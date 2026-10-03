#!/usr/bin/env python3
"""PROTOTYPE: contact sheets (one per representation) from render.py output.

    python3 scripts/studio_lights/sheet.py /tmp/studio-gallery [--bg dark]

Needs Pillow. Writes sheet_<rep>_<bg>.png next to the renders.
"""
import argparse
import importlib.util
import os
import sys

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
# Loaded under another name: render.py itself imports the materials gallery's
# render module as `render`.
_spec = importlib.util.spec_from_file_location(
    'studio_render', os.path.join(HERE, 'render.py'))
_render = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_render)
PRESETS, REPS, SWEEPS = _render.PRESETS, _render.REPS, _render.SWEEPS


def font(size):
    for path in ('/System/Library/Fonts/SFNS.ttf',
                 '/System/Library/Fonts/Helvetica.ttc'):
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            pass
    return ImageFont.load_default()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('out')
    ap.add_argument('--bg', default='dark')
    ap.add_argument('--cols', type=int, default=4)
    ap.add_argument('--tile', default='480x360')
    ap.add_argument('--sweeps', default='',
                    help='one row per sweep instead of the preset sheets')
    ap.add_argument('--rep', default='surface', help='rep for --sweeps')
    args = ap.parse_args()
    tw, th = (int(x) for x in args.tile.split('x'))
    label_h = 30
    f = font(20)
    if args.sweeps and ',' in args.rep:
        # one sweep, one row per representation
        sweep, reps = args.sweeps, args.rep.split(',')
        cols = len(SWEEPS[sweep])
        sheet = Image.new('RGB', (cols * tw, len(reps) * (th + label_h)),
                          (24, 24, 26))
        draw = ImageDraw.Draw(sheet)
        for r, rep in enumerate(reps):
            for c, (label, _spec) in enumerate(SWEEPS[sweep]):
                path = os.path.join(args.out, 'sweep_%s_%d_%s.png' % (
                    sweep, c, rep))
                if not os.path.exists(path):
                    continue
                x, y = c * tw, r * (th + label_h)
                img = Image.open(path).convert('RGB').resize((tw, th),
                                                             Image.LANCZOS)
                sheet.paste(img, (x, y + label_h))
                draw.text((x + 10, y + 4), label, fill=(230, 230, 230), font=f)
        dest = os.path.join(args.out, 'sheet_%s.png' % sweep)
        sheet.save(dest)
        print(dest)
        return
    if args.sweeps:
        sweeps = args.sweeps.split(',')
        cols = max(len(SWEEPS[w]) for w in sweeps)
        sheet = Image.new('RGB', (cols * tw, len(sweeps) * (th + label_h)),
                          (24, 24, 26))
        draw = ImageDraw.Draw(sheet)
        for r, sweep in enumerate(sweeps):
            for c, (label, _spec) in enumerate(SWEEPS[sweep]):
                path = os.path.join(args.out, 'sweep_%s_%d_%s.png' % (
                    sweep, c, args.rep))
                if not os.path.exists(path):
                    continue
                x, y = c * tw, r * (th + label_h)
                img = Image.open(path).convert('RGB').resize((tw, th),
                                                             Image.LANCZOS)
                sheet.paste(img, (x, y + label_h))
                draw.text((x + 10, y + 4), '%s: %s' % (sweep, label),
                          fill=(230, 230, 230), font=f)
        dest = os.path.join(args.out, 'sheet_sweeps_%s.png' % args.rep)
        sheet.save(dest)
        print(dest)
        return
    for rep in REPS:
        tiles = [(p, os.path.join(args.out, '%s_%s_%s.png' % (rep, args.bg, p)))
                 for p in PRESETS]
        tiles = [(p, path) for p, path in tiles if os.path.exists(path)]
        if not tiles:
            continue
        rows = (len(tiles) + args.cols - 1) // args.cols
        sheet = Image.new('RGB', (args.cols * tw, rows * (th + label_h)),
                          (24, 24, 26))
        draw = ImageDraw.Draw(sheet)
        for i, (preset, path) in enumerate(tiles):
            x, y = (i % args.cols) * tw, (i // args.cols) * (th + label_h)
            img = Image.open(path).convert('RGB').resize((tw, th), Image.LANCZOS)
            sheet.paste(img, (x, y + label_h))
            name = 'off (current lighting)' if preset == 'off' else preset
            draw.text((x + 10, y + 4), name, fill=(230, 230, 230), font=f)
        dest = os.path.join(args.out, 'sheet_%s_%s.png' % (rep, args.bg))
        sheet.save(dest)
        print(dest)


if __name__ == '__main__':
    main()
