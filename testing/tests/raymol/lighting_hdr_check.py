"""HDR colour and exposure's evidence (#624): pixel checks, scene files, timing.

L2 for #624 renders scripts/lighting/scenes/lighting_624.json with the frozen
harness and decides with scripts/lighting/check_hdr.py (l2, and negative: the
knee twins fail every proof); L1b compares lighting_624_regress.json with
master's renders (max 0); L6 runs scripts/lighting/time_hdr.py. CI has no GPU,
so this pins what it can:

* check_hdr.py's twin of D2 (the identity under the knee, the white point,
  monotone, C1 at the knee, concave, hue kept, the closed-form inverse, NaN
  and negatives to 0), mat_soft_knee, D7's glass and D8's air composites, the
  8-bit air bound, and the model's light colour against the core's warmth;
* the checks on the model's synthetic renders: the HDR set passes every row,
  the knee set (a build before #624) fails exactly the proofs (plus display,
  an HDR behaviour), the negative control from files, each guard failing on a
  broken image, the plan, kinds, thresholds and the command line;
* both scene files load with the frozen harness; every tag the checks read is
  rendered and nothing else; each knee twin is its tag plus
  _l624_opt('metal_light_hdr', 2); metal_light_hdr is set only through
  _l624_opt; recover pairs differ only in intensity x exposure (the same light
  in scene units); the regression file runs on master; every scene script runs
  in-process twice and installs what its tag says, framed on m;
* time_hdr.py: the matrices, the generated scripts (time_shadows' run-2
  export guard, the switch and air lines, the toggle's frame commands after
  util.mroll's), the export queued once per process, the AUTOCMD refusals, the
  per-frame parsing (2 lines per ray=1 frame), the spike summary, the tables
  and flags, --dry-run.

Source-reading, so skipped (not passed) outside a repo checkout, decided by
one file every checkout has; in a checkout the ticket's own files are
required, so renaming one fails instead of skipping. The pixel checks are
skipped without numpy or Pillow.

Runs on a RayMol build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/lighting_hdr_check.py
"""
import importlib.util
import json
import os
import re
import shutil
import tempfile
import unittest

from pymol import cmd, lighting, testing

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), os.pardir,
                                     os.pardir, os.pardir))
LIGHTING = os.path.join(ROOT, 'scripts', 'lighting')
SCENES = os.path.join(LIGHTING, 'scenes')
PDB = os.path.join(ROOT, 'testing', 'data', '1rx1.pdb')
METAL = os.path.join(ROOT, 'layerGraphics', 'metal', 'RendererMetal.mm')
FILES = {
    'l2': os.path.join(SCENES, 'lighting_624.json'),
    'regress': os.path.join(SCENES, 'lighting_624_regress.json'),
}
HAVE_CHECKOUT = os.path.isfile(METAL)

try:
    import numpy
    import PIL.Image
    HAVE_PIXELS = True
except ImportError:
    HAVE_PIXELS = False

KNEE_LINE = "_l624_opt('metal_light_hdr', 2)"
RIG_LINE = 'cmd._l624_rig = '


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
    """Undo the scene files' cmd.set_lights shim (what tearDown does)."""
    original = vars(cmd).pop('_l624_set', None)
    if original is not None:
        cmd.set_lights = original
    vars(cmd).pop('_l624_rig', None)


def tag_parts(tag):
    m = re.match(r'^(.*)_rt([01])$', tag)
    return m.group(1), int(m.group(2))


def save(directory, tag, image):
    a = numpy.asarray(image).astype(numpy.uint8)
    PIL.Image.fromarray(a, 'RGBA' if a.shape[-1] == 4 else 'RGB').save(
        os.path.join(directory, tag + '.png'))


# --- the twin --------------------------------------------------------------------------

