#!/usr/bin/env python3
"""Pixel checks for HDR colour and exposure under a light rig (#624, lighting epic #610; L2).

    check_hdr.py l2 DIR [--checks c1,c2,...] [--json FILE]
                        every proof, guard and report of lighting_624.json
    check_hdr.py negative DIR [--json FILE]
                        the negative control: each proof run on the knee twins
                        (metal_light_hdr 2, the 8-bit soft knee) must FAIL
    check_hdr.py table DIR [--json FILE]
                        both, as the markdown the PR pastes (a Kind column)
    check_hdr.py model [--json FILE]
                        the python model behind the thresholds: the tone curve's
                        table, then every check on synthetic renders of the scene
                        file made with the twin (an HDR build) and with the knee
                        (a build before #624); the HDR set must pass and every
                        proof must fail on the knee set

THE TWIN. tone() is the python twin of D2 (plans/624.md): hue-preserving on the
largest channel m, the identity up to the knee k, then an extended-Reinhard
shoulder that is C1 at k, exactly 1 at the white point W and 1 beyond (a
pixel at or over W keeps its hue at full scale, c / m). tone_inverse() is its
closed form (rationalised). soft_knee() is mat_soft_knee (the 8-bit knee every
rig path takes before #624). glass_cover_*, air_* and glints_* are D7's and
D8's composites. testing/tests/raymol/lighting_hdr.py (#624 part 2) ties the
twin to the C++ curve, pymol::LightTone; TONE_KNEE and TONE_WHITE must equal
LightTone.h. Part 6 tunes (k, W) once and freezes them in both places.

THE SCENE FILE is scripts/lighting/scenes/lighting_624.json (its comment
describes every tag): 1rx1 at 1280x720 on black, grey80 subjects unless named,
every rig the scene's own. A tag `<base>_knee_rt<n>` is the knee twin of
`<base>_rt<n>`: the same lines plus `_l624_opt('metal_light_hdr', 2)`.

PROOFS (each must FAIL on the knee: the negative control, and the round-0
renders of a build before #624; a proof the knee passes is strengthened or
reclassified, plans/624.md 3.3):

  sweep        the prototype spot on a grey80 surface at intensity 0, 0.6, 1.2,
               2.0, 3.5. Footprint: pixels where sweep_1p2 is brighter than
               sweep_0 by SWEEP_FOOT luminance levels. sweep_rt0: the mean
               rises by SWEEP_STEP at each step; at 3.5 at most SWEEP_CLIP of
               the footprint has a channel at CLIP_LEVEL or more; the relative
               chroma ((max - min) / max, the 5600 K light's warmth) at 3.5 is
               at least SWEEP_CHROMA x that at 1.2; the 5-95% luminance spread
               ratio 3.5 / 1.2 is at least the knee twins' (x SWEEP_SPREAD).
               sweep_e05: 3.5 at exposure 0.5 lands between 1.2 and 2.0
               (SWEEP_E05_MARGIN levels each side): exposure acts in scene
               units. sweep_rt1: the traced 3.5 keeps the chroma and clips no
               more.
  recover      rec_<rep>_a = (intensity 3.5, metal_exposure 4/7) against
               rec_<rep>_b = (2.0, 1): the same light in scene units, so the
               pair agrees (max REC_MAX, p99 REC_P99, mean REC_MEAN levels on
               the geometry), and b reaches the shoulder (REC_BRIGHT of the
               geometry at KNEE_LEVEL or more). Surface, cartoon, sticks,
               spheres and the bezier tube at rt0, the surface at rt1.
  air_recover  the same pair with haze 0.3 (rec_air_a/b): every lit pixel,
               the same bounds, and the air present on AIR_SHARE of the frame
               (background pixels lit in b; the no-air rec_surface_b masks the
               geometry).
  hue          lighting_613's orange key and cyan rim (both at intensity 1.6:
               x2.5 is 4, the field's top) at x1 and x2.5: in
               each light's own footprint (x1's pixels within HUE_CLASS_DEG of
               the light's hue, with a channel at HUE_LEVEL or more: the light
               is on the shoulder at x2.5) the hue moves at most HUE_DEG and
               the chroma keeps HUE_CHROMA of x1's.
  peak         a white key (highlight 0.7, material_env 2) on gold metallic and
               orange plastic spheres and surface at intensity 1, 2, 3.
               metallic_tint: the brightest PEAK_TOP of the geometry keeps the
               base's hue within PEAK_HUE and PEAK_CHROMA of its chroma at i2,
               i3 and i3 traced (rt1). metallic_recover: i3 at exposure 2/3
               against i2 on i2's highlight (its brightest PEAK_HL_SHARE):
               max REC_MAX, mean REC_MEAN. *_steps (guards): the highlight's
               p99 rises from i1 to i2 by PEAK_STEP and never falls to i3.
  glints       clear glass, every light's highlight 1 (hl1) or 0 (hl0): the
               glint is hl1 - hl0. glass_recover: i3 at exposure 1/3 against
               i1 (hl1), REC bounds: the glint curve is linear in scene units
               under HDR (D7). glass_growth: the glint's p99 grows by
               GLINT_GROW from i1 to i3 (the knee's is saturated at i1).
               Guards: glass_rules_i1/_i3 (check_materials'
               glint rules: sparse, peaked, positive, white), glass_clip (at
               most GLINT_CLIP of the glint pixels clip at i3), glass_body
               (coloured glass whose glint overlaps its lit body: at most
               GLINT_CLIP of those pixels clip, and the glint adds light there).

GUARDS (must pass with HDR; the knee is their reference where they read one):

  shadows      #618's red and blue lights, both shadowed, at intensity 3: each
               light's shadow keeps the other light's hue (check_shadows'
               HUE_MIN and COLOURED_MIN: red-led and blue-led pixels each cover
               COLOURED_MIN of the geometry); each lobe's chroma against the
               knee's is reported.
  display      white background, rt1, labels, a lines rep and a cartoon under a
               bright rig: HDR at exposure 0.6 equals exposure 1 on every pixel
               outside the cartoon (where display_e1 differs from
               display_nocartoon, dilated DISPLAY_DILATE px). The knee pair is
               reported (#13's exposure scales the whole frame).
  unlit        white, navy and magenta lines reps and a label over a bright lit
               cartoon (rt1): every pixel that is exactly an overlay colour in
               the knee render is exactly it with HDR (each colour on
               UNLIT_SHARE of the frame); the background stays. (Round 0:
               measurement dashes are lit geometry, drawn at the lit cartoon's
               levels, and labels ignored their colour settings, drawn
               magenta, or were not drawn at all; so the overlay colours are
               the lines', and the label counts with the magenta lines.)
  below_knee   a rig at intensity 0.4: HDR equals the knee exactly on the
               pixels whose knee max channel is at most BELOW_LEVEL
               (round(255 k) - 2), which are BELOW_SHARE of the geometry.
  continuity   the three_point, softbox, rembrandt and neon presets: pixels
               whose knee max channel is under CONT_LEVEL differ by at most
               CONT_TOL; the mean change elsewhere is reported.
  edges        a rim light at 3.5 behind the molecule, metal_msaa 1: on the
               silhouette (geometry pixels touching the background: the partly
               covered ones), the partial pixels (EDGE_LO..EDGE_HI of the
               3x3 maximum over the fully covered pixels just inside, within
               EDGE_BAND px) number within EDGE_COUNT_TOL of the knee's, and
               the pixels brighter than that maximum by EDGE_OVER are no more
               than the knee's (x (1 + EDGE_COUNT_TOL), + EDGE_SLACK of the
               silhouette): no fringe (tone after a resolve would brighten
               the partial pixels, T(cov x) > cov T(x)).
  fog          depth_cue 1, white background, rt1: the background is exact,
               and pixels within FOG_NEAR of it in the knee render stay within
               FOG_RATIO x their knee distance + FOG_TOL with HDR (there are
               some).
  export       ray_opaque_background 0: the alpha channel equals the knee's
               (and the background is transparent: some alpha under 255).
  oit          a 50% surface over the cartoon plus a glass surface at 3.5:
               wherever the knee's luminance exceeds OIT_LUM, HDR keeps at
               least OIT_RATIO of it (no holes), rt0 and rt1.

REPORTS (never fail): haze683 (#618's L4 rig: three_point, haze 0.35, dust
0.6; mean, std and saturated share inside the molecule and the background's
mean, HDR and knee at exposure 1 and 0.5, for #683), aces (metal_tonemap 1:
the same numbers, HDR and knee), and display's knee pair.

Reuses check_air.py (dilate) and through it check_shadows.py (load, luminance,
geometry, Result, Usage, report, HUE_MIN, COLOURED_MIN), and check_materials.py
(the glint rules): imported by path, never edited. Prints one markdown row per
check and exits 0 when every row passes, 1 when one fails, 2 on a usage error.
Pillow and numpy (/Users/javier/repos/light-tools/venv). The checks are pure
functions on arrays; testing/tests/raymol/lighting_hdr_check.py runs each on
the model's synthetic images.
"""
import argparse
import colorsys
import importlib.util
import io
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def _load(name, filename):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ca = _load('lighting_check_air', 'check_air.py')
cs = ca.cs                      # one check_shadows instance, check_air's
cm = _load('lighting_check_materials', 'check_materials.py')
load = cs.load
luminance = cs.luminance
geometry = cs.geometry
Result = cs.Result
Usage = cs.Usage
dilate = ca.dilate

# --- the twin (D2) ---------------------------------------------------------------
# The curve, tuned ONCE (plans/624.md D2, #624 part 6) within k 0.5-0.8 and
# W 6-16 on round 1's renders (built at the initial k 0.6, W 8; each candidate
# simulated by mapping the renders back to scene units through the built curve
# and forward through the candidate) and FROZEN here, in LightTone.h and in
# both MSL copies (CI pins them equal). The orchestrator's rule (open question
# 5): keep moderate rigs closest to today's look, subject to the sweep staying
# distinguishable to 3.5x. k 0.6 passes the sweep's spread ratio only at W 6
# (0.824 against the knee's 0.820, inside the 0.005 the ratio moves between
# neighbouring W, and 5% of the glass glints clip); k 0.55 is the highest knee
# that passes at every W 6-16 with margin (W 10: 0.828, nothing clipped at
# 3.5), and T(1) = 0.776 (>= 0.75). W 10 over 8: no glint or sweep pixel at
# the white point. Lower knees separate more but move moderate rigs further
# from the knee (mean |hdr - knee| on the presets and the 0.6/1.2 sweep: 5.5
# levels at k 0.55, 6.9 at k 0.5, 4.3 at k 0.6).
TONE_KNEE = 0.55
TONE_WHITE = 10.0
SOFT_KNEE = 0.8                  # mat_soft_knee's knee (the 8-bit knee before #624)

