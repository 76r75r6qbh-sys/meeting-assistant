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
- Install downloads the zip, strips macOS quarantine, atomically swaps `Casablanca.app` with the new bundle, and relaunches.
- A failed swap leaves the existing installation untouched — no half-replaced state on disk.
- The relaunched app launches cleanly without Gatekeeper "damaged" dialogs even though the bundle is only ad-hoc signed.
- Auto-checks fail silently; manual checks and any error after the user clicks Install surface alerts with a useful message.
- Install refuses to start when a recording is in progress; the user is asked to stop the recording first.
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
- Force-quitting an active recording so an install can proceed. Install is gated on the user stopping the recording first.

## Decisions

| # | Decision | Why |
|---|----------|-----|
| 1 | Custom updater service inside the app, not Sparkle. | App is currently ad-hoc signed (not Developer ID + notarized), so Sparkle's strict security path requires EdDSA appcast plumbing. Custom path stays small and matches the existing Services pattern. Sparkle can replace the custom updater later if/when Developer ID signing lands. |
| 2 | Update source is the GitHub Releases REST API on the same repository the app was built from (`76r75r6qbh-sys/meeting-assistant`), endpoint `/repos/{owner}/{repo}/releases/latest`. Prereleases use `/repos/{owner}/{repo}/releases` and pick the top entry. | Releases are already the distribution channel. No new infrastructure to host an appcast. |
| 3 | Asset selection uses a hard-coded regex `^Casablanca-([0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?)-macOS\.zip$`. | Rejects unrelated zip assets (source archives, SBOMs, etc.) and surfaces a clear `.assetNotFound` error if the release is missing the expected zip. |
| 4 | Check cadence: ~5 seconds after launch (only if more than 24 hours since the last successful check) and every 24 hours thereafter while the app is running. Plus a manual **Check for Updates…** menu item that ignores the 24h window. | Standard Mac app convention. Stays well within unauthenticated GitHub rate limits even for users who relaunch the app many times per day. |
| 5 | Prompt shows release notes (rendered from the GitHub release `body` markdown) plus three buttons: **Install Update**, **Remind Me Later**, **Skip This Version**. | Standard pattern. Release notes drive adoption; Skip prevents the prompt from becoming nag-ware on a release a user wants to avoid. |
| 6 | Skipped versions persist in `UserDefaults`. The user is re-prompted whenever the latest release's `SemanticVersion` is strictly greater than the skipped one — including the cases `0.4.0 > 0.4.0-beta.2` (stable beats prerelease at the same MMP), `0.4.1-beta.1 > 0.4.0` (next MMP beats current stable), and `0.4.0-beta.3 > 0.4.0-beta.2`. The case `0.4.0-beta.1` ⊀ `0.4.0` is explicitly *not* re-prompted (a stable equal-or-lower than the skipped prerelease's MMP is treated as the same version family). | Matches Sparkle's behavior; "skip" should not silence future updates. SemVer-precedence rules are spelled out so prerelease boundary cases are unambiguous. |
| 7 | Auto-check failures are silent; manual-check failures surface alerts; any error after the user has clicked **Install** always surfaces an alert regardless of the original check trigger. | Auto-checks should be invisible when they fail. Once the user has explicitly committed to installing, silent failure is wrong — they need feedback. |
| 8 | Stable channel by default, with a hidden **Include prereleases** toggle in Settings revealed by Option-clicking the Updates section title. | Lets the maintainer dogfood prerelease tags without forcing every user onto unstable builds and without cluttering the default settings UI. |
| 9 | First-launch location enforcement: if `Bundle.main` is not in `/Applications`, show a one-time prompt offering to move the app there. After that, updates require `/Applications` as the install location and refuse otherwise. The check explicitly handles the Gatekeeper translocation case (a randomized `/private/var/folders/.../AppTranslocation/.../Casablanca.app` path). | Eliminates the long tail of "update failed" cases caused by running from `~/Downloads`, the build folder, or a read-only DMG. |
| 10 | The atomic bundle swap is performed by the running parent app via `FileManager.replaceItem(at:withItemAt:backupItemName:options:resultingItemAt:)`, which uses APFS `renamex_np` under the hood for an atomic directory swap. The swap completes *before* the parent terminates. | A two-step `mv` from a shell script has a window where `/Applications/Casablanca.app` does not exist — power loss or `pkill` in that window leaves the user with no app. Doing the swap from Swift with `replaceItem` removes that window entirely. APFS guarantees: either the swap succeeded and the new bundle is in place, or it failed and the original bundle is untouched. |
| 11 | After the swap, the parent app spawns a tiny relaunch script and immediately calls `NSApp.terminate(nil)`. The script waits for the parent to fully exit (using a sentinel file written at app start and removed in `applicationWillTerminate`, plus a PID-and-start-time check as a fallback), then runs `open -n /Applications/Casablanca.app`. | The swap has already happened, so the script's only job is to launch the new bundle once the old process is gone. PID-only waiting is racy under PID reuse; a sentinel file is reliable. |
| 12 | Install is gated on a "safe to quit" precondition: no active recording, no in-flight transcription or summarization. If unsafe, the install is refused with a clear message asking the user to finish or stop the recording first. | `MenuBarExtra` and an `NSApplicationDelegate` could veto `NSApp.terminate`; rather than racing termination, we just don't start the install when state is hot. Worst case: user dismisses the alert, stops the recording, clicks Install again. |
| 13 | Quarantine attribute removal: after unzip, the staged bundle has `com.apple.quarantine` removed recursively (via `xattr -dr` in a `Process` invocation). | `URLSession` writes downloads with the quarantine xattr set; `ditto -x -k` propagates it to every file in the unzipped bundle. After the swap, an ad-hoc-signed bundle with quarantine set fails Gatekeeper and shows the "Casablanca.app is damaged" dialog. Stripping quarantine *after* unzip and *before* swap means the user-installed bundle launches cleanly. |
| 14 | Staged downloads live under `~/Library/Application Support/Casablanca/Updates/staging/<version>/` (wiped at app launch and after a successful install). Install logs are kept in `~/Library/Application Support/Casablanca/Updates/logs/install-<timestamp>.log` (NOT wiped). | Predictable, sandbox-friendly location. The separate logs directory means a failed install's diagnostic record survives the next-launch staging wipe. |
| 15 | Codesign sanity check: run `codesign --verify --deep --strict` on the unzipped bundle before swapping. Treated as a corruption check (detects bit-flips and incomplete downloads), not a tamper-detection mechanism. | For an ad-hoc-signed bundle, this verifies the seal is intact and the resources match the signature. It does *not* prove the release came from us — that is the trust-in-GitHub limitation in Non-Goals. The corruption check still has value: it catches truncated downloads and zip corruption before we touch `/Applications`. |
| 16 | The relaunch script is spawned via `posix_spawn` with `POSIX_SPAWN_SETSID` so the helper becomes a session leader and survives the parent process group's termination. stdin/stdout/stderr redirected to `/dev/null`; working directory set to `/`. | A `Process`-spawned child inherits the parent's process group; signals from the parent's terminal can propagate. `POSIX_SPAWN_SETSID` decouples the helper into its own session, guaranteeing it survives `NSApp.terminate`. |
| 17 | Clock and HTTP are injected as protocols on `UpdateService` so tests can drive 24h scheduling and GitHub responses without real waits or network. `lastCheckAt` is updated only after a successful check (HTTP 200 with parseable response); failed checks do not advance the timer. | Determinism. Failed checks must not silence the next 24h tick — otherwise an offline-at-launch user gets one check attempt and then nothing for 24 hours. |
| 18 | `URLSession` is configured to follow redirects (default behavior), with a custom `URLSessionTaskDelegate.urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:)` that strips `Authorization` headers across origin boundaries. Today no auth headers are sent (Non-Goal: unauthenticated requests), but the redirect handler is included as a guard for any future auth additions. | GitHub release asset URLs 302 to `objects.githubusercontent.com`. Default redirect-following works; the explicit delegate is a safety belt. |
| 19 | Logging via `OSLog` subsystem `nl.medicore.casablanca`, category `update`. | Consistent with the existing services and easy to capture from `Console.app` for support cases. |

