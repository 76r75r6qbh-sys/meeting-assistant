import XCTest
@testable import Casablanca

final class PerMeetingViewStateTests: XCTestCase {
    private let meetingA = UUID()
    private let meetingB = UUID()

    // MARK: - Automatic summary is per meeting

    func testTriggersForATranscribedMeetingWithoutSummary() {
        XCTAssertTrue(AutomaticSummaryTrigger.shouldTrigger(
            meetingID: meetingA, alreadyTriggeredFor: nil, isEnabled: true,
            transcript: "Hello", summary: nil
        ))
    }

    func testDoesNotTriggerTwiceForTheSameMeeting() {
        XCTAssertFalse(AutomaticSummaryTrigger.shouldTrigger(
            meetingID: meetingA, alreadyTriggeredFor: meetingA, isEnabled: true,
            transcript: "Hello", summary: nil
        ))
    }

    /// The reported bug: the detail view is reused across completed meetings,
    /// so having summarized A must not stop B from auto-summarizing.
    func testStillTriggersForMeetingBAfterMeetingA() {
        XCTAssertTrue(AutomaticSummaryTrigger.shouldTrigger(
            meetingID: meetingB, alreadyTriggeredFor: meetingA, isEnabled: true,
            transcript: "Hello", summary: "  "
        ))
    }

    func testDoesNotTriggerWhenDisabledOrNothingToSummarizeOrAlreadySummarized() {
        XCTAssertFalse(AutomaticSummaryTrigger.shouldTrigger(
            meetingID: meetingA, alreadyTriggeredFor: nil, isEnabled: false,
            transcript: "Hello", summary: nil
        ))
        XCTAssertFalse(AutomaticSummaryTrigger.shouldTrigger(
            meetingID: meetingA, alreadyTriggeredFor: nil, isEnabled: true,
            transcript: " \n", summary: nil
        ))
        XCTAssertFalse(AutomaticSummaryTrigger.shouldTrigger(
            meetingID: meetingA, alreadyTriggeredFor: nil, isEnabled: true,
            transcript: "Hello", summary: "Done"
        ))
    }
}
