import XCTest
@testable import Casablanca

@MainActor
final class SafeToQuitProbeTests: XCTestCase {
    func test_returnsNil_whenAllIdle() {
        let probe = ClosureSafeToQuitProbe(
            isRecordingActive: { false },
            isTranscriptionActive: { false },
            isSummarizationActive: { false }
        )
        XCTAssertNil(probe.reasonInstallShouldWait())
    }

    func test_returnsRecording_whenRecording() {
        let probe = ClosureSafeToQuitProbe(
            isRecordingActive: { true },
            isTranscriptionActive: { false },
            isSummarizationActive: { false }
        )
        XCTAssertEqual(probe.reasonInstallShouldWait(), "an active recording")
    }

    func test_returnsTranscription_whenTranscribing() {
        let probe = ClosureSafeToQuitProbe(
            isRecordingActive: { false },
            isTranscriptionActive: { true },
            isSummarizationActive: { false }
        )
        XCTAssertEqual(probe.reasonInstallShouldWait(), "an in-flight transcription")
    }

    func test_returnsSummary_whenSummarizing() {
        let probe = ClosureSafeToQuitProbe(
            isRecordingActive: { false },
            isTranscriptionActive: { false },
            isSummarizationActive: { true }
        )
        XCTAssertEqual(probe.reasonInstallShouldWait(), "an in-flight summary")
    }

    func test_recordingTakesPriority_overTranscriptionAndSummary() {
        let probe = ClosureSafeToQuitProbe(
            isRecordingActive: { true },
            isTranscriptionActive: { true },
            isSummarizationActive: { true }
        )
        XCTAssertEqual(probe.reasonInstallShouldWait(), "an active recording")
    }
}
