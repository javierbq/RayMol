#!/bin/bash
# ios_deps_fingerprint.sh — emit a stable 12-hex fingerprint of the iOS
# dependency bring-up (deps_ios/).
#
# BOTH pipelines call THIS script, which is what makes the scheme safe:
#   * .github/workflows/ios-deps-artifact.yml publishes  ios-deps-<fingerprint>
#   * swiftui/ci_scripts/ci_post_clone.sh fetches exactly that tag
# so the deps a build links can never silently disagree with the dep scripts in
# that checkout. There is no lockfile to drift.
#
# Six scripts are hashed (in fixed order):
#   fetch_ios_python.sh    PY_APPLE_SUPPORT_TAG  3.13-b12
#   build_ios_deps.sh      FREETYPE_VERSION 2.13.3 / LIBPNG_VERSION 1.6.44
#   build_numpy_ios.sh     NUMPY_VERSION 2.4.6
#   bundle_biopython.sh    BIO_VERSION 1.87
#   setup_ios_deps.sh      (orchestrates the above four)
#   prune_ios_deps.sh      included because it shapes the published artifact's
#                          contents — tightening the prune changes what the
#                          artifact contains, not just the bring-up behaviour
# Bump any pin and the fingerprint changes, invalidating the old artifact. That
# is the intended behaviour, not a side effect.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# FIXED order — the value must never depend on glob or filesystem ordering.
FILES=(
  scripts/setup_ios_deps.sh
  scripts/fetch_ios_python.sh
  scripts/build_ios_deps.sh
  scripts/build_numpy_ios.sh
  scripts/bundle_biopython.sh
  scripts/prune_ios_deps.sh
)

for f in "${FILES[@]}"; do
  [ -f "$ROOT/$f" ] || { echo "ERROR: fingerprint input missing: $f" >&2; exit 1; }
done

# Hash contents only (never paths or mtimes) so the value is reproducible from
# any checkout location, on CI and on a laptop alike.
( cd "$ROOT" && cat "${FILES[@]}" ) | shasum -a 256 | cut -c1-12
