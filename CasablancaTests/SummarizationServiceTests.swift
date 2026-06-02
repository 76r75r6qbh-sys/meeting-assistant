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
}
