# Speech pipeline Track C — Evaluation and cross-meeting Q&A Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make summary quality measurable against a hand-curated gold set (C1, point 14) and let Youri ask one question across all meetings with tappable citations (C2, point 15).

**Architecture:** C1 is a stdlib-only Python tool in `tools/eval/` plus a pure Swift `EvaluationExport` builder behind a menu command; both sides agree on one versioned JSON schema (Contracts below). C2 is a pure retrieval stack — tokenizer → corpus chunks → in-memory BM25 → budgeted context selection → prompt → citation parser — wrapped by an `@Observable` `AskService` (single-turn, like `MeetingChatService`) and an `AskView` reached from a new sidebar entry. Citations are resolved only against the sources that were in the prompt and handed to a navigation callback, which Phase 2 upgrades from "open the meeting" to "jump to the timestamp".

**Tech Stack:** Swift 5 / SwiftUI / SwiftData (macOS 14+), Foundation only for C2 logic; Python 3 standard library only (`json`, `difflib`, `unicodedata`, `argparse`, `unittest`).

**Spec:** `docs/superpowers/specs/2026-11-05-speech-pipeline-best-practices-design.md` (binding; this plan covers "Track C" and consumes "Contracts shared by all tracks"). Master plan: `docs/superpowers/plans/2026-11-05-speech-pipeline-best-practices.md`.

## Global Constraints

- Work in worktree `../lahore-track-c` on branch `76r75r6qbh-sys/speech-pipeline-track-c`, branched from the Phase 0 tip. Never push, never open a PR, never release.
- Swift tests: only targeted classes, never the full suite. Command template (referred to below as **SWIFT-TEST**):
  `xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -derivedDataPath .build/test-track-c -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' -only-testing:CasablancaTests/<Class> [-only-testing:CasablancaTests/<Class2> …]` — pass: `** TEST SUCCEEDED **`.
- Python: stdlib only, always run with `python3 -I`. Full Python suite: `python3 -I -m unittest discover tools/eval/tests` — pass: last line `OK`. Code must run on Python ≥ 3.9 (no `match`, no `X | Y` type unions at runtime).
- `python3 -I` does **not** put the script's directory on `sys.path`, so `tools/eval/casaeval.py` is one self-contained module and tests load it by file path (`importlib.util.spec_from_file_location`), never `import casaeval` via sys.path.
- `tools/` is untracked in the main worktree and holds unrelated content (`tools/rebuild-history`). Create only `tools/eval/`; stage with explicit paths (`git add tools/eval/...`), never `git add tools/`, `git add -A` or `git add .`.
- Never call a live LLM or the network in tests: use `CasablancaTests/LLM/StubLLMProvider.swift`.
- Do not modify Phase 0/2 shared files: `Meeting.swift`, `TodoItem.swift`, `CasablancaSchema.swift`, `SettingsView.swift`, `Models/SpeakerTranscript.swift`, `Models/ExtractedActionItem.swift`, `Services/TranscriptLineFormat.swift`, `Services/AudioClipPlayer.swift`. No new model fields, no new `AppPreferenceKey`s (Track C needs none).
- Old meetings (no `speakersData`, no `actionItemsData`, transcript lines without speaker) must work in export and Ask.
- Ship 0 real gold files and 0 real exports; exactly one synthetic example. `tools/eval/.gitignore` keeps `gold/` and `exports/` out of git.
- New Swift files go into existing groups (`Casablanca/Services`, `Casablanca/Views`, `CasablancaTests`) — no new pbxproj groups. Add each with `ruby scripts/add-files-to-xcodeproj.rb <paths…>` (idempotent) and commit the pbxproj with the task.
- Commits: conventional messages ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Consumed from Phase 0 (treat as given)

```swift
struct ExtractedActionItem: Codable, Equatable { var task: String; var owner: String?; var due: String?; var dueIsExplicit: Bool; var confidence: Double; var quote: String?; var timestamp: String?; var verified: VerificationState; var verificationReason: String? }
enum VerificationState: String, Codable { case unverified, supported, unsupported }
struct SpeakerInfo: Codable, Equatable, Identifiable { var id: String; var displayName: String; var source: SpeakerSource; var isUser: Bool; var nameConfirmed: Bool }
// Meeting (computed): actionItems: [ExtractedActionItem], speakers: [SpeakerInfo]; stored: summaryTemplateID: String?
struct TranscriptLine: Equatable { var label: String; var seconds: Double; var speaker: String?; var text: String }
enum TranscriptLineFormat { static func parse(_ line: String) -> TranscriptLine?; static func parse(_ line: String, knownSpeakers: Set<String>) -> TranscriptLine?; static func seconds(fromLabel: String) -> Double? }
```
Existing code reused: `SummaryResponseParser.parse(_:)` (decisions, `todoTexts`), `ActionItemOwnership.parse(_:)` (`**owner** — action`), `TranscriptChunker.chunks(of:chunkTokens:overlapTokens:)` (`startLabel`), `LLMPromptSupport` (`budgetTokens`, `applyThinkingSwitch`, `tokenBudget(thinkingEnabled:)`, `thinkingEnabled()`, `stripReasoningTags`), `LLMProviderFactory.current()`, `LLMRetryPolicy.withRetry(onAttempt:_:)`, `provider.promptTokenBudget`, `provider.timeout(orDefault:)`.

## Contracts (Track C internal, binding for Swift and Python)

### Evaluation export — `casablanca.eval-export` v1

Written by Swift (`EvaluationExport`), read by `casaeval.py score` / `make-gold`. UTF-8, `JSONEncoder` with `.prettyPrinted, .sortedKeys, .withoutEscapingSlashes`, dates ISO 8601 UTC (`2026-11-05T14:00:00Z`). Every key is always present; "absent" values are `null` or `[]`, never omitted.

```json
{
  "schema": "casablanca.eval-export",
  "schemaVersion": 1,
  "exportedAt": "2026-11-05T14:00:00Z",
  "appVersion": "0.20.0",
  "meeting": {
    "id": "6F1C…-UUID", "title": "Refinement Team Link", "date": "2026-11-03T09:00:00Z",
    "endDate": "2026-11-03T10:00:00Z", "durationSeconds": 3540.0, "language": "nl-NL",
    "participants": ["Youri Broekhuizen", "Kim Owen-Jones"], "tags": ["link"], "summaryTemplateID": null
  },
  "speakers": [{"id": "mic", "displayName": "Youri", "source": "microphone", "isUser": true, "nameConfirmed": true}],
  "transcript": {
    "text": "[00:10] Youri: we beginnen\n[00:14] Spreker 1: ok",
    "lines": [{"label": "00:10", "seconds": 10.0, "speaker": "Youri", "text": "we beginnen"}]
  },
  "summary": {"markdown": "# …", "decisions": ["…"], "actionItemTexts": ["**Kim** — offerte opvragen [12:34]"]},
  "actionItemsSource": "structured",
  "actionItems": [{"task": "Offerte opvragen", "owner": "Kim", "due": "2026-11-07", "dueIsExplicit": true,
                   "confidence": 0.9, "quote": "ik vraag de offerte op", "timestamp": "12:34",
                   "verified": "supported", "verificationReason": null}],
  "decisions": [{"text": "We gaan door met BgZ-profiel v2", "source": "summaryMarkdown"}]
}
```
- `actionItemsSource`: `"structured"` when `meeting.actionItems` is non-empty; else `"summaryMarkdown"` when the summary's `## Action Items` (any `SummaryResponseParser` alias) yields bullets; else `"none"` with `actionItems: []`.
- Fallback items (`summaryMarkdown`): `task` = `ActionItemOwnership.parse(bullet).action` with a trailing `[mm:ss]`/`[h:mm:ss]` removed, `owner` = parsed owner, `timestamp` = that trailing label (no brackets) or `null`, `due` = `null`, `dueIsExplicit` = `false`, `confidence` = `0`, `quote` = `null`, `verified` = `"unverified"`, `verificationReason` = `null`.
- `decisions`: from `SummaryResponseParser.parse(summary).decisions` (no structured decisions are stored in V3), each `source: "summaryMarkdown"`. Summary `nil` → `summary` fields `markdown: null, decisions: [], actionItemTexts: []`.
- `transcript.lines`: each transcript line parsed with `TranscriptLineFormat.parse(_:knownSpeakers:)` using `Set(meeting.speakers.map(\.displayName))`; lines without a leading timestamp are skipped in `lines` (still in `text`). Transcript `nil` → `text: null, lines: []`.

