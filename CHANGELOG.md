# Changelog

All notable changes to Casablanca are documented here. This project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.13.0] — 2026-07-16

Much better meeting summaries: a richer "Pocket-style" default prompt and working action-item extraction for Dutch meetings.

### Changed

- **New default summary prompt (Pocket-style).** Summaries are now written in the language of the transcript and structured as a short lead summary, 2–5 thematic sections, an optional chronological **Planning** section, and an optional personnel section, followed by the fixed closing sections (Decisions / Action Items / Risks and Blockers / Follow-ups — or their Dutch equivalents). Action items are owner-tagged (`- **Wesley** — …`), decisions include their stated rationale, and the model is instructed to correct speech-recognition mistranscriptions of names using the terminology and participants lists — and to never comment on transcript quality in the notes. **Note:** if you customized the prompt template in Settings, reset it to the default to pick this up.
- **Participants are now injected into the summarization prompt** (`{{participants}}` template variable), so the model can attribute action items to the right people and correct misheard names.
- **Summary output limit raised from 2000 to 3500 tokens** (thinking off) so the richer structure doesn't get truncated — truncation used to eat the closing action-items section first.

### Fixed

- **Dutch summaries now produce to-dos.** The summary parser only recognized English section headers (`## Action Items`, `## Decisions`, …), so Dutch summaries (`## Actiepunten`, `## Besluiten`, `## Risico's en blockers`, `## Opvolging`) silently produced no extracted decisions, action items, risks, or follow-ups — and no meeting to-dos. The parser now accepts Dutch header aliases, both curly and straight apostrophes (`Risico’s`/`Risico's`), and trailing colons.

## [0.12.0] — 2026-06-25

Pause/resume correctness: a lost display now pauses the recording (instead of silently going microphone-only), and resuming continues the timer instead of resetting it.

### Changed

- **Losing the display auto-pauses the recording.** When no display is available to ScreenCaptureKit (lid closed with no external monitor), the recording now cleanly **auto-pauses** rather than continuing microphone-only (the v0.11.0 behavior). It auto-resumes when a display returns (within the auto-resume window; otherwise it stays paused for a manual resume). Detection uses the *online* display list, so an idle screen that merely went to sleep (lid open) does **not** pause a running recording. The lid-close path raises both screen-lock and display-unavailable interruptions; resume is guarded so it never deadlocks if the screen-parameters notification doesn't re-fire on wake.

### Fixed

- **Resume no longer resets the timer to 00:00.** The elapsed-time display now continues from the total already recorded across earlier segments when a paused recording resumes (and the paused display shows the cumulative total), instead of restarting from the new segment.

### Verify on device

- The display-loss auto-pause depends on macOS reporting the built-in display as offline when the lid closes and posting a screen-parameters change. Confirm on real hardware: start a recording, close the lid (no external monitor) → recording pauses; reopen → it resumes and the timer continues. Clamshell with an external display should keep recording without pausing.

## [0.11.0] — 2026-06-25

More recording resilience: closing the laptop lid no longer fails the recording outright.

### Fixed

- **Recording continues (microphone-only) when system audio can't be captured.** System audio is captured via ScreenCaptureKit, which streams off a *display*; a closed lid with no external monitor has no capturable display, so the stream failed to start with "Geen beeldschermen of vensters gevonden om op te nemen" / "no displays or windows found to record" — and that error aborted the whole recording, resetting the timer to 00:00. The session now degrades to microphone-only instead of failing: the recording (and timer) keep running, and a non-fatal notification tells you system audio is unavailable (so you know remote meeting audio may be missing). System audio recovers automatically on the next resume once a display is available again.

### Known follow-ups (not in this release)

- A system-audio stream that dies **mid-recording** (e.g. undocking an external display partway through) still stops the recording rather than degrading to microphone-only — same root cause as the lid-closed case, different timing.
- No power assertion is held, so a Mac that actually sleeps on lid-close (no clamshell/external display) still captures nothing while asleep.

## [0.10.0] — 2026-06-23

Recording resilience: an interruption that tears down the audio device mid-recording (most commonly closing the laptop lid / system sleep) no longer discards the entire recording.

