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
    ///
    /// Wires the explicit, versioned ``CasablancaMigrationPlan`` into the real
    /// `ModelContainer` so schema upgrades are deterministic across macOS
    /// versions instead of relying on SwiftData's inferred migration (whose
    /// behavior varied by OS — at least one real v0.8.0 store lost data).
    static func makeAppContainer() throws -> Result {
        try makeContainer(storeURL: defaultStoreURL) { url in
            let configuration = ModelConfiguration(url: url)
            return try ModelContainer(
                for: Meeting.self, TodoItem.self,
                migrationPlan: CasablancaMigrationPlan.self,
                configurations: configuration
            )
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
        // THE GUARANTEE: before the (migrating) container opens, copy the existing
        // store aside. This runs every launch, so the exact pre-migration state is
        // always recoverable regardless of what the migration does to the live
        // store — independent of OS, schema delta, or migration strategy. The
        // copy is best-effort: a failure is logged but must never block launch.
        backUpStore(at: storeURL, keeping: 3, now: now())

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

    /// Suffix marking a pre-open backup set member: `<file>.<stamp>.pre-open-backup`.
    static let preOpenBackupSuffix = "pre-open-backup"

    /// Pre-migration backup net (the data-loss GUARANTEE).
    ///
    /// Before the migrating `ModelContainer` opens, **copies** the store file and
    /// its `-wal`/`-shm` sidecars aside to a single timestamped backup set, e.g.
    /// `default.store.<UTCyyyyMMdd-HHmmss>.pre-open-backup`. Because the copy
    /// happens before the container migrates the live store, the exact
    /// pre-migration state is always recoverable — no matter what the migration
    /// (inferred or explicit) does, or on which macOS version.
    ///
    /// Retention: keeps only the most recent `keeping` backup SETS (grouped by
    /// timestamp), pruning older ones so backups don't grow without bound.
    ///
    /// Entirely best-effort: every filesystem failure is logged via
    /// `Log.persistence` and swallowed — this MUST NOT block app launch. A missing
    /// store is a no-op (nothing to back up, e.g. first launch).
    ///
    /// - Parameters:
    ///   - storeURL: the live store whose files get copied aside.
    ///   - keeping: how many recent backup sets to retain (older ones pruned).
    ///   - fileManager: injectable for tests.
    ///   - now: injectable clock for a deterministic backup timestamp.
    /// - Returns: the URLs created for this backup set (empty if nothing was
    ///   backed up).
    @discardableResult
    static func backUpStore(
        at storeURL: URL,
        keeping: Int = 3,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) -> [URL] {
        // No store yet (first launch / fresh install): nothing to protect.
        guard fileManager.fileExists(atPath: storeURL.path) else { return [] }

        let stamp = stampString(from: now)
        var created: [URL] = []

        for source in storeFileURLs(for: storeURL) where fileManager.fileExists(atPath: source.path) {
            let destination = source.deletingLastPathComponent()
                .appending(path: "\(source.lastPathComponent).\(stamp).\(preOpenBackupSuffix)")
            do {
                // Defensive: a same-stamp backup already existing (e.g. two launches
                // in the same second) would make copyItem throw. Replace it so the
                // backup remains the freshest pre-open snapshot.
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.copyItem(at: source, to: destination)
                created.append(destination)
            } catch {
                Log.persistence.error(
                    "Pre-open store backup failed for \(source.lastPathComponent, privacy: .public): \(error.localizedDescription)"
                )
            }
        }

        if !created.isEmpty {
            Log.persistence.info(
                "Pre-open store backup: copied \(created.count, privacy: .public) file(s) to \(stamp, privacy: .public).\(preOpenBackupSuffix)"
            )
        }

        pruneBackupSets(for: storeURL, keeping: keeping, fileManager: fileManager)

        return created
    }

    /// Keeps only the most recent `keeping` pre-open backup sets next to the store,
    /// removing older sets (all files sharing an older timestamp). Best-effort:
    /// failures are logged, never fatal.
    private static func pruneBackupSets(
        for storeURL: URL,
        keeping: Int,
        fileManager: FileManager
    ) {
        let dir = storeURL.deletingLastPathComponent()
        // Match every member of a backup set. The main file's backup is
        // `default.store.<stamp>.pre-open-backup`; the sidecars are
        // `default.store-wal.<stamp>...` / `default.store-shm.<stamp>...`. All
        // share the bare store name as a prefix (no trailing dot — that would
        // exclude the `-wal`/`-shm` members).
        let prefix = storeURL.lastPathComponent
        let backupSuffix = ".\(preOpenBackupSuffix)"

        guard let entries = try? fileManager.contentsOfDirectory(atPath: dir.path) else { return }

        // Group backup files by their timestamp token so a whole set is pruned
        // together. Filename shape: <storeName>.<sidecar?>.<stamp>.pre-open-backup
        // The stamp is the second-to-last dot component.
        var setsByStamp: [String: [URL]] = [:]
        for name in entries where name.hasPrefix(prefix) && name.hasSuffix(backupSuffix) {
            let withoutSuffix = String(name.dropLast(backupSuffix.count))
            guard let stamp = withoutSuffix.split(separator: ".").last.map(String.init) else { continue }
            setsByStamp[stamp, default: []].append(dir.appending(path: name))
        }

        guard setsByStamp.count > keeping else { return }

        // Lexicographic sort over `yyyyMMdd-HHmmss` is chronological. Drop the
        // newest `keeping` stamps; everything older is pruned.
        let stampsToPrune = setsByStamp.keys.sorted().dropLast(keeping)
        for stamp in stampsToPrune {
            for url in setsByStamp[stamp] ?? [] {
                do {
                    try fileManager.removeItem(at: url)
                } catch {
                    Log.persistence.error(
                        "Failed to prune old backup \(url.lastPathComponent, privacy: .public): \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    private static func stampString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