# --- thresholds --------------------------------------------------------------------
# PROVISIONAL (#624 part 1): modelled with `check_hdr.py model` (the numbers
# quoted are the model's: 'hdr' the twin, 'knee' a build before #624) and
# checked against the round-0 renders of a build before #624 (every proof
# fails there). Part 6 freezes them from round 1's measured extremes by the
# half-margin rule (#613, #615); lighting_hdr_check.py pins them.

CLIP_LEVEL = 254          # a channel this high counts as clipped
KNEE_LEVEL = 204          # round(255 x 0.8): where mat_soft_knee starts
SWEEP_FOOT = 8            # sweep footprint: sweep_1p2 brighter than sweep_0 by this
                          #   (luminance levels)
SWEEP_MIN_SHARE = 0.02    # ... covering at least this share of the frame
SWEEP_STEP = 8            # sweep: the footprint's mean rises by this at each step
                          #   (model: hdr +45/+38/+34, knee +47/+44/+38: a guard
                          #   inside the proof, the knee never clips either)
SWEEP_CLIP = 0.01         # sweep: at most this share of the footprint clips at 3.5
                          #   (model: hdr 0, knee 0)
SWEEP_CHROMA = 0.7        # sweep: chroma at 3.5 over chroma at 1.2 at least this
                          #   (model: hdr 1.10, knee 0.49)
SWEEP_SPREAD = 1.0        # sweep: spread ratio at least the knee's x this
                          #   (model: hdr 1.066 against the knee's 1.028)
SWEEP_E05_MARGIN = 2.0    # sweep_e05: the mean sits this far inside (1.2, 2.0)
                          #   (model: hdr +24 / +14, knee -12: #13 halves the knee)
REC_MAX = 3               # recover: largest channel difference at most this
REC_P99 = 2               # ... its 99th percentile at most this
REC_MEAN = 0.5            # ... its mean at most this (model: hdr max 0, mean 0.00;
                          #   knee max 95, mean 49; the real pair adds float rounding
                          #   of e x I, at most a level: lighting_hdr.py TestCommute)
REC_BRIGHT = 0.02         # recover: b has at least this share of the geometry at
                          #   KNEE_LEVEL or more (the pair reaches the shoulder)
REC_MIN_SHARE = 0.01      # recover: the geometry covers at least this of the frame
AIR_SHARE = 0.02          # air_recover: background pixels lit by the air in b
BG_MARGIN = 3             # background: at least this far (px) from the geometry
HUE_CHROMA_MIN = 0.15     # hue: x1 pixels at least this chromatic ...
HUE_LUM_MIN = 16.0        # ... and this bright are in a light's footprint
HUE_CLASS_DEG = 40.0      # ... the light's, when within this of its hue
HUE_LEVEL = 128           # ... and where x1's largest channel is at least this (at
                          #   x2.5 the light is on the shoulder: the knee whitens it)
HUE_SHARE = 0.002         # ... each light's footprint covers this share of the frame
HUE_DEG = 15.0            # hue: mean hue shift x1 -> x2.5 at most this (degrees)
                          #   (model: hdr 0.2 / 0.2, knee 21.6 / 8.7: key / rim)
HUE_CHROMA = 0.7          # hue: chroma at x2.5 over x1 at least this
                          #   (model: hdr 1.04 / 1.04, knee 0.73 / 0.73)
PEAK_TOP = 0.02           # peak tint: the brightest share of the geometry
PEAK_HUE = 25.0           # ... its mean colour's hue within this of the base's
                          #   (check_materials' TINT_HUE)
PEAK_CHROMA = 0.5         # ... and its chroma at least this x the base's
                          #   (model: hdr 0.93, knee 0.13-0.18)
PEAK_HL_SHARE = 0.05      # peak recover: i2's brightest share of the geometry
PEAK_STEP = 4             # peak steps: the highlight's p99 rises i1 -> i2 by this
                          #   (model: hdr +15 metallic / +14 plastic, knee +23 / +17:
                          #   a guard, the knee never clips)
GLINT_GROW = 4            # glints: the glint's p99 grows i1 -> i3 by this
                          #   (round 0, the knee: 111 -> 112: its glints are
                          #   saturated already at i1, so growth is a proof, not
                          #   the guard plans/624.md 3.3 feared; model: hdr +6,
                          #   knee -9. glass_recover: model hdr max 0, knee max 99;
                          #   round 0 max 98, mean 24)
GLINT_CLIP = 0.02         # glints: at most this share of glint pixels clips
BODY_LUM = 24.0           # glass_body: the lit body (hl0 luminance at least this)
SHADOW_HUE_MIN = cs.HUE_MIN          # shadows: a channel leads the other by this
SHADOW_COLOURED_MIN = cs.COLOURED_MIN  # ... on this share of the geometry, each light
DISPLAY_DILATE = 3        # display: the cartoon footprint dilated by this (px)
UNLIT_SHARE = 0.0002      # unlit: each overlay colour on this share of the frame
UNLIT_COLOURS = {         # the scene's overlay colours (8-bit, exact)
    'white lines': (255, 255, 255),
    'navy lines': (0, 0, 89),
    'magenta lines and label': (255, 0, 255),
}
BELOW_LEVEL = int(round(255 * TONE_KNEE)) - 2   # below_knee: knee max channel at most this
BELOW_SHARE = 0.80        # ... on at least this share of the geometry
CONT_LEVEL = 0.55 * 255   # continuity: knee max channel under this
CONT_TOL = 2              # ... differs by at most this
EDGE_BAND = 2             # edges: the fully covered pixels within this of the silhouette
EDGE_LO, EDGE_HI = 0.10, 0.90   # edges: a partial pixel's share of the interior maximum
EDGE_COUNT_TOL = 0.15     # edges: counts within this of the knee's
EDGE_OVER = 2.0           # edges: a fringe pixel is brighter than its 3x3 interior
                          #   maximum by more than this (luminance levels)
EDGE_SLACK = 0.002        # edges: fringe pixels allowed over the knee's (band share)
FOG_NEAR = 16             # fog: pixels within this of the background in the knee
                          #   (round 0: 3434 px; none within 3)
FOG_RATIO = 1.5           # ... stay within this x their knee distance + FOG_TOL with
FOG_TOL = 3               #   HDR (the shoulder is at most 1.33x the knee's distance
                          #   from white, at x = 0.8: the fog still blends to white)
OIT_LUM = 20.0            # oit: where the knee is brighter than this ...
OIT_RATIO = 0.5           # ... HDR keeps at least this of it
SATURATED = 250           # reports: a pixel is saturated with a channel this high

RTS = (0, 1)
SCENE_SHAPE = (720, 1280)

# The warm colours of the scene file: the prototype spot's 5600 K (the black
# body white-balanced at 6500 K, largest channel 1: LightWarmthRGB) and
# lighting_613's coloured key and rim; the peak scenes' bases.
WARM_5600 = (1.0, 0.910607, 0.785171)
KEY = (1.0, 0.55, 0.2)
RIM = (0.2, 0.8, 1.0)
RED = (1.0, 0.05, 0.0)
BLUE = (0.0, 0.05, 1.0)
GOLD = (0.95, 0.70, 0.25)        # l624_gold
ORANGE = (0.85, 0.45, 0.10)      # l624_orange (check_materials' TINT_BASE)

PRESETS = ('three_point', 'softbox', 'rembrandt', 'neon')
REC_REPS = ('surface_rt0', 'cartoon_rt0', 'sticks_rt0', 'spheres_rt0', 'tube_rt0',
            'surface_rt1')

PROOFS = ('sweep', 'recover', 'air_recover', 'hue', 'peak', 'glints')
GUARDS = ('shadows', 'display', 'unlit', 'below_knee', 'continuity', 'edges', 'fog',
          'export', 'oit')
REPORTS = ('haze683', 'aces')
# Subjects reported inside a guard check (never fail).
REPORT_SUBJECTS = (('display', 'display_knee_rt1'),)

# The proofs' subjects that must FAIL on the knee twins (the negative control)
# and on the round-0 renders of a build before #624.
NEGATIVE = {
    'sweep': ('sweep_rt0', 'sweep_e05', 'sweep_rt1'),
    'recover': ('rec_surface_rt0', 'rec_cartoon_rt0'),
    'air_recover': ('rec_air_rt0',),
    'hue': ('hue_rt0',),
    'peak': ('metallic_tint_rt0', 'metallic_tint_rt1', 'metallic_recover_rt0'),
    'glints': ('glass_recover_rt0', 'glass_growth_rt0'),
}

# Tags of lighting_624.json no check reads: for the eye (the contact sheet).
INFORMATIONAL = ('frosted_i3_rt0', 'frosted_i3_knee_rt0', 'jelly_i3_rt0',
                 'jelly_i3_knee_rt0')


def knee_twin(tag):
    """The knee twin's tag: `<base>_rt<n>` -> `<base>_knee_rt<n>`."""
    m = re.match(r'^(.*)_rt([01])$', tag)
    if not m or m.group(1).endswith('_knee'):
        raise Usage('no knee twin for %r' % (tag,))
    return '%s_knee_rt%s' % (m.group(1), m.group(2))


def is_knee(tag):
    return re.match(r'^.*_knee_rt[01]$', tag) is not None


# --- numpy helpers -------------------------------------------------------------------

def _np():
    import numpy
    return numpy


def _f(a):
    return _np().asarray(a)[..., :3].astype('float64')


def _pct(x):
    return '%.3f%%' % (100.0 * x)


def _same_size(check, subject, *images):
    shapes = {tuple(_np().asarray(i).shape[:2]) for i in images}
    if len(shapes) != 1:
        return Result(check, subject, False, 'image sizes differ: %s' % sorted(shapes))
    return None


def chroma(img):
    """Relative chroma (max - min) / max per pixel (0 on black)."""
    np = _np()
    c = _f(img)
    mx, mn = c.max(axis=-1), c.min(axis=-1)
    return np.where(mx > 0, (mx - mn) / np.where(mx > 0, mx, 1.0), 0.0)


def hue_deg(img):
    """HSV hue in degrees per pixel (0 where the pixel is grey)."""
    np = _np()
    c = _f(img)
    r, g, b = c[..., 0], c[..., 1], c[..., 2]
    mx, mn = c.max(axis=-1), c.min(axis=-1)
    d = np.where(mx - mn > 0, mx - mn, 1.0)
    hr = np.mod((g - b) / d, 6.0)
    hg = (b - r) / d + 2.0
    hb = (r - g) / d + 4.0
    h = np.where(mx == r, hr, np.where(mx == g, hg, hb)) * 60.0
    return np.where(mx - mn > 0, h, 0.0)


def hue_of(colour):
    return colorsys.rgb_to_hsv(*colour)[0] * 360.0


def chroma_of(colour):
    return (max(colour) - min(colour)) / max(colour) if max(colour) > 0 else 0.0


