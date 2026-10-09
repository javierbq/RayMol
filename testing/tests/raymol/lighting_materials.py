"""How each material takes a studio light (#615).

A studio light reaches a material through five terms the Metal rig fragments
read as their LightResponse: diffuse, highlight, exponent (as #613's
`sharpness`), tint and wrap. #615 derives them from the draw's FINAL material
params (MaterialLightResponseFor and MaterialLightSharpness,
layer1/Material.h): the table row plus the layer's Custom knobs. These tests
reach that C++ through _cmd.material_light_response, handed the exact tuple
_cmd.get_material_draw_params returns, and through _cmd.get_light_frame's
'classic_scale' (the rig's classic, which the material shaders' own key-light
terms follow). No CI job has a GPU or builds catch2, so this is how the C++
is tested (lighting checklist, "What CI must cover").

Expected values never come from the code under test: they are an in-test
port of the plan's rules (section 3.1), fed with the params the draw path
reports, plus the literal table of derived values the plan publishes.

Runs on a RayMol build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/lighting_materials.py
"""
import math
import struct

from pymol import _cmd, cmd, lighting, setting, testing
from pymol.constants import repres

TOL = 1e-4
SHININESS = 55.0

REP_INDEX = {'cartoon': repres['cartoon'], 'surface': repres['surface'],
             'stick': repres['sticks'], 'sphere': repres['spheres']}
REPS = ('surface', 'cartoon', 'stick', 'sphere')

NEUTRAL = {'diffuse': 1.0, 'highlight': 1.0, 'exponent': 0.0, 'tint': 0.0,
           'wrap': 0.0}
KEYS = ('diffuse', 'highlight', 'exponent', 'tint', 'wrap')

# The shader laws the response reproduces (kMaterialSrc, RendererMetal.mm),
# written out here rather than read from the code under test.
HIGHLIGHT_REF = 0.5          # a new light's default `highlight`
GLASS_KEY_GLINT = 1.2        # mat_glass_shade: 1.2 * pow(n.h1, expo)
GLASS_GLINT_EXP = 60.0       # expo = mix(60, 60 * 0.1, rough)
GLASS_FROST_DIM = 0.8        # strength x (1 - 0.8 * rough)
GLASS_FROST_EXP_SCALE = 0.1
MARBLE_WRAP = 0.35
JELLY_WET_EXP = 70.0         # mat_jelly_shade: p[2] * pow(n.h, 70)
JELLY_WET_TINT = 0.25        # mix(1, base * 1.3, 0.25)
JELLY_GLOW_WRAP = 0.6        # (n.l + 0.6) / 1.6
JELLY_GLOW_GAIN = 1.15       # base * 1.15
RUBBER_EXP = 8.0             # p[2] * pow(n.h, 8)
RUBBER_TINT = 0.7            # mix(1, base * 1.4, 0.7)
MIN_ROUGH = 0.1              # the reflective lobe's roughness floor
# Tint rule B (#615 Q1): the table metallic's studio tint is the CPU ray
# mapping's highlight tint (MaterialRayParamsFor: 0.8) over its table tint.
CPU_METALLIC_SPEC_TINT = 0.8
METALLIC_TABLE_TINT = 0.35
TINT_GAIN = CPU_METALLIC_SPEC_TINT / METALLIC_TABLE_TINT

# The plan's published values (section 3.1) at the table params.
PUBLISHED = {
    'default': (1.0, 1.0, 0.0, 0.0, 0.0),
    'matte': (1.0, 0.0, 0.0, 0.0, 0.0),
    'clay': (1.0, 0.0, 0.0, 0.0, 0.0),
    'rubber': (1.0, 0.34, 8.0, 0.7, 0.0),
    'marble': (1.0, 1.0, 0.0, 0.0, 0.35),
    'plastic': (1.0, 3.5368, 86.889, 0.0, 0.0),
    'metallic': (0.79, 3.0558, 30.0, 0.8, 0.0),
    'glass': (1.0, 2.4, 60.0, 0.0, 0.0),
    'frosted_glass': (1.0, 1.248, 27.6, 0.0, 0.0),
    'jelly': (0.4025, 2.2, 70.0, 0.25, 0.6),
}


