"""The studio lights gallery (#627): scripts/lighting/gallery.py and its scene
file scripts/lighting/scenes/gallery.json.

The gallery renders headless through the frozen harness (render.py), which CI
cannot run (no GPU, no app). These tests pin what CI can check:

* TestSections: gallery.py's section table. Names are tag-shaped and pass the
  harness's path refusals; every section's scene file loads with the harness
  and holds its tags; the rigs section is PyMOL's own lights plus one image
  per preset, in presets() order, so a new preset fails until it has one;
  every reference pair stays inside its section and every check override
  gives its reason; the exposure and materials sections name tags that
  lighting_624.json and lighting_615_gallery.json still define.
* TestScenesRun: every gallery.json scene script, written by the harness,
  runs in-process twice (the way the app runs it), both runs leave the same
  rig, and the rig is the one its tag names: the preset, the swept field, the
  placement helper's result, the shadowed lights, the air and the pinned dust
  clock. highlight= refuses in the app's launch pass (no viewport size
  yet), so those two scenes add a dark key there; testHighlightUnsizedPass
  runs that pass with get_viewport reporting 0x1. tearDown puts
  cmd.set_lights back and removes every cmd._lg_* attribute, since CI runs
  every test file in one process.
* TestDriver: gallery.py's one command, on synthetic images (it never
  launches an app). --dry-run writes every scene script; a refusal (an
  unknown section, the canonical bundle id, a 'preset' path, no --app)
  exits 2 and deletes nothing; --skip-render writes the seven sheets with
  their caption row and their cells in SECTIONS order, index.html and
  gallery.json; the difference checks pass and fail either side of the
  threshold and honour a per-pair override; a missing image, an empty
  section and a tag render.py reported failed exit 1 without a traceback;
  sections not asked for and not on disk are 'not rendered'; clear_section
  deletes only its section; an app sha that is not HEAD is flagged.

Source-reading, so skipped (not passed) outside a repo checkout, decided by
one file every checkout has; in a checkout the gallery's own files are
required, so renaming one fails instead of skipping. Nothing here launches
an app.

Runs on a RayMol build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/lighting_gallery.py
"""
import contextlib
import importlib.util
import io
import json
import math
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

from pymol import cmd, lighting, lighting_commands, testing

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), os.pardir,
                                     os.pardir, os.pardir))
LIGHTING = os.path.join(ROOT, 'scripts', 'lighting')
SCENES = os.path.join(LIGHTING, 'scenes')
GALLERY_JSON = os.path.join(SCENES, 'gallery.json')
PDB = os.path.join(ROOT, 'testing', 'data', '1rx1.pdb')
HAVE_CHECKOUT = os.path.isfile(os.path.join(ROOT, 'layerGraphics', 'metal',
                                            'RendererMetal.mm'))

# Section name -> tag prefix, for the sections gallery.json holds.
PREFIXES = {'rigs': 'rig_', 'light': 'light_', 'place': 'place_',
            'shadows': 'shadow_', 'air': 'air_'}
REUSED = {'exposure': 'lighting_624.json',
          'materials': 'lighting_615_gallery.json'}
SECTION_ORDER = ('rigs', 'light', 'place', 'shadows', 'air', 'exposure',
                 'materials')
MAX_TILES = 12          # a render-inspector contact sheet holds at most 12
HIGHLIGHT_SELE = 'm and polymer and resi 124'
NAP = 'm and resn NAP'


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
    """Undo gallery.json's wrapper and drop every cmd._lg_* attribute."""
    original = vars(cmd).get('_lg_set')
    if original is not None:
        cmd.set_lights = original
    for name in [n for n in vars(cmd) if n.startswith('_lg_')]:
        delattr(cmd, name)


