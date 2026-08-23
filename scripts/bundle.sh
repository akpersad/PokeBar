#!/bin/bash
# Assembles dist/PokeBar.app around the built executable and prints its path.
#
# Not optional, and this is why: SwiftUI registers a MenuBarExtra status item only
# for a process that has a bundle identifier. `swift run PokeBar` produces a bare
# executable whose CFBundleIdentifier is NULL, so the engine runs, scans, and
# credits coins perfectly while drawing nothing in the menu bar at all. Verified
# the hard way. Run this, then `open dist/PokeBar.app`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-debug}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

swift build --package-path "$ROOT" -c "$CONFIG"
BIN="$(swift build --package-path "$ROOT" -c "$CONFIG" --show-bin-path)/PokeBar"
APP="$ROOT/dist/PokeBar.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/PokeBar"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>PokeBar</string>
    <key>CFBundleDisplayName</key>     <string>PokeBar</string>
    <key>CFBundleIdentifier</key>      <string>local.pokebar</string>
    <key>CFBundleExecutable</key>      <string>PokeBar</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>0.2</string>
    <key>CFBundleVersion</key>         <string>2</string>
    <key>LSMinimumSystemVersion</key>  <string>26.0</string>
    <!-- Menu bar only: no Dock tile, no window on launch. The app delegate also
         sets .accessory at runtime, which covers running the binary directly. -->
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

# Ad-hoc signature, which is all a local launch needs. A stable signing identity
# would only have mattered for caching credentials in the Keychain, and PokeBar
# deliberately holds none (see DECISIONS.md).
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "note: ad-hoc codesign failed, launching unsigned" >&2

echo "$APP"
