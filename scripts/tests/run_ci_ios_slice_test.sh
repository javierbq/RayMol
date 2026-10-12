#!/bin/bash
# Unit tests for scripts/ci_ios_slice.sh — prints device, simulator or none.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/ci_ios_slice.sh"
FAILED=0

# expect <want|ERROR> <CI_XCODEBUILD_ACTION> <CI_XCODE_SCHEME>
expect () {
  local want="$1" act="$2" scheme="$3" got rc
  got="$(env -u CI_XCODEBUILD_ACTION -u CI_XCODE_SCHEME \
           ${act:+CI_XCODEBUILD_ACTION="$act"} ${scheme:+CI_XCODE_SCHEME="$scheme"} \
           bash "$SCRIPT" 2>/dev/null)"; rc=$?
  local label="action='$act' scheme='$scheme'"
  if [ "$want" = ERROR ]; then
    if [ "$rc" -ne 0 ]; then echo "  ok: $label -> error"
    else echo "  FAIL: $label should error, printed '$got'"; FAILED=1; fi
  else
    if [ "$rc" -eq 0 ] && [ "$got" = "$want" ]; then echo "  ok: $label -> $want"
    else echo "  FAIL: $label -> '$got' (rc=$rc), want $want"; FAILED=1; fi
  fi
}

echo "== ci_ios_slice =="
# 1. test-without-building -> none
expect none test-without-building ""
expect none test-without-building PyMOLViewer_iOS
expect none test-without-building LightsUITests_iOS

# 2. build-for-testing -> simulator
expect simulator build-for-testing ""
expect simulator build-for-testing PyMOLViewer_iOS
expect simulator build-for-testing LightsUITests_iOS

# 3. archive, build, analyze -> device
expect device archive PyMOLViewer_iOS
expect device build   PyMOLViewer_iOS
expect device analyze PyMOLViewer_iOS
expect device archive LightsUITests_iOS

# 4. unset CI_XCODEBUILD_ACTION -> fallback to scheme
expect device    "" ""
expect device    "" PyMOLViewer_iOS
expect simulator "" LightsUITests_iOS
expect simulator "" UITests_iOS
expect device    "" SomeOtherScheme

# 5. Invalid / unsupported action values -> ERROR
expect ERROR bogus ""
expect ERROR bogus PyMOLViewer_iOS
expect ERROR test  ""

# Check stderr warning when falling back on scheme
ERR="$(env -u CI_XCODEBUILD_ACTION -u CI_XCODE_SCHEME CI_XCODE_SCHEME="LightsUITests_iOS" bash "$SCRIPT" 2>&1 >/dev/null)"
if grep -q "NOTE: CI_XCODEBUILD_ACTION is unset" <<<"$ERR"; then
  echo "  ok: note printed to stderr when action is unset"
else
  echo "  FAIL: missing note on stderr when action is unset; got: $ERR"; FAILED=1
fi

[ "$FAILED" = 0 ] && echo "PASS" || { echo "FAILURES"; exit 1; }
