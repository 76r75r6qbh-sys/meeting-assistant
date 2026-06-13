import XCTest
@testable import Casablanca

@MainActor
final class LLMPromptSupportTests: XCTestCase {

    // MARK: - Thinking soft-switch (matches the previous inline behavior)

    func testApplyThinkingSwitchAppendsNoThinkWhenDisabled() {
        let result = LLMPromptSupport.applyThinkingSwitch(to: "Prompt body", thinkingEnabled: false)
        // Identical to the old `prompt += "\n\n/no_think"`.
        XCTAssertEqual(result, "Prompt body\n\n/no_think")
    }

    func testApplyThinkingSwitchLeavesPromptUnchangedWhenEnabled() {
        let result = LLMPromptSupport.applyThinkingSwitch(to: "Prompt body", thinkingEnabled: true)
        XCTAssertEqual(result, "Prompt body")
    }

    // MARK: - Token budget (matches the previous inline behavior)

    func testTokenBudgetCappedWhenThinkingOff() {
        XCTAssertEqual(LLMPromptSupport.tokenBudget(thinkingEnabled: false), 2000)
        XCTAssertEqual(LLMPromptSupport.tokenBudget(thinkingEnabled: false), LLMPromptSupport.cappedOutputTokens)
    }

    func testTokenBudgetNilWhenThinkingOn() {
        XCTAssertNil(LLMPromptSupport.tokenBudget(thinkingEnabled: true))
    }

    func testSummarizationServiceMaxTokensForwardsToHelper() {
        XCTAssertEqual(SummarizationService.maxSummaryTokens, LLMPromptSupport.cappedOutputTokens)
        XCTAssertEqual(SummarizationService.maxSummaryTokens, 2000)
    }

    // MARK: - stripReasoning parity (forwards to the shared copy)

    func testStripReasoningRemovesThinkTags() {
        let raw = "<think>Let me reason about this...</think>\n# Summary\nAll good."
        XCTAssertEqual(LLMPromptSupport.stripReasoning(raw), "# Summary\nAll good.")
    }

    func testSummarizationServiceStripReasoningMatchesHelper() {
        let raw = "<thinking>noise</thinking>\n# Summary\nDone."
        XCTAssertEqual(
            SummarizationService.stripReasoning(raw),
            LLMPromptSupport.stripReasoning(raw)
        )
    }

    func testStripReasoningDropsUntaggedPreambleBeforeFirstHeading() {
        let raw = """
        Thinking Process:
        1. Analyze.

        # Summary
        Aligned.
        """
        let cleaned = LLMPromptSupport.stripReasoning(raw)
        XCTAssertTrue(cleaned.hasPrefix("# Summary"))
        XCTAssertFalse(cleaned.contains("Thinking Process"))
    }
}
