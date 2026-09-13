#!/bin/zsh
# test_cylinder_cap_isolation.sh — regression test for GitHub issue #441.
#
# INVARIANT: drawing a CGO cylinder (cgo.CYLINDER — what the Move-mode gizmo is
# built from) must not change how STICKS render, during or after.
#
# Before the fix, the Metal cylinder impostor dropped the per-cylinder `a_cap`
# vertex attribute and substituted a never-reset process global
# (CCGORenderer::metalCylCapConst). A single cgo.CYLINDER latched that global to
# cCylShaderBothCapsFlat|cCylShaderInterpColor (0x13), permanently switching every
# subsequent stick to flat caps + linear two-color interpolation. The artifact
# scales with stick_radius, so the test renders at 0.40 where it is obvious.
#
# Usage: scripts/test_cylinder_cap_isolation.sh [/path/to/RayMol.app]
# Exits 0 if the three renders are identical, 1 otherwise.

set -uo pipefail
APP="${1:-swiftui/build_mac_dd/Build/Products/Debug/RayMol.app}"
# Dev builds are renamed per CLAUDE.md (RayMol-<suffix>.app), so read the real
# executable name rather than assuming "RayMol".
EXE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist" 2>/dev/null)"
BIN="$APP/Contents/MacOS/${EXE:-RayMol}"
[ -x "$BIN" ] || { echo "FAIL: no RayMol binary at $BIN"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/poison.py" <<'PY'
from pymol import cmd, cgo
cmd.load_cgo([cgo.CYLINDER, 100.0, 100.0, 100.0, 100.6, 100.0, 100.0, 0.05,
              1.0, 0.0, 0.0, 0.0, 0.0, 1.0], 'cyl', zoom=0)
PY

# Runs twice: PYMOL_AUTOEXPORT re-asserts PYMOL_AUTOCMD just before the render,
# so the CGO is created on the first pass (and rendered in the frames between)
# and deleted on the second — proving the corruption outlives the object.
cat > "$WORK/poison_once.py" <<PY
import os
from pymol import cmd, cgo
FLAG = '$WORK/flag'
if os.path.exists(FLAG):
    cmd.delete('cyl')
else:
    open(FLAG, 'w').write('1')
    cmd.load_cgo([cgo.CYLINDER, 100.0, 100.0, 100.0, 100.6, 100.0, 100.0, 0.05,
                  1.0, 0.0, 0.0, 0.0, 0.0, 1.0], 'cyl', zoom=0)
PY

SCENE="fragment trp;hide everything;show sticks;util.cnc all;bg_color black"
SCENE="$SCENE;set stick_radius, 0.40;orient trp;zoom trp, -0.3"

render() {  # render <out.png> [extra cmds]
  local out="$1" extra="${2:-}" cmds="$SCENE"
  [ -n "$extra" ] && cmds="$cmds;$extra"
  rm -f "$out"
  PYMOL_AUTOCMD="$cmds" PYMOL_AUTOEXPORT="$out,800,600" "$BIN" >"$WORK/log" 2>&1 &
  local pid=$!
  for _ in $(seq 1 90); do [ -s "$out" ] && break; /bin/sleep 1; done
  /bin/sleep 2; kill $pid 2>/dev/null; wait $pid 2>/dev/null
  [ -s "$out" ] || { echo "FAIL: render produced nothing ($out)"; tail -5 "$WORK/log"; exit 1; }
}

echo "== rendering (app: $APP)"
render "$WORK/a_clean.png"
render "$WORK/b_present.png" "run $WORK/poison.py"
render "$WORK/c_deleted.png" "run $WORK/poison_once.py"

/usr/bin/python3 - "$WORK" <<'PY'
import sys, struct, zlib, pathlib
# Minimal PNG reader (no PIL dependency): RGBA8, no interlace — what the
# Metal exporter writes.
def read(p):
    d = pathlib.Path(p).read_bytes(); assert d[:8] == b'\x89PNG\r\n\x1a\n', p
    i, idat, w = 8, b'', None
    while i < len(d):
        ln = struct.unpack('>I', d[i:i+4])[0]; typ = d[i+4:i+8]; body = d[i+8:i+8+ln]
        if typ == b'IHDR':
            w, h, bd, ct = struct.unpack('>IIBB', body[:10])
            assert bd == 8 and ct == 6, f'{p}: expected RGBA8, got bd={bd} ct={ct}'
        elif typ == b'IDAT': idat += body
        i += 12 + ln
    raw, out, stride, prev = zlib.decompress(idat), bytearray(), w*4, bytearray(w*4)
    pos = 0
    for _ in range(h):
        f = raw[pos]; line = bytearray(raw[pos+1:pos+1+stride]); pos += 1 + stride
        for x in range(stride):
            a = line[x-4] if x >= 4 else 0; b = prev[x]; c = prev[x-4] if x >= 4 else 0
            if f == 1: line[x] = (line[x]+a) & 255
            elif f == 2: line[x] = (line[x]+b) & 255
            elif f == 3: line[x] = (line[x]+((a+b) >> 1)) & 255
            elif f == 4:
                pa, pb, pc = abs(b-c), abs(a-c), abs(a+b-2*c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[x] = (line[x]+pr) & 255
        out += line; prev = line
    return bytes(out)

w = sys.argv[1]
clean = read(f'{w}/a_clean.png')
fail = False
for name, path in (('CGO present', f'{w}/b_present.png'),
                   ('CGO deleted', f'{w}/c_deleted.png')):
    other = read(path)
    diff = sum(1 for i in range(0, len(clean), 4)
               if abs(clean[i]-other[i]) + abs(clean[i+1]-other[i+1])
                + abs(clean[i+2]-other[i+2]) > 12)
    pct = 100.0 * diff / (len(clean)//4)
    status = 'ok' if pct < 0.01 else 'CHANGED'
    print(f'  sticks vs clean, {name:12s}: {pct:6.2f}% of pixels {status}')
    if pct >= 0.01: fail = True
sys.exit(1 if fail else 0)
PY
rc=$?
[ $rc -eq 0 ] && echo "PASS: a CGO cylinder does not affect stick rendering" \
              || echo "FAIL: stick rendering changed (issue #441)"
exit $rc
