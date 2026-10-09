#!/bin/bash
# bundle_numpy_macos.sh — install numpy into the embedded python-build-standalone
# 3.13 tree used by the macOS app (deps_macos/python-standalone).
#
# Two things need it:
#   * Runtime — `import numpy` in the embedded interpreter that runs the MCP
#     run_python tool, and Bio.Align / Bio.pairwise2 / Bio.PDB via
#     bundle_biopython.sh (whose header already assumes "macOS has numpy").
#   * Compile time — the C core's `_PYMOL_NUMPY` paths (cmd.get_coords,
#     cmd.get_coordset, cmd.get_volume_field) need numpy/arrayobject.h, which
#     ships inside the installed package at numpy/_core/include. appkit's
#     CMakeLists picks it up from here (#373).
#
# Before this script existed the tree carried only pip, so a dev build silently
# compiled the core WITHOUT numpy support and get_coords returned None — while
# release bundles happened to have numpy installed by hand.
#
# Idempotent: re-run to refresh. deps_macos is gitignored.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PYVER="3.13"
NUMPY_VERSION="${NUMPY_VERSION:-2.4.6}"
PY="$REPO/deps_macos/python-standalone/python/bin/python"

test -x "$PY" || { echo "ERROR: run scripts/fetch_macos_python.sh first ($PY missing)"; exit 1; }

echo "=== Installing numpy==${NUMPY_VERSION} into the embedded python ==="
"$PY" -m pip install --upgrade --only-binary=:all: "numpy==${NUMPY_VERSION}"

SP="$REPO/deps_macos/python-standalone/python/lib/python${PYVER}/site-packages"
HDR="$SP/numpy/_core/include/numpy/arrayobject.h"

# drop bundled tests to keep the eventual .app lean (mirrors bundle_app.py)
find "$SP/numpy" -type d -name "tests" -exec rm -rf {} + 2>/dev/null || true
find "$SP/numpy" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true

test -f "$HDR" || { echo "ERROR: numpy headers missing at $HDR"; exit 1; }
"$PY" -c "import numpy; print('OK: numpy', numpy.__version__, 'at', numpy.__file__)"
echo "OK: headers at $HDR"
