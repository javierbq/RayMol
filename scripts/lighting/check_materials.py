#!/usr/bin/env python3
"""Pixel checks for how each material takes a studio light (#615, lighting epic #610; L2).

    check_materials.py l2 DIR [--checks a,b]   every check of lighting_615.json, grouped
                                               default / procedural / reflective / glass
    check_materials.py negative DIR            the negative control: renders from an app
                                               without #615's response must FAIL nohighlight,
                                               tint, classic_glints and knobs_dark, and PASS
                                               default's highlight, the tint controls and
                                               sheen_kept
    check_materials.py nohighlight HI1 HI0     a zero highlight: byte-equal (exact)
    check_materials.py highlight HI1 HI0       a highlight: bright, local, never darker
    check_materials.py neutral HI1 HI0         the highlight on grey under white lights has no hue
    check_materials.py tint T0_1 T0_0 TAB_1 TAB_0
                                               the table metallic's highlight takes the base
                                               colour (against the same material at Custom tint 0)
    check_materials.py tint_control ON OFF     a neutral control's highlight on the same base
                                               stays white
    check_materials.py glints HI1 HI0          glass glints: sparse, peaked, positive, white
    check_materials.py frost F1 F0 G1 G0       frosted's glints spread wider and peak no higher
                                               than clear glass's
    check_materials.py diffuse M_ON M_OFF D_ON D_OFF [--expect X]
                                               the material's studio diffuse over default's
    check_materials.py wrap M_ON M_OFF REF_ON REF_OFF
                                               wrap lights more of the surface than matte
    check_materials.py classic_glints C1 C0    with every light dark, classic 1 against 0 adds
                                               only glass's own glints
    check_materials.py knobs_dark A B          a knob that reaches only a classic-scaled term
                                               changes nothing at classic 0 (exact)
    check_materials.py sheen_kept A B          rubber's sheen is not scaled (they differ)

The scene file is scripts/lighting/scenes/lighting_615.json (its comment
names rig W and every variant). Each comparison holds everything but one
input: a highlight pair (hi1/hi0, dim1/dim0) differs only in every light's
`highlight`, so its delta is the studio highlight alone; a diffuse pair
(dim0/dimdark) differs only in intensity at highlight 0, so its delta is the
studio diffuse alone; a classic pair (dark_c1/dark) has every light dark, so
its delta is what PyMOL's own lights add at classic 1; a knob pair differs
only in that Custom knob.

Images are the harness's PNGs (scripts/lighting/render.py): black background,
so the geometry is every pixel that is not black in either image. A delta is
a - b per channel, in 0..255 units.

Prints one table row per check (paste it into the PR) and exits 0 when every
check passes, 1 when one fails, 2 on a usage error (a missing directory, an
unknown check). Pillow and numpy; the checks are pure functions on arrays,
which testing/tests/raymol/lighting_material_check.py exercises on synthetic
images.
"""
import argparse
import colorsys
import os
import sys

# --- thresholds ----------------------------------------------------------------
# Tuned ONCE, on #615's first full L2 round (round 1: the 79 images of
# lighting_615.json, 1rx1 at 1280x720, app built from 973cbdea8), and FROZEN:
# never re-tuned to make a later round pass (#615 plan section 9.4).
#
# #613's rule (check_lit.py): a threshold a measured value must reach is about
# half the smallest value measured in its class, rounded down; a cap a value
# must stay under sits about halfway between the largest value measured and
# what the failure it guards against would give. Definitions (what counts as
# a changed or lit pixel, which pixels a ratio reads), sign checks and bands
# the measurements sit deep inside keep the plan's values. "measured" is round
# 1's extreme and the subject it came from. nohighlight and knobs_dark are
# exact (max 0) and never tuned.

CHANGE = 8                  # a pixel "changes" when its largest channel delta is at least this
HIGHLIGHT_MAX_DELTA = 13    # highlight: its brightest added channel at least this
                            #   (plan 40; measured 27, marble_surface, jelly_surface and
                            #   jelly_spheres, whose bright bases sit at the 8-bit knee, #624;
                            #   others 70-148)
