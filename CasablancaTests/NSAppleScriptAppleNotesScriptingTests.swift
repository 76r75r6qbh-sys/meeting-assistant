import XCTest
@testable import Casablanca

final class NSAppleScriptAppleNotesScriptingTests: XCTestCase {
    func testTypeConformsToProtocol() {
        // Smoke test: this only verifies the type exists and conforms.
        // Real scripting is exercised in manual integration testing per the spec.
        let scripting: AppleNotesScripting = NSAppleScriptAppleNotesScripting()
        XCTAssertNotNil(scripting)
    }

    func testTimeoutErrorIsMappedToAppleNotesExportError() {
        let nsError = NSError(domain: "NSAppleScriptErrorDomain", code: 0, userInfo: [
            "NSAppleScriptErrorNumber": -1712
        ])
        let mapped = AppleNotesExportError.from(appleScriptErrorCode: nsError.userInfo["NSAppleScriptErrorNumber"] as! Int)
        if case .scriptingFailed(let code, _) = mapped {
            XCTAssertEqual(code, -1712)
        } else {
            XCTFail("Expected scriptingFailed, got \(mapped)")
        }
    }
}