@unittest.skipUnless(HAVE_CHECKOUT, 'needs a RayMol checkout (scripts/lighting)')
@unittest.skipUnless(HAVE_PIXELS, 'needs numpy and Pillow')
class TestTwin(testing.PyMOLTestCase):

    @classmethod
    def setUpClass(cls):
        assert_present(os.path.join(LIGHTING, 'check_hdr.py'))
        cls.c = load_module('lighting_check_hdr', 'check_hdr.py')

    def testCurveConstants(self):
        # D2's curve as part 6 tuned it once (k 0.5-0.8, W 6-16) and froze it
        self.assertEqual((self.c.TONE_KNEE, self.c.TONE_WHITE), (0.55, 10.0))
        self.assertEqual(self.c.SOFT_KNEE, 0.8)
        self.assertAlmostEqual(float(self.c.tone_scalar(1.0)), 0.7755, places=4)
        self.assertGreaterEqual(float(self.c.tone_scalar(1.0)), 0.75)   # D2's constraint

    def testIdentityBelowTheKnee(self):
        c = self.c
        x = numpy.linspace(0.0, c.TONE_KNEE, 601)
        self.assertTrue((c.tone_scalar(x) == x).all())
        rgb = numpy.stack([x, 0.5 * x, 0.25 * x], axis=-1)
        self.assertTrue((c.tone(rgb) == rgb).all())
        self.assertTrue((c.tone_inverse(rgb) == rgb).all())

    def testWhitePoint(self):
        c = self.c
        self.assertAlmostEqual(float(c.tone_scalar(c.TONE_WHITE)), 1.0, places=12)
        self.assertEqual(float(c.tone_scalar(c.TONE_WHITE + 1e-9)), 1.0)
        self.assertEqual(float(c.tone_scalar(1e30)), 1.0)
        # past W the hue stays at full scale: c / max
        out = c.tone(numpy.array([16.0, 8.0, 4.0]))
        self.assertTrue(numpy.allclose(out, [1.0, 0.5, 0.25], atol=0, rtol=0))
        self.assertEqual(float(c.tone_scalar_inverse(1.0)), c.TONE_WHITE)

    def testMonotoneC1Concave(self):
        c = self.c
        x = numpy.linspace(0.0, 12.0, 120001)
        y = c.tone_scalar(x)
        self.assertTrue((numpy.diff(y) >= 0).all())
        self.assertTrue((y <= 1.0).all())
        h = 1e-6
        k = c.TONE_KNEE
        left = (c.tone_scalar(k) - c.tone_scalar(k - h)) / h
        right = (c.tone_scalar(k + h) - c.tone_scalar(k)) / h
        self.assertAlmostEqual(float(left), 1.0, delta=1e-3)
        self.assertAlmostEqual(float(right), 1.0, delta=1e-3)
        above = y[(x > k + 0.01) & (x < c.TONE_WHITE - 0.01)]
        self.assertTrue((numpy.diff(above, 2) <= 1e-12).all())

    def testHueKept(self):
        c = self.c
        rgb = numpy.array([[3.0, 1.5, 0.3], [1.2, 0.9, 0.6], [0.2, 5.0, 7.0]])
        out = c.tone(rgb)
        for a, b in zip(rgb, out):
            self.assertTrue(numpy.allclose(b / b.max(), a / a.max(), rtol=1e-12))
        # exposure multiplies first: T(e x)
        self.assertTrue(numpy.allclose(c.tone(rgb, 0.5), c.tone(0.5 * rgb), rtol=0, atol=0))

    def testInverse(self):
        c = self.c
        y = numpy.linspace(0.0, 1.0, 10001)
        self.assertLess(float(numpy.abs(c.tone_scalar(c.tone_scalar_inverse(y)) - y).max()),
                        1e-6)
        x = numpy.linspace(0.0, c.TONE_WHITE - 1e-3, 5001)
        self.assertLess(float(numpy.abs(c.tone_scalar_inverse(c.tone_scalar(x)) - x).max()),
                        1e-6)
        rgb = numpy.array([[2.0, 1.0, 0.5], [0.3, 0.2, 0.1]])
        self.assertTrue(numpy.allclose(c.tone_inverse(c.tone(rgb)), rgb, atol=1e-9))

    def testNonFinite(self):
        c = self.c
        out = c.tone_scalar([float('nan'), float('inf'), -float('inf'), -2.0])
        self.assertEqual(list(out), [0.0, 0.0, 0.0, 0.0])
        rgb = numpy.array([[float('nan'), 1.0, 1.0], [1.0, float('inf'), 0.5],
                           [-1.0, 0.5, 0.25]])
        out = c.tone(rgb)
        self.assertEqual(out[0].tolist(), [0.0, 0.0, 0.0])
        self.assertEqual(out[1].tolist(), [0.0, 0.0, 0.0])
        self.assertEqual(out[2].tolist(), [0.0, 0.5, 0.25])
        self.assertEqual(c.tone_inverse(rgb)[0].tolist(), [0.0, 0.0, 0.0])

    def testSoftKneeIsTheShaders(self):
        c = self.c
        self.assertEqual(float(c.soft_knee(numpy.array([0.8]))[0]), 0.8)
        self.assertAlmostEqual(float(c.soft_knee(numpy.array([1.0]))[0]),
                               0.8 + 0.2 * 0.2 / 1.2, places=12)
        with open(METAL) as fh:
            src = fh.read()
        m = re.search(r'static float3 mat_soft_knee\(float3 c\) \{(.*?)\n\}', src, re.S)
        self.assertIsNotNone(m)
        self.assertIn('const float knee = 0.8;', m.group(1))
        self.assertIn('over / (float3(1.0) + over) * (1.0 - knee)', m.group(1))

    def testGlassCover(self):
        c = self.c
        # D7: at exposure 1, under both knees, light_glass_cover is mat_glass_cover
        body = numpy.array([[0.3, 0.2, 0.1], [0.3, 0.25, 0.2]])
        hi = numpy.array([[0.05, 0.05, 0.05], [0.1, 0.1, 0.1]])
        a = 0.4
        kr, kc = c.glass_cover_knee(body, hi, a)
        hr, hc = c.glass_cover_hdr(body, hi, a, 1.0)
        self.assertTrue(numpy.array_equal(kc, hc))
        self.assertTrue(numpy.allclose(kr, hr, rtol=0, atol=1e-15))
        # bright glints over a lit body roll off instead of clipping
        rgb, cover = c.glass_cover_hdr(numpy.array([[2.0, 1.0, 0.3]]),
                                       numpy.array([[1.5, 1.5, 1.5]]), 0.35)
        self.assertLess(float(rgb.max()), 1.0)
        rgb, _ = c.glass_cover_knee(numpy.array([[2.0, 1.0, 0.3]]),
                                    numpy.array([[0.95, 0.95, 0.95]]), 0.35)
        self.assertEqual(float(rgb.max()), 1.0)          # the knee's saturate
        # glints: the HDR curve is the knee's slope at 0
        self.assertAlmostEqual(float(c.glints_hdr(1e-6)), float(c.glints_knee(1e-6)), places=10)

    def testAir(self):
        c = self.c
        grey = numpy.linspace(0.0, 1.0, 256)
        rgb = numpy.stack([grey] * 3, axis=-1)
        # no air: the pixel round-trips (exactly at or under the knee)
        out = c.air_hdr(rgb, numpy.zeros_like(rgb))
        self.assertLess(float(numpy.abs(out - rgb).max()), 1e-9)
        low = grey <= c.TONE_KNEE
        self.assertTrue((out[low] == rgb[low]).all())
        # white stays white; the air only adds
        self.assertTrue(numpy.allclose(c.air_hdr(numpy.ones(3), numpy.full(3, 0.5)), 1.0))
        more = c.air_hdr(rgb, numpy.full_like(rgb, 0.2))
        self.assertTrue((more >= rgb - 1e-12).all())
        # coloured air never lowers a channel: white under red haze stays
        # white, and a bright orange pixel keeps its green and blue (T alone
        # rescales by the largest channel and would lower them)
        red = numpy.array([2.0, 0.0, 0.0])
        self.assertTrue((c.air_hdr(numpy.ones(3), red) == 1.0).all())
        orange = numpy.array([0.95, 0.6, 0.3])
        self.assertLess(float(c.tone(c.tone_inverse(orange) + red)[1]), 0.6)
        self.assertTrue((c.air_hdr(orange, red) >= orange).all())
        # the knee's composite, as post_air_finish was
        self.assertTrue(numpy.allclose(c.air_knee(rgb, numpy.zeros_like(rgb)), rgb))
        # an 8-bit store costs the HDR air at most one level
        self.assertLessEqual(c.model_quantised_air(step=0.05), 1.0)

    def testModelLightColourIsTheCores(self):
        c = self.c
        for k in (3400.0, 4500.0, 5600.0, 6500.0, 8000.0):
            want = lighting._light_warmth(k)
            got = c.warmth_rgb(k)
            for a, b in zip(got, want):
                self.assertAlmostEqual(a, b, delta=1e-6, msg=k)
        for a, b in zip(c.WARM_5600, lighting._light_warmth(5600.0)):
            self.assertAlmostEqual(a, b, delta=1e-5)


# --- the checks ---------------------------------------------------------------------------

