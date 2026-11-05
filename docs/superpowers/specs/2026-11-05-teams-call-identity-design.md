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
| Shared-content pop-out while sharing in "Medicore/Prakikon/Levvel" | `Shared content \| Medicore/Prakikon/Levvel \| Medicore \| …`: `Shared content` is stripped like `Meeting join` |
| 1:1 call with another person (14:00, Ryanne) | `Ryanne Makor \| Medicore \| <email>` from the first sample on: no pre-join screen, no prefix. The main window keeps `Chat \| Ryanne Makor \| …` alongside it |

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
| Meeting whose real subject equals a placeholder (e.g. 'Meeting') | always time-based; accepted |

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

Captured 2026-11-05 14:00: the 1:1 call window is titled `<Name> | <tenant> |
<email>` with no prefix, and the popped-out chat keeps its `Chat` prefix.
Both fit the parser as written; no rule change was needed.

Gap found in the same capture (not covered by this branch): the 1:1 started
nine minutes after the previous Teams meeting (Healthtalk, 13:01) ended, yet
the mic monitor logged one call from 13:01 to 14:30. Teams kept microphone
input running in between, so no new call start fired and the 1:1 was never
auto-recorded. Call names are only read at a call start, so this design
cannot catch a back-to-back call. A follow-up would treat a change of the
newest call name during a running call as a new call.

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
   fires inside that stretch. The parser therefore rejects a title when any
   remaining component (after the email/tenant suffix and the pre-join token
   are stripped) normalizes to a known placeholder, not only when the joined
   name does: an unknown pre-join token (e.g. a Dutch-UI `Deelnemen aan
   vergadering`) can sit in front of the placeholder. The call then falls
   back to today's time-based choice. Placeholders (EN/NL UI only):
   `Microsoft Teams meeting`, `Microsoft Teams-vergadering`, `Microsoft Teams
   vergadering`, `Teams meeting`, `Teams-vergadering`, `Meeting`,
   `Vergadering`. Without this, a scheduled external meeting would become a
   manual "Microsoft Teams meeting", which is a regression. The policy's
   `matchEvent` filters placeholders again as deliberate defence-in-depth.
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

## Revision 3 (2026-11-05): a new call during a running call

### Evidence

At 13:01 the Healthtalk meeting started; the mic monitor reported a call
start and the recording was linked to it. Youri stopped the recording by hand
at 13:40. The Healthtalk call window was gone by about 13:51. At 14:00:44 a
1:1 call window `Ryanne Makor | Medicore | <email>` opened, and it closed at
about 14:29. Casablanca's log shows one mic call from 13:01 to 14:30: Teams
kept microphone input running throughout. No call start fired at 14:00, so
the 1:1 was not recorded. The call names are read only at a call start, so
Revisions 1–2 cannot catch this either.

### Goal

When the call window's name changes to a new call while the mic monitor
still reports the same call, treat it as the old call ending and a new call
starting. In the case above, the 1:1 is then recorded as a manual meeting
"Ryanne Makor".

### Rule: `TeamsCallSwitchDetector` (pure value type, clock passed in)

It lives in `TeamsAutoRecordCoordinator.swift` beside the policy and is owned
by the coordinator. Names are compared in normalized form
(`TeamsAutoRecordPolicy.normalizedTitle`).

- **State:**
  - `knownNames`: every normalized name seen during the current call;
  - `pendingName`: a candidate switch waiting for confirmation, with its
    first sighting time;
  - `lastCheck`: when names were last read.
- **`begin(names:at:)`**, at every call start (real or switched): sets
  `knownNames` to the names read at the start (possibly empty), clears
  `pendingName`, and sets `lastCheck`.
- **`shouldCheck(at:)`**: true when at least `checkInterval` (10 s) has passed
  since `lastCheck`. The window server is not read on every monitor tick;
  ticks come from every CoreAudio callback plus a 5 s poll.
