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

# Core behaviour: emit the next PATCH after project.yml's version.
#
# READ THIS BEFORE "FIXING" IT BACK. This suite has now asserted three different
# things, and the history matters because two of them were wrong:
#   1. next MINOR (1.9.1 -> 1.10.0). Over-claimed: stranded a TestFlight 1.10.0
#      above a live 1.8.0 for a release nobody had decided on.
#   2. VERBATIM (1.9.1 -> 1.9.1), to claim nothing at all. Apple rejects this
#      outright once the version ships — iOS 1.9.1 went READY_FOR_SALE and the
#      next upload came back ITMS-90186 "the train version '1.9.1' is closed for
#      new build submissions" plus ITMS-90062 "must contain a higher version
#      than the previously approved version".
#   3. next PATCH (1.9.1 -> 1.9.2), below. The smallest claim Apple permits.
# So "do not bump" is not a safer choice here; it is a rejected upload. A beta
# MUST sit on a version that has never been approved.
expect_ok "1.8.0 -> 1.8.1"   '"1.8.0"'  "1.8.1"
expect_ok "1.9.1 -> 1.9.2"   '"1.9.1"'  "1.9.2"
expect_ok "0.1.0 -> 0.1.1"   '"0.1.0"'  "0.1.1"
# Integer arithmetic, not string: the patch must roll 9 -> 10, never "1.9.91".
expect_ok "1.9.9 -> 1.9.10"  '"1.9.9"'  "1.9.10"
# Double-digit minors must survive untouched while only the patch moves.
expect_ok "1.10.0 -> 1.10.1" '"1.10.0"' "1.10.1"
# Unquoted YAML scalar is still valid YAML and must parse.
expect_ok "unquoted 1.8.0"   '1.8.0'    "1.8.1"

# Pin both halves of the contract: the output must differ from the input (or the
# upload is rejected), and it must exceed it by exactly ONE patch (or we are
# over-claiming versions again, which is how scheme 1 stranded 1.10.0).
for v in "1.8.0" "1.9.1" "1.10.0" "2.0.3"; do
  got="$(bash "$SCRIPT" "$(fixture "\"$v\"")" 2>/dev/null)"
  want="${v%.*}.$(( ${v##*.} + 1 ))"     # computed here, independently of the script
  if [ "$got" = "$v" ]; then
    echo "  FAIL: $v unchanged — an approved version's train is closed (ITMS-90186)"; FAILED=1
  elif [ "$got" != "$want" ]; then
    echo "  FAIL: $v -> '$got', expected exactly one patch up ('$want')"; FAILED=1
  else
    echo "  ok: $v -> $got (exactly one patch)"
  fi
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
# The expectation is read out of the file with an independent sed and bumped
# with independent arithmetic — never by calling the script — so this stays
# non-circular, and it stays correct across every future release bump rather
# than pinning a literal that goes stale the next time a version ships.
REAL_YML="$ROOT/swiftui/project.yml"
DECLARED="$(sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([0-9]+\.[0-9]+\.[0-9]+)"?[[:space:]]*$/\1/p' \
             "$REAL_YML" | head -1)"
WANT="${DECLARED%.*}.$(( ${DECLARED##*.} + 1 ))"
if REAL="$(bash "$SCRIPT" 2>/dev/null)" && [ -n "$DECLARED" ] && [ "$REAL" = "$WANT" ]; then
  echo "  ok: real repo → $REAL (one patch above project.yml's $DECLARED)"
else
  echo "  FAIL: real repo gave '$REAL', expected '$WANT' (project.yml declares '$DECLARED')"; FAILED=1
fi

rm -rf "$TMP"
[ "$FAILED" = 0 ] && echo "PASS" || { echo "FAILURES"; exit 1; }
