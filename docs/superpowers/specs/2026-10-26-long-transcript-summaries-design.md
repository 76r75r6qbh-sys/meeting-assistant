# Long-transcript summaries — design

**Date:** 2026-10-26
**Status:** Youri asked to build the long-transcript fix (chat, 2026-10-26); this design was reviewed by a subagent, not individually approved.

## Problem

`SummarizationService.summarize` middle-elides every transcript to
`LLMPromptSupport.defaultTranscriptTokenBudget` (6,000 tokens × 4 chars =
24,000 chars) before summarizing, regardless of provider. A 2.5-hour meeting
(147,704 chars, ~37k tokens) loses ~84 % of its content: only the first and
last ~12k chars reach the model. The budget exists for local models (Ollama /
oMLX with ~8k context) but is also applied to the Claude Code CLI provider,
whose context (200k+) easily holds the whole transcript. `MeetingChatService`
has the same fixed 6,000-token whole-prompt budget.

Separately, `OllamaProvider` never sets `num_ctx`, so Ollama runs at its
server default context (2k–4k depending on version) and silently drops the
head of any prompt longer than that — even the 6k budget is not honoured.

## Goals

1. Every provider summarizes the **whole** transcript — no content is dropped
   silently for any meeting length a user realistically records (≤ 8 h).
2. Large-context providers (Claude Code CLI) do it in **one call**, exactly as
   today for short meetings.
3. Small-context providers (Ollama, oMLX) do it via **map-reduce**: condense
   the transcript in parts, then summarize the condensed notes with the
   user's existing summary template.
4. Output format, `SummaryResponseParser`, to-do extraction and export stay
   unchanged.
5. The user sees progress ("Summarizing part 3 of 13…") during multi-part runs.

## Non-goals

- No persisted per-chunk cache (in-memory only, see §5).
- No map-reduce for chat; chat only gets the provider-aware budget.
- No Settings UI for budgets or `num_ctx`.
- Terminology correction is untouched (it already gates on
  `supportsFullTranscriptEcho`).

## Design

### 1. Provider input budget

`LLMProvider` gains:

```swift
/// How many tokens of *input* a single prompt to this provider may carry,
/// leaving room for the model's output. Callers size transcripts against it.
var promptTokenBudget: Int { get }
```

- Protocol extension default: `LLMPromptSupport.localPromptTokenBudget = 6000`
  (today's value, moved/renamed from `defaultTranscriptTokenBudget`; keep a
  forwarding alias only if existing tests need it).
- `ClaudeCLIProvider`: `100_000` (headroom: estimates can undercount real tokens by ~30 % for Dutch + timestamps).
- `OllamaProvider`, `OMLXProvider`: default (6,000).
- `StubLLMProvider` (tests): injectable, default 6,000.

### 2. Ollama context window

`OllamaProvider` sends `options.num_ctx` on every generate call, computed per
call by a pure helper `LLMPromptSupport.ollamaContextTokens(promptChars:maxTokens:)`:

```
need = budgetTokens(prompt) + (maxTokens ?? budgetTokens(prompt)) + 1_024
num_ctx = min(32_768, max(16_384, roundUp(need, to: 4_096)))
```

The floor (16,384) covers a 6k-budget prompt plus 3,500 output with
estimation error; per-call growth keeps the unbounded terminology echo pass
(`TerminologyService.runProviderPass`, prompt ≈ output) from being cut;
rounding to 4,096 steps limits model reloads. Options are always sent from
now on (today they are omitted when temperature and maxTokens are both nil).
oMLX is unchanged.

### 2a. Token estimation for budget decisions

Budget decisions (single-pass test, chunk sizing, merge grouping, num_ctx)
use `LLMPromptSupport.budgetTokens(_:) = ceil(count / 3)` — 3 chars/token,
deliberately pessimistic for Dutch text with `[mm:ss]` labels. The existing
`charsPerToken = 4` stays for chat's existing elision.

### 3. Single pass vs map-reduce

