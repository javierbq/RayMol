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
    check_lit.py highlight ON OFF              highlight 1 against 0: a few pixels, only
                                               brighter, in the key's hue
    check_lit.py falloff F2 F0 DARK            falloff 2 lights the side nearer the light
                                               more, relative to the far side, than 0
    check_lit.py softer SOFT HARD DARK         softness 1 against 0 at the same beam: less
                                               light in all, more of it partial
    check_lit.py reflect LIT1 DARK1 LIT0 DARK0 traced reflections (rt1) carry the rig's
                                               light: the rt1 lit-minus-dark delta keeps
                                               enough of the rt0 one
    check_lit.py glass_lit LIT REF             the rig on clear glass sphere impostors:
                                               faint, through the coverage, but warm
    check_lit.py d15 DIR --dark DIR [--dark DIR]
                                               every <s>_d15_rt<n> (no rig, decision 15's
                                               terms) equals the dark twin <s>_dark_rt<n>
    check_lit.py hue-present PNG [--box X0,Y0,X1,Y1]
                                               warm and cyan light in one image (L4),
                                               counted inside the box (the viewport)

    pairs takes --norig DIR (the L1 no-rig renders): mesh, whose lines are
    unlit, must then also equal the no-rig mesh_rt<n> byte for byte.

The scene files are scripts/lighting/scenes/lighting_613.json (pairs),
lighting_613_params.json (isolation and parameters) and lighting_613_d15.json
(no rig, at decision 15's terms: d15). Every lit image is
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
# Tuned ONCE, on #613's first full L2 round (round 1, head 26431e4ac: 48 pair
# images and 31 parameter images of 1rx1 at 1280x720, plus the L4 simulator
# screenshot), and FROZEN: never re-tuned to make a later round pass.
#
# The rule: a coverage threshold is about half the smallest value measured in
# its class, rounded down, so a real regression (a path left unlit, a light
# missing, a cone that no longer narrows) fails while a legitimate change of
# look (#615 materials, #616 shadows, #624 HDR) keeps its margin. Definitions
# (what counts as a changed, orange or cyan pixel) and sign checks keep the
# plan's values. "measured" is round 1's minimum and the subject it came from.

LIT_MAX_DELTA = 50       # lit: the largest channel delta is at least this
                         #   (plan 32; measured 100, spheres_jelly_rt0; others 161-232)
LIT_CHANGE = 8           # a pixel "changes" when a channel moves by more than this
LIT_FRACTION = 0.20      # lit: at least this fraction of geometry pixels change
                         #   (plan 0.02; measured 43.19%, sticks_glass_rt0; others 54.97-99.34%)
HUE_LUMINANCE = 8.0      # hue: only pixels whose luminance delta exceeds this
HUE_RATIO = 1.6          # orange: dr > 1.6 db and dr >= dg; cyan: db > 1.6 dr and dg > dr
ORANGE_FRACTION = 0.25   # hue: orange pixels, as a fraction of geometry pixels
                         #   (plan 0.01; measured 56.72%, tube_rt0/rt1)
CYAN_FRACTION = 0.05     # hue: cyan pixels, likewise
                         #   (plan 0.005; measured 10.57%, meshcyl_rt1)
FAINT_HUE_FRACTION = 0.01     # both, for transparent, glass and jelly subjects
                              #   (plan 0.0005; measured cyan 2.33%, spheres_trans_rt0/rt1;
                              #   orange 18.13%, sticks_glass_rt0)
FAINT_TOKENS = ('glass', 'transparent', 'trans', 'jelly')
ISOLATE_RATIO = 1.5      # key: sum dr >= 1.5 sum db; rim: sum db >= 1.5 sum dr
                         #   (plan 1.5; measured 3.32, tube key and rim)
ISOLATE_FRACTION = 0.09  # each light alone changes at least this fraction
                         #   (plan 0.003; measured 18.90%, surface rim)
LEFT_OF = 0.05           # left_of: the rim's mean place across the geometry it lights
                         #   (0 = a run's left edge, 1 = its right edge) is at least this
                         #   right of the key's (measured gap 0.109, spheres; cartoon
                         #   0.263, surface 0.199, sticks 0.315, tube 0.517)
FEWER_RATIO = 0.5        # narrow cone: fewer than this x the wide cone's lit pixels
                         #   (plan 0.6; measured 18.68% / 75.78% = 0.246)
OUTLINE_MAX_FRACTION = 0.05   # outline: differs from the key image on at most 5%
                              #   (measured 2.03%)
OUTLINE_TOLERANCE = 0.15      # a ring pixel's chromaticity within this of the ring colour
OUTLINE_MIN_BRIGHT = 64       # ... and its brightest channel at least this
OUTLINE_MIN_PIXELS = 20       # ... at least this many ring pixels (measured 2045; a
                              #   count, which scales with the image and the beam's
                              #   footprint: it only shows the ring colour is there)

# Round 2 (#613's review round 1) added the checks below. Each has its own
# thresholds, tuned ONCE on round 2's renders by the same rule and frozen:
# about half the measured margin. A shading-term check compares two images
# that differ in that term alone (lighting_613_params.json).
HIGHLIGHT_MAX_DELTA = 55      # highlight: its brightest added channel at least this
                              #   (measured 111, surface and ortho)
HIGHLIGHT_MIN_FRACTION = 0.038  # ... on at least this fraction of the geometry
                                #   (measured 7.77% ortho, 8.35% perspective)
HIGHLIGHT_MAX_FRACTION = 0.20   # ... and at most this: a highlight, not a diffuse
                                #   (the key alone lights 75.8% of the surface)
HIGHLIGHT_NEGATIVE = 0.01     # ... taking away at most this x what it adds (measured 0)
FALLOFF_RATIO = 1.6           # falloff: near/far ratio at falloff 2 over that at 0
                              #   (measured 8.712 / 2.596 = 3.36; inverted < 1)
SOFT_TOTAL = 0.83             # softer: softness 1 adds at most this x softness 0's light
                              #   (measured 0.670; a hard edge at both gives 1)
SOFT_PARTIAL = 0.08           # ... and its share of partly lit pixels is higher by this
                              #   (measured 70.78% against 53.66%: +17.1 points)
REFLECT_RATIO = 0.57          # reflect: rt1's added light over rt0's, metallic spheres
                              #   (measured 0.693 with the hits rig-lit; 0.450 before
                              #   the fix, when the hits took decision 15 alone)
GLASS_LIT_MAX_DELTA = 9       # glass_lit: clear glass on sphere impostors (surface
GLASS_LIT_FRACTION = 0.11     #   dots), lit through its coverage: measured max 18,
                              #   changed 23.3%, sum dr 1.44 x sum db
D15_TOLERANCE = 1             # d15: a dark twin equals its no-rig render at decision
                              #   15's terms within this (the reviewer's bound; measured 0)
PRESENT_PIXELS = 1000    # hue-present: at least this many warm and this many cyan pixels
                         #   (plan 500; measured in the L4 viewport, 1206x2622 iPhone
                         #   simulator, box 0,420,1206,2400: warm 456099, cyan 2058 with
                         #   the 3-light rig, 0 and 0 without it. The app's blue toolbar
                         #   icons alone are 2777 "cyan" pixels, so L4 passes --box)
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
    # review round 1: each shading term on its own
    ('highlight', ('surface_hl1_rt0', 'surface_hl0_rt0')),
    ('highlight', ('surface_hl1_ortho_rt0', 'surface_hl0_ortho_rt0')),
    ('falloff', ('surface_fall2_rt0', 'surface_fall0_rt0', 'surface_dark_rt0')),
    ('softer', ('surface_soft1_rt0', 'surface_soft0_rt0', 'surface_dark_rt0')),
    # traced reflection hits take the rig (pairs images, through --pairs)
    ('reflect', ('spheres_metallic_2l_rt1', 'spheres_metallic_dark_rt1',
                 'spheres_metallic_2l_rt0', 'spheres_metallic_dark_rt0')),
    # the harness's 3-light rig: lit against itself at intensity 0, and the
    # pinned rim's outline against the same rig without it
    ('lit', ('cartoon_rig3_rt0', 'cartoon_rig3dark_rt0')),
    ('lit', ('cartoon_rig3_rt1', 'cartoon_rig3dark_rt1')),
    ('lit', ('surface_rig3_rt1', 'surface_rig3dark_rt1')),
    ('outline_white', ('cartoon_rig3_rt0', 'cartoon_rig3plain_rt0')),
    ('outline_white', ('cartoon_rig3_rt1', 'cartoon_rig3plain_rt1')),
    # clear glass on sphere impostors, lit through its coverage
    ('glass_lit', ('surfdots_glass_lit_rt0', 'surfdots_glass_dark_rt0')),
)