### Gold file — `casablanca.eval-gold` v1 (`tools/eval/gold/<meetingId>.json`)

```json
{
  "schema": "casablanca.eval-gold", "schemaVersion": 1,
  "meetingId": "6F1C…-UUID", "title": "Refinement Team Link", "date": "2026-11-03",
  "reviewed": false, "notes": "",
  "ownerAliases": {"Ik": "Youri", "Me": "Youri", "Youri Broekhuizen": "Youri"},
  "decisions": [{"text": "We gaan door met BgZ-profiel v2"}],
  "actionItems": [{"task": "Offerte opvragen bij leverancier", "owner": "Kim", "due": null}]
}
```
`owner: null` means "nobody explicitly assigned" (gold truth). `ownerAliases` maps variants to a canonical name, applied to both gold and predicted owners before comparison.

### Ask citation — `[Meeting title, YYYY-MM-DD, mm:ss]`

Title in citations and source headers is `AskCitationFormat.citationTitle(_:)`: `[`→`(`, `]`→`)`, newlines → space, trimmed. Date `yyyy-MM-dd` in the user's current calendar/time zone. Time is the source chunk's `startLabel` (`mm:ss` or `h:mm:ss`); sources without a time (summary, action item without timestamp) are cited as `[Meeting title, YYYY-MM-DD]`. One bracket may hold several citations separated by `; `.

## Review Focus

1. A meeting title containing a comma or brackets ("Bila Youri, Martijn [extern]") → the citation still parses and opens that meeting. (Task C2.5: `testTitleWithCommaParses`, `testBracketsInTitleAreSanitised`.)
2. The model cites a meeting/date that was not among the prompt's sources (hallucinated citation) → rendered as plain text, never a link to a wrong meeting. (Task C2.5: `testCitationNotInSourcesIsUnresolved`.)
3. An old meeting (no speakers, no structured items, `[mm:ss] text` lines) → exported with `actionItemsSource: "summaryMarkdown"` and indexed/answerable in Ask. (Task C1.1: `testOldMeetingFallsBackToSummaryMarkdown`; Task C2.2: `testOldMeetingWithoutStructuredItemsIsChunked`.)
4. Dutch question with diacritics/casing differing from the transcript ("geïnteresseerd" vs "geinteresseerd", "BGZ" vs "BgZ") → same tokens, so the meeting is retrieved. (Task C2.1: `testFoldsDiacriticsAndCase`; Task C2.3: `testDiacriticQueryRetrievesUnaccentedDoc`.)
5. A store with hundreds of long meetings on a local 6 000-token provider → prompt stays within `promptTokenBudget`, at least one source is included, and no single meeting crowds out all others. (Task C2.4: `testSelectionRespectsBudget`, `testPerMeetingCap`, `testOversizedFirstChunkIsTruncatedNotDropped`.)

---

## C1 — Evaluation set

### Task C1.1: Pure evaluation export builder (Swift)

**Files:**
- Create: `Casablanca/Services/EvaluationExport.swift`
- Test: `CasablancaTests/EvaluationExportTests.swift`
- Modify: `Casablanca.xcodeproj/project.pbxproj` (via `scripts/add-files-to-xcodeproj.rb`)

**Interfaces:**
- Consumes: Phase 0 `Meeting.actionItems`, `Meeting.speakers`, `Meeting.summaryTemplateID`, `TranscriptLineFormat.parse(_:knownSpeakers:)`; `SummaryResponseParser.parse`, `ActionItemOwnership.parse`.
- Produces:
```swift
enum EvaluationExport {
  static let schemaName = "casablanca.eval-export"; static let schemaVersion = 1
  static let topLevelKeys: Set<String> = ["schema","schemaVersion","exportedAt","appVersion","meeting","speakers","transcript","summary","actionItemsSource","actionItems","decisions"]
  struct Document: Codable, Equatable { … }   // mirrors the Contract exactly; nested MeetingInfo, TranscriptInfo, LineInfo, SummaryInfo, DecisionInfo; actionItems: [ExtractedActionItem]; speakers: [SpeakerInfo]
  enum ActionItemsSource: String, Codable { case structured, summaryMarkdown, none }
  static func document(for meeting: Meeting, exportedAt: Date, appVersion: String) -> Document
  static func encode(_ document: Document) throws -> Data        // pretty, sorted keys, ISO 8601, nils encoded as null (custom encode(to:) with encodeNil)
  static func fallbackActionItems(fromSummary summary: String) -> [ExtractedActionItem]
  static func suggestedFileName(for meeting: Meeting) -> String  // "<yyyy-MM-dd> <meeting.sanitizedTitle>.eval.json"
}
```

- [ ] **Step 1: Write the failing tests** in `EvaluationExportTests`:
  - `testTopLevelKeysMatchContract` — encode a document for a bare `Meeting(title:"X", date:…)`, `JSONSerialization` → `Set(dict.keys) == EvaluationExport.topLevelKeys`; `dict["schema"] == "casablanca.eval-export"`, `dict["schemaVersion"] == 1`.
  - `testNilsAreEncodedAsNull` — bare meeting → `dict["transcript"]["text"] is NSNull`, `dict["summary"]["markdown"] is NSNull`, `dict["meeting"]["endDate"] is NSNull`, `dict["actionItems"] as? [Any] == []`.
  - `testStructuredItemsWin` — meeting with `actionItems = [ExtractedActionItem(task:"Offerte opvragen", owner:"Kim", due:"2026-11-07", dueIsExplicit:true, confidence:0.9, quote:"ik vraag de offerte op", timestamp:"12:34", verified:.supported, verificationReason:nil)]` and a summary with a different `## Action Items` bullet → `actionItemsSource == .structured`, items equal the structured list.
  - `testOldMeetingFallsBackToSummaryMarkdown` — no structured items, summary `"# S\n\n## Actiepunten\n- **Kim** — offerte opvragen [12:34]\n- **?** — notulen delen\n"` → source `.summaryMarkdown`; items `[("offerte opvragen", owner "Kim", timestamp "12:34"), ("notulen delen", owner nil, timestamp nil)]`, `verified == .unverified`, `confidence == 0`.
  - `testNoItemsAnywhereIsNone` — summary without action items section → `.none`, `[]`.
  - `testDecisionsFromSummary` — `## Besluiten\n- Door met v2` → `decisions == [DecisionInfo(text:"Door met v2", source:"summaryMarkdown")]`.
  - `testTranscriptLinesUseKnownSpeakers` — speakers `[SpeakerInfo(id:"mic", displayName:"Youri", …)]`, transcript `"[00:10] Youri: ja\n[00:12] Agenda: punt 1\nzonder label"` → `lines.count == 2`, `lines[0].speaker == "Youri"`, `lines[1].speaker == nil`, `lines[1].text == "Agenda: punt 1"`, `transcript.text` unchanged.
  - `testDatesAreISO8601UTC` — `exportedAt = Date(timeIntervalSince1970: 0)` → JSON string contains `"exportedAt" : "1970-01-01T00:00:00Z"`.
  - `testSuggestedFileName` — title `"Bila: Martijn/Youri"` on 2026-11-03 → ends with `.eval.json`, contains no `/` or `:`.
- [ ] **Step 2: Run** SWIFT-TEST with `-only-testing:CasablancaTests/EvaluationExportTests` → FAIL (`EvaluationExport` undefined).
- [ ] **Step 3: Implement** `EvaluationExport.swift` per Interfaces and the Contract. Fallback trailing-timestamp regex: `\s*\[(\d{1,2}:\d{2}(?::\d{2})?)\]\s*$`. `durationSeconds` = `meeting.recordingDuration`. `appVersion` passed in (caller reads `CFBundleShortVersionString`). Add both files with `ruby scripts/add-files-to-xcodeproj.rb Casablanca/Services/EvaluationExport.swift CasablancaTests/EvaluationExportTests.swift`.
- [ ] **Step 4: Run** the same command → PASS; also `-only-testing:CasablancaTests/SummaryResponseParserTests -only-testing:CasablancaTests/ActionItemOwnershipTests` → PASS (untouched, sanity).
- [ ] **Step 5: Commit**
```bash
git add Casablanca/Services/EvaluationExport.swift CasablancaTests/EvaluationExportTests.swift Casablanca.xcodeproj/project.pbxproj
git commit -m "feat(eval): evaluation export document for a meeting"
```

