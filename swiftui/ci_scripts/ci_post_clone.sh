#!/bin/bash
# ci_post_clone.sh — Xcode Cloud post-clone: stage everything xcodebuild needs
# that is not in the repository, then build the C++ core.
#
# Apple's environment, all of which this script depends on:
#   * runs with swiftui/ci_scripts as the working directory, so we cd to the repo
#   * NO sudo is available — Homebrew is preinstalled and needs none
#   * network egress goes through $HTTP_PROXY/$HTTPS_PROXY (curl honours them)
#   * only ONE ci_scripts directory is recognised per repo, and it must sit
#     beside the .xcodeproj — hence swiftui/ci_scripts/
#   * CI_PRIMARY_REPOSITORY_PATH = /Volumes/workspace/repository
#   * CI_BUILD_NUMBER is a monotonic integer assigned by Xcode Cloud
#
# `set -u` deliberately makes this fail fast outside Xcode Cloud, where
# CI_PRIMARY_REPOSITORY_PATH and CI_BUILD_NUMBER are unset.
set -euo pipefail

cd "$CI_PRIMARY_REPOSITORY_PATH"

REPO="javierbq/RayMol"

echo "== 1/6  Toolchain =="
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
# Read the prefix rather than trusting /opt/homebrew: Xcode Cloud runs at
# /usr/local. Hardcoding /opt/homebrew here would be the same mistake line 22
# of PyMOLBridge.xcconfig made before the sed patch below.
export PYMOL_EXTERNAL_PREFIX="$(brew --prefix)"
echo "  PYMOL_EXTERNAL_PREFIX=$PYMOL_EXTERNAL_PREFIX"

# TWO places need the Homebrew prefix, not one:
#   - The CMake core build reads PYMOL_EXTERNAL_PREFIX from the env var above.
#   - swiftui/PyMOLBridge.xcconfig line 22 hardcodes
#       PYMOL_EXTERNAL_PREFIX = /opt/homebrew
#     and feeds it to every compile unit via "-I$(PYMOL_EXTERNAL_PREFIX)/include"
#     (line 44). On Xcode Cloud the prefix is /usr/local, so that path is absent.
# Build 4 failed with 'glm/vec3.hpp' file not found for exactly this reason.
# Patch the ephemeral checkout in place — same treatment project.yml gets in
# step 3.
sed -i '' "s|^PYMOL_EXTERNAL_PREFIX = .*|PYMOL_EXTERNAL_PREFIX = $PYMOL_EXTERNAL_PREFIX|" \
  swiftui/PyMOLBridge.xcconfig
test -f "$PYMOL_EXTERNAL_PREFIX/include/glm/vec3.hpp" \
  && echo "  glm/vec3.hpp present under the patched prefix" \
  || { echo "ERROR: glm/vec3.hpp missing under $PYMOL_EXTERNAL_PREFIX/include" >&2; exit 1; }

echo "== 2/6  Fetch prebuilt deps_ios =="
FP="$(bash scripts/ios_deps_fingerprint.sh)"
TARBALL="deps_ios-$FP.tar.gz"
BASE="https://github.com/$REPO/releases/download/ios-deps-$FP"
echo "  fingerprint=$FP"
# Build 2 skipped this step: appkit/CMakeLists.txt silently fell back to an
# uninstalled $(brew --prefix)/opt/python@3.13/... and died in contrib/champ
# with "'Python.h' file not found". deps_ios MUST be staged before the core
# build in step 5.
#
# Fail loudly when the artifact is absent. NEVER fall back to building deps
# inline, and never accept a different fingerprint: today's core linked against
# yesterday's numpy is exactly the stale-artifact class of bug that make_dmg.sh
# grew its staleness assertions to prevent.
curl -fL --retry 3 --retry-delay 5 -o "$TARBALL" "$BASE/$TARBALL" || {
  echo "ERROR: no published deps artifact for fingerprint $FP." >&2
  echo "       Run the 'iOS deps artifact' GitHub Actions workflow on master," >&2
  echo "       then re-run this build. Refusing to build deps inline." >&2
  exit 1; }
curl -fL --retry 3 --retry-delay 5 -o "$TARBALL.sha256" "$BASE/$TARBALL.sha256"
shasum -a 256 -c "$TARBALL.sha256"
tar -xzf "$TARBALL"
rm -f "$TARBALL" "$TARBALL.sha256"

echo "== 3/6  Stamp marketing version + build number =="
MKT="$(bash scripts/nightly_version.sh)"
# apply_ci_versions.sh must run before xcodegen (step 4): xcodegen propagates
# MARKETING_VERSION and CURRENT_PROJECT_VERSION from project.yml into the
# generated .pbxproj.
bash scripts/apply_ci_versions.sh swiftui/project.yml "$MKT" "$CI_BUILD_NUMBER"

echo "== 4/6  Regenerate the Xcode project =="
# project.yml is the source of truth and the committed .pbxproj can lag it —
# skipping this is how PR #124's app-icon setting was once silently reverted.
# It is also what picks up the version stamp from step 3.
( cd swiftui && xcodegen generate )

echo "== 5/6  Build libpymol_core.a (device) =="
bash swiftui/build_ios.sh device

echo "== 6/6  Assert build inputs before xcodebuild =="
bash scripts/assert_ios_build_inputs.sh "$CI_PRIMARY_REPOSITORY_PATH"

echo "ci_post_clone OK — $MKT ($CI_BUILD_NUMBER), deps fingerprint $FP"
