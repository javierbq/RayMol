#!/usr/bin/env python3
"""Pixel checks for per-light shadow maps (#616, lighting epic #610; L2).

    check_shadows.py l2 DIR [--checks c1,c2,...]   every check lighting_616.json is for
    check_shadows.py grid DIR [--checks grid]      the grid check (lighting_616_grid.json)
    check_shadows.py same A B [--crop X0,Y0,X1,Y1]       byte-equal
    check_shadows.py differs A B [--darken] [--crop ...] A differs from B (darker than B)

The scene files are scripts/lighting/scenes/lighting_616.json (l2) and
lighting_616_grid.json (grid). Their tags name the inputs of every check:

  <rep>_{dark,aonly,bonly,none,a,b,ab}_rt<n>   two coloured lights, amber A and
      cyan B, on grey80 plus a grey80 backdrop. dark: both at intensity 0;
      aonly / bonly: one light (the other at 0); none: both, no shadow; a / b /
      ab: both lit, the named lights shadowed (metal_shadows 1). The first four
      are at metal_shadows 0.
  shadows_dark_{ns_ms0,sh_ms1,ns_ms1}_rt<n>    both lights at intensity 0; sh =
      both shadowed. Studio shadows turn the whole-pixel shadow off.
  {transparent,glass}_{none,a}_rt0             the OIT paths.
  {sticks,spheres}_{front,side}_{a,none}_rt0 (and spheres_* _ortho_rt0)
      amber alone, 25 and 85 degrees off the view axis.
  ovl_{gizmo,gizmohid,blob,blobhid}_rt0        a CGO sphere between A and the
      molecule, outside the view, named _move_gizmo (an overlay: never casts)
      or blob (casts); *hid has its cgo rep hidden (the same extent).
  {grid,nogrid}_{slab,slabhid}_rt<n>           grid_mode 1 (each cell shadowed
      only by its own objects) and 0, a slab CGO between A and the molecule.

Checks (pure functions on arrays; testing/tests/raymol/lighting_shadow_check.py
exercises each on synthetic images, one pass and one fail):

  coloured     least squares per pixel of X - dark = vA*A + vB*B (A = aonly -
               dark, B = bonly - dark) on <rep>_ab: A's shadow (vA < 0.5) where
               B still lights (vB > 0.9) exists and has B's hue, and the
               reverse; the fit's residual stays small on a, b and ab.
  own          on <rep>_a, B keeps vB >= 0.9 on nearly every pixel it lights
               (A's map never touches B's light) and A's shadow exists; the
               same for <rep>_b.
  independent  ab == a + b - none within 3 levels (each shadow takes only its
               own light), under the 8-bit soft knee.
  no_extra     pixels darkened in ab but in neither a nor b are rare.
  speckle      isolated darkened pixels (acne) are rare.
  same         byte-equal: shadows_dark_sh_ms1 against shadows_dark_ns_ms0 at
               rt0 and rt1 (the whole-pixel shadow is off, raster and traced,
               while studio shadows are on).
  differs      the control of `same`: shadows_dark_ns_ms1 differs from
               shadows_dark_ns_ms0 (the whole-pixel shadow is visible there).
  silhouette   impostor casters face the light: the side light's shadow area
               is at least half the front light's (camera-facing billboards
               give about none), perspective and orthographic.
  oit          A's shadow darkens the transparent and glass surfaces, in A's hue.
  overlay      ovl_gizmo == ovl_gizmohid byte for byte (#433); control:
               ovl_blob darkens the molecule against ovl_blobhid.
  grid         the molecule's grid cell (16 px inside its edges) is byte-equal
               between grid_slab and grid_slabhid; control: nogrid_slab darkens
               the molecule against nogrid_slabhid.

Images are the harness's PNGs (scripts/lighting/render.py). A pixel is
"darkened" when its luminance drops by more than DARKEN levels.

Prints one markdown table row per check (paste it into the PR) and exits 0
when every check passes, 1 when one fails, 2 on a usage error. Pillow and
numpy (/Users/javier/repos/light-tools/venv).
"""
import argparse
import os
import sys

