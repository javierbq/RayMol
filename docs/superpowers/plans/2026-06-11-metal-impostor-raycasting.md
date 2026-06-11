# Metal Impostor Ray-Casting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render `show spheres` and `show sticks` on the SwiftUI+Metal backend as analytic GPU impostors (per-pixel ray–sphere / ray–cylinder intersection with correct fragment depth), replacing the tessellated-triangle fallback.

**Architecture:** Reuse the reps' existing impostor VBOs. Lift the `RepGetSphereMode`/cylinder downgrade so the impostor `*_buffers` CGO ops are emitted on Metal; add new `RendererMetal` impostor pipelines (inline MSL ported from `data/shaders/sphere.{vs,fs}` and `cylinder.{vs,fs}`) that output `[[depth(any)]]`; wire the currently-no-op `CGO_gl_draw_sphere_buffers` / `CGO_gl_draw_cylinder_buffers` Metal branches to call them.

**Tech Stack:** C++17, Objective-C++ (Metal), MSL shaders, the PyMOL CGO render path. Build: `bash swiftui/build_macos.sh` (core lib) + `xcodebuild` (app). No GPU unit tests — verification is PID-exact screenshot inspection.

**Testing note (read first):** GPU rendering has no meaningful unit test; the "test" for each renderable task is: build, launch with `PYMOL_AUTOCMD`, capture the window by PID, and visually verify. Reusable harness (already on disk): `/tmp/winforpid` (compiled), and this snippet:

```bash
APP=/Users/jcastellanos/repos/pymol-open-source/swiftui/build_xcode/Build/Products/Debug/PyMOLViewer.app
BIN="$APP/Contents/MacOS/PyMOLViewer"
cap() { # $1 = pymol cmds, $2 = out.png
  pkill -9 -f "$BIN" 2>/dev/null; sleep 1
  rm -rf "$HOME/Library/Saved Application State/org.pymol.viewer.savedState"
  PYMOL_AUTOCMD="$1" open -nF "$APP"; sleep 8
  PID=$(pgrep -n -f "$BIN"); WIN=$(/tmp/winforpid "$PID" 2>/dev/null)
  [ -n "$WIN" ] && screencapture -o -x -l"$WIN" "$2" && echo "captured $2 (pid=$PID win=$WIN)"
  ls -t ~/Library/Logs/DiagnosticReports/PyMOLViewer* 2>/dev/null | head -1 | xargs -I{} basename {}
  pkill -9 -f "$BIN" 2>/dev/null
}
```

Build commands used throughout:
```bash
cd /Users/jcastellanos/repos/pymol-open-source && bash swiftui/build_macos.sh 2>&1 | grep -iE "error:" | head
cd /Users/jcastellanos/repos/pymol-open-source/swiftui && xcodebuild -project PyMOLViewer.xcodeproj -scheme PyMOLViewer_macOS -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$(pwd)/build_xcode" build 2>&1 | grep -iE "BUILD (SUCCEEDED|FAILED)|error: .*\.(swift|mm|cpp)"
```

---

## File Structure

- **`layerGraphics/metal/RendererMetal.h`** — add member pipelines/funcs + `drawSphereImpostors` / `drawCylinderImpostors` declarations.
- **`layerGraphics/metal/RendererMetal.mm`** — add inline MSL impostor shaders, `buildImpostorPipelines()`, and the two draw methods.
- **`layerGraphics/Renderer.h`** — add `drawSphereImpostors`/`drawCylinderImpostors` virtual no-op declarations on the base `Renderer` (so `CGOGL.cpp`, which only sees `pymol::Renderer*`, can call them).
- **`layer1/CGOGL.cpp`** — fill in the Metal branches of `CGO_gl_draw_sphere_buffers` (~812) and `CGO_gl_draw_cylinder_buffers` (~874); add small `drawSphereImpostorsViaMetal` / `drawCylinderImpostorsViaMetal` helpers near `drawVBOViaMetal`.
- **`layer2/RepSphere.cpp`** — lift the `sphere_mode 9 → 0` downgrade in `RepGetSphereMode` for the Metal renderer.
- **`layer2/RepCylinder.cpp`** (or wherever sticks choose impostor-vs-geometry) — lift the analogous cylinder downgrade.

---

# STAGE 1 — SPHERES

## Task 1: Add base-class `drawSphereImpostors` hook

**Files:**
- Modify: `layerGraphics/Renderer.h`

- [ ] **Step 1: Add the virtual no-op to the base Renderer** (after the existing `drawLabels` declaration / `LabelDrawCall`)

```cpp
  // Sphere impostors: interleaved VBO (4 verts/sphere) with attributes
  // a_vertex_radius (Float4 center+radius), a_Color (UByte4Norm), a_rightUpFlags.
  // offsets are byte offsets within `stride` (-1 = absent). Default: no-op.
  struct SphereImpostorDrawCall {
    int sphereCount = 0;
    const void* data = nullptr;
    size_t dataSize = 0;
    size_t stride = 0;
    int posRadiusOff = -1;   // a_vertex_radius (Float4)
    int colorOff = -1;       // a_Color (UByte4Norm)
    int rightUpOff = -1;     // a_rightUpFlags
    int rightUpIsFloat = 1;  // 1 = Float, 0 = UByte
    float sphereSizeScale = 1.0f;
    int ortho = 0;           // 1 = orthographic
  };
  virtual void drawSphereImpostors(const SphereImpostorDrawCall&) {}
```

