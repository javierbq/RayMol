#!/usr/bin/env python3
"""PROTOTYPE: every material under every studio-lighting setup (Metal).

    python3 scripts/studio_lights/material_gallery.py --app /path/RayMol-studio.app \\
        --out /tmp/studio-materials [--materials matte,glass] [--lights softbox]
    python3 scripts/studio_lights/material_gallery.py --sheet /tmp/studio-materials

The molecular surface carries the material; a blue cartoon and the NADPH
(yellow sticks) sit inside it, so the glass family has something to show.
material_env=1 (studio): against the black backdrop the reflective
materials would otherwise reflect black.
One `open -n` per image (see scripts/materials_gallery/render.py). --sheet
writes sheet_materials.png and index.html (needs Pillow).
"""
import argparse
import html
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, os.pardir, os.pardir))
sys.path.insert(0, os.path.join(ROOT, 'scripts', 'materials_gallery'))
sys.path.insert(1, HERE)

SIZE = (800, 600)

MATERIALS = ['default', 'matte', 'plastic', 'metallic', 'glass',
             'frosted_glass', 'jelly', 'marble', 'clay', 'rubber']

_SPOT = ('spot: target=polymer az=-50 el=45 dist=3 beam=30 soft=0.45 '
         'kelvin=5200 int=2.0 spec=0.9 shadow=1 | fill: target=polymer az=40 '
         'el=-10 beam=100 soft=1 kelvin=8000 int=0.12 spec=0 ambient=0.04')

LIGHTS = [
    ('softbox', 'softbox', 'softbox'),
    ('three_point', 'three-point', 'three_point'),
    ('spot_dust', 'spot + haze + dust', _SPOT + ' haze=0.3 dust=0.6'),
    ('redblue_dust', 'red / blue + dust',
     'red: target=polymer az=-80 el=25 dist=3 beam=28 soft=0.4 '
     'rgb=1/0.15/0.08 int=2.2 spec=0.7 shadow=1 | blue: target=polymer '
     'az=100 el=-25 dist=3 beam=28 soft=0.4 rgb=0.15/0.4/1 int=2.4 spec=0.7 '
     'ambient=0.03 haze=0.25 dust=0.7'),
    ('backlit', 'backlit + haze',
     'back: target=polymer az=165 el=18 dist=3 beam=50 soft=0.5 kelvin=6500 '
     'int=2.2 spec=1 shadow=1 | front: target=polymer az=0 el=0 beam=100 '
     'soft=1 kelvin=4000 int=0.18 spec=0.2 ambient=0.04 haze=0.12 dust=0.5 '
     'scatter=0.55'),
]

SCENE = '''from pymol import cmd, util
cmd.reinitialize()
cmd.load({pdb!r}, "m")
cmd.remove("solvent or inorganic")
cmd.hide("everything")
cmd.show("cartoon", "m and polymer")
cmd.color("skyblue", "m and polymer")
cmd.show("surface", "m and polymer")
cmd.set("surface_color", "grey85", "m")
cmd.show("sticks", "resn NAP")
util.cbay("resn NAP")
cmd.set("surface_material", {material!r}, "m")
cmd.set("material_env", 1)   # reflective materials reflect the studio, not the black backdrop
cmd.set("bg_rgb", [0.05, 0.05, 0.06])
cmd.set("depth_cue", 0)
cmd.set("ray_opaque_background", 1)
cmd.set("metal_dof", 0)
cmd.set("metal_temporal_ao", 0)
cmd.orient("m and polymer")
cmd.turn("y", -25)
cmd.studio({studio!r})
'''


