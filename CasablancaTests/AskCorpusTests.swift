import Foundation
import SwiftData
import XCTest
@testable import Casablanca

final class AskCorpusTests: XCTestCase {

    // MARK: - Helpers

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return cal
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    private func snapshot(
        id: UUID = UUID(),
        title: String = "Refinement Team Link",
        date: Date = Date(timeIntervalSince1970: 1_793_000_000),
        participants: [String] = [],
        tags: [String] = [],
        summary: String? = nil,
        actionItems: [ExtractedActionItem] = [],
        transcript: String? = nil
    ) -> AskMeetingSnapshot {
        AskMeetingSnapshot(
            id: id, title: title, date: date, participants: participants, tags: tags,
            summary: summary, actionItems: actionItems, transcript: transcript
        )
    }

    private func item(_ task: String, owner: String?, due: String? = nil, quote: String? = nil,
                      timestamp: String? = "12:34") -> ExtractedActionItem {
        ExtractedActionItem(
            task: task, owner: owner, due: due, dueIsExplicit: due != nil, confidence: 0.9,
            quote: quote, timestamp: timestamp, verified: .supported, verificationReason: nil
        )
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Meeting.self, TodoItem.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func longTranscript(lines: Int) -> String {
        (0..<lines).map { i in
            String(format: "[%02d:%02d] Spreker 1: ", i / 60, i % 60)
                + "we bespreken punt \(i) van de BgZ uitwisseling en de planning voor de volgende sprint"
        }.joined(separator: "\n")
    }

    // MARK: - Chunking

    func testSummaryIsSplitBySection() {
        let summary = """
        Korte intro over de refinement.

        ## Besluiten
        - We gaan door met BgZ-profiel v2

        ## Actiepunten
        - **Kim** — offerte opvragen
        """
        let chunks = AskCorpus.chunks(for: snapshot(summary: summary))
        let summaryChunks = chunks.filter { $0.kind == .summary }
        XCTAssertEqual(summaryChunks.count, 3)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertTrue(summaryChunks.allSatisfy { $0.timeLabel == nil })
        XCTAssertTrue(summaryChunks[0].text.contains("Korte intro"))
        XCTAssertTrue(summaryChunks[1].text.hasPrefix("## Besluiten"))
        XCTAssertTrue(summaryChunks[2].text.contains("offerte opvragen"))
    }

    func testLongSummarySectionIsSplitOnBlankLines() {
        let paragraph = String(repeating: "woord ", count: 150)   // 900 chars
        let summary = "## Notities\n\(paragraph)\n\n\(paragraph)\n\n\(paragraph)"
        let chunks = AskCorpus.chunks(for: snapshot(summary: summary))
        XCTAssertGreaterThanOrEqual(chunks.count, 3)
        XCTAssertTrue(chunks.allSatisfy { $0.text.count <= AskCorpus.summarySectionMaxChars })
    }

    func testStructuredItemsBecomeOwnChunks() {
        let items = [
            item("Offerte opvragen", owner: "Kim", due: "2026-11-07", quote: "ik vraag de offerte op"),
            item("Planning delen", owner: "Youri"),
        ]
        let chunks = AskCorpus.chunks(for: snapshot(summary: "Intro", actionItems: items))
        let itemChunks = chunks.filter { $0.kind == .actionItem }
        XCTAssertEqual(itemChunks.count, 2)
        XCTAssertTrue(itemChunks[0].text.contains("Offerte opvragen"))
        XCTAssertTrue(itemChunks[0].text.contains("Kim"))
        XCTAssertEqual(
            itemChunks[0].text,
            "Action item: Offerte opvragen — owner: Kim — due 2026-11-07 — \"ik vraag de offerte op\""
        )
        XCTAssertEqual(itemChunks[1].text, "Action item: Planning delen — owner: Youri")
        XCTAssertTrue(itemChunks.allSatisfy { $0.timeLabel == "12:34" })
    }

    func testUnassignedOwnerWording() {
        let chunks = AskCorpus.chunks(for: snapshot(summary: "Intro", actionItems: [item("Iets doen", owner: nil)]))
        let itemChunk = chunks.first { $0.kind == .actionItem }
        XCTAssertNotNil(itemChunk)
        XCTAssertTrue(itemChunk!.text.contains("owner: unassigned"))
    }

    func testTranscriptChunksCarryStartLabel() {
        let chunks = AskCorpus.chunks(for: snapshot(transcript: longTranscript(lines: 40)))
        let transcriptChunks = chunks.filter { $0.kind == .transcript }
        XCTAssertGreaterThanOrEqual(transcriptChunks.count, 2)
        XCTAssertEqual(transcriptChunks.first?.timeLabel, "00:00")
        XCTAssertTrue(transcriptChunks.allSatisfy { $0.timeLabel != nil })
    }

    func testOldMeetingWithoutStructuredItemsIsChunked() {
        let snap = snapshot(
            summary: "## Samenvatting\nWe spraken over de migratie.",
            transcript: "[00:05] we beginnen met de migratie\n[00:20] Orchestra op Azure"
        )
        let chunks = AskCorpus.chunks(for: snap)
        XCTAssertTrue(chunks.contains { $0.kind == .summary })
        XCTAssertTrue(chunks.contains { $0.kind == .transcript })
        XCTAssertFalse(chunks.contains { $0.kind == .actionItem })
        XCTAssertEqual(chunks.first { $0.kind == .transcript }?.timeLabel, "00:05")
    }

    func testEmptyMeetingHasNoChunks() {
        XCTAssertEqual(AskCorpus.chunks(for: snapshot()), [])
        XCTAssertEqual(AskCorpus.chunks(for: snapshot(summary: "  \n", transcript: "\n")), [])
        // Action items alone (no summary, no transcript) produce no chunks either.
        XCTAssertEqual(AskCorpus.chunks(for: snapshot(actionItems: [item("x", owner: nil)])), [])
    }

    func testChunkIDsAreUniqueAndStable() {
        let id = UUID()
        let snap = snapshot(
            id: id,
            summary: "Intro\n\n## Besluiten\n- a\n\n## Actiepunten\n- b",
            actionItems: [item("Een", owner: "Kim"), item("Twee", owner: nil)],
            transcript: longTranscript(lines: 40)
        )
        let first = AskCorpus.chunks(for: snap)
        let second = AskCorpus.chunks(for: snap)
        XCTAssertEqual(first, second)
        let ids = first.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertTrue(ids.contains("\(id.uuidString)#summary#0"))
        XCTAssertTrue(ids.contains("\(id.uuidString)#actionItem#1"))
        XCTAssertTrue(ids.contains("\(id.uuidString)#transcript#0"))
        XCTAssertTrue(first.allSatisfy { $0.meetingID == id })
    }

    // MARK: - Filter

    func testFilterNoneIsEmptyAndMatchesEverything() {
        XCTAssertTrue(AskFilter.none.isEmpty)
        XCTAssertTrue(AskFilter.none.matches(snapshot(), calendar: calendar))
        XCTAssertFalse(AskFilter(participant: "kim").isEmpty)
    }

    func testFilterDateRangeInclusive() {
        let filter = AskFilter(from: date(2026, 11, 3, 15, 0), to: date(2026, 11, 3))
        XCTAssertTrue(filter.matches(snapshot(date: date(2026, 11, 3, 23, 30)), calendar: calendar))
        XCTAssertTrue(filter.matches(snapshot(date: date(2026, 11, 3, 0, 0)), calendar: calendar))
        XCTAssertFalse(filter.matches(snapshot(date: date(2026, 11, 4, 0, 0)), calendar: calendar))
        XCTAssertFalse(filter.matches(snapshot(date: date(2026, 11, 2, 23, 59)), calendar: calendar))
    }

    func testFilterParticipantFoldsDiacritics() {
        let snap = snapshot(participants: ["Kim Owen-Jones", "Zoë Jansen"])
        XCTAssertTrue(AskFilter(participant: "zoe").matches(snap, calendar: calendar))
        XCTAssertTrue(AskFilter(participant: "JANSEN").matches(snap, calendar: calendar))
        XCTAssertFalse(AskFilter(participant: "marcel").matches(snap, calendar: calendar))
    }

    func testFilterTagAndCombination() {
        let snap = snapshot(participants: ["Kim"], tags: ["link"])
        XCTAssertTrue(AskFilter(tag: "Link").matches(snap, calendar: calendar))
        XCTAssertFalse(AskFilter(tag: "integrations").matches(snap, calendar: calendar))
        XCTAssertFalse(AskFilter(participant: "marcel", tag: "link").matches(snap, calendar: calendar))
        XCTAssertTrue(AskFilter(participant: "kim", tag: "link").matches(snap, calendar: calendar))
    }

    // MARK: - Load

    @MainActor
    func testLoadSkipsPendingDeletionUpcomingAndEmpty() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let kept = Meeting(title: "Kept", date: date(2026, 11, 3, 9), participants: ["Kim"], status: .completed)
        kept.transcript = "[00:05] we beginnen"
        kept.tags = ["link"]
        kept.actionItems = [item("Offerte opvragen", owner: "Kim")]
        let pending = Meeting(title: "Pending", date: date(2026, 11, 2, 9), status: .completed)
        pending.transcript = "[00:05] weg"
        let upcoming = Meeting(title: "Upcoming", date: date(2026, 11, 10, 9), status: .upcoming)
        upcoming.summary = "Agenda"
        let empty = Meeting(title: "Empty", date: date(2026, 11, 1, 9), status: .completed)
        empty.summary = "   "
        for meeting in [kept, pending, upcoming, empty] { context.insert(meeting) }
        try context.save()

        let pendingID = pending.id
        let snapshots = try AskCorpus.load(from: context) { $0 == pendingID }

        XCTAssertEqual(snapshots.count, 1)
        let snap = try XCTUnwrap(snapshots.first)
        XCTAssertEqual(snap.id, kept.id)
        XCTAssertEqual(snap.title, "Kept")
        XCTAssertEqual(snap.participants, ["Kim"])
        XCTAssertEqual(snap.tags, ["link"])
        XCTAssertEqual(snap.transcript, "[00:05] we beginnen")
        XCTAssertNil(snap.summary)
        XCTAssertEqual(snap.actionItems.map(\.task), ["Offerte opvragen"])
    }

