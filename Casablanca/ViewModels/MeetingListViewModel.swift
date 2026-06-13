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

    /// Meetings that have been soft-deleted (hidden from the sidebar) but not yet
    /// hard-deleted. During the grace period the meeting is filtered out of the
    /// visible lists; on timeout it is really deleted (file + model), on Undo it
    /// is un-hidden. This indirection lets us offer an "Undo" toast for a
    /// deletion that physically removes the recording file (so NSUndoManager
    /// can't restore it).
    private(set) var pendingDeletionIDs: Set<UUID> = []

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
        findOrCreateMeeting(
            calendarEventID: event.eventIdentifier,
            occurrenceStart: event.startDate ?? Date(),
            title: event.title ?? "Untitled Meeting",
            endDate: event.endDate,
            participants: event.attendees?.compactMap { $0.name } ?? []
        )
    }

    /// EKEvent-free core of ``findOrCreateMeeting(for:)`` so the
    /// occurrence-disambiguation logic is unit-testable (EKEvent's
    /// `eventIdentifier` is read-only and not KVC-settable in tests).
    ///
    /// EventKit's `eventIdentifier` is SHARED across every occurrence of a
    /// recurring event, so `calendarEventID` alone matches the whole series —
    /// matching on it alone would hand back occurrence 1's row when the user
    /// opens occurrence 2, colliding their notes/transcript. We therefore
    /// disambiguate by the occurrence's start date (`Meeting.date`, which stores
    /// the occurrence's `event.startDate`).
    ///
    /// The occurrence start is normalized to whole seconds (via
    /// ``Meeting/normalizedOccurrenceDate(_:)``) at BOTH the `#Predicate` match
    /// AND before storing `meeting.date`, so a created row and a later lookup of
    /// the SAME occurrence agree even if EventKit returns a sub-second-jittered
    /// `startDate` between fetches — otherwise the exact `Date ==` would miss and
    /// create a duplicate. Normalization happens here (not at the callers) so the
    /// invariant holds for every entry point, including the EKEvent overload.
    func findOrCreateMeeting(
        calendarEventID: String?,
        occurrenceStart: Date,
        title: String,
        endDate: Date?,
        participants: [String]
    ) -> Meeting? {
        guard let modelContext else { return nil }

        let eventID = calendarEventID ?? ""
        let normalizedStart = Meeting.normalizedOccurrenceDate(occurrenceStart)
        let descriptor = FetchDescriptor<Meeting>(
            predicate: #Predicate { meeting in
                meeting.calendarEventID == eventID && meeting.date == normalizedStart
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
            title: title,
            date: normalizedStart,
            endDate: endDate,
            calendarEventID: calendarEventID,
            participants: participants
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

    // MARK: - Soft-delete (undoable) state machine

    /// True when `id` is currently hidden pending a real deletion.
    func isPendingDeletion(_ id: UUID) -> Bool {
        pendingDeletionIDs.contains(id)
    }

    /// Marks a meeting as soft-deleted: it's immediately hidden from the sidebar
    /// (via `visibleMeetings(from:)`) but NOT yet removed from disk/model. If it
    /// was the selected meeting, navigation falls back to the dashboard so the
    /// detail pane doesn't show a now-hidden meeting.
    func beginSoftDelete(_ id: UUID) {
        pendingDeletionIDs.insert(id)
        if sidebarSelection == .meeting(id) {
            sidebarSelection = .dashboard
        }
    }

    /// Cancels a pending soft-delete (the user tapped Undo). The meeting becomes
    /// visible again. Returns true if `id` was actually pending.
    @discardableResult
    func undoSoftDelete(_ id: UUID) -> Bool {
        pendingDeletionIDs.remove(id) != nil
    }

    /// Commits a pending soft-delete by performing the real hard delete (file +
    /// model). No-ops if the id is no longer pending (e.g. the user already
    /// undid it). Returns true if a hard delete was performed.
    @discardableResult
    func commitSoftDelete(_ meeting: Meeting) throws -> Bool {
        guard pendingDeletionIDs.contains(meeting.id) else { return false }
        pendingDeletionIDs.remove(meeting.id)
        try deleteMeeting(meeting)
        return true
    }

    /// Filters out meetings that are pending soft-deletion, so the sidebar hides
    /// them during the undo grace period.
    func visibleMeetings(from meetings: [Meeting]) -> [Meeting] {
        guard !pendingDeletionIDs.isEmpty else { return meetings }
        return meetings.filter { !pendingDeletionIDs.contains($0.id) }
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
        // Hide soft-deleted meetings during their undo grace period.
        let visible = visibleMeetings(from: meetings)
        let filteredMeetings = visible.filter { sidebarSection(for: $0) == section }

        guard !query.isEmpty else {
            return sortMeetings(filteredMeetings, in: section)
        }

        let queryFiltered = filteredMeetings.filter { meeting in
            // Use `localizedStandardContains` to match the DB-side title
            // predicate in `SidebarMeetingsProvider` exactly (case- AND
            // diacritic-insensitive), so the Swift residual filter and the
            // SQLite fetch agree on what "matches".
            meeting.title.localizedStandardContains(query)
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