# --- thresholds ----------------------------------------------------------------
# PROVISIONAL: the plan's values (plans/616.md section 10.3). They are tuned
# ONCE on #616's first full L2 round (round 1), recorded here beside the
# measured values by the same rule as check_lit.py (about half the measured
# margin), and then FROZEN: never re-tuned to make a later round pass.

DARKEN = 8.0             # a pixel is darkened when its luminance drops by more than this
LIGHT_MIN = 6.0          # a light reaches a pixel when its contribution's largest
                         #   channel (aonly - dark) is at least this
KNEE = 0.7 * 255         # decomposition, independence: only pixels whose unshadowed
                         #   image (none, or aonly + bonly - dark) stays under the
                         #   8-bit soft knee on every channel (largest channel < this)
COND = 0.05              # two lights are told apart at a pixel when their colours
                         #   are not parallel: det >= COND * |A|^2 |B|^2 (sin^2 angle)
SHADOWED = 0.5           # v < this: the light is (mostly) blocked at the pixel
KEPT = 0.9               # v > this: the light (mostly) still reaches the pixel
HUE_MIN = 8.0            # coloured: the pixel's added light has the other light's
                         #   hue: (b - r) for cyan, (r - b) for amber, above this
COLOURED_MIN = 0.002     # coloured: each light's coloured shadow covers at least this
                         #   fraction of the pixels both lights reach
COLOURED_HUE_SHARE = 0.8  # ... and at least this share of it has the other light's hue
RESIDUAL = 6.0           # the fit's residual (largest channel) at the 95th percentile
OWN_KEEP = 0.98          # own: the unshadowed light keeps v >= KEPT on this share of
                         #   the pixels it reaches
OWN_SHADOW_MIN = 0.01    # own: the shadowed light is blocked (v < SHADOWED) on at
                         #   least this share of the pixels it reaches
INDEPENDENT_TOL = 3      # independent: |ab - (a + b - none)| <= this, every channel
INDEPENDENT_SHARE = 0.99  # ... on at least this share of the pixels under the knee
NO_EXTRA_MAX = 0.002     # no_extra: at most this fraction of the geometry
SPECKLE_MAX = 0.002      # speckle: isolated darkened pixels, at most this fraction
SILHOUETTE_RATIO = 0.5   # silhouette: side area >= this x the front area
SILHOUETTE_MIN = 0.005   # ... and the front light's shadow covers at least this
                         #   fraction of the geometry
OIT_DARKEN = 4.0         # oit: a faint path: darkened by more than this
OIT_MIN = 0.002          # ... on at least this fraction of the geometry
OIT_HUE_RATIO = 1.5      # ... the light taken away is A's hue: sum dr >= this x sum db
DIFFERS_MIN = 200        # differs: at least this many pixels change (or darken)
GRID_MARGIN = 16         # grid: the molecule's cell, this many pixels inside its edges
GRID_LAYOUT = (2, 1, 0)  # grid: (columns, rows, the molecule's cell) of the
                         #   lighting_616_grid.json renders (m, then the slab)

# The two coloured lights of the scene files.
AMBER = (1.0, 0.55, 0.15)
CYAN = (0.15, 0.75, 1.0)

REPS = ('cartoon', 'surface', 'sticks', 'spheres')
RTS = (0, 1)


class Usage(Exception):
    """A missing input: exit 2."""


class Result(object):
    def __init__(self, check, subject, ok, detail):
        self.check = check
        self.subject = subject
        self.ok = bool(ok)
        self.detail = detail

    def row(self):
        cells = (self.check, self.subject, 'PASS' if self.ok else 'FAIL', self.detail)
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
    import numpy
    with Image.open(path) as image:
        return numpy.asarray(image.convert('RGB'), dtype=numpy.int32)


