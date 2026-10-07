#!/usr/bin/env python3
"""The studio lights gallery (#627): every section of docs/lighting.md's
pictures, rendered headless with a built RayMol.app through the lighting
harness (scripts/lighting/render.py, unmodified).

Seven sections, each a list of harness tags from one scene file:

    rigs       PyMOL's own lights, then each preset          scenes/gallery.json
    light      one light field at a time                     scenes/gallery.json
    place      target=, highlight= and rim=, camera vs pin   scenes/gallery.json
    shadows    per-light coloured shadows, raster and traced scenes/gallery.json
    air        haze, dust and shafts; the pinned dust clock  scenes/gallery.json
    exposure   HDR roll-off, exposure and the 8-bit knee     scenes/lighting_624.json
    materials  every material under three_point              scenes/lighting_615_gallery.json

SECTIONS below is the one table: per section its title, the caption (the
commands it shows), the scene file, the tags in sheet order, the sheet's
columns, the reference pairs its difference checks compare (tag, reference)
and the per-pair overrides of those checks, each with its reason.

Names never contain 'preset' (it holds 'reset', a word the harness refuses
in any path, #646): the presets section is `rigs`.

The one command (a RayMol.app with its own bundle id; Pillow and numpy):

    gallery.py --app APP --out DIR [--sections a,b] [--timeout N]
    gallery.py --out DIR --dry-run [--sections a,b]
    gallery.py --out DIR --skip-render [--sections a,b]

  1. Validate everything first: --out, every scene file, stem directory, tag,
     scene script, image and sheet path pass render.check_path; every section's
     tags load from its scene file (render.scene_file_jobs + select); the app
     passes render.check_app. A refusal exits 2 and deletes nothing.
  2. Clear only the requested sections: their <tag>.png files and their sheet.
  3. Render: one render.main call per scene file, --only the requested
     sections' tags, into DIR/<scene file stem>/ (so a full run is three calls
     and three warm-ups). render.py's exit 2 stops the run; its exit 1 is
     recorded and the run goes on.
  4. Assemble every section in SECTIONS: DIR/<section>.png (a caption row,
     then the images in SECTIONS order, `cols` wide), the difference checks,
     DIR/index.html and DIR/gallery.json (per scene file: render.json's app
     sha and render.py sha256 against HEAD, a mismatch flagged).

--dry-run writes every scene script (render.py --dry-run), prints the
render.py argument lists the run would use (the per-file `gate.sh render`
route) and launches nothing; it needs no --app. --skip-render only assembles
(step 4), from images already on disk: it is what follows `gate.sh render`.

Assembly: a requested section (every section in a full run or a plain
--skip-render) must have every image, or it fails. A section not requested
and absent from disk is listed as 'not rendered' and does not fail; one not
requested but on disk is assembled and checked from disk. A tag render.json
lists as failed fails its section even if a PNG was left behind.

Difference checks (D5): each reference pair (tag, ref) must differ in at
least `share` of its pixels by more than `level` (of 255, any of R, G, B),
by default 0.5 % beyond 8 levels; a pair's override in the section's
`overrides` replaces either value and records why. This catches a command
the renderer silently ignored; nothing judged by eye is automated.

Exit codes: 0 every requested section rendered and every check passed;
1 an image or a check failed; 2 a refusal or a usage error.
"""
import argparse
import collections
import datetime
import html
import importlib.util
import json
import os
import subprocess
import sys
import textwrap

HERE = os.path.dirname(os.path.abspath(__file__))
SCENES_DIR = os.path.join(HERE, 'scenes')

Section = collections.namedtuple('Section', (
    'name',       # section name: the sheet is <out>/<name>.png
    'title',      # the sheet's heading
    'caption',    # the commands the section shows
    'scenes',     # scene file, relative to scripts/lighting/scenes
    'tags',       # harness tags, in sheet order
    'cols',       # sheet columns
    'refs',       # ((tag, reference tag), ...): the pair must differ
    'overrides',  # {(tag, reference tag): {'level': n, 'share': f, 'reason': text}}
))

