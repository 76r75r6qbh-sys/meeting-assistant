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

    /// Input budget, in tokens, for one prompt to a *local* model (Ollama, oMLX):
    /// the `LLMProvider.promptTokenBudget` default. A local context window is
    /// typically ~8k tokens, and this leaves headroom for the model's output.
    /// Large-context providers override it. (Was `defaultTranscriptTokenBudget`.)
    static let localPromptTokenBudget = 6000

    /// Output cap for one map (condense a part) or merge call when thinking is
    /// off: room for compact notes on one part, small enough that a dozen parts
    /// still fit one summary prompt after joining.
    static let mapOutputTokens = 900

    /// Most hierarchical merge levels map-reduce attempts before it falls back to
    /// middle-eliding the joined notes. Each level costs serial model calls.
    static let maxMergeLevels = 3

    /// Overlap between consecutive transcript parts, so a statement split across
    /// a boundary keeps its context in the next part.
    static let summaryOverlapTokens = 200

    /// chars-per-token used for *budget decisions* (does a prompt fit, how big is
    /// a part, how large a context to ask Ollama for). Deliberately more
    /// pessimistic than `charsPerToken`: Dutch text with `[mm:ss]` labels
    /// tokenizes denser than 4 chars/token, and an undercount here means content
    /// silently falls off the front of the model's context window.
    static let budgetCharsPerToken = 3

    /// Pessimistic token estimate for `text` (`ceil(count / budgetCharsPerToken)`).
    static func budgetTokens(_ text: String) -> Int {
        budgetTokens(forCharCount: text.count)
    }

    /// `budgetTokens` for a known character count, so callers that grow a text
    /// line by line (`TranscriptChunker`) need not re-join it per check.
    static func budgetTokens(forCharCount count: Int) -> Int {
        (max(0, count) + budgetCharsPerToken - 1) / budgetCharsPerToken
    }

    /// Smallest `num_ctx` asked of Ollama: a full `localPromptTokenBudget` prompt
    /// plus a `cappedOutputTokens` answer, with room for estimation error.
    static let ollamaMinContextTokens = 16_384
    /// Largest `num_ctx` asked of Ollama, so one oversized prompt cannot make the
    /// server allocate a context the Mac has no memory for.
    static let ollamaMaxContextTokens = 32_768
    /// Step `num_ctx` is rounded up to. Ollama reloads the model whenever
    /// `num_ctx` changes, so coarse steps keep consecutive calls on one size.
    static let ollamaContextStepTokens = 4_096

    /// Headroom added on top of prompt + expected output when sizing a context,
    /// for estimation error.
    static let contextSlackTokens = 1_024

    /// The `num_ctx` to send Ollama for one generate call. Without it Ollama runs
    /// at its server default (2k–4k) and silently drops the head of a longer
    /// prompt. Sized per call — prompt plus expected output (`maxTokens`, or as
    /// much again as the prompt when uncapped, which covers the terminology echo
    /// pass) plus 1,024 slack — rounded up to `ollamaContextStepTokens` and
    /// clamped to [`ollamaMinContextTokens`, `ollamaMaxContextTokens`].
    static func ollamaContextTokens(promptChars: Int, maxTokens: Int?) -> Int {
        let promptTokens = budgetTokens(forCharCount: promptChars)
        let need = promptTokens + (maxTokens ?? promptTokens) + contextSlackTokens
        let step = ollamaContextStepTokens
        let rounded = ((need + step - 1) / step) * step
        return min(ollamaMaxContextTokens, max(ollamaMinContextTokens, rounded))
    }

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
    /// Moved from `SummarizationService.stripReasoning`; the tag handling is
    /// shared with `stripReasoningTags`.
    static func stripReasoning(_ text: String) -> String {
        var s = stripReasoningTags(text)

        // Fallback for models that emit UNTAGGED chain-of-thought before the
        // answer: the structured summary begins at a top-level "# " heading, so
        // if a real heading exists, drop any reasoning preamble before it.
        if let h1 = s.range(of: "(?m)^#[ \\t]+\\S", options: .regularExpression),
           h1.lowerBound != s.startIndex {
            s = String(s[h1.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }

    /// Removes `<think>…</think>` (and `<thinking>…</thinking>`) blocks, plus an
    /// unterminated trailing opening tag and everything after it — and nothing
    /// else. Unlike `stripReasoning` there is no "drop everything before the
    /// first `# ` heading" fallback: intermediate output (condensed transcript
    /// notes) is not a summary, and a stray heading in it would make that
    /// fallback discard real content.
    static func stripReasoningTags(_ text: String) -> String {
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
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
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
