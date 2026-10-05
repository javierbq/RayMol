"""Per-light shadow maps (#616) in the Metal shaders and pipelines, from source.

The studio shadow maps are MSL compiled at run time (layerGraphics/metal/
RendererMetal.mm) and CI has no GPU. These checks pin, from the source, what
L1, the regression renders against master and L3 prove on a Mac:

* kLightShadow is function constant 2, declared once at the end of
  kMaterialSrc after #613's light block, with the C++ indices (constant 2,
  texture 7, sampler 7);
* the shadow helpers (light_shadow_lookup, light_visibility_shadowed and the
  _shadowed copies) are `__attribute__((unused)) static`, live at the end of
  kMaterialSrc and read no function constant;
* every _shadowed function is a copy of #613's, differing only by the maps
  and their sampler after `rig` and the _shadowed calls (a generic drift
  guard);
* the lookup: the slot from pos.w bounded by head.w, the normal offset
  (info.z) and the depth bias (info.w), a 3x3 sample_compare on the light's
  own slice, taps clamped inside the draw's tile, 1 without a tile or behind
  the light, nothing that can make a NaN;
* each of #613's six rig fragments takes the maps at texture(7) and their
  sampler at sampler(7) under kLightShadow, uses them only under it, and
  with kLightShadow false is #613's fragment verbatim (pinned against
  master aea4e74c6, the forms of the plan's D8 table);
* no other library sees kLightShadow (the ray tracer, the tubes, the post
  chain);
* materialFragmentFunction sets index 2 on every specialisation, the tube's
  fallback sets it false, and the shadow variants (VBO, sphere, cylinder)
  are chosen only under lightShadowsReady(), keyed apart from every classic
  and #613 key, fall back to the rig's own pipeline, and are released with
  the rig's;
* the map pass (Part 4): a lazy 3-slice Depth32Float array reallocated only
  on a size change; beginLightShadowMap chains the slices (depth-only, the
  full slice, never the classic map's validity or the camera viewport) and
  endLightShadowMaps reopens the scene pass once with endShadowPass's own
  statements; the modelview premultiply and u.ortho = 0 only while a slice
  is open; the maps bound with the rig only when ready; the whole-pixel
  shadow off, raster and traced, while studio shadows are on;
* SceneRenderMetal: the frame read once, the studio maps only under
  lights.shadows with every caster but the overlays, the classic pre-pass
  as the else branch, the camera matrices restored;
* grid_mode (Part 5): the map pass draws each cell into its own tile of the
  atlas (setLightShadowViewport, I->grid.slot per cell, reset after) and
  never calls SceneSetMetalGridCell or setGridSlot; setGridSlot stores the
  cell before its early returns; bindLightRig gives each draw its cell's
  tile (zero outside every cell); today's grid loops are master's (sha);
  the classic pass (beginShadowPass, endShadowPass, SceneBuildLightViewProjEye,
  the pre-pass body) pinned by sha against master aea4e74c6.

Pure source parsing (skipped, not passed, outside a repo checkout).

    pymol -ckqy testing/testing.py --run testing/tests/raymol/lighting_shadow_msl.py
"""
import hashlib
import importlib.util
import os
import re

from pymol import testing

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, os.pardir, os.pardir, os.pardir))
METAL_MM = os.path.join(ROOT, 'layerGraphics', 'metal', 'RendererMetal.mm')
METAL_H = os.path.join(ROOT, 'layerGraphics', 'metal', 'RendererMetal.h')


