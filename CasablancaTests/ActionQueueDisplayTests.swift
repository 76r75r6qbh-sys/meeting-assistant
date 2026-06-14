import Foundation
import XCTest
@testable import Casablanca

final class ActionQueueDisplayTests: XCTestCase {
    // MARK: - Fixture helper

    private func item(
        _ id: String,
        status: ActionItemStatus = .pending,
        priority: ActionItemPriority = .medium,
        bucket: ActionBucket? = nil,
        externalRef: String? = nil,
        linkedItemIds: [String]? = nil,
        createdAt: Date? = nil
    ) -> ActionQueueItem {
        ActionQueueItem(
            id: id,
            title: id,
            priority: priority,
            status: status,
            createdAt: createdAt,
            bucket: bucket,
            externalRef: externalRef,
            linkedItemIds: linkedItemIds
        )
    }

    private func date(_ iso: String) -> Date {
        ActionQueueDateFormat.date(from: iso)!
    }

    // MARK: - Linked composites

    func testLinkedPairBecomesOneComposite() {
        // A ticket (low id) linked to a response (high id) both in ticket_draft.
        let ticket = item("AQ-01", bucket: .ticketDraft, linkedItemIds: ["AQ-02"])
        let response = item("AQ-02", bucket: .ticketDraft, linkedItemIds: ["AQ-01"])

        let sections = buildActionQueueSections([response, ticket])
        XCTAssertEqual(sections.count, 1)
        let section = sections[0]
        XCTAssertEqual(section.bucket, .ticketDraft)
        XCTAssertEqual(section.entries.count, 1)

        guard case let .composite(primary, linked) = section.entries[0] else {
            return XCTFail("Expected a composite entry")
        }
        XCTAssertEqual(primary.id, "AQ-01")              // lowest id is primary
        XCTAssertEqual(linked.map(\.id), ["AQ-02"])      // the rest, sorted by id

        // Both items represented; none shown as a separate single.
        XCTAssertEqual(section.totalCount, 2)
    }

