import XCTest
@testable import Casablanca

@MainActor
final class RecordingInterruptionCoordinatorTests: XCTestCase {
    func testShortLockTriggersPauseAndAutoResume() async {
        let env = makeEnv()
        env.coordinator.bind(meeting: env.meeting)

        env.fireStart(.screenLock, atOffset: 0)
        await env.flush()
        XCTAssertEqual(env.meeting.status, .pausedRecording)

        env.advance(by: 10)
        env.fireEnd(.screenLock, atOffset: 10)
        await env.flush()

        XCTAssertEqual(env.service.calls, [.handleSystemInterrupt(.screenLock), .resume])
        XCTAssertEqual(env.notifier.posted.count, 2)
        XCTAssertEqual(env.meeting.status, .recording)
        XCTAssertGreaterThanOrEqual(env.saveCount, 2)
    }

    func testLongLockSkipsAutoResumeAndStaysPaused() async {
        let env = makeEnv()
        env.coordinator.bind(meeting: env.meeting)

        env.fireStart(.screenLock, atOffset: 0)
        await env.flush()
        env.advance(by: 31)
        env.fireEnd(.screenLock, atOffset: 31)
        await env.flush()

        XCTAssertEqual(env.service.calls, [.handleSystemInterrupt(.screenLock)])
        XCTAssertEqual(env.notifier.posted.count, 1)
        XCTAssertEqual(env.meeting.status, .pausedRecording)
    }

    func testDisplayLostTriggersPauseAndAutoResumesWhenDisplayReturns() async {
        let env = makeEnv()
        env.coordinator.bind(meeting: env.meeting)

        env.fireStart(.displayUnavailable, atOffset: 0)
        await env.flush()
        XCTAssertEqual(env.meeting.status, .pausedRecording)

        env.advance(by: 8)
        env.fireEnd(.displayUnavailable, atOffset: 8)
        await env.flush()

        XCTAssertEqual(env.service.calls, [.handleSystemInterrupt(.displayUnavailable), .resume])
        XCTAssertEqual(env.meeting.status, .recording)
    }

    func testScreenLockPlusDisplayUnavailableResumeOnlyAfterBothEnd() async {
        // The lid-close deadlock guard: closing the lid raises BOTH .screenLock
        // and .displayUnavailable. Resume must wait until both clear, and must
        // not be permanently blocked by either.
        let env = makeEnv()
        env.coordinator.bind(meeting: env.meeting)

        env.fireStart(.screenLock, atOffset: 0)
        env.fireStart(.displayUnavailable, atOffset: 0)
        await env.flush()
        XCTAssertEqual(env.meeting.status, .pausedRecording)

        env.advance(by: 3)
        env.fireEnd(.screenLock, atOffset: 3)
        await env.flush()
        XCTAssertEqual(env.service.calls, [.handleSystemInterrupt(.screenLock)], "Must not resume until display also returns")

        env.advance(by: 1)
        env.fireEnd(.displayUnavailable, atOffset: 4)
        await env.flush()
        XCTAssertEqual(env.service.calls, [.handleSystemInterrupt(.screenLock), .resume])
        XCTAssertEqual(env.meeting.status, .recording)
    }

    func testAudioDeviceLostNeverAutoResumes() async {
        let env = makeEnv()
        env.coordinator.bind(meeting: env.meeting)

        env.fireStart(.audioDeviceLost(deviceID: "USBMic"), atOffset: 0)
        await env.flush()
        env.advance(by: 5)
        env.fireEnd(.audioDeviceLost(deviceID: "USBMic"), atOffset: 5)
        await env.flush()

        XCTAssertEqual(env.service.calls, [.handleSystemInterrupt(.audioDeviceLost(deviceID: "USBMic"))])
    }

    func testStreamFailureNeverAutoResumes() async {
        let env = makeEnv()
        env.coordinator.bind(meeting: env.meeting)

        env.fireStart(.streamFailure(underlyingDescription: "stream not found"), atOffset: 0)
        await env.flush()
        env.advance(by: 1)
        env.fireEnd(.streamFailure(underlyingDescription: "stream not found"), atOffset: 1)
        await env.flush()

        XCTAssertEqual(env.service.calls.count, 1)
        XCTAssertEqual(env.service.calls.first, .handleSystemInterrupt(.streamFailure(underlyingDescription: "stream not found")))
    }