def hue_diff(a, b):
    """Circular |a - b| in degrees."""
    np = _np()
    return np.abs(np.mod(np.asarray(a) - np.asarray(b) + 180.0, 360.0) - 180.0)


def max_filter(values, r):
    """Square maximum filter of a 2-D array (padding 0)."""
    np = _np()
    v = np.asarray(values, dtype='float64')
    h, w = v.shape
    p = np.pad(v, r)
    out = np.zeros_like(v)
    for dy in range(-r, r + 1):
        for dx in range(-r, r + 1):
            out = np.maximum(out, p[r + dy:r + dy + h, r + dx:r + dx + w])
    return out


def background(*twins, margin=BG_MARGIN):
    return ~dilate(geometry(*twins), margin)


# --- the twin ------------------------------------------------------------------------

def _scalar_clean(m):
    np = _np()
    m = np.array(m, dtype='float64')
    return np.maximum(np.where(np.isfinite(m), m, 0.0), 0.0)


def _rgb_clean(rgb):
    """D10: a pixel with a non-finite channel is black; negatives are 0."""
    np = _np()
    c = np.array(rgb, dtype='float64')
    bad = ~np.isfinite(c).all(axis=-1)
    c = np.where(np.isfinite(c), c, 0.0)
    c[bad] = 0.0
    return np.maximum(c, 0.0)


def tone_scalar(m, knee=TONE_KNEE, white=TONE_WHITE):
    """T1: the identity to `knee`, the extended-Reinhard shoulder (C1 at the
    knee, 1 at `white`), 1 beyond."""
    np = _np()
    m = _scalar_clean(m)
    s = 1.0 - knee
    w = (white - knee) / s
    t = np.maximum(m - knee, 0.0) / s
    y = knee + s * t * (1.0 + t / (w * w)) / (1.0 + t)
    return np.where(m <= knee, m, np.where(m >= white, 1.0, y))


def tone_scalar_inverse(y, knee=TONE_KNEE, white=TONE_WHITE):
    """T1's inverse, rationalised: Tinv(1) = white."""
    np = _np()
    y = np.minimum(_scalar_clean(y), 1.0)
    s = 1.0 - knee
    w = (white - knee) / s
    u = np.clip((y - knee) / s, 0.0, 1.0)
    t = 2.0 * u / ((1.0 - u) + np.sqrt((1.0 - u) ** 2 + 4.0 * u / (w * w)))
    return np.where(y <= knee, y, np.where(y >= 1.0, white, knee + s * t))


def tone(rgb, exposure=1.0, knee=TONE_KNEE, white=TONE_WHITE):
    """T(exposure x rgb), hue-preserving on the largest channel (D2)."""
    np = _np()
    c = _rgb_clean(np.asarray(rgb, dtype='float64') * exposure)
    m = c.max(axis=-1, keepdims=True)
    y = tone_scalar(m, knee, white)
    return c * np.where(m > 0, y / np.where(m > 0, m, 1.0), 0.0)


def tone_inverse(rgb, knee=TONE_KNEE, white=TONE_WHITE):
    """T's inverse on display colour (each channel clipped to 0..1)."""
    np = _np()
    c = np.minimum(_rgb_clean(rgb), 1.0)
    m = c.max(axis=-1, keepdims=True)
    y = tone_scalar_inverse(m, knee, white)
    return c * np.where(m > 0, y / np.where(m > 0, m, 1.0), 0.0)


def soft_knee(rgb):
    """mat_soft_knee: per channel, Reinhard on the excess over 0.8."""
    np = _np()
    c = np.asarray(rgb, dtype='float64')
    over = np.maximum(c - SOFT_KNEE, 0.0)
    return np.minimum(c, SOFT_KNEE) + over / (1.0 + over) * (1.0 - SOFT_KNEE)


def quantise(rgb):
    """Display colour to 8-bit levels (int32)."""
    np = _np()
    return np.clip(np.floor(np.asarray(rgb, dtype='float64') * 255.0 + 0.5),
                   0, 255).astype('int32')


def glints_knee(s):
    np = _np()
    return 1.0 - np.exp(-2.0 * np.asarray(s, dtype='float64'))


def glints_hdr(s):
    return 2.0 * _np().asarray(s, dtype='float64')


def glass_cover_knee(body, hi, a):
    """mat_glass_cover: (straight rgb, cover)."""
    np = _np()
    hi = np.asarray(hi, dtype='float64')
    h = np.clip(hi.max(axis=-1, keepdims=True), 0.0, 1.0)
    cover = np.clip(a + (1.0 - a) * h, 0.0, 1.0)
    rgb = (soft_knee(body) * a + hi) / np.maximum(cover, 1e-4)
    return np.clip(rgb, 0.0, 1.0), cover


def glass_cover_hdr(body, hi, a, exposure=1.0):
    """D7's light_glass_cover: body and glints composed in scene units, one T."""
    np = _np()
    hi = np.asarray(hi, dtype='float64')
    h = tone_scalar(exposure * hi.max(axis=-1, keepdims=True))
    cover = np.clip(a + (1.0 - a) * h, 0.0, 1.0)
    s = (np.asarray(body, dtype='float64') * a + hi) / np.maximum(cover, 1e-4)
    return tone(s, exposure), cover


def air_knee(c, a):
    """post_air_finish before #624: c + max(knee(c + a) - knee(c), 0)."""
    np = _np()
    return c + np.maximum(soft_knee(c + a) - soft_knee(c), 0.0)


def air_hdr(c, a, exposure=1.0):
    """D8: T(Tinv(c) + e a)."""
    np = _np()
    return tone(tone_inverse(np.clip(c, 0.0, 1.0)) + np.maximum(a, 0.0) * exposure)


def warmth_rgb(kelvin):
    """LightWarmthRGB (LightShading.cpp) in python: Krystek's Planckian fit,
    white-balanced at 6500 K, largest channel 1 (the model's light colour;
    lighting_hdr_check.py pins it to lighting._light_warmth)."""
    def planck(t):
        t2 = t * t
        u = ((0.860117757 + 1.54118254e-4 * t + 1.28641212e-7 * t2) /
             (1.0 + 8.42420235e-4 * t + 7.08145163e-7 * t2))
        v = ((0.317398726 + 4.22806245e-5 * t + 4.20481691e-8 * t2) /
             (1.0 - 2.89741816e-5 * t + 1.61456053e-7 * t2))
        d = 2.0 * u - 8.0 * v + 4.0
        x, y = 3.0 * u / d, 2.0 * v / d
        X, Y, Z = x / y, 1.0, (1.0 - x - y) / y
        return (3.2404542 * X - 1.5371385 * Y - 0.4985314 * Z,
                -0.9692660 * X + 1.8760108 * Y + 0.0415560 * Z,
                0.0556434 * X - 0.2040259 * Y + 1.0572252 * Z)
    kelvin = min(max(float(kelvin), 1500.0), 15000.0)
    c = [max(a / b, 0.0) for a, b in zip(planck(kelvin), planck(6500.0))]
    top = max(c)
    return tuple(v / top for v in c)


# --- the checks: proofs ----------------------------------------------------------------

def _footprint(s0, s12):
    return geometry(s12) & ((luminance(s12) - luminance(s0)) >= SWEEP_FOOT)


def _spread(img, mask):
    np = _np()
    lum = luminance(img)[mask]
    p5, p95 = np.percentile(lum, [5, 95])
    return float(p95 - p5)


def check_sweep(s0, s06, s12, s20, s35, k12, k35, subject=''):
    """Steps, clipping, chroma and spread of the intensity sweep."""
    bad = _same_size('sweep', subject, s0, s06, s12, s20, s35, k12, k35)
    if bad:
        return bad
    np = _np()
    foot = _footprint(s0, s12)
    n = int(foot.sum())
    if n < SWEEP_MIN_SHARE * foot.size:
        return Result('sweep', subject, False, 'footprint %d px (< %s of the frame)' % (
            n, _pct(SWEEP_MIN_SHARE)))
    means = [float(luminance(i)[foot].mean()) for i in (s06, s12, s20, s35)]
    steps = [b - a for a, b in zip(means, means[1:])]
    clip = float((_f(s35)[foot].max(axis=-1) >= CLIP_LEVEL).mean())
    c12, c35 = float(chroma(s12)[foot].mean()), float(chroma(s35)[foot].mean())
    cr = c35 / c12 if c12 > 0 else 0.0
    sh = _spread(s35, foot) / max(_spread(s12, foot), 1e-9)
    sk = _spread(k35, foot) / max(_spread(k12, foot), 1e-9)
    ok = (min(steps) >= SWEEP_STEP and clip <= SWEEP_CLIP and cr >= SWEEP_CHROMA
          and sh >= sk * SWEEP_SPREAD - 1e-9)
    return Result('sweep', subject, ok,
                  'footprint %d px; means %s, steps %s (>= %d); clipped at 3.5 %s (<= %s); '
                  'chroma 3.5/1.2 %.3f/%.3f = %.2f (>= %.2f); spread ratio %.3f (knee %.3f, '
                  '>= x%.2f)' % (
                      n, '/'.join('%.1f' % m for m in means),
                      '/'.join('%+.1f' % s for s in steps), SWEEP_STEP, _pct(clip),
                      _pct(SWEEP_CLIP), c35, c12, cr, SWEEP_CHROMA, sh, sk, SWEEP_SPREAD))


def check_sweep_exposure(s0, s12, s20, e05, subject=''):
    """3.5 at exposure 0.5 is 1.75 in scene units: between 1.2 and 2.0."""
    bad = _same_size('sweep', subject, s0, s12, s20, e05)
    if bad:
        return bad
    foot = _footprint(s0, s12)
    if not foot.any():
        return Result('sweep', subject, False, 'no footprint')
    m12, m20, me = (float(luminance(i)[foot].mean()) for i in (s12, s20, e05))
    ok = me - m12 >= SWEEP_E05_MARGIN and m20 - me >= SWEEP_E05_MARGIN
    return Result('sweep', subject, ok,
                  'mean at 1.2 %.1f < 3.5 x e0.5 %.1f < 2.0 %.1f (margins %+.1f / %+.1f, '
                  '>= %.1f)' % (m12, me, m20, me - m12, m20 - me, SWEEP_E05_MARGIN))


def check_sweep_chroma(s0, s12, s35, subject=''):
    """The traced 3.5 keeps the light's chroma and clips no more."""
    bad = _same_size('sweep', subject, s0, s12, s35)
    if bad:
        return bad
    foot = _footprint(s0, s12)
    if not foot.any():
        return Result('sweep', subject, False, 'no footprint')
    c12, c35 = float(chroma(s12)[foot].mean()), float(chroma(s35)[foot].mean())
    cr = c35 / c12 if c12 > 0 else 0.0
    clip = float((_f(s35)[foot].max(axis=-1) >= CLIP_LEVEL).mean())
    ok = cr >= SWEEP_CHROMA and clip <= SWEEP_CLIP
    return Result('sweep', subject, ok,
                  'chroma 3.5/1.2 %.3f/%.3f = %.2f (>= %.2f); clipped %s (<= %s)' % (
                      c35, c12, cr, SWEEP_CHROMA, _pct(clip), _pct(SWEEP_CLIP)))


