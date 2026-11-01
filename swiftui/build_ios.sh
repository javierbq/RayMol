#!/bin/bash
# build_ios.sh — Build libpymol_core.a for iOS simulator (arm64)
#
# Usage:
#   cd swiftui && ./build_ios.sh
#   # or for device:
#   cd swiftui && ./build_ios.sh device

set -euo pipefail

PYMOL_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PLATFORM="${1:-simulator}"
if [ "$PLATFORM" = "device" ]; then
    IOS_PLATFORM="OS"
    BUILD_DIR="${PYMOL_ROOT}/build_ios_device"
else
    IOS_PLATFORM="SIMULATOR64"
    BUILD_DIR="${PYMOL_ROOT}/build_ios"
fi

NCPU=$(sysctl -n hw.ncpu)
# Homebrew by default; MacPorts users: export PYMOL_EXTERNAL_PREFIX=/opt/local
PYMOL_EXTERNAL_PREFIX="${PYMOL_EXTERNAL_PREFIX:-/opt/homebrew}"

echo "=== Building libpymol_core.a for iOS ($PLATFORM) ==="
echo "  PYMOL_ROOT: ${PYMOL_ROOT}"
echo "  BUILD_DIR:  ${BUILD_DIR}"
echo "  Platform:   ${IOS_PLATFORM}"
echo "  EXTERNAL_PREFIX: ${PYMOL_EXTERNAL_PREFIX}"
echo ""

# Fingerprint the core sources BEFORE compiling, stamp after (#400); see
# scripts/check_core_fresh.sh and build_macos.sh.
CORE_FP="$(bash "${PYMOL_ROOT}/scripts/check_core_fresh.sh" fingerprint 2>/dev/null || true)"

mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

cmake "${PYMOL_ROOT}/appkit" \
    -DCMAKE_TOOLCHAIN_FILE="${PYMOL_ROOT}/appkit/ios.toolchain.cmake" \
    -DIOS_PLATFORM="${IOS_PLATFORM}" \
    -C "${PYMOL_ROOT}/appkit/CMakeLists_iOS.cmake" \
    -DPYMOL_EXTERNAL_PREFIX="${PYMOL_EXTERNAL_PREFIX}" \
    -DCMAKE_BUILD_TYPE=Release

cmake --build . --target pymol_core -j"${NCPU}"

bash "${PYMOL_ROOT}/scripts/check_core_fresh.sh" stamp "${BUILD_DIR}" "$CORE_FP"

echo ""
echo "=== Done ==="
echo "  Library: ${BUILD_DIR}/libpymol_core.a"
echo ""
lipo -info "${BUILD_DIR}/libpymol_core.a"
