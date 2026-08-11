#!/bin/bash
# Unit tests for scripts/nightly_version.sh.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/nightly_version.sh"
FAILED=0
TMP="$(mktemp -d)"

# Write a project.yml fixture containing $1 as the MARKETING_VERSION line body.
# Indented to 8 spaces to match the real file's nesting under settings:.
fixture () {
  local file="$TMP/p$RANDOM.yml"
  {
    echo "settings:"
    echo "  base:"
    echo "        PRODUCT_NAME: RayMol"
    [ -n "$1" ] && echo "        MARKETING_VERSION: $1"
    echo "        CURRENT_PROJECT_VERSION: 23"
  } > "$file"
  echo "$file"
}

expect_ok () {  # $1=label $2=version-literal $3=expected output
  local got; got="$(bash "$SCRIPT" "$(fixture "$2")" 2>/dev/null)"
  if [ "$got" = "$3" ]; then echo "  ok: $1"
  else echo "  FAIL: $1 — expected '$3', got '$got'"; FAILED=1; fi
}

expect_fail () {  # $1=label $2=version-literal (may be empty)
  if bash "$SCRIPT" "$(fixture "$2")" >/dev/null 2>&1; then
    echo "  FAIL: $1 — should have exited non-zero"; FAILED=1
  else echo "  ok: $1"; fi
}

echo "== nightly_version =="

# Core behaviour: emit project.yml's version VERBATIM — no bump.
#
# This is the assertion that matters, and it is the inverse of what this suite
# asserted before 2026-08-10. Bumping to the next minor pre-claimed a version in
# App Store Connect that could never be released or reclaimed (the iOS app ended
# up with a TestFlight 1.10.0 above a live 1.8.0). Betas are now told apart by
# build number, so a bump reintroduced here is a regression, not a refinement.
expect_ok "1.8.0 stays 1.8.0"   '"1.8.0"'  "1.8.0"
expect_ok "1.9.1 stays 1.9.1"   '"1.9.1"'  "1.9.1"
expect_ok "1.9.9 stays 1.9.9"   '"1.9.9"'  "1.9.9"
expect_ok "0.1.0 stays 0.1.0"   '"0.1.0"'  "0.1.0"
# Double-digit minors must survive verbatim (no numeric round-trip mangling).
expect_ok "1.10.0 stays 1.10.0" '"1.10.0"' "1.10.0"
# Unquoted YAML scalar is still valid YAML and must parse.
expect_ok "unquoted 1.8.0"      '1.8.0'    "1.8.0"

# Explicitly pin the anti-regression: the output must NEVER exceed the input.
for v in "1.8.0" "1.9.1" "1.10.0" "2.0.3"; do
  got="$(bash "$SCRIPT" "$(fixture "\"$v\"")" 2>/dev/null)"
  if [ "$got" = "$v" ]; then echo "  ok: $v not bumped"
  else echo "  FAIL: $v was rewritten to '$got' — betas must not claim a new version"; FAILED=1; fi
done

# Hard failures — guessing a version is unrecoverable in App Store Connect.
expect_fail "missing MARKETING_VERSION" ""
expect_fail "two-component version"     '"1.8"'
expect_fail "non-numeric version"       '"1.8.0-beta"'
expect_fail "empty version"             '""'

# A missing file is a failure, not an empty result.
if bash "$SCRIPT" "$TMP/does-not-exist.yml" >/dev/null 2>&1; then
  echo "  FAIL: missing file should exit non-zero"; FAILED=1
else echo "  ok: missing file exits non-zero"; fi

# Smoke-test the real repo file: with no argument the script must default to
# swiftui/project.yml and exit 0.
#
# This now asserts the value directly, which the old bump-based version could
# not: the answer is "whatever project.yml declares" rather than arithmetic on
# it, and that equality IS the contract. Reading the expectation out of the file
# with an independent sed (not by calling the script) keeps it non-circular, and
# it stays correct across every future release bump.
REAL_YML="$ROOT/swiftui/project.yml"
DECLARED="$(sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([0-9]+\.[0-9]+\.[0-9]+)"?[[:space:]]*$/\1/p' \
             "$REAL_YML" | head -1)"
if REAL="$(bash "$SCRIPT" 2>/dev/null)" && [ -n "$DECLARED" ] && [ "$REAL" = "$DECLARED" ]; then
  echo "  ok: real repo → $REAL (matches project.yml verbatim)"
else
  echo "  FAIL: real repo gave '$REAL', project.yml declares '$DECLARED'"; FAILED=1
fi

rm -rf "$TMP"
[ "$FAILED" = 0 ] && echo "PASS" || { echo "FAILURES"; exit 1; }
