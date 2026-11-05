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

    /// How the call was tied to a calendar event (or not), so the coordinator
    /// can log which rule decided.
    enum EventMatch: Equatable {
        /// No usable call name: today's rule (Teams-mention preference,
        /// closest start). The event is nil when nothing is running.
        case timeBased(TeamsCallEventCandidate?)
        /// The call name equals a running event's title once normalized.
        case exactTitle(TeamsCallEventCandidate)
        /// One of the two is a whole-word prefix (≥ 2 words) of the other,
        /// for exactly one running event.
        case titlePrefix(TeamsCallEventCandidate)
        /// The call has a name and no running event matches it.
        case noTitleMatch(callName: String)

        var event: TeamsCallEventCandidate? {
            switch self {
            case .timeBased(let event): return event
            case .exactTitle(let event), .titlePrefix(let event): return event
            case .noTitleMatch: return nil
            }
        }

        /// For the log; never contains the call name or the event title.
        var ruleDescription: String {
            switch self {
            case .timeBased: return "no title, time-based"
            case .exactTitle: return "title matched event (exact)"
            case .titlePrefix: return "title matched event (prefix)"
            case .noTitleMatch: return "title matched no running event"
            }
        }
    }

    /// The calendar event a call that starts at `now` belongs to: one running
    /// from `start − 10 min` until its end.
    ///
    /// Without a call name: events that mention Teams win over those that do
    /// not; among equals, the start closest to `now`. With one (the Teams call
    /// window's title): only a running event whose title matches it, so an
    /// ad-hoc call taken during another calendar item is not filed under it.
    static func resolveEvent(
        from candidates: [TeamsCallEventCandidate],
        now: Date,
        callName: String? = nil
    ) -> TeamsCallEventCandidate? {
        matchEvent(from: candidates, now: now, callName: callName).event
    }

    /// `resolveEvent`, plus which rule decided. See `normalizedTitle` for
    /// what "matches" ignores.
    static func matchEvent(
        from candidates: [TeamsCallEventCandidate],
        now: Date,
        callName: String?
    ) -> EventMatch {
        let live = candidates.filter {
            $0.startDate.addingTimeInterval(-earlyJoinWindow) <= now && now < $0.endDate
        }
        let closestStart: ([TeamsCallEventCandidate]) -> TeamsCallEventCandidate? = { pool in
            pool.min {
                abs($0.startDate.timeIntervalSince(now)) < abs($1.startDate.timeIntervalSince(now))
            }
        }

        // A name that normalizes to nothing (emoji only) says nothing about
        // the meeting: treat it as no name.
        guard let callName else { return .timeBased(timeBasedEvent(live, closestStart)) }
        let name = normalizedTitle(callName)
        guard !name.isEmpty else { return .timeBased(timeBasedEvent(live, closestStart)) }

        // Rule 1: exact normalized equality. A title match beats the Teams
        // mention: the window names the meeting outright.
        let exact = live.filter { normalizedTitle($0.title) == name }
        if let event = closestStart(exact) { return .exactTitle(event) }

        // Rule 2: guarded whole-word prefix, only when unambiguous.
        let nameWords = name.split(separator: " ")
        let prefixed = live.filter { isGuardedPrefixMatch(nameWords, normalizedTitle($0.title).split(separator: " ")) }
        if prefixed.count == 1, let event = prefixed.first { return .titlePrefix(event) }

        return .noTitleMatch(callName: callName)
    }

    private static func timeBasedEvent(
        _ live: [TeamsCallEventCandidate],
        _ closestStart: ([TeamsCallEventCandidate]) -> TeamsCallEventCandidate?
    ) -> TeamsCallEventCandidate? {
        let teams = live.filter(\.mentionsTeams)
        return closestStart(teams.isEmpty ? live : teams)
    }

    /// One word list is a strict whole-word prefix of the other and the shorter
    /// has at least two words, so a one-word "Daily" never swallows "Daily AI
    /// team".
    private static func isGuardedPrefixMatch(_ a: [Substring], _ b: [Substring]) -> Bool {
        let (shorter, longer) = a.count <= b.count ? (a, b) : (b, a)
        guard shorter.count >= 2, shorter.count < longer.count else { return false }
        return Array(longer.prefix(shorter.count)) == shorter
    }

    /// Mail and calendar tags Outlook puts in front of a subject. Matched
    /// case-insensitively and stripped repeatedly, leading only.
    static let leadingTitleTags = [
        "[EXTERN]", "[EXTERNAL]", "[EXT]", "FW:", "FWD:", "RE:",
        "Canceled:", "Cancelled:", "Geannuleerd:", "Updated:", "Bijgewerkt:",
    ]

    /// A title reduced to what identifies the meeting: leading tags stripped,
    /// case and diacritics folded, punctuation and symbols (emoji included)
    /// turned into spaces, whitespace collapsed.
    static func normalizedTitle(_ title: String) -> String {
        var rest = Substring(title)
        stripping: while true {
            rest = rest.drop(while: \.isWhitespace)
            for tag in leadingTitleTags where rest.count >= tag.count
                && rest.prefix(tag.count).caseInsensitiveCompare(tag) == .orderedSame {
                rest = rest.dropFirst(tag.count)
                continue stripping
            }
            break
        }

        let folded = String(rest)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
        var kept = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars {
            kept.append(isTitleWordScalar(scalar) ? scalar : " ")
        }
        return String(kept).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Letters, numbers and the marks that belong to them; everything else
    /// (punctuation, symbols, emoji and their modifiers, joiners, variation
    /// selectors) separates words.
    private static func isTitleWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber:
            return true
        case .nonspacingMark, .spacingMark:
            return !scalar.properties.isVariationSelector && !scalar.properties.isEmojiModifier
        default:
            return false
        }
    }

    static func startDecision(
        isEnabled: Bool,
        isRecordingBusy: Bool,
        selectedMeetingStatus: MeetingStatus?,
        candidates: [TeamsCallEventCandidate],
        now: Date,
        callName: String? = nil,
        manualTitle: (Date) -> String = manualMeetingTitle
    ) -> StartDecision {
        guard isEnabled else { return .skip("auto-record is off") }
        guard !isRecordingBusy else { return .skip("a recording is already active") }
        if selectedMeetingStatus == .recording || selectedMeetingStatus == .pausedRecording {
            return .skip("the open meeting is already recording or paused")
        }
        switch matchEvent(from: candidates, now: now, callName: callName) {
        case .noTitleMatch(let callName):
            return .recordManual(title: callName)
        case let match:
            if let event = match.event { return .recordEvent(identifier: event.identifier) }
            return .recordManual(title: manualTitle(now))
        }
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

    /// Whether a new recording must not start: something is capturing,
    /// preparing or starting. A capture whose Stop is in flight is ignored —
    /// it is going away, and the start waits for it to release the session.
    static func isRecordingBusy(
        isRecording: Bool,
        isPreparing: Bool,
        isStartInFlight: Bool,
        activeMeetingID: UUID?,
        stoppingMeetingIDs: Set<UUID>
    ) -> Bool {
        if isPreparing || isStartInFlight { return true }
        guard isRecording else { return false }
        guard let activeMeetingID else { return true }
        return !stoppingMeetingIDs.contains(activeMeetingID)
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
    ///
    /// A meeting whose Stop is in flight counts as `.processing` even though
    /// its status still reads `.recording`/`.pausedRecording` until the merge
    /// finishes: the user stopped it, and a start into it is refused (and used
    /// to flip it to `.notesOnly` mid-merge), so the call would go unrecorded.
    static func canRecordInto(existingStatus: MeetingStatus, isStopInFlight: Bool = false) -> Bool {
        if isStopInFlight { return false }
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
    /// The user (or an earlier auto-stop) already stopped this meeting and
    /// its finalize/merge is running.
    func isStopInFlight(meetingID: UUID) -> Bool
    func teamsCallCandidates() -> [TeamsCallEventCandidate]
    /// The running Teams call's name from its window title (a person, or the
    /// meeting subject), or nil when no title is readable. Reads the window
    /// server, so the coordinator calls it only when a start can follow.
    func teamsCallName() -> String?
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
    /// Bumped by every call start and end (and `reset`). The monitor's
    /// callbacks each run in their own Task, so `callEnded` can run while
    /// `callStarted` is still awaiting a slow start (retries, a first-run
    /// permission prompt); the start then compares generations to learn that
    /// the call it was started for is over.
    private var callGeneration = 0
    private var isCallLive = false

    init(host: TeamsAutoRecordHost, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.host = host
        self.defaults = defaults
        self.now = now
    }

    func callStarted() async {
        guard let host else { return }
        // A new call supersedes whatever the last one left behind.
        linkedMeetingID = nil
        callGeneration += 1
        isCallLive = true
        let generation = callGeneration

        // Already recording when the call began: that recording is the call's —
        // unless its Stop is already in flight. Linking a meeting the user just
        // stopped left this call unrecorded: its end found the meeting
        // `.processing` and stopped nothing.
        if let active = host.activeRecordingMeetingID, !host.isStopInFlight(meetingID: active) {
            link(active, why: "was already recording when the call started")
            return
        }

        // The call window's title is read only when a start can follow:
        // `startDecision` checks these too, but too late to save the read.
        let isEnabled = AppPreferences.teamsAutoRecordEnabled(in: defaults)
        let isRecordingBusy = host.isRecordingBusy
        let callName = isEnabled && !isRecordingBusy ? host.teamsCallName() : nil
        let candidates = host.teamsCallCandidates()
        let callTime = now()

        let decision = TeamsAutoRecordPolicy.startDecision(
            isEnabled: isEnabled,
            isRecordingBusy: isRecordingBusy,
            selectedMeetingStatus: host.selectedMeetingStatus,
            candidates: candidates,
            now: callTime,
            callName: callName
        )
        if case .skip = decision {} else {
            logCallName(callName, match: TeamsAutoRecordPolicy.matchEvent(from: candidates, now: callTime, callName: callName))
        }
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
        guard let started else { return }
        guard generation != callGeneration else {
            link(started, why: "auto-started for the call")
            return
        }
        await handleStartThatOutlivedItsCall(started)
    }

    /// The start finished after the call it was made for ended. Linking it now
    /// would tie it to no call (or the wrong one) and nothing would stop it.
    private func handleStartThatOutlivedItsCall(_ meetingID: UUID) async {
        guard let host else { return }
        if isCallLive {
            // A newer call is running: the recording overlaps it, so it is
            // that call's (as `callTick` would decide on its next tick).
            if linkedMeetingID == nil {
                link(meetingID, why: "auto-start finished during a later call")
            }
            return
        }
        guard TeamsAutoRecordPolicy.shouldAutoStop(
            linkedMeetingID: meetingID,
            activeMeetingID: host.activeRecordingMeetingID,
            isRecording: host.isRecording,
            linkedMeetingStatus: host.meetingStatus(id: meetingID),
            isStopEnabled: AppPreferences.teamsAutoRecordStopWhenCallEnds(in: defaults)
        ), !host.isStopInFlight(meetingID: meetingID) else {
            Log.recording.notice(
                "Teams auto-start finished after the call ended; leaving meeting \(meetingID.uuidString, privacy: .public) as it is"
            )
            return
        }
        Log.recording.notice(
            "Teams auto-start finished after the call ended; stopping meeting \(meetingID.uuidString, privacy: .public)"
        )
        await host.stopRecordingForEndedCall(meetingID: meetingID)
    }

    /// Called on every monitor evaluation during a call: ties a recording that
    /// started or resumed mid-call to it.
    func callTick() {
        guard let host, let active = host.activeRecordingMeetingID, active != linkedMeetingID,
              !host.isStopInFlight(meetingID: active) else { return }
        link(active, why: "recording during the call")
    }

    func callEnded() async {
        guard let host else { return }
        callGeneration += 1
        isCallLive = false
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
        callGeneration += 1
        isCallLive = false
    }

    /// Whether the call window had a name and which rule picked the meeting.
    /// The name is a person's name or a meeting subject, so it stays private.
    private func logCallName(_ callName: String?, match: TeamsAutoRecordPolicy.EventMatch) {
        if let callName {
            Log.recording.notice(
                "Teams call name found (\(callName, privacy: .private)); \(match.ruleDescription, privacy: .public)"
            )
        } else {
            Log.recording.notice("Teams call name not found; \(match.ruleDescription, privacy: .public)")
        }
    }

    private func link(_ meetingID: UUID, why: String) {
        linkedMeetingID = meetingID
        Log.recording.notice(
            "Teams call linked to meeting \(meetingID.uuidString, privacy: .public): \(why, privacy: .public)"
        )
    }
}
