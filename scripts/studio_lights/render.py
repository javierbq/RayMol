#!/usr/bin/env python3
"""PROTOTYPE: render the studio-lights preset gallery headlessly.

    python3 scripts/studio_lights/render.py --app /path/RayMol-studio.app \\
        --out /tmp/studio-gallery [--presets off,three_point] [--reps surface]

One `open -n` per image, using the materials gallery's export helper (same
PYMOL_AUTOCMD + PYMOL_AUTOEXPORT path; read its docstring for the pitfalls).
Then builds a contact sheet, index.html, from the PNGs.
"""
import argparse
import html
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, os.pardir, os.pardir))
sys.path.insert(0, os.path.join(ROOT, 'scripts', 'materials_gallery'))
from render import bundle_id, export  # noqa: E402

PRESETS = ['off', 'three_point', 'softbox', 'spotlight', 'rembrandt', 'neon',
           'sunset', 'underlight']

REPS = {
    'surface': '''cmd.show("surface", "m and polymer")
cmd.color("grey90", "m")''',
    'cartoon': '''cmd.show("cartoon", "m and polymer")
cmd.set("cartoon_flat_sheets", 1)
cmd.spectrum("count", "rainbow", "m and name CA")''',
    'spheres': '''cmd.show("spheres", "m and polymer and not hydro")
util.cbaw("m")''',
    'cartoon_white': '''cmd.show("cartoon", "m and polymer")
cmd.set("cartoon_flat_sheets", 1)
cmd.color("grey90", "m")''',
}

SCENE = '''from pymol import cmd, util
cmd.reinitialize()
cmd.load({pdb!r}, "m")
cmd.remove("solvent or hetatm")
cmd.hide("everything")
{rep}
cmd.set("bg_rgb", {bg!r})
cmd.set("depth_cue", 0)
cmd.set("ray_opaque_background", 1)
cmd.set("metal_dof", 0)
cmd.set("metal_temporal_ao", 0)
cmd.orient("m")
cmd.turn("y", -25)
{studio}
'''

BG = {'dark': [0.05, 0.05, 0.06], 'light': [0.84, 0.85, 0.87]}

# One-parameter sweeps of a single spot light: what each knob does on its own.
_SPOT = 'spot: az=-25 el=35 dist=3 beam=40 soft=0.4 kelvin=5600 int=1.5 ' \
        'spec=0.7 shadow=1 ambient=0.06'


def _with(**kw):
    tokens = dict(t.split('=', 1) for t in _SPOT.split()[1:])
    tokens.update({k: str(v) for k, v in kw.items()})
    return 'spot: ' + ' '.join('%s=%s' % kv for kv in tokens.items())


SWEEPS = {
    # At dist=3 a cone wider than ~25 degrees already covers the whole
    # molecule, so the sweeps live where the beam edge falls ON it.
    'beam': [('beam %d' % b, _with(beam=b, soft=0.3)) for b in (8, 13, 19, 28)],
    'soft': [('soft %g' % v, _with(beam=15, soft=v)) for v in (0, 0.3, 0.7, 1)],
    'kelvin': [('%d K' % k, _with(kelvin=k)) for k in (2200, 3500, 6500, 12000)],
    'color': [(c, 'spot: az=-25 el=35 dist=3 beam=45 soft=0.4 int=1.5 spec=0.7 '
                  'shadow=1 color=%s ambient=0.06 | rim: az=160 el=25 beam=40 '
                  'soft=0.4 int=1.8 spec=1 color=%s' % (c, r))
              for c, r in (('white', 'white'), ('orange', 'skyblue'),
                           ('hotpink', 'cyan'), ('palegreen', 'violet'))],
    'intensity': [('int %g' % v, _with(int=v)) for v in (0.6, 1.2, 2.0, 3.5)],
}

# Two lights, red and blue, from opposite directions (antipodal az/el pairs).
# Blue is lifted toward cyan and run a little hotter: pure blue carries so
# little luminance that it reads as a dark side rather than a light.
_RED = 'rgb=1/0.12/0.06 int=1.3'
_BLUE = 'rgb=0.15/0.35/1 int=1.6'


