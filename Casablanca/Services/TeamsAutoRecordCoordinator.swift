import EventKit
import Foundation

/// A calendar event flattened to what Teams auto-record needs, so the choice of
/// event is testable without EventKit (`EKEvent.eventIdentifier` cannot be set
/// in a test).
struct TeamsCallEventCandidate: Equatable {
    let identifier: String
    let title: String
    let startDate: Date
    let endDate: Date
    /// Location, notes and URL joined: where Outlook puts the join link.
    let searchableText: String

    init(identifier: String, title: String, startDate: Date, endDate: Date, searchableText: String = "") {
        self.identifier = identifier
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.searchableText = searchableText
    }

    init?(event: EKEvent) {
        guard let identifier = event.eventIdentifier, !identifier.isEmpty,
              let startDate = event.startDate, let endDate = event.endDate else { return nil }
        self.init(
            identifier: identifier,
            title: event.title ?? "Untitled Meeting",
            startDate: startDate,
            endDate: endDate,
            searchableText: [event.location, event.notes, event.url?.absoluteString]
                .compactMap { $0 }
                .joined(separator: "\n")
        )
    }

    var mentionsTeams: Bool {
        searchableText.localizedCaseInsensitiveContains("teams.microsoft.com")
            || searchableText.localizedCaseInsensitiveContains("Microsoft Teams")
    }
}

/// The decisions behind Teams auto-record, free of any app state.
enum TeamsAutoRecordPolicy {
    /// Joining a few minutes early still belongs to the meeting.
    static let earlyJoinWindow: TimeInterval = 10 * 60

    enum StartDecision: Equatable {
        case skip(String)
        case recordEvent(identifier: String)
        case recordManual(title: String)
    }

    /// The calendar event a call that starts at `now` belongs to: one running
    /// from `start − 10 min` until its end. Events that mention Teams win over
    /// those that do not; among equals, the start closest to `now`.
    static func resolveEvent(
        from candidates: [TeamsCallEventCandidate],
        now: Date
    ) -> TeamsCallEventCandidate? {
        let live = candidates.filter {
            $0.startDate.addingTimeInterval(-earlyJoinWindow) <= now && now < $0.endDate
        }
        let teams = live.filter(\.mentionsTeams)
        let pool = teams.isEmpty ? live : teams
        return pool.min {
            abs($0.startDate.timeIntervalSince(now)) < abs($1.startDate.timeIntervalSince(now))
        }
    }

    static func startDecision(
        isEnabled: Bool,
        isRecordingBusy: Bool,
        selectedMeetingStatus: MeetingStatus?,
        candidates: [TeamsCallEventCandidate],
        now: Date,
        manualTitle: (Date) -> String = manualMeetingTitle
    ) -> StartDecision {
        guard isEnabled else { return .skip("auto-record is off") }
        guard !isRecordingBusy else { return .skip("a recording is already active") }
        if selectedMeetingStatus == .recording || selectedMeetingStatus == .pausedRecording {
            return .skip("the open meeting is already recording or paused")
        }
        if let event = resolveEvent(from: candidates, now: now) {
            return .recordEvent(identifier: event.identifier)
        }
        return .recordManual(title: manualTitle(now))
    }

    /// Whether the call's end should stop the recording linked to it. A
    /// recording is linked when it was capturing at some point during the call
    /// — started by the monitor, started by hand mid-call, or already running
    /// when the call began. One that never overlapped a call is never linked,
    /// so never stopped. The linked meeting is stopped while it is still
    /// capturing, or finalized if the user paused it; anything else (stopped
    /// already, or the service now capturing another meeting) is left alone.
    static func shouldAutoStop(
        linkedMeetingID: UUID?,
        activeMeetingID: UUID?,
        isRecording: Bool,
        linkedMeetingStatus: MeetingStatus?,
        isStopEnabled: Bool
    ) -> Bool {
        guard isStopEnabled, let linkedMeetingID else { return false }
        if isRecording, activeMeetingID == linkedMeetingID { return true }
        // Paused: nothing captures (`activeMeetingID` is nil), the segments
        // wait on disk, and Stop merges them.
        return linkedMeetingStatus == .pausedRecording && activeMeetingID != linkedMeetingID
    }

    /// The monitor has work while either half of the feature is on.
    static func isMonitorNeeded(autoRecordEnabled: Bool, autoStopEnabled: Bool) -> Bool {
        autoRecordEnabled || autoStopEnabled
    }

    /// Whether the event's existing meeting can take this recording. One that
    /// was already recorded and stopped (`.processing`/`.completed`) cannot:
    /// recording it again — the call dropped and was re-joined after the
    /// auto-stop — would replace its recording and transcript. A paused one
    /// can; starting it resumes the session it already has.
    static func canRecordInto(existingStatus: MeetingStatus) -> Bool {
        switch existingStatus {
        case .upcoming, .notesOnly, .recording, .pausedRecording: return true
        case .processing, .completed: return false
        }
    }

