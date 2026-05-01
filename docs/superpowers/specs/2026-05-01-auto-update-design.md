# Auto-Update from GitHub Releases Design

**Status:** Draft for implementation planning
**Owner:** Youri Broekhuizen
**Last updated:** 2026-05-01

## Problem

Casablanca ships as a zipped `.app` bundle attached to GitHub Releases on `76r75r6qbh-sys/meeting-assistant`. Users find out a new version exists by visiting the repo and downloading the latest zip manually. There is no in-app mechanism to discover, download, or install updates.

Goal: when the user is running an older version, the app detects the newer release on GitHub, prompts the user with the release notes, and — on confirmation — downloads, replaces, and relaunches itself.

## Goals

- The app silently checks GitHub for newer releases on launch and every 24 hours afterward.
- A manual **Check for Updates…** menu item triggers an immediate check.
- When a newer release is found, the user sees a sheet with release notes and three actions: Install, Remind Me Later, Skip This Version.
- Install downloads the zip, verifies the staged bundle, atomically swaps `Casablanca.app` with the new bundle, and relaunches.
- A failed swap leaves the existing installation untouched and recoverable.
- Auto-checks fail silently; manual checks surface errors with a useful message.
- The component layout matches the existing `Casablanca/Services/` pattern: small, focused, independently testable units.

## Non-Goals

- Sparkle integration. Custom updater is the chosen path; revisit if/when Developer ID + notarization is in place.
- EdDSA / SHA256 / cryptographic update verification. The trust boundary is HTTPS to GitHub, same as `brew install`. Documented as a known limitation.
- Delta updates. Full zip swap every time; bundle is small enough.
- Multi-architecture asset matching. Today there is one `Casablanca-X.Y.Z-macOS.zip` (arm64). Cross-arch matching is a future concern.
- Background download while the app keeps running. Download is a modal sheet to keep UX simple and avoid racing the user starting a recording mid-update.
- Authenticated GitHub API requests. Unauthenticated 60/hr budget is more than enough for one user app.
- Self-updating the updater itself. The new version's updater code becomes the active updater after relaunch.
- Telemetry / opt-in update analytics.
- Migrating users running the app from non-`/Applications` locations onto a managed install path automatically. We prompt once and then refuse to update from non-`/Applications` locations.

## Decisions

