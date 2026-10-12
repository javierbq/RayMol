"""Finite bit tests for the Metal shaders (#739), read from source.

The Metal shader libraries compile with Metal's default fast math
(newLibraryWithSource with default MTLCompileOptions), which may assume no NaN
or inf. Under that assumption a compiler is allowed to fold isfinite(x) /
all(isfinite(v)) to true, which would make the NaN guards in the light rig and
air shaders no-ops. Every such guard is written as an integer bit test on the
float's exponent bits (as_type<uint>), through two helpers, light_finite(float)
and light_finite3(float3).

Tests:
* testNoRawFiniteTests: no raw isfinite, isnan, or isinf call in any shader
  literal;
* testHelpers: light_finite and light_finite3 defined in kMaterialSrc and
  kRTSrc with the squashed signatures and bodies, verbatim in kPostSrc
  (#732, its HDR AO calls the tone helpers), and nowhere else;
* testGuardSites: every NaN guard site in kAirSrc, kMaterialSrc, kRTSrc and
  kPostSrc (#732) uses the helper;
* testOnlyTheGuardsChanged: without_finite_739 removes the helpers and
  replaces the helper calls with the old isfinite calls, restoring master's
  pre-#739 digests exactly;
* testCmdRegistersThePoisonHook: Cmd.cpp registers set_metal_air_debug_poison
  and encodeAirPass reads _airDebugPoison to inject infinity into haze density;
* testRuntimeHeadlessHasNoPoison: runtime check that headless pymol returns
  None for the test-only hook.

Pure source parsing (skipped, not passed, outside a repo checkout; in a
checkout a missing source file fails).

    pymol -ckqy testing/testing.py --run testing/tests/raymol/lighting_finite_msl.py
"""
import importlib.util
import os
import re

from pymol import testing

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, os.pardir, os.pardir, os.pardir))
METAL_MM = os.path.join(ROOT, 'layerGraphics', 'metal', 'RendererMetal.mm')
CMD_CPP = os.path.join(ROOT, 'layer4', 'Cmd.cpp')


