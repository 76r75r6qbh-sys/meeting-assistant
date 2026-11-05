// Casablanca/Services/RelativeDateResolver.swift
import Foundation

/// Turns the `due` value an LLM wrote ("2026-11-06", "vrijdag", "next week",
/// "5 januari") into an ISO date (`yyyy-MM-dd`) relative to the meeting day.
///
/// Dutch and English, case- and diacritic-insensitive; the phrase may be
/// embedded ("voor vrijdag"). Weeks are ISO weeks (Monday first) in the
/// injected calendar's time zone. Anything it cannot read yields `(nil, false)`.
enum RelativeDateResolver {
    static func resolve(
        _ raw: String?,
        llmSaysExplicit: Bool,
        meetingDate: Date,
        calendar: Calendar
    ) -> (iso: String?, isExplicit: Bool) {
        guard let raw else { return (nil, false) }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "null" else { return (nil, false) }

        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = calendar.timeZone
        let today = cal.startOfDay(for: meetingDate)

        // 1. An ISO date anywhere in the value passes through.
        if let m = firstMatch(#"(?<!\d)(\d{4})-(\d{2})-(\d{2})(?!\d)"#, in: trimmed) {
            guard let date = makeDate(year: Int(m[1]), month: Int(m[2]), day: Int(m[3]), cal) else { return (nil, false) }
            return (iso(date, cal), llmSaysExplicit)
        }

        let text = FuzzyText.normalized(trimmed)
        guard !text.isEmpty else { return (nil, false) }
        let isoWeekday = (cal.component(.weekday, from: today) + 5) % 7   // Monday = 0 … Sunday = 6
        let monday = add(-isoWeekday, to: today, cal)

        // 2. A day and a month name.
        if let date = dayMonth(text, today: today, cal) { return (iso(date, cal), true) }

        // 3. Today / tomorrow / the day after tomorrow.
        if matches(#"\b(overmorgen|day after tomorrow)\b"#, text) { return (iso(add(2, to: today, cal), cal), true) }
        if matches(#"\b(vandaag|today)\b"#, text) { return (iso(today, cal), true) }
        if matches(#"\b(morgen|tomorrow)\b"#, text) { return (iso(add(1, to: today, cal), cal), true) }

        // 4. "volgende week dinsdag" / "next week friday" / "friday next week".
        let weekdays = weekdayIndex.keys.joined(separator: "|")
        if let m = firstMatch(#"\b(?:volgende|next|komende) week (?:op )?("# + weekdays + #")\b"#, in: text)
            ?? firstMatch(#"\b("# + weekdays + #") (?:van )?(?:volgende|next|komende) week\b"#, in: text),
           let target = weekdayIndex[m[1]] {
            return (iso(add(7 + target, to: monday, cal), cal), true)
        }

        // 5. A weekday: the first one strictly after the meeting day.
        if let m = firstMatch(#"\b("# + weekdays + #")\b"#, in: text), let target = weekdayIndex[m[1]] {
            let ahead = (target - isoWeekday + 7) % 7
            return (iso(add(ahead == 0 ? 7 : ahead, to: today, cal), cal), true)
        }

        // 6. In N days / in N weeks.
        if let m = firstMatch(#"\b(?:over|in|binnen) (\d{1,3}) (?:dagen|dag|days|day)\b"#, in: text), let n = Int(m[1]) {
            return (iso(add(n, to: today, cal), cal), true)
        }
        if let m = firstMatch(#"\b(?:over|in|binnen) (\d{1,2}) (?:weken|week|weeks)\b"#, in: text), let n = Int(m[1]) {
            return (iso(add(7 * n, to: today, cal), cal), false)
        }

        // 7. End of the week / month.
        if matches(#"\beinde? (?:van )?(?:de |deze )?week\b"#, text) || matches(#"\bend of (?:the |this )?week\b"#, text) {
            return (iso(add(isoWeekday <= 3 ? 4 : 11, to: monday, cal), cal), false)
        }
        if matches(#"\beinde? (?:van )?(?:de |deze )?maand\b"#, text) || matches(#"\bend of (?:the |this )?month\b"#, text) {
            guard let range = cal.range(of: .day, in: .month, for: today) else { return (nil, false) }
            let c = cal.dateComponents([.year, .month], from: today)
            guard let date = makeDate(year: c.year, month: c.month, day: range.count, cal) else { return (nil, false) }
            return (iso(date, cal), false)
        }

        // 8. Next week without a day: its Monday.
        if matches(#"\b(?:volgende|next|komende) week\b"#, text) {
            return (iso(add(7, to: monday, cal), cal), false)
        }

        return (nil, false)
    }

    // MARK: - Vocabulary

    /// Folded weekday names → ISO index (Monday = 0).
    private static let weekdayIndex: [String: Int] = [
        "maandag": 0, "dinsdag": 1, "woensdag": 2, "donderdag": 3, "vrijdag": 4, "zaterdag": 5, "zondag": 6,
        "monday": 0, "tuesday": 1, "wednesday": 2, "thursday": 3, "friday": 4, "saturday": 5, "sunday": 6,
    ]

    /// Folded month names → month number.
    private static let monthNumber: [String: Int] = [
        "januari": 1, "februari": 2, "maart": 3, "april": 4, "mei": 5, "juni": 6, "juli": 7,
        "augustus": 8, "september": 9, "oktober": 10, "november": 11, "december": 12,
        "january": 1, "february": 2, "march": 3, "may": 5, "june": 6, "july": 7,
        "august": 8, "october": 10,
    ]

    /// `<day> <month>` or `<month> <day>`, optionally followed by a year. Without
    /// a year: the meeting's year, or the next one when that date lies more than
    /// 30 days before the meeting.
    private static func dayMonth(_ text: String, today: Date, _ cal: Calendar) -> Date? {
        let months = monthNumber.keys.joined(separator: "|")
        var day: Int?, month: Int?, year: Int?
        if let m = firstMatch(#"\b(\d{1,2})(?:st|nd|rd|th|ste|de|e)? (?:of )?("# + months + #")\b(?: (\d{4})\b)?"#, in: text) {
            day = Int(m[1]); month = monthNumber[m[2]]; year = m[3].isEmpty ? nil : Int(m[3])
        } else if let m = firstMatch(#"\b("# + months + #") (\d{1,2})(?:st|nd|rd|th)?\b(?: (\d{4})\b)?"#, in: text) {
            day = Int(m[2]); month = monthNumber[m[1]]; year = m[3].isEmpty ? nil : Int(m[3])
        }
        guard let day, let month else { return nil }
        if let year { return makeDate(year: year, month: month, day: day, cal) }
        let meetingYear = cal.component(.year, from: today)
        guard let candidate = makeDate(year: meetingYear, month: month, day: day, cal) else { return nil }
        if candidate < add(-30, to: today, cal) {
            return makeDate(year: meetingYear + 1, month: month, day: day, cal)
        }
        return candidate
    }

    // MARK: - Helpers

    private static func add(_ days: Int, to date: Date, _ cal: Calendar) -> Date {
        cal.date(byAdding: .day, value: days, to: date) ?? date
    }

    /// A real calendar date, or `nil` for e.g. 31 February.
    private static func makeDate(year: Int?, month: Int?, day: Int?, _ cal: Calendar) -> Date? {
        guard let year, let month, let day else { return nil }
        guard let date = cal.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        let c = cal.dateComponents([.year, .month, .day], from: date)
        guard c.year == year, c.month == month, c.day == day else { return nil }
        return date
    }

    private static func iso(_ date: Date, _ cal: Calendar) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        firstMatch(pattern, in: text) != nil
    }

    /// Capture groups of the first match (index 0 = whole match; an
    /// unmatched optional group is `""`), or `nil`.
    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        return (0..<match.numberOfRanges).map { i in
            Range(match.range(at: i), in: text).map { String(text[$0]) } ?? ""
        }
    }
}
