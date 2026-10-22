import XCTest
@testable import Casablanca

final class SidebarPipelineIndicatorTests: XCTestCase {
    private let meetingID = UUID()

    private func indicator(
        status: MeetingStatus,
        isTranscribing: Bool = false,
        summarizingMeetingID: UUID? = nil
    ) -> MeetingPipelinePresentation? {
        SidebarPipelineIndicator.presentation(
            meetingID: meetingID,
            status: status,
            isTranscribing: isTranscribing,
            summarizingMeetingID: summarizingMeetingID,
            summarizationPhase: summarizingMeetingID == nil ? .idle : .sending,
            summarizationStartedAt: nil
        )
    }

    /// Resting rows get no presentation, so nothing about them (and in
    /// particular none of their unfetched heavy columns) is consulted.
    func testRestingMeetingsGetNoPresentation() {
        for status in [MeetingStatus.completed, .notesOnly, .upcoming, .recording, .pausedRecording] {
            XCTAssertNil(indicator(status: status), "\(status) should show its plain status icon")
        }
        XCTAssertNil(indicator(status: .completed, summarizingMeetingID: UUID()),
                     "another meeting's summary must not mark this row")
    }

    func testTranscribingMeetingIsActive() {
        let presentation = indicator(status: .processing, isTranscribing: true)
        XCTAssertEqual(presentation?.isActive, true)
    }

    func testMeetingBeingSummarizedIsActive() {
        let presentation = indicator(status: .completed, summarizingMeetingID: meetingID)
        XCTAssertEqual(presentation?.isActive, true)
    }

    /// Same as before the change: `.processing` with nothing running is a
    /// stale transcription and shows the error glyph.
    func testStaleProcessingMeetingShowsAnError() {
        let presentation = indicator(status: .processing, isTranscribing: false)
        XCTAssertEqual(presentation?.isActive, false)
        XCTAssertEqual(presentation?.hasError, true)
    }
}
