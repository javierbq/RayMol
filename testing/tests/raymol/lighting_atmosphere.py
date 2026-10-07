"""The Atmosphere card in Lights mode: the Python half (#726).

The card (swiftui/PyMOLViewer/Shared/LightsAtmosphere.swift and
LightsAtmosphereCard.swift) edits the rig's air two ways:

* slider ticks and typed values go through the bridge setter at index -1
  (PyMOLBridge_LightSet -> SceneLightSet, the C++ that lighting._light_set
  calls), with no Python;
* the On/Off switch runs one echoed `atmosphere` command: Off is exactly
  `atmosphere off`, On is `atmosphere f=v, ...` with the air the card
  remembered, or the start look `atmosphere haze=0.2, dust=0.5`.

Its slider ranges and defaults come from appkit_lights.write_air_fields, the
air rows of the C++ field table (lighting._light_fields()), so the app holds
no copy of them.

TestAirFieldsHelper: the helper writes exactly those rows, in the JSON the
Swift AirField decoder reads, and never touches the rig.

TestCardCommands runs the switch's exact command strings through cmd.do (the
app's runCommand path). The same literals are pinned on the Swift side by
LightsActionInvocationTests (LightsModeTests.swift); change both together.
The card prints numbers in Swift's shortest round-trip form (0.35, 1.0,
-0.25, 1e-05), which Python's repr matches for these values, and quantises
slider values to integer steps; every slider stop must read back exactly
with at most two decimals.

TestCardSetterPath: what the card's slider path writes is what `atmosphere`
reads and prints (the card -> command half of the mirroring), clamped to the
table, and refused with no rig.

TestSavedAfterCardEdits: air written through the card's path saves in .pse
sessions and scenes as before (no new storage), and the bar's Revert
(appkit_lights.restore) brings back the entry air.

CI builds the GLUT flavour without a GPU, so this exercises _cmd and Python
only. A small peptide (cmd.fab) gives the rig a real frame.

Runs on a RayMol build:
    pymol -ckqy testing/testing.py --run \
        testing/tests/raymol/lighting_atmosphere.py
"""
import base64
import contextlib
import io
import json
import os
import re
import shutil
import tempfile

import pymol
import pymol.invocation
from pymol import CmdException
from pymol import appkit_lights, cmd, lighting, raymol_scene_anim, \
    raymol_scenes, testing

# The peptide that gives the rig its frame.
PEPTIDE = 'ACDEFG'

# The air fields, in table order (the order of the .pse session list).
AIR_FIELDS = ['haze', 'dust', 'dust_size', 'dust_speed', 'scatter', 'seed']

# What write_air_fields writes today, byte for byte (seed's bounds are
# whole numbers; Swift decodes every number as a Double). Swift's
# AirFieldDecodeTests (LightsAtmosphereTests.swift) decodes this same
# literal; change both together (and the `atmosphere` help) when a range or
# default moves in layer1/LightRig.cpp.
HELPER_JSON = (
    '[{"name": "haze", "kind": "float", "default": 0.0, "min": 0.0, '
    '"max": 1.0}, '
    '{"name": "dust", "kind": "float", "default": 0.0, "min": 0.0, '
    '"max": 1.0}, '
    '{"name": "dust_size", "kind": "float", "default": 0.35, "min": 0.05, '
    '"max": 2.0}, '
    '{"name": "dust_speed", "kind": "float", "default": 1.0, "min": 0.0, '
    '"max": 10.0}, '
    '{"name": "scatter", "kind": "float", "default": 0.55, "min": -0.9, '
    '"max": 0.9}, '
    '{"name": "seed", "kind": "int", "default": 0, "min": 0, '
    '"max": 1000000}]')

# The card's slider resolutions (AirParameter.stepsPerUnit): steps per unit,
# not ranges. A slider value is round(x * steps) / steps.
STEPS = {'haze': 100, 'dust': 100, 'dust_size': 100, 'dust_speed': 20,
         'scatter': 100}

# The switch's On command with nothing remembered (AtmosphereSwitch.startLook,
# the orchestrator's Q1): a UI default, not a field default.
START_LOOK = {'haze': 0.2, 'dust': 0.5}
START_LOOK_COMMAND = 'atmosphere haze=0.2, dust=0.5'

