import EventKit
import SwiftData
import SwiftUI

@Observable
final class MeetingListViewModel {
    private let calendarService: CalendarService
    private var modelContext: ModelContext?

    var selectedMeeting: Meeting? {
        didSet {
            // Keep sidebar selection in sync
            if let meeting = selectedMeeting {
                _sidebarSelection = .meeting(meeting.id)
            } else {
                _sidebarSelection = .dashboard
            }
        }
    }

    private var _sidebarSelection: SidebarDestination = .dashboard

    var sidebarSelection: SidebarDestination? {
        get { _sidebarSelection }
        set {
            guard let newValue else { return }
            _sidebarSelection = newValue
            switch newValue {
            case .dashboard:
                selectedMeeting = nil
            case .meeting(let id):
                if selectedMeeting?.id != id {
                    selectedMeeting = fetchMeeting(byID: id)
                }
            }
        }
    }

    init(calendarService: CalendarService) {
        self.calendarService = calendarService
    }

    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
    }

    func save() {
        try? modelContext?.save()
    }

    var groupedEvents: [(date: Date, events: [EKEvent])] {
        calendarService.eventsGroupedByDay()
    }

    var isLoading: Bool {
        calendarService.isLoading
    }

    var hasEvents: Bool {
        !calendarService.events.isEmpty
    }

    var calendarAuthorized: Bool {
        calendarService.authorizationStatus == .fullAccess
    }

    var currentOrNextEvent: EKEvent? {
        let now = Date()

        if let currentEvent = calendarService.events.first(where: { isHappeningNow($0, referenceDate: now) }) {
            return currentEvent
        }

        return calendarService.events.first(where: { $0.startDate > now })
    }

    func requestCalendarAccess() async {
        _ = await calendarService.requestAccess()
    }

    func refreshEvents() async {
        await calendarService.fetchUpcomingEvents()
    }

    func fetchMeeting(byID id: UUID) -> Meeting? {
        guard let modelContext else { return nil }
        let descriptor = FetchDescriptor<Meeting>(
            predicate: #Predicate { meeting in
                meeting.id == id
            }
        )
        return try? modelContext.fetch(descriptor).first
    }

    func findOrCreateMeeting(for event: EKEvent) -> Meeting? {
        guard let modelContext else { return nil }

        // Look for existing meeting linked to this calendar event
        let eventID = event.eventIdentifier ?? ""
        let descriptor = FetchDescriptor<Meeting>(
            predicate: #Predicate { meeting in
                meeting.calendarEventID == eventID
            }
        )

        if let existing = try? modelContext.fetch(descriptor).first {
            return existing
        }

        // Create new meeting from calendar event
        let meeting = Meeting(
            title: event.title ?? "Untitled Meeting",
            date: event.startDate,
            endDate: event.endDate,
            calendarEventID: event.eventIdentifier,
            participants: event.attendees?.compactMap { $0.name } ?? []
        )

        modelContext.insert(meeting)
        try? modelContext.save()
        return meeting
    }

    func createManualMeeting(title: String) -> Meeting? {
        guard let modelContext else { return nil }

        let meeting = Meeting(
            title: title.isEmpty ? "Manual Meeting" : title,
            date: Date()
        )

        modelContext.insert(meeting)
        try? modelContext.save()
        return meeting
    }

    func beginManualMeeting(title: String = "") {
        guard let meeting = createManualMeeting(title: title) else { return }
        beginNotes(for: meeting)
    }

    func beginRecording(for event: EKEvent) {
        guard let meeting = findOrCreateMeeting(for: event) else { return }
        beginRecording(for: meeting)
    }

    func beginRecording(for meeting: Meeting) {
        meeting.status = .recording
        selectedMeeting = meeting
        save()
    }

    func beginNotes(for event: EKEvent) {
        guard let meeting = findOrCreateMeeting(for: event) else { return }
        beginNotes(for: meeting)
    }

    func beginNotes(for meeting: Meeting) {
        meeting.status = .notesOnly
        selectedMeeting = meeting
        save()
    }

    func dayLabel(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE, MMMM d, yyyy"
            return "Today \u{00B7} \(formatter.string(from: date))"
        } else if calendar.isDateInTomorrow(date) {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE, MMMM d, yyyy"
            return "Tomorrow \u{00B7} \(formatter.string(from: date))"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE, MMMM d, yyyy"
            return formatter.string(from: date)
        }
    }

    func isNextUpcoming(_ event: EKEvent) -> Bool {
        let now = Date()
        return event.startDate > now && calendarService.events
            .filter { $0.startDate > now }
            .sorted { $0.startDate < $1.startDate }
            .first?.eventIdentifier == event.eventIdentifier
    }

    func timeUntil(_ event: EKEvent) -> String? {
        let now = Date()
        guard event.startDate > now else { return nil }
        let interval = event.startDate.timeIntervalSince(now)

        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60

        if hours > 0 {
            return "in \(hours)h \(minutes)m"
        }
        return "in \(minutes)m"
    }

    func isHappeningNow(_ event: EKEvent, referenceDate: Date = Date()) -> Bool {
        event.startDate <= referenceDate && event.endDate > referenceDate
    }
}
