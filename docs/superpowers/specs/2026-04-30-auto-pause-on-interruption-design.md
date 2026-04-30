# Auto-Pause Recording On System Interruption Design

**Status:** Draft for implementation planning
**Owner:** Youri Broekhuizen
**Last updated:** 2026-04-30

## Problem

When the recording is interrupted mid-meeting — laptop locked, system sleeps, mic disconnected, ScreenCaptureKit terminating its stream — `AudioRecordingService` only sets `errorMessage` from the stream-delegate failure callback. It never resets `isRecording`, the `session` reference, or `activeMeetingID`. The user sees a "no recording device found" alert. Tapping **Retry** either no-ops (because `startRecordingIfNeeded` early-returns on stale `isRecording == true`) or hits the `session != nil` guard and surfaces a second SCStream error like "stream doesn't exist", leaving the in-flight audio data effectively lost.

The desired behavior: treat system interruptions as a graceful pause that preserves the audio captured so far, transitions the meeting into the existing `.pausedRecording` state, and either resumes silently for short interruptions or waits for a manual Resume tap for longer ones.

## Goals

- Mid-recording failures from system events never reach the user as a generic "Recording Error" alert.
- Audio captured before the interruption is preserved as a segment that becomes part of the final stitched recording.
- Short interruptions (lock, sleep) resolve themselves with no user action.
- Long interruptions and audio-device disconnects leave the meeting clearly paused with a working Resume button.
- The recording state machine and the system-event listening stay in separate, independently testable units.

## Non-Goals

- Pause behavior triggered by application backgrounding or window focus changes.
- A user-facing setting to disable the auto-pause behavior. Always on.
- Automatic switching to a different microphone when the active one disappears.
- Graceful handling of pre-recording failures (mic permission denied, disk write blocked) — those keep the existing "Recording Error" alert and Retry path.

## Decisions

| # | Decision | Why |
|---|----------|-----|
| 1 | Auto-pause triggers: screen lock, system sleep, audio input device removed, SCStream stop-with-error. | Covers the observed "no recording device found" and "stream doesn't exist" failures and the user's stated lock-screen case. |
| 2 | Auto-resume threshold: 30 seconds, only for screen lock and system sleep. | Short window keeps quick interruptions transparent without silently resuming long-paused recordings. |
| 3 | Audio-device disconnect always stays paused. | Reattaching may take a long time and may bring back a different device; resuming silently could capture audio on the wrong input. |
| 4 | SCStream stop-with-error always stays paused (no auto-resume). | The stream may have died for a reason that has not resolved; require explicit Resume so the user knows recording is back. |
| 5 | UX feedback: quiet inline indicator in the workspace plus a macOS user notification on each pause and each resume. | Notifications surface the event when the user is not in the app; the inline indicator gives context when they return. No modals. |
| 6 | Always on, no Settings toggle. | Strictly better than today's broken Retry path; no plausible reason to disable. |
| 7 | Implementation rides on top of the existing pause/resume plan (Tasks 3 & 4 of `2026-04-24-pause-resume-recording.md`), not as a parallel track. | Auto-pause uses exactly the same finalize-segment / persist-session / transition-to-paused machinery the manual pause button needs. One implementation pass. |

## Architecture

Three units, each independently testable:

```
NSWorkspace / Core Audio / SCStream delegate
              │
              ▼
   RecordingInterruptionMonitor   (observes the system, knows nothing about recording state)
              │
              ▼   interruptionStarted / interruptionEnded events
   RecordingInterruptionCoordinator  (decides pause vs auto-resume vs manual-resume; posts notifications)
              │
              ▼   pauseRecording() / resumeRecording(for:)
       AudioRecordingService     (pure recording state machine; no system-event awareness)
              │
              ▼
       RecordingResumeSessionStore + RecordingSegmentMerger
```

### `RecordingInterruptionMonitor` (new)

Single source of truth for "is the system interrupting recording right now?".

