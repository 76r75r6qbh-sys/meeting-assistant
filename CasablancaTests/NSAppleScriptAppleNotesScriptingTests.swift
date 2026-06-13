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

    /// A slow script that exceeds the timeout: the first call returns `.timedOut`, and a second
    /// call arriving while the first's (leaked) worker thread is still executing fails fast with
    /// `.busy` rather than spawning a second concurrent script. The injected execution seam blocks
    /// on a semaphore so the test can hold the worker thread "running" deterministically, then
    /// release it.
    func testSecondCallWhileLeakedScriptRunningFailsFastWithBusy() async throws {
        // Gates the worker thread. Released only after we've observed `.busy`, so the first
        // script's worker stays "in flight" for the duration of the second call.
        let release = DispatchSemaphore(value: 0)
        // Signals that the worker thread has actually started executing (so the timeout we set is
        // genuinely racing a running script, not a not-yet-spawned one).
        let started = DispatchSemaphore(value: 0)

        let scripting = NSAppleScriptAppleNotesScripting(timeout: 0.2) { _ in
            started.signal()
            release.wait() // block, simulating a long-running NSAppleScript call
            return .success("id||name")
        }

        // First call: short timeout fires before the blocked script returns → `.timedOut`.
        do {
            _ = try await scripting.ensureFolder(named: "Meetings")
            XCTFail("Expected first call to time out")
        } catch let error as AppleNotesExportError {
            XCTAssertEqual(error, .timedOut)
        }

        // Make sure the worker is actually executing (and thus scriptInFlight is still raised
        // because markScriptFinished only runs after the worker returns).
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success, "worker thread never started")

        // Second call while the leaked script is still blocked → fail fast with `.busy`.
        do {
            _ = try await scripting.ensureFolder(named: "Meetings")
            XCTFail("Expected second call to fail with .busy")
        } catch let error as AppleNotesExportError {
            XCTAssertEqual(error, .busy)
        }

        // Release the leaked worker so it can finish and clear the flag.
        release.signal()
    }
}
