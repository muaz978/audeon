#!/bin/bash
# Installs the Audeon virtual audio driver into the system HAL plug-in folder
# and restarts coreaudiod so it is picked up.
#
#     sudo Driver/install-driver.sh
#
# This loads a plug-in into coreaudiod, the shared system audio daemon. If
# anything goes wrong afterward, run:  sudo Driver/recover-audio.sh
set -euo pipefail
cd "$(dirname "$0")"

SRC="build/AudeonAudio.driver"
DST_DIR="/Library/Audio/Plug-Ins/HAL"
DST="$DST_DIR/AudeonAudio.driver"

if [ "$(id -u)" -ne 0 ]; then
    echo "This needs admin rights. Re-run with: sudo $0"
    exit 1
fi

if [ ! -d "$SRC" ]; then
    echo "Build first: ./build-driver.sh"
    exit 1
fi

# Stage the new bundle beside the destination, validate it there, and only then
# swap it in. Deleting the working driver before the copy succeeds would leave
# the machine with no audio device if anything failed part way through.
NEW="$DST_DIR/.AudeonAudio.driver.new.$$"
OLD="$DST_DIR/.AudeonAudio.driver.old.$$"

cleanup() {
    rm -rf "$NEW"
}
trap cleanup EXIT

echo ">> staging $SRC -> $NEW"
mkdir -p "$DST_DIR"
rm -rf "$NEW"
cp -R "$SRC" "$NEW"

# The HAL folder wants root ownership, and coreaudiod loads this as root: no one
# else may be able to write to it.
chown -R root:wheel "$NEW"
chmod -R go-w "$NEW"

echo ">> validating staged bundle"
if [ ! -x "$NEW/Contents/MacOS/AudeonDriver" ]; then
    echo "Staged bundle has no executable at Contents/MacOS/AudeonDriver. Aborting."
    exit 1
fi
if [ ! -f "$NEW/Contents/Info.plist" ]; then
    echo "Staged bundle has no Contents/Info.plist. Aborting."
    exit 1
fi
if ! codesign --verify --strict "$NEW" 2>/dev/null; then
    echo "Staged bundle failed signature verification. Aborting; nothing was changed."
    exit 1
fi

echo ">> installing -> $DST"
if [ -e "$DST" ]; then
    mv "$DST" "$OLD"
fi
if ! mv "$NEW" "$DST"; then
    echo "Install failed. Restoring the previous driver."
    if [ -e "$OLD" ]; then
        mv "$OLD" "$DST"
    fi
    exit 1
fi
rm -rf "$OLD"

echo ">> restarting coreaudiod (system audio will blip for a second)"
killall coreaudiod 2>/dev/null || true

echo ">> installed. Give it a few seconds, then check for an 'Audeon Stream' device."
echo ">> if anything misbehaves: sudo ./recover-audio.sh"
