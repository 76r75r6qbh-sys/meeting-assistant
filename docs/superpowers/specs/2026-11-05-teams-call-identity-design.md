# Teams call identity — design

**Date:** 2026-11-05
**Status:** Youri asked for this (session brief, 2026-11-05); evidence gathered on his Mac the same day. This design was reviewed by a subagent, not approved by Youri item by item.

## Problem

Teams auto-record (v0.19.0) decides which meeting a call belongs to by time
alone. `TeamsAutoRecordPolicy.resolveEvent` takes any calendar event running
from `start − 10 min` until its end, preferring events that mention Teams. An
ad-hoc 1:1 call taken during another calendar item (a focus block, or a
meeting you are skipping) is saved under that item's name. The note, the
transcript and the summary then end up in the wrong meeting.

## Evidence: what new Teams exposes (2026-11-05, this Mac)

The probe sampled `com.microsoft.teams2` windows every 2 s through the
Accessibility API (Terminal.app is AX-trusted; Claude's shell has neither AX
nor Screen Recording, so `kCGWindowName` came back `nil` there). Log:
`scratchpad/probe/teams-windows.log` (local, not committed).

| Situation | Window titles seen |
|---|---|
| Idle, chat view | `Chat \| Judith Koetsier, Marco Spoor, Wouter Tengeler +1 \| Medicore \| youri.broekhuizen@medicore.nl` |
| Idle, 1:1 chat open | `Chat \| Marco Spoor \| Medicore \| youri.broekhuizen@medicore.nl` |
| Idle, calendar view | `Calendar \| Medicore \| youri.broekhuizen@medicore.nl` |
| "Meet now" (self call), pre-join | main window + **second window** `Meeting join \| Meeting with Youri Broekhuizen \| Medicore \| …` |
| Same, in call | `Meeting with Youri Broekhuizen \| Medicore \| …` |
| Scheduled meeting "Daily AI team", pre-join | `Meeting join \| Daily AI team \| Medicore \| …` |
| Same, in call | `Daily AI team \| Medicore \| …` (equal to the calendar subject) |
| Screen sharing in "Daily AI team" | extra `Sharing control bar \| Medicore \| …` (AXSystemDialog, CG layer 19, 297×35); the call window itself turns AXSystemDialog with the same title |
| External-tenant meeting "Medicore/Prakikon/Levvel" (10:01), pre-join | `Meeting join \| Microsoft Teams meeting \| Medicore \| …` for ~8 s: a **generic placeholder**, not the subject |
| Same, in call (from 10:01:54) | `Medicore/Prakikon/Levvel \| Medicore \| …` (equal to the calendar subject, own tenant shown) |
| Popped-out 1:1 chat | `Chat \| Marco Spoor \| Medicore \| …` (AXDialog): pop-outs keep the `Chat` prefix, so they are rejected as section windows |
| 1:1 call with another person | **not captured yet.** Expected `<Name> \| Medicore \| …`, by analogy with the chat title; the design does not depend on it (see §3) |

Findings:

1. The call runs in its own window, which appears with the pre-join screen
   (the screen where Teams opens the microphone for the device preview). It is
   therefore present when the 5 s mic debounce fires `callStarted`.
2. Title shape: `[Meeting join | ]<call name> | <tenant> | <account email>`.
   The main window has the same shape with a section name (`Chat`,
   `Calendar`, …) as its first component.
3. For a scheduled meeting, `<call name>` equals the calendar event's title.

**Still to prove in the running app:** Casablanca reads titles through
`CGWindowListCopyWindowInfo` and `kCGWindowName`, which needs the Screen
Recording permission the app already holds, not Accessibility. On macOS both
report the same `NSWindow` title. The in-app check (§7) confirms it. If
`kCGWindowName` turns out empty for Teams, the feature does nothing and the
behaviour is today's (§4).

## Goals

1. A call whose window names a meeting that is running in the calendar is
   recorded into **that** event, even when another event overlaps.
2. A call whose name matches no running event (an ad-hoc 1:1, a "Meet now", a
   meeting not in this calendar) is **not** attached to an overlapping event.
   It becomes a manual meeting **named after the call**, e.g. `Marco Spoor`
   or `Meeting with Youri Broekhuizen`.
