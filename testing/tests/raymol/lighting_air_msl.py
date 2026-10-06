"""The air (haze and dust, #618) in the Metal shaders and the post chain, from
source.

The air is MSL compiled at run time (kAirSrc in layerGraphics/metal/
RendererMetal.mm) and CI has no GPU: a library that fails to compile is one
NSLog and a frame without air. These checks pin, from the source, what L1,
the regression renders against master, L2 and L3 prove on a Mac:

* TestMasterUnchanged: every shader literal that master has is master's
  (sha256 of the comment-stripped, whitespace-free text, taken from master
  83dd31bbe with these parsers, never from this branch), kAirSrc is the only
  new one, and runPostChain, beginFrame, SceneRenderMetal and
  SceneLightsFrame are master's once the air's own statement is taken out;
* TestLibrary: kAirSrc is built once, as kEyeReconSrc + kMaterialSrc +
  kAirSrc, inside ensureAirPipelines (one attempt, every failure logged in
  the L4 console's words, everything but the pipeline released), which only
  runPostChain's air statement reaches; its functions come from airFunction,
  the tube rig library's fallback (constant indices 0, 1 and 2); it defines
  only post_air_ functions, LightAirU and AirVOut, and declares no function
  constant, no rig or shadow token and nothing at the lit libraries' rig and
  map indices;
* TestLayout: LightAirU mirrors layer1/LightAirBlock.h field for field, and
  post_air_vertex is kPostSrc's post_vertex;
* TestShadows: the haze's one-tap lookup is light_shadow_lookup with its 3x3
  replaced by one compare (a drift guard); every light with a map this frame
  shadows the air (no single shadow light); the far-plane pull-back runs
  before both lookups; motes, and the haze at filter 2, take the lookup
  verbatim;
* TestModel: the caps, step counts and scatter clamp equal layer1/LightAir.h's
  constants; the cone is light_terms_view's (a drift guard); the haze has no
  time term and the dust does; the composite only adds light, through
  light_finish; the NaN guards;
* TestPostChain: one air statement, between Pass 1 (raster or traced) and the
  OIT resolve; encodeAirPass ping-pongs on _cmdBuffer, binds only its own
  indices and value copies of the blocks (the whole slice as the tile, no
  maps unless they were rendered, the stand-in then), never bindLightRig;
  the destructor releases what the air made;
* TestSceneRender: SceneRenderMetal hands the air to the renderer once,
  after the rig and the GPU timing, before anything draws (lighting_air.py
  pins the two statements' text).

Pure source parsing (skipped, not passed, outside a repo checkout; in a
checkout a missing source file fails).

    pymol -ckqy testing/testing.py --run testing/tests/raymol/lighting_air_msl.py
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
AIR_H = os.path.join(ROOT, 'layer1', 'LightAir.h')
AIR_BLOCK_H = os.path.join(ROOT, 'layer1', 'LightAirBlock.h')
SCENE_RENDER = os.path.join(ROOT, 'layer1', 'SceneRender.cpp')
SCENE_LIGHTS = os.path.join(ROOT, 'layer1', 'SceneLights.cpp')


def _load_lighting_msl():
    """lighting_msl.py's parsers (shader_literals, msl_functions,
    cpp_function, squash...), loaded by path under a private name so its
    test cases are not collected a second time."""
    spec = importlib.util.spec_from_file_location(
        '_lighting_air_msl_parsers', os.path.join(HERE, 'lighting_msl.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


_msl = _load_lighting_msl()
shader_literals = _msl.shader_literals
strip_comments = _msl.strip_comments
msl_functions = _msl.msl_functions
cpp_function = _msl.cpp_function
match_brace = _msl.match_brace
squash = _msl.squash
depth_at = _msl.depth_at

# Master 83dd31bbe (#670's merge, the branch's base): sha256 of each shader
# literal, comments stripped and whitespace removed, the first 16 hex digits.
# Taken from master with these parsers, never from this branch.
MASTER_LITERALS = {
    'kBezierTubeRigSrc': 'c15ddac6015e66dc',
    'kBezierTubeSrc': '0085bdbf88964ab4',
    'kConnectorShaderSrc': '40ef57a0e535d985',
    'kCylinderImpostorSrc': '637f7d7546fb17e3',
    'kEyeReconSrc': '34e775c149c8b075',
    'kLabelShaderSrc': 'e9739e2374962609',
    'kMaterialImpostorSrc': '5da7ac9fc2e8eb42',
    'kMaterialSrc': 'da47cac063348d43',
    'kPostSrc': 'c13f90740b5420b8',
    'kRTSrc': 'c3f2065ac121a166',
    'kSphereImpostorSrc': '1ed9ba64205bd960',
    'kVBOSrc': '728416d46e47293d',
}
# The same digests of four functions on master (cpp_function's body, braces
# included, comments stripped); on this branch with the air's statement
# taken out (AIR_STATEMENTS).
MASTER_FUNCTIONS = {
    ('RendererMetal.mm', 'RendererMetal::runPostChain'): '4f0c6097ac77fcb0',
    ('RendererMetal.mm', 'RendererMetal::beginFrame'): 'a943ed9e4b89cda5',
    ('SceneRender.cpp', 'SceneRenderMetal'): '1b36877a11862fd2',
    ('SceneLights.cpp', 'SceneLightsFrame'): '5fb060d63ab0d96b',
}
AIR_STATEMENTS = {
    'RendererMetal::runPostChain': re.compile(r'if\s*\(\s*_lightAirOn\b[^;]*;'),
    'RendererMetal::beginFrame': re.compile(r'_lightAirOn\s*=\s*false\s*;'),
    'SceneRenderMetal': re.compile(
        r'const auto air = SceneLightsAir\(G, lights\);\s*'
        r'G->Renderer->setLightAir\(air \? &\*air : nullptr\);'),
    'SceneLightsFrame': re.compile(
        r'if\s*\(frame\.rig && pymol::LightAirActive\(rig->air\)\)\s*'
        r'frame\.airSource\s*=[^;]*;'),
}

# #616's shadow tokens (lighting_shadow_msl.py): never in another library.
SHADOW_TOKENS = re.compile(r'\bkLightShadow\b|\blightShadow\w*|\w+_shadowed\b')
# The structs the rig owns (lighting_msl.py STRUCTS).
RIG_STRUCTS = re.compile(r'\bstruct\s+(?:LightRig\w*|LightResponse|LightTerms)\b')

# The MSL constants and their layer1/LightAir.h names.
CONSTANTS = (('kAirHazeSteps', 'kLightAirHazeSteps'),
             ('kAirDustLayers', 'kLightAirDustLayers'),
             ('kAirHazePhaseCap', 'kLightAirHazePhaseCap'),
             ('kAirDustPhaseCap', 'kLightAirDustPhaseCap'),
             ('kAirFalloffCap', 'kLightAirFalloffCap'),
             ('kAirMaxScatter', 'kLightAirMaxScatter'))

AIR_INDICES = (('kAirParamsBufferIndex', 0), ('kAirRigBufferIndex', 1),
               ('kAirColorTextureIndex', 0), ('kAirDepthTextureIndex', 1),
               ('kAirMapsTextureIndex', 2), ('kAirPostSamplerIndex', 0),
               ('kAirMapsSamplerIndex', 1))


def digest(text):
    return hashlib.sha256(squash(text).encode()).hexdigest()[:16]


def read(path):
    with open(path, encoding='utf-8') as handle:
        return handle.read()


def statements(body, first, last):
    """The text of `body` from the statement starting `first` to the end of
    the statement starting `last` (its `;`)."""
    start = body.index(first)
    end = body.index(';', body.index(last, start)) + 1
    return body[start:end]


class AirMSLCase(testing.PyMOLTestCase):

    def setUp(self):
        # As lighting_msl.py: skipped outside a checkout (decided by
        # RendererMetal.mm alone), and before the base setUp.
        if not os.path.isfile(METAL_MM):
            self.skipTest('%s not present; not a repo checkout' % METAL_MM)
        for path in (METAL_H, AIR_H, AIR_BLOCK_H, SCENE_RENDER, SCENE_LIGHTS):
            if not os.path.isfile(path):
                self.fail('%s is missing from the checkout' % path)
        super().setUp()
        self.mm = read(METAL_MM)
        self.code = strip_comments(self.mm)
        self.header = strip_comments(read(METAL_H))
        self.msl = shader_literals(self.mm)
        self.air = self.msl['kAirSrc']
        self.air_code = strip_comments(self.air)
        self.functions = msl_functions(self.air)
        self.material = msl_functions(self.msl['kMaterialSrc'])

    def body(self, name):
        return cpp_function(self.mm, name)

    def fn(self, name):
        """kAirSrc's `name`, signature and body."""
        self.assertIn(name, self.functions)
        sig, body = self.functions[name]
        return sig, body


