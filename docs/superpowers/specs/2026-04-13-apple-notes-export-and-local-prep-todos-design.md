# Apple Notes Export And Local Prep/Todos Design

## Goal

Add a user-selectable export destination so meeting notes can be exported to Apple Notes instead of Obsidian, while also making prep/todo storage independently selectable as either Obsidian-backed or app-local.

## Scope

- Add `Export destination` preference with `Obsidian` and `Apple Notes`.
- Add `Prep/todo storage` preference with `Obsidian` and `Local`.
- Preserve current Obsidian behavior exactly when Obsidian is selected.
- Export to Apple Notes only when `Export destination = Apple Notes`.
- Keep prep/todo behavior filesystem-backed only in Obsidian mode.
- Keep prep/todo behavior fully inside Casablanca's local SwiftData model in Local mode.

## Non-Goals

- No Apple Notes integration for prep files.
- No Apple Notes integration for todos.
- No redesign of the meeting workspace UI beyond settings copy and export messaging.
- No broad storage-backend abstraction for unrelated meeting data.

## Current State

- `ExportService` writes two markdown files into an Obsidian vault under `meeting notes/`.
- `MeetingPrepService` reads `- Prep.md` files from the Obsidian meeting notes directory.
- `ObsidianTodoSyncService` treats markdown files in the vault as the source of truth for meeting and generic todos.
- `TodoItem` and `Meeting` data already exist in SwiftData, so the app already has local persistence for notes and todos.

## Requirements

### Preferences

- Settings must expose two independent choices:
  - `Export destination`: `Obsidian` or `Apple Notes`
  - `Prep/todo storage`: `Obsidian` or `Local`
- Existing users should continue to behave as they do now after upgrading.
- The Obsidian vault path remains configurable and required only for Obsidian-backed features.

### Obsidian Compatibility

- If `Export destination = Obsidian`, raw notes and summary export must behave exactly as they do today.
- If `Prep/todo storage = Obsidian`, prep lookup and todo sync must behave exactly as they do today.
- Existing filenames, directory names, markdown structure, links, and automatic export flow must remain unchanged in Obsidian mode.

### Apple Notes Export

- If `Export destination = Apple Notes`, Casablanca exports meeting content into Apple Notes instead of Obsidian files.
- Apple Notes export creates two notes per meeting in a dedicated Apple Notes folder named `Casablanca`:
  - `YYYY-MM-DD Meeting Title`
  - `YYYY-MM-DD Meeting Title - Notes`
- The summary note should contain the same user-facing content as the current Obsidian summary export.
- The raw notes note should contain the same user-facing content as the current Obsidian raw notes export.
- Export should be deterministic so repeat exports target the same notes rather than producing avoidable duplicates.
- Automatic export and manual export must both use the selected export destination.

### Local Prep/Todos

- If `Prep/todo storage = Local`, Casablanca must not read prep markdown from Obsidian.
- If `Prep/todo storage = Local`, Casablanca must not sync todos to or from Obsidian markdown.
- The prep pane should simply show no prep content in Local mode.
- Meeting todos and generic todos should continue to work through SwiftData only in Local mode.
- Local mode must not require an Obsidian vault path.

## Proposed Architecture

### Preference Model

Add two enum-backed app preferences:

- `ExportDestination`
  - `.obsidian`
  - `.appleNotes`
- `PrepTodoStorage`
  - `.obsidian`
  - `.local`

These preferences are independent. Supported combinations include:

- Obsidian export + Obsidian prep/todos
- Apple Notes export + Obsidian prep/todos
- Obsidian export + Local prep/todos
- Apple Notes export + Local prep/todos

### Export Routing

Keep `ExportService` as the orchestration entry point, but move destination-specific write behavior behind a small exporter boundary.

Responsibilities:

- `ExportService`
  - decides whether export should run
  - prepares meeting content
  - routes to the selected exporter
  - returns a destination-aware export result for UI messaging
- `ObsidianMeetingExporter`
  - preserves the current markdown file export logic
- `AppleNotesMeetingExporter`
  - creates or updates the two Apple Notes entries in folder `Casablanca`

The routing boundary should be narrow. Views should continue calling `ExportService` and should not know how notes are written.

### Apple Notes Writer

Implement Apple Notes export through AppleScript executed from the app, most likely through `osascript`.

The Apple Notes writer must:

- ensure a folder named `Casablanca` exists
- find existing notes by deterministic title inside that folder
- create notes when missing
- replace note body contents on re-export so exported content stays current

The exported note bodies can reuse the existing markdown-rendering content as plain text or lightly formatted text. The core requirement is preserving the same meeting information and note split, not preserving Obsidian wikilinks or YAML frontmatter semantics.

### Prep/Todo Routing

Keep prep/todo storage routing separate from export routing.

- In `Obsidian` mode:
  - `MeetingPrepService` keeps reading from Obsidian meeting note files
  - `ObsidianTodoSyncService` remains active
- In `Local` mode:
  - prep reads return no prep
  - todo creation and completion update SwiftData only
  - startup refresh and per-meeting refresh skip Obsidian sync

