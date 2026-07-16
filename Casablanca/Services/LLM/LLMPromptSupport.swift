import Foundation

/// Shared helpers for talking to the local LLM that are NOT specific to any one
/// feature. Extracted from `SummarizationService` so the summary flow, the prep
/// drafter, and the meeting-chat flow share ONE copy of the thinking-mode
/// handling (the `/no_think` soft-switch, the thinking-dependent token budget)
/// and the chain-of-thought stripping. Behavior is identical to the previous
/// inline logic — these are pure, side-effect-free string helpers.
enum LLMPromptSupport {
    /// Upper bound on generated tokens when thinking is OFF. Local reasoning
    /// models can otherwise ramble or loop for thousands of tokens on a short
    /// input, so we cap output as a safety net. Raised from 2000 to 3500 to give
    /// the richer structured summary (Pocket-style template with four mandatory
    /// closing sections) enough headroom — truncation at the old limit ate the
    /// closing sections (action items, follow-ups) first. (Was
    /// `SummarizationService.maxSummaryTokens`.)
    static let cappedOutputTokens = 3500

    /// The Qwen-family soft-switch that disables out-loud reasoning, appended to
    /// the prompt when thinking is off.
    static let noThinkSuffix = "/no_think"

    /// Appends the `/no_think` soft-switch to `prompt` when thinking is disabled.
    /// When thinking is enabled the prompt is returned unchanged (the provider
    /// also flips its native thinking switch via `enableThinking`).
    ///
    /// Matches the previous inline behavior exactly: `prompt + "\n\n/no_think"`.
    static func applyThinkingSwitch(to prompt: String, thinkingEnabled: Bool) -> String {
        guard !thinkingEnabled else { return prompt }
        return prompt + "\n\n" + noThinkSuffix
    }

    /// The output token budget for a generation. Thinking on → `nil` (uncapped,
    /// the user opted in and the reasoning needs room); thinking off → a tight
    /// cap as the safety net.
    static func tokenBudget(thinkingEnabled: Bool) -> Int? {
        thinkingEnabled ? nil : cappedOutputTokens
    }

    /// Reads the user's thinking preference from defaults.
    static func thinkingEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: AppPreferenceKey.summaryThinkingEnabled)
    }

    /// Removes chain-of-thought blocks reasoning models emit before their answer
    /// (e.g. `<think>…</think>` / `<thinking>…</thinking>`), so they don't end up
    /// in stored output. Handles an unclosed tag (output cut mid-thought) by
    /// dropping from the opening tag onward.
    ///
    /// Moved verbatim from `SummarizationService.stripReasoning`.
    static func stripReasoning(_ text: String) -> String {
        var s = text
        for tag in ["think", "thinking"] {
            s = s.replacingOccurrences(
                of: "(?is)<\(tag)>.*?</\(tag)>",
                with: "",
                options: .regularExpression
            )
            if let open = s.range(of: "<\(tag)>", options: .caseInsensitive) {
                s = String(s[..<open.lowerBound])
            }
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)

        // Fallback for models that emit UNTAGGED chain-of-thought before the
        // answer: the structured summary begins at a top-level "# " heading, so
        // if a real heading exists, drop any reasoning preamble before it.
        if let h1 = s.range(of: "(?m)^#[ \\t]+\\S", options: .regularExpression),
           h1.lowerBound != s.startIndex {
            s = String(s[h1.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }
}
