#!/bin/bash
# build_macos.sh — build libpymol_core.a for native macOS (arm64), Metal-only
# (NO_OPENGL), compiled against the embedded python-build-standalone 3.13 headers.
# The static lib links nothing; linking happens in the Xcode app via the xcconfig.
#
# CLEAN=1 wipes the build dir before configuring. Use it whenever a setting
# DEFAULT changed (layer1/SettingInfo.h) — an incremental build does NOT reliably
# recompile the generated settings table, so it can ship a stale default with a
# fresh-looking mtime and no error (this shipped metal_outline compiled `true`
# while source said `false` in 1.6.1). The release path (make_dmg.sh) always
# builds clean for exactly this reason. Incremental (the default) keeps day-to-day
# dev fast.
set -euo pipefail

PYMOL_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="$PYMOL_ROOT/deps_macos/python-standalone/python"
BUILD_DIR="$PYMOL_ROOT/build_macos_swiftui"
NCPU=$(sysctl -n hw.ncpu)
# Homebrew by default; MacPorts users: export PYMOL_EXTERNAL_PREFIX=/opt/local
PYMOL_EXTERNAL_PREFIX="${PYMOL_EXTERNAL_PREFIX:-/opt/homebrew}"

test -d "$PY" || { echo "ERROR: run scripts/fetch_macos_python.sh first ($PY missing)"; exit 1; }

CLEAN="${CLEAN:-0}"
case "$CLEAN" in
  1|true|yes|on) echo "== Clean core build (rm -rf $BUILD_DIR) =="; rm -rf "$BUILD_DIR" ;;
  *)             echo "== Incremental core build (set CLEAN=1 if a setting default changed) ==" ;;
esac

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
cmake "$PYMOL_ROOT/appkit" \
    -DPYMOL_METAL_ONLY=ON -DPYMOL_IOS=OFF \
    -DPYMOL_LIBXML=OFF -DPYMOL_VMD_PLUGINS=ON -DPYMOL_MSGPACKC=OFF \
    -DPYMOL_PYTHON_INCLUDE_DIR="$PY/include/python3.13" \
    -DPYMOL_EXTERNAL_PREFIX="$PYMOL_EXTERNAL_PREFIX" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 \
    -DCMAKE_BUILD_TYPE=Release

cmake --build . --target pymol_core -j"${NCPU}"

echo ""
echo "=== Done: ${BUILD_DIR}/libpymol_core.a ==="
lipo -archs "${BUILD_DIR}/libpymol_core.a"
