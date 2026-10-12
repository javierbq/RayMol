#!/bin/bash
# Unit tests for scripts/assert_ios_build_inputs.sh.
#
# The arch check is exercised with a REAL arm64 static library built by clang,
# not a stub, because `lipo -archs` is what the script actually calls.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/assert_ios_build_inputs.sh"
FAILED=0

# Build a static library for $1 (e.g. arm64, x86_64) at $2.
make_lib () {
  local arch="$1" out="$2" tmp
  tmp="$(mktemp -d)"
  echo 'int raymol_probe(void){return 0;}' > "$tmp/p.c"
  clang -c -arch "$arch" "$tmp/p.c" -o "$tmp/p.o" 2>/dev/null
  mkdir -p "$(dirname "$out")"
  ar rcs "$out" "$tmp/p.o" 2>/dev/null
  rm -rf "$tmp"
}

# A fake repo root with everything the DEVICE build needs.
make_fixture () {
  local r; r="$(mktemp -d)"
  mkdir -p "$r/deps_ios/Python.xcframework/ios-arm64/Python.framework/Headers"
  : >     "$r/deps_ios/Python.xcframework/ios-arm64/Python.framework/Python"
  mkdir -p "$r/deps_ios/Python.xcframework/ios-arm64/lib/python3.13/site-packages/Bio"
  mkdir -p "$r/deps_ios/install_device/lib"
  : >     "$r/deps_ios/install_device/lib/libpng16.a"
  : >     "$r/deps_ios/install_device/lib/libfreetype.a"
  mkdir -p "$r/deps_ios/numpy-ios/device/numpy"
  # Simulator headers are required even for the device build: appkit/CMakeLists.txt
  # unconditionally points its Python header search at this simulator slice.
  mkdir -p "$r/deps_ios/Python.xcframework/ios-arm64_x86_64-simulator/Python.framework/Headers"
  make_lib arm64 "$r/build_ios_device/libpymol_core.a"
  echo "$r"
}

# A fake repo root with everything the SIMULATOR build needs.
make_sim_fixture () {
  local r; r="$(mktemp -d)"
  mkdir -p "$r/deps_ios/Python.xcframework/ios-arm64_x86_64-simulator/Python.framework/Headers"
  : >     "$r/deps_ios/Python.xcframework/ios-arm64_x86_64-simulator/Python.framework/Python"
  mkdir -p "$r/deps_ios/Python.xcframework/ios-arm64_x86_64-simulator/lib/python3.13/site-packages/Bio"
  mkdir -p "$r/deps_ios/install/lib"
  : >     "$r/deps_ios/install/lib/libpng16.a"
  : >     "$r/deps_ios/install/lib/libfreetype.a"
  mkdir -p "$r/deps_ios/numpy-ios/simulator/numpy"
  make_lib arm64 "$r/build_ios/libpymol_core.a"
  echo "$r"
}

echo "== assert_ios_build_inputs =="

R="$(make_fixture)"
if bash "$SCRIPT" "$R" >/dev/null 2>&1; then
  echo "  ok: complete tree passes"
else
  echo "  FAIL: complete tree should pass"; bash "$SCRIPT" "$R"; FAILED=1
fi

# Each dep path is individually load-bearing.
for req in \
  "deps_ios/Python.xcframework/ios-arm64/Python.framework/Python" \
  "deps_ios/Python.xcframework/ios-arm64/Python.framework/Headers" \
  "deps_ios/Python.xcframework/ios-arm64/lib/python3.13/site-packages/Bio" \
  "deps_ios/install_device/lib/libpng16.a" \
  "deps_ios/install_device/lib/libfreetype.a" \
  "deps_ios/numpy-ios/device/numpy" \
  "deps_ios/Python.xcframework/ios-arm64_x86_64-simulator/Python.framework/Headers"; do
  F="$(make_fixture)"; rm -rf "$F/$req"
  if bash "$SCRIPT" "$F" >/dev/null 2>&1; then
    echo "  FAIL: passed with $req missing"; FAILED=1
  else echo "  ok: fails when $req is missing"; fi
  rm -rf "$F"
done

# Missing core library.
F="$(make_fixture)"; rm -f "$F/build_ios_device/libpymol_core.a"
if bash "$SCRIPT" "$F" >/dev/null 2>&1; then
  echo "  FAIL: passed with no libpymol_core.a"; FAILED=1
