import Foundation
import SwiftData

/// Owns the ⌘F global search so it runs *once per settled query* (250 ms
/// debounce) instead of on every keystroke / SwiftUI render. The old
/// `GlobalSearchView` called `MeetingSearchIndex.search` inside a computed
/// `groups` property, so the full O(n×m) Swift scan re-ran on every render.
///
/// ## Two-tier strategy
/// SwiftData `#Predicate` can only express the *scalar String* fields, and the
/// `participants` array (Codable, stored as an opaque blob) plus the large
/// `transcript` column can't be matched in a predicate. So the search splits in
/// two:
///
///   - **Tier 1 — SQLite `#Predicate` fetches.** `title`, `summary`,
///     `userNotes` are matched with `localizedStandardContains` *inside the
///     database*. Three small bounded fetches (`fetchLimit` ~50 each), no Swift
///     scan, no transcript hydration. This is the path that matters for scaling
///     to thousands of meetings — a summary-only match surfaces here even though
///     the meeting never appears in the sidebar's title-only window (important
///     for Phase 9a tag search, which will extend Tier 1).
///
///   - **Tier 2 — bounded in-memory scan.** `transcript` and `participants`
///     can't be predicated, so we fetch the most-recent `tier2Limit` meetings
///     (reverse-chronological) and scan them in Swift via
///     `MeetingSearchIndex.search`. The bound keeps the per-query cost flat:
///     even with 10k meetings we only ever scan the newest `tier2Limit`. This
///     runs *only on the debounced query*, never per keystroke. For the typical
///     1–2k-meeting store the bound covers the whole store; beyond that, recent
///     meetings are what users search for, and the eventual fix for exhaustive
///     transcript search is a SQLite FTS5 index (see escape-hatch note below) —
///     deliberately NOT built here.
///
/// Results from both tiers are merged and de-duplicated by
/// `(meeting.id, kind, person)` so a meeting that matches in both tiers (e.g.
/// title in Tier 1 *and* transcript in Tier 2) yields one row per kind, not
/// duplicates. Ranking is title > summary > notes > transcript > person, which
/// is the order the view renders groups in.
///
/// ### FTS escape hatch
/// If exhaustive transcript search across a very large store is ever required,
/// the move is a contentless SQLite FTS5 table mirroring transcript/summary,
/// rebuilt on save, queried with `MATCH`. That replaces Tier 2's bounded scan
/// with a real index. Not built now — the bounded scan is sufficient and has
/// zero migration/index-maintenance cost.
@MainActor
@Observable
final class GlobalSearchViewModel {
    /// Per-field cap on Tier 1 predicate fetches. Keeps each DB round-trip
    /// bounded; 50 hits per field is far more than the overlay can usefully show.
    static let tier1Limit = 50

    /// Upper bound on how many (most-recent) meetings Tier 2 scans in Swift for
    /// transcript/participant matches. See the type doc for the rationale.
    static let tier2Limit = 500

    /// The merged, de-duplicated, ranked meeting-content results for the current
    /// settled query. The view groups these (Meetings / In summaries / …) and
    /// renders snippets exactly as before.
    private(set) var results: [SearchResult] = []

    /// Action-queue items whose title/body match the current query. Kept in the
    /// VM so all search work is debounced together; the view renders the
    /// "Approvals" group from this.
    private(set) var approvalItems: [ActionQueueItem] = []

    /// The query that produced the current `results` — lets the view render
    /// highlighting/snippets against the settled query, not the in-flight text.
    private(set) var settledQuery: String = ""

    private let modelContext: ModelContext
    private let actionQueueModel: ActionQueueModel

    /// Excludes meetings hidden behind a pending soft-delete (the 6s undo grace
    /// window owned by `MeetingListViewModel`). The sidebar already filters these
    /// via `visibleMeetings(from:)`; search must match that so a meeting the user
    /// just deleted doesn't reappear in ⌘F mid-undo. Evaluated at search time so
    /// it always reflects the current pending set. Default lets it match nothing
    /// (no filtering) for callers/tests that don't wire soft-delete.
    @ObservationIgnored private let isPendingDeletion: (UUID) -> Bool

    /// Coalesces keystrokes; a newer keystroke cancels the pending search so we
    /// only ever run the search for the final, settled query. Injectable so
    /// tests can drive it with a tiny interval.
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private let debounceInterval: Duration

    init(
        modelContext: ModelContext,
        actionQueueModel: ActionQueueModel,
        debounceInterval: Duration = .milliseconds(250),
        isPendingDeletion: @escaping (UUID) -> Bool = { _ in false }
    ) {
        self.modelContext = modelContext
        self.actionQueueModel = actionQueueModel
        self.debounceInterval = debounceInterval
        self.isPendingDeletion = isPendingDeletion
    }

    // MARK: - Debounced entry point

    /// Schedule a debounced search for `query`. A newer call supersedes a
    /// pending one, so a burst of keystrokes runs the search exactly once for
    /// the final query. Empty/whitespace queries clear results immediately
    /// (no debounce — nothing to coalesce). Returns the scheduled task so tests
    /// can `await` it deterministically.
    @discardableResult
    func search(_ query: String) -> Task<Void, Never>? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        debounceTask?.cancel()

        guard !trimmed.isEmpty else {
            clear()
            return nil
        }

