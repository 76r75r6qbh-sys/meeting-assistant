# Speech pipeline best practices — Implementation Plan (master)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Speaker-aware transcripts, verifiable structured action items with approval, meeting-type templates, evaluation tooling and cross-meeting Q&A (16 points of the research report).

**Architecture:** Phase 0 lands all shared contracts (value types, transcript-line format, schema V3, audio clip player, settings scaffolding) on the branch. Phase 1 runs three independent tracks in parallel worktrees branched from the Phase 0 commit, each with its own plan file. Phase 2 merges and adds the cross-track features. Phase 3 runs the full suite once.

**Tech Stack:** Swift 5 / SwiftUI / SwiftData (macOS), WhisperKit, FluidAudio (new SPM dep, Track A), CryptoKit, Python 3 stdlib (eval tooling).

**Spec:** `docs/superpowers/specs/2026-11-05-speech-pipeline-best-practices-design.md` (binding authority).

**Track plans:**
- Track A (points 1, 2, 12, 11, 3, 4, 16): `docs/superpowers/plans/2026-11-05-speech-pipeline-track-a.md`
- Track B (points 5, 6, 7, 9, 10, 13): `docs/superpowers/plans/2026-11-05-speech-pipeline-track-b.md`
- Track C (points 14, 15): `docs/superpowers/plans/2026-11-05-speech-pipeline-track-c.md`

## Global Constraints

