"""How each material takes a studio light: the render evidence (#615).

L2 for #615 renders scripts/lighting/scenes/lighting_615.json with the frozen
harness and decides with scripts/lighting/check_materials.py; the done-when
gallery is lighting_615_gallery.json; byte identity on the paths L1 does not
draw is lighting_615_default.json, rendered on master and on the branch. CI
has no GPU, so this pins what it can:

* check_materials.py's decisions on synthetic images: a pass and a fail for
  every check (nohighlight and knobs_dark exact), the negative control, the
  l2 plan (it names only tags lighting_615.json defines, every check has its
  images, every other tag is listed for the eye), and the thresholds in force;
* the three scene files load with the frozen harness (render.scene_file_jobs);
* every scene script runs in-process twice (the way the app runs it), leaves
  the camera alone (the gallery: the L1 view turned y -25), installs the rig
  its tag names through the cmd._l615_rig shim of cmd.set_lights (white rig W
  and its variant's highlight, intensity, classic and shadow; the gallery's
  presets and air, with metal_light_air_time pinned through a guarded
  setter), sets the material, Custom knobs, base colour and environment its
  tag names, and the shim is restored afterwards;
* the default-path file pairs every none_ tag with an identical off_ tag,
  draws the default material in every rig_ tag, and uses nothing master
  lacks (it is rendered on master).

Source-reading, so skipped (not passed) outside a repo checkout, decided by
one file every checkout has; in a checkout the ticket's own files are
required, so renaming one fails instead of skipping. The pixel checks are
skipped without numpy or Pillow.

Runs on a RayMol build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/lighting_material_check.py
"""
import contextlib
import importlib.util
import io
import json
import math
import os
import re
import shutil
import struct
import tempfile
import unittest

from pymol import _cmd, cmd, lighting, setting, testing
from pymol.constants import repres

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), os.pardir,
                                     os.pardir, os.pardir))
LIGHTING = os.path.join(ROOT, 'scripts', 'lighting')
SCENES = os.path.join(LIGHTING, 'scenes')
PDB = os.path.join(ROOT, 'testing', 'data', '1rx1.pdb')
FILES = {
    'checks': os.path.join(SCENES, 'lighting_615.json'),
    'gallery': os.path.join(SCENES, 'lighting_615_gallery.json'),
    'default': os.path.join(SCENES, 'lighting_615_default.json'),
}
HAVE_CHECKOUT = os.path.isfile(os.path.join(ROOT, 'layerGraphics', 'metal',
                                            'RendererMetal.mm'))

try:
    import numpy
    import PIL.Image
    HAVE_PIXELS = True
except ImportError:
    HAVE_PIXELS = False

RIG_LINE = 'cmd._l615_rig = '


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


def restore_set_lights():
    """Undo the scene files' shim (what tearDown does)."""
    original = vars(cmd).pop('_l615_set', None)
    if original is not None:
        cmd.set_lights = original
    vars(cmd).pop('_l615_rig', None)


# --- the pixel checks on synthetic images -------------------------------------------

H, W = 72, 128
GEO = (slice(16, 56), slice(24, 104))       # the "molecule": 40 x 80 = 3200 pixels
SPOT = (slice(30, 34), slice(60, 66))       # a highlight: 24 pixels (0.75%)
SPOT2 = (slice(40, 48), slice(40, 50))      # a second one: 80 pixels
BROAD = (slice(16, 56), slice(24, 80))      # most of the geometry (70%)
RIM = (slice(16, 18), slice(24, 104))       # the top edge (5%)
LOBE = (slice(28, 44), slice(56, 76))       # a broad highlight: 320 pixels (10%)
SHEEN = (slice(16, 24), slice(24, 104))     # a grazing band: the top 8 rows (20%)


def img(value=0):
    return numpy.full((H, W, 3), value, dtype=numpy.int32)


def grey(level=100):
    out = img()
    out[GEO] = level
    return out


def plus(base, region, rgb):
    out = base.copy()
    out[region] = numpy.clip(out[region] + numpy.array(rgb), 0, 255)
    return out


def coloured(rgb):
    out = img()
    out[GEO] = rgb
    return out


