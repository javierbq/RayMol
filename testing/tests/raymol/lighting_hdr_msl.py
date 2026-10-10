"""HDR colour for the light rig (#624) in the Metal shaders and their
specialisation, read from source.

D1 (plans/624.md): HDR lives in the rig shaders. A rig fragment keeps its
light in scene units, multiplies it by the exposure (the rig block's tone.x)
and maps it once through the tone curve T before the 8-bit store; glass
composes body and glints in scene units first (light_glass_cover); the air
adds its light in scene units over T's inverse. One function constant,
kLightHdr (kMaterialSrc index 3, kRTSrc index 2), chooses it per pipeline;
false keeps every two-arm helper's 8-bit knee, the rig as it was before
#624. CI has no GPU, so these checks pin from the source what L1, L1b (the
regression renders against master) and L3 prove on a Mac:

* TestConstants: kLightHdr is declared once in kMaterialSrc at index 3 and
  once in kRTSrc at index 2, and nowhere else; the C++ indices agree; the
  tone constants equal layer1/LightTone.h in both libraries; kRTSrc's copies
  of the tone helpers and light_finish are kMaterialSrc's verbatim;
* TestShaders: light_finish, light_glass_glints, light_glass_cover and the
  tone helpers have exactly the planned bodies (the tone helpers mirror
  LightTone.cpp operation for operation); light_apply, light_apply_shadowed,
  the sphere glass helpers and rt_rig_hit hand light_finish the exposure;
  the rig glass covers choose light_glass_cover only under
  `kLightRig && kLightHdr`; post_air_finish has its two arms and both air
  composites pass the exposure (the upsample takes the rig at buffer(1));
  under kLightHdr no rig helper reaches the 8-bit knee (mat_soft_knee) or
  mat_glass_cover;
* TestMasterUnchanged: every shader literal is master 054b525e9's (sha256 of
  the comment-stripped, whitespace-free text, taken from master with these
  parsers) once #624's edits are put back (lighting_air_msl.py
  without_hdr_624), and each edit applies exactly where this allowlist says;
  the material laws (mat_soft_knee, mat_glass_cover, mat_glass_shade,
  mat_env_specular, mat_jelly_shade) are master's;
* TestSpecialisers: every specialiser of a function that can reach the light
  helpers sets kLightHdr's index (materialFragmentFunction to
  `lightRig && lightHdr`; bezierTubeRigFunction and airFunction to their
  builder's choice; buildRTPipelines false and buildRTRigComposite its
  caller's choice), no function fetched unspecialised reaches kLightHdr, and
  only the rig builders ask for it, each with the frame's hdr choice;
* TestCaches (Parts 4-5): every rig cache keys on hdr (the VBO rig functions
  and tried flags [hdr][family], the cachedVBOPipeline key with an hdr bit
  mixed only when true, the sphere rig and rig-shadow sets [hdr][family]
  with a flag per set, the cylinder tuple's 6th bool, the tube's two
  pipelines from one library compile under one tried flag; Part 5: the RT
  rig composites [transparent][hdr] with a tried flag each, from the
  retained _rtLib, and the air's two composites in both variants from its
  one compile in its one attempt, the march single), each draw or pass asks
  for this frame's variant (_lightHdrOn), and each release frees both
  variants;
* TestFrame (Parts 4-5): setLightRig derives _lightHdrOn from the block's
  tone[1] while the rig is on, beginFrame clears it, nothing else writes it,
  and only the rig draws, the air and runPostChain read it; runPostChain is
  master's once postExposure and the RT rig composite choice are put back
  (exposure 1 in an HDR rig frame); SceneLightsFrame is master's once the
  one tone statement is taken out;
* TestBlock: pymol::LightRigBlock is 688 bytes with the tone last, and both
  MSL LightRigU copies end with it.

Pure source parsing (skipped, not passed, outside a repo checkout; in a
checkout a missing source file fails).

    pymol -ckqy testing/testing.py --run testing/tests/raymol/lighting_hdr_msl.py
"""
import importlib.util
import os
import re

from pymol import testing

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, os.pardir, os.pardir, os.pardir))
METAL_MM = os.path.join(ROOT, 'layerGraphics', 'metal', 'RendererMetal.mm')
METAL_H = os.path.join(ROOT, 'layerGraphics', 'metal', 'RendererMetal.h')
TONE_H = os.path.join(ROOT, 'layer1', 'LightTone.h')
TONE_CPP = os.path.join(ROOT, 'layer1', 'LightTone.cpp')
BLOCK_H = os.path.join(ROOT, 'layer1', 'LightRigBlock.h')


