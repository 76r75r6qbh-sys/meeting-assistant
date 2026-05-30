import Foundation

/// Observable owner of the action queue for the UI. Reads the configured path
/// from `UserDefaults.standard`, loads via `ActionQueueStore`, and watches the
/// queue file's PARENT DIRECTORY so atomic writes (which replace the file's
/// inode) keep triggering reloads.
@MainActor
@Observable
final class ActionQueueModel {
    private(set) var items: [ActionQueueItem] = []
    var loadError: String?

    @ObservationIgnored private var watchSource: DispatchSourceFileSystemObject?
    @ObservationIgnored private var watchedFD: CInt = -1
    @ObservationIgnored private var debounceWorkItem: DispatchWorkItem?

    var pendingCount: Int {
        items.filter { $0.status == .pending }.count
    }

    // MARK: - Loading

    func reload() {
        do {
            let doc = try ActionQueueStore.load(userDefaults: .standard)
            items = Self.sorted(doc.items)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
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
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        if let watchSource {
            watchSource.cancel() // cancel handler closes the fd
            self.watchSource = nil
        }
        watchedFD = -1
    }

    /// Debounce ~250 ms and coalesce filesystem events, then reload on the main actor.
    nonisolated private func scheduleDebouncedReload() {
        Task { @MainActor in
            self.debounceWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                Task { @MainActor in self?.reload() }
            }
            self.debounceWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }

    deinit {
        debounceWorkItem?.cancel()
        watchSource?.cancel()
    }
}
