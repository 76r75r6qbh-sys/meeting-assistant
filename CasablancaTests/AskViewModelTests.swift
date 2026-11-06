import Foundation
import XCTest
@testable import Casablanca

final class AskViewModelTests: XCTestCase {

    private var calendar: Calendar { .current }

    private func date(_ y: Int, _ mo: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: 12))!
    }

    func testFormDefaultsProduceEmptyFilter() {
        let form = AskFormState()
        XCTAssertTrue(form.filter.isEmpty)
        XCTAssertEqual(form.filter, AskFilter.none)
        XCTAssertFalse(form.useDateRange)
        XCTAssertLessThanOrEqual(form.from, form.to, "The default range runs forwards")
    }

    func testBlankFieldsMapToNil() {
        var form = AskFormState()
        form.participant = "  "
        form.tag = "\n "
        XCTAssertNil(form.filter.participant)
        XCTAssertNil(form.filter.tag)
        XCTAssertTrue(form.filter.isEmpty)

        form.participant = " Kim "
        form.tag = "partner"
        XCTAssertEqual(form.filter.participant, "Kim")
        XCTAssertEqual(form.filter.tag, "partner")
    }

    func testDateRangeOnlyWhenToggled() {
        var form = AskFormState()
        form.from = date(2026, 10, 1)
        form.to = date(2026, 10, 31)
        XCTAssertNil(form.filter.from)
        XCTAssertNil(form.filter.to)

        form.useDateRange = true
        XCTAssertEqual(form.filter.from, date(2026, 10, 1))
        XCTAssertEqual(form.filter.to, date(2026, 10, 31))
    }

    func testSwappedDatesAreOrdered() throws {
        var form = AskFormState()
        form.useDateRange = true
        form.from = date(2026, 11, 5)
        form.to = date(2026, 11, 1)
        let from = try XCTUnwrap(form.filter.from)
        let to = try XCTUnwrap(form.filter.to)
        XCTAssertLessThanOrEqual(from, to)
        XCTAssertEqual(from, date(2026, 11, 1))
        XCTAssertEqual(to, date(2026, 11, 5))
    }

    func testCanSubmitNeedsQuestion() {
        var form = AskFormState()
        XCTAssertFalse(form.canSubmit)
        form.question = "  \n "
        XCTAssertFalse(form.canSubmit)
        form.question = "Wat hebben we besloten over BgZ?"
        XCTAssertTrue(form.canSubmit)
    }

    func testSidebarDestinationAskIsDistinct() {
        XCTAssertNotEqual(SidebarDestination.ask, .dashboard)
        let all: Set<SidebarDestination> = [.dashboard, .todos, .actionQueue, .ask, .meeting(UUID())]
        XCTAssertEqual(all.count, 5)
    }
}
