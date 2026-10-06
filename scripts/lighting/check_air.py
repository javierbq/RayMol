#!/usr/bin/env python3
"""Pixel checks for the air, haze and dust (#618, lighting epic #610; L2).

    check_air.py l2 DIR [--checks c1,c2,...]    every check lighting_618.json is for
    check_air.py negative DIR                   the negative control: renders made
                                                WITHOUT the air pass must fail the
                                                checks that need it (NEGATIVE)

The scene file is scripts/lighting/scenes/lighting_618.json (its comment
describes every tag). The checks read, by tag:

  spot_{none,haze,hazedust,dust}_rt<n>   a warm shadowed spot plus a dim fill;
      none = no air, haze 0.6, hazedust 0.6/0.6, dust only (a narrower beam).
  spot_hazens_rt0                       the spot unshadowed (metal_shadows 1).
  spot_{haze,hazens}_ms0_rt0            shadow flag on / off at metal_shadows 0.
  backlit[_noair]_rt<n>, backlit_g09_rt0  a shadowed back light; g09: scatter 0.9.
  cross_{noair,none,a,b,ab}_rt<n>       red A from the left, blue B from the
      right, haze 0.5; noair: no air (the background mask); none: no light
      shadowed; a, b, ab: the shadowed lights.
  cross_dust_rt0                        the same lights, dust 0.8, no haze.
  s3[_noair]_rt<n>                      three shadowed lights, haze and dust.
  half_hazedust_rt<n>, filter9_haze_rt0  metal_light_air_resolution 2,
      metal_light_air_shadow_filter 2.
  t{0,05,1,2,4}_dust_rt0, t{2,4}_haze_rt0  the dust clock pinned at those seconds.
  still_rt0, movie_f{1,16,16b,17}_rt0, pinned05_rt0, speed0_{still,f16}_rt0
      the clock unpinned: an offscreen still, movie frames (mset 1 x48,
      movie_fps 30), a pin of 0.5 s, dust_speed 0.
  ovl_{air,noair}_rt0                   only a _move_gizmo CGO is shown.
  airoff_rt<n>                          haze 0 and dust 0, other air fields set.
  grid_{air,noair}_rt0                  grid_mode 1.
  whitebg_{none,haze}_rt<n>             bg_rgb white, cross_none's lights (no air,
      haze 0.5).

Checks (pure functions on arrays; testing/tests/raymol/lighting_air_check.py
exercises each on synthetic images, a pass and a fail):

  visible    spot_haze adds light against spot_none: at least VISIBLE_PX
             pixels gain light, by VISIBLE_MEAN luminance levels on average.
  rt_match   RT on and off agree (air minus its no-air twin): background
             pixels at least BG_MARGIN px from geometry differ by at most
             RT_BG_MAX between rt0 and rt1 (and the air is there: at least
             RT_PRESENT_PX of them gain light); on geometry under the knee
             with and without the air (the composite is linear there),
             |delta rt0 - delta rt1| <= RT_GEO_TOL on RT_GEO_SHARE of the
             pixels, mean <= RT_GEO_MEAN.
  shafts     every shadowed light darkens its own haze: on background pixels,
             cross_a drops red against cross_none by SHAFT_DARKEN levels on
             SHAFT_PX pixels and moves blue by at most SHAFT_OTHER (B: the
             reverse; ab: both drop); spot_haze is darker than spot_hazens
             behind the molecule; spot_haze_ms0 == spot_hazens_ms0 (no maps at
             metal_shadows 0).
  reach      A's (B's) shaft reaches into REACH_BOXES['a'] (['b']), where its
             beam is past the light's far plane: REACH_SHARE of the box's
             (at least REACH_PX) background pixels darken by REACH_DARKEN.
             Without the far-plane pull-back the air there reads lit.
  in_beams   the pixels the dust changes (hazedust against haze) number at
             least IN_BEAMS_PX, and IN_BEAMS_SHARE of them lie inside the haze
             footprint (haze against none) dilated by IN_BEAMS_DILATE px.
  colour     cross_dust's motes take their light's colour: in A's footprint
             (red-only haze in cross_none) red-dominant, in B's blue-dominant.
  unchanged  the composite adds light and changes nothing else:
             whitebg_haze == whitebg_none outside cross_none's footprint
             (against cross_noair, dilated; the same lights and haze), no
             pixel gets darker, and every white pixel stays 255.
  moves      consecutive frames of the dust strip differ.
  clock      t2_haze == t4_haze (haze is still); t2_dust != t4_dust; still ==
             movie_f1; movie_f16 == movie_f16b == pinned05; movie_f17 !=
             movie_f16; speed0_f16 == speed0_still.
  geometry   ovl_air == ovl_noair (no air without geometry).
  off        airoff == spot_none at rt0 and rt1; grid_air == grid_noair.
  half       half resolution differs from full, and their air agrees within
             HALF_TOL on HALF_SHARE of the air's pixels, mean <= HALF_MEAN,
             and on HALF_EDGE_SHARE of the silhouettes (no halo).
  filter     the 3x3 haze lookup differs from the one tap, and their air
             agrees within FILTER_TOL on FILTER_SHARE of its pixels.
  no_clip    backlit_g09 (scatter 0.9): at most SATURATED_MAX of the pixels
             have a channel at 255.

Reuses check_shadows.py (imported, never edited): load, luminance, geometry,
check_same, check_differs (DIFFERS_MIN pixels), run_plan and report.

Prints one markdown table row per check (paste it into the PR) and exits 0
when every check passes, 1 when one fails, 2 on a usage error. Pillow and
numpy (/Users/javier/repos/light-tools/venv).
"""
import argparse
import importlib.util
import io
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def _load_check_shadows():
    spec = importlib.util.spec_from_file_location(
        'lighting_check_shadows', os.path.join(HERE, 'check_shadows.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


cs = _load_check_shadows()
load = cs.load
luminance = cs.luminance
geometry = cs.geometry
check_same = cs.check_same
check_differs = cs.check_differs
run_plan = cs.run_plan
Result = cs.Result
Usage = cs.Usage

# --- thresholds ------------------------------------------------------------------
# FROZEN. The plan's values (plans/618.md 10.3), tuned once on round 1 (the
# full-resolution pass: rt_match's knee mask, the reach boxes and share) and
# round 2 (half resolution: the silhouette criterion), then frozen with every
# check passing on round 2 (43 of 43). testing/tests/raymol/lighting_air_check.py
# pins them; change them only with new L2 evidence.

ADD_MIN = 1               # a pixel is in an air footprint when a channel rises by
                          #   at least this (levels)
VISIBLE_PX = 2000         # visible: at least this many pixels gain light
VISIBLE_MEAN = 2.0        # ... by this much luminance on average
BG_MARGIN = 3             # background: pixels at least this far (px) from geometry
KNEE = 204                # geometry under the 8-bit knee: largest channel below this
RT_BG_MAX = 1             # rt_match: background |rt0 - rt1| at most this
RT_PRESENT_PX = 2000      # ... and the air lights at least this many of them
RT_GEO_TOL = 4            # rt_match: |delta rt0 - delta rt1| <= this, every channel
RT_GEO_SHARE = 0.99       # ... on at least this share of the geometry under the knee
RT_GEO_MEAN = 1.0         # ... with a mean of at most this
SHAFT_DARKEN = 8          # shafts: a channel drops by at least this (levels)
SHAFT_PX = 500            # ... on at least this many background pixels
SHAFT_OTHER = 2           # ... while the other light's channel moves by at most this
REACH_PX = 500            # reach: background pixels the light's box must hold
REACH_DARKEN = 24         # ... a channel drops by at least this (levels)
REACH_SHARE = 0.90        # ... on at least this share of them
REACH_BOXES = {           # (x0, y0, x1, y1), end-exclusive, at 1280x720: where the
    'a': (1200, 500, 1280, 720),   # beam leaves its map's far plane, past the
    'b': (0, 0, 64, 128),          # casters' sphere (A right and low, B left and
}                         #   high). Tuned on round 1 against a build without the
                          #   far-plane pull-back: A 100% of the box darkened by
                          #   24+ with it, 0.1% without; B 100% / 42%.
IN_BEAMS_PX = 50          # in_beams: the dust changes at least this many pixels
IN_BEAMS_SHARE = 0.98     # ... and this share of them is inside the haze footprint
IN_BEAMS_DILATE = 3       # ... dilated by this many pixels
FOOT_MIN = 2              # colour: a light's footprint: its channel rises by at least
                          #   this, the other's by less than ADD_MIN
MOTE_MIN = 10             # colour: a mote pixel: the dust adds at least this (largest
                          #   channel)
HUE_MIN = 8               # colour: the mote's own channel leads the other by this
COLOUR_SHARE = 0.90       # ... on at least this share of the motes in the footprint
COLOUR_PX = 20            # ... of which there are at least this many
UNCHANGED_DILATE = 3      # unchanged: the haze footprint, dilated by this many pixels
WHITE_PX = 1000           # unchanged: white pixels needed where white is required
HALF_TOL = 8              # half: |delta half - delta full| <= this
HALF_SHARE = 0.97         # ... on this share of the air's pixels
HALF_MEAN = 2.0           # ... mean at most this
HALF_EDGE_BAND = 2        # ... and at the silhouettes (pixels within this many px of
HALF_EDGE_PX = 200        #   both geometry and background, at least this many of
HALF_EDGE_SHARE = 0.97    #   them) within HALF_TOL on this share: no halo. Round 2:
                          #   99.83% (rt0 and rt1); a plain bilinear upsample of the
                          #   same air, simulated from the full images, 81.7%.
FILTER_TOL = 6            # filter: |delta 3x3 - delta 1 tap| <= this
FILTER_SHARE = 0.97       # ... on this share of the air's pixels
SATURATED_MAX = 0.02      # no_clip: at most this fraction of pixels has a channel at 255

RTS = (0, 1)
SCENE_SHAPE = (720, 1280)

# The checks that need the air pass: on renders made without it these must
# fail (the negative control). Subjects, by check.
NEGATIVE = {
    'visible': ('spot_haze_rt0', 'spot_haze_rt1'),
    'in_beams': ('spot_rt0', 'spot_rt1'),
    'shafts': ('cross_a_rt0', 'cross_b_rt0', 'cross_ab_rt0', 'cross_a_rt1',
               'cross_b_rt1', 'cross_ab_rt1', 'spot_rt0'),
    'moves': ('t0_t05', 't05_t1', 't1_t2', 't2_t4'),
    'colour': ('cross_dust_rt0',),
}

# Images the scene file renders for the eye only (the contact sheet): no check.
INFORMATIONAL = ('spot_dust_rt0', 'spot_dust_rt1', 'ortho_haze_rt0', 'glass_haze_rt0',
                 'transparent_haze_rt0', 'transparent_haze_rt1', 'rttrans_haze_rt1')


# --- pixels ---------------------------------------------------------------------

def _np():
    import numpy
    return numpy


def _f(a):
    return _np().asarray(a)[..., :3].astype('float64')


def _same_size(check, subject, *images):
    shapes = {tuple(_np().asarray(i).shape[:2]) for i in images}
    if len(shapes) != 1:
        return Result(check, subject, False, 'image sizes differ: %s' % sorted(shapes))
    return None


def _pct(x):
    return '%.3f%%' % (100.0 * x)


def added(img, ref):
    """img - ref per channel (float)."""
    return _f(img) - _f(ref)


def footprint(img, ref, level=ADD_MIN):
    """Pixels where img gains light over ref: a channel rises by >= level."""
    return added(img, ref).max(axis=2) >= level


def dilate(mask, r):
    """Square dilation of a boolean mask by r pixels."""
    np = _np()
    m = np.asarray(mask, dtype=bool)
    if r <= 0:
        return m.copy()
    h, w = m.shape
    p = np.pad(m, r)
    out = np.zeros_like(m)
    for dy in range(-r, r + 1):
        for dx in range(-r, r + 1):
            out |= p[r + dy:r + dy + h, r + dx:r + dx + w]
    return out


def background(*twins, margin=BG_MARGIN):
    """Pixels at least `margin` px from the geometry of the no-air twins."""
    return ~dilate(geometry(*twins), margin)


def _box_mask(shape, box):
    np = _np()
    m = np.zeros(shape[:2], dtype=bool)
    x0, y0, x1, y1 = box
    m[y0:y1, x0:x1] = True
    return m


# --- the checks -----------------------------------------------------------------

def check_visible(none, haze, subject=''):
    """The haze adds light: VISIBLE_PX pixels gain, by VISIBLE_MEAN on average."""
    bad = _same_size('visible', subject, none, haze)
    if bad:
        return bad
    gain = luminance(haze) - luminance(none)
    fp = footprint(haze, none)
    n = int(fp.sum())
    mean = float(gain[fp].mean()) if n else 0.0
    return Result('visible', subject, n >= VISIBLE_PX and mean >= VISIBLE_MEAN,
                  '%d pixels gain light (>= %d), mean +%.2f levels (>= %.1f)' % (
                      n, VISIBLE_PX, mean, VISIBLE_MEAN))


def check_rt_match(none0, none1, air0, air1, subject=''):
    """The air with ray tracing off (0) and on (1) agrees."""
    bad = _same_size('rt_match', subject, none0, none1, air0, air1)
    if bad:
        return bad
    np = _np()
    bg = background(none0, none1)
    nbg = int(bg.sum())
    if not nbg:
        return Result('rt_match', subject, False, 'no background pixel')
    top = int(np.abs(_f(air0) - _f(air1)).max(axis=2)[bg].max())
    present = int((footprint(air0, none0) & bg).sum())
    # Geometry where the composite is linear: the bases AND the results under
    # the knee. Past it, post_air_finish compresses what the air adds by how
    # bright the base already was, and the traced and raster bases differ, so
    # the same air term lands differently (tuned on round 1).
    geo = (geometry(none0, none1) & (_f(none0).max(axis=2) < KNEE)
           & (_f(none1).max(axis=2) < KNEE) & (_f(air0).max(axis=2) < KNEE)
           & (_f(air1).max(axis=2) < KNEE))
    ngeo = int(geo.sum())
    if ngeo:
        dd = np.abs(added(air0, none0) - added(air1, none1)).max(axis=2)[geo]
        share = float((dd <= RT_GEO_TOL).mean())
        mean = float(dd.mean())
    else:
        share, mean = 1.0, 0.0
    ok = (present >= RT_PRESENT_PX and top <= RT_BG_MAX and share >= RT_GEO_SHARE
          and mean <= RT_GEO_MEAN)
    return Result('rt_match', subject, ok,
                  'background |rt0 - rt1| max %d (<= %d), air on %d background px '
                  '(>= %d); geometry |d0 - d1| <= %d on %s (>= %s), mean %.2f (<= %.1f)' % (
                      top, RT_BG_MAX, present, RT_PRESENT_PX, RT_GEO_TOL, _pct(share),
                      _pct(RT_GEO_SHARE), mean, RT_GEO_MEAN))


_CH = {'r': 0, 'b': 2}


def check_shafts_cross(noair, none, x, shadowed='a', subject=''):
    """Each shadowed light darkens its own haze on the background (A red, B
    blue), and only its own: the other light's channel barely moves."""
    bad = _same_size('shafts', subject, noair, none, x)
    if bad:
        return bad
    np = _np()
    bg = background(noair)
    drop = _f(none) - _f(x)
    dr = int(((drop[..., 0] >= SHAFT_DARKEN) & bg).sum())
    db = int(((drop[..., 2] >= SHAFT_DARKEN) & bg).sum())
    move_r = float(np.abs(drop[..., 0])[bg].max()) if bg.any() else 0.0
    move_b = float(np.abs(drop[..., 2])[bg].max()) if bg.any() else 0.0
    if shadowed == 'a':
        ok = dr >= SHAFT_PX and move_b <= SHAFT_OTHER
        what = 'red drops on %d px (>= %d), blue moves <= %.0f (<= %d)' % (
            dr, SHAFT_PX, move_b, SHAFT_OTHER)
    elif shadowed == 'b':
        ok = db >= SHAFT_PX and move_r <= SHAFT_OTHER
        what = 'blue drops on %d px (>= %d), red moves <= %.0f (<= %d)' % (
            db, SHAFT_PX, move_r, SHAFT_OTHER)
    else:
        ok = dr >= SHAFT_PX and db >= SHAFT_PX
        what = 'red drops on %d px, blue on %d px (each >= %d)' % (dr, db, SHAFT_PX)
    return Result('shafts', subject, ok, what)


def check_shafts_spot(none, haze, hazens, subject=''):
    """The shadowed spot's haze is darker behind the molecule than the
    unshadowed spot's (background pixels)."""
    bad = _same_size('shafts', subject, none, haze, hazens)
    if bad:
        return bad
    bg = background(none)
    n = int((((luminance(hazens) - luminance(haze)) >= SHAFT_DARKEN) & bg).sum())
    return Result('shafts', subject, n >= SHAFT_PX,
                  'haze darker than hazens on %d background px (>= %d)' % (n, SHAFT_PX))


def check_reach(noair, none, x, box, channel='r', subject=''):
    """The light's shaft reaches into `box`, past the casters' sphere."""
    bad = _same_size('reach', subject, noair, none, x)
    if bad:
        return bad
    drop = (_f(none) - _f(x))[..., _CH[channel]]
    inside = _box_mask(_np().asarray(x).shape, box) & background(noair)
    n = int(inside.sum())
    dark = int(((drop >= REACH_DARKEN) & inside).sum())
    share = dark / float(n) if n else 0.0
    return Result('reach', subject, n >= REACH_PX and share >= REACH_SHARE,
                  '%s of %d background px in %d,%d,%d,%d (>= %d) darkened by >= %d '
                  '(>= %s)' % ((_pct(share), n) + tuple(box) +
                               (REACH_PX, REACH_DARKEN, _pct(REACH_SHARE))))


def check_in_beams(none, haze, hazedust, subject=''):
    """Dust lights only inside the beams: the pixels it changes lie in the
    haze footprint."""
    bad = _same_size('in_beams', subject, none, haze, hazedust)
    if bad:
        return bad
    np = _np()
    changed = np.abs(_f(hazedust) - _f(haze)).max(axis=2) > 0
    n = int(changed.sum())
    fp = dilate(footprint(haze, none), IN_BEAMS_DILATE)
    share = float((changed & fp).sum()) / n if n else 0.0
    return Result('in_beams', subject, n >= IN_BEAMS_PX and share >= IN_BEAMS_SHARE,
                  'dust changes %d px (>= %d), %s inside the haze footprint (>= %s)' % (
                      n, IN_BEAMS_PX, _pct(share), _pct(IN_BEAMS_SHARE)))


def check_colour(noair, none, dust, subject=''):
    """Motes take their light's colour: red in A's footprint, blue in B's."""
    bad = _same_size('colour', subject, noair, none, dust)
    if bad:
        return bad
    bg = background(noair)
    inc = added(none, noair)
    a_fp = bg & (inc[..., 0] >= FOOT_MIN) & (inc[..., 2] < ADD_MIN)
    b_fp = bg & (inc[..., 2] >= FOOT_MIN) & (inc[..., 0] < ADD_MIN)
    mote_add = added(dust, noair)
    mote = mote_add.max(axis=2) >= MOTE_MIN
    lead = mote_add[..., 0] - mote_add[..., 2]
    ma, mb = mote & a_fp, mote & b_fp
    na, nb = int(ma.sum()), int(mb.sum())
    sa = float((lead[ma] >= HUE_MIN).mean()) if na else 0.0
    sb = float((-lead[mb] >= HUE_MIN).mean()) if nb else 0.0
    ok = na >= COLOUR_PX and nb >= COLOUR_PX and sa >= COLOUR_SHARE and sb >= COLOUR_SHARE
    return Result('colour', subject, ok,
                  "A's motes %d (>= %d), red-led %s; B's motes %d, blue-led %s (>= %s)" % (
                      na, COLOUR_PX, _pct(sa), nb, _pct(sb), _pct(COLOUR_SHARE)))


def check_unchanged(none, haze, white_none, white_haze, subject='', need_white=False):
    """Outside the haze footprint (found on black, dilated) the white-background
    pair is byte-equal (and there is such an outside), no pixel of it gets
    darker in any channel, and no white pixel loses its 255."""
    bad = _same_size('unchanged', subject, none, haze, white_none, white_haze)
    if bad:
        return bad
    np = _np()
    outside = ~dilate(footprint(haze, none), UNCHANGED_DILATE)
    noutside = int(outside.sum())
    d = np.abs(_f(white_haze) - _f(white_none)).max(axis=2)
    top = int(d[outside].max()) if noutside else 0
    darker = int((_f(white_haze) < _f(white_none)).any(axis=2).sum())
    white = (_f(white_none) >= 255).all(axis=2)
    nwhite = int(white.sum())
    kept = bool((_f(white_haze)[white] >= 255).all()) if nwhite else True
    ok = (noutside > 0 and top == 0 and darker == 0 and kept
          and (nwhite >= WHITE_PX or not need_white))
    return Result('unchanged', subject, ok,
                  'outside the footprint (%d px, > 0) max |d| %d (== 0); %d px darker '
                  '(== 0); %d white px%s, %s' % (
                      noutside, top, darker, nwhite,
                      ' (>= %d)' % WHITE_PX if need_white else '',
                      'all stay 255' if kept else 'some lose 255'))


def _delta_agreement(check, subject, none, a, b, tol, share_min, mean_max=None):
    np = _np()
    differs = int((np.abs(_f(a) - _f(b)).max(axis=2) > 0).sum())
    fp = footprint(a, none) | footprint(b, none)
    n = int(fp.sum())
    if n:
        d = np.abs(added(a, none) - added(b, none)).max(axis=2)[fp]
        share, mean = float((d <= tol).mean()), float(d.mean())
    else:
        share, mean = 0.0, 0.0
    ok = differs >= cs.DIFFERS_MIN and n > 0 and share >= share_min
    if mean_max is not None:
        ok = ok and mean <= mean_max
    return Result(check, subject, ok,
                  '%d px differ (>= %d); air on %d px, |delta| <= %d on %s (>= %s), mean %.2f%s' % (
                      differs, cs.DIFFERS_MIN, n, tol, _pct(share), _pct(share_min), mean,
                      '' if mean_max is None else ' (<= %.1f)' % mean_max))


def silhouettes(none, band=HALF_EDGE_BAND):
    """Pixels within `band` px of both geometry and background (the no-air
    twin's): where a plain upsample would bleed the air across an edge."""
    geo = geometry(none)
    return dilate(geo, band) & dilate(~geo, band)


def check_half(none, full, half, subject=''):
    """Half resolution differs from full but its air agrees, over the frame
    and at the silhouettes (no halo)."""
    bad = _same_size('half', subject, none, full, half)
    if bad:
        return bad
    np = _np()
    frame = _delta_agreement('half', subject, none, half, full, HALF_TOL, HALF_SHARE,
                             HALF_MEAN)
    edge = silhouettes(none)
    ne = int(edge.sum())
    if ne:
        d = np.abs(added(half, none) - added(full, none)).max(axis=2)[edge]
        share = float((d <= HALF_TOL).mean())
    else:
        share = 0.0
    ok = frame.ok and ne >= HALF_EDGE_PX and share >= HALF_EDGE_SHARE
    return Result('half', subject, ok,
                  '%s; silhouettes %d px (>= %d), |delta| <= %d on %s (>= %s)' % (
                      frame.detail, ne, HALF_EDGE_PX, HALF_TOL, _pct(share),
                      _pct(HALF_EDGE_SHARE)))


def check_filter(none, one, nine, subject=''):
    """The 3x3 haze lookup differs from the one tap but their air agrees."""
    bad = _same_size('filter', subject, none, one, nine)
    if bad:
        return bad
    return _delta_agreement('filter', subject, none, nine, one, FILTER_TOL, FILTER_SHARE)


def check_no_clip(img, subject=''):
    """Strong forward scattering stays capped: few saturated pixels."""
    frac = float((_f(img).max(axis=2) >= 255).mean())
    return Result('no_clip', subject, frac <= SATURATED_MAX,
                  'saturated %s (<= %s)' % (_pct(frac), _pct(SATURATED_MAX)))


# --- what each check reads ---------------------------------------------------------

def l2_plan():
    """[(check, subject, func, tags, kwargs)] for every check of lighting_618.json."""
    plan = []
    for rt in RTS:
        plan.append(('visible', 'spot_haze_rt%d' % rt, check_visible,
                     ['spot_none_rt%d' % rt, 'spot_haze_rt%d' % rt], {}))
    for name, twin, air in (('spot_haze', 'spot_none', 'spot_haze'),
                            ('spot_hazedust', 'spot_none', 'spot_hazedust'),
                            ('backlit', 'backlit_noair', 'backlit'),
                            ('s3', 's3_noair', 's3'),
                            ('half', 'spot_none', 'half_hazedust')):
        plan.append(('rt_match', name, check_rt_match,
                     [twin + '_rt0', twin + '_rt1', air + '_rt0', air + '_rt1'], {}))
    for rt in RTS:
        for k in ('a', 'b', 'ab'):
            plan.append(('shafts', 'cross_%s_rt%d' % (k, rt), check_shafts_cross,
                         ['cross_noair_rt%d' % rt, 'cross_none_rt%d' % rt,
                          'cross_%s_rt%d' % (k, rt)], {'shadowed': k}))
    plan.append(('shafts', 'spot_rt0', check_shafts_spot,
                 ['spot_none_rt0', 'spot_haze_rt0', 'spot_hazens_rt0'], {}))
    plan.append(('shafts', 'ms0_rt0', check_same,
                 ['spot_haze_ms0_rt0', 'spot_hazens_ms0_rt0'], {}))
    for rt in RTS:
        for k, ch in (('a', 'r'), ('b', 'b')):
            plan.append(('reach', 'cross_%s_rt%d' % (k, rt), check_reach,
                         ['cross_noair_rt%d' % rt, 'cross_none_rt%d' % rt,
                          'cross_%s_rt%d' % (k, rt)],
                         {'box': REACH_BOXES[k], 'channel': ch}))
    for rt in RTS:
        plan.append(('in_beams', 'spot_rt%d' % rt, check_in_beams,
                     ['spot_none_rt%d' % rt, 'spot_haze_rt%d' % rt,
                      'spot_hazedust_rt%d' % rt], {}))
    plan.append(('colour', 'cross_dust_rt0', check_colour,
                 ['cross_noair_rt0', 'cross_none_rt0', 'cross_dust_rt0'], {}))
    for rt in RTS:
        plan.append(('unchanged', 'whitebg_rt%d' % rt, check_unchanged,
                     ['cross_noair_rt%d' % rt, 'cross_none_rt%d' % rt,
                      'whitebg_none_rt%d' % rt, 'whitebg_haze_rt%d' % rt],
                     {'need_white': rt == 1}))
    strip = ('0', '05', '1', '2', '4')
    for a, b in zip(strip, strip[1:]):
        plan.append(('moves', 't%s_t%s' % (a, b), check_differs,
                     ['t%s_dust_rt0' % b, 't%s_dust_rt0' % a], {}))
    same, differs = check_same, check_differs
    plan += [
        ('clock', 'haze_still', same, ['t2_haze_rt0', 't4_haze_rt0'], {}),
        ('clock', 'dust_moves', differs, ['t4_dust_rt0', 't2_dust_rt0'], {}),
        ('clock', 'still_is_f1', same, ['still_rt0', 'movie_f1_rt0'], {}),
        ('clock', 'f16_repeat', same, ['movie_f16_rt0', 'movie_f16b_rt0'], {}),
        ('clock', 'f16_is_pin', same, ['movie_f16_rt0', 'pinned05_rt0'], {}),
        ('clock', 'f17_moves', differs, ['movie_f17_rt0', 'movie_f16_rt0'], {}),
        ('clock', 'speed0', same, ['speed0_f16_rt0', 'speed0_still_rt0'], {}),
    ]
    plan.append(('geometry', 'ovl_rt0', check_same,
                 ['ovl_air_rt0', 'ovl_noair_rt0'], {}))
    for rt in RTS:
        plan.append(('off', 'airoff_rt%d' % rt, check_same,
                     ['airoff_rt%d' % rt, 'spot_none_rt%d' % rt], {}))
    plan.append(('off', 'grid_rt0', check_same, ['grid_air_rt0', 'grid_noair_rt0'], {}))
    for rt in RTS:
        plan.append(('half', 'half_rt%d' % rt, check_half,
                     ['spot_none_rt%d' % rt, 'spot_hazedust_rt%d' % rt,
                      'half_hazedust_rt%d' % rt], {}))
    plan.append(('filter', 'filter9_rt0', check_filter,
                 ['spot_none_rt0', 'spot_haze_rt0', 'filter9_haze_rt0'], {}))
    plan.append(('no_clip', 'backlit_g09_rt0', check_no_clip, ['backlit_g09_rt0'], {}))
    return plan


def negative_plan():
    """The l2 plan's entries the negative control expects to FAIL."""
    return [p for p in l2_plan() if p[1] in NEGATIVE.get(p[0], ())]


def run_negative(directory):
    """Run the checks that need the air pass on renders made without it.
    Each row reports whether it failed as it must; returns the results with
    `ok` meaning 'failed as expected'."""
    results = run_plan(directory, negative_plan())
    for r in results:
        failed = not r.ok and not r.detail.startswith('missing')
        r.detail = '(%s without the pass) %s' % ('fails' if not r.ok else 'PASSES', r.detail)
        r.ok = failed
    return results


def report(results, out=None):
    """check_shadows.report under this file's name."""
    out = out or sys.stdout
    buf = io.StringIO()
    rc = cs.report(results, buf)
    out.write(buf.getvalue().replace('check_shadows:', 'check_air:'))
    return rc


def _checks(text, plan):
    if not text:
        return None
    names = [c for c in text.split(',') if c]
    known = sorted({p[0] for p in plan})
    unknown = [c for c in names if c not in known]
    if unknown:
        raise Usage('unknown checks %s (known: %s)' % (', '.join(unknown), ', '.join(known)))
    return set(names)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    sub = ap.add_subparsers(dest='cmd')
    p = sub.add_parser('l2')
    p.add_argument('dir')
    p.add_argument('--checks', help='comma-separated subset of the checks')
    p = sub.add_parser('negative')
    p.add_argument('dir')
    args = ap.parse_args(argv)
    try:
        if args.cmd == 'l2':
            plan = l2_plan()
            results = run_plan(args.dir, plan, _checks(args.checks, plan))
        elif args.cmd == 'negative':
            results = run_negative(args.dir)
        else:
            ap.print_usage(sys.stderr)
            return 2
    except Usage as e:
        print('check_air.py: %s' % e, file=sys.stderr)
        return 2
    return report(results)


if __name__ == '__main__':
    sys.exit(main())