- [ ] **Step 2: Build the core lib to confirm it compiles**

Run: `cd /Users/jcastellanos/repos/pymol-open-source && bash swiftui/build_macos.sh 2>&1 | grep -iE "error:" | head`
Expected: no `error:` lines.

- [ ] **Step 3: Commit**

```bash
git add layerGraphics/Renderer.h
git commit -m "feat(metal): add drawSphereImpostors hook on base Renderer"
```

## Task 2: Sphere impostor MSL shaders + pipeline in RendererMetal

**Files:**
- Modify: `layerGraphics/metal/RendererMetal.h`
- Modify: `layerGraphics/metal/RendererMetal.mm`

- [ ] **Step 1: Declare members + builder in RendererMetal.h** (near `_vboVertexFunc` etc.)

```objc
  id<MTLRenderPipelineState> _sphereImpostorPipeline = nil;
  id<MTLBuffer> _sphereIndexBuffer = nil;   // 6 indices/sphere (quad->2 tris)
  NSUInteger _sphereIndexCapacity = 0;      // # spheres the index buffer covers
```
And in the private methods section:
```objc
  void buildImpostorPipelines();
```
And the public override (near `drawLabels`):
```objc
  void drawSphereImpostors(const SphereImpostorDrawCall& call) override;
```

- [ ] **Step 2: Add the inline MSL + pipeline builder in RendererMetal.mm** (place near `buildVBOPipelines`; call `buildImpostorPipelines()` lazily from `drawSphereImpostors` if `_sphereImpostorPipeline == nil`)

```objc
static NSString* const kSphereImpostorSrc = @R"(
#include <metal_stdlib>
using namespace metal;

struct SphereIn {
  float4 vertex_radius [[attribute(0)]];  // center xyz + radius
  float4 color         [[attribute(1)]];  // UByte4Norm -> float4
  float  rightUpFlags  [[attribute(2)]];
};
struct SphereU {
  float4x4 modelview;
  float4x4 projection;
  float sphere_size_scale;
  float ortho;          // 1 = orthographic
  float depthZeroToOne; // 1 if clip Z already [0,1]; else apply 0.5+0.5 remap
  float _pad;
};
struct SphereVOut {
  float4 position [[position]];
  float4 color;
  float3 sphere_center;  // eye space
  float  radius2;
  float3 point;          // eye-space impostor point
};
struct SphereFOut {
  float4 color [[color(0)]];
  float  depth [[depth(any)]];
};

static float2 outer_tangent_adjustment(float3 center, float radius_sq) {
  float2 xy_dist = float2(length(center.xz), length(center.yz));
  float2 cos_a = clamp(center.z / xy_dist, -1.0, 1.0);
  float2 cos_b = xy_dist / sqrt(radius_sq + (xy_dist * xy_dist));
  float2 cos_ab = cos_a * cos_b + sqrt((1.0 - cos_a*cos_a) * (1.0 - cos_b*cos_b));
  float2 cos_ab_sq = cos_ab * cos_ab;
  float2 tan_ab_sq = (1.0 - cos_ab_sq) / cos_ab_sq;
  return min(sqrt(tan_ab_sq + 1.0), 10.0);
}

vertex SphereVOut sphere_impostor_vertex(SphereIn in [[stage_in]],
    constant SphereU& u [[buffer(1)]]) {
  SphereVOut out;
  float radius = in.vertex_radius.w * u.sphere_size_scale;
  float3 mvcol0 = float3(u.modelview[0].x, u.modelview[0].y, u.modelview[0].z);
  radius /= max(length(mvcol0), 1e-6);
  float right = -1.0 + 2.0 * fmod(in.rightUpFlags, 2.0);
  float up    = -1.0 + 2.0 * floor(fmod(in.rightUpFlags / 2.0, 2.0));
  float4 tmppos = u.modelview * float4(in.vertex_radius.xyz, 1.0);
  out.color = in.color;
  out.radius2 = radius * radius;
  float2 corner = float2(right, up);
  if (u.ortho < 0.5)
    corner *= outer_tangent_adjustment(tmppos.xyz, out.radius2);
  float4 eyePos = tmppos;
  eyePos.xy += radius * corner;
  out.sphere_center = tmppos.xyz / tmppos.w;
  out.point = eyePos.xyz / eyePos.w;
  out.position = u.projection * eyePos;
  return out;
}

fragment SphereFOut sphere_impostor_fragment(SphereVOut in [[stage_in]],
    constant SphereU& u [[buffer(1)]]) {
  float3 ray_origin, ray_dir, sphere_dir;
  if (u.ortho >= 0.5) {
    ray_origin = in.point; ray_dir = float3(0.0,0.0,-1.0);
    sphere_dir = ray_origin - in.sphere_center;
  } else {
    ray_origin = float3(0.0); ray_dir = normalize(in.point);
    sphere_dir = in.sphere_center;
  }
  float b = dot(sphere_dir, ray_dir);
  float position = b*b + in.radius2 - dot(sphere_dir, sphere_dir);
  if (position < 0.0) discard_fragment();
  float nearest = b - sqrt(position);
  float3 ipoint = nearest * ray_dir + ray_origin;
  float3 normal = normalize(ipoint - in.sphere_center);
  float4 clip = u.projection * float4(ipoint, 1.0);
  float ndcz = clip.z / clip.w;
  float depth = (u.depthZeroToOne >= 0.5) ? ndcz : (0.5 + 0.5 * ndcz);
  if (depth <= 0.0 || depth >= 1.0) discard_fragment();
  // headlight diffuse + Blinn-Phong specular (eye looks down -Z, light at +Z)
  float3 L = float3(0.0, 0.0, 1.0);
  float NdotL = max(dot(normal, L), 0.0);
  float3 H = normalize(L + float3(0.0,0.0,1.0));
  float spec = pow(max(dot(normal, H), 0.0), 32.0);
  float ambient = 0.25;
  float3 rgb = in.color.rgb * (ambient + (1.0 - ambient) * NdotL) + spec * 0.6;
  SphereFOut out;
  out.color = float4(rgb, in.color.a);
  out.depth = depth;
  return out;
}
)";

void RendererMetal::buildImpostorPipelines()
{
  if (_sphereImpostorPipeline) return;
  NSError* err = nil;
  id<MTLLibrary> lib = [_device newLibraryWithSource:kSphereImpostorSrc options:nil error:&err];
  if (!lib) { NSLog(@"RendererMetal: sphere impostor compile failed: %@", err); return; }
  id<MTLFunction> vfn = [lib newFunctionWithName:@"sphere_impostor_vertex"];
  id<MTLFunction> ffn = [lib newFunctionWithName:@"sphere_impostor_fragment"];
  if (!vfn || !ffn) { NSLog(@"RendererMetal: sphere impostor funcs missing"); return; }

  MTLVertexDescriptor* vd = [[MTLVertexDescriptor alloc] init];
  vd.attributes[0].format = MTLVertexFormatFloat4;          // a_vertex_radius
  vd.attributes[0].offset = 0;  vd.attributes[0].bufferIndex = 0;
  vd.attributes[1].format = MTLVertexFormatUChar4Normalized; // a_Color
  vd.attributes[1].offset = 16; vd.attributes[1].bufferIndex = 0;
  vd.attributes[2].format = MTLVertexFormatFloat;            // a_rightUpFlags
  vd.attributes[2].offset = 20; vd.attributes[2].bufferIndex = 0;
  vd.layouts[0].stride = 24;
  vd.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;
  // NOTE: the stride/offsets above are the EXPECTED packing; Task 4 passes the
  // real offsets from the VBO and rebuilds this descriptor per-draw if they
  // differ. Keep this prebuilt pipeline for the common packing.

  MTLRenderPipelineDescriptor* psd = [[MTLRenderPipelineDescriptor alloc] init];
  psd.vertexFunction = vfn; psd.fragmentFunction = ffn; psd.vertexDescriptor = vd;
  psd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
  psd.colorAttachments[0].blendingEnabled = YES;
  psd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
  psd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
  psd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
  psd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
  psd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
  psd.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
  _sphereImpostorPipeline = [_device newRenderPipelineStateWithDescriptor:psd error:&err];
  if (!_sphereImpostorPipeline) NSLog(@"RendererMetal: sphere impostor pipeline failed: %@", err);
}
```