PRESET_NAMES = ('three_point', 'softbox', 'spotlight', 'rembrandt', 'neon',
                'sunset', 'underlight')
MATERIALS = ('default', 'matte', 'plastic', 'metallic', 'glass',
             'frosted_glass', 'jelly', 'marble', 'clay', 'rubber')


def _rows(*rows):
    """Consecutive pairs within each row: (b, a), (c, b), ..."""
    return tuple((row[i], row[i - 1]) for row in rows for i in range(1, len(row)))


_LIGHT_ROWS = (
    ('light_beam_8', 'light_beam_15', 'light_beam_28'),
    ('light_soft_0', 'light_soft_0p5', 'light_soft_1'),
    ('light_warm_2200', 'light_warm_6500', 'light_warm_12000'),
    ('light_colour_white', 'light_colour_orange', 'light_colour_hotpink'),
)

SECTIONS = [
    Section(
        'rigs', 'Presets',
        "lights <preset>: PyMOL's own lights (no rig), then three_point, "
        'softbox, spotlight, rembrandt, neon, sunset and underlight',
        'gallery.json',
        ('rig_none',) + tuple('rig_' + p for p in PRESET_NAMES),
        4,
        tuple(('rig_' + p, 'rig_none') for p in PRESET_NAMES),
        {}),
    Section(
        'light', 'One light, one field at a time',
        'lights add, key, orbit=-25, pitch=35, radius=3, intensity=1.5, '
        'shadow=1 and, by row: beam=8/15/28 (softness=0.3); softness=0/0.5/1 '
        '(beam=15); warmth=2200/6500/12000; color=white/orange/hotpink with '
        'a white/skyblue/cyan rim at orbit=160',
        'gallery.json',
        sum(_LIGHT_ROWS, ()),
        3,
        _rows(*_LIGHT_ROWS),
        {}),
    Section(
        'place', 'Placing a light',
        'lights add, key, target=<sele> (outline=1, then 0); '
        'lights add, key, highlight=<sele> (then rim=145); '
        "a camera light vs pin=1, then turn y, 90",
        'gallery.json',
        ('place_target', 'place_target_final', 'place_highlight',
         'place_highlight_rim', 'place_camera_turned', 'place_pinned_turned'),
        2,
        (('place_target_final', 'place_target'),
         ('place_highlight_rim', 'place_highlight'),
         ('place_pinned_turned', 'place_camera_turned')),
        {}),
    Section(
        'shadows', 'Per-light shadows',
        'red and blue lights from either side: no shadows, shadow=1 on red, '
        'on both, four lights with three shadowed (the cap), both with '
        'metal_raytrace 1',
        'gallery.json',
        ('shadow_none', 'shadow_red', 'shadow_both', 'shadow_cap',
         'shadow_both_rt1'),
        3,
        (('shadow_red', 'shadow_none'), ('shadow_both', 'shadow_red')),
        {}),
    Section(
        'air', 'Haze and dust',
        'atmosphere haze=0.6, then dust=0.6 (metal_raytrace 0 and 1 side by '
        'side); a backlit haze; crossing red and blue beams; dust alone at '
        'metal_light_air_time 0, 1 and 2',
        'gallery.json',
        ('air_none', 'air_haze', 'air_backlit',
         'air_dust', 'air_dust_rt1', 'air_crossing',
         'air_dust_t0', 'air_dust_t1', 'air_dust_t2'),
        3,
        (('air_haze', 'air_none'), ('air_dust', 'air_haze'),
         ('air_dust_t1', 'air_dust_t0'), ('air_dust_t2', 'air_dust_t1')),
        {('air_dust', 'air_haze'): {
            'share': 0.002,
            'reason': 'dust 0.6 adds sparse motes to the same haze beam: '
                      '0.42% of pixels differ by more than 8 levels in the '
                      'first L2 run (#627 round 1), under the default 0.5%; '
                      '0.2% keeps a 2x margin and still fails a dust value '
                      'the renderer ignored (0%)'}}),
    Section(
        'exposure', 'Exposure and HDR',
        'a spot at intensity 3.5, then metal_exposure 0.5; an orange key and '
        'cyan rim at 2.5x with HDR, then metal_light_hdr 2 (the 8-bit knee); '
        'three_point (its rim behind the molecule) with haze 0.35 and dust '
        '0.6 at metal_exposure 1, then 0.5 (#683)',
        'lighting_624.json',
        ('sweep_3p5_rt0', 'sweep_3p5_e05_rt0', 'hue_x2p5_rt0',
         'hue_x2p5_knee_rt0', 'haze683_e1_rt0', 'haze683_e05_rt0'),
        2,
        (('sweep_3p5_e05_rt0', 'sweep_3p5_rt0'),
         ('hue_x2p5_knee_rt0', 'hue_x2p5_rt0'),
         ('haze683_e05_rt0', 'haze683_e1_rt0')),
        {}),
    Section(
        'materials', 'Materials under three_point',
        'lights three_point over set surface_material, <material> for each '
        'of the ten materials',
        'lighting_615_gallery.json',
        tuple('g%02d_%s__c1_three_point' % (n, m) for n, m in enumerate(MATERIALS)),
        5,
        tuple(('g%02d_%s__c1_three_point' % (n, m), 'g00_default__c1_three_point')
              for n, m in enumerate(MATERIALS) if n),
        {}),
]


