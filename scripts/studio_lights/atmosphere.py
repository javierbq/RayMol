#!/usr/bin/env python3
"""PROTOTYPE: render the studio-atmosphere examples (haze + dust) headlessly.

    python3 scripts/studio_lights/atmosphere.py --app /path/RayMol-studio.app \\
        --out /tmp/studio-atmosphere [--only beam,backlit]

Then a contact sheet (needs Pillow):

    python3 scripts/studio_lights/atmosphere.py --sheet /tmp/studio-atmosphere
"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import placement  # noqa: E402  (BASE scene, export helper)

SPOT = ('spot: target=polymer az=-50 el=45 dist=3 beam=30 soft=0.45 '
        'kelvin=5200 int=2.0 spec=0.9 shadow=1 | fill: target=polymer az=40 '
        'el=-10 beam=100 soft=1 kelvin=8000 int=0.12 spec=0 ambient=0.04')

EXAMPLES = [
    ('beam_none', 'Spot from the upper left: no atmosphere', SPOT),
    ('beam_haze', '+ haze=0.6: the beam shows in the air, the molecule '
                  'shadows it', SPOT + ' haze=0.6'),
    ('beam_dust', '+ dust=0.6: motes glint inside the beam only',
     SPOT + ' haze=0.6 dust=0.6'),
    ('backlit', 'Backlit: light behind, toward the camera -> glow and shafts',
     'back: target=polymer az=165 el=18 dist=3 beam=50 soft=0.5 kelvin=6500 '
     'int=2.2 spec=1 shadow=1 | front: target=polymer az=0 el=0 beam=100 '
     'soft=1 kelvin=4000 int=0.12 spec=0 ambient=0.03 haze=0.18 dust=0.5 '
     'scatter=0.55'),
    ('crossing', 'Red and blue beams crossing; dust takes the colour of the '
                 'beam it is in',
     'red: target=polymer az=-80 el=25 dist=3 beam=28 soft=0.4 '
     'rgb=1/0.15/0.08 int=2.2 spec=0.7 shadow=1 | blue: target=polymer '
     'az=100 el=-25 dist=3 beam=28 soft=0.4 rgb=0.15/0.4/1 int=2.4 spec=0.7 '
     'ambient=0.03 haze=0.35 dust=0.8'),
    ('dust_only', 'Dust only, no haze: just the motes in a narrow beam',
     'spot: target=polymer az=-30 el=35 dist=3 beam=22 soft=0.35 '
     'kelvin=4800 int=2.0 spec=0.9 shadow=1 ambient=0.04 dust=1.0 '
     'dust_size=0.45'),
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
    export(args.app, exe, warm, os.path.join(out, '_warm.png'), size, 0)
    for n, (tag, text) in enumerate(jobs, 1):
        script = os.path.join(out, 'scenes', tag + '.py')
        open(script, 'w').write(text)
        ok = export(args.app, exe, script, os.path.join(out, tag + '.png'),
                    size, 0)
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
    dest = os.path.join(out, 'sheet_atmosphere.png')
    img.save(dest)
    print(dest)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--app')
    ap.add_argument('--out')
    ap.add_argument('--only', default='')
    ap.add_argument('--sheet', help='build the contact sheet for this dir')
    args = ap.parse_args()
    if args.sheet:
        sheet(args.sheet)
    else:
        render(args)


if __name__ == '__main__':
    main()
