"""The air (haze and dust, #618) in the Metal shaders and the post chain, from
source.

The air is MSL compiled at run time (kAirSrc in layerGraphics/metal/
RendererMetal.mm) and CI has no GPU: a library that fails to compile is one
NSLog and a frame without air. These checks pin, from the source, what L1,
the regression renders against master, L2 and L3 prove on a Mac:

* TestMasterUnchanged: every shader literal that master has is master's
  (sha256 of the comment-stripped, whitespace-free text, taken from master
  83dd31bbe with these parsers, never from this branch), except kMaterialSrc,
  which #615 changes and pins at its head (CHANGED_BY_615), and four lit
  libraries once #615's mat_classic_light arguments are taken out; kAirSrc
  is the only new one; and runPostChain, beginFrame, SceneRenderMetal and
  SceneLightsFrame are master's once the air's own statement (and, in
  SceneRenderMetal, #615's setLightClassicScale statement) is taken out;
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
  pins the two statements' text);
* TestHalf: half resolution (metal_light_air_resolution 2, the default on both)
  marches into an RGBA16Float _airTerm, ceil(w/2) x ceil(h/2), private, made
  lazily and re-made on a size change, with a checkerboard of each 2x2
  block's nearest and farthest depth; the upsample is a 4-tap joint-bilateral
  filter on the eye depth where each march stopped (post_air_stop, the
  term's own range statements), falling back to the texel nearest in depth;
  without the half pipelines or the term the frame draws at full;
* TestBridgeAndApp: the redraw policy. PyMOLBridge_AirAnimating is declared
  and defined alike, calls only PyMOL_GetGlobals and SceneLightsAirAnimating
  and names no Python (outside the PyMOLBridge_Light* set lighting_bridge.py
  pins); only PyMOLEngine.lightAirAnimating calls it; draw(in:) asks it only
  through airTickDue, after AirRedrawGate allows a due tick and only when
  nothing else renders, and hands RenderGate `pending || airDue`; RenderGate
  and the rest of draw(in:) are master's.

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
# #615 (Materials own their response to studio lights) changes kMaterialSrc
# itself: MaterialU carries the studio response, light_response reads it, the
# material shaders name their light constants, and their own classic light
# terms take the rig's classic scale (mat_classic_light; kLightRig declared
# at the top). MASTER_LITERALS keeps
# master's digest; this is the branch's, taken with the same parsers at
# #615's head. #615 (re-take only when #615 changes kMaterialSrc);
# lighting_material_msl.py pins what changed.
CHANGED_BY_615 = {
    'kMaterialSrc': '4f4f1e7f4c703bad',
}
# #615 appends the material's classic scale to every mat_glass_shade call
# (`, mat_classic_light(m)`). These four literals carry such calls and nothing
# else of #615's: with the argument taken out they are master's.
CLASSIC_LIGHT_ARGUMENT = re.compile(r',\s*mat_classic_light\(\s*\w+\s*\)')
CLASSIC_LIGHT_LITERALS = ('kVBOSrc', 'kSphereImpostorSrc', 'kCylinderImpostorSrc',
                          'kMaterialImpostorSrc')
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
# #615's own statements in those functions, taken out the same way (exactly
# one match each): SceneRenderMetal hands the renderer the rig's classic
# scale right after the rig.
STATEMENTS_615 = {
    'SceneRenderMetal': re.compile(
        r'G->Renderer->setLightClassicScale\(lights\.classic\.scale\);'),
}
# #624's (HDR) statement, taken out the same way (exactly one match):
# SceneLightsFrame fills the rig block's tone only while the rig is on.
STATEMENTS_624 = {
    'SceneLightsFrame': re.compile(
        r'if\s*\(\s*frame\.rig\s*\)\s*SceneLightsToneFill\(G,\s*\*frame\.rig\);'),
}
# #624 appends `float4 tone;` to the rig block's MSL mirror (LightRigU) in
# kMaterialSrc and kRTSrc (layer1/LightRigBlock.h, 688 bytes). With the field
# taken out (exactly one match each) the literals are what they were.
TONE_FIELD_624 = re.compile(r'(?<=float4 shadowTile;)\s*float4\s+tone\s*;')
TONE_FIELD_LITERALS = ('kMaterialSrc', 'kRTSrc')

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
             ('kAirMaxScatter', 'kLightAirMaxScatter'),
             ('kAirDepthSigma', 'kLightAirDepthSigma'))

AIR_INDICES = (('kAirParamsBufferIndex', 0), ('kAirRigBufferIndex', 1),
               ('kAirColorTextureIndex', 0), ('kAirDepthTextureIndex', 1),
               ('kAirMapsTextureIndex', 2), ('kAirTermTextureIndex', 3),
               ('kAirPostSamplerIndex', 0),
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
            # #615: a literal it changed is pinned at #615's head instead
            if name in CHANGED_BY_615:
                self.assertNotEqual(CHANGED_BY_615[name], want, name)
                want = CHANGED_BY_615[name]
            code = strip_comments(self.msl[name])
            # #624: the rig block's tone field taken out
            if name in TONE_FIELD_LITERALS:
                self.assertEqual(len(TONE_FIELD_624.findall(code)), 1, name)
                code = TONE_FIELD_624.sub('', code, count=1)
            # #615: the classic-scale argument of the glass calls taken out
            if name in CLASSIC_LIGHT_LITERALS:
                self.assertTrue(CLASSIC_LIGHT_ARGUMENT.search(code), name)
                code = CLASSIC_LIGHT_ARGUMENT.sub('', code)
            self.assertEqual(digest(code), want, name)
        self.assertLessEqual(set(CHANGED_BY_615), set(MASTER_LITERALS))
        self.assertEqual(set(self.msl) - set(MASTER_LITERALS), {'kAirSrc'})

    def testFunctionsAreMastersWithoutTheAir(self):
        sources = {'RendererMetal.mm': self.mm,
                   'SceneRender.cpp': read(SCENE_RENDER),
                   'SceneLights.cpp': read(SCENE_LIGHTS)}
        for (path, name), want in sorted(MASTER_FUNCTIONS.items()):
            body = cpp_function(sources[path], name)
            statement = AIR_STATEMENTS[name]
            self.assertEqual(len(statement.findall(body)), 1, name)
            body = statement.sub('', body, count=1)
            # #615's statement, taken out as the air's is
            if name in STATEMENTS_615:
                self.assertEqual(len(STATEMENTS_615[name].findall(body)), 1, name)
                body = STATEMENTS_615[name].sub('', body, count=1)
            # #624's statement, taken out as the air's is
            if name in STATEMENTS_624:
                self.assertEqual(len(STATEMENTS_624[name].findall(body)), 1, name)
                body = STATEMENTS_624[name].sub('', body, count=1)
            self.assertEqual(digest(body), want, name)


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
        pipeline = cpp_function(self.mm, 'newAirPipeline')
        logs = re.findall(r'NSLog\(@"([^"]*)"', ensure + pipeline
                          + self.body('RendererMetal::ensureAirTerm'))
        self.assertTrue(logs)
        for text in logs:
            # what the L4 console check greps for
            self.assertRegex(text, r'^RendererMetal: air .*(fail|missing)', text)
        # only the pipeline states are kept
        for released in ('[lib release];', '[vfn release];'):
            self.assertIn(released, ensure)
        for released in ('[ffn release];', '[pd release];'):
            self.assertIn(released, pipeline)
        self.assertNotIn('newRenderPipelineStateWithDescriptor:', ensure)
        self.assertEqual(pipeline.count('newRenderPipelineStateWithDescriptor:'), 1)
        self.assertEqual(self.code.count('newAirPipeline('), 4)   # the definition, 3 calls
        self.assertIn('pd.rasterSampleCount = 1;', pipeline)
        self.assertIn('pd.colorAttachments[0].pixelFormat = format;', pipeline)
        self.assertIn('pd.vertexFunction = vfn;', pipeline)
        self.assertNotIn('depthAttachmentPixelFormat', pipeline)
        # the maps' stand-in in the same attempt
        self.assertIn('ensureAirNoMaps()', ensure)
        self.assertEqual(len(re.findall(r'(?<!::)\bensureAirNoMaps\(\)', self.code)), 1)
        self.assertRegex(self.header, r'bool _airPipelinesTried = false;')

    def testFunctionsComeFromAirFunction(self):
        ensure = self.body('RendererMetal::ensureAirPipelines')
        self.assertNotIn('newFunctionWithName', ensure)
        self.assertEqual(re.findall(r'airFunction\(lib, @"(\w+)"\)', ensure),
                         ['post_air_vertex'])
        # the fragments, each in its own pipeline and colour format
        self.assertEqual(
            re.findall(r'newAirPipeline\(_device, lib, vfn, @"(\w+)",\s*(\w+)\)', ensure),
            [('post_air_full', 'MTLPixelFormatBGRA8Unorm'),
             ('post_air_march', 'MTLPixelFormatRGBA16Float'),
             ('post_air_upsample', 'MTLPixelFormatBGRA8Unorm')])
        pipeline = cpp_function(self.mm, 'newAirPipeline')
        self.assertIn('id<MTLFunction> ffn = airFunction(lib, name);', pipeline)
        self.assertNotIn('newFunctionWithName', pipeline)
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
                     'post_air_finish', 'post_air_full', 'post_air_stop',
                     'post_air_march', 'post_air_upsample'):
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
        self.assertIn('[ea setRenderPipelineState:(half ? _airUpsamplePipeline : '
                      '_airFullPipeline)];', enc)
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
        for name in ('_airMarchPipeline', '_airUpsamplePipeline', '_airTerm'):
            self.assertIn('[%s release];' % name, dtor)
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


class TestHalf(AirMSLCase):

    def testTermTexture(self):
        term = self.body('RendererMetal::ensureAirTerm')
        # ceil(w/2) x ceil(h/2), RGBA16Float, private, a render target read by
        # the upsample
        self.assertIn('const NSUInteger hw = (w + 1) / 2;', term)
        self.assertIn('const NSUInteger hh = (h + 1) / 2;', term)
        self.assertRegex(term, r'texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float\s*'
                               r'width:hw height:hh mipmapped:NO\]')
        self.assertIn('d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;',
                      term)
        self.assertIn('d.storageMode = MTLStorageModePrivate;', term)
        # kept while the size holds, re-made (the old one released) when it
        # changes; a size that failed is not retried every frame
        self.assertRegex(term, r'^\{\s*const NSUInteger hw = \(w \+ 1\) / 2;\s*'
                               r'const NSUInteger hh = \(h \+ 1\) / 2;\s*'
                               r'if \(hw == _airTermW && hh == _airTermH\)\s*'
                               r'return _airTerm != nil;\s*\[_airTerm release\];\s*'
                               r'_airTerm = nil;\s*_airTermW = hw;\s*_airTermH = hh;')
        self.assertEqual(term.count('newTextureWithDescriptor:'), 1)
        self.assertRegex(self.header, r'id<MTLTexture> _airTerm = nil;')
        self.assertRegex(self.header, r'bool ensureAirTerm\(NSUInteger w, NSUInteger h\);')
        # lazy: only a half-resolution frame makes it
        calls = re.findall(r'(?<!::)\bensureAirTerm\(', self.code)
        self.assertEqual(len(calls), 1)
        self.assertIn('ensureAirTerm(dst.width, dst.height)',
                      self.body('RendererMetal::encodeAirPass'))
        # released only when re-made and by the destructor
        self.assertEqual(self.code.count('[_airTerm release]'), 2)

    def testMarchThenUpsample(self):
        enc = self.body('RendererMetal::encodeAirPass')
        # half: the block asks for it (view.x 0.5) and everything exists; else
        # full, and the shaders are told so
        self.assertRegex(enc, r'const bool half = air\.view\[0\] < 0\.75f && '
                              r'_airMarchPipeline && _airUpsamplePipeline &&\s*'
                              r'ensureAirTerm\(dst\.width, dst\.height\);\s*'
                              r'if \(!half\)\s*air\.view\[0\] = 1\.0f;')
        march = enc.index('[em setRenderPipelineState:_airMarchPipeline];')
        final = enc.index('[ea setRenderPipelineState:')
        self.assertLess(march, final)
        self.assertLess(enc.index('if (half) {'), march)
        self.assertIn('md.colorAttachments[0].texture = _airTerm;', enc)
        self.assertIn('[_cmdBuffer renderCommandEncoderWithDescriptor:md]', enc)
        self.assertEqual(enc.count('[_cmdBuffer renderCommandEncoderWithDescriptor:'), 2)
        self.assertRegex(enc, r'if \(half\)\s*\[ea setFragmentTexture:_airTerm '
                              r'atIndex:kAirTermTextureIndex\];')
        # both passes bind the same blocks, depth and maps
        self.assertEqual(enc.count('bindAir(em);'), 1)
        self.assertEqual(enc.count('bindAir(ea);'), 1)
        self.assertEqual(enc.count('endEncoding'), 2)

    def testHalfFallsBackToFull(self):
        ensure = self.body('RendererMetal::ensureAirPipelines')
        # the half pipelines are made only with the full one, and a failure
        # of either drops both (half then draws at full); full alone is enough
        self.assertRegex(ensure, r'if \(_airFullPipeline\) \{\s*_airMarchPipeline = ')
        self.assertRegex(ensure, r'if \(!_airMarchPipeline \|\| !_airUpsamplePipeline\) \{'
                                 r'[^}]*_airMarchPipeline = nil;\s*_airUpsamplePipeline = nil;')
        self.assertRegex(ensure, r'return _airFullPipeline != nil;\s*\}$')
        self.assertRegex(self.header, r'id<MTLRenderPipelineState> _airMarchPipeline = nil;')
        self.assertRegex(self.header, r'id<MTLRenderPipelineState> _airUpsamplePipeline = nil;')

    def testCheckerboardDepth(self):
        sig, body = self.fn('post_air_march')
        self.assertTrue(sig.lstrip().startswith('fragment float4 post_air_march('))
        for arg in (r'depth2d<float>\s+depthTex\s*\[\[\s*texture\(1\)\s*\]\]',
                    r'depth2d_array<float>\s+maps\s*\[\[\s*texture\(2\)\s*\]\]',
                    r'sampler\s+smp\s*\[\[\s*sampler\(1\)\s*\]\]',
                    r'constant\s+LightAirU\s*&\s*air\s*\[\[\s*buffer\(0\)\s*\]\]',
                    r'constant\s+LightRigU\s*&\s*rig\s*\[\[\s*buffer\(1\)\s*\]\]'):
            self.assertRegex(sig, arg)
        # the 2x2 block, clamped; the nearest depth on one colour of the
        # checkerboard, the farthest on the other; read, never filtered
        self.assertIn('const bool nearest = ((tx.x + tx.y) & 1u) == 0u;', body)
        self.assertIn('uint2 px = min(tx * 2u, lim);', body)
        self.assertIn('for (uint k = 1u; k < 4u; ++k)', body)
        self.assertIn('min(tx * 2u + uint2(k & 1u, k >> 1u), lim)', body)
        self.assertIn('if (nearest ? dq < d : dq > d)', body)
        self.assertEqual(body.count('depthTex.read('), 2)
        self.assertNotIn('.sample(', body)
        # the same term as full resolution, through the chosen pixel
        self.assertIn('const float2 frag = float2(px) + 0.5;', body)
        self.assertIn('return post_air_term(frag / float2(lim + 1u), frag, d, air, rig, '
                      'maps, smp);', body)

    def testJointBilateralUpsample(self):
        sig, body = self.fn('post_air_upsample')
        self.assertTrue(sig.lstrip().startswith('fragment float4 post_air_upsample('))
        for arg in (r'texture2d<float>\s+colorTex\s*\[\[\s*texture\(0\)\s*\]\]',
                    r'depth2d<float>\s+depthTex\s*\[\[\s*texture\(1\)\s*\]\]',
                    r'texture2d<float>\s+termTex\s*\[\[\s*texture\(3\)\s*\]\]',
                    r'constant\s+LightAirU\s*&\s*air\s*\[\[\s*buffer\(0\)\s*\]\]'):
            self.assertRegex(sig, arg)
        self.assertIn('colorTex.read(px)', body)
        self.assertIn('const float z = post_air_stop(depthTex.read(px), air);', body)
        self.assertNotIn('.sample(', body)
        # the four nearest texels, each its bilinear weight times a Gaussian
        # on the eye depth where it stopped
        self.assertIn('const float2 h = in.position.xy * 0.5 - 0.5;', body)
        self.assertIn('for (int k = 0; k < 4; ++k)', body)
        self.assertIn('termTex.read(uint2(clamp(int2(b) + o, int2(0), lim)))', body)
        self.assertIn('const float dz = abs(t.a - z);', body)
        self.assertIn('(o.x == 1 ? f.x : 1.0 - f.x) * (o.y == 1 ? f.y : 1.0 - f.y)', body)
        self.assertIn('max(kAirDepthSigma * (air.range.y - air.range.x), 1e-3)', body)
        self.assertIn('const float w = wb * exp(-r * r);', body)
        # the nearest-depth fallback, then the composite, alpha kept
        self.assertIn('if (dz < best)', body)
        self.assertIn('const float3 a = wsum > 1e-4 ? sum / wsum : nearest;', body)
        self.assertIn('return float4(post_air_finish(c.rgb, a), c.a);', body)

    def testStopIsTheTermsRange(self):
        _, stop = self.fn('post_air_stop')
        _, term = self.fn('post_air_term')
        first, last = 'const float A =', 'const float zHi ='
        self.assertEqual(squash(statements(stop, first, last)),
                         squash(statements(term, first, last)))
        # an empty range stops at the surface, as the term's .a does
        self.assertIn('if (!(zHi > zLo) || !isfinite(zHi - zLo)) return zSurf;', stop)
        self.assertRegex(stop, r'return zHi;\s*\}$')
        self.assertIn('return float4(0.0, 0.0, 0.0, zSurf);', term)
        self.assertIn('return float4(max(add, float3(0.0)), zHi);', term)

    def testDefaultIsHalfOnBothPlatforms(self):
        # metal_light_air_resolution 0 is the platform default: half on iOS
        # and, after L6, on the Mac too (lighting_air.TestResolution checks
        # the function)
        air = read(os.path.join(ROOT, 'layer1', 'LightAir.cpp'))
        res = cpp_function(air, 'LightAirResolution')
        self.assertRegex(res, r'return kLightAirHalf;\s*\}$')
        self.assertNotIn('kLightAirFull :', res)
        self.assertNotIn('? kLightAirFull', res)
        self.assertNotIn('mobile ?', res)
        lights = read(SCENE_LIGHTS)
        self.assertRegex(lights, r'#ifdef _PYMOL_IOS\s*constexpr bool kSceneLightsMobile = true;'
                                 r'\s*#else\s*constexpr bool kSceneLightsMobile = false;')
        body = cpp_function(lights, 'SceneLightsAir')
        self.assertRegex(body, r'pymol::LightAirResolution\(\s*SettingGetGlobal_i\(G, '
                               r'cSetting_metal_light_air_resolution\),\s*kSceneLightsMobile\)')
        pack = cpp_function(air, 'LightAirPack')
        self.assertIn('b.view[0] = resolution == kLightAirHalf ? 0.5f : 1.0f;', pack)


# ---- The redraw policy (Part 5) ----------------------------------------------

BRIDGE_DIR = os.path.join(ROOT, 'swiftui', 'PyMOLViewer', 'Bridge')
BRIDGE_H = os.path.join(BRIDGE_DIR, 'PyMOLBridge.h')
BRIDGE_MM = os.path.join(BRIDGE_DIR, 'PyMOLBridge.mm')
APP_DIR = os.path.join(ROOT, 'swiftui', 'PyMOLViewer')
SHARED = os.path.join(APP_DIR, 'Shared')
VIEWPORT = os.path.join(SHARED, 'MetalViewport.swift')
ENGINE = os.path.join(SHARED, 'PyMOLEngine.swift')

# Master 83dd31bbe, the same digest (comments stripped, whitespace removed,
# sha256, 16 hex digits) of `enum RenderGate {...}` (signature included) and
# of draw(in:)'s body; draw(in:) on this branch with the air's three edits
# undone (AIR_DRAW_EDITS).
MASTER_RENDER_GATE = '2d8f135d3658785a'
MASTER_DRAW = '83fc4b2d4ba500a9'
AIR_DRAW_EDITS = (
    (re.compile(r'let airDue = !pending && !forceRedraw && hasRenderedOnce\s*'
                r'&& airTickDue\(view: view, engine: engine\)'), ''),
    (re.compile(r'redisplayPending: pending \|\| airDue'), 'redisplayPending: pending'),
    (re.compile(r'lastFrameTime = CACurrentMediaTime\(\)'), ''),
)
AIR_BRIDGE_CALLS = {'INST', 'PyMOL_GetGlobals', 'SceneLightsAirAnimating'}


def _load_lighting_bridge():
    """lighting_bridge.py's parsers and its Python pattern, loaded by path
    under a private name (its cases are not collected twice)."""
    spec = importlib.util.spec_from_file_location(
        '_lighting_air_bridge_parsers', os.path.join(HERE, 'lighting_bridge.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


_bridge = _load_lighting_bridge()


def swift_body(text, signature, keep_signature=False):
    """The braces-matched block after `signature` in `text` (None when absent),
    as lighting_inspector.body; with the signature when asked."""
    start = text.find(signature)
    if start < 0:
        return None
    open_at = text.find('{', start)
    end = match_brace(text, open_at)
    return text[start if keep_signature else open_at:end + 1]


def c_function(source, name):
    """(return type, [param types], body) of the C function `name` defined in
    `source`, with lighting_bridge's parsers."""
    source = _bridge.strip_comments(source)
    match = re.search(r'^([A-Za-z_][\w \t\*]*?)\b%s\s*\(([^)]*)\)\s*\{' % name,
                      source, re.M)
    if not match:
        raise AssertionError('no definition of %s' % name)
    open_at = match.end() - 1
    return (_bridge.normalize_type(match.group(1)), _bridge.param_types(match.group(2)),
            source[open_at:match_brace(source, open_at) + 1])