def _load(name, filename):
    """A sibling test module's helpers, loaded by path under a private name
    so its test cases are not collected a second time."""
    spec = importlib.util.spec_from_file_location(
        name, os.path.join(HERE, filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


_msl = _load('_lighting_finite_msl_parsers', 'lighting_msl.py')
_air = _load('_lighting_finite_msl_air', 'lighting_air_msl.py')
shader_literals = _msl.shader_literals
strip_comments = _msl.strip_comments
msl_functions = _msl.msl_functions
squash = _msl.squash
cpp_function = _msl.cpp_function
digest = _air.digest

FINITE_HELPER_DEF = re.compile(
    r'(?:__attribute__\(\(unused\)\)\s*)?static\s+bool\s+light_finite3?\s*\([^)]*\)\s*\{[^{}]*\}'
)
FINITE3_CALL = re.compile(r'\blight_finite3\(([^()]*)\)')
FINITE_CALL = re.compile(r'\blight_finite\(')


def without_finite_739(code):
    """`code` (comment-stripped shader source) with #739's helpers removed and
    guard calls replaced with isfinite. Returns (text, counts)."""
    counts = {}
    text, counts['helpers'] = FINITE_HELPER_DEF.subn('', code)
    text, counts['finite3'] = FINITE3_CALL.subn(r'all(isfinite(\1))', text)
    text, counts['finite'] = FINITE_CALL.subn('isfinite(', text)
    return text, counts


# Master f1855ac28 (#739's base): sha256 of each literal, comments stripped
# and whitespace removed, first 16 hex digits (lighting_air_msl.py digest).
PRE_739 = {
    'kMaterialSrc': 'f4eb7866dc2af793',
    'kAirSrc': '4d768488fee43dc5',  # #686: per-cell air
    'kRTSrc': 'aa8162e29ff5e6b2',  # #732: AO in scene units under an HDR rig
}
FINITE_COUNTS = {
    'kMaterialSrc': {'helpers': 2, 'finite3': 2, 'finite': 2},
    'kRTSrc': {'helpers': 2, 'finite3': 2, 'finite': 2},
    'kAirSrc': {'helpers': 0, 'finite3': 2, 'finite': 2},
}


class FiniteMSLCase(testing.PyMOLTestCase):

    def setUp(self):
        if not os.path.isfile(METAL_MM):
            self.skipTest('%s not present; not a repo checkout' % METAL_MM)
        if not os.path.isfile(CMD_CPP):
            self.fail('%s is missing from the checkout' % CMD_CPP)
        super().setUp()
        with open(METAL_MM, encoding='utf-8') as f:
            self.mm = f.read()
        with open(CMD_CPP, encoding='utf-8') as f:
            self.cmd_cpp = f.read()
        self.msl = shader_literals(self.mm)


class TestFiniteGuards(FiniteMSLCase):

    def testNoRawFiniteTests(self):
        """In EVERY shader literal (comments stripped), no match for
        \\bisfinite\\s*\\( or \\bisnan\\s*\\( or \\bisinf\\s*\\(."""
        raw_finite = re.compile(r'\b(?:isfinite|isnan|isinf)\s*\(')
        for name, literal in sorted(self.msl.items()):
            code = strip_comments(literal)
            matches = raw_finite.findall(code)
            self.assertEqual(matches, [], f'{name} contains raw finite check: {matches}')

    def testHelpers(self):
        """kMaterialSrc and kRTSrc each define light_finite and light_finite3
        exactly once (msl_functions), with the squashed bodies and signatures.
        No other literal defines them (kAirSrc included)."""
        want_bodies = {
            'light_finite': '{return(as_type<uint>(x)&0x7f800000u)!=0x7f800000u;}',
            'light_finite3': '{returnall((as_type<uint3>(c)&0x7f800000u)!=0x7f800000u);}',
        }
        want_sigs = {
            'light_finite': 'boollight_finite(floatx)',
            'light_finite3': 'boollight_finite3(float3c)',
        }

        for lib_name in ('kMaterialSrc', 'kRTSrc'):
            fns = msl_functions(self.msl[lib_name])
            for fn_name in ('light_finite', 'light_finite3'):
                self.assertIn(fn_name, fns, f'{lib_name} missing {fn_name}')
                sig, body = fns[fn_name]
                self.assertIn(want_sigs[fn_name], squash(sig), f'{lib_name} {fn_name} signature')
                self.assertEqual(squash(body), want_bodies[fn_name], f'{lib_name} {fn_name} body')

        # kRTSrc's and kPostSrc's (#732) copies equal kMaterialSrc's
        # (squashed sig and body)
        mat_fns = msl_functions(self.msl['kMaterialSrc'])
        for copy in ('kRTSrc', 'kPostSrc'):
            copy_fns = msl_functions(self.msl[copy])
            for fn_name in ('light_finite', 'light_finite3'):
                self.assertIn(fn_name, copy_fns, f'{copy} missing {fn_name}')
                self.assertEqual(squash(mat_fns[fn_name][0]), squash(copy_fns[fn_name][0]))
                self.assertEqual(squash(mat_fns[fn_name][1]), squash(copy_fns[fn_name][1]))

        # No other literal defines them (kAirSrc included)
        for name, literal in sorted(self.msl.items()):
            if name in ('kMaterialSrc', 'kRTSrc', 'kPostSrc'):
                continue
            fns = msl_functions(literal)
            self.assertNotIn('light_finite', fns, f'{name} defines light_finite')
            self.assertNotIn('light_finite3', fns, f'{name} defines light_finite3')

    def testGuardSites(self):
        """Each guard site in Context uses the helper."""
        air_fns = msl_functions(self.msl['kAirSrc'])
        post_air_term_body = squash(air_fns['post_air_term'][1])
        self.assertIn('||!light_finite(zHi-zLo))returnfloat4(0.0,0.0,0.0,zSurf);',
                      post_air_term_body)
        self.assertIn('if(!light_finite3(add))add=float3(0.0);', post_air_term_body)

        post_air_stop_body = squash(air_fns['post_air_stop'][1])
        self.assertIn('||!light_finite(zHi-zLo))returnzSurf;', post_air_stop_body)

        post_air_finish_body = squash(air_fns['post_air_finish'][1])
        self.assertIn('constfloat3add=light_finite3(a)?max(a,float3(0.0))*e:float3(0.0);',
                      post_air_finish_body)

        for lib_name in ('kMaterialSrc', 'kRTSrc', 'kPostSrc'):
            fns = msl_functions(self.msl[lib_name])
            scalar_body = squash(fns['light_tone_scalar'][1])
            self.assertTrue(scalar_body.startswith('{m=(light_finite(m)&&m>0.0)?m:0.0;'),
                            f'{lib_name} light_tone_scalar')
            inv_body = squash(fns['light_tone_scalar_inverse'][1])
            self.assertTrue(inv_body.startswith('{y=(light_finite(y)&&y>0.0)?y:0.0;'),
                            f'{lib_name} light_tone_scalar_inverse')
            tone_body = squash(fns['light_tone'][1])
            self.assertTrue(tone_body.startswith('{if(!light_finite3(c))returnfloat3(0.0);'),
                            f'{lib_name} light_tone')
            tone_inv_body = squash(fns['light_tone_inverse'][1])
            self.assertTrue(tone_inv_body.startswith('{if(!light_finite3(c))returnfloat3(0.0);'),
                            f'{lib_name} light_tone_inverse')

    def testOnlyTheGuardsChanged(self):
        for name in ('kMaterialSrc', 'kRTSrc', 'kAirSrc'):
            code = strip_comments(self.msl[name])
            text, counts = without_finite_739(code)
            self.assertEqual(counts, FINITE_COUNTS[name], f'{name} counts')
            self.assertEqual(digest(text), PRE_739[name], f'{name} digest')

    def testCmdRegistersThePoisonHook(self):
        self.assertIn('"set_metal_air_debug_poison", CmdSetMetalAirDebugPoison',
                      self.cmd_cpp)
        encode_air = cpp_function(self.mm, 'RendererMetal::encodeAirPass')
        self.assertIn('if (_airDebugPoison) air.medium[0] =', encode_air)
        # and that is the only place in RendererMetal.mm (outside setAirDebugPoison
        # itself and the header) that reads _airDebugPoison.
        code = strip_comments(self.mm)
        set_fn = cpp_function(self.mm, 'RendererMetal::setAirDebugPoison')
        code_without_set = code.replace(set_fn, '')
        matches = re.findall(r'\b_airDebugPoison\b', code_without_set)
        self.assertEqual(len(matches), 1,
                         f'_airDebugPoison read outside encodeAirPass: {matches}')

    def testRuntimeHeadlessHasNoPoison(self):
        from pymol import cmd
        if not hasattr(cmd._cmd, 'set_metal_air_debug_poison'):
            self.skipTest('set_metal_air_debug_poison not in _cmd yet (needs rebuilt core)')
        self.assertIsNone(cmd._cmd.set_metal_air_debug_poison(cmd._COb, 0))