@unittest.skipUnless(HAVE_CHECKOUT, 'needs a RayMol checkout (scripts/lighting)')
@unittest.skipUnless(HAVE_PIXELS, 'needs numpy and Pillow')
class TestChecks(testing.PyMOLTestCase):

    @classmethod
    def setUpClass(cls):
        assert_present(os.path.join(LIGHTING, 'check_materials.py'))
        cls.c = load_module('lighting_check_materials', 'check_materials.py')

    def setUp(self):
        super(TestChecks, self).setUp()
        self.tmp = tempfile.mkdtemp(prefix='l615c')
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def assertPass(self, r):
        self.assertTrue(r.ok, r)

    def assertFail(self, r):
        self.assertFalse(r.ok, r)

    def testThresholdsInForce(self):
        """The thresholds frozen on round 1 (plan section 9.4: tuned once by
        #613's half-margin rule, the measurements written beside each in
        check_materials.py; never re-tuned to make a later round pass)."""
        c = self.c
        self.assertEqual((c.CHANGE, c.HIGHLIGHT_MAX_DELTA, c.HIGHLIGHT_MIN_FRACTION,
                          c.HIGHLIGHT_MAX_FRACTION, c.NEVER_DARKER), (8, 13, 0.048, 0.72, -1))
        self.assertEqual((c.NEUTRAL_RED, c.NEUTRAL_MAX, c.MIN_PIXELS), (12, 3.0, 50))
        self.assertEqual((c.TINT_DROP, c.TINT_HUE, c.TINT_NEUTRAL), (0.35, 25.0, 0.14))
        self.assertEqual(c.TINT_BASE, (0.85, 0.45, 0.10))
        self.assertEqual((c.GLINT_MAX_FRACTION, c.GLINT_PEAK, c.GLINT_NEUTRAL), (0.63, 56, 6.0))
        self.assertEqual((c.DIFFUSE_TOLERANCE, c.DIFFUSE_LIT), (0.08, 4))
        self.assertEqual((c.WRAP_LIT, c.WRAP_MARGIN), (2, 0.006))
        self.assertEqual((c.SHEEN_MAX_DELTA, c.SHEEN_FRACTION), (36, 0.10))
        # the frozen block says so, and nothing is left marked provisional
        src = open(os.path.join(LIGHTING, 'check_materials.py')).read()
        self.assertIn('FROZEN', src)
        self.assertNotIn('provisional', src.lower())
        # the expected diffuse ratios follow plan 3.1 (#615 Q4)
        self.assertEqual(c.DIFFUSE_EXPECTED, {'plastic': 1.0, 'matte': 1.0, 'metallic': 0.79})
        self.assertAlmostEqual(c.DIFFUSE_EXPECTED['metallic'], 1.0 - 0.6 * 0.35, places=6)

    def testExactChecks(self):
        """nohighlight and knobs_dark are byte-equality: one level fails."""
        for func in (self.c.check_nohighlight, self.c.check_knobs_dark):
            a = grey()
            self.assertPass(func(a, a.copy()))
            b = a.copy()
            b[20, 30, 1] += 1
            self.assertFail(func(b, a))
            self.assertFail(func(a, img()[:10]))       # sizes differ

    def testHighlight(self):
        c = self.c
        off = grey()
        self.assertPass(c.check_highlight(plus(off, LOBE, (60, 60, 60)), off))
        self.assertFail(c.check_highlight(off, off.copy()))                 # none
        self.assertFail(c.check_highlight(plus(off, LOBE, (10, 10, 10)), off))   # too dim
        self.assertFail(c.check_highlight(plus(off, SPOT, (60, 60, 60)), off))   # too few pixels
        self.assertFail(c.check_highlight(plus(off, GEO, (60, 60, 60)), off))    # a diffuse
        darker = plus(plus(off, LOBE, (60, 60, 60)), SPOT2, (-5, -5, -5))
        self.assertFail(c.check_highlight(darker, off))                     # darker somewhere
        self.assertFail(c.check_highlight(img(), img()))                    # no geometry

    def testNeutral(self):
        c = self.c
        off = grey()
        self.assertPass(c.check_neutral(plus(off, SPOT2, (50, 50, 50)), off))
        self.assertPass(c.check_neutral(plus(off, SPOT2, (50, 50, 48)), off))
        self.assertFail(c.check_neutral(plus(off, SPOT2, (50, 50, 30)), off))   # warm
        self.assertFail(c.check_neutral(plus(off, SPOT, (50, 50, 50)), off))    # 24 pixels

    def testTint(self):
        c = self.c
        base = c.TINT_BASE
        off = coloured([int(255 * 0.3 * v) for v in base])
        white = plus(off, SPOT2, (40, 40, 40))
        hl = [40.0 * (1.0 + (v - 1.0) * 0.8) for v in base]      # mix(1, base, 0.8)
        tinted = plus(off, SPOT2, [int(round(v)) for v in hl])
        r = c.check_tint(white, off, tinted, off)
        self.assertPass(r)
        self.assertIn('drop', r.detail)
        # the negative control: the table's highlight as white as tint 0's
        self.assertFail(c.check_tint(white, off, white, off))
        # rule A's milder tint (0.35) does not drop enough under rule B's bar
        hl_a = [40.0 * (1.0 + (v - 1.0) * 0.35) for v in base]
        self.assertFail(c.check_tint(white, off, plus(off, SPOT2, [int(round(v)) for v in hl_a]),
                                     off))
        # tinted, but not toward the base's hue (magenta)
        self.assertFail(c.check_tint(white, off, plus(off, SPOT2, (40, 4, 20)), off))
        # t0 itself is not white
        self.assertFail(c.check_tint(tinted, off, tinted, off))
        # too few pixels
        self.assertFail(c.check_tint(plus(off, SPOT, (40, 40, 40)), off, tinted, off))

    def testTintControl(self):
        c = self.c
        off = coloured([200, 100, 20])
        self.assertPass(c.check_tint_control(plus(off, SPOT2, (40, 40, 40)), off))
        self.assertFail(c.check_tint_control(plus(off, SPOT2, (40, 25, 10)), off))
        self.assertFail(c.check_tint_control(off, off.copy()))

    def testGlints(self):
        c = self.c
        off = grey(60)
        on = plus(plus(off, SPOT, (120, 120, 120)), SPOT2, (60, 60, 60))
        self.assertPass(c.check_glints(on, off))
        self.assertFail(c.check_glints(off, off.copy()))                         # none
        self.assertFail(c.check_glints(plus(off, BROAD, (60, 60, 60)), off))     # broad
        self.assertFail(c.check_glints(plus(off, SPOT2, (12, 12, 12)), off))     # not peaked
        self.assertFail(c.check_glints(plus(plus(off, SPOT, (120, 120, 120)), SPOT2,
                                            (60, 60, 20)), off))                 # coloured
        self.assertFail(c.check_glints(plus(on, RIM, (-4, -4, -4)), off))        # darker

    def testClassicGlints(self):
        c = self.c
        off = grey(10)
        on = plus(plus(off, SPOT, (120, 120, 120)), SPOT2, (60, 60, 60))
        self.assertPass(c.check_classic_glints(on, off))
        # master: classic does not reach glass's glints, the pair is byte-equal
        self.assertFail(c.check_classic_glints(off, off.copy()))
        # the body lit as well (not only glints)
        self.assertFail(c.check_classic_glints(plus(on, GEO, (30, 30, 30)), off))
        # warm glints are fine here (a classic light's colour is the scene's)
        self.assertPass(c.check_classic_glints(plus(plus(off, SPOT, (120, 110, 90)), SPOT2,
                                                    (60, 50, 40)), off))

    def testFrost(self):
        c = self.c
        off = grey(60)
        glass = plus(off, SPOT, (150, 150, 150))
        frosted = plus(plus(off, SPOT, (60, 60, 60)), SPOT2, (40, 40, 40))
        self.assertPass(c.check_frost(frosted, off, glass, off))
        self.assertFail(c.check_frost(glass, off, frosted, off))       # swapped
        brighter = plus(plus(off, SPOT, (180, 180, 180)), SPOT2, (40, 40, 40))
        self.assertFail(c.check_frost(brighter, off, glass, off))       # peaks higher

    def testDiffuse(self):
        c = self.c
        off = grey(10)
        default_on = plus(off, GEO, (100, 100, 100))
        metal_on = plus(off, GEO, (79, 79, 79))
        self.assertPass(c.check_diffuse(default_on, off, default_on, off))
        self.assertPass(c.check_diffuse(metal_on, off, default_on, off, expected=0.79))
        self.assertFail(c.check_diffuse(metal_on, off, default_on, off))
        self.assertFail(c.check_diffuse(default_on, off, default_on, off, expected=0.79))
        self.assertFail(c.check_diffuse(default_on, off, off, off.copy()))   # default unlit

    def testWrap(self):
        c = self.c
        off = grey(10)
        matte = plus(off, (slice(16, 56), slice(24, 70)), (40, 40, 40))
        wrapped = plus(off, (slice(16, 56), slice(24, 80)), (40, 40, 40))
        self.assertPass(c.check_wrap(wrapped, off, matte, off))
        self.assertFail(c.check_wrap(matte, off, matte, off))
        self.assertFail(c.check_wrap(matte, off, wrapped, off))

    def testSheenKept(self):
        c = self.c
        a = grey(30)
        self.assertPass(c.check_sheen_kept(plus(a, SHEEN, (40, 40, 40)), a))
        self.assertFail(c.check_sheen_kept(a, a.copy()))
        self.assertFail(c.check_sheen_kept(plus(a, SHEEN, (20, 20, 20)), a))    # too faint
        self.assertFail(c.check_sheen_kept(plus(a, RIM, (40, 40, 40)), a))      # too few pixels

    def testRowsEscapeBars(self):
        r = self.c.Result('highlight', 's', True, 'max |d| 3', group='default')
        self.assertEqual(r.row(), '| default | highlight | s | PASS | max \\|d\\| 3 |')

    # --- the plan -----------------------------------------------------------------

    def testPlanCoversEveryCheckAndGroup(self):
        plan = self.c.l2_plan()
        self.assertEqual(sorted({p[1] for p in plan}),
                         sorted(['nohighlight', 'highlight', 'neutral', 'tint', 'tint_control',
                                 'glints', 'frost', 'diffuse', 'wrap', 'classic_glints',
                                 'knobs_dark', 'sheen_kept']))
        self.assertEqual([g for g in self.c.GROUPS if g in {p[0] for p in plan}],
                         list(self.c.GROUPS))
        # every plan entry calls the check its name says
        for group, check, subject, func, tags, kwargs in plan:
            self.assertIs(func, self.c.SINGLE[check][0], (check, subject))
            self.assertEqual(len(tags), len(self.c.SINGLE[check][1]), (check, subject))
        # the families as plan section 9.4 lists them
        subjects = {(p[1], p[2]) for p in plan}
        for s in ('matte_surface_rt0', 'matte_sticks_rt0', 'matte_surface_rt1',
                  'matte_surface_sh_rt0', 'clay_surface_rt0', 'clay_spheres_rt0'):
            self.assertIn(('nohighlight', s), subjects)
        for s in ('default_surface_rt0', 'plastic_surface_rt0', 'metallic_surface_rt0',
                  'rubber_surface_rt0', 'jelly_surface_rt0', 'marble_surface_rt0',
                  'metallic_spheres_rt0', 'metallic_surface_rt1', 'metallic_surface_sh_rt0'):
            self.assertIn(('highlight', s), subjects)
        for s in ('glass_surface_rt0', 'glass_sticks_rt0', 'glass_surface_rt1',
                  'glass_surface_sh_rt0'):
            self.assertIn(('glints', s), subjects)
        self.assertIn(('frost', 'frosted_surface'), subjects)
        # the surface dots left glints and frost at the round-1 freeze (their
        # glints average away in the stacked OIT; see INFORMATIONAL)
        self.assertFalse([p for p in plan if 'dots' in p[2]])
        for tag in ('glass_dots_hi1_rt0', 'glass_dots_hi0_rt0', 'frosted_dots_hi1_rt0',
                    'frosted_dots_hi0_rt0'):
            self.assertIn(tag, self.c.INFORMATIONAL)
        for s in ('rubber_k3z_surface', 'jelly_k3z_surface'):
            self.assertIn(('knobs_dark', s), subjects)

    def testNegativePlan(self):
        neg = self.c.negative_plan()
        must_fail = sorted({p[1] for p, must_pass in neg if not must_pass})
        self.assertEqual(must_fail, ['classic_glints', 'knobs_dark', 'nohighlight', 'tint'])
        must_pass = sorted((p[1], p[2]) for p, must_pass in neg if must_pass)
        self.assertEqual(must_pass, [('highlight', 'default_surface_rt0'),
                                     ('sheen_kept', 'rubber_k4z_surface'),
                                     ('tint_control', 'default_surface'),
                                     ('tint_control', 'plastic_surface')])
        # every row of the plan with a must-fail check is in it
        self.assertEqual(len([p for p in self.c.l2_plan() if p[1] in self.c.NEGATIVE_FAIL]),
                         len([1 for _p, m in neg if not m]))

    def write(self, directory, tag, image):
        os.makedirs(directory, exist_ok=True)
        PIL.Image.fromarray(numpy.asarray(image, dtype=numpy.uint8)).save(
            os.path.join(directory, tag + '.png'))

    def negative_images(self, directory, master=True):
        """Synthetic renders of every negative-control tag: `master` gives
        every material the neutral response (the control's app), else #615's."""
        c = self.c
        off = grey(60)
        spot = plus(off, SPOT2, (50, 50, 50))
        base = [int(255 * 0.3 * v) for v in c.TINT_BASE]
        torange = coloured(base)
        twhite = plus(torange, SPOT2, (40, 40, 40))
        ttint = plus(torange, SPOT2, [int(round(40.0 * (1.0 + (v - 1.0) * 0.8)))
                                      for v in c.TINT_BASE])
        for (group, check, subject, func, tags, kw), must_pass in c.negative_plan():
            if check == 'nohighlight':
                imgs = [spot, off] if master else [off, off]
            elif check == 'knobs_dark':
                imgs = [plus(off, SPOT, (9, 9, 9)), off] if master else [off, off]
            elif check == 'classic_glints':
                imgs = [off, off] if master else [plus(off, SPOT2, (60, 60, 60)), off]
            elif check == 'tint':
                imgs = [twhite, torange, twhite if master else ttint, torange]
            elif check == 'tint_control':
                imgs = [twhite, torange]
            elif check == 'highlight':
                imgs = [plus(off, LOBE, (60, 60, 60)), off]
            elif check == 'sheen_kept':
                imgs = [plus(off, SHEEN, (40, 40, 40)), off]
            for tag, image in zip(tags, imgs):
                self.write(directory, tag, image)

    def testRunNegative(self):
        d = os.path.join(self.tmp, 'neg')
        self.negative_images(d, master=True)
        results = self.c.run_negative(d)
        self.assertTrue(results)
        self.assertTrue(all(r.ok for r in results), [r for r in results if not r.ok])
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(self.c.main(['negative', d]), 0)
        self.assertIn('must fail', out.getvalue())
        # with #615's response the control no longer fails: every must-fail row is flagged
        d2 = os.path.join(self.tmp, 'neg615')
        self.negative_images(d2, master=False)
        results = self.c.run_negative(d2)
        bad = sorted({r.check for r in results if not r.ok})
        self.assertEqual(bad, ['classic_glints', 'knobs_dark', 'nohighlight', 'tint'])
        # a missing image is never "as expected"
        os.remove(os.path.join(d, 'matte_surface_hi1_rt0.png'))
        self.assertFalse(all(r.ok for r in self.c.run_negative(d)))

    def testL2AndCli(self):
        c = self.c
        d = os.path.join(self.tmp, 'l2')
        off = grey(60)
        for p in c.l2_plan():
            if p[1] == 'nohighlight':
                for tag in p[4]:
                    self.write(d, tag, off)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(c.main(['l2', d, '--checks', 'nohighlight']), 0)
        rows = [l for l in out.getvalue().splitlines() if l.startswith('| procedural |')]
        self.assertEqual(len(rows), 6)
        # the other checks' images are missing: they fail, naming the file
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(c.main(['l2', d]), 1)
        results = c.run_plan(d, c.l2_plan())
        missing = [r for r in results if r.detail.startswith('missing')]
        self.assertEqual(len(missing), len(results) - 6)
        # one check alone, from files
        a = os.path.join(d, 'matte_surface_hi1_rt0.png')
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(c.main(['nohighlight', a, a]), 0)
            self.assertEqual(c.main(['diffuse', a, a, a, a, '--expect', '1']), 1)
        # usage errors
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(c.main(['l2', os.path.join(self.tmp, 'nowhere')]), 2)
            self.assertEqual(c.main(['l2', d, '--checks', 'sparkle']), 2)
            self.assertEqual(c.main(['nohighlight', a, os.path.join(d, 'none.png')]), 2)
            self.assertEqual(c.main([]), 2)


