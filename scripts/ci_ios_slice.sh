#!/bin/bash
# ci_ios_slice.sh — print which iOS core the current Xcode Cloud action needs:
# `device`, `simulator` or `none`. swiftui/ci_scripts/ci_post_clone.sh dispatches
# on this for iOS actions.
#
# WHY IT IS NEEDED. Xcode Cloud's "iOS Beta (master)" workflow runs both Archive
# and Test actions. Archive builds the app for real devices (requires the
# arm64 device core at build_ios_device/libpymol_core.a). Test actions run in two
# phases: `build-for-testing` (compiles the app + test bundle for the simulator,
# requiring the simulator core at build_ios/libpymol_core.a) and
# `test-without-building` (runs the already-built products on a simulator, needing
# no core and no dependencies at all).
#
# SIGNALS:
#   CI_XCODEBUILD_ACTION  "archive" | "build" | "analyze" | "build-for-testing" |
#                         "test-without-building"
#   CI_XCODE_SCHEME       scheme of the current action (e.g. PyMOLViewer_iOS,
#                         LightsUITests_iOS, UITests_iOS)
#
# Rules:
#   1. CI_XCODEBUILD_ACTION = test-without-building -> none
#   2. CI_XCODEBUILD_ACTION = build-for-testing     -> simulator
#   3. CI_XCODEBUILD_ACTION = archive|build|analyze -> device
#   4. CI_XCODEBUILD_ACTION unset/empty:
#      Fall back on CI_XCODE_SCHEME (and log a warning note to stderr):
#        LightsUITests_iOS | UITests_iOS -> simulator
#        anything else (incl. unset)     -> device
#   5. Any other CI_XCODEBUILD_ACTION value: hard error on stderr, exit 1.
#
# Usage: ci_ios_slice.sh       (reads the environment; prints one word)
set -euo pipefail

A="${CI_XCODEBUILD_ACTION:-}"
S="${CI_XCODE_SCHEME:-}"

case "$A" in
  test-without-building)
    echo "none"
    ;;
  build-for-testing)
    echo "simulator"
    ;;
  archive|build|analyze)
    echo "device"
    ;;
  "")
    echo "NOTE: CI_XCODEBUILD_ACTION is unset; falling back to scheme '$S'" >&2
    case "$S" in
      LightsUITests_iOS|UITests_iOS)
        echo "simulator"
        ;;
      *)
        echo "device"
        ;;
    esac
    ;;
  *)
    echo "ERROR: unsupported CI_XCODEBUILD_ACTION='$A' (expected archive, build, analyze, build-for-testing, or test-without-building)" >&2
    exit 1
    ;;
esac