| # | Decision | Why |
|---|----------|-----|
| 1 | Custom updater service inside the app, not Sparkle. | App is currently ad-hoc signed (not Developer ID + notarized), so Sparkle's strict security path requires EdDSA appcast plumbing. Custom path stays small and matches the existing Services pattern. Sparkle can replace the custom updater later if/when Developer ID signing lands. |
| 2 | Update source is the GitHub Releases REST API on the same repository the app was built from (`76r75r6qbh-sys/meeting-assistant`), endpoint `/repos/{owner}/{repo}/releases/latest`. Prereleases use `/repos/{owner}/{repo}/releases` and pick the top entry. | Releases are already the distribution channel. No new infrastructure to host an appcast. |
| 3 | Asset selection uses a hard-coded regex `^Casablanca-([0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?)-macOS\.zip$`. | Rejects unrelated zip assets (source archives, SBOMs, etc.) and surfaces a clear `.assetNotFound` error if the release is missing the expected zip. |
| 4 | Check cadence: ~5 seconds after launch (only if more than 24 hours since the last successful check) and every 24 hours thereafter while the app is running. Plus a manual **Check for Updates…** menu item that ignores the 24h window. | Standard Mac app convention. Stays well within unauthenticated GitHub rate limits even for users who relaunch the app many times per day. |
| 5 | Prompt shows release notes (rendered from the GitHub release `body` markdown) plus three buttons: **Install Update**, **Remind Me Later**, **Skip This Version**. | Standard pattern. Release notes drive adoption; Skip prevents the prompt from becoming nag-ware on a release a user wants to avoid. |
| 6 | Skipped versions persist in `UserDefaults`. The skipped version is forgotten when a strictly newer version becomes available. | Matches Sparkle's behavior; "skip" should not silence future updates. |
| 7 | Auto-check failures are silent; the user only sees error UI when they manually triggered the check. | Auto-checks should be invisible when they fail (network offline, GitHub down, rate-limited). Manual checks need feedback so the user knows something happened. |
| 8 | Stable channel by default, with a hidden **Include prereleases** toggle in Settings revealed by Option-clicking the Updates section title. | Lets the maintainer dogfood prerelease tags without forcing every user onto unstable builds and without cluttering the default settings UI. |
| 9 | First-launch location enforcement: if `Bundle.main` is not in `/Applications`, show a one-time prompt offering to move the app there. After that, updates require `/Applications` as the install location and refuse otherwise. | Eliminates the long tail of "update failed" cases caused by running from `~/Downloads`, the build folder, or a read-only DMG. |
| 10 | Install mechanism: write a small shell script to the staging folder, spawn it via `Process` decoupled from the parent, then call `NSApp.terminate(nil)`. The script waits for the parent PID to exit, atomically swaps the bundles, and relaunches the new app via `open`. | A running app cannot replace itself; an external process must do the swap. A shell script is simpler than an XPC helper and fits the custom-updater scope. |
| 11 | Rollback: the script renames the current bundle to `Casablanca.app.old.<pid>` first; if the move-in of the new bundle fails, it restores the old bundle. If the script dies between the two moves, the `.old.<pid>` directory remains for manual recovery. | No partial states. Either the swap succeeds and the new app launches, or the old app is left intact for the next launch. |
| 12 | Staged downloads live under `~/Library/Application Support/Casablanca/Updates/staging/<version>/`. The staging directory is wiped at app launch (anything left over from a prior interrupted attempt) and after a successful install. | Predictable, sandbox-friendly location. Prevents disk-bloat from abandoned downloads. |
| 13 | Codesign sanity check: run `codesign --verify --deep --strict` on the unzipped bundle before swapping. Fails the install on mismatch. | Cheap defense against a mid-flight corrupt download or zip tampering. Works for both ad-hoc and Developer ID-signed bundles. |
| 14 | Clock and HTTP are injected as protocols on `UpdateService` so tests can drive 24h scheduling and GitHub responses without real waits or network. | Determinism. Mirrors the test pattern used by the existing recording services. |
| 15 | Logging via `OSLog` subsystem `nl.medicore.casablanca`, category `update`. | Consistent with the existing services and easy to capture from `Console.app` for support cases. |

## Architecture

Five units in `Casablanca/Services/Updates/` (new subfolder), each with one responsibility.

```
                                 ┌──────────────────────────────────┐
                                 │ UpdatePreferences (UserDefaults) │
                                 └──────────────────────────────────┘
                                                ▲
                                                │ reads / writes
            user clicks menu                    │
                  │                             │
                  ▼                             │
        ┌────────────────────┐   delegates      │
        │   UpdateService    │──────────────────┘
        │ (Observable, owns  │
        │  state machine)    │
        └────────────────────┘
            │           │           │
   uses     │     uses  │     uses  │
            ▼           ▼           ▼
   ┌───────────────┐ ┌─────────────┐ ┌────────────────┐
   │ GitHubRelease │ │ UpdateDown- │ │ UpdateInstaller│
   │     Client    │ │   loader    │ │ (script + spawn│
   │  (HTTP only)  │ │ (zip + fs)  │ │  + terminate)  │
   └───────────────┘ └─────────────┘ └────────────────┘
            ▲             │
       URL  │             │ writes to ~/Library/.../Updates/staging/
            ▼             ▼
       GitHub API    Filesystem
```

UI integration:

