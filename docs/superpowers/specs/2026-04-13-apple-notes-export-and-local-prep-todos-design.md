# Apple Notes Export And Local Prep/Todos Design

## Goal

Add a user-selectable export destination so meeting notes can be exported to Apple Notes instead of Obsidian, while also making prep/todo storage independently selectable as either Obsidian-backed or app-local.

## Scope

- Add `Export destination` preference with `Obsidian` and `Apple Notes`.
- Add `Prep/todo storage` preference with `Obsidian` and `Local`.
- Preserve current Obsidian behavior exactly when Obsidian is selected.
- Export to Apple Notes only when `Export destination = Apple Notes`.
- Keep prep/todo behavior filesystem-backed only in Obsidian mode.
- Keep prep/todo behavior fully inside Casablanca's local SwiftData model in Local mode.

## Non-Goals

- No Apple Notes integration for prep files.
- No Apple Notes integration for todos.
- No redesign of the meeting workspace UI beyond settings copy and export messaging.
- No broad storage-backend abstraction for unrelated meeting data.

## Current State

- `ExportService` writes two markdown files into an Obsidian vault under `meeting notes/`.
- `MeetingPrepService` reads `- Prep.md` files from the Obsidian meeting notes directory.
- `ObsidianTodoSyncService` treats markdown files in the vault as the source of truth for meeting and generic todos.
- `TodoItem` and `Meeting` data already exist in SwiftData, so the app already has local persistence for notes and todos.

## Requirements

### Preferences

- Settings must expose two independent choices:
  - `Export destination`: `Obsidian` or `Apple Notes`
  - `Prep/todo storage`: `Obsidian` or `Local`
- Existing users should continue to behave as they do now after upgrading.
- The Obsidian vault path remains configurable and required only for Obsidian-backed features.

### Obsidian Compatibility

- If `Export destination = Obsidian`, raw notes and summary export must behave exactly as they do today.
- If `Prep/todo storage = Obsidian`, prep lookup and todo sync must behave exactly as they do today.
- Existing filenames, directory names, markdown structure, links, and automatic export flow must remain unchanged in Obsidian mode.

### Apple Notes Export

- If `Export destination = Apple Notes`, Casablanca exports meeting content into Apple Notes instead of Obsidian files.
- Apple Notes export creates two notes per meeting in a dedicated Apple Notes folder named `Casablanca`:
  - `YYYY-MM-DD Meeting Title`
  - `YYYY-MM-DD Meeting Title - Notes`
- The summary note should contain the same user-facing content as the current Obsidian summary export.
- The raw notes note should contain the same user-facing content as the current Obsidian raw notes export.
- Export should be deterministic so repeat exports target the same notes rather than producing avoidable duplicates.
- Automatic export and manual export must both use the selected export destination.

### Local Prep/Todos

- If `Prep/todo storage = Local`, Casablanca must not read prep markdown from Obsidian.
- If `Prep/todo storage = Local`, Casablanca must not sync todos to or from Obsidian markdown.
- The prep pane should simply show no prep content in Local mode.
- Meeting todos and generic todos should continue to work through SwiftData only in Local mode.
- Local mode must not require an Obsidian vault path.

## Proposed Architecture

### Preference Model

Add two enum-backed app preferences:

- `ExportDestination`
  - `.obsidian`
  - `.appleNotes`
- `PrepTodoStorage`
  - `.obsidian`
  - `.local`

Existing automatic-export preference (`autoExportNotesToObsidian`) is **renamed** to `autoExportEnabled` to reflect that it now applies to whichever destination is selected. On first launch after upgrade, read the old key once and copy its value to the new key, then leave the old key in place (do not delete user data). All call sites are updated to read the new key.

These preferences are independent. Supported combinations include:

- Obsidian export + Obsidian prep/todos
- Apple Notes export + Obsidian prep/todos
- Obsidian export + Local prep/todos
- Apple Notes export + Local prep/todos

### Export Routing

Keep `ExportService` as the orchestration entry point, but move destination-specific write behavior behind a small exporter boundary.

Responsibilities:

- `ExportService`
  - decides whether export should run
  - prepares meeting content
  - routes to the selected exporter
  - returns a destination-aware export result for UI messaging
- `ObsidianMeetingExporter`
  - preserves the current markdown file export logic
- `AppleNotesMeetingExporter`
  - creates or updates the two Apple Notes entries in folder `Casablanca`

The routing boundary should be narrow. Views should continue calling `ExportService` and should not know how notes are written.

### Apple Notes Writer

Implement Apple Notes export through AppleScript executed via `osascript`.