# A remembered air away from every default, as the card prints it (Swift's
# shortest round-trip text; 1e-05 is a typed value, which passes unrounded).
REMEMBERED = [('haze', '1e-05'), ('dust', '0.3'), ('dust_size', '0.6'),
              ('dust_speed', '2.5'), ('scatter', '-0.25'), ('seed', '7')]

# A slider value's text: an optional minus, digits, at most two decimals.
TWO_DECIMALS = re.compile(r'^-?\d+(\.\d{1,2})?$')


def b64(text):
    """What the app sends: base64 of the UTF-8 text
    (Data(text.utf8).base64EncodedString() in Swift)."""
    return base64.b64encode(text.encode('utf-8')).decode('ascii')


def output(func, *args, **kwargs):
    """Run func, return (result, what it printed from Python)."""
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        result = func(*args, **kwargs)
    return result, buf.getvalue()


def do(line, echo=1):
    """cmd.do(line), the app's command path; returns the printed text.
    The runner's -y (exit on error) would quit on an error, so it is off for
    the call. echo=0 keeps the 'PyMOL>' echo of a long loop out of the
    log."""
    options = pymol.invocation.options
    exit_on_error = options.exit_on_error
    options.exit_on_error = 0
    try:
        return output(cmd.do, line, echo=echo)[1]
    finally:
        options.exit_on_error = exit_on_error


def air_rows():
    """The air rows of the C++ field table:
    [(name, kind, default, min, max), ...] in table order."""
    return [tuple(row[1:]) for row in lighting._light_fields()
            if row[0] == 'air']


def air_table():
    """name -> (kind, default, min, max)."""
    return {row[0]: row[1:] for row in air_rows()}


def air_defaults():
    return {name: entry[1] for name, entry in air_table().items()}


def slider_stops(field):
    """Every value the card's slider for `field` can write, as the card
    prints it: str(k / steps) for each whole k across the table range."""
    _kind, _default, lo, hi = air_table()[field]
    steps = STEPS[field]
    first, last = lo * steps, hi * steps
    # the table's ends are whole steps (the card's slider ends on them)
    assert abs(first - round(first)) < 1e-9, (field, lo)
    assert abs(last - round(last)) < 1e-9, (field, hi)
    return [str(k / steps) for k in range(round(first), round(last) + 1)]


class AtmosphereCase(testing.PyMOLTestCase):

    def setUp(self):
        super().setUp()
        cmd.fab(PEPTIDE, 'pep')

    def tearDown(self):
        lighting.set_lights(None)
        super().tearDown()

    def air(self):
        rig = lighting.get_lights()
        return None if rig is None else rig['air']

    def three_point(self, **air):
        """A lit three_point rig with the given air (set through the card's
        setter path)."""
        do('lights three_point')
        for field, value in air.items():
            lighting._light_set(-1, field, value)
        return lighting.get_lights()


# --- the field table helper ---------------------------------------------------