### Fixed

- **Recording no longer lost when the input device disappears mid-session.** When the machine slept or the capture device went away, ScreenCaptureKit had usually already torn the `SCStream` down, so `RecordingSession.stop()`'s `stopCapture()` threw — and that throw aborted teardown *before* the microphone track was drained, closed, and mixed down. The microphone audio that had been streaming to disk the whole meeting was orphaned and then deleted by the resume store. Stopping the system-audio stream is now best-effort: a stop failure is logged and the captured tracks are still finalized into the output file. (Known narrower gap, tracked separately: a genuine `render()` I/O failure during an interrupt can still drop that segment.)

### Internal

- Extracted a `SystemAudioCapturing` protocol and a headless teardown test seam; added `RecordingSessionTeardownResilienceTests` (fails against the pre-fix teardown, passes after).

## [0.9.0] — 2026-06-14

A focused release turning the approvals inbox into a first-class surface: the action queue now groups by bucket, renders a bespoke editable card per item type, folds paired ticket+response drafts into one composite, and shows a live open-approvals badge on the Dock and menu bar. Built against the new bucket-based `action-queue.json` schema (see `action-queue-schema.md`).

### Added

- **Bucket-based action queue** — the queue decodes four new fields (`bucket`, `attachments`, `externalRef`, `linkedItemIds`) and two new draft types (`calendar`, `topdesk`). Unknown buckets/values round-trip verbatim; missing fields never fail to load.
- **Bespoke approval cards per bucket** — email-shaped partner-API replies (To/Cc chips, attachment "Reveal in Finder"), Jira ticket drafts (field chips, custom-fields table with Release-notes-radio call-out, Jira-markup-rendered description), Topdesk responses (visibility toggle, Jira-link chip), refinement-prep (current→proposed radio/priority compare with editable dropdowns and flag pills), roadmap commitments (Teams excerpt + nested ticket), and calendar events. Every card edits in place and round-trips its changes back into the draft body; malformed bodies fall back to a plain-text editor so approval is never blocked.
- **Composite linked drafts** — a paired ticket + reply (linked via `linkedItemIds`) renders as one card with per-item Approve/Decline/Revise and a primary "Approve all".
- **Jira wiki-markup renderer** — bold/italic/headings/lists/links/code/tables render in card descriptions, degrading to literal text on anything unrecognized.
- **Bucket-grouped, collapsible list** — approvals group into fixed-order bucket sections with `(pending / total)` headers and per-bucket collapse state; duplicate items sharing an `externalRef` fold behind a `+N` indicator.
- **Open-approvals badge** — a live count of pending items on the Dock icon and the menu-bar item, recomputed on launch, on file changes, and after every in-app decision.

### Changed

- Approving a `todo`-bucket item now marks it complete in-app (status, decided/executed timestamps, and an execution result) instead of routing to a remote action.

## [0.8.2] — 2026-06-14

### Fixed

- Opening a past meeting in a narrow window no longer makes the sidebar jump out of sight. The layout is now responsive: a narrow window hides the meeting inspector (keeping the sidebar visible), and only a very small window gracefully collapses the sidebar — instead of `NavigationSplitView` silently dropping it.

## [0.8.1] — 2026-06-14

### Fixed

- Automatic pre-migration store backup — the meeting database is copied aside before every launch so an upgrade can never make data unrecoverable (the last 3 backups are kept).

### Changed

- Explicit, versioned SwiftData migration plan so schema upgrades are deterministic across macOS versions instead of relying on inference (which silently reset some v0.8.0 stores).

## [0.8.0] — 2026-06-14

A large quality + feature release: new meeting intelligence features, a reliability and performance pass across the recording → transcription → summary → export pipeline, an internal architecture cleanup, and broad UX polish.

### Added

