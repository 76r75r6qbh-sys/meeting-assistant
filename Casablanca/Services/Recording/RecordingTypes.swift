@preconcurrency import AVFoundation
import CoreAudio
import Foundation

struct RecordingResult {
    let outputURL: URL
    let duration: TimeInterval
}

struct AudioInputDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let deviceID: AudioDeviceID
}

enum RecordingError: LocalizedError {
    case microphonePermissionDenied
    case systemAudioPermissionDenied
    case systemAudioPermissionRequiresRestart
    case systemAudioCaptureFailed(String)
    case noDisplayAvailable
    case unableToCreateOutputDirectory
    case failedToCreateAudioFile
    case failedToFinalizeRecording(String)
    case noCapturedAudio
    case activeRecordingExists
    case noActiveRecording

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone access is required before recording can start."
        case .systemAudioPermissionDenied:
            return "Enable Screen Recording for Casablanca in System Settings, then quit and reopen the app before starting the recording again."
        case .systemAudioPermissionRequiresRestart:
            return "Quit and reopen Casablanca, then start the recording again."
        case .systemAudioCaptureFailed(let message):
            return message
        case .noDisplayAvailable:
            return "No active display was found for system audio capture."
        case .unableToCreateOutputDirectory:
            return "Casablanca could not create its recordings folder."
        case .failedToCreateAudioFile:
            return "Casablanca could not create the recording file."
        case .failedToFinalizeRecording(let message):
            return message
        case .noCapturedAudio:
            return "Casablanca started the recording, but no audio samples were captured."
        case .activeRecordingExists:
            return "A recording is already in progress."
        case .noActiveRecording:
            return "There is no active recording to stop."
        }
    }
}

protocol RecordingSessionControlling: AnyObject {
    var outputURL: URL { get }
    var startedAt: Date { get }
    var hasCapturedFrames: Bool { get }
    /// Non-nil after `start()` when system-audio capture could not start and the
    /// session fell back to microphone-only (see `RecordingSession`).
    var systemAudioUnavailableError: Error? { get }
    func start() async throws
    func stop() async throws -> RecordingResult
    func setMicrophoneDevice(_ deviceID: AudioDeviceID) throws
    func setSystemAudioEnabled(_ enabled: Bool)
}

/// The system-audio capture surface `RecordingSession` drives. Extracted as a
/// protocol so the stop/finalize teardown can be exercised headlessly with a
/// fake that throws on `stop()` (mirroring an `SCStream` already torn down by
/// system sleep or device loss).
///
/// `Sendable` is load-bearing: the production conformer feeds buffers from the
/// SCStream sample-handler queue while the facade drives it from the MainActor,
/// so any conformer (including test fakes) must be safe to touch from both.
protocol SystemAudioCapturing: AnyObject, Sendable {
    func beginAcceptingInput()
    func start() async throws
    func stop() async throws
    func setSystemAudioEnabled(_ enabled: Bool)
}

typealias RecordingSessionFactory = (
    _ outputURL: URL,
    _ meeting: Meeting,
    _ inputDeviceID: AudioDeviceID?,
    _ systemAudioEnabled: Bool,
    _ onLevelUpdate: @escaping (Double) -> Void,
    _ onFailure: @escaping (Error) -> Void,
    _ onStreamFatal: @escaping (Error) -> Void
) throws -> RecordingSessionControlling

enum RecordingInterruptionReason: Hashable, Sendable {
    case screenLock
    case systemSleep
    case audioDeviceLost(deviceID: String)
    /// No display is available to capture, so ScreenCaptureKit can't record
    /// system audio (e.g. the lid is closed with no external monitor). Recording
    /// auto-pauses and auto-resumes when a display returns.
    case displayUnavailable
    case streamFailure(underlyingDescription: String)

    var allowsAutoResume: Bool {
        switch self {
        case .screenLock, .systemSleep, .displayUnavailable: return true
        case .audioDeviceLost, .streamFailure: return false
        }
    }
}

enum RecordingTrackKind {
    case microphone
    case systemAudio
}

struct DeferredTrackCapturePlan: Equatable {
    let kind: RecordingTrackKind
    let writesRawCaptureBuffers: Bool
    let requiresRealtimeConversion: Bool
}

struct DeferredRecordingPipeline: Equatable {
    let microphone: DeferredTrackCapturePlan
    let systemAudio: DeferredTrackCapturePlan
    let requiresScreenStreamOutput: Bool

    static let captureFirst = DeferredRecordingPipeline(
        microphone: DeferredTrackCapturePlan(
            kind: .microphone,
            writesRawCaptureBuffers: true,
            requiresRealtimeConversion: false
        ),
        systemAudio: DeferredTrackCapturePlan(
            kind: .systemAudio,
            writesRawCaptureBuffers: true,
            requiresRealtimeConversion: false
        ),
        requiresScreenStreamOutput: false
    )

    func expectedOutputFrameCount(
        microphoneFrames: AVAudioFramePosition,
        systemAudioFrames: AVAudioFramePosition
    ) -> AVAudioFramePosition {
        max(microphoneFrames, systemAudioFrames)
    }
}

enum TemporaryRecordingPCMStorage {
    static func data(from buffer: AVAudioPCMBuffer) -> Data {
        guard let channelData = buffer.floatChannelData?.pointee else {
            return Data()
        }

        let sampleCount = Int(buffer.frameLength)
        return Data(bytes: channelData, count: sampleCount * MemoryLayout<Float>.size)
    }

    static func samples(from data: Data) -> [Float] {
        data.withUnsafeBytes { rawBuffer in
            Array(rawBuffer.bindMemory(to: Float.self))
        }
    }
}
