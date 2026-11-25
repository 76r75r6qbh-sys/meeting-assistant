import XCTest
import SwiftData
import SQLite3
@testable import Casablanca

final class PersistenceControllerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL.temporaryDirectory.appending(path: "PersistenceControllerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
    }

    private func storeURL() -> URL {
        tempDir.appending(path: "default.store")
    }

    /// Writes placeholder files standing in for the corrupt store + sidecars so
    /// the backup path has something to move.
    private func writeStubStoreFiles(at storeURL: URL) throws {
        for url in PersistenceController.storeFileURLs(for: storeURL) {
            try Data("stub".utf8).write(to: url)
        }
    }

    // MARK: - Backup path

    func test_recovery_backsUpCorruptStoreAndRecreates() throws {
        let storeURL = storeURL()
        try writeStubStoreFiles(at: storeURL)

        var attempts = 0
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

        let result = try PersistenceController.makeContainer(
            storeURL: storeURL,
            now: { fixedDate }
        ) { url in
            attempts += 1
            if attempts == 1 {
                // First call simulates the corrupt/incompatible store.
                throw CocoaError(.fileReadCorruptFile)
            }
            // Retry after backup succeeds with an in-memory store so the test
            // doesn't depend on the renamed files (which were moved aside).
            _ = url
            let config = ModelConfiguration(isStoredInMemoryOnly: true)
            return try ModelContainer(for: Meeting.self, TodoItem.self, configurations: config)
        }

        // Built twice: failed once, recovered once.
        XCTAssertEqual(attempts, 2)

        guard case .recovered(let backups) = result.recovery else {
            return XCTFail("Expected .recovered, got \(result.recovery)")
        }
        // All three original files were backed up.
        XCTAssertEqual(backups.count, 3)

        let fm = FileManager.default
        for backup in backups {
            XCTAssertTrue(backup.lastPathComponent.hasSuffix(".corrupt-backup"))
            XCTAssertTrue(fm.fileExists(atPath: backup.path), "backup should exist: \(backup.lastPathComponent)")
        }
        // Originals were renamed (moved), not copied: they should be gone.
        for original in PersistenceController.storeFileURLs(for: storeURL) {
            XCTAssertFalse(fm.fileExists(atPath: original.path), "original should be moved away: \(original.lastPathComponent)")
        }
    }

    // MARK: - Clean path

    func test_cleanOpen_doesNotTouchStoreFiles() throws {
        let storeURL = storeURL()
        try writeStubStoreFiles(at: storeURL)

        let result = try PersistenceController.makeContainer(storeURL: storeURL) { _ in
            let config = ModelConfiguration(isStoredInMemoryOnly: true)
            return try ModelContainer(for: Meeting.self, TodoItem.self, configurations: config)
        }

        XCTAssertEqual(result.recovery, .clean)
        // No backups created on the happy path.
        let contents = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertFalse(contents.contains { $0.hasSuffix(".corrupt-backup") })
    }

    // MARK: - Unrecoverable path

    func test_recovery_propagatesErrorWhenFreshStoreAlsoFails() throws {
        let storeURL = storeURL()
        try writeStubStoreFiles(at: storeURL)

        struct FreshStoreError: Error {}

        XCTAssertThrowsError(
            try PersistenceController.makeContainer(storeURL: storeURL) { _ in
                // Always fails, including the post-backup retry.
                throw FreshStoreError()
            }
        ) { error in
            XCTAssertTrue(error is FreshStoreError)
        }

        // Even on unrecoverable failure, the corrupt store was still backed up
        // (data preserved), not left in place or deleted.
        let contents = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertEqual(contents.filter { $0.hasSuffix(".corrupt-backup") }.count, 3)
    }

    // MARK: - Backup mechanics

    func test_backUpStoreFiles_skipsMissingFiles() throws {
        let storeURL = storeURL()
        // Only create the main file, not the sidecars.
        try Data("stub".utf8).write(to: storeURL)

        let backups = PersistenceController.backUpStoreFiles(storeURL: storeURL)

        XCTAssertEqual(backups.count, 1)
        XCTAssertTrue(backups[0].lastPathComponent.hasPrefix("default.store."))
    }

    // MARK: - Pre-open backup net (the data-loss guarantee)

    private func backupSuffix() -> String { ".pre-open-backup" }

    func test_backUpStore_copiesStoreAndSidecars_leavingOriginalsInPlace() throws {
        let storeURL = storeURL()
        try writeStubStoreFiles(at: storeURL)
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

        let created = PersistenceController.backUpStore(at: storeURL, keeping: 3, now: fixedDate)

        // A full backup set: store + -wal + -shm.
        XCTAssertEqual(created.count, 3)
        let fm = FileManager.default
        for url in created {
            XCTAssertTrue(url.lastPathComponent.hasSuffix(backupSuffix()))
            XCTAssertTrue(fm.fileExists(atPath: url.path), "backup should exist: \(url.lastPathComponent)")
        }
        // COPY, not move: the live store files must still be in place.
        for original in PersistenceController.storeFileURLs(for: storeURL) {
            XCTAssertTrue(fm.fileExists(atPath: original.path), "original must remain: \(original.lastPathComponent)")
        }
    }

    func test_backUpStore_missingStore_isNoOp() throws {
        // No store file written at all.
        let created = PersistenceController.backUpStore(at: storeURL(), keeping: 3)

        XCTAssertEqual(created, [])
        let contents = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertTrue(contents.isEmpty, "missing store must produce no backups")
    }

    func test_backUpStore_prunesToMostRecentThreeSets() throws {
        let storeURL = storeURL()
        try writeStubStoreFiles(at: storeURL)

        // Five launches at distinct, increasing timestamps → five backup sets.
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for offset in 0..<5 {
            let when = base.addingTimeInterval(TimeInterval(offset))
            PersistenceController.backUpStore(at: storeURL, keeping: 3, now: when)
        }

        let fm = FileManager.default
        let backupNames = try fm.contentsOfDirectory(atPath: tempDir.path)
            .filter { $0.hasSuffix(backupSuffix()) }

        // Each set has 3 files; only the most recent 3 sets survive → 9 files.
        XCTAssertEqual(backupNames.count, 9, "should keep exactly 3 backup sets")

        // Distinct stamp tokens (second-to-last dot component) should number 3.
        let stamps = Set(backupNames.compactMap { name -> String? in
            let withoutSuffix = String(name.dropLast(backupSuffix().count))
            return withoutSuffix.split(separator: ".").last.map(String.init)
        })
        XCTAssertEqual(stamps.count, 3)

        // The pruned (oldest two) stamps must be gone; the newest three kept.
        let kept = (2...4).map { offset in
            stampString(from: base.addingTimeInterval(TimeInterval(offset)))
        }
        let pruned = (0...1).map { offset in
            stampString(from: base.addingTimeInterval(TimeInterval(offset)))
        }
        XCTAssertTrue(kept.allSatisfy { stamps.contains($0) }, "newest 3 stamps must be kept")
        XCTAssertTrue(pruned.allSatisfy { !stamps.contains($0) }, "oldest 2 stamps must be pruned")
    }

    // MARK: - Namespaced store location

    func test_appStoreURL_isNamespacedUnderCasablanca_notTheSharedDefault() {
        let url = PersistenceController.storeURL
        XCTAssertEqual(url.lastPathComponent, "Casablanca.store")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Casablanca")
        XCTAssertNotEqual(url.standardizedFileURL, PersistenceController.legacyStoreURL.standardizedFileURL)
        XCTAssertEqual(PersistenceController.legacyStoreURL.lastPathComponent, "default.store")
    }

    // MARK: - One-time legacy migration

    private var legacyURL: URL { tempDir.appending(path: "legacy/default.store") }
    private var newURL: URL { tempDir.appending(path: "new/Casablanca/Casablanca.store") }
    private var newDir: URL { newURL.deletingLastPathComponent() }
    private var markerURL: URL { newDir.appending(path: PersistenceController.legacyMigrationMarkerName) }

    /// Snapshot of every existing legacy file's bytes, keyed by file name.
    private func snapshot(of storeURL: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for url in PersistenceController.storeFileURLs(for: storeURL)
        where FileManager.default.fileExists(atPath: url.path) {
            result[url.lastPathComponent] = try Data(contentsOf: url)
        }
        return result
    }

    private func newDirContents() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: newDir.path)) ?? []).sorted()
    }

    private func makeLegacyDirectory() throws {
        try FileManager.default.createDirectory(
            at: legacyURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
    }

    /// Opens (creating) a raw SQLite database at `url` and runs `sql`. The caller
    /// owns the returned handle and must close it.
    private func openRawStore(at url: URL, sql: String) throws -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw CocoaError(.fileWriteUnknown)
        }
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? "?"
            sqlite3_free(message)
            sqlite3_close(db)
            throw NSError(domain: "sqlite", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
        }
        return db
    }

    /// Creates a raw SQLite database at `url` with only the given tables, standing
    /// in for another app's (or a partial) SwiftData store at the shared path.
    private func makeRawStore(at url: URL, tables: [String]) throws {
        let sql = tables.map { "CREATE TABLE \($0) (Z_PK INTEGER PRIMARY KEY, ZVALUE VARCHAR);" }.joined()
        sqlite3_close(try openRawStore(at: url, sql: sql))
    }

    /// Minimal Casablanca-shaped schema: the Meeting/TodoItem tables plus the
    /// Core Data `Z_PRIMARYKEY` entity registry, with one meeting row.
    private let casablancaShapedSQL = """
        CREATE TABLE ZMEETING (Z_PK INTEGER PRIMARY KEY, ZTITLE VARCHAR);
        CREATE TABLE ZTODOITEM (Z_PK INTEGER PRIMARY KEY, ZTEXT VARCHAR);
        CREATE TABLE Z_PRIMARYKEY (Z_ENT INTEGER PRIMARY KEY, Z_NAME VARCHAR, Z_SUPER INTEGER, Z_MAX INTEGER);
        INSERT INTO Z_PRIMARYKEY VALUES (1, 'Meeting', 0, 1), (2, 'TodoItem', 0, 0);
        INSERT INTO ZMEETING VALUES (1, 'WAL-only meeting');
        """

    private func meetingTitles(inRawStoreAt url: URL) -> [String] {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT ZTITLE FROM ZMEETING ORDER BY Z_PK;", -1, &statement, nil) == SQLITE_OK else { return [] }
        var titles: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            titles.append(String(cString: sqlite3_column_text(statement, 0)))
        }
        return titles
    }

    func test_migration_copiesCasablancaLegacyStore_asSingleFile_andLeavesLegacyUntouched() throws {
        try makeLegacyDirectory()
        let seededTitle = "Legacy weekly sync"
        try autoreleasepool {
            let config = ModelConfiguration(url: legacyURL)
            let container = try ModelContainer(
                for: Meeting.self, TodoItem.self,
                migrationPlan: CasablancaMigrationPlan.self,
                configurations: config
            )
            let context = ModelContext(container)
            context.insert(Meeting(title: seededTitle, date: Date(timeIntervalSince1970: 1_700_000_000)))
            try context.save()
        }
        let before = try snapshot(of: legacyURL)
        XCTAssertNotNil(before["default.store"])

        let outcome = PersistenceController.migrateLegacyStoreIfNeeded(from: legacyURL, to: newURL)

        XCTAssertEqual(outcome, .migrated)
        // Exactly one self-contained store file plus the decision marker: no
        // sidecars, no staging leftovers.
        XCTAssertEqual(newDirContents(), [PersistenceController.legacyMigrationMarkerName, "Casablanca.store"].sorted())
        // Legacy files are byte-identical: copied, never moved, opened or modified.
        XCTAssertEqual(try snapshot(of: legacyURL), before)

        let container = try ModelContainer(
            for: Meeting.self, TodoItem.self,
            migrationPlan: CasablancaMigrationPlan.self,
            configurations: ModelConfiguration(url: newURL)
        )
        let meetings = try ModelContext(container).fetch(FetchDescriptor<Meeting>())
        XCTAssertEqual(meetings.map(\.title), [seededTitle])
    }

    func test_migration_schemaOnlyInWAL_withLiveConnection_migrates_andLegacyUnchanged() throws {
        try makeLegacyDirectory()
        // A live writer in WAL mode that never checkpoints: the whole schema and
        // data exist only in the -wal file while we migrate.
        let liveDB = try openRawStore(
            at: legacyURL,
            sql: "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;" + casablancaShapedSQL
        )
        defer { sqlite3_close(liveDB) }
        let before = try snapshot(of: legacyURL)
        XCTAssertNotNil(before["default.store-wal"], "precondition: data must live in the WAL")

        let outcome = PersistenceController.migrateLegacyStoreIfNeeded(from: legacyURL, to: newURL)

        XCTAssertEqual(outcome, .migrated)
        XCTAssertEqual(meetingTitles(inRawStoreAt: newURL), ["WAL-only meeting"])
        XCTAssertEqual(try snapshot(of: legacyURL), before)
    }

    func test_migration_foreignStore_isSkipped_nothingCreated_markerWritten() throws {
        try makeLegacyDirectory()
        try makeRawStore(at: legacyURL, tables: ["ZAPIREQUESTMODEL"])
        let before = try snapshot(of: legacyURL)

        let outcome = PersistenceController.migrateLegacyStoreIfNeeded(from: legacyURL, to: newURL)

        XCTAssertEqual(outcome, .skippedForeignStore)
        XCTAssertEqual(newDirContents(), [PersistenceController.legacyMigrationMarkerName])
        XCTAssertEqual(try snapshot(of: legacyURL), before)
    }

    func test_migration_meetingTableWithoutTodoTable_isForeign() throws {
        try makeLegacyDirectory()
        try makeRawStore(at: legacyURL, tables: ["ZMEETING"])

        let outcome = PersistenceController.migrateLegacyStoreIfNeeded(from: legacyURL, to: newURL)

        XCTAssertEqual(outcome, .skippedForeignStore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: newURL.path))
    }

    func test_migration_notSQLiteLegacyFile_isForeign_markerWritten() throws {
        try makeLegacyDirectory()
        try Data(repeating: 0xAB, count: 8192).write(to: legacyURL)
        let before = try snapshot(of: legacyURL)

        let outcome = PersistenceController.migrateLegacyStoreIfNeeded(from: legacyURL, to: newURL)

        XCTAssertEqual(outcome, .skippedForeignStore)
        XCTAssertEqual(newDirContents(), [PersistenceController.legacyMigrationMarkerName])
        XCTAssertEqual(try snapshot(of: legacyURL), before)
    }

    /// A Casablanca-shaped store whose schema reads fine but whose data pages are
    /// damaged, so `PRAGMA quick_check` fails. Rollback-journal mode keeps every
    /// page in the main file so the damage is deterministic.
    private func makeDamagedCasablancaStore(at url: URL) throws {
        let rows = (2...400).map { "(\($0), '\(String(repeating: "x", count: 500))')" }.joined(separator: ",")
        sqlite3_close(try openRawStore(
            at: url,
            sql: "PRAGMA page_size=4096; PRAGMA journal_mode=DELETE;" + casablancaShapedSQL
                + "INSERT INTO ZMEETING VALUES \(rows);"
        ))
        var bytes = try Data(contentsOf: url)
        let pageSize = 4096
        let pageCount = bytes.count / pageSize
        XCTAssertGreaterThan(pageCount, 20, "precondition: enough data pages to damage one")
        // Trash a data page near the end, far away from page 1 (sqlite_master)
        // and the tables' early root pages.
        let start = (pageCount - 2) * pageSize
        bytes.replaceSubrange(start..<(start + pageSize), with: Data(repeating: 0xFF, count: pageSize))
        try bytes.write(to: url)
    }

    /// Counts copies of the legacy main file, i.e. staging attempts.
    private final class CountingFileManager: FileManager {
        var mainFileCopies = 0
        override func copyItem(at srcURL: URL, to dstURL: URL) throws {
            if srcURL.lastPathComponent == "default.store" { mainFileCopies += 1 }
            try super.copyItem(at: srcURL, to: dstURL)
        }
    }

    func test_migration_damagedCasablancaStore_retriesOnce_thenSkipsWithMarker_legacyUnchanged() throws {
        try makeLegacyDirectory()
        try makeDamagedCasablancaStore(at: legacyURL)
        let before = try snapshot(of: legacyURL)
        let fileManager = CountingFileManager()

        let outcome = PersistenceController.migrateLegacyStoreIfNeeded(
            from: legacyURL, to: newURL, fileManager: fileManager
        )

        XCTAssertEqual(outcome, .skippedUnreadableCasablancaStore)
        XCTAssertEqual(fileManager.mainFileCopies, 2, "a torn copy is retried exactly once")
        XCTAssertEqual(newDirContents(), [PersistenceController.legacyMigrationMarkerName])
        XCTAssertEqual(try snapshot(of: legacyURL), before)
    }

    func test_appContainer_damagedCasablancaStore_opensFreshOnDiskStore_andReportsIt() throws {
        try makeLegacyDirectory()
        try makeDamagedCasablancaStore(at: legacyURL)
        let before = try snapshot(of: legacyURL)

        let result = try PersistenceController.makeAppContainer(storeURL: newURL, legacyStoreURL: legacyURL)

        XCTAssertEqual(result.recovery, .legacyStoreNotCopied(legacyStoreURL: legacyURL))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newURL.path), "a fresh on-disk store, not in-memory")
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
        XCTAssertEqual(try snapshot(of: legacyURL), before)
    }

    /// Lets the copy succeed but fails the final move into place.
    private final class FailingMoveFileManager: FileManager {
        override func moveItem(at srcURL: URL, to dstURL: URL) throws {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    func test_migration_moveFailure_fails_leavesNothingAtDestination() throws {
        try makeLegacyDirectory()
        sqlite3_close(try openRawStore(at: legacyURL, sql: casablancaShapedSQL))
        let before = try snapshot(of: legacyURL)

        let outcome = PersistenceController.migrateLegacyStoreIfNeeded(
            from: legacyURL, to: newURL, fileManager: FailingMoveFileManager()
        )

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(newDirContents(), [])
        XCTAssertEqual(try snapshot(of: legacyURL), before)
    }

    func test_migration_markerPresent_isSkipped_evenWithAValidLegacyStore() throws {
        try makeLegacyDirectory()
        sqlite3_close(try openRawStore(at: legacyURL, sql: casablancaShapedSQL))
        try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        try Data().write(to: markerURL)

        let outcome = PersistenceController.migrateLegacyStoreIfNeeded(from: legacyURL, to: newURL)

        XCTAssertEqual(outcome, .skippedAlreadyDecided)
        XCTAssertFalse(FileManager.default.fileExists(atPath: newURL.path), "stale legacy data must not be re-imported")
    }

    func test_migration_newStoreAlreadyExists_isSkipped_notOverwritten_markerWritten() throws {
        try makeLegacyDirectory()
        sqlite3_close(try openRawStore(at: legacyURL, sql: casablancaShapedSQL))
        try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        let existing = Data("existing new store".utf8)
        try existing.write(to: newURL)

        let outcome = PersistenceController.migrateLegacyStoreIfNeeded(from: legacyURL, to: newURL)

        XCTAssertEqual(outcome, .skippedNewStoreExists)
        XCTAssertEqual(try Data(contentsOf: newURL), existing)
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
    }

    func test_migration_noLegacyStore_isSkipped_markerWritten() throws {
        let outcome = PersistenceController.migrateLegacyStoreIfNeeded(from: legacyURL, to: newURL)

        XCTAssertEqual(outcome, .skippedNoLegacyStore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: newURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
    }

    func test_migration_sweepsLeftoverStagingDirectories() throws {
        let leftover = newDir.appending(path: ".legacy-store-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: leftover.appending(path: "Casablanca.store"))

        _ = PersistenceController.migrateLegacyStoreIfNeeded(from: legacyURL, to: newURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
        XCTAssertEqual(newDirContents(), [PersistenceController.legacyMigrationMarkerName])
    }

    // MARK: - App container + migration

    func test_appContainer_filesystemFailure_usesInMemoryStore_andCreatesNothing() throws {
        try makeLegacyDirectory()
        sqlite3_close(try openRawStore(at: legacyURL, sql: casablancaShapedSQL))
        let before = try snapshot(of: legacyURL)

        let result = try PersistenceController.makeAppContainer(
            storeURL: newURL, legacyStoreURL: legacyURL, fileManager: FailingMoveFileManager()
        )
        XCTAssertEqual(try snapshot(of: legacyURL), before)

        XCTAssertEqual(result.recovery, .migrationFailed(legacyStoreURL: legacyURL))
        // No empty store (it would block the retry forever) and no marker.
        XCTAssertEqual(newDirContents(), [])
        // The in-memory container still works.
        let context = ModelContext(result.container)
        context.insert(Meeting(title: "temp", date: .now))
        XCTAssertNoThrow(try context.save())
        XCTAssertEqual(newDirContents(), [])
    }

    func test_appContainer_notSQLiteLegacy_opensFreshStoreCleanly() throws {
        try makeLegacyDirectory()
        try Data(repeating: 0xAB, count: 8192).write(to: legacyURL)

        let result = try PersistenceController.makeAppContainer(storeURL: newURL, legacyStoreURL: legacyURL)

        XCTAssertEqual(result.recovery, .clean)
        XCTAssertTrue(FileManager.default.fileExists(atPath: newURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
    }

    func test_migrationMarker_doesNotShareTheStagingPrefix() {
        XCTAssertEqual(PersistenceController.legacyMigrationMarkerName, ".casablanca-legacy-migration-done")
    }

    func test_appContainer_noLegacy_opensNamespacedStoreCleanly() throws {
        let result = try PersistenceController.makeAppContainer(storeURL: newURL, legacyStoreURL: legacyURL)

        XCTAssertEqual(result.recovery, .clean)
        XCTAssertTrue(FileManager.default.fileExists(atPath: newURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
    }

    /// Mirror of PersistenceController's private stamp format for assertions.
    private func stampString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
