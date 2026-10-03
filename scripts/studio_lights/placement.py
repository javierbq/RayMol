#!/usr/bin/env python3
"""PROTOTYPE: render the light-PLACEMENT examples headlessly.

    python3 scripts/studio_lights/placement.py --app /path/RayMol-studio.app \\
        --out /tmp/studio-placement [--only check,target_ligand]

Each example renders up to three images: the shot with beam cues (outline of
each beam on the geometry), the same shot as a final image (cues off), and an
overview from further out with the rig gizmo (lights, cones, camera, and for
click placements the view ray and surface normal). World-anchored lights stay
fixed to the molecule, so the overview shows the same lighting from outside.
"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, os.pardir, os.pardir))
sys.path.insert(0, os.path.join(ROOT, 'scripts', 'materials_gallery'))
from render import bundle_id, export  # noqa: E402

SIZE = (800, 600)
ASPECT = SIZE[0] / float(SIZE[1])

BASE = '''from pymol import cmd, util
cmd.reinitialize()
cmd.load({pdb!r}, "m")
cmd.remove("solvent or inorganic")
cmd.hide("everything")
cmd.show("surface", "m and polymer")
cmd.color("grey90", "m and polymer")
cmd.show("sticks", "resn NAP")
util.cbay("resn NAP")
cmd.select("nap", "resn NAP")
cmd.select("nterm", "polymer and resi 1-25")
cmd.select("cterm", "polymer and resi 135-159")
cmd.deselect()
cmd.set("bg_rgb", [0.05, 0.05, 0.06])
cmd.set("depth_cue", 0)
cmd.set("ray_opaque_background", 1)
cmd.set("metal_dof", 0)
cmd.set("metal_temporal_ao", 0)
cmd.set("cgo_line_width", 3)
cmd.orient("m and polymer")
{view}
'''

# Turns the NADPH toward the camera (found with the `look` job below).
VIEW = 'cmd.turn("y", -25)'

# A studio floor plan: looking down on the set (camera at the bottom), with
# the ambient raised so the molecule reads from up there. Lighting is
# otherwise the shot's: world-anchored lights stay with the molecule.
OVERVIEW = '''cmd.studio("gizmo")
cmd.turn("x", 70)
cmd.zoom("studio_rig", 6, complete=1)
cmd.set("ambient", 0.3)
'''


def click(sx, sy):
    return 'click=%g/%g aspect=%.4f' % (sx, sy, ASPECT)


EXAMPLES = {
    # Sanity check: the same light, camera rig vs world-anchored target=.
    'check_camera': ('', 'k: az=-60 el=25 dist=3 beam=60 soft=0.3 int=1.5 '
                         'cue=1 shadow=1 ambient=0.06', False),
    'check_world': ('', 'k: target=polymer az=-60 el=25 dist=3 beam=60 '
                        'soft=0.3 int=1.5 cue=1 shadow=1 ambient=0.06', False),
    # Aim at a selection: a warm spot fitted to the NADPH, a dim cool fill.
    'target_ligand': ('', 'key: target=nap az=-35 el=40 dist=3 kelvin=4300 '
                          'int=1.9 spec=0.8 soft=0.45 cue=1 shadow=1 | '
                          'fill: target=polymer az=45 el=10 beam=100 soft=1 '
                          'kelvin=9000 int=0.22 spec=0.1 ambient=0.05', True),
    # Two targets, two colours, from opposite sides.
    'two_targets': ('', 'red: target=nterm az=-70 el=30 dist=3 '
                        'rgb=1/0.15/0.08 int=1.8 spec=0.7 soft=0.5 cue=1 '
                        'shadow=1 | blue: target=cterm az=110 el=-30 dist=3 '
                        'rgb=0.15/0.4/1 int=2.0 spec=0.7 soft=0.5 cue=1 | '
                        'fill: target=polymer az=0 el=0 beam=100 soft=1 '
                        'int=0.12 spec=0 ambient=0.04', True),
    # Click to place the highlight: near the middle (gives a key light) ...
    'click_center': ('', 'pin: %s dist=3 focus=12 kelvin=5600 int=1.7 '
                         'spec=1.4 soft=0.5 cue=1 shadow=1 | fill: '
                         'target=polymer az=40 el=-10 beam=100 soft=1 '
                         'kelvin=8000 int=0.2 spec=0 ambient=0.05'
                     % click(0.08, 0.12), True),
    # ... and near the silhouette, with the rim rule (light ~145 degrees
    # from the camera on the clicked side).
    'click_edge': ('', 'pin: %s rim=145 dist=3 focus=16 kelvin=7000 int=2.4 spec=1.4 '
                       'soft=0.5 cue=1 | fill: target=polymer az=-30 el=20 '
                       'beam=100 soft=1 kelvin=4500 int=0.35 spec=0 shadow=1 '
                       'ambient=0.05' % click(-0.78, 0.05), True),
}

# Dragging: the highlight follows the cursor across the molecule.
for i, sx in enumerate((-0.55, -0.2, 0.15, 0.5)):
    EXAMPLES['drag_%d' % i] = (
        '', 'pin: %s dist=3 focus=10 kelvin=5600 int=1.8 spec=1.4 soft=0.5 '
            'cue=1 shadow=1 | fill: target=polymer az=40 el=-10 beam=100 '
            'soft=1 kelvin=8000 int=0.18 spec=0 ambient=0.05'
        % click(sx, 0.1), False)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--app', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--only', default='')
    ap.add_argument('--look', action='store_true',
                    help='also render the plain scene (default lighting)')
    ap.add_argument('--rig-only', action='store_true',
                    help='render only the rig (overview) images')
    args = ap.parse_args()
    out = os.path.abspath(args.out)
    ident, exe = bundle_id(args.app)
    if ident == 'io.raymol.RayMol':
        sys.exit('give the app copy its own CFBundleIdentifier')
    os.makedirs(os.path.join(out, 'scenes'), exist_ok=True)
    pdb = os.path.join(ROOT, 'testing', 'data', '1rx1.pdb')
    base = BASE.format(pdb=pdb, view=VIEW)

    jobs = []
    if args.look:
        jobs.append(('look', base))
    for name, (extra, spec, overview) in EXAMPLES.items():
        if args.only and not any(name.startswith(o) for o in args.only.split(',')):
            continue
        shot = base + extra + 'cmd.studio(%r)\n' % spec
        if not args.rig_only:
            jobs.append((name + '_cues', shot))
            if not name.startswith(('check', 'drag')):
                jobs.append((name + '_final', shot + 'cmd.studio("cue off")\n'))
        if overview:
            jobs.append((name + '_rig', shot + OVERVIEW))

    warm = os.path.join(out, 'scenes', '_warm.py')
    open(warm, 'w').write(jobs[0][1])
    export(args.app, exe, warm, os.path.join(out, '_warm.png'), list(SIZE), 0)
    for n, (tag, text) in enumerate(jobs, 1):
        script = os.path.join(out, 'scenes', tag + '.py')
        open(script, 'w').write(text)
        ok = export(args.app, exe, script, os.path.join(out, tag + '.png'),
                    list(SIZE), 0)
        print('[%d/%d] %s %s' % (n, len(jobs), tag, 'ok' if ok else 'FAILED'),
              flush=True)


if __name__ == '__main__':
    main()
