import XCTest
@testable import Casablanca

final class UpdateErrorTests: XCTestCase {
    func test_localizedDescription_isHumanReadable_forEveryCase() {
        let cases: [UpdateError] = [
            .notInApplicationsFolder,
            .checkFailed(URLError(.notConnectedToInternet)),
            .rateLimited(retryAfter: Date(timeIntervalSince1970: 0)),
            .malformedResponse,
            .assetNotFound,
            .notSafeToQuit(reason: "a recording"),
            .downloadFailed(URLError(.timedOut)),
            .unzipFailed,
            .quarantineStripFailed("xattr exited 1"),
            .versionRegression,
            .codesignFailed,
            .swapFailed("permission denied"),
            .helperSpawnFailed("posix_spawn returned 13")
        ]
        for error in cases {
            let description = error.errorDescription ?? ""
            XCTAssertFalse(description.isEmpty, "missing description for \(error)")
            XCTAssertFalse(description.contains("Optional("), "raw Optional in \(error)")
        }
    }

    func test_equatable_distinguishesAssociatedValues() {
        XCTAssertNotEqual(
            UpdateError.swapFailed("disk full"),
            UpdateError.swapFailed("permission denied")
        )
        XCTAssertEqual(UpdateError.unzipFailed, UpdateError.unzipFailed)
    }
}
