# Quiet Skills via add-todo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Youri's skills stop queueing drafts in `action-queue.json` and instead add to-dos (with `🔗` source links) to the Obsidian to-do file only for clear actions, through one shared `add-todo` skill; the queue machinery is retired, pre-November to-dos are deleted, the 71 pending queue items are triaged.

**Architecture:** Mostly prose edits to Claude Code skills/commands outside this repo (`~/.claude/skills`, `~/.claude/commands`) plus vault data/doc changes; one contract test inside this repo locks the to-do line format the skill writes to the parser the app uses. Nothing outside this repo is in git, so Task 1 takes a tarball backup before any edit.

**Tech Stack:** Markdown skills (Claude Code), Obsidian vault files, Python 3 for one-off data scripts, Swift/XCTest for the contract test.

**Spec:** `docs/superpowers/specs/2026-11-18-quiet-skills-add-todo-design.md` (read it; it is the authority — section numbers below refer to it).

## Global Constraints

- To-do file: `~/Documents/Obsidian Vault/tasks/Casablanca Todos.md`; headings `# Casablanca Todos`, `## Open`, `## Done` must survive every write.
- Line format: `- [ ] <action> 📅 <yyyy-MM-dd> 🔗 <scheme>:<ref>` — `📅` only for a stated deadline, `🔗` last and at most one, no owner, no `<!-- casablanca-todo: … -->` marker. Schemes exactly `outlook`, `teams`, `jira`, `topdesk`, `url`.
- Refs: `outlook:<Graph message id>`, `teams:<chat id>` or `teams:<chat id>/<message id>`, `jira:<KEY-123>`, `topdesk:<call number e.g. MC2611 0123>`, `url:<https URL>`.
- The bar (spec "The bar"): Youri committed himself, or a named person asked him directly and is waiting; and not already tracked under his name in Jira/Topdesk. Never: FYIs, others' work, a meeting's own action items, read-only items.
- Cap: at most 5 new to-dos per skill run; extras listed in the run's output.
- Only `end-of-day` ticks off, only with proof from the `🔗` source (spec §1 "Ticking off").
- No skill/command reads or writes `action-queue.json`, runs `check_queue.py`, calls `notify-youri`, or composes draft reply text unless Youri asks in the session.
- Retired files are moved (never deleted) to `~/.claude/retired/2026-11-18/`, keeping relative paths (`skills/<name>/…`, `commands/<file>`).
- Never edit anything under `~/.claude/skills/synced/`.
- Keep each file's existing language (English or Dutch) and voice; edit only the sections the task names.
- **Hard safety rule for every subagent:** never call a connector tool that sends, posts, creates, updates or deletes anything (mail, Teams, Jira, Topdesk, calendar); never run a producer skill for real; never open or modify Casablanca's SwiftData store (read a *copy* only). Only Tasks 7 and 9 write to the real vault, and only the files they name.

## Review Focus

1. A `teams:` ref containing `:` and `/`, and a `topdesk:` ref containing a space, must parse back as one link — pinned in Task 1's contract test.
2. A meeting note with open-marked, done-marked, unmarked and non-task lines: the pre-November cleanup removes only the open marked lines — pinned in Task 7's scratch-copy test.
3. A meeting note without a `yyyy-MM-dd` in its filename, or dated 2026-11-01 or later, is untouched by the cleanup — pinned in Task 7.
4. Dutch wording of the queue ("wachtrij", "queue-item", "Approvals", "goedkeuren") left behind in a producer — every task's grep check includes these words.
5. The scheduled `end-of-day` run (17:10 Mon–Fri) firing mid-execution: each file is replaced in one write, and Task 9 checks `end-of-day` is not running before it archives the queue.

---

### Task 1: Backup, `add-todo` skill, and the format contract test

**Files:**
- Create: `~/.claude/retired/2026-11-18/backup.tar.gz`
- Create: `~/.claude/skills/add-todo/SKILL.md`
- Create: `CasablancaTests/Fixtures/add-todo-examples.md` (this repo; add to the test target as a resource via `LC_ALL=en_US.UTF-8 ruby scripts/add-files-to-xcodeproj.rb` if fixtures are bundled, otherwise embed the same text as a string literal in the test and skip the fixture file)
- Create: `CasablancaTests/AddTodoSkillContractTests.swift`

