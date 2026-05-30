# Action Queue (Approvals)

The **Approvals** inbox (sidebar) is where AI-prepared drafts land for you to act on — draft emails,
Jira comments, Teams messages. You **approve**, **decline**, **edit**, or **send back with a steer**
("Request changes"); a paired agent prepares the drafts and executes the approved ones.

Casablanca itself **never sends anything**. It only reads a shared file and writes your decisions back.
Producing drafts and executing approvals is done by an **agent** you set up (this guide uses
[Claude Code](https://claude.com/claude-code), but anything that follows the JSON contract works).

```
┌─────────────┐   writes pending drafts    ┌──────────────────┐  you approve/decline/   ┌─────────────┐
│  Agent      │ ─────────────────────────▶ │ action-queue.json │ ──── request changes ──▶│ Casablanca  │
│ (producer)  │                            │  (shared file)    │ ◀──── writes decision ──│  Approvals  │
└─────────────┘                            └──────────────────┘                         └─────────────┘
       ▲    reads "approved" / "revision_requested"  │
       └───────────────── executor ──────────────────┘   sends email/Jira/Teams, or re-drafts
```

---

## 1. Point the app at a queue file

**Settings → Action Queue → file path.** Pick (or type) a path to an `action-queue.json` file. The app
reads it, shows the items, and writes your decisions back to it. The list live-updates when the file
changes on disk.

> The built-in default path points at the original author's agent memory directory. **Set your own path**
> in Settings — anywhere both the app and your agent can read/write (the app is not sandboxed, so any
> location under your home folder works).

If the file doesn't exist yet, the view is empty until your agent creates it.

---

## 2. The data contract: `action-queue.json`

One JSON document; `items` is the queue. The app and your agent both follow this shape.

```jsonc
{
  "version": 1,
  "updatedAt": "2026-05-30T09:00:00Z",
  "items": [
    {
      "id": "AQ-20260530-01",            // stable id (any unique string)
      "kind": "draft",                    // "draft" = approvable body; "task" = tracking only
      "draftType": "email",               // "email" | "jira" | "teams" | "other" (null for tasks)
      "title": "Reply to Acme — renewal",
      "priority": "medium",               // "low" | "medium" | "high"
      "target": "email: jane@acme.com",   // human-readable destination
      "source": "Jane Doe 2026-05-30 — \"RE: renewal\"",  // origin shown at top of the sheet
      "rationale": "Why this is queued / context.",
      "body": "Hi Jane,\n\n…",           // the draft you approve/edit (empty for tasks)
      "proposedAction": "Send this reply, then schedule a call.",
      "status": "pending",
      "decisionNote": null,               // optional note (e.g. decline reason) — written by the app
      "revisionPrompt": null,             // your steer when you click "Request changes"
      "createdAt": "2026-05-30T09:00:00Z",
      "decidedAt": null,                  // set by the app when you decide
      "executedAt": null,                 // set by the agent after it acts
      "executionResult": null
    }
  ]
}
```

### Statuses (these are the filters in the app)

| status               | meaning                                              | set by |
|----------------------|------------------------------------------------------|--------|
| `pending`            | draft awaiting your decision                         | agent  |
| `approved`           | you approved → agent should execute (send)           | app    |
| `declined`           | you declined                                         | app    |
| `revision_requested` | you sent it back with a steer in `revisionPrompt`    | app    |
| `follow_up`          | tracked action, this week                            | agent/app |
| `awaiting_context`   | blocked on external input                            | agent/app |
| `deferred`           | postponed                                            | app/agent |
| `completed`          | executed / done                                      | agent/app |

### Write discipline (both sides)
- **Read-modify-write the whole file by `id`**, then write atomically. Don't drop items you didn't touch.
- **Append, don't clobber.** Producers add items; never rewrite untouched ones.
- **Bump `updatedAt`** on every write. Treat decision/exec fields and `draftType` as optional (lenient decode).

---

## 3. What you do in the app

Open **Approvals**, click an item. The sheet shows **Origin → editable Proposed reply → context**, with:

- **Approve** — marks `approved` (saving any inline edits to `body`). Your agent sends it next run.
- **Decline** — marks `declined`.
- **Request changes…** — opens a popover; type a steer ("propose a call instead", "more formal", "push
  back on the deadline") → marks `revision_requested` with your text in `revisionPrompt`.
- **Defer** — right-click a row → Defer (`deferred`).
- **✕ / Esc** — close the sheet without changing anything.

Approving in the app counts as your "show-before-send" sign-off — you saw and approved the exact text.

---

## 4. Set up the agent (Claude Code)

The agent has two jobs: **produce** drafts into the queue, and **execute** your decisions.

**Producers.** Point whatever prepares your drafts (e.g. a morning/triage routine) at the queue file:
append items with `status: "pending"`, a full `body`, and the `source`/`target`/`draftType` fields above.
Keep a copy of the schema (section 2) next to the file so every producer writes consistent items.

**Executor.** A command that reads the queue and acts on your decisions:
- `status: "approved"` → send via the right tool (email / Jira / Teams) per `target`/`draftType`/`body`,
  then set `completed` + `executedAt` + `executionResult`.
- `status: "revision_requested"` → re-draft `body` per `revisionPrompt`, clear `revisionPrompt`, set back
  to `pending` (it returns to you for another pass — it is **not** auto-sent).
- `status: "declined"` → archive.

Two commands ship with the original setup:
- **`/review-action-queue`** — interactive: walks pending items and asks you to decide, and also picks up
  app-made decisions.
- **`/sweep-action-queue`** — non-interactive: only acts on app-made decisions (`approved` /
  `revision_requested` / `declined`). This is the one to schedule.

---

## 5. Run it on a schedule (hourly, local)

> **Must run locally, not as a cloud/remote routine.** The queue file and your authenticated connectors
> (email / Jira / Teams) live on your Mac. A remote agent can't read the local file or use those
> connectors, so use a local `launchd` agent.

Wrapper `~/bin/sweep-action-queue.sh`:
```bash
#!/bin/zsh
exec /usr/bin/env PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/bin:/bin" \
  "$(command -v claude)" -p "/sweep-action-queue" \
  --allowedTools "Read,Write,Edit,Bash,mcp__microsoft365__*,mcp__claude_ai_Atlassian__*" \
  >> "$HOME/.claude/sweep-action-queue.log" 2>&1
```

`~/Library/LaunchAgents/com.casablanca.sweep-queue.plist`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.casablanca.sweep-queue</string>
  <key>ProgramArguments</key><array><string>/bin/zsh</string><string>-lc</string>
    <string>$HOME/bin/sweep-action-queue.sh</string></array>
  <key>StartCalendarInterval</key><dict><key>Minute</key><integer>0</integer></dict>
  <key>RunAtLoad</key><false/>
</dict></plist>
```

Enable:
```bash
chmod +x ~/bin/sweep-action-queue.sh
launchctl load ~/Library/LaunchAgents/com.casablanca.sweep-queue.plist
```

The `--allowedTools` list is what lets the unattended run send without an interactive permission prompt —
scope it to the queue tools, not a blanket bypass. Adjust the MCP tool prefixes to match your connectors.

**Test once by hand first** — run `~/bin/sweep-action-queue.sh`, check `~/.claude/sweep-action-queue.log`,
and confirm a real send works before trusting the hourly schedule. If a connector isn't available in the
headless run, the sweep logs "skipped — connector unavailable" and leaves the item for the next run.

---

## Quick start checklist
1. **Settings → Action Queue** → set your `action-queue.json` path.
2. Have your agent write a `pending` draft into that file (see the schema).
3. Open **Approvals**, review the draft, **Approve / Decline / Request changes**.
4. Add the hourly local `launchd` agent running `/sweep-action-queue` to execute approvals automatically.
