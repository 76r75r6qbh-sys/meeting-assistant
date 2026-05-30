# Casablanca Approval Inbox + JSON Action Queue

## Context

Today Youri's executive copilot (Claude, via `/morning`, `/end-of-day`, executive triage, Topdesk handling)
prepares draft emails, Jira stories/comments, and Teams messages and tracks them in a prose markdown file
`~/.claude/projects/-Users-youri-broekhuizen/memory/action-queue.md`. Approving or declining those drafts
means re-reading that file in a Claude session. Youri wants a **central place inside the Casablanca macOS
app** to see and act on this queue — primarily to approve/decline prepared drafts.

The solution: a machine-readable **JSON action queue** that is the single source of truth (the prose
`action-queue.md` is retired). The Claude skills *produce* drafts and *execute* approved ones; Casablanca is
the *approval UI* — it reads the queue, shows draft bodies, and writes back approve/decline/defer/complete
decisions. Casablanca never sends anything itself; Claude picks up `approved` items on its next run /
via `/review-action-queue` and executes them through MCP, then marks them done.

Casablanca is **not sandboxed** (no `com.apple.security.app-sandbox` entitlement in
`Casablanca/Casablanca.entitlements`), so it can read/write the JSON in `~/.claude/...` directly with
`FileManager`, exactly as it already does for the Obsidian vault.

---

## The contract: `action-queue.json`

Default location (configurable in Settings, like the Obsidian vault path):
`~/.claude/projects/-Users-youri-broekhuizen/memory/action-queue.json`

```jsonc
{
  "version": 1,
  "updatedAt": "2026-05-30T09:00:00Z",      // ISO-8601 UTC; informational
  "items": [
    {
      "id": "AQ-20260529-01",               // stable id, AQ-YYYYMMDD-NN convention
      "kind": "draft",                       // "draft" = has an approvable body; "task" = tracking only
      "draftType": "email",                  // "email"|"jira"|"teams"|"other"; null for tasks
      "title": "Reply to Luuk Geijsen — BergOp doorontwikkeling",
      "priority": "medium",                  // "low"|"medium"|"high"
      "target": "email: l.geijsen@praktikon.nl",   // human-readable destination
      "source": "Luuk Geijsen 2026-05-29 13:44 — \"RE: Doorontwikkeling Bergop\"",
      "rationale": "Praktikon wil de BergOp-koppeling vernieuwen; dev-sessie gevraagd.",
      "body": "Hi Luuk,\n\n...",            // the draft Youri approves (kind=draft); "" for tasks
      "proposedAction": "Send this reply, then schedule a dev session.",
      "status": "pending",                   // see status set below
      "decisionNote": null,                  // optional note/edit reason from Youri
      "createdAt": "2026-05-29T13:44:00Z",
      "decidedAt": null,                     // set by the app when Youri decides
      "executedAt": null,                    // set by Claude after executing
      "executionResult": null                // free-text outcome from Claude
    }
  ]
}
```

### Status set (these are the filterable "sections")

| status            | meaning                                   | who sets it |
|-------------------|-------------------------------------------|-------------|
| `pending`         | draft awaiting approve/decline            | Claude (create) |
| `approved`        | Youri approved → awaiting Claude execution| App |
| `declined`        | Youri declined                            | App |
| `follow_up`       | tracked action, this week                 | Claude / App |
| `awaiting_context`| blocked on external input                 | Claude / App |
| `deferred`        | postponed                                 | App / Claude |
| `completed`       | executed / done                           | Claude (exec) / App (tasks) |

### Write discipline (both sides)

- **Read-modify-write the whole file by `id`** immediately before saving; never hold a stale copy. Single
  local user, human-paced edits → last-writer races are rare; re-reading first closes the window.
- The app decodes leniently (all decision/exec fields optional, unknown enum values fall back to a default
  case) and **re-encodes the entire decoded item** (all known fields) — never a partial patch. v1 round-trips
  the full known schema; preserving *truly-unknown* JSON keys is explicitly out of scope (the schema is
  shared between both sides via `action-queue-schema.md`, so there are none in practice).
