import XCTest
import AVFoundation
@testable import Casablanca

/// Regression coverage for total recording loss on interruption.
///
/// Context: `RecordingSession.stop()` stops the system-audio capture FIRST.
/// When the machine sleeps or the input device disappears (e.g. closing the
/// laptop lid), ScreenCaptureKit has often already torn the `SCStream` down, so
/// `stopCapture()` throws. The throw used to escape `stop()` *before* the
/// microphone writer was drained/closed and the mix-down rendered — orphaning
/// the microphone PCM that had streamed to disk the whole meeting, which the
/// resume store then deleted. Net effect: an interruption lost the entire
/// recording even though the audio was on disk all along.
///
/// The fix makes the system-audio stop best-effort so finalization always
/// proceeds. This test seeds a captured microphone track, injects a fake
/// system-audio unit whose `stop()` throws, and asserts the recording is
/// finalized instead of discarded.
///
/// NOT covered here: the narrower path where `render()` itself throws (genuine
/// I/O failure) after a clean drain — `handleSystemInterrupt` still discards
/// that segment. Recovering orphaned temp PCM on render failure is tracked as a
/// separate follow-up; add a matching test when that lands.
@MainActor
final class RecordingSessionTeardownResilienceTests: XCTestCase {

    /// A fake system-audio source whose `stop()` throws, mirroring an `SCStream`
    /// already torn down by system sleep / device loss.
    private final class ThrowingSystemAudioUnit: SystemAudioCapturing, @unchecked Sendable {
        struct StopError: Error {}
        private(set) var stopCalled = false
        func beginAcceptingInput() {}
        func start() async throws {}
        func stop() async throws {
            stopCalled = true
            throw StopError()
        }
        func setSystemAudioEnabled(_ enabled: Bool) {}
    }

    private func makeSession(outputURL: URL) throws -> RecordingSession {
        let meeting = Meeting(title: "Teardown Resilience", date: .now, status: .recording)
        return try RecordingSession(
            outputURL: outputURL,
            meeting: meeting,
            inputDeviceID: nil,
            systemAudioEnabled: true,
            onLevelUpdate: { _ in },
            onFailure: { _ in },
            onStreamFatal: { _ in }
        )
    }

    /// One second of 16 kHz mono float32 audio matching the recorder's target
    /// format, so the writer stores it verbatim (no conversion) and counts frames.
    private func oneSecondMonoBuffer() -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        let frames: AVAudioFrameCount = 16_000
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        for index in 0..<Int(frames) {
            samples[index] = 0.1
        }
        return buffer
    }

    func testStopFinalizesCapturedMicrophoneAudioWhenSystemAudioStopThrows() async throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        let session = try makeSession(outputURL: outputURL)
        let throwingSystemAudio = ThrowingSystemAudioUnit()
        let microphoneWriter = try session.configureForTeardownTesting(systemAudioUnit: throwingSystemAudio)

        // Microphone audio that streamed to disk before the interruption.
        microphoneWriter.enqueue(buffer: oneSecondMonoBuffer())

        // Before the fix this threw `ThrowingSystemAudioUnit.StopError` and the
        // captured audio was lost. It must now finalize the microphone track.
        let result = try await session.stop()

        XCTAssertTrue(throwingSystemAudio.stopCalled, "System-audio stop should have been attempted")
        XCTAssertTrue(
            session.hasCapturedFrames,
            "Captured microphone frames must survive a system-audio stop failure"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: result.outputURL.path),
            "A final WAV must be written from the captured microphone audio"
        )
        let size = (try FileManager.default.attributesOfItem(atPath: result.outputURL.path)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size, 44, "Final WAV must contain audio beyond the 44-byte header")

        try? FileManager.default.removeItem(at: result.outputURL)
    }
}
