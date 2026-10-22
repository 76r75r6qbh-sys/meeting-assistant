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

    // MARK: - Editor Stop is per meeting

    /// The reported bug: Stop on A, then the reused editor shows B — B must
    /// not show finalizing chrome, and B's Stop must not be swallowed.
    func testStopOnMeetingADoesNotFinalizeOrBlockMeetingB() {
        var gate = EditorStopGate()
        XCTAssertTrue(gate.begin(meetingA))
        XCTAssertTrue(gate.isFinalizing(meetingA))
        XCTAssertFalse(gate.isFinalizing(meetingB))
        XCTAssertTrue(gate.begin(meetingB), "B's Stop runs while A's is in flight")
        XCTAssertFalse(gate.begin(meetingA), "A double-click on A is ignored")

        gate.end(meetingA)
        XCTAssertFalse(gate.isFinalizing(meetingA))
        XCTAssertTrue(gate.isFinalizing(meetingB))
        gate.end(meetingB)
        XCTAssertEqual(gate, EditorStopGate())
    }
}
