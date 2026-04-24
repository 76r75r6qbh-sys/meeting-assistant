# Pause And Resume Recording Design

## Goal

Let the user pause a recording, close and reopen Casablanca later, and then resume that same meeting recording as additional segments that are stitched into one final recording when the user eventually stops.

## Product Decisions

- Use persisted multi-segment recording sessions rather than trying to reopen one live recorder after relaunch.
- Add an explicit paused-resumable meeting state separate from active recording and post-stop processing.
- Do not auto-open paused meetings on app launch.
- After relaunch, resuming is available only when the user manually opens the meeting workspace.
- `Stop Recording` after one or more pauses must produce one final stitched recording file for the meeting.

## Current Context

- `AudioRecordingService` currently models recording as a binary lifecycle:
  - `startRecording(for:)`
  - `stopRecording()`
- A live `RecordingSession` writes temporary raw capture, then mixes it into one final output file during stop.
- `MeetingStatus` currently distinguishes:
  - `.upcoming`
  - `.notesOnly`
  - `.recording`
  - `.processing`
  - `.completed`
- `NotesEditorView` owns the unified notes/recording workspace and currently renders either:
  - `Start Recording`
  - `Stop Recording`
- `MeetingWorkspacePresentation` already centralizes workspace-state visibility rules and is covered by unit tests.

## Requirements

### Recording Lifecycle

- `Start Recording` begins a new resumable recording session and starts segment `1`.
- `Pause Recording` stops live capture, persists the completed segment, and leaves the meeting resumable.
- `Resume Recording` starts a new segment within the same persisted recording session.
- `Stop Recording` finalizes the active segment if needed, merges all saved segments into one final recording file, stores the result on the meeting, and clears resumable session state.

### Relaunch Behavior

- Paused recordings must survive app relaunch.
- Casablanca must not auto-open paused meetings on launch.
- When the user later opens a paused meeting manually, the workspace must show `Resume Recording`.

### Workspace Behavior

- Active recording must still support freeform notes, timestamped notes, prep, and todos as it does today.
- Paused recordings must keep freeform notes, prep, and todos available.
- Timestamped note entry remains available only during active recording, not while paused.
- The user must be able to stop and finalize a paused session without resuming capture first.

### Recovery And Safety

- Missing or corrupt resumable session data must not leave a meeting permanently stuck in a paused state.
- Failed final merge must preserve the resumable session so the user can retry later.
- Meeting deletion must clean up resumable recording data as well as the final recording file.

## Proposed Architecture

Extend the existing meeting workspace and recording service instead of introducing a new paused-recording screen or a background recovery subsystem.

### Meeting State

Add a new `MeetingStatus.pausedRecording`.

Behavior:
- `.recording` means a live capture session is currently running.
- `.pausedRecording` means one or more recording segments exist for the meeting and the session is resumable, but no capture is active.
- `.processing` still means recording is fully finished and downstream work such as transcription may continue.

`MeetingDetailPresentation` should continue routing `.pausedRecording` to `.workspace`.

### Persisted Recording Session Store

Add a persisted resumable recording-session store keyed by `meeting.id`.

The meeting model should continue storing only durable meeting-facing data:
- final `recordingFileURL`
- final `recordingDuration`
- meeting `status`

Low-level capture bookkeeping belongs in a sidecar session store, not on the meeting itself.

### Recording Session Manifest

Persist a manifest per resumable session containing:
- `meetingID`
- `createdAt`
- `updatedAt`
- `nextSegmentNumber`
- `segments: [SegmentMetadata]`
- `systemAudioEnabled`
- optional `selectedInputDeviceID`

Each `SegmentMetadata` contains:
- `index`
- `fileURL`
- `duration`
- `createdAt`
- optional normalized format metadata if needed for validation

### Storage Layout

Store resumable sessions under a dedicated application-managed folder, for example:

- `Application Support/.../RecordingSessions/<meeting-id>/session.json`
- `Application Support/.../RecordingSessions/<meeting-id>/segment-001.wav`
- `Application Support/.../RecordingSessions/<meeting-id>/segment-002.wav`

Keep the final merged meeting recording in the existing final-recording location used today.

## Data Flow

### Start Recording

1. User clicks `Start Recording` from a notes-only workspace.
2. Casablanca creates a new recording-session folder and manifest for the meeting.
3. `AudioRecordingService` starts a fresh live `RecordingSession` for segment `1`.
4. Meeting status becomes `.recording`.

### Pause Recording

1. User clicks `Pause Recording` during active recording.
2. Casablanca stops the live `RecordingSession`.
3. The service finalizes the active temp capture into a durable segment file inside the session folder.
4. The manifest is updated with the new segment metadata.
5. In-memory live recording state is cleared.
6. Meeting status becomes `.pausedRecording`.

### Resume Recording

1. User opens a meeting in `.pausedRecording`.
2. Workspace loads the persisted session manifest.
3. User clicks `Resume Recording`.
4. Casablanca starts a fresh live `RecordingSession` using the next segment number.
5. Meeting status becomes `.recording`.

### Stop Recording From Active State

1. User clicks `Stop Recording` while actively recording.
2. Casablanca finalizes the live segment into the persisted session manifest.
3. Casablanca merges all persisted segments into one final output file.
4. Meeting `recordingFileURL` and `recordingDuration` are updated.
5. Resumable session files are deleted.
6. Meeting status becomes `.processing`.

### Stop Recording From Paused State

