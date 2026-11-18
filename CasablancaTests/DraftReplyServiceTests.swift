import XCTest
@testable import Casablanca

final class DraftReplyOutputTests: XCTestCase {
    func testChannelLineIsSplitOff() {
        let output = DraftReplyOutput.parse("Channel: email\n\nHoi Kim,")
        XCTAssertEqual(output, DraftReplyOutput(channel: "email", body: "Hoi Kim,"))
    }

    func testNoChannelLineKeepsTheWholeTextAsBody() {
        let output = DraftReplyOutput.parse("  Hoi Kim,\n\nGroet, Youri\n")
        XCTAssertNil(output.channel)
        XCTAssertEqual(output.body, "Hoi Kim,\n\nGroet, Youri")
    }
}

/// Every test goes through `FakeCommandRunner`: a real `claude` run is billed and
/// can reach Youri's live connectors.
final class DraftReplyServiceTests: XCTestCase {
    private static let stubPath = "/tmp/draft-reply-service-tests/claude"
    private static let gateway = "mcp__medicore-gateway__"

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "DraftReplyServiceTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Invocation contract

    /// Locks the whole flag list and both tool lists: a silent change here could
    /// make a send/write tool reachable from an app-launched run.
    func testArgumentsAreLocked() {
        let read = ["Read", "Skill"] + [
            "ping", "atlassian_fetch", "atlassian_search",
            "confluence_get_page", "confluence_get_page_footer_comments",
            "confluence_get_page_inline_comments", "confluence_search",
            "jira_get_issue", "jira_get_comments", "jira_search_issues",
            "microsoft365_get_email", "microsoft365_list_emails", "microsoft365_search_emails",
            "microsoft365_list_chats", "microsoft365_list_chat_messages",
            "microsoft365_get_event", "microsoft365_list_events",
            "microsoft365_find_user", "microsoft365_search_contacts", "microsoft365_get_contact",
        ].map { Self.gateway + $0 }
        let blocked = [
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
        ].map { Self.gateway + $0 } + ["Bash", "Write", "Edit"]

        XCTAssertEqual(DraftReplyService.readOnlyTools, read)
        XCTAssertEqual(DraftReplyService.blockedTools, blocked)
        XCTAssertEqual(DraftReplyService.arguments(model: "sonnet", mcpConfigPath: "/x"), [
            "-p",
            "--output-format", "json",
            "--model", "sonnet",
            "--no-session-persistence",
            "--strict-mcp-config",
            "--mcp-config", "/x",
            "--permission-mode", "default",
            "--setting-sources", "user",
            "--settings", #"{"disableAllHooks":true}"#,
            "--allowedTools", read.joined(separator: ","),
            "--disallowedTools", blocked.joined(separator: ","),
        ])
    }

    func testMCPConfigIsTheGatewayOnly() {
        XCTAssertEqual(
            DraftReplyService.mcpConfigJSON,
            #"{"mcpServers":{"medicore-gateway":{"type":"http","url":"https://mcptest.development.mcepd.nl/mcp"}}}"#
        )
    }

    /// Guards against someone adding a write tool to the allowlist: every gateway
    /// entry must be a read verb once its product prefix (`jira_` …) is dropped:
    /// the whole verb (`search`, `fetch`) or the verb plus `_` (`get_issue`).
    func testReadOnlyListHasOnlyReadVerbs() {
        let readVerbs = ["ping", "get", "list", "search", "fetch", "find"]
        for tool in DraftReplyService.readOnlyTools {
            guard tool.hasPrefix("mcp__") else {
                XCTAssertTrue(["Read", "Skill"].contains(tool), "unexpected built-in tool \(tool)")
                continue
            }
            XCTAssertTrue(tool.hasPrefix(Self.gateway), "tool outside the gateway: \(tool)")
            let name = String(tool.dropFirst(Self.gateway.count))
            let verb = name.firstIndex(of: "_").map { String(name[name.index(after: $0)...]) } ?? name
            XCTAssertTrue(
                readVerbs.contains { verb == $0 || verb.hasPrefix($0 + "_") },
                "not a read verb: \(tool)"
            )
        }
    }

    /// The tools that would send something or touch a mailbox on the user's behalf
    /// must be named explicitly, not only left off the allowlist.
    func testBlockedListNamesTheSendTools() {
        let mustBlock = [
            "microsoft365_send_email", "microsoft365_send_draft", "microsoft365_reply_to_email",
            "microsoft365_forward_email", "microsoft365_send_chat_message",
            "microsoft365_update_email", "jira_add_comment",
        ].map { Self.gateway + $0 }
        for tool in mustBlock {
            XCTAssertTrue(DraftReplyService.blockedTools.contains(tool), "not blocked: \(tool)")
        }
    }

    func testAllowAndBlockListsAreDisjoint() {
        XCTAssertTrue(
            Set(DraftReplyService.readOnlyTools).isDisjoint(with: DraftReplyService.blockedTools)
        )
    }

    // MARK: - draft

