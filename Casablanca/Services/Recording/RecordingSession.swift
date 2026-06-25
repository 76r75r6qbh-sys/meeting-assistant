@preconcurrency import AVFoundation
import CoreAudio
import CoreGraphics
import Foundation
import OSLog
import os

/// Composes the recording units (`MicrophoneCaptureUnit`,
/// `SystemAudioCaptureUnit`, two `PCMTrackWriter`s, `AudioLevelAggregator`) and
/// renders the final mix via `RecordingMixdownRenderer`. Phase 1c reduced this
/// from a ~880-line god class to start/stop sequencing plus permission checks.
///
/// `@unchecked Sendable`: this object is created and driven from the MainActor
/// facade, but the realtime audio callbacks live in the units (each of which
/// owns its own synchronization). The only state this type reads off the
/// MainActor is `hasCapturedFrames`, which reads the writers' lock-guarded
/// frame counters — safe from any thread.
final class RecordingSession: NSObject, RecordingSessionControlling, @unchecked Sendable {
    let outputURL: URL
    let startedAt = Date()

    private let microphoneTempURL: URL
    private let systemAudioTempURL: URL
    private let pipeline = DeferredRecordingPipeline.captureFirst
    private let initialInputDeviceID: AudioDeviceID?
    private let initialSystemAudioEnabled: Bool

    private let onFailure: (Error) -> Void
    private let onStreamFatal: (Error) -> Void

    private let levelAggregator: AudioLevelAggregator

    private var microphoneWriter: PCMTrackWriter?
    private var systemAudioWriter: PCMTrackWriter?
    private var microphoneUnit: MicrophoneCaptureUnit?
    private var systemAudioUnit: SystemAudioCapturing?

    /// Set during `start()` when system-audio capture could not start (e.g. no
    /// available display because the lid is closed) and the session fell back to
    /// microphone-only. Read by the facade to surface a non-fatal notice. `nil`
    /// means system audio started normally (or was disabled by the user).
    private(set) var systemAudioUnavailableError: Error?

    /// Frames captured by the just-finalized track(s), cached during `stop()`
    /// before the writers are released. The facade reads `hasCapturedFrames`
    /// *after* `stop()` (to decide whether to keep the segment), so the count
    /// must outlive the writers — matching the pre-Phase-1c behavior where the
    /// counters were session-level stored properties. Lock-guarded so it stays
    /// safe to read from any thread.
    private let finalizedFrameCount = OSAllocatedUnfairLock<AVAudioFramePosition>(initialState: 0)

    init(
        outputURL: URL,
        meeting: Meeting,
        inputDeviceID: AudioDeviceID?,
        systemAudioEnabled: Bool,
        onLevelUpdate: @escaping (Double) -> Void,
        onFailure: @escaping (Error) -> Void,
        onStreamFatal: @escaping (Error) -> Void
    ) throws {
        self.outputURL = outputURL
        self.microphoneTempURL = Self.makeTemporaryURL(for: outputURL, suffix: "mic")
        self.systemAudioTempURL = Self.makeTemporaryURL(for: outputURL, suffix: "system")
        self.initialInputDeviceID = inputDeviceID
        self.initialSystemAudioEnabled = systemAudioEnabled
        self.onFailure = onFailure
        self.onStreamFatal = onStreamFatal
        self.levelAggregator = AudioLevelAggregator(onLevelUpdate: onLevelUpdate)
        super.init()
    }

    var hasCapturedFrames: Bool {
        // Live writers report frames while recording; once `stop()` releases the
        // writers it caches the final total in `finalizedFrameCount`, so this
        // stays accurate when the facade checks it after stopping.
        let live = (microphoneWriter?.frames ?? 0) + (systemAudioWriter?.frames ?? 0)
        return live > 0 || finalizedFrameCount.withLock { $0 } > 0
    }

    func start() async throws {
        try await Self.ensureMicrophonePermission()
        // System audio (via ScreenCaptureKit) needs Screen Recording permission.
        // It is optional: when system audio is disabled we record microphone-only
        // and must NOT block on a missing/denied screen-recording grant.
        if initialSystemAudioEnabled {
            try Self.ensureScreenCapturePermission()
        }
        try configure()
        // `configure()` has already started the microphone engine, so the
        // engine-is-live invariant the original gated on (`didStartEngine`) now
        // holds. Open the system-audio gate before starting the stream so no
        // samples are dropped once it begins delivering.
        //
        // When system audio is disabled we skip the ScreenCaptureKit stream
        // entirely: it requires Screen Recording permission, and starting it
        // would fail for a microphone-only recording. The mix-down later sees
        // zero system-audio frames and renders microphone-only.
        await startSystemAudioBestEffort()
    }

