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
# Usage: apply_ci_versions.sh <project.yml> <marketing-version> <build-number>
set -euo pipefail

YML="${1:?usage: apply_ci_versions.sh <project.yml> <marketing-version> <build-number>}"
MKT="${2:-}"
BUILD="${3:-}"

[ -f "$YML" ] || { echo "ERROR: not found: $YML" >&2; exit 1; }
[[ "$MKT" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "ERROR: marketing version must be X.Y.Z, got '$MKT'" >&2; exit 1; }
# Xcode Cloud build numbers are always integers; Apple rejects hashes and
# timestamps outright.
[[ "$BUILD" =~ ^[0-9]+$ ]] || {
  echo "ERROR: build number must be a non-negative integer, got '$BUILD'" >&2; exit 1; }

# Both keys must already exist — we rewrite, never append, so we cannot create a
# duplicate key or land one at the wrong nesting level.
grep -qE '^[[:space:]]*MARKETING_VERSION:' "$YML" || {
  echo "ERROR: no MARKETING_VERSION line in $YML" >&2; exit 1; }
grep -qE '^[[:space:]]*CURRENT_PROJECT_VERSION:' "$YML" || {
  echo "ERROR: no CURRENT_PROJECT_VERSION line in $YML" >&2; exit 1; }

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

echo "project.yml -> $MKT ($BUILD)"
