"""The light rig in the Metal shaders and pipelines (#613), read from source.

The rig's shading is MSL compiled at run time (layerGraphics/metal/
RendererMetal.mm), and CI has no GPU: a shader that fails to specialise is
an NSLog and a representation drawn without its lights, and a rig statement
that escapes its function constant changes every default render. These
checks pin, from the source, what L1 (byte-identical default) and L3 (iOS
shader compile) prove on a Mac:

* the light block lives at the end of kMaterialSrc, the shared material
  block every lit library is built with, and nowhere else;
* its helpers read no function constant, so any library can call them;
* every lit colour fragment of a rig library takes the rig at buffer(9)
  under kLightRig, and every other fragment never sees it;
* every rig statement sits under `if (kLightRig)`, so the classic
  specialisation (kLightRig false) removes all of it, and what is left is
  today's code;
* the impostors' rig helpers are copies of the classic ones plus the light,
  and glass, jelly and the other families take the rig as on the VBO path;
* the specialisation always sets the constant, and the indices agree between
  C++ and MSL;
* the MSL LightRigU mirrors layer1/LightRigBlock.h, #616's shadow maps
  (LightRigShadow) appended after #613's 400 bytes;
* the rig is bound only while it is on, and rig pipelines (VBO, sphere,
  cylinder, bezier tube) are chosen only then, with a classic fallback;
* the classic bezier tube library is untouched; the tube's rig library is
  kMaterialSrc + kBezierTubeSrc + kBezierTubeRigSrc, its functions are
  copies of the classic ones plus the light (drift guards), and its pipeline
  is the classic descriptor with those functions;
* SceneRenderMetal reads the rig once per frame, before the shadow pre-pass;
* the shading terms the ticket names are pinned where they are computed
  (light_terms_view): the cone's soft edge, the falloff's direction, the
  coloured highlight and its per-light strength, and the orthographic view;
* the ray tracer's composite takes the rig on its reflection hits under its
  own constant (kRTLightRig), from verbatim copies of the rig's structs and
  helpers (drift guards), with a classic fallback, bound only while on.

Pure source parsing (skipped, not passed, outside a repo checkout; in a
checkout a missing source file fails).

    pymol -ckqy testing/testing.py --run testing/tests/raymol/lighting_msl.py
"""
import importlib.util
import os
import re

from pymol import testing

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, os.pardir, os.pardir, os.pardir))
METAL_MM = os.path.join(ROOT, 'layerGraphics', 'metal', 'RendererMetal.mm')
SCENE_RENDER = os.path.join(ROOT, 'layer1', 'SceneRender.cpp')
BLOCK_H = os.path.join(ROOT, 'layer1', 'LightRigBlock.h')
SHADING_H = os.path.join(ROOT, 'layer1', 'LightShading.h')