3. Without a readable call title (no Screen Recording, Teams changed its
   title format, the window is not there yet) the behaviour is exactly
   today's.

## Non-goals

- No Accessibility permission request. Screen Recording only, which the app
  already has; never prompt for it from this path.
- No renaming a meeting after the fact when the title only shows up later in
  the call (possible follow-up).
- No widening of the 10-minute early-join window, even for a title match
  (possible follow-up).
- Classic Teams (`com.microsoft.teams`) and Teams in a browser are out of
  scope. Auto-record already watches only `com.microsoft.teams2` audio.

## Design

### 1. `TeamsCallWindowTitle` (pure parser)

```swift
struct TeamsWindow: Equatable { let number: Int; let title: String }

enum TeamsCallWindowTitle {
    /// The call's name from Teams windows, or nil when no window is a call
    /// window. Several distinct names: the newest window (highest number) wins.
    static func callName(fromWindows windows: [TeamsWindow]) -> String?
    /// One title → call name, or nil for main/section windows.
    static func callName(fromWindowTitle title: String) -> String?
}
```

Rules for a single title:

1. Split on `" | "`, trim each component, drop empty components.
2. If the last component contains `@`, drop it together with the one before it
   (account email + tenant name). Otherwise leave the title alone: the format
   is not the known one, so return nil (stay conservative).
3. If the first remaining component is a pre-join token (`Meeting join`;
   Dutch-UI variant added once captured), drop it.
4. If nothing is left → nil.
5. If the first remaining component is in `nonCallFirstComponents` (one static
   `Set`, compared case-insensitively) → nil. These are the main window's
   sections and Teams' own auxiliary windows. English and Dutch UI:
   `Activity, Chat, Teams, Calendar, Calls, OneDrive, Files, Apps, Copilot,
   Communities, Assignments, Approvals, Planner, Shifts, Settings, Help,
   Search, Notifications, Sharing control bar, Activiteit, Agenda, Oproepen,
   Bestanden, Instellingen, Zoeken, Meldingen, Vergaderingen`.
6. Otherwise rejoin the rest with `" | "`, since a meeting title can itself
   contain `" | "`. The result is the call name.

For several windows, apply the rules to each and drop nils. If more than one
distinct name remains (a stray pop-out next to the call), the window with the
highest `kCGWindowNumber` wins: the call window is the newest. This is a
deliberate heuristic, so it is logged when it fires.

### 2. `TeamsWindowTitleReader` (system boundary)

```swift
@MainActor
protocol TeamsWindowTitleReading {
    /// All titled com.microsoft.teams2 windows; empty without permission.
    func teamsWindows() -> [TeamsWindow]
}
struct CGTeamsWindowTitleReader: TeamsWindowTitleReading { … }
```

- Return `[]` without calling CG when `CGPreflightScreenCaptureAccess()` is
  false. Preflight never prompts.
- Find the PIDs of `NSRunningApplication`s whose `bundleIdentifier ==
  "com.microsoft.teams2"`. The bundle ID must match exactly: helper, WebView
  and notification-center processes have their own bundle IDs and must be
  ignored.
- `CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements],
  kCGNullWindowID)`, keeping windows of those PIDs that have a non-empty
  `kCGWindowName`, **on any layer**. During screen sharing the call window
  becomes a floating panel, and the sharing bar sits on layer 19. Window
  kind is left to the parser's denylist, not a layer filter. Off-screen
  windows count, because a call window can sit on another Space or be
  minimized.
- Diagnostics: once per call start, log at `notice` the number of Teams
  windows, how many have a title, and each window's layer. **Never log raw
  titles**: they contain the account email and chat members' names.
- Testability: the window list and the PID lookup are injected closures with
  the real ones as defaults. The reader is called once per call start.

### 3. Policy changes (`TeamsAutoRecordPolicy`)

`resolveEvent` and `startDecision` take a new `callName: String?`. Its default
is nil, so existing call sites and tests are unchanged.

