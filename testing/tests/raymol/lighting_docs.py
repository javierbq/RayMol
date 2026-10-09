"""docs/lighting.md stays in step with the code (#627).

The page is the user's reference for the studio lights. A field, preset,
setting, platform default, UI label or notice that changes in the code
without the page fails here until the page says the same thing:

* TestStructure: the fixed `## ` headings (D7), the fences (every one is
  `pymol`, `python` or `text`) and the relative links of docs/lighting.md and
  docs/materials.md (files and anchors), including materials.md's link here.
* TestTables: the Settings table has a row for every `metal_light_*` setting
  plus metal_gpu_timing, metal_shadows, metal_exposure and metal_tonemap,
  with the setting's own default and 'yes' in Saved in scenes exactly for
  raymol_scenes.CAPTURE; the Light, Rig and Air field tables have a row for
  every entry of the C++ field table with its range and default (the number
  format of TestDocs); aliases, command fields, helpers and keywords are
  named where they belong; the presets table is presets() in order, with
  each preset's lights, ambient and description; the rig's limits.
* TestPlatformDefaults: both platforms' defaults come from the pure helpers
  (shadow map size, air resolution, air shadow filter, metal_light_hdr) and
  the dust cap and its launch switches from MetalViewport.swift's
  AirRedrawGate, so #623's device calibration cannot change an iOS default
  without this page; the iOS defaults are called provisional.
* TestNotices: the CPU ray notice is the core's text, as the commands print
  it; the metal_gpu_timing lines have the core's format; the Atmosphere
  card's hints, start look and backlit threshold are the Swift ones.
* TestLabels: every bold UI label (bold text that does not end a lead-in
  with '.' or ':') is a string literal in its Swift file, comments
  stripped, so a renamed control fails here.
* TestGallerySection: the gallery section names gallery.py's sections, image
  counts, scene files and options.
* TestReleaseNotes: the release-notes draft
  (docs/release-notes/unreleased/lighting.md, args Q2) is in the house style
  (a '### Studio lights' section, the updater footer last), macOS-facing (no
  iPhone, iPad or touch wording outside its header comment), links to this
  page, and every bold UI label in it is a literal in its Swift file.
* TestExamples: every line of every `pymol` block runs through cmd.do and
  every `python` block runs, each block in a fresh session (1rx1 as m with a
  surface, cartoon and organic sticks, viewport 640x480, the harness's view)
  in an empty temporary directory. Output on fd 1 and Python's stdout is
  captured; an 'Error', a traceback or a file written fails the block.
  Examples that show an error, write a file or depend on the window are in
  `text` blocks.

Source-reading, so skipped (not passed) outside a repo checkout, decided by
one file every checkout has; in a checkout the page itself is required.

Runs on a RayMol build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/lighting_docs.py
"""
import contextlib
import importlib.util
import io
import os
import re
import shutil
import sys
import tempfile
import traceback
import unittest

import pymol
import pymol.invocation
from pymol import _cmd, cmd, lighting, lighting_commands, setting, testing

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), os.pardir,
                                     os.pardir, os.pardir))
DOCS = os.path.join(ROOT, 'docs')
DOC = os.path.join(DOCS, 'lighting.md')
MATERIALS = os.path.join(DOCS, 'materials.md')
NOTES = os.path.join(DOCS, 'release-notes', 'unreleased', 'lighting.md')
STYLE = os.path.join(ROOT, '.claude', 'skills', 'cut-macos-release',
                     'references', 'release-notes-style.md')
LIGHTING_SCRIPTS = os.path.join(ROOT, 'scripts', 'lighting')
PDB = os.path.join(ROOT, 'testing', 'data', '1rx1.pdb')
SHARED = os.path.join(ROOT, 'swiftui', 'PyMOLViewer', 'Shared')
PANELS = os.path.join(ROOT, 'swiftui', 'PyMOLViewer', 'Panels')
HAVE_CHECKOUT = os.path.isfile(os.path.join(ROOT, 'layerGraphics', 'metal',
                                            'RendererMetal.mm'))

# The page's fixed headings, in order (plan D7): the tests below read the
# page by these.
HEADINGS = (
    'Quick start',
    'Concepts',
    'The lights command',
    'The atmosphere command',
    'Shadows',
    'Exposure and HDR',
    'In the app',
    'Scenes, sessions and movies',
    'Metal only: the CPU ray tracer and exports',
    'Settings',
    'Performance and iOS',
    'Known limits',
    'Regenerating the gallery',
)

