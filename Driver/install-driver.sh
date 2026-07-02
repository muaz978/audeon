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

echo ">> installing $SRC -> $DST"
mkdir -p "$DST_DIR"
rm -rf "$DST"
cp -R "$SRC" "$DST"

# The HAL folder wants root ownership.
chown -R root:wheel "$DST"

echo ">> restarting coreaudiod (system audio will blip for a second)"
killall coreaudiod 2>/dev/null || true

echo ">> installed. Give it a few seconds, then check for an 'Audeon Stream' device."
echo ">> if anything misbehaves: sudo ./recover-audio.sh"