_D15_RE = re.compile(r'^(?P<s>[a-z0-9_]+)_d15_rt(?P<rt>[01])$')

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
        """One markdown table row; a '|' inside a cell ("max |d|") is
        escaped so the row keeps its four columns when pasted into a PR."""
        cells = (self.check, self.subject, 'PASS' if self.ok else 'FAIL', self.detail)
        return '| %s |' % ' | '.join(str(c).replace('|', '\\|') for c in cells)

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


def run_sides(geo):
    """Each geometry pixel's place across its row's run of geometry: near 0 at
    the run's left edge, near 1 at its right edge ((x - start + 0.5) / width);
    NaN off the geometry."""
    np = _np()
    geo = np.asarray(geo, dtype=bool)
    h, w = geo.shape
    xs = np.broadcast_to(np.arange(w), (h, w))
    off = np.zeros((h, 1), dtype=bool)
    starts = geo & ~np.concatenate([off, geo[:, :-1]], axis=1)
    ends = geo & ~np.concatenate([geo[:, 1:], off], axis=1)
    left = np.maximum.accumulate(np.where(starts, xs, -1), axis=1)
    right = np.minimum.accumulate(np.where(ends, xs, w)[:, ::-1], axis=1)[:, ::-1]
    side = (xs - left + 0.5) / np.maximum(right - left + 1, 1)
    return np.where(geo, side, np.nan)


