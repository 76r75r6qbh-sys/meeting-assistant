import Foundation

// MARK: - Display model

/// Pure, SwiftUI-free transform of `[ActionQueueItem]` into bucket-grouped
/// sections for the list UI. Folds linked items into composites, dedups singles
/// by `externalRef`, and groups everything by `ActionBucket`.
///
/// Invariants the UI relies on (and the dock badge depends on):
/// - Every input item is represented in exactly one section.
/// - `sum(section.totalCount) == items.count`.
/// - `sum(section.pendingCount) == items.filter { $0.status == .pending }.count`.

/// One row in a section: either a standalone item (possibly hiding older
/// externalRef duplicates) or a composite of linked items.
enum ActionQueueEntry: Identifiable, Hashable {
    /// A standalone item. `olderDuplicateIds` are the ids of same-externalRef
    /// items hidden behind this (kept) one, newest-first.
    case single(item: ActionQueueItem, olderDuplicateIds: [String])
    /// A group of linked items. `primary` is the lowest-id member; `linked`
    /// excludes the primary and is sorted by id.
    case composite(primary: ActionQueueItem, linked: [ActionQueueItem])

    var id: String {
        switch self {
        case .single(let item, _): return item.id
        case .composite(let primary, _): return primary.id
        }
    }

    /// The item that represents this entry for sorting / bucketing.
    var representative: ActionQueueItem {
        switch self {
        case .single(let item, _): return item
        case .composite(let primary, _): return primary
        }
    }
}

/// A bucket-titled group of entries with pending/total counts.
struct ActionQueueSection: Identifiable, Hashable {
    /// The bucket these entries belong to; `nil` means "General".
    let bucket: ActionBucket?
    let entries: [ActionQueueEntry]
    let pendingCount: Int
    let totalCount: Int

    var id: String { ActionQueueSection.key(for: bucket) }

    /// Canonical, collision-free string key for a bucket section. Single source
    /// of truth shared by the `Identifiable` id (ForEach identity) and the
    /// collapse-state persistence key. `nil` → "general", an unknown bucket →
    /// "unknown:<raw>" (so a literal `.unknown("general")` never collides with
    /// the nil "general"), else the bucket's raw value.
    static func key(for bucket: ActionBucket?) -> String {
        switch bucket {
        case .none: return "general"
        case .unknown(let raw): return "unknown:\(raw)"
        case .some(let known): return known.rawValue
        }
    }
}

// MARK: - Builder

/// Transform raw items into ordered, bucket-grouped sections per the folding
/// rules. Pure function — no I/O, no SwiftUI.
func buildActionQueueSections(_ items: [ActionQueueItem]) -> [ActionQueueSection] {
    guard !items.isEmpty else { return [] }

    let byId = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })

    // --- Step 1: linked composites (undirected graph over linkedItemIds) ---
    let groups = linkedGroups(items, byId: byId)

    // Map: item id -> the group it belongs to (size >= 2 only). Items in a
    // single-member group are treated as normal singles.
    var compositeMemberIds = Set<String>()
    var composites: [ActionQueueEntry] = []
    for group in groups where group.count >= 2 {
        let sorted = group.sorted { $0.id < $1.id }
        let primary = sorted[0]
        let linked = Array(sorted.dropFirst())
        composites.append(.composite(primary: primary, linked: linked))
        for member in group { compositeMemberIds.insert(member.id) }
    }

    // --- Step 2: externalRef dedup over the remaining (non-composite) items ---
    let remaining = items.filter { !compositeMemberIds.contains($0.id) }
    var singles: [ActionQueueEntry] = []

    // Group remaining items by non-nil externalRef.
    var byRef: [String: [ActionQueueItem]] = [:]
    for item in remaining {
        if let ref = item.externalRef {
            byRef[ref, default: []].append(item)
        } else {
            singles.append(.single(item: item, olderDuplicateIds: []))
        }
    }

    for (_, group) in byRef {
        if group.count == 1 {
            singles.append(.single(item: group[0], olderDuplicateIds: []))
            continue
        }
        // Most-recently-created wins; tie (equal/nil createdAt) -> greatest id.
        let ordered = group.sorted { lhs, rhs in
            let l = lhs.createdAt
            let r = rhs.createdAt
            if let l, let r, l != r { return l > r }
            if (l == nil) != (r == nil) {
                // A present date beats a nil date (more recent).
                return l != nil
            }
            // Equal or both-nil dates: greatest id wins (sorts first).
            return lhs.id > rhs.id
        }
        let kept = ordered[0]
        let olderIds = ordered.dropFirst().map { $0.id } // newest-first already
        singles.append(.single(item: kept, olderDuplicateIds: olderIds))
    }

    let allEntries = composites + singles

    // --- Step 3: bucket grouping ---
    // Group entries by their representative's bucket. Use rawValue as the key for
    // unknown buckets so distinct unknown strings stay separate; nil = General.
    var sectionsByKey: [BucketKey: [ActionQueueEntry]] = [:]
    for entry in allEntries {
        let key = BucketKey(entry.representative.bucket)
        sectionsByKey[key, default: []].append(entry)
    }

    let orderedKeys = sectionsByKey.keys.sorted(by: bucketKeyOrder)

    return orderedKeys.map { key in
        let entries = sectionsByKey[key]!.sorted(by: entryOrder)
        let counts = sectionCounts(entries, byId: byId)
        return ActionQueueSection(
            bucket: key.bucket,
            entries: entries,
            pendingCount: counts.pending,
            totalCount: counts.total
        )
    }
}

