import Foundation

/// Reads and writes the machine-readable `action-queue.json` shared with the
/// Claude skills. Pure functions; injectable `userDefaults`/`fileManager` for
/// testability. Mirrors the style of `ObsidianTodoSyncService`.
///
/// Write discipline: every mutation is read-modify-write by `id` (load fresh,
/// find the item, re-encode the FULL decoded item, atomic save) — never a
/// partial patch and never holding a stale copy.
///
/// Concurrency: Claude skills rewrite the same file from other processes and do
/// not take any lock (so `NSFileCoordinator` would not help). Instead each
/// mutation re-reads the raw bytes just before its atomic write and, if another
/// writer replaced the file since it was read, starts over on that newer
/// version (up to `maxWriteAttempts`). This closes the read-modify-write
/// window down to the instant between that check and the rename.
enum ActionQueueStore {
    enum StoreError: LocalizedError, Equatable {
        case concurrentModification

        var errorDescription: String? {
            "The action queue kept changing while saving. Try again."
        }
    }

    static let maxWriteAttempts = 3

    /// Legacy queue location, used only when neither `actionQueuePath` nor an
    /// Obsidian vault is configured. Since 2026-07-08 that folder holds only a
    /// redirect stub — the memory system moved into the vault (`Memory/`).
    static let legacyDefaultPath = "~/.claude/projects/-Users-youri-broekhuizen/memory/action-queue.json"

    /// Queue location relative to the Obsidian vault root.
    static let vaultRelativePath = "Memory/action-queue.json"

    /// Resolves the queue file URL, in priority order:
    /// 1. an explicit `AppPreferenceKey.actionQueuePath` (leading `~` expanded),
    /// 2. `<obsidianVaultPath>/Memory/action-queue.json` when a vault is set,
    /// 3. the legacy `~/.claude/…/memory/action-queue.json`.
    static func fileURL(userDefaults: UserDefaults = .standard) -> URL? {
        let configured = (userDefaults.string(forKey: AppPreferenceKey.actionQueuePath) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty {
            return URL(fileURLWithPath: (configured as NSString).expandingTildeInPath)
        }
        if let vaultRoot = ObsidianMeetingFiles.vaultRoot(userDefaults: userDefaults) {
            return vaultRoot.appendingPathComponent(vaultRelativePath)
        }
        return URL(fileURLWithPath: (legacyDefaultPath as NSString).expandingTildeInPath)
    }

    /// Loads the document, returning an empty doc if the file is absent.
    static func load(
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) throws -> ActionQueueDocument {
        guard let url = fileURL(userDefaults: userDefaults) else {
            return ActionQueueDocument()
        }
        return try decode(readRaw(at: url, fileManager: fileManager))
    }

    /// Optimistic read-modify-write of the whole document. `change` returns
    /// false when there is nothing to write. If the file's bytes changed between
    /// the read and the write (another process wrote it), the change is re-applied
    /// to the fresh document. Internal so tests can simulate that writer.
    static func mutate(
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        _ change: (inout ActionQueueDocument) throws -> Bool
    ) throws {
        guard let url = fileURL(userDefaults: userDefaults) else {
            throw CocoaError(.fileNoSuchFile)
        }
        for _ in 0..<maxWriteAttempts {
            let snapshot = try readRaw(at: url, fileManager: fileManager)
            var doc = try decode(snapshot)
            guard try change(&doc) else { return }
            let data = try encoder().encode(doc)

            guard try readRaw(at: url, fileManager: fileManager) == snapshot else {
                Log.actionQueue.info("Action queue changed on disk during a write; retrying on the newer version")
                continue
            }
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            return
        }
        throw StoreError.concurrentModification
    }

    // MARK: - Mutations

    /// Read-modify-write: load, find item by id, apply status (+ optional
    /// note/body), set `decidedAt`, bump `updatedAt`, atomic save.
    static func setStatus(
        _ status: ActionItemStatus,
        for id: String,
        decisionNote: String? = nil,
        editedBody: String? = nil,
        revisionPrompt: String? = nil,
        executedAt: Date? = nil,
        executionResult: String? = nil,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) throws {
        try mutate(userDefaults: userDefaults, fileManager: fileManager) { doc in
            guard let index = doc.items.firstIndex(where: { $0.id == id }) else { return false }

            var item = doc.items[index]
            item.status = status
            item.decidedAt = Date()
            if let decisionNote {
                item.decisionNote = decisionNote
            }
            if let editedBody {
                item.body = editedBody
            }
            if let revisionPrompt {
                item.revisionPrompt = revisionPrompt
            }
            if let executedAt {
                item.executedAt = executedAt
            }
            if let executionResult {
                item.executionResult = executionResult
            }
            doc.items[index] = item
            doc.updatedAt = Date()
            return true
        }
    }

    /// Updates a draft body without changing status (inline edit before approve).
    static func updateBody(
        _ body: String,
        for id: String,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) throws {
        try mutate(userDefaults: userDefaults, fileManager: fileManager) { doc in
            guard let index = doc.items.firstIndex(where: { $0.id == id }) else { return false }

            var item = doc.items[index]
            item.body = body
            doc.items[index] = item
            doc.updatedAt = Date()
            return true
        }
    }

    // MARK: - Convenience wrappers

    static func approve(
        id: String,
        editedBody: String? = nil,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) throws {
        try setStatus(.approved, for: id, editedBody: editedBody, userDefaults: userDefaults, fileManager: fileManager)
    }

    static func decline(
        id: String,
        note: String? = nil,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) throws {
        try setStatus(.declined, for: id, decisionNote: note, userDefaults: userDefaults, fileManager: fileManager)
    }

    /// Send the draft back to the copilot with a steer on how to change it.
    static func requestRevision(
        id: String,
        prompt: String,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) throws {
        try setStatus(.revisionRequested, for: id, revisionPrompt: prompt, userDefaults: userDefaults, fileManager: fileManager)
    }

    /// Postpone (named `postpone`, not `defer` — reserved word).
    static func postpone(
        id: String,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) throws {
        try setStatus(.deferred, for: id, userDefaults: userDefaults, fileManager: fileManager)
    }

    static func complete(
        id: String,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) throws {
        try setStatus(.completed, for: id, userDefaults: userDefaults, fileManager: fileManager)
    }

    static func reopen(
        id: String,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) throws {
        try setStatus(.pending, for: id, userDefaults: userDefaults, fileManager: fileManager)
    }

    /// Mark a local-only item (e.g. a `todo` bucket item with no remote execute)
    /// as completed directly in the app. Unlike `complete(_:)`, this also records
    /// `executedAt` and an `executionResult` so the item reads as actioned, not
    /// merely status-flipped.
    static func completeLocally(
        id: String,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) throws {
        try setStatus(
            .completed,
            for: id,
            executedAt: Date(),
            executionResult: "marked complete in Casablanca",
            userDefaults: userDefaults,
            fileManager: fileManager
        )
    }

    // MARK: - Private

    /// The file's raw bytes, or nil when it does not exist.
    private static func readRaw(at url: URL, fileManager: FileManager) throws -> Data? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    private static func decode(_ data: Data?) throws -> ActionQueueDocument {
        guard let data, !data.isEmpty else { return ActionQueueDocument() }
        return try decoder().decode(ActionQueueDocument.self, from: data)
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        ActionQueueDateFormat.configureDecoder(decoder)
        return decoder
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ActionQueueDateFormat.configureEncoder(encoder)
        return encoder
    }
}