def f32(x):
    return struct.unpack('f', struct.pack('f', x))[0]


def clamp01(x):
    return min(max(x, 0.0), 1.0) if x == x else 0.0


def material_names():
    return {name: mid for mid, name in setting.get_material_names(1)}


def draw_params(obj, rep):
    """(family, mode, reflect, tint, rough, (p0..p5)), as the draw uses."""
    f, m, r, t, ro, p = _cmd.get_material_draw_params(cmd._COb, obj,
                                                      REP_INDEX[rep])
    return f, m, r, t, ro, tuple(p)


def response(params, shininess=SHININESS):
    return _cmd.material_light_response(cmd._COb, params, shininess)


def oracle(name, params):
    """The plan's section 3.1, ported: the expected five terms."""
    _f, _m, reflect, tint, rough, p = params
    if name in ('matte', 'clay'):
        return dict(NEUTRAL, highlight=0.0)
    if name == 'rubber':
        return dict(NEUTRAL, highlight=max(p[2], 0.0) / HIGHLIGHT_REF,
                    exponent=RUBBER_EXP, tint=RUBBER_TINT)
    if name == 'marble':
        return dict(NEUTRAL, wrap=MARBLE_WRAP)
    if name in ('plastic', 'metallic'):
        reflect, tint = clamp01(reflect), clamp01(tint)
        a = max(clamp01(rough), MIN_ROUGH)
        n = max(2.0 / (a * a) - 2.0, 1.0)
        return {'diffuse': 1.0 - reflect * tint,
                'highlight': reflect * (n + 2.0) / (2.0 * math.pi),
                'exponent': n, 'tint': min(1.0, tint * TINT_GAIN), 'wrap': 0.0}
    if name in ('glass', 'frosted_glass'):
        r = clamp01(rough)
        expo = GLASS_GLINT_EXP + (GLASS_GLINT_EXP * GLASS_FROST_EXP_SCALE
                                  - GLASS_GLINT_EXP) * r
        return dict(NEUTRAL, highlight=GLASS_KEY_GLINT * (1.0 - GLASS_FROST_DIM * r)
                    / HIGHLIGHT_REF, exponent=expo)
    if name == 'jelly':
        return {'diffuse': JELLY_GLOW_GAIN * clamp01(p[1]),
                'highlight': max(p[2], 0.0) / HIGHLIGHT_REF,
                'exponent': JELLY_WET_EXP, 'tint': JELLY_WET_TINT,
                'wrap': JELLY_GLOW_WRAP}
    return dict(NEUTRAL)


class MaterialCase(testing.PyMOLTestCase):

    def setUp(self):
        super().setUp()
        cmd.reinitialize()
        cmd.fab('ACDEFGHIKM', 'p', ss=1)
        cmd.hide('everything')

    def use(self, name, rep, obj='p'):
        """`name` on `rep`, set on the object (a layer of its own, so a stick
        or sphere layer does not follow a cartoon)."""
        cmd.set('%s_material' % rep, name, obj)

    def assertResponse(self, got, want, msg=None, tol=TOL):
        for key in KEYS:
            self.assertAlmostEqual(
                got[key], want[key], delta=tol * max(1.0, abs(want[key])),
                msg='%s: %s %r != %r' % (msg, key, got[key], want[key]))

    def assertNeutral(self, got, msg=None):
        for key in KEYS:
            self.assertEqual(got[key], NEUTRAL[key], '%s: %s' % (msg, key))
        self.assertEqual(got['sharpness'], 1.0, msg)

    def assertSane(self, got, msg=None):
        for key in KEYS + ('sharpness',):
            self.assertTrue(math.isfinite(got[key]), '%s: %s %r' % (msg, key, got[key]))
        self.assertGreaterEqual(got['diffuse'], 0.0, msg)
        self.assertGreaterEqual(got['highlight'], 0.0, msg)
        self.assertGreaterEqual(got['wrap'], 0.0, msg)
        self.assertTrue(0.0 <= got['tint'] <= 1.0, msg)
        self.assertTrue(got['exponent'] == 0.0 or got['exponent'] >= 1.0, msg)