HIGHLIGHT_MIN_FRACTION = 0.048   # ... changing at least this fraction of the geometry
                                 #   (plan 0.002; measured 9.708%, marble_surface)
HIGHLIGHT_MAX_FRACTION = 0.72    # ... and at most this (a highlight, not a diffuse)
                                 #   (plan 0.40; measured 45.512%, metallic_surface_rt0, whose
                                 #   exponent-30 lobe is broad; the rig's diffuse lights 98.762%)
NEVER_DARKER = -1           # highlight, glints, classic_glints: the smallest delta at least this
                            #   (measured -1, glass_surface: rounding)
NEUTRAL_RED = 12            # neutral, tint: only pixels whose red delta is at least this
NEUTRAL_MAX = 3.0           # neutral: |mean(dR - dB)| at most this many levels (measured 0.00)
MIN_PIXELS = 50             # neutral, tint: at least this many such pixels to judge
TINT_DROP = 0.35            # tint: the table's mean dB/dR is under Custom tint 0's by this
                            #   (plan 0.30 under rule B, #615 Q1; measured 0.719,
                            #   metallic_surface; spheres 0.720)
TINT_HUE = 25.0             # tint: the table's delta hue within this many degrees of the base's
                            #   (measured 0.4)
TINT_NEUTRAL = 0.14         # tint (t0) and tint_control: mean dB/dR within this of 1
                            #   (plan 0.10; measured 1.068, the plastic control: the knee
                            #   compresses the orange base's red more than its blue; t0 1.038)
TINT_BASE = (0.85, 0.45, 0.10)   # the saturated base of the tint scenes
GLINT_MAX_FRACTION = 0.63   # glints, classic_glints: at most this fraction of the geometry changes
                            #   (plan 0.10; measured 27.381%, glass_sticks: four exponent-60
                            #   lobes, the headlight's on every face turned to the viewer;
                            #   classic_glints 20.344%; the rig's diffuse lights 98.762%)
GLINT_PEAK = 56             # ... the 99.9th percentile of the delta over the geometry at least this
                            #   (plan 30; measured 113, glass_surface rt0, rt1 and sh)
GLINT_NEUTRAL = 6.0         # glints: |mean(dR - dB)| over the changed pixels at most this
                            #   (measured 0.00)
DIFFUSE_TOLERANCE = 0.08    # diffuse: the ratio within this of the expected value
                            #   (measured 1.000 matte and plastic, 0.791 metallic)
DIFFUSE_LIT = 4             # diffuse: default's lit pixels (largest channel delta at least this)
WRAP_LIT = 2                # wrap: a pixel is lit when its largest channel delta is at least this
WRAP_MARGIN = 0.006         # wrap: lit fraction above matte's by at least this (of the geometry)
                            #   (plan 0.02; measured +1.231%, marble_surface; jelly +1.238%;
                            #   default and plastic, without wrap, +0.000%: the dim rig's three
                            #   lights already reach 98.762% of the surface)
SHEEN_MAX_DELTA = 36        # sheen_kept: the largest channel difference at least this
                            #   (plan 8; measured 73)
SHEEN_FRACTION = 0.10       # ... on at least this fraction of the geometry
                            #   (plan 0.005; measured 20.794%)

# The studio diffuse each material should take, over default's (plan 3.1,
# #615 Q4: reflective diffuse 1 - reflect * tint; metallic 1 - 0.6 * 0.35).
DIFFUSE_EXPECTED = {'plastic': 1.0, 'matte': 1.0, 'metallic': 0.79}

GROUPS = ('default', 'procedural', 'reflective', 'glass')

