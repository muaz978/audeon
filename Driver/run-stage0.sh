#!/bin/bash
# Stage 0 test runner for the Audeon virtual audio driver.
# Builds the driver bundle and both test executables, then runs the tests.
# Everything happens in ordinary processes; nothing is installed and
# coreaudiod is never touched.
set -euo pipefail
cd "$(dirname "$0")"

./build-driver.sh

echo ""
echo ">> building Stage 0 tests"
mkdir -p build
clang -o build/harness Tests/harness.c \
    -framework CoreAudio -framework CoreFoundation -framework Accelerate \
    -Wno-format-extra-args -Wno-deprecated-declarations -O1 -g
clang -o build/bundle_load Tests/bundle_load.c \
    -framework CoreAudio -framework CoreFoundation \
    -O1 -g

# Both tests always run and the summary is always printed. Under `set -e` a bare
# `./build/harness` would abort the script the moment the harness failed, so the
# bundle load test never ran and the summary below was dead code. `|| STATUS=$?`
# keeps the failure from tripping errexit while still recording the exit code.
echo ""
echo ">> running in-process harness"
HARNESS=0
./build/harness || HARNESS=$?

echo ""
echo ">> running bundle load test"
BUNDLE=0
./build/bundle_load build/AudeonAudio.driver || BUNDLE=$?

echo ""
echo ">> harness exit: $HARNESS   bundle load exit: $BUNDLE"
if [ "$HARNESS" -eq 0 ] && [ "$BUNDLE" -eq 0 ]; then
    echo "== STAGE 0: ALL GREEN =="
else
    echo "== STAGE 0: FAILURES PRESENT =="
    exit 1
fi
