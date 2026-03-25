#!/usr/bin/env bash
#
# fetch_python.sh - Download python-build-standalone for embedding in PyMOL.app
#
# Usage: ./scripts/fetch_python.sh [VERSION]
#   VERSION defaults to 3.13 (latest stable)
#
# Output: deps/python/ containing a self-contained, relocatable Python
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PYTHON_MAJOR_MINOR="${1:-3.13}"
DEST="$REPO_ROOT/deps/python"
CACHE_DIR="$REPO_ROOT/deps/src"

mkdir -p "$CACHE_DIR"

# Find the latest release from python-build-standalone
echo "=== Fetching python-build-standalone (Python ${PYTHON_MAJOR_MINOR}, aarch64-apple-darwin) ==="

# Get latest release tag
RELEASE_TAG=$(gh api repos/indygreg/python-build-standalone/releases/latest --jq '.tag_name')
echo "  Latest release: $RELEASE_TAG"

# Find the matching asset
ASSET_NAME=$(gh api "repos/indygreg/python-build-standalone/releases/latest" \
    --jq "[.assets[].name | select(test(\"cpython-${PYTHON_MAJOR_MINOR}.*aarch64-apple-darwin-install_only_stripped\"))] | sort | last")

if [ -z "$ASSET_NAME" ] || [ "$ASSET_NAME" = "null" ]; then
    echo "ERROR: No matching asset found for Python ${PYTHON_MAJOR_MINOR} aarch64-apple-darwin"
    echo "Available assets:"
    gh api "repos/indygreg/python-build-standalone/releases/latest" \
        --jq '[.assets[].name | select(test("aarch64-apple-darwin-install_only"))] | sort | .[]'
    exit 1
fi

echo "  Asset: $ASSET_NAME"

# Download
TARBALL="$CACHE_DIR/$ASSET_NAME"
if [ -f "$TARBALL" ]; then
    echo "  Already downloaded: $ASSET_NAME"
else
    DOWNLOAD_URL=$(gh api "repos/indygreg/python-build-standalone/releases/latest" \
        --jq ".assets[] | select(.name == \"$ASSET_NAME\") | .browser_download_url")
    echo "  Downloading..."
    curl -fSL "$DOWNLOAD_URL" -o "$TARBALL"
fi

# Extract
if [ -d "$DEST" ]; then
    echo "  Removing existing $DEST"
    rm -rf "$DEST"
fi

echo "  Extracting to $DEST"
mkdir -p "$DEST"
tar xf "$TARBALL" -C "$DEST" --strip-components=1

# Verify
PYTHON_BIN="$DEST/bin/python3"
if [ ! -x "$PYTHON_BIN" ]; then
    # Some builds put it under python/
    PYTHON_BIN="$DEST/python/bin/python3"
    if [ ! -x "$PYTHON_BIN" ]; then
        echo "ERROR: python3 binary not found in extracted archive"
        echo "Contents of $DEST:"
        ls -la "$DEST/"
        exit 1
    fi
    # Move contents up one level
    mv "$DEST/python"/* "$DEST/"
    rmdir "$DEST/python"
    PYTHON_BIN="$DEST/bin/python3"
fi

PYTHON_VERSION=$("$PYTHON_BIN" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}')")
PYTHON_MM=$("$PYTHON_BIN" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")

echo ""
echo "=== Python ${PYTHON_VERSION} installed ==="
echo "  Prefix:  $DEST"
echo "  Binary:  $PYTHON_BIN"
echo "  Version: $PYTHON_MM"
echo ""

# Ensure pip is available
if ! "$PYTHON_BIN" -m pip --version &>/dev/null; then
    echo "  Installing pip..."
    "$PYTHON_BIN" -m ensurepip --upgrade
fi

echo "  pip: $("$PYTHON_BIN" -m pip --version)"
echo ""
echo "Use with CMake: -DPYMOL_PYTHON_PREFIX=$DEST"
