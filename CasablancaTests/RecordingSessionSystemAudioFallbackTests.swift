import XCTest
import AVFoundation
@testable import Casablanca

/// Regression coverage for recording failing outright when system audio can't
/// be captured.
///
/// Context: system audio is captured via ScreenCaptureKit, which streams off a
/// *display*. With the laptop lid closed and no external monitor there is no
/// capturable display, so `SCStream.startCapture()` fails with "no displays or
/// windows found to record". `RecordingSession.start()` used to let that error
/// propagate, failing the whole recording (and the elapsed timer reset to
/// 00:00). The microphone needs no display, so the session should instead
/// degrade to microphone-only and keep recording.
///
/// This injects a system-audio unit whose `start()` throws and asserts the
/// session disables system audio, records the fallback for the facade to
/// surface, and does not propagate the error.
@MainActor
final class RecordingSessionSystemAudioFallbackTests: XCTestCase {

    /// A fake system-audio source whose `start()` throws, mirroring
    /// ScreenCaptureKit with no available display (lid closed).
    private final class StartThrowingSystemAudioUnit: SystemAudioCapturing, @unchecked Sendable {
        struct NoDisplayError: Error {}
        private(set) var beganAcceptingInput = false
        private(set) var startCalled = false
        private(set) var systemAudioDisabled = false
        func beginAcceptingInput() { beganAcceptingInput = true }
        func start() async throws {
            startCalled = true
            throw NoDisplayError()
        }
        func stop() async throws {}
        func setSystemAudioEnabled(_ enabled: Bool) {
            if !enabled { systemAudioDisabled = true }
        }
    }

    func testSystemAudioStartFailureDegradesToMicrophoneOnly() async throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        let meeting = Meeting(title: "Lid Closed", date: .now, status: .recording)
        let session = try RecordingSession(
            outputURL: outputURL,
            meeting: meeting,
            inputDeviceID: nil,
            systemAudioEnabled: true,
            onLevelUpdate: { _ in },
            onFailure: { _ in },
            onStreamFatal: { _ in }
        )
        let failing = StartThrowingSystemAudioUnit()
        try session.configureForTeardownTesting(systemAudioUnit: failing)

        // Must not throw — this is the regression. The system-audio start failure
        // used to propagate and fail the whole recording.
        await session.startSystemAudioBestEffortForTesting()

        XCTAssertTrue(failing.beganAcceptingInput)
        XCTAssertTrue(failing.startCalled)
        XCTAssertTrue(
            failing.systemAudioDisabled,
            "System audio should be disabled for the session after a start failure"
        )
        XCTAssertNotNil(
            session.systemAudioUnavailableError,
            "The fallback must be recorded so the facade can surface a non-fatal notice"
        )
    }
}
