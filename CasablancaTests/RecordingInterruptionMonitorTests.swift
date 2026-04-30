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
