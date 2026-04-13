# Delete Meetings From Sidebar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a sidebar context-menu delete action for recent meetings that removes the meeting record, its related app data, and any saved recording file.

**Architecture:** Keep destructive behavior centralized in `MeetingListViewModel` so file deletion, SwiftData deletion, and selection cleanup happen in one transaction-like flow. `SidebarView` stays thin: it decides which row is pending deletion, shows confirmation UI, and calls the view model. Small helper types in existing files provide testable coverage for context-menu availability and deletion behavior without adding UI test infrastructure.

**Tech Stack:** SwiftUI, SwiftData, XCTest, `xcodebuild`

---

## File Structure

| File | Responsibility |
| --- | --- |
| `Casablanca/ViewModels/MeetingListViewModel.swift` | Add meeting deletion API, recording-file removal seam, and selection fallback logic |
| `Casablanca/Views/SidebarView.swift` | Add sidebar row delete context menu, confirmation dialog state, and a small testable action helper |
| `CasablancaTests/MeetingStartFlowTests.swift` | Add deletion-focused XCTest coverage for persistence, file-removal behavior, and sidebar delete-action availability |
| `Casablanca.xcodeproj/project.pbxproj` | No new file expected if tests stay in `MeetingStartFlowTests.swift`; only modify if the engineer chooses to split tests into a separate file |

## Test Commands

- Targeted deletion tests: `xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -destination 'platform=macOS' -only-testing:CasablancaTests/MeetingDeletionTests -only-testing:CasablancaTests/SidebarMeetingRowActionTests`
- Full regression suite: `xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -destination 'platform=macOS'`
- Build verification: `xcodebuild build -project Casablanca.xcodeproj -scheme Casablanca -destination 'platform=macOS'`

### Task 1: Add Deletion Behavior To The View Model

**Files:**
- Modify: `CasablancaTests/MeetingStartFlowTests.swift`
- Modify: `Casablanca/ViewModels/MeetingListViewModel.swift`

- [ ] **Step 1: Write the failing deletion tests**

Append these tests to `CasablancaTests/MeetingStartFlowTests.swift`:

```swift
@MainActor
final class MeetingDeletionTests: XCTestCase {
    func testDeleteMeetingRemovesPersistedMeetingAndClearsSelection() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let viewModel = MeetingListViewModel(
            calendarService: CalendarService(),
            removeItemAtURL: { _ in }
        )
        viewModel.setModelContext(context)

        let meeting = Meeting(title: "Delete Me", date: .now, status: .completed)
        context.insert(meeting)
        try context.save()
        viewModel.selectedMeeting = meeting

        try viewModel.deleteMeeting(meeting)

        let meetings = try context.fetch(FetchDescriptor<Meeting>())
        XCTAssertTrue(meetings.isEmpty)
        XCTAssertEqual(viewModel.sidebarSelection, .dashboard)
    }

    func testDeleteMeetingSucceedsWhenRecordingFileIsAlreadyMissing() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let missingURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let viewModel = MeetingListViewModel(calendarService: CalendarService())
        viewModel.setModelContext(context)

        let meeting = Meeting(title: "Missing File", date: .now, status: .completed)
        meeting.recordingFileURL = missingURL.path
        context.insert(meeting)
        try context.save()

        try viewModel.deleteMeeting(meeting)

        let meetings = try context.fetch(FetchDescriptor<Meeting>())
        XCTAssertTrue(meetings.isEmpty)
    }

    func testDeleteMeetingThrowsWhenRecordingRemovalFails() throws {
        enum TestError: Error { case removalFailed }

        let container = try makeContainer()
        let context = ModelContext(container)
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let viewModel = MeetingListViewModel(
            calendarService: CalendarService(),
            removeItemAtURL: { _ in throw TestError.removalFailed }
        )
        viewModel.setModelContext(context)

        let meeting = Meeting(title: "Protected File", date: .now, status: .completed)
        meeting.recordingFileURL = fileURL.path
        context.insert(meeting)
        try context.save()

        XCTAssertThrowsError(try viewModel.deleteMeeting(meeting))

        let meetings = try context.fetch(FetchDescriptor<Meeting>())
        XCTAssertEqual(meetings.count, 1)
        XCTAssertEqual(meetings.first?.id, meeting.id)
    }

    func testDeleteMeetingWithoutRecordingPathSucceeds() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let viewModel = MeetingListViewModel(calendarService: CalendarService())
        viewModel.setModelContext(context)

        let meeting = Meeting(title: "Notes Only", date: .now, status: .notesOnly)
        context.insert(meeting)
        try context.save()

        try viewModel.deleteMeeting(meeting)

        let meetings = try context.fetch(FetchDescriptor<Meeting>())
        XCTAssertTrue(meetings.isEmpty)
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Meeting.self, TodoItem.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
```

