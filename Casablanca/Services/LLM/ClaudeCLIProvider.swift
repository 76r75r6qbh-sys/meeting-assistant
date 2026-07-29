import Foundation

/// `LLMProvider` backed by headless Claude Code (`claude -p`), so the app's AI
/// features can use a frontier model billed against the user's existing Claude
/// subscription instead of a local model.
///
/// Unlike the HTTP-backed providers this one shells out, via the injectable
/// `CommandRunning` seam. Every flag in `completionArguments` exists to switch off
/// a Claude Code *agent* behavior we do not want here: we need one completion turn,
/// no tools, no MCP servers, no user settings, and no session on disk.
struct ClaudeCLIProvider: LLMProvider {
    /// Path to the `claude` binary. Empty means "auto-detect". The protocol's
    /// `endpoint` carries the CLI path for this provider, because that is what
    /// `SettingsView.refreshModels` and `SummarizationService.fetchAvailableModels`
    /// thread through.
    let endpoint: String
    let model: String
    let runner: CommandRunning
    let defaults: UserDefaults

    init(
        endpoint: String,
        model: String,
        runner: CommandRunning = ProcessCommandRunner(),
        defaults: UserDefaults = .standard
    ) {
        self.endpoint = endpoint
        self.model = model
        self.runner = runner
        self.defaults = defaults
    }

    var displayName: String { "Claude Code" }

    /// The models we offer. The CLI has no model-list command, and these three
    /// aliases always resolve to the current generation, so hardcoding them beats
    /// pinning version strings that go stale. Ascending order, per the protocol.
    static let availableModels = ["haiku", "opus", "sonnet"]

    /// Keeps the CLI in completion mode rather than assistant mode: no questions
    /// back, no chat-style framing, just the text the caller's prompt asks for.
    static let systemPrompt = """
    You are a text completion assistant. Follow the user's instructions exactly and \
    reply with only the requested output — no preamble, no commentary, no questions.
    """

    /// The full argument list for a completion run. Exposed so a test can lock the
    /// invocation contract: each flag here suppresses a Claude Code agent behavior we
    /// do not want, and a silent regression would cost tokens or spawn MCP servers.
    static func completionArguments(model: String) -> [String] {
        [
            "-p",
            "--output-format", "json",
            "--model", model,
            "--tools", "",              // no tools → guaranteed single completion turn
            "--strict-mcp-config",      // with no --mcp-config → zero MCP servers
            "--setting-sources", "",    // skip user CLAUDE.md / hooks / settings
            "--no-session-persistence", // don't write a session per summary
            "--system-prompt", systemPrompt,
        ]
    }

    /// How long the auxiliary probes (`--version`, `command -v claude`) may take.
    /// Both are near-instant; a long wait here would just stall Settings.
    private static let probeTimeout: TimeInterval = 10

    /// Where the native installer and the common package managers put `claude`,
    /// in the order we trust them. `~/.claude/local/claude` ranks below the
    /// standalone binary because it is a `#!/usr/bin/env node` wrapper: without
    /// `node` on the minimal PATH a GUI app inherits, it cannot run.
    static let candidatePaths: [String] = [
        "~/.local/bin/claude",
        "~/.claude/local/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
    ].map { ($0 as NSString).expandingTildeInPath }

    /// Only the keys we use; the real success envelope carries ~20 more.
    private struct ResultEnvelope: Decodable {
        let result: String?
        let subtype: String?
        let isError: Bool?

        enum CodingKeys: String, CodingKey {
            case result, subtype, isError = "is_error"
        }
    }