@unittest.skipUnless(HAVE_CHECKOUT, 'needs a RayMol checkout (scripts/lighting)')
class TestSections(testing.PyMOLTestCase):

    @classmethod
    def setUpClass(cls):
        assert_present(os.path.join(LIGHTING, 'render.py'),
                       os.path.join(LIGHTING, 'gallery.py'), GALLERY_JSON,
                       *[os.path.join(SCENES, f) for f in REUSED.values()])
        cls.gallery = load_module('lighting_gallery_driver', 'gallery.py')
        cls.render = cls.gallery.load_render()
        cls.sections = {s.name: s for s in cls.gallery.SECTIONS}
        with open(GALLERY_JSON) as handle:
            cls.spec = json.load(handle)

    def jobs(self, section):
        return {j.tag: j for j in self.render.scene_file_jobs(
            os.path.join(SCENES, section.scenes))}

    def testLoadRenderIsTheHarness(self):
        self.assertEqual(os.path.realpath(self.render.__file__),
                         os.path.realpath(os.path.join(LIGHTING, 'render.py')))
        self.assertTrue(hasattr(self.render, 'scene_file_jobs'))

    def testSectionNames(self):
        names = [s.name for s in self.gallery.SECTIONS]
        self.assertEqual(tuple(names), SECTION_ORDER)
        self.assertEqual(len(set(names)), len(names))
        for name in names:
            self.assertRegex(name, self.render.TAG_RE.pattern)
            self.render.check_path('section', name)
            self.render.check_path('sheet', name + '.png')

    def testSectionFields(self):
        for s in self.gallery.SECTIONS:
            self.assertTrue(s.title and s.caption, s.name)
            self.assertIsInstance(s.tags, tuple, s.name)
            self.assertTrue(s.tags, s.name)
            self.assertEqual(len(set(s.tags)), len(s.tags), s.name)
            self.assertLessEqual(len(s.tags), MAX_TILES, s.name)
            self.assertTrue(1 <= s.cols <= len(s.tags), s.name)
            self.assertFalse(os.path.isabs(s.scenes), s.name)

    def testSceneFilesHoldTheirTags(self):
        for s in self.gallery.SECTIONS:
            path = os.path.join(SCENES, s.scenes)
            assert_present(path)
            jobs = self.jobs(s)
            missing = [t for t in s.tags if t not in jobs]
            self.assertEqual(missing, [], '%s: tags not in %s' % (s.name, s.scenes))
            # the harness's own selection accepts exactly these tags
            self.assertEqual([j.tag for j in self.render.select(list(jobs.values()), s.tags)],
                             [t for t in jobs if t in s.tags])

    def testGalleryFile(self):
        """gallery.json: 40 unique tags, each in exactly one section, whose
        prefix names it; 960x540; rt1 exactly where the tag says so."""
        tags = [e['tag'] for e in self.spec['scenes']]
        self.assertEqual(len(tags), 40)
        self.assertEqual(len(set(tags)), len(tags))
        owners = {}
        for s in self.gallery.SECTIONS:
            if s.scenes == 'gallery.json':
                self.assertIn(s.name, PREFIXES)
                for t in s.tags:
                    self.assertTrue(t.startswith(PREFIXES[s.name]), t)
                    owners.setdefault(t, []).append(s.name)
            else:
                self.assertEqual(REUSED.get(s.name), s.scenes, s.name)
        self.assertEqual(sorted(owners), sorted(tags))
        self.assertTrue(all(len(v) == 1 for v in owners.values()), owners)
        for job in self.render.scene_file_jobs(GALLERY_JSON):
            self.assertEqual(job.size, (960, 540), job.tag)
            self.assertEqual(job.rt, 1 if job.tag.endswith('_rt1') else 0, job.tag)
            self.assertEqual(job.rep_lines, [], job.tag)
            self.assertEqual(job.rig, 'none' if job.tag == 'rig_none' else 'on', job.tag)

    def testGalleryUsesTheCommands(self):
        """Every lit scene builds its rig with cmd.lights / cmd.atmosphere
        through cmd._lg_rig, never cmd.do or a rig dict; the wrapper is the
        one line that calls the original set_lights."""
        extra = self.spec['extra']
        self.assertIn("if not hasattr(cmd, '_lg_set'): cmd._lg_set = cmd.set_lights", extra)
        self.assertIn("cmd._lg_rig = None", extra)
        wrapper = [l for l in extra if l.startswith('cmd.set_lights = ')]
        self.assertEqual(len(wrapper), 1)
        for entry in self.spec['scenes']:
            lines = entry.get('lines', [])
            text = ' '.join(lines)
            self.assertNotIn('cmd.do(', text, entry['tag'])
            self.assertNotIn('set_lights', text, entry['tag'])
            if entry['tag'] == 'rig_none':
                self.assertEqual(entry.get('rig'), 'none')
                continue
            rig_lines = [l for l in lines if l.startswith('cmd._lg_rig = lambda: (')]
            self.assertEqual(len(rig_lines), 1, entry['tag'])
            self.assertIn('cmd.lights(', rig_lines[0], entry['tag'])

    def testPathsPassTheRefusals(self):
        out = os.path.join(tempfile.gettempdir(), 'gallery_out')
        for s in self.gallery.SECTIONS:
            self.render.check_path('--scenes', os.path.join(LIGHTING, 'scenes', s.scenes))
            self.render.check_path('--scenes', os.path.join('scripts', 'lighting', 'scenes', s.scenes))
            stem = os.path.splitext(s.scenes)[0]
            self.render.check_path('stem', stem)
            for tag in s.tags:
                self.render.check_path('tag', tag)
                self.render.check_path('scene script',
                                       self.render.script_path(os.path.join(out, stem), tag))
                self.render.check_path('image', self.render.png_path(os.path.join(out, stem), tag))

    def testRigsAreThePresets(self):
        names = [n for n, _ in lighting_commands.presets()]
        self.assertEqual(list(self.gallery.PRESET_NAMES), names)
        self.assertEqual(list(self.sections['rigs'].tags),
                         ['rig_none'] + ['rig_' + n for n in names])

    def testReferencePairs(self):
        for s in self.gallery.SECTIONS:
            for pair in s.refs:
                self.assertEqual(len(pair), 2, s.name)
                tag, ref = pair
                self.assertIn(tag, s.tags, s.name)
                self.assertIn(ref, s.tags, s.name)
                self.assertNotEqual(tag, ref)
            self.assertEqual(len(set(s.refs)), len(s.refs), s.name)
            for pair, override in s.overrides.items():
                self.assertIn(pair, s.refs, '%s: override of %r has no pair' % (s.name, pair))
                self.assertTrue(str(override.get('reason', '')).strip(),
                                '%s: override of %r gives no reason' % (s.name, pair))
                self.assertTrue(set(override) <= {'level', 'share', 'reason'}, override)
        # air rt0 and rt1 sit side by side and are never a differs pair
        air = self.sections['air']
        i = air.tags.index('air_dust')
        self.assertEqual(air.tags[i + 1], 'air_dust_rt1')
        self.assertNotEqual(i % air.cols, air.cols - 1)
        self.assertFalse({('air_dust_rt1', 'air_dust'), ('air_dust', 'air_dust_rt1')}
                         & set(air.refs))

    def testReusedTagsExist(self):
        """#624's and #615's L2 tags the gallery reuses (if #624's file renames
        them, the exposure section moves to its own exp_* scenes)."""
        for name, filename in REUSED.items():
            jobs = self.render.scene_file_jobs(os.path.join(SCENES, filename))
            known = {j.tag for j in jobs}
            self.assertEqual([t for t in self.sections[name].tags if t not in known], [], name)
        self.assertEqual(len(self.sections['exposure'].tags), 6)
        self.assertEqual(len(self.sections['materials'].tags), 10)

    def testImageCount(self):
        self.assertEqual(sum(len(s.tags) for s in self.gallery.SECTIONS), 56)


