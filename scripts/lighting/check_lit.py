#!/usr/bin/env python3
"""Pixel checks for the light-rig renders (#613, lighting epic #610; L2).

    check_lit.py pairs DIR                     every <s>_2l..._rt<n> against <s>_dark..._rt<n>
                                               (lit and hue; mesh: byte-equal, its lines are unlit)
    check_lit.py isolate DIR                   <s>_key_rt<n> and <s>_rim_rt<n> against <s>_dark_rt<n>
    check_lit.py params DIR [--pairs DIR2]     everything lighting_613_params.json is for
    check_lit.py lit LIT REF                   LIT has light REF has not
    check_lit.py hue LIT REF                   ... and it is the key's orange and the rim's cyan
    check_lit.py fewer_lit NARROW WIDE DARK    a narrow cone lights fewer pixels than a wide one
    check_lit.py warm_cool WARM COOL DARK      2500 K light is red-heavy, 12000 K blue-heavy
    check_lit.py brighter A B                  A has the higher mean luminance (decision 15)
    check_lit.py outline OUTLINE KEY           a thin ring in the key's outline colour
    check_lit.py hue-present PNG               warm and cyan light in one image (L4)

The scene files are scripts/lighting/scenes/lighting_613.json (pairs) and
lighting_613_params.json (isolation and parameters). Every lit image is
compared with the SAME rig at intensity 0 ("dark"), never with a render
without a rig: with a rig on, decision 15 alone changes every pixel, so a
difference from a no-rig render proves nothing about the rig's own light.

Images are the harness's PNGs (scripts/lighting/render.py): a black
background at metal_raytrace 0 and 1, so the geometry is every pixel that
is not black in either image of a comparison. A delta is lit - ref per
channel, in 0..255 units.

Prints one table row per check (paste it into the PR) and exits 0 when every
check passes, 1 when one fails, 2 on a usage error (a missing directory, no
images to check). Pillow and numpy; the checks are pure functions on arrays,
which testing/tests/raymol/lighting_check.py exercises on synthetic images.
"""
import argparse
import os
import re
import sys

# --- thresholds ----------------------------------------------------------------
# Plan values (#613 plan §8.3). They are tuned ONCE, on the first full L2
# round, with the measured numbers recorded next to each, and then frozen:
# never re-tuned to make a later round pass.

LIT_MAX_DELTA = 32       # lit: the largest channel delta is at least this
LIT_CHANGE = 8           # a pixel "changes" when a channel moves by more than this
LIT_FRACTION = 0.02      # lit: at least this fraction of geometry pixels change
HUE_LUMINANCE = 8.0      # hue: only pixels whose luminance delta exceeds this
HUE_RATIO = 1.6          # orange: dr > 1.6 db and dr >= dg; cyan: db > 1.6 dr and dg > dr
ORANGE_FRACTION = 0.01   # hue: orange pixels, as a fraction of geometry pixels
CYAN_FRACTION = 0.005    # hue: cyan pixels, likewise
FAINT_HUE_FRACTION = 0.0005   # both, for transparent and glass subjects
FAINT_TOKENS = ('glass', 'transparent', 'trans', 'jelly')
ISOLATE_RATIO = 1.5      # key: sum dr >= 1.5 sum db; rim: sum db >= 1.5 sum dr
ISOLATE_FRACTION = 0.003  # each light alone changes at least this fraction
LEFT_OF = 0.05           # key centroid at least this fraction of the width left of the rim's
FEWER_RATIO = 0.6        # narrow cone: fewer than 0.6 x the wide cone's lit pixels
OUTLINE_MAX_FRACTION = 0.05   # outline: differs from the key image on at most 5%
OUTLINE_TOLERANCE = 0.15      # a ring pixel's chromaticity within this of the ring colour
OUTLINE_MIN_BRIGHT = 64       # ... and its brightest channel at least this
OUTLINE_MIN_PIXELS = 20       # ... at least this many ring pixels
PRESENT_PIXELS = 500     # hue-present: at least this many warm and this many cyan pixels
PRESENT_MIN_BRIGHT = 32  # ... counting only pixels at least this bright

# The 2-light rig of the scene files: the key's colour (warmth 6500 K, so
# neutral) gives the outline ring colour.
KEY_COLOUR = (1.0, 0.55, 0.2)