        let task = Task { @MainActor in
            try? await Task.sleep(for: self.debounceInterval)
            guard !Task.isCancelled else { return }
            self.runSearch(trimmed)
        }
        debounceTask = task
        return task
    }

    /// Clear results immediately (e.g. the field was emptied or the overlay
    /// dismissed). Cancels any pending debounced search.
    func clear() {
        debounceTask?.cancel()
        debounceTask = nil
        results = []
        approvalItems = []
        settledQuery = ""
    }

    // MARK: - Search (runs on the settled query only)

    private func runSearch(_ trimmed: String) {
        let tier1 = fetchScalarMatches(trimmed)
        let tier2 = scanTranscriptAndParticipants(trimmed)
        results = merge(tier1: tier1, tier2: tier2)
        approvalItems = matchingApprovals(trimmed)
        settledQuery = trimmed
        Log.search.debug("Global search '\(trimmed, privacy: .public)': \(self.results.count) meeting results, \(self.approvalItems.count) approvals")
    }

    // MARK: - Tier 1 — predicate fetches (title / summary / userNotes)

    /// Three bounded `#Predicate` fetches, each matched with
    /// `localizedStandardContains` inside SQLite. No Swift scan, no transcript
    /// hydration.
    ///
    /// macOS 14 note: the optional-String predicate form that compiles AND runs
    /// here is `field?.localizedStandardContains(q) == true` (NOT the
    /// `?? false` form, which fails to typecheck as a `Predicate` expression on
    /// this SDK). `summary` and `userNotes`-style optionals use the `== true`
    /// form; `userNotes` is non-optional so it's a plain call.
    private func fetchScalarMatches(_ query: String) -> [SearchResult] {
        var out: [SearchResult] = []

        // Titles
        out += fetch(
            #Predicate<Meeting> { $0.title.localizedStandardContains(query) }
        ).map { SearchResult(meeting: $0, kind: .title, snippet: nil, person: nil) }

        // Summaries (optional String)
        out += fetch(
            #Predicate<Meeting> { $0.summary?.localizedStandardContains(query) == true }
        ).map { meeting in
            SearchResult(
                meeting: meeting,
                kind: .summary,
                snippet: MeetingSearchIndex.snippet(from: meeting.summary ?? "", matching: query),
                person: nil
            )
        }

        // User notes (non-optional String)
        out += fetch(
            #Predicate<Meeting> { $0.userNotes.localizedStandardContains(query) }
        ).map { meeting in
            SearchResult(
                meeting: meeting,
                kind: .notes,
                snippet: MeetingSearchIndex.snippet(from: meeting.userNotes, matching: query),
                person: nil
            )
        }

        return out
    }

    private func fetch(_ predicate: Predicate<Meeting>) -> [Meeting] {
        var descriptor = FetchDescriptor<Meeting>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = Self.tier1Limit
        do {
            return try modelContext.fetch(descriptor)
                .filter { !isPendingDeletion($0.id) }
        } catch {
            Log.search.error("Global search Tier 1 fetch failed: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Tier 2 — bounded in-memory scan (transcript / participants)

    /// Fetch the most-recent `tier2Limit` meetings and scan their transcript and
    /// participants in Swift (the only fields `#Predicate` can't express). Reuses
    /// `MeetingSearchIndex.search`, then keeps only the transcript/person kinds —
    /// title/summary/notes are already covered (more cheaply) by Tier 1.
    private func scanTranscriptAndParticipants(_ query: String) -> [SearchResult] {
        var descriptor = FetchDescriptor<Meeting>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = Self.tier2Limit

        let recent: [Meeting]
        do {
            recent = try modelContext.fetch(descriptor)
                .filter { !isPendingDeletion($0.id) }
        } catch {
            Log.search.error("Global search Tier 2 fetch failed: \(error.localizedDescription)")
            return []
        }

        return MeetingSearchIndex.search(query, in: recent)
            .filter { $0.kind == .transcript || $0.kind == .person || $0.kind == .tag }
    }

    // MARK: - Merge / dedup / rank

    /// Merge the two tiers, drop duplicates keyed by `(meeting, kind, person)`,
    /// and sort by kind rank (title > summary > notes > transcript > person),
    /// then most-recent date within a kind so ordering is stable.
    private func merge(tier1: [SearchResult], tier2: [SearchResult]) -> [SearchResult] {
        var seen = Set<DedupKey>()
        var merged: [SearchResult] = []
        for result in tier1 + tier2 {
            let key = DedupKey(id: result.meeting.id, kind: result.kind, person: result.person)
            if seen.insert(key).inserted {
                merged.append(result)
            }
        }
        return merged.sorted { lhs, rhs in
            let lr = rank(lhs.kind), rr = rank(rhs.kind)
            if lr != rr { return lr < rr }
            return lhs.meeting.date > rhs.meeting.date
        }
    }

    private func rank(_ kind: ResultKind) -> Int {
        switch kind {
        case .title: return 0
        case .summary: return 1
        case .notes: return 2
        case .transcript: return 3
        case .person: return 4
        case .tag: return 5
        }
    }

    private struct DedupKey: Hashable {
        let id: UUID
        let kind: ResultKind
        let person: String?
    }

    // MARK: - Approvals

    private func matchingApprovals(_ query: String) -> [ActionQueueItem] {
        let needle = query.lowercased()
        return actionQueueModel.items.filter { item in
            item.title.lowercased().contains(needle)
            || item.body.lowercased().contains(needle)
        }
    }
}