## Architecture

Six units in `Casablanca/Services/Updates/` (new subfolder), each with one responsibility.

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
        │       │       │       │
        ▼       ▼       ▼       ▼
  ┌──────┐ ┌──────┐ ┌──────┐ ┌──────────┐
  │GitHub│ │Update│ │Update│ │SafeToQuit│
  │Client│ │Down- │ │Inst- │ │  Probe   │
  │      │ │loader│ │aller │ │          │
  └──────┘ └──────┘ └──────┘ └──────────┘
     ▲        │        │
URL  │        │        │
     ▼        ▼        ▼
 GitHub   Filesystem  posix_spawn
  API     + xattr     + atomic swap
```

UI integration:

- `UpdatePromptView` — sheet presented on the main window when state is `.available`. Renders release notes via the existing `MarkdownConverter` (which targets CommonMark; release notes' GitHub-flavored extensions like `@user` mentions and `#1234` issue refs render as plain text — acceptable for v1, see Known Limitations).
- `UpdateProgressView` — modal sheet shown during `.downloading` and `.staged`. Determinate progress bar + cancel button.
- `UpdatesSettingsView` — new tab in Settings. Toggle for **Automatically check for updates** (default on). Hidden Option-click reveals **Include prereleases** toggle and a "Reveal install logs" button. "Last checked" timestamp.
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

