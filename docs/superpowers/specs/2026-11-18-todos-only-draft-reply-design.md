# To-dos only, with on-demand draft replies — design

Date: 2026-11-18 · Project 1 of 4 (see "Roadmap")

## Why

The Approvals inbox (`action-queue.json`) produces far more than Youri can
keep up with: of 604 queue items, 426 were declined, 107 completed, 71 still
pending. Most drafts were never used. Youri wants **one list — the To-Dos** —
and a draft only when he asks for one, by clicking a button on a to-do.

## Goals

- Remove the Approvals view and everything that only exists for it.
- Every open to-do gets a **Draft reply** action. Clicking it runs Claude Code
  headless with read-only access to Youri's connectors and shows a draft he
  can edit, copy, regenerate with a steer, or continue in Claude Code.
- Every to-do keeps a visible link to the meeting it came from (list row,
  draft sheet), and the meeting's summary/transcript is context for the draft.
- To-dos can carry an optional **source link** (email, Teams chat, Jira,
  Topdesk) so the draft knows what it is replying to.

## Non-goals (this project)

- Rewiring the producer skills (project 2), Apple Reminders sync (project 3),
  focus-time planning skill (project 4).
- Migrating or deleting `action-queue.json` — the app simply stops reading it;
  project 2 migrates the 71 pending items and retires the sweep.

## Anti-goals

- **The app never sends anything.** No send/post/create/update tool may be
  reachable from the draft run. A draft that could be sent by the app is a
  failure even if it works.
- **No new inbox.** Drafts are not persisted, listed or badged. A draft lives
  in the sheet until it is closed.
- No drop in to-do reliability: Obsidian stays the source of truth; a to-do
  line written by the app or a skill must round-trip unchanged.

## Approaches considered

| | Approach | Trade-off |
|---|---|---|
| **A (chosen)** | Headless `claude -p` from the app, read-only tools, draft in a sheet | Stays in the app; 30–90 s wait; needs a careful tool allowlist |
| B | Button opens an interactive Claude Code session with a prefilled prompt | Can iterate, uses skills, but leaves the app every time |
| C | Mark "draft wanted", a scheduled skill fills it in later | Minutes–hours latency, and rebuilds the queue we are removing |

Youri picked A, with a "Continue in Claude Code" escape hatch from B.

## Design

### 1. Remove Approvals

Delete: `ActionQueueView`, `Views/ActionCards/*`, `Models/ActionQueue.swift`,
`ActionQueueDisplay`, `ActionCardBodies/*`, `ActionQueueModel`,
`ActionQueueStore`, their tests; `SidebarDestination.actionQueue` and its
sidebar row/ContentView case; the Approvals results in global search; the
`actionQueuePath` setting; the menu-bar pending count and the
`DockBadge` wiring in `CasablancaApp`.
*My call:* the Dock badge goes away entirely (not repurposed to open to-dos —
a badge is exactly the "keep up" pressure we are removing). `DockBadge.swift`
is deleted if nothing else uses it.

### 2. Source link on a to-do

- Obsidian task-line syntax gains an optional token, written last in the
  suffix: `🔗 <scheme>:<ref>`, schemes `outlook`, `teams`, `jira`, `topdesk`,
  `url`. Examples: `🔗 jira:IO-1234`, `🔗 topdesk:MC2611 0123`,
  `🔗 outlook:AAMkAD…`. It must parse back unambiguously next to the existing
  ` — owner 📅 due [mm:ss]` suffix; a line with only a link and no
  owner/due/timestamp is valid.
- `TodoItem` gains `sourceRef: String?` → **CasablancaSchemaV4**, lightweight
  migration from V3 (additive optional).
- The list row shows the source as a small caption chip next to the meeting
  subtitle (e.g. "Jira IO-1234"); `jira`/`url` open in the browser.
- Skills will write this token in project 2; in this project the app only
  parses, stores, displays and round-trips it.

### 3. Meeting link

Already present (`TodoRowPresentation.meetingSubtitle` + navigation). Keep it
in the row; also show it in the draft sheet header as a button that closes the
sheet and navigates to the meeting.

### 4. Draft reply

**Entry:** a "Draft reply" button (icon `text.bubble`, hover-revealed on the
row, plus context-menu item) on accepted, not-completed to-dos (Open and All
filters). Not on Review/proposed or done items.

**Sheet** (`DraftReplySheet`):
- Header: to-do text, meeting link (if any), source chip (if any).
- Body: progress state ("Reading the thread…") with Cancel → editable text
  view with the draft when done → error state with the message and Retry.
