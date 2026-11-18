# To-dos Only + Draft Reply Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the Approvals inbox and give every open to-do an on-demand, read-only Claude Code draft reply, with a source link and meeting link.

**Architecture:** Approvals code is deleted outright. Obsidian task lines gain an optional trailing `🔗 scheme:ref` token, stored as `TodoItem.sourceRef` (schema V4). A new `DraftReplyService` shells out to `claude -p` through the existing `CommandRunning` seam with a locked, read-only flag set; a `DraftReplyViewModel` drives a `DraftReplySheet` opened from the to-do row. Revise is a tool-less completion through `ClaudeCLIProvider`.

**Tech Stack:** Swift / SwiftUI / SwiftData (macOS), XCTest, Claude Code CLI, `xcodeproj` Ruby gem for project file edits.

**Spec:** `docs/superpowers/specs/2026-11-18-todos-only-draft-reply-design.md`

## Global Constraints

- The app never sends anything: no send/reply/forward/create/update/delete/comment/transition tool reachable from any app-launched run.
- Drafts are never persisted, listed or badged.
- Obsidian stays the source of truth; every task line must round-trip byte-identical through parse → render.
- Draft run flags (verified by a live spike on 2026-11-18): `-p --output-format json --model <m> --no-session-persistence --strict-mcp-config --mcp-config <file> --permission-mode default --setting-sources user --settings {"disableAllHooks":true} --allowedTools <read list> --disallowedTools <write list>`.
- Generated MCP config: `{"mcpServers":{"medicore-gateway":{"type":"http","url":"https://mcptest.development.mcepd.nl/mcp"}}}` (auth is picked up from the user's stored OAuth token — verified).
- Draft model setting key `draftReplyModel`, values `haiku|sonnet|opus`, default `sonnet`. Draft timeout 180 s. CLI path reuses `AppPreferenceKey.claudeCLIPath`.
- "Continue in Claude Code" launches interactive `claude --permission-mode default "<prompt>"` in `~`.
- New Swift files must be added to the Xcode project with `ruby scripts/add-files-to-xcodeproj.rb <paths>`; deleted ones removed with the script created in Task 1.
- Test command (from README): `xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -derivedDataPath .build/test -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''` — referred to below as **TEST**; add `-only-testing:CasablancaTests/<Class>` for a single class.
- SwiftUI view changes must be verified in the running app, not only by build + tests (project lesson: views pass tests and break at runtime).
- No PR, push or merge without Youri's explicit go-ahead.

## Review Focus

1. A Topdesk ref with a space (`🔗 topdesk:MC2611 0123`) and a ref after the id comment boundary must round-trip exactly — pinned in Task 2.
2. A generic to-do ticked done/undone keeps its `🔗` link (the `setCompleted` path rebuilds the `TaskLine` by hand at `ObsidianTodoSyncService.swift:197-200`) — pinned in Task 3.
3. Closing the sheet mid-generation terminates the `claude` process (no orphan, no late state write) — pinned in Task 5.
4. `claude` missing, not logged in, or gateway auth expired → the sheet shows an error with the CLI's message and Retry, never an endless spinner — pinned in Task 5.
5. A to-do with no meeting and no source link still drafts (prompt omits those sections, sheet shows no links) — pinned in Tasks 4 and 5.

---

### Task 1: Remove Approvals

**Files:**
- Create: `scripts/remove-files-from-xcodeproj.rb`
- Delete: `Casablanca/Views/ActionQueueView.swift`, `Casablanca/Views/ActionCards/` (all), `Casablanca/Models/ActionQueue.swift`, `Casablanca/Models/ActionQueueDisplay.swift`, `Casablanca/Models/ActionCardBodies/` (all), `Casablanca/Services/ActionQueueModel.swift`, `Casablanca/Services/ActionQueueStore.swift`, `Casablanca/Services/DockBadge.swift`, and tests `ActionCardBodyTests`, `ActionQueueDisplayTests`, `ActionQueueModelTests`, `ActionQueueSectionStateTests`, `ActionQueueStoreTests` (+ any `DockBadge` test)
- Modify: `Casablanca/CasablancaApp.swift` (~215-230 menu-bar pending count, 248 `actionQueueModel`, 364-366 wiring), `Casablanca/Views/SidebarView.swift` (`SidebarDestination.actionQueue` + its row), `Casablanca/Views/ContentView.swift:205-206`, `Casablanca/ViewModels/GlobalSearchViewModel.swift` (`approvalItems`, `matchingApprovals`, init param), `Casablanca/Views/GlobalSearchView.swift` (Approvals section), `Casablanca/Views/SettingsView.swift:15,200-262` (path section + `onChange`), `Casablanca/Models/Meeting.swift:28` (`actionQueuePath` key), `Casablanca/Utilities/Logging.swift` (queue log category), `CasablancaTests/AskViewModelTests.swift`, `CasablancaTests/GlobalSearchViewModelTests.swift`

**Interfaces:**
- Produces: `SidebarDestination` = `dashboard | todos | ask | meeting(UUID)`; `GlobalSearchViewModel.init` without `actionQueueModel`.
- `scripts/remove-files-from-xcodeproj.rb <paths…>`: removes each file's reference and build-file entries from both targets; idempotent; mirrors the add script's style.

- [ ] **Step 1:** Write `scripts/remove-files-from-xcodeproj.rb`; run it on every file listed under Delete, then `git rm` them.
- [ ] **Step 2:** Remove every remaining reference: `grep -rn "ActionQueue\|ActionCard\|actionQueue\|DockBadge\|approvalItems\|matchingApprovals" Casablanca CasablancaTests` must print nothing.
- [ ] **Step 3:** Run **TEST**. Expected: build succeeds, all tests pass (count drops only by the deleted test classes; note before/after counts).
- [ ] **Step 4:** Build and launch the app; confirm the sidebar has no Approvals row, Settings has no action-queue section, global search works, Dock shows no badge, To-Dos view opens.
- [ ] **Step 5:** Commit `refactor: remove the Approvals inbox`.

### Task 2: `🔗` source link in Obsidian task lines

**Files:**
- Modify: `Casablanca/Services/ObsidianTodoMarkdown.swift`
- Test: `CasablancaTests/ObsidianTodoMarkdownTests.swift`

**Interfaces:**
- Produces: `TaskLine.link: String?` (default `nil`, the raw `scheme:ref` without the emoji); `suffix(owner:due:timestamp:link:) -> String` (`link` defaulted to `nil` so existing callers compile); `splittingSuffix` returns a 5-tuple adding `link`; `withID` keeps `link`.
- Syntax: ` 🔗 <scheme>:<ref>` is always the **last** suffix part, after `[timestamp]`. Schemes: `outlook|teams|jira|topdesk|url`. `<ref>` is everything after `scheme:` to the end of the text (may contain spaces, never empty). An unknown scheme or a `🔗` not at a ` 🔗 <scheme>:` boundary stays in the text. A link alone does **not** enable owner parsing (owner still requires due or timestamp).

- [ ] **Step 1: Write failing tests** in `ObsidianTodoMarkdownTests`:
  - `testLinkOnlyLineParsesAndRoundTrips`: `- [ ] Reply to Kim 🔗 outlook:AAMkAD123 <!-- casablanca-todo: <UUID> -->` → text `Reply to Kim`, link `outlook:AAMkAD123`, owner/due/timestamp nil; rendering the generic document reproduces the line exactly.
  - `testFullSuffixWithLinkRoundTrips`: `Plan demo — Youri 📅 2026-11-20 [12:34] 🔗 jira:IO-1234` → owner `Youri`, due `2026-11-20`, timestamp `12:34`, link `jira:IO-1234`; round-trips.
  - `testTopdeskRefWithSpaceRoundTrips`: `Antwoord sturen 🔗 topdesk:MC2611 0123` → link `topdesk:MC2611 0123`; round-trips.
  - `testUnknownSchemeStaysInText`: `Check 🔗 ftp:foo` → text `Check 🔗 ftp:foo`, link nil.
  - `testLinkDoesNotEnableOwner`: `Bel Kim — dringend 🔗 teams:19:abc` → text `Bel Kim — dringend`, owner nil, link `teams:19:abc`.
- [ ] **Step 2:** Run **TEST** `-only-testing:CasablancaTests/ObsidianTodoMarkdownTests`. Expected: the five new tests FAIL.
- [ ] **Step 3:** Implement: in `splittingSuffix` strip a trailing link first (search backwards for ` 🔗 ` followed by a known scheme and `:` and a non-empty ref), then run the existing timestamp/due/owner logic on the rest; extend `suffix`, `render`, `parseTaskLine`, `withID`. (`taskLine(for:)` / `suffix(for:)` start reading `sourceRef` in Task 3.)
- [ ] **Step 4:** Run the class again. Expected: all PASS (including every pre-existing test).
- [ ] **Step 5:** Commit `feat: parse and render a 🔗 source link on to-do lines`.

### Task 3: `TodoItem.sourceRef`, schema V4, sync threading, row chip

**Files:**
- Modify: `Casablanca/Models/TodoItem.swift`, `Casablanca/Models/CasablancaSchema.swift`, `Casablanca/Services/ObsidianTodoMarkdown.swift` (`taskLine(for:)`, `suffix(for:)` read `sourceRef`), `Casablanca/Services/ObsidianTodoSyncService.swift` (`applySuffixFields` ~466-471, rendered-line comparison ~416, `setCompleted` TaskLine rebuild ~197-200, any other `TaskLine(` construction — grep `timestamp: ` in the file), `Casablanca/Views/TodosView.swift` (`TodoRow`, `TodoRowPresentation`)
- Create: `Casablanca/Models/TodoSourceLink.swift`
- Test: `CasablancaTests/ObsidianTodoSyncServiceTests.swift`, `CasablancaTests/TodoSourceLinkTests.swift`, existing schema-migration test file if one exists (grep `CasablancaMigrationPlan` in CasablancaTests)

**Interfaces:**
- Consumes: `TaskLine.link`, `suffix(…link:)` from Task 2.
- Produces: `TodoItem.sourceRef: String?`; `CasablancaSchemaV4` (version 4.0.0, same models) + `.lightweight(V3 → V4)` stage; container setup uses V4.
- `struct TodoSourceLink { enum Scheme: String { outlook, teams, jira, topdesk, url }; let scheme: Scheme; let ref: String; init?(_ raw: String); var label: String; var url: URL? }`. Labels: `Outlook email`, `Teams chat`, `Jira IO-1234`, `Topdesk MC2611 0123`, url → host. `url`: jira → `https://tenzinger.atlassian.net/browse/<ref>`, url → `URL(string: ref)`, others nil.
- `TodoRowPresentation.sourceLink: TodoSourceLink?`.

- [ ] **Step 1: Write failing tests:**
  - `TodoSourceLinkTests`: `jira:IO-1234` → label `Jira IO-1234`, url `https://tenzinger.atlassian.net/browse/IO-1234`; `topdesk:MC2611 0123` → label `Topdesk MC2611 0123`, url nil; `bogus:x` → nil; `url:https://example.com/a` → url host label `example.com`.
  - `ObsidianTodoSyncServiceTests.testGenericTodoLinkSurvivesCompletionToggle`: generic file line with `🔗 jira:IO-1` → after refresh `sourceRef == "jira:IO-1"`; `setCompleted(true)` then `setCompleted(false)`; file still contains `🔗 jira:IO-1` and the row's `sourceRef` is unchanged.
  - `testMeetingTodoLinkImported`: a meeting file's `## Action Items` line with a link → row `sourceRef` set.
  - Migration test (if a V3 store fixture/test exists, extend it): V3 store opens under V4 with `sourceRef == nil`.
- [ ] **Step 2:** Run the three test classes. Expected: new tests FAIL.
- [ ] **Step 3:** Implement the field, V4 schema + stage, `applySuffixFields` sets `sourceRef = task.link`, the rendered-line comparison and every `TaskLine` construction carry the link, `taskLine(for:)` reads `sourceRef`; add `TodoSourceLink.swift` (add to project).
- [ ] **Step 4:** In `TodoRow`, under the text next to the meeting subtitle, show `sourceLink.label` as a `.caption` chip with `Color.textTertiary`; when `url != nil` it is a `Link`/button opening the URL (does not trigger the row's meeting navigation).
- [ ] **Step 5:** Run **TEST** (full). Expected: all PASS.
- [ ] **Step 6:** Launch the app with a hand-edited generic todo line containing `🔗 jira:IO-1234`; confirm the chip shows and opens Jira; tick and untick it; confirm the Obsidian line keeps the link.
- [ ] **Step 7:** Commit `feat: store and show a to-do's source link (schema V4)`.

### Task 4: `DraftReplyService` (prompt, flags, output)

**Files:**
- Create: `Casablanca/Services/DraftReply/DraftReplyContext.swift`, `DraftReplyPrompt.swift`, `DraftReplyService.swift`
- Modify: `Casablanca/Services/LLM/ClaudeCLIProvider.swift` (make `resolvedExecutablePath(preferring:)` internal, unchanged behavior), `Casablanca/Models/Meeting.swift` (`AppPreferenceKey.draftReplyModel = "draftReplyModel"`)
- Test: `CasablancaTests/DraftReplyPromptTests.swift`, `CasablancaTests/DraftReplyServiceTests.swift`

**Interfaces:**
- `struct DraftReplyContext: Equatable { let todoText: String; let owner: String?; let dueDate: Date?; let sourceRef: String?; let meetingTitle: String?; let meetingDate: Date?; let meetingSummary: String?; let transcriptExcerpt: String?; init(todo: TodoItem) }` — `transcriptExcerpt`: whole `meeting.transcript` if ≤ 300_000 chars, else the 60_000-char window centered on the first occurrence of the `sourceTimestamp` label in the transcript, else the first 60_000 chars.
- `enum DraftReplyPrompt { static func initial(_ c: DraftReplyContext) -> String; static func revision(draft: String, steer: String, context: DraftReplyContext) -> String }`
- `struct DraftReplyOutput: Equatable { let channel: String?; let body: String; static func parse(_ raw: String) -> DraftReplyOutput }` — a first line `Channel: <x>` is split off; otherwise `channel == nil`, body = trimmed raw.
- `struct DraftReplyService { init(runner: CommandRunning = ProcessCommandRunner(), defaults: UserDefaults = .standard, resolveExecutable: …); static let readOnlyTools: [String]; static let blockedTools: [String]; static let mcpConfigJSON: String; static func arguments(model: String, mcpConfigPath: String) -> [String]; func draft(_ context: DraftReplyContext) async throws -> DraftReplyOutput; func revise(draft: String, steer: String, context: DraftReplyContext) async throws -> DraftReplyOutput }`
  - `draft`: writes `mcpConfigJSON` into a fresh temp dir (also the working directory), runs with `arguments(...)`, prompt on stdin, timeout 180; decodes the JSON envelope the same way `ClaudeCLIProvider.generate` does (non-zero exit / `is_error` / empty → `LLMProviderError` with the CLI's message); deletes the temp dir.
  - `revise`: `ClaudeCLIProvider(endpoint: claudeCLIPath, model: draftModel).generate(prompt: DraftReplyPrompt.revision(…), …)` → `DraftReplyOutput.parse`.
  - `readOnlyTools`: `Read`, `Skill`, and `mcp__medicore-gateway__` + each of: `ping, atlassian_fetch, atlassian_search, confluence_get_page, confluence_get_page_footer_comments, confluence_get_page_inline_comments, confluence_search, jira_get_issue, jira_get_comments, jira_search_issues, microsoft365_get_email, microsoft365_list_emails, microsoft365_search_emails, microsoft365_list_chats, microsoft365_list_chat_messages, microsoft365_get_event, microsoft365_list_events, microsoft365_find_user, microsoft365_search_contacts, microsoft365_get_contact`.
  - `blockedTools`: `mcp__medicore-gateway__` + `microsoft365_send_email, microsoft365_send_draft, microsoft365_reply_to_email, microsoft365_forward_email, microsoft365_create_draft, microsoft365_send_chat_message, microsoft365_create_chat, microsoft365_respond_to_event, microsoft365_create_event, microsoft365_update_event, jira_add_comment, jira_transition_issue, jira_edit_issue, jira_create_issue, confluence_create_footer_comment, confluence_create_inline_comment, confluence_update_page, confluence_create_page`, plus `Bash, Write, Edit`.

- [ ] **Step 1: Write failing tests:**
  - `DraftReplyPromptTests.testInitialPromptWithSourceAndMeeting`: contains the to-do text, `jira:IO-1234`, an instruction to fetch the source, the meeting title, summary, the transcript excerpt, "Do not send", "language of the source", and the `Channel:` output rule.
  - `testInitialPromptWithoutMeetingOrSource`: contains no `Meeting` section header and no fetch instruction; still contains "Do not send".
  - `testRevisionPromptCarriesDraftAndSteer`.
  - `testTranscriptWindowCentersOnTimestamp`: 400_000-char transcript with `[45:00]` in the middle → excerpt length 60_000 and contains `[45:00]`.
  - `DraftReplyOutputTests` (in the service test file): `"Channel: email\n\nHoi Kim,"` → channel `email`, body `Hoi Kim,`; no channel line → channel nil.
  - `DraftReplyServiceTests.testArgumentsAreLocked`: `arguments(model: "sonnet", mcpConfigPath: "/x")` equals the exact Global Constraints flag list with `--allowedTools` joined by `,` and `--disallowedTools` joined by `,`.
  - `testReadOnlyListHasOnlyReadVerbs`: every `mcp__` entry in `readOnlyTools` has a suffix starting with `ping|get_|list_|search_|fetch|find_` (after the product prefix) — guards against someone adding a write tool.
  - `testAllowAndBlockListsAreDisjoint`.
  - `testDraftDecodesEnvelope` (fake `CommandRunning` returning `{"result":"Channel: teams\n\nHi","is_error":false}`) → output channel `teams`; also asserts the runner got stdin = `DraftReplyPrompt.initial(ctx)` and a working directory containing `mcp.json` with `mcpConfigJSON`.
  - `testDraftSurfacesCLIError`: exit 1, stderr `Not logged in` → throws `LLMProviderError` whose message contains `Not logged in`.
- [ ] **Step 2:** Run both classes. Expected: FAIL (types missing).
- [ ] **Step 3:** Implement the four types and the `ClaudeCLIProvider` visibility change; add files to the project.
- [ ] **Step 4:** Run both classes, then **TEST** (full). Expected: PASS.
- [ ] **Step 5: Live check** (one small billed run): in a temp dir holding `mcp.json`, run `claude` with exactly the `arguments(model: "haiku", mcpConfigPath: "mcp.json")` list and stdin "Call ping, then try microsoft365_send_draft; report both". Expected: ping returns `"status":"ok"`, the send tool is reported unavailable. Paste the result into the commit body.
- [ ] **Step 6:** Commit `feat: read-only Claude Code draft reply service`.

### Task 5: `DraftReplyViewModel`

**Files:**
- Create: `Casablanca/Services/DraftReply/DraftReplyViewModel.swift`
- Test: `CasablancaTests/DraftReplyViewModelTests.swift`

**Interfaces:**
- Consumes: `DraftReplyService`, `DraftReplyContext`, `DraftReplyOutput` (Task 4). For testability `DraftReplyViewModel.init(context:, drafter: DraftReplyDrafting)` where `protocol DraftReplyDrafting { func draft(_:) async throws -> DraftReplyOutput; func revise(draft:steer:context:) async throws -> DraftReplyOutput }` and `DraftReplyService` conforms.
- Produces: `@MainActor @Observable final class DraftReplyViewModel { enum Phase: Equatable { case generating(String), ready, failed(String) }; private(set) var phase; var draftText: String; var steer: String; private(set) var channel: String?; var isEdited: Bool; var canRevise: Bool; func start(); func revise(); func startOver(); func cancel() }`
  - `start()` runs `draft`; progress label `"Reading the source…"` when `sourceRef != nil` else `"Writing the draft…"`.
  - `canRevise` = phase `.ready` and (`!steer.trimmed.isEmpty` or `isEdited`).
  - `revise()` sends current `draftText` (with edits) + `steer`; label `"Revising…"`; on success replaces text, clears `steer`, `isEdited = false`.
  - `startOver()` = `start()` (the confirm-before-discard dialog lives in the view, driven by `isEdited`).
  - `cancel()` cancels the in-flight `Task`; a result arriving after cancel is ignored.
  - Failure → `.failed(message)` using `LocalizedError.errorDescription` or `localizedDescription`.

- [ ] **Step 1: Write failing tests** with a fake drafter (controllable continuation):
  - `testStartGoesGeneratingThenReady` (text/channel set, `isEdited == false`).
  - `testFailureShowsMessage` (drafter throws `LLMProviderError` with "Not logged in" → `.failed` containing it).
  - `testCancelDuringGenerationIgnoresLateResult` (cancel, then fake resumes → phase not `.ready`, text empty, fake observed cancellation).
  - `testReviseSendsEditedDraftAndSteer` (edit text, steer "korter" → fake received the edited text and "korter"; steer cleared after).
  - `testCanReviseRequiresSteerOrEdit`.
- [ ] **Step 2:** Run. Expected FAIL.
- [ ] **Step 3:** Implement; add file to project.
- [ ] **Step 4:** Run the class, then **TEST**. Expected PASS.
- [ ] **Step 5:** Commit `feat: draft reply view model`.

### Task 6: Draft sheet, row action, Continue in Claude Code, Settings

**Files:**
- Create: `Casablanca/Views/DraftReply/DraftReplySheet.swift`, `Casablanca/Services/DraftReply/ClaudeCodeLauncher.swift`
- Modify: `Casablanca/Views/TodosView.swift` (`TodoRow`: hover-revealed `text.bubble` button + `.contextMenu` item "Draft reply"; only when `todo.status == .accepted && !todo.isCompleted`; presents the sheet), `Casablanca/Views/SettingsView.swift` (new "Draft replies" section: model picker haiku/sonnet/opus bound to `draftReplyModel`, read-only display of the resolved `claudeCLIPath`)
- Test: `CasablancaTests/ClaudeCodeLauncherTests.swift`

**Interfaces:**
- Consumes: `DraftReplyViewModel` (Task 5), `TodoRowPresentation.meetingSubtitle/meetingID/sourceLink` (Task 3).
- `enum ClaudeCodeLauncher { static func commandFileContents(claudePath: String, prompt: String) -> String; static func launch(claudePath: String, prompt: String) throws }` — writes a `0700` `.command` file in a temp dir: `#!/bin/zsh`, `cd ~`, `exec '<claudePath>' --permission-mode default "$(cat '<promptfile>')"` (prompt in a sibling file, never interpolated into the script), then `NSWorkspace.shared.open(url)` (opens Terminal).
- Sheet layout (per `DESIGN_SYSTEM.md`): header = to-do text, meeting button (`meetingSubtitle`, closes sheet and sets `viewModel.sidebarSelection = .meeting(id)`), source chip; body = progress + Cancel / `TextEditor` bound to `draftText` with channel caption / error + Retry; footer = steer `TextField`, primary **Revise** (disabled unless `canRevise`) with a menu holding **Start over** (confirmation dialog "Discard your edits?" when `isEdited`), **Copy** (NSPasteboard, toast "Draft copied"), **Continue in Claude Code** (prompt = `DraftReplyPrompt.revision(draft:steer:context:)` when a draft exists, else `initial`). `onDisappear` → `cancel()`. Min size ~560×480.

- [ ] **Step 1: Write failing test** `testCommandFileQuotesPromptViaFile`: contents contain `--permission-mode default`, `cd ~`, the quoted claude path, and do NOT contain the prompt text itself (prompt with `'; rm -rf ~` stays only in the prompt file).
- [ ] **Step 2:** Run. Expected FAIL. **Step 3:** Implement launcher. **Step 4:** Run → PASS.
- [ ] **Step 5:** Build the sheet, row action and Settings section; add files to the project. Run **TEST** → PASS.
- [ ] **Step 6: Verify in the running app** (required): open To-Dos → hover a to-do → Draft reply opens the sheet; spinner shows; Cancel closes it and `pgrep -f "claude -p"` shows no leftover process; a real draft for a to-do with a meeting appears (meeting button navigates); type a steer → Revise works and keeps edits; Start over with edits asks first; Copy puts text on the clipboard; Continue in Claude Code opens Terminal in ask mode with the prompt; no button on Done or Review items; Settings shows the model picker. Check the view at the narrowest window width for layout crashes.
- [ ] **Step 7:** Commit `feat: draft reply sheet on to-dos`.

### Task 7: Final verification

- [ ] **Step 1:** Run **TEST** (full); record the test count.
- [ ] **Step 2:** `grep -rn "action-queue\|ActionQueue" Casablanca CasablancaTests docs/action-queue-approvals.md` — app code clean; mark `docs/action-queue-approvals.md` as retired (one-line header pointing to this spec) rather than deleting it (project 2 removes the pipeline).
- [ ] **Step 3:** Update `README.md`/`CHANGELOG.md` "Unreleased": Approvals removed, Draft reply added, `🔗` syntax documented.
- [ ] **Step 4:** Commit `docs: changelog for to-dos only + draft replies`. Do not release, push or open a PR — report to Youri.
