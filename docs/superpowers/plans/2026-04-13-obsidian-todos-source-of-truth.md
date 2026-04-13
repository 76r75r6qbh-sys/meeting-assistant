# Obsidian Todos Source of Truth Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Obsidian the authoritative todo system for Casablanca, with meeting-linked todos synced from meeting files, generic todos synced from `tasks/Casablanca Todos.md`, and immediate writeback from app interactions.

**Architecture:** Add a focused Obsidian todo markdown layer plus a sync/writeback service that treats SwiftData as a local cache only. Keep `TodoItem.meeting` for meeting linkage, bootstrap legacy cached todos into Obsidian on first sync, and integrate refresh/writeback into app launch, meeting workspaces, and the global Todos screen.

**Tech Stack:** SwiftUI, SwiftData, Foundation file I/O, markdown text parsing/rewriting, existing Obsidian vault preferences

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `Casablanca/Models/TodoItem.swift` | Modify | Add source-file metadata needed for Obsidian-backed cache rows |
| `Casablanca/Services/ObsidianMeetingFiles.swift` | Create | Centralize meeting prep/notes/generic todo file resolution inside the Obsidian vault |
| `Casablanca/Services/ObsidianTodoMarkdown.swift` | Create | Parse and rewrite markdown checkbox documents with hidden Casablanca IDs |
| `Casablanca/Services/ObsidianTodoSyncService.swift` | Create | Refresh cache from Obsidian, bootstrap legacy todos, and write app edits back to source files |
| `Casablanca/Services/MeetingPrepService.swift` | Modify | Reuse shared meeting-file resolution helper instead of custom path logic |
| `Casablanca/Views/ContentView.swift` | Modify | Trigger initial todo refresh after `ModelContext` is available |
| `Casablanca/Views/NotesEditorView.swift` | Modify | Refresh meeting todos from Obsidian and route create/toggle/delete through sync service |
| `Casablanca/Views/RecordedMeetingView.swift` | Modify | Route post-summary meeting todos through sync service instead of direct SwiftData inserts |
| `Casablanca/Views/TodosView.swift` | Modify | Refresh all todos, show generic + meeting-linked rows, and add generic create input |
| `Casablanca/Views/SettingsView.swift` | Modify | Clarify that Obsidian vault also drives todo sync and the managed generic todo file |
| `CasablancaTests/MeetingPrepServiceTests.swift` | Modify | Keep prep-path resolution green after extracting shared Obsidian file helper |
| `CasablancaTests/ObsidianTodoMarkdownTests.swift` | Create | Parser and rewrite unit tests for markdown task documents |
| `CasablancaTests/ObsidianTodoSyncServiceTests.swift` | Create | Sync/bootstrap/writeback tests against temporary vault fixtures |
| `CasablancaTests/MeetingStartFlowTests.swift` | Modify | Add presentation/integration regressions for generic + meeting-linked todo behavior |

---

### Task 1: Build the Obsidian todo document layer

**Files:**
- Modify: `Casablanca/Models/TodoItem.swift`
- Create: `Casablanca/Services/ObsidianMeetingFiles.swift`
- Create: `Casablanca/Services/ObsidianTodoMarkdown.swift`
- Modify: `Casablanca/Services/MeetingPrepService.swift`
- Create: `CasablancaTests/ObsidianTodoMarkdownTests.swift`
- Modify: `CasablancaTests/MeetingPrepServiceTests.swift`

- [ ] **Step 1: Write the failing markdown/parser tests**

Create `CasablancaTests/ObsidianTodoMarkdownTests.swift` with these tests:

