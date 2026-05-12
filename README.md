# Casablanca

Casablanca is a local-first macOS meeting assistant for capturing notes during meetings, recording audio, transcribing sessions with Whisper, generating summaries with Ollama, and exporting meeting notes to Obsidian or Apple Notes.

## What `v0.1.0` includes

- Calendar-driven meeting list plus manual meetings
- Live meeting workspace with freeform notes by default and optional timestamped capture
- Local meeting recording with microphone and optional system audio capture
- Local transcription through WhisperKit
- Local summary generation through Ollama
- Export to Obsidian (Markdown) or Apple Notes (HTML), selectable in Settings
- Optional Local-only mode for prep notes and todos (no Obsidian vault required)

## Requirements

- macOS 14 or later
- Xcode 16 or later
- Microphone permission
- Screen Recording permission if you want system audio capture
- Optional: a local Ollama instance for summaries

## Build

```bash
./scripts/build-release.sh
```

This script:

- builds the app in `Release`
- re-signs the `.app` bundle so resources are sealed correctly
- verifies the signature with `codesign --verify`
- produces a zip asset in `.build/release-assets/`

The built app bundle is produced at a path like:

```text
.build/release-dist/Build/Products/Release/Casablanca.app
```

Optional environment variables:

```bash
SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' ./scripts/build-release.sh
DERIVED_DATA_PATH=.build/custom-release ./scripts/build-release.sh
ZIP_OUTPUT_PATH=.build/release-assets/Casablanca-custom.zip ./scripts/build-release.sh
```

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

- The GitHub release for `v0.1.0` ships a zipped `.app` bundle.
- A raw `xcodebuild` output with signing disabled is not suitable for distribution by itself; re-sign the bundle before sharing it.
- Ad-hoc signing avoids the broken “app is damaged” bundle state, but macOS still requires Developer ID signing and notarization for a frictionless public download experience.

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
