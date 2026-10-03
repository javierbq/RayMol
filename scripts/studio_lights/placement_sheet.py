#!/usr/bin/env python3
"""PROTOTYPE: contact sheets for placement.py's renders (needs Pillow).

    python3 scripts/studio_lights/placement_sheet.py /tmp/studio-placement

Writes sheet_placement.png (one row per example: with cues / final / rig) and
sheet_drag.png (the click-and-drag sequence).
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFont

ROWS = [
    ('target_ligand', 'Aim at a selection: target=nap, beam=fit'),
    ('two_targets', 'Two targets: N-terminus red, C-terminus blue'),
    ('click_center', 'Click to place the highlight: near the middle -> key'),
    ('click_edge', 'Click near the silhouette with rim=145 -> rim light on that edge'),
]
COLS = [('cues', 'beam cues on'), ('final', 'final (cues off)'),
        ('rig', 'rig view: lights, cones, camera')]
TW, TH, LH, HH = 480, 360, 28, 34


def font(size):
    for path in ('/System/Library/Fonts/SFNS.ttf',
                 '/System/Library/Fonts/Helvetica.ttc'):
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            pass
    return ImageFont.load_default()


def tile(out, name):
    path = os.path.join(out, name + '.png')
    if not os.path.exists(path):
        return None
    return Image.open(path).convert('RGB').resize((TW, TH), Image.LANCZOS)


def main():
    out = sys.argv[1]
    f, fh = font(18), font(22)
    sheet = Image.new('RGB', (len(COLS) * TW, len(ROWS) * (HH + LH + TH)),
                      (24, 24, 26))
    d = ImageDraw.Draw(sheet)
    for r, (name, title) in enumerate(ROWS):
        y = r * (HH + LH + TH)
        d.text((10, y + 6), title, fill=(240, 240, 240), font=fh)
        for c, (suffix, label) in enumerate(COLS):
            img = tile(out, '%s_%s' % (name, suffix))
            if img is None:
                continue
            d.text((c * TW + 10, y + HH + 4), label, fill=(180, 180, 180), font=f)
            sheet.paste(img, (c * TW, y + HH + LH))
    sheet.save(os.path.join(out, 'sheet_placement.png'))

    drag = [tile(out, 'drag_%d_cues' % i) for i in range(4)]
    strip = Image.new('RGB', (4 * TW, HH + TH), (24, 24, 26))
    d = ImageDraw.Draw(strip)
    d.text((10, 6), 'Drag: click=sx/0.1 for sx = -0.55, -0.2, 0.15, 0.5 -- the '
           'highlight (and the beam) follow the cursor', fill=(240, 240, 240),
           font=fh)
    for i, img in enumerate(drag):
        if img is not None:
            strip.paste(img, (i * TW, HH))
    strip.save(os.path.join(out, 'sheet_drag.png'))
    print(os.path.join(out, 'sheet_placement.png'))
    print(os.path.join(out, 'sheet_drag.png'))


if __name__ == '__main__':
    main()