    /// Starts the ScreenCaptureKit system-audio stream, degrading to
    /// microphone-only if it can't start.
    ///
    /// System audio needs an *available display*: ScreenCaptureKit captures it
    /// off a display's stream. When the lid is closed with no external monitor
    /// there is no capturable display, so `startCapture()` fails with "no
    /// displays or windows found to record". That must NOT fail the whole
    /// recording — the microphone engine is already live (`configure()` started
    /// it) and needs no display. We disable system audio for this session and
    /// carry on microphone-only; the mix-down then renders microphone-only.
    /// `systemAudioUnavailableError` lets the facade surface a non-fatal notice
    /// (remote meeting audio comes through system audio, so the user should know
    /// it's missing).
    private func startSystemAudioBestEffort() async {
        guard initialSystemAudioEnabled, let systemAudioUnit else { return }
        systemAudioUnit.beginAcceptingInput()
        do {
            try await systemAudioUnit.start()
        } catch {
            Log.recording.error("System-audio capture could not start (\(error.localizedDescription, privacy: .public)); continuing microphone-only")
            systemAudioUnit.setSystemAudioEnabled(false)
            systemAudioUnavailableError = error
        }
    }

    func stop() async throws -> RecordingResult {
        // Teardown ordering is intentional and load-bearing: stop capture
        // (removes the tap, halts new enqueues) → drain in-flight buffers →
        // close writers. Reordering risks dropping or losing queued audio.
        //
        // Stopping the system-audio stream is BEST-EFFORT: when the machine
        // sleeps or the capture device disappears, ScreenCaptureKit has often
        // already torn the `SCStream` down, so `stopCapture()` throws. Letting
        // that throw escape here used to abort the entire teardown before the
        // microphone writer was drained/closed and the mix-down rendered —
        // orphaning the microphone PCM that had been streaming to disk the whole
        // meeting, which the resume store then deleted. The result was that an
        // interruption (e.g. closing the laptop lid) lost the entire recording.
        // Swallow the stop failure so the captured tracks are still drained,
        // closed, and rendered below.
        //
        // NOTE: this does NOT make stop() infallible — `render()` further down
        // can still throw (genuine I/O failure), and `handleSystemInterrupt`
        // currently discards a segment whose finalize throws. That narrower
        // loss window (orphaned temp PCM on render failure) needs raw-segment
        // recovery and is tracked separately, not fixed here.
        do {
            try await systemAudioUnit?.stop()
        } catch {
            Log.recording.error("System-audio stop failed during teardown; finalizing captured audio anyway: \(error.localizedDescription, privacy: .public)")
        }
        systemAudioUnit = nil

        microphoneUnit?.stop()
        microphoneUnit?.drainPendingWork()
        microphoneUnit = nil

        microphoneWriter?.drainAndClose()
        systemAudioWriter?.drainAndClose()

        let microphoneFrames = microphoneWriter?.frames ?? 0
        let systemAudioFrames = systemAudioWriter?.frames ?? 0
        // Cache the total before releasing the writers so `hasCapturedFrames`
        // (read by the facade after `stop()` returns) reflects what was captured.
        finalizedFrameCount.withLock { $0 = microphoneFrames + systemAudioFrames }
        microphoneWriter = nil
        systemAudioWriter = nil

        guard microphoneFrames > 0 || systemAudioFrames > 0 else {
            bestEffort("remove microphone temp file", Log.recording) { try FileManager.default.removeItem(at: microphoneTempURL) }
            bestEffort("remove system audio temp file", Log.recording) { try FileManager.default.removeItem(at: systemAudioTempURL) }
            bestEffort("remove output file", Log.recording) { try FileManager.default.removeItem(at: outputURL) }
            throw RecordingError.noCapturedAudio
        }

        let renderer = RecordingMixdownRenderer(
            microphoneURL: microphoneTempURL,
            systemAudioURL: systemAudioTempURL,
            microphoneFrames: microphoneFrames,
            systemAudioFrames: systemAudioFrames,
            outputURL: outputURL,
            expectedOutputFrames: pipeline.expectedOutputFrameCount(
                microphoneFrames: microphoneFrames,
                systemAudioFrames: systemAudioFrames
            )
        )
        try renderer.render()

        let duration = Date().timeIntervalSince(startedAt)
        return RecordingResult(outputURL: outputURL, duration: duration)
    }

    func setMicrophoneDevice(_ deviceID: AudioDeviceID) throws {
        try microphoneUnit?.setInputDevice(deviceID)
    }

    func setSystemAudioEnabled(_ enabled: Bool) {
        systemAudioUnit?.setSystemAudioEnabled(enabled)
    }

