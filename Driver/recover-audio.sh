#!/bin/bash
# EMERGENCY RECOVERY for the Audeon virtual audio driver.
#
# If installing the driver ever makes system audio misbehave, coreaudiod
# crash-loop, or devices disappear, run this. It removes the Audeon driver
# and restarts the audio daemon, returning the Mac to its normal state.
#
#     sudo Driver/recover-audio.sh
#
# You can run it as many times as you like. It never touches anything but
# the Audeon driver.
set -u

TARGET="/Library/Audio/Plug-Ins/HAL/AudeonAudio.driver"

if [ "$(id -u)" -ne 0 ]; then
    echo "This needs admin rights. Re-run with: sudo $0"
    exit 1
fi

if [ -d "$TARGET" ]; then
    echo ">> removing $TARGET"
    rm -rf "$TARGET"
else
    echo ">> $TARGET is not installed (nothing to remove)"
fi

echo ">> restarting coreaudiod (system audio will blip for a second)"
killall coreaudiod 2>/dev/null || true

echo ">> done. System audio is back to normal."
