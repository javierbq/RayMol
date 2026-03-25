#!/usr/bin/env bash
#
# build_deps.sh - Build static C dependencies for PyMOL (arm64, macOS 12.0+)
#
# Usage: ./scripts/build_deps.sh
#
# Downloads and builds: zlib, libpng, freetype, GLEW, libxml2, netcdf-c
# Output: deps/arm64/{lib,include}
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PREFIX="$REPO_ROOT/deps/arm64"
SRC_DIR="$REPO_ROOT/deps/src"
BUILD_DIR="$REPO_ROOT/deps/build"

MACOSX_DEPLOYMENT_TARGET=12.0
export MACOSX_DEPLOYMENT_TARGET

ARCH_FLAGS="-arch arm64"
export CFLAGS="${CFLAGS:-} $ARCH_FLAGS -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET -O2"
export CXXFLAGS="${CXXFLAGS:-} $ARCH_FLAGS -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET -O2"
export LDFLAGS="${LDFLAGS:-} $ARCH_FLAGS -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
export CMAKE_OSX_ARCHITECTURES=arm64

NPROC=$(sysctl -n hw.ncpu)

# Dependency versions
ZLIB_VERSION=1.3.1
LIBPNG_VERSION=1.6.43
FREETYPE_VERSION=2.13.3
GLEW_VERSION=2.2.0
LIBXML2_VERSION=2.12.9
NETCDF_VERSION=4.9.2
HDF5_VERSION=1.14.5

ZLIB_URL="https://github.com/madler/zlib/releases/download/v${ZLIB_VERSION}/zlib-${ZLIB_VERSION}.tar.gz"
LIBPNG_URL="https://download.sourceforge.net/libpng/libpng-${LIBPNG_VERSION}.tar.xz"
FREETYPE_URL="https://download.savannah.gnu.org/releases/freetype/freetype-${FREETYPE_VERSION}.tar.xz"
GLEW_URL="https://github.com/nigels-com/glew/releases/download/glew-${GLEW_VERSION}/glew-${GLEW_VERSION}.tgz"
LIBXML2_URL="https://download.gnome.org/sources/libxml2/2.12/libxml2-${LIBXML2_VERSION}.tar.xz"
NETCDF_URL="https://downloads.unidata.ucar.edu/netcdf-c/${NETCDF_VERSION}/netcdf-c-${NETCDF_VERSION}.tar.gz"
HDF5_URL="https://github.com/HDFGroup/hdf5/releases/download/hdf5_${HDF5_VERSION}/hdf5-${HDF5_VERSION}.tar.gz"

mkdir -p "$PREFIX"/{lib,include} "$SRC_DIR" "$BUILD_DIR"

download() {
    local url="$1" dest="$2"
    if [ -f "$dest" ]; then
        echo "  Already downloaded: $(basename "$dest")"
        return
    fi
    echo "  Downloading: $(basename "$dest")"
    curl -fSL "$url" -o "$dest"
}

# --------------------------------------------------------------------------
# zlib
# --------------------------------------------------------------------------
build_zlib() {
    echo "=== Building zlib ${ZLIB_VERSION} ==="
    download "$ZLIB_URL" "$SRC_DIR/zlib-${ZLIB_VERSION}.tar.gz"
    cd "$BUILD_DIR"
    rm -rf "zlib-${ZLIB_VERSION}"
    tar xf "$SRC_DIR/zlib-${ZLIB_VERSION}.tar.gz"
    cd "zlib-${ZLIB_VERSION}"
    ./configure --prefix="$PREFIX" --static
    make -j"$NPROC"
    make install
    # Remove any shared libs that snuck in
    rm -f "$PREFIX"/lib/libz.dylib "$PREFIX"/lib/libz.*.dylib
    echo "  zlib installed to $PREFIX"
}

# --------------------------------------------------------------------------
# libpng (depends on zlib)
# --------------------------------------------------------------------------
build_libpng() {
    echo "=== Building libpng ${LIBPNG_VERSION} ==="
    download "$LIBPNG_URL" "$SRC_DIR/libpng-${LIBPNG_VERSION}.tar.xz"
    cd "$BUILD_DIR"
    rm -rf "libpng-${LIBPNG_VERSION}"
    tar xf "$SRC_DIR/libpng-${LIBPNG_VERSION}.tar.xz"
    cd "libpng-${LIBPNG_VERSION}"
    export CPPFLAGS="-I$PREFIX/include"
    export LDFLAGS_SAVE="$LDFLAGS"
    export LDFLAGS="$LDFLAGS -L$PREFIX/lib"
    ./configure \
        --prefix="$PREFIX" \
        --enable-static \
        --disable-shared \
        --host=aarch64-apple-darwin
    make -j"$NPROC"
    make install
    export LDFLAGS="$LDFLAGS_SAVE"
    unset CPPFLAGS
    echo "  libpng installed to $PREFIX"
}

# --------------------------------------------------------------------------
# freetype (can optionally use libpng for color emoji, we enable it)
# --------------------------------------------------------------------------
build_freetype() {
    echo "=== Building freetype ${FREETYPE_VERSION} ==="
    download "$FREETYPE_URL" "$SRC_DIR/freetype-${FREETYPE_VERSION}.tar.xz"
    cd "$BUILD_DIR"
    rm -rf "freetype-${FREETYPE_VERSION}"
    tar xf "$SRC_DIR/freetype-${FREETYPE_VERSION}.tar.xz"
    cd "freetype-${FREETYPE_VERSION}"
    ./configure \
        --prefix="$PREFIX" \
        --enable-static \
        --disable-shared \
        --with-png=yes \
        --with-zlib=yes \
        --with-harfbuzz=no \
        --with-bzip2=no \
        --with-brotli=no \
        PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
    make -j"$NPROC"
    make install
    echo "  freetype installed to $PREFIX"
}