class TestResponseTable(MaterialCase):
    """Every implemented material on surface, cartoon, sticks and spheres,
    against the plan's rules, at shininess 55."""

    def testEveryMaterialOnEveryRep(self):
        names = material_names()
        self.assertEqual(sorted(names), sorted(PUBLISHED))
        for name in names:
            for rep in REPS:
                self.use(name, rep)
                params = draw_params('p', rep)
                got = response(params)
                label = '%s on %s' % (name, rep)
                self.assertSane(got, label)
                # default, and clear and frosted glass on sphere impostors
                # (MaterialResolve's degradation), draw as default
                degraded = (rep == 'sphere' and name in ('glass', 'frosted_glass'))
                self.assertEqual(params[0] == 0, name == 'default' or degraded,
                                 label)
                if params[0] == 0:
                    self.assertNeutral(got, label)
                    continue
                self.assertResponse(got, oracle(name, params), label)
                if got['exponent'] > 0.0:
                    self.assertAlmostEqual(got['sharpness'] * SHININESS,
                                           got['exponent'],
                                           delta=TOL * got['exponent'], msg=label)
                else:
                    self.assertEqual(got['sharpness'], 1.0, label)

    def testThePublishedTable(self):
        """The derived values the plan's table publishes, at table params."""
        for name, want in PUBLISHED.items():
            self.use(name, 'surface')
            got = response(draw_params('p', 'surface'))
            self.assertResponse(got, dict(zip(KEYS, want)), name, tol=2e-4)

    def testPublishedSharpness(self):
        want = {'plastic': 1.580, 'metallic': 0.545, 'glass': 1.091,
                'frosted_glass': 0.502, 'jelly': 1.273, 'rubber': 0.145,
                'matte': 1.0, 'clay': 1.0, 'marble': 1.0, 'default': 1.0}
        for name, sharp in want.items():
            self.use(name, 'surface')
            got = response(draw_params('p', 'surface'))
            self.assertAlmostEqual(got['sharpness'], sharp, delta=1e-3, msg=name)

    def testMatteAndClayTakeNoHighlight(self):
        for name in ('matte', 'clay'):
            for rep in REPS:
                self.use(name, rep)
                self.assertEqual(response(draw_params('p', rep))['highlight'],
                                 0.0, '%s on %s' % (name, rep))

    def testRepsWithoutAMaterialAreNeutral(self):
        for name in ('ribbon', 'mesh', 'dots', 'lines'):
            params = _cmd.get_material_draw_params(cmd._COb, 'p', repres[name])
            self.assertEqual(params[0], 0, name)
            self.assertNeutral(response(params), name)

    def testTheFrameShininess(self):
        """At the frame's own shininess the GPU's head.y * sharpness gives the
        material's exponent back."""
        shin = lighting._light_frame()['shininess']
        self.assertGreater(shin, 1e-3)
        for name in ('plastic', 'metallic', 'glass', 'jelly', 'rubber'):
            self.use(name, 'surface')
            got = response(draw_params('p', 'surface'), shin)
            self.assertAlmostEqual(got['sharpness'] * shin, got['exponent'],
                                   delta=TOL * got['exponent'], msg=name)


class TestSharpness(MaterialCase):

    def params(self, name):
        self.use(name, 'surface')
        return draw_params('p', 'surface')

    def testNeverInfOrNan(self):
        for name in ('plastic', 'matte', 'glass', 'default'):
            params = self.params(name)
            for shin in (0.0, 1e-4, float('nan'), 55.0, 200.0, float('inf'),
                         -3.0):
                got = response(params, shin)
                self.assertTrue(math.isfinite(got['sharpness']),
                                '%s at %r' % (name, shin))
                self.assertGreater(got['sharpness'], 0.0)

    def testOneWithoutAnExponentOrAShininess(self):
        plastic = self.params('plastic')
        for shin in (0.0, 1e-4, 1e-3, float('nan'), float('inf'), -3.0):
            self.assertEqual(response(plastic, shin)['sharpness'], 1.0, shin)
        matte = self.params('matte')
        for shin in (0.0, 55.0, 200.0):
            self.assertEqual(response(matte, shin)['sharpness'], 1.0, shin)

    def testExponentOverShininess(self):
        plastic = self.params('plastic')
        for shin in (0.01, 55.0, 200.0):
            got = response(plastic, shin)
            self.assertAlmostEqual(got['sharpness'],
                                   f32(got['exponent'] / f32(shin)),
                                   delta=1e-6 * got['sharpness'])


