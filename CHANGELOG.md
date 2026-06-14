# Changelog

All notable changes to Casablanca are documented here. This project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