- `UpdatePromptView` — sheet presented on the main window when state is `.available`. Renders release notes via the existing `MarkdownConverter`, three buttons, optional "Show Details" disclosure for the full body.
- `UpdateProgressView` — modal sheet shown during `.downloading` and `.staged`. Determinate progress bar + cancel button.
- `UpdatesSettingsView` — new tab in Settings. Toggle for **Automatically check for updates** (default on). Hidden Option-click reveals **Include prereleases** toggle. "Last checked" timestamp.
- App menu — `Check for Updates…` added via `CommandGroup(after: .appInfo)` so it appears beneath "About Casablanca."

### Component contracts

**`SemanticVersion`** — value type.

```swift
struct SemanticVersion: Comparable, Codable {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: String?  // e.g. "beta.1"
    init(parsing tag: String) throws  // accepts "v0.3.0", "0.3.0-beta.1", etc.
}
```

`Bundle.main` parses its `CFBundleShortVersionString` into a `SemanticVersion` once at startup.

**`GitHubReleaseClient`** — pure HTTP, no app state.

```swift
protocol GitHubReleaseClient {
    func fetchLatestRelease(includePrereleases: Bool) async throws -> ReleaseInfo
}

struct ReleaseInfo {
    let version: SemanticVersion
    let tag: String                // raw tag, e.g. "v0.3.0"
    let title: String              // release name
    let bodyMarkdown: String       // release notes
    let assetURL: URL              // direct download URL for the macOS zip
    let assetByteCount: Int64
}
```

**`UpdateDownloader`** — file IO + zip extraction.

```swift
protocol UpdateDownloader {
    func download(
        from url: URL,
        expectedByteCount: Int64,
        progress: @escaping (Double) -> Void
    ) async throws -> URL  // returns path to the unzipped Casablanca.app inside staging
}
```

Implementation streams the response to `staging/<version>/Casablanca.zip`, unzips with `Process`/`/usr/bin/ditto -x -k`, runs `codesign --verify --deep --strict`, parses the unzipped bundle's version, and asserts it is strictly greater than the running version.

**`UpdateInstaller`** — script generator + process spawn.

```swift
protocol UpdateInstaller {
    func install(
        stagedBundle: URL,
        currentBundle: URL,
        parentProcessID: Int32
    ) throws
}
```

Writes `staging/<version>/install.sh` (template below), `chmod +x`, spawns it via `Process` with stdin/stdout/stderr redirected to `/dev/null` and the working directory set outside both bundle paths, then returns. Caller then calls `NSApp.terminate(nil)`.

The shell template, with substituted variables:

```sh
#!/bin/sh
set -u
PARENT_PID=__PARENT_PID__
CURRENT_BUNDLE=__CURRENT_BUNDLE__
STAGED_BUNDLE=__STAGED_BUNDLE__
LOG=__LOG__

log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$LOG"; }

log "waiting for parent pid $PARENT_PID to exit"
i=0
while kill -0 "$PARENT_PID" 2>/dev/null; do
  sleep 0.2
  i=$((i+1))
  if [ "$i" -gt 150 ]; then
    log "parent did not exit within 30s, aborting"
    exit 1
  fi
done

OLD_BUNDLE="$CURRENT_BUNDLE.old.$$"

log "moving $CURRENT_BUNDLE to $OLD_BUNDLE"
mv "$CURRENT_BUNDLE" "$OLD_BUNDLE" || { log "step 1 mv failed"; exit 1; }

log "moving $STAGED_BUNDLE to $CURRENT_BUNDLE"
if ! mv "$STAGED_BUNDLE" "$CURRENT_BUNDLE"; then
  log "step 2 mv failed, rolling back"
  mv "$OLD_BUNDLE" "$CURRENT_BUNDLE" || log "rollback also failed; old bundle remains at $OLD_BUNDLE"
  exit 1
fi

log "removing $OLD_BUNDLE"
rm -rf "$OLD_BUNDLE"

log "relaunching"
open "$CURRENT_BUNDLE"
```

Path substitutions are quoted as POSIX single-quoted strings to handle spaces; the substitution code escapes embedded single quotes by closing-quoting-reopening (`'\''`).

**`UpdatePreferences`** — `UserDefaults` wrapper.