// MARK: - Linked groups (union-find over linkedItemIds)

private func linkedGroups(
    _ items: [ActionQueueItem],
    byId: [String: ActionQueueItem]
) -> [[ActionQueueItem]] {
    var parent: [String: String] = [:]
    for item in items { parent[item.id] = item.id }

    func find(_ x: String) -> String {
        var root = x
        while parent[root] != root { root = parent[root]! }
        // Path compression.
        var cur = x
        while parent[cur] != root {
            let next = parent[cur]!
            parent[cur] = root
            cur = next
        }
        return root
    }

    func union(_ a: String, _ b: String) {
        let ra = find(a)
        let rb = find(b)
        if ra != rb { parent[ra] = rb }
    }

    for item in items {
        for linkedId in item.linkedItemIds ?? [] where byId[linkedId] != nil {
            union(item.id, linkedId)
        }
    }

    var clusters: [String: [ActionQueueItem]] = [:]
    for item in items {
        clusters[find(item.id), default: []].append(item)
    }
    return Array(clusters.values)
}

// MARK: - Ordering helpers

/// Wraps an optional bucket as a hashable section key. Unknown buckets stay
/// distinct by their raw string; `nil` is General.
private struct BucketKey: Hashable {
    let bucket: ActionBucket?
    init(_ bucket: ActionBucket?) { self.bucket = bucket }
}

/// Section order: known buckets by `sortOrder`, then unknown buckets by raw
/// string, then `nil` (General) last.
private func bucketKeyOrder(_ lhs: BucketKey, _ rhs: BucketKey) -> Bool {
    func rank(_ key: BucketKey) -> (Int, String) {
        guard let bucket = key.bucket else {
            return (2, "") // General last
        }
        if case .unknown(let raw) = bucket {
            return (1, raw) // unknown buckets after known, ordered by raw string
        }
        return (0, "") // known buckets first
    }
    let lr = rank(lhs)
    let rr = rank(rhs)
    if lr.0 != rr.0 { return lr.0 < rr.0 }
    if lr.0 == 0 {
        // Both known: by fixed sortOrder.
        return (lhs.bucket?.sortOrder ?? 0) < (rhs.bucket?.sortOrder ?? 0)
    }
    // Both unknown: by raw string.
    return lr.1 < rr.1
}

/// Rank for status sorting: pending first, then the fixed status order.
private func statusRank(_ status: ActionItemStatus) -> Int {
    switch status {
    case .pending: return 0
    case .revisionRequested: return 1
    case .awaitingContext: return 2
    case .followUp: return 3
    case .approved: return 4
    case .deferred: return 5
    case .completed: return 6
    case .declined: return 7
    case .unknown: return 8
    }
}

/// Within-section entry order: pending first, then status rank, then priority
/// sortRank, then createdAt ascending, then id.
private func entryOrder(_ lhs: ActionQueueEntry, _ rhs: ActionQueueEntry) -> Bool {
    let l = lhs.representative
    let r = rhs.representative

    let lPending = l.status == .pending
    let rPending = r.status == .pending
    if lPending != rPending { return lPending }

    let lStatus = statusRank(l.status)
    let rStatus = statusRank(r.status)
    if lStatus != rStatus { return lStatus < rStatus }

    if l.priority.sortRank != r.priority.sortRank {
        return l.priority.sortRank < r.priority.sortRank
    }

    let lDate = l.createdAt ?? .distantPast
    let rDate = r.createdAt ?? .distantPast
    if lDate != rDate { return lDate < rDate }

    return l.id < r.id
}

// MARK: - Counting

/// Count actual items (and pending among them) represented by a section's
/// entries, resolving olderDuplicateIds back to their items.
private func sectionCounts(
    _ entries: [ActionQueueEntry],
    byId: [String: ActionQueueItem]
) -> (total: Int, pending: Int) {
    var total = 0
    var pending = 0
    for entry in entries {
        switch entry {
        case .single(let item, let olderIds):
            total += 1
            if item.status == .pending { pending += 1 }
            for olderId in olderIds {
                guard let older = byId[olderId] else { continue }
                total += 1
                if older.status == .pending { pending += 1 }
            }
        case .composite(let primary, let linked):
            for item in [primary] + linked {
                total += 1
                if item.status == .pending { pending += 1 }
            }
        }
    }
    return (total, pending)
}