def _mean_side(lit, ref, sides, geo):
    """Where a light lands across the geometry it lights: the run_sides
    place, weighted by the luminance the light adds. None when it adds
    nothing."""
    w = luminance(_positive(lit, ref))[geo]
    total = float(w.sum())
    if total <= 0.0:
        return None
    return float((w * sides[geo]).sum()) / total


def check_isolate(key, rim, dark, subject=''):
    """Each light alone, against the rig at intensity 0: the key adds orange
    light, the rim cyan, each on enough pixels, and the key (orbit -45) lands
    on the left sides of the geometry it lights, the rim (orbit +120) on the
    right sides: decision 12's orbit sign, in pixels.

    left_of compares sides, not image centroids: a centroid says where the
    subject has geometry facing a light, not which side of it the light is
    on (round 1: the cartoon rim lights the right edges of its loops and
    helices, but most of those are in the left half of the image, so its
    centroid lies left of the key's)."""
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
    geo = geometry(key, rim, dark)
    sides = run_sides(geo)
    sk, sr = _mean_side(key, dark, sides, geo), _mean_side(rim, dark, sides, geo)
    if sk is None or sr is None:
        out.append(Result('left_of', subject, False, 'a light adds nothing'))
    else:
        out.append(Result('left_of', subject, sk <= sr - LEFT_OF,
                          'key side %.3f <= rim side %.3f - %.2f (0 left edge, 1 right)'
                          % (sk, sr, LEFT_OF)))
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


