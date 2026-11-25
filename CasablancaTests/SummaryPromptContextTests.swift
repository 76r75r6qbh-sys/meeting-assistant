import XCTest
@testable import Casablanca

final class SummaryPromptContextTests: XCTestCase {
    // MARK: - Participants line

    func testParticipantsMarkUserByAliasAndAddEmails() {
        let line = SummaryPromptContext.participantsLine(
            participants: ["Kim Hartman-Lee", "Joris Verbeek"],
            attendees: [MeetingAttendee(name: "Kim Hartman-Lee", email: "kim@partner.example", isCurrentUser: false)],
            userAliases: ["Joris"]
        )
        XCTAssertEqual(line, "Kim Hartman-Lee <kim@partner.example>, Joris Verbeek (me)")
    }

    func testParticipantsMarkCurrentUserAttendee() {
        let line = SummaryPromptContext.participantsLine(
            participants: ["Kim"],
            attendees: [MeetingAttendee(name: "Y. Verbeek", email: "joris@example.com", isCurrentUser: true)],
            userAliases: ["Joris"]
        )
        XCTAssertEqual(line, "Kim, Y. Verbeek (me) <joris@example.com>")
    }

    func testParticipantsAppendUserWhenUnmarked() {
        let line = SummaryPromptContext.participantsLine(
            participants: ["Kim"],
            attendees: [],
            userAliases: ["Joris"]
        )
        XCTAssertEqual(line, "Kim, Joris (me)")
    }

    func testEmptyParticipantsStayUnknown() {
        let line = SummaryPromptContext.participantsLine(participants: [], attendees: [], userAliases: ["Joris"])
        XCTAssertEqual(line, "Unknown")
    }

    func testAttendeeNameMatchIsCaseAndDiacriticInsensitive() {
        let line = SummaryPromptContext.participantsLine(
            participants: ["  Rene Hoekstra ", ""],
            attendees: [
                MeetingAttendee(name: "rené hoekstra", email: "rene@example.nl", isCurrentUser: false),
                MeetingAttendee(name: "", email: "room@example.nl", isCurrentUser: false)
            ],
            userAliases: []
        )
        XCTAssertEqual(line, "Rene Hoekstra <rene@example.nl>, room@example.nl")
    }

    // MARK: - Focus block

    func testFocusBlockTrimsPrepBeforeNotes() {
        let prep = String(repeating: "p", count: 3_000)
        let notes = String(repeating: "n", count: 300)

        let block = SummaryPromptContext.focusBlock(prep: prep, notes: notes, maxTokens: 400)

        XCTAssertLessThanOrEqual(LLMPromptSupport.budgetTokens(block), 400)
        XCTAssertTrue(block.contains("User notes:\n" + notes))
        let prepPart = try? XCTUnwrap(block.components(separatedBy: "\nUser notes:\n").first)
        XCTAssertTrue(prepPart?.hasSuffix("…") ?? false, "the prep is cut at its tail with an ellipsis")
        XCTAssertTrue(block.hasPrefix("What the user cares about"))
    }

    func testFocusBlockEmptyWhenNothingGiven() {
        XCTAssertEqual(SummaryPromptContext.focusBlock(prep: nil, notes: "  ", maxTokens: 400), "")
    }

    func testFocusBlockExactCopy() {
        let block = SummaryPromptContext.focusBlock(prep: " Vraag naar budget \n", notes: "Kim twijfelt", maxTokens: 400)
        XCTAssertEqual(block, """
        What the user cares about (their prep and own notes for this meeting — use it to decide what matters, but only report what the transcript or notes support):
        Prep:
        Vraag naar budget
        User notes:
        Kim twijfelt
        """)
    }

    func testFocusBlockOmitsEmptyPart() {
        let block = SummaryPromptContext.focusBlock(prep: "Vraag naar budget", notes: nil, maxTokens: 400)
        XCTAssertTrue(block.hasSuffix("support):\nPrep:\nVraag naar budget"))
        XCTAssertFalse(block.contains("User notes:"))
    }

    func testFocusBlockCutsNotesOnceThePrepIsGone() {
        let notes = String(repeating: "n", count: 3_000)
        let block = SummaryPromptContext.focusBlock(prep: String(repeating: "p", count: 3_000), notes: notes, maxTokens: 200)
        XCTAssertLessThanOrEqual(LLMPromptSupport.budgetTokens(block), 200)
        XCTAssertFalse(block.contains("Prep:"))
        XCTAssertTrue(block.hasSuffix("…"))
    }
}