class TestMasterUnchanged(AirMSLCase):

    def testEveryMasterLiteralIsMasters(self):
        for name, want in sorted(MASTER_LITERALS.items()):
            self.assertIn(name, self.msl)
            self.assertEqual(digest(strip_comments(self.msl[name])), want, name)
        self.assertEqual(set(self.msl) - set(MASTER_LITERALS), {'kAirSrc'})

    def testFunctionsAreMastersWithoutTheAir(self):
        sources = {'RendererMetal.mm': self.mm,
                   'SceneRender.cpp': read(SCENE_RENDER),
                   'SceneLights.cpp': read(SCENE_LIGHTS)}
        for (path, name), want in sorted(MASTER_FUNCTIONS.items()):
            body = cpp_function(sources[path], name)
            statement = AIR_STATEMENTS[name]
            self.assertEqual(len(statement.findall(body)), 1, name)
            self.assertEqual(digest(statement.sub('', body, count=1)), want, name)


class TestLibrary(AirMSLCase):

    def testBuiltOnceWithBothBlocks(self):
        builds = []
        for m in re.finditer(r'newLibraryWithSource:(.*?)\boptions:', self.code, re.S):
            names = [n for n in re.findall(r'\b(k\w+Src)\b', m.group(1))
                     if n in self.msl]
            if 'kAirSrc' in names:
                builds.append((m.start(), names))
        self.assertEqual(len(builds), 1)
        self.assertEqual(builds[0][1], ['kEyeReconSrc', 'kMaterialSrc', 'kAirSrc'])
        ensure = self.body('RendererMetal::ensureAirPipelines')
        self.assertIn('newLibraryWithSource:[[kEyeReconSrc stringByAppendingString:'
                      'kMaterialSrc]', ensure)
        self.assertEqual(ensure.count('newLibraryWithSource:'), 1)
        # the only caller: runPostChain's air statement
        calls = re.findall(r'(?<!::)\bensureAirPipelines\(\)', self.code)
        self.assertEqual(len(calls), 1)
        self.assertIn('ensureAirPipelines()', self.body('RendererMetal::runPostChain'))
        self.assertRegex(self.header, r'bool ensureAirPipelines\(\);')

    def testOneAttemptLoggedOnce(self):
        ensure = self.body('RendererMetal::ensureAirPipelines')
        self.assertRegex(ensure, r'^\{\s*if\s*\(\s*_airFullPipeline\s*\)\s*return true;'
                                 r'\s*if\s*\(\s*_airPipelinesTried\s*\)\s*return false;'
                                 r'\s*_airPipelinesTried = true;')
        self.assertLess(ensure.index('_airPipelinesTried = true;'),
                        ensure.index('newLibraryWithSource:'))
        logs = re.findall(r'NSLog\(@"([^"]*)"', ensure)
        self.assertTrue(logs)
        for text in logs:
            # what the L4 console check greps for
            self.assertRegex(text, r'^RendererMetal: air .*(fail|missing)', text)
        # only the pipeline state is kept
        for released in ('[lib release];', '[vfn release];', '[ffn release];',
                         '[pd release];'):
            self.assertIn(released, ensure)
        self.assertEqual(ensure.count('newRenderPipelineStateWithDescriptor:'), 1)
        self.assertIn('pd.rasterSampleCount = 1;', ensure)
        self.assertIn('pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;',
                      ensure)
        self.assertNotIn('depthAttachmentPixelFormat', ensure)
        # the maps' stand-in in the same attempt
        self.assertIn('ensureAirNoMaps()', ensure)
        self.assertEqual(len(re.findall(r'(?<!::)\bensureAirNoMaps\(\)', self.code)), 1)
        self.assertRegex(self.header, r'bool _airPipelinesTried = false;')

    def testFunctionsComeFromAirFunction(self):
        ensure = self.body('RendererMetal::ensureAirPipelines')
        self.assertNotIn('newFunctionWithName', ensure)
        self.assertEqual(re.findall(r'airFunction\(lib, @"(\w+)"\)', ensure),
                         ['post_air_vertex', 'post_air_full'])
        # bezierTubeRigFunction's logic, its log text aside
        air = cpp_function(self.mm, 'airFunction')
        tube = cpp_function(self.mm, 'bezierTubeRigFunction')

        def normal(body):
            return squash(re.sub(r'NSLog\(@"[^"]*"', 'NSLog(@""', body))
        self.assertEqual(normal(air), normal(tube))
        for index in ('atIndex:0]', 'atIndex:kLightRigConstantIndex]',
                      'atIndex:kLightShadowConstantIndex]'):
            self.assertIn(index, air)
        self.assertIn('int fam = cMaterialFamily_default;', air)
        self.assertIn('bool rig = false;', air)
        self.assertIn('bool shadow = false;', air)

    def testDefinesOnlyAirFunctionsAndStructs(self):
        self.assertTrue(self.functions)
        for name in self.functions:
            self.assertTrue(name.startswith('post_air_'), name)
        for name in ('post_air_vertex', 'post_air_far_pull', 'post_air_shadow_tap',
                     'post_air_visibility', 'post_air_light', 'post_air_ray',
                     'post_air_haze', 'post_air_dust', 'post_air_term',
                     'post_air_finish', 'post_air_full'):
            self.assertIn(name, self.functions)
        self.assertEqual(sorted(re.findall(r'\bstruct\s+(\w+)', self.air_code)),
                         ['AirVOut', 'LightAirU'])
        self.assertNotIn('function_constant', self.air_code)
        self.assertNotRegex(self.air_code, r'\bkLightRig\b|\bkMat[A-Z]\w*')
        self.assertNotRegex(self.air_code, SHADOW_TOKENS)
        self.assertNotRegex(self.air_code, RIG_STRUCTS)
        for index in (r'buffer\(9\)', r'buffer\(13\)', r'texture\(7\)', r'sampler\(7\)'):
            self.assertNotRegex(self.air_code, index)
        # no block comments (they would slip past every check here)
        self.assertNotIn('/*', self.air)

    def testCallsTheSharedHelpers(self):
        for helper in ('post_eye_pos(', 'post_linear_depth(', 'light_shadow_lookup(',
                       'light_finish(', 'mat_hash(', 'mat_noise('):
            self.assertIn(helper, self.air_code, helper)
        for copy in ('float mat_hash(', 'float mat_noise(', 'float3 post_eye_pos(',
                     'LightRigU {'):
            self.assertNotIn(copy, self.air_code, copy)

    def testTheFragmentAndItsArguments(self):
        sig, body = self.fn('post_air_full')
        self.assertTrue(sig.lstrip().startswith('fragment float4 post_air_full('))
        for arg in (r'texture2d<float>\s+colorTex\s*\[\[\s*texture\(0\)\s*\]\]',
                    r'depth2d<float>\s+depthTex\s*\[\[\s*texture\(1\)\s*\]\]',
                    r'depth2d_array<float>\s+maps\s*\[\[\s*texture\(2\)\s*\]\]',
                    r'sampler\s+smp\s*\[\[\s*sampler\(1\)\s*\]\]',
                    r'constant\s+LightAirU\s*&\s*air\s*\[\[\s*buffer\(0\)\s*\]\]',
                    r'constant\s+LightRigU\s*&\s*rig\s*\[\[\s*buffer\(1\)\s*\]\]'):
            self.assertRegex(sig, arg)
        # read at this pixel, never filtered
        self.assertIn('colorTex.read(px)', body)
        self.assertIn('depthTex.read(px)', body)
        self.assertNotIn('.sample(', body)
        self.assertIn('returnfloat4(post_air_finish(c.rgb,t.rgb),c.a);', squash(body))