In `summarize(meeting:)`, after reading transcript + notes:

- `estimatedTokens(text) = LLMPromptSupport.budgetTokens(text)` (3 chars/token).
- `overhead` = estimated tokens of the rendered prompt with an empty transcript
  (template + notes + terminology block + metadata).
- If `estimatedTokens(transcript) + overhead <= provider.promptTokenBudget` →
  **single pass**: today's flow, transcript passed whole, no truncation, no
  warning.
- Otherwise → **map-reduce** (below).

### 4. Map-reduce

**Chunking** — new pure type `TranscriptChunker` (Foundation only, unit-tested):

- Input: transcript, `chunkTokens`, `overlapTokens`.
- Splits on line boundaries (Casablanca transcripts are `[mm:ss] text` lines);
  never splits inside a line unless a single line exceeds `chunkTokens`, in
  which case that line is hard-split at a whitespace boundary (or at the char
  limit if none).
- Each chunk after the first starts with the trailing lines of the previous
  chunk totalling ≤ `overlapTokens`.
- Output: ordered `[TranscriptChunk]` with `index`, `text`, and the first/last
  timestamp label found in the chunk (nil when none) for the map prompt header.
- Chunk size: `chunkTokens = max(1_000, min(provider.promptTokenBudget - mapPromptOverhead, max(4_000, provider.promptTokenBudget / 2)))`
  where `mapPromptOverhead` = estimated tokens of the map prompt with an empty
  chunk; `overlapTokens = 200`. Local providers get ≤ 4,000-token parts; a
  large-context provider that still overflows gets two-ish big parts instead of
  dozens of serial CLI calls.

**Map step** — one call per chunk, fixed prompt (English instructions, output
language = transcript language), via the same provider + `LLMRetryPolicy`:

```
You are condensing part {{part}} of {{total}} of a meeting transcript
({{start}}–{{end}}) so it can be summarized later.
Meeting: {{title}}. Participants: {{participants}}. {{note_taker_line}}
{{terminology_block}}
Write compact notes in the language of the transcript, as markdown bullets
under these headings, each bullet prefixed with its [timestamp] where known:
### Topics discussed
### Decisions
### Action items (owner: what)
### Open questions and risks
### Notable statements and figures
Only use this part of the transcript. Omit empty headings. No preamble.

Transcript part:
{{chunk}}
```

`maxTokens`: `LLMPromptSupport.mapOutputTokens = 900` when thinking is off,
`nil` when thinking is on (otherwise reasoning eats the budget and the notes
vanish). Claude CLI ignores it. Output is stripped with **tag-only** reasoning
stripping (`<think>…</think>` blocks; not `stripReasoning`'s H1 fallback, which
would drop notes before a stray `# ` heading). Empty output after stripping is
an error (`emptyResponse`), never silently skipped. Each call's `truncated`
signal is captured; any truncated map/merge call sets the existing
output-limit warning. The `/no_think` switch is applied as for summaries.

**Reduce step** — the per-part notes are joined in order, each under
`## Part i/N (start–end)`, prefixed with one line:
`[Condensed notes of a long transcript, in chronological order — summarize these as the transcript.]`
The joined text replaces `{{transcript}}` in the user's existing summary
template via the existing `renderPrompt`. Then the existing generate/parse
path runs unchanged.

