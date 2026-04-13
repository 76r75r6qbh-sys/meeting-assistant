# Manual Notes Before Recording Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add explicit `Take Notes` entry points for calendar meetings, keep manual meeting shortcuts notes-first, and let users start recording later from the same notes workspace without losing the notes they already typed.

**Architecture:** Keep `Meeting.status` as the persisted source of truth, but stop treating `.recording` as a separate detail screen. `NotesEditorView` becomes the unified workspace for notes-only and active-recording sessions, while small testable helper types in existing source files drive routing and button visibility. `RecordingView` becomes a thin compatibility wrapper so recording logic lives in one place.

**Tech Stack:** SwiftUI, SwiftData, XCTest, `xcodebuild`

---

## File Structure

| File | Responsibility |
| --- | --- |
| `Casablanca/Models/Meeting.swift` | Add a testable `MeetingDetailPresentation` mapping so `.notesOnly` and `.recording` share the same workspace route |
| `Casablanca/Views/Components/MeetingCardView.swift` | Define `MeetingEntryActionLayout` and render both visible launch actions for current/upcoming calendar meetings |
| `Casablanca/Views/MenuBarMeetingView.swift` | Reuse the same launch-action layout so the menu bar matches the dashboard behavior |
| `Casablanca/Views/NotesEditorView.swift` | Host the unified notes/recording workspace, including inline recording start, recording chrome, timestamped notes, and existing export behavior |
| `Casablanca/Views/RecordingView.swift` | Reduce to a thin wrapper that delegates to `NotesEditorView(autoStartRecording: true)` |
| `Casablanca/Views/ContentView.swift` | Route `.notesOnly` and `.recording` through the same workspace |
| `CasablancaTests/MeetingStartFlowTests.swift` | Cover routing, entry-action visibility, manual-meeting defaults, and workspace presentation behavior |
| `Casablanca.xcodeproj/project.pbxproj` | Add `MeetingStartFlowTests.swift` to the `CasablancaTests` target |

## Test Commands

- Targeted unit tests: `xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -destination 'platform=macOS' -only-testing:CasablancaTests/MeetingStartFlowTests -only-testing:CasablancaTests/MeetingWorkspacePresentationTests`
- Full regression suite: `xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -destination 'platform=macOS'`

### Task 1: Add Routing And Launch-Action Coverage

**Files:**
- Create: `CasablancaTests/MeetingStartFlowTests.swift`
- Modify: `Casablanca.xcodeproj/project.pbxproj`
- Modify: `Casablanca/Models/Meeting.swift`
- Modify: `Casablanca/Views/Components/MeetingCardView.swift`
- Modify: `Casablanca/Views/MenuBarMeetingView.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import SwiftData
import XCTest
@testable import Casablanca

@MainActor
final class MeetingStartFlowTests: XCTestCase {
    func testRecordingStatusUsesWorkspacePresentation() {
        XCTAssertEqual(MeetingStatus.recording.detailPresentation, .workspace)
        XCTAssertEqual(MeetingStatus.notesOnly.detailPresentation, .workspace)
        XCTAssertEqual(MeetingStatus.processing.detailPresentation, .processing)
        XCTAssertEqual(MeetingStatus.completed.detailPresentation, .completed)
    }

    func testUpcomingMeetingsShowRecordingAndNotesButtons() {
        let layout = MeetingEntryActionLayout(isPast: false)
        XCTAssertEqual(layout.visibleActions, [.startRecording, .takeNotes])
        XCTAssertEqual(layout.contextMenuActions, [.startRecording, .takeNotes, .viewDetails])
    }

    func testPastMeetingsKeepDetailsPrimary() {
        let layout = MeetingEntryActionLayout(isPast: true)
        XCTAssertEqual(layout.visibleActions, [.viewDetails])
        XCTAssertEqual(layout.contextMenuActions, [.takeNotes, .viewDetails])
    }

    func testBeginManualMeetingCreatesNotesOnlyMeeting() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let viewModel = MeetingListViewModel(calendarService: CalendarService())
        viewModel.setModelContext(context)

        viewModel.beginManualMeeting(title: "Weekly Sync")

        let meetings = try context.fetch(FetchDescriptor<Meeting>())
        XCTAssertEqual(meetings.count, 1)
        XCTAssertEqual(meetings[0].title, "Weekly Sync")
        XCTAssertEqual(meetings[0].status, .notesOnly)
        XCTAssertEqual(viewModel.selectedMeeting?.id, meetings[0].id)
    }

    func testBeginRecordingPreservesExistingUserNotes() {
        let meeting = Meeting(title: "Design Review", date: .now, status: .notesOnly)
        meeting.userNotes = "Already typed before recording"

        let viewModel = MeetingListViewModel(calendarService: CalendarService())
        viewModel.beginRecording(for: meeting)

        XCTAssertEqual(meeting.status, .recording)
        XCTAssertEqual(meeting.userNotes, "Already typed before recording")
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Meeting.self, TodoItem.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
```

