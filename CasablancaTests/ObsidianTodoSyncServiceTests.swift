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

    /// Regression: with no Prep file, meeting todos live in the Notes file, and an
    /// auto-export after a notes edit used to rewrite that file without its
    /// Action Items. The next new todo then made refresh delete the old rows.
    func testNotesFileTodosSurviveAutoExportAndLaterNewTodo() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let defaults = makeDefaults(vaultURL: try makeVault())
        let meeting = makeMeeting()
        meeting.userNotes = "first note"
        context.insert(meeting)
        try context.save()

        _ = try ObsidianMeetingExporter.exportCompletedMeeting(meeting, userDefaults: defaults)
        try ObsidianTodoSyncService.createMeetingTodo(text: "Todo A", meeting: meeting, in: context, userDefaults: defaults)
        try ObsidianTodoSyncService.createMeetingTodo(text: "Todo B", meeting: meeting, in: context, userDefaults: defaults)
        try ObsidianTodoSyncService.refreshTodos(for: meeting, in: context, userDefaults: defaults)
        let todoA = try XCTUnwrap(context.fetch(FetchDescriptor<TodoItem>()).first { $0.text == "Todo A" })
        try ObsidianTodoSyncService.setCompleted(true, for: todoA, in: context, userDefaults: defaults)

        meeting.userNotes += "\nedited"
        _ = try ObsidianMeetingExporter.exportCompletedMeeting(meeting, userDefaults: defaults)
        try ObsidianTodoSyncService.refreshTodos(for: meeting, in: context, userDefaults: defaults)

        try ObsidianTodoSyncService.createMeetingTodo(text: "Todo C", meeting: meeting, in: context, userDefaults: defaults)
        try ObsidianTodoSyncService.refreshTodos(for: meeting, in: context, userDefaults: defaults)

        let todos = try context.fetch(FetchDescriptor<TodoItem>(sortBy: [SortDescriptor(\.text)]))
        XCTAssertEqual(todos.map(\.text), ["Todo A", "Todo B", "Todo C"])
        XCTAssertEqual(todos.map(\.isCompleted), [true, false, false])
        XCTAssertEqual(todos[0].id, todoA.id)

        let notesURL = try XCTUnwrap(ObsidianMeetingFiles.meetingFiles(for: meeting, userDefaults: defaults)).notesURL
        let markdown = try String(contentsOf: notesURL, encoding: .utf8)
        XCTAssertTrue(markdown.contains("edited"))
    }

    /// Preservation reads the file as it is on disk, which the delete path has
    /// already rewritten, so a deleted todo must not come back on re-export.
    func testTodoDeletedInAppStaysDeletedAfterReExport() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let defaults = makeDefaults(vaultURL: try makeVault())
        let meeting = makeMeeting()
        context.insert(meeting)
        try context.save()

        _ = try ObsidianMeetingExporter.exportCompletedMeeting(meeting, userDefaults: defaults)
        try ObsidianTodoSyncService.createMeetingTodo(text: "Keep me", meeting: meeting, in: context, userDefaults: defaults)
        try ObsidianTodoSyncService.createMeetingTodo(text: "Delete me", meeting: meeting, in: context, userDefaults: defaults)
        let doomed = try XCTUnwrap(context.fetch(FetchDescriptor<TodoItem>()).first { $0.text == "Delete me" })

        try ObsidianTodoSyncService.deleteTodo(doomed, in: context, userDefaults: defaults)
        meeting.userNotes = "edited after delete"
        _ = try ObsidianMeetingExporter.exportCompletedMeeting(meeting, userDefaults: defaults)
        _ = try ObsidianMeetingExporter.exportRawNotes(meeting, userDefaults: defaults)
        try ObsidianTodoSyncService.refreshTodos(for: meeting, in: context, userDefaults: defaults)

        let todos = try context.fetch(FetchDescriptor<TodoItem>())
        XCTAssertEqual(todos.map(\.text), ["Keep me"])
        let notesURL = try XCTUnwrap(ObsidianMeetingFiles.meetingFiles(for: meeting, userDefaults: defaults)).notesURL
        let markdown = try String(contentsOf: notesURL, encoding: .utf8)
        XCTAssertTrue(markdown.contains("Keep me"))
        XCTAssertFalse(markdown.contains("Delete me"))
        XCTAssertTrue(markdown.contains("edited after delete"))
    }

    /// When the user's own notes contain an `## Action Items` heading, the export
    /// merges instead of replacing: file todos keep ID and state, newly typed
    /// tasks are added, and non-task lines under the heading are kept.
    func testExportMergesUserTypedActionItemsHeadingWithExistingTodos() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let defaults = makeDefaults(vaultURL: try makeVault())
        let meeting = makeMeeting()
        context.insert(meeting)
        try context.save()

        _ = try ObsidianMeetingExporter.exportCompletedMeeting(meeting, userDefaults: defaults)
        try ObsidianTodoSyncService.createMeetingTodo(text: "Ask Bob", meeting: meeting, in: context, userDefaults: defaults)
        let bob = try XCTUnwrap(context.fetch(FetchDescriptor<TodoItem>()).first)
        try ObsidianTodoSyncService.setCompleted(true, for: bob, in: context, userDefaults: defaults)

        meeting.userNotes = "## Action Items\n- [ ] Ask Carol\nsome paragraph"
        _ = try ObsidianMeetingExporter.exportCompletedMeeting(meeting, userDefaults: defaults)

        let notesURL = try XCTUnwrap(ObsidianMeetingFiles.meetingFiles(for: meeting, userDefaults: defaults)).notesURL
        var markdown = try String(contentsOf: notesURL, encoding: .utf8)
        XCTAssertTrue(markdown.contains("- [x] Ask Bob <!-- casablanca-todo: \(bob.id.uuidString.uppercased()) -->"))
        XCTAssertTrue(markdown.contains("- [ ] Ask Carol"))
        XCTAssertTrue(markdown.contains("some paragraph"))

        try ObsidianTodoSyncService.refreshTodos(for: meeting, in: context, userDefaults: defaults)
        let todos = try context.fetch(FetchDescriptor<TodoItem>(sortBy: [SortDescriptor(\.text)]))
        XCTAssertEqual(todos.map(\.text), ["Ask Bob", "Ask Carol"])
        XCTAssertEqual(todos[0].id, bob.id)
        XCTAssertTrue(todos[0].isCompleted)

        // A later save must not duplicate Carol now that the file carries her ID.
        _ = try ObsidianMeetingExporter.exportRawNotes(meeting, userDefaults: defaults)
        markdown = try String(contentsOf: notesURL, encoding: .utf8)
        XCTAssertEqual(markdown.components(separatedBy: "Ask Carol").count - 1, 1)
        XCTAssertTrue(markdown.contains("some paragraph"))
        try ObsidianTodoSyncService.refreshTodos(for: meeting, in: context, userDefaults: defaults)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TodoItem>()), 2)
    }

    /// Toggling, deleting, adding and ID-assigning todos must only touch the
    /// task lines involved: everything else the user wrote under (and around)
    /// `## Action Items` survives byte-for-byte.
    func testTodoEditsPreserveUserContentInRealisticPrepFile() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let vaultURL = try makeVault()
        let defaults = makeDefaults(vaultURL: vaultURL)
        let notesDirectory = vaultURL.appendingPathComponent("meeting notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notesDirectory, withIntermediateDirectories: true)
        let prepURL = notesDirectory.appendingPathComponent("2025-04-12 Weekly Sync - Prep.md")
        let original = """
        # Weekly Sync - Prep

        ## Agenda

        - Roadmap
          - Q3 items

        ## Action Items

        Context line written by hand.

        - [ ] Bring roadmap slide
          - sub-bullet detail
          - [ ] nested sub-task
        - [/] In progress thing
        * [ ] Star task
        - [ ] Mail agenda
            wrapped continuation

        ### Follow-ups

        Free text under h3.

        ## Notes

        Trailing text.

        """
        try original.write(to: prepURL, atomically: true, encoding: .utf8)
        let meeting = makeMeeting()
        context.insert(meeting)
        try context.save()

        try ObsidianTodoSyncService.refreshTodos(for: meeting, in: context, userDefaults: defaults)
        let todos = try context.fetch(FetchDescriptor<TodoItem>())
        let slide = try XCTUnwrap(todos.first { $0.text == "Bring roadmap slide" })
        let agenda = try XCTUnwrap(todos.first { $0.text == "Mail agenda" })
        XCTAssertEqual(todos.count, 2)

        try ObsidianTodoSyncService.setCompleted(true, for: slide, in: context, userDefaults: defaults)
        try ObsidianTodoSyncService.deleteTodo(agenda, in: context, userDefaults: defaults)
        try ObsidianTodoSyncService.createMeetingTodo(text: "New one", meeting: meeting, in: context, userDefaults: defaults)
        let newTodo = try XCTUnwrap(context.fetch(FetchDescriptor<TodoItem>()).first { $0.text == "New one" })

        let expected = original
            .replacingOccurrences(
                of: "- [ ] Bring roadmap slide\n",
                with: "- [x] Bring roadmap slide <!-- casablanca-todo: \(slide.id.uuidString.uppercased()) -->\n"
            )
            .replacingOccurrences(of: "- [ ] Mail agenda\n", with: "")
            .replacingOccurrences(
                of: "    wrapped continuation\n",
                with: "    wrapped continuation\n- [ ] New one <!-- casablanca-todo: \(newTodo.id.uuidString.uppercased()) -->\n"
            )
        XCTAssertEqual(try String(contentsOf: prepURL, encoding: .utf8), expected)

        try ObsidianTodoSyncService.refreshTodos(for: meeting, in: context, userDefaults: defaults)
        XCTAssertEqual(try String(contentsOf: prepURL, encoding: .utf8), expected)
        let refreshed = try context.fetch(FetchDescriptor<TodoItem>(sortBy: [SortDescriptor(\.text)]))
        XCTAssertEqual(refreshed.map(\.text), ["Bring roadmap slide", "New one"])
        XCTAssertEqual(refreshed.map(\.isCompleted), [true, false])
    }

    /// A file that exists but cannot be read must never be treated as empty:
    /// that used to overwrite the user's Prep file with a lone Action Items
    /// block (create/delete) and silently skip it during refresh.
    func testUnreadableMeetingFileIsNeitherOverwrittenNorTreatedAsEmpty() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let vaultURL = try makeVault()
        let defaults = makeDefaults(vaultURL: vaultURL)
        let notesDirectory = vaultURL.appendingPathComponent("meeting notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notesDirectory, withIntermediateDirectories: true)
        let prepURL = notesDirectory.appendingPathComponent("2025-04-12 Weekly Sync - Prep.md")
        try "## Action Items\n\n- [ ] Keep me\n".write(to: prepURL, atomically: true, encoding: .utf8)
        let meeting = makeMeeting()
        context.insert(meeting)
        try context.save()
        try ObsidianTodoSyncService.refreshTodos(for: meeting, in: context, userDefaults: defaults)
        let keep = try XCTUnwrap(context.fetch(FetchDescriptor<TodoItem>()).first)

        // Not valid UTF-8 (e.g. a file saved in another encoding).
        let unreadable = Data([0x23, 0x20, 0xFF, 0xFE, 0x0A, 0xC3, 0x28])
        try unreadable.write(to: prepURL)

        XCTAssertThrowsError(
            try ObsidianTodoSyncService.createMeetingTodo(text: "New", meeting: meeting, in: context, userDefaults: defaults)
        )
        XCTAssertThrowsError(try ObsidianTodoSyncService.deleteTodo(keep, in: context, userDefaults: defaults))
        XCTAssertThrowsError(try ObsidianTodoSyncService.setCompleted(true, for: keep, in: context, userDefaults: defaults))
        XCTAssertThrowsError(try ObsidianTodoSyncService.refreshTodos(for: meeting, in: context, userDefaults: defaults))

        XCTAssertEqual(try Data(contentsOf: prepURL), unreadable)
        XCTAssertEqual(try context.fetch(FetchDescriptor<TodoItem>()).map(\.text), ["Keep me"])
    }

    /// One meeting whose file cannot be read must not stop the full refresh
    /// from syncing every other meeting; the failure is still reported.
    func testRefreshAllTodosContinuesPastAFailingMeeting() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let vaultURL = try makeVault()
        let defaults = makeDefaults(vaultURL: vaultURL)
        let notesDirectory = vaultURL.appendingPathComponent("meeting notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notesDirectory, withIntermediateDirectories: true)

        let broken = Meeting(title: "Broken", date: makeMeeting().date)
        let healthy = Meeting(title: "Healthy", date: makeMeeting().date)
        context.insert(broken)
        context.insert(healthy)
        try context.save()
        let brokenURL = notesDirectory.appendingPathComponent("2025-04-12 Broken - Prep.md")
        let unreadable = Data([0xFF, 0xFE, 0xC3, 0x28])
        try unreadable.write(to: brokenURL)
        try "## Action Items\n\n- [ ] Healthy todo\n".write(
            to: notesDirectory.appendingPathComponent("2025-04-12 Healthy - Prep.md"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertThrowsError(try ObsidianTodoSyncService.refreshAllTodos(in: context, userDefaults: defaults))

        let todos = try context.fetch(FetchDescriptor<TodoItem>())
        XCTAssertEqual(todos.map(\.text), ["Healthy todo"])
        XCTAssertEqual(todos.first?.meeting?.id, healthy.id)
        XCTAssertEqual(try Data(contentsOf: brokenURL), unreadable)
    }

    /// Review focus 3: a proposed row (SwiftData only, no source file) is
    /// neither written to the meeting's file nor deleted by the refresh.
    func testRefreshNeverWritesProposedTodosToTheVault() throws {
        let context = ModelContext(try makeContainer())
        let defaults = makeDefaults(vaultURL: try makeVault())
        let meeting = makeMeeting()
        meeting.userNotes = "notes"
        context.insert(meeting)
        _ = try ObsidianMeetingExporter.exportCompletedMeeting(meeting, userDefaults: defaults)
        let proposal = TodoItem(text: "Proposed follow-up", meeting: meeting)
        proposal.status = .proposed
        context.insert(proposal)
        try context.save()

        try ObsidianTodoSyncService.refreshTodos(for: meeting, in: context, userDefaults: defaults)
        try ObsidianTodoSyncService.refreshAllTodos(in: context, userDefaults: defaults)

        let files = try XCTUnwrap(ObsidianMeetingFiles.meetingFiles(for: meeting, userDefaults: defaults))
        let markdown = try String(contentsOf: files.notesURL, encoding: .utf8)
        XCTAssertFalse(markdown.contains("Proposed follow-up"))
        XCTAssertFalse(markdown.contains(proposal.id.uuidString))
        let rows = try context.fetch(FetchDescriptor<TodoItem>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.status, .proposed)
        XCTAssertNil(rows.first?.sourceFilePath)
    }

    /// Existing behaviour: an accepted row without a source file is still
    /// bootstrapped into the meeting's file.
    func testRefreshStillBootstrapsLegacyAcceptedTodos() throws {
        let context = ModelContext(try makeContainer())
        let defaults = makeDefaults(vaultURL: try makeVault())
        let meeting = makeMeeting()
        meeting.userNotes = "notes"
        context.insert(meeting)
        _ = try ObsidianMeetingExporter.exportCompletedMeeting(meeting, userDefaults: defaults)
        let legacy = TodoItem(text: "Legacy accepted todo", meeting: meeting)
        context.insert(legacy)
        try context.save()
        XCTAssertEqual(legacy.status, .accepted)

        try ObsidianTodoSyncService.refreshTodos(for: meeting, in: context, userDefaults: defaults)

        let files = try XCTUnwrap(ObsidianMeetingFiles.meetingFiles(for: meeting, userDefaults: defaults))
        let markdown = try String(contentsOf: files.canonicalTodoWriteURL, encoding: .utf8)
        XCTAssertTrue(markdown.contains("- [ ] Legacy accepted todo <!-- casablanca-todo: \(legacy.id.uuidString) -->"))
        XCTAssertEqual(legacy.sourceFilePath, files.canonicalTodoWriteURL.path)
        XCTAssertEqual(try context.fetch(FetchDescriptor<TodoItem>()).count, 1)
    }

    // MARK: - Task 10: accepted-only sync with the owner / due / timestamp suffix

    private func makeDecisionLog() -> TodoDecisionLog {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ObsidianTodoSyncServiceTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return TodoDecisionLog(fileURL: directory.appendingPathComponent("todo-decisions.jsonl"))
    }

    private func proposeOffer(for meeting: Meeting, in context: ModelContext) throws -> TodoItem {
        try TodoReviewService.replaceProposedTodos(
            for: meeting,
            with: [ExtractedActionItem(task: "Stuur offerte", owner: "Youri", due: "2026-11-06", dueIsExplicit: true,
                                       confidence: 0.9, quote: "ik stuur de offerte", timestamp: "12:34",
                                       verified: .supported, verificationReason: nil)],
            in: context
        )
        try context.save()
        return try XCTUnwrap(try context.fetch(FetchDescriptor<TodoItem>()).first { $0.status == .proposed })
    }

    func testRejectedRowsSurviveRefresh() throws {
        let context = ModelContext(try makeContainer())
        let defaults = makeDefaults(vaultURL: try makeVault())
        let meeting = makeMeeting()
        meeting.userNotes = "notes"
        context.insert(meeting)
        _ = try ObsidianMeetingExporter.exportCompletedMeeting(meeting, userDefaults: defaults)
        let todo = try proposeOffer(for: meeting, in: context)
        try TodoReviewService.reject(todo, in: context, log: makeDecisionLog())

        try ObsidianTodoSyncService.refreshTodos(for: meeting, in: context, userDefaults: defaults)
        try ObsidianTodoSyncService.refreshAllTodos(in: context, userDefaults: defaults)

        let rows = try context.fetch(FetchDescriptor<TodoItem>())
        XCTAssertEqual(rows.map(\.id), [todo.id])
        XCTAssertEqual(rows.first?.status, .rejected)
        XCTAssertNil(rows.first?.sourceFilePath)
        let files = try XCTUnwrap(ObsidianMeetingFiles.meetingFiles(for: meeting, userDefaults: defaults))
        XCTAssertFalse(try String(contentsOf: files.notesURL, encoding: .utf8).contains("Stuur offerte"))
    }

    func testAcceptedLineRoundTripsThroughRefresh() throws {
        let context = ModelContext(try makeContainer())
        let defaults = makeDefaults(vaultURL: try makeVault())
        let meeting = makeMeeting()
        meeting.userNotes = "notes"
        context.insert(meeting)
        _ = try ObsidianMeetingExporter.exportCompletedMeeting(meeting, userDefaults: defaults)
        let todo = try proposeOffer(for: meeting, in: context)
        try TodoReviewService.accept(todo, in: context, userDefaults: defaults, log: makeDecisionLog())
        let files = try XCTUnwrap(ObsidianMeetingFiles.meetingFiles(for: meeting, userDefaults: defaults))
        let url = files.canonicalTodoWriteURL

        // The user edits the task text in Obsidian; the suffix stays.
        let markdown = try String(contentsOf: url, encoding: .utf8)
        try markdown.replacingOccurrences(of: "- [ ] Stuur offerte — ", with: "- [x] Stuur de offerte — ")
            .write(to: url, atomically: true, encoding: .utf8)
        // Fields lost locally come back from the line.
        todo.owner = nil
        todo.dueDate = nil
        todo.sourceTimestamp = nil
        try context.save()

        try ObsidianTodoSyncService.refreshTodos(for: meeting, in: context, userDefaults: defaults)

        let rows = try context.fetch(FetchDescriptor<TodoItem>())
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.id, todo.id)
        XCTAssertEqual(row.text, "Stuur de offerte", "the stored text has no suffix")
        XCTAssertTrue(row.isCompleted)
        XCTAssertEqual(row.owner, "Youri")
        XCTAssertEqual(row.dueDate, TodoReviewService.dueDate(fromISO: "2026-11-06"))
        XCTAssertEqual(row.sourceTimestamp, "12:34")
        XCTAssertEqual(row.status, .accepted)
        XCTAssertEqual(row.sourceFilePath, url.path)
        let after = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(after.contains("- [x] Stuur de offerte — Youri 📅 2026-11-06 [12:34] <!-- casablanca-todo: \(todo.id.uuidString) -->"))

        // A row imported fresh from the file gets the fields too.
        context.delete(row)
        try context.save()
        try ObsidianTodoSyncService.refreshTodos(for: meeting, in: context, userDefaults: defaults)
        let imported = try XCTUnwrap(try context.fetch(FetchDescriptor<TodoItem>()).first)
        XCTAssertEqual(imported.id, todo.id)
        XCTAssertEqual(imported.text, "Stuur de offerte")
        XCTAssertEqual(imported.owner, "Youri")
        XCTAssertEqual(imported.sourceTimestamp, "12:34")
        XCTAssertEqual(imported.status, .accepted)
    }

    /// Pre-V3 rows (status defaults to `.accepted`, no owner/due/timestamp)
    /// sync, toggle and export exactly as before; a line without a suffix
    /// keeps the row's own owner.
    func testLegacyTodosStillSyncAndExport() throws {
        let context = ModelContext(try makeContainer())
        let defaults = makeDefaults(vaultURL: try makeVault())
        let meeting = makeMeeting()
        meeting.userNotes = "notes"
        meeting.summary = "# Summary\nShort."
        context.insert(meeting)
        _ = try ObsidianMeetingExporter.exportCompletedMeeting(meeting, userDefaults: defaults)
        let legacy = TodoItem(text: "Legacy todo", meeting: meeting)
        let ownerOnly = TodoItem(text: "Owner only", meeting: meeting)
        ownerOnly.owner = "Kim"
        context.insert(legacy)
        context.insert(ownerOnly)
        try context.save()
        XCTAssertEqual(legacy.statusRaw, TodoStatus.accepted.rawValue)

        try ObsidianTodoSyncService.refreshTodos(for: meeting, in: context, userDefaults: defaults)
        try ObsidianTodoSyncService.setCompleted(true, for: legacy, in: context, userDefaults: defaults)
        try ObsidianTodoSyncService.refreshAllTodos(in: context, userDefaults: defaults)

        let files = try XCTUnwrap(ObsidianMeetingFiles.meetingFiles(for: meeting, userDefaults: defaults))
        let markdown = try String(contentsOf: files.canonicalTodoWriteURL, encoding: .utf8)
        XCTAssertTrue(markdown.contains("- [x] Legacy todo <!-- casablanca-todo: \(legacy.id.uuidString) -->\n"))
        XCTAssertTrue(markdown.contains("- [ ] Owner only <!-- casablanca-todo: \(ownerOnly.id.uuidString) -->"))
        XCTAssertEqual(ownerOnly.owner, "Kim", "a line without a suffix keeps the row's owner")
        XCTAssertEqual(try context.fetch(FetchDescriptor<TodoItem>()).count, 2)

        let result = try ObsidianMeetingExporter.exportCompletedMeeting(meeting, userDefaults: defaults)
        let summary = try String(contentsOf: try XCTUnwrap(result.summaryURL), encoding: .utf8)
        XCTAssertTrue(summary.contains("- [x] Legacy todo\n"))
        XCTAssertTrue(summary.contains("- [ ] Owner only\n"))
    }

    // MARK: - Fix round 1: summary-tab to-dos keep their text

    /// Mirrors `MeetingSummaryTab.toggleActionItem` (a private view method).
    private func toggleSummaryBullet(_ bullet: String, meeting: Meeting, in context: ModelContext, defaults: UserDefaults) throws {
        if let todo = ActionItemTodoMatcher.matchingTodo(for: bullet, in: meeting.todos) {
            try ObsidianTodoSyncService.setCompleted(!todo.isCompleted, for: todo, in: context, userDefaults: defaults)
        } else {
            try ObsidianTodoSyncService.createMeetingTodo(text: bullet, meeting: meeting, in: context, userDefaults: defaults)
            if let created = ActionItemTodoMatcher.matchingTodo(for: bullet, in: meeting.todos) {
                try ObsidianTodoSyncService.setCompleted(true, for: created, in: context, userDefaults: defaults)
            }
        }
    }

    private func assertSummaryBulletRoundTrips(_ bullet: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let context = ModelContext(try makeContainer())
        let defaults = makeDefaults(vaultURL: try makeVault())
        let meeting = makeMeeting()
        meeting.userNotes = "notes"
        context.insert(meeting)
        try context.save()
        _ = try ObsidianMeetingExporter.exportCompletedMeeting(meeting, userDefaults: defaults)

        try toggleSummaryBullet(bullet, meeting: meeting, in: context, defaults: defaults)
        let todo = try XCTUnwrap(try context.fetch(FetchDescriptor<TodoItem>()).first, file: file, line: line)
        let url = try XCTUnwrap(todo.sourceFilePath.map(URL.init(fileURLWithPath:)), file: file, line: line)
        TestVaultGuard.assertTemporary(url, "meeting todo file")
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8)
            .contains("- [x] \(bullet) <!-- casablanca-todo: \(todo.id.uuidString) -->"), file: file, line: line)

        try ObsidianTodoSyncService.refreshTodos(for: meeting, in: context, userDefaults: defaults)
        try ObsidianTodoSyncService.refreshAllTodos(in: context, userDefaults: defaults)

        XCTAssertEqual(todo.text, bullet, "the row's text is unchanged", file: file, line: line)
        XCTAssertNil(todo.owner, file: file, line: line)
        XCTAssertNil(todo.sourceTimestamp, file: file, line: line)
        XCTAssertTrue(ActionItemTodoMatcher.matchingTodo(for: bullet, in: meeting.todos) === todo, file: file, line: line)

        try toggleSummaryBullet(bullet, meeting: meeting, in: context, defaults: defaults)
        try ObsidianTodoSyncService.refreshTodos(for: meeting, in: context, userDefaults: defaults)

        let markdown = try String(contentsOf: url, encoding: .utf8)
        let taskLines = markdown.components(separatedBy: "\n").filter { $0.contains("casablanca-todo:") }
        XCTAssertEqual(taskLines, ["- [ ] \(bullet) <!-- casablanca-todo: \(todo.id.uuidString) -->"],
                       "the second toggle unchecks the same line and appends none", file: file, line: line)
        XCTAssertEqual(try context.fetch(FetchDescriptor<TodoItem>()).count, 1, file: file, line: line)
        XCTAssertEqual(todo.text, bullet, file: file, line: line)
    }

    func testSummaryTabBoldOwnerBulletRoundTripsThroughRefresh() throws {
        try assertSummaryBulletRoundTrips("**Youri** — Plan de demo [00:20]")
    }

    func testSummaryTabPlainOwnerBulletRoundTripsThroughRefresh() throws {
        try assertSummaryBulletRoundTrips("Youri — Plan de demo [00:20]")
    }

    func testSummaryTabColonOwnerBulletRoundTripsThroughRefresh() throws {
        try assertSummaryBulletRoundTrips("**Youri:** Mail Kim [00:20]")
    }

    func testSummaryTabUnassignedBulletWithDateRoundTripsThroughRefresh() throws {
        try assertSummaryBulletRoundTrips("**?** — Plan de demo (2026-11-06) [00:20]")
    }

    // MARK: - Fix round 2: rows that render to their own line are left alone

    /// Accepts a hand-built proposed row through `TodoReviewService.accept`
    /// (scratch vault, temporary decision log) and returns the todo file URL.
    private func acceptRow(
        _ text: String, owner: String?, due: String? = nil, timestamp: String?,
        meeting: Meeting, in context: ModelContext, defaults: UserDefaults
    ) throws -> (TodoItem, URL) {
        let todo = TodoItem(text: text, meeting: meeting)
        todo.status = .proposed
        todo.owner = owner
        todo.dueDate = due.flatMap(TodoReviewService.dueDate(fromISO:))
        todo.sourceTimestamp = timestamp
        context.insert(todo)
        try context.save()
        try TodoReviewService.accept(todo, in: context, userDefaults: defaults, log: makeDecisionLog())
        let url = try XCTUnwrap(todo.sourceFilePath.map(URL.init(fileURLWithPath:)))
        TestVaultGuard.assertTemporary(url, "meeting todo file")
        return (todo, url)
    }

    private func exportedMeeting(in context: ModelContext, defaults: UserDefaults) throws -> Meeting {
        let meeting = makeMeeting()
        meeting.userNotes = "notes"
        meeting.summary = "# Summary\nShort."
        context.insert(meeting)
        try context.save()
        _ = try ObsidianMeetingExporter.exportCompletedMeeting(meeting, userDefaults: defaults)
        return meeting
    }

    private func taskLines(_ url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n").filter { $0.contains("casablanca-todo:") }
    }

    func testUnassignedDashTextWithTimestampSurvivesRefresh() throws {
        let context = ModelContext(try makeContainer())
        let defaults = makeDefaults(vaultURL: try makeVault())
        let meeting = try exportedMeeting(in: context, defaults: defaults)
        let (todo, url) = try acceptRow("Stuur offerte — uiterlijk vrijdag", owner: nil, timestamp: "12:34",
                                        meeting: meeting, in: context, defaults: defaults)
        XCTAssertEqual(try taskLines(url), ["- [ ] Stuur offerte — uiterlijk vrijdag [12:34] <!-- casablanca-todo: \(todo.id.uuidString) -->"])

        try ObsidianTodoSyncService.refreshTodos(for: meeting, in: context, userDefaults: defaults)

        XCTAssertEqual(todo.text, "Stuur offerte — uiterlijk vrijdag")
        XCTAssertNil(todo.owner)
        XCTAssertEqual(todo.sourceTimestamp, "12:34")

        let bullet = "**Youri** — Stuur offerte — uiterlijk vrijdag [12:34]"
        try toggleSummaryBullet(bullet, meeting: meeting, in: context, defaults: defaults)
        try ObsidianTodoSyncService.refreshTodos(for: meeting, in: context, userDefaults: defaults)

        XCTAssertEqual(try taskLines(url), ["- [x] Stuur offerte — uiterlijk vrijdag [12:34] <!-- casablanca-todo: \(todo.id.uuidString) -->"],
                       "the toggle checked the row's own line and appended none")
        XCTAssertEqual(try context.fetch(FetchDescriptor<TodoItem>()).count, 1)
        XCTAssertEqual(todo.text, "Stuur offerte — uiterlijk vrijdag")
    }

    func testBoldPrefixedTodoCarriesItsSuffixOnceInExports() throws {
        let context = ModelContext(try makeContainer())
        let defaults = makeDefaults(vaultURL: try makeVault())
        let meeting = try exportedMeeting(in: context, defaults: defaults)
        let (todo, url) = try acceptRow("**Urgent:** bel Kim", owner: "Kim", timestamp: "12:34",
                                        meeting: meeting, in: context, defaults: defaults)

        try ObsidianTodoSyncService.refreshTodos(for: meeting, in: context, userDefaults: defaults)

        XCTAssertEqual(todo.text, "**Urgent:** bel Kim")
        XCTAssertEqual(todo.owner, "Kim")
        XCTAssertEqual(todo.sourceTimestamp, "12:34")
        XCTAssertEqual(try taskLines(url), ["- [ ] **Urgent:** bel Kim — Kim [12:34] <!-- casablanca-todo: \(todo.id.uuidString) -->"])

        let result = try ObsidianMeetingExporter.exportCompletedMeeting(meeting, userDefaults: defaults)
        let summary = try String(contentsOf: try XCTUnwrap(result.summaryURL), encoding: .utf8)
        XCTAssertTrue(summary.contains("- [ ] **Urgent:** bel Kim — Kim [12:34]\n"), summary)
        XCTAssertEqual(summary.components(separatedBy: "[12:34]").count - 1, 1)
        let html = AppleNotesBodyRenderer.summaryHTML(for: meeting)
        XCTAssertTrue(html.contains("bel Kim — Kim [12:34]</li>"), html)
        XCTAssertEqual(html.components(separatedBy: "[12:34]").count - 1, 1)
    }

    func testOwnerTooLongForTheLineSurvivesRefresh() throws {
        let context = ModelContext(try makeContainer())
        let defaults = makeDefaults(vaultURL: try makeVault())
        let meeting = try exportedMeeting(in: context, defaults: defaults)
        let longOwner = String(repeating: "Kim ", count: 20).trimmingCharacters(in: .whitespaces)
        let (todo, url) = try acceptRow("Stuur offerte", owner: longOwner, due: "2026-11-06", timestamp: "12:34",
                                        meeting: meeting, in: context, defaults: defaults)
        XCTAssertEqual(try taskLines(url), ["- [ ] Stuur offerte 📅 2026-11-06 [12:34] <!-- casablanca-todo: \(todo.id.uuidString) -->"])

        try ObsidianTodoSyncService.refreshTodos(for: meeting, in: context, userDefaults: defaults)

        XCTAssertEqual(todo.text, "Stuur offerte")
        XCTAssertEqual(todo.owner, longOwner)
        XCTAssertEqual(todo.dueDate, TodoReviewService.dueDate(fromISO: "2026-11-06"))
    }

    /// The general early return does not freeze rows: a line edited in
    /// Obsidian still updates the row.
    func testBoldInsideTextStillSplitsTheOwner() throws {
        let task = try XCTUnwrap(ObsidianTodoMarkdown.parseMeetingActionItems(
            "## Action Items\n\n- [ ] Stuur **offerte** — Kim [12:34]\n").first)
        XCTAssertEqual(task.text, "Stuur **offerte**")
        XCTAssertEqual(task.owner, "Kim")
        XCTAssertEqual(task.timestamp, "12:34")
    }

    /// A line written before Task 10 (no row yet: another Mac, a rebuilt
    /// store) is imported with its whole bold-owner text.
    func testPreTask10BulletLineImportsWithItsWholeText() throws {
        let context = ModelContext(try makeContainer())
        let defaults = makeDefaults(vaultURL: try makeVault())
        let meeting = makeMeeting()
        meeting.userNotes = "notes"
        context.insert(meeting)
        _ = try ObsidianMeetingExporter.exportCompletedMeeting(meeting, userDefaults: defaults)
        let files = try XCTUnwrap(ObsidianMeetingFiles.meetingFiles(for: meeting, userDefaults: defaults))
        let id = UUID()
        let bullet = "**Youri** — Plan de demo [00:20]"
        let markdown = try String(contentsOf: files.notesURL, encoding: .utf8)
        try ObsidianTodoMarkdown.appendingTask(markdown, .init(id: nil, text: "x", isCompleted: false))
            .replacingOccurrences(of: "- [ ] x", with: "- [x] \(bullet) <!-- casablanca-todo: \(id.uuidString) -->")
            .write(to: files.notesURL, atomically: true, encoding: .utf8)

        try ObsidianTodoSyncService.refreshTodos(for: meeting, in: context, userDefaults: defaults)

        let row = try XCTUnwrap(try context.fetch(FetchDescriptor<TodoItem>()).first)
        XCTAssertEqual(row.id, id)
        XCTAssertEqual(row.text, bullet)
        XCTAssertTrue(ActionItemTodoMatcher.matchingTodo(for: bullet, in: meeting.todos) === row)
    }

    private func makeVault() throws -> URL {
        makeScratchVault("todo-sync")
    }

    /// Scratch preference domain pointed at a temporary vault. Never the
    /// standard domain: this suite WRITES markdown, so a real vault path would
    /// litter the user's vault (see `TestVaultGuard`).
    private func makeDefaults(vaultURL: URL) -> UserDefaults {
        let defaults = makeScratchDefaults(vaultRoot: vaultURL, label: "todo-sync")
        assertScratchVault(defaults)
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

    /// Local-only mode: no vault is consulted, but the domain still must not be
    /// the standard one.
    private func makeLocalModeDefaults() -> UserDefaults {
        makeScratchDefaults(label: "todo-sync-local")
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Meeting.self, TodoItem.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func makeInMemoryModelContext() throws -> ModelContext {
        let schema = Schema([Meeting.self, TodoItem.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        return ModelContext(container)
    }

    @MainActor
    func testCreateGenericTodoInLocalModePersistsSwiftDataOnly() throws {
        let defaults = makeLocalModeDefaults()
        defaults.set(PrepTodoStorage.local.rawValue, forKey: AppPreferenceKey.prepTodoStorage)
        defaults.set("/tmp/no-such-vault", forKey: AppPreferenceKey.obsidianVaultPath)
        let context = try makeInMemoryModelContext()

        try ObsidianTodoSyncService.createGenericTodo(
            text: "Buy milk",
            in: context,
            userDefaults: defaults
        )

        let todos = try context.fetch(FetchDescriptor<TodoItem>())
        XCTAssertEqual(todos.count, 1)
        XCTAssertNil(todos[0].sourceFilePath)
        XCTAssertNil(todos[0].meeting)
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/no-such-vault"))
    }

    @MainActor
    func testCreateMeetingTodoInLocalModePersistsSwiftDataOnly() throws {
        let defaults = makeLocalModeDefaults()
        defaults.set(PrepTodoStorage.local.rawValue, forKey: AppPreferenceKey.prepTodoStorage)
        defaults.set("/tmp/no-such-vault", forKey: AppPreferenceKey.obsidianVaultPath)
        let context = try makeInMemoryModelContext()
        let meeting = Meeting(title: "Sync", date: .now)
        context.insert(meeting)

        try ObsidianTodoSyncService.createMeetingTodo(
            text: "Send recap",
            meeting: meeting,
            in: context,
            userDefaults: defaults
        )

        let todos = try context.fetch(FetchDescriptor<TodoItem>())
        XCTAssertEqual(todos.count, 1)
        XCTAssertNil(todos[0].sourceFilePath)
        XCTAssertEqual(todos[0].meeting?.id, meeting.id)
    }

    @MainActor
    func testSetCompletedInLocalModeSkipsFilesystem() throws {
        let defaults = makeLocalModeDefaults()
        defaults.set(PrepTodoStorage.local.rawValue, forKey: AppPreferenceKey.prepTodoStorage)
        let context = try makeInMemoryModelContext()
        // Pre-existing row with a stale source path that no longer corresponds to anything on disk.
        let todo = TodoItem(text: "Old", isCompleted: false, sourceFilePath: "/tmp/no-such-vault/tasks/Casablanca Todos.md")
        context.insert(todo)

        try ObsidianTodoSyncService.setCompleted(true, for: todo, in: context, userDefaults: defaults)

        XCTAssertTrue(todo.isCompleted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/no-such-vault/tasks/Casablanca Todos.md"))
    }

    @MainActor
    func testDeleteTodoInLocalModeSkipsFilesystem() throws {
        let defaults = makeLocalModeDefaults()
        defaults.set(PrepTodoStorage.local.rawValue, forKey: AppPreferenceKey.prepTodoStorage)
        let context = try makeInMemoryModelContext()
        let todo = TodoItem(text: "Old", sourceFilePath: "/tmp/no-such-vault/Old.md")
        context.insert(todo)

        try ObsidianTodoSyncService.deleteTodo(todo, in: context, userDefaults: defaults)

        XCTAssertEqual(try context.fetch(FetchDescriptor<TodoItem>()).count, 0)
    }

    @MainActor
    func testRefreshAllTodosInLocalModeIsNoop() throws {
        let defaults = makeLocalModeDefaults()
        defaults.set(PrepTodoStorage.local.rawValue, forKey: AppPreferenceKey.prepTodoStorage)
        defaults.set("/tmp/no-such-vault", forKey: AppPreferenceKey.obsidianVaultPath)
        let context = try makeInMemoryModelContext()

        XCTAssertNoThrow(try ObsidianTodoSyncService.refreshAllTodos(in: context, userDefaults: defaults))
    }
}
