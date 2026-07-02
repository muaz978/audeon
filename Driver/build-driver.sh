#!/bin/bash
# Builds the Audeon virtual audio driver bundle (AudeonAudio.driver) from the
# vendored BlackHole source, branded through AudeonDriverConfig.h.
#
# This script only BUILDS. It never installs anything into
# /Library/Audio/Plug-Ins/HAL and never touches coreaudiod. Installation is a
# separate, deliberate step that comes later in the staging plan.
set -euo pipefail
cd "$(dirname "$0")"

OUT="build"
BUNDLE="$OUT/AudeonAudio.driver"
BIN="$BUNDLE/Contents/MacOS/AudeonDriver"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

echo ">> compiling driver (vendored BlackHole source + Audeon branding)"
clang -bundle \
    -o "$BIN" \
    -include AudeonDriverConfig.h \
    vendor/BlackHole/BlackHole.c \
    -framework CoreAudio \
    -framework CoreFoundation \
    -framework Accelerate \
    -mmacosx-version-min=13.0 \
    -O2 \
    -Wno-deprecated-declarations

cp Info.plist "$BUNDLE/Contents/Info.plist"

# Ad-hoc signature so the bundle has a stable identity. A real distribution
# to other machines will need Developer ID signing and notarization.
codesign --force --sign - "$BUNDLE" >/dev/null

echo ">> built $BUNDLE"
echo ">> NOT installed anywhere. Stage 0 tests run it in-process only."