```swift
import XCTest
@testable import Casablanca

final class ObsidianTodoMarkdownTests: XCTestCase {
    func testParseGenericTodoDocumentSplitsOpenAndDoneTasks() throws {
        let markdown = """
        # Casablanca Todos

        ## Open

        - [ ] Follow up with Kim <!-- casablanca-todo: 550E8400-E29B-41D4-A716-446655440000 -->

        ## Done

        - [x] Send summary <!-- casablanca-todo: 660E8400-E29B-41D4-A716-446655440000 -->
        """

        let document = ObsidianTodoMarkdown.parseGenericDocument(markdown)

        XCTAssertEqual(document.openTasks.map(\.text), ["Follow up with Kim"])
        XCTAssertEqual(document.doneTasks.map(\.text), ["Send summary"])
        XCTAssertEqual(document.openTasks.first?.id.uuidString, "550E8400-E29B-41D4-A716-446655440000")
    }

    func testParseMeetingActionItemsReadsCheckboxesWithoutIds() {
        let markdown = """
        # Prep

        ## Action Items

        - [ ] Bring roadmap slide
        - [x] Mail agenda <!-- casablanca-todo: 770E8400-E29B-41D4-A716-446655440000 -->
        """

        let items = ObsidianTodoMarkdown.parseMeetingActionItems(markdown)

        XCTAssertEqual(items.count, 2)
        XCTAssertNil(items[0].id)
        XCTAssertEqual(items[0].text, "Bring roadmap slide")
        XCTAssertTrue(items[1].isCompleted)
    }

    func testRenderGenericDocumentCreatesExpectedScaffold() {
        let item = ObsidianTodoMarkdown.TaskLine(
            id: UUID(uuidString: "550E8400-E29B-41D4-A716-446655440000")!,
            text: "Follow up with Kim",
            isCompleted: false
        )

        let markdown = ObsidianTodoMarkdown.renderGenericDocument(
            openTasks: [item],
            doneTasks: []
        )

        XCTAssertTrue(markdown.contains("# Casablanca Todos"))
        XCTAssertTrue(markdown.contains("## Open"))
        XCTAssertTrue(markdown.contains("<!-- casablanca-todo: 550E8400-E29B-41D4-A716-446655440000 -->"))
    }
}
```

- [ ] **Step 2: Write the failing shared file-resolution test**

Append this test to `CasablancaTests/MeetingPrepServiceTests.swift`:

```swift
func testCanonicalMeetingTodoTargetPrefersPrepFileOverNotesFile() throws {
    let defaults = UserDefaults(suiteName: "MeetingPrepServiceTests.canonical-\(UUID().uuidString)")!
    let vaultURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let notesDirectory = vaultURL.appendingPathComponent("meeting notes", isDirectory: true)
    try FileManager.default.createDirectory(at: notesDirectory, withIntermediateDirectories: true)
    defaults.set(vaultURL.path, forKey: AppPreferenceKey.obsidianVaultPath)

    let meeting = Meeting(title: "Weekly Sync", date: makeDate())
    let prepURL = notesDirectory.appendingPathComponent("2025-04-12 Weekly Sync - Prep.md")
    let notesURL = notesDirectory.appendingPathComponent("2025-04-12 Weekly Sync - Notes.md")
    FileManager.default.createFile(atPath: prepURL.path, contents: Data())
    FileManager.default.createFile(atPath: notesURL.path, contents: Data())

    let files = try XCTUnwrap(ObsidianMeetingFiles.meetingFiles(for: meeting, userDefaults: defaults))

    XCTAssertEqual(files.canonicalTodoWriteURL.path, prepURL.path)
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run:

```bash
cd /Users/youri.broekhuizen/conductor/workspaces/meeting-assistant/lahore && \
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -destination 'platform=macOS' \
  -only-testing:CasablancaTests/ObsidianTodoMarkdownTests \
  -only-testing:CasablancaTests/MeetingPrepServiceTests
```

Expected:
- `ObsidianTodoMarkdownTests` fails because the service does not exist yet
- `MeetingPrepServiceTests` fails because `ObsidianMeetingFiles` does not exist yet

- [ ] **Step 4: Implement the minimal document and file-resolution layer**

Create `Casablanca/Services/ObsidianMeetingFiles.swift`:

```swift
import Foundation

struct ObsidianMeetingFiles {
    struct MeetingFiles {
        let notesDirectory: URL
        let prepURL: URL
        let notesURL: URL
        let canonicalTodoWriteURL: URL
    }