- [ ] **Step 2: Add the new test file to the Xcode test target**

```text
Update `Casablanca.xcodeproj/project.pbxproj` so `MeetingStartFlowTests.swift` appears in the `CasablancaTests` group and the `CasablancaTests` Sources build phase.
```

- [ ] **Step 3: Run the targeted test command to verify the new tests fail for the right reason**

Run: `xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -destination 'platform=macOS' -only-testing:CasablancaTests/MeetingStartFlowTests`

Expected: FAIL at compile time because `MeetingStatus.detailPresentation` and `MeetingEntryActionLayout` do not exist yet.

- [ ] **Step 4: Implement the routing and launch-action helpers**

Add the route mapping in `Casablanca/Models/Meeting.swift`:

```swift
enum MeetingDetailPresentation: Equatable {
    case workspace
    case processing
    case completed
}

extension MeetingStatus {
    var detailPresentation: MeetingDetailPresentation {
        switch self {
        case .upcoming, .notesOnly, .recording:
            return .workspace
        case .processing:
            return .processing
        case .completed:
            return .completed
        }
    }
}
```

Add the shared launch-action model near the top of `Casablanca/Views/Components/MeetingCardView.swift`:

```swift
enum MeetingEntryAction: String, CaseIterable {
    case startRecording
    case takeNotes
    case viewDetails

    var title: String {
        switch self {
        case .startRecording: return "Start Recording"
        case .takeNotes: return "Take Notes"
        case .viewDetails: return "View Details"
        }
    }

    var systemImage: String {
        switch self {
        case .startRecording: return "record.circle"
        case .takeNotes: return "pencil.line"
        case .viewDetails: return "doc.text"
        }
    }
}

struct MeetingEntryActionLayout {
    let isPast: Bool

    var visibleActions: [MeetingEntryAction] {
        isPast ? [.viewDetails] : [.startRecording, .takeNotes]
    }

    var contextMenuActions: [MeetingEntryAction] {
        isPast ? [.takeNotes, .viewDetails] : [.startRecording, .takeNotes, .viewDetails]
    }
}
```

Replace the single primary button in `MeetingCardView` with shared visible actions:

```swift
private var actionLayout: MeetingEntryActionLayout {
    MeetingEntryActionLayout(isPast: isPast)
}

private var actionButtons: some View {
    HStack(spacing: CasaSpace.sm) {
        ForEach(actionLayout.visibleActions, id: \.rawValue) { action in
            Button {
                perform(action)
            } label: {
                Label(action.title, systemImage: action.systemImage)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(action == .startRecording || action == .viewDetails
                ? PrimaryButtonStyle()
                : SecondaryButtonStyle())
        }
    }
}

private func perform(_ action: MeetingEntryAction) {
    switch action {
    case .startRecording:
        onStartRecording()
    case .takeNotes:
        onTakeNotes()
    case .viewDetails:
        onViewDetails()
    }
}
```

Then use the same `MeetingEntryActionLayout(isPast: false)` inside `MenuBarMeetingView.eventCard(for:)`:

