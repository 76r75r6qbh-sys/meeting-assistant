import Foundation
import SQLite3
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
/// The store lives in the app's own folder
/// (`Application Support/Casablanca/Casablanca.store`). It used to be pinned to
/// SwiftData's implicit default (`Application Support/default.store`), but that
/// path is shared by every unsandboxed SwiftData app on the Mac: another app
/// overwrote it, and the recovery code then set *that app's* database aside.
/// Backups and recovery now only ever touch the namespaced store; the legacy
/// store is copied over once (see ``migrateLegacyStoreIfNeeded(from:to:fileManager:)``)
/// and is never opened or modified.
enum PersistenceController {
    /// Outcome of opening the store, so the UI can inform the user when their
    /// data was set aside.
    enum Recovery: Equatable {
        /// Store opened normally; nothing was touched.
        case clean
        /// The original store was corrupt and backed up to these URLs; a fresh
        /// store is now in use.
        case recovered(backedUpTo: [URL])
        /// The legacy store could not be migrated. Nothing was written to the new
        /// location (an empty store there would block the migration for good), so
        /// an in-memory store is in use and the next launch retries.
        case migrationFailed(legacyStoreURL: URL)
        /// The legacy store is Casablanca's but too damaged to copy. It was left
        /// unchanged and a fresh on-disk store is in use; this is not retried.
        case legacyStoreNotCopied(legacyStoreURL: URL)
    }

    struct Result {
        let container: ModelContainer
        let recovery: Recovery
    }

    /// SwiftData's implicit default store location for `ModelContainer(for:)`,
    /// where Casablanca kept its store until it moved into its own folder. Shared
    /// with any other unsandboxed SwiftData app, so it is only ever *copied* (for the
    /// one-time migration), never backed up, recovered or written.
    static var legacyStoreURL: URL {
        URL.applicationSupportDirectory.appending(path: "default.store")
    }