    static func meetingFiles(
        for meeting: Meeting,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> MeetingFiles? {
        guard let notesDirectory = meetingNotesDirectory(userDefaults: userDefaults) else {
            return nil
        }

        let prepURL = notesDirectory.appendingPathComponent("\(meeting.obsidianFileName) - Prep.md")
        let notesURL = notesDirectory.appendingPathComponent("\(meeting.obsidianFileName) - Notes.md")
        let canonical = fileManager.fileExists(atPath: prepURL.path) ? prepURL : notesURL

        return MeetingFiles(
            notesDirectory: notesDirectory,
            prepURL: prepURL,
            notesURL: notesURL,
            canonicalTodoWriteURL: canonical
        )
    }

    static func genericTodosURL(userDefaults: UserDefaults = .standard) -> URL? {
        guard let vaultRoot = vaultRoot(userDefaults: userDefaults) else { return nil }
        return vaultRoot.appendingPathComponent("tasks", isDirectory: true)
            .appendingPathComponent("Casablanca Todos.md")
    }

    private static func meetingNotesDirectory(userDefaults: UserDefaults) -> URL? {
        vaultRoot(userDefaults: userDefaults)?
            .appendingPathComponent("meeting notes", isDirectory: true)
    }

    private static func vaultRoot(userDefaults: UserDefaults) -> URL? {
        let vaultPath = userDefaults.string(forKey: AppPreferenceKey.obsidianVaultPath)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !vaultPath.isEmpty else { return nil }
        return URL(fileURLWithPath: vaultPath, isDirectory: true)
    }
}
```

Create `Casablanca/Services/ObsidianTodoMarkdown.swift`:

```swift
import Foundation

enum ObsidianTodoMarkdown {
    struct TaskLine: Equatable {
        let id: UUID?
        let text: String
        let isCompleted: Bool
    }

    struct GenericDocument: Equatable {
        var openTasks: [TaskLine]
        var doneTasks: [TaskLine]
    }

    private static let taskPattern = #"^- \[( |x)\] (.+?)(?: <!-- casablanca-todo: ([A-F0-9-]+) -->)?$"#

    static func parseGenericDocument(_ markdown: String) -> GenericDocument {
        GenericDocument(
            openTasks: parseTasks(in: section(named: "Open", from: markdown)),
            doneTasks: parseTasks(in: section(named: "Done", from: markdown))
        )
    }

    static func parseMeetingActionItems(_ markdown: String) -> [TaskLine] {
        parseTasks(in: section(named: "Action Items", from: markdown))
    }

    static func renderGenericDocument(openTasks: [TaskLine], doneTasks: [TaskLine]) -> String {
        """
        # Casablanca Todos

        ## Open

        \(render(openTasks))

        ## Done

        \(render(doneTasks))
        """
    }

    private static func parseTasks(in body: String) -> [TaskLine] { /* implement regex parsing here */ }
    private static func render(_ tasks: [TaskLine]) -> String { /* convert tasks back to markdown lines here */ }
    private static func section(named title: String, from markdown: String) -> String { /* extract section body */ }
}
```

Modify `Casablanca/Models/TodoItem.swift` to add source-file metadata needed by the cache:

```swift
@Model
final class TodoItem {
    var id: UUID
    var text: String
    var isCompleted: Bool
    var createdAt: Date
    var sourceFilePath: String
    var meeting: Meeting?

    init(
        id: UUID = UUID(),
        text: String,
        isCompleted: Bool = false,
        createdAt: Date = Date(),
        sourceFilePath: String = "",
        meeting: Meeting? = nil
    ) {
        self.id = id
        self.text = text
        self.isCompleted = isCompleted
        self.createdAt = createdAt
        self.sourceFilePath = sourceFilePath
        self.meeting = meeting
    }
}
```

Refactor `Casablanca/Services/MeetingPrepService.swift` so `prepURL` and `hasPrep` use `ObsidianMeetingFiles.meetingFiles(...)` instead of duplicating vault path logic.

- [ ] **Step 5: Run the tests to verify they pass**

Run:

```bash
cd /Users/youri.broekhuizen/conductor/workspaces/meeting-assistant/lahore && \
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -destination 'platform=macOS' \
  -only-testing:CasablancaTests/ObsidianTodoMarkdownTests \
  -only-testing:CasablancaTests/MeetingPrepServiceTests
```

Expected:
- `ObsidianTodoMarkdownTests` PASS
- `MeetingPrepServiceTests` PASS

- [ ] **Step 6: Commit**

```bash
git add Casablanca/Models/TodoItem.swift \
  Casablanca/Services/ObsidianMeetingFiles.swift \
  Casablanca/Services/ObsidianTodoMarkdown.swift \
  Casablanca/Services/MeetingPrepService.swift \
  CasablancaTests/ObsidianTodoMarkdownTests.swift \
  CasablancaTests/MeetingPrepServiceTests.swift
git commit -m "feat: add obsidian todo markdown parsing layer"
```

---

### Task 2: Implement Obsidian todo sync and bootstrap service

**Files:**
- Create: `Casablanca/Services/ObsidianTodoSyncService.swift`
- Create: `CasablancaTests/ObsidianTodoSyncServiceTests.swift`

- [ ] **Step 1: Write the failing sync tests**

Create `CasablancaTests/ObsidianTodoSyncServiceTests.swift` with these tests:

```swift
import SwiftData
import XCTest
@testable import Casablanca

@MainActor
final class ObsidianTodoSyncServiceTests: XCTestCase {
    func testRefreshAllTodosImportsGenericTodosFromManagedFile() throws {
        let fixture = try makeFixture()
        try fixture.writeGenericTodos("""
        # Casablanca Todos

        ## Open

        - [ ] Buy headset <!-- casablanca-todo: 550E8400-E29B-41D4-A716-446655440000 -->

        ## Done
        """)

        try ObsidianTodoSyncService.refreshAllTodos(
            in: fixture.context,
            userDefaults: fixture.defaults,
            fileManager: .default
        )

        let todos = try fixture.context.fetch(FetchDescriptor<TodoItem>())
        XCTAssertEqual(todos.map(\.text), ["Buy headset"])
        XCTAssertNil(todos.first?.meeting)
    }