- [ ] **Step 3: Build core + app**

Run the two build commands (top of plan).
Expected: BUILD SUCCEEDED, no errors. (Pipeline is unused so far.)

- [ ] **Step 4: Commit**

```bash
git add layerGraphics/metal/RendererMetal.h layerGraphics/metal/RendererMetal.mm
git commit -m "feat(metal): sphere impostor MSL shaders + pipeline (unwired)"
```

## Task 3: Implement `RendererMetal::drawSphereImpostors`

**Files:**
- Modify: `layerGraphics/metal/RendererMetal.mm`

- [ ] **Step 1: Implement the draw method** (after `drawVBO`/`drawVBOIndexed`)

```objc
void RendererMetal::drawSphereImpostors(const SphereImpostorDrawCall& call)
{
  if (!call.data || call.dataSize == 0 || call.sphereCount <= 0) return;
  ensureEncoder();
  if (!_encoder) return;
  buildImpostorPipelines();
  if (!_sphereImpostorPipeline) return;

  // Vertex buffer (reuse cache by data pointer, like drawVBO).
  id<MTLBuffer> vbo = nil;
  auto it = _vboCache.find(call.data);
  if (it != _vboCache.end()) vbo = it->second;
  else {
    vbo = [_device newBufferWithBytes:call.data length:call.dataSize
                              options:MTLResourceStorageModeShared];
    if (!vbo) return;
    _vboCache[call.data] = vbo;
  }

  // Index buffer: 6 indices per sphere mapping the 4 quad corners (0,1,2,0,2,3).
  NSUInteger nSph = (NSUInteger)call.sphereCount;
  if (!_sphereIndexBuffer || _sphereIndexCapacity < nSph) {
    std::vector<uint32_t> idx(nSph * 6);
    for (NSUInteger s = 0; s < nSph; ++s) {
      uint32_t b = (uint32_t)(s * 4);
      idx[s*6+0]=b+0; idx[s*6+1]=b+1; idx[s*6+2]=b+2;
      idx[s*6+3]=b+0; idx[s*6+4]=b+2; idx[s*6+5]=b+3;
    }
    _sphereIndexBuffer = [_device newBufferWithBytes:idx.data()
                            length:idx.size()*sizeof(uint32_t)
                            options:MTLResourceStorageModeShared];
    _sphereIndexCapacity = nSph;
  }
  if (!_sphereIndexBuffer) return;

  // Build a vertex descriptor from the REAL offsets so packing differences are
  // handled; reuse the prebuilt pipeline only if offsets match (0/16/20, stride 24).
  bool common = (call.posRadiusOff == 0 && call.colorOff == 16 &&
                 call.rightUpOff == 20 && call.stride == 24 && call.rightUpIsFloat);
  id<MTLRenderPipelineState> pipeline = _sphereImpostorPipeline;
  if (!common) {
    // Recreate a pipeline with a matching vertex descriptor (driver-cached).
    MTLVertexDescriptor* vd = [[MTLVertexDescriptor alloc] init];
    vd.attributes[0].format = MTLVertexFormatFloat4;
    vd.attributes[0].offset = call.posRadiusOff; vd.attributes[0].bufferIndex = 0;
    vd.attributes[1].format = MTLVertexFormatUChar4Normalized;
    vd.attributes[1].offset = call.colorOff;     vd.attributes[1].bufferIndex = 0;
    vd.attributes[2].format = call.rightUpIsFloat ? MTLVertexFormatFloat : MTLVertexFormatUCharNormalized;
    vd.attributes[2].offset = call.rightUpOff;    vd.attributes[2].bufferIndex = 0;
    vd.layouts[0].stride = call.stride;
    vd.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;
    // Reuse the same functions via a fresh descriptor: rebuild library once is
    // expensive; instead keep _sphereImpostorPipeline for the common case and
    // log if we hit the uncommon path (then implement a cached variant).
    NSLog(@"RendererMetal: sphere impostor non-standard packing pos=%d col=%d ru=%d stride=%zu", call.posRadiusOff, call.colorOff, call.rightUpOff, call.stride);
    return; // Task 4 verifies the common packing holds; revisit only if this logs.
  }

  [_encoder setRenderPipelineState:pipeline];
  applyDepthStencilState();
  if (_depthStencilState) [_encoder setDepthStencilState:_depthStencilState];
  [_encoder setVertexBuffer:vbo offset:0 atIndex:0];

  struct {
    float modelview[16];
    float projection[16];
    float sphere_size_scale;
    float ortho;
    float depthZeroToOne;
    float _pad;
  } u;
  std::memcpy(u.modelview, _modelviewMatrix.data(), 64);
  std::memcpy(u.projection, _projectionMatrix.data(), 64);
  u.sphere_size_scale = call.sphereSizeScale;
  u.ortho = (float)call.ortho;
  u.depthZeroToOne = 1.0f;   // assume Metal [0,1] clip Z; verified in Task 4
  u._pad = 0.0f;
  [_encoder setVertexBytes:&u length:sizeof(u) atIndex:1];

  [_encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                       indexCount:nSph * 6
                        indexType:MTLIndexTypeUInt32
                      indexBuffer:_sphereIndexBuffer
                indexBufferOffset:0];
}
```

