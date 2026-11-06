# Speech pipeline best practices — design

**Date:** 2026-11-05
**Status:** Youri asked to build all 16 improvement points from
`docs/research/2026-11-05-transcription-diarization-summary-best-practices.md`
("alle punten oppakken, stuk voor stuk; parallel waar mogelijk; volledige
testsuite pas aan het einde"). Calls marked *(Claude's call)* were not discussed
with Youri.
**Branch:** `76r75r6qbh-sys/speech-pipeline-best-practices` (from master 5ca8686, v0.20.0).

## Why

Casablanca has no notion of *who* said something. The mic and system-audio
tracks are recorded separately and then mixed and deleted
(`Services/Recording/RecordingMixdownRenderer.swift:126-131`, and again in crash recovery `RecordingSessionRecovery.swift:190`), so action items
are attributed by the LLM guessing from content. Action items are parsed from
summary markdown after the fact and carry no owner, due date, quote or
timestamp, so nothing is verifiable. Summary quality is not measured at all.
Goal: speaker-aware transcripts, verifiable structured action items, and a way
to measure whether changes help — while staying local-first.

## Goals

1. Every transcript line says who spoke: the user ("me", from the mic track),
   or a remote/in-room speaker label that can become a real name.
2. Action items are structured data with owner, optional due date, verbatim
   quote and source timestamp; every summary bullet that cites `[mm:ss]` links
   back to the transcript and audio.
3. Summaries are built from extracted facts and verified against the
   transcript before to-dos are proposed; the user approves to-dos.
4. Quality is measurable on a Dutch gold set.

## Non-goals

- No meeting bots, no cloud ASR, no cloud diarization.
- No live (during-meeting) diarization or live notes.
- No Teams Accessibility-API active-speaker scraping.
- No change to the export *formats* beyond adding owner/due/timestamp text.

## Anti-goals (a failure even if it "works")

- Silently storing anyone's voiceprint. Voiceprints are AVG art. 9 biometric
  data: off by default, opt-in per person with explicit consent, deletable.
- Inventing owners: an owner is set only on explicit evidence; otherwise null.
- Breaking existing meetings: old transcripts without speaker data keep
  working everywhere (summaries, chat, search, export).
- Doubling transcription time for the common case.

## Contracts shared by all tracks (Phase 0 builds these)

### Transcript lines
Rendered transcript stays plain text, one line per segment:
`[mm:ss] <Speaker>: <text>` (or `[h:mm:ss]`). The `<Speaker>: ` part is
optional — old transcripts have none, and every consumer must accept both.
`TranscriptChunker`'s label regex already matches the `[mm:ss]` prefix.
Speaker display names: the user's name from Settings (first alias; fallback
"Me"/"Ik" per transcript language) for the mic track; `Speaker 1`, `Speaker 2`…
(`Spreker 1`… for nl) for diarized clusters until renamed; `Others`/`Anderen`
when the system track is not diarized.