**Interfaces:**
- Produces: the skill name `add-todo` that every later task points producers at, with these section headings producers can cite: `## The bar`, `## Line format`, `## Dedupe`, `## Writing the file`, `## Ticking off (end-of-day only)`, `## Cap and report`.

- [ ] **Step 1: Backup.** `tar -czf ~/.claude/retired/2026-11-18/backup.tar.gz` of `~/.claude/skills` (excluding `synced/`), `~/.claude/commands`, `~/.claude/scheduled-tasks`, `~/CLAUDE.md`, and from the vault `Memory/{operating-rules.md,MEMORY.md,README.md,action-queue-schema.md,feedback_proactive_no_asking.md}` and `tasks/Casablanca Todos.md`. Verify: `tar -tzf … | wc -l` > 30 and lists `commands/end-of-day.md`.

- [ ] **Step 2: Write the failing contract test** `AddTodoSkillContractTests.testSkillExampleLinesParse` — parse this document with `ObsidianTodoMarkdown.parseGenericDocument` and assert each `openTasks[i]`:

```
# Casablanca Todos

## Open
- [ ] Make the WhatsApp poll for Daily Link-up 🔗 teams:19:meeting_abc@thread.v2/1762073195000
- [ ] Reply to Marco Spoor about the BgZ test data 📅 2026-11-20 🔗 outlook:AAMkADExample=
- [ ] Beantwoord de vraag van Kim over de API-scope 🔗 topdesk:MC2611 0123
- [ ] Plan bilateral with Martijn de Hoogh 📅 2026-11-27
- [ ] Send Arriejanne the partner shortlist 🔗 url:https://tenzinger.atlassian.net/wiki/spaces/X/pages/1

## Done
```

| i | text | due | link |
|---|---|---|---|
| 0 | `Make the WhatsApp poll for Daily Link-up` | nil | `teams:19:meeting_abc@thread.v2/1762073195000` |
| 1 | `Reply to Marco Spoor about the BgZ test data` | `2026-11-20` | `outlook:AAMkADExample=` |
| 2 | `Beantwoord de vraag van Kim over de API-scope` | nil | `topdesk:MC2611 0123` |
| 3 | `Plan bilateral with Martijn de Hoogh` | `2026-11-27` | nil |
| 4 | `Send Arriejanne the partner shortlist` | nil | `url:https://tenzinger.atlassian.net/wiki/spaces/X/pages/1` |

For all: `owner == nil`, `id == nil`, `isCompleted == false`, `openTasks.count == 5`. Second test `testRenderRoundTripKeepsLines`: `renderGenericDocument(openTasks:doneTasks:)` of the parsed tasks, re-parsed, gives the same `text/due/link` per task.

- [ ] **Step 3: Run it** — `xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -derivedDataPath .build/test -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' -only-testing:CasablancaTests/AddTodoSkillContractTests`. Expected: FAIL only if the file isn't in the target yet; if it passes at once, that is the expected outcome for a contract test of existing behaviour — record it and continue.

- [ ] **Step 4: Write `~/.claude/skills/add-todo/SKILL.md`** per spec §1: frontmatter `name: add-todo` and a description that says producers load it whenever they find an action for Youri and that it applies to "add a to-do" / "zet op mijn lijst"; the six sections listed under Interfaces; the five example lines from Step 2 copied **byte-identically** into `## Line format`. English. No mention of `action-queue.json` except one sentence under `## Cap and report` saying the queue is retired.

- [ ] **Step 5: Verify the examples match** — extract the `- [ ]` lines from the SKILL.md and from the test; `diff` must print nothing.