Comparison follows SemVer 2.0.0: major/minor/patch compared numerically; a version without a prerelease tag has higher precedence than the same MMP with a prerelease tag (so `0.4.0 > 0.4.0-beta.2`); two prerelease tags compare lexicographically by dot-separated identifiers (so `0.4.0-beta.2 < 0.4.0-beta.10` is *false* per SemVer 11.4.4 — numeric identifiers compared numerically). Build metadata (`+build.7`) is parsed but ignored for comparison.

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

URLSession uses default redirect-following with a delegate that strips `Authorization` headers across origin boundaries (Decision 18).

**`UpdateDownloader`** — split into three operations on one type so each step is independently testable and the corresponding error variants are isolated.

```swift
protocol UpdateDownloader {
    /// Streams the asset to staging/<version>/Casablanca.zip.
    /// Throws .downloadFailed on URLError; throws .rateLimited if 429 is observed mid-redirect.
    func download(
        from url: URL,
        expectedByteCount: Int64,
        progress: @escaping (Double) -> Void
    ) async throws -> URL  // path to the downloaded zip

    /// Unzips via `/usr/bin/ditto -x -k` into staging/<version>/Casablanca.app,
    /// strips com.apple.quarantine recursively, returns the bundle URL.
    /// Throws .unzipFailed if ditto fails or the result is not a .app bundle.
    /// Throws .quarantineStripFailed if xattr -dr fails.
    func extract(zipAt: URL) async throws -> URL  // path to unzipped Casablanca.app

    /// Verifies the unzipped bundle:
    ///  - codesign --verify --deep --strict (corruption check)
    ///  - reads CFBundleShortVersionString
    ///  - asserts version > running version
    /// Throws .codesignFailed or .versionRegression accordingly.
    func verify(bundleAt: URL) async throws -> SemanticVersion
}
```

**`SafeToQuitProbe`** — answers whether installing now is safe.

```swift
protocol SafeToQuitProbe {
    /// Returns nil when safe; otherwise a localized reason describing why install must wait.
    func reasonInstallShouldWait() -> String?
}
```

The default implementation checks `AudioRecordingService.isRecording`, paused recordings still bound to a meeting, and any in-flight transcription/summarization tasks tracked by `TranscriptionService` / `SummarizationService`.

