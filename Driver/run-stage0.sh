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

echo ""
echo ">> running in-process harness"
./build/harness
HARNESS=$?

echo ""
echo ">> running bundle load test"
./build/bundle_load build/AudeonAudio.driver
BUNDLE=$?

echo ""
if [ $HARNESS -eq 0 ] && [ $BUNDLE -eq 0 ]; then
    echo "== STAGE 0: ALL GREEN =="
else
    echo "== STAGE 0: FAILURES PRESENT =="
    exit 1
fi
