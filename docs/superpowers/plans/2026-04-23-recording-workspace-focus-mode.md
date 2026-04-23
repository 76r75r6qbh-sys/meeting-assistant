# Recording Workspace Focus Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a remembered focus mode to the recording workspace that hides the recording header and audio settings together while keeping compact recording controls available.

**Architecture:** Keep the change inside the existing meeting workspace. Add a single app-wide preference key, extend `MeetingWorkspacePresentation` with focused-recording derived state, and let `NotesEditorView` switch between the full recording header and a compact footer row based on that state.

**Tech Stack:** Swift, SwiftUI, SwiftData, XCTest, `xcodebuild`

---

### Task 1: Add Focus-Mode Preference And Presentation Coverage

**Files:**
- Modify: `Casablanca/Models/Meeting.swift`
- Modify: `CasablancaTests/MeetingStartFlowTests.swift`
- Test: `CasablancaTests/MeetingStartFlowTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
func testFocusedRecordingWorkspaceHidesExpandedRecordingChrome() {
    let meeting = Meeting(title: "Weekly Sync", date: .now, status: .recording)
    let presentation = MeetingWorkspacePresentation(
        meeting: meeting,
        activeMeetingID: meeting.id,
        isRecording: true,
        isPreparing: false,
        isFinalizing: false,
        prefersRecordingFocusMode: true
    )

    XCTAssertFalse(presentation.showsExpandedRecordingChrome)
    XCTAssertTrue(presentation.showsCompactRecordingControls)
    XCTAssertTrue(presentation.showsRecordingChrome)
}

func testNotesOnlyWorkspaceIgnoresFocusedRecordingPreference() {
    let meeting = Meeting(title: "Weekly Sync", date: .now, status: .notesOnly)
    let presentation = MeetingWorkspacePresentation(
        meeting: meeting,
        activeMeetingID: nil,
        isRecording: false,
        isPreparing: false,
        isFinalizing: false,
        prefersRecordingFocusMode: true
    )

    XCTAssertFalse(presentation.showsExpandedRecordingChrome)
    XCTAssertFalse(presentation.showsCompactRecordingControls)
    XCTAssertTrue(presentation.showsStartRecordingButton)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -derivedDataPath .build/xcode-recording-focus-red -destination 'platform=macOS' -only-testing:CasablancaTests/MeetingWorkspacePresentationTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
```

Expected: FAIL because `MeetingWorkspacePresentation` does not yet accept `prefersRecordingFocusMode` and does not expose `showsExpandedRecordingChrome` / `showsCompactRecordingControls`.

- [ ] **Step 3: Write minimal implementation**

In `Casablanca/Models/Meeting.swift`, add the new preference key:

```swift
enum AppPreferenceKey {
    static let obsidianVaultPath = "obsidianVaultPath"
    static let ollamaEndpoint = "ollamaEndpoint"
    static let ollamaModel = "ollamaModel"
    static let whisperModel = "whisperModel"
    static let defaultTranscriptionLanguage = "defaultTranscriptionLanguage"
    static let summaryPromptTemplate = "summaryPromptTemplate"
    static let autoExportNotesToObsidian = "autoExportNotesToObsidian"
    static let autoSummarizeAfterTranscription = "autoSummarizeAfterTranscription"
    static let defaultRecordingInputDeviceID = "defaultRecordingInputDeviceID"
    static let recordingWorkspaceFocusMode = "recordingWorkspaceFocusMode"
}
```

In `Casablanca/Views/NotesEditorView.swift`, extend `MeetingWorkspacePresentation`:

