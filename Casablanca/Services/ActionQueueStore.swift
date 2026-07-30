import Foundation

/// Reads and writes the machine-readable `action-queue.json` shared with the
/// Claude skills. Pure functions; injectable `userDefaults`/`fileManager` for
/// testability. Mirrors the style of `ObsidianTodoSyncService`.
///
/// Write discipline: every mutation is read-modify-write by `id` (load fresh,
/// find the item, re-encode the FULL decoded item, atomic save) — never a
/// partial patch and never holding a stale copy.
enum ActionQueueStore {
    /// Default queue location when the preference is empty.
    static let defaultPath = "~/.claude/projects/-Users-youri-broekhuizen/memory/action-queue.json"

    /// Resolves the queue file URL. Uses `AppPreferenceKey.actionQueuePath`,
    /// falling back to the default; expands a leading `~`.
    static func fileURL(userDefaults: UserDefaults = .standard) -> URL? {
        let configured = userDefaults.string(forKey: AppPreferenceKey.actionQueuePath) ?? ""
        let raw = configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultPath : configured
        let expanded = (raw as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
    }

    /// Loads the document, returning an empty doc if the file is absent.
    static func load(
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) throws -> ActionQueueDocument {
        guard let url = fileURL(userDefaults: userDefaults) else {
            return ActionQueueDocument()
        }
        guard fileManager.fileExists(atPath: url.path) else {
            return ActionQueueDocument()
        }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return ActionQueueDocument() }
        return try decoder().decode(ActionQueueDocument.self, from: data)
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
        var doc = try load(userDefaults: userDefaults, fileManager: fileManager)
        guard let index = doc.items.firstIndex(where: { $0.id == id }) else { return }

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

        try save(doc, userDefaults: userDefaults, fileManager: fileManager)
    }

    /// Updates a draft body without changing status (inline edit before approve).
    static func updateBody(
        _ body: String,
        for id: String,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) throws {
        var doc = try load(userDefaults: userDefaults, fileManager: fileManager)
        guard let index = doc.items.firstIndex(where: { $0.id == id }) else { return }

        var item = doc.items[index]
        item.body = body
        doc.items[index] = item
        doc.updatedAt = Date()

        try save(doc, userDefaults: userDefaults, fileManager: fileManager)
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

    private static func save(
        _ doc: ActionQueueDocument,
        userDefaults: UserDefaults,
        fileManager: FileManager
    ) throws {
        guard let url = fileURL(userDefaults: userDefaults) else {
            throw CocoaError(.fileNoSuchFile)
        }
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder().encode(doc)
        try data.write(to: url, options: .atomic)
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
