"""The app bridge's light-rig functions run no Python (#611, spec §4.4).

PyMOLBridge_LightsJSON / LightSet / LightSetVector / LightsEyeSpace
(swiftui/PyMOLViewer/Bridge/PyMOLBridge.mm) are what a light drag calls once
per tick, so they must be plain C++: #610's "no Python call per drag tick".
CI builds no app, so this checks the source:

- each bridge light function calls only the scene's rig functions
  (layer1/SceneLights.h) and a few std helpers, and names nothing from the
  Python C-API or PyMOL's GIL wrappers;
- the rig core those calls reach (layer1/LightRig.*, layer1/SceneLights.*)
  uses no Python either (the conversions live in layer1/LightRigPy.*);
- the Swift wrapper (Shared/LightRigBridge.swift) calls only those bridge
  functions, never runPython;
- the bridging header declares the functions with the types the .mm defines
  (the .mm does not include the bridging header, and C linkage would let a
  mismatch link);
- the status codes and the light cap agree in C++ (LightRig.h), the C header
  (PyMOLBridgeLights.h) and Swift.

The live behaviour is LightRigBridgeTests (swiftui/PyMOLViewerTests, run by
the UnitTests_macOS scheme); the maths behind it is lighting_eye.py and
lighting_rig.py, through _cmd.

Source-reading, so skipped (not passed) outside a repo checkout.

    pymol -ckqy testing/testing.py --run testing/tests/raymol/lighting_bridge.py
"""
import os
import re

from pymol import testing

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), os.pardir,
                                     os.pardir, os.pardir))
BRIDGE = os.path.join('swiftui', 'PyMOLViewer', 'Bridge')
MM = os.path.join(BRIDGE, 'PyMOLBridge.mm')
HEADER = os.path.join(BRIDGE, 'PyMOLBridge.h')
LIGHTS_H = os.path.join(BRIDGE, 'PyMOLBridgeLights.h')
SWIFT = os.path.join('swiftui', 'PyMOLViewer', 'Shared', 'LightRigBridge.swift')
RIG_CORE = [os.path.join('layer1', name) for name in
            ('LightRig.h', 'LightRig.cpp', 'SceneLights.h', 'SceneLights.cpp')]

FUNCTIONS = {'PyMOLBridge_LightsJSON', 'PyMOLBridge_LightSet',
             'PyMOLBridge_LightSetVector', 'PyMOLBridge_LightsEyeSpace'}

# What a bridge light function may call: the scene's rig functions (plain
# C++, layer1/SceneLights.cpp), the instance lookup, and std helpers.
ALLOWED_CALLS = {
    'INST', 'PyMOL_GetGlobals',
    'SceneLightsJSON', 'SceneLightSet', 'SceneLightsResolve',
    'strdup', 'c_str', 'size', 'min', 'max',
}
KEYWORDS = {'if', 'for', 'while', 'switch', 'return', 'sizeof'}

# The Python C-API (Py*, but not PyMOL*), PyMOL's GIL / Python wrappers
# (layer1/P.h: PAutoBlock, PBlock, PRun*, PLock*, PXDecRef, ...), the
# PyMOL_* embedding API beyond the instance lookup (PyMOL_Cmd* runs Python),
# and the Swift-side Python entry points.
PYTHON = re.compile(
    r'\bPy(?!MOL)\w*'
    r'|\bP(?:AutoBlock|AutoUnblock|Block|Unblock|Run\w*|Lock\w*|Unlock\w*'
    r'|XDecRef|XIncRef|Conv\w*|Convert\w*|Get\w*Lock\w*)\b'
    r'|\bPyMOL_(?!GetGlobals\b)\w+'
    r'|\brunPython\w*|\bRunPython\w*')

RIG_CORE_PYTHON = re.compile(
    r'\bPyObject\b|\bPy_\w+|\bPyGILState\w*|\bPRun\w*|\bPAutoBlock\b'
    r'|\bPBlock\b|os_python\.h|#include\s+"P\.h"|LightRigPy\.h')


def strip_comments(text):
    """C/C++/Swift comments removed, so a comment can neither satisfy nor
    trip a check (and braces inside comments do not count)."""
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    return re.sub(r'//[^\n]*', '', text)


def definitions(source):
    """{name: (return type, [param types], body)} for every PyMOLBridge_Light*
    function defined in `source` (comments stripped)."""
    source = strip_comments(source)
    found = {}
    for match in re.finditer(
            r'^([A-Za-z_][\w \t\*]*?)\b(PyMOLBridge_Light\w*)\s*\(([^)]*)\)\s*\{',
            source, re.M):
        ret, name, params = match.groups()
        depth = 0
        for i in range(match.end() - 1, len(source)):
            if source[i] == '{':
                depth += 1
            elif source[i] == '}':
                depth -= 1
                if depth == 0:
                    body = source[match.end():i]
                    break
        else:
            raise AssertionError('unbalanced braces after %s' % name)
        found[name] = (normalize_type(ret), param_types(params), body)
    return found


def declarations(source):
    """{name: (return type, [param types])} for every PyMOLBridge_Light*
    prototype in `source`."""
    source = strip_comments(source)
    return {name: (normalize_type(ret), param_types(params))
            for ret, name, params in re.findall(
                r'^([A-Za-z_][\w \t\*]*?)\b(PyMOLBridge_Light\w*)\s*\(([^)]*)\)\s*;',
                source, re.M)}


def normalize_type(text):
    text = re.sub(r'\s+', ' ', text.strip())
    return re.sub(r'\s*\*\s*', '*', text)


