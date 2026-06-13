import Foundation
import SwiftData

/// Owns a *windowed* fetch of the most-recent meetings for the sidebar so the
/// list scales to thousands of meetings without hydrating every transcript into
/// memory.
///
/// Two memory wins over the old `@Query(sort: \Meeting.date, order: .reverse)`
/// that fetched ALL meetings:
///   1. **Windowing** — `fetchLimit` caps the result set (100 initially, grown
///      by `loadMore()`), so only a bounded slice of rows is materialized.
///   2. **Partial fetch** — `propertiesToFetch` lists ONLY the lightweight
///      fields the sidebar row renders (id/title/date/status). The multi-MB
///      `transcript` / `rawTranscript` / `summary` / `userNotes` columns stay
///      off the eager path; if a row ever touches one it faults in lazily, but
///      the common sidebar path never loads them.
///
/// The window is kept fresh by observing `ModelContext.didSave` — inserting,
/// editing, or deleting a meeting re-runs the fetch so the sidebar updates.
@MainActor
@Observable
final class SidebarMeetingsProvider {
    /// Number of meetings the window grows by each time more are requested, and
    /// the initial window size.
    static let pageSize = 100

    /// The current windowed, reverse-chronological set of meetings. The sidebar
    /// applies its own upcoming/recent split + time-bucket grouping on top of
    /// this, exactly as it did over the old all-meetings query.
    private(set) var meetings: [Meeting] = []

    /// True when the last fetch hit the window limit, i.e. there may be older
    /// meetings beyond the window. Drives the "Show earlier meetings" affordance.
    private(set) var hasMore = false

    /// Title filter pushed down into the SQLite fetch (not filtered in Swift).
    var searchText: String = "" {
        didSet {
            guard searchText != oldValue else { return }
            // A new search resets the window so results aren't artificially
            // truncated by a window grown for the previous query.
            fetchLimit = Self.pageSize
            refresh()
        }
    }

    private var fetchLimit = SidebarMeetingsProvider.pageSize
    private let modelContext: ModelContext
    /// Holds the `didSave` observer token in a nonisolated box so `deinit`
    /// (which runs nonisolated) can remove it without touching MainActor state.
    private let saveObserverBox = ObserverBox()

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        observeContextSaves()
        refresh()
    }

    deinit {
        saveObserverBox.removeObserver()
    }

    /// Grows the window by one page and re-fetches. Used by the sidebar's
    /// "Show earlier meetings" button.
    func loadMore() {
        fetchLimit += Self.pageSize
        refresh()
    }

    /// Re-runs the windowed fetch. Called on init, on search changes, when the
    /// window grows, and whenever the model context saves.
    func refresh() {
        var descriptor = FetchDescriptor<Meeting>(
            predicate: titlePredicate,
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = fetchLimit
        // Eagerly load ONLY the fields the sidebar row reads. Transcripts and
        // other large columns are deliberately excluded — they fault in lazily
        // if ever touched, but the sidebar never touches them.
        descriptor.propertiesToFetch = [\.id, \.title, \.date, \.status]

        do {
            let results = try modelContext.fetch(descriptor)
            meetings = results
            hasMore = results.count == fetchLimit
        } catch {
            Log.search.error("Sidebar windowed fetch failed: \(error.localizedDescription)")
            meetings = []
            hasMore = false
        }
    }

    /// Title-only predicate pushed into the DB. `localizedStandardContains`
    /// gives case- and diacritic-insensitive matching and is supported in
    /// SwiftData `#Predicate` on this target. Returns `nil` (match all) when the
    /// query is empty.
    private var titlePredicate: Predicate<Meeting>? {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        return #Predicate<Meeting> { meeting in
            meeting.title.localizedStandardContains(query)
        }
    }

    private func observeContextSaves() {
        // `queue: nil` delivers the notification synchronously on the thread
        // that posted it. All saves in this app happen on the MainActor (the
        // main thread), so the callback is main-thread isolated. This also makes
        // the refresh deterministic for tests, which save synchronously.
        let token = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
        saveObserverBox.token = token
    }
}

/// A tiny nonisolated holder for a NotificationCenter observer token, so the
/// MainActor-isolated provider can still tear the observer down from its
/// nonisolated `deinit`.
private final class ObserverBox: @unchecked Sendable {
    var token: NSObjectProtocol?

    func removeObserver() {
        if let token {
            NotificationCenter.default.removeObserver(token)
        }
    }
}