- Atomic writes (`Data.write(to:options:.atomic)` / `String.write(atomically:true)`).
- App writes only: `status`, `body` (if edited), `decisionNote`, `decidedAt`, plus `updatedAt`.
- Claude writes: new items; on `approved` → execute → `completed` + `executedAt` + `executionResult`;
  may archive `declined`. Claude reads `decidedAt`/`status` to find what to act on.

---

## Part A — Casablanca app

### A1. Models — `Casablanca/Models/ActionQueue.swift` (new)
- `struct ActionQueueDocument: Codable { var version: Int; var updatedAt: Date?; var items: [ActionQueueItem] }`
- `struct ActionQueueItem: Codable, Identifiable, Hashable` with all fields above. Decision/exec fields and
  `draftType`/`decisionNote` optional. Provide a custom `Decodable` (or default-tolerant defaults) so missing
  keys don't fail decode.
- Enums (String-backed, `Codable`). Implement `init(from:)` as
  `self = Self(rawValue: try container.decode(String.self)) ?? .<fallback>` so unknown values don't fail decode
  (note: an unknown value is rewritten as the fallback's rawValue on re-save — acceptable for v1).
  `ActionItemKind { draft, task }` (fallback `task`), `ActionDraftType { email, jira, teams, other }`
  (fallback `other`), `ActionItemPriority { low, medium, high }` (fallback `medium`),
  `ActionItemStatus { pending, approved, declined, followUp, awaitingContext, deferred, completed }`
  (fallback `pending`; rawValues `follow_up`, `awaiting_context`).
- Dates: use `JSONDecoder.dateDecodingStrategy = .custom` (and matching `.custom` encode) that tries an
  `ISO8601DateFormatter` **with** `.withFractionalSeconds` then **without** — a single formatter cannot parse
  both `...Z` and `...123Z`. Encode without fractional seconds. Define both formatters once (static).

### A2. Store — `Casablanca/Services/ActionQueueStore.swift` (new)
Static enum, mirroring `ObsidianTodoSyncService`'s style. Pure functions, all take
`userDefaults:`/`fileManager:` for testability.
- `static func fileURL(userDefaults:) -> URL?` — reads `AppPreferenceKey.actionQueuePath`; if empty, returns
  the expanded default path. Expand `~` via `(path as NSString).expandingTildeInPath`.
- `static func load(userDefaults:fileManager:) throws -> ActionQueueDocument` — returns empty doc if file
  absent; decodes leniently.
- `static func setStatus(_:for id:decisionNote:userDefaults:fileManager:) throws` — read-modify-write: load,
  find item by id, set `status` + `decidedAt = Date()` (+ optional `decisionNote`), bump `updatedAt`, atomic save.
- `static func updateBody(_:for id:...) throws` — for inline draft edits before approving.
- Convenience: `approve(id:editedBody:)`, `decline(id:note:)`, `postpone(id:)` (NOT `defer` — reserved word),
  `complete(id:)`, `reopen(id:)` thin wrappers over `setStatus`/`updateBody`. `setStatus` re-encodes the full
  decoded item.
- Private `save(_ doc:to:)` encodes with sorted keys + ISO dates, atomic.
- **Tests** (`CasablancaTests/ActionQueueStoreTests.swift`, XCTest): round-trip decode of a realistic file;
  lenient decode (missing optional fields, unknown extra field preserved on re-save); each mutation sets the
  right status + `decidedAt`; absent file → empty doc; tilde expansion; atomic save round-trips.

### A3. Observable model — `Casablanca/Services/ActionQueueModel.swift` (new)
- `@MainActor @Observable final class ActionQueueModel`. Holds `private(set) var items: [ActionQueueItem]`
  and `var loadError: String?`. Reads path from `UserDefaults.standard`.
- `func reload()` — loads via store, sorts (pending first, then by priority desc, then createdAt).
- Mutation methods call the store then `reload()`.
- `var pendingCount: Int` — count of `status == .pending` (drives sidebar badge).
- File watching: **watch the parent directory**, not the file (atomic writes replace the file's inode, so a
  file-descriptor watcher goes deaf after the first write). `open(dirPath, O_EVTONLY)` →
  `DispatchSource.makeFileSystemObjectSource(fileDescriptor:eventMask:[.write], queue:)`; debounce ~250 ms,
  coalesce, then `Task { @MainActor in reload() }`. `setCancelHandler { close(fd) }`. Guard against a missing
  directory (create-or-skip). Note: the app's own approve/decline write trips this watcher → one redundant
  `reload()`; that's harmless (read-modify-write), so do NOT add suppression logic.
- `func setPath()` / `refreshWatch()` — re-point the watcher and reload when the configured path changes.
- Owned by `AppModel` (add `let actionQueueModel = ActionQueueModel()`), injected via the existing
  `.environment(appModel)`. Call `actionQueueModel.reload()` + start watching **early** in
  `AppModel.bootstrap()` (before `await permissionsManager.checkAll()`) so the badge populates without waiting
  on calendar permissions.

### A4. Preferences + Settings
- `Casablanca/Models/Meeting.swift` → `enum AppPreferenceKey` add `static let actionQueuePath = "actionQueuePath"`.
- `Casablanca/Views/SettingsView.swift` general tab: add a "Action Queue" `Section` with a `TextField`
  bound to `@AppStorage(AppPreferenceKey.actionQueuePath)` + a "Browse..." `NSOpenPanel`
  (`canChooseFiles = true`, `canChooseDirectories = false`). Helper caption. When empty, caption notes the
  default path is used. (Default is resolved in the store, not stored, so an empty field == default.)
- Add `.onChange(of: actionQueuePath) { appModel.actionQueueModel.refreshWatch() }` (mirroring the existing
  `.onChange` sync pattern in `generalSettings`) so changing the path reloads + re-watches without relaunch.
  `SettingsView` already has `@Environment(AppModel.self)`.

### A5. Navigation wiring
- `Casablanca/Views/SidebarView.swift`:
  - `enum SidebarDestination` add `case actionQueue`.
  - **Add `@Environment(AppModel.self) private var appModel` to `SidebarView`** (the env is already plumbed —
    `ContentView` lives inside `.environment(appModel)`). Do NOT add a new init parameter.
  - At the top of `body`, read the count in this view's tracked context (mirror ContentView's documented
    workaround `let _ = viewModel.sidebarSelection`): `let pendingCount = appModel.actionQueueModel.pendingCount`.
    Then `Section { Label("Approvals", systemImage: "tray.full").badge(pendingCount).tag(SidebarDestination.actionQueue) }`
    after the To-Dos section. Without reading the count in `body`'s own context the badge will go stale.
