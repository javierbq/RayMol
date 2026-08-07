#!/bin/bash
# prune_ios_deps.sh — reduce a populated deps_ios/ to ONLY what the Xcode build
# links, so the published artifact stays as small as possible to download on
# every Xcode Cloud build.
#
# What the build actually reads:
#   swiftui/PyMOLBridge.xcconfig — the linked libraries and Python headers:
#     Python.xcframework/<slice>/Python.framework/{Python,Headers}
#     install/lib/{libpng16.a,libfreetype.a}             simulator (platform 7)
#     install_device/lib/{libpng16.a,libfreetype.a}      device    (platform 2)
#   swiftui/project.yml (iOS build phases) — the bundled stdlib and packages:
#     Python.xcframework/<slice>/lib/python3.13          (stdlib + staged Bio)
#     numpy-ios/{simulator,device}/numpy
# Everything else is intermediate: CMake build trees, extracted freetype/libpng
# sources, and the downloaded tarballs.
#
# The REQUIRED assertion below matters more than the deletions: pruning too much
# is worse than not pruning, because a missing dep surfaces as an opaque linker
# error minutes into an Xcode Cloud archive rather than here.
set -euo pipefail

DEPS="${1:?usage: prune_ios_deps.sh <deps_ios dir>}"
[ -d "$DEPS" ] || { echo "ERROR: not a directory: $DEPS" >&2; exit 1; }

BEFORE="$(du -sh "$DEPS" | cut -f1)"

# --- drop intermediates -------------------------------------------------------
rm -rf "$DEPS"/build_freetype* "$DEPS"/build_libpng* "$DEPS"/build_python_ios
rm -rf "$DEPS"/freetype-* "$DEPS"/libpng-*
rm -f  "$DEPS"/*.tar.xz "$DEPS"/*.tar.gz

# --- assert the shipping set survived ----------------------------------------
REQUIRED=(
  "Python.xcframework/ios-arm64/Python.framework/Python"
  "Python.xcframework/ios-arm64/Python.framework/Headers"
  "Python.xcframework/ios-arm64/lib/python3.13"
  "Python.xcframework/ios-arm64/lib/python3.13/site-packages/Bio"
  "Python.xcframework/ios-arm64_x86_64-simulator/Python.framework/Python"
  "Python.xcframework/ios-arm64_x86_64-simulator/Python.framework/Headers"
  "Python.xcframework/ios-arm64_x86_64-simulator/lib/python3.13"
  "Python.xcframework/ios-arm64_x86_64-simulator/lib/python3.13/site-packages/Bio"
  "install/lib/libpng16.a"
  "install/lib/libfreetype.a"
  "install_device/lib/libpng16.a"
  "install_device/lib/libfreetype.a"
  "numpy-ios/simulator/numpy"
  "numpy-ios/device/numpy"
)

MISSING=0
for r in "${REQUIRED[@]}"; do
  [ -e "$DEPS/$r" ] || { echo "MISSING: $r" >&2; MISSING=1; }
done
[ "$MISSING" = 0 ] || {
  echo "ERROR: deps_ios is incomplete after pruning (see MISSING above)." >&2
  echo "       Either setup_ios_deps.sh did not finish, or this script's" >&2
  echo "       delete patterns are too broad. Do NOT publish this tree." >&2
  exit 1; }

echo "pruned OK: $BEFORE -> $(du -sh "$DEPS" | cut -f1)"