    /// The app's own store, namespaced under `Application Support/Casablanca/`
    /// next to Recordings, Transcriptions etc. so no other app can collide with it.
    static var storeURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "Casablanca", directoryHint: .isDirectory)
            .appending(path: "Casablanca.store")
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

    /// Build the container for the real app at the namespaced ``storeURL``,
    /// after the one-time copy of a legacy store.
    ///
    /// Wires the explicit, versioned ``CasablancaMigrationPlan`` into the real
    /// `ModelContainer` so schema upgrades are deterministic across macOS
    /// versions instead of relying on SwiftData's inferred migration (whose
    /// behavior varied by OS — at least one real v0.8.0 store lost data).
    ///
    /// If the legacy migration hits a filesystem failure, no store is created at
    /// `storeURL`: the app runs on an in-memory store
    /// (``Recovery/migrationFailed(legacyStoreURL:)``) and the next launch tries
    /// again. A legacy Casablanca store too damaged to copy is reported as
    /// ``Recovery/legacyStoreNotCopied(legacyStoreURL:)`` next to a fresh store.
    ///
    /// - Parameters: the URLs and file manager are injectable so tests stay out
    ///   of the real Application Support folder.
    static func makeAppContainer(
        storeURL: URL = storeURL,
        legacyStoreURL: URL = legacyStoreURL,
        fileManager: FileManager = .default
    ) throws -> Result {
        do {
            try FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
        } catch {
            // Let the container open surface the real failure (and recovery).
            Log.persistence.error("Could not create store directory: \(error.localizedDescription)")
        }
        // Before the pre-open backup, so a migrated store gets backed up too.
        let migration = migrateLegacyStoreIfNeeded(from: legacyStoreURL, to: storeURL, fileManager: fileManager)
        if migration == .failed {
            let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
            let container = try ModelContainer(for: Meeting.self, TodoItem.self, configurations: configuration)
            return Result(container: container, recovery: .migrationFailed(legacyStoreURL: legacyStoreURL))
        }

        let result = try makeContainer(storeURL: storeURL) { url in
            let configuration = ModelConfiguration(url: url)
            return try ModelContainer(
                for: Meeting.self, TodoItem.self,
                migrationPlan: CasablancaMigrationPlan.self,
                configurations: configuration
            )
        }
        if migration == .skippedUnreadableCasablancaStore, result.recovery == .clean {
            return Result(container: result.container, recovery: .legacyStoreNotCopied(legacyStoreURL: legacyStoreURL))
        }
        return result
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

    // MARK: - One-time legacy migration

    /// Written next to the new store once the migration reached a decision, so a
    /// later missing store never re-imports stale legacy data.
    static let legacyMigrationMarkerName = ".casablanca-legacy-migration-done"

    /// Prefix of the temporary staging folders next to the new store.
    private static let legacyMigrationStagingPrefix = ".legacy-store-migration-"

    /// Result of ``migrateLegacyStoreIfNeeded(from:to:fileManager:)``.
    enum LegacyMigrationOutcome: Equatable {
        /// The legacy store was Casablanca's and was copied to the new location.
        case migrated
        /// The new store already exists; nothing to migrate.
        case skippedNewStoreExists
        /// An earlier launch already decided (the marker exists).
        case skippedAlreadyDecided
        /// Nothing at the legacy path (fresh install, or already gone).
        case skippedNoLegacyStore
        /// The legacy file is not a Casablanca store: another app's database, or a
        /// file whose schema cannot even be read (not SQLite, encrypted, corrupt).
        /// It is left alone.
        case skippedForeignStore
        /// The legacy store is Casablanca's but failed `quick_check` or the export
        /// twice (one retry covers a copy torn by a concurrent writer). It is left
        /// unchanged and not retried; the app starts with a fresh store.
        case skippedUnreadableCasablancaStore
        /// A filesystem step of our own (staging, copy, move) failed. Nothing was
        /// written to the new location and no marker either, so the next launch
        /// retries. The legacy files are untouched.
        case failed
    }

    /// What the staged copy of a legacy database turned out to be.
    private enum StagedStoreCheck {
        /// Casablanca's, verified and exported to the single output file.
        case exported
        /// Not Casablanca's, or its schema could not be read at all.
        case foreign
        /// Casablanca's, but `quick_check` or the export failed.
        case damaged
    }

    /// Copies Casablanca's store from the shared legacy `default.store` to its
    /// namespaced location, once.
    ///
    /// Order of checks: the marker (an earlier decision is final), then an existing
    /// new store, then a missing legacy store. Otherwise the legacy store and its
    /// `-wal` are **copied** to a staging folder next to the new store; the legacy
    /// path is never opened with SQLite and never moved, modified or deleted —
    /// after the copy it belongs to whoever owns that path now. Ownership is
    /// decided first from the staged copy's schema (Meeting/TodoItem tables and
    /// entities). Only then is a Casablanca store verified (`PRAGMA quick_check`)
    /// and written out with `VACUUM INTO` as one self-contained, fsynced file that
    /// is moved into place in a single step. A damaged Casablanca store gets one
    /// retry with a fresh copy.
    ///
    /// Every decided outcome writes the marker; only `.failed` (a filesystem
    /// failure of our own) does not, so that one is retried on the next launch.
    ///
    /// Entirely best-effort: failures are logged via `Log.persistence` and nothing
    /// is thrown — this MUST NOT crash launch.
    ///
    /// - Parameters:
    ///   - legacyURL: the shared legacy store (``legacyStoreURL`` in the app).
    ///   - newURL: the namespaced store (``storeURL`` in the app).
    ///   - fileManager: injectable for tests.
    @discardableResult
    static func migrateLegacyStoreIfNeeded(
        from legacyURL: URL,
        to newURL: URL,
        fileManager: FileManager = .default
    ) -> LegacyMigrationOutcome {
        let destinationDir = newURL.deletingLastPathComponent()
        let markerURL = destinationDir.appending(path: legacyMigrationMarkerName)
        guard !fileManager.fileExists(atPath: markerURL.path) else { return .skippedAlreadyDecided }

        sweepStagingDirectories(in: destinationDir, fileManager: fileManager)

        let outcome = decideAndMigrate(from: legacyURL, to: newURL, fileManager: fileManager)
        if outcome != .failed {
            do {
                try fileManager.createDirectory(at: destinationDir, withIntermediateDirectories: true)
                try Data().write(to: markerURL)
            } catch {
                Log.persistence.error("Could not write the legacy migration marker: \(error.localizedDescription)")
            }
        }
        return outcome
    }

    private static func decideAndMigrate(
        from legacyURL: URL,
        to newURL: URL,
        fileManager: FileManager
    ) -> LegacyMigrationOutcome {
        guard !fileManager.fileExists(atPath: newURL.path) else { return .skippedNewStoreExists }
        guard fileManager.fileExists(atPath: legacyURL.path) else { return .skippedNoLegacyStore }

        // A damaged result may be a copy torn by a concurrent writer: retry once.
        for attempt in 1...2 {
            let outcome = stageAndMigrate(from: legacyURL, to: newURL, fileManager: fileManager)
            guard outcome == .skippedUnreadableCasablancaStore, attempt == 1 else { return outcome }
            Log.persistence.info("Legacy store copy failed verification; retrying once.")
        }
        return .skippedUnreadableCasablancaStore
    }

    /// One attempt: copy to a fresh staging folder, check, export, move into place.
    private static func stageAndMigrate(
        from legacyURL: URL,
        to newURL: URL,
        fileManager: FileManager
    ) -> LegacyMigrationOutcome {
        let stagingDir = newURL.deletingLastPathComponent()
            .appending(path: "\(legacyMigrationStagingPrefix)\(UUID().uuidString)")
        defer {
            if fileManager.fileExists(atPath: stagingDir.path) {
                try? fileManager.removeItem(at: stagingDir)
            }
        }

        do {
            try fileManager.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            // Main file + WAL only: a copied -shm describes the live process's WAL
            // index, not our copy, so SQLite rebuilds it from the WAL instead.
            let stagedLegacy = stagingDir.appending(path: "legacy.store")
            try fileManager.copyItem(at: legacyURL, to: stagedLegacy)
            let legacyWAL = legacyURL.deletingLastPathComponent().appending(path: "\(legacyURL.lastPathComponent)-wal")
            if fileManager.fileExists(atPath: legacyWAL.path) {
                try fileManager.copyItem(at: legacyWAL, to: stagingDir.appending(path: "legacy.store-wal"))
            }

            let exported = stagingDir.appending(path: newURL.lastPathComponent)
            switch checkAndExport(stagedLegacy, to: exported) {
            case .foreign:
                Log.persistence.info(
                    "Legacy store at \(legacyURL.lastPathComponent, privacy: .public) is not Casablanca's; leaving it alone."
                )
                return .skippedForeignStore
            case .damaged:
                Log.persistence.error(
                    "Legacy Casablanca store at \(legacyURL.lastPathComponent, privacy: .public) failed verification; leaving it alone."
                )
                return .skippedUnreadableCasablancaStore
            case .exported:
                break
            }

            // Durable before it becomes the live store (and before the marker).
            let handle = try FileHandle(forWritingTo: exported)
            try handle.synchronize()
            try handle.close()

            // Orphaned sidecars at the destination would be paired with the new
            // main file; only the single self-contained file may end up there.
            for url in storeFileURLs(for: newURL) where fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            try fileManager.moveItem(at: exported, to: newURL)
        } catch {
            Log.persistence.error(
                "Legacy store migration failed; will retry next launch: \(error.localizedDescription)"
            )
            return .failed
        }

        Log.persistence.info("Migrated legacy store to \(newURL.lastPathComponent, privacy: .public).")
        return .migrated
    }

    /// Removes staging folders left behind by an interrupted earlier migration.
    private static func sweepStagingDirectories(in directory: URL, fileManager: FileManager) {
        guard let entries = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
        for name in entries where name.hasPrefix(legacyMigrationStagingPrefix) {
            do {
                try fileManager.removeItem(at: directory.appending(path: name))
            } catch {
                Log.persistence.error(
                    "Could not remove leftover migration folder \(name, privacy: .public): \(error.localizedDescription)"
                )
            }
        }
    }

    /// Opens the *staged copy* at `stagedURL` (never the legacy path), decides
    /// ownership from its schema and, for a Casablanca store, verifies it and
    /// writes it as one self-contained database to `outputURL` (`VACUUM INTO`
    /// folds the WAL in).
    private static func checkAndExport(_ stagedURL: URL, to outputURL: URL) -> StagedStoreCheck {
        var db: OpaquePointer?
        defer { sqlite3_close_v2(db) }
        // Read-write on our private copy so SQLite can rebuild the WAL index.
        guard sqlite3_open_v2(stagedURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let db else { return .foreign }

        // Ownership first. A schema we cannot read (not SQLite, encrypted, corrupt
        // header) is nothing we could migrate: treat it as foreign.
        guard let tables = singleColumn(db, "SELECT name FROM sqlite_master WHERE type = 'table';"),
              Set(["ZMEETING", "ZTODOITEM", "Z_PRIMARYKEY"]).isSubset(of: tables) else { return .foreign }
        guard let entities = singleColumn(db, "SELECT Z_NAME FROM Z_PRIMARYKEY;") else { return .damaged }
        guard Set(["Meeting", "TodoItem"]).isSubset(of: entities) else { return .foreign }

        // Ours: it must be intact before we copy it.
        guard singleColumn(db, "PRAGMA quick_check;") == ["ok"] else { return .damaged }

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_exec(db, "PRAGMA synchronous = FULL;", nil, nil, nil) == SQLITE_OK,
              sqlite3_prepare_v2(db, "VACUUM INTO ?;", -1, &statement, nil) == SQLITE_OK,
              sqlite3_bind_text(statement, 1, outputURL.path, -1, transient) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE else { return .damaged }
        return .exported
    }

    /// Runs `sql` and returns the first column of every row as text, or `nil` on
    /// any SQLite error.
    private static func singleColumn(_ db: OpaquePointer, _ sql: String) -> [String]? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        var values: [String] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                values.append(sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "")
            case SQLITE_DONE:
                return values
            default:
                return nil
            }
        }
    }

    /// Suffix marking a pre-open backup set member: `<file>.<stamp>.pre-open-backup`.
    static let preOpenBackupSuffix = "pre-open-backup"

    /// Pre-migration backup net (the data-loss GUARANTEE).
    ///
    /// Before the migrating `ModelContainer` opens, **copies** the store file and
    /// its `-wal`/`-shm` sidecars aside to a single timestamped backup set, e.g.
    /// `Casablanca.store.<UTCyyyyMMdd-HHmmss>.pre-open-backup`. Because the copy
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
        // `Casablanca.store.<stamp>.pre-open-backup`; the sidecars are
        // `Casablanca.store-wal.<stamp>...` / `Casablanca.store-shm.<stamp>...`. All
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