def _rgb(a):
    return _np().asarray(a)[..., :3].astype('int32')


def _f(a):
    return _np().asarray(a)[..., :3].astype('float64')


def geometry(*images):
    """Pixels that are not black in any of the images."""
    mask = None
    for image in images:
        m = _rgb(image).max(axis=2) > 0
        mask = m if mask is None else (mask | m)
    return mask


def luminance(rgb):
    rgb = _f(rgb)
    return 0.2126 * rgb[..., 0] + 0.7152 * rgb[..., 1] + 0.0722 * rgb[..., 2]


def darkened(img, ref, threshold=DARKEN):
    """img is darker than ref by more than `threshold` luminance levels."""
    return (luminance(ref) - luminance(img)) > threshold


def _same_size(check, subject, *images):
    shapes = {tuple(_np().asarray(i).shape[:2]) for i in images}
    if len(shapes) != 1:
        return Result(check, subject, False, 'image sizes differ: %s' % sorted(shapes))
    return None


def _pct(x):
    return '%.3f%%' % (100.0 * x)


def _crop(image, crop):
    if crop is None:
        return image
    x0, y0, x1, y1 = crop
    return _np().asarray(image)[y0:y1, x0:x1]


# --- the decomposition ----------------------------------------------------------

class Decomposition(object):
    """Least squares per pixel of X - dark = vA * A + vB * B.

    A = aonly - dark and B = bonly - dark are each light's own contribution
    (that representation's dark, aonly and bonly). AO, fog and the RT
    composite act per pixel and affinely across these images, so `dark`
    absorbs them. vA (vB) is NaN where light A (B) does not reach, or where
    both reach with colours too close to tell apart.
    """

    def __init__(self, dark, aonly, bonly, x):
        np = _np()
        d0 = _f(dark)
        self.A = _f(aonly) - d0
        self.B = _f(bonly) - d0
        D = _f(x) - d0
        A, B = self.A, self.B
        aa = (A * A).sum(axis=2)
        bb = (B * B).sum(axis=2)
        ab = (A * B).sum(axis=2)
        ad = (A * D).sum(axis=2)
        bd = (B * D).sum(axis=2)
        self.reachA = A.max(axis=2) >= LIGHT_MIN
        self.reachB = B.max(axis=2) >= LIGHT_MIN
        det = aa * bb - ab * ab
        both = self.reachA & self.reachB & (det >= COND * aa * bb)
        onlyA = self.reachA & ~self.reachB
        onlyB = self.reachB & ~self.reachA
        with np.errstate(divide='ignore', invalid='ignore'):
            vA = np.where(both, (bb * ad - ab * bd) / np.where(both, det, 1.0),
                          np.where(onlyA, ad / np.where(onlyA, aa, 1.0), np.nan))
            vB = np.where(both, (aa * bd - ab * ad) / np.where(both, det, 1.0),
                          np.where(onlyB, bd / np.where(onlyB, bb, 1.0), np.nan))
        self.both = both
        self.vA = vA
        self.vB = vB
        fit = (np.nan_to_num(vA)[..., None] * A + np.nan_to_num(vB)[..., None] * B)
        self.residual = np.abs(D - fit).max(axis=2)
        self.defined = ~np.isnan(vA) | ~np.isnan(vB)
        # under the knee: the unshadowed image (both lights) stays linear
        self.knee = (_f(aonly) + _f(bonly) - d0).max(axis=2) < KNEE
        self.delta = D

    def residual_p95(self):
        np = _np()
        m = self.defined & self.knee
        if not m.any():
            return float('nan')
        return float(np.percentile(self.residual[m], 95))


def _hue_sign(colour):
    """+1 when the light is warm (red over blue), -1 when it is cool."""
    return 1.0 if colour[0] > colour[2] else -1.0