**`UpdateInstaller`** — performs the atomic swap from Swift, then spawns the relaunch helper.

```swift
protocol UpdateInstaller {
    /// 1. FileManager.replaceItem swap of currentBundle ← stagedBundle. Atomic on APFS.
    /// 2. Writes a relaunch script to ~/Library/Application Support/Casablanca/Updates/relaunch-<timestamp>.sh
    ///    containing only the wait-for-parent + open -n logic.
    /// 3. Spawns the script via posix_spawn with POSIX_SPAWN_SETSID, fds redirected to /dev/null.
    /// 4. Caller is expected to call NSApp.terminate(nil) immediately after this returns.
    /// Throws .swapFailed if step 1 fails (rare: disk full, /Applications not writable).
    /// Throws .helperSpawnFailed if step 3 fails (very rare).
    func install(stagedBundle: URL, currentBundle: URL, sentinelPath: URL) throws
}
```

The relaunch script template, with substituted variables:

```sh
#!/bin/sh
set -u
SENTINEL=__SENTINEL__
NEW_APP=__NEW_APP__
LOG=__LOG__

log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$LOG"; }

log "waiting for parent to exit (sentinel: $SENTINEL)"
i=0
while [ -e "$SENTINEL" ]; do
  sleep 0.2
  i=$((i+1))
  if [ "$i" -gt 150 ]; then
    log "parent did not remove sentinel within 30s, launching anyway"
    break
  fi
done

log "launching $NEW_APP"
open -n "$NEW_APP"
```

The sentinel file is written at app startup (in `applicationDidFinishLaunching`) to `~/Library/Application Support/Casablanca/Updates/relaunch.sentinel` and removed in `applicationWillTerminate`. Path substitutions are quoted as POSIX single-quoted strings; the substitution code escapes embedded single quotes by close-quote-reopen (`'\''`).

Note: the Swift code that performs `FileManager.replaceItem` runs *before* the script is spawned, so by the time the script's `open -n` fires, `/Applications/Casablanca.app` is already the new bundle. The script never touches `/Applications`.

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
        case error(UpdateError, visibility: ErrorVisibility)
    }

    enum CheckTrigger { case automatic, manual }
    enum ErrorVisibility { case silent, alert }

    private(set) var state: State

    func startScheduling()                         // called once at app launch
    func checkNow(trigger: CheckTrigger) async     // manual or auto entry point
    func installUpdate(_ release: ReleaseInfo) async
    func skipVersion(_ release: ReleaseInfo)
    func remindLater()
    func dismissError()
}
```

Errors carry a separate `ErrorVisibility` value rather than reusing `CheckTrigger`, so user-initiated install failures surface alerts even when the original check trigger was `.automatic`. Visibility is computed at the point the error is raised: silent if the failure happened during an `.automatic` check phase and the user has not yet interacted; alert if the user clicked **Install** or **Check for Updates…** at any earlier point in the current attempt.

`startScheduling` reads `lastCheckAt`, decides whether to trigger an auto-check immediately (if `> 24h` since last) or arms a `Timer` for the remaining interval. Subsequent ticks repeat the cycle. The schedule is paused while the state is anything other than `.idle` or `.error`. `lastCheckAt` is written only on successful checks (Decision 17).

## State Machine

```
idle
  ├── (24h timer fires OR app launch OR menu click) → checking(trigger)
  └── (terminal for skip / later)

checking(trigger)
  ├── (no newer version)                  → idle, persist lastCheckAt
  ├── (newer version, not skipped)        → available(release), persist lastCheckAt
  ├── (newer version equals skipped)      → idle, persist lastCheckAt
  └── (network / API error)
        ├── trigger=automatic             → idle (silent, log only; lastCheckAt NOT advanced)
        └── trigger=manual                → error(.checkFailed, .alert)