def _agreement(a, b, mask):
    np = _np()
    d = np.abs(_f(a) - _f(b)).max(axis=-1)[mask]
    if not d.size:
        return 0, 0.0, 0.0
    return int(d.max()), float(np.percentile(d, 99)), float(d.mean())


def check_recover(a, b, subject='', bright=True):
    """The pair holds the same light in scene units: it agrees on the geometry."""
    bad = _same_size('recover', subject, a, b)
    if bad:
        return bad
    geo = geometry(a, b)
    n = int(geo.sum())
    if n < REC_MIN_SHARE * geo.size:
        return Result('recover', subject, False, 'geometry %d px (< %s of the frame)' % (
            n, _pct(REC_MIN_SHARE)))
    top, p99, mean = _agreement(a, b, geo)
    share = float((_f(b).max(axis=-1)[geo] >= KNEE_LEVEL).mean())
    ok = top <= REC_MAX and p99 <= REC_P99 and mean <= REC_MEAN
    detail = 'max %d (<= %d), p99 %.1f (<= %d), mean %.2f (<= %.1f) on %d px' % (
        top, REC_MAX, p99, REC_P99, mean, REC_MEAN, n)
    if bright:
        ok = ok and share >= REC_BRIGHT
        detail += '; b at the shoulder on %s (>= %s)' % (_pct(share), _pct(REC_BRIGHT))
    return Result('recover', subject, ok, detail)


def check_air_recover(noair, a, b, subject=''):
    """The air pair: every lit pixel agrees, and the air is there."""
    bad = _same_size('air_recover', subject, noair, a, b)
    if bad:
        return bad
    lit = geometry(a, b)
    bg = background(noair)
    air = int((geometry(b) & bg).sum())
    top, p99, mean = _agreement(a, b, lit)
    btop, bp99, bmean = _agreement(a, b, lit & bg)
    ok = (air >= AIR_SHARE * lit.size and top <= REC_MAX and p99 <= REC_P99
          and mean <= REC_MEAN)
    return Result('air_recover', subject, ok,
                  'lit pixels: max %d (<= %d), p99 %.1f (<= %d), mean %.2f (<= %.1f); '
                  'background alone max %d, mean %.2f; air on %d background px (>= %s)' % (
                      top, REC_MAX, p99, REC_P99, mean, REC_MEAN, btop, bmean, air,
                      _pct(AIR_SHARE)))


def check_hue(x1, x25, subject=''):
    """Each light keeps its hue and chroma at 2.5x."""
    bad = _same_size('hue', subject, x1, x25)
    if bad:
        return bad
    np = _np()
    geo = geometry(x1, x25)
    c1, c25 = chroma(x1), chroma(x25)
    h1, h25 = hue_deg(x1), hue_deg(x25)
    sel = (geo & (c1 >= HUE_CHROMA_MIN) & (luminance(x1) >= HUE_LUM_MIN)
           & (_f(x1).max(axis=-1) >= HUE_LEVEL))
    ok, parts = True, []
    for name, colour in (('key', KEY), ('rim', RIM)):
        cls = sel & (hue_diff(h1, hue_of(colour)) <= HUE_CLASS_DEG)
        n = int(cls.sum())
        if n < HUE_SHARE * geo.size:
            ok = False
            parts.append('%s footprint %d px (< %s)' % (name, n, _pct(HUE_SHARE)))
            continue
        dh = float(hue_diff(h25, h1)[cls].mean())
        cr = float(c25[cls].mean() / max(c1[cls].mean(), 1e-9))
        ok = ok and dh <= HUE_DEG and cr >= HUE_CHROMA
        parts.append('%s (%d px): hue moves %.1f deg (<= %.0f), chroma x%.2f (>= %.2f)' % (
            name, n, dh, HUE_DEG, cr, HUE_CHROMA))
    return Result('hue', subject, ok, '; '.join(parts))


def _core_colour(img):
    np = _np()
    geo = geometry(img)
    if not geo.any():
        return None
    lum = luminance(img)
    cut = np.percentile(lum[geo], 100.0 * (1.0 - PEAK_TOP))
    core = geo & (lum >= cut)
    return _f(img)[core].mean(axis=0) / 255.0


def check_peak_tint(*images, subject='', base=GOLD):
    """The reflective highlight keeps the base's hue and chroma."""
    bad = _same_size('peak', subject, *images)
    if bad:
        return bad
    ok, parts = True, []
    hb, cb = hue_of(base), chroma_of(base)
    for i, img in enumerate(images):
        col = _core_colour(img)
        if col is None:
            return Result('peak', subject, False, 'image %d is black' % i)
        dh = float(hue_diff(hue_of(col), hb))
        cr = chroma_of(col) / cb
        ok = ok and dh <= PEAK_HUE and cr >= PEAK_CHROMA
        parts.append('core %s: hue %+.1f deg (<= %.0f), chroma x%.2f (>= %.2f)' % (
            '/'.join('%.2f' % v for v in col), dh, PEAK_HUE, cr, PEAK_CHROMA))
    return Result('peak', subject, ok, '; '.join(parts))


def check_peak_steps(i1, i2, i3, subject=''):
    """The highlight brightens from i1 to i2 and never dims to i3."""
    bad = _same_size('peak', subject, i1, i2, i3)
    if bad:
        return bad
    np = _np()
    geo = geometry(i1, i2, i3)
    if not geo.any():
        return Result('peak', subject, False, 'no geometry')
    p = [float(np.percentile(luminance(i)[geo], 99)) for i in (i1, i2, i3)]
    ok = p[1] - p[0] >= PEAK_STEP and p[2] >= p[1]
    return Result('peak', subject, ok, 'highlight p99 %.1f -> %.1f -> %.1f (i1 -> i2 >= +%d, '
                  'i3 >= i2)' % (p[0], p[1], p[2], PEAK_STEP))


def check_peak_recover(e067, i2, subject=''):
    """i3 at exposure 2/3 is i2 in scene units: no plateau on the highlight."""
    bad = _same_size('peak', subject, e067, i2)
    if bad:
        return bad
    np = _np()
    geo = geometry(e067, i2)
    if not geo.any():
        return Result('peak', subject, False, 'no geometry')
    lum = luminance(i2)
    hl = geo & (lum >= np.percentile(lum[geo], 100.0 * (1.0 - PEAK_HL_SHARE)))
    top, _p99, mean = _agreement(e067, i2, hl)
    return Result('peak', subject, top <= REC_MAX and mean <= REC_MEAN,
                  'highlight (%d px): max %d (<= %d), mean %.2f (<= %.1f)' % (
                      int(hl.sum()), top, REC_MAX, mean, REC_MEAN))


def _glint(h1, h0):
    np = _np()
    geo = geometry(h1, h0)
    d = (_f(h1) - _f(h0)).max(axis=-1)
    return d, geo


def check_glass_recover(e033, i1, subject=''):
    """Glass at i3 x exposure 1/3 is i1 in scene units (linear glints)."""
    r = check_recover(e033, i1, subject, bright=False)
    r.check = 'glints'
    return r


def check_glint_growth(i1h1, i1h0, i3h1, i3h0, subject=''):
    bad = _same_size('glints', subject, i1h1, i1h0, i3h1, i3h0)
    if bad:
        return bad
    np = _np()
    d1, g1 = _glint(i1h1, i1h0)
    d3, g3 = _glint(i3h1, i3h0)
    if not g1.any() or not g3.any():
        return Result('glints', subject, False, 'no geometry')
    p1, p3 = float(np.percentile(d1[g1], 99)), float(np.percentile(d3[g3], 99))
    return Result('glints', subject, p3 - p1 >= GLINT_GROW,
                  'glint p99 %.1f -> %.1f (grows >= %d)' % (p1, p3, GLINT_GROW))


def check_glint_rules(h1, h0, subject=''):
    """check_materials' glint rules (sparse, peaked, positive, white)."""
    r = cm.check_glints(h1, h0, subject)
    return Result('glints', subject, r.ok, r.detail)


def check_glint_clip(h1, h0, subject=''):
    bad = _same_size('glints', subject, h1, h0)
    if bad:
        return bad
    d, geo = _glint(h1, h0)
    glint = geo & (d >= cm.CHANGE)
    n = int(glint.sum())
    if not n:
        return Result('glints', subject, False, 'no glint pixel')
    clip = float((_f(h1).max(axis=-1)[glint] >= CLIP_LEVEL).mean())
    return Result('glints', subject, clip <= GLINT_CLIP,
                  '%d glint px, clipped %s (<= %s)' % (n, _pct(clip), _pct(GLINT_CLIP)))


def check_glass_body(h1, h0, subject=''):
    bad = _same_size('glints', subject, h1, h0)
    if bad:
        return bad
    d, geo = _glint(h1, h0)
    lit = geo & (luminance(h0) >= BODY_LUM) & (d >= cm.CHANGE)
    n = int(lit.sum())
    if not n:
        return Result('glints', subject, False, 'no glint on the lit body')
    clip = float((_f(h1).max(axis=-1)[lit] >= CLIP_LEVEL).mean())
    gain = float((luminance(h1) - luminance(h0))[lit].mean())
    return Result('glints', subject, clip <= GLINT_CLIP and gain > 0,
                  'glint on the lit body %d px: clipped %s (<= %s), adds %.1f levels (> 0)'
                  % (n, _pct(clip), _pct(GLINT_CLIP), gain))


# --- the checks: guards -----------------------------------------------------------------

def _led(img, geo):
    c = _f(img)
    red = geo & ((c[..., 0] - c[..., 2]) >= SHADOW_HUE_MIN)
    blue = geo & ((c[..., 2] - c[..., 0]) >= SHADOW_HUE_MIN)
    return red, blue


def check_shadows(knee, hdr, subject=''):
    """Each light's shadow keeps the other light's hue; chroma reported."""
    bad = _same_size('shadows', subject, knee, hdr)
    if bad:
        return bad
    geo = geometry(knee, hdr)
    n = int(geo.sum())
    if not n:
        return Result('shadows', subject, False, 'no geometry')
    rh, bh = _led(hdr, geo)
    rk, bk = _led(knee, geo)
    sr, sb = rh.sum() / float(n), bh.sum() / float(n)
    ch = chroma(hdr)
    ck = chroma(knee)

    def lobe(mh, mk):
        a = float(ch[mh].mean()) if mh.any() else 0.0
        b = float(ck[mk].mean()) if mk.any() else 0.0
        return a, b
    (rch, rck), (bch, bck) = lobe(rh, rk), lobe(bh, bk)
    ok = sr >= SHADOW_COLOURED_MIN and sb >= SHADOW_COLOURED_MIN
    return Result('shadows', subject, ok,
                  'red-led %s, blue-led %s of the geometry (each >= %s); chroma red %.2f '
                  '(knee %.2f), blue %.2f (knee %.2f) (reported)' % (
                      _pct(sr), _pct(sb), _pct(SHADOW_COLOURED_MIN), rch, rck, bch, bck))


