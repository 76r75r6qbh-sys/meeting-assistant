# Casablanca Design Overhaul — Design Spec

**Date:** 2026-05-30
**Status:** Approved (design), pending implementation plan

## Context

Casablanca (the local-first macOS meeting assistant) already has a real design
foundation — semantic color tokens, an adaptive light/dark palette, a 4pt spacing
grid, native button-style wrappers, and spring animations (`Casablanca/Design/Theme.swift`,
`Casablanca/Design/DesignTokens.swift`). This is therefore a **refinement and HIG-compliance
pass, not a rebuild**.

The goal is **showcase quality**: a calmer, more mature, more polished Mac app that
could be judged alongside first-party software. Two things drive the work: (1) closing
concrete HIG gaps — chief among them an app-wide hardcoded accent color that ignores the
user's system setting — and (2) reducing visual/cognitive friction on the busiest screens.

Scope agreed with the user covers: the design language, sidebar/navigation, global search,
the recorded-meeting detail view, the live recording workspace, settings, and first-run
onboarding. The Approvals queue inherits the system-wide changes but is not separately
redesigned.

## Design Language — "Layered Material" (Direction C)

Modern native macOS (Sonoma/Tahoe) feel: translucent vibrancy, layered surfaces, gentle
depth. Everything below is the system every screen inherits. Dark mode is the primary
showcase appearance; all of it has a light-mode twin.

### Accent color (the headline HIG fix)
- **Replace the hardcoded indigo `#5B6EF5` (`accentPrimary`/`accentPrimaryHover`) with `Color.accentColor`** everywhere it drives interactive UI (primary buttons, selection highlights, focus rings, active nav, badges). The app must honor whatever accent the user chose in System Settings.
- Audit `Theme.swift` and all views for direct use of `accentPrimary`; route them through the system accent.

### Surface layers (depth via material, not borders)
- **L0** Window base
- **L1** Sidebar — vibrancy / translucent material
- **L2** Card — subtle top-down translucent gradient + 1px hairline
- **L3** Sheet / popover — `regularMaterial` with soft shadow
- Toolbar + sidebar use vibrancy materials; unified titlebar.

### State colors — calm & semantic
- Switch custom state hexes (`accentSuccess`, `accentWarning`, `accentDanger`, `accentSecondary`)
  to **Apple semantic system colors** (`.red`, `.green`, `.orange`, `.purple`), desaturated.
  They adapt to appearance and Increased Contrast automatically.
- **Color appears only to signal state, never as decoration.** Recording = system red with a
  soft glow; live/done = green; processing/AI = purple; warning = orange; idle/upcoming = gray.

### Typography (SF Pro, generous)
- Large title 22 semibold · section title 17 semibold · uppercase label 11 · body/transcript 13 at **1.6 line-height** · metadata 12 secondary.

