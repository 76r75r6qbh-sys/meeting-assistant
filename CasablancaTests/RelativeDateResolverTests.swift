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

    func testDagdeelCompoundsKeepTheWeekday() {
        let cases = ["maandagmorgen": "2026-11-09", "vrijdagmiddag": "2026-11-06", "maandag morgen": "2026-11-09",
                     "maandag-ochtend": "2026-11-09", "donderdagavond": "2026-11-05", "voor dinsdag ochtend": "2026-11-10"]
        for (raw, expected) in cases {
            XCTAssertEqual(resolve(raw).0, expected, raw)
            XCTAssertEqual(resolve(raw).1, true, raw)
        }
        XCTAssertEqual(resolve("morgenochtend").0, "2026-11-05")
        XCTAssertEqual(resolve("morgen").0, "2026-11-05")
    }

    func testEndOfNextWeekIsThatWeeksFriday() {
        XCTAssertEqual(resolve("eind volgende week").0, "2026-11-13")
        XCTAssertEqual(resolve("eind volgende week").1, false)
        XCTAssertEqual(resolve("end of next week").0, "2026-11-13")
        XCTAssertEqual(resolve("eind van volgende week", on: "2026-11-07").0, "2026-11-13")
    }

    func testWeekdayAcrossDSTChange() {
        // Summer time ends 2026-10-25 in Europe/Amsterdam.
        XCTAssertEqual(resolve("maandag", on: "2026-10-23").0, "2026-10-26")
        let lateEvening = calendar.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 23, minute: 30))!
        XCTAssertEqual(RelativeDateResolver.resolve("maandag", llmSaysExplicit: false, meetingDate: lateEvening, calendar: calendar).iso,
                       "2026-10-26")
    }

    func testUsesInjectedTimeZoneNotUTC() {
        // 00:30 on Wed 2026-11-04 in Amsterdam is still Tue 2026-11-03 in UTC.
        let justAfterMidnight = calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 0, minute: 30))!
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(utc.component(.day, from: justAfterMidnight), 3)
        XCTAssertEqual(RelativeDateResolver.resolve("morgen", llmSaysExplicit: false, meetingDate: justAfterMidnight, calendar: calendar).iso,
                       "2026-11-05")
        XCTAssertEqual(RelativeDateResolver.resolve("woensdag", llmSaysExplicit: false, meetingDate: justAfterMidnight, calendar: calendar).iso,
                       "2026-11-11")
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
