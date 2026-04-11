# Manual Notes Before Recording Design

## Goal

Allow users to start a meeting in notes-only mode without recording, for both manual and calendar meetings, while preserving an easy path to start recording later without losing manually entered notes.

## Product Decisions

- Calendar meeting surfaces show both `Start Recording` and `Take Notes` actions directly.
- Manual meeting entry points created from app commands and menu bar shortcuts open directly into notes-only mode.
- When a user is already in notes-only mode and starts recording, the same screen stays visible.
- Existing freeform notes remain visible and intact while recording starts and after recording becomes active.

## Current Context

- `MeetingListViewModel` already supports `beginNotes(for:)`, `beginRecording(for:)`, and `beginManualMeeting()`.
- `Meeting.status` already includes `.notesOnly` and `.recording`.
- `NotesEditorView` currently handles freeform notes and export in the notes-only flow.
- `RecordingView` currently owns live recording UI, timer/audio state display, timestamped note capture, and recording error handling.
- `ContentView` currently routes `.notesOnly` to `NotesEditorView` and `.recording` to `RecordingView`, which assumes recording always owns a separate screen.

## Proposed Architecture

Use a single live meeting workspace for both notes-only and active recording instead of switching between two different detail experiences.

`NotesEditorView` becomes the primary meeting workspace. It continues to render the freeform notes editor in notes-only mode, and it also gains the ability to show live recording controls when recording is being prepared or is already active. Starting a recording from that screen should not navigate away or rebuild the editor around a new state object.

`Meeting.status` remains the persisted source of truth for meeting history and sidebar labels, but the detail UI no longer assumes that `.recording` implies a dedicated `RecordingView` screen. Recording becomes a capability layered on top of the same meeting workspace the user already occupies.

## UI Design

### Entry Points

- `MeetingCardView` shows both `Start Recording` and `Take Notes` actions directly for calendar meetings.
- `DashboardView` continues to pass through both actions to meeting cards.
- Menu bar and app-command manual meeting entry still create a new meeting and open notes-only mode immediately.

### Meeting Workspace

The notes workspace should support three visual states:

1. `Notes only`
   - Freeform notes editor
   - Export/save actions
   - `Start Recording` action visible

2. `Preparing recording`
   - Same freeform notes editor remains visible
   - Recording header/footer appears with loading/progress state
   - Recording start errors are surfaced without leaving the screen

3. `Recording active`
   - Freeform notes editor remains visible
   - Recording status, timer, audio meter, and stop control are visible
   - Timestamped note capture/list is available inline

The essential behavior is that freeform notes remain on screen before, during, and after recording start. The user should not experience a route transition just because recording began.

## Component Changes

### `MeetingCardView`

- Add a second visible action for `Take Notes` next to `Start Recording`.
- Keep existing context-menu actions aligned with the visible actions.

### `DashboardView`

- No structural change beyond supporting the updated `MeetingCardView` action layout.

### `MenuBarMeetingView`

- Calendar meeting quick-access UI should expose both `Start Recording` and `Take Notes` directly.
- Manual meeting shortcut remains notes-first.

### `NotesEditorView`

- Become the main meeting workspace for both notes-only and active-recording states.
- Accept recording service dependencies and callbacks currently owned by `RecordingView`.
- Render recording status/header/footer conditionally when this meeting is being prepared or actively recorded.
- Render timestamped notes UI conditionally when recording is active.
- Preserve the current markdown freeform notes editor and export behavior.

### `RecordingView`

There are two acceptable implementation directions:

- Remove `RecordingView` entirely and fold its reusable pieces into `NotesEditorView`.
- Or reduce `RecordingView` into extracted helper subviews/functions that `NotesEditorView` reuses.

The implementation should choose the option with the smallest, clearest diff, but the product behavior must be the same either way.

### `ContentView`

- Stop routing `.recording` meetings to a separate recording-only screen.
- Route both `.notesOnly` and `.recording` meetings into the unified notes workspace.
- Preserve existing `.processing` and `.completed` behavior.

## Data Flow

### Starting Notes

1. User clicks `Take Notes` on a calendar meeting, or creates a new manual meeting.
2. `MeetingListViewModel` sets the meeting status to `.notesOnly` and selects that meeting.
3. The unified notes workspace opens with the freeform notes editor.

### Starting Recording From Notes

1. User clicks `Start Recording` from inside the notes workspace.
2. The same meeting remains selected.
3. `AudioRecordingService.startRecording(for:)` is invoked for that meeting.
4. The view shows recording preparation state inline.
5. On success:
   - `meeting.status` becomes `.recording`
   - recording controls remain inside the same workspace
   - existing `meeting.userNotes` remain unchanged
6. On failure:
   - the meeting remains usable in notes mode
   - the user’s typed notes remain unchanged
   - existing retry/privacy actions are shown inline

### Starting Recording Directly

1. User clicks `Start Recording` from a calendar meeting entry point.
2. The app selects that meeting and opens the same unified workspace in recording-preparation state.
3. On success, the workspace transitions into active recording state without changing screens.

## Error Handling

- Recording start failures must not clear or reset freeform notes.
- If microphone or system-audio permissions block recording, the user remains in the notes workspace and can continue typing.
- If another recording is already active for a different meeting, the current workspace remains stable and the existing conflict error is surfaced.
- Choosing to back out of a failed recording attempt should leave the meeting in `.notesOnly`.

## Testing Strategy

### View Model Tests

- Starting notes for a meeting sets `.notesOnly` and selects the meeting.
- Starting recording for a meeting sets `.recording` and selects the same meeting.
- Manual meeting creation still opens notes-only mode by default.

### View / Integration Tests

- Calendar meeting surfaces render both `Start Recording` and `Take Notes`.
- Manual notes entered in the unified workspace remain present after triggering recording start.
- Recording start errors leave the meeting usable in notes-only mode.
- Manual meeting command/menu entry opens notes-only mode directly.

### Regression Focus

- No note loss when transitioning from notes-only to recording.
- No accidental route change from the unified workspace into a separate recording screen.
- No regressions to `.processing` and `.completed` detail routes.

## Out of Scope

- Changing completed-meeting playback/transcription/export flows.
- Redesigning the sidebar or meeting history model.
- Adding new persisted note fields beyond existing `userNotes` and `timestampedNotes`.