@unittest.skipUnless(HAVE_CHECKOUT, 'needs a RayMol checkout (scripts/lighting)')
@unittest.skipUnless(HAVE_PIXELS, 'needs numpy and Pillow')
class TestChecks(testing.PyMOLTestCase):

    @classmethod
    def setUpClass(cls):
        assert_present(*[os.path.join(LIGHTING, f) for f in (
            'check_hdr.py', 'check_air.py', 'check_shadows.py', 'check_materials.py')])
        cls.c = load_module('lighting_check_hdr', 'check_hdr.py')
        cls.hdr = cls.c.model_images('hdr')
        cls.knee = cls.c.model_images('knee')

    def setUp(self):
        super(TestChecks, self).setUp()
        self.tmp = tempfile.mkdtemp(prefix='l624c')
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def write_set(self, images, directory=None):
        directory = directory or self.tmp
        for tag, image in images.items():
            save(directory, tag, image)
        return directory

    def test_reuses_the_earlier_checks(self):
        c = self.c
        self.assertIs(c.cs, c.ca.cs)
        for name in ('load', 'luminance', 'geometry', 'Result', 'Usage'):
            self.assertIs(getattr(c, name), getattr(c.cs, name), name)
        self.assertIs(c.dilate, c.ca.dilate)
        self.assertEqual(c.SHADOW_HUE_MIN, c.cs.HUE_MIN)
        self.assertEqual(c.SHADOW_COLOURED_MIN, c.cs.COLOURED_MIN)
        with open(os.path.join(LIGHTING, 'check_hdr.py')) as fh:
            src = fh.read()
        for name in ('load', 'luminance', 'geometry', 'dilate', 'check_glints', 'glint_stats'):
            self.assertNotIn('def %s(' % name, src)

    def testThresholdsPinned(self):
        # FROZEN by part 6 from round 1 (the half-margin rule); part 1
        # modelled them and checked them on the round-0 renders.
        pinned = {
            'CLIP_LEVEL': 254, 'KNEE_LEVEL': 204, 'SWEEP_FOOT': 8, 'SWEEP_MIN_SHARE': 0.02,
            'SWEEP_STEP': 10, 'SWEEP_CLIP': 0.01, 'SWEEP_CHROMA': 0.7, 'SWEEP_SPREAD': 1.0,
            'SWEEP_E05_MARGIN': 4.0, 'REC_MAX': 3, 'REC_P99': 2, 'REC_MEAN': 0.5,
            'REC_BRIGHT': 0.10, 'REC_MIN_SHARE': 0.01, 'AIR_SHARE': 0.02, 'BG_MARGIN': 3,
            'HUE_CHROMA_MIN': 0.15, 'HUE_LUM_MIN': 16.0, 'HUE_CLASS_DEG': 40.0,
            'HUE_LEVEL': 128, 'HUE_SHARE': 0.002, 'HUE_DEG': 7.5, 'HUE_CHROMA': 0.8,
            'PEAK_TOP': 0.02, 'PEAK_HUE': 25.0, 'PEAK_CHROMA': 0.45, 'PEAK_HL_SHARE': 0.05,
            'PEAK_TRACED_MIN': 0.10, 'PEAK_TRACED_TOP': 0.25, 'PEAK_TRACED_CHROMA': 0.48,
            'PEAK_STEP': 4, 'GLINT_GROW': 15, 'GLINT_CLIP': 0.015, 'BODY_LEVEL': 24,
            'DISPLAY_DILATE': 3, 'UNLIT_SHARE': 0.0002, 'UNLIT_KEEP': 0.99,
            'BELOW_LEVEL': 138, 'BELOW_SHARE': 0.80, 'CONT_LEVEL': 0.55 * 255, 'CONT_TOL': 2,
            'INTERIOR_R': 1, 'AO_SHARE': 0.01, 'EDGE_BAND': 2,
            'EDGE_LO': 0.10, 'EDGE_HI': 0.90, 'EDGE_COUNT_TOL': 0.15, 'EDGE_OVER': 2.0,
            'EDGE_SLACK': 0.002, 'FOG_NEAR': 16, 'FOG_RATIO': 1.5, 'FOG_TOL': 3, 'OIT_LUM': 20.0,
            'OIT_RATIO': 0.5, 'SATURATED': 250,
        }
        for name, value in pinned.items():
            self.assertEqual(getattr(self.c, name), value, name)
        self.assertEqual(self.c.UNLIT_COLOURS, {
            'white lines': (255, 255, 255), 'navy lines': (0, 0, 89),
            'magenta lines and label': (255, 0, 255)})
        self.assertEqual(self.c.BELOW_LEVEL, int(round(255 * self.c.TONE_KNEE)) - 2)

    def testPlanAndKinds(self):
        c = self.c
        plan = c.l2_plan()
        names = {p[0] for p in plan}
        self.assertEqual(names, set(c.PROOFS) | set(c.GUARDS) | set(c.REPORTS))
        subjects = [(p[0], p[1]) for p in plan]
        self.assertEqual(len(subjects), len(set(subjects)))
        for check, subs in c.NEGATIVE.items():
            self.assertIn(check, c.PROOFS)
            for s in subs:
                self.assertIn((check, s), subjects)
                self.assertEqual(c.kind(check, s), 'proof')
        for check in c.PROOFS:
            self.assertTrue(c.NEGATIVE.get(check), check)       # every proof has a subject
        self.assertEqual(c.kind('haze683', 'haze683_rt0'), 'report')
        self.assertEqual(c.kind('display', 'display_knee_rt1'), 'report')
        self.assertEqual(c.kind('peak', 'metallic_core_rt1'), 'report')
        self.assertEqual(c.kind('peak', 'metallic_tint_rt1'), 'proof')
        traced = [p for p in plan if p[1] == 'metallic_tint_rt1'][0]
        self.assertIs(traced[2], c.check_peak_traced)
        self.assertEqual(traced[3], ['peak_metallic_i3_rt1', 'peak_metallic_i3_rt0'])
        self.assertEqual(c.kind('display', 'display_rt1'), 'guard')
        self.assertEqual(c.kind('peak', 'metallic_steps_rt0'), 'guard')
        # recover reads the six reps: a then b
        rec = {p[1]: p[3] for p in plan if p[0] == 'recover'}
        self.assertEqual(sorted(rec), sorted('rec_%s' % r for r in c.REC_REPS))
        self.assertEqual(rec['rec_tube_rt0'], ['rec_tube_a_rt0', 'rec_tube_b_rt0'])
        # the negative plan swaps in knee twins, and only those
        for check, subject, func, tags, kwargs in c.negative_plan():
            orig = [p for p in plan if (p[0], p[1]) == (check, subject)][0][3]
            for a, b in zip(orig, tags):
                self.assertEqual(b, c.knee_twin(a) if a in c.TWINNED else a)
        self.assertEqual(c.knee_twin('sweep_1p2_rt0'), 'sweep_1p2_knee_rt0')
        self.assertTrue(c.is_knee('sweep_1p2_knee_rt0'))
        self.assertFalse(c.is_knee('sweep_1p2_rt0'))
        with self.assertRaises(c.Usage):
            c.knee_twin('sweep_1p2_knee_rt0')

    def testModelHdrPassesEveryRow(self):
        results = self.c.run_plan(self.hdr, self.c.l2_plan())
        failed = [r for r in results if not r.ok]
        self.assertEqual(failed, [])

    def testModelKneeFailsExactlyTheProofs(self):
        c = self.c
        results = c.run_plan(self.knee, c.l2_plan())
        failed = {(r.check, r.subject) for r in results if not r.ok}
        want = {(k, s) for k, subs in c.NEGATIVE.items() for s in subs}
        # the recover guards (sticks, spheres, tube, rt1) fail on the knee too,
        # and display: exposure under a rig leaves the background (D3)
        want |= {('recover', 'rec_%s' % r) for r in c.REC_REPS}
        want.add(('display', 'display_rt1'))
        self.assertEqual(failed, want)

    def testModelReport(self):
        import io
        out = io.StringIO()
        rc, payload = self.c.model_report(out)
        self.assertEqual(rc, 0, out.getvalue()[-2000:])
        self.assertTrue(payload['ok'])
        self.assertEqual(payload['knee_passes'], [])
        self.assertLessEqual(payload['air_quantised_levels'], 1.0)
        self.assertIn('model: OK', out.getvalue())

    def testFromFilesAndTheCommandLine(self):
        c = self.c
        self.write_set(self.hdr)
        self.assertEqual(c.main(['l2', self.tmp]), 0)
        self.assertEqual(c.main(['negative', self.tmp]), 0)
        js = os.path.join(self.tmp, 'rows.json')
        self.assertEqual(c.main(['table', self.tmp, '--json', js]), 0)
        with open(js) as fh:
            rows = json.load(fh)
        self.assertEqual(len(rows['l2']), len(c.l2_plan()))
        self.assertEqual(len(rows['negative']), len(c.negative_plan()))
        self.assertTrue(all(r['ok'] for r in rows['l2'] + rows['negative']))
        self.assertEqual({r['kind'] for r in rows['l2']}, {'proof', 'guard', 'report'})
        # a knee twin that passes a proof is a failed negative control
        for tag in ('hue_x1_rt0', 'hue_x2p5_rt0'):
            save(self.tmp, c.knee_twin(tag), self.hdr[tag])
        results = {r.subject: r for r in c.run_negative(self.tmp)}
        self.assertFalse(results['hue_rt0'].ok)
        self.assertIn('PASSES', results['hue_rt0'].detail)
        self.assertEqual(c.main(['negative', self.tmp]), 1)
        # the round-0 situation: every tag rendered as the knee fails l2
        knee_dir = os.path.join(self.tmp, 'knee')
        os.makedirs(knee_dir)
        self.write_set(self.knee, knee_dir)
        self.assertEqual(c.main(['l2', knee_dir]), 1)
        self.assertEqual(c.main(['negative', knee_dir]), 0)
        # usage
        self.assertEqual(c.main(['l2', self.tmp, '--checks', 'bogus']), 2)
        self.assertEqual(c.main(['l2', os.path.join(self.tmp, 'nope')]), 2)
        self.assertEqual(c.main([]), 2)
        self.assertEqual(c.main(['l2', self.tmp, '--checks', 'sweep,hue']), 0)

    def testMissingImages(self):
        c = self.c
        save(self.tmp, 'hue_x1_rt0', self.hdr['hue_x1_rt0'])
        plan = [p for p in c.l2_plan() if p[0] == 'hue']
        r = c.run_plan(self.tmp, plan)[0]
        self.assertFalse(r.ok)
        self.assertIn('missing hue_x2p5_rt0.png', r.detail)
        # a missing image never counts as a failed proof
        neg = c.run_negative(self.tmp)
        self.assertTrue(all(not r.ok for r in neg))

    def testExportReadsAlpha(self):
        c = self.c
        save(self.tmp, 'export_rt0', self.hdr['export_rt0'])
        save(self.tmp, 'export_knee_rt0', self.hdr['export_knee_rt0'])
        plan = [p for p in c.l2_plan() if p[1] == 'export_rt0']
        self.assertTrue(c.run_plan(self.tmp, plan)[0].ok)
        # an opaque export (no alpha) fails: no transparent background
        rgb = self.hdr['export_rt0'][..., :3]
        save(self.tmp, 'export_rt0', rgb)
        save(self.tmp, 'export_knee_rt0', rgb)
        self.assertFalse(c.run_plan(self.tmp, plan)[0].ok)
        # an alpha that moves fails
        bad = self.hdr['export_rt0'].copy()
        bad[0, 0, 3] = 17
        self.assertFalse(c.check_export(self.hdr['export_knee_rt0'], bad).ok)

    def args(self, subject):
        p = [p for p in self.c.l2_plan() if p[1] == subject][0]
        return [self.hdr[t] for t in p[3]], p[2], p[4]

    def assertBreaks(self, subject, index, change):
        images, func, kwargs = self.args(subject)
        self.assertTrue(func(*images, subject=subject, **kwargs).ok, subject)
        images = [i.copy() for i in images]
        change(images[index])
        r = func(*images, subject=subject, **kwargs)
        self.assertFalse(r.ok, '%s still passes: %s' % (subject, r.detail))

    def testGuardsFailOnBrokenImages(self):
        c = self.c

        def first(mask):
            ys, xs = numpy.nonzero(mask)
            return ys[0], xs[0]

        def bump_bg(img):
            img[0, 0] = (200, 200, 200)

        # display: the background moves with exposure (#13's semantics)
        self.assertBreaks('display_rt1', 0, lambda img: img.__setitem__((0, 0), (150, 150, 150)))
        # unlit: an overlay colour changes (one pixel is an anti-aliasing
        # allowance, UNLIT_KEEP; every pixel of the colour is not)
        def overlay(img):
            m = (img == numpy.array([255, 0, 255])).all(axis=-1)
            img[m] = (250, 0, 250)
        self.assertBreaks('unlit_rt1', 1, overlay)
        def one_overlay(img):
            m = (img == numpy.array([255, 0, 255])).all(axis=-1)
            img[first(m)] = (250, 0, 250)
        images, func, kwargs = self.args('unlit_rt1')
        broken = images[1].copy()
        one_overlay(broken)
        self.assertTrue(func(images[0], broken, **kwargs).ok)
        self.assertBreaks('unlit_rt1', 1, bump_bg)
        # below_knee: the dim pixels off by one level (a curve that is not
        # the identity under the knee); one pixel is allowed (AO_SHARE)
        def dim(img):
            m = (img.max(axis=-1) > 20) & (img.max(axis=-1) < 120)
            img[m] += 1
        self.assertBreaks('below_i04_rt0', 1, dim)
        def one_dim(img):
            m = (img.max(axis=-1) > 20) & (img.max(axis=-1) < 120)
            img[first(m)] += 1
        images, func, kwargs = self.args('below_i04_rt0')
        broken = images[1].copy()
        one_dim(broken)
        self.assertTrue(func(images[0], broken, **kwargs).ok)
        # continuity: the dim pixels off by three
        def dim3(img):
            m = (img.max(axis=-1) > 20) & (img.max(axis=-1) < 120)
            img[m] += 3
        self.assertBreaks('cont_softbox_rt0', 1, dim3)
        # peak traced: the reflections go white
        def white(img):
            geo = img.max(axis=-1) > 0
            img[geo] = img[geo].max(axis=-1, keepdims=True)
        self.assertBreaks('metallic_tint_rt1', 0, white)
        # edges: tone after the resolve brightens the partial pixels
        def fringe(img):
            geo = img.max(axis=-1) > 0
            rim = geo & c.dilate(~geo, 1)
            img[rim] = numpy.minimum(255, img[rim] * 2 + 40)
        self.assertBreaks('edges_rt0', 1, fringe)
        # fog: the background is toned
        self.assertBreaks('fog_rt1', 1, lambda img: img.__setitem__((0, 0), (250, 250, 250)))
        # oit: a hole where the knee is lit
        def hole(img):
            m = img.max(axis=-1) > 100
            img[first(m)] = 0
        self.assertBreaks('oit_rt0', 1, hole)
        # shadows: the colours are gone
        def grey(img):
            img[...] = img.mean(axis=-1, keepdims=True).astype(img.dtype)
        self.assertBreaks('shadow_cross_rt0', 1, grey)
        # glints: clipped, no growth, a body glint that clips
        def clip(img):
            img[img.max(axis=-1) > 120] = 255
        self.assertBreaks('glass_clip_rt0', 0, clip)
        self.assertBreaks('glass_body_rt0', 0, clip)
        images, func, kwargs = self.args('glass_growth_rt0')
        self.assertFalse(func(images[0], images[1], images[0], images[1]).ok)
        # peak steps: no rise from i1 to i2
        images, func, kwargs = self.args('metallic_steps_rt0')
        self.assertFalse(func(images[0], images[0], images[2]).ok)
        # sizes must agree
        self.assertFalse(c.check_oit(self.hdr['oit_rt0'], self.hdr['oit_rt0'][:10]).ok)

    def testReportsNeverFail(self):
        c = self.c
        plan = [p for p in c.l2_plan() if c.kind(p[0], p[1]) == 'report']
        black = {t: numpy.zeros_like(self.hdr[t]) for p in plan for t in p[3]}
        for r in c.run_plan(black, plan):
            self.assertTrue(r.ok, r)
            self.assertTrue(r.detail.startswith('(report)'), r)


