"""Per-light shadow map evidence (#616): scene files, pixel checks, L6 harness.

L2 for #616 renders scripts/lighting/scenes/lighting_616*.json with the frozen
harness and decides with scripts/lighting/check_shadows.py; L6 times movie
exports with scripts/lighting/time_shadows.py (the orchestrator runs it). CI
has no GPU, so this pins what it can:

* check_shadows.py's decisions on synthetic images: a pass and a fail for
  every check, the least-squares decomposition, and the run plan (a missing
  image fails, an informational one never does);
* the three scene files load with the frozen harness and name every image a
  check reads; every scene script runs in-process (the way the app runs it,
  twice), leaves the camera alone and installs the rig its tag says, framed
  explicitly on m (so no backdrop or caster CGO moves the lights), through
  the cmd.set_lights shim, which is restored afterwards;
* the scene geometry the checks rely on: the gizmo, blob and slab CGOs lie
  outside the view, halfway between their light and the rig centre; the
  backdrop lies behind every atom and inside the slab;
* time_shadows.py: the configuration matrix, the generated scripts (the
  export queued once per process) and AUTOCMD text, the stamped-line
  parsing, the s/frame arithmetic and the markdown table.

Source-reading, so skipped (not passed) outside a repo checkout, decided by
one file every checkout has; in a checkout the ticket's own files are
required, so renaming one fails instead of skipping. The pixel checks are
skipped without numpy or Pillow.

Runs on a RayMol build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/lighting_shadow_check.py
"""
import importlib.util
import itertools
import json
import math
import os
import re
import shutil
import tempfile
import unittest

from pymol import cmd, lighting, metal_pick, testing

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), os.pardir,
                                     os.pardir, os.pardir))
LIGHTING = os.path.join(ROOT, 'scripts', 'lighting')
SCENES = os.path.join(LIGHTING, 'scenes')
PDB = os.path.join(ROOT, 'testing', 'data', '1rx1.pdb')
FILES = {
    'l2': os.path.join(SCENES, 'lighting_616.json'),
    'grid': os.path.join(SCENES, 'lighting_616_grid.json'),
    'noshadow': os.path.join(SCENES, 'lighting_616_noshadow.json'),
}
HAVE_CHECKOUT = os.path.isfile(os.path.join(ROOT, 'layerGraphics', 'metal',
                                            'RendererMetal.mm'))

try:
    import numpy
    import PIL.Image
    HAVE_PIXELS = True
except ImportError:
    HAVE_PIXELS = False

RIG_LINE = 'cmd._l616_rig = '


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
    original = vars(cmd).pop('_l616_set', None)
    if original is not None:
        cmd.set_lights = original
    vars(cmd).pop('_l616_rig', None)


# --- the pixel checks on synthetic images -------------------------------------------

AMBER = (100.0, 55.0, 15.0)     # each light's contribution on a grey80 pixel
CYAN = (15.0, 75.0, 100.0)
DARK = 10


def img(h=60, w=80, value=DARK):
    return numpy.full((h, w, 3), value, dtype=numpy.int32)


def region(mask_shape, y0, y1, x0, x1):
    m = numpy.zeros(mask_shape, dtype=bool)
    m[y0:y1, x0:x1] = True
    return m


def lit(base, colour, mask=None, scale=1.0):
    """base plus `colour` x scale where mask (everywhere when None)."""
    out = base.astype(numpy.float64).copy()
    add = numpy.array(colour) * scale
    if mask is None:
        out += add
    else:
        out[mask] += add
    return numpy.rint(out).astype(numpy.int32)


def coloured_set():
    """dark, aonly, bonly, none, a, b, ab with A's shadow in one rectangle and
    B's in another (overlapping a little), each light's term exactly removed
    in its own shadow."""
    dark = img()
    shape = dark.shape[:2]
    sa = region(shape, 5, 25, 5, 35)          # A's shadow
    sb = region(shape, 20, 45, 30, 70)        # B's shadow
    aonly = lit(dark, AMBER)
    bonly = lit(dark, CYAN)
    none = lit(aonly, CYAN)
    a = lit(lit(dark, AMBER, ~sa), CYAN)
    b = lit(lit(dark, AMBER), CYAN, ~sb)
    ab = lit(lit(dark, AMBER, ~sa), CYAN, ~sb)
    return dict(dark=dark, aonly=aonly, bonly=bonly, none=none, a=a, b=b, ab=ab,
                sa=sa, sb=sb)


def whole_pixel(image, mask, factor=0.5):
    """The classic whole-pixel shadow: every channel of the pixel scaled."""
    out = image.astype(numpy.float64).copy()
    out[mask] *= factor
    return numpy.rint(out).astype(numpy.int32)