available(release)
  ├── user clicks Install + safe-to-quit  → downloading(release, 0)
  ├── user clicks Install + unsafe        → error(.recordingActive, .alert), dismiss → available(release)
  ├── user clicks Later                   → idle (re-prompts on next check)
  └── user clicks Skip                    → idle, persist skippedVersion=release.version

downloading(release, progress)
  ├── (progress ticks)                    → downloading(release, newProgress)
  ├── (download completes)                → staged(stagedBundle, release)
  ├── (cancel)                            → idle
  └── (failure)                           → error(_, .alert)
                                            (always alert: user clicked Install)

staged(stagedBundle, release)
  ├── (swap succeeds, helper spawned)     → NSApp.terminate(nil) — process exits, no further state
  └── (swap or helper failure)            → error(.swapFailed | .helperSpawnFailed, .alert)

error(_, .alert)
  └── user dismisses                      → idle
error(_, .silent)
  └── auto-clears on next state change    → idle
```

## Error Handling

`UpdateError` is one typed enum. UI maps cases to messages; `ErrorVisibility` determines whether an alert is shown.

| Case | When | Visibility rule |
|---|---|---|
| `.notInApplicationsFolder` | Bundle path is not `/Applications/Casablanca.app` and the first-launch prompt has already been seen | Silent for auto-checks; alert for manual checks: "Move Casablanca to /Applications to enable updates." |
| `.checkFailed(URLError)` | GitHub API offline, DNS, TLS, timeout | Silent for auto-checks (log only, do not advance `lastCheckAt`); alert with Retry button for manual checks |
| `.rateLimited(retryAfter: Date)` | 403/429 from GitHub | Silent for auto-checks (suspend schedule until `retryAfter`); alert for manual checks: "GitHub rate limit hit, try again in N minutes" |
| `.malformedResponse` | API returns non-JSON or unexpected structure | Silent for auto; alert for manual: "Unexpected response from GitHub" |
| `.assetNotFound` | Latest release has no asset matching the regex | Silent for auto; alert for manual: "No macOS asset found in latest release" |
| `.recordingActive(reason)` | `SafeToQuitProbe` returns a non-nil reason when user clicks Install | Always alert: "Casablanca is currently recording. Stop the recording, then click Install again." (`reason` is the localized string from the probe.) |
| `.downloadFailed(URLError)` | Network drop mid-download | Always alert (user clicked Install): Retry / Cancel |
| `.unzipFailed` | ditto returns non-zero, or no `.app` bundle inside the zip | Always alert: "Update download was corrupt." |
| `.quarantineStripFailed` | `xattr -dr com.apple.quarantine` returns non-zero | Always alert: "Could not prepare the update for installation." Logs the xattr command output. |
| `.versionRegression` | Unzipped bundle version ≤ running version | Always alert: "Update package was older than current version. Cancelling." (Defensive — should never happen if the API check was correct.) |
| `.codesignFailed` | `codesign --verify --deep --strict` fails on staged bundle | Always alert: "Update package was corrupt. Update was not installed." |
| `.swapFailed(reason)` | `FileManager.replaceItem` throws (disk full, `/Applications` not writable, permission denied) | Always alert: "Could not install the update. Your existing app is unchanged." (APFS guarantee: original bundle untouched.) |
| `.helperSpawnFailed` | `posix_spawn` of relaunch script fails | Always alert: "Update was installed but Casablanca could not relaunch automatically. Please reopen Casablanca." (Bundle is already replaced; user just needs to launch it again.) |

All errors log through `OSLog` with subsystem `nl.medicore.casablanca`, category `update`, including correlation info (release tag, asset URL, staging path).

## Storage Layout

```
~/Library/Application Support/Casablanca/Updates/
├── staging/                                   ← wiped at app launch + after success
│   └── <version>/
│       ├── Casablanca.zip
│       └── Casablanca.app/                    (unzipped, quarantine stripped)
├── logs/                                      ← never wiped
│   └── install-<YYYY-MM-DDTHHMMSS>.log
├── relaunch.sentinel                          ← present while parent app is alive
└── relaunch-<timestamp>.sh                    ← orphaned helper scripts cleaned at next launch
```

- The whole `staging/` directory is wiped at app launch (anything left over from a prior interrupted attempt) and after a successful install.
- `logs/` is never automatically wiped. The Settings → Updates pane has a "Reveal install logs" button (behind the same Option-click that exposes prereleases) that opens `logs/` in Finder. Manual cleanup if it ever grows too large; in practice logs are only written on install attempts.
- Orphaned `relaunch-<timestamp>.sh` files (helpers that succeeded — leaving the script behind because nothing comes back to clean them up) are deleted at the next app launch as part of the staging-wipe pass.

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
│ │ [ Reveal install logs in Finder ]              │ │
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

- Reads `Bundle.main.bundleURL`.
- If the path equals `/Applications/Casablanca.app`, return.
- If the path matches `/private/var/folders/.../AppTranslocation/.../d/Casablanca.app` (Gatekeeper translocation), show a translocation-specific alert: "Casablanca is running from a randomized read-only location. Move it to /Applications to enable updates." Buttons: **Move to Applications** | **Quit**. (No "Not Now" — the app cannot do anything useful from a translocated path.)
- Otherwise (running from `~/Downloads`, `.build/`, etc.) and the `applicationsLocationPromptShown` `UserDefaults` flag is unset: show the alert: "Casablanca runs best from the /Applications folder. Move it there now? Auto-update requires this." Buttons: **Move to Applications** | **Not Now**.
- If the flag is already set: return silently.

On **Move to Applications**:
- If `/Applications/Casablanca.app` already exists: show a confirmation alert ("A copy of Casablanca already exists in /Applications. Replace it?"). On confirm, atomically swap-in the running bundle's contents using `FileManager.replaceItem`. On cancel, dismiss without setting the flag (user is re-prompted next launch).
- Copy the bundle to `/Applications/Casablanca.app` (or replace if confirmed).
- Launch the new copy via `NSWorkspace.shared.openApplication(at: ..., configuration: ...)` with `createsNewApplicationInstance = true`.
- Terminate the current process.

On **Not Now**: set the flag and dismiss. Updates will be refused with `.notInApplicationsFolder` until the user moves the app manually.

Errors during the move (copy fails, permission denied, target exists and the user cancels the replace prompt) surface as a follow-up alert and the flag is *not* set so the user gets prompted again next launch.

## Testing Plan

Unit tests live in `CasablancaTests/Updates/` (new folder):

| Test target | Covers |
|---|---|
| `SemanticVersionTests` | Parsing of `v0.3.0`, `0.3.0`, `0.3.0-beta.1`, `0.3.0+build.7`. Comparison: `0.3.0 > 0.2.99`, `0.3.0 > 0.3.0-beta.1`, `0.3.0-beta.2 > 0.3.0-beta.1`, `0.3.0-beta.10 > 0.3.0-beta.2` (numeric identifier comparison per SemVer 11.4.4), `0.4.1-beta.1 > 0.4.0`, build metadata ignored. Throws on malformed input. |
| `GitHubReleaseClientTests` | Stubbed via `URLProtocol`. Asserts: parses `latest` JSON, parses `releases` list and picks first prerelease when prereleases enabled, picks the right asset by regex, surfaces `.rateLimited(retryAfter)` from 429 with `Retry-After` header, surfaces `.malformedResponse` on bad JSON, surfaces `.assetNotFound` when the matching zip is missing, follows redirects to a different origin without leaking `Authorization` (test injects an auth header to the original request and asserts the redirected request omits it). |
| `UpdatePreferencesTests` | UserDefaults round-trip with an injected suite name. Skipped-version persistence including prerelease boundary cases; `lastCheckAt` only advances on success; defaults match the spec. |
| `UpdateServiceTests` | Injects fake `GitHubReleaseClient`, fake `UpdateDownloader`, fake `UpdateInstaller`, fake `SafeToQuitProbe`, fake `Clock`, in-memory `UpdatePreferences`. Asserts every transition in the state machine, both auto and manual triggers, error visibility difference (silent vs alert), 24h scheduling cadence including the "auto-check failure does not advance `lastCheckAt`" property, skip-then-newer-version behavior, install refused when `SafeToQuitProbe` returns a reason. |
| `UpdateDownloaderTests` | Three sub-suites for the three protocol methods. `download(...)`: uses a `file://` URL pointing at a fixture zip, asserts progress callbacks fire monotonically, output zip exists. `extract(...)`: uses a quarantined fixture zip (xattr applied in test setup), asserts the unzipped bundle has no `com.apple.quarantine` xattr, asserts a corrupt zip throws `.unzipFailed`. `verify(...)`: runs against a real ad-hoc-signed fixture bundle in `Tests/Fixtures/Casablanca-99.0.0-macOS.zip` (built by a one-time test fixture script), asserts the codesign pass, asserts version-regression detection trips on an older fixture. |
| `UpdateInstallerScriptTests` | Two parts. (1) Script-content tests: generates the relaunch script string, asserts it contains the `[ -e "$SENTINEL" ]` wait loop, the 30s timeout, the `open -n` line, correct POSIX-quoted paths for inputs containing spaces, single quotes, and `$`. (2) Atomic-swap tests: unit-tests `FileManager.replaceItem` against a temp-dir source/destination — does NOT touch `/Applications`. Asserts atomic-swap success, swap of a directory that doesn't exist as destination, swap when destination is in use (held open by a Swift `FileHandle`). |
| `SafeToQuitProbeTests` | Injects fake `AudioRecordingService`, `TranscriptionService`, `SummarizationService`. Asserts probe returns nil when all idle, returns the correct reason string when each service is active. |
| `ApplicationsLocationCheckTests` | Injects bundle URL + UserDefaults. Asserts: prompt shown only when bundle is not in `/Applications` and the flag is unset; translocation path triggers the translocation-specific alert with no "Not Now" button; existing `/Applications/Casablanca.app` triggers the replace-confirmation. |

