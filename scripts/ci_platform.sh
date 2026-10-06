#!/bin/bash
# ci_platform.sh — print which platform the current Xcode Cloud action builds:
# `iOS` or `macOS`. swiftui/ci_scripts/ci_post_clone.sh dispatches on this.
#
# WHY IT IS NEEDED. Xcode Cloud recognises exactly ONE ci_scripts directory per
# repository, so the "iOS Beta (master)" and "macOS Beta (master)" workflows run
# the same ci_post_clone.sh, and it has to stage completely different inputs for
# each: deps_ios + a device core vs. deps_macos + a Metal-only macOS core with
# the Mac App Store project edits.
#
# SIGNALS, both listed by Apple as "always available" to custom build scripts:
#   CI_PRODUCT_PLATFORM  "iOS" | "macOS" | ...  the platform of the current action
#   CI_XCODE_SCHEME      the scheme the action uses (PyMOLViewer_iOS / _macOS)
# Either one is enough; when both are present they must agree.
#
# NEITHER PRESENT -> iOS, with a warning. Before the macOS workflow existed this
# hook was iOS-only and read neither variable, so defaulting keeps the one
# pipeline that is known to work exactly as it was. A macOS action that somehow
# lands here still fails loudly later: assert_ios_build_inputs.sh passes, but
# the archive of PyMOLViewer_macOS has no macOS core to link.
#
# ANYTHING ELSE (tvOS, an unknown scheme, a disagreement) is a hard error.
#
# Usage: ci_platform.sh        (reads the environment; prints one word)
set -euo pipefail

P="${CI_PRODUCT_PLATFORM:-}"
S="${CI_XCODE_SCHEME:-}"

from_platform=""
case "$P" in
  "")    ;;
  iOS)   from_platform=iOS ;;
  macOS) from_platform=macOS ;;
  *) echo "ERROR: unsupported CI_PRODUCT_PLATFORM='$P' (expected iOS or macOS)" >&2; exit 1 ;;
esac

from_scheme=""
case "$S" in
  "")                ;;
  PyMOLViewer_iOS)   from_scheme=iOS ;;
  PyMOLViewer_macOS) from_scheme=macOS ;;
  *) echo "ERROR: unsupported CI_XCODE_SCHEME='$S' (expected PyMOLViewer_iOS or PyMOLViewer_macOS)" >&2; exit 1 ;;
esac

if [ -n "$from_platform" ] && [ -n "$from_scheme" ] && [ "$from_platform" != "$from_scheme" ]; then
  echo "ERROR: CI_PRODUCT_PLATFORM='$P' disagrees with CI_XCODE_SCHEME='$S'" >&2
  exit 1
fi

if [ -n "$from_platform" ]; then echo "$from_platform"
elif [ -n "$from_scheme" ]; then echo "$from_scheme"
else
  echo "WARNING: neither CI_PRODUCT_PLATFORM nor CI_XCODE_SCHEME is set; assuming iOS" >&2
  echo iOS
fi
