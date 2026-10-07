"""The studio response on the GPU (#615), from source.

#615 derives how each material takes a studio light from its MaterialParams
on the CPU (MaterialLightResponseFor, MaterialLightSharpness;
lighting_materials.py tests them through _cmd) and hands the result to the
Metal rig fragments in MaterialU. The shaders are MSL compiled at run time
(layerGraphics/metal/RendererMetal.mm) and CI has no GPU, so these checks pin
from the source what L1, the byte-identity renders against master, L2 and L3
prove on a Mac:

* TestLayout: the C++ and MSL MaterialU list the same fields in the same
  order, #615's eight floats appended after the 128 bytes before it (size
  160, lightDiffuse at 128, 16-byte aligned: Metal API validation aborts a
  draw whose bound buffer is shorter than the struct the function declares);
* TestBinding: bindMaterialU fills every light field from
  MaterialLightResponseFor and MaterialLightSharpness and lightClassic from
  its parameter; bindRepMaterial hands it the rig's shininess (head.y) only
  while the rig is on; the neutral bind keeps the defaults;
* TestLightResponse: light_response returns light_response_neutral() under
  the compile-time kMatFamily == 0 before it reads anything (what keeps
  `default` under a rig byte-identical), else exactly the five fields; it
  carries no per-material table; LightResponse, light_response_neutral,
  light_terms_view, every other #613 helper and the kRTSrc copies are
  master's;
* TestConstants: the shader constants layer1/Material.cpp mirrors equal
  their MSL twins, the material shaders use them by name where they used
  literals, and the C++ response reads them by name;
* TestClassicLight (Part 4): the material shaders' own classic light terms
  follow the rig's classic. kLightRig is declared once, at the top beside
  kMatFamily and before MaterialU; mat_classic_light (right after MaterialU)
  is kLightRig ? lightClassic : 1.0; it scales exactly glass's glints, jelly's
  wet pair and rubber's highlight, never an environment term or rubber's
  sheen; every mat_glass_shade call hands it over last; bindRepMaterial
  passes the rig's classic scale only while the rig is on;
  setLightClassicScale is a value copy SceneRenderMetal calls once, right
  after setLightRig.

Pure source parsing (skipped, not passed, outside a repo checkout; in a
checkout a missing source file fails).

    pymol -ckqy testing/testing.py --run testing/tests/raymol/lighting_material_msl.py
"""
import hashlib
import importlib.util
import os
import re
import struct

from pymol import testing

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, os.pardir, os.pardir, os.pardir))
METAL_MM = os.path.join(ROOT, 'layerGraphics', 'metal', 'RendererMetal.mm')
METAL_H = os.path.join(ROOT, 'layerGraphics', 'metal', 'RendererMetal.h')
RENDERER_H = os.path.join(ROOT, 'layerGraphics', 'Renderer.h')
SCENE_RENDER = os.path.join(ROOT, 'layer1', 'SceneRender.cpp')
MATERIAL_CPP = os.path.join(ROOT, 'layer1', 'Material.cpp')