```swift
struct UpdatePreferences {
    var automaticChecksEnabled: Bool
    var includePrereleases: Bool
    var skippedVersion: SemanticVersion?
    var lastCheckAt: Date?
}
```

Backed by a single `UserDefaults` suite so tests can inject an isolated suite name.

**`UpdateService`** — coordinator.

```swift
@Observable
final class UpdateService {
    enum State {
        case idle
        case checking(trigger: CheckTrigger)
        case available(ReleaseInfo)
        case downloading(ReleaseInfo, progress: Double)
        case staged(stagedBundle: URL, ReleaseInfo)
        case error(UpdateError, trigger: CheckTrigger)
    }

    enum CheckTrigger { case automatic, manual }

    private(set) var state: State

    func startScheduling()                         // called once at app launch
    func checkNow(trigger: CheckTrigger) async     // manual or auto entry point
    func installUpdate(_ release: ReleaseInfo) async
    func skipVersion(_ release: ReleaseInfo)
    func remindLater()
    func dismissError()
}
```

`startScheduling` reads `lastCheckAt`, decides whether to trigger an auto-check immediately (if `> 24h` since last) or arms a `Timer` for the remaining interval. Subsequent ticks repeat the cycle. The schedule is paused while the state is anything other than `.idle` or `.error`.

## State Machine

```
idle
  ├── (24h timer fires OR app launch OR menu click) → checking(trigger)
  └── (terminal for skip / later)

checking(trigger)
  ├── (no newer version)                  → idle
  ├── (newer version, not skipped)        → available(release)
  ├── (newer version equals skipped)      → idle
  └── (network error)
        ├── trigger=automatic             → idle (silent, log only)
        └── trigger=manual                → error(.checkFailed, .manual)

available(release)
  ├── user clicks Install                 → downloading(release, 0)
  ├── user clicks Later                   → idle (re-prompts on next check)
  └── user clicks Skip                    → idle, persist skippedVersion=release.version

downloading(release, progress)
  ├── (progress ticks)                    → downloading(release, newProgress)
  ├── (download completes)                → staged(stagedBundle, release)
  ├── (cancel)                            → idle
  └── (failure)                           → error(.downloadFailed, currentTrigger)

staged(stagedBundle, release)
  └── installer spawned, NSApp.terminate(nil) — process exits, no further state

error(_, trigger)
  └── user dismisses                      → idle
```

## Error Handling

`UpdateError` is one typed enum. UI maps cases to messages; auto vs manual triggers determine visibility.

| Case | When | Auto trigger | Manual trigger |
|---|---|---|---|
| `.notInApplicationsFolder` | Bundle path is not `/Applications/Casablanca.app` and the first-launch prompt has already been seen | Silent | Alert: "Move Casablanca to /Applications to enable updates." |
| `.checkFailed(URLError)` | GitHub API offline, DNS, TLS, timeout | Silent, log to OSLog, retry on next 24h tick | Alert with Retry button |
| `.rateLimited(retryAfter: Date)` | 403/429 from GitHub | Silent, suspend schedule until `retryAfter` | Alert: "GitHub rate limit hit, try again in N minutes" |
| `.malformedResponse` | API returns non-JSON or unexpected structure | Silent | Alert: "Unexpected response from GitHub" |
| `.assetNotFound` | Latest release has no asset matching the regex | Silent | Alert: "No macOS asset found in latest release" |
| `.downloadFailed(URLError)` | Network drop mid-download | Alert with Retry / Cancel | Same |
| `.unzipFailed` | Corrupt zip, no `.app` bundle inside | Alert: "Update download was corrupt" | Same |
| `.versionRegression` | Unzipped bundle version ≤ running version | Alert: "Update package was older than current version. Cancelling." | Same |
| `.codesignFailed` | `codesign --verify` fails on staged bundle | Alert: "Update signature check failed. Update was not installed." | Same |
| `.swapFailed(reason)` | `mv` fails because directory not writable, disk full, or installer script killed | Alert with rollback message: "Your existing app is unchanged." | Same |