# Tags of lighting_615.json no check reads: for the eye (the contact sheet).
# The lobe tags are informational by plan. The surface dots (clear and frosted
# glass on sphere impostors) left the glints and frost checks at the round-1
# freeze: that path folds its glints into the colour and composites through
# the glass's coverage in the weighted OIT (no mat_glass_cover), so across
# the stacked dots each glint is averaged with the dots behind it. Measured
# at round 1: hi1 against hi0 moves no pixel by more than 2 levels (glass)
# or 3 (frosted), and PyMOL's own glints there (classic 1 against 0, every
# light dark) by at most 7, so no glint threshold can be met on that subject
# with or without #615. The path stays drawn here for the eye, its source is
# pinned by lighting_material_msl.py and lighting_msl.py, and its no-rig
# pixels by lighting_615_default.json's surfdots tags; frost reads the
# surfaces (the VBO OIT path) instead.
INFORMATIONAL = ('glass_dots_hi1_rt0', 'glass_dots_hi0_rt0',
                 'frosted_dots_hi1_rt0', 'frosted_dots_hi0_rt0',
                 'lobe_plastic_spheres_rt0', 'lobe_metallic_spheres_rt0')

# The negative control (plan 9.4): with a renderer that gives every material
# the neutral response, these checks must fail ...
NEGATIVE_FAIL = ('nohighlight', 'tint', 'classic_glints', 'knobs_dark')
# ... and these subjects must still pass (they do not depend on #615).
NEGATIVE_PASS = {'highlight': ('default_surface_rt0',),
                 'tint_control': ('default_surface', 'plastic_surface'),
                 'sheen_kept': ('rubber_k4z_surface',)}


class Usage(Exception):
    """A missing input: exit 2."""


class Result(object):
    def __init__(self, check, subject, ok, detail, group=''):
        self.check = check
        self.subject = subject
        self.ok = bool(ok)
        self.detail = detail
        self.group = group

    def row(self):
        """One markdown table row; a '|' inside a cell is escaped."""
        cells = (self.group, self.check, self.subject, 'PASS' if self.ok else 'FAIL',
                 self.detail)
        return '| %s |' % ' | '.join(str(c).replace('|', '\\|') for c in cells)

    def __repr__(self):
        return 'Result(%r, %r, %r, %r)' % (self.check, self.subject, self.ok, self.detail)


# --- pixels -------------------------------------------------------------------

def _np():
    import numpy
    return numpy


def load(path):
    """RGB as an int32 array (H, W, 3)."""
    from PIL import Image
    numpy = _np()
    with Image.open(path) as image:
        return numpy.asarray(image.convert('RGB'), dtype=numpy.int32)


def _rgb(a):
    return _np().asarray(a)[..., :3].astype('int32')


def geometry(*images):
    """Pixels that are not black in any of the images."""
    mask = None
    for image in images:
        m = _rgb(image).max(axis=2) > 0
        mask = m if mask is None else (mask | m)
    return mask


def delta(a, b):
    return _rgb(a) - _rgb(b)


def _same_size(check, subject, *images):
    shapes = {tuple(_np().asarray(i).shape[:2]) for i in images}
    if len(shapes) != 1:
        return Result(check, subject, False, 'image sizes differ: %s' % sorted(shapes))
    return None


def _pct(x):
    return '%.3f%%' % (100.0 * x)


def _hue(rgb):
    """HSV hue in degrees of an RGB triple (any scale)."""
    r, g, b = [float(v) for v in rgb]
    top = max(r, g, b)
    if top <= 0:
        return 0.0
    return 360.0 * colorsys.rgb_to_hsv(r / top, g / top, b / top)[0]


def _hue_gap(a, b):
    d = abs(a - b) % 360.0
    return min(d, 360.0 - d)


# --- checks (pure) ------------------------------------------------------------

def check_equal(a, b, subject='', check='nohighlight'):
    """Byte-equal decoded pixels (max 0)."""
    bad = _same_size(check, subject, a, b)
    if bad:
        return bad
    d = _np().abs(delta(a, b)).max(axis=2)
    top = int(d.max())
    return Result(check, subject, top == 0,
                  'max |d| %d (== 0), %d pixels differ' % (top, int((d > 0).sum())))


def check_nohighlight(hi1, hi0, subject=''):
    """Matte and clay take no studio highlight: every light's highlight 1
    against 0 changes no pixel. Exact: a zero highlight multiplies every
    studio specular term by 0."""
    return check_equal(hi1, hi0, subject, 'nohighlight')