class TestLayout(AirMSLCase):

    def testAirBlockMirrorsLightAirBlock(self):
        struct = re.search(r'struct\s+LightAirU\s*\{(.*?)\};', self.air_code, re.S)
        self.assertIsNotNone(struct)
        msl = re.findall(r'(\w+)\s+(\w+)\s*;', struct.group(1))
        block = strip_comments(read(AIR_BLOCK_H))
        cpp_struct = re.search(r'struct\s+LightAirBlock\s*\{(.*?)\};', block, re.S)
        self.assertIsNotNone(cpp_struct)
        cpp = re.findall(r'float\s+(\w+)\[4\]\s*;', cpp_struct.group(1))
        self.assertEqual(cpp, ['medium', 'range', 'motion', 'view', 'proj'])
        self.assertEqual(msl, [('float4', name) for name in cpp])

    def testVertexIsPostVertex(self):
        post = msl_functions(self.msl['kPostSrc'])['post_vertex']
        air = self.fn('post_air_vertex')
        self.assertEqual(squash(''.join(air)).replace('AirVOut', 'PostVOut')
                         .replace('post_air_vertex', 'post_vertex'),
                         squash(''.join(post)))
        self.assertRegex(self.air_code, r'struct\s+AirVOut\s*\{\s*float4\s+position\s*'
                                        r'\[\[position\]\];\s*float2\s+uv;\s*\};')


