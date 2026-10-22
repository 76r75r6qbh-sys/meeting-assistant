import CoreAudio
import Foundation
import SwiftData
import XCTest
@testable import Casablanca

// MARK: - Debouncer

final class TeamsCallDebouncerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    func testShortPreJoinBlipNeverStartsACall() {
        var debouncer = TeamsCallDebouncer()
        XCTAssertNil(debouncer.update(isInputActive: true, at: at(0)))
        XCTAssertNil(debouncer.update(isInputActive: true, at: at(4.9)))
        XCTAssertNil(debouncer.update(isInputActive: false, at: at(5.5)))
        XCTAssertNil(debouncer.update(isInputActive: false, at: at(60)))
        XCTAssertFalse(debouncer.isInCall)
    }

    func testFiveSecondsOfContinuousInputStartsTheCallOnce() {
        var debouncer = TeamsCallDebouncer()
        XCTAssertNil(debouncer.update(isInputActive: true, at: at(0)))
        XCTAssertEqual(debouncer.update(isInputActive: true, at: at(5)), .callStarted)
        XCTAssertNil(debouncer.update(isInputActive: true, at: at(10)), "An edge is reported once")
        XCTAssertTrue(debouncer.isInCall)
    }

    func testABreakInInputRestartsTheStartCountdown() {
        var debouncer = TeamsCallDebouncer()
        _ = debouncer.update(isInputActive: true, at: at(0))
        _ = debouncer.update(isInputActive: false, at: at(3))
        XCTAssertNil(debouncer.update(isInputActive: true, at: at(4)))
        XCTAssertNil(debouncer.update(isInputActive: true, at: at(8)), "Only 4 s since the input came back")
        XCTAssertEqual(debouncer.update(isInputActive: true, at: at(9)), .callStarted)
    }

    func testShortDropMidCallDoesNotEndIt() {
        var debouncer = inCall()
        XCTAssertNil(debouncer.update(isInputActive: false, at: at(100)))
        XCTAssertNil(debouncer.update(isInputActive: false, at: at(119)))
        XCTAssertNil(debouncer.update(isInputActive: true, at: at(119.5)), "Hold / device switch: still the same call")
        XCTAssertNil(debouncer.update(isInputActive: false, at: at(130)))
        XCTAssertNil(debouncer.update(isInputActive: false, at: at(149)), "The off-countdown restarted at 130")
        XCTAssertTrue(debouncer.isInCall)
    }

    func testTwentySecondsWithoutInputEndsTheCall() {
        var debouncer = inCall()
        XCTAssertNil(debouncer.update(isInputActive: false, at: at(100)))
        XCTAssertEqual(debouncer.update(isInputActive: false, at: at(120)), .callEnded)
        XCTAssertNil(debouncer.update(isInputActive: false, at: at(200)))
        XCTAssertFalse(debouncer.isInCall)
    }

    func testMutedCallWithOnlyOutputRunningStaysActive() {
        var debouncer = inCall()
        // Muted: Teams may release the microphone, the remote stream plays on.
        for second in stride(from: 100.0, through: 400.0, by: 10) {
            XCTAssertNil(debouncer.update(isInputActive: false, isOutputActive: true, at: at(second)))
        }
        XCTAssertTrue(debouncer.isInCall)
        XCTAssertNil(debouncer.nextDeadline, "Output running: no end pending")
    }

    func testCallEndsOnlyAfterBothInputAndOutputStopFor20Seconds() {
        var debouncer = inCall()
        XCTAssertNil(debouncer.update(isInputActive: false, isOutputActive: true, at: at(100)))
        XCTAssertNil(debouncer.update(isInputActive: false, isOutputActive: false, at: at(110)))
        XCTAssertNil(debouncer.update(isInputActive: false, isOutputActive: true, at: at(125)), "Output resets the countdown")
        XCTAssertNil(debouncer.update(isInputActive: false, isOutputActive: false, at: at(130)))
        XCTAssertNil(debouncer.update(isInputActive: false, isOutputActive: false, at: at(149)))
        XCTAssertEqual(debouncer.update(isInputActive: false, isOutputActive: false, at: at(150)), .callEnded)
    }

    func testOutputWithoutAPriorCallNeverStartsOne() {
        var debouncer = TeamsCallDebouncer()
        // A notification sound or a video in a chat: output only, for minutes.
        for second in stride(from: 0.0, through: 300.0, by: 5) {
            XCTAssertNil(debouncer.update(isInputActive: false, isOutputActive: true, at: at(second)))
        }
        XCTAssertFalse(debouncer.isInCall)
        XCTAssertNil(debouncer.nextDeadline)
    }

    func testNextDeadlineTracksThePendingTransition() {
        var debouncer = TeamsCallDebouncer()
        XCTAssertNil(debouncer.nextDeadline)
        _ = debouncer.update(isInputActive: true, at: at(0))
        XCTAssertEqual(debouncer.nextDeadline, at(5))
        _ = debouncer.update(isInputActive: true, at: at(5))
        XCTAssertNil(debouncer.nextDeadline, "In a call with input running: nothing pending")
        _ = debouncer.update(isInputActive: false, at: at(50))
        XCTAssertEqual(debouncer.nextDeadline, at(70))
    }

    private func inCall() -> TeamsCallDebouncer {
        var debouncer = TeamsCallDebouncer()
        _ = debouncer.update(isInputActive: true, at: at(0))
        XCTAssertEqual(debouncer.update(isInputActive: true, at: at(5)), .callStarted)
        return debouncer
    }
}