    @MainActor
    func testLoadSortsByDateDescendingAndRespectsLimitAndOffset() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        for day in 1...3 {
            let meeting = Meeting(title: "Dag \(day)", date: date(2026, 11, day, 9), status: .completed)
            meeting.summary = "Samenvatting \(day)"
            context.insert(meeting)
        }
        try context.save()

        XCTAssertEqual(try AskCorpus.load(from: context) { _ in false }.map(\.title), ["Dag 3", "Dag 2", "Dag 1"])
        XCTAssertEqual(try AskCorpus.load(from: context, limit: 2) { _ in false }.map(\.title), ["Dag 3", "Dag 2"])
        XCTAssertEqual(
            try AskCorpus.load(from: context, limit: 2, offset: 2) { _ in false }.map(\.title),
            ["Dag 1"]
        )
    }

    @MainActor
    func testLoadPagesDeterministicallyWhenDatesTie() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let shared = date(2026, 11, 3, 9)
        let createdAt = date(2026, 11, 1, 8)
        var ids: [UUID] = []
        for n in 1...3 {
            let meeting = Meeting(title: "Gelijk \(n)", date: shared, status: .completed)
            meeting.summary = "Samenvatting \(n)"
            meeting.createdAt = createdAt   // force a full tie on date AND createdAt
            context.insert(meeting)
            ids.append(meeting.id)
        }
        try context.save()

        func pageThrough() throws -> [UUID] {
            var result: [UUID] = []
            for offset in 0..<4 {
                result += try AskCorpus.load(from: context, limit: 1, offset: offset) { _ in false }.map(\.id)
            }
            return result
        }
        let first = try pageThrough()
        XCTAssertEqual(first.count, 3)
        XCTAssertEqual(Set(first), Set(ids), "every meeting exactly once")
        XCTAssertEqual(first, ids.sorted(), "ties fall back to id ascending")
        XCTAssertEqual(try pageThrough(), first, "order is stable across runs")
        XCTAssertEqual(try AskCorpus.load(from: context) { _ in false }.map(\.id), first)
    }

    @MainActor
    func testLoadPageReportsFetchedRowsSoSkippedRowsDoNotEndPaging() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let newest = Meeting(title: "Leeg", date: date(2026, 11, 3, 9), status: .completed)   // skipped: empty
        let older = Meeting(title: "Ouder", date: date(2026, 11, 2, 9), status: .completed)
        older.summary = "Samenvatting"
        context.insert(newest)
        context.insert(older)
        try context.save()

        let first = try AskCorpus.loadPage(from: context, limit: 1, offset: 0) { _ in false }
        XCTAssertEqual(first.snapshots, [])
        XCTAssertEqual(first.fetchedRows, 1, "an all-skipped page is not the last page")
        let second = try AskCorpus.loadPage(from: context, limit: 1, offset: 1) { _ in false }
        XCTAssertEqual(second.snapshots.map(\.title), ["Ouder"])
        let third = try AskCorpus.loadPage(from: context, limit: 1, offset: 2) { _ in false }
        XCTAssertEqual(third.fetchedRows, 0)
    }

    /// Seeds (and saves) on the main actor: the app's `SidebarMeetingsProvider`
    /// observes every `ModelContext.didSave` with `MainActor.assumeIsolated`,
    /// so an off-main save traps in the test host. Only the fetch runs off-main.
    @MainActor
    func testLoadRunsOnABackgroundContext() async throws {
        let container = try makeContainer()
        let seed = ModelContext(container)
        let meeting = Meeting(title: "Achtergrond", date: date(2026, 11, 3, 9), status: .completed)
        meeting.summary = "Samenvatting"
        seed.insert(meeting)
        try seed.save()

        let titles = try await Task.detached {
            try AskCorpus.load(from: ModelContext(container)) { _ in false }.map(\.title)
        }.value
        XCTAssertEqual(titles, ["Achtergrond"])
    }

    // MARK: - Filter options

    func testFilterOptionsDistinctSorted() {
        let snapshots = [
            snapshot(participants: ["Kim Owen-Jones", "youri"], tags: ["link", "bgz"]),
            snapshot(participants: ["Arriejanne", "Kim Owen-Jones", " "], tags: ["link", "orchestra"]),
        ]
        let options = AskCorpus.filterOptions(snapshots)
        XCTAssertEqual(options.participants, ["Arriejanne", "Kim Owen-Jones", "youri"])
        XCTAssertEqual(options.tags, ["bgz", "link", "orchestra"])
    }
}