@unittest.skipUnless(HAVE_CHECKOUT, 'needs a RayMol checkout (scripts/lighting)')
@unittest.skipUnless(HAVE_PIXELS, 'needs numpy and Pillow')
class TestChecks(testing.PyMOLTestCase):

    @classmethod
    def setUpClass(cls):
        assert_present(os.path.join(LIGHTING, 'check_shadows.py'))
        cls.c = load_module('lighting_check_shadows', 'check_shadows.py')

    def setUp(self):
        super(TestChecks, self).setUp()
        self.s = coloured_set()

    def testDecompositionRecoversVisibility(self):
        s = self.s
        dec = self.c.Decomposition(s['dark'], s['aonly'], s['bonly'], s['ab'])
        self.assertTrue(dec.both.all())
        va, vb = dec.vA, dec.vB
        self.assertLess(abs(va[s['sa']]).max(), 0.02)
        self.assertLess(abs(va[~s['sa']] - 1.0).max(), 0.02)
        self.assertLess(abs(vb[s['sb']]).max(), 0.02)
        self.assertLess(abs(vb[~s['sb']] - 1.0).max(), 0.02)
        self.assertLessEqual(dec.residual_p95(), 1.0)
        # a light that reaches nowhere is NaN there, not 0
        dec = self.c.Decomposition(s['dark'], s['aonly'], s['dark'], s['a'])
        self.assertTrue(numpy.isnan(dec.vB).all())
        self.assertFalse(numpy.isnan(dec.vA).any())

    def testColoured(self):
        s = self.s
        r = self.c.check_coloured(s['dark'], s['aonly'], s['bonly'], s['a'], s['b'], s['ab'])
        self.assertTrue(r.ok, r)
        # the whole-pixel shadow (one shadow taking both lights) has no
        # coloured shadow at all: today's renderer, the negative control
        wp = whole_pixel(s['none'], s['sa'] | s['sb'])
        r = self.c.check_coloured(s['dark'], s['aonly'], s['bonly'], wp, wp, wp)
        self.assertFalse(r.ok, r)
        # the shadows swapped: A's region lit by A, not by B's colour
        r = self.c.check_coloured(s['dark'], s['aonly'], s['bonly'], s['a'], s['b'], s['none'])
        self.assertFalse(r.ok, r)

    def testColouredResidual(self):
        s = self.s
        noisy = s['ab'].copy()
        rng = numpy.random.RandomState(616)
        noisy += rng.randint(-20, 21, size=noisy.shape)
        r = self.c.check_coloured(s['dark'], s['aonly'], s['bonly'], s['a'], s['b'], noisy)
        self.assertFalse(r.ok, r)
        self.assertIn('residual', r.detail)

    def testOwn(self):
        s = self.s
        self.assertTrue(self.c.check_own(s['dark'], s['aonly'], s['bonly'], s['a'], 'a').ok)
        self.assertTrue(self.c.check_own(s['dark'], s['aonly'], s['bonly'], s['b'], 'b').ok)
        # A's map darkening B's light too (the whole-pixel shadow)
        wp = whole_pixel(s['none'], s['sa'])
        r = self.c.check_own(s['dark'], s['aonly'], s['bonly'], wp, 'a')
        self.assertFalse(r.ok, r)
        # no shadow at all
        r = self.c.check_own(s['dark'], s['aonly'], s['bonly'], s['none'], 'a')
        self.assertFalse(r.ok, r)
        # the wrong light shadowed
        r = self.c.check_own(s['dark'], s['aonly'], s['bonly'], s['b'], 'a')
        self.assertFalse(r.ok, r)

    def testIndependent(self):
        s = self.s
        self.assertTrue(self.c.check_independent(s['none'], s['a'], s['b'], s['ab']).ok)
        extra = lit(s['ab'], (-20.0, -20.0, -20.0), region(s['ab'].shape[:2], 50, 60, 0, 80))
        self.assertFalse(self.c.check_independent(s['none'], s['a'], s['b'], extra).ok)

    def testNoExtra(self):
        s = self.s
        self.assertTrue(self.c.check_no_extra(s['none'], s['a'], s['b'], s['ab']).ok)
        extra = lit(s['ab'], (-30.0, -30.0, -30.0), region(s['ab'].shape[:2], 50, 60, 0, 80))
        r = self.c.check_no_extra(s['none'], s['a'], s['b'], extra)
        self.assertFalse(r.ok, r)

    def testSpeckle(self):
        s = self.s
        self.assertTrue(self.c.check_speckle(s['ab'], s['none']).ok)
        acne = s['none'].copy()
        acne[::4, ::4] -= 40          # isolated dark pixels
        r = self.c.check_speckle(acne, s['none'])
        self.assertFalse(r.ok, r)

    def testSameAndDiffers(self):
        a = img()
        self.assertTrue(self.c.check_same(a, a.copy()).ok)
        b = a.copy()
        b[0, 0, 1] += 1
        r = self.c.check_same(a, b)
        self.assertFalse(r.ok)
        self.assertIn('1 pixels differ', r.detail)
        # a crop that leaves the difference out
        self.assertTrue(self.c.check_same(a, b, crop=(10, 10, 40, 40)).ok)
        self.assertFalse(self.c.check_differs(b, a).ok)       # 1 pixel < DIFFERS_MIN
        c = lit(a, (5.0, 5.0, 5.0), region(a.shape[:2], 0, 30, 0, 80))
        self.assertTrue(self.c.check_differs(c, a).ok)
        # darken: c is BRIGHTER than a, and only by 5 levels
        self.assertFalse(self.c.check_differs(c, a, darken=True).ok)
        self.assertTrue(self.c.check_differs(a, lit(a, (40.0, 40.0, 40.0)), darken=True).ok)
        # different sizes never pass
        self.assertFalse(self.c.check_same(a, img(10, 10)).ok)

    def testSilhouette(self):
        base = lit(img(), (120.0, 120.0, 120.0))
        shape = base.shape[:2]
        front = whole_pixel(base, region(shape, 10, 30, 10, 30))      # 400 px
        side = whole_pixel(base, region(shape, 10, 30, 40, 55))       # 300 px
        self.assertTrue(self.c.check_silhouette(front, base, side, base).ok)
        thin = whole_pixel(base, region(shape, 10, 30, 40, 42))       # 40 px: billboards
        r = self.c.check_silhouette(front, base, thin, base)
        self.assertFalse(r.ok, r)
        # no shadow from the front either: nothing proved
        self.assertFalse(self.c.check_silhouette(base, base, base, base).ok)

    def testOit(self):
        s = self.s
        self.assertTrue(self.c.check_oit(s['none'], s['a']).ok)
        # the light taken away is cyan: B's shadow, not A's
        r = self.c.check_oit(s['none'], s['b'])
        self.assertFalse(r.ok, r)
        self.assertFalse(self.c.check_oit(s['none'], s['none']).ok)

    def testOverlay(self):
        s = self.s
        self.assertTrue(self.c.check_overlay(s['none'], s['none'].copy(), s['a'], s['none']).ok)
        # the gizmo casts
        self.assertFalse(self.c.check_overlay(s['a'], s['none'], s['a'], s['none']).ok)
        # the control casts nothing: the pair proves nothing
        self.assertFalse(self.c.check_overlay(s['none'], s['none'], s['none'], s['none']).ok)

    def testGrid(self):
        h, w = 100, 200
        base = lit(img(h, w), (120.0, 120.0, 120.0))
        crop = self.c.grid_cell(base.shape, (2, 1, 0))
        self.assertEqual(crop, (16, 16, 84, 84))
        self.assertEqual(self.c.grid_cell(base.shape, (2, 2, 3), 0), (100, 50, 200, 100))
        other_cell = whole_pixel(base, region((h, w), 20, 60, 120, 180))
        m_shadow = whole_pixel(base, region((h, w), 20, 60, 20, 60))
        # the slab's own cell changes, the molecule's does not
        self.assertTrue(self.c.check_grid(other_cell, base, m_shadow, base, layout=(2, 1, 0)).ok)
        # the slab shadows the molecule's cell in grid mode
        r = self.c.check_grid(m_shadow, base, m_shadow, base, layout=(2, 1, 0))
        self.assertFalse(r.ok, r)
        # no control shadow
        self.assertFalse(self.c.check_grid(base, base, base, base, layout=(2, 1, 0)).ok)

    def testGridPositiveControl(self):
        # grid_self: m's cell darker with its light shadowed than unshadowed,
        # read inside m's cell only, and required at rt0
        plan = {p[1]: p for p in self.c.grid_plan()}
        for rt in (0, 1):
            check, subject, func, tags, kwargs = plan['grid_self_rt%d' % rt]
            self.assertEqual((check, func), ('differs', self.c.check_differs))
            self.assertEqual(tags, ['grid_slabhid_rt%d' % rt, 'grid_unshadowed_rt%d' % rt])
            self.assertEqual(kwargs, {'darken': True,
                                      'crop': (16, 16, 640 - 16, 720 - 16)})
        self.assertEqual(self.c.GRID_REQUIRED, ('grid_rt0', 'grid_self_rt0'))
        h, w = 720, 1280
        base = lit(img(h, w), (120.0, 120.0, 120.0))
        crop = plan['grid_self_rt0'][4]['crop']
        in_cell = whole_pixel(base, region((h, w), 100, 300, 100, 400))
        in_other = whole_pixel(base, region((h, w), 100, 300, 800, 1100))
        self.assertTrue(self.c.check_differs(in_cell, base, darken=True, crop=crop).ok)
        # a shadow in the other cell only, or none, fails
        self.assertFalse(self.c.check_differs(in_other, base, darken=True, crop=crop).ok)
        self.assertFalse(self.c.check_differs(base, base, darken=True, crop=crop).ok)

    def testPlansNameEveryCheck(self):
        names = {p[0] for p in self.c.l2_plan()} | {p[0] for p in self.c.grid_plan()}
        self.assertEqual(names, {'coloured', 'own', 'independent', 'no_extra', 'speckle',
                                 'same', 'differs', 'silhouette', 'oit', 'overlay', 'grid'})
        # the dark byte pair and its control run at rt0 AND rt1
        same = [p for p in self.c.l2_plan() if p[0] == 'same']
        self.assertEqual([p[3] for p in same],
                         [['shadows_dark_sh_ms1_rt0', 'shadows_dark_ns_ms0_rt0'],
                          ['shadows_dark_sh_ms1_rt1', 'shadows_dark_ns_ms0_rt1']])

    def testRunPlan(self):
        tmp = tempfile.mkdtemp(prefix='l616c')
        self.addCleanup(shutil.rmtree, tmp, True)
        s = self.s
        for k in ('dark', 'aonly', 'bonly', 'a', 'b', 'ab', 'none'):
            PIL.Image.fromarray(s[k].astype(numpy.uint8)).save(
                os.path.join(tmp, 'cartoon_%s_rt0.png' % k))
        plan = [p for p in self.c.l2_plan() if p[1].startswith('cartoon_') and
                p[1].endswith('rt0')]
        results = self.c.run_plan(tmp, plan)
        self.assertTrue(all(r.ok for r in results), results)
        # a check whose images are missing fails (cartoon at rt1)
        rt1 = [p for p in self.c.l2_plan() if p[1] == 'cartoon_rt1' and p[0] == 'coloured']
        results = self.c.run_plan(tmp, rt1)
        self.assertFalse(results[0].ok)
        self.assertIn('missing', results[0].detail)
        # an informational subject is reported but never fails the run
        results = self.c.run_plan(tmp, rt1, required=())
        self.assertTrue(results[0].ok)
        self.assertIn('(info, fail)', results[0].detail)
        with self.assertRaises(self.c.Usage):
            self.c.run_plan(os.path.join(tmp, 'nope'), plan)
        self.assertEqual(self.c.main(['l2', tmp, '--checks', 'coloured']), 1)   # rt1 missing
        self.assertEqual(self.c.main(['l2', tmp, '--checks', 'bogus']), 2)
        self.assertEqual(self.c.main(['same', os.path.join(tmp, 'cartoon_a_rt0.png'),
                                      os.path.join(tmp, 'cartoon_a_rt0.png')]), 0)