// MARK: - Monitor

@MainActor
private final class FakeTeamsAudioActivitySource: TeamsAudioActivitySource {
    var isSupported = true
    var isActive = false
    var isOutputActive = false
    private(set) var isObserving = false

    func isTeamsInputRunning() -> Bool { isActive }
    func isTeamsOutputRunning() -> Bool { isOutputActive }
    func startObserving(onChange: @escaping @MainActor () -> Void) { isObserving = true }
    func stopObserving() { isObserving = false }
}

@MainActor
final class TeamsCallMonitorTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeMonitor(_ source: FakeTeamsAudioActivitySource) -> TeamsCallMonitor {
        TeamsCallMonitor(
            source: source,
            now: { [unowned self] in self.clock },
            // Timers never fire on their own: the test drives `evaluate()`.
            sleep: { _ in try? await Task.sleep(for: .seconds(3600)) }
        )
    }

    func testReportsStartTicksAndEndFromTheSource() {
        let source = FakeTeamsAudioActivitySource()
        let monitor = makeMonitor(source)
        var events: [String] = []
        monitor.onCallStarted = { events.append("start") }
        monitor.onCallTick = { events.append("tick") }
        monitor.onCallEnded = { events.append("end") }

        monitor.start()
        XCTAssertTrue(source.isObserving)

        source.isActive = true
        monitor.evaluate()
        clock += 5
        monitor.evaluate()
        XCTAssertEqual(events, ["start", "tick"])

        source.isActive = false
        monitor.evaluate()
        clock += 20
        monitor.evaluate()
        XCTAssertEqual(events, ["start", "tick", "tick", "end"])
        monitor.stop()
    }

    func testMutedCallKeepsRunningOnOutputAndOutputAloneNeverStartsOne() {
        let source = FakeTeamsAudioActivitySource()
        let monitor = makeMonitor(source)
        var events: [String] = []
        monitor.onCallStarted = { events.append("start") }
        monitor.onCallEnded = { events.append("end") }
        monitor.start()

        // Output-only blip before any call: nothing starts.
        source.isOutputActive = true
        monitor.evaluate()
        clock += 30
        monitor.evaluate()
        XCTAssertEqual(events, [])

        // The call starts on input...
        source.isActive = true
        monitor.evaluate()
        clock += 5
        monitor.evaluate()
        XCTAssertEqual(events, ["start"])

        // ...the user mutes for a minute: input released, output keeps going.
        source.isActive = false
        monitor.evaluate()
        clock += 60
        monitor.evaluate()
        XCTAssertEqual(events, ["start"])
        XCTAssertTrue(monitor.isInCall)

        // Hang up: both stop, and 20 s later the call has ended.
        source.isOutputActive = false
        monitor.evaluate()
        clock += 20
        monitor.evaluate()
        XCTAssertEqual(events, ["start", "end"])
        monitor.stop()
    }

    func testUnsupportedSystemNeverStarts() {
        let source = FakeTeamsAudioActivitySource()
        source.isSupported = false
        let monitor = makeMonitor(source)
        monitor.start()
        XCTAssertFalse(monitor.isRunning)
        XCTAssertFalse(source.isObserving)
    }

    func testStoppingMidCallForgetsTheCallWithoutReportingAnEnd() {
        let source = FakeTeamsAudioActivitySource()
        let monitor = makeMonitor(source)
        var ended = false
        monitor.onCallEnded = { ended = true }
        monitor.start()
        source.isActive = true
        monitor.evaluate()
        clock += 6
        monitor.evaluate()
        XCTAssertTrue(monitor.isInCall)

        monitor.stop()
        XCTAssertFalse(monitor.isInCall)
        XCTAssertFalse(ended)
        XCTAssertFalse(source.isObserving)
    }
}

