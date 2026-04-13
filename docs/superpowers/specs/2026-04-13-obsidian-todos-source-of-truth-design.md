# Obsidian Todos Source of Truth Design

## Goal

Make Obsidian the canonical source of truth for todos in Casablanca, while preserving meeting linkage for meeting-created todos and supporting generic todos in one app-managed Obsidian file.

## Context

Casablanca currently stores todos in SwiftData and only exports meeting-linked todos into meeting notes as a derived artifact. That model breaks the user's desired workflow because agents and other tools operate directly on Obsidian. The app must therefore stop treating SwiftData as authoritative for todos and instead maintain a local cache derived from Obsidian files.

## Requirements

- Obsidian is the source of truth for all todos.
- Meeting-linked todos must retain a stable reference to a specific meeting.
- Generic todos must be supported without requiring a meeting.
- Casablanca must create and manage one dedicated generic-todo file automatically.
- Changes made in Casablanca must be written back immediately to Obsidian so other applications can observe status changes.
- Other applications must still be able to read the markdown tasks normally.

## Approach Options

### Option 1: Stable hidden IDs in markdown comments

Store each synced task as a normal markdown checkbox with a hidden Casablanca ID comment, for example:

`- [ ] Follow up with Kim <!-- casablanca-todo: 550E8400-E29B-41D4-A716-446655440000 -->`

This preserves normal Obsidian readability while giving Casablanca a durable identity for import, edit, completion toggles, reordering, and deletion. This is the recommended approach.

### Option 2: File path and line position as identity

Infer identity from the source file and line number. This keeps files cleaner but is too brittle because reordering, manual edits, and section rewrites invalidate references.

### Option 3: Task text as identity

Infer identity from checkbox text. This avoids metadata but fails for duplicate texts and becomes ambiguous after edits.

## Decision

Use Option 1. Casablanca will embed a stable hidden ID comment in synced markdown tasks and use that ID as the canonical identity in its local cache.

## Architecture

### Sources

There are two todo sources in Obsidian:

- Meeting-linked todos stored in meeting files under `meeting notes/`
- Generic todos stored in `tasks/Casablanca Todos.md`

Casablanca will treat those files as authoritative and maintain SwiftData only as a local cache for UI speed, filtering, and meeting navigation.

### Local Cache Model

`TodoItem` remains the app model, including the optional `meeting: Meeting?` relationship. The semantic meaning changes:

- Rows are cached mirrors of Obsidian tasks
- Meeting-linked tasks always have `meeting != nil`
- Generic tasks always have `meeting == nil`

The cache must be refreshed from Obsidian and reconciled whenever relevant files are loaded or written.

### Sync Entry Points

Casablanca should sync todos from Obsidian at these moments:

- App launch
- Opening the Todos screen
- Opening a meeting
- Immediately before writing a user-initiated change back to Obsidian

This keeps the app close to external Obsidian edits without requiring a full filesystem watcher in the first iteration.

## File Layout

### Generic Todo File

Casablanca creates and manages:

`<vault>/tasks/Casablanca Todos.md`

Recommended file structure:

```md
# Casablanca Todos

## Open

- [ ] Example task <!-- casablanca-todo: UUID -->

## Done

- [x] Completed task <!-- casablanca-todo: UUID -->
```

This structure is intentionally simple and readable in Obsidian and other markdown-aware apps.

### Meeting Todo Sections

Casablanca reads and writes a dedicated `## Action Items` section in meeting files.

Canonical write target per meeting:

- If `<meeting> - Prep.md` exists, write there
- Otherwise write to `<meeting> - Notes.md`

Read behavior:

- Read both prep and notes files if both exist
- Merge discovered tasks by Casablanca ID
- Preserve one canonical write target to avoid ambiguous round trips

This allows prep-created tasks to stay with the prep note while still tolerating older notes files that may already contain tasks.

## Markdown Format

Every synced task uses standard markdown checkbox syntax plus a hidden ID comment:

- Open: `- [ ] Task text <!-- casablanca-todo: UUID -->`
- Done: `- [x] Task text <!-- casablanca-todo: UUID -->`

Rules:

- The visible task text remains plain markdown text
- The hidden comment is Casablanca-specific identity metadata
- If a valid checkbox line is missing the ID comment, Casablanca may adopt it and add an ID during writeback

## Data Flow

### Import

1. Read source markdown file
2. Parse checkbox items in the supported section or file
3. Extract completion state, visible text, and optional Casablanca ID
4. Resolve the task as meeting-linked or generic based on source file
5. Upsert the corresponding `TodoItem` cache row
6. Remove cached rows that no longer exist in the authoritative source

### Writeback

When the user creates, edits, completes, or deletes a task in Casablanca:

1. Reload the authoritative source file
2. Parse the latest contents
3. Reapply the intended change against fresh source data
4. Write the updated markdown back to Obsidian
5. Update the local cache to match the written result

This ensures Obsidian wins in case of external edits just before app writeback.

## Meeting Linkage Rules

- Tasks originating from meeting files always remain linked to that meeting
- Generic tasks from `tasks/Casablanca Todos.md` always remain unlinked
- Moving a task between generic and meeting contexts is not part of the first iteration
- Meeting linkage is determined from source file context, never inferred from task text

## Bootstrap and Migration

Existing SwiftData todos must be migrated into Obsidian on first sync so users do not lose current action items.

Migration behavior:

- If a cached meeting-linked todo exists and no matching markdown todo exists in the meeting’s canonical source, write it into that meeting file with a new Casablanca ID
- If a cached generic todo exists and no matching markdown todo exists in `tasks/Casablanca Todos.md`, write it there with a new Casablanca ID
- After bootstrap, Obsidian becomes authoritative
- If a cached todo later disappears from Obsidian, Casablanca removes it from cache on refresh

The first sync should be idempotent so re-running it does not duplicate tasks.

## UI Behavior

### Meeting Workspace

- Adding a todo from a meeting creates a meeting-linked markdown task in the canonical meeting source file
- Completion toggles update the meeting source file immediately
- The meeting workspace continues to display only that meeting’s linked tasks

### Todos Screen

- Show both generic and meeting-linked tasks
- Meeting-linked rows keep their meeting subtitle and tap-through behavior
- Generic rows show no meeting subtitle and do not navigate
- Add a global create affordance that creates generic tasks in `tasks/Casablanca Todos.md`

## Failure Handling

- Missing vault path: disable todo sync/writeback and show a clear settings-level message
- Missing generic todo file: create it automatically
- Missing meeting action-items section: create it on first app-created meeting task
- Malformed checkbox lines: ignore unless they are valid markdown tasks
- Duplicate Casablanca IDs in one file: log and ignore later duplicates during that parse
- Write failure: do not keep the UI in a falsely-successful state; revert or refresh and show an error
- Read failure for one file: fail that source gracefully without blocking the rest of the app

## Testing

### Parser Tests

- Parse open and completed checkbox lines
- Parse hidden Casablanca IDs
- Handle missing IDs
- Ignore malformed lines
- Detect duplicate IDs safely

### Sync Tests

- Import generic tasks from `tasks/Casablanca Todos.md`
- Import meeting-linked tasks from prep and notes files
- Write back create, edit, complete, and delete operations
- Bootstrap legacy cached todos into Obsidian
- Prefer fresh Obsidian content when external edits occur before writeback

### UI and View-Model Tests

- Todos screen shows mixed generic and meeting-linked tasks
- Meeting-linked rows navigate to their meeting
- Generic rows do not navigate
- Meeting workspace preserves linked tasks after refresh

## Scope Boundaries

Included in this design:

- Obsidian-first todo sync
- Meeting-linked and generic tasks
- Immediate writeback from app to Obsidian
- Bootstrap of existing cached todos

Not included in this design:

- Arbitrary vault-wide task scanning
- Filesystem watcher-based live sync
- Moving tasks between generic and meeting contexts
- Rich markdown task metadata beyond checkbox, text, and Casablanca ID

## Implementation Notes

- Keep the file format human-readable and minimally invasive
- Treat source-file parsing and markdown rewriting as a dedicated service, not view code
- Keep the first iteration deterministic and conservative; correctness matters more than clever sync behavior
