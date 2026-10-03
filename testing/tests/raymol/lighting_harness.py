"""The lighting render harness, scripts/lighting/render.py (#611).

L1 (the epic's byte-identical default render) rests on this harness: a master
baseline is rendered with a lone copy of render.py run with --root, the branch
is rendered with the checkout's copy, and --compare decides. These tests pin
what CI can check without a GPU or an app: --compare on synthetic images, the
L1 image set and the shape of every generated scene script, the refusals, the
lone-copy protocol, the scene files, and the scene scripts run in-process
(idempotent, both runs marked). Nothing here ever launches an app.

Source-reading, so skipped (not passed) outside a repo checkout.

Runs on a RayMol build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/lighting_harness.py
"""
import ast
import contextlib
import importlib.util
import io
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

from pymol import cmd, testing

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), os.pardir,
                                     os.pardir, os.pardir))
RENDER = os.path.join(ROOT, 'scripts', 'lighting', 'render.py')
SCENES = os.path.join(ROOT, 'scripts', 'lighting', 'scenes')
PDB = os.path.join(ROOT, 'testing', 'data', '1rx1.pdb')

L1 = {'%s_rt%d' % (rep, rt)
      for rep in ('cartoon', 'surface', 'sticks', 'spheres', 'mesh',
                  'transparent', 'glass', 'shadows')
      for rt in (0, 1)}


