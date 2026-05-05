# In-Recording Language Change Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a language picker to the Audio Settings disclosure on the active meeting screen so users can change `Meeting.transcriptionLanguage` while a recording is in progress or paused.

**Architecture:** Single SwiftUI binding change in `NotesEditorView`. The picker reads/writes the existing `meeting.transcriptionLanguage` SwiftData property, debounce-saves on change, and consumes the existing `TranscriptionService.supportedLanguages` list. No service, model, or view-model changes. The new value is read at transcription time (post-Stop) by the existing `TranscriptionView` flow — no live-transcription pipeline involved.

**Tech Stack:** Swift, SwiftUI, SwiftData, macOS app target (Casablanca).

**Spec:** `docs/superpowers/specs/2026-05-05-in-recording-language-change-design.md`

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `Casablanca/Views/NotesEditorView.swift` | Modify (insert ~7 lines into existing `DisclosureGroup`, around line 371) | Render the new language picker as the third row of Audio Settings |

No other files change. No tests added (matches existing pattern: SwiftUI bindings to model properties have no unit tests in this codebase; service-level tests live under `CasablancaTests/`).

---

## Task 1: Add Language picker to Audio Settings disclosure

**Files:**
- Modify: `Casablanca/Views/NotesEditorView.swift` (insert after line 371, inside the `DisclosureGroup("Audio Settings", ...)` `VStack`)

- [ ] **Step 1: Open the file and locate the insertion point**

Open `Casablanca/Views/NotesEditorView.swift`. Find the `DisclosureGroup("Audio Settings", isExpanded: $showingAudioSettings)` block (currently around line 346). Inside its `VStack(alignment: .leading, spacing: CasaSpace.md)`, locate the `Toggle(isOn: ...) { Label("Capture system audio", ...) } .disabled(recordingService.isPreparing)` block (lines 361–371). The new picker goes immediately after the closing `}` of that `.disabled(recordingService.isPreparing)` modifier, still inside the outer `VStack`.

- [ ] **Step 2: Insert the language picker**

Insert this block after line 371 (after the `.disabled(recordingService.isPreparing)` line that closes the system-audio Toggle), and before the closing `}` of the `VStack` (line 372 currently):

```swift
Picker("Language", selection: $meeting.transcriptionLanguage) {
    ForEach(TranscriptionService.supportedLanguages, id: \.id) { language in
        Text(language.name).tag(language.id)
    }
}
.onChange(of: meeting.transcriptionLanguage) {
    save()
}
```

Notes for the implementer:
- Do **not** add `.labelsHidden()` — the inline "Language" label matches the sibling `Picker("Microphone", ...)`.
- Do **not** add a fixed `.frame(width:)` — let the disclosure layout drive sizing.
- Do **not** add `.disabled(recordingService.isPreparing)` — language has no hardware coupling and should remain interactive even while audio I/O is preparing.
- `meeting` is already `@Bindable` at the top of `NotesEditorView`, so `$meeting.transcriptionLanguage` resolves directly.
- `TranscriptionService.supportedLanguages` is already in scope (no new import needed).
- `save()` is the existing private method on `NotesEditorView` (around line 919) that calls `try? modelContext.save()` and `ExportService.exportAutomaticallyIfEnabled(meeting)`.

After insert, the disclosure body should look like (showing context):

```swift
DisclosureGroup("Audio Settings", isExpanded: $showingAudioSettings) {
    VStack(alignment: .leading, spacing: CasaSpace.md) {
        if recordingService.availableInputDevices.isEmpty {
            Text("No microphone found")
                .font(.body)
                .foregroundStyle(Color.textTertiary)
        } else {
            Picker("Microphone", selection: selectedMicrophoneBinding) {
                ForEach(recordingService.availableInputDevices) { device in
                    Text(device.name).tag(device.id)
                }
            }
            .disabled(recordingService.isPreparing)
        }

        Toggle(isOn: Binding(
            get: { recordingService.isSystemAudioEnabled },
            set: { newValue in
                if newValue != recordingService.isSystemAudioEnabled {
                    recordingService.toggleSystemAudioEnabled()
                }
            }
        )) {
            Label("Capture system audio", systemImage: "speaker.wave.2.fill")
        }
        .disabled(recordingService.isPreparing)

        Picker("Language", selection: $meeting.transcriptionLanguage) {
            ForEach(TranscriptionService.supportedLanguages, id: \.id) { language in
                Text(language.name).tag(language.id)
            }
        }
        .onChange(of: meeting.transcriptionLanguage) {
            save()
        }
    }
    .padding(.top, CasaSpace.sm)
}
.tint(Color.textPrimary)
```

