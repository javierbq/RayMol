#!/bin/bash
# Unit tests for scripts/ci_platform.sh — the switch that decides whether
# ci_post_clone.sh stages an iOS or a macOS build. Getting it wrong either way
# costs a full Xcode Cloud run, so every combination of the two signals is
# pinned here.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/ci_platform.sh"
FAILED=0

# expect <want|ERROR> <CI_PRODUCT_PLATFORM> <CI_XCODE_SCHEME>
expect () {
  local want="$1" plat="$2" scheme="$3" got rc
  got="$(env -u CI_PRODUCT_PLATFORM -u CI_XCODE_SCHEME \
           ${plat:+CI_PRODUCT_PLATFORM="$plat"} ${scheme:+CI_XCODE_SCHEME="$scheme"} \
           bash "$SCRIPT" 2>/dev/null)"; rc=$?
  local label="platform='$plat' scheme='$scheme'"
  if [ "$want" = ERROR ]; then
    if [ "$rc" -ne 0 ]; then echo "  ok: $label -> error"
    else echo "  FAIL: $label should error, printed '$got'"; FAILED=1; fi
  else
    if [ "$rc" -eq 0 ] && [ "$got" = "$want" ]; then echo "  ok: $label -> $want"
    else echo "  FAIL: $label -> '$got' (rc=$rc), want $want"; FAILED=1; fi
  fi
}

echo "== ci_platform =="
expect macOS macOS ""
expect macOS ""    PyMOLViewer_macOS
expect macOS macOS PyMOLViewer_macOS
expect iOS   iOS   ""
expect iOS   ""    PyMOLViewer_iOS
expect iOS   iOS   PyMOLViewer_iOS
# Neither signal: the historic iOS-only behaviour, so the working pipeline is
# never broken by Apple leaving these unset in post-clone.
expect iOS   ""    ""
# Disagreement and unknown values are hard errors, never a guess.
expect ERROR macOS PyMOLViewer_iOS
expect ERROR iOS   PyMOLViewer_macOS
expect ERROR tvOS  ""
expect ERROR ""    SomeOtherScheme

# The no-signal default must say so on stderr — a silent guess is how a macOS
# workflow would end up quietly staging iOS inputs.
ERR="$(env -u CI_PRODUCT_PLATFORM -u CI_XCODE_SCHEME bash "$SCRIPT" 2>&1 >/dev/null)"
if grep -q WARNING <<<"$ERR"; then echo "  ok: default warns on stderr"
else echo "  FAIL: no warning when defaulting to iOS"; FAILED=1; fi

[ "$FAILED" = 0 ] && echo "PASS" || { echo "FAILURES"; exit 1; }