def check_highlight(on, off, colour=KEY_COLOUR, subject=''):
    """A light's highlight (Blinn-Phong, coloured): the same rig with the
    light's highlight 1 (ON) and 0 (OFF). The highlight only ADDS light, on a
    small part of the geometry (where the surface turns its half-vector
    toward the viewer), in the light's colour. A highlight that is missing,
    ignores the light's highlight value, or lights most of the geometry
    fails."""
    bad = _same_size('highlight', subject, on, off)
    if bad:
        return bad
    np = _np()
    geo = geometry(on, off)
    n = max(int(geo.sum()), 1)
    d = delta(on, off)
    pos, neg = np.maximum(d, 0), np.maximum(-d, 0)
    frac = float(((pos.max(axis=2) > LIT_CHANGE) & geo).sum()) / n
    pmass, nmass = float(pos.sum()), float(neg.sum())
    top = int(pos.max())
    # hue: the light's dominant channel over its weakest one
    hi_c = int(max(range(3), key=lambda c: colour[c]))
    lo_c = int(min(range(3), key=lambda c: colour[c]))
    hi_sum, lo_sum = float(pos[..., hi_c].sum()), float(pos[..., lo_c].sum())
    hued = hi_sum > 0 and (colour[hi_c] == colour[lo_c] or
                           hi_sum >= ISOLATE_RATIO * lo_sum)
    ok = (top >= HIGHLIGHT_MAX_DELTA and
          HIGHLIGHT_MIN_FRACTION <= frac <= HIGHLIGHT_MAX_FRACTION and
          nmass <= HIGHLIGHT_NEGATIVE * pmass and hued)
    return Result('highlight', subject, ok,
                  'max +d %d (>= %d), on %s (%s..%s), negative %.4f x positive (<= %.2f), '
                  'sum d%s %.0f >= %.1f x sum d%s %.0f'
                  % (top, HIGHLIGHT_MAX_DELTA, _pct(frac), _pct(HIGHLIGHT_MIN_FRACTION),
                     _pct(HIGHLIGHT_MAX_FRACTION), nmass / max(pmass, 1.0),
                     HIGHLIGHT_NEGATIVE, 'rgb'[hi_c], hi_sum, ISOLATE_RATIO,
                     'rgb'[lo_c], lo_sum))


def _thirds(geo):
    """(near, far): the geometry in the left and the right third of its own
    width (columns)."""
    np = _np()
    cols = np.nonzero(geo.any(axis=0))[0]
    if not len(cols):
        return geo & False, geo & False
    x0, x1 = int(cols[0]), int(cols[-1]) + 1
    third = (x1 - x0) / 3.0
    xs = np.broadcast_to(np.arange(geo.shape[1]), geo.shape)
    return geo & (xs < x0 + third), geo & (xs >= x1 - third)


def _near_far(lit, dark, near, far):
    added = luminance(_positive(lit, dark))
    mn = float(added[near].mean()) if near.any() else 0.0
    mf = float(added[far].mean()) if far.any() else 0.0
    return mn, mf


def check_falloff(f2, f0, dark, subject=''):
    """Distance falloff, normalised at the aim point: a light pinned left of
    and in front of the subject, aimed at its centre, at falloff 2 (F2) and
    0 (F0), against the rig at intensity 0. At falloff 2 the left third
    (nearer the light than the aim point) gains and the right third loses,
    so the near/far ratio of added light is clearly higher than at falloff 0,
    where distance does not matter. An inverted falloff (far side brighter)
    or none fails."""
    bad = _same_size('falloff', subject, f2, f0, dark)
    if bad:
        return bad
    near, far = _thirds(geometry(f2, f0, dark))
    n2, d2 = _near_far(f2, dark, near, far)
    n0, d0 = _near_far(f0, dark, near, far)
    if min(n2, d2, n0, d0) <= 0.0:
        return Result('falloff', subject, False,
                      'a third gets no light (near/far: falloff 2 %.2f/%.2f, 0 %.2f/%.2f)'
                      % (n2, d2, n0, d0))
    r2, r0 = n2 / d2, n0 / d0
    return Result('falloff', subject, r2 >= FALLOFF_RATIO * r0,
                  'near/far falloff 2 %.3f >= %.2f x falloff 0 %.3f'
                  % (r2, FALLOFF_RATIO, r0))


