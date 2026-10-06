"""The air's evidence (#618): scene files, pixel checks, timing and movie harness.

L2 for #618 renders scripts/lighting/scenes/lighting_618.json with the frozen
harness and decides with scripts/lighting/check_air.py; the regression
lighting_618_noair.json is compared with master's renders (max 0); L6, the
idle table and the movie-export check run scripts/lighting/time_air.py. CI
has no GPU, so this pins what it can:

* check_air.py's decisions on synthetic images: a pass and a fail for every
  check, the plan (every check named, every image read or listed for the
  eye), the negative control and the thresholds in force;
* both scene files load with the frozen harness; every scene script runs
  in-process twice (the way the app runs it), leaves the camera alone,
  installs the rig, air and settings its tag says (framed explicitly on m),
  and _light_air_frame(offscreen=True) gives what the check expects for the
  tag: no air for the no-air twins, the overlay, grid and air-off tags and
  every regression scene; the listed dust times for the clock tags;
* the regression file sets a #618 setting only through _l618_opt and calls
  no _light_air_* helper (it must run on master);
* render.py's enabled harness rig carries no air (older scene files render
  as before), while RIG_OFF keeps its air for the rig-off run;
* time_air.py: the configuration matrices, the generated scripts (time_shadows'
  run-2 export guard and AUTOEXPORT probe, the air lines), the AUTOCMD
  refusals, two lines per ray=1 frame, the idle parsing and verdicts
  (inconclusive when the moving-dust control draws nothing), the movie
  comparisons, the tables and --dry-run.

Source-reading, so skipped (not passed) outside a repo checkout, decided by
one file every checkout has; in a checkout the ticket's own files are
required, so renaming one fails instead of skipping. The pixel checks are
skipped without numpy or Pillow.

Runs on a RayMol build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/lighting_air_check.py
"""
import importlib.util
import json
import os
import re
import shutil
import struct
import tempfile
import unittest

from pymol import cmd, lighting, testing

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), os.pardir,
                                     os.pardir, os.pardir))
LIGHTING = os.path.join(ROOT, 'scripts', 'lighting')
SCENES = os.path.join(LIGHTING, 'scenes')
PDB = os.path.join(ROOT, 'testing', 'data', '1rx1.pdb')
FILES = {
    'l2': os.path.join(SCENES, 'lighting_618.json'),
    'noair': os.path.join(SCENES, 'lighting_618_noair.json'),
}
HAVE_CHECKOUT = os.path.isfile(os.path.join(ROOT, 'layerGraphics', 'metal',
                                            'RendererMetal.mm'))

try:
    import numpy
    import PIL.Image
    HAVE_PIXELS = True
except ImportError:
    HAVE_PIXELS = False

RIG_LINE = 'cmd._l618_rig = '
NEW_SETTINGS = ('metal_light_air_resolution', 'metal_light_air_time',
                'metal_light_air_shadow_filter')


def f32(x):
    return struct.unpack('f', struct.pack('f', x))[0]


def assert_present(*paths):
    missing = [os.path.relpath(p, ROOT) for p in paths if not os.path.isfile(p)]
    if missing:
        raise AssertionError('missing from the checkout: %s' % ', '.join(missing))