# Settings the page documents besides every metal_light_* one.
EXTRA_SETTINGS = ('metal_gpu_timing', 'metal_shadows', 'metal_exposure',
                  'metal_tonemap')

# Each bold UI label the page names -> the Swift file that defines it.
LABELS = {
    'Enter Lights Mode': os.path.join(SHARED, 'PyMOLApp.swift'),
    'Tools': os.path.join(SHARED, 'PyMOLApp.swift'),
    'Lights': os.path.join(SHARED, 'LightsBar.swift'),
    'Presets': os.path.join(SHARED, 'LightsBar.swift'),
    'Re-centre': os.path.join(SHARED, 'LightsBar.swift'),
    'Revert': os.path.join(SHARED, 'LightsBar.swift'),
    'Done': os.path.join(SHARED, 'LightsBar.swift'),
    'Lights on': os.path.join(SHARED, 'LightsBar.swift'),
    'Lights off': os.path.join(SHARED, 'LightsBar.swift'),
    'Orbit': os.path.join(SHARED, 'LightsEditing.swift'),
    'Pitch': os.path.join(SHARED, 'LightsEditing.swift'),
    'Radius': os.path.join(SHARED, 'LightsEditing.swift'),
    'Intensity': os.path.join(SHARED, 'LightsEditing.swift'),
    'Warmth': os.path.join(SHARED, 'LightsEditing.swift'),
    'Beam': os.path.join(SHARED, 'LightsEditing.swift'),
    'Softness': os.path.join(SHARED, 'LightsEditing.swift'),
    'Shadow': os.path.join(SHARED, 'LightsInspector.swift'),
    'Pin': os.path.join(SHARED, 'LightsInspector.swift'),
    'Turn On': os.path.join(SHARED, 'LightsInspector.swift'),
    'Revert this light': os.path.join(SHARED, 'LightsInspector.swift'),
    'Delete': os.path.join(SHARED, 'LightsInspector.swift'),
    'Atmosphere': os.path.join(SHARED, 'LightsAtmosphere.swift'),
    'Haze': os.path.join(SHARED, 'LightsAtmosphere.swift'),
    'Dust': os.path.join(SHARED, 'LightsAtmosphere.swift'),
    'Dust size': os.path.join(SHARED, 'LightsAtmosphere.swift'),
    'Dust speed': os.path.join(SHARED, 'LightsAtmosphere.swift'),
    'Scatter (g)': os.path.join(SHARED, 'LightsAtmosphere.swift'),
    'Shadows': os.path.join(PANELS, 'ObjectPanel.swift'),
    'Exposure': os.path.join(PANELS, 'ObjectPanel.swift'),
    'Filmic tone-map': os.path.join(PANELS, 'ObjectPanel.swift'),
    'Ray-traced (AO + shadows)': os.path.join(SHARED, 'ContentView.swift'),
}

FENCE_RE = re.compile(r'^```([^\n`]*)\n(.*?)^```[ \t]*$', re.M | re.S)
LINK_RE = re.compile(r'\]\(([^)\s]+)\)')
BOLD_RE = re.compile(r'\*\*(.+?)\*\*', re.S)


# --- reading the page -------------------------------------------------------

def read(path):
    with open(path, encoding='utf-8') as handle:
        return handle.read()


def without_fences(text):
    """The text with every fenced block removed (headings, tables and bold
    are read outside code only)."""
    return FENCE_RE.sub('', text)


def section(doc, heading):
    """The text under `## heading`, up to the next `## ` (as
    material_docs.section)."""
    start = doc.index('\n## %s\n' % heading)
    end = doc.find('\n## ', start + 1)
    return doc[start:end if end >= 0 else len(doc)]


def subsection(doc, heading):
    """The text under `### heading`, up to the next `## ` or `### `."""
    start = doc.index('\n### %s\n' % heading)
    end = re.compile(r'\n#{2,3} ').search(doc, start + 1)
    return doc[start:end.start() if end else len(doc)]


def flat(text):
    """Whitespace runs as one space (the page wraps its lines)."""
    return ' '.join(text.split())


def table_rows(text):
    """{first cell without backticks: [cells]} for every table row whose
    first cell is code."""
    rows = {}
    for line in text.splitlines():
        if not line.startswith('| `'):
            continue
        cells = [c.strip() for c in line.strip().strip('|').split('|')]
        rows[cells[0].strip('`')] = cells
    return rows


def ordered_rows(text):
    return [line for line in text.splitlines() if line.startswith('| `')]