- **Meeting tags** — label meetings, filter the sidebar by tag (OR semantics), search by tag, and export tags to Obsidian YAML frontmatter. A token-style tag editor lives in the meeting inspector with existing-tag suggestions.
- **Ask your meeting** — a grounded Q&A chat that answers questions about a single meeting using its transcript, summary, and notes via the local LLM. Disabled until there is content to ground on, and while a summary is still generating.
- **Auto-record prompt** — an optional local notification at a meeting's start time with a one-tap "Start Recording" action, plus a lead-time picker. Toggle in Settings → Recording → Notifications.
- **Recurring-series linking** — the prep view surfaces the previous occurrence's summary and open action items, with one-click carry-over into prep notes; the detail inspector links to the previous/next occurrence.
- **Unified processing-status card** — a single transcribe → summarize → export status surface with determinate transcription progress, elapsed-time summarization, per-stage Cancel, and error rows with Retry.
- **Native markdown editor (beta)** — an `NSTextView`-based editor with live markdown syntax styling and selection-aware formatting, behind a default-off Settings toggle ("Use native notes editor").
- **Undoable meeting deletion** — deleting a meeting shows an Undo toast for a grace period before the audio file and record are removed.
- **UX polish** — loading skeletons, transcript chapter grouping with a timestamp gutter, highlight-all in global search, reduce-motion support throughout, a `⌘⇧F` focus-mode shortcut, and a `.help()`/accessibility-label pass on icon buttons.
- **Release hygiene** — copyright string and a Credits.rtf About-panel attribution; graceful microphone-only recording when Screen Recording is denied, with clear onboarding copy.
- First-run onboarding flow, grouped Settings with a dedicated Recording tab, and a native `.inspector` workspace with Prep and To-Dos panels.

### Changed

- **Smaller recordings** — finished recordings are encoded to AAC/m4a after transcription (~5–8× smaller than WAV); a "Keep original WAV" setting preserves the uncompressed file.
- **Scales to thousands of meetings** — the sidebar uses a windowed partial fetch (transcripts kept off the hot path) and global search is debounced with database-side predicates plus a bounded in-memory transcript/participant scan. Global search now covers meeting summaries.
- **Event-driven calendar refresh** — replaced 5-minute polling with `EKEventStoreChanged` notifications (debounced) plus a long fallback timer.
- **Local-LLM resilience** — transcription frees the Whisper model before summarization; summarization runs in a navigation-independent background task with a visible retrying status and a thinking-mode toggle.
- **Internal architecture** — decomposed the recording engine, the live notes editor, and the meeting detail view into focused components; centralized logging via `os.Logger`. No user-facing behavior change from these refactors.

### Fixed

- **Recording finalize dropped the recording** — `RecordingSession.stop()` released the track writers before the facade read the captured-frame count, so every finished recording was discarded as "no audio samples were captured." The frame total is now cached before teardown.
- **Recurring-meeting occurrence collisions** — opening the Nth occurrence of a recurring event no longer returns the first occurrence's notes/transcript; occurrence start is matched at whole-second granularity to avoid duplicate rows.
- **Audio thread-safety** — replaced unsynchronized cross-thread state in the recording session with lock-guarded access; fixed a heap-corrupting data race in the interruption-coordinator tests.
- **Corrupt-store recovery** — a corrupt or incompatible data store is backed up and recreated instead of crashing on launch; user data is never deleted.
- **Action-queue robustness** — lenient, data-preserving decoding of the agent-shared `action-queue.json` (unknown enum values and malformed items are preserved on rewrite, including large-integer precision).
- **Apple Notes export** — a single-flight guard prevents a second AppleScript from running against Notes after a timeout.
- **Lifecycle** — background summarization is cancelled on quit; the action-queue file watcher uses a race-safe debounce.
- **Persistence** — `try?`-swallowed save failures now surface a user-visible alert.
- Focus-mode editor no longer renders blank (WKWebView height in a scroll container); summarizing UI is scoped to the meeting being processed; summary generation length is capped.

## [0.7.1]

- Calendar-driven meeting list, manual meetings, and the live meeting workspace
- Local recording (microphone + optional system audio), WhisperKit transcription, and local LLM summaries (Ollama / oMLX)
- Export to Obsidian (Markdown) or Apple Notes (HTML); optional Local-only mode
- Approvals inbox backed by a shared `action-queue.json`
- Stable team-based designated requirement so TCC permissions persist across rebuilds
