import SwiftData
import XCTest
@testable import Casablanca

@MainActor
final class GlobalSearchViewModelTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Meeting.self, TodoItem.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func makeViewModel(
        _ context: ModelContext,
        actionQueue: ActionQueueModel = ActionQueueModel(),
        debounce: Duration = .milliseconds(1)
    ) -> GlobalSearchViewModel {
        GlobalSearchViewModel(
            modelContext: context,
            actionQueueModel: actionQueue,
            debounceInterval: debounce
        )
    }

    // MARK: - Debounce

    func testDebounceCoalescesKeystrokes() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let kickoff = Meeting(title: "Wegiz kickoff", date: .now)
        let bgz = Meeting(title: "BgZ planning", date: .now)
        context.insert(kickoff)
        context.insert(bgz)
        try context.save()

        // Long-ish debounce so the rapid keystrokes definitely coalesce.
        let vm = makeViewModel(context, debounce: .milliseconds(80))

        // Simulate typing "W", "We", "Weg", "Wegiz" — only the final query runs.
        vm.search("W")
        vm.search("We")
        vm.search("Weg")
        let final = vm.search("Wegiz")
        await final?.value

        XCTAssertEqual(vm.settledQuery, "Wegiz")
        XCTAssertTrue(vm.results.contains { $0.meeting.id == kickoff.id && $0.kind == .title })
        XCTAssertFalse(vm.results.contains { $0.meeting.id == bgz.id },
                       "An intermediate query must not have produced results")
    }

    // MARK: - Tier 1 predicate matches

    func testTitleSummaryAndUserNotesPredicateMatches() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let titled = Meeting(title: "Orchestra migration", date: .now)
        let summarized = Meeting(title: "Random", date: .now)
        summarized.summary = "We discussed the Orchestra rollout on Azure."
        let noted = Meeting(title: "Other", date: .now)
        noted.userNotes = "Follow up on Orchestra licensing."
        context.insert(titled)
        context.insert(summarized)
        context.insert(noted)
        try context.save()

        let vm = makeViewModel(context)
        await vm.search("orchestra")?.value

        XCTAssertTrue(vm.results.contains { $0.meeting.id == titled.id && $0.kind == .title })
        XCTAssertTrue(vm.results.contains { $0.meeting.id == summarized.id && $0.kind == .summary })
        XCTAssertTrue(vm.results.contains { $0.meeting.id == noted.id && $0.kind == .notes })
    }

    /// Explicit guard for Phase 9a: a meeting that matches ONLY in its summary
    /// (not its title) must still surface. The sidebar window is title-only, so
    /// Tier 1's summary predicate is the only thing that finds these.
    func testSummaryOnlyMatchSurfaces() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let meeting = Meeting(title: "Weekly sync", date: .now)
        meeting.summary = "Agreed the BgZ exchange timeline with the partner."
        context.insert(meeting)
        try context.save()

        let vm = makeViewModel(context)
        await vm.search("partner")?.value

        XCTAssertTrue(
            vm.results.contains { $0.meeting.id == meeting.id && $0.kind == .summary },
            "Summary-only match must surface even though the title doesn't match"
        )
        XCTAssertNotNil(vm.results.first { $0.kind == .summary }?.snippet)
    }

    /// Verifies the optional-String `#Predicate` form (`summary?... == true`)
    /// actually runs on this OS without crashing — meetings with a nil summary
    /// must simply not match (not trap).
    func testNilSummaryDoesNotMatchOrCrash() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let withNil = Meeting(title: "No summary here", date: .now) // summary stays nil
        context.insert(withNil)
        try context.save()

        let vm = makeViewModel(context)
        await vm.search("anything")?.value

        XCTAssertFalse(vm.results.contains { $0.kind == .summary })
    }

    // MARK: - Tier 2 in-memory scan

    func testTranscriptMatchFoundViaTier2() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let meeting = Meeting(title: "Standup", date: .now)
        meeting.transcript = "the FHIR mapping for the BgZ profile needs work"
        context.insert(meeting)
        try context.save()

        let vm = makeViewModel(context)
        await vm.search("FHIR")?.value

        XCTAssertTrue(
            vm.results.contains { $0.meeting.id == meeting.id && $0.kind == .transcript },
            "Transcript match must be found by the Tier 2 in-memory scan"
        )
    }

    func testParticipantMatchFound() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let meeting = Meeting(title: "Bilateral", date: .now)
        meeting.participants = ["Kim Owen-Jones", "Arriejanne Brouwer"]
        context.insert(meeting)
        try context.save()

        let vm = makeViewModel(context)
        await vm.search("kim")?.value

        XCTAssertTrue(
            vm.results.contains { $0.kind == .person && $0.person == "Kim Owen-Jones" },
            "Participant match must be found by the Tier 2 scan (array field)"
        )
    }

    // MARK: - Dedup & ranking

    func testDedupAcrossTiers() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        // "bgz" matches the title (Tier 1) AND the transcript (Tier 2).
        let meeting = Meeting(title: "BgZ kickoff", date: .now)
        meeting.transcript = "the BgZ profile mapping"
        context.insert(meeting)
        try context.save()

        let vm = makeViewModel(context)
        await vm.search("bgz")?.value

        let titleHits = vm.results.filter { $0.meeting.id == meeting.id && $0.kind == .title }
        XCTAssertEqual(titleHits.count, 1, "Title match must not be duplicated across tiers")
        // Distinct kinds for the same meeting are allowed and expected.
        XCTAssertTrue(vm.results.contains { $0.meeting.id == meeting.id && $0.kind == .transcript })
    }

    func testRankingOrder() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let titleMatch = Meeting(title: "Acme review", date: .now)
        let summaryMatch = Meeting(title: "B", date: .now)
        summaryMatch.summary = "Discussed Acme."
        let notesMatch = Meeting(title: "C", date: .now)
        notesMatch.userNotes = "Acme follow-up."
        let transcriptMatch = Meeting(title: "D", date: .now)
        transcriptMatch.transcript = "we talked about Acme at length"
        for m in [titleMatch, summaryMatch, notesMatch, transcriptMatch] { context.insert(m) }
        try context.save()

        let vm = makeViewModel(context)
        await vm.search("acme")?.value

        // Find the first index of each kind; ranking must be title < summary < notes < transcript.
        func firstIndex(of kind: ResultKind) -> Int? {
            vm.results.firstIndex { $0.kind == kind }
        }
        let t = try XCTUnwrap(firstIndex(of: .title))
        let s = try XCTUnwrap(firstIndex(of: .summary))
        let n = try XCTUnwrap(firstIndex(of: .notes))
        let tr = try XCTUnwrap(firstIndex(of: .transcript))

        XCTAssertLessThan(t, s)
        XCTAssertLessThan(s, n)
        XCTAssertLessThan(n, tr)
    }

    // MARK: - Pending soft-deletion filtering

    /// A meeting whose id is in the pending-deletion set (the 6s undo grace window)
    /// must NOT appear in search results, matching the sidebar's `visibleMeetings`
    /// filter. Removing it from the set restores it.
    func testPendingDeletionExcludedFromResults() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let meeting = Meeting(title: "Orchestra migration", date: .now)
        meeting.transcript = "Orchestra on Azure transcript text"
        context.insert(meeting)
        try context.save()

        var pending: Set<UUID> = [meeting.id]
        let vm = GlobalSearchViewModel(
            modelContext: context,
            actionQueueModel: ActionQueueModel(),
            debounceInterval: .milliseconds(1),
            isPendingDeletion: { pending.contains($0) }
        )

        // While pending-deleted: no result in either tier (title or transcript).
        await vm.search("orchestra")?.value
        XCTAssertFalse(
            vm.results.contains { $0.meeting.id == meeting.id },
            "A pending-deleted meeting must not appear in global search"
        )

        // Undo the pending deletion: the meeting is searchable again.
        pending.remove(meeting.id)
        await vm.search("orchestra")?.value
        XCTAssertTrue(
            vm.results.contains { $0.meeting.id == meeting.id && $0.kind == .title },
            "Removing the meeting from the pending set restores it in search"
        )
    }

    // MARK: - Empty query

    func testEmptyQueryClearsResultsImmediately() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let meeting = Meeting(title: "Sync", date: .now)
        context.insert(meeting)
        try context.save()

        let vm = makeViewModel(context)
        await vm.search("sync")?.value
        XCTAssertFalse(vm.results.isEmpty)

        let task = vm.search("   ")
        XCTAssertNil(task, "Empty query clears synchronously, returns no task")
        XCTAssertTrue(vm.results.isEmpty)
        XCTAssertEqual(vm.settledQuery, "")
    }
}