def slug(heading):
    """GitHub's anchor for a heading."""
    text = heading.strip().lower().replace('`', '')
    text = re.sub(r'[^\w\- ]', '', text)
    return text.replace(' ', '-')


def anchors(text):
    return {slug(m.group(1)) for m in
            re.finditer(r'^#{1,6} (.+)$', without_fences(text), re.M)}


def strip_swift_comments(text):
    """Swift comments removed (as lighting_touch.strip_comments), so a
    comment can neither satisfy nor trip a check."""
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    return re.sub(r'//[^\n]*', '', text)


def swift(path):
    return strip_swift_comments(read(path))


def num(x):
    """The page's number format: lighting_commands._num (the one the command
    help and TestDocs use)."""
    return lighting_commands._num(x)


def setting_default(name):
    """A setting's value after reinitialize, as the page writes it."""
    kind, (value,) = cmd.get_setting_tuple(name)
    if kind == 1:
        return 'on' if value else 'off'
    if kind == 2:
        return str(int(value))
    return num(value)


@contextlib.contextmanager
def capture_output():
    """Collect what is written to fd 1 and to Python's stdout while open
    (yields a getter). C++ feedback is written straight to fd 1, which
    contextlib.redirect_stdout never sees (as in lighting_session.py)."""
    sys.stdout.flush()
    saved = os.dup(1)
    tmp = tempfile.TemporaryFile(mode='w+b')
    buf = io.StringIO()
    result = {}
    try:
        os.dup2(tmp.fileno(), 1)
        with contextlib.redirect_stdout(buf):
            yield lambda: result['text']
        sys.stdout.flush()
    finally:
        os.dup2(saved, 1)
        os.close(saved)
        tmp.seek(0)
        result['text'] = tmp.read().decode(errors='replace') + buf.getvalue()
        tmp.close()


class DocCase(testing.PyMOLTestCase):

    @classmethod
    def setUpClass(cls):
        if not HAVE_CHECKOUT:
            raise unittest.SkipTest('needs a RayMol checkout (docs/)')
        # In a checkout the page is required: a renamed page fails.
        cls.raw = read(DOC)
        cls.doc = without_fences(cls.raw)


# --- structure --------------------------------------------------------------

class TestStructure(DocCase):

    def testHeadingsInOrder(self):
        found = re.findall(r'^## (.+)$', self.doc, re.M)
        self.assertEqual(tuple(found), HEADINGS)

    def testEveryFenceIsClassified(self):
        # pymol and python blocks run in TestExamples; text blocks show
        # errors, file writes and window-dependent lines. A bare fence would
        # escape both.
        kinds = [m.group(1).strip() for m in FENCE_RE.finditer(self.raw)]
        self.assertGreaterEqual(kinds.count('pymol'), 10, kinds)
        self.assertIn('python', kinds)
        self.assertEqual(set(kinds) - {'pymol', 'python', 'text'}, set())
        # every opening fence was matched with its closing one
        self.assertEqual(self.raw.count('```'), 2 * len(kinds))

    def testRelativeLinksResolve(self):
        checked = 0
        for path in (DOC, MATERIALS, NOTES):
            text = read(path)
            for target in LINK_RE.findall(without_fences(text)):
                if re.match(r'^[a-z]+:', target):
                    continue        # an absolute URL
                file_part, _, anchor = target.partition('#')
                dest = (os.path.normpath(os.path.join(os.path.dirname(path),
                                                      file_part))
                        if file_part else path)
                self.assertTrue(os.path.exists(dest), (path, target))
                if anchor:
                    self.assertTrue(dest.endswith('.md'), target)
                    self.assertIn(anchor, anchors(read(dest)), (path, target))
                checked += 1
        self.assertGreaterEqual(checked, 10)

    def testBacklitHazeIsAnOpenLimit(self):
        # #683 (backlit haze, no extinction) is open: HDR and exposure soften
        # it but do not fix it, so Known limits lists it and the Backlit haze
        # text says it is open rather than citing it as history.
        self.assertIn('#683', flat(section(self.doc, 'Known limits')))
        backlit = flat(subsection(self.doc, 'Backlit haze'))
        self.assertIn('#683, open', backlit)
        for word in ('fixed', 'resolved', 'closed'):
            self.assertNotIn(word, backlit)

    def testMaterialsLinksHere(self):
        text = section(read(MATERIALS), 'Under studio lights')
        self.assertIn('](lighting.md)', text)

    def testMaterialsLimitLineIsCurrent(self):
        # #624 replaced the 8-bit limit; the materials page must not say the
        # rig clips until HDR any more.
        text = flat(section(read(MATERIALS), 'Under studio lights'))
        self.assertNotIn('until HDR', text)
        self.assertIn('metal_light_hdr 2', text)