def _load(name, filename):
    """A sibling test module's helpers, loaded by path under a private name
    so its test cases are not collected a second time."""
    spec = importlib.util.spec_from_file_location(
        name, os.path.join(HERE, filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


_msl = _load('_lighting_hdr_msl_parsers', 'lighting_msl.py')
_air = _load('_lighting_hdr_msl_air', 'lighting_air_msl.py')
shader_literals = _msl.shader_literals
strip_comments = _msl.strip_comments
msl_functions = _msl.msl_functions
fragments = _msl.fragments
cpp_function = _msl.cpp_function
remove_rig_statements = _msl.remove_rig_statements
squash = _msl.squash
depth_at = _msl.depth_at
digest = _air.digest
without_hdr_624 = _air.without_hdr_624

TONE_HELPERS = _msl.TONE_HELPERS
HDR_CONSTANT = re.compile(r'\bkLightHdr\b')

# Master 054b525e9 (#615's merge, this branch's base): sha256 of each shader
# literal, comments stripped and whitespace removed, the first 16 hex digits.
# Taken from master with these parsers, never from this branch.
MASTER_054B525 = {
    'kAirSrc': 'bb28757fec4568af',
    'kBezierTubeRigSrc': 'c15ddac6015e66dc',
    'kBezierTubeSrc': '0085bdbf88964ab4',
    'kConnectorShaderSrc': '40ef57a0e535d985',
    'kCylinderImpostorSrc': '43f9c76b791ece1d',
    'kEyeReconSrc': '34e775c149c8b075',
    'kLabelShaderSrc': 'e9739e2374962609',
    'kMaterialImpostorSrc': 'ad8142cda60dc979',
    'kMaterialSrc': '4f4f1e7f4c703bad',
    'kPostSrc': 'c13f90740b5420b8',
    'kRTSrc': 'c3f2065ac121a166',
    'kSphereImpostorSrc': 'd4db196a0bab087c',
    'kVBOSrc': '834ce9f8e90f5832',
}
# The same digests (signature, body) of the material laws #624 leaves alone,
# on master 054b525e9.
MASTER_LAWS = {
    'mat_soft_knee': ('74cb65ae1e37a5c5', '532407fdae17cad5'),
    'mat_glass_cover': ('0b2202961d7fabe3', 'f267a4ccd591fb9e'),
    'mat_glass_shade': ('3a63f86596630e16', '665872d4636070ea'),
    'mat_env_specular': ('90db4c60a2451436', '7e5f92848d45ef5f'),
    'mat_jelly_shade': ('9046ca7a8083ec47', '1a8176fe37f54771'),
}
# The allowlist: how many times each of #624's edits (lighting_air_msl.py
# HDR_EDITS_624; the new functions and declarations) applies in each literal.
# A literal not named here has none.
EDIT_COUNTS = {
    'kMaterialSrc': {'functions': 5, 'declarations': 3, 'finish_signature': 1,
                     'finish_body': 1, 'apply_exposure': 2, 'glints_body': 1},
    'kRTSrc': {'functions': 4, 'declarations': 3, 'finish_signature': 1,
               'finish_body': 1, 'hit_exposure': 1},
    'kVBOSrc': {'vbo_cover': 1},
    'kCylinderImpostorSrc': {'cyl_cover': 1},
    'kSphereImpostorSrc': {'sphere_glass': 2},
    'kAirSrc': {'air_signature': 1, 'air_body': 1, 'air_full': 1,
                'air_upsample': 1, 'air_upsample_rig': 1,
                'alpha_functions': 2},   # #684: post_air_alpha, post_air_alpha_merge
}
UNTOUCHED = ('kPostSrc', 'kEyeReconSrc', 'kBezierTubeSrc', 'kBezierTubeRigSrc',
             'kLabelShaderSrc', 'kConnectorShaderSrc', 'kMaterialImpostorSrc')

# The planned bodies (whitespace removed).
LIGHT_FINISH = ('__attribute__((unused))staticfloat3light_finish(float3c,floatexposure)',
                '{if(kLightHdr)returnlight_tone(c*exposure);returnmat_soft_knee(c);}')
GLINTS_BODY = '{if(kLightHdr)return2.0*s;returnfloat3(1.0)-exp(-2.0*s);}'
GLASS_COVER = (
    '__attribute__((unused))staticfloat4light_glass_cover(float3body,float3hi,'
    'floata,floate)',
    '{constfloath=light_tone_scalar(e*max(hi.r,max(hi.g,hi.b)));'
    'constfloatcover=saturate(a+(1.0-a)*h);'
    'constfloat3S=(body*a+hi)/max(cover,1e-4);'
    'returnfloat4(light_tone(e*S),cover);}')
TONE_BODY = ('{if(!all(isfinite(c)))returnfloat3(0.0);c=max(c,float3(0.0));'
             'constfloatm=max(c.r,max(c.g,c.b));if(m<=kLightToneKnee)returnc;'
             'returnc*light_tone_scalar(m)/m;}')
TONE_INVERSE_BODY = ('{if(!all(isfinite(c)))returnfloat3(0.0);'
                     'c=clamp(c,float3(0.0),float3(1.0));'
                     'constfloatm=max(c.r,max(c.g,c.b));if(m<=kLightToneKnee)returnc;'
                     'returnc*light_tone_scalar_inverse(m)/m;}')
AIR_FINISH = (
    'staticfloat3post_air_finish(float3c,float3a,floate)',
    '{if(kLightHdr){constfloat3add=all(isfinite(a))?max(a,float3(0.0))*e:float3(0.0);'
    'returnmax(saturate(c),light_tone(light_tone_inverse(saturate(c))+add));}'
    'returnc+max(mat_soft_knee(c+a)-mat_soft_knee(c),float3(0.0));}')

# The specialisers that set kMaterialSrc's constants, and the RT builders.
MATERIAL_SPECIALISERS = ('RendererMetal::materialFragmentFunction',
                         'bezierTubeRigFunction', 'airFunction')
RT_SPECIALISERS = ('RendererMetal::buildRTPipelines',
                   'RendererMetal::buildRTRigComposite')
# The libraries built with kMaterialSrc (and kMaterialImpostorSrc for the
# impostors): their functions can reach the light helpers.
MATERIAL_LIBRARIES = ('kVBOSrc', 'kSphereImpostorSrc', 'kCylinderImpostorSrc',
                      'kBezierTubeSrc', 'kBezierTubeRigSrc', 'kAirSrc')


def read(path):
    with open(path, encoding='utf-8') as handle:
        return handle.read()


def cpp_float(text, name):
    """`inline constexpr float <name> = <x>f;` in a header, as a float."""
    m = re.search(r'inline\s+constexpr\s+float\s+%s\s*=\s*([0-9.]+)f\s*;' % name,
                  strip_comments(text))
    return float(m.group(1)) if m else None


def msl_float(code, name):
    m = re.search(r'constant\s+float\s+%s\s*=\s*([0-9.]+)\s*;' % name, code)
    return float(m.group(1)) if m else None


def cpp_like_msl(text):
    """C++ statements written as the MSL copies write them: no std::, no f
    suffix on float literals, no whitespace."""
    text = re.sub(r'\bstd::', '', text)
    text = re.sub(r'(\d+\.\d+)f\b', r'\1', text)
    return squash(text)


def reaches(table, start, pattern):
    """The functions of `table` reachable from `start` (itself included)
    whose body matches `pattern`."""
    seen, todo, found = set(), [start], set()
    while todo:
        name = todo.pop()
        if name in seen or name not in table:
            continue
        seen.add(name)
        body = table[name][1]
        if pattern.search(body):
            found.add(name)
        todo += re.findall(r'\b(\w+)\s*\(', body)
    return found


def hdr_view(body):
    """A function body (comments stripped) as kLightHdr true compiles it:
    `if (kLightHdr) return X;` or `if (kLightHdr) { ... }` at the top keeps
    only that arm, and `if (kLightRig && kLightHdr) A else B` keeps A.
    Whitespace is kept, so word boundaries still separate the calls."""
    body = re.sub(r'^\{\s*if\s*\(\s*kLightHdr\s*\)\s*(return[^;]*;).*\}$', r'{\1}',
                  body, flags=re.S)
    body = re.sub(r'^\{\s*if\s*\(\s*kLightHdr\s*\)\s*(\{[^{}]*\}).*\}$', r'{\1}',
                  body, flags=re.S)
    body = re.sub(r'if\s*\(\s*kLightRig\s*&&\s*kLightHdr\s*\)\s*(\w+\s*=[^;]*;)'
                  r'\s*else\s*\w+\s*=[^;]*;', r'\1', body)
    return body


class HdrMSLCase(testing.PyMOLTestCase):

    def setUp(self):
        # As lighting_msl.py: skipped outside a checkout (decided by
        # RendererMetal.mm alone), and before the base setUp.
        if not os.path.isfile(METAL_MM):
            self.skipTest('%s not present; not a repo checkout' % METAL_MM)
        for path in (METAL_H, TONE_H, TONE_CPP, BLOCK_H):
            if not os.path.isfile(path):
                self.fail('%s is missing from the checkout' % path)
        super().setUp()
        self.mm = read(METAL_MM)
        self.code = strip_comments(self.mm)
        self.header = strip_comments(read(METAL_H))
        self.msl = shader_literals(self.mm)
        self.material = msl_functions(self.msl['kMaterialSrc'])
        self.rt = msl_functions(self.msl['kRTSrc'])
        self.air = msl_functions(self.msl['kAirSrc'])

    def fn(self, table, name):
        self.assertIn(name, table, name)
        sig, body = table[name]
        return squash(sig), squash(body)


class TestConstants(HdrMSLCase):

    def testDeclaredOnceAtItsIndex(self):
        material = strip_comments(self.msl['kMaterialSrc'])
        rt = strip_comments(self.msl['kRTSrc'])
        self.assertEqual(re.findall(r'constant\s+bool\s+kLightHdr\s*\[\[\s*'
                                    r'function_constant\((\d+)\)\s*\]\]\s*;', material),
                         ['3'])
        self.assertEqual(re.findall(r'constant\s+bool\s+kLightHdr\s*\[\[\s*'
                                    r'function_constant\((\d+)\)\s*\]\]\s*;', rt),
                         ['2'])
        # each index is kLightHdr's alone in its library
        for code, index in ((material, '3'), (rt, '2')):
            owners = re.findall(r'(\w+)\s*\[\[\s*function_constant\(%s\)' % index, code)
            self.assertEqual(owners, ['kLightHdr'])
        # declared after the rig's structs (the light block) and before its
        # first reader, light_finish
        self.assertLess(material.index('struct LightRigU {'),
                        material.index('kLightHdr [[function_constant(3)]]'))
        self.assertLess(material.index('kLightHdr [[function_constant(3)]]'),
                        material.index(self.material['light_finish'][0].strip()))
        # nowhere else: every other literal reads kMaterialSrc's (or none)
        for name, literal in self.msl.items():
            if name in ('kMaterialSrc', 'kRTSrc'):
                continue
            self.assertNotRegex(strip_comments(literal), r'\bkLightHdr\s*\[\[', name)
        # the C++ indices
        self.assertRegex(self.code, r'constexpr NSUInteger kLightHdrConstantIndex = 3;')
        self.assertRegex(self.code, r'constexpr NSUInteger kRTLightHdrConstantIndex = 2;')
        self.assertEqual(len(re.findall(r'\bkLightHdrConstantIndex\s*=', self.code)), 1)
        self.assertEqual(len(re.findall(r'\bkRTLightHdrConstantIndex\s*=', self.code)), 1)

    def testToneConstantsAreLightTones(self):
        tone_h = read(TONE_H)
        knee = cpp_float(tone_h, 'kLightToneKnee')
        white = cpp_float(tone_h, 'kLightToneWhite')
        self.assertIsNotNone(knee)
        self.assertIsNotNone(white)
        for lib in ('kMaterialSrc', 'kRTSrc'):
            code = strip_comments(self.msl[lib])
            self.assertEqual(msl_float(code, 'kLightToneKnee'), knee, lib)
            self.assertEqual(msl_float(code, 'kLightToneWhite'), white, lib)
            self.assertEqual(len(re.findall(r'constant\s+float\s+kLightTone\w+', code)), 2)
        # within the tuning range D2 allows
        self.assertTrue(0.5 <= knee <= 0.8, knee)
        self.assertTrue(6.0 <= white <= 16.0, white)

    def testRTCopiesAreVerbatim(self):
        attribute = re.compile(r'__attribute__\(\(unused\)\)')
        for name in TONE_HELPERS + ('light_finish',):
            sig, body = self.fn(self.rt, name)
            msig, mbody = self.fn(self.material, name)
            self.assertEqual(attribute.sub('', sig), attribute.sub('', msig), name)
            self.assertEqual(body, mbody, name)
        # no glass helper in the ray tracer (it shades no glass with the rig)
        self.assertNotIn('light_glass_cover', self.rt)
        self.assertNotIn('light_glass_glints', self.rt)


class TestShaders(HdrMSLCase):

    def testLightFinish(self):
        self.assertEqual(self.fn(self.material, 'light_finish'), LIGHT_FINISH)
        self.assertEqual(self.fn(self.rt, 'light_finish')[1], LIGHT_FINISH[1])

    def testToneHelpersMirrorLightTone(self):
        """Operation for operation LightTone.cpp's, in float: the same
        statements after the NaN rule, and the rescale multiplies first."""
        cpp = read(TONE_CPP)
        for msl_name, cpp_name, first in (
                ('light_tone_scalar', 'LightToneScalar', 'if(m<=kLightToneKnee)'),
                ('light_tone_scalar_inverse', 'LightToneScalarInverse',
                 'if(y<=kLightToneKnee)')):
            _, body = self.fn(self.material, msl_name)
            want = cpp_like_msl(cpp_function(cpp, cpp_name))
            self.assertIn(first, want)
            self.assertEqual(body[body.index(first):], want[want.index(first):],
                             msl_name)
            # the NaN rule: non-finite and negative read as 0
            var = first[3]
            self.assertTrue(body.startswith('{%s=(isfinite(%s)&&%s>0.0)?%s:0.0;'
                                            % ((var,) * 4)), msl_name)
        self.assertEqual(self.fn(self.material, 'light_tone')[1], TONE_BODY)
        self.assertEqual(self.fn(self.material, 'light_tone_inverse')[1],
                         TONE_INVERSE_BODY)
        # LightToneRescale: c * y / m, channel by channel, as the MSL's
        # c * T1(m) / m
        rescale = squash(cpp_function(cpp, 'LightToneRescale'))
        self.assertIn('c[0]*y/m,c[1]*y/m,c[2]*y/m', rescale)
        for name in TONE_HELPERS:
            sig, _ = self.material[name]
            self.assertRegex(sig, r'^\s*__attribute__\(\(unused\)\)\s+static\s', name)
            # no pow (exact at the knee; no NaN from a negative base)
            self.assertNotIn('pow(', self.material[name][1], name)

    def testExposureReachesLightFinish(self):
        for name in ('light_apply', 'light_apply_shadowed'):
            _, body = self.fn(self.material, name)
            self.assertIn('light_outline(light_finish(rgb+base*t.diffuse+t.specular,'
                          'rig.tone.x),pEye,rig);', body, name)
        _, hit = self.fn(self.rt, 'rt_rig_hit')
        self.assertIn('returnlight_finish(shaded+base*t.diffuse+t.specular,'
                      'rig.tone.x);', hit)
        sphere = msl_functions(self.msl['kSphereImpostorSrc'])
        for name in ('sphere_glass_rig', 'sphere_glass_rig_shadowed'):
            _, body = self.fn(sphere, name)
            self.assertTrue(body.endswith(
                'returnlight_outline(light_finish(body+hi,rig.tone.x),pt,rig);}'), name)
            self.assertNotIn('mat_soft_knee', body, name)
        # every light_finish call in every library passes the exposure
        for lib, literal in self.msl.items():
            code = squash(strip_comments(literal))
            for m in re.finditer(r'light_finish\(', code):
                if code[:m.start()].endswith('float3'):
                    continue   # the definition
                close = _msl.match_paren(code, m.end() - 1)
                self.assertTrue(code[:close].endswith(',rig.tone.x'),
                                '%s: %s' % (lib, code[m.start():close + 1]))

    def testGlass(self):
        self.assertEqual(self.fn(self.material, 'light_glass_glints')[1], GLINTS_BODY)
        self.assertEqual(self.fn(self.material, 'light_glass_cover'), GLASS_COVER)
        # the rig glass covers: light_glass_cover only under kLightRig &&
        # kLightHdr, at the frame's exposure; mat_glass_cover otherwise; the
        # outline after either
        vbo = squash(fragments(self.msl['kVBOSrc'])['vbo_fragment_oit'][1])
        self.assertIn('if(kLightRig&&kLightHdr)c=light_glass_cover(body,hi,in.color.a,'
                      'rig.tone.x);elsec=mat_glass_cover(body,hi,in.color.a);'
                      'if(kLightRig)c.rgb=light_outline(c.rgb,in.posEye,rig);', vbo)
        cyl = squash(fragments(self.msl['kCylinderImpostorSrc'])
                     ['cyl_impostor_fragment_oit'][1])
        self.assertIn('float4g;if(kLightRig&&kLightHdr)g=light_glass_cover(body,hi,a,'
                      'rig.tone.x);elseg=mat_glass_cover(body,hi,a);rgb=g.rgb;'
                      'if(kLightRig)rgb=light_outline(rgb,pt,rig);', cyl)
        for lib in self.msl:
            code = squash(strip_comments(self.msl[lib]))
            calls = len(re.findall(r'(?<!static)(?<!float4)light_glass_cover\(', code))
            self.assertEqual(calls, {'kVBOSrc': 1, 'kCylinderImpostorSrc': 1}.get(lib, 0),
                             lib)
        # the classic glints' own curve (mat_glass_shade) is a material law
        _, shade = self.fn(self.material, 'mat_glass_shade')
        self.assertIn('1.0-exp(-2.0*glint)', shade)

    def testAir(self):
        self.assertEqual(self.fn(self.air, 'post_air_finish'), AIR_FINISH)
        sig, full = self.fn(self.air, 'post_air_full')
        self.assertIn('returnfloat4(post_air_finish(c.rgb,t.rgb,rig.tone.x),c.a);', full)
        sig, upsample = self.fn(self.air, 'post_air_upsample')
        self.assertIn('constantLightAirU&air[[buffer(0)]],'
                      'constantLightRigU&rig[[buffer(1)]])', sig)
        self.assertIn('returnfloat4(post_air_finish(c.rgb,a,rig.tone.x),c.a);', upsample)
        # the rig block's index in the air library, bound to every air pass
        self.assertRegex(self.code, r'constexpr NSUInteger kAirRigBufferIndex = 1;')
        encode = cpp_function(self.mm, 'RendererMetal::encodeAirPass')
        self.assertIn('[e setFragmentBytes:&rig length:sizeof(rig) '
                      'atIndex:kAirRigBufferIndex];', encode)
        self.assertEqual(encode.count('bindAir(e'), 2)
        # the march adds nothing and reads no constant: it stays plain
        self.assertFalse(reaches(dict(self.material, **self.air), 'post_air_march',
                                 HDR_CONSTANT))

    def testNoKneeUnderHdr(self):
        """kLightHdr true: no rig helper, air composite or traced hit reaches
        the 8-bit knee or mat_glass_cover; they remain only in the false
        arms (whose text TestMasterUnchanged proves is master's)."""
        tables = (
            (self.material, [n for n in self.material if n.startswith('light_')]),
            (dict(self.material, **self.air), ['post_air_full', 'post_air_upsample',
                                               'post_air_finish']),
            (self.rt, ['rt_rig_hit']),
            (dict(self.material, **msl_functions(self.msl['kSphereImpostorSrc'])),
             ['sphere_glass_rig', 'sphere_glass_rig_shadowed']),
        )
        knee = re.compile(r'\bmat_soft_knee\(|\bmat_glass_cover\(')
        for table, roots in tables:
            for root in roots:
                seen, todo = set(), [root]
                while todo:
                    name = todo.pop()
                    if name in seen:
                        continue
                    seen.add(name)
                    body = hdr_view(table[name][1])
                    self.assertNotRegex(body, knee, '%s (from %s)' % (name, root))
                    todo += [c for c in re.findall(r'\b((?:light|post_air|rt)_\w+)\s*\(',
                                                   body)
                             if c in table]
                # the walk follows the HDR arms down to T
                if root in ('light_apply', 'light_apply_shadowed', 'post_air_full',
                            'post_air_upsample', 'rt_rig_hit', 'sphere_glass_rig',
                            'sphere_glass_rig_shadowed'):
                    self.assertIn('light_tone', seen, root)
        # ...and the false arms do reach them
        self.assertIn('mat_soft_knee', reaches(self.material, 'light_finish',
                                               re.compile(r'\bknee\b')))
        for lib, frag in (('kVBOSrc', 'vbo_fragment_oit'),
                          ('kCylinderImpostorSrc', 'cyl_impostor_fragment_oit')):
            body = fragments(self.msl[lib])[frag][1]
            self.assertIn('light_glass_cover(', hdr_view(body))
            self.assertNotIn('mat_glass_cover(', hdr_view(body))
            self.assertIn('mat_glass_cover(', squash(remove_rig_statements(
                fragments(self.msl[lib])[frag][1])))


class TestMasterUnchanged(HdrMSLCase):

    def testEveryLiteralIsMastersWithoutHdr(self):
        self.assertEqual(set(self.msl), set(MASTER_054B525))
        for name, want in sorted(MASTER_054B525.items()):
            code = strip_comments(self.msl[name])
            if name in _air.TONE_FIELD_LITERALS:
                # Part 2's tone field (lighting_air_msl.py TONE_FIELD_624)
                self.assertEqual(len(_air.TONE_FIELD_624.findall(code)), 1, name)
                code = _air.TONE_FIELD_624.sub('', code, count=1)
            text, counts = without_hdr_624(code)
            self.assertEqual({k: v for k, v in counts.items() if v},
                             EDIT_COUNTS.get(name, {}), name)
            self.assertEqual(digest(text), want, name)
        for name in UNTOUCHED:
            self.assertNotIn(name, EDIT_COUNTS)

    def testMaterialLawsAreMasters(self):
        for name, want in MASTER_LAWS.items():
            sig, body = self.material[name]
            self.assertEqual((digest(sig), digest(body)), want, name)


class TestSpecialisers(HdrMSLCase):

    def setting(self, body, index):
        """The variable set at `index` and its value statement."""
        m = re.search(r'bool (\w+) = ([^;]*);\s*\[(?:cv|fc) setConstantValue:&\1 '
                      r'type:MTLDataTypeBool atIndex:%s\];' % index, body)
        self.assertIsNotNone(m, index)
        self.assertEqual(depth_at(body, m.start()), 1)
        self.assertLess(m.start(), body.index('constantValues:'))
        return m.group(2)

    def testEverySpecialiserSetsIt(self):
        body = cpp_function(self.mm, 'RendererMetal::materialFragmentFunction')
        self.assertEqual(self.setting(body, 'kLightHdrConstantIndex'),
                         'lightRig && lightHdr')
        self.assertRegex(self.header, r'bool lightShadow = false,\s*bool lightHdr = false\);')
        self.assertRegex(self.code, r'RendererMetal::materialFragmentFunction\(\s*'
                                    r'id<MTLLibrary> lib, NSString\* name, int family, '
                                    r'bool lightRig,\s*bool lightShadow, bool lightHdr\)')
        # Parts 4-5: the tube's and the air's builders choose per variant
        for name in ('bezierTubeRigFunction', 'airFunction'):
            fn = cpp_function(self.mm, name)
            self.assertEqual(self.setting(fn, 'kLightHdrConstantIndex'), 'lightHdr', name)
            self.assertEqual(self.setting(fn, 'kLightShadowConstantIndex'), 'false', name)
            self.assertRegex(self.code, r'static id<MTLFunction> %s\('
                                        r'id<MTLLibrary> lib, NSString\* name,\s*'
                                        r'bool lightHdr\)' % name)
        # the classic RT pipelines never; the rig composite as its caller asks
        for name, value in (('RendererMetal::buildRTPipelines', 'false'),
                            ('RendererMetal::buildRTRigComposite', 'hdr')):
            fn = cpp_function(self.mm, name)
            self.assertEqual(self.setting(fn, 'kRTLightHdrConstantIndex'), value, name)
        self.assertRegex(self.code, r'RendererMetal::buildRTRigComposite\(bool transparent, '
                                    r'bool hdr\)')
        self.assertRegex(self.header, r'buildRTRigComposite\(bool transparent, bool hdr\);')
        # no other specialisation of these libraries: each site sets both
        # constants, and every one is in a function named above
        self.assertEqual(self.code.count('atIndex:kLightHdrConstantIndex]'),
                         self.code.count('atIndex:kLightShadowConstantIndex]'))
        self.assertEqual(self.code.count('atIndex:kLightHdrConstantIndex]'),
                         len(MATERIAL_SPECIALISERS))
        self.assertEqual(self.code.count('atIndex:kRTLightHdrConstantIndex]'),
                         self.code.count('atIndex:kRTLightRigConstantIndex]'))
        self.assertEqual(self.code.count('atIndex:kRTLightHdrConstantIndex]'),
                         len(RT_SPECIALISERS))

    def testOnlyRigBuildersAskForIt(self):
        """Part 4: a materialFragmentFunction call with a sixth argument
        (kLightHdr) is a rig build (its fourth argument true), and hands on
        its builder's hdr choice; every classic build passes three
        arguments, so the default false holds for it."""
        code = re.sub(r'/\*.*?\*/', '', self.code, flags=re.S)
        owners = {}
        for m in re.finditer(r'(?<![\w:])materialFragmentFunction\(([^;]*)\);', code):
            args = squash(m.group(1)).split(',')
            owner = re.findall(r'^[\w<>:\*\s]*RendererMetal::(\w+)\s*\(',
                               code[:m.start()], re.M)[-1]
            if len(args) <= 3:
                self.assertIn(owner, ('buildVBOPipelines', 'buildImpostorPipelines'),
                              m.group(0))
                continue
            self.assertEqual(len(args), 6, m.group(0))
            owners.setdefault(owner, set()).add(args[5])
            self.assertIn(args[3], ('true', 'lightRig'), m.group(0))
        self.assertEqual(owners, {
            'vboRigFragmentFunction': {'hdr'},
            'vboRigShadowFragmentFunction': {'hdr'},
            'ensureSphereRigPipelines': {'hdr'},
            'ensureSphereRigShadowPipelines': {'hdr'},
            'buildCylinderImpostorPipeline': {'lightHdr'},
        })
        # the tube's two variants, from its one builder
        tube = re.findall(r'bezierTubeRigFunction\(([^;]*)\);', code)
        self.assertEqual(sorted(squash(t).split(',')[-1] for t in tube),
                         ['false', 'h==1'])
        # Part 5: the air's functions come from newAirPipeline, which hands
        # airFunction its hdr choice, and the vertex function (no constant);
        # ensureAirPipelines asks for both composite variants and one march
        air = [squash(a) for a in re.findall(r'(?<![\w:])airFunction\(([^;]*)\);', code)]
        self.assertEqual(sorted(air), ['lib,@"post_air_vertex",false', 'lib,name,hdr'])
        ensure = cpp_function(self.mm, 'RendererMetal::ensureAirPipelines')
        self.assertEqual([(n, squash(h)) for n, h in re.findall(
            r'newAirPipeline\(_device, lib, vfn, @"(\w+)",\s*\w+, ([^)]*)\)', ensure)],
            [('post_air_full', 'v==1'), ('post_air_march', 'false'),
             ('post_air_upsample', 'v==1'),
             # #684: the export alpha's two passes read no constant
             ('post_air_alpha', 'false'), ('post_air_alpha_merge', 'false')])
        # Part 5: the RT rig composite is built once per call site, with the
        # frame's choice
        rt = [squash(r) for r in re.findall(r'(?<![\w:])buildRTRigComposite\(([^;]*)\);',
                                            code)]
        self.assertEqual(rt, ['doRTTrans,_lightHdrOn'])

    def testNothingUnspecialisedReachesIt(self):
        """A function fetched with plain newFunctionWithName: never reads
        kLightHdr (it would fail to compile at run time). The tube and air
        functions fetched by a name variable go through their specialisers,
        which fall back to the specialised form when Metal lists a
        constant."""
        plain = set(re.findall(r'newFunctionWithName:@"(\w+)"\]', self.code))
        self.assertTrue(plain)
        shared = dict(self.material, **msl_functions(self.msl['kMaterialImpostorSrc']))
        for lib in MATERIAL_LIBRARIES:
            own = msl_functions(self.msl[lib])
            table = dict(shared, **own)
            for name in plain & set(own):
                self.assertFalse(reaches(table, name, HDR_CONSTANT), '%s.%s' % (lib, name))
        for name in plain & set(self.rt):
            self.assertFalse(reaches(self.rt, name, HDR_CONSTANT), 'kRTSrc.%s' % name)
        # the tube and air composites do reach it, hence the specialisers
        tube = dict(self.material, **msl_functions(self.msl['kBezierTubeRigSrc']))
        self.assertEqual(reaches(tube, 'bezier_tube_fragment_rig', HDR_CONSTANT),
                         {'light_finish'})
        self.assertFalse(reaches(tube, 'bezier_tube_vertex_rig', HDR_CONSTANT))
        air = dict(self.material, **self.air)
        for name in ('post_air_full', 'post_air_upsample'):
            self.assertEqual(reaches(air, name, HDR_CONSTANT), {'post_air_finish'}, name)
        self.assertFalse(reaches(air, 'post_air_vertex', HDR_CONSTANT))
        for name in ('bezierTubeRigFunction', 'airFunction'):
            fn = cpp_function(self.mm, name)
            self.assertRegex(fn, r'fn\.functionConstantsDictionary\.count\s*==\s*0')


class TestCaches(HdrMSLCase):
    """Part 4 (the raster rig): every raster rig cache has an hdr dimension,
    and each draw asks for this frame's variant."""

    def testHeaderDimensions(self):
        h = self.header
        for member in ('_vboFragmentRigFunc', '_vboFragmentOitRigFunc',
                       '_vboFragmentRigShadowFunc', '_vboFragmentOitRigShadowFunc'):
            self.assertRegex(h, r'id<MTLFunction> %s\[2\]\[cMaterialFamily_count\] = \{\};'
                             % member, member)
        for member in ('_vboRigFuncTried', '_vboRigShadowFuncTried'):
            self.assertRegex(h, r'bool %s\[2\]\[cMaterialFamily_count\]\[2\] = \{\};'
                             % member, member)
        for member in ('_sphereRigPipeline', '_sphereRigOitPipeline',
                       '_sphereRigShadowPipeline', '_sphereRigShadowOitPipeline'):
            self.assertRegex(h, r'id<MTLRenderPipelineState> %s\[2\]'
                                r'\[cMaterialFamily_count\] = \{\};' % member, member)
        for member in ('_sphereRigBuilt', '_sphereRigShadowBuilt'):
            self.assertRegex(h, r'bool %s\[2\] = \{\};' % member, member)
        self.assertRegex(h, r'std::map<std::tuple<NSUInteger,\s*int,\s*int,\s*bool,'
                            r'\s*bool,\s*bool>,\s*CylinderPipelines>')
        self.assertRegex(h, r'id<MTLRenderPipelineState> _bezierTubeRigPipeline\[2\]'
                            r' = \{\};')
        # one tried flag for both tube variants
        self.assertRegex(h, r'bool _bezierTubeRigTried = false;')
        # Part 5: the RT rig composites and their tried flags [transparent][hdr]
        self.assertRegex(h, r'id<MTLRenderPipelineState> _rtResolvePipelineRig\[2\]\[2\]'
                            r' = \{\};')
        self.assertRegex(h, r'bool _rtRigTried\[2\]\[2\] = \{\};')
        self.assertNotRegex(h, r'_rtResolvePipelineTRig|_rtRigTTried')
        # Part 5: the air's composites [hdr], the march and the attempt single
        for member in ('_airFullPipeline', '_airUpsamplePipeline'):
            self.assertRegex(h, r'id<MTLRenderPipelineState> %s\[2\] = \{\};' % member,
                             member)
        self.assertRegex(h, r'id<MTLRenderPipelineState> _airMarchPipeline = nil;')
        self.assertRegex(h, r'bool _airPipelinesTried = false;')
        for sig in (r'id<MTLFunction> vboRigFragmentFunction\(int family, bool oit, '
                    r'bool hdr\);',
                    r'id<MTLFunction> vboRigShadowFragmentFunction\(int family, bool oit, '
                    r'bool hdr\);',
                    r'void ensureSphereRigPipelines\(bool hdr\);',
                    r'void ensureSphereRigShadowPipelines\(bool hdr\);',
                    r'MTLVertexDescriptor\* vd, int family, bool lightRig = false,'
                    r'\s*bool lightHdr = false\);',
                    r'MTLVertexDescriptor\* vd, bool lightRig = false,'
                    r'\s*bool lightHdr = false\);',
                    r'bool lightShadow = false,\s*bool lightHdr = false\);\s*'
                    r'void buildLabelPipeline'):
            self.assertRegex(h, sig)

    def testVBORigFunctions(self):
        for name, slots, tried in (
                ('RendererMetal::vboRigFragmentFunction',
                 r'oit \? &_vboFragmentOitRigFunc\[h\]\[family\] : '
                 r'&_vboFragmentRigFunc\[h\]\[family\];',
                 'bool& tried = _vboRigFuncTried[h][family][oit ? 1 : 0];'),
                ('RendererMetal::vboRigShadowFragmentFunction',
                 r'oit \? &_vboFragmentOitRigShadowFunc\[h\]\[family\]\s*'
                 r': &_vboFragmentRigShadowFunc\[h\]\[family\];',
                 'bool& tried = _vboRigShadowFuncTried[h][family][oit ? 1 : 0];')):
            body = cpp_function(self.mm, name)
            self.assertIn('const int h = hdr ? 1 : 0;', body, name)
            self.assertRegex(body, slots, name)
            self.assertIn(tried, body, name)
        release = cpp_function(self.mm, 'RendererMetal::releaseVBORigFunctions')
        self.assertIn('for (int h = 0; h < 2; ++h)', release)
        for member in ('_vboFragmentRigFunc', '_vboFragmentOitRigFunc',
                       '_vboFragmentRigShadowFunc', '_vboFragmentOitRigShadowFunc'):
            self.assertIn('[%s[h][f] release];' % member, release)
            self.assertIn('%s[h][f] = nil;' % member, release)

    def testVBOPipelineKey(self):
        body = cpp_function(self.mm, 'RendererMetal::cachedVBOPipeline')
        shadow_mix = body.index('if (lightShadow) mix(0x4C53);')
        hdr_rule = body.index('lightHdr = lightHdr && lightRig;')
        hdr_mix = body.index('if (lightHdr) mix(0x4C48);')
        # mixed only when true, after every other bit, before the lookup:
        # every classic and knee rig key is what it was
        self.assertLess(shadow_mix, hdr_rule)
        self.assertLess(hdr_rule, hdr_mix)
        self.assertLess(hdr_mix, body.index('_vboPipelineCache.find(key)'))
        self.assertEqual(body.count('mix(0x4C48)'), 1)
        self.assertEqual(len(set(re.findall(r'mix\((0x[0-9A-F]+)\)', body))), 3)
        # every rig function or pipeline it asks for is that variant
        for call in ('oitPipelineForVD(vd, family, lightRig, lightHdr)',
                     'oitPipelineForVD(vd, cMaterialFamily_default, lightRig, lightHdr)',
                     'vboRigShadowFragmentFunction(family, false, lightHdr)',
                     'vboRigFragmentFunction(family, false, lightHdr)',
                     'vboRigFragmentFunction(cMaterialFamily_default, false, lightHdr)'):
            self.assertIn(call, body)
        self.assertRegex(body, r'vboRigShadowFragmentFunction\(cMaterialFamily_default, '
                               r'false,\s*lightHdr\)')
        oit = cpp_function(self.mm, 'RendererMetal::oitPipelineForVD')
        self.assertRegex(oit, r'^\{[^;]*;\s*lightHdr = lightHdr && lightRig;')
        self.assertIn('vboRigShadowFragmentFunction(family, true, lightHdr)', oit)
        self.assertIn('vboRigFragmentFunction(family, true, lightHdr)', oit)
        # the draws: the rig request carries the frame's choice, the classic
        # requests none
        for fn in ('RendererMetal::drawVBO', 'RendererMetal::drawVBOIndexed'):
            draw = re.sub(r'/\*.*?\*/', '', cpp_function(self.mm, fn), flags=re.S)
            calls = [squash(c).split(',')
                     for c in re.findall(r'cachedVBOPipeline\(([^;]*)\);', draw)]
            rig = [c for c in calls if len(c) == 9]
            self.assertEqual(len(rig), 1, fn)
            self.assertEqual(rig[0][-2:], ['true', '_lightHdrOn'], fn)
            for c in calls:
                self.assertIn(len(c), (7, 9), (fn, c))

    def testSpherePipelines(self):
        for name, built, sets in (
                ('RendererMetal::ensureSphereRigPipelines', '_sphereRigBuilt',
                 ('_sphereRigPipeline', '_sphereRigOitPipeline')),
                ('RendererMetal::ensureSphereRigShadowPipelines', '_sphereRigShadowBuilt',
                 ('_sphereRigShadowPipeline', '_sphereRigShadowOitPipeline'))):
            body = cpp_function(self.mm, name)
            self.assertRegex(body, r'^\{\s*const int h = hdr \? 1 : 0;\s*if \(%s\[h\]\) '
                                   r'return;\s*%s\[h\] = true;' % (built, built), name)
            for member in sets:
                self.assertRegex(body, r'%s\[h\]\[f\] =\s*\[_device ' % member, name)
                self.assertNotRegex(body, r'%s\[f\]' % member, name)
        release = cpp_function(self.mm, 'RendererMetal::releaseSphereRigPipelines')
        self.assertIn('for (int h = 0; h < 2; ++h)', release)
        for member in ('_sphereRigPipeline', '_sphereRigOitPipeline',
                       '_sphereRigShadowPipeline', '_sphereRigShadowOitPipeline'):
            self.assertIn('[%s[h][f] release];' % member, release)
        for flag in ('_sphereRigBuilt', '_sphereRigShadowBuilt'):
            self.assertIn('%s[h] = false;' % flag, release)
        draw = cpp_function(self.mm, 'RendererMetal::drawSphereImpostors')
        self.assertIn('const int sphereHdr = _lightHdrOn ? 1 : 0;', draw)
        self.assertIn('ensureSphereRigPipelines(_lightHdrOn);', draw)
        self.assertIn('ensureSphereRigShadowPipelines(_lightHdrOn);', draw)
        for member in ('_sphereRigPipeline', '_sphereRigOitPipeline',
                       '_sphereRigShadowPipeline', '_sphereRigShadowOitPipeline'):
            self.assertRegex(draw, r'%s\[sphereHdr\]' % member)
            self.assertNotRegex(draw, r'%s(?!\[sphereHdr\])\b' % member)

    def testCylinderPipelines(self):
        build = cpp_function(self.mm, 'RendererMetal::buildCylinderImpostorPipeline')
        self.assertRegex(build, r'lightHdr = lightHdr && lightRig;')
        self.assertRegex(build, r'std::make_tuple\([^;]*lightRig,\s*lightShadow,\s*lightHdr\)')
        draw = re.sub(r'/\*.*?\*/', '', cpp_function(
            self.mm, 'RendererMetal::drawCylinderImpostors'), flags=re.S)
        self.assertRegex(draw, r'const bool cylHdr = cylRig && _lightHdrOn;')
        calls = [squash(c) for c in
                 re.findall(r'buildCylinderImpostorPipeline\(([^;]*)\);', draw)]
        # every rig entry is this frame's variant; the classic one is not
        self.assertEqual(sorted(calls), sorted(['call,cylRig,false,cylHdr', 'call,false',
                                                'call,true,true,cylHdr',
                                                'call,true,false,cylHdr']))

    def testTubeFromOneCompile(self):
        build = cpp_function(self.mm, 'RendererMetal::buildBezierTubeRigPipeline')
        self.assertRegex(build, r'^\{\s*if \(_bezierTubeRigTried\) return;\s*'
                                r'_bezierTubeRigTried = true;')
        self.assertEqual(build.count('newLibraryWithSource:'), 1)
        loop = re.search(r'for \(int h = 0; h < 2; \+\+h\) \{', build)
        self.assertIsNotNone(loop)
        inside = build[loop.end():_msl.match_brace(build, loop.end() - 1)]
        self.assertRegex(re.sub(r'/\*.*?\*/', '', inside),
                         r'bezierTubeRigFunction\(\s*lib, @"bezier_tube_fragment_rig",'
                         r'\s*h == 1\)')
        self.assertIn('_bezierTubeRigPipeline[h] =', inside)
        self.assertIn('[ffn release];', inside)
        # one vertex function for both, outside the loop
        self.assertLess(build.index('bezier_tube_vertex_rig'), loop.start())
        self.assertIn('[lib release];', build[_msl.match_brace(build, loop.end() - 1):])
        draw = cpp_function(self.mm, 'RendererMetal::drawBezierTubes')
        self.assertIn('_bezierTubeRigPipeline[_lightHdrOn ? 1 : 0]', draw)
        rebuild = cpp_function(self.mm, 'RendererMetal::rebuildDrawPipelines')
        self.assertIn('[_bezierTubeRigPipeline[h] release];', rebuild)
        dtor = cpp_function(self.mm, 'RendererMetal::~RendererMetal')
        self.assertIn('[_bezierTubeRigPipeline[0] release];', dtor)
        self.assertIn('[_bezierTubeRigPipeline[1] release];', dtor)

    def testRTRigComposites(self):
        """Part 5: the RT rig composite for the frame's kind (transparent or
        not, HDR or knee), each slot tried once, built from the retained RT
        library (no compile of its own), every slot released."""
        build = cpp_function(self.mm, 'RendererMetal::buildRTRigComposite')
        self.assertRegex(build, r'^\{\s*if \(!_rtLib\)\s*return nil;')
        self.assertNotIn('newLibraryWithSource:', build)
        self.assertEqual(build.count('[_rtLib newFunctionWithName:'), 2)
        self.assertIn('hdr ? " HDR" : ""', build)
        post = cpp_function(self.mm, 'RendererMetal::runPostChain')
        block = re.search(r'if\s*\(\s*_lightRigOn\s*&&\s*u\.matCount\s*>\s*0\.5f\s*\)\s*\{',
                          post)
        self.assertIsNotNone(block)
        inside = post[block.end():_msl.match_brace(post, block.end() - 1)]
        self.assertRegex(inside, r'^\s*const int rigT = doRTTrans \? 1 : 0;\s*'
                                 r'const int rigH = _lightHdrOn \? 1 : 0;\s*'
                                 r'id<MTLRenderPipelineState>\* rigComposite = '
                                 r'&_rtResolvePipelineRig\[rigT\]\[rigH\];\s*'
                                 r'bool\* tried = &_rtRigTried\[rigT\]\[rigH\];\s*'
                                 r'if \(!\*rigComposite && !\*tried\) \{\s*\*tried = true;\s*'
                                 r'\*rigComposite = buildRTRigComposite\(doRTTrans, '
                                 r'_lightHdrOn\);\s*\}')
        # the slots are read nowhere else
        for member in ('_rtResolvePipelineRig', '_rtRigTried'):
            owners = set()
            for m in re.finditer(r'\b%s\b' % member, self.code):
                owners.add(re.findall(r'^[\w<>:\*\s~]*RendererMetal::(~?\w+)\s*\(',
                                      self.code[:m.start()], re.M)[-1])
            want = {'runPostChain', '~RendererMetal'} if member == '_rtResolvePipelineRig' \
                else {'runPostChain'}
            self.assertEqual(owners, want, member)
        dtor = cpp_function(self.mm, 'RendererMetal::~RendererMetal')
        self.assertRegex(dtor, r'for \(int t = 0; t < 2; \+\+t\)\s*'
                               r'for \(int h = 0; h < 2; \+\+h\)\s*'
                               r'\[_rtResolvePipelineRig\[t\]\[h\] release\];')

    def testAirFromOneCompile(self):
        """Part 5: ensureAirPipelines makes both kLightHdr variants of the two
        composites from its one library compile, in its one attempt, and
        answers for this frame's variant; encodeAirPass draws that variant;
        the march stays single; both variants are released."""
        ensure = cpp_function(self.mm, 'RendererMetal::ensureAirPipelines')
        self.assertEqual(ensure.count('newLibraryWithSource:'), 1)
        self.assertRegex(ensure, r'^\{\s*const int h = _lightHdrOn \? 1 : 0;\s*'
                                 r'if \(_airPipelinesTried\)\s*return _airFullPipeline\[h\] '
                                 r'!= nil;\s*_airPipelinesTried = true;')
        self.assertLess(ensure.index('_airPipelinesTried = true;'),
                        ensure.index('newLibraryWithSource:'))
        for member, name in (('_airFullPipeline', 'post_air_full'),
                             ('_airUpsamplePipeline', 'post_air_upsample')):
            self.assertRegex(ensure, r'for \(int v = 0; v < 2; \+\+v\)\s*%s\[v\] = '
                                     r'newAirPipeline\(_device, lib, vfn, @"%s",\s*'
                                     r'MTLPixelFormatBGRA8Unorm, v == 1\);' % (member, name))
        self.assertRegex(ensure, r'_airMarchPipeline = newAirPipeline\(_device, lib, vfn, '
                                 r'@"post_air_march",\s*MTLPixelFormatRGBA16Float, false\);')
        # the library is released after every variant is made
        self.assertGreater(ensure.rindex('[lib release];'),
                           ensure.rindex('newAirPipeline('))
        self.assertRegex(ensure, r'return _airFullPipeline\[h\] != nil;\s*\}$')
        enc = cpp_function(self.mm, 'RendererMetal::encodeAirPass')
        self.assertIn('const int h = _lightHdrOn ? 1 : 0;', enc)
        self.assertRegex(enc, r'_airMarchPipeline && _airUpsamplePipeline\[h\] &&')
        self.assertIn('[ea setRenderPipelineState:(half ? _airUpsamplePipeline[h] : '
                      '_airFullPipeline[h])];', enc)
        self.assertIn('[em setRenderPipelineState:_airMarchPipeline];', enc)
        # every other use of the composites is a release or the one attempt
        for member in ('_airFullPipeline', '_airUpsamplePipeline'):
            self.assertNotRegex(self.code, r'\b%s\b(?!\[)' % member, member)
            owners = set()
            for m in re.finditer(r'\b%s\[' % member, self.code):
                owners.add(re.findall(r'^[\w<>:\*\s~]*RendererMetal::(~?\w+)\s*\(',
                                      self.code[:m.start()], re.M)[-1])
            self.assertEqual(owners, {'ensureAirPipelines', 'encodeAirPass',
                                      '~RendererMetal'}, member)
        dtor = cpp_function(self.mm, 'RendererMetal::~RendererMetal')
        for member in ('_airFullPipeline', '_airUpsamplePipeline'):
            for v in (0, 1):
                self.assertIn('[%s[%d] release];' % (member, v), dtor)
        self.assertIn('[_airMarchPipeline release];', dtor)


class TestFrame(HdrMSLCase):
    """Part 4: the frame's HDR colour (_lightHdrOn) and the exposure
    hand-off."""

    def testDerivedFromTheBlock(self):
        self.assertRegex(self.header, r'bool _lightHdrOn = false;')
        set_rig = cpp_function(self.mm, 'RendererMetal::setLightRig')
        on = set_rig.index('_lightRigOn = rig && rig->head[0] >= 1.0f;')
        hdr = set_rig.index('_lightHdrOn = _lightRigOn && rig->tone[1] > 0.5f;')
        self.assertLess(on, hdr)
        self.assertEqual(depth_at(set_rig, hdr), 1)
        begin = cpp_function(self.mm, 'RendererMetal::beginFrame')
        self.assertRegex(begin, r'_lightRigOn = false;\s*_lightHdrOn = false;')
        # written nowhere else
        writers = set()
        for m in re.finditer(r'\b_lightHdrOn\s*=(?!=)', self.code):
            writers.add(re.findall(r'^[\w<>:\*\s]*RendererMetal::(\w+)\s*\(',
                                   self.code[:m.start()], re.M)[-1])
        self.assertEqual(writers, {'setLightRig', 'beginFrame'})
        # read by the rig draws, runPostChain (the exposure hand-off and the
        # RT rig composite) and the air (Part 5) only
        readers = set()
        for m in re.finditer(r'\b_lightHdrOn\b(?!\s*=(?!=))', self.code):
            readers.add(re.findall(r'^[\w<>:\*\s]*RendererMetal::(\w+)\s*\(',
                                   self.code[:m.start()], re.M)[-1])
        self.assertEqual(readers, {'runPostChain', 'drawVBO', 'drawVBOIndexed',
                                   'drawSphereImpostors', 'drawCylinderImpostors',
                                   'drawBezierTubes', 'ensureAirPipelines',
                                   'encodeAirPass'})

    def testPostChainIsMastersWithoutTheHandOff(self):
        post = cpp_function(self.mm, 'RendererMetal::runPostChain')
        decl = _air.POST_EXPOSURE_624.search(post)
        self.assertIsNotNone(decl)
        self.assertEqual(depth_at(post, decl.start()), 1)
        # declared just before #13's pass, used only by it
        self.assertLess(decl.end(), post.index('bool exposureActive ='))
        self.assertRegex(post, r'bool exposureActive = \(postExposure < 0\.999f \|\| '
                               r'postExposure > 1\.001f\);')
        self.assertIn('u.exposure = postExposure;', post)
        self.assertNotRegex(post, r'\b_exposure\b(?!\s*;)')
        body = _air.AIR_STATEMENTS['RendererMetal::runPostChain'].sub('', post, count=1)
        body, declarations, uses = _air.without_post_exposure_624(body)
        self.assertEqual((declarations, uses), (1, _air.POST_EXPOSURE_USES_624))
        # Part 5: the RT rig composite choice, put back
        body, choices, builds = _air.without_rt_rig_hdr_624(body)
        self.assertEqual((choices, builds), (1, 1))
        # #684: the air alpha's two statements, taken out
        body, alpha = _air.without_air_alpha_684(body)
        self.assertEqual(alpha, [1, 1])
        self.assertEqual(digest(body),
                         _air.MASTER_FUNCTIONS[('RendererMetal.mm',
                                                'RendererMetal::runPostChain')])

    def testSceneLightsFrameOnlyGainsTheTone(self):
        source = read(os.path.join(ROOT, 'layer1', 'SceneLights.cpp'))
        body = cpp_function(source, 'SceneLightsFrame')
        for table in (_air.AIR_STATEMENTS, _air.STATEMENTS_624):
            statement = table['SceneLightsFrame']
            self.assertEqual(len(statement.findall(body)), 1)
            body = statement.sub('', body, count=1)
        self.assertEqual(digest(body),
                         _air.MASTER_FUNCTIONS[('SceneLights.cpp', 'SceneLightsFrame')])


class TestBlock(HdrMSLCase):

    def testToneIsLast(self):
        block = strip_comments(read(BLOCK_H))
        self.assertRegex(block, r'static_assert\(sizeof\(LightRigBlock\) == 688,')
        self.assertRegex(block, r'static_assert\(offsetof\(LightRigBlock, tone\) == 672,')
        struct = re.search(r'struct\s+LightRigBlock\s*\{(.*?)\};', block, re.S).group(1)
        self.assertTrue(squash(struct).endswith('floatshadowTile[4];floattone[4];'))
        for lib in ('kMaterialSrc', 'kRTSrc'):
            code = strip_comments(self.msl[lib])
            mirror = re.search(r'struct\s+LightRigU\s*\{(.*?)\};', code, re.S).group(1)
            self.assertTrue(squash(mirror).endswith('float4shadowTile;float4tone;'), lib)
