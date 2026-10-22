import XCTest
@testable import Casablanca

@MainActor
final class AppLifecycleOwnershipTests: XCTestCase {
    // MARK: - Bootstrap runs once

    func testRunOnceGateLetsTheFirstClaimThrough() {
        var gate = RunOnceGate()
        XCTAssertTrue(gate.claim())
        XCTAssertTrue(gate.hasRun)
    }

    /// Reopening the main window re-runs its `.task`, which calls
    /// `AppModel.bootstrap` again. The second call must be a no-op.
    func testRunOnceGateRefusesEveryLaterClaim() {
        var gate = RunOnceGate()
        _ = gate.claim()
        XCTAssertFalse(gate.claim(), "a second bootstrap must not run launch work again")
        XCTAssertFalse(gate.claim())
    }

    // MARK: - Interruption handling outlives the window

    /// The service and the coordinator hold the monitor/notifier weakly. The
    /// handling object is the one strong owner: as long as it lives (on
    /// `AppModel`, i.e. the whole app run), so do they, whether or not any
    /// window is open.
    func testInterruptionHandlingKeepsMonitorAndCoordinatorAliveWithoutAWindow() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("interruption-ownership-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let service = AudioRecordingService(
            sessionStore: RecordingResumeSessionStore(baseDirectoryProvider: { rootURL })
        )
        weak var weakMonitor: RecordingInterruptionMonitor?
        weak var weakCoordinator: RecordingInterruptionCoordinator?
        var handling: RecordingInterruptionHandling? = makeHandling(service: service)
        weakMonitor = handling?.monitor
        weakCoordinator = handling?.coordinator

        XCTAssertNotNil(weakMonitor)
        XCTAssertNotNil(weakCoordinator, "the coordinator must survive with only the owner holding it")
        XCTAssertTrue(service.interruptionMonitor === weakMonitor, "the service must see the owned monitor")
        XCTAssertNotNil(weakMonitor?.onEvent, "the coordinator must be wired to the monitor")

        // Releasing the owner is what used to happen when the window closed.
        handling = nil
        XCTAssertNil(weakCoordinator)
        XCTAssertNil(service.interruptionMonitor, "the service only holds the monitor weakly")
    }

    private func makeHandling(service: AudioRecordingService) -> RecordingInterruptionHandling {
        RecordingInterruptionHandling(
            service: service,
            monitor: RecordingInterruptionMonitor(
                workspaceNotificationCenter: NotificationCenter(),
                screenNotificationCenter: NotificationCenter(),
                distributedNotificationCenter: NotificationCenter(),
                deviceListProvider: { [] },
                displayListProvider: { [] }
            ),
            notifier: SilentNotifier(),
            lookupMeeting: { _ in nil },
            save: {}
        )
    }

    private final class SilentNotifier: RecordingInterruptionNotifying {
        func post(title: String, body: String) {}
    }
}
