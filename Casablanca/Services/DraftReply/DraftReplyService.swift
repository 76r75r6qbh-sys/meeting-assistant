import Foundation

/// A draft reply as the model returned it: an optional `Channel:` hint (email,
/// Teams, Jira, Topdesk) and the draft text.
struct DraftReplyOutput: Equatable {
    let channel: String?
    let body: String

    private static let channelPrefix = "channel:"

    /// Splits off a first line `Channel: <x>`; otherwise `channel` is nil and the
    /// body is the whole (trimmed) text.
    static func parse(_ raw: String) -> DraftReplyOutput {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = text.prefix { !$0.isNewline }
        guard firstLine.lowercased().hasPrefix(channelPrefix) else {
            return DraftReplyOutput(channel: nil, body: text)
        }
        let channel = firstLine.dropFirst(channelPrefix.count).trimmingCharacters(in: .whitespaces)
        let body = text.dropFirst(firstLine.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return DraftReplyOutput(channel: channel.isEmpty ? nil : channel, body: body)
    }
}

/// Drafts a reply for a to-do with headless Claude Code (`claude -p`) that can
/// READ the user's mail, Teams, Jira and Confluence through `medicore-gateway`,
/// and cannot write to any of them.
///
/// The app must never be able to send anything. That rests on the flags in
/// ``arguments(model:mcpConfigPath:)``: only the gateway is loaded
/// (`--strict-mcp-config` + a generated config), `--permission-mode default`
/// overrides a user `auto` mode so every tool outside `--allowedTools` is
/// denied in `-p` mode, and `--disallowedTools` names the gateway's send/write
/// tools and `Bash`/`Write`/`Edit` again as belt-and-braces.
struct DraftReplyService {
    /// The full run reads a thread before it writes, so it gets more than a
    /// plain completion; the revision shares the same budget.
    static let timeout: TimeInterval = 180
    static let defaultModel = "sonnet"
    static let mcpConfigFileName = "mcp.json"

    /// The only MCP server the run loads. It carries M365, Jira and Confluence.
    static let mcpConfigJSON =
        #"{"mcpServers":{"medicore-gateway":{"type":"http","url":"https://mcptest.development.mcepd.nl/mcp"}}}"#

    /// Loads user settings (skills, CLAUDE.md) but runs none of the user's hooks.
    static let hookFreeSettings = #"{"disableAllHooks":true}"#

    private static let gatewayToolPrefix = "mcp__medicore-gateway__"

    /// Everything the run may use. Read verbs only; a test enforces that.
    static let readOnlyTools: [String] = ["Read", "Skill"] + [
        "ping", "atlassian_fetch", "atlassian_search",
        "confluence_get_page", "confluence_get_page_footer_comments",
        "confluence_get_page_inline_comments", "confluence_search",
        "jira_get_issue", "jira_get_comments", "jira_search_issues",
        "microsoft365_get_email", "microsoft365_list_emails", "microsoft365_search_emails",
        "microsoft365_list_chats", "microsoft365_list_chat_messages",
        "microsoft365_get_event", "microsoft365_list_events",
        "microsoft365_find_user", "microsoft365_search_contacts", "microsoft365_get_contact",
    ].map { gatewayToolPrefix + $0 }

    /// Denied explicitly on top of the allowlist: every gateway tool that sends,
    /// replies, creates or changes something, plus the local write tools.
    static let blockedTools: [String] = [
        "microsoft365_send_email", "microsoft365_send_draft", "microsoft365_reply_to_email",
        "microsoft365_forward_email", "microsoft365_create_draft", "microsoft365_send_chat_message",
        "microsoft365_create_chat", "microsoft365_respond_to_event", "microsoft365_create_event",
        "microsoft365_update_event", "jira_add_comment", "jira_transition_issue",
        "jira_edit_issue", "jira_create_issue", "confluence_create_footer_comment",
        "confluence_create_inline_comment", "confluence_update_page", "confluence_create_page",
    ].map { gatewayToolPrefix + $0 } + ["Bash", "Write", "Edit"]

    /// The argument list of the tool-using draft run. A test locks it.
    static func arguments(model: String, mcpConfigPath: String) -> [String] {
        [
            "-p",
            "--output-format", "json",
            "--model", model,
            "--no-session-persistence",
            "--strict-mcp-config",
            "--mcp-config", mcpConfigPath,
            "--permission-mode", "default",
            "--setting-sources", "user",
            "--settings", hookFreeSettings,
            "--allowedTools", readOnlyTools.joined(separator: ","),
            "--disallowedTools", blockedTools.joined(separator: ","),
        ]
    }

    private let runner: CommandRunning
    private let defaults: UserDefaults
    /// Nil means `ClaudeCLIProvider`'s own resolution (setting, known install
    /// paths, login shell).
    private let resolveExecutable: (@Sendable (String) async throws -> String?)?

    /// - Parameter resolveExecutable: maps the `claudeCLIPath` setting to the
    ///   binary to run, or nil when there is none. Defaults to
    ///   `ClaudeCLIProvider.resolvedExecutablePath(preferring:)`.
    init(
        runner: CommandRunning = ProcessCommandRunner(),
        defaults: UserDefaults = .standard,
        resolveExecutable: (@Sendable (String) async throws -> String?)? = nil
    ) {
        self.runner = runner
        self.defaults = defaults
        self.resolveExecutable = resolveExecutable
    }

    /// The tool-using run: reads the source and the context, returns a draft.
    func draft(_ context: DraftReplyContext) async throws -> DraftReplyOutput {
        let cli = provider()
        let executable: String?
        if let resolveExecutable {
            executable = try await resolveExecutable(cli.endpoint)
        } else {
            executable = try await cli.resolvedExecutablePath(preferring: cli.endpoint)
        }
        guard let executable else {
            throw LLMProviderError.invalidEndpoint(provider: cli.displayName)
        }

        // A fresh directory per run, holding only the MCP config, so nothing in a
        // project tree (a CLAUDE.md, a .mcp.json) can influence the draft.
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DraftReplyService-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workingDirectory) }
        let configURL = workingDirectory.appendingPathComponent(Self.mcpConfigFileName)
        try Data(Self.mcpConfigJSON.utf8).write(to: configURL)

        let result = try await cli.run(
            executable: executable,
            arguments: Self.arguments(model: cli.model, mcpConfigPath: configURL.path),
            standardInput: DraftReplyPrompt.initial(context),
            workingDirectory: workingDirectory,
            timeout: Self.timeout
        )
        return DraftReplyOutput.parse(try cli.completionText(from: result))
    }

    /// A tool-less completion: rewrites `draft` (including the user's edits) as
    /// `steer` asks. No MCP servers, no tools.
    func revise(draft: String, steer: String, context: DraftReplyContext) async throws -> DraftReplyOutput {
        let text = try await provider().generate(
            prompt: DraftReplyPrompt.revision(draft: draft, steer: steer, context: context),
            temperature: nil,
            timeout: Self.timeout,
            truncated: nil
        )
        return DraftReplyOutput.parse(text)
    }

    /// Reads the settings at call time, so a change in Settings applies to the
    /// next draft without rebuilding the service.
    private func provider() -> ClaudeCLIProvider {
        ClaudeCLIProvider(
            endpoint: defaults.string(forKey: AppPreferenceKey.claudeCLIPath) ?? "",
            model: draftModel,
            runner: runner,
            defaults: defaults
        )
    }

    private var draftModel: String {
        let stored = defaults.string(forKey: AppPreferenceKey.draftReplyModel)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? Self.defaultModel : stored
    }
}