    func generate(
        prompt: String,
        temperature: Double?,
        maxTokens: Int? = nil,
        timeout: TimeInterval,
        truncated: ((Bool) -> Void)?
    ) async throws -> String {
        // `temperature` and `maxTokens` are ignored: the CLI exposes neither.
        guard let executable = try await resolvedExecutablePath(preferring: endpoint) else {
            throw LLMProviderError.invalidEndpoint(provider: displayName)
        }

        // A fresh empty directory per run, so nothing in the user's project tree
        // (a CLAUDE.md, a .mcp.json) can influence the completion.
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeCLIProvider-\(UUID().uuidString)", isDirectory: true)
        // Not `try?`: launching with a directory that does not exist would fail as
        // `launchFailed` and report itself as a bad CLI path, which it is not.
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workingDirectory) }

        let result = try await run(
            executable: executable,
            arguments: Self.completionArguments(model: model),
            standardInput: Self.strippingNoThinkSuffix(from: prompt),
            workingDirectory: workingDirectory,
            timeout: timeout
        )

        // A non-zero exit must not require JSON: usage limits and rejected flags
        // print plain text, and demanding a decodable envelope here would replace a
        // useful message with "malformed response".
        guard result.exitCode == 0 else {
            throw LLMProviderError.requestFailed(
                provider: displayName,
                kind: .backendError,
                message: message(
                    from: [result.standardError, result.standardOutput],
                    fallback: "\(displayName) exited with status \(result.exitCode)."
                )
            )
        }

        let envelope: ResultEnvelope
        do {
            envelope = try JSONDecoder().decode(ResultEnvelope.self, from: Data(result.standardOutput.utf8))
        } catch {
            throw LLMProviderError.requestFailed(
                provider: displayName,
                kind: .malformedResponse,
                message: "\(displayName) returned a malformed response: \(error.localizedDescription)"
            )
        }

        // Error subtypes such as `error_during_execution` omit `result` entirely,
        // so the message falls back through what the envelope does carry.
        if envelope.isError == true {
            throw LLMProviderError.requestFailed(
                provider: displayName,
                kind: .backendError,
                message: message(
                    from: [envelope.result, envelope.subtype, result.standardError],
                    fallback: "\(displayName) reported an error."
                )
            )
        }

        let text = envelope.result?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            throw LLMProviderError.emptyResponse(provider: displayName)
        }
        // The CLI reports no length-limit signal, so a completion is never known
        // to be truncated.
        truncated?(false)
        return text
    }

    /// The CLI has no model-list command, so this doubles as the reachability probe
    /// Settings and Onboarding show: it runs `--version` and, on success, returns the
    /// fixed model list.
    func fetchAvailableModels(endpoint: String) async throws -> [String] {
        // The argument wins over the stored property, matching how
        // `SettingsView.refreshModels` calls it with the field's current text.
        guard let executable = try await resolvedExecutablePath(preferring: endpoint) else {
            throw LLMProviderError.invalidEndpoint(provider: displayName)
        }

        let result = try await run(
            executable: executable,
            arguments: ["--version"],
            standardInput: "",
            workingDirectory: nil,
            timeout: Self.probeTimeout
        )
        guard result.exitCode == 0 else {
            throw LLMProviderError.requestFailed(
                provider: displayName,
                kind: .backendError,
                message: message(
                    from: [result.standardError, result.standardOutput],
                    fallback: "\(displayName) is not usable: `--version` exited with status \(result.exitCode)."
                )
            )
        }

        // Persist what we resolved, so an auto-detected path shows up in the
        // Settings / Onboarding field instead of an empty box.
        if defaults.string(forKey: AppPreferenceKey.claudeCLIPath) != executable {
            defaults.set(executable, forKey: AppPreferenceKey.claudeCLIPath)
        }
        return Self.availableModels
    }

    // MARK: - Running

    /// Runs the CLI and maps `CommandRunError` onto `LLMProviderError`.
    ///
    /// `CancellationError` is deliberately *not* caught: converting it into an
    /// `LLMProviderError` would let `LLMRetryPolicy` rerun a call the user just
    /// cancelled. It propagates unchanged.
    private func run(
        executable: String,
        arguments: [String],
        standardInput: String,
        workingDirectory: URL?,
        timeout: TimeInterval
    ) async throws -> CommandResult {
        do {
            return try await runner.run(
                executable: executable,
                arguments: arguments,
                standardInput: standardInput,
                workingDirectory: workingDirectory,
                timeout: timeout
            )
        } catch let error as CommandRunError {
            switch error {
            case .launchFailed:
                // The path is wrong or not executable — the one failure the user can
                // fix, and Settings points them at the field.
                throw LLMProviderError.invalidEndpoint(provider: displayName)
            case .timedOut:
                throw LLMProviderError.requestFailed(
                    provider: displayName,
                    kind: .network(.timedOut),
                    message: "\(displayName) did not respond within \(Int(timeout)) seconds."
                )
            }
        }
    }

    // MARK: - Path resolution

    /// The `claude` binary to run, or `nil` if none was found.
    ///
    /// A non-blank `preferred` path wins outright: a bogus one then surfaces as
    /// `.invalidEndpoint` via `launchFailed`, which is the correct visible failure
    /// rather than a silent fall-through to some other binary.
    private func resolvedExecutablePath(preferring preferred: String) async throws -> String? {
        let trimmed = preferred.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let known = Self.candidatePaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return known
        }
        return try await pathFromLoginShell()
    }

    /// Last resort: ask a login shell where `claude` is. A GUI-spawned `Process`
    /// inherits a minimal PATH that will not include a user-level install, so the
    /// login shell (which sources the user's profile) is the only way to see what
    /// the user sees in Terminal.
    private func pathFromLoginShell() async throws -> String? {
        let result: CommandResult
        do {
            result = try await runner.run(
                executable: "/bin/zsh",
                arguments: ["-lc", "command -v claude"],
                standardInput: "",
                workingDirectory: nil,
                timeout: Self.probeTimeout
            )
        } catch is CommandRunError {
            // No shell, or the profile hung. Indistinguishable from "not installed"
            // as far as the caller is concerned.
            return nil
        }
        guard result.exitCode == 0 else { return nil }
        return result.standardOutput
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    // MARK: - Prompt and message shaping

    /// Removes a trailing `/no_think` token. Callers append it via
    /// `LLMPromptSupport.applyThinkingSwitch` for local Qwen models; to Claude it is
    /// meaningless slash-command noise. Only a trailing occurrence is stripped — a
    /// prompt that merely mentions the string mid-text is left alone.
    private static func strippingNoThinkSuffix(from prompt: String) -> String {
        let trimmed = trimmingTrailingWhitespace(prompt)
        guard trimmed.hasSuffix(LLMPromptSupport.noThinkSuffix) else { return prompt }
        return trimmingTrailingWhitespace(String(trimmed.dropLast(LLMPromptSupport.noThinkSuffix.count)))
    }

    /// Trailing-only trim, so stripping the suffix cannot also reflow a prompt whose
    /// leading whitespace is deliberate.
    private static func trimmingTrailingWhitespace(_ text: String) -> String {
        var result = text
        while let last = result.last, last.isWhitespace { result.removeLast() }
        return result
    }

    /// The first non-blank candidate, trimmed, or `fallback` when they are all blank.
    private func message(from candidates: [String?], fallback: String) -> String {
        let found = candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let found else { return fallback }
        return "\(displayName) failed: \(found)"
    }
}
