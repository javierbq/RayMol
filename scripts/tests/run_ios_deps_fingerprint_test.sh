#!/bin/bash
# Unit tests for scripts/ios_deps_fingerprint.sh.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/ios_deps_fingerprint.sh"
FAILED=0

check () {  # $1=label  $2=expected  $3=actual
  if [ "$2" = "$3" ]; then
    echo "  ok: $1"
  else
    echo "  FAIL: $1 — expected '$2', got '$3'"; FAILED=1
  fi
}

INPUTS=(setup_ios_deps.sh fetch_ios_python.sh build_ios_deps.sh
        build_numpy_ios.sh bundle_biopython.sh)

# Build a throwaway repo whose scripts/ holds stubs + a copy of the script under
# test. The script derives its root from its own location, so this fully
# isolates the test from the real dep scripts.
make_fixture () {
  local dir; dir="$(mktemp -d)"
  mkdir -p "$dir/scripts"
  for f in "${INPUTS[@]}"; do echo "stub $f" > "$dir/scripts/$f"; done
  cp "$SCRIPT" "$dir/scripts/ios_deps_fingerprint.sh"
  echo "$dir"
}

echo "== ios_deps_fingerprint =="

A="$(make_fixture)"
FP1="$(bash "$A/scripts/ios_deps_fingerprint.sh")"

# 1. format: exactly 12 lowercase hex characters
if [[ "$FP1" =~ ^[0-9a-f]{12}$ ]]; then echo "  ok: 12 lowercase hex chars"
else echo "  FAIL: format — got '$FP1'"; FAILED=1; fi

# 2. deterministic across runs
check "deterministic" "$FP1" "$(bash "$A/scripts/ios_deps_fingerprint.sh")"

# 3. identical inputs in a different temp dir give the same value (path-independent)
B="$(make_fixture)"
check "path-independent" "$FP1" "$(bash "$B/scripts/ios_deps_fingerprint.sh")"

# 4. changing ANY input changes the fingerprint (this is the whole point:
#    a pin bump must invalidate the published artifact)
for f in "${INPUTS[@]}"; do
  C="$(make_fixture)"
  echo "NUMPY_VERSION=99.99.99" >> "$C/scripts/$f"
  GOT="$(bash "$C/scripts/ios_deps_fingerprint.sh")"
  if [ "$GOT" != "$FP1" ]; then echo "  ok: changes when $f changes"
  else echo "  FAIL: fingerprint unchanged after editing $f"; FAILED=1; fi
  rm -rf "$C"
done

# 5. a missing input is a loud failure, not a silent partial hash
D="$(make_fixture)"; rm -f "$D/scripts/build_numpy_ios.sh"
if bash "$D/scripts/ios_deps_fingerprint.sh" >/dev/null 2>&1; then
  echo "  FAIL: succeeded despite a missing input"; FAILED=1
else
  echo "  ok: missing input exits non-zero"
fi

# 6. the real repo checkout produces a valid fingerprint
REAL="$(bash "$SCRIPT")"
if [[ "$REAL" =~ ^[0-9a-f]{12}$ ]]; then echo "  ok: real repo → $REAL"
else echo "  FAIL: real repo gave '$REAL'"; FAILED=1; fi

rm -rf "$A" "$B" "$D"
[ "$FAILED" = 0 ] && echo "PASS" || { echo "FAILURES"; exit 1; }