# --- tables -----------------------------------------------------------------

class TestTables(DocCase):

    def testEverySettingHasARow(self):
        from pymol import raymol_scenes
        light = sorted(n for n in setting.get_name_list()
                       if n.startswith('metal_light_'))
        # the derivation must find #616's, #618's and #624's settings
        self.assertGreaterEqual(len(light), 5, light)
        names = light + list(EXTRA_SETTINGS)
        rows = table_rows(section(self.doc, 'Settings'))
        self.assertEqual(sorted(rows), sorted(names))
        cmd.reinitialize()
        for name in names:
            cells = rows[name]
            self.assertEqual(len(cells), 4, cells)
            default = cells[2]
            self.assertTrue(default.startswith('`%s`' % setting_default(name)),
                            (name, default))
            saved = 'yes' if name in raymol_scenes.CAPTURE else 'no'
            self.assertEqual(cells[3], saved, name)

    def check_fields(self, scope, heading):
        rows = table_rows(subsection(self.doc, heading))
        fields = [f for f in lighting._light_fields() if f[0] == scope]
        self.assertTrue(fields, scope)
        for _scope, name, kind, default, lo, hi in fields:
            self.assertIn(name, rows, (heading, name))
            cells = rows[name]
            self.assertEqual(len(cells), 5, cells)
            if lo is not None:
                self.assertRegex(cells[2], r'(^|[^\d.])%s to %s(\D|$)' % (
                    re.escape(num(lo)), re.escape(num(hi))), name)
            if default is None:
                continue
            if kind in ('float', 'int', 'angle'):
                want = num(default)
            elif kind == 'bool':
                want = '1' if default else '0'
            elif kind in ('camera|pinned', 'centre|point'):
                want = default
            else:
                continue
            self.assertEqual(cells[3], want, (name, cells))
        return rows

    def testLightFields(self):
        rows = self.check_fields('light', 'Light fields')
        for extra in lighting_commands.COMMAND_FIELDS:
            self.assertIn(extra, rows, extra)
        for alias, field in lighting_commands.ALIASES.items():
            self.assertEqual(rows[field][1], '`%s`' % alias, alias)

    def testRigFields(self):
        self.check_fields('rig', 'Rig fields')

    def testAirFields(self):
        self.check_fields('air', 'Air fields')

    def testHelpersAndKeywords(self):
        helpers = subsection(self.doc, 'Placement helpers')
        for helper in lighting_commands.HELPERS:
            self.assertIn('`%s=' % helper, helpers, helper)
        usage = subsection(self.doc, 'Usage')
        for keyword in lighting_commands.KEYWORDS:
            self.assertIn('`lights %s' % keyword, usage, keyword)

    def testLimits(self):
        self.assertIn('A rig holds at most %d lights, and at most %d of them '
                      'cast shadows.' % (lighting_commands.MAX_LIGHTS,
                                         lighting_commands.MAX_SHADOWS),
                      flat(section(self.doc, 'Concepts')))

    def testPresetsTable(self):
        rows = ordered_rows(subsection(self.doc, 'Presets'))
        presets = lighting_commands.presets()
        self.assertEqual(len(rows), len(presets))
        for line, (name, description) in zip(rows, presets):
            _desc, ambient, lights = lighting_commands.PRESETS[name]
            cells = [c.strip() for c in line.strip().strip('|').split('|')]
            self.assertEqual(cells, [
                '`%s`' % name, ', '.join(l['name'] for l in lights),
                num(ambient), description])

    def testEveryPresetsFirstLightCastsAShadow(self):
        self.assertIn("Each preset's first light casts a shadow.",
                      flat(subsection(self.doc, 'Presets')))
        for name, (_d, _a, lights) in lighting_commands.PRESETS.items():
            self.assertTrue(lights[0].get('shadow'), name)


# --- platform defaults ------------------------------------------------------

