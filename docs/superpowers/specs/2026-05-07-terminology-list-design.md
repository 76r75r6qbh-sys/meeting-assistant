# Terminology List

## Problem

WhisperKit transcribes domain-specific terminology poorly — product names, internal jargon, healthcare/Dutch-EHR vocabulary (e.g. "Medicore", "Wegiz BgZ", "Orchestra", "Topdesk") routinely come out as phonetic approximations. The downstream summary inherits the wrong spelling and the user has no lever to fix this short of editing each transcript by hand.

WhisperKit (local) does not expose `initial_prompt` or vocabulary biasing, so we cannot hint the transcriber directly. The only point of leverage is post-processing.

## Goal

Maintain a single, global terminology list. When enabled, post-process every new transcript to:

1. Deterministically replace known misspellings with their canonical form.
2. Run an Ollama "terminology pass" to fix remaining phonetic variants.

Inject the same list into the summarization prompt so the summary preserves correct spellings even if a term sneaks past the correction pass.

## Non-goals

- No live correction during recording. The pipeline runs only after Stop, in the existing async post-recording chain.
- No per-meeting override. One global list, controlled by one toggle.
- No structured editor / table UI. The list is a plain-text blob in a sheet, matching the existing Summary Prompt editor.
- No language-aware corrections. The list is language-agnostic; the same list applies to English and Dutch transcripts.
- No automatic re-correction of historical meetings. Re-application is a manual button.
- No cloud Whisper API migration.

## Design

### New preferences

Two new keys in `AppPreferenceKey` (`Casablanca/Models/Meeting.swift`):

| Key | Type | Default |
|---|---|---|
| `terminologyCorrectionEnabled` | `Bool` | `false` |
| `terminologyList` | `String` (multiline) | `""` |

When `terminologyCorrectionEnabled == false` **or** `terminologyList` is empty, the post-processing pipeline behaves exactly as today (no extra latency, no extra Ollama call, no `{{terminology_list}}` injection).

### Terminology list format

Plain text, one entry per line. Aliases (common misspellings) follow a colon, comma-separated:

```
Medicore: Mediscore, Medi-Core, MedyCore
Wegiz BgZ: Wegis, Wegi's, BGZ
Orchestra
Topdesk
```

Parsing rules:

- Trim each line; ignore blank lines and lines starting with `#`.
- Split on the first `:`. Left side is the canonical term. Right side (optional) is a comma-separated list of aliases.
- Canonical terms with no aliases contribute only to the Ollama hint and the summary prompt.
- Empty canonical → skip the line.
- Whitespace inside terms is preserved ("Wegiz BgZ" is one term).

### Meeting model change

Add one optional property to `Meeting` (`Casablanca/Models/Meeting.swift`):

```swift
var rawTranscript: String?
```

`rawTranscript` is the unmodified WhisperKit output. `transcript` continues to be the displayed/exported version, but is now the *corrected* version when correction runs. Existing meetings have `rawTranscript == nil`; nothing breaks (the re-apply action below is simply unavailable for them).

**Schema migration.** This is an additive optional property on an existing `@Model` class. SwiftData handles it as a lightweight migration with no version bump required (the project does not use `VersionedSchema`). No migration code or schema-version constants need to change.

### Pipeline

The terminology stage slots into the existing `TranscriptionView.startTranscription()` chain (`Casablanca/Views/TranscriptionView.swift` ~149) **before** the existing post-transcription side effects. The exact ordering becomes:

```
1. WhisperKit.transcribe                                  [existing]
2. meeting.rawTranscript = result.formattedTranscript     [NEW]
3. TerminologyService.correct(...)                        [NEW; gated]
       ├── 3a. Dictionary replace (deterministic)
       └── 3b. Ollama terminology pass
4. meeting.transcript = corrected                         [moved: was step 1's result]
5. meeting.status = .completed  +  save()                 [existing]
6. TranscriptionService.saveTranscriptLocally(...)        [existing — now writes corrected]
7. ExportService.exportAutomaticallyIfEnabled(meeting)    [existing — now exports corrected]
8. Summarization (existing autoSummarizeAfterTranscription path, with {{terminology_list}} substitution)
```