class TestAirFieldsHelper(AtmosphereCase):

    def setUp(self):
        super().setUp()
        self.tmp = tempfile.mkdtemp(prefix='lighting_atmosphere_')

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)
        super().tearDown()

    def write(self, payload):
        return output(appkit_lights.write_air_fields, payload)

    def testRowsAreTheCoreAirRows(self):
        # a path with a space and non-ASCII, as a user's temp dir can have
        path = os.path.join(self.tmp, 'air fields é 1.json')
        ok, text = self.write(b64(path))
        self.assertIs(ok, True)
        self.assertEqual(text, '')
        with open(path, encoding='utf-8') as handle:
            got = json.load(handle)
        want = [{'name': name, 'kind': kind, 'default': default,
                 'min': lo, 'max': hi}
                for name, kind, default, lo, hi in air_rows()]
        self.assertEqual(got, want)
        for entry in got:
            self.assertEqual(list(entry),
                             ['name', 'kind', 'default', 'min', 'max'])
        self.assertEqual([entry['name'] for entry in got], AIR_FIELDS)
        # every air field has a range (the card's slider ends)
        for entry in got:
            self.assertIsNotNone(entry['min'], entry['name'])
            self.assertIsNotNone(entry['max'], entry['name'])
            self.assertLessEqual(entry['min'], entry['default'])
            self.assertLessEqual(entry['default'], entry['max'])
        # the defaults are what `atmosphere off` sets
        self.assertEqual({e['name']: e['default'] for e in got},
                         air_defaults())

    def testJsonIsTheSwiftFixture(self):
        path = os.path.join(self.tmp, 'air.json')
        ok, _ = self.write(b64(path))
        self.assertIs(ok, True)
        with open(path, encoding='utf-8') as handle:
            self.assertEqual(handle.read(), HELPER_JSON)

    def testCardSliderFieldsAreTheFloatAirFields(self):
        """The card has a slider for every float air field (seed stays
        command-only, Q5)."""
        floats = [name for name, kind, *_ in air_rows() if kind == 'float']
        self.assertEqual(floats, list(STEPS))
        for field, value in START_LOOK.items():
            _kind, _default, lo, hi = air_table()[field]
            self.assertTrue(lo <= value <= hi, field)

    def testNeverTouchesTheRig(self):
        path = os.path.join(self.tmp, 'air.json')
        # no rig: none is created
        ok, _ = self.write(b64(path))
        self.assertIs(ok, True)
        self.assertIsNone(lighting.get_lights())
        # a rig with air: byte for byte the same afterwards
        self.three_point(haze=0.3, dust=0.4, scatter=-0.2)
        before = lighting._lights_json()
        ok, _ = self.write(b64(path))
        self.assertIs(ok, True)
        ok, _ = self.write(b64(os.path.join(self.tmp, 'no', 'such.json')))
        self.assertIs(ok, False)
        self.assertEqual(lighting._lights_json(), before)

    def testBadPayloadFailsWithOneLine(self):
        for label, payload in (
                ('missing directory',
                 b64(os.path.join(self.tmp, 'no', 'such', 'dir', 'a.json'))),
                ('a directory', b64(self.tmp)),
                ('not base64', 'not base64!'),
                ('not UTF-8', base64.b64encode(b'\xff\xfe').decode('ascii'))):
            with self.subTest(label):
                ok, text = self.write(payload)
                self.assertIs(ok, False)
                lines = text.splitlines()
                self.assertEqual(len(lines), 1, text)
                self.assertTrue(
                    lines[0].startswith(' lights: air fields failed: '), text)

    def testTableErrorNeverRaises(self):
        """A failing table read prints one line and returns False."""
        def broken(*, _self=cmd):
            raise CmdException('the table is broken')
        saved = lighting._light_fields
        lighting._light_fields = broken
        try:
            ok, text = self.write(b64(os.path.join(self.tmp, 'air.json')))
        finally:
            lighting._light_fields = saved
        self.assertIs(ok, False)
        self.assertEqual(text, ' lights: air fields failed: the table is '
                               'broken\n')
        self.assertFalse(os.path.exists(os.path.join(self.tmp, 'air.json')))


# --- the switch's command strings ---------------------------------------------

