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

    /// How long `stop()` waits for the system-audio stream to stop before
    /// abandoning it and finalizing the microphone track anyway. Injectable so
    /// tests can drive the timeout path without a multi-second wait.
    private let systemAudioStopTimeout: Duration

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

    /// Where this session is in its stop sequence. `stop()` is one-shot: an
    /// interrupt-driven finalize and the user's Stop can interleave, and the
    /// second entry used to re-read the released frame counters as 0, take the
    /// "empty" branch, and delete the finished WAV plus the raw PCM — losing the
    /// whole recording. Lock-guarded because the two callers arrive on different
    /// threads.
    private enum Lifecycle {
        case live
        case stopping
        case stopped
    }

    private let lifecycle = OSAllocatedUnfairLock<Lifecycle>(initialState: .live)

    init(
        outputURL: URL,
        meeting: Meeting,
        inputDeviceID: AudioDeviceID?,
        systemAudioEnabled: Bool,
        systemAudioStopTimeout: Duration = .seconds(5),
        onLevelUpdate: @escaping (Double) -> Void,
        onFailure: @escaping (Error) -> Void,
        onStreamFatal: @escaping (Error) -> Void
    ) throws {
        self.outputURL = outputURL
        self.microphoneTempURL = Self.makeTemporaryURL(for: outputURL, suffix: "mic")
        self.systemAudioTempURL = Self.makeTemporaryURL(for: outputURL, suffix: "system")
        self.initialInputDeviceID = inputDeviceID
        self.initialSystemAudioEnabled = systemAudioEnabled
        self.systemAudioStopTimeout = systemAudioStopTimeout
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
        // closed, and rendered below. The wait is also time-bounded, because
        // after sleep the stop often neither returns nor throws — see
        // `stopSystemAudioBounded`.
        //
        // NOTE: this does NOT make stop() infallible — `render()` further down
        // can still throw (genuine I/O failure), and `handleSystemInterrupt`
        // currently discards a segment whose finalize throws. That narrower
        // loss window (orphaned temp PCM on render failure) needs raw-segment
        // recovery and is tracked separately, not fixed here.
        //
        // Claim the stop first, before touching anything on disk: a second entry
        // must be rejected while the first is still finalizing, not allowed to
        // race it into the delete branch below.
        try lifecycle.withLock { state in
            guard case .live = state else {
                // Leave a trace: this is the interleave that lost a recording, so
                // a rejected second finalize must be visible in the field — with
                // which state it hit (still finalizing vs. already finished).
                // Materialized before interpolation: the log interpolation is an
                // autoclosure and cannot capture the `inout` state.
                let rejectedState = String(describing: state)
                Log.recording.error("Second stop() rejected: state=\(rejectedState, privacy: .public)")
                throw RecordingError.sessionAlreadyStopped
            }
            state = .stopping
        }
        defer { lifecycle.withLock { $0 = .stopped } }

        if let systemAudioUnit {
            await stopSystemAudioBounded(systemAudioUnit)
        }
        systemAudioUnit = nil

        microphoneUnit?.stop()
        microphoneUnit?.drainPendingWork()
        microphoneUnit = nil

        microphoneWriter?.drainAndClose()
        systemAudioWriter?.drainAndClose()

        // The bytes on disk are the source of truth for "how much did we
        // capture?". The in-memory counters live in the writers, which a
        // previous finalize may already have released — reading them alone once
        // reported 0 for a 75-minute recording and deleted it. Take whichever is
        // larger so a counter that is merely behind can still only *raise* the
        // count, never lower it. Integer division truncates a torn trailing
        // partial frame, and a missing file measures as 0 bytes.
        let microphoneBytes = Self.fileSize(at: microphoneTempURL)
        let systemAudioBytes = Self.fileSize(at: systemAudioTempURL)
        let microphoneFrames = max(
            microphoneWriter?.frames ?? 0,
            AVAudioFramePosition(microphoneBytes / Int64(MemoryLayout<Float>.size))
        )
        let systemAudioFrames = max(
            systemAudioWriter?.frames ?? 0,
            AVAudioFramePosition(systemAudioBytes / Int64(MemoryLayout<Float>.size))
        )
        // Cache the total before releasing the writers so `hasCapturedFrames`
        // (read by the facade after `stop()` returns) reflects what was captured.
        finalizedFrameCount.withLock { $0 = microphoneFrames + systemAudioFrames }
        microphoneWriter = nil
        systemAudioWriter = nil

        // Delete only when the segment is *provably* empty: no frames counted
        // AND no bytes on disk on either track. Any doubt keeps the files.
        let isProvablyEmpty = microphoneFrames == 0
            && systemAudioFrames == 0
            && microphoneBytes == 0
            && systemAudioBytes == 0
        if isProvablyEmpty {
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
        let renderStartedAt = Date()
        try renderer.render()
        let renderMilliseconds = Int((Date().timeIntervalSince(renderStartedAt) * 1000).rounded())

        Log.recording.notice(
            "Segment finalize: micFrames=\(microphoneFrames, privacy: .public) sysFrames=\(systemAudioFrames, privacy: .public) micBytes=\(microphoneBytes, privacy: .public) sysBytes=\(systemAudioBytes, privacy: .public) renderMs=\(renderMilliseconds, privacy: .public)"
        )

        let duration = Date().timeIntervalSince(startedAt)
        return RecordingResult(outputURL: outputURL, duration: duration)
    }

    /// Stops the system-audio stream, waiting at most `systemAudioStopTimeout`.
    ///
    /// A thrown stop is already survivable, but after the Mac sleeps
    /// ScreenCaptureKit has often torn the `SCStream` down without ever calling
    /// back, so `stopCapture()`'s continuation is never resumed and awaiting it
    /// suspends forever. That hung `stop()` never released the facade's
    /// `session`, so every later resume threw `.activeRecordingExists` and the
    /// UI sat on "Finalizing recording…" while the captured microphone PCM was
    /// never rendered. Bounding the wait keeps the rest of the teardown
    /// (drain → close → mix-down) reachable.
    ///
    /// Deliberately NOT a task group: a group only returns once *all* of its
    /// children have finished, and `cancelAll()` cannot interrupt a suspended
    /// continuation — the hung child would keep the group, and `stop()`, waiting
    /// anyway. So both legs race as unstructured tasks to claim a one-shot
    /// resume. The losing leg is abandoned, and because the claim is
    /// lock-guarded a hung stop that resumes much later is a harmless no-op
    /// rather than a double resume (which would trap).
    private func stopSystemAudioBounded(_ unit: SystemAudioCapturing) async {
        // BEFORE the await, not inside `unit.stop()`: a stop that times out
        // never reaches its own disarm, and the abandoned `SCStream` can still
        // deliver `didStopWithError` afterwards — which arrived at the service as
        // a fresh `.streamFailure` (a reason that never auto-resumes) and hard-
        // paused the segment the wake had just resumed.
        unit.disarmStreamFailureReporting()

        let timeout = systemAudioStopTimeout
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let isClaimed = OSAllocatedUnfairLock<Bool>(initialState: false)
            let claim: @Sendable () -> Bool = {
                isClaimed.withLock { claimed in
                    guard !claimed else { return false }
                    claimed = true
                    return true
                }
            }

            Task {
                do {
                    try await unit.stop()
                } catch {
                    Log.recording.error("System-audio stop failed during teardown; finalizing captured audio anyway: \(error.localizedDescription, privacy: .public)")
                }
                if claim() { continuation.resume() }
            }

            Task {
                try? await Task.sleep(for: timeout)
                guard claim() else { return }
                Log.recording.error("System-audio stop timed out after \(String(describing: timeout), privacy: .public); continuing teardown")
                continuation.resume()
            }
        }
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

    /// Test seam: the temporary per-track PCM files this session captures into.
    /// Tests write raw float32 bytes straight into them (behind the writers'
    /// backs) to reproduce the double-finalize shape where audio is on disk but
    /// the in-memory frame counters read 0.
    var temporaryTrackURLs: (microphone: URL, systemAudio: URL) {
        (microphoneTempURL, systemAudioTempURL)
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

    /// Bytes currently on disk for a temp track, or 0 when the file is missing.
    private static func fileSize(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    private static func makeTemporaryURL(for outputURL: URL, suffix: String) -> URL {
        outputURL
            .deletingPathExtension()
            .appendingPathExtension(suffix)
            .appendingPathExtension("pcm")
    }
}
