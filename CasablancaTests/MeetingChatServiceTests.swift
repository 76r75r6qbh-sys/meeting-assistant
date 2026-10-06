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

    // MARK: - Asking: timeout and retry feedback

    /// Collects what the service was showing at the start of each attempt. A
    /// `@MainActor` class so the stub's main-actor hook can reach it without a lock,
    /// and so it can hold the service the hook has to read.
    @MainActor
    private final class Observer {
        weak var service: MeetingChatService?
        var statusAtEachAttempt: [String?] = []

        func record() {
            statusAtEachAttempt.append(service?.statusMessage)
        }
    }

    private func makeMeeting() -> Meeting {
        let meeting = Meeting(title: "Weekly Sync", date: .now, status: .completed)
        meeting.transcript = "Alice: We ship Friday."
        return meeting
    }

    /// Drains the in-flight answer. `ask` runs in a service-owned task, so the test
    /// has to wait for it rather than assume it finished.
    private func waitForAnswer(_ service: MeetingChatService) async throws {
        for _ in 0..<1000 {
            if !service.isAnswering { return }
            await Task.yield()
        }
        XCTFail("the answer never completed")
    }

    /// The provider's own budget must reach `generate`. The hardcoded 120s here was
    /// chosen for a local model, and for a provider billed per call a timeout costs
    /// `maxAttempts` generations rather than one.
    func testAskUsesTheProvidersPreferredTimeoutWhenItHasOne() async throws {
        let stub = StubLLMProvider(preferredTimeout: 300, outcomes: [.success("Friday.")])
        let service = MeetingChatService(providerFactory: { stub })

        service.ask("When do we ship?", meeting: makeMeeting())
        try await waitForAnswer(service)

        XCTAssertEqual(stub.calls.count, 1)
        XCTAssertEqual(stub.calls.first?.timeout, 300)
    }

    /// A provider without a preference leaves the call site's own number alone.
    func testAskKeepsItsOwnTimeoutForAProviderWithoutAPreference() async throws {
        let stub = StubLLMProvider(preferredTimeout: nil, outcomes: [.success("Friday.")])
        let service = MeetingChatService(providerFactory: { stub })

        service.ask("When do we ship?", meeting: makeMeeting())
        try await waitForAnswer(service)

        XCTAssertEqual(stub.calls.first?.timeout, 120)
    }

    /// Without this the user sees only a spinner while up to three attempts run,
    /// which for a slow provider is minutes of silence with nothing to explain it.
    func testAskSurfacesARetryStatusMessageBetweenAttempts() async throws {
        let observer = Observer()
        let stub = StubLLMProvider(
            displayName: "Claude Code",
            outcomes: [.failure(StubLLMProvider.transientFailure()), .success("Friday.")],
            onGenerate: { [observer] in observer.record() }
        )
        let service = MeetingChatService(
            providerFactory: { stub },
            // No real backoff: the point is the message, not the wait.
            retryPolicy: LLMRetryPolicy(maxAttempts: 3, baseDelay: 0, sleep: { _ in })
        )
        observer.service = service

        service.ask("When do we ship?", meeting: makeMeeting())
        try await waitForAnswer(service)

        XCTAssertEqual(stub.calls.count, 2, "the transient failure should have been retried")
        XCTAssertEqual(
            observer.statusAtEachAttempt,
            [nil, "Claude Code request failed, retrying (2/3)…"],
            "nothing to say on the first attempt; the retry must be visible while it runs"
        )
        // The answer landed, so the transient status must not linger.
        XCTAssertNil(service.statusMessage)
        XCTAssertEqual(service.messages.last?.text, "Friday.")
    }

    /// A failed answer clears the status too, so the error row is not shown beside a
    /// stale "retrying" label.
    func testStatusMessageIsClearedAfterAllAttemptsFail() async throws {
        let stub = StubLLMProvider(outcomes: [.failure(StubLLMProvider.transientFailure())])
        let service = MeetingChatService(
            providerFactory: { stub },
            retryPolicy: LLMRetryPolicy(maxAttempts: 2, baseDelay: 0, sleep: { _ in })
        )

        service.ask("When do we ship?", meeting: makeMeeting())
        try await waitForAnswer(service)

        XCTAssertEqual(stub.calls.count, 2)
        XCTAssertNil(service.statusMessage)
        XCTAssertNotNil(service.errorMessage)
    }

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
