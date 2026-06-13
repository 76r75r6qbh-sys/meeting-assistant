import Foundation
import XCTest
@testable import Casablanca

/// Exercises the PURE scheduling-decision logic (`MeetingStartScheduleDecision`),
/// not `UNUserNotificationCenter`. Verifies horizon/lead-time filtering, dedupe by
/// identifier, stable request ids, and the toggle-off short-circuit.
final class MeetingStartNotifierTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let horizon: TimeInterval = 24 * 60 * 60

    private func decide(
        _ events: [(identifier: String, title: String, startDate: Date)],
        leadTime: MeetingStartLeadTime = .atStart,
        isEnabled: Bool = true
    ) -> [ScheduledMeetingStartNotification] {
        MeetingStartScheduleDecision.notifications(
            for: events,
            now: now,
            horizon: horizon,
            leadTime: leadTime,
            isEnabled: isEnabled
        )
    }

    func testSchedulesUpcomingEventWithinHorizon() {
        let start = now.addingTimeInterval(30 * 60)
        let result = decide([(identifier: "e1", title: "Standup", startDate: start)])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].eventIdentifier, "e1")
        XCTAssertEqual(result[0].title, "Meeting starting: Standup")
        XCTAssertEqual(result[0].fireDate, start, "at-start lead time fires exactly at start")
        XCTAssertEqual(result[0].requestIdentifier, "meeting-start-e1", "stable id keyed by event id")
    }

    func testFiltersPastEvents() {
        let result = decide([(identifier: "past", title: "Done", startDate: now.addingTimeInterval(-60))])
        XCTAssertTrue(result.isEmpty, "events that already started must not be scheduled")
    }

    func testFiltersEventsBeyondHorizon() {
        let beyond = now.addingTimeInterval(horizon + 60)
        let result = decide([(identifier: "later", title: "Tomorrow+", startDate: beyond)])
        XCTAssertTrue(result.isEmpty, "events beyond the horizon must not be scheduled")
    }

    func testRespectsLeadTime() {
        let start = now.addingTimeInterval(30 * 60)
        let result = decide([(identifier: "e1", title: "M", startDate: start)], leadTime: .fiveMinutes)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].fireDate, start.addingTimeInterval(-300), "5-min lead fires 5 minutes before start")
    }

    func testLeadTimePushingFireDateIntoPastIsSkipped() {
        // Starts in 2 minutes, but the 5-minute lead would fire 3 minutes ago.
        let start = now.addingTimeInterval(2 * 60)
        let result = decide([(identifier: "soon", title: "Soon", startDate: start)], leadTime: .fiveMinutes)
        XCTAssertTrue(result.isEmpty, "a lead time that lands in the past must be skipped")
    }

    func testDedupesByIdentifier() {
        let start = now.addingTimeInterval(20 * 60)
        let result = decide([
            (identifier: "dup", title: "First", startDate: start),
            (identifier: "dup", title: "Second", startDate: start.addingTimeInterval(60))
        ])
        XCTAssertEqual(result.count, 1, "duplicate event identifiers collapse to one notification")
        XCTAssertEqual(result[0].title, "Meeting starting: First", "first-seen wins")
    }

    func testSkipsEmptyIdentifier() {
        let result = decide([(identifier: "", title: "Anon", startDate: now.addingTimeInterval(10 * 60))])
        XCTAssertTrue(result.isEmpty, "events with no identifier cannot be addressed and are skipped")
    }

    func testEmptyWhenDisabled() {
        let start = now.addingTimeInterval(30 * 60)
        let result = decide([(identifier: "e1", title: "M", startDate: start)], isEnabled: false)
        XCTAssertTrue(result.isEmpty, "toggle off yields no notifications (caller cancels all)")
    }

    func testMultipleEventsAllWithinHorizon() {
        let result = decide([
            (identifier: "a", title: "A", startDate: now.addingTimeInterval(10 * 60)),
            (identifier: "b", title: "B", startDate: now.addingTimeInterval(20 * 60)),
            (identifier: "c", title: "C", startDate: now.addingTimeInterval(30 * 60))
        ])
        XCTAssertEqual(Set(result.map(\.eventIdentifier)), ["a", "b", "c"])
    }
}