### Radii, materials, motion
- Card radius **12**, controls **8**, pills **20** (softer than today's 8).
- Depth = 1px hairline + faint shadow; **glow reserved exclusively for the live recording state**.
- Keep existing `CasaAnimation` spring tokens; add subtle transitions on state change.
- Bump content padding up one step for more air.

## Screen-by-screen

### 1. Sidebar & Dashboard
- **Vibrancy sidebar.** Top-level nav (Dashboard / To-Dos / Approvals) with count badges;
  the Approvals badge uses the accent color.
- **Meeting list grouped by time buckets:** Upcoming → Today → This Week → This Month →
  This Year → Earlier (older years may break down by year). **Empty buckets are hidden.**
  - "This Week" = **calendar week**. **No separate "Yesterday" bucket.**
  - Future meetings live under "Upcoming"; past meetings fall into recency buckets.
  - Status dots per row (semantic state color).
- **Dashboard main area:** a day navigator (`‹ Today ›`), an **"Up next" hero** surfacing the
  single most actionable meeting with primary *Start Recording* + secondary *Take Notes*, then
  the day's remaining meetings as roomy layered cards with participant avatars and hover actions.
- **Toolbar** = a proper search field (`Search everything`, opens the global-search overlay — replaces the old tiny ambiguous glyph) + `＋ New Meeting`.

### 2. Global search (⌘F)
Replaces the sidebar mini-search with a single, more powerful search.
- Triggered by the toolbar search field or `⌘F`; opens a **Spotlight-style overlay** over
  a dimmed window (vibrancy material).
- **Searches across:** meeting titles, **summaries**, **transcripts**, freeform notes, to-dos,
  approvals, **and participants** (a dedicated "People" group; selecting a person can filter to
  their meetings).
- Results **grouped by source** with a count; summary/transcript hits show a **snippet with the
  matched term highlighted**.
- Fully keyboard-driven (`↑↓` navigate, `↵` open, `esc` close); selected row uses accent color.
- **Backend:** index over existing SwiftData meetings (title/summary/transcript/notes/participants)
  + the action-queue JSON. No new storage.

### 3. Recorded-meeting detail
- **Summary is the hero** in a single calm reading column. The AI summary sits in a subtly
  purple-tinted block (the one place that accent appears), followed by **Decisions / Action
  items / Risks & blockers / Follow-ups** as distinct styled sections.
  - **Parser change:** extend `SummaryResponseParser` (`Casablanca/Services/SummaryResponseParser.swift`)
    to split **all** `##` sections, not just Action Items. The LLM already emits these sections
    (`SummarizationService.swift:32-37`) — no new LLM work, no new data. Empty sections don't render.
  - Action-item checkboxes sync back to to-dos.
- **Transcript and Notes** move off the main canvas into a **segmented control**
  (`Summary · Transcript · Notes`); Summary is default.
- A macOS **inspector** (right, toggleable) holds the **audio player** (waveform + scrubber),
  **participants**, and **export status**. Toggling it off gives a focused full-width read.
- **Toolbar discipline:** one contextual primary action (Transcribe → Summarize → Export by
  state); secondary actions (Re-transcribe, Record again, Show in Finder, Delete) under `⋯`.

### 4. Live recording workspace
- **Always-visible, calm recording bar:** softly pulsing system-red glow dot, tabular-numeral
  timer, inline audio level meter. One clear primary action **`Stop & Process`** (`stop.fill`),
  Pause beside it (`pause.fill`; flips to `play.fill` + "Paused" when paused). Shortcuts:
  `⌘P` pause, `⌘⏎` stop.
- **Note surface is the hero** — a single **freeform** markdown editor.
- **Timestamped notes are removed entirely** (user never uses them):
  - Drop the `Timestamped/Freeform` picker and `TimestampedNotesHistorySection`.
  - Remove the `timestampedNotes` field and the `TimestampedNote` model (`Casablanca/Models/Meeting.swift`).
  - Remove the `{{timestamped_notes}}` token from the summary prompt (`SummarizationService.swift`)
    and the timestamped-notes assembly in `summarize()`.
  - Migration: existing meetings simply lose the (unused) field; verify SwiftData migration is clean.
- **Per-meeting device & language quick-control:** a compact chip in the recording bar
  (`🎙 <device> · <lang> ⌄`) opens a vibrancy popover to change **input device** (with a live
  level meter beside the selected one), toggle **system-audio capture**, and switch
  **transcription language** — without opening Settings. Footer link to "Recording defaults in
  Settings…". The same control appears in the pre-record state. Mid-recording language change
  re-tags from that point (matches existing in-recording language switch).
- **Focus mode** (polished `recordingWorkspaceFocusMode`): hides sidebar, Prep inspector, and
  toolbar chrome; centers notes at a comfortable measure; collapses recording state to a single
  pill (still pausable/stoppable). Toggle via button or `Esc`. View-state only — recording and
  autosave continue.
- **Prep inspector** (Obsidian prep notes): **drag-resizable** divider — highlights on hover,
  resize cursor, **min ~220pt, max 50% of window width**, width persisted via `@AppStorage`.
  `▣ Prep` toolbar toggle hides/shows it. Same resizable pattern applies to the detail inspector.

### 5. Freeform notes — formatting & appearance
- A **light markdown formatting toolbar** above the editor (B, I, heading, bullet, checklist,
  code, link) for discoverability; **markdown keyboard shortcuts still apply** (`- `, `# `, `⌘B`…).
- An **"Aa" popover** for layout/appearance: **text size** (3 steps) and **reading width**
  (Comfortable / Full width). Chosen value persists as default; also settable globally in
  Settings ▸ General.

### 6. Settings & first-run onboarding
- **Settings restructured System-Settings-style:** inset rounded groups with section labels
  instead of long flat forms; native toggles, disclosure rows, dropdowns.
- **New dedicated `Recording` tab** (input device, system-audio capture, default transcription
  language, Whisper model), split out from General/AI. Tabs: General · AI · Recording · Updates.
- **First-run onboarding** — 4 quick, skippable, re-runnable steps:
  1. Welcome (privacy reassurance: everything stays on your Mac)
  2. Vault & export destination (Obsidian path / Apple Notes)
  3. Permissions — mic / system audio / calendar, each with live granted status
  4. LLM check — detect a running provider ("we found Ollama running ✓")
  - Re-runnable from Settings.

### 7. Preparation mode (self-authored prep)
Today prep notes are read-only, synced from Obsidian. Add the ability to **author prep in-app**.
- **Entry:** a **`Prepare`** action on any upcoming meeting — dashboard "Up next" hero, meeting
  cards, and sidebar context menu.
- **Editor:** reuses the freeform markdown editor + formatting toolbar + `Aa` controls. Starts
  from an optional light **template (Goal · Agenda · Questions · Notes)** or blank.
- **Inspector:** calendar context — participants, event description/Teams link, links to
  related/prior meetings.
- **`✦ Draft with AI`** optional starting point (reuses the summarization LLM provider with a
  prep-oriented prompt); the user then edits. Manual authoring is the default.
- **Persistence:** save to the Obsidian vault as **`YYYY-MM-DD Meeting Name - Prep.md`** — the
  existing convention recognized by `MeetingPrepService` and Conductor's `- Prep` detection — so
  self-authored prep and morning-briefing AI prep share one location and both surface in the
  recording workspace's Prep inspector. **In local-only mode (no vault), store prep on the `Meeting`.**
  - This requires `MeetingPrepService` to gain **write** capability (it is currently read/sync only).
- **Top-right** keeps a primary **`Start Recording`** (flow straight from prep into the meeting) + **Done**.
- The recording workspace Prep inspector becomes **editable** (opens the same editor inline) rather
  than strictly read-only.

## Empty states, loading & feedback (cross-cutting)
- Replace bare `ProgressView`s with proper loading/skeleton states where content is being
  generated (transcription, summarization).
- Designed empty states for Dashboard (no meetings / no calendar access), To-Dos, Approvals,
  and search-no-results.
- Micro-feedback on state changes (approve, complete todo, export done) using subtle transitions.

## Out of scope
- Redesigning the Approvals queue UI beyond inheriting the new system (it keeps its current
  structure; benefits from accent/material/state-color changes).
- Changing recording/transcription/summarization/export **logic** (only the timestamped-notes
  removal and summary-section parsing touch service code).
- New LLM prompts or providers.

## Verification
- **Accent compliance:** change System Settings ▸ Appearance ▸ Accent color (e.g. to Pink, then
  Graphite) and confirm primary buttons, selection, focus rings, and badges all follow; grep
  confirms no remaining direct `accentPrimary` usage for interactive UI.
- **Light/dark:** toggle appearance; confirm all surfaces, materials, and state colors adapt.
- **Increased Contrast & Reduce Motion:** enable both; confirm state colors remain legible and
  the recording pulse/animations respect Reduce Motion.
- **Sidebar buckets:** seed meetings across today/this week/this month/this year + future;
  confirm correct calendar-week bucketing, hidden empty buckets, no "Yesterday" group.
- **Global search:** search a term present in a summary, a transcript, and a participant name;
  confirm grouped results, highlighted snippets, People group, and keyboard nav.
- **Detail sections:** summarize a meeting whose LLM output includes Decisions/Risks/Follow-ups;
  confirm each renders as its own block and empty sections are omitted; checkbox→todo sync works.
- **Timestamped notes removal:** build passes with the model/field/UI removed; existing meetings
  open without error (SwiftData migration clean); summary still generates from freeform notes +
  transcript.
- **Recording quick-controls:** change device and language from the bar popover mid-recording;
  confirm the live meter reflects the selected device and language change re-tags subsequent audio.
- **Resizable prep:** drag the divider to its max and confirm it stops at 50% of window width and
  the width persists across relaunch; `▣ Prep` toggle hides/shows.
- **Focus mode:** enter focus while recording; confirm chrome hides, pill remains, recording +
  autosave continue, `Esc` exits.
- **Onboarding:** reset first-run state; walk all 4 steps; confirm permission statuses are live
  and the flow is skippable and re-runnable from Settings.
- **Preparation mode:** open `Prepare` on an upcoming meeting; write prep from the template;
  confirm it saves to the vault as `YYYY-MM-DD Meeting Name - Prep.md` and re-opens with the
  content; confirm it then shows in the recording workspace Prep inspector; in local-only mode
  confirm it stores on the `Meeting`; confirm `✦ Draft with AI` produces an editable draft.
- Run the existing test suite (`CasablancaTests/`); update `SummaryResponseParser` and
  Meeting-model tests for the parser change and timestamped-notes removal.

## Key files
- `Casablanca/Design/Theme.swift`, `Casablanca/Design/DesignTokens.swift` — tokens, accent, materials
- `Casablanca/Views/SidebarView.swift`, `DashboardView.swift`, `MeetingCardView.swift`
- `Casablanca/Views/RecordedMeetingView.swift` — segmented detail + inspector
- `Casablanca/Views/NotesEditorView.swift` — recording bar, freeform-only notes, focus, quick-controls, resizable prep
- `Casablanca/Views/Components/MarkdownTextEditor.swift` — formatting toolbar + Aa
- `Casablanca/Views/SettingsView.swift` — grouped settings + new Recording tab
- `Casablanca/Services/SummaryResponseParser.swift`, `SummarizationService.swift` — section parsing, prompt token
- `Casablanca/Models/Meeting.swift` — remove `timestampedNotes` / `TimestampedNote`
- `Casablanca/Services/MeetingPrepService.swift` — add **write** capability for self-authored prep
- New: global search overlay view + index; first-run onboarding flow; **preparation-mode editor view**