class TestCardCommands(AtmosphereCase):
    """The exact strings LightsAction.invocation sends for the switch."""

    def testOffGoesBackToTheTableDefaults(self):
        rig = self.three_point(haze=0.3, dust=0.5, dust_size=0.6,
                               dust_speed=2.5, scatter=-0.25)
        lighting._light_set(-1, 'seed', 7)
        do('atmosphere off')
        after = lighting.get_lights()
        self.assertEqual(after['air'], air_defaults())
        # only the air changed
        self.assertEqual(after['lights'], rig['lights'])
        self.assertEqual((after['enabled'], after['ambient'],
                          after['classic']),
                         (rig['enabled'], rig['ambient'], rig['classic']))

    def testOffWithNoRigChangesNothing(self):
        text = do('atmosphere off')
        self.assertIsNone(lighting.get_lights())
        lines = [line for line in text.splitlines()
                 if 'no light rig' in line]
        self.assertEqual(lines, [' atmosphere: no light rig'], text)

    def testStartLookWithNoRigCreatesAnOffRig(self):
        do(START_LOOK_COMMAND)
        rig = lighting.get_lights()
        self.assertIsNotNone(rig)
        self.assertIs(rig['enabled'], False)
        self.assertEqual(rig['lights'], [])
        self.assertEqual(rig['air'], dict(air_defaults(), **START_LOOK))
        # and the bar's Revert to 'no rig' removes it again
        ok, _ = output(appkit_lights.restore, b64('null'))
        self.assertIs(ok, True)
        self.assertIsNone(lighting.get_lights())

    def testStartLookOnALitRig(self):
        rig = self.three_point()
        do(START_LOOK_COMMAND)
        after = lighting.get_lights()
        self.assertEqual(after['air'], dict(air_defaults(), **START_LOOK))
        self.assertEqual(after['lights'], rig['lights'])
        self.assertIs(after['enabled'], True)

    def testOffThenOnRestoresExactly(self):
        """Off, then On with the remembered air in the card's number format,
        gives back the rig byte for byte. On sends only the fields that
        differ from the current air (here, Off's defaults)."""
        defaults = air_defaults()
        for label, remembered in (
                ('every field', REMEMBERED),
                ('dust_size at its default',
                 [(f, '0.35' if f == 'dust_size' else v)
                  for f, v in REMEMBERED])):
            with self.subTest(label):
                lighting.set_lights(None)
                self.three_point()
                for field, text in remembered:
                    value = int(text) if field == 'seed' else float(text)
                    lighting._light_set(-1, field, value)
                before = lighting._lights_json()
                do('atmosphere off')
                self.assertEqual(self.air(), defaults)
                sent = [(f, v) for f, v in remembered
                        if float(v) != defaults[f]]
                line = 'atmosphere ' + ', '.join(
                    '%s=%s' % (f, v) for f, v in sent)
                do(line)
                self.assertEqual(lighting._lights_json(), before, line)

    def testEverySliderStopReadsBackExactly(self):
        """Each value a slider can write, printed as the card prints it,
        has at most two decimals and reads back through `atmosphere`
        exactly (what the console echo then shows is what is stored)."""
        self.three_point()
        for field in STEPS:
            stops = slider_stops(field)
            with self.subTest(field):
                self.assertGreater(len(stops), 10)
                for text in stops:
                    self.assertRegex(text, TWO_DECIMALS)
                    do('atmosphere %s=%s' % (field, text), echo=0)
                    self.assertEqual(self.air()[field], float(text), text)
                # the slider's ends are the table's
                _kind, _default, lo, hi = air_table()[field]
                self.assertEqual((float(stops[0]), float(stops[-1])),
                                 (lo, hi))

    def testSliderStopsHitTheDefaults(self):
        """Each slider can land on its table default (the value Off sets)."""
        for field in STEPS:
            with self.subTest(field):
                self.assertIn(air_defaults()[field],
                              [float(s) for s in slider_stops(field)])


# --- the card's setter path ---------------------------------------------------

# A value away from the default for each slider field, on a slider stop.
EDITS = {'haze': 0.4, 'dust': 0.45, 'dust_size': 0.6, 'dust_speed': 2.5,
         'scatter': -0.25}


class TestCardSetterPath(AtmosphereCase):
    """lighting._light_set(-1, ...) is the C++ the card's slider path calls
    (PyMOLBridge_LightSet -> SceneLightSet)."""

    def testSetterIsWhatAtmosphereReads(self):
        self.three_point()
        for field, value in EDITS.items():
            with self.subTest(field):
                lighting._light_set(-1, field, value)
                self.assertEqual(lighting.get_lights()['air'][field], value)
                self.assertEqual(lighting._light_get(-1, field), value)
                result, text = output(cmd.atmosphere)
                self.assertEqual(result[field], value)
                self.assertIn('%s %g' % (field, value), text)
        # and the console's form reads the same
        text = do('atmosphere')
        self.assertIn('haze 0.4, dust 0.45, dust_size 0.6, dust_speed 2.5, '
                      'scatter -0.25', text)

    def testSetterClampsToTheTableRange(self):
        self.three_point()
        for field in EDITS:
            _kind, _default, lo, hi = air_table()[field]
            with self.subTest(field):
                lighting._light_set(-1, field, hi + 1.0)
                self.assertEqual(self.air()[field], hi)
                lighting._light_set(-1, field, lo - 1.0)
                self.assertEqual(self.air()[field], lo)
                lighting._light_set(-1, field, hi)
                self.assertEqual(self.air()[field], hi)
                lighting._light_set(-1, field, lo)
                self.assertEqual(self.air()[field], lo)

    def testNoRigIsRefusedAndCreatesNothing(self):
        for field, value in EDITS.items():
            with self.subTest(field):
                with self.assertRaises(CmdException) as caught:
                    lighting._light_set(-1, field, value)
                self.assertIn('no rig', str(caught.exception))
                self.assertIsNone(lighting.get_lights())

    def testSetterOnAnEmptyRigTheSwitchCreated(self):
        do(START_LOOK_COMMAND)
        lighting._light_set(-1, 'dust', 0.7)
        rig = lighting.get_lights()
        self.assertEqual(rig['air'], dict(air_defaults(), haze=0.2, dust=0.7))
        self.assertIs(rig['enabled'], False)

    def testAirStaysOnAnOffRigAndThroughLightsOffAndClear(self):
        self.three_point()
        do('lights off')
        lighting._light_set(-1, 'haze', 0.4)
        rig = lighting.get_lights()
        self.assertIs(rig['enabled'], False)
        self.assertEqual(rig['air']['haze'], 0.4)
        do('lights on')
        self.assertEqual(self.air()['haze'], 0.4)
        lighting._light_set(-1, 'dust', 0.5)
        do('lights off')
        self.assertEqual((self.air()['haze'], self.air()['dust']), (0.4, 0.5))
        do('lights clear')
        rig = lighting.get_lights()
        self.assertEqual(rig['lights'], [])
        self.assertEqual((rig['air']['haze'], rig['air']['dust']), (0.4, 0.5))
        # a preset keeps the air too
        do('lights three_point')
        self.assertEqual((self.air()['haze'], self.air()['dust']), (0.4, 0.5))


