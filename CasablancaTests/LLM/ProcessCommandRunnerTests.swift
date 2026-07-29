import XCTest
@testable import Casablanca

/// Exercises the real `Process` against system binaries: hermetic, no network,
/// and deliberately never the `claude` CLI.
final class ProcessCommandRunnerTests: XCTestCase {
    private let runner = ProcessCommandRunner()

    // MARK: - Output capture

    func testEchoReturnsStandardOutputAndZeroExitCode() async throws {
        let result = try await run(executable: "/bin/echo", arguments: ["hi"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardOutput, "hi\n")
        XCTAssertEqual(result.standardError, "")
    }

    /// The deadlock guard. A pipe buffers ~64 KB, so this only passes if stdin is
    /// written while stdout is being drained; serialize them and `cat` hangs.
    func testLargeStandardInputRoundTripsThroughCat() async throws {
        let payload = (0..<8_000)
            .map { "line \($0): \(String(repeating: "x", count: 30))\n" }
            .joined()
        XCTAssertGreaterThan(payload.utf8.count, 300_000, "payload must exceed the pipe buffer many times over")

        let result = try await run(executable: "/bin/cat", standardInput: payload)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardOutput, payload)
    }

    func testNonZeroExitIsReturnedWithStandardError() async throws {
        let result = try await run(executable: "/bin/sh", arguments: ["-c", "printf err >&2; exit 3"])
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertEqual(result.standardError, "err")
        XCTAssertEqual(result.standardOutput, "")
    }

    func testWorkingDirectoryIsAppliedToChildProcess() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ProcessCommandRunnerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // `-P` reports the physical path, so the comparison does not depend on the
        // inherited `PWD`. Both sides go through `resolvingSymlinksInPath` because
        // the temp directory is behind the /var -> /private/var symlink.
        let result = try await run(executable: "/bin/pwd", arguments: ["-P"], workingDirectory: directory)
        XCTAssertEqual(result.exitCode, 0)
        let reported = URL(fileURLWithPath: result.standardOutput.trimmingCharacters(in: .newlines))
        XCTAssertEqual(
            reported.resolvingSymlinksInPath().path,
            directory.resolvingSymlinksInPath().path
        )
    }

    // MARK: - Failure modes

    func testMissingExecutableThrowsLaunchFailed() async {
        await XCTAssertThrowsErrorAsync(try await run(executable: "/nonexistent/claude")) { error in
            guard case CommandRunError.launchFailed(let message) = error else {
                return XCTFail("expected launchFailed, got \(error)")
            }
            XCTAssertFalse(message.isEmpty)
        }
    }

    func testTimeoutTerminatesProcessAndThrowsTimedOut() async {
        let started = Date()
        await XCTAssertThrowsErrorAsync(
            try await run(executable: "/bin/sleep", arguments: ["30"], timeout: 0.5)
        ) { error in
            guard case CommandRunError.timedOut = error else {
                return XCTFail("expected timedOut, got \(error)")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "should not have waited out the sleep")
        XCTAssertEqual(try liveChildProcesses(matching: "sleep 30"), [], "timed-out child must not survive")
    }

    func testCancellationTerminatesProcessAndThrowsCancellationError() async throws {
        let runner = self.runner
        let started = Date()
        let task = Task {
            try await runner.run(
                executable: "/bin/sleep",
                arguments: ["30"],
                standardInput: "",
                workingDirectory: nil,
                timeout: 60
            )
        }
        // Let the process actually launch before pulling the plug. Asserting it is
        // running first is also what makes the "gone afterwards" check below
        // meaningful rather than vacuously true.
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(try liveChildProcesses(matching: "sleep 30").isEmpty, "child should be running")
        task.cancel()

        await XCTAssertThrowsErrorAsync(try await task.value) { error in
            XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "should not have waited out the sleep")
        XCTAssertEqual(try liveChildProcesses(matching: "sleep 30"), [], "cancelled child must not survive")
    }

    // MARK: - Helpers

    /// PIDs of this process's own children whose command line matches `pattern`.
    /// Scoping to our children (`pgrep -P`) rather than the whole machine keeps the
    /// leak assertions stable when something unrelated is also running `sleep`.
    private func liveChildProcesses(matching pattern: String) throws -> [String] {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-P", String(ProcessInfo.processInfo.processIdentifier), "-f", pattern]
        let output = Pipe()
        pgrep.standardOutput = output
        try pgrep.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        pgrep.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
    }

    private func run(
        executable: String,
        arguments: [String] = [],
        standardInput: String = "",
        workingDirectory: URL? = nil,
        timeout: TimeInterval = 30
    ) async throws -> CommandResult {
        try await runner.run(
            executable: executable,
            arguments: arguments,
            standardInput: standardInput,
            workingDirectory: workingDirectory,
            timeout: timeout
        )
    }
}
