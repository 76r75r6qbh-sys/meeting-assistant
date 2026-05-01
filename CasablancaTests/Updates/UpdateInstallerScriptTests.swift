import XCTest
@testable import Casablanca

final class UpdateInstallerScriptTests: XCTestCase {
    func test_script_containsSentinelWaitLoop_andTimeout_andOpen() {
        let script = DefaultUpdateInstaller.relaunchScript(
            sentinelPath: URL(fileURLWithPath: "/tmp/relaunch.sentinel"),
            newAppPath: URL(fileURLWithPath: "/Applications/Casablanca.app"),
            logPath: URL(fileURLWithPath: "/tmp/install.log")
        )
        XCTAssertTrue(script.contains("while [ -e"), "missing sentinel wait loop")
        XCTAssertTrue(script.contains("i=$((i+1))"), "missing iteration counter")
        XCTAssertTrue(script.contains("open -n"), "missing open -n")
        XCTAssertTrue(script.contains("set -u"), "missing set -u")
    }

    func test_script_quotesPathsWithSpacesAndQuotes() {
        let script = DefaultUpdateInstaller.relaunchScript(
            sentinelPath: URL(fileURLWithPath: "/tmp/has space/relaunch.sentinel"),
            newAppPath: URL(fileURLWithPath: "/Applications/has 'quote'/Casablanca.app"),
            logPath: URL(fileURLWithPath: "/tmp/log.log")
        )
        XCTAssertTrue(script.contains("'/tmp/has space/relaunch.sentinel'"))
        XCTAssertTrue(script.contains(#"'/Applications/has '\''quote'\''/Casablanca.app'"#))
    }
}