- [ ] **Step 2: Run the targeted deletion tests to verify they fail**

Run: `xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -destination 'platform=macOS' -only-testing:CasablancaTests/MeetingDeletionTests`

Expected: FAIL at compile time because `MeetingListViewModel` does not yet support `removeItemAtURL` injection or `deleteMeeting(_:)`.

- [ ] **Step 3: Implement the minimal deletion API**

Update `Casablanca/ViewModels/MeetingListViewModel.swift` to add the file-removal seam and delete method:

```swift
@Observable
final class MeetingListViewModel {
    private let calendarService: CalendarService
    private let removeItemAtURL: (URL) throws -> Void
    private var modelContext: ModelContext?
    var meetingSearchText = ""

    init(
        calendarService: CalendarService,
        removeItemAtURL: @escaping (URL) throws -> Void = { url in
            try FileManager.default.removeItem(at: url)
        }
    ) {
        self.calendarService = calendarService
        self.removeItemAtURL = removeItemAtURL
    }

    func deleteMeeting(_ meeting: Meeting) throws {
        guard let modelContext else { return }

        if let path = meeting.recordingFileURL {
            let recordingURL = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: recordingURL.path) {
                try removeItemAtURL(recordingURL)
            }
        }

        modelContext.delete(meeting)

        if case .meeting(let id) = sidebarSelection, id == meeting.id {
            sidebarSelection = .dashboard
        }

        try modelContext.save()
    }
}
```

- [ ] **Step 4: Re-run the targeted deletion tests and confirm they pass**

Run: `xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -destination 'platform=macOS' -only-testing:CasablancaTests/MeetingDeletionTests`

Expected: PASS with `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit the view-model deletion behavior**

```bash
git add \
  Casablanca/ViewModels/MeetingListViewModel.swift \
  CasablancaTests/MeetingStartFlowTests.swift
git commit -m "feat: add meeting deletion behavior"
```

### Task 2: Add Sidebar Delete Action And Confirmation

**Files:**
- Modify: `CasablancaTests/MeetingStartFlowTests.swift`
- Modify: `Casablanca/Views/SidebarView.swift`

- [ ] **Step 1: Write the failing sidebar action tests**

Append these tests to `CasablancaTests/MeetingStartFlowTests.swift`:

```swift
final class SidebarMeetingRowActionTests: XCTestCase {
    func testRecentMeetingRowsExposeDeleteAction() {
        let actions = SidebarMeetingRowActions(status: .completed)
        XCTAssertEqual(actions.contextMenuActions, [.deleteMeeting])
    }

    func testUpcomingMeetingsDoNotExposeDeleteAction() {
        let actions = SidebarMeetingRowActions(status: .upcoming)
        XCTAssertTrue(actions.contextMenuActions.isEmpty)
    }
}
```

- [ ] **Step 2: Run the targeted sidebar tests to verify they fail**

Run: `xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -destination 'platform=macOS' -only-testing:CasablancaTests/SidebarMeetingRowActionTests`

Expected: FAIL at compile time because `SidebarMeetingRowActions` does not exist yet.

- [ ] **Step 3: Add the sidebar delete action and confirmation dialog**

At the top of `Casablanca/Views/SidebarView.swift`, add a small helper that keeps the row behavior testable:

```swift
enum SidebarMeetingRowAction: Equatable {
    case deleteMeeting
}

struct SidebarMeetingRowActions {
    let status: MeetingStatus

