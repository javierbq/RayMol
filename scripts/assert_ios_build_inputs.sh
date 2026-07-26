#!/bin/bash
# assert_ios_build_inputs.sh — fail LOUDLY, before xcodebuild starts, if
# anything the iOS DEVICE build links is missing or the wrong architecture.
#
# Without this, a missing dependency surfaces as an opaque linker error minutes
# into an Xcode Cloud archive. Every path below is one the device slice of
# swiftui/PyMOLBridge.xcconfig points at.
#
# Usage: assert_ios_build_inputs.sh [repo-root]     (defaults to this repo)
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
CORE="$ROOT/build_ios_device/libpymol_core.a"

PROBLEMS=0

if [ ! -f "$CORE" ]; then
  echo "MISSING: build_ios_device/libpymol_core.a (did swiftui/build_ios.sh device run?)" >&2
  PROBLEMS=1
else
  ARCHS="$(lipo -archs "$CORE" 2>/dev/null || echo "<unreadable>")"
  # Exactly arm64. A simulator build links fine and then cannot run on a device.
  if [ "$ARCHS" != "arm64" ]; then
    echo "WRONG ARCH: libpymol_core.a archs = '$ARCHS', expected 'arm64'" >&2
    echo "            (a simulator core here would produce an unrunnable app)" >&2
    PROBLEMS=1
  fi
fi

REQUIRED=(
  "deps_ios/Python.xcframework/ios-arm64/Python.framework/Python"
  "deps_ios/Python.xcframework/ios-arm64/Python.framework/Headers"
  "deps_ios/Python.xcframework/ios-arm64/lib/python3.13"
  "deps_ios/Python.xcframework/ios-arm64/lib/python3.13/site-packages/Bio"
  "deps_ios/install_device/lib/libpng16.a"
  "deps_ios/install_device/lib/libfreetype.a"
  "deps_ios/numpy-ios/device/numpy"
)

# Report EVERY problem in one pass — fixing these one build at a time is slow.
for r in "${REQUIRED[@]}"; do
  [ -e "$ROOT/$r" ] || { echo "MISSING: $r" >&2; PROBLEMS=1; }
done

[ "$PROBLEMS" = 0 ] || {
  echo "ERROR: iOS device build inputs are incomplete (see above)." >&2
  echo "       deps_ios comes from the 'iOS deps artifact' workflow;" >&2
  echo "       libpymol_core.a comes from swiftui/build_ios.sh device." >&2
  exit 1; }

echo "iOS build inputs OK (core arm64 + deps_ios device slice complete)"