# --- the scene files ------------------------------------------------------------------

TAG_RE = re.compile(
    r'^(?:(?P<pre>tint|lobe)_)?(?P<mat>[a-z]+)(?:_(?P<knob>t0|tab|k3z|k4z))?'
    r'_(?P<rep>surface|sticks|spheres|dots)(?P<sh>_sh)?'
    r'(?:_(?P<var>hi1|hi0|dark_c1|dark|dim1|dim0|dimdark))?_rt(?P<rt>[01])$')
GALLERY_RE = re.compile(r'^g(?P<n>\d\d)_(?P<mat>[a-z_]+)__c(?P<k>\d)_(?P<setup>[a-z_]+)$')
DEFAULT_RE = re.compile(r'^(?P<pre>none|off|rig)_(?P<s>[a-z_]+?)_rt(?P<rt>[01])$')

MATERIALS = ('default', 'matte', 'plastic', 'metallic', 'glass', 'frosted_glass', 'jelly',
             'marble', 'clay', 'rubber')
TAG_MATERIAL = {'frosted': 'frosted_glass'}
REP_DRAW = {'surface': 'surface', 'dots': 'surface', 'sticks': 'sticks', 'spheres': 'spheres',
            'cartoon': 'cartoon', 'surfdots': 'surface'}
