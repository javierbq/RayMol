# PyMOL OpenGL Feature Audit — Complete Rendering Pipeline

**Date**: 2026-03-22
**Objective**: Understand complete OpenGL requirements for Metal backend planning

---

## 1. Shader Inventory

### Total Shaders: 41 files, ~1,840 lines of code

**Breakdown**:
- **Vertex Shaders (.vs)**: 19 files
  - bezier, bg, connector, copy, cylinder, default, indicator, label, line, oit, ramp, screen, sphere, surface, trilines, volume, vrcontroller, webgl_header, + 1 more

- **Fragment Shaders (.fs)**: 20 files
  - bezier, bg, call_compute_color_for_light, compute_color_for_light, compute_fog_color, connector, copy, cylinder, default, indicator, label, line, oit, ramp, screen, sphere, surface, trilines, volume, vrcontroller, anaglyph_header, webgl_header

- **Geometry Shaders (.gs)**: 2 files
  - connector.gs, 1 other

- **Tessellation Shaders**: Reference found (GL_TESS_CONTROL_SHADER, GL_TESS_EVALUATION_SHADER) but NOT active (no .tcs/.tes files in data/shaders)

### Key Observations
- **WebGL compatibility headers present** (`webgl_header.vs`, `webgl_header.fs`) — conditionals for ES 2.0 and legacy GL
- **No tessellation shader files** — tessellation support coded but not shipped with default shaders
- **Geometry shaders used** — connector visual effects depend on GS (lines → quads)
- **Shader size modest** — 1,840 lines total is manageable for Metal translation

---

## 2. Shader Features & GLSL Characteristics

### GLSL Version
- **Targets**: GLSL 1.2+ (legacy compatible), with ES 2.0 fallbacks
- **Headers found**:
  ```glsl
  #ifdef PURE_OPENGL_ES_2
  precision highp float;
  #endif
  #version 120
  ```
- **Modern constructs**: Geometry shaders (GL 3.2+), vertex/fragment stages only in most files

### Shader Features Used

| Feature | Usage | Context |
|---------|-------|---------|
| `attribute` / `varying` | Dominant (legacy) | Vertex input/varyings for old GLSL |
| `in` / `out` | Some usage | Newer shader compatibility |
| `layout` qualifiers | Minimal | Not heavily used in current shaders |
| `discard` | **9 uses** | Fragment-level alpha testing/cutoff (OIT, sphere impostors, labels) |
| `texture2D()` | 2+ uses | Standard 2D sampling (backwards compat macro) |
| `texture()` | Used | Newer generalized texture function |
| `gl_FragData[N]` | **OIT pipeline** | Order-Independent Transparency — MRT (multi-render-target) writes |
| `gl_FragColor` | Some usage | Single-target legacy output |
| `gl_Position` | All VS | Standard position output |

### Critical Shader Pipeline Features

1. **Order-Independent Transparency (OIT)**
   - Uses `glDrawBuffers()` for MRT (Multiple Render Targets)
   - Writes to `gl_FragData[0]` (color) and `gl_FragData[1]` (weight/reveal)
   - Requires dual-target framebuffer attachment
   - Geometry shader transforms lines → quads (connector)

2. **Impostor Geometry**
   - Sphere, cylinder, connector shaders use ray-casting
   - Heavy use of `discard` for clipping/depth testing
   - Ray-sphere/ray-cylinder intersection in fragment shader

3. **Label/Text Rendering**
   - Uses textured quads with alpha cutoff (`discard`)
   - `gl_PointCoord` + texture sampling

4. **Fog & Lighting**
   - Separate compute functions (`compute_color_for_light.fs`)
   - Phong-style lighting in shader
   - Fog blending on final color

---

## 3. OpenGL Version & Extension Requirements

### Minimum GL Version Required
**OpenGL 2.1** (legacy compatible) to **OpenGL 3.2+** (geometry shaders)