def load_render():
    """scripts/lighting/render.py, the frozen harness beside this file."""
    spec = importlib.util.spec_from_file_location(
        'lighting_render', os.path.join(HERE, 'render.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# --- sections and paths -------------------------------------------------------

DIFF_LEVEL = 8        # a pixel differs when a channel moves by more than this
DIFF_SHARE = 0.005    # ... and a pair differs when this share of pixels does
CELL_WIDTH = 480      # the sheet's cell width, as render.sheet
LABEL = 18            # the tag label above each cell, as render.sheet


def section_names():
    return [s.name for s in SECTIONS]


def stem(section):
    """The scene file's stem: render.py's output directory under --out."""
    return os.path.splitext(os.path.basename(section.scenes))[0]


def scene_path(section):
    return os.path.join(SCENES_DIR, section.scenes)


def section_dir(out, section):
    return os.path.join(out, stem(section))


def image_path(out, section, tag):
    return os.path.join(section_dir(out, section), tag + '.png')


def sheet_path(out, section):
    return os.path.join(out, section.name + '.png')


def section_jobs(render, section):
    """{tag: render.Job} for the section's tags, in the section's order.
    Raises render.Refusal when the file does not load or lacks a tag."""
    jobs = render.scene_file_jobs(scene_path(section))
    chosen = {j.tag: j for j in render.select(jobs, list(section.tags),
                                               '%s: tags' % section.name)}
    return collections.OrderedDict((t, chosen[t]) for t in section.tags)


def scene_groups(sections):
    """[(scene file, [tags...])] in SECTIONS order, one entry per file: the
    union of the given sections' tags in that file."""
    groups = collections.OrderedDict()
    for s in sections:
        tags = groups.setdefault(s.scenes, [])
        tags.extend(t for t in s.tags if t not in tags)
    return list(groups.items())


def head_sha(root):
    """`git rev-parse HEAD` of the checkout, or None."""
    try:
        res = subprocess.run(['git', '-C', root, 'rev-parse', 'HEAD'],
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             universal_newlines=True, timeout=20)
    except (OSError, subprocess.SubprocessError):
        return None
    sha = res.stdout.strip()
    return sha if res.returncode == 0 and sha else None


# --- validate first, then clear -----------------------------------------------

def parse_sections(render, value):
    """The requested sections (SECTIONS order), from a comma list or all."""
    if not value:
        return list(SECTIONS)
    asked = [v for v in value.split(',') if v]
    unknown = [v for v in asked if v not in section_names()]
    if unknown or not asked:
        raise render.Refusal('--sections: unknown sections %s (known: %s)' % (
            ', '.join(unknown) or repr(value), ', '.join(section_names())))
    return [s for s in SECTIONS if s.name in asked]


def validate(render, args, sections):
    """Every refusal render.py (or this driver) could raise, raised before
    anything is deleted. Returns {section name: {tag: job}} for EVERY section
    (assembly covers them all) and the app's (bundle id, executable) or None."""
    out = os.path.abspath(args.out)
    render.check_path('--out', out)
    render.check_path('--root', render.DEFAULT_ROOT)
    render.check_root(render.DEFAULT_ROOT)
    jobs = collections.OrderedDict()
    for s in SECTIONS:
        render.check_path('--scenes', os.path.abspath(scene_path(s)))
        render.check_path('stem', section_dir(out, s))
        render.check_path('sheet', sheet_path(out, s))
        jobs[s.name] = section_jobs(render, s)
        for tag in s.tags:
            render.check_path('tag', tag)
            render.check_path('scene script', render.script_path(section_dir(out, s), tag))
            render.check_path('image', image_path(out, s, tag))
    for name in ('index.html', 'gallery.json'):
        render.check_path(name, os.path.join(out, name))
    app_id = None
    if not (args.dry_run or args.skip_render):
        if not args.app:
            raise render.Refusal('--app is required to render (or give '
                                 '--dry-run or --skip-render)')
        app = os.path.abspath(args.app).rstrip('/')
        render.check_path('--app', app)
        app_id = render.check_app(app)
    return jobs, app_id


def clear_section(out, section):
    """Delete only the section's images and its sheet. Returns what went."""
    removed = []
    for path in [image_path(out, section, t) for t in section.tags] + [sheet_path(out, section)]:
        if os.path.isfile(path):
            os.remove(path)
            removed.append(path)
    return removed


# --- rendering -----------------------------------------------------------------

def render_argv(out, scenes, tags, app=None, timeout=None, dry_run=False,
                scenes_dir=SCENES_DIR):
    """render.py's arguments for one scene file (scenes_dir: where the
    scene files are named from; the checkout-relative form for gate.sh)."""
    argv = []
    if app:
        argv += ['--app', app]
    argv += ['--out', os.path.join(out, os.path.splitext(scenes)[0]),
             '--scenes', os.path.join(scenes_dir, scenes), '--only', ','.join(tags)]
    if timeout is not None:
        argv += ['--timeout', str(timeout)]
    if dry_run:
        argv.append('--dry-run')
    return argv


def render_group(render, out, scenes, tags, args):
    """One render.main call for one scene file. Returns its exit code."""
    app = None if args.dry_run else os.path.abspath(args.app).rstrip('/')
    argv = render_argv(out, scenes, tags, app, args.timeout, args.dry_run)
    print('gallery: render.py %s' % ' '.join(argv), flush=True)
    return render.main(argv)


# --- checks --------------------------------------------------------------------

def differs(a, b, level=DIFF_LEVEL, share=DIFF_SHARE):
    """Do two images differ? At least `share` of the pixels must move by more
    than `level` in R, G or B. Arrays (H x W x 3+) or PNG paths. Returns
    {'pass', 'measured', 'level', 'share', 'error'}."""
    import numpy
    result = {'pass': False, 'measured': None, 'level': level, 'share': share,
              'error': None}
    try:
        pa, pb = (_pixels(x) for x in (a, b))
    except Exception as e:   # Pillow raises several types for a bad file
        result['error'] = 'cannot decode: %s' % e
        return result
    if pa.shape[:2] != pb.shape[:2]:
        result['error'] = 'size %dx%d vs %dx%d' % (pa.shape[1], pa.shape[0],
                                                  pb.shape[1], pb.shape[0])
        return result
    diff = numpy.abs(pa[..., :3].astype(numpy.int16) - pb[..., :3].astype(numpy.int16))
    measured = float((diff.max(axis=2) > level).mean())
    result['measured'] = measured
    result['pass'] = measured >= share
    return result


def _pixels(x):
    import numpy
    if isinstance(x, str):
        from PIL import Image
        with Image.open(x) as image:
            return numpy.asarray(image.convert('RGB'))
    return numpy.asarray(x)


def read_render_json(directory):
    path = os.path.join(directory, 'render.json')
    try:
        with open(path) as handle:
            data = json.load(handle)
        return data if isinstance(data, dict) else None
    except (OSError, ValueError):
        return None


def check_section(render, out, section, jobs, requested):
    """The section's images and difference checks, from disk.

    status: 'ok'; 'failed' (an image missing or bad, or a check failed);
    'not rendered' (not requested and none of its images on disk)."""
    info = read_render_json(section_dir(out, section)) or {}
    failed_by_render = set(info.get('failed') or ())
    images = []
    for tag in section.tags:
        path = image_path(out, section, tag)
        entry = {'tag': tag, 'path': os.path.relpath(path, out), 'ok': False,
                 'error': None}
        if not os.path.isfile(path):
            entry['error'] = 'missing'
        else:
            entry['error'] = render.check_image(path, jobs[tag].size)
            if not entry['error'] and tag in failed_by_render:
                entry['error'] = 'render.py reported it failed'
        entry['ok'] = entry['error'] is None
        images.append(entry)
    present = [e for e in images if e['error'] != 'missing']
    result = {'name': section.name, 'title': section.title,
              'caption': section.caption, 'scenes': section.scenes,
              'requested': bool(requested), 'images': images, 'checks': [],
              'sheet': None, 'status': 'ok', 'errors': []}
    if not present and not requested:
        result['status'] = 'not rendered'
        return result
    if not present:
        result['errors'].append('no images in %s' % os.path.relpath(
            section_dir(out, section), out))
    for e in images:
        if not e['ok']:
            result['errors'].append('%s: %s' % (e['tag'], e['error']))
    ok_tags = {e['tag'] for e in images if e['ok']}
    for tag, ref in section.refs:
        override = section.overrides.get((tag, ref), {})
        level = override.get('level', DIFF_LEVEL)
        share = override.get('share', DIFF_SHARE)
        check = {'tag': tag, 'ref': ref, 'level': level, 'share': share,
                 'reason': override.get('reason'), 'measured': None,
                 'pass': False, 'error': None}
        if tag in ok_tags and ref in ok_tags:
            got = differs(image_path(out, section, tag), image_path(out, section, ref),
                          level, share)
            check['measured'], check['error'] = got['measured'], got['error']
            check['pass'] = got['pass']
        else:
            check['error'] = 'not checked: an image is missing or failed'
        if not check['pass']:
            result['errors'].append('%s vs %s: %s' % (
                tag, ref, check['error'] or 'differs in %.4f of pixels by more '
                'than %d levels, needs %.4f' % (check['measured'], level, share)))
        result['checks'].append(check)
    if result['errors']:
        result['status'] = 'failed'
    return result


# --- sheets, index.html, gallery.json -----------------------------------------

def _font(size):
    from PIL import ImageFont
    try:
        return ImageFont.load_default(size=size)
    except (TypeError, AttributeError, OSError):   # Pillow < 10.1, no FreeType
        return ImageFont.load_default()


def _line_height(font):
    box = font.getbbox('Ag')
    return box[3] - box[1]


def write_sheet(out, section, result):
    """DIR/<section>.png: a caption row (title and commands), then the images
    in SECTIONS order, `cols` wide, each under its tag (a missing or failed
    image is a grey cell with the error). None when no image is on disk.
    Returns the layout: {'path', 'header', 'cell': (w, h), 'cols'}."""
    from PIL import Image, ImageDraw
    path = sheet_path(out, section)
    if os.path.isfile(path):
        os.remove(path)
    entries = {e['tag']: e for e in result['images']}
    thumbs = []
    for tag in section.tags:
        e = entries[tag]
        thumb = None
        if e['error'] != 'missing':
            try:
                with Image.open(os.path.join(out, e['path'])) as image:
                    image = image.convert('RGB')
                    height = max(1, round(image.height * CELL_WIDTH / float(image.width)))
                    thumb = image.resize((CELL_WIDTH, height), Image.LANCZOS)
            except Exception:   # Pillow raises several types for a bad file
                thumb = None
        thumbs.append((tag, thumb, e['error']))
    if not any(t for _, t, _ in thumbs):
        return None
    cols = max(1, min(int(section.cols), len(thumbs)))
    rows = (len(thumbs) + cols - 1) // cols
    thumb_h = max(t.height for _, t, _ in thumbs if t)
    cell_h = thumb_h + LABEL
    width = cols * CELL_WIDTH

    title_font, caption_font, label_font = _font(22), _font(15), _font(11)
    probe = ImageDraw.Draw(Image.new('RGB', (1, 1)))
    char_w = max(1.0, probe.textlength('abcdefghij', font=caption_font) / 10.0)
    caption = textwrap.wrap(section.caption, width=max(20, int((width - 16) / char_w)))
    pad, title_h, caption_h = 8, _line_height(title_font), _line_height(caption_font)
    header = pad + title_h + 8 + len(caption) * (caption_h + 5) + pad

    grid = Image.new('RGB', (width, header + rows * cell_h), (255, 255, 255))
    draw = ImageDraw.Draw(grid)
    draw.rectangle((0, 0, width - 1, header - 1), fill=(232, 232, 232))
    draw.text((pad, pad), '%s (%s)' % (section.title, section.name), fill=(0, 0, 0),
              font=title_font)
    y = pad + title_h + 8
    for line in caption:
        draw.text((pad, y), line, fill=(40, 40, 40), font=caption_font)
        y += caption_h + 5
    for i, (tag, thumb, error) in enumerate(thumbs):
        x, y = (i % cols) * CELL_WIDTH, header + (i // cols) * cell_h
        if thumb is not None:
            grid.paste(thumb, (x, y + LABEL))
        else:
            draw.rectangle((x, y + LABEL, x + CELL_WIDTH - 1, y + cell_h - 1),
                           fill=(128, 128, 128))
        label = tag if not error else '%s: %s' % (tag, error)
        draw.text((x + 4, y + 3), label, fill=(0, 0, 0) if not error else (200, 0, 0),
                  font=label_font)
    grid.save(path)
    return {'path': path, 'header': header, 'cell': (CELL_WIDTH, cell_h), 'cols': cols}


def provenance(out, head):
    """Per scene file: render.json's app sha and render.py sha256 against
    HEAD; a mismatch (or an unknown sha) is flagged."""
    files = collections.OrderedDict()
    for s in SECTIONS:
        if stem(s) in files:
            continue
        info = read_render_json(section_dir(out, s))
        entry = {'scenes': s.scenes, 'render_json': None, 'app_sha': None,
                 'render_py_sha256': None, 'tags': [], 'failed': [],
                 'head': head, 'app_sha_matches_head': None, 'flag': None}
        if info is None:
            entry['flag'] = 'no render.json in %s' % stem(s)
        else:
            app_sha = info.get('app_sha')
            entry.update(render_json=os.path.join(stem(s), 'render.json'),
                         app_sha=app_sha,
                         render_py_sha256=info.get('render_py_sha256'),
                         tags=list(info.get('tags') or []),
                         failed=list(info.get('failed') or []))
            if app_sha and head:
                match = app_sha.startswith(head) or head.startswith(app_sha)
                entry['app_sha_matches_head'] = match
                if not match:
                    entry['flag'] = 'app sha %s is not HEAD %s' % (app_sha, head)
            else:
                entry['flag'] = 'app sha %s, HEAD %s: cannot compare' % (
                    app_sha or 'unknown', head or 'unknown')
        files[stem(s)] = entry
    return files


def write_index(out, report):
    """DIR/index.html: provenance, then each section's sheet and checks."""
    e = html.escape
    lines = ['<!doctype html>', '<meta charset="utf-8">',
             '<title>Studio lights gallery</title>',
             '<style>body{font-family:-apple-system,Helvetica,sans-serif;margin:2em}'
             'table{border-collapse:collapse}td,th{border:1px solid #ccc;padding:2px 6px}'
             '.failed{color:#c00}.flag{color:#c60}img{max-width:100%}</style>',
             '<h1>Studio lights gallery</h1>',
             '<p>Generated %s by scripts/lighting/gallery.py (%s); HEAD %s; exit %d.</p>'
             % (e(report['generated']), e(report['mode']), e(report['head'] or 'unknown'),
                report['exit']),
             '<h2>Provenance</h2>', '<table><tr><th>Scene file</th><th>app sha</th>'
             '<th>render.py sha256</th><th>Flag</th></tr>']
    for stem_name, p in report['scene_files'].items():
        lines.append('<tr><td>%s</td><td>%s</td><td>%s</td><td class="flag">%s</td></tr>' % (
            e(p['scenes']), e(p['app_sha'] or ''), e((p['render_py_sha256'] or '')[:16]),
            e(p['flag'] or '')))
    lines.append('</table>')
    for r in report['sections']:
        lines.append('<h2 id="%s">%s <small>(%s)</small></h2>' % (
            e(r['name']), e(r['title']), e(r['name'])))
        lines.append('<p><code>%s</code></p>' % e(r['caption']))
        cls = ' class="failed"' if r['status'] == 'failed' else ''
        lines.append('<p%s>Status: %s</p>' % (cls, e(r['status'])))
        if r['errors']:
            lines.append('<ul class="failed">%s</ul>' % ''.join(
                '<li>%s</li>' % e(x) for x in r['errors']))
        if r['sheet']:
            lines.append('<p><a href="%s"><img src="%s" alt="%s"></a></p>' % (
                e(r['sheet']), e(r['sheet']), e(r['title'])))
        if r['status'] != 'not rendered':
            lines.append('<p>Images: %s</p>' % ', '.join(
                '<a href="%s">%s</a>' % (e(i['path']), e(i['tag'])) for i in r['images']))
        if r['checks']:
            lines.append('<table><tr><th>Image</th><th>Reference</th><th>Measured</th>'
                         '<th>Needs</th><th>Level</th><th>Pass</th><th>Override reason</th></tr>')
            for c in r['checks']:
                lines.append('<tr><td>%s</td><td>%s</td><td>%s</td><td>%.4f</td><td>%d</td>'
                             '<td>%s</td><td>%s</td></tr>' % (
                                 e(c['tag']), e(c['ref']),
                                 '%.4f' % c['measured'] if c['measured'] is not None
                                 else e(c['error'] or ''),
                                 c['share'], c['level'], 'yes' if c['pass'] else 'NO',
                                 e(c['reason'] or '')))
            lines.append('</table>')
    path = os.path.join(out, 'index.html')
    with open(path, 'w') as handle:
        handle.write('\n'.join(lines) + '\n')
    return path


def write_report(out, report):
    path = os.path.join(out, 'gallery.json')
    with open(path, 'w') as handle:
        json.dump(report, handle, indent=2)
    return path


def assemble(render, out, jobs, requested, mode, render_rcs=None):
    """Sheets, checks, index.html and gallery.json for every section.
    Returns the exit code (0 or 1)."""
    head = head_sha(render.DEFAULT_ROOT)
    os.makedirs(out, exist_ok=True)
    results = []
    for s in SECTIONS:
        r = check_section(render, out, s, jobs[s.name], s.name in requested)
        if r['status'] != 'not rendered':
            layout = write_sheet(out, s, r)
            r['sheet'] = os.path.relpath(layout['path'], out) if layout else None
        elif os.path.isfile(sheet_path(out, s)):
            os.remove(sheet_path(out, s))   # a sheet of images no longer on disk
        results.append(r)
    failed = [r['name'] for r in results if r['status'] == 'failed']
    bad_rc = sorted(k for k, v in (render_rcs or {}).items() if v)
    code = 1 if failed or bad_rc else 0
    files = provenance(out, head)
    report = {
        'generated': datetime.datetime.now().isoformat(timespec='seconds'),
        'mode': mode, 'head': head, 'requested': sorted(requested, key=section_names().index),
        'exit': code, 'render_exit': dict(render_rcs or {}),
        'scene_files': files, 'sections': results,
        'checks': {'level': DIFF_LEVEL, 'share': DIFF_SHARE},
    }
    write_index(out, report)
    write_report(out, report)
    for r in results:
        print('gallery: %-9s %-12s %s' % (r['name'], r['status'],
                                          '; '.join(r['errors'][:3])), flush=True)
    for p in files.values():
        if p['flag']:
            print('gallery: WARNING %s: %s' % (p['scenes'], p['flag']), flush=True)
    for name in bad_rc:
        print('gallery: render.py exited %d for %s' % (render_rcs[name], name), flush=True)
    print('gallery: %s (exit %d)' % (os.path.join(out, 'index.html'), code), flush=True)
    return code


# --- CLI ------------------------------------------------------------------------

def parse_args(argv):
    ap = argparse.ArgumentParser(
        description='The studio lights gallery (#627): render every section '
                    'with a built RayMol.app, then sheets, checks, index.html '
                    'and gallery.json.',
        epilog='Exit codes: 0 ok; 1 an image or a check failed; 2 a refusal '
               'or usage error. Sections: %s.' % ', '.join(section_names()))
    ap.add_argument('--app', help='a RayMol .app with its own bundle id')
    ap.add_argument('--out', help='output directory')
    ap.add_argument('--sections', default='',
                    help='comma-separated sections (default: all)')
    ap.add_argument('--timeout', type=int, default=120,
                    help='seconds to wait for each PNG (default 120)')
    ap.add_argument('--dry-run', action='store_true',
                    help='write the scene scripts, print the render.py calls; launch nothing')
    ap.add_argument('--skip-render', action='store_true',
                    help='only assemble sheets, checks, index.html and gallery.json')
    return ap.parse_args(argv)


def main(argv=None):
    try:
        args = parse_args(argv)
    except SystemExit as e:   # argparse: --help (0) or a usage error (2)
        return e.code if isinstance(e.code, int) else 2
    render = load_render()
    try:
        if not args.out:
            raise render.Refusal('--out is required')
        if args.dry_run and args.skip_render:
            raise render.Refusal('give --dry-run or --skip-render, not both')
        requested = parse_sections(render, args.sections)
        jobs, _app_id = validate(render, args, requested)
    except render.Refusal as e:
        print('gallery.py: %s' % e, file=sys.stderr)
        return 2
    out = os.path.abspath(args.out)
    names = [s.name for s in requested]

    if args.dry_run:
        code = 0
        for scenes, tags in scene_groups(requested):
            code = max(code, render_group(render, out, scenes, tags, args))
        print('gallery: dry run; the per-file route renders with')
        for scenes, tags in scene_groups(requested):
            print('  gate.sh render <issue> <worktree> %s' % ' '.join(render_argv(
                out, scenes, tags, scenes_dir=os.path.join('scripts', 'lighting', 'scenes'))))
        print('  then: gallery.py --out %s --skip-render%s' % (
            out, ' --sections ' + ','.join(names) if args.sections else ''))
        return code

    if args.skip_render:
        return assemble(render, out, jobs, names, 'skip-render')

    for s in requested:
        clear_section(out, s)
    rcs = {}
    for scenes, tags in scene_groups(requested):
        rc = render_group(render, out, scenes, tags, args)
        rcs[scenes] = rc
        if rc == 2:
            print('gallery.py: render.py refused %s; stopping' % scenes, file=sys.stderr)
            return 2
    return assemble(render, out, jobs, names, 'render', rcs)


if __name__ == '__main__':
    sys.exit(main())
