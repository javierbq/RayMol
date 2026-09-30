"""metal_rt_transparent (#532): transparent geometry in the Metal ray tracer.

Metal RT used to leave every transparent draw out of its acceleration
structure, so glass, frosted glass and jelly cast no traced shadow or AO and
were absent from reflections. With `metal_rt_transparent 1` the transparent
draws go into a SEPARATE structure: a shadow ray that reaches no opaque caster
is attenuated by the transparent reps it crosses, an AO ray that misses opaque
geometry occludes by the alpha of a transparent hit, and a reflection ray
blends the nearest transparent surface over what it hit.

It is off by default, and the default must stay byte-identical. That rests on
two things this file pins in the source, since the rendering itself needs a
Metal GPU:
  * the RT shaders are SPECIALISED on a function constant, and the default
    pipelines are built with it false, so the new code is compiled out of them;
  * every argument only the transparent variant reads is itself gated on that
    constant. A plain argument would have to be bound on every default frame
    too, and Metal API validation aborts on an unbound one.

    pymol -ckqy testing/testing.py --run testing/tests/raymol/metal_rt_transparent.py
"""
import os
import re

from pymol import _cmd, cmd, setting, testing

SOURCE = os.path.join('layerGraphics', 'metal', 'RendererMetal.mm')


def rt_source():
    root = os.path.join(os.path.dirname(__file__), os.pardir, os.pardir, os.pardir)
    with open(os.path.normpath(os.path.join(root, SOURCE))) as f:
        src = f.read()
    m = re.search(r'static NSString\* const kRTSrc = @R"\((.*?)\)"', src, re.S)
    return src, m.group(1)


class TestTheSetting(testing.PyMOLTestCase):

    def testItIsAGlobalBooleanAtItsOwnIndex(self):
        # .pse files store indices: 845 is this setting's for good
        self.assertEqual(setting._get_index('metal_rt_transparent'), 845)
        self.assertEqual(
            _cmd.get_setting_level(setting._get_index('metal_rt_transparent')),
            'global')

    def testItIsOffByDefault(self):
        cmd.reinitialize()
        self.assertEqual(cmd.get_setting_boolean('metal_rt_transparent'), 0)

    def testAScenePutsItBack(self):
        from pymol import raymol_scenes as rs
        from pymol import appkit_inspector as ai
        self.assertIn('metal_rt_transparent', rs.CAPTURE)
        self.assertIn('metal_rt_transparent', ai.SCENE_SETTINGS)
        cmd.reinitialize()
        cmd.fragment('ala', 'm1')
        cmd.set('metal_rt_transparent', 1)
        cmd.scene('s1', 'store')
        cmd.set('metal_rt_transparent', 0)
        cmd.scene('s1', 'recall')
        self.assertEqual(cmd.get_setting_boolean('metal_rt_transparent'), 1)


class TestTheDefaultIsCompiledOut(testing.PyMOLTestCase):

    def testTheConstantIsFunctionConstantZero(self):
        _src, rt = rt_source()
        self.assertRegex(rt, r'constant bool kRTTrans \[\[function_constant\(0\)\]\];')

    def testTheDefaultPipelinesAreSpecialisedFalse(self):
        src, _rt = rt_source()
        # the specialisation writes index 0, the constant's, with the value
        # the caller asked for
        self.assertRegex(src, r'bool t = transparent;\s*'
                              r'\[fc setConstantValue:&t type:MTLDataTypeBool atIndex:0\]')
        # the default pair is built false; the transparent pair only when the
        # setting is on
        self.assertIn('buildRTPipelines(false, &_rtAOPipeline, &_rtResolvePipeline);', src)
        self.assertRegex(
            src, r'if \(_rtLib && _rtTransparent && !_rtTCompileTried\) \{\s*'
                 r'_rtTCompileTried = true;\s*'
                 r'buildRTPipelines\(true, &_rtAOPipelineT, &_rtResolvePipelineT\);')

    def testEveryTransparentOnlyArgumentIsGated(self):
        _src, rt = rt_source()
        # buffer slots 9..12 exist only for the transparent structure
        args = re.findall(r'\[\[buffer\((9|1[0-2])\)([^\]]*)\]\]', rt)
        self.assertGreaterEqual(len(args), 6)   # 3 in rt_ao, 3 in rt_composite
        for slot, rest in args:
            self.assertIn('function_constant(kRTTrans)', rest, 'buffer(%s)' % slot)

    def testTheTransparentPipelinesAreUsedOnlyWithTheStructure(self):
        src, _rt = rt_source()
        # chosen only when the setting is on AND the structure and its
        # pipelines exist -- otherwise the default pair, which binds nothing new
        self.assertRegex(src, r'const bool doRTTrans = doRT && _rtTransparent && _rtTReady && '
                              r'_rtTransAS &&\s*_rtAOPipelineT && _rtResolvePipelineT;')
        self.assertIn('setRenderPipelineState:doRTTrans ? _rtAOPipelineT : _rtAOPipeline]', src)
        self.assertIn('setRenderPipelineState:doRTTrans ? _rtResolvePipelineT : _rtResolvePipeline]', src)

    def testEveryUseOfTheTransparentStructureIsBehindTheConstant(self):
        """The declarations are gated (above), and so must every read be: the
        default pipeline compiles kRTTrans out only where a kRTTrans branch
        encloses the read. An ungated read still compiles -- and makes the
        default pipeline read buffers no default frame binds."""
        _src, rt = rt_source()
        # rt_trans_T itself reads them unconditionally; it is covered by its
        # call sites, which are uses of `tas` checked below
        start = rt.index('static float rt_trans_T')
        end = rt.index('\n}\n', start) + 3
        checked = 0
        for m in re.finditer(r'\b(tas|tcols|tocc|tnrms)\b', rt):
            if start <= m.start() < end:
                continue
            if rt[m.end():m.end() + 12].lstrip().startswith('[[buffer('):
                continue   # the argument declaration
            # headers of the blocks enclosing this use, innermost first
            depth, headers, i = 0, [], m.start()
            while i > 0:
                i -= 1
                c = rt[i]
                if c == '}':
                    depth += 1
                elif c == '{':
                    if depth:
                        depth -= 1
                    else:
                        j = max(rt.rfind(';', 0, i), rt.rfind('}', 0, i),
                                rt.rfind('{', 0, i))
                        headers.append(rt[j + 1:i])
            # an `if (kRTTrans ...)` block -- not merely a header that mentions
            # it: the function's own header does, in its gated arguments
            self.assertTrue(any(re.search(r'\bif \(kRTTrans\b', h) for h in headers),
                            '%s at offset %d is not inside a kRTTrans branch'
                            % (m.group(0), m.start()))
            checked += 1
        # AO (tas, tcols), shadow (tas, tcols, tocc), reflection (tas, tnrms, tcols)
        self.assertGreaterEqual(checked, 8)


