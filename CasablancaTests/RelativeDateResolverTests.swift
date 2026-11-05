import XCTest
@testable import Casablanca

final class RelativeDateResolverTests: XCTestCase {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return cal
    }

    /// Noon local time on the given day, so time-zone edges cannot shift it.
    private func day(_ iso: String) -> Date {
        let parts = iso.split(separator: "-").compactMap { Int($0) }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))!
    }

    /// Meeting on Wednesday 2026-11-04 unless stated otherwise.
    private func resolve(_ raw: String?, explicit: Bool = false, on meeting: String = "2026-11-04") -> (String?, Bool) {
        let r = RelativeDateResolver.resolve(raw, llmSaysExplicit: explicit, meetingDate: day(meeting), calendar: calendar)
        return (r.iso, r.isExplicit)
    }

    func testIsoPassesThrough() {
        XCTAssertEqual(resolve("2026-11-20", explicit: true).0, "2026-11-20")
        XCTAssertEqual(resolve("2026-11-20", explicit: true).1, true)
        XCTAssertEqual(resolve("2026-11-20", explicit: false).1, false)
        XCTAssertNil(resolve("2026-02-30").0)
    }

    func testTomorrowAndOvermorgen() {
        XCTAssertEqual(resolve("morgen").0, "2026-11-05")
        XCTAssertEqual(resolve("morgen").1, true)
        XCTAssertEqual(resolve("Tomorrow").0, "2026-11-05")
        XCTAssertEqual(resolve("overmorgen").0, "2026-11-06")
        XCTAssertEqual(resolve("the day after tomorrow").0, "2026-11-06")
        XCTAssertEqual(resolve("vandaag").0, "2026-11-04")
    }

    func testWeekdayIsFirstOneAfterTheMeeting() {
        XCTAssertEqual(resolve("vrijdag").0, "2026-11-06")
        XCTAssertEqual(resolve("vrijdag").1, true)
        XCTAssertEqual(resolve("voor aanstaande maandag").0, "2026-11-09")
        XCTAssertEqual(resolve("next Tuesday").0, "2026-11-10")
    }

    func testWeekdayOnSameWeekdayIsNextWeek() {
        XCTAssertEqual(resolve("vrijdag", on: "2026-11-06").0, "2026-11-13")
        XCTAssertEqual(resolve("vrijdag", on: "2026-11-06").1, true)
    }

    func testNextWeekWeekday() {
        XCTAssertEqual(resolve("volgende week dinsdag").0, "2026-11-10")
        XCTAssertEqual(resolve("volgende week dinsdag").1, true)
        XCTAssertEqual(resolve("next week Friday").0, "2026-11-13")
    }

    func testVolgendeWeekIsMondayNotExplicit() {
        XCTAssertEqual(resolve("volgende week").0, "2026-11-09")
        XCTAssertEqual(resolve("volgende week").1, false)
        XCTAssertEqual(resolve("next week").0, "2026-11-09")
    }

    func testInDaysAndWeeks() {
        XCTAssertEqual(resolve("over 3 dagen").0, "2026-11-07")
        XCTAssertEqual(resolve("over 3 dagen").1, true)
        XCTAssertEqual(resolve("in 2 weeks").0, "2026-11-18")
        XCTAssertEqual(resolve("in 2 weeks").1, false)
    }

    func testEndOfWeekMidweekIsThisFriday() {
        XCTAssertEqual(resolve("eind van de week").0, "2026-11-06")
        XCTAssertEqual(resolve("eind van de week").1, false)
    }

    func testEndOfWeekOnSaturdayIsNextFriday() {
        XCTAssertEqual(resolve("end of the week", on: "2026-11-07").0, "2026-11-13")
        XCTAssertEqual(resolve("einde week", on: "2026-11-06").0, "2026-11-13")
    }

    func testEndOfMonth() {
        XCTAssertEqual(resolve("eind van de maand").0, "2026-11-30")
        XCTAssertEqual(resolve("end of month").1, false)
    }

    func testDayMonthInMeetingYear() {
        XCTAssertEqual(resolve("15 november").0, "2026-11-15")
        XCTAssertEqual(resolve("15 november").1, true)
        XCTAssertEqual(resolve("December 3rd").0, "2026-12-03")
    }

    func testDayMonthRollsToNextYear() {
        XCTAssertEqual(resolve("5 januari", on: "2026-12-20").0, "2027-01-05")
        XCTAssertEqual(resolve("5 januari", on: "2026-12-20").1, true)
    }

    func testGarbageIsNil() {
        for raw in [nil, "", "  ", "null", "binnenkort", "asap", "31 februari"] as [String?] {
            let r = resolve(raw, explicit: true)
            XCTAssertNil(r.0, "\(String(describing: raw))")
            XCTAssertFalse(r.1, "\(String(describing: raw))")
        }
    }
}