KNOB_PREFIX = {'surface': 'surface', 'dots': 'surface', 'sticks': 'stick', 'spheres': 'sphere'}
# rig W (plan 9.0): name, orbit, pitch, beam, its own intensity
RIG_W = (('key', -40.0, 30.0, 55.0, 1.0), ('fill', 55.0, 5.0, 80.0, 0.5),
         ('rim', 150.0, 25.0, 50.0, 0.8))
# variant -> (every intensity or None, every highlight, classic)
VARIANTS = {'hi1': (None, 1.0, 0.0), 'hi0': (None, 0.0, 0.0), 'dark': (0.0, 0.5, 0.0),
            'dark_c1': (0.0, 0.5, 1.0), 'dim1': (0.3, 0.5, 0.0), 'dim0': (0.3, 0.0, 0.0),
            'dimdark': (0.0, 0.0, 0.0)}
ORANGE = (0.85, 0.45, 0.10)
# The table's knobs the Custom-knob tags zero: rubber's Highlight (p[2]) and
# Sheen (p[3]), jelly's Wet highlight (p[2]).
TABLE_P = {'rubber': (0.14, 26.5, 0.17, 0.37), 'jelly': (2.2, 0.35, 1.1, 1.0)}
GALLERY_SETUPS = {
    # setup: (light names, ambient, haze, dust, air scatter)
    'softbox': (['left', 'right', 'top'], 0.16, 0.0, 0.0, 0.55),
    'three_point': (['key', 'fill', 'rim'], 0.10, 0.0, 0.0, 0.55),
    'spot_dust': (['spot', 'fill'], 0.04, 0.3, 0.6, 0.55),
    'redblue_dust': (['red', 'blue'], 0.03, 0.25, 0.7, 0.55),
    'backlit_haze': (['back', 'front'], 0.04, 0.12, 0.5, 0.55),
    'colour': (['left', 'right', 'top'], 0.16, 0.0, 0.0, 0.55),
}
# What master has not: the default-path file is rendered on master too.
NOT_ON_MASTER = ('material_light_response', 'classic_scale', 'setLightClassicScale',
                 '_l615_opt')