def param_types(params):
    """The types of a C parameter list, without the parameter names."""
    types = []
    for param in params.split(','):
        param = normalize_type(param)
        match = re.match(r'^(.*?[\w\*])\s*\b([A-Za-z_]\w*)$', param)
        if not match or match.group(1).endswith(('const', 'struct')):
            raise AssertionError('unnamed or unparsable parameter %r' % param)
        types.append(normalize_type(match.group(1)))
    return types


def calls(body):
    return set(re.findall(r'\b([A-Za-z_]\w*)\s*\(', body)) - KEYWORDS


def camel_to_upper_snake(name):
    """'UnknownField' -> 'UNKNOWN_FIELD'."""
    return re.sub(r'(?<!^)([A-Z])', r'_\1', name).upper()


def upper_snake_to_camel(name):
    """'UNKNOWN_FIELD' -> 'unknownField'."""
    head, *rest = name.lower().split('_')
    return head + ''.join(part.capitalize() for part in rest)


class TestLightingBridge(testing.PyMOLTestCase):

    def read(self, rel):
        path = os.path.join(ROOT, rel)
        if not os.path.isfile(path):
            # Skipped, not passed: a source-reading test that cannot find its
            # source has checked nothing. Only reached outside a checkout.
            self.skipTest('%s not present; not a repo checkout' % rel)
        with open(path, encoding='utf-8') as handle:
            return handle.read()

    def testBridgeLightFunctionsCallNoPython(self):
        defs = definitions(self.read(MM))
        self.assertEqual(set(defs), FUNCTIONS)
        for name, (_, _, body) in sorted(defs.items()):
            self.assertIsNone(PYTHON.search(body),
                              '%s names %r' % (name, (PYTHON.search(body) or [''])[0]))
            self.assertLessEqual(calls(body), ALLOWED_CALLS,
                                 '%s calls %s' % (name, sorted(calls(body) - ALLOWED_CALLS)))
        # The rig functions the bridge calls live in SceneLights.cpp, which
        # testRigCoreHasNoPython reads.
        scene_lights = strip_comments(self.read(os.path.join('layer1', 'SceneLights.cpp')))
        for callee in ('SceneLightsJSON', 'SceneLightSet', 'SceneLightsResolve'):
            self.assertRegex(scene_lights, r'\n[^\n;]*\b%s\s*\([^;{]*\)\s*\{' % callee)

    def testRigCoreHasNoPython(self):
        for rel in RIG_CORE:
            text = strip_comments(self.read(rel))
            found = RIG_CORE_PYTHON.search(text)
            self.assertIsNone(found, '%s uses %r' % (rel, found and found.group(0)))

    def testSwiftWrapperCallsOnlyTheLightFunctions(self):
        text = strip_comments(self.read(SWIFT))
        bridge = set(re.findall(r'\b(PyMOLBridge_\w+)\s*\(', text))
        self.assertEqual(bridge, FUNCTIONS | {'PyMOLBridge_FreeFeedback'})
        self.assertNotRegex(text, r'\brunPython|\bRunPython')
        # Each write asks the viewport for a frame when the rig changed.
        self.assertEqual(text.count('requestViewportRedraw()'), 2)

    def testDeclarationsMatchDefinitions(self):
        decls = declarations(self.read(HEADER))
        defs = definitions(self.read(MM))
        self.assertEqual(set(decls), FUNCTIONS)
        for name in sorted(FUNCTIONS):
            self.assertEqual(decls[name], defs[name][:2], name)
        self.assertEqual(decls['PyMOLBridge_LightSet'],
                         ('int', ['PyMOLHandle', 'int', 'const char*', 'double']))
        self.assertEqual(decls['PyMOLBridge_LightsEyeSpace'],
                         ('int', ['PyMOLHandle', 'PyMOLLightRigEye*',
                                  'PyMOLLightEye*', 'int']))
        for rel in (HEADER, MM):
            self.assertRegex(strip_comments(self.read(rel)),
                             r'#include\s+"PyMOLBridgeLights\.h"', rel)
        self.assertRegex(strip_comments(self.read(MM)), r'#include\s+"SceneLights\.h"')
        # Types and constants only: the functions are declared in PyMOLBridge.h.
        self.assertNotIn('PyMOLBridge_', strip_comments(self.read(LIGHTS_H)))

    def testStatusCodesMatch(self):
        rig_h = strip_comments(self.read(os.path.join('layer1', 'LightRig.h')))
        block = re.search(r'enum class LightSetStatus\s*\{(.*?)\}', rig_h, re.S)
        self.assertIsNotNone(block)
        cpp = {camel_to_upper_snake(name): int(value) for name, value in
               re.findall(r'(\w+)\s*=\s*(-?\d+)', block.group(1))}
        self.assertEqual(sorted(cpp), ['BAD_INDEX', 'BAD_VALUE', 'NO_RIG', 'OK',
                                       'REFUSED', 'UNKNOWN_FIELD'])

        lights_h = strip_comments(self.read(LIGHTS_H))
        c = {name: int(value) for name, value in
             re.findall(r'\bPYMOL_LIGHT_SET_(\w+)\s*=\s*(-?\d+)', lights_h)}
        self.assertEqual(c, cpp)

        cap = re.search(r'#define\s+PYMOL_LIGHTS_MAX\s+(\d+)', lights_h)
        rig_cap = re.search(r'kLightRigMaxLights\s*=\s*(\d+)', rig_h)
        self.assertEqual((int(cap.group(1)), int(rig_cap.group(1))), (6, 6))

        # Swift maps every code to the case of the same name.
        swift = strip_comments(self.read(SWIFT))
        mapped = dict(re.findall(
            r'case\s+PYMOL_LIGHT_SET_(\w+)\s*:\s*self\s*=\s*\.(\w+)', swift))
        self.assertEqual(mapped, {name: upper_snake_to_camel(name) for name in c})
