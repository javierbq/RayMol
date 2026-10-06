#!/bin/bash
# apply_mas_restrictions.sh — turn a project.yml into its Mac App Store variant,
# in place:
#   1. delete everything between the RAYMOL_SPARKLE_BEGIN / RAYMOL_SPARKLE_END
#      markers (the Sparkle package + its dependency entry), and
#   2. add RAYMOL_MAS_RESTRICTED to the macOS SWIFT_ACTIVE_COMPILATION_CONDITIONS
#      line, which compiles the Sparkle + MCP code paths out of the build.
#
# Both halves are required. The Mac App Store forbids self-update, and Sparkle's
# helper executables fail App Sandbox validation at upload (error 90296). The
# compilation condition alone does not unembed Sparkle — the binary still links
# @rpath/Sparkle.framework while the package dependency is present.
#
# Two callers, both of which must only ever run this on a THROWAWAY copy:
#   * swiftui/archive_appstore.sh macOS — backs project.yml up first and
#     restores it right after `xcodegen generate`
#   * swiftui/ci_scripts/ci_post_clone.sh — Xcode Cloud's ephemeral checkout,
#     for the macOS beta workflow
# Never commit the result: the committed project.yml is the Developer-ID/DMG
# build, and Sparkle is how that build updates itself.
#
# Why the flag goes into project.yml rather than onto the xcodebuild command
# line: Xcode Cloud runs its own `xcodebuild archive` and accepts no extra
# settings. Appending to the existing per-SDK line yields exactly what
# archive_appstore.sh's command-line override produces —
# `RAYMOL_MPNN RAYMOL_MAS_RESTRICTED` for the macOS slice — so both MAS paths
# compile the same code.
#
# Every edit is verified after it is made: `sed` exits 0 whether or not its
# pattern matched, and a silent no-op here ships Sparkle to App Review.
#
# Usage: apply_mas_restrictions.sh <project.yml>
set -euo pipefail
YML="${1:?usage: apply_mas_restrictions.sh <project.yml>}"
[ -f "$YML" ] || { echo "ERROR: not found: $YML" >&2; exit 1; }

# A key line is `  "SWIFT_ACTIVE_COMPILATION_CONDITIONS[sdk=macosx*]": "..."`.
MAC_KEY='"SWIFT_ACTIVE_COMPILATION_CONDITIONS\[sdk=macosx\*\]":'

# --- Preconditions: refuse to edit a file whose shape we do not recognise ----
BEGINS="$(grep -c '# RAYMOL_SPARKLE_BEGIN' "$YML" || true)"
ENDS="$(grep -c '# RAYMOL_SPARKLE_END' "$YML" || true)"
if [ "$BEGINS" = 0 ] || [ "$BEGINS" != "$ENDS" ]; then
  echo "ERROR: RAYMOL_SPARKLE_BEGIN/END markers missing or unbalanced in $YML" >&2
  echo "       (found $BEGINS BEGIN, $ENDS END). Refusing to guess what to strip." >&2
  exit 1
fi
MAC_LINES="$(grep -cE "^[[:space:]]*$MAC_KEY" "$YML" || true)"
if [ "$MAC_LINES" != 1 ]; then
  echo "ERROR: expected exactly one macOS SWIFT_ACTIVE_COMPILATION_CONDITIONS line" >&2
  echo "       in $YML, found $MAC_LINES." >&2
  exit 1
fi

# --- 1. Strip Sparkle ---------------------------------------------------------
/usr/bin/sed -i '' '/# RAYMOL_SPARKLE_BEGIN/,/# RAYMOL_SPARKLE_END/d' "$YML"
if grep -qE '^[[:space:]]*(- )?package:[[:space:]]*Sparkle' "$YML" \
   || grep -qE '^[[:space:]]*Sparkle:[[:space:]]*$' "$YML"; then
  echo "ERROR: Sparkle is still referenced after the strip — a Sparkle entry sits" >&2
  echo "       outside the RAYMOL_SPARKLE_BEGIN/END markers in $YML." >&2
  exit 1
fi

# --- 2. Add RAYMOL_MAS_RESTRICTED to the macOS slice ---------------------------
if ! grep -E "^[[:space:]]*$MAC_KEY" "$YML" | grep -q 'RAYMOL_MAS_RESTRICTED'; then
  /usr/bin/sed -i '' -E "s/^([[:space:]]*$MAC_KEY[[:space:]]*\"[^\"]*)\"/\1 RAYMOL_MAS_RESTRICTED\"/" "$YML"
fi
grep -E "^[[:space:]]*$MAC_KEY" "$YML" | grep -q 'RAYMOL_MAS_RESTRICTED' || {
  echo "ERROR: could not add RAYMOL_MAS_RESTRICTED to the macOS" >&2
  echo "       SWIFT_ACTIVE_COMPILATION_CONDITIONS line in $YML (value not quoted?)." >&2
  exit 1; }

echo "MAS restrictions applied to $YML (Sparkle stripped, RAYMOL_MAS_RESTRICTED on macOS)"