class TestDegradations(MaterialCase):

    def testClearAndFrostedGlassSpheresAreDefault(self):
        for name in ('glass', 'frosted_glass'):
            self.use(name, 'sphere')
            params = draw_params('p', 'sphere')
            self.assertEqual(params[:2], (0, 0), name)
            self.assertNeutral(response(params), name)

    def testJellySpheresKeepJellys(self):
        self.use('jelly', 'sphere')
        params = draw_params('p', 'sphere')
        self.assertEqual(params[1], material_names()['jelly'])
        self.assertResponse(response(params), oracle('jelly', params))

    def testSticksFollowingTheCartoonTakeItsResponse(self):
        cmd.show('cartoon')
        cmd.show('sticks', 'sidechain')
        cmd.set('cartoon_material', 'metallic', 'p')
        cmd.set('cartoon_material_tint', 0.3, 'p')
        cartoon = draw_params('p', 'cartoon')
        sticks = draw_params('p', 'stick')
        self.assertEqual(sticks, cartoon)
        got = response(sticks)
        self.assertEqual(got, response(cartoon))
        self.assertAlmostEqual(got['tint'], 0.3 * TINT_GAIN, delta=TOL)


class TestCustomKnobs(MaterialCase):

    def knob(self, name, **knobs):
        cmd.set('surface_material', name, 'p')
        for key, value in knobs.items():
            cmd.set('surface_material_%s' % key, value, 'p')
        params = draw_params('p', 'surface')
        return params, response(params)

    def testMetallicFullTint(self):
        params, got = self.knob('metallic', tint=1.0)
        reflect = params[2]
        self.assertEqual(got['tint'], 1.0)
        self.assertAlmostEqual(got['diffuse'], 1.0 - reflect, delta=TOL)

    def testRoughnessMovesTheExponent(self):
        last = None
        for rough in (0.1, 0.2, 0.4, 0.7):
            params, got = self.knob('metallic', rough=rough)
            self.assertResponse(got, oracle('metallic', params), rough)
            if last is not None:
                self.assertLess(got['exponent'], last)
            last = got['exponent']

    def testFullRoughnessIsExponentOne(self):
        """Never 0 (the scene's) and never infinite."""
        for rough in (0.99, 1.0):
            params, got = self.knob('metallic', rough=rough)
            self.assertEqual(got['exponent'], 1.0, rough)
            self.assertAlmostEqual(got['highlight'],
                                   params[2] * 3.0 / (2.0 * math.pi),
                                   delta=TOL, msg=rough)
            self.assertAlmostEqual(got['sharpness'], 1.0 / SHININESS,
                                   delta=TOL, msg=rough)

    def testSmoothFloorsAtATenth(self):
        for rough in (0.0, 0.05):
            params, got = self.knob('plastic', rough=rough)
            self.assertAlmostEqual(got['exponent'], 198.0, delta=1e-2, msg=rough)
            self.assertAlmostEqual(got['highlight'],
                                   params[2] * 200.0 / (2.0 * math.pi),
                                   delta=1e-3, msg=rough)

    def testRubberHighlightKnob(self):
        _p, base = self.knob('rubber')
        _p, got = self.knob('rubber', knob3=0.5)
        self.assertAlmostEqual(got['highlight'], 1.0, delta=TOL)
        self.assertGreater(got['highlight'], base['highlight'])
        _p, got = self.knob('rubber', knob3=0.0)
        self.assertEqual(got['highlight'], 0.0)
        # its sheen (knob4) is not part of the studio response
        _p, got = self.knob('rubber', knob3=0.17, knob4=0.0)
        self.assertResponse(got, base, 'sheen')

    def testJellyKnobs(self):
        _p, got = self.knob('jelly', knob3=2.0)
        self.assertAlmostEqual(got['highlight'], 4.0, delta=TOL)
        _p, got = self.knob('jelly', knob2=0.8)
        self.assertAlmostEqual(got['diffuse'], JELLY_GLOW_GAIN * 0.8, delta=TOL)
        _p, got = self.knob('jelly', knob2=1.5)        # its shader saturates
        self.assertAlmostEqual(got['diffuse'], JELLY_GLOW_GAIN, delta=TOL)
        _p, got = self.knob('jelly', knob2=-0.4)
        self.assertEqual(got['diffuse'], 0.0)

    def testNegativeHighlightKnobIsZero(self):
        for name in ('rubber', 'jelly'):
            _p, got = self.knob(name, knob3=-1.0)
            self.assertEqual(got['highlight'], 0.0, name)
            self.assertSane(got, name)

    def testOutOfRangeTripleIsClamped(self):
        """As RendererMetal::setRepMaterial clamps reflect, tint and rough."""
        _p, got = self.knob('metallic', reflect=1.7, tint=-0.5, rough=1.7)
        self.assertResponse(got, {'diffuse': 1.0,
                                  'highlight': 3.0 / (2.0 * math.pi),
                                  'exponent': 1.0, 'tint': 0.0, 'wrap': 0.0})
        _p, got = self.knob('metallic', reflect=-0.5, tint=1.7, rough=-0.5)
        self.assertResponse(got, {'diffuse': 1.0, 'highlight': 0.0,
                                  'exponent': 198.0, 'tint': 1.0, 'wrap': 0.0})
        _p, got = self.knob('frosted_glass', rough=1.7)
        self.assertResponse(got, oracle('glass', (0, 0, 0, 0, 1.0, (0,) * 6)))
        _p, got = self.knob('frosted_glass', rough=-0.5)
        self.assertResponse(got, oracle('glass', (0, 0, 0, 0, 0.0, (0,) * 6)))

    def testGlassReflectionKnobLeavesTheResponse(self):
        """Reflection (knob1) is applied where the glints are added."""
        for name in ('glass', 'frosted_glass'):
            _p, base = self.knob(name)
            _p, got = self.knob(name, knob1=0.0)
            self.assertEqual(got, base, name)
            cmd.unset('surface_material_knob1', 'p')

    def testFrostWidensAndDims(self):
        _p, glass = self.knob('glass')
        _p, frosted = self.knob('frosted_glass')
        self.assertLess(frosted['exponent'], glass['exponent'])
        self.assertLess(frosted['highlight'], glass['highlight'])

    def testThePureEntryClampsTheRawTuple(self):
        names = material_names()
        metallic, jelly = names['metallic'], names['jelly']
        refl = 2   # cMaterialFamily_reflective
        got = response((refl, metallic, 1.7, -0.5, 1.7, (0.0,) * 6))
        self.assertResponse(got, {'diffuse': 1.0,
                                  'highlight': 3.0 / (2.0 * math.pi),
                                  'exponent': 1.0, 'tint': 0.0, 'wrap': 0.0})
        got = response((3, jelly, 0.0, 0.0, 0.0, (2.2, 7.0, -1.0, 1.0, 0.0, 0.0)))
        self.assertAlmostEqual(got['diffuse'], JELLY_GLOW_GAIN, delta=TOL)
        self.assertEqual(got['highlight'], 0.0)
        nan = float('nan')
        got = response((refl, metallic, nan, nan, nan, (0.0,) * 6))
        self.assertSane(got, 'nan')

    def testUnknownCasesAreNeutral(self):
        names = material_names()
        metallic, matte = names['metallic'], names['matte']
        for params, label in (
                ((0, metallic, 0.6, 0.35, 0.25, (0.0,) * 6), 'default family'),
                ((9, metallic, 0.6, 0.35, 0.25, (0.0,) * 6), 'unknown family'),
                ((-1, metallic, 0.6, 0.35, 0.25, (0.0,) * 6), 'negative family'),
                ((2, 42, 0.6, 0.35, 0.25, (0.0,) * 6), 'unknown mode'),
                ((2, matte, 0.6, 0.35, 0.25, (0.0,) * 6), 'mode of another family'),
                ((1, metallic, 0.6, 0.35, 0.25, (0.0,) * 6), 'family mismatch')):
            self.assertNeutral(response(params), label)

    def testBadArgumentsRaise(self):
        for args in (('x',), ((2, 3, 0.6, 0.35, 0.25),), ((2, 3, 0.6, 0.35, 0.25,
                                                           (0.0,) * 5),)):
            with self.assertRaises(Exception):
                _cmd.material_light_response(cmd._COb, *(args + (SHININESS,)))


