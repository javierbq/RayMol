#!/bin/bash
# Unit tests for scripts/prune_ios_deps.sh, using a fixture deps_ios tree of
# empty files — the script only makes structural decisions, never reads content.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/prune_ios_deps.sh"
FAILED=0

SLICES=(ios-arm64 ios-arm64_x86_64-simulator)

# A complete, valid deps_ios as setup_ios_deps.sh leaves it: shipping paths
# plus the intermediates we expect to be pruned away.
make_fixture () {
  local d; d="$(mktemp -d)/deps_ios"; mkdir -p "$d"
  for s in "${SLICES[@]}"; do
    mkdir -p "$d/Python.xcframework/$s/Python.framework/Headers"
    : > "$d/Python.xcframework/$s/Python.framework/Python"
    mkdir -p "$d/Python.xcframework/$s/lib/python3.13/site-packages/Bio"
  done
  for p in install install_device; do
    mkdir -p "$d/$p/lib" "$d/$p/include"
    : > "$d/$p/lib/libpng16.a"; : > "$d/$p/lib/libfreetype.a"
  done
  mkdir -p "$d/numpy-ios/simulator/numpy" "$d/numpy-ios/device/numpy"
  # Intermediates that must be pruned.
  mkdir -p "$d/build_freetype" "$d/build_freetype_device" \
           "$d/build_libpng" "$d/build_libpng_device" "$d/build_python_ios" \
           "$d/freetype-2.13.3" "$d/libpng-1.6.44"
  : > "$d/freetype.tar.xz"; : > "$d/libpng.tar.xz"
  echo "$d"
}

echo "== prune_ios_deps =="

D="$(make_fixture)"
if ! bash "$SCRIPT" "$D" >/dev/null 2>&1; then
  echo "  FAIL: pruning a complete tree should succeed"; FAILED=1
else
  echo "  ok: complete tree prunes cleanly"
fi

# Intermediates gone.
for junk in build_freetype build_freetype_device build_libpng build_libpng_device \
            build_python_ios freetype-2.13.3 libpng-1.6.44 \
            freetype.tar.xz libpng.tar.xz; do
  if [ -e "$D/$junk" ]; then echo "  FAIL: intermediate survived: $junk"; FAILED=1
  else echo "  ok: pruned $junk"; fi
done

# Shipping paths intact.
for keep in \
  "Python.xcframework/ios-arm64/Python.framework/Python" \
  "Python.xcframework/ios-arm64/Python.framework/Headers" \
  "Python.xcframework/ios-arm64/lib/python3.13/site-packages/Bio" \
  "Python.xcframework/ios-arm64_x86_64-simulator/Python.framework/Python" \
  "install/lib/libpng16.a" "install/lib/libfreetype.a" \
  "install_device/lib/libpng16.a" "install_device/lib/libfreetype.a" \
  "numpy-ios/simulator/numpy" "numpy-ios/device/numpy"; do
  if [ -e "$D/$keep" ]; then echo "  ok: kept $keep"
  else echo "  FAIL: pruning destroyed $keep"; FAILED=1; fi
done

# Every required path is individually load-bearing: removing any one of them
# before pruning must make the script fail rather than publish a broken artifact.
for req in \
  "Python.xcframework/ios-arm64/Python.framework/Python" \
  "Python.xcframework/ios-arm64/lib/python3.13/site-packages/Bio" \
  "install_device/lib/libfreetype.a" \
  "numpy-ios/device/numpy"; do
  E="$(make_fixture)"; rm -rf "$E/$req"
  if bash "$SCRIPT" "$E" >/dev/null 2>&1; then
    echo "  FAIL: succeeded with $req missing"; FAILED=1
  else echo "  ok: fails when $req is missing"; fi
  rm -rf "$(dirname "$E")"
done

# A non-directory argument is a loud failure.
if bash "$SCRIPT" "/nonexistent/deps_ios" >/dev/null 2>&1; then
  echo "  FAIL: missing directory should exit non-zero"; FAILED=1
else echo "  ok: missing directory exits non-zero"; fi

# Missing argument entirely.
if bash "$SCRIPT" >/dev/null 2>&1; then
  echo "  FAIL: no argument should exit non-zero"; FAILED=1
else echo "  ok: no argument exits non-zero"; fi

rm -rf "$(dirname "$D")"
[ "$FAILED" = 0 ] && echo "PASS" || { echo "FAILURES"; exit 1; }