### AppKit Integration (macOS)
Located in `layer5/main_appkit.mm`:
```objective-c
NSOpenGLPixelFormatAttribute attrs[] = {
    NSOpenGLPFADoubleBuffer,
    NSOpenGLPFADepthSize, 24,
    NSOpenGLPFAStencilSize, 8,
    NSOpenGLPFAColorSize, 32,
    NSOpenGLPFAAlphaSize, 8,
    NSOpenGLPFAOpenGLProfile, NSOpenGLProfileVersionLegacy, // GL 2.1 compat
    NSOpenGLPFAAccelerated,
    NSOpenGLPFANoRecovery,
};
```

**Key Context State**:
- Double-buffered RGBA
- 24-bit depth, 8-bit stencil
- 32-bit color + 8-bit alpha
- VSync enabled (`NSOpenGLContextParameterSwapInterval = 1`)
- Retina/HiDPI support requested

### GL Extensions Used

| Extension | Count | Usage |
|-----------|-------|-------|
| `GL_GEOMETRY_SHADER` (GL 3.2) | 1 | connector.gs visual effects |
| `GL_TESS_CONTROL_SHADER` (GL 4.0) | Code present | Not active (no files shipped) |
| `GL_TESS_EVALUATION_SHADER` (GL 4.0) | Code present | Not active (no files shipped) |
| `GL_DRAW_BUFFERS` / MRT | OIT pipeline | Multi-target rendering for transparency |
| `GL_FRAMEBUFFER` / FBO | Offscreen rendering | Post-processing, stereo, screenshots |
| `GL_TEXTURE_CUBE_MAP` | Specular lighting | Cube map for lighting/environment |
| `GL_BLEND_FUNC_SEPARATE` | 1+ use | OIT blending (separate RGB/alpha blend) |

---

## 4. Renderer Abstraction Status

### Current Renderer.h Interface (pymol::Renderer)

**Implemented** in `RendererGL` (gl/RendererGL.cpp):

```cpp
// Frame lifecycle
void beginFrame(), endFrame()

// Viewport & Clear
void viewport(), clear(), clearColor(), scissor()

// State Management
void enable/disable(Capability)
void blendFunc(), depthFunc(), depthMask(), colorMask()
void lineWidth(), pointSize()

// Drawing
void drawArrays(), drawElements()

// Buffers (VBO)
void createBuffer(), deleteBuffer(), bindBuffer(), bufferData()
void vertexAttribPointer(), enableVertexAttribArray(), disableVertexAttribArray()

// Shaders (Program Use Only — NOT Compilation)
void useProgram()
void setUniform1i/1f/2f/3f/4f(), setUniformMatrix3fv(), setUniformMatrix4fv()

// Textures (Binding Only)
void createTexture(), deleteTexture(), bindTexture(), activeTexture()
void texParameteri()

// Framebuffers (Binding Only)
void createFramebuffer(), deleteFramebuffer(), bindFramebuffer()

// Legacy Matrix Stack
void matrixMode(), loadIdentity(), loadMatrixf(), pushMatrix(), popMatrix()
void translatef(), scalef(), multMatrixf()

// Immediate Mode Replacement
void beginBatch(PrimitiveType), batchVertex3f(), batchColor4f(), etc.
void endBatch()

// Queries
void getIntegerv(), getString(), getError()

// Misc
void flush(), finish(), readPixels(), pixelStorei()
```

### What's Abstracted ✅
- Vertex submission (via batching instead of immediate mode)
- Basic state management
- Uniform setting
- Program binding (but NOT creation/compilation)
- Texture binding (but NOT creation/upload details)
- Framebuffer binding (but NOT attachment/creation details)

### What's NOT Abstracted ❌ (Still Direct GL)

**Shader Compilation Pipeline** (~75 calls in ShaderMgr.cpp)
- `glCreateProgram`, `glCreateShader`, `glCompileShader`, `glLinkProgram`
- `glAttachShader`, `glDetachShader`, `glDeleteShader`
- `glGetShaderiv`, `glGetShaderInfoLog`, `glGetProgramiv`, `glGetProgramInfoLog`
- `glGetUniformLocation`, `glGetAttribLocation`
- `glBindAttribLocation`, `glProgramParameteriEXT` (geometry shader params)

