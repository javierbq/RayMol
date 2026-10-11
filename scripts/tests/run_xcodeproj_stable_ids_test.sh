#!/bin/bash
# Tests for deterministic XcodeGen output (GitHub issue #642).
#
# XcodeGen gives a `configFiles` entry at the project root an orphan PBXGroup,
# and that group plus the file reference get random TEMP_<UUID> object ids, so
# every `xcodegen generate` rewrote project.pbxproj. This suite asserts:
#   1. the TEMP_ id detector itself works (fixtures);
#   2. the committed project.pbxproj has no TEMP_ object ids;
#   3. no configFiles entry in project.yml (project- or target-level) points at
#      a file in the project root;
#   4. when xcodegen >= 2.46.0 is installed (older versions order the targets
#      list differently, see project.yml): regenerating a clean copy of swiftui/
#      (tracked + unignored files, as in a fresh checkout) twice gives
#      byte-identical output with no TEMP_ ids, identical to the committed
#      project.pbxproj (i.e. `xcodegen generate` leaves `git diff` empty).
# CI's runner has no xcodegen, so there checks 1-3 are what is enforced.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FAILED=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok ()   { echo "  ok: $1"; }
fail () { echo "  FAIL: $1"; FAILED=1; }

echo "== xcodeproj_stable_ids =="

# no_temp_ids <pbxproj>: prints the offending lines and returns non-zero if the
# file contains a TEMP_<UUID> object id, else returns 0. Matches the id shape
# only, so build settings such as TARGET_TEMP_DIR in embedded shell scripts
# don't trip it.
TEMP_ID_RE='TEMP_[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}'
no_temp_ids () {
  local pbx="$1"
  if [ ! -f "$pbx" ]; then
    echo "file not found: $pbx" >&2
    return 2
  fi
  if grep -nE "$TEMP_ID_RE" "$pbx"; then
    return 1
  fi
  return 0
}

