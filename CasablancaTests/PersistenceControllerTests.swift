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
}