def check_knobs_dark(a, b, subject=''):
    """With every light dark at classic 0, a Custom knob that reaches only a
    classic-scaled term (rubber's and jelly's highlight) changes nothing."""
    return check_equal(a, b, subject, 'knobs_dark')


def _delta_stats(a, b):
    np = _np()
    d = delta(a, b)
    geo = geometry(a, b)
    top = d.max(axis=2)
    return d, geo, top, int(geo.sum())


def check_highlight(hi1, hi0, subject=''):
    """A studio highlight: a bright peak on a minority of the geometry, never
    darker anywhere."""
    bad = _same_size('highlight', subject, hi1, hi0)
    if bad:
        return bad
    d, geo, top, n = _delta_stats(hi1, hi0)
    if not n:
        return Result('highlight', subject, False, 'no geometry (both images black)')
    peak = int(top.max())
    low = int(d.min())
    frac = float(((top >= CHANGE) & geo).sum()) / n
    ok = (peak >= HIGHLIGHT_MAX_DELTA and HIGHLIGHT_MIN_FRACTION <= frac <= HIGHLIGHT_MAX_FRACTION
          and low >= NEVER_DARKER)
    return Result('highlight', subject, ok,
                  'max +d %d (>= %d), changed %s (%s..%s), min d %d (>= %d)'
                  % (peak, HIGHLIGHT_MAX_DELTA, _pct(frac), _pct(HIGHLIGHT_MIN_FRACTION),
                     _pct(HIGHLIGHT_MAX_FRACTION), low, NEVER_DARKER))


def check_neutral(hi1, hi0, subject=''):
    """On grey80 under white lights the highlight carries no hue."""
    bad = _same_size('neutral', subject, hi1, hi0)
    if bad:
        return bad
    np = _np()
    d = delta(hi1, hi0)
    mask = d[..., 0] >= NEUTRAL_RED
    n = int(mask.sum())
    if n < MIN_PIXELS:
        return Result('neutral', subject, False,
                      'only %d pixels with dR >= %d (need %d)' % (n, NEUTRAL_RED, MIN_PIXELS))
    gap = float(np.mean(d[..., 0][mask] - d[..., 2][mask]))
    return Result('neutral', subject, abs(gap) <= NEUTRAL_MAX,
                  '|mean(dR - dB)| %.2f (<= %.1f) over %d pixels' % (abs(gap), NEUTRAL_MAX, n))


def tint_ratio(on, off):
    """(mean dB / mean dR, mean delta RGB, pixels) over the pixels whose red
    delta is at least NEUTRAL_RED; None when too few."""
    np = _np()
    d = delta(on, off).astype('float64')
    mask = d[..., 0] >= NEUTRAL_RED
    n = int(mask.sum())
    if n < MIN_PIXELS:
        return None, None, n
    mean = [float(d[..., c][mask].mean()) for c in range(3)]
    return mean[2] / mean[0], mean, n


def check_tint(t0_1, t0_0, tab_1, tab_0, subject='', base=TINT_BASE):
    """The same metallic below the knee, env off: at the table's tint its
    highlight is the base colour's (blue drops against red, the hue is the
    base's); at Custom tint 0 it is white."""
    bad = _same_size('tint', subject, t0_1, t0_0, tab_1, tab_0)
    if bad:
        return bad
    r0, m0, n0 = tint_ratio(t0_1, t0_0)
    rt, mt, nt = tint_ratio(tab_1, tab_0)
    if r0 is None or rt is None:
        return Result('tint', subject, False, 'too few highlight pixels (t0 %d, tab %d; need %d)'
                      % (n0, nt, MIN_PIXELS))
    gap = _hue_gap(_hue(mt), _hue(base))
    drop = r0 - rt
    ok = drop >= TINT_DROP and gap <= TINT_HUE and abs(r0 - 1.0) <= TINT_NEUTRAL
    return Result('tint', subject, ok,
                  'dB/dR t0 %.3f (1 +- %.2f), tab %.3f: drop %.3f (>= %.2f); tab hue %.1f deg '
                  'from the base (<= %.0f)' % (r0, TINT_NEUTRAL, rt, drop, TINT_DROP, gap,
                                               TINT_HUE))