// MARK: - Policy

final class TeamsAutoRecordPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(
        _ id: String,
        start: TimeInterval,
        end: TimeInterval,
        text: String = ""
    ) -> TeamsCallEventCandidate {
        TeamsCallEventCandidate(
            identifier: id,
            title: id,
            startDate: now.addingTimeInterval(start),
            endDate: now.addingTimeInterval(end),
            searchableText: text
        )
    }

    func testPicksTheEventHappeningNow() {
        let resolved = TeamsAutoRecordPolicy.resolveEvent(
            from: [
                event("earlier", start: -7200, end: -3600),
                event("now", start: -600, end: 1800),
                event("later", start: 3600, end: 7200)
            ],
            now: now
        )
        XCTAssertEqual(resolved?.identifier, "now")
    }

    func testJoiningUpToTenMinutesEarlyStillMatches() {
        XCTAssertEqual(
            TeamsAutoRecordPolicy.resolveEvent(from: [event("soon", start: 540, end: 3600)], now: now)?.identifier,
            "soon"
        )
        XCTAssertNil(
            TeamsAutoRecordPolicy.resolveEvent(from: [event("too-soon", start: 660, end: 3600)], now: now)
        )
    }

    func testEndedEventDoesNotMatch() {
        XCTAssertNil(TeamsAutoRecordPolicy.resolveEvent(from: [event("over", start: -3600, end: 0)], now: now))
    }

    func testTeamsEventWinsOverACloserNonTeamsEvent() {
        let resolved = TeamsAutoRecordPolicy.resolveEvent(
            from: [
                event("focus block", start: 0, end: 3600),
                event("sync", start: -1200, end: 1800, text: "https://teams.microsoft.com/l/meetup-join/abc")
            ],
            now: now
        )
        XCTAssertEqual(resolved?.identifier, "sync")
    }

    func testMicrosoftTeamsLocationCountsAsTeams() {
        XCTAssertTrue(event("x", start: 0, end: 1, text: "Microsoft Teams Meeting").mentionsTeams)
        XCTAssertFalse(event("y", start: 0, end: 1, text: "Room 4.12").mentionsTeams)
    }

    func testAmongEqualsTheNearestStartWins() {
        let resolved = TeamsAutoRecordPolicy.resolveEvent(
            from: [
                event("long-running", start: -3000, end: 3600, text: "Microsoft Teams"),
                event("just-started", start: -120, end: 1800, text: "Microsoft Teams"),
                event("starting-soon", start: 300, end: 1800, text: "Microsoft Teams")
            ],
            now: now
        )
        XCTAssertEqual(resolved?.identifier, "just-started")
    }

    func testNoEventFallsBackToAManualMeeting() {
        let decision = TeamsAutoRecordPolicy.startDecision(
            isEnabled: true,
            isRecordingBusy: false,
            selectedMeetingStatus: nil,
            candidates: [event("tomorrow", start: 86_400, end: 90_000)],
            now: now,
            manualTitle: { _ in "Teams call 14:05" }
        )
        XCTAssertEqual(decision, .recordManual(title: "Teams call 14:05"))
    }

    func testManualTitleNamesTheCall() {
        XCTAssertTrue(TeamsAutoRecordPolicy.manualMeetingTitle(at: now).hasPrefix("Teams call "))
    }

    func testEventFoundIsRecorded() {
        let decision = TeamsAutoRecordPolicy.startDecision(
            isEnabled: true,
            isRecordingBusy: false,
            selectedMeetingStatus: .notesOnly,
            candidates: [event("standup", start: -60, end: 900)],
            now: now
        )
        XCTAssertEqual(decision, .recordEvent(identifier: "standup"))
    }

    func testNeverStartsOverAnActiveRecordingOrWhenOff() {
        let candidates = [event("standup", start: -60, end: 900)]
        for (enabled, busy, selected) in [
            (false, false, MeetingStatus?.none),
            (true, true, nil),
            (true, false, .recording),
            (true, false, .pausedRecording)
        ] {
            let decision = TeamsAutoRecordPolicy.startDecision(
                isEnabled: enabled,
                isRecordingBusy: busy,
                selectedMeetingStatus: selected,
                candidates: candidates,
                now: now
            )
            guard case .skip = decision else {
                return XCTFail("Expected skip for enabled=\(enabled) busy=\(busy) selected=\(String(describing: selected)), got \(decision)")
            }
        }
    }

    func testAlreadyRecordedMeetingIsNotRecordedInto() {
        XCTAssertTrue(TeamsAutoRecordPolicy.canRecordInto(existingStatus: .upcoming))
        XCTAssertTrue(TeamsAutoRecordPolicy.canRecordInto(existingStatus: .notesOnly))
        XCTAssertTrue(TeamsAutoRecordPolicy.canRecordInto(existingStatus: .pausedRecording))
        XCTAssertFalse(TeamsAutoRecordPolicy.canRecordInto(existingStatus: .processing))
        XCTAssertFalse(TeamsAutoRecordPolicy.canRecordInto(existingStatus: .completed))
    }

    func testAutoStopOnlyForTheLinkedRecording() {
        let linked = UUID()
        let other = UUID()
        func stop(_ linkedID: UUID?, active: UUID?, recording: Bool, status: MeetingStatus?, enabled: Bool = true) -> Bool {
            TeamsAutoRecordPolicy.shouldAutoStop(
                linkedMeetingID: linkedID,
                activeMeetingID: active,
                isRecording: recording,
                linkedMeetingStatus: status,
                isStopEnabled: enabled
            )
        }
        XCTAssertTrue(stop(linked, active: linked, recording: true, status: .recording))
        XCTAssertTrue(stop(linked, active: nil, recording: false, status: .pausedRecording), "Paused: finalize")
        XCTAssertFalse(stop(nil, active: other, recording: true, status: nil), "Never linked to a call")
        XCTAssertFalse(stop(linked, active: other, recording: true, status: .completed), "Now recording something else")
        XCTAssertFalse(stop(linked, active: nil, recording: false, status: .processing), "Already stopped")
        XCTAssertFalse(stop(linked, active: linked, recording: true, status: .recording, enabled: false))
    }

    func testMonitorRunsWhenEitherToggleIsOn() {
        XCTAssertFalse(TeamsAutoRecordPolicy.isMonitorNeeded(autoRecordEnabled: false, autoStopEnabled: false))
        XCTAssertTrue(TeamsAutoRecordPolicy.isMonitorNeeded(autoRecordEnabled: true, autoStopEnabled: false))
        XCTAssertTrue(TeamsAutoRecordPolicy.isMonitorNeeded(autoRecordEnabled: false, autoStopEnabled: true))
    }

    func testStopPreferenceDefaultsOnAndRecordPreferenceDefaultsOff() {
        let defaults = TestVaultGuard.makeScratchDefaults()
        XCTAssertFalse(AppPreferences.teamsAutoRecordEnabled(in: defaults))
        XCTAssertTrue(AppPreferences.teamsAutoRecordStopWhenCallEnds(in: defaults))
        defaults.set(false, forKey: AppPreferenceKey.teamsAutoRecordStopWhenCallEnds)
        XCTAssertFalse(AppPreferences.teamsAutoRecordStopWhenCallEnds(in: defaults))
    }
}