- [ ] **Step 2: Build core + app** — Expected BUILD SUCCEEDED (still unwired).

- [ ] **Step 3: Commit**

```bash
git add layerGraphics/metal/RendererMetal.mm
git commit -m "feat(metal): implement drawSphereImpostors (indexed quad->tris)"
```

## Task 4: Wire `CGO_gl_draw_sphere_buffers` Metal branch + lift the rep gate

**Files:**
- Modify: `layer1/CGOGL.cpp` (~812; add helper near `drawVBOViaMetal` ~28)
- Modify: `layer2/RepSphere.cpp` (`RepGetSphereMode` ~142-145)

- [ ] **Step 1: Add a forward decl near the other static decls (CGOGL.cpp ~90)**

```cpp
static void drawSphereImpostorsViaMetal(CCGORenderer* I, const cgo::draw::sphere_buffers* sp);
```

- [ ] **Step 2: Replace the early-return in `CGO_gl_draw_sphere_buffers` (CGOGL.cpp ~814)**

```cpp
static void CGO_gl_draw_sphere_buffers(CCGORenderer* I, CGO_op_data pc)
{
  const cgo::draw::sphere_buffers* sp = reinterpret_cast<decltype(sp)>(*pc);
  if (I->G->Renderer) {
    if (!I->isPicking)            // picking uses CPU metal_pick
      drawSphereImpostorsViaMetal(I, sp);
    return;
  }
  // ... existing GL code stays below ...
```
(Remove the old bare `if (I->G->Renderer) return;` and the now-redundant later `sp` re-read if present.)

- [ ] **Step 3: Add the helper (CGOGL.cpp, after `drawVBOViaMetal`)**