def check_tint_control(on, off, subject=''):
    """A neutral control (default, plastic) on the tint base: its highlight
    stays white (mean dB/dR within TINT_NEUTRAL of 1)."""
    bad = _same_size('tint_control', subject, on, off)
    if bad:
        return bad
    r, _m, n = tint_ratio(on, off)
    if r is None:
        return Result('tint_control', subject, False,
                      'only %d pixels with dR >= %d (need %d)' % (n, NEUTRAL_RED, MIN_PIXELS))
    return Result('tint_control', subject, abs(r - 1.0) <= TINT_NEUTRAL,
                  'dB/dR %.3f (1 +- %.2f) over %d pixels' % (r, TINT_NEUTRAL, n))


def glint_stats(a, b):
    """(changed fraction of the geometry, p99.9 of the largest channel delta
    over the geometry, smallest delta, |mean(dR - dB)| over changed pixels,
    changed pixels, geometry pixels)."""
    np = _np()
    d, geo, top, n = _delta_stats(a, b)
    if not n:
        return None
    changed = (top >= CHANGE) & geo
    c = int(changed.sum())
    p999 = float(np.percentile(top[geo], 99.9))
    gap = abs(float(np.mean(d[..., 0][changed] - d[..., 2][changed]))) if c else 0.0
    return float(c) / n, p999, int(d.min()), gap, c, n


def _glints(check, a, b, subject, neutral):
    bad = _same_size(check, subject, a, b)
    if bad:
        return bad
    s = glint_stats(a, b)
    if s is None:
        return Result(check, subject, False, 'no geometry (both images black)')
    frac, p999, low, gap, c, _n = s
    ok = (c > 0 and frac <= GLINT_MAX_FRACTION and p999 >= GLINT_PEAK and low >= NEVER_DARKER
          and (not neutral or gap <= GLINT_NEUTRAL))
    detail = ('changed %s (> 0, <= %s), p99.9 %.1f (>= %d), min d %d (>= %d)'
              % (_pct(frac), _pct(GLINT_MAX_FRACTION), p999, GLINT_PEAK, low, NEVER_DARKER))
    if neutral:
        detail += ', |mean(dR - dB)| %.2f (<= %.1f)' % (gap, GLINT_NEUTRAL)
    return Result(check, subject, ok, detail)


def check_glints(hi1, hi0, subject=''):
    """Glass glints under the studio lights: positive, sparse, peaked, white."""
    return _glints('glints', hi1, hi0, subject, True)


def check_classic_glints(c1, c0, subject=''):
    """Every light dark: classic 1 against 0 adds glass's own glints (sparse,
    positive, peaked) and nothing else: glass's body takes no light here."""
    return _glints('classic_glints', c1, c0, subject, False)


def check_frost(f1, f0, g1, g0, subject=''):
    """Frosted glass's glints cover more pixels than clear glass's, and peak
    no higher."""
    bad = _same_size('frost', subject, f1, f0, g1, g0)
    if bad:
        return bad
    sf, sg = glint_stats(f1, f0), glint_stats(g1, g0)
    if sf is None or sg is None:
        return Result('frost', subject, False, 'no geometry')
    np = _np()
    pf = int(delta(f1, f0).max(axis=2).max())
    pg = int(delta(g1, g0).max(axis=2).max())
    ok = sf[4] > sg[4] and pf <= pg
    return Result('frost', subject, ok,
                  'changed pixels frosted %d > glass %d; peak frosted %d <= glass %d'
                  % (sf[4], sg[4], pf, pg))


