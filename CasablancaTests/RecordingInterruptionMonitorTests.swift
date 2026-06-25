import XCTest
@testable import Casablanca

@MainActor
final class RecordingInterruptionMonitorTests: XCTestCase {
    func testScreenSleepProducesInterruptionStartedScreenLock() async {
        let center = NotificationCenter()
        let monitor = RecordingInterruptionMonitor(
            workspaceNotificationCenter: center,
            deviceListProvider: { [] },
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        var events: [RecordingInterruptionEvent] = []
        monitor.onEvent = { events.append($0) }

        center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, .started)
        XCTAssertEqual(events.first?.reason, .screenLock)
    }

    func testScreenWakeProducesInterruptionEndedScreenLock() async {
        let center = NotificationCenter()
        let monitor = RecordingInterruptionMonitor(
            workspaceNotificationCenter: center,
            deviceListProvider: { [] },
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        var events: [RecordingInterruptionEvent] = []
        monitor.onEvent = { events.append($0) }

        center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.last?.kind, .ended)
        XCTAssertEqual(events.last?.reason, .screenLock)
    }

    func testSleepAndWakeProduceSystemSleepEvents() async {
        let center = NotificationCenter()
        let monitor = RecordingInterruptionMonitor(
            workspaceNotificationCenter: center,
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
            deviceListProvider: { [] },
            displayListProvider: { displays },
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        monitor.setActiveInputDevice("BuiltInMic")

        var events: [RecordingInterruptionEvent] = []
        monitor.onEvent = { events.append($0) }

        // Display lost while recording -> displayUnavailable started.
        monitor.reportDisplayConfigurationChanged()

        // Lid reopens: the wake notification fires and a display is back, but
        // assume didChangeScreenParameters did NOT re-fire (the deadlock case).
        displays = [1]
        workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)

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

    func testStreamFailureWhileSystemReasonActiveIsSwallowed() async {
        let center = NotificationCenter()
        let monitor = RecordingInterruptionMonitor(
            workspaceNotificationCenter: center,
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