- [ ] **Step 6: Dry run against a scratch copy.** Copy the to-do file to the scratchpad. Following only the SKILL.md text, apply three candidates: (a) "Gijs asked for a WhatsApp poll; Youri: I'll make one" with a teams ref → added; (b) "AI-226 In progress, assignee Youri" → skipped (tracked in Jira); (c) candidate (a) again → skipped (duplicate link). Expected: exactly one new line under `## Open`, headings intact, and the scratch file parses (re-run the Step 2 parser on it via the test or a quick check) with 1 open task. Do not touch the real file.

- [ ] **Step 7: Run the test again, then commit** (repo only):

```bash
git add CasablancaTests/AddTodoSkillContractTests.swift Casablanca.xcodeproj/project.pbxproj CasablancaTests/Fixtures/add-todo-examples.md
git commit -m "test: lock the add-todo skill's line format to the parser"
```

---

### Task 2: Skill producers

**Files (modify):** `~/.claude/skills/end-of-day/SKILL.md`, `~/.claude/skills/bilateral-cadence-watchdog/SKILL.md`, `~/.claude/skills/conductor-outcome-lag-chaser/SKILL.md`, `~/.claude/skills/forwarded-partner-intro-triage/SKILL.md`, `~/.claude/skills/release-cycle-orchestrator/SKILL.md`

**Interfaces:** Consumes `add-todo` and its section headings (Task 1).

- [ ] **Step 1: Rewrite each file per the spec §2 table.** Each queue section becomes a short pointer: what this skill considers a candidate, then "follow `add-todo` (bar, format, dedupe, cap)" with the `🔗` scheme this skill uses. Remove draft composition, queue schema fields (`bucket`, `draftType`, `externalRef`, `status: pending` …), queue dedupe reads, `check_queue.py`, and every `notify-youri` step. `end-of-day`: the Teams "Now/Tomorrow" threads go through `add-todo` (others listed in the summary); the queue cleanup step is removed; the "Casablanca todo sync" step becomes "add via `add-todo`, then tick off with proof per `add-todo` § Ticking off, and list each tick with its proof". `bilateral-cadence-watchdog`: to-do "Plan bilateral with <name>" (no draft invite). `release-cycle-orchestrator`: one to-do per checklist step that is Youri's; its dedupe is `add-todo`'s. Update each frontmatter `description` that mentions queueing.

- [ ] **Step 2: Grep check** — `grep -n -i -E "action-queue|check_queue|notify-youri|sweep-queue|queue-item|wachtrij|approval|goedkeur|draftType|bucket" <the five files>` prints nothing. `grep -c "add-todo" <each file>` ≥ 1.

- [ ] **Step 3: Read-through** — each file still parses as a skill (frontmatter `---` block intact, `name:` unchanged) and its steps are numbered consecutively.

---

### Task 3: Command producers

**Files (modify):** `~/.claude/commands/end-of-day.md`, `~/.claude/commands/executive-triage.md`, `~/.claude/commands/post-meeting-autopilot.md`, `~/.claude/commands/topdesk.md`, `~/.claude/commands/topdesk-triage.md`

**Interfaces:** Consumes `add-todo` (Task 1); `commands/end-of-day.md` must describe the same behaviour as the Task 2 `end-of-day` skill.

- [ ] **Step 1: Rewrite per spec §2.** `end-of-day.md`: same changes as the skill in Task 2 (step 7 queue cleanup removed; step 8 todo sync = add via `add-todo` + tick off with proof). `executive-triage.md`: read open to-dos from the to-do file instead of `check_queue`; new actions via `add-todo`. `post-meeting-autopilot.md`: no to-dos for the meeting's own action items (Casablanca's to-do review owns them); `add-todo` only for a non-meeting follow-up it finds; remove the "add or update internal todos" reconcile (keep "keep the headings intact" only if it now refers to `add-todo`). `topdesk.md`, `topdesk-triage.md`: replies/internal notes become an `add-todo` with `topdesk:<call number>`; reply text only when Youri asks in the session.

- [ ] **Step 2: Grep check** — same grep as Task 2 Step 2 on these five files prints nothing; each has `add-todo`.

---

### Task 4: Readers