The Apple Notes writer must:

- target the user's **primary Notes account**, resolved at runtime via `default account of application "Notes"`. If that property is unavailable, fall back to `accounts of application "Notes"` sorted by `id` (ascending) and pick the first entry — sorting by `id` rather than relying on enumeration order gives deterministic test behavior. The resolved account may be iCloud or "On My Mac"; either is acceptable. v1 does not expose account selection in the UI.
- ensure the `Casablanca` folder exists at the root of that account on **every export** (not just first use), creating it if missing. This handles the case where the user deletes or renames the folder out-of-band.
- locate existing notes for a meeting by scanning the `Casablanca` folder for an embedded marker (see Identity & Upsert below). Titles are informational only.
- create notes when missing.
- replace note body contents on re-export so exported content stays current. Re-export always rewrites the body — Notes will update `modification date` and trigger sync churn; that is accepted in v1, hash-based skipping is deferred.
- run on a background `Task`. Each AppleScript invocation has a 30-second timeout. Cancellation flows through standard Swift `Task` cancellation (parity with existing Obsidian export).

#### Identity & Upsert

Apple Notes allows duplicate titles, AppleScript note `id` values are per-device and not stable across syncs, and Notes is known to strip HTML comments from saved bodies. To make upsert deterministic:

- Each exported note body includes a visible footer marker on the last line:
  - Summary note: `Casablanca id: <UUID> / summary`
  - Raw notes note: `Casablanca id: <UUID> / notes`
- The UUID is the `Meeting.id` already stored in SwiftData.
- The marker scan is the **source of truth**. The cached AppleScript note `id` on `Meeting` (see Data Model Changes) is a per-install fast-path optimization only.
- Resolution order on each export:
  1. If a cached id exists, look up the note via `note id "…" of folder "Casablanca" of account …`. **Verify** the resolved note's body still contains the meeting's marker — if not, treat as a cache miss (this prevents overwriting an unrelated note when ids have drifted).
  2. On miss, scan `every note of folder "Casablanca"` for one whose body contains the marker.
  3. If still none, create a new note.
- Persist the resolved note `id` back to the `Meeting` after every successful create or update.

#### Body Format

Bodies are assigned via the AppleScript `body` property as a full HTML document (`<html><body>…</body></html>`). Notes only preserves a limited tag subset; the renderer is constrained to:

- `<h1>`, `<h2>` for top-level/section headings (markdown `##` → `<h1>`, `###` → `<h2>` — Notes treats `<h1>` as its visual "Title" style).
- `<p>` for paragraphs.
- `<ul>` / `<ol>` / `<li>` for lists.
- `<b>`, `<i>`, `<u>`, `<br>` for inline formatting and breaks.
- All other tags are avoided. HTML comments are not used (Notes strips them on save).

Mapping from the current Obsidian markdown content:

- YAML frontmatter is **stripped entirely** before rendering.
- Markdown headings (`##`, `###`) → `<h1>`, `<h2>`.
- Bullet lists → `<ul><li>`.
- Action items / todos → `<ul><li>` items prefixed with `☐ ` (open) or `☑ ` (done). Apple Notes' native checklist data type is not reliably round-trippable from AppleScript; visible Unicode glyphs are stable and human-readable.
- Paragraphs → `<p>`.
- Obsidian wikilinks (`[[Name]]`) are flattened to their plain text (`Name`). The two notes per meeting do not link to each other in v1.
- The identity marker (see above) is emitted as the **last** `<p>` of the document so it survives Notes' HTML normalization. The exporter must prototype this behavior end-to-end as the first implementation task and adjust the marker placement if Notes proves to drop trailing paragraphs (e.g. move to a leading `<p>` instead).

#### AppleScript Execution

The production implementation uses **`NSAppleScript`** rather than spawning `/usr/bin/osascript` via `Process`. Rationale:

- `NSAppleScript` runs in-process and exposes the raw error code via `NSAppleScriptErrorNumber`, which makes mapping permission denials and other AppleEvent errors deterministic.
- It avoids the subprocess overhead and stderr-parsing fragility of `Process`-based osascript.
- It is the sandbox-friendly Apple-recommended path when paired with the `com.apple.security.automation.apple-events` entitlement.
- Compilation can happen once per process and be reused; the script is parameterized via `NSAppleEventDescriptor` arguments to avoid string-formatting injection risks with meeting titles/bodies.