- Footer: steer field ("shorter, Dutch, more formal…") + **Revise**
  (primary) with a menu holding **Start over**, **Copy**, **Continue in
  Claude Code**.
  - **Revise** (Youri's pick): current draft *including his edits* + steer →
    new draft. A tool-less completion through the existing
    `ClaudeCLIProvider` path; seconds, never loses edits.
  - **Start over**: the full tool-using run again (re-reads the source). If
    the draft was edited, confirm before discarding.
- Draft is not persisted; closing the sheet cancels a running generation.

**Runner** (`DraftReplyService`, reusing `CommandRunning`/`ProcessCommandRunner`
and `ClaudeCLIProvider`'s executable resolution):
- `claude -p --output-format json --model <setting, default sonnet>
  --no-session-persistence`, working directory = fresh temp dir.
- MCP: `--strict-mcp-config --mcp-config <generated JSON>` containing only the
  servers needed for context (today: `medicore-gateway`, which carries M365,
  Jira and Confluence). The full user server list has ~20 claude.ai servers,
  several needing auth — loading them all would be slow and noisy.
  *Builder to verify* how a headless run authenticates to `medicore-gateway`
  (OAuth token from the user's Claude Code credentials) and whether
  `--mcp-config` can reference it by name or needs the URL.
- Tools: `--allowedTools` lists only read tools (`Read`, `Skill`, and the
  gateway's `*_get_*`, `*_list_*`, `*_search_*`, `atlassian_fetch`,
  `confluence_get_page` …). `--disallowedTools` additionally blocks every
  send/reply/forward/create/update/delete/transition/comment tool by pattern
  as belt-and-braces. Pass `--permission-mode default` explicitly — Youri's
  `~/.claude/settings.json` has `defaultMode: auto`, which loading user
  settings would otherwise inherit — so anything not allowed is denied in
  `-p` mode. A unit test locks the argument list, including this flag.
- User settings: load user settings so the `email-drafting` skill (signature,
  style) and `~/.claude/CLAUDE.md` language rules apply, but no hooks.
  *Builder to verify* the cleanest flag set for "skills + CLAUDE.md, no hooks".
- Timeout 180 s.
- Prompt contains: to-do text, owner, due date, source ref, meeting title/date,
  the meeting summary, and the transcript (whole if it fits the CLI's 100k
  budget, else a window around `sourceTimestamp`). Instructions: fetch the
  source if a ref is present; reply in the language of the source; return
  only the draft (with a one-line `Channel:` hint: email/Teams/Jira/Topdesk);
  never send.
- Topdesk: no Topdesk MCP server is configured in Claude Code today, so a
  `topdesk:` ref is passed as text only. Noted, not solved here.

**Continue in Claude Code:** opens Terminal with `claude "<same prompt +
current draft + steer>" --permission-mode default` in `~/` (interactive).
Youri's pick: force ask mode for this session even though his default is
`auto`, so nothing is sent without his explicit yes; the extra prompts on
read tools are accepted friction.

## Calls made by Claude (check these)

- Dock badge and menu-bar count removed entirely, not repurposed.
- Source link syntax `🔗 <scheme>:<ref>` and the `sourceRef` field (schema V4).
- Draft button only on accepted, open to-dos.
- Drafts never persisted.
- Draft run's MCP limited to `medicore-gateway` via a generated config.
- Default draft model sonnet; timeout 180 s.

### 5. Settings

Remove the action-queue path section. Add "Draft replies" section: model
picker (haiku/sonnet/opus, default sonnet) and the resolved `claude` path
(reuse existing CLI path setting if one exists).

## Constraints

- macOS SwiftUI app, SwiftData with versioned schema; non-sandboxed (already
  shells out to `claude`).
- Known risk: SwiftUI view changes pass build+tests but break at runtime —
  verify in the running app (sheet open/close, list rows) per project memory.
- Work branches from the current HEAD (`teams-compact-view-split`, v0.22.0,
  not yet merged); no PR without Youri's explicit go-ahead.

## Left to the builder

Exact SF symbols and layout of the sheet within `DESIGN_SYSTEM.md`; file
organisation; exact allowlist patterns (after inspecting the gateway's tool
names); the transcript windowing size.

## Roadmap (later projects, designed separately)

2. Skills go quiet — producers write to-dos (with `🔗` source links) to the
   Obsidian todo file only for actions clearly Youri's; no drafts; sweep and
   `/review-action-queue` retired; 71 pending items triaged (≈14 real to-dos
   migrated, rest archived). Includes the claude.ai-synced skills.
3. Apple Reminders two-way sync, opt-in in Settings, target list selectable
   (an Exchange-backed list would surface in Outlook).
4. Focus-time planner skill — reads open to-dos, books focus blocks in the
   calendar.