All time-dependent paths use an injected `Clock` so the 24h scheduling is testable without real waits.

**Not unit-tested (covered by manual verification only):**
- The `posix_spawn` flags actually decouple the helper from the parent process group. Asserted by manual verification step 2: the helper survives `NSApp.terminate(nil)`.
- Swap of the running app's own `/Applications/Casablanca.app` from inside the running process. Tested only via manual verification — the unit test asserts `replaceItem` works on a temp dir, which exercises the same APFS primitive.
- Quarantine xattr makes the relaunched ad-hoc-signed app fail Gatekeeper. The fix is verified by manual step 2 (relaunched app launches without "damaged" dialog).

Manual verification (run before merging the PR):

1. Run from `~/Downloads` → first-launch prompt to move to `/Applications` appears. Click "Not Now" → updates are refused with the `.notInApplicationsFolder` alert on a manual check. Move manually to `/Applications` → updates work.
2. Mark a test release `v999.0.0` on the repo → in-app prompt appears within ~5 seconds of launch → click Install → progress sheet → app quits, replaces, **relaunches as v999.0.0 without a "damaged" Gatekeeper dialog** (this is the quarantine-strip + atomic-swap end-to-end test). Tear down the test release after.
3. Click Skip on the test release → restart app → prompt does not reappear. Publish `v999.0.1` → prompt reappears. Test the prerelease boundary: skip a prerelease `v999.1.0-beta.1`, publish stable `v999.1.0` → re-prompts. Skip stable `v999.2.0`, publish prerelease `v999.2.1-beta.1` → re-prompts (with prereleases enabled).
4. Disconnect network, click "Check for Updates…" → error alert with retry. Reconnect → retry succeeds.
5. Start a recording, then publish a test release → click Install → see the `.recordingActive` alert. Stop the recording, click Install again → install proceeds.
6. Mid-install resilience: kill the relaunch script (`pkill -f relaunch-`) just before it runs `open -n` (or block its execution by chmod) → the bundle on disk is already the new version (atomic swap succeeded). Manually open `/Applications/Casablanca.app` → new version launches. No `.old` directory needed.
7. Toggle "Include prereleases" → mark the test release as prerelease → verify it's offered.
8. With the app running, watch `Console.app` filtered by subsystem `nl.medicore.casablanca` and category `update` for the full audit trail of a check + install cycle, plus inspect `~/Library/Application Support/Casablanca/Updates/logs/install-<timestamp>.log` for the helper script's log.

