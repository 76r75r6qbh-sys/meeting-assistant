import SwiftData
import XCTest
@testable import Casablanca

@MainActor
final class SidebarMeetingsProviderTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Meeting.self, TodoItem.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    @discardableResult
    private func insertMeetings(
        count: Int,
        titlePrefix: String = "Meeting",
        baseDate: Date = Date(timeIntervalSince1970: 1_000_000),
        into context: ModelContext
    ) throws -> [Meeting] {
        var meetings: [Meeting] = []
        for index in 0..<count {
            // Each later index is OLDER so a reverse-date sort returns index 0 first.
            let meeting = Meeting(
                title: "\(titlePrefix) \(index)",
                date: baseDate.addingTimeInterval(Double(-index) * 60),
                status: .completed
            )
            context.insert(meeting)
            meetings.append(meeting)
        }
        try context.save()
        return meetings
    }

    func testWindowRespectsInitialFetchLimit() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        try insertMeetings(count: SidebarMeetingsProvider.pageSize + 50, into: context)

        let provider = SidebarMeetingsProvider(modelContext: context)

        XCTAssertEqual(provider.meetings.count, SidebarMeetingsProvider.pageSize)
        XCTAssertTrue(provider.hasMore)
    }

    func testShowEarlierGrowsTheWindow() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let total = SidebarMeetingsProvider.pageSize + 30
        try insertMeetings(count: total, into: context)

        let provider = SidebarMeetingsProvider(modelContext: context)
        XCTAssertEqual(provider.meetings.count, SidebarMeetingsProvider.pageSize)

        provider.loadMore()

        XCTAssertEqual(provider.meetings.count, total)
        XCTAssertFalse(provider.hasMore, "Window now exceeds total, so there is nothing more to show")
    }

    func testWindowIsReverseChronological() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        try insertMeetings(count: 5, into: context)

        let provider = SidebarMeetingsProvider(modelContext: context)

        let dates = provider.meetings.map(\.date)
        XCTAssertEqual(dates, dates.sorted(by: >), "Sidebar window must be newest-first")
    }

    func testTitlePredicateFiltersInTheFetch() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        try insertMeetings(count: 3, titlePrefix: "Refinement", into: context)
        try insertMeetings(count: 4, titlePrefix: "Standup", into: context)

        let provider = SidebarMeetingsProvider(modelContext: context)
        XCTAssertEqual(provider.meetings.count, 7)

        provider.searchText = "Refinement"

        XCTAssertEqual(provider.meetings.count, 3)
        XCTAssertTrue(provider.meetings.allSatisfy { $0.title.contains("Refinement") })

        // Clearing the filter restores the full window.
        provider.searchText = ""
        XCTAssertEqual(provider.meetings.count, 7)
    }

    func testTitlePredicateIsCaseInsensitive() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        try insertMeetings(count: 2, titlePrefix: "PM-PM Sync", into: context)
        try insertMeetings(count: 2, titlePrefix: "Daily", into: context)

        let provider = SidebarMeetingsProvider(modelContext: context)
        provider.searchText = "pm-pm"

        XCTAssertEqual(provider.meetings.count, 2)
    }

    func testDidSaveRefreshPicksUpNewMeeting() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        try insertMeetings(count: 2, into: context)

        let provider = SidebarMeetingsProvider(modelContext: context)
        XCTAssertEqual(provider.meetings.count, 2)

        let newMeeting = Meeting(title: "Brand New", date: Date(), status: .completed)
        context.insert(newMeeting)
        try context.save()

        XCTAssertEqual(provider.meetings.count, 3)
        XCTAssertTrue(provider.meetings.contains { $0.title == "Brand New" })
    }

    func testDidSaveRefreshPicksUpDeletion() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let meetings = try insertMeetings(count: 3, into: context)

        let provider = SidebarMeetingsProvider(modelContext: context)
        XCTAssertEqual(provider.meetings.count, 3)

        context.delete(meetings[0])
        try context.save()

        XCTAssertEqual(provider.meetings.count, 2)
    }

    func testBucketingStillCorrectOverTheWindow() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let now = Date()
        let calendar = Calendar.current

        let todayMeeting = Meeting(title: "Today", date: now.addingTimeInterval(-60), status: .completed)
        let earlierMeeting = Meeting(
            title: "Earlier",
            date: calendar.date(byAdding: .year, value: -2, to: now)!,
            status: .completed
        )
        context.insert(todayMeeting)
        context.insert(earlierMeeting)
        try context.save()

        let provider = SidebarMeetingsProvider(modelContext: context)

        let grouped = Dictionary(grouping: provider.meetings) {
            MeetingTimeBucket.bucket(for: $0.date, now: now)
        }
        XCTAssertEqual(grouped[.today]?.count, 1)
        XCTAssertEqual(grouped[.earlier]?.count, 1)
    }
}
