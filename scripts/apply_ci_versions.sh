#!/bin/bash
# apply_ci_versions.sh — rewrite MARKETING_VERSION and CURRENT_PROJECT_VERSION
# in a project.yml, in place.
#
# Used ONLY inside an ephemeral CI checkout. The committed project.yml keeps its
# release values; this edit exists purely so `xcodegen generate` picks up the
# beta version and Xcode Cloud's CI_BUILD_NUMBER. It is never committed.
#
# Why this must not silently no-op: App Store Connect requires the
# (CFBundleShortVersionString, CFBundleVersion) pair to be UNIQUE. If the edit
# fails to apply, every build after the first uploads a duplicate pair and is
# rejected — so the substitution is verified below and a no-op is fatal.
#
# The optional 4th argument is the human-readable beta label from
# scripts/beta_label.sh (e.g. "1.9.1-beta27"). It is stamped into
# RAYMOL_BETA_LABEL, which a postBuildScript copies to the built Info.plist's
# RayMolBetaLabel key for the app's Settings pane to display. Omit it and the
# committed empty value stands, which is what marks a build as NOT a beta —
# so release builds must keep omitting it.
#
# Usage: apply_ci_versions.sh <project.yml> <marketing-version> <build-number> [beta-label]
set -euo pipefail

YML="${1:?usage: apply_ci_versions.sh <project.yml> <marketing-version> <build-number> [beta-label]}"
MKT="${2:-}"
BUILD="${3:-}"
LABEL="${4:-}"

[ -f "$YML" ] || { echo "ERROR: not found: $YML" >&2; exit 1; }
[[ "$MKT" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "ERROR: marketing version must be X.Y.Z, got '$MKT'" >&2; exit 1; }
# Xcode Cloud build numbers are always integers; Apple rejects hashes and
# timestamps outright.
[[ "$BUILD" =~ ^[0-9]+$ ]] || {
  echo "ERROR: build number must be a non-negative integer, got '$BUILD'" >&2; exit 1; }

# Both keys must appear exactly once — we rewrite, never append, and sed applies
# the substitution to every matching line. A count of 0 (absent) and a count of
# 2+ (ambiguous) are both hard failures with distinct messages.
# Note: grep -c exits 1 when count is 0; || true keeps set -e from firing.
MKT_COUNT="$(grep -cE '^[[:space:]]*MARKETING_VERSION:' "$YML" || true)"
case "$MKT_COUNT" in
  0) echo "ERROR: no MARKETING_VERSION line in $YML" >&2; exit 1 ;;
  1) ;;
  *) echo "ERROR: $MKT_COUNT MARKETING_VERSION lines in $YML — ambiguous; refusing to rewrite all" >&2; exit 1 ;;
esac

CPV_COUNT="$(grep -cE '^[[:space:]]*CURRENT_PROJECT_VERSION:' "$YML" || true)"
case "$CPV_COUNT" in
  0) echo "ERROR: no CURRENT_PROJECT_VERSION line in $YML" >&2; exit 1 ;;
  1) ;;
  *) echo "ERROR: $CPV_COUNT CURRENT_PROJECT_VERSION lines in $YML — ambiguous; refusing to rewrite all" >&2; exit 1 ;;
esac

# \1 preserves the original indentation; xcodegen would reject a re-indented file.
/usr/bin/sed -i '' -E \
  -e "s/^([[:space:]]*)MARKETING_VERSION:.*/\1MARKETING_VERSION: \"$MKT\"/" \
  -e "s/^([[:space:]]*)CURRENT_PROJECT_VERSION:.*/\1CURRENT_PROJECT_VERSION: $BUILD/" \
  "$YML"

# Verify — a silent no-op here ships the wrong version.
grep -qE "^[[:space:]]*MARKETING_VERSION: \"$MKT\"$" "$YML" || {
  echo "ERROR: MARKETING_VERSION edit did not apply to $YML" >&2; exit 1; }
grep -qE "^[[:space:]]*CURRENT_PROJECT_VERSION: $BUILD$" "$YML" || {
  echo "ERROR: CURRENT_PROJECT_VERSION edit did not apply to $YML" >&2; exit 1; }

# The beta label is optional, but a MALFORMED one is not tolerated: it is what a
# tester reads off the Settings pane to report a bug against, so "1.9.1-beta" or
# a stray newline is worse than no label at all.
if [ -n "$LABEL" ]; then
  [[ "$LABEL" =~ ^[0-9]+\.[0-9]+\.[0-9]+-beta[0-9]+$ ]] || {
    echo "ERROR: beta label must be X.Y.Z-betaN, got '$LABEL'" >&2
    echo "       Build it with scripts/beta_label.sh, not by hand." >&2
    exit 1; }
  # Same exactly-once discipline as the two version keys above: we rewrite the
  # committed placeholder and never append, so an absent line is a hard failure
  # rather than a beta that silently ships with no label.
  LBL_COUNT="$(grep -cE '^[[:space:]]*RAYMOL_BETA_LABEL:' "$YML" || true)"
  case "$LBL_COUNT" in
    0) echo "ERROR: no RAYMOL_BETA_LABEL line in $YML — add the placeholder to project.yml" >&2; exit 1 ;;
    1) ;;
    *) echo "ERROR: $LBL_COUNT RAYMOL_BETA_LABEL lines in $YML — ambiguous; refusing to rewrite all" >&2; exit 1 ;;
  esac

  /usr/bin/sed -i '' -E \
    -e "s/^([[:space:]]*)RAYMOL_BETA_LABEL:.*/\1RAYMOL_BETA_LABEL: \"$LABEL\"/" \
    "$YML"

  grep -qE "^[[:space:]]*RAYMOL_BETA_LABEL: \"$LABEL\"$" "$YML" || {
    echo "ERROR: RAYMOL_BETA_LABEL edit did not apply to $YML" >&2; exit 1; }
  echo "project.yml -> $MKT ($BUILD), label $LABEL"
else
  echo "project.yml -> $MKT ($BUILD)"
fi
