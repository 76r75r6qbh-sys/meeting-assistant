import Foundation
import os

/// Observable owner of the action queue for the UI. Reads the configured path
/// from `UserDefaults.standard`, loads via `ActionQueueStore`, and watches the
/// queue file's PARENT DIRECTORY so atomic writes (which replace the file's
/// inode) keep triggering reloads.
@MainActor
@Observable
final class ActionQueueModel {
    private(set) var items: [ActionQueueItem] = []
    var loadError: String?
    /// Non-fatal notice surfaced when the agent's file contained items that
    /// couldn't be read (and were preserved verbatim) or unknown enum values.
    /// The queue still loads and works; this just informs the user.
    private(set) var loadWarning: String?

    @ObservationIgnored private var watchSource: DispatchSourceFileSystemObject?
    @ObservationIgnored private var watchedFD: CInt = -1
    @ObservationIgnored private var debounceTask: Task<Void, Never>?

    /// How long to coalesce filesystem events before reloading. Injectable so
    /// tests can drive the debounce with a tiny interval; defaults to 250 ms.
    @ObservationIgnored private let debounceInterval: Duration

    init(debounceInterval: Duration = .milliseconds(250)) {
        self.debounceInterval = debounceInterval
    }

    var pendingCount: Int {
        items.filter { $0.status == .pending }.count
    }

    // MARK: - Loading

    func reload() {
        do {
            let doc = try ActionQueueStore.load(userDefaults: .standard)
            items = Self.sorted(doc.items)
            loadError = nil
            loadWarning = Self.warning(for: doc)
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Build a non-fatal warning for items that couldn't be parsed or carried
    /// unknown enum values, and log it. Returns `nil` when the load was clean.
    private static func warning(for doc: ActionQueueDocument) -> String? {
        guard doc.hadLenientFallback else { return nil }
        let unparsed = doc.unparsedItemCount
        let message: String
        if unparsed > 0 {
            let noun = unparsed == 1 ? "item" : "items"
            message = "\(unparsed) \(noun) couldn't be read and were preserved."
        } else {
            message = "Some items had unrecognized values; they were preserved."
        }
        Log.actionQueue.warning("Lenient action-queue load: \(message, privacy: .public)")
        return message
    }

    /// Pending first, then by priority (high → low), then by createdAt ascending.
    private static func sorted(_ items: [ActionQueueItem]) -> [ActionQueueItem] {
        items.sorted { lhs, rhs in
            let lhsPending = lhs.status == .pending
            let rhsPending = rhs.status == .pending
            if lhsPending != rhsPending { return lhsPending }
            if lhs.priority.sortRank != rhs.priority.sortRank {
                return lhs.priority.sortRank < rhs.priority.sortRank
            }
            let lhsDate = lhs.createdAt ?? .distantPast
            let rhsDate = rhs.createdAt ?? .distantPast
            return lhsDate < rhsDate
        }
    }

    // MARK: - Mutations (store then reload)

    func approve(id: String, editedBody: String? = nil) {
        perform { try ActionQueueStore.approve(id: id, editedBody: editedBody) }
    }

    func decline(id: String, note: String? = nil) {
        perform { try ActionQueueStore.decline(id: id, note: note) }
    }

    func requestRevision(id: String, prompt: String) {
        perform { try ActionQueueStore.requestRevision(id: id, prompt: prompt) }
    }

    func postpone(id: String) {
        perform { try ActionQueueStore.postpone(id: id) }
    }

    func complete(id: String) {
        perform { try ActionQueueStore.complete(id: id) }
    }

    func reopen(id: String) {
        perform { try ActionQueueStore.reopen(id: id) }
    }

    func updateBody(_ body: String, id: String) {
        perform { try ActionQueueStore.updateBody(body, for: id) }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            reload()
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: - File watching

    /// Reload and re-point the watcher at the currently-configured path.
    func refreshWatch() {
        reload()
        startWatching()
    }

    func startWatching() {
        stopWatching()

        guard let fileURL = ActionQueueStore.fileURL(userDefaults: .standard) else { return }
        let dirURL = fileURL.deletingLastPathComponent()

        // Watch the parent directory: atomic writes swap the file's inode, so a
        // watcher on the file itself would go deaf after the first write. Skip
        // if the directory does not exist (badge stays at its last value).
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dirURL.path, isDirectory: &isDir), isDir.boolValue else {
            return
        }

        let fd = open(dirURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        watchedFD = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            self?.scheduleDebouncedReload()
        }
        source.setCancelHandler { [fd] in
            close(fd)
        }
        watchSource = source
        source.resume()
    }

    func stopWatching() {
        debounceTask?.cancel()
        debounceTask = nil
        if let watchSource {
            watchSource.cancel() // cancel handler closes the fd
            self.watchSource = nil
        }
        watchedFD = -1
    }

    /// Debounce (~250 ms) and coalesce filesystem events, then reload on the main
    /// actor. Callable from the file-watch event handler, which runs on a
    /// background DispatchQueue, so it hops to the MainActor before touching
    /// state. The `watchSource != nil` guard closes the stop-watching race: if
    /// watching was stopped (e.g. the file was deleted) while a debounce was
    /// pending, the late reload is skipped.
    nonisolated private func scheduleDebouncedReload() {
        Task { @MainActor in self.scheduleDebouncedReloadNow() }
    }

    /// MainActor-isolated body of the debounce. Separated so tests can drive it
    /// directly (the `nonisolated` wrapper just hops onto the MainActor from the
    /// background file-watch queue). Returns the scheduled task so a test can
    /// `await` its completion deterministically.
    @discardableResult
    func scheduleDebouncedReloadNow() -> Task<Void, Never> {
        debounceTask?.cancel()
        let task = Task { @MainActor in
            try? await Task.sleep(for: self.debounceInterval)
            guard !Task.isCancelled, self.watchSource != nil else { return }
            self.reload()
        }
        debounceTask = task
        return task
    }

    deinit {
        debounceTask?.cancel()
        watchSource?.cancel()
    }
}
