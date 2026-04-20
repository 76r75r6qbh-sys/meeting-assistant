# Casablanca

Casablanca is a local-first macOS meeting assistant for capturing notes during meetings, recording audio, transcribing sessions with Whisper, generating summaries with Ollama, and exporting meeting notes to Obsidian.

## What `v0.1.0` includes

- Calendar-driven meeting list plus manual meetings
- Live meeting workspace with freeform notes and timestamped notes
- Local meeting recording with microphone and optional system audio capture
- Local transcription through WhisperKit
- Local summary generation through Ollama
- Obsidian export for raw notes, summaries, and synced action items

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