# --- the scene files -------------------------------------------------------------------------

def l2_expected(tag):
    """What a lighting_624.json tag stands for, written out from the tag:
    {'exposure', 'knee', 'haze', 'dust', 'lights': {name: intensity} or None
    (a preset), 'rt', 'bg_white', 'depth_cue', 'tonemap', 'opaque'}."""
    base, rt = tag_parts(tag)
    knee = base.endswith('_knee')
    if knee:
        base = base[:-len('_knee')]
    e = {'exposure': 1.0, 'knee': knee, 'haze': 0.0, 'dust': 0.0, 'rt': rt, 'bg_white': False,
         'depth_cue': 0, 'tonemap': 0, 'opaque': 1, 'lights': None}
    m = re.match(r'^sweep_([0-9p]+)(_e05)?$', base)
    if m:
        e['lights'] = {'spot': float(m.group(1).replace('p', '.'))}
        if m.group(2):
            e['exposure'] = 0.5
    m = re.match(r'^rec_(surface|cartoon|sticks|spheres|tube|air)_([ab])$', base)
    if m:
        e['lights'] = {'spot': 3.5 if m.group(2) == 'a' else 2.0}
        e['exposure'] = 4.0 / 7.0 if m.group(2) == 'a' else 1.0
        if m.group(1) == 'air':
            e['haze'] = 0.3
    m = re.match(r'^hue_x(1|2p5)$', base)
    if m:
        x = float(m.group(1).replace('p', '.'))
        e['lights'] = {'key': 1.6 * x, 'rim': 1.6 * x}
    m = re.match(r'^peak_(metallic|plastic)_i([123])(_e067|_e05)?$', base)
    if m:
        e['lights'] = {'key': float(m.group(2))}
        if m.group(3):
            e['exposure'] = 2.0 / 3.0 if m.group(3) == '_e067' else 0.5
    m = re.match(r'^glass(_dark)?_i([13])(_e033)?_hl([01])$', base)
    if m:
        i = float(m.group(2))
        e['lights'] = {'key': i, 'rim': 0.8 * i}
        if m.group(3):
            e['exposure'] = 1.0 / 3.0
    if base.startswith('glass_body_i3'):
        e['lights'] = {'key': 3.0}
    if base in ('frosted_i3', 'jelly_i3'):
        e['lights'] = {'key': 3.0, 'rim': 2.4}
    if base == 'shadow_cross':
        e['lights'] = {'red': 3.0, 'blue': 3.0}
    m = re.match(r'^display_(e06|e1|nocartoon)$', base)
    if m:
        e['lights'] = {'key': 3.0, 'rim': 2.4}
        e['bg_white'] = True
        e['exposure'] = 0.6 if m.group(1) == 'e06' else 1.0
    if base == 'unlit':
        e['lights'] = {'key': 3.0, 'rim': 2.4}
    if base == 'below_i04':
        e['lights'] = {'key': 0.4, 'rim': 0.4}
    if base == 'edges':
        e['lights'] = {'back': 3.5, 'front': 0.3}
    if base == 'fog':
        e['lights'] = {'key': 3.0, 'rim': 2.4}
        e['bg_white'] = True
        e['depth_cue'] = 1
    if base == 'export':
        e['lights'] = {'key': 3.5, 'rim': 2.8}
        e['opaque'] = 0
    if base == 'oit':
        e['lights'] = {'key': 3.5, 'rim': 2.8}
    m = re.match(r'^haze683_(e1|e05|noair)$', base)
    if m:
        e['exposure'] = 0.5 if m.group(1) == 'e05' else 1.0
        if m.group(1) != 'noair':
            e['haze'], e['dust'] = 0.35, 0.6
        e['preset'] = 'three_point'
    m = re.match(r'^cont_(three_point|softbox|rembrandt|neon)$', base)
    if m:
        e['preset'] = m.group(1)
    if base == 'aces':
        e['lights'] = {'spot': 3.5}
        e['tonemap'] = 1
    if e['lights'] is None and 'preset' not in e:
        raise AssertionError('no expectation for %s' % tag)
    return e


