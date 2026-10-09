#!/bin/bash
# ci_post_clone.sh — Xcode Cloud post-clone: stage everything xcodebuild needs
# that is not in the repository, then build the C++ core.
#
# Serves TWO workflows, because Apple runs this one script for every action:
#   iOS Beta (master)    PyMOLViewer_iOS   — deps_ios artifact + device core
#   macOS Beta (master)  PyMOLViewer_macOS — deps_macos + Metal-only core, and
#                        the project rewritten to its Mac App Store variant
#                        (no Sparkle, RAYMOL_MAS_RESTRICTED): TestFlight for Mac
#                        only accepts sandboxed App Store builds
# scripts/ci_platform.sh decides which. Steps marked [iOS] / [macOS] run for
# that platform only; everything else is shared.
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

PLATFORM="$(bash scripts/ci_platform.sh)"
echo "== platform: $PLATFORM (CI_PRODUCT_PLATFORM='${CI_PRODUCT_PLATFORM:-}' CI_XCODE_SCHEME='${CI_XCODE_SCHEME:-}') =="

echo "== 1/7  Allow the mlx-swift build-tool plugin =="
# Both platforms: Design mode links MPNNKit — and so mlx-swift — into the macOS
# slice too (see archive_appstore.sh, which needs the same switches locally).
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
#
# [macOS] adds libomp. The Metal-only core compiles OpenMP surface sampling
# (appkit/CMakeLists.txt PYMOL_OPENMP, finds omp.h under the prefix) and the
# app links $(PYMOL_EXTERNAL_PREFIX)/opt/libomp/lib/libomp.a STATICALLY
# (PyMOLBridge.xcconfig PYMOL_LIBOMP_STATIC). [macOS] does NOT install libpng
# or freetype: build_macos.sh (step 6) builds them from pinned sources as static
# archives (scripts/build_macos_deps.sh) and the app links those. Linking
# Homebrew's freetype dylib is what shipped 1.12.2 (212), which crashed at
# launch on a libbrotlicommon that Homebrew's freetype pulled in and the app
# did not carry. GLEW, libxml2 and netcdf stay out: the Metal-only build
# (PYMOL_METAL_ONLY, -DPYMOL_LIBXML=OFF) never looks for them either.
case "$PLATFORM" in
  iOS)   brew install cmake glm xcodegen libpng freetype ;;
  macOS) brew install cmake glm xcodegen libomp ;;
esac
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

if [ "$PLATFORM" = macOS ]; then
  # [macOS] The static OpenMP runtime is linked BY PATH (PYMOL_LIBOMP_STATIC),
  # derived from the prefix patched above. A missing archive is otherwise an
  # opaque "file not found" at the final link, ~20 minutes in.
  test -f "$PYMOL_EXTERNAL_PREFIX/opt/libomp/lib/libomp.a" \
    && echo "  libomp.a present under the patched prefix" \
    || { echo "ERROR: $PYMOL_EXTERNAL_PREFIX/opt/libomp/lib/libomp.a missing" >&2; exit 1; }
fi

DEPS_ID=""
if [ "$PLATFORM" = iOS ]; then
echo "== 3/7  [iOS] Fetch prebuilt deps_ios =="
FP="$(bash scripts/ios_deps_fingerprint.sh)"
DEPS_ID="deps fingerprint $FP"
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
else
echo "== 3/7  [macOS] Stage deps_macos (standalone Python + numpy + Biopython) =="
# Unlike deps_ios there is no prebuilt artifact to fetch: the macOS tree is a
# relocatable python-build-standalone download plus two pinned wheels, all
# fetched from their upstreams in about a minute. setup_macos_deps.sh imports
# both packages through the embedded interpreter before returning, so a broken
# tree stops here rather than in the app's Python bundling phase.
bash scripts/setup_macos_deps.sh
DEPS_ID="deps_macos staged"
fi