def check_diffuse(m_on, m_off, d_on, d_off, subject='', expected=1.0):
    """The material's studio diffuse over default's, summed over default's
    lit pixels (dim lights at highlight 0 against the same lights dark, env
    off, under the knee)."""
    bad = _same_size('diffuse', subject, m_on, m_off, d_on, d_off)
    if bad:
        return bad
    np = _np()
    dm = delta(m_on, m_off).astype('float64')
    dd = delta(d_on, d_off).astype('float64')
    lit = dd.max(axis=2) >= DIFFUSE_LIT
    n = int(lit.sum())
    total = float(dd[lit].sum())
    if n < MIN_PIXELS or total <= 0:
        return Result('diffuse', subject, False, 'default lights only %d pixels' % n)
    ratio = float(dm[lit].sum()) / total
    return Result('diffuse', subject, abs(ratio - expected) <= DIFFUSE_TOLERANCE,
                  'ratio %.3f (%.2f +- %.2f) over %d pixels' % (ratio, expected,
                                                               DIFFUSE_TOLERANCE, n))


def lit_fraction(on, off):
    d, geo, top, n = _delta_stats(on, off)
    return (float(((top >= WRAP_LIT) & geo).sum()) / n) if n else 0.0


def check_wrap(m_on, m_off, ref_on, ref_off, subject=''):
    """Wrap carries the diffuse past the terminator: the material lights more
    of the geometry than matte does."""
    bad = _same_size('wrap', subject, m_on, m_off, ref_on, ref_off)
    if bad:
        return bad
    fm, fr = lit_fraction(m_on, m_off), lit_fraction(ref_on, ref_off)
    return Result('wrap', subject, fm - fr >= WRAP_MARGIN,
                  'lit %s against matte %s: +%s (>= %s)' % (_pct(fm), _pct(fr), _pct(fm - fr),
                                                           _pct(WRAP_MARGIN)))


def check_sheen_kept(a, b, subject=''):
    """The positive control: rubber's sheen (knob4) is not classic-scaled, so
    the two images differ even with every light dark at classic 0."""
    bad = _same_size('sheen_kept', subject, a, b)
    if bad:
        return bad
    np = _np()
    d = np.abs(delta(a, b)).max(axis=2)
    geo = geometry(a, b)
    n = int(geo.sum())
    top = int(d.max())
    frac = float(((d >= CHANGE) & geo).sum()) / n if n else 0.0
    return Result('sheen_kept', subject, top >= SHEEN_MAX_DELTA and frac >= SHEEN_FRACTION,
                  'max |d| %d (>= %d), changed %s (>= %s)' % (top, SHEEN_MAX_DELTA, _pct(frac),
                                                            _pct(SHEEN_FRACTION)))


# --- the plan -----------------------------------------------------------------

def _pair(subject, v1, v0, rt=0):
    return ['%s_%s_rt%d' % (subject, v1, rt), '%s_%s_rt%d' % (subject, v0, rt)]


