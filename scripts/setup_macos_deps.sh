#!/bin/bash
# setup_macos_deps.sh — stage deps_macos/ from nothing: the embedded
# python-build-standalone 3.13 plus the two third-party packages the shipped
# macOS app carries in it (numpy, Biopython).
#
# Until this script existed, numpy reached deps_macos by a one-off hand
# `pip install` that nothing recorded, so a fresh machine — Xcode Cloud, a new
# laptop — built an app whose run_python tool and Bio.PDB/Bio.Align paths raised
# ImportError. The pins below are what the 1.12.0 DMG and Mac App Store builds
# actually ship (read from their site-packages *.dist-info); bump them
# deliberately, never by letting pip float.
#
#   NUMPY_VERSION  default 2.4.6 — PyPI's cp313 macosx arm64 wheel (delocated,
#                  carries its own OpenBLAS under numpy/.dylibs; the app's
#                  packaging phase re-signs every embedded .dylib/.so)
#   BIO_VERSION    default 1.87  — via scripts/bundle_biopython.sh, which owns
#                  the Biopython wheel handling for both platforms
#
# Callers: swiftui/ci_scripts/ci_post_clone.sh (macOS beta workflow). Safe to
# run by hand; it replaces deps_macos/python-standalone wholesale.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
NUMPY_VERSION="${NUMPY_VERSION:-2.4.6}"
export BIO_VERSION="${BIO_VERSION:-1.87}"
PYROOT="$REPO/deps_macos/python-standalone/python"
PY="$PYROOT/bin/python3"
SP="$PYROOT/lib/python3.13/site-packages"

echo "== python-build-standalone =="
rm -rf "$PYROOT"
bash "$REPO/scripts/fetch_macos_python.sh"

echo "== numpy $NUMPY_VERSION =="
# The standalone interpreter installs into its OWN site-packages, which is the
# tree the "macOS: Bundle Python + modules + data" phase copies into the app.
# --only-binary: never compile numpy here; a source build would silently pick
# up whatever BLAS the host happens to have.
"$PY" -m pip install --disable-pip-version-check --no-warn-script-location \
  --only-binary=:all: "numpy==$NUMPY_VERSION"

echo "== biopython $BIO_VERSION =="
# bundle_biopython.sh also handles the iOS slices; with no deps_ios present it
# skips them and installs only the macOS (arm64 C-extension) copy.
bash "$REPO/scripts/bundle_biopython.sh"

echo "== verify =="
# Import through the embedded interpreter, not the host's: this is the
# interpreter the app runs, and the version check catches a stale tree.
"$PY" - "$NUMPY_VERSION" "$BIO_VERSION" <<'PY'
import sys
import numpy, Bio
want_np, want_bio = sys.argv[1], sys.argv[2]
assert numpy.__version__ == want_np, f"numpy {numpy.__version__} != {want_np}"
assert Bio.__version__ == want_bio, f"Bio {Bio.__version__} != {want_bio}"
from Bio.PDB import PDBParser  # numpy-dependent half of Biopython
print(f"  numpy {numpy.__version__}, Bio {Bio.__version__}, Python {sys.version.split()[0]}")
PY
test -d "$SP/numpy" && test -d "$SP/Bio"
echo "deps_macos OK: $PYROOT"
