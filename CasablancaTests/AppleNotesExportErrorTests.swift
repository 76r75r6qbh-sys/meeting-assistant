import XCTest
@testable import Casablanca

final class AppleNotesExportErrorTests: XCTestCase {
    func testMapsKnownPermissionErrorCodes() {
        XCTAssertEqual(AppleNotesExportError.from(appleScriptErrorCode: -1743), .permissionDenied)
        XCTAssertEqual(AppleNotesExportError.from(appleScriptErrorCode: -1744), .permissionDenied)
        XCTAssertEqual(AppleNotesExportError.from(appleScriptErrorCode: -600), .permissionDenied)
        XCTAssertEqual(AppleNotesExportError.from(appleScriptErrorCode: -10810), .permissionDenied)
    }

    func testMapsUnknownErrorCode() {
        switch AppleNotesExportError.from(appleScriptErrorCode: -42) {
        case .scriptingFailed(let code, _):
            XCTAssertEqual(code, -42)
        default:
            XCTFail("Expected scriptingFailed")
        }
    }

    func testPermissionDeniedMessageMentionsSystemSettings() {
        let message = AppleNotesExportError.permissionDenied.errorDescription ?? ""
        XCTAssertTrue(message.contains("System Settings"))
        XCTAssertTrue(message.contains("Automation"))
    }

    func testTimeoutMessageMentionsTimeout() {
        XCTAssertTrue((AppleNotesExportError.timedOut.errorDescription ?? "").lowercased().contains("timed out"))
    }
}
