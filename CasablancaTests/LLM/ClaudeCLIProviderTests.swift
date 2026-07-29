import XCTest
import os
@testable import Casablanca

/// Every test here goes through `FakeCommandRunner`: invoking the real `claude`
/// would bill the user's subscription and make the suite non-hermetic.
final class ClaudeCLIProviderTests: XCTestCase {
    /// A path that is never resolved against the filesystem, only handed to the fake.
    /// Non-blank so it wins path resolution outright and exactly one command runs.
    private static let stubPath = "/tmp/claude-cli-provider-tests/claude"

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ClaudeCLIProviderTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Success

    func testGenerateReturnsResultAndReportsNoTruncation() async throws {
        let runner = FakeCommandRunner.succeeding(standardOutput: Self.envelope(result: "Summary text"))
        var sawTruncated: Bool?

        let text = try await makeProvider(runner: runner).generate(
            prompt: "p", temperature: nil, timeout: 60,
            truncated: { sawTruncated = $0 }
        )

        XCTAssertEqual(text, "Summary text")
        // The CLI reports no length-limit signal, so truncation is always "no".
        XCTAssertEqual(sawTruncated, false)
    }

    // MARK: - Error mapping

    /// `error_during_execution` and friends omit `result` entirely, so the envelope
    /// must decode it as optional and still produce a usable error.
    func testGenerateErrorEnvelopeWithoutResultKeyIsNonTransientBackendError() async {
        let runner = FakeCommandRunner.succeeding(
            standardOutput: #"{"type":"result","subtype":"error_during_execution","is_error":true}"#
        )
        await XCTAssertThrowsErrorAsync(try await generate(with: runner)) { error in
            guard case LLMProviderError.requestFailed(_, let kind, _) = error else {
                return XCTFail("expected requestFailed, got \(error)")
            }
            XCTAssertEqual(kind, .backendError)
            XCTAssertEqual((error as? LLMProviderError)?.isTransient, false)
        }
    }

    func testGenerateNonJSONOutputOnZeroExitIsMalformedResponse() async {
        let runner = FakeCommandRunner.succeeding(standardOutput: "not json at all")
        await XCTAssertThrowsErrorAsync(try await generate(with: runner)) { error in
            guard case LLMProviderError.requestFailed(_, let kind, _) = error else {
                return XCTFail("expected requestFailed, got \(error)")
            }
            XCTAssertEqual(kind, .malformedResponse)
        }
    }

    /// A usage-limit hit exits non-zero with plain text, not JSON. Requiring a
    /// decodable envelope on this path would hide the only useful information, and
    /// retrying it would not help before the limit resets — hence non-transient.
    func testGenerateNonZeroExitSurfacesPlainTextAsNonTransientBackendError() async {
        let runner = FakeCommandRunner.succeeding(
            exitCode: 1,
            standardError: "Claude usage limit reached"
        )
        await XCTAssertThrowsErrorAsync(try await generate(with: runner)) { error in
            guard case LLMProviderError.requestFailed(_, let kind, let message) = error else {
                return XCTFail("expected requestFailed, got \(error)")
            }
            XCTAssertEqual(kind, .backendError)
            XCTAssertTrue(message.contains("Claude usage limit reached"), "got: \(message)")
            XCTAssertEqual((error as? LLMProviderError)?.isTransient, false)
        }
    }

    func testGenerateLaunchFailureIsInvalidEndpoint() async {
        let runner = FakeCommandRunner.throwing(CommandRunError.launchFailed("No such file"))
        await XCTAssertThrowsErrorAsync(try await generate(with: runner)) { error in
            guard case LLMProviderError.invalidEndpoint = error else {
                return XCTFail("expected invalidEndpoint, got \(error)")
            }
        }
    }

    /// Transient by design: a timeout is the one failure where rerunning plausibly
    /// succeeds, even though it means terminology correction can spend 3 × 240s.
    func testGenerateTimeoutIsTransientNetworkFailure() async {
        let runner = FakeCommandRunner.throwing(CommandRunError.timedOut)
        await XCTAssertThrowsErrorAsync(try await generate(with: runner)) { error in
            guard case LLMProviderError.requestFailed(_, let kind, _) = error else {
                return XCTFail("expected requestFailed, got \(error)")
            }
            XCTAssertEqual(kind, .network(.timedOut))
            XCTAssertEqual((error as? LLMProviderError)?.isTransient, true)
        }
    }

