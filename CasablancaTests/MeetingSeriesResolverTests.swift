import SwiftData
import XCTest
@testable import Casablanca

@MainActor
final class MeetingSeriesResolverTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Meeting.self, TodoItem.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// Mirrors `findOrCreateMeeting(for:)` for a recurring occurrence. We can't set
    /// `EKEvent.eventIdentifier` (read-only, not KVC-settable), so the test drives
    /// the EKEvent-free core which the EKEvent overload delegates to.
    private func findOrCreate(_ vm: MeetingListViewModel, id: String, start: Date) -> Meeting? {
        vm.findOrCreateMeeting(
            calendarEventID: id,
            occurrenceStart: start,
            title: "Weekly Sync",
            endDate: start.addingTimeInterval(1800),
            participants: []
        )
    }

    // MARK: - Occurrence-collision fix

    func testTwoOccurrencesOfSameSeriesProduceTwoDistinctRows() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let viewModel = MeetingListViewModel(calendarService: CalendarService())
        viewModel.setModelContext(context)

        let sharedID = "recurring-shared-id"
        guard let m1 = findOrCreate(viewModel, id: sharedID, start: Date(timeIntervalSince1970: 1_000_000)),
              let m2 = findOrCreate(viewModel, id: sharedID, start: Date(timeIntervalSince1970: 1_604_800)) else {
            return XCTFail("Expected both occurrences to resolve")
        }

        XCTAssertNotEqual(m1.id, m2.id, "Two occurrences sharing a calendar id must be distinct rows")
        XCTAssertEqual(m1.calendarEventID, m2.calendarEventID, "Both occurrences share the series id")

        let meetings = try context.fetch(FetchDescriptor<Meeting>())
        XCTAssertEqual(meetings.count, 2)
    }

    func testSubSecondJitteredOccurrenceStartReturnsSameRowNotADuplicate() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let viewModel = MeetingListViewModel(calendarService: CalendarService())
        viewModel.setModelContext(context)

        let sharedID = "recurring-shared-id"
        // Same occurrence, but EventKit hands back a start that differs by a
        // sub-second amount (< 0.5s) between two fetches. Normalization to whole
        // seconds must collapse them to the SAME row — no duplicate.
        let firstFetch = findOrCreate(viewModel, id: sharedID, start: Date(timeIntervalSince1970: 1_000.0))
        let secondFetch = findOrCreate(viewModel, id: sharedID, start: Date(timeIntervalSince1970: 1_000.3))

        XCTAssertNotNil(firstFetch)
        XCTAssertEqual(firstFetch?.id, secondFetch?.id, "Jittered start for the same occurrence must resolve to the same row")

        let meetings = try context.fetch(FetchDescriptor<Meeting>())
        XCTAssertEqual(meetings.count, 1, "Sub-second jitter must not create a duplicate meeting")
    }

    func testOpeningAnOccurrenceReturnsItsOwnRowNotTheFirst() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let viewModel = MeetingListViewModel(calendarService: CalendarService())
        viewModel.setModelContext(context)

        let sharedID = "recurring-shared-id"
        let week1Start = Date(timeIntervalSince1970: 1_000_000)
        let week2Start = Date(timeIntervalSince1970: 1_604_800)

        let m1 = findOrCreate(viewModel, id: sharedID, start: week1Start)
        let m2 = findOrCreate(viewModel, id: sharedID, start: week2Start)

        // Re-opening week 2 must return week 2's row, NOT week 1's.
        let reopenedWeek2 = findOrCreate(viewModel, id: sharedID, start: week2Start)
        XCTAssertEqual(reopenedWeek2?.id, m2?.id)
        XCTAssertNotEqual(reopenedWeek2?.id, m1?.id)

        let reopenedWeek1 = findOrCreate(viewModel, id: sharedID, start: week1Start)
        XCTAssertEqual(reopenedWeek1?.id, m1?.id)

        let meetings = try context.fetch(FetchDescriptor<Meeting>())
        XCTAssertEqual(meetings.count, 2, "No extra rows should have been created on re-open")
    }

    // MARK: - previousOccurrence

    func testFindsPreviousOccurrenceInSameSeries() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let id = "series-A"
        let older = Meeting(title: "Weekly Sync", date: Date(timeIntervalSince1970: 1_000), calendarEventID: id)
        let middle = Meeting(title: "Weekly Sync", date: Date(timeIntervalSince1970: 2_000), calendarEventID: id)
        let current = Meeting(title: "Weekly Sync", date: Date(timeIntervalSince1970: 3_000), calendarEventID: id)
        [older, middle, current].forEach(context.insert)
        try context.save()

        let previous = MeetingSeriesResolver.previousOccurrence(of: current, in: context)
        XCTAssertEqual(previous?.id, middle.id, "Should pick the most-recent earlier occurrence")
    }

    func testIgnoresOtherSeriesWhenFindingPrevious() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let current = Meeting(title: "Weekly Sync", date: Date(timeIntervalSince1970: 3_000), calendarEventID: "series-A")
        let otherSeries = Meeting(title: "Other", date: Date(timeIntervalSince1970: 2_000), calendarEventID: "series-B")
        [current, otherSeries].forEach(context.insert)
        try context.save()

        XCTAssertNil(MeetingSeriesResolver.previousOccurrence(of: current, in: context))
    }

    func testNilWhenNoPreviousOccurrence() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let first = Meeting(title: "Weekly Sync", date: Date(timeIntervalSince1970: 1_000), calendarEventID: "series-A")
        context.insert(first)
        try context.save()

        XCTAssertNil(MeetingSeriesResolver.previousOccurrence(of: first, in: context))
    }

    func testTitleFallbackForManualMeetings() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        // No calendarEventID — must match on normalized title.
        let older = Meeting(title: "Team Link Refinement", date: Date(timeIntervalSince1970: 1_000))
        let current = Meeting(title: "team link refinement", date: Date(timeIntervalSince1970: 2_000))
        let unrelated = Meeting(title: "Standup", date: Date(timeIntervalSince1970: 1_500))
        [older, current, unrelated].forEach(context.insert)
        try context.save()

        let previous = MeetingSeriesResolver.previousOccurrence(of: current, in: context)
        XCTAssertEqual(previous?.id, older.id, "Case-insensitive title fallback should match")
    }

    func testNextOccurrence() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let id = "series-A"
        let current = Meeting(title: "Weekly Sync", date: Date(timeIntervalSince1970: 2_000), calendarEventID: id)
        let next = Meeting(title: "Weekly Sync", date: Date(timeIntervalSince1970: 3_000), calendarEventID: id)
        let later = Meeting(title: "Weekly Sync", date: Date(timeIntervalSince1970: 4_000), calendarEventID: id)
        [current, next, later].forEach(context.insert)
        try context.save()

        XCTAssertEqual(MeetingSeriesResolver.nextOccurrence(of: current, in: context)?.id, next.id)
    }

    // MARK: - Carry-over markdown (pure)

    func testCarryOverMarkdownCarriesOnlyUncheckedTodos() {
        let previous = Meeting(title: "Weekly Sync", date: .now)
        let open1 = TodoItem(text: "Follow up with Kim", isCompleted: false, meeting: previous)
        let done = TodoItem(text: "Send agenda", isCompleted: true, meeting: previous)
        let open2 = TodoItem(text: "Review BgZ spec", isCompleted: false, meeting: previous)
        previous.todos = [open1, done, open2]

        let markdown = MeetingSeriesResolver.carryOverMarkdown(from: previous)
        XCTAssertEqual(markdown, """
        ## From last time
        - [ ] Follow up with Kim
        - [ ] Review BgZ spec
        """)
        XCTAssertFalse(markdown?.contains("Send agenda") ?? true, "Completed todos must not be carried over")
    }

    func testCarryOverMarkdownNilWhenNoOpenTodos() {
        let previous = Meeting(title: "Weekly Sync", date: .now)
        previous.todos = [TodoItem(text: "Done thing", isCompleted: true, meeting: previous)]

        XCTAssertNil(MeetingSeriesResolver.carryOverMarkdown(from: previous))
    }

    func testAppendingCarryOverSeparatesFromExistingPrep() {
        let previous = Meeting(title: "Weekly Sync", date: .now)
        previous.todos = [TodoItem(text: "Open item", isCompleted: false, meeting: previous)]

        let appended = MeetingSeriesResolver.appendingCarryOver(to: "## Goal\nShip it", from: previous)
        XCTAssertEqual(appended, "## Goal\nShip it\n\n## From last time\n- [ ] Open item")
    }

    func testAppendingCarryOverToEmptyPrepHasNoLeadingBlankLines() {
        let previous = Meeting(title: "Weekly Sync", date: .now)
        previous.todos = [TodoItem(text: "Open item", isCompleted: false, meeting: previous)]

        let appended = MeetingSeriesResolver.appendingCarryOver(to: "   \n", from: previous)
        XCTAssertEqual(appended, "## From last time\n- [ ] Open item")
    }

    func testOpenTodosAreSortedByCreatedAt() {
        let previous = Meeting(title: "Weekly Sync", date: .now)
        let later = TodoItem(text: "Second", isCompleted: false, createdAt: Date(timeIntervalSince1970: 200), meeting: previous)
        let earlier = TodoItem(text: "First", isCompleted: false, createdAt: Date(timeIntervalSince1970: 100), meeting: previous)
        previous.todos = [later, earlier]

        let open = MeetingSeriesResolver.openTodos(of: previous)
        XCTAssertEqual(open.map(\.text), ["First", "Second"])
    }
}