class TestAlignWithRay(MaterialCase):
    """Qualitatively the CPU ray mapping's highlight shaping (#499); the
    strengths differ by design and are recorded in the PR, not asserted."""

    def both(self, name):
        self.use(name, 'surface')
        _w, _id, spec, diffuse, spec_tint = _cmd.get_material_ray_params(
            cmd._COb, 'p', REP_INDEX['surface'])
        return (spec, diffuse, spec_tint), response(draw_params('p', 'surface'))

    def testMatteHasNoHighlightInEither(self):
        (spec, _d, _t), got = self.both('matte')
        self.assertEqual(spec, 0.0)
        self.assertEqual(got['highlight'], 0.0)

    def testPlasticIsWhiteWithFullDiffuse(self):
        (spec, diffuse, tint), got = self.both('plastic')
        self.assertEqual((diffuse, tint), (1.0, 0.0))
        self.assertGreater(spec, 1.0)
        self.assertEqual((got['diffuse'], got['tint']), (1.0, 0.0))
        self.assertGreater(got['highlight'], 1.0)

    def testMetallicIsDimmerAndTinted(self):
        (_s, diffuse, tint), got = self.both('metallic')
        self.assertLess(diffuse, 1.0)
        self.assertLess(got['diffuse'], 1.0)
        self.assertGreater(tint, 0.0)
        # tint rule B: the table metallic's studio tint IS the CPU's
        self.assertAlmostEqual(got['tint'], tint, delta=1e-6)
        self.assertAlmostEqual(tint, CPU_METALLIC_SPEC_TINT, delta=1e-6)
        self.assertAlmostEqual(draw_params('p', 'surface')[3],
                               METALLIC_TABLE_TINT, delta=1e-6)

    def testClayIsTheKnownDivergence(self):
        """The CPU keeps default's highlight on clay; its Metal shader and its
        studio response have none (proposed follow-up)."""
        (spec, _d, _t), got = self.both('clay')
        self.assertEqual(spec, 1.0)
        self.assertEqual(got['highlight'], 0.0)