@unittest.skipUnless(HAVE_CHECKOUT, 'needs a RayMol checkout (scripts/lighting)')
class TestScenesRun(testing.PyMOLTestCase):

    @classmethod
    def setUpClass(cls):
        assert_present(os.path.join(LIGHTING, 'render.py'), GALLERY_JSON, PDB)
        cls.render = load_module('lighting_render', 'render.py')
        cls.jobs = {j.tag: j for j in cls.render.scene_file_jobs(GALLERY_JSON)}

    def setUp(self):
        super(TestScenesRun, self).setUp()
        self.original = cmd.set_lights
        self.tmp = tempfile.mkdtemp(prefix='l627')
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def tearDown(self):
        restore_set_lights()
        self.assertIs(cmd.set_lights, self.original)
        cmd.set_lights(None)
        cmd.reinitialize()
        super(TestScenesRun, self).tearDown()

    def run_tag(self, tag):
        """Run the tag's script twice, as the app does; both runs must leave
        the marker and the same rig. Returns the rig."""
        job = self.jobs[tag]
        out = os.path.join(self.tmp, 'out')
        self.render.write_scripts(ROOT, out, [job])
        marker = self.render.marker_path(out, tag)
        if os.path.exists(marker):
            os.remove(marker)
        rigs = []
        for _ in range(2):
            cmd.run(self.render.script_path(out, tag))
            rigs.append(cmd.get_lights())
        self.assertIsNone(self.render.check_marker(marker, tag, job.rig), tag)
        self.assertEqual(rigs[0], rigs[1], '%s: the second run left another rig' % tag)
        self.assertIs(vars(cmd).get('_lg_set'), self.original, tag)
        self.assertEqual(cmd.count_atoms('m and inorganic'), 0, tag)
        self.assertEqual(cmd.get_setting_int('depth_cue'), 0, tag)
        self.assertEqual(cmd.get_setting_int('metal_shadows'), 1, tag)
        self.assertEqual(cmd.get_setting_int('async_builds'), 0, tag)
        self.assertEqual(cmd.get_setting_int('metal_raytrace'), job.rt, tag)
        return rigs[1]

    def view(self, turn=None):
        cmd.set_view(self.render.VIEW, animate=0)
        cmd.turn('y', -25)
        if turn:
            cmd.turn('y', turn)
        return cmd.get_view()

    def assertView(self, want, tag):
        for i, (got, w) in enumerate(zip(cmd.get_view(), want)):
            self.assertAlmostEqual(got, w, delta=1e-3, msg='%s: view[%d]' % (tag, i))

    def assertAir(self, rig, tag, **want):
        defaults = {name: default for scope, name, kind, default, lo, hi
                    in lighting._light_fields() if scope == 'air'}
        for name, default in defaults.items():
            self.assertAlmostEqual(rig['air'][name], want.get(name, default), places=6,
                                   msg='%s: air %s' % (tag, name))

    def key(self, rig, name='key'):
        for light in rig['lights']:
            if light['name'] == name:
                return light
        raise AssertionError('no light %r in %r' % (name, [l['name'] for l in rig['lights']]))

    def eye_position(self, name):
        for entry in lighting._lights_eye()['lights']:
            if entry['name'] == name:
                return entry['position']
        raise KeyError(name)

    def testRigs(self):
        rig = self.run_tag('rig_none')
        self.assertIsNone(rig)
        self.assertView(self.view(), 'rig_none')
        for name, (description, ambient, lights) in lighting_commands.PRESETS.items():
            tag = 'rig_' + name
            rig = self.run_tag(tag)
            self.assertIs(rig['enabled'], True, tag)
            self.assertAlmostEqual(rig['ambient'], ambient, places=6, msg=tag)
            self.assertEqual(rig['classic'], 0.0, tag)
            self.assertEqual([l['name'] for l in rig['lights']],
                             [l['name'] for l in lights], tag)
            for got, want in zip(rig['lights'], lights):
                for field in ('orbit', 'pitch', 'beam', 'intensity'):
                    if field in want:
                        self.assertAlmostEqual(got[field], want[field], places=4,
                                               msg='%s %s' % (tag, field))
            self.assertAir(rig, tag)
            self.assertView(self.view(), tag)

    def testLightRows(self):
        rows = {
            'light_beam_8': {'beam': 8.0, 'softness': 0.3},
            'light_beam_15': {'beam': 15.0, 'softness': 0.3},
            'light_beam_28': {'beam': 28.0, 'softness': 0.3},
            'light_soft_0': {'beam': 15.0, 'softness': 0.0},
            'light_soft_0p5': {'beam': 15.0, 'softness': 0.5},
            'light_soft_1': {'beam': 15.0, 'softness': 1.0},
            'light_warm_2200': {'warmth': 2200.0},
            'light_warm_6500': {'warmth': 6500.0},
            'light_warm_12000': {'warmth': 12000.0},
        }
        base = {'orbit': -25.0, 'pitch': 35.0, 'radius': 3.0, 'beam': 45.0,
                'softness': 0.4, 'warmth': 6500.0, 'intensity': 1.5,
                'highlight': 0.7}
        for tag, fields in rows.items():
            rig = self.run_tag(tag)
            self.assertEqual([l['name'] for l in rig['lights']], ['key'], tag)
            self.assertAlmostEqual(rig['ambient'], 0.06, places=6, msg=tag)
            key = self.key(rig)
            for field, value in dict(base, **fields).items():
                self.assertAlmostEqual(key[field], value, places=4, msg='%s %s' % (tag, field))
            self.assertIs(key['shadow'], True, tag)
            self.assertEqual(key['color'], [1.0, 1.0, 1.0], tag)
            self.assertAir(rig, tag)
        for colour, rim in (('white', 'white'), ('orange', 'skyblue'), ('hotpink', 'cyan')):
            tag = 'light_colour_' + colour
            rig = self.run_tag(tag)
            self.assertEqual([l['name'] for l in rig['lights']], ['key', 'rim'], tag)
            for name, want in (('key', colour), ('rim', rim)):
                got = self.key(rig, name)['color']
                for a, b in zip(got, cmd.get_color_tuple(want)):
                    self.assertAlmostEqual(a, b, places=4, msg='%s %s' % (tag, name))
            self.assertAlmostEqual(self.key(rig, 'rim')['orbit'], 160.0, places=4, msg=tag)

    def testTarget(self):
        for tag, outline in (('place_target', True), ('place_target_final', False)):
            rig = self.run_tag(tag)
            key = self.key(rig)
            self.assertEqual(key['aim'], 'point', tag)
            self.assertEqual(key['aim_selection'], NAP, tag)
            xyz = cmd.get_coords(NAP)
            centre = [float(sum(c[k] for c in xyz) / len(xyz)) for k in range(3)]
            for a, b in zip(key['aim_point'], centre):
                self.assertAlmostEqual(a, b, places=3, msg=tag)
            # the beam was fitted to the NADPH (the field's default is 45)
            self.assertTrue(1.0 <= key['beam'] < 40.0, '%s: beam %r' % (tag, key['beam']))
            self.assertIs(key['outline'], outline, tag)
            self.assertIs(key['shadow'], True, tag)
            self.assertEqual(key['anchor'], 'camera', tag)

    def testHighlight(self):
        """highlight= picks His124's own surface: the pick did not refuse
        (it would raise and the marker would fail), and the aim point is on
        the selection; rim=145 moves the light."""
        positions = {}
        for tag in ('place_highlight', 'place_highlight_rim'):
            rig = self.run_tag(tag)
            key = self.key(rig)
            self.assertEqual(key['aim'], 'point', tag)
            self.assertEqual(key['aim_selection'], HIGHLIGHT_SELE, tag)
            atoms = cmd.get_model(HIGHLIGHT_SELE).atom
            gap = min(math.sqrt(sum((p - a) ** 2 for p, a in zip(key['aim_point'], atom.coord)))
                      - atom.vdw for atom in atoms)
            self.assertLess(gap, 1.5, tag)
            self.assertEqual(key['anchor'], 'camera', tag)
            self.assertIs(key['outline'], True, tag)
            positions[tag] = self.eye_position('key')
        self.assertGreater(math.dist(positions['place_highlight'],
                                     positions['place_highlight_rim']), 1.0)

    def testHighlightUnsizedPass(self):
        """The app's launch pass of PYMOL_AUTOCMD has no viewport size yet
        (get_viewport 0x1), where highlight= refuses: that pass adds a dark
        key instead, so both passes leave the marker; the pass before the
        export (sized) places the light."""
        sized = cmd.get_viewport
        for tag in ('place_highlight', 'place_highlight_rim'):
            job = self.jobs[tag]
            out = os.path.join(self.tmp, 'unsized')
            self.render.write_scripts(ROOT, out, [job])
            marker = self.render.marker_path(out, tag)
            if os.path.exists(marker):
                os.remove(marker)
            cmd.get_viewport = lambda *a, **k: (0, 1)
            try:
                cmd.run(self.render.script_path(out, tag))
            finally:
                cmd.get_viewport = sized
            key = self.key(cmd.get_lights())
            self.assertEqual((key['intensity'], key['aim']), (0.0, 'centre'), tag)
            cmd.run(self.render.script_path(out, tag))
            self.assertIsNone(self.render.check_marker(marker, tag, job.rig), tag)
            key = self.key(cmd.get_lights())
            self.assertEqual((key['intensity'], key['aim_selection']), (2.0, HIGHLIGHT_SELE), tag)

    def testCameraVsPinned(self):
        positions = {}
        for tag, anchor in (('place_camera_turned', 'camera'),
                            ('place_pinned_turned', 'pinned')):
            rig = self.run_tag(tag)
            self.assertEqual(self.key(rig)['anchor'], anchor, tag)
            self.assertEqual(self.key(rig, 'fill')['anchor'], 'camera', tag)
            self.assertView(self.view(turn=90), tag)
            positions[tag] = self.eye_position('key')
        # the camera light stayed with the camera; the pinned one turned
        self.assertGreater(math.dist(positions['place_camera_turned'],
                                     positions['place_pinned_turned']), 1.0)

    def testShadows(self):
        want = {'shadow_none': ([], 2), 'shadow_red': (['red'], 2),
                'shadow_both': (['red', 'blue'], 2),
                'shadow_cap': (['red', 'blue', 'top'], 4),
                'shadow_both_rt1': (['red', 'blue'], 2)}
        for tag, (shadowed, count) in want.items():
            rig = self.run_tag(tag)
            self.assertEqual(len(rig['lights']), count, tag)
            self.assertEqual([l['name'] for l in rig['lights'] if l['shadow']], shadowed, tag)
            self.assertLessEqual(len(shadowed), lighting_commands.MAX_SHADOWS)
            self.assertAlmostEqual(rig['ambient'], 0.04, places=6, msg=tag)
            self.assertAir(rig, tag)

    def testAir(self):
        want = {
            'air_none': {},
            'air_haze': {'haze': 0.6},
            'air_dust': {'haze': 0.6, 'dust': 0.6},
            'air_dust_rt1': {'haze': 0.6, 'dust': 0.6},
            'air_backlit': {'haze': 0.18, 'dust': 0.5, 'scatter': 0.55},
            'air_crossing': {'haze': 0.35, 'dust': 0.8},
            'air_dust_t0': {'dust': 1.0, 'dust_size': 0.45},
            'air_dust_t1': {'dust': 1.0, 'dust_size': 0.45},
            'air_dust_t2': {'dust': 1.0, 'dust_size': 0.45},
        }
        clock = {'air_dust_t0': 0.0, 'air_dust_t1': 1.0, 'air_dust_t2': 2.0}
        for tag, air in want.items():
            rig = self.run_tag(tag)
            self.assertIs(rig['enabled'], True, tag)
            self.assertAir(rig, tag, **air)
            t = cmd.get_setting_float('metal_light_air_time')
            self.assertAlmostEqual(t, clock.get(tag, 2.0), places=6, msg=tag)
            if rig['air']['dust'] > 0:
                self.assertGreaterEqual(t, 0.0, '%s: dust with an unpinned clock' % tag)
            self.assertTrue(any(l['shadow'] for l in rig['lights']), tag)

    def testEveryTagIsCovered(self):
        """The tests above run every gallery.json tag."""
        covered = (['rig_none'] + ['rig_' + n for n in lighting_commands.PRESETS]
                   + ['light_beam_8', 'light_beam_15', 'light_beam_28',
                      'light_soft_0', 'light_soft_0p5', 'light_soft_1',
                      'light_warm_2200', 'light_warm_6500', 'light_warm_12000',
                      'light_colour_white', 'light_colour_orange', 'light_colour_hotpink',
                      'place_target', 'place_target_final', 'place_highlight',
                      'place_highlight_rim', 'place_camera_turned', 'place_pinned_turned',
                      'shadow_none', 'shadow_red', 'shadow_both', 'shadow_cap',
                      'shadow_both_rt1', 'air_none', 'air_haze', 'air_dust',
                      'air_dust_rt1', 'air_backlit', 'air_crossing', 'air_dust_t0',
                      'air_dust_t1', 'air_dust_t2'])
        self.assertEqual(sorted(covered), sorted(self.jobs))