The reordering is critical: `saveTranscriptLocally` and `ExportService` must see the corrected transcript, otherwise Obsidian and the locally saved transcript file get the raw text. `meeting.status` stays `.processing` through the terminology stage and only flips to `.completed` after step 4.

If correction is disabled or the list is empty, steps 2–3 are still cheap (one preference read + one parse on an empty string returning early); `meeting.transcript` is then assigned directly from `result.formattedTranscript` and `rawTranscript` is left `nil`.

All stages run in the existing background `Task` spawned inside `startTranscription()`. The user can navigate freely; nothing blocks the UI.

### New service

`Casablanca/Services/TerminologyService.swift`, `@MainActor` (matching `TranscriptionService` and `SummarizationService`):

```swift
struct TerminologyEntry {
    let canonical: String
    let aliases: [String]
}

@MainActor
enum TerminologyService {
    static func parse(_ raw: String) -> [TerminologyEntry]
    static func dictionaryReplace(_ text: String, entries: [TerminologyEntry]) -> String
    static func correct(_ rawTranscript: String, entries: [TerminologyEntry]) async -> String
    static func formattedForPrompt(_ entries: [TerminologyEntry]) -> String  // bullet list
}
```

**Concurrency note.** The service is `@MainActor`; the `URLSession` call inside `correct(...)` is `await`ed and yields the actor. Pure functions (`parse`, `dictionaryReplace`, `formattedForPrompt`) are CPU-bound and run synchronously on whichever actor calls them. The `entries` array passed into `correct` is captured by value before the await, so editing the list in Settings during an in-flight correction does not affect that run.

**`dictionaryReplace` algorithm.**

- For each alias across all entries, build a regex pattern `\b<escaped-alias>\b`, where `<escaped-alias>` is `NSRegularExpression.escapedPattern(for: alias)`.
- Use `NSRegularExpression` with `.caseInsensitive`. (Whisper output is ASCII for the languages we support; `\b` ASCII-only word boundaries are acceptable. Aliases containing leading/trailing non-word characters are accepted as-is — boundary will simply not match them, which is fine.)
- Apply replacements **longest-alias-first across all entries** (sorted by alias `count` descending, ties broken by entry order in the parsed list). This makes overlap deterministic: if a user defines `Medi → X` and `Medicore → Y`, the longer alias replaces first; the substring `Medi` inside the resulting `Y` text will not be re-replaced because all replacements are computed against the input string in a single sequential pass with non-overlapping ranges (use `matches(in:range:)` once per pattern, then apply replacements in reverse order, OR use `replacingMatches(of:options:range:withTemplate:)` once per pattern in longest-first order).
- The replacement is the canonical's exact spelling, regardless of the casing of the alias match (e.g. input `MEDISCORE` → output `Medicore`, not `MEDICORE`).

**`correct` behaviour.**

- Run `dictionaryReplace` first. Result becomes the candidate output.
- If the parsed list is empty → return the raw input unchanged (caller is also expected to short-circuit before calling, but this makes the function robust).
- If `terminologyCorrectionEnabled` is on and the list is non-empty, always run the Ollama terminology pass on the dictionary-replaced text. (No conditional skip based on entry shape — keep the rule simple: toggle on + list non-empty = both phases run.)
- The Ollama request uses `URLRequest.timeoutInterval = 60`. Honor `Task.isCancelled` between phases and immediately after the Ollama response: on cancellation, return the dictionary-replaced text and exit cleanly.
- On any Ollama error (timeout, non-2xx, decode failure) → return the dictionary-replaced text. Set a user-visible warning (see "Failure surface" below). Never throw.

**`formattedForPrompt`.** Emits `- Medicore\n- Wegiz BgZ\n…` — all entries' canonical forms only, never aliases. Consumed by both `correct(...)` (Ollama prompt) and `SummarizationService` (summary prompt).

### Ollama correction prompt

Single-shot, low-temperature, same Ollama model and endpoint as summarization (`AppPreferenceKey.ollamaModel`, `ollamaEndpoint`):

