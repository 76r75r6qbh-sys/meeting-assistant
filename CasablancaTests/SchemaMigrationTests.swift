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
}