def load_module(name, filename):
    spec = importlib.util.spec_from_file_location(name, os.path.join(LIGHTING, filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def restore_shims():
    """Undo the scene files' shims (what tearDown does)."""
    original = vars(cmd).pop('_l618_set', None)
    if original is not None:
        cmd.set_lights = original
    original = vars(cmd).pop('_l618_get', None)
    if original is not None:
        cmd.get_lights = original
    vars(cmd).pop('_l618_rig', None)


# --- the pixel checks on synthetic images -------------------------------------------

H, W = 72, 128
GEO = (slice(26, 47), slice(54, 75))        # the "molecule"
BEAM = (slice(10, 61), slice(10, 119))      # the haze footprint


def img(value=0):
    return numpy.full((H, W, 3), value, dtype=numpy.int32)


def scene_none():
    out = img()
    out[GEO] = 120
    return out


def plus(base, region, rgb):
    out = base.copy()
    out[region] = numpy.clip(out[region] + numpy.array(rgb), 0, 255)
    return out


def scene_haze():
    return plus(scene_none(), BEAM, (10, 8, 5))


@unittest.skipUnless(HAVE_CHECKOUT, 'needs a RayMol checkout (scripts/lighting)')
@unittest.skipUnless(HAVE_PIXELS, 'needs numpy and Pillow')
class TestChecks(testing.PyMOLTestCase):

    @classmethod
    def setUpClass(cls):
        assert_present(os.path.join(LIGHTING, 'check_air.py'),
                       os.path.join(LIGHTING, 'check_shadows.py'))
        cls.c = load_module('lighting_check_air', 'check_air.py')

    def test_reuses_check_shadows(self):
        c = self.c
        for name in ('load', 'luminance', 'geometry', 'check_same', 'check_differs',
                     'run_plan', 'Result', 'Usage'):
            self.assertIs(getattr(c, name), getattr(c.cs, name), name)
        with open(os.path.join(LIGHTING, 'check_air.py')) as fh:
            src = fh.read()
        # imported by path, never copied: no second definition of its helpers
        for name in ('load', 'luminance', 'geometry', 'check_same', 'check_differs',
                     'run_plan'):
            self.assertNotIn('def %s(' % name, src)

    def testThresholdsPinned(self):
        # FROZEN after L2 rounds 1 and 2 (check_air.py's thresholds block
        # gives the measured values); change only with new L2 evidence.
        pinned = {
            'ADD_MIN': 1, 'VISIBLE_PX': 2000, 'VISIBLE_MEAN': 2.0, 'BG_MARGIN': 3,
            'KNEE': 204, 'RT_BG_MAX': 1, 'RT_PRESENT_PX': 2000, 'RT_GEO_TOL': 4,
            'RT_GEO_SHARE': 0.99, 'RT_GEO_MEAN': 1.0, 'SHAFT_DARKEN': 8, 'SHAFT_PX': 500,
            'SHAFT_OTHER': 2, 'REACH_PX': 500, 'REACH_DARKEN': 24, 'REACH_SHARE': 0.90,
            'REACH_BOXES': {'a': (1200, 500, 1280, 720), 'b': (0, 0, 64, 128)},
            'IN_BEAMS_PX': 50, 'IN_BEAMS_SHARE': 0.98, 'IN_BEAMS_DILATE': 3,
            'FOOT_MIN': 2, 'MOTE_MIN': 10, 'HUE_MIN': 8, 'COLOUR_SHARE': 0.90,
            'COLOUR_PX': 20, 'UNCHANGED_DILATE': 3, 'WHITE_PX': 1000, 'HALF_TOL': 8,
            'HALF_SHARE': 0.97, 'HALF_MEAN': 2.0, 'HALF_EDGE_BAND': 2, 'HALF_EDGE_PX': 200,
            'HALF_EDGE_SHARE': 0.97, 'FILTER_TOL': 6, 'FILTER_SHARE': 0.97,
            'SATURATED_MAX': 0.02,
        }
        for name, value in pinned.items():
            self.assertEqual(getattr(self.c, name), value, name)
        # the plan's definitions
        self.assertEqual(self.c.cs.DIFFERS_MIN, 200)

    def testVisible(self):
        none, haze = scene_none(), scene_haze()
        self.assertTrue(self.c.check_visible(none, haze).ok)
        self.assertFalse(self.c.check_visible(none, none).ok)
        # too few pixels, or too faint
        self.assertFalse(self.c.check_visible(none, plus(none, (slice(0, 5), slice(0, 20)),
                                                         (50, 50, 50))).ok)
        self.assertFalse(self.c.check_visible(none, plus(none, BEAM, (1, 1, 1))).ok)

    def testRtMatch(self):
        none, haze = scene_none(), scene_haze()
        self.assertTrue(self.c.check_rt_match(none, none, haze, haze).ok)
        # a background pixel that differs by 3 between rt0 and rt1
        off = haze.copy()
        off[12, 12] += 3
        self.assertFalse(self.c.check_rt_match(none, none, haze, off).ok)
        # ...but next to geometry (FXAA) it is not background
        near = haze.copy()
        near[25, 60] += 3
        self.assertTrue(self.c.check_rt_match(none, none, haze, near).ok)
        # the air on geometry disagrees
        geo = plus(haze, GEO, (6, 6, 6))
        self.assertFalse(self.c.check_rt_match(none, none, haze, geo).ok)
        # ...but not where the composite crosses the knee: past it the air
        # is compressed by the base's brightness, which the two paths shade
        # differently (round 1)
        bright = plus(haze, GEO, (90, 90, 90))                # 120 + 90 > 204
        self.assertTrue(self.c.check_rt_match(none, none, haze, bright).ok)
        # no air at all: nothing to match
        self.assertFalse(self.c.check_rt_match(none, none, none, none).ok)

    def shafts_set(self):
        noair = scene_none()
        a_reg = (slice(0, 36), slice(0, 128))
        b_reg = (slice(36, 72), slice(0, 128))
        none = plus(plus(noair, a_reg, (40, 0, 0)), b_reg, (0, 0, 40))
        a_shaft = (slice(2, 20), slice(80, 128))           # 864 px, background
        b_shaft = (slice(52, 70), slice(0, 48))
        a = plus(none, a_shaft, (-20, 0, 0))
        b = plus(none, b_shaft, (0, 0, -20))
        ab = plus(a, b_shaft, (0, 0, -20))
        return noair, none, a, b, ab, a_shaft, b_shaft

    def testShaftsCross(self):
        c = self.c
        noair, none, a, b, ab, a_shaft, _ = self.shafts_set()
        self.assertTrue(c.check_shafts_cross(noair, none, a, 'a').ok)
        self.assertTrue(c.check_shafts_cross(noair, none, b, 'b').ok)
        self.assertTrue(c.check_shafts_cross(noair, none, ab, 'ab').ok)
        # no shaft (no pass), the wrong light's shaft, or B's haze moved by A
        self.assertFalse(c.check_shafts_cross(noair, none, none, 'a').ok)
        self.assertFalse(c.check_shafts_cross(noair, none, b, 'a').ok)
        self.assertFalse(c.check_shafts_cross(noair, none, a, 'ab').ok)
        leak = plus(a, (slice(40, 50), slice(80, 128)), (0, 0, -5))
        self.assertFalse(c.check_shafts_cross(noair, none, leak, 'a').ok)

    def testShaftsSpot(self):
        none = scene_none()
        hazens = plus(none, BEAM, (30, 25, 15))
        haze = plus(hazens, (slice(50, 62), slice(40, 118)), (-20, -20, -20))
        self.assertTrue(self.c.check_shafts_spot(none, haze, hazens).ok)
        self.assertFalse(self.c.check_shafts_spot(none, hazens, hazens).ok)

    def testReach(self):
        c = self.c
        noair, none, _, _, _, a_shaft, _ = self.shafts_set()
        box = (80, 2, 128, 20)                               # a_shaft: 864 px
        deep = plus(none, a_shaft, (-30, 0, 0))
        self.assertTrue(c.check_reach(noair, none, deep, box, 'r').ok)
        # the shaft stops short of the box
        self.assertFalse(c.check_reach(noair, none, deep, (0, 0, 60, 30), 'r').ok)
        self.assertFalse(c.check_reach(noair, none, deep, box, 'b').ok)
        # past the far plane the air reads lit: a shallow drop
        shallow = plus(none, a_shaft, (-12, 0, 0))
        self.assertFalse(c.check_reach(noair, none, shallow, box, 'r').ok)
        # ...or only part of the box
        part = plus(none, (slice(2, 11), slice(80, 128)), (-30, 0, 0))
        self.assertFalse(c.check_reach(noair, none, part, box, 'r').ok)
        # a box with too few background pixels checks nothing
        self.assertFalse(c.check_reach(noair, none, deep, (80, 2, 100, 20), 'r').ok)

    def testInBeams(self):
        none, haze = scene_none(), scene_haze()
        inside = haze.copy()
        for i in range(60):
            inside[12 + (i % 45), 12 + (i * 7) % 100] += 9
        self.assertTrue(self.c.check_in_beams(none, haze, inside).ok)
        outside = haze.copy()
        for i in range(60):
            outside[66 + i % 5, 2 + i * 2] += 9
        self.assertFalse(self.c.check_in_beams(none, haze, outside).ok)
        self.assertFalse(self.c.check_in_beams(none, haze, haze).ok)    # no dust

    def colour_set(self, a_rgb=(30, 0, 2), b_rgb=(2, 0, 30)):
        noair = scene_none()
        a_reg = (slice(0, 72), slice(0, 50))
        b_reg = (slice(0, 72), slice(78, 128))
        none = plus(plus(noair, a_reg, (5, 0, 0)), b_reg, (0, 0, 5))
        dust = noair.copy()
        for i in range(30):
            dust[2 + 2 * i, 5 + i % 40] += a_rgb
            dust[2 + 2 * i, 82 + i % 40] += b_rgb
        return noair, none, dust

    def testColour(self):
        c = self.c
        self.assertTrue(c.check_colour(*self.colour_set()).ok)
        # A's motes are blue, or there are no motes
        self.assertFalse(c.check_colour(*self.colour_set(a_rgb=(2, 0, 30))).ok)
        noair, none, _ = self.colour_set()
        self.assertFalse(c.check_colour(noair, none, noair).ok)

    def white_set(self):
        none, haze = scene_none(), scene_haze()
        white_none = img(255)
        white_none[GEO] = 120
        white_haze = numpy.clip(white_none + (haze - none), 0, 255)
        return none, haze, white_none, white_haze

    def testUnchanged(self):
        c = self.c
        none, haze, wn, wh = self.white_set()
        self.assertTrue(c.check_unchanged(none, haze, wn, wh, need_white=True).ok)
        # a pixel outside the footprint changes
        bad = wh.copy()
        bad[68, 5] = 254
        self.assertFalse(c.check_unchanged(none, haze, wn, bad).ok)
        # a white pixel inside the footprint loses its 255 (the knee dims it)
        dim = wh.copy()
        dim[15, 20] = 250
        self.assertFalse(c.check_unchanged(none, haze, wn, dim).ok)
        # no white where white is required
        self.assertFalse(c.check_unchanged(none, haze, none, haze, need_white=True).ok)
        self.assertTrue(c.check_unchanged(none, haze, none, haze, need_white=False).ok)
        # a geometry pixel inside the footprint gets darker (a whole-pixel knee)
        darker = wh.copy()
        darker[30, 60] = 110
        self.assertFalse(c.check_unchanged(none, haze, wn, darker).ok)
        # the air lights every pixel: no outside to compare, nothing checked
        everywhere = plus(none, (slice(None), slice(None)), (3, 3, 3))
        self.assertFalse(c.check_unchanged(none, everywhere, wn, wh).ok)

    def testHalfAndFilter(self):
        c = self.c
        none, full = scene_none(), scene_haze()
        close = full.copy()
        close[10:20, 10:40] += 3                              # 300 px, 3 levels
        self.assertTrue(c.check_half(none, full, close).ok)
        self.assertTrue(c.check_filter(none, full, close).ok)
        self.assertFalse(c.check_half(none, full, full).ok)   # identical: no switch
        far = full.copy()
        far[10:60, 10:60] += 20                               # deltas disagree
        self.assertFalse(c.check_half(none, full, far).ok)
        self.assertFalse(c.check_filter(none, full, far).ok)
        self.assertFalse(c.check_half(none, none, none).ok)   # no air
        # a halo: the air bleeds across one side of the molecule. Too few
        # pixels for the frame-wide share, caught at the silhouettes.
        halo = close.copy()                                   # 300 px differ by 3
        halo[GEO[0], 52:56] += 20                             # 84 px across the edge
        frame = c._delta_agreement('half', '', none, halo, full, c.HALF_TOL, c.HALF_SHARE,
                                   c.HALF_MEAN)
        self.assertTrue(frame.ok)
        self.assertFalse(c.check_half(none, full, halo).ok)
        # no silhouettes at all (nothing drawn but air): not a pass
        empty = img()
        self.assertFalse(c.check_half(empty, plus(empty, BEAM, (10, 8, 5)),
                                      plus(empty, BEAM, (11, 8, 5))).ok)

    def testSilhouettes(self):
        edge = self.c.silhouettes(scene_none())
        # a 2 px band each side of the 21 x 21 molecule's outline
        self.assertEqual(int(edge.sum()), (25 * 25 - 21 * 21) + (21 * 21 - 17 * 17))
        self.assertTrue(edge[26, 54] and edge[24, 60] and edge[27, 60])
        self.assertFalse(edge[36, 64] or edge[23, 60] or edge[28, 60])

    def testNoClip(self):
        ok = img(100)
        ok[0, :50] = 255                                       # 0.5%
        self.assertTrue(self.c.check_no_clip(ok).ok)
        bad = img(100)
        bad[:4, :] = 255                                       # 5.6%
        self.assertFalse(self.c.check_no_clip(bad).ok)

    def testDilateAndBackground(self):
        m = numpy.zeros((9, 9), dtype=bool)
        m[4, 4] = True
        self.assertEqual(int(self.c.dilate(m, 1).sum()), 9)
        self.assertEqual(int(self.c.dilate(m, 3).sum()), 49)
        bg = self.c.background(scene_none())
        self.assertFalse(bg[26 - 3, 60])
        self.assertTrue(bg[26 - 4, 60])

    def testPlanNamesEveryCheck(self):
        names = {p[0] for p in self.c.l2_plan()}
        self.assertEqual(names, {'visible', 'rt_match', 'shafts', 'reach', 'in_beams',
                                 'colour', 'unchanged', 'moves', 'clock', 'geometry',
                                 'off', 'half', 'filter', 'no_clip'})
        subjects = [(p[0], p[1]) for p in self.c.l2_plan()]
        self.assertEqual(len(subjects), len(set(subjects)))
        # the byte pairs of the clock
        clock = {p[1]: p[3] for p in self.c.l2_plan() if p[0] == 'clock'}
        self.assertEqual(clock['f16_is_pin'], ['movie_f16_rt0', 'pinned05_rt0'])
        self.assertEqual(clock['still_is_f1'], ['still_rt0', 'movie_f1_rt0'])
        self.assertEqual(clock['speed0'], ['speed0_f16_rt0', 'speed0_still_rt0'])
        # rt_match runs every listed pair at rt0 against rt1
        for p in self.c.l2_plan():
            if p[0] == 'rt_match':
                self.assertEqual([t[-3:] for t in p[3]], ['rt0', 'rt1', 'rt0', 'rt1'], p[1])

    def testNegativeControl(self):
        c = self.c
        plan = c.negative_plan()
        self.assertEqual({p[0] for p in plan}, {'visible', 'in_beams', 'shafts', 'moves',
                                                'colour'})
        self.assertEqual(sorted((p[0], p[1]) for p in plan),
                         sorted((k, s) for k, v in c.NEGATIVE.items() for s in v))
        tmp = tempfile.mkdtemp(prefix='l618n')
        self.addCleanup(shutil.rmtree, tmp, True)
        tags = {t for p in plan for t in p[3]}
        for t in tags:      # every image the same: the renders of a build without air
            PIL.Image.fromarray(scene_none().astype(numpy.uint8)).save(
                os.path.join(tmp, t + '.png'))
        results = c.run_negative(tmp)
        self.assertTrue(all(r.ok for r in results), results)
        # one check that passes without the pass is a failed negative control
        PIL.Image.fromarray(scene_haze().astype(numpy.uint8)).save(
            os.path.join(tmp, 'spot_haze_rt0.png'))
        results = {r.subject: r for r in c.run_negative(tmp) if r.check == 'visible'}
        self.assertFalse(results['spot_haze_rt0'].ok)
        self.assertIn('PASSES', results['spot_haze_rt0'].detail)
        self.assertEqual(c.main(['negative', tmp]), 1)

    def testRunPlan(self):
        c = self.c
        tmp = tempfile.mkdtemp(prefix='l618c')
        self.addCleanup(shutil.rmtree, tmp, True)
        for tag, image in (('spot_none_rt0', scene_none()), ('spot_haze_rt0', scene_haze())):
            PIL.Image.fromarray(image.astype(numpy.uint8)).save(os.path.join(tmp, tag + '.png'))
        plan = [p for p in c.l2_plan() if p[1] == 'spot_haze_rt0']
        results = c.run_plan(tmp, plan)
        self.assertEqual([(r.check, r.ok) for r in results], [('visible', True)])
        rt1 = [p for p in c.l2_plan() if p[1] == 'spot_haze_rt1']
        self.assertIn('missing', c.run_plan(tmp, rt1)[0].detail)
        self.assertEqual(c.main(['l2', tmp, '--checks', 'visible']), 1)    # rt1 missing
        self.assertEqual(c.main(['l2', tmp, '--checks', 'bogus']), 2)
        self.assertEqual(c.main(['l2', os.path.join(tmp, 'nope')]), 2)


# --- the scene files ------------------------------------------------------------------

def tag_parts(tag):
    m = re.match(r'^(.*)_rt([01])$', tag)
    return m.group(1), int(m.group(2))


CLOCK_TIMES = {          # unpinned clock tags: the dust time each must get
    'still': 0.0, 'movie_f1': 0.0, 'movie_f16': 0.5, 'movie_f16b': 0.5,
    'movie_f17': 16 / 30.0, 'pinned05': 0.5, 'speed0_still': 0.0, 'speed0_f16': 0.0,
}
MOVIE_FRAME = {'movie_f1': 1, 'movie_f16': 16, 'movie_f16b': 16, 'movie_f17': 17,
               'speed0_f16': 16}


def l2_expected(tag):
    """What a lighting_618.json tag stands for, written out from the tag:
    {'haze', 'dust', 'shadowed', 'ms', 'time' (None: no air in the frame),
     'res', 'filter', 'pin', 'grid'}."""
    base, _ = tag_parts(tag)
    e = {'ms': 1, 'res': 0, 'filter': 0, 'pin': 2.0, 'grid': False, 'shadowed': ['spot']}
    families = [
        ('spot_none', (0.0, 0.0)), ('spot_hazedust', (0.6, 0.6)),
        ('spot_hazens_ms0', (0.6, 0.0)), ('spot_hazens', (0.6, 0.0)),
        ('spot_haze_ms0', (0.6, 0.0)), ('spot_haze', (0.6, 0.0)),
        ('spot_dust', (0.0, 1.0)), ('backlit_noair', (0.0, 0.0)),
        ('backlit_g09', (0.6, 0.5)), ('backlit', (0.18, 0.5)), ('cross_noair', (0.0, 0.0)),
        ('cross_dust', (0.0, 0.8)), ('cross_', (0.5, 0.0)), ('s3_noair', (0.0, 0.0)),
        ('s3', (0.3, 0.5)), ('half_hazedust', (0.6, 0.6)), ('filter9_haze', (0.6, 0.0)),
        ('ovl_air', (0.6, 0.6)), ('ovl_noair', (0.0, 0.0)), ('airoff', (0.0, 0.0)),
        ('grid_air', (0.6, 0.6)), ('grid_noair', (0.0, 0.0)), ('whitebg_none', (0.0, 0.0)),
        ('whitebg_haze', (0.5, 0.0)),
    ]
    if re.match(r'^t\d+_dust$', base):
        e['haze'], e['dust'] = 0.0, 1.0
        e['pin'] = {'t0': 0.0, 't05': 0.5, 't1': 1.0, 't2': 2.0, 't4': 4.0}[base[:-5]]
    elif re.match(r'^t\d+_haze$', base):
        e['haze'], e['dust'] = 0.6, 0.0
        e['pin'] = {'t2': 2.0, 't4': 4.0}[base[:-5]]
    elif base in CLOCK_TIMES:
        e['haze'], e['dust'] = 0.6, 0.6
        e['pin'] = 0.5 if base == 'pinned05' else -1.0
    elif base in ('ortho_haze', 'glass_haze', 'transparent_haze', 'rttrans_haze'):
        e['haze'], e['dust'] = 0.6, 0.0
    else:
        for prefix, (haze, dust) in families:
            if base.startswith(prefix):
                e['haze'], e['dust'] = haze, dust
                break
        else:
            raise AssertionError('no expectation for %s' % tag)
    if base.endswith('_ms0'):
        e['ms'] = 0
    if base.startswith('spot_hazens'):
        e['shadowed'] = []
    elif base.startswith('backlit'):
        e['shadowed'] = ['back']
    elif base.startswith('whitebg'):
        e['shadowed'] = []
    elif base.startswith('cross_'):
        k = base[len('cross_'):]
        e['shadowed'] = {'a': ['red'], 'b': ['blue'], 'ab': ['red', 'blue']}.get(k, [])
    elif base.startswith('s3'):
        e['shadowed'] = ['spot', 'back', 'third']
    if base.startswith('half'):
        e['res'] = 2
    if base.startswith('filter9'):
        e['filter'] = 2
    e['grid'] = base.startswith('grid')
    if e['haze'] == 0.0 and e['dust'] == 0.0 or base.startswith(('ovl_', 'grid_')):
        e['time'] = None
    elif base in CLOCK_TIMES:
        e['time'] = CLOCK_TIMES[base]
    else:
        e['time'] = e['pin']
    return e


@unittest.skipUnless(HAVE_CHECKOUT, 'needs a RayMol checkout (scripts/lighting)')
class TestSceneFiles(testing.PyMOLTestCase):

    @classmethod
    def setUpClass(cls):
        assert_present(os.path.join(LIGHTING, 'render.py'),
                       os.path.join(LIGHTING, 'check_air.py'), PDB, *FILES.values())
        cls.render = load_module('lighting_render', 'render.py')
        cls.jobs = {k: cls.render.scene_file_jobs(v) for k, v in FILES.items()}
        cls.specs = {}
        for k, v in FILES.items():
            with open(v) as handle:
                cls.specs[k] = json.load(handle)

    def setUp(self):
        super(TestSceneFiles, self).setUp()
        self.original = (cmd.set_lights, cmd.get_lights)
        self.tmp = tempfile.mkdtemp(prefix='l618')
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def tearDown(self):
        restore_shims()
        cmd.set_lights(None)
        self.assertIs(cmd.set_lights, self.original[0])
        self.assertIs(cmd.get_lights, self.original[1])
        super(TestSceneFiles, self).tearDown()

    def run_job(self, job, times=1):
        out = os.path.join(self.tmp, 'out')
        self.render.write_scripts(ROOT, out, [job])
        script = self.render.script_path(out, job.tag)
        marker = self.render.marker_path(out, job.tag)
        if os.path.exists(marker):
            os.remove(marker)
        for _ in range(times):
            cmd.run(script)
        return marker

    def job(self, which, tag):
        return {j.tag: j for j in self.jobs[which]}[tag]

    def m_frame(self):
        mn, mx = cmd.get_extent('m')
        return ([(a + b) / 2.0 for a, b in zip(mn, mx)],
                sum((b - a) ** 2 for a, b in zip(mn, mx)) ** 0.5 / 2.0)

    def assertCamera(self, tag):
        for i, (got, want) in enumerate(zip(cmd.get_view(), self.render.VIEW)):
            if i == 17:
                got, want = abs(got), abs(want)
            self.assertAlmostEqual(got, want, delta=1e-3,
                                   msg='%s moves the camera (view[%d])' % (tag, i))

    def assertFramed(self, rig, tag):
        centre, size = self.m_frame()
        for got, want in zip(rig['centre'], centre):
            self.assertAlmostEqual(got, want, delta=1e-4, msg=tag)
        self.assertAlmostEqual(rig['size'], size, delta=1e-4, msg=tag)

    def testSceneFilesLoad(self):
        self.assertEqual(len(self.jobs['l2']), 64)
        self.assertEqual(len(self.jobs['noair']), 31)
        for which, spec in self.specs.items():
            self.assertEqual(spec['rig'], 'on', which)
            self.assertIsNone(spec['base'], which)
            self.assertIn('#618', spec['comment'])
            for job in self.jobs[which]:
                self.assertEqual(job.size, (1280, 720), job.tag)
                tag_parts(job.tag)
                self.assertTrue(job.extra[-1].startswith(RIG_LINE), job.tag)

    def testEveryCheckHasItsImages(self):
        check = load_module('lighting_check_air', 'check_air.py')
        tags = {j.tag for j in self.jobs['l2']}
        need = {t for p in check.l2_plan() for t in p[3]}
        self.assertEqual(sorted(need - tags), [])
        self.assertEqual(sorted(tags - need - set(check.INFORMATIONAL)), [])
        self.assertEqual(sorted(set(check.INFORMATIONAL) - tags), [])

    def testNoAirFileCoversThePlan(self):
        tags = {j.tag for j in self.jobs['noair']}
        for rep in ('cartoon', 'surface', 'sticks', 'spheres', 'tube'):
            for s in (0, 1):
                for rt in (0, 1):
                    self.assertIn('zero_%s_s%d_rt%d' % (rep, s, rt), tags)
        for tag in ('zero_ortho_rt0', 'zero_oit_rt0', 'zero_oit_rt1', 'zero_grid_rt0',
                    'rigoff_air_surface_rt0', 'rigoff_air_surface_rt1',
                    'rigoff_air_cartoon_rt0', 'rigoff_air_cartoon_rt1', 'atmo_norig_rt0',
                    'suppressed_grid_rt0', 'suppressed_ovl_rt0'):
            self.assertIn(tag, tags)

    def testNewSettingsGuarded(self):
        """Every line that names a #618 setting sets it through _l618_opt (the
        regression file must run on master, where they do not exist); the
        regression file calls no _light_air_* helper; the clock pin is set in
        the L2 file's extra lines."""
        for which, spec in self.specs.items():
            lines = list(spec['extra']) + [l for s in spec['scenes'] for l in s['lines']]
            for line in lines:
                for name in NEW_SETTINGS:
                    for m in re.finditer(name, line):
                        before = line[:m.start()]
                        self.assertTrue(before.endswith("_l618_opt('"),
                                        '%s: %s not through _l618_opt: %s' % (which, name, line))
            if which == 'noair':
                # (metal_light_air_* settings aside: those are guarded above)
                self.assertIsNone(re.search(r'(?<![A-Za-z0-9])_light_air_', '\n'.join(lines)))
        self.assertIn("_l618_opt('metal_light_air_time', 2.0)", self.specs['l2']['extra'])

    def testHarnessRigHasNoAir(self):
        """render.py's enabled rig carries no air (#618: scene files written
        before the air render as they did); --rig off keeps RIG_OFF's air."""
        r = self.render
        self.assertEqual(r.RIG_OFF['air'], {'haze': 0.3, 'dust': 0.5, 'dust_size': 0.4,
                                            'dust_speed': 1.0, 'scatter': 0.55, 'seed': 7})
        self.assertIn("_lh_rig.pop('air', None)", r._rig_block('on'))
        self.assertNotIn("_lh_rig.pop('air', None)", r._rig_block('off'))
        out = os.path.join(self.tmp, 'h')
        job = r.l1_job('cartoon_rt0', 'on')
        r.write_scripts(ROOT, out, [job])
        cmd.run(r.script_path(out, job.tag))
        rig = cmd.get_lights()
        self.assertIs(rig['enabled'], True)
        self.assertEqual((rig['air']['haze'], rig['air']['dust']), (0.0, 0.0))
        self.assertIsNone(lighting._light_air_frame(offscreen=True))

    def testEveryL2ScriptRunsInProcess(self):
        ran = 0
        for job in self.jobs['l2']:
            ran += 1
            marker = self.run_job(job, times=2)
            self.assertIsNone(self.render.check_marker(marker, job.tag, 'on'), job.tag)
            self.assertCamera(job.tag)
            e = l2_expected(job.tag)
            rig = cmd.get_lights()
            self.assertIs(rig['enabled'], True, job.tag)
            self.assertFramed(rig, job.tag)
            self.assertAlmostEqual(rig['air']['haze'], e['haze'], places=6, msg=job.tag)
            self.assertAlmostEqual(rig['air']['dust'], e['dust'], places=6, msg=job.tag)
            self.assertEqual([l['name'] for l in rig['lights'] if l['shadow']], e['shadowed'],
                             job.tag)
            self.assertEqual(cmd.get_setting_int('metal_shadows'), e['ms'], job.tag)
            base, rt = tag_parts(job.tag)
            self.assertEqual(cmd.get_setting_int('metal_raytrace'), rt, job.tag)
            self.assertEqual(cmd.get_setting_int('depth_cue'), 0, job.tag)
            self.assertEqual(cmd.get_setting_int('grid_mode'), int(e['grid']), job.tag)
            self.assertEqual(cmd.get_setting_int('orthoscopic'), int(base.startswith('ortho')),
                             job.tag)
            self.assertEqual(cmd.get_setting_int('metal_rt_transparent'),
                             int(base.startswith('rttrans')), job.tag)
            self.assertEqual(cmd.get_setting_int('metal_light_air_resolution'), e['res'], job.tag)
            self.assertEqual(cmd.get_setting_int('metal_light_air_shadow_filter'), e['filter'],
                             job.tag)
            self.assertAlmostEqual(cmd.get_setting_float('metal_light_air_time'), e['pin'],
                                   places=6, msg=job.tag)
            if base in MOVIE_FRAME:
                self.assertEqual(cmd.count_frames(), 48, job.tag)
                self.assertEqual(cmd.get_frame(), MOVIE_FRAME[base], job.tag)
                self.assertEqual(cmd.get_setting_float('movie_fps'), 30.0, job.tag)
            else:
                self.assertLessEqual(cmd.count_frames(), 1, job.tag)
            if base.startswith('whitebg'):
                self.assertEqual(cmd.get_color_tuple(cmd.get_setting_tuple('bg_rgb')[1][0]),
                                 (1.0, 1.0, 1.0), job.tag)
            if base.startswith('ovl'):
                self.assertEqual(cmd.get_names('objects', enabled_only=1), ['_move_gizmo'],
                                 job.tag)
            # the air block the GPU gets for this tag (an offscreen frame;
            # CI lays out no grid, so a grid scene passes the grid as the
            # renderer would see it)
            grid = (2, 1, 0) if e['grid'] else None
            frame = lighting._light_air_frame(offscreen=True, grid=grid)
            if e['time'] is None:
                self.assertIsNone(frame, job.tag)
            else:
                self.assertIsNotNone(frame, job.tag)
                self.assertEqual(frame['time'], f32(e['time']), job.tag)
                self.assertEqual(frame['scale'], 0.5 if e['res'] == 2 else 1.0, job.tag)
                self.assertEqual(frame['shadow_filter'], 2 if e['filter'] == 2 else 1, job.tag)
            if e['grid'] and e['haze']:
                # the air is on: only the grid suppresses it
                self.assertIsNotNone(lighting._light_air_frame(offscreen=True), job.tag)
            if base == 'ovl_air':
                # nothing enabled at all: no air either
                cmd.disable('_move_gizmo')
                self.assertIsNone(lighting._light_air_frame(offscreen=True), job.tag)
            restore_shims()
        self.assertEqual(ran, 64)

    def testEveryNoAirScriptRunsInProcess(self):
        zero = {'haze': 0.0, 'dust': 0.0, 'dust_size': 1.2, 'dust_speed': 3.0,
                'scatter': -0.4, 'seed': 99}
        for job in self.jobs['noair']:
            marker = self.run_job(job, times=2)
            self.assertIsNone(self.render.check_marker(marker, job.tag, job.rig), job.tag)
            self.assertCamera(job.tag)
            base, rt = tag_parts(job.tag)
            self.assertEqual(cmd.get_setting_int('metal_raytrace'), rt, job.tag)
            grid = base.endswith('grid')
            self.assertEqual(cmd.get_setting_int('grid_mode'), int(grid), job.tag)
            # never any air in the frame
            self.assertIsNone(lighting._light_air_frame(
                offscreen=True, grid=(2, 1, 0) if grid else None), job.tag)
            # the #618 settings are set (they exist here) and change nothing
            self.assertAlmostEqual(cmd.get_setting_float('metal_light_air_time'), 2.0, places=6)
            self.assertEqual(cmd.get_setting_int('metal_light_air_resolution'), 2)
            self.assertEqual(cmd.get_setting_int('metal_light_air_shadow_filter'), 2)
            if base.startswith('zero_'):
                rig = cmd.get_lights()
                self.assertIs(rig['enabled'], True, job.tag)
                self.assertFramed(rig, job.tag)
                for k, v in zero.items():
                    self.assertAlmostEqual(rig['air'][k], v, places=5, msg=job.tag)
                s1 = '_s1_' in job.tag or base in ('zero_ortho', 'zero_oit', 'zero_grid')
                self.assertEqual([l['name'] for l in rig['lights'] if l['shadow']],
                                 ['spot'] if s1 else [], job.tag)
                self.assertEqual(cmd.get_setting_int('metal_shadows'), int(s1), job.tag)
                self.assertEqual(cmd.get_setting_int('orthoscopic'), int('ortho' in base))
                if base == 'zero_oit':
                    # a glass surface (object g) over the 50% transparent one
                    self.assertGreater(cmd.get_setting_int('surface_material', 'g'), 0)
                    self.assertEqual(cmd.get_setting_float('transparency'), 0.5)
            elif base.startswith('rigoff_air'):
                self.assertEqual(job.rig, 'off')
                rig = cmd.get_lights()
                self.assertIs(rig['enabled'], False, job.tag)
                self.assertGreaterEqual(len(rig['lights']), 1, job.tag)
                self.assertAlmostEqual(rig['air']['haze'], 0.3, places=6)
                self.assertAlmostEqual(rig['air']['dust'], 0.5, places=6)
            elif base == 'atmo_norig':
                self.assertEqual(job.rig, 'none')
                self.assertIsNone(cmd.get_lights())          # the harness's view
                real = cmd._l618_get()
                self.assertIs(real['enabled'], False)
                self.assertEqual(real['lights'], [])
                self.assertAlmostEqual(real['air']['haze'], 0.3, places=6)
                self.assertAlmostEqual(real['air']['dust'], 0.5, places=6)
                self.assertIsNone(real['centre'])
            elif base.startswith('suppressed_'):
                rig = cmd.get_lights()
                self.assertIs(rig['enabled'], True, job.tag)
                self.assertFramed(rig, job.tag)
                self.assertAlmostEqual(rig['air']['haze'], 0.3, places=6)
                self.assertAlmostEqual(rig['air']['dust'], 0.5, places=6)
                if grid:
                    # the air is on: only the grid suppresses it
                    self.assertIsNotNone(lighting._light_air_frame(offscreen=True))
                else:
                    self.assertEqual(cmd.get_names('objects', enabled_only=1),
                                     ['_move_gizmo'])
            else:
                self.fail('no expectation for %s' % job.tag)
            restore_shims()

    def testGetLightsShimOnlyHidesAnEmptyOffRig(self):
        self.run_job(self.job('noair', 'atmo_norig_rt0'), times=2)
        self.assertIsNone(cmd.get_lights())
        # a rig with lights is reported as it is, through the same shim
        cmd.lights('three_point')
        self.assertIsNotNone(cmd.get_lights())
        self.assertEqual(len(cmd.get_lights()['lights']), 3)
        # every script restores the real get_lights before it acts
        self.run_job(self.job('noair', 'zero_cartoon_s0_rt0'))
        self.assertIs(cmd.get_lights, self.original[1])

    def testOverlayInsideTheView(self):
        """The ovl scenes' _move_gizmo sphere is at the rig centre, in view (the
        image must not be one colour), and is the only thing shown."""
        self.run_job(self.job('l2', 'ovl_air_rt0'))
        mn, mx = cmd.get_extent('_move_gizmo')
        centre, size = self.m_frame()
        for a, b, c in zip(mn, mx, centre):
            self.assertAlmostEqual((a + b) / 2.0, c, delta=0.1)
        self.assertLess(max(b - a for a, b in zip(mn, mx)), 0.5 * size)


# --- time_air.py ------------------------------------------------------------------

@unittest.skipUnless(HAVE_CHECKOUT, 'needs a RayMol checkout (scripts/lighting)')
class TestTimeAir(testing.PyMOLTestCase):

    @classmethod
    def setUpClass(cls):
        assert_present(os.path.join(LIGHTING, 'time_air.py'),
                       os.path.join(LIGHTING, 'time_shadows.py'), PDB)
        cls.t = load_module('lighting_time_air', 'time_air.py')
        cls.render = cls.t.ts.load_render()

    def setUp(self):
        super(TestTimeAir, self).setUp()
        self.tmp = tempfile.mkdtemp(prefix='l618t')
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def tearDown(self):
        vars(cmd).pop('_ts_runs', None)
        cmd.set_lights(None)
        super(TestTimeAir, self).tearDown()

    def testReusesTimeShadows(self):
        t = self.t
        self.assertEqual(t.LINES_PER_FRAME, 2)
        self.assertEqual(t.PROBE, (64, 64, 0))
        self.assertIs(t.Refusal, t.ts.Refusal)
        with open(os.path.join(LIGHTING, 'time_air.py')) as fh:
            src = fh.read()
        for name in ('class Tailer', 'def launch_env', 'def check_autocmd', 'def run_once',
                     'def structure_path', 'def summarise_run', 'def frame_times'):
            self.assertNotIn(name, src)

    def testConfigMatrix(self):
        tags = [c.tag for c in self.t.configs()]
        want = []
        for s in ('1rx1', '1ao6', '7k00'):
            want += ['%s_s3' % s, '%s_s3_air' % s, '%s_s0_air' % s]
            if s != '1ao6':
                want += ['%s_s3_air_half' % s, '%s_s3_air_f9' % s]
        self.assertEqual(tags, want)
        V = self.t.VARIANTS
        self.assertEqual(V['s3'], (3, None, None, None))
        self.assertEqual(V['s3_air'][1:], (self.t.AIR, 1, 1))
        self.assertEqual(V['s0_air'][0], 0)
        self.assertEqual(V['s3_air_half'][2:], (2, 1))
        self.assertEqual(V['s3_air_f9'][2:], (1, 2))
        self.assertEqual(self.t.AIR, {'haze': 0.3, 'dust': 0.5, 'dust_size': 0.35,
                                      'dust_speed': 1.0, 'scatter': 0.55, 'seed': 7})
        with self.assertRaises(self.t.Refusal):
            self.t.AirConfig('1rx1', 'bogus')

    def write(self, name, text):
        path = os.path.join(self.tmp, name)
        with open(path, 'w') as fh:
            fh.write(text)
        return path

    def testExportScriptIsTimeShadowsPlusAir(self):
        t = self.t
        mp4 = os.path.join(self.tmp, 'x.mp4')
        start = os.path.join(self.tmp, 'x.start.json')
        base = t.ts.script_text(self.render, t.ts.Config('1rx1', 's3'), PDB, mp4, start, 4)
        same = t.script_text(self.render, t.AirConfig('1rx1', 's3'), PDB, mp4, start, 4)
        # s3 is time_shadows' own script (only the header line differs)
        self.assertEqual(base.split('\n')[1:], same.split('\n')[1:])
        text = t.script_text(self.render, t.AirConfig('1rx1', 's3_air_f9'), PDB, mp4, start, 4)
        self.assertIn("    rig['air'] = %r\n" % (t.AIR,), text)
        self.assertIn("cmd.set('metal_light_air_resolution', 1)", text)
        self.assertIn("cmd.set('metal_light_air_shadow_filter', 2)", text)
        self.assertNotIn('metal_light_air_time', text)          # the movie clock
        self.assertLess(text.index("rig['air']"), text.index('cmd.set_lights(rig)'))
        # the run-2 guard and the export, unchanged
        self.assertIn('if cmd._ts_runs == 2:', text)
        self.assertIn("ray=1", text)
        self.assertIn("'tag': '1rx1_s3_air_f9'", text)

    def testExportQueuedOncePerProcess(self):
        t = self.t
        mp4 = os.path.join(self.tmp, 'x.mp4')
        start = os.path.join(self.tmp, 'x.start.json')
        script = self.write('x.py', t.script_text(self.render, t.AirConfig('1rx1', 's3_air_half'),
                                                  PDB, mp4, start, 4))
        calls = []
        original = cmd.movie_export
        cmd.movie_export = lambda *a, **k: calls.append((a, k))
        try:
            cmd.run(script)                   # at launch: nothing
            self.assertEqual(calls, [])
            cmd.run(script)                   # PYMOL_AUTOEXPORT's run: the export
            cmd.run(script)                   # later runs: nothing
        finally:
            cmd.movie_export = original
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0], ((mp4, 1920, 1080), {'quality': 'standard', 'ray': 1}))
        with open(start) as fh:
            self.assertEqual(json.load(fh)['tag'], '1rx1_s3_air_half')
        rig = cmd.get_lights()
        self.assertEqual([l['shadow'] for l in rig['lights']], [True, True, True])
        self.assertAlmostEqual(rig['air']['haze'], 0.3, places=6)
        self.assertEqual(cmd.get_setting_int('metal_light_air_resolution'), 2)
        self.assertEqual(cmd.get_setting_int('metal_light_air_shadow_filter'), 1)
        self.assertEqual(cmd.get_setting_int('metal_raytrace'), 1)
        # export frame N gets dust time (N - 1) / movie_fps: the movie clock
        cmd.frame(3)
        frame = lighting._light_air_frame(offscreen=True)
        self.assertEqual(frame['time'], f32(2.0 / cmd.get_setting_float('movie_fps')))

    def testAutocmdAndProbe(self):
        t = self.t
        script = os.path.join(self.tmp, 'w', '1rx1_s3_air_r1.py')
        probe = os.path.join(self.tmp, 'w', 'p.png')
        env = t.ts.launch_env(script, os.path.join(self.tmp, 't.timing'), probe)
        self.assertIn('PYMOL_AUTOEXPORT=%s,64,64,0' % probe, env)
        self.assertIn('PYMOL_AUTOCMD=run %s' % script, env)
        for bad in ('run a.py; run b.py', 'run /x/orient/a.py', 'run /x/reset.py'):
            with self.assertRaises(t.Refusal):
                t.ts.check_autocmd(bad)

    def testSummaryTableAndFlags(self):
        t = self.t
        C = t.AirConfig

        def runs(*s):
            return [{'s_per_frame': v, 's_per_frame_mp4': v,
                     'gpu_ms_median': None if v is None else 10.0 * v} for v in s]
        results = {
            '7k00_s3': {'config': C('7k00', 's3'), 'runs': runs(2.0, 2.2, 1.8), 'atoms': 150000},
            '7k00_s3_air': {'config': C('7k00', 's3_air'), 'runs': runs(2.2), 'atoms': 150000},
            '7k00_s3_air_f9': {'config': C('7k00', 's3_air_f9'), 'runs': runs(2.75),
                               'atoms': 150000},
            '7k00_s0_air': {'config': C('7k00', 's0_air'), 'runs': runs(None), 'atoms': None},
        }
        s = t.summarise(results)
        self.assertIsNone(s['7k00_s3']['delta_vs_s3'])
        self.assertAlmostEqual(s['7k00_s3_air']['delta_vs_s3'], 0.1)
        self.assertAlmostEqual(s['7k00_s3_air_f9']['delta_vs_s3'], 0.375)
        self.assertIsNone(s['7k00_s0_air']['delta_vs_s3'])
        text = t.table(s, ['7k00_s3', '7k00_s3_air', '7k00_s3_air_f9', '7k00_s0_air'])
        lines = text.strip().split('\n')
        self.assertIn('| vs s3 |', lines[0])
        self.assertNotIn('vs s0', text)
        self.assertEqual(lines[3], '| 7k00 | 150000 | s3_air | default | 2.200 | 2.200 | '
                                   '22.0 | +10.0% |')
        notes = t.flags(s)
        self.assertEqual(notes[0], 'FLAG 7k00_s3_air_f9: +37.5% s/frame over s3 (> +25%)')
        self.assertEqual(notes[1], 'Q1 7k00: 3x3 haze lookup +25.0% s/frame against the one tap')
        self.assertEqual(len(notes), 2)

    def testIdleParsing(self):
        t = self.t
        self.assertEqual(t.parse_frames('726383001 frames/s=29.8 gpu_ms/frame=3.10 gpu_busy=9%'),
                         29.8)
        self.assertIsNone(t.parse_frames('offscreen 1920x1080 gpu_ms=3.00'))
        self.assertIsNone(t.parse_frames('RendererMetal: gpu_ms frame=3.0'))
        stamped = [(10.0, '1 frames/s=60.0 gpu_ms/frame=1'), (21.0, '2 frames/s=30.0 x'),
                   (23.0, '3 frames/s=28.0 x'), (40.0, '4 frames/s=1.0 x'),
                   (22.0, 'offscreen 64x64 gpu_ms=1.00')]
        r = t.idle_summary(stamped, 20.0, 30.0, [1.0, 3.0])
        self.assertEqual((r['fps'], r['lines'], r['cpu'], r['cpu_samples']), (29.0, 2, 2.0, 2))
        # no line in the window reads as 0 frames/s
        r = t.idle_summary(stamped, 24.0, 30.0, [])
        self.assertEqual((r['fps'], r['lines'], r['cpu']), (0.0, 0, None))

    def testIdleVerdict(self):
        t = self.t

        def row(fps, cpu):
            return {'fps': fps, 'lines': 1, 'cpu': cpu, 'cpu_samples': 10}
        rows = {c: row(0.0, 2.0) for c in t.IDLE_CONFIGS}
        rows['dust'] = row(29.5, 15.0)
        self.assertEqual(t.idle_verdict(rows), (0, []))
        # a still configuration that keeps drawing, or burns CPU
        bad = dict(rows, haze=row(12.0, 2.0))
        self.assertEqual(t.idle_verdict(bad)[0], 1)
        bad = dict(rows, dust_pinned=row(0.0, 6.0))
        self.assertEqual(t.idle_verdict(bad)[0], 1)
        # the moving dust above the cap, or not moving at all (inconclusive)
        self.assertEqual(t.idle_verdict(dict(rows, dust=row(60.0, 20.0)))[0], 1)
        rc, notes = t.idle_verdict(dict(rows, dust=row(0.0, 2.0)))
        self.assertEqual(rc, 3)
        self.assertIn('INCONCLUSIVE', notes[-1])
        # a real failure is never reported as inconclusive
        self.assertEqual(t.idle_verdict(dict(rows, haze=row(5.0, 2.0),
                                             dust=row(0.0, 2.0)))[0], 1)
        self.assertEqual(t.IDLE_FPS, 0.5)
        self.assertEqual(t.CPU_TOL, 3.0)
        self.assertEqual(t.DUST_FPS, (20.0, 31.0))
        text = t.idle_table(rows)
        self.assertEqual(text.count('\n'), 2 + len(t.IDLE_CONFIGS))

    def testIdleScriptsInProcess(self):
        t = self.t
        want = {'norig': None, 'rig_noair': (0.0, 0.0, 1.0, -1.0),
                'haze': (0.3, 0.0, 1.0, -1.0), 'dust_speed0': (0.3, 0.5, 0.0, -1.0),
                'dust_pinned': (0.3, 0.5, 1.0, 1.0), 'dust': (0.3, 0.5, 1.0, -1.0)}
        for config in t.IDLE_CONFIGS:
            script = self.write('idle_%s.py' % config,
                                t.idle_script_text(self.render, config, PDB))
            for _ in range(2):                    # every AUTOCMD run re-applies it
                cmd.run(script)
            rig = cmd.get_lights()
            if want[config] is None:
                self.assertIsNone(rig)
                continue
            haze, dust, speed, pin = want[config]
            self.assertIs(rig['enabled'], True, config)
            self.assertAlmostEqual(rig['air']['haze'], haze, places=6, msg=config)
            self.assertAlmostEqual(rig['air']['dust'], dust, places=6, msg=config)
            self.assertAlmostEqual(rig['air']['dust_speed'], speed, places=6, msg=config)
            self.assertAlmostEqual(cmd.get_setting_float('metal_light_air_time'), pin, places=6)
            self.assertEqual(cmd.get_setting_int('metal_raytrace'), 0)
            # only the moving dust asks the app for redraws
            self.assertIs(lighting._light_air_animating(), config == 'dust', config)

    def testMovieScriptsInProcess(self):
        t = self.t
        folder = os.path.join(self.tmp, 'export_a')
        start = os.path.join(self.tmp, 'a.start.json')
        script = self.write('movie_a.py', t.movie_export_script(self.render, PDB, folder, start))
        calls = []
        original = cmd.movie_export
        cmd.movie_export = lambda *a, **k: calls.append((a, k))
        try:
            for _ in range(3):
                cmd.run(script)
        finally:
            cmd.movie_export = original
        self.assertEqual(calls, [((folder, 640, 360), {'quality': 'standard', 'format': 'png',
                                                       'ray': 1})])
        self.assertEqual(cmd.count_frames(), 4)
        self.assertEqual(cmd.get_setting_float('movie_fps'), 30.0)
        self.assertAlmostEqual(cmd.get_setting_float('metal_light_air_time'), -1.0)
        rig = cmd.get_lights()
        self.assertAlmostEqual(rig['air']['dust'], 0.8, places=6)
        self.assertEqual([l['shadow'] for l in rig['lights']], [True])
        export_times = []
        for k in range(1, 5):
            cmd.frame(k)
            export_times.append(lighting._light_air_frame(offscreen=True)['time'])
        self.assertEqual(export_times, [f32((k - 1) / 30.0) for k in range(1, 5)])
        # still k: the same frame with the clock pinned to (k - 1) / 30
        for k in range(1, 5):
            still = self.write('still_%d.py' % k, t.movie_still_script(self.render, PDB, k))
            cmd.run(still)
            self.assertEqual(cmd.get_frame(), k)
            frame = lighting._light_air_frame(offscreen=True)
            self.assertEqual(frame['time'], export_times[k - 1], k)
            self.assertAlmostEqual(cmd.get_setting_float('metal_light_air_time'),
                                   (k - 1) / 30.0, places=6)

    @unittest.skipUnless(HAVE_PIXELS, 'needs numpy and Pillow')
    def testMovieCompare(self):
        t = self.t
        frames = []
        for k in range(4):
            a = numpy.zeros((20, 30, 3), dtype=numpy.int32)
            a[k * 4:k * 4 + 8, :10] = 200          # the motes move each frame
            frames.append(a)
        stills = [f.copy() for f in frames]
        stills[2][0, 0] += 2                       # within the tolerance
        res = t.movie_compare(frames, [f.copy() for f in frames], stills)
        self.assertTrue(all(ok for _, ok, _ in res), res)
        self.assertEqual([n for n, _, _ in res],
                         ['repeatable', 'moves', 'still_1', 'still_2', 'still_3', 'still_4'])
        # the second export differs
        other = [f.copy() for f in frames]
        other[1][5, 5] += 1
        self.assertFalse(dict((n, ok) for n, ok, _ in t.movie_compare(frames, other, stills))
                         ['repeatable'])
        # the dust stands still (wall time, or no time at all)
        still_dust = [frames[0].copy() for _ in range(4)]
        self.assertFalse(dict((n, ok) for n, ok, _ in
                              t.movie_compare(still_dust, still_dust, stills))['moves'])
        # frame 2 is nearest to still 3: the clock is off by a frame
        shifted = [stills[0], stills[2], stills[1], stills[3]]
        res = dict((n, ok) for n, ok, _ in t.movie_compare(frames, frames, shifted))
        self.assertFalse(res['still_2'])
        self.assertTrue(res['still_1'])
        # a missing frame fails
        self.assertFalse(t.movie_compare(frames[:3], frames, stills)[0][1])

    def testDryRuns(self):
        t = self.t
        out = os.path.join(self.tmp, 'e')
        self.assertEqual(t.main(['--mode', 'export', '--out', out, '--dry-run', '--runs', '1',
                                 '--only', '1rx1_s3_air,7k00_s3_air_f9']), 0)
        self.assertEqual(sorted(os.listdir(os.path.join(out, '_work'))),
                         ['1rx1_s3_air_r1.py', '7k00_s3_air_f9_r1.py'])
        self.assertEqual(t.main(['--mode', 'export', '--out', out, '--dry-run',
                                 '--only', '1ao6_s3_air_half']), 2)      # not in the matrix
        self.assertEqual(t.main(['--mode', 'export', '--out', out]), 2)   # no --app
        out = os.path.join(self.tmp, 'i')
        self.assertEqual(t.main(['--mode', 'idle', '--out', out, '--dry-run']), 0)
        self.assertEqual(sorted(os.listdir(os.path.join(out, '_work'))),
                         sorted('idle_%s.py' % c for c in t.IDLE_CONFIGS))
        self.assertEqual(t.main(['--mode', 'idle', '--out', out, '--dry-run', '--only', 'x']), 2)
        out = os.path.join(self.tmp, 'm')
        self.assertEqual(t.main(['--mode', 'movie', '--out', out, '--dry-run']), 0)
        self.assertEqual(sorted(os.listdir(os.path.join(out, '_work'))),
                         ['movie_a.py', 'movie_b.py', 'still_1.py', 'still_2.py',
                          'still_3.py', 'still_4.py'])
        # paths the app would act on are refused
        self.assertEqual(t.main(['--mode', 'movie', '--dry-run', '--out',
                                 os.path.join(self.tmp, 'orient')]), 2)


if __name__ == '__main__':
    unittest.main()