```
You are correcting domain-specific terminology in a meeting transcript.

The following terms must appear with their exact spelling:
{{terminology_bullets}}

Rules:
- Fix only misspellings or phonetic mistranscriptions of the terms above.
- Do not rephrase, translate, summarize, add, or remove anything else.
- Preserve all timestamps, speaker labels, line breaks, and punctuation exactly.
- Output only the corrected transcript. No preamble, no commentary.

Transcript:
{{transcript}}
```

Request settings: `temperature: 0`, `stream: false`, same `OllamaGenerateRequest` shape used by `SummarizationService`.

### Summarization integration

`Casablanca/Services/SummarizationService.swift`:

- `summarize(meeting:)` reads `terminologyCorrectionEnabled` and `terminologyList` from `UserDefaults`, parses the list via `TerminologyService.parse`, and passes a pre-rendered terminology block string to `renderPrompt(...)` as a new parameter (e.g. `terminologyBlock: String`).
- `renderPrompt(...)` gains a `terminologyBlock` parameter and adds `{{terminology_list}}` to its placeholder substitutions, substituting it with the passed-in string verbatim.
- When `terminologyCorrectionEnabled == true` and the parsed list is non-empty, the caller computes the block as:

  ```
  Domain terminology to preserve (use these exact spellings):
  - Medicore
  - Wegiz BgZ
  - Orchestra
  ```

  Otherwise the caller passes an empty string. The block owning its own heading keeps disabled-state prompts clean.