## Phasing for Implementation Plan

Each step is independently mergeable; the service layer is fully testable before any UI is wired.

1. `SemanticVersion` value type + tests (including prerelease boundary cases per SemVer 11.4.4).
2. `GitHubReleaseClient` protocol + URLSession implementation with cross-origin auth-stripping redirect delegate + `URLProtocol`-stubbed tests.
3. `UpdatePreferences` UserDefaults wrapper + tests.
4. `SafeToQuitProbe` + tests using fake services.
5. `UpdateService` skeleton with state machine + tests using fakes for downloader/installer/client/probe/clock.
6. `UpdateDownloader` URLSession + ditto-based unzip + xattr quarantine strip + codesign check, split into the three protocol methods + tests including a quarantined fixture zip.
7. `UpdateInstaller` `FileManager.replaceItem` swap + relaunch-script generator + `posix_spawn` with `POSIX_SPAWN_SETSID` (via a small `Darwin`-based wrapper) + tests for script content and a temp-dir atomic-swap test.
8. `ApplicationsLocationCheck` helper (with translocation path detection and existing-bundle replace-confirmation) + tests + wiring into `CasablancaApp`.
9. Sentinel file lifecycle in `CasablancaApp`: write at app launch, remove in `applicationWillTerminate`. Plus orphan-cleanup pass at startup.
10. `UpdatePromptView` SwiftUI sheet + release-notes markdown rendering.
11. `UpdateProgressView` SwiftUI sheet.
12. `UpdatesSettingsView` SwiftUI tab + Option-click reveal for prereleases / install-logs button.
13. App menu integration (`Check for Updates…` via `CommandGroup(after: .appInfo)`).
14. End-to-end manual verification pass (especially step 2: relaunched app launches without Gatekeeper "damaged" dialog) + README docs update.