else echo "  ok: fails when libpymol_core.a is absent"; fi
rm -rf "$F"

# Wrong architecture — a simulator core would link but never run on a device.
F="$(make_fixture)"; rm -f "$F/build_ios_device/libpymol_core.a"
make_lib x86_64 "$F/build_ios_device/libpymol_core.a"
if bash "$SCRIPT" "$F" >/dev/null 2>&1; then
  echo "  FAIL: accepted an x86_64 core library"; FAILED=1
else echo "  ok: rejects a non-arm64 core library"; fi
rm -rf "$F"

# Diagnostics: report EVERY problem at once, not just the first.
F="$(make_fixture)"
rm -rf "$F/deps_ios/numpy-ios/device/numpy" "$F/deps_ios/install_device/lib/libpng16.a"
OUT="$(bash "$SCRIPT" "$F" 2>&1)"
if grep -q "numpy-ios/device/numpy" <<<"$OUT" && grep -q "libpng16.a" <<<"$OUT"; then
  echo "  ok: lists all missing paths"
else echo "  FAIL: did not list all missing paths; got: $OUT"; FAILED=1; fi
rm -rf "$F"
rm -rf "$R"

echo "== assert_ios_build_inputs (simulator) =="
SIM_R="$(make_sim_fixture)"
if bash "$SCRIPT" "$SIM_R" simulator >/dev/null 2>&1; then
  echo "  ok: complete simulator tree passes"
else
  echo "  FAIL: complete simulator tree should pass"; bash "$SCRIPT" "$SIM_R" simulator; FAILED=1
fi

# Each simulator dep path is individually load-bearing.
for req in \
  "deps_ios/Python.xcframework/ios-arm64_x86_64-simulator/Python.framework/Python" \
  "deps_ios/Python.xcframework/ios-arm64_x86_64-simulator/Python.framework/Headers" \
  "deps_ios/Python.xcframework/ios-arm64_x86_64-simulator/lib/python3.13" \
  "deps_ios/Python.xcframework/ios-arm64_x86_64-simulator/lib/python3.13/site-packages/Bio" \
  "deps_ios/install/lib/libpng16.a" \
  "deps_ios/install/lib/libfreetype.a" \
  "deps_ios/numpy-ios/simulator/numpy"; do
  F="$(make_sim_fixture)"; rm -rf "$F/$req"
  if bash "$SCRIPT" "$F" simulator >/dev/null 2>&1; then
    echo "  FAIL: passed with simulator $req missing"; FAILED=1
  else echo "  ok: fails when simulator $req is missing"; fi
  rm -rf "$F"
done

# Missing core library.
F="$(make_sim_fixture)"; rm -f "$F/build_ios/libpymol_core.a"
if bash "$SCRIPT" "$F" simulator >/dev/null 2>&1; then
  echo "  FAIL: simulator passed with no libpymol_core.a"; FAILED=1
else echo "  ok: simulator fails when libpymol_core.a is absent"; fi
rm -rf "$F"

# Wrong architecture — an x86_64-only core cannot run on Apple Silicon runners.
F="$(make_sim_fixture)"; rm -f "$F/build_ios/libpymol_core.a"
make_lib x86_64 "$F/build_ios/libpymol_core.a"
if bash "$SCRIPT" "$F" simulator >/dev/null 2>&1; then
  echo "  FAIL: simulator accepted an x86_64-only core library"; FAILED=1
else echo "  ok: simulator rejects an x86_64-only core library"; fi
rm -rf "$F"

# A device-only tree fails in simulator mode.
DEV="$(make_fixture)"
if bash "$SCRIPT" "$DEV" simulator >/dev/null 2>&1; then
  echo "  FAIL: device-only tree passed in simulator mode"; FAILED=1
else echo "  ok: device-only tree fails in simulator mode"; fi
rm -rf "$DEV"

# Invalid mode argument fails.
if bash "$SCRIPT" "$SIM_R" invalid_mode >/dev/null 2>&1; then
  echo "  FAIL: accepted invalid mode"; FAILED=1
else echo "  ok: rejects invalid mode argument"; fi
rm -rf "$SIM_R"

[ "$FAILED" = 0 ] && echo "PASS" || { echo "FAILURES"; exit 1; }