    /// Converting cancellation into an `LLMProviderError` would let `LLMRetryPolicy`
    /// rerun a call the user just cancelled.
    func testGenerateRethrowsCancellationErrorUnchanged() async {
        let runner = FakeCommandRunner.throwing(CancellationError())
        await XCTAssertThrowsErrorAsync(try await generate(with: runner)) { error in
            XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(error)")
        }
    }

    func testGenerateThrowsEmptyResponseOnBlankResult() async {
        let runner = FakeCommandRunner.succeeding(standardOutput: Self.envelope(result: "   "))
        await XCTAssertThrowsErrorAsync(try await generate(with: runner)) { error in
            guard case LLMProviderError.emptyResponse = error else {
                return XCTFail("expected emptyResponse, got \(error)")
            }
        }
    }

    // MARK: - Invocation contract

    func testGeneratePassesPromptOnStandardInputVerbatim() async throws {
        let runner = FakeCommandRunner.succeeding(standardOutput: Self.envelope(result: "ok"))
        let prompt = "Summarize this:\n\n- one\n- two"

        _ = try await makeProvider(runner: runner).generate(
            prompt: prompt, temperature: nil, timeout: 60, truncated: nil
        )

        XCTAssertEqual(runner.lastCall?.standardInput, prompt)
    }

    /// Callers append `/no_think` for local Qwen models; to Claude it is a
    /// meaningless slash command that would end up in the prompt.
    func testGenerateStripsTrailingNoThinkSuffixFromPrompt() async throws {
        let runner = FakeCommandRunner.succeeding(standardOutput: Self.envelope(result: "ok"))
        let base = "Summarize this transcript."

        _ = try await makeProvider(runner: runner).generate(
            prompt: base + "\n\n" + LLMPromptSupport.noThinkSuffix,
            temperature: nil, timeout: 60, truncated: nil
        )

        XCTAssertEqual(runner.lastCall?.standardInput, base)
    }

    /// Locks the invocation contract: every one of these flags switches off a Claude
    /// Code agent behavior, and losing one silently would cost tokens or spawn MCP
    /// servers rather than fail visibly.
    func testGenerateArgumentsSuppressAgentBehaviors() async throws {
        let runner = FakeCommandRunner.succeeding(standardOutput: Self.envelope(result: "ok"))

        _ = try await makeProvider(runner: runner, model: "opus").generate(
            prompt: "p", temperature: nil, timeout: 60, truncated: nil
        )

        let arguments = try XCTUnwrap(runner.lastCall?.arguments)
        XCTAssertEqual(runner.lastCall?.executable, Self.stubPath)
        XCTAssertTrue(arguments.contains("-p"), "print mode missing: \(arguments)")
        assertPair("--model", "opus", in: arguments)
        assertPair("--output-format", "json", in: arguments)
        assertPair("--tools", "", in: arguments)
        assertPair("--setting-sources", "", in: arguments)
        XCTAssertTrue(arguments.contains("--strict-mcp-config"), "missing --strict-mcp-config: \(arguments)")
        XCTAssertTrue(arguments.contains("--no-session-persistence"), "missing --no-session-persistence: \(arguments)")
        // Absent from CLI 2.1.220 — passing it would make every call fail.
        XCTAssertFalse(arguments.contains("--max-turns"), "--max-turns does not exist in this CLI")
    }