```text
live = events running from start − 10 min until end   (unchanged)
if callName == nil:            today's rule (Teams-mention preference, closest start)
else if some live event's title matches callName:
                               that event (closest start among matches)
else:                          no event → .recordManual(title: callName)
```

- **Normalize** both sides before comparing:
  - Strip leading tags, repeatedly: `[EXTERN]`, `[EXTERNAL]`, `[EXT]`,
    `FW:`, `FWD:`, `RE:`, `Canceled:`, `Cancelled:`, `Geannuleerd:`,
    `Updated:`, `Bijgewerkt:`.
  - Fold case and diacritics.
  - Turn punctuation and symbols (emoji included) into spaces, then
    collapse whitespace.
- **Match**, first rule that yields exactly one live event wins:
  1. The normalized strings are equal.
  2. Guarded prefix: one normalized string is a whole-word prefix of the
     other, the shorter one has at least 2 words, and exactly one live
     event qualifies. So "Daily AI team" ↔ "Daily AI team — Q4" matches,
     but a one-word "Daily" never swallows "Daily AI team".

  General token-overlap fuzzing is left out: it is the matcher most likely
  to attach a 1:1 to the wrong meeting, which is the bug being fixed. Which
  rule decided is logged.
- **Manual title:** the call name verbatim (`Marco Spoor`,
  `Meeting with Youri Broekhuizen`). With no call name it stays
  `Teams call HH:mm`. A 1:1 is not told apart from a meeting: the name is
  all we know, and the brief asks for the recording to be named after the
  person or meeting. The reviewer suggested `Teams call — Marco Spoor`
  instead. That is a one-line change if Youri prefers it during the in-app
  check.
- **Known regression risk:** today, time alone routes a meeting whose Teams
  title differs from the calendar subject correctly (e.g. the meeting-chat
  topic was renamed in Teams). Under the new rule it becomes a manual
  meeting named after the call. The normalization and prefix rule reduce
  this, and the log shows when it happens. Accepted: the recording is still
  made and named.
- A title match beats the Teams-mention preference: the window names the
  meeting outright.

The "1:1 call doesn't land in the calendar meeting" requirement (goal 2) holds
whatever the exact 1:1 title is, as long as it is not equal to the running
event's title. A section-like title (one the parser rejects) falls back to
today's behaviour.

### 4. Coordinator and host

- `TeamsAutoRecordHost` gains `func teamsCallName() -> String?`. `AppModel`
  implements it as `TeamsCallWindowTitle.callName(fromWindows:
  reader.teamsWindows())`, with the reader injected (default
  `CGTeamsWindowTitleReader()`). No protocol-extension default, so a missing
  implementation fails to compile. `FakeTeamsAutoRecordHost` in the tests
  gets `var callName: String?` and a counter of reads.
- `startDecision(…, callName: String? = nil, manualTitle: …)`. The new
  parameter goes before the defaulted `manualTitle` closure, so existing
  call sites compile unchanged.
- `TeamsAutoRecordCoordinator.callStarted` reads `host.teamsCallName()` only
  when it is needed: after the already-recording link, and only when
  `AppPreferences.teamsAutoRecordEnabled` is true and `host.isRecordingBusy`
  is false. Add an explicit guard for both, because `startDecision` checks
  them too late to save the window read.
- The `.recordManual(title:)` path already passes the title through to
  `startAutoRecording`. No change there. The `(continued)` path for an event
  that cannot take the recording is unchanged.
- Logging: `Log.recording.notice` records whether a call name was found and
  which rule decided ("title matched event", "title matched no running event",
  "no title, time-based"). The call name itself is logged with
  `privacy: .private` because it is a person's name.

### 5. Edge cases

