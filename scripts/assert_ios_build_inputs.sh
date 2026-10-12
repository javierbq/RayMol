#!/bin/bash
# assert_ios_build_inputs.sh — fail LOUDLY, before xcodebuild starts, if
# anything the iOS build links is missing or the wrong architecture.
# Supports both `device` (default) and `simulator` slices.
#
# Without this, a missing dependency surfaces as an opaque linker error minutes
# into an Xcode Cloud archive or test build. Paths below come from two sources:
#   swiftui/PyMOLBridge.xcconfig — the linked libraries and Python headers for
#     the device/simulator slice
#   swiftui/project.yml (iOS build phases) — the bundled stdlib, Biopython
#     and numpy paths
#
# Usage: assert_ios_build_inputs.sh [repo-root] [device|simulator]
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
SLICE="${2:-device}"

if [ "$SLICE" != "device" ] && [ "$SLICE" != "simulator" ]; then
  echo "ERROR: invalid slice '$SLICE' (expected 'device' or 'simulator')" >&2
  echo "Usage: assert_ios_build_inputs.sh [repo-root] [device|simulator]" >&2
  exit 1
fi

PROBLEMS=0

if [ "$SLICE" = "device" ]; then
  CORE="$ROOT/build_ios_device/libpymol_core.a"

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
    # Required despite being a simulator path: appkit/CMakeLists.txt line 90
    # unconditionally points the Python header search path at the simulator slice
    # for ALL iOS core builds, including the device build done here. Without these
    # headers the compiler silently falls back to Homebrew's python@3.13 headers,
    # compiling the core against the wrong Python ABI. Do not remove this entry
    # to "clean up" the apparent inconsistency — it is load-bearing.
    "deps_ios/Python.xcframework/ios-arm64_x86_64-simulator/Python.framework/Headers"
  )
else
  CORE="$ROOT/build_ios/libpymol_core.a"

  if [ ! -f "$CORE" ]; then
    echo "MISSING: build_ios/libpymol_core.a (did swiftui/build_ios.sh run?)" >&2
    PROBLEMS=1
  else
    ARCHS="$(lipo -archs "$CORE" 2>/dev/null || echo "<unreadable>")"
    # Archs must contain arm64 (simulator libs may legitimately be x86_64 arm64).
    if ! grep -q -w "arm64" <<<"$ARCHS"; then
      echo "WRONG ARCH: libpymol_core.a archs = '$ARCHS', expected 'arm64'" >&2
      echo "            (Xcode Cloud runs on Apple silicon and requires an arm64 slice)" >&2
      PROBLEMS=1
    fi
  fi

  REQUIRED=(
    "deps_ios/Python.xcframework/ios-arm64_x86_64-simulator/Python.framework/Python"
    "deps_ios/Python.xcframework/ios-arm64_x86_64-simulator/Python.framework/Headers"
    "deps_ios/Python.xcframework/ios-arm64_x86_64-simulator/lib/python3.13"
    "deps_ios/Python.xcframework/ios-arm64_x86_64-simulator/lib/python3.13/site-packages/Bio"
    "deps_ios/install/lib/libpng16.a"
    "deps_ios/install/lib/libfreetype.a"
    "deps_ios/numpy-ios/simulator/numpy"
  )
fi

# Report EVERY problem in one pass — fixing these one build at a time is slow.
for r in "${REQUIRED[@]}"; do
  [ -e "$ROOT/$r" ] || { echo "MISSING: $r" >&2; PROBLEMS=1; }
done

if [ "$PROBLEMS" != 0 ]; then
  if [ "$SLICE" = "device" ]; then
    echo "ERROR: iOS device build inputs are incomplete (see above)." >&2
    echo "       deps_ios comes from the 'iOS deps artifact' workflow;" >&2
    echo "       libpymol_core.a comes from swiftui/build_ios.sh device." >&2
  else
    echo "ERROR: iOS simulator build inputs are incomplete (see above)." >&2
    echo "       deps_ios comes from the 'iOS deps artifact' workflow;" >&2
    echo "       libpymol_core.a comes from swiftui/build_ios.sh." >&2
  fi
  exit 1
fi

echo "iOS build inputs OK (core arm64 + deps_ios $SLICE slice complete)"