# --- saved after card edits ---------------------------------------------------

class TestSavedAfterCardEdits(AtmosphereCase):

    def setUp(self):
        super().setUp()
        raymol_scenes.clear_all()
        raymol_scene_anim._track.clear()
        raymol_scene_anim._scene_marks[:] = []
        lights_track = getattr(raymol_scene_anim, '_lights_track', None)
        if lights_track is not None:
            lights_track.clear()

    def tearDown(self):
        raymol_scenes.clear_all()
        super().tearDown()

    def card_edits(self, **air):
        for field, value in air.items():
            lighting._light_set(-1, field, value)
        return lighting.get_lights()

    def testPseKeepsTheAir(self):
        for binary in (0, 1):
            with self.subTest(pse_binary_dump=binary):
                lighting.set_lights(None)
                self.three_point()
                rig = self.card_edits(**EDITS)
                text = lighting._lights_json()
                cmd.set('pse_binary_dump', binary)
                with testing.mktemp('.pse') as filename:
                    cmd.save(filename)
                    cmd.reinitialize()
                    self.assertIsNone(lighting.get_lights())
                    cmd.load(filename)
                self.assertEqual(lighting.get_lights(), rig)
                self.assertEqual(lighting._lights_json(), text)

    def testPseKeepsTheAirOfAnEmptyRig(self):
        """The switch's rig (off, no lights) saves its air too."""
        do(START_LOOK_COMMAND)
        rig = self.card_edits(dust_speed=2.5)
        with testing.mktemp('.pse') as filename:
            cmd.save(filename)
            cmd.reinitialize()
            cmd.load(filename)
        self.assertEqual(lighting.get_lights(), rig)

    def testSceneRecallBringsBackTheAir(self):
        self.three_point()
        a = self.card_edits(haze=0.25, dust=0.5)
        cmd.scene('A', 'store')
        b = self.card_edits(haze=0.6, dust_size=1.2, scatter=-0.4)
        cmd.scene('B', 'store')
        self.card_edits(haze=0.9, dust=0.1)
        cmd.scene('A', 'recall')
        self.assertEqual(lighting.get_lights()['air'], a['air'])
        cmd.scene('B', 'recall')
        self.assertEqual(lighting.get_lights()['air'], b['air'])

    def testRevertBringsBackTheEntryAir(self):
        self.three_point(haze=0.1, dust=0.3, scatter=-0.25)
        entry = lighting._lights_json()
        self.card_edits(**EDITS)
        do('atmosphere off')
        self.assertNotEqual(lighting._lights_json(), entry)
        ok, text = output(appkit_lights.restore, b64(entry))
        self.assertIs(ok, True)
        self.assertEqual(text, ' lights: reverted\n')
        self.assertEqual(lighting._lights_json(), entry)

    def testRevertRemovesARigTheCardCreated(self):
        """No rig at entry (the bridge's 'null'); the switch made one and a
        slider edited it; Revert removes it."""
        self.assertIsNone(lighting._lights_json())
        do(START_LOOK_COMMAND)
        self.card_edits(dust=0.8)
        ok, _ = output(appkit_lights.restore, b64('null'))
        self.assertIs(ok, True)
        self.assertIsNone(lighting.get_lights())