class TestShadows(AirMSLCase):

    def testTapIsTheLookupWithOneCompare(self):
        sig, body = self.fn('post_air_shadow_tap')
        lsig, lbody = self.material['light_shadow_lookup']
        # the signature, name and attribute aside
        self.assertEqual(squash(sig).replace('post_air_shadow_tap', 'NAME')
                         .replace('staticfloat', 'float'),
                         squash(lsig).replace('light_shadow_lookup', 'NAME')
                         .replace('__attribute__((unused))', '')
                         .replace('staticfloat', 'float'))
        # the body: the lookup's 3x3 (the tap spacing to the return) is ONE
        # compare at the centre, the rest verbatim
        loop = re.search(r'const float tap = .*?return lit / 9\.0;', lbody, re.S)
        self.assertIsNotNone(loop)
        one = 'return maps.sample_compare(smp, clamp(uv, lo, hi), uint(slot), fd);'
        self.assertEqual(squash(body),
                         squash(lbody[:loop.start()] + one + lbody[loop.end():]))
        self.assertEqual(body.count('sample_compare'), 1)

    def testEveryShadowedLightShadowsTheAir(self):
        _, body = self.fn('post_air_visibility')
        self.assertIn('const int slot = int(rig.L[i].pos.w);', body)
        self.assertIn('if (slot < 0 || slot >= 3 || slot >= int(rig.head.w)) return 1.0;',
                      body)
        _, light = self.fn('post_air_light')
        self.assertIn('const int n = int(rig.head.x);', light)
        self.assertRegex(light, r'for \(int i = 0; i < 6; \+\+i\) \{\s*if \(i >= n\) break;')
        self.assertRegex(light, r'post_air_visibility\(rig, maps, smp, i,')
        # no single shadow light
        self.assertNotRegex(self.air_code, r'shadowIdx|shadowIndex')

    def testFarPullBeforeBothLookups(self):
        _, body = self.fn('post_air_visibility')
        pull = body.index('post_air_far_pull(rig.S[slot].viewProj, L, dir, dl)')
        self.assertIn('const float3 q = L + dir * t;', body)
        self.assertIn('const float3 ld = -dir;', body)
        lookup = body.index('light_shadow_lookup(rig, maps, smp, slot, q, ld, ld, t)')
        tap = body.index('post_air_shadow_tap(rig, maps, smp, slot, q, ld, ld, t)')
        self.assertLess(pull, lookup)
        self.assertLess(pull, tap)
        # motes and filter 2 take #616's lookup verbatim
        self.assertRegex(body, r'if \(mote \|\| filter > 1\.5\)\s*'
                               r'return light_shadow_lookup\(')
        _, far = self.fn('post_air_far_pull')
        self.assertIn('const float4 a = viewProj * float4(L, 1.0);', far)
        self.assertIn('const float4 b = viewProj * float4(dir, 0.0);', far)
        self.assertIn('const float den = b.z - b.w;', far)
        self.assertIn('if (!(den > 1e-8)) return dl;', far)
        self.assertIn('const float tf = (a.w - a.z) / den;', far)
        self.assertIn('return min(dl, tf * (1.0 - 1e-4));', far)

    def testMotesAndHazeAskForTheirFilters(self):
        _, light = self.fn('post_air_light')
        self.assertIn('-Ld, d, mote, air.motion.w)', light)
        _, haze = self.fn('post_air_haze')
        self.assertRegex(haze, r'post_air_light\(x, -rd, g, kAirHazePhaseCap, false,')
        _, dust = self.fn('post_air_dust')
        self.assertRegex(dust, r'post_air_light\(xp, -rd, g, kAirDustPhaseCap, true,')


