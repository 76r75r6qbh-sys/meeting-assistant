#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
WORK=$(mktemp -d)
trap "rm -rf $WORK" EXIT

build_fixture() {
  local version="$1"
  local out_zip="$ROOT/Casablanca-$version-macOS.zip"
  local app="$WORK/Casablanca.app"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS"
  cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>nl.medicore.casablanca.fixture</string>
  <key>CFBundleName</key><string>Casablanca</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleExecutable</key><string>Casablanca</string>
  <key>CFBundlePackageType</key><string>APPL</string>
</dict>
</plist>
EOF
  printf '#!/bin/sh\nexit 0\n' > "$app/Contents/MacOS/Casablanca"
  chmod +x "$app/Contents/MacOS/Casablanca"
  codesign --force --sign - --deep "$app"
  rm -f "$out_zip"
  ditto -c -k --sequesterRsrc --keepParent "$app" "$out_zip"
  echo "built $out_zip"
}

build_fixture "99.0.0"
build_fixture "0.0.1"
