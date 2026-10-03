#!/usr/bin/env python3
"""PROTOTYPE: render the per-light studio shadow examples headlessly.

    python3 scripts/studio_lights/shadows.py --app /path/RayMol-studio.app \\
        --out /tmp/studio-shadows [--only redblue]
    python3 scripts/studio_lights/shadows.py --sheet /tmp/studio-shadows
"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import placement  # noqa: E402  (BASE scene, export helper)

_RED = 'red: az=-75 el=30 dist=3 beam=55 soft=0.4 rgb=1/0.18/0.1 int=1.9 spec=0.7'
_BLUE = 'blue: az=75 el=-15 dist=3 beam=55 soft=0.4 rgb=0.15/0.4/1 int=2.1 spec=0.7'

EXAMPLES = [
    ('redblue_none', 'Red + blue, no shadows', '%s | %s ambient=0.05' % (_RED, _BLUE)),
    ('redblue_red', 'Red casts a shadow; blue still lights it',
     '%s shadow=1 | %s ambient=0.05' % (_RED, _BLUE)),
    ('redblue_both', 'Both cast shadows: each shadow is lit by the other colour',
     '%s shadow=1 | %s shadow=1 ambient=0.05' % (_RED, _BLUE)),
    ('crossed', 'Red front-left + blue front-right, both shadowed: coloured shadows',
     'red: az=-40 el=25 dist=3 beam=55 soft=0.4 rgb=1/0.25/0.15 int=1.6 spec=0.6 '
     'shadow=1 | blue: az=40 el=10 dist=3 beam=55 soft=0.4 rgb=0.2/0.45/1 '
     'int=1.8 spec=0.6 shadow=1 ambient=0.05'),
    ('three_point', 'Three-point, key + rim + top all shadowed',
     'key: az=-45 el=35 dist=3 beam=45 soft=0.5 kelvin=4300 int=1.8 spec=0.8 shadow=1 | '
     'fill: az=55 el=5 beam=90 soft=1 kelvin=8500 int=0.3 spec=0.1 | '
     'rim: az=160 el=35 dist=3 beam=40 soft=0.4 kelvin=7000 int=1.8 spec=1 shadow=1 | '
     'top: az=0 el=80 dist=3 beam=25 soft=0.4 int=1.2 spec=0.6 shadow=1 ambient=0.05'),
    ('spot_shafts', 'One shadowed spot + haze: shafts from the lamp',
     'spot: az=-55 el=45 dist=3 beam=35 soft=0.4 kelvin=5200 int=2.2 spec=0.9 '
     'shadow=1 | fill: az=40 el=-10 beam=100 soft=1 kelvin=8000 int=0.12 spec=0 '
     'ambient=0.04 haze=0.5 dust=0.4 dust_speed=0'),
    ('redblue_shafts', 'Red + blue both shadowed, with haze: two sets of shafts',
     '%s shadow=1 | %s shadow=1 ambient=0.04 haze=0.35 dust=0.3 dust_speed=0'
     % (_RED, _BLUE)),
]


def render(args):
    from render import bundle_id, export
    out = os.path.abspath(args.out)
    ident, exe = bundle_id(args.app)
    if ident == 'io.raymol.RayMol':
        sys.exit('give the app copy its own CFBundleIdentifier')
    os.makedirs(os.path.join(out, 'scenes'), exist_ok=True)
    pdb = os.path.join(placement.ROOT, 'testing', 'data', '1rx1.pdb')
    base = placement.BASE.format(pdb=pdb, view=placement.VIEW)
    jobs = [(name, base + 'cmd.studio(%r)\n' % spec)
            for name, _title, spec in EXAMPLES
            if not args.only or any(name.startswith(o)
                                    for o in args.only.split(','))]
    warm = os.path.join(out, 'scenes', '_warm.py')
    open(warm, 'w').write(jobs[0][1])
    size = list(placement.SIZE)
    export(args.app, exe, warm, os.path.join(out, '_warm.png'), size, args.rt)
    for n, (tag, text) in enumerate(jobs, 1):
        script = os.path.join(out, 'scenes', tag + '.py')
        open(script, 'w').write(text)
        ok = export(args.app, exe, script, os.path.join(out, tag + '.png'),
                    size, args.rt)
        print('[%d/%d] %s %s' % (n, len(jobs), tag, 'ok' if ok else 'FAILED'),
              flush=True)


def sheet(out):
    from PIL import Image, ImageDraw
    from placement_sheet import font
    tw, th, lh, cols = 640, 480, 30, 2
    rows = (len(EXAMPLES) + cols - 1) // cols
    img = Image.new('RGB', (cols * tw, rows * (th + lh)), (24, 24, 26))
    d = ImageDraw.Draw(img)
    f = font(17)
    for i, (name, title, _spec) in enumerate(EXAMPLES):
        path = os.path.join(out, name + '.png')
        if not os.path.exists(path):
            continue
        x, y = (i % cols) * tw, (i // cols) * (th + lh)
        d.text((x + 10, y + 6), title, fill=(235, 235, 235), font=f)
        img.paste(Image.open(path).convert('RGB').resize((tw, th),
                                                         Image.LANCZOS),
                  (x, y + lh))
    dest = os.path.join(out, 'sheet_shadows.png')
    img.save(dest)
    print(dest)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--app')
    ap.add_argument('--out')
    ap.add_argument('--only', default='')
    ap.add_argument('--rt', type=int, default=-1,
                    help='Metal ray tracing: -1 app setting (on), 0 off, 1 on')
    ap.add_argument('--sheet')
    args = ap.parse_args()
    if args.sheet:
        sheet(args.sheet)
    else:
        render(args)


if __name__ == '__main__':
    main()
