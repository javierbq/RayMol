#!/bin/bash
# Unit tests for scripts/assert_macos_build_inputs.sh.
#
# Like run_assert_ios_build_inputs_test.sh, the arch check uses a REAL static
# library built by clang, because `lipo -archs` is what the script calls. The
# package-manager prefix is a fixture directory passed via PYMOL_EXTERNAL_PREFIX,
# so the suite never depends on what the host's Homebrew has installed.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/assert_macos_build_inputs.sh"
FAILED=0

make_lib () {
  local arch="$1" out="$2" tmp
  tmp="$(mktemp -d)"
  echo 'int raymol_probe(void){return 0;}' > "$tmp/p.c"
  clang -c -arch "$arch" "$tmp/p.c" -o "$tmp/p.o" 2>/dev/null
  mkdir -p "$(dirname "$out")"
  ar rcs "$out" "$tmp/p.o" 2>/dev/null
  rm -rf "$tmp"
}

# A fake repo root (with its prefix at $root/prefix) holding everything the
# MAS macOS archive needs.
make_fixture () {
  local r py; r="$(mktemp -d)"
  py="$r/deps_macos/python-standalone/python"
  mkdir -p "$py/lib/python3.13/site-packages/numpy" "$py/lib/python3.13/site-packages/Bio" \
           "$py/include/python3.13"
  : > "$py/lib/libpython3.13.dylib"
  : > "$py/include/python3.13/Python.h"
  mkdir -p "$r/prefix/opt/libomp/lib" "$r/prefix/lib" "$r/prefix/include/glm"
  : > "$r/prefix/opt/libomp/lib/libomp.a"
  : > "$r/prefix/lib/libfreetype.dylib"
  : > "$r/prefix/lib/libpng16.dylib"
  : > "$r/prefix/include/glm/glm.hpp"
  mkdir -p "$r/swiftui/PyMOLViewer.xcodeproj"
  cat > "$r/swiftui/PyMOLViewer.xcodeproj/project.pbxproj" <<'PBX'
		1234 /* XCRemoteSwiftPackageReference "boltz-mlx" */ = {
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = "$(inherited) RAYMOL_MPNN RAYMOL_MAS_RESTRICTED";
PBX
  make_lib arm64 "$r/build_macos_swiftui/libpymol_core.a"
  echo "$r"
}

run () { PYMOL_EXTERNAL_PREFIX="$1/prefix" bash "$SCRIPT" "$1"; }

echo "== assert_macos_build_inputs =="

R="$(make_fixture)"
if run "$R" >/dev/null 2>&1; then
  echo "  ok: complete tree passes"
else
  echo "  FAIL: complete tree should pass"; run "$R"; FAILED=1
fi
rm -rf "$R"

# Each input is individually load-bearing.
for req in \
  "deps_macos/python-standalone/python/lib/libpython3.13.dylib" \
  "deps_macos/python-standalone/python/include/python3.13/Python.h" \
  "deps_macos/python-standalone/python/lib/python3.13/site-packages/numpy" \
  "deps_macos/python-standalone/python/lib/python3.13/site-packages/Bio" \
  "prefix/opt/libomp/lib/libomp.a" \
  "prefix/lib/libfreetype.dylib" \
  "prefix/lib/libpng16.dylib" \
  "prefix/include/glm/glm.hpp" \
  "swiftui/PyMOLViewer.xcodeproj/project.pbxproj" \
  "build_macos_swiftui/libpymol_core.a"; do
  F="$(make_fixture)"; rm -rf "$F/$req"
  if run "$F" >/dev/null 2>&1; then
    echo "  FAIL: passed with $req missing"; FAILED=1
  else echo "  ok: fails when $req is missing"; fi
  rm -rf "$F"
done

# Wrong architecture.
F="$(make_fixture)"; rm -f "$F/build_macos_swiftui/libpymol_core.a"
make_lib x86_64 "$F/build_macos_swiftui/libpymol_core.a"
if run "$F" >/dev/null 2>&1; then
  echo "  FAIL: accepted an x86_64 core library"; FAILED=1
else echo "  ok: rejects a non-arm64 core library"; fi
rm -rf "$F"

# A generated project that is still the DMG variant.
F="$(make_fixture)"
echo '		5678 /* XCRemoteSwiftPackageReference "Sparkle" */ = {' \
  >> "$F/swiftui/PyMOLViewer.xcodeproj/project.pbxproj"
if run "$F" >/dev/null 2>&1; then
  echo "  FAIL: accepted a project that still references Sparkle"; FAILED=1
else echo "  ok: rejects a project that still references Sparkle"; fi
rm -rf "$F"

F="$(make_fixture)"
/usr/bin/sed -i '' 's/ RAYMOL_MAS_RESTRICTED//' "$F/swiftui/PyMOLViewer.xcodeproj/project.pbxproj"
if run "$F" >/dev/null 2>&1; then
  echo "  FAIL: accepted a project without RAYMOL_MAS_RESTRICTED"; FAILED=1
else echo "  ok: rejects a project without RAYMOL_MAS_RESTRICTED"; fi
rm -rf "$F"

# Diagnostics: report EVERY problem at once.
F="$(make_fixture)"
rm -rf "$F/prefix/opt/libomp/lib/libomp.a" "$F/deps_macos/python-standalone/python/lib/python3.13/site-packages/numpy"
OUT="$(run "$F" 2>&1)"
if grep -q "libomp.a" <<<"$OUT" && grep -q "site-packages/numpy" <<<"$OUT"; then
  echo "  ok: lists all missing paths"
else echo "  FAIL: did not list all missing paths; got: $OUT"; FAILED=1; fi
rm -rf "$F"

[ "$FAILED" = 0 ] && echo "PASS" || { echo "FAILURES"; exit 1; }