def check_display(e06, e1, nocartoon, subject=''):
    """Exposure moves only the lit cartoon."""
    bad = _same_size('display', subject, e06, e1, nocartoon)
    if bad:
        return bad
    np = _np()
    cartoon = np.abs(_f(e1) - _f(nocartoon)).max(axis=-1) > 0
    foot = dilate(cartoon, DISPLAY_DILATE)
    outside = ~foot
    d = np.abs(_f(e06) - _f(e1)).max(axis=-1)
    top = int(d[outside].max()) if outside.any() else 0
    inside = int((d[foot] > 0).sum())
    ok = cartoon.any() and outside.any() and top == 0 and inside > 0
    return Result('display', subject, ok,
                  'outside the cartoon (%d px) max |e0.6 - e1| %d (== 0); %d px move inside '
                  '(> 0)' % (int(outside.sum()), top, inside))


def check_unlit(knee, hdr, subject=''):
    """Overlay colours and the background are untouched by HDR."""
    bad = _same_size('unlit', subject, knee, hdr)
    if bad:
        return bad
    np = _np()
    k, h = _f(knee), _f(hdr)
    ok, parts = True, []
    for name, colour in sorted(UNLIT_COLOURS.items()):
        m = (k == np.array(colour, dtype='float64')).all(axis=-1)
        n = int(m.sum())
        kept = int((h[m] == np.array(colour, dtype='float64')).all(axis=-1).sum())
        good = n >= UNLIT_SHARE * m.size and kept == n
        ok = ok and good
        parts.append('%s %d/%d' % (name, kept, n))
    bg = (k == 0).all(axis=-1)
    bgk = int(((h[bg] == 0).all(axis=-1)).sum())
    ok = ok and bgk == int(bg.sum())
    return Result('unlit', subject, ok,
                  'kept/exact: %s (each >= %s of the frame); background %d/%d' % (
                      ', '.join(parts), _pct(UNLIT_SHARE), bgk, int(bg.sum())))


def check_below_knee(knee, hdr, subject=''):
    """Under both knees HDR is the knee exactly."""
    bad = _same_size('below_knee', subject, knee, hdr)
    if bad:
        return bad
    np = _np()
    geo = geometry(knee)
    n = int(geo.sum())
    if not n:
        return Result('below_knee', subject, False, 'no geometry')
    low = geo & (_f(knee).max(axis=-1) <= BELOW_LEVEL)
    share = low.sum() / float(n)
    top = int(np.abs(_f(knee) - _f(hdr)).max(axis=-1)[low].max()) if low.any() else 0
    return Result('below_knee', subject, share >= BELOW_SHARE and top == 0,
                  'pixels at or under %d: %s of the geometry (>= %s), max |hdr - knee| %d '
                  '(== 0)' % (BELOW_LEVEL, _pct(share), _pct(BELOW_SHARE), top))


def check_continuity(knee, hdr, subject=''):
    """A preset changes little where it is dim."""
    bad = _same_size('continuity', subject, knee, hdr)
    if bad:
        return bad
    np = _np()
    geo = geometry(knee, hdr)
    km = _f(knee).max(axis=-1)
    low = geo & (km < CONT_LEVEL)
    hi = geo & ~low
    d = np.abs(_f(knee) - _f(hdr)).max(axis=-1)
    top = int(d[low].max()) if low.any() else 0
    elsewhere = float((luminance(hdr) - luminance(knee))[hi].mean()) if hi.any() else 0.0
    return Result('continuity', subject, low.any() and top <= CONT_TOL,
                  'under %.0f (%d px): max |d| %d (<= %d); elsewhere (%d px) mean %+.1f '
                  'levels (reported)' % (CONT_LEVEL, int(low.sum()), top, CONT_TOL,
                                         int(hi.sum()), elsewhere))


def _edge_counts(img, rim, inner):
    np = _np()
    lum = luminance(img)
    li = np.where(inner, lum, 0.0)
    m3 = max_filter(li, 1)
    partial = rim & (m3 > 0) & (lum >= EDGE_LO * m3) & (lum <= EDGE_HI * m3)
    over = rim & (m3 > 0) & (lum > m3 + EDGE_OVER)
    return int(partial.sum()), int(over.sum())


def check_edges(knee, hdr, subject=''):
    """The silhouettes anti-alias as the knee's do: no fringe."""
    bad = _same_size('edges', subject, knee, hdr)
    if bad:
        return bad
    geo = geometry(knee)
    rim = geo & dilate(~geo, 1)                  # touches the background: partly covered
    inner = geo & ~rim & dilate(rim, EDGE_BAND)  # the fully covered pixels just inside
    nb = int(rim.sum())
    pk, ok_ = _edge_counts(knee, rim, inner)
    ph, oh = _edge_counts(hdr, rim, inner)
    ratio = ph / float(pk) if pk else 0.0
    ok = (pk > 0 and abs(ratio - 1.0) <= EDGE_COUNT_TOL
          and oh <= ok_ * (1.0 + EDGE_COUNT_TOL) + EDGE_SLACK * nb)
    return Result('edges', subject, ok,
                  'silhouette %d px: partial %d (knee %d, ratio %.3f within %.2f); fringe %d '
                  '(knee %d, <= x%.2f + %d)' % (nb, ph, pk, ratio, EDGE_COUNT_TOL, oh, ok_,
                                                1.0 + EDGE_COUNT_TOL, int(EDGE_SLACK * nb)))


def check_fog(knee, hdr, subject=''):
    """The fog's background and near-background pixels stay."""
    bad = _same_size('fog', subject, knee, hdr)
    if bad:
        return bad
    np = _np()
    k, h = _f(knee), _f(hdr)
    bg = (k >= 255).all(axis=-1)
    nbg = int(bg.sum())
    bg_ok = int((h[bg] >= 255).all(axis=-1).sum())
    near = ~bg & (np.abs(k - 255.0).max(axis=-1) <= FOG_NEAR)
    nn = int(near.sum())
    dk = np.abs(k[near] - 255.0).max(axis=-1)
    dh = np.abs(h[near] - 255.0).max(axis=-1)
    near_ok = int((dh <= FOG_RATIO * dk + FOG_TOL).sum())
    ok = nbg > 0 and bg_ok == nbg and nn > 0 and near_ok == nn
    return Result('fog', subject, ok,
                  'background %d/%d exact; near-background (knee within %d, > 0) %d/%d within '
                  '%.1fx + %d' % (bg_ok, nbg, FOG_NEAR, near_ok, nn, FOG_RATIO, FOG_TOL))


def load_rgba(path):
    """RGBA as an int32 array (H, W, 4)."""
    from PIL import Image
    np = _np()
    with Image.open(path) as image:
        return np.asarray(image.convert('RGBA'), dtype=np.int32)


def check_export(knee, hdr, subject=''):
    """The exported alpha is the knee's (images RGBA)."""
    bad = _same_size('export', subject, knee, hdr)
    if bad:
        return bad
    np = _np()
    ka, ha = np.asarray(knee)[..., 3], np.asarray(hdr)[..., 3]
    d = int(np.abs(ka - ha).max())
    clear = int((ka < 255).sum())
    return Result('export', subject, d == 0 and clear > 0,
                  'max |alpha - knee alpha| %d (== 0); %d px under 255 (> 0: a transparent '
                  'background)' % (d, clear))


def check_oit(knee, hdr, subject=''):
    """Transparency keeps its light: no hole where the knee is lit."""
    bad = _same_size('oit', subject, knee, hdr)
    if bad:
        return bad
    lk, lh = luminance(knee), luminance(hdr)
    m = lk > OIT_LUM
    n = int(m.sum())
    if not n:
        return Result('oit', subject, False, 'nothing lit in the knee render')
    low = int((lh[m] < OIT_RATIO * lk[m]).sum())
    return Result('oit', subject, low == 0,
                  '%d px over %.0f in the knee; %d keep less than %.0f%% (== 0)' % (
                      n, OIT_LUM, low, 100 * OIT_RATIO))


# --- reports -----------------------------------------------------------------------------

def _stats(img, mask):
    np = _np()
    lum = luminance(img)[mask]
    if not lum.size:
        return 'empty'
    sat = float((_f(img).max(axis=-1)[mask] >= SATURATED).mean())
    return 'mean %.1f std %.1f saturated %s' % (float(lum.mean()), float(lum.std()), _pct(sat))


def report_haze(noair, e1, e05, k1, k05, subject=''):
    bad = _same_size('haze683', subject, noair, e1, e05, k1, k05)
    if bad:
        return bad
    mol = geometry(noair)
    bg = background(noair)
    parts = []
    for name, img in (('hdr e1', e1), ('hdr e0.5', e05), ('knee e1', k1), ('knee e0.5', k05)):
        bgm = float(luminance(img)[bg].mean()) if bg.any() else 0.0
        parts.append('%s: molecule %s, background mean %.1f' % (name, _stats(img, mol), bgm))
    return Result('haze683', subject, True, '; '.join(parts))


def report_aces(knee, hdr, subject=''):
    bad = _same_size('aces', subject, knee, hdr)
    if bad:
        return bad
    geo = geometry(knee, hdr)
    return Result('aces', subject, True, 'hdr %s; knee %s' % (_stats(hdr, geo),
                                                             _stats(knee, geo)))


# --- what each check reads -----------------------------------------------------------------

def _s(i):
    return 'sweep_%s_rt0' % i


