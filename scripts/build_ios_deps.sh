#!/bin/bash
# build_ios_deps.sh — cross-compile libpng + freetype for iOS (arm64) into
#   deps_ios/install         (iphonesimulator SDK, platform 7)
#   deps_ios/install_device  (iphoneos SDK,        platform 2)
# so swiftui/PyMOLBridge.xcconfig (PYMOL_IOS_DEPS / PYMOL_IOS_DEPS_DEVICE) can
# link -lfreetype/-lpng16 for each iOS SDK. This is the iOS analogue of the
# deps_macos/ Homebrew libs used by the macOS app. Re-run to refresh.
#
# Both are built with CMake's native iOS cross-compile support (CMAKE_SYSTEM_NAME
# =iOS). zlib comes from the iOS SDK (libz.tbd) — no separate build. libpng is
# built FIRST because freetype's PNG support (FT_DISABLE_PNG=OFF) links against
# it; freetype is then pointed at the just-built libpng via PNG_LIBRARY /
# PNG_PNG_INCLUDE_DIR. HarfBuzz/Brotli/bzip2 are disabled (not needed and not
# cross-built here) — mirrors the original bring-up.
#
# Versions match what shipped: freetype 2.13.3, libpng 1.6.44. Override with
# FREETYPE_VERSION / LIBPNG_VERSION. Deployment target via IOS_DEPLOYMENT_TARGET.
#
# Requires: Xcode + command-line tools (cmake, xcrun), curl, tar.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DEPS="$REPO/deps_ios"
FREETYPE_VERSION="${FREETYPE_VERSION:-2.13.3}"
LIBPNG_VERSION="${LIBPNG_VERSION:-1.6.44}"
DEPLOY="${IOS_DEPLOYMENT_TARGET:-16.0}"

command -v cmake >/dev/null || { echo "ERROR: cmake not found (brew install cmake / port install cmake)"; exit 1; }

FREETYPE_URL="https://download.savannah.gnu.org/releases/freetype/freetype-${FREETYPE_VERSION}.tar.xz"
LIBPNG_URL="https://downloads.sourceforge.net/project/libpng/libpng16/${LIBPNG_VERSION}/libpng-${LIBPNG_VERSION}.tar.xz"

mkdir -p "$DEPS"
cd "$DEPS"

fetch_src () {   # $1=url  $2=srcdir
  local URL="$1" SRC="$2" TARBALL
  TARBALL="$(basename "$URL")"
  if [ ! -d "$SRC" ]; then
    echo ">> downloading $TARBALL"
    curl -fL -o "$TARBALL" "$URL"
    tar -xf "$TARBALL"
    rm -f "$TARBALL"
  fi
}

fetch_src "$LIBPNG_URL"   "libpng-${LIBPNG_VERSION}"
fetch_src "$FREETYPE_URL" "freetype-${FREETYPE_VERSION}"

# $1 = "simulator" | "device"  -> sets SDK + install prefix, builds both libs.
build_slice () {
  local KIND="$1" SDK PREFIX
  case "$KIND" in
    simulator) SDK="iphonesimulator"; PREFIX="$DEPS/install" ;;
    device)    SDK="iphoneos";        PREFIX="$DEPS/install_device" ;;
    *) echo "ERROR: unknown slice $KIND"; exit 1 ;;
  esac
  echo "==================== iOS $KIND ($SDK) -> $PREFIX ===================="

  local COMMON=(
    -G "Unix Makefiles"
    -DCMAKE_SYSTEM_NAME=iOS
    -DCMAKE_OSX_ARCHITECTURES=arm64
    -DCMAKE_OSX_SYSROOT="$SDK"
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOY"
    -DCMAKE_INSTALL_PREFIX="$PREFIX"
    -DCMAKE_BUILD_TYPE=Release
  )

  # --- libpng (first: freetype links against it) ---
  local PNGBUILD="$DEPS/build_libpng_${KIND}"
  rm -rf "$PNGBUILD"
  cmake -S "libpng-${LIBPNG_VERSION}" -B "$PNGBUILD" "${COMMON[@]}" \
    -DPNG_SHARED=OFF -DPNG_FRAMEWORK=OFF -DPNG_TESTS=OFF
  cmake --build "$PNGBUILD" --target install

  # --- freetype (points at the libpng we just installed) ---
  local FTBUILD="$DEPS/build_freetype_${KIND}"
  rm -rf "$FTBUILD"
  cmake -S "freetype-${FREETYPE_VERSION}" -B "$FTBUILD" "${COMMON[@]}" \
    -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BROTLI=ON -DFT_DISABLE_BZIP2=ON \
    -DFT_DISABLE_PNG=OFF -DFT_DISABLE_ZLIB=OFF \
    -DPNG_PNG_INCLUDE_DIR="$PREFIX/include" \
    -DPNG_LIBRARY="$PREFIX/lib/libpng16.a"
  cmake --build "$FTBUILD" --target install

  test -f "$PREFIX/lib/libpng16.a"   || { echo "ERROR: $KIND libpng16.a missing"; exit 1; }
  test -f "$PREFIX/lib/libfreetype.a" || { echo "ERROR: $KIND libfreetype.a missing"; exit 1; }
  echo ">> $KIND OK:"
  lipo -archs "$PREFIX/lib/libfreetype.a"
}

build_slice simulator
build_slice device

echo ""
echo ">> done. iOS deps staged:"
echo "     $DEPS/install         (simulator: libpng16.a, libfreetype.a)"
echo "     $DEPS/install_device  (device:    libpng16.a, libfreetype.a)"
