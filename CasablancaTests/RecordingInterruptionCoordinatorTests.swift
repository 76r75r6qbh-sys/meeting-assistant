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
