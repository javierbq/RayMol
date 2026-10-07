"""The light-rig render evidence (#613): scene files and pixel checks.

L2 for #613 renders every lit path with a 2-light rig and decides with
scripts/lighting/check_lit.py. CI has no GPU, so this pins what it can:

* the five scripts/lighting/scenes/lighting_613*.json files load with the
  frozen harness, and are complete: every lit image has its dark reference
  (the same rig at intensity 0), every parameter check its images, the two
  default-path files differ only in "rig", and every no-rig decision-15
  render (lighting_613_d15.json) has its dark twin and the same classic
  terms;
* every scene script runs in-process (the way the app runs it) and leaves
  the rig its scene asks for, including through the cmd.set_lights shim the
  pairs and params files install, which is restored afterwards;
* check_lit.py's decisions on synthetic images: a pass and a fail for every
  check, including the negative control (dark equal to lit fails).

Source-reading, so skipped (not passed) outside a repo checkout, which is
decided by one file every checkout has; in a checkout the ticket's own files
are required, so renaming or removing one fails instead of skipping. The
pixel checks are skipped without numpy or Pillow.

Runs on a RayMol build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/lighting_check.py
"""
import contextlib
import math
import importlib.util
import io
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
    'pairs': os.path.join(SCENES, 'lighting_613.json'),
    'params': os.path.join(SCENES, 'lighting_613_params.json'),
    'default': os.path.join(SCENES, 'lighting_613_default.json'),
    'default_off': os.path.join(SCENES, 'lighting_613_default_off.json'),
    'd15': os.path.join(SCENES, 'lighting_613_d15.json'),
}
# A repo checkout is decided by ONE file every checkout has, never by this
# ticket's own files: in a checkout those are required (assert_present), so a
# rename fails the suites instead of skipping them.
HAVE_CHECKOUT = os.path.isfile(os.path.join(ROOT, 'layerGraphics', 'metal',
                                            'RendererMetal.mm'))


def assert_present(*paths):
    """Raise (failing the class, not skipping it) when a file is missing."""
    missing = [os.path.relpath(p, ROOT) for p in paths if not os.path.isfile(p)]
    if missing:
        raise AssertionError('missing from the checkout: %s' % ', '.join(missing))

try:
    import numpy
    import PIL.Image
    HAVE_PIXELS = True
except ImportError:
    HAVE_PIXELS = False

RIG_LINE = 'cmd._l613_rig = '