# What lighting_613_params.json is for, besides the isolate and pairs images
# it carries: (check, tags). A tag is looked up in the params directory, then
# in --pairs (surface_2l_rt0 lives in lighting_613.json).
PARAM_CHECKS = (
    ('fewer_lit', ('surface_narrow_rt0', 'surface_wide_rt0', 'surface_dark_rt0')),
    ('warm_cool', ('surface_warm_rt0', 'surface_cool_rt0', 'surface_dark_rt0')),
    ('brighter', ('surface_classic1_rt0', 'surface_2l_rt0')),
    ('outline', ('surface_outline_rt0', 'surface_key_rt0')),
    ('lit', ('cartoon_pinned_rt0', 'cartoon_dark_rt0')),
)

_RT_RE = re.compile(r'^(?P<base>[a-z0-9_]+)_rt(?P<rt>[01])$')


class Usage(Exception):
    """A missing input: exit 2."""


class Result(object):
    def __init__(self, check, subject, ok, detail):
        self.check = check
        self.subject = subject
        self.ok = bool(ok)
        self.detail = detail

    def row(self):
        return '| %s | %s | %s | %s |' % (self.check, self.subject,
                                          'PASS' if self.ok else 'FAIL', self.detail)

    def __repr__(self):
        return 'Result(%r, %r, %r, %r)' % (self.check, self.subject, self.ok, self.detail)


# --- pixels -------------------------------------------------------------------

def load(path):
    """RGB as an int32 array (H, W, 3)."""
    from PIL import Image
    import numpy
    with Image.open(path) as image:
        return numpy.asarray(image.convert('RGB'), dtype=numpy.int32)


def _np():
    import numpy
    return numpy


def _rgb(a):
    a = _np().asarray(a)
    return a[..., :3].astype('int32')


def geometry(*images):
    """Pixels that are not black in any of the images."""
    mask = None
    for image in images:
        m = _rgb(image).max(axis=2) > 0
        mask = m if mask is None else (mask | m)
    return mask


def delta(lit, ref):
    return _rgb(lit) - _rgb(ref)


def luminance(rgb):
    rgb = _np().asarray(rgb, dtype='float64')
    return 0.2126 * rgb[..., 0] + 0.7152 * rgb[..., 1] + 0.0722 * rgb[..., 2]


def _same_size(check, subject, *images):
    shapes = {tuple(_np().asarray(i).shape[:2]) for i in images}
    if len(shapes) != 1:
        return Result(check, subject, False, 'image sizes differ: %s' % sorted(shapes))
    return None


def _pct(x):
    return '%.3f%%' % (100.0 * x)


# --- checks (pure) ------------------------------------------------------------

def check_lit(lit, ref, subject=''):
    """The rig's light is there: a big enough delta on enough pixels."""
    bad = _same_size('lit', subject, lit, ref)
    if bad:
        return bad
    np = _np()
    geo = geometry(lit, ref)
    n = int(geo.sum())
    if not n:
        return Result('lit', subject, False, 'no geometry (both images black)')
    change = np.abs(delta(lit, ref)).max(axis=2)
    top = int(change.max())
    frac = float(((change > LIT_CHANGE) & geo).sum()) / n
    ok = top >= LIT_MAX_DELTA and frac >= LIT_FRACTION
    return Result('lit', subject, ok, 'max |d| %d (>= %d), changed %s (>= %s)' % (
        top, LIT_MAX_DELTA, _pct(frac), _pct(LIT_FRACTION)))


def hue_fractions(lit, ref):
    """(orange, cyan) brightened pixels as fractions of the geometry."""
    geo = geometry(lit, ref)
    n = max(int(geo.sum()), 1)
    d = delta(lit, ref)
    dr, dg, db = d[..., 0], d[..., 1], d[..., 2]
    bright = geo & (luminance(d) > HUE_LUMINANCE)
    orange = bright & (dr > HUE_RATIO * db) & (dr >= dg)
    cyan = bright & (db > HUE_RATIO * dr) & (dg > dr)
    return float(orange.sum()) / n, float(cyan.sum()) / n


def faint(subject):
    """Transparent and glass subjects light only a little of what they cover."""
    return any(t in subject.split('_') for t in FAINT_TOKENS)


def check_hue(lit, ref, subject='', faint_subject=None):
    """Both lights show: the key's orange and the rim's cyan."""
    bad = _same_size('hue', subject, lit, ref)
    if bad:
        return bad
    if faint_subject is None:
        faint_subject = faint(subject)
    need_o = FAINT_HUE_FRACTION if faint_subject else ORANGE_FRACTION
    need_c = FAINT_HUE_FRACTION if faint_subject else CYAN_FRACTION
    o, c = hue_fractions(lit, ref)
    return Result('hue', subject, o >= need_o and c >= need_c,
                  'orange %s (>= %s), cyan %s (>= %s)' % (
                      _pct(o), _pct(need_o), _pct(c), _pct(need_c)))