class TestHighlightRef(MaterialCase):
    """The reference behind every p-derived strength: a light added without a
    highlight has 0.5, so glass's 2.4 is its key glint's 1.2 over 0.5."""

    def testANewLightsHighlight(self):
        cmd.show('cartoon')
        cmd.set_lights({'enabled': True, 'lights': [{'name': 'key'}]})
        self.assertEqual(cmd.get_lights()['lights'][0]['highlight'],
                         HIGHLIGHT_REF)
        cmd.lights('add', 'fill')
        self.assertEqual(cmd.get_lights()['lights'][1]['highlight'],
                         HIGHLIGHT_REF)

    def testStrengthsAreOverTheReference(self):
        self.use('glass', 'surface')
        got = response(draw_params('p', 'surface'))
        self.assertAlmostEqual(got['highlight'] * HIGHLIGHT_REF,
                               GLASS_KEY_GLINT, delta=TOL)
        self.use('rubber', 'surface')
        params = draw_params('p', 'surface')
        self.assertAlmostEqual(response(params)['highlight'] * HIGHLIGHT_REF,
                               params[5][2], delta=TOL)


def material_settings():
    return [name for name in setting.get_name_list()
            if name.endswith('_material')]


class TestNothingWritten(MaterialCase):

    def snapshot(self):
        session = cmd.get_session()
        colors = []
        cmd.iterate('all', 'colors.append(color)', space={'colors': colors})
        return {
            'settings': session['settings'],
            'unique_settings': session.get('unique_settings'),
            'colors': colors,
            'materials': [cmd.get(name) for name in material_settings()],
            'lights': cmd.get_lights(),
        }

    def testReadingResponsesWritesNothing(self):
        cmd.show('cartoon')
        cmd.set('cartoon_material', 'metallic', 'p')
        cmd.set('surface_material', 'jelly', 'p')
        cmd.set('surface_material_knob3', 2.0, 'p')
        cmd.set_lights({'enabled': True, 'classic': 0.3,
                        'lights': [{'name': 'key'}]})
        # The first get_session() writes pse_binary_dump back: take it first.
        self.snapshot()
        before = self.snapshot()
        for rep in REPS:
            params = draw_params('p', rep)
            for shin in (0.0, SHININESS, float('nan')):
                response(params, shin)
            self.assertEqual(self.snapshot(), before, rep)
        lighting._light_frame()
        self.assertEqual(self.snapshot(), before)


