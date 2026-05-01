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

extension UpdateInstallerScriptTests {
    private func makeTempBundle(version: String, in dir: URL) throws -> URL {
        let bundle = dir.appendingPathComponent("Casablanca-\(version).app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try Data(version.utf8).write(to: bundle.appendingPathComponent("Contents/version.txt"))
        return bundle
    }

    func test_atomicSwap_replacesDestinationAtomically() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let current = try makeTempBundle(version: "old", in: tempDir)
        let staged = try makeTempBundle(version: "new", in: tempDir)
        let target = tempDir.appendingPathComponent("Casablanca.app", isDirectory: true)
        try FileManager.default.moveItem(at: current, to: target)

        let installer = DefaultUpdateInstaller()
        try await MainActor.run { try installer.atomicSwap(stagedBundle: staged, currentBundle: target) }

        let postSwapVersion = String(data: try Data(contentsOf: target.appendingPathComponent("Contents/version.txt")), encoding: .utf8)
        XCTAssertEqual(postSwapVersion, "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path), "staged path should have been consumed")
    }

    func test_atomicSwap_whenDestinationMissing_movesStagedIntoPlace() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let staged = try makeTempBundle(version: "fresh", in: tempDir)
        let target = tempDir.appendingPathComponent("Casablanca.app", isDirectory: true)

        let installer = DefaultUpdateInstaller()
        try await MainActor.run { try installer.atomicSwap(stagedBundle: staged, currentBundle: target) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    func test_atomicSwap_throwsSwapFailed_onUnwritableDestination() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempDir.path)
            try? FileManager.default.removeItem(at: tempDir)
        }

        let staged = try makeTempBundle(version: "new", in: tempDir)
        let target = tempDir.appendingPathComponent("Casablanca.app", isDirectory: true)
        try FileManager.default.moveItem(at: try makeTempBundle(version: "old", in: tempDir), to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: tempDir.path)

        let installer = DefaultUpdateInstaller()
        do {
            try await MainActor.run { try installer.atomicSwap(stagedBundle: staged, currentBundle: target) }
            XCTFail("expected swapFailed")
        } catch UpdateError.swapFailed {}
    }
}

extension UpdateInstallerScriptTests {
    func test_spawnDetached_runsScriptToCompletion() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let marker = tempDir.appendingPathComponent("marker.txt")
        let pidfile = tempDir.appendingPathComponent("helper.pid")
        let script = tempDir.appendingPathComponent("helper.sh")
        try """
        #!/bin/sh
        echo $$ > '\(pidfile.path)'
        sleep 0.5
        printf 'alive' > '\(marker.path)'
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let installer = DefaultUpdateInstaller()
        try installer.spawnDetached(scriptPath: script)

        // Wait for the helper to write its PID, then assert it is its own session leader.
        for _ in 0..<20 {
            if FileManager.default.fileExists(atPath: pidfile.path) { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let pid = Int(try String(contentsOf: pidfile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        XCTAssertGreaterThan(pid, 0)

        // SETSID makes the helper its own process group leader: pgid equals pid.
        // (On macOS, ps -o sess= always prints 0; pgid= is the reliable indicator.)
        let inspect = Process()
        inspect.launchPath = "/bin/ps"
        inspect.arguments = ["-o", "pgid=", "-p", String(pid)]
        let pipe = Pipe()
        inspect.standardOutput = pipe
        try inspect.run()
        inspect.waitUntilExit()
        let pgid = Int(String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        XCTAssertEqual(pgid, pid, "helper should be its own process group leader (POSIX_SPAWN_SETSID)")

        try await Task.sleep(nanoseconds: 1_000_000_000)
        let value = try? String(contentsOf: marker, encoding: .utf8)
        XCTAssertEqual(value, "alive", "helper script should have completed and written the marker")
    }
}
