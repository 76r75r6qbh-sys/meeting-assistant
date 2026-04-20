#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCHEME="Casablanca"
PROJECT_PATH="$ROOT_DIR/Casablanca.xcodeproj"
BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-Release}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT_DIR/.build/release-dist}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"

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

# xcodebuild with signing disabled produces a runnable bundle for local build
# output, but not a distributable app bundle. Re-sign the full bundle so
# resources are sealed before the app is zipped or shared.
codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
ZIP_OUTPUT_PATH="${ZIP_OUTPUT_PATH:-$ROOT_DIR/.build/release-assets/Casablanca-$VERSION-macOS.zip}"

mkdir -p "$(dirname "$ZIP_OUTPUT_PATH")"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_OUTPUT_PATH"

echo "App: $APP_PATH"
echo "Zip: $ZIP_OUTPUT_PATH"
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  echo "Signature: ad-hoc"
  echo "Note: ad-hoc signatures avoid the broken 'damaged' bundle, but Developer ID signing and notarization are still required for frictionless public distribution."
else
  echo "Signature: $SIGNING_IDENTITY"
fi
