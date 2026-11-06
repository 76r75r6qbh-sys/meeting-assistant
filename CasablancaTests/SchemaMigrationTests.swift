import XCTest
import SwiftData
@testable import Casablanca

/// Forward regression guard for the explicit V1 → V2 SwiftData migration.
///
/// Seeds a temp-URL store using ONLY the v0.7.1 schema (``CasablancaSchemaV1``),
/// then reopens that SAME file through the production path
/// (`migrationPlan: CasablancaMigrationPlan.self` + the current top-level
/// schema) and asserts the seeded meeting SURVIVES with its fields intact and
/// the new `tags` property defaulted to `[]`.
///
/// HONEST FRAMING: this passes on macOS 26 and documents the EXPECTED migration
/// behavior; it is NOT a reproduction of the v0.8.0 data loss (which was not
/// reproducible on this OS). The unconditional pre-open store backup is the
/// actual guarantee against loss; this test proves the deterministic plan
/// preserves rows here.
final class SchemaMigrationTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL.temporaryDirectory.appending(path: "SchemaMigrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
    }

    func test_v1StoreMigratesToCurrentSchema_preservingRows() throws {
        let storeURL = tempDir.appending(path: "default.store")
        let seededTitle = "Quarterly planning"
        let seededDate = Date(timeIntervalSince1970: 1_700_000_000)

        // 1. Seed a store with ONLY the v0.7.1 schema, then release it.
        try autoreleasepool {
            let v1Schema = Schema(versionedSchema: CasablancaSchemaV1.self)
            let config = ModelConfiguration(schema: v1Schema, url: storeURL)
            let container = try ModelContainer(for: v1Schema, configurations: config)
            let context = ModelContext(container)

            let meeting = CasablancaSchemaV1.Meeting(title: seededTitle, date: seededDate)
            context.insert(meeting)
            try context.save()
        }

        // 2. Reopen the SAME file via the production path: current schema +
        //    explicit migration plan.
        let result = try PersistenceController.makeContainer(storeURL: storeURL) { url in
            let config = ModelConfiguration(url: url)
            return try ModelContainer(
                for: Meeting.self, TodoItem.self,
                migrationPlan: CasablancaMigrationPlan.self,
                configurations: config
            )
        }

        // 3. The seeded meeting survives the migration with fields intact and the
        //    new `tags` defaulted.
        let context = ModelContext(result.container)
        let meetings = try context.fetch(FetchDescriptor<Meeting>())

        XCTAssertEqual(meetings.count, 1, "the v0.7.1 meeting must survive the migration")
        let migrated = try XCTUnwrap(meetings.first)
        XCTAssertEqual(migrated.title, seededTitle)
        XCTAssertEqual(migrated.date, seededDate)
        XCTAssertEqual(migrated.tags, [], "new `tags` property should default to []")
        XCTAssertEqual(migrated.localPrepNotes, "", "new `localPrepNotes` property should default to \"\"")
    }
    // MARK: - V2 -> V3

    func testV2StoreMigratesToV3PreservingMeetingsAndTodos() throws {
        let storeURL = tempDir.appending(path: "default.store")
        let seededDate = Date(timeIntervalSince1970: 1_750_000_000)

        // 1. Seed a store with ONLY the frozen V2 schema, then release it.
        try autoreleasepool {
            let v2Schema = Schema(versionedSchema: CasablancaSchemaV2.self)
            let config = ModelConfiguration(schema: v2Schema, url: storeURL)
            let container = try ModelContainer(for: v2Schema, configurations: config)
            let context = ModelContext(container)

            let meeting = CasablancaSchemaV2.Meeting(title: "Sprint review", date: seededDate)
            meeting.transcript = "Hello world"
            meeting.tags = ["link"]
            meeting.localPrepNotes = "prep"
            context.insert(meeting)
            let first = CasablancaSchemaV2.TodoItem(text: "Send minutes", meeting: meeting)
            let second = CasablancaSchemaV2.TodoItem(text: "Book room", isCompleted: true, meeting: meeting)
            context.insert(first)
            context.insert(second)
            try context.save()
        }

        // 2. Reopen via the production path: top-level models + migration plan.
        let result = try PersistenceController.makeContainer(storeURL: storeURL) { url in
            let config = ModelConfiguration(url: url)
            return try ModelContainer(
                for: Meeting.self, TodoItem.self,
                migrationPlan: CasablancaMigrationPlan.self,
                configurations: config
            )
        }

        XCTAssertEqual(result.recovery, .clean, "the V2 store must open via migration, not via backup-and-recreate")
        let context = ModelContext(result.container)
        let meetings = try context.fetch(FetchDescriptor<Meeting>())
        XCTAssertEqual(meetings.count, 1, "the V2 meeting must survive the migration")
        let migrated = try XCTUnwrap(meetings.first)
        XCTAssertEqual(migrated.title, "Sprint review")
        XCTAssertEqual(migrated.date, seededDate)
        XCTAssertEqual(migrated.transcript, "Hello world")
        XCTAssertEqual(migrated.tags, ["link"])
        XCTAssertEqual(migrated.localPrepNotes, "prep")
        XCTAssertNil(migrated.speakerSegmentsData)
        XCTAssertNil(migrated.speakersData)
        XCTAssertNil(migrated.actionItemsData)
        XCTAssertNil(migrated.summaryTemplateID)
        XCTAssertNil(migrated.micTrackFileURL)
        XCTAssertNil(migrated.systemTrackFileURL)
        XCTAssertEqual(migrated.speakerSegments, [])
        XCTAssertEqual(migrated.speakers, [])
        XCTAssertEqual(migrated.actionItems, [])

        let todos = try context.fetch(FetchDescriptor<TodoItem>())
        XCTAssertEqual(todos.count, 2, "both V2 to-dos must survive the migration")
        XCTAssertEqual(Set(todos.map(\.text)), ["Send minutes", "Book room"])
        XCTAssertEqual(migrated.todos.count, 2, "the meeting relationship must survive")
        for todo in todos {
            XCTAssertEqual(todo.status, .accepted, "existing to-dos must read as accepted")
            XCTAssertEqual(todo.statusRaw, TodoStatus.accepted.rawValue)
            XCTAssertNil(todo.owner)
            XCTAssertNil(todo.dueDate)
            XCTAssertNil(todo.sourceTimestamp)
            XCTAssertNil(todo.quote)
            XCTAssertNil(todo.verificationRaw)
            XCTAssertNil(todo.verification)
        }
        XCTAssertEqual(todos.first { $0.text == "Book room" }?.isCompleted, true)
    }

    /// The fetch predicates the sidebar badge and the Todos view use must see
    /// migrated legacy to-dos as accepted: `statusRaw` has to be stored as
    /// "accepted" (not NULL) in the migrated store, or the SQL-side predicate
    /// would drop them even though the Swift accessor reads them as accepted.
    func testV2TodosMatchTheTodoCountingPredicatesAfterMigration() throws {
        let storeURL = tempDir.appending(path: "default.store")

        try autoreleasepool {
            let v2Schema = Schema(versionedSchema: CasablancaSchemaV2.self)
            let config = ModelConfiguration(schema: v2Schema, url: storeURL)
            let container = try ModelContainer(for: v2Schema, configurations: config)
            let context = ModelContext(container)

            let meeting = CasablancaSchemaV2.Meeting(title: "Sprint review", date: Date(timeIntervalSince1970: 1_750_000_000))
            context.insert(meeting)
            context.insert(CasablancaSchemaV2.TodoItem(text: "Send minutes", meeting: meeting))
            context.insert(CasablancaSchemaV2.TodoItem(text: "Book room", isCompleted: true, meeting: meeting))
            context.insert(CasablancaSchemaV2.TodoItem(text: "Loose task"))
            try context.save()
        }

        let result = try PersistenceController.makeContainer(storeURL: storeURL) { url in
            try ModelContainer(
                for: Meeting.self, TodoItem.self,
                migrationPlan: CasablancaMigrationPlan.self,
                configurations: ModelConfiguration(url: url)
            )
        }
        XCTAssertEqual(result.recovery, .clean)
        let context = ModelContext(result.container)

        let open = try context.fetch(FetchDescriptor<TodoItem>(predicate: TodoCounting.openTodoPredicate))
        XCTAssertEqual(Set(open.map(\.text)), ["Send minutes", "Loose task"],
                       "migrated open to-dos count as open; the completed one does not")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TodoItem>(predicate: TodoCounting.openTodoPredicate)), 2)

        let visible = try context.fetch(FetchDescriptor<TodoItem>(predicate: TodoCounting.notRejectedPredicate))
        XCTAssertEqual(Set(visible.map(\.text)), ["Send minutes", "Book room", "Loose task"],
                       "every migrated to-do, completed included, is shown")
    }

    func testTodoStatusUnknownRawIsAccepted() {
        let todo = TodoItem(text: "x")
        XCTAssertEqual(todo.status, .accepted, "new to-dos default to accepted")
        todo.statusRaw = "somethingElse"
        XCTAssertEqual(todo.status, .accepted, "unknown raw falls back to accepted")
        todo.status = .proposed
        XCTAssertEqual(todo.statusRaw, "proposed")
        XCTAssertEqual(todo.status, .proposed)
        todo.status = .rejected
        XCTAssertEqual(todo.status, .rejected)

        XCTAssertNil(todo.verification)
        todo.verification = .supported
        XCTAssertEqual(todo.verificationRaw, "supported")
        XCTAssertEqual(todo.verification, .supported)
        todo.verificationRaw = "bogus"
        XCTAssertNil(todo.verification, "unknown verification raw reads as nil")
        todo.verification = nil
        XCTAssertNil(todo.verificationRaw)
    }

    func testMeetingSpeakerAccessorsRoundTrip() {
        let meeting = Meeting(title: "Round trip", date: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(meeting.speakerSegments, [])
        XCTAssertEqual(meeting.speakers, [])
        XCTAssertEqual(meeting.actionItems, [])

        let segments = [
            SpeakerSegment(start: 0, end: 1.5, speakerID: "S1", text: "Hi",
                           words: [TranscriptWord(start: 0, end: 0.5, text: "Hi")]),
            SpeakerSegment(start: 1.5, end: 3, speakerID: nil, text: "there", words: nil)
        ]
        let speakers = [
            SpeakerInfo(id: "S1", displayName: "Youri", source: .microphone, isUser: true, nameConfirmed: true)
        ]
        let items = [
            ExtractedActionItem(task: "Ship it", owner: "Youri", due: "2026-11-10", dueIsExplicit: true,
                                confidence: 0.9, quote: "I'll ship it", timestamp: "00:01",
                                verified: .supported, verificationReason: nil)
        ]

        meeting.speakerSegments = segments
        meeting.speakers = speakers
        meeting.actionItems = items

        XCTAssertNotNil(meeting.speakerSegmentsData)
        XCTAssertNotNil(meeting.speakersData)
        XCTAssertNotNil(meeting.actionItemsData)
        XCTAssertEqual(meeting.speakerSegments, segments)
        XCTAssertEqual(meeting.speakers, speakers)
        XCTAssertEqual(meeting.actionItems, items)

        meeting.speakersData = Data("not json".utf8)
        XCTAssertEqual(meeting.speakers, [], "unreadable blob degrades to []")
    }
}