- `Casablanca/Views/ContentView.swift` `detailView` switch: add
  `case .actionQueue: ActionQueueView()` (reads `AppModel` from environment).

### A6. View — `Casablanca/Views/ActionQueueView.swift` (new)
Follow `TodosView.swift` structure and the design tokens (`CasaSpace`, `CasaRadius`, `Color.text*`,
`Color.accent*`, `ContentUnavailableView`, `.navigationTitle("Approvals")`).
- Reads `@Environment(AppModel.self)`, uses `appModel.actionQueueModel`.
- Toolbar `.principal` `Picker` (segmented or menu) filtering by status group:
  `All • Pending • Approved • Follow-ups • Awaiting • Deferred • Done`.
- **Commit to one UI shape:** a `List` of rows; tapping a row opens a **detail sheet** (matches the app's
  established `SettingsView` sheet idiom) showing `source`, `rationale`, `target`, the **draft `body`** in an
  editable `TextEditor`, and `proposedAction`, with the action buttons at the bottom.
- Row: priority dot + `draftType` badge + title + status chip. Use tag/badge styling from DESIGN_SYSTEM §5.6.
- Actions per item (context menu + buttons in detail):
  - Draft & pending: **Approve** (optionally with edited body), **Decline** (optional note), **Defer**.
  - Task: **Mark done**, **Defer**, **Reopen**.
  - Approved/declined/completed: **Reopen** (→ pending).
- After any action: `actionQueueModel.<method>()` (which reloads). Empty states per filter via
  `ContentUnavailableView` (e.g. Pending empty → "Nothing waiting on you. 🎉").
