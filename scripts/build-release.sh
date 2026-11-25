#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCHEME="Casablanca"
PROJECT_PATH="$ROOT_DIR/Casablanca.xcodeproj"
BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-Release}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT_DIR/.build/release-dist}"
ENTITLEMENTS="$ROOT_DIR/Casablanca/Casablanca.entitlements"
REQUIREMENT_FILE="$ROOT_DIR/scripts/casablanca.req"

# Pick a signing identity. A stable, Apple-anchored identity is what lets macOS
# TCC keep microphone / screen-recording / calendar grants across builds and
# installs: TCC keys permissions on (bundle id, designated requirement), and an
# ad-hoc signature's requirement is a per-build cdhash that changes every time.
# Prefer Developer ID (needed for notarized public distribution), then fall back
# to Apple Development (fine for local use and in-app updates), then ad-hoc.
#
# Select by the cert's SHA-1 hash ($2), not its name: names can be ambiguous
# (multiple certs share one name) and codesign refuses an ambiguous name.
SIGNING_IDENTITY_IS_DEVELOPER_ID=0
if [[ -z "${SIGNING_IDENTITY:-}" ]]; then
  IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null)"
  SIGNING_IDENTITY="$(printf '%s\n' "$IDENTITIES" | awk '/Developer ID Application/{print $2; exit}')"
  if [[ -n "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY_IS_DEVELOPER_ID=1
  else
    SIGNING_IDENTITY="$(printf '%s\n' "$IDENTITIES" | awk '/Apple Development/{print $2; exit}')"
  fi
  if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="-"
  fi
elif [[ "$SIGNING_IDENTITY" == "Developer ID Application:"* ]]; then
  SIGNING_IDENTITY_IS_DEVELOPER_ID=1
fi

APP_PATH="$DERIVED_DATA_PATH/Build/Products/$BUILD_CONFIGURATION/Casablanca.app"

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$BUILD_CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY='' \
  build

# xcodebuild with signing disabled produces a runnable bundle but not a sealed,
# distributable one. Re-sign the whole bundle to match how Xcode signs the dev
# build: hardened runtime on, the app entitlements applied, and — for real
# identities — a pinned, team-based designated requirement so the requirement is
# identical to the Xcode build and stable across certificate renewal.
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  echo "WARNING: no Developer ID / Apple Development identity found — signing ad-hoc." >&2
  echo "         macOS will treat each build as a different app, so TCC permissions" >&2
  echo "         (microphone / screen recording / calendar) will NOT persist across" >&2
  echo "         builds or installs. Install an Apple Development cert (free) to fix." >&2
  codesign --force --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "-" "$APP_PATH"
else
  codesign --force --options runtime \
    --entitlements "$ENTITLEMENTS" \
    -r "$REQUIREMENT_FILE" \
    --sign "$SIGNING_IDENTITY" "$APP_PATH"
fi
codesign --verify --strict --verbose=2 "$APP_PATH"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
ZIP_OUTPUT_PATH="${ZIP_OUTPUT_PATH:-$ROOT_DIR/.build/release-assets/Casablanca-$VERSION-macOS.zip}"

mkdir -p "$(dirname "$ZIP_OUTPUT_PATH")"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_OUTPUT_PATH"

# Optional notarization for frictionless public download. Opt in with NOTARIZE=1
# and a notarytool keychain profile (xcrun notarytool store-credentials <name>).
# Requires a Developer ID Application identity (paid Apple Developer account).
if [[ "${NOTARIZE:-0}" == "1" ]]; then
  if [[ "$SIGNING_IDENTITY_IS_DEVELOPER_ID" != "1" ]]; then
    echo "NOTARIZE=1 needs a 'Developer ID Application' identity (got: $SIGNING_IDENTITY); skipping notarization." >&2
  elif [[ -z "${NOTARY_PROFILE:-}" ]]; then
    echo "NOTARIZE=1 needs NOTARY_PROFILE set to a notarytool keychain profile name; skipping notarization." >&2
  else
    echo "Submitting $ZIP_OUTPUT_PATH for notarization (profile: $NOTARY_PROFILE)..."
    xcrun notarytool submit "$ZIP_OUTPUT_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP_PATH"
    rm -f "$ZIP_OUTPUT_PATH"
    ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_OUTPUT_PATH"
    echo "Notarized and stapled."
  fi
fi

echo "App: $APP_PATH"
echo "Zip: $ZIP_OUTPUT_PATH"
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  echo "Signature: ad-hoc (TCC permissions will not persist)"
else
  echo "Signature: $(codesign -dvv "$APP_PATH" 2>&1 | awk -F= '/^Authority=/{print $2; exit}')"
fi
echo "Designated requirement:"
codesign -d -r- "$APP_PATH" 2>&1 | grep '^designated' || true