class TestModel(AirMSLCase):

    def testConstantsEqualLightAirH(self):
        header = strip_comments(read(AIR_H))
        for msl_name, cpp_name in CONSTANTS:
            m = re.search(r'constant\s+(?:int|float)\s+%s\s*=\s*([0-9.]+)\s*;' % msl_name,
                          self.air_code)
            c = re.search(r'\b%s\s*=\s*([0-9.]+)\s*;' % cpp_name, header)
            self.assertIsNotNone(m, msl_name)
            self.assertIsNotNone(c, cpp_name)
            self.assertEqual(float(m.group(1)), float(c.group(1)), msl_name)
        self.assertRegex(self.air_code, r'constant int kAirHazeSteps = 48;')
        self.assertRegex(self.air_code, r'constant int kAirDustLayers = 32;')
        self.assertRegex(self.air_code, r'constant float kAirHazePhaseCap = 5\.0;')
        self.assertRegex(self.air_code, r'constant float kAirDustPhaseCap = 8\.0;')
        self.assertRegex(self.air_code, r'constant float kAirFalloffCap = 4\.0;')

    def testCapsAndScatter(self):
        _, light = self.fn('post_air_light')
        self.assertIn('min(pow(max(rig.L[i].misc.z / d, 1e-4), rig.L[i].misc.y), '
                      'kAirFalloffCap)', light)
        self.assertIn('pow(max(1.0 + g * g - 2.0 * g * c, 1e-4), 1.5), phMax)', light)
        _, haze = self.fn('post_air_haze')
        self.assertIn('const float g = clamp(air.medium.z, -kAirMaxScatter, '
                      'kAirMaxScatter);', haze)
        self.assertIn('for (int k = 0; k < kAirHazeSteps; ++k)', haze)
        _, dust = self.fn('post_air_dust')
        self.assertRegex(dust, r'const float g = min\(clamp\(air\.medium\.z, '
                               r'-kAirMaxScatter, kAirMaxScatter\) \+ 0\.25,\s*0\.92\);')
        self.assertIn('for (int k = 0; k < kAirDustLayers; ++k)', dust)

    def testConeIsLightTermsViews(self):
        _, light = self.fn('post_air_light')
        _, view = self.material['light_terms_view']
        first, last = 'const float3 Lv =', 'const float spot ='
        self.assertEqual(squash(statements(light, first, last)),
                         squash(statements(view, first, last)))

    def testHazeIsStillAndDustMoves(self):
        _, haze = self.fn('post_air_haze')
        self.assertNotIn('motion.x', haze)
        self.assertIn('const float dens = 0.55 + 0.9 * mat_noise(x * scale);', haze)
        self.assertIn('return acc * (air.medium.x * dz * tPerZ);', haze)
        _, dust = self.fn('post_air_dust')
        self.assertIn('const float T = air.motion.x;', dust)
        for text in ('- drift * T', 'sin(T * fr + ph)', 'sin(T * (1.3 + 2.1 * fr)'):
            self.assertIn(text, dust)
        # a cell holds a mote when its hash is at most the occupancy
        self.assertIn('if (mat_hash(float3(ci, kk)) > air.medium.y) continue;', dust)
        # the mote: rig-size radius, defocus, capped at 0.2 cell
        self.assertIn('air.motion.y * (0.35 + 1.3 * mat_hash(float3(ci, kk + 5.3)))', dust)
        self.assertIn('abs(z - air.range.z) * air.motion.z * size', dust)
        self.assertIn('max(min(size + blur, 0.2 * cell), 1e-3)', dust)
        # layers over the rig frame's range, cut at the first surface
        self.assertIn('(air.range.y - air.range.x) / float(kAirDustLayers)', dust)
        self.assertIn('if (z >= zHi) break;', dust)

    def testCompositeOnlyAddsLight(self):
        _, finish = self.fn('post_air_finish')
        self.assertEqual(squash(finish),
                         '{returnc+max(light_finish(c+a)-light_finish(c),float3(0.0));}')
        _, full = self.fn('post_air_full')
        self.assertIn('post_air_finish(', full)

    def testRangeAndNaNGuards(self):
        _, term = self.fn('post_air_term')
        for text in ('post_linear_depth(0.0, A, B, ortho)',
                     'post_linear_depth(1.0, A, B, ortho)',
                     'const float zLo = max(air.range.x, camNear);',
                     'const float zHi = min(min(air.range.y, camFar), zSurf);',
                     'if (!(zHi > zLo) || !isfinite(zHi - zLo))',
                     'if (!all(isfinite(add))) add = float3(0.0);',
                     'max(add, float3(0.0))'):
            self.assertIn(text, term)
        # every pow base and every length is floored; -rd.z too
        for m in re.finditer(r'\bpow\(', self.air_code):
            self.assertTrue(self.air_code[m.end():].startswith('max('),
                            self.air_code[m.start():m.start() + 60])
        for name in ('post_air_haze', 'post_air_dust'):
            self.assertIn('1.0 / max(-rd.z, 1e-4)', self.fn(name)[1], name)
        _, light = self.fn('post_air_light')
        self.assertIn('max(length(Lv), 1e-3)', light)
        self.assertIn('max(rig.L[i].radiance.w - rig.L[i].axis.w, 1e-7)', light)
        # no pow at all for the twinkle (a 0 base)
        self.assertNotRegex(self.fn('post_air_dust')[1], r'\bpow\(')