All errors log through `OSLog` with subsystem `nl.medicore.casablanca`, category `update`, including correlation info (release tag, asset URL, staging path).

## Storage Layout

```
~/Library/Application Support/Casablanca/Updates/
└── staging/
    └── <version>/
        ├── Casablanca.zip
        ├── Casablanca.app/      (unzipped, awaiting swap)
        ├── install.sh
        └── install.log
```

- The whole `staging/` directory is wiped at app launch (anything older than the most recent attempt) and after a successful install.
- A failed install leaves `install.log` in place for diagnosis. Settings → Updates pane has a "Reveal staging folder" button (debug-only, behind the same Option-click that exposes prereleases) that opens this directory in Finder.

## Settings Pane

New tab in `SettingsView`:

```
┌─────────────────────────────────────────────────────┐
│ Updates                                             │
│                                                     │
│ ☑ Automatically check for updates                   │
│   Checks GitHub every 24 hours.                     │
│                                                     │
│ Last checked: 2026-04-30 14:22                      │
│                                                     │
│ [ Check for Updates… ]                              │
│                                                     │
│ ┌─ hidden (Option-click section title) ──────────┐ │
│ │ ☐ Include prereleases                          │ │
│ │ [ Reveal staging folder in Finder ]            │ │
│ └────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────┘
```

The hidden block toggles visibility on Option-click of the "Updates" header label, persisted only for the current Settings window session.

## First-Launch Location Check

Added to `CasablancaApp.swift`'s top-level `.task` after the existing permissions check:

```swift
await appModel.permissionsManager.checkAll()
appModel.applicationsLocationCheck.runOnceIfNeeded()
appModel.updateService.startScheduling()
```

`ApplicationsLocationCheck` is a small helper (sibling to `Permissions.swift` in `Utilities/`):

- Reads `Bundle.main.bundleURL`. If it equals `/Applications/Casablanca.app`, return.
- If a `UserDefaults` flag `applicationsLocationPromptShown` is set, return.
- Otherwise show an alert: "Casablanca runs best from the /Applications folder. Move it there now? Auto-update requires this." Buttons: **Move to Applications** | **Not Now**.
- On "Move to Applications": copy the bundle to `/Applications/`, launch the new copy via `open`, terminate the current process.
- On "Not Now": set the flag and dismiss. Updates will be refused with `.notInApplicationsFolder` until the user moves the app manually.

Errors during the move (e.g., `/Applications/Casablanca.app` already exists with a different bundle, or copy fails) surface as a follow-up alert and the flag is *not* set so the user gets prompted again next launch.

## Testing Plan

Unit tests live in `CasablancaTests/Updates/` (new folder):

| Test target | Covers |
|---|---|
| `SemanticVersionTests` | Parsing of `v0.3.0`, `0.3.0`, `0.3.0-beta.1`, `0.3.0+build.7`. Comparison: `0.3.0 > 0.2.99`, `0.3.0 > 0.3.0-beta.1`, `0.3.0-beta.2 > 0.3.0-beta.1`. Throws on malformed input. |
| `GitHubReleaseClientTests` | Stubbed via `URLProtocol`. Asserts: parses `latest` JSON, parses `releases` list and picks first prerelease when prereleases enabled, picks the right asset by regex, surfaces `.rateLimited(retryAfter)` from 429 with `Retry-After` header, surfaces `.malformedResponse` on bad JSON, surfaces `.assetNotFound` when the matching zip is missing. |
| `UpdatePreferencesTests` | UserDefaults round-trip with an injected suite name. Skipped-version persistence, `lastCheckAt`, defaults match the spec. |
| `UpdateServiceTests` | Injects fake `GitHubReleaseClient`, fake `UpdateDownloader`, fake `Clock`, in-memory `UpdatePreferences`. Asserts every transition in the state machine, both auto and manual triggers, error visibility difference, 24h scheduling cadence, skip-then-newer-version behavior. |
| `UpdateDownloaderTests` | Uses a `file://` URL pointing at a fixture zip in the test bundle (`Tests/Fixtures/Casablanca-99.0.0-macOS.zip` containing a stub bundle with that version). Asserts progress callbacks fire monotonically, output bundle exists, version-regression detection trips on an older fixture, codesign verify path is exercised against a real ad-hoc signed fixture. |
| `UpdateInstallerScriptTests` | Generates the script as a string; asserts it contains the `kill -0` wait loop, the rollback path on step-2 failure, correct POSIX-quoted paths for inputs containing spaces, `'`, and `$`. Does not execute the script. |
| `ApplicationsLocationCheckTests` | Injects bundle URL + UserDefaults; asserts the prompt is shown only when bundle is not in `/Applications` and the flag is unset. |