**Texture Internals** (~20 calls in GenericBuffer.cpp)
- `glGenTextures`, `glDeleteTextures`
- `glTexImage1D`, `glTexImage2D`, `glTexImage3D`, `glTexSubImage2D`
- `glTexParameteri` (filtering, wrapping, cube map params)
- Cube map handling (`GL_TEXTURE_CUBE_MAP_*`)

**Framebuffer Internals** (~15 calls)
- `glGenFramebuffers`, `glDeleteFramebuffers`
- `glFramebufferTexture2D`, `glFramebufferRenderbuffer`
- `glCheckFramebufferStatus`, `glBlitFramebuffer`

**Renderbuffer Management** (~6 calls)
- `glGenRenderbuffers`, `glDeleteRenderbuffers`
- `glBindRenderbuffer`, `glRenderbufferStorage`

**Advanced State** (Missing from Renderer)
- `glBlendFuncSeparate()` — needed for OIT (separate RGB/alpha)
- `glCullFace()`, `cullFace()` — face culling for cylinders
- `glDrawBuffers()` — MRT for OIT pipeline
- `glReadBuffer()`, `glDrawBuffer()` — FBO target selection
- `glActiveTexture()` — texture unit selection (has wrapper but needs review)

---

## 5. Framebuffer & Render Target Pipeline

### FBO Architecture

**Classes** (layer0/GenericBuffer.h):

```cpp
class FramebufferGL : public GPUBuffer {
  void attach_texture(TextureGL*, fbo::attachment loc)
  void attach_renderbuffer(RenderbufferGL*, fbo::attachment loc)
  void bind(), unbind()
  void blitTo(dest, srcExtent, dstOffset)
}

class RenderTargetGL : public GPUBuffer {
  void bind(bool clear)
  void layout(vector<rt_layout_t> desc, RenderbufferGL* with_rbo)
  void resize(shape_type size)
  FramebufferGL* fbo()
  RenderbufferGL* rbo()
  vector<TextureGL*> textures()
}
```

### Render Target Usage Patterns

| Use Case | File | Details |
|----------|------|---------|
| **Offscreen rendering** | ShaderMgr.cpp | Off-screen FBO for stereo, screenshots, output |
| **Orthographic rendering** | ShaderMgr.cpp | `bindOffscreenOrtho()` for 2D text/UI |
| **OIT (Transparency)** | PostProcess.cpp | Dual-target: color (UBYTE) + weight (FLOAT) |
| **Depth readback** | SceneRender.cpp | Read depth buffer for picking |
| **Blit operations** | GenericBuffer.cpp | MSAA resolve, copy between targets |

### Texture Formats
Supports:
- **UBYTE** (8-bit unsigned) — standard color
- **FLOAT** (32-bit) — OIT weight, depth, HDR output
- **1D, 2D, 3D, Cube** targets

---

## 6. Shader Compilation & Program Management

### Pipeline (layer0/ShaderMgr.cpp)

```
ShaderMgr::reload()
  ↓
glCreateProgram()
  ↓
For each stage (vertex, fragment, geometry, tess-control, tess-eval):
  glCreateShader(GL_*_SHADER)
  glShaderSource1String()
  glCompileShader()
  glGetShaderiv(GL_COMPILE_STATUS)
  glAttachShader()
  ↓
glBindAttribLocation() — bind vertex attributes
  ↓
For geometry/tessellation:
  glProgramParameteriEXT(GL_GEOMETRY_*) — config output
  ↓
glLinkProgram()
glGetProgramiv(GL_LINK_STATUS)
glGetProgramInfoLog() — error reporting
```

### Shader Text Storage
Shaders are compiled at build time by `create_shadertext.py` and embedded in:
- `build_appkit/generated/ShaderText.h` — C++ string arrays
- Each shader ID maps to pre-compiled source text

### Program Instance Management
Located in `layer0/ShaderPrg.cpp`:
- `CShaderPrg::Enable()` — glUseProgram
- `CShaderPrg::Set*()` — uniform setters (glUniform*)
- `CShaderPrg::Invalidate()` — cleanup on reload

---

## 7. State Management Summary

### Capabilities (Renderer::enable/disable)