- Reload on `.task` only (the watcher + `bootstrap()` already keep `items` fresh — don't also use `.onAppear`).
- Read `appModel.actionQueueModel.items` at the top of `body` (tracked-context rule, same as the sidebar badge).

### A7. Register files & build
- For each new `.swift`: `scripts/add-to-xcode.rb Casablanca Casablanca/...swift` and
  `scripts/add-to-xcode.rb CasablancaTests CasablancaTests/ActionQueueStoreTests.swift` (idempotent; uses the
  `xcodeproj` gem which is present).
- Build: `xcodebuild -project Casablanca.xcodeproj -scheme Casablanca -configuration Debug build`
- Test: `xcodebuild -project Casablanca.xcodeproj -scheme Casablanca -configuration Debug test`
  (or filter to the new test class).

---

## Part B — Claude skills (global, under `~/.claude/`)

These are personal skill/command files outside this repo.

### B1. Shared schema reference
- Add `~/.claude/projects/-Users-youri-broekhuizen/memory/action-queue-schema.md` documenting the JSON
  contract above (so every skill writes consistent items). Reference it from the producer skills.

### B2. One-time migration
- Convert the current `action-queue.md` sections into `action-queue.json` items:
  - "Ready For Review" → `pending` drafts where they are draft-like; otherwise `pending`/`follow_up`.
  - "Follow-ups — This Week" → `follow_up` tasks. "Awaiting More Context" → `awaiting_context`.
  - "Deferred" → `deferred`. "Completed This/Last Week" → `completed` tasks (preserve dates in
    `executedAt`/`executionResult`).
  - Preserve ids; synthesize `createdAt` from the id date. Keep `body` empty where no draft text exists yet.
- Rename `action-queue.md` → `action-queue.md.retired` (don't delete user data); JSON becomes source of truth.

### B3. Producers — write `pending` items
Update these to append draft items to `action-queue.json` (read-modify-write, preserve unknown fields):
- `~/.claude/skills/morning-briefing/SKILL.md` (`/morning`) — when it would draft something, add a `pending`
  draft with full `body`; the briefing surfaces pending + approved-not-executed counts from the JSON.
- `~/.claude/skills/end-of-day/SKILL.md` (`/end-of-day`) — Teams/email sweep drafts → `pending`; tracked
  follow-ups → `follow_up`. Completed → `completed` items.
- Executive triage skill/command (email + Teams sweeps) — same producer behavior.
- `~/.claude/skills/topdesk*` — when it prepares a ticket reply/comment, queue it as a `pending` draft
  (`draftType: "other"`, target = ticket ref).

### B4. Executor — `~/.claude/commands/review-action-queue.md` (`/review-action-queue`)
- Read `action-queue.json`. Present `pending` items (as today) for interactive approve/decline if Youri is in
  session — but now also **honor decisions made in Casablanca**: any item with `status == approved` is
  executed (send email via `mcp__microsoft365__*` / post Jira comment / send Teams chat) per its
  `target`/`draftType`/`body`, then set `completed` + `executedAt` + `executionResult`. `declined` items are
  archived. Keep the existing guardrail: never execute without an explicit `approved` decision.
- Update any other skill that reads `action-queue.md` (e.g. `end-of-day`, `morning`, `radar`) to read the JSON.

---

## Verification

1. **Unit**: `xcodebuild ... test` — `ActionQueueStoreTests` green (decode/lenient/mutations/atomic/tilde).
2. **Build**: `xcodebuild ... build` succeeds; new files compile and are in the target.
3. **End-to-end (manual, app)**: seed a sample `action-queue.json` at the default path with one `pending`
   draft + one `follow_up` task. Launch the app → "Approvals" appears in the sidebar with a badge of 1 →
   open it → filter works → open the draft → see the body → **Approve** → confirm the JSON now shows
   `status: "approved"` + `decidedAt`. **Defer** the task → JSON updates. Edit the JSON externally (add an
   item) → the view refreshes (file watch).
4. **End-to-end (skills)**: run the migration, confirm `action-queue.json` validates against the schema and
   the app renders it. Run `/morning` → a new `pending` draft appears in the app. Approve it in the app →
   run `/review-action-queue` → Claude executes it (with Youri's per-send approval per operating rules) and
   marks it `completed`; the app reflects `completed`.

## Out of scope (v1)
- Casablanca sending anything directly (all sends stay with Claude/MCP).
- Real-time bidirectional sync beyond file-watch + read-modify-write.
- Conflict-resolution UI for concurrent edits (rare for single local user).