// MARK: - Coordinator

@MainActor
private final class FakeTeamsAutoRecordHost: TeamsAutoRecordHost {
    var isRecordingBusy = false
    var isRecording = false
    var activeRecordingMeetingID: UUID?
    var selectedMeetingStatus: MeetingStatus?
    var statuses: [UUID: MeetingStatus] = [:]
    var candidates: [TeamsCallEventCandidate] = []
    var nextStartedMeetingID: UUID? = UUID()

    private(set) var startRequests: [(eventIdentifier: String?, manualTitle: String)] = []
    private(set) var stoppedMeetingIDs: [UUID] = []

    func meetingStatus(id: UUID) -> MeetingStatus? { statuses[id] }
    func teamsCallCandidates() -> [TeamsCallEventCandidate] { candidates }

    func startAutoRecording(eventIdentifier: String?, manualTitle: String) async -> UUID? {
        startRequests.append((eventIdentifier, manualTitle))
        if let id = nextStartedMeetingID {
            startRecording(id)
        }
        return nextStartedMeetingID
    }

    func stopRecordingForEndedCall(meetingID: UUID) async {
        stoppedMeetingIDs.append(meetingID)
        stopRecording(meetingID, status: .processing)
    }

    /// The user (or the monitor) starts capturing `id`.
    func startRecording(_ id: UUID) {
        isRecording = true
        activeRecordingMeetingID = id
        statuses[id] = .recording
    }

