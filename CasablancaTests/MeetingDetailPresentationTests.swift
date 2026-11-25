import XCTest
@testable import Casablanca

final class MeetingDetailPresentationTests: XCTestCase {

    // MARK: - reviewPrimaryAction

    func testTranscribeWhenNoTranscriptButHasRecording() {
        let action = reviewPrimaryAction(
            hasTranscript: false, hasRecording: true,
            hasSummary: false, canSummarize: false, canExport: false
        )
        XCTAssertEqual(action, .transcribe)
    }

    func testNoTranscribeWhenNoRecordingEvenWithoutTranscript() {
        // No recording -> cannot transcribe; falls through.
        let action = reviewPrimaryAction(
            hasTranscript: false, hasRecording: false,
            hasSummary: false, canSummarize: false, canExport: false
        )
        XCTAssertNil(action)
    }

    func testSummarizeWhenTranscriptPresentNoSummaryAndCanSummarize() {
        let action = reviewPrimaryAction(
            hasTranscript: true, hasRecording: true,
            hasSummary: false, canSummarize: true, canExport: true
        )
        XCTAssertEqual(action, .summarize)
    }

    func testSummarizeNotChosenWhenCannotSummarize() {
        let action = reviewPrimaryAction(
            hasTranscript: true, hasRecording: true,
            hasSummary: false, canSummarize: false, canExport: true
        )
        XCTAssertEqual(action, .export)
    }

    func testExportWhenSummaryPresent() {
        let action = reviewPrimaryAction(
            hasTranscript: true, hasRecording: true,
            hasSummary: true, canSummarize: true, canExport: true
        )
        XCTAssertEqual(action, .export)
    }

    func testNilWhenNothingActionable() {
        let action = reviewPrimaryAction(
            hasTranscript: true, hasRecording: true,
            hasSummary: true, canSummarize: false, canExport: false
        )
        XCTAssertNil(action)
    }

    func testTranscribeTakesPriorityOverSummarize() {
        // No transcript + recording wins even if a summary path looks available.
        let action = reviewPrimaryAction(
            hasTranscript: false, hasRecording: true,
            hasSummary: false, canSummarize: true, canExport: true
        )
        XCTAssertEqual(action, .transcribe)
    }

    // MARK: - formattedRecordingDuration

    func testFormatSecondsOnly() {
        XCTAssertEqual(TimeInterval(45).formattedRecordingDuration, "45s")
    }

    func testFormatMinutesAndSeconds() {
        XCTAssertEqual(TimeInterval(125).formattedRecordingDuration, "2m 05s")
    }

    func testFormatHoursMinutesSeconds() {
        // 1h 02m 03s = 3723s
        XCTAssertEqual(TimeInterval(3723).formattedRecordingDuration, "1h 02m 03s")
    }

    func testFormatZero() {
        XCTAssertEqual(TimeInterval(0).formattedRecordingDuration, "0s")
    }

    func testFormatNegativeClampsToZero() {
        XCTAssertEqual(TimeInterval(-10).formattedRecordingDuration, "0s")
    }

    func testFormatRoundsToNearestSecond() {
        XCTAssertEqual(TimeInterval(59.6).formattedRecordingDuration, "1m 00s")
    }
}
