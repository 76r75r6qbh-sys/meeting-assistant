import XCTest
@testable import Casablanca

@MainActor
final class RecordingInterruptionMonitorTests: XCTestCase {
    /// `screensDidSleep` is an idle DISPLAY sleep — the lid is open and the user
    /// simply isn't touching the Mac. With the recording's power assertion in
    /// place the screen going dark is harmless to microphone and system-audio
    /// capture, so it must not pause anything.
    func testScreensDidSleepProducesNoEvent() async {
        let center = NotificationCenter()
        let monitor = RecordingInterruptionMonitor(
            workspaceNotificationCenter: center,
            distributedNotificationCenter: NotificationCenter(),
            deviceListProvider: { [] },
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        monitor.start()

        var events: [RecordingInterruptionEvent] = []
        monitor.onEvent = { events.append($0) }

        center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)

        XCTAssertTrue(events.isEmpty, "An idle display sleep must not interrupt the recording")
    }

    func testScreensDidWakeProducesNoEvent() async {
        let center = NotificationCenter()
        let monitor = RecordingInterruptionMonitor(
            workspaceNotificationCenter: center,
            distributedNotificationCenter: NotificationCenter(),
            deviceListProvider: { [] },
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        monitor.start()

        var events: [RecordingInterruptionEvent] = []
        monitor.onEvent = { events.append($0) }

        center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)

        XCTAssertTrue(events.isEmpty, "Nothing was interrupted by the display sleep, so nothing ends on wake")
    }

