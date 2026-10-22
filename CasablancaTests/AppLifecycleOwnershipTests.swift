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
}
