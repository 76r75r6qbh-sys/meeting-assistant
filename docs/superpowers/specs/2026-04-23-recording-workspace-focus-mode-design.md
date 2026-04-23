# Recording Workspace Focus Mode Design

## Goal

Let the user hide the recording header and audio settings while recording so the workspace can stay centered on prep and note-taking, without losing safe access to stop recording or restore the controls.

## Product Decisions

- Add a single focus-mode toggle for the recording workspace that hides the recording header and audio settings together.
- Keep a compact recording controls row visible while focus mode is active.
- The compact controls must still expose:
  - recording state
  - elapsed time
  - `Show Recording Controls`
  - `Stop Recording`
  - `Save & Export`
- Remember the user's focus-mode preference across recording workspaces.
- Apply focus mode only to the active recording workspace UI.
- Do not change notes-only, processing, completed, or recorded-meeting layouts.

## Current Context

- `NotesEditorView` already owns the unified workspace for notes-only and recording states.
- The freeform workspace already supports collapsing the prep pane while keeping notes and todos visible.
- The recording-specific header currently combines:
  - recording state indicator
  - elapsed timer
  - audio level meter
  - notes-mode picker
  - `Audio Settings` disclosure
- The footer already holds primary recording actions, including `Stop Recording` and `Save & Export`.
- `MeetingWorkspacePresentation` already centralizes most workspace visibility decisions and is covered by presentation tests in `MeetingStartFlowTests`.

## Proposed Architecture

Extend the existing workspace presentation model instead of introducing a new route, panel manager, or recording-specific container.

### Preference Storage

- Persist the recording focus-mode preference with `@AppStorage`.
- Store it as an app-wide preference rather than per meeting.
- Default to the current behavior, with focus mode off until the user enables it.

### Presentation Boundary

- Extend `MeetingWorkspacePresentation` with derived state for focused recording mode.
- Focus mode is active only when:
  - the meeting is in recording workspace state
  - the stored preference is enabled
- Keep finalizing overlay behavior separate and higher priority than focus mode.

### View Integration

- Reuse `NotesEditorView` as the only integration point.
- Hide the existing recording `header` block when focused recording mode is active.
- Replace the missing header controls with a compact footer-level recording controls row.
- Keep the rest of the workspace layout unchanged:
  - prep pane behavior
  - freeform notes editor
  - todos panel
  - timestamped notes history in freeform mode

## UI Design

### Normal Recording Mode

- Keep the existing layout and controls.
- Add a discoverable focus action inside the visible recording chrome, labeled as a focus-oriented action rather than a generic collapse affordance.
- Tapping the focus action immediately enables the persisted preference and hides the recording header.

### Focused Recording Mode

- Remove the full recording header from the top of the workspace.
- Preserve the main note-taking canvas and prep/todo layout exactly as-is.
- Show a compact recording controls row in the footer containing:
  - recording indicator
  - elapsed time
  - `Show Recording Controls`
  - `Stop Recording`
  - `Save & Export`

### Restoring Full Controls

- Tapping `Show Recording Controls` disables the persisted focus-mode preference immediately.
- The full recording header returns in place without changing the active notes mode or workspace content.

## Data Flow

### Entering A Recording Workspace

1. User starts or opens a recording workspace.
2. `NotesEditorView` reads the stored focus-mode preference.
3. If the meeting is in recording workspace state and the preference is enabled:
   - hide the recording header
   - show compact recording controls
4. Otherwise, render the existing recording header and footer behavior.

### Enabling Focus Mode

1. User clicks the focus action in the visible recording header.
2. The app updates the stored focus-mode preference.
3. `MeetingWorkspacePresentation` recalculates the focused recording state.
4. The header disappears and the compact recording controls remain available.

### Restoring Recording Controls

1. User clicks `Show Recording Controls` from the compact controls row.
2. The app disables the stored focus-mode preference.
3. The full recording header returns.

## Behavior Rules And Edge Cases

- Focus mode only affects the active recording workspace UI.
- Notes-only workspaces ignore the focus-mode preference.
- Timestamped notes mode continues to work exactly as it does today while recording.
- The compact controls must always keep `Stop Recording` accessible during recording.
- If recording is preparing, the compact controls still reflect recording state accurately.
- If recording is finalizing, the blocking overlay still covers the workspace and takes precedence over focus mode.
- Error alerts and privacy-setting flows remain unchanged.

## Error Handling

- If the stored preference cannot be read, fall back to the current default layout with full recording controls visible.
- If the stored preference cannot be written, keep the current session responsive and continue rendering based on the in-memory toggle result where possible.
- Focus mode must never block recording stop, export, or error recovery actions.

## Testing Strategy

### Presentation Tests

- Focus mode off + recording workspace -> full recording chrome remains visible.
- Focus mode on + recording workspace -> recording chrome is hidden and compact controls are shown.
- Focus mode on + notes-only workspace -> no focused-recording layout is applied.
- Finalizing workspace -> blocking overlay behavior remains unchanged regardless of focus-mode preference.

### View Behavior Tests

- Compact controls remain available in focused recording mode.
- `Show Recording Controls` restores the full header.
- Enabling focus mode does not change prep-pane visibility rules, notes content, or todo visibility.

### Regression Focus

- Existing start/stop recording flows continue to work.
- Timestamped note entry remains available when timestamped mode is active during recording.
- `Save & Export` remains available in both normal and focused recording modes.
- Existing footer and blocking-overlay behavior remains stable.

## Out Of Scope

- Per-meeting focus-mode preferences.
- Moving recording controls into a popover or modal.
- Changing notes-only or completed-meeting layouts.
- Reworking the prep-pane or todo-pane interaction model.
- Changing the separate `RecordingView` screen.
