# Phase 2: Immediate Mode GL Elimination — Status

## Summary

Phase 2 systematically replaced `glBegin`/`glEnd` immediate mode rendering
with `ImmBatch` (VBO-based batching) across 30+ files spanning all layers
of the PyMOL codebase.

## Remaining `glBegin` calls

| File | Count | Notes |
|------|-------|-------|
| `layer1/CGOGL.cpp` | 2 | CGO GL replay — dispatches arbitrary GL modes |
| `layer1/Character.cpp` | 1 | Textured quad (needs `glTexCoord2f`, not supported by ImmBatch) |
| `layer2/ObjectVolume.cpp` | 1 | Volume slice rendering |
| `layer3/Executive.cpp` | 1 | Inside a comment block (dead code) |
| `layerGraphics/ImmediateHelper.h` | 1 | Reference in doc comment |

**Total active `glBegin` calls: 4** (1 dead code, 1 doc comment, 2 in CGOGL replay, 1 textured)

## Files converted in this pass (Phase 2, Pass 2)

- `layer3/Executive.cpp` — draw_button(): 4 polygon blocks → ImmBatch
- `layer3/Editor.cpp` — draw_tube/draw_globe: 6 triangle strip blocks → ImmBatch
- `layer5/main.cpp` — sync lines + busy indicator: 5 blocks → ImmBatch
- `layer1/Character.cpp` — picking quad: 1 block → ImmBatch (textured path retained)
- `layer1/PyMOLObject.cpp` — debug wireframe box: 2 blocks → ImmBatch
- `layer1/Rep.cpp` — debug wireframe box: 2 blocks → ImmBatch
- `layer0/Sphere.cpp` — SphereRender(): 1 loop of triangle strips → ImmBatch

## Top 20 files by direct GL call count (`gl[A-Z]`)

| File | GL calls |
|------|----------|
| `layer1/CGOGL.cpp` | 174 |
| `layer1/SceneRender.cpp` | 168 |
| `layer0/ShaderMgr.cpp` | 110 |
| `layer1/Scene.cpp` | 96 |
| `layer5/main.cpp` | 87 |
| `layerGraphics/gl/RendererGL.cpp` | 67 |
| `layer0/os_gl.cpp` | 47 |
| `layer0/GenericBuffer.cpp` | 42 |
| `layer1/Ortho.cpp` | 39 |
| `layer5/PyMOL.cpp` | 37 |
| `layer0/ShaderPrg.cpp` | 36 |
| `layerGraphics/gl/GLVertexBuffer.cpp` | 34 |
| `layer3/Executive.cpp` | 31 |
| `layer1/FontGLUT.cpp` | 22 |
| `layer2/ObjectVolume.cpp` | 20 |
| `layer1/SceneRay.cpp` | 20 |
| `layer1/Character.cpp` | 19 |
| `layer1/ScenePicking.cpp` | 17 |

Note: These remaining GL calls are predominantly state management
(`glEnable`, `glDisable`, `glBlendFunc`, etc.), shader/buffer operations,
and the Renderer abstraction layer — not immediate mode vertex submission.

## What Phase 2 accomplished

- Eliminated ~2100+ lines of `glBegin`/`glEnd` immediate mode across 30+ files
- Introduced `ImmBatch` helper for VBO-backed vertex batching
- Reduced active `glBegin` usage from dozens of call sites to 4 remaining
  (2 in CGO replay, 1 textured quad, 1 volume slice)
- All converted code routes through VBO + client-state arrays instead of
  deprecated immediate mode functions