    /// The run happens in a throwaway directory so nothing in the user's project tree
    /// (a CLAUDE.md, a .mcp.json) can influence the completion. It must exist while
    /// the command runs, and be gone afterwards.
    func testGenerateRunsInAnExistingTemporaryWorkingDirectory() async throws {
        let runner = FakeCommandRunner.succeeding(standardOutput: Self.envelope(result: "ok"))

        _ = try await makeProvider(runner: runner).generate(
            prompt: "p", temperature: nil, timeout: 60, truncated: nil
        )

        let call = try XCTUnwrap(runner.lastCall)
        let directory = try XCTUnwrap(call.workingDirectory)
        XCTAssertTrue(call.workingDirectoryExisted, "working directory must exist while the command runs")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "must be cleaned up afterwards")
    }

    // MARK: - fetchAvailableModels

    func testFetchAvailableModelsProbesVersionAndReturnsFixedList() async throws {
        let runner = FakeCommandRunner.succeeding(standardOutput: "2.1.220 (Claude Code)\n")

        let models = try await makeProvider(runner: runner).fetchAvailableModels(endpoint: Self.stubPath)

        XCTAssertEqual(models, ClaudeCLIProvider.availableModels)
        XCTAssertEqual(runner.lastCall?.arguments, ["--version"])
    }

    /// What makes an auto-detected path appear in the Settings / Onboarding field.
    func testFetchAvailableModelsWritesResolvedPathToDefaults() async throws {
        let runner = FakeCommandRunner.succeeding(standardOutput: "2.1.220 (Claude Code)\n")
        XCTAssertNil(defaults.string(forKey: AppPreferenceKey.claudeCLIPath))

        _ = try await makeProvider(runner: runner).fetchAvailableModels(endpoint: Self.stubPath)

        XCTAssertEqual(defaults.string(forKey: AppPreferenceKey.claudeCLIPath), Self.stubPath)
    }

    func testFetchAvailableModelsLaunchFailureIsInvalidEndpoint() async {
        let runner = FakeCommandRunner.throwing(CommandRunError.launchFailed("No such file"))
        await XCTAssertThrowsErrorAsync(
            try await makeProvider(runner: runner).fetchAvailableModels(endpoint: Self.stubPath)
        ) { error in
            guard case LLMProviderError.invalidEndpoint = error else {
                return XCTFail("expected invalidEndpoint, got \(error)")
            }
        }
    }

    // MARK: - Helpers

    private func makeProvider(
        runner: CommandRunning,
        endpoint: String = ClaudeCLIProviderTests.stubPath,
        model: String = "sonnet"
    ) -> ClaudeCLIProvider {
        ClaudeCLIProvider(endpoint: endpoint, model: model, runner: runner, defaults: defaults)
    }

    @discardableResult
    private func generate(with runner: CommandRunning) async throws -> String {
        try await makeProvider(runner: runner).generate(
            prompt: "p", temperature: nil, timeout: 60, truncated: nil
        )
    }

    /// Asserts `value` immediately follows `flag`, which is what the CLI requires.
    private func assertPair(
        _ flag: String,
        _ value: String,
        in arguments: [String],
        file: StaticString = #file,
        line: UInt = #line
    ) {
        guard let index = arguments.firstIndex(of: flag) else {
            return XCTFail("missing \(flag) in \(arguments)", file: file, line: line)
        }
        guard index + 1 < arguments.count else {
            return XCTFail("\(flag) has no value in \(arguments)", file: file, line: line)
        }
        XCTAssertEqual(arguments[index + 1], value, "value after \(flag)", file: file, line: line)
    }

    /// A minimal stand-in for the real ~20-key success envelope.
    private static func envelope(result: String) -> String {
        let body = try! JSONSerialization.data(withJSONObject: [
            "type": "result",
            "subtype": "success",
            "is_error": false,
            "result": result,
        ])
        return String(decoding: body, as: UTF8.self)
    }
}

/// `CommandRunning` double that records every call and replays one canned outcome.
///
/// `Sendable` (inherited from `CommandRunning`) rules out a bare mutable `var`, so
/// the recording lives behind a lock and the outcome behind a `@Sendable` closure.
final class FakeCommandRunner: CommandRunning {
    struct Call: Sendable {
        let executable: String
        let arguments: [String]
        let standardInput: String
        let workingDirectory: URL?
        /// Whether `workingDirectory` existed at the moment `run` was called — the
        /// provider deletes it before the caller can look.
        let workingDirectoryExisted: Bool
        let timeout: TimeInterval
    }

    private let outcome: @Sendable () throws -> CommandResult
    private let calls = OSAllocatedUnfairLock(initialState: [Call]())

    init(outcome: @escaping @Sendable () throws -> CommandResult) {
        self.outcome = outcome
    }

    static func succeeding(
        exitCode: Int32 = 0,
        standardOutput: String = "",
        standardError: String = ""
    ) -> FakeCommandRunner {
        let result = CommandResult(
            exitCode: exitCode,
            standardOutput: standardOutput,
            standardError: standardError
        )
        return FakeCommandRunner { result }
    }

    static func throwing(_ error: some Error & Sendable) -> FakeCommandRunner {
        FakeCommandRunner { throw error }
    }

    var lastCall: Call? { calls.withLock { $0.last } }

    func run(
        executable: String,
        arguments: [String],
        standardInput: String,
        workingDirectory: URL?,
        timeout: TimeInterval
    ) async throws -> CommandResult {
        let existed = workingDirectory.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        calls.withLock {
            $0.append(Call(
                executable: executable,
                arguments: arguments,
                standardInput: standardInput,
                workingDirectory: workingDirectory,
                workingDirectoryExisted: existed,
                timeout: timeout
            ))
        }
        return try outcome()
    }
}
