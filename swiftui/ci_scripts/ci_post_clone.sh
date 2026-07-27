#!/bin/bash
# TEMPORARY Xcode Cloud validation spike — replaced by the real script in Task 8.
#
# Answers four questions that Apple's documentation leaves open, in one build:
#   1. Do files this script writes into the repository survive to later stages?
#   2. Does network egress work through the mandated $HTTP_PROXY?
#   3. Do `brew install cmake glm xcodegen` succeed with no sudo available?
#   4. How long does a full PyMOL iOS core build take on this hardware?
set -euo pipefail

cd "$CI_PRIMARY_REPOSITORY_PATH"

echo "== spike: environment =="
echo "  CI_PRIMARY_REPOSITORY_PATH = $CI_PRIMARY_REPOSITORY_PATH"
echo "  CI_BUILD_NUMBER            = ${CI_BUILD_NUMBER:-<unset>}"
echo "  CI_START_CONDITION         = ${CI_START_CONDITION:-<unset>}"
echo "  HTTPS_PROXY                = ${HTTPS_PROXY:-<unset>}"
echo "  sw_vers                    = $(sw_vers -productVersion)"
echo "  xcodebuild                 = $(xcodebuild -version | head -1)"
echo "  preinstalled cmake?        = $(command -v cmake || echo NO)"
echo "  preinstalled python3       = $(python3 --version 2>&1)"

echo "== spike: Q3 toolchain via Homebrew (no sudo) =="
# The COMPLETE set the iOS core build needs. Derived by reading
# appkit/CMakeLists.txt's iOS branch rather than by guessing:
#   cmake, xcodegen  - tools, neither preinstalled on Xcode Cloud
#   glm              - find_path(GLM_INCLUDE glm/glm.hpp HINTS $BREW/include)
#   libpng, freetype - PNG_INCLUDE_DIRS / FREETYPE_INCLUDE_DIRS are read straight
#                      from $BREW/include; only the .a LIBRARIES come from
#                      deps_ios/install_device. Build 3 reached 14% and then died
#                      on "'png.h' file not found" for exactly this reason.
# Deliberately NOT installed: GLEW, libxml2, libomp and netcdf are all inside
# `NOT PYMOL_IOS` guards in appkit/CMakeLists.txt, so the iOS build never looks
# for them.
brew install cmake glm xcodegen libpng freetype
export PYMOL_EXTERNAL_PREFIX="$(brew --prefix)"
echo "  PYMOL_EXTERNAL_PREFIX = $PYMOL_EXTERNAL_PREFIX"
echo "  glm header            = $(ls "$PYMOL_EXTERNAL_PREFIX/include/glm/glm.hpp")"

echo "== spike: Q2 network through the proxy =="
# Any small public asset. A GitHub release download is the exact path the real
# script will use to fetch the deps artifact.
curl -fsSL -o /tmp/spike-probe.txt \
  "https://raw.githubusercontent.com/javierbq/RayMol/master/README.md"
echo "  fetched $(wc -c < /tmp/spike-probe.txt) bytes from raw.githubusercontent.com"

echo "== spike: Q1 write markers into the repository =="
echo "post-clone build ${CI_BUILD_NUMBER:-?}" > SPIKE_MARKER.txt
mkdir -p spike_marker_dir && echo ok > spike_marker_dir/inside.txt
( cd swiftui && xcodegen generate )   # mutates the committed .xcodeproj
echo "  wrote SPIKE_MARKER.txt, spike_marker_dir/, and regenerated the project"

echo "== spike: fetch prebuilt deps_ios (build 2 failed without this) =="
# Build 2 skipped this and the core build died in contrib/champ with
# "'Python.h' file not found": with no deps_ios/Python.xcframework present,
# appkit/CMakeLists.txt takes its else() branch and points at
# $(brew --prefix)/opt/python@3.13/... which is not installed on Xcode Cloud.
# That is the silent-fallback hazard assert_ios_build_inputs.sh exists to catch.
# Fetch the real artifact, exactly as the production ci_post_clone.sh will.
FP="$(bash scripts/ios_deps_fingerprint.sh)"
TARBALL="deps_ios-$FP.tar.gz"
BASE="https://github.com/javierbq/RayMol/releases/download/ios-deps-$FP"
echo "  fingerprint=$FP"
curl -fL --retry 3 --retry-delay 5 -o "$TARBALL" "$BASE/$TARBALL"
curl -fL --retry 3 --retry-delay 5 -o "$TARBALL.sha256" "$BASE/$TARBALL.sha256"
shasum -a 256 -c "$TARBALL.sha256"
tar -xzf "$TARBALL"
rm -f "$TARBALL" "$TARBALL.sha256"
echo "  deps_ios staged: $(du -sh deps_ios | cut -f1)"

echo "== spike: Q4 time a full core build =="
START=$(date +%s)
bash swiftui/build_ios.sh device
echo "  CORE_BUILD_SECONDS=$(( $(date +%s) - START ))"
ls -la build_ios_device/libpymol_core.a
lipo -archs build_ios_device/libpymol_core.a

echo "== spike: assert build inputs (rehearses the production gate) =="
bash scripts/assert_ios_build_inputs.sh "$CI_PRIMARY_REPOSITORY_PATH"