def check_coloured(dark, aonly, bonly, a, b, ab, subject='',
                   colour_a=AMBER, colour_b=CYAN):
    """Each light's shadow is lit by the other light's colour (<rep>_ab), and
    the decomposition holds on a, b and ab."""
    bad = _same_size('coloured', subject, dark, aonly, bonly, a, b, ab)
    if bad:
        return bad
    np = _np()
    dec = Decomposition(dark, aonly, bonly, ab)
    base = dec.both & dec.knee
    n = int(base.sum())
    if not n:
        return Result('coloured', subject, False, 'no pixel both lights reach')
    with np.errstate(invalid='ignore'):
        a_sh = base & (dec.vA < SHADOWED) & (dec.vB > KEPT)    # A blocked, B lights
        b_sh = base & (dec.vB < SHADOWED) & (dec.vA > KEPT)
    rb = dec.delta[..., 0] - dec.delta[..., 2]
    a_hue = a_sh & (_hue_sign(colour_b) * rb > HUE_MIN)       # lit in B's hue
    b_hue = b_sh & (_hue_sign(colour_a) * rb > HUE_MIN)
    fa, fb = a_sh.sum() / float(n), b_sh.sum() / float(n)
    sa = a_hue.sum() / float(max(int(a_sh.sum()), 1))
    sb = b_hue.sum() / float(max(int(b_sh.sum()), 1))
    res = [Decomposition(dark, aonly, bonly, x).residual_p95() for x in (a, b, ab)]
    res_ok = all(r == r and r <= RESIDUAL for r in res)
    ok = (fa >= COLOURED_MIN and fb >= COLOURED_MIN and sa >= COLOURED_HUE_SHARE
          and sb >= COLOURED_HUE_SHARE and res_ok)
    return Result('coloured', subject, ok,
                  "A's shadow in B's light %s (>= %s, hue %s >= %s), B's in A's %s "
                  "(>= %s, hue %s), residual p95 a/b/ab %s (<= %.0f)" % (
                      _pct(fa), _pct(COLOURED_MIN), _pct(sa), _pct(COLOURED_HUE_SHARE),
                      _pct(fb), _pct(COLOURED_MIN), _pct(sb),
                      '/'.join('%.1f' % r for r in res), RESIDUAL))


def check_own(dark, aonly, bonly, x, shadowed='a', subject=''):
    """In x, only light `shadowed` ('a' or 'b') is shadowed: the other keeps
    its light on nearly every pixel it reaches, and the shadow exists."""
    bad = _same_size('own', subject, dark, aonly, bonly, x)
    if bad:
        return bad
    np = _np()
    dec = Decomposition(dark, aonly, bonly, x)
    if shadowed == 'a':
        v_sh, v_kept, reach_sh, reach_kept = dec.vA, dec.vB, dec.reachA, dec.reachB
    else:
        v_sh, v_kept, reach_sh, reach_kept = dec.vB, dec.vA, dec.reachB, dec.reachA
    kept_px = reach_kept & dec.knee & ~np.isnan(v_kept)
    sh_px = reach_sh & dec.knee & ~np.isnan(v_sh)
    if not kept_px.any() or not sh_px.any():
        return Result('own', subject, False, 'a light reaches no pixel under the knee')
    with np.errstate(invalid='ignore'):
        keep = float((v_kept[kept_px] >= KEPT).mean())
        shadow = float((v_sh[sh_px] < SHADOWED).mean())
    ok = keep >= OWN_KEEP and shadow >= OWN_SHADOW_MIN
    other = 'B' if shadowed == 'a' else 'A'
    return Result('own', subject, ok,
                  '%s keeps its light on %s (>= %s); %s shadowed on %s (>= %s)' % (
                      other, _pct(keep), _pct(OWN_KEEP), shadowed.upper(),
                      _pct(shadow), _pct(OWN_SHADOW_MIN)))