def check_equal(a, b, subject=''):
    """Byte-equal decoded pixels (mesh lines are unlit on Metal)."""
    bad = _same_size('equal', subject, a, b)
    if bad:
        return bad
    top = int(_np().abs(delta(a, b)).max())
    return Result('equal', subject, top == 0, 'max |d| %d (== 0)' % top)


def _positive(lit, ref):
    return _np().maximum(delta(lit, ref), 0)


def _lit_fraction(lit, ref):
    geo = geometry(lit, ref)
    n = max(int(geo.sum()), 1)
    return float(((_positive(lit, ref).max(axis=2) > LIT_CHANGE) & geo).sum()) / n


def _x_centroid(lit, ref):
    np = _np()
    w = luminance(_positive(lit, ref))
    total = float(w.sum())
    if total <= 0.0:
        return None
    xs = np.arange(w.shape[1], dtype='float64')
    return float((w.sum(axis=0) * xs).sum()) / total


def check_isolate(key, rim, dark, subject=''):
    """Each light alone, against the rig at intensity 0: the key adds orange
    light, the rim cyan, each on enough pixels, and the key (orbit -45) lands
    left of the rim (orbit +120): decision 12's orbit sign, in pixels."""
    bad = _same_size('isolate', subject, key, rim, dark)
    if bad:
        return [bad]
    dk, dr = _positive(key, dark), _positive(rim, dark)
    kr, kb = float(dk[..., 0].sum()), float(dk[..., 2].sum())
    rr, rb = float(dr[..., 0].sum()), float(dr[..., 2].sum())
    fk, fr = _lit_fraction(key, dark), _lit_fraction(rim, dark)
    out = [
        Result('isolate key', subject, kr > 0 and kr >= ISOLATE_RATIO * kb,
               'sum dr %.0f >= %.1f x sum db %.0f' % (kr, ISOLATE_RATIO, kb)),
        Result('isolate rim', subject, rb > 0 and rb >= ISOLATE_RATIO * rr,
               'sum db %.0f >= %.1f x sum dr %.0f' % (rb, ISOLATE_RATIO, rr)),
        Result('isolate lit', subject, fk >= ISOLATE_FRACTION and fr >= ISOLATE_FRACTION,
               'key %s, rim %s (each >= %s)' % (_pct(fk), _pct(fr), _pct(ISOLATE_FRACTION))),
    ]
    width = _np().asarray(key).shape[1]
    ck, cr = _x_centroid(key, dark), _x_centroid(rim, dark)
    if ck is None or cr is None:
        out.append(Result('left_of', subject, False, 'a light adds nothing'))
    else:
        out.append(Result('left_of', subject, ck <= cr - LEFT_OF * width,
                          'key x %.0f <= rim x %.0f - %.0f' % (ck, cr, LEFT_OF * width)))
    return out


def check_fewer_lit(narrow, wide, dark, subject=''):
    """A narrower cone lights fewer pixels (smoothstep cone)."""
    bad = _same_size('fewer_lit', subject, narrow, wide, dark)
    if bad:
        return bad
    fn, fw = _lit_fraction(narrow, dark), _lit_fraction(wide, dark)
    return Result('fewer_lit', subject, fw > 0 and fn < FEWER_RATIO * fw,
                  'narrow %s < %.1f x wide %s' % (_pct(fn), FEWER_RATIO, _pct(fw)))


def check_warm_cool(warm, cool, dark, subject=''):
    """Kelvin end to end: a warm white light adds more red than blue, a cool
    one more blue than red."""
    bad = _same_size('warm_cool', subject, warm, cool, dark)
    if bad:
        return bad
    dw, dc = _positive(warm, dark), _positive(cool, dark)
    wr, wb = float(dw[..., 0].sum()), float(dw[..., 2].sum())
    cr, cb = float(dc[..., 0].sum()), float(dc[..., 2].sum())
    return Result('warm_cool', subject, wr > wb and cb > cr,
                  'warm R %.0f > B %.0f; cool B %.0f > R %.0f' % (wr, wb, cb, cr))


def check_brighter(a, b, subject=''):
    """A has the higher mean luminance over the geometry (decision 15: classic
    1 keeps PyMOL's own lights, classic 0 drops them)."""
    bad = _same_size('brighter', subject, a, b)
    if bad:
        return bad
    geo = geometry(a, b)
    if not geo.any():
        return Result('brighter', subject, False, 'no geometry')
    la, lb = float(luminance(_rgb(a))[geo].mean()), float(luminance(_rgb(b))[geo].mean())
    return Result('brighter', subject, la > lb, 'mean luminance %.2f > %.2f' % (la, lb))


