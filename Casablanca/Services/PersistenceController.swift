import Foundation
import SwiftData

/// Creates the app's `ModelContainer` with corrupt-store recovery.
///
/// A store-grade app must never crash on launch because the persistent store
/// became corrupt or schema-incompatible. `makeContainer` therefore:
///   1. Tries to open the store normally.
///   2. On failure, **moves the existing store files aside** (timestamped
///      `.corrupt-backup` rename — never deletes, so the user's data is
///      recoverable) and tries again with a fresh store.
///   3. If even a fresh store can't be created, surfaces the failure as a
///      thrown error so the caller can present an alert instead of aborting.
///
/// The store URL is pinned to SwiftData's implicit default
/// (`Application Support/default.store`) so existing installs keep using the
/// same file and the recovery code knows exactly which files to back up.
enum PersistenceController {
    /// Outcome of opening the store, so the UI can inform the user when their
    /// data was set aside.
    enum Recovery: Equatable {
        /// Store opened normally; nothing was touched.
        case clean
        /// The original store was corrupt and backed up to these URLs; a fresh
        /// store is now in use.
        case recovered(backedUpTo: [URL])
    }

    struct Result {
        let container: ModelContainer
        let recovery: Recovery
    }

    /// SwiftData's implicit default store location for `ModelContainer(for:)`.
    static var defaultStoreURL: URL {
        URL.applicationSupportDirectory.appending(path: "default.store")
    }

    /// The store file and its WAL/SHM sidecars, in the order they should be
    /// backed up (main file last so a partial failure leaves the sidecars,
    /// not an orphaned main file, behind).
    static func storeFileURLs(for storeURL: URL) -> [URL] {
        let dir = storeURL.deletingLastPathComponent()
        let name = storeURL.lastPathComponent
        return [
            dir.appending(path: "\(name)-shm"),
            dir.appending(path: "\(name)-wal"),
            storeURL
        ]
    }

    /// Build the container for the real app, pinned to the default store URL.
    static func makeAppContainer() throws -> Result {
        try makeContainer(storeURL: defaultStoreURL) { url in
            let configuration = ModelConfiguration(url: url)
            return try ModelContainer(for: Meeting.self, TodoItem.self, configurations: configuration)
        }
    }

    /// Core recovery logic, parameterized over the container-building closure so
    /// tests can inject a closure that fails on the first (corrupt) store and
    /// succeeds on the fresh one — exercising the backup-and-retry path without
    /// a real corrupt store.
    ///
    /// - Parameters:
    ///   - storeURL: location of the store file whose sidecars get backed up.
    ///   - now: injectable clock for deterministic backup timestamps in tests.
    ///   - build: opens a container at the given URL, throwing on a bad store.
    static func makeContainer(
        storeURL: URL,
        now: () -> Date = Date.init,
        build: (URL) throws -> ModelContainer
    ) throws -> Result {
        do {
            return Result(container: try build(storeURL), recovery: .clean)
        } catch {
            Log.persistence.error(
                "ModelContainer creation failed; attempting corrupt-store recovery: \(error.localizedDescription)"
            )

            let backups = backUpStoreFiles(storeURL: storeURL, now: now())

            do {
                let container = try build(storeURL)
                Log.persistence.error(
                    "Recovered from corrupt store: backed up \(backups.count, privacy: .public) file(s) and recreated a fresh store."
                )
                return Result(container: container, recovery: .recovered(backedUpTo: backups))
            } catch {
                // Unrecoverable: even a fresh store failed. Surface to the caller
                // (which presents an alert) rather than crashing.
                Log.persistence.error(
                    "Corrupt-store recovery failed: fresh ModelContainer could not be created: \(error.localizedDescription)"
                )
                throw error
            }
        }
    }

    /// Renames each existing store file to a timestamped `.corrupt-backup`
    /// sibling. Best-effort and reversible: failures are logged, never fatal,
    /// and nothing is deleted. Returns the URLs the files were moved to.
    @discardableResult
    static func backUpStoreFiles(storeURL: URL, now: Date = Date()) -> [URL] {
        // Filesystem-friendly timestamp (no colons) for the backup filename.
        let stamp = stampString(from: now)

        let fileManager = FileManager.default
        var backedUp: [URL] = []

        for url in storeFileURLs(for: storeURL) where fileManager.fileExists(atPath: url.path) {
            let backupURL = url.deletingLastPathComponent()
                .appending(path: "\(url.lastPathComponent).\(stamp).corrupt-backup")
            do {
                // If a backup with this exact name already exists, remove it
                // first so the rename can proceed (extremely unlikely given the
                // timestamp, but keeps recovery deterministic).
                if fileManager.fileExists(atPath: backupURL.path) {
                    try fileManager.removeItem(at: backupURL)
                }
                try fileManager.moveItem(at: url, to: backupURL)
                backedUp.append(backupURL)
                Log.persistence.error(
                    "Backed up corrupt store file to \(backupURL.lastPathComponent, privacy: .public)"
                )
            } catch {
                Log.persistence.error(
                    "Failed to back up store file \(url.lastPathComponent, privacy: .public): \(error.localizedDescription)"
                )
            }
        }
        return backedUp
    }

    private static func stampString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
