#!/bin/bash
# fetch_ios_python.sh — download a BeeWare CPython 3.13 Python.xcframework
# (github.com/beeware/Python-Apple-support) for embedding in the iOS
# PyMOLViewer app. Extracts to deps_ios/Python.xcframework (gitignored),
# which carries both slices the build expects:
#     ios-arm64                    (device)
#     ios-arm64_x86_64-simulator   (simulator)
# each with Python.framework/{Python dylib, Headers}, the stdlib under
# lib/python3.13, and the BeeWare platform-config/_sysconfigdata. This is the
# iOS analogue of scripts/fetch_macos_python.sh. Re-run to refresh.
#
# This fetches the PRISTINE framework only. numpy and Biopython are layered in
# afterwards by separate scripts (they depend on this xcframework existing):
#     scripts/build_ios_deps.sh     freetype + libpng (deps_ios/install{,_device})
#     scripts/build_numpy_ios.sh    numpy   -> deps_ios/numpy-ios/{simulator,device}
#     scripts/bundle_biopython.sh   Biopython Bio/ -> into the xcframework
# See swiftui/README.md ("iOS") for the full ordered bring-up.
#
# The tag is PINNED (below) rather than "latest" on purpose: BeeWare's 3.13-b13
# moved the embedded stdlib from <slice>/lib/python3.13 to <slice>/lib-<arch>/
# python3.13. The rest of the iOS build integration — the "Prepare Python binary
# modules" phase, the interpreter's config.home, and scripts/bundle_biopython.sh
# (which writes into <slice>/lib/python3.13/site-packages) — all assume the old
# lib/python3.13 layout. 3.13-b12 is the newest release that still uses it.
# Override with PY_APPLE_SUPPORT_TAG only if you've also updated those consumers;
# the layout guard below rejects an incompatible release loudly.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$REPO/deps_ios"
PY_MINOR="3.13"

TAG="${PY_APPLE_SUPPORT_TAG:-3.13-b12}"
BUILD="${TAG#${PY_MINOR}-}"   # e.g. 3.13-b12 -> b12
URL="https://github.com/beeware/Python-Apple-support/releases/download/${TAG}/Python-${PY_MINOR}-iOS-support.${BUILD}.tar.gz"

mkdir -p "$DEST"
cd "$DEST"
echo ">> Downloading $URL"
curl -fL -o python-ios.tar.gz "$URL"

echo ">> Extracting Python.xcframework"
rm -rf Python.xcframework
tar -xzf python-ios.tar.gz Python.xcframework   # tarball has it at the top level
rm -f python-ios.tar.gz

# Sanity: both slices present with the dylib, headers, and stdlib — and the
# stdlib is at the lib/python3.13 layout the rest of the build assumes (see the
# header note; b13+ use lib-<arch> and would silently break bundling/import).
for SLICE in ios-arm64 ios-arm64_x86_64-simulator; do
  BASE="Python.xcframework/$SLICE"
  test -f "$BASE/Python.framework/Python"   || { echo "ERROR: $SLICE Python dylib missing"; exit 1; }
  test -d "$BASE/Python.framework/Headers"  || { echo "ERROR: $SLICE Headers missing"; exit 1; }
  if [ ! -d "$BASE/lib/python${PY_MINOR}" ]; then
    echo "ERROR: $SLICE stdlib not at lib/python${PY_MINOR} (got $(cd "$BASE" && echo lib*/python${PY_MINOR} 2>/dev/null))."
    echo "       $TAG uses an incompatible layout; pin PY_APPLE_SUPPORT_TAG=3.13-b12."
    exit 1
  fi
done

echo "OK: $DEST/Python.xcframework  (BeeWare $TAG)"
lipo -archs Python.xcframework/ios-arm64_x86_64-simulator/Python.framework/Python
