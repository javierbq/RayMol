#!/bin/bash
# Unit tests for XcodeGen deterministic object IDs (GitHub issue #642).
# Asserts that project.pbxproj contains no random TEMP_ UUIDs, that project.yml
# configFiles entries do not point directly to the project root, and that
# xcodegen regeneration is deterministic and free of TEMP_ IDs when xcodegen
# is available.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FAILED=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok ()   { echo "  ok: $1"; }
fail () { echo "  FAIL: $1"; FAILED=1; }

echo "== xcodegen_stable_ids =="

# no_temp_ids <pbxproj>: prints the offending lines and returns non-zero if the
# file contains a TEMP_ object id, else returns 0.
no_temp_ids () {
  local pbx="$1"
  if [ ! -f "$pbx" ]; then
    echo "file not found: $pbx" >&2
    return 2
  fi
  if grep -n 'TEMP_' "$pbx"; then
    return 1
  fi
  return 0
}

# --- 1. Self-test no_temp_ids --------------------------------------------------
BAD_FX="$TMP/bad.pbxproj"
GOOD_FX="$TMP/good.pbxproj"
echo '"TEMP_EDD84068-517B-461C-BDE0-73E905351476" /* PyMOLBridge.xcconfig */ = {isa = PBXFileReference; };' > "$BAD_FX"
echo '0DBFD1FF07FFAD4B8029FA48 /* Project.xcconfig */ = {isa = PBXFileReference; };' > "$GOOD_FX"

if OUT="$(no_temp_ids "$BAD_FX" 2>&1)"; then
  fail "no_temp_ids accepted fixture with TEMP_ ids"
else
  if [[ "$OUT" == *"TEMP_EDD84068"* ]]; then
    ok "no_temp_ids rejects fixture with TEMP_ ids and prints offending lines"
  else
    fail "no_temp_ids rejected fixture but did not print offending lines"
  fi
fi

if no_temp_ids "$GOOD_FX" >/dev/null 2>&1; then
  ok "no_temp_ids accepts fixture without TEMP_ ids"
else
  fail "no_temp_ids rejected fixture without TEMP_ ids"
fi

# --- 2. Committed project.pbxproj has no TEMP_ ---------------------------------
COMMITTED_PBX="$ROOT/swiftui/PyMOLViewer.xcodeproj/project.pbxproj"
if [ ! -f "$COMMITTED_PBX" ]; then
  fail "committed project.pbxproj missing: $COMMITTED_PBX"
elif OUT="$(no_temp_ids "$COMMITTED_PBX" 2>&1)"; then
  ok "committed project.pbxproj exists and has no TEMP_ ids"
else
  fail "committed project.pbxproj contains TEMP_ ids: $OUT"
fi

# --- 3. Assert project.yml configFiles entries are not in project root ---------
PROJECT_YML="$ROOT/swiftui/project.yml"
if [ ! -f "$PROJECT_YML" ]; then
  fail "project.yml missing: $PROJECT_YML"
else
  count=0
  bad_configs=()
  while read -r key val; do
    [ -z "$key" ] && continue
    count=$((count + 1))
    if [[ "$val" != */* ]]; then
      bad_configs+=("$key $val")
    fi
  done < <(awk '/^configFiles:/{flag=1; next} /^[a-zA-Z]/{flag=0} flag && /^[[:space:]]*(Debug|Release):/{print $1, $2}' "$PROJECT_YML")

  if [ "$count" -eq 0 ]; then
    fail "no Debug/Release entries found under configFiles in $PROJECT_YML"
  elif [ "${#bad_configs[@]}" -ne 0 ]; then
    fail "project.yml configFiles entries point at project root (must be in a subdirectory to avoid TEMP_ ids): ${bad_configs[*]}"
  else
    ok "project.yml configFiles entries point to subdirectory paths (non-root)"
  fi
fi

# --- 4. XcodeGen regeneration determinism (if installed) -----------------------
if command -v xcodegen >/dev/null 2>&1; then
  cp -R "$ROOT/swiftui" "$TMP/swiftui"
  # Drop the copied project so a failed generate cannot leave the committed
  # pbxproj in place and make both checks below pass vacuously.
  rm -rf "$TMP/swiftui/PyMOLViewer.xcodeproj"
  GEN_PBX="$TMP/swiftui/PyMOLViewer.xcodeproj/project.pbxproj"
  if ! OUT="$(cd "$TMP/swiftui" && xcodegen generate --quiet 2>&1)" || [ ! -f "$GEN_PBX" ]; then
    fail "first xcodegen generate failed: $OUT"
  else
    if OUT="$(no_temp_ids "$GEN_PBX" 2>&1)"; then
      ok "first xcodegen generated pbxproj has no TEMP_ ids"
    else
      fail "first xcodegen generated pbxproj contains TEMP_ ids: $OUT"
    fi

    cp "$GEN_PBX" "$TMP/pbxproj.run1"
    if ! OUT="$(cd "$TMP/swiftui" && xcodegen generate --quiet 2>&1)"; then
      fail "second xcodegen generate failed: $OUT"
    elif cmp -s "$TMP/pbxproj.run1" "$GEN_PBX"; then
      ok "xcodegen generation is byte-identical across runs (determinism check)"
    else
      fail "xcodegen generation produced different pbxproj across runs"
    fi
  fi
else
  echo "  skip: xcodegen not installed (determinism check)"
fi

if [ "$FAILED" = 0 ]; then echo "PASS"; else echo "FAILED"; exit 1; fi
