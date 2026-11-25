import Foundation
import XCTest
@testable import Casablanca

/// Focused on the EKEventStoreChanged debounce coalescing, driven directly with
/// a tiny interval so the test is deterministic and needs no system calendar
/// access. EventKit fires bursts of change notifications for a single edit; a
/// newer notification must cancel the prior pending refresh so we coalesce the
/// burst into a single settled refresh.
@MainActor
final class CalendarServiceTests: XCTestCase {
    func testNewDebounceCancelsPreviousPendingRefresh() async {
        let service = CalendarService(debounceInterval: .milliseconds(50))

        let first = service.scheduleDebouncedRefresh()
        // A second notification arriving within the debounce window must
        // supersede the first, cancelling it.
        let second = service.scheduleDebouncedRefresh()

        await first.value
        await second.value

        XCTAssertTrue(first.isCancelled, "earlier refresh must be cancelled by a newer one")
    }

    func testDebouncedRefreshCompletes() async {
        // No calendar access in tests, so fetchUpcomingEvents() is a guarded
        // no-op — but the scheduled task must still run to completion and not
        // leak or hang.
        let service = CalendarService(debounceInterval: .milliseconds(5))

        let task = service.scheduleDebouncedRefresh()
        await task.value

        XCTAssertFalse(task.isCancelled, "an undisturbed debounce task must complete, not cancel")
    }
}
