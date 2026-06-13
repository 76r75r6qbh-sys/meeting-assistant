import XCTest
@testable import Casablanca

final class MeetingTimeBucketTests: XCTestCase {
    private var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
    private let now = ISO8601DateFormatter().date(from: "2026-05-30T12:00:00Z")!

    func test_futureIsUpcoming() {
        XCTAssertEqual(MeetingTimeBucket.bucket(for: date("2026-05-30T15:00:00Z"), now: now, calendar: calendar), .upcoming)
    }
    func test_earlierTodayIsToday() {
        XCTAssertEqual(MeetingTimeBucket.bucket(for: date("2026-05-30T09:00:00Z"), now: now, calendar: calendar), .today)
    }
    func test_earlierThisCalendarWeekIsThisWeek() {
        XCTAssertEqual(MeetingTimeBucket.bucket(for: date("2026-05-25T09:00:00Z"), now: now, calendar: calendar), .thisWeek)
    }
    func test_earlierThisMonth() {
        XCTAssertEqual(MeetingTimeBucket.bucket(for: date("2026-05-05T09:00:00Z"), now: now, calendar: calendar), .thisMonth)
    }
    func test_earlierThisYear() {
        XCTAssertEqual(MeetingTimeBucket.bucket(for: date("2026-03-04T09:00:00Z"), now: now, calendar: calendar), .thisYear)
    }
    func test_priorYear() {
        XCTAssertEqual(MeetingTimeBucket.bucket(for: date("2025-11-01T09:00:00Z"), now: now, calendar: calendar), .earlier)
    }
}