- Branch `76r75r6qbh-sys/speech-pipeline-best-practices`; tracks work in worktrees on `…-track-a/-b/-c` branched from the Phase 0 tip; never push, never open a PR, never release.
- **Do not run the full test suite until Phase 3** (Youri's instruction). During tasks run only the affected classes: `xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -derivedDataPath .build/test-<track> -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' -only-testing:CasablancaTests/<Class>` (a distinct `-derivedDataPath` per worktree so parallel builds don't collide).
- `Casablanca.xcodeproj/project.pbxproj` lists every file explicitly: each new file needs PBXFileReference, PBXBuildFile, group and Sources-phase entries (copy the pattern of `SummarizationService.swift` for app files, `StubLLMProvider.swift` for test files).
- Never call a live LLM or network in tests; use `CasablancaTests/LLM/StubLLMProvider.swift`.
- Old meetings (no speaker data, no structured items, no tracks) must keep working everywhere.
- Transcript line format: `[mm:ss] <Speaker>: <text>` / `[h:mm:ss] …`; the speaker prefix is optional for every consumer.
- Owners only on explicit evidence; otherwise `nil`. Voiceprints off by default.
- Tracks edit only the files their plan lists; shared files (`Meeting.swift`, `TodoItem.swift`, `CasablancaSchema.swift`, `SettingsView.swift`, the new `Models/SpeakerTranscript.swift`, `Models/ExtractedActionItem.swift`, `Services/TranscriptLineFormat.swift`, `Services/AudioClipPlayer.swift`) change only in Phase 0 or Phase 2. pbxproj edits are unavoidable per track; keep them minimal (conflicts resolved in Phase 2).
- Commits: conventional messages ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. A meeting recorded before this change (no `speakersData`, transcript lines without speaker) opened, chatted, summarized, exported and searched → behaves exactly as before. (Test owners: T0.1 parser, Track B summarization tests, Track C retrieval tests.)
2. Upgrading an existing V2 store → no data loss, existing to-dos become `.accepted` and keep syncing. (T0.2.)
3. A hand-edited / terminology-corrected transcript, then a speaker rename → only `<Speaker>: ` prefixes change. (T0.1.)
4. Recording with system audio unavailable (mic only), or diarization model download failing offline → pipeline completes, transcript labels the user only. (Track A.)
5. LLM returns malformed JSON / no JSON block → one repair retry, then today's markdown path with a warning; never zero to-dos silently when the markdown has them. (Track B.)

---

## Phase 0 — shared contracts (sequential, on the main branch)

### Task 0.1: Speaker transcript value types and line format

**Files:**
- Create: `Casablanca/Models/SpeakerTranscript.swift`, `Casablanca/Models/ExtractedActionItem.swift`, `Casablanca/Services/TranscriptLineFormat.swift`
- Test: `CasablancaTests/TranscriptLineFormatTests.swift`, `CasablancaTests/ExtractedActionItemTests.swift`

**Interfaces — Produces:**
```swift
struct TranscriptWord: Codable, Equatable { var start: Double; var end: Double; var text: String }
struct SpeakerSegment: Codable, Equatable { var start: Double; var end: Double; var speakerID: String?; var text: String; var words: [TranscriptWord]? }
enum SpeakerSource: String, Codable { case microphone, system, room }
struct SpeakerInfo: Codable, Equatable, Identifiable { var id: String; var displayName: String; var source: SpeakerSource; var isUser: Bool; var nameConfirmed: Bool }
enum SpeakerData { static func encodeSegments(_: [SpeakerSegment]) -> Data?; static func decodeSegments(_: Data?) -> [SpeakerSegment]; static func encodeSpeakers(_: [SpeakerInfo]) -> Data?; static func decodeSpeakers(_: Data?) -> [SpeakerInfo] }  // decode of nil/garbage → []
enum VerificationState: String, Codable { case unverified, supported, unsupported }
struct ExtractedActionItem: Codable, Equatable { var task: String; var owner: String?; var due: String?; var dueIsExplicit: Bool; var confidence: Double; var quote: String?; var timestamp: String?; var verified: VerificationState; var verificationReason: String? }
enum ActionItemData { static func encode(_: [ExtractedActionItem]) -> Data?; static func decode(_: Data?) -> [ExtractedActionItem] }
struct TranscriptLine: Equatable { var label: String /* "12:34" or "1:02:03" */; var seconds: Double; var speaker: String?; var text: String }
enum TranscriptLineFormat {
  static func parse(_ line: String) -> TranscriptLine?          // nil if no leading [ts]
  static func timestampLabel(seconds: Double) -> String         // mm:ss below 1h, h:mm:ss at/after; same output as TranscriptionService's formatter (move it here and make TranscriptionService call this)
  static func render(_ segments: [SpeakerSegment], speakers: [SpeakerInfo]) -> String   // one line per segment, "[label] Name: text"; unknown/nil speakerID → no prefix
  static func renameSpeaker(in transcript: String, from old: String, to new: String) -> String  // only "] old: " at line start after the timestamp
  static func seconds(fromLabel: String) -> Double?
}
```
Speaker prefix grammar: after `] `, a name of 1–40 chars without `:` or `[` followed by `: `. A line whose text merely contains a colon later (`[00:10] Agenda: punt 1`) is ambiguous — `parse` treats a prefix as a speaker **only** when `knownSpeakers` matches; add overload `parse(_:knownSpeakers: Set<String>)` and have `parse(_:)` return `speaker = nil`.

- [ ] Write failing tests: `testParsesPlainOldLine` (`"[01:05] hallo"` → label `01:05`, seconds 65, speaker nil); `testParsesHourLabel` (`"[1:02:03] x"` → 3723); `testParsesKnownSpeaker` (`"[00:10] Youri: ja"` with `["Youri"]` → speaker `Youri`, text `ja`); `testColonTextIsNotSpeakerWhenUnknown` (`"[00:10] Agenda: punt 1"` with `[]` → speaker nil, text `Agenda: punt 1`); `testRenderUsesDisplayNames`; `testRenderOmitsPrefixForNilSpeaker`; `testRenameOnlyTouchesPrefix` (transcript with `Spreker 1:` as prefix and inside text → only prefix renamed); `testRenamePreservesHandEdits`; `testTimestampLabelMatchesLegacyFormatter` (0, 59.9, 3599, 3600 against the current `TranscriptionService` output); `testDecodeGarbageIsEmpty`; `ExtractedActionItemTests.testRoundTrip`, `testDecodeNilIsEmpty`.
- [ ] Run `-only-testing:CasablancaTests/TranscriptLineFormatTests -only-testing:CasablancaTests/ExtractedActionItemTests` → FAIL (types missing).
- [ ] Implement the three files; switch `TranscriptionService`'s timestamp formatter (TranscriptionService.swift:40-66) to `TranscriptLineFormat.timestampLabel`.
- [ ] Run the two classes plus `TranscriptPresentationTests`, `TranscriptChunkerTests` → PASS.
- [ ] Commit `feat(model): speaker transcript and action item value types`.

### Task 0.2: Schema V3

**Files:** Modify `Casablanca/Models/Meeting.swift`, `Casablanca/Models/TodoItem.swift`, `Casablanca/Models/CasablancaSchema.swift`; Test `CasablancaTests/SchemaMigrationTests.swift` (+ fixture under `CasablancaTests/Fixtures/` if needed).

**Interfaces — Produces (all with defaults, additive):**
- `Meeting`: `speakerSegmentsData: Data?`, `speakersData: Data?`, `actionItemsData: Data?`, `summaryTemplateID: String?`, `micTrackFileURL: String?`, `systemTrackFileURL: String?`; computed `speakerSegments: [SpeakerSegment]`, `speakers: [SpeakerInfo]`, `actionItems: [ExtractedActionItem]` (get/set via `SpeakerData` / `ActionItemData`).
- `TodoItem`: `owner: String?`, `dueDate: Date?`, `sourceTimestamp: String?`, `quote: String?`, `statusRaw: String = TodoStatus.accepted.rawValue`, `verificationRaw: String?`; `enum TodoStatus: String, Codable { case proposed, accepted, rejected }`; computed `status: TodoStatus` (unknown raw → `.accepted`), `verification: VerificationState?`.
- `CasablancaSchemaV2` becomes a frozen nested copy of today's `Meeting`/`TodoItem` (same pattern as V1); `CasablancaSchemaV3` (3.0.0) uses the top-level models; plan stages V1→V2, V2→V3 both `.lightweight`.

- [ ] Failing tests: `testV2StoreMigratesToV3PreservingMeetingsAndTodos` (build a V2 store with a meeting + 2 todos using the nested V2 models, reopen with the migration plan, assert counts, text, `status == .accepted`, new fields nil); `testTodoStatusUnknownRawIsAccepted`; `testMeetingSpeakerAccessorsRoundTrip`.
- [ ] Run `SchemaMigrationTests` → FAIL.
- [ ] Implement; keep the existing V1→V2 tests green.
- [ ] Run `SchemaMigrationTests`, `PersistenceControllerTests`, `MeetingSoftDeleteTests` → PASS.
- [ ] Commit `feat(model): schema V3 for speakers, action items and to-do review`.

### Task 0.3: Audio clip player and settings scaffolding

**Files:** Create `Casablanca/Services/AudioClipPlayer.swift`, `Casablanca/Views/Settings/SpeakerSettingsSection.swift`, `Casablanca/Views/Settings/PrivacySettingsSection.swift`, `Casablanca/Views/Settings/SummaryTemplatesSettingsSection.swift`, `Casablanca/Views/Settings/ActionItemReviewSettingsSection.swift`; Modify `Casablanca/Views/SettingsView.swift`, `Casablanca/Models/Meeting.swift` (AppPreferenceKey); Test `CasablancaTests/AudioClipPlayerTests.swift`, `CasablancaTests/AppPreferencesTests.swift`.

**Interfaces — Produces:**
- `@MainActor final class AudioClipPlayer: ObservableObject { @Published private(set) var isPlaying: Bool; @Published private(set) var currentTime: Double; @Published private(set) var playingURL: URL?; func play(url: URL, from start: Double, duration: Double? = nil) throws; func stop(); static let shared }` — AVAudioPlayer-based; stops automatically at `start + duration`; playing a new clip stops the previous; inject a `AudioPlaybackEngine` protocol for tests.
- `AppPreferenceKey`: `recogniseSpeakersEnabled` (default true), `keepSpeakerTracks` (true), `wordTimestampsEnabled` (true), `voiceProfilesEnabled` (false), `summaryTemplates` (JSON string, default empty = built-ins), `autoAcceptVerifiedTodos` (false). Register defaults where existing defaults are registered.
- Four section views, each `struct XSettingsSection: View` with a placeholder `Section("…")` containing only the toggles above bound via `@AppStorage`; `SettingsView` embeds Speaker + Privacy in the Recording tab, SummaryTemplates + ActionItemReview in the AI tab. Tracks later fill only these files.

- [ ] Failing tests: `AudioClipPlayerTests.testPlayStopsPreviousClip`, `testStopsAtDuration` (fake engine), `AppPreferencesTests.testNewSpeechPipelineDefaults` (values above).
- [ ] Run → FAIL; implement; run those classes → PASS.
- [ ] In-app check: build and open Settings → AI and Recording tabs render (constraint-pass probe per `SplitColumnMinimumSizeProbe.swift` pattern not required; a launch + screenshot is enough).
- [ ] Commit `feat: audio clip player and settings sections for the speech pipeline`.

**Phase 0 review gate:** one reviewer checks 0.1–0.3 together against the spec contracts before the tracks branch off.

---

## Phase 1 — parallel tracks

Create worktrees from the Phase 0 tip and run each track plan with subagent-driven development, one task at a time inside a track:
```bash
git worktree add ../lahore-track-a -b 76r75r6qbh-sys/speech-pipeline-track-a
git worktree add ../lahore-track-b -b 76r75r6qbh-sys/speech-pipeline-track-b
git worktree add ../lahore-track-c -b 76r75r6qbh-sys/speech-pipeline-track-c
```

---

## Phase 2 — merge and integration (sequential, main branch)

### Task 2.0: Merge tracks
- [ ] `git merge --no-ff` track A, then B, then C; resolve pbxproj conflicts by keeping all entries; build (`xcodebuild build …`) succeeds.
- [ ] Run the classes each track touched (union) → PASS. Commit merges.

### Task 2.1: Clickable timestamps (point 8)
**Files:** Create `Casablanca/Views/Components/TimestampLinkText.swift`; Modify `Views/MeetingDetail/MeetingSummaryTab.swift`, `MeetingTranscriptTab.swift`, the to-do review strip (Track B file), the Ask answer view (Track C file); Test `CasablancaTests/TimestampLinkTests.swift`.
**Interfaces:** `enum TimestampLinks { static func ranges(in text: String) -> [(range: Range<String.Index>, seconds: Double)] }` (matches `[mm:ss]` and `[h:mm:ss]` not inside code spans); `MeetingDetailNavigator.shared.jump(to meetingID: UUID, seconds: Double)` that selects the meeting, switches to the transcript tab, scrolls to the nearest line ≤ seconds and plays the mixed recording from there via `AudioClipPlayer` (transport bar with play/pause + time in the transcript tab).
- [ ] Failing tests: `testFindsMinuteAndHourLabels`, `testIgnoresNonTimestampBrackets` (`[x]`, `[12:345]`), `testSecondsValues`; implement; PASS; in-app check: click a timestamp in a summary → transcript scrolls and audio plays.
- [ ] Commit `feat(ui): clickable timestamps jump to transcript and audio`.

### Task 2.2: Speaker names into summaries (I2)
- [ ] Failing test in `SummarizationServiceTests`: transcript with `Youri:` / `Spreker 1:` prefixes and a confirmed rename → prompt contains renamed names and the speaker-evidence instruction; renaming a speaker on a meeting with a summary sets `offerRegenerateSummary`.
- [ ] Implement the wiring between Track A's rename action and Track B's regenerate; PASS; commit `feat: offer summary regeneration after naming speakers`.

---

## Phase 3 — verification and wrap-up
- [ ] Full suite once: `xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -derivedDataPath .build/test -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''` → `** TEST SUCCEEDED **`; record the count. Fix failures (systematic-debugging), re-run.
- [ ] Final whole-branch review (most capable model) against the spec; fix findings.
- [ ] CHANGELOG `## [Unreleased]` section (Added/Changed per point, model licences, measured numbers from A3/A4); signed test build via `scripts/build-release.sh`-equivalent debug build for Youri's on-device checks list (spec "Testing").
- [ ] Report to Youri: branch, diff summary, test count, on-device checklist; no push/PR without his go.