def outline_colour(colour=KEY_COLOUR):
    """The ring colour: the light's colour normalised to its brightest
    channel, mixed 40% toward white (the prototype's studio_cues)."""
    top = max(max(colour), 1e-4)
    return tuple(0.6 * (c / top) + 0.4 for c in colour)


def check_outline(outline, key, colour=KEY_COLOUR, subject=''):
    """The beam outline is a thin ring painted on the geometry: it changes a
    few pixels, some of them to the ring colour. Compared by chromaticity, so
    depth cue and SSAO darkening do not matter."""
    bad = _same_size('outline', subject, outline, key)
    if bad:
        return bad
    np = _np()
    geo = geometry(outline, key)
    n = max(int(geo.sum()), 1)
    o = _rgb(outline)
    differs = geo & (np.abs(delta(outline, key)).max(axis=2) > 0)
    frac = float(differs.sum()) / n
    top = o.max(axis=2)
    chroma = o / np.maximum(top, 1)[..., None]
    ring = np.asarray(outline_colour(colour))
    near = (np.abs(chroma - ring).max(axis=2) <= OUTLINE_TOLERANCE) & (top >= OUTLINE_MIN_BRIGHT)
    hits = int((differs & near).sum())
    ok = 0 < frac <= OUTLINE_MAX_FRACTION and hits >= OUTLINE_MIN_PIXELS
    return Result('outline', subject, ok, 'differs on %s (0 < . <= %s), %d ring pixels (>= %d)'
                  % (_pct(frac), _pct(OUTLINE_MAX_FRACTION), hits, OUTLINE_MIN_PIXELS))


def present_counts(image):
    """(warm, cyan) pixels of one image, by absolute colour."""
    p = _rgb(image)
    r, g, b = p[..., 0], p[..., 1], p[..., 2]
    bright = p.max(axis=2) >= PRESENT_MIN_BRIGHT
    warm = bright & (r > HUE_RATIO * b) & (r >= g)
    cyan = bright & (b > HUE_RATIO * r) & (g > r)
    return int(warm.sum()), int(cyan.sum())


def check_hue_present(image, subject=''):
    """L4: the simulator screenshot shows both a warm and a cyan light on the
    grey subjects (no dark reference exists there)."""
    w, c = present_counts(image)
    return Result('hue-present', subject, w >= PRESENT_PIXELS and c >= PRESENT_PIXELS,
                  'warm %d, cyan %d (each >= %d)' % (w, c, PRESENT_PIXELS))


# --- directories --------------------------------------------------------------

def _tags(directory):
    if not os.path.isdir(directory):
        raise Usage('%s is not a directory' % directory)
    return sorted(n[:-4] for n in os.listdir(directory)
                  if n.endswith('.png') and n != 'sheet.png' and not n.startswith('_'))


def pair_tags(tags):
    """[(subject, lit tag, dark tag)] for every tag holding the token '2l'."""
    out = []
    for tag in tags:
        m = _RT_RE.match(tag)
        if not m:
            continue
        tokens = m.group('base').split('_')
        if '2l' not in tokens:
            continue
        i = tokens.index('2l')
        dark = '_'.join(tokens[:i] + ['dark'] + tokens[i + 1:]) + '_rt' + m.group('rt')
        subject = '_'.join(tokens[:i] + tokens[i + 1:]) + '_rt' + m.group('rt')
        out.append((subject, tag, dark))
    return out


def isolate_tags(tags):
    """[(subject, key tag, rim tag, dark tag)] for every <s>_key_rt<n>."""
    out = []
    for tag in tags:
        m = _RT_RE.match(tag)
        if not m or not m.group('base').endswith('_key'):
            continue
        s = m.group('base')[:-len('_key')]
        rt = '_rt' + m.group('rt')
        out.append((s + rt, tag, s + '_rim' + rt, s + '_dark' + rt))
    return out


def _path(dirs, tag):
    for d in dirs:
        p = os.path.join(d, tag + '.png')
        if os.path.isfile(p):
            return p
    return None


def run_pairs(directory):
    tags = _tags(directory)
    found = pair_tags(tags)
    if not found:
        raise Usage('%s holds no <s>_2l..._rt<n> images' % directory)
    results = []
    for subject, lit_tag, dark_tag in found:
        dark = _path([directory], dark_tag)
        if not dark:
            results.append(Result('pair', subject, False, 'missing %s.png' % dark_tag))
            continue
        lit, ref = load(os.path.join(directory, lit_tag + '.png')), load(dark)
        if _RT_RE.match(subject).group('base') == 'mesh':
            results.append(check_equal(lit, ref, subject))
            continue
        results.append(check_lit(lit, ref, subject))
        results.append(check_hue(lit, ref, subject))
    return results