| Capability | GL Equivalent | Used Where |
|------------|---------------|-----------|
| DepthTest | GL_DEPTH_TEST | Most geometry, OIT setup |
| Blend | GL_BLEND | Transparency, OIT |
| CullFace | GL_CULL_FACE | Cylinder rendering (backface) |
| ScissorTest | GL_SCISSOR_TEST | Viewport clipping |
| StencilTest | GL_STENCIL_TEST | Potentially (legacy) |
| LineSmooth | GL_LINE_SMOOTH | Anti-aliased lines |
| AlphaTest | GL_ALPHA_TEST | OIT, text cutoff |
| PolygonOffset | GL_POLYGON_OFFSET_FILL | Depth fighting mitigation |
| Texture2D | GL_TEXTURE_2D | Texture binding (legacy) |

### Blend Modes
**Currently used**:
- `GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA` — standard alpha blend
- `GL_BLEND_FUNC_SEPARATE` — OIT: separate RGB/alpha (1 use)
- `GL_SRC_COLOR, GL_ONE_MINUS_SRC_COLOR` — multiply blend (stereo)

### Depth Test & Write
- Depth test: `GL_LESS` (standard), `GL_LEQUAL`, `GL_ALWAYS` (UI)
- Depth write: enabled for geometry, disabled for transparent/UI pass

---

## 8. Remaining Direct GL Calls Summary

### High-Level Breakdown

| Category | Count | Priority | Action for Metal |
|----------|-------|----------|------------------|
| **Shader compilation** | ~50 | Deferred | Abstract shader creation/link API |
| **FBO/RBO internals** | ~35 | Deferred | Abstract framebuffer/renderbuffer API |
| **Texture internals** | ~20 | Deferred | Abstract texture creation/upload API |
| **Uniform/attribute setters** | ~15 | N/A | These ARE the shader API — keep |
| **State extensions needed** | ~10 | Next pass | blendFuncSeparate, cullFace, drawBuffers |
| **Queries (version, extensions)** | ~5 | Low | Could use Renderer or keep GL-specific |

### Top GL Call Count Files (by direct GL calls)

| File | GL Calls | Category |
|------|----------|----------|
| layer1/CGOGL.cpp | 174 | CGO replay (architectural) |
| layer1/SceneRender.cpp | 168 | Rendering orchestration |
| layer0/ShaderMgr.cpp | 110 | Shader management, FBO |
| layer1/Scene.cpp | 96 | State management, camera |
| layer5/main.cpp | 87 | Main loop, UI |

---

## 9. Immediate Mode Status

**PHASE 2 COMPLETE**: All `glBegin`/`glEnd` eliminated except 4 remaining:
- 2 in `CGOGL.cpp` — CGO GL replay (architectural necessity)
- 1 in `Character.cpp` — Textured quad (special case)
- 1 in `ObjectVolume.cpp` — Volume slice rendering

Replaced with:
- **ImmBatch** — VBO-backed vertex batching helper
- **Client-state arrays** — VBO submission

---

## 10. Platform-Specific Details (AppKit Integration)

### macOS OpenGL Initialization (main_appkit.mm)

**View Setup**:
```mm
NSOpenGLView with:
  - Double-buffered RGBA (32-bit color + 8-bit alpha)
  - 24-bit depth, 8-bit stencil
  - Legacy GL 2.1 compatible profile
  - VSync enabled
  - HiDPI/Retina support
```

**Context Lifecycle**:
1. `initWithFrame:` — Create pixel format & context
2. `prepareOpenGL` — Make context current, initialize PyMOL
3. Rendering loop — `setNeedsDisplay:` → `drawRect:`
4. Window close — cleanup

### Metal Equivalents
- `NSOpenGLView` → `MTKView` (Metal)
- `NSOpenGLContext` → `MTLCommandQueue` + `MTLDevice`
- `makeCurrentContext` → Set MTKView delegate
- Double-buffering → Managed by MTKView/Metal layer

---

## 11. OIT (Order-Independent Transparency) Pipeline

### Two-Pass OIT Algorithm