def check_independent(none, a, b, ab, subject=''):
    """Each shadow takes only its own light: ab == a + b - none."""
    bad = _same_size('independent', subject, none, a, b, ab)
    if bad:
        return bad
    pred = _f(a) + _f(b) - _f(none)
    diff = _np().abs(_f(ab) - pred).max(axis=2)
    mask = geometry(none, a, b, ab) & (_f(none).max(axis=2) < KNEE)
    n = int(mask.sum())
    if not n:
        return Result('independent', subject, False, 'no pixel under the knee')
    share = float((diff[mask] <= INDEPENDENT_TOL).mean())
    return Result('independent', subject, share >= INDEPENDENT_SHARE,
                  '|ab - (a + b - none)| <= %d on %s (>= %s)' % (
                      INDEPENDENT_TOL, _pct(share), _pct(INDEPENDENT_SHARE)))


def check_no_extra(none, a, b, ab, subject=''):
    """No darkening in ab that neither a nor b has."""
    bad = _same_size('no_extra', subject, none, a, b, ab)
    if bad:
        return bad
    geo = geometry(none, a, b, ab)
    n = int(geo.sum())
    if not n:
        return Result('no_extra', subject, False, 'no geometry')
    extra = (darkened(ab, none) & ~darkened(a, none, DARKEN / 2.0)
             & ~darkened(b, none, DARKEN / 2.0) & geo)
    frac = extra.sum() / float(n)
    return Result('no_extra', subject, frac <= NO_EXTRA_MAX,
                  'darkened in ab alone %s (<= %s)' % (_pct(frac), _pct(NO_EXTRA_MAX)))


def isolated(mask):
    """Pixels of mask with none of their 8 neighbours in mask."""
    np = _np()
    m = np.asarray(mask, dtype=bool)
    p = np.pad(m, 1)
    h, w = m.shape
    neighbours = np.zeros_like(m)
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            if dy or dx:
                neighbours |= p[1 + dy:1 + dy + h, 1 + dx:1 + dx + w]
    return m & ~neighbours


def check_speckle(x, ref, subject=''):
    """Isolated darkened pixels (shadow acne) are rare."""
    bad = _same_size('speckle', subject, x, ref)
    if bad:
        return bad
    geo = geometry(x, ref)
    n = int(geo.sum())
    if not n:
        return Result('speckle', subject, False, 'no geometry')
    frac = (isolated(darkened(x, ref) & geo).sum()) / float(n)
    return Result('speckle', subject, frac <= SPECKLE_MAX,
                  'isolated darkened pixels %s (<= %s)' % (_pct(frac), _pct(SPECKLE_MAX)))


def check_same(a, b, subject='', crop=None):
    """Byte-equal decoded pixels (inside crop when given)."""
    bad = _same_size('same', subject, a, b)
    if bad:
        return bad
    d = _np().abs(_rgb(_crop(a, crop)) - _rgb(_crop(b, crop))).max(axis=2)
    top = int(d.max()) if d.size else 0
    where = ' in %d,%d,%d,%d' % tuple(crop) if crop is not None else ''
    return Result('same', subject, d.size > 0 and top == 0,
                  'max |d| %d (== 0), %d pixels differ%s' % (top, int((d > 0).sum()), where))


def check_differs(a, b, subject='', darken=False, crop=None):
    """a differs from b on at least DIFFERS_MIN pixels; with darken, a is
    DARKER than b there (a shadow is present in a, not in b)."""
    bad = _same_size('differs', subject, a, b)
    if bad:
        return bad
    a, b = _crop(a, crop), _crop(b, crop)
    if darken:
        n = int((darkened(a, b) & geometry(a, b)).sum())
        what = 'darkened'
    else:
        n = int((_np().abs(_rgb(a) - _rgb(b)).max(axis=2) > 0).sum())
        what = 'differing'
    where = ' in %d,%d,%d,%d' % tuple(crop) if crop is not None else ''
    return Result('differs', subject, n >= DIFFERS_MIN,
                  '%d %s pixels (>= %d)%s' % (n, what, DIFFERS_MIN, where))


def shadow_area(x, ref):
    """The fraction of the geometry darkened in x against ref."""
    geo = geometry(x, ref)
    n = int(geo.sum())
    return (darkened(x, ref) & geo).sum() / float(n) if n else 0.0