def _partial_share(lit, dark):
    """Of the pixels a light changes, the share it lights only partly: added
    luminance under half of what its brightest 2% get."""
    np = _np()
    geo = geometry(lit, dark)
    pos = _positive(lit, dark)
    lit_px = geo & (pos.max(axis=2) > LIT_CHANGE)
    if not lit_px.any():
        return 0.0, 0.0
    added = luminance(pos)[lit_px]
    top = float(np.percentile(added, 98))
    return float((added < 0.5 * top).sum()) / len(added), float(added.sum())


def check_softer(soft, hard, dark, subject=''):
    """The cone's soft edge: the same beam at softness 1 (SOFT) and 0 (HARD),
    against the rig at intensity 0. Softness 1 fades the light from the beam
    axis to its edge, so it adds less light in all and more of what it adds
    is partial; a hard edge (softness ignored, or the edge band inverted)
    gives the same image at both."""
    bad = _same_size('softer', subject, soft, hard, dark)
    if bad:
        return bad
    ps, ss = _partial_share(soft, dark)
    ph, sh = _partial_share(hard, dark)
    if sh <= 0.0:
        return Result('softer', subject, False, 'the hard beam adds no light')
    ok = ss <= SOFT_TOTAL * sh and ps >= ph + SOFT_PARTIAL
    return Result('softer', subject, ok,
                  'light %.3f x hard (<= %.2f); partial %s >= hard %s + %s'
                  % (ss / sh, SOFT_TOTAL, _pct(ps), _pct(ph), _pct(SOFT_PARTIAL)))


def check_reflect(lit1, dark1, lit0, dark0, subject=''):
    """Traced reflections take the rig (metal_raytrace 1): a reflective
    subject lit and dark at rt1 and at rt0. At rt1 the composite mixes each
    pixel with what its reflection ray hits, by a Fresnel weight of at least
    the material's reflectance. If the hits ignore the rig, the rt1
    lit-minus-dark delta keeps only the unreflected share of the rt0 one
    (1 - F); if they take it, the reflected neighbours add theirs."""
    bad = _same_size('reflect', subject, lit1, dark1, lit0, dark0)
    if bad:
        return bad
    geo = geometry(lit1, dark1, lit0, dark0)
    s1 = float(luminance(_positive(lit1, dark1))[geo].sum())
    s0 = float(luminance(_positive(lit0, dark0))[geo].sum())
    if s0 <= 0.0:
        return Result('reflect', subject, False, 'the rt0 pair adds no light')
    return Result('reflect', subject, s1 >= REFLECT_RATIO * s0,
                  'rt1 added light %.3f x rt0 (>= %.2f)' % (s1 / s0, REFLECT_RATIO))


def check_glass_lit(lit, dark, subject=''):
    """The rig on clear glass that sphere impostors draw (another rep's glass
    spheres: surface dots): the light reaches the screen only at the glass's
    coverage (orchestrator decision Q1), so far more faintly than on an
    opaque subject, but it is there, on enough of the geometry, and warm
    (the key's orange outweighs the rim's cyan)."""
    bad = _same_size('glass_lit', subject, lit, dark)
    if bad:
        return bad
    np = _np()
    geo = geometry(lit, dark)
    n = max(int(geo.sum()), 1)
    pos = _positive(lit, dark)
    top = int(pos.max())
    frac = float(((pos.max(axis=2) > LIT_CHANGE) & geo).sum()) / n
    dr, db = float(pos[..., 0].sum()), float(pos[..., 2].sum())
    ok = top >= GLASS_LIT_MAX_DELTA and frac >= GLASS_LIT_FRACTION and dr > db
    return Result('glass_lit', subject, ok,
                  'max +d %d (>= %d), changed %s (>= %s), sum dr %.0f > sum db %.0f'
                  % (top, GLASS_LIT_MAX_DELTA, _pct(frac), _pct(GLASS_LIT_FRACTION),
                     dr, db))