The script must be executed off the main thread (e.g. on a detached `Task` with a `Mutex`-style serial queue so concurrent exports don't race on a shared compiled script).

#### Test Seam

Introduce a narrow protocol so the exporter can be tested without launching Apple Notes:

```swift
protocol AppleNotesScripting {
    func ensureFolder(named: String) async throws -> AppleNotesFolderRef
    func findNote(markerContaining: String, in: AppleNotesFolderRef) async throws -> AppleNotesNoteRef?
    func noteBody(id: String) async throws -> String?
    func createNote(title: String, body: String, in: AppleNotesFolderRef) async throws -> AppleNotesNoteRef
    func updateNote(id: String, title: String, body: String) async throws
}
```

- Production implementation: `NSAppleScriptAppleNotesScripting` — owns the compiled `NSAppleScript`, serializes calls, returns parsed refs.
- Test implementation: in-memory fake that records calls and returns canned refs.
- `AppleNotesMeetingExporter` takes the protocol via initializer injection. Unit tests verify upsert routing (create vs update), cache verification (`noteBody` returns drifted content → fallback to scan), marker generation, body rendering, and error mapping.

### Prep/Todo Routing

Keep prep/todo storage routing separate from export routing.

- In `Obsidian` mode:
  - `MeetingPrepService` keeps reading from Obsidian meeting note files
  - `ObsidianTodoSyncService` remains active
- In `Local` mode:
  - prep reads return no prep
  - todo creation and completion update SwiftData only
  - startup refresh and per-meeting refresh skip Obsidian sync

This avoids forcing Apple Notes into workflows that fundamentally depend on editable markdown files.

#### Generic Todos in Local Mode

`ObsidianTodoSyncService.createGenericTodo` currently writes to `tasks/Casablanca Todos.md`. In Local mode:

- Generic todo creation persists a `TodoItem` with `sourceFilePath = nil` via SwiftData only.
- Completing or deleting a Local todo never reads or writes the filesystem, even if `sourceFilePath` is non-nil on a row created before the user switched modes (see "Mode Transitions" below).
- The startup "bootstrap legacy generic todos" path is skipped in Local mode.

### Mode Transitions

A user can change either preference at any time. The spec defines exactly one behavior per transition:

- **Export destination Obsidian → Apple Notes:** old markdown files in the vault are **left in place**, unchanged. They become orphaned but are not deleted (the user's vault is theirs). Future exports go to Apple Notes only. `Meeting.appleNotesSummaryNoteId` / `.appleNotesRawNotesNoteId` start `nil` so the first Apple Notes export performs a marker scan or creates new notes.
- **Export destination Apple Notes → Obsidian:** old Apple Notes entries are left in place. Future exports write markdown files as today.
- **Prep/todo storage Obsidian → Local:** existing `TodoItem` rows that have a non-nil `sourceFilePath` are **left as-is** but `sourceFilePath` is **ignored** by all sync calls — writes never touch the filesystem. `ObsidianTodoSyncService` operations are skipped entirely; the service is not invoked from any call site while in Local mode.
- **Prep/todo storage Local → Obsidian:** on switch, run the existing Obsidian sync refresh once so that the vault becomes the source of truth again. Todos created while in Local mode have `sourceFilePath = nil` and remain SwiftData-only until the user edits them in the vault and a future sync picks them up; the spec accepts that those Local-era todos will not be exported automatically to the vault. (Re-syncing Local-era todos *into* the vault is out of scope for v1.)

In both directions, `MeetingPrepService.prepURL` returns `nil` in Local mode so any "open in Obsidian" affordances are hidden or disabled.

## Data Flow

### Export Flow

1. User edits meeting notes, transcript, summary, and todos in Casablanca.
2. Casablanca saves app state locally as it does today.
3. Manual export and automatic export both call `ExportService`.
4. `ExportService` reads `ExportDestination`.
5. If destination is Obsidian:
   - write the existing markdown files exactly as today
6. If destination is Apple Notes:
   - upsert the summary note
   - upsert the raw notes note
7. UI shows destination-appropriate success or failure messaging.

### Prep Flow

1. Notes workspace requests prep content for the active meeting.
2. Casablanca reads `PrepTodoStorage`.
3. If storage is Obsidian:
   - resolve prep markdown path and read it as today
   - `MeetingPrepService.prepURL` continues to return the vault URL for "open externally" affordances
4. If storage is Local:
   - return `nil` for both prep content and `prepURL`
   - any "open in Obsidian" affordance is hidden
5. Notes UI falls back to the existing full-width workspace when no prep is available.

### Todo Flow

1. User adds or completes a todo from meeting or global todo UI.
2. Casablanca reads `PrepTodoStorage`.
3. If storage is Obsidian:
   - keep current sync behavior, including markdown updates and refresh
4. If storage is Local:
   - create or update only the local `TodoItem`
   - do not touch the filesystem

## UI Changes

### Settings

- Replace the single Obsidian-only automation wording with destination-aware wording.
- Keep Obsidian vault controls visible because they are still needed in Obsidian export mode or Obsidian prep/todo mode.
- Clarify in helper text:
  - Obsidian vault path is only required for Obsidian-backed export or prep/todo storage
  - Apple Notes export writes to the `Casablanca` folder in Apple Notes
  - Local prep/todo storage keeps prep disabled and stores todos only inside Casablanca

### Export Messaging

- Manual export success text should mention the active destination:
  - Obsidian: existing folder/file wording
  - Apple Notes: saved to Apple Notes folder `Casablanca`
- Automatic export status text should no longer hard-code Obsidian in the UI copy.

## Error Handling

### Obsidian Mode

- Preserve current errors and behavior.
- Missing vault path should still fail export in Obsidian export mode.
- Obsidian automatic export failures should remain non-blocking.

### Apple Notes Mode

- The app is sandboxed. Apple Notes scripting requires:
  - `com.apple.security.automation.apple-events` entitlement.
  - `NSAppleEventsUsageDescription` in `Info.plist` explaining that Casablanca writes meeting notes to Apple Notes.
  - User consent via the macOS Automation prompt, which appears on the first scripted call.
- If the user denies Automation access, surface a specific error message instructing the user to enable Casablanca under **System Settings → Privacy & Security → Automation → Notes**. Detect this via `NSAppleScriptErrorNumber` matching any of:
  - `-1743` (`errAEEventNotPermitted`) — primary case
  - `-1744` (`errAEEventWouldRequireUserConsent`) — pre-consent prompt
  - `-600` (`procNotFound`) — Notes is not running and the system blocked auto-launch
  - `-10810` — Finder/Notes failed to launch
  All four map to the same actionable Automation-guidance message.
- If Apple Notes scripting fails for other reasons (any other non-zero `NSAppleScriptErrorNumber`), surface a normal export failure for manual export with the error description.
- Automatic export failures remain non-blocking and only log the failure (same as Obsidian today).
- AppleScript invocations exceeding the 30-second timeout are treated as failures with a timeout-specific error message.
- The `Casablanca` folder is ensured on every export (not just the first); if it has been deleted out-of-band, it is recreated and any cached note ids are invalidated by the cache-verification step.
- If a note already exists (matched by marker), update it rather than creating a duplicate.

### Local Prep/Todo Mode

- Missing vault path should not affect prep or todo behavior.
- Prep should quietly appear unavailable.
- Todo actions should continue working because SwiftData remains the local source of truth.

## Testing Strategy

### Export Routing

- Add tests that verify `ExportService` routes to the correct exporter based on `ExportDestination`.
- Preserve or add tests proving Obsidian export output is byte-for-byte compatible with current expectations where practical.
- Apple Notes exporter tests use the in-memory `AppleNotesScripting` fake and cover:
  - first-time export creates a folder + two notes with correct markers and HTML bodies
  - re-export of the same meeting updates the existing notes (no duplicates)
  - re-export after the cached note `id` is cleared falls back to marker scanning
  - cached note `id` points to a note whose body no longer contains the meeting marker → exporter treats this as a cache miss, scans, and does not overwrite the unrelated note
  - `Casablanca` folder deleted out-of-band → `ensureFolder` recreates it on next export
  - permission-denied error codes (`-1743`, `-1744`, `-600`, `-10810`) all map to the user-facing Automation guidance message
  - timeout maps to a timeout-specific error message
  - YAML frontmatter is stripped and wikilinks are flattened in rendered HTML

### Prep Routing

- Add tests verifying prep loads in Obsidian mode when files exist.
- Add tests verifying prep returns `nil` in Local mode even when an Obsidian vault path exists.

### Todo Routing

- Add tests verifying Local mode creates and completes todos without requiring source markdown files.
- Add tests verifying Local mode generic todos persist with `sourceFilePath = nil`.
- Add tests verifying that, after switching Obsidian → Local, existing rows with non-nil `sourceFilePath` are completed without any filesystem writes.
- Preserve existing Obsidian todo sync tests for Obsidian mode.

### Mode Transitions

- Add tests covering each documented transition behavior in the Mode Transitions section.
- Verify `autoExportEnabled` is seeded from the legacy `autoExportNotesToObsidian` key on first launch and is independent thereafter.

### UI/Preference Coverage

- Add focused tests for new preference defaults and any presentation logic that changes visible export messaging.
- Ensure the no-regression path for Obsidian mode is covered explicitly.

## Data Model Changes

- Add two optional Apple Notes id properties to `Meeting` so upsert can skip the marker scan on the happy path:
  - `appleNotesSummaryNoteId: String?`
  - `appleNotesRawNotesNoteId: String?`
- These are populated after a successful create/update and cleared if a lookup fails.
- Existing meetings default to `nil`, which simply forces a marker scan on first Apple Notes export.

## File-Level Change Plan

- `Casablanca.entitlements`
  - add `com.apple.security.automation.apple-events`
- Xcode project (`INFOPLIST_KEY_NSAppleEventsUsageDescription` build setting, or `Info.plist` if one is later introduced)
  - add `NSAppleEventsUsageDescription` describing Apple Notes write access
- `Casablanca/Models/Meeting.swift`
  - add new preference keys, `ExportDestination` and `PrepTodoStorage` enums, and `appleNotesSummaryNoteId` / `appleNotesRawNotesNoteId` properties
- `Casablanca/Views/SettingsView.swift`
  - add destination/storage pickers and update helper text
- `Casablanca/Services/ExportService.swift`
  - route export through destination-specific writer; return destination-aware `ExportResult`
- `Casablanca/Services/ObsidianMeetingFiles.swift`
  - keep current Obsidian path logic unchanged except for any small compatibility extraction needed
- `Casablanca/Services/AppleNotesScripting.swift` (new)
  - protocol + value types (`AppleNotesFolderRef`, `AppleNotesNoteRef`)
- `Casablanca/Services/NSAppleScriptAppleNotesScripting.swift` (new)
  - production `NSAppleScript`-based implementation with timeout, serialized execution, and permission error mapping
- `Casablanca/Services/AppleNotesMeetingExporter.swift` (new)
  - HTML rendering, marker logic, upsert orchestration
- `Casablanca/Services/MeetingPrepService.swift`
  - gate prep loading on `PrepTodoStorage`
- `Casablanca/Services/ObsidianTodoSyncService.swift`
  - either gate behavior internally or move call sites behind a storage-mode-aware facade
- `Casablanca/Views/TodosView.swift`
  - avoid forced Obsidian sync in Local mode
- `Casablanca/Views/NotesEditorView.swift`
  - route meeting todo actions and export success messaging through destination/storage-aware services
- `Casablanca/Views/RecordedMeetingView.swift`
  - route todo actions and export success messaging through destination/storage-aware services
- `Casablanca/Views/TranscriptionView.swift`
  - update automation copy to be destination-aware
- `CasablancaTests/*`
  - extend existing export, prep, todo, and workflow tests for the new preference matrix
  - add `AppleNotesMeetingExporterTests` against the in-memory scripting fake

## Open Decisions Resolved

- Apple Notes export is opt-in through `Export destination`.
- Apple Notes export creates two notes, not one.
- Prep/todo storage is independent from export destination.
- Local prep/todo storage means no external markdown files; data remains inside Casablanca only.
- Obsidian mode is a strict compatibility path where behavior must not change.
- Apple Notes integration runs as a sandboxed scripted client: `com.apple.security.automation.apple-events` entitlement + `NSAppleEventsUsageDescription`; permission denial (`-1743`/`-1744`/`-600`/`-10810`) surfaces actionable guidance.
- Bodies are assigned as full HTML documents using the limited tag subset Notes preserves; YAML frontmatter is stripped, wikilinks flattened to plain text, todos shown with `☐`/`☑` glyphs.
- Notes target the resolved primary Apple Notes account via `default account` (with a sorted-by-id fallback; no account picker in v1); folder is `Casablanca` at the account root, ensured on every export.
- Upsert identity is established via a visible footer marker (`Casablanca id: <UUID> / summary|notes`) — marker scan is the source of truth, cached AppleScript note ids are a per-install fast path verified against the live body before any write.
- AppleScript execution uses `NSAppleScript` in-process on a serialized off-main queue so error codes are surfaced directly and parameters are passed as `NSAppleEventDescriptor` arguments (no string interpolation into scripts).
- Apple Notes scripting is gated behind an `AppleNotesScripting` protocol so the exporter is unit-testable with an in-memory fake.
- Export runs on a background `Task` with a 30-second per-invocation AppleScript timeout and standard Swift task cancellation.
- `autoExportNotesToObsidian` is renamed to `autoExportEnabled` with a one-time migration that seeds the new key from the old value.
- Mode transitions are explicit and one-way per export: switching destinations does not delete or migrate existing artifacts; switching `Prep/todo storage` Local → Obsidian triggers a one-shot Obsidian refresh.