```swift
let actionLayout = MeetingEntryActionLayout(isPast: false)

ForEach(actionLayout.visibleActions, id: \.rawValue) { action in
    Button {
        switch action {
        case .startRecording:
            viewModel.beginRecording(for: event)
        case .takeNotes:
            viewModel.beginNotes(for: event)
        case .viewDetails:
            viewModel.openMeetingDetails(for: event)
        }
        openMainWindow()
    } label: {
        Label(action.title, systemImage: action.systemImage)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    .buttonStyle(action == .takeNotes ? SecondaryButtonStyle() : PrimaryButtonStyle())
}
```

- [ ] **Step 5: Re-run the targeted tests and confirm they pass**

Run: `xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -destination 'platform=macOS' -only-testing:CasablancaTests/MeetingStartFlowTests`

Expected: PASS with `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit the routing and launch-action changes**

```bash
git add \
  Casablanca/Models/Meeting.swift \
  Casablanca/Views/Components/MeetingCardView.swift \
  Casablanca/Views/MenuBarMeetingView.swift \
  CasablancaTests/MeetingStartFlowTests.swift \
  Casablanca.xcodeproj/project.pbxproj
git commit -m "feat: add notes-first meeting launch actions"
```

### Task 2: Unify The Notes And Recording Workspace

**Files:**
- Modify: `CasablancaTests/MeetingStartFlowTests.swift`
- Modify: `Casablanca/Views/NotesEditorView.swift`
- Modify: `Casablanca/Views/ContentView.swift`
- Modify: `Casablanca/Views/RecordingView.swift`

- [ ] **Step 1: Append failing tests for workspace presentation**

Add these tests to `CasablancaTests/MeetingStartFlowTests.swift` below the existing class:

```swift
@MainActor
final class MeetingWorkspacePresentationTests: XCTestCase {
    func testNotesOnlyWorkspaceShowsStartRecordingButton() {
        let meeting = Meeting(title: "Weekly Sync", date: .now, status: .notesOnly)
        let presentation = MeetingWorkspacePresentation(
            meeting: meeting,
            activeMeetingID: nil,
            isRecording: false,
            isPreparing: false
        )

        XCTAssertFalse(presentation.showsRecordingChrome)
        XCTAssertTrue(presentation.showsStartRecordingButton)
        XCTAssertFalse(presentation.showsTimestampedTools)
        XCTAssertFalse(presentation.backButtonDisabled)
    }

    func testActiveRecordingWorkspaceShowsRecordingChrome() {
        let meeting = Meeting(title: "Weekly Sync", date: .now, status: .recording)
        let presentation = MeetingWorkspacePresentation(
            meeting: meeting,
            activeMeetingID: meeting.id,
            isRecording: true,
            isPreparing: false
        )

        XCTAssertTrue(presentation.showsRecordingChrome)
        XCTAssertFalse(presentation.showsStartRecordingButton)
        XCTAssertTrue(presentation.showsTimestampedTools)
        XCTAssertTrue(presentation.backButtonDisabled)
    }

    func testPreparingWorkspaceKeepsUserInSameScreen() {
        let meeting = Meeting(title: "Weekly Sync", date: .now, status: .recording)
        let presentation = MeetingWorkspacePresentation(
            meeting: meeting,
            activeMeetingID: meeting.id,
            isRecording: false,
            isPreparing: true
        )

        XCTAssertTrue(presentation.showsRecordingChrome)
        XCTAssertFalse(presentation.showsTimestampedTools)
        XCTAssertFalse(presentation.showsStartRecordingButton)
    }
}
```

- [ ] **Step 2: Run the targeted tests to verify they fail**

Run: `xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -destination 'platform=macOS' -only-testing:CasablancaTests/MeetingStartFlowTests -only-testing:CasablancaTests/MeetingWorkspacePresentationTests`

Expected: FAIL at compile time because `MeetingWorkspacePresentation` does not exist yet.

- [ ] **Step 3: Add the workspace presentation helper and make `NotesEditorView` own the live recording flow**

At the top of `Casablanca/Views/NotesEditorView.swift`, add the new helper:

```swift
struct MeetingWorkspacePresentation {
    let meeting: Meeting
    let activeMeetingID: UUID?
    let isRecording: Bool
    let isPreparing: Bool