### Task C1.2: "Export for Evaluation…" menu command

**Files:**
- Create: `Casablanca/Views/EvaluationExportCommands.swift`
- Modify: `Casablanca/CasablancaApp.swift` (one line inside `.commands { … }` at ~line 176–205: `EvaluationExportCommands(viewModel: appModel.meetingListViewModel, toastCenter: appModel.toastCenter)`)
- Test: `CasablancaTests/EvaluationExportTests.swift` (extend)
- Modify: `Casablanca.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `EvaluationExport.document/encode/suggestedFileName` (C1.1); `MeetingListViewModel.selectedMeeting`; `ToastCenter`.
- Produces:
```swift
struct EvaluationExportCommands: Commands { let viewModel: MeetingListViewModel; let toastCenter: ToastCenter; var body: some Commands }
// CommandGroup(after: .importExport) { Button("Export Meeting for Evaluation…") { … }.disabled(!EvaluationExport.canExport(viewModel.selectedMeeting)) }
extension EvaluationExport { static func canExport(_ meeting: Meeting?) -> Bool }   // true iff meeting has a non-empty transcript or summary
```

- [ ] **Step 1: Failing tests** `testCanExportRequiresTranscriptOrSummary` (`nil` → false; bare meeting → false; transcript `"[00:01] a"` → true; only summary → true; whitespace-only transcript → false).
- [ ] **Step 2: Run** SWIFT-TEST `-only-testing:CasablancaTests/EvaluationExportTests` → FAIL.
- [ ] **Step 3: Implement.** Action: build document with `Bundle.main.infoDictionary?["CFBundleShortVersionString"]`, present `NSSavePanel` (`allowedContentTypes: [.json]`, `nameFieldStringValue: suggestedFileName`), write atomically; on success `toastCenter` shows "Exported for evaluation" ; on failure a toast with `error.localizedDescription`. Doc comment on the button: the file contains the full transcript — keep it out of git (`tools/eval/exports/` is git-ignored). Add the new file to pbxproj.
- [ ] **Step 4: Run** the test class → PASS. Then `xcodebuild build -project Casablanca.xcodeproj -scheme Casablanca -derivedDataPath .build/test-track-c -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''` → `** BUILD SUCCEEDED **`.
- [ ] **Step 5: In-app check:** launch the built app, select a completed meeting, File → "Export Meeting for Evaluation…", save to the scratchpad; `python3 -I -c "import json,sys; d=json.load(open(sys.argv[1])); print(sorted(d))" <file>` prints exactly the 11 contract keys. Menu item is disabled on Dashboard.
- [ ] **Step 6: Commit**
```bash
git add Casablanca/Views/EvaluationExportCommands.swift Casablanca/CasablancaApp.swift CasablancaTests/EvaluationExportTests.swift Casablanca.xcodeproj/project.pbxproj
git commit -m "feat(eval): export meeting for evaluation menu command"
```

### Task C1.3: `casaeval.py` normalisation, similarity and matching

**Files:**
- Create: `tools/eval/casaeval.py`, `tools/eval/.gitignore`, `tools/eval/tests/test_matching.py`

**Interfaces:**
- Produces (module `casaeval`, module docstring documents both JSON formats from the Contracts section and the usage of all subcommands):
```python
DEFAULT_THRESHOLD = 0.55
def normalize(text: str) -> str            # NFKD, drop Mn marks, casefold, drop "**", drop [mm:ss]/[h:mm:ss], non-word -> space, collapse
def tokens(text: str) -> list              # normalize().split() minus STOPWORDS (small nl+en set: de het een en van naar op te in is dat die we ik je the a an to of and for on in is)
def similarity(a: str, b: str) -> float    # max(difflib.SequenceMatcher(None, na, nb).ratio(), token_f1(a, b)); both empty -> 1.0; one empty -> 0.0
def token_f1(a: str, b: str) -> float      # multiset overlap F1 on tokens()
def match(gold: list, predicted: list, threshold: float = DEFAULT_THRESHOLD) -> list   # [(gold_index, pred_index, score)], one-to-one
def canonical_owner(owner, aliases: dict)  # None/""/"?" -> None; alias lookup on normalize()d keys; returns normalize()d canonical
```
`match` algorithm (deterministic): score every pair, keep pairs `>= threshold`, sort by `(-score, gold_index, pred_index)`, take greedily while neither index is used.
`.gitignore` contents: `gold/`, `exports/`, `__pycache__/`, `*.pyc`.

- [ ] **Step 1: Write failing tests** (`unittest.TestCase`; top of file loads the module: `spec = importlib.util.spec_from_file_location("casaeval", Path(__file__).resolve().parents[1] / "casaeval.py")`, `casaeval = importlib.util.module_from_spec(spec); spec.loader.exec_module(casaeval)`):
  - `test_normalize_folds_diacritics_and_case`: `normalize("Café-overleg  GEÏNTERESSEERD") == "cafe overleg geinteresseerd"`.
  - `test_normalize_strips_timestamps_and_bold`: `normalize("**Kim** — offerte [12:34]") == "kim offerte"`; `[1:02:03]` also removed.
  - `test_similarity_identical_is_one`: `similarity("Offerte opvragen", "offerte  opvragen!") == 1.0`.
  - `test_similarity_paraphrase_passes_default`: `similarity("Youri stuurt de planning naar Kim", "Planning naar Kim sturen") >= 0.55`.
  - `test_similarity_unrelated_is_low`: `similarity("Budget goedkeuren", "Planning naar Kim sturen") < 0.4`; `similarity("Release notes schrijven", "Retro inplannen") < 0.4`.
  - `test_match_is_one_to_one`: gold `["offerte opvragen", "planning sturen"]`, predicted `["offerte opvragen", "offerte opvragen bij leverancier"]` → exactly one pair for gold 0 (pred 0, score 1.0), gold 1 unmatched.
  - `test_match_is_deterministic_on_ties`: two equal-score candidates → lowest indices win; repeated calls return the same list.
  - `test_match_empty_inputs`: `match([], ["x"]) == []`, `match(["x"], []) == []`.
  - `test_canonical_owner_aliases`: aliases `{"Ik": "Youri", "Youri Broekhuizen": "Youri"}` → `canonical_owner("ik", a) == canonical_owner("Youri Broekhuizen", a) == "youri"`; `canonical_owner("?", a) is None`; `canonical_owner(None, a) is None`.
- [ ] **Step 2: Run** `python3 -I -m unittest discover -s tools/eval/tests -p 'test_matching.py'` → FAIL (`FileNotFoundError`/`AttributeError`).
- [ ] **Step 3: Implement** the functions in `tools/eval/casaeval.py` (shebang `#!/usr/bin/env python3`, style of `scripts/transcript-agreement.py`: module docstring, constants up top, small functions, no classes needed beyond dataclass-free dicts).
- [ ] **Step 4: Run** the same command → `OK`.
- [ ] **Step 5: Commit**
```bash
git add tools/eval/casaeval.py tools/eval/.gitignore tools/eval/tests/test_matching.py
git commit -m "feat(eval): fuzzy matching for the evaluation scorer"
```

### Task C1.4: Scorer, `score` subcommand and synthetic example

**Files:**
- Modify: `tools/eval/casaeval.py`
- Create: `tools/eval/examples/synthetic-gold.json`, `tools/eval/examples/synthetic-export.json`, `tools/eval/tests/test_score.py`