```cpp
static void drawSphereImpostorsViaMetal(CCGORenderer* I, const cgo::draw::sphere_buffers* sp)
{
  auto* G = I->G;
  auto* vbo = G->ShaderMgr->getGPUBuffer<VertexBufferGL>(sp->vboid);
  if (!vbo || !vbo->hasCPUData()) return;

  pymol::Renderer::SphereImpostorDrawCall call;
  call.data = vbo->cpuData();
  call.dataSize = vbo->cpuDataSize();
  call.stride = vbo->cpuStride();
  call.sphereCount = sp->num_spheres;
  for (const auto& d : vbo->getDesc().descs) {
    int off = static_cast<int>(d.offset);
    if (d.attr_name == "a_vertex_radius") call.posRadiusOff = off;
    else if (d.attr_name == "a_Color")    call.colorOff = off;
    else if (d.attr_name == "a_rightUpFlags") {
      call.rightUpOff = off;
      call.rightUpIsFloat = (d.m_format == VertexFormat::Float) ? 1 : 0;
    }
  }
  call.sphereSizeScale = SettingGet_f(G, I->set1, I->set2, cSetting_sphere_scale);
  // sphere_scale is the default; sphere.vs multiplies a_vertex_radius.w by
  // sphere_size_scale which the GL path sets to 1.0 via DOTSIZE_WITH_SPHERESCALE
  // / the sphere shader's sphere_size_scale uniform = 1.0 unless overridden.
  // The radius is already baked into a_vertex_radius.w, so use 1.0 here:
  call.sphereSizeScale = 1.0f;
  call.ortho = SettingGetGlobal_b(G, cSetting_ortho) ? 1 : 0;

  G->Renderer->drawSphereImpostors(call);
}
```

> Note: confirm `cgo::draw::sphere_buffers` member name `num_spheres` and `vboid` (CGO.h ~407-419). The radius is pre-scaled into `a_vertex_radius.w` by the rep, so `sphere_size_scale = 1.0`.

- [ ] **Step 4: Lift the rep gate (RepSphere.cpp ~142-145)**

Change:
```cpp
  case 9:
    if (!use_shader || !G->ShaderMgr->ShaderPrgExists("sphere")) {
      sphere_mode = 0;
    }
```
to:
```cpp
  case 9:
    // On the Metal renderer the GL "sphere" shader doesn't exist, but the
    // Metal impostor pipeline does — keep mode 9 so sphere_buffers are emitted.
    if (!use_shader || (!G->Renderer && !G->ShaderMgr->ShaderPrgExists("sphere"))) {
      sphere_mode = 0;
    }
```

- [ ] **Step 5: Build core + app**

Run both build commands. Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Verify rendering (screenshot)**

```bash
P=/Users/jcastellanos/repos/pymol-open-source/1ubq.cif
cap "load $P, mol;hide everything;show spheres;color salmon;orient" /tmp/imp_spheres.png
```
Then Read `/tmp/imp_spheres.png`. Expected: smooth, round, shaded spheres with **specular highlights** (not faceted), filling the molecule; NO new crash report.

- [ ] **Step 7: Verify depth occlusion (the critical check)**

```bash
P=/Users/jcastellanos/repos/pymol-open-source/1ubq.cif
cap "load $P, mol;hide everything;show cartoon;spectrum count,rainbow;show spheres, resn LYS;color yellow, resn LYS;orient" /tmp/imp_depth.png
```
Read `/tmp/imp_depth.png`. Expected: the yellow LYS spheres correctly occlude / are occluded by the rainbow cartoon (consistent depth). **If the spheres float in front of everything or are wrongly hidden**, the depth convention is off → set `u.depthZeroToOne = 0.0f` in `drawSphereImpostors` (apply the `0.5+0.5` remap), rebuild, re-verify. Iterate until occlusion is correct; that fixes the convention permanently.

- [ ] **Step 8: Commit**

```bash
git add layer1/CGOGL.cpp layer2/RepSphere.cpp
git commit -m "feat(metal): render spheres as analytic impostors (wire + lift rep gate)"
```

## Task 5: Tune sphere lighting/radius if needed; finalize stage 1

- [ ] **Step 1:** Compare `/tmp/imp_spheres.png` to desktop PyMOL's sphere look. If specular is too hot/dull, adjust the `spec * 0.6` factor and `pow(...,32.0)` shininess in the fragment shader; if radius looks wrong vs. the cartoon scale, re-check `sphere_size_scale` (should be 1.0; radius baked in). Rebuild + re-capture `/tmp/imp_spheres.png` and confirm.

- [ ] **Step 2: Commit any tuning**

```bash
git add layerGraphics/metal/RendererMetal.mm
git commit -m "polish(metal): tune sphere impostor specular/radius"
```

---

# STAGE 2 — CYLINDERS

## Task 6: Add base-class `drawCylinderImpostors` hook

**Files:**
- Modify: `layerGraphics/Renderer.h`

- [ ] **Step 1: Add the struct + virtual** (after `SphereImpostorDrawCall`)