    var isActiveMeeting: Bool {
        activeMeetingID == meeting.id
    }

    var showsRecordingChrome: Bool {
        isActiveMeeting && (isPreparing || isRecording || meeting.status == .recording)
    }

    var showsTimestampedTools: Bool {
        isActiveMeeting && isRecording
    }

    var showsStartRecordingButton: Bool {
        !showsRecordingChrome
    }

    var backButtonDisabled: Bool {
        isActiveMeeting && isRecording
    }

    var stateLabel: String {
        isRecording ? "Recording" : "Preparing"
    }
}
```

Change the `NotesEditorView` signature and state so it can start recording inline and preserve the current notes mode:

```swift
struct NotesEditorView: View {
    private enum NotesMode { case timestamped, freeform }

    @Bindable var meeting: Meeting
    @Bindable var recordingService: AudioRecordingService
    let autoStartRecording: Bool
    let onBack: () -> Void

    @State private var saveTask: Task<Void, Never>?
    @State private var didTriggerStart = false
    @State private var noteText = ""
    @State private var notesMode: NotesMode
    @State private var newTodoText = ""
    @State private var showingAudioSettings = false
    @FocusState private var isNoteFieldFocused: Bool
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        meeting: Meeting,
        recordingService: AudioRecordingService,
        autoStartRecording: Bool = false,
        onBack: @escaping () -> Void
    ) {
        self.meeting = meeting
        self.recordingService = recordingService
        self.autoStartRecording = autoStartRecording
        self.onBack = onBack
        _notesMode = State(initialValue: autoStartRecording ? .timestamped : .freeform)
    }
}
```

Use a computed presentation inside `body`, keep the freeform editor path for notes-only mode, and reuse the current recording sections when recording is preparing or active:

```swift
private var presentation: MeetingWorkspacePresentation {
    MeetingWorkspacePresentation(
        meeting: meeting,
        activeMeetingID: recordingService.activeMeetingID,
        isRecording: recordingService.isRecording,
        isPreparing: recordingService.isPreparing
    )
}

var body: some View {
    VStack(spacing: 0) {
        if presentation.showsRecordingChrome {
            header
            Divider()
        } else if !meeting.timestampedNotes.isEmpty {
            previousNotesBar
            Divider()
        }

        switch notesMode {
        case .timestamped where presentation.showsTimestampedTools:
            timestampedNotesArea
        default:
            freeformWorkspace
        }

        Divider()
        footer
    }
    .task(id: autoStartRecording) {
        guard autoStartRecording else { return }
        recordingService.refreshInputDevices(forcePreferredSelection: true)
        await startRecordingIfNeeded()
    }
    .alert("Recording Error", isPresented: recordingErrorBinding) {
        Button("Retry") {
            recordingService.clearError()
            didTriggerStart = false
            Task { await startRecordingIfNeeded() }
        }
        Button("Open Privacy Settings") {
            openRelevantPrivacySettings()
        }
        Button("Back to Notes", role: .cancel) {
            meeting.status = .notesOnly
            save()
        }
    } message: {
        Text(recordingService.errorMessage ?? "Unable to start recording.")
    }
}
```

Keep the existing freeform editor visible when recording starts from notes-only mode by leaving `notesMode = .freeform` in the inline start action:

```swift
private func requestRecordingStart() {
    guard !presentation.showsRecordingChrome else { return }
    recordingService.refreshInputDevices(forcePreferredSelection: true)
    Task {
        await startRecordingIfNeeded()
    }
}