**Pass 1 — Accumulate**:
- FBO with MRT: color (RGBA8) + weight (FLOAT32)
- Vertex → Fragment shader
- Write to `gl_FragData[0]` (color) and `gl_FragData[1]` (weight)
- Blending: `glBlendFuncSeparate(GL_ONE, GL_ONE, GL_ZERO, GL_ONE_MINUS_SRC_ALPHA)`
- Accumulates weighted color

**Pass 2 — Composite**:
- Render screen quad with accumulated textures
- Fragment shader: `color / weight` (reveal equation)
- Blending: Standard alpha blend

### Metal Adaptation Needed
- **MRT support** — Metal render pass descriptors with multiple color attachments
- **Separate blend modes** — Metal has per-target blend state
- **Framebuffer readback** → Metal texture sampling of attachment

---

## 12. Recommendations for Metal Backend

### Phase 1: Essential Abstraction Layer
1. **Shader compilation API** in Renderer:
   ```cpp
   createShader(ShaderType, source)
   compileShader(id)
   attachShader(programId, shaderId)
   linkProgram(programId)
   deleteShader(id), deleteProgram(id)
   ```

2. **Texture creation/upload API**:
   ```cpp
   texImage1D/2D/3D(target, level, internalFormat, w, h, d, data)
   texSubImage2D(x, y, w, h, data)
   bindTextureToUnit(unit, texture)
   ```

3. **Framebuffer API**:
   ```cpp
   attachTexture(fbo, attachment, texture, level)
   attachRenderbuffer(fbo, attachment, rbo)
   checkFramebufferStatus(fbo)
   blitFramebuffer(src, dst, srcRect, dstRect, mask)
   ```

4. **Enhanced state API**:
   ```cpp
   blendFuncSeparate(srcRGB, dstRGB, srcA, dstA)
   cullFace(GL_FRONT/BACK/FRONT_AND_BACK)
   drawBuffers(count, buffers)  // for MRT
   readBuffer(buf), drawBuffer(buf)
   ```

### Phase 2: Backend Implementation
- Create `RendererMetal` class implementing Metal equivalents
- Map shader compilation → `MTLLibrary` creation from source
- Map FBO → `MTLRenderPassDescriptor`
- Map texture operations → `MTLTexture` creation/sampling

### Phase 3: Platform Selection
```cpp
std::unique_ptr<Renderer> renderer;
#ifdef __APPLE__
  // Try Metal first, fallback to GL
  renderer = std::make_unique<RendererMetal>();
  if (!renderer->isAvailable()) {
    renderer = std::make_unique<RendererGL>();
  }
#else
  renderer = std::make_unique<RendererGL>();
#endif
```

---

## Key Metrics for Planning

| Metric | Value | Notes |
|--------|-------|-------|
| Total shaders | 41 files | ~1,840 LOC, manageable |
| Shader stages | VS, FS, GS | No active tessellation |
| GL version | 2.1 → 3.2+ | Legacy + geometry support |
| FBO targets | 2–4 max | OIT uses dual-target (MRT) |
| Texture types | 1D, 2D, 3D, Cube | All need Metal mapping |
| Render passes | 2–3 per frame | Main + OIT + PostProcess |
| Critical features | OIT, ray-casting impostor, cube maps | Highest priority for Metal |
| Immediate mode | 4 remaining (acceptable) | CGO replay, volumes, text |

---

## Summary

**PyMOL's rendering pipeline is well-structured for Metal porting**:

✅ Renderer abstraction exists (covers basic state + program binding)
✅ Immediate mode nearly eliminated (4 remaining acceptable exceptions)
✅ Framebuffer usage is isolated (FBO + RenderTargetGL classes)
✅ Shaders are self-contained (1,840 LOC, pre-compiled at build time)
✅ Platform integration is clean (AppKit separate from core GL)

⚠️ **Work required**:
- Shader compilation → Metal library creation
- FBO management → MTLRenderPassDescriptor
- Texture operations → MTLTexture/MTLSamplerState
- OIT (MRT) → Metal per-target state

**Estimated Metal backend scope**: ~3,000–4,000 lines of C++ (RendererMetal + supporting classes)
