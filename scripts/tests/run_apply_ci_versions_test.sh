#!/bin/bash
# Unit tests for scripts/apply_ci_versions.sh.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/apply_ci_versions.sh"
FAILED=0
TMP="$(mktemp -d)"

# Mirror the real project.yml's shape: 8-space indent under settings: base:.
fixture () {
  local f="$TMP/p$RANDOM.yml"
  {
    echo "settings:"
    echo "  base:"
    echo "        PRODUCT_NAME: RayMol"
    echo "        MARKETING_VERSION: \"1.8.0\""
    echo "        CURRENT_PROJECT_VERSION: 23"
    echo "        GENERATE_INFOPLIST_FILE: YES"
  } > "$f"
  echo "$f"
}

echo "== apply_ci_versions =="

F="$(fixture)"
if bash "$SCRIPT" "$F" "1.9.0" "47" >/dev/null 2>&1; then
  echo "  ok: valid input succeeds"
else
  echo "  FAIL: valid input should succeed"; FAILED=1
fi

if grep -qE '^        MARKETING_VERSION: "1\.9\.0"$' "$F"; then
  echo "  ok: MARKETING_VERSION rewritten"
else echo "  FAIL: MARKETING_VERSION not rewritten"; FAILED=1; fi

if grep -qE '^        CURRENT_PROJECT_VERSION: 47$' "$F"; then
  echo "  ok: CURRENT_PROJECT_VERSION rewritten"
else echo "  FAIL: CURRENT_PROJECT_VERSION not rewritten"; FAILED=1; fi

# Indentation must be preserved — xcodegen would reject a re-indented file.
if grep -qE '^        PRODUCT_NAME: RayMol$' "$F"; then
  echo "  ok: surrounding lines and indentation untouched"
else echo "  FAIL: clobbered surrounding lines"; FAILED=1; fi

# Exactly one of each key (no duplicate lines appended).
[ "$(grep -c 'MARKETING_VERSION:' "$F")" = 1 ] \
  && echo "  ok: single MARKETING_VERSION line" \
  || { echo "  FAIL: duplicate MARKETING_VERSION lines"; FAILED=1; }

# Idempotent: re-applying the same values is a no-op success.
if bash "$SCRIPT" "$F" "1.9.0" "47" >/dev/null 2>&1; then
  echo "  ok: idempotent"
else echo "  FAIL: second identical application failed"; FAILED=1; fi

# Validation. A bad version must never reach App Store Connect.
for bad in "1.9" "1.9.0-beta" "v1.9.0" "" "1.9.0.1"; do
  if bash "$SCRIPT" "$(fixture)" "$bad" "47" >/dev/null 2>&1; then
    echo "  FAIL: accepted bad marketing version '$bad'"; FAILED=1
  else echo "  ok: rejects marketing version '$bad'"; fi
done

for bad in "abc" "4.7" "-1" ""; do
  if bash "$SCRIPT" "$(fixture)" "1.9.0" "$bad" >/dev/null 2>&1; then
    echo "  FAIL: accepted bad build number '$bad'"; FAILED=1
  else echo "  ok: rejects build number '$bad'"; fi
done

if bash "$SCRIPT" "$TMP/absent.yml" "1.9.0" "47" >/dev/null 2>&1; then
  echo "  FAIL: missing file should exit non-zero"; FAILED=1
else echo "  ok: missing file exits non-zero"; fi

# A project.yml with no such keys must FAIL, not silently succeed — that would
# ship a duplicate (version, build) pair and the upload would be rejected.
NOKEYS="$TMP/nokeys.yml"; printf 'settings:\n  base:\n        PRODUCT_NAME: RayMol\n' > "$NOKEYS"
if bash "$SCRIPT" "$NOKEYS" "1.9.0" "47" >/dev/null 2>&1; then
  echo "  FAIL: succeeded on a project.yml with neither key"; FAILED=1
else echo "  ok: fails when the keys are absent"; fi

# Single-key-absent: only MARKETING_VERSION missing.
NO_MKT="$TMP/no_mkt.yml"
printf 'settings:\n  base:\n        PRODUCT_NAME: RayMol\n        CURRENT_PROJECT_VERSION: 23\n' > "$NO_MKT"
if bash "$SCRIPT" "$NO_MKT" "1.9.0" "47" >/dev/null 2>&1; then
  echo "  FAIL: succeeded with MARKETING_VERSION absent"; FAILED=1
else echo "  ok: fails when MARKETING_VERSION is absent"; fi

# Single-key-absent: only CURRENT_PROJECT_VERSION missing.
NO_CPV="$TMP/no_cpv.yml"
printf 'settings:\n  base:\n        PRODUCT_NAME: RayMol\n        MARKETING_VERSION: "1.8.0"\n' > "$NO_CPV"
if bash "$SCRIPT" "$NO_CPV" "1.9.0" "47" >/dev/null 2>&1; then
  echo "  FAIL: succeeded with CURRENT_PROJECT_VERSION absent"; FAILED=1
else echo "  ok: fails when CURRENT_PROJECT_VERSION is absent"; fi

# Duplicate MARKETING_VERSION must fail — nightly_version.sh treats first
# occurrence as authoritative; silently rewriting all would create a version
# disagreement that reaches App Store Connect.
DUP_MKT="$TMP/dup_mkt.yml"
{
  echo "settings:"
  echo "  base:"
  echo "        MARKETING_VERSION: \"1.8.0\""
  echo "        CURRENT_PROJECT_VERSION: 23"
  echo "  targets:"
  echo "    RayMol:"
  echo "        MARKETING_VERSION: \"1.8.0\""
} > "$DUP_MKT"
if bash "$SCRIPT" "$DUP_MKT" "1.9.0" "47" >/dev/null 2>&1; then
  echo "  FAIL: succeeded with duplicate MARKETING_VERSION lines"; FAILED=1
else echo "  ok: fails when MARKETING_VERSION appears more than once"; fi

# Duplicate CURRENT_PROJECT_VERSION must fail for the same reason.
DUP_CPV="$TMP/dup_cpv.yml"
{
  echo "settings:"
  echo "  base:"
  echo "        MARKETING_VERSION: \"1.8.0\""
  echo "        CURRENT_PROJECT_VERSION: 23"
  echo "  targets:"
  echo "    RayMol:"
  echo "        CURRENT_PROJECT_VERSION: 23"
} > "$DUP_CPV"
if bash "$SCRIPT" "$DUP_CPV" "1.9.0" "47" >/dev/null 2>&1; then
  echo "  FAIL: succeeded with duplicate CURRENT_PROJECT_VERSION lines"; FAILED=1
else echo "  ok: fails when CURRENT_PROJECT_VERSION appears more than once"; fi

rm -rf "$TMP"
[ "$FAILED" = 0 ] && echo "PASS" || { echo "FAILURES"; exit 1; }