- Update `defaultPromptTemplate` to include `{{terminology_list}}` on its own line above the `Transcript:` block. Existing user-customised templates are untouched (placeholder simply substitutes to empty if the template doesn't reference it).
- The hardcoded heading text leaks into the rendered prompt; users with custom templates cannot restyle it. Acceptable trade-off — keeps the placeholder a single token rather than forcing the user to know to write `Domain terminology to preserve:\n{{terminology_list}}`.

### Settings UI

New "Terminology" section in the AI tab of `Casablanca/Views/SettingsView.swift`, placed below the existing "Summary Prompt" section. Structurally identical to the existing Summary Prompt pattern (see `summaryPromptSheet` in SettingsView.swift):

Outer Settings page:

```
─ Terminology ─────────────────────────────────────
  [ ] Correct terminology after transcription          ← Toggle, bound to @AppStorage(terminologyCorrectionEnabled)

  Domain-specific terms that are often misspelled by
  the transcriber. One term per line. Use a colon to
  list common misspellings, e.g.:
      Medicore: Mediscore, Medi-Core

  [ Customize Terminology List… ]                       ← Opens sheet editor
```

Sheet editor: a `TextEditor` bound **directly** to `@AppStorage(AppPreferenceKey.terminologyList)` (no working copy, no debounce — matches the Summary Prompt sheet's direct binding). A single **"Done"** button dismisses the sheet. A **"Reset to Empty"** secondary button lives **inside the sheet** (mirroring the placement of "Reset to Default Prompt" in the Summary Prompt sheet), visible only when the list is non-empty.

The list editor and toggle are independent: the list editor remains usable even when the toggle is off, so the user can prepare the list before flipping the switch.

### Re-apply action

On `RecordedMeetingView`, add a "Re-apply terminology" secondary button on the transcript display area (the section that renders `meeting.transcript` post-completion — the implementation plan should pick the precise anchor; a button next to the existing transcript controls or in a context menu on the transcript card is acceptable). Visible only when:

- `meeting.rawTranscript != nil`, AND
- `terminologyCorrectionEnabled == true`, AND
- the parsed terminology list is non-empty.

Behaviour: re-runs `TerminologyService.correct(rawTranscript)` against a snapshot of the current list and writes the result to `meeting.transcript`. Reuses the same "Correcting terminology…" status surface used by the post-Stop pipeline. Does not re-run summarization automatically — the user can re-summarize via the existing summarize button if they want the new terms reflected in the summary.

### Pipeline status UI / failure surface

`TranscriptionView` already displays per-stage progress; `RecordedMeetingView`'s `pipelineBanner` reads `summarizationService.isSummarizing`. Add equivalent state for terminology correction:

- A new `@Observable` value on a small `TerminologyCorrectionState` (or a `@State var isCorrectingTerminology: Bool` plus `var terminologyWarning: String?` co-located on the view that owns the pipeline — the implementation plan picks the exact shape; what matters is that the flag is observable from both `TranscriptionView` and `RecordedMeetingView`).
- While correction is in flight, both views show a "Correcting terminology…" status string in the existing pipeline banner / transcription progress component. No new visual element.
- On Ollama failure during correction, set `terminologyWarning` to a human-readable string ("Terminology correction is unavailable; transcript reflects only deterministic replacements."). `RecordedMeetingView` renders it as a small inline notice near the transcript card with a dismiss action — analogous to the existing summarization-error rendering pattern.

### Failure modes

| Condition | Behaviour |
|---|---|
| Toggle off | Skip correction; `meeting.rawTranscript` not set; `meeting.transcript` = raw WhisperKit output (today's behaviour). |
| Toggle on, list empty after parse | Skip correction; same as above. |
| Ollama unreachable / non-2xx / decode failure / timeout (60s) | Fall back to dictionary-replaced text; set `terminologyWarning`; do not block summarization. Summary proceeds with the dictionary-replaced transcript and the terminology block in its prompt. |
| User cancels via existing `transcriptionService.cancel()` during correction | `Task.isCancelled` check between phases / after Ollama → return dictionary-replaced text and exit; pipeline aborts as it does today for cancelled WhisperKit runs. |
| Meeting deleted from model context mid-correction | Before writing to `meeting.transcript` / `meeting.rawTranscript`, guard with `meeting.modelContext != nil`. If the meeting has been deleted, drop the result silently. |
| Re-apply on legacy meeting (no `rawTranscript`) | Action hidden / disabled. |
| User edits terminology list mid-correction | The in-flight correction uses the snapshot of the parsed list captured before its first await. Subsequent meetings (and re-apply actions) pick up the new list. |
| Aliases containing regex metacharacters (e.g. `.` `(` `+` `?`) | Always escaped via `NSRegularExpression.escapedPattern(for:)` before pattern construction — entries are never interpreted as regex. |

## Testing

Manual verification:

1. With toggle **off**, record a 30-second meeting that mentions "Medicore" and "Wegiz BgZ". Confirm transcript and summary are unchanged from today's output (no terminology stage runs, no extra Ollama call in logs).
2. Set the list to `Medicore: Mediscore`, `Wegiz BgZ: Wegis`, enable the toggle. Re-record the same content (or use a fixture audio that is known to mistranscribe these). Confirm:
   - `meeting.rawTranscript` contains the original WhisperKit output (mistranscribed).
   - `meeting.transcript` contains the corrected version.
   - Summary contains the canonical spellings.
3. Trigger an Ollama failure (point endpoint at an invalid URL). Confirm the dictionary-replaced text still lands in `meeting.transcript`, summarization still runs (using the dictionary-replaced transcript and the terminology block in its prompt), the locally saved transcript file and Obsidian export both contain the dictionary-replaced text, and an inline `terminologyWarning` is shown on the meeting view.
4. Add an alias with a regex metacharacter (e.g. `Wegi.s` → `Wegiz BgZ`); confirm it replaces only the literal string `Wegi.s`, not "Wegits" or "Wegiss".
5. Add overlapping entries (`Medi → X`, `Medicore → Y`); confirm `Medicore` in the input becomes `Y` and a standalone `Medi` becomes `X`.
6. Open a legacy meeting (transcribed before the change). Confirm the "Re-apply terminology" action is hidden.
7. Open a meeting with `rawTranscript` set, change the terminology list, click "Re-apply terminology". Confirm `meeting.transcript` is overwritten with new corrections.
8. Verify the entire post-Stop pipeline is non-blocking: navigate to a different meeting while a recording is correcting; confirm UI stays responsive.
9. Delete a meeting while correction is in flight (toggle on, slow Ollama). Confirm no crash and no orphan write.

No unit tests added for the SwiftUI bindings or the service wrapper; the parsing and dictionary-replace pure functions in `TerminologyService` warrant unit tests if the test target supports them — defer that decision to the implementation plan.