    func testOverlappingReasonsCoalescePauseAndDelayAutoResume() async {
        let env = makeEnv()
        env.coordinator.bind(meeting: env.meeting)

        env.fireStart(.screenLock, atOffset: 0)
        env.fireStart(.systemSleep, atOffset: 1)
        await env.flush()
        XCTAssertEqual(env.service.calls, [.handleSystemInterrupt(.screenLock)])

        env.advance(by: 5)
        env.fireEnd(.screenLock, atOffset: 5)
        await env.flush()
        XCTAssertEqual(env.service.calls, [.handleSystemInterrupt(.screenLock)])

        env.advance(by: 2)
        env.fireEnd(.systemSleep, atOffset: 7)
        await env.flush()
        XCTAssertEqual(env.service.calls, [.handleSystemInterrupt(.screenLock), .resume])
    }

    func testManualStopDuringAutoResumeWindowCancelsResume() async {
        let env = makeEnv()
        env.coordinator.bind(meeting: env.meeting)

        env.fireStart(.screenLock, atOffset: 0)
        await env.flush()
        env.coordinator.notifyMeetingTransitioned(to: .processing)
        env.fireEnd(.screenLock, atOffset: 5)
        await env.flush()

        XCTAssertEqual(env.service.calls, [.handleSystemInterrupt(.screenLock)])
    }

    func testResumeFailureLeavesMeetingPausedAndPostsNotification() async {
        let env = makeEnv()
        env.service.resumeError = NSError(domain: "test", code: 7)
        env.coordinator.bind(meeting: env.meeting)

        env.fireStart(.screenLock, atOffset: 0)
        await env.flush()
        env.advance(by: 5)
        env.fireEnd(.screenLock, atOffset: 5)
        await env.flush()

        XCTAssertEqual(env.service.calls, [.handleSystemInterrupt(.screenLock), .resume])
        XCTAssertEqual(env.notifier.posted.last?.title, "Could not resume recording")
        XCTAssertEqual(env.meeting.status, .pausedRecording)
    }

    func testBindClearsRecentEventsFromPriorMeeting() async {
        let env = makeEnv()
        env.coordinator.bind(meeting: env.meeting)
        env.fireStart(.screenLock, atOffset: 0)
        await env.flush()

        XCTAssertEqual(env.coordinator.recentEvents.count, 1)

        let secondMeeting = Meeting(title: "Different Meeting", date: .now, status: .recording)
        env.coordinator.bind(meeting: secondMeeting)

        XCTAssertTrue(env.coordinator.recentEvents.isEmpty,
                      "Switching meetings must clear stale interruption events")
    }

    func testAutoResumeAfterMeetingSwitchDoesNotMutateNewMeeting() async {
        let env = makeEnv()
        env.coordinator.bind(meeting: env.meeting)

        env.fireStart(.screenLock, atOffset: 0)
        await env.flush()

        let originalStatus = env.meeting.status
        XCTAssertEqual(originalStatus, .pausedRecording)

        // User switches to a different meeting BEFORE the auto-resume window resolves.
        // Use a non-recording initial status so we can detect a buggy mutation to .recording.
        let secondMeeting = Meeting(title: "Different Meeting", date: .now, status: .upcoming)
        env.coordinator.bind(meeting: secondMeeting)

        // Original meeting's auto-resume end fires AFTER the bind. With the bug, this would
        // (a) call resumeRecording for the ORIGINAL meeting (we accept that in v1 since the
        //     resume task was already in-flight at bind time — but here it hasn't been
        //     dispatched yet, so it never even fires) and (b) mutate `secondMeeting.status`.
        env.advance(by: 5)
        env.fireEnd(.screenLock, atOffset: 5)
        await env.flush()

        XCTAssertNotEqual(secondMeeting.status, .recording,
                          "Auto-resume must not mutate a different meeting's status")
    }

