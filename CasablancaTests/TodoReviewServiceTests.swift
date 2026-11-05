// CasablancaTests/TodoReviewServiceTests.swift
import Foundation
import SwiftData
import XCTest
@testable import Casablanca

@MainActor
final class TodoReviewServiceTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let schema = Schema([Meeting.self, TodoItem.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        return ModelContext(container)
    }

    private func item(
        _ task: String, owner: String? = nil, due: String? = nil, timestamp: String? = nil,
        quote: String? = nil, verified: VerificationState = .unverified
    ) -> ExtractedActionItem {
        ExtractedActionItem(task: task, owner: owner, due: due, dueIsExplicit: due != nil, confidence: 0.8,
                            quote: quote, timestamp: timestamp, verified: verified, verificationReason: nil)
    }

    private func todos(of meeting: Meeting, in context: ModelContext) throws -> [TodoItem] {
        let id = meeting.id
        return try context.fetch(FetchDescriptor<TodoItem>(sortBy: [SortDescriptor(\.text)]))
            .filter { $0.meeting?.id == id }
    }

    func testProposedTodosCarryStructuredFields() throws {
        let context = try makeContext()
        let meeting = Meeting(title: "Offerte", date: SummaryFixtures.meetingDate)
        context.insert(meeting)

        try TodoReviewService.replaceProposedTodos(
            for: meeting,
            with: [item("Stuur offerte", owner: "Youri", due: "2026-11-06", timestamp: "12:34",
                        quote: "ik stuur de offerte", verified: .supported)],
            in: context
        )
        try context.save()

        let todo = try XCTUnwrap(try todos(of: meeting, in: context).first)
        XCTAssertEqual(todo.text, "Stuur offerte")
        XCTAssertEqual(todo.status, .proposed)
        XCTAssertNil(todo.sourceFilePath)
        XCTAssertEqual(todo.owner, "Youri")
        XCTAssertEqual(todo.dueDate, Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 6)))
        XCTAssertEqual(todo.sourceTimestamp, "12:34")
        XCTAssertEqual(todo.quote, "ik stuur de offerte")
        XCTAssertEqual(todo.verification, .supported)
        XCTAssertFalse(todo.isCompleted)
    }

    func testReplaceDropsOnlyPendingProposed() throws {
        let context = try makeContext()
        let meeting = Meeting(title: "Offerte", date: SummaryFixtures.meetingDate)
        context.insert(meeting)
        let accepted = TodoItem(text: "Bel Kim", meeting: meeting)
        let rejected = TodoItem(text: "Plan demo", meeting: meeting)
        rejected.status = .rejected
        let oldProposal = TodoItem(text: "Oud voorstel", meeting: meeting)
        oldProposal.status = .proposed
        [accepted, rejected, oldProposal].forEach(context.insert)
        try context.save()

        try TodoReviewService.replaceProposedTodos(
            for: meeting,
            with: [item("Bel Kim"), item(" Plan demo "), item("Stuur offerte"), item("Stuur offerte")],
            in: context
        )
        try context.save()

        let rows = try todos(of: meeting, in: context)
        XCTAssertEqual(rows.map(\.text), ["Bel Kim", "Plan demo", "Stuur offerte"])
        XCTAssertEqual(rows.map(\.status), [.accepted, .rejected, .proposed])
        XCTAssertFalse(rows.contains { $0.text == "Oud voorstel" }, "the pending proposal was replaced")
    }

    func testItemsToProposeRespectsOwnershipAndUnassignedSetting() {
        let items = [
            item("Mijn taak", owner: "Youri B."),
            item("Kims taak", owner: "Kim"),
            item("Niemands taak"),
            item("Samen", owner: "Kim & Youri"),
        ]
        XCTAssertEqual(
            ProposedTodoPlanner.itemsToPropose(items, aliases: ["Youri"], includeUnassigned: false).map(\.task),
            ["Mijn taak", "Samen"]
        )
        XCTAssertEqual(
            ProposedTodoPlanner.itemsToPropose(items, aliases: ["Youri"], includeUnassigned: true).map(\.task),
            ["Mijn taak", "Niemands taak", "Samen"]
        )
        XCTAssertEqual(
            ProposedTodoPlanner.itemsToPropose(items, aliases: [], includeUnassigned: false).map(\.task),
            []
        )
    }

    /// Controller requirement: no proposed or rejected to-do reaches Apple Notes,
    /// the vault summary export or the next meeting's carry-over.
    func testOnlyAcceptedTodosReachExportsAndCarryOver() throws {
        let context = try makeContext()
        let meeting = Meeting(title: "Offerte", date: SummaryFixtures.meetingDate, status: .completed)
        meeting.summary = "# Samenvatting\nKort."
        context.insert(meeting)
        context.insert(TodoItem(text: "Geaccepteerd", meeting: meeting))
        try TodoReviewService.replaceProposedTodos(for: meeting, with: [item("Voorgesteld")], in: context)
        let rejected = TodoItem(text: "Afgewezen", meeting: meeting)
        rejected.status = .rejected
        context.insert(rejected)
        try context.save()

        let html = AppleNotesBodyRenderer.summaryHTML(for: meeting)
        XCTAssertTrue(html.contains("Geaccepteerd"))
        XCTAssertFalse(html.contains("Voorgesteld"))
        XCTAssertFalse(html.contains("Afgewezen"))

        XCTAssertEqual(MeetingSeriesResolver.openTodos(of: meeting).map(\.text), ["Geaccepteerd"])

        let vault = makeScratchVault("todo-review")
        let defaults = makeScratchDefaults(vaultRoot: vault, label: "todo-review")
        let result = try ObsidianMeetingExporter.exportCompletedMeeting(meeting, userDefaults: defaults)
        let summary = try String(contentsOf: try XCTUnwrap(result.summaryURL), encoding: .utf8)
        XCTAssertTrue(summary.contains("- [ ] Geaccepteerd"))
        XCTAssertFalse(summary.contains("Voorgesteld"))
        XCTAssertFalse(summary.contains("Afgewezen"))
    }

    /// Review fix 1: to-dos checked off in the summary tab store the full
    /// bullet (rendered or legacy); re-summarizing never proposes them again.
    func testReplaceSkipsTasksMatchingAcceptedFullBulletTodos() throws {
        let context = try makeContext()
        let meeting = Meeting(title: "Offerte", date: SummaryFixtures.meetingDate)
        context.insert(meeting)
        context.insert(TodoItem(text: "**?** — Plan de demo [00:20]", meeting: meeting))
        context.insert(TodoItem(text: "**Youri** — Stuur release notes", meeting: meeting))
        context.insert(TodoItem(text: "**Youri** — Mail Kim (2026-11-06) [1:02:03]", meeting: meeting))
        try context.save()

        try TodoReviewService.replaceProposedTodos(
            for: meeting,
            with: [item("Plan de demo"), item("Stuur de release notes."), item("Mail Kim"),
                   item("Plan Q4 budget"), item("Bel leverancier")],
            in: context
        )
        try context.save()

        let proposed = try todos(of: meeting, in: context).filter { $0.status == .proposed }.map(\.text)
        XCTAssertEqual(proposed, ["Bel leverancier", "Plan Q4 budget"])
    }

    func testReplaceKeepsDigitAndShortTextRulesOfTheFuzzyMatch() throws {
        let context = try makeContext()
        let meeting = Meeting(title: "Offerte", date: SummaryFixtures.meetingDate)
        context.insert(meeting)
        context.insert(TodoItem(text: "**Youri** — Plan Q3 budget", meeting: meeting))
        context.insert(TodoItem(text: "Bel Kim", meeting: meeting))
        try context.save()

        try TodoReviewService.replaceProposedTodos(
            for: meeting, with: [item("Plan Q4 budget"), item("Bel Tim"), item("Bel Kim.")], in: context
        )
        try context.save()

        let proposed = try todos(of: meeting, in: context).filter { $0.status == .proposed }.map(\.text)
        XCTAssertEqual(proposed, ["Bel Tim", "Plan Q4 budget"])
    }

    /// Review fix 2: an accepted match wins over a proposed one, so a checked
    /// item never shows "In review"; ties go to the oldest row.
    func testMatchingTodoPrefersAcceptedOverProposed() throws {
        let context = try makeContext()
        let meeting = Meeting(title: "Offerte", date: SummaryFixtures.meetingDate)
        context.insert(meeting)
        let proposed = TodoItem(text: "Plan de demo", createdAt: Date(timeIntervalSince1970: 100), meeting: meeting)
        proposed.status = .proposed
        let rejected = TodoItem(text: "Plan de demo", createdAt: Date(timeIntervalSince1970: 50), meeting: meeting)
        rejected.status = .rejected
        let newerAccepted = TodoItem(text: "**Youri** — Plan de demo [00:20]", isCompleted: true,
                                     createdAt: Date(timeIntervalSince1970: 300), meeting: meeting)
        let olderAccepted = TodoItem(text: "Plan de demo", createdAt: Date(timeIntervalSince1970: 200), meeting: meeting)
        let bullet = "**Youri** — Plan de demo [00:20]"

        XCTAssertTrue(ActionItemTodoMatcher.matchingTodo(for: bullet, in: [proposed, rejected, newerAccepted, olderAccepted]) === olderAccepted)
        XCTAssertTrue(ActionItemTodoMatcher.matchingTodo(for: bullet, in: [proposed, rejected, newerAccepted]) === newerAccepted)
        XCTAssertTrue(ActionItemTodoMatcher.matchingTodo(for: bullet, in: [rejected, proposed]) === proposed)
        XCTAssertNil(ActionItemTodoMatcher.matchingTodo(for: bullet, in: [rejected]))
        XCTAssertNil(ActionItemTodoMatcher.matchingTodo(for: "**Kim** — Iets anders", in: [olderAccepted]))
    }
}