def load_render():
    spec = importlib.util.spec_from_file_location('lighting_render', RENDER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def call(func, *args):
    """Run func, return (result, stdout text)."""
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        result = func(*args)
    return result, buf.getvalue()


def statements(text):
    """The script's top-level statements as source strings."""
    tree = ast.parse(text)
    return [ast.get_source_segment(text, node) for node in tree.body]


@unittest.skipUnless(os.path.isfile(RENDER) and os.path.isfile(PDB),
                     'needs a RayMol checkout (scripts/lighting/render.py)')
class TestLightingHarness(testing.PyMOLTestCase):

    @classmethod
    def setUpClass(cls):
        cls.render = load_render()

    def setUp(self):
        super(TestLightingHarness, self).setUp()
        self.tmp = tempfile.mkdtemp(prefix='lh')
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def mkdir(self, name):
        path = os.path.join(self.tmp, name)
        os.makedirs(path, exist_ok=True)
        return path

    def png(self, directory, name, size=(8, 6), colour=(10, 20, 30, 255),
            dot=None):
        from PIL import Image
        image = Image.new('RGBA', size, colour)
        if dot:
            image.putpixel((1, 1), dot)
        image.save(os.path.join(directory, name))

    def run_cli(self, *args, cwd=None):
        return subprocess.run([sys.executable, RENDER] + list(args), cwd=cwd,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              universal_newlines=True, timeout=120)

    def scripts(self, rig='none', root=None, out=None):
        render = self.render
        out = out or self.mkdir('out_' + rig)
        jobs = render.l1_jobs(rig)
        texts = {}
        for job in jobs:
            texts[job.tag] = render.scene_script(root or ROOT, job,
                                                 render.marker_path(out, job.tag))
        return texts

    # --- --compare ----------------------------------------------------------

    def testCompareIdentical(self):
        a, b = self.mkdir('a'), self.mkdir('b')
        for d in (a, b):
            self.png(d, 'one.png')
            self.png(d, 'two.png', dot=(200, 0, 0, 255))
        rc, text = call(self.render.compare, a, b)
        self.assertEqual(rc, 0, text)
        self.assertIn('one.png max=0 differing_px=0', text)
        self.assertIn('overall max=0', text)

    def testCompareOneChannel(self):
        a, b = self.mkdir('a'), self.mkdir('b')
        self.png(a, 'one.png', dot=(100, 100, 100, 255))
        self.png(b, 'one.png', dot=(100, 101, 100, 255))
        rc, text = call(self.render.compare, a, b)
        self.assertEqual(rc, 1, text)
        self.assertIn('one.png max=1 differing_px=1', text)
        self.assertIn('overall max=1', text)

    def testCompareMissingExtra(self):
        a, b = self.mkdir('a'), self.mkdir('b')
        for d in (a, b):
            self.png(d, 'one.png')
        self.png(a, 'only_a.png')
        rc, text = call(self.render.compare, a, b)
        self.assertEqual(rc, 1, text)
        self.assertIn('missing in B: only_a.png', text)
        rc, text = call(self.render.compare, b, a)
        self.assertEqual(rc, 1, text)
        self.assertIn('extra in B: only_a.png', text)

    def testCompareSizeMismatch(self):
        a, b = self.mkdir('a'), self.mkdir('b')
        self.png(a, 'one.png', size=(8, 6))
        self.png(b, 'one.png', size=(6, 8))
        rc, text = call(self.render.compare, a, b)
        self.assertEqual(rc, 1, text)
        self.assertIn('size mismatch: one.png', text)

    def testCompareEmptyFails(self):
        rc, text = call(self.render.compare, self.mkdir('a'), self.mkdir('b'))
        self.assertEqual(rc, 1, text)
        self.assertNotIn('overall max=0', text)

    def testCompareIgnoresSheetAndUnderscore(self):
        a, b = self.mkdir('a'), self.mkdir('b')
        for d in (a, b):
            self.png(d, 'one.png')
        self.png(a, 'sheet.png', colour=(1, 2, 3, 255))
        self.png(b, 'sheet.png', size=(3, 3))
        self.png(a, '_warm.png')
        os.makedirs(os.path.join(b, '_work'))
        self.png(os.path.join(b, '_work'), 'two.png')
        rc, text = call(self.render.compare, a, b)
        self.assertEqual(rc, 0, text)
        self.assertNotIn('sheet', text)
        self.assertNotIn('_warm', text)

    def testCompareCliAcceptsApp(self):
        # gate.sh render always passes --app; --compare ignores it.
        a, b = self.mkdir('a'), self.mkdir('b')
        for d in (a, b):
            self.png(d, 'one.png')
        res = self.run_cli('--app', '/nonexistent/X.app', '--compare', a, b)
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.png(b, 'one.png', colour=(11, 20, 30, 255))
        res = self.run_cli('--app', '/nonexistent/X.app', '--compare', a, b)
        self.assertEqual(res.returncode, 1, res.stdout + res.stderr)

    def testSheet(self):
        d = self.mkdir('s')
        for n in range(5):
            self.png(d, 'img%d.png' % n, size=(64, 36))
        self.png(d, '_skip.png', size=(64, 36))
        res = self.run_cli('--app', '/nonexistent/X.app', '--sheet', d, '--cols', '2')
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        from PIL import Image
        with Image.open(os.path.join(d, 'sheet.png')) as image:
            self.assertEqual(image.width, 2 * 480)
            self.assertEqual(image.height, 3 * (270 + 18))
        # the sheet is not an image to compare
        self.assertNotIn('sheet.png', self.render._pngs(d))

    # --- the L1 set and its scripts ------------------------------------------

    def testL1TagSet(self):
        tags = self.render.l1_tags()
        self.assertEqual(len(tags), 16)
        self.assertEqual(set(tags), L1)
        self.assertEqual([j.tag for j in self.render.l1_jobs('none')], tags)
        self.assertEqual([j.tag for j in self.render.l1_jobs('off')], tags)

    def testScriptShape(self):
        self.assertEqual(self.render.DEFAULT_ROOT, ROOT)
        root = ROOT
        for rig in ('none', 'off'):
            for tag, text in self.scripts(rig).items():
                body = statements(text)
                self.assertEqual(body[0], 'from pymol import cmd, util', tag)
                self.assertEqual(body[1], 'cmd.reinitialize()', tag)
                self.assertEqual(body[2], "cmd.reinitialize('original_settings')", tag)
                self.assertNotIn('orient', text, tag)
                self.assertNotIn('environ', text, tag)
                self.assertNotIn('getenv', text, tag)
                views = [s for s in body if s.startswith('cmd.set_view(')]
                self.assertEqual(len(views), 1, tag)
                view = ast.literal_eval(views[0][len('cmd.set_view('):].split(
                    ', animate=0)')[0])
                self.assertEqual(len(view), 18, tag)
                self.assertEqual(tuple(view), self.render.VIEW, tag)
                rt = int(tag[-1])
                self.assertIn("cmd.set('metal_raytrace', %d)" % rt, body, tag)
                shadows = 1 if tag.startswith('shadows_') else 0
                self.assertIn("cmd.set('metal_shadows', %d)" % shadows, body, tag)
                self.assertIn("cmd.set('metal_temporal_ao', 0)", body, tag)
                # Metal draws nothing CGO-based with the factory use_shaders 0
                self.assertIn("cmd.set('use_shaders', 1)", body, tag)
                self.assertGreater(body.index("cmd.set('use_shaders', 1)"),
                                   body.index("cmd.reinitialize('original_settings')"))
                self.assertIn("cmd.set('metal_dof', 0)", body, tag)
                loads = [s for s in body if s.startswith('cmd.load(')]
                self.assertEqual(loads, ['cmd.load(%r, %r)' % (
                    os.path.join(root, 'testing', 'data', '1rx1.pdb'), 'm')], tag)
                # the marker write is the last statement
                self.assertTrue(body[-1].startswith('with open(_lh_marker'), tag)
                self.assertIn("'tag': %r" % tag, body[-1], tag)
                # nothing but the marker block follows the rig block
                rig_at = text.index('# rig: %s' % rig)
                marker_at = text.index('# marker (last)')
                self.assertLess(rig_at, marker_at, tag)
                self.assertNotIn('cmd.set(', text[marker_at:], tag)

    def testTransparentAndGlass(self):
        texts = self.scripts()
        for tag, text in texts.items():
            self.assertEqual("cmd.set('transparency', 0.5)" in text,
                             tag.startswith('transparent_'), tag)
            self.assertEqual("cmd.set('surface_material', 'glass')" in text,
                             tag.startswith('glass_'), tag)
            self.assertEqual("'transparency'" in text, tag.startswith('transparent_'), tag)

    def testScriptTextDeterministic(self):
        out = self.mkdir('det')
        for rig in ('none', 'off'):
            self.assertEqual(self.scripts(rig, out=out), self.scripts(rig, out=out))

    # --- refusals (exit 2, nothing launched) ---------------------------------

    def testRefusesPaths(self):
        bad = ['with space', 'a,b', 'a;b', 'orient', 'Reset', 'x.pse']
        for word in bad:
            out = os.path.join(self.tmp, 'o_' + word)
            res = self.run_cli('--dry-run', '--set', 'l1', '--rig', 'none',
                               '--out', out)
            self.assertEqual(res.returncode, 2, (word, res.stdout, res.stderr))
            self.assertIn('render.py:', res.stderr)
            self.assertFalse(os.path.exists(out), word)
            root = os.path.join(self.tmp, 'r_' + word)
            os.makedirs(os.path.join(root, 'testing', 'data'))
            shutil.copy(PDB, os.path.join(root, 'testing', 'data'))
            res = self.run_cli('--dry-run', '--root', root, '--set', 'l1',
                               '--rig', 'none', '--out', self.mkdir('ok'))
            self.assertEqual(res.returncode, 2, (word, res.stdout, res.stderr))

    def fake_app(self, ident):
        app = os.path.join(self.tmp, 'Fake%d.app' % len(os.listdir(self.tmp)))
        os.makedirs(os.path.join(app, 'Contents', 'MacOS'))
        with open(os.path.join(app, 'Contents', 'Info.plist'), 'wb') as handle:
            plistlib.dump({'CFBundleIdentifier': ident,
                           'CFBundleExecutable': 'Fake'}, handle)
        return app

    def testRefusesMainBundleId(self):
        app = self.fake_app('io.raymol.RayMol')
        res = self.run_cli('--dry-run', '--app', app, '--set', 'l1', '--rig',
                           'none', '--out', self.mkdir('o'))
        self.assertEqual(res.returncode, 2, res.stdout + res.stderr)
        self.assertIn('io.raymol.RayMol', res.stderr)
        # a dev bundle id passes the same checks
        app = self.fake_app('io.raymol.RayMol.lighttest%d' % os.getpid())
        res = self.run_cli('--dry-run', '--app', app, '--set', 'l1', '--rig',
                           'none', '--out', self.mkdir('o2'))
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)

    def testRefusesNonApp(self):
        res = self.run_cli('--dry-run', '--app', self.mkdir('NotAnApp'), '--set',
                           'l1', '--rig', 'none', '--out', self.mkdir('o'))
        self.assertEqual(res.returncode, 2, res.stdout + res.stderr)

    def testRefusesUnknownOnlyTag(self):
        res = self.run_cli('--dry-run', '--set', 'l1', '--rig', 'none', '--out',
                           self.mkdir('o'), '--only', 'cartoon_rt0,ribbon_rt0')
        self.assertEqual(res.returncode, 2, res.stdout + res.stderr)
        self.assertIn('ribbon_rt0', res.stderr)
        res = self.run_cli('--dry-run', '--set', 'l1', '--rig', 'none', '--out',
                           self.mkdir('o2'), '--only', 'cartoon_rt0,glass_rt1')
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertEqual(sorted(os.listdir(os.path.join(self.tmp, 'o2', '_work'))),
                         ['cartoon_rt0.py', 'glass_rt1.py'])

    def testMissingRootPdbRefused(self):
        res = self.run_cli('--dry-run', '--root', self.mkdir('empty'), '--set',
                           'l1', '--rig', 'none', '--out', self.mkdir('o'))
        self.assertEqual(res.returncode, 2, res.stdout + res.stderr)
        self.assertIn('1rx1.pdb', res.stderr)

    def testUsageErrors(self):
        out = self.mkdir('o')
        for args in ([], ['--set', 'l1', '--out', out],
                     ['--set', 'l1', '--rig', 'on', '--out', out],
                     ['--set', 'l1', '--rig', 'none'],
                     ['--set', 'l1', '--rig', 'none', '--out', out, '--scenes',
                      os.path.join(SCENES, 'selftest_bg.json')]):
            res = self.run_cli('--dry-run', *args)
            self.assertEqual(res.returncode, 2, (args, res.stdout, res.stderr))

    def testRenderNeedsApp(self):
        # without --dry-run and without --app nothing can launch: a refusal
        res = self.run_cli('--set', 'l1', '--rig', 'none', '--out', self.mkdir('o'))
        self.assertEqual(res.returncode, 2, res.stdout + res.stderr)

    # --- the lone copy that renders master baselines -------------------------

    def testCopyRunsWithRoot(self):
        # baseline.sh: `$B/render.py --root $B/root ...`, $B/root holding only
        # testing/data/1rx1.pdb (from master), the copy alone in $B.
        lone = self.mkdir('copy')
        shutil.copy(RENDER, lone)
        root = self.mkdir('root')
        os.makedirs(os.path.join(root, 'testing', 'data'))
        shutil.copy(PDB, os.path.join(root, 'testing', 'data'))
        out = os.path.join(self.tmp, 'renders')
        res = subprocess.run([sys.executable, os.path.join(lone, 'render.py'),
                              '--dry-run', '--root', root, '--set', 'l1', '--rig',
                              'none', '--out', out], cwd=self.mkdir('elsewhere'),
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             universal_newlines=True, timeout=120)
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        work = os.path.join(out, '_work')
        names = sorted(os.listdir(work))
        self.assertEqual(names, sorted(t + '.py' for t in L1))
        pdb = os.path.join(root, 'testing', 'data', '1rx1.pdb')
        for name in names:
            with open(os.path.join(work, name)) as handle:
                text = handle.read()
            self.assertIn('cmd.load(%r, %r)' % (pdb, 'm'), text, name)
            self.assertNotIn(ROOT + os.sep, text.replace(root, ''), name)
        # the copy and the checkout write the same scripts for the same root
        out2 = os.path.join(self.tmp, 'renders2')
        res = self.run_cli('--dry-run', '--root', root, '--set', 'l1', '--rig',
                           'none', '--out', out2)
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        for name in names:
            with open(os.path.join(work, name)) as a, \
                    open(os.path.join(out2, '_work', name)) as b:
                self.assertEqual(a.read(), b.read().replace(out2, out), name)

    # --- scene files -----------------------------------------------------------

    def testSceneFilesLoad(self):
        jobs = self.render.scene_file_jobs(os.path.join(SCENES, 'selftest_bg.json'))
        self.assertEqual({j.tag for j in jobs}, L1)
        for job in jobs:
            self.assertEqual(job.rig, 'none')
            self.assertEqual(job.extra, ["cmd.set('bg_rgb', [0.55, 0.25, 0.25])"])
            text = self.render.scene_script(ROOT, job, '/m.ran')
            # the change comes after the baked background, so it wins
            self.assertGreater(text.index('[0.55, 0.25, 0.25]'),
                               text.index("cmd.set('bg_rgb', %r)" % (self.render.BG,)))
        jobs = self.render.scene_file_jobs(os.path.join(SCENES, 'rig_present.json'))
        self.assertEqual([j.tag for j in jobs],
                         ['cartoon_rt0', 'cartoon_rt1', 'surface_rt1', 'glass_rt1',
                          'shadows_rt0', 'shadows_rt1'])
        for job in jobs:
            self.assertEqual(job.rig, 'on')
            self.assertEqual(job.extra, [])
            l1 = self.render.l1_job(job.tag, 'on')
            self.assertEqual((job.rep_lines, job.rt, job.shadows),
                             (l1.rep_lines, l1.rt, l1.shadows))

    def testSceneFileEntries(self):
        path = os.path.join(self.tmp, 'mine.json')
        with open(path, 'w') as handle:
            json.dump({'base': 'l1', 'rig': 'off', 'extra': ['x = 1'],
                       'scenes': [
                           {'tag': 'cartoon_rt0', 'from': 'surface_rt1', 'rt': 0},
                           {'tag': 'lit_glass', 'from': 'glass_rt1', 'rig': 'on',
                            'size': [640, 360], 'lines': ['y = 2']}]}, handle)
        jobs = {j.tag: j for j in self.render.scene_file_jobs(path)}
        self.assertEqual(set(jobs), L1 | {'lit_glass'})
        self.assertEqual(jobs['cartoon_rt0'].rep_lines, self.render.REPS['surface'])
        self.assertEqual(jobs['cartoon_rt0'].rt, 0)
        self.assertEqual(jobs['lit_glass'].rig, 'on')
        self.assertEqual(jobs['lit_glass'].size, (640, 360))
        self.assertEqual(jobs['lit_glass'].extra, ['x = 1', 'y = 2'])
        self.assertEqual(jobs['mesh_rt1'].rig, 'off')
        for bad in ({'colour': 1}, {'rig': 'dim'}, {'base': 'l2'},
                    {'scenes': [{'tag': 'Bad Tag'}]},
                    {'scenes': [{'tag': 'a', 'from': 'ribbon_rt0'}]},
                    {'scenes': [{'tag': 'a', 'lines': 'cmd.zoom()'}]},
                    {'scenes': [{'tag': 'a', 'rt': 2}]},
                    {'base': 'l1', 'only': ['nope']}, {}):
            with open(path, 'w') as handle:
                json.dump(bad, handle)
            with self.assertRaises(self.render.Refusal, msg=repr(bad)):
                self.render.scene_file_jobs(path)

    def testLaunchEnvironment(self):
        env = self.render.launch_env('/o/_work/t.py', '/o/t.png', (1280, 720), 1)
        self.assertEqual(env, [
            'PYMOL_SKIP_WHATS_NEW=1',
            'PYMOL_SKIP_FIRSTBOOT_THEME=1',
            'PYMOL_AUTOTHEME=Classic',
            'PYMOL_AUTOCMD=run /o/_work/t.py',
            'PYMOL_AUTOEXPORT=/o/t.png,1280,720,1',
        ])
        # rt0 exports clear with the previous frame's background: black on a
        # locked screen (nothing drawn) and black under Classic, so the scenes
        # ask for black too.
        self.assertEqual(self.render.BG, [0.0, 0.0, 0.0])
        self.assertNotIn('RAYMOL_MCP', ' '.join(env))

    # --- checks after each render -----------------------------------------------

    def testMarkerCheck(self):
        check = self.render.check_marker
        path = os.path.join(self.tmp, 't.ran')

        def write(*rows):
            with open(path, 'w') as handle:
                for row in rows:
                    handle.write(json.dumps(row) + '\n')

        def row(run, rig='absent', atoms=1317, tag='t'):
            return {'tag': tag, 'run': run, 'atoms': atoms, 'rig': rig}

        self.assertIn('unreadable', check(path, 't', 'none'))
        write(row(1))
        self.assertIn('1 lines', check(path, 't', 'none'))   # pre-export run missing
        write(row(1), row(2))
        self.assertIsNone(check(path, 't', 'none'))
        write(row(1, 'none'), row(2, 'none'))
        self.assertIsNone(check(path, 't', 'none'))
        write(row(1), row(1))
        self.assertIsNotNone(check(path, 't', 'none'))
        write(row(1), row(2), row(3))
        self.assertIsNotNone(check(path, 't', 'none'))
        write(row(1, atoms=0), row(2, atoms=0))
        self.assertIsNotNone(check(path, 't', 'none'))
        write(row(1), row(2, atoms=10))
        self.assertIsNotNone(check(path, 't', 'none'))
        write(row(1), row(2, tag='u'))
        self.assertIsNotNone(check(path, 't', 'none'))
        off = {'enabled': False, 'lights': 3}
        on = {'enabled': True, 'lights': 3}
        write(row(1, off), row(2, off))
        self.assertIsNone(check(path, 't', 'off'))
        self.assertIsNotNone(check(path, 't', 'on'))
        self.assertIsNotNone(check(path, 't', 'none'))
        write(row(1, on), row(2, on))
        self.assertIsNone(check(path, 't', 'on'))
        self.assertIsNotNone(check(path, 't', 'off'))
        write(row(1, 'absent'), row(2, 'absent'))
        self.assertIsNotNone(check(path, 't', 'off'))
        write(row(1, {'enabled': False, 'lights': 0}), row(2, {'enabled': False, 'lights': 0}))
        self.assertIsNotNone(check(path, 't', 'off'))

    def testImageCheck(self):
        d = self.mkdir('img')
        self.png(d, 'ok.png', size=(16, 9), dot=(0, 0, 0, 255))
        self.assertIsNone(self.render.check_image(os.path.join(d, 'ok.png'), (16, 9)))
        self.assertIn('expected 32x18',
                      self.render.check_image(os.path.join(d, 'ok.png'), (32, 18)))
        self.png(d, 'flat.png', size=(16, 9))
        self.assertIn('single colour',
                      self.render.check_image(os.path.join(d, 'flat.png'), (16, 9)))
        with open(os.path.join(d, 'bad.png'), 'wb') as handle:
            handle.write(b'not a png')
        self.assertIn('does not decode',
                      self.render.check_image(os.path.join(d, 'bad.png'), (16, 9)))

    # --- the scripts, run in-process the way the app runs them ---------------

    def write_one(self, tag, rig):
        out = self.mkdir('run_' + rig)
        job = self.render.l1_job(tag, rig)
        self.render.write_scripts(ROOT, out, [job])
        return self.render.script_path(out, tag), self.render.marker_path(out, tag)

    def snapshot(self):
        lights = getattr(cmd, 'get_lights', None)
        return {
            'view': cmd.get_view(),
            'settings': cmd.get_session()['settings'],
            'atoms': cmd.count_atoms('m'),
            'names': cmd.get_names('all'),
            'rig': lights() if lights else 'absent',
        }

    def testNoneScriptIdempotentInProcess(self):
        script, marker = self.write_one('cartoon_rt0', 'none')
        cmd.run(script)      # what PYMOL_AUTOCMD='run <script>' does
        first = self.snapshot()
        cmd.run(script)
        second = self.snapshot()
        self.assertEqual(first, second)
        self.assertEqual(first['names'], ['m'])
        self.assertGreater(first['atoms'], 1000)
        self.assertEqual(cmd.count_atoms('solvent'), 0)
        self.assertIn(first['rig'], ('absent', None))
        self.assertEqual(tuple(cmd.get_view()), self.render.VIEW)
        with open(marker) as handle:
            rows = [json.loads(line) for line in handle]
        self.assertEqual([r['run'] for r in rows], [1, 2])
        self.assertEqual({r['atoms'] for r in rows}, {first['atoms']})
        self.assertIn(rows[0]['rig'], ('absent', 'none'))
        self.assertIsNone(self.render.check_marker(marker, 'cartoon_rt0', 'none'))

    def testEveryScriptRunsInProcess(self):
        out = self.mkdir('all')
        jobs = self.render.l1_jobs('none')
        self.render.write_scripts(ROOT, out, jobs)
        for job in jobs:
            cmd.run(self.render.script_path(out, job.tag))
            self.assertEqual(cmd.get_names('all'), ['m'], job.tag)
            self.assertEqual(cmd.get_setting_int('metal_raytrace'), job.rt, job.tag)
            self.assertEqual(cmd.get_setting_int('metal_shadows'), job.shadows, job.tag)
            self.assertEqual(cmd.get_setting_int('metal_temporal_ao'), 0, job.tag)
            with open(self.render.marker_path(out, job.tag)) as handle:
                self.assertEqual(len(handle.read().splitlines()), 1, job.tag)

    def testOffScriptInProcess(self):
        # Before #612 the 'off' script reaches the rig through cmd.set_lights,
        # so this also proves the frozen RIG_OFF validates as written.
        script, marker = self.write_one('cartoon_rt0', 'off')
        cmd.run(script)
        first = cmd.get_lights()
        cmd.run(script)
        second = cmd.get_lights()
        self.assertEqual(first, second)
        self.assertIsNotNone(first)
        self.assertIs(first['enabled'], False)
        self.assertGreaterEqual(len(first['lights']), 1)
        if 'lights' not in cmd.keyword:
            # set_lights path: the frozen RIG_OFF validates as written
            self.assertEqual([l['name'] for l in first['lights']], ['key', 'fill', 'rim'])
            mx = cmd.get_extent('m')[1]
            rim = first['lights'][2]
            self.assertEqual(rim['anchor'], 'pinned')
            for got, want in zip(rim['position'], mx):
                self.assertAlmostEqual(got, want + 10.0, places=4)
        self.assertIsNone(self.render.check_marker(marker, 'cartoon_rt0', 'off'))


if __name__ == '__main__':
    unittest.main()
