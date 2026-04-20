import XCTest
@testable import Casablanca

final class PermissionsBehaviorTests: XCTestCase {
    func testScreenCapturePermissionStateSkipsRequestWhenAlreadyGranted() {
        var requestCallCount = 0

        let state = ScreenCapturePermissionState.resolve(
            preflight: { true },
            request: {
                requestCallCount += 1
                return true
            }
        )

        XCTAssertEqual(state, .granted)
        XCTAssertEqual(requestCallCount, 0)
    }

    func testScreenCapturePermissionStateRequiresRestartAfterFreshGrant() {
        let state = ScreenCapturePermissionState.resolve(
            preflight: { false },
            request: { true }
        )

        XCTAssertEqual(state, .grantedRequiresRestart)
    }

    func testScreenCapturePermissionStateReportsDeniedWhenRequestFails() {
        let state = ScreenCapturePermissionState.resolve(
            preflight: { false },
            request: { false }
        )

        XCTAssertEqual(state, .denied)
    }
}