def l2_plan():
    """[(group, check, subject, func, tags, kwargs)] for every check of
    lighting_615.json, in report order."""
    plan = []
    hl = lambda group, s, rt=0: plan.append(
        (group, 'highlight', '%s_rt%d' % (s, rt), check_highlight, _pair(s, 'hi1', 'hi0', rt), {}))
    # default: the control
    hl('default', 'default_surface')
    plan.append(('default', 'neutral', 'default_surface', check_neutral,
                 _pair('default_surface', 'hi1', 'hi0'), {}))
    plan.append(('default', 'tint_control', 'default_surface', check_tint_control,
                 _pair('tint_default_surface', 'dim1', 'dim0'), {}))
    # procedural
    for s, rt in (('matte_surface', 0), ('matte_sticks', 0), ('matte_surface', 1),
                  ('matte_surface_sh', 0), ('clay_surface', 0), ('clay_spheres', 0)):
        plan.append(('procedural', 'nohighlight', '%s_rt%d' % (s, rt), check_nohighlight,
                     _pair(s, 'hi1', 'hi0', rt), {}))
    hl('procedural', 'rubber_surface')
    hl('procedural', 'marble_surface')
    plan.append(('procedural', 'diffuse', 'matte_surface', check_diffuse,
                 _pair('matte_surface', 'dim0', 'dimdark') +
                 _pair('default_surface', 'dim0', 'dimdark'),
                 {'expected': DIFFUSE_EXPECTED['matte']}))
    plan.append(('procedural', 'wrap', 'marble_surface', check_wrap,
                 _pair('marble_surface', 'dim0', 'dimdark') +
                 _pair('matte_surface', 'dim0', 'dimdark'), {}))
    plan.append(('procedural', 'knobs_dark', 'rubber_k3z_surface', check_knobs_dark,
                 ['rubber_k3z_surface_dark_rt0', 'rubber_surface_dark_rt0'], {}))
    plan.append(('procedural', 'sheen_kept', 'rubber_k4z_surface', check_sheen_kept,
                 ['rubber_k4z_surface_dark_rt0', 'rubber_surface_dark_rt0'], {}))
    # reflective
    hl('reflective', 'plastic_surface')
    hl('reflective', 'metallic_surface')
    hl('reflective', 'metallic_spheres')
    hl('reflective', 'metallic_surface', 1)
    hl('reflective', 'metallic_surface_sh')
    plan.append(('reflective', 'neutral', 'plastic_surface', check_neutral,
                 _pair('plastic_surface', 'hi1', 'hi0'), {}))
    for rep in ('surface', 'spheres'):
        plan.append(('reflective', 'tint', 'metallic_%s' % rep, check_tint,
                     _pair('tint_metallic_t0_%s' % rep, 'dim1', 'dim0') +
                     _pair('tint_metallic_tab_%s' % rep, 'dim1', 'dim0'), {}))
    plan.append(('reflective', 'tint_control', 'plastic_surface', check_tint_control,
                 _pair('tint_plastic_surface', 'dim1', 'dim0'), {}))
    for mat in ('plastic', 'metallic'):
        plan.append(('reflective', 'diffuse', '%s_surface' % mat, check_diffuse,
                     _pair('%s_surface' % mat, 'dim0', 'dimdark') +
                     _pair('default_surface', 'dim0', 'dimdark'),
                     {'expected': DIFFUSE_EXPECTED[mat]}))
    # glass (clear, frosted and jelly)
    for s, rt in (('glass_surface', 0), ('glass_sticks', 0),
                  ('glass_surface', 1), ('glass_surface_sh', 0)):
        plan.append(('glass', 'glints', '%s_rt%d' % (s, rt), check_glints,
                     _pair(s, 'hi1', 'hi0', rt), {}))
    plan.append(('glass', 'frost', 'frosted_surface', check_frost,
                 _pair('frosted_surface', 'hi1', 'hi0') + _pair('glass_surface', 'hi1', 'hi0'),
                 {}))
    plan.append(('glass', 'classic_glints', 'glass_surface', check_classic_glints,
                 _pair('glass_surface', 'dark_c1', 'dark'), {}))
    hl('glass', 'jelly_surface')
    hl('glass', 'jelly_spheres')
    plan.append(('glass', 'wrap', 'jelly_surface', check_wrap,
                 _pair('jelly_surface', 'dim0', 'dimdark') +
                 _pair('matte_surface', 'dim0', 'dimdark'), {}))
    plan.append(('glass', 'knobs_dark', 'jelly_k3z_surface', check_knobs_dark,
                 ['jelly_k3z_surface_dark_rt0', 'jelly_surface_dark_rt0'], {}))
    return plan


def negative_plan():
    """The l2 plan's entries the negative control runs, each with whether it
    must pass: [(entry, must_pass)]."""
    out = []
    for p in l2_plan():
        if p[1] in NEGATIVE_FAIL:
            out.append((p, False))
        elif p[2] in NEGATIVE_PASS.get(p[1], ()):
            out.append((p, True))
    return out


def plan_tags(plan=None):
    return sorted({t for p in (plan or l2_plan()) for t in p[4]})


def _path(directory, tag):
    p = os.path.join(directory, tag + '.png')
    return p if os.path.isfile(p) else None


def run_plan(directory, plan, checks=None):
    if not os.path.isdir(directory):
        raise Usage('%s is not a directory' % directory)
    results = []
    for group, check, subject, func, tags, kwargs in plan:
        if checks is not None and check not in checks:
            continue
        paths = [_path(directory, t) for t in tags]
        if not all(paths):
            r = Result(check, subject, False, 'missing %s' % ', '.join(
                t + '.png' for t, p in zip(tags, paths) if not p))
        else:
            r = func(*[load(p) for p in paths], subject=subject, **kwargs)
        r.group = group
        results.append(r)
    return results


