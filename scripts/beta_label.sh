#!/bin/bash
# beta_label.sh — emit the human-readable label for an automated beta build:
#     beta_label.sh 1.9.1 27  ->  1.9.1-beta27
#
# WHY THIS IS NOT THE MARKETING VERSION. App Store Connect requires
# CFBundleShortVersionString to be a period-separated list of at most three
# non-negative integers, so "1.9.1-beta27" is rejected at upload — a beta cannot
# carry it as its version. Apple therefore only ever sees "1.9.1 (27)". This
# label is the same information in the form a human reads, and it goes only where
# WE control the text: RAYMOL_BETA_LABEL -> the built Info.plist's
# RayMolBetaLabel key -> the app's Settings pane. It is display text, never an
# identity Apple validates or sorts on.
#
# WHY THE BUILD NUMBER IS THE BETA ORDINAL. Xcode Cloud's CI_BUILD_NUMBER is a
# monotonic integer across the whole app, so the counter does not restart at 1
# for each version line — 1.9.1-beta27 can be followed by 1.10.0-beta34. That is
# deliberate: a per-version ordinal would need persistent state (the build number
# at which the line started) and would make two different builds share a label if
# that state were ever wrong. Monotonic-and-slightly-odd beats ambiguous.
#
# Usage: beta_label.sh <marketing-version> <build-number>
set -euo pipefail

MKT="${1:-}"
BUILD="${2:-}"

# Validate both halves to the SAME rules their consumers enforce, so a bad label
# fails here rather than showing a tester a version that does not exist.
# apply_ci_versions.sh applies the identical two patterns to the real settings.
[[ "$MKT" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "ERROR: marketing version must be X.Y.Z, got '$MKT'" >&2; exit 1; }
[[ "$BUILD" =~ ^[0-9]+$ ]] || {
  echo "ERROR: build number must be a non-negative integer, got '$BUILD'" >&2; exit 1; }

echo "${MKT}-beta${BUILD}"
