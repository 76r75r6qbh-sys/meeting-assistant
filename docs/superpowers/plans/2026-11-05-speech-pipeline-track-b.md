# Speech pipeline Track B — Summary and action items Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Summaries built from extracted, verified facts; structured action items (owner, due, quote, timestamp) that become *proposed* to-dos the user accepts, edits or rejects; templates per meeting type (spec points 5, 6, 7, 9, 10, 13 = B1–B6).

**Architecture:** The summary prompt gains a "what the user cares about" block and a marked participant list (B4), and always asks for a JSON facts block (single pass) or returns JSON per part (map step) that `SummaryFactsParser` decodes, with one repair retry and today's markdown path as fallback (B1). The structured list renders the `## Action Items` / `## Decisions` sections so every existing markdown consumer keeps working (B2), is verified against the transcript (deterministic quote pre-check, then one LLM call, B3), is shaped by a per-meeting template (B5), and lands as `.proposed` `TodoItem`s that reach Obsidian / Apple Notes only when accepted (B6).

**Tech Stack:** Swift 5, SwiftUI, SwiftData (macOS 14+), XCTest with `StubLLMProvider`; no new dependencies.

**Spec:** `docs/superpowers/specs/2026-11-05-speech-pipeline-best-practices-design.md` (Track B + "Contracts shared by all tracks"). Master plan: `docs/superpowers/plans/2026-11-05-speech-pipeline-best-practices.md`.

## Global Constraints

- Work in the Track B worktree (`../lahore-track-b`, branch `76r75r6qbh-sys/speech-pipeline-track-b`) branched from the Phase 0 tip. Never push, never open a PR, never release.
- **Never run the full suite.** `<TB_TEST>` below means exactly:
  `xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -derivedDataPath .build/test-track-b -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''`
  followed by one or more `-only-testing:CasablancaTests/<Class>`. PASS means `** TEST SUCCEEDED **`.
- Never a live LLM or network in tests: `CasablancaTests/LLM/StubLLMProvider.swift`. Never the user's defaults or vault: `makeScratchDefaults(vaultRoot:label:)`, `makeScratchVault(_:)` (`CasablancaTests/Support/TestVaultGuard.swift`), in-memory `ModelContainer` as in `ObsidianTodoSyncServiceTests`.
- Transcript lines are `[mm:ss] <Speaker>: <text>` or `[h:mm:ss] …`; the `<Speaker>: ` part is optional. Every Track B test that feeds a transcript has a variant **with** and **without** speaker prefixes.
- Owners only on explicit evidence, otherwise `nil`. Generic speaker labels (`Speaker 1`, `Spreker 2`, `Others`, `Anderen`) are never owners.
- Old meetings (no `actionItemsData`, no `summaryTemplateID`, legacy todos) behave as before everywhere.
- Only `.accepted` to-dos sync or export. Proposed to-dos have `sourceFilePath == nil` and live in SwiftData only.
- Do **not** edit Phase 0/2-reserved files: `Models/Meeting.swift` (incl. `AppPreferenceKey`), `Models/TodoItem.swift`, `Models/CasablancaSchema.swift`, `Views/SettingsView.swift`, `Models/SpeakerTranscript.swift`, `Models/ExtractedActionItem.swift`, `Services/TranscriptLineFormat.swift`, `Services/AudioClipPlayer.swift`. Where a change is needed there, the task carries a **Phase 2 handoff** note.
- New files go in the existing flat groups (`Casablanca/Services/`, `Casablanca/Views/Components/`, `Casablanca/Views/MeetingDetail/`, `CasablancaTests/`); each needs PBXFileReference + PBXBuildFile + group + Sources-phase entries in `Casablanca.xcodeproj/project.pbxproj` (pattern: `SummarizationService.swift` / `StubLLMProvider.swift`). pbxproj edits are part of each task's commit.
- Commit messages are conventional and end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Consumed from Phase 0 (do not redefine)

```swift
enum VerificationState: String, Codable { case unverified, supported, unsupported }
struct ExtractedActionItem: Codable, Equatable { var task: String; var owner: String?; var due: String? /* yyyy-MM-dd */
  var dueIsExplicit: Bool; var confidence: Double; var quote: String?; var timestamp: String?
  var verified: VerificationState; var verificationReason: String? }
enum ActionItemData { static func encode(_: [ExtractedActionItem]) -> Data?; static func decode(_: Data?) -> [ExtractedActionItem] }
struct TranscriptLine: Equatable { var label: String; var seconds: Double; var speaker: String?; var text: String }
enum TranscriptLineFormat { static func parse(_:) -> TranscriptLine?; static func parse(_:knownSpeakers:) -> TranscriptLine?
  static func seconds(fromLabel:) -> Double?; static func timestampLabel(seconds:) -> String }
// Meeting (V3): actionItemsData: Data?, summaryTemplateID: String?, actionItems: [ExtractedActionItem] { get set }, speakers: [SpeakerInfo]
// TodoItem (V3): owner: String?, dueDate: Date?, sourceTimestamp: String?, quote: String?, statusRaw: String, verificationRaw: String?
//   status: TodoStatus (.proposed/.accepted/.rejected; unknown → .accepted), verification: VerificationState?
//   If Phase 0 lands `status`/`verification` get-only, write `statusRaw`/`verificationRaw` directly.
// AppPreferenceKey.summaryTemplates (JSON string, "" = built-ins), AppPreferenceKey.autoAcceptVerifiedTodos (Bool, false)
// Views/Settings/SummaryTemplatesSettingsSection.swift, Views/Settings/ActionItemReviewSettingsSection.swift (placeholders this track fills)
```

## Review Focus