def run_negative(directory):
    """The negative control on renders from an app without #615's response.
    Each row's `ok` means 'behaved as the control expects'; a missing image
    is never expected."""
    results = []
    for entry, must_pass in negative_plan():
        r = run_plan(directory, [entry])[0]
        missing = r.detail.startswith('missing')
        verdict = 'passes' if r.ok else 'fails'
        r.detail = '(%s; must %s) %s' % (verdict, 'pass' if must_pass else 'fail', r.detail)
        r.ok = (not missing) and (r.ok == must_pass)
        results.append(r)
    return results


# --- CLI ----------------------------------------------------------------------

def report(results, out=None):
    out = out or sys.stdout
    print('| Group | Check | Subject | Result | Measured |', file=out)
    print('| --- | --- | --- | --- | --- |', file=out)
    for r in results:
        print(r.row(), file=out)
    failed = [r for r in results if not r.ok]
    print('check_materials: %d checks, %d failed' % (len(results), len(failed)), file=out)
    return 1 if failed else 0


def _files(paths):
    for p in paths:
        if not os.path.isfile(p):
            raise Usage('no such image %s' % p)
    return [load(p) for p in paths]


def _name(path):
    return os.path.splitext(os.path.basename(path))[0]


def _checks(text):
    if not text:
        return None
    names = [c for c in text.split(',') if c]
    known = sorted({p[1] for p in l2_plan()})
    unknown = [c for c in names if c not in known]
    if unknown:
        raise Usage('unknown checks %s (known: %s)' % (', '.join(unknown), ', '.join(known)))
    return set(names)


SINGLE = {
    'nohighlight': (check_nohighlight, ('hi1', 'hi0')),
    'highlight': (check_highlight, ('hi1', 'hi0')),
    'neutral': (check_neutral, ('hi1', 'hi0')),
    'tint': (check_tint, ('t0_1', 't0_0', 'tab_1', 'tab_0')),
    'tint_control': (check_tint_control, ('on', 'off')),
    'glints': (check_glints, ('hi1', 'hi0')),
    'frost': (check_frost, ('f1', 'f0', 'g1', 'g0')),
    'diffuse': (check_diffuse, ('m_on', 'm_off', 'd_on', 'd_off')),
    'wrap': (check_wrap, ('m_on', 'm_off', 'ref_on', 'ref_off')),
    'classic_glints': (check_classic_glints, ('c1', 'c0')),
    'knobs_dark': (check_knobs_dark, ('a', 'b')),
    'sheen_kept': (check_sheen_kept, ('a', 'b')),
}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    sub = ap.add_subparsers(dest='cmd')
    p = sub.add_parser('l2')
    p.add_argument('dir')
    p.add_argument('--checks', help='comma-separated subset of the checks')
    sub.add_parser('negative').add_argument('dir')
    for name, (_func, args) in SINGLE.items():
        p = sub.add_parser(name)
        for a in args:
            p.add_argument(a)
        if name == 'diffuse':
            p.add_argument('--expect', type=float, default=1.0,
                           help='the expected ratio (default 1)')
    args = ap.parse_args(argv)
    try:
        if args.cmd == 'l2':
            results = run_plan(args.dir, l2_plan(), _checks(args.checks))
        elif args.cmd == 'negative':
            results = run_negative(args.dir)
        elif args.cmd in SINGLE:
            func, names = SINGLE[args.cmd]
            paths = [getattr(args, n) for n in names]
            kwargs = {'expected': args.expect} if args.cmd == 'diffuse' else {}
            results = [func(*_files(paths), subject=_name(paths[0]), **kwargs)]
        else:
            ap.print_usage(sys.stderr)
            return 2
    except Usage as e:
        print('check_materials.py: %s' % e, file=sys.stderr)
        return 2
    return report(results)


if __name__ == '__main__':
    sys.exit(main())