```swift
struct MeetingWorkspacePresentation {
    let meeting: Meeting
    let activeMeetingID: UUID?
    let isRecording: Bool
    let isPreparing: Bool
    let isFinalizing: Bool
    let prefersRecordingFocusMode: Bool

    var isActiveMeeting: Bool {
        activeMeetingID == meeting.id
    }

    var showsRecordingChrome: Bool {
        meeting.status == .recording
    }

    var showsFocusedRecordingControls: Bool {
        showsRecordingChrome && prefersRecordingFocusMode
    }

    var showsExpandedRecordingChrome: Bool {
        showsRecordingChrome && !showsFocusedRecordingControls
    }

    var showsCompactRecordingControls: Bool {
        showsFocusedRecordingControls
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run:

```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -derivedDataPath .build/xcode-recording-focus-green-1 -destination 'platform=macOS' -only-testing:CasablancaTests/MeetingWorkspacePresentationTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
```

Expected: PASS for the new presentation tests and the existing workspace presentation tests.

- [ ] **Step 5: Commit**

```bash
git add Casablanca/Models/Meeting.swift Casablanca/Views/NotesEditorView.swift CasablancaTests/MeetingStartFlowTests.swift
git commit -m "feat: add recording workspace focus mode state"
```

### Task 2: Switch The Recording Workspace Between Full And Compact Controls

**Files:**
- Modify: `Casablanca/Views/NotesEditorView.swift`
- Modify: `CasablancaTests/MeetingStartFlowTests.swift`
- Test: `CasablancaTests/MeetingStartFlowTests.swift`

- [ ] **Step 1: Write the failing tests**

Add coverage that the presentation exposes the compact controls path while still preserving recording safety:

```swift
func testFinalizingWorkspaceStillShowsBlockingOverlayWhenFocusModeEnabled() {
    let meeting = Meeting(title: "Weekly Sync", date: .now, status: .recording)
    let presentation = MeetingWorkspacePresentation(
        meeting: meeting,
        activeMeetingID: meeting.id,
        isRecording: false,
        isPreparing: false,
        isFinalizing: true,
        prefersRecordingFocusMode: true
    )

    XCTAssertTrue(presentation.showsBlockingOverlay)
    XCTAssertFalse(presentation.showsExpandedRecordingChrome)
    XCTAssertTrue(presentation.showsCompactRecordingControls)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -derivedDataPath .build/xcode-recording-focus-red-2 -destination 'platform=macOS' -only-testing:CasablancaTests/MeetingWorkspacePresentationTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
```

Expected: FAIL until the focused-recording layout is wired through the view model and the finalizing case preserves compact controls state.

- [ ] **Step 3: Write minimal implementation**

In `Casablanca/Views/NotesEditorView.swift`, add the stored preference and route header/footer rendering through the new presentation state:

```swift
@AppStorage(AppPreferenceKey.recordingWorkspaceFocusMode)
private var recordingWorkspaceFocusMode = false
```

Pass the preference into `presentation`:

```swift
private var presentation: MeetingWorkspacePresentation {
    MeetingWorkspacePresentation(
        meeting: meeting,
        activeMeetingID: recordingService.activeMeetingID,
        isRecording: recordingService.isRecording,
        isPreparing: recordingService.isPreparing,
        isFinalizing: isFinalizingRecording,
        prefersRecordingFocusMode: recordingWorkspaceFocusMode
    )
}
```

Swap the top header condition:

```swift
if presentation.showsExpandedRecordingChrome {
    header
    Divider()
}
```

Add a focus toggle inside the header:

```swift
Button {
    recordingWorkspaceFocusMode = true
} label: {
    Label("Focus on Notes", systemImage: "rectangle.compress.vertical")
}
.buttonStyle(.plain)
```

Add compact controls inside `footer` when `presentation.showsCompactRecordingControls` is true:

```swift
if presentation.showsCompactRecordingControls {
    HStack(spacing: CasaSpace.md) {
        Label(presentation.stateLabel, systemImage: "record.circle.fill")
            .foregroundStyle(recordingService.isRecording ? Color.stateRecording : Color.textSecondary)

        Text(formattedElapsed)
            .font(.caption.monospaced())
            .foregroundStyle(Color.textSecondary)

        Button("Show Recording Controls") {
            recordingWorkspaceFocusMode = false
        }
        .buttonStyle(.plain)
    }
}
```

Keep the existing `Stop Recording` and `Save & Export` buttons in the footer so recording remains safe to control even when the header is hidden.

- [ ] **Step 4: Run test to verify it passes**

Run:

```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -derivedDataPath .build/xcode-recording-focus-green-2 -destination 'platform=macOS' -only-testing:CasablancaTests/MeetingWorkspacePresentationTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
```

Expected: PASS for the new focus-mode coverage and the existing workspace presentation assertions.

- [ ] **Step 5: Run broader regression verification**

Run:

```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -derivedDataPath .build/xcode-recording-focus-full -destination 'platform=macOS' -only-testing:CasablancaTests/MeetingStartFlowTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
```

Expected: PASS with the full `MeetingStartFlowTests` class green, confirming existing workspace behavior still holds.

- [ ] **Step 6: Commit**

```bash
git add Casablanca/Views/NotesEditorView.swift CasablancaTests/MeetingStartFlowTests.swift
git commit -m "feat: add focused recording workspace layout"
```