def check_same(a, b, subject='', tolerance=D15_TOLERANCE):
    """Equal decoded pixels within `tolerance` levels per channel."""
    bad = _same_size('d15', subject, a, b)
    if bad:
        return bad
    d = _np().abs(delta(a, b)).max(axis=2)
    top = int(d.max())
    return Result('d15', subject, top <= tolerance,
                  'max |d| %d (<= %d), %d pixels differ' % (top, tolerance, int((d > 0).sum())))


def check_outline_white(outline, plain, subject=''):
    """check_outline for a white light (the harness rig's pinned rim)."""
    return check_outline(outline, plain, colour=(1.0, 1.0, 1.0), subject=subject)


def present_counts(image, box=None):
    """(warm, cyan) pixels of one image, by absolute colour; only inside
    box = (x0, y0, x1, y1) (pixels, end-exclusive) when given."""
    p = _rgb(image)
    if box is not None:
        x0, y0, x1, y1 = box
        p = p[y0:y1, x0:x1]
    r, g, b = p[..., 0], p[..., 1], p[..., 2]
    bright = p.max(axis=2) >= PRESENT_MIN_BRIGHT
    warm = bright & (r > HUE_RATIO * b) & (r >= g)
    cyan = bright & (b > HUE_RATIO * r) & (g > r)
    return int(warm.sum()), int(cyan.sum())


def check_hue_present(image, subject='', box=None):
    """L4: the simulator screenshot shows both a warm and a cyan light on the
    grey subjects (no dark reference exists there). Pass the viewport as box:
    the app's own chrome has blue icons that count as cyan."""
    w, c = present_counts(image, box)
    where = ' in %d,%d,%d,%d' % tuple(box) if box is not None else ''
    return Result('hue-present', subject, w >= PRESENT_PIXELS and c >= PRESENT_PIXELS,
                  'warm %d, cyan %d (each >= %d)%s' % (w, c, PRESENT_PIXELS, where))


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


def run_pairs(directory, norig_dir=None):
    """Every pair in `directory`. With norig_dir (the L1 no-rig renders),
    mesh is also compared with the no-rig mesh_rt<n>: its lines are unlit on
    Metal, so the rig must change nothing at all (orchestrator decision Q3),
    not merely the same thing in the lit and the dark image."""
    tags = _tags(directory)
    found = pair_tags(tags)
    if not found:
        raise Usage('%s holds no <s>_2l..._rt<n> images' % directory)
    if norig_dir is not None and not os.path.isdir(norig_dir):
        raise Usage('%s is not a directory' % norig_dir)
    results = []
    for subject, lit_tag, dark_tag in found:
        dark = _path([directory], dark_tag)
        if not dark:
            results.append(Result('pair', subject, False, 'missing %s.png' % dark_tag))
            continue
        lit, ref = load(os.path.join(directory, lit_tag + '.png')), load(dark)
        if _RT_RE.match(subject).group('base') == 'mesh':
            results.append(check_equal(lit, ref, subject))
            if norig_dir is not None:
                norig = _path([norig_dir], subject)
                if not norig:
                    results.append(Result('equal no rig', subject, False,
                                          'missing %s.png in %s' % (subject, norig_dir)))
                else:
                    r = check_equal(lit, load(norig), subject)
                    r.check = 'equal no rig'
                    results.append(r)
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
    'highlight': check_highlight,
    'falloff': check_falloff,
    'softer': check_softer,
    'reflect': check_reflect,
    'outline_white': check_outline_white,
    'glass_lit': check_glass_lit,
}


def run_d15(directory, dark_dirs):
    """Every <s>_d15_rt<n> in `directory` (no rig, the classic settings at
    decision 15's terms) against the rig-on dark twin <s>_dark_rt<n>, looked
    up in dark_dirs: the rig variant keeps the family's own look."""
    tags = [t for t in _tags(directory) if _D15_RE.match(t)]
    if not tags:
        raise Usage('%s holds no <s>_d15_rt<n> images' % directory)
    for d in dark_dirs:
        if not os.path.isdir(d):
            raise Usage('%s is not a directory' % d)
    results = []
    for tag in tags:
        m = _D15_RE.match(tag)
        dark_tag = '%s_dark_rt%s' % (m.group('s'), m.group('rt'))
        subject = '%s_rt%s' % (m.group('s'), m.group('rt'))
        dark = _path(dark_dirs, dark_tag)
        if not dark:
            results.append(Result('d15', subject, False, 'missing %s.png' % dark_tag))
            continue
        results.append(check_same(load(dark), load(os.path.join(directory, tag + '.png')),
                                  subject))
    return results


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