class TestBridgeAndApp(AirMSLCase):

    def setUp(self):
        super().setUp()
        for path in (BRIDGE_H, BRIDGE_MM, VIEWPORT, ENGINE):
            if not os.path.isfile(path):
                self.fail('%s is missing from the checkout' % path)
        self.viewport = _bridge.strip_comments(read(VIEWPORT))
        self.engine = _bridge.strip_comments(read(ENGINE))

    def testBridgeCallsOnlyTheScene(self):
        header = _bridge.strip_comments(read(BRIDGE_H))
        decls = re.findall(r'^([A-Za-z_][\w \t\*]*?)\bPyMOLBridge_AirAnimating\s*\(([^)]*)\)\s*;',
                           header, re.M)
        self.assertEqual(len(decls), 1, 'PyMOLBridge_AirAnimating is declared once')
        ret, params, body = c_function(read(BRIDGE_MM), 'PyMOLBridge_AirAnimating')
        self.assertEqual((_bridge.normalize_type(decls[0][0]), _bridge.param_types(decls[0][1])),
                         (ret, params))
        self.assertEqual((ret, params), ('int', ['PyMOLHandle']))
        self.assertIsNone(_bridge.PYTHON.search(body),
                          'the air query names %r' % (_bridge.PYTHON.search(body) or [''])[0])
        self.assertEqual(_bridge.calls(body), AIR_BRIDGE_CALLS)
        self.assertEqual(body.count('SceneLightsAirAnimating('), 1)
        # Outside the PyMOLBridge_Light* set lighting_bridge.py pins.
        self.assertNotRegex('PyMOLBridge_AirAnimating', r'^PyMOLBridge_Light')
        # The scene function exists, in the file lighting_bridge's
        # testRigCoreHasNoPython reads, and asks for no frame itself.
        animating = cpp_function(read(SCENE_LIGHTS), 'SceneLightsAirAnimating')
        self.assertNotRegex(animating, r'NeedRedisplay|SceneInvalidate|OrthoDirty|SceneChanged')

    def testOnlyTheEngineCallsTheBridge(self):
        callers = []
        for folder, _dirs, files in os.walk(APP_DIR):
            for filename in files:
                if filename.endswith('.swift'):
                    text = _bridge.strip_comments(read(os.path.join(folder, filename)))
                    count = len(re.findall(r'\bPyMOLBridge_AirAnimating\s*\(', text))
                    if count:
                        callers.append((filename, count))
        self.assertEqual(callers, [('PyMOLEngine.swift', 1)])
        wrapper = swift_body(self.engine, 'var lightAirAnimating: Bool')
        self.assertIsNotNone(wrapper, 'PyMOLEngine.lightAirAnimating not found')
        self.assertRegex(wrapper, r'guard let inst = instance, !exportRenderActive else '
                                  r'\{ return false \}')
        self.assertIn('PyMOLBridge_AirAnimating(inst) != 0', wrapper)
        self.assertNotRegex(wrapper, r'runPython|runCommand|RunPython|RunCommand')
        # Beside metalRayTracing, the render loop's other per-tick read.
        self.assertLess(self.engine.index('var metalRayTracing: Bool'),
                        self.engine.index('var lightAirAnimating: Bool'))

    def testGatePolicy(self):
        gate = swift_body(self.viewport, 'enum AirRedrawGate')
        self.assertIsNotNone(gate, 'enum AirRedrawGate not found')
        # The 30 Hz default stays (#623 changes no default); RAYMOL_AIR_FPS
        # (1-120, read once per launch) is the calibration's switch.
        self.assertRegex(gate, r'static let defaultFPS: Double = 30\b')
        self.assertRegex(gate, r'static let activeFPS: Double = '
                               r'fps\(environment: ProcessInfo\.processInfo\.environment\)')
        self.assertRegex(gate, r'static let fpsRange: ClosedRange<Double> = 1\.\.\.120\b')
        fps = swift_body(gate, 'static func fps(environment: [String: String]) -> Double')
        self.assertIsNotNone(fps, 'AirRedrawGate.fps(environment:) not found')
        self.assertIn('environment["RAYMOL_AIR_FPS"]', fps)
        self.assertIn('value.isFinite, fpsRange.contains(value) else { return defaultFPS }', fps)
        log = swift_body(gate, 'static func logEnabled(environment: [String: String]) -> Bool')
        self.assertIsNotNone(log, 'AirRedrawGate.logEnabled(environment:) not found')
        self.assertIn('environment["RAYMOL_AIR_LOG"]', log)
        self.assertIn('== "1"', log)
        # The gate reads the environment once per launch, for those two only;
        # no other viewport code reads either switch.
        self.assertEqual(gate.count('ProcessInfo.processInfo.environment'), 2)
        self.assertEqual(self.viewport.count('"RAYMOL_AIR_FPS"'), 1)
        self.assertEqual(self.viewport.count('"RAYMOL_AIR_LOG"'), 1)
        hold = swift_body(gate, 'static func holdReason(_ activity: Activity) -> HoldReason?')
        self.assertIsNotNone(hold, 'AirRedrawGate.holdReason not found')
        self.assertLess(hold.index('!activity.active'), hold.index('!activity.visible'))
        self.assertLess(hold.index('!activity.visible'), hold.index('activity.lowPower'))
        self.assertIn('case lowPower = "low_power"', gate)
        self.assertRegex(gate, r'static let dueShare: Double = 0\.95\b')
        self.assertRegex(gate, r'struct Activity: Equatable \{\s*var active: Bool\s*'
                               r'var visible: Bool\s*var lowPower: Bool\s*\}')
        interval = swift_body(gate, 'static func interval(')
        self.assertRegex(interval, r'guard activity\.active, activity\.visible, '
                                   r'!activity\.lowPower else \{ return nil \}')
        self.assertIn('return 1 / activeFPS', interval)
        due = swift_body(gate, 'static func due(')
        self.assertIn('now - lastFrame >= dueShare * interval', due)
        low = swift_body(gate, 'static func lowPower(')
        self.assertIn('lowPowerMode || thermalState.rawValue >= '
                      'ProcessInfo.ThermalState.serious.rawValue', low)

    def testActivityReadsThePlatform(self):
        activity = swift_body(self.viewport, 'private func airActivity(')
        self.assertIsNotNone(activity, 'Coordinator.airActivity not found')
        for token in ('info.isLowPowerModeEnabled', 'info.thermalState',
                      'NSApp.isActive', '.occlusionState.contains(.visible)',
                      '.isMiniaturized', '.isVisible',
                      'activationState == .foregroundActive'):
            self.assertIn(token, activity)
        mac = activity.index('#if os(macOS)')
        other = activity.index('#else')
        self.assertLess(mac, activity.index('NSApp.isActive'))
        self.assertLess(activity.index('NSApp.isActive'), other)
        self.assertGreater(activity.index('activationState'), other)

    def testDrawAsksOnlyOnADueTick(self):
        due = swift_body(self.viewport, 'private func airTickDue(')
        self.assertIsNotNone(due, 'Coordinator.airTickDue not found')
        ask = due.index('engine.lightAirAnimating')
        self.assertLess(due.index('guard let interval = AirRedrawGate.interval('), ask)
        self.assertLess(due.index('guard AirRedrawGate.due('), ask)
        self.assertEqual(due.count('lightAirAnimating'), 1)
        # The only ask in the viewport, and airTickDue's only caller is draw(in:)
        # behind the cheap terms.
        self.assertEqual(self.viewport.count('lightAirAnimating'), 1)
        self.assertEqual(len(re.findall(r'(?<!func )\bairTickDue\(view:', self.viewport)), 1)
        # #623: the activity is read once; the hold log (RAYMOL_AIR_LOG=1
        # only) notes it before the interval guard, and asks the core nothing.
        self.assertEqual(due.count('airActivity(of: view)'), 1)
        self.assertRegex(due, r'if AirRedrawGate\.logsHolds \{ noteAirHold\(activity\) \}')
        self.assertLess(due.index('noteAirHold(activity)'),
                        due.index('guard let interval = AirRedrawGate.interval(activity)'))
        note = swift_body(self.viewport, 'private func noteAirHold(')
        self.assertIsNotNone(note, 'Coordinator.noteAirHold not found')
        self.assertIn('guard state != lastAirHold else { return }', note)
        self.assertIn('AirRedrawGate.holdLine(state, fps: AirRedrawGate.activeFPS)', note)
        self.assertNotIn('engine', note)
        self.assertNotIn('#if DEBUG', note)
        draw = swift_body(self.viewport, 'func draw(in view: MTKView)')
        self.assertRegex(draw, r'let airDue = !pending && !forceRedraw && hasRenderedOnce\s*'
                               r'&& airTickDue\(view: view, engine: engine\)')
        self.assertLess(draw.index('let pending ='), draw.index('let airDue ='))
        self.assertLess(draw.index('let airDue ='), draw.index('RenderGate.decide('))
        self.assertIn('redisplayPending: pending || airDue', draw)
        self.assertEqual(draw.count('RenderGate.decide('), 1)
        # Every rendered frame stamps the clock the gate reads.
        self.assertLess(draw.index('engine.renderMetalFrame('),
                        draw.index('lastFrameTime = CACurrentMediaTime()'))
        self.assertEqual(self.viewport.count('private var lastFrameTime: CFTimeInterval = 0'), 1)
        self.assertEqual(len(re.findall(r'\blastFrameTime\s*=', self.viewport)), 1,
                         'stamped once, after the render')

    def testRenderGateAndDrawAreMasters(self):
        gate = swift_body(self.viewport, 'enum RenderGate {', keep_signature=True)
        self.assertEqual(digest(gate), MASTER_RENDER_GATE, 'RenderGate changed')
        draw = swift_body(self.viewport, 'func draw(in view: MTKView)')
        for pattern, replacement in AIR_DRAW_EDITS:
            draw, count = pattern.subn(replacement, draw)
            self.assertEqual(count, 1, pattern.pattern)
        self.assertEqual(digest(draw), MASTER_DRAW,
                         'draw(in:) differs from master beyond the air\'s three edits')