# --- the scene files ------------------------------------------------------------------

def tag_parts(tag):
    """(base without _rt<n>, rt)."""
    m = re.match(r'^(.*)_rt([01])$', tag)
    return m.group(1), int(m.group(2))


def expected(which, tag):
    """(names of the shadowed lights, the intensities (None: don't check),
    metal_shadows) a scene's tag stands for, written out from the tag."""
    base, _ = tag_parts(tag)
    if which == 'l2':
        for rep in ('cartoon', 'surface', 'sticks', 'spheres', 'transparent', 'glass'):
            if base.startswith(rep + '_') and base[len(rep) + 1:] in (
                    'dark', 'aonly', 'bonly', 'none', 'a', 'b', 'ab'):
                k = base[len(rep) + 1:]
                shadowed = {'a': ['amber'], 'b': ['cyan'], 'ab': ['amber', 'cyan']}.get(k, [])
                inten = {'dark': [0.0, 0.0], 'aonly': [1.0, 0.0],
                         'bonly': [0.0, 1.0]}.get(k, [1.0, 1.0])
                return shadowed, inten, 1 if k in ('a', 'b', 'ab') else 0
        if base.startswith('shadows_dark_'):
            k = base[len('shadows_dark_'):]
            return (['amber', 'cyan'] if k.startswith('sh') else [], [0.0, 0.0],
                    int(k.endswith('ms1')))
        if base.startswith(('sticks_', 'spheres_')):        # silhouettes
            a = '_a' in base
            return (['amber'] if a else []), [1.0], int(a)
        if base.startswith('ovl_'):
            return ['amber'], [1.0], 1
        if base == 'rig3':
            return ['amber', 'cyan', 'magenta'], [1.0, 1.0, 1.0], 1
        if base.startswith('cartoon_ab_s'):
            return ['amber', 'cyan'], [1.0, 1.0], 1
    if which == 'grid':
        return ([] if base.startswith('grid_unshadowed') else ['amber']), [1.0], 1
    if which == 'noshadow':
        if base.startswith('rig3key_'):
            return ['key'], None, 0
        if base.startswith('rig3all_'):
            return ['key', 'fill', 'rim'], None, 0
        return [], [1.0, 1.0], int(base.endswith('_ms1'))
    raise AssertionError('no expectation for %s %s' % (which, tag))