```cpp
  // Cylinder impostors: interleaved VBO (8 verts/cylinder) + index buffer.
  struct CylinderImpostorDrawCall {
    int cylinderCount = 0;
    const void* vdata = nullptr;  size_t vdataSize = 0;  size_t stride = 0;
    const void* idata = nullptr;  size_t idataSize = 0;  int indexCount = 0;
    int v1Off=-1, v2Off=-1, colorOff=-1, color2Off=-1, radiusOff=-1, capOff=-1, flagsOff=-1;
    int colorIsFloat = 1; // a_Color format: 1=Float4, 0=UByte4Norm
    float uniRadius = 0.0f;   // uni_radius (0 => use attr_radius directly)
    int ortho = 0;
    int noFlatCaps = 0;       // cSetting_no_flat_caps style flag
  };
  virtual void drawCylinderImpostors(const CylinderImpostorDrawCall&) {}
```

- [ ] **Step 2: Build core** — no errors.
- [ ] **Step 3: Commit**

```bash
git add layerGraphics/Renderer.h
git commit -m "feat(metal): add drawCylinderImpostors hook on base Renderer"
```

## Task 7: Cylinder impostor MSL + pipeline

**Files:**
- Modify: `layerGraphics/metal/RendererMetal.{h,mm}`

- [ ] **Step 1: Declare members/override in RendererMetal.h**

```objc
  id<MTLRenderPipelineState> _cylinderImpostorPipeline = nil;
  // ... and:
  void drawCylinderImpostors(const CylinderImpostorDrawCall& call) override;
```

- [ ] **Step 2: Add inline MSL (ported from cylinder.vs/fs) + build in `buildImpostorPipelines()`**