    /// "Teams call 14:05", in the user's locale time format.
    static func manualMeetingTitle(at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return "Teams call \(formatter.string(from: date))"
    }
}

/// What the coordinator needs from the app. `AppModel` implements it; tests
/// pass a fake.
@MainActor
protocol TeamsAutoRecordHost: AnyObject {
    /// Capturing, preparing, or a start already in flight.
    var isRecordingBusy: Bool { get }
    var isRecording: Bool { get }
    var activeRecordingMeetingID: UUID? { get }
    var selectedMeetingStatus: MeetingStatus? { get }
    func meetingStatus(id: UUID) -> MeetingStatus?
    func teamsCallCandidates() -> [TeamsCallEventCandidate]
    /// Starts recording the event's meeting, or a new manual meeting when
    /// `eventIdentifier` is nil. Returns the meeting ID once capture runs,
    /// `nil` when it did not start.
    func startAutoRecording(eventIdentifier: String?, manualTitle: String) async -> UUID?
    /// Stops (or, when paused, finalizes) the meeting's recording through the
    /// normal Stop path, so transcription and summary run as usual.
    func stopRecordingForEndedCall(meetingID: UUID) async
}

/// Glue between `TeamsCallMonitor` and the app: applies `TeamsAutoRecordPolicy`
/// and remembers which recording overlapped the current call — the only one
/// the call's end may stop.
@MainActor
final class TeamsAutoRecordCoordinator {
    private weak var host: TeamsAutoRecordHost?
    private let defaults: UserDefaults
    private let now: () -> Date
    /// The meeting whose recording overlapped the current call. Last one wins:
    /// stopping one recording and starting another mid-call re-links.
    private(set) var linkedMeetingID: UUID?

    init(host: TeamsAutoRecordHost, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.host = host
        self.defaults = defaults
        self.now = now
    }

    func callStarted() async {
        guard let host else { return }
        // A new call supersedes whatever the last one left behind.
        linkedMeetingID = nil

        // Already recording when the call began: that recording is the call's.
        if let active = host.activeRecordingMeetingID {
            link(active, why: "was already recording when the call started")
            return
        }

        let decision = TeamsAutoRecordPolicy.startDecision(
            isEnabled: AppPreferences.teamsAutoRecordEnabled(in: defaults),
            isRecordingBusy: host.isRecordingBusy,
            selectedMeetingStatus: host.selectedMeetingStatus,
            candidates: host.teamsCallCandidates(),
            now: now()
        )
        let started: UUID?
        switch decision {
        case .skip(let reason):
            Log.recording.notice("Teams call started; not auto-recording: \(reason, privacy: .public)")
            return
        case .recordEvent(let identifier):
            Log.recording.notice("Teams call started; recording calendar event \(identifier, privacy: .public)")
            started = await host.startAutoRecording(eventIdentifier: identifier, manualTitle: "")
        case .recordManual(let title):
            Log.recording.notice("Teams call started; no matching calendar event, recording a manual meeting")
            started = await host.startAutoRecording(eventIdentifier: nil, manualTitle: title)
        }
        if let started {
            link(started, why: "auto-started for the call")
        }
    }

    /// Called on every monitor evaluation during a call: ties a recording that
    /// started or resumed mid-call to it.
    func callTick() {
        guard let host, let active = host.activeRecordingMeetingID, active != linkedMeetingID else { return }
        link(active, why: "recording during the call")
    }

    func callEnded() async {
        guard let host else { return }
        let meetingID = linkedMeetingID
        linkedMeetingID = nil
        guard let meetingID, TeamsAutoRecordPolicy.shouldAutoStop(
            linkedMeetingID: meetingID,
            activeMeetingID: host.activeRecordingMeetingID,
            isRecording: host.isRecording,
            linkedMeetingStatus: host.meetingStatus(id: meetingID),
            isStopEnabled: AppPreferences.teamsAutoRecordStopWhenCallEnds(in: defaults)
        ) else {
            Log.recording.notice("Teams call ended; no linked recording to stop (or auto-stop is off)")
            return
        }
        Log.recording.notice("Teams call ended; stopping linked recording \(meetingID.uuidString, privacy: .public)")
        await host.stopRecordingForEndedCall(meetingID: meetingID)
    }

    /// The monitor was switched off: forget the call so a later end cannot
    /// stop anything.
    func reset() {
        linkedMeetingID = nil
    }

    private func link(_ meetingID: UUID, why: String) {
        linkedMeetingID = meetingID
        Log.recording.notice(
            "Teams call linked to meeting \(meetingID.uuidString, privacy: .public): \(why, privacy: .public)"
        )
    }
}
