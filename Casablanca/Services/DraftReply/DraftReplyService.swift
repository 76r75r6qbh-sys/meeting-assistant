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

/// The MCP server a draft run reads mail, Teams, Jira and Confluence through.
/// Set in Settings → Draft replies; the defaults are placeholders.
struct DraftReplyGateway: Equatable {
    let name: String
    let url: String

    static let defaultName = "work-gateway"
    static let defaultURL = "https://mcp.example.com/mcp"
    static let `default` = DraftReplyGateway(name: defaultName, url: defaultURL)

    /// Reads the configured gateway; an empty or invalid field falls back to its
    /// default. A name may only hold letters, digits, `_` and `-`, because it
    /// becomes part of every tool name (`mcp__<name>__<tool>`).
    static func configured(in defaults: UserDefaults) -> DraftReplyGateway {
        let name = (defaults.string(forKey: AppPreferenceKey.draftReplyGatewayName) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let url = (defaults.string(forKey: AppPreferenceKey.draftReplyGatewayURL) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let validName = !name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
        let validURL = URL(string: url).map { ["http", "https"].contains($0.scheme?.lowercased() ?? "") } ?? false
        return DraftReplyGateway(name: validName ? name : defaultName, url: validURL ? url : defaultURL)
    }

    var toolPrefix: String { "mcp__\(name)__" }

    /// The MCP config the run loads: this gateway only.
    var mcpConfigJSON: String {
        let encodedURL = (try? JSONEncoder().encode(url)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        return #"{"mcpServers":{""# + name + #"":{"type":"http","url":"# + encodedURL.replacingOccurrences(of: "\\/", with: "/") + "}}}"
    }
}

/// Drafts a reply for a to-do with headless Claude Code (`claude -p`) that can
/// READ the user's mail, Teams, Jira and Confluence through the configured MCP
/// gateway (``DraftReplyGateway``), and cannot write to any of them.
///
/// The app must never be able to send anything. That rests on the flags in
/// ``arguments(model:mcpConfigPath:gateway:)``: only the gateway is loaded
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

    /// The only MCP server the run loads (default gateway). It carries M365, Jira and Confluence.
    static var mcpConfigJSON: String { DraftReplyGateway.default.mcpConfigJSON }

    /// Loads user settings (skills, CLAUDE.md) but runs none of the user's hooks.
    static let hookFreeSettings = #"{"disableAllHooks":true}"#

    /// Everything the run may use, for the default gateway.
    static var readOnlyTools: [String] { readOnlyTools(for: .default) }
    /// The deny list, for the default gateway.
    static var blockedTools: [String] { blockedTools(for: .default) }

    /// Everything the run may use. Read verbs only; a test enforces that.
    static func readOnlyTools(for gateway: DraftReplyGateway) -> [String] {
        ["Read", "Skill"] + readOnlyGatewayTools.map { gateway.toolPrefix + $0 }
    }

    /// Denied explicitly on top of the allowlist: every gateway tool that sends,
    /// replies, creates or changes something, plus the local write tools and the
    /// built-ins that reach the network or start another agent. A skill's
    /// `allowed-tools` frontmatter can grant tools while `Skill` is allowed;
    /// the deny list still wins over that.
    static func blockedTools(for gateway: DraftReplyGateway) -> [String] {
        blockedGatewayTools.map { gateway.toolPrefix + $0 } + [
            "Bash", "Write", "Edit", "WebFetch", "WebSearch", "NotebookEdit", "Agent", "Task",
        ]
    }

    private static let readOnlyGatewayTools: [String] = [
        "ping", "atlassian_fetch", "atlassian_search",
        "confluence_get_page", "confluence_get_page_footer_comments",
        "confluence_get_page_inline_comments", "confluence_search",
        "jira_get_issue", "jira_get_comments", "jira_search_issues",
        "microsoft365_get_email", "microsoft365_list_emails", "microsoft365_search_emails",
        "microsoft365_list_chats", "microsoft365_list_chat_messages",
        "microsoft365_get_event", "microsoft365_list_events",
        "microsoft365_find_user", "microsoft365_search_contacts", "microsoft365_get_contact",
    ]

    private static let blockedGatewayTools: [String] = [
        "bitbucket_add_pr_comment", "bitbucket_approve_pull_request", "bitbucket_create_pr_task",
        "bitbucket_create_pull_request", "bitbucket_decline_pull_request",
        "bitbucket_delete_pr_comment", "bitbucket_merge_pull_request",
        "bitbucket_remove_pr_change_request", "bitbucket_reopen_pr_comment",
        "bitbucket_request_pr_changes", "bitbucket_resolve_pr_comment", "bitbucket_run_pipeline",
        "bitbucket_unapprove_pull_request", "bitbucket_update_pr_comment",
        "bitbucket_update_pr_task", "bitbucket_update_pull_request", "confluence_append_to_page",
        "confluence_create_footer_comment", "confluence_create_inline_comment",
        "confluence_create_page", "confluence_update_page", "confluence_upload_attachment",
        "jira_add_comment", "jira_add_issues_to_sprint", "jira_add_worklog", "jira_create_issue",
        "jira_create_issue_link", "jira_create_request", "jira_delete_comment", "jira_edit_issue",
        "jira_transition_issue", "jira_update_comment", "microsoft365_add_invitees",
        "microsoft365_add_table_row", "microsoft365_cancel_event",
        "microsoft365_close_workbook_session", "microsoft365_complete_task",
        "microsoft365_copy_file", "microsoft365_create_chat", "microsoft365_create_contact",
        "microsoft365_create_draft", "microsoft365_create_event", "microsoft365_create_folder",
        "microsoft365_create_mail_folder", "microsoft365_create_task",
        "microsoft365_create_workbook_session", "microsoft365_delete_contact",
        "microsoft365_delete_event", "microsoft365_delete_file", "microsoft365_delete_item",
        "microsoft365_delete_mail_folder", "microsoft365_delete_task",
        "microsoft365_format_worksheet_range", "microsoft365_forward_email",
        "microsoft365_move_email", "microsoft365_move_emails", "microsoft365_move_file",
        "microsoft365_move_mail_folder", "microsoft365_rename_file",
        "microsoft365_rename_mail_folder", "microsoft365_reply_to_email",
        "microsoft365_respond_to_event", "microsoft365_send_chat_message",
        "microsoft365_send_draft", "microsoft365_send_email", "microsoft365_update_contact",
        "microsoft365_update_email", "microsoft365_update_event", "microsoft365_upload_file",
        "microsoft365_write_worksheet_range",
    ]

    /// The argument list of the tool-using draft run. A test locks it.
    static func arguments(
        model: String, mcpConfigPath: String, gateway: DraftReplyGateway = .default
    ) -> [String] {
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
            "--allowedTools", readOnlyTools(for: gateway).joined(separator: ","),
            "--disallowedTools", blockedTools(for: gateway).joined(separator: ","),
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
        let gateway = DraftReplyGateway.configured(in: defaults)
        let configURL = workingDirectory.appendingPathComponent(Self.mcpConfigFileName)
        try Data(gateway.mcpConfigJSON.utf8).write(to: configURL)

        let result = try await cli.run(
            executable: executable,
            arguments: Self.arguments(model: cli.model, mcpConfigPath: configURL.path, gateway: gateway),
            standardInput: DraftReplyPrompt.initial(context),
            workingDirectory: workingDirectory,
            timeout: Self.timeout
        )
        // As in `ClaudeCLIProvider.generate`: the launch proved the path, so
        // Settings shows it and the next run skips detection.
        await cli.persistResolvedPath(executable)
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