1. **An old meeting** (summary written by today's prompt, legacy accepted to-dos, no `actionItemsData`) → summary tab, action-item toggles, Todos view and both exports look and behave exactly as today. Pinned in Task 5 (`testLegacySummaryRendersUnchanged`) and Task 10 (`testLegacyTodosStillSyncAndExport`).
2. **The model returns no or broken JSON** → one repair call, then the markdown fallback with `factsFallbackWarning`; the to-dos come from the summary's action-items section and are never silently zero. Pinned in Task 3 (`testBrokenJSONAfterRepairFallsBackToMarkdownItems`) and Task 4 (`testAPartWithBrokenJSONSwitchesTheWholeRunToTheMarkdownFallback`).
3. **A vault refresh with proposed/rejected rows present** → nothing is written to, created from, or deleted because of them. Pinned in Task 5 (`testRefreshNeverWritesProposedTodosToTheVault`) and Task 10 (`testRejectedRowsSurviveRefresh`).
4. **A user-typed Obsidian task containing ` — ` or brackets** (`- [ ] Bel Kim — dringend`) → its text survives a sync round trip unchanged; only a suffix with `📅` or `[mm:ss]` is parsed. Pinned in Task 10 (`testUserTypedDashLineKeepsItsText`).
5. **Relative dates at week edges and speaker labels** → "vrijdag" said on a Friday resolves to the *next* Friday; `Spreker 2: ik pak dat op` never yields owner `Spreker 2`. Pinned in Task 2 (`testWeekdayOnSameWeekdayIsNextWeek`, `testGenericSpeakerLabelIsNeverAnOwner`).

---

## Task 1 (B4): Prompt context — focus block, marked participants, attendee e-mails

**Files:**
- Create: `Casablanca/Services/SummaryPromptContext.swift`
- Modify: `Casablanca/Services/SummarizationService.swift` (`defaultPromptTemplate`, `PromptContext`, `renderPrompt`, `fitsInOnePass`, `meetingLine`, `init`)
- Create test: `CasablancaTests/SummaryPromptContextTests.swift`, `CasablancaTests/Support/StaticAttendeeProvider.swift`
- Modify test: `CasablancaTests/SummarizationServiceTests.swift`

**Interfaces:**
- Consumes: `MeetingPrepService.loadResolvedPrepMarkdown(for:userDefaults:) async -> String?`; `ActionItemOwnership.owner(_:matchesAnyOf:)`; `AppPreferences.userNameAliases(in:)`.
- Produces:
```swift
struct MeetingAttendee: Equatable, Sendable { var name: String; var email: String?; var isCurrentUser: Bool }
protocol MeetingAttendeeProviding { @MainActor func attendees(for meeting: Meeting) -> [MeetingAttendee] }
/// Lazy EKEventStore; returns [] unless `meeting.calendarEventID` is set AND
/// EKEventStore.authorizationStatus(for: .event) == .fullAccess. email = EKParticipant.url
/// with "mailto:" stripped (nil if not mailto); isCurrentUser = EKParticipant.isCurrentUser.
struct EventKitAttendeeProvider: MeetingAttendeeProviding
enum SummaryPromptContext {
  static let maxFocusTokens = 1_500     // focus block cap in a single pass / reduce
  static let minFocusTokens = 200       // below this, go map-reduce instead of trimming further
  static let mapFocusTokens = 300       // focus cap inside each map prompt
  static func participantsLine(participants: [String], attendees: [MeetingAttendee], userAliases: [String]) -> String
  static func focusBlock(prep: String?, notes: String?, maxTokens: Int) -> String   // "" when both empty
}
// SummarizationService
init(providerFactory:userDefaults:retryPolicy:attendeeProvider: MeetingAttendeeProviding = EventKitAttendeeProvider(),
     prepLoader: @escaping @MainActor (Meeting, UserDefaults) async -> String? = { await MeetingPrepService.loadResolvedPrepMarkdown(for: $0, userDefaults: $1) })
static func renderPrompt(template:meeting:transcript:freeformNotes:terminologyBlock:userName: String? = nil,
                         participantsLine: String? = nil, focusBlock: String = "") -> String
// PromptContext gains: let participantsLine: String; let prep: String?; func summaryPrompt(transcript:focusTokens:) -> String
```

Rules the code must follow:
- `participantsLine`: start from `participants` (trimmed, non-empty); give each the e-mail of the attendee whose name matches case/diacritic-insensitively (`ActionItemOwnership.fold`); append attendees not already listed (their name, or the e-mail when the name is empty); mark the user with ` (me)` (attendee `isCurrentUser`, or a name matching `userAliases`); if nobody is marked and the list is non-empty and `userAliases` is non-empty, append `"<aliases[0]> (me)"`. Each entry renders `Name`, `Name <mail>`, `Name (me)` or `Name (me) <mail>`, joined by `, `. An empty list renders `Unknown` (never invents the user into an unknown room).
- `focusBlock`: `prep` is trimmed first, then `notes` — each cut at the tail with `…` until the block fits `maxTokens` (`LLMPromptSupport.budgetTokens`). The transcript is never trimmed for it. Exact copy:

~~~~text
What the user cares about (their prep and own notes for this meeting — use it to decide what matters, but only report what the transcript or notes support):
Prep:
<prep>
User notes:
<notes>
~~~~
  (the `Prep:` / `User notes:` part is omitted when that input is empty or whitespace).
- When the template contains `{{freeform_notes}}`, user notes go there and the focus block carries prep only; otherwise the focus block carries both. `{{user_focus}}` is replaced by the block; when the block is empty the placeholder line and one following blank line are removed. A custom template without `{{user_focus}}` gets the block inserted on its own lines directly before the line containing `{{transcript}}` — or before the line above it when that line, trimmed, is `Transcript:`.
- Budget: single pass is tried with the focus at `maxFocusTokens`; if it does not fit, the focus shrinks to `budget − transcriptTokens − overheadWithoutFocus`; if that is `< minFocusTokens`, the transcript goes map-reduce (where the reduce gets the full-size focus).
- `meetingLine` (map/merge prompts) uses the new participants line.

New `defaultPromptTemplate` (exact copy — identical to today's except the speaker rule bullet, the `{{user_focus}}` line and the removed freeform-notes tail):

~~~~text
You are a meeting assistant creating structured, high-signal meeting notes.

Write the notes in the dominant language of the transcript (Dutch transcript -> Dutch notes, English transcript -> English notes).

Use only the information provided below. If something is unclear or missing, leave it out instead of guessing.

The transcript comes from machine speech recognition and may misspell names of people, companies and products. Correct obvious mistranscriptions using the terminology list and the participants list. Never invent names, and never comment on transcript quality in the notes.

Structure the notes as follows:

1. Start with a single `# Summary` heading (Dutch: `# Samenvatting`) followed by a 2-4 sentence paragraph: what the meeting was about and its main outcome.
2. Then 2-5 thematic sections, each with a descriptive `## <theme>` heading, containing a short intro sentence and/or `- **subtopic:** detail` bullets. Capture the reasoning behind conclusions, not just the conclusions.
3. If the meeting discussed planning across dates, weeks or months, add a `## Planning` section with chronological bullets: `- **<period>** — <milestone or activity>`.
4. If hiring or staffing was discussed, add a `## Personele zaken` (English: `## Personnel`) section.
5. End with these four sections, always present, in this order. Use exactly these headings — Dutch notes / English notes:
   `## Besluiten` / `## Decisions`
   `## Actiepunten` / `## Action Items`
   `## Risico's en blockers` / `## Risks and Blockers`
   `## Opvolging` / `## Follow-ups`

Rules for the four closing sections:
- Every item is a `- ` bullet. If a section has no items, keep the heading with nothing below it.
- Decisions include their stated rationale.
- Each action item is one bullet formatted `- **<owner>** — <action>`. Resolve the owner against the participants list; use the person's name, never "me" or "I". If no owner was stated, use `- **?** — <action>`.
- The note-taker is {{user_name}}. When the note-taker commits to something ("I will…", "ik pak dat op"), the owner is {{user_name}}.
- Transcript lines may start with a speaker label (`[12:34] Kim: …`). A labelled speaker's first-person commitment makes that speaker the owner. Generic labels such as "Speaker 1", "Spreker 2", "Others" or "Anderen" are not names.
- Omit optional sections that have nothing meaningful. Never add sections about the transcript itself.

{{terminology_list}}

Meeting title: {{title}}
Scheduled time: {{scheduled_time}}
Participants: {{participants}}

{{user_focus}}

Transcript:
{{transcript}}
~~~~

- [ ] **Step 1: Write the failing tests** (`SummaryPromptContextTests`)
  - `testParticipantsMarkUserByAliasAndAddEmails`: participants `["Kim Owen-Jones","Youri Broekhuizen"]`, attendees `[("Kim Owen-Jones","kim@partner.nl",false)]`, aliases `["Youri"]` → `"Kim Owen-Jones <kim@partner.nl>, Youri Broekhuizen (me)"`.
  - `testParticipantsMarkCurrentUserAttendee`: attendee `("Y. Broekhuizen","youri@medicore.nl",true)` not in participants → appended as `"Y. Broekhuizen (me) <youri@medicore.nl>"`.
  - `testParticipantsAppendUserWhenUnmarked`: `["Kim"]`, aliases `["Youri"]` → `"Kim, Youri (me)"`.
  - `testEmptyParticipantsStayUnknown`: `[]`, `[]`, `["Youri"]` → `"Unknown"`.
  - `testFocusBlockTrimsPrepBeforeNotes`: prep 3 000 chars, notes 300 chars, `maxTokens: 400` → block fits 400 budget tokens, contains the whole notes, prep ends with `…`.
  - `testFocusBlockEmptyWhenNothingGiven`: `(nil, "  ")` → `""`.
- [ ] **Step 2: Write the failing tests** (`SummarizationServiceTests`, all with `StaticAttendeeProvider` and a stub `prepLoader`)
  - `testPromptPutsFocusBeforeTranscript`: prep `"Vraag naar budget"`, notes `"Kim twijfelt"` → in the single call, `range(of: "What the user cares about")` < `range(of: "Transcript:")`, both texts present once.
  - `testFocusIsTrimmedBeforeTheTranscript`: budget 1 500, transcript 3 600 chars, prep 4 000 chars → one call (single pass), prompt contains the full transcript, prompt ≤ 1 500 budget tokens.
  - `testCustomTemplateWithFreeformNotesKeepsNotesThere`: template `"T {{transcript}} N {{freeform_notes}}"` → notes appear after `N `, focus block holds prep only and sits before `{{transcript}}`'s position.
  - `testPromptListsUserAsMe` with and without speaker prefixes in the transcript → prompt contains `Participants: Kim, Youri (me)`.
  - Rename `testDefaultPromptTemplateIncludesTranscriptAndFreeformNotes` → `testDefaultPromptTemplateIncludesTranscriptAndUserFocus` asserting `{{transcript}}`, `{{user_focus}}` present and `{{freeform_notes}}` absent.
- [ ] **Step 3: Run** `<TB_TEST> -only-testing:CasablancaTests/SummaryPromptContextTests -only-testing:CasablancaTests/SummarizationServiceTests` → FAIL (types/params missing).
- [ ] **Step 4: Implement** `SummaryPromptContext.swift`, `StaticAttendeeProvider` (test support: returns a fixed array), and the `SummarizationService` changes above. `summarize` loads prep via `prepLoader` once, before building `PromptContext`.
- [ ] **Step 5: Run** the same command → PASS (all pre-existing `SummarizationServiceTests` stay green).
- [ ] **Step 6: Commit** `feat(summary): user focus block and marked participants in prompts`.

---

## Task 2 (B1, pure): Facts types, lenient JSON parser, relative-date resolver, prompt copy

**Files:**
- Create: `Casablanca/Services/SummaryFacts.swift` (types + parser + prompt copy), `Casablanca/Services/RelativeDateResolver.swift`, `Casablanca/Services/FuzzyText.swift`
- Test: `CasablancaTests/SummaryFactsParserTests.swift`, `CasablancaTests/RelativeDateResolverTests.swift`, `CasablancaTests/FuzzyTextTests.swift`

**Interfaces:**
- Consumes: `ExtractedActionItem`, `VerificationState`, `TranscriptLineFormat.seconds(fromLabel:)`/`timestampLabel(seconds:)`, `ActionItemOwnership.parse/fold`, `SummaryResponseParser.ParsedResponse`.
- Produces:
```swift
struct ExtractedDecision: Codable, Equatable { var text: String; var quote: String?; var timestamp: String?
  var verified: VerificationState = .unverified; var verificationReason: String? }
struct ExtractedNote: Codable, Equatable { var text: String; var timestamp: String? }
struct SummaryFacts: Equatable {
  var topics: [String]; var decisions: [ExtractedDecision]; var actionItems: [ExtractedActionItem]
  var openQuestions: [ExtractedNote]; var facts: [ExtractedNote]
  static let empty: SummaryFacts
  static func merged(_ parts: [SummaryFacts]) -> SummaryFacts
  static func fromMarkdown(_ parsed: SummaryResponseParser.ParsedResponse) -> SummaryFacts
  static func sanitizedOwner(_ raw: String?) -> String?
  func notesMarkdown() -> String
}
enum SummaryFactsParser {
  enum Failure: Error, Equatable { case noJSON, invalidJSON }
  struct SinglePassSplit: Equatable { let markdown: String; let jsonText: String? }
  static func splitSinglePass(_ response: String) -> SinglePassSplit
  static func extractJSONObject(_ text: String) -> String?
  static func decodeFacts(_ jsonText: String, meetingDate: Date, calendar: Calendar) -> Result<SummaryFacts, Failure>
}
enum SummaryFactsPrompt {
  static func singlePassInstruction(meetingDate: Date, calendar: Calendar) -> String
  static func repairPrompt(broken: String) -> String
  static func rebuildPrompt(fromMarkdown closingSections: String, meetingDate: Date, calendar: Calendar) -> String
  static let objectShape: String
  static func rules(meetingDate: Date, calendar: Calendar) -> String
}
enum RelativeDateResolver {
  static func resolve(_ raw: String?, llmSaysExplicit: Bool, meetingDate: Date, calendar: Calendar) -> (iso: String?, isExplicit: Bool)
}
enum FuzzyText {
  static let matchThreshold = 0.85
  static func normalized(_ text: String) -> String      // fold case+diacritics, punctuation → space, collapse whitespace, trim
  static func similarity(_ a: String, _ b: String) -> Double   // 1 − Levenshtein(normalized a, normalized b) / max(len); both empty → 1
}
```

Decisions the code must follow:
- `splitSinglePass`: the **last** fenced block whose info string is `json`, or a bare ```` ``` ```` block whose first non-space character is `{`, is removed from the markdown (with the whitespace before it); `markdown` is trimmed. No block → `jsonText == nil`, markdown unchanged (trimmed).
- `extractJSONObject`: strips one surrounding fence if present, then takes the first `{` to the last `}`; `nil` if none.
- `decodeFacts` is lenient: snake_case keys `topics`, `decisions`, `action_items`, `open_questions`, `facts`; any missing key → `[]`; `confidence` accepts a number, a numeric string, or `"high"/"medium"/"low"` (0.9/0.6/0.3), default 0.5, clamped to 0…1; `timestamp` brackets stripped and kept only if `seconds(fromLabel:)` parses, then re-labelled with `timestampLabel(seconds:)`; empty `task`/`text` items dropped; `owner` through `sanitizedOwner`; `due` through `RelativeDateResolver` (so `ExtractedActionItem.due` is always ISO or nil); `verified = .unverified`. Top level not an object → `.invalidJSON`.
- `sanitizedOwner`: trims and strips `*`; returns nil for empty, for `ActionItemOwnership`'s unassigned words, and for folded `^(speaker|spreker|sprecher)\s*\d+$`, `others`, `anderen`, `me`, `ik`, `i`, `unknown speaker`.
- `merged`: concatenates in part order; action items whose `FuzzyText.similarity(task, task) ≥ 0.85` collapse into the one with higher confidence, filling its nil `owner/due/quote/timestamp` from the other; decisions likewise on `text`; topics de-duplicated on `normalized`.
- `fromMarkdown`: action items from `parsed.todoTexts` via `ActionItemOwnership.parse` (owner through `sanitizedOwner`, task = action, `confidence: 0.5`, no quote/timestamp, `dueIsExplicit: false`); decisions from `parsed.decisions`.
- `notesMarkdown()` renders (headings exact, sections with no items omitted; `[ts] ` prefix only when a timestamp exists):
~~~~text
### Topics discussed
- <topic>
### Decisions
- [<ts>] <text>
### Action items (owner: what)
- [<ts>] <owner or ?>: <task> (<due>)
### Open questions and risks
- [<ts>] <text>
### Notable statements and figures
- [<ts>] <text>
~~~~
- `RelativeDateResolver` (ISO-8601 calendar, Monday first, the injected time zone; Dutch and English, case/diacritic-insensitive, phrase may be embedded, e.g. "voor vrijdag"):
  - `nil`, empty, `"null"`, unparseable → `(nil, false)`.
  - `yyyy-MM-dd` → itself, `isExplicit = llmSaysExplicit`.
  - `vandaag/today` +0, `morgen/tomorrow` +1, `overmorgen/day after tomorrow` +2 → explicit.
  - weekday (`maandag…zondag`, `monday…sunday`, optional `aanstaande/komende/deze/this/next/volgende`) → the first such day **strictly after** the meeting day → explicit. `volgende week <weekday>` / `next week <weekday>` → that weekday in the next ISO week → explicit.
  - `over N dagen` / `in N days` → +N, explicit; `over N weken` / `in N weeks` → +7N, not explicit.
  - `volgende week` / `next week` → Monday of next ISO week, not explicit; `eind van de week` / `einde week` / `end of (the) week` → Friday of the meeting's week, or next week's Friday when the meeting is on Fri–Sun, not explicit; `eind van de maand` / `end of (the) month` → last day of the meeting's month, not explicit.
  - `<day> <month name>` / `<month name> <day>` (nl/en month names) → that date in the meeting's year, or next year when it is more than 30 days before the meeting → explicit.

Prompt copy (exact). `<date>` = meeting date as `yyyy-MM-dd`, `<weekday>` = English weekday name, both from the injected calendar.

`objectShape`:
~~~~text
{
  "topics": ["<short topic>"],
  "decisions": [{"text": "<decision with its rationale>", "quote": "<verbatim words from the transcript>", "timestamp": "<mm:ss or h:mm:ss>"}],
  "action_items": [{"task": "<the action>", "owner": "<name or null>", "due": "<YYYY-MM-DD, or the words used such as \"vrijdag\", or null>", "due_is_explicit": true, "confidence": 0.8, "quote": "<verbatim words from the transcript>", "timestamp": "<mm:ss or h:mm:ss>"}],
  "open_questions": [{"text": "<question or risk>", "timestamp": "<mm:ss or h:mm:ss>"}],
  "facts": [{"text": "<notable statement or figure>", "timestamp": "<mm:ss or h:mm:ss>"}]
}
~~~~

`rules(meetingDate:calendar:)`:
~~~~text
Rules for the JSON:
- Text values are in the language of the transcript; keys stay in English. Use [] for an empty list and never leave out a key.
- "quote" is copied word for word from the transcript (at most 25 words), without the [timestamp] and without the speaker label. Use null when the item comes from the user's notes rather than the transcript.
- "timestamp" is the [timestamp] of the transcript line the quote comes from, without brackets; null if unknown.
- Set "owner" only on explicit evidence: a named assignment ("Kim, wil jij…"), a first-person commitment by a labelled speaker ("Youri: ik pak dat op" makes Youri the owner), a commitment by the note-taker, or the user's own notes. Otherwise "owner" is null. Never use "me", "I" or a generic label such as "Speaker 1", "Spreker 2", "Others" or "Anderen" as an owner.
- The meeting took place on <date> (<weekday>). Write "due" as YYYY-MM-DD when you can resolve it from that date, otherwise the words that were used. "due_is_explicit" is true only when a specific day or date was said.
- "confidence" (0.0-1.0) is how sure you are that this was really agreed as an action.
~~~~

`singlePassInstruction(meetingDate:calendar:)` = the block below + `\n` + `objectShape` + `\n` + `rules(…)` + `\n- Every action item and decision in the notes appears in the JSON, and nothing else does.`
~~~~text
After the notes, add one fenced code block that starts with ```json and contains one valid JSON object with exactly this shape. Write nothing after the closing ```.
~~~~

`repairPrompt(broken:)`:
~~~~text
The text below was meant to be one JSON object with this shape, but it is not valid JSON:
<objectShape>
Return only the corrected JSON object — no prose and no code fence. Keep every item and every value; do not add items.

Text:
<broken>
~~~~

`rebuildPrompt(fromMarkdown:meetingDate:calendar:)` (single pass returned no JSON at all; input is the markdown's Decisions + Action Items sections only, never the transcript):
~~~~text
These are the closing sections of meeting notes. Turn them into one JSON object with exactly this shape:
<objectShape>
<rules>
Use null for "quote" and "timestamp" unless the notes show them. Return only the JSON object — no prose and no code fence.

Notes:
<closingSections>
~~~~

- [ ] **Step 1: Write the failing tests**
  - `SummaryFactsParserTests`: `testSplitsTrailingJSONBlockFromMarkdown` (markdown + ```` ```json{…}``` ```` → markdown has no ```` ``` ````, `jsonText` starts with `{`); `testTakesTheLastJSONBlock`; `testNoBlockLeavesMarkdownAndNilJSON`; `testExtractsBareObjectFromProse` (`"Here: {\"topics\":[]} ok"` → `{"topics":[]}`); `testDecodesFullObject` (all five lists, `confidence:"high"` → 0.9, `timestamp:"[01:05]"` → `"01:05"`); `testMissingKeysAreEmpty` (`{}` → `.success(.empty)`); `testArrayTopLevelIsInvalid`; `testGenericSpeakerLabelIsNeverAnOwner` (owners `"Spreker 2"`, `"Speaker 1"`, `"Anderen"`, `"?"` → all nil; `"Youri"` kept); `testRelativeDueIsResolvedAgainstMeetingDate` (meeting Wed 2026-11-04, due `"vrijdag"` → `"2026-11-06"`, explicit); `testMergedCollapsesFuzzyDuplicateTasks` (`"Stuur offerte naar Kim"` / `"Stuur de offerte naar Kim."` → 1 item, keeps the higher confidence, fills its nil owner); `testFromMarkdownUsesOwnerPrefix` (`"**Kim** — Bel leverancier"` → owner Kim, task "Bel leverancier", confidence 0.5); `testNotesMarkdownHeadingsAndTimestamps`.
  - `RelativeDateResolverTests` (meeting Wednesday 2026-11-04, Europe/Amsterdam): `testIsoPassesThrough`, `testTomorrowAndOvermorgen`, `testWeekdayOnSameWeekdayIsNextWeek` (meeting Fri 2026-11-06, `"vrijdag"` → `"2026-11-13"`), `testNextWeekWeekday` (`"volgende week dinsdag"` → `"2026-11-10"`), `testVolgendeWeekIsMondayNotExplicit` (→ `"2026-11-09"`, false), `testEndOfWeekOnSaturdayIsNextFriday`, `testDayMonthRollsToNextYear` (meeting 2026-12-20, `"5 januari"` → `"2027-01-05"`), `testGarbageIsNil`.
  - `FuzzyTextTests`: `testIdenticalAfterNormalisationIsOne` (`"Ik pak het op."` vs `"ik pak het op"` → 1.0), `testDiacriticsFold` (`"één"` vs `"een"` → 1.0), `testUnrelatedIsLow` (< 0.5), `testNearMissAboveThreshold` (one-word typo in an 8-word sentence ≥ 0.85).
- [ ] **Step 2: Run** `<TB_TEST> -only-testing:CasablancaTests/SummaryFactsParserTests -only-testing:CasablancaTests/RelativeDateResolverTests -only-testing:CasablancaTests/FuzzyTextTests` → FAIL (types missing).
- [ ] **Step 3: Implement** the three files.
- [ ] **Step 4: Run** the same command → PASS.
- [ ] **Step 5: Commit** `feat(summary): structured facts parser, relative due dates and fuzzy matching`.

---

## Task 3 (B1): Single pass returns facts — JSON block, repair retry, markdown fallback

**Files:**
- Modify: `Casablanca/Services/SummarizationService.swift`, `Casablanca/Services/MeetingPipelineState.swift` (status text for new phases)
- Test: `CasablancaTests/SummarizationServiceTests.swift`, `CasablancaTests/MeetingPipelineStateTests.swift`, new `CasablancaTests/Support/SummaryFixtures.swift`

**Interfaces:**
- Consumes: Task 2 (`SummaryFactsParser`, `SummaryFactsPrompt`, `SummaryFacts`).
- Produces:
```swift
extension SummarizationService {
  enum FactsSource: Equatable { case singlePassJSON, repairedJSON, mapJSON, markdownFallback }
  struct SummaryOutcome { let parsed: SummaryResponseParser.ParsedResponse; let facts: SummaryFacts
                          let factsSource: FactsSource; let templateID: String }
  static let factsFallbackWarning = "Couldn't read the structured action items; to-dos were taken from the summary text instead."
}
func summarizeWithFacts(meeting: Meeting, templateID: String? = nil) async throws -> SummaryOutcome
func summarize(meeting: Meeting) async throws -> SummaryResponseParser.ParsedResponse   // = summarizeWithFacts(meeting:).parsed (kept for callers/tests)
// SummarizationPhase gains: case repairing, verifying
// statusMessage: .repairing → "Repairing the structured notes…", .verifying → "Checking action items against the transcript…"
```
(`templateID` is accepted and echoed as `"general"` until Task 8 resolves it.) `SummarizationService.init` gains `calendar: Calendar = .current` (tests inject ISO-8601, Europe/Amsterdam) and `PromptContext` gains `let calendar: Calendar`; both feed `SummaryFactsPrompt` and `decodeFacts`.

Flow in a single pass: the prompt is `renderPrompt(…)` + `"\n\n"` + `SummaryFactsPrompt.singlePassInstruction(…)`, then the thinking switch; the JSON instruction counts toward `summaryOverhead`. After `stripReasoning`, `splitSinglePass` separates the block; `parsed` is parsed from the markdown **without** the block (so the stored summary never shows JSON).
- Block present and decodes → `.singlePassJSON`.
- Block present but invalid → one call (`.repairing`) with `repairPrompt(broken:)`, `maxTokens: LLMPromptSupport.cappedOutputTokens` (nil when thinking), decoded via `extractJSONObject` → `.repairedJSON`.
- No block → one call with `rebuildPrompt(fromMarkdown:)` given the markdown's Decisions + Action Items section text → `.repairedJSON`.
- Repair fails to decode, or the repair call throws a non-cancellation error → `SummaryFacts.fromMarkdown(parsed)`, `.markdownFallback`, `factsFallbackWarning` joined into `warningMessage`. Cancellation still propagates.

- [ ] **Step 1: Write the failing tests** (stubs return markdown + JSON built by `SummaryFixtures.withFacts(_ markdown: String, json: String = SummaryFixtures.emptyFactsJSON) -> String`)
  - `testSinglePassAsksForTheJSONBlockInTheSameCall`: one call; prompt contains "add one fenced code block that starts with ```json" and the meeting date as `yyyy-MM-dd`.
  - `testJSONBlockIsStrippedFromTheStoredSummary`: `outcome.parsed.rawMarkdown` contains no ```` ``` ````; `outcome.factsSource == .singlePassJSON`; `outcome.facts.actionItems.first?.owner == "Kim"`.
  - `testInvalidJSONGetsOneRepairCall`: outcomes `[withFacts(md, json: "{oops"), validJSON]` → 2 calls, 2nd prompt hasPrefix "The text below was meant to be one JSON object", `.repairedJSON`, `warningMessage == nil`.
  - `testMissingBlockRebuildsFromClosingSectionsWithoutTheTranscript`: outcomes `[md, validJSON]` → 2nd prompt hasPrefix "These are the closing sections", does not contain the transcript.
  - `testBrokenJSONAfterRepairFallsBackToMarkdownItems`: outcomes `[md with "- **Youri** — Mail Kim", "still {bad"]` → `.markdownFallback`, `facts.actionItems.map(\.task) == ["Mail Kim"]`, `warningMessage` contains `factsFallbackWarning`.
  - `testPhaseShowsRepairing` (onGenerate records `service.phase` on the 2nd call == `.repairing`).
  - Each of the above runs once with a transcript **with** `[00:10] Kim: …` prefixes and once without (two `func test…` or a loop over both fixtures).
  - Update existing single-pass tests whose stub returns bare markdown (`testSummarizeUsesTheProvidersPreferredTimeoutWhenItHasOne`, `…KeepsItsOwnTimeout…`, `…ReadsItsSettingsFromTheInjectedDefaults`, `…UsesTheInjectedRetryPolicy`, `…WarnsWhenTheProviderReportsTruncatedOutput`, `testShortTranscriptOnASmallBudgetIsOneCallWithTheWholeTranscript`) to wrap their outcome in `SummaryFixtures.withFacts`; their assertions stay.
  - `MeetingPipelineStateTests.testVerifyingPhaseFallsBackToGeneratingSummary` (`.verifying` → "Generating summary…" in the pipeline card, unchanged default branch).
- [ ] **Step 2: Run** `<TB_TEST> -only-testing:CasablancaTests/SummarizationServiceTests -only-testing:CasablancaTests/MeetingPipelineStateTests` → new tests FAIL.
- [ ] **Step 3: Implement** the flow above in `SummarizationService.swift`.
- [ ] **Step 4: Run** the same command → PASS.
- [ ] **Step 5: Commit** `feat(summary): extract facts in the single-pass call with repair and markdown fallback`.

---

## Task 4 (B1): Map step returns JSON facts; Claude one-pass cap

**Files:**
- Modify: `Casablanca/Services/SummarizationService.swift` (`mapPrompt`, `mapParts`, `CondensedPartKey`, cache value type, `fitsInOnePass`, reduce input)
- Test: `CasablancaTests/SummarizationServiceTests.swift`, `CasablancaTests/Support/SummaryFixtures.swift`

**Interfaces:**
- Consumes: Task 2, Task 3 (`FactsSource`, `SummaryOutcome`, `.repairing`), Task 1 (`mapFocusTokens`).
- Produces:
```swift
static let onePassTokenCap = 25_000          // single pass and map chunking use min(provider.promptTokenBudget, onePassTokenCap)
static func mapPrompt(chunk: TranscriptChunk, total: Int, context: PromptContext) -> String   // new copy below
static let reducedActionItemsHeading = "Action items already extracted from the transcript (de-duplicated; use exactly these in the action items section):"
// CondensedPartKey gains: let focusSHA256: String
// condensedPartCache value: enum CondensedPart { case facts(SummaryFacts), markdown(String) }
```

Rules:
- `fitsInOnePass` and `chunkTokens(budget:…)` use `min(provider.promptTokenBudget, onePassTokenCap)`; merge and reduce capacity keep the provider's full budget.
- Each map output → `extractJSONObject` → `decodeFacts`. Invalid → one repair call (`.repairing`, same `repairPrompt`) → if still invalid the part is cached as `.markdown(rawText)` (today's behaviour).
- If every part decoded: `facts = SummaryFacts.merged(parts)`, `CondensedNote.text = partFacts.notesMarkdown()`, `.mapJSON`; the reduce prompt's `{{transcript}}` is `reduceJoin(notes)` + `"\n\n" + reducedActionItemsHeading + "\n"` + one `- ` line per merged action item (`ActionItemRendering` is not available yet: render `**<owner or ?>** — <task>` inline here; Task 5 swaps in `ActionItemRendering.bullet`). The reduce gets **no** JSON instruction.
- If any part is `.markdown`: notes for decoded parts still use `notesMarkdown()`, raw text for the others; the reduce gets no action-item list; facts come from `SummaryFacts.fromMarkdown` on the reduce output → `.markdownFallback` + `factsFallbackWarning`.
- Map prompt (exact; `\(…)` are the existing interpolations, `\(focus)` is `SummaryPromptContext.focusBlock(prep:notes:maxTokens: mapFocusTokens)` + `"\n"` or empty):
~~~~text
You are extracting facts from part \(chunk.index + 1) of \(total) of a meeting transcript
(\(chunk.startLabel ?? "?")–\(chunk.endLabel ?? "?")) so it can be summarized later.
\(meetingLine(context: context))
\(terminology)\(focus)Return only one JSON object, no prose and no code fence, with exactly this shape:
\(SummaryFactsPrompt.objectShape)
\(SummaryFactsPrompt.rules(meetingDate: context.meeting.date, calendar: context.calendar))
Only use this part of the transcript.

Transcript part:
\(chunk.text)
~~~~
  (`context.calendar` is the one Task 3 added.)

- [ ] **Step 1: Write the failing tests**
  - `testALongTranscriptOverTheOnePassCapIsChunkedOnALargeBudgetProvider` (replaces `testSummarizeSendsALongTranscriptWholeToALargeBudgetProvider`): 147 000-char transcript, budget 100 000 → `mapCalls.count >= 2`, every map prompt ≤ 25 000 budget tokens, last call is the reduce.
  - `testMapPromptAsksForJSONAndKeepsTheHeaderLines`: header lines 0–2 as today but line 0 hasPrefix "You are extracting facts from part 1 of", line 3 == "Return only one JSON object, no prose and no code fence, with exactly this shape:".
  - `testReduceGetsDeduplicatedActionItemsFromTheParts`: two parts each returning the same item `"Stuur offerte"` owner Kim → reduce prompt contains `reducedActionItemsHeading` and exactly one `**Kim** — Stuur offerte`; `outcome.factsSource == .mapJSON`; `outcome.facts.actionItems.count == 1`.
  - `testAPartWithBrokenJSONIsRepairedOnce`: part 2 returns `"{bad"`, repair returns valid → one extra call, `.mapJSON`.
  - `testAPartWithBrokenJSONSwitchesTheWholeRunToTheMarkdownFallback`: part 2 and its repair invalid; reduce returns markdown with `- **Youri** — Plan demo` → `.markdownFallback`, `facts.actionItems.map(\.task) == ["Plan demo"]`, warning contains `factsFallbackWarning`.
  - `testRetryReusesCachedFactsParts` (variant of the existing cache test with JSON outcomes): after a failed part 3, retry makes no calls for parts 1–2.
  - `testChangedPrepInvalidatesTheMapCache`: same meeting, prep changed between runs → all parts re-mapped.
  - Speaker-prefix variant: run `testReduceGetsDeduplicatedActionItemsFromTheParts` on a transcript with `Spreker 1:` prefixes and on one without.
  - Update existing map-reduce tests: `numberedNotes` returns `SummaryFixtures.partJSON(topic: "NOTE-%02d")` (`{"topics":["NOTE-01"]}` etc.), `isMapCall` checks `hasPrefix("You are extracting facts from part")`, and `testLongTranscriptOnASmallBudgetIsCondensedInPartsThenReducedWithTheTemplate`'s header-line assertions move to the new copy; the "NOTE-xx in order" and budget assertions stay.
- [ ] **Step 2: Run** `<TB_TEST> -only-testing:CasablancaTests/SummarizationServiceTests` → new tests FAIL.
- [ ] **Step 3: Implement** the rules above.
- [ ] **Step 4: Run** the same command → PASS.
- [ ] **Step 5: Commit** `feat(summary): JSON facts per map part and a 25k one-pass cap`.

---

## Task 5 (B2): Render sections from structured items; store items; create proposed to-dos

**Files:**
- Create: `Casablanca/Services/ActionItemRendering.swift`, `Casablanca/Services/TodoReviewService.swift` (proposal half only)
- Modify: `Casablanca/Services/SummaryResponseParser.swift` (expose aliases), `Casablanca/Services/SummarizationService.swift` (`summarizeWithFacts` rendering, `summarizeInBackground`), `Casablanca/Services/ObsidianTodoSyncService.swift` (skip non-accepted), `Casablanca/Views/MeetingDetail/MeetingSummaryTab.swift` (matching only)
- Test: `CasablancaTests/ActionItemRenderingTests.swift`, `CasablancaTests/TodoReviewServiceTests.swift`, `CasablancaTests/SummaryResponseParserTests.swift`, `CasablancaTests/ObsidianTodoSyncServiceTests.swift`, `CasablancaTests/SummarizationServiceTests.swift`

**Interfaces:**
- Consumes: Tasks 2–4; Phase 0 `Meeting.actionItems`, `TodoItem` V3 fields.
- Produces:
```swift
extension SummaryResponseParser { enum Field { case decisions, actionItems }; static func headingAliases(for field: Field) -> [String] }
enum ActionItemRendering {
  static let unverifiedDecisionPrefix = "⚠︎ "
  static func bullet(for item: ExtractedActionItem) -> String     // "**Kim** — Stuur offerte (2026-11-06) [12:34]"; owner nil → "**?**"
  static func decisionBullet(for decision: ExtractedDecision) -> String   // "<text> [12:34]"; .unsupported → prefix "⚠︎ "
  static func replacingSection(_ field: SummaryResponseParser.Field, in markdown: String, bullets: [String]) -> String
  static func strippingSuffix(_ action: String) -> String          // drops trailing " (yyyy-MM-dd)" and " [mm:ss]"/" [h:mm:ss]"
  static func render(_ facts: SummaryFacts, into markdown: String) -> String   // both sections
}
enum ProposedTodoPlanner {
  static func itemsToPropose(_ items: [ExtractedActionItem], aliases: [String], includeUnassigned: Bool) -> [ExtractedActionItem]
}
@MainActor enum TodoReviewService {
  static func replaceProposedTodos(for meeting: Meeting, with items: [ExtractedActionItem], in context: ModelContext) throws
}
// SummaryOutcome.parsed now parses the rendered markdown.
```

Rules:
- `replacingSection`: finds the first `## ` heading matching the field's aliases (same normalisation as the parser) and replaces its body up to the next `## `/`# ` heading with `bullets` as `- ` lines followed by one blank line (empty list → heading with nothing below). Missing heading → inserts one: Dutch (`## Besluiten` / `## Actiepunten`) when the markdown contains `# Samenvatting` or a Dutch alias heading, else English; Decisions before Action Items; Action Items directly after Decisions, else before the risks heading, else at the end.
- `render` runs only for `.singlePassJSON`, `.repairedJSON`, `.mapJSON`; a `.markdownFallback` summary is stored exactly as the model wrote it.
- `itemsToPropose`: the user's own items (`ActionItemOwnership.owner(_:matchesAnyOf: aliases)`), plus `owner == nil` items when `includeUnassigned`.
- `replaceProposedTodos` (B2 version): deletes the meeting's `.proposed` todos; inserts one `TodoItem` per item with `text = task`, `owner`, `dueDate` (ISO `yyyy-MM-dd` at local midnight), `sourceTimestamp = timestamp`, `quote`, `status = .proposed`, `verification = item.verified`, `sourceFilePath = nil`, `meeting`; skips items whose task equals (trimmed) the text of an existing non-proposed todo. (Task 10 replaces the dedupe with the spec's fuzzy regeneration rules.)
- `summarizeInBackground(meeting:modelContext:templateID: String? = nil)`: stores `meeting.summary = outcome.parsed.rawMarkdown`, `meeting.actionItems = outcome.facts.actionItems` (all owners), `meeting.summaryTemplateID = outcome.templateID`, then `replaceProposedTodos(… itemsToPropose(…))`, then saves. The old `ActionItemOwnership.todoTexts` + `createMeetingTodo` loop is removed.
- `ObsidianTodoSyncService`: `bootstrapLegacyGenericTodos`, `bootstrapLegacyMeetingTodos`, `removeMissingGenericRows`, `removeMissingMeetingRows` only consider `status == .accepted` rows.
- `MeetingSummaryTab.matchingTodo(for:)` compares against `ActionItemRendering.strippingSuffix(action)` too, and ignores `.rejected` todos; a `.proposed` match shows a small "In review" capsule instead of the checkbox (no toggle).

- [ ] **Step 1: Write the failing tests**
  - `ActionItemRenderingTests`: `testBulletWithOwnerDueAndTimestamp` (`"**Kim** — Stuur offerte (2026-11-06) [12:34]"`); `testBulletWithoutOwnerUsesQuestionMark`; `testUnsupportedDecisionGetsWarningPrefix`; `testReplacesDutchActiepuntenBody` (other sections byte-identical); `testInsertsMissingSectionAfterDecisions`; `testEmptyListKeepsHeading`; `testRenderedSummaryRoundTripsThroughParserAndOwnership` (render → `SummaryResponseParser.parse(…).todoTexts` → `ActionItemOwnership.parse` → owner `Kim`, `strippingSuffix(action) == "Stuur offerte"`); `testStrippingSuffixLeavesPlainTextAlone` (`"Bel [Kim]"` unchanged).
  - `SummaryResponseParserTests.testHeadingAliasesMatchParser` (`headingAliases(for: .actionItems)` contains `"Actiepunten"`).
  - `TodoReviewServiceTests`: `testProposedTodosCarryStructuredFields` (status `.proposed`, `sourceFilePath == nil`, `dueDate` == 2026-11-06 local midnight, `sourceTimestamp == "12:34"`); `testReplaceDropsOnlyPendingProposed` (an accepted and a rejected todo survive, an old proposed is gone); `testItemsToProposeRespectsOwnershipAndUnassignedSetting`.
  - `ObsidianTodoSyncServiceTests.testRefreshNeverWritesProposedTodosToTheVault` (meeting with one `.proposed` row, `sourceFilePath == nil` → after `refreshTodos`, the notes file does not contain its text and the row still exists, status `.proposed`); `testRefreshStillBootstrapsLegacyAcceptedTodos` (existing behaviour, accepted row with nil path is written).
  - `SummarizationServiceTests.testBackgroundSummaryStoresAllItemsAndProposesOnlyMine` (facts: Youri item + Kim item; aliases `Youri` → `meeting.actionItems.count == 2`, one todo, `.proposed`; `meeting.summary` contains `**Kim** — `); `testFallbackSummaryIsStoredVerbatim`; `testLegacySummaryRendersUnchanged` (a meeting whose summary predates Track B: `SummaryResponseParser.parse(meeting.summary!)` output equals the pre-change fixture; no `actionItemsData`).
- [ ] **Step 2: Run** `<TB_TEST> -only-testing:CasablancaTests/ActionItemRenderingTests -only-testing:CasablancaTests/TodoReviewServiceTests -only-testing:CasablancaTests/SummaryResponseParserTests -only-testing:CasablancaTests/ObsidianTodoSyncServiceTests -only-testing:CasablancaTests/SummarizationServiceTests -only-testing:CasablancaTests/ActionItemOwnershipTests` → FAIL.
- [ ] **Step 3: Implement** per the rules; replace Task 4's inline reduce bullet with `ActionItemRendering.bullet`.
- [ ] **Step 4: Run** the same command → PASS.
- [ ] **Step 5: In-app check** — build, open an old meeting's summary tab: identical to before; toggle an action item → still syncs.
- [ ] **Step 6: Commit** `feat(summary): render action items from structured data and propose to-dos`.

---

## Task 6 (B3, deterministic): Quote pre-check and transcript windows

**Files:**
- Create: `Casablanca/Services/ActionItemVerifier.swift` (pre-check + `TranscriptIndex`; LLM half added in Task 7)
- Test: `CasablancaTests/ActionItemVerifierTests.swift`

**Interfaces:**
- Consumes: `FuzzyText`, `TranscriptLineFormat.parse(_:knownSpeakers:)`, `SummaryFacts`, `ExtractedDecision`.
- Produces:
```swift
struct TranscriptIndex {
  init(transcript: String, knownSpeakers: Set<String>)
  let lines: [TranscriptLine]                                    // lines without a [ts] attach to the previous line's text
  func window(around seconds: Double, radius: Double) -> [TranscriptLine]
  func locate(quote: String, near seconds: Double?) -> (score: Double, line: TranscriptLine?)
}
enum ActionItemVerifier {
  static let windowRadius: Double = 60
  static let quoteNotFoundReason = "The quoted words do not occur in the transcript."
  enum ClaimKind: String { case actionItem = "action item", decision }
  struct Claim: Equatable { let id: String /* "a1", "d1" */; let kind: ClaimKind; let text: String; let owner: String?
                            let due: String?; let quote: String; let seconds: Double }
  static func precheck(_ facts: SummaryFacts, index: TranscriptIndex) -> (facts: SummaryFacts, claims: [Claim])
}
```

Rules:
- `locate`: haystack = normalised (`FuzzyText.normalized`) line texts, with timestamps and known speaker prefixes removed, joined by spaces. Exact normalised substring → score 1.0. Otherwise slide windows of `k−1…k+1` tokens (`k` = quote token count) and score with `FuzzyText.similarity`: first over the lines inside `window(around: seconds, radius: 60)` when `seconds` is known, then — only if that is below 0.85 — over the whole transcript restricted to offsets whose token equals one of the quote's first two tokens. Returns the best score and the line where the best window starts.
- `precheck`: quote `nil`/empty → item stays `.unverified`, no claim (from the user's notes; never auto-accepted). Score `< FuzzyText.matchThreshold` → `.unsupported`, `verificationReason = quoteNotFoundReason`, no claim. Score ≥ 0.85 → timestamp replaced by the located line's label (fixes a mis-cited `[mm:ss]`) and a `Claim` is emitted (ids `a1…` for action items, `d1…` for decisions, in list order).
- `knownSpeakers` = `meeting.speakers.map(\.displayName)`; for old transcripts it is empty and `Kim: …` stays part of the line text (substring search still finds a quote inside it).

- [ ] **Step 1: Write the failing tests** (each on a transcript with `Youri:`/`Spreker 1:` prefixes and known speakers, and on the same transcript without prefixes)
  - `testExactQuoteIsFoundAndTimestampCorrected`: quote at `[03:10]`, item cites `"01:00"` → claim emitted, item timestamp `"03:10"`.
  - `testQuoteWithOneTranscriptionErrorStillMatches` (≥ 0.85).
  - `testInventedQuoteIsUnsupportedWithoutAClaim` (`verified == .unsupported`, reason `quoteNotFoundReason`, `claims.isEmpty`).
  - `testNilQuoteStaysUnverified`.
  - `testQuoteSpanningTwoLinesMatches`.
  - `testWindowIsSixtySecondsEachSide` (lines at 0, 59, 61, 125 s around 60 s → labels at 0, 59, 61 s… exactly those with |Δ| ≤ 60).
  - `testHourLabelsParse` (`[1:02:03]`).
  - `testDecisionsGetDIds` (`d1`, `d2`).
- [ ] **Step 2: Run** `<TB_TEST> -only-testing:CasablancaTests/ActionItemVerifierTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the same command → PASS.
- [ ] **Step 5: Commit** `feat(summary): deterministic quote pre-check for action items and decisions`.

---

## Task 7 (B3): One verification call and its wiring

**Files:**
- Modify: `Casablanca/Services/ActionItemVerifier.swift`, `Casablanca/Services/SummarizationService.swift`
- Test: `CasablancaTests/ActionItemVerifierTests.swift`, `CasablancaTests/SummarizationServiceTests.swift`

**Interfaces:**
- Consumes: Task 6; Task 3 phases; `LLMPromptSupport.middleElide`.
- Produces:
```swift
extension ActionItemVerifier {
  static func prompt(claims: [Claim], index: TranscriptIndex, meetingDate: Date, calendar: Calendar, budgetTokens: Int) -> String
  static func apply(response: String, claims: [Claim], to facts: SummaryFacts) -> SummaryFacts?   // nil when no JSON array can be read
}
extension SummarizationService { static let verificationFailedWarning = "Couldn't check the action items against the transcript; review them before accepting." }
```

Rules:
- Runs inside `summarizeWithFacts` after facts are final and **before** `ActionItemRendering.render` (so decision prefixes reflect it), phase `.verifying`, on the **original** transcript. Skipped (no call, no phase) for `.markdownFallback` or when `claims` is empty.
- Budget: if the prompt exceeds `min(provider.promptTokenBudget, onePassTokenCap)`, rebuild with radius 30 s; still too large → each excerpt is `middleElide`d to an equal share. Always one call.
- `apply`: parses a JSON array (`extractJSONObject` generalised: first `[` to last `]`); `supported == true` → `.supported`; `false` → `.unsupported` with `reason`; claim ids missing from the answer stay `.unverified`. Unreadable → one repair call (prompt below) → still unreadable, or any non-cancellation error → facts unchanged (`.unverified`) and `verificationFailedWarning` added. The summary itself never fails because of verification.
- Verification prompt (exact; one block per claim; `Owner`/`Due` lines read `none` when nil):
~~~~text
You are checking meeting notes against the transcript they were written from.
For each claim below, decide whether the transcript excerpt supports it. A decision is supported only if the excerpt shows it was actually decided or agreed. An action item is supported only if the excerpt shows the action was taken on — by the named owner, if one is given — and the due date, if one is given, was said or clearly implied.
Answer with only one JSON array, no prose and no code fence, with one object per claim in the same order:
[{"id": "<claim id>", "supported": true, "reason": "<one short sentence in the language of the transcript>"}]
When in doubt, answer false.

Meeting date: <yyyy-MM-dd>

Claims:
### <id> (<kind>)
Claim: <text>
Owner: <owner>
Due: <due>
Quote: "<quote>"
Transcript excerpt (<first label>–<last label>):
<window lines, original text>
~~~~
- Verification repair prompt (exact):
~~~~text
The text below was meant to be one JSON array of objects {"id": "...", "supported": true or false, "reason": "..."}, but it is not valid JSON. Return only the corrected JSON array — no prose and no code fence. Keep every entry; do not add entries.

Text:
<broken>
~~~~

- [ ] **Step 1: Write the failing tests**
  - `ActionItemVerifierTests.testPromptListsEveryClaimWithItsWindow` (2 claims → 2 `### a1 (action item)`/`### d1 (decision)` blocks, each excerpt only ±60 s lines); `testPromptShrinksWindowsToFitTheBudget` (budget 800 → ≤ 800 budget tokens, still contains every claim id); `testApplyMapsSupportedAndUnsupported` (reason kept); `testApplyMissingIdStaysUnverified`; `testApplyUnreadableIsNil`.
  - `SummarizationServiceTests.testVerificationIsOneCallAfterTheSummary`: facts with 2 quoted items + 1 decision found in the transcript → 2 calls; 2nd hasPrefix "You are checking meeting notes"; phase on that call `.verifying`; decision marked unsupported by the stub renders `- ⚠︎ ` in `## Decisions`; `meeting.actionItems` (via background) carry `.supported`/`.unsupported`.
  - `testInventedQuoteNeverReachesTheVerifierCall` (only the found item's id in the prompt).
  - `testNoVerificationCallForMarkdownFallback` and `testNoVerificationCallWithoutQuotes`.
  - `testVerifierFailureKeepsSummaryAndWarns` (verifier call throws non-transient error → outcome returned, items `.unverified`, warning == `verificationFailedWarning`).
  - Run the first SummarizationService test on transcripts with and without speaker prefixes.
- [ ] **Step 2: Run** `<TB_TEST> -only-testing:CasablancaTests/ActionItemVerifierTests -only-testing:CasablancaTests/SummarizationServiceTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the same command → PASS.
- [ ] **Step 5: Commit** `feat(summary): verify action items and decisions against the transcript`.

---

## Task 8 (B5): Built-in templates, template store, auto-selection

**Files:**
- Create: `Casablanca/Services/SummaryTemplates.swift`
- Modify: `Casablanca/Services/SummarizationService.swift` (`defaultPromptTemplate` = General composition; template resolution in `summarizeWithFacts`)
- Test: `CasablancaTests/SummaryTemplatesTests.swift`, `CasablancaTests/SummarizationServiceTests.swift`

**Interfaces:**
- Consumes: Task 1 (`MeetingAttendee`, attendee provider), `AppPreferenceKey.summaryTemplates`, `AppPreferenceKey.summaryPromptTemplate`.
- Produces:
```swift
struct SummaryTemplate: Codable, Equatable, Identifiable { var id: String; var name: String; var prompt: String; var isBuiltIn: Bool }
enum SummaryTemplateID { static let general = "general", oneOnOne = "one-on-one", standup = "standup",
                         refinement = "refinement", external = "external", workshop = "workshop" }
enum SummaryTemplateCatalog {
  static func compose(structure: String) -> String     // defaultPromptTemplate with its items 2.–4. replaced by `structure`
  static let generalStructure, oneOnOneStructure, standupStructure, refinementStructure, externalStructure, workshopStructure: String
  static let builtIns: [SummaryTemplate]               // order: General, 1:1 / bilateral, Stand-up, Refinement / planning, External / partner, Workshop
}
enum SummaryTemplateStore {
  static func all(in defaults: UserDefaults) -> [SummaryTemplate]          // built-ins (overrides applied) then custom, by name
  static func template(id: String?, in defaults: UserDefaults) -> SummaryTemplate   // nil/unknown → General
  static func save(_ template: SummaryTemplate, in defaults: UserDefaults)
  static func delete(id: String, in defaults: UserDefaults)                // custom only; built-ins ignored
  static func reset(id: String, in defaults: UserDefaults)                 // built-in: drop override; General: remove summaryPromptTemplate
  static func isModified(id: String, in defaults: UserDefaults) -> Bool
}
enum SummaryTemplateSelector {
  static func templateID(title: String, participants: [String], attendees: [MeetingAttendee], userAliases: [String]) -> String
}
```

Rules:
- General's prompt is the `summaryPromptTemplate` value when set (legacy, still edited by today's Settings editor), else `defaultPromptTemplate`. Other overrides and custom templates (`id = "custom-<UUID>"`, `isBuiltIn: false`) are a JSON `[SummaryTemplate]` in `summaryTemplates`; unreadable JSON → built-ins only.
- `compose(structure: generalStructure) == SummarizationService.defaultPromptTemplate` (byte-identical; `generalStructure` is today's items 2.–4.).
- Selector, first match wins (folded title, word-boundary match): `stand-up|standup|daily|dagstart` → standup; `refinement|refinen|planning|sprintplanning|grooming|backlog` → refinement; `workshop|brainstorm|hackathon` → workshop; `bila|bilateral|bilateraal|1-op-1|1:1|1on1|1-1|one-on-one` → oneOnOne; any attendee e-mail whose domain differs from the user's domain (the `isCurrentUser` attendee's domain, else the most common attendee domain) → external; exactly 2 people (participants ∪ attendees, by folded name) → oneOnOne; else general.
- Resolution in `summarizeWithFacts`: explicit `templateID` → `meeting.summaryTemplateID` → selector. The chosen template's prompt replaces the `summaryPromptTemplate` read; `outcome.templateID` is the resolved id.
- Structure texts (exact; each replaces items 2.–4.):

`oneOnOneStructure`:
~~~~text
2. Then these sections, each only when it has content: `## Hoe gaat het` / `## Check-in` (wellbeing, workload, energy), `## Voortgang` / `## Progress` (what moved since last time), `## Feedback` (given and received, both directions, in neutral wording), `## Ontwikkeling` / `## Growth` (career, learning, goals).
3. Keep personal remarks factual and brief; leave out anything that reads as private gossip.
4. If the date or topics of the next 1:1 were agreed, put them under `## Opvolging` / `## Follow-ups`.
~~~~
`standupStructure`:
~~~~text
2. Then one `## Per persoon` / `## Per person` section with one bullet per speaker: `- **<name>:** <yesterday> · <today> · <blockers>`. Use only what each person said.
3. Keep it short: the opening paragraph has at most 2 sentences and there are no thematic sections.
4. Put every blocker, with its owner, under `## Risico's en blockers` / `## Risks and Blockers`.
~~~~
`refinementStructure`:
~~~~text
2. Then one `## <item>` section per backlog item or story discussed (start with its key, e.g. `IO-1234`, when it was said), with bullets for the agreed scope, open questions, acceptance criteria, the estimate (`- **Estimate:** 5 SP`) and whether it is ready for a sprint.
3. If a sprint goal or capacity was discussed, add a `## Sprintdoel` / `## Sprint goal` section.
4. Put items that were explicitly not ready, with the reason, under `## Risico's en blockers` / `## Risks and Blockers`.
~~~~
`externalStructure`:
~~~~text
2. Then the sections `## Context` (who the other party is and why the meeting took place, only as stated), `## Hun vraag` / `## Their ask`, `## Ons standpunt` / `## Our position` and `## Afspraken` / `## Agreements` (commitments in both directions, each with the party that made it).
3. Mark anything the other party asked to keep confidential with `(vertrouwelijk)` / `(confidential)`.
4. If planning or the next contact was discussed, add a `## Planning` section with chronological bullets: `- **<period>** — <milestone or activity>`.
~~~~
`workshopStructure`:
~~~~text
2. Then `## Doel` / `## Goal` (one sentence), followed by one `## <theme>` section per cluster of ideas, with the ideas as bullets and who raised them when that was said.
3. Add `## Keuzes` / `## Choices` for options that were chosen or dropped, with the reason.
4. Add `## Parkeerplaats` / `## Parking lot` for ideas deferred to later.
~~~~

- [ ] **Step 1: Write the failing tests** (`SummaryTemplatesTests`)
  - `testGeneralComposesToTheDefaultTemplate`.
  - `testEveryBuiltInKeepsTheFourClosingHeadingsAndPlaceholders` (`Besluiten`, `Actiepunten`, `{{transcript}}`, `{{user_focus}}`, `{{participants}}` in each).
  - `testGeneralUsesLegacyPromptKey` (`summaryPromptTemplate = "X {{transcript}}"` → `template(id: "general").prompt == "X {{transcript}}"`).
  - `testSaveOverrideResetBuiltIn` / `testCustomTemplateAddDelete` / `testDeleteIgnoresBuiltIn` / `testGarbageJSONFallsBackToBuiltIns` / `testUnknownIdIsGeneral`.
  - Selector: `testBilaTitleIsOneOnOne` ("Bila Martijn"), `testDailyIsStandup` ("Daily Team Link"), `testRefinement` ("Refinement IO"), `testWorkshopTitle`, `testExternalDomain` (user `youri@medicore.nl`, attendee `kim@partner.nl`, title "Afstemming"), `testTwoPeopleIsOneOnOne`, `testTitleBeatsAttendeeHeuristics` ("Daily" with an external attendee → standup), `testDefaultIsGeneral`, `testDailyInsideAWordDoesNotMatch` ("Dailymotion review" → general).
  - `SummarizationServiceTests.testAutoSelectedTemplateIsUsedAndReturned` (title "Daily stand-up" → prompt contains `## Per persoon`, `outcome.templateID == "standup"`); `testMeetingOverrideBeatsSelector`; `testExplicitTemplateBeatsMeetingOverride`.
- [ ] **Step 2: Run** `<TB_TEST> -only-testing:CasablancaTests/SummaryTemplatesTests -only-testing:CasablancaTests/SummarizationServiceTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the same command → PASS.
- [ ] **Step 5: Commit** `feat(summary): built-in templates per meeting type with auto-selection`.

---

## Task 9 (B5): Template settings and "Regenerate with…"

**Files:**
- Modify: `Casablanca/Views/Settings/SummaryTemplatesSettingsSection.swift` (Phase 0 placeholder, track-owned), `Casablanca/Views/MeetingDetail/MeetingSummaryTab.swift`
- Create: `Casablanca/Views/Components/SummaryTemplateMenu.swift`
- Test: `CasablancaTests/SummaryTemplatesTests.swift` (menu presentation)

**Interfaces:**
- Consumes: Task 8 store/selector; `SummarizationService.summarizeInBackground(meeting:modelContext:templateID:)`.
- Produces:
```swift
struct SummaryTemplateMenuPresentation {   // pure, tested
  init(templates: [SummaryTemplate], currentID: String?, autoID: String)
  var currentName: String                  // "1:1 / bilateral" or "General (auto)" when currentID == nil
  var items: [(id: String, name: String, isCurrent: Bool)]
}
struct SummaryTemplateMenu: View { let meeting: Meeting; let onPick: (String) -> Void }  // Menu "Regenerate with…" + current template label
```

Rules:
- Summary hero header: a caption `Template: <currentName>` and a `Menu("Regenerate with…")` listing all templates (checkmark on current); picking one sets `meeting.summaryTemplateID` and calls `appModel.summarizationService.summarizeInBackground(meeting:modelContext:templateID:)`. Disabled while summarizing.
- Settings section: list of templates (name + "Modified" badge from `isModified`), a selected template's name field and `TextEditor` for its prompt, buttons Add (copies General with name "New template"), Delete (custom only), Reset (built-ins). Saving writes through `SummaryTemplateStore.save` (General → `summaryPromptTemplate`).
- **Phase 2 handoff:** remove the legacy summary-prompt `TextEditor` + reset button from `Views/SettingsView.swift` (~:620-645) — both edit the same key, so they coexist harmlessly until then.

- [ ] **Step 1: Write the failing tests** `testMenuPresentationMarksCurrent`, `testMenuPresentationShowsAutoWhenNoOverride`.
- [ ] **Step 2: Run** `<TB_TEST> -only-testing:CasablancaTests/SummaryTemplatesTests` → FAIL.
- [ ] **Step 3: Implement** the menu, the hero header change and the settings section.
- [ ] **Step 4: Run** the same command → PASS.
- [ ] **Step 5: In-app check** — build and run: Settings → AI shows the templates section and editing General updates the legacy editor's text; on a summarized meeting, "Regenerate with… → Stand-up" regenerates and the header shows "Stand-up". Narrow the window to its minimum width: no constraint-loop warning in the console (constraint-pass probe as in `project_casablanca-view-verification`).
- [ ] **Step 6: Commit** `feat(ui): summary template settings and regenerate-with menu`.

---

## Task 10 (B6): Accept / edit / reject, accepted-only sync and export, decision log, regeneration rules

**Files:**
- Modify: `Casablanca/Services/TodoReviewService.swift`, `Casablanca/Services/ObsidianTodoMarkdown.swift` (`TaskLine` fields, suffix render/parse), `Casablanca/Services/ObsidianTodoSyncService.swift` (accepted write, upsert of suffix fields), `Casablanca/Services/ObsidianMeetingExporter.swift` (accepted-only list with suffix), `Casablanca/Services/AppleNotesBodyRenderer.swift` (accepted-only list with suffix), `Casablanca/Services/SummarizationService.swift` (auto-accept after summary)
- Create: `Casablanca/Services/TodoDecisionLog.swift`
- Test: `CasablancaTests/TodoReviewServiceTests.swift`, `CasablancaTests/TodoDecisionLogTests.swift`, `CasablancaTests/ObsidianTodoMarkdownTests.swift`, `CasablancaTests/ObsidianTodoSyncServiceTests.swift`, `CasablancaTests/ExportServiceTests.swift`, `CasablancaTests/AppleNotesBodyRendererTests.swift`

**Interfaces:**
- Consumes: Task 5 (`replaceProposedTodos`), `FuzzyText`, `AppPreferenceKey.autoAcceptVerifiedTodos`.
- Produces:
```swift
// ObsidianTodoMarkdown.TaskLine gains: var owner: String? = nil; var due: String? = nil /* yyyy-MM-dd */; var timestamp: String? = nil
extension ObsidianTodoMarkdown { static func suffix(owner: String?, due: String?, timestamp: String?) -> String }  // "" or " — Youri 📅 2026-11-06 [12:34]"
@MainActor enum TodoReviewService {
  static func replaceProposedTodos(for: Meeting, with: [ExtractedActionItem], in: ModelContext) throws   // now with regeneration rules
  static func accept(_ todo: TodoItem, in: ModelContext, userDefaults: UserDefaults = .standard,
                     fileManager: FileManager = .default, log: TodoDecisionLog = .shared, auto: Bool = false) throws
  static func reject(_ todo: TodoItem, in: ModelContext, log: TodoDecisionLog = .shared) throws
  static func edit(_ todo: TodoItem, task: String, owner: String?, dueDate: Date?, in: ModelContext, log: TodoDecisionLog = .shared) throws
  @discardableResult static func acceptAllVerified(in meeting: Meeting, in: ModelContext, userDefaults:, fileManager:, log:) throws -> Int
}
extension ObsidianTodoSyncService {
  static func writeAcceptedMeetingTodo(_ todo: TodoItem, in: ModelContext, userDefaults: UserDefaults = .standard, fileManager: FileManager = .default) throws
}
struct TodoDecisionEntry: Codable, Equatable {
  enum Action: String, Codable { case accept, reject, edit, autoAccept = "auto_accept" }
  struct Item: Codable, Equatable { var task: String; var owner: String?; var due: String?; var timestamp: String?; var quote: String? }
  struct Change: Codable, Equatable { var from: String?; var to: String? }
  var date: Date; var meetingID: UUID?; var todoID: UUID; var action: Action; var item: Item
  var edit: [String: Change]?          // keys "task", "owner", "due"; only changed fields
  var verification: String?; var verificationReason: String?
}
final class TodoDecisionLog: @unchecked Sendable {
  static let shared: TodoDecisionLog    // ~/Library/Application Support/Casablanca/feedback/todo-decisions.jsonl
  init(fileURL: URL)
  let fileURL: URL
  func append(_ entry: TodoDecisionEntry)   // one JSON line (sortedKeys, ISO-8601 dates), creates dirs; failures logged via Log.persistence, never thrown
}
```

Rules:
- Line format (exact): `- [ ] <task> — <owner> 📅 <yyyy-MM-dd> [<label>] <!-- casablanca-todo: <ID> -->`, each part present only when set; the ` — <owner>` part is written **only when a due date or timestamp is also written** (so it can be parsed back unambiguously).
- Parse: after the existing regex, `text` is split from the end: optional ` [<label>]` (label must pass `seconds(fromLabel:)`), then optional ` 📅 yyyy-MM-dd`, then — only if one of those two matched — optional ` — <owner>` (1–60 chars, no `—`). Anything else stays in `text`.
- `upsertTask`: writes `owner/dueDate/sourceTimestamp` from the line only when the line carried a suffix; otherwise keeps the row's values. Rows found in a file are `.accepted` (a file never holds proposed rows).
- `accept`: Obsidian storage with resolvable meeting files → append `TaskLine(id: todo.id, text, isCompleted, owner, due, timestamp)` via `appendingTask` to `canonicalTodoWriteURL`, set `sourceFilePath`; otherwise (local storage or no vault) only SwiftData. Then `status = .accepted`, save, log (`.accept` or `.autoAccept`).
- `reject`: `status = .rejected`, save, log; never touches files.
- `edit`: only for `.proposed`; changes `text/owner/dueDate`, logs `.edit` with the changed fields; does not accept.
- `acceptAllVerified`: accepts every `.proposed` todo of the meeting whose `verification == .supported`; returns the count.
- Regeneration (`replaceProposedTodos`, spec B6): delete pending `.proposed`; drop a new item when `FuzzyText.similarity(item.task, todo.text) ≥ 0.85` for any `.accepted` or `.rejected` todo of the meeting, or for an earlier new item; insert the rest as `.proposed`. `meeting.actionItems` is overwritten by the caller (Task 5).
- After `replaceProposedTodos`, `summarizeInBackground` calls `acceptAllVerified(… auto: true)` when `autoAcceptVerifiedTodos` is on.
- Exports: `ObsidianMeetingExporter.summaryMarkdown` and `AppleNotesBodyRenderer.todoList` list only `.accepted` todos, each line/item text followed by `ObsidianTodoMarkdown.suffix(…)` (`dueDate` formatted `yyyy-MM-dd`).

- [ ] **Step 1: Write the failing tests**
  - `ObsidianTodoMarkdownTests`: `testRendersOwnerDueAndTimestampSuffix` (exact line above); `testParsesSuffixIntoFields`; `testOwnerAloneIsNotWritten`; `testUserTypedDashLineKeepsItsText` (`- [ ] Bel Kim — dringend` → text `Bel Kim — dringend`, owner nil); `testBracketTextThatIsNotATimestampStaysText` (`- [ ] Check [IO-12]`); `testSettingCompletionKeepsSuffix`.
  - `TodoReviewServiceTests`: `testAcceptWritesOneLineToTheMeetingFile` (scratch vault; file contains `— Youri 📅 2026-11-06 [12:34] <!-- casablanca-todo: <id> -->`, `sourceFilePath` set, status `.accepted`); `testAcceptInLocalModeTouchesNoFiles`; `testRejectStaysInSwiftDataOnly`; `testEditLogsOnlyChangedFields`; `testAcceptAllVerifiedSkipsUnsupportedAndUnverified` (returns 1 of 3); `testRegenerationKeepsAcceptedAndRejectedAndDropsFuzzyMatches` (accepted "Stuur offerte naar Kim", rejected "Plan demo", new items "Stuur de offerte naar Kim.", "Plan de demo", "Bel leverancier" → only "Bel leverancier" proposed; accepted/rejected rows untouched); `testAutoAcceptVerifiedWhenSettingOn` (via `SummarizationService.summarizeInBackground` with stubs; logs `auto_accept`).
  - `TodoDecisionLogTests`: `testAppendsOneJSONLinePerDecision` (two appends → two lines, each decodes to `TodoDecisionEntry`); `testCreatesMissingDirectory`; `testUnwritableLocationDoesNotThrow`.
  - `ObsidianTodoSyncServiceTests`: `testRejectedRowsSurviveRefresh`; `testAcceptedLineRoundTripsThroughRefresh` (owner/due/timestamp intact, text without suffix); `testLegacyTodosStillSyncAndExport` (pre-V3 style rows: status default `.accepted`, existing flows unchanged).
  - `ExportServiceTests.testSummaryExportListsOnlyAcceptedTodosWithSuffix`; `AppleNotesBodyRendererTests.testSummaryListsOnlyAcceptedTodos`.
- [ ] **Step 2: Run** `<TB_TEST> -only-testing:CasablancaTests/ObsidianTodoMarkdownTests -only-testing:CasablancaTests/TodoReviewServiceTests -only-testing:CasablancaTests/TodoDecisionLogTests -only-testing:CasablancaTests/ObsidianTodoSyncServiceTests -only-testing:CasablancaTests/ExportServiceTests -only-testing:CasablancaTests/AppleNotesBodyRendererTests -only-testing:CasablancaTests/MeetingPrepSaveTests -only-testing:CasablancaTests/NoRealVaultWritesTests` → FAIL (new tests).
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the same command plus `-only-testing:CasablancaTests/SummarizationServiceTests` → PASS.
- [ ] **Step 5: Commit** `feat(todos): accept, edit and reject proposed to-dos with a decision log`.

---

## Task 11 (B6): Review UI — summary-tab strip, Todos view, meeting panel, settings

**Files:**
- Create: `Casablanca/Views/Components/TodoReviewRow.swift` (row + pure `TodoReviewPresentation`), `Casablanca/Views/MeetingDetail/TodoReviewStrip.swift`
- Modify: `Casablanca/Views/MeetingDetail/MeetingSummaryTab.swift`, `Casablanca/Views/TodosView.swift`, `Casablanca/Views/Components/MeetingTodosPanel.swift`, `Casablanca/Views/Settings/ActionItemReviewSettingsSection.swift` (Phase 0 placeholder, track-owned)
- Test: `CasablancaTests/TodoReviewPresentationTests.swift`

**Interfaces:**
- Consumes: Task 10 service; `appModel.toastCenter`, `appModel.exportStatusCenter`; `ExportService.exportAutomaticallyIfEnabled(_:reporter:)`.
- Produces:
```swift
struct TodoReviewPresentation {      // pure
  enum Badge: Equatable { case verified, unsupported(reason: String?), unverified }
  init(todo: TodoItem)
  var badge: Badge; var ownerText: String?; var dueText: String?   // "vr 6 nov" style via DateFormatter(dateFormat: "EEE d MMM")
  var timestampLabel: String?; var quoteText: String?             // quote wrapped in typographic quotes
  static func acceptAllVerifiedCount(_ todos: [TodoItem]) -> Int
}
struct TodoReviewRow: View { let todo: TodoItem; let onAccept, onReject: () -> Void; let onEdit: (String, String?, Date?) -> Void }
struct TodoReviewStrip: View { @Bindable var meeting: Meeting }
// TodosView.TodoFilter gains: case review = "Review"
```

Rules:
- Badge: `.supported` → `checkmark.seal.fill` / `Color.accentSuccess`, help "Supported by the transcript"; `.unsupported` → `exclamationmark.triangle.fill` / `Color.accentWarning`, help = reason; `.unverified`/nil → `questionmark.circle` / `Color.textTertiary`, help "Not checked".
- Row: task (body), then caption line `owner · due · [mm:ss]`, then the quote (caption, italic, secondary, 2 lines). Buttons Accept (`PrimaryButtonStyle`), Edit (popover: task `TextField`, owner `TextField` with meeting participants as suggestions, optional `DatePicker`; Save), Reject (`GhostButtonStyle`). The `[mm:ss]` is plain `Text` in one place (`TodoReviewRow.timestampText`). **Phase 2 handoff:** Task 2.1 makes it a timestamp link.
- Strip: shown at the top of the summary tab (below the hero) when the meeting has `.proposed` todos; header "Review to-dos (N)" and "Accept all verified (K)" (disabled when K == 0). After any accept, the view runs `ExportService.exportAutomaticallyIfEnabled(meeting, reporter: appModel.exportStatusCenter)` so Apple Notes / the summary file get the accepted list. Errors → toast.
- Summary tab action-items section: when `meeting.actionItems` is non-empty, other people's items show their owner and verification badge (read-only); legacy meetings keep today's toggle list.
- `TodosView`: Open/Done/All show `.accepted` only; new `Review` segment (label `Review (N)` when N > 0) lists `.proposed` across meetings with `TodoReviewRow`; rejected never shown.
- `MeetingTodosPanel`: list shows `.accepted` only; above it, when proposed exist, a compact "N to-dos to review" section of `TodoReviewRow`s.
- `ActionItemReviewSettingsSection`: keeps the Phase 0 "Auto-accept verified to-dos" toggle; adds explanatory caption "Only to-dos whose quote is confirmed by the transcript are accepted automatically." and a "Show decision log in Finder" button (`NSWorkspace.shared.activateFileViewerSelecting([TodoDecisionLog.shared.fileURL])`, disabled when the file does not exist).

- [ ] **Step 1: Write the failing tests** (`TodoReviewPresentationTests`): `testBadgeForEachVerificationState`; `testUnsupportedBadgeCarriesReason`; `testCaptionPartsOmitMissingFields`; `testAcceptAllVerifiedCountIgnoresAcceptedAndUnsupported`; `testLegacyTodoHasUnverifiedBadgeAndNoQuote`.
- [ ] **Step 2: Run** `<TB_TEST> -only-testing:CasablancaTests/TodoReviewPresentationTests` → FAIL.
- [ ] **Step 3: Implement** the views.
- [ ] **Step 4: Run** `<TB_TEST> -only-testing:CasablancaTests/TodoReviewPresentationTests -only-testing:CasablancaTests/MeetingDetailPresentationTests -only-testing:CasablancaTests/SplitLayoutStabilityTests` → PASS.
- [ ] **Step 5: In-app check** — build and run against a scratch vault: summarize a meeting → strip shows badges; Accept one (file gets one line with suffix), Reject one, Edit one; Todos → Review lists the rest; Open lists the accepted one; narrow the inspector and window to minimum: no constraint-loop console warning (constraint-pass probe per `project_casablanca-view-verification`).
- [ ] **Step 6: Commit** `feat(ui): to-do review strip, Review filter and auto-accept setting`.

---

## Phase 2 handoffs (collected)

1. `Views/SettingsView.swift`: remove the legacy summary-prompt editor (Task 9).
2. Task 2.1 (clickable timestamps): `TodoReviewRow.timestampText`, the rendered `[mm:ss]` in summary bullets and in `TodoReviewStrip`.
3. Task 2.2 / I2: after a speaker rename, call `appModel.summarizationService.summarizeInBackground(meeting:modelContext:templateID: meeting.summaryTemplateID)`; the regeneration rules (Task 10) already keep accepted/rejected items. `knownSpeakers` for the verifier comes from `meeting.speakers` (Track A fills it).
4. pbxproj: Track B adds 24 files (12 app, 12 test; listed per task); merge keeps all entries.

## Track-B pre-merge checklist (in-app, for Youri)

- [ ] Targeted classes all green: `SummaryPromptContextTests SummaryFactsParserTests RelativeDateResolverTests FuzzyTextTests SummarizationServiceTests MeetingPipelineStateTests ActionItemRenderingTests SummaryResponseParserTests ActionItemOwnershipTests TodoReviewServiceTests ObsidianTodoSyncServiceTests ObsidianTodoMarkdownTests ActionItemVerifierTests SummaryTemplatesTests TodoDecisionLogTests ExportServiceTests AppleNotesBodyRendererTests MeetingPrepSaveTests NoRealVaultWritesTests TodoReviewPresentationTests MeetingDetailPresentationTests SplitLayoutStabilityTests` (one `<TB_TEST>` run with all of them; still not the full suite).
- [ ] A short Dutch meeting with **Claude Code**: summary shows `## Actiepunten` as `- **Naam** — taak (datum) [mm:ss]`, no JSON visible, review strip with badges.
- [ ] Same meeting with **Ollama/oMLX** (local model): either structured items, or the fallback warning with to-dos still proposed — never silently none.
- [ ] A meeting over ~25k tokens (≈ 2 h) on Claude: "Summarizing part i of N" appears, then "Checking action items…"; items keep timestamps.
- [ ] A meeting with Obsidian prep notes: the summary reflects the prep focus; participants show you as `(me)` (and e-mails when the calendar event has them).
- [ ] Title "Bila Martijn" → header "1:1 / bilateral"; "Regenerate with… → Stand-up": accepted to-dos stay, rejected ones do not come back, pending ones are replaced.
- [ ] Accept / Edit / Reject: the Obsidian meeting file holds only the accepted line (`— Youri 📅 2026-… [mm:ss]`, due date visible in the Obsidian Tasks plugin); reopening the Todos view (vault refresh) neither deletes nor resurrects anything.
- [ ] Export destination Apple Notes: the summary note lists only accepted to-dos.
- [ ] `~/Library/Application Support/Casablanca/feedback/todo-decisions.jsonl` has one line per decision.
- [ ] "Auto-accept verified to-dos" on → only `Supported` items are accepted after the next summary.
- [ ] An old meeting (summarized before this branch): summary tab, toggles, Todos and export behave as before; re-summarizing it works.
- [ ] Settings → AI → templates: edit General, add/delete a custom template, reset a built-in; minimum window and inspector widths show no constraint-loop warning.