class TestPlatformDefaults(DocCase):
    """Every platform default the page states, derived from the code. If
    #623's device run changes one, this fails until the page follows."""

    AIR_RESOLUTION = {1: 'full', 2: 'half'}
    AIR_FILTER = {1: 'one tap', 2: '3x3'}
    HDR = {True: 'HDR', False: 'the 8-bit knee'}

    def row(self, name):
        return table_rows(section(self.doc, 'Settings'))[name]

    def both(self, mac, ios):
        return '%s on the Mac, %s on iOS' % (mac, ios)

    def defaults(self):
        return {
            'metal_light_shadow_size': (
                lighting._light_shadow_map_size(0),
                lighting._light_shadow_map_size(0, mobile=True)),
            'metal_light_air_resolution': (
                self.AIR_RESOLUTION[lighting._light_air_resolution(0, False)],
                self.AIR_RESOLUTION[lighting._light_air_resolution(0, True)]),
            'metal_light_air_shadow_filter': (
                self.AIR_FILTER[lighting._light_air_shadow_filter(0, False)],
                self.AIR_FILTER[lighting._light_air_shadow_filter(0, True)]),
            'metal_light_hdr': (
                self.HDR[bool(_cmd.light_hdr(cmd._COb, 0, False))],
                self.HDR[bool(_cmd.light_hdr(cmd._COb, 0, True))]),
        }

    def testSettingsRowsGiveBothPlatforms(self):
        for name, (mac, ios) in self.defaults().items():
            self.assertIn('`0`: ' + self.both(mac, ios), self.row(name)[2],
                          name)

    def testShadowsSectionSize(self):
        mac, ios = self.defaults()['metal_light_shadow_size']
        self.assertIn('0 is the platform default (%d on the Mac, %d on iOS)'
                      % (mac, ios), flat(section(self.doc, 'Shadows')))

    def testHdrValues(self):
        self.assertTrue(_cmd.light_hdr(cmd._COb, 1, False))
        self.assertTrue(_cmd.light_hdr(cmd._COb, 1, True))
        self.assertFalse(_cmd.light_hdr(cmd._COb, 2, False))
        self.assertFalse(_cmd.light_hdr(cmd._COb, 2, True))
        mac, ios = self.defaults()['metal_light_hdr']
        text = flat(section(self.doc, 'Exposure and HDR'))
        if mac == ios:
            want = '0 is the platform default (%s on the Mac and on iOS' % mac
        else:
            want = '0 is the platform default (%s on the Mac, %s on iOS' % (
                mac, ios)
        self.assertIn(want, text)
        self.assertIn('1 HDR; 2 the 8-bit soft knee', text)

    def gate(self):
        text = swift(os.path.join(SHARED, 'MetalViewport.swift'))
        body = text[text.index('enum AirRedrawGate'):]
        fps = re.search(r'static let defaultFPS: Double = (\d+)', body)
        lo_hi = re.search(r'static let fpsRange: ClosedRange<Double> = '
                          r'(\d+)\.\.\.(\d+)', body)
        self.assertIsNotNone(fps)
        self.assertIsNotNone(lo_hi)
        self.assertIn('"RAYMOL_AIR_FPS"', body)
        self.assertIn('"RAYMOL_AIR_LOG"', body)
        return int(fps.group(1)), int(lo_hi.group(1)), int(lo_hi.group(2))

    def testDustCap(self):
        fps, lo, hi = self.gate()
        self.assertIn('at most %d times a second' % fps,
                      flat(section(self.doc, 'The atmosphere command')))
        perf = flat(section(self.doc, 'Performance and iOS'))
        self.assertIn('`RAYMOL_AIR_FPS=<n>`, with n from %d to %d, replaces '
                      'the cap of %d air redraws a second' % (lo, hi, fps),
                      perf)
        self.assertIn('`RAYMOL_AIR_LOG=1`', perf)

    def testIOSDefaultsAreProvisional(self):
        defaults = self.defaults()
        fps = self.gate()[0]
        size = defaults['metal_light_shadow_size'][1]
        air = defaults['metal_light_air_resolution'][1]
        tap = defaults['metal_light_air_shadow_filter'][1]
        hdr = defaults['metal_light_hdr'][1]
        app = flat(subsection(self.doc, 'iPhone and iPad'))
        self.assertIn('**iOS defaults are provisional.** They hold until '
                      "#623's device run: the shadow map size (%d), the air "
                      "resolution (%s), the air's shadow filter (%s), the "
                      '%d-a-second dust cap and HDR (%s).' % (
                          size, air, tap, fps,
                          'on' if hdr == 'HDR' else 'off'), app)
        perf = flat(section(self.doc, 'Performance and iOS'))
        self.assertIn('The iOS defaults (%d shadow maps, %s-resolution air, '
                      '%s, HDR %s, %d redraws a second) are provisional until '
                      "#623's device run." % (
                          size, air, tap, 'on' if hdr == 'HDR' else 'off',
                          fps), perf)
        self.assertIn("provisional until #623's device run",
                      flat(section(self.doc, 'Settings')))


