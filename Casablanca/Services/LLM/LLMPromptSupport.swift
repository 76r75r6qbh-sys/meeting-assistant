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

    /// chars-per-token heuristic. No real tokenizer exists in the app; 4 chars ≈
    /// 1 token is the standard rough estimate for English/Dutch text and is good
    /// enough to keep a prompt inside the model's context window. (Was
    /// `MeetingChatService.charsPerToken`.)
    static let charsPerToken = 4

    /// Conservative token budget for a transcript being inlined whole into a
    /// prompt (terminology correction, summarization, chat). Shared across all
    /// three so a transcript is never sent unbounded — a large local context
    /// window is typically ~8k tokens, and this leaves headroom for the rest of
    /// the prompt plus the model's output.
    static let defaultTranscriptTokenBudget = 6000

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

    /// Keeps the head and tail of `text`, eliding the middle with a marker, so
    /// the result fits within `budget` characters. The opening and closing of a
    /// transcript usually carry the most context (agenda + wrap-up), so a middle
    /// elision preserves more signal than a tail cut.
    ///
    /// Moved verbatim from `MeetingChatService.middleElide` so terminology
    /// correction and summarization can share it instead of sending an
    /// unbounded transcript.
    static func middleElide(_ text: String, toCharBudget budget: Int) -> String {
        guard text.count > budget else { return text }
        let marker = "\n\n[… transcript truncated to fit context window …]\n\n"
        guard budget > marker.count else {
            // Not even room for the marker — return a hard prefix.
            return String(text.prefix(max(0, budget)))
        }
        let keep = budget - marker.count
        let headLen = keep / 2
        let tailLen = keep - headLen
        let head = text.prefix(headLen)
        let tail = text.suffix(tailLen)
        return head + marker + tail
    }

    /// Middle-elides `text` to fit within `tokenBudget` tokens (via
    /// `charsPerToken`). Returns the possibly-shortened text and whether
    /// truncation happened, so callers can warn the user when a very long
    /// transcript had to be shortened before being sent to the model.
    static func truncated(_ text: String, toFitTokenBudget tokenBudget: Int) -> (text: String, wasTruncated: Bool) {
        let budgetChars = max(0, tokenBudget) * charsPerToken
        guard text.count > budgetChars else { return (text, false) }
        return (middleElide(text, toCharBudget: budgetChars), true)
    }
}
