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
xcodebuild -project Casablanca.xcodeproj \
  -scheme Casablanca \
  -configuration Release \
  -derivedDataPath .build/release \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY=''
```

The built app bundle is produced at:

```text
.build/release/Build/Products/Release/Casablanca.app
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
- The release artifact is unsigned unless you rebuild with your own signing identity.