# --- notices and texts ------------------------------------------------------

class TestNotices(DocCase):

    def testRayNotice(self):
        cmd.fragment('ala')
        cmd.set_lights({'enabled': True, 'lights': [{'name': 'key'}]})
        try:
            notice = lighting._lights_ray_notice()
        finally:
            cmd.set_lights(None)
        self.assertTrue(notice)
        text = section(self.raw, 'Metal only: the CPU ray tracer and exports')
        self.assertIn('\n Ray: %s\n' % notice, text)
        flat_text = flat(text)
        for name in ('`ray`', '`png ..., ray=1`', '`mpng`',
                     '`feedback disable, ray, warnings`', '`Note:`',
                     '`capture_viewport`', 'decided in #626'):
            self.assertIn(name, flat_text, name)

    def line_pattern(self, line):
        """A log line with every number a number pattern."""
        parts = re.split(r'(\d+(?:\.\d+)?)', line)
        return ''.join(r'\d+(?:\.\d+)?' if i % 2 else re.escape(p)
                       for i, p in enumerate(parts))

    def testGpuTimingLines(self):
        window = lighting._gpu_time_replay(
            [(3.1, 3, 1024, False, 0.0), (3.2, 3, 1024, False, 1.2)],
            1)['lines']
        frame = lighting._gpu_time_replay(
            [(3.12, 3, 1024, False, 0.0)], 2)['lines']
        self.assertTrue(window and frame)
        text = section(self.raw, 'Performance and iOS')
        for line in (window[0], frame[0]):
            self.assertRegex(text, r'\n%s\n' % self.line_pattern(line), line)
        self.assertIn('`set metal_gpu_timing, 1`', text)

    def hint_texts(self):
        text = swift(os.path.join(SHARED, 'LightsAtmosphere.swift'))
        start = text.index('enum AtmosphereHint')
        block = text[start:text.index('var glyph', start)]
        hints = {}
        for case, body in re.findall(r'case \.(\w+):\s*return (.*?)(?=case |\}\s*\})',
                                     block, re.S):
            hints[case] = ''.join(re.findall(r'"((?:[^"\\]|\\.)*)"', body))
        self.assertEqual(set(hints), {'noLights', 'lightsOff', 'backlitHaze'})
        return text, hints

    def testAtmosphereHints(self):
        text, hints = self.hint_texts()
        card = flat(subsection(self.doc, 'The Atmosphere card'))
        for case, hint in hints.items():
            self.assertIn('"%s"' % hint, card, case)
        threshold = re.search(r'static let backlitHazeThreshold = ([\d.]+)',
                              text).group(1)
        self.assertIn('Haze above about %s with a light behind the molecule'
                      % threshold, flat(subsection(self.doc, 'Backlit haze')))

    def testStartLook(self):
        text = swift(os.path.join(SHARED, 'LightsAtmosphere.swift'))
        look = re.search(r'static let startLook: \[AirValue\] = \[(.*?)\]\n',
                         text).group(1)
        values = dict(re.findall(r'AirValue\("(\w+)", ([\d.]+)\)', look))
        self.assertEqual(sorted(values), ['dust', 'haze'])
        self.assertIn('a start look of haze %s and dust %s' % (
            values['haze'], values['dust']),
            flat(subsection(self.doc, 'The Atmosphere card')))


# --- UI labels --------------------------------------------------------------

class TestLabels(DocCase):

    def labels(self):
        """Every bold span that is not a lead-in (ending with '.' or ':')."""
        spans = [flat(s) for s in BOLD_RE.findall(self.doc)]
        return [s for s in spans if not s.endswith(('.', ':'))]

    def testEveryBoldLabelIsInItsSwiftFile(self):
        labels = self.labels()
        self.assertGreaterEqual(len(set(labels)), 25)
        sources = {}
        for label in labels:
            self.assertIn(label, LABELS, 'bold %r is not a known UI label' %
                          label)
            path = LABELS[label]
            if path not in sources:
                sources[path] = swift(path)
            self.assertIn('"%s"' % label, sources[path],
                          (label, os.path.relpath(path, ROOT)))

    def testEveryKnownLabelIsUsed(self):
        # keeps LABELS honest: a label the page stopped naming goes too
        self.assertEqual(set(LABELS) - set(self.labels()), set())

    def testTheMenuItemIsInTheToolsMenu(self):
        text = swift(os.path.join(SHARED, 'PyMOLApp.swift'))
        tools = text.index('CommandMenu("Tools")')
        self.assertLess(tools, text.index('"Enter Lights Mode"'))