def _load_shader_sources():
    """metal_shader_sources.py's parsers (shader_literals, _function_body,
    _strip_comments), loaded by path under a private name so its own test
    case is not collected a second time from this module."""
    spec = importlib.util.spec_from_file_location(
        '_lighting_msl_shader_sources',
        os.path.join(HERE, 'metal_shader_sources.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


_sources = _load_shader_sources()
shader_literals = _sources.shader_literals
strip_comments = _sources._strip_comments

# Every helper of the light block, in kMaterialSrc.
HELPERS = ('light_response_neutral', 'light_response', 'light_visibility',
           'light_terms_view', 'light_terms', 'light_finish', 'light_outline',
           'light_apply', 'light_glass_glints')
# The ray tracer's copies (kRTSrc cannot take kMaterialSrc): the structs, and
# the helpers its reflection hits need. No light_outline (overlays never
# enter ray tracing), no light_apply, no light_response (needs MaterialU).
RT_COPIES = ('light_response_neutral', 'light_visibility', 'light_terms_view',
             'mat_soft_knee', 'light_finish')
RT_RIG_ARGUMENT = re.compile(
    r'constant\s+LightRigU\s*&\s*rig\s*\[\[\s*buffer\(13\)\s*,\s*'
    r'function_constant\(kRTLightRig\)\s*\]\]')
RT_RIG_GUARD = re.compile(r'if\s*\(\s*kRTLightRig\s*\)')
STRUCTS = ('LightRigLight', 'LightRigShadow', 'LightRigU', 'LightResponse',
           'LightTerms')

# Libraries whose lit fragments take the rig (the bezier tube has its own
# rig library and is checked apart).
RIG_LIBRARIES = ('kVBOSrc', 'kSphereImpostorSrc', 'kCylinderImpostorSrc')
LIT_LIBRARIES = ('kVBOSrc', 'kSphereImpostorSrc', 'kCylinderImpostorSrc')
# The fragments of RIG_LIBRARIES that must take the rig, so the generic
# detection below cannot pass by finding nothing.
EXPECTED_RIG_FRAGMENTS = {
    'kVBOSrc': {'vbo_fragment', 'vbo_fragment_oit'},
    'kSphereImpostorSrc': {'sphere_impostor_fragment',
                           'sphere_impostor_fragment_oit'},
    'kCylinderImpostorSrc': {'cyl_impostor_fragment',
                             'cyl_impostor_fragment_oit'},
}
# The impostors' rig helpers: (library, rig copy, classic helper, the base
# colour light_apply takes).
IMPOSTOR_RIG_HELPERS = (
    ('kSphereImpostorSrc', 'sphere_shade_material_rig', 'sphere_shade_material',
     'in.color.rgb'),
    ('kCylinderImpostorSrc', 'cyl_shade_material_rig', 'cyl_shade_material',
     'base'),
)
# A fragment shades colour with the classic lights when it calls one of these.
LIT_MARKERS = ('vbo_material_shade', 'sphere_shade_material',
               'cyl_shade_material', 'mat_impostor_composite',
               'mat_glass_shade')
RIG_ARGUMENT = re.compile(
    r'constant\s+LightRigU\s*&\s*rig\s*\[\[\s*buffer\(9\)\s*,\s*'
    r'function_constant\(kLightRig\)\s*\]\]')
RIG_GUARD = re.compile(r'if\s*\(\s*kLightRig\s*\)')
# What a rig statement can mention; none of it may survive outside the guard.
RIG_TOKENS = re.compile(r'\brig\b|\blight_\w+|\bLightTerms\b|\bLightRigU\b|'
                        r'\bkLightRig\b|\bLightResponse\b|\w+_rig\b')
# Functions of RendererMetal.mm allowed to bind the rig: every VBO, sphere
# and cylinder draw through bindRepMaterial, and the bezier tube, which never
# calls it.
BIND_CALLERS = {'bindRepMaterial', 'drawBezierTubes'}
# The tube's rig argument: plain, because its library is never specialised.
TUBE_RIG_ARGUMENT = re.compile(
    r'constant\s+LightRigU\s*&\s*rig\s*\[\[\s*buffer\(9\)\s*\]\]')


def read(path):
    with open(path, encoding='utf-8') as handle:
        return handle.read()


def _match(text, start, opening, closing):
    depth = 0
    for i in range(start, len(text)):
        if text[i] == opening:
            depth += 1
        elif text[i] == closing:
            depth -= 1
            if depth == 0:
                return i
    raise AssertionError('unbalanced %s%s' % (opening, closing))


def match_brace(text, open_brace):
    """Index of the brace closing the one at `open_brace`."""
    return _match(text, open_brace, '{', '}')


def match_paren(text, open_paren):
    """Index of the parenthesis closing the one at `open_paren`."""
    return _match(text, open_paren, '(', ')')


def msl_functions(literal):
    """{name: (signature, body)} for every function defined in a literal
    (comments stripped). The signature runs from the start of the line to the
    opening brace; the body includes both braces."""
    code = strip_comments(literal)
    found = {}
    for m in re.finditer(r'^[ \t]*(?:__attribute__\(\(\w+\)\)\s+)?'
                         r'(?:static\s+|fragment\s+|vertex\s+)?'
                         r'[\w:<>]+\s+(\w+)\s*\(', code, re.M):
        name = m.group(1)
        # the parameter list, then a brace (a prototype or a call ends in ;)
        close = match_paren(code, m.end() - 1) + 1
        nxt = re.match(r'\s*\{', code[close:])
        if not nxt:
            continue
        open_brace = close + nxt.end() - 1
        found[name] = (code[m.start():open_brace],
                       code[open_brace:match_brace(code, open_brace) + 1])
    return found


def fragments(literal):
    """{name: (signature, body)} of the `fragment` functions in a literal."""
    return {name: sig_body for name, sig_body in msl_functions(literal).items()
            if re.match(r'\s*fragment\s', sig_body[0])}


def is_lit(body):
    return any(re.search(r'\b%s\s*\(' % marker, body) for marker in LIT_MARKERS)


def remove_rig_statements(body, guard=RIG_GUARD):
    """`body` as the classic specialisation (kLightRig false) runs it: every
    `if (kLightRig) { ... }` block and every `if (kLightRig) statement;`
    removed, and for `if (kLightRig) A else B` only B kept. `guard` is the
    ray tracer's RT_RIG_GUARD for its composite."""
    while True:
        m = guard.search(body)
        if not m:
            return body
        i = m.end()
        while body[i].isspace():
            i += 1
        if body[i] == '{':
            end = match_brace(body, i) + 1
        else:
            depth = 0
            end = i
            while True:
                ch = body[end]
                if ch in '([':
                    depth += 1
                elif ch in ')]':
                    depth -= 1
                elif ch == ';' and depth == 0:
                    break
                end += 1
            end += 1
        # `if (kLightRig) A else B`: with the rig off only B runs
        alternative = re.match(r'\s*else\b', body[end:])
        if alternative:
            end += alternative.end()
        body = body[:m.start()] + body[end:]


def cpp_function(source, qualified_name):
    """The body of a C++ function DEFINITION (not a prototype or a call),
    braces included, with // comments stripped."""
    code = strip_comments(source)
    for m in re.finditer(r'(?<![\w:~])%s\s*\(' % re.escape(qualified_name),
                         code):
        close = match_paren(code, m.end() - 1) + 1
        nxt = re.match(r'\s*(?:const\s*)?(?:override\s*)?\{', code[close:])
        if nxt:
            open_brace = close + nxt.end() - 1
            return code[open_brace:match_brace(code, open_brace) + 1]
    raise AssertionError('no definition of %s' % qualified_name)


def depth_at(body, index):
    """Brace depth of `body` at `index` (1 = the function's top level)."""
    return body[:index].count('{') - body[:index].count('}')


def squash(text):
    """`text` with all whitespace removed, for comparing copied code."""
    return re.sub(r'\s+', '', text)


def statements_after(body, marker):
    """The text of `body` from the first occurrence of `marker`."""
    return body[body.index(marker):]


class LightMSLCase(testing.PyMOLTestCase):

    def setUp(self):
        # Skipped, not passed, outside a repo checkout: a source test with no
        # source checked nothing. A checkout is decided by RendererMetal.mm
        # alone; in one, every other source read here is REQUIRED, so a
        # renamed or removed file fails rather than skipping the suite.
        # Both happen BEFORE the base setUp: a skip or a failure raised in
        # setUp skips tearDown too, which would leave the base class's
        # feedback push and working directory behind.
        if not os.path.isfile(METAL_MM):
            self.skipTest('%s not present; not a repo checkout' % METAL_MM)
        for path in (SCENE_RENDER, BLOCK_H, SHADING_H):
            if not os.path.isfile(path):
                self.fail('%s is missing from the checkout' % path)
        super().setUp()
        self.mm = read(METAL_MM)
        self.msl = shader_literals(self.mm)


class TestLightBlock(LightMSLCase):

    def testLightBlockLivesInMaterialSrc(self):
        material = strip_comments(self.msl['kMaterialSrc'])
        constant = re.search(
            r'constant\s+bool\s+kLightRig\s*\[\[\s*function_constant\((\d+)\)'
            r'\s*\]\]\s*;', material)
        self.assertIsNotNone(constant, 'kMaterialSrc does not declare kLightRig')
        for struct in STRUCTS:
            self.assertRegex(material, r'\bstruct\s+%s\s*\{' % struct)
        functions = msl_functions(self.msl['kMaterialSrc'])
        for helper in HELPERS:
            self.assertIn(helper, functions, '%s missing from kMaterialSrc' % helper)
            # marked unused, as mat_glass_cover is: a library that skips a
            # helper gets no new -Wunused-function
            self.assertRegex(functions[helper][0],
                             r'^\s*__attribute__\(\(unused\)\)\s+static\s',
                             helper)
        # appended at the END: after MaterialU (light_response takes it) and
        # after every material helper, so it is one block, not interleaved
        block = constant.start()
        self.assertLess(material.index('struct MaterialU {'), block)
        last_mat = max(material.index(sig) for name, (sig, _) in functions.items()
                       if name.startswith('mat_'))
        self.assertLess(last_mat, block)
        for helper in HELPERS:
            self.assertGreater(material.index(functions[helper][0]), block,
                               helper)
        # ...and nowhere else, the tube's rig library included (it calls the
        # helpers; it must not carry its own)
        self.assertIn('kBezierTubeRigSrc', self.msl)
        # (kRTSrc carries copies, which TestRayTracedReflections pins as
        # verbatim)
        for name, literal in self.msl.items():
            if name in ('kMaterialSrc', 'kRTSrc'):
                continue
            code = strip_comments(literal)
            self.assertNotRegex(code, r'\bkLightRig\s*\[\[', name)
            for struct in STRUCTS:
                self.assertNotRegex(code, r'\bstruct\s+%s\b' % struct, name)
            for fn in msl_functions(literal):
                self.assertFalse(fn.startswith('light_'),
                                 '%s defines %s' % (name, fn))
        rt = [fn for fn in msl_functions(self.msl['kRTSrc'])
              if fn.startswith('light_')]
        self.assertEqual(sorted(rt), sorted(c for c in RT_COPIES
                                            if c.startswith('light_')))

    def testOnlyTheRigUsesItsIndices(self):
        """function_constant(1) and buffer(9) belong to the rig in every
        library built with kMaterialSrc."""
        for lib in ('kMaterialSrc', 'kMaterialImpostorSrc') + LIT_LIBRARIES:
            code = strip_comments(self.msl[lib])
            for m in re.finditer(r'(\w+)\s*\[\[\s*function_constant\((\d+)\)',
                                 code):
                if m.group(2) == '1':
                    self.assertEqual(m.group(1), 'kLightRig', lib)
            for m in re.finditer(r'[^\n,(]*\[\[\s*buffer\(9\)[^\]]*\]\]', code):
                self.assertTrue(RIG_ARGUMENT.search(m.group(0)),
                                '%s binds something other than the rig at '
                                'buffer(9): %r' % (lib, m.group(0).strip()))
        # The tube's rig library: buffer(9) is the rig, as a plain argument,
        # and it declares no function constant of its own. The classic tube
        # uses neither.
        code = strip_comments(self.msl['kBezierTubeRigSrc'])
        self.assertNotIn('function_constant', code)
        nines = re.findall(r'[^\n,(]*\[\[\s*buffer\(9\)[^\]]*\]\]', code)
        self.assertEqual(len(nines), 1, nines)
        self.assertRegex(nines[0], TUBE_RIG_ARGUMENT)
        code = strip_comments(self.msl['kBezierTubeSrc'])
        self.assertNotIn('function_constant', code)
        self.assertNotRegex(code, r'buffer\(9\)')

    def testLightHelpersReadNoFunctionConstant(self):
        """Every helper (but light_response, whose body #615 owns) reaches
        only code that reads no function constant, so a library can call it
        unspecialised (the tube's rig library does)."""
        functions = msl_functions(self.msl['kMaterialSrc'])
        constant = re.compile(r'\bkLightRig\b|\bkMat[A-Z]\w*|function_constant')
        for helper in HELPERS:
            if helper == 'light_response':
                continue
            seen = set()
            todo = [helper]
            while todo:
                name = todo.pop()
                if name in seen:
                    continue
                seen.add(name)
                body = functions[name][1]
                self.assertNotRegex(body, constant,
                                    '%s (reached from %s) reads a function '
                                    'constant' % (name, helper))
                for callee in re.findall(r'\b((?:light|mat)_\w+)\s*\(', body):
                    if callee in functions:
                        todo.append(callee)
            self.assertNotIn('light_response', seen, helper)

    def testNaNGuards(self):
        """No NaN may reach the OIT accumulation, where it spoils the whole
        resolve for that pixel."""
        functions = msl_functions(self.msl['kMaterialSrc'])
        terms = functions['light_terms_view'][1]
        self.assertRegex(terms, r'max\(length\(Lv\),\s*1e-3\)')
        self.assertIn('dot(H, H) > 1e-8', terms)
        self.assertRegex(terms, r'misc\.y\s*>\s*0\.0')
        self.assertNotIn('smoothstep(', terms)   # a zero-width band divides by 0
        self.assertNotIn('normalize(-pEye)', terms)
        self.assertNotIn('normalize(nEye)', terms)
        # the camera's view vector: a point at the eye cannot divide by 0
        self.assertIn('pl <= 1e-6', functions['light_terms'][1])
        self.assertNotIn('normalize(-pEye)', functions['light_terms'][1])

    def testShadingTermsPinned(self):
        """The terms the ticket names, where they are computed: L2's pixel
        checks show each one works (highlight, falloff, softer); these pin
        the form, so a sign or an operand order cannot flip unseen."""
        functions = msl_functions(self.msl['kMaterialSrc'])
        terms = squash(functions['light_terms_view'][1])
        for expr in (
                # the soft edge: smoothstep from cos(outer) (axis.w) up to
                # cos(inner) (radiance.w); the band is inner - outer
                'constfloatband=max(rig.L[i].radiance.w-rig.L[i].axis.w,1e-7);',
                'constfloats=saturate((dot(-Ld,rig.L[i].axis.xyz)-rig.L[i].axis.w)/band);',
                'constfloatspot=s*s*(3.0-2.0*s);',
                # falloff normalised at the aim point: (reference / distance)^falloff,
                # so nearer than the aim point is brighter
                'constfloatfall=rig.L[i].misc.y>0.0?min(pow(rig.L[i].misc.z/d,rig.L[i].misc.y),1e4):1.0;',
                # coloured radiance, scaled by cone, falloff and visibility
                'constfloat3rad=rig.L[i].radiance.rgb*(spot*fall*light_visibility(rig,i,pEye,N,Ld,d));',
                't.diffuse+=rad*(wd*r.diffuse);',
                # Blinn-Phong in the light's colour, at the light's own
                # highlight strength times the material's
                'constfloat3H=Ld+V;',
                't.specular+=rad*(rig.L[i].misc.x*r.highlight*pow(saturate(dot(N,normalize(H))),shin));',
                'constfloatshin=max(rig.head.y*r.sharpness,1.0);',
                # two-sided, toward the viewer
                'if(dot(N,V)<0.0)N=-N;'):
            self.assertIn(expr, terms, expr)
        # the view vector: +z for an orthographic draw (head.z), else toward
        # the eye; handed to light_terms_view unchanged
        camera = squash(functions['light_terms'][1])
        self.assertIn('constfloat3V=(rig.head.z>0.5||pl<=1e-6)?float3(0.0,0.0,1.0):-pEye/pl;',
                      camera)
        self.assertIn('returnlight_terms_view(rig,base,nEye,pEye,V,r);', camera)

    def testOneKneeOnTheRigPath(self):
        functions = msl_functions(self.msl['kMaterialSrc'])
        self.assertIn('mat_soft_knee(', functions['light_finish'][1])
        apply_body = functions['light_apply'][1]
        self.assertIn('light_finish(', apply_body)
        self.assertIn('light_outline(', apply_body)
        self.assertIn('light_terms(', apply_body)
        self.assertNotIn('mat_soft_knee', apply_body)
        self.assertNotIn('mat_soft_knee', functions['light_terms'][1])
        self.assertNotIn('mat_soft_knee', functions['light_terms_view'][1])


class TestRemoveRigStatements(LightMSLCase):
    """The helper the classic-code checks rest on."""

    def testForms(self):
        self.assertEqual(
            squash(remove_rig_statements(
                '{ a(); if (kLightRig) { b(rig); } c(); '
                'if (kLightRig) d(rig, f(x)); e(); }')),
            '{a();c();e();}')
        self.assertEqual(
            squash(remove_rig_statements(
                '{ if (kLightRig)\n  x_rig(a, rig, b);\nelse\n  x(a, b); y(); }')),
            '{x(a,b);y();}')
        self.assertEqual(
            squash(remove_rig_statements(
                '{ if (kLightRig) { p(rig); } else { q(); } }')),
            '{{q();}}')


class TestLitFragments(LightMSLCase):

    def testEveryLitFragmentTakesTheRig(self):
        for lib in LIT_LIBRARIES:
            found = set()
            for name, (sig, body) in fragments(self.msl[lib]).items():
                takes = bool(RIG_ARGUMENT.search(sig))
                if lib in RIG_LIBRARIES and is_lit(body):
                    self.assertTrue(takes, '%s.%s shades colour but does not '
                                    'take the rig' % (lib, name))
                    found.add(name)
                else:
                    # shadow, peel, unlit, cap and coverage fragments never
                    # see it
                    self.assertNotRegex(sig + body, r'LightRigU|kLightRig|\blight_',
                                        '%s.%s' % (lib, name))
            if lib in RIG_LIBRARIES:
                self.assertEqual(found, EXPECTED_RIG_FRAGMENTS[lib], lib)

    def testRigCodeOnlyUnderTheConstant(self):
        for lib in RIG_LIBRARIES:
            for name, (sig, body) in fragments(self.msl[lib]).items():
                if not RIG_ARGUMENT.search(sig):
                    continue
                self.assertRegex(body, RIG_GUARD, '%s.%s' % (lib, name))
                classic = remove_rig_statements(body)
                leftover = RIG_TOKENS.findall(classic)
                self.assertFalse(leftover, '%s.%s mentions %s outside '
                                 '`if (kLightRig)`' % (lib, name, leftover))

    def testOpaqueFragmentReturnsTheClassicColourUnchanged(self):
        """vbo_fragment: an early return under the constant, then today's
        return statement."""
        sig, body = fragments(self.msl['kVBOSrc'])['vbo_fragment']
        classic = remove_rig_statements(body)
        returns = re.findall(r'return\s+([^;]*);', classic)
        self.assertEqual(len(returns), 1)
        self.assertEqual(
            re.sub(r'\s+', '', returns[0]),
            'float4(vbo_material_shade(in.color.rgb,in.normalEye,in.posModel,'
            'lt,mat,envMap,envSmp),in.color.a)')
        rig = body[RIG_GUARD.search(body).end():]
        self.assertIn('light_apply(', rig[:rig.index('return float4(vbo')])

    def testImpostorRigHelpersCopyTheClassicOnes(self):
        """sphere_shade_material_rig and cyl_shade_material_rig are today's
        helpers plus the rig argument and ONE added statement: the light on
        the lit surface, after the material and after the interior cap's
        early return."""
        for lib, rig_name, classic_name, base in IMPOSTOR_RIG_HELPERS:
            functions = msl_functions(self.msl[lib])
            self.assertIn(rig_name, functions, lib)
            rig_sig, rig_body = functions[rig_name]
            classic_sig, classic_body = functions[classic_name]
            # the signature: the classic one with the rig before the outputs
            self.assertEqual(
                squash(rig_sig),
                squash(classic_sig)
                .replace(classic_name + '(', rig_name + '(')
                .replace('threadfloat3&rgb', 'constantLightRigU&rig,threadfloat3&rgb'),
                rig_name)
            light = re.findall(r'\n[ \t]*rgb\s*=\s*light_apply\(([^;]*)\);',
                               rig_body)
            self.assertEqual(len(light), 1, rig_name)
            self.assertEqual(squash(light[0]),
                             squash('rgb, %s, n, pt, rig, light_response(mat)'
                                    % base), rig_name)
            # the last statement, after the cap's return and the material
            tail = rig_body[rig_body.index('light_apply('):]
            self.assertEqual(squash(tail[tail.index(';'):]), ';}', rig_name)
            self.assertLess(rig_body.index('if (!lit) return;'),
                            rig_body.index('light_apply('), rig_name)
            self.assertLess(rig_body.index('mat_impostor_composite('),
                            rig_body.index('light_apply('), rig_name)
            # remove it and what is left is the classic helper, verbatim
            stripped = re.sub(r'\n[ \t]*rgb\s*=\s*light_apply\([^;]*\);', '',
                              rig_body)
            self.assertEqual(squash(stripped), squash(classic_body), rig_name)

    def testImpostorFragmentsChooseTheRigHelperUnderTheConstant(self):
        """Every impostor colour fragment calls the rig helper under the
        constant and today's helper otherwise, with the same arguments."""
        choose = re.compile(r'if\s*\(\s*kLightRig\s*\)\s*(\w+)\(([^;]*)\);'
                            r'\s*else\s*(\w+)\(([^;]*)\);')
        for lib, rig_name, classic_name, _ in IMPOSTOR_RIG_HELPERS:
            for name in EXPECTED_RIG_FRAGMENTS[lib]:
                body = fragments(self.msl[lib])[name][1]
                found = choose.findall(body)
                self.assertEqual(len(found), 1, name)
                rig_call, rig_args, classic_call, classic_args = found[0]
                self.assertEqual((rig_call, classic_call),
                                 (rig_name, classic_name), name)
                self.assertEqual(squash(rig_args).replace('rig,', '', 1),
                                 squash(classic_args), name)
                self.assertNotIn(classic_name + '(',
                                 body.replace(classic_name + '(' + classic_args,
                                              '', 1), name)

    def testImpostorGlassFamilyTakesTheRig(self):
        """Glass sticks split the rig as the VBO glass does; jelly sticks
        take light_apply on top of the composite, before the refraction,
        inside the lit branch. The sphere impostors' glass family goes
        through sphere_glass_rig (testSphereGlassSplitsTheRig)."""
        cyl = fragments(self.msl['kCylinderImpostorSrc'])['cyl_impostor_fragment_oit'][1]
        glass = cyl[:cyl.index('} else if (kMatGlass)')]
        jelly = cyl[cyl.index('} else if (kMatGlass)'):cyl.index('} else {')]
        cover = glass.index('mat_glass_cover(')
        terms = glass.index('light_terms(')
        self.assertLess(glass.index('mat_glass_shade('), terms)
        self.assertLess(terms, cover)
        self.assertRegex(glass[terms:cover],
                         r'light_terms\(rig,\s*base,\s*n,\s*pt,\s*'
                         r'light_response\(mat\)\)')
        self.assertRegex(glass[terms:cover],
                         r'body\s*\+=\s*base\s*\*\s*'
                         r'kMatGlassBaseAttenuation\s*\*\s*\w+\.diffuse')
        self.assertRegex(glass[terms:cover],
                         r'hi\s*\+=\s*light_glass_glints\(\w+\.specular\)\s*\*\s*'
                         r'\(kMatGlassReflection\s*\*\s*saturate\(mat\.p\[0\]\)\)')
        outline = re.search(r'if\s*\(kLightRig\)\s*rgb\s*=\s*'
                            r'light_outline\(rgb,\s*pt,\s*rig\);', glass)
        self.assertIsNotNone(outline)
        self.assertGreater(outline.start(), glass.index('rgb = g.rgb;'))
        self.assertNotIn('light_apply(', glass)
        lit = statements_after(jelly, 'if (lit)')
        apply_ = re.search(r'if\s*\(kLightRig\)\s*rgb\s*=\s*light_apply\('
                           r'rgb,\s*base,\s*n,\s*pt,\s*rig,\s*'
                           r'light_response\(mat\)\);', lit)
        self.assertIsNotNone(apply_)
        self.assertLess(lit.index('mat_impostor_composite('), apply_.start())
        self.assertLess(apply_.start(), lit.index('mat_glass_refraction('))
        self.assertNotIn('light_terms(', jelly)

    def testSphereGlassSplitsTheRig(self):
        """The sphere impostors' glass family (jelly spheres, and the clear
        or frosted glass spheres other reps emit) takes the rig through
        sphere_glass_rig, on top of the composite and before the refraction.
        Jelly takes light_apply. Clear and frosted glass split it as the VBO
        and cylinder glass do (Q1): the diffuse into the body at
        kMatGlassBaseAttenuation, the highlights through the glint curve and
        the Reflection knob; folded and kneed as mat_impostor_composite folds
        this path's own glints, with the same glass shading call, then the
        outlines."""
        sphere = msl_functions(self.msl['kSphereImpostorSrc'])
        branch = fragments(self.msl['kSphereImpostorSrc'])[
            'sphere_impostor_fragment_oit'][1].split('} else {')[0]
        lit = statements_after(branch, 'if (lit)')
        call = re.search(r'if\s*\(kLightRig\)\s*rgb\s*=\s*sphere_glass_rig\('
                         r'rgb,\s*in\.color\.rgb,\s*n,\s*pt,\s*u,\s*mat,\s*'
                         r'envMap,\s*envSmp,\s*rig\);', lit)
        self.assertIsNotNone(call)
        self.assertLess(lit.index('mat_impostor_composite('), call.start())
        self.assertLess(call.start(), lit.index('mat_glass_refraction('))
        self.assertNotIn('light_apply(', branch)
        self.assertNotIn('light_terms(', branch)
        helper = squash(sphere['sphere_glass_rig'][1])
        jelly = helper.index('if(mat.mode==kMatMode_jelly)returnlight_apply('
                             'rgb,base,n,pt,rig,light_response(mat));')
        for expr in ('constLightTermsrigLight=light_terms(rig,base,n,pt,light_response(mat));',
                     'body+=base*kMatGlassBaseAttenuation*rigLight.diffuse;',
                     'hi+=light_glass_glints(rigLight.specular)*'
                     '(kMatGlassReflection*saturate(mat.p[0]));',
                     'returnlight_outline(mat_soft_knee(body+hi),pt,rig);'):
            self.assertGreater(helper.index(expr), jelly, expr)
        # drift guard: the glass shading is mat_impostor_composite's glass
        # branch with the fragment's arguments (m -> mat, N -> n, the key
        # light from SphereU, V = +z)
        composite = squash(msl_functions(self.msl['kMaterialImpostorSrc'])
                           ['mat_impostor_composite'][1])
        self.assertIn('inttaps=(m.mode==kMatMode_frosted_glass)?int(max(1.0,m.p[5])):1;',
                      composite)
        self.assertIn('float3body=mat_glass_shade(base,N,V,m.rough,m.p[0],taps,keyDir,'
                      'envMap,envSmp,hi);returnmat_soft_knee(body+hi);', composite)
        self.assertIn('inttaps=(mat.mode==kMatMode_frosted_glass)?int(max(1.0,mat.p[5])):1;',
                      helper)
        self.assertIn('float3body=mat_glass_shade(base,n,float3(0.0,0.0,1.0),mat.rough,'
                      'mat.p[0],taps,float3(u.klx,u.kly,u.klz),envMap,envSmp,hi);', helper)
        self.assertIn('mat_impostor_composite(in.color.rgb,n,pt,u.lAmbient,u.lDirect,'
                      'u.lReflect,float3(u.klx,u.kly,u.klz),mat,', squash(lit))

    def testGlassSplitsTheRig(self):
        """Clear and frosted glass: the rig's diffuse lights the body at its
        coverage, its specular joins the glints through the classic curve
        and the Reflection knob, both before mat_glass_cover; the outline is
        painted after it. Every other family takes light_apply."""
        sig, body = fragments(self.msl['kVBOSrc'])['vbo_fragment_oit']
        glass = body[:body.index('} else {')]
        other = body[body.index('} else {'):]
        cover = glass.index('mat_glass_cover(')
        terms = glass.index('light_terms(')
        self.assertLess(glass.index('mat_glass_shade('), terms)
        self.assertLess(terms, cover)
        self.assertRegex(glass[terms:cover],
                         r'body\s*\+=\s*in\.color\.rgb\s*\*\s*'
                         r'kMatGlassBaseAttenuation\s*\*\s*\w+\.diffuse')
        self.assertRegex(glass[terms:cover],
                         r'hi\s*\+=\s*light_glass_glints\(\w+\.specular\)\s*\*\s*'
                         r'\(kMatGlassReflection\s*\*\s*saturate\(mat\.p\[0\]\)\)')
        self.assertGreater(glass.index('light_outline('), cover)
        self.assertNotIn('light_apply(', glass)
        self.assertLess(other.index('vbo_material_shade('),
                        other.index('light_apply('))
        self.assertNotIn('light_terms(', other)


class TestPipelines(LightMSLCase):

    def testSpecialisationIndices(self):
        material = strip_comments(self.msl['kMaterialSrc'])
        index = re.search(r'kLightRig\s*\[\[\s*function_constant\((\d+)\)',
                          material).group(1)
        code = strip_comments(self.mm)
        self.assertRegex(code, r'constexpr NSUInteger kLightRigConstantIndex = %s;'
                         % index)
        self.assertRegex(code, r'constexpr NSUInteger kLightRigBufferIndex = 9;')
        self.assertRegex(material, r'kMatFamily\s*\[\[\s*function_constant\(0\)')
        body = cpp_function(self.mm, 'RendererMetal::materialFragmentFunction')
        family = re.search(r'setConstantValue:&\w+ type:MTLDataTypeInt '
                           r'atIndex:0\]', body)
        rig = re.search(r'setConstantValue:&\w+ type:MTLDataTypeBool '
                        r'atIndex:kLightRigConstantIndex\]', body)
        self.assertIsNotNone(family)
        self.assertIsNotNone(rig, 'the light rig constant is not set')
        specialise = body.index('constantValues:')
        for m in (family, rig):
            # set unconditionally, before the function is specialised
            self.assertEqual(depth_at(body, m.start()), 1)
            self.assertLess(m.start(), specialise)
        # the rig variant asks for true; every classic VBO build passes nothing
        rig_fn = cpp_function(self.mm, 'RendererMetal::vboRigFragmentFunction')
        self.assertRegex(rig_fn, r'materialFragmentFunction\([^;]*true\);')
        build = cpp_function(self.mm, 'RendererMetal::buildVBOPipelines')
        calls = re.findall(r'materialFragmentFunction\(([^;]*)\);', build)
        self.assertEqual(len(calls), 2)
        for args in calls:
            self.assertEqual(len(args.split(',')), 3, args)
        # ...and so does every classic sphere build
        build = cpp_function(self.mm, 'RendererMetal::buildImpostorPipelines')
        calls = re.findall(r'materialFragmentFunction\(([^;]*)\);', build)
        self.assertEqual(len(calls), 2)
        for args in calls:
            self.assertEqual(len(args.split(',')), 3, args)

    def testRigBoundOnlyWhenOn(self):
        code = strip_comments(self.mm)
        bind = cpp_function(self.mm, 'RendererMetal::bindLightRig')
        self.assertEqual(code.count('atIndex:kLightRigBufferIndex'), 1)
        self.assertIn('atIndex:kLightRigBufferIndex', bind)
        first = re.match(r'\{\s*if\s*\(\s*!_lightRigOn\s*\)\s*return\s*;', bind)
        self.assertIsNotNone(first, 'bindLightRig must return first while the '
                             'rig is off')
        self.assertRegex(bind, r'head\[2\]\s*=\s*ortho')
        # callers
        callers = set()
        for m in re.finditer(r'\bbindLightRig\s*\(', code):
            line_start = code.rindex('\n', 0, m.start()) + 1
            line = code[line_start:code.index('\n', m.start())]
            if 'RendererMetal::bindLightRig' in line or 'void bindLightRig' in line:
                continue
            owner = re.findall(r'^[\w<>:\*\s]*RendererMetal::(\w+)\s*\(',
                               code[:m.start()], re.M)[-1]
            callers.add(owner)
            if owner == 'bindRepMaterial':
                body = cpp_function(self.mm, 'RendererMetal::bindRepMaterial')
                self.assertRegex(body, r'if\s*\(\s*!_shadowMode\s*&&\s*!_peelMode\s*\)'
                                       r'\s*bindLightRig\(')
            elif owner == 'drawBezierTubes':
                # only when the rig pipeline was chosen, with the ortho flag
                # bindRepMaterial derives
                body = cpp_function(self.mm, 'RendererMetal::drawBezierTubes')
                self.assertRegex(body, r'if\s*\(\s*tubeRig\s*\)\s*bindLightRig\('
                                       r'_encoder,\s*_projectionMatrix\[15\]\s*!=\s*'
                                       r'0\.0f\s*\?\s*1\s*:\s*0\);')
        self.assertEqual(callers, BIND_CALLERS)
        # on only with lights; off again at every frame start
        set_rig = cpp_function(self.mm, 'RendererMetal::setLightRig')
        self.assertRegex(set_rig, r'_lightRigOn\s*=\s*\w+\s*&&\s*\w+->head\[0\]\s*>=\s*1')
        begin = cpp_function(self.mm, 'RendererMetal::beginFrame')
        self.assertIn('_lightRigOn = false;', begin)

    def testRigPipelinesChosenOnlyWhenOn(self):
        guard = (r'if\s*\(\s*_lightRigOn\s*&&\s*!_shadowMode\s*&&\s*!_peelMode'
                 r'\s*&&\s*!unlit\s*\)\s*\{')
        for fn in ('RendererMetal::drawVBO', 'RendererMetal::drawVBOIndexed'):
            body = cpp_function(self.mm, fn)
            rig_calls = [m for m in re.finditer(r'cachedVBOPipeline\(([^;]*)\);', body)
                         if 'true' in m.group(1)]
            self.assertEqual(len(rig_calls), 1, fn)
            block = re.search(guard, body)
            self.assertIsNotNone(block, fn)
            end = match_brace(body, block.end() - 1)
            self.assertTrue(block.end() < rig_calls[0].start() < end, fn)
            self.assertRegex(rig_calls[0].group(1),
                             r'_oitActive\s*\?\s*VBOPipelineVariant::Oit\s*:\s*'
                             r'VBOPipelineVariant::Lit')
            # ...ahead of today's selection, which runs only when it chose
            # nothing (always, with the rig off)
            prebuilt = re.search(r'if\s*\(\s*!pipeline\s*&&\s*!_shadowMode\s*&&\s*'
                                 r'!_peelMode\s*&&\s*!unlit\s*&&\s*posOffset == 0',
                                 body)
            self.assertIsNotNone(prebuilt, fn)
            self.assertLess(end, prebuilt.start(), fn)
            # the log-once fallback
            self.assertIn('_lightRigWarned = true;', body[block.end():end])
        # no other call asks for a rig pipeline
        code = strip_comments(self.mm)
        rig_requests = [m for m in re.finditer(r'cachedVBOPipeline\(([^;]*)\);', code)
                        if 'true' in m.group(1)]
        self.assertEqual(len(rig_requests), 2)

    def testRigCacheKeyLeavesClassicKeysAlone(self):
        body = cpp_function(self.mm, 'RendererMetal::cachedVBOPipeline')
        family_mix = body.index('mix((uint64_t)family);')
        rig_mix = re.search(r'if\s*\(\s*lightRig\s*\)\s*mix\(', body)
        self.assertIsNotNone(rig_mix)
        self.assertLess(family_mix, rig_mix.start())
        # today's seven layout fields, then the family: a classic key is
        # exactly what it was
        self.assertEqual(len(re.findall(r'\bmix\(', body[:family_mix])), 7)
        # Lit and Oit keep their family (a marble surface stays marble)
        self.assertRegex(body, r'variant != VBOPipelineVariant::Lit && '
                               r'variant != VBOPipelineVariant::Oit')
        # the rig's functions come from the lazily specialised variants
        self.assertIn('vboRigFragmentFunction(family, false)', body)
        self.assertRegex(body, r'oitPipelineForVD\(vd, family, lightRig\)')
        oit = cpp_function(self.mm, 'RendererMetal::oitPipelineForVD')
        self.assertIn('vboRigFragmentFunction(family, true)', oit)

    def testRetainedLibraryIsReleased(self):
        build = cpp_function(self.mm, 'RendererMetal::buildVBOPipelines')
        self.assertIn('_vboLibrary = lib;', build)
        # released only on the early return that keeps no functions from it
        self.assertEqual(len(re.findall(r'\[lib release\];\s*return;', build)), 1)
        self.assertEqual(build.count('[lib release]'), 1)
        # released, with the rig functions, before every rebuild and in the dtor
        self.assertLess(build.index('releaseVBORigFunctions();'),
                        build.index('newLibraryWithSource:'))
        self.assertLess(build.index('[_vboLibrary release];'),
                        build.index('newLibraryWithSource:'))
        dtor = cpp_function(self.mm, 'RendererMetal::~RendererMetal')
        self.assertIn('releaseVBORigFunctions();', dtor)
        self.assertIn('[_vboLibrary release];', dtor)
        release = cpp_function(self.mm, 'RendererMetal::releaseVBORigFunctions')
        for member in ('_vboFragmentRigFunc[f]', '_vboFragmentOitRigFunc[f]'):
            self.assertIn('[%s release];' % member, release)
        # the rig pipelines live in the layout cache, emptied before the
        # library is rebuilt
        rebuild = cpp_function(self.mm, 'RendererMetal::rebuildDrawPipelines')
        self.assertLess(rebuild.index('_vboPipelineCache.clear();'),
                        rebuild.index('buildVBOPipelines();'))


class TestImpostorPipelines(LightMSLCase):

    def testSphereRigPipelinesComeFromTheClassicBuild(self):
        build = cpp_function(self.mm, 'RendererMetal::buildImpostorPipelines')
        # the library and both descriptors are kept (+1), released first
        for kept, value in (('_sphereLib', 'lib'), ('_sphereOpaqueDesc', 'psd'),
                            ('_sphereOitDesc', 'op')):
            self.assertIn('%s = %s;' % (kept, value), build)
            self.assertLess(build.index('[%s release];' % kept),
                            build.index('newLibraryWithSource:'), kept)
        # the functions it no longer leaks
        for released in ('[vfn release];', '[sfn release];', '[sp release];'):
            self.assertIn(released, build)
        rig = cpp_function(self.mm, 'RendererMetal::ensureSphereRigPipelines')
        first = re.match(r'\{\s*if\s*\(\s*_sphereRigBuilt\s*\)\s*return\s*;'
                         r'\s*_sphereRigBuilt\s*=\s*true\s*;', rig)
        self.assertIsNotNone(first, 'one attempt per build')
        calls = re.findall(r'materialFragmentFunction\(([^;]*)\);', rig)
        self.assertEqual(sorted(squash(c).split(',')[1] for c in calls),
                         ['@"sphere_impostor_fragment"',
                          '@"sphere_impostor_fragment_oit"'])
        for args in calls:
            self.assertTrue(squash(args).startswith('_sphereLib,'), args)
            self.assertTrue(squash(args).endswith('true'), args)
        # the classic descriptors, with only the fragment function changed
        self.assertIn('newRenderPipelineStateWithDescriptor:_sphereOpaqueDesc', rig)
        self.assertIn('newRenderPipelineStateWithDescriptor:_sphereOitDesc', rig)
        self.assertNotIn('alloc]', rig)
        self.assertRegex(rig, r'setOitRefractAttachment\(_sphereOitDesc\.'
                              r'colorAttachments\[2\],\s*_oitRefractEnabled,'
                              r'\s*f == cMaterialFamily_glass\)')
        # released and rebuilt with every classic rebuild, and in the dtor
        release = cpp_function(self.mm, 'RendererMetal::releaseSphereRigPipelines')
        for member in ('_sphereRigPipeline[f]', '_sphereRigOitPipeline[f]'):
            self.assertIn('[%s release];' % member, release)
        self.assertIn('_sphereRigBuilt = false;', release)
        for fn in ('RendererMetal::rebuildDrawPipelines',
                   'RendererMetal::~RendererMetal'):
            body = cpp_function(self.mm, fn)
            self.assertIn('releaseSphereRigPipelines();', body, fn)
            for kept in ('_sphereLib', '_sphereOpaqueDesc', '_sphereOitDesc'):
                self.assertIn('[%s release];' % kept, body, fn)

    def testSphereDrawPicksTheRigOnlyWhenOn(self):
        body = cpp_function(self.mm, 'RendererMetal::drawSphereImpostors')
        block = re.search(r'if\s*\(\s*_lightRigOn\s*&&\s*!_shadowMode\s*&&\s*'
                          r'!_peelMode\s*\)\s*\{', body)
        self.assertIsNotNone(block)
        end = match_brace(body, block.end() - 1)
        inside = body[block.end():end]
        self.assertIn('ensureSphereRigPipelines();', inside)
        self.assertRegex(inside, r'_oitActive\s*\?\s*_sphereRigOitPipeline\s*:\s*'
                                 r'_sphereRigPipeline')
        # this family's rig pipeline, else the rig's default, else classic
        self.assertIn('rigSet[cMaterialFamily_default]', inside)
        self.assertIn('_lightRigWarned = true;', inside)
        self.assertEqual(body.count('ensureSphereRigPipelines('), 1)
        # starts nil, so with the rig off the classic pipelines are chosen
        self.assertRegex(body, r'id<MTLRenderPipelineState>\s+rigPipeline\s*=\s*nil;')
        self.assertRegex(body, r'setRenderPipelineState:rigPipeline\s*\?\s*rigPipeline'
                               r'\s*:\s*_sphereOitPipeline\[sphereFam\]\]')
        self.assertRegex(body, r'setRenderPipelineState:rigPipeline\s*\?\s*rigPipeline'
                               r'\s*:\s*_sphereImpostorPipeline\[sphereFam\]\]')
        # shadow and peel never take it
        self.assertIn('setRenderPipelineState:_sphereShadowPipeline]', body)
        self.assertIn('setRenderPipelineState:_spherePeelPipeline]', body)
        # the rig is bound with the material on every colour draw
        self.assertLess(body.rindex('setRenderPipelineState:'),
                        body.index('bindRepMaterial();'))

    def testCylinderRigEntriesAreKeyedApart(self):
        header = strip_comments(read(METAL_MM.replace('.mm', '.h')))
        self.assertRegex(header, r'std::map<std::tuple<NSUInteger,\s*int,\s*int,'
                                 r'\s*bool>,\s*CylinderPipelines>')
        build = cpp_function(self.mm, 'RendererMetal::buildCylinderImpostorPipeline')
        self.assertRegex(build, r'std::make_tuple\([^;]*cylFam,\s*lightRig\)')
        calls = re.findall(r'materialFragmentFunction\(([^;]*)\);', build)
        self.assertEqual(len(calls), 4)
        for args in calls:
            self.assertEqual(squash(args).split(',')[-1], 'lightRig', args)
        # no shadow or peel pipeline for a rig entry
        self.assertRegex(build, r'sfn\s*=\s*lightRig\s*\?\s*nil\s*:')
        # a failed rig entry is cached, so it is not recompiled every frame
        self.assertIn('if (_cylinderImpostorPipeline || lightRig)', build)

    def testCylinderDrawPicksTheRigOnlyWhenOn(self):
        body = cpp_function(self.mm, 'RendererMetal::drawCylinderImpostors')
        self.assertRegex(body, r'const bool cylRig\s*=\s*_lightRigOn\s*&&\s*'
                               r'!_shadowMode\s*&&\s*!_peelMode;')
        calls = re.findall(r'buildCylinderImpostorPipeline\(([^;]*)\);', body)
        self.assertEqual([squash(c) for c in calls], ['call,cylRig', 'call,false'])
        fallback = re.search(r'if\s*\(\s*cylRig\s*&&', body)
        self.assertIsNotNone(fallback)
        end = match_brace(body, body.index('{', fallback.end()))
        inside = body[fallback.end():end]
        self.assertIn('_lightRigWarned = true;', inside)
        self.assertIn('buildCylinderImpostorPipeline(call, false);', inside)
        # the only caller
        code = strip_comments(self.mm)
        self.assertEqual(len(re.findall(r'buildCylinderImpostorPipeline\(call', code)), 2)
        self.assertLess(body.rindex('setRenderPipelineState:'),
                        body.index('bindRepMaterial();'))


def descriptor_lines(body):
    """The vertex- and pipeline-descriptor settings of a pipeline builder,
    whitespace removed, in order, without the two shader functions (the one
    thing a rig pipeline changes)."""
    lines = [squash(m) for m in re.findall(r'^\s*((?:vd|psd)\.[^;]*;)', body, re.M)]
    return [line for line in lines
            if not line.startswith(('psd.vertexFunction=', 'psd.fragmentFunction='))]


class TestBezierTube(LightMSLCase):
    """The tube's rig is a separate library and pipeline, so the classic tube
    stays exactly as it was (no rig: byte-identical), and the rig copies of
    its two functions cannot drift from the classic ones."""

    def setUp(self):
        super().setUp()
        self.classic = msl_functions(self.msl['kBezierTubeSrc'])
        self.rig = msl_functions(self.msl['kBezierTubeRigSrc'])

    def testClassicTubeUntouched(self):
        code = strip_comments(self.msl['kBezierTubeSrc'])
        self.assertNotRegex(code, r'\blight_\w+|\bkLightRig\b|\bLightRigU\b|'
                                  r'\bposEye\b|\bkMat\w*')
        self.assertEqual(sorted(fragments(self.msl['kBezierTubeSrc'])),
                         ['bezier_tube_fragment'])
        # compiled alone, from the classic functions, as before #613
        build = cpp_function(self.mm, 'RendererMetal::buildBezierTubePipeline')
        self.assertRegex(build, r'newLibraryWithSource:kBezierTubeSrc\s+options:')
        self.assertIn('newFunctionWithName:@"bezier_tube_vertex"]', build)
        self.assertIn('newFunctionWithName:@"bezier_tube_fragment"]', build)
        self.assertNotIn('Rig', build)
        # the rig library: the shared material block, then the classic tube,
        # then the rig's functions; and it is the only other tube library
        rig = cpp_function(self.mm, 'RendererMetal::buildBezierTubeRigPipeline')
        self.assertRegex(rig, r'newLibraryWithSource:\[\[kMaterialSrc\s+'
                              r'stringByAppendingString:kBezierTubeSrc\]\s+'
                              r'stringByAppendingString:kBezierTubeRigSrc\]\s+options:')
        code = strip_comments(self.mm)
        libraries = re.findall(r'newLibraryWithSource:(.*?)\boptions:', code, re.S)
        self.assertEqual(sorted(squash(lib) for lib in libraries
                                if 'kBezierTube' in lib),
                         ['[[kMaterialSrcstringByAppendingString:kBezierTubeSrc]'
                          'stringByAppendingString:kBezierTubeRigSrc]',
                          'kBezierTubeSrc'])

    def testTubeRigCopiesMatch(self):
        """Drift guards: each rig function is the classic one plus exactly
        what the rig needs, and nothing else."""
        # TubeRigOut is TubeOut plus the eye-space position, at the end
        tube = strip_comments(self.msl['kBezierTubeSrc'])
        rig = strip_comments(self.msl['kBezierTubeRigSrc'])
        out = re.search(r'struct TubeOut\s*(\{.*?\};)', tube, re.S).group(1)
        rig_out = re.search(r'struct TubeRigOut\s*(\{.*?\};)', rig, re.S).group(1)
        self.assertEqual(squash(rig_out), squash(out)[:-2] + 'float3posEye;};')
        # both are post-tessellation vertex functions over the same patch
        for code, name in ((tube, 'TubeOut bezier_tube_vertex('),
                           (rig, 'TubeRigOut bezier_tube_vertex_rig(')):
            self.assertRegex(code, r'\[\[patch\(quad,\s*4\)\]\]\s*vertex\s+'
                             + re.escape(name))
        # the vertex stage: the classic one, renamed, plus o.posEye
        sig, body = self.rig['bezier_tube_vertex_rig']
        classic_sig, classic_body = self.classic['bezier_tube_vertex']
        self.assertEqual(squash(sig).replace('TubeRigOut', 'TubeOut')
                         .replace('bezier_tube_vertex_rig(', 'bezier_tube_vertex('),
                         squash(classic_sig))
        added = re.findall(r'\n[ \t]*o\.posEye\s*=\s*([^;]*);', body)
        self.assertEqual(added, ['eye.xyz'])
        self.assertLess(body.index('float4 eye = U.modelview'),
                        body.index('o.posEye'))
        stripped = re.sub(r'\n[ \t]*o\.posEye\s*=[^;]*;', '', body)
        self.assertEqual(squash(stripped).replace('TubeRigOut', 'TubeOut'),
                         squash(classic_body))
        # the fragment: the classic two-light colour, then the rig on top of
        # it with the neutral response, then the classic return
        sig, body = self.rig['bezier_tube_fragment_rig']
        classic_sig, classic_body = self.classic['bezier_tube_fragment']
        self.assertEqual(
            squash(sig),
            squash(classic_sig)
            .replace('bezier_tube_fragment(', 'bezier_tube_fragment_rig(')
            .replace('TubeOutin', 'TubeRigOutin')
            .replace('constantLightU&lt[[buffer(0)]])',
                     'constantLightU&lt[[buffer(0)]],'
                     'constantLightRigU&rig[[buffer(9)]])'))
        light = re.findall(r'\n[ \t]*rgb\s*=\s*light_apply\(([^;]*)\);', body)
        self.assertEqual(len(light), 1)
        self.assertEqual(squash(light[0]),
                         squash('rgb, in.color.rgb, nrm, in.posEye, rig, '
                                'light_response_neutral()'))
        tail = body[body.index('light_apply('):]
        self.assertEqual(squash(tail[tail.index(';'):]),
                         ';returnfloat4(rgb,in.color.a);}')
        stripped = re.sub(r'\n[ \t]*rgb\s*=\s*light_apply\([^;]*\);', '', body)
        self.assertEqual(squash(stripped), squash(classic_body))

    def testTubeRigReadsNoFunctionConstant(self):
        """The builder takes the rig functions unspecialised, so neither they
        nor any helper they reach may read a function constant. The neutral
        response, not light_response (whose body #615 owns), keeps it so."""
        material = msl_functions(self.msl['kMaterialSrc'])
        constant = re.compile(r'\bkLightRig\b|\bkMat[A-Z]\w*|function_constant')
        for name in ('bezier_tube_vertex_rig', 'bezier_tube_fragment_rig'):
            sig, body = self.rig[name]
            self.assertNotRegex(sig + body, constant, name)
        seen = set()
        todo = re.findall(r'\b((?:light|mat)_\w+)\s*\(',
                          self.rig['bezier_tube_fragment_rig'][1])
        self.assertIn('light_apply', todo)
        while todo:
            name = todo.pop()
            if name in seen:
                continue
            seen.add(name)
            self.assertIn(name, material, name)
            body = material[name][1]
            self.assertNotRegex(body, constant, '%s reads a function constant' % name)
            todo += [c for c in re.findall(r'\b((?:light|mat)_\w+)\s*\(', body)
                     if c in material]
        self.assertNotIn('light_response', seen)
        self.assertIn('light_response_neutral', seen)
        # plain first; specialised (family default, rig off) only if Metal
        # lists a constant against the function
        fn = cpp_function(self.mm, 'bezierTubeRigFunction')
        plain = fn.index('newFunctionWithName:name]')
        self.assertRegex(fn[plain:], r'^newFunctionWithName:name\]\s*;\s*if\s*\(\s*fn\s*&&\s*'
                                     r'fn\.functionConstantsDictionary\.count\s*==\s*0\s*\)'
                                     r'\s*return\s+fn\s*;')
        self.assertLess(plain, fn.index('constantValues:'))
        self.assertIn('int fam = cMaterialFamily_default;', fn)
        self.assertIn('bool rig = false;', fn)
        self.assertRegex(fn, r'type:MTLDataTypeInt atIndex:0\]')
        self.assertRegex(fn, r'type:MTLDataTypeBool atIndex:kLightRigConstantIndex\]')
        self.assertIn('[cv release];', fn)

    def testTubeRigPipeline(self):
        classic = cpp_function(self.mm, 'RendererMetal::buildBezierTubePipeline')
        rig = cpp_function(self.mm, 'RendererMetal::buildBezierTubeRigPipeline')
        # lazy, one attempt per build
        self.assertRegex(rig, r'^\{\s*if\s*\(\s*_bezierTubeRigPipeline\s*\|\|\s*'
                              r'_bezierTubeRigTried\s*\)\s*return\s*;\s*'
                              r'_bezierTubeRigTried\s*=\s*true\s*;')
        self.assertIn('bezierTubeRigFunction(lib, @"bezier_tube_vertex_rig")', rig)
        self.assertIn('bezierTubeRigFunction(lib, @"bezier_tube_fragment_rig")', rig)
        # the classic descriptor, tessellation included, field for field
        lines = descriptor_lines(rig)
        self.assertEqual(lines, descriptor_lines(classic))
        self.assertIn('psd.maxTessellationFactor=64;', lines)
        self.assertIn('psd.rasterSampleCount=_sampleCount;', lines)
        for body in (classic, rig):
            self.assertIn('psd.vertexFunction = vfn;', body)
            self.assertIn('psd.fragmentFunction = ffn;', body)
        self.assertIn('_bezierTubeRigPipeline = [_device '
                      'newRenderPipelineStateWithDescriptor:psd error:&err];', rig)
        # only the pipeline state is kept
        for released in ('[psd release];', '[vfn release];', '[ffn release];',
                         '[lib release];'):
            self.assertIn(released, rig)
        # released with the classic tube, and retried, at every rebuild
        rebuild = cpp_function(self.mm, 'RendererMetal::rebuildDrawPipelines')
        self.assertIn('[_bezierTubeRigPipeline release];', rebuild)
        self.assertIn('_bezierTubeRigPipeline = nil;', rebuild)
        self.assertIn('_bezierTubeRigTried = false;', rebuild)
        dtor = cpp_function(self.mm, 'RendererMetal::~RendererMetal')
        self.assertIn('[_bezierTubeRigPipeline release];', dtor)

    def testTubeDrawPicksTheRigOnlyWhenOn(self):
        body = cpp_function(self.mm, 'RendererMetal::drawBezierTubes')
        # today's guards, before anything rig-related
        build = body.index('buildBezierTubeRigPipeline();')
        for guard in (r'if\s*\(\s*_shadowMode\s*\)\s*return\s*;',
                      r'if\s*\(\s*_peelMode\s*\)\s*return\s*;',
                      r'if\s*\(\s*!_bezierTubePipeline\s*\)\s*return\s*;'):
            m = re.search(guard, body)
            self.assertIsNotNone(m, guard)
            self.assertLess(m.start(), build, guard)
        # starts as the classic pipeline: with the rig off, today's draw
        self.assertRegex(body, r'id<MTLRenderPipelineState>\s+tubePipeline\s*='
                               r'\s*_bezierTubePipeline\s*;')
        self.assertRegex(body, r'bool\s+tubeRig\s*=\s*false\s*;')
        block = re.search(r'if\s*\(\s*_lightRigOn\s*\)\s*\{', body)
        self.assertIsNotNone(block)
        end = match_brace(body, block.end() - 1)
        inside = body[block.end():end]
        self.assertIn('buildBezierTubeRigPipeline();', inside)
        self.assertIn('tubePipeline = _bezierTubeRigPipeline;', inside)
        self.assertIn('tubeRig = true;', inside)
        self.assertIn('_lightRigWarned = true;', inside)
        self.assertEqual(len(re.findall(r'tubeRig\s*=\s*true', body)), 1)
        self.assertEqual(re.findall(r'setRenderPipelineState:(\w+)\]', body),
                         ['tubePipeline'])
        # the rig is bound after the classic lighting and before the draw
        bind = re.search(r'if\s*\(\s*tubeRig\s*\)\s*bindLightRig\(', body)
        self.assertIsNotNone(bind)
        self.assertLess(body.index('setFragmentBytes:&_lt'), bind.start())
        self.assertLess(bind.start(), body.index('drawPatches:'))
        # the only caller of the rig builder
        code = strip_comments(self.mm)
        self.assertEqual(len(re.findall(r'(?<!::)buildBezierTubeRigPipeline\(\);',
                                        code)), 1)


class TestLayout(LightMSLCase):

    def testLayoutMirrors(self):
        material = strip_comments(self.msl['kMaterialSrc'])
        light = re.search(r'struct LightRigLight\s*\{(.*?)\};', material, re.S)
        rig = re.search(r'struct LightRigU\s*\{(.*?)\};', material, re.S)
        light_fields = re.findall(r'(\w+)\s+(\w+)\s*;', light.group(1))
        self.assertEqual(light_fields, [('float4', 'pos'), ('float4', 'axis'),
                                        ('float4', 'radiance'), ('float4', 'misc')])
        rig_fields = re.findall(r'(\w+)\s+(\w+)(?:\[(\d+)\])?\s*;', rig.group(1))
        # #613's head and lights first, unchanged, then #616's tail
        self.assertEqual(rig_fields[:2], [('float4', 'head', ''),
                                          ('LightRigLight', 'L', '6')])
        prefix = 16 + int(rig_fields[1][2]) * 16 * len(light_fields)
        self.assertEqual(prefix, 400)
        self.assertEqual(rig_fields[2:], [('LightRigShadow', 'S', '3'),
                                          ('float4', 'shadowGrid', ''),
                                          ('float4', 'shadowTile', '')])
        shadow = re.search(r'struct LightRigShadow\s*\{(.*?)\};', material, re.S)
        shadow_fields = re.findall(r'(\w+)\s+(\w+)\s*;', shadow.group(1))
        self.assertEqual(shadow_fields, [('float4x4', 'viewProj'),
                                         ('float4', 'info')])
        shadow_size = 64 + 16
        # float4x4 and float4 are 16-byte aligned: no padding anywhere
        size = prefix + int(rig_fields[2][2]) * shadow_size + 16 + 16
        self.assertEqual(size, 672)
        header = strip_comments(read(BLOCK_H))
        cpp_light = re.search(r'struct LightRigBlockLight\s*\{(.*?)\};', header, re.S)
        cpp_rig = re.search(r'struct LightRigBlock\s*\{(.*?)\};', header, re.S)
        cpp_shadow = re.search(r'struct LightRigBlockShadow\s*\{(.*?)\};',
                               header, re.S)
        self.assertEqual(re.findall(r'float\s+(\w+)\[4\];', cpp_light.group(1)),
                         [name for _, name in light_fields])
        self.assertEqual(re.findall(r'float\s+(\w+)\[4\];', cpp_rig.group(1)),
                         ['head', 'shadowGrid', 'shadowTile'])
        self.assertEqual(re.findall(r'float\s+(\w+)\[(\d+)\];', cpp_shadow.group(1)),
                         [('viewProj', '16'), ('info', '4')])
        slots = re.search(r'kLightRigBlockSlots\s*=\s*(\d+);', header).group(1)
        self.assertEqual(slots, rig_fields[1][2])
        shadow_slots = re.search(r'kLightRigBlockShadowSlots\s*=\s*(\d+);',
                                 header).group(1)
        self.assertEqual(shadow_slots, rig_fields[2][2])
        self.assertRegex(header, r'sizeof\(LightRigBlock\)\s*==\s*%d' % size)
        self.assertRegex(header, r'sizeof\(LightRigBlockShadow\)\s*==\s*%d'
                         % shadow_size)
        self.assertRegex(header, r'offsetof\(LightRigBlock,\s*shadow\)\s*==\s*%d'
                         % prefix)
        # the rig model's light limit is the block's
        self.assertRegex(strip_comments(read(SHADING_H)),
                         r'static_assert\(kLightRigMaxLights\s*==\s*'
                         r'kLightRigBlockSlots')
        # the loops cover every slot and stop at the count
        for helper in ('light_terms_view', 'light_outline'):
            body = msl_functions(self.msl['kMaterialSrc'])[helper][1]
            self.assertIn('i < %s' % slots, body, helper)
            self.assertIn('int(rig.head.x)', body, helper)


class TestSceneRender(LightMSLCase):

    def testSceneRenderReadsTheRigOnce(self):
        body = cpp_function(read(SCENE_RENDER), 'SceneRenderMetal')
        self.assertEqual(body.count('SceneLightsFrame('), 1)
        self.assertEqual(body.count('setLightRig('), 1)
        self.assertEqual(body.count('setLightingParams('), 1)
        shadow_pass = body.index('beginShadowPass()')
        for call in ('SceneLightsFrame(', 'setLightingParams(', 'setLightRig('):
            self.assertLess(body.index(call), shadow_pass, call)
            self.assertLess(body.index(call), body.index('SceneRenderAll('), call)
        # the classic terms come only through SceneLightsFrame
        for setting in ('cSetting_ambient', 'cSetting_direct', 'cSetting_reflect',
                        'SceneGetAdjustedLightValues'):
            self.assertNotIn(setting, body, setting)
        # with this frame's render modelview
        self.assertRegex(body, r'SceneLightsFrame\(G,\s*glm::dmat4\(glm::make_mat4\(mv\)\)\)')


class TestRayTracedReflections(LightMSLCase):
    """metal_raytrace 1 (the default): rt_composite mixes each reflective
    pixel with what its reflection ray hits. Those hits are shaded in the RT
    library, which cannot take kMaterialSrc, so it carries copies of the rig's
    structs and helpers; with a rig on, the hits take the rig as the raster
    paths do (decision 15 alone would leave them ambient-only). The classic
    composite is specialised with the rig's constant false, so a frame
    without a rig runs exactly today's composite."""

    def setUp(self):
        super().setUp()
        self.rt = self.msl['kRTSrc']
        self.rt_code = strip_comments(self.rt)
        self.rt_functions = msl_functions(self.rt)
        self.material = msl_functions(self.msl['kMaterialSrc'])

    def testRigCopiesMatch(self):
        """Drift guards: every copy is kMaterialSrc's code verbatim."""
        material = strip_comments(self.msl['kMaterialSrc'])
        for struct in STRUCTS:
            pattern = r'struct\s+%s\s*(\{.*?\};)' % struct
            ours = re.search(pattern, self.rt_code, re.S)
            theirs = re.search(pattern, material, re.S)
            self.assertIsNotNone(ours, struct)
            self.assertEqual(squash(ours.group(1)), squash(theirs.group(1)), struct)
        attribute = re.compile(r'__attribute__\(\(unused\)\)')
        for name in RT_COPIES:
            self.assertIn(name, self.rt_functions, name)
            sig, body = self.rt_functions[name]
            msig, mbody = self.material[name]
            self.assertEqual(squash(attribute.sub('', sig)),
                             squash(attribute.sub('', msig)), name)
            self.assertEqual(squash(body), squash(mbody), name)
        # and nothing that paints or needs the material table
        for name in ('light_outline', 'light_apply', 'light_response',
                     'light_terms', 'light_glass_glints'):
            self.assertNotIn(name, self.rt_functions, name)
            self.assertNotRegex(self.rt_code, r'\b%s\s*\(' % name, name)

    def testCompositeTakesTheRigUnderItsConstant(self):
        constant = re.search(r'constant\s+bool\s+kRTLightRig\s*\[\[\s*'
                             r'function_constant\((\d+)\)\s*\]\]\s*;', self.rt_code)
        self.assertIsNotNone(constant)
        self.assertEqual(constant.group(1), '1')
        self.assertRegex(self.rt_code, r'kRTTrans\s*\[\[\s*function_constant\(0\)')
        self.assertNotRegex(self.rt_code, r'\bkLightRig\b')
        frags = fragments(self.rt)
        self.assertEqual(sorted(frags), ['rt_ao', 'rt_composite'])
        sig, body = frags['rt_composite']
        self.assertRegex(sig, RT_RIG_ARGUMENT)
        self.assertNotRegex(frags['rt_ao'][0] + frags['rt_ao'][1],
                            r'LightRigU|kRTLightRig|\brig\b|rt_rig_hit')
        # buffer(13) is the rig's alone
        self.assertEqual(len(re.findall(r'buffer\(13\)', self.rt_code)), 1)
        # every rig statement under the constant, and what is left is free of
        # the rig: the classic specialisation is today's composite
        guards = RT_RIG_GUARD.findall(body)
        self.assertEqual(len(guards), 2)
        classic = remove_rig_statements(body, RT_RIG_GUARD)
        self.assertFalse(re.findall(r'\brig\b|rt_rig_hit|light_\w+|LightTerms',
                                    classic))
        # 1: the opaque hit, after its classic colour, before the fog
        hit = re.search(r'reflCol\s*=\s*hc\s*\*\s*min\(inten,\s*1\.0\)\s*\+\s*specv;\s*'
                        r'if\s*\(\s*kRTLightRig\s*\)\s*reflCol\s*=\s*rt_rig_hit\('
                        r'rig,\s*u,\s*reflCol,\s*hc,\s*hitP,\s*hn,\s*R\);\s*'
                        r'reflCol\s*=\s*mix\(reflCol,\s*envCol,', body)
        self.assertIsNotNone(hit)
        # 2: the transparent layer in front of it (kRTTrans), likewise
        layer = re.search(r'float3\s+tcol\s*=\s*tc\.rgb\s*\*\s*min\(inten,\s*1\.0\)\s*'
                          r'\+\s*specv;\s*if\s*\(\s*kRTLightRig\s*\)\s*tcol\s*=\s*'
                          r'rt_rig_hit\(rig,\s*u,\s*tcol,\s*tc\.rgb,\s*tr\.origin\s*\+\s*'
                          r'R\s*\*\s*th\.distance,\s*hn,\s*R\);\s*tcol\s*=\s*mix\(tcol,'
                          r'\s*envCol,', body)
        self.assertIsNotNone(layer)
        # both inside the reflection block, which matCount 0 skips
        block = body.index('if (u.matCount > 0.5)')
        self.assertLess(block, hit.start())
        self.assertLess(block, layer.start())

    def testRigHitShading(self):
        """A hit: model to eye by the inverse modelview's transposed rotation
        (as the environment lookup does), the reflected ray's own view
        vector, the neutral response (#615 needs MaterialU), then the knee;
        and nothing reads a function constant."""
        self.assertIn('rt_rig_hit', self.rt_functions)
        sig, body = self.rt_functions['rt_rig_hit']
        code = squash(body)
        for expr in ('constfloat3x3toEye=transpose(float3x3(u.invModelview[0].xyz,'
                     'u.invModelview[1].xyz,u.invModelview[2].xyz));',
                     'constfloat3pEye=toEye*(pModel-u.invModelview[3].xyz);',
                     'constfloat3nEye=toEye*nModel;',
                     'constfloat3V=-normalize(toEye*R);',
                     'constLightTermst=light_terms_view(rig,base,nEye,pEye,V,'
                     'light_response_neutral());',
                     'returnlight_finish(shaded+base*t.diffuse+t.specular);'):
            self.assertIn(expr, code, expr)
        constant = re.compile(r'\bkRT\w+|\bkLightRig\b|function_constant')
        seen, todo = set(), ['rt_rig_hit']
        while todo:
            name = todo.pop()
            if name in seen:
                continue
            seen.add(name)
            self.assertNotRegex(self.rt_functions[name][1], constant, name)
            todo += [c for c in re.findall(r'\b((?:light|mat|rt)_\w+)\s*\(',
                                           self.rt_functions[name][1])
                     if c in self.rt_functions]
        self.assertLessEqual({'light_terms_view', 'light_finish', 'mat_soft_knee',
                              'light_response_neutral', 'light_visibility'}, seen)

    def testRTPipelines(self):
        code = strip_comments(self.mm)
        self.assertRegex(code, r'constexpr NSUInteger kRTLightRigConstantIndex = 1;')
        self.assertRegex(code, r'constexpr NSUInteger kRTLightRigBufferIndex = 13;')
        # every classic RT pipeline sets the constant, false, before it
        # specialises (both functions take the same values)
        build = cpp_function(self.mm, 'RendererMetal::buildRTPipelines')
        rig = re.search(r'bool\s+rig\s*=\s*false;\s*\[fc\s+setConstantValue:&rig\s+'
                        r'type:MTLDataTypeBool\s+atIndex:kRTLightRigConstantIndex\];', build)
        self.assertIsNotNone(rig)
        self.assertEqual(depth_at(build, rig.start()), 1)
        self.assertLess(rig.start(), build.index('constantValues:fc'))
        # the variant: the composite only, with true, the classic descriptor
        variant = cpp_function(self.mm, 'RendererMetal::buildRTRigComposite')
        self.assertRegex(variant, r'bool\s+rig\s*=\s*true;\s*\[fc\s+setConstantValue:&rig\s+'
                                  r'type:MTLDataTypeBool\s+atIndex:kRTLightRigConstantIndex\];')
        self.assertIn('newFunctionWithName:@"rt_composite" constantValues:fc', variant)
        self.assertNotIn('rt_ao', variant)
        self.assertIn('pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;',
                      variant)
        self.assertIn('pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;',
                      build)
        for released in ('[fc release];', '[pd release];', '[vtx release];', '[fco release];'):
            self.assertIn(released, variant)
        dtor = cpp_function(self.mm, 'RendererMetal::~RendererMetal')
        self.assertIn('[_rtResolvePipelineRig release];', dtor)
        self.assertIn('[_rtResolvePipelineTRig release];', dtor)

    def testRigCompositeChosenAndBoundOnlyWhenOn(self):
        code = strip_comments(self.mm)
        # one binding, under rtRig; one builder call, under the rig and a
        # reflective frame; one attempt per variant
        self.assertEqual(code.count('atIndex:kRTLightRigBufferIndex'), 1)
        self.assertEqual(len(re.findall(r'(?<!::)buildRTRigComposite\(', code)), 1)
        post = cpp_function(self.mm, 'RendererMetal::runPostChain')
        start = post.index('id<MTLRenderPipelineState> composite =')
        self.assertRegex(post[start:], r'^id<MTLRenderPipelineState> composite =\s*'
                                       r'doRTTrans \? _rtResolvePipelineT : _rtResolvePipeline;'
                                       r'\s*bool rtRig = false;')
        block = re.search(r'if\s*\(\s*_lightRigOn\s*&&\s*u\.matCount\s*>\s*0\.5f\s*\)\s*\{',
                          post)
        self.assertIsNotNone(block)
        end = match_brace(post, block.end() - 1)
        inside = post[block.end():end]
        self.assertIn('*tried = true;', inside)
        self.assertLess(inside.index('*tried = true;'), inside.index('buildRTRigComposite('))
        self.assertIn('rtRig = true;', inside)
        self.assertEqual(len(re.findall(r'rtRig\s*=\s*true', post)), 1)
        self.assertEqual(len(re.findall(r'\[er setRenderPipelineState:', post)), 1)
        self.assertIn('[er setRenderPipelineState:composite];', post)
        # which composite variant the rig path uses (613-R2-3): the transparent
        # or default pipeline slot, flag and builder argument all follow doRTTrans
        self.assertRegex(inside, r'rigComposite\s*=\s*doRTTrans \? &_rtResolvePipelineTRig'
                                 r' : &_rtResolvePipelineRig;')
        self.assertRegex(inside, r'tried\s*=\s*doRTTrans \? &_rtRigTTried : &_rtRigTried;')
        self.assertRegex(inside, r'\*rigComposite\s*=\s*buildRTRigComposite\(doRTTrans\);')
        builder = cpp_function(self.mm, 'RendererMetal::buildRTRigComposite')
        self.assertRegex(builder, r'bool t = transparent;\s*\[fc setConstantValue:&t '
                                  r'type:MTLDataTypeBool atIndex:0\];')
        bind = re.search(r'if\s*\(\s*rtRig\s*\)\s*\{[^}]*LightRigBlock block = _lightRigBlock;'
                         r'[^}]*setFragmentBytes:&block length:sizeof\(block\) '
                         r'atIndex:kRTLightRigBufferIndex\];\s*\}', post)
        self.assertIsNotNone(bind)
        self.assertLess(post.index('[er setRenderPipelineState:composite];'), bind.start())
        self.assertLess(bind.start(), post.index('[er drawPrimitives:', bind.start()))