### Structured segments
New `Codable` value types (Foundation only):
```swift
struct SpeakerSegment: Codable, Equatable {   // name avoids the existing live `TranscriptSegment` (TranscriptionService.swift:27)
  var start: Double; var end: Double
  var speakerID: String?; var text: String; var words: [TranscriptWord]? }
struct TranscriptWord: Codable, Equatable { var start: Double; var end: Double; var text: String }
struct SpeakerInfo: Codable, Equatable { var id: String; var displayName: String
  var source: SpeakerSource /* .microphone, .system, .room */; var isUser: Bool
  var nameConfirmed: Bool }
```
Stored on `Meeting` as JSON `Data?` (`speakerSegmentsData`,
`speakersData`) — `Data` so it can be externalStorage-friendly later
*(Claude's call)*. `Meeting.transcript` remains the canonical text used by
prompts, editing and search. Segments hold the text *after* the deterministic
terminology replacement (applied per segment); the LLM terminology echo pass
works on the rendered string and its prompt must preserve `<Speaker>:`
prefixes (validated: if prefixes are lost, keep the deterministic result).
Renaming a speaker **never re-renders**: it rewrites the `<Speaker>: ` prefix
at line start in `transcript` (and `displayName` in `speakersData`), so
terminology corrections and hand edits survive *(Claude's call)*.

### Structured action items
```swift
struct ExtractedActionItem: Codable, Equatable { var task: String
  var owner: String?; var due: String? /* ISO date */; var dueIsExplicit: Bool
  var confidence: Double; var quote: String?; var timestamp: String? /* "mm:ss" */
  var verified: VerificationState /* .unverified, .supported, .unsupported */ }
```
Stored per meeting as JSON (`actionItemsData`). `TodoItem` gains
`owner: String?`, `dueDate: Date?`, `sourceTimestamp: String?`,
`quote: String?`, `status` (`.proposed`, `.accepted`, `.rejected`; existing
rows migrate as `.accepted`). Only `.accepted` to-dos sync/export.

### Schema
One new `CasablancaSchemaV3` with *all* new fields from every track, added in
Phase 0 (freeze V2 as a nested copy, lightweight V2→V3 stage, defaults for
every new property). No track adds model fields afterwards.

## Track A — Audio and speakers (points 1, 2, 12, 11, 3, 4, 16)

**A1 Keep tracks (pt 1).** `RecordingMixdownRenderer` *and* the crash-recovery
mixdown (`RecordingSessionRecovery.swift:190`) keep writing the mixed
WAV/m4a (playback, export, backwards compatibility) and no longer delete the
per-source PCM. Per-track files must be merged across pause segments with
exactly the ordering `RecordingSegmentMerger` uses for the mix, and padded so
sample positions line up with the mix (tracks are aligned by sample position
only, `RecordingMixdownRenderer.swift:72-92`). After transcription the two tracks are compressed to m4a next
to the recording (`<name>.mic.m4a`, `<name>.system.m4a`) and the PCMs deleted.
Mic-only recordings (system capture failed) have only a mic track. Track
files follow the recording's lifecycle (deleted with the meeting/recording).
Setting "Keep separate speaker tracks" default on; when off, tracks are
deleted after diarization, so clip playback (A6) and voice profiles (A7) are
unavailable for that meeting. Old meetings have no tracks; their UI degrades
gracefully *(Claude's call)*.

**A2 Attribution without double transcription (pt 1, 2).** Transcribe the
mixed audio once (unchanged cost). With word timestamps (A3), compute per-track
RMS envelopes (e.g. 50 ms frames) and attribute each word to mic or system by
energy ratio; split a Whisper segment where the attributed source changes for
≥ ~0.6 s. Bleed/echo guard (pt 2): mic energy that is strongly correlated with
the system track at the same instant (remote voice leaking from speakers into
the mic) is attributed to the system track; threshold-based, deterministic,
unit-tested with synthetic signals. Optionally enable Apple voice processing
on the mic input if the builder confirms it does not degrade capture *(left to
builder, must be measured on a sample)*.

**A3 Word timestamps (pt 12).** Turn on WhisperKit `wordTimestamps` and keep
words in `TranscriptSegment.words`. Measure the speed cost on the benchmark
harness (`docs/transcription-benchmarks.md`); if > 15 % slower, make it a
setting default-on and report the number.

**A4 Whisper prompt + default model (pt 11).** Feed the top terminology terms
(canonical forms, ≤ 224 tokens, most frequently used first or list order) as
WhisperKit prompt tokens. Re-check the default model: change
`defaultWhisperModel` to the best model the benchmark doc supports on Apple
Silicon (expected `large-v3` turbo variant if available) *only* for new
installs; existing users keep their setting. Record the measured WER/speed
justification in the CHANGELOG.

**A5 Diarization (pt 3).** Add FluidAudio (Swift Package, Apache-2.0) and run
its offline diarizer after transcription on the system track (and on the mic
track when the meeting has no system audio, i.e. an in-room meeting). Map
clusters to word-level attribution from A2 (system words get a cluster
speakerID). Models download on first use like WhisperKit's, with progress and
a clear error; diarization failure never fails the pipeline (fall back to
"Others"). Setting: "Recognise speakers" default on. Licence of every model
file checked and listed in the CHANGELOG; avoid Sortformer unless its licence
is confirmed permissive.

**A6 Speaker naming (pt 4).** Transcript tab gets a speakers bar: each speaker
chip shows name, talk-time share, a ▶ button playing a ~5 s representative
clip from that speaker's track (new small `AudioClipPlayer` on
AVAudioPlayer), and rename (free text + calendar participants as suggestions).
After diarization, an LLM pass proposes names using participant list + the
first N minutes of transcript, returning `{speakerID, name|null, evidence}`;
names with evidence are shown as suggestions the user confirms (one tap), never
applied silently. Renaming re-renders the transcript (contract above). If a
summary exists, offer "Regenerate summary with names".

**A7 Voiceprints (pt 16), off by default.** Settings → Privacy: "Remember
voices (biometric data)" toggle, off, with an explanation and a link-free note
that a DPIA is required before use in an organisation. When on, a confirmed
speaker can be saved as a voice profile only after a per-person consent
checkbox ("This person gave explicit consent"). Store embedding centroids
locally, encrypted (CryptoKit AES-GCM, key in Keychain), with a list to view
and delete profiles. Matching (cosine ≥ threshold) only *suggests* a name.
Turning the toggle off deletes all profiles after confirmation.

## Track B — Summary and action items (points 5, 6, 7, 9, 10, 13)

**B1 Fact extraction always (pt 6).** Every summarization extracts facts. When
the transcript fits one pass, there is still **one** call: the summary prompt
additionally asks for a fenced ```json``` block with the structured facts and
action items after the markdown (no added latency). When it does not fit, the
map step (all providers; Claude gets a lower map-reduce threshold so meetings
over ~25k tokens are chunked against lost-in-the-middle) returns JSON facts per
chunk *(Claude's call, keeps latency flat for normal meetings)*. The map prompt returns JSON: decisions, commitments/action items
(per `ExtractedActionItem`, owner only on explicit evidence: a named
assignment, a first-person commitment by a known speaker, or the user's notes),
open questions, notable facts — each with `[mm:ss]`. Speaker labels in the
transcript are explicitly allowed as owner evidence for first-person
commitments ("ik pak dat op" by `Youri:`). The reduce step writes the summary
from the facts with the user's template (unchanged output format) and gets the
de-duplicated action item list. Relative dates ("vrijdag") resolve against the
meeting date. Invalid JSON → one repair retry → fall back to today's markdown
path with a warning. 

**B2 Structured action items (pt 5).** Action items come from B1's JSON, not
from parsing the summary. The summary's `## Action Items` section is rendered
*from* the structured list (`- **owner** — task (due) [mm:ss]`) so
`SummaryResponseParser`, exports and `ActionItemOwnership` stay compatible.
All items (also other people's) are stored on the meeting; to-dos are created
for the user's own (and unassigned if the setting says so) as `.proposed`.

**B3 Verification pass (pt 7).** One LLM call verifies every action item and
decision against its quote and the surrounding transcript window (±60 s),
returning supported/unsupported + reason. Unsupported items are kept but
flagged (shown with a warning badge, never auto-accepted). Deterministic
pre-check: the quote must occur (normalised, fuzzy ≥ 0.85) in the transcript;
if not, the item is unsupported without an LLM call.

**B4 Prompt context (pt 9).** Pass prep notes (`localPrepNotes` / Obsidian prep
file content already loaded by `MeetingPrepService`) and user notes as "What
the user cares about" ahead of the transcript; mark the user in the
participant list (`(me)`), and include attendee e-mails when available from
EventKit. Budget-aware: prep/notes are trimmed before the transcript is.

**B5 Templates per meeting type (pt 10).** Built-in templates: General
(today's), 1:1/bilateral, Stand-up, Refinement/planning, External/partner,
Workshop. Auto-select by title/attendee heuristics (e.g. "bila", "1-op-1",
2 attendees → 1:1; "daily", "standup" → stand-up; external domains →
External), overridable per meeting; user can edit/add templates in Settings
(today's single template becomes the editable "General"). "Regenerate with…"
menu on the summary tab. Stored as JSON in UserDefaults *(Claude's call)*; the
meeting stores the chosen template id (field in V3).

**B6 To-do approval (pt 13).** Proposed to-dos live only in SwiftData
(`status = .proposed`, no `sourceFilePath`) and are written to the Obsidian
meeting file / Apple Notes only on Accept, so the vault sync (which deletes
rows missing from the file, `ObsidianTodoSyncService.swift:417-430`) only ever
sees accepted rows; the sync must skip non-accepted rows. Accepted lines carry
owner/due/timestamp as text in the markdown line (`- [ ] task — owner 📅
2026-11-07 [12:34]`, Obsidian Tasks-compatible due date) and `TaskLine`
parsing tolerates the suffix. Rejected items stay in SwiftData only.
**Regeneration** (template or names) replaces only pending `.proposed` items;
accepted and rejected items are kept and new items fuzzy-matching them
(≥ 0.85) are dropped; `actionItemsData` is overwritten *(Claude's calls)*.
 Proposed to-dos show in a review strip on the
summary tab and in the Todos view with quote, timestamp (clickable), owner,
due and a verification badge; actions Accept / Edit / Reject (bulk "Accept
all verified"). Only accepted to-dos sync to Obsidian / Apple Notes. Each
decision is appended to a local JSONL log
(`Application Support/Casablanca/feedback/todo-decisions.jsonl`: meeting id,
item, action, edit diff, verification) for evaluation (C1). Setting
"Auto-accept verified to-dos" default off *(Claude's call)*.

## Track C — Evaluation and cross-meeting Q&A (points 14, 15)

**C1 Evaluation set (pt 14).** `tools/eval/` (Python, stdlib only, run with
`python3 -I`): a gold-file format (`gold/<meeting>.json`: decisions, action
items with owner) and a script that reads a Casablanca export/JSON dump and
reports action-item precision/recall/owner accuracy and decision recall with
fuzzy matching. A `make-gold` helper drafts a gold file from an existing
meeting's structured items for Youri to correct (marked `"reviewed": false`;
the scorer warns on unreviewed gold). A debug menu item / CLI flag exports a
meeting's transcript + structured output as JSON for the scorer. The gold data
itself is Youri's to curate; ship 0 real gold files (privacy) and one
synthetic example.

**C2 Ask across meetings (pt 15).** New "Ask" view (sidebar entry): question
box with optional filters (date range, participant, tag). Retrieval: a new in-memory BM25
index (`MeetingSearchIndex` is plain substring search, so it is not reusable)
over summaries + structured items + transcript chunks, built lazily; top-k chunks within the provider budget;
answer with citations `[Meeting title, date, mm:ss]` that open the meeting at
that timestamp. Single-turn like `MeetingChatService`. No embeddings
*(Claude's call: keeps it local and dependency-free)*.

## Integration (after tracks): point 8 and wiring

**I1 Clickable timestamps (pt 8).** In summary, transcript, to-do review and
Ask answers, `[mm:ss]` / `[h:mm:ss]` renders as a link that scrolls the
transcript tab to that line and plays the mixed recording from there (shared
`AudioClipPlayer`, with a small transport bar in the transcript tab).
**I2** Speaker labels from Track A flow into Track B prompts and owner evidence;
renamed speakers trigger the "Regenerate summary" offer.

## Phasing and parallelism

1. **Phase 0 (sequential):** schema V3, shared value types, transcript-line
   parser/renderer, `AudioClipPlayer`, empty Settings sections/keys for every
   new setting (so tracks only fill their own section view files), pbxproj
   group entries. One commit set.
2. **Phase 1 (parallel, three worktrees from Phase 0):** Track A, Track B,
   Track C. Within a track, points are done one by one in the listed order.
   Tracks must not edit each other's files; shared files touched only in
   Phase 0 or Integration.
3. **Phase 2 (sequential):** merge tracks, Integration (I1, I2).
4. **Phase 3:** full `xcodebuild test` suite once, fix failures, final
   review, CHANGELOG. No push, no PR, no release without Youri's go.

## Testing

Per point: unit tests for the pure logic (attribution, bleed guard, segment
splitting, prompt rendering, JSON parsing/repair, verification pre-check,
template selection, BM25 retrieval, migration V2→V3 with an existing store
fixture). Only targeted test classes run during the build; the **full suite
runs once at the end** (Youri's instruction). Never call a live LLM in tests
(`StubLLMProvider`). UI changes get the in-app checks listed in
`project_casablanca-view-verification` memory (constraint-pass probe), and a
list of on-device checks for Youri: a Teams call with 3+ people, an in-room
meeting, renaming, regenerate with names, to-do approval, Ask.

## Left to the builder

Exact thresholds (energy ratio, bleed correlation, split duration, cosine
match), chunk sizes per provider within the stated bounds, UI layout details
within existing design components, FluidAudio API usage and model choice
(subject to licence), file layout of new types.
