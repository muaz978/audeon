#!/bin/bash
# Builds the universal Audeon driver and assembles a self-contained,
# downloadable installer package (a zip) that other people can use on their own
# Macs without the source tree or a toolchain.
#
#     Driver/package-driver.sh
#
# Produces Driver/dist/Audeon-Driver-macos.zip containing the driver bundle and
# plain install/uninstall scripts. The bundle is ad-hoc signed, not notarized:
# it loads on most Macs after the installer clears the download quarantine, but
# a Developer ID signature + notarization is the only thing that makes it load
# with no caveats everywhere. See README.txt inside the package.
set -euo pipefail
cd "$(dirname "$0")"

./build-driver.sh

DIST="dist"
STAGE="$DIST/Audeon-Driver"
rm -rf "$STAGE" "$DIST/Audeon-Driver-macos.zip"
mkdir -p "$STAGE"

cp -R build/AudeonAudio.driver "$STAGE/AudeonAudio.driver"

# The driver is built from the vendored BlackHole source (GPL-3.0). Shipping the
# object code means shipping the licence text with it.
cp vendor/BlackHole/LICENSE "$STAGE/LICENSE"

cat > "$STAGE/install.sh" <<'INSTALL'
#!/bin/bash
# Installs the Audeon virtual audio driver so this Mac gains an "Audeon Stream"
# device. Run from Terminal with admin rights:
#
#     sudo ./install.sh
#
# If audio ever misbehaves afterward, run:  sudo ./uninstall.sh
set -euo pipefail
cd "$(dirname "$0")"

if [ "$(id -u)" -ne 0 ]; then
    echo "This needs admin rights. Re-run with:  sudo ./install.sh"
    exit 1
fi

SRC="AudeonAudio.driver"
DST_DIR="/Library/Audio/Plug-Ins/HAL"
DST="$DST_DIR/AudeonAudio.driver"

if [ ! -d "$SRC" ]; then
    echo "Could not find AudeonAudio.driver next to this script."
    exit 1
fi

# The bundle sitting next to this script came out of a zip in the user's Downloads
# folder: it is writable by whoever unpacked it, and coreaudiod will load it as
# root. So verify the signature first, then stage a root-owned copy, and only
# clear quarantine on that staged copy - never on the downloaded tree itself.
echo ">> verifying signature of $SRC"
if ! codesign --verify --strict "$SRC"; then
    echo "The driver bundle failed signature verification. Refusing to install it."
    echo "Re-download the package; do not install a bundle that will not verify."
    exit 1
fi

NEW="$DST_DIR/.AudeonAudio.driver.new.$$"
OLD="$DST_DIR/.AudeonAudio.driver.old.$$"

cleanup() {
    rm -rf "$NEW"
}
trap cleanup EXIT

echo ">> staging -> $NEW"
mkdir -p "$DST_DIR"
rm -rf "$NEW"
cp -R "$SRC" "$NEW"

# Root-owned and not writable by anyone else, before it is ever loaded.
chown -R root:wheel "$NEW"
chmod -R go-w "$NEW"

echo ">> clearing download quarantine on the staged copy"
xattr -dr com.apple.quarantine "$NEW" 2>/dev/null || true

# Re-verify after the ownership, permission and xattr changes.
if ! codesign --verify --strict "$NEW"; then
    echo "The staged driver no longer verifies. Aborting; nothing was changed."
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

echo ">> restarting coreaudiod (system audio blips for a second)"
killall coreaudiod 2>/dev/null || true

echo ">> done. Give it a few seconds, then look for an 'Audeon Stream' device"
echo ">> in Audeon or in System Settings > Sound."
echo ">> if anything misbehaves:  sudo ./uninstall.sh"
INSTALL
chmod +x "$STAGE/install.sh"

cat > "$STAGE/uninstall.sh" <<'UNINSTALL'
#!/bin/bash
# Removes the Audeon virtual audio driver and restarts coreaudiod.
#
#     sudo ./uninstall.sh
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "This needs admin rights. Re-run with:  sudo ./uninstall.sh"
    exit 1
fi

DST="/Library/Audio/Plug-Ins/HAL/AudeonAudio.driver"
if [ -d "$DST" ]; then
    echo ">> removing $DST"
    rm -rf "$DST"
else
    echo ">> nothing to remove at $DST"
fi

echo ">> restarting coreaudiod"
killall coreaudiod 2>/dev/null || true
echo ">> done."
UNINSTALL
chmod +x "$STAGE/uninstall.sh"

cat > "$STAGE/README.txt" <<'READ'
Audeon virtual audio driver
===========================

This adds an "Audeon Stream" device to your Mac, so all system audio can be
captured into Audeon (pick it as your output, or use "Capture system audio"
in the app). Universal build: runs on Apple Silicon and Intel Macs.

Install (from Terminal)
-----------------------
1. Unzip this folder.
2. In Terminal, cd into it, then run:

       sudo ./install.sh

3. Enter your password when asked. Wait a few seconds, then look for
   "Audeon Stream" in Audeon or System Settings > Sound.

Uninstall
---------
       sudo ./uninstall.sh

Important note about signing
----------------------------
This driver is ad-hoc signed, not notarized by Apple. The installer clears the
download quarantine so it loads on most Macs, but some Macs with stricter
security or managed (MDM) policies may still refuse to load an un-notarized
system driver. If it does not appear after installing and waiting, the fully
supported alternative is the free, notarized BlackHole driver
(https://existential.audio/blackhole/): install it and Audeon will use it for
system audio capture exactly the same way.

The driver is GPL-3.0 (it builds on the BlackHole source by Existential Audio
Inc.). The full licence text is in the LICENSE file next to this README, and the
full source is at https://github.com/muaz978/audeon in the Driver folder.
READ

# Strip Finder cruft, then a clean zip with no AppleDouble/__MACOSX noise.
find "$STAGE" -name '.DS_Store' -delete
( cd "$DIST" && zip -r -X -q "Audeon-Driver-macos.zip" "Audeon-Driver" )
echo ">> packaged $DIST/Audeon-Driver-macos.zip"
lipo -info "$STAGE/AudeonAudio.driver/Contents/MacOS/AudeonDriver"
