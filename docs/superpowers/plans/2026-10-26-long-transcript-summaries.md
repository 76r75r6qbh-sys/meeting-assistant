# Long-transcript summaries — implementation plan

**Spec:** `docs/superpowers/specs/2026-10-26-long-transcript-summaries-design.md` (binding authority — read the sections named per task)
**Branch:** `76r75r6qbh-sys/long-transcript-summaries`

## Global Constraints

- Swift / SwiftUI macOS app; match surrounding code style and comment density (doc comments explain *why*).
- Full test suite:
  `xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -derivedDataPath .build/test -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''`
  One class: append `-only-testing:CasablancaTests/<ClassName>`.
- `Casablanca.xcodeproj/project.pbxproj` lists every file explicitly (no synchronized groups). A new source file needs a PBXFileReference, PBXBuildFile, group entry and Sources-phase entry — copy the pattern of `SummarizationService.swift` (app target) and `StubLLMProvider.swift` (test target, `path = CasablancaTests/…; sourceTree = SOURCE_ROOT`).
- Exact values: `localPromptTokenBudget = 6000`; Claude CLI `promptTokenBudget = 100_000`; Ollama `num_ctx = min(32_768, max(16_384, roundUp(need, to: 4_096)))` with `need = budgetTokens(prompt) + (maxTokens ?? budgetTokens(prompt)) + 1_024`; `budgetTokens(text) = ceil(text.count / 3)`; chunk size `max(1_000, min(budget - mapPromptOverhead, max(4_000, budget / 2)))`; `overlapTokens = 200`; `mapOutputTokens = 900` (nil when thinking is on); max merge levels `3`. Existing `charsPerToken = 4` stays for chat's elision.
- Output format, `SummaryResponseParser`, to-do creation and export flow must not change.
- Never call a live LLM in tests; use `CasablancaTests/LLM/StubLLMProvider.swift`.
- One commit (or a few) per task, conventional-commit messages ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Do not push, do not open PRs.

## Task 1: Provider-aware budget, Ollama num_ctx, chat, test seams

Spec §1, §2, §2a, §6a, §7.

1. `Casablanca/Services/LLM/LLMPromptSupport.swift`: add `localPromptTokenBudget = 6000`, `budgetCharsPerToken = 3`, `static func budgetTokens(_ text: String) -> Int` (ceil), `static func ollamaContextTokens(promptChars: Int, maxTokens: Int?) -> Int` per spec §2, and `static func stripReasoningTags(_:)` that removes only `<think>…</think>` blocks (and an unterminated trailing `<think>…`) — tag-only, no H1 fallback. Replace `defaultTranscriptTokenBudget` usages with `localPromptTokenBudget` (keep a forwarding alias only if tests reference it).
2. `LLMProvider.swift`: protocol requirement `var promptTokenBudget: Int { get }` with doc comment; extension default = `localPromptTokenBudget`.
3. `ClaudeCLIProvider`: `promptTokenBudget = 100_000` with a why-comment.
4. `OllamaProvider`: add `num_ctx` to `GenerateRequest.Options`; always send options with `numCtx` from `ollamaContextTokens(promptChars: prompt.count, maxTokens: maxTokens)`; temperature/num_predict still omitted when nil. Update the existing test in `OllamaProviderTests.swift` (around line 50) that asserts `options` is nil.
5. `StubLLMProvider`: init param `promptTokenBudget: Int = LLMPromptSupport.localPromptTokenBudget`; per-outcome truncated flag (e.g. outcomes accept a `truncated: Bool` alongside the result — keep existing call sites compiling with a default of false), reported via the `truncated` closure.
6. `MeetingChatService`: call `providerFactory()` before `assemblePrompt` and pass `provider.promptTokenBudget`; `defaultPromptTokenBudget` becomes `LLMPromptSupport.localPromptTokenBudget`.
7. `SummarizationService`:
   - read template, terminology settings and thinking flag from `self.userDefaults` (not `UserDefaults.standard`) — check what `LLMPromptSupport.thinkingEnabled()` / `TerminologyService.renderTerminologyBlock` read and give them a defaults parameter if needed, keeping other callers' behaviour;
   - inject `retryPolicy: LLMRetryPolicy` via init (default `LLMRetryPolicy()`), mirroring `MeetingChatService`;
   - obtain the provider before truncation and truncate against `provider.promptTokenBudget` (interim; Task 3 replaces it).

