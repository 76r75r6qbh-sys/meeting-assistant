import XCTest
@testable import Casablanca

final class ActionQueueSectionStateTests: XCTestCase {
    private func makeDefaults(suite: String = UUID().uuidString) -> UserDefaults {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testDefaultsToExpanded() {
        let state = ActionQueueSectionState(defaults: makeDefaults())
        XCTAssertFalse(state.isCollapsed(ActionQueueSectionState.key(for: .ticketDraft)))
        XCTAssertFalse(state.isCollapsed("general"))
    }

    func testToggleCollapsesAndExpands() {
        let state = ActionQueueSectionState(defaults: makeDefaults())
        let key = ActionQueueSectionState.key(for: .partnerApiReply)

        state.toggle(key)
        XCTAssertTrue(state.isCollapsed(key))

        state.toggle(key)
        XCTAssertFalse(state.isCollapsed(key))
    }

    func testTogglePersistsAcrossInstances() {
        let defaults = makeDefaults()
        let key = ActionQueueSectionState.key(for: .todo)

        let first = ActionQueueSectionState(defaults: defaults)
        first.toggle(key)
        XCTAssertTrue(first.isCollapsed(key))

        // A fresh instance reading the same suite sees the persisted collapse.
        let second = ActionQueueSectionState(defaults: defaults)
        XCTAssertTrue(second.isCollapsed(key))
    }

    func testTogglesAreIndependentPerKey() {
        let state = ActionQueueSectionState(defaults: makeDefaults())
        let a = ActionQueueSectionState.key(for: .ticketDraft)
        let b = ActionQueueSectionState.key(for: .calendarEvent)

        state.toggle(a)
        XCTAssertTrue(state.isCollapsed(a))
        XCTAssertFalse(state.isCollapsed(b))
    }

    func testKeyMapping() {
        XCTAssertEqual(ActionQueueSectionState.key(for: nil), "general")
        XCTAssertEqual(ActionQueueSectionState.key(for: .ticketDraft), "ticket_draft")
        XCTAssertEqual(ActionQueueSectionState.key(for: .unknown("weird")), "unknown:weird")
    }
}
