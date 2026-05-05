# In-Recording Language Change

## Problem

`Meeting.transcriptionLanguage` is set at meeting creation (from the `defaultTranscriptionLanguage` user pref) and can only be edited after the recording stops, via the picker in `RecordedMeetingView`. Users who notice mid-recording that the language is wrong have no way to fix it from the active meeting screen — they have to wait until the recording stops, then remember to change it before transcription runs.

## Goal

Let users change the transcription language from the active meeting screen during recording / paused-recording, so the correct language is committed by the time they hit Stop.

## Non-goals

- No live transcription. Whisper still only runs after Stop.
- No retroactive re-transcription. Changing language post-transcription is out of scope.
- No new language options. Reuse the existing `TranscriptionService.supportedLanguages` list.
- No pre-recording (`notesOnly`) picker. Users continue to rely on the default until recording starts.
- No focus-mode placement. The picker is reachable only when the recording header is expanded.

## Design

### Component change

One file: `Casablanca/Views/NotesEditorView.swift`. Inside the existing `DisclosureGroup("Audio Settings", ...)` (around line 346), add a third row below the microphone picker and the "Capture system audio" toggle:

```swift
Picker("Language", selection: $meeting.transcriptionLanguage) {
    ForEach(TranscriptionService.supportedLanguages, id: \.id) { language in
        Text(language.name).tag(language.id)
    }
}
.onChange(of: meeting.transcriptionLanguage) { save() }
```

**Styling.** Match the sibling Microphone picker, not the `RecordedMeetingView` picker: keep the inline `"Language"` label (no `.labelsHidden()`), no fixed frame width — let the disclosure layout drive sizing.

**Disabled state.** Do not apply `.disabled(recordingService.isPreparing)`. Language has no hardware coupling; the value is only consumed at transcription time, so user can change it any moment the picker is visible.

### Data flow

The picker binds directly to the existing `meeting.transcriptionLanguage` property (already `@Bindable` in `NotesEditorView`). The `onChange` handler calls the existing `save()` method, which persists to SwiftData via `modelContext.save()` and triggers `ExportService.exportAutomaticallyIfEnabled(meeting)`. No new state, no new service plumbing.

`TranscriptionService` already reads `meeting.transcriptionLanguage` at transcription time via `TranscriptionView.swift:149`. No service changes required.

### Visibility rules

| Meeting status | Picker visible? | Where |
|---|---|---|
| `notesOnly` (pre-recording) | No | — |
| `recording` | Yes | Audio Settings disclosure in `NotesEditorView` header |
| `pausedRecording` | Yes | Audio Settings disclosure in `NotesEditorView` header |
| Recording focus mode | No | Header is hidden; user toggles focus mode off to access |
| `processing` / `completed` (post-stop) | Existing picker in `RecordedMeetingView` | Unchanged |

The Audio Settings disclosure is part of the `header` view, which only renders when `presentation.showsExpandedRecordingChrome` is true (i.e. recording or paused, and not in focus mode). No changes to disclosure visibility logic.

### Effect timing

Recording is unaffected by the change (no live transcription pipeline). The new value is read only when `TranscriptionView.startTranscription()` calls `transcriptionService.transcribe(..., localeIdentifier: meeting.transcriptionLanguage)` after Stop. Net effect: changing language during recording = changing what Whisper will use when finalizing.

### Edge cases

- **SwiftData save failures**: Already silently ignored by the existing `save()` (`try? modelContext.save()`). No new handling needed.
- **Unknown locale identifier**: Not reachable from the picker (only values from `supportedLanguages` are selectable). The existing fallback in `whisperLanguageCode(for:)` handles unknowns by defaulting to `"en"`.
- **Default-language preference change mid-recording**: Out of scope. Per-meeting language is already independent of the pref once a meeting is created.
- **Last-second change while finalizing (Stop pressed)**: Acceptable. The header still renders while `meeting.status` is `.recording` / `.pausedRecording`, so a change can land just before `TranscriptionView` reads the value. Whichever value is committed at the moment `transcribe(...)` is called wins. No locking needed.

## Testing

Manual verification:

1. Create a meeting with the default language set to Dutch.
2. Start recording, open Audio Settings, change the language picker to English (US).
3. Stop recording, confirm transcription runs in English.
4. Repeat with paused-recording state to confirm picker is interactive while paused.
5. Toggle focus mode during recording, confirm picker is not visible (header hidden).

No unit tests added. The change is a thin SwiftUI binding and matches the existing untested pattern of the post-recording picker in `RecordedMeetingView`.