- [ ] **Step 3: Build the app to verify compilation**

Run from the repo root:

```bash
xcodebuild -project Casablanca.xcodeproj -scheme Casablanca -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -40
```

Expected: `** BUILD SUCCEEDED **` near the end of the output.

If the build fails:
- Type errors on `$meeting.transcriptionLanguage` → confirm `meeting` is declared `@Bindable var meeting: Meeting` at the top of `NotesEditorView` (around line 146). It already is; do not change.
- Missing `TranscriptionService` symbol → confirm no extra imports needed; the symbol resolves via the same module.
- `onChange` signature warnings on macOS 14+ → use the zero-parameter closure form shown above (matches the existing `.onChange(of: meeting.userNotes)` at line 571).

- [ ] **Step 4: Run the existing test suite to confirm no regressions**

```bash
xcodebuild -project Casablanca.xcodeproj -scheme Casablanca -configuration Debug -destination 'platform=macOS' test 2>&1 | tail -40
```

Expected: `** TEST SUCCEEDED **`. No new tests are added in this task; this run is purely a regression guard.

- [ ] **Step 5: Manual smoke test**

This UI cannot be exercised by automated tests. Launch the app from Xcode (⌘R) and verify all of the following before marking the task done:

1. Open or create a meeting and click **Start Recording**. The recording header appears.
2. Expand the **Audio Settings** disclosure. Confirm the **Language** picker appears as the third row, below "Capture system audio". The label "Language" is visible inline (mirrors the "Microphone" row above).
3. Change the picker to a value different from the current default (e.g. switch from "English (US)" to "Dutch").
4. Click **Pause Recording**. The header still shows the disclosure. Confirm the picker is still interactive while paused, and changing it again still works.
5. Click **Resume Recording**, then **Stop Recording**. Wait for the post-recording view (`RecordedMeetingView`) to appear.
6. On `RecordedMeetingView`, before transcription kicks off, confirm the existing language picker reflects the value selected in step 3 (i.e. the change persisted across views).
7. Let transcription run. Confirm the resulting transcript matches the language chosen in step 3 (inspect a few sentences — Whisper transcribing Dutch audio with the English model produces obviously wrong output, and vice versa).
8. Toggle **Focus on Notes** during a recording. Confirm the header (and therefore the picker) is hidden in focus mode. Toggle back, confirm the picker reappears with the current value preserved.

If any step fails, do NOT commit — diagnose first.

- [ ] **Step 6: Commit**

```bash
git add Casablanca/Views/NotesEditorView.swift
git commit -m "$(cat <<'EOF'
feat(recording): allow language change during recording

Add a Language picker to the Audio Settings disclosure on the active
meeting screen so users can change Meeting.transcriptionLanguage while
recording or paused. The value is consumed by Whisper at transcription
time after Stop.

Refs: docs/superpowers/specs/2026-05-05-in-recording-language-change-design.md
EOF
)"
```

---

## Verification checklist (post-implementation)

- [ ] `xcodebuild ... build` succeeds.
- [ ] `xcodebuild ... test` passes with no new failures.
- [ ] Manual smoke test (Step 5) all 8 sub-steps green.
- [ ] Single commit on the feature branch touching only `Casablanca/Views/NotesEditorView.swift`.
- [ ] No edits to `Meeting.swift`, `TranscriptionService.swift`, `RecordedMeetingView.swift`, or any other file.