This avoids forcing Apple Notes into workflows that fundamentally depend on editable markdown files.

## Data Flow

### Export Flow

1. User edits meeting notes, transcript, summary, and todos in Casablanca.
2. Casablanca saves app state locally as it does today.
3. Manual export and automatic export both call `ExportService`.
4. `ExportService` reads `ExportDestination`.
5. If destination is Obsidian:
   - write the existing markdown files exactly as today
6. If destination is Apple Notes:
   - upsert the summary note
   - upsert the raw notes note
7. UI shows destination-appropriate success or failure messaging.

### Prep Flow

1. Notes workspace requests prep content for the active meeting.
2. Casablanca reads `PrepTodoStorage`.
3. If storage is Obsidian:
   - resolve prep markdown path and read it as today
4. If storage is Local:
   - return `nil`
5. Notes UI falls back to the existing full-width workspace when no prep is available.

### Todo Flow

1. User adds or completes a todo from meeting or global todo UI.
2. Casablanca reads `PrepTodoStorage`.
3. If storage is Obsidian:
   - keep current sync behavior, including markdown updates and refresh
4. If storage is Local:
   - create or update only the local `TodoItem`
   - do not touch the filesystem

## UI Changes

### Settings

- Replace the single Obsidian-only automation wording with destination-aware wording.
- Keep Obsidian vault controls visible because they are still needed in Obsidian export mode or Obsidian prep/todo mode.
- Clarify in helper text:
  - Obsidian vault path is only required for Obsidian-backed export or prep/todo storage
  - Apple Notes export writes to the `Casablanca` folder in Apple Notes
  - Local prep/todo storage keeps prep disabled and stores todos only inside Casablanca

### Export Messaging

- Manual export success text should mention the active destination:
  - Obsidian: existing folder/file wording
  - Apple Notes: saved to Apple Notes folder `Casablanca`
- Automatic export status text should no longer hard-code Obsidian in the UI copy.

## Error Handling

### Obsidian Mode

- Preserve current errors and behavior.
- Missing vault path should still fail export in Obsidian export mode.
- Obsidian automatic export failures should remain non-blocking.

### Apple Notes Mode

- If Apple Notes scripting fails, surface a normal export failure to the user for manual export.
- Automatic export failures should remain non-blocking and only log/report the failure path used today.
- If the `Casablanca` folder does not exist, create it automatically.
- If a note already exists, update it rather than silently creating an additional duplicate with the same title whenever practical.

### Local Prep/Todo Mode

- Missing vault path should not affect prep or todo behavior.
- Prep should quietly appear unavailable.
- Todo actions should continue working because SwiftData remains the local source of truth.

## Testing Strategy

### Export Routing

- Add tests that verify `ExportService` routes to the correct exporter based on `ExportDestination`.
- Preserve or add tests proving Obsidian export output is byte-for-byte compatible with current expectations where practical.
- Add tests for Apple Notes exporter request construction at the boundary that can be exercised without requiring the real Notes app in unit tests.

### Prep Routing

- Add tests verifying prep loads in Obsidian mode when files exist.
- Add tests verifying prep returns `nil` in Local mode even when an Obsidian vault path exists.

### Todo Routing

- Add tests verifying Local mode creates and completes todos without requiring source markdown files.
- Preserve existing Obsidian todo sync tests for Obsidian mode.

### UI/Preference Coverage

- Add focused tests for new preference defaults and any presentation logic that changes visible export messaging.
- Ensure the no-regression path for Obsidian mode is covered explicitly.

## File-Level Change Plan

- `Casablanca/Models/Meeting.swift`
  - add new preference keys and enum raw values
- `Casablanca/Views/SettingsView.swift`
  - add destination/storage pickers and update helper text
- `Casablanca/Services/ExportService.swift`
  - route export through destination-specific writer
- `Casablanca/Services/ObsidianMeetingFiles.swift`
  - keep current Obsidian path logic unchanged except for any small compatibility extraction needed
- `Casablanca/Services/MeetingPrepService.swift`
  - gate prep loading on `PrepTodoStorage`
- `Casablanca/Services/ObsidianTodoSyncService.swift`
  - either gate behavior internally or move call sites behind a storage-mode-aware facade
- `Casablanca/Views/TodosView.swift`
  - avoid forced Obsidian sync in Local mode
- `Casablanca/Views/NotesEditorView.swift`
  - route meeting todo actions and export success messaging through destination/storage-aware services
- `Casablanca/Views/RecordedMeetingView.swift`
  - route todo actions and export success messaging through destination/storage-aware services
- `Casablanca/Views/TranscriptionView.swift`
  - update automation copy to be destination-aware
- `CasablancaTests/*`
  - extend existing export, prep, todo, and workflow tests for the new preference matrix

## Open Decisions Resolved

- Apple Notes export is opt-in through `Export destination`.
- Apple Notes export creates two notes, not one.
- Prep/todo storage is independent from export destination.
- Local prep/todo storage means no external markdown files; data remains inside Casablanca only.
- Obsidian mode is a strict compatibility path where behavior must not change.