    func stopRecording(_ id: UUID, status: MeetingStatus) {
        isRecording = false
        activeRecordingMeetingID = nil
        statuses[id] = status
    }
}

@MainActor
final class TeamsAutoRecordCoordinatorTests: XCTestCase {
    private var host: FakeTeamsAutoRecordHost!
    private var defaults: UserDefaults!
    private var coordinator: TeamsAutoRecordCoordinator!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        host = FakeTeamsAutoRecordHost()
        defaults = TestVaultGuard.makeScratchDefaults()
        coordinator = TeamsAutoRecordCoordinator(host: host, defaults: defaults, now: { [now] in now })
    }

    private func setPreferences(autoRecord: Bool, autoStop: Bool) {
        defaults.set(autoRecord, forKey: AppPreferenceKey.teamsAutoRecordEnabled)
        defaults.set(autoStop, forKey: AppPreferenceKey.teamsAutoRecordStopWhenCallEnds)
    }

    func testAutoRecordStartsTheCalendarEventAndStopsItWhenTheCallEnds() async {
        setPreferences(autoRecord: true, autoStop: true)
        host.candidates = [TeamsCallEventCandidate(
            identifier: "evt-1", title: "Refinement",
            startDate: now.addingTimeInterval(-120), endDate: now.addingTimeInterval(3000),
            searchableText: "Microsoft Teams Meeting"
        )]
        let meetingID = try? XCTUnwrap(host.nextStartedMeetingID)

        await coordinator.callStarted()
        XCTAssertEqual(host.startRequests.map(\.eventIdentifier), ["evt-1"])
        XCTAssertEqual(coordinator.linkedMeetingID, meetingID)

        await coordinator.callEnded()
        XCTAssertEqual(host.stoppedMeetingIDs, [meetingID].compactMap { $0 })
    }

    func testAutoRecordWithoutAnEventRecordsAManualMeeting() async {
        setPreferences(autoRecord: true, autoStop: true)
        await coordinator.callStarted()
        XCTAssertEqual(host.startRequests.count, 1)
        XCTAssertNil(host.startRequests.first?.eventIdentifier)
        XCTAssertTrue(host.startRequests.first?.manualTitle.hasPrefix("Teams call ") == true)
    }

    func testAutoRecordNeverStartsOverAnActiveRecording() async {
        setPreferences(autoRecord: true, autoStop: true)
        host.isRecordingBusy = true
        await coordinator.callStarted()
        XCTAssertTrue(host.startRequests.isEmpty)
    }

    func testFailedAutoStartLinksNothing() async {
        setPreferences(autoRecord: true, autoStop: true)
        host.nextStartedMeetingID = nil
        await coordinator.callStarted()
        XCTAssertNil(coordinator.linkedMeetingID)
        await coordinator.callEnded()
        XCTAssertTrue(host.stoppedMeetingIDs.isEmpty)
    }

    // Manual start while a call is already active -> stops at the call's end.
    func testManualRecordingStartedDuringACallStopsWhenItEnds() async {
        setPreferences(autoRecord: false, autoStop: true)
        await coordinator.callStarted()
        XCTAssertTrue(host.startRequests.isEmpty, "Auto-record is off")

        let manual = UUID()
        host.startRecording(manual)
        coordinator.callTick()

        await coordinator.callEnded()
        XCTAssertEqual(host.stoppedMeetingIDs, [manual])
    }

    // Manual recording, no Teams call ever -> never stopped.
    func testManualRecordingThatNeverOverlappedACallIsNeverStopped() async {
        setPreferences(autoRecord: false, autoStop: true)
        let manual = UUID()
        host.startRecording(manual)
        await coordinator.callEnded()
        XCTAssertTrue(host.stoppedMeetingIDs.isEmpty)

        // A call that came and went before the recording started is not
        // this recording's call either.
        host.stopRecording(manual, status: .completed)
        await coordinator.callStarted()
        await coordinator.callEnded()
        let later = UUID()
        host.startRecording(later)
        await coordinator.callEnded()
        XCTAssertTrue(host.stoppedMeetingIDs.isEmpty)
    }

    // A call starts while a manual recording is running -> stops at its end.
    func testCallStartingMidManualRecordingStopsItAtTheCallsEnd() async {
        setPreferences(autoRecord: true, autoStop: true)
        let manual = UUID()
        host.startRecording(manual)
        host.isRecordingBusy = true

        await coordinator.callStarted()
        XCTAssertTrue(host.startRequests.isEmpty, "Never a second recording over the manual one")
        XCTAssertEqual(coordinator.linkedMeetingID, manual)

        await coordinator.callEnded()
        XCTAssertEqual(host.stoppedMeetingIDs, [manual])
    }

    // Auto-record off + auto-stop on: the stop half works on its own.
    func testAutoStopWorksWithAutoRecordOff() async {
        setPreferences(autoRecord: false, autoStop: true)
        let manual = UUID()
        host.startRecording(manual)
        await coordinator.callStarted()
        await coordinator.callEnded()
        XCTAssertEqual(host.stoppedMeetingIDs, [manual])
    }

    func testPausedLinkedRecordingIsFinalizedWhenTheCallEnds() async {
        setPreferences(autoRecord: false, autoStop: true)
        let manual = UUID()
        host.startRecording(manual)
        await coordinator.callStarted()
        host.stopRecording(manual, status: .pausedRecording)

        await coordinator.callEnded()
        XCTAssertEqual(host.stoppedMeetingIDs, [manual])
    }

    func testAutoStopOffLeavesTheRecordingRunning() async {
        setPreferences(autoRecord: true, autoStop: false)
        await coordinator.callStarted()
        XCTAssertEqual(host.startRequests.count, 1)
        await coordinator.callEnded()
        XCTAssertTrue(host.stoppedMeetingIDs.isEmpty)
        XCTAssertTrue(host.isRecording)
    }

    func testRecordingTheUserAlreadyStoppedIsLeftAlone() async {
        setPreferences(autoRecord: false, autoStop: true)
        let manual = UUID()
        host.startRecording(manual)
        await coordinator.callStarted()
        host.stopRecording(manual, status: .processing)

        await coordinator.callEnded()
        XCTAssertTrue(host.stoppedMeetingIDs.isEmpty)
    }

    func testResetForgetsTheCall() async {
        setPreferences(autoRecord: false, autoStop: true)
        host.startRecording(UUID())
        await coordinator.callStarted()
        coordinator.reset()
        await coordinator.callEnded()
        XCTAssertTrue(host.stoppedMeetingIDs.isEmpty)
    }
}