```metal
// (kCylinderImpostorSrc — append to buildImpostorPipelines, build a 2nd pipeline)
#include <metal_stdlib>
using namespace metal;
struct CylIn {
  float3 vertex1 [[attribute(0)]];
  float3 vertex2 [[attribute(1)]];
  float4 color   [[attribute(2)]];
  float4 color2  [[attribute(3)]];
  float  radius  [[attribute(4)]];
  float  cap     [[attribute(5)]];
  float  flags   [[attribute(6)]];
};
struct CylU {
  float4x4 modelview;
  float4x4 projection;
  float uni_radius;
  float ortho;
  float depthZeroToOne;
  float no_flat_caps;
};
struct CylVOut {
  float4 position [[position]];
  float3 surface_point;
  float3 axis; float3 base; float3 end_cyl;
  float3 U; float3 V;
  float radius; float cap; float inv_sqr_height;
  float4 color1; float4 color2;
};
struct CylFOut { float4 color [[color(0)]]; float depth [[depth(any)]]; };

inline float3x3 normalMat(float4x4 mv) {
  // inverse-transpose of upper-left 3x3; for rotation == the 3x3 itself.
  return float3x3(mv[0].xyz, mv[1].xyz, mv[2].xyz);
}
inline float get_bit_and_shift(thread float& bits) {
  float bit = fmod(bits, 2.0); bits = (bits - bit) / 2.0; return step(0.5, bit);
}

vertex CylVOut cyl_impostor_vertex(CylIn in [[stage_in]], constant CylU& u [[buffer(1)]]) {
  CylVOut o;
  float3x3 N = normalMat(u.modelview);
  float uniformglscale = length(N[0]);
  o.radius = (u.uni_radius != 0.0) ? (u.uni_radius * in.radius) : in.radius;
  o.color1 = in.color; o.color2 = in.color2;
  float3 attr_axis = in.vertex2 - in.vertex1;
  o.cap = in.cap;
  float ish = length(attr_axis) / uniformglscale; ish *= ish; o.inv_sqr_height = 1.0/ish;
  float3 h = normalize(attr_axis);
  o.axis = normalize(N * h);
  float3 uu = cross(h, float3(1.0,0.0,0.0));
  if (dot(uu,uu) < 0.001) uu = cross(h, float3(0.0,1.0,0.0));
  uu = normalize(uu);
  float3 vv = normalize(cross(uu, h));
  o.U = normalize(N * uu); o.V = normalize(N * vv);
  float4 base4 = u.modelview * float4(in.vertex1, 1.0); o.base = base4.xyz;
  float4 end4  = u.modelview * float4(in.vertex2, 1.0); o.end_cyl = end4.xyz;
  float4 vertex = float4(in.vertex1, 1.0);
  float pf = in.flags;
  float out_v = get_bit_and_shift(pf);
  float up_v  = get_bit_and_shift(pf);
  float right_v = get_bit_and_shift(pf);
  vertex.xyz += up_v * attr_axis;
  vertex.xyz += (2.0*right_v - 1.0) * o.radius * uu;
  vertex.xyz += (2.0*out_v   - 1.0) * o.radius * vv;
  vertex.xyz += (2.0*up_v    - 1.0) * o.radius * h;
  float4 tvertex = u.modelview * vertex; o.surface_point = tvertex.xyz;
  o.position = u.projection * tvertex;
  o.radius /= uniformglscale;
  return o;
}

fragment CylFOut cyl_impostor_fragment(CylVOut in [[stage_in]], constant CylU& u [[buffer(1)]]) {
  float3 ray_target = in.surface_point;
  float3 ray_origin, ray_dir;
  if (u.ortho >= 0.5) { ray_origin = in.surface_point; ray_dir = float3(0.0,0.0,1.0); }
  else { ray_origin = float3(0.0); ray_dir = normalize(-ray_target); }
  float3x3 basis = float3x3(in.U, in.V, in.axis);
  float2 P = (ray_target - in.base) * basis;   // .xy of the 3-vector
  float2 D = (ray_dir) * basis;
  // NOTE: in MSL, (vec * mat3) does row-vector*matrix; verify it matches GLSL
  // 'vec * mat3' (it does: GLSL vec*mat == row-vector*matrix). Take .xy below.
  float r2 = in.radius * in.radius;
  float a0 = P.x*P.x + P.y*P.y - r2;
  float a1 = P.x*D.x + P.y*D.y;
  float a2 = D.x*D.x + D.y*D.y;
  float d = a1*a1 - a0*a2;
  if (d < 0.0) discard_fragment();
  float dist = (-a1 + sqrt(d)) / a2;
  float3 new_point = ray_target + dist * ray_dir;
  float3 tmp = new_point - in.base;
  float3 normal = normalize(tmp - in.axis * dot(tmp, in.axis));
  float fcap = in.cap + 0.001;
  bool frontcap      = get_bit_and_shift(fcap) > 0.5;
  bool endcap        = get_bit_and_shift(fcap) > 0.5;
  bool frontcapround = (get_bit_and_shift(fcap) > 0.5) && (u.no_flat_caps > 0.5);
  bool endcapround   = (get_bit_and_shift(fcap) > 0.5) && (u.no_flat_caps > 0.5);
  bool nocolorinterp = !(get_bit_and_shift(fcap) > 0.5);
  float ratio = dot(new_point - in.base, in.end_cyl - in.base) * in.inv_sqr_height;
  if (nocolorinterp) ratio = step(0.5, ratio); else ratio = clamp(ratio, 0.0, 1.0);
  float4 color = mix(in.color1, in.color2, ratio);
  bool cap_base = 0.0 > dot(new_point - in.base, in.axis);
  bool cap_end  = 0.0 < dot(new_point - in.end_cyl, in.axis);
  if (cap_base || cap_end) {
    float3 thisaxis = -in.axis; float3 thisbase = in.base;
    if (cap_end) { thisaxis = in.axis; thisbase = in.end_cyl; frontcap = endcap; frontcapround = endcapround; }
    if (!frontcap) discard_fragment();
    if (frontcapround) {
      float3 sd = thisbase - ray_origin;
      float b = dot(sd, ray_dir);
      float pos = b*b + r2 - dot(sd, sd);
      if (pos < 0.0) discard_fragment();
      float nr = sqrt(pos) + b; new_point = nr * ray_dir + ray_origin; normal = normalize(new_point - thisbase);
    } else {
      float dNV = dot(thisaxis, ray_dir);
      if (dNV < 0.0) discard_fragment();
      float nr = dot(thisaxis, thisbase - ray_origin) / dNV;
      new_point = ray_dir * nr + ray_origin;
      if (dot(new_point - thisbase, new_point - thisbase) > r2) discard_fragment();
      normal = thisaxis;
    }
  }
  float4 clip = u.projection * float4(new_point, 1.0);
  float ndcz = clip.z / clip.w;
  float depth = (u.depthZeroToOne >= 0.5) ? ndcz : (0.5 + 0.5 * ndcz);
  if (depth <= 0.0) discard_fragment();
  float3 L = float3(0.0,0.0,1.0);
  float NdotL = max(dot(normal, L), 0.0);
  float3 H = normalize(L + float3(0.0,0.0,1.0));
  float spec = pow(max(dot(normal, H), 0.0), 32.0);
  float3 rgb = color.rgb * (0.25 + 0.75 * NdotL) + spec * 0.6;
  CylFOut o; o.color = float4(rgb, color.a); o.depth = depth; return o;
}
```
Build a second pipeline `_cylinderImpostorPipeline` in `buildImpostorPipelines()` with a vertex descriptor for the 7 attributes (Float3 v1, Float3 v2, Float4/UByte4Norm color, Float4 color2, Float radius, Float cap, Float flags) — offsets supplied per-draw in Task 8 (mirror the sphere approach; the common packing pipeline + per-draw guard).

- [ ] **Step 3: Build core + app** — BUILD SUCCEEDED (unwired).
- [ ] **Step 4: Commit**

```bash
git add layerGraphics/metal/RendererMetal.h layerGraphics/metal/RendererMetal.mm
git commit -m "feat(metal): cylinder impostor MSL + pipeline (unwired)"
```

## Task 8: Implement `drawCylinderImpostors` + wire branch + lift cylinder gate

**Files:**
- Modify: `layerGraphics/metal/RendererMetal.mm`, `layer1/CGOGL.cpp` (~874), the cylinder rep mode gate.

- [ ] **Step 1: Implement `drawCylinderImpostors`** — mirror `drawSphereImpostors` but use the supplied index buffer (`call.idata`/`indexCount`, `drawIndexedPrimitives`), uniform struct `{modelview, projection, uni_radius, ortho, depthZeroToOne, no_flat_caps}`, and the cylinder vertex descriptor from the real offsets.

