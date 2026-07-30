import XCTest
@testable import Casablanca

@MainActor
final class SummarizationServiceTests: XCTestCase {
    func testDefaultPromptTemplateIncludesTranscriptAndFreeformNotes() {
        let template = SummarizationService.defaultPromptTemplate

        XCTAssertTrue(template.contains("Transcript:"))
        XCTAssertTrue(template.contains("{{transcript}}"))
        XCTAssertTrue(template.contains("Freeform notes:"))
        XCTAssertTrue(template.contains("{{freeform_notes}}"))
    }

    // MARK: - Pocket-style template placeholders

    func testDefaultPromptTemplateContainsParticipantsPlaceholder() {
        let template = SummarizationService.defaultPromptTemplate
        XCTAssertTrue(template.contains("{{participants}}"), "Template must include {{participants}} placeholder")
    }

    func testDefaultPromptTemplateContainsTerminologyListPlaceholder() {
        let template = SummarizationService.defaultPromptTemplate
        XCTAssertTrue(template.contains("{{terminology_list}}"), "Template must include {{terminology_list}} placeholder")
    }

    func testDefaultPromptTemplateContainsDutchClosingHeadings() {
        let template = SummarizationService.defaultPromptTemplate
        XCTAssertTrue(template.contains("Besluiten"), "Template must reference Dutch heading 'Besluiten'")
        XCTAssertTrue(template.contains("Actiepunten"), "Template must reference Dutch heading 'Actiepunten'")
        XCTAssertTrue(template.contains("Risico"), "Template must reference Dutch heading 'Risico's en blockers'")
        XCTAssertTrue(template.contains("Opvolging"), "Template must reference Dutch heading 'Opvolging'")
    }

    func testDefaultPromptTemplateContainsEnglishClosingHeadings() {
        let template = SummarizationService.defaultPromptTemplate
        XCTAssertTrue(template.contains("Decisions"), "Template must reference English heading 'Decisions'")
        XCTAssertTrue(template.contains("Action Items"), "Template must reference English heading 'Action Items'")
        XCTAssertTrue(template.contains("Risks and Blockers"), "Template must reference English heading 'Risks and Blockers'")
        XCTAssertTrue(template.contains("Follow-ups"), "Template must reference English heading 'Follow-ups'")
    }

    // MARK: - renderPrompt participants injection

    func testRenderPromptSubstitutesParticipantsWhenPresent() {
        let meeting = Meeting(
            title: "Sprint Review",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            participants: ["Alice", "Bob", "Carol"]
        )
        let rendered = SummarizationService.renderPrompt(
            template: "Participants: {{participants}}",
            meeting: meeting,
            transcript: "",
            freeformNotes: "",
            terminologyBlock: ""
        )
        XCTAssertTrue(rendered.contains("Alice, Bob, Carol"), "renderPrompt must join participants with ', '")
        XCTAssertFalse(rendered.contains("{{participants}}"), "renderPrompt must replace {{participants}} placeholder")
    }

    func testRenderPromptSubstitutesUnknownWhenParticipantsEmpty() {
        let meeting = Meeting(
            title: "Quick Sync",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            participants: []
        )
        let rendered = SummarizationService.renderPrompt(
            template: "Participants: {{participants}}",
            meeting: meeting,
            transcript: "",
            freeformNotes: "",
            terminologyBlock: ""
        )
        XCTAssertTrue(rendered.contains("Unknown"), "renderPrompt must use 'Unknown' when participants list is empty")
        XCTAssertFalse(rendered.contains("{{participants}}"), "renderPrompt must replace {{participants}} placeholder")
    }

    func testRenderPromptSubstitutesTranscriptAndFreeformNotes() {
        let meeting = Meeting(title: "Design Review", date: Date(timeIntervalSince1970: 1_700_000_000))
        let rendered = SummarizationService.renderPrompt(
            template: SummarizationService.defaultPromptTemplate,
            meeting: meeting,
            transcript: "Transcript body",
            freeformNotes: "Freeform notes body",
            terminologyBlock: ""
        )

        XCTAssertTrue(rendered.contains("Transcript:\nTranscript body"))
        XCTAssertTrue(rendered.contains("Freeform notes:\nFreeform notes body"))
    }

    func testStripReasoningRemovesThinkTags() {
        let raw = "<think>Let me reason about this...</think>\n# Summary\nAll good."
        let cleaned = SummarizationService.stripReasoning(raw)
        XCTAssertEqual(cleaned, "# Summary\nAll good.")
    }

    func testStripReasoningDropsUntaggedPreambleBeforeFirstHeading() {
        let raw = """
        Thinking Process:
        1. Analyze the request.
        2. Draft the sections.
        Wait, let me reconsider the time.

        # Summary
        The team aligned on the plan.

        ## Decisions
        - Ship Friday
        """
        let cleaned = SummarizationService.stripReasoning(raw)
        XCTAssertTrue(cleaned.hasPrefix("# Summary"))
        XCTAssertFalse(cleaned.contains("Thinking Process"))
        XCTAssertTrue(cleaned.contains("## Decisions"))
    }

    func testStripReasoningLeavesCleanOutputUnchanged() {
        let raw = "# Summary\nDone.\n## Action Items\n- Send notes"
        XCTAssertEqual(SummarizationService.stripReasoning(raw), raw)
    }

    // MARK: - Generation timeout

    private func makeMeeting() -> Meeting {
        let meeting = Meeting(title: "Weekly Sync", date: .now, status: .completed)
        meeting.transcript = "Alice: We ship Friday. Bob: Agreed."
        return meeting
    }

    /// The 120s at this call site was chosen for a local model. A provider that pays
    /// a network round trip per call states its own budget, and it has to arrive —
    /// this generation is wrapped in `LLMRetryPolicy`, so a timeout that fires costs
    /// three billed generations instead of one slow success.
    func testSummarizeUsesTheProvidersPreferredTimeoutWhenItHasOne() async throws {
        let stub = StubLLMProvider(preferredTimeout: 300, outcomes: [.success("# Summary\nWe ship Friday.")])
        let service = SummarizationService(providerFactory: { stub })

        _ = try await service.summarize(meeting: makeMeeting())

        XCTAssertEqual(stub.calls.count, 1)
        XCTAssertEqual(stub.calls.first?.timeout, 300)
    }

    /// A local provider keeps the call site's own number, so nothing changes for it.
    func testSummarizeKeepsItsOwnTimeoutForAProviderWithoutAPreference() async throws {
        let stub = StubLLMProvider(preferredTimeout: nil, outcomes: [.success("# Summary\nWe ship Friday.")])
        let service = SummarizationService(providerFactory: { stub })

        _ = try await service.summarize(meeting: makeMeeting())

        XCTAssertEqual(stub.calls.first?.timeout, 120)
    }
}