// MARK: - Recording controller

@MainActor
final class MeetingRecordingControllerTests: XCTestCase {
    func testSecondStartForTheSameMeetingJoinsTheFirstInsteadOfDoublingIt() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        TestVaultGuard.assertTemporary(rootURL, "recording session root")
        let store = RecordingResumeSessionStore(baseDirectoryProvider: { rootURL })
        var sessionsBuilt = 0
        let service = AudioRecordingService(
            sessionStore: store,
            makeRecordingSession: { outputURL, _, _, _, _, _, _ in
                sessionsBuilt += 1
                return SlowStartRecordingSession(outputURL: outputURL)
            },
            makeFinalOutputURL: { _ in rootURL.appendingPathComponent("final.wav") },
            mergeSegments: { _, outputURL in
                try Data("merged".utf8).write(to: outputURL)
                return 1
            }
        )
        let controller = MeetingRecordingController(recordingService: service)
        let meeting = Meeting(title: "Teams call", date: .now, status: .recording)

        async let first = controller.startRecording(for: meeting, save: {})
        // Let the first start reach its suspension inside `session.start()`.
        await Task.yield()
        let second = await controller.startRecording(for: meeting, save: {})
        let firstOutcome = await first

        XCTAssertEqual(second, .alreadyStarting)
        XCTAssertEqual(firstOutcome, .started)
        XCTAssertEqual(sessionsBuilt, 1)
        XCTAssertEqual(meeting.status, .recording)
        XCTAssertFalse(controller.isStartInFlight)
        let third = await controller.startRecording(for: meeting, save: {})
        XCTAssertEqual(third, .alreadyRecording)
        _ = try? await service.stopRecording(for: meeting)
        try? FileManager.default.removeItem(at: rootURL)
    }
}

/// A session whose `start()` suspends for a moment, so a second caller can
/// arrive while the first is still preparing.
private final class SlowStartRecordingSession: RecordingSessionControlling, @unchecked Sendable {
    let outputURL: URL
    let startedAt = Date()
    let hasCapturedFrames = true
    let systemAudioUnavailableError: Error? = nil

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    func start() async throws {
        try await Task.sleep(for: .milliseconds(100))
    }

    func stop() async throws -> RecordingResult {
        try Data("audio".utf8).write(to: outputURL)
        return RecordingResult(outputURL: outputURL, duration: 1)
    }

    func setMicrophoneDevice(_ deviceID: AudioDeviceID) throws {}
    func setSystemAudioEnabled(_ enabled: Bool) {}
}