private func startRecordingIfNeeded() async {
    guard !didTriggerStart else { return }
    guard recordingService.activeMeetingID == nil || recordingService.activeMeetingID == meeting.id else {
        recordingService.clearError()
        return
    }

    didTriggerStart = true

    do {
        try await recordingService.startRecording(for: meeting)
        meeting.status = .recording
        save()
    } catch {
        didTriggerStart = false
        if meeting.status == .recording {
            meeting.status = .notesOnly
            save()
        }
    }
}
```

Update the footer to switch between `Start Recording` and `Stop Recording` instead of navigating to another screen:

```swift
private var footer: some View {
    HStack {
        if recordingService.isPreparing && presentation.isActiveMeeting {
            ProgressView()
                .controlSize(.small)
        }

        Text("\(meeting.timestampedNotes.count) notes")
            .font(.caption)
            .foregroundStyle(Color.textTertiary)

        Spacer()

        if presentation.showsStartRecordingButton {
            Button(action: requestRecordingStart) {
                Label("Start Recording", systemImage: "record.circle")
            }
            .buttonStyle(PrimaryButtonStyle())
        } else {
            Button {
                Task { await stopRecording() }
            } label: {
                Label("Stop Recording", systemImage: "stop.circle")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!recordingService.isRecording || recordingService.activeMeetingID != meeting.id)
        }

        Button {
            exportNotes()
        } label: {
            Label("Save & Export", systemImage: "square.and.arrow.up")
        }
        .buttonStyle(SecondaryButtonStyle())
        .disabled(meeting.userNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && meeting.timestampedNotes.isEmpty)
    }
    .padding(CasaSpace.lg)
    .background(.bar)
}
```

Add the old recording-only subviews (`header`, `timestampedNotesArea`, `noteInputBar`, `todosArea`, `stopRecording()`, `openRelevantPrivacySettings()`) into `NotesEditorView`, reusing the code that already exists in `RecordingView`.

- [ ] **Step 4: Route both notes-only and recording meetings through the unified workspace**

Update `Casablanca/Views/ContentView.swift` to use `meeting.status.detailPresentation` and always pass the shared `recordingService` into `NotesEditorView`:

```swift
switch meeting.status.detailPresentation {
case .workspace:
    NotesEditorView(
        meeting: meeting,
        recordingService: recordingService,
        autoStartRecording: meeting.status == .recording,
        onBack: {
            viewModel.selectedMeeting = nil
        }
    )
case .processing:
    TranscriptionView(
        meeting: meeting,
        transcriptionService: transcriptionService,
        onComplete: {},
        onCancel: {
            meeting.status = .completed
            try? modelContext.save()
        }
    )
case .completed:
    RecordedMeetingView(
        meeting: meeting,
        onRecordAgain: {
            viewModel.beginRecording(for: meeting)
        },
        onTranscribe: {
            meeting.status = .processing
            try? modelContext.save()
        }
    )
}
```

Reduce `Casablanca/Views/RecordingView.swift` to a thin compatibility wrapper:

```swift
import SwiftUI

struct RecordingView: View {
    @Bindable var meeting: Meeting
    @Bindable var recordingService: AudioRecordingService
    let onBack: () -> Void

    var body: some View {
        NotesEditorView(
            meeting: meeting,
            recordingService: recordingService,
            autoStartRecording: true,
            onBack: onBack
        )
    }
}
```

- [ ] **Step 5: Run the targeted tests, then the full regression suite**

Run: `xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -destination 'platform=macOS' -only-testing:CasablancaTests/MeetingStartFlowTests -only-testing:CasablancaTests/MeetingWorkspacePresentationTests`

Expected: PASS with `** TEST SUCCEEDED **`.

Run: `xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -destination 'platform=macOS'`

Expected: PASS with `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit the unified workspace changes**

```bash
git add \
  Casablanca/Views/NotesEditorView.swift \
  Casablanca/Views/ContentView.swift \
  Casablanca/Views/RecordingView.swift \
  CasablancaTests/MeetingStartFlowTests.swift
git commit -m "feat: keep notes visible when recording starts"
```

## Final Verification

- [ ] **Step 1: Build the app cleanly**

Run: `xcodebuild build -project Casablanca.xcodeproj -scheme Casablanca -destination 'platform=macOS'`

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 2: Perform one manual smoke check**

Run the app from Xcode or the built product and verify this exact path:

```text
1. Open a calendar meeting from the dashboard.
2. Confirm both "Start Recording" and "Take Notes" are visible.
3. Click "Take Notes", type "first manual note".
4. Click "Start Recording" from the notes workspace.
5. Confirm the same screen stays open and "first manual note" is still visible.
6. Stop recording and confirm the meeting moves into processing/completed flow as before.
```