Responsibilities:
- Subscribe to `NSWorkspace.shared.notificationCenter`: `screensDidSleepNotification`, `screensDidWakeNotification`, `willSleepNotification`, `didWakeNotification`. (Display-sleep is what fires on macOS when the user locks the screen, closes the lid, or hits a hot corner — `NSWorkspace` does not expose a true screen-lock notification on its main center; the system posts `com.apple.screenIsLocked` only on the distributed center.)
- Register a Core Audio property listener on `kAudioHardwarePropertyDevices`. On change, compare against the active input device ID currently in use by the recording; if it disappeared, fire a device-lost event. The active device ID is supplied via `func setActiveInputDevice(_ id: String?)`, which `AudioRecordingService` calls when starting and resuming a recording (and clears on stop/finalize).
- Expose `func reportStreamFailure(_ error: Error)` so `AudioRecordingService` can forward SCStream `didStopWithError` and AVAudioEngine engine-died notifications. The monitor is the only place that decides whether such a failure counts as an interruption.
- Emit two event streams (callbacks or `AsyncStream`):
  - `interruptionStarted(reason: InterruptionReason, at: Date)`
  - `interruptionEnded(reason: InterruptionReason, at: Date)`

```swift
enum InterruptionReason: Equatable {
    case screenLock
    case systemSleep
    case audioDeviceLost(deviceID: String)
    case streamFailure(underlyingDescription: String)
}
```

Injection seams: takes a `NotificationCenter`, a `() -> [AudioInputDevice]` device-list provider, and a `Date`-returning clock so tests can drive time and events deterministically without touching real Core Audio or `NSWorkspace`.

### `RecordingInterruptionCoordinator` (new)

Thin glue layer. The only piece that touches both the monitor and the service.

Responsibilities:
- Hold a reference to `AudioRecordingService` and the active `Meeting` (set when recording starts, cleared when stopped or completed).
- Subscribe to monitor events. On `interruptionStarted`:
  1. If the service is recording, call `service.handleSystemInterrupt(reason:)` — which finalizes the segment and transitions to `.pausedRecording`.
  2. Append an `InterruptionEvent` (reason, started-at, segment-duration) to a bounded in-memory ring buffer (last 5).
  3. Post a `UNUserNotificationCenter` notification: title "Recording paused", body localized to the reason.
  4. Start a 30-second "auto-resume window" timer. The window is the deadline for auto-resume: if it expires while the meeting is still paused, the auto-resume option is dropped (the timer is *not* what triggers the resume — `interruptionEnded` is). Cancel the timer on any user-initiated transition out of `.pausedRecording`.
- On `interruptionEnded`: if the auto-resume window has not yet expired, every reason that fired during the window allows auto-resume (`.screenLock`, `.systemSleep`), the active reason multiset is now empty, and the meeting is still `.pausedRecording`, call `service.resumeRecording(for: meeting)` and post a "Recording resumed" notification. Otherwise leave it paused; the user uses the Resume button.

Coalescing: the coordinator tracks a multiset of currently-active reasons. Multiple overlapping `interruptionStarted` events do not re-finalize once the meeting is already paused; the auto-resume window only opens once the multiset is empty.

Injection seams: fake `NotifierProtocol`, fake clock, fake `service` test double. The coordinator's tests never instantiate `AudioRecordingService` or the real `UNUserNotificationCenter`.

### `AudioRecordingService` extensions

Lands the missing pieces from the existing pause/resume plan plus a small system-interrupt entry point.