def colour(i):
    """Distinct per index: any two differ by 32 levels in R or G."""
    return ((i % 8) * 32 + 16, ((i // 8) % 8) * 32 + 16, 128)


@unittest.skipUnless(HAVE_CHECKOUT, 'needs a RayMol checkout (scripts/lighting)')
class TestDriver(testing.PyMOLTestCase):
    """gallery.py's driver on synthetic images; nothing is launched."""

    @classmethod
    def setUpClass(cls):
        assert_present(os.path.join(LIGHTING, 'render.py'),
                       os.path.join(LIGHTING, 'gallery.py'))
        cls.gallery = load_module('lighting_gallery_driver', 'gallery.py')
        cls.render = cls.gallery.load_render()
        cls.sections = {s.name: s for s in cls.gallery.SECTIONS}
        cls.sizes, cls.colours = {}, {}
        for s in cls.gallery.SECTIONS:
            for tag, job in cls.gallery.section_jobs(cls.render, s).items():
                cls.sizes[tag] = job.size
                cls.colours[tag] = colour(len(cls.colours))
        # one synthetic set, copied per test: a solid colour per tag with a
        # white corner (render.check_image refuses a single colour)
        from PIL import Image
        cls.template = tempfile.mkdtemp(prefix='l627t')
        for s in cls.gallery.SECTIONS:
            os.makedirs(cls.gallery.section_dir(cls.template, s), exist_ok=True)
            for tag in s.tags:
                image = Image.new('RGB', cls.sizes[tag], cls.colours[tag])
                image.paste((255, 255, 255), (0, 0, 8, 8))
                image.save(cls.gallery.image_path(cls.template, s, tag))

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.template, True)

    def setUp(self):
        super(TestDriver, self).setUp()
        self.tmp = tempfile.mkdtemp(prefix='l627d')
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.saved_sections = list(self.gallery.SECTIONS)
        self.saved_head = self.gallery.head_sha

    def tearDown(self):
        self.gallery.SECTIONS[:] = self.saved_sections
        self.gallery.head_sha = self.saved_head
        super(TestDriver, self).tearDown()

    # --- helpers --------------------------------------------------------------

    def main(self, *argv):
        """gallery.main, quietly. Returns (exit code, stdout + stderr)."""
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
            code = self.gallery.main(list(argv))
        return code, buf.getvalue()

    def out_with(self, sections=None, name='out'):
        """An output directory holding the synthetic images of `sections`
        (default: all)."""
        out = os.path.join(self.tmp, name)
        for s in self.gallery.SECTIONS:
            if sections is not None and s.name not in sections:
                continue
            src = self.gallery.section_dir(self.template, s)
            dst = self.gallery.section_dir(out, s)
            os.makedirs(dst, exist_ok=True)
            for tag in s.tags:
                shutil.copy(os.path.join(src, tag + '.png'), dst)
        return out

    def report(self, out):
        with open(os.path.join(out, 'gallery.json')) as handle:
            report = json.load(handle)
        return report, {r['name']: r for r in report['sections']}

    def snapshot(self, out):
        files = {}
        for base, _, names in os.walk(out):
            for n in names:
                path = os.path.join(base, n)
                with open(path, 'rb') as handle:
                    files[os.path.relpath(path, out)] = handle.read()
        return files

    def fake_app(self, ident):
        app = os.path.join(self.tmp, 'Fake.app')
        os.makedirs(os.path.join(app, 'Contents', 'MacOS'))
        with open(os.path.join(app, 'Contents', 'Info.plist'), 'wb') as handle:
            plistlib.dump({'CFBundleIdentifier': ident, 'CFBundleExecutable': 'Fake'},
                          handle)
        return app

    def replace_section(self, name, **fields):
        i = [s.name for s in self.gallery.SECTIONS].index(name)
        self.gallery.SECTIONS[i] = self.gallery.SECTIONS[i]._replace(**fields)

    # --- dry run and refusals ----------------------------------------------------

    def testDryRun(self):
        out = os.path.join(self.tmp, 'dry')
        code, text = self.main('--dry-run', '--out', out)
        self.assertEqual(code, 0, text)
        for s in self.gallery.SECTIONS:
            for tag in s.tags:
                self.assertTrue(os.path.isfile(self.render.script_path(
                    self.gallery.section_dir(out, s), tag)), tag)
        # nothing rendered or assembled; three scene files, three calls
        pngs = [n for _, _, names in os.walk(out) for n in names if n.endswith('.png')]
        self.assertEqual(pngs, [])
        self.assertFalse(os.path.exists(os.path.join(out, 'gallery.json')))
        self.assertEqual(sorted(os.listdir(out)),
                         ['gallery', 'lighting_615_gallery', 'lighting_624'])
        self.assertEqual(text.count('gate.sh render '), 3, text)
        self.assertIn('--scenes scripts/lighting/scenes/gallery.json', text)
        # --sections narrows the scripts to its scene file
        out = os.path.join(self.tmp, 'dry_air')
        code, text = self.main('--dry-run', '--out', out, '--sections', 'air')
        self.assertEqual(code, 0, text)
        self.assertEqual(sorted(n[:-3] for n in os.listdir(os.path.join(out, 'gallery', '_work'))),
                         sorted(self.sections['air'].tags))
        self.assertEqual(os.listdir(out), ['gallery'])

    def testUsageErrors(self):
        out = os.path.join(self.tmp, 'u')
        for argv in (['--skip-render', '--out', out, '--sections', 'rigs,bogus'],
                     ['--skip-render', '--out', out, '--sections', ','],
                     ['--dry-run', '--skip-render', '--out', out],
                     ['--skip-render'],
                     ['--bogus-flag', '--out', out],
                     ['--out', out]):                       # rendering needs --app
            code, text = self.main(*argv)
            self.assertEqual(code, 2, (argv, text))
            self.assertNotIn('Traceback', text)
            self.assertFalse(os.path.exists(out), argv)

    def testRefusalKeepsOldFiles(self):
        """Validation comes before any deletion: the canonical bundle id, a
        path holding 'preset' (it contains 'reset') and a missing --app all
        exit 2 with every old image and sheet in place."""
        out = self.out_with()
        self.assertEqual(self.main('--skip-render', '--out', out)[0], 0)
        before = self.snapshot(out)
        self.assertIn('rigs.png', before)
        app = self.fake_app('io.raymol.RayMol')
        for argv in (['--app', app, '--out', out],
                     ['--app', app, '--out', out, '--sections', 'rigs'],
                     ['--out', out, '--sections', 'light']):
            code, text = self.main(*argv)
            self.assertEqual(code, 2, (argv, text))
            self.assertEqual(self.snapshot(out), before, argv)
        self.assertIn('io.raymol.RayMol', self.main('--app', app, '--out', out)[1])
        # an --out the app would act on
        bad = self.out_with(name='my_presets')
        before = self.snapshot(bad)
        # (the canonical-id app again, so that nothing could ever launch: the
        # path is refused first, and the message says so)
        for argv in (['--app', app, '--out', bad], ['--skip-render', '--out', bad],
                     ['--dry-run', '--out', bad]):
            code, text = self.main(*argv)
            self.assertEqual(code, 2, (argv, text))
            self.assertIn('reset', text)
            self.assertEqual(self.snapshot(bad), before, argv)

    # --- assembly ---------------------------------------------------------------

    def testSkipRenderAssembles(self):
        out = self.out_with()
        code, text = self.main('--skip-render', '--out', out)
        self.assertEqual(code, 0, text)
        report, by_name = self.report(out)
        self.assertEqual([r['name'] for r in report['sections']], list(SECTION_ORDER))
        self.assertEqual(report['exit'], 0)
        self.assertEqual(report['requested'], list(SECTION_ORDER))
        for name, r in by_name.items():
            self.assertEqual(r['status'], 'ok', (name, r['errors']))
            self.assertEqual(r['sheet'], name + '.png')
            self.assertTrue(os.path.isfile(os.path.join(out, name + '.png')))
            self.assertEqual([i['tag'] for i in r['images']], list(self.sections[name].tags))
            self.assertEqual([(c['tag'], c['ref']) for c in r['checks']],
                             list(self.sections[name].refs))
            self.assertTrue(all(c['pass'] for c in r['checks']), name)
        with open(os.path.join(out, 'index.html')) as handle:
            index = handle.read()
        for s in self.gallery.SECTIONS:
            self.assertIn('src="%s.png"' % s.name, index)
            self.assertIn(s.title, index)
        self.assertEqual(sorted(report['scene_files']),
                         ['gallery', 'lighting_615_gallery', 'lighting_624'])

    def testSheetOrderAndCaption(self):
        """Each sheet: a caption row on top, then one cell per tag in SECTIONS
        order (render.py's own sheets are alphabetical), `cols` wide."""
        from PIL import Image
        import numpy
        out = self.out_with()
        self.assertEqual(self.main('--skip-render', '--out', out)[0], 0)
        for s in self.gallery.SECTIONS:
            with Image.open(os.path.join(out, s.name + '.png')) as image:
                sheet = numpy.asarray(image.convert('RGB')).astype(int)
            w, h = self.sizes[s.tags[0]]
            thumb_h = round(h * self.gallery.CELL_WIDTH / float(w))
            cell_h = thumb_h + self.gallery.LABEL
            rows = (len(s.tags) + s.cols - 1) // s.cols
            self.assertEqual(sheet.shape[1], s.cols * self.gallery.CELL_WIDTH, s.name)
            header = sheet.shape[0] - rows * cell_h
            self.assertGreater(header, 30, '%s: no caption row' % s.name)
            # the caption row holds text (dark pixels) on its grey band
            self.assertLess(sheet[:header].min(), 80, s.name)
            for i, tag in enumerate(s.tags):
                x = (i % s.cols) * self.gallery.CELL_WIDTH + self.gallery.CELL_WIDTH // 2
                y = header + (i // s.cols) * cell_h + self.gallery.LABEL + thumb_h // 2
                got = tuple(int(v) for v in sheet[y, x])
                self.assertTrue(all(abs(a - b) <= 3 for a, b in zip(got, self.colours[tag])),
                                '%s: cell %d shows %r, %s is %r' % (
                                    s.name, i, got, tag, self.colours[tag]))

    def testDiffers(self):
        import numpy
        a = numpy.zeros((100, 100, 3), numpy.uint8)
        def changed(n, by):
            b = a.copy()
            b.reshape(-1, 3)[:n, 1] = by
            return b
        differs = self.gallery.differs
        self.assertTrue(differs(a, changed(60, 20))['pass'])          # 0.6 %
        self.assertFalse(differs(a, changed(40, 20))['pass'])         # 0.4 %
        self.assertFalse(differs(a, changed(10000, 8))['pass'])       # not beyond 8
        self.assertTrue(differs(a, changed(10000, 9))['pass'])
        self.assertAlmostEqual(differs(a, changed(40, 20))['measured'], 0.004)
        self.assertTrue(differs(a, changed(40, 20), share=0.003)['pass'])
        self.assertTrue(differs(a, changed(60, 5), level=4)['pass'])
        got = differs(a, numpy.zeros((50, 100, 3), numpy.uint8))
        self.assertFalse(got['pass'])
        self.assertIn('size', got['error'])

    def testOverride(self):
        """A pair that differs in only 0.2 % of its pixels fails the default
        check and passes with a per-pair override (which records its reason)."""
        from PIL import Image
        out = self.out_with(['light'])
        s = self.sections['light']
        src = self.gallery.image_path(out, s, 'light_beam_8')
        with Image.open(src) as image:
            image = image.copy()
        w, h = image.size
        image.paste((250, 250, 250), (w // 2, h // 2, w // 2 + 32, h // 2 + 32))   # 0.2 %
        image.save(self.gallery.image_path(out, s, 'light_beam_15'))
        code, text = self.main('--skip-render', '--out', out, '--sections', 'light')
        self.assertEqual(code, 1, text)
        _, by_name = self.report(out)
        check = [c for c in by_name['light']['checks']
                 if (c['tag'], c['ref']) == ('light_beam_15', 'light_beam_8')][0]
        self.assertFalse(check['pass'])
        self.assertAlmostEqual(check['measured'], 32 * 32 / float(w * h), places=5)
        self.replace_section('light', overrides={('light_beam_15', 'light_beam_8'): {
            'share': 0.001, 'reason': 'a test pair that differs in a small patch'}})
        code, text = self.main('--skip-render', '--out', out, '--sections', 'light')
        self.assertEqual(code, 0, text)
        _, by_name = self.report(out)
        check = [c for c in by_name['light']['checks']
                 if (c['tag'], c['ref']) == ('light_beam_15', 'light_beam_8')][0]
        self.assertTrue(check['pass'])
        self.assertEqual(check['share'], 0.001)
        self.assertEqual(check['reason'], 'a test pair that differs in a small patch')

    def testMissingImage(self):
        out = self.out_with()
        os.remove(self.gallery.image_path(out, self.sections['air'], 'air_dust_t1'))
        code, text = self.main('--skip-render', '--out', out)
        self.assertEqual(code, 1, text)
        report, by_name = self.report(out)
        self.assertEqual(report['exit'], 1)
        self.assertEqual(by_name['air']['status'], 'failed')
        self.assertIn('air_dust_t1: missing', by_name['air']['errors'])
        self.assertEqual(by_name['air']['sheet'], 'air.png')     # with a grey cell
        self.assertEqual([n for n, r in by_name.items() if r['status'] != 'ok'], ['air'])

    def testEmptySection(self):
        """A requested section with no image on disk fails (exit 1, from the
        command line too) without a traceback, and its old sheet goes."""
        out = self.out_with()
        self.assertEqual(self.main('--skip-render', '--out', out)[0], 0)
        shutil.rmtree(self.gallery.section_dir(out, self.sections['materials']))
        res = subprocess.run([sys.executable, os.path.join(LIGHTING, 'gallery.py'),
                              '--skip-render', '--out', out],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             universal_newlines=True, timeout=300)
        self.assertEqual(res.returncode, 1, res.stdout + res.stderr)
        self.assertNotIn('Traceback', res.stdout + res.stderr)
        _, by_name = self.report(out)
        self.assertEqual(by_name['materials']['status'], 'failed')
        self.assertIn('no images in lighting_615_gallery', by_name['materials']['errors'])
        self.assertIsNone(by_name['materials']['sheet'])
        self.assertFalse(os.path.exists(os.path.join(out, 'materials.png')))
        # asked for alone, too
        code, text = self.main('--skip-render', '--out', out, '--sections', 'materials')
        self.assertEqual(code, 1, text)
        # an --out that does not exist yet: every section fails, nothing raises
        fresh = os.path.join(self.tmp, 'fresh')
        code, text = self.main('--skip-render', '--out', fresh)
        self.assertEqual(code, 1, text)
        _, by_name = self.report(fresh)
        self.assertEqual({r['status'] for r in by_name.values()}, {'failed'})

    def testRenderReportedFailure(self):
        """A tag render.json lists as failed fails its section even though a
        PNG was left behind (render.py keeps the image of a failed marker)."""
        out = self.out_with()
        with open(os.path.join(out, 'gallery', 'render.json'), 'w') as handle:
            json.dump({'app_sha': None, 'tags': ['rig_neon'], 'failed': ['rig_neon']}, handle)
        code, text = self.main('--skip-render', '--out', out)
        self.assertEqual(code, 1, text)
        _, by_name = self.report(out)
        self.assertEqual(by_name['rigs']['status'], 'failed')
        self.assertIn('rig_neon: render.py reported it failed', by_name['rigs']['errors'])

    def testSectionsNotRendered(self):
        out = self.out_with(['light'])
        code, text = self.main('--skip-render', '--out', out, '--sections', 'light')
        self.assertEqual(code, 0, text)
        report, by_name = self.report(out)
        self.assertEqual(report['requested'], ['light'])
        self.assertEqual(by_name['light']['status'], 'ok')
        for name in SECTION_ORDER:
            if name != 'light':
                self.assertEqual(by_name[name]['status'], 'not rendered', name)
                self.assertIsNone(by_name[name]['sheet'], name)
        self.assertEqual(sorted(n for n in os.listdir(out) if n.endswith('.png')),
                         ['light.png'])
        with open(os.path.join(out, 'index.html')) as handle:
            self.assertEqual(handle.read().count('Status: not rendered'), 6)
        # a section not asked for but on disk is assembled and checked
        out = self.out_with(name='all')
        code, text = self.main('--skip-render', '--out', out, '--sections', 'light')
        self.assertEqual(code, 0, text)
        _, by_name = self.report(out)
        self.assertEqual({r['status'] for r in by_name.values()}, {'ok'})
        self.assertFalse(by_name['rigs']['requested'])
        os.remove(self.gallery.image_path(out, self.sections['rigs'], 'rig_none'))
        code, text = self.main('--skip-render', '--out', out, '--sections', 'light')
        self.assertEqual(code, 1, text)

    def testClearSection(self):
        out = self.out_with()
        self.assertEqual(self.main('--skip-render', '--out', out)[0], 0)
        before = set(self.snapshot(out))
        removed = self.gallery.clear_section(out, self.sections['air'])
        gone = {os.path.relpath(p, out) for p in removed}
        self.assertEqual(gone, {'air.png'} | {os.path.join('gallery', t + '.png')
                                              for t in self.sections['air'].tags})
        self.assertEqual(set(self.snapshot(out)), before - gone)
        self.assertEqual(self.gallery.clear_section(out, self.sections['air']), [])

    def testShaFlag(self):
        out = self.out_with()
        head = 'c0ffee' + '0' * 34
        self.gallery.head_sha = lambda root: head
        for stem_name in ('gallery', 'lighting_624', 'lighting_615_gallery'):
            with open(os.path.join(out, stem_name, 'render.json'), 'w') as handle:
                json.dump({'app_sha': head if stem_name != 'lighting_624' else 'deadbeef' * 5,
                           'render_py_sha256': 'ab' * 32, 'tags': [], 'failed': []}, handle)
        code, text = self.main('--skip-render', '--out', out)
        self.assertEqual(code, 0, text)                # flagged, not failed
        report, _ = self.report(out)
        files = report['scene_files']
        self.assertEqual(report['head'], head)
        self.assertIs(files['gallery']['app_sha_matches_head'], True)
        self.assertIsNone(files['gallery']['flag'])
        self.assertIs(files['lighting_624']['app_sha_matches_head'], False)
        self.assertIn('is not HEAD', files['lighting_624']['flag'])
        self.assertEqual(files['lighting_624']['render_py_sha256'], 'ab' * 32)
        self.assertIn('WARNING', text)
        with open(os.path.join(out, 'index.html')) as handle:
            self.assertIn('deadbeef' * 5 + ' is not HEAD', handle.read())
        # no render.json at all: flagged as unknown
        os.remove(os.path.join(out, 'gallery', 'render.json'))
        self.main('--skip-render', '--out', out)
        report, _ = self.report(out)
        self.assertIn('no render.json', report['scene_files']['gallery']['flag'])


if __name__ == '__main__':
    unittest.main()
