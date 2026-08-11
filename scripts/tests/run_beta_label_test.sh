#!/bin/bash
# Unit tests for scripts/beta_label.sh.
#
# The label is display text, not an identity Apple validates — but it is the ONLY
# thing that tells a TestFlight tester which build they are on, because betas
# share their marketing version with the release they were cut from. A label that
# is wrong, ambiguous, or silently empty makes every bug report from that build
# unattributable, so the failure cases below matter as much as the happy path.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/beta_label.sh"
FAILED=0

expect_ok () {  # $1=label $2=version $3=build $4=expected
  local got; got="$(bash "$SCRIPT" "$2" "$3" 2>/dev/null)"
  if [ "$got" = "$4" ]; then echo "  ok: $1"
  else echo "  FAIL: $1 — expected '$4', got '$got'"; FAILED=1; fi
}

expect_fail () {  # $1=label $2=version $3=build
  if bash "$SCRIPT" "$2" "$3" >/dev/null 2>&1; then
    echo "  FAIL: $1 — should have exited non-zero"; FAILED=1
  else echo "  ok: $1"; fi
}

echo "== beta_label =="

expect_ok "1.9.1 + 27"          "1.9.1"  "27"  "1.9.1-beta27"
expect_ok "double-digit minor"  "1.10.0" "34"  "1.10.0-beta34"
expect_ok "build 0"             "1.9.1"  "0"   "1.9.1-beta0"
expect_ok "large build number"  "2.0.0"  "1234" "2.0.0-beta1234"

# A malformed version must not reach a tester's screen. These are exactly the
# forms App Store Connect itself rejects for CFBundleShortVersionString, kept in
# lockstep with apply_ci_versions.sh's validation.
expect_fail "two-component version"   "1.9"        "27"
expect_fail "four-component version"  "1.9.0.1"    "27"
expect_fail "v-prefixed version"      "v1.9.1"     "27"
expect_fail "already-suffixed version" "1.9.1-beta" "27"
expect_fail "empty version"           ""           "27"

# Xcode Cloud build numbers are always non-negative integers; anything else means
# the caller passed the wrong variable.
expect_fail "non-numeric build"  "1.9.1" "abc"
expect_fail "negative build"     "1.9.1" "-1"
expect_fail "decimal build"      "1.9.1" "27.1"
expect_fail "empty build"        "1.9.1" ""

# No arguments at all must fail rather than emit a bare "-beta".
expect_fail "no arguments" "" ""

# Round-trip: the output must satisfy the pattern apply_ci_versions.sh enforces,
# or the two scripts disagree and the pipeline dies at the stamping step.
OUT="$(bash "$SCRIPT" "1.9.1" "27" 2>/dev/null)"
if [[ "$OUT" =~ ^[0-9]+\.[0-9]+\.[0-9]+-beta[0-9]+$ ]]; then
  echo "  ok: output satisfies apply_ci_versions.sh's label pattern"
else
  echo "  FAIL: '$OUT' would be rejected by apply_ci_versions.sh"; FAILED=1
fi

# The label must NOT be a valid marketing version — if it ever were, someone
# could pass it to apply_ci_versions.sh as the version and upload would fail.
if [[ "$OUT" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "  FAIL: '$OUT' looks like a marketing version"; FAILED=1
else
  echo "  ok: label is distinguishable from a marketing version"
fi

[ "$FAILED" = 0 ] && echo "PASS" || { echo "FAILURES"; exit 1; }