New public surface:
- `func pauseRecording() async throws -> RecordingResult` — manual pause. Stops the live session, appends a non-empty segment to the resume-session manifest, clears live state. Throws `noActiveRecording` if not recording.
- `func resumeRecording(for meeting: Meeting) async throws` — manual or auto resume. Loads the manifest, opens a new segment file, starts a fresh `RecordingSession` against it, sets `isRecording = true`, restarts the timer.
- `func stopRecording(for meeting: Meeting) async throws -> RecordingResult` — segment-aware stop. If currently recording, finalizes the live segment first. Then merges all segments into one final WAV via `RecordingSegmentMerger.merge`, deletes the resume-session folder, returns the final result.
- `func handleSystemInterrupt(reason: InterruptionReason) async` — non-throwing wrapper over `pauseRecording()` for the coordinator. If the live session has captured zero frames, deletes the temp WAV without appending to the manifest. If anything else throws, sets `errorMessage` and leaves the service in whatever consistent state it can.
- `func forwardStreamFailure(_ error: Error)` — bridges SCStream `didStopWithError` and AVAudioEngine notifications to the monitor. The service no longer mutates state directly from those callbacks.

Existing `startRecording(for:)` and the legacy zero-arg `stopRecording()` stay for backwards compatibility with current callers but are no longer the primary surface.

Injection seams (per the existing plan): `RecordingResumeSessionStore`, `RecordingSessionFactory`, `makeFinalOutputURL`, `mergeSegments`. These keep the service testable without ScreenCaptureKit, AVFoundation, or the real filesystem.

## Data Flow

### Interruption start

1. User locks the screen (display sleeps). `RecordingInterruptionMonitor` receives `screensDidSleepNotification`, emits `interruptionStarted(.screenLock, at: now)`.
2. Coordinator inspects state. Service is recording → calls `service.handleSystemInterrupt(reason: .screenLock)`.
3. Service stops the live session (`session.stop()`), gets back a `RecordingResult { url, duration }`.
   - If `duration > 0`: append to manifest via `RecordingResumeSessionStore.appendSegment(...)`.
   - If `duration == 0`: delete the empty WAV; manifest unchanged. Resume will create segment 1.
4. Service clears `session`, flips `isRecording = false`, clears `activeMeetingID`, cancels the elapsed-time timer, zeroes `audioLevel`.
5. View layer observes the state change. Meeting transitions to `.pausedRecording` and `modelContext.save()` runs (the change is driven via the same `meeting.status` mutation the manual pause button uses).
6. Coordinator records the event, posts the macOS notification, schedules the 30-second auto-resume task.

### Interruption end

1. User unlocks. Monitor emits `interruptionEnded(.screenLock, at: now)`.
2. Coordinator computes `elapsed = end - start`. If `elapsed < 30s`, every active reason allows auto-resume, the meeting is still `.pausedRecording`, and the manifest still exists → call `service.resumeRecording(for: meeting)`.
3. Service loads the manifest, opens segment N+1, starts a new `RecordingSession`. View flips meeting back to `.recording`.
4. Coordinator posts "Recording resumed" notification. Workspace inline indicator shows "Auto-paused at 14:23 for 12s".

### SCStream stop-with-error mid-recording

1. SCStream's `didStopWithError` fires inside the existing `StreamLifecycleDelegate`.
2. Service's `forwardStreamFailure(_:)` passes the error to the monitor.
3. Monitor classifies. If a system interruption is already active (e.g., we already saw `willSleepNotification`), the stream failure is treated as part of that interruption and ignored. Otherwise it emits `interruptionStarted(.streamFailure(...))`.
4. Coordinator runs the standard pause flow. Reason `.streamFailure` is not auto-resumable; the meeting stays `.pausedRecording` until the user taps Resume.

### Audio input device removed

1. Core Audio property listener fires. Monitor compares the previous device list against the new one; the input device the recording was using is gone.
2. Monitor emits `interruptionStarted(.audioDeviceLost(deviceID:))`.
3. Coordinator runs the standard pause flow. Not auto-resumable. Even if the same device reappears, the user re-enters via the Resume button (which uses the persisted `selectedInputDeviceID` from the manifest, so the right device is picked when present).

## UI Changes

