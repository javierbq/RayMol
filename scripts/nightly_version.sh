#!/bin/bash
# nightly_version.sh — emit the marketing version for automated beta
# (TestFlight) builds: whatever swiftui/project.yml currently declares, VERBATIM.
#     project.yml MARKETING_VERSION 1.9.1  ->  1.9.1
#
# WHY THIS DOES NOT BUMP. It used to emit the next MINOR (1.9.1 -> 1.10.0) so a
# beta always sorted above the last release. That pre-claims a version number
# App Store Connect will not let you take back: by 2026-08-10 the iOS app had a
# TestFlight prerelease 1.10.0 sitting above a live App Store 1.8.0, for a
# release nobody had decided on yet. When the real next version turned out to be
# a patch, 1.10.0 was stranded and every beta was labelled with a version that
# would never ship. Betas now ride the CURRENT version and are distinguished by
# the build number, which is exactly what the (CFBundleShortVersionString,
# CFBundleVersion) uniqueness rule is for:
#     1.9.1 (27), 1.9.1 (28), 1.9.1 (29) ...
# so no version is burned until a release actually claims it.
#
# The human-readable "1.9.1-beta27" that testers see is built by
# scripts/beta_label.sh from this version plus the build number, and cannot live
# here: App Store Connect requires CFBundleShortVersionString to be at most
# three numeric components, so a "-beta27" suffix in the marketing version is
# rejected at upload. See run_nightly_version_test.sh, which asserts exactly
# that this script refuses a non-numeric version.
#
# DO NOT derive this from git tags. This repo carries the inherited PyMOL version
# line, so `git tag | sort -V | tail -1` yields v3.2.0 while RayMol's own
# releases top out at 1.9.1. A tag-based scheme would stamp betas 3.3.0 and
# permanently burn that version in App Store Connect — versions cannot be
# deleted there.
#
# COROLLARY / CONVENTION, unchanged and now load-bearing in a second way: bump
# MARKETING_VERSION *to* the release version when cutting a release, never in
# advance. publish_release.sh already asserts the packaged version matches
# project.yml. Pre-bumping it no longer makes betas leapfrog — it makes them
# claim a version that has not shipped.
#
# Usage: nightly_version.sh [path/to/project.yml]
# The optional argument exists for unit tests; production callers pass nothing.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_YML="${1:-$ROOT/swiftui/project.yml}"

[ -f "$PROJECT_YML" ] || { echo "ERROR: project.yml not found: $PROJECT_YML" >&2; exit 1; }

# Accept quoted or bare scalars, but require a strict three-component numeric
# version — anything else means the file changed shape and we must not guess.
CUR="$(sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([0-9]+\.[0-9]+\.[0-9]+)"?[[:space:]]*$/\1/p' \
        "$PROJECT_YML" | head -1)"

[ -n "$CUR" ] || {
  echo "ERROR: no valid MARKETING_VERSION (X.Y.Z) in $PROJECT_YML" >&2
  echo "       Refusing to guess — a wrong marketing version cannot be undone" >&2
  echo "       in App Store Connect." >&2
  exit 1; }

echo "$CUR"
