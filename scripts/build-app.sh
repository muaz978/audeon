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

# Release builds are universal (Apple Silicon + Intel) to match the deployment
# target and the universal driver shipped alongside. Debug builds stay native so
# the edit/run loop is quick.
# macOS still ships bash 3.2, where "${ARR[@]}" on an empty array trips `set -u`,
# so the arch flags are expanded with the ${ARR[@]+...} form throughout.
ARCH_ARGS=()
if [ "$CONFIG" = "release" ]; then
    ARCH_ARGS=(--arch arm64 --arch x86_64)
fi

echo ">> swift build ($CONFIG)"
swift build -c "$CONFIG" ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"}

BIN_PATH="$(swift build -c "$CONFIG" ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} --show-bin-path)"

echo ">> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp "$BIN_PATH/Audeon" "$APP/Contents/MacOS/Audeon"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Icon/Audeon.icns "$APP/Contents/Resources/Audeon.icns"

# Ad-hoc sign so the bundle has a stable identity for TCC across launches. This
# is required for microphone access, so a failure here is fatal rather than
# something to discard.
if ! codesign --force --sign - "$APP"; then
    echo "codesign failed. Without a signature the bundle has no stable identity"
    echo "and macOS will not grant it microphone access."
    exit 1
fi

echo ">> launching"
# `open` would just reactivate an already-running old instance instead of
# launching what we just built, so retire the running copy first.
if pkill -x Audeon 2>/dev/null; then
    # give it a moment to actually exit before the new one starts
    for _ in $(seq 1 25); do
        pgrep -x Audeon >/dev/null 2>&1 || break
        sleep 0.2
    done
fi
open -n "$APP"
echo "Done. If the mic prompt does not appear, grant access under"
echo "System Settings > Privacy & Security > Microphone."
