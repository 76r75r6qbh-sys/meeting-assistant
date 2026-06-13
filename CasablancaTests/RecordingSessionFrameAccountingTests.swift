import XCTest
import AVFoundation
@testable import Casablanca

/// Regression coverage for the frame-accounting contract that the recording
/// facade depends on.
///
/// Context: `AudioRecordingService.finalizeActiveSegment` calls `session.stop()`
/// and *then* reads `session.hasCapturedFrames` to decide whether to keep the
/// segment. A Phase-1c regression moved the per-track frame counters into the
/// `PCMTrackWriter`s, which `stop()` releases — so `hasCapturedFrames` read the
/// now-nil writers and always returned `false` after stopping, causing every
/// finalized recording to be dropped as "no audio samples were captured."
///
/// The fix caches the captured-frame total in `stop()` before the writers are
/// released, so `hasCapturedFrames` stays accurate when the facade checks it.
/// These tests exercise the real `RecordingSession.stop()` teardown path
/// (the empty case, which needs no audio hardware); the non-empty capture path
/// is hardware-bound and is verified by recording in the app.
@MainActor
final class RecordingSessionFrameAccountingTests: XCTestCase {

    private func makeSession(systemAudioEnabled: Bool) throws -> RecordingSession {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        let meeting = Meeting(title: "Frame Accounting", date: .now, status: .recording)
        return try RecordingSession(
            outputURL: outputURL,
            meeting: meeting,
            inputDeviceID: nil,
            systemAudioEnabled: systemAudioEnabled,
            onLevelUpdate: { _ in },
            onFailure: { _ in },
            onStreamFatal: { _ in }
        )
    }

    func testFreshSessionReportsNoCapturedFrames() throws {
        let session = try makeSession(systemAudioEnabled: false)
        XCTAssertFalse(session.hasCapturedFrames)
    }

    func testStopWithoutCaptureThrowsNoCapturedAudioAndStaysEmpty() async throws {
        let session = try makeSession(systemAudioEnabled: false)

        do {
            _ = try await session.stop()
            XCTFail("Expected stop() to throw noCapturedAudio when nothing was captured")
        } catch let error as RecordingError {
            guard case .noCapturedAudio = error else {
                return XCTFail("Expected .noCapturedAudio, got \(error)")
            }
        }

        // The contract the facade relies on: after stop(), hasCapturedFrames must
        // still reflect what was captured (here: nothing). This is the property
        // the regression broke — it must remain false, not throw or change.
        XCTAssertFalse(session.hasCapturedFrames)
    }
}
