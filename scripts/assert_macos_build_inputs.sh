#!/bin/bash
# assert_macos_build_inputs.sh — fail LOUDLY, before xcodebuild starts, if
# anything the Mac App Store (sandboxed, Sparkle-free) macOS archive needs is
# missing, the wrong architecture, or still configured for the DMG build.
#
# The macOS sibling of assert_ios_build_inputs.sh, for the same reason: on
# Xcode Cloud a missing input otherwise surfaces as an opaque linker error, or —
# worse — as a build that succeeds and then fails upload validation. Paths come
# from:
#   swiftui/PyMOLBridge.xcconfig — the macOS link line: libpymol_core.a,
#     -lpython3.13 from the standalone tree, -lfreetype -lpng16 from the
#     package-manager prefix, and libomp.a linked statically by path
#   swiftui/project.yml ("macOS: Bundle Python + modules + data") — the
#     embedded interpreter and its numpy + Biopython
#   scripts/apply_mas_restrictions.sh — what the generated project must look
#     like for an App Store build (no Sparkle, RAYMOL_MAS_RESTRICTED)
#
# Usage: assert_macos_build_inputs.sh [repo-root]     (defaults to this repo)
# The package-manager prefix comes from $PYMOL_EXTERNAL_PREFIX (default
# /opt/homebrew), exactly as swiftui/build_macos.sh reads it.
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
PREFIX="${PYMOL_EXTERNAL_PREFIX:-/opt/homebrew}"
CORE="$ROOT/build_macos_swiftui/libpymol_core.a"
PBXPROJ="$ROOT/swiftui/PyMOLViewer.xcodeproj/project.pbxproj"
PYROOT="deps_macos/python-standalone/python"

PROBLEMS=0

if [ ! -f "$CORE" ]; then
  echo "MISSING: build_macos_swiftui/libpymol_core.a (did swiftui/build_macos.sh run?)" >&2
  PROBLEMS=1
else
  ARCHS="$(lipo -archs "$CORE" 2>/dev/null || echo "<unreadable>")"
  # project.yml pins ARCHS=arm64 for Release; anything else fails the link.
  if [ "$ARCHS" != "arm64" ]; then
    echo "WRONG ARCH: libpymol_core.a archs = '$ARCHS', expected 'arm64'" >&2
    PROBLEMS=1
  fi
fi

REQUIRED=(
  "$ROOT/$PYROOT/lib/libpython3.13.dylib"
  "$ROOT/$PYROOT/include/python3.13/Python.h"
  "$ROOT/$PYROOT/lib/python3.13/site-packages/numpy"
  "$ROOT/$PYROOT/lib/python3.13/site-packages/Bio"
  # Homebrew's keg layout; PyMOLBridge.xcconfig's PYMOL_LIBOMP_STATIC default.
  "$PREFIX/opt/libomp/lib/libomp.a"
  "$PREFIX/lib/libfreetype.dylib"
  "$PREFIX/lib/libpng16.dylib"
  "$PREFIX/include/glm/glm.hpp"
  "$PBXPROJ"
)

# Report EVERY problem in one pass — fixing these one build at a time is slow.
for r in "${REQUIRED[@]}"; do
  [ -e "$r" ] || { echo "MISSING: $r" >&2; PROBLEMS=1; }
done

# The generated project must be the App Store variant. A Sparkle package left in
# it archives fine and is then rejected at upload (error 90296); a missing
# RAYMOL_MAS_RESTRICTED compiles Sparkle + MCP code back in.
if [ -f "$PBXPROJ" ]; then
  if grep -q 'XCRemoteSwiftPackageReference "Sparkle"' "$PBXPROJ"; then
    echo "NOT MAS: the generated project still references the Sparkle package" >&2
    echo "         (scripts/apply_mas_restrictions.sh must run before xcodegen)" >&2
    PROBLEMS=1
  fi
  if ! grep -q 'RAYMOL_MAS_RESTRICTED' "$PBXPROJ"; then
    echo "NOT MAS: RAYMOL_MAS_RESTRICTED is absent from the generated project" >&2
    PROBLEMS=1
  fi
fi

[ "$PROBLEMS" = 0 ] || {
  echo "ERROR: macOS App Store build inputs are incomplete (see above)." >&2
  echo "       deps_macos comes from scripts/setup_macos_deps.sh; the Homebrew" >&2
  echo "       libraries from 'brew install'; libpymol_core.a from" >&2
  echo "       swiftui/build_macos.sh." >&2
  exit 1; }

echo "macOS build inputs OK (core arm64, embedded Python + numpy + Bio, MAS project)"
