#!/bin/bash
# Builds Audeon as a universal release .app and wraps it in the downloadable
# zip that ships on a GitHub release.
#
#     ./scripts/package-app.sh
#
# Produces dist/Audeon-<version>-macos.zip, where <version> is read from the
# bundle's own Info.plist rather than passed in -- so the file name can never
# disagree with what the app reports about itself.
#
# The bundle is ad-hoc signed, not notarized. That is enough for a stable TCC
# identity (microphone access) but not enough for Gatekeeper to open it without
# a right-click, which the release notes and README say plainly.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Audeon.app"
DIST="dist"

./scripts/build-app.sh release --no-launch

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
if [ -z "$VERSION" ]; then
    echo "could not read CFBundleShortVersionString from $APP/Contents/Info.plist"
    exit 1
fi
echo ">> version $VERSION"

# A release build that quietly came out single-architecture would run fine on
# the machine that built it and fail on half the Macs that download it, so this
# is checked rather than assumed.
echo ">> verifying the binary is universal"
ARCHS="$(lipo -archs "$APP/Contents/MacOS/Audeon")"
echo "   archs: $ARCHS"
for want in arm64 x86_64; do
    case " $ARCHS " in
        *" $want "*) ;;
        *) echo "!! release binary is missing $want; refusing to package a partial build"; exit 1 ;;
    esac
done

echo ">> verifying the signature"
codesign --verify --deep --strict "$APP"

ZIP="$DIST/Audeon-$VERSION-macos.zip"
rm -rf "$DIST"
mkdir -p "$DIST"

find "$APP" -name '.DS_Store' -delete

# ditto, not zip: it is the Apple-supported way to archive a bundle, preserving
# symlinks and extended attributes. A plain `zip -r` can corrupt the signature
# on a bundle that contains either.
echo ">> archiving -> $ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# Round-trip the archive and re-verify. Packaging is the last step before other
# people download this, and a bundle whose signature did not survive the zip is
# exactly the failure that would otherwise be discovered by a user.
echo ">> verifying the archive round-trips"
CHECK="$(mktemp -d)"
trap 'rm -rf "$CHECK"' EXIT
ditto -x -k "$ZIP" "$CHECK"
codesign --verify --deep --strict "$CHECK/Audeon.app"
lipo -archs "$CHECK/Audeon.app/Contents/MacOS/Audeon" >/dev/null

echo ">> packaged $ZIP ($(du -h "$ZIP" | cut -f1))"
