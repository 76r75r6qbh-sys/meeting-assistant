# Quiet skills: to-dos instead of an approval queue — design

Date: 2026-11-18 · Project 2 of 4 (project 1, v0.23.0, removed the Approvals
inbox from Casablanca; see `2026-11-18-todos-only-draft-reply-design.md`)

## Why

Youri's skills fill `Memory/action-queue.json` with drafts and tasks, and
`notify-youri` pings his Teams self-chat for each batch. Of 604 items, 426
were declined, 107 completed, 71 are still pending. "Too many drafts I never
use … it's too much to keep up with." Casablanca no longer shows the queue
(v0.23.0); a draft is now made on demand from a to-do (**Draft reply**). The
skills must follow: write a to-do only when there is a clear action for
Youri, never a draft, and stop pinging.

## Goals

- One shared skill, **`add-todo`**, owns the bar, the line format, the
  dedupe and the write discipline for `~/Documents/Obsidian Vault/tasks/Casablanca Todos.md`.
  Producers call it instead of writing the queue.
- No skill or command writes or reads `action-queue.json` any more, and none
  creates drafts. Draft text is made only by Casablanca's Draft reply or when
  Youri asks for one in a session.
- Retire the queue machinery: `sweep-queue`, `/sweep-action-queue`,
  `/review-action-queue`, the `review-action-queue` scheduled task,
  `notify-youri`, `check_queue.py`.
- Triage the 71 pending items: the ones that pass the bar become to-dos
  (with `🔗` links), the rest are archived.
- The claude.ai copies (end-of-day, morning-briefing, meeting-brief,
  week-wrap, sweep-queue) follow the same change.

## Non-goals

- Apple Reminders sync (project 3) and the focus-time planner (project 4).
- Changing what the briefings and wrap-ups *report*: they still tell Youri
  what is waiting on him, as text in the run's output. Only the queue and the
  drafts go.
- App changes beyond one contract test and the sync fix in §5 (below).

## Anti-goals

- **A new firehose.** If the to-do list fills up the way the queue did, the
  project failed even if every skill works. The bar and the per-run cap are
  the guard.
- **Duplicate to-dos.** The same thread showing up twice, or a meeting action
  the app already extracts appearing again from a skill.
- **Damaging the to-do file.** A skill must never break the
  `# Casablanca Todos` / `## Open` / `## Done` structure, rewrite or reorder
  existing lines, or strip `<!-- casablanca-todo: … -->` markers the app wrote.
- **Losing history.** Nothing in the queue or its backups is deleted; it is
  archived.

## The bar (agreed with Youri, 2026-11-18)

A skill adds a to-do only when **both** hold:

1. Youri committed to it himself ("I'll …", "ik pak het op"), **or** a named
   person asked him directly and is waiting on him; and
2. it is not already tracked under his name in Jira or Topdesk (an issue or
   call assigned to him, or one he is working on).

Examples: Gijs asked for a WhatsApp poll in Daily Link-up and Youri said
"I'll make one" → to-do. AI-226 "In progress", assignee Youri → no to-do.

## Approaches

| | Approach | Trade-off |
|---|---|---|
| **A (chosen)** | Shared `add-todo` skill; each producer replaces its queue section with "for each clear action, follow `add-todo`" | One place to tune the bar; one extra skill to upload to claude.ai |
| B | Write the bar and format into every producer | No extra skill, but ~13 copies of the rule drift apart — the problem `notify-youri` was created to solve for notifications |
| C | A script (`add_todo.py`) that appends lines with exact dedupe | Deterministic, but claude.ai/desktop runs may not be able to run a local script against the vault; can be added under A later |

Youri picked A.

## Design

### 1. `add-todo` skill (`~/.claude/skills/add-todo/SKILL.md`)

Frontmatter `name: add-todo`; the description says producers load it
whenever they find an action for Youri, and that it also applies when Youri
says "add a to-do" / "zet op mijn lijst". It holds:

- **The bar** (above), with the examples, plus what never becomes a to-do:
  FYIs, things someone else owns, items already tracked in Jira/Topdesk,
  action items from a meeting (Casablanca's own to-do review owns those),
  and anything that only needs reading.
- **When the Jira/Topdesk check can't run** (connector down): add the to-do
  anyway and say in the run's output that the check was skipped — a missed
  commitment costs more than a duplicate Youri can delete.
- **Line format** (must match `ObsidianTodoMarkdown`):
  `- [ ] <action> 📅 <yyyy-MM-dd> 🔗 <scheme>:<ref>`
  - `<action>`: one imperative line in the language of the source, naming
    the person: "Reply to Marco Spoor about the BgZ test data".
  - `📅` only for a real deadline someone stated; otherwise omitted. No owner
    (every to-do is Youri's; the app only parses an owner next to a date).
  - `🔗` always last, at most one, when there is a source:
    `outlook:<Graph message id>`, `teams:<chat id>` (optionally
    `teams:<chat id>/<message id>`), `jira:<KEY-123>`,
    `topdesk:<call number, e.g. MC2611 0123>`, `url:<https URL>`. No other
    schemes; no newline in a ref.
  - No `<!-- casablanca-todo: … -->` marker: the app adds it (verified:
    `ObsidianTodoSyncService.syncGenericTodos` assigns ids to unmarked lines
    and writes them back).
- **Dedupe:** skip when the same `🔗` link is already on any line (Open or
  Done) of the file; without a link, skip when an Open line says the same
  thing about the same person.
- **Write discipline:** re-read the file right before writing; insert new
  lines after the last `- [` line under `## Open` (directly under the
  heading when Open is empty), keeping the blank line before `## Done`;
  read the file back afterwards and confirm each new line is there (the app
  rewrites the file when it assigns ids, so a simultaneous write can lose a
  line — re-add it once if missing); never edit, reorder or
  remove existing lines (ticking only as in "Ticking off" below); never write under `## Done`; keep the three headings;
  if the file or a heading is missing, add nothing and report it in the
  run's output.
- **Ticking off (Youri, 2026-11-18: "yes, with proof"):** only
  `end-of-day` ticks, and only an Open line with a `🔗` link whose source
  proves it is done: `teams:`/`outlook:` — Youri's own reply in that thread
  after the message that asked him; `jira:` — the issue is resolved/done, or
  Youri posted the comment the to-do asked for; `topdesk:` — the call is
  closed. It flips `- [ ]` to `- [x]` in place, keeping the line and its
  marker (the app marks it completed; the line may stay under `## Open` until the app next re-renders the file), and names each ticked to-do with its
  proof in the EOD summary. No link, unclear proof or a connector error →
  leave it open.
- **Cap:** at most **5** new to-dos per skill run. Beyond that, list the
  extra candidates in the run's output ("3 more possible to-dos: …") instead
  of writing them.
- **Report:** the run's output lists the to-dos it added (one line each) so
  briefings and wrap-ups show them. No Teams or email message.

### 2. Producers

Each producer's queue section is replaced by a pointer to `add-todo`; draft
bodies are no longer composed; `notify-youri` calls go.

| File | Today | After |
|---|---|---|
| `commands/end-of-day.md`, `skills/end-of-day` | "Now" Teams threads → pending draft; "Tomorrow" → follow_up task; queue cleanup | Threads that pass the bar → `add-todo` with `teams:` link; others listed in the EOD summary; queue cleanup removed; its "Casablanca todo sync" step becomes add-via-`add-todo` plus ticking off with proof |
| `commands/executive-triage.md` | reads queue; appends drafts/tasks | reads open to-dos instead; `add-todo` for new actions |
| `commands/post-meeting-autopilot.md` | queues drafts/tasks per meeting; adds/updates todos | no to-dos for the meeting's own action items (Casablanca's to-do review owns them); `add-todo` only for a non-meeting follow-up it finds (a mail or chat that asks Youri something) |
| `commands/topdesk.md`, `commands/topdesk-triage.md` | queue Dutch reply / internal-note drafts | `add-todo` with `topdesk:` link; reply text only when Youri asks in the session |
| `skills/bilateral-cadence-watchdog` | queues a `calendar_event` draft | `add-todo` "Plan bilateral with <name>" (passes the bar as a standing commitment); no draft invite |
| `skills/conductor-outcome-lag-chaser` | queues "capture meeting outcome" tasks | `add-todo` for each, with the meeting title in the text |
| `skills/forwarded-partner-intro-triage` | queues partner reply email drafts | `add-todo` "Reply to <partner> …" with `outlook:` link |
| `skills/release-cycle-orchestrator` | one task per checklist step; dedupe reads the queue | `add-todo` per step that is Youri's; dedupe via `add-todo` |

### 3. Readers

- `commands/morning.md`, `skills/morning-briefing`: drop `check_queue.py`
  and the "Action Queue — Ready for Review" section; the existing
  "Casablanca Todos — Open" section stays.
- `skills/meeting-brief`: drop the queue read; read open to-dos for context.
- `skills/week-wrap`: drop the queue archive/prune; the weekly summary
  counts to-dos completed this week from the `## Done` section instead.

### 4. Retire (move, don't delete)

The scheduled-task wrappers `daily-start`, `end-of-day` and `week-wrap`
only call `/morning`, `/end-of-day` and the week-wrap skill by name and need
no edit.

Move to `~/.claude/retired/2026-11-18/` (outside the skill and command
loaders, so nothing loads them): `skills/sweep-queue`, `skills/notify-youri`,
`commands/sweep-action-queue.md`, `commands/review-action-queue.md`. Delete
the disabled `review-action-queue` scheduled task.

### 5. Clear out to-dos from before 1 November (Youri, 2026-11-18)

Youri wants every to-do from before 2026-11-01 gone ("Delete, with
backup"). Counted on a copy of the store: **194 open accepted to-dos**, all
as `- [ ] … <!-- casablanca-todo: … -->` action-item lines in
`meeting notes/` files dated before 2026-11-01; **5 proposed** ones that
live only in the app (Review filter); and 280 completed ones.

- Copy every affected meeting note to
  `~/.claude/retired/2026-11-18/meeting-notes-backup/` (same relative paths).
- Delete only the open marked lines (`- [ ] … casablanca-todo:`) from notes
  whose filename date is before 2026-11-01; touch nothing else in those
  notes.
- **App fix needed (found in plan review):** `removeMissingMeetingRows` only
  considers files that still contain task lines, so a note left with no
  task lines keeps its rows in the app (21 of the 29 affected notes). Fix:
  every existing scanned meeting file counts as a source path, so its
  missing rows are removed. TDD'd, released as v0.23.1; the cleanup takes
  effect in the app once that build runs.
- Verify: the store copy query and a grep both return 0 open pre-November
  to-dos; the notes otherwise diff clean against the backup.
- The 5 proposed ones are app-only; Youri dismisses them in the Review
  filter (no store surgery while the app runs).
- *Claude's call:* the 280 completed ones stay as history (they are not on
  the Open list).

### 6. The queue file and the 71 pending items

- Triage: apply the bar to each pending item; show Youri the list that
  passes (proposed to-do line with `🔗` link, and why), plus a one-line
  count of the rest by reason. Write the confirmed lines through `add-todo`
  (the cap of 5 does not apply to this one-off migration).
- Then move `action-queue.json`, its `.bak-*` files, `notify-youri-state.json`
  and the archive JSONs into `Memory/archive/action-queue-retired-2026-11-18/`.
  `action-queue-schema.md` gets a "Retired 2026-11-18" banner pointing at
  `add-todo` and moves with them.

### 7. Vault and profile docs

- `Memory/operating-rules.md`: the `## Action-queue Policy` section becomes
  a short "To-dos" section pointing at `add-todo`; rules whose output was "a
  queue item" now say "a to-do via `add-todo` if it passes the bar, else a
  line in the run's output"; the `notify-youri` nudge rules (L208–209) go;
  a connector outage is reported in the run's output, not queued.
- `Memory/MEMORY.md`, `Memory/README.md`: remove queue/notify rows and
  roles; add `add-todo`. `feedback_proactive_no_asking.md`: drop
  `/review-action-queue` from its command list.
- History files are left as they are: `daily-log.md`, `lessons-learned.md`,
  `decisions-log.md`, `archive/`, all `.bak-*` files. `current-work.md` and
  `work-radar.md` are refreshed by the next end-of-day run, not hand-edited.
- `~/CLAUDE.md` L78 (Memory contents): drop the queue files, mention the
  to-do file and `add-todo`.

### 8. claude.ai copies

The synced copies under `~/.claude/skills/synced/…` are byte-identical to
the local ones today and are overwritten by sync, so they are not edited.
Each is a separate upload on Youri's claude.ai account. Prepare upload-ready
folders (and zips) in `~/Documents/claude-skill-uploads/2026-11-18/` for
`end-of-day`, `morning-briefing`, `meeting-brief`, `week-wrap` and the new
`add-todo`; Youri replaces them on claude.ai and removes `sweep-queue`
there. Claude does not publish them (publishing goes to the Medicore
library).

### 9. Safety net

`~/.claude/skills` and `~/.claude/commands` are not git repos. Before any
edit, snapshot both plus the touched vault files into a dated tarball in
`~/.claude/retired/2026-11-18/backup.tar.gz`.

### 10. Contract test (app repo)

A Casablanca unit test feeds the exact example lines from `add-todo`'s
SKILL.md through `ObsidianTodoMarkdown` and asserts text, due date and link
come out as intended, so the skill's format and the parser can't drift
silently.

## Verification

- `grep` for `action-queue`, `check_queue`, `notify-youri`, `sweep-queue`
  across `~/.claude/skills` (excluding `synced/`), `~/.claude/commands`,
  `~/.claude/scheduled-tasks`, `~/CLAUDE.md`, `operating-rules.md`,
  `MEMORY.md`, `README.md` and `feedback_*.md` returns only "retired"
  banners or pointers (history files excluded, see 7).
- A dry run of `add-todo` against a scratch copy of the to-do file: three
  sample candidates (one passing, one Jira-tracked, one duplicate link) → one
  line added, structure intact, the app parser reads it.
- Subagent review of every edited skill/command against this design.
- The contract test passes with the full suite.

## Calls made by Claude (check these)

- Cap of 5 new to-dos per run; extras listed in the output.
- No Teams self-ping at all (project 3's Reminders sync may bring phone
  alerts back, opt-in).
- Only end-of-day ticks to-dos, only with proof from the linked source
  (Youri agreed); no other skill edits existing lines.
- Skills never add a meeting's own action items; Casablanca's to-do review
  owns them. post-meeting-autopilot stops producing to-dos for them.
- When the Jira/Topdesk check can't run, the to-do is added anyway and the
  skipped check is reported.
- History and log files in the vault are not rewritten.
- Pre-November cleanup removes open to-dos only; completed ones stay.
- Bilateral-cadence reminders pass the bar as a standing commitment.
- `teams:` refs are `<chat id>` or `<chat id>/<message id>`; `outlook:` refs
  are Graph message ids.
- Retired files are moved to `~/.claude/retired/2026-11-18/`, the queue to a
  vault archive folder; nothing is deleted except the disabled scheduled task.
- claude.ai copies are prepared for upload, not published by Claude.

## Left to the builder

Exact wording inside each skill, as long as it points at `add-todo` rather
than restating the bar; the order of edits; how the triage list is shown.
