"""The light-rig render evidence (#613): scene files and pixel checks.

L2 for #613 renders every lit path with a 2-light rig and decides with
scripts/lighting/check_lit.py. CI has no GPU, so this pins what it can:

* the four scripts/lighting/scenes/lighting_613*.json files load with the
  frozen harness, and are complete: every lit image has its dark reference
  (the same rig at intensity 0), every parameter check its images, and the
  two default-path files differ only in "rig";
* every scene script runs in-process (the way the app runs it) and leaves
  the rig its scene asks for, including through the cmd.set_lights shim the
  pairs and params files install, which is restored afterwards;
* check_lit.py's decisions on synthetic images: a pass and a fail for every
  check, including the negative control (dark equal to lit fails).

Source-reading, so skipped (not passed) outside a repo checkout; the pixel
checks are skipped without numpy or Pillow.

Runs on a RayMol build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/lighting_check.py
"""
import contextlib
import importlib.util
import io
import json
import os
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
}
HAVE_CHECKOUT = (os.path.isfile(os.path.join(LIGHTING, 'render.py')) and
                 os.path.isfile(os.path.join(LIGHTING, 'check_lit.py')) and
                 os.path.isfile(PDB) and all(map(os.path.isfile, FILES.values())))

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
                         {'pairs': 48, 'params': 31, 'default': 16, 'default_off': 16})
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
        for which in ('default', 'default_off'):
            for job in self.jobs[which]:
                self.assertFalse(any('_l613_rig' in l or 'set_lights' in l
                                     for l in job.extra), job.tag)
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

    # --- the scripts, run in-process the way the app runs them ---------------

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
        for which in ('pairs', 'params', 'default', 'default_off'):
            for job in self.jobs[which]:
                marker = self.run_job(job)
                with open(marker) as handle:
                    self.assertEqual(len(handle.read().splitlines()), 1, job.tag)
                got = cmd.get_lights()
                if job.rig == 'none':
                    self.assertIsNone(got, job.tag)
                    continue
                self.assertIs(got['enabled'], job.rig == 'on', job.tag)
                names = [l['name'] for l in got['lights']]
                if job.rig == 'on' and job.extra[-1] != RIG_LINE + 'None':
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


@unittest.skipUnless(HAVE_CHECKOUT, 'needs a RayMol checkout (scripts/lighting)')
@unittest.skipUnless(HAVE_PIXELS, 'needs numpy and Pillow')
class TestCheckLit(testing.PyMOLTestCase):
    """check_lit.py's decisions on synthetic images. Each image is 60x100,
    black background, a grey80-ish block of geometry in the middle."""

    H, W = 60, 100

    @classmethod
    def setUpClass(cls):
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
        # glass and transparent subjects need only a little of each
        faint = self.add(self.add(dark, slice(20, 22), slice(20, 22), (120, 66, 24)),
                         slice(30, 32), slice(70, 72), (24, 96, 120))
        self.fails(self.check.check_hue(faint, dark, 'surface_rt0'))
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

    def testHuePresent(self):
        image = numpy.zeros((self.H, self.W, 3), dtype=numpy.uint8)
        image[:, :] = (100, 100, 100)          # unlit grey counts as neither
        image[0:10, 0:60] = (230, 140, 60)     # 600 warm
        image[20:30, 0:60] = (60, 180, 230)    # 600 cyan
        self.ok(self.check.check_hue_present(image))
        self.assertEqual(self.check.present_counts(image), (600, 600))
        image[20:30, 0:60] = (100, 100, 100)
        self.fails(self.check.check_hue_present(image))
        image[0:10, 0:60] = (12, 7, 3)         # warm but too dark to count
        self.assertEqual(self.check.present_counts(image), (0, 0))

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
        for name, image in images.items():
            self.save(name, image)
        pairs = os.path.join(self.tmp, 'pairs')
        os.makedirs(pairs)
        PIL.Image.fromarray(dark).save(os.path.join(pairs, 'surface_2l_rt0.png'))
        rc, text = self.main('params', self.tmp, '--pairs', pairs)
        self.assertEqual(rc, 0, text)
        for check in ('isolate key', 'isolate rim', 'isolate lit', 'left_of', 'fewer_lit',
                      'warm_cool', 'brighter', 'outline', 'lit'):
            self.assertIn('| %s |' % check, text)
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