- `NotesEditorView` footer: replace the start/stop button cluster with explicit Pause / Resume / Stop buttons (Task 4 of the existing pause/resume plan).
- `NotesEditorView` header: add a small inline line beneath the recording chrome when there is at least one event in the coordinator's recent-events buffer for the active meeting, e.g. "Auto-paused at 14:23 for 12s — recording resumed". Disappears when the meeting transitions away from the workspace or the user dismisses it.
- `SidebarView`: paused-state icon (already in the existing plan).
- macOS notifications: request authorization on first use via `UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])`. If the user declines, fall back to inline-only feedback. Do not retry the request on every recording.
- The existing "Recording Error" alert with Retry now only fires for pre-recording failures (mic permission, disk error, screen-capture permission). Live-recording failures take the new pause path instead.

## Edge Cases

- **Empty segment** at pause time. Detected by `capturedMicrophoneFrames == 0 && capturedSystemAudioFrames == 0`. Service deletes the temp WAV, does not append to the manifest, still transitions to paused. Resume opens segment 1 fresh.
- **Failure during the pause's own finalize** (rare — temp file write fails, mixer fails). Surface a non-blocking error indicator, leave the meeting in `.pausedRecording`, leave whatever segments already landed in the manifest intact. User can still Resume (new segment) or Stop (merge what we have).
- **Resume fails** (e.g., audio device still missing on auto-resume). Coordinator catches the throw, posts a "Could not resume recording" notification, leaves the meeting paused.
- **Manual stop or resume during the auto-resume window.** Manual action wins. Coordinator's auto-resume task checks `meeting.status` immediately before running and bails if it changed; it also explicitly cancels the task on any user-initiated transition.
- **Overlapping interruptions.** Coordinator maintains a multiset of active reasons. Pause is triggered only on the first transition to non-empty; auto-resume only fires when the multiset returns to empty. Mid-interruption events are recorded for the UI but do not re-finalize.
- **App quit while paused.** Already covered by the existing plan: segments and manifest persist under `Application Support/Casablanca/RecordingSessions/<meetingID>/`. On next launch the meeting opens with `.pausedRecording` status; the workspace shows the Resume button. The coordinator does not auto-resume after a process restart, regardless of how short the gap was — the time gap is unbounded from the app's perspective.
- **Per-buffer conversion errors** (today's `onFailure` callbacks from inside audio queues). These keep their current behavior of setting `errorMessage` for visibility but do not pause: a single dropped buffer is not an interruption. Pause only triggers via `forwardStreamFailure(_:)` (stream delegate) or `engine.notification` for engine-died, which are coarse, infrequent signals.
- **Stop during an active interruption window.** Stop merges existing segments, transitions to `.processing`, cancels the pending auto-resume task. If the live session is somehow still alive (race: stream-failure ended but coordinator hadn't run yet), Stop calls `pauseRecording()` once internally to drain the live session before merging.
- **Pre-recording failures.** Untouched. Mic permission denied, disk failure, screen-capture permission missing — all still surface the existing "Recording Error" alert with Retry / Open Privacy Settings / Back to Notes.

## Testing

The split gives three pure test surfaces plus one manual sanity pass.

### `AudioRecordingServicePauseResumeTests` (extends Task 3 of existing plan)
Inject fake `RecordingSessionControlling` and fake merge closure. Cover:
- Pause persists segment and clears live state.
- Pause with zero frames discards temp WAV and leaves manifest unchanged.
- Resume opens a new segment file and increments the manifest's `nextSegmentNumber`.
- Stop after multiple pauses merges all segments and deletes the session folder.
- Stop during a live session finalizes the segment first, then merges.
- `handleSystemInterrupt(reason:)` is a non-throwing wrapper that calls the same pause path and tolerates the empty-segment case.

### `RecordingInterruptionCoordinatorTests` (new)
Inject fake monitor, fake service test double, fake clock, fake notifier. Cover:
- Short lock then unlock → service receives `pauseRecording` then `resumeRecording`; notification fires twice (paused, resumed).
- Long lock then unlock (>30s elapsed in the fake clock) → service receives `pauseRecording` only; meeting stays paused.
- Audio-device-lost → service receives `pauseRecording`; later device reappear does **not** trigger resume.
- Stream-failure → same as device-lost; no auto-resume.
- Overlapping screen-lock + system-sleep → service receives `pauseRecording` once; auto-resume waits for both to end.
- Manual stop during the auto-resume window cancels the pending resume task; service does not receive `resumeRecording`.
- Resume failure (service throws) → coordinator posts "Could not resume recording" notification, meeting still paused.

### `RecordingInterruptionMonitorTests` (new)
Narrow integration with fake `NotificationCenter` and fake device-list provider. Cover:
- `screensDidSleepNotification` produces `interruptionStarted(.screenLock)`.
- `willSleepNotification` produces `interruptionStarted(.systemSleep)`.
- Device list change that removes the active device produces `interruptionStarted(.audioDeviceLost)`.
- Device list change that does not affect the active device produces no event.
- `reportStreamFailure(_:)` while a system reason is already active produces no additional event.

### Manual sanity pass
1. Start a recording. Lock the laptop for 10 seconds, unlock. Recording continues. Header shows "Auto-paused at HH:MM for ~10s".
2. Start a recording. Lock for 60 seconds, unlock. Meeting is `.pausedRecording`. Resume button works; final stitched WAV plays back as one continuous file.
3. Start a recording with a USB mic. Unplug the mic. Meeting goes to `.pausedRecording` with a "Recording paused — microphone disconnected" notification. Plug the mic back in — meeting stays paused. Tap Resume — recording continues with the same mic.
4. Start a recording. Force-quit Casablanca. Reopen the app, open the meeting. Resume button is visible. Tap Resume → record more → Stop. Final WAV contains both segments.

## File Inventory

| File | Responsibility | Status |
|---|---|---|
| `Casablanca/Models/Meeting.swift` | `MeetingStatus.pausedRecording` exists. | Already landed (Task 1). |
| `Casablanca/Services/RecordingResumeSessionStore.swift` | Persist resumable manifests and segment files. | Already landed (Task 2). |
| `Casablanca/Services/AudioRecordingService.swift` | Add `pauseRecording`, `resumeRecording(for:)`, `stopRecording(for:)`, `handleSystemInterrupt(reason:)`, `forwardStreamFailure(_:)`. | Modify (Task 3 + this design). |
| `Casablanca/Services/RecordingInterruptionMonitor.swift` | New. Observe `NSWorkspace`, Core Audio device list, and stream failures. | New. |
| `Casablanca/Services/RecordingInterruptionCoordinator.swift` | New. Glue monitor events to service actions; manage auto-resume window; post macOS notifications. | New. |
| `Casablanca/ViewModels/MeetingListViewModel.swift` | Clean up resume-session folder on meeting deletion. | Modify (existing plan Task 4). |
| `Casablanca/Views/NotesEditorView.swift` | Pause / Resume / Stop buttons, paused-state task validation, inline auto-pause indicator. | Modify (existing plan Task 4 + this design). |
| `Casablanca/Views/SidebarView.swift` | Paused-state icon and label. | Already landed (Task 1). |
| `CasablancaTests/MeetingStartFlowTests.swift` | Pause/resume service flows + paused workspace presentation. | Extend (existing plan + this design). |
| `CasablancaTests/PermissionsBehaviorTests.swift` | Resume-session store and segment merger helpers. | Extend (existing plan). |
| `CasablancaTests/RecordingInterruptionCoordinatorTests.swift` | Coordinator behavior with fakes. | New. |
| `CasablancaTests/RecordingInterruptionMonitorTests.swift` | Monitor's mapping from system events to interruption events. | New. |

## Open Questions

None at design time. Implementation may surface a question about exactly which `AVAudioEngine` notification (if any) reliably fires when a USB mic disappears — Core Audio's property listener on `kAudioHardwarePropertyDevices` is the primary signal; engine-died is a fallback.