def run_isolate(directory):
    tags = _tags(directory)
    found = isolate_tags(tags)
    if not found:
        raise Usage('%s holds no <s>_key_rt<n> images' % directory)
    results = []
    for subject, key_tag, rim_tag, dark_tag in found:
        missing = [t for t in (rim_tag, dark_tag) if not _path([directory], t)]
        if missing:
            results.append(Result('isolate', subject, False,
                                  'missing %s' % ', '.join(t + '.png' for t in missing)))
            continue
        results += check_isolate(*[load(os.path.join(directory, t + '.png'))
                                   for t in (key_tag, rim_tag, dark_tag)], subject=subject)
    return results


_PARAM_FUNCS = {
    'fewer_lit': check_fewer_lit,
    'warm_cool': check_warm_cool,
    'brighter': check_brighter,
    'outline': check_outline,
    'lit': check_lit,
}


def run_params(directory, pairs_dir=None):
    dirs = [directory] + ([pairs_dir] if pairs_dir else [])
    results = run_isolate(directory)
    if pair_tags(_tags(directory)):
        results += run_pairs(directory)
    for check, tags in PARAM_CHECKS:
        paths = [_path(dirs, t) for t in tags]
        subject = tags[0]
        if not all(paths):
            results.append(Result(check, subject, False, 'missing %s' % ', '.join(
                t + '.png' for t, p in zip(tags, paths) if not p)))
            continue
        results.append(_PARAM_FUNCS[check](*[load(p) for p in paths], subject=subject))
    return results


# --- CLI ----------------------------------------------------------------------

def report(results, out=None):
    out = out or sys.stdout
    print('| Check | Subject | Result | Measured |', file=out)
    print('| --- | --- | --- | --- |', file=out)
    for r in results:
        print(r.row(), file=out)
    failed = [r for r in results if not r.ok]
    print('check_lit: %d checks, %d failed' % (len(results), len(failed)), file=out)
    return 1 if failed else 0


def _files(paths):
    for p in paths:
        if not os.path.isfile(p):
            raise Usage('no such image %s' % p)
    return [load(p) for p in paths]


def _name(path):
    return os.path.splitext(os.path.basename(path))[0]


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    sub = ap.add_subparsers(dest='cmd')
    for name in ('pairs', 'isolate'):
        sub.add_parser(name).add_argument('dir')
    p = sub.add_parser('params')
    p.add_argument('dir')
    p.add_argument('--pairs', help='the lighting_613.json render directory')
    for name, args in (('lit', ('lit', 'ref')), ('hue', ('lit', 'ref')),
                       ('fewer_lit', ('narrow', 'wide', 'dark')),
                       ('warm_cool', ('warm', 'cool', 'dark')),
                       ('brighter', ('a', 'b')), ('outline', ('outline', 'key')),
                       ('hue-present', ('png',))):
        p = sub.add_parser(name)
        for a in args:
            p.add_argument(a)
    args = ap.parse_args(argv)
    try:
        if args.cmd == 'pairs':
            results = run_pairs(args.dir)
        elif args.cmd == 'isolate':
            results = run_isolate(args.dir)
        elif args.cmd == 'params':
            results = run_params(args.dir, args.pairs)
        elif args.cmd in ('lit', 'hue'):
            func = check_lit if args.cmd == 'lit' else check_hue
            results = [func(*_files([args.lit, args.ref]), subject=_name(args.lit))]
        elif args.cmd == 'fewer_lit':
            results = [check_fewer_lit(*_files([args.narrow, args.wide, args.dark]),
                                       subject=_name(args.narrow))]
        elif args.cmd == 'warm_cool':
            results = [check_warm_cool(*_files([args.warm, args.cool, args.dark]),
                                       subject=_name(args.warm))]
        elif args.cmd == 'brighter':
            results = [check_brighter(*_files([args.a, args.b]), subject=_name(args.a))]
        elif args.cmd == 'outline':
            results = [check_outline(*_files([args.outline, args.key]),
                                     subject=_name(args.outline))]
        elif args.cmd == 'hue-present':
            results = [check_hue_present(*_files([args.png]), subject=_name(args.png))]
        else:
            ap.print_usage(sys.stderr)
            return 2
    except Usage as e:
        print('check_lit.py: %s' % e, file=sys.stderr)
        return 2
    return report(results)


if __name__ == '__main__':
    sys.exit(main())