    var contextMenuActions: [SidebarMeetingRowAction] {
        status == .upcoming ? [] : [.deleteMeeting]
    }
}
```

Expand `SidebarView` to own delete-confirmation state:

```swift
@State private var meetingPendingDeletion: Meeting?
@State private var deletionErrorMessage: String?
```

Pass a delete callback into each row:

```swift
ForEach(recentMeetings) { meeting in
    SidebarMeetingRow(
        meeting: meeting,
        onDeleteRequest: {
            meetingPendingDeletion = meeting
        }
    )
    .tag(SidebarDestination.meeting(meeting.id))
}
```

Update `SidebarMeetingRow` to accept the callback and render the context menu:

```swift
struct SidebarMeetingRow: View {
    let meeting: Meeting
    let onDeleteRequest: () -> Void

    private var actions: SidebarMeetingRowActions {
        SidebarMeetingRowActions(status: meeting.status)
    }

    var body: some View {
        HStack(spacing: CasaSpace.sm) {
            statusIcon
                .frame(width: 14)

            VStack(alignment: .leading, spacing: CasaSpace.xxs) {
                Text(meeting.title)
                    .font(.body)
                    .lineLimit(1)

                Text(formattedDate)
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)
            }

            Spacer()
        }
        .contextMenu {
            ForEach(actions.contextMenuActions, id: \.self) { action in
                switch action {
                case .deleteMeeting:
                    Button("Delete Meeting…", role: .destructive, action: onDeleteRequest)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(meeting.title), \(statusAccessibilityLabel), \(formattedDate)")
    }
}
```

Add the confirmation dialog and error alert to `SidebarView`:

```swift
.confirmationDialog(
    meetingPendingDeletion.map { "Delete \"\($0.title)\"?" } ?? "Delete Meeting?",
    isPresented: Binding(
        get: { meetingPendingDeletion != nil },
        set: { newValue in
            if !newValue { meetingPendingDeletion = nil }
        }
    ),
    titleVisibility: .visible
) {
    Button("Delete Meeting", role: .destructive) {
        confirmDeleteMeeting()
    }
    Button("Cancel", role: .cancel) {
        meetingPendingDeletion = nil
    }
} message: {
    Text("This removes the meeting, notes, transcript, summary, to-dos, and saved recording from Casablanca.")
}
.alert("Unable to Delete Meeting", isPresented: deletionErrorBinding) {
    Button("OK", role: .cancel) {
        deletionErrorMessage = nil
    }
} message: {
    Text(deletionErrorMessage ?? "Unknown error")
}
```

Add the helper method in `SidebarView`:

```swift
private var deletionErrorBinding: Binding<Bool> {
    Binding(
        get: { deletionErrorMessage != nil },
        set: { newValue in
            if !newValue { deletionErrorMessage = nil }
        }
    )
}

private func confirmDeleteMeeting() {
    guard let meeting = meetingPendingDeletion else { return }

    do {
        try viewModel.deleteMeeting(meeting)
        meetingPendingDeletion = nil
        selection = viewModel.sidebarSelection
    } catch {
        deletionErrorMessage = error.localizedDescription
    }
}
```

- [ ] **Step 4: Re-run the targeted sidebar tests and then the full suite**

Run: `xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -destination 'platform=macOS' -only-testing:CasablancaTests/SidebarMeetingRowActionTests -only-testing:CasablancaTests/MeetingDeletionTests`

Expected: PASS with `** TEST SUCCEEDED **`.

Run: `xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -destination 'platform=macOS'`

Expected: PASS with `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit the sidebar deletion UI**

```bash
git add \
  Casablanca/Views/SidebarView.swift \
  CasablancaTests/MeetingStartFlowTests.swift
git commit -m "feat: add sidebar meeting deletion"
```

## Final Verification

- [ ] **Step 1: Build the app cleanly**

Run: `xcodebuild build -project Casablanca.xcodeproj -scheme Casablanca -destination 'platform=macOS'`

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 2: Perform one manual smoke check**

Verify this exact path in the running app:

```text
1. Open the app and ensure there is at least one recent meeting in the left sidebar.
2. Right-click the recent meeting row.
3. Confirm "Delete Meeting…" is present.
4. Choose it and confirm the destructive dialog text mentions meeting, notes, transcript, summary, to-dos, and saved recording.
5. Confirm the meeting disappears from the sidebar after deletion.
6. If that meeting was selected, confirm the detail pane falls back to the dashboard.
```