# --------------------------------------------------------------------------
# GLEW
# --------------------------------------------------------------------------
build_glew() {
    echo "=== Building GLEW ${GLEW_VERSION} ==="
    download "$GLEW_URL" "$SRC_DIR/glew-${GLEW_VERSION}.tgz"
    cd "$BUILD_DIR"
    rm -rf "glew-${GLEW_VERSION}"
    tar xf "$SRC_DIR/glew-${GLEW_VERSION}.tgz"
    cd "glew-${GLEW_VERSION}"
    # GLEW uses a Makefile, not configure. Build only the static library.
    make -j"$NPROC" \
        GLEW_DEST="$PREFIX" \
        SYSTEM=darwin \
        CC="cc $ARCH_FLAGS -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET" \
        LD="cc $ARCH_FLAGS -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET" \
        STRIP= \
        glew.lib.static
    # Install manually
    cp -f lib/libGLEW.a "$PREFIX/lib/"
    cp -rf include/GL "$PREFIX/include/"
    echo "  GLEW installed to $PREFIX"
}

# --------------------------------------------------------------------------
# libxml2
# --------------------------------------------------------------------------
build_libxml2() {
    echo "=== Building libxml2 ${LIBXML2_VERSION} ==="
    download "$LIBXML2_URL" "$SRC_DIR/libxml2-${LIBXML2_VERSION}.tar.xz"
    cd "$BUILD_DIR"
    rm -rf "libxml2-${LIBXML2_VERSION}"
    tar xf "$SRC_DIR/libxml2-${LIBXML2_VERSION}.tar.xz"
    cd "libxml2-${LIBXML2_VERSION}"
    ./configure \
        --prefix="$PREFIX" \
        --enable-static \
        --disable-shared \
        --without-python \
        --without-icu \
        --without-lzma \
        --with-zlib="$PREFIX"
    make -j"$NPROC"
    make install
    echo "  libxml2 installed to $PREFIX"
}

# --------------------------------------------------------------------------
# HDF5 (needed by netcdf-c)
# --------------------------------------------------------------------------
build_hdf5() {
    echo "=== Building HDF5 ${HDF5_VERSION} ==="
    download "$HDF5_URL" "$SRC_DIR/hdf5-${HDF5_VERSION}.tar.gz"
    cd "$BUILD_DIR"
    rm -rf "hdf5-${HDF5_VERSION}"
    tar xf "$SRC_DIR/hdf5-${HDF5_VERSION}.tar.gz"
    cd "hdf5-${HDF5_VERSION}"
    cmake -B build \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET \
        -DCMAKE_PREFIX_PATH="$PREFIX" \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_TESTING=OFF \
        -DHDF5_BUILD_TOOLS=OFF \
        -DHDF5_BUILD_UTILS=OFF \
        -DHDF5_BUILD_EXAMPLES=OFF \
        -DHDF5_ENABLE_Z_LIB_SUPPORT=ON \
        -DZLIB_ROOT="$PREFIX"
    cmake --build build -j"$NPROC"
    cmake --install build
    echo "  HDF5 installed to $PREFIX"
}

# --------------------------------------------------------------------------
# netcdf-c (depends on HDF5 and zlib)
# --------------------------------------------------------------------------
build_netcdf() {
    echo "=== Building netcdf-c ${NETCDF_VERSION} ==="
    download "$NETCDF_URL" "$SRC_DIR/netcdf-c-${NETCDF_VERSION}.tar.gz"
    cd "$BUILD_DIR"
    rm -rf "netcdf-c-${NETCDF_VERSION}"
    tar xf "$SRC_DIR/netcdf-c-${NETCDF_VERSION}.tar.gz"
    cd "netcdf-c-${NETCDF_VERSION}"
    cmake -B build \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET \
        -DCMAKE_PREFIX_PATH="$PREFIX" \
        -DBUILD_SHARED_LIBS=OFF \
        -DENABLE_TESTS=OFF \
        -DENABLE_DAP=OFF \
        -DENABLE_BYTERANGE=OFF \
        -DENABLE_EXAMPLES=OFF \
        -DHDF5_ROOT="$PREFIX"
    cmake --build build -j"$NPROC"
    cmake --install build
    echo "  netcdf-c installed to $PREFIX"
}

# --------------------------------------------------------------------------
# Build everything in dependency order
# --------------------------------------------------------------------------
echo "Building static dependencies for arm64 (macOS $MACOSX_DEPLOYMENT_TARGET+)"
echo "Install prefix: $PREFIX"
echo ""

build_zlib
build_libpng
build_freetype
build_glew
build_libxml2
build_hdf5
build_netcdf

echo ""
echo "=== All dependencies built ==="
echo "Static libraries in: $PREFIX/lib/"
ls -la "$PREFIX/lib/"*.a 2>/dev/null || echo "(no .a files found)"
echo ""
echo "Use with CMake: -DDEPS_PREFIX=$PREFIX"
