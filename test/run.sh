#!/bin/sh
# Build + run the logic harness. Compiled with a 1 MB decompression ceiling and a
# nesting depth of 3 so the guards can be exercised cheaply; the shipped build
# uses the real values (2 GB / 50) from SmartHighlight.mm.
#
# A watchdog kills the harness if it hangs — the deadlock regression it covers
# would otherwise block forever rather than fail.
set -eu

cd "$(dirname "$0")/.."
OUT="build/test"
mkdir -p "$OUT"

echo "==> Building harness"
clang++ -std=c++17 -O0 -g -Wall \
    -mmacosx-version-min=10.13 \
    -DCC_MAX_DECOMPRESSED_BYTES=1048576 \
    -DCC_MAX_NESTING_DEPTH=3 \
    -framework Cocoa -framework CoreFoundation \
    -o "$OUT/harness" \
    test/harness.mm

echo "==> Running (120s watchdog)"
"$OUT/harness" &
pid=$!
( sleep 120; kill -9 "$pid" 2>/dev/null && echo "!! TIMED OUT — probable deadlock" ) &
watchdog=$!

set +e
wait "$pid"
rc=$?
set -e
kill "$watchdog" 2>/dev/null || true

exit "$rc"