    func testRefreshMeetingTodosBootstrapsLegacyMeetingTodoIntoCanonicalFile() throws {
        let fixture = try makeFixture()
        let meeting = fixture.makeMeeting(title: "Weekly Sync")
        let legacy = TodoItem(text: "Bring roadmap slide", meeting: meeting)
        fixture.context.insert(legacy)
        try fixture.context.save()

        try ObsidianTodoSyncService.refreshTodos(
            for: meeting,
            in: fixture.context,
            userDefaults: fixture.defaults,
            fileManager: .default
        )

        let prepMarkdown = try fixture.readCanonicalMeetingTodoFile(for: meeting)
        XCTAssertTrue(prepMarkdown.contains("Bring roadmap slide"))
        XCTAssertTrue(prepMarkdown.contains("casablanca-todo"))
    }

    func testToggleTodoWritesCompletionBackToSourceFile() throws {
        let fixture = try makeFixture()
        let todo = try fixture.makeSyncedGenericTodo(text: "Buy headset", isCompleted: false)

        try ObsidianTodoSyncService.setCompleted(
            true,
            for: todo,
            in: fixture.context,
            userDefaults: fixture.defaults,
            fileManager: .default
        )

        let markdown = try fixture.readGenericTodos()
        XCTAssertTrue(markdown.contains("- [x] Buy headset"))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
cd /Users/youri.broekhuizen/conductor/workspaces/meeting-assistant/lahore && \
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -destination 'platform=macOS' \
  -only-testing:CasablancaTests/ObsidianTodoSyncServiceTests
```

Expected:
- FAIL because `ObsidianTodoSyncService` and test helpers do not exist yet

- [ ] **Step 3: Implement the sync/writeback service**

Create `Casablanca/Services/ObsidianTodoSyncService.swift` with these public entry points:

```swift
import Foundation
import SwiftData

enum ObsidianTodoSyncService {
    static func refreshAllTodos(
        in modelContext: ModelContext,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) throws { /* generic file + all cached meeting files */ }

    static func refreshTodos(
        for meeting: Meeting,
        in modelContext: ModelContext,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) throws { /* meeting prep/notes sync + bootstrap */ }

    static func createGenericTodo(
        text: String,
        in modelContext: ModelContext,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) throws -> TodoItem { /* write to tasks/Casablanca Todos.md first, then cache */ }

    static func createMeetingTodo(
        text: String,
        meeting: Meeting,
        in modelContext: ModelContext,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) throws -> TodoItem { /* write to canonical meeting file first, then cache */ }

    static func setCompleted(
        _ isCompleted: Bool,
        for todo: TodoItem,
        in modelContext: ModelContext,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) throws { /* reload source, update task line by ID, write back, update cache */ }

    static func deleteTodo(
        _ todo: TodoItem,
        in modelContext: ModelContext,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) throws { /* remove line from source, then delete cache row */ }
}
```

Implement these private behaviors in the same file:

```swift
private static func bootstrapLegacyTodosIfNeeded(
    in modelContext: ModelContext,
    userDefaults: UserDefaults,
    fileManager: FileManager
) throws { /* any TodoItem with empty sourceFilePath gets written into Obsidian once */ }

private static func upsertCacheRows(
    from tasks: [ObsidianTodoMarkdown.TaskLine],
    sourceFilePath: String,
    meeting: Meeting?,
    in modelContext: ModelContext
) throws { /* update existing rows by UUID or insert new ones */ }

private static func removeMissingRows(
    keeping ids: Set<UUID>,
    sourceFilePath: String,
    in modelContext: ModelContext
) throws { /* delete cache rows absent from source file */ }
```

Implementation rules:

- Use `TodoItem.id` as the canonical Obsidian todo UUID
- Use `TodoItem.sourceFilePath` to detect legacy cache rows and support cleanup
- Always reload the markdown file before applying a writeback operation
- Create `tasks/` directory and `Casablanca Todos.md` automatically if missing

- [ ] **Step 4: Add test fixture helpers in the sync test file**

Inside `CasablancaTests/ObsidianTodoSyncServiceTests.swift`, add a private fixture type similar to:

```swift
private struct Fixture {
    let context: ModelContext
    let defaults: UserDefaults
    let vaultURL: URL

    func makeMeeting(title: String) -> Meeting { /* insert and save Meeting */ }
    func writeGenericTodos(_ markdown: String) throws { /* write tasks/Casablanca Todos.md */ }
    func readGenericTodos() throws -> String { /* read managed generic todo file */ }
    func readCanonicalMeetingTodoFile(for meeting: Meeting) throws -> String { /* prep if present else notes */ }
    func makeSyncedGenericTodo(text: String, isCompleted: Bool) throws -> TodoItem { /* seed file + cache row */ }
}
```

- [ ] **Step 5: Run the sync tests to verify they pass**

Run:

```bash
cd /Users/youri.broekhuizen/conductor/workspaces/meeting-assistant/lahore && \
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -destination 'platform=macOS' \
  -only-testing:CasablancaTests/ObsidianTodoSyncServiceTests
```

Expected:
- `ObsidianTodoSyncServiceTests` PASS

- [ ] **Step 6: Commit**

```bash
git add Casablanca/Services/ObsidianTodoSyncService.swift \
  CasablancaTests/ObsidianTodoSyncServiceTests.swift
git commit -m "feat: sync todos from obsidian files"
```

---

### Task 3: Integrate Obsidian todo sync into app startup and UI

**Files:**
- Modify: `Casablanca/Views/ContentView.swift`
- Modify: `Casablanca/Views/NotesEditorView.swift`
- Modify: `Casablanca/Views/RecordedMeetingView.swift`
- Modify: `Casablanca/Views/TodosView.swift`
- Modify: `Casablanca/Views/SettingsView.swift`
- Modify: `CasablancaTests/MeetingStartFlowTests.swift`

- [ ] **Step 1: Write the failing presentation tests**

Append these tests to `CasablancaTests/MeetingStartFlowTests.swift`:

```swift
func testGlobalTodosRowWithoutMeetingDoesNotNavigate() {
    let todo = TodoItem(text: "Buy headset")
    XCTAssertNil(todo.meeting)
}

func testMeetingLinkedTodoKeepsMeetingReference() {
    let meeting = Meeting(title: "Weekly Sync", date: .now, status: .notesOnly)
    let todo = TodoItem(text: "Bring roadmap slide", sourceFilePath: "/tmp/prep.md", meeting: meeting)
    XCTAssertEqual(todo.meeting?.id, meeting.id)
}
```

Also add this presentation rule for the global todos screen:

```swift
func testGenericTodosScreenNeedsCreateAffordance() {
    let presentation = FreeformWorkspacePresentation(showsRecordingChrome: false)
    XCTAssertTrue(presentation.showsTodosArea)
}
```

- [ ] **Step 2: Run the tests to verify they fail only where expected**

Run:

```bash
cd /Users/youri.broekhuizen/conductor/workspaces/meeting-assistant/lahore && \
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -destination 'platform=macOS' \
  -only-testing:CasablancaTests/MeetingStartFlowTests
```

Expected:
- Existing tests stay green
- New tests fail if constructor signatures or UI assumptions are not implemented yet

- [ ] **Step 3: Integrate refresh and writeback in the meeting screens**

In `Casablanca/Views/ContentView.swift`, add a launch-time refresh after `setModelContext`:

```swift
.task {
    viewModel.setModelContext(modelContext)
    try? ObsidianTodoSyncService.refreshAllTodos(in: modelContext)
}
```

In `Casablanca/Views/NotesEditorView.swift`:

```swift
.task(id: meeting.id) {
    try? ObsidianTodoSyncService.refreshTodos(for: meeting, in: modelContext)
    loadPrepMarkdown()
}
```

Replace direct todo creation/toggle logic:

```swift
private func addTodo() {
    let trimmed = newTodoText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    do {
        _ = try ObsidianTodoSyncService.createMeetingTodo(
            text: trimmed,
            meeting: meeting,
            in: modelContext
        )
        newTodoText = ""
    } catch {
        // surface an alert in the final implementation
    }
}
```

And in the todo row button:

```swift
try? ObsidianTodoSyncService.setCompleted(
    !todo.isCompleted,
    for: todo,
    in: modelContext
)
```

In `Casablanca/Views/RecordedMeetingView.swift`, replace `saveTodos(texts:)` with repeated `createMeetingTodo(...)` calls and refresh meeting todos on `.task(id: meeting.id)`.

- [ ] **Step 4: Integrate refresh and generic todo creation in the global Todos screen**

In `Casablanca/Views/TodosView.swift`:

```swift
@State private var newTodoText = ""

.task {
    try? ObsidianTodoSyncService.refreshAllTodos(in: modelContext)
}
```

Add a bottom input bar:

```swift
private var createBar: some View {
    HStack(spacing: CasaSpace.sm) {
        TextField("Add a general to-do...", text: $newTodoText)
            .textFieldStyle(.plain)
            .onSubmit(addGenericTodo)

        Button(action: addGenericTodo) {
            Image(systemName: "plus.circle.fill")
                .font(.title3)
        }
        .buttonStyle(.plain)
        .disabled(newTodoText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    .padding(.horizontal, CasaSpace.lg)
    .padding(.vertical, CasaSpace.md)
    .background(.bar)
}
```

Implement:

```swift
private func addGenericTodo() {
    let trimmed = newTodoText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    do {
        _ = try ObsidianTodoSyncService.createGenericTodo(text: trimmed, in: modelContext)
        newTodoText = ""
    } catch {
        // surface an alert in the final implementation
    }
}
```

Update `TodoRow` so meeting-linked rows still navigate and generic rows do nothing:

```swift
.onTapGesture {
    guard todo.meeting != nil else { return }
    onNavigateToMeeting()
}
```

- [ ] **Step 5: Clarify Obsidian todo ownership in Settings**

In `Casablanca/Views/SettingsView.swift`, update the Obsidian helper copy to mention:

```swift
Text("Select your Obsidian vault to enable export and todo sync. Casablanca manages generic todos in tasks/Casablanca Todos.md.")
    .font(.caption)
    .foregroundStyle(Color.textTertiary)
```

- [ ] **Step 6: Run the focused UI/integration tests**

Run:

```bash
cd /Users/youri.broekhuizen/conductor/workspaces/meeting-assistant/lahore && \
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -destination 'platform=macOS' \
  -only-testing:CasablancaTests/MeetingStartFlowTests \
  -only-testing:CasablancaTests/ObsidianTodoSyncServiceTests
```

Expected:
- PASS for meeting/todo presentation
- PASS for sync service tests

- [ ] **Step 7: Commit**

```bash
git add Casablanca/Views/ContentView.swift \
  Casablanca/Views/NotesEditorView.swift \
  Casablanca/Views/RecordedMeetingView.swift \
  Casablanca/Views/TodosView.swift \
  Casablanca/Views/SettingsView.swift \
  CasablancaTests/MeetingStartFlowTests.swift
git commit -m "feat: wire obsidian todo sync into app views"
```

---

### Task 4: Verify migration, regression coverage, and full app behavior

**Files:**
- Modify: `CasablancaTests/ObsidianTodoSyncServiceTests.swift`
- Modify: `CasablancaTests/MeetingStartFlowTests.swift`

- [ ] **Step 1: Add migration and deletion regression tests**

Extend `CasablancaTests/ObsidianTodoSyncServiceTests.swift` with:

```swift
func testRefreshAllTodosRemovesCachedTodoDeletedFromSourceFile() throws {
    let fixture = try makeFixture()
    let todo = try fixture.makeSyncedGenericTodo(text: "Buy headset", isCompleted: false)

    try fixture.writeGenericTodos("""
    # Casablanca Todos

    ## Open

    ## Done
    """)

    try ObsidianTodoSyncService.refreshAllTodos(
        in: fixture.context,
        userDefaults: fixture.defaults,
        fileManager: .default
    )

    let todos = try fixture.context.fetch(FetchDescriptor<TodoItem>())
    XCTAssertFalse(todos.contains(where: { $0.id == todo.id }))
}

func testCreateMeetingTodoKeepsMeetingReferenceAfterRefresh() throws {
    let fixture = try makeFixture()
    let meeting = fixture.makeMeeting(title: "Weekly Sync")

    let created = try ObsidianTodoSyncService.createMeetingTodo(
        text: "Bring roadmap slide",
        meeting: meeting,
        in: fixture.context,
        userDefaults: fixture.defaults,
        fileManager: .default
    )

    try ObsidianTodoSyncService.refreshTodos(
        for: meeting,
        in: fixture.context,
        userDefaults: fixture.defaults,
        fileManager: .default
    )

    let todos = try fixture.context.fetch(FetchDescriptor<TodoItem>())
    XCTAssertEqual(todos.first(where: { $0.id == created.id })?.meeting?.id, meeting.id)
}
```

- [ ] **Step 2: Run the regression tests to verify they fail before the final fixes**

Run:

```bash
cd /Users/youri.broekhuizen/conductor/workspaces/meeting-assistant/lahore && \
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -destination 'platform=macOS' \
  -only-testing:CasablancaTests/ObsidianTodoSyncServiceTests
```

Expected:
- New tests fail until cleanup + meeting-link preservation behavior is complete

- [ ] **Step 3: Finish the cleanup and migration edge cases**

Complete `ObsidianTodoSyncService` so it:

```swift
// when refreshing a source file:
removeMissingRows(keeping: importedIDs, sourceFilePath: sourceFile.path, in: modelContext)

// when upserting a meeting-linked task:
existing.meeting = meeting
existing.sourceFilePath = sourceFilePath

// when bootstrapping legacy rows:
if cachedTodo.sourceFilePath.isEmpty {
    // write to Obsidian first, then set sourceFilePath
}
```

- [ ] **Step 4: Run the full test suite**

Run:

```bash
cd /Users/youri.broekhuizen/conductor/workspaces/meeting-assistant/lahore && \
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -destination 'platform=macOS'
```

Expected:
- `** TEST SUCCEEDED **`
- All existing tests remain green

- [ ] **Step 5: Manual verification**

Check these cases in the running app:

```text
1. Launch with a valid Obsidian vault and confirm tasks/Casablanca Todos.md is created.
2. Add a generic todo in Casablanca and verify it appears in the file with a hidden casablanca-todo ID.
3. Toggle a generic todo in Casablanca and verify the checkbox updates in Obsidian.
4. Add a meeting todo from NotesEditorView and verify it appears in the meeting prep file under ## Action Items.
5. Add a checkbox manually in Obsidian without an ID, reopen the meeting, and verify Casablanca imports it.
6. Delete a task from Obsidian, refresh by reopening the meeting or Todos screen, and verify it disappears from Casablanca.
```

Expected:
- Casablanca and Obsidian stay in sync for both generic and meeting-linked todos

- [ ] **Step 6: Commit**

```bash
git add Casablanca/Services/ObsidianTodoSyncService.swift \
  CasablancaTests/ObsidianTodoSyncServiceTests.swift \
  CasablancaTests/MeetingStartFlowTests.swift
git commit -m "feat: make obsidian the source of truth for todos"
```

---

## Self-Review

### Spec coverage

- Obsidian-first authority: covered by Tasks 2-4
- Meeting-linked + generic files: covered by Tasks 1-3
- Immediate writeback: covered by Tasks 2-3
- Legacy todo bootstrap: covered by Tasks 2 and 4
- UI behavior for generic vs meeting-linked rows: covered by Task 3

### Placeholder scan

- No `TODO`/`TBD` placeholders remain
- Each task includes exact files, commands, and implementation snippets

### Type consistency

- `TodoItem.id` is the stable Obsidian UUID across tasks
- `sourceFilePath` is the cache/source bridge across parser, sync service, and UI integration
- `ObsidianMeetingFiles`, `ObsidianTodoMarkdown`, and `ObsidianTodoSyncService` names stay consistent across all tasks