echo "== 4/7  Stamp marketing version + build number =="
# nightly_version.sh emits the next PATCH after project.yml's version, so betas
# ride a version that has never been approved. They must: App Store Connect
# closes a version's pre-release train permanently once it ships, and uploading
# under the live 1.9.1 came back ITMS-90186 "train version '1.9.1' is closed" and
# ITMS-90062 "must contain a higher version than the previously approved".
# The marketing version is still STABLE across betas — every one rides the same
# 1.9.2 until a release claims it; only CI_BUILD_NUMBER moves. BETA_LABEL is the
# human-readable half of the same identity ("1.9.2-beta29") for the Settings
# pane; Apple only ever sees the numeric pair, which is why the label cannot be
# the marketing version.
MKT="$(bash scripts/nightly_version.sh)"
BETA_LABEL="$(bash scripts/beta_label.sh "$MKT" "$CI_BUILD_NUMBER")"
echo "  version=$MKT build=$CI_BUILD_NUMBER label=$BETA_LABEL"
# apply_ci_versions.sh must run before xcodegen (step 5): xcodegen propagates
# MARKETING_VERSION, CURRENT_PROJECT_VERSION and RAYMOL_BETA_LABEL from
# project.yml into the generated .pbxproj.
bash scripts/apply_ci_versions.sh swiftui/project.yml "$MKT" "$CI_BUILD_NUMBER" "$BETA_LABEL"
# [macOS] One extra constraint the iOS side does not have: a Mac app's build
# number must increase across ALL versions, not just within one (Apple,
# "Setting the next build number for Xcode Cloud builds"). Xcode Cloud stamps
# its own CI_BUILD_NUMBER into every build it distributes regardless — the
# export options carry "buildNumber" — so once a macOS beta ships as e.g. 190,
# the next Mac App Store release must be numbered above 190 too. The
# cut-mas-release and cut-macos-release skills read the highest macOS build
# from App Store Connect for exactly this reason.

if [ "$PLATFORM" = macOS ]; then
  echo "== 4b/7 [macOS] Rewrite project.yml as the Mac App Store variant =="
  # TestFlight for Mac only takes sandboxed App Store builds: Sparkle out (its
  # helpers fail sandbox validation, error 90296), RAYMOL_MAS_RESTRICTED in.
  # Xcode Cloud runs its own `xcodebuild archive`, so the compilation condition
  # cannot be passed on a command line the way archive_appstore.sh passes it;
  # it has to be in the generated project. Must precede xcodegen (step 5).
  #
  # Dropping the Sparkle package also changes the package graph from what the
  # committed Package.resolved was made for. That is fine: the strict
  # `xcodebuild -resolvePackageDependencies -disableAutomaticPackageResolution
  # -onlyUsePackageVersionsFromResolvedFile` resolve was verified against
  # exactly this edit — an unused pin is ignored, every remaining package keeps
  # its pinned version.
  bash scripts/apply_mas_restrictions.sh swiftui/project.yml
fi

echo "== 5/7  Regenerate the Xcode project =="
# project.yml is the source of truth and the committed .pbxproj can lag it —
# skipping this is how PR #124's app-icon setting was once silently reverted.
# It is also what picks up the version stamp from step 4.
( cd swiftui && xcodegen generate )

if [ "$PLATFORM" = iOS ]; then
  echo "== 6/7  [iOS] Build libpymol_core.a (device) =="
  bash swiftui/build_ios.sh device

  echo "== 7/7  [iOS] Assert build inputs before xcodebuild =="
  bash scripts/assert_ios_build_inputs.sh "$CI_PRIMARY_REPOSITORY_PATH"
else
  echo "== 6/7  [macOS] Build libpymol_core.a (Metal-only, arm64) =="
  # CLEAN=1 is what make_dmg.sh and the Mac App Store recipe use: an incremental
  # core can carry a stale setting default (1.6.1's metal_outline). A fresh
  # checkout has nothing to be stale against, but say so explicitly rather than
  # depend on it. PYMOL_EXTERNAL_PREFIX is exported from step 2.
  CLEAN=1 bash swiftui/build_macos.sh

  echo "== 7/7  [macOS] Assert build inputs before xcodebuild =="
  bash scripts/assert_macos_build_inputs.sh "$CI_PRIMARY_REPOSITORY_PATH"
fi

echo "ci_post_clone OK — $PLATFORM $MKT ($CI_BUILD_NUMBER), $DEPS_ID"
