#!/bin/bash
# build_macos_deps.sh — build STATIC libpng + freetype for native macOS (arm64)
# into deps_macos/install/{lib,include}, so the macOS app links them into its
# own binary and ships no third-party dylibs at all.
#
# WHY. The macOS app used to link -lfreetype -lpng16 out of Homebrew and then
# copy Homebrew's dylibs into Contents/Frameworks (bundle_macos_dylibs.py). That
# made what we ship depend on whatever Homebrew happened to have that day: the
# Xcode Cloud runner's freetype pulled in brotli, whose libbrotlidec loads
# libbrotlicommon via @rpath — a reference the copy script did not follow — and
# the 1.12.2 (212) TestFlight beta died at launch with
#     Library not loaded: @rpath/libbrotlicommon.1.dylib
# Building pinned sources here, exactly like scripts/build_ios_deps.sh does for
# iOS, removes Homebrew from the shipped app entirely (it remains a BUILD-tool
# source only: cmake, glm headers, libomp.a).
#
# Same versions and feature set as build_ios_deps.sh: freetype 2.13.3, libpng
# 1.6.44, with HarfBuzz/Brotli/bzip2 disabled (PyMOL needs none of them) and
# zlib from the SDK. Deliberately a separate script: build_ios_deps.sh is an
# input of scripts/ios_deps_fingerprint.sh, and editing it would orphan the
# published deps_ios artifact the iOS beta fetches.
#
# Idempotent: a stamp file records the versions + deployment target; when it
# matches and both archives exist the script exits immediately.
# FORCE=1 rebuilds anyway.
#
# Callers: swiftui/build_macos.sh (runs this whenever deps are missing/stale, so
# every macOS build path — dev, make_dmg.sh, archive_appstore.sh, Xcode Cloud —
# gets them without a separate step).
# Requires: Xcode command-line tools, cmake, curl, tar.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DEPS="$REPO/deps_macos"
PREFIX="$DEPS/install"
FREETYPE_VERSION="${FREETYPE_VERSION:-2.13.3}"
LIBPNG_VERSION="${LIBPNG_VERSION:-1.6.44}"
# Must not exceed the app's deployment target (project.yml macOS "14.0"), or
# the linker warns "built for newer macOS version" and the archive may be
# rejected. Same value build_macos.sh uses for the core.
DEPLOY="${MACOS_DEPLOYMENT_TARGET:-11.0}"
STAMP="$PREFIX/.raymol-deps-stamp"
WANT="freetype=$FREETYPE_VERSION libpng=$LIBPNG_VERSION deploy=$DEPLOY arch=arm64"

if [ "${FORCE:-0}" != 1 ] && [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$WANT" ] \
   && [ -f "$PREFIX/lib/libfreetype.a" ] && [ -f "$PREFIX/lib/libpng16.a" ]; then
  echo "macOS deps up to date ($WANT)"
  exit 0
fi

command -v cmake >/dev/null || { echo "ERROR: cmake not found (brew install cmake)" >&2; exit 1; }

FREETYPE_URL="https://download.savannah.gnu.org/releases/freetype/freetype-${FREETYPE_VERSION}.tar.xz"
LIBPNG_URL="https://downloads.sourceforge.net/project/libpng/libpng16/${LIBPNG_VERSION}/libpng-${LIBPNG_VERSION}.tar.xz"

SRC="$DEPS/src"
mkdir -p "$SRC"
cd "$SRC"

fetch_src () {   # $1=url  $2=srcdir
  local URL="$1" DIR="$2" TARBALL
  TARBALL="$(basename "$URL")"
  if [ ! -d "$DIR" ]; then
    echo ">> downloading $TARBALL"
    curl -fL --retry 3 --retry-delay 5 -o "$TARBALL" "$URL"
    tar -xf "$TARBALL"
    rm -f "$TARBALL"
  fi
}

fetch_src "$LIBPNG_URL"   "libpng-${LIBPNG_VERSION}"
fetch_src "$FREETYPE_URL" "freetype-${FREETYPE_VERSION}"

rm -rf "$PREFIX"

# CMAKE_FIND_ROOT_PATH_MODE_* + CMAKE_IGNORE_PREFIX_PATH keep CMake's package
# search out of Homebrew: freetype's CMakeLists auto-enables any optional
# dependency it can find (that is precisely how brotli crept into Homebrew's
# own freetype), and the FT_DISABLE_* switches below are only half of the
# guarantee. The verify step at the end is the other half.
COMMON=(
  -G "Unix Makefiles"
  -DCMAKE_OSX_ARCHITECTURES=arm64
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOY"
  -DCMAKE_INSTALL_PREFIX="$PREFIX"
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON
  -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local;/opt/local"
)

# --- libpng (first: freetype links against it) ---
PNGBUILD="$DEPS/build_libpng"
rm -rf "$PNGBUILD"
cmake -S "libpng-${LIBPNG_VERSION}" -B "$PNGBUILD" "${COMMON[@]}" \
  -DPNG_SHARED=OFF -DPNG_STATIC=ON -DPNG_FRAMEWORK=OFF -DPNG_TESTS=OFF -DPNG_TOOLS=OFF
cmake --build "$PNGBUILD" --target install -j"$(sysctl -n hw.ncpu)"

# --- freetype (points at the libpng we just installed) ---
FTBUILD="$DEPS/build_freetype"
rm -rf "$FTBUILD"
cmake -S "freetype-${FREETYPE_VERSION}" -B "$FTBUILD" "${COMMON[@]}" \
  -DBUILD_SHARED_LIBS=OFF \
  -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BROTLI=ON -DFT_DISABLE_BZIP2=ON \
  -DFT_DISABLE_PNG=OFF -DFT_DISABLE_ZLIB=OFF \
  -DPNG_PNG_INCLUDE_DIR="$PREFIX/include" \
  -DPNG_LIBRARY="$PREFIX/lib/libpng16.a"
cmake --build "$FTBUILD" --target install -j"$(sysctl -n hw.ncpu)"

rm -rf "$PNGBUILD" "$FTBUILD"

# --- verify ---
for a in libpng16.a libfreetype.a; do
  test -f "$PREFIX/lib/$a" || { echo "ERROR: $PREFIX/lib/$a missing" >&2; exit 1; }
  ARCHS="$(lipo -archs "$PREFIX/lib/$a")"
  [ "$ARCHS" = arm64 ] || { echo "ERROR: $a archs '$ARCHS', expected arm64" >&2; exit 1; }
done
# freetype must not reference any optional codec we did not build: an
# undefined BrotliDecoder*/hb_*/BZ2_* symbol would fail the app link (or, worse,
# be satisfied by a stray Homebrew dylib on the search path).
if nm -u "$PREFIX/lib/libfreetype.a" 2>/dev/null | grep -Eq '_(Brotli|hb_|BZ2_)'; then
  echo "ERROR: libfreetype.a references brotli/harfbuzz/bzip2 symbols:" >&2
  nm -u "$PREFIX/lib/libfreetype.a" | grep -E '_(Brotli|hb_|BZ2_)' | sort -u >&2
  exit 1
fi

echo "$WANT" > "$STAMP"
echo ">> macOS deps staged in $PREFIX ($WANT)"