Tests: capability tests (Claude 100_000; Ollama/oMLX 6_000); `ollamaContextTokens` floor/growth/cap/rounding; Ollama body always has `options.num_ctx`; `stripReasoningTags` cases; chat with a large-budget stub doesn't elide what a 6_000 budget would; summarization with a 100_000-budget stub passes a 147_000-char transcript whole with no warning.

## Task 2: TranscriptChunker

Spec §4 "Chunking". New file `Casablanca/Services/TranscriptChunker.swift`, Foundation only, pure:

```swift
struct TranscriptChunk: Equatable {
    let index: Int            // 0-based
    let text: String
    let startLabel: String?   // first "[mm:ss]" / "[h:mm:ss]" label in the chunk, without brackets
    let endLabel: String?     // last such label
}

enum TranscriptChunker {
    static func chunks(of transcript: String, chunkTokens: Int, overlapTokens: Int) -> [TranscriptChunk]
}
```

Rules: token estimate = `LLMPromptSupport.budgetTokens`; split on `\n` line boundaries; a chunk (incl. its overlap prefix) totals ≤ `chunkTokens`; each chunk after the first begins with the trailing whole lines of the previous chunk totalling ≤ `overlapTokens` (zero lines if the last line alone exceeds it); a single line over `chunkTokens` is hard-split at the last whitespace before the limit, or at the limit if none; empty/whitespace-only → `[]`; input within budget → one chunk equal to the trimmed input; labels match `^\[(\d{1,2}:)?\d{1,2}:\d{2}\]` at line start; always makes progress (no infinite loop when overlap ≥ chunk); deterministic.

Tests `CasablancaTests/TranscriptChunkerTests.swift`: empty; small → 1 chunk; long timestamped transcript → every chunk ≤ budget and the non-overlap parts reconstruct all lines in order; overlap present and ≤ overlapTokens; oversized line split; labels incl. `1:02:03`; no-timestamp → nil labels; overlap ≥ chunk terminates.

## Task 3: Map-reduce summarization with progress

Spec §3–§6, §8. Depends on Tasks 1–2.

In `SummarizationService`:
1. Single pass when `budgetTokens(transcript) + overhead ≤ provider.promptTokenBudget` (overhead = `budgetTokens(renderPrompt(... transcript: ""))`): whole transcript, no warning.
2. Otherwise map-reduce per spec §4: chunk size per Global Constraints; map prompt text verbatim from the spec, placeholders filled (part/total 1-based; start/end labels or `?`; title; participants or `Unknown`; note-taker line `The note-taker is <name>.` or empty; terminology block); `maxTokens` = `mapOutputTokens` or nil when thinking on; apply `applyThinkingSwitch`; strip with `stripReasoningTags`; empty after strip → throw `emptyResponse`; record truncation → output-limit warning; timeout `provider.timeout(orDefault: 120)`.
3. Reduce: join per spec (`## Part i/N (start–end)` headings, preamble line verbatim), render with the user's template via `renderPrompt`, then the existing generate/parse path.
4. Hierarchical merge per spec (group by merge overhead, single-note groups pass through, max 3 levels, stop when no reduction), then fallback middle-elide to `budget - overhead` with the warning text verbatim: "The meeting was too long to summarize fully; some middle sections were shortened."
5. Retry/cancellation/cache per spec §5 (Hashable struct key, SHA-256 via CryptoKit; cache replaced when a different meeting starts; cleared on success).
6. Phases `.condensing(part:of:)` / `.merging(level:)` with `statusMessage` strings verbatim from spec §6; re-set the step phase before each step and after each successful call; final reduce uses `.sending`. Map both new phases in `MeetingPipelinePresentation.statusText` (`Casablanca/Services/MeetingPipelineState.swift`) to the same strings; add `MeetingPipelineStateTests` cases.
7. Prompt builders (map, merge, reduce-join) as `static` funcs for testability.

Tests in `SummarizationServiceTests` per spec "Testing" (all SummarizationService bullets), with a small-budget stub (e.g. 1_500), canned outcomes, injected no-sleep retry policy and an isolated `UserDefaults` suite; `onGenerate` to capture phases.