def check_silhouette(front_a, front_none, side_a, side_none, subject=''):
    """Impostor casters face the light: from the side, the shadow is about as
    big as from the front (camera-facing billboards cast almost none)."""
    bad = _same_size('silhouette', subject, front_a, front_none, side_a, side_none)
    if bad:
        return bad
    front = shadow_area(front_a, front_none)
    side = shadow_area(side_a, side_none)
    ok = front >= SILHOUETTE_MIN and side >= SILHOUETTE_RATIO * front
    return Result('silhouette', subject, ok,
                  'side %s, front %s (side >= %.2f x front; front >= %s)' % (
                      _pct(side), _pct(front), SILHOUETTE_RATIO, _pct(SILHOUETTE_MIN)))


def check_oit(none, a, subject='', colour=AMBER):
    """A's shadow darkens the transparent surface, and the light it takes
    away is A's colour."""
    bad = _same_size('oit', subject, none, a)
    if bad:
        return bad
    geo = geometry(none, a)
    n = int(geo.sum())
    if not n:
        return Result('oit', subject, False, 'no geometry')
    dk = darkened(a, none, OIT_DARKEN) & geo
    frac = dk.sum() / float(n)
    loss = _f(none) - _f(a)
    dr = float(loss[..., 0][dk].clip(min=0).sum())
    db = float(loss[..., 2][dk].clip(min=0).sum())
    if _hue_sign(colour) > 0:
        hue_ok, hue = dr >= OIT_HUE_RATIO * db, 'sum dr %.0f >= %.1f x sum db %.0f' % (
            dr, OIT_HUE_RATIO, db)
    else:
        hue_ok, hue = db >= OIT_HUE_RATIO * dr, 'sum db %.0f >= %.1f x sum dr %.0f' % (
            db, OIT_HUE_RATIO, dr)
    return Result('oit', subject, frac >= OIT_MIN and hue_ok,
                  'darkened %s (>= %s), %s' % (_pct(frac), _pct(OIT_MIN), hue))


def check_overlay(gizmo, gizmohid, blob, blobhid, subject=''):
    """#433: a _move_gizmo CGO casts nothing (its shown and hidden renders are
    byte-equal); the control, an ordinary CGO in the same place, does."""
    same = check_same(gizmo, gizmohid, subject)
    control = check_differs(blob, blobhid, subject, darken=True)
    return Result('overlay', subject, same.ok and control.ok,
                  'gizmo: %s; control blob: %s' % (same.detail, control.detail))


def grid_cell(shape, layout=GRID_LAYOUT, margin=GRID_MARGIN):
    """(x0, y0, x1, y1) of cell `layout[2]` in a (cols, rows) grid over an
    image of `shape` (H, W, ...), `margin` pixels inside its edges. Cells are
    numbered left to right, top to bottom."""
    cols, rows, cell = layout
    h, w = shape[0], shape[1]
    cx, cy = cell % cols, cell // cols
    x0, x1 = (w * cx) // cols, (w * (cx + 1)) // cols
    y0, y1 = (h * cy) // rows, (h * (cy + 1)) // rows
    return (x0 + margin, y0 + margin, x1 - margin, y1 - margin)


def check_grid(grid_slab, grid_slabhid, nogrid_slab, nogrid_slabhid, subject='',
               layout=GRID_LAYOUT):
    """Grid mode: a cell is shadowed only by its own objects (the slab in the
    other cell leaves the molecule's cell byte-equal); the control without
    grid_mode shows the slab's shadow on the molecule."""
    bad = _same_size('grid', subject, grid_slab, grid_slabhid, nogrid_slab, nogrid_slabhid)
    if bad:
        return bad
    crop = grid_cell(_np().asarray(grid_slab).shape, layout)
    same = check_same(grid_slab, grid_slabhid, subject, crop=crop)
    control = check_differs(nogrid_slab, nogrid_slabhid, subject, darken=True)
    return Result('grid', subject, same.ok and control.ok,
                  'cell: %s; control no grid: %s' % (same.detail, control.detail))


