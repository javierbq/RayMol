#!/bin/bash
# Unit tests for scripts/apply_mas_restrictions.sh.
#
# The script turns project.yml into its Mac App Store variant for both the
# local MAS archive (swiftui/archive_appstore.sh) and the Xcode Cloud macOS
# beta (swiftui/ci_scripts/ci_post_clone.sh). A silent no-op ships Sparkle to
# App Review (error 90296), so most of these cases are about REFUSING to run on
# a file whose shape changed.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/apply_mas_restrictions.sh"
REAL_YML="$ROOT/swiftui/project.yml"
FAILED=0

MAC_LINE='"SWIFT_ACTIVE_COMPILATION_CONDITIONS[sdk=macosx*]"'

# A minimal project.yml with the same shape as the real one.
make_fixture () {
  local f; f="$(mktemp)"
  cat > "$f" <<'YML'
packages:
  BoltzMLX:
    url: https://github.com/javierbq/boltz-mlx.git
    from: 0.2.1
  # RAYMOL_SPARKLE_BEGIN — stripped for the Mac App Store build
  Sparkle:
    url: https://github.com/sparkle-project/Sparkle
    from: 2.6.0
# RAYMOL_SPARKLE_END
targets:
  PyMOLViewer:
    settings:
      base:
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS[sdk=macosx*]": "$(inherited) RAYMOL_MPNN"
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS[sdk=iphoneos*]": "$(inherited) RAYMOL_MPNN"
    dependencies:
      - package: BoltzMLX
        product: BoltzMLX
# RAYMOL_SPARKLE_BEGIN — stripped for the Mac App Store build
      - package: Sparkle
        platforms: [macOS]
# RAYMOL_SPARKLE_END
YML
  echo "$f"
}

expect_fail () {  # $1 = description, $2 = fixture
  if bash "$SCRIPT" "$2" >/dev/null 2>&1; then
    echo "  FAIL: accepted $1"; FAILED=1
  else
    echo "  ok: refuses $1"
  fi
}

echo "== apply_mas_restrictions =="

# 1. Happy path on the fixture.
F="$(make_fixture)"
if bash "$SCRIPT" "$F" >/dev/null 2>&1; then
  if grep -q Sparkle "$F"; then
    echo "  FAIL: Sparkle survived the strip"; FAILED=1
  else echo "  ok: Sparkle package + dependency stripped"; fi
  if grep -F "$MAC_LINE" "$F" | grep -q '"$(inherited) RAYMOL_MPNN RAYMOL_MAS_RESTRICTED"'; then
    echo "  ok: macOS conditions = RAYMOL_MPNN RAYMOL_MAS_RESTRICTED"
  else echo "  FAIL: macOS line is: $(grep -F "$MAC_LINE" "$F")"; FAILED=1; fi
  if grep 'sdk=iphoneos' "$F" | grep -q RAYMOL_MAS_RESTRICTED; then
    echo "  FAIL: RAYMOL_MAS_RESTRICTED leaked into the iOS slice"; FAILED=1
  else echo "  ok: iOS slice untouched"; fi
  if grep -q 'package: BoltzMLX' "$F"; then
    echo "  ok: dependencies outside the markers survive"
  else echo "  FAIL: stripped a dependency outside the markers"; FAILED=1; fi
else
  echo "  FAIL: rejected a well-formed fixture"; bash "$SCRIPT" "$F"; FAILED=1
fi
rm -f "$F"

# 2. A Sparkle entry outside the markers must be caught after the strip.
F="$(make_fixture)"
printf '      - package: Sparkle\n' >> "$F"
expect_fail "a Sparkle dependency outside the markers" "$F"; rm -f "$F"

# 3. Markers missing or unbalanced.
F="$(make_fixture)"; /usr/bin/sed -i '' '/RAYMOL_SPARKLE_BEGIN/d; /RAYMOL_SPARKLE_END/d' "$F"
expect_fail "a file with no Sparkle markers" "$F"; rm -f "$F"
F="$(make_fixture)"; /usr/bin/sed -i '' '$d' "$F"   # drop the last END marker
expect_fail "unbalanced Sparkle markers" "$F"; rm -f "$F"

# 4. The macOS conditions line missing, or ambiguous.
F="$(make_fixture)"; /usr/bin/sed -i '' '/sdk=macosx/d' "$F"
expect_fail "a file with no macOS conditions line" "$F"; rm -f "$F"
F="$(make_fixture)"
/usr/bin/sed -i '' 's/^\(.*sdk=macosx.*\)$/\1\
\1/' "$F"
expect_fail "two macOS conditions lines" "$F"; rm -f "$F"

# 5. An unquoted value cannot be safely appended to — refuse it.
F="$(make_fixture)"
/usr/bin/sed -i '' 's/"\$(inherited) RAYMOL_MPNN"$/$(inherited)/' "$F"
grep -F "$MAC_LINE" "$F" | grep -q 'RAYMOL_MPNN' && echo "  (fixture edit failed)"
expect_fail "an unquoted macOS conditions value" "$F"; rm -f "$F"

# 6. The REAL project.yml: the script must accept it and produce a project with
#    no Sparkle package. This is the check that breaks when someone moves the
#    markers or reshapes the conditions line.
F="$(mktemp)"; cp "$REAL_YML" "$F"
if bash "$SCRIPT" "$F" >/dev/null 2>&1; then
  if grep -qE '^[[:space:]]*(- )?package:[[:space:]]*Sparkle|^[[:space:]]*Sparkle:[[:space:]]*$' "$F"; then
    echo "  FAIL: real project.yml still has a Sparkle package after the strip"; FAILED=1
  else echo "  ok: real project.yml strips cleanly"; fi
  if grep -F "$MAC_LINE" "$F" | grep -q RAYMOL_MAS_RESTRICTED; then
    echo "  ok: real project.yml gains RAYMOL_MAS_RESTRICTED"
  else echo "  FAIL: real project.yml macOS line lacks RAYMOL_MAS_RESTRICTED"; FAILED=1; fi
else
  echo "  FAIL: rejected the real swiftui/project.yml:"; bash "$SCRIPT" "$F"; FAILED=1
fi
rm -f "$F"

# 7. The committed project.yml itself must never carry the MAS flag — that
#    would compile Sparkle out of every DMG build too.
if grep -F "$MAC_LINE" "$REAL_YML" | grep -q RAYMOL_MAS_RESTRICTED; then
  echo "  FAIL: committed swiftui/project.yml has RAYMOL_MAS_RESTRICTED on macOS"; FAILED=1
else echo "  ok: committed project.yml is the Developer-ID variant"; fi

[ "$FAILED" = 0 ] && echo "PASS" || { echo "FAILURES"; exit 1; }
