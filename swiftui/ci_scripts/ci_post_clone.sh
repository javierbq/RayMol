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

echo "== 1/7  Allow the mlx-swift build-tool plugin =="
# mlx-swift's Cmlx target carries a `CudaBuild` .buildTool() plugin. Xcode
# fingerprints package plugins and refuses to run one that has not been trusted;
# in the IDE that trust is a dialog, and there is no dialog on Xcode Cloud. The
# archive action just dies with
#     Plugin "CudaBuild" from package "mlx-swift" must be enabled before it can be used
# which is what broke every iOS Beta build from #22 (the #217 Phase 2d merge that
# linked mlx-swift into the iOS target) onward.
#
# Locally and in swiftui/archive_appstore.sh the cure is
# `-skipPackagePluginValidation -skipMacroValidation` on our own xcodebuild call.
# That is NOT available here: Xcode Cloud runs its own `xcodebuild archive` for
# the Archive - iOS action and gives us no way to add flags to it. The defaults
# below are the same switches at the preference layer, so they apply to a
# xcodebuild we never invoke. ci_post_clone.sh runs before that action, which is
# the whole reason this belongs here and not in a build script.
#
# DO NOT "fix" the spelling of IDESkipPackagePluginFingerprintValidatation. The
# doubled "at" is Apple's own typo — the string is verbatim what ships inside
# Xcode's IDEFoundation and SwiftPM frameworks, and the corrected spelling reads
# as an unset key, silently restoring the failure. scripts/tests/
# run_ci_post_clone_plugin_trust_test.sh pins both names against exactly that.
defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidatation -bool YES
defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES
# Read the values back. `defaults write` to an unwritable domain still exits 0,
# and a silent no-op here fails ~20 minutes later inside an xcodebuild whose
# flags we do not control — the same discipline the xcconfig patch in step 2
# follows, for the same reason.
for KEY in IDESkipPackagePluginFingerprintValidatation IDESkipMacroFingerprintValidation; do
  VAL="$(defaults read com.apple.dt.Xcode "$KEY" 2>/dev/null || echo MISSING)"
  [ "$VAL" = "1" ] || {
    echo "ERROR: $KEY did not stick (read back '$VAL')." >&2
    echo "       Xcode Cloud's archive action will fail plugin validation." >&2
    exit 1; }
  echo "  $KEY=1"
done

echo "== 2/7  Toolchain =="
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
# step 4.
sed -i '' "s|^PYMOL_EXTERNAL_PREFIX = .*|PYMOL_EXTERNAL_PREFIX = $PYMOL_EXTERNAL_PREFIX|" \
  swiftui/PyMOLBridge.xcconfig
# `sed` exits 0 whether or not the pattern matched. Verify the substitution
# applied before we discover the failure deep inside xcodebuild with the same
# 'glm/vec3.hpp' file not found symptom that cost us build 4. This is the same
# discipline apply_ci_versions.sh follows: "a silent no-op here ships the wrong
# version" — here, a silent no-op ships /opt/homebrew to a machine that has none.
grep -q "^PYMOL_EXTERNAL_PREFIX = $PYMOL_EXTERNAL_PREFIX$" swiftui/PyMOLBridge.xcconfig || {
  echo "ERROR: the PYMOL_EXTERNAL_PREFIX patch did not apply to swiftui/PyMOLBridge.xcconfig." >&2
  echo "       Its line 22 format probably changed; the sed pattern needs updating." >&2
  exit 1; }
test -f "$PYMOL_EXTERNAL_PREFIX/include/glm/vec3.hpp" \
  && echo "  glm/vec3.hpp present under the patched prefix" \
  || { echo "ERROR: glm/vec3.hpp missing under $PYMOL_EXTERNAL_PREFIX/include" >&2; exit 1; }

echo "== 3/7  Fetch prebuilt deps_ios =="
FP="$(bash scripts/ios_deps_fingerprint.sh)"
TARBALL="deps_ios-$FP.tar.gz"
BASE="https://github.com/$REPO/releases/download/ios-deps-$FP"
echo "  fingerprint=$FP"
# Build 2 skipped this step: appkit/CMakeLists.txt silently fell back to an
# uninstalled $(brew --prefix)/opt/python@3.13/... and died in contrib/champ
# with "'Python.h' file not found". deps_ios MUST be staged before the core
# build in step 6.
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

echo "== 4/7  Stamp marketing version + build number =="
# nightly_version.sh emits project.yml's CURRENT version verbatim — betas ride
# the released version and are told apart by CI_BUILD_NUMBER, so no unreleased
# version number is claimed in App Store Connect (where it could never be
# reclaimed). BETA_LABEL is the human-readable half of the same identity, for the
# Settings pane; Apple only sees the numeric pair.
MKT="$(bash scripts/nightly_version.sh)"
BETA_LABEL="$(bash scripts/beta_label.sh "$MKT" "$CI_BUILD_NUMBER")"
echo "  version=$MKT build=$CI_BUILD_NUMBER label=$BETA_LABEL"
# apply_ci_versions.sh must run before xcodegen (step 5): xcodegen propagates
# MARKETING_VERSION, CURRENT_PROJECT_VERSION and RAYMOL_BETA_LABEL from
# project.yml into the generated .pbxproj.
bash scripts/apply_ci_versions.sh swiftui/project.yml "$MKT" "$CI_BUILD_NUMBER" "$BETA_LABEL"

echo "== 5/7  Regenerate the Xcode project =="
# project.yml is the source of truth and the committed .pbxproj can lag it —
# skipping this is how PR #124's app-icon setting was once silently reverted.
# It is also what picks up the version stamp from step 4.
( cd swiftui && xcodegen generate )

echo "== 6/7  Build libpymol_core.a (device) =="
bash swiftui/build_ios.sh device

echo "== 7/7  Assert build inputs before xcodebuild =="
bash scripts/assert_ios_build_inputs.sh "$CI_PRIMARY_REPOSITORY_PATH"

echo "ci_post_clone OK — $MKT ($CI_BUILD_NUMBER), deps fingerprint $FP"