def _box(text):
    try:
        box = tuple(int(v) for v in text.split(','))
    except ValueError:
        box = ()
    if len(box) != 4 or box[0] < 0 or box[1] < 0 or box[2] <= box[0] or box[3] <= box[1]:
        raise Usage('--box wants X0,Y0,X1,Y1 with X0 < X1 and Y0 < Y1, not %r' % text)
    return box


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    sub = ap.add_subparsers(dest='cmd')
    p = sub.add_parser('pairs')
    p.add_argument('dir')
    p.add_argument('--norig', help='the L1 no-rig render directory: mesh must '
                   'also equal its mesh_rt<n> there')
    sub.add_parser('isolate').add_argument('dir')
    p = sub.add_parser('d15')
    p.add_argument('dir')
    p.add_argument('--dark', action='append', default=[], required=True,
                   help='a directory with the rig-on dark twins (repeatable)')
    p = sub.add_parser('params')
    p.add_argument('dir')
    p.add_argument('--pairs', help='the lighting_613.json render directory')
    for name, args in (('lit', ('lit', 'ref')), ('hue', ('lit', 'ref')),
                       ('fewer_lit', ('narrow', 'wide', 'dark')),
                       ('warm_cool', ('warm', 'cool', 'dark')),
                       ('brighter', ('a', 'b')), ('outline', ('outline', 'key')),
                       ('highlight', ('on', 'off')),
                       ('falloff', ('f2', 'f0', 'dark')),
                       ('softer', ('soft', 'hard', 'dark')),
                       ('reflect', ('lit1', 'dark1', 'lit0', 'dark0')),
                       ('glass_lit', ('lit', 'ref')),
                       ('hue-present', ('png',))):
        p = sub.add_parser(name)
        for a in args:
            p.add_argument(a)
        if name == 'hue-present':
            p.add_argument('--box', help='X0,Y0,X1,Y1: count only inside this '
                           'rectangle (pixels, end-exclusive), e.g. the viewport')
    args = ap.parse_args(argv)
    try:
        if args.cmd == 'pairs':
            results = run_pairs(args.dir, args.norig)
        elif args.cmd == 'isolate':
            results = run_isolate(args.dir)
        elif args.cmd == 'd15':
            results = run_d15(args.dir, args.dark)
        elif args.cmd == 'params':
            results = run_params(args.dir, args.pairs)
        elif args.cmd in ('lit', 'hue', 'glass_lit'):
            func = {'lit': check_lit, 'hue': check_hue,
                    'glass_lit': check_glass_lit}[args.cmd]
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
        elif args.cmd == 'highlight':
            results = [check_highlight(*_files([args.on, args.off]),
                                       subject=_name(args.on))]
        elif args.cmd == 'falloff':
            results = [check_falloff(*_files([args.f2, args.f0, args.dark]),
                                     subject=_name(args.f2))]
        elif args.cmd == 'softer':
            results = [check_softer(*_files([args.soft, args.hard, args.dark]),
                                    subject=_name(args.soft))]
        elif args.cmd == 'reflect':
            results = [check_reflect(*_files([args.lit1, args.dark1, args.lit0,
                                              args.dark0]),
                                     subject=_name(args.lit1))]
        elif args.cmd == 'hue-present':
            box = _box(args.box) if args.box else None
            results = [check_hue_present(*_files([args.png]), subject=_name(args.png),
                                         box=box)]
        else:
            ap.print_usage(sys.stderr)
            return 2
    except Usage as e:
        print('check_lit.py: %s' % e, file=sys.stderr)
        return 2
    return report(results)


if __name__ == '__main__':
    sys.exit(main())