    /// The REAL session lock (Ctrl-Cmd-Q, or the lock screen that follows an
    /// idle display sleep) arrives as `com.apple.screenIsLocked` on the
    /// distributed center. It is reported, so a later hook can key off it, but
    /// it must not pause: the recording holds a power assertion and capture
    /// keeps running behind the lock screen.
    func testDistributedScreenIsLockedIsReportedButDoesNotPause() async {
        let distributed = NotificationCenter()
        let monitor = RecordingInterruptionMonitor(
            workspaceNotificationCenter: NotificationCenter(),
            distributedNotificationCenter: distributed,
            deviceListProvider: { [] },
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        monitor.start()

        var events: [RecordingInterruptionEvent] = []
        var lockChanges: [Bool] = []
        monitor.onEvent = { events.append($0) }
        monitor.onSessionLockChanged = { lockChanges.append($0) }

        distributed.post(name: Notification.Name("com.apple.screenIsLocked"), object: nil)

        XCTAssertEqual(lockChanges, [true])
        XCTAssertTrue(monitor.isSessionLocked)

        distributed.post(name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)

        XCTAssertEqual(lockChanges, [true, false])
        XCTAssertFalse(monitor.isSessionLocked)
        XCTAssertTrue(events.isEmpty, "A session lock must not interrupt the recording")
    }

    /// The distributed center is cross-process (`distnoted`), and the only
    /// production construction is a SwiftUI `@State` initializer expression that
    /// re-runs on every app-model change. Registering in `init` would therefore
    /// cost a register plus unregister per thrown-away view value, so the
    /// observers wait for the idempotent `start()` -- called once, from `.task`.
    func testSessionLockObserversWaitForStartAndRegisterOnlyOnce() async {
        let distributed = NotificationCenter()
        let monitor = RecordingInterruptionMonitor(
            workspaceNotificationCenter: NotificationCenter(),
            distributedNotificationCenter: distributed,
            deviceListProvider: { [] },
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        var lockChanges: [Bool] = []
        monitor.onSessionLockChanged = { lockChanges.append($0) }

        distributed.post(name: Notification.Name("com.apple.screenIsLocked"), object: nil)

        XCTAssertTrue(lockChanges.isEmpty, "Nothing may be registered on the distributed center before start()")
        XCTAssertFalse(monitor.isSessionLocked)

        monitor.start()
        monitor.start()
        distributed.post(name: Notification.Name("com.apple.screenIsLocked"), object: nil)

        XCTAssertEqual(lockChanges, [true], "A repeated start() must not register a second observer")
    }

    func testSleepAndWakeProduceSystemSleepEvents() async {
        let center = NotificationCenter()
        let monitor = RecordingInterruptionMonitor(
            workspaceNotificationCenter: center,
            distributedNotificationCenter: NotificationCenter(),
            deviceListProvider: { [] },
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        var events: [RecordingInterruptionEvent] = []
        monitor.onEvent = { events.append($0) }

        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)

        XCTAssertEqual(events.map(\.reason), [.systemSleep, .systemSleep])
        XCTAssertEqual(events.map(\.kind), [.started, .ended])
    }

    func testActiveDeviceRemovedProducesAudioDeviceLost() async {
        let center = NotificationCenter()
        var devices: [String] = ["BuiltInMic", "USBMic"]
        let monitor = RecordingInterruptionMonitor(
            workspaceNotificationCenter: center,
            distributedNotificationCenter: NotificationCenter(),
            deviceListProvider: { devices },
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        monitor.setActiveInputDevice("USBMic")

        var events: [RecordingInterruptionEvent] = []
        monitor.onEvent = { events.append($0) }

        devices = ["BuiltInMic"]
        monitor.deviceListChanged()

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.reason, .audioDeviceLost(deviceID: "USBMic"))
    }

    func testDeviceRemovedThatIsNotActiveProducesNoEvent() async {
        let center = NotificationCenter()
        var devices: [String] = ["BuiltInMic", "USBMic"]
        let monitor = RecordingInterruptionMonitor(
            workspaceNotificationCenter: center,
            distributedNotificationCenter: NotificationCenter(),
            deviceListProvider: { devices },
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        monitor.setActiveInputDevice("BuiltInMic")

        var events: [RecordingInterruptionEvent] = []
        monitor.onEvent = { events.append($0) }

        devices = ["BuiltInMic"]
        monitor.deviceListChanged()

        XCTAssertTrue(events.isEmpty)
    }

    func testDisplayLostWhileRecordingProducesDisplayUnavailableStart() async {
        var displays: [CGDirectDisplayID] = [1]
        let monitor = RecordingInterruptionMonitor(
            workspaceNotificationCenter: NotificationCenter(),
            screenNotificationCenter: NotificationCenter(),
            distributedNotificationCenter: NotificationCenter(),
            deviceListProvider: { [] },
            displayListProvider: { displays },
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        monitor.setActiveInputDevice("BuiltInMic") // recording

        var events: [RecordingInterruptionEvent] = []
        monitor.onEvent = { events.append($0) }

        displays = []
        monitor.reportDisplayConfigurationChanged()

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, .started)
        XCTAssertEqual(events.first?.reason, .displayUnavailable)
    }

    func testDisplayReturnsProducesDisplayUnavailableEnd() async {
        var displays: [CGDirectDisplayID] = []
        let monitor = RecordingInterruptionMonitor(
            workspaceNotificationCenter: NotificationCenter(),
            screenNotificationCenter: NotificationCenter(),
            distributedNotificationCenter: NotificationCenter(),
            deviceListProvider: { [] },
            displayListProvider: { displays },
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        monitor.setActiveInputDevice("BuiltInMic")

        var events: [RecordingInterruptionEvent] = []
        monitor.onEvent = { events.append($0) }

        monitor.reportDisplayConfigurationChanged() // no display -> started
        displays = [1]
        monitor.reportDisplayConfigurationChanged() // display back -> ended

        XCTAssertEqual(events.map(\.kind), [.started, .ended])
        XCTAssertEqual(events.map(\.reason), [.displayUnavailable, .displayUnavailable])
    }

    func testWakeReEvaluatesDisplaySoDisplayUnavailableEndsEvenWithoutScreenParamsEvent() async {
        let workspace = NotificationCenter()
        var displays: [CGDirectDisplayID] = []
        let monitor = RecordingInterruptionMonitor(
            workspaceNotificationCenter: workspace,
            screenNotificationCenter: NotificationCenter(),
            distributedNotificationCenter: NotificationCenter(),
            deviceListProvider: { [] },
            displayListProvider: { displays },
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        monitor.setActiveInputDevice("BuiltInMic")

        var events: [RecordingInterruptionEvent] = []
        monitor.onEvent = { events.append($0) }

        // Display lost while recording -> displayUnavailable started.
        monitor.reportDisplayConfigurationChanged()

        // Lid reopens: the system wake notification fires and a display is back,
        // but assume didChangeScreenParameters did NOT re-fire (the deadlock case).
        displays = [1]
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)

        XCTAssertTrue(
            events.contains { $0.kind == .ended && $0.reason == .displayUnavailable },
            "Wake must re-evaluate display and end displayUnavailable, else auto-resume deadlocks"
        )
    }

    func testDisplayLostWhileNotRecordingProducesNoEvent() async {
        var displays: [CGDirectDisplayID] = [1]
        let monitor = RecordingInterruptionMonitor(
            workspaceNotificationCenter: NotificationCenter(),
            screenNotificationCenter: NotificationCenter(),
            distributedNotificationCenter: NotificationCenter(),
            deviceListProvider: { [] },
            displayListProvider: { displays },
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        // No setActiveInputDevice -> not recording.

        var events: [RecordingInterruptionEvent] = []
        monitor.onEvent = { events.append($0) }

        displays = []
        monitor.reportDisplayConfigurationChanged()

        XCTAssertTrue(events.isEmpty, "Display changes must not pause a meeting that isn't recording")
    }

    // MARK: - IOKit sleep deferral

    func testSystemWillSleepEmitsEventWithCompletionThatAllowsPowerChange() async {
        let gate = FakeSleepGate()
        let monitor = RecordingInterruptionMonitor(
            workspaceNotificationCenter: NotificationCenter(),
            distributedNotificationCenter: NotificationCenter(),
            deviceListProvider: { [] },
            now: { Date(timeIntervalSince1970: 1_000) },
            sleepGate: gate
        )
        monitor.start()

        var events: [RecordingInterruptionEvent] = []
        monitor.onEvent = { events.append($0) }

        gate.send(.willSleep(notificationID: 42))

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, .started)
        XCTAssertEqual(events.first?.reason, .systemSleep)
        XCTAssertEqual(gate.allowed, [], "The power change must be held until the finalize is done")

        events.first?.completion?()
        XCTAssertEqual(gate.allowed, [42], "Running the completion must release the deferral")

        events.first?.completion?()
        XCTAssertEqual(gate.allowed, [42], "The deferral must be released exactly once")
    }

    func testSleepDeferralSafetyTimerAllowsPowerChangeWhenCompletionNeverRuns() async {
        let gate = FakeSleepGate()
        let allowed = expectation(description: "safety timer allows the power change")
        gate.onAllow = { _ in allowed.fulfill() }
        let monitor = RecordingInterruptionMonitor(
            workspaceNotificationCenter: NotificationCenter(),
            distributedNotificationCenter: NotificationCenter(),
            deviceListProvider: { [] },
            now: { Date(timeIntervalSince1970: 1_000) },
            sleepGate: gate,
            sleepDeferralTimeout: 0.05
        )
        monitor.start()
        monitor.onEvent = { _ in } // the completion is deliberately never run

        gate.send(.willSleep(notificationID: 7))

        await fulfillment(of: [allowed], timeout: 5)
        XCTAssertEqual(gate.allowed, [7])
    }

    func testCanSystemSleepIsAllowedImmediatelyAndEmitsNoEvent() async {
        let gate = FakeSleepGate()
        let monitor = RecordingInterruptionMonitor(
            workspaceNotificationCenter: NotificationCenter(),
            distributedNotificationCenter: NotificationCenter(),
            deviceListProvider: { [] },
            now: { Date(timeIntervalSince1970: 1_000) },
            sleepGate: gate
        )
        monitor.start()

        var events: [RecordingInterruptionEvent] = []
        monitor.onEvent = { events.append($0) }

        gate.send(.canSystemSleep(notificationID: 3))

        XCTAssertEqual(gate.allowed, [3], "Idle sleep is prevented by the power assertion, never vetoed here")
        XCTAssertTrue(events.isEmpty)
    }

    func testPoweredOnEndsSystemSleepInterruption() async {
        let gate = FakeSleepGate()
        let monitor = RecordingInterruptionMonitor(
            workspaceNotificationCenter: NotificationCenter(),
            distributedNotificationCenter: NotificationCenter(),
            deviceListProvider: { [] },
            now: { Date(timeIntervalSince1970: 1_000) },
            sleepGate: gate
        )
        monitor.start()

        var events: [RecordingInterruptionEvent] = []
        monitor.onEvent = { events.append($0) }

        gate.send(.willSleep(notificationID: 9))
        gate.send(.hasPoweredOn(notificationID: 9))

        XCTAssertEqual(events.map(\.kind), [.started, .ended])
        XCTAssertEqual(events.map(\.reason), [.systemSleep, .systemSleep])
    }

    /// Both paths observe the same sleep. If the undeferrable NSWorkspace
    /// notification won, the coordinator would get a completion-less event and
    /// only the safety timer could let the Mac sleep — so while the IOKit gate
    /// is live it owns the `.systemSleep` start.
    func testWorkspaceWillSleepIsSuppressedWhileTheIOKitGateIsLive() async {
        let workspace = NotificationCenter()
        let gate = FakeSleepGate()
        let monitor = RecordingInterruptionMonitor(
            workspaceNotificationCenter: workspace,
            distributedNotificationCenter: NotificationCenter(),
            deviceListProvider: { [] },
            now: { Date(timeIntervalSince1970: 1_000) },
            sleepGate: gate
        )
        monitor.start()

        var events: [RecordingInterruptionEvent] = []
        monitor.onEvent = { events.append($0) }

        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertTrue(events.isEmpty, "The IOKit path must be the one that emits, so the completion is not lost")

        gate.send(.willSleep(notificationID: 5))
        XCTAssertEqual(events.count, 1)
        XCTAssertNotNil(events.first?.completion)
    }

    /// If `IORegisterForSystemPower` fails there is no deferral to hand out, so
    /// the NSWorkspace fallback must still pause the recording.
    func testWorkspaceWillSleepStillEmitsWhenTheGateFailedToRegister() async {
        let workspace = NotificationCenter()
        let gate = FakeSleepGate()
        gate.startSucceeds = false
        let monitor = RecordingInterruptionMonitor(
            workspaceNotificationCenter: workspace,
            distributedNotificationCenter: NotificationCenter(),
            deviceListProvider: { [] },
            now: { Date(timeIntervalSince1970: 1_000) },
            sleepGate: gate
        )
        monitor.start()

        var events: [RecordingInterruptionEvent] = []
        monitor.onEvent = { events.append($0) }

        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.reason, .systemSleep)
        XCTAssertNil(events.first?.completion, "There is nothing to release without a registration")
    }

    /// If the kernel slept on its own timeout, the deferral it was holding is
    /// gone by the time we wake — answering it then is meaningless, and the
    /// safety timer must not fire after the fact.
    func testWakeWithAPendingDeferralDropsItInsteadOfAllowingLate() async {
        let gate = FakeSleepGate()
        let monitor = RecordingInterruptionMonitor(
            workspaceNotificationCenter: NotificationCenter(),
            distributedNotificationCenter: NotificationCenter(),
            deviceListProvider: { [] },
            now: { Date(timeIntervalSince1970: 1_000) },
            sleepGate: gate,
            sleepDeferralTimeout: 0.05
        )
        monitor.start()

        var events: [RecordingInterruptionEvent] = []
        monitor.onEvent = { events.append($0) }

        gate.send(.willSleep(notificationID: 11))
        gate.send(.hasPoweredOn(notificationID: 11))

        // Well past the safety timeout.
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(gate.allowed, [], "A deferral the kernel abandoned must not be answered after the wake")
        XCTAssertEqual(events.map(\.kind), [.started, .ended])

        events.first?.completion?()
        XCTAssertEqual(gate.allowed, [], "A late finalize completion has nothing left to release")
    }

    /// `ContentView`'s `@State` initializer expression runs on every view value
    /// SwiftUI builds, so registering in `init` meant one
    /// `IORegisterForSystemPower` per rebuild. Registration lives in `start()`
    /// now, and calling it twice must not register twice.
    func testStartRegistersOnceEvenWhenCalledRepeatedly() async {
        let gate = FakeSleepGate()
        let monitor = RecordingInterruptionMonitor(
            workspaceNotificationCenter: NotificationCenter(),
            distributedNotificationCenter: NotificationCenter(),
            deviceListProvider: { [] },
            now: { Date(timeIntervalSince1970: 1_000) },
            sleepGate: gate
        )

        XCTAssertEqual(gate.registerCount, 0, "init must not register; ContentView rebuilds it constantly")

        monitor.start()
        monitor.start()
        monitor.start()

        XCTAssertEqual(gate.registerCount, 1)
    }

    /// The suppression above must not become a silent hole: if the IOKit
    /// will-sleep never arrives, the recording still has to be paused.
    func testWorkspaceWillSleepFallbackPausesWhenNoIOKitMessageArrives() async {
        let workspace = NotificationCenter()
        let gate = FakeSleepGate()
        let monitor = RecordingInterruptionMonitor(
            workspaceNotificationCenter: workspace,
            distributedNotificationCenter: NotificationCenter(),
            deviceListProvider: { [] },
            now: { Date(timeIntervalSince1970: 1_000) },
            sleepGate: gate,
            willSleepFallbackGrace: 0.05
        )
        monitor.start()

        var events: [RecordingInterruptionEvent] = []
        let paused = expectation(description: "fallback pauses the recording")
        monitor.onEvent = {
            events.append($0)
            paused.fulfill()
        }

        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertTrue(events.isEmpty, "The IOKit message gets the grace period first")

        await fulfillment(of: [paused], timeout: 5)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, .started)
        XCTAssertEqual(events.first?.reason, .systemSleep)
        XCTAssertNil(events.first?.completion, "NSWorkspace's sleep cannot be deferred, so there is nothing to release")
    }

    /// The normal case: both sources fire, and the IOKit one -- the only one
    /// carrying a deferral -- is the single event the coordinator sees.
    func testIOKitWillSleepInsideGracePeriodWinsAndEmitsOnce() async {
        let workspace = NotificationCenter()
        let gate = FakeSleepGate()
        let monitor = RecordingInterruptionMonitor(
            workspaceNotificationCenter: workspace,
            distributedNotificationCenter: NotificationCenter(),
            deviceListProvider: { [] },
            now: { Date(timeIntervalSince1970: 1_000) },
            sleepGate: gate,
            willSleepFallbackGrace: 0.05
        )
        monitor.start()

        var events: [RecordingInterruptionEvent] = []
        monitor.onEvent = { events.append($0) }

        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        gate.send(.willSleep(notificationID: 21))

        // Well past the grace period: the fallback must have been cancelled.
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(events.count, 1)
        XCTAssertNotNil(events.first?.completion, "The event the coordinator gets must carry the deferral")
    }

    /// If the Mac sleeps before the grace period elapses, the timer resumes on
    /// wake -- where a `.started` would strand the meeting paused with nothing
    /// left to end it.
    func testWakeCancelsAPendingWillSleepFallback() async {
        let workspace = NotificationCenter()
        let gate = FakeSleepGate()
        let monitor = RecordingInterruptionMonitor(
            workspaceNotificationCenter: workspace,
            distributedNotificationCenter: NotificationCenter(),
            deviceListProvider: { [] },
            displayListProvider: { [1] },
            now: { Date(timeIntervalSince1970: 1_000) },
            sleepGate: gate,
            willSleepFallbackGrace: 0.05
        )
        monitor.start()

        var events: [RecordingInterruptionEvent] = []
        monitor.onEvent = { events.append($0) }

        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)

        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertTrue(events.isEmpty, "A wake settles the sleep; the fallback must not fire afterwards")
    }

    /// The real gate is only ever built in production; every test drives this.
    private final class FakeSleepGate: SystemSleepGating {
        var allowed: [Int] = []
        var startSucceeds = true
        var onAllow: ((Int) -> Void)?
        /// How many times the monitor asked to register.
        var registerCount = 0
        private var handler: (@MainActor (SystemSleepGateMessage) -> Void)?

        func start(onMessage: @escaping @MainActor (SystemSleepGateMessage) -> Void) -> Bool {
            registerCount += 1
            guard startSucceeds else { return false }
            handler = onMessage
            return true
        }

        func allowPowerChange(notificationID: Int) {
            allowed.append(notificationID)
            onAllow?(notificationID)
        }

        func stop() { handler = nil }

        /// The real gate delivers on the main queue; every test is `@MainActor`,
        /// so match that isolation rather than assuming into it.
        @MainActor
        func send(_ message: SystemSleepGateMessage) {
            handler?(message)
        }
    }

    func testStreamFailureWhileSystemReasonActiveIsSwallowed() async {
        let center = NotificationCenter()
        let monitor = RecordingInterruptionMonitor(
            workspaceNotificationCenter: center,
            distributedNotificationCenter: NotificationCenter(),
            deviceListProvider: { [] },
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        var events: [RecordingInterruptionEvent] = []
        monitor.onEvent = { events.append($0) }

        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        monitor.reportStreamFailure(NSError(domain: "test", code: 1))

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.reason, .systemSleep)
    }

    func testStreamFailureWithoutActiveSystemReasonProducesStreamFailureEvent() async {
        let center = NotificationCenter()
        let monitor = RecordingInterruptionMonitor(
            workspaceNotificationCenter: center,
            distributedNotificationCenter: NotificationCenter(),
            deviceListProvider: { [] },
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        var events: [RecordingInterruptionEvent] = []
        monitor.onEvent = { events.append($0) }

        let error = NSError(domain: "SCStreamErrorDomain", code: -3812, userInfo: [NSLocalizedDescriptionKey: "Stream not found"])
        monitor.reportStreamFailure(error)

        XCTAssertEqual(events.count, 1)
        if case .streamFailure(let description) = events.first?.reason {
            XCTAssertTrue(description.contains("Stream not found"))
        } else {
            XCTFail("Expected streamFailure event, got \(String(describing: events.first?.reason))")
        }
    }
}