def l2_plan():
    """[(check, subject, func, tags, kwargs)] for every check of lighting_624.json."""
    k = knee_twin
    plan = [
        ('sweep', 'sweep_rt0', check_sweep,
         [_s('0'), _s('0p6'), _s('1p2'), _s('2p0'), _s('3p5'), k(_s('1p2')), k(_s('3p5'))], {}),
        ('sweep', 'sweep_e05', check_sweep_exposure,
         [_s('0'), _s('1p2'), _s('2p0'), 'sweep_3p5_e05_rt0'], {}),
        ('sweep', 'sweep_rt1', check_sweep_chroma, [_s('0'), _s('1p2'), 'sweep_3p5_rt1'], {}),
    ]
    for rep in REC_REPS:
        base, rt = rep.rsplit('_rt', 1)
        plan.append(('recover', 'rec_%s' % rep, check_recover,
                     ['rec_%s_a_rt%s' % (base, rt), 'rec_%s_b_rt%s' % (base, rt)], {}))
    plan.append(('air_recover', 'rec_air_rt0', check_air_recover,
                 ['rec_surface_b_rt0', 'rec_air_a_rt0', 'rec_air_b_rt0'], {}))
    plan.append(('hue', 'hue_rt0', check_hue, ['hue_x1_rt0', 'hue_x2p5_rt0'], {}))
    plan += [
        ('peak', 'metallic_tint_rt0', check_peak_tint,
         ['peak_metallic_i2_rt0', 'peak_metallic_i3_rt0'], {'base': GOLD}),
        ('peak', 'metallic_tint_rt1', check_peak_tint, ['peak_metallic_i3_rt1'],
         {'base': GOLD}),
        ('peak', 'metallic_recover_rt0', check_peak_recover,
         ['peak_metallic_i3_e067_rt0', 'peak_metallic_i2_rt0'], {}),
        ('peak', 'metallic_steps_rt0', check_peak_steps,
         ['peak_metallic_i%d_rt0' % i for i in (1, 2, 3)], {}),
        ('peak', 'plastic_steps_rt0', check_peak_steps,
         ['peak_plastic_i%d_rt0' % i for i in (1, 2, 3)], {}),
        ('glints', 'glass_recover_rt0', check_glass_recover,
         ['glass_i3_e033_hl1_rt0', 'glass_i1_hl1_rt0'], {}),
        ('glints', 'glass_growth_rt0', check_glint_growth,
         ['glass_i1_hl1_rt0', 'glass_i1_hl0_rt0', 'glass_i3_hl1_rt0', 'glass_i3_hl0_rt0'], {}),
        ('glints', 'glass_rules_i1_rt0', check_glint_rules,
         ['glass_i1_hl1_rt0', 'glass_i1_hl0_rt0'], {}),
        ('glints', 'glass_rules_i3_rt0', check_glint_rules,
         ['glass_i3_hl1_rt0', 'glass_i3_hl0_rt0'], {}),
        ('glints', 'glass_clip_rt0', check_glint_clip,
         ['glass_i3_hl1_rt0', 'glass_i3_hl0_rt0'], {}),
        ('glints', 'glass_body_rt0', check_glass_body,
         ['glass_body_i3_hl1_rt0', 'glass_body_i3_hl0_rt0'], {}),
    ]
    for rt in RTS:
        t = 'shadow_cross_rt%d' % rt
        plan.append(('shadows', t, check_shadows, [k(t), t], {}))
    plan += [
        ('display', 'display_rt1', check_display,
         ['display_e06_rt1', 'display_e1_rt1', 'display_nocartoon_rt1'], {}),
        ('display', 'display_knee_rt1', check_display,
         ['display_e06_knee_rt1', 'display_e1_knee_rt1', 'display_nocartoon_rt1'], {}),
        ('unlit', 'unlit_rt1', check_unlit, ['unlit_knee_rt1', 'unlit_rt1'], {}),
        ('below_knee', 'below_i04_rt0', check_below_knee,
         ['below_i04_knee_rt0', 'below_i04_rt0'], {}),
    ]
    for p in PRESETS:
        t = 'cont_%s_rt0' % p
        plan.append(('continuity', t, check_continuity, [k(t), t], {}))
    plan += [
        ('edges', 'edges_rt0', check_edges, ['edges_knee_rt0', 'edges_rt0'], {}),
        ('fog', 'fog_rt1', check_fog, ['fog_knee_rt1', 'fog_rt1'], {}),
    ]
    for rt in RTS:
        t = 'export_rt%d' % rt
        plan.append(('export', t, check_export, [k(t), t], {}))
    for rt in RTS:
        t = 'oit_rt%d' % rt
        plan.append(('oit', t, check_oit, [k(t), t], {}))
    plan += [
        ('haze683', 'haze683_rt0', report_haze,
         ['haze683_noair_rt0', 'haze683_e1_rt0', 'haze683_e05_rt0', 'haze683_e1_knee_rt0',
          'haze683_e05_knee_rt0'], {}),
        ('aces', 'aces_rt0', report_aces, ['aces_knee_rt0', 'aces_rt0'], {}),
    ]
    return plan


RGBA_CHECKS = ('export',)


def kind(check, subject=''):
    if check in REPORTS or (check, subject) in REPORT_SUBJECTS:
        return 'report'
    if check in PROOFS:
        return 'proof' if subject in NEGATIVE.get(check, ()) else 'guard'
    return 'guard'


def plan_tags(plan=None):
    """Every tag a plan reads."""
    return sorted({t for p in (plan or l2_plan()) for t in p[3]})


def negative_plan():
    """The l2 plan's NEGATIVE entries with every tag swapped for its knee twin
    (where the scene file has one; intensity 0 and the masks have none)."""
    plan = []
    twins = set(TWINNED)
    for check, subject, func, tags, kwargs in l2_plan():
        if subject in NEGATIVE.get(check, ()):
            plan.append((check, subject, func,
                         [knee_twin(t) if t in twins else t for t in tags], kwargs))
    return plan


# Tags lighting_624.json renders a knee twin of (the twin is the same scene
# plus _l624_opt('metal_light_hdr', 2)).
TWINNED = (
    'sweep_0p6_rt0', 'sweep_1p2_rt0', 'sweep_2p0_rt0', 'sweep_3p5_rt0', 'sweep_3p5_e05_rt0',
    'sweep_3p5_rt1', 'rec_surface_a_rt0', 'rec_surface_b_rt0', 'rec_cartoon_a_rt0',
    'rec_cartoon_b_rt0', 'rec_air_a_rt0', 'rec_air_b_rt0', 'hue_x1_rt0', 'hue_x2p5_rt0',
    'peak_metallic_i1_rt0', 'peak_metallic_i2_rt0', 'peak_metallic_i3_rt0',
    'peak_metallic_i3_e067_rt0', 'peak_metallic_i3_rt1', 'peak_plastic_i1_rt0',
    'peak_plastic_i2_rt0', 'peak_plastic_i3_rt0', 'glass_i1_hl0_rt0', 'glass_i1_hl1_rt0',
    'glass_i3_hl0_rt0', 'glass_i3_hl1_rt0', 'glass_i3_e033_hl1_rt0', 'glass_body_i3_hl0_rt0',
    'glass_body_i3_hl1_rt0', 'frosted_i3_rt0', 'jelly_i3_rt0', 'shadow_cross_rt0',
    'shadow_cross_rt1', 'display_e06_rt1', 'display_e1_rt1', 'unlit_rt1', 'below_i04_rt0',
    'cont_three_point_rt0', 'cont_softbox_rt0', 'cont_rembrandt_rt0', 'cont_neon_rt0',
    'edges_rt0', 'fog_rt1', 'export_rt0', 'export_rt1', 'oit_rt0', 'oit_rt1',
    'haze683_e1_rt0', 'haze683_e05_rt0', 'aces_rt0',
)


def scene_tags():
    """Every tag lighting_624.json must render: what the plans read plus the
    informational ones."""
    return sorted(set(plan_tags()) | set(plan_tags(negative_plan())) |
                  {knee_twin(t) for t in TWINNED} | set(INFORMATIONAL))


# --- running -----------------------------------------------------------------------------

def _image(source, tag, rgba):
    """(image or None) from a directory or a {tag: array} dict."""
    if isinstance(source, dict):
        img = source.get(tag)
        if img is None:
            return None
        np = _np()
        img = np.asarray(img)
        if rgba and img.shape[-1] == 3:
            img = np.concatenate([img, np.full(img.shape[:2] + (1,), 255, dtype=img.dtype)],
                                 axis=-1)
        return img if rgba else img[..., :3]
    path = os.path.join(source, tag + '.png')
    if not os.path.isfile(path):
        return None
    return load_rgba(path) if rgba else load(path)


def run_plan(source, plan, checks=None):
    """Run every planned check (whose name is in `checks`, all when None) on a
    render directory or a {tag: image} dict. Reports never fail the run."""
    if not isinstance(source, dict) and not os.path.isdir(source):
        raise Usage('%s is not a directory' % source)
    results = []
    for check, subject, func, tags, kwargs in plan:
        if checks is not None and check not in checks:
            continue
        rgba = check in RGBA_CHECKS
        images = [_image(source, t, rgba) for t in tags]
        missing = [t for t, i in zip(tags, images) if i is None]
        if missing:
            r = Result(check, subject, False, 'missing %s' % ', '.join(t + '.png' for t in missing))
        else:
            r = func(*images, subject=subject, **kwargs)
            r.check = check
            r.subject = subject
        if kind(check, subject) == 'report' and not missing:
            r.detail = '(report) %s' % r.detail
            r.ok = True
        results.append(r)
    if not results:
        raise Usage('no check selected')
    return results


def run_negative(source):
    """Every proof subject on the knee twins: `ok` means 'failed as it must'."""
    results = run_plan(source, negative_plan())
    for r in results:
        failed = not r.ok and not r.detail.startswith('missing')
        r.detail = '(%s on the knee) %s' % ('fails' if not r.ok else 'PASSES', r.detail)
        r.ok = failed
    return results


def report(results, out=None, kinds=False):
    """The markdown table; returns 1 when a row failed."""
    out = out or sys.stdout
    if kinds:
        print('| Check | Kind | Subject | Result | Measured |', file=out)
        print('| --- | --- | --- | --- | --- |', file=out)
        for r in results:
            cells = (r.check, kind(r.check, r.subject), r.subject, 'PASS' if r.ok else 'FAIL',
                     r.detail)
            print('| %s |' % ' | '.join(str(c).replace('|', '\\|') for c in cells), file=out)
        failed = [r for r in results if not r.ok]
        print('check_hdr: %d checks, %d failed' % (len(results), len(failed)), file=out)
        return 1 if failed else 0
    buf = io.StringIO()
    rc = cs.report(results, buf)
    out.write(buf.getvalue().replace('check_shadows:', 'check_hdr:'))
    return rc


def _json_rows(results):
    return [{'check': r.check, 'kind': kind(r.check, r.subject), 'subject': r.subject,
             'ok': r.ok, 'detail': r.detail} for r in results]


def _write_json(path, payload):
    if path:
        with open(path, 'w') as fh:
            json.dump(payload, fh, indent=2)


def _checks(text, plan):
    if not text:
        return None
    names = [c for c in text.split(',') if c]
    known = sorted({p[0] for p in plan})
    unknown = [c for c in names if c not in known]
    if unknown:
        raise Usage('unknown checks %s (known: %s)' % (', '.join(unknown), ', '.join(known)))
    return set(names)


# --- the model -------------------------------------------------------------------------------
# Synthetic renders of every tag the plans read, small (MODEL_SHAPE), made with
# the twin ('hdr': an HDR build; knee twins always take the knee) or the knee
# ('knee': a build before #624, as round 0). Light is modelled in scene units
# (base x (ambient + intensity x footprint x colour) plus a highlight), stored
# through the build's curve at 8 bits, and composited in display space (the
# MSAA resolve, the air, OIT, #13's exposure pass) as the renderer does.