def _load(name, filename):
    """A sibling test module's parsers, loaded by path under a private name
    so its test cases are not collected a second time."""
    spec = importlib.util.spec_from_file_location(
        name, os.path.join(HERE, filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


_msl = _load('_lighting_material_msl_parsers', 'lighting_msl.py')
_shadow = _load('_lighting_material_msl_shadow', 'lighting_shadow_msl.py')
_air = _load('_lighting_material_msl_air', 'lighting_air_msl.py')
shader_literals = _msl.shader_literals
strip_comments = _msl.strip_comments
msl_functions = _msl.msl_functions
cpp_function = _msl.cpp_function
squash = _msl.squash

# #615's fields, appended to MaterialU in this order.
LIGHT_FIELDS = ('lightDiffuse', 'lightHighlight', 'lightSharpness', 'lightTint',
                'lightWrap', 'lightClassic', '_pad3', '_pad4')
# The five LightResponse fields light_response reads, by MaterialU field.
RESPONSE_FIELDS = {'diffuse': 'lightDiffuse', 'highlight': 'lightHighlight',
                   'sharpness': 'lightSharpness', 'tint': 'lightTint',
                   'wrap': 'lightWrap'}
# Byte sizes of the MaterialU field types (C++ and MSL spellings).
TYPE_SIZES = {'simd_float4x4': 64, 'float4x4': 64, 'int': 4, 'float': 4}
# What each C++ type is in MSL.
MSL_TYPE = {'simd_float4x4': 'float4x4', 'int': 'int', 'float': 'float'}

# light_response's body, whitespace removed (comments are stripped first).
LIGHT_RESPONSE_BODY = (
    '{if(kMatFamily==0)returnlight_response_neutral();'
    'LightResponser;'
    'r.diffuse=mat.lightDiffuse;'
    'r.highlight=mat.lightHighlight;'
    'r.sharpness=mat.lightSharpness;'
    'r.tint=mat.lightTint;'
    'r.wrap=mat.lightWrap;'
    'returnr;}')

# Master f8251f227 (#615's base), with these parsers: struct LightResponse's
# braces and body, and kMaterialSrc's mat_soft_knee (signature, body),
# comments stripped and whitespace removed, first 16 hex digits of sha256.
MASTER_LIGHT_RESPONSE_STRUCT = 'a21a3fd677214d39'
MASTER_SOFT_KNEE = ('74cb65ae1e37a5c5', '532407fdae17cad5')
# light_response's signature is master's; only its body is #615's.
MASTER_LIGHT_RESPONSE_SIGNATURE = '0671125f88c96948'

# The constants layer1/Material.cpp mirrors, each with its MSL value: the
# names #613 had (glass's key glint and exponent, marble's wrap) and the ones
# #615 gave to literals that were already in the shaders.
MIRRORED = {
    'kMatGlassKeyGlint': 1.2,
    'kMatGlassGlintExp': 60.0,
    'kMatGlassFrostDim': 0.8,
    'kMatGlassFrostExpScale': 0.1,
    'kMatMarbleWrap': 0.35,
    'kMatJellyWetExp': 70.0,
    'kMatJellyWetTint': 0.25,
    'kMatJellyGlowWrap': 0.6,
    'kMatJellyGlowGain': 1.15,
    'kMatRubberHighlightExp': 8.0,
    'kMatRubberHighlightTint': 0.7,
}
# Where each named constant is used in the classic shaders (whitespace
# removed), and the literal it replaced, which must be gone from there.
USES = {
    'mat_glass_shade': (
        ('mix(kMatGlassGlintExp,kMatGlassGlintExp*kMatGlassFrostExpScale,'
         'saturate(rough));',
         'floatglint=(1.0-kMatGlassFrostDim*saturate(rough))*'),
        ('kMatGlassGlintExp*0.1', '(1.0-0.8*saturate(rough))')),
    'mat_jelly_shade': (
        ('reflectAmt*saturate((dot(N,L1)+kMatJellyGlowWrap)/(1.0+kMatJellyGlowWrap))',
         'direct*saturate((ndotv+kMatJellyGlowWrap)/(1.0+kMatJellyGlowWrap));',
         'saturate(base*kMatJellyGlowGain)*min(wrapLit,1.0);',
         'm.p[2]*pow(ndoth,kMatJellyWetExp)',
         'mix(float3(1.0),saturate(base*1.3),kMatJellyWetTint);'),
        ('/1.6', '+0.6)', 'base*1.15', 'pow(ndoth,70.0)', '1.3),0.25)')),
}
# Rubber's branch of mat_shade_procedural (it has no function of its own).
RUBBER_USES = ('pow(max(dot(N,H),0.0),kMatRubberHighlightExp)',
               'mix(float3(1.0),saturate(base*1.4),kMatRubberHighlightTint);')
RUBBER_LITERALS = ('pow(max(dot(N,H),0.0),8.0)', 'saturate(base*1.4),0.7)')

# Part 4: mat_classic_light, signature and body (whitespace removed).
CLASSIC_LIGHT_SIGNATURE = (
    '__attribute__((unused))staticfloatmat_classic_light(constantMaterialU&m)')
CLASSIC_LIGHT_BODY = '{returnkLightRig?m.lightClassic:1.0;}'
# The statements it scales, whole (whitespace removed), and the neighbouring
# ones it must not: environment terms and rubber's view-only sheen.
GLASS_GLINT = ('floatglint=(1.0-kMatGlassFrostDim*saturate(rough))*'
               '(kMatGlassKeyGlint*pow(ndoth1,expo)+'
               'kMatGlassHeadGlint*pow(ndotv,expo))*classic;')
GLASS_HI = ('hi=(room*F+float3(1.0-exp(-2.0*glint)))*'
            '(kMatGlassReflection*saturate(reflection));')
JELLY_WET = ('col+=(m.p[2]*pow(ndoth,kMatJellyWetExp)+0.12*pow(ndoth,8.0))'
             '*mat_classic_light(m)'
             '*mix(float3(1.0),saturate(base*1.3),kMatJellyWetTint);')
JELLY_ROOM = 'col+=room*F*0.8;'
RUBBER_SPEC = ('floatspec=m.p[2]*pow(max(dot(N,H),0.0),kMatRubberHighlightExp)*'
               '(n1>0.0?1.0:0.0)*mat_classic_light(m);')
RUBBER_SHEEN = 'floatsheen=m.p[3]*pow(1.0-saturate(N.z),3.0);'
# Every mat_glass_shade call, by library, with the MaterialU it hands over.
GLASS_CALLS = {'kMaterialImpostorSrc': ['m'], 'kVBOSrc': ['mat', 'mat'],
               'kSphereImpostorSrc': ['mat', 'mat'], 'kCylinderImpostorSrc': ['mat']}


def read(path):
    with open(path, encoding='utf-8') as handle:
        return handle.read()


def digest(text):
    return hashlib.sha256(squash(text).encode()).hexdigest()[:16]


def struct_fields(code, name):
    """[(type, name, count)] of `struct name { ... };` in comment-stripped
    `code` (the first definition)."""
    m = re.search(r'\bstruct\s+%s\s*\{(.*?)\};' % name, code, re.S)
    assert m, 'no struct %s' % name
    fields = []
    for decl in m.group(1).split(';'):
        decl = decl.strip()
        if not decl:
            continue
        f = re.fullmatch(r'(\w+)\s+(\w+)(?:\[(\d+)\])?', decl)
        assert f, 'unexpected MaterialU declaration %r' % decl
        fields.append((f.group(1), f.group(2), int(f.group(3) or 1)))
    return fields


def layout(fields):
    """{field: offset} and the size, every field 4-byte aligned after a
    leading 64-byte matrix (MaterialU's shape)."""
    offsets, at = {}, 0
    for type_, name, count in fields:
        offsets[name] = at
        at += TYPE_SIZES[type_] * count
    return offsets, at


def f32(x):
    return struct.unpack('f', struct.pack('f', x))[0]


class MaterialMSLCase(testing.PyMOLTestCase):

    def setUp(self):
        # Skipped (not passed) outside a checkout; in one, every source read
        # here is required. Both before the base setUp (see lighting_msl.py).
        if not os.path.isfile(METAL_MM):
            self.skipTest('%s not present; not a repo checkout' % METAL_MM)
        if not os.path.isfile(MATERIAL_CPP):
            self.fail('%s is missing from the checkout' % MATERIAL_CPP)
        super().setUp()
        self.mm = read(METAL_MM)
        self.code = strip_comments(self.mm)
        self.msl = shader_literals(self.mm)
        self.material = msl_functions(self.msl['kMaterialSrc'])
        self.material_code = strip_comments(self.msl['kMaterialSrc'])
        self.cpp = strip_comments(read(MATERIAL_CPP))

    def cpp_material_u(self):
        """The C++ MaterialU: the first definition in the file, before any
        shader literal."""
        first_literal = self.code.index('@R"')
        cpp = self.code[:first_literal]
        self.assertEqual(len(re.findall(r'\bstruct\s+MaterialU\s*\{', cpp)), 1)
        return struct_fields(cpp, 'MaterialU')


class TestLayout(MaterialMSLCase):

    def testFieldsMatchInOrder(self):
        cpp = self.cpp_material_u()
        msl = struct_fields(self.material_code, 'MaterialU')
        self.assertEqual([n for _t, n, _c in cpp], [n for _t, n, _c in msl])
        self.assertEqual([(MSL_TYPE[t], c) for t, _n, c in cpp],
                         [(t, c) for t, _n, c in msl])
        # #615's eight floats, at the end, in this order
        self.assertEqual(tuple(n for _t, n, _c in cpp[-8:]), LIGHT_FIELDS)
        for type_, name, count in cpp[-8:]:
            self.assertEqual((type_, count), ('float', 1), name)
        # the fields before them are the 128 bytes MaterialU had (#503, #588)
        self.assertEqual([n for _t, n, _c in cpp[:-8]],
                         ['invModelview', 'family', 'mode', 'wantsPeel', '_pad0',
                          'reflect', 'tint', 'rough', 'refrPx', 'p',
                          'refrOrtho', '_pad2'])

    def testSizeAndOffsets(self):
        for fields in (self.cpp_material_u(),
                       struct_fields(self.material_code, 'MaterialU')):
            offsets, size = layout(fields)
            self.assertEqual(size, 160)
            self.assertEqual(size % 16, 0)
            self.assertEqual(offsets['lightDiffuse'], 128)
        cpp = self.code[:self.code.index('@R"')]
        self.assertRegex(cpp, r'static_assert\(\s*sizeof\(MaterialU\)\s*==\s*160\s*,')
        self.assertRegex(cpp, r'static_assert\(\s*offsetof\(MaterialU,\s*'
                              r'lightDiffuse\)\s*==\s*128\s*,')
        self.assertRegex(cpp, r'static_assert\(\s*sizeof\(MaterialU\)\s*%\s*16'
                              r'\s*==\s*0\s*,')
        self.assertNotRegex(cpp, r'sizeof\(MaterialU\)\s*==\s*128')

    def testOneMaterialUInTheShaders(self):
        """Every lit library takes kMaterialSrc's MaterialU; none has its own
        copy that could keep the 128-byte layout."""
        for name, literal in self.msl.items():
            count = len(re.findall(r'\bstruct\s+MaterialU\s*\{',
                                   strip_comments(literal)))
            self.assertEqual(count, 1 if name == 'kMaterialSrc' else 0, name)


class TestBinding(MaterialMSLCase):

    def bind_material(self):
        m = re.search(r'void\s+bindMaterialU\s*\(([^)]*)\)\s*\{', self.code)
        self.assertIsNotNone(m)
        return squash(m.group(1)), cpp_function(self.mm, 'bindMaterialU')

    def testSignature(self):
        params, _body = self.bind_material()
        self.assertEqual(
            params,
            'id<MTLRenderCommandEncoder>enc,constMaterialParams&mp,'
            'constfloat*invModelview,floatrefrPx=0.0f,intrefrOrtho=0,'
            'floatshininess=0.0f,floatclassicScale=1.0f')

    def testFillsEveryLightField(self):
        _params, body = self.bind_material()
        body = squash(body)
        for stmt in ('constMaterialLightResponser=MaterialLightResponseFor(mp);',
                     'u.lightDiffuse=r.diffuse;',
                     'u.lightHighlight=r.highlight;',
                     'u.lightSharpness=MaterialLightSharpness(r.exponent,shininess);',
                     'u.lightTint=r.tint;',
                     'u.lightWrap=r.wrap;',
                     'u.lightClassic=classicScale;'):
            self.assertEqual(body.count(stmt), 1, stmt)
            # filled before the bytes are copied to the encoder
            self.assertLess(body.index(stmt), body.index('setFragmentBytes:&u'))
        # zero-initialised, so the padding is never stale memory
        self.assertIn('MaterialUu{};', body)
        for field in LIGHT_FIELDS[:6]:
            self.assertEqual(len(re.findall(r'\bu\.%s=' % field, body)), 1, field)
        for pad in LIGHT_FIELDS[6:]:
            self.assertNotIn('u.%s' % pad, body)

    def testCallers(self):
        """Only bindRepMaterial (every material draw) and the neutral bind
        (each encoder) fill MaterialU."""
        calls = [m.start() for m in re.finditer(r'(?<![\w:])bindMaterialU\s*\(',
                                                self.code)]
        # the definition, the neutral bind and bindRepMaterial
        self.assertEqual(len(calls), 3)
        rep = squash(cpp_function(self.mm, 'RendererMetal::bindRepMaterial'))
        self.assertEqual(rep.count('bindMaterialU('), 1)
        self.assertIn('bindMaterialU(_encoder,_repMatParams,_modelviewInv.data(),'
                      'refrPx,ortho,_lightRigOn?_lightRigBlock.head[1]:0.0f',
                      rep)
        neutral = squash(cpp_function(self.mm, 'bindNeutralMaterialU'))
        # defaults: shininess 0 (sharpness 1), classic 1, neutral params
        self.assertIn('bindMaterialU(enc,MaterialParams{},kIdentity4x4);', neutral)

    def testRigShininessIsHeadY(self):
        """head.y of the rig block is the shininess light_terms_view raises
        by sharpness, so sharpness * head.y is the material's exponent."""
        terms = squash(self.material['light_terms_view'][1])
        self.assertIn('constfloatshin=max(rig.head.y*r.sharpness,1.0);', terms)
        self.assertRegex(self.material_code,
                         r'struct\s+LightRigU\s*\{\s*float4\s+head;')


class TestLightResponse(MaterialMSLCase):

    def testBody(self):
        sig, body = self.material['light_response']
        self.assertEqual(digest(sig), MASTER_LIGHT_RESPONSE_SIGNATURE)
        self.assertRegex(sig, r'^\s*__attribute__\(\(unused\)\)\s+static\s')
        self.assertEqual(squash(body), LIGHT_RESPONSE_BODY)

    def testDefaultIsCompiledNeutralFirst(self):
        """The compile-time gate comes before any MaterialU read: default's
        rig pipelines fold to #613's neutral literals."""
        body = squash(self.material['light_response'][1])
        gate = body.index('if(kMatFamily==0)returnlight_response_neutral();')
        self.assertLess(gate, body.index('mat.'))
        self.assertEqual(gate, 1)

    def testReadsExactlyTheFiveFields(self):
        body = self.material['light_response'][1]
        read_fields = re.findall(r'\bmat\.(\w+)', body)
        self.assertEqual(sorted(read_fields), sorted(RESPONSE_FIELDS.values()))
        for field, source in RESPONSE_FIELDS.items():
            self.assertRegex(body, r'\br\.%s\s*=\s*mat\.%s\s*;' % (field, source))

    def testNoPerMaterialTable(self):
        """The core owns the response: no mode, family field, knob or table
        in the shader."""
        body = self.material['light_response'][1]
        for token in (r'\bswitch\b', r'\bmode\b', r'\bkMatMode_\w+',
                      r'\bmat\.(?!light)\w+', r'\[', r'\bkMat(?!Family\b)\w+',
                      r'\?', r'\bconstant\s+float\b'):
            self.assertNotRegex(body, token, token)
        # one if, one return each
        self.assertEqual(len(re.findall(r'\bif\s*\(', body)), 1)
        self.assertEqual(len(re.findall(r'\breturn\b', body)), 2)

    def testTheLightBlockCommentNamesTheException(self):
        """The light block says light_response reads kMatFamily (#615)."""
        literal = self.msl['kMaterialSrc']
        # (#615 moved kLightRig's declaration to the top: the block's comment
        # runs to its first struct)
        block = literal[literal.index('--- Studio light rig'):
                        literal.index('struct LightRigLight')]
        self.assertRegex(re.sub(r'\s*//\s*', ' ', block),
                         r'except light_response, which reads kMatFamily \(#615\)')

    def testThe613CodeIsMasters(self):
        """LightResponse, light_response_neutral, light_terms_view and every
        other #613 helper are master's: #615 changes only light_response."""
        material_struct = re.search(r'struct\s+LightResponse\s*(\{.*?\};)',
                                    self.material_code, re.S)
        self.assertEqual(digest(material_struct.group(1)),
                         MASTER_LIGHT_RESPONSE_STRUCT)
        helpers = [name for (lib, name) in _shadow.MASTER_613
                   if lib == 'kMaterialSrc']
        for name in ('light_response_neutral', 'light_terms_view',
                     'light_terms', 'light_apply', 'light_glass_glints'):
            self.assertIn(name, helpers)
        self.assertNotIn('light_response', helpers)
        for name in helpers:
            sig, body = self.material[name]
            self.assertEqual((digest(sig), digest(body)),
                             _shadow.MASTER_613[('kMaterialSrc', name)], name)
        knee_sig, knee_body = self.material['mat_soft_knee']
        self.assertEqual((digest(knee_sig), digest(knee_body)), MASTER_SOFT_KNEE)

    def testTheRayTracerIsUntouched(self):
        """kRTSrc keeps its #613 copies (and the neutral response) byte for
        byte: master's whole-literal digest, once #624's tone field in its
        LightRigU mirror is taken out (lighting_air_msl.py TONE_FIELD_624)."""
        rt_code = strip_comments(self.msl['kRTSrc'])
        self.assertEqual(len(_air.TONE_FIELD_624.findall(rt_code)), 1)
        self.assertEqual(digest(_air.TONE_FIELD_624.sub('', rt_code, count=1)),
                         _air.MASTER_LITERALS['kRTSrc'])
        rt = msl_functions(self.msl['kRTSrc'])
        self.assertNotIn('light_response', rt)
        self.assertNotRegex(strip_comments(self.msl['kRTSrc']), r'\bMaterialU\b')
        for name in ('light_response_neutral', 'light_terms_view'):
            self.assertEqual(squash(rt[name][1]), squash(self.material[name][1]))


class TestConstants(MaterialMSLCase):

    def msl_constants(self):
        return {m.group(1): float(m.group(2)) for m in re.finditer(
            r'^\s*constant\s+float\s+(kMat[A-Z]\w*)\s*=\s*([0-9.]+)\s*;',
            self.material_code, re.M)}

    def cpp_mirrors(self):
        return {m.group(1): float(m.group(2)) for m in re.finditer(
            r'^\s*constexpr\s+float\s+(kMat[A-Z]\w*)\s*=\s*([0-9.]+)f\s*;',
            self.cpp, re.M)}

    def testMirrorsEqualTheShader(self):
        msl = self.msl_constants()
        cpp = self.cpp_mirrors()
        self.assertEqual(cpp, MIRRORED)
        for name, value in MIRRORED.items():
            self.assertIn(name, msl, name)
            self.assertEqual(f32(msl[name]), f32(value), name)
        # declared once in the shaders
        for name in MIRRORED:
            self.assertEqual(len(re.findall(r'constant\s+float\s+%s\b' % name,
                                            self.material_code)), 1, name)

    def testTheClassicShadersUseTheNames(self):
        for function, (uses, literals) in USES.items():
            body = squash(self.material[function][1])
            for use in uses:
                self.assertIn(use, body, '%s: %s' % (function, use))
            for literal in literals:
                self.assertNotIn(literal, body, '%s: %s' % (function, literal))
        procedural = squash(self.material['mat_shade_procedural'][1])
        rubber = procedural[procedural.index('if(m.mode==kMatMode_rubber)'):
                            procedural.index('if(m.mode==kMatMode_clay)')]
        for use in RUBBER_USES:
            self.assertIn(use, rubber, use)
        for literal in RUBBER_LITERALS:
            self.assertNotIn(literal, rubber, literal)

    def testJellyDivisorIsTheOldLiteral(self):
        """(1.0 + kMatJellyGlowWrap) folds to exactly the 1.6 it replaced, so
        a classic jelly render cannot move."""
        self.assertEqual(f32(1.0 + f32(MIRRORED['kMatJellyGlowWrap'])), f32(1.6))

    def testTheResponseReadsThemByName(self):
        body = cpp_function(read(MATERIAL_CPP), 'MaterialLightResponseFor')
        for name in MIRRORED:
            self.assertRegex(body, r'\b%s\b' % name, name)
        # and types no shader number of its own
        for literal in ('1.2f', '60.0f', '0.35f', '70.0f', '0.25f', '0.6f',
                        '1.15f', '8.0f', '0.7f'):
            self.assertNotIn(literal, body, literal)


class TestClassicLight(MaterialMSLCase):
    """Part 4: the material shaders' own classic light terms (glass's glints,
    jelly's wet pair, rubber's highlight) follow the rig's classic."""

    def testDeclaredOnceBeforeMaterialU(self):
        code = self.material_code
        decls = [m.start() for m in re.finditer(
            r'constant\s+bool\s+kLightRig\s*\[\[\s*function_constant\(1\)\s*\]\]\s*;',
            code)]
        self.assertEqual(len(decls), 1)
        self.assertEqual(len(re.findall(r'\bkLightRig\s*\[\[', code)), 1)
        self.assertLess(code.index('constant int kMatFamily [[function_constant(0)]];'),
                        decls[0])
        self.assertLess(decls[0], code.index('struct MaterialU {'))
        # before every material function, the light block after them all
        self.assertLess(decls[0], min(code.index(sig) for name, (sig, _b)
                                      in self.material.items()
                                      if name.startswith('mat_')))

    def testMatClassicLight(self):
        self.assertIn('mat_classic_light', self.material)
        sig, body = self.material['mat_classic_light']
        self.assertEqual(squash(sig), CLASSIC_LIGHT_SIGNATURE)
        self.assertEqual(squash(body), CLASSIC_LIGHT_BODY)
        # right after struct MaterialU: the next thing defined after its `};`
        code = self.material_code
        struct_end = code.index('};', code.index('struct MaterialU {')) + 2
        self.assertEqual(code[struct_end:].lstrip().index(sig.strip()), 0)
        # defined only here
        for name, literal in self.msl.items():
            if name != 'kMaterialSrc':
                self.assertNotIn('mat_classic_light', msl_functions(literal), name)

    def testGlassGlints(self):
        sig, body = self.material['mat_glass_shade']
        # the last parameter, after `hi`
        self.assertRegex(squash(sig), r'threadfloat3&hi,floatclassic\)$')
        code = squash(body)
        self.assertEqual(code.count(GLASS_GLINT), 1)
        self.assertEqual(code.count(GLASS_HI), 1)
        # `classic` scales the glints and nothing else
        self.assertEqual(len(re.findall(r'\bclassic\b', body)), 1)
        self.assertNotIn('mat_classic_light', body)

    def testJellyWetPair(self):
        code = squash(self.material['mat_jelly_shade'][1])
        self.assertEqual(code.count('mat_classic_light('), 1)
        self.assertEqual(code.count(JELLY_WET), 1)
        self.assertEqual(code.count(JELLY_ROOM), 1)
        # the glow takes decision 15's already-scaled terms; nothing else here
        self.assertLess(code.index(JELLY_ROOM), code.index(JELLY_WET))

    def testRubberHighlightNotSheen(self):
        procedural = squash(self.material['mat_shade_procedural'][1])
        rubber = procedural[procedural.index('if(m.mode==kMatMode_rubber)'):
                            procedural.index('if(m.mode==kMatMode_clay)')]
        self.assertEqual(procedural.count('mat_classic_light('), 1)
        self.assertEqual(rubber.count(RUBBER_SPEC), 1)
        self.assertEqual(rubber.count(RUBBER_SHEEN), 1)

    def testScalesNothingElse(self):
        """In kMaterialSrc only jelly's and rubber's terms call it (glass
        takes it as a parameter); no environment helper sees it."""
        callers = sorted(name for name, (_sig, body) in self.material.items()
                         if re.search(r'\bmat_classic_light\s*\(', body))
        self.assertEqual(callers, ['mat_jelly_shade', 'mat_shade_procedural'])
        for name in ('mat_env_specular', 'mat_glass_cover', 'mat_soft_knee',
                     'mat_body_shade', 'mat_matte_shade'):
            if name in self.material:
                self.assertNotIn('classic', self.material[name][1], name)
        # the ray tracer has no MaterialU and no classic scale
        self.assertNotIn('mat_classic_light', self.msl['kRTSrc'])

    def testEveryGlassCallHandsItOver(self):
        found = {}
        for name, literal in self.msl.items():
            code = strip_comments(literal)
            for m in re.finditer(r'(?<![\w])mat_glass_shade\s*\(', code):
                close = _msl.match_paren(code, m.end() - 1)
                if re.match(r'\s*\{', code[close + 1:]):
                    continue                    # the definition
                args = squash(code[m.end():close])
                last = re.search(r',hi,mat_classic_light\((\w+)\)$', args)
                self.assertIsNotNone(last, '%s: %s' % (name, args))
                found.setdefault(name, []).append(last.group(1))
        self.assertEqual(found, GLASS_CALLS)
        self.assertEqual(sum(len(v) for v in found.values()), 6)

    def testBindRepMaterialPassesTheScale(self):
        rep = squash(cpp_function(self.mm, 'RendererMetal::bindRepMaterial'))
        self.assertEqual(rep.count('bindMaterialU('), 1)
        self.assertIn('bindMaterialU(_encoder,_repMatParams,_modelviewInv.data(),'
                      'refrPx,ortho,_lightRigOn?_lightRigBlock.head[1]:0.0f,'
                      '_lightRigOn?_lightClassicScale:1.0f);', rep)

    def testSetLightClassicScaleIsAValueCopy(self):
        body = squash(cpp_function(self.mm, 'RendererMetal::setLightClassicScale'))
        self.assertEqual(body, '{_lightClassicScale=scale;}')
        # read only by bindRepMaterial (under _lightRigOn), written only here;
        # beginFrame never resets it
        self.assertEqual(len(re.findall(r'\b_lightClassicScale\b', self.code)), 2)
        self.assertNotIn('_lightClassicScale',
                         cpp_function(self.mm, 'RendererMetal::beginFrame'))
        header = strip_comments(read(METAL_H))
        self.assertEqual(len(re.findall(r'\bfloat\s+_lightClassicScale\s*=\s*1\.0f\s*;',
                                        header)), 1)
        self.assertRegex(header, r'void\s+setLightClassicScale\(float\s+scale\)\s*'
                                 r'override\s*;')
        renderer = strip_comments(read(RENDERER_H))
        self.assertRegex(renderer, r'virtual\s+void\s+setLightClassicScale\('
                                   r'float\s*(?:/\*\s*scale\s*\*/)?\s*\)\s*\{\s*\}')

    def testSceneRenderHandsItOverOnceAfterTheRig(self):
        source = read(SCENE_RENDER)
        body = cpp_function(source, 'SceneRenderMetal')
        calls = re.findall(r'setLightClassicScale\(([^;]*)\);', body)
        self.assertEqual([squash(c) for c in calls], ['lights.classic.scale'])
        rig = re.search(r'G->Renderer->setLightRig\([^;]*\);\s*', body)
        self.assertIsNotNone(rig)
        # the very next statement
        self.assertTrue(body[rig.end():].startswith(
            'G->Renderer->setLightClassicScale(lights.classic.scale);'))
        self.assertLess(body.index('setLightClassicScale('),
                        body.index('SceneRenderAll('))
        self.assertEqual(strip_comments(source).count('setLightClassicScale('), 1)
