import XCTest
import SwiftData
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

    /// Mirror of PersistenceController's private stamp format for assertions.
    private func stampString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
