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
    /// succeeds. It is only reachable from a retrying call site — `SummarizationService`
    /// and `MeetingChatService` wrap `generate` in `LLMRetryPolicy`, so a timeout there
    /// costs up to `maxAttempts` billed generations. `TerminologyService` calls
    /// `generate` bare, and does not send this provider a transcript at all.
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

    /// The opposite of a timeout: the CLI already ran the generation and only its
    /// output failed to finish arriving. Retrying would bill a second generation for
    /// an answer that is most likely already complete, so this maps to a
    /// non-transient kind even though the underlying condition is a wait that expired.
    func testGenerateIncompleteOutputIsNonTransientMalformedResponse() async {
        let runner = FakeCommandRunner.throwing(CommandRunError.outputIncomplete)
        await XCTAssertThrowsErrorAsync(try await generate(with: runner)) { error in
            guard case LLMProviderError.requestFailed(_, let kind, _) = error else {
                return XCTFail("expected requestFailed, got \(error)")
            }
            XCTAssertEqual(kind, .malformedResponse)
            XCTAssertEqual(
                (error as? LLMProviderError)?.isTransient,
                false,
                "a drain overrun must not buy another billed generation"
            )
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
        // Keeps the CLI in completion mode. Dropping it — or swapping it for
        // `--append-system-prompt`, which layers on top of the agent prompt instead
        // of replacing it — would turn summaries into chat replies.
        assertPair("--system-prompt", ClaudeCLIProvider.systemPrompt, in: arguments)
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

    /// What makes an auto-detected path appear in the Settings / Onboarding field
    /// instead of an empty box: the path the provider *found* is what gets stored,
    /// not the blank one it was handed.
    func testFetchAvailableModelsWritesDetectedPathToDefaults() async throws {
        let runner = FakeCommandRunner.succeeding(standardOutput: "2.1.220 (Claude Code)\n")
        XCTAssertNil(defaults.string(forKey: AppPreferenceKey.claudeCLIPath))

        _ = try await makeAutoDetectProvider(
            runner: runner,
            executablePaths: [Self.secondCandidate]
        ).fetchAvailableModels(endpoint: "")

        XCTAssertEqual(defaults.string(forKey: AppPreferenceKey.claudeCLIPath), Self.secondCandidate)
    }

    /// `generate` must persist the path too, not just the model lookup. A user who
    /// never opens the AI settings tab or onboarding step 4 would otherwise repeat
    /// the candidate scan plus the `/bin/zsh -lc` login-shell probe on every AI call
    /// — and that probe's budget sits outside the caller's timeout.
    func testGenerateWritesDetectedPathToDefaults() async throws {
        let runner = FakeCommandRunner.succeeding(standardOutput: Self.envelope(result: "ok"))
        XCTAssertNil(defaults.string(forKey: AppPreferenceKey.claudeCLIPath))

        _ = try await makeAutoDetectProvider(
            runner: runner,
            executablePaths: [Self.secondCandidate]
        ).generate(prompt: "p", temperature: nil, timeout: 60, truncated: nil)

        XCTAssertEqual(defaults.string(forKey: AppPreferenceKey.claudeCLIPath), Self.secondCandidate)
        XCTAssertEqual(runner.allCalls.count, 1, "a candidate hit must not also consult the login shell")
    }

    /// `AppPreferenceKey.claudeCLIPath` is `@AppStorage`-bound in `SettingsView` and
    /// `OnboardingView`, and `generate` is nonisolated — so a background
    /// summarization that auto-detects the CLI would publish a SwiftUI change from a
    /// background thread while either of those is open. The provider has to hop to
    /// the main actor itself; it cannot rely on where its caller happened to be.
    ///
    /// The `async` test body is nonisolated, so it runs on the cooperative pool
    /// rather than the main thread — the same shape as a background summarization.
    /// The first assertion pins that, so the test cannot pass vacuously.
    func testGenerateWritesTheDetectedPathOnTheMainThread() async throws {
        XCTAssertFalse(Thread.isMainThread, "this test only means anything off the main thread")

        let recording = ThreadRecordingDefaults(suiteName: suiteName)!
        let provider = ClaudeCLIProvider(
            endpoint: "",
            model: "sonnet",
            runner: FakeCommandRunner.succeeding(standardOutput: Self.envelope(result: "ok")),
            defaults: recording,
            candidates: [Self.firstCandidate, Self.secondCandidate],
            isExecutable: { $0 == Self.secondCandidate }
        )

        _ = try await provider.generate(prompt: "p", temperature: nil, timeout: 60, truncated: nil)

        XCTAssertEqual(recording.setCallThreads, [true], "the path write must land on the main thread")
        XCTAssertEqual(recording.string(forKey: AppPreferenceKey.claudeCLIPath), Self.secondCandidate)
    }

    /// The write is deliberately gated on the run having *returned*, not merely on
    /// the process having launched, so neither `timedOut` nor `outputIncomplete`
    /// persists a path. Making the hop to the main actor must not widen that: the
    /// point of the gate is that these two paths never reach the write at all.
    func testGenerateDoesNotPersistThePathWhenTheRunNeverReturned() async {
        for error in [CommandRunError.timedOut, .outputIncomplete] {
            let provider = makeAutoDetectProvider(
                runner: FakeCommandRunner.throwing(error),
                executablePaths: [Self.secondCandidate]
            )
            await XCTAssertThrowsErrorAsync(
                try await provider.generate(prompt: "p", temperature: nil, timeout: 60, truncated: nil)
            )
            XCTAssertNil(
                defaults.string(forKey: AppPreferenceKey.claudeCLIPath),
                "\(error) must not persist a path"
            )
        }
    }

    /// What the write-back buys: a provider built from the stored path resolves
    /// without touching the filesystem or a shell, so the only command is the CLI.
    func testGenerateWithAStoredPathRunsExactlyOneCommand() async throws {
        let runner = FakeCommandRunner.succeeding(standardOutput: Self.envelope(result: "ok"))

        _ = try await makeAutoDetectProvider(
            runner: runner,
            // Nothing is executable, so a provider without a stored path would have to
            // fall through to the login shell.
            executablePaths: []
        ).generate(prompt: "p", temperature: nil, timeout: 60, truncated: nil)
        XCTAssertEqual(runner.allCalls.count, 2, "auto-detect costs the login-shell probe plus the CLI")

        let withStoredPath = FakeCommandRunner.succeeding(standardOutput: Self.envelope(result: "ok"))
        _ = try await makeProvider(runner: withStoredPath)
            .generate(prompt: "p", temperature: nil, timeout: 60, truncated: nil)
        XCTAssertEqual(withStoredPath.allCalls.count, 1)
        XCTAssertEqual(withStoredPath.lastCall?.executable, Self.stubPath)
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

    // MARK: - Path auto-detection

    /// The first-run path: no stored CLI path, so the candidate list decides. Later
    /// candidates must not win over earlier ones, and non-existent ones are skipped.
    func testAutoDetectUsesTheFirstExecutableCandidate() async throws {
        let runner = FakeCommandRunner.succeeding(standardOutput: "2.1.220 (Claude Code)\n")

        let models = try await makeAutoDetectProvider(
            runner: runner,
            executablePaths: [Self.secondCandidate, Self.thirdCandidate]
        ).fetchAvailableModels(endpoint: "")

        XCTAssertEqual(models, ClaudeCLIProvider.availableModels)
        XCTAssertEqual(runner.allCalls.count, 1, "a candidate hit must not also consult the login shell")
        XCTAssertEqual(runner.lastCall?.executable, Self.secondCandidate)
    }

    /// A GUI-spawned process inherits a minimal PATH, so an install outside the known
    /// locations (bun, nvm, a custom prefix) is only visible to a login shell.
    func testAutoDetectFallsBackToLoginShellWhenNoCandidateIsExecutable() async throws {
        // One canned outcome serves both calls: stdout is the shell's answer for the
        // lookup, and for the `--version` probe only the exit code matters.
        let shellAnswer = "/Users/test/.bun/bin/claude"
        let runner = FakeCommandRunner.succeeding(standardOutput: shellAnswer + "\n")

        let models = try await makeAutoDetectProvider(
            runner: runner,
            executablePaths: []
        ).fetchAvailableModels(endpoint: "")

        XCTAssertEqual(models, ClaudeCLIProvider.availableModels)
        let calls = runner.allCalls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.first?.executable, "/bin/zsh")
        XCTAssertEqual(calls.first?.arguments, ["-lc", "command -v claude"])
        XCTAssertEqual(calls.last?.executable, shellAnswer, "the probe must run what the shell reported")
    }

    /// Claude Code is not installed at all: the user must see "endpoint is invalid",
    /// which Settings points at the path field, rather than a launch failure.
    func testAutoDetectFindingNothingAnywhereIsInvalidEndpoint() async {
        // Exit 1 = `command -v claude` found nothing.
        let runner = FakeCommandRunner.succeeding(exitCode: 1)
        let provider = makeAutoDetectProvider(runner: runner, executablePaths: [])

        await XCTAssertThrowsErrorAsync(try await provider.fetchAvailableModels(endpoint: "")) { error in
            guard case LLMProviderError.invalidEndpoint = error else {
                return XCTFail("expected invalidEndpoint, got \(error)")
            }
        }
        XCTAssertEqual(runner.allCalls.count, 1, "nothing may be launched once resolution failed")
        XCTAssertNil(defaults.string(forKey: AppPreferenceKey.claudeCLIPath), "must not store a path it never found")
    }

    // MARK: - Helpers

    /// Hermetic stand-ins for the real candidate list, so auto-detect tests do not
    /// depend on whether the running machine happens to have `claude` installed.
    private static let firstCandidate = "/tmp/claude-cli-provider-tests/first/claude"
    private static let secondCandidate = "/tmp/claude-cli-provider-tests/second/claude"
    private static let thirdCandidate = "/tmp/claude-cli-provider-tests/third/claude"

    /// A provider with a blank endpoint, so path resolution actually runs, and where
    /// only `executablePaths` count as installed.
    private func makeAutoDetectProvider(
        runner: CommandRunning,
        executablePaths: Set<String>
    ) -> ClaudeCLIProvider {
        ClaudeCLIProvider(
            endpoint: "",
            model: "sonnet",
            runner: runner,
            defaults: defaults,
            candidates: [Self.firstCandidate, Self.secondCandidate, Self.thirdCandidate],
            isExecutable: { executablePaths.contains($0) }
        )
    }

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

/// `UserDefaults` that records which thread each write came in on.
///
/// Subclassing is the only seam here: the provider takes a plain `UserDefaults`, and
/// the thing under test is *where* the write happens, which nothing observable from
/// the outside reveals. Reads are left untouched.
final class ThreadRecordingDefaults: UserDefaults {
    private let threads = OSAllocatedUnfairLock(initialState: [Bool]())

    /// `true` for each write that happened on the main thread, in order.
    var setCallThreads: [Bool] { threads.withLock { $0 } }

    override func set(_ value: Any?, forKey defaultName: String) {
        threads.withLock { $0.append(Thread.isMainThread) }
        super.set(value, forKey: defaultName)
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

    /// Every call in order — path resolution can run two commands (the login-shell
    /// lookup, then the binary itself), and which ran matters.
    var allCalls: [Call] { calls.withLock { $0 } }

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