**Files (modify):** `~/.claude/commands/morning.md`, `~/.claude/skills/morning-briefing/SKILL.md`, `~/.claude/skills/meeting-brief/SKILL.md`, `~/.claude/skills/week-wrap/SKILL.md`

- [ ] **Step 1: Edit per spec §3.** Morning (both): drop the `check_queue.py` step and the "Action Queue — Ready for Review" output section; keep "Casablanca Todos — Open"; fix the `morning-briefing` description. `meeting-brief`: replace the queue read with reading open to-dos for context. `week-wrap`: drop the queue archive/prune; the weekly summary counts to-dos completed this week from `## Done`.

- [ ] **Step 2: Grep check** — Task 2 Step 2's grep on these four files prints nothing.

---

### Task 5: Retire the queue machinery

**Files:** move `~/.claude/skills/sweep-queue/`, `~/.claude/skills/notify-youri/`, `~/.claude/commands/sweep-action-queue.md`, `~/.claude/commands/review-action-queue.md` to `~/.claude/retired/2026-11-18/{skills,commands}/…`; delete scheduled task `review-action-queue` (disabled).

- [ ] **Step 1: Move** with `mv` (not copy). Verify the four paths no longer exist under `~/.claude/skills` / `~/.claude/commands` and do exist under the retired dir.
- [ ] **Step 2: Delete the scheduled task** `review-action-queue` with `mcp__scheduled-tasks__delete_scheduled_task`; first confirm via `list_scheduled_tasks` that it is `enabled: false` (stop and report if it is enabled). Verify it is gone from the list and `daily-start`, `end-of-day`, `week-wrap`, `contacten-sync` remain.
- [ ] **Step 3: Global grep** — `grep -rln -i -E "action-queue|check_queue|notify-youri|sweep-queue|sweep-action-queue|review-action-queue" ~/.claude/skills ~/.claude/commands ~/.claude/scheduled-tasks --exclude-dir=synced` prints only `skills/add-todo/SKILL.md` (its one "retired" sentence).

---

### Task 6: Vault and profile docs

**Files (modify):** vault `Memory/operating-rules.md`, `Memory/MEMORY.md`, `Memory/README.md`, `Memory/feedback_proactive_no_asking.md`, `Memory/action-queue-schema.md`; `~/CLAUDE.md` (Memory contents line only).

- [ ] **Step 1: Edit per spec §7.** `operating-rules.md`: `## Action-queue Policy` → a short `## To-dos` section pointing at `add-todo`; every rule whose output is "a queue item"/"in de queue" now says "a to-do via `add-todo` if it passes the bar, else a line in the run's output"; remove the `notify-youri` nudge rules; a connector outage is reported in the run's output. Keep the file's Dutch. `MEMORY.md`/`README.md`: remove queue/notify rows and roles, add `add-todo`. `feedback_proactive_no_asking.md`: drop `/review-action-queue` from its list. `action-queue-schema.md`: prepend a "**Retired 2026-11-18** — see the `add-todo` skill" banner (it moves to the archive in Task 9). `~/CLAUDE.md`: in the Memory bullet, replace the `action-queue.json` (+ schema, notify state) mention with the to-do file and `add-todo`. Do not touch history files (`daily-log.md`, `lessons-learned.md`, `decisions-log.md`, `current-work.md`, `work-radar.md`, `archive/`, `*.bak-*`).
- [ ] **Step 2: Grep check** — `grep -n -i -E "action-queue|check_queue|notify-youri|sweep-queue|queue-item|in de queue|wachtrij" ~/CLAUDE.md "<vault>/Memory/"{operating-rules,MEMORY,README,feedback_proactive_no_asking}.md` prints only lines that say retired/archived.

---

### Task 7: Delete pre-November to-dos (vault data)

**Files:** vault `meeting notes/*.md` whose filename date < `2026-11-01`; backup to `~/.claude/retired/2026-11-18/meeting-notes-backup/`.

**Interfaces:** Produces `~/.claude/retired/2026-11-18/prenov_cleanup.py` (kept for audit) with `remove_open_marked(text: str) -> tuple[str, int]` and a CLI `--root <dir> --before 2026-11-01 [--apply]` (dry run by default, prints per-file counts and the total).