**Interfaces:**
- Consumes: C1.3 functions; Contracts (export v1, gold v1).
- Produces:
```python
class FormatError(Exception): ...
def load_export(path) -> dict     # validates schema == "casablanca.eval-export", schemaVersion == 1, required keys; FormatError otherwise
def load_gold(path) -> dict       # validates schema == "casablanca.eval-gold", schemaVersion == 1, "reviewed" is bool
def score_meeting(gold: dict, export: dict, threshold=DEFAULT_THRESHOLD) -> dict
#  -> {"meetingId", "reviewed", "actionItems": {"gold", "predicted", "matched", "precision", "recall", "f1",
#       "ownerCorrect", "ownerAccuracy", "inventedOwners", "missedOwners"},
#      "decisions": {"gold", "predicted", "matched", "recall", "precision"}, "unmatchedGold": [...], "unmatchedPredicted": [...]}
def aggregate(results: list) -> dict   # micro-averaged over meetings (sum counts, then divide); same shape minus per-item lists
def main(argv=None) -> int              # argparse subcommands: score, make-gold (C1.5)
```
Metric definitions: precision = matched / predicted, recall = matched / gold, f1 harmonic; a ratio with a zero denominator is `None` (printed `n/a`). `ownerCorrect` counts matched pairs whose `canonical_owner` values are equal (both `None` counts as correct). `ownerAccuracy` = ownerCorrect / matched. `inventedOwners` = matched pairs with gold owner `None` and predicted owner not `None` (the spec's anti-goal); `missedOwners` = gold owner set, predicted `None`.
CLI: `python3 -I tools/eval/casaeval.py score --gold <file|dir> --export <file|dir> [--threshold 0.55] [--json] [--strict]`. Directories are paired by `meetingId` (gold) ↔ `meeting.id` (export); unpaired files listed as a warning on stderr. Output: one line per meeting (`<title>  AI P=0.80 R=0.67 F1=0.73 owner=0.75 invented=1  DEC R=0.50`) then `TOTAL …`; `--json` prints `{"meetings": [...], "total": {...}}`. Any gold with `"reviewed": false` → stderr `WARNING: <path> is unreviewed ("reviewed": false) — scores against it are provisional.`; with `--strict` exit 3. Exit codes: 0 ok, 2 usage/`FormatError`, 3 strict + unreviewed.
Synthetic example: an invented Dutch refinement meeting ("Refinement Demo-team", 2026-01-15, participants "Alex Jansen", "Sam de Vries", "Ik"); export with `actionItemsSource: "structured"`, 4 action items, 2 decisions, ~12 transcript lines with `Alex:`/`Sam:` prefixes; gold with 4 action items (3 matching paraphrases, 1 missing in export, export has 1 extra), 2 decisions, `"reviewed": true`, `"notes": "Synthetic example — not a real meeting."`. No real names, no Medicore content.

- [ ] **Step 1: Write failing tests** in `test_score.py`:
  - `test_example_files_validate`: `load_export(examples/synthetic-export.json)` and `load_gold(examples/synthetic-gold.json)` succeed; export keys equal the 11 contract keys (same list as `EvaluationExport.topLevelKeys`).
  - `test_example_scores`: `score_meeting(gold, export)` on the example → `actionItems.matched == 3`, `precision == 0.75`, `recall == 0.75`, `decisions.recall == 1.0` (pin the numbers the example is built for).
  - `test_owner_accuracy_and_invented`: inline dicts — gold `[{"task":"offerte opvragen","owner":null}, {"task":"planning sturen","owner":"Kim"}]`, predicted `[{"task":"offerte opvragen","owner":"Youri"}, {"task":"planning sturen","owner":"kim"}]` → `ownerCorrect == 1`, `ownerAccuracy == 0.5`, `inventedOwners == 1`.
  - `test_zero_denominators_are_none`: no predicted items → `precision is None`, `recall == 0.0`; no gold items → `recall is None`.
  - `test_aggregate_is_micro_average`: two meetings (1/1 matched and 0/3 matched) → total `recall == 0.25`.
  - `test_unreviewed_warns`: copy gold to a temp dir with `"reviewed": false`, call `main(["score", "--gold", g, "--export", e])` with stderr captured (`contextlib.redirect_stderr`) → returns 0, stderr contains `unreviewed`; with `--strict` → returns 3.
  - `test_bad_schema_exits_2`: export with `"schema": "other"` → `main([...]) == 2`.
  - `test_directory_pairing`: temp dirs with the example pair plus an unpaired export → scores 1 meeting, stderr mentions the unpaired file.
  - `test_json_output_shape`: `--json` stdout parses; keys `{"meetings", "total"}`.
- [ ] **Step 2: Run** `python3 -I -m unittest discover -s tools/eval/tests -p 'test_score.py'` → FAIL.
- [ ] **Step 3: Implement** in `casaeval.py`; write the two example files so `test_example_scores` holds.
- [ ] **Step 4: Run** `python3 -I -m unittest discover tools/eval/tests` → `OK`; and `python3 -I tools/eval/casaeval.py score --gold tools/eval/examples/synthetic-gold.json --export tools/eval/examples/synthetic-export.json` prints a `TOTAL` line, exit 0.
- [ ] **Step 5: Commit**
```bash
git add tools/eval/casaeval.py tools/eval/examples/synthetic-gold.json tools/eval/examples/synthetic-export.json tools/eval/tests/test_score.py
git commit -m "feat(eval): action item and decision scorer with synthetic example"
```

### Task C1.5: `make-gold` helper

**Files:**
- Modify: `tools/eval/casaeval.py`
- Create: `tools/eval/tests/test_make_gold.py`

**Interfaces:**
- Consumes: `load_export` (C1.4).
- Produces: `def draft_gold(export: dict) -> dict` and subcommand `python3 -I tools/eval/casaeval.py make-gold <export.json> [-o <path>] [--force]` (default output `tools/eval/gold/<meetingId>.json`, directory created; refuses to overwrite an existing file without `--force`, exit 2 with message).
`draft_gold`: `schema`/`schemaVersion` per contract, `meetingId` = `meeting.id`, `title`, `date` = first 10 chars of `meeting.date`, `"reviewed": false`, `notes` = `"Draft from Casablanca export (<actionItemsSource>) — correct every item, then set reviewed to true."`, `ownerAliases: {}`, `decisions` = `[{"text": d["text"]}]`, `actionItems` = `[{"task", "owner", "due"}]` copied from the export (unsupported/unverified items included — Youri deletes the wrong ones).

- [ ] **Step 1: Failing tests:** `test_draft_is_unreviewed` (`draft_gold(example)["reviewed"] is False`); `test_draft_copies_items_and_decisions` (counts equal export's; first task equal); `test_draft_validates_as_gold` (write draft to temp, `load_gold` succeeds); `test_refuses_overwrite` (`main(["make-gold", e, "-o", existing]) == 2`, file unchanged; with `--force` → 0, file replaced); `test_roundtrip_score_is_perfect` (scoring the export against its own draft → precision == recall == 1.0, and stderr has the unreviewed warning).
- [ ] **Step 2: Run** `python3 -I -m unittest discover -s tools/eval/tests -p 'test_make_gold.py'` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `python3 -I -m unittest discover tools/eval/tests` → `OK` (all three files).
- [ ] **Step 5: Commit**
```bash
git add tools/eval/casaeval.py tools/eval/tests/test_make_gold.py
git commit -m "feat(eval): make-gold drafts an unreviewed gold file from an export"
```

---

## C2 — Ask across meetings

### Task C2.1: Tokenizer

**Files:**
- Create: `Casablanca/Services/AskTokenizer.swift`
- Test: `CasablancaTests/AskTokenizerTests.swift`
- Modify: `Casablanca.xcodeproj/project.pbxproj`

**Interfaces — Produces:**
```swift
enum AskTokenizer {
  static func tokens(_ text: String) -> [String]   // order-preserving, duplicates kept (BM25 needs tf)
  static func fold(_ text: String) -> String       // text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
  static let stopwords: Set<String>                // folded nl + en function words (de het een en van naar op te in is dat die er we ik je jij hij zij ze wat wie hoe met voor aan om ook maar niet wel nog dan als bij of the a an and or of to in on for is are was be it that this with what who how did do we i you)
}
```
Rules: remove `[mm:ss]`/`[h:mm:ss]` labels first; fold; split on any character that is not a letter or digit (`CharacterSet.alphanumerics.inverted`); drop tokens of length 1 unless all digits; drop stopwords; no stemming *(Claude's call: predictable, and BM25 over Dutch compounds works acceptably on whole words; revisit with C1 numbers)*.

- [ ] **Step 1: Failing tests:** `testFoldsDiacriticsAndCase` (`tokens("Geïnteresseerd in BGZ") == ["geinteresseerd", "bgz"]`); `testCafeAndUmlauts` (`tokens("café überleg") == ["cafe", "uberleg"]`); `testDropsTimestampsAndSpeakerColon` (`tokens("[12:34] Youri: offerte") == ["youri", "offerte"]`, `tokens("[1:02:03] x 42")` contains `"42"`, not `"12"`/`"34"`/`"02"`); `testDropsStopwordsBothLanguages` (`tokens("de offerte van the vendor") == ["offerte", "vendor"]`); `testSplitsOnPunctuationAndHyphens` (`tokens("BgZ-profiel, v2!") == ["bgz", "profiel", "v2"]`); `testKeepsDuplicates` (`tokens("bgz bgz") == ["bgz", "bgz"]`); `testEmpty` (`tokens("  ") == []`).
- [ ] **Step 2: Run** SWIFT-TEST `-only-testing:CasablancaTests/AskTokenizerTests` → FAIL.
- [ ] **Step 3: Implement**; add files to pbxproj.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `git add Casablanca/Services/AskTokenizer.swift CasablancaTests/AskTokenizerTests.swift Casablanca.xcodeproj/project.pbxproj && git commit -m "feat(ask): tokenizer with Dutch diacritics folding"`.

### Task C2.2: Corpus — meeting snapshots, chunks and filters

**Files:**
- Create: `Casablanca/Services/AskCorpus.swift`
- Test: `CasablancaTests/AskCorpusTests.swift`
- Modify: `Casablanca.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `Meeting.actionItems`, `Meeting.speakers` (Phase 0); `TranscriptChunker.chunks`; `SummaryResponseParser`.
- Produces:
```swift
struct AskMeetingSnapshot: Equatable, Sendable { let id: UUID; let title: String; let date: Date; let participants: [String]; let tags: [String]
  let summary: String?; let actionItems: [ExtractedActionItem]; let transcript: String?
  init(meeting: Meeting) }                                  // copies on the main actor; tags lowercased as stored
enum AskChunkKind: String, Equatable, Sendable { case summary, actionItem, transcript }
struct AskChunk: Identifiable, Equatable, Sendable { let id: String /* "<uuid>#<kind>#<n>" */; let meetingID: UUID; let kind: AskChunkKind
  let text: String; let timeLabel: String? /* "12:34" */ }
struct AskFilter: Equatable, Sendable { var from: Date?; var to: Date?; var participant: String?; var tag: String?
  static let none = AskFilter(); var isEmpty: Bool
  func matches(_ m: AskMeetingSnapshot, calendar: Calendar = .current) -> Bool }
enum AskCorpus {
  static let transcriptChunkTokens = 220; static let transcriptOverlapTokens = 40; static let summarySectionMaxChars = 1_200
  static func chunks(for m: AskMeetingSnapshot) -> [AskChunk]
  static func load(from context: ModelContext, limit: Int = 1_000, isPendingDeletion: (UUID) -> Bool) throws -> [AskMeetingSnapshot]
  static func filterOptions(_ snapshots: [AskMeetingSnapshot]) -> (participants: [String], tags: [String])   // distinct, sorted with localizedStandardCompare
}
```
Chunking: summary split at `## ` headers into sections (intro included), each section ≤ `summarySectionMaxChars` (split further on blank lines), `timeLabel` = nil. One chunk per structured action item: `"Action item: <task> — owner: <owner ?? "unassigned">[ — due <due>][ — "<quote>"]"`, `timeLabel` = item.timestamp. Transcript via `TranscriptChunker.chunks(of:chunkTokens:overlapTokens:)`, `timeLabel` = chunk.startLabel. Meetings with neither summary nor transcript produce no chunks.
`load`: `FetchDescriptor<Meeting>` sorted by `date` desc, `fetchLimit = limit`; skip pending-deletion ids, `.upcoming`/`.recording`/`.pausedRecording` meetings, and meetings with empty summary and transcript.
`AskFilter.matches`: `from` compares `calendar.startOfDay(for: from) <= m.date`; `to` is inclusive through end of that day; participant: any participant whose `AskTokenizer.fold` contains the folded filter text; tag: `m.tags.contains(tag.lowercased())`. All set criteria must hold (AND).

- [ ] **Step 1: Failing tests:** `testSummaryIsSplitBySection` (summary with intro + `## Besluiten` + `## Actiepunten` → 3 `.summary` chunks, nil timeLabel); `testStructuredItemsBecomeOwnChunks` (2 items → 2 `.actionItem` chunks, text contains task + owner, timeLabel `"12:34"`); `testUnassignedOwnerWording` (owner nil → text contains `owner: unassigned`); `testTranscriptChunksCarryStartLabel` (40 lines `"[mm:ss] Spreker 1: …"` → ≥ 2 `.transcript` chunks, first timeLabel `"00:00"`); `testOldMeetingWithoutStructuredItemsIsChunked` (no items, plain `[00:05] tekst` transcript + summary → has `.summary` and `.transcript` chunks, no `.actionItem`); `testEmptyMeetingHasNoChunks`; `testChunkIDsAreUniqueAndStable` (two calls equal, `Set(ids).count == ids.count`); `testFilterDateRangeInclusive` (meeting at 2026-11-03 23:30 matches `to = 2026-11-03 00:00`; 2026-11-04 does not); `testFilterParticipantFoldsDiacritics` (`"Zoë Jansen"` matches `"zoe"`); `testFilterTagAndCombination` (tag match but participant mismatch → false); `testLoadSkipsPendingDeletionUpcomingAndEmpty` (in-memory container built like `GlobalSearchViewModelTests.makeContainer()`: 4 meetings — completed with transcript, completed pending deletion, upcoming, completed empty → 1 snapshot); `testFilterOptionsDistinctSorted`.
- [ ] **Step 2: Run** SWIFT-TEST `-only-testing:CasablancaTests/AskCorpusTests` → FAIL.
- [ ] **Step 3: Implement**; add files to pbxproj.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(ask): meeting corpus chunks and filters`.

### Task C2.3: BM25 index

**Files:**
- Create: `Casablanca/Services/BM25Index.swift`
- Test: `CasablancaTests/BM25IndexTests.swift`
- Modify: `Casablanca.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `AskTokenizer.tokens`, `AskChunk` (C2.1, C2.2).
- Produces:
```swift
struct ScoredChunk: Equatable, Sendable { let chunk: AskChunk; let score: Double }
struct BM25Index: Sendable {
  static let k1 = 1.2; static let b = 0.75
  init(chunks: [AskChunk], titles: [UUID: String])   // indexed text = title + "\n" + chunk.text (title boost by inclusion)
  var count: Int { get }
  func search(_ query: String, allowedMeetings: Set<UUID>?, limit: Int) -> [ScoredChunk]   // nil = all; score > 0 only; sorted by score desc, then chunk.id asc
}
```
Scoring (Lucene BM25, non-negative IDF):
```
idf(t)   = ln(1 + (N - df(t) + 0.5) / (df(t) + 0.5))
score(d) = Σ_{t ∈ unique(query tokens)} idf(t) * tf(t,d) * (k1 + 1) / (tf(t,d) + k1 * (1 - b + b * |d| / avgdl))
```
N, df and avgdl are over the whole index (filters restrict results, not statistics). Store postings `[term: [(docIndex, tf)]]` and doc lengths; search touches only postings of query terms.

- [ ] **Step 1: Failing tests:** `testExactTermOutranksAbsent` (docs "bgz profiel mapping", "lunch planning" → query "bgz" returns only doc 0); `testRareTermOutweighsCommonTerm` (3 docs contain "meeting", 1 contains "fhir"; query "meeting fhir" → fhir doc first); `testTermFrequencySaturates` (doc with "bgz"×10 scores < 2× doc with "bgz"×1 of equal length); `testLengthNormalisation` (same tf, shorter doc ranks first); `testIDFIsNonNegative` (term in every doc → score ≥ 0, results still returned when it is the only query term); `testAllowedMeetingsFilter` (two meetings, filter to one → only its chunks); `testLimitAndTieOrder` (equal scores ordered by id; `limit: 1` → 1 result); `testDiacriticQueryRetrievesUnaccentedDoc` ("geïnteresseerd" query hits "geinteresseerd" doc); `testTitleBoost` (query matching only the meeting title still returns that meeting's chunks); `testEmptyQueryOrIndex` (→ `[]`); `testManualScoreValue` (2 docs, pin one BM25 score to 1e-9 computed by hand in the test from the formula above).
- [ ] **Step 2: Run** SWIFT-TEST `-only-testing:CasablancaTests/BM25IndexTests` → FAIL.
- [ ] **Step 3: Implement**; add files to pbxproj.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(ask): in-memory BM25 index`.

### Task C2.4: Context selection and prompt

**Files:**
- Create: `Casablanca/Services/AskPrompt.swift`
- Test: `CasablancaTests/AskPromptTests.swift`
- Modify: `Casablanca.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `ScoredChunk`, `AskMeetingSnapshot`, `AskFilter`; `LLMPromptSupport.budgetTokens`.
- Produces:
```swift
struct AskSource: Identifiable, Equatable, Sendable { let id: Int /* 1-based S-number */; let meetingID: UUID; let meetingTitle: String /* citationTitle */
  let dateLabel: String /* yyyy-MM-dd */; let timeLabel: String?; let kind: AskChunkKind; let text: String
  var citation: String }   // "[<title>, <date>, <time>]" or "[<title>, <date>]"
enum AskCitationFormat { static func citationTitle(_ title: String) -> String; static func dateLabel(_ date: Date, calendar: Calendar = .current) -> String }
enum AskPrompt {
  static let systemFraming: String        // exact text below
  static let maxSourcesPerMeeting = 4; static let retrievalLimit = 60; static let answerReserveTokens = 0  // output is capped separately by maxTokens
  static func selectSources(_ scored: [ScoredChunk], meetings: [UUID: AskMeetingSnapshot], question: String, filter: AskFilter, tokenBudget: Int) -> [AskSource]
  static func render(question: String, filter: AskFilter, sources: [AskSource]) -> String
}
```
`selectSources`: fixed cost = `budgetTokens(render(question:filter:sources: []))`; walk `scored` in order, skip a chunk when its meeting already has `maxSourcesPerMeeting`, add while `fixed + Σ budgetTokens(source block) <= tokenBudget`; skip (don't stop) on a chunk that doesn't fit so smaller later chunks can still enter. If nothing fits but `scored` is non-empty, include the first chunk with its text prefix-truncated to the remaining budget (minimum 200 chars) and `…` appended. Ids are 1…n in selection order.

`AskPrompt.systemFraming` (exact copy):
```
You answer questions about the user's past meetings. Use ONLY the sources below: excerpts from meeting summaries, extracted action items and transcripts. If the sources do not contain the answer, say so plainly (for example "Ik kan dat niet vinden in je meetings." or "I can't find that in your meetings.") instead of guessing. Do not use outside knowledge.

Answer in the language of the question. Start with a short, direct answer; add supporting points only when they help.

Cite every factual claim with the citation shown in the header of the source it came from, copied exactly, for example [Refinement Team Link, 2026-11-03, 12:34]. Some sources have no time; cite those as shown, for example [Refinement Team Link, 2026-11-03]. Several citations for one claim go in one bracket separated by "; ". Never invent a citation, never cite a source number, and never cite a meeting that is not in the sources.

When sources disagree, say so and cite both; the most recent meeting usually reflects the current state. In transcript lines, a name before a colon ("Youri: ...") is the person who said it. Action item sources state the owner only when someone was explicitly assigned; do not assign owners yourself.
```
`render` layout (exact, sections separated by one blank line; filter section omitted when `filter.isEmpty`; filter lines only for set criteria):
```
<systemFraming>

## Filters
Date range: 2026-10-01 to 2026-11-05
Participant: Kim
Tag: partner

## Sources
### Source 1 | Cite as: [Refinement Team Link, 2026-11-03, 12:34] | transcript
<text>

### Source 2 | Cite as: [Refinement Team Link, 2026-11-03] | summary
<text>

## Question
<question>
```
With no sources the `## Sources` body is `(No matching meeting content was found.)`.

- [ ] **Step 1: Failing tests:** `testFramingIsExact` (`AskPrompt.systemFraming` hasPrefix `"You answer questions about the user's past meetings."` and contains `"[Refinement Team Link, 2026-11-03, 12:34]"`); `testRenderLayout` (one transcript + one summary source → contains `"### Source 1 | Cite as: [T, 2026-11-03, 12:34] | transcript"`, `"### Source 2 | Cite as: [T, 2026-11-03] | summary"`, ends with `"## Question\nwat is besloten?"`, no `## Filters`); `testRenderFilters` (participant + tag set → `"## Filters\nParticipant: Kim\nTag: partner"`, no `Date range` line); `testNoSourcesMarker`; `testCitationTitleSanitises` (`"Bila [extern]\nx"` → `"Bila (extern) x"`); `testSelectionRespectsBudget` (100 chunks × ~300 tokens, budget 6 000 → `budgetTokens(render(...)) <= 6000`, ≥ 1 source); `testPerMeetingCap` (10 top chunks from meeting A then 1 from B → A has 4 sources, B is included); `testSkipsTooLargeButKeepsSmallerLater`; `testOversizedFirstChunkIsTruncatedNotDropped` (single chunk larger than budget → 1 source, text ends with `…`, fits budget); `testLargeBudgetTakesMoreSources` (budget 150 000 → up to `retrievalLimit`-bounded count, more than with 6 000); `testSourceIdsSequential`.
- [ ] **Step 2: Run** SWIFT-TEST `-only-testing:CasablancaTests/AskPromptTests` → FAIL.
- [ ] **Step 3: Implement**; add files to pbxproj.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(ask): budgeted source selection and ask prompt`.

### Task C2.5: Citation parsing, resolution and links

**Files:**
- Create: `Casablanca/Services/AskCitations.swift`
- Test: `CasablancaTests/AskCitationsTests.swift`
- Modify: `Casablanca.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `AskSource` (C2.4), `TranscriptLineFormat.seconds(fromLabel:)`.
- Produces:
```swift
struct AskCitationTarget: Equatable, Sendable { let meetingID: UUID; let seconds: Double? }   // Phase 2 handoff type
struct AskCitation: Equatable, Sendable { let title: String; let dateLabel: String; let timeLabel: String?; let target: AskCitationTarget? /* nil = unresolved */ }
enum AskAnswerSegment: Equatable { case text(String); case citations(raw: String, [AskCitation]) }
enum AskCitations {
  static let urlScheme = "casablanca-ask"
  static func segments(in answer: String, sources: [AskSource]) -> [AskAnswerSegment]
  static func attributed(_ segments: [AskAnswerSegment]) -> (text: AttributedString, targets: [Int: AskCitationTarget])  // resolved citations get .link = url(for: n)
  static func url(for index: Int) -> URL          // casablanca-ask://citation/<index>
  static func index(from url: URL) -> Int?        // nil for other schemes/malformed
}
```
Parsing: scan bracket groups `\[([^\[\]\n]+)\]`; split the inside on `"; "`; each part must match `^(.+), (\d{4}-\d{2}-\d{2})(?:, (\d{1,2}:\d{2}(?::\d{2})?))?$` (greedy title so commas in titles stay in the title); if any part fails, the whole bracket stays `.text`. Resolution against `sources` only: exact match on `(AskTokenizer.fold(title), dateLabel)`; else, if exactly one source meeting has that `dateLabel`, use it; else unresolved. `seconds` = `TranscriptLineFormat.seconds(fromLabel: timeLabel)` when a time is present, else nil. Adjacent `.text` segments are merged. Unresolved citations render as plain text in `attributed`.

- [ ] **Step 1: Failing tests:** `testSingleCitationResolves` (`"Besloten [T, 2026-11-03, 12:34]."` with source T/2026-11-03 → segments `[.text("Besloten "), .citations(raw:"[T, 2026-11-03, 12:34]", [target seconds 754]), .text(".")]`); `testCitationWithoutTime` (→ seconds nil); `testHourLabel` (`1:02:03` → 3723); `testTitleWithCommaParses` (`"[Bila Youri, Martijn, 2026-11-03, 05:00]"` → title `"Bila Youri, Martijn"`, resolved); `testBracketsInTitleAreSanitised` (source title from `citationTitle("Sync [extern]")`, answer cites `[Sync (extern), 2026-11-03]` → resolved); `testSemicolonSeparatedCitations` (two citations in one bracket → one `.citations` with 2 entries); `testCitationNotInSourcesIsUnresolved` (other title and date → `target == nil`, and `attributed` has no link run for it); `testSameDateUniqueFallback` (title slightly different, single source meeting that day → resolved); `testSameDateAmbiguousIsUnresolved` (two meetings that day, unknown title → nil); `testPlainBracketsAndBareTimestampsStayText` (`"[x]"`, `"[12:34]"`, `"[TODO, later]"` → `.text`); `testCaseAndDiacriticInsensitiveTitle` (`"café sync"` vs source `"Cafe Sync"`); `testURLRoundTrip` (`index(from: url(for: 7)) == 7`; `index(from: URL(string:"https://x")!) == nil`); `testAttributedLinksOnlyResolved` (two citations, one resolved → exactly one run with `.link`, `targets.count == 1`).
- [ ] **Step 2: Run** SWIFT-TEST `-only-testing:CasablancaTests/AskCitationsTests` → FAIL.
- [ ] **Step 3: Implement**; add files to pbxproj.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(ask): parse and resolve meeting citations`.

### Task C2.6: AskService (lazy index, single-turn answer)

**Files:**
- Create: `Casablanca/Services/AskService.swift`
- Test: `CasablancaTests/AskServiceTests.swift`
- Modify: `Casablanca.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: C2.2–C2.5; `LLMProvider`, `LLMProviderFactory.current()`, `LLMRetryPolicy`, `LLMPromptSupport` (`thinkingEnabled`, `applyThinkingSwitch`, `tokenBudget(thinkingEnabled:)`, `stripReasoningTags`).
- Produces:
```swift
struct AskAnswer: Equatable { let question: String; let text: String; let segments: [AskAnswerSegment]; let sources: [AskSource] }
@MainActor @Observable final class AskService {
  private(set) var answer: AskAnswer?; private(set) var isAnswering: Bool; private(set) var isIndexing: Bool
  private(set) var statusMessage: String?; var errorMessage: String?
  private(set) var filterOptions: (participants: [String], tags: [String])   // from the last snapshot load
  init(snapshotLoader: @escaping @MainActor () throws -> [AskMeetingSnapshot],
       providerFactory: @escaping () -> LLMProvider = { LLMProviderFactory.current() },
       retryPolicy: LLMRetryPolicy = LLMRetryPolicy(),
       thinkingEnabled: @escaping () -> Bool = { LLMPromptSupport.thinkingEnabled() })
  func invalidateIndex()                               // next ask (or prepareIndex) rebuilds
  @discardableResult func prepareIndex() -> Task<Void, Never>   // loads snapshots on main, builds chunks + BM25Index in Task.detached, publishes
  @discardableResult func ask(_ question: String, filter: AskFilter) -> Task<Void, Never>?   // nil when trimmed question empty or already answering
  func cancel()
}
```
Flow of `ask`: ensure index (await `prepareIndex()` if stale/absent) → `allowed` = ids of snapshots matching `filter` (nil when `filter.isEmpty`) → `index.search(question, allowedMeetings: allowed, limit: AskPrompt.retrievalLimit)` → `selectSources(…, tokenBudget: provider.promptTokenBudget)` → if no sources: set `answer` with text `"No meeting content matches this question and filter."`, segments `[.text(...)]`, **no LLM call** → else `generate(prompt: applyThinkingSwitch(render(…)), temperature: nil, maxTokens: tokenBudget(thinkingEnabled:), timeout: provider.timeout(orDefault: 120), truncated: nil)` inside `retryPolicy.withRetry` (status message `"<displayName> request failed, retrying (n/max)…"` like `MeetingChatService`) → `stripReasoningTags` (not `stripReasoning`: an answer may contain `#` headings) → `segments(in:sources:)`. Single-turn: each ask replaces `answer`; no history in the prompt. Cancellation guards like `MeetingChatService`. Empty model output → text `"<displayName> returned an empty answer."`.

- [ ] **Step 1: Failing tests** (pattern: `waitForAnswer` loop from `MeetingChatServiceTests`; snapshots built from in-memory `Meeting`s via `AskMeetingSnapshot(meeting:)`):
  - `testAskSendsRetrievedSourcesAndQuestion` — 2 meetings, question matches meeting A → stub's single call prompt contains A's citation header and the question, not B's title.
  - `testFilterRestrictsSources` — filter tag `"partner"` on meeting B only → prompt contains only B sources.
  - `testNoMatchSkipsLLM` — question with no matching tokens → `stub.calls.isEmpty`, answer text is the no-match copy.
  - `testUsesProviderBudgetAndTimeout` — stub `promptTokenBudget: 1_500, preferredTimeout: 600` → `budgetTokens(prompt) <= 1_500`, `calls[0].timeout == 600`.
  - `testAnswerCitationsAreResolved` — stub returns `"Ja [<A title>, <A date>, 00:10]."` → `answer.segments` contains a `.citations` whose target meetingID == A.id, seconds 10.
  - `testSingleTurnReplacesAnswer` — two asks → second prompt does not contain the first question; `answer.question` is the second.
  - `testThinkingOffAppendsNoThink` — `thinkingEnabled: { false }` → prompt hasSuffix `"/no_think"`, `maxTokens == LLMPromptSupport.cappedOutputTokens`.
  - `testReasoningTagsStripped` — stub `"<think>x</think># Antwoord\nJa"` → text `"# Antwoord\nJa"`.
  - `testIndexIsLazyAndInvalidates` — loader counts calls: init → 0; first ask → 1; second ask → 1; `invalidateIndex()` + ask → 2.
  - `testRetryStatusAndErrorSurface` — outcomes `[transientFailure(), transientFailure(), transientFailure()]` with `LLMRetryPolicy(maxAttempts: 3, …)` as in `MeetingChatServiceTests` → `errorMessage != nil`, `statusMessage == nil` afterwards, `isAnswering == false`.
  - `testEmptyQuestionIsIgnored` — `ask("  ", filter: .none) == nil`.
- [ ] **Step 2: Run** SWIFT-TEST `-only-testing:CasablancaTests/AskServiceTests` → FAIL.
- [ ] **Step 3: Implement**; add files to pbxproj.
- [ ] **Step 4: Run** `-only-testing:CasablancaTests/AskServiceTests -only-testing:CasablancaTests/MeetingChatServiceTests` → PASS.
- [ ] **Step 5: Commit** `feat(ask): ask service over a lazily built index`.

### Task C2.7: Ask view, sidebar entry and route

**Files:**
- Create: `Casablanca/Views/AskView.swift`
- Modify: `Casablanca/Views/SidebarView.swift` (Ask `Section` after Approvals ~line 60–64; `case ask` in `SidebarDestination` ~line 462), `Casablanca/Views/ContentView.swift` (`@State private var askService: AskService?` created in `.task`; `case .ask:` in `detailView` ~line 163)
- Test: `CasablancaTests/AskViewModelTests.swift`
- Modify: `Casablanca.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `AskService` (C2.6), `AskCitations.attributed/index(from:)`, `AskFilter`, `AskCitationTarget`.
- Produces:
```swift
typealias AskCitationHandler = @MainActor (AskCitationTarget) -> Void
struct AskView: View { @Bindable var service: AskService; let isSummaryInProgress: Bool; let onOpenCitation: AskCitationHandler }
struct AskFormState: Equatable {          // pure, tested; the view binds to it
  var question = ""; var useDateRange = false; var from: Date; var to: Date; var participant = ""; var tag = ""
  var filter: AskFilter { get }           // empty participant/tag → nil; useDateRange false → from/to nil; from > to → swapped
  var canSubmit: Bool { get }             // non-blank question
}
```
UI (existing design tokens: `CasaSpace`, `Color.textSecondary`, `Label(...).font(.caption.weight(.bold)).textCase(.uppercase)` header like `MeetingChatTab`): header "Ask across meetings"; question `TextField` (`axis: .vertical`, ⏎ submits); filter row: "Date range" toggle + two compact `DatePicker`s, participant `Picker` ("Anyone" + `service.filterOptions.participants`), tag `Picker` ("Any tag" + tags); Ask button disabled when `!canSubmit || service.isAnswering || isSummaryInProgress` (hint copy: "Available after the summary finishes — the local model handles one request at a time."); progress row while `isIndexing` ("Indexing meetings…") or `isAnswering` (`statusMessage ?? "Thinking…"`); answer as `Text(attributed.text).textSelection(.enabled)` with `.environment(\.openURL, OpenURLAction { url in if let i = AskCitations.index(from: url), let t = targets[i] { onOpenCitation(t); return .handled }; return .systemAction })`; collapsible "Sources (n)" list: each row `source.citation` + kind, button → `onOpenCitation(AskCitationTarget(meetingID:, seconds: timeLabel.flatMap(TranscriptLineFormat.seconds(fromLabel:))))`; error row with dismiss. `.onAppear { service.prepareIndex() }`; `.onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { _ in service.invalidateIndex() }`.
Sidebar: `Label("Ask", systemImage: "text.bubble").tag(SidebarDestination.ask)` in its own `Section` after Approvals.
ContentView: `askService = AskService(snapshotLoader: { [modelContext, viewModel] in try AskCorpus.load(from: modelContext, isPendingDeletion: { viewModel.isPendingDeletion($0) }) })`; route `case .ask: if let askService { AskView(service: askService, isSummaryInProgress: appModel.summarizationService.summarizingMeetingID != nil, onOpenCitation: { target in viewModel.sidebarSelection = .meeting(target.meetingID) }) }`.

**Phase 2 handoff (I1):** `onOpenCitation` in `ContentView` is the single seam. Phase 2 replaces its body with `MeetingDetailNavigator.shared.jump(to: target.meetingID, seconds: target.seconds ?? 0)` when `target.seconds != nil` (keep the plain selection when nil). The answer text may also be passed through Phase 2's `TimestampLinkText` for bare `[mm:ss]` — not needed: Ask citations already carry the meeting, and bare timestamps in an Ask answer have no meeting context, so leave them as text. Put this note as a `// PHASE 2 HANDOFF:` comment on the closure.

- [ ] **Step 1: Failing tests** `AskViewModelTests`: `testFormDefaultsProduceEmptyFilter` (`filter.isEmpty`); `testBlankFieldsMapToNil` (participant `"  "` → nil); `testDateRangeOnlyWhenToggled`; `testSwappedDatesAreOrdered` (from > to → filter.from <= filter.to); `testCanSubmitNeedsQuestion`; `testSidebarDestinationAskIsDistinct` (`SidebarDestination.ask != .dashboard`, hashable into a `Set` of all five cases with count 5).
- [ ] **Step 2: Run** SWIFT-TEST `-only-testing:CasablancaTests/AskViewModelTests` → FAIL.
- [ ] **Step 3: Implement** the view, sidebar entry and route; add files to pbxproj.
- [ ] **Step 4: Run** `-only-testing:CasablancaTests/AskViewModelTests -only-testing:CasablancaTests/MeetingStartFlowTests -only-testing:CasablancaTests/SplitLayoutStabilityTests` → PASS (row actions and split layout untouched).
- [ ] **Step 5: In-app check** (per `project_casablanca-view-verification`: build + tests are not enough): launch the build, click Ask in the sidebar, ask a question about a known meeting with the configured provider → answer renders with citation links; click one → that meeting opens; narrow the window to compact width and back → no layout crash/constraint loop (screenshot both). Switch Dashboard ↔ Ask ↔ a meeting repeatedly → no blank detail column.
- [ ] **Step 6: Commit**
```bash
git add Casablanca/Views/AskView.swift Casablanca/Views/SidebarView.swift Casablanca/Views/ContentView.swift CasablancaTests/AskViewModelTests.swift Casablanca.xcodeproj/project.pbxproj
git commit -m "feat(ask): ask across meetings view with tappable citations"
```

---

## Track-C completion gate

- [ ] Run every Track C class together: SWIFT-TEST with `-only-testing:` for `EvaluationExportTests AskTokenizerTests AskCorpusTests BM25IndexTests AskPromptTests AskCitationsTests AskServiceTests AskViewModelTests MeetingChatServiceTests MeetingStartFlowTests` → `** TEST SUCCEEDED **`; record the test count. `python3 -I -m unittest discover tools/eval/tests` → `OK`; record the count.
- [ ] `git status --short` shows nothing outside the files listed in this plan (in particular nothing under `tools/` except `tools/eval/`, no `gold/` or `exports/` content).
- [ ] Subagent review (non-skippable): one fresh reviewer checks the track diff against the spec's Track C section, this plan's Contracts (Swift export ↔ Python loader agree key-for-key), Global Constraints and Review Focus; fix findings, re-run the affected classes.

## Track-C pre-merge checklist (in-app checks for Youri)

1. **Export:** open a recent meeting with a summary → File → "Export Meeting for Evaluation…" → save under `tools/eval/exports/`. Repeat for one *old* meeting (before this branch) → its export says `"actionItemsSource": "summaryMarkdown"`.
2. **Gold draft:** `python3 -I tools/eval/casaeval.py make-gold tools/eval/exports/<file>.json` → file appears in `tools/eval/gold/`; correct the items, set `"reviewed": true`.
3. **Score:** `python3 -I tools/eval/casaeval.py score --gold tools/eval/gold --export tools/eval/exports` → per-meeting line + TOTAL; an unreviewed gold prints the warning. Numbers look plausible against what you corrected.
4. **Privacy:** `git status` shows nothing from `tools/eval/gold/` or `tools/eval/exports/`.
5. **Ask, Dutch:** ask "Wat hebben we besloten over BgZ?" (or another topic you know) → answer in Dutch with `[titel, datum, mm:ss]` citations; clicking one opens the right meeting (jump to the timestamp arrives in Phase 2).
6. **Ask, filters:** same question with a participant filter and with a date range that excludes the meeting → second time it says nothing matches, without waiting on the model.
7. **Ask, unknown:** ask something never discussed → the answer says it can't find it, no invented citations.
8. **Ask during a summary:** start a summary, open Ask → Ask button disabled with the hint; enabled again after the summary finishes.
9. **Ask with Claude Code provider and with a local provider** → both answer; the local one stays responsive on a large store (first ask shows "Indexing meetings…" briefly).

## Self-Review

1. **Spec coverage:** C1 gold format (Contracts + C1.4), scorer with action-item precision/recall/owner accuracy and decision recall with fuzzy matching (C1.3–C1.4), make-gold with `"reviewed": false` + scorer warning (C1.5, C1.4), export menu item (C1.1–C1.2), 0 real gold + one synthetic example + `.gitignore` (C1.3–C1.4). C2 Ask sidebar view + filters date/participant/tag (C2.2, C2.7), new in-memory BM25 over summaries + structured items + transcript chunks, built lazily (C2.2, C2.3, C2.6), top-k within provider budget (C2.4), single-turn (C2.6), citations `[Meeting title, date, mm:ss]` that open the meeting, timestamp jump handed to Phase 2 (C2.5, C2.7 handoff). No embeddings.
2. **Step scan:** every test step names tests and assertions; bodies given only for BM25 scoring, matching order, prompt copy and the JSON contract.
3. **Type consistency:** `AskChunk.timeLabel`, `AskSource.timeLabel/dateLabel/citation`, `AskCitationTarget(meetingID:seconds:)`, `AskFilter.none/isEmpty`, `BM25Index.search(_:allowedMeetings:limit:)`, `AskPrompt.selectSources(_:meetings:question:filter:tokenBudget:)` used identically in C2.4–C2.7; `EvaluationExport.topLevelKeys` equals the Python contract key list in C1.4.
4. **Review Focus:** each of the five lines has a named test in its owning task.
5. **Proportion:** code blocks are signatures, the scoring formula, the exact prompt and the JSON contract.