| Case | Result |
|---|---|
| No Screen Recording permission | callName nil → today's behaviour |
| Teams main window only (call window not yet created) | parser rejects section titles → nil → today's |
| Pre-join title `Meeting join \| X \| …` | `X` |
| Two call windows | newest window (highest `kCGWindowNumber`) wins; logged |
| Calendar subject edited locally, differs from the Teams title | no match → manual meeting named after the call. Accepted: rare, and the recording is still named |
| Call name equal to an event that started > 10 min early-window rules allow (joined 15 min early) | no live event → manual meeting named after the call (same as today, but named) |
| Already recording when the call starts | unchanged (links the active recording, no title read) |
| Screen sharing starts after the call began | irrelevant: the title is read once, at call start. If it is read during sharing, the sharing bar is rejected and the call window keeps its title |
| A chat popped out next to the call | two names → the newest window wins (the call window, opened later) |
| Two Teams accounts / tenants | both main windows are section titles and are rejected; the tenant and email components are dropped from the call window |
| Notification text | "Recording started — Marco Spoor" shows the name on screen. Accepted: it is the user's own Mac, and the meeting list shows the name anyway |

### 6. Tests (XCTest, alongside `TeamsAutoRecordTests`)

- Parser: every title in the evidence table (including `Sharing control bar`);
  newest-window tie-break; a title without an email
  suffix → nil; a title whose call name contains `" | "`; Dutch section names;
  de-duplication and ambiguity for lists; empty and whitespace-only input.
- Reader: injected window list with mixed owners, layers, nil and empty
  names; preflight false → `[]` and the window list is never called.
- Policy: title matches the overlapping event → `.recordEvent` of that event
  (even when another live event mentions Teams); title matches nothing →
  `.recordManual(title: callName)` despite a live Teams event; nil callName →
  all existing expectations unchanged; diacritic/case/whitespace/punctuation
  match; `[EXTERN]`, `RE:` and `Canceled: ` tags; guarded prefix match
  (accepts 2+ words, rejects 1 word, rejects when two events qualify).
- Coordinator: fake host returns a call name → the start uses it; the
  already-recording, disabled and busy paths never read it.

### 6a. Still to capture before merge

The 1:1 call with another person and a popped-out chat window. If the 1:1
title has a prefix (e.g. `Call with X` or `Calls | X`), update rules 3 and 5
and the tests before release. That is a parser-only change.

### 7. In-app verification (Youri)

1. Debug build signed as usual, Teams auto-record on.
2. During a calendar event, take a 1:1 Teams call with a colleague → a new
   meeting named after the colleague; the calendar event's meeting untouched.
3. Join a scheduled Teams meeting → recorded into that event's meeting.
4. `log show --predicate 'subsystem == "nl.medicore.casablanca"' --last 10m`
   shows "call name found". If it shows "no title", `kCGWindowName` is
   empty for Teams under Screen Recording, and the design needs the AX
   fallback (follow-up).

## Revision 2 (2026-11-05, after code review and the 10:00 meeting capture)

1. **Generic placeholder names count as no name.** Teams shows `Microsoft
   Teams meeting` during an external meeting's pre-join. The 5 s mic debounce
   fires inside that stretch. The parser therefore rejects call names that
   normalize to a known placeholder, and the call falls back to today's
   time-based choice. Placeholders: `Microsoft Teams meeting`, `Microsoft
   Teams-vergadering`, `Microsoft Teams vergadering`, `Teams meeting`,
   `Meeting`, `Vergadering`. Without this, a scheduled external meeting would
   become a manual "Microsoft Teams meeting", which is a regression.
2. **All candidate names, matched before newest-wins.**
   - The parser returns every distinct call name, newest window first.
   - The host's `teamsCallName()` becomes `teamsCallNames() -> [String]`.
   - The policy takes `callNames: [String]` (empty = no name). Every name is
     tried against the live events, exact rule before prefix rule.
   - The first name that matches an event wins. When none matches, the
     newest name becomes the manual title.
   - The popped-out chat titles captured so far are rejected anyway (they
     keep their `Chat` prefix). This is a safety net for window kinds that
     have not been captured.
3. **One match computation.** `startDecision` returns the decision together
   with the `EventMatch` it used, and the coordinator logs that same value.
   It no longer calls `matchEvent` a second time.
4. **Skip the window read when the start will be skipped.** The read also
   doesn't happen when the selected meeting is already recording or paused.
5. **The §3 wording for multiple matches.** The exact rule picks the
   closest start among several exact matches. The prefix rule refuses when
   more than one event qualifies.