# --- what each check reads ---------------------------------------------------------

def _coloured_tags(rep, rt):
    return ['%s_%s_rt%d' % (rep, k, rt) for k in ('dark', 'aonly', 'bonly', 'a', 'b', 'ab')]


def _set_tags(rep, rt):
    return ['%s_%s_rt%d' % (rep, k, rt) for k in ('none', 'a', 'b', 'ab')]


def l2_plan():
    """[(check, subject, func, tags, kwargs)] for every check of lighting_616.json."""
    plan = []
    for rep in REPS:
        for rt in RTS:
            s = '%s_rt%d' % (rep, rt)
            d, ao, bo = ['%s_%s_rt%d' % (rep, k, rt) for k in ('dark', 'aonly', 'bonly')]
            plan.append(('coloured', s, check_coloured, _coloured_tags(rep, rt), {}))
            for which in ('a', 'b'):
                plan.append(('own', '%s_%s_rt%d' % (rep, which, rt), check_own,
                             [d, ao, bo, '%s_%s_rt%d' % (rep, which, rt)],
                             {'shadowed': which}))
            plan.append(('independent', s, check_independent, _set_tags(rep, rt), {}))
            plan.append(('no_extra', s, check_no_extra, _set_tags(rep, rt), {}))
            plan.append(('speckle', '%s_ab_rt%d' % (rep, rt), check_speckle,
                         ['%s_ab_rt%d' % (rep, rt), '%s_none_rt%d' % (rep, rt)], {}))
    for rt in RTS:
        plan.append(('same', 'shadows_dark_rt%d' % rt, check_same,
                     ['shadows_dark_sh_ms1_rt%d' % rt, 'shadows_dark_ns_ms0_rt%d' % rt], {}))
        plan.append(('differs', 'shadows_dark_rt%d' % rt, check_differs,
                     ['shadows_dark_ns_ms1_rt%d' % rt, 'shadows_dark_ns_ms0_rt%d' % rt], {}))
    for rep in ('sticks', 'spheres'):
        plan.append(('silhouette', rep + '_rt0', check_silhouette,
                     ['%s_front_a_rt0' % rep, '%s_front_none_rt0' % rep,
                      '%s_side_a_rt0' % rep, '%s_side_none_rt0' % rep], {}))
    plan.append(('silhouette', 'spheres_ortho_rt0', check_silhouette,
                 ['spheres_front_a_ortho_rt0', 'spheres_front_none_ortho_rt0',
                  'spheres_side_a_ortho_rt0', 'spheres_side_none_ortho_rt0'], {}))
    for rep in ('transparent', 'glass'):
        plan.append(('oit', rep + '_rt0', check_oit,
                     ['%s_none_rt0' % rep, '%s_a_rt0' % rep], {}))
    plan.append(('overlay', 'ovl_rt0', check_overlay,
                 ['ovl_gizmo_rt0', 'ovl_gizmohid_rt0', 'ovl_blob_rt0', 'ovl_blobhid_rt0'], {}))
    return plan


def grid_plan():
    """[(check, subject, func, tags, kwargs)] for lighting_616_grid.json."""
    return [('grid', 'grid_rt%d' % rt, check_grid,
             ['grid_slab_rt%d' % rt, 'grid_slabhid_rt%d' % rt,
              'nogrid_slab_rt%d' % rt, 'nogrid_slabhid_rt%d' % rt], {})
            for rt in RTS]


# Images the scene files render for the eye only (the contact sheet): no check.
INFORMATIONAL = ('rig3_rt0', 'rig3_rt1', 'cartoon_ab_s512_rt0', 'cartoon_ab_s1024_rt0',
                 'cartoon_ab_s4096_rt0')

# The required grid result is rt0; rt1 is informational (plan 10.3).
GRID_REQUIRED = ('grid_rt0',)


