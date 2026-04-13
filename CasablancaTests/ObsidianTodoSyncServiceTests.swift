import Foundation
import SwiftData
import XCTest
@testable import Casablanca

@MainActor
final class ObsidianTodoSyncServiceTests: XCTestCase {
    func testRefreshAllTodosImportsGenericTodosFromManagedFile() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let vaultURL = try makeVault()
        let defaults = makeDefaults(vaultURL: vaultURL)
        let genericURL = try XCTUnwrap(ObsidianMeetingFiles.genericTodosURL(userDefaults: defaults))

        try FileManager.default.createDirectory(
            at: genericURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        # Casablanca Todos

        ## Open

        - [ ] Follow up with Kim <!-- casablanca-todo: 550E8400-E29B-41D4-A716-446655440000 -->

        ## Done

        - [x] Send summary <!-- casablanca-todo: 660E8400-E29B-41D4-A716-446655440000 -->
        """.write(to: genericURL, atomically: true, encoding: .utf8)

        try ObsidianTodoSyncService.refreshAllTodos(in: context, userDefaults: defaults)

        let todos = try context.fetch(FetchDescriptor<TodoItem>(sortBy: [SortDescriptor(\.text)]))
        XCTAssertEqual(todos.map(\.text), ["Follow up with Kim", "Send summary"])
        XCTAssertNil(todos[0].meeting)
        XCTAssertEqual(todos[0].sourceFilePath, genericURL.path)
        XCTAssertFalse(todos[0].isCompleted)
        XCTAssertTrue(todos[1].isCompleted)
    }

    func testRefreshMeetingBootstrapsLegacyMeetingTodoIntoCanonicalFile() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let vaultURL = try makeVault()
        let defaults = makeDefaults(vaultURL: vaultURL)
        let notesDirectory = vaultURL.appendingPathComponent("meeting notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notesDirectory, withIntermediateDirectories: true)

        let meeting = makeMeeting()
        let prepURL = notesDirectory.appendingPathComponent("2025-04-12 Weekly Sync - Prep.md")
        try "# Prep".write(to: prepURL, atomically: true, encoding: .utf8)
        context.insert(meeting)
        context.insert(TodoItem(text: "Bring roadmap slide", meeting: meeting))
        try context.save()

        try ObsidianTodoSyncService.refreshTodos(for: meeting, in: context, userDefaults: defaults)

        let markdown = try String(contentsOf: prepURL, encoding: .utf8)
        XCTAssertTrue(markdown.contains("## Action Items"))
        XCTAssertTrue(markdown.contains("Bring roadmap slide"))
        XCTAssertTrue(markdown.contains("<!-- casablanca-todo:"))

        let todos = try context.fetch(FetchDescriptor<TodoItem>())
        XCTAssertEqual(todos.count, 1)
        XCTAssertEqual(todos[0].meeting?.id, meeting.id)
        XCTAssertEqual(todos[0].sourceFilePath, prepURL.path)
    }

    func testSetCompletedWritesBackToGenericSourceFile() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let vaultURL = try makeVault()
        let defaults = makeDefaults(vaultURL: vaultURL)
        let genericURL = try XCTUnwrap(ObsidianMeetingFiles.genericTodosURL(userDefaults: defaults))

        try FileManager.default.createDirectory(
            at: genericURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        # Casablanca Todos

        ## Open

        - [ ] Follow up with Kim <!-- casablanca-todo: 550E8400-E29B-41D4-A716-446655440000 -->

        ## Done
        """.write(to: genericURL, atomically: true, encoding: .utf8)

        try ObsidianTodoSyncService.refreshAllTodos(in: context, userDefaults: defaults)
        let todo = try XCTUnwrap(try context.fetch(FetchDescriptor<TodoItem>()).first)

        try ObsidianTodoSyncService.setCompleted(true, for: todo, in: context, userDefaults: defaults)

        let markdown = try String(contentsOf: genericURL, encoding: .utf8)
        XCTAssertTrue(markdown.contains("- [x] Follow up with Kim"))
        XCTAssertTrue(todo.isCompleted)
    }

    func testRefreshAllTodosRemovesGenericCacheRowDeletedFromSourceFile() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let vaultURL = try makeVault()
        let defaults = makeDefaults(vaultURL: vaultURL)
        let genericURL = try XCTUnwrap(ObsidianMeetingFiles.genericTodosURL(userDefaults: defaults))

        try FileManager.default.createDirectory(
            at: genericURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        # Casablanca Todos

        ## Open

        - [ ] Follow up with Kim <!-- casablanca-todo: 550E8400-E29B-41D4-A716-446655440000 -->

        ## Done
        """.write(to: genericURL, atomically: true, encoding: .utf8)

        try ObsidianTodoSyncService.refreshAllTodos(in: context, userDefaults: defaults)
        XCTAssertEqual(try context.fetch(FetchDescriptor<TodoItem>()).count, 1)

        try """
        # Casablanca Todos

        ## Open

        ## Done
        """.write(to: genericURL, atomically: true, encoding: .utf8)

        try ObsidianTodoSyncService.refreshAllTodos(in: context, userDefaults: defaults)

        XCTAssertTrue(try context.fetch(FetchDescriptor<TodoItem>()).isEmpty)
    }

    func testRefreshMeetingPreservesMeetingReferenceForMeetingLinkedTodo() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let vaultURL = try makeVault()
        let defaults = makeDefaults(vaultURL: vaultURL)
        let notesDirectory = vaultURL.appendingPathComponent("meeting notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notesDirectory, withIntermediateDirectories: true)

        let meeting = makeMeeting()
        context.insert(meeting)
        try context.save()

        let prepURL = notesDirectory.appendingPathComponent("2025-04-12 Weekly Sync - Prep.md")
        try """
        # Prep

        ## Action Items

        - [ ] Bring roadmap slide <!-- casablanca-todo: 550E8400-E29B-41D4-A716-446655440000 -->
        """.write(to: prepURL, atomically: true, encoding: .utf8)

        try ObsidianTodoSyncService.refreshTodos(for: meeting, in: context, userDefaults: defaults)

        var todos = try context.fetch(FetchDescriptor<TodoItem>())
        XCTAssertEqual(todos.count, 1)
        XCTAssertEqual(todos[0].meeting?.id, meeting.id)

        try """
        # Prep

        ## Action Items

        - [x] Bring roadmap slide <!-- casablanca-todo: 550E8400-E29B-41D4-A716-446655440000 -->
        """.write(to: prepURL, atomically: true, encoding: .utf8)

        try ObsidianTodoSyncService.refreshTodos(for: meeting, in: context, userDefaults: defaults)

        todos = try context.fetch(FetchDescriptor<TodoItem>())
        XCTAssertEqual(todos.count, 1)
        XCTAssertEqual(todos[0].meeting?.id, meeting.id)
        XCTAssertTrue(todos[0].isCompleted)
    }

    private func makeVault() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeDefaults(vaultURL: URL) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "ObsidianTodoSyncServiceTests.\(UUID().uuidString)")!
        defaults.set(vaultURL.path, forKey: AppPreferenceKey.obsidianVaultPath)
        return defaults
    }

    private func makeMeeting() -> Meeting {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = 2025
        components.month = 4
        components.day = 12
        components.hour = 12
        return Meeting(title: "Weekly Sync", date: components.date!)
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Meeting.self, TodoItem.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
