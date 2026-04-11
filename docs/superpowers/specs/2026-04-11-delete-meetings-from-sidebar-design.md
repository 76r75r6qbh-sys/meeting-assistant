# Delete Meetings From Sidebar Design

## Goal

Allow users to delete any recent meeting directly from the left sidebar. Deleting a meeting removes the `Meeting` record itself from the app, along with all associated notes, transcript, summary, to-dos, and any saved recording file on disk.

## Product Decisions

- The delete entry point lives in the recent meetings list in the left sidebar.
- The action applies to any recent meeting shown there, not just meetings with recordings.
- Deletion removes the meeting record itself from the app rather than leaving an empty shell.
- Deletion requires an explicit confirmation step.

## Current Context

- `SidebarView` renders recent meetings using `SidebarMeetingRow`.
- Recent meetings already exclude `.upcoming` meetings via `MeetingListViewModel.filteredRecentMeetings(from:)`.
- `Meeting` owns related to-dos with `@Relationship(deleteRule: .cascade)`, so deleting the meeting already removes to-dos from persistence.
- Recorded-meeting data is stored on the `Meeting` model itself (`userNotes`, `timestampedNotes`, `transcript`, `summary`, `recordingFileURL`, `recordingDuration`).
- `ContentView` and `MeetingListViewModel.selectedMeeting` already control fallback navigation when the current meeting changes.

## Proposed Architecture

Add a sidebar-owned destructive action for recent meetings. The action removes the `Meeting` from SwiftData and also deletes the saved recording file from disk when one exists.

The deletion logic should live in `MeetingListViewModel` so the sidebar row stays presentational and selection cleanup happens in one place. The view model becomes the coordinator for:

1. resolving the recording file URL from `meeting.recordingFileURL`
2. removing the file if it exists
3. deleting the `Meeting` from `ModelContext`
4. clearing sidebar selection when the deleted meeting is currently selected
5. saving the model context

Because the meeting model stores transcript, summary, notes, and recording metadata directly, and to-dos cascade from the meeting, deleting the meeting removes the full record for that meeting in one operation.

## UI Design

### Sidebar Entry Point

Each recent meeting row in the left sidebar gets a context menu action:

- `Delete Meeting…`

This action should not be shown for upcoming meetings because they do not appear in the recent meetings section.

### Confirmation Flow

Triggering the delete action opens a confirmation dialog or alert that:

- names the meeting being deleted
- clearly states that the meeting and all stored data will be removed
- states that any saved recording file will also be deleted

Suggested confirmation language:

> Delete “{Meeting Title}”?
> This removes the meeting, notes, transcript, summary, to-dos, and saved recording from Casablanca.

## Component Changes

### `SidebarView` / `SidebarMeetingRow`

- Add a context menu entry for `Delete Meeting…` on recent-meeting rows.
- Wire that action to a parent-owned confirmation state rather than deleting directly in the row.

### `MeetingListViewModel`

- Add a deletion API such as `deleteMeeting(_ meeting: Meeting) throws`.
- Handle recording file deletion, model deletion, selection cleanup, and save orchestration here.

### `ContentView`

- No major routing change expected, but selection fallback must remain correct when a selected meeting is removed.

## Data Flow

1. User right-clicks a recent meeting in the sidebar.
2. User selects `Delete Meeting…`.
3. App presents confirmation dialog.
4. If confirmed:
   - determine whether a recording file path exists
   - if the file exists, delete it from disk
   - delete the `Meeting` from SwiftData
   - clear sidebar selection if the deleted meeting was selected
   - save the context
5. App falls back to the dashboard if the deleted meeting was open in the detail pane.

## Error Handling

- If the meeting has no recording file, deletion still succeeds.
- If the meeting has a recording path but the file is already missing, deletion still succeeds.
- If file deletion fails for another reason, the app should stop the delete operation, keep the meeting in the app, and surface an error message.
- The app must avoid half-deleted state where the meeting is removed from SwiftData but the UI claims the file removal failed afterward.

## Testing Strategy

### View Model Tests

- Deleting a meeting removes it from SwiftData persistence.
- Deleting a selected meeting clears selection back to dashboard.
- Deleting a meeting with no recording succeeds.
- Deleting a meeting whose recording path points to a missing file succeeds.

### View / Integration Tests

- Sidebar recent-meeting rows expose `Delete Meeting…`.
- Upcoming meetings do not receive that action via the recent-meeting sidebar path.
- Confirmation text reflects destructive scope.

## Out of Scope

- Bulk deletion of multiple meetings.
- Trash/undo support.
- Deleting upcoming meetings from calendar-based views.
- A separate “remove recording only” action that preserves the meeting record.
