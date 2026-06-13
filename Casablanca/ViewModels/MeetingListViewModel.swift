import EventKit
import OSLog
import SwiftData
import SwiftUI

@MainActor
@Observable
final class MeetingListViewModel {
    private let calendarService: CalendarService
    private let removeItemAtURL: (URL) throws -> Void
    private let meetingHasPrep: (Meeting) -> Bool
    private let removeResumableRecordingSession: (UUID) throws -> Void
    private var modelContext: ModelContext?
    var meetingSearchText = ""

    /// Set when a SwiftData save/fetch fails, so the UI can surface it.
    var persistenceErrorMessage: String?

    var sidebarSelection: SidebarDestination? = .dashboard

    /// When non-nil, the preparation editor is presented for this meeting.
    var prepMeeting: Meeting?

    var selectedMeeting: Meeting? {
        get {
            if case .meeting(let id) = sidebarSelection {
                return fetchMeeting(byID: id)
            }
            return nil
        }
        set {
            if let meeting = newValue {
                sidebarSelection = .meeting(meeting.id)
            } else if sidebarSelection != .todos {
                sidebarSelection = .dashboard
            }
        }
    }

    init(
        calendarService: CalendarService,
        meetingHasPrep: @escaping (Meeting) -> Bool = { meeting in
            MeetingPrepService.hasPrep(for: meeting)
        },
        removeItemAtURL: @escaping (URL) throws -> Void = { url in
            try FileManager.default.removeItem(at: url)
        },
        removeResumableRecordingSession: @escaping (UUID) throws -> Void = { meetingID in
            try RecordingResumeSessionStore().deleteSession(for: meetingID)
        }
    ) {
        self.calendarService = calendarService
        self.meetingHasPrep = meetingHasPrep
        self.removeItemAtURL = removeItemAtURL
        self.removeResumableRecordingSession = removeResumableRecordingSession
    }

    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
    }

    func save() {
        guard let modelContext else { return }
        do {
            try modelContext.save()
        } catch {
            reportPersistenceFailure("Saving changes failed", error)
        }
    }

    private func reportPersistenceFailure(_ operation: String, _ error: Error) {
        Log.persistence.error("\(operation, privacy: .public): \(error.localizedDescription)")
        persistenceErrorMessage = "\(operation): \(error.localizedDescription)"
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

    /// The single most actionable meeting to surface in the dashboard hero:
    /// a meeting that is live right now, otherwise the earliest meeting that
    /// is still upcoming today. Returns `nil` when there is nothing actionable
    /// (no live meeting and no upcoming meeting left today).
    func actionableEventToday(referenceDate: Date = Date()) -> EKEvent? {
        let calendar = Calendar.current

        if let liveEvent = calendarService.events.first(where: { isHappeningNow($0, referenceDate: referenceDate) }) {
            return liveEvent
        }

        return calendarService.events
            .filter { $0.startDate > referenceDate && calendar.isDateInToday($0.startDate) }
            .min { $0.startDate < $1.startDate }
    }

    /// Presentation metadata for the dashboard hero, derived from the actionable meeting.
    func heroPresentation(referenceDate: Date = Date()) -> DashboardHeroPresentation? {
        guard let event = actionableEventToday(referenceDate: referenceDate) else { return nil }
        return DashboardHeroPresentation(event: event, referenceDate: referenceDate)
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
        do {
            return try modelContext.fetch(descriptor).first
        } catch {
            // Called from view bodies (e.g. `selectedMeeting`), so only log —
            // mutating observable state here would happen during a view update.
            Log.persistence.error("Fetching meeting by id failed: \(error.localizedDescription)")
            return nil
        }
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

        do {
            if let existing = try modelContext.fetch(descriptor).first {
                return existing
            }
        } catch {
            reportPersistenceFailure("Fetching meeting for calendar event failed", error)
            return nil
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
        do {
            try modelContext.save()
        } catch {
            reportPersistenceFailure("Saving meeting for calendar event failed", error)
        }
        return meeting
    }

    func createManualMeeting(title: String) -> Meeting? {
        guard let modelContext else { return nil }

        let meeting = Meeting(
            title: title.isEmpty ? "Manual Meeting" : title,
            date: Date()
        )

        modelContext.insert(meeting)
        do {
            try modelContext.save()
        } catch {
            reportPersistenceFailure("Saving manual meeting failed", error)
        }
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

    func beginPrepare(for event: EKEvent) {
        guard let meeting = findOrCreateMeeting(for: event) else { return }
        beginPrepare(for: meeting)
    }

    func beginPrepare(for meeting: Meeting) {
        prepMeeting = meeting
    }

    func openMeetingDetails(for event: EKEvent) {
        guard let meeting = findOrCreateMeeting(for: event) else { return }
        selectedMeeting = meeting
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

    func deleteMeeting(_ meeting: Meeting) throws {
        guard let modelContext else { return }

        if let recordingPath = meeting.recordingFileURL {
            let recordingURL = URL(fileURLWithPath: recordingPath)
            do {
                try removeItemAtURL(recordingURL)
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
                // Missing recording files should not block deleting the meeting record.
            }
        }

        let isSelectedMeeting = sidebarSelection == .meeting(meeting.id)
        bestEffort("remove resumable recording session", Log.recording) {
            try removeResumableRecordingSession(meeting.id)
        }
        modelContext.delete(meeting)

        if isSelectedMeeting {
            sidebarSelection = .dashboard
        }

        try modelContext.save()
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

    func filteredRecentMeetings(from meetings: [Meeting]) -> [Meeting] {
        filteredMeetings(from: meetings, in: .recent)
    }

    func filteredUpcomingMeetings(from meetings: [Meeting]) -> [Meeting] {
        filteredMeetings(from: meetings, in: .upcoming)
    }

    func sidebarSection(for meeting: Meeting, now: Date = Date()) -> SidebarMeetingSection {
        if meeting.status == .upcoming {
            return .upcoming
        }

        if meeting.date > now && meetingHasPrep(meeting) {
            return .upcoming
        }

        return .recent
    }

    private func filteredMeetings(from meetings: [Meeting], in section: SidebarMeetingSection) -> [Meeting] {
        let query = meetingSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filteredMeetings = meetings.filter { sidebarSection(for: $0) == section }

        guard !query.isEmpty else {
            return sortMeetings(filteredMeetings, in: section)
        }

        let queryFiltered = filteredMeetings.filter { meeting in
            meeting.title.localizedCaseInsensitiveContains(query)
        }

        return sortMeetings(queryFiltered, in: section)
    }

    private func sortMeetings(_ meetings: [Meeting], in section: SidebarMeetingSection) -> [Meeting] {
        switch section {
        case .upcoming:
            return meetings.sorted { $0.date < $1.date }
        case .recent:
            return meetings.sorted { $0.date > $1.date }
        }
    }
}