def eye(point, cam):
    d = [point[j] - cam.origin[j] for j in range(3)]
    return [sum(cam.rot[3 * i + j] * d[j] for j in range(3)) + cam.pos[i] for i in range(3)]


def outside_view(points, cam, aspect):
    """Every point beyond ONE side plane of the view frustum."""
    ndc = []
    for p in points:
        e = eye(p, cam)
        depth = -e[2]
        if depth <= 0:
            return False
        ndc.append((e[0] / (depth * cam.tan_half * aspect), e[1] / (depth * cam.tan_half)))
    return (all(x > 1 for x, _ in ndc) or all(x < -1 for x, _ in ndc) or
            all(y > 1 for _, y in ndc) or all(y < -1 for _, y in ndc))


@unittest.skipUnless(HAVE_CHECKOUT, 'needs a RayMol checkout (scripts/lighting)')
class TestSceneFiles(testing.PyMOLTestCase):

    @classmethod
    def setUpClass(cls):
        assert_present(os.path.join(LIGHTING, 'render.py'),
                       os.path.join(LIGHTING, 'check_shadows.py'), PDB, *FILES.values())
        cls.render = load_module('lighting_render', 'render.py')
        cls.check = load_module('lighting_check_shadows', 'check_shadows.py')
        cls.jobs = {k: cls.render.scene_file_jobs(v) for k, v in FILES.items()}
        cls.specs = {}
        for k, v in FILES.items():
            with open(v) as handle:
                cls.specs[k] = json.load(handle)

    def setUp(self):
        super(TestSceneFiles, self).setUp()
        self.original_set_lights = cmd.set_lights
        self.tmp = tempfile.mkdtemp(prefix='l616')
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def tearDown(self):
        restore_set_lights()
        cmd.set_lights(None)
        self.assertIs(cmd.set_lights, self.original_set_lights)
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
                math.sqrt(sum((b - a) ** 2 for a, b in zip(mn, mx))) / 2.0)

    def testSceneFilesLoad(self):
        self.assertEqual(len(self.jobs['l2']), 87)
        self.assertEqual(len(self.jobs['grid']), 10)
        self.assertEqual(len(self.jobs['noshadow']), 60)
        for which, spec in self.specs.items():
            self.assertEqual(spec['rig'], 'on', which)
            self.assertIsNone(spec['base'], which)
            for job in self.jobs[which]:
                self.assertEqual(job.size, (1280, 720), job.tag)
                tag_parts(job.tag)
                # every scene sets the shim's rig, as its last line
                self.assertTrue(job.extra[-1].startswith(RIG_LINE), job.tag)

    def testEveryCheckHasItsImages(self):
        for which, plan in (('l2', self.check.l2_plan()), ('grid', self.check.grid_plan())):
            tags = {j.tag for j in self.jobs[which]}
            need = {t for p in plan for t in p[3]}
            self.assertEqual(sorted(need - tags), [], which)
            # every image is read by a check, or is listed as informational
            self.assertEqual(sorted(tags - need - set(self.check.INFORMATIONAL)), [], which)

    def testNoShadowFileCoversThePlan(self):
        tags = {j.tag for j in self.jobs['noshadow']}
        for rep in ('cartoon', 'surface', 'sticks', 'spheres', 'mesh', 'transparent',
                    'glass', 'shadows', 'tube', 'sticks_trans', 'spheres_trans',
                    'cartoon_ortho', 'grid'):
            for ms in (0, 1):
                for rt in (0, 1):
                    self.assertIn('%s_ns_ms%d_rt%d' % (rep, ms, rt), tags)

    def testEveryScriptRunsInProcess(self):
        """Every scene: the camera stays the harness's, the rig is framed on m
        whatever else is loaded, and its lights, shadows and metal_shadows
        are what the tag says."""
        ran = 0
        for which in ('l2', 'grid', 'noshadow'):
            for job in self.jobs[which]:
                ran += 1
                marker = self.run_job(job)
                with open(marker) as handle:
                    self.assertEqual(len(handle.read().splitlines()), 1, job.tag)
                view = cmd.get_view()
                for i, (got, want) in enumerate(zip(view, self.render.VIEW)):
                    if i == 17:
                        got, want = abs(got), abs(want)
                    self.assertAlmostEqual(got, want, delta=1e-3,
                                           msg='%s moves the camera (view[%d])' % (job.tag, i))
                rig = cmd.get_lights()
                self.assertIs(rig['enabled'], True, job.tag)
                centre, size = self.m_frame()
                for got, want in zip(rig['centre'], centre):
                    self.assertAlmostEqual(got, want, delta=1e-4, msg=job.tag)
                self.assertAlmostEqual(rig['size'], size, delta=1e-4, msg=job.tag)
                shadowed, inten, ms = expected(which, job.tag)
                self.assertEqual([l['name'] for l in rig['lights'] if l['shadow']], shadowed,
                                 job.tag)
                if inten is not None:
                    self.assertEqual([l['intensity'] for l in rig['lights']], inten, job.tag)
                self.assertEqual(cmd.get_setting_int('metal_shadows'), ms, job.tag)
                base, rt = tag_parts(job.tag)
                self.assertEqual(cmd.get_setting_int('metal_raytrace'), rt, job.tag)
                self.assertEqual(cmd.get_setting_int('orthoscopic'), int('ortho' in base),
                                 job.tag)
                self.assertEqual(cmd.get_setting_int('grid_mode'),
                                 int(base.startswith('grid')), job.tag)
                if which == 'l2':
                    self.assertEqual(cmd.get_setting_int('depth_cue'), 0, job.tag)
                    # every L2 scene has the backdrop but the OIT and
                    # silhouette ones, which read the molecule alone
                    plain = (base.startswith(('transparent_', 'glass_')) or
                             '_front_' in base or '_side_' in base)
                    self.assertEqual('backdrop' in cmd.get_names('objects'), not plain,
                                     job.tag)
            restore_set_lights()
        self.assertEqual(ran, 87 + 10 + 60)

    def testShimInProcess(self):
        job = self.job('l2', 'cartoon_ab_rt0')
        marker = self.run_job(job, times=2)       # the app runs it twice
        self.assertIsNone(self.render.check_marker(marker, job.tag, 'on'))
        self.assertIs(cmd._l616_set, self.original_set_lights)
        rig = cmd.get_lights()
        self.assertEqual((rig['ambient'], rig['classic']), (0.05, 0.0))
        self.assertEqual([l['name'] for l in rig['lights']], ['amber', 'cyan'])
        self.assertEqual([l['color'] for l in rig['lights']],
                         [[1.0, 0.55, 0.15], [0.15, 0.75, 1.0]])
        self.assertEqual([l['shadow'] for l in rig['lights']], [True, True])
        frame = lighting._light_frame()
        amber, cyan = [l['radiance'] for l in frame['rig']['lights']]
        self.assertGreater(amber[0], amber[2])
        self.assertGreater(cyan[2], cyan[0])
        # the backdrop is loaded once, not once per run
        self.assertEqual(cmd.get_names('objects'), ['m', 'backdrop'])

        # a function of the harness rig (the noshadow file's rig3 scenes)
        self.run_job(self.job('noshadow', 'rig3all_surface_rt1'), times=2)
        self.assertIs(cmd._l616_set, self.original_set_lights)
        rig = cmd.get_lights()
        self.assertEqual([l['name'] for l in rig['lights']], ['key', 'fill', 'rim'])
        self.assertEqual([l['shadow'] for l in rig['lights']], [True, True, True])
        self.assertEqual(cmd.get_setting_int('metal_shadows'), 0)

    def testMapSizeSweep(self):
        """cartoon_ab_s<n> set metal_light_shadow_size where it exists (#616
        adds it after this file), and change nothing else otherwise."""
        names = cmd.setting.get_name_list()
        for size in (512, 1024, 4096):
            self.run_job(self.job('l2', 'cartoon_ab_s%d_rt0' % size))
            if 'metal_light_shadow_size' in names:
                self.assertEqual(cmd.get_setting_int('metal_light_shadow_size'), size)

    def testCastersOutsideTheView(self):
        """The overlay and grid casters lie outside the camera view, halfway
        between their light and the rig centre (so the pairs compare only
        their shadows); the light's place comes from the C++ resolver."""
        aspect = 1280.0 / 720.0
        extents = {}
        for which, tag, name in (('l2', 'ovl_gizmo_rt0', '_move_gizmo'),
                                 ('l2', 'ovl_gizmohid_rt0', '_move_gizmo'),
                                 ('l2', 'ovl_blob_rt0', 'blob'),
                                 ('l2', 'ovl_blobhid_rt0', 'blob'),
                                 ('grid', 'grid_slab_rt0', 'slab'),
                                 ('grid', 'nogrid_slabhid_rt0', 'slab')):
            self.run_job(self.job(which, tag))
            cam = metal_pick.camera()
            mn, mx = cmd.get_extent(name)
            corners = list(itertools.product(*zip(mn, mx)))
            self.assertTrue(outside_view(corners, cam, aspect), tag)
            # in a grid cell (half the width) too
            self.assertTrue(outside_view(corners, cam, aspect / 2.0), tag)
            centre_world = [(a + b) / 2.0 for a, b in zip(mn, mx)]
            got = eye(centre_world, cam)
            frame = lighting._lights_eye()
            light = frame['lights'][0]['position']
            mid = [(l + c) / 2.0 for l, c in zip(light, frame['centre'])]
            for g, w in zip(got, mid):
                self.assertAlmostEqual(g, w, delta=0.05, msg=tag)
            extents[tag] = (mn, mx)
        # hidden or shown, a caster's extent is the same (so are the frustum
        # and the grid layout)
        for shown, hidden in (('ovl_gizmo_rt0', 'ovl_gizmohid_rt0'),
                              ('ovl_blob_rt0', 'ovl_blobhid_rt0'),
                              ('grid_slab_rt0', 'nogrid_slabhid_rt0')):
            for a, b in zip(extents[shown], extents[hidden]):
                for x, y in zip(a, b):
                    self.assertAlmostEqual(x, y, delta=1e-4, msg=shown)

    def testBackdropBehindTheMolecule(self):
        self.run_job(self.job('l2', 'cartoon_none_rt0'))
        cam = metal_pick.camera()
        xyz = []
        cmd.iterate_state(1, 'm', 'xyz.append((x, y, z))', space={'xyz': xyz})
        far_atom = max(-eye(p, cam)[2] for p in xyz)
        mn, mx = cmd.get_extent('backdrop')
        # the quad is perpendicular to the view: its corners' depths bracket
        # the plane's depth at the centre of its box
        depth = -eye([(a + b) / 2.0 for a, b in zip(mn, mx)], cam)[2]
        self.assertGreater(depth, far_atom + 3.0)
        self.assertLess(depth, cam.clip_back)


