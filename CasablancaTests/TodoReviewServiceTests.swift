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

    // MARK: - Task 10: accept / edit / reject, decision log, regeneration

    /// A decision log in a temporary directory; never Application Support.
    private func makeLog() -> TodoDecisionLog {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TodoReviewServiceTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return TodoDecisionLog(fileURL: directory.appendingPathComponent("todo-decisions.jsonl"))
    }

    private func entries(in log: TodoDecisionLog) throws -> [TodoDecisionEntry] {
        guard FileManager.default.fileExists(atPath: log.fileURL.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try String(contentsOf: log.fileURL, encoding: .utf8)
            .split(separator: "\n")
            .map { try decoder.decode(TodoDecisionEntry.self, from: Data($0.utf8)) }
    }

    /// Obsidian storage pointed at a scratch vault.
    private func makeVaultDefaults(_ vault: URL) -> UserDefaults {
        let defaults = makeScratchDefaults(vaultRoot: vault, label: "todo-review-accept")
        AppPreferences.setPrepTodoStorage(.obsidian, in: defaults)
        assertScratchVault(defaults)
        return defaults
    }

    /// Local storage, with a scratch vault configured anyway so the test can
    /// prove nothing is written there.
    private func makeLocalDefaults(_ vault: URL) -> UserDefaults {
        let defaults = makeScratchDefaults(vaultRoot: vault, label: "todo-review-local")
        AppPreferences.setPrepTodoStorage(.local, in: defaults)
        assertScratchVault(defaults)
        return defaults
    }

    private func vaultContents(_ vault: URL) -> [String] {
        (FileManager.default.enumerator(atPath: vault.path)?.allObjects as? [String]) ?? []
    }

    private func proposed(
        _ items: [ExtractedActionItem], in meeting: Meeting, context: ModelContext
    ) throws -> [TodoItem] {
        try TodoReviewService.replaceProposedTodos(for: meeting, with: items, in: context)
        try context.save()
        return try todos(of: meeting, in: context).filter { $0.status == .proposed }
    }

    private let offerItem = ExtractedActionItem(
        task: "Stuur offerte", owner: "Youri", due: "2026-11-06", dueIsExplicit: true, confidence: 0.9,
        quote: "ik stuur de offerte", timestamp: "12:34", verified: .supported, verificationReason: "Youri zegt het."
    )

    func testAcceptWritesOneLineToTheMeetingFile() throws {
        let context = try makeContext()
        let vault = makeScratchVault("todo-accept")
        let defaults = makeVaultDefaults(vault)
        let log = makeLog()
        let meeting = Meeting(title: "Offerte", date: SummaryFixtures.meetingDate)
        context.insert(meeting)
        meeting.actionItems = [offerItem]
        let todo = try XCTUnwrap(try proposed([offerItem], in: meeting, context: context).first)

        try TodoReviewService.accept(todo, in: context, userDefaults: defaults, log: log)
        try TodoReviewService.accept(todo, in: context, userDefaults: defaults, log: log)

        let files = try XCTUnwrap(ObsidianMeetingFiles.meetingFiles(for: meeting, userDefaults: defaults))
        TestVaultGuard.assertTemporary(files.canonicalTodoWriteURL, "meeting todo file")
        let markdown = try String(contentsOf: files.canonicalTodoWriteURL, encoding: .utf8)
        let id = todo.id.uuidString
        XCTAssertTrue(markdown.contains("- [ ] Stuur offerte — Youri 📅 2026-11-06 [12:34] <!-- casablanca-todo: \(id) -->"), markdown)
        XCTAssertEqual(markdown.components(separatedBy: id).count - 1, 1, "accepting twice writes one line")
        XCTAssertEqual(todo.sourceFilePath, files.canonicalTodoWriteURL.path)
        XCTAssertEqual(todo.status, .accepted)

        let logged = try entries(in: log)
        XCTAssertEqual(logged.map(\.action), [.accept])
        XCTAssertEqual(logged.first?.todoID, todo.id)
        XCTAssertEqual(logged.first?.meetingID, meeting.id)
        XCTAssertEqual(logged.first?.item, .init(task: "Stuur offerte", owner: "Youri", due: "2026-11-06",
                                                 timestamp: "12:34", quote: "ik stuur de offerte"))
        XCTAssertEqual(logged.first?.verification, "supported")
        XCTAssertEqual(logged.first?.verificationReason, "Youri zegt het.", "the reason comes from the meeting's action items")
        XCTAssertNil(logged.first?.edit)
    }

    func testAcceptInLocalModeTouchesNoFiles() throws {
        let context = try makeContext()
        let vault = makeScratchVault("todo-accept-local")
        let defaults = makeLocalDefaults(vault)
        let log = makeLog()
        let meeting = Meeting(title: "Offerte", date: SummaryFixtures.meetingDate)
        context.insert(meeting)
        let todo = try XCTUnwrap(try proposed([offerItem], in: meeting, context: context).first)

        try TodoReviewService.accept(todo, in: context, userDefaults: defaults, log: log)

        XCTAssertEqual(todo.status, .accepted)
        XCTAssertNil(todo.sourceFilePath)
        XCTAssertEqual(vaultContents(vault), [], "local storage writes nothing to the vault")
        XCTAssertEqual(try entries(in: log).map(\.action), [.accept])
    }

    func testRejectStaysInSwiftDataOnly() throws {
        let context = try makeContext()
        let vault = makeScratchVault("todo-reject")
        let defaults = makeVaultDefaults(vault)
        let log = makeLog()
        let meeting = Meeting(title: "Offerte", date: SummaryFixtures.meetingDate)
        context.insert(meeting)
        let todo = try XCTUnwrap(try proposed([offerItem], in: meeting, context: context).first)

        try TodoReviewService.reject(todo, in: context, log: log)
        try ObsidianTodoSyncService.refreshTodos(for: meeting, in: context, userDefaults: defaults)

        XCTAssertEqual(todo.status, .rejected)
        XCTAssertNil(todo.sourceFilePath)
        XCTAssertEqual(try todos(of: meeting, in: context).count, 1, "the rejected row is kept")
        let files = try XCTUnwrap(ObsidianMeetingFiles.meetingFiles(for: meeting, userDefaults: defaults))
        let markdown = (try? String(contentsOf: files.canonicalTodoWriteURL, encoding: .utf8)) ?? ""
        XCTAssertFalse(markdown.contains(todo.id.uuidString))
        XCTAssertFalse(markdown.contains("Stuur offerte"))
        let logged = try entries(in: log)
        XCTAssertEqual(logged.map(\.action), [.reject])
        XCTAssertEqual(logged.first?.item.task, "Stuur offerte")
    }

    func testEditLogsOnlyChangedFields() throws {
        let context = try makeContext()
        let log = makeLog()
        let meeting = Meeting(title: "Offerte", date: SummaryFixtures.meetingDate)
        context.insert(meeting)
        let todo = try XCTUnwrap(try proposed([offerItem], in: meeting, context: context).first)
        let newDue = try XCTUnwrap(TodoReviewService.dueDate(fromISO: "2026-11-07"))

        try TodoReviewService.edit(todo, task: " Stuur de offerte ", owner: "Youri", dueDate: newDue, in: context, log: log)

        XCTAssertEqual(todo.text, "Stuur de offerte")
        XCTAssertEqual(todo.owner, "Youri")
        XCTAssertEqual(todo.dueDate, newDue)
        XCTAssertEqual(todo.status, .proposed, "editing does not accept")
        let logged = try entries(in: log)
        XCTAssertEqual(logged.map(\.action), [.edit])
        XCTAssertEqual(logged.first?.edit, [
            "task": .init(from: "Stuur offerte", to: "Stuur de offerte"),
            "due": .init(from: "2026-11-06", to: "2026-11-07"),
        ])
        XCTAssertEqual(logged.first?.item.task, "Stuur de offerte")

        // Clearing the owner is a change; an unchanged edit logs nothing.
        try TodoReviewService.edit(todo, task: "Stuur de offerte", owner: nil, dueDate: newDue, in: context, log: log)
        try TodoReviewService.edit(todo, task: "Stuur de offerte", owner: nil, dueDate: newDue, in: context, log: log)
        XCTAssertNil(todo.owner)
        XCTAssertEqual(try entries(in: log).last?.edit, ["owner": .init(from: "Youri", to: nil)])
        XCTAssertEqual(try entries(in: log).count, 2)

        // Only proposed to-dos are edited.
        let accepted = TodoItem(text: "Bel Kim", meeting: meeting)
        context.insert(accepted)
        try TodoReviewService.edit(accepted, task: "Bel Tim", owner: nil, dueDate: nil, in: context, log: log)
        XCTAssertEqual(accepted.text, "Bel Kim")
        XCTAssertEqual(try entries(in: log).count, 2)
    }

    func testAcceptAllVerifiedSkipsUnsupportedAndUnverified() throws {
        let context = try makeContext()
        let vault = makeScratchVault("todo-accept-all")
        let defaults = makeLocalDefaults(vault)
        let log = makeLog()
        let meeting = Meeting(title: "Offerte", date: SummaryFixtures.meetingDate)
        context.insert(meeting)
        _ = try proposed([
            item("Stuur offerte naar Kim", verified: .supported),
            item("Plan de productdemo", verified: .unsupported),
            item("Bel de leverancier", verified: .unverified),
        ], in: meeting, context: context)

        let count = try TodoReviewService.acceptAllVerified(in: meeting, in: context, userDefaults: defaults,
                                                             fileManager: .default, log: log)

        XCTAssertEqual(count, 1)
        let rows = try todos(of: meeting, in: context)
        XCTAssertEqual(rows.map(\.text), ["Bel de leverancier", "Plan de productdemo", "Stuur offerte naar Kim"])
        XCTAssertEqual(rows.map(\.status), [.proposed, .proposed, .accepted])
        XCTAssertEqual(try entries(in: log).map(\.action), [.accept])
    }

    /// Ruling (Task 10): the brief's "Plan de demo" vs "Plan demo" pair cannot
    /// merge under `FuzzyText.isFuzzyEqual` (9 < 12 characters, similarity
    /// 0.75), so the fuzzy pair is "Plan de productdemo met Kim" / "Plan
    /// productdemo met Kim" (similarity 0.889) and "Plan demo" is an exact repeat.
    func testRegenerationKeepsAcceptedAndRejectedAndDropsFuzzyMatches() throws {
        let context = try makeContext()
        let meeting = Meeting(title: "Offerte", date: SummaryFixtures.meetingDate)
        context.insert(meeting)
        let accepted = TodoItem(text: "Stuur offerte naar Kim", meeting: meeting)
        let rejectedFuzzy = TodoItem(text: "Plan de productdemo met Kim", meeting: meeting)
        rejectedFuzzy.status = .rejected
        let rejectedExact = TodoItem(text: "Plan demo", meeting: meeting)
        rejectedExact.status = .rejected
        let pending = TodoItem(text: "Oud voorstel", meeting: meeting)
        pending.status = .proposed
        [accepted, rejectedFuzzy, rejectedExact, pending].forEach(context.insert)
        try context.save()

        try TodoReviewService.replaceProposedTodos(
            for: meeting,
            with: [item("Stuur de offerte naar Kim."), item("Plan productdemo met Kim"), item("Plan demo"), item("Bel leverancier")],
            in: context
        )
        try context.save()

        let rows = try todos(of: meeting, in: context)
        XCTAssertEqual(rows.filter { $0.status == .proposed }.map(\.text), ["Bel leverancier"])
        XCTAssertEqual(rows.count, 4, "the pending proposal is gone; kept rows are untouched")
        XCTAssertEqual(accepted.text, "Stuur offerte naar Kim")
        XCTAssertEqual(accepted.status, .accepted)
        XCTAssertEqual(rejectedFuzzy.text, "Plan de productdemo met Kim")
        XCTAssertEqual(rejectedFuzzy.status, .rejected)
        XCTAssertEqual(rejectedExact.status, .rejected)
    }

    /// The short-text guard: "Plan demo" (9 characters) only matches exactly,
    /// so "Plan de demo" is proposed again rather than silently dropped.
    func testRegenerationShortTextStaysProposed() throws {
        let context = try makeContext()
        let meeting = Meeting(title: "Offerte", date: SummaryFixtures.meetingDate)
        context.insert(meeting)
        let rejected = TodoItem(text: "Plan demo", meeting: meeting)
        rejected.status = .rejected
        context.insert(rejected)
        try context.save()

        try TodoReviewService.replaceProposedTodos(for: meeting, with: [item("Plan de demo")], in: context)
        try context.save()

        let rows = try todos(of: meeting, in: context)
        XCTAssertEqual(rows.filter { $0.status == .proposed }.map(\.text), ["Plan de demo"])
        XCTAssertEqual(rejected.status, .rejected)
    }

    /// Carry-in from Task 7: every proposed to-do keeps its item's verdict.
    func testProposedTodosCarryTheVerificationVerdict() throws {
        let context = try makeContext()
        let meeting = Meeting(title: "Offerte", date: SummaryFixtures.meetingDate)
        context.insert(meeting)

        let rows = try proposed([
            item("Stuur offerte naar Kim", verified: .supported),
            item("Plan de productdemo", verified: .unsupported),
            item("Bel de leverancier", verified: .unverified),
        ], in: meeting, context: context)

        XCTAssertEqual(rows.map(\.text), ["Bel de leverancier", "Plan de productdemo", "Stuur offerte naar Kim"])
        XCTAssertEqual(rows.map(\.verification), [.unverified, .unsupported, .supported])
        XCTAssertEqual(rows.map(\.verificationRaw), ["unverified", "unsupported", "supported"])
    }

    func testAutoAcceptVerifiedWhenSettingOn() async throws {
        let markdown = """
        # Samenvatting
        Korte meeting.

        ## Besluiten

        ## Actiepunten
        - **Youri** — Stuur offerte naar Kim
        - **Youri** — Plan de demo

        ## Risico's en blockers

        ## Opvolging
        """
        let json = #"""
        {"topics":["Offerte"],"decisions":[],"action_items":[{"task":"Stuur offerte naar Kim","owner":"Youri","due":null,"confidence":0.9,"quote":"ik stuur de offerte naar Kim","timestamp":"00:10"},{"task":"Plan de demo","owner":"Youri","due":null,"confidence":0.9,"quote":"prima","timestamp":"00:20"}],"open_questions":[],"facts":[]}
        """#
        let verdict = #"[{"id": "a1", "supported": true, "reason": "Youri zegt het."}]"#

        for autoAccept in [true, false] {
            let stub = StubLLMProvider(outcomes: [.success(SummaryFixtures.withFacts(markdown, json: json)), .success(verdict)])
            let defaults = makeScratchDefaults(label: "todo-review-auto")
            defaults.set("Youri", forKey: AppPreferenceKey.userNameAliases)
            defaults.set(false, forKey: AppPreferenceKey.includeUnassignedActionItems)
            defaults.set(false, forKey: AppPreferenceKey.summaryThinkingEnabled)
            defaults.set(autoAccept, forKey: AppPreferenceKey.autoAcceptVerifiedTodos)
            AppPreferences.setPrepTodoStorage(.local, in: defaults)
            let log = makeLog()
            let service = SummarizationService(
                providerFactory: { stub },
                userDefaults: defaults,
                attendeeProvider: StaticAttendeeProvider(attendees: []),
                prepLoader: { _, _ in nil },
                calendar: SummaryFixtures.amsterdamCalendar,
                todoDecisionLog: log
            )
            let context = try makeContext()
            let meeting = Meeting(title: "Offerte", date: SummaryFixtures.meetingDate, status: .completed)
            meeting.transcript = "[00:10] Youri: Ik stuur de offerte naar Kim vrijdag.\n[00:20] Kim: Prima, dank je."
            context.insert(meeting)

            service.summarizeInBackground(meeting: meeting, modelContext: context)
            let deadline = Date().addingTimeInterval(5)
            while service.isSummarizing, Date() < deadline {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTAssertFalse(service.isSummarizing)
            XCTAssertNil(service.errorMessage)

            let rows = try todos(of: meeting, in: context)
            XCTAssertEqual(rows.map(\.text), ["Plan de demo", "Stuur offerte naar Kim"])
            XCTAssertEqual(rows.map(\.verification), [.unverified, .supported])
            XCTAssertEqual(rows.map(\.status), autoAccept ? [.proposed, .accepted] : [.proposed, .proposed])
            let logged = try entries(in: log)
            XCTAssertEqual(logged.map(\.action), autoAccept ? [.autoAccept] : [])
            if autoAccept {
                XCTAssertEqual(logged.first?.verificationReason, "Youri zegt het.")
                XCTAssertTrue(try String(contentsOf: log.fileURL, encoding: .utf8).contains(#""action":"auto_accept""#))
            }
        }
    }

    // MARK: - Fix round 1

    func testEditSanitizesOwnersThatCannotRoundTrip() throws {
        let context = try makeContext()
        let log = makeLog()
        let meeting = Meeting(title: "Offerte", date: SummaryFixtures.meetingDate)
        context.insert(meeting)
        let todo = try XCTUnwrap(try proposed([offerItem], in: meeting, context: context).first)
        let longOwner = String(repeating: "x", count: 70)

        try TodoReviewService.edit(todo, task: "Stuur offerte", owner: " Kim — Youri ", dueDate: todo.dueDate, in: context, log: log)
        XCTAssertEqual(todo.owner, "Kim - Youri")
        try TodoReviewService.edit(todo, task: "Stuur offerte", owner: longOwner, dueDate: todo.dueDate, in: context, log: log)
        XCTAssertEqual(todo.owner, String(repeating: "x", count: 60))
        XCTAssertEqual(ObsidianTodoMarkdown.suffix(for: todo), " — \(todo.owner!) 📅 2026-11-06 [12:34]",
                       "a sanitized owner is written and parses back")
        XCTAssertEqual(try entries(in: log).last?.edit?["owner"]?.to, String(repeating: "x", count: 60))
    }

    /// The bullet's stripped action is compared with the stripped action of the
    /// to-do's text too, so a row holding a stripped action or a full bullet
    /// (with or without a suffix) matches.
    func testMatcherComparesStrippedActionsOnBothSides() {
        let bullet = "**Youri** — Plan de demo [00:20]"
        let stripped = TodoItem(text: "Plan de demo")
        XCTAssertTrue(ActionItemTodoMatcher.matchingTodo(for: bullet, in: [stripped]) === stripped)
        let otherSuffix = TodoItem(text: "**Youri** — Plan de demo (2026-11-06) [00:20]")
        XCTAssertTrue(ActionItemTodoMatcher.matchingTodo(for: bullet, in: [otherSuffix]) === otherSuffix)
        let unrelated = TodoItem(text: "**Youri** — Plan de demo met Kim [00:20]")
        XCTAssertNil(ActionItemTodoMatcher.matchingTodo(for: bullet, in: [unrelated]))
    }

    // MARK: - Fix round 2: the matcher respects owners

    func testMatcherDoesNotMatchAnotherOwnersBullet() {
        let kimRow = TodoItem(text: "**Kim** — Plan de demo [00:20]")
        XCTAssertNil(ActionItemTodoMatcher.matchingTodo(for: "**Youri** — Plan de demo [05:00]", in: [kimRow]))
        XCTAssertTrue(ActionItemTodoMatcher.matchingTodo(for: "**Kim** — Plan de demo [05:00]", in: [kimRow]) === kimRow,
                      "the same owner with another timestamp still matches")
        XCTAssertTrue(ActionItemTodoMatcher.matchingTodo(for: "**kím** — Plan de demo", in: [kimRow]) === kimRow,
                      "owners are compared folded")

        // A row without an owner prefix uses its owner field, else matches any owner.
        let kimByField = TodoItem(text: "Plan de demo")
        kimByField.owner = "Kim"
        XCTAssertNil(ActionItemTodoMatcher.matchingTodo(for: "**Youri** — Plan de demo [00:20]", in: [kimByField]))
        XCTAssertTrue(ActionItemTodoMatcher.matchingTodo(for: "**Kim** — Plan de demo [00:20]", in: [kimByField]) === kimByField)
        let unowned = TodoItem(text: "Plan de demo")
        XCTAssertTrue(ActionItemTodoMatcher.matchingTodo(for: "**Youri** — Plan de demo [00:20]", in: [unowned]) === unowned)
    }

    func testReplaceSanitizesTheExtractedOwner() throws {
        let context = try makeContext()
        let meeting = Meeting(title: "Offerte", date: SummaryFixtures.meetingDate)
        context.insert(meeting)
        let rows = try proposed([item("Stuur offerte", owner: "Kim — Youri", timestamp: "12:34")], in: meeting, context: context)
        XCTAssertEqual(rows.first?.owner, "Kim - Youri")
    }

    // MARK: - Fix round 3: owner tokens, row owners, wildcard bullets and rows

    /// The bullet and the proposed row come from one item, even when the row's
    /// owner was sanitized (`—` → `-`, `_`, cut to 60 characters).
    func testSanitizedOwnerRowStillMatchesItsBullet() throws {
        let owners = [
            "Kim — Youri",
            "Kim_Youri",
            "Annemarie van den Berg-Hoogendoorn en Kim Owen-Jones en Youri Broekhuizen",
            String(repeating: "Kim ", count: 20).trimmingCharacters(in: .whitespaces),
        ]
        for owner in owners {
            let context = try makeContext()
            let meeting = Meeting(title: "Offerte", date: SummaryFixtures.meetingDate)
            context.insert(meeting)
            let extracted = item("Plan de demo", owner: owner, timestamp: "00:20")
            let row = try XCTUnwrap(try proposed([extracted], in: meeting, context: context).first)
            let bullet = ActionItemRendering.bullet(for: extracted)
            XCTAssertTrue(ActionItemTodoMatcher.matchingTodo(for: bullet, in: [row]) === row, "\(owner) → \(bullet)")
        }

        // Token containment: an owner edited to the full name still matches.
        let edited = TodoItem(text: "Plan de demo")
        edited.owner = "Youri Broekhuizen"
        XCTAssertTrue(ActionItemTodoMatcher.matchingTodo(for: "**Youri** — Plan de demo", in: [edited]) === edited)
        XCTAssertNil(ActionItemTodoMatcher.matchingTodo(for: "**Kim** — Plan de demo", in: [edited]))
    }

    /// A bold prefix inside the row's own text is not its owner when the row
    /// has an owner field.
    func testBoldTextRowUsesItsOwnerField() {
        let row = TodoItem(text: "**Urgent:** bel Kim")
        row.owner = "Kim"
        row.sourceTimestamp = "12:34"
        XCTAssertTrue(ActionItemTodoMatcher.matchingTodo(for: "**Kim** — **Urgent:** bel Kim [12:34]", in: [row]) === row)
        XCTAssertNil(ActionItemTodoMatcher.matchingTodo(for: "**Urgent** — bel Kim [12:34]", in: [row]))
    }

    /// A row that stores only the action (its bold text is emphasis, not an
    /// owner) is a wildcard under the timestamp guard; only a row storing the
    /// whole bullet owns its prefix.
    func testActionOnlyRowDoesNotOwnItsBoldPrefix() {
        // Unassigned item `**Urgent:** bel Kim` [12:34] → row text = task, owner nil.
        let row = TodoItem(text: "**Urgent:** bel Kim")
        row.sourceTimestamp = "12:34"
        XCTAssertTrue(ActionItemTodoMatcher.matchingTodo(for: "**?** — **Urgent:** bel Kim [12:34]", in: [row]) === row)
        XCTAssertNil(ActionItemTodoMatcher.matchingTodo(for: "**?** — **Urgent:** bel Kim [05:00]", in: [row]),
                     "still under the timestamp guard")
        // A pre-Task-10 whole-bullet row keeps using its prefix.
        let legacy = TodoItem(text: "**Kim** — Plan de demo")
        XCTAssertTrue(ActionItemTodoMatcher.matchingTodo(for: "**Kim** — Plan de demo [00:20]", in: [legacy]) === legacy)
        XCTAssertNil(ActionItemTodoMatcher.matchingTodo(for: "**Youri** — Plan de demo [00:20]", in: [legacy]))
        XCTAssertNil(ActionItemTodoMatcher.matchingTodo(for: "**?** — Plan de demo [00:20]", in: [legacy]))
    }

    /// Among rows of the same text, an exact owner beats a contained one,
    /// whatever their age; then an equal timestamp wins.
    func testExactOwnerAndTimestampWinTheSelection() {
        let jansen = TodoItem(text: "Plan de demo", createdAt: Date(timeIntervalSince1970: 100))
        jansen.owner = "Kim Jansen"
        let kim = TodoItem(text: "Plan de demo", createdAt: Date(timeIntervalSince1970: 200))
        kim.owner = "Kim"
        XCTAssertTrue(ActionItemTodoMatcher.matchingTodo(for: "**Kim** — Plan de demo [00:20]", in: [jansen, kim]) === kim)
        XCTAssertTrue(ActionItemTodoMatcher.matchingTodo(for: "**Kim Jansen** — Plan de demo", in: [kim, jansen]) === jansen)

        let early = TodoItem(text: "Plan de demo", createdAt: Date(timeIntervalSince1970: 100))
        early.owner = "Kim"
        early.sourceTimestamp = "00:20"
        let late = TodoItem(text: "Plan de demo", createdAt: Date(timeIntervalSince1970: 200))
        late.owner = "Kim"
        late.sourceTimestamp = "05:00"
        XCTAssertTrue(ActionItemTodoMatcher.matchingTodo(for: "**Kim** — Plan de demo [05:00]", in: [early, late]) === late)
        XCTAssertTrue(ActionItemTodoMatcher.matchingTodo(for: "**Kim** — Plan de demo [00:20]", in: [early, late]) === early)
    }

    /// Status ranks before the timestamp: an accepted row beats a proposed row
    /// at the bullet's timestamp, so a checked-off item never turns back into
    /// "In review" when a regenerated proposal carries the timestamp.
    func testAcceptedRowBeatsAProposedRowAtTheBulletTimestamp() {
        let accepted = TodoItem(text: "Plan de demo", createdAt: Date(timeIntervalSince1970: 200))
        accepted.owner = "Kim"
        let proposedAtTimestamp = TodoItem(text: "Plan de demo", createdAt: Date(timeIntervalSince1970: 100))
        proposedAtTimestamp.owner = "Kim"
        proposedAtTimestamp.sourceTimestamp = "00:20"
        proposedAtTimestamp.status = .proposed
        let bullet = "**Kim** — Plan de demo [00:20]"
        XCTAssertTrue(ActionItemTodoMatcher.matchingTodo(for: bullet, in: [proposedAtTimestamp, accepted]) === accepted)
        XCTAssertTrue(ActionItemTodoMatcher.matchingTodo(for: bullet, in: [accepted, proposedAtTimestamp]) === accepted)
    }

    /// An owner field that means "nobody" is the unassigned owner.
    func testUnassignedOwnerFieldMatchesTheUnassignedBullet() {
        for owner in ["?", "-", "unknown", "Onbekend", "***"] {
            let row = TodoItem(text: "Plan de demo")
            row.owner = owner
            XCTAssertTrue(ActionItemTodoMatcher.matchingTodo(for: "**?** — Plan de demo [00:20]", in: [row]) === row, owner)
            XCTAssertNil(ActionItemTodoMatcher.matchingTodo(for: "**Kim** — Plan de demo [00:20]", in: [row]), owner)
        }
    }

    /// Timestamps compare as seconds: `0:20` is `00:20`.
    func testTimestampsCompareAsSeconds() {
        let row = TodoItem(text: "Plan de demo")
        row.sourceTimestamp = "0:20"
        XCTAssertTrue(ActionItemTodoMatcher.matchingTodo(for: "**Kim** — Plan de demo [00:20]", in: [row]) === row)
        XCTAssertNil(ActionItemTodoMatcher.matchingTodo(for: "**Kim** — Plan de demo [00:21]", in: [row]))
    }

    /// No prefix is a wildcard; `**?**` is the unassigned owner.
    func testBulletWithoutOwnerPrefixIsAWildcard() {
        let kimRow = TodoItem(text: "**Kim** — Plan de demo [00:20]")
        let fieldRow = TodoItem(text: "Plan de demo")
        fieldRow.owner = "Kim"
        XCTAssertTrue(ActionItemTodoMatcher.matchingTodo(for: "Plan de demo", in: [kimRow]) === kimRow)
        XCTAssertTrue(ActionItemTodoMatcher.matchingTodo(for: "Plan de demo", in: [fieldRow]) === fieldRow)
        XCTAssertNil(ActionItemTodoMatcher.matchingTodo(for: "**?** — Plan de demo", in: [kimRow]))
        XCTAssertNil(ActionItemTodoMatcher.matchingTodo(for: "**?** — Plan de demo", in: [fieldRow]))
        let unassignedRow = TodoItem(text: "**?** — Plan de demo [00:20]")
        XCTAssertTrue(ActionItemTodoMatcher.matchingTodo(for: "**?** — Plan de demo", in: [unassignedRow]) === unassignedRow)
    }

    /// An owner-less row with a timestamp only matches a timestamped bullet at
    /// the same timestamp: Kim's item elsewhere never flips the user's row.
    func testOwnerlessRowNeedsTheSameTimestamp() {
        let mine = TodoItem(text: "Plan de demo")
        mine.sourceTimestamp = "00:20"
        XCTAssertNil(ActionItemTodoMatcher.matchingTodo(for: "**Kim** — Plan de demo [05:00]", in: [mine]))
        XCTAssertTrue(ActionItemTodoMatcher.matchingTodo(for: "**Kim** — Plan de demo [00:20]", in: [mine]) === mine)
        XCTAssertTrue(ActionItemTodoMatcher.matchingTodo(for: "**Youri** — Plan de demo (2026-11-06) [00:20]", in: [mine]) === mine)
        XCTAssertTrue(ActionItemTodoMatcher.matchingTodo(for: "**Youri** — Plan de demo", in: [mine]) === mine,
                      "a bullet without a timestamp still matches")
    }
}