    func testDraftDecodesEnvelope() async throws {
        let runner = FakeCommandRunner.succeeding(
            standardOutput: #"{"result":"Channel: teams\n\nHi","is_error":false}"#
        )
        let context = Self.context

        let output = try await makeService(runner: runner).draft(context)

        XCTAssertEqual(output, DraftReplyOutput(channel: "teams", body: "Hi"))
        let call = try XCTUnwrap(runner.lastCall)
        XCTAssertEqual(call.executable, Self.stubPath)
        XCTAssertEqual(call.standardInput, DraftReplyPrompt.initial(context))
        XCTAssertEqual(call.timeout, 180)
        XCTAssertEqual(call.workingDirectoryFiles["mcp.json"], DraftReplyService.mcpConfigJSON)
        let directory = try XCTUnwrap(call.workingDirectory)
        XCTAssertEqual(
            call.arguments,
            DraftReplyService.arguments(
                model: "sonnet",
                mcpConfigPath: directory.appendingPathComponent("mcp.json").path
            )
        )
        // The temp dir (with the MCP config) is gone once the run returns.
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testDraftUsesTheModelAndPathSettings() async throws {
        defaults.set("opus", forKey: AppPreferenceKey.draftReplyModel)
        defaults.set("/custom/claude", forKey: AppPreferenceKey.claudeCLIPath)
        let runner = FakeCommandRunner.succeeding(standardOutput: #"{"result":"Hi","is_error":false}"#)
        let preferred = PreferredPathRecorder()
        let service = DraftReplyService(runner: runner, defaults: defaults) { path in
            preferred.record(path)
            return Self.stubPath
        }

        _ = try await service.draft(Self.context)

        XCTAssertEqual(preferred.paths, ["/custom/claude"])
        let arguments = try XCTUnwrap(runner.lastCall?.arguments)
        let modelIndex = try XCTUnwrap(arguments.firstIndex(of: "--model"))
        XCTAssertEqual(arguments[modelIndex + 1], "opus")
    }

    /// Like `ClaudeCLIProvider.generate`: an auto-detected binary is written back to
    /// the CLI path setting, so Settings shows it and the next run skips the scan.
    func testDraftPersistsTheResolvedPath() async throws {
        XCTAssertNil(defaults.string(forKey: AppPreferenceKey.claudeCLIPath))
        let runner = FakeCommandRunner.succeeding(standardOutput: #"{"result":"Hi","is_error":false}"#)

        _ = try await makeService(runner: runner).draft(Self.context)

        XCTAssertEqual(defaults.string(forKey: AppPreferenceKey.claudeCLIPath), Self.stubPath)
    }

    func testDraftSurfacesCLIError() async {
        let runner = FakeCommandRunner.succeeding(exitCode: 1, standardError: "Not logged in")
        await XCTAssertThrowsErrorAsync(try await makeService(runner: runner).draft(Self.context)) { error in
            guard case LLMProviderError.requestFailed(_, _, let message) = error else {
                return XCTFail("expected requestFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("Not logged in"), "got: \(message)")
        }
    }

    func testDraftErrorEnvelopeIsReported() async {
        let runner = FakeCommandRunner.succeeding(
            standardOutput: #"{"result":"MCP server failed","is_error":true}"#
        )
        await XCTAssertThrowsErrorAsync(try await makeService(runner: runner).draft(Self.context)) { error in
            guard case LLMProviderError.requestFailed(_, .backendError, let message) = error else {
                return XCTFail("expected backendError, got \(error)")
            }
            XCTAssertTrue(message.contains("MCP server failed"), "got: \(message)")
        }
    }

    func testDraftWithoutExecutableIsInvalidEndpoint() async {
        let runner = FakeCommandRunner.succeeding(standardOutput: "{}")
        let service = DraftReplyService(runner: runner, defaults: defaults) { _ in nil }
        await XCTAssertThrowsErrorAsync(try await service.draft(Self.context)) { error in
            guard case LLMProviderError.invalidEndpoint = error else {
                return XCTFail("expected invalidEndpoint, got \(error)")
            }
        }
        XCTAssertNil(runner.lastCall)
    }

    // MARK: - revise

    /// Revising is a tool-less completion: the draft is already in hand, so the
    /// run gets no MCP servers and no tools at all.
    func testReviseIsAToolLessCompletion() async throws {
        defaults.set(Self.stubPath, forKey: AppPreferenceKey.claudeCLIPath)
        let runner = FakeCommandRunner.succeeding(
            standardOutput: #"{"result":"Channel: email\n\nKort.","is_error":false}"#
        )
        let context = Self.context

        let output = try await makeService(runner: runner)
            .revise(draft: "Channel: email\n\nLang.", steer: "shorter", context: context)

        XCTAssertEqual(output, DraftReplyOutput(channel: "email", body: "Kort."))
        let call = try XCTUnwrap(runner.lastCall)
        XCTAssertEqual(call.executable, Self.stubPath)
        XCTAssertEqual(call.arguments, ClaudeCLIProvider.completionArguments(model: "sonnet"))
        XCTAssertEqual(
            call.standardInput,
            DraftReplyPrompt.revision(draft: "Channel: email\n\nLang.", steer: "shorter", context: context)
        )
        XCTAssertEqual(call.timeout, 180)
    }

    // MARK: - Fixtures

    private static let context = DraftReplyContext(
        todoText: "Reply to Kim",
        owner: nil, dueDate: nil,
        sourceRef: "jira:IO-1234",
        meetingTitle: nil, meetingDate: nil, meetingSummary: nil, transcriptExcerpt: nil
    )

    private func makeService(runner: FakeCommandRunner) -> DraftReplyService {
        DraftReplyService(runner: runner, defaults: defaults) { _ in Self.stubPath }
    }
}

/// Records the preferred path the service hands its resolver.
private final class PreferredPathRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var paths: [String] { lock.withLock { recorded } }

    func record(_ path: String) {
        lock.withLock { recorded.append(path) }
    }
}