def render(args):
    from render import bundle_id, export
    out = os.path.abspath(args.out)
    ident, exe = bundle_id(args.app)
    if ident == 'io.raymol.RayMol':
        sys.exit('give the app copy its own CFBundleIdentifier')
    os.makedirs(os.path.join(out, 'scenes'), exist_ok=True)
    pdb = os.path.join(ROOT, 'testing', 'data', '1rx1.pdb')
    mats = args.materials.split(',') if args.materials else MATERIALS
    lights = [l for l in LIGHTS
              if not args.lights or l[0] in args.lights.split(',')]
    jobs = [('%s__%s' % (m, key), SCENE.format(pdb=pdb, material=m, studio=spec))
            for m in mats for key, _label, spec in lights]
    warm = os.path.join(out, 'scenes', '_warm.py')
    open(warm, 'w').write(jobs[0][1])
    export(args.app, exe, warm, os.path.join(out, '_warm.png'), list(SIZE), 0)
    failed = []
    for n, (tag, text) in enumerate(jobs, 1):
        script = os.path.join(out, 'scenes', tag + '.py')
        open(script, 'w').write(text)
        png = os.path.join(out, tag + '.png')
        ok = export(args.app, exe, script, png, list(SIZE), 0)
        if ok and os.path.getsize(png) < 20000:   # a scene that never ran
            ok = False
        print('[%d/%d] %s %s' % (n, len(jobs), tag, 'ok' if ok else 'FAILED'),
              flush=True)
        if not ok:
            failed.append(tag)
    if failed:
        sys.exit('failed: ' + ', '.join(failed))


def sheet(out):
    from PIL import Image, ImageDraw
    from placement_sheet import font
    tw, th, head, side, gap = 384, 288, 44, 150, 4
    f, fh = font(18), font(20)
    img = Image.new('RGB', (side + len(LIGHTS) * tw,
                            head + len(MATERIALS) * (th + gap)), (24, 24, 26))
    d = ImageDraw.Draw(img)
    for c, (_key, label, _spec) in enumerate(LIGHTS):
        d.text((side + c * tw + 10, 12), label, fill=(240, 240, 240), font=fh)
    for r, m in enumerate(MATERIALS):
        y = head + r * (th + gap)
        d.text((12, y + th // 2 - 10), m, fill=(240, 240, 240), font=fh)
        for c, (key, _label, _spec) in enumerate(LIGHTS):
            path = os.path.join(out, '%s__%s.png' % (m, key))
            if os.path.exists(path):
                img.paste(Image.open(path).convert('RGB').resize(
                    (tw, th), Image.LANCZOS), (side + c * tw, y))
    dest = os.path.join(out, 'sheet_materials.png')
    img.save(dest)
    # index.html: the same grid at full resolution, click to open an image
    rows = []
    for m in MATERIALS:
        cells = ''.join('<td><a href="%s__%s.png"><img src="%s__%s.png"></a></td>'
                        % (m, k, m, k) for k, _l, _s in LIGHTS)
        rows.append('<tr><th>%s</th>%s</tr>' % (html.escape(m), cells))
    header = ''.join('<th>%s</th>' % html.escape(l) for _k, l, _s in LIGHTS)
    page = ('<!doctype html><meta charset="utf-8"><title>Studio lights x '
            'materials</title><style>body{background:#18181a;color:#ddd;'
            'font-family:-apple-system,sans-serif;margin:16px}'
            'table{border-collapse:collapse}th{padding:6px 10px;text-align:left;'
            'font-weight:600}td{padding:2px}img{width:320px;display:block}'
            'thead th{position:sticky;top:0;background:#18181a}</style>'
            '<h2>Studio lights &times; materials (prototype, Metal)</h2>'
            '<p>Rows: <code>surface_material</code>. Columns: <code>studio</code> '
            'setups. Click an image for full size.</p>'
            '<table><thead><tr><th></th>%s</tr></thead>%s</table>'
            % (header, ''.join(rows)))
    open(os.path.join(out, 'index.html'), 'w').write(page)
    print(dest)
    print(os.path.join(out, 'index.html'))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--app')
    ap.add_argument('--out')
    ap.add_argument('--materials', default='')
    ap.add_argument('--lights', default='')
    ap.add_argument('--sheet')
    args = ap.parse_args()
    if args.sheet:
        sheet(args.sheet)
    else:
        render(args)


if __name__ == '__main__':
    main()
