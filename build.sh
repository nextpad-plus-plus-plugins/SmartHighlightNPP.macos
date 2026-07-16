#!/bin/sh
# Build + package SmartHighlightNPP for Nextpad++ (macOS).
#
# Produces build/SmartHighlightNPP/SmartHighlightNPP.dylib and a
# zip laid out the way the host loader expects: <folder>/<folder>.dylib. The
# folder name and the dylib name are not independent — NppPluginManager.mm builds
# the dylib name from the directory name, so a mismatch is skipped silently.
#
# Usage:  ./build.sh            build + verify + package
#         ./build.sh --no-zip   build + verify only
set -eu

NAME="SmartHighlightNPP"
VERSION="1.0.5"
SRC="SmartHighlight.mm"
OUT="build"
STAGE="$OUT/$NAME"
DYLIB="$STAGE/$NAME.dylib"

cd "$(dirname "$0")"
rm -rf "$OUT"
mkdir -p "$STAGE"

echo "==> Compiling $SRC -> $NAME.dylib (universal arm64 + x86_64)"
clang++ -fPIC -dynamiclib -std=c++17 -O2 -Wall -Wextra -fvisibility=hidden \
    -mmacosx-version-min=10.13 \
    -arch arm64 -arch x86_64 \
    -framework Cocoa -framework CoreFoundation \
    -Wl,-install_name,"$NAME.dylib" \
    -Wl,-current_version,"$VERSION" \
    -Wl,-compatibility_version,1.0.0 \
    -o "$DYLIB" \
    "$SRC"

echo "==> Verifying"

# Universal?
archs=$(lipo -archs "$DYLIB")
case "$archs" in
    *arm64*) ;;
    *) echo "FAIL: missing arm64 slice (got: $archs)"; exit 1 ;;
esac
case "$archs" in
    *x86_64*) ;;
    *) echo "FAIL: missing x86_64 slice (got: $archs)"; exit 1 ;;
esac
echo "    archs: $archs"

# All five plugin entry points exported, and nothing else.
for sym in _setInfo _getName _getFuncsArray _beNotified _messageProc; do
    nm -g --defined-only "$DYLIB" 2>/dev/null | grep -q " T $sym\$" \
        || { echo "FAIL: missing export $sym"; exit 1; }
done
nexports=$(nm -g --defined-only -arch arm64 "$DYLIB" 2>/dev/null | wc -l | tr -d ' ')
[ "$nexports" = "5" ] || { echo "FAIL: expected 5 exports, got $nexports"; exit 1; }
echo "    exports: 5 (setInfo getName getFuncsArray beNotified messageProc)"

# No non-system dependencies: everything must ship with macOS. otool -L on a
# universal binary emits a header line and the dylib's own install name once per
# architecture; both are dropped so only real dependencies remain.
deps=$(otool -L "$DYLIB" \
       | grep -v ':$' \
       | awk '{print $1}' \
       | grep -vE '^(/System/|/usr/lib/)' \
       | grep -v "^$NAME\.dylib\$" \
       | sort -u || true)
[ -z "$deps" ] || { echo "FAIL: non-system dependency: $deps"; exit 1; }
echo "    deps: system frameworks only (nothing to bundle)"

# Deployment target must stay low enough for the catalog's supported floor.
minos=$(otool -l "$DYLIB" | awk '/LC_BUILD_VERSION|LC_VERSION_MIN_MACOSX/{f=1} f&&/minos|version/{print $2; exit}')
echo "    minos: $minos"

# Version stamped, so Plugins Admin reports a real version instead of 0.0.0.
cur=$(otool -l "$DYLIB" | awk '/LC_ID_DYLIB/{f=1} f&&/current version/{print $3; exit}')
[ "$cur" = "$VERSION" ] || { echo "FAIL: current_version is $cur, expected $VERSION"; exit 1; }
echo "    current_version: $cur"

if [ "${1:-}" = "--no-zip" ]; then
    echo "==> Built: $DYLIB"
    exit 0
fi

echo "==> Packaging"
ZIP="$OUT/${NAME}_v${VERSION}.zip"
# Strip extended attributes and skip resource forks, or ditto stores an
# AppleDouble ._ sidecar next to the dylib inside the zip.
xattr -cr "$STAGE"
( cd "$OUT" && /usr/bin/ditto -c -k --keepParent --norsrc --noextattr "$NAME" "$(basename "$ZIP")" )

# The zip must contain exactly <folder>/<folder>.dylib.
listing=$(unzip -Z1 "$ZIP" | grep -v '/$')
[ "$listing" = "$NAME/$NAME.dylib" ] \
    || { echo "FAIL: unexpected zip layout:"; echo "$listing"; exit 1; }
echo "    layout: $listing"

echo
echo "zip   : $ZIP"
echo "sha256: $(shasum -a 256 "$ZIP"   | cut -d' ' -f1)"
echo "dylib : $(shasum -a 256 "$DYLIB" | cut -d' ' -f1)"
echo "built : $(date +%Y-%m-%d)"
