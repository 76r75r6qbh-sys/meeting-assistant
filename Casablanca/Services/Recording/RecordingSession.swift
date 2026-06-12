@preconcurrency import AVFoundation
import CoreAudio
import CoreGraphics
import Foundation
import OSLog

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

    private var outputFormat: AVAudioFormat?
    private var microphoneWriter: PCMTrackWriter?
    private var systemAudioWriter: PCMTrackWriter?
    private var microphoneUnit: MicrophoneCaptureUnit?
    private var systemAudioUnit: SystemAudioCaptureUnit?

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
        (microphoneWriter?.frames ?? 0) > 0 || (systemAudioWriter?.frames ?? 0) > 0
    }

    func start() async throws {
        try await Self.ensureMicrophonePermission()
        try Self.ensureScreenCapturePermission()
        try configure()
        // `configure()` has already started the microphone engine, so the
        // engine-is-live invariant the original gated on (`didStartEngine`) now
        // holds. Open the system-audio gate before starting the stream so no
        // samples are dropped once it begins delivering.
        systemAudioUnit?.beginAcceptingInput()
        try await systemAudioUnit?.start()
    }

    func stop() async throws -> RecordingResult {
        try await systemAudioUnit?.stop()
        systemAudioUnit = nil

        microphoneUnit?.stop()
        microphoneUnit?.drainPendingWork()
        microphoneUnit = nil

        microphoneWriter?.drainAndClose()
        systemAudioWriter?.drainAndClose()

        let microphoneFrames = microphoneWriter?.frames ?? 0
        let systemAudioFrames = systemAudioWriter?.frames ?? 0
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
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw RecordingError.failedToCreateAudioFile
        }
        self.outputFormat = outputFormat

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
