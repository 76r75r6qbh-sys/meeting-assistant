import XCTest
@testable import Casablanca

/// The "Regenerate summary" offer after a speaker is renamed or merged
/// (Task 2.2): when it appears, when it is hidden, and what a regenerate asks
/// the summarizer for. Never regenerates by itself.
@MainActor
final class SummaryRegenerationOfferTests: XCTestCase {
    private func makeMeeting(summary: String? = "# Summary\nDone.", templateID: String? = nil) -> Meeting {
        let meeting = Meeting(title: "Sync", date: Date(timeIntervalSince1970: 1_700_000_000), status: .completed)
        meeting.transcript = "[00:10] Kim: Ik mail de offerte."
        meeting.summary = summary
        meeting.summaryTemplateID = templateID
        return meeting
    }

    func testNoOfferBeforeAnySpeakerChange() {
        let offer = SummaryRegenerationOffer()
        XCTAssertFalse(offer.offerRegenerateSummary(for: makeMeeting(), isSummarizing: false))
    }

    func testSpeakerChangeOnASummarizedMeetingOffers() {
        let meeting = makeMeeting()
        var offer = SummaryRegenerationOffer()

        offer.speakersChanged(on: meeting, isSummarizingThisMeeting: false)

        XCTAssertTrue(offer.offerRegenerateSummary(for: meeting, isSummarizing: false))
    }

    func testSpeakerChangeWithoutASummaryDoesNotOffer() {
        for summary in [nil, "", "  \n"] as [String?] {
            let meeting = makeMeeting(summary: summary)
            var offer = SummaryRegenerationOffer()

            offer.speakersChanged(on: meeting, isSummarizingThisMeeting: false)

            XCTAssertFalse(offer.offerRegenerateSummary(for: meeting, isSummarizing: false))
        }
    }

    /// The running summary read the transcript before the rename, so once it
    /// lands it carries the old names: the offer waits and shows afterwards.
    func testSpeakerChangeDuringThisMeetingsFirstSummaryOffersOnceItLands() {
        let meeting = makeMeeting(summary: nil)
        var offer = SummaryRegenerationOffer()

        offer.speakersChanged(on: meeting, isSummarizingThisMeeting: true)
        XCTAssertFalse(offer.offerRegenerateSummary(for: meeting, isSummarizing: true), "hidden while a summary runs")

        meeting.summary = "# Summary\nSpreker 1 mails."
        XCTAssertTrue(offer.offerRegenerateSummary(for: meeting, isSummarizing: false))
    }

    func testHiddenWhileASummaryIsRunning() {
        let meeting = makeMeeting()
        var offer = SummaryRegenerationOffer()
        offer.speakersChanged(on: meeting, isSummarizingThisMeeting: false)

        XCTAssertFalse(offer.offerRegenerateSummary(for: meeting, isSummarizing: true))
        XCTAssertTrue(offer.offerRegenerateSummary(for: meeting, isSummarizing: false), "back once it is done")
    }

    func testDismissClearsTheOffer() {
        let meeting = makeMeeting()
        var offer = SummaryRegenerationOffer()
        offer.speakersChanged(on: meeting, isSummarizingThisMeeting: false)

        offer.dismiss(meeting)

        XCTAssertFalse(offer.offerRegenerateSummary(for: meeting, isSummarizing: false))
    }

    func testRegenerateUsesTheExplicitTemplateAndClearsTheOffer() {
        for templateID in [nil, "workshop"] as [String?] {
            let meeting = makeMeeting(templateID: templateID)
            var offer = SummaryRegenerationOffer()
            offer.speakersChanged(on: meeting, isSummarizingThisMeeting: false)
            var requested: [String?] = []

            offer.regenerate(meeting) { requested.append($0) }

            XCTAssertEqual(requested, [templateID], "nil means auto")
            XCTAssertFalse(offer.offerRegenerateSummary(for: meeting, isSummarizing: false))
        }
    }

    /// Any new summary of the meeting (template menu, retry) answers the offer.
    func testAnyNewSummaryOfTheMeetingClearsTheOffer() {
        let meeting = makeMeeting()
        var offer = SummaryRegenerationOffer()
        offer.speakersChanged(on: meeting, isSummarizingThisMeeting: false)

        offer.summaryStarted(for: meeting.id)

        XCTAssertFalse(offer.offerRegenerateSummary(for: meeting, isSummarizing: false))
    }

    /// The detail view is reused across meetings: an offer belongs to its own
    /// meeting and survives navigating to another one and back.
    func testOffersArePerMeeting() {
        let a = makeMeeting()
        let b = makeMeeting()
        var offer = SummaryRegenerationOffer()

        offer.speakersChanged(on: a, isSummarizingThisMeeting: false)
        XCTAssertFalse(offer.offerRegenerateSummary(for: b, isSummarizing: false))

        offer.speakersChanged(on: b, isSummarizingThisMeeting: false)
        offer.dismiss(b)
        offer.summaryStarted(for: b.id)
        XCTAssertTrue(offer.offerRegenerateSummary(for: a, isSummarizing: false))
    }
}
