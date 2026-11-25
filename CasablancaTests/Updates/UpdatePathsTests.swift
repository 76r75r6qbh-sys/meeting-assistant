import XCTest
@testable import Casablanca

final class UpdatePathsTests: XCTestCase {
    func test_default_resolvesUnderApplicationSupport() {
        let paths = UpdatePaths.default
        XCTAssertTrue(paths.updatesRoot.path.contains("Application Support/Casablanca/Updates"))
    }

    func test_subpaths_haveExpectedNames() {
        let root = URL(fileURLWithPath: "/tmp/Updates")
        let paths = UpdatePaths(updatesRoot: root)
        XCTAssertEqual(paths.stagingRoot.lastPathComponent, "staging")
        XCTAssertEqual(paths.logsRoot.lastPathComponent, "logs")
        XCTAssertEqual(paths.sentinel.lastPathComponent, "relaunch.sentinel")
    }

    func test_stagingDirectory_perVersion() throws {
        let root = URL(fileURLWithPath: "/tmp/Updates")
        let paths = UpdatePaths(updatesRoot: root)
        let v = try SemanticVersion(parsing: "0.4.0-beta.1")
        XCTAssertEqual(paths.stagingDirectory(for: v).lastPathComponent, "0.4.0-beta.1")
        XCTAssertEqual(paths.stagingDirectory(for: v).deletingLastPathComponent(), paths.stagingRoot)
    }

    func test_relaunchScript_andInstallLog_useTimestampedFilenames() {
        let root = URL(fileURLWithPath: "/tmp/Updates")
        let paths = UpdatePaths(updatesRoot: root)
        let date = Date(timeIntervalSince1970: 1_714_550_400) // 2024-05-01T08:00:00Z
        let log = paths.installLog(at: date)
        let script = paths.relaunchScript(at: date)
        XCTAssertTrue(log.lastPathComponent.hasPrefix("install-"))
        XCTAssertTrue(log.lastPathComponent.hasSuffix(".log"))
        XCTAssertTrue(script.lastPathComponent.hasPrefix("relaunch-"))
        XCTAssertTrue(script.lastPathComponent.hasSuffix(".sh"))
    }
}
