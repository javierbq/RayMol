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
  specialisation (kLightRig false) removes all of it;
* the specialisation always sets the constant, and the indices agree between
  C++ and MSL;
* the MSL LightRigU mirrors layer1/LightRigBlock.h;
* the rig is bound only while it is on, and rig pipelines are chosen only
  then;
* SceneRenderMetal reads the rig once per frame, before the shadow pre-pass.

Pure source parsing (skipped, not passed, outside a repo checkout).

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
           'light_terms', 'light_finish', 'light_outline', 'light_apply',
           'light_glass_glints')
STRUCTS = ('LightRigLight', 'LightRigU', 'LightResponse', 'LightTerms')

# Libraries whose lit fragments take the rig. The impostor libraries join
# when their rig paths do; until then none of their fragments may see it.
RIG_LIBRARIES = ('kVBOSrc',)
LIT_LIBRARIES = ('kVBOSrc', 'kSphereImpostorSrc', 'kCylinderImpostorSrc')
# The fragments of RIG_LIBRARIES that must take the rig, so the generic
# detection below cannot pass by finding nothing.
EXPECTED_RIG_FRAGMENTS = {
    'kVBOSrc': {'vbo_fragment', 'vbo_fragment_oit'},
}
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
                        r'\bkLightRig\b|\bLightResponse\b')
# Functions of RendererMetal.mm allowed to bind the rig.
BIND_CALLERS = {'bindRepMaterial'}


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


def remove_rig_statements(body):
    """`body` with every `if (kLightRig) { ... }` block and every
    `if (kLightRig) statement;` removed."""
    while True:
        m = RIG_GUARD.search(body)
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
        # an `else` after a guarded block would run the classic code only
        # with the rig off; nothing uses that form, so reject it outright
        if re.match(r'\s*else\b', body[end:]):
            raise AssertionError('`if (kLightRig) ... else` is not a form the '
                                 'rig statements use')
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


class LightMSLCase(testing.PyMOLTestCase):

    def setUp(self):
        super().setUp()
        for path in (METAL_MM, SCENE_RENDER, BLOCK_H, SHADING_H):
            if not os.path.isfile(path):
                # Skipped, not passed: a source test with no source checked
                # nothing. Only reached outside a repo checkout.
                self.skipTest('%s not present; not a repo checkout' % path)
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
        # ...and nowhere else
        for name, literal in self.msl.items():
            if name == 'kMaterialSrc':
                continue
            code = strip_comments(literal)
            self.assertNotRegex(code, r'\bkLightRig\s*\[\[', name)
            for struct in STRUCTS:
                self.assertNotRegex(code, r'\bstruct\s+%s\b' % struct, name)
            for fn in msl_functions(literal):
                self.assertFalse(fn.startswith('light_'),
                                 '%s defines %s' % (name, fn))

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
        terms = msl_functions(self.msl['kMaterialSrc'])['light_terms'][1]
        self.assertRegex(terms, r'max\(length\(Lv\),\s*1e-3\)')
        self.assertIn('dot(H, H) > 1e-8', terms)
        self.assertRegex(terms, r'misc\.y\s*>\s*0\.0')
        self.assertNotIn('smoothstep(', terms)   # a zero-width band divides by 0
        self.assertNotIn('normalize(-pEye)', terms)
        self.assertNotIn('normalize(nEye)', terms)

    def testOneKneeOnTheRigPath(self):
        functions = msl_functions(self.msl['kMaterialSrc'])
        self.assertIn('mat_soft_knee(', functions['light_finish'][1])
        apply_body = functions['light_apply'][1]
        self.assertIn('light_finish(', apply_body)
        self.assertIn('light_outline(', apply_body)
        self.assertIn('light_terms(', apply_body)
        self.assertNotIn('mat_soft_knee', apply_body)
        self.assertNotIn('mat_soft_knee', functions['light_terms'][1])


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
                    # shadow, peel, unlit, cap and coverage fragments (and the
                    # impostors until their rig paths land) never see it
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


class TestLayout(LightMSLCase):

    def testLayoutMirrors(self):
        material = strip_comments(self.msl['kMaterialSrc'])
        light = re.search(r'struct LightRigLight\s*\{(.*?)\};', material, re.S)
        rig = re.search(r'struct LightRigU\s*\{(.*?)\};', material, re.S)
        light_fields = re.findall(r'(\w+)\s+(\w+)\s*;', light.group(1))
        self.assertEqual(light_fields, [('float4', 'pos'), ('float4', 'axis'),
                                        ('float4', 'radiance'), ('float4', 'misc')])
        rig_fields = re.findall(r'(\w+)\s+(\w+)(?:\[(\d+)\])?\s*;', rig.group(1))
        self.assertEqual(rig_fields, [('float4', 'head', ''),
                                      ('LightRigLight', 'L', '6')])
        size = 16 + int(rig_fields[1][2]) * 16 * len(light_fields)
        self.assertEqual(size, 400)
        header = strip_comments(read(BLOCK_H))
        cpp_light = re.search(r'struct LightRigBlockLight\s*\{(.*?)\};', header, re.S)
        cpp_rig = re.search(r'struct LightRigBlock\s*\{(.*?)\};', header, re.S)
        self.assertEqual(re.findall(r'float\s+(\w+)\[4\];', cpp_light.group(1)),
                         [name for _, name in light_fields])
        self.assertEqual(re.findall(r'float\s+(\w+)\[4\];', cpp_rig.group(1)),
                         ['head'])
        slots = re.search(r'kLightRigBlockSlots\s*=\s*(\d+);', header).group(1)
        self.assertEqual(slots, rig_fields[1][2])
        self.assertRegex(header, r'sizeof\(LightRigBlock\)\s*==\s*%d' % size)
        # the rig model's light limit is the block's
        self.assertRegex(strip_comments(read(SHADING_H)),
                         r'static_assert\(kLightRigMaxLights\s*==\s*'
                         r'kLightRigBlockSlots')
        # the loops cover every slot and stop at the count
        for helper in ('light_terms', 'light_outline'):
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