MODEL_SHAPE = (180, 320)
GLASS_KNOB = 1.6
GLASS_OIT = 0.58


class _Grid(object):
    def __init__(self, shape=MODEL_SHAPE):
        np = _np()
        self.h, self.w = shape
        v, u = np.mgrid[0:self.h, 0:self.w].astype('float64')
        self.u = (u + 0.5) / self.w
        self.v = (v + 0.5) / self.h

    def ellipse(self, cx, cy, rx, ry):
        """(coverage with a one-pixel anti-aliased edge, normalised radius)."""
        np = _np()
        d = np.sqrt(((self.u - cx) / rx) ** 2 + ((self.v - cy) / ry) ** 2)
        px = 1.0 / (min(rx * self.w, ry * self.h))
        return np.clip((1.0 - d) / px + 0.5, 0.0, 1.0), d

    def spot(self, cx, cy, r, power=1.0):
        np = _np()
        d = np.sqrt(((self.u - cx) * self.w / self.h) ** 2 + (self.v - cy) ** 2)
        return np.clip(1.0 - d / r, 0.0, 1.0) ** power

    def rect(self, x0, y0, x1, y1):
        return (self.u >= x0) & (self.u < x1) & (self.v >= y0) & (self.v < y1)


def _col(c):
    return _np().asarray(c, dtype='float64').reshape((1, 1, 3))


def _store(x, curve, exposure=1.0):
    """The lit colour in display units as the build stores it (0..1, float)."""
    if curve == 'hdr':
        return tone(x, exposure)
    return soft_knee(x)                        # #13's exposure comes later


def _post(d, curve, exposure=1.0):
    """#13's exposure pass (the knee build only; HDR exposes in scene units)."""
    np = _np()
    if curve == 'hdr' or exposure == 1.0:
        return d
    return np.clip(quantise(d) / 255.0 * exposure, 0.0, 1.0)


def _over(fg, cov, bg):
    return fg * cov[..., None] + bg * (1.0 - cov[..., None])


def _m_sweep(g, curve, intensity, exposure=1.0):
    np = _np()
    cov, _ = g.ellipse(0.5, 0.5, 0.42, 0.40)
    f = g.spot(0.45, 0.45, 0.42, 0.8)
    f = np.where((np.abs(g.v - 0.72) < 0.04) & (g.u > 0.5), 0.1 * f, f)   # a shadow
    w = _col(WARM_5600)
    x = 0.8 * (0.06 + intensity * f[..., None] * w) + intensity * 0.25 * (f ** 30)[..., None] * w
    d = _store(x, curve, exposure)
    return quantise(_post(_over(d, cov, 0.0), curve, exposure))


def _m_lit(g, curve, intensity, exposure=1.0, centre=(0.5, 0.5), radii=(0.4, 0.38),
           colour=WARM_5600, ambient=0.0, base=0.8):
    np = _np()
    cov, _ = g.ellipse(centre[0], centre[1], radii[0], radii[1])
    f = g.spot(centre[0] - 0.05, centre[1] - 0.05, 0.45, 0.7)
    c = _col(colour)
    x = base * (ambient + intensity * f[..., None] * c) + intensity * 0.3 * (f ** 25)[..., None] * c
    return _store(x, curve, exposure), cov


def _m_rec(g, curve, rep, which, air=False):
    np = _np()
    intensity, exposure = (3.5, 4.0 / 7.0) if which == 'a' else (2.0, 1.0)
    shapes = {'surface': ((0.5, 0.5), (0.40, 0.38)), 'cartoon': ((0.48, 0.52), (0.36, 0.34)),
              'sticks': ((0.52, 0.48), (0.30, 0.36)), 'spheres': ((0.5, 0.5), (0.34, 0.40)),
              'tube': ((0.46, 0.5), (0.42, 0.25))}
    centre, radii = shapes[rep]
    d, cov = _m_lit(g, curve, intensity, exposure, centre, radii)
    disp = _over(d, cov, 0.0)
    if air:
        beam = g.spot(0.42, 0.35, 0.65, 1.0)
        a = intensity * 0.12 * (beam * (1.0 - 0.7 * cov))[..., None] * _col(WARM_5600)
        c8 = quantise(disp) / 255.0
        if curve == 'hdr':
            disp = air_hdr(c8, a, exposure)
        else:
            disp = air_knee(c8, a)
    return quantise(_post(disp, curve, exposure))


def _m_hue(g, curve, scale):
    cov, _ = g.ellipse(0.5, 0.5, 0.42, 0.40)
    fk = g.spot(0.36, 0.5, 0.32, 0.8)[..., None]
    fr = g.spot(0.66, 0.45, 0.26, 0.8)[..., None]
    x = 0.8 * (0.06 + scale * (1.6 * fk * _col(KEY) + 1.6 * fr * _col(RIM)))
    return quantise(_over(_store(x, curve), cov, 0.0))


def _m_peak(g, curve, material, intensity, exposure=1.0):
    np = _np()
    base = GOLD if material == 'metallic' else ORANGE
    tint = (0.15 * _col((1, 1, 1)) + 0.85 * _col(base)) if material == 'metallic' else _col(
        (1, 1, 1))
    strength = 0.7 * (3.1 if material == 'metallic' else 3.5) * 0.35
    diffuse = 0.79 if material == 'metallic' else 1.0
    out_x = np.zeros((g.h, g.w, 3))
    covs = np.zeros((g.h, g.w))
    for cx, cy in ((0.3, 0.35), (0.62, 0.32), (0.42, 0.7), (0.74, 0.68)):
        cov, d = g.ellipse(cx, cy, 0.13, 0.22)
        nl = np.sqrt(np.clip(1.0 - d * d, 0.0, 1.0))
        hl = np.exp(-(((g.u - cx + 0.04) / 0.035) ** 2 + ((g.v - cy + 0.07) / 0.06) ** 2))
        x = (_col(base) * (0.06 + intensity * diffuse * nl[..., None])
             + intensity * strength * hl[..., None] * tint)
        out_x = np.where(cov[..., None] > covs[..., None], x, out_x)
        covs = np.maximum(covs, cov)
    d = _store(out_x, curve, exposure)
    return quantise(_post(_over(d, covs, 0.0), curve, exposure))


def _m_glass(g, curve, intensity, hl, exposure=1.0, body=False):
    np = _np()
    cov, dd = g.ellipse(0.5, 0.5, 0.40, 0.38)
    f = g.spot(0.45, 0.45, 0.45, 0.7)[..., None]
    base = _col(ORANGE if body else (0.8, 0.8, 0.8))
    lit = intensity * f * base * (0.9 if body else 0.25)
    peaks = np.zeros((g.h, g.w))
    for cx, cy in ((0.42, 0.40), (0.58, 0.55), (0.36, 0.62), (0.62, 0.34)):
        peaks += np.exp(-(((g.u - cx) / 0.02) ** 2 + ((g.v - cy) / 0.035) ** 2))
    if body:
        peaks = np.exp(-(((g.u - 0.45) / 0.05) ** 2 + ((g.v - 0.45) / 0.08) ** 2))
    s = hl * intensity * 0.8 * peaks[..., None] * _col((1, 1, 1))
    a = 0.35
    # The Reflection knob scales the glints (GLASS_KNOB) before the cover, so
    # the knee's cover saturates at i1 already; the weighted OIT over black
    # shows the straight colour at about GLASS_OIT of its value (round 0: the
    # knee's glint cores sit at 147 at i1 and i3).
    if curve == 'hdr':
        rgb, cover = glass_cover_hdr(lit, GLASS_KNOB * glints_hdr(s), a, exposure)
    else:
        rgb, cover = glass_cover_knee(lit, GLASS_KNOB * glints_knee(s), a)
    disp = rgb * cover * GLASS_OIT
    return quantise(_post(_over(disp, cov, 0.0), curve, exposure))


def _m_shadow(g, curve):
    np = _np()
    cov, _ = g.ellipse(0.5, 0.5, 0.42, 0.40)
    fr = np.where(g.u < 0.62, 1.0, 0.0)[..., None] * g.spot(0.4, 0.5, 0.5, 0.6)[..., None]
    fb = np.where(g.u > 0.38, 1.0, 0.0)[..., None] * g.spot(0.6, 0.5, 0.5, 0.6)[..., None]
    x = 0.8 * (0.05 + 3.0 * (fr * _col(RED) + fb * _col(BLUE)))
    return quantise(_over(_store(x, curve), cov, 0.0))


def _m_display(g, curve, exposure, cartoon=True):
    np = _np()
    bg = np.ones((g.h, g.w, 3))
    if cartoon:
        d, cov = _m_lit(g, curve, 3.0, exposure, (0.55, 0.55), (0.3, 0.3),
                        colour=(1, 1, 1), ambient=0.06)
        bg = _over(d, cov, bg)
    disp = bg
    lines = g.rect(0.05, 0.2, 0.25, 0.23) | g.rect(0.1, 0.3, 0.13, 0.8)
    disp = np.where(lines[..., None], _col((1.0, 1.0, 0.0)), disp)
    labels = g.rect(0.3, 0.05, 0.5, 0.12) | g.rect(0.7, 0.85, 0.9, 0.93)
    disp = np.where(labels[..., None], _col((0.1, 0.1, 0.1)), disp)
    if curve == 'knee':
        disp = _post(disp, curve, exposure)
    return quantise(disp)


def _m_unlit(g, curve):
    np = _np()
    d, cov = _m_lit(g, curve, 3.0, 1.0, colour=(1, 1, 1), ambient=0.06)
    disp = _over(d, cov, 0.0)
    for (r, colour) in ((g.rect(0.3, 0.3, 0.45, 0.36), (1.0, 1.0, 1.0)),
                        (g.rect(0.55, 0.6, 0.7, 0.66), (0.0, 0.0, 89.0 / 255.0)),
                        (g.rect(0.2, 0.5, 0.8, 0.52), (1.0, 0.0, 1.0))):
        disp = np.where(r[..., None], _col(colour), disp)
    return quantise(disp)


def _m_below(g, curve):
    cov, _ = g.ellipse(0.5, 0.5, 0.42, 0.40)
    fk = g.spot(0.36, 0.5, 0.45, 0.8)[..., None]
    fr = g.spot(0.66, 0.45, 0.35, 0.8)[..., None]
    x = 0.8 * (0.06 + 0.4 * (fk * _col(KEY) + fr * _col(RIM)))
    return quantise(_over(_store(x, curve), cov, 0.0))


