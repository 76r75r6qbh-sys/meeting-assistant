// CasablancaTests/TodoReviewPresentationTests.swift
import Foundation
import SwiftData
import XCTest
@testable import Casablanca

/// The pure parts of the to-do review UI: badges, the caption line, the
/// "Accept all verified" count, the summary tab's per-bullet state, the
/// Todos filters and the open-to-do count. Proposed and rejected to-dos are
/// never open to-dos.
@MainActor
final class TodoReviewPresentationTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let schema = Schema([Meeting.self, TodoItem.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        return ModelContext(container)
    }

    private func item(
        _ task: String, owner: String? = nil, timestamp: String? = nil, quote: String? = nil,
        verified: VerificationState = .unverified, reason: String? = nil
    ) -> ExtractedActionItem {
        ExtractedActionItem(task: task, owner: owner, due: nil, dueIsExplicit: false, confidence: 0.8,
                            quote: quote, timestamp: timestamp, verified: verified, verificationReason: reason)
    }

    private func proposed(_ text: String, verification: VerificationState? = nil, meeting: Meeting? = nil) -> TodoItem {
        let todo = TodoItem(text: text, meeting: meeting)
        todo.status = .proposed
        todo.verification = verification
        return todo
    }

    // MARK: - Brief tests

    func testBadgeForEachVerificationState() {
        XCTAssertEqual(TodoReviewPresentation(todo: proposed("A", verification: .supported)).badge, .verified)
        XCTAssertEqual(TodoReviewPresentation(todo: proposed("A", verification: .unsupported)).badge, .unsupported(reason: nil))
        XCTAssertEqual(TodoReviewPresentation(todo: proposed("A", verification: .unverified)).badge, .unverified)
        XCTAssertEqual(TodoReviewPresentation(todo: proposed("A", verification: nil)).badge, .unverified)

        let verified = TodoReviewPresentation.Badge.verified
        XCTAssertEqual(verified.symbolName, "checkmark.seal.fill")
        XCTAssertEqual(verified.help, "Supported by the transcript")
        let unsupported = TodoReviewPresentation.Badge.unsupported(reason: nil)
        XCTAssertEqual(unsupported.symbolName, "exclamationmark.triangle.fill")
        let unverified = TodoReviewPresentation.Badge.unverified
        XCTAssertEqual(unverified.symbolName, "questionmark.circle")
        XCTAssertEqual(unverified.help, "Not checked")
    }

    func testUnsupportedBadgeCarriesReason() throws {
        let context = try makeContext()
        let meeting = Meeting(title: "Offerte", date: SummaryFixtures.meetingDate)
        context.insert(meeting)
        meeting.actionItems = [
            item("Stuur offerte", owner: "Youri", verified: .unsupported, reason: "Quote not found in the transcript"),
            item("Bel Kim", owner: "Youri", timestamp: "05:00", quote: "ik bel Kim", verified: .unsupported, reason: "Speaker differs"),
        ]
        let byText = proposed("Stuur offerte", verification: .unsupported, meeting: meeting)
        // Edited text: found by quote + timestamp, like the decision log.
        let edited = proposed("Bel Kim morgen", verification: .unsupported, meeting: meeting)
        edited.quote = "ik bel Kim"
        edited.sourceTimestamp = "05:00"
        let unknown = proposed("Iets anders", verification: .unsupported, meeting: meeting)
        context.insert(byText)
        context.insert(edited)
        context.insert(unknown)

        // The caller decodes the meeting's items once and passes them in.
        let items = meeting.actionItems
        let badge = TodoReviewPresentation(todo: byText, actionItems: items).badge
        XCTAssertEqual(badge, .unsupported(reason: "Quote not found in the transcript"))
        XCTAssertEqual(badge.help, "Quote not found in the transcript")
        XCTAssertEqual(TodoReviewPresentation(todo: edited, actionItems: items).badge, .unsupported(reason: "Speaker differs"))
        let fallback = TodoReviewPresentation(todo: unknown, actionItems: items).badge
        XCTAssertEqual(fallback, .unsupported(reason: nil))
        XCTAssertFalse(fallback.help.isEmpty, "Without a reason the badge still explains itself")
        // Nothing is decoded from the meeting behind the caller's back.
        XCTAssertEqual(TodoReviewPresentation(todo: byText).badge, .unsupported(reason: nil))
    }

    func testCaptionPartsOmitMissingFields() {
        let full = proposed("Stuur offerte")
        full.owner = "Kim"
        full.dueDate = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 6))
        full.sourceTimestamp = "12:34"
        let presentation = TodoReviewPresentation(todo: full)
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM"
        let expectedDue = formatter.string(from: full.dueDate!)
        XCTAssertEqual(presentation.ownerText, "Kim")
        XCTAssertEqual(presentation.dueText, expectedDue)
        XCTAssertEqual(presentation.timestampLabel, "[12:34]")
        XCTAssertEqual(presentation.ownerAndDueText, "Kim · \(expectedDue)")

        let ownerOnly = proposed("Stuur offerte")
        ownerOnly.owner = "Kim"
        XCTAssertEqual(TodoReviewPresentation(todo: ownerOnly).ownerAndDueText, "Kim")
        XCTAssertNil(TodoReviewPresentation(todo: ownerOnly).dueText)
        XCTAssertNil(TodoReviewPresentation(todo: ownerOnly).timestampLabel)

        let timestampOnly = proposed("Stuur offerte")
        timestampOnly.sourceTimestamp = "1:02:03"
        let timestampPresentation = TodoReviewPresentation(todo: timestampOnly)
        XCTAssertNil(timestampPresentation.ownerText)
        XCTAssertNil(timestampPresentation.ownerAndDueText)
        XCTAssertEqual(timestampPresentation.timestampLabel, "[1:02:03]")
        XCTAssertTrue(timestampPresentation.hasCaption)

        let blank = proposed("Stuur offerte")
        blank.owner = "  "
        blank.sourceTimestamp = ""
        XCTAssertNil(TodoReviewPresentation(todo: blank).ownerText)
        XCTAssertNil(TodoReviewPresentation(todo: blank).timestampLabel)
        XCTAssertFalse(TodoReviewPresentation(todo: blank).hasCaption)
    }

    func testAcceptAllVerifiedCountIgnoresAcceptedAndUnsupported() {
        let verified1 = proposed("A", verification: .supported)
        let verified2 = proposed("B", verification: .supported)
        let unsupported = proposed("C", verification: .unsupported)
        let unverified = proposed("D", verification: .unverified)
        let unchecked = proposed("E")
        let accepted = TodoItem(text: "F")
        accepted.verification = .supported
        let rejected = proposed("G", verification: .supported)
        rejected.status = .rejected

        let all = [verified1, verified2, unsupported, unverified, unchecked, accepted, rejected]
        XCTAssertEqual(TodoReviewPresentation.acceptAllVerifiedCount(all), 2)
        XCTAssertEqual(TodoReviewPresentation.acceptAllVerifiedCount([accepted, unsupported]), 0)
    }

    func testLegacyTodoHasUnverifiedBadgeAndNoQuote() {
        let legacy = TodoItem(text: "Bel leverancier")
        let presentation = TodoReviewPresentation(todo: legacy)
        XCTAssertEqual(legacy.status, .accepted)
        XCTAssertEqual(presentation.badge, .unverified)
        XCTAssertNil(presentation.quoteText)
        XCTAssertNil(presentation.ownerText)
        XCTAssertNil(presentation.dueText)
        XCTAssertNil(presentation.timestampLabel)
        XCTAssertFalse(presentation.hasCaption)

        let quoted = proposed("Stuur offerte")
        quoted.quote = "  ik stuur de offerte vrijdag  "
        XCTAssertEqual(TodoReviewPresentation(todo: quoted).quoteText, "\u{201C}ik stuur de offerte vrijdag\u{201D}")
    }

    // MARK: - Summary tab

    /// Proposed matches show the review state (no completion toggle); accepted
    /// matches and legacy meetings keep the toggle; in a meeting with
    /// structured items, a bullet with no to-do of the user's is read-only
    /// with its owner and verification badge.
    func testSummaryBulletStateForEachKindOfBullet() {
        let kim = item("Plan de demo", owner: "Kim", timestamp: "00:20", verified: .unsupported, reason: "No quote")
        let mine = item("Stuur offerte", owner: "Youri", verified: .supported)
        let unassigned = item("Bel leverancier")
        let items = [kim, mine, unassigned]
        let kimBullet = ActionItemRendering.bullet(for: kim)
        let mineBullet = ActionItemRendering.bullet(for: mine)
        let unassignedBullet = ActionItemRendering.bullet(for: unassigned)

        let proposedRow = proposed("Stuur offerte", verification: .supported)
        proposedRow.owner = "Youri"
        if case .review(let todo) = TodoReviewPresentation.summaryBulletState(for: mineBullet, todos: [proposedRow], items: items) {
            XCTAssertTrue(todo === proposedRow)
        } else {
            XCTFail("A proposed match shows the review state")
        }

        let acceptedRow = TodoItem(text: "Stuur offerte")
        acceptedRow.owner = "Youri"
        if case .toggle(let todo) = TodoReviewPresentation.summaryBulletState(for: mineBullet, todos: [proposedRow, acceptedRow], items: items) {
            XCTAssertTrue(todo === acceptedRow)
        } else {
            XCTFail("An accepted match keeps the toggle")
        }

        if case .readOnly(let owner, let action, let badge) = TodoReviewPresentation.summaryBulletState(for: kimBullet, todos: [acceptedRow], items: items) {
            XCTAssertEqual(owner, "Kim")
            XCTAssertEqual(action, "Plan de demo")
            XCTAssertEqual(badge, .unsupported(reason: "No quote"))
        } else {
            XCTFail("Another person's item is read-only")
        }

        if case .readOnly(let owner, _, let badge) = TodoReviewPresentation.summaryBulletState(for: unassignedBullet, todos: [], items: items) {
            XCTAssertNil(owner)
            XCTAssertEqual(badge, .unverified)
        } else {
            XCTFail("An unassigned item without a to-do is read-only")
        }

        let rejectedRow = proposed("Stuur offerte", verification: .supported)
        rejectedRow.status = .rejected
        if case .readOnly = TodoReviewPresentation.summaryBulletState(for: mineBullet, todos: [rejectedRow], items: items) {
        } else {
            XCTFail("A rejected to-do cannot be checked off from the summary")
        }

        // Legacy meeting (no structured items): today's toggle list, also
        // for a bullet without a to-do yet.
        if case .toggle(let todo) = TodoReviewPresentation.summaryBulletState(for: kimBullet, todos: [], items: []) {
            XCTAssertNil(todo)
        } else {
            XCTFail("Legacy meetings keep the toggle")
        }
    }

    /// "· X of N done" counts only bullets with a toggle; in-review and
    /// read-only bullets can't be done, and with none the suffix is hidden.
    func testDoneSummaryCountsOnlyToggleableBullets() {
        let doneMine = TodoItem(text: "Stuur offerte", isCompleted: true)
        let openMine = TodoItem(text: "Bel Kim")
        let inReview = proposed("Plan de demo")
        let kim = TodoReviewPresentation.SummaryBulletState.readOnly(owner: "Kim", action: "Deel planning", badge: .verified)

        // Structured meeting: the user finished all of their own items.
        XCTAssertEqual(
            TodoReviewPresentation.doneSummary([.toggle(doneMine), kim, .review(inReview), kim]),
            "\u{00B7} 1 of 1 done"
        )
        XCTAssertEqual(
            TodoReviewPresentation.doneSummary([.toggle(doneMine), .toggle(openMine), .review(inReview)]),
            "\u{00B7} 1 of 2 done"
        )
        // Legacy meeting: bullets without a to-do yet still count.
        XCTAssertEqual(TodoReviewPresentation.doneSummary([.toggle(nil), .toggle(doneMine)]), "\u{00B7} 1 of 2 done")
        XCTAssertNil(TodoReviewPresentation.doneSummary([kim, .review(inReview)]))
        XCTAssertNil(TodoReviewPresentation.doneSummary([]))
    }

    // MARK: - Export coalescing

    func testExportCoalescerRunsOnceAfterABurst() async {
        let sleeper = Gate()
        let coalescer = MeetingExportCoalescer(delay: .seconds(60), sleep: { _ in await sleeper.wait() })
        let meeting = UUID()
        let other = UUID()
        var runs: [UUID] = []
        for _ in 0..<5 {
            coalescer.schedule(meeting) { runs.append(meeting) }
        }
        coalescer.schedule(other) { runs.append(other) }
        await settle { sleeper.waiting == 6 }
        XCTAssertEqual(sleeper.waiting, 6)

        sleeper.open()
        await coalescer.waitUntilIdle()
        XCTAssertEqual(runs.filter { $0 == meeting }.count, 1, "A burst for one meeting exports once")
        XCTAssertEqual(runs.filter { $0 == other }.count, 1, "Another meeting is not coalesced away")
    }

    func testExportCoalescerNeverOverlapsRunsForOneMeeting() async {
        let sleeper = Gate()
        let export = Gate()
        let coalescer = MeetingExportCoalescer(delay: .seconds(60), sleep: { _ in await sleeper.wait() })
        let meeting = UUID()
        var started = 0
        var running = 0
        var maxRunning = 0
        var finished = 0
        let operation: @MainActor () async -> Void = {
            started += 1
            running += 1
            maxRunning = max(maxRunning, running)
            await export.wait()
            running -= 1
            finished += 1
        }

        coalescer.schedule(meeting, operation)
        await settle { sleeper.waiting == 1 }
        sleeper.releaseWaiting()
        await settle { started == 1 }
        XCTAssertEqual(started, 1, "Run 1 is held open")

        coalescer.schedule(meeting, operation)
        await settle { sleeper.waiting == 1 }
        sleeper.releaseWaiting()
        await settle(rounds: 200) { started > 1 }
        XCTAssertEqual(started, 1, "Run 2 waits for run 1")

        export.open()
        await coalescer.waitUntilIdle()
        XCTAssertEqual(finished, 2)
        XCTAssertEqual(maxRunning, 1, "Exports of one meeting never overlap")
    }

    /// Quit: `willTerminate` is delivered synchronously on the main thread,
    /// so this test is synchronous too. Pending exports start at once and
    /// finish before flushAndWait returns, without waiting out the delay.
    func testFlushRunsPendingExportsImmediately() {
        let coalescer = MeetingExportCoalescer(delay: .seconds(60))
        let meeting = UUID()
        var runs = 0
        coalescer.schedule(meeting) {
            await Task.yield()
            runs += 1
        }

        coalescer.flushAndWait(timeout: 10)
        XCTAssertEqual(runs, 1, "The accept before quit is exported")
        XCTAssertTrue(coalescer.isIdle)

        // The cancelled delay ends without a second run.
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(runs, 1)
    }

    /// Yields to the main actor until `condition` holds (or `rounds` yields).
    private func settle(rounds: Int = 1000, _ condition: () -> Bool) async {
        for _ in 0..<rounds where !condition() {
            await Task.yield()
        }
    }

    // MARK: - Todos view and counts

    func testTodoFiltersShowAcceptedOnlyAndReviewShowsProposed() {
        let open = TodoItem(text: "Open")
        let done = TodoItem(text: "Done", isCompleted: true)
        let pending = proposed("Pending")
        let rejected = proposed("Rejected")
        rejected.status = .rejected
        let all = [open, done, pending, rejected]

        XCTAssertEqual(TodosView.TodoFilter.open.todos(from: all).map(\.text), ["Open"])
        XCTAssertEqual(TodosView.TodoFilter.done.todos(from: all).map(\.text), ["Done"])
        XCTAssertEqual(TodosView.TodoFilter.all.todos(from: all).map(\.text), ["Open", "Done"])
        XCTAssertEqual(TodosView.TodoFilter.review.todos(from: all).map(\.text), ["Pending"])

        XCTAssertEqual(TodosView.TodoFilter.review.rawValue, "Review")
        XCTAssertEqual(TodosView.TodoFilter.review.label(reviewCount: 0), "Review")
        XCTAssertEqual(TodosView.TodoFilter.review.label(reviewCount: 3), "Review (3)")
        XCTAssertEqual(TodosView.TodoFilter.open.label(reviewCount: 3), "Open")
    }

    /// The sidebar's To-Dos badge fetches with this predicate.
    func testOpenTodoCountExcludesProposedAndRejected() throws {
        let context = try makeContext()
        let open = TodoItem(text: "Open")
        let done = TodoItem(text: "Done", isCompleted: true)
        let pending = proposed("Pending")
        let rejected = proposed("Rejected")
        rejected.status = .rejected
        for todo in [open, done, pending, rejected] { context.insert(todo) }
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<TodoItem>(predicate: TodoCounting.openTodoPredicate))
        XCTAssertEqual(fetched.map(\.text), ["Open"])
    }

    /// The Todos view's query never fetches rejected to-dos.
    func testTodosQueryLeavesOutRejected() throws {
        let context = try makeContext()
        let open = TodoItem(text: "Open")
        let pending = proposed("Pending")
        let rejected = proposed("Rejected")
        rejected.status = .rejected
        for todo in [open, pending, rejected] { context.insert(todo) }
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<TodoItem>(
            predicate: TodoCounting.notRejectedPredicate, sortBy: [SortDescriptor(\.text)]))
        XCTAssertEqual(fetched.map(\.text), ["Open", "Pending"])
    }
}

/// A test-controlled gate: `wait()` suspends until released, or returns at
/// once after `open()`.
@MainActor
private final class Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    var waiting: Int { waiters.count }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Releases the current waiters; later waits suspend again.
    func releaseWaiting() {
        let current = waiters
        waiters.removeAll()
        current.forEach { $0.resume() }
    }

    /// Releases everyone, now and later.
    func open() {
        isOpen = true
        releaseWaiting()
    }
}
