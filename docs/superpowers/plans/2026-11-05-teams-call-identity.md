# Teams call identity — implementation plan

Spec: `docs/superpowers/specs/2026-11-05-teams-call-identity-design.md`.
Branch: `76r75r6qbh-sys/teams-call-identity`.

Test command (full suite):

```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -derivedDataPath .build/test -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
```

Tasks run in order, each TDD (failing test first) and each in its own commit.
The Xcode project has no synchronized folders: register every new source and
test file in `Casablanca.xcodeproj/project.pbxproj` (file ref, build file,
group, and the right target's Sources phase), copying the entries of a sibling
file such as `TeamsCallMonitor.swift` / `TeamsAutoRecordTests.swift`.

## Task 1 — Window-title parser and reader (spec §1, §2)

- New `Casablanca/Services/Recording/TeamsCallWindowTitle.swift`:
  `TeamsWindow`, `TeamsCallWindowTitle` (single-title rules 1–6, multi-window
  newest-wins, static `nonCallFirstComponents` set, pre-join tokens),
  `TeamsWindowTitleReading` protocol and `CGTeamsWindowTitleReader` with
  injected `preflight`, `teamsPIDs` and `windowList` closures (real defaults:
  `CGPreflightScreenCaptureAccess`, `NSWorkspace.shared.runningApplications`
  filtered on exact bundle ID `com.microsoft.teams2`,
  `CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)`).
  Diagnostics log once per read: window count, titled count, layers. Never
  raw titles.
- New `CasablancaTests/TeamsCallWindowTitleTests.swift`: every title from the
  spec's evidence table (use the literal strings, email included), the
  sharing bar, no email suffix → nil, `" | "` inside a meeting name, Dutch
  sections, newest-window tie-break, duplicate names, empty/whitespace input;
  reader: preflight false → `[]` without calling windowList; owner, empty-
  name and nil-name filtering; any layer kept.

## Task 2 — Policy matching and coordinator wiring (spec §3, §4)

- `TeamsAutoRecordPolicy`: `normalizedTitle(_:)` (tag stripping, case and
  diacritic folding, punctuation and symbols → space, whitespace collapse);
  `resolveEvent(from:now:callName:)` and
  `startDecision(…, callName: String? = nil, manualTitle: …)` per spec §3,
  including the guarded prefix rule. Return enough to log which rule decided
  (e.g. an internal `EventMatch` enum, or a log inside the policy).
  `.recordManual(title: callName)` when a name matches no live event.
- `TeamsAutoRecordHost.teamsCallName()` (no default implementation).
  `AppModel` implements it with an injected `TeamsWindowTitleReading`.
  `FakeTeamsAutoRecordHost` gets `callName` plus a read counter.
- `TeamsAutoRecordCoordinator.callStarted`: read the name only when enabled,
  not busy, and not already linked. Pass it to `startDecision`. Log found or
  not found, and the rule; the name itself goes in with `privacy: .private`.
- Tests in `CasablancaTests/TeamsAutoRecordTests.swift`: the policy cases in
  spec §6, and coordinator read gating plus pass-through. All existing tests
  stay green unchanged.

## Then

Full suite green → spec-compliance and code-quality review subagents → fix →
CHANGELOG `Unreleased` entry → hand to Youri for in-app verification (spec §7).
No PR without Youri's OK.
