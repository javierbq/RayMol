#!/bin/bash
# Unit tests for scripts/bundle_macos_dylibs.py's whole-bundle verification.
#
# Regression for 1.12.2 (212): the app shipped Contents/Frameworks/
# libbrotlidec.1.dylib, which loads @rpath/libbrotlicommon.1.dylib, without
# libbrotlicommon — and verification passed, because it only flagged absolute
# non-system paths (and the main binary's /usr/lib/swift rpath was treated as
# resolving anything). The fixtures are REAL Mach-Os built by clang, since the
# script reads them with otool.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/bundle_macos_dylibs.py"
FAILED=0

# A minimal .app: main executable -> @rpath/libdec.dylib -> @rpath/libcommon.dylib,
# mirroring freetype -> libbrotlidec -> libbrotlicommon. The main binary carries
# /usr/lib/swift as an rpath, like every Swift app does.
make_app () {
  local t app fw
  t="$(mktemp -d)"; app="$t/Fake.app"; fw="$app/Contents/Frameworks"
  mkdir -p "$app/Contents/MacOS" "$fw"
  cat > "$app/Contents/Info.plist" <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>Fake</string></dict></plist>
PL
  echo 'int common(void){return 1;}' > "$t/common.c"
  echo 'int common(void); int dec(void){return common();}' > "$t/dec.c"
  echo 'int dec(void); int main(void){return dec();}' > "$t/main.c"
  clang -dynamiclib "$t/common.c" -o "$fw/libcommon.dylib" \
    -install_name @rpath/libcommon.dylib
  clang -dynamiclib "$t/dec.c" -o "$fw/libdec.dylib" \
    -install_name @rpath/libdec.dylib "$fw/libcommon.dylib" -Wl,-rpath,@loader_path
  clang "$t/main.c" -o "$app/Contents/MacOS/Fake" "$fw/libdec.dylib" \
    -Wl,-rpath,@executable_path/../Frameworks -Wl,-rpath,/usr/lib/swift
  echo "$app"
}

echo "== bundle_macos_dylibs verify =="

A="$(make_app)"
if python3 "$SCRIPT" "$A" >/dev/null 2>&1; then
  echo "  ok: complete bundle passes"
else
  echo "  FAIL: complete bundle should pass"; python3 "$SCRIPT" "$A"; FAILED=1
fi
rm -rf "$(dirname "$A")"

A="$(make_app)"; rm -f "$A/Contents/Frameworks/libcommon.dylib"
OUT="$(python3 "$SCRIPT" "$A" 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] && grep -q "libdec.dylib: @rpath/libcommon.dylib (resolves to nothing)" <<<"$OUT"; then
  echo "  ok: fails when a bundled dylib's @rpath sibling is missing"
else
  echo "  FAIL: missing @rpath sibling not reported (rc=$RC)"; echo "$OUT"; FAILED=1
fi
rm -rf "$(dirname "$A")"

[ "$FAILED" = 0 ] && echo "PASS" || { echo "FAILED"; exit 1; }
