"""The Metal frame releases the GPU buffers freed since the last frame.

CShaderMgr::freeGPUBuffer only QUEUES a buffer object; FreeAllVBOs drains the
queue, deleting the CPU vertex copies Metal draws from and dropping the
MTLBuffers uploaded from them (invalidateVBOCacheEntry). The GL loop,
SceneRender, drains it at the top of every frame. SceneRenderMetal -- the
path the macOS and iOS apps render with -- never did, so every rep rebuild
(a material or colour change, each tick of a transparency slider, a surface
recompute) leaked the old copy and its MTLBuffer. On an iPhone 15 Pro that
grew RayMol to its ~3.5 GB per-app limit and iOS killed it (Jetsam, no crash
report); in the simulator, alternating transparency and material grew the app
~19 MB per transparency+material iteration, and was flat with the drain.

The leak needs a Metal GPU to reproduce, so this pins the drain in the
source: SceneRenderMetal calls FreeAllVBOs before its update phase rebuilds
anything, as SceneRender does.

    pymol -ckqy testing/testing.py --run testing/tests/raymol/metal_frees_gpu_buffers.py
"""
import os
import re

from pymol import testing

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), os.pardir,
                                     os.pardir, os.pardir))


def function_body(src, signature):
    start = src.index(signature)
    brace = src.index('{', start)
    depth = 0
    for i in range(brace, len(src)):
        if src[i] == '{':
            depth += 1
        elif src[i] == '}':
            depth -= 1
            if depth == 0:
                return src[brace:i + 1]
    raise AssertionError('unbalanced ' + signature)


def code_only(body):
    """Drop // comments, so a call mentioned in prose does not count."""
    return '\n'.join(line.split('//', 1)[0] for line in body.splitlines())


class TestMetalFreesGPUBuffers(testing.PyMOLTestCase):
    def setUp(self):
        super().setUp()
        path = os.path.join(ROOT, 'layer1', 'SceneRender.cpp')
        if not os.path.isfile(path):
            self.skipTest('layer1/SceneRender.cpp not present; not a repo checkout')
        with open(path, encoding='utf-8') as handle:
            self.src = handle.read()

    def testTheMetalFrameDrainsTheFreeQueueBeforeItsUpdatePhase(self):
        body = code_only(function_body(self.src, 'void SceneRenderMetal(PyMOLGlobals* G)'))
        drain = body.find('G->ShaderMgr->FreeAllVBOs();')
        self.assertGreater(drain, -1, 'SceneRenderMetal no longer drains the free queue')
        update = body.find('SceneUpdate(G')
        self.assertGreater(update, -1)
        self.assertLess(drain, update)

    def testTheGLFrameStillDoes(self):
        """The reference the Metal loop mirrors."""
        body = code_only(function_body(
            self.src, 'void SceneRender(PyMOLGlobals* G, const SceneRenderInfo& renderInfo)'))
        self.assertIn('G->ShaderMgr->FreeAllVBOs();', body)