def load_module(name, filename):
    spec = importlib.util.spec_from_file_location(name, os.path.join(LIGHTING, filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def f32(x):
    return struct.unpack('f', struct.pack('f', x))[0]


def restore_set_lights():
    """Undo the scene files' shim (what tearDown does)."""
    original = vars(cmd).pop('_l613_set', None)
    if original is not None:
        cmd.set_lights = original
    vars(cmd).pop('_l613_rig', None)


@unittest.skipUnless(HAVE_CHECKOUT, 'needs a RayMol checkout (scripts/lighting)')
class TestSceneFiles(testing.PyMOLTestCase):

    @classmethod
    def setUpClass(cls):
        assert_present(os.path.join(LIGHTING, 'render.py'),
                       os.path.join(LIGHTING, 'check_lit.py'), PDB, *FILES.values())
        cls.render = load_module('lighting_render', 'render.py')
        cls.check = load_module('lighting_check_lit', 'check_lit.py')
        cls.jobs = {k: cls.render.scene_file_jobs(v) for k, v in FILES.items()}
        cls.specs = {}
        for k, v in FILES.items():
            with open(v) as handle:
                cls.specs[k] = json.load(handle)

    def setUp(self):
        super(TestSceneFiles, self).setUp()
        self.original_set_lights = cmd.set_lights
        self.tmp = tempfile.mkdtemp(prefix='l613')
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def tearDown(self):
        restore_set_lights()
        cmd.set_lights(None)
        self.assertIs(cmd.set_lights, self.original_set_lights)
        super(TestSceneFiles, self).tearDown()

    def tags(self, *which):
        return [j.tag for w in which for j in self.jobs[w]]

    # --- the files ------------------------------------------------------------

    def testSceneFilesLoad(self):
        self.assertEqual({k: len(v) for k, v in self.jobs.items()},
                         {'pairs': 60, 'params': 46, 'default': 16, 'default_off': 16,
                          # #615 took surfdots_glass out (the file says why)
                          'd15': 4})
        for which in ('pairs', 'params'):
            spec = self.specs[which]
            self.assertEqual((spec['base'], spec['rig']), (None, 'on'), which)
            for job in self.jobs[which]:
                self.assertEqual(job.rig, 'on', job.tag)
                self.assertEqual(job.extra[:len(spec['extra'])], spec['extra'], job.tag)
                # every scene says which rig the shim installs, as its last line
                own = job.extra[len(spec['extra']):]
                self.assertEqual([l for l in own if l.startswith(RIG_LINE)], [own[-1]],
                                 job.tag)
        for which in ('default', 'default_off', 'd15'):
            for job in self.jobs[which]:
                self.assertFalse(any('_l613_rig' in l or 'set_lights' in l
                                     for l in job.extra), job.tag)
        self.assertEqual((self.specs['d15']['base'], self.specs['d15']['rig']), (None, 'none'))
        # the default-path files differ only in "rig"
        a, b = self.specs['default'], self.specs['default_off']
        self.assertEqual((a['rig'], b['rig']), ('none', 'off'))
        self.assertEqual(dict(a, rig=None), dict(b, rig=None))
        # none of the default-path images is one of the 16 L1 images
        self.assertFalse(set(self.tags('default')) & set(self.render.l1_tags()))

    def testPairsComplete(self):
        tags = self.tags('pairs')
        pairs = self.check.pair_tags(tags)
        self.assertEqual(len(pairs) * 2, len(tags))
        for subject, lit, dark in pairs:
            self.assertIn(dark, tags, lit)
        subjects = {s for s, _, _ in pairs}
        for s in ('cartoon', 'surface', 'sticks', 'spheres', 'mesh', 'meshcyl',
                  'transparent', 'glass', 'tube', 'sticks_trans', 'spheres_trans'):
            self.assertLessEqual({s + '_rt0', s + '_rt1'}, subjects, s)
        self.assertLessEqual({'sticks_glass_rt0', 'spheres_jelly_rt0'}, subjects)
        # review round 1: the other material families (procedural,
        # reflective; jelly on the VBO and cylinder paths), clear glass on
        # sphere impostors (surface dots), and the ray tracer's reflection
        # hits (rt1), with the transparent layer in front of them
        self.assertLessEqual({'cartoon_marble_rt0', 'spheres_metallic_rt0',
                              'spheres_metallic_rt1', 'surface_jelly_rt0',
                              'sticks_jelly_rt0', 'metallic_trans_rt1'}, subjects)
        # dark and lit differ only in the light intensities
        jobs = {j.tag: j for j in self.jobs['pairs']}
        for subject, lit, dark in pairs:
            self.assertEqual(jobs[lit].extra[:-1], jobs[dark].extra[:-1], lit)
            self.assertEqual((jobs[lit].rep_lines, jobs[lit].rt, jobs[lit].shadows),
                             (jobs[dark].rep_lines, jobs[dark].rt, jobs[dark].shadows))
        # mesh keeps its own colour (unlit lines must not change)
        for tag in ('mesh_dark_rt0', 'mesh_2l_rt1'):
            self.assertFalse(any('grey80' in l for l in jobs[tag].extra), tag)

    def testParamsComplete(self):
        params, both = self.tags('params'), self.tags('params', 'pairs')
        found = self.check.isolate_tags(params)
        self.assertEqual({s for s, _, _, _ in found},
                         {s + '_rt0' for s in ('cartoon', 'surface', 'sticks', 'spheres',
                                               'tube')})
        for subject, key, rim, dark in found:
            self.assertIn(rim, params, key)
            self.assertIn(dark, params, key)
        for check, refs in self.check.PARAM_CHECKS:
            for tag in refs:
                self.assertIn(tag, both, (check, tag))
        for subject, lit, dark in self.check.pair_tags(params):
            self.assertIn(dark, params, lit)
        self.assertLessEqual({'cartoon_rig3_rt0', 'cartoon_rig3_rt1', 'surface_rig3_rt1'},
                             set(params))
        # every 3-light image is checked: lit against its dark twin, and the
        # outline against the same rig without it
        checked = {t for _, refs in self.check.PARAM_CHECKS for t in refs}
        for tag in ('cartoon_rig3_rt0', 'cartoon_rig3_rt1', 'surface_rig3_rt1',
                    'cartoon_rig3dark_rt0', 'cartoon_rig3dark_rt1',
                    'surface_rig3dark_rt1', 'cartoon_rig3plain_rt0',
                    'cartoon_rig3plain_rt1'):
            self.assertIn(tag, checked)
        # every params image is used by some check
        used = checked | {t for f in self.check.isolate_tags(params) for t in f[1:]}
        used |= {t for f in self.check.pair_tags(params) for t in f[1:]}
        self.assertEqual(set(params) - used, set())
        # a term's two images differ only in that term (the rig line), and
        # the falloff, softness and highlight images keep everything else
        jobs = {j.tag: j for j in self.jobs['params']}
        for a, b in (('surface_hl0_rt0', 'surface_hl1_rt0'),
                     ('surface_hl0_ortho_rt0', 'surface_hl1_ortho_rt0'),
                     ('surface_fall0_rt0', 'surface_fall2_rt0'),
                     ('surface_soft0_rt0', 'surface_soft1_rt0')):
            self.assertEqual(jobs[a].extra[:-1], jobs[b].extra[:-1], a)
            self.assertEqual((jobs[a].rep_lines, jobs[a].rt), (jobs[b].rep_lines, jobs[b].rt))
            la, lb = jobs[a].extra[-1], jobs[b].extra[-1]
            diff = [(x, y) for x, y in zip(re.split(r'(\d+\.\d+)', la),
                                           re.split(r'(\d+\.\d+)', lb)) if x != y]
            self.assertEqual(len(diff), 1, (a, diff))
        # A tag in both files (the params file carries its own dark references)
        # is the same image in both.
        pairs = {j.tag: j for j in self.jobs['pairs']}
        shared = [j for j in self.jobs['params'] if j.tag in pairs]
        self.assertEqual(sorted(j.tag for j in shared),
                         sorted(s + '_dark_rt0' for s in ('cartoon', 'surface', 'sticks',
                                                          'spheres', 'tube')))
        for job in shared:
            twin = pairs[job.tag]
            self.assertEqual((job.rep_lines, job.rt, job.shadows, job.rig, job.size,
                              job.extra),
                             (twin.rep_lines, twin.rt, twin.shadows, twin.rig, twin.size,
                              twin.extra), job.tag)

    def testD15Complete(self):
        """Every no-rig decision-15 render has a rig-on dark twin with the
        same representation, material and camera, in the pairs or params
        file; the default family is the control, and the procedural and
        reflective families are there (jelly and, since #615, glass are left
        out: the scene file says why)."""
        dark = {j.tag: j for w in ('pairs', 'params') for j in self.jobs[w]}
        subjects = set()
        for job in self.jobs['d15']:
            m = self.check._D15_RE.match(job.tag)
            self.assertIsNotNone(m, job.tag)
            twin = dark.get('%s_dark_rt%s' % (m.group('s'), m.group('rt')))
            self.assertIsNotNone(twin, job.tag)
            self.assertEqual((job.rep_lines, job.rt, job.shadows, job.size),
                             (twin.rep_lines, twin.rt, twin.shadows, twin.size), job.tag)
            self.assertEqual(job.rig, 'none')
            # the twin's own lines (material, colour), then the four settings
            own = [l for l in twin.extra if l not in self.specs['pairs']['extra']
                   and l not in self.specs['params']['extra']
                   and not l.startswith(RIG_LINE)]
            self.assertEqual(job.extra[:len(own)], own, job.tag)
            self.assertEqual(job.extra[len(own):],
                             ["cmd.set('ambient', 0.06)", "cmd.set('direct', 0.0)",
                              "cmd.set('reflect', 0.0)", "cmd.set('specular', 0.0)"],
                             job.tag)
            subjects.add(m.group('s'))
        # #615: surfdots_glass left d15 (glass's own classic glints follow
        # the rig's classic since #615; no setting reproduces that without
        # the rig); check_materials.py classic_glints covers them
        self.assertEqual(subjects, {'cartoon', 'cartoon_marble', 'spheres_metallic'})

    # --- the scripts, run in-process the way the app runs them ---------------

    def testD15MatchesDecision15(self):
        """A d15 render's classic terms are exactly what the rig-on dark twin
        hands the renderer (decision 15 at classic 0, ambient 0.06)."""
        self.run_job(self.job('pairs', 'spheres_metallic_dark_rt1'))
        rig_on = lighting._light_frame()
        self.assertTrue(rig_on['rig_on'])
        restore_set_lights()
        cmd.set_lights(None)
        self.run_job(self.job('d15', 'spheres_metallic_d15_rt1'))
        no_rig = lighting._light_frame()
        self.assertFalse(no_rig['rig_on'])
        self.assertIsNone(no_rig['rig'])
        for term in ('ambient', 'direct', 'reflect', 'specular', 'shininess'):
            self.assertEqual(no_rig[term], rig_on[term], term)

    def run_job(self, job, times=1):
        out = os.path.join(self.tmp, 'out')
        self.render.write_scripts(ROOT, out, [job])
        script = self.render.script_path(out, job.tag)
        marker = self.render.marker_path(out, job.tag)
        if os.path.exists(marker):       # as render.py does before each launch
            os.remove(marker)
        for _ in range(times):
            cmd.run(script)
        return marker

    def job(self, which, tag):
        return {j.tag: j for j in self.jobs[which]}[tag]

    def testEveryScriptRunsInProcess(self):
        for which in ('pairs', 'params', 'default', 'default_off', 'd15'):
            for job in self.jobs[which]:
                marker = self.run_job(job)
                with open(marker) as handle:
                    self.assertEqual(len(handle.read().splitlines()), 1, job.tag)
                # The camera is still the harness's: the scene's lines run
                # after its set_view, so a line that moves the camera moves
                # it in the render too. load_cgo auto-zooms by default, and
                # a bezier-only CGO has no extent, so the tube scenes'
                # load_cgo zoomed onto the origin and rendered all black
                # until it passed zoom=0. (The last value is the field of
                # view, signed by orthoscopic.)
                view = cmd.get_view()
                for i, (got_v, want) in enumerate(zip(view, self.render.VIEW)):
                    if i == 17:
                        got_v, want = abs(got_v), abs(want)
                    self.assertAlmostEqual(got_v, want, delta=1e-3,
                                           msg='%s moves the camera (view[%d])'
                                           % (job.tag, i))
                got = cmd.get_lights()
                if job.rig == 'none':
                    self.assertIsNone(got, job.tag)
                    continue
                self.assertIs(got['enabled'], job.rig == 'on', job.tag)
                names = [l['name'] for l in got['lights']]
                # the harness's own rig: as it is (None) or changed by a
                # function of it (lambda)
                harness = (job.extra[-1] == RIG_LINE + 'None' or
                           job.extra[-1].startswith(RIG_LINE + 'lambda'))
                if job.rig == 'on' and not harness:
                    self.assertEqual(names, ['key', 'rim'], job.tag)
                else:
                    self.assertEqual(names, ['key', 'fill', 'rim'], job.tag)
            # the shim must not leak into the next file's scripts
            restore_set_lights()

    def testShimInProcess(self):
        job = self.job('pairs', 'cartoon_2l_rt0')
        marker = self.run_job(job, times=2)       # the app runs it twice
        self.assertIsNone(self.render.check_marker(marker, job.tag, 'on'))
        # the guard kept the real set_lights (no shim wrapping a shim)
        self.assertIs(cmd._l613_set, self.original_set_lights)
        rig = cmd.get_lights()
        self.assertIs(rig['enabled'], True)
        self.assertEqual((rig['ambient'], rig['classic']), (0.06, 0.0))
        self.assertEqual([l['name'] for l in rig['lights']], ['key', 'rim'])
        self.assertEqual(rig['lights'][0]['color'], [1.0, 0.55, 0.2])
        self.assertEqual(rig['lights'][1]['color'], [0.2, 0.8, 1.0])
        self.assertEqual([l['intensity'] for l in rig['lights']], [1.6, 2.0])
        frame = lighting._light_frame()
        self.assertTrue(frame['rig_on'])
        # decision 15: the rig's ambient, PyMOL's lights at classic 0
        self.assertEqual(frame['ambient'], f32(0.06))
        self.assertEqual((frame['direct'], frame['reflect'], frame['specular']),
                         (0.0, 0.0, 0.0))
        key, rim = [l['radiance'] for l in frame['rig']['lights']]
        self.assertGreater(key[0], key[2])     # orange
        self.assertGreater(rim[2], rim[0])     # cyan

        # the dark twin: the same rig, every light at intensity 0
        self.run_job(self.job('pairs', 'cartoon_dark_rt0'), times=2)
        frame = lighting._light_frame()
        self.assertTrue(frame['rig_on'])       # still on: decision 15 applies
        self.assertEqual(frame['ambient'], f32(0.06))
        for light in frame['rig']['lights']:
            self.assertEqual(light['radiance'], [0.0, 0.0, 0.0])

        # a FUNCTION of the harness's rig (the params file's 3-light twins):
        # the shim applies it to the rig the harness installs
        self.run_job(self.job('params', 'cartoon_rig3dark_rt0'), times=2)
        self.assertIs(cmd._l613_set, self.original_set_lights)
        rig = cmd.get_lights()
        self.assertIs(rig['enabled'], True)
        self.assertEqual([l['name'] for l in rig['lights']], ['key', 'fill', 'rim'])
        self.assertEqual([l['intensity'] for l in rig['lights']], [0.0, 0.0, 0.0])
        self.assertEqual([l['outline'] for l in rig['lights']], [False, False, True])

    def testParamScenesInProcess(self):
        # classic 1: PyMOL's lights at full strength, the rig's ambient
        self.run_job(self.job('params', 'surface_classic1_rt0'))
        frame = lighting._light_frame()
        self.assertEqual(frame['direct'], f32(cmd.get_setting_float('direct')))
        self.assertEqual(frame['ambient'], f32(0.06))
        # the pinned key sits 20 A left, 15 A up and 30 A toward the camera
        # from the rig centre, in eye space (the scene converts through the view)
        self.run_job(self.job('params', 'cartoon_pinned_rt0'))
        eye = lighting._lights_eye()
        key = eye['lights'][0]
        self.assertEqual(key['anchor'], 'pinned')
        for got, centre, want in zip(key['position'], eye['centre'], (-20.0, 15.0, 30.0)):
            self.assertAlmostEqual(got - centre, want, delta=1e-3)
        # kelvin: a white key at 2500 K is red-heavy, at 12000 K blue-heavy
        for tag, warm in (('surface_warm_rt0', True), ('surface_cool_rt0', False)):
            self.run_job(self.job('params', tag))
            r, g, b = lighting._light_frame()['rig']['lights'][0]['radiance']
            self.assertEqual(r > b, warm, tag)
        # outlines and the harness's own rig
        self.run_job(self.job('params', 'surface_outline_rt0'))
        self.assertIs(lighting._light_frame()['rig']['lights'][0]['outline'], True)
        self.run_job(self.job('params', 'cartoon_rig3_rt0'))
        self.assertEqual([l['name'] for l in cmd.get_lights()['lights']],
                         ['key', 'fill', 'rim'])
        # orthographic: the scene's own setting wins over the baked one
        self.run_job(self.job('params', 'cartoon_2l_ortho_rt0'))
        self.assertEqual(cmd.get_setting_int('orthoscopic'), 1)

        # review round 1: each shading term's scenes set what they say
        for tag, want in (('surface_hl0_rt0', 0.0), ('surface_hl1_rt0', 1.0),
                          ('surface_hl0_ortho_rt0', 0.0),
                          ('surface_hl1_ortho_rt0', 1.0)):
            self.run_job(self.job('params', tag))
            key = lighting._light_frame()['rig']['lights'][0]
            self.assertEqual(key['highlight'], want, tag)
            self.assertEqual(cmd.get_setting_int('orthoscopic'), int('ortho' in tag), tag)
        for tag, want in (('surface_fall0_rt0', 0.0), ('surface_fall2_rt0', 2.0)):
            self.run_job(self.job('params', tag))
            key = lighting._light_frame()['rig']['lights'][0]
            self.assertEqual((key['falloff'], key['highlight']), (want, 0.0), tag)
            # pinned 35 A left of and 25 A in front of the centre, aimed at
            # it: the left of the subject is nearer the light than the aim
            eye = lighting._lights_eye()
            for got, centre, off in zip(eye['lights'][0]['position'], eye['centre'],
                                        (-35.0, 0.0, 25.0)):
                self.assertAlmostEqual(got - centre, off, delta=1e-3, msg=tag)
            self.assertAlmostEqual(key['falloff_ref'], math.hypot(35.0, 25.0),
                                   delta=1e-3, msg=tag)
        cones = {}
        for tag in ('surface_soft0_rt0', 'surface_soft1_rt0'):
            self.run_job(self.job('params', tag))
            key = lighting._light_frame()['rig']['lights'][0]
            cones[tag] = (key['cos_outer'], key['cos_inner'])
        hard, soft = cones['surface_soft0_rt0'], cones['surface_soft1_rt0']
        self.assertEqual(hard[0], soft[0])                       # the same beam
        self.assertAlmostEqual(hard[1] - hard[0], 1e-4, delta=1e-5)   # a hard edge
        self.assertEqual(soft[1], 1.0)                           # soft to the axis
        # the 3-light twins: the harness rig at intensity 0, and without the
        # rim's outline
        self.run_job(self.job('params', 'cartoon_rig3plain_rt1'))
        lights = lighting._light_frame()['rig']['lights']
        self.assertEqual([l['outline'] for l in lights], [False, False, False])
        self.assertTrue(all(max(l['radiance']) > 0.0 for l in lights))
        self.run_job(self.job('params', 'surface_rig3dark_rt1'))
        lights = lighting._light_frame()['rig']['lights']
        self.assertEqual(len(lights), 3)
        self.assertTrue(all(l['radiance'] == [0.0, 0.0, 0.0] for l in lights))


@unittest.skipUnless(HAVE_CHECKOUT, 'needs a RayMol checkout (scripts/lighting)')
@unittest.skipUnless(HAVE_PIXELS, 'needs numpy and Pillow')
class TestCheckLit(testing.PyMOLTestCase):
    """check_lit.py's decisions on synthetic images. Each image is 60x100,
    black background, a grey80-ish block of geometry in the middle."""

    H, W = 60, 100

    @classmethod
    def setUpClass(cls):
        assert_present(os.path.join(LIGHTING, 'check_lit.py'))
        cls.check = load_module('lighting_check_lit', 'check_lit.py')

    def setUp(self):
        super(TestCheckLit, self).setUp()
        self.tmp = tempfile.mkdtemp(prefix='l613c')
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def dark(self):
        image = numpy.zeros((self.H, self.W, 3), dtype=numpy.uint8)
        image[10:50, 10:90] = 60
        return image

    def add(self, image, rows, cols, rgb):
        out = image.astype(numpy.int32)
        out[rows, cols] += numpy.array(rgb, dtype=numpy.int32)
        return numpy.clip(out, 0, 255).astype(numpy.uint8)

    def lit(self, dark=None, orange=True, cyan=True):
        """Orange light on the left of the block, cyan on the right."""
        image = self.dark() if dark is None else dark
        if orange:
            image = self.add(image, slice(10, 50), slice(10, 40), (120, 66, 24))
        if cyan:
            image = self.add(image, slice(10, 50), slice(60, 90), (24, 96, 120))
        return image

    def ok(self, result):
        self.assertTrue(result.ok, result)

    def fails(self, result):
        self.assertFalse(result.ok, result)

    def testLit(self):
        dark = self.dark()
        self.ok(self.check.check_lit(self.lit(), dark))
        self.fails(self.check.check_lit(dark, dark))                 # negative control
        self.fails(self.check.check_lit(self.add(dark, slice(10, 50), slice(10, 90),
                                                 (5, 5, 5)), dark))  # too faint
        self.fails(self.check.check_lit(self.add(dark, slice(10, 11), slice(10, 20),
                                                 (90, 90, 90)), dark))  # too few
        black = numpy.zeros_like(dark)
        self.fails(self.check.check_lit(black, black))               # no geometry
        self.fails(self.check.check_lit(dark[:30], dark))            # sizes differ

    def testHue(self):
        dark = self.dark()
        self.ok(self.check.check_hue(self.lit(), dark, 'cartoon_rt0'))
        self.fails(self.check.check_hue(self.lit(cyan=False), dark, 'cartoon_rt0'))
        self.fails(self.check.check_hue(self.lit(orange=False), dark, 'cartoon_rt0'))
        self.fails(self.check.check_hue(dark, dark, 'cartoon_rt0'))
        # white light is neither orange nor cyan
        white = self.add(dark, slice(10, 50), slice(10, 90), (100, 100, 100))
        self.fails(self.check.check_hue(white, dark, 'cartoon_rt0'))
        # glass and transparent subjects need only a little of each: 36 of
        # the 3200 geometry pixels (1.1%) orange and as many cyan
        faint = self.add(self.add(dark, slice(20, 26), slice(20, 26), (120, 66, 24)),
                         slice(30, 36), slice(70, 76), (24, 96, 120))
        self.fails(self.check.check_hue(faint, dark, 'surface_rt0'))
        fainter = self.add(self.add(dark, slice(20, 22), slice(20, 22), (120, 66, 24)),
                           slice(30, 32), slice(70, 72), (24, 96, 120))
        self.fails(self.check.check_hue(fainter, dark, 'glass_rt0'))   # 0.1% each
        for subject in ('glass_rt0', 'transparent_rt1', 'sticks_trans_rt0',
                        'spheres_jelly_rt0', 'sticks_glass_rt0'):
            self.assertTrue(self.check.faint(subject), subject)
            self.ok(self.check.check_hue(faint, dark, subject))
        self.assertFalse(self.check.faint('meshcyl_rt0'))

    def testEqual(self):
        dark = self.dark()
        self.ok(self.check.check_equal(dark, dark.copy()))
        self.fails(self.check.check_equal(self.add(dark, slice(0, 1), slice(0, 1),
                                                   (1, 0, 0)), dark))

    def testIsolate(self):
        dark = self.dark()
        key = self.lit(orange=True, cyan=False)
        rim = self.lit(orange=False, cyan=True)
        results = self.check.check_isolate(key, rim, dark, 'cartoon_rt0')
        self.assertEqual([r.check for r in results],
                         ['isolate key', 'isolate rim', 'isolate lit', 'left_of'])
        for r in results:
            self.ok(r)
        # the key landing right of the rim breaks decision 12's orbit sign
        key_right = self.add(dark, slice(10, 50), slice(60, 90), (120, 66, 24))
        rim_left = self.add(dark, slice(10, 50), slice(10, 40), (24, 96, 120))
        by = {r.check: r for r in self.check.check_isolate(key_right, rim_left, dark)}
        self.fails(by['left_of'])
        self.ok(by['isolate key'])
        # a blue key or a red rim
        by = {r.check: r for r in self.check.check_isolate(rim, key, dark)}
        self.fails(by['isolate key'])
        self.fails(by['isolate rim'])
        # a light that adds nothing
        by = {r.check: r for r in self.check.check_isolate(dark, rim, dark)}
        self.fails(by['isolate lit'])
        self.fails(by['left_of'])

    def testLeftOfIsPerRun(self):
        """left_of asks which SIDE of the geometry each light lands on, not
        where in the image: two blocks, the rim on the right half of the left
        one and the key on the left half of the right one, so the key's
        centroid is right of the rim's (round 1's cartoon and sticks) and
        the orbit sign still holds."""
        dark = numpy.zeros((self.H, self.W, 3), dtype=numpy.uint8)
        dark[10:50, 10:40] = 60
        dark[10:50, 60:90] = 60
        key = self.add(dark, slice(10, 50), slice(60, 75), (120, 66, 24))
        rim = self.add(dark, slice(10, 50), slice(25, 40), (24, 96, 120))
        by = {r.check: r for r in self.check.check_isolate(key, rim, dark)}
        self.ok(by['left_of'])
        self.assertIn('key side 0.250 <= rim side 0.750', by['left_of'].detail)
        mirrored = [image[:, ::-1] for image in (key, rim, dark)]
        by = {r.check: r for r in self.check.check_isolate(*mirrored)}
        self.fails(by['left_of'])

    def testRunSides(self):
        geo = numpy.zeros((2, 10), dtype=bool)
        geo[0, 1:5] = True           # a run of 4
        geo[0, 7] = True             # a run of 1
        geo[1, :] = True             # a whole row
        sides = self.check.run_sides(geo)
        self.assertEqual(list(sides[0, 1:5]), [0.125, 0.375, 0.625, 0.875])
        self.assertEqual(sides[0, 7], 0.5)
        self.assertEqual(sides[1, 0], 0.05)
        self.assertEqual(sides[1, 9], 0.95)
        self.assertTrue(numpy.isnan(sides[0, 0]) and numpy.isnan(sides[0, 6]))

    def testFewerLit(self):
        dark = self.dark()
        narrow = self.add(dark, slice(25, 35), slice(40, 50), (90, 60, 30))
        wide = self.add(dark, slice(10, 50), slice(20, 80), (90, 60, 30))
        self.ok(self.check.check_fewer_lit(narrow, wide, dark))
        self.fails(self.check.check_fewer_lit(wide, narrow, dark))
        self.fails(self.check.check_fewer_lit(wide, wide, dark))
        self.fails(self.check.check_fewer_lit(dark, dark, dark))

    def testWarmCool(self):
        dark = self.dark()
        warm = self.add(dark, slice(10, 50), slice(10, 90), (100, 70, 40))
        cool = self.add(dark, slice(10, 50), slice(10, 90), (60, 75, 100))
        self.ok(self.check.check_warm_cool(warm, cool, dark))
        self.fails(self.check.check_warm_cool(cool, warm, dark))
        self.fails(self.check.check_warm_cool(dark, dark, dark))

    def testBrighter(self):
        dark = self.dark()
        self.ok(self.check.check_brighter(self.lit(), dark))
        self.fails(self.check.check_brighter(dark, self.lit()))
        self.fails(self.check.check_brighter(dark, dark))

    def testOutline(self):
        key = self.lit(cyan=False)
        ring = numpy.array(self.check.outline_colour()) * 200.0
        for got, want in zip(self.check.outline_colour((1.0, 0.55, 0.2)),
                             (1.0, 0.73, 0.52)):
            self.assertAlmostEqual(got, want, places=12)
        outline = key.copy()
        outline[30, 15:45] = ring.astype(numpy.uint8)     # a thin ring
        outline[29, 15:45] = 8                            # its dark halo
        self.ok(self.check.check_outline(outline, key))
        self.fails(self.check.check_outline(key, key))   # no ring at all
        halo_only = key.copy()
        halo_only[29:31, 15:45] = 8
        self.fails(self.check.check_outline(halo_only, key))   # wrong colour
        flood = key.copy()
        flood[10:50, 10:90] = ring.astype(numpy.uint8)
        self.fails(self.check.check_outline(flood, key))       # not thin

    # --- review round 1: one shading term at a time --------------------------

    def keyed(self):
        """The key's diffuse on the whole block: what highlight 0 shows."""
        return self.add(self.dark(), slice(10, 50), slice(10, 90), (90, 50, 18))

    def testHighlight(self):
        off = self.keyed()
        on = self.add(off, slice(20, 30), slice(30, 50), (100, 55, 20))   # 200 px, 6.25%
        self.ok(self.check.check_highlight(on, off))
        self.fails(self.check.check_highlight(off, off))     # no highlight at all
        # ...on most of the geometry: diffuse, not a highlight
        self.fails(self.check.check_highlight(
            self.add(off, slice(10, 50), slice(10, 90), (100, 55, 20)), off))
        # ...in the wrong hue (the rim's, on the key's highlight)
        self.fails(self.check.check_highlight(
            self.add(off, slice(20, 30), slice(30, 50), (20, 80, 100)), off))
        # ...taking light away elsewhere
        darker = self.add(on, slice(30, 50), slice(10, 90), (-30, -30, -30))
        self.fails(self.check.check_highlight(darker, off))
        # ...too faint to be a highlight
        self.fails(self.check.check_highlight(
            self.add(off, slice(20, 30), slice(30, 50), (10, 6, 2)), off))
        # a white light: any hue passes the hue part
        white = self.add(off, slice(20, 30), slice(30, 50), (90, 90, 90))
        self.ok(self.check.check_highlight(white, off, colour=(1.0, 1.0, 1.0)))
        self.fails(self.check.check_highlight(white, off))

    def thirds(self, left, middle, right):
        image = self.dark()
        image = self.add(image, slice(10, 50), slice(10, 37), (left,) * 3)
        image = self.add(image, slice(10, 50), slice(37, 63), (middle,) * 3)
        return self.add(image, slice(10, 50), slice(63, 90), (right,) * 3)

    def testFalloff(self):
        dark = self.dark()
        f0 = self.thirds(40, 40, 40)
        f2 = self.thirds(90, 40, 15)          # nearer the light: brighter
        self.ok(self.check.check_falloff(f2, f0, dark))
        self.fails(self.check.check_falloff(self.thirds(15, 40, 90), f0, dark))  # inverted
        self.fails(self.check.check_falloff(f0, f0, dark))                       # none
        self.fails(self.check.check_falloff(self.thirds(90, 40, 0), f0, dark))   # far unlit
        # relative to falloff 0, not absolute: a light that already favours
        # the near side at falloff 0 must favour it more at falloff 2
        self.fails(self.check.check_falloff(self.thirds(90, 40, 15),
                                            self.thirds(80, 40, 15), dark))
        near, far = self.check._thirds(self.check.geometry(dark))
        self.assertEqual((int(near.sum()), int(far.sum())), (40 * 27, 40 * 26))

    def spot(self, soft):
        """A 20x40 beam footprint: flat at softness 0, fading out from its
        middle row at softness 1."""
        image = self.dark().astype(numpy.int32)
        for r in range(20, 40):
            v = 100 if not soft else int(round(100 * (1.0 - abs(r - 29.5) / 10.0)))
            image[r, 30:70] += v
        return numpy.clip(image, 0, 255).astype(numpy.uint8)

    def testSofter(self):
        dark = self.dark()
        soft, hard = self.spot(True), self.spot(False)
        self.ok(self.check.check_softer(soft, hard, dark))
        self.fails(self.check.check_softer(hard, hard, dark))   # softness ignored
        self.fails(self.check.check_softer(hard, soft, dark))   # the wrong way round
        self.fails(self.check.check_softer(soft, dark, dark))   # no hard beam
        # less light but no more of it partial (the beam only dimmer): fails
        self.fails(self.check.check_softer(self.add(dark, slice(20, 40), slice(30, 70),
                                                    (50, 50, 50)), hard, dark))

    def testReflect(self):
        dark = self.dark()
        lit0 = self.add(dark, slice(10, 50), slice(10, 90), (100, 100, 100))
        taken = self.add(dark, slice(10, 50), slice(10, 90), (85, 85, 85))
        ignored = self.add(dark, slice(10, 50), slice(10, 90), (40, 40, 40))
        self.ok(self.check.check_reflect(taken, dark, lit0, dark))
        self.fails(self.check.check_reflect(ignored, dark, lit0, dark))
        self.fails(self.check.check_reflect(dark, dark, lit0, dark))
        self.fails(self.check.check_reflect(taken, dark, dark, dark))   # no rt0 light

    def testGlassLit(self):
        dark = self.dark()
        warm = self.add(dark, slice(10, 30), slice(10, 90), (16, 12, 8))   # 50%, faint
        self.ok(self.check.check_glass_lit(warm, dark))
        self.fails(self.check.check_glass_lit(dark, dark))                 # unlit
        self.fails(self.check.check_glass_lit(
            self.add(dark, slice(10, 30), slice(10, 90), (8, 12, 16)), dark))   # cool
        self.fails(self.check.check_glass_lit(
            self.add(dark, slice(10, 12), slice(10, 90), (16, 12, 8)), dark))   # 5%
        self.fails(self.check.check_glass_lit(
            self.add(dark, slice(10, 30), slice(10, 90), (6, 4, 2)), dark))     # too faint

    def testD15Directory(self):
        dark = self.dark()
        twins = os.path.join(self.tmp, 'pairs')
        d15 = os.path.join(self.tmp, 'd15')
        os.makedirs(twins)
        os.makedirs(d15)
        PIL.Image.fromarray(dark).save(os.path.join(twins, 'cartoon_dark_rt0.png'))
        PIL.Image.fromarray(dark).save(os.path.join(twins, 'spheres_metallic_dark_rt1.png'))
        PIL.Image.fromarray(dark).save(os.path.join(d15, 'cartoon_d15_rt0.png'))
        # one level off: within the tolerance
        PIL.Image.fromarray(self.add(dark, slice(10, 50), slice(10, 90), (1, 0, 1))).save(
            os.path.join(d15, 'spheres_metallic_d15_rt1.png'))
        rc, text = self.main('d15', d15, '--dark', twins)
        self.assertEqual(rc, 0, text)
        self.assertIn('| d15 | cartoon_rt0 | PASS | max \\|d\\| 0 (<= 1), 0 pixels differ |', text)
        self.assertIn('| d15 | spheres_metallic_rt1 | PASS |', text)
        # a family look lost under the rig (a fallback to another variant)
        PIL.Image.fromarray(self.lit()).save(os.path.join(d15, 'cartoon_d15_rt0.png'))
        rc, text = self.main('d15', d15, '--dark', twins)
        self.assertEqual(rc, 1, text)
        self.assertIn('| d15 | cartoon_rt0 | FAIL |', text)
        # the twin may live in a second directory; a missing one fails
        params = os.path.join(self.tmp, 'params')
        os.makedirs(params)
        PIL.Image.fromarray(dark).save(os.path.join(d15, 'surfdots_glass_d15_rt0.png'))
        rc, text = self.main('d15', d15, '--dark', twins)
        self.assertIn('| d15 | surfdots_glass_rt0 | FAIL | missing surfdots_glass_dark_rt0.png |',
                      text)
        PIL.Image.fromarray(dark).save(os.path.join(params, 'surfdots_glass_dark_rt0.png'))
        rc, text = self.main('d15', d15, '--dark', twins, '--dark', params)
        self.assertIn('| d15 | surfdots_glass_rt0 | PASS |', text)
        # usage: no d15 images, a missing directory
        self.assertEqual(self.main('d15', twins, '--dark', twins)[0], 2)
        self.assertEqual(self.main('d15', d15, '--dark', os.path.join(self.tmp, 'no'))[0], 2)

    def testOutlineWhite(self):
        plain = self.lit(cyan=False)
        outline = plain.copy()
        outline[30, 15:45] = 230                          # a white ring
        outline[29, 15:45] = 8
        self.ok(self.check.check_outline_white(outline, plain))
        self.fails(self.check.check_outline_white(plain, plain))
        orange = plain.copy()
        orange[30, 15:45] = (230, 150, 90)                # the key's ring, not white
        self.fails(self.check.check_outline_white(orange, plain))

    def testHuePresent(self):
        image = numpy.zeros((self.H, self.W, 3), dtype=numpy.uint8)
        image[:, :] = (100, 100, 100)          # unlit grey counts as neither
        image[0:20, 0:60] = (230, 140, 60)     # 1200 warm
        image[20:40, 0:60] = (60, 180, 230)    # 1200 cyan
        self.ok(self.check.check_hue_present(image))
        self.assertEqual(self.check.present_counts(image), (1200, 1200))
        # the box: only what is inside counts (the app's toolbar icons are
        # blue enough to count as cyan, so L4 passes the viewport)
        self.assertEqual(self.check.present_counts(image, (0, 0, 60, 20)), (1200, 0))
        self.assertEqual(self.check.present_counts(image, (30, 10, 100, 60)), (300, 600))
        self.fails(self.check.check_hue_present(image, box=(0, 0, 60, 20)))
        image[20:40, 0:60] = (100, 100, 100)
        self.fails(self.check.check_hue_present(image))
        image[0:20, 0:60] = (12, 7, 3)         # warm but too dark to count
        self.assertEqual(self.check.present_counts(image), (0, 0))

    def testHuePresentBoxOption(self):
        image = numpy.zeros((self.H, self.W, 3), dtype=numpy.uint8)
        image[0:20, 0:60] = (230, 140, 60)
        image[20:40, 0:60] = (60, 180, 230)
        self.save('shot', image)
        shot = os.path.join(self.tmp, 'shot.png')
        rc, text = self.main('hue-present', shot)
        self.assertEqual(rc, 0, text)
        rc, text = self.main('hue-present', shot, '--box', '0,0,100,20')
        self.assertEqual(rc, 1, text)
        self.assertIn('warm 1200, cyan 0 (each >= 1000) in 0,0,100,20', text)
        for bad in ('1,2,3', '10,0,5,20', 'a,b,c,d'):
            self.assertEqual(self.main('hue-present', shot, '--box', bad)[0], 2, bad)

    def testTagParsing(self):
        self.assertEqual(
            self.check.pair_tags(['cartoon_2l_rt0', 'cartoon_dark_rt0',
                                  'cartoon_2l_ortho_rt0', 'sticks_trans_2l_rt1',
                                  'surface_key_rt0', 'notatag']),
            [('cartoon_rt0', 'cartoon_2l_rt0', 'cartoon_dark_rt0'),
             ('cartoon_ortho_rt0', 'cartoon_2l_ortho_rt0', 'cartoon_dark_ortho_rt0'),
             ('sticks_trans_rt1', 'sticks_trans_2l_rt1', 'sticks_trans_dark_rt1')])
        self.assertEqual(
            self.check.isolate_tags(['tube_key_rt0', 'tube_rim_rt0', 'surface_2l_rt0']),
            [('tube_rt0', 'tube_key_rt0', 'tube_rim_rt0', 'tube_dark_rt0')])

    # --- directories and the CLI -----------------------------------------------

    def save(self, name, image):
        PIL.Image.fromarray(image).save(os.path.join(self.tmp, name + '.png'))

    def main(self, *argv):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(io.StringIO()):
            rc = self.check.main(list(argv))
        return rc, buf.getvalue()

    def testPairsDirectory(self):
        dark = self.dark()
        self.save('cartoon_dark_rt0', dark)
        self.save('cartoon_2l_rt0', self.lit())
        self.save('mesh_dark_rt0', dark)
        self.save('mesh_2l_rt0', dark)
        rc, text = self.main('pairs', self.tmp)
        self.assertEqual(rc, 0, text)
        self.assertIn('| equal | mesh_rt0 | PASS |', text)
        self.assertIn('| lit | cartoon_rt0 | PASS |', text)
        # the table pastes into a PR: a '|' inside a cell is escaped, so
        # every row has exactly four columns
        rows = [line for line in text.splitlines() if line.startswith('|')]
        self.assertIn('| lit | cartoon_rt0 | PASS | max \\|d\\| 120 ', text)
        for line in rows:
            self.assertEqual(len(re.findall(r'(?<!\\)\|', line)), 5, line)
        # the negative control: no rig light yet, so dark == lit and pairs fails
        self.save('cartoon_2l_rt0', dark)
        rc, text = self.main('pairs', self.tmp)
        self.assertEqual(rc, 1, text)
        self.assertIn('| lit | cartoon_rt0 | FAIL |', text)
        self.assertIn('| hue | cartoon_rt0 | FAIL |', text)
        # mesh lines must not change
        self.save('mesh_2l_rt0', self.lit())
        rc, text = self.main('pairs', self.tmp)
        self.assertIn('| equal | mesh_rt0 | FAIL |', text)
        # a lit image without its dark reference fails, it is not skipped
        os.remove(os.path.join(self.tmp, 'cartoon_dark_rt0.png'))
        rc, text = self.main('pairs', self.tmp)
        self.assertEqual(rc, 1)
        self.assertIn('| pair | cartoon_rt0 | FAIL | missing cartoon_dark_rt0.png |', text)

    def testPairsMeshAgainstNoRig(self):
        """--norig: mesh must also equal the no-rig (L1) render, not only its
        own dark twin: a rig-on change common to both would pass the pair."""
        dark = self.dark()
        self.save('cartoon_dark_rt0', dark)
        self.save('cartoon_2l_rt0', self.lit())
        self.save('mesh_dark_rt0', dark)
        self.save('mesh_2l_rt0', dark)
        norig = os.path.join(self.tmp, 'l1')
        os.makedirs(norig)
        PIL.Image.fromarray(dark).save(os.path.join(norig, 'mesh_rt0.png'))
        rc, text = self.main('pairs', self.tmp, '--norig', norig)
        self.assertEqual(rc, 0, text)
        self.assertIn('| equal | mesh_rt0 | PASS |', text)
        self.assertIn('| equal no rig | mesh_rt0 | PASS |', text)
        # the rig changes the lit and the dark mesh alike: the pair passes,
        # the no-rig comparison does not
        self.save('mesh_dark_rt0', self.lit())
        self.save('mesh_2l_rt0', self.lit())
        rc, text = self.main('pairs', self.tmp, '--norig', norig)
        self.assertEqual(rc, 1, text)
        self.assertIn('| equal | mesh_rt0 | PASS |', text)
        self.assertIn('| equal no rig | mesh_rt0 | FAIL |', text)
        # without --norig, today's pair check only
        rc, text = self.main('pairs', self.tmp)
        self.assertEqual(rc, 0, text)
        self.assertNotIn('equal no rig', text)
        # a missing no-rig image fails; a missing directory is a usage error
        os.remove(os.path.join(norig, 'mesh_rt0.png'))
        rc, text = self.main('pairs', self.tmp, '--norig', norig)
        self.assertEqual(rc, 1, text)
        self.assertIn('| equal no rig | mesh_rt0 | FAIL | missing mesh_rt0.png', text)
        self.assertEqual(self.main('pairs', self.tmp, '--norig',
                                   os.path.join(self.tmp, 'nope'))[0], 2)

    def testParamsDirectory(self):
        dark = self.dark()
        key = self.lit(cyan=False)
        outline = key.copy()
        outline[30, 15:45] = (numpy.array(self.check.outline_colour()) * 200).astype(numpy.uint8)
        images = {
            'surface_dark_rt0': dark, 'surface_key_rt0': key,
            'surface_rim_rt0': self.lit(orange=False),
            'surface_narrow_rt0': self.add(dark, slice(25, 35), slice(40, 50), (90, 60, 30)),
            'surface_wide_rt0': self.add(dark, slice(10, 50), slice(20, 80), (90, 60, 30)),
            'surface_warm_rt0': self.add(dark, slice(10, 50), slice(10, 90), (100, 70, 40)),
            'surface_cool_rt0': self.add(dark, slice(10, 50), slice(10, 90), (60, 75, 100)),
            'surface_classic1_rt0': self.add(dark, slice(10, 50), slice(10, 90), (30, 30, 30)),
            'surface_outline_rt0': outline,
            'cartoon_dark_rt0': dark, 'cartoon_pinned_rt0': key,
        }
        # review round 1's terms and the 3-light rig
        keyed = self.keyed()
        hl = self.add(keyed, slice(20, 30), slice(30, 50), (100, 55, 20))
        white_ring = self.lit().copy()
        white_ring[30, 15:45] = 230
        images.update({
            'surface_hl0_rt0': keyed, 'surface_hl1_rt0': hl,
            'surface_hl0_ortho_rt0': keyed, 'surface_hl1_ortho_rt0': hl,
            'surface_fall0_rt0': self.thirds(40, 40, 40),
            'surface_fall2_rt0': self.thirds(90, 40, 15),
            'surface_soft0_rt0': self.spot(False), 'surface_soft1_rt0': self.spot(True),
            'cartoon_rig3_rt0': white_ring, 'cartoon_rig3_rt1': white_ring,
            'surface_rig3_rt1': white_ring,
            'cartoon_rig3dark_rt0': dark, 'cartoon_rig3dark_rt1': dark,
            'surface_rig3dark_rt1': dark,
            'cartoon_rig3plain_rt0': self.lit(), 'cartoon_rig3plain_rt1': self.lit(),
            'surfdots_glass_dark_rt0': dark,
            'surfdots_glass_lit_rt0': self.add(dark, slice(10, 30), slice(10, 90),
                                               (16, 12, 8)),
        })
        for name, image in images.items():
            self.save(name, image)
        pairs = os.path.join(self.tmp, 'pairs')
        os.makedirs(pairs)
        lit = self.add(dark, slice(10, 50), slice(10, 90), (100, 100, 100))
        for name, image in (('surface_2l_rt0', dark),
                            ('spheres_metallic_2l_rt1', lit),
                            ('spheres_metallic_dark_rt1', dark),
                            ('spheres_metallic_2l_rt0', lit),
                            ('spheres_metallic_dark_rt0', dark)):
            PIL.Image.fromarray(image).save(os.path.join(pairs, name + '.png'))
        rc, text = self.main('params', self.tmp, '--pairs', pairs)
        self.assertEqual(rc, 0, text)
        for check in ('isolate key', 'isolate rim', 'isolate lit', 'left_of', 'fewer_lit',
                      'warm_cool', 'brighter', 'outline', 'lit', 'highlight', 'falloff',
                      'softer', 'reflect', 'glass_lit'):
            self.assertIn('| %s |' % check, text)
        self.assertEqual(len(re.findall(r'^\| highlight \|', text, re.M)), 2)
        self.assertEqual(len(re.findall(r'^\| lit \| \w*rig3_rt\d \| PASS', text, re.M)), 3)
        self.assertEqual(len(re.findall(r'^\| outline \| cartoon_rig3_rt\d \| PASS', text,
                                        re.M)), 2)
        # a traced reflection that ignores the rig fails reflect
        PIL.Image.fromarray(self.add(dark, slice(10, 50), slice(10, 90), (40, 40, 40))).save(
            os.path.join(pairs, 'spheres_metallic_2l_rt1.png'))
        rc, text = self.main('params', self.tmp, '--pairs', pairs)
        self.assertEqual(rc, 1, text)
        self.assertIn('| reflect | spheres_metallic_2l_rt1 | FAIL |', text)
        PIL.Image.fromarray(lit).save(os.path.join(pairs, 'spheres_metallic_2l_rt1.png'))
        # without the pairs directory, surface_2l_rt0 is missing: a failure
        rc, text = self.main('params', self.tmp)
        self.assertEqual(rc, 1)
        self.assertIn('missing surface_2l_rt0.png', text)

    def testUsage(self):
        self.assertEqual(self.main('pairs', os.path.join(self.tmp, 'nope'))[0], 2)
        self.assertEqual(self.main('pairs', self.tmp)[0], 2)       # nothing to check
        self.assertEqual(self.main('brighter', os.path.join(self.tmp, 'a.png'),
                                   os.path.join(self.tmp, 'b.png'))[0], 2)
        self.save('a', self.lit())
        self.save('b', self.dark())
        rc, text = self.main('brighter', os.path.join(self.tmp, 'a.png'),
                             os.path.join(self.tmp, 'b.png'))
        self.assertEqual(rc, 0, text)
        self.assertIn('| brighter | a | PASS |', text)
        self.assertEqual(self.main('brighter', os.path.join(self.tmp, 'b.png'),
                                   os.path.join(self.tmp, 'a.png'))[0], 1)


if __name__ == '__main__':
    unittest.main()