def _load_lighting_msl():
    """lighting_msl.py's parsers (shader_literals, msl_functions, fragments,
    cpp_function, remove_rig_statements, squash), loaded by path under a
    private name so its test cases are not collected a second time."""
    spec = importlib.util.spec_from_file_location(
        '_lighting_shadow_msl_parsers', os.path.join(HERE, 'lighting_msl.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


_msl = _load_lighting_msl()
shader_literals = _msl.shader_literals
strip_comments = _msl.strip_comments
msl_functions = _msl.msl_functions
fragments = _msl.fragments
cpp_function = _msl.cpp_function
match_brace = _msl.match_brace
remove_rig_statements = _msl.remove_rig_statements
squash = _msl.squash
depth_at = _msl.depth_at

# The six rig fragments of #613, by library.
RIG_FRAGMENTS = {
    'kVBOSrc': ('vbo_fragment', 'vbo_fragment_oit'),
    'kSphereImpostorSrc': ('sphere_impostor_fragment',
                           'sphere_impostor_fragment_oit'),
    'kCylinderImpostorSrc': ('cyl_impostor_fragment',
                             'cyl_impostor_fragment_oit'),
}
# The libraries the shadow variants are specialised from.
SHADOW_LIBRARIES = tuple(RIG_FRAGMENTS)

# The shadow helpers in kMaterialSrc, and which of them are copies of #613's.
SHADOW_HELPERS = ('light_shadow_lookup', 'light_visibility_shadowed',
                  'light_terms_view_shadowed', 'light_terms_shadowed',
                  'light_apply_shadowed')
# Every _shadowed copy, by library, with its #613 original (the plan's D8:
# one loop, two wrappers, three impostor helpers). light_visibility_shadowed
# is new code (the lookup), not a copy of light_visibility (which returns 1).
SHADOWED_COPIES = {
    'kMaterialSrc': {'light_terms_view_shadowed': 'light_terms_view',
                     'light_terms_shadowed': 'light_terms',
                     'light_apply_shadowed': 'light_apply'},
    'kSphereImpostorSrc': {
        'sphere_shade_material_rig_shadowed': 'sphere_shade_material_rig',
        'sphere_glass_rig_shadowed': 'sphere_glass_rig'},
    'kCylinderImpostorSrc': {
        'cyl_shade_material_rig_shadowed': 'cyl_shade_material_rig'},
}

# The two arguments each rig fragment gains, exactly.
MAPS_ARGUMENT = re.compile(
    r'depth2d_array<float>\s+lightShadowMaps\s*\[\[\s*texture\(7\)\s*,\s*'
    r'function_constant\(kLightShadow\)\s*\]\]')
SAMPLER_ARGUMENT = re.compile(
    r'sampler\s+lightShadowSmp\s*\[\[\s*sampler\(7\)\s*,\s*'
    r'function_constant\(kLightShadow\)\s*\]\]')
SHADOW_ARGUMENTS_SQUASHED = (
    ',depth2d_array<float>lightShadowMaps[[texture(7),function_constant(kLightShadow)]]'
    ',samplerlightShadowSmp[[sampler(7),function_constant(kLightShadow)]]')
SHADOW_GUARD = re.compile(r'if\s*\(\s*(?:kLightRig\s*&&\s*)?kLightShadow\s*\)')
SHADOW_TOKENS = re.compile(r'\bkLightShadow\b|\blightShadow\w*|\w+_shadowed\b')

# #613's code on master (aea4e74c6, PR #644's merge): sha256 of each
# function's signature and body, comments stripped and whitespace removed,
# the first 16 hex digits. Taken from master with lighting_msl.py's parsers,
# never from this branch: with kLightShadow false every rig fragment, rig
# helper and light helper must be exactly what #613 shipped.
MASTER_613 = {
    ('kVBOSrc', 'vbo_fragment'): ('1be74e6af4d56e9d', 'a40bc7ab03b56474'),
    ('kVBOSrc', 'vbo_fragment_oit'): ('fa4a6d1608274485', '25ba2c47075b0478'),
    ('kSphereImpostorSrc', 'sphere_impostor_fragment'):
        ('8ff00c9aa8dab448', '3c25a1c606d32503'),
    ('kSphereImpostorSrc', 'sphere_impostor_fragment_oit'):
        ('40c85eabe7e7fbde', 'a82a724bba7fef13'),
    ('kSphereImpostorSrc', 'sphere_shade_material_rig'):
        ('07c482db02f7600c', '7f29ebf73bd315ca'),
    ('kSphereImpostorSrc', 'sphere_glass_rig'):
        ('6febcc0900e0fcd6', '57d962cc7214ad2a'),
    ('kCylinderImpostorSrc', 'cyl_impostor_fragment'):
        ('ece804d6981b5b5c', 'e5df5087332f4379'),
    ('kCylinderImpostorSrc', 'cyl_impostor_fragment_oit'):
        ('99fab7e91e0cc052', '6837bc3562529bdb'),
    ('kCylinderImpostorSrc', 'cyl_shade_material_rig'):
        ('2eb0f1493ffb3b10', 'd201685b5438c819'),
    ('kMaterialSrc', 'light_response_neutral'):
        ('f9d29c479d573b42', '54a48318b1bd91ef'),
    ('kMaterialSrc', 'light_response'): ('0671125f88c96948', 'f2e7e832e8d95ec9'),
    ('kMaterialSrc', 'light_visibility'): ('0fa4d419dcaabf46', 'c6f76bc0d21bd512'),
    ('kMaterialSrc', 'light_terms_view'): ('c3ee53eb972837b6', 'bcd134015fcc1123'),
    ('kMaterialSrc', 'light_terms'): ('8eb781b0326cac3f', '5700796aaac4b937'),
    ('kMaterialSrc', 'light_finish'): ('481469f10a37eec2', 'ee8660f541d2d01f'),
    ('kMaterialSrc', 'light_outline'): ('a7b110ee96452011', 'b6293663981b312a'),
    ('kMaterialSrc', 'light_apply'): ('bae8f06c28ac6de5', '0f0770bb54f4b944'),
    ('kMaterialSrc', 'light_glass_glints'): ('28525fda551dd7b7', '1b0f5b8869222b54'),
}


def digest(text):
    return hashlib.sha256(squash(text).encode()).hexdigest()[:16]


def read(path):
    with open(path, encoding='utf-8') as handle:
        return handle.read()


def strip_block_comments(text):
    """C++ `/*name*/` argument labels removed (the MSL has none)."""
    return re.sub(r'/\*.*?\*/', '', text, flags=re.S)


def remove_shadow_ternaries(body):
    """Every `kLightShadow ? A : B` replaced by B, as the specialisation with
    kLightShadow false folds it."""
    while True:
        m = re.search(r'\bkLightShadow\s*\?', body)
        if not m:
            return body
        depth = 0
        i = m.end()
        while True:
            ch = body[i]
            if ch in '([{':
                depth += 1
            elif ch in ')]}':
                depth -= 1
            elif ch == ':' and depth == 0:
                break
            i += 1
        body = body[:m.start()] + body[i + 1:]


def without_shadow(body):
    """`body` as the specialisation with kLightShadow false runs it: the
    ternaries' false arms kept, every `if (kLightShadow) S;` and
    `if (kLightRig && kLightShadow) S; else` removed."""
    return remove_rig_statements(remove_shadow_ternaries(body), SHADOW_GUARD)


def normalise_copy(text):
    """A _shadowed copy (signature + body) with the two differences the plan
    allows taken out: the _shadowed suffixes and the maps and their sampler,
    as parameters and as arguments."""
    code = squash(text)
    code = code.replace(',depth2d_array<float>maps,samplersmp', '')
    code = code.replace(',maps,smp', '')
    return code.replace('_shadowed', '')


def guarding_block(body, index):
    """The text of every `if (...)` condition whose braces enclose `index`,
    innermost last."""
    conditions = []
    for m in re.finditer(r'(?:else\s+)?if\s*\(', body[:index]):
        close = _msl.match_paren(body, m.end() - 1)
        brace = re.match(r'\s*\{', body[close + 1:])
        if not brace:
            continue
        open_brace = close + 1 + brace.end() - 1
        if open_brace < index <= match_brace(body, open_brace):
            conditions.append(body[m.end():close])
    return conditions


class ShadowMSLCase(testing.PyMOLTestCase):

    def setUp(self):
        # As lighting_msl.py: skipped outside a checkout (decided by
        # RendererMetal.mm alone), and before the base setUp.
        if not os.path.isfile(METAL_MM):
            self.skipTest('%s not present; not a repo checkout' % METAL_MM)
        if not os.path.isfile(METAL_H):
            self.fail('%s is missing from the checkout' % METAL_H)
        super().setUp()
        self.mm = read(METAL_MM)
        self.code = strip_comments(self.mm)
        self.msl = shader_literals(self.mm)
        self.material = msl_functions(self.msl['kMaterialSrc'])


class TestShadowBlock(ShadowMSLCase):

    def testConstantAndIndices(self):
        material = strip_comments(self.msl['kMaterialSrc'])
        found = re.findall(r'constant\s+bool\s+kLightShadow\s*\[\[\s*'
                           r'function_constant\((\d+)\)\s*\]\]\s*;', material)
        self.assertEqual(found, ['2'])
        # after #613's constant and helpers: one block at the end
        decl = re.search(r'constant\s+bool\s+kLightShadow\b', material).start()
        self.assertLess(re.search(r'constant\s+bool\s+kLightRig\b', material).start(),
                        decl)
        for helper in _msl.HELPERS:
            self.assertLess(material.index(self.material[helper][0]), decl, helper)
        for helper in SHADOW_HELPERS:
            self.assertGreater(material.index(self.material[helper][0]), decl,
                               helper)
        # the C++ side
        for name, value in (('kLightShadowConstantIndex', 2),
                            ('kLightShadowTextureIndex', 7),
                            ('kLightShadowSamplerIndex', 7)):
            self.assertRegex(self.code, r'constexpr NSUInteger %s = %d;'
                             % (name, value))
        # and nowhere else: no other literal declares or reads it
        for name, literal in self.msl.items():
            if name == 'kMaterialSrc' or name in SHADOW_LIBRARIES:
                continue
            self.assertNotRegex(strip_comments(literal), SHADOW_TOKENS, name)
        for name in ('kRTSrc', 'kBezierTubeSrc', 'kBezierTubeRigSrc', 'kPostSrc',
                     'kEyeReconSrc'):
            self.assertIn(name, self.msl)
        # texture(7) and sampler(7) are the maps' alone
        for lib in ('kMaterialSrc', 'kMaterialImpostorSrc') + SHADOW_LIBRARIES:
            code = strip_comments(self.msl[lib])
            for m in re.finditer(r'[^\n,(]*\[\[\s*(?:texture|sampler)\(7\)[^\]]*\]\]',
                                 code):
                self.assertTrue(MAPS_ARGUMENT.search(m.group(0)) or
                                SAMPLER_ARGUMENT.search(m.group(0)),
                                '%s: %r' % (lib, m.group(0).strip()))

    def testHelpersAreUnusedStaticAndReadNoConstant(self):
        constant = re.compile(r'\bkLightRig\b|\bkLightShadow\b|\bkMat[A-Z]\w*|'
                              r'function_constant')
        for helper in SHADOW_HELPERS:
            self.assertIn(helper, self.material, helper)
            self.assertRegex(self.material[helper][0],
                             r'^\s*__attribute__\(\(unused\)\)\s+static\s', helper)
            seen, todo = set(), [helper]
            while todo:
                name = todo.pop()
                if name in seen:
                    continue
                seen.add(name)
                self.assertNotRegex(self.material[name][1], constant,
                                    '%s (from %s)' % (name, helper))
                todo += [c for c in re.findall(r'\b((?:light|mat)_\w+)\s*\(',
                                               self.material[name][1])
                         if c in self.material]
            # light_response is #615's; the helpers take a LightResponse
            self.assertNotIn('light_response', seen, helper)
        # defined only in kMaterialSrc
        for name, literal in self.msl.items():
            if name == 'kMaterialSrc':
                continue
            for helper in SHADOW_HELPERS:
                self.assertNotIn(helper, msl_functions(literal), name)

    def testThe613CodeIsUnchanged(self):
        """#613's light helpers and impostor rig helpers are master's, byte
        for byte up to whitespace and comments."""
        for (lib, name), (sig, body) in MASTER_613.items():
            if name in [f for fs in RIG_FRAGMENTS.values() for f in fs]:
                continue
            got_sig, got_body = msl_functions(self.msl[lib])[name]
            self.assertEqual((digest(got_sig), digest(got_body)), (sig, body),
                             '%s.%s' % (lib, name))


class TestDriftGuard(ShadowMSLCase):

    def testEveryShadowedCopyIsTheOriginal(self):
        """Generic: every function named *_shadowed in a lit library, but
        the lookup's light_visibility_shadowed, is its original with only the
        maps and the _shadowed calls added."""
        found = {}
        for lib in ('kMaterialSrc', 'kMaterialImpostorSrc') + SHADOW_LIBRARIES:
            functions = msl_functions(self.msl[lib])
            for name, (sig, body) in functions.items():
                if not name.endswith('_shadowed'):
                    continue
                found.setdefault(lib, set()).add(name)
                if name == 'light_visibility_shadowed':
                    continue
                original = name[:-len('_shadowed')]
                self.assertIn(original, functions, '%s.%s' % (lib, name))
                osig, obody = functions[original]
                self.assertEqual(normalise_copy(sig + body),
                                 squash(osig + obody), '%s.%s' % (lib, name))
                # the maps come right after the rig, as parameters
                self.assertRegex(squash(sig), r'constantLightRigU&rig,'
                                              r'depth2d_array<float>maps,samplersmp')
        expected = {lib: set(copies) for lib, copies in SHADOWED_COPIES.items()}
        expected['kMaterialSrc'].add('light_visibility_shadowed')
        self.assertEqual(found, expected)

    def testCopiesCallOnlyShadowedLights(self):
        """A copy calls the _shadowed light functions and never the
        unshadowed ones it replaces (a half-converted copy would drop a
        light's shadow)."""
        for lib, copies in SHADOWED_COPIES.items():
            functions = msl_functions(self.msl[lib])
            for name in copies:
                body = functions[name][1]
                self.assertNotRegex(body, r'\blight_(?:apply|terms|terms_view|'
                                          r'visibility)\s*\(', name)
                self.assertRegex(body, r'\w+_shadowed\(', name)


class TestLookup(ShadowMSLCase):

    def testVisibilityTakesTheLightsOwnSlot(self):
        body = squash(self.material['light_visibility_shadowed'][1])
        self.assertIn('constintslot=int(rig.L[i].pos.w);', body)
        self.assertIn('if(slot<0||slot>=3||slot>=int(rig.head.w))return1.0;', body)
        self.assertIn('returnlight_shadow_lookup(rig,maps,smp,slot,p,n,ld,d);', body)
        # the loop hands it light i, the point, the facing normal, the unit
        # direction to the light and the distance
        loop = squash(self.material['light_terms_view_shadowed'][1])
        self.assertIn('light_visibility_shadowed(rig,maps,smp,i,pEye,N,Ld,d)', loop)

    def testLookupForm(self):
        sig, body = self.material['light_shadow_lookup']
        self.assertEqual(squash(sig),
                         '__attribute__((unused))staticfloatlight_shadow_lookup('
                         'constantLightRigU&rig,depth2d_array<float>maps,samplersmp,'
                         'intslot,float3p,float3n,float3ld,floatd)')
        code = squash(body)
        for expr in (
                # no tile (grid cell without one): lit
                'constfloat4tile=rig.shadowTile;',
                'if(!(tile.z>0.0&&tile.w>0.0))return1.0;',
                'constfloat4info=rig.S[slot].info;',
                # one texel of this tile at the point's distance
                'constfloattilePx=max(info.y*tile.z,1.0);',
                'constfloattexel=2.0*d*info.x/tilePx;',
                # the normal offset (info.z texels, more at grazing light),
                # then a texel toward the light
                'constfloat3q=p+n*(info.z*texel/max(dot(n,ld),0.25))+ld*texel;',
                'constfloat4lc=rig.S[slot].viewProj*float4(q,1.0);',
                # behind the light, outside the map or its depth range: lit
                'if(!(lc.w>1e-6))return1.0;',
                'if(!(abs(ndc.x)<=1.0&&abs(ndc.y)<=1.0&&abs(ndc.z)<=1.0))return1.0;',
                # the tile's uv (window y down) and the GL depth, less the bias
                'constfloat2uv=tile.xy+float2(0.5+0.5*ndc.x,0.5-0.5*ndc.y)*tile.zw;',
                'constfloatfd=0.5+0.5*ndc.z-info.w;',
                # taps half a texel inside the tile, 1.2 texels apart
                'constfloat2lo=tile.xy+halfTexel;',
                'constfloat2hi=max(tile.xy+tile.zw-halfTexel,lo);',
                'constfloattap=1.2/size;',
                'for(inty=-1;y<=1;++y){for(intx=-1;x<=1;++x){',
                'lit+=maps.sample_compare(smp,clamp(uv+float2(x,y)*tap,lo,hi),'
                'uint(slot),fd);',
                'returnlit/9.0;'):
            self.assertIn(expr, code, expr)
        self.assertIn('constfloatsize=max(info.y,1.0);', code)
        self.assertIn('constfloat2halfTexel=float2(0.5/size);', code)
        self.assertEqual(code.count('sample_compare('), 1)

    def testLookupCannotMakeANaN(self):
        """Every division is by a value bounded away from zero, and there is
        no normalize() (#613's OIT rule)."""
        body = strip_comments(self.material['light_shadow_lookup'][1])
        self.assertNotIn('normalize(', body)
        divisors = re.findall(r'/\s*([\w.]+)', body)
        self.assertEqual(sorted(set(divisors)),
                         sorted({'tilePx', 'max', 'lc.w', 'size', '9.0'}))
        self.assertIn('/ max(dot(n, ld), 0.25)', body)
        code = squash(body)
        # lc.w is tested before the divide; size and tilePx are max()ed
        self.assertLess(code.index('if(!(lc.w>1e-6))return1.0;'),
                        code.index('lc.xyz/lc.w'))


class TestFragments(ShadowMSLCase):

    def testEachRigFragmentTakesTheMapsUnderTheConstant(self):
        for lib in self.msl:
            for name, (sig, body) in fragments(self.msl[lib]).items():
                takes = lib in RIG_FRAGMENTS and name in RIG_FRAGMENTS[lib]
                if not takes:
                    self.assertNotRegex(sig + body, SHADOW_TOKENS,
                                        '%s.%s' % (lib, name))
                    continue
                self.assertEqual(len(MAPS_ARGUMENT.findall(sig)), 1, name)
                self.assertEqual(len(SAMPLER_ARGUMENT.findall(sig)), 1, name)
                # right after the rig argument, and last
                self.assertTrue(squash(sig).endswith(
                    'function_constant(kLightRig)]]' + SHADOW_ARGUMENTS_SQUASHED
                    + ')'), name)
                # used only under kLightShadow
                self.assertRegex(body, r'\bkLightShadow\b', name)
                leftover = SHADOW_TOKENS.findall(without_shadow(body))
                self.assertFalse(leftover, '%s.%s uses %s outside kLightShadow'
                                 % (lib, name, leftover))

    def testWithoutTheConstantEachFragmentIs613s(self):
        """kLightShadow false: master's #613 fragment, signature and body
        (R1: the false arm is #613's statement verbatim)."""
        for lib, names in RIG_FRAGMENTS.items():
            for name in names:
                sig, body = fragments(self.msl[lib])[name]
                self.assertEqual(
                    (digest(squash(sig).replace(SHADOW_ARGUMENTS_SQUASHED, '')),
                     digest(without_shadow(body))),
                    MASTER_613[(lib, name)], '%s.%s' % (lib, name))

    def testShadowArmsAreThe613ArmsShadowed(self):
        """The D8 table: each shadow arm is the #613 statement next to it with
        the _shadowed function and the maps."""
        vbo = fragments(self.msl['kVBOSrc'])
        body = squash(vbo['vbo_fragment'][1])
        self.assertIn(
            'if(kLightRig){constfloat3shaded=vbo_material_shade(in.color.rgb,'
            'in.normalEye,in.posModel,lt,mat,envMap,envSmp);'
            'if(kLightShadow)returnfloat4(light_apply_shadowed(shaded,in.color.rgb,'
            'in.normalEye,in.posEye,rig,lightShadowMaps,lightShadowSmp,'
            'light_response(mat)),in.color.a);'
            'returnfloat4(light_apply(shaded,in.color.rgb,in.normalEye,in.posEye,'
            'rig,light_response(mat)),in.color.a);}', body)
        body = squash(vbo['vbo_fragment_oit'][1])
        self.assertIn(
            'constLightTermsrigLight=kLightShadow?light_terms_shadowed(rig,'
            'lightShadowMaps,lightShadowSmp,in.color.rgb,N,in.posEye,'
            'light_response(mat)):light_terms(rig,in.color.rgb,N,in.posEye,'
            'light_response(mat));', body)
        self.assertIn(
            'c.rgb=kLightShadow?light_apply_shadowed(c.rgb,in.color.rgb,'
            'in.normalEye,in.posEye,rig,lightShadowMaps,lightShadowSmp,'
            'light_response(mat)):light_apply(c.rgb,in.color.rgb,in.normalEye,'
            'in.posEye,rig,light_response(mat));', body)
        three_way = re.compile(
            r'if\(kLightRig&&kLightShadow\)(\w+)_rig_shadowed\(([^;]*)\);'
            r'elseif\(kLightRig\)(\w+)_rig\(([^;]*)\);else(\w+)\(([^;]*)\);')
        for lib in ('kSphereImpostorSrc', 'kCylinderImpostorSrc'):
            for name in RIG_FRAGMENTS[lib]:
                body = squash(fragments(self.msl[lib])[name][1])
                found = three_way.findall(body)
                self.assertEqual(len(found), 1, name)
                shadow, sargs, rig, rargs, classic, _ = found[0]
                self.assertEqual(shadow, rig, name)
                self.assertEqual(classic, rig, name)
                self.assertEqual(sargs.replace('rig,lightShadowMaps,lightShadowSmp,',
                                               'rig,', 1), rargs, name)
        sphere = squash(fragments(self.msl['kSphereImpostorSrc'])
                        ['sphere_impostor_fragment_oit'][1])
        self.assertIn(
            'if(kLightRig&&kLightShadow)rgb=sphere_glass_rig_shadowed(rgb,'
            'in.color.rgb,n,pt,u,mat,envMap,envSmp,rig,lightShadowMaps,'
            'lightShadowSmp);elseif(kLightRig)rgb=sphere_glass_rig(rgb,'
            'in.color.rgb,n,pt,u,mat,envMap,envSmp,rig);', sphere)
        cyl = squash(fragments(self.msl['kCylinderImpostorSrc'])
                     ['cyl_impostor_fragment_oit'][1])
        self.assertIn(
            'constLightTermsrigLight=kLightShadow?light_terms_shadowed(rig,'
            'lightShadowMaps,lightShadowSmp,base,n,pt,light_response(mat))'
            ':light_terms(rig,base,n,pt,light_response(mat));', cyl)
        self.assertIn(
            'if(kLightRig&&kLightShadow)rgb=light_apply_shadowed(rgb,base,n,pt,'
            'rig,lightShadowMaps,lightShadowSmp,light_response(mat));'
            'elseif(kLightRig)rgb=light_apply(rgb,base,n,pt,rig,'
            'light_response(mat));', cyl)
        # the outlines are #613's, unshadowed paint
        for lib, names in RIG_FRAGMENTS.items():
            for name in names:
                body = fragments(self.msl[lib])[name][1]
                self.assertNotIn('light_outline_shadowed', body)

    def testRigSpecialisationKeepsNoShadowCode(self):
        """With kLightRig and kLightShadow both false (classic) nothing of
        either survives (lighting_msl.py's RIG_TOKENS checks the same with
        its extended guard; this is the shadow-only view)."""
        for lib, names in RIG_FRAGMENTS.items():
            for name in names:
                body = fragments(self.msl[lib])[name][1]
                classic = remove_rig_statements(body)
                self.assertFalse(SHADOW_TOKENS.findall(classic), name)


class TestPipelines(ShadowMSLCase):

    def setUp(self):
        super().setUp()
        self.header = strip_comments(read(METAL_H))

    def body(self, name):
        return strip_block_comments(cpp_function(self.mm, name))

    def testSpecialisationAlwaysSetsIndexTwo(self):
        body = self.body('RendererMetal::materialFragmentFunction')
        m = re.search(r'bool shadow = lightRig && lightShadow;\s*\[cv setConstantValue:'
                      r'&shadow type:MTLDataTypeBool atIndex:kLightShadowConstantIndex\];',
                      body)
        self.assertIsNotNone(m)
        self.assertEqual(depth_at(body, m.start()), 1)
        self.assertLess(m.start(), body.index('constantValues:'))
        self.assertRegex(self.header, r'materialFragmentFunction\(\s*id<MTLLibrary> lib,'
                                      r'\s*NSString\* name,\s*int family,\s*'
                                      r'bool lightRig = false,\s*bool lightShadow = false\);')
        # the classic builds pass three arguments, #613's rig builds four
        for fn, count in (('RendererMetal::buildVBOPipelines', 3),
                          ('RendererMetal::buildImpostorPipelines', 3),
                          ('RendererMetal::vboRigFragmentFunction', 4),
                          ('RendererMetal::ensureSphereRigPipelines', 4)):
            calls = re.findall(r'materialFragmentFunction\(([^;]*)\);', self.body(fn))
            self.assertTrue(calls, fn)
            for args in calls:
                self.assertEqual(len(args.split(',')), count, (fn, args))
        # the shadow variants ask for both
        for fn in ('RendererMetal::vboRigShadowFragmentFunction',
                   'RendererMetal::ensureSphereRigShadowPipelines'):
            calls = re.findall(r'materialFragmentFunction\(([^;]*)\);', self.body(fn))
            self.assertTrue(calls, fn)
            for args in calls:
                self.assertEqual(squash(args).split(',')[-2:], ['true', 'true'], fn)
        # the tube's fallback sets it false
        tube = self.body('bezierTubeRigFunction')
        self.assertRegex(tube, r'bool shadow = false;\s*\[cv setConstantValue:&shadow '
                               r'type:MTLDataTypeBool atIndex:kLightShadowConstantIndex\];')

    def testOnlyTheShadowVariantsAskForTheMaps(self):
        """materialFragmentFunction is asked for kLightShadow (a fifth
        argument) only by the three shadow builders."""
        callers = set()
        for m in re.finditer(r'\bmaterialFragmentFunction\(([^;]*)\);',
                             strip_block_comments(self.code)):
            if len(m.group(1).split(',')) < 5:
                continue
            owner = re.findall(r'^[\w<>:\*\s]*RendererMetal::(\w+)\s*\(',
                               self.code[:m.start()], re.M)
            callers.add(owner[-1])
        self.assertEqual(callers, {'vboRigShadowFragmentFunction',
                                   'ensureSphereRigShadowPipelines',
                                   'buildCylinderImpostorPipeline'})

    def testReadyPredicate(self):
        ready = self.body('RendererMetal::lightShadowsReady')
        self.assertEqual(squash(ready),
                         '{return_lightRigOn&&_lightShadowMapsReady&&!_shadowMode'
                         '&&!_peelMode;}')
        self.assertRegex(self.header, r'bool _lightShadowMapsReady = false;')
        self.assertRegex(self.header, r'bool lightShadowsReady\(\) const;')
        begin = self.body('RendererMetal::beginFrame')
        self.assertIn('_lightShadowMapsReady = false;', begin)

    def testVBOShadowVariantChosenOnlyWhenReady(self):
        cached = self.body('RendererMetal::cachedVBOPipeline')
        self.assertIn('const bool lightShadow = lightRig && lightShadowsReady();',
                      cached)
        # the key bit after #613's, only for the shadow variant
        rig_mix = cached.index('if (lightRig) mix(0x4C52);')
        shadow_mix = cached.index('if (lightShadow) mix(0x4C53);')
        self.assertLess(rig_mix, shadow_mix)
        self.assertEqual(len(re.findall(r'\bmix\(', cached)), 10)
        # Lit: the shadow function only under lightShadow, the rig's otherwise
        block = re.search(r'if\s*\(\s*variant == VBOPipelineVariant::Lit && '
                          r'lightShadow\s*\)\s*\{', cached)
        self.assertIsNotNone(block)
        inside = cached[block.end():match_brace(cached, block.end() - 1)]
        self.assertIn('vboRigShadowFragmentFunction(family, false)', inside)
        self.assertIn('vboRigShadowFragmentFunction(cMaterialFamily_default, false)',
                      inside)
        self.assertIn('_lightShadowWarned = true;', inside)
        self.assertRegex(cached, r'if\s*\(\s*shadowFn\s*\)\s*\{\s*ffn = shadowFn;\s*\}'
                                 r'\s*else if\s*\(\s*variant == VBOPipelineVariant::Lit'
                                 r' && lightRig\s*\)')
        self.assertEqual(len(re.findall(r'vboRigShadowFragmentFunction\(', cached)), 2)
        # Oit: the same predicate inside oitPipelineForVD, whose call is #613's
        oit = self.body('RendererMetal::oitPipelineForVD')
        block = re.search(r'if\s*\(\s*lightRig && lightShadowsReady\(\)\s*\)\s*\{', oit)
        self.assertIsNotNone(block)
        inside = oit[block.end():match_brace(oit, block.end() - 1)]
        self.assertIn('ffn = vboRigShadowFragmentFunction(family, true);', inside)
        self.assertIn('_lightShadowWarned = true;', inside)
        self.assertEqual(len(re.findall(r'vboRigShadowFragmentFunction\(', oit)), 1)
        # ...falling back to #613's choice
        self.assertRegex(oit, r'if\s*\(\s*!ffn\s*\)\s*ffn = lightRig \? '
                              r'vboRigFragmentFunction\(family, true\)\s*:\s*'
                              r'_vboFragmentOitFunc\[family\];')
        # nobody else asks for a VBO shadow function
        self.assertEqual(len(re.findall(r'(?<!::)\bvboRigShadowFragmentFunction\(',
                                        self.code)), 3)
        # the draw sites are #613's (lighting_msl.py pins them)
        for fn in ('RendererMetal::drawVBO', 'RendererMetal::drawVBOIndexed'):
            self.assertNotRegex(self.body(fn), r'lightShadow|RigShadow', fn)

    def testVBOShadowFunctionsAreLazyAndReleased(self):
        fn = self.body('RendererMetal::vboRigShadowFragmentFunction')
        self.assertIn('bool& tried = _vboRigShadowFuncTried[family][oit ? 1 : 0];', fn)
        self.assertRegex(fn, r'if\s*\(\s*!\*slot && !tried\s*\)\s*\{\s*tried = true;')
        self.assertIn('_vboLibrary', fn)
        release = self.body('RendererMetal::releaseVBORigFunctions')
        for member in ('_vboFragmentRigShadowFunc[f]', '_vboFragmentOitRigShadowFunc[f]'):
            self.assertIn('[%s release];' % member, release)
            self.assertIn('%s = nil;' % member, release)
        self.assertIn('_vboRigShadowFuncTried[f][0] = _vboRigShadowFuncTried[f][1] = false;',
                      release)

    def testSphereShadowPipelines(self):
        ensure = self.body('RendererMetal::ensureSphereRigShadowPipelines')
        self.assertRegex(ensure, r'^\{\s*if\s*\(\s*_sphereRigShadowBuilt\s*\)\s*return\s*;'
                                 r'\s*_sphereRigShadowBuilt\s*=\s*true\s*;')
        calls = re.findall(r'materialFragmentFunction\(([^;]*)\);', ensure)
        self.assertEqual(sorted(squash(c).split(',')[1] for c in calls),
                         ['@"sphere_impostor_fragment"',
                          '@"sphere_impostor_fragment_oit"'])
        for args in calls:
            self.assertTrue(squash(args).startswith('_sphereLib,'), args)
        # the classic descriptors, as #613's rig pipelines
        self.assertIn('newRenderPipelineStateWithDescriptor:_sphereOpaqueDesc', ensure)
        self.assertIn('newRenderPipelineStateWithDescriptor:_sphereOitDesc', ensure)
        self.assertNotIn('alloc]', ensure)
        self.assertRegex(ensure, r'setOitRefractAttachment\(_sphereOitDesc\.'
                                 r'colorAttachments\[2\],\s*_oitRefractEnabled,'
                                 r'\s*f == cMaterialFamily_glass\)')
        # released (and retried) with #613's rig pipelines
        release = self.body('RendererMetal::releaseSphereRigPipelines')
        for member in ('_sphereRigShadowPipeline[f]', '_sphereRigShadowOitPipeline[f]'):
            self.assertIn('[%s release];' % member, release)
        self.assertIn('_sphereRigShadowBuilt = false;', release)
        for fn in ('RendererMetal::rebuildDrawPipelines',
                   'RendererMetal::~RendererMetal'):
            self.assertIn('releaseSphereRigPipelines();', self.body(fn), fn)
        # the draw: after #613's choice, only in place of a rig pipeline and
        # only while the maps are ready; the rig pipeline if none (logged)
        draw = self.body('RendererMetal::drawSphereImpostors')
        block = re.search(r'if\s*\(\s*rigPipeline\s*&&\s*lightShadowsReady\(\)\s*\)\s*\{',
                          draw)
        self.assertIsNotNone(block)
        inside = draw[block.end():match_brace(draw, block.end() - 1)]
        self.assertIn('ensureSphereRigShadowPipelines();', inside)
        self.assertRegex(inside, r'_oitActive\s*\?\s*_sphereRigShadowOitPipeline\s*:\s*'
                                 r'_sphereRigShadowPipeline')
        self.assertIn('shadowSet[cMaterialFamily_default]', inside)
        self.assertRegex(inside, r'if\s*\(\s*shadowPipeline\s*\)\s*\{\s*'
                                 r'rigPipeline = shadowPipeline;')
        self.assertIn('_lightShadowWarned = true;', inside)
        self.assertLess(draw.index('ensureSphereRigPipelines();'), block.start())
        self.assertEqual(len(re.findall(r'(?<!::)\bensureSphereRigShadowPipelines\(',
                                        self.code)), 1)

    def testCylinderShadowEntries(self):
        self.assertRegex(self.header, r'std::map<std::tuple<NSUInteger,\s*int,\s*int,'
                                      r'\s*bool,\s*bool>,\s*CylinderPipelines>')
        self.assertRegex(self.header, r'void buildCylinderImpostorPipeline\('
                                      r'const CylinderImpostorDrawCall& call,\s*'
                                      r'bool lightRig = false,\s*bool lightShadow = false\);')
        build = self.body('RendererMetal::buildCylinderImpostorPipeline')
        self.assertRegex(build, r'^\{\s*lightShadow = lightShadow && lightRig;')
        self.assertRegex(build, r'std::make_tuple\(\s*static_cast<NSUInteger>\(call\.stride\),'
                                r'\s*call\.capOff,\s*cylFam,\s*lightRig,\s*lightShadow\)')
        # no shadow or peel pipeline, and a failed entry is cached, as #613's
        self.assertRegex(build, r'sfn\s*=\s*lightRig\s*\?\s*nil\s*:')
        self.assertIn('if (_cylinderImpostorPipeline || lightRig)', build)
        # every entry is released, whatever its key
        release = self.body('RendererMetal::releaseCylinderPipelines')
        self.assertIn('for (auto& kv : _cylinderPipelines)', release)
        self.assertIn('_cylinderPipelines.clear();', release)
        # the draw: after #613's selection, only when its rig entry was built
        # and the maps are ready; back to the rig entry if not (logged)
        draw = self.body('RendererMetal::drawCylinderImpostors')
        block = re.search(r'\}\s*else if\s*\(\s*cylRig\s*&&\s*lightShadowsReady\(\)'
                          r'\s*\)\s*\{', draw)
        self.assertIsNotNone(block)
        inside = draw[block.end():match_brace(draw, block.end() - 1)]
        calls = re.findall(r'buildCylinderImpostorPipeline\(([^;]*)\);', inside)
        self.assertEqual([squash(c) for c in calls], ['call,true,true', 'call,true'])
        self.assertIn('_lightShadowWarned = true;', inside)
        self.assertLess(draw.index('buildCylinderImpostorPipeline(call, false);'),
                        block.start())

    def testShadowNeverChosenWithoutTheRig(self):
        """Every shadow-variant choice sits under lightShadowsReady(), which
        needs the rig on and a colour draw."""
        for fn, call in (('RendererMetal::oitPipelineForVD',
                          r'vboRigShadowFragmentFunction\('),
                         ('RendererMetal::cachedVBOPipeline',
                          r'vboRigShadowFragmentFunction\('),
                         ('RendererMetal::drawSphereImpostors',
                          r'ensureSphereRigShadowPipelines\('),
                         ('RendererMetal::drawCylinderImpostors',
                          r'buildCylinderImpostorPipeline\(call,\s*true,\s*true\)')):
            body = self.body(fn)
            found = list(re.finditer(call, body))
            self.assertTrue(found, fn)
            for m in found:
                conditions = guarding_block(body, m.start())
                self.assertTrue(any('lightShadowsReady()' in c or c.strip().endswith(
                    'lightShadow') for c in conditions), (fn, conditions))
        cached = self.body('RendererMetal::cachedVBOPipeline')
        self.assertIn('const bool lightShadow = lightRig && lightShadowsReady();', cached)


SCENE_RENDER = os.path.join(ROOT, 'layer1', 'SceneRender.cpp')

# The classic whole-pixel shadow on master (aea4e74c6): sha256 of each
# function (comments stripped, whitespace removed, the first 16 hex digits),
# and of the classic pre-pass body in SceneRenderMetal (inside the braces of
# its `if`, from `float shadowRadius` to the restore of the camera matrices).
# Taken from master with lighting_msl.py's parsers, never from this branch:
# studio shadows replace the classic pass, they never edit it.
MASTER_CLASSIC = {
    'RendererMetal::beginShadowPass': 'c421447f5f77a489',
    'RendererMetal::endShadowPass': '5dd9374e7be0fb2f',
    'SceneBuildLightViewProjEye': '6b975b5c9dc7bec8',
    'classic pre-pass body': 'b3b5919caf1bbff4',
}
# The statements both passes end with: the scene pass reopened with CLEAR.
# Today's grid code on master (aea4e74c6), hashed as MASTER_CLASSIC is: the
# studio tile atlas (Part 5 of #616) lives in the map pass alone, so the grid
# loops of SceneRenderMetal (from `auto const peeled` to the selection pass),
# SceneSetMetalGridCell and SceneRenderMetalSelections are master's, and so
# is RendererMetal::setGridSlot once its first statement (the stored cell) is
# taken out.
MASTER_GRID = {
    'SceneRenderMetal grid and scene passes': '2f21cf55fa47c5af',
    'SceneSetMetalGridCell': '034aaa521b356a8c',
    'SceneRenderMetalSelections': '37c869d18ac858bd',
}
MASTER_SET_GRID_SLOT = 'bd39d8b8d26168bd'

REOPEN_MARKER = '_passDesc = _scenePassDesc;'


def classic_pre_pass_body(scene_render):
    """The classic pre-pass's body in SceneRenderMetal (inside its braces)."""
    body = cpp_function(scene_render, 'SceneRenderMetal')
    i = body.index('float shadowRadius')
    open_brace = body.rindex('{', 0, i)
    return body[open_brace + 1:match_brace(body, open_brace)]


class TestClassicShadowUnchanged(ShadowMSLCase):
    """Sha pins: the classic pass, its light frustum and the pre-pass body
    are master's."""

    def testClassicCodeIsMasters(self):
        scene_render = read(SCENE_RENDER)
        found = {
            'RendererMetal::beginShadowPass':
                digest(cpp_function(self.mm, 'RendererMetal::beginShadowPass')),
            'RendererMetal::endShadowPass':
                digest(cpp_function(self.mm, 'RendererMetal::endShadowPass')),
            'SceneBuildLightViewProjEye':
                digest(cpp_function(scene_render, 'SceneBuildLightViewProjEye')),
            'classic pre-pass body': digest(classic_pre_pass_body(scene_render)),
        }
        self.assertEqual(found, MASTER_CLASSIC)


class TestMapPass(ShadowMSLCase):
    """The renderer's studio map pass (Part 4 of #616)."""

    def setUp(self):
        super().setUp()
        self.header = strip_comments(read(METAL_H))

    def body(self, name):
        return strip_block_comments(cpp_function(self.mm, name))

    def testArray(self):
        ensure = self.body('RendererMetal::ensureLightShadowArray')
        for text in ('d.textureType = MTLTextureType2DArray;',
                     'd.pixelFormat = MTLPixelFormatDepth32Float;',
                     'd.arrayLength = kLightRigBlockShadowSlots;',
                     'd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;',
                     'd.storageMode = MTLStorageModePrivate;',
                     '_lightShadowPassDesc.depthAttachment.texture = _lightShadowArray;'):
            self.assertIn(text, ensure)
        # kept while the size holds; reallocated only when it changes
        keep = re.search(r'if\s*\(\s*_lightShadowArray && _lightShadowArraySize == size\s*\)'
                         r'\s*return true;', ensure)
        self.assertIsNotNone(keep)
        self.assertLess(keep.start(), ensure.index('[_lightShadowArray release];'))
        self.assertEqual(ensure.count('newTextureWithDescriptor'), 1)
        self.assertLess(keep.start(), ensure.index('newTextureWithDescriptor'))
        # a size that could not be allocated is not retried every frame
        self.assertRegex(ensure, r'if\s*\(\s*size == _lightShadowArrayFailedSize\s*\)'
                                 r'\s*return false;')
        # only the map pass allocates; nothing releases the array per frame
        self.assertEqual(len(re.findall(r'(?<!::)\bensureLightShadowArray\(\)',
                                        self.code)), 1)
        self.assertIn('ensureLightShadowArray()',
                      self.body('RendererMetal::beginLightShadowMap'))
        self.assertEqual(len(re.findall(r'\[_lightShadowArray release\]', self.code)), 2)
        dtor = self.body('RendererMetal::~RendererMetal')
        self.assertIn('[_lightShadowArray release];', dtor)
        self.assertIn('[_lightShadowPassDesc release];', dtor)
        for fn in ('RendererMetal::beginFrame', 'RendererMetal::setLightShadowFrame'):
            self.assertNotIn('_lightShadowArray', self.body(fn), fn)
        # setLightShadowFrame stores two scalars, no GPU call
        frame = squash(self.body('RendererMetal::setLightShadowFrame'))
        self.assertEqual(frame, '{_lightStudioShadows=studioShadows;'
                                '_lightShadowSize=studioShadows&&mapSize>0?mapSize:0;}')

    def testBeginMap(self):
        begin = self.body('RendererMetal::beginLightShadowMap')
        # everything that can fail is checked before the open encoder ends
        end_open = begin.index('[_encoder endEncoding]')
        for check in ('!_vboShadowPipelineUByte', '!_shadowSampler',
                      'ensureLightShadowArray()', '!_lightStudioShadows',
                      'slot >= kLightRigBlockShadowSlots'):
            self.assertLess(begin.index(check), end_open, check)
        # the slot's slice, cleared, then Load for any mid-slice reopen
        slice_ = begin.index('_lightShadowPassDesc.depthAttachment.slice = (NSUInteger)slot;')
        clear = begin.index('_lightShadowPassDesc.depthAttachment.loadAction = '
                            'MTLLoadActionClear;')
        opened = begin.index('_encoder = [_cmdBuffer renderCommandEncoderWithDescriptor:'
                             '_lightShadowPassDesc];')
        load = begin.index('_lightShadowPassDesc.depthAttachment.loadAction = '
                           'MTLLoadActionLoad;')
        self.assertTrue(end_open < slice_ < opened < load, begin)
        self.assertLess(clear, opened)
        self.assertIn('_passDesc = _lightShadowPassDesc;', begin)
        # the every-encoder invariant
        self.assertLess(opened, begin.index('bindNeutralMaterialU(_encoder);'))
        self.assertLess(opened, begin.index('bindEnvironment(_encoder);'))
        # depth-only pipelines, the full slice, light-POV depth state, no cull
        for text in ('_shadowMode = true;', '_lightShadowSlotOpen = slot;',
                     '_lightShadowPassActive = true;',
                     'std::memcpy(_lightShadowView, view, sizeof(_lightShadowView));',
                     'MTLViewport vp = {0.0, 0.0, side, side, 0.0, 1.0};',
                     '[_encoder setViewport:vp];', '[_encoder setScissorRect:sr];',
                     '[_encoder setDepthStencilState:_shadowDepthState];',
                     '[_encoder setCullMode:MTLCullModeNone];',
                     '++_lightShadowSlicesOpened;'):
            self.assertIn(text, begin)
        self.assertIn('const double side = (double)_lightShadowArraySize;', begin)
        # never the classic map's validity or the camera's viewport
        self.assertNotIn('_shadowMapValid', begin)
        self.assertNotRegex(begin, r'\b_viewport\b')
        self.assertNotIn('_scenePassDesc', begin)

    def testEndMaps(self):
        end = self.body('RendererMetal::endLightShadowMaps')
        self.assertRegex(end, r'^\{\s*if\s*\(\s*!_lightShadowPassActive\s*\)\s*return\s*;')
        for text in ('_lightShadowPassActive = false;', '_shadowMode = false;',
                     '_lightShadowSlotOpen = -1;'):
            self.assertIn(text, end)
        self.assertNotIn('_shadowMapValid', end)
        # ready only when every planned map (head.w) was rendered
        ready = re.search(r'_lightShadowMapsReady\s*=([^;]*);', end)
        self.assertIsNotNone(ready)
        self.assertEqual(squash(ready.group(1)),
                         '_lightRigOn&&!_lightShadowFailed&&_lightShadowSlicesOpened>0'
                         '&&_lightShadowSlicesOpened==(int)_lightRigBlock.head[3]')
        self.assertLess(end.index('_lightShadowSlotOpen = -1;'), end.index(REOPEN_MARKER))
        # the one reopen: endShadowPass's statements, verbatim
        classic = self.body('RendererMetal::endShadowPass')
        self.assertEqual(squash(end[end.index(REOPEN_MARKER):]),
                         squash(classic[classic.index(REOPEN_MARKER):]))
        self.assertEqual(end.count('renderCommandEncoderWithDescriptor'), 1)

    def testOnlyTheMapPassMakesTheMapsReady(self):
        owners = []
        for m in re.finditer(r'\b_lightShadowMapsReady\s*=(?!=)', self.code):
            owners.append(re.findall(r'^[\w<>:\*\s]*RendererMetal::(\w+)\s*\(',
                                     self.code[:m.start()], re.M)[-1])
        self.assertEqual(sorted(owners), ['beginFrame', 'endLightShadowMaps'])
        self.assertIn('_lightShadowMapsReady = false;', self.body('RendererMetal::beginFrame'))

    def testBeginFrameResets(self):
        begin = self.body('RendererMetal::beginFrame')
        for text in ('_lightShadowMapsReady = false;', '_lightStudioShadows = false;',
                     '_lightShadowSlotOpen = -1;', '_lightShadowPassActive = false;',
                     '_lightShadowSlicesOpened = 0;', '_lightShadowFailed = false;'):
            self.assertIn(text, begin)
        self.assertRegex(self.header, r'int _lightShadowSlotOpen = -1;')
        self.assertRegex(self.header, r'bool _lightStudioShadows = false;')

    def testPremultiplyOnlyWhileASliceIsOpen(self):
        load = self.body('RendererMetal::loadMatrixf')
        block = re.search(r'if\s*\(\s*_matrixMode == 0 && _lightShadowSlotOpen >= 0\s*\)\s*\{',
                          load)
        self.assertIsNotNone(block)
        inside = load[block.end():match_brace(load, block.end() - 1)]
        self.assertIn('std::memcpy(lightView.data(), _lightShadowView, 16 * sizeof(float));',
                      inside)
        self.assertIn('mat = multiplyMatrices(lightView, mat);', inside)
        # before the inverse is taken, so the inverse is the stored matrix's
        self.assertLess(block.start(), load.index('simd_inverse'))
        self.assertEqual(load.count('_lightShadowSlotOpen'), 1)
        identity = self.body('RendererMetal::loadIdentity')
        self.assertRegex(identity, r'_modelviewMatrix = identityMatrix\(\);\s*'
                                   r'if\s*\(\s*_lightShadowSlotOpen >= 0\s*\)\s*'
                                   r'std::memcpy\(_modelviewMatrix\.data\(\), _lightShadowView,')
        # the slot opens only in beginLightShadowMap and closes at its end and
        # at every frame start
        owners = {}
        for m in re.finditer(r'\b_lightShadowSlotOpen\s*=(?!=)\s*([^;]*);', self.code):
            owner = re.findall(r'^[\w<>:\*\s]*RendererMetal::(\w+)\s*\(',
                               self.code[:m.start()], re.M)[-1]
            owners.setdefault(owner, []).append(m.group(1).strip())
        self.assertEqual(owners, {'beginFrame': ['-1'], 'beginLightShadowMap': ['slot'],
                                  'endLightShadowMaps': ['-1']})
        # the other matrix calls post-multiply, as before
        for fn in ('RendererMetal::multMatrixf', 'RendererMetal::translatef',
                   'RendererMetal::scalef', 'RendererMetal::popMatrix'):
            self.assertNotIn('_lightShadow', self.body(fn), fn)

    def testImpostorsRayCastFromTheLight(self):
        for fn in ('RendererMetal::drawSphereImpostors',
                   'RendererMetal::drawCylinderImpostors'):
            body = self.body(fn)
            self.assertEqual(re.findall(r'\bu\.ortho\s*=\s*([^;]*);', body),
                             ['_lightShadowSlotOpen >= 0 ? 0.0f : (float)call.ortho'], fn)

    def testMapsBoundOnlyWithTheRigWhenReady(self):
        bind = self.body('RendererMetal::bindLightRig')
        self.assertRegex(bind, r'^\{\s*if\s*\(\s*!_lightRigOn\s*\)\s*return\s*;')
        block = re.search(r'if\s*\(\s*_lightShadowMapsReady\s*\)\s*\{', bind)
        self.assertIsNotNone(block)
        inside = bind[block.end():match_brace(bind, block.end() - 1)]
        self.assertIn('[enc setFragmentTexture:_lightShadowArray '
                      'atIndex:kLightShadowTextureIndex];', inside)
        self.assertIn('[enc setFragmentSamplerState:_shadowSampler '
                      'atIndex:kLightShadowSamplerIndex];', inside)
        # the whole slice without a grid
        self.assertEqual(re.findall(r'block\.shadowTile\[(\d)\]\s*=\s*([\d.]+)f;', inside),
                         [('0', '0.0'), ('1', '0.0'), ('2', '1.0'), ('3', '1.0')])
        self.assertLess(block.end(), bind.index('setFragmentBytes:&block'))
        # nowhere else
        for index in ('kLightShadowTextureIndex', 'kLightShadowSamplerIndex'):
            self.assertEqual(self.code.count('atIndex:%s' % index), 1, index)

    def testWholePixelShadowOffWithStudioShadows(self):
        post = self.body('RendererMetal::runPostChain')
        self.assertIn('bool doShadow = _ssaoPipeline && _shadowEnabled && !noShadow && '
                      '!_lightStudioShadows;', post)
        self.assertIn('u.rtShadow = (_rtShadowEnabled && !_lightStudioShadows) ? 1.0f : 0.0f;',
                      post)
        self.assertEqual(len(re.findall(r'\bu\.rtShadow\s*=', self.code)), 1)
        self.assertEqual(len(re.findall(r'\bbool doShadow\s*=', self.code)), 1)
        # the composite's shadow intensity and the raster map follow doShadow
        self.assertIn('bool doShadowMap = doShadow && _shadowMapValid;', post)
        self.assertRegex(post, r'u\.shadowIntensity =\s*\(doShadow &&')


class TestSceneRenderPass(ShadowMSLCase):
    """SceneRenderMetal's studio pre-pass (Part 4 of #616)."""

    def setUp(self):
        super().setUp()
        self.scene_render = read(SCENE_RENDER)
        self.render = cpp_function(self.scene_render, 'SceneRenderMetal')
        self.maps = cpp_function(self.scene_render, 'SceneRenderLightShadowMaps')

    def testTheFrameIsReadOnceAndHandedOver(self):
        body = self.render
        self.assertEqual(body.count('SceneLightsFrame('), 1)
        self.assertRegex(body, r'\blights = SceneLightsFrame\(G,\s*glm::dmat4\('
                               r'glm::make_mat4\(mv\)\)\);')
        calls = re.findall(r'setLightShadowFrame\(([^;]*)\);', body)
        self.assertEqual([squash(c) for c in calls],
                         ['lights.studioShadows,lights.shadowMapSize'])
        self.assertLess(body.index('setLightRig('), body.index('setLightShadowFrame('))
        self.assertLess(body.index('setLightShadowFrame('), body.index('SceneRenderAll('))

    def testStudioMapsReplaceTheClassicPass(self):
        body = self.render
        m = re.search(r'if\s*\(\s*lights\.shadows\s*\)\s*\{\s*'
                      r'SceneRenderLightShadowMaps\(G,\s*&context,\s*normal,\s*'
                      r'\*lights\.shadows\);\s*\}\s*else if\s*\(\s*!lights\.studioShadows'
                      r'\s*&&\s*!I->grid\.active\s*&&\s*SettingGetGlobal_b\(G,\s*'
                      r'cSetting_metal_shadows\)\s*\)\s*\{\s*float shadowRadius', body)
        self.assertIsNotNone(m)
        self.assertEqual(body.count('SceneRenderLightShadowMaps('), 1)
        self.assertEqual(body.count('beginShadowPass()'), 1)
        # the studio maps run before every scene pass
        self.assertLess(m.start(), body.index('SceneRenderAll('))
        self.assertLess(m.start(), body.index('SceneRenderTransparentMetal('))
        # only SceneRenderMetal runs them
        self.assertEqual(len(re.findall(r'\bSceneRenderLightShadowMaps\(',
                                        strip_comments(self.scene_render))), 2)

    def testThePassDrawsEveryCasterButTheOverlays(self):
        maps = self.maps
        self.assertRegex(maps, r'const std::vector<pymol::CObject\*> overlays = '
                               r'SceneLightShadowOverlays\(G\);')
        calls = re.findall(r'SceneRenderAll\(([^;]*)\);', maps)
        # one draw per slice without a grid, one per cell with it
        self.assertEqual(len(calls), 2)
        for call in calls:
            self.assertEqual(squash(call),
                             'G,context,normal,nullptr,RenderPass::Opaque,false,0.0f,&I->grid,'
                             '0,SceneRenderWhich::All,SceneRenderOrder::GadgetsLast,nullptr,'
                             '&overlays')
        # never a grid cell or the RT cell table
        for call in ('SceneSetMetalGridCell', 'setGridSlot'):
            self.assertNotIn(call, maps)

    def testMatricesAreLoadedPerSliceAndRestored(self):
        maps = self.maps
        loop = re.search(r'for\s*\(\s*int slot = 0;\s*slot < shadows\.count;\s*\+\+slot\s*\)'
                         r'\s*\{', maps)
        self.assertIsNotNone(loop)
        inside = maps[loop.end():match_brace(maps, loop.end() - 1)]
        begin = re.search(r'if\s*\(\s*!G->Renderer->beginLightShadowMap\(\s*slot,\s*'
                          r'glm::value_ptr\(shadows\.view\[slot\]\.view\)\)\s*\)\s*break;',
                          inside)
        self.assertIsNotNone(begin)
        proj = inside.index('loadMatrixf(glm::value_ptr(shadows.view[slot].proj));')
        cam = inside.index('loadMatrixf(mv);')
        draw = inside.index('SceneRenderAll(')
        self.assertTrue(begin.end() <= proj < cam < draw, inside)
        self.assertLess(inside.index('matrixMode(0x1701)'), proj)
        self.assertLess(inside.index('matrixMode(0x1700)'), cam)
        self.assertIn('const float* mv = SceneGetModelViewMatrixPtr(G);', maps)
        after = maps[match_brace(maps, loop.end() - 1):]
        end = after.index('G->Renderer->endLightShadowMaps();')
        restore = re.search(r'matrixMode\(0x1701\);\s*G->Renderer->loadMatrixf\('
                            r'SceneGetProjectionMatrixPtr\(G\)\);\s*G->Renderer->'
                            r'matrixMode\(0x1700\);\s*G->Renderer->loadMatrixf\(mv\);', after)
        self.assertIsNotNone(restore)
        self.assertLess(end, restore.start())

    def testGridFramesDrawEachCellIntoItsTile(self):
        maps = self.maps
        # no early return for grid frames any more
        self.assertRegex(maps, r'^\{\s*CScene\* I = G->Scene;\s*const std::vector')
        loop = re.search(r'for\s*\(\s*int slot = 0;\s*slot < shadows\.count;\s*\+\+slot\s*\)'
                         r'\s*\{', maps)
        inside = maps[loop.end():match_brace(maps, loop.end() - 1)]
        grid = re.search(r'if\s*\(\s*I->grid\.active\s*\)\s*\{', inside)
        self.assertIsNotNone(grid)
        # after the slice opens and the matrices are loaded
        self.assertLess(inside.index('loadMatrixf(mv);'), grid.start())
        branch = inside[grid.end():match_brace(inside, grid.end() - 1)]
        cells = re.search(r'for\s*\(\s*int cell = I->grid\.first_slot;\s*'
                          r'cell <= I->grid\.last_slot;\s*\+\+cell\s*\)\s*\{', branch)
        self.assertIsNotNone(cells)
        cell = branch[cells.end():match_brace(branch, cells.end() - 1)]
        tile = re.search(r'const pymol::LightShadowTile tile = pymol::LightShadowTileRect\('
                         r'\s*cell - I->grid\.first_slot,\s*shadows\.tiles,\s*shadows\.size\);',
                         cell)
        self.assertIsNotNone(tile)
        skip = re.search(r'if\s*\(\s*tile\.size <= 0\s*\)\s*continue;', cell)
        viewport = re.search(r'G->Renderer->setLightShadowViewport\(\s*tile\.x,\s*tile\.y,'
                             r'\s*tile\.size,\s*tile\.size\);', cell)
        slot = cell.index('I->grid.slot = cell;')
        draw = cell.index('SceneRenderAll(')
        self.assertIsNotNone(skip)
        self.assertIsNotNone(viewport)
        self.assertTrue(tile.end() <= skip.start() < viewport.start() < slot < draw, cell)
        # the grid slot is reset after the cells, and only set to a cell
        after = branch[match_brace(branch, cells.end() - 1):]
        self.assertRegex(after, r'^\}\s*I->grid\.slot = 0;')
        self.assertEqual(re.findall(r'I->grid\.slot\s*=\s*([^;]*);', maps), ['cell', '0'])
        # nothing in the pass touches the camera viewport, the scissor or the
        # ray tracer's cell table
        for call in ('SceneSetMetalGridCell', 'setGridSlot', 'Renderer->viewport(',
                     'Renderer->scissor(', 'ScissorTest', 'cur_viewport_size'):
            self.assertNotIn(call, maps, call)
        # only the map pass picks a tile
        self.assertEqual(len(re.findall(r'\bsetLightShadowViewport\(',
                                        strip_comments(self.scene_render))), 1)

    def testTheGridLoopsAreMasters(self):
        body = self.render
        start = body.index('auto const peeled')
        end = body.index('if (G->Renderer && G->Renderer->hasActiveEncoder())')
        found = {
            'SceneRenderMetal grid and scene passes': digest(body[start:end]),
            'SceneSetMetalGridCell':
                digest(cpp_function(self.scene_render, 'SceneSetMetalGridCell')),
            'SceneRenderMetalSelections':
                digest(cpp_function(self.scene_render, 'SceneRenderMetalSelections')),
        }
        self.assertEqual(found, MASTER_GRID)


class TestGridTiles(ShadowMSLCase):
    """The renderer's side of the grid tile atlas (Part 5 of #616)."""

    def setUp(self):
        super().setUp()
        self.header = strip_comments(read(METAL_H))

    def body(self, name):
        return strip_block_comments(cpp_function(self.mm, name))

    def testSetGridSlotStoresTheCellFirst(self):
        body = self.body('RendererMetal::setGridSlot')
        self.assertRegex(body, r'^\{\s*_currentGridSlot = slot;')
        self.assertLess(body.index('_currentGridSlot = slot;'), body.index('return'))
        # the rest is master's (the RT cell table, #478)
        self.assertEqual(digest(body.replace('_currentGridSlot = slot;', '', 1)),
                         MASTER_SET_GRID_SLOT)
        # only setGridSlot and the frame start write it
        owners = {}
        for m in re.finditer(r'\b_currentGridSlot\s*=(?!=)\s*([^;]*);', self.code):
            owner = re.findall(r'^[\w<>:\*\s]*RendererMetal::(\w+)\s*\(',
                               self.code[:m.start()], re.M)[-1]
            owners.setdefault(owner, []).append(m.group(1).strip())
        self.assertEqual(owners, {'beginFrame': ['0'], 'setGridSlot': ['slot']})
        self.assertRegex(self.header, r'int _currentGridSlot = 0;')

    def testEachDrawReadsItsCellsTile(self):
        bind = self.body('RendererMetal::bindLightRig')
        block = re.search(r'if\s*\(\s*_lightShadowMapsReady\s*\)\s*\{', bind)
        inside = bind[block.end():match_brace(bind, block.end() - 1)]
        first = re.search(r'const int firstGridSlot = \(int\)_lightRigBlock\.shadowGrid\[1\];',
                          inside)
        self.assertIsNotNone(first)
        no_grid = re.search(r'if\s*\(\s*firstGridSlot <= 0\s*\)\s*\{', inside)
        self.assertIsNotNone(no_grid)
        whole = inside[no_grid.end():match_brace(inside, no_grid.end() - 1)]
        self.assertEqual(re.findall(r'block\.shadowTile\[(\d)\]\s*=\s*([\d.]+)f;', whole),
                         [('0', '0.0'), ('1', '0.0'), ('2', '1.0'), ('3', '1.0')])
        rest = inside[match_brace(inside, no_grid.end() - 1) + 1:]
        grid = re.match(r'\s*else\s*\{', rest)
        self.assertIsNotNone(grid)
        cell = rest[grid.end():match_brace(rest, grid.end() - 1)]
        self.assertEqual(
            squash(cell),
            'constpymol::LightShadowTiletile=pymol::LightShadowTileRect('
            '_currentGridSlot-firstGridSlot,(int)_lightRigBlock.shadowGrid[0],'
            '_lightShadowArraySize);'
            'std::memcpy(block.shadowTile,tile.uv,sizeof(block.shadowTile));')
        # the tile is written before the block is bound
        self.assertLess(block.end(), bind.index('setFragmentBytes:&block'))
        self.assertIn('#include "LightShadows.h"', self.mm)

    def testTileViewportIsTheEncodersOnly(self):
        body = self.body('RendererMetal::setLightShadowViewport')
        self.assertRegex(body, r'^\{\s*if\s*\(\s*_lightShadowSlotOpen < 0 \|\| !_encoder\s*\)'
                               r'\s*return;')
        self.assertIn('const int side = _lightShadowArraySize;', body)
        for v in ('x', 'y'):
            self.assertIn('%s = std::clamp(%s, 0, side);' % (v, v), body)
        self.assertIn('w = std::clamp(w, 0, side - x);', body)
        self.assertIn('h = std::clamp(h, 0, side - y);', body)
        self.assertRegex(body, r'if\s*\(\s*w <= 0 \|\| h <= 0\s*\)\s*return;')
        self.assertIn('[_encoder setViewport:vp];', body)
        self.assertIn('[_encoder setScissorRect:sr];', body)
        # never the camera's viewport or scissor state
        for name in ('_viewport', '_scissorRect', '_scissorEnabled', '_renderScale'):
            self.assertNotRegex(body, r'\b%s\b' % name, name)
        self.assertRegex(self.header,
                         r'void setLightShadowViewport\(int x, int y, int w, int h\) override;')

    def testBeginFrameClearsTheCell(self):
        self.assertIn('_currentGridSlot = 0;', self.body('RendererMetal::beginFrame'))