def _m_cont(g, curve, preset):
    intensity, colour, ambient = {
        'three_point': (1.15, warmth_rgb(4500.0), 0.10), 'softbox': (0.75, (1, 1, 1), 0.16),
        'rembrandt': (1.5, warmth_rgb(3400.0), 0.04), 'neon': (1.6, (1.0, 0.0, 1.0), 0.06)}[preset]
    d, cov = _m_lit(g, curve, intensity, 1.0, colour=colour, ambient=ambient)
    return quantise(_over(d, cov, 0.0))


def _m_edges(g, curve):
    np = _np()
    cov, d = g.ellipse(0.5, 0.5, 0.35, 0.36)
    rim = np.clip((d - 0.75) / 0.25, 0.0, 1.0) ** 2
    x = 0.8 * (0.06 + 0.3 * g.spot(0.45, 0.45, 0.5)[..., None] + 3.5 * rim[..., None]) * _col(
        (1, 1, 1))
    return quantise(_over(_store(x, curve), cov, 0.0))


def _m_fog(g, curve):
    np = _np()
    d, cov = _m_lit(g, curve, 3.0, 1.0, colour=(1, 1, 1), ambient=0.06)
    fogf = np.clip((g.v - 0.15) * 1.2, 0.0, 1.0)[..., None]
    lit = d * (1.0 - fogf) + fogf
    return quantise(_over(lit, cov, np.ones((g.h, g.w, 3))))


def _m_export(g, curve):
    np = _np()
    d, cov = _m_lit(g, curve, 3.5, 1.0, ambient=0.06)
    rgb = quantise(_over(d, cov, 0.0))
    alpha = quantise(cov)[..., None]
    return np.concatenate([rgb, alpha], axis=-1)


def _m_oit(g, curve):
    back, cb = _m_lit(g, curve, 3.5, 1.0, (0.5, 0.5), (0.3, 0.3), colour=(1, 1, 1),
                      ambient=0.06, base=0.6)
    front, cf = _m_lit(g, curve, 3.5, 1.0, (0.5, 0.5), (0.42, 0.40), colour=(1, 1, 1),
                       ambient=0.06)
    behind = _over(back, cb, 0.0)
    return quantise(_over(0.5 * front + 0.5 * behind, cf, 0.0))


def _m_haze(g, curve, exposure, air=True):
    np = _np()
    d, cov = _m_lit(g, curve, 1.15, exposure, colour=warmth_rgb(4500.0), ambient=0.1)
    disp = _over(d, cov, 0.0)
    if air:
        beam = g.spot(0.6, 0.4, 0.8, 1.0)
        a = 0.5 * (beam * (1.0 - 0.6 * cov))[..., None] * _col((1, 1, 1))
        c8 = quantise(disp) / 255.0
        disp = air_hdr(c8, a, exposure) if curve == 'hdr' else air_knee(c8, a)
    return quantise(_post(disp, curve, exposure))


def _aces(x):
    np = _np()
    a, b, c, d, e = 2.51, 0.03, 2.43, 0.59, 0.14
    return np.clip((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0)


def model_image(tag, curve):
    """One synthetic render of a lighting_624.json tag for a build whose rig
    takes `curve` ('hdr' or 'knee'); a knee twin always takes the knee."""
    g = _Grid()
    if is_knee(tag):
        curve = 'knee'
        tag = tag.replace('_knee_rt', '_rt')
    base = re.sub(r'_rt[01]$', '', tag)
    m = re.match(r'^sweep_([0-9p]+)(_e05)?$', base)
    if m:
        return _m_sweep(g, curve, float(m.group(1).replace('p', '.')),
                        0.5 if m.group(2) else 1.0)
    m = re.match(r'^rec_(surface|cartoon|sticks|spheres|tube|air)_([ab])$', base)
    if m:
        rep = 'surface' if m.group(1) == 'air' else m.group(1)
        return _m_rec(g, curve, rep, m.group(2), air=m.group(1) == 'air')
    m = re.match(r'^hue_x(1|2p5)$', base)
    if m:
        return _m_hue(g, curve, float(m.group(1).replace('p', '.')))
    m = re.match(r'^peak_(metallic|plastic)_i([123])(_e067)?$', base)
    if m:
        return _m_peak(g, curve, m.group(1), float(m.group(2)),
                       2.0 / 3.0 if m.group(3) else 1.0)
    m = re.match(r'^glass_i([13])(_e033)?_hl([01])$', base)
    if m:
        return _m_glass(g, curve, float(m.group(1)), float(m.group(3)),
                        1.0 / 3.0 if m.group(2) else 1.0)
    m = re.match(r'^glass_body_i3_hl([01])$', base)
    if m:
        return _m_glass(g, curve, 3.0, float(m.group(1)), body=True)
    if base.startswith('shadow_cross'):
        return _m_shadow(g, curve)
    m = re.match(r'^display_(e06|e1|nocartoon)$', base)
    if m:
        return _m_display(g, curve, 0.6 if m.group(1) == 'e06' else 1.0,
                          cartoon=m.group(1) != 'nocartoon')
    if base == 'unlit':
        return _m_unlit(g, curve)
    if base == 'below_i04':
        return _m_below(g, curve)
    m = re.match(r'^cont_(%s)$' % '|'.join(PRESETS), base)
    if m:
        return _m_cont(g, curve, m.group(1))
    if base == 'edges':
        return _m_edges(g, curve)
    if base == 'fog':
        return _m_fog(g, curve)
    if base == 'export':
        return _m_export(g, curve)
    if base == 'oit':
        return _m_oit(g, curve)
    m = re.match(r'^haze683_(e1|e05|noair)$', base)
    if m:
        return _m_haze(g, curve, 0.5 if m.group(1) == 'e05' else 1.0,
                       air=m.group(1) != 'noair')
    if base == 'aces':
        d = _m_sweep(g, curve, 3.5) / 255.0
        return quantise(_aces(d))
    if base in ('frosted_i3', 'jelly_i3'):
        return _m_glass(g, curve, 3.0, 1.0)
    raise Usage('the model has no image for %r' % (tag,))


def model_images(curve):
    """{tag: image} for every tag the plans read (and the informational ones)."""
    return {t: model_image(t, curve) for t in scene_tags()}


def model_quantised_air(step=0.01, top=2.0):
    """The worst |T(Tinv(c8) + a) - T(Tinv(c) + a)| in levels over every 8-bit
    c (grey, its exact value c8 against c +- half a level) and a in
    step..top: what an 8-bit store costs the air (lighting_hdr.py pins <= 1)."""
    np = _np()
    c = (np.arange(256) / 255.0)[:, None]
    worst = 0.0
    for a in np.arange(step, top + 1e-9, step):
        exact = tone_scalar(tone_scalar_inverse(c) + a)
        for off in (-0.5 / 255.0, 0.5 / 255.0):
            near = tone_scalar(tone_scalar_inverse(np.clip(c + off, 0, 1)) + a)
            worst = max(worst, float(np.abs(near - exact).max()) * 255.0)
    return worst


def model_report(out=None):
    """The model's numbers: the curve's table, the air bound, and every check
    on the HDR and knee model renders. Returns (rc, payload)."""
    out = out or sys.stdout
    np = _np()
    rows = []
    print('## Tone curve (k %.2f, W %.1f) against mat_soft_knee, 8-bit levels' % (
        TONE_KNEE, TONE_WHITE), file=out)
    print('| scene x | knee | hdr |', file=out)
    print('| --- | --- | --- |', file=out)
    for x in (0.5, 0.8, 1.0, 1.5, 2.0, 3.07, 6.14, 9.21):
        k = int(quantise(soft_knee(np.array([x])))[0])
        h = int(quantise(tone_scalar(x)))
        rows.append({'x': x, 'knee': k, 'hdr': h})
        print('| %.2f | %d | %d |' % (x, k, h), file=out)
    air = model_quantised_air()
    print('\nair: an 8-bit store costs the HDR composite at most %.3f levels' % air, file=out)
    hdr = run_plan(model_images('hdr'), l2_plan())
    knee_imgs = model_images('knee')
    knee = run_plan(knee_imgs, l2_plan())
    neg = run_negative(model_images('hdr'))
    print('\n## The checks on the HDR model (every row must pass)', file=out)
    rc_h = report(hdr, out, kinds=True)
    print('\n## The checks on the knee model (a build before #624: every proof fails)',
          file=out)
    report(knee, out, kinds=True)
    failed_proofs = {(r.check, r.subject) for r in knee if not r.ok}
    unfailed = [(c, s) for c, subs in NEGATIVE.items() for s in subs
                if (c, s) not in failed_proofs]
    print('\n## The negative control on the HDR model (the knee twins fail every proof)',
          file=out)
    rc_n = report(neg, out, kinds=True)
    ok = rc_h == 0 and rc_n == 0 and not unfailed
    if unfailed:
        print('MODEL: proofs the knee model passes: %s' % ', '.join(
            '%s/%s' % u for u in unfailed), file=out)
    print('model: %s' % ('OK' if ok else 'FAILED'), file=out)
    payload = {'curve': rows, 'air_quantised_levels': air, 'hdr': _json_rows(hdr),
               'knee': _json_rows(knee), 'negative': _json_rows(neg),
               'knee_passes': ['%s/%s' % u for u in unfailed], 'ok': ok}
    return (0 if ok else 1), payload


# --- main ---------------------------------------------------------------------------------

def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    sub = ap.add_subparsers(dest='cmd')
    p = sub.add_parser('l2')
    p.add_argument('dir')
    p.add_argument('--checks', help='comma-separated subset of the checks')
    p.add_argument('--json', help='also write the rows here')
    for name in ('negative', 'table'):
        p = sub.add_parser(name)
        p.add_argument('dir')
        p.add_argument('--json', help='also write the rows here')
    p = sub.add_parser('model')
    p.add_argument('--json', help='also write the numbers here')
    args = ap.parse_args(argv)
    try:
        if args.cmd == 'l2':
            plan = l2_plan()
            results = run_plan(args.dir, plan, _checks(args.checks, plan))
            _write_json(args.json, {'l2': _json_rows(results)})
            return report(results, kinds=True)
        if args.cmd == 'negative':
            results = run_negative(args.dir)
            _write_json(args.json, {'negative': _json_rows(results)})
            return report(results, kinds=True)
        if args.cmd == 'table':
            l2 = run_plan(args.dir, l2_plan())
            neg = run_negative(args.dir)
            print('### L2 (check_hdr.py l2)\n')
            rc1 = report(l2, kinds=True)
            print('\n### Negative control (check_hdr.py negative: the knee fails every proof)\n')
            rc2 = report(neg, kinds=True)
            _write_json(args.json, {'l2': _json_rows(l2), 'negative': _json_rows(neg)})
            return 1 if rc1 or rc2 else 0
        if args.cmd == 'model':
            rc, payload = model_report()
            _write_json(args.json, payload)
            return rc
        ap.print_usage(sys.stderr)
        return 2
    except Usage as e:
        print('check_hdr.py: %s' % e, file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