1. User opens a meeting in `.pausedRecording`.
2. User clicks `Stop Recording`.
3. Casablanca merges the existing persisted segments without restarting capture.
4. Meeting `recordingFileURL` and `recordingDuration` are updated.
5. Resumable session files are deleted.
6. Meeting status becomes `.processing`.

## UI Design

### Workspace Actions

The footer should render state-appropriate actions rather than a simple start/stop toggle:

- `.notesOnly`
  - `Start Recording`
- `.recording`
  - `Pause Recording`
  - `Stop Recording`
- `.pausedRecording`
  - `Resume Recording`
  - `Stop Recording`

`Save & Export` remains available subject to the existing notes-content rules.

### Workspace Presentation Rules

`MeetingWorkspacePresentation` should distinguish:
- active live recording
- resumable recording exists
- finalization in progress

Presentation rules:
- Back navigation remains blocked while actively recording or finalizing.
- Back navigation is allowed while paused.
- Timestamped note entry is available only during active live recording.
- Freeform notes, prep, and todos remain available in all workspace states.

### State Labels

Replace the current binary state label behavior with explicit labels:
- `Recording`
- `Paused`
- `Preparing`
- `Finalizing`

Focus mode should continue working, but compact recording controls must reflect paused state clearly.

## Recording Service Design

Implement pause/resume as multiple independent full capture segments.

### Service API Direction

Extend `AudioRecordingService` with paused-session behavior:

- `startRecording(for:)`
  - starts a brand-new resumable session and first segment
- `pauseRecording()`
  - stops the live session
  - finalizes the current segment into durable session storage
  - clears live in-memory capture state
- `resumeRecording(for:)`
  - loads persisted session metadata
  - starts a new live segment
- `stopRecording()`
  - if needed, finalizes the active segment
  - merges all persisted segment files into one final output
  - clears resumable session state

### Segment Format

Persist each paused segment in one normalized durable audio format so final merge is deterministic.

Preferred direction:
- reuse the current capture-first pipeline
- finalize each active run into a stable WAV segment file
- perform final stop as a second-stage merge across normalized segment WAV files

This avoids trying to preserve a live engine or append directly into one recording file across app relaunches.

### Final Merge

On final stop:
- validate that all segment files exist
- validate or normalize compatible format expectations
- concatenate or merge the normalized segment files in order
- compute final duration as the sum of segment durations

If any segment is missing or incompatible, fail with a targeted error and keep the resumable session intact for retry or repair.

## Error Handling

### Pause Failure

- If `Pause Recording` fails, keep the meeting in `.recording`.
- Preserve the live-session error path and surface the failure normally.

### Resume Failure

- If `Resume Recording` fails, keep the meeting in `.pausedRecording`.
- Do not discard existing persisted segments.

### Stop Failure

- If final merge fails from `.recording`, first finalize the active segment only if that step succeeds.
- If the app is no longer actively capturing, keep the meeting in `.pausedRecording`.
- Preserve resumable session files so the user can retry `Stop Recording` later.

### Corrupt Or Missing Manifest

- If a meeting is in `.pausedRecording` but its manifest cannot be loaded, show a targeted error.
- Offer recovery by downgrading the meeting back to `.notesOnly` only after cleaning up unusable resumable session data.
- Do not silently pretend the recording is resumable when the backing data is gone.

## Cleanup Rules

- Successful final stop deletes the resumable session folder.
- Deleting a meeting deletes:
  - the final recording file if present
  - the resumable session folder if present
- Starting a new recording on a meeting with stale resumable session data must not silently discard that state.
- Recovery flows should either resume the existing session or force explicit cleanup first.

## Testing Strategy

### Presentation Tests

- `.pausedRecording` routes to workspace presentation.
- Paused workspace shows `Resume Recording` and `Stop Recording`.
- Paused workspace allows back navigation.
- Paused workspace hides live timestamped-note entry while keeping freeform notes and todos visible.

### Recording Flow Tests

- `start -> pause -> resume -> stop` produces a single final recording result.
- `start -> pause -> relaunch/open -> resume -> stop` restores resumable behavior correctly.
- `start -> pause -> open later -> stop` finalizes without resuming capture.

### Persistence And Recovery Tests

- Session manifest round-trip persists expected segment metadata.
- Missing manifest for `.pausedRecording` triggers recovery handling.
- Missing segment file during final stop preserves resumable state and returns an error.

### Cleanup Tests

- Successful final stop deletes session storage.
- Meeting deletion removes session storage.
- Failed final merge does not delete session storage.

## File-Level Change Plan

- `Casablanca/Models/Meeting.swift`
  - add `MeetingStatus.pausedRecording`
  - update presentation mapping as needed
- `Casablanca/Services/AudioRecordingService.swift`
  - add pause/resume behavior
  - integrate persisted recording-session store
  - support final merge across stored segments
- `Casablanca/Views/NotesEditorView.swift`
  - render pause/resume/stop actions
  - handle paused workspace behavior and recovery errors
- `CasablancaTests/MeetingStartFlowTests.swift`
  - extend workspace presentation coverage
- `CasablancaTests/*recording*`
  - add segment persistence, recovery, and merge flow coverage

## Out Of Scope

- Auto-opening paused meetings on app launch.
- Background recovery or migration work at startup beyond lightweight validation.
- Editing or trimming individual paused segments before final merge.
- Cross-meeting recording-session reuse.
- Cloud sync or sharing for in-progress resumable recordings.