# root_config_files <project.yml>: prints every configFiles value (project- or
# target-level, any config name) that resolves to a file in the project root.
root_config_files () {
  awk '
    function indent(s) { match(s, /^ */); return RLENGTH }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    {
      ind = indent($0)
      if (inblock && ind <= blockind) inblock = 0
      if (inblock) {
        line = $0; sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "", line)
        sub(/[[:space:]]+#.*$/, "", line); gsub(/["\047]/, "", line)
        while (line ~ /^\.\//) sub(/^\.\//, "", line)
        if (line != "" && line !~ /\//) print $0
      }
      if ($0 ~ /^[[:space:]]*configFiles:[[:space:]]*(#.*)?$/) { inblock = 1; blockind = ind }
      else if ($0 ~ /^[[:space:]]*configFiles:[[:space:]]*\{/) {   # flow mapping
        flow = $0; sub(/^[^{]*\{/, "", flow); sub(/\}.*$/, "", flow)
        n = split(flow, items, ",")
        for (k = 1; k <= n; k++) {
          v = items[k]; sub(/^[^:]*:[[:space:]]*/, "", v); gsub(/["\047[:space:]]/, "", v)
          while (v ~ /^\.\//) sub(/^\.\//, "", v)
          if (v != "" && v !~ /\//) print $0
        }
      }
    }' "$1"
}

# --- 1. Self-test the detectors ------------------------------------------------
BAD_FX="$TMP/bad.pbxproj"
GOOD_FX="$TMP/good.pbxproj"
echo '"TEMP_EDD84068-517B-461C-BDE0-73E905351476" /* PyMOLBridge.xcconfig */ = {isa = PBXFileReference; };' > "$BAD_FX"
cat > "$GOOD_FX" <<'EOF'
0DBFD1FF07FFAD4B8029FA48 /* Project.xcconfig */ = {isa = PBXFileReference; };
shellScript = "cp \"$TARGET_TEMP_DIR/x\" \"$TEMP_FILES_DIR/y\"\n";
EOF

if OUT="$(no_temp_ids "$BAD_FX" 2>&1)"; then
  fail "no_temp_ids accepted fixture with TEMP_ ids"
elif [[ "$OUT" == *"TEMP_EDD84068"* ]]; then
  ok "no_temp_ids rejects fixture with TEMP_ ids and prints offending lines"
else
  fail "no_temp_ids rejected fixture but did not print offending lines"
fi

if no_temp_ids "$GOOD_FX" >/dev/null 2>&1; then
  ok "no_temp_ids accepts fixture without TEMP_ ids (TARGET_TEMP_DIR is not an id)"
else
  fail "no_temp_ids rejected fixture without TEMP_ ids"
fi

YML_FX="$TMP/fixture.yml"
cat > "$YML_FX" <<'EOF'
options:
  createIntermediateGroups: true
configFiles:   # project base
  Debug: Config/Project.xcconfig    # fine
  Release: ./Root.xcconfig
  Profile: "Root2.xcconfig"
targets:
  App:
    configFiles:
      Debug: Config/App.xcconfig
      Release: TargetRoot.xcconfig
    settings:
      base:
        X: y.xcconfig
  Other:
    configFiles: {Debug: Sub/Ok.xcconfig, Release: FlowRoot.xcconfig}
EOF
OUT="$(root_config_files "$YML_FX")"
if [[ "$OUT" == *Root.xcconfig* && "$OUT" == *Root2.xcconfig* && "$OUT" == *TargetRoot.xcconfig* \
      && "$OUT" == *FlowRoot.xcconfig* && "$(grep -c . <<<"$OUT")" = 4 \
      && "$OUT" != *Project.xcconfig* && "$OUT" != *App.xcconfig* && "$OUT" != *y.xcconfig* ]]; then
  ok "root_config_files flags root-level entries (./, any config name, target-level, flow mapping) only"
else
  fail "root_config_files fixture output wrong: $OUT"
fi

# --- 2. Committed project.pbxproj has no TEMP_ ids ----------------------------
COMMITTED_PBX="$ROOT/swiftui/PyMOLViewer.xcodeproj/project.pbxproj"
if [ ! -f "$COMMITTED_PBX" ]; then
  fail "committed project.pbxproj missing: $COMMITTED_PBX"
elif OUT="$(no_temp_ids "$COMMITTED_PBX" 2>&1)"; then
  ok "committed project.pbxproj has no TEMP_ ids"
else
  fail "committed project.pbxproj contains TEMP_ ids: $OUT"
fi

# --- 3. No configFiles entry in the project root -------------------------------
PROJECT_YML="$ROOT/swiftui/project.yml"
if [ ! -f "$PROJECT_YML" ]; then
  fail "project.yml missing: $PROJECT_YML"
elif ! grep -qE '^[[:space:]]*configFiles:' "$PROJECT_YML"; then
  ok "project.yml has no configFiles (nothing can get a root-level TEMP_ id)"
elif OUT="$(root_config_files "$PROJECT_YML")" && [ -n "$OUT" ]; then
  fail "configFiles entries in the project root (XcodeGen gives them TEMP_ ids; put them in a subdirectory, see swiftui/Config/Project.xcconfig): $OUT"
else
  ok "project.yml configFiles entries are all in subdirectories"
fi

# --- 4. Regeneration is deterministic and matches the committed project -------
# gen <label>: regenerate the copy from scratch; fails if no pbxproj results.
gen () {
  rm -rf "$TMP/swiftui/PyMOLViewer.xcodeproj"
  if ! OUT="$(cd "$TMP/swiftui" && xcodegen generate --quiet 2>&1)" || [ ! -f "$GEN_PBX" ]; then
    fail "$1 xcodegen generate failed: $OUT"
    return 1
  fi
}

MIN="2.46.0"
VER="$(command -v xcodegen >/dev/null 2>&1 && xcodegen --version 2>/dev/null | sed -n 's/^Version: *//p')"
if [ -z "$VER" ]; then
  echo "  skip: xcodegen not installed (regeneration checks)"
elif [ "$(printf '%s\n%s\n' "$MIN" "$VER" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" != "$MIN" ]; then
  echo "  skip: xcodegen $VER < $MIN (regeneration checks; older versions order targets differently)"
else
  # Copy only tracked and untracked-but-not-ignored files, as in a fresh
  # checkout: the gitignored DerivedData dirs under swiftui/ are gigabytes, and
  # local overrides such as PyMOLBridge.local.xcconfig must not leak in.
  mkdir -p "$TMP/swiftui"
  if ! ( cd "$ROOT" && git ls-files -z -co --exclude-standard -- swiftui \
           | while IFS= read -r -d '' f; do [ -e "$f" ] && printf '%s\0' "$f"; done \
           | tar --null -T - -cf - ) | tar -xf - -C "$TMP"; then
    fail "could not copy swiftui/ for regeneration"
  else
    GEN_PBX="$TMP/swiftui/PyMOLViewer.xcodeproj/project.pbxproj"
    if gen "first"; then
      if OUT="$(no_temp_ids "$GEN_PBX" 2>&1)"; then
        ok "regenerated pbxproj has no TEMP_ ids"
      else
        fail "regenerated pbxproj contains TEMP_ ids: $OUT"
      fi
      cp "$GEN_PBX" "$TMP/pbxproj.run1"
      if gen "second"; then
        if cmp -s "$TMP/pbxproj.run1" "$GEN_PBX"; then
          ok "two regenerations are byte-identical (determinism check)"
        else
          fail "two regenerations produced different pbxproj files"
        fi
      fi
      if cmp -s "$TMP/pbxproj.run1" "$COMMITTED_PBX"; then
        ok "regeneration matches the committed project.pbxproj"
      else
        fail "committed project.pbxproj is stale; run 'cd swiftui && xcodegen generate' and commit. Diff: $(diff "$COMMITTED_PBX" "$TMP/pbxproj.run1" | head -20)"
      fi
    fi
  fi
fi

if [ "$FAILED" = 0 ]; then echo "PASS"; else echo "FAILED"; exit 1; fi
