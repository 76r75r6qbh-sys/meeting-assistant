import Foundation
@testable import Casablanca

/// `MeetingAttendeeProviding` double: returns the same fixed attendees for every
/// meeting, so tests never touch EventKit or the user's calendar.
struct StaticAttendeeProvider: MeetingAttendeeProviding {
    var attendees: [MeetingAttendee] = []

    @MainActor
    func attendees(for meeting: Meeting) -> [MeetingAttendee] {
        attendees
    }
}
