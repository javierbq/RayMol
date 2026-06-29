#!/bin/bash
# build_numpy_ios.sh — cross-compile numpy for iOS (arm64 device + simulator)
# and stage it into deps_ios/numpy-ios/{simulator,device}/numpy so the Xcode
# "iOS: Prepare Python binary modules" build phase can bundle + framework-wrap it.
#
# numpy ships NO iOS wheels, so this cross-compiles from the sdist with numpy's
# vendored Meson (which provides the custom 'features' CPU-dispatch module).
# No external BLAS/LAPACK — numpy's bundled lapack-lite is used (-Dblas=none
# -Dlapack=none -Dallow-noblas=true).
#
# Key gotchas baked in below (discovered the hard way):
#   * Use numpy's VENDORED meson (vendored-meson/meson/meson.py), NOT a system
#     meson — the 'features' module only exists there.
#   * Do NOT pass -fembed-bitcode-marker: it makes ld emit "path=marker" errors,
#     which break meson's link-based has_function() probes (libm 'sin' etc.).
#   * libm is part of libSystem on iOS (no separate -lm) — once linking works,
#     the math functions resolve fine.
#   * Rename the built *.cpython-313-darwin.so to the iOS EXT_SUFFIX
#     (.cpython-313-iphonesimulator.so / .cpython-313-iphoneos.so) so the
#     embedded interpreter's import machinery finds them.
#
# Requires: Xcode, a host CPython 3.13, and `pip install meson ninja cython`.
set -euo pipefail

NUMPY_VERSION="${NUMPY_VERSION:-2.4.6}"
DEPLOY="${IOS_DEPLOYMENT_TARGET:-16.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PYHOST="${PYHOST:-/opt/homebrew/bin/python3.13}"
WORK="$(mktemp -d)"
OUT="$ROOT/deps_ios/numpy-ios"

PY_SIM_HDR="$ROOT/deps_ios/Python.xcframework/ios-arm64_x86_64-simulator/Python.framework/Headers"
PY_DEV_HDR="$ROOT/deps_ios/Python.xcframework/ios-arm64/Python.framework/Headers"

echo ">> host python: $PYHOST"; "$PYHOST" --version
"$PYHOST" -c "import meson, ninja" 2>/dev/null || {
  echo "ERROR: install build tools first:  $PYHOST -m pip install meson ninja cython build"; exit 1; }

echo ">> downloading numpy $NUMPY_VERSION sdist"
"$PYHOST" -m pip download --no-deps --no-binary=:all: "numpy==$NUMPY_VERSION" --dest "$WORK"
tar xzf "$WORK/numpy-$NUMPY_VERSION.tar.gz" -C "$WORK"
SRC="$WORK/numpy-$NUMPY_VERSION"
MESON="$PYHOST $SRC/vendored-meson/meson/meson.py"

build_slice () {   # $1=sdk  $2=triple  $3=pyhdr  $4=ext_suffix  $5=outname
  local SDKNAME="$1" TRIPLE="$2" PYHDR="$3" EXT="$4" NAME="$5"
  local SDK CLANG CLANGXX AR STRIP BUILDDIR STAGE CROSS
  SDK="$(xcrun --sdk "$SDKNAME" --show-sdk-path)"
  CLANG="$(xcrun --sdk "$SDKNAME" -f clang)"
  CLANGXX="$(xcrun --sdk "$SDKNAME" -f clang++)"
  AR="$(xcrun --sdk "$SDKNAME" -f ar)"
  STRIP="$(xcrun --sdk "$SDKNAME" -f strip)"
  BUILDDIR="$WORK/build_$NAME"
  STAGE="$WORK/stage_$NAME"
  CROSS="$WORK/$NAME.cross"
  cat > "$CROSS" <<EOF
[binaries]
c = ['$CLANG', '-target', '$TRIPLE', '-isysroot', '$SDK']
cpp = ['$CLANGXX', '-target', '$TRIPLE', '-isysroot', '$SDK']
ar = '$AR'
strip = '$STRIP'

[host_machine]
system = 'darwin'
kernel = 'xnu'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'

[properties]
needs_exe_wrapper = true
longdouble_format = 'IEEE_DOUBLE_LE'

[built-in options]
c_args = ['-target', '$TRIPLE', '-isysroot', '$SDK', '-I$PYHDR']
cpp_args = ['-target', '$TRIPLE', '-isysroot', '$SDK', '-I$PYHDR']
c_link_args = ['-target', '$TRIPLE', '-isysroot', '$SDK']
cpp_link_args = ['-target', '$TRIPLE', '-isysroot', '$SDK']
EOF
  echo ">> [$NAME] meson setup"
  ( cd "$SRC" && $MESON setup "$BUILDDIR" --cross-file "$CROSS" \
      -Dallow-noblas=true -Dblas=none -Dlapack=none )
  echo ">> [$NAME] ninja"
  ( cd "$SRC" && $MESON compile -C "$BUILDDIR" ) || ninja -C "$BUILDDIR"
  echo ">> [$NAME] install -> stage"
  rm -rf "$STAGE"
  ( cd "$SRC" && DESTDIR="$STAGE" $MESON install -C "$BUILDDIR" )
  local NP
  NP="$(find "$STAGE" -type d -name numpy -path '*site-packages*' | head -1)"
  rm -rf "$OUT/$NAME/numpy"; mkdir -p "$OUT/$NAME"
  ditto "$NP" "$OUT/$NAME/numpy"
  # Drop test-only extensions (not needed at runtime; fewer frameworks).
  find "$OUT/$NAME/numpy" -name "*_tests.cpython*.so" -delete
  find "$OUT/$NAME/numpy" -name "_operand_flag_tests*.so" -delete
  find "$OUT/$NAME/numpy" -name "_rational_tests*.so" -delete
  find "$OUT/$NAME/numpy" -name "_struct_ufunc_tests*.so" -delete
  # Rename host (-darwin) suffix to the iOS EXT_SUFFIX so import finds them.
  # -print0 | read -d '' so paths containing spaces/newlines don't word-split
  # (an unquoted $(find ...) would split and the mv would silently miss files).
  find "$OUT/$NAME/numpy" -name "*.cpython-313-darwin.so" -print0 | while IFS= read -r -d '' so; do
    mv "$so" "${so/.cpython-313-darwin.so/$EXT}"
  done
  echo ">> [$NAME] staged $(find "$OUT/$NAME/numpy" -name '*.so' | wc -l | tr -d ' ') extension modules"
}

build_slice iphonesimulator "arm64-apple-ios${DEPLOY}-simulator" "$PY_SIM_HDR" ".cpython-313-iphonesimulator.so" simulator
build_slice iphoneos        "arm64-apple-ios${DEPLOY}"           "$PY_DEV_HDR" ".cpython-313-iphoneos.so"        device

echo ">> done. numpy slices in $OUT/{simulator,device}/numpy"
rm -rf "$WORK"