# --- the gallery section ----------------------------------------------------

class TestGallerySection(DocCase):

    def testSectionsTable(self):
        spec = importlib.util.spec_from_file_location(
            'lighting_docs_gallery', os.path.join(LIGHTING_SCRIPTS, 'gallery.py'))
        gallery = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(gallery)
        text = section(self.doc, 'Regenerating the gallery')
        rows = ordered_rows(text)
        self.assertEqual(len(rows), len(gallery.SECTIONS))
        total = 0
        for line, sec in zip(rows, gallery.SECTIONS):
            cells = [c.strip() for c in line.strip().strip('|').split('|')]
            self.assertEqual(cells[:3], ['`%s`' % sec.name, str(len(sec.tags)),
                                         '`%s`' % sec.scenes], sec.name)
            total += len(sec.tags)
        self.assertIn('%d images in seven sections' % total, flat(text))
        self.assertEqual(len(gallery.SECTIONS), 7)
        source = read(os.path.join(LIGHTING_SCRIPTS, 'gallery.py'))
        for option in ('--app', '--out', '--sections', '--dry-run',
                       '--skip-render', '--timeout'):
            self.assertIn("add_argument('%s'" % option, source, option)
            self.assertIn(option, section(self.raw,
                                          'Regenerating the gallery'), option)


# --- the release-notes draft ----------------------------------------------

# The footer every macOS release note ends with (release-notes-style.md).
FOOTER = ('Built on the open-source PyMOL engine. Updates install '
          'automatically via the in-app updater (**Check for Updates\u2026** '
          'in the app menu).')

# Words that mark an iOS-only item: those go in the PR's iOS What's New block
# for cut-ios-release, never in the Sparkle notes.
IOS_WORDS = re.compile(r'\b(iPhone|iPad|iOS|touch|long[- ]press|pinch)\b', re.I)


class TestReleaseNotes(DocCase):

    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        raw = read(NOTES)
        # the header comment is for the release cut, not the user
        cls.notes = re.sub(r'<!--.*?-->', '', raw, flags=re.S).strip()
        cls.studio = cls.notes[cls.notes.index('\n### Studio lights\n'):
                               cls.notes.index('\nSee [docs/lighting.md]')]

    def testHouseStyle(self):
        self.assertTrue(self.notes.startswith('## RayMol'), self.notes[:40])
        self.assertTrue(self.notes.endswith(FOOTER), self.notes[-200:])
        if os.path.isfile(STYLE):
            self.assertIn(FOOTER, read(STYLE))
        # every bullet bolds its change first
        bullets = [l for l in self.studio.splitlines() if l.startswith('- ')]
        self.assertGreaterEqual(len(bullets), 8)
        for line in bullets:
            self.assertTrue(line.startswith('- **'), line[:60])

    def testMacOnly(self):
        found = IOS_WORDS.findall(self.notes)
        self.assertEqual(found, [], 'iOS-only wording in the macOS notes')

    def testLinksTheGuide(self):
        self.assertIn('](../../lighting.md)', self.notes)

    def testBoldLabelsAreInTheirSwiftFiles(self):
        spans = [flat(s) for s in BOLD_RE.findall(self.studio)]
        labels = [s for s in spans if not s.endswith(('.', ':'))]
        self.assertGreaterEqual(len(set(labels)), 10)
        for label in labels:
            self.assertIn(label, LABELS, 'bold %r is not a known UI label' %
                          label)
            self.assertIn('"%s"' % label, swift(LABELS[label]), label)

    def testQuotedCommandsRun(self):
        # the commands the notes quote are real and run without an error
        quoted = ('lights three_point', 'lights key, warmth=3800, intensity=1.3',
                  'lights add, back, orbit=180', 'lights',
                  'atmosphere haze=0.3, dust=0.5', 'set metal_light_hdr, 2',
                  'lights off')
        for line in quoted:
            self.assertIn('`%s`' % line, self.notes, line)
        options = pymol.invocation.options
        exit_on_error, options.exit_on_error = options.exit_on_error, 0
        cmd.reinitialize()
        cmd.load(PDB, 'm')
        cmd.show_as('cartoon')
        try:
            with capture_output() as out:
                for line in quoted:
                    cmd.do(line, echo=0)
            self.assertNotIn('Error', out(), out())
        finally:
            options.exit_on_error = exit_on_error
            cmd.set_lights(None)
            cmd.reinitialize()


# --- runnable examples ------------------------------------------------------