    func testTransitiveLinksFormSingleComposite() {
        // A-B and B-C links -> one composite of {A, B, C}, primary = A.
        let a = item("AQ-A", bucket: .todo, linkedItemIds: ["AQ-B"])
        let b = item("AQ-B", bucket: .todo, linkedItemIds: ["AQ-C"])
        let c = item("AQ-C", bucket: .todo)

        let sections = buildActionQueueSections([c, b, a])
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].entries.count, 1)
        guard case let .composite(primary, linked) = sections[0].entries[0] else {
            return XCTFail("Expected a composite entry")
        }
        XCTAssertEqual(primary.id, "AQ-A")
        XCTAssertEqual(linked.map(\.id), ["AQ-B", "AQ-C"])
        XCTAssertEqual(sections[0].totalCount, 3)
    }

    func testUnresolvableLinkStaysSingle() {
        // linkedItemIds points at a missing id -> normal single, not a composite.
        let lone = item("AQ-01", bucket: .ticketDraft, linkedItemIds: ["AQ-missing"])
        let sections = buildActionQueueSections([lone])
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].entries.count, 1)
        guard case let .single(single, older) = sections[0].entries[0] else {
            return XCTFail("Expected a single entry")
        }
        XCTAssertEqual(single.id, "AQ-01")
        XCTAssertTrue(older.isEmpty)
    }

    func testCompositeSitsInPrimaryBucketEvenIfLinkedDiffers() {
        // Primary is ticket_draft, linked is todo -> section follows primary.
        let primary = item("AQ-01", bucket: .ticketDraft, linkedItemIds: ["AQ-02"])
        let linked = item("AQ-02", bucket: .todo, linkedItemIds: ["AQ-01"])
        let sections = buildActionQueueSections([primary, linked])
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].bucket, .ticketDraft)
        XCTAssertEqual(sections[0].totalCount, 2) // both count in primary's section
    }

    // MARK: - externalRef dedup

    func testThreeSharedRefFoldToOneSingleWithTwoOlder() {
        let oldest = item("AQ-01", externalRef: "forta:x", createdAt: date("2026-01-01T00:00:00Z"))
        let middle = item("AQ-02", externalRef: "forta:x", createdAt: date("2026-01-02T00:00:00Z"))
        let newest = item("AQ-03", externalRef: "forta:x", createdAt: date("2026-01-03T00:00:00Z"))
        let unrelated = item("AQ-04") // nil externalRef -> its own single

        let sections = buildActionQueueSections([oldest, newest, middle, unrelated])
        XCTAssertEqual(sections.count, 1) // all General
        let entries = sections[0].entries
        XCTAssertEqual(entries.count, 2)

        // Find the deduped single.
        let deduped = entries.compactMap { entry -> (ActionQueueItem, [String])? in
            if case let .single(item, older) = entry, !older.isEmpty { return (item, older) }
            return nil
        }
        XCTAssertEqual(deduped.count, 1)
        XCTAssertEqual(deduped[0].0.id, "AQ-03")                    // newest kept
        XCTAssertEqual(deduped[0].1, ["AQ-02", "AQ-01"])           // older, newest-first

        // The nil-ref item is its own single with no older dups.
        let lone = entries.compactMap { entry -> ActionQueueItem? in
            if case let .single(item, older) = entry, older.isEmpty { return item }
            return nil
        }
        XCTAssertEqual(lone.map(\.id), ["AQ-04"])

        // 4 input items all represented in the one section.
        XCTAssertEqual(sections[0].totalCount, 4)
    }

    func testDedupTieBreaksByGreatestId() {
        // Equal createdAt -> greatest id wins.
        let d = date("2026-01-01T00:00:00Z")
        let a = item("AQ-A", externalRef: "ref:1", createdAt: d)
        let b = item("AQ-B", externalRef: "ref:1", createdAt: d)
        let sections = buildActionQueueSections([a, b])
        guard case let .single(kept, older) = sections[0].entries[0] else {
            return XCTFail("Expected single")
        }
        XCTAssertEqual(kept.id, "AQ-B")
        XCTAssertEqual(older, ["AQ-A"])
    }

    func testLinkedItemsNeverDedupedAgainstSingles() {
        // A composite member shares externalRef with a standalone single; they
        // must NOT be deduped against each other.
        let p = item("AQ-01", externalRef: "forta:x", linkedItemIds: ["AQ-02"])
        let l = item("AQ-02", externalRef: "forta:y", linkedItemIds: ["AQ-01"])
        let standalone = item("AQ-03", externalRef: "forta:x") // same ref as composite primary

        let sections = buildActionQueueSections([p, l, standalone])
        let allEntries = sections.flatMap(\.entries)
        let compositeCount = allEntries.filter { if case .composite = $0 { return true }; return false }.count
        let singleCount = allEntries.filter { if case .single = $0 { return true }; return false }.count
        XCTAssertEqual(compositeCount, 1)
        XCTAssertEqual(singleCount, 1) // standalone remains its own single, not folded
        // standalone has no older dups (composite member not counted as a dup).
        let standaloneEntry = allEntries.first { $0.representative.id == "AQ-03" }
        guard case let .single(_, older)? = standaloneEntry else {
            return XCTFail("Expected standalone single")
        }
        XCTAssertTrue(older.isEmpty)
    }

    // MARK: - Bucket section ordering

    func testBucketSectionOrderingIsFixedWithUnknownThenGeneralLast() {
        let items = [
            item("AQ-todo", bucket: .todo),
            item("AQ-general"),                       // nil bucket = General
            item("AQ-partner", bucket: .partnerApiReply),
            item("AQ-unknown", bucket: .unknown("zzz_custom")),
            item("AQ-cal", bucket: .calendarEvent),
            item("AQ-ticket", bucket: .ticketDraft),
        ]
        let sections = buildActionQueueSections(items)
        let order = sections.map(\.bucket)
        XCTAssertEqual(order, [
            .partnerApiReply,
            .ticketDraft,
            .calendarEvent,
            .todo,
            .unknown("zzz_custom"),
            nil,                                       // General last
        ])
    }

    func testMultipleUnknownBucketsOrderByRawString() {
        let items = [
            item("AQ-b", bucket: .unknown("bbb")),
            item("AQ-a", bucket: .unknown("aaa")),
        ]
        let sections = buildActionQueueSections(items)
        XCTAssertEqual(sections.map(\.bucket), [.unknown("aaa"), .unknown("bbb")])
    }

    // MARK: - Within-section ordering

    func testPendingBeforeNonPendingThenPriority() {
        let items = [
            item("AQ-1", status: .completed, priority: .high, bucket: .todo),
            item("AQ-2", status: .pending, priority: .low, bucket: .todo),
            item("AQ-3", status: .pending, priority: .high, bucket: .todo),
        ]
        let sections = buildActionQueueSections(items)
        let ids = sections[0].entries.map(\.id)
        // Pending first (AQ-3 high, then AQ-2 low), then completed AQ-1.
        XCTAssertEqual(ids, ["AQ-3", "AQ-2", "AQ-1"])
    }

    // MARK: - Count invariants

    func testCountInvariantsOnMixedFixture() {
        let items: [ActionQueueItem] = [
            // Composite of 2 in ticket_draft, both pending.
            item("AQ-01", status: .pending, bucket: .ticketDraft, linkedItemIds: ["AQ-02"]),
            item("AQ-02", status: .pending, bucket: .ticketDraft, linkedItemIds: ["AQ-01"]),
            // Dedup set of 3 sharing externalRef in todo, mixed statuses.
            item("AQ-03", status: .pending, bucket: .todo, externalRef: "r", createdAt: date("2026-01-01T00:00:00Z")),
            item("AQ-04", status: .completed, bucket: .todo, externalRef: "r", createdAt: date("2026-01-02T00:00:00Z")),
            item("AQ-05", status: .pending, bucket: .todo, externalRef: "r", createdAt: date("2026-01-03T00:00:00Z")),
            // Standalone singles, varied buckets/statuses.
            item("AQ-06", status: .pending, bucket: .partnerApiReply),
            item("AQ-07", status: .declined),                          // General
            item("AQ-08", status: .pending, bucket: .unknown("custom")),
        ]

        let sections = buildActionQueueSections(items)

        let totalSum = sections.reduce(0) { $0 + $1.totalCount }
        let pendingSum = sections.reduce(0) { $0 + $1.pendingCount }
        XCTAssertEqual(totalSum, items.count)
        XCTAssertEqual(pendingSum, items.filter { $0.status == .pending }.count)

        // Spot check: todo section holds all 3 dedup items even though 2 are hidden.
        let todo = sections.first { $0.bucket == .todo }
        XCTAssertEqual(todo?.totalCount, 3)
        XCTAssertEqual(todo?.pendingCount, 2) // AQ-03 + AQ-05 pending, AQ-04 completed
    }
}