**Hierarchical merge** — if the joined notes + overhead still exceed
`promptTokenBudget`, group consecutive notes greedily into groups that fit
`promptTokenBudget - mergePromptOverhead` (merge prompt with empty notes), pass
single-note groups through without a call, merge each multi-note group with a fixed merge prompt ("Merge these
chronological partial meeting notes into one set of notes with the same
headings; deduplicate; keep timestamps and owners") using `mapOutputTokens`,
and repeat. Maximum 3 merge levels; stop early when a level does not reduce
the note count. If still too large, fall back to middle-eliding the joined
notes to `promptTokenBudget - overhead` and set the existing
"shortened" warning (reworded: "The meeting was too long to summarize fully;
some middle sections were shortened.").

**Deduplication** — the reduce happens through the user template; the
condensed-notes preamble line plus the merge prompt instruct dedup. No code
dedup.

### 5. Retry, cancellation, caching

- Every map/merge call goes through `LLMRetryPolicy.withRetry`. A part that
  still fails fails the whole summarization with the mapped error (existing
  `mapProviderError`), so the existing error/Retry UI applies.
- `Task.checkCancellation()` between calls; cancellation surfaces nothing (as today).
- In-memory cache on `SummarizationService`: `[CacheKey: String]` where
  `CacheKey` is a `Hashable` struct of meetingID, SHA-256 of the transcript,
  provider display name + endpoint/model identity, terminology block, thinking
  flag, chunkTokens and chunk index. A retry
  after a failed part re-uses completed parts. Cleared when a summarization of
  that meeting succeeds, and capped to the most recent meeting (dictionary is
  replaced when a different meeting starts).

### 6. Progress

`SummarizationPhase` gains `.condensing(part: Int, of: Int)` and
`.merging(level: Int)`. `statusMessage`:

- `.condensing` → `"Summarizing part \(part) of \(of) with \(provider)…"`
- `.merging` → `"Combining notes (step \(level))…"`
- `.retrying` keeps its message; the step's own phase is set again before
  each step and after each successful call so "retrying" never sticks.

Existing `.sending` is used for the final reduce call. The main status UI
reads `MeetingPipelinePresentation.statusText` (MeetingPipelineState.swift),
which today only maps `.retrying`; it must map `.condensing` and `.merging`
to the same strings (sidebar and processing card both use it).

### 6a. Testability

`SummarizationService` reads the template, terminology settings and thinking
flag from its injected `userDefaults` (not `UserDefaults.standard`), and takes
an injectable `retryPolicy` (as `MeetingChatService` does) so tests don't sleep.
`StubLLMProvider` gains a per-outcome truncated flag.

### 7. Chat

`MeetingChatService` obtains its provider *before* assembling the prompt and
uses `provider.promptTokenBudget` instead of `defaultPromptTokenBudget`
(which becomes `LLMPromptSupport.localPromptTokenBudget` so they cannot drift). Middle-elide remains the fallback for chat.

### 8. Warnings

- Single pass: no warning (transcript whole).
- Map-reduce without fallback: no warning.
- Fallback elision: reworded warning above.
- Output-limit warning unchanged.

## Testing

- `TranscriptChunkerTests`: line-boundary split, overlap content and size,
  oversized single line, timestamp extraction, empty input, transcript without
  timestamps, determinism.
- `SummarizationServiceTests` (StubLLMProvider):
  - short transcript → exactly 1 call, prompt contains whole transcript, no warning;
  - large budget stub (100k) + 147k-char transcript → 1 call, whole transcript, no warning;
  - small budget stub + long transcript → N map calls + 1 reduce; reduce prompt
    contains every part's stub notes in order and not the raw transcript;
  - hierarchical path triggers when notes exceed the budget; capped at 3 levels then fallback warning;
  - thinking on → map calls get `maxTokens == nil`; empty-after-strip map output → error;
  - a part failing after retries → error surfaced; retry re-uses cached parts (call count);
  - phase progression observed via `onGenerate` (`.condensing(1, N)` … `.sending`).
- `OllamaProviderTests`: request body always has `options.num_ctx` (update the existing test asserting `options` is nil); helper: floor 16,384, growth for long echo prompts, cap 32,768, 4,096 rounding.
- `MeetingPipelineStateTests`: `.condensing`/`.merging` status text.
- `ClaudeCLIProvider` / capability tests: `promptTokenBudget == 100_000`; default 6,000.
- `MeetingChatServiceTests`: budget follows the provider.
- Full `xcodebuild test` suite green; on-device check: summarize the EHDS meeting
  (147k chars) with Claude Code (1 call) and with Ollama (map-reduce, progress shown).