def blocks(raw, kind):
    return [m.group(2) for m in FENCE_RE.finditer(raw)
            if m.group(1).strip() == kind]


class TestExamples(DocCase):

    @classmethod
    def setUpClass(cls):
        super(TestExamples, cls).setUpClass()
        spec = importlib.util.spec_from_file_location(
            'lighting_docs_render', os.path.join(LIGHTING_SCRIPTS, 'render.py'))
        render = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(render)
        cls.view = render.VIEW

    def setUp(self):
        super(TestExamples, self).setUp()
        self.cwd = os.getcwd()
        self.tmp = tempfile.mkdtemp(prefix='l627docs')
        self.addCleanup(shutil.rmtree, self.tmp, True)
        options = pymol.invocation.options
        self.exit_on_error = options.exit_on_error
        # the runner's -y would quit on an example's error; report it instead
        options.exit_on_error = 0

    def tearDown(self):
        os.chdir(self.cwd)
        pymol.invocation.options.exit_on_error = self.exit_on_error
        self.fresh(load=False)
        super(TestExamples, self).tearDown()

    def fresh(self, load=True):
        cmd.scene('*', 'clear')
        cmd.set_lights(None)
        cmd.reinitialize()
        if not load:
            return
        cmd.load(PDB, 'm')
        cmd.remove('solvent')
        cmd.hide('everything')
        cmd.show('cartoon', 'm')
        cmd.show('sticks', 'organic')
        cmd.show('surface', 'm and polymer')
        cmd.set('async_builds', 0)
        cmd.viewport(640, 480)
        cmd.set_view(self.view)

    def run_block(self, kind, code):
        """Run one block in a fresh session in an empty directory; returns
        (output, files written, exception text or None)."""
        self.fresh()
        os.chdir(self.tmp)
        failure = None
        try:
            with capture_output() as output:
                try:
                    if kind == 'pymol':
                        for line in code.splitlines():
                            if line.strip():
                                cmd.do(line, echo=0)
                    else:
                        exec(compile(code, '<docs/lighting.md>', 'exec'),
                             {'__name__': '__lighting_docs__'})
                except Exception:
                    failure = traceback.format_exc()
        finally:
            os.chdir(self.cwd)
        return output(), sorted(os.listdir(self.tmp)), failure

    def assertRuns(self, kind, code):
        text, files, failure = self.run_block(kind, code)
        where = '%s block:\n%s' % (kind, code)
        self.assertIsNone(failure, '%s\n%s' % (where, failure))
        self.assertNotIn('Error', text, '%s\noutput:\n%s' % (where, text))
        self.assertNotIn('Traceback', text, '%s\noutput:\n%s' % (where, text))
        self.assertEqual(files, [], '%s wrote files' % where)

    def testTheRunnerCatchesErrors(self):
        # the checks below would pass vacuously if errors went unseen
        text, files, failure = self.run_block('pymol',
                                              'lights key, pitch=100\n')
        self.assertIn('Error', text)
        text, files, failure = self.run_block(
            'python', "from pymol import cmd\ncmd.lights('nolight', orbit=1)\n")
        self.assertIsNotNone(failure)
        text, files, failure = self.run_block(
            'python', "open('written.txt', 'w').close()\n")
        self.assertEqual(files, ['written.txt'])

    def testPymolBlocks(self):
        found = blocks(self.raw, 'pymol')
        self.assertGreaterEqual(len(found), 10)
        for code in found:
            self.assertRuns('pymol', code)

    def testPythonBlocks(self):
        found = blocks(self.raw, 'python')
        self.assertGreaterEqual(len(found), 1)
        for code in found:
            self.assertRuns('python', code)

    def testTextBlocksHoldTheErrors(self):
        # the error examples are real: each ' Error: ' line is what the
        # command above it prints now, in a session where the earlier lines
        # of its block ran
        checked = 0
        for code in blocks(self.raw, 'text'):
            lines = code.splitlines()
            if not any(l.startswith('PyMOL>') for l in lines):
                continue
            self.fresh()
            for i, line in enumerate(lines):
                if not line.startswith('PyMOL>'):
                    continue
                with capture_output() as output:
                    cmd.do(line[len('PyMOL>'):], echo=0)
                said = [l for l in output().splitlines() if 'Error' in l]
                expected = lines[i + 1] if i + 1 < len(lines) else ''
                if expected.startswith(' Error: '):
                    self.assertEqual([l.strip() for l in said],
                                     [expected.strip()], line)
                    checked += 1
                else:
                    self.assertEqual(said, [], line)
        self.assertGreaterEqual(checked, 3)