- **`observe(names:at:) -> String?`** returns the confirmed new call name, or
  nil. It always sets `lastCheck`.
  1. `names` empty (no permission, Teams hidden, between calls): nothing
     changes and `pendingName` is kept. A missing title is never evidence of
     a new call.
  2. `knownNames` empty (no baseline: titles unreadable at the start, or the
     start skipped the read because it was busy or disabled): adopt all of
     `names` as known and return nil. With no baseline there is no telling
     whether this is a new call.
  3. Let `newest = names[0]`. If `newest` is in `knownNames`, clear
     `pendingName`, add the other names to `knownNames`, and return nil.
  4. Otherwise `newest` is a candidate. If `pendingName` is the same
     normalized name and its first sighting is at least `confirmAfter` (10 s)
     ago, return it; the coordinator then restarts the detector via `begin`.
     If `pendingName` differs or is unset, set it to `newest` with first
     sighting = now, and return nil.
  - Why "newest" and not "every name new": while a call is on hold its window
    probably stays open. A 1:1 accepted during a meeting would leave the
    meeting's name present, and "every name new" would miss the main case.
    The parser already rejects the main window, chat pop-outs and the
    sharing bar. A shared-content pop-out repeats the meeting's name, which
    is known.
  - Why confirmation: Teams opens and retitles windows during transitions.
    Two reads at least 10 s apart that agree keep a flicker from splitting a
    recording. A switch is then detected 10–20 s after the new window shows
    a name, which is in line with the 5 s start debounce.
  - Going back to a held call after the 1:1 ends: once the 1:1's window
    closes, the old call's window is newest again. Its name is no longer
    known after the switch's `begin`, so it counts as another switch. The
    resumed meeting is recorded again, as "(continued)" if its meeting was
    already stopped (`canRecordInto`). That is intended.

### Coordinator

- `callStarted()` (the mic edge): after deciding, calls `detector.begin` with
  the names it read. When it skipped the read, it passes `[]`, so the
  baseline is adopted on the first check.
- `callTick()` keeps linking a mid-call recording. Then, when `isCallLive`,
  auto-record is enabled, no switch is in flight and
  `detector.shouldCheck(at: now())`, it reads `host.teamsCallNames()` and
  feeds `observe`. With auto-record off it never reads titles during a call:
  a switch would only auto-stop, and the mic end still does that.
- **On a confirmed switch,** set `isSwitchInFlight` and start a Task that:
  1. logs `Teams call switched: a new call window (name private) replaced
     the running call; ending the old call and starting a new one`;
  2. runs the existing `callEnded()` path. With auto-stop on, this stops the
     linked recording when it is still the active one; otherwise nothing.
     This is right: the old call's window is no longer the newest call
     window;
  3. runs `callStarted()`. This bumps the generation, sets `isCallLive`, and
     picks the meeting with the usual policy and the freshly read names;
  4. clears `isSwitchInFlight`.
- `callEnded()` and `reset()` also reset the detector. The real mic end
  later ends the switched call as usual.
- Race: a mic `callEnded` during the switch Task is covered by the
  generation counter as today. The switch's own `callStarted` checks
  `isCallLive` afterwards: when the real end arrived meanwhile it must not
  leave a live call behind. Implementation: the switch Task captures
  `callGeneration` before step 2, and skips step 3 when the generation moved
  by more than the one bump that step 2 itself causes.

### Edge cases

