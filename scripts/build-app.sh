#!/bin/bash
# Builds Audeon and wraps the binary in a proper .app bundle so macOS can grant
# microphone access (TCC reads Info.plist from the bundle).
#
# Usage:
#   ./scripts/build-app.sh           # debug build + launch
#   ./scripts/build-app.sh release   # optimized build + launch
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
APP="build/Audeon.app"

echo ">> swift build ($CONFIG)"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"

echo ">> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp "$BIN_PATH/Audeon" "$APP/Contents/MacOS/Audeon"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc sign so the bundle has a stable identity for TCC across launches.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo ">> launching"
open "$APP"
echo "Done. If the mic prompt does not appear, grant access under"
echo "System Settings > Privacy & Security > Microphone."