All time-dependent paths use an injected `Clock` so the 24h scheduling is testable without real waits.

Manual verification (run before merging the PR):

1. Run from `~/Downloads` → first-launch prompt to move to `/Applications` appears. Click "Not Now" → updates are refused. Move manually to `/Applications` → updates work.
2. Mark a test release `v999.0.0` on the repo → in-app prompt appears within 5 seconds of launch → click Install → progress sheet → app quits, replaces, relaunches as v999.0.0. Tear down the test release after.
3. Click Skip on the test release → restart app → prompt does not reappear. Publish `v999.0.1` → prompt reappears.
4. Disconnect network, click "Check for Updates…" → error alert with retry. Reconnect → retry succeeds.
5. Force-kill the installer script mid-swap (`pkill -f install.sh` between the two `mv` calls) → on next launch the original app launches normally, the `.old.<pid>` directory is still in `/Applications` for recovery.
6. Toggle "Include prereleases" → mark the test release as prerelease → verify it's offered.
7. With the app running, watch `Console.app` filtered by subsystem `nl.medicore.casablanca` and category `update` for the full audit trail of a check + install cycle.

## Phasing for Implementation Plan

Each step is independently mergeable; the service layer is fully testable before any UI is wired.

1. `SemanticVersion` value type + tests.
2. `GitHubReleaseClient` protocol + URLSession implementation + `URLProtocol`-stubbed tests.
3. `UpdatePreferences` UserDefaults wrapper + tests.
4. `UpdateService` skeleton with state machine + tests using fakes for downloader/installer/client/clock.
5. `UpdateDownloader` URLSession + ditto-based unzip + codesign check + tests against fixture zip.
6. `UpdateInstaller` script generator + Process spawn + tests for script content (no execution).
7. `ApplicationsLocationCheck` helper + tests + wiring into `CasablancaApp`.
8. `UpdatePromptView` SwiftUI sheet + release-notes markdown rendering.
9. `UpdateProgressView` SwiftUI sheet.
10. `UpdatesSettingsView` SwiftUI tab + Option-click reveal for prereleases / staging-folder button.
11. App menu integration (`Check for Updates…` via `CommandGroup(after: .appInfo)`).
12. End-to-end manual verification pass + README docs update describing how update checking works and how to back out via the `.old.<pid>` directory.

## Known Limitations

- Trust boundary is HTTPS to GitHub. A compromised GitHub account could push a malicious release. Mitigation: switch to Sparkle + EdDSA when Developer ID + notarization is in place.
- Update from non-`/Applications` locations is intentionally refused after the one-time prompt is dismissed. The user must move the app manually to re-enable updates.
- The installer script's parent-PID wait timeout is 30 seconds; if the app refuses to terminate (e.g., a recording is mid-stop), the install aborts and the user must retry. Acceptable trade-off vs. force-killing a recording.
- Single arm64 macOS asset only. If the project ever ships a universal binary or x86_64 build, the asset selection regex must change.
- Self-update of the updater itself relies on the new bundle's updater code being correct. A regression in the updater inside a shipped release that breaks future updates can only be recovered by manually downloading the next release. Acceptable risk for a small project; mitigated by keeping the updater logic narrow and well-tested.