class TestPostChain(AirMSLCase):

    def testOneStatementAfterPassOneBeforeTheResolve(self):
        post = self.body('RendererMetal::runPostChain')
        found = re.findall(r'if\s*\(([^;]*?)\)\s*sceneSrc\s*=\s*encodeAirPass\(sceneSrc\);',
                           post)
        self.assertEqual(len(found), 1)
        self.assertEqual(squash(found[0]),
                         '_lightAirOn&&_lightRigOn&&_postColor&&_sceneDepth&&'
                         'ensureAirPipelines()')
        self.assertEqual(post.count('encodeAirPass('), 1)
        at = post.index('encodeAirPass(')
        self.assertEqual(depth_at(post, at), 1)
        # after both pass-1 variants (the else-if closes before it) ...
        raster = re.search(r'else if \(\(doAO \|\| doFog \|\| doShadowMap\) && _postColor\)'
                           r'\s*\{', post)
        self.assertIsNotNone(raster)
        self.assertLess(match_brace(post, raster.end() - 1), at)
        self.assertLess(post.index('if (doRT) {'), at)
        # ... and before the OIT resolve and every later pass
        self.assertLess(at, post.index('if (_oitHasContent && _oitResolvePipeline'))
        self.assertLess(at, post.index('if (_dofEnabled'))

    def testIndices(self):
        for name, value in AIR_INDICES:
            self.assertRegex(self.code, r'constexpr NSUInteger %s = %d;' % (name, value))

    def testEncodeAirPass(self):
        enc = self.body('RendererMetal::encodeAirPass')
        # value copies of the blocks, this frame's projection in the air's
        for text in ('LightAirBlock air = _lightAirBlock;',
                     'air.view[1] = _projOrtho;', 'air.proj[0] = _projA;',
                     'air.proj[1] = _projB;', 'air.proj[2] = _projX;',
                     'air.proj[3] = _projY;', 'LightRigBlock rig = _lightRigBlock;'):
            self.assertIn(text, enc)
        # the whole slice (a grid frame draws no air) ...
        self.assertEqual(re.findall(r'rig\.shadowTile\[(\d)\]\s*=\s*([\d.]+)f;', enc),
                         [('0', '0.0'), ('1', '0.0'), ('2', '1.0'), ('3', '1.0')])
        # ... and no maps unless they were rendered, the stand-in then
        self.assertRegex(enc, r'const bool maps = lightShadowsReady\(\);\s*'
                              r'if \(!maps\)\s*rig\.head\[3\] = 0\.0f;')
        self.assertIn('maps ? _lightShadowArray : _airNoMaps', enc)
        # its own indices only, never the lit draws' binding
        self.assertNotIn('bindLightRig', enc)
        self.assertNotRegex(enc, r'kLightRig\w*Index|kLightShadow\w*Index|kRTLightRig')
        indices = re.findall(r'atIndex:(\w+)\]', enc)
        self.assertEqual(sorted(indices), sorted(name for name, _ in AIR_INDICES))
        for name, _ in AIR_INDICES:
            self.assertEqual(self.code.count('atIndex:%s]' % name), 1, name)
        self.assertIn('setFragmentBytes:&air length:sizeof(air) atIndex:kAirParamsBufferIndex]',
                      enc)
        self.assertIn('setFragmentBytes:&rig length:sizeof(rig) atIndex:kAirRigBufferIndex]',
                      enc)
        self.assertIn('setFragmentTexture:_sceneDepth atIndex:kAirDepthTextureIndex]', enc)
        self.assertIn('setFragmentSamplerState:_shadowSampler atIndex:kAirMapsSamplerIndex]',
                      enc)
        # on the frame's command buffer (metal_gpu_timing includes it), ping-pong
        self.assertIn('[_cmdBuffer renderCommandEncoderWithDescriptor:pd]', enc)
        self.assertIn('id<MTLTexture> dst = (sceneSrc == _sceneColor) ? _postColor : '
                      '_sceneColor;', enc)
        self.assertIn('[ea setFragmentTexture:sceneSrc atIndex:kAirColorTextureIndex];', enc)
        self.assertIn('[ea setRenderPipelineState:_airFullPipeline];', enc)
        self.assertRegex(enc, r'return dst;\s*\}$')

    def testStandInMaps(self):
        noMaps = self.body('RendererMetal::ensureAirNoMaps')
        for text in ('d.textureType = MTLTextureType2DArray;',
                     'd.pixelFormat = MTLPixelFormatDepth32Float;',
                     'd.width = 1;', 'd.height = 1;',
                     'd.arrayLength = kLightRigBlockShadowSlots;',
                     'd.usage = MTLTextureUsageShaderRead;',
                     'd.storageMode = MTLStorageModePrivate;', '[d release];'):
            self.assertIn(text, noMaps)
        self.assertRegex(noMaps, r'^\{\s*if\s*\(\s*_airNoMaps\s*\)\s*return _airNoMaps;')

    def testDestructorReleases(self):
        dtor = self.body('RendererMetal::~RendererMetal')
        self.assertIn('[_airFullPipeline release];', dtor)
        self.assertIn('[_airNoMaps release];', dtor)
        # nothing else releases or rebuilds them (single-sample: a sample-count
        # change leaves them alone), but the attempt that cannot make the
        # stand-in maps
        self.assertEqual(self.code.count('[_airFullPipeline release]'), 2)
        self.assertRegex(self.body('RendererMetal::ensureAirPipelines'),
                         r'if \(_airFullPipeline && !ensureAirNoMaps\(\)\) \{\s*'
                         r'\[_airFullPipeline release\];\s*_airFullPipeline = nil;')
        self.assertEqual(self.code.count('[_airNoMaps release]'), 1)
        self.assertNotIn('_airFullPipeline', self.body('RendererMetal::rebuildDrawPipelines'))


class TestSceneRender(AirMSLCase):

    def testTheAirReachesTheRendererOncePerFrame(self):
        scene = strip_comments(read(SCENE_RENDER))
        body = cpp_function(read(SCENE_RENDER), 'SceneRenderMetal')
        self.assertEqual(body.count('SceneLightsAir('), 1)
        self.assertEqual(body.count('setLightAir('), 1)
        frame = body.index('lights = SceneLightsFrame(G, glm::dmat4(glm::make_mat4(mv)));')
        self.assertLess(frame, body.index('SceneLightsAir('))
        self.assertLess(body.index('setGpuTiming('), body.index('SceneLightsAir('))
        self.assertLess(body.index('setLightAir('), body.index('SceneRenderAll('))
        # and nowhere else in the scene
        self.assertEqual(scene.count('setLightAir('), 1)