@unittest.skipUnless(HAVE_CHECKOUT, 'needs a RayMol checkout (scripts/lighting)')
class TestSceneFiles(testing.PyMOLTestCase):

    @classmethod
    def setUpClass(cls):
        assert_present(os.path.join(LIGHTING, 'render.py'),
                       os.path.join(LIGHTING, 'check_hdr.py'), PDB, *FILES.values())
        cls.render = load_module('lighting_render', 'render.py')
        cls.jobs = {k: cls.render.scene_file_jobs(v) for k, v in FILES.items()}
        cls.specs = {}
        for k, v in FILES.items():
            with open(v) as handle:
                cls.specs[k] = json.load(handle)
        cls.scenes = {k: {s['tag']: s for s in spec['scenes']} for k, spec in cls.specs.items()}

    def setUp(self):
        super(TestSceneFiles, self).setUp()
        self.original = (cmd.set_lights, cmd.get_lights)
        self.tmp = tempfile.mkdtemp(prefix='l624s')
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def tearDown(self):
        restore_shims()
        cmd.set_lights(None)
        self.assertIs(cmd.set_lights, self.original[0])
        self.assertIs(cmd.get_lights, self.original[1])
        super(TestSceneFiles, self).tearDown()

    def run_job(self, job, times=2):
        out = os.path.join(self.tmp, 'out')
        self.render.write_scripts(ROOT, out, [job])
        marker = self.render.marker_path(out, job.tag)
        if os.path.exists(marker):
            os.remove(marker)
        for _ in range(times):
            cmd.run(self.render.script_path(out, job.tag))
        return marker

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

    def hdr_setting(self):
        """metal_light_hdr's value, or None on a build without it (before part 2)."""
        if 'metal_light_hdr' not in cmd.setting.get_name_list():
            return None
        return cmd.get_setting_int('metal_light_hdr')

    def testSceneFilesLoad(self):
        self.assertEqual(len(self.jobs['l2']), 122)
        self.assertEqual(len(self.jobs['regress']), 31)
        for which, spec in self.specs.items():
            self.assertEqual(spec['rig'], 'on', which)
            self.assertIsNone(spec['base'], which)
            self.assertIn('#624', spec['comment'])
            for job in self.jobs[which]:
                self.assertEqual(job.size, (1280, 720), job.tag)
                tag_parts(job.tag)
        for job in self.jobs['l2']:
            self.assertTrue(job.extra[-1].startswith(RIG_LINE), job.tag)
            self.assertEqual(job.rig, 'on', job.tag)

    def testEveryCheckHasItsImages(self):
        check = load_module('lighting_check_hdr', 'check_hdr.py')
        tags = set(self.scenes['l2'])
        self.assertEqual(sorted(tags - set(check.scene_tags())), [])
        self.assertEqual(sorted(set(check.scene_tags()) - tags), [])
        for t in check.INFORMATIONAL:
            self.assertIn(t, tags)

    def testKneeTwins(self):
        check = load_module('lighting_check_hdr', 'check_hdr.py')
        scenes = self.scenes['l2']
        twins = {t for t in scenes if check.is_knee(t)}
        self.assertEqual(twins, {check.knee_twin(t) for t in check.TWINNED})
        for tag in check.TWINNED:
            hdr, knee = scenes[tag], scenes[check.knee_twin(tag)]
            self.assertEqual(knee['lines'], [KNEE_LINE] + hdr['lines'], tag)
            self.assertEqual({k: v for k, v in knee.items() if k not in ('tag', 'lines')},
                             {k: v for k, v in hdr.items() if k not in ('tag', 'lines',
                                                                         'comment')}, tag)
            self.assertNotIn(KNEE_LINE, hdr['lines'], tag)

    def testHdrSettingOnlyThroughOpt(self):
        """metal_light_hdr exists from #624 part 2: every line that names it
        goes through _l624_opt, so master and a build before part 2 render
        both files (the knee twins then render as the knee anyway)."""
        values = {}
        for which, spec in self.specs.items():
            lines = list(spec['extra']) + [l for s in spec['scenes'] for l in s['lines']]
            for line in lines:
                for m in re.finditer('metal_light_hdr', line):
                    self.assertTrue(line[:m.start()].endswith("_l624_opt('"),
                                    '%s: not through _l624_opt: %s' % (which, line))
                    values.setdefault(which, set()).add(
                        re.match(r"metal_light_hdr', (\d+)\)", line[m.start():]).group(1))
            self.assertIn("_l624_opt = lambda name, value: cmd.set(name, value) if name in "
                          "cmd.setting.get_name_list() else None", spec['extra'])
        self.assertEqual(values['l2'], {'2'})
        self.assertEqual(values['regress'], {'1', '2', '7'})

    def testRecoverPairsAreTheSameLight(self):
        scenes = self.scenes['l2']
        pairs = [(t, t.replace('_a_', '_b_')) for t in scenes if re.match(r'^rec_.*_a_', t)]
        self.assertEqual(len(pairs), 10)         # six reps, the air, three knee twins
        for a, b in pairs:
            la, lb = scenes[a]['lines'], scenes[b]['lines']
            self.assertEqual(len(la), len(lb))
            diff = [(x, y) for x, y in zip(la, lb) if x != y]
            self.assertEqual(len(diff), 2, a)
            (ea, eb), (ra, rb) = diff
            exp_a = re.match(r"^cmd\.set\('metal_exposure', (.*)\)$", ea).group(1)
            exp_b = re.match(r"^cmd\.set\('metal_exposure', (.*)\)$", eb).group(1)
            int_a = float(re.search(r", ([0-9.]+)\)\], ambient=0\.0", ra).group(1))
            int_b = float(re.search(r", ([0-9.]+)\)\], ambient=0\.0", rb).group(1))
            self.assertEqual(re.sub(r", [0-9.]+\)\], ambient", '', ra),
                             re.sub(r", [0-9.]+\)\], ambient", '', rb), a)
            self.assertEqual((int_a, int_b), (3.5, 2.0))
            self.assertAlmostEqual(eval(exp_a) * int_a, eval(exp_b) * int_b, places=12)

    def testRegressionFileRunsOnMaster(self):
        spec = self.specs['regress']
        text = '\n'.join(list(spec['extra']) + [l for s in spec['scenes'] for l in s['lines']])
        self.assertIsNone(re.search(r'(?<![A-Za-z0-9])_light_', text))
        for word in ('light_tone', 'get_light_hdr', 'light_hdr(', 'cmd.lights('):
            self.assertNotIn(word, text)
        rigs = {s['tag']: s.get('rig', spec['rig']) for s in spec['scenes']}
        for tag, rig in rigs.items():
            want = ('none' if tag.startswith('norig_') else
                    'off' if tag.startswith(('rigoff_', 'toggle_')) else 'on')
            self.assertEqual(rig, want, tag)
        tags = set(rigs)
        for rep in ('cartoon', 'surface', 'sticks', 'spheres', 'tube', 'oit50', 'glass',
                    'metallic', 'shadow', 'air'):
            for rt in (0, 1):
                self.assertIn('knee_%s_rt%d' % (rep, rt), tags)
        for tag in ('knee_airhalf_rt0', 'knee_tonemap_rt0', 'norig_hdr1_rt0', 'norig_hdr1_rt1',
                    'norig_hdrjunk_rt0', 'rigoff_hdr1_rt0', 'rigoff_hdr1_rt1',
                    'norig_tonemap_rt0', 'toggle_surface_rt0', 'toggle_surface_rt1',
                    'flip_knee_rt0'):
            self.assertIn(tag, tags)
        # every knee tag picks the knee before anything else
        for s in spec['scenes']:
            if s['tag'].startswith('knee_'):
                self.assertEqual(s['lines'][0], KNEE_LINE, s['tag'])

    def testEveryL2ScriptRunsInProcess(self):
        ran = 0
        for job in self.jobs['l2']:
            ran += 1
            marker = self.run_job(job)
            self.assertIsNone(self.render.check_marker(marker, job.tag, 'on'), job.tag)
            self.assertCamera(job.tag)
            e = l2_expected(job.tag)
            rig = cmd.get_lights()
            self.assertIs(rig['enabled'], True, job.tag)
            self.assertFramed(rig, job.tag)
            self.assertEqual(rig['classic'], 0.0, job.tag)
            if e['lights'] is not None:
                got = {l['name']: l['intensity'] for l in rig['lights']}
                self.assertEqual(sorted(got), sorted(e['lights']), job.tag)
                for name, value in e['lights'].items():
                    self.assertAlmostEqual(got[name], value, places=5, msg=job.tag)
            else:
                from pymol import lighting_commands
                want = [l['name'] for l in lighting_commands.PRESETS[e['preset']][2]]
                self.assertEqual([l['name'] for l in rig['lights']], want, job.tag)
            self.assertAlmostEqual(rig['air']['haze'], e['haze'], places=6, msg=job.tag)
            self.assertAlmostEqual(rig['air']['dust'], e['dust'], places=6, msg=job.tag)
            self.assertAlmostEqual(cmd.get_setting_float('metal_exposure'), e['exposure'],
                                   places=6, msg=job.tag)
            hdr = self.hdr_setting()
            if hdr is not None:
                self.assertEqual(hdr, 2 if e['knee'] else 0, job.tag)
            self.assertEqual(cmd.get_setting_int('metal_raytrace'), e['rt'], job.tag)
            self.assertEqual(cmd.get_setting_int('depth_cue'), e['depth_cue'], job.tag)
            self.assertEqual(cmd.get_setting_int('metal_tonemap'), e['tonemap'], job.tag)
            self.assertEqual(cmd.get_setting_int('ray_opaque_background'), e['opaque'],
                             job.tag)
            bg = cmd.get_color_tuple(cmd.get_setting_tuple('bg_rgb')[1][0])
            self.assertEqual(tuple(bg), (1.0, 1.0, 1.0) if e['bg_white'] else (0.0, 0.0, 0.0),
                             job.tag)
            self.assertAlmostEqual(cmd.get_setting_float('metal_light_air_time'), 2.0,
                                   places=6)
            self.assertEqual(cmd.get_setting_int('metal_light_air_resolution'), 1)
            base, _ = tag_parts(job.tag)
            if base.startswith('peak_') or re.match(r'^glass(_dark)?_i[13]_', base):
                self.assertEqual(cmd.get_setting_int('material_env'), 2, job.tag)
            if re.match(r'^glass(_dark)?_i[13]_', base):
                self.assertEqual(rig['ambient'], 0.0, job.tag)     # the recover pair
            restore_shims()
        self.assertEqual(ran, 122)

    def testEveryRegressionScriptRunsInProcess(self):
        import tempfile as tf
        for job in self.jobs['regress']:
            scratch = os.path.join(tf.gettempdir(), 'l624_regress_%s.png' % job.tag)
            if os.path.exists(scratch):
                os.remove(scratch)
            marker = self.run_job(job)
            self.assertIsNone(self.render.check_marker(marker, job.tag, job.rig), job.tag)
            self.assertCamera(job.tag)
            base, rt = tag_parts(job.tag)
            self.assertEqual(cmd.get_setting_int('metal_raytrace'), rt, job.tag)
            hdr = self.hdr_setting()
            if base.startswith('knee_') or base == 'flip_knee':
                rig = cmd.get_lights()
                self.assertIs(rig['enabled'], True, job.tag)
                self.assertFramed(rig, job.tag)
                self.assertEqual([l['name'] for l in rig['lights']], ['spot', 'fill'], job.tag)
                if hdr is not None:
                    self.assertEqual(hdr, 2, job.tag)
                if base.startswith('knee_air'):
                    self.assertAlmostEqual(rig['air']['haze'], 0.3, places=6)
                    self.assertEqual(cmd.get_setting_int('metal_light_air_resolution'),
                                     2 if base == 'knee_airhalf' else 1, job.tag)
                else:
                    self.assertEqual(rig['air']['haze'], 0.0, job.tag)
                self.assertEqual([l['shadow'] for l in rig['lights']],
                                 [base in ('knee_shadow', 'knee_air', 'knee_airhalf'), False],
                                 job.tag)
            elif base.startswith('norig_'):
                self.assertIsNone(cmd.get_lights(), job.tag)
                if hdr is not None:
                    self.assertEqual(hdr, 7 if base == 'norig_hdrjunk' else 1, job.tag)
            elif base.startswith(('rigoff_', 'toggle_')):
                rig = cmd.get_lights()
                self.assertIs(rig['enabled'], False, job.tag)
                if hdr is not None:
                    self.assertEqual(hdr, 1, job.tag)
            else:
                self.fail('no expectation for %s' % job.tag)
            if base in ('toggle_surface', 'flip_knee'):
                # the forced frame was drawn before the switch or the rig changed
                self.assertTrue(os.path.isfile(scratch), job.tag)
                os.remove(scratch)
            else:
                self.assertFalse(os.path.exists(scratch), job.tag)
            tonemap = base in ('knee_tonemap', 'norig_tonemap')
            self.assertEqual(cmd.get_setting_int('metal_tonemap'), int(tonemap), job.tag)
            self.assertAlmostEqual(cmd.get_setting_float('metal_exposure'),
                                   0.7 if tonemap else 1.0, places=6, msg=job.tag)
            restore_shims()