    func testResumeMarksCorrectRecordEvenIfNewInterruptionAppended() async {
        let env = makeEnv()
        env.coordinator.bind(meeting: env.meeting)

        // First interruption — short, should auto-resume
        env.fireStart(.screenLock, atOffset: 0)
        await env.flush()
        XCTAssertEqual(env.coordinator.recentEvents.count, 1)

        let firstStartedAt = env.coordinator.recentEvents[0].startedAt

        // The end event triggers the auto-resume Task. Before that Task runs, simulate a
        // brand-new interruption (lock again) which appends to recentEvents.
        env.advance(by: 5)
        env.fireEnd(.screenLock, atOffset: 5)
        env.fireStart(.screenLock, atOffset: 6)

        await env.flush()

        // The first record (startedAt == 0) must be marked auto-resumed; the new one (startedAt == 6) must NOT be.
        let firstRecord = env.coordinator.recentEvents.first { $0.startedAt == firstStartedAt }
        XCTAssertNotNil(firstRecord)
        XCTAssertTrue(firstRecord?.resumedAutomatically == true,
                      "First interruption should be marked resumed")

        let secondRecord = env.coordinator.recentEvents.first {
            $0.startedAt == Date(timeIntervalSince1970: 6)
        }
        XCTAssertNotNil(secondRecord)
        XCTAssertFalse(secondRecord?.resumedAutomatically == true,
                       "Newly-appended interruption must not inherit resumed=true from the prior one")
    }

    private func makeEnv() -> CoordinatorEnv {
        CoordinatorEnv()
    }

    @MainActor
    private final class CoordinatorEnv {
        let service = FakeRecordingService()
        let notifier = FakeNotifier()
        let monitor = FakeMonitor()
        var clock: TimeInterval = 0
        let meeting = Meeting(title: "Weekly Sync", date: .now, status: .recording)
        var saveCount = 0
        var coordinator: RecordingInterruptionCoordinator!

        init() {
            let env = self
            coordinator = RecordingInterruptionCoordinator(
                service: service,
                monitor: monitor,
                notifier: notifier,
                autoResumeWindow: 30,
                now: { Date(timeIntervalSince1970: env.clock) },
                save: { env.saveCount += 1 }
            )
        }

        func bind(meeting: Meeting) { coordinator.bind(meeting: meeting) }

        func advance(by seconds: TimeInterval) { clock += seconds }

        func fireStart(_ reason: RecordingInterruptionReason, atOffset offset: TimeInterval) {
            clock = offset
            monitor.fire(.init(kind: .started, reason: reason, at: Date(timeIntervalSince1970: offset)))
        }

        func fireEnd(_ reason: RecordingInterruptionReason, atOffset offset: TimeInterval) {
            clock = offset
            monitor.fire(.init(kind: .ended, reason: reason, at: Date(timeIntervalSince1970: offset)))
        }

        func flush() async {
            for _ in 0..<10 {
                await Task.yield()
            }
        }
    }

    // Mirrors the real conformer (`AudioRecordingService`), which is `@MainActor`.
    // The coordinator invokes these methods from `Task { @MainActor … }` closures, so
    // without this annotation the recorded-call array would be mutated off the main actor
    // and concurrent interrupts could race on `calls.append` → heap corruption.
    @MainActor
    private final class FakeRecordingService: RecordingInterruptionServicing {
        enum Call: Equatable {
            case handleSystemInterrupt(RecordingInterruptionReason)
            case resume
        }
        var calls: [Call] = []
        var resumeError: Error?

        func handleSystemInterrupt(reason: RecordingInterruptionReason) async {
            calls.append(.handleSystemInterrupt(reason))
        }

        func resumeRecording(for meeting: Meeting) async throws {
            calls.append(.resume)
            if let error = resumeError { throw error }
        }
    }

    private final class FakeNotifier: RecordingInterruptionNotifying {
        struct Post: Equatable {
            let title: String
            let body: String
        }
        var posted: [Post] = []
        func post(title: String, body: String) {
            posted.append(.init(title: title, body: body))
        }
    }

    private final class FakeMonitor: RecordingInterruptionEmitting {
        var onEvent: ((RecordingInterruptionEvent) -> Void)?
        func fire(_ event: RecordingInterruptionEvent) { onEvent?(event) }
    }
}