def material_ids():
    return {name: mid for mid, name in setting.get_material_names(1)}


def draw_params(rep):
    return _cmd.get_material_draw_params(cmd._COb, 'm', repres[REP_DRAW[rep]])


def atom_colour():
    colours = []
    cmd.iterate('m and polymer and name CA', 'colours.append(color)',
                space={'colours': colours})
    return cmd.get_color_tuple(colours[0])


@unittest.skipUnless(HAVE_CHECKOUT, 'needs a RayMol checkout (scripts/lighting)')
class TestSceneFiles(testing.PyMOLTestCase):

    @classmethod
    def setUpClass(cls):
        assert_present(os.path.join(LIGHTING, 'render.py'),
                       os.path.join(LIGHTING, 'check_materials.py'), PDB, *FILES.values())
        cls.render = load_module('lighting_render', 'render.py')
        cls.check = load_module('lighting_check_materials', 'check_materials.py')
        cls.jobs = {k: cls.render.scene_file_jobs(v) for k, v in FILES.items()}
        cls.specs = {}
        for k, v in FILES.items():
            with open(v) as handle:
                cls.specs[k] = json.load(handle)

    def setUp(self):
        super(TestSceneFiles, self).setUp()
        self.original = cmd.set_lights
        self.tmp = tempfile.mkdtemp(prefix='l615')
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def tearDown(self):
        restore_set_lights()
        cmd.set_lights(None)
        self.assertIs(cmd.set_lights, self.original)
        super(TestSceneFiles, self).tearDown()

    def run_job(self, job, times=2):
        out = os.path.join(self.tmp, 'out')
        self.render.write_scripts(ROOT, out, [job])
        marker = self.render.marker_path(out, job.tag)
        if os.path.exists(marker):
            os.remove(marker)
        for _ in range(times):
            cmd.run(self.render.script_path(out, job.tag))
        if times == 2:
            self.assertIsNone(self.render.check_marker(marker, job.tag, job.rig), job.tag)
        return marker

    def m_frame(self):
        mn, mx = cmd.get_extent('m')
        return ([(a + b) / 2.0 for a, b in zip(mn, mx)],
                math.sqrt(sum((b - a) ** 2 for a, b in zip(mn, mx))) / 2.0)

    def assertView(self, want, tag):
        for i, (got, w) in enumerate(zip(cmd.get_view(), want)):
            if i == 17:
                got, w = abs(got), abs(w)
            self.assertAlmostEqual(got, w, delta=1e-3,
                                   msg='%s moves the camera (view[%d])' % (tag, i))

    def assertFramed(self, rig, tag):
        centre, size = self.m_frame()
        for got, want in zip(rig['centre'], centre):
            self.assertAlmostEqual(got, want, delta=1e-4, msg=tag)
        self.assertAlmostEqual(rig['size'], size, delta=1e-4, msg=tag)

    def assertMaterial(self, rep, name, tag):
        params = draw_params(rep)
        self.assertEqual(params[1], material_ids()[name], '%s: %s' % (tag, params))
        return params

    def assertRigW(self, rig, variant, shadow, tag):
        intensity, highlight, classic = VARIANTS[variant]
        self.assertIs(rig['enabled'], True, tag)
        self.assertEqual((rig['ambient'], rig['classic']), (0.06, classic), tag)
        self.assertFramed(rig, tag)
        self.assertEqual([l['name'] for l in rig['lights']], [w[0] for w in RIG_W], tag)
        for light, (name, orbit, pitch, beam, own) in zip(rig['lights'], RIG_W):
            self.assertEqual((light['orbit'], light['pitch'], light['beam']),
                             (orbit, pitch, beam), tag)
            self.assertEqual((light['color'], light['warmth']), ([1.0, 1.0, 1.0], 6500.0), tag)
            self.assertEqual(light['intensity'], own if intensity is None else intensity, tag)
            self.assertEqual(light['highlight'], highlight, tag)
            self.assertIs(light['shadow'], bool(shadow and name == 'key'), tag)
        # white: every light's radiance has equal channels
        for light in lighting._light_frame()['rig']['lights']:
            r, g, b = light['radiance']
            self.assertTrue(r == g == b, tag)

    # --- the files ------------------------------------------------------------

    def testSceneFilesLoad(self):
        self.assertEqual({k: len(v) for k, v in self.jobs.items()},
                         {'checks': 79, 'gallery': 60, 'default': 71})
        sizes = {'checks': (1280, 720), 'gallery': (960, 540), 'default': (1280, 720)}
        for which, spec in self.specs.items():
            self.assertIsNone(spec['base'], which)
            self.assertIn('#615', spec['comment'])
            self.assertEqual(spec['rig'], 'none' if which == 'default' else 'on', which)
            for job in self.jobs[which]:
                self.assertEqual(job.size, sizes[which], job.tag)
                self.assertEqual(job.extra[:len(spec['extra'])], spec['extra'], job.tag)
                # every scene says which rig the shim installs, as its last line
                own = job.extra[len(spec['extra']):]
                self.assertEqual([l for l in own if l.startswith(RIG_LINE)], [own[-1]], job.tag)
                # the shim, guarded (the app runs each script twice)
                self.assertIn("if not hasattr(cmd, '_l615_set'): cmd._l615_set = cmd.set_lights",
                              spec['extra'], which)

    def testPlanNamesOnlyDefinedTags(self):
        tags = {j.tag for j in self.jobs['checks']}
        for p in self.check.l2_plan():
            for t in p[4]:
                self.assertIn(t, tags, (p[1], p[2]))
        need = set(self.check.plan_tags())
        self.assertEqual(sorted(tags - need - set(self.check.INFORMATIONAL)), [])
        self.assertEqual(sorted(set(self.check.INFORMATIONAL) - tags), [])
        for tag in tags:
            self.assertIsNotNone(TAG_RE.match(tag), tag)

    def testChecksFileCoversThePlan(self):
        tags = {j.tag for j in self.jobs['checks']}
        for mat in ('default', 'matte', 'plastic', 'metallic', 'glass', 'frosted', 'jelly',
                    'marble', 'clay', 'rubber'):
            for v in ('hi1', 'hi0'):
                self.assertIn('%s_surface_%s_rt0' % (mat, v), tags)
        for s in ('matte_sticks', 'clay_spheres', 'metallic_spheres', 'glass_sticks',
                  'jelly_spheres', 'glass_dots', 'frosted_dots'):
            for v in ('hi1', 'hi0'):
                self.assertIn('%s_%s_rt0' % (s, v), tags)
        for mat in ('matte', 'metallic', 'glass'):
            for v in ('hi1', 'hi0'):
                self.assertIn('%s_surface_%s_rt1' % (mat, v), tags)
                self.assertIn('%s_surface_sh_%s_rt0' % (mat, v), tags)
        for k in ('t0', 'tab'):
            for rep in ('surface', 'spheres'):
                for v in ('dim1', 'dim0'):
                    self.assertIn('tint_metallic_%s_%s_%s_rt0' % (k, rep, v), tags)
        for mat in ('default', 'plastic', 'metallic', 'matte', 'marble', 'jelly'):
            for v in ('dim0', 'dimdark'):
                self.assertIn('%s_surface_%s_rt0' % (mat, v), tags)

    def testEveryChecksScriptRunsInProcess(self):
        ran = 0
        for job in self.jobs['checks']:
            self.run_job(job)
            ran += 1
            tag = job.tag
            m = TAG_RE.match(tag)
            self.assertView(self.render.VIEW, tag)
            rt = int(m.group('rt'))
            self.assertEqual(cmd.get_setting_int('metal_raytrace'), rt, tag)
            self.assertEqual(cmd.get_setting_int('depth_cue'), 0, tag)
            sh = bool(m.group('sh'))
            self.assertEqual(cmd.get_setting_int('metal_shadows'), int(sh), tag)
            rep = m.group('rep')
            dots = rep == 'dots'
            self.assertEqual(cmd.get_setting_int('surface_type'), int(dots), tag)
            self.assertEqual(cmd.get_setting_int('dot_as_spheres'), int(dots), tag)
            name = TAG_MATERIAL.get(m.group('mat'), m.group('mat'))
            params = self.assertMaterial(rep, name, tag)
            # the subject's colour and environment
            pre, var, knob = m.group('pre'), m.group('var'), m.group('knob')
            want = cmd.get_color_tuple('l615_orange' if pre == 'tint' else 'grey80')
            if pre == 'tint':
                for got, w in zip(want, ORANGE):
                    self.assertAlmostEqual(got, w, delta=1e-6, msg=tag)
            for got, w in zip(atom_colour(), want):
                self.assertAlmostEqual(got, w, delta=1e-6, msg=tag)
            env = 1 if pre == 'lobe' else 2 if (pre == 'tint' or var in ('dim0', 'dimdark')) \
                else 0
            self.assertEqual(cmd.get_setting_int('material_env'), env, tag)
            # the Custom knobs
            if knob == 't0':
                self.assertEqual(params[3], 0.0, tag)
                self.assertEqual(cmd.get_setting_float('%s_material_tint' % KNOB_PREFIX[rep],
                                                       'm'), 0.0, tag)
            elif knob == 'tab' or (pre == 'tint' and name == 'metallic'):
                self.assertAlmostEqual(params[3], 0.35, places=6, msg=tag)
            if name in TABLE_P:
                p = list(TABLE_P[name])
                if knob == 'k3z':
                    p[2] = 0.0
                if knob == 'k4z':
                    p[3] = 0.0
                for got, w in zip(params[5], p):
                    self.assertAlmostEqual(got, w, places=5, msg=tag)
            # the rig
            rig = cmd.get_lights()
            if pre == 'lobe':
                self.assertEqual([l['name'] for l in rig['lights']], ['key'], tag)
                self.assertEqual((rig['lights'][0]['highlight'], rig['lights'][0]['intensity']),
                                 (1.0, 1.0), tag)
                self.assertFramed(rig, tag)
            else:
                self.assertRigW(rig, var, sh, tag)
            # never any air (rig W carries none)
            self.assertIsNone(lighting._light_air_frame(offscreen=True), tag)
            # the guard kept the real set_lights (no shim wrapping a shim)
            self.assertIs(cmd._l615_set, self.original, tag)
        self.assertEqual(ran, 79)

    def testClassicTagsDifferOnlyInTheirInput(self):
        """The classic pairs: every light dark, the same rig but for classic (glass)
        or the same rig and one Custom knob (rubber, jelly)."""
        jobs = {j.tag: j for j in self.jobs['checks']}
        self.run_job(jobs['glass_surface_dark_c1_rt0'])
        frame = lighting._light_frame()
        self.assertTrue(frame['rig_on'])
        self.assertEqual(frame['direct'], f32(cmd.get_setting_float('direct')))
        for light in frame['rig']['lights']:
            self.assertEqual(light['radiance'], [0.0, 0.0, 0.0])
        self.run_job(jobs['glass_surface_dark_rt0'])
        frame = lighting._light_frame()
        self.assertEqual((frame['direct'], frame['reflect'], frame['specular']), (0.0, 0.0, 0.0))
        a, b = (jobs['rubber_k3z_surface_dark_rt0'].extra, jobs['rubber_surface_dark_rt0'].extra)
        self.assertEqual([l for l in a if l not in b],
                         ["cmd.set('surface_material_knob3', 0.0, 'm')"])
        self.assertEqual([l for l in b if l not in a], [])

    def testGallery(self):
        presets = load_lighting_presets()
        view = self.gallery_view()
        rows = {}
        for job in self.jobs['gallery']:
            self.run_job(job)
            tag = job.tag
            m = GALLERY_RE.match(tag)
            self.assertIsNotNone(m, tag)
            n, mat, k, setup = int(m.group('n')), m.group('mat'), int(m.group('k')), \
                m.group('setup')
            rows.setdefault(n, set()).add(mat)
            self.assertEqual(MATERIALS[n], mat, tag)
            self.assertEqual(list(GALLERY_SETUPS).index(setup), k, tag)
            self.assertView(view, tag)
            self.assertEqual(cmd.get_setting_int('metal_raytrace'), 0, tag)
            self.assertEqual(cmd.get_setting_int('material_env'), 1, tag)
            self.assertEqual(cmd.get_setting_int('depth_cue'), 0, tag)
            self.assertEqual(cmd.get_setting_int('metal_shadows'), 1, tag)
            self.assertMaterial('surface', mat, tag)
            self.assertEqual(cmd.count_atoms('m and inorganic'), 0, tag)
            self.assertGreater(cmd.count_atoms('m and resn NAP'), 0, tag)
            if setup == 'colour':
                # the surface takes the atoms' spectrum colours
                self.assertEqual(cmd.get_setting_int('surface_color', 'm'), -1, tag)
            else:
                self.assertEqual(cmd.get('surface_color', 'm'), 'grey85', tag)
            names, ambient, haze, dust, scatter = GALLERY_SETUPS[setup]
            rig = cmd.get_lights()
            self.assertIs(rig['enabled'], True, tag)
            self.assertFramed(rig, tag)
            self.assertEqual([l['name'] for l in rig['lights']], names, tag)
            self.assertAlmostEqual(rig['ambient'], ambient, places=6, msg=tag)
            self.assertEqual(rig['classic'], 0.0, tag)
            self.assertAlmostEqual(rig['air']['haze'], haze, places=6, msg=tag)
            self.assertAlmostEqual(rig['air']['dust'], dust, places=6, msg=tag)
            self.assertAlmostEqual(rig['air']['scatter'], scatter, places=6, msg=tag)
            self.assertEqual(rig['air']['seed'], 7, tag)
            if setup in presets:
                self.assertPreset(rig, presets[setup], tag)
            # the dust clock: pinned at 2.0 s through the guarded setter
            self.assertAlmostEqual(cmd.get_setting_float('metal_light_air_time'), 2.0,
                                   places=6, msg=tag)
            air = lighting._light_air_frame(offscreen=True)
            if haze or dust:
                self.assertIsNotNone(air, tag)
                self.assertEqual(air['time'], f32(2.0), tag)
            else:
                self.assertIsNone(air, tag)
        self.assertEqual(sorted(rows), list(range(10)))
        self.assertTrue(all(len(v) == 1 for v in rows.values()))

    def assertPreset(self, rig, preset, tag):
        ambient, lights = preset
        self.assertAlmostEqual(rig['ambient'], ambient, places=6, msg=tag)
        self.assertEqual(len(rig['lights']), len(lights), tag)
        for got, want in zip(rig['lights'], lights):
            for key, value in want.items():
                msg = '%s: %s.%s' % (tag, want['name'], key)
                if isinstance(value, float):
                    self.assertAlmostEqual(got[key], value, places=6, msg=msg)
                else:
                    self.assertEqual(got[key], value, msg)

    def gallery_view(self):
        cmd.set_view(self.render.VIEW, animate=0)
        cmd.turn('y', -25)
        return cmd.get_view()

    def testGalleryPresetFallback(self):
        """Without the lights command the gallery writes the presets out: the
        same lights as the command's presets."""
        presets = load_lighting_presets()
        jobs = {j.tag: j for j in self.jobs['gallery']}
        saved = cmd.keyword.pop('lights')
        try:
            for tag, setup in (('g01_matte__c0_softbox', 'softbox'),
                               ('g01_matte__c1_three_point', 'three_point')):
                self.run_job(jobs[tag])
                self.assertPreset(cmd.get_lights(), presets[setup], tag)
        finally:
            cmd.keyword['lights'] = saved

    def testGalleryAirSettingGuarded(self):
        spec = self.specs['gallery']
        lines = list(spec['extra']) + [l for s in spec['scenes'] for l in s['lines']]
        for line in lines:
            for mt in re.finditer('metal_light_air_', line):
                self.assertTrue(line[:mt.start()].endswith("_l615_opt('"), line)
        self.assertIn("_l615_opt('metal_light_air_time', 2.0)", spec['extra'])
        self.assertIn("_l615_opt = lambda name, value: cmd.set(name, value) if name in "
                      "cmd.setting.get_name_list() else None", spec['extra'])

    # --- the default-path file --------------------------------------------------------

    def testDefaultFilePairs(self):
        jobs = {j.tag: j for j in self.jobs['default']}
        none = sorted(t for t in jobs if t.startswith('none_'))
        self.assertEqual(len(none), 25)
        for tag in none:
            twin = 'off_' + tag[len('none_'):]
            self.assertIn(twin, jobs)
            self.assertEqual((jobs[tag].rig, jobs[twin].rig), ('none', 'off'))
            # identical but for the rig
            self.assertEqual(jobs[tag].extra, jobs[twin].extra, tag)
            self.assertEqual(jobs[tag].rep_lines, jobs[twin].rep_lines, tag)
            self.assertEqual((jobs[tag].rt, jobs[twin].rt), (jobs[twin].rt, jobs[tag].rt))
        subjects = {t[len('none_'):] for t in none}
        for s in ('surface_%s_rt0' % m for m in ('matte', 'clay', 'rubber', 'marble', 'plastic',
                                                'metallic', 'glass', 'frosted', 'jelly')):
            self.assertIn(s, subjects)
        for s in ('surfdots_glass_rt0', 'surfdots_glass_rt1', 'surfdots_frosted_rt0',
                  'surfdots_frosted_rt1', 'surface_metallic_rt1', 'surface_glass_rt1',
                  'surface_jelly_rt1'):
            self.assertIn(s, subjects)
        rig = sorted(t for t in jobs if t.startswith('rig_'))
        self.assertEqual(len(rig), 21)
        for t in ('rig_cartoon_rt0', 'rig_surface_rt1', 'rig_sticks_rt0', 'rig_spheres_rt1',
                  'rig_transparent_rt0', 'rig_meshcyl_rt0', 'rig_tube_rt0', 'rig_tube_rt1',
                  'rig_cartoon_ortho_rt0', 'rig_surface_sh_rt0', 'rig_spheres_sh_rt0',
                  'rig_sticks_sh_rt0', 'rig_transparent_sh_rt0', 'rig_surfdots_rt0',
                  'rig_surfdots_rt1'):
            self.assertIn(t, rig)
            self.assertEqual(jobs[t].rig, 'on', t)

    def testDefaultFileRunsOnMaster(self):
        spec = self.specs['default']
        text = json.dumps(spec['extra']) + json.dumps([s['lines'] for s in spec['scenes']])
        for name in NOT_ON_MASTER:
            self.assertNotIn(name, text)

    def testEveryDefaultScriptRunsInProcess(self):
        for job in self.jobs['default']:
            self.run_job(job)
            tag = job.tag
            m = DEFAULT_RE.match(tag)
            self.assertIsNotNone(m, tag)
            pre, s, rt = m.group('pre'), m.group('s'), int(m.group('rt'))
            self.assertEqual(cmd.get_setting_int('metal_raytrace'), rt, tag)
            self.assertEqual(cmd.get_setting_int('orthoscopic'), int('ortho' in s), tag)
            self.assertView(self.render.VIEW, tag)
            rig = cmd.get_lights()
            if pre == 'none':
                self.assertIsNone(rig, tag)
            elif pre == 'off':
                self.assertIs(rig['enabled'], False, tag)
            else:
                sh = s.endswith('_sh')
                self.assertRigW(rig, 'hi1', sh, tag)
                self.assertEqual(cmd.get_setting_int('metal_shadows'), int(sh), tag)
            if pre in ('none', 'off'):
                rep, mat = s.split('_', 1)
                name = TAG_MATERIAL.get(mat, mat)
                self.assertMaterial(rep, name, tag)
                dots = rep == 'surfdots'
                self.assertEqual(cmd.get_setting_int('surface_type'), int(dots), tag)
                self.assertEqual(cmd.get_setting_int('dot_as_spheres'), int(dots), tag)
            else:
                # the default material on every representation
                for rep in ('cartoon', 'surface', 'sticks', 'spheres'):
                    self.assertEqual(draw_params(rep)[0], 0, '%s %s' % (tag, rep))
                if s.startswith('tube'):
                    self.assertIn('tube', cmd.get_names('objects'))
                if s.startswith('meshcyl'):
                    self.assertEqual(cmd.get_setting_int('mesh_as_cylinders'), 1, tag)
                if s.startswith('surfdots'):
                    self.assertEqual(cmd.get_setting_int('surface_type'), 1, tag)
            restore_set_lights()


def load_lighting_presets():
    """{setup: (ambient, [light fields])} from the lights command's presets
    (#612), so the gallery's written-out copies are checked against them."""
    from pymol import lighting_commands
    out = {}
    for setup, name in (('softbox', 'softbox'), ('three_point', 'three_point'),
                        ('colour', 'softbox')):
        _desc, ambient, lights = lighting_commands.PRESETS[name]
        out[setup] = (ambient, lights)
    return out