def _pair(az, el, extra_red='', beam=70):
    common = 'dist=4 beam=%d soft=0.6 spec=0.8' % beam
    return ('red: az=%g el=%g %s %s %s | blue: az=%g el=%g %s %s ambient=0.04'
            % (az, el, common, _RED, extra_red, az + 180 if az <= 0 else az - 180,
               -el, common, _BLUE))


SWEEPS['redblue'] = [
    ('left / right', _pair(-90, 0)),
    ('front-top-left / back-bottom-right', _pair(-50, 35)),
    ('top / bottom', _pair(0, 80)),
    ('left / right + red shadow', _pair(-90, 0, 'shadow=1')),
]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--app', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--presets', default=','.join(PRESETS))
    ap.add_argument('--reps', default=','.join(REPS))
    ap.add_argument('--bg', default='dark')
    ap.add_argument('--rt', type=int, default=0, help='Metal ray tracing 0/1')
    ap.add_argument('--size', default='800x600')
    ap.add_argument('--sweeps', default='',
                    help='comma-separated SWEEPS to render instead of presets')
    args = ap.parse_args()
    out = os.path.abspath(args.out)
    if any(c.isspace() for c in out + ROOT):
        sys.exit('paths must not contain whitespace (PYMOL_AUTOCMD limitation)')
    ident, exe = bundle_id(args.app)
    if ident == 'io.raymol.RayMol':
        sys.exit('give the app copy its own CFBundleIdentifier')
    size = [int(x) for x in args.size.split('x')]
    os.makedirs(os.path.join(out, 'scenes'), exist_ok=True)
    presets = args.presets.split(',')
    reps = args.reps.split(',')
    bgs = args.bg.split(',')
    pdb = os.path.join(ROOT, 'testing', 'data', '1rx1.pdb')

    jobs = []
    if args.sweeps:
        for sweep in args.sweeps.split(','):
            for i, (label, spec) in enumerate(SWEEPS[sweep]):
                for rep in reps:
                    text = SCENE.format(pdb=pdb, rep=REPS[rep], bg=BG[bgs[0]],
                                        studio='cmd.studio(%r)' % spec)
                    jobs.append(('sweep_%s_%d_%s' % (sweep, i, rep), text))
    for bg in bgs if not args.sweeps else ():
        for rep in reps:
            for preset in presets:
                studio = '' if preset == 'off' else 'cmd.studio(%r)' % preset
                text = SCENE.format(pdb=pdb, rep=REPS[rep], bg=BG[bg],
                                    studio=studio)
                jobs.append(('%s_%s_%s' % (rep, bg, preset), text))

    warm = os.path.join(out, 'scenes', '_warm.py')
    open(warm, 'w').write(jobs[0][1])
    export(args.app, exe, warm, os.path.join(out, '_warm.png'), size, args.rt)
    for n, (tag, text) in enumerate(jobs, 1):
        script = os.path.join(out, 'scenes', tag + '.py')
        open(script, 'w').write(text)
        png = os.path.join(out, tag + '.png')
        ok = export(args.app, exe, script, png, size, args.rt)
        print('[%d/%d] %s %s' % (n, len(jobs), tag, 'ok' if ok else 'FAILED'),
              flush=True)

    if args.sweeps:
        return
    rows = []
    for bg in bgs:
        for rep in reps:
            cells = ''.join(
                '<td><img src="%s_%s_%s.png"><br>%s</td>' % (
                    rep, bg, p, html.escape(p)) for p in presets)
            rows.append('<tr><th>%s<br>%s</th>%s</tr>' % (rep, bg, cells))
    with open(os.path.join(out, 'index.html'), 'w') as handle:
        handle.write('<html><body style="background:#222;color:#ddd;'
                     'font-family:sans-serif"><table>%s</table>'
                     '</body></html>' % ''.join(rows))


if __name__ == '__main__':
    main()
