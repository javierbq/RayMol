#!/bin/bash
# nightly_version.sh — emit the marketing version for automated beta
# (TestFlight) builds: the next PATCH after whatever swiftui/project.yml
# currently declares.
#     project.yml MARKETING_VERSION 1.9.1  ->  1.9.2
#
# WHY IT CANNOT RIDE THE CURRENT VERSION (learned 2026-08-10, the hard way).
# This script previously emitted project.yml's version verbatim so that betas
# would not claim an unreleased number at all. App Store Connect does not allow
# it. Once a version is APPROVED, its "pre-release train" is closed forever and
# no further build may be uploaded under it. iOS 1.9.1 went READY_FOR_SALE, and
# the next beta upload was rejected outright:
#     ITMS-90186: Invalid Pre-Release Train — the train version '1.9.1' is
#                 closed for new build submissions
#     ITMS-90062: CFBundleShortVersionString [1.9.1] must contain a higher
#                 version than the previously approved version [1.9.1]
# A beta therefore MUST sit on a version that has never been approved. That is
# Apple's rule, not a preference of ours.
#
# WHY THE NEXT PATCH, AND NOT THE NEXT MINOR. Emitting the next MINOR
# (1.9.1 -> 1.10.0) was the original scheme and it over-claimed: it stranded a
# TestFlight 1.10.0 above a live 1.8.0 for a release nobody had decided on, and
# when the real next version turned out to be a patch, every beta carried a
# version that would never ship. The next PATCH is the smallest legal claim —
# exactly one version ahead, and the one most likely to be released next anyway,
# so in the common case nothing is stranded at all.
#
# THE MARKETING VERSION IS STABLE ACROSS BETAS. This does not bump per build.
# Every beta rides the same 1.9.2 until a release actually claims it; only
# CI_BUILD_NUMBER moves, which is precisely what the (CFBundleShortVersionString,
# CFBundleVersion) uniqueness rule is for:
#     1.9.2 (27), 1.9.2 (28), 1.9.2 (29) ...
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
# COROLLARY / CONVENTION, unchanged and load-bearing: bump MARKETING_VERSION
# *to* the release version when cutting a release, never in advance.
# publish_release.sh already asserts the packaged version matches project.yml.
# This script reads project.yml as "the last version that shipped" and returns
# the first one that has not — so the beta train advances by itself the moment a
# release lands. Pre-bumping breaks that reading and makes betas skip a version.
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

MAJOR="${CUR%%.*}"
REST="${CUR#*.}"
MINOR="${REST%%.*}"
PATCH="${REST#*.}"

# $(( )) forces integer arithmetic, so 1.9.9 -> 1.9.10 rather than a string bug.
echo "${MAJOR}.${MINOR}.$((PATCH + 1))"