    private func configure() throws {
        let (outputFormat, microphoneWriter, systemAudioWriter) = try makeTrackWriters()

        let levelAggregator = self.levelAggregator
        let microphoneUnit = MicrophoneCaptureUnit(
            inputDeviceID: initialInputDeviceID,
            onLevel: { buffer in levelAggregator.publishMicrophoneLevel(from: buffer) },
            onBuffer: { buffer in microphoneWriter.enqueue(buffer: buffer) }
        )
        let systemAudioUnit = SystemAudioCaptureUnit(
            pipeline: pipeline,
            targetFormat: outputFormat,
            systemAudioEnabled: initialSystemAudioEnabled,
            onSampleBuffer: { buffer in
                systemAudioWriter.enqueue(buffer: buffer) { converted in
                    levelAggregator.publishSystemLevel(from: converted)
                }
            },
            onSystemDisabled: { levelAggregator.resetSystemLevel() },
            onStreamFatal: onStreamFatal
        )
        self.microphoneUnit = microphoneUnit
        self.systemAudioUnit = systemAudioUnit

        try microphoneUnit.start()
    }

    /// Creates the two temp PCM files and their writers. Extracted from
    /// `configure()` so the teardown/finalize path can be exercised in tests
    /// without starting real audio hardware.
    private func makeTrackWriters() throws -> (AVAudioFormat, PCMTrackWriter, PCMTrackWriter) {
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw RecordingError.failedToCreateAudioFile
        }

        guard FileManager.default.createFile(atPath: microphoneTempURL.path, contents: nil),
              FileManager.default.createFile(atPath: systemAudioTempURL.path, contents: nil),
              let microphoneFileHandle = try? FileHandle(forWritingTo: microphoneTempURL),
              let systemAudioFileHandle = try? FileHandle(forWritingTo: systemAudioTempURL)
        else {
            throw RecordingError.failedToCreateAudioFile
        }

        let microphoneWriter = PCMTrackWriter(
            label: "microphone",
            queueLabel: "com.casablanca.recording.microphone.writer",
            targetFormat: outputFormat,
            fileHandle: microphoneFileHandle,
            onFailure: onFailure
        )
        let systemAudioWriter = PCMTrackWriter(
            label: "system audio",
            queueLabel: "com.casablanca.recording.system.writer",
            targetFormat: outputFormat,
            fileHandle: systemAudioFileHandle,
            onFailure: onFailure
        )
        self.microphoneWriter = microphoneWriter
        self.systemAudioWriter = systemAudioWriter
        return (outputFormat, microphoneWriter, systemAudioWriter)
    }

#if DEBUG
    /// Test seam: builds a session whose temp files + writers are live but whose
    /// only capture source is the injected (typically fake) system-audio unit,
    /// so `stop()`'s teardown resilience can be verified headlessly. The
    /// microphone unit stays nil; tests seed captured frames through the
    /// returned microphone writer. Returns the microphone writer so callers can
    /// enqueue buffers before stopping. The writer-live-without-its-unit state is
    /// deliberate and test-only — production always creates them together in
    /// `configure()`; `stop()` tolerates the nil unit via its `?.` chaining.
    @discardableResult
    func configureForTeardownTesting(systemAudioUnit: SystemAudioCapturing?) throws -> PCMTrackWriter {
        let (_, microphoneWriter, _) = try makeTrackWriters()
        self.systemAudioUnit = systemAudioUnit
        return microphoneWriter
    }

    /// Test seam: drives `startSystemAudioBestEffort()` with the injected unit so
    /// the no-display degrade-to-microphone-only path can be verified headlessly
    /// (the real `start()` would spin up the microphone `AVAudioEngine`).
    func startSystemAudioBestEffortForTesting() async {
        await startSystemAudioBestEffort()
    }
#endif

    // MARK: - Permissions

    private static func ensureMicrophonePermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard granted else {
                throw RecordingError.microphonePermissionDenied
            }
        default:
            throw RecordingError.microphonePermissionDenied
        }
    }

    private static func ensureScreenCapturePermission() throws {
        switch ScreenCapturePermissionState.resolve(
            preflight: { CGPreflightScreenCaptureAccess() },
            request: { CGRequestScreenCaptureAccess() }
        ) {
        case .granted:
            return
        case .grantedRequiresRestart:
            throw RecordingError.systemAudioPermissionRequiresRestart
        case .denied:
            throw RecordingError.systemAudioPermissionDenied
        }
    }

    private static func makeTemporaryURL(for outputURL: URL, suffix: String) -> URL {
        outputURL
            .deletingPathExtension()
            .appendingPathExtension(suffix)
            .appendingPathExtension("pcm")
    }
}
