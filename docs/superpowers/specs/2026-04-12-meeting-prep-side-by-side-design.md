# Meeting Prep Side-by-Side Design

## Goal

When a meeting has an AI-generated preparation note in Obsidian, show that prep immediately inside the meeting workspace so the user can continue working from it without mixing prep content into their live notes.

## Product Decisions

- Matching prep files live in the Obsidian `meeting notes/` folder and use the existing naming convention: `YYYY-MM-DD Meeting Name - Prep.md`.
- When a matching prep file exists, the meeting workspace opens with a side-by-side layout:
  - read-only prep pane
  - editable live notes pane
- When no prep file exists, the live notes editor keeps the current full-width layout.
- The prep pane is collapsible, but it always starts expanded whenever the workspace opens.
- Prep content stays separate from `meeting.userNotes` and from the app's note exports.
- The prep pane must render Markdown correctly in read-only mode, including headings, lists, emphasis, links, blockquotes, and code blocks.

## Current Context

- `NotesEditorView` is already the unified workspace for notes-only and recording states.
- `Meeting.obsidianFileName` already produces the base filename used for Obsidian note exports.
- `ExportService` already knows how to resolve the configured Obsidian vault and the `meeting notes/` directory, but it only writes files.
- The app currently has no import/read path for prep notes from Obsidian.
- The existing freeform notes editor is backed by `meeting.userNotes` and should remain the source of truth for user-authored live notes.

## Proposed Architecture

Add a lightweight read path for meeting prep files without changing the persistence model.

### Prep Loading

- Introduce a small helper/service responsible for:
  - resolving the configured Obsidian vault path
  - locating `meeting notes/\(meeting.obsidianFileName) - Prep.md`
  - reading the file contents as UTF-8 Markdown text
- If the vault path is missing, the file is absent, or the file cannot be read, treat prep as unavailable and continue with the existing workspace.

### Workspace Integration

- `NotesEditorView` loads prep content when the selected meeting workspace appears and when the meeting identity changes.
- Prep content is held in local view state, not persisted onto `Meeting`.
- `Meeting`, `MeetingListViewModel`, and export data structures remain unchanged.

### Rendering Boundary

- The prep pane is strictly read-only.
- The live notes editor remains bound to `meeting.userNotes`.
- `Save & Export` continues to export only app-managed notes and must never overwrite the `- Prep.md` file.

## UI Design

### Freeform Workspace States

The freeform workspace supports three prep-related states:

1. `No prep available`
   - existing full-width live notes editor

2. `Prep available and expanded`
   - two-column layout
   - read-only prep pane on the left
   - editable live notes pane on the right

3. `Prep available and collapsed`
   - live notes editor returns to full width
   - a lightweight `Show Prep` control restores the split layout

### Prep Pane

- The prep pane includes a small header with:
  - a title such as `Preparation`
  - a collapse control
- The content body renders Markdown in read-only form.
- The rendered output should preserve normal document structure and remain easy to scan during a meeting.
- The prep pane should support text selection and scrolling independently from the live notes editor.

### Notes Pane

- The live notes pane keeps the current editable Markdown editor and save behavior.
- The current editor should not be prefilled with prep content.
- When the prep pane is collapsed or unavailable, the notes pane uses the full available width.

### Recording States

- In freeform mode during recording, keep the same prep-aware layout:
  - prep pane visible when expanded
  - notes editor beside it
- In timestamped-notes mode, keep the current timestamped recording UI and do not show the prep pane there.

## Data Flow

### Opening A Meeting Workspace

1. User opens a meeting in the workspace.
2. `NotesEditorView` resolves the expected prep file path from `meeting.obsidianFileName`.
3. If the prep file is found and readable:
   - load its Markdown text into local state
   - initialize the prep pane as expanded
4. If the prep file is missing or unreadable:
   - clear prep state
   - show the existing full-width notes editor

### Collapsing And Reopening Prep

1. User clicks the collapse control in the prep pane header.
2. The prep pane hides for the current workspace session.
3. The notes editor expands to full width.
4. User can click `Show Prep` to restore the split view.
5. Reopening the workspace starts expanded again whenever prep exists.

### Saving Notes

1. User edits live notes in the existing editor.
2. The app continues saving to `meeting.userNotes`.
3. Export continues writing the app-managed raw notes and summary files only.
4. The source `- Prep.md` file remains untouched.

## Error Handling

- Missing vault path: silently fall back to the normal full-width notes editor.
- Missing prep file: silently fall back to the normal full-width notes editor.
- Read failure or invalid encoding: silently fall back to the normal full-width notes editor.
- These cases should not block note-taking, recording, or exporting because prep is optional context.

## Testing Strategy

### Prep Reader Tests

- Resolves the expected `- Prep.md` path from a meeting.
- Returns prep Markdown when the file exists and is readable.
- Returns no prep when the vault path is missing.
- Returns no prep when the file does not exist.
- Returns no prep when reading fails.

### Workspace Presentation Tests

- Prep available -> workspace enters split-layout state with prep expanded.
- Prep collapsed -> notes editor uses full width and exposes `Show Prep`.
- No prep -> workspace uses existing full-width notes layout.
- Reopening a workspace with prep resets the pane to expanded.

### Regression Focus

- Live notes remain separate from prep content.
- Export output remains unchanged and does not overwrite `- Prep.md`.
- Existing recording and timestamped-note flows continue to work.
- Read-only prep Markdown renders with expected formatting rather than raw Markdown source.

## Out Of Scope

- Editing prep notes from inside the app.
- Syncing prep content into SwiftData.
- Changing the completed-meeting export model.
- Adding cross-file merge logic between prep and live notes.
