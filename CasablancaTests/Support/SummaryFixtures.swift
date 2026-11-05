import Foundation
@testable import Casablanca

/// Canned model replies for the summarization tests: markdown notes followed by
/// the fenced JSON facts block the single-pass prompt asks for.
enum SummaryFixtures {
    /// A valid facts object with every list empty.
    static let emptyFactsJSON = #"{"topics":[],"decisions":[],"action_items":[],"open_questions":[],"facts":[]}"#

    /// A valid facts object with one action item owned by Kim.
    static let kimActionJSON = #"""
    {"topics":["Offerte"],"decisions":[],"action_items":[{"task":"Mail de offerte","owner":"Kim","due":"vrijdag","due_is_explicit":true,"confidence":0.8,"quote":"ik mail de offerte","timestamp":"00:10"}],"open_questions":[],"facts":[]}
    """#

    /// `markdown`, a blank line, then `json` in a ```` ```json ```` fence.
    static func withFacts(_ markdown: String, json: String = emptyFactsJSON) -> String {
        markdown + "\n\n```json\n" + json + "\n```"
    }

    /// ISO-8601 calendar in Europe/Amsterdam, as the service tests inject it.
    static var amsterdamCalendar: Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return calendar
    }

    /// Wednesday 2026-11-04, 14:00 in Amsterdam.
    static var meetingDate: Date {
        amsterdamCalendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 14))!
    }
}
