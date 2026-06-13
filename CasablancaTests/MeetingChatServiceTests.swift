import XCTest
@testable import Casablanca

@MainActor
final class MeetingChatServiceTests: XCTestCase {

    // MARK: - Prompt assembly: under budget keeps the full transcript

    func testAssemblePromptUnderBudgetIncludesFullTranscript() {
        let transcript = "Alice: Let's ship Friday.\nBob: Agreed."
        let prompt = MeetingChatService.assemblePrompt(
            summary: "We agreed to ship.",
            notes: "Remember to tell QA.",
            transcript: transcript,
            history: [],
            question: "When do we ship?",
            tokenBudget: 6000
        )

        XCTAssertTrue(prompt.contains(MeetingChatService.systemFraming))
        XCTAssertTrue(prompt.contains("We agreed to ship."))
        XCTAssertTrue(prompt.contains("Remember to tell QA."))
        XCTAssertTrue(prompt.contains(transcript), "Full transcript should be present under budget")
        XCTAssertTrue(prompt.contains("When do we ship?"))
        XCTAssertFalse(prompt.contains("transcript truncated"))
    }

    // MARK: - Prompt assembly: over budget truncates only the transcript

    func testAssemblePromptOverBudgetTruncatesTranscriptKeepsEverythingElse() {
        let summary = "SUMMARY-MARKER agreed to ship."
        let notes = "NOTES-MARKER tell QA."
        // Large transcript with distinct head + tail markers we can assert on.
        let head = "HEAD-MARKER " + String(repeating: "a", count: 2000)
        let tail = String(repeating: "b", count: 2000) + " TAIL-MARKER"
        let transcript = head + tail

        let history = [
            ChatMessage(role: .user, text: "HISTORY-USER-MARKER earlier question?"),
            ChatMessage(role: .assistant, text: "HISTORY-ASSISTANT-MARKER earlier answer.")
        ]
        let question = "QUESTION-MARKER latest?"

        // Tight budget forces transcript truncation but leaves room for fixed parts.
        let budget = (MeetingChatService.systemFraming.count
            + summary.count + notes.count
            + history.reduce(0) { $0 + $1.text.count }
            + question.count
            + 600) / MeetingChatService.charsPerToken

        let prompt = MeetingChatService.assemblePrompt(
            summary: summary,
            notes: notes,
            transcript: transcript,
            history: history,
            question: question,
            tokenBudget: budget
        )

        // Fixed parts are all intact.
        XCTAssertTrue(prompt.contains("SUMMARY-MARKER"))
        XCTAssertTrue(prompt.contains("NOTES-MARKER"))
        XCTAssertTrue(prompt.contains("HISTORY-USER-MARKER"))
        XCTAssertTrue(prompt.contains("HISTORY-ASSISTANT-MARKER"))
        XCTAssertTrue(prompt.contains("QUESTION-MARKER"))

        // Transcript was truncated (middle elided): head + tail survive, marker present.
        XCTAssertTrue(prompt.contains("transcript truncated"), "Expected an elision marker")
        XCTAssertTrue(prompt.contains("HEAD-MARKER"), "Head of transcript should survive")
        XCTAssertTrue(prompt.contains("TAIL-MARKER"), "Tail of transcript should survive")
        XCTAssertFalse(prompt.contains(transcript), "Full transcript should NOT be present over budget")

        // The whole prompt stays within the char budget (approximately — the
        // marker itself adds a few chars, so allow a small slack).
        XCTAssertLessThanOrEqual(
            prompt.count,
            budget * MeetingChatService.charsPerToken + 64
        )
    }

    // MARK: - Prompt assembly: empty content

    func testAssemblePromptEmptyContentOmitsSectionsButKeepsQuestion() {
        let prompt = MeetingChatService.assemblePrompt(
            summary: "",
            notes: "",
            transcript: "",
            history: [],
            question: "Anything happen?",
            tokenBudget: 6000
        )

        XCTAssertTrue(prompt.contains(MeetingChatService.systemFraming))
        XCTAssertTrue(prompt.contains("Anything happen?"))
        XCTAssertFalse(prompt.contains("## Meeting summary"))
        XCTAssertFalse(prompt.contains("## User notes"))
        XCTAssertFalse(prompt.contains("## Transcript"))
        XCTAssertFalse(prompt.contains("## Previous Q&A"))
    }

    // MARK: - Prompt assembly: fixed parts exceed budget → transcript omitted

    func testAssemblePromptTinyBudgetOmitsTranscriptEntirely() {
        let prompt = MeetingChatService.assemblePrompt(
            summary: "Summary text here.",
            notes: "Notes text here.",
            transcript: String(repeating: "z", count: 500),
            history: [],
            question: "Q?",
            tokenBudget: 1 // far below the fixed parts
        )

        XCTAssertTrue(prompt.contains("Transcript omitted"))
        XCTAssertFalse(prompt.contains(String(repeating: "z", count: 500)))
        XCTAssertTrue(prompt.contains("Q?"))
    }

    // MARK: - History rendering

    func testRenderHistoryEmptyIsEmptyString() {
        XCTAssertEqual(MeetingChatService.renderHistory([]), "")
    }

    func testRenderHistoryLabelsSpeakers() {
        let rendered = MeetingChatService.renderHistory([
            ChatMessage(role: .user, text: "Hi"),
            ChatMessage(role: .assistant, text: "Hello")
        ])
        XCTAssertTrue(rendered.contains("User: Hi"))
        XCTAssertTrue(rendered.contains("Assistant: Hello"))
        XCTAssertTrue(rendered.contains("## Previous Q&A"))
    }

    // MARK: - middleElide

    func testMiddleElideUnderBudgetReturnsUnchanged() {
        let text = "short text"
        XCTAssertEqual(MeetingChatService.middleElide(text, toCharBudget: 1000), text)
    }

    func testMiddleElideKeepsHeadAndTail() {
        let text = String(repeating: "H", count: 100) + String(repeating: "T", count: 100)
        let elided = MeetingChatService.middleElide(text, toCharBudget: 120)
        XCTAssertTrue(elided.hasPrefix("H"))
        XCTAssertTrue(elided.hasSuffix("T"))
        XCTAssertTrue(elided.contains("truncated"))
        XCTAssertLessThan(elided.count, text.count)
    }

    // MARK: - Conversation state

    func testActivateClearsHistoryOnMeetingChange() {
        let service = MeetingChatService()
        let a = UUID()
        let b = UUID()
        service.activate(meetingID: a)
        XCTAssertEqual(service.currentMeetingID, a)
        // Activating the same meeting is a no-op.
        service.activate(meetingID: a)
        XCTAssertEqual(service.currentMeetingID, a)
        // Switching changes the active meeting (and would clear history).
        service.activate(meetingID: b)
        XCTAssertEqual(service.currentMeetingID, b)
        XCTAssertTrue(service.messages.isEmpty)
    }
}