# --- time_hdr.py ------------------------------------------------------------------------------

@unittest.skipUnless(HAVE_CHECKOUT, 'needs a RayMol checkout (scripts/lighting)')
class TestTimeHdr(testing.PyMOLTestCase):

    @classmethod
    def setUpClass(cls):
        assert_present(os.path.join(LIGHTING, 'time_hdr.py'),
                       os.path.join(LIGHTING, 'time_air.py'),
                       os.path.join(LIGHTING, 'time_shadows.py'), PDB)
        cls.t = load_module('lighting_time_hdr', 'time_hdr.py')
        cls.render = cls.t.ts.load_render()

    def setUp(self):
        super(TestTimeHdr, self).setUp()
        self.tmp = tempfile.mkdtemp(prefix='l624t')
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def tearDown(self):
        vars(cmd).pop('_ts_runs', None)
        cmd.set_lights(None)
        super(TestTimeHdr, self).tearDown()

    def write(self, name, text):
        path = os.path.join(self.tmp, name)
        with open(path, 'w') as fh:
            fh.write(text)
        return path

    def testReusesTimeShadowsAndTimeAir(self):
        t = self.t
        self.assertIs(t.ts, t.ta.ts)
        self.assertEqual(t.LINES_PER_FRAME, 2)
        self.assertEqual(t.PROBE, (64, 64, 0))
        self.assertIs(t.Refusal, t.ts.Refusal)
        with open(os.path.join(LIGHTING, 'time_hdr.py')) as fh:
            src = fh.read()
        for name in ('class Tailer', 'def launch_env', 'def check_autocmd', 'def run_once',
                     'def structure_path', 'def summarise_run', 'def frame_times',
                     'def air_lines', 'def parse_gpu_ms'):
            self.assertNotIn(name, src)

    def testConfigMatrix(self):
        t = self.t
        self.assertEqual([c.tag for c in t.configs()],
                         ['%s_%s' % (s, v) for s in ('1rx1', '1ao6', '7k00')
                          for v in ('s3', 's3_knee', 's3_air', 's3_air_knee')])
        self.assertEqual(t.VARIANTS, {'s3': (False, False), 's3_knee': (True, False),
                                      's3_air': (False, True), 's3_air_knee': (True, True)})
        self.assertEqual(t.PAIRS, (('s3', 's3_knee'), ('s3_air', 's3_air_knee')))
        self.assertEqual((t.HDR_EXPECT, t.HDR_FLAG), (0.02, 0.05))
        self.assertEqual([c.tag for c in t.toggle_configs()],
                         ['1rx1_on_hdr', '1rx1_on_knee', '1rx1_flip', '1rx1_steady'])
        with self.assertRaises(t.Refusal):
            t.HdrConfig('1rx1', 'bogus')
        with self.assertRaises(t.Refusal):
            t.ToggleConfig('1rx1', 'bogus')

    def testExportScripts(self):
        t = self.t
        mp4 = os.path.join(self.tmp, 'x.mp4')
        start = os.path.join(self.tmp, 'x.start.json')
        base = t.ts.script_text(self.render, t.ts.Config('1rx1', 's3'), PDB, mp4, start, 4)
        same = t.script_text(self.render, t.HdrConfig('1rx1', 's3'), PDB, mp4, start, 4)
        # s3 is time_shadows' own script (the header and the tag stamp aside)
        self.assertEqual([l for l in base.split('\n')[1:] if "'tag'" not in l],
                         [l for l in same.split('\n')[1:] if "'tag'" not in l])
        for variant, (knee, air) in t.VARIANTS.items():
            text = t.script_text(self.render, t.HdrConfig('1rx1', variant), PDB, mp4, start, 4)
            compile(text, variant, 'exec')
            self.assertEqual(t.KNEE_LINE in text, knee, variant)
            self.assertEqual("rig['air'] = %r" % (t.ta.AIR,) in text, air, variant)
            self.assertEqual("cmd.set('metal_light_air_resolution', 1)" in text, air, variant)
            if knee:
                self.assertLess(text.index(t.KNEE_LINE), text.index('cmd.set_lights(rig)'))
            self.assertIn('if cmd._ts_runs == 2:', text)
            self.assertEqual(text.count('cmd.movie_export('), 1)
            self.assertIn("'tag': '1rx1_%s'" % variant, text)
            self.assertIn('ray=1', text)

    def testExportQueuedOncePerProcess(self):
        t = self.t
        mp4 = os.path.join(self.tmp, 'x.mp4')
        start = os.path.join(self.tmp, 'x.start.json')
        script = self.write('x.py', t.script_text(self.render, t.HdrConfig('1rx1', 's3_air_knee'),
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
        self.assertEqual(calls, [((mp4, 1920, 1080), {'quality': 'standard', 'ray': 1})])
        with open(start) as fh:
            self.assertEqual(json.load(fh)['tag'], '1rx1_s3_air_knee')
        rig = cmd.get_lights()
        self.assertEqual([l['shadow'] for l in rig['lights']], [True, True, True])
        self.assertAlmostEqual(rig['air']['haze'], 0.3, places=6)
        if 'metal_light_hdr' in cmd.setting.get_name_list():
            self.assertEqual(cmd.get_setting_int('metal_light_hdr'), 2)

    def testToggleScripts(self):
        t = self.t
        mp4 = os.path.join(self.tmp, 'x.mp4')
        start = os.path.join(self.tmp, 'x.start.json')
        texts = {g: t.toggle_script_text(self.render, t.ToggleConfig('1rx1', g), PDB, mp4,
                                         start, 24, 12) for g in t.TOGGLES}
        for g, text in texts.items():
            compile(text, g, 'exec')
            self.assertIn('if cmd._ts_runs == 2:', text)
            self.assertIn("cmd.movie_export(%r, 1920, 1080, quality='standard', ray=1)" % mp4,
                          text)
            self.assertIn("'tag': '1rx1_%s'" % g, text)
        on = texts['on_hdr']
        self.assertIn("    rig['enabled'] = False\n", on)
        self.assertNotIn(t.KNEE_LINE, on)
        self.assertGreater(on.index("cmd.mappend(12, 'lights on')"), on.index('cmd.frame(1)'))
        self.assertIn(t.KNEE_LINE, texts['on_knee'])
        flip = texts['flip']
        self.assertIn("cmd.mappend(12, 'set metal_light_hdr, 2')", flip)
        self.assertIn("cmd.mappend(18, 'set metal_light_hdr, 1')", flip)
        self.assertIn(t.HDR_SET, flip)
        self.assertNotIn('mappend', texts['steady'])
        # the change back is dropped when it falls outside the movie
        short = t.toggle_script_text(self.render, t.ToggleConfig('1rx1', 'flip'), PDB, mp4,
                                     start, 14, 12)
        self.assertNotIn('set metal_light_hdr, 1', short)
        with self.assertRaises(t.Refusal):
            t.toggle_script_text(self.render, t.ToggleConfig('1rx1', 'flip'), PDB, mp4, start,
                                 24, 1)
        self.assertEqual((t.default_at(24), t.default_at(2), t.default_at(3)), (12, 2, 2))

    def testToggleScriptInProcess(self):
        t = self.t
        mp4 = os.path.join(self.tmp, 'x.mp4')
        start = os.path.join(self.tmp, 'x.start.json')
        script = self.write('on.py', t.toggle_script_text(
            self.render, t.ToggleConfig('1rx1', 'on_knee'), PDB, mp4, start, 6, 3))
        calls, appended = [], []
        original, mappend = cmd.movie_export, cmd.mappend
        cmd.movie_export = lambda *a, **k: calls.append((a, k))

        def record(frame, command, *a, **k):
            appended.append((int(frame), command))
            return mappend(frame, command, *a, **k)
        cmd.mappend = record
        try:
            for _ in range(3):
                cmd.run(script)
        finally:
            cmd.movie_export, cmd.mappend = original, mappend
        self.assertEqual(calls, [((mp4, 1920, 1080), {'quality': 'standard', 'ray': 1})])
        self.assertEqual(appended, [(3, 'lights on')])
        self.assertEqual(cmd.count_frames(), 6)
        self.assertIs(cmd.get_lights()['enabled'], False)       # until frame 3
        if 'metal_light_hdr' in cmd.setting.get_name_list():
            self.assertEqual(cmd.get_setting_int('metal_light_hdr'), 2)

    def testAutocmdRefusals(self):
        t = self.t
        for bad in ('run a.py; run b.py', 'run /x/orient/a.py', 'run /x/reset.py'):
            with self.assertRaises(t.Refusal):
                t.ts.check_autocmd(bad)
        self.assertEqual(t.main(['--mode', 'toggle', '--dry-run', '--out',
                                 os.path.join(self.tmp, 'orient')]), 2)

    def testTogglePerFrame(self):
        t = self.t
        line = 'offscreen 1920x1080 gpu_ms=%.1f'
        stamped = [(0.0, 'probe line'), (0.5, 'offscreen 64x64 gpu_ms=1.0')]
        clock, frames, at = 10.0, 8, 4
        for k in range(1, frames + 1):
            step = 3.0 if k == at else 1.0
            clock += step / 2
            stamped.append((clock, line % 5.0))
            clock += step / 2
            stamped.append((clock, line % 6.0))
        done = t.toggle_frames(stamped, frames)
        self.assertEqual(len(done), frames)
        self.assertEqual([ms for _, ms in done], [11.0] * frames)      # 2 lines a frame
        s = t.toggle_summary(done, at, frames)
        self.assertIsNone(s['wall'][0])
        self.assertAlmostEqual(s['median'], 1.0)
        self.assertAlmostEqual(s['wall_at'], 3.0)
        self.assertAlmostEqual(s['spike'], 3.0)
        self.assertIsNone(s['back'])                       # 4 + 6 > 8
        s = t.toggle_summary(done, 2, frames)
        self.assertEqual(s['back'], 8)
        text = t.toggle_table({'1rx1_flip': s})
        self.assertIn('| 1rx1_flip | 8 |', text)
        self.assertIn('spike back', text)
        # too few lines: fewer frames, never a made-up one
        self.assertEqual(len(t.toggle_frames(stamped[:7], frames)), 2)

    def testSummaryTableAndFlags(self):
        t = self.t
        C = t.HdrConfig

        def runs(*s):
            return [{'s_per_frame': v, 's_per_frame_mp4': v,
                     'gpu_ms_median': None if v is None else 10.0 * v} for v in s]
        results = {
            '1rx1_s3': {'config': C('1rx1', 's3'), 'runs': runs(1.06, 1.07), 'atoms': 10},
            '1rx1_s3_knee': {'config': C('1rx1', 's3_knee'), 'runs': runs(1.0), 'atoms': 10},
            '1rx1_s3_air': {'config': C('1rx1', 's3_air'), 'runs': runs(1.01), 'atoms': 10},
            '1rx1_s3_air_knee': {'config': C('1rx1', 's3_air_knee'), 'runs': runs(1.0),
                                 'atoms': 10},
        }
        s = t.summarise(results)
        self.assertAlmostEqual(s['1rx1_s3']['delta_vs_knee'], 0.065)
        self.assertAlmostEqual(s['1rx1_s3_air']['delta_vs_knee'], 0.01)
        self.assertIsNone(s['1rx1_s3_knee']['delta_vs_knee'])
        notes = t.flags(s)
        self.assertEqual(len(notes), 1)
        self.assertIn('FLAG 1rx1_s3:', notes[0])
        text = t.table(s, ['1rx1_s3', '1rx1_s3_knee'])
        self.assertIn('| vs knee |', text)
        self.assertIn('+6.5%', text)

    def testDryRuns(self):
        t = self.t
        out = os.path.join(self.tmp, 'e')
        self.assertEqual(t.main(['--mode', 'export', '--out', out, '--dry-run', '--runs', '1',
                                 '--only', '1rx1_s3,1rx1_s3_air_knee']), 0)
        self.assertEqual(sorted(os.listdir(os.path.join(out, '_work'))),
                         ['1rx1_s3_air_knee_r1.py', '1rx1_s3_r1.py'])
        self.assertEqual(t.main(['--mode', 'export', '--out', out, '--dry-run',
                                 '--only', '1rx1_s0']), 2)                # not in the matrix
        self.assertEqual(t.main(['--mode', 'export', '--out', out]), 2)   # no --app
        out = os.path.join(self.tmp, 'g')
        self.assertEqual(t.main(['--mode', 'toggle', '--out', out, '--dry-run']), 0)
        self.assertEqual(sorted(os.listdir(os.path.join(out, '_work'))),
                         sorted('1rx1_%s_r1.py' % g for g in t.TOGGLES))
        self.assertEqual(t.main(['--mode', 'toggle', '--out', out, '--dry-run', '--frames', '2',
                                 '--only', '1rx1_flip']), 0)
        self.assertEqual(t.main(['--mode', 'toggle', '--out', out, '--dry-run', '--at', '1']), 2)
        self.assertEqual(t.main(['--mode', 'toggle', '--out', out, '--dry-run', '--only',
                                 'x']), 2)


if __name__ == '__main__':
    unittest.main()
