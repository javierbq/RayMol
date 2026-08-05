#!/bin/bash
# nightly_version.sh — emit the marketing version for automated beta
# (TestFlight) builds: the next MINOR after whatever swiftui/project.yml
# currently declares.
#     project.yml MARKETING_VERSION 1.8.0  ->  1.9.0
#
# DO NOT derive this from git tags. This repo carries the inherited PyMOL
# version line, so `git tag | sort -V | tail -1` yields v3.2.0 while RayMol's
# own releases top out at v1.8.0. A tag-based scheme would stamp betas 3.3.0 and
# permanently burn that version in App Store Connect — versions cannot be
# deleted there.
#
# The line advances by itself: publish_release.sh already asserts the packaged
# version matches project.yml, so cutting 1.9.0 sets that field to 1.9.0 and
# betas move to 1.10.0.
#
# COROLLARY / CONVENTION: bump MARKETING_VERSION *to* the release version when
# cutting a release, never in advance — pre-bumping makes betas leapfrog the
# version actually being prepared.
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

# $(( )) forces integer arithmetic, so 1.9.x -> 1.10.0 rather than a string bug.
echo "${MAJOR}.$((MINOR + 1)).0"