def run_plan(directory, plan, checks=None, required=None):
    """Run every planned check whose name is in `checks` (all when None).
    A check whose subject is not in `required` (when given) is reported but
    never fails the run (its row says 'info')."""
    if not os.path.isdir(directory):
        raise Usage('%s is not a directory' % directory)
    results = []
    for check, subject, func, tags, kwargs in plan:
        if checks is not None and check not in checks:
            continue
        paths = [os.path.join(directory, t + '.png') for t in tags]
        missing = [t for t, p in zip(tags, paths) if not os.path.isfile(p)]
        if missing:
            r = Result(check, subject, False, 'missing %s' % ', '.join(t + '.png' for t in missing))
        else:
            r = func(*[load(p) for p in paths], subject=subject, **kwargs)
            r.check = check
        if required is not None and subject not in required:
            # informational: reported with its own verdict, never fails the run
            r.detail = '(info, %s) %s' % ('pass' if r.ok else 'fail', r.detail)
            r.ok = True
        results.append(r)
    if not results:
        raise Usage('no check selected')
    return results


def report(results, out=None):
    out = out or sys.stdout
    print('| Check | Subject | Result | Measured |', file=out)
    print('| --- | --- | --- | --- |', file=out)
    for r in results:
        print(r.row(), file=out)
    failed = [r for r in results if not r.ok]
    print('check_shadows: %d checks, %d failed' % (len(results), len(failed)), file=out)
    return 1 if failed else 0


def _box(text):
    try:
        box = tuple(int(v) for v in text.split(','))
    except ValueError:
        box = ()
    if len(box) != 4 or box[0] < 0 or box[1] < 0 or box[2] <= box[0] or box[3] <= box[1]:
        raise Usage('--crop wants X0,Y0,X1,Y1 with X0 < X1 and Y0 < Y1, not %r' % text)
    return box


def _checks(text, plan):
    if not text:
        return None
    names = [c for c in text.split(',') if c]
    known = sorted({p[0] for p in plan})
    unknown = [c for c in names if c not in known]
    if unknown:
        raise Usage('unknown checks %s (known: %s)' % (', '.join(unknown), ', '.join(known)))
    return set(names)


def _file(path):
    if not os.path.isfile(path):
        raise Usage('no such image %s' % path)
    return load(path)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    sub = ap.add_subparsers(dest='cmd')
    for name in ('l2', 'grid'):
        p = sub.add_parser(name)
        p.add_argument('dir')
        p.add_argument('--checks', help='comma-separated subset of the checks')
    for name in ('same', 'differs'):
        p = sub.add_parser(name)
        p.add_argument('a')
        p.add_argument('b')
        p.add_argument('--crop', help='X0,Y0,X1,Y1 (pixels, end-exclusive)')
        if name == 'differs':
            p.add_argument('--darken', action='store_true',
                           help='count pixels where A is darker than B')
    args = ap.parse_args(argv)
    try:
        if args.cmd == 'l2':
            plan = l2_plan()
            results = run_plan(args.dir, plan, _checks(args.checks, plan))
        elif args.cmd == 'grid':
            plan = grid_plan()
            results = run_plan(args.dir, plan, _checks(args.checks, plan), GRID_REQUIRED)
        elif args.cmd == 'same':
            crop = _box(args.crop) if args.crop else None
            results = [check_same(_file(args.a), _file(args.b),
                                  os.path.basename(args.a), crop=crop)]
        elif args.cmd == 'differs':
            crop = _box(args.crop) if args.crop else None
            results = [check_differs(_file(args.a), _file(args.b), os.path.basename(args.a),
                                     darken=args.darken, crop=crop)]
        else:
            ap.print_usage(sys.stderr)
            return 2
    except Usage as e:
        print('check_shadows.py: %s' % e, file=sys.stderr)
        return 2
    return report(results)


if __name__ == '__main__':
    sys.exit(main())