class TestTheStructuresStaySeparate(testing.PyMOLTestCase):
    """What keeps the transparent structure from costing the opaque one, and
    from being built where nothing can use it. Source checks: the behaviour is
    GPU-side."""

    def header(self):
        root = os.path.join(os.path.dirname(__file__), os.pardir, os.pardir, os.pardir)
        with open(os.path.normpath(os.path.join(
                root, 'layerGraphics', 'metal', 'RendererMetal.h'))) as f:
            return f.read()

    def testDroppingAnEntryDirtiesOnlyTheStructureBuiltFromIt(self):
        """A dropped cache entry forces a rebuild only of a structure whose
        last build USED it -- not the opaque one for a transparent-only entry
        (#532), and neither for the buffers a rebuilt rep replaced, which are
        drained each frame after that frame's structure was built from the
        replacement."""
        src, _rt = rt_source()
        self.assertRegex(src, r'if \(_rtBuiltKeys\.count\(key\)\)\s*_rtGeomDirty = true;\s*'
                              r'if \(_rtTBuiltKeys\.count\(key\)\)\s*_rtTGeomDirty = true;')
        # the sets are the records each structure is built from
        self.assertIn('_rtBuiltKeys = std::unordered_set<const void*>(_rtFrameKeys.begin(), _rtFrameKeys.end());', src)
        self.assertIn('_rtTBuiltKeys = std::unordered_set<const void*>(_rtTFrameKeys.begin(), _rtTFrameKeys.end());', src)
        # ...and the transparent build is driven by its own flag
        self.assertRegex(src, r'!_rtTGeomDirty &&\s*_rtTFrameSig == _rtTBuiltSig')

    def testNothingIsBuiltWithoutOpaqueCasters(self):
        src, _rt = rt_source()
        self.assertRegex(src, r'_rtTFrameKeys\.empty\(\) \|\|\s*_rtFrameKeys\.empty\(\)\) \{\s*'
                              r'if \(_rtTransAS\) releaseRayTracingTransAS\(\);')

    def testGridModeRecordsNoTransparentGeometry(self):
        self.assertIn('if (transparent && (!_rtTransparent || !_rtFrameCells.empty()))',
                      self.header())

    def testTheShadowWalkCountsDistinctRepsNotHits(self):
        _src, rt = rt_source()
        self.assertIn('for (int k = 0; k < 32 && nSeen < 8 && T > 0.02; ++k)', rt)

    def testAnAllClippedRecordIsNotRegatheredEveryFrame(self):
        src, _rt = rt_source()
        self.assertRegex(src, r'if \(nTris == 0\) \{\s*_rtTBuiltSig = _rtTFrameSig;\s*'
                              r'_rtTBuiltEmpty = true;')
        self.assertIn('((_rtTReady && _rtTransAS) || _rtTBuiltEmpty) && !_rtTGeomDirty', src)