- [ ] **Step 1: Write the test first** in the same script (`--self-test`): a note containing an open marked line, a done marked line, an open unmarked line, a `## Action Items` heading and prose → after `remove_open_marked`, only the open marked line is gone and every other byte is identical; count == 1. A file named `2026-11-01 X - Notes.md` and one with no date are skipped by the file selector.
- [ ] **Step 2: Dry run on a scratch copy** of `meeting notes/`: total must be **194** (the count from the spec). If not 194, stop and report the difference.
- [ ] **Step 3: Backup** every file the dry run would change into the backup dir (same relative paths); verify file count matches.
- [ ] **Step 4: Apply** on the real `meeting notes/`. Verify: re-running the dry run reports 0; `diff` of each changed file against its backup shows only removed `- [ ] … casablanca-todo:` lines.
- [ ] **Step 5: Report** the total removed and the 5 app-only proposed to-dos Youri must dismiss in the Review filter (list their text from a fresh *copy* of `~/Library/Application Support/Casablanca/Casablanca.store*` via `sqlite3`: `ZSTATUSRAW='proposed'` and meeting `ZDATE` before 2026-11-01).

---

### Task 8: Triage proposal for the 71 pending queue items (read-only)

**Files:** Create `~/.claude/retired/2026-11-18/queue-triage.md`.

- [ ] **Step 1:** Read `Memory/action-queue.json` (read-only). For each `status: pending` item apply the bar using only the item's own fields (`title`, `body`, `rationale`, `source`, `target`, `externalRef`, `kind`, `createdAt`); no connector calls. Write `queue-triage.md` with: (a) a table of items that pass — queue id, proposed to-do line in the exact format (with `🔗` link when the item has an email/chat/Jira/Topdesk ref), one-line reason; (b) a count of the rest grouped by reason (draft only, FYI, tracked in Jira/Topdesk, meeting action item, stale/done, someone else's).
- [ ] **Step 2: Controller checkpoint (not a subagent step):** show Youri table (a); he confirms or edits the list. Do not start Task 9 before his answer.

---

### Task 9: Migrate confirmed to-dos and archive the queue (vault data)

**Files:** vault `tasks/Casablanca Todos.md`; move `Memory/action-queue.json`, `Memory/action-queue.json.bak-*`, `Memory/notify-youri-state.json`, `Memory/action-queue-schema.md`, `Memory/archive/action-queue-archive.json*` into `Memory/archive/action-queue-retired-2026-11-18/`.

- [ ] **Step 1:** Check `list_scheduled_tasks`: `end-of-day` is not mid-run (its `lastRunAt` is not within the last 15 minutes); otherwise wait and re-check.
- [ ] **Step 2:** Append the confirmed lines via the `add-todo` write rules (cap does not apply). Verify by reading back: each line present once under `## Open`, headings intact.
- [ ] **Step 3:** Move the queue files with `mv`. Verify none of them remain in `Memory/` and all are in the archive folder.

---

### Task 10: claude.ai upload folders and final verification

**Files:** Create `~/Documents/claude-skill-uploads/2026-11-18/{add-todo,end-of-day,morning-briefing,meeting-brief,week-wrap}/SKILL.md` (copies of the edited local skills) and one `.zip` per folder (folder at the zip root).

- [ ] **Step 1:** Copy and zip. Verify `unzip -l` shows `<name>/SKILL.md` in each.
- [ ] **Step 2: Final checks** — the grep of spec "Verification" returns only retired banners/pointers; the full test suite passes (`xcodebuild test …` as in Task 1, all tests, report the count; known flake `PersistenceControllerTests…LegacyStore…`); `git status` in the repo is clean apart from the untracked `tools/rebuild-history/`.
- [ ] **Step 3:** Write a short `~/Documents/claude-skill-uploads/2026-11-18/README.md`: replace these four skills on claude.ai, add `add-todo`, remove `sweep-queue`.