```objc
void RendererMetal::drawCylinderImpostors(const CylinderImpostorDrawCall& call) {
  if (!call.vdata || !call.idata || call.indexCount <= 0) return;
  ensureEncoder(); if (!_encoder) return;
  buildImpostorPipelines(); if (!_cylinderImpostorPipeline) return;
  id<MTLBuffer> vbo, ibo;
  { auto it=_vboCache.find(call.vdata); if(it!=_vboCache.end()) vbo=it->second;
    else { vbo=[_device newBufferWithBytes:call.vdata length:call.vdataSize options:MTLResourceStorageModeShared]; if(vbo)_vboCache[call.vdata]=vbo; } }
  { auto it=_vboCache.find(call.idata); if(it!=_vboCache.end()) ibo=it->second;
    else { ibo=[_device newBufferWithBytes:call.idata length:call.idataSize options:MTLResourceStorageModeShared]; if(ibo)_vboCache[call.idata]=ibo; } }
  if(!vbo||!ibo) return;
  [_encoder setRenderPipelineState:_cylinderImpostorPipeline];
  applyDepthStencilState(); if(_depthStencilState)[_encoder setDepthStencilState:_depthStencilState];
  [_encoder setVertexBuffer:vbo offset:0 atIndex:0];
  struct { float modelview[16]; float projection[16]; float uni_radius; float ortho; float depthZeroToOne; float no_flat_caps; } u;
  std::memcpy(u.modelview,_modelviewMatrix.data(),64);
  std::memcpy(u.projection,_projectionMatrix.data(),64);
  u.uni_radius=call.uniRadius; u.ortho=(float)call.ortho; u.depthZeroToOne=1.0f; u.no_flat_caps=(float)call.noFlatCaps;
  [_encoder setVertexBytes:&u length:sizeof(u) atIndex:1];
  [_encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:call.indexCount indexType:MTLIndexTypeUInt32 indexBuffer:ibo indexBufferOffset:0];
}
```
> Verify the index buffer element type (UInt32 vs UInt16) from the cylinder IndexBufferGL; adjust `MTLIndexTypeUInt16` if needed.

- [ ] **Step 2: Wire `CGO_gl_draw_cylinder_buffers` (CGOGL.cpp ~874)** — mirror the sphere helper: extract the VBO (attr_vertex1/2, a_Color, a_Color2, attr_radius, a_cap, attr_flags) offsets + the IBO CPU data, set `uniRadius` from the `CYLINDERWIDTH_*` special/`uni_radius` (read from `cgo::draw::cylinder_buffers`), `no_flat_caps` from `cSetting_no_flat_caps` style logic, `ortho`, and call `drawCylinderImpostors`. Confirm `cgo::draw::cylinder_buffers` member names (`vboid`, `iboid`, `num_cyl`, `vertsperpickinfo`).

- [ ] **Step 3: Lift the cylinder rep gate** so sticks emit `cylinder_buffers` on Metal (analogous to RepSphere — find where the cylinder/stick rep downgrades the impostor path when the GL "cylinder" shader is absent, and add the `!G->Renderer` condition).

- [ ] **Step 4: Build core + app** — BUILD SUCCEEDED.

- [ ] **Step 5: Verify (screenshot)**

```bash
P=/Users/jcastellanos/repos/pymol-open-source/1ubq.cif
cap "load $P, mol;hide everything;show sticks;color marine;orient" /tmp/imp_sticks.png
cap "load $P, mol;hide everything;show sticks;show spheres;set sphere_scale,0.25;util.cbag mol;orient" /tmp/imp_ballstick.png
```
Read both. Expected: smooth cylindrical sticks with rounded/flat caps, two-tone bond coloring, correct depth; ball-and-stick joins cleanly; no crash. If depth wrong, set cylinder `depthZeroToOne` to match what spheres needed.

- [ ] **Step 6: Commit**

```bash
git add layerGraphics/metal/RendererMetal.mm layer1/CGOGL.cpp layer2/*.cpp
git commit -m "feat(metal): render cylinders/sticks as analytic impostors"
```

## Task 9: Regression + finalize

- [ ] **Step 1:** Re-capture the full rep sweep to confirm no regressions: cartoon, surface, mesh, lines, ribbon, dots, labels still render; spheres+sticks now impostors. Use `cap` for each; Read each PNG.
- [ ] **Step 2:** Update memory `macos_metal_parity.md` with the impostor status + the resolved `depthZeroToOne` convention.
- [ ] **Step 3: Commit** any doc/memory updates.

---

## Self-review notes

- **Spec coverage:** spheres (Tasks 1–5), cylinders (Tasks 6–8), depth convention (Task 4 Step 7 empirical resolution), specular lighting (in both fragment shaders), picking unchanged (no task needed), testing (screenshot steps), staging (Stage 1 then 2). Covered.
- **Open items intentionally resolved at implementation:** (a) `depthZeroToOne` value — resolved empirically in Task 4 Step 7 and reused for cylinders; (b) `a_rightUpFlags`/`a_Color` exact formats — read from `getDesc()` at runtime; (c) cylinder index type UInt16/32 — verified in Task 8 Step 1; (d) exact `cgo::draw::*_buffers` member names — verified against CGO.h while wiring. These are verifications, not placeholders.
- **Type consistency:** `SphereImpostorDrawCall`/`CylinderImpostorDrawCall` field names match between `Renderer.h`, the `drawXImpostors` implementations, and the CGOGL helpers.
