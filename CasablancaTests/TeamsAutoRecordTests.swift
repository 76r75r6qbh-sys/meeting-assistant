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
        ).decision
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
        ).decision
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
            ).decision
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

    /// A meeting being stopped still reads `.recording` until its merge ends;
    /// it must be treated as `.processing` so the call gets a "(continued)".
    func testMeetingWhoseStopIsInFlightIsNotRecordedInto() {
        XCTAssertFalse(TeamsAutoRecordPolicy.canRecordInto(existingStatus: .recording, isStopInFlight: true))
        XCTAssertFalse(TeamsAutoRecordPolicy.canRecordInto(existingStatus: .pausedRecording, isStopInFlight: true))
        XCTAssertTrue(TeamsAutoRecordPolicy.canRecordInto(existingStatus: .recording, isStopInFlight: false))
    }

    func testRecordingBusyIgnoresACaptureWhoseStopIsInFlight() {
        let active = UUID()
        func busy(recording: Bool = true, preparing: Bool = false, starting: Bool = false, stopping: Set<UUID>) -> Bool {
            TeamsAutoRecordPolicy.isRecordingBusy(
                isRecording: recording, isPreparing: preparing, isStartInFlight: starting,
                activeMeetingID: recording ? active : nil, stoppingMeetingIDs: stopping
            )
        }
        XCTAssertTrue(busy(stopping: []))
        XCTAssertFalse(busy(stopping: [active]))
        XCTAssertFalse(busy(recording: false, stopping: []))
        XCTAssertTrue(busy(preparing: true, stopping: [active]))
        XCTAssertTrue(busy(starting: true, stopping: [active]))
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

// MARK: - Policy: call-name matching

final class TeamsAutoRecordTitleMatchTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(
        _ id: String,
        title: String,
        start: TimeInterval = -300,
        end: TimeInterval = 1800,
        text: String = ""
    ) -> TeamsCallEventCandidate {
        TeamsCallEventCandidate(
            identifier: id,
            title: title,
            startDate: now.addingTimeInterval(start),
            endDate: now.addingTimeInterval(end),
            searchableText: text
        )
    }

    private func resolve(_ candidates: [TeamsCallEventCandidate], callName: String?) -> String? {
        TeamsAutoRecordPolicy.resolveEvent(from: candidates, now: now, callNames: callName.map { [$0] } ?? [])?.identifier
    }

    private func decide(_ candidates: [TeamsCallEventCandidate], callName: String?) -> TeamsAutoRecordPolicy.StartDecision {
        decide(candidates, callNames: callName.map { [$0] } ?? [])
    }

    private func decide(_ candidates: [TeamsCallEventCandidate], callNames: [String]) -> TeamsAutoRecordPolicy.StartDecision {
        plan(candidates, callNames: callNames).decision
    }

    private func plan(_ candidates: [TeamsCallEventCandidate], callNames: [String]) -> TeamsAutoRecordPolicy.StartPlan {
        TeamsAutoRecordPolicy.startDecision(
            isEnabled: true,
            isRecordingBusy: false,
            selectedMeetingStatus: nil,
            candidates: candidates,
            now: now,
            callNames: callNames,
            manualTitle: { _ in "Teams call 14:05" }
        )
    }

    // MARK: Normalization

    func testNormalizationFoldsCaseDiacriticsPunctuationAndWhitespace() {
        XCTAssertEqual(TeamsAutoRecordPolicy.normalizedTitle("  Café   Überleg-sessie!  "), "cafe uberleg sessie")
        XCTAssertEqual(TeamsAutoRecordPolicy.normalizedTitle("Daily AI team 🚀✨"), "daily ai team")
        XCTAssertEqual(TeamsAutoRecordPolicy.normalizedTitle("Sync: Link/Integrations (Q4)"), "sync link integrations q4")
        XCTAssertEqual(TeamsAutoRecordPolicy.normalizedTitle("👍🏽"), "")
    }

    func testNormalizationStripsLeadingTagsRepeatedly() {
        XCTAssertEqual(TeamsAutoRecordPolicy.normalizedTitle("[EXTERN] Partner sync"), "partner sync")
        XCTAssertEqual(TeamsAutoRecordPolicy.normalizedTitle("[External] RE: FW: Partner sync"), "partner sync")
        XCTAssertEqual(TeamsAutoRecordPolicy.normalizedTitle("Canceled: Partner sync"), "partner sync")
        XCTAssertEqual(TeamsAutoRecordPolicy.normalizedTitle("cancelled:Partner sync"), "partner sync")
        XCTAssertEqual(TeamsAutoRecordPolicy.normalizedTitle("Geannuleerd: [EXT] Fwd: Bijgewerkt: Updated: Partner sync"), "partner sync")
        XCTAssertEqual(
            TeamsAutoRecordPolicy.normalizedTitle("Partner sync RE: Q4"), "partner sync re q4",
            "Only leading tags are stripped"
        )
    }

    // MARK: resolveEvent with a call name

    func testTitleMatchesTheOverlappingEventEvenWhenAnotherLiveEventMentionsTeams() {
        let events = [
            event("focus", title: "Daily AI team", start: -1800, end: 1800),
            event("teams", title: "Refinement", start: -120, end: 1800, text: "Microsoft Teams Meeting")
        ]
        XCTAssertEqual(resolve(events, callName: "Daily AI team"), "focus")
        XCTAssertEqual(decide(events, callName: "Daily AI team"), .recordEvent(identifier: "focus"))
    }

    func testNoTitleMatchRecordsAManualMeetingNamedAfterTheCallDespiteALiveTeamsEvent() {
        let events = [event("teams", title: "Refinement", text: "https://teams.microsoft.com/l/meetup-join/x")]
        XCTAssertNil(resolve(events, callName: "Marco Spoor"))
        XCTAssertEqual(decide(events, callName: "Marco Spoor"), .recordManual(title: "Marco Spoor"))
    }

    func testNoTitleMatchWithoutAnyEventStillUsesTheCallName() {
        XCTAssertEqual(
            decide([], callName: "Meeting with Youri Broekhuizen"),
            .recordManual(title: "Meeting with Youri Broekhuizen")
        )
    }

    func testNilCallNameKeepsTodaysTimeBasedBehaviour() {
        let events = [
            event("focus", title: "Daily AI team", start: 0, end: 3600),
            event("teams", title: "Refinement", start: -1200, end: 1800, text: "Microsoft Teams")
        ]
        XCTAssertEqual(resolve(events, callName: nil), "teams")
        XCTAssertEqual(decide(events, callName: nil), .recordEvent(identifier: "teams"))
        XCTAssertEqual(decide([], callName: nil), .recordManual(title: "Teams call 14:05"))
    }

    func testCallNameThatNormalizesToNothingIsTreatedAsNoName() {
        let events = [event("teams", title: "Refinement", text: "Microsoft Teams")]
        XCTAssertEqual(decide(events, callName: " 🎉 "), .recordEvent(identifier: "teams"))
    }

    func testTitleMatchIsCaseDiacriticWhitespaceAndPunctuationInsensitive() {
        let events = [event("e", title: "Café-overleg:  Team Link")]
        XCTAssertEqual(resolve(events, callName: "cafe overleg team link"), "e")
        XCTAssertEqual(resolve(events, callName: "CAFÉ OVERLEG — TEAM LINK 🙂"), "e")
    }

    func testTaggedEventTitlesMatch() {
        XCTAssertEqual(resolve([event("e", title: "[EXTERN] Partner sync")], callName: "Partner sync"), "e")
        XCTAssertEqual(resolve([event("e", title: "RE: Partner sync")], callName: "Partner sync"), "e")
        XCTAssertEqual(resolve([event("e", title: "Canceled: Partner sync")], callName: "Partner sync"), "e")
    }

    func testTitleMatchOnlyConsidersLiveEvents() {
        let events = [
            event("over", title: "Partner sync", start: -7200, end: -3600),
            event("too-early", title: "Partner sync", start: 660, end: 3600)
        ]
        XCTAssertNil(resolve(events, callName: "Partner sync"))
        XCTAssertEqual(decide(events, callName: "Partner sync"), .recordManual(title: "Partner sync"))
    }

    func testAmongSeveralExactMatchesTheClosestStartWins() {
        let events = [
            event("long", title: "Office hours", start: -3000, end: 3600),
            event("recent", title: "Office hours", start: -60, end: 3600)
        ]
        XCTAssertEqual(resolve(events, callName: "Office hours"), "recent")
    }

    func testExactMatchBeatsAPrefixMatch() {
        let events = [
            event("prefix", title: "Daily AI team — Q4", start: -60),
            event("exact", title: "Daily AI team", start: -1500)
        ]
        XCTAssertEqual(resolve(events, callName: "Daily AI team"), "exact")
    }

    // MARK: Guarded prefix

    func testGuardedPrefixAcceptsTwoOrMoreWordsInEitherDirection() {
        XCTAssertEqual(resolve([event("e", title: "Daily AI team — Q4")], callName: "Daily AI team"), "e")
        XCTAssertEqual(resolve([event("e", title: "Daily AI")], callName: "Daily AI team"), "e")
    }

    func testGuardedPrefixRejectsAOneWordShorterSide() {
        XCTAssertNil(resolve([event("e", title: "Daily AI team")], callName: "Daily"))
        XCTAssertNil(resolve([event("e", title: "Daily")], callName: "Daily AI team"))
    }

    func testGuardedPrefixRejectsWholeWordMismatches() {
        XCTAssertNil(resolve([event("e", title: "Daily AI teammates")], callName: "Daily AI team"))
    }

    func testGuardedPrefixRejectsWhenTwoEventsQualify() {
        let events = [
            event("a", title: "Daily AI team — Q4"),
            event("b", title: "Daily AI team retro")
        ]
        XCTAssertNil(resolve(events, callName: "Daily AI team"))
        XCTAssertEqual(decide(events, callName: "Daily AI team"), .recordManual(title: "Daily AI team"))
    }

    // MARK: Which rule decided

    func testMatchEventReportsTheRuleThatDecided() {
        let events = [event("e", title: "Daily AI team — Q4")]
        XCTAssertEqual(
            TeamsAutoRecordPolicy.matchEvent(from: events, now: now, callNames: []),
            .timeBased(events[0])
        )
        XCTAssertEqual(
            TeamsAutoRecordPolicy.matchEvent(from: [], now: now, callNames: []),
            .timeBased(nil)
        )
        XCTAssertEqual(
            TeamsAutoRecordPolicy.matchEvent(from: [event("over", title: "Daily AI team", start: -7200, end: -3600)],
                                             now: now, callNames: []),
            .timeBased(nil),
            "Nothing running and no name: time-based with no event"
        )
        XCTAssertEqual(
            TeamsAutoRecordPolicy.matchEvent(from: events, now: now, callNames: ["Daily AI team — Q4"]),
            .exactTitle(events[0])
        )
        XCTAssertEqual(
            TeamsAutoRecordPolicy.matchEvent(from: events, now: now, callNames: ["Daily AI team"]),
            .titlePrefix(events[0])
        )
        XCTAssertEqual(
            TeamsAutoRecordPolicy.matchEvent(from: events, now: now, callNames: ["Marco Spoor"]),
            .noTitleMatch(callName: "Marco Spoor")
        )
    }

    func testStartPlanCarriesTheMatchItDecidedWith() {
        let events = [event("e", title: "Daily AI team — Q4")]
        let decided = plan(events, callNames: ["Daily AI team"])
        XCTAssertEqual(decided.decision, .recordEvent(identifier: "e"))
        XCTAssertEqual(decided.match, .titlePrefix(events[0]))

        let skipped = TeamsAutoRecordPolicy.startDecision(
            isEnabled: false, isRecordingBusy: false, selectedMeetingStatus: nil,
            candidates: events, now: now, callNames: ["Daily AI team"]
        )
        XCTAssertEqual(skipped.decision, .skip("auto-record is off"))
        XCTAssertNil(skipped.match, "A skipped start computes no match")
    }

    // MARK: Placeholders (Revision 2)

    func testPlaceholderNameDuringALiveTeamsEventRecordsThatEvent() {
        let events = [
            event("partner", title: "Medicore/Prakikon/Levvel", start: -60, end: 3600,
                  text: "https://teams.microsoft.com/l/meetup-join/x")
        ]
        for placeholder in ["Microsoft Teams meeting", "Microsoft Teams-vergadering", "Teams meeting", "Meeting"] {
            XCTAssertEqual(decide(events, callName: placeholder), .recordEvent(identifier: "partner"), placeholder)
            XCTAssertEqual(plan(events, callNames: [placeholder]).match, .timeBased(events[0]), placeholder)
        }
        XCTAssertEqual(
            decide([], callName: "Microsoft Teams meeting"), .recordManual(title: "Teams call 14:05"),
            "Never a manual \"Microsoft Teams meeting\""
        )
    }

    // MARK: Several candidate names (Revision 2)

    func testAnOlderWindowsNameMatchingTheLiveEventBeatsANewerNonMatchingName() {
        let events = [event("daily", title: "Daily AI team", text: "Microsoft Teams")]
        XCTAssertEqual(decide(events, callNames: ["Marco Spoor", "Daily AI team"]), .recordEvent(identifier: "daily"))
        XCTAssertEqual(plan(events, callNames: ["Marco Spoor", "Daily AI team"]).match, .exactTitle(events[0]))
    }

    func testNoNameMatchingUsesTheNewestNameAsTheManualTitle() {
        let events = [event("refinement", title: "Refinement", text: "Microsoft Teams")]
        XCTAssertEqual(
            decide(events, callNames: ["Marco Spoor", "Judith Koetsier"]),
            .recordManual(title: "Marco Spoor")
        )
        XCTAssertEqual(
            plan(events, callNames: ["Marco Spoor", "Judith Koetsier"]).match,
            .noTitleMatch(callName: "Marco Spoor")
        )
    }

    func testAnExactMatchOfAnyNameBeatsAPrefixMatchOfAnEarlierName() {
        let events = [
            event("prefix", title: "Daily AI team — Q4", start: -60),
            event("exact", title: "Partner sync", start: -1500)
        ]
        XCTAssertEqual(decide(events, callNames: ["Daily AI team", "Partner sync"]), .recordEvent(identifier: "exact"))
    }

    func testAmongPrefixMatchesTheFirstNameWins() {
        let events = [
            event("daily", title: "Daily AI team — Q4"),
            event("partner", title: "Partner sync Levvel")
        ]
        XCTAssertEqual(decide(events, callNames: ["Partner sync", "Daily AI team"]), .recordEvent(identifier: "partner"))
    }

    func testUnusableNamesAreSkippedAndDoNotBecomeTheManualTitle() {
        XCTAssertEqual(
            decide([], callNames: ["🎉", "Microsoft Teams meeting", "Marco Spoor"]),
            .recordManual(title: "Marco Spoor")
        )
        let events = [event("teams", title: "Refinement", text: "Microsoft Teams")]
        XCTAssertEqual(decide(events, callNames: ["🎉", "Meeting"]), .recordEvent(identifier: "teams"))
    }

    // MARK: Early join

    func testCallInsideTheEarlyJoinWindowWithAMatchingTitleIsRecordedIntoThatEvent() {
        let events = [
            event("overrun", title: "Refinement", start: -3000, end: 600, text: "Microsoft Teams"),
            event("next", title: "Daily AI team", start: 540, end: 2400, text: "Microsoft Teams")
        ]
        XCTAssertEqual(decide(events, callName: "Daily AI team"), .recordEvent(identifier: "next"))
        XCTAssertEqual(plan(events, callNames: ["Daily AI team"]).match, .exactTitle(events[1]))
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
    var stoppingMeetingIDs: Set<UUID> = []
    /// Awaited inside `startAutoRecording` before capture "runs": a slow start.
    var startDelay: (() async -> Void)?
    /// The Teams call windows' names, newest first; empty when none is readable.
    var callNames: [String] = []
    private(set) var callNameReads = 0

    private(set) var startRequests: [(eventIdentifier: String?, manualTitle: String)] = []
    private(set) var stoppedMeetingIDs: [UUID] = []

    func meetingStatus(id: UUID) -> MeetingStatus? { statuses[id] }
    func isStopInFlight(meetingID: UUID) -> Bool { stoppingMeetingIDs.contains(meetingID) }
    func teamsCallCandidates() -> [TeamsCallEventCandidate] { candidates }

    func teamsCallNames() -> [String] {
        callNameReads += 1
        return callNames
    }

    func startAutoRecording(eventIdentifier: String?, manualTitle: String) async -> UUID? {
        startRequests.append((eventIdentifier, manualTitle))
        if let startDelay { await startDelay() }
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

    // MARK: Call name

    func testCallNameMatchingNoEventNamesTheManualMeeting() async {
        setPreferences(autoRecord: true, autoStop: true)
        host.callNames = ["Marco Spoor"]
        host.candidates = [TeamsCallEventCandidate(
            identifier: "focus", title: "Focus time",
            startDate: now.addingTimeInterval(-600), endDate: now.addingTimeInterval(3000),
            searchableText: "Microsoft Teams Meeting"
        )]

        await coordinator.callStarted()
        XCTAssertEqual(host.callNameReads, 1)
        XCTAssertEqual(host.startRequests.count, 1)
        XCTAssertNil(host.startRequests.first?.eventIdentifier)
        XCTAssertEqual(host.startRequests.first?.manualTitle, "Marco Spoor")
    }

    func testCallNamePicksTheMatchingEventOverATeamsEvent() async {
        setPreferences(autoRecord: true, autoStop: true)
        host.callNames = ["Daily AI team"]
        host.candidates = [
            TeamsCallEventCandidate(
                identifier: "refinement", title: "Refinement",
                startDate: now.addingTimeInterval(-60), endDate: now.addingTimeInterval(3000),
                searchableText: "Microsoft Teams Meeting"
            ),
            TeamsCallEventCandidate(
                identifier: "daily", title: "Daily AI team",
                startDate: now.addingTimeInterval(-1200), endDate: now.addingTimeInterval(600)
            )
        ]

        await coordinator.callStarted()
        XCTAssertEqual(host.startRequests.map(\.eventIdentifier), ["daily"])
    }

    func testAlreadyRecordingNeverReadsTheCallName() async {
        setPreferences(autoRecord: true, autoStop: true)
        host.callNames = ["Marco Spoor"]
        host.startRecording(UUID())
        await coordinator.callStarted()
        XCTAssertEqual(host.callNameReads, 0)
    }

    func testDisabledAutoRecordNeverReadsTheCallName() async {
        setPreferences(autoRecord: false, autoStop: true)
        host.callNames = ["Marco Spoor"]
        await coordinator.callStarted()
        XCTAssertEqual(host.callNameReads, 0)
        XCTAssertTrue(host.startRequests.isEmpty)
    }

    func testBusyRecorderNeverReadsTheCallName() async {
        setPreferences(autoRecord: true, autoStop: true)
        host.callNames = ["Marco Spoor"]
        host.isRecordingBusy = true
        await coordinator.callStarted()
        XCTAssertEqual(host.callNameReads, 0)
        XCTAssertTrue(host.startRequests.isEmpty)
    }

    func testSelectedMeetingRecordingOrPausedNeverReadsTheCallName() async throws {
        for status in [MeetingStatus.recording, .pausedRecording] {
            try await setUp()
            setPreferences(autoRecord: true, autoStop: true)
            host.callNames = ["Marco Spoor"]
            host.selectedMeetingStatus = status
            await coordinator.callStarted()
            XCTAssertEqual(host.callNameReads, 0, "\(status)")
            XCTAssertTrue(host.startRequests.isEmpty, "\(status)")
        }
    }

    func testEmojiOnlyCallNameRecordsATimeNamedManualMeeting() async {
        setPreferences(autoRecord: true, autoStop: true)
        host.callNames = [" 🎉 "]
        await coordinator.callStarted()
        XCTAssertEqual(host.callNameReads, 1)
        XCTAssertEqual(host.startRequests.count, 1)
        XCTAssertNil(host.startRequests.first?.eventIdentifier)
        XCTAssertEqual(host.startRequests.first?.manualTitle, TeamsAutoRecordPolicy.manualMeetingTitle(at: now))
    }

    func testPlaceholderNameDuringALiveTeamsEventRecordsThatEvent() async {
        setPreferences(autoRecord: true, autoStop: true)
        host.callNames = ["Microsoft Teams meeting"]
        host.candidates = [TeamsCallEventCandidate(
            identifier: "partner", title: "Medicore/Prakikon/Levvel",
            startDate: now.addingTimeInterval(-60), endDate: now.addingTimeInterval(3600),
            searchableText: "https://teams.microsoft.com/l/meetup-join/x"
        )]
        await coordinator.callStarted()
        XCTAssertEqual(host.startRequests.map(\.eventIdentifier), ["partner"])
        XCTAssertNotEqual(host.startRequests.first?.manualTitle, "Microsoft Teams meeting")
    }

    func testOlderWindowNameMatchingTheEventIsUsedOverANewerOne() async {
        setPreferences(autoRecord: true, autoStop: true)
        host.callNames = ["Marco Spoor", "Daily AI team"]
        host.candidates = [TeamsCallEventCandidate(
            identifier: "daily", title: "Daily AI team",
            startDate: now.addingTimeInterval(-60), endDate: now.addingTimeInterval(1800)
        )]
        await coordinator.callStarted()
        XCTAssertEqual(host.callNameReads, 1)
        XCTAssertEqual(host.startRequests.map(\.eventIdentifier), ["daily"])
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

    // A call starts while the user's Stop of meeting X is still finalizing:
    // X is not the call's recording; a new one is started and stopped later.
    func testCallStartingWhileTheActiveMeetingIsStoppingRecordsANewMeeting() async throws {
        setPreferences(autoRecord: true, autoStop: true)
        let stopping = UUID()
        host.startRecording(stopping)
        host.stoppingMeetingIDs = [stopping]
        let newMeeting = try XCTUnwrap(host.nextStartedMeetingID)

        await coordinator.callStarted()
        XCTAssertEqual(host.startRequests.count, 1, "The call must get its own recording")
        XCTAssertEqual(coordinator.linkedMeetingID, newMeeting)

        await coordinator.callEnded()
        XCTAssertEqual(host.stoppedMeetingIDs, [newMeeting])
    }

    func testTickNeverLinksAMeetingWhoseStopIsInFlight() async {
        setPreferences(autoRecord: false, autoStop: true)
        await coordinator.callStarted()
        let stopping = UUID()
        host.startRecording(stopping)
        host.stoppingMeetingIDs = [stopping]
        coordinator.callTick()
        XCTAssertNil(coordinator.linkedMeetingID)
    }

    // The start (retries, a permission prompt) outlives the call: the call's
    // end found nothing linked, so the start itself must stop the recording.
    func testStartThatFinishesAfterTheCallEndedIsStopped() async throws {
        setPreferences(autoRecord: true, autoStop: true)
        let gate = TestGate()
        host.startDelay = { await gate.wait() }
        let meetingID = try XCTUnwrap(host.nextStartedMeetingID)

        let starting = Task { await coordinator.callStarted() }
        while host.startRequests.isEmpty { await Task.yield() }
        await coordinator.callEnded()
        XCTAssertTrue(host.stoppedMeetingIDs.isEmpty, "Nothing was capturing yet")

        await gate.open()
        await starting.value
        XCTAssertEqual(host.stoppedMeetingIDs, [meetingID])
        XCTAssertNil(coordinator.linkedMeetingID, "A finished call links nothing")
    }

    func testStartThatFinishesAfterTheCallEndedKeepsRunningWhenAutoStopIsOff() async {
        setPreferences(autoRecord: true, autoStop: false)
        let gate = TestGate()
        host.startDelay = { await gate.wait() }

        let starting = Task { await coordinator.callStarted() }
        while host.startRequests.isEmpty { await Task.yield() }
        await coordinator.callEnded()
        await gate.open()
        await starting.value

        XCTAssertTrue(host.stoppedMeetingIDs.isEmpty)
        XCTAssertTrue(host.isRecording)
        XCTAssertNil(coordinator.linkedMeetingID)
    }
}

/// A one-shot latch for interleaving async steps in tests.
private actor TestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
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

    private struct Harness {
        let rootURL: URL
        let service: AudioRecordingService
        let controller: MeetingRecordingController
        let mergeGate: TestGate
    }

    /// A service whose merge waits on `mergeGate` and whose sessions take
    /// `stopDelay` to finalize.
    private func makeHarness(stopDelay: Duration = .zero) -> Harness {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        TestVaultGuard.assertTemporary(rootURL, "recording session root")
        let store = RecordingResumeSessionStore(baseDirectoryProvider: { rootURL })
        let mergeGate = TestGate()
        let service = AudioRecordingService(
            sessionStore: store,
            makeRecordingSession: { outputURL, _, _, _, _, _, _ in
                SlowStartRecordingSession(outputURL: outputURL, stopDelay: stopDelay)
            },
            makeFinalOutputURL: { meeting in rootURL.appendingPathComponent("\(meeting.id.uuidString).wav") },
            mergeSegments: { _, outputURL in
                await mergeGate.wait()
                try Data("merged".utf8).write(to: outputURL)
                return 1
            }
        )
        let controller = MeetingRecordingController(
            recordingService: service,
            releasePollInterval: .milliseconds(5)
        )
        return Harness(rootURL: rootURL, service: service, controller: controller, mergeGate: mergeGate)
    }

    // Merge phase: a start for the meeting being stopped is refused and must
    // not flip it to `.notesOnly` while its merge runs.
    func testStartForAMeetingWhoseStopIsMergingLeavesItsStatusAlone() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.rootURL) }
        let meeting = Meeting(title: "Refinement", date: .now, status: .recording)
        let firstStart = await harness.controller.startRecording(for: meeting, save: {})
        XCTAssertEqual(firstStart, .started)

        let stopping = Task { try await harness.controller.stopRecording(for: meeting, save: {}) }
        while harness.service.isRecording { await Task.yield() }
        XCTAssertTrue(harness.controller.isStopInFlight(for: meeting.id))

        let outcome = await harness.controller.startRecording(for: meeting, save: {})
        XCTAssertEqual(outcome, .refusedWhileStopping)
        XCTAssertEqual(meeting.status, .recording, "The Stop owns the status")

        await harness.mergeGate.open()
        _ = try await stopping.value
        XCTAssertEqual(meeting.status, .processing)
    }

    // Finalize phase: the "(continued)" meeting's start waits for the stopping
    // capture to release the session instead of failing on it.
    func testStartOfAnotherMeetingWaitsForAStoppingCaptureToRelease() async throws {
        let harness = makeHarness(stopDelay: .milliseconds(150))
        defer { try? FileManager.default.removeItem(at: harness.rootURL) }
        await harness.mergeGate.open()
        let stopped = Meeting(title: "Refinement", date: .now, status: .recording)
        let continued = Meeting(title: "Refinement (continued)", date: .now, status: .recording)
        let firstStart = await harness.controller.startRecording(for: stopped, save: {})
        XCTAssertEqual(firstStart, .started)

        let stopping = Task { try await harness.controller.stopRecording(for: stopped, save: {}) }
        while !harness.controller.isStopInFlight(for: stopped.id) { await Task.yield() }
        XCTAssertTrue(harness.service.isRecording, "Still finalizing the live segment")
        XCTAssertFalse(harness.controller.isBusyForNewRecording, "A stopping capture is not busy")

        let outcome = await harness.controller.startRecording(for: continued, save: {})
        XCTAssertEqual(outcome, .started)
        XCTAssertEqual(continued.status, .recording)
        XCTAssertEqual(harness.service.activeMeetingID, continued.id)
        _ = try await stopping.value
        XCTAssertEqual(stopped.status, .processing)
        _ = try? await harness.controller.stopRecording(for: continued, save: {})
    }

    // Every stop path ends interruption bookkeeping through this hook, once.
    func testSuccessfulStopNotifiesOnceAndAFailedStopDoesNot() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.rootURL) }
        await harness.mergeGate.open()
        var stopped: [UUID] = []
        harness.controller.onMeetingStopped = { stopped.append($0) }
        let meeting = Meeting(title: "Weekly", date: .now, status: .recording)

        _ = await harness.controller.startRecording(for: meeting, save: {})
        _ = try await harness.controller.stopRecording(for: meeting, save: {})
        XCTAssertEqual(stopped, [meeting.id])

        let never = Meeting(title: "Never recorded", date: .now, status: .recording)
        _ = try? await harness.controller.stopRecording(for: never, save: {})
        XCTAssertEqual(stopped, [meeting.id])
    }

    // A failed start reports its own error, not whatever the service held.
    func testFailedStartReportsItsOwnError() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.rootURL) }
        await harness.mergeGate.open()
        harness.service.setErrorMessage("stale error from an earlier recording")
        let running = Meeting(title: "Running", date: .now, status: .recording)
        let other = Meeting(title: "Other", date: .now, status: .recording)
        _ = await harness.controller.startRecording(for: running, save: {})

        let outcome = await harness.controller.startRecording(for: other, save: {})
        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(
            harness.controller.lastStartFailureMessage,
            RecordingError.activeRecordingExists.localizedDescription
        )
        _ = try? await harness.controller.stopRecording(for: running, save: {})
    }
}

/// A session whose `start()` suspends for a moment, so a second caller can
/// arrive while the first is still preparing.
private final class SlowStartRecordingSession: RecordingSessionControlling, @unchecked Sendable {
    let outputURL: URL
    let startedAt = Date()
    let hasCapturedFrames = true
    let systemAudioUnavailableError: Error? = nil
    let stopDelay: Duration

    init(outputURL: URL, stopDelay: Duration = .zero) {
        self.outputURL = outputURL
        self.stopDelay = stopDelay
    }

    func start() async throws {
        try await Task.sleep(for: .milliseconds(100))
    }

    func stop() async throws -> RecordingResult {
        if stopDelay > .zero { try await Task.sleep(for: stopDelay) }
        try Data("audio".utf8).write(to: outputURL)
        return RecordingResult(outputURL: outputURL, duration: 1)
    }

    func setMicrophoneDevice(_ deviceID: AudioDeviceID) throws {}
    func setSystemAudioEnabled(_ enabled: Bool) {}
}