## Known Limitations

- Trust boundary is HTTPS to GitHub. A compromised GitHub account could push a malicious release. Mitigation: switch to Sparkle + EdDSA when Developer ID + notarization is in place.
- Update from non-`/Applications` locations is intentionally refused after the one-time prompt is dismissed. The user must move the app manually to re-enable updates.
- Install is refused while a recording or in-flight transcription/summarization is running. The user must finish or stop the operation before installing.
- The relaunch helper's parent-exit timeout is 30 seconds; if the app refuses to terminate (uncommon — `applicationShouldTerminate` would have to veto), the helper launches the new app anyway after the timeout. The new app may briefly compete with the old one for the bundle ID; macOS's launch services will activate one of them.
- Single arm64 macOS asset only. If the project ever ships a universal binary or x86_64 build, the asset selection regex must change.
- `MarkdownConverter` targets CommonMark, not GitHub-Flavored Markdown. Release notes containing `@user` mentions, `#1234` issue refs, autolinked bare URLs, task lists, or tables will render as plain text or fail to autolink. Acceptable for v1; the body is informational.
- Self-update of the updater itself relies on the new bundle's updater code being correct. A regression in the updater inside a shipped release that breaks future updates can only be recovered by manually downloading the next release. Acceptable risk for a small project; mitigated by keeping the updater logic narrow and well-tested.
- Codesign verify on the staged bundle is a corruption check, not a tamper-detection mechanism. An attacker who can publish a release can re-sign ad-hoc just as easily as the maintainer. The trust-in-GitHub limitation above is the binding constraint.
