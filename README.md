# Casablanca

Casablanca is a local-first macOS meeting assistant for capturing notes during meetings, recording audio, transcribing sessions with Whisper, generating summaries with a local LLM (Ollama or oMLX), and exporting meeting notes to Obsidian or Apple Notes.

## What `v0.8.0` includes

- Calendar-driven meeting list plus manual meetings
- Live meeting workspace with freeform notes by default and optional timestamped capture
- Local meeting recording with microphone and optional system audio capture
- Local transcription through WhisperKit
- Local summary generation through a selectable LLM provider — Ollama (default) or oMLX — with per-provider endpoint and model settings and optional oMLX API-key authentication
- Export to Obsidian (Markdown) or Apple Notes (HTML), selectable in Settings
- Optional Local-only mode for prep notes and todos (no Obsidian vault required)
- **Approvals inbox** — a sidebar queue of AI-prepared draft emails / Jira comments / Teams messages backed by a shared `action-queue.json`; approve, decline, edit, or send a draft back with a steer ("Request changes"), and a paired agent executes the approved ones. See the [Action Queue (Approvals) setup guide](docs/action-queue-approvals.md).

### New in `v0.8.0`

- **Meeting tags** — label meetings and filter the sidebar by tag; tags are searchable and written to Obsidian frontmatter
- **Ask your meeting** — a grounded Q&A chat that answers from a meeting's transcript, summary, and notes using your local LLM
- **Auto-record prompt** — an optional notification at a meeting's start time with a one-tap "Start Recording" action
- **Recurring-series linking** — surfaces the previous occurrence's summary and carries open action items into prep; fixes an occurrence-collision bug
- **Compressed recordings** — finished recordings are encoded to AAC/m4a (~5–8× smaller), with a "Keep original WAV" option
- **Unified processing status** — a single transcribe → summarize → export card with per-stage cancel, retry, and error surfacing
- **Faster at scale** — windowed sidebar and debounced full-content search (including summaries) stay responsive with thousands of meetings
- **Reliability** — local-LLM retry with backoff, corrupt-store recovery, event-driven calendar refresh, and audio thread-safety hardening
- **UX polish** — undoable meeting deletion, loading skeletons, transcript chapters, search highlight-all, reduce-motion support, and a `⌘⇧F` focus-mode shortcut
- **Native notes editor (beta)** — an `NSTextView`-based markdown editor behind a Settings toggle, with selection-aware formatting
- See [`CHANGELOG.md`](CHANGELOG.md) for the full list.

## Requirements

- macOS 14 or later
- Xcode 16 or later
- Microphone permission
- Screen Recording permission if you want system audio capture
- Optional: a local LLM server for summaries — [Ollama](https://ollama.com) (default) or [oMLX](https://github.com/jundot/omlx)

## Build

```bash
./scripts/build-release.sh
```

This script:

- builds the app in `Release`
- re-signs the `.app` bundle with hardened runtime, the app entitlements, and a pinned, team-based designated requirement so resources are sealed correctly **and** macOS treats it as the same app as the Xcode build
- verifies the signature with `codesign --verify`
- produces a zip asset in `.build/release-assets/`

By default the script auto-selects a signing identity: a **Developer ID Application** cert if you have one, otherwise an **Apple Development** cert, otherwise ad-hoc. The pinned designated requirement (`scripts/casablanca.req`) is keyed on the team ID (`OU`), not a specific certificate, so macOS keeps microphone / screen-recording / calendar permissions across rebuilds, version updates, and certificate renewals. The same requirement is pinned on the Xcode build via `OTHER_CODE_SIGN_FLAGS`, so switching between the Xcode build and the distributed `.app` no longer wipes permissions. Ad-hoc signing (no identity available) breaks this — each build looks like a different app to TCC.

The built app bundle is produced at a path like:

```text
.build/release-dist/Build/Products/Release/Casablanca.app
```

Optional environment variables:

```bash
SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' ./scripts/build-release.sh
DERIVED_DATA_PATH=.build/custom-release ./scripts/build-release.sh
ZIP_OUTPUT_PATH=.build/release-assets/Casablanca-custom.zip ./scripts/build-release.sh

# Notarize for frictionless public download (requires a paid Developer ID + a
# stored notarytool credential profile: xcrun notarytool store-credentials):
NOTARIZE=1 NOTARY_PROFILE='casablanca-notary' \
  SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
  ./scripts/build-release.sh
```

> If the pinned requirement's team ID ever changes (e.g. enrolling the same
> Apple ID in the paid Developer Program issues a new Team ID), update the `OU`
> value in `scripts/casablanca.req` to match. Confirm the team with
> `codesign -dvv <app>` (`TeamIdentifier=…`).

## Test

```bash
xcodebuild test -project Casablanca.xcodeproj \
  -scheme Casablanca \
  -derivedDataPath .build/test \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY=''
```

## Notes

- Each GitHub release ships a zipped `.app` bundle.
- A raw `xcodebuild` output with signing disabled is not suitable for distribution by itself; re-sign the bundle before sharing it.
- Signing every release with the same team identity is what keeps users' TCC permissions intact across in-app updates — the bundle's designated requirement must stay stable, or macOS revokes the grants on each update.
- For a frictionless **first** download from GitHub on someone else's Mac, macOS still requires Developer ID signing **and** notarization (a paid Apple Developer account). Without it, Gatekeeper blocks the initial download (the in-app updater strips quarantine, so subsequent updates are unaffected).

## Auto-update

Casablanca checks `https://api.github.com/repos/76r75r6qbh-sys/meeting-assistant/releases/latest` shortly after launch (only when more than 24 hours have passed since the last successful check) and then every 24 hours. Manual checks live under `Casablanca → Check for Updates…`.

When a newer release is found, you'll see a prompt with the release notes and three options:

- **Install Update** — downloads the zip, strips the macOS quarantine attribute, atomically swaps `/Applications/Casablanca.app`, and relaunches.
- **Remind Me Later** — re-prompts at the next check.
- **Skip This Version** — silenced until a strictly newer version (per SemVer 2.0.0) appears.

### Requirements
- Casablanca must live at `/Applications/Casablanca.app`. On first launch from any other location, you'll be prompted to move it there.
- Install is refused while a recording, transcription, or summarization is in flight.
- Updates are not cryptographically signed beyond GitHub's HTTPS — same trust model as `brew install`. If the GitHub repo is compromised, the updater would deliver the compromised binary.

### Settings → Updates
- Toggle: **Automatically check for updates**
- Last-checked timestamp
- Manual **Check for Updates…** button
- Hidden (Option-click the section title): **Include prereleases**, **Reveal install logs in Finder**

### Recovering from a failed update
- The install is atomic — either the new bundle is in place or the existing one is untouched.
- Failed installs leave a log under `~/Library/Application Support/Casablanca/Updates/logs/install-<timestamp>.log`. The Settings pane has a button to reveal that folder.
