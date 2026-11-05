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
        XCTAssertEqual(LLMPromptSupport.tokenBudget(thinkingEnabled: false), 3500)
        XCTAssertEqual(LLMPromptSupport.tokenBudget(thinkingEnabled: false), LLMPromptSupport.cappedOutputTokens)
    }

    func testTokenBudgetNilWhenThinkingOn() {
        XCTAssertNil(LLMPromptSupport.tokenBudget(thinkingEnabled: true))
    }

    func testSummarizationServiceMaxTokensForwardsToHelper() {
        XCTAssertEqual(SummarizationService.maxSummaryTokens, LLMPromptSupport.cappedOutputTokens)
        XCTAssertEqual(SummarizationService.maxSummaryTokens, 3500)
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

    // MARK: - Budget estimation

    func testBudgetTokensRoundsUpAtThreeCharsPerToken() {
        XCTAssertEqual(LLMPromptSupport.budgetTokens(""), 0)
        XCTAssertEqual(LLMPromptSupport.budgetTokens("abc"), 1)
        XCTAssertEqual(LLMPromptSupport.budgetTokens("abcd"), 2)
        XCTAssertEqual(LLMPromptSupport.budgetTokens(String(repeating: "x", count: 147_000)), 49_000)
    }

    // MARK: - Ollama num_ctx

    /// A full local-budget prompt with the capped summary output still gets the
    /// 16k floor, never Ollama's 2k–4k server default.
    func testOllamaContextHasAFloor() {
        XCTAssertEqual(LLMPromptSupport.ollamaContextTokens(promptChars: 0, maxTokens: nil), 16_384)
        XCTAssertEqual(LLMPromptSupport.ollamaContextTokens(promptChars: 10, maxTokens: 3500), 16_384)
        // 6,000-token prompt + 3,500 output + 1,024 slack = 10,524.
        XCTAssertEqual(LLMPromptSupport.ollamaContextTokens(promptChars: 18_000, maxTokens: 3500), 16_384)
    }

    /// An uncapped call (the terminology echo pass) expects as much output as
    /// input, so the context grows with the prompt.
    func testOllamaContextGrowsForLongUncappedPrompts() {
        // 10,000 + 10,000 + 1,024 = 21,024 → 24,576.
        XCTAssertEqual(LLMPromptSupport.ollamaContextTokens(promptChars: 30_000, maxTokens: nil), 24_576)
    }

    func testOllamaContextIsCapped() {
        // 20,000 + 20,000 + 1,024 = 41,024 → capped.
        XCTAssertEqual(LLMPromptSupport.ollamaContextTokens(promptChars: 60_000, maxTokens: nil), 32_768)
        XCTAssertEqual(LLMPromptSupport.ollamaContextTokens(promptChars: 3, maxTokens: 31_744), 32_768)
        XCTAssertEqual(LLMPromptSupport.ollamaContextTokens(promptChars: 3, maxTokens: 1_000_000), 32_768)
    }

    /// Rounded up to 4,096-token steps so consecutive calls rarely reload the model.
    func testOllamaContextRoundsUpToWholeSteps() {
        // need = 1 + 15,360 + 1,024 = 16,385 → next step.
        XCTAssertEqual(LLMPromptSupport.ollamaContextTokens(promptChars: 3, maxTokens: 15_360), 20_480)
        // need = 1 + 19,455 + 1,024 = 20,480 exactly → unchanged.
        XCTAssertEqual(LLMPromptSupport.ollamaContextTokens(promptChars: 3, maxTokens: 19_455), 20_480)
        // need = 20,481 → next step.
        XCTAssertEqual(LLMPromptSupport.ollamaContextTokens(promptChars: 3, maxTokens: 19_456), 24_576)
    }

    // MARK: - stripReasoningTags

    func testStripReasoningTagsRemovesThinkBlocks() {
        let raw = "<think>plan the notes</think>\n### Decisions\n- [01:02] Ship Friday."
        XCTAssertEqual(LLMPromptSupport.stripReasoningTags(raw), "### Decisions\n- [01:02] Ship Friday.")
    }

    func testStripReasoningTagsRemovesMultipleAndMultilineBlocks() {
        let raw = "<THINK>a\nb</THINK>Notes one.\n<think>\nc\n</think>\nNotes two."
        XCTAssertEqual(LLMPromptSupport.stripReasoningTags(raw), "Notes one.\n\nNotes two.")
    }

    /// Output cut off mid-thought: everything from the unclosed tag on is reasoning.
    func testStripReasoningTagsDropsAnUnterminatedTrailingBlock() {
        let raw = "### Topics discussed\n- Budget\n<think>still reasoning when the limit hit"
        XCTAssertEqual(LLMPromptSupport.stripReasoningTags(raw), "### Topics discussed\n- Budget")
    }

    /// The point of the tag-only variant: notes before a stray `# ` heading
    /// survive, where `stripReasoning`'s heading fallback would discard them.
    func testStripReasoningTagsKeepsContentBeforeAHeading() {
        let raw = "- [00:10] Alice opens the meeting.\n# Budget\n- [00:20] Bob: 40k."
        XCTAssertEqual(LLMPromptSupport.stripReasoningTags(raw), raw)
        XCTAssertNotEqual(LLMPromptSupport.stripReasoning(raw), raw)
    }

    func testStripReasoningTagsOnlyThinkingIsEmpty() {
        XCTAssertEqual(LLMPromptSupport.stripReasoningTags("<think>only this</think>\n  "), "")
    }
}