| Case | Behaviour |
|---|---|
| Back-to-back: meeting ends, 1:1 starts with no mic gap (today's evidence) | Switch after confirmation; 1:1 recorded as "Ryanne Makor"; nothing stopped (already stopped by hand) |
| Meeting still recording when the 1:1's window opens on top (meeting on hold) | Auto-stop on: the meeting's recording stops and the 1:1 records separately. Auto-stop off: the meeting keeps recording and the switch's start is skipped because the recording is busy; logged |
| Screen sharing / shared-content pop-out | No switch: the sharing bar is rejected and the pop-out repeats a known name |
| A Teams title flickers to an unknown window for one read | No switch: needs two agreeing reads 10 s apart |
| No Screen Recording permission | Names are always empty, so there is never a switch (today's behaviour) |
| Auto-record off, auto-stop on | No title reads during a call; no switch |
| Same meeting re-joined (same name) | No switch: the name is known |
| Meeting renamed mid-call in Teams | Switch: one recording becomes two. Rare; accepted and logged |

### Tests

- **Detector:**
  - baseline adoption;
  - empty reads keep pending;
  - known newest name clears pending;
  - confirmation needs the same name at least 10 s later;
  - a different candidate restarts the pending;
  - normalized comparison;
  - `shouldCheck` throttling.
- **Coordinator, using the fake host and an injected clock:**
  - back-to-back switch starts a manual "Ryanne Makor" with nothing linked;
  - a switch while the linked recording is active stops it (auto-stop on)
    and then starts the new call;
  - no reads when auto-record is off;
  - the throttle limits reads;
  - a mic end during the switch leaves no live call;
  - a flicker of one read does not switch.

### Revision 3 amendments (after the spec review)

These override the Revision 3 text above where they differ.

1. **The switch happens synchronously in `callTick` (was blocker 1).**
   - `callEnded()` splits into a synchronous `endCallBookkeeping() -> UUID?`
     and the async stop. The bookkeeping bumps `callGeneration`, sets
     `isCallLive = false`, clears `linkedMeetingID` and resets the detector,
     and returns the meeting the stop should act on. The stop then applies
     `shouldAutoStop`, unchanged.
   - When `callTick` confirms a switch, it does all of the following
     synchronously before any Task exists:
     - logs the switch;
     - runs `endCallBookkeeping()`;
     - captures `callGeneration` after that bump;
     - sets `isSwitchInFlight = true`.
   - It then stores `switchTask = Task { … }` (`private(set)`, so tests can
     await it). The Task:
     1. runs the async stop for the returned meeting, if any, when it is
        due;
     2. starts the new call with `callStarted()` only if `callGeneration` is
        still the captured value. A mic end or a `reset()` that arrived at
        any point after the confirmation (before the Task ran, or during the
        stop) moved the generation, so no call is left live;
     3. always clears `isSwitchInFlight` at the end.
   - `reset()` also clears `isSwitchInFlight`.
   - `handleStartThatOutlivedItsCall` treats `isSwitchInFlight` like
     `isCallLive`, so a slow start is not stopped during the switch gap.
2. **`detector.begin` on every exit of `callStarted`, including the
   already-recording early return and `.skip`.** It gets the call windows
   read for that start, or `[]` when there was no read. The edge-case table
   is corrected: with the meeting still recording on hold and auto-stop off,
   the switch's `callStarted` links the still-running recording to the new
   call ("already recording"). Nothing is stopped or started, and it is
   logged.
3. **Calls are identified by window, not by name alone.**
   - The parser gains `callWindows(fromWindows:) -> [TeamsCallWindowName]`
     with `number`, `name` and `isPreJoin`, newest first, not deduplicated.
     `callNames(fromWindows:)` is derived from it: the same dedup, newest
     first, as today.
   - The host's `teamsCallNames()` is replaced by `teamsCallWindows() ->
     [TeamsCallWindowName]`. The coordinator derives the names for the start
     decision.
   - The detector tracks `knownNumbers` and `knownNames`. Pre-join windows
     are ignored entirely: they are never known and never a candidate.
   - **Candidate:** the newest non-pre-join window, when its number is not in
     `knownNumbers` and its normalized name is not in `knownNames`.
   - A known window that is retitled has its new name adopted as known, with
     no switch. This covers a meeting renamed mid-call and a 1:1 turned into
     a group call. A new window with a known name is adopted too (a
     shared-content pop-out, or an in-call window opened after a separate
     pre-join window).
   - Confirmation is by window number: the same number has to be the
     candidate on two reads at least `confirmAfter` (10 s) apart.
   - With no baseline (nothing known yet), all non-pre-join windows are
     adopted.
   - In the back-to-back case, Ryanne's window is a new number with an
     unknown name, so it switches.
4. **No log line per check.** `TeamsCallWindowTitle` no longer logs the
   multiple-names notice. The coordinator logs the count once, at the call
   start, in `logCallNames`. The detector's reads log nothing unless a
   switch is confirmed. The switch log names no call: window numbers and
   counts only, and any name stays `.private`.
5. **Accepted and documented:**
   - A switch auto-stops a linked recording the user started by hand. This
     is the same rule as at the mic end.
   - Detection takes up to about 25 s (poll quantization plus
     confirmation), so the first part of the new call is not recorded.
6. **Still to capture before merge:**
   - an incoming call ringing during a meeting: is the ring toast a titled
     Teams window in the `… | tenant | email` format? If it is, a ring of
     10 s or more would switch, and with auto-stop on it would stop the
     meeting;
   - breakout rooms.

   Both go to Youri's in-app check. If the ring toast is titled, it must be
   rejected in the parser before merge.
7. **A switch's baseline is the new call only (after the code review).**
   - A switch-initiated start passes `detector.begin` only the switch's
     window plus windows sharing its normalized name, not every window it
     read. A mic-edge start keeps all windows it read, as before.
   - Otherwise the held meeting's window becomes known at the 1:1's start,
     and going back to it after the 1:1 is no switch: the rest of the
     meeting would land in the 1:1's recording. Going back is a switch, as
     the Revision 3 text says.
   - When a known window is newest, the detector adopts only that window
     and windows with known names. A pending unknown window that a newer
     known pop-out overtook stays a candidate.