class TestClassicScale(MaterialCase):
    """get_light_frame's 'classic_scale': the factor decision 15 scales
    PyMOL's direct, reflect and specular by, which the material shaders' own
    key-light terms follow (#615)."""

    def setUp(self):
        super().setUp()
        cmd.show('cartoon')

    def frame(self):
        return lighting._light_frame()

    def rig(self, **extra):
        rig = {'enabled': True, 'lights': [{'name': 'key'}, {'name': 'fill'}]}
        rig.update(extra)
        cmd.set_lights(rig)

    def testOneWithNoRigOrARigThatIsOff(self):
        self.assertIsNone(cmd.get_lights())
        self.assertEqual(self.frame()['classic_scale'], 1.0)
        self.rig(enabled=False, classic=0.3)
        self.assertIs(self.frame()['rig_on'], False)
        self.assertEqual(self.frame()['classic_scale'], 1.0)
        cmd.lights('on')
        self.assertEqual(self.frame()['classic_scale'], f32(0.3))
        cmd.lights('off')
        self.assertEqual(self.frame()['classic_scale'], 1.0)

    def testTheRigsClassicWhileOn(self):
        self.rig()
        self.assertEqual(cmd.get_lights()['classic'], 0.0)
        self.assertEqual(self.frame()['classic_scale'], 0.0)
        for classic in (0.3, 1.0):
            self.rig(classic=classic)
            self.assertEqual(self.frame()['classic_scale'], f32(classic))
        lighting._light_set(-1, 'classic', 0.5)
        self.assertEqual(self.frame()['classic_scale'], 0.5)

    def testTheLightsCommandsClassic(self):
        cmd.lights('softbox', classic=0.3)
        self.assertEqual(self.frame()['classic_scale'], f32(0.3))
        cmd.lights(classic=0.6)
        self.assertEqual(self.frame()['classic_scale'], f32(0.6))
        cmd.lights('softbox')
        self.assertEqual(self.frame()['classic_scale'], 0.0)

    def testStillTheClassicWithEveryLightDark(self):
        """Decision 15: a rig whose lights are all at 0 is on."""
        self.rig(classic=0.3, lights=[{'name': 'key', 'intensity': 0.0},
                                      {'name': 'fill', 'intensity': 0.0}])
        frame = self.frame()
        self.assertIs(frame['rig_on'], True)
        self.assertEqual(frame['classic_scale'], f32(0.3))

    def testTheTermsAreTheSettingsTimesTheScale(self):
        cmd.set('direct', 0.6)
        cmd.set('reflect', 0.2)
        base = self.frame()
        for classic in (0.0, 0.3, 0.75, 1.0):
            self.rig(classic=classic)
            frame = self.frame()
            scale = frame['classic_scale']
            self.assertEqual(scale, f32(classic))
            for key in ('direct', 'reflect', 'specular'):
                self.assertEqual(frame[key], f32(f32(base[key]) * scale),
                                 '%s at classic %r' % (key, classic))
