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

# Core behaviour: bump the MINOR, zero the PATCH.
expect_ok "1.8.0 -> 1.9.0"   '"1.8.0"'  "1.9.0"
expect_ok "1.9.9 -> 1.10.0"  '"1.9.9"'  "1.10.0"
expect_ok "0.1.0 -> 0.2.0"   '"0.1.0"'  "0.2.0"
expect_ok "2.0.3 -> 2.1.0"   '"2.0.3"'  "2.1.0"
# Double-digit minors must not be mangled by string comparison.
expect_ok "1.10.0 -> 1.11.0" '"1.10.0"' "1.11.0"
# Unquoted YAML scalar is still valid YAML and must parse.
expect_ok "unquoted 1.8.0"   '1.8.0'    "1.9.0"

# Hard failures — guessing a version is unrecoverable in App Store Connect.
expect_fail "missing MARKETING_VERSION" ""
expect_fail "two-component version"     '"1.8"'
expect_fail "non-numeric version"       '"1.8.0-beta"'
expect_fail "empty version"             '""'

# A missing file is a failure, not an empty result.
if bash "$SCRIPT" "$TMP/does-not-exist.yml" >/dev/null 2>&1; then
  echo "  FAIL: missing file should exit non-zero"; FAILED=1
else echo "  ok: missing file exits non-zero"; fi

# Against the real repo (project.yml is at 1.8.0 today) the answer is 1.9.0,
# and with no argument it must default to swiftui/project.yml.
REAL="$(bash "$SCRIPT" 2>/dev/null)"
if [ "$REAL" = "1.9.0" ]; then echo "  ok: real repo → 1.9.0"
else echo "  FAIL: real repo → '$REAL' (expected 1.9.0; did project.yml move on?)"; FAILED=1; fi

rm -rf "$TMP"
[ "$FAILED" = 0 ] && echo "PASS" || { echo "FAILURES"; exit 1; }
