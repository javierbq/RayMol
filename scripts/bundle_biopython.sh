#!/bin/bash
# bundle_biopython.sh — bundle Biopython's `Bio` package into the embedded
# Python site-packages for BOTH the macOS app (python-build-standalone 3.13)
# and the iOS app (BeeWare CPython 3.13 xcframework), so `import Bio` works in
# the embedded interpreter that runs Raymond's run_python tool.
#
# Biopython is mostly pure Python. On macOS we keep the cp313 arm64 C extensions
# (they load natively); on iOS we bundle the PURE-PYTHON subset only (the
# darwin .so cannot load on iOS, and iOS has no bundled numpy, so the numpy-
# dependent submodules — Bio.Align / Bio.pairwise2 / Bio.PDB — are unavailable
# there; Bio, Bio.Seq, Bio.SeqRecord, Bio.SeqUtils, Bio.Data still import).
#
# Idempotent: re-run to refresh. The deps_* trees are gitignored.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PYVER="3.13"
ABI="cp313"
BIO_VERSION="${BIO_VERSION:-1.87}"

MAC_SP="$REPO/deps_macos/python-standalone/python/lib/python${PYVER}/site-packages"
IOS_SLICES=("ios-arm64" "ios-arm64_x86_64-simulator")
IOS_XCFW="$REPO/deps_ios/Python.xcframework"

TMP="$(mktemp -d /tmp/raymol_bio.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

echo "=== Downloading biopython==${BIO_VERSION} (${ABI}, macOS arm64 wheel) ==="
python3 -m pip download "biopython==${BIO_VERSION}" \
    --only-binary=:all: --no-deps \
    --python-version "$PYVER" --platform macosx_11_0_arm64 --abi "$ABI" \
    -d "$TMP" >/dev/null
WHL="$(ls "$TMP"/biopython-*.whl)"
echo "  $WHL"

EX="$TMP/extract"; mkdir -p "$EX"
( cd "$EX" && unzip -q "$WHL" )

trim() {  # drop __pycache__ + bundled tests to keep the bundle lean
    find "$1" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
    find "$1" -type d -name "tests" -exec rm -rf {} + 2>/dev/null || true
}

# --- macOS: full Bio (keep arm64 .so; macOS has numpy) -----------------------
if [ -d "$MAC_SP" ]; then
    echo "=== macOS: install Bio -> $MAC_SP ==="
    rm -rf "$MAC_SP/Bio" "$MAC_SP"/biopython-*.dist-info
    cp -R "$EX/Bio" "$MAC_SP/Bio"
    cp -R "$EX"/biopython-*.dist-info "$MAC_SP/"
    trim "$MAC_SP/Bio"
    du -sh "$MAC_SP/Bio"
else
    echo "  SKIP macOS (run scripts/fetch_macos_python.sh first; $MAC_SP missing)"
fi

# --- iOS: pure-Python Bio only (no .so; numpy-dependent submodules unavailable)
PURE="$TMP/Bio_pure"
cp -R "$EX/Bio" "$PURE"
find "$PURE" -name "*.so" -delete
trim "$PURE"
for SLICE in "${IOS_SLICES[@]}"; do
    SP="$IOS_XCFW/$SLICE/lib/python${PYVER}/site-packages"
    if [ -d "$(dirname "$SP")" ]; then
        echo "=== iOS ($SLICE): install pure Bio -> $SP ==="
        mkdir -p "$SP"
        rm -rf "$SP/Bio" "$SP"/biopython-*.dist-info
        cp -R "$PURE" "$SP/Bio"
        cp -R "$EX"/biopython-*.dist-info "$SP/"
        du -sh "$SP/Bio"
    else
        echo "  SKIP iOS $SLICE (slice not present)"
    fi
done

echo "=== Done. Verify with: <embedded-python> -c 'import Bio; print(Bio.__version__)' ==="