# --- time_shadows.py ------------------------------------------------------------------

@unittest.skipUnless(HAVE_CHECKOUT, 'needs a RayMol checkout (scripts/lighting)')
class TestTimeShadows(testing.PyMOLTestCase):

    @classmethod
    def setUpClass(cls):
        assert_present(os.path.join(LIGHTING, 'time_shadows.py'), PDB)
        cls.t = load_module('lighting_time_shadows', 'time_shadows.py')
        cls.render = cls.t.load_render()

    def setUp(self):
        super(TestTimeShadows, self).setUp()
        self.tmp = tempfile.mkdtemp(prefix='l616t')
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def tearDown(self):
        vars(cmd).pop('_ts_started', None)
        cmd.set_lights(None)
        super(TestTimeShadows, self).tearDown()

    def testConfigMatrix(self):
        tags = [c.tag for c in self.t.configs()]
        want = ['%s_%s' % (s, r) for s in ('1rx1', '1ao6', '7k00')
                for r in ('norig', 's0', 's1', 's3')] + ['7k00_s3_1024', '7k00_s3_4096']
        self.assertEqual(tags, want)
        self.assertEqual(self.t.FRAMES, 48)
        self.assertEqual(self.t.SIZE, (1920, 1080))
        self.assertEqual(self.t.FALLBACK['7k00'][0], '1aon')
        for n in (0, 1, 3):
            rig = self.t.rig_dict(n)
            self.assertEqual([l['shadow'] for l in rig['lights']],
                             [i < n for i in range(3)])
            self.assertIs(rig['enabled'], True)

    def testAutocmdText(self):
        script = os.path.join(self.tmp, 'work', '7k00_s3_r1.py')
        text = self.t.autocmd(script)
        for word in (';', 'orient', 'reset', 'load ', 'fetch ', 'show '):
            self.assertNotIn(word, text)
        env = self.t.launch_env(script, os.path.join(self.tmp, 't.timing'))
        self.assertIn('PYMOL_AUTOCMD=run %s' % script, env)
        self.assertIn('RAYMOL_GPU_TIMING=%s' % os.path.join(self.tmp, 't.timing'), env)
        with self.assertRaises(self.t.Refusal):
            self.t.launch_env(os.path.join(self.tmp, 'orient', 'x.py'), 't')
        with self.assertRaises(self.t.Refusal):
            self.t.check_autocmd('run a.py; run b.py')

    def testDryRun(self):
        out = os.path.join(self.tmp, 'dry')
        self.assertEqual(self.t.main(['--out', out, '--dry-run', '--runs', '1',
                                      '--only', '1rx1_s1,7k00_s3_4096']), 0)
        work = os.path.join(out, '_work')
        self.assertEqual(sorted(os.listdir(work)), ['1rx1_s1_r1.py', '7k00_s3_4096_r1.py'])
        with open(os.path.join(work, '7k00_s3_4096_r1.py')) as fh:
            text = fh.read()
        self.assertIn("cmd.set('metal_light_shadow_size', 4096)", text)
        self.assertIn("ray=1", text)
        self.assertEqual(self.t.main(['--out', out, '--dry-run', '--only', 'bogus']), 2)
        self.assertEqual(self.t.main(['--out', out]), 2)           # no --app

    def testExportQueuedOncePerProcess(self):
        config = self.t.Config('1rx1', 's1')
        mp4 = os.path.join(self.tmp, 'x.mp4')
        start = os.path.join(self.tmp, 'x.start.json')
        script = os.path.join(self.tmp, 'x.py')
        with open(script, 'w') as fh:
            fh.write(self.t.script_text(self.render, config, PDB, mp4, start, frames=4))
        calls = []
        original = cmd.movie_export
        cmd.movie_export = lambda *a, **k: calls.append((a, k))
        try:
            cmd.run(script)
            cmd.run(script)              # the app may run AUTOCMD twice
        finally:
            cmd.movie_export = original
        self.assertEqual(len(calls), 1)
        args, kwargs = calls[0]
        self.assertEqual(args, (mp4, 1920, 1080))
        self.assertEqual(kwargs, {'quality': 'standard', 'ray': 1})
        with open(start) as fh:
            stamp = json.load(fh)
        self.assertEqual((stamp['tag'], stamp['frames']), ('1rx1_s1', 4))
        self.assertGreater(stamp['atoms'], 1000)
        self.assertEqual(cmd.get_setting_int('metal_raytrace'), 1)
        self.assertEqual(cmd.get_setting_int('metal_shadows'), 1)
        rig = cmd.get_lights()
        self.assertEqual([l['shadow'] for l in rig['lights']], [True, False, False])
        mn, mx = cmd.get_extent('m')
        for got, want in zip(rig['centre'], [(a + b) / 2.0 for a, b in zip(mn, mx)]):
            self.assertAlmostEqual(got, want, delta=1e-4)

    def testStampedLines(self):
        timing = os.path.join(self.tmp, 'gpu.timing')
        clock = [100.0]
        tail = self.t.Tailer(timing, clock=lambda: clock[0])
        self.assertEqual(tail.poll(), 0)                  # no file yet
        with open(timing, 'w') as fh:
            fh.write('offscreen 1920x1080 gpu_ms=12.50\n'
                     'RendererMetal: 0.5 fps, gpu 3.0 ms\n'
                     'offscreen 640x480 gpu_ms=1.00\n'
                     'offscreen 1920x1080 gpu_ms=1')            # half a line
        tail.poll()
        clock[0] = 102.5
        with open(timing, 'a') as fh:
            fh.write('4.00\noffscreen 1920x1080 gpu_ms=16.00\n')
        tail.poll()
        self.assertEqual(tail.frames(), [(100.0, 12.5), (102.5, 14.0), (102.5, 16.0)])
        self.assertIsNone(self.t.parse_gpu_ms('offscreen 1920x1080 gpu_ms=abc'))

    def testArithmetic(self):
        frames = [(10.0 + 2.0 * i, 100.0 + i) for i in range(48)]     # 2 s per frame
        frames[0] = (5.0, 900.0)                                       # frame 1: compiles
        run = self.t.summarise_run(frames, 48, start=0.0, mp4_end=96.0)
        self.assertAlmostEqual(run['s_per_frame'], (104.0 - 5.0) / 47.0)
        self.assertAlmostEqual(run['gpu_ms_median'], 124.0)           # lines 2..48: 101..147
        self.assertAlmostEqual(run['s_per_frame_mp4'], 2.0)
        self.assertTrue(run['complete'])
        short = self.t.summarise_run(frames[:10], 48)
        self.assertIsNone(short['s_per_frame'])
        self.assertFalse(short['complete'])
        # an extra stray line never stretches the measure: line 48 is used
        extra = self.t.summarise_run(frames + [(500.0, 1.0)], 48)
        self.assertAlmostEqual(extra['s_per_frame'], run['s_per_frame'])
        self.assertFalse(extra['complete'])

    def testSummaryAndTable(self):
        C = self.t.Config
        def runs(*s):
            return [{'s_per_frame': v, 's_per_frame_mp4': v,
                     'gpu_ms_median': None if v is None else 10.0 * v}
                    for v in s]
        results = {
            '7k00_s0': {'config': C('7k00', 's0'), 'runs': runs(2.0, 2.2, 1.8), 'atoms': 150000},
            '7k00_s3': {'config': C('7k00', 's3'), 'runs': runs(2.6, 2.4, 2.5), 'atoms': 150000},
            '7k00_norig': {'config': C('7k00', 'norig'), 'runs': runs(1.5), 'atoms': 150000},
            '7k00_s3_1024': {'config': C('7k00', 's3', 1024), 'runs': runs(None), 'atoms': None},
        }
        summary = self.t.summarise(results)
        self.assertAlmostEqual(summary['7k00_s3']['s_per_frame'], 2.5)
        self.assertAlmostEqual(summary['7k00_s3']['delta_vs_s0'], 0.25)
        self.assertIsNone(summary['7k00_norig']['delta_vs_s0'])
        self.assertIsNone(summary['7k00_s3_1024']['s_per_frame'])
        text = self.t.table(summary, ['7k00_norig', '7k00_s0', '7k00_s3', '7k00_s3_1024'])
        lines = text.strip().split('\n')
        self.assertEqual(len(lines), 6)
        self.assertTrue(lines[0].startswith('| Structure | Atoms | Config | Map size | s/frame'))
        self.assertEqual(lines[4], '| 7k00 | 150000 | s3 | default | 2.500 | 2.500 | 25.0 | +25.0% |')
        self.assertEqual(lines[5], '| 7k00 | - | s3 | 1024 | - | - | - | - |')
        for line in lines:
            self.assertEqual(line.count('|'), 9, line)

    def testCountAtoms(self):
        n = self.t.count_atoms(PDB)
        cmd.load(PDB, 'tmp_count')
        self.assertEqual(n, cmd.count_atoms('tmp_count'))
