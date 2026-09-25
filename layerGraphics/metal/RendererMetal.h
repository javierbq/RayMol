#pragma once
#include "Renderer.h"

#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#include <simd/simd.h>

#include <array>
#include <atomic>
#include <cstdint>
#include <cstring>
#include <memory>
#include <stack>
#include <string>
#include <map>
#include <unordered_map>
#include <utility>
#include <vector>

namespace pymol {

class RendererMetal : public Renderer {
public:
  RendererMetal(id<MTLDevice> device, id<MTLCommandQueue> queue);
  ~RendererMetal() override;

  // Live frame setup, deliberately split in two (#396). Only the FINAL post
  // pass writes to the drawable, so the drawable is acquired as late as
  // possible: everything that just needs the target SIZE (MSAA rebuild,
  // offscreen post targets) happens in beginLiveFrame from the drawable's
  // dimensions, and setPresentTarget hands over the actual CAMetalDrawable
  // right before endFrame. Waiting on `currentDrawable` before encoding the
  // scene blocked the main thread (and therefore input) for roughly half of
  // every GPU-bound frame.
  //
  // beginLiveFrame clears any previous drawable, so a frame whose drawable
  // never arrives presents nothing rather than re-presenting a stale one.
  void beginLiveFrame(int drawableW, int drawableH);
  void setPresentTarget(
      id<CAMetalDrawable> drawable, MTLRenderPassDescriptor* passDesc);

  // Live command buffers that have been committed but whose GPU work has not
  // completed yet. The render loop uses this to skip a tick instead of piling
  // frames onto the queue, which is what keeps the (now late) currentDrawable
  // wait short — see RenderGate in MetalViewport.swift. Offscreen/export
  // frames block until completion and are never counted.
  int framesInFlight() const { return _inFlight ? _inFlight->load() : 0; }

  // Frame lifecycle
  void beginFrame() override;
  void endFrame() override;

  // MSAA: stash the desired sample count (from metal_msaa). Applied at the top
  // of the next beginLiveFrame, before any encoder is open, so a toggle never
  // mismatches an in-flight encoder. n < 1 is clamped to 1.
  void setDesiredSampleCount(int n) override
  {
    _desiredSampleCount = (n < 1) ? 1 : (NSUInteger)n;
  }

  // Viewport and clear
  void viewport(int x, int y, int w, int h) override;
  bool getViewportRect(int& x, int& y, int& w, int& h) const override;
  void setGridSlot(int slot) override;
  void clear(bool color, bool depth, bool stencil) override;
  void clearColor(float r, float g, float b, float a) override;
  void scissor(int x, int y, int w, int h) override;

  // State management
  void enable(Capability cap) override;
  void disable(Capability cap) override;
  void blendFunc(BlendFunc src, BlendFunc dst) override;
  void depthFunc(DepthFunc func) override;
  void depthMask(bool write) override;
  void colorMask(bool r, bool g, bool b, bool a) override;
  void lineWidth(float w) override;
  void pointSize(float s) override;
  void setDepthClamp(bool enabled) override;

  // Drawing
  void drawArrays(PrimitiveType mode, int first, int count) override;
  void drawElements(
      PrimitiveType mode, int count, const void* indices) override;

  // Buffers
  uint32_t createBuffer() override;
  void deleteBuffer(uint32_t id) override;
  void bindBuffer(BufferTarget target, uint32_t id) override;
  void bufferData(BufferTarget target, size_t size, const void* data,
      BufferUsage usage) override;

  // Vertex attributes
  void vertexAttribPointer(int index, int size, int type, bool normalized,
      int stride, const void* offset) override;
  void enableVertexAttribArray(int index) override;
  void disableVertexAttribArray(int index) override;

  // Shaders
  void useProgram(uint32_t programId) override;
  void setUniform1i(int location, int v) override;
  void setUniform1f(int location, float v) override;
  void setUniform2f(int location, float v0, float v1) override;
  void setUniform3f(int location, float v0, float v1, float v2) override;
  void setUniform4f(
      int location, float v0, float v1, float v2, float v3) override;
  void setUniformMatrix4fv(int location, const float* value) override;
  void setUniformMatrix3fv(int location, const float* value) override;

  // Textures
  uint32_t createTexture() override;
  void deleteTexture(uint32_t id) override;
  void bindTexture(TextureTarget target, uint32_t id) override;
  void activeTexture(int unit) override;
  void texParameteri(TextureTarget target, int pname, int param) override;

  // Framebuffers
  uint32_t createFramebuffer() override;
  void deleteFramebuffer(uint32_t id) override;
  void bindFramebuffer(uint32_t id) override;

  // Matrix stack
  void matrixMode(int mode) override;
  void loadIdentity() override;
  void loadMatrixf(const float* m) override;
  void pushMatrix() override;
  void popMatrix() override;
  void translatef(float x, float y, float z) override;
  void scalef(float x, float y, float z) override;
  void multMatrixf(const float* m) override;

  // Immediate mode replacement
  void beginBatch(PrimitiveType mode) override;
  void batchVertex3f(float x, float y, float z) override;
  void batchVertex3fv(const float* v) override;
  void batchVertex2f(float x, float y) override;
  void batchVertex2i(int x, int y) override;
  void batchColor3f(float r, float g, float b) override;
  void batchColor3fv(const float* c) override;
  void batchColor4f(float r, float g, float b, float a) override;
  void batchColor4fv(const float* c) override;
  void batchColor4ub(unsigned char r, unsigned char g, unsigned char b,
      unsigned char a) override;
  void batchNormal3fv(const float* n) override;
  void endBatch() override;

  // Render readiness
  bool isRenderReady() const override;
  bool hasActiveEncoder() const override;

  // Queries
  void getIntegerv(int pname, int* params) override;
  const char* getString(int name) override;
  int getError() override;

  // Misc
  void flush() override;
  void finish() override;
  void readPixels(
      int x, int y, int w, int h, int format, int type, void* pixels) override;
  void pixelStorei(int pname, int param) override;

  // VBO rendering
  void drawVBO(PrimitiveType mode, int vertexCount,
      const void* data, size_t dataSize, size_t stride,
      int posOffset, int normalOffset, int colorOffset,
      int colorType, int interiorCap = 0) override;
  void drawVBOIndexed(PrimitiveType mode, int indexCount,
      const void* vertexData, size_t vertexDataSize, size_t stride,
      int posOffset, int normalOffset, int colorOffset, int colorType,
      const void* indexData, size_t indexDataSize, int interiorCap = 0) override;
  void setInteriorCapColor(float r, float g, float b, bool overrideColor) override;
  void setRepClip(float front, float back, float fracFront = 0.0f,
      float fracBack = 0.0f) override;
  void setBaseModelView(const float* m) override;
  void setRepContour(bool enabled, const float* rgba, float widthPx) override;
  void setRepMaterial(const MaterialParams& params) override;
  void setReflectionParams(int env, int samples) override;
  void setRepScreenAO(bool exempt) override;
  void invalidateVBOCache(uint64_t key) override;
  void invalidateVBOCacheEntry(const void* cpuData) override;
  void drawLabels(const LabelDrawCall& call) override;
  void drawConnectors(const ConnectorDrawCall& call) override;
  void drawSphereImpostors(const SphereImpostorDrawCall& call) override;
  void drawCylinderImpostors(const CylinderImpostorDrawCall& call) override;
  void setPostParams(int fogEnabled, float fogStart, float fogEnd, float bgR,
      float bgG, float bgB, int aoEnabled, int shadowEnabled, int aaEnabled,
      int outlineEnabled, float projA, float projB, float projX,
      float projY, int rtEnabled, int tonemapEnabled = 0,
      float exposure = 1.0f, int rtShadowEnabled = 0, float outlineR = 0.0f,
      float outlineG = 0.0f, float outlineB = 0.0f,
      float outlineWidth = 1.4f, int dofEnabled = 0, float dofFocus = 0.0f,
      float dofRange = 14.0f, int temporalAO = 0,
      int upscaleEnabled = 0, float dofAperture = 14.0f,
      int ortho = 0) override;
  void setLightingParams(float ambient, float direct, float reflect,
      float specular, float shininess, float sssWrap = 0.0f) override;
  void setKeyLightDir(const float* lightv) override;
  void setRayTraceParams(int samples, float aoRadius, float aoIntensity,
      float shadowIntensity, float scale = 1.0f) override;
  void setDofQuality(int level) override;

  // Letterbox: render the scene into a centered sub-rect of the given aspect
  // (W/H) so a loaded .pse reproduces its saved-viewport framing. 0 = fill.
  void setLetterboxAspect(float a) { _letterboxAspect = a; }
  float letterboxAspect() const { return _letterboxAspect; }
  // Letterbox origin in backing px (for mouse-coordinate offsetting).
  int letterboxOriginX() const { return _lbOriginX; }
  int letterboxOriginY() const { return _lbOriginY; }
  void setLetterboxOrigin(int x, int y) { _lbOriginX = x; _lbOriginY = y; }

  // Request a PNG capture of the next RENDERED frame (png ray=0). The Metal
  // app has no GL framebuffer for PyMOL's ScenePNG to read, so we grab the
  // renderer's final offscreen color and write it via MyPNGWrite.
  void requestPNGCapture(const std::string& path) { _capturePath = path; }

  // True iff this GPU supports hardware ray tracing (set in the ctor from
  // [_device supportsRaytracing]). Lets the UI gate the metal_raytrace toggle.
  bool rtSupported() const { return _rtSupported; }

  // Hi-res offscreen render → PNG. beginOffscreen sizes the post targets to
  // an arbitrary W×H, points the scene pass at them (no drawable), and arms
  // the PNG capture; the caller then runs the normal beginFrame / scene-draw /
  // endOffscreen sequence. endOffscreen runs the full post chain (skipping the
  // drawable blit), commits, and blocks until the GPU has written the PNG.
  // Targets self-heal to the window size on the next live beginLiveFrame.
  void beginOffscreen(int w, int h, const std::string& path);
  void endOffscreen();
  void beginTransparentOIT(bool peel = false) override;
  void beginPeelPrepass() override;
  void endPeelPrepass() override;
  bool peelSupported() const override;
  void resetTransparentOIT() override;
  void endTransparentOIT() override;
  void setEnvironment(int mode, float bgR, float bgG, float bgB) override;
  void drawBezierTubes(const void* controlPoints, size_t dataSize, float radius,
      float r, float g, float b) override;

  // Shadow map: SceneRenderMetal replays the opaque geometry a second time
  // between begin/endShadowPass with the LIGHT view-projection loaded via
  // matrixMode/loadMatrixf. Draws route to depth-only pipelines that write
  // into _shadowDepth (the light-POV depth map). setLightViewProjEye hands the
  // renderer the eye-space light VP so the post pass can sample the map.
  void beginShadowPass() override;
  void endShadowPass() override;
  void setLightViewProjEye(const float* m) override;
  void setShadowFrustum(float radius) override;
  void setShadowBias(float bias) override;

private:
  void buildImpostorPipelines();
  // The cylinder VBO layout (stride/offsets/formats) varies with the rep, so
  // the cylinder pipeline is built lazily from the first draw call's layout
  // and rebuilt only if a later call has a different stride.
  void releaseCylinderPipelines();
  void buildCylinderImpostorPipeline(const CylinderImpostorDrawCall& call);
  void buildLabelPipeline();
  // (Re)upload the glyph atlas to an MTLTexture if the generation changed.
  void ensureLabelAtlas(const unsigned char* pixels, int w, int h,
      uint64_t generation);
  // The connector VBO layout comes from CGOOptimizeConnectors, so the vertex
  // descriptor is built from the first draw call's offsets and rebuilt only if
  // a later call disagrees.
  void buildConnectorPipeline(const ConnectorDrawCall& call);

  // 4x4 matrix stored column-major
  using Mat4 = std::array<float, 16>;

  static Mat4 identityMatrix();
  static Mat4 multiplyMatrices(const Mat4& a, const Mat4& b);
  static Mat4 translationMatrix(float x, float y, float z);
  static Mat4 scaleMatrix(float x, float y, float z);

  void ensureEncoder();
  void applyDepthStencilState();
  // Cached depth-stencil states for the transparent (OIT) and opaque bezier-tube
  // draw paths. Built once on first use and reused across all draws — previously
  // a fresh state (+ descriptor) was created per draw call, leaking one of each
  // every transparent/tube draw under MRC. Released in the destructor.
  id<MTLDepthStencilState> oitDepthState();     // LessEqual, no depth write
  id<MTLDepthStencilState> bezierDepthState();  // LessEqual, depth write
  MTLPrimitiveType toMTL(PrimitiveType t);
  void buildVBOPipelines();

  // Anti-aliased line rendering: scene VBO line segments are expanded on the
  // CPU into feathered screen-space quads (PyMOL "trilines") instead of using
  // 1px MTLPrimitiveTypeLine, so lines/ribbon/mesh-wireframe/dashes are smooth.
  void drawLinesAA(PrimitiveType mode, int vertexCount, const void* data,
      size_t stride, int posOffset, int colorOffset, int colorType, bool flat);
  void buildLinePipeline();

  // Vertex attribute description
  struct VertexAttrib {
    int size = 0;        // component count (1-4)
    int type = 0;        // GL type constant (unused in Metal, always float)
    bool normalized = false;
    int stride = 0;
    uintptr_t offset = 0;
    bool enabled = false;
  };

  // Metal objects
  id<MTLDevice> _device;
  id<MTLCommandQueue> _queue;
  id<MTLCommandBuffer> _cmdBuffer;
  id<MTLRenderCommandEncoder> _encoder;
  MTLRenderPassDescriptor* _passDesc;
  id<CAMetalDrawable> _drawable;
  // In-flight live frame count. Held behind a shared_ptr because the command
  // buffer's completion handler (a background thread) decrements it and may
  // outlive this renderer.
  std::shared_ptr<std::atomic<int>> _inFlight;

  // Buffer pool
  uint32_t _nextBufferId = 1;
  std::unordered_map<uint32_t, id<MTLBuffer>> _buffers;
  uint32_t _boundArrayBuffer = 0;
  uint32_t _boundElementBuffer = 0;

  // Texture pool
  uint32_t _nextTextureId = 1;
  std::unordered_map<uint32_t, id<MTLTexture>> _textures;
  uint32_t _boundTexture = 0;
  int _activeTextureUnit = 0;

  // Framebuffer pool
  uint32_t _nextFBOId = 1;
  std::unordered_map<uint32_t, id<MTLTexture>> _fbColorAttachments;
  std::unordered_map<uint32_t, id<MTLTexture>> _fbDepthAttachments;
  uint32_t _boundFBO = 0;

  // Pipeline state cache
  id<MTLRenderPipelineState> _currentPipeline;
  id<MTLRenderPipelineState> _batchPipeline;  // built-in batch shader pipeline
  // Lit pipelines are specialised per MATERIAL FAMILY (#503): the fragment
  // function is compiled with kMatFamily fixed, so the `default` family carries
  // none of the material code at all and renders byte for byte as it did before
  // materials existed. Only families with an implemented material are built
  // (MaterialFamilyIsImplemented), so a family nothing can draw costs nothing.
  id<MTLRenderPipelineState> _vboPipelineUByte[cMaterialFamily_count] = {};
  id<MTLRenderPipelineState> _vboPipelineFloat[cMaterialFamily_count] = {};
  id<MTLFunction> _vboVertexFunc;
  id<MTLFunction> _vboFragmentFunc[cMaterialFamily_count] = {};
  // Fragment function specialised for one material family, or nil when the
  // family has no implemented material or specialisation failed.
  id<MTLFunction> materialFragmentFunction(
      id<MTLLibrary> lib, NSString* name, int family);
  id<MTLFunction> _vboVertexUnlitFunc;   // flat-color (no normal) for lines/dots
  id<MTLFunction> _vboFragmentUnlitFunc;
  // Unlit, position-ONLY (no per-vertex color attribute): used for uniform-
  // colored line geometry (alignment objects, distance/angle dashes) whose VBO
  // has no a_Color. Reads its color from a uniform (buffer 2) instead of an
  // attribute, so the pipeline can be created (the regular unlit shader requires
  // attribute 2 and would fail to compile a pipeline for such a layout).
  id<MTLFunction> _vboVertexUnlitFlatFunc;
  // Impostor ray-casting (analytic spheres/cylinders). nil-init (MRC).
  id<MTLRenderPipelineState> _sphereImpostorPipeline[cMaterialFamily_count] = {};
  // Cylinder impostor pipelines are cached PER VERTEX LAYOUT — (stride, a_cap
  // offset) — not in a single slot. a_cap's offset is part of the vertex
  // descriptor, so a stick VBO (per-vertex a_cap) and a CGO VBO (one constant
  // a_cap) need different pipelines even at the same stride; a single slot would
  // recompile the MSL library on every draw in a scene that has both, which is
  // exactly Move mode (issue #441). Values are +1-owned (MRC): release each
  // before erasing, like _vboCache. The three ivars below are NON-OWNING aliases
  // of the entry selected by the last buildCylinderImpostorPipeline().
  struct CylinderPipelines {
    id<MTLRenderPipelineState> opaque = nil;
    id<MTLRenderPipelineState> oit = nil;
    id<MTLRenderPipelineState> shadow = nil;
    id<MTLRenderPipelineState> peel = nil;   // depth-only, peel-depth format
  };
  // Keyed by (stride, a_cap offset, MATERIAL FAMILY): a marble stick and a
  // default stick at the same layout need different pipelines, and whichever
  // drew first would otherwise decide how both looked.
  std::map<std::tuple<NSUInteger, int, int>, CylinderPipelines> _cylinderPipelines;
  id<MTLRenderPipelineState> _cylinderImpostorPipeline = nil; // alias, not owned

  // Post-processing: the scene renders to offscreen color+depth, then
  // fullscreen passes (SSAO, fog/depth-cue, FXAA) composite to the drawable.
  // _passDesc is pointed at _scenePassDesc so existing scene-draw code is
  // unchanged; _screenPassDesc (from Swift) is used only by the final pass.
  id<MTLTexture> _sceneColor = nil;  // resolved (single-sample), post chain reads
  id<MTLTexture> _sceneDepth = nil;  // resolved (single-sample), post chain reads
  id<MTLTexture> _postColor = nil;   // ping-pong target for intermediate passes
  id<MTLTexture> _rtAO = nil;        // R16Float raw RT AO term (blurred in composite)
  // Temporal AO accumulation (cSetting_metal_temporal_ao): EMA the per-frame raw
  // RT-AO into _rtAOAccum (read by the composite), kept in _rtAOHistory for the
  // next frame. RG16Float to mirror _rtAO (.r AO, .g traced shadow).
  id<MTLTexture> _rtAOHistory = nil;
  id<MTLTexture> _rtAOAccum = nil;
  id<MTLRenderPipelineState> _rtAOAccumPipeline = nil;
  bool _rtAOHistoryValid = false;    // false => next accumulate hard-resets (alpha 1)
  uint64_t _rtAOHashPrev = 0;        // _rtSphereHash last accumulate (geometry reset)
  uint32_t _aoFrameCounter = 0;      // advances RTU.frame so each frame jitters AO
  // MSAA: when _sampleCount > 1 the scene renders to these multisampled targets
  // and resolves into _sceneColor/_sceneDepth. Opaque pipelines use
  // _sampleCount; OIT + post pipelines stay single-sample.
  id<MTLTexture> _sceneColorMS = nil;
  id<MTLTexture> _sceneDepthMS = nil;
  NSUInteger _sampleCount = 4;        // 4x MSAA by default (metal_msaa)
  NSUInteger _desiredSampleCount = 4; // applied at next beginLiveFrame (no encoder)
  void setSampleCount(NSUInteger n);  // rebuilds targets+pipelines on change
  void buildBatchPipeline();
  MTLRenderPassDescriptor* _scenePassDesc = nil;
  MTLRenderPassDescriptor* _screenPassDesc = nil;
  NSUInteger _rtW = 0, _rtH = 0;
  // Live render-target height, captured in beginLiveFrame. Pixel-radius post passes
  // (DoF aperture, outline thickness) are authored against the live resolution;
  // offscreen exports run at a higher _rtH, so scaling those radii by
  // _rtH/_liveRefH keeps the effect resolution-relative (WYSIWYG). 0 until the
  // first live frame, where the scale is 1 (live appearance unchanged).
  NSUInteger _liveRefH = 0;
  float pixelRadiusScale() const {
    return (_liveRefH > 0) ? (float)_rtH / (float)_liveRefH : 1.0f;
  }
  id<MTLRenderPipelineState> _blitPipeline = nil;
  id<MTLRenderPipelineState> _ssaoPipeline = nil;
  id<MTLRenderPipelineState> _fxaaPipeline = nil;
  id<MTLSamplerState> _postSampler = nil;
  void ensurePostTargets(NSUInteger w, NSUInteger h);
  void buildPostPipelines();
  // Create/resize the MetalFX spatial scaler for the given in/out sizes (no-op
  // if MetalFX is unsupported on this device; the caller then falls back to the
  // bilinear blit). Signature uses only NSUInteger so the header needn't import
  // MetalFX (the typed id<MTLFXSpatialScaler> lives in _upscaler / the .mm).
  void ensureUpscaler(NSUInteger inW, NSUInteger inH, NSUInteger outW, NSUInteger outH);
  void runPostChain();

  // Real-time ray tracing: build the shared unit-icosphere primitive
  // acceleration structure (once) + (re)build the per-atom instance
  // acceleration structure when the accumulated sphere set changes.
  void buildSphereProtoAS();
  void ensureRayTracingAS();
  void uploadRTMaterials();
  id<MTLAccelerationStructure> buildAccelStructure(MTLAccelerationStructureDescriptor* desc);

  // Order-independent transparency (weighted-blended). Transparent geometry
  // accumulates here (depth-tested vs opaque _sceneDepth, no write); a resolve
  // pass composites over the opaque color during runPostChain.
  id<MTLTexture> _oitAccum = nil;    // RGBA16Float, additive
  id<MTLTexture> _oitReveal = nil;   // R16Float, revealage (multiplicative)
  MTLRenderPassDescriptor* _oitPassDesc = nil;
  id<MTLRenderPipelineState> _vboOitPipelineUByte[cMaterialFamily_count] = {};
  id<MTLRenderPipelineState> _vboOitPipelineFloat[cMaterialFamily_count] = {};
  id<MTLFunction> _vboFragmentOitFunc[cMaterialFamily_count] = {};
  // Build a weighted-blended OIT MRT pipeline (vbo_vertex + vbo_fragment_oit)
  // for an arbitrary vertex layout (e.g. the surface's stride-44 layout).
  id<MTLRenderPipelineState> oitPipelineForVD(
      MTLVertexDescriptor* vd, int family);
  // Build-once cache for one-off VBO pipelines whose vertex layout does not match
  // a prebuilt stride (e.g. the molecular-surface stride-44 layout). Without it,
  // drawVBO/drawVBOIndexed rebuilt a pipeline on EVERY such draw — a per-frame
  // MRC leak plus the (significant) cost of pipeline-state compilation. The cache
  // OWNS each +1 pipeline; callers borrow. Released in setSampleCount + the dtor.
  enum class VBOPipelineVariant { Lit, Unlit, UnlitFlat, Oit, Shadow, Peel };
  id<MTLRenderPipelineState> cachedVBOPipeline(VBOPipelineVariant variant,
      size_t stride, int posOffset, int normalOffset, int colorOffset,
      int colorType, MTLVertexDescriptor* vd);
  id<MTLRenderPipelineState> _sphereOitPipeline[cMaterialFamily_count] = {};
  id<MTLRenderPipelineState> _cylinderOitPipeline = nil; // alias, not owned
  NSUInteger _cylinderOitStride = 0;
  id<MTLRenderPipelineState> _oitResolvePipeline = nil;
  // --- Environment cubemap for the reflective materials (#493) ---
  // Six 128px RGBA16F faces with mipmaps, rebuilt only when material_env or
  // the background colour changes. Mipmaps are the roughness axis: a rough
  // material samples a coarser level, which is what lets brushed metal read
  // differently from a mirror without a second texture.
  //
  // Bound on EVERY encoder that draws molecular geometry -- the scene pass, the
  // shadow pass and its resume, and the OIT pass -- so a reflective object
  // reflects the same room whichever one draws it. NOT the RT composite: that
  // is a post pass with its own fullscreen fragment and never samples this.
  // Frosted-glass environment taps: what an export can afford vs what an
  // interactive orbit can. Mirrored into MaterialParams.p[5] by setRepMaterial.
  static constexpr float kFrostTaps = 5.0f;
  // 3, not 2: the ring loop draws taps-1 offset samples, so 2 gave a single
  // one-sided tap instead of a blur. 3 is an opposed pair -- symmetric, and so
  // stable across the shader's basis flip.
  static constexpr float kFrostTapsLive = 3.0f;
  static constexpr NSUInteger kEnvFaceDim = 128;
  static constexpr NSUInteger kEnvTextureIndex = 6;   // fragment texture slot
  id<MTLTexture> _envCubemap = nil;
  id<MTLSamplerState> _envSampler = nil;
  int _envMode = -1;            // the material_env the cubemap was built for
  float _envBg[3] = {-1.0f, -1.0f, -1.0f};
  bool _envDirty = true;
  id<MTLTexture> _envFallbackCube = nil;   // 1x1 black; slot 6 is never empty
  bool ensureEnvironmentMap();
  bool ensureEnvironmentSampler();
  bool ensureEnvironmentFallback();
  void bindEnvironment(id<MTLRenderCommandEncoder> enc);

  bool _oitActive = false;      // true while the transparent pass is rendering
  bool _oitHasContent = false;  // true if any transparent fragments drew

  // --- Per-object transparent depth peel (#488) ---
  // _peelDepth is a single-sample copy of the opaque depth that ONE object's
  // depth-only pre-pass then writes its nearest surface into; that object's OIT
  // draw is then tested for EQUALITY against it, so only the front-most shell
  // of that object contributes. Blitting the opaque depth in first is what
  // makes a transparent fragment behind opaque geometry lose the pre-pass test
  // and therefore never match -- occlusion comes for free.
  //
  // The peel pipelines are the SHADOW vertex/fragment functions (depth only,
  // and the camera matrices are already loaded when the scene loop runs this)
  // built against Depth32Float_Stencil8 instead of the shadow map's plain
  // Depth32Float. Same shaders, different attachment formats -- so the depth a
  // fragment writes here is computed by the same code that computes the depth
  // the OIT pass compares, which is what makes the equality test exact.
  id<MTLTexture> _peelDepth = nil;
  MTLRenderPassDescriptor* _peelPassDesc = nil;   // zero colour attachments
  MTLRenderPassDescriptor* _oitPeelPassDesc = nil;  // OIT MRT + _peelDepth
  id<MTLDepthStencilState> _peelWriteState = nil;   // Less, write
  id<MTLDepthStencilState> _peelTestState = nil;    // Equal, no write
  id<MTLRenderPipelineState> _vboPeelPipelineUByte = nil;
  id<MTLRenderPipelineState> _vboPeelPipelineFloat = nil;
  id<MTLRenderPipelineState> _spherePeelPipeline = nil;
  id<MTLRenderPipelineState> _cylinderPeelPipeline = nil;  // alias, not owned
  id<MTLRenderPipelineState> peelPipelineForVD(MTLVertexDescriptor* vd);
  id<MTLDepthStencilState> oitDepthPeelAwareState();
  // Re-open the scene pass with LOAD semantics after an aborted peel pass.
  void resumeScenePass();
  // Create _peelDepth on first use and point the two peel descriptors at it.
  bool ensurePeelTargets();
  id<MTLDepthStencilState> peelWriteState();
  id<MTLDepthStencilState> peelTestState();
  bool _peelMode = false;       // true between begin/endPeelPrepass
  // Set when a draw could not run its peel pre-pass (no pipeline for that
  // layout). Its OIT draw must then use the ordinary LessEqual test: EQUAL
  // against a depth it never wrote rejects it at every pixel, i.e. the geometry
  // disappears.
  bool _peelUnseeded = false;
  bool _oitPeelTest = false;    // true while an OIT pass tests against the peel
  bool _oitCleared = false;     // the frame's first transparent encoder cleared

  // --- Real shadow map (light-POV depth pre-pass + PCF in the post pass) ---
  // _shadowDepth is a fixed-resolution single-sample Depth32Float map rendered
  // from the light's point of view; the post pass projects each fragment into
  // light space and PCF-compares against it. Depth-only pipelines mirror the
  // opaque ones but write no color and stay single-sample (the scene pass is
  // 4x MSAA; the shadow pass is not). _shadowMode is true during the replay.
  static constexpr NSUInteger kShadowDim = 4096;
  id<MTLTexture> _shadowDepth = nil;
  MTLRenderPassDescriptor* _shadowPassDesc = nil;
  id<MTLDepthStencilState> _shadowDepthState = nil;
  id<MTLSamplerState> _shadowSampler = nil;
  id<MTLFunction> _vboFragmentShadowFunc = nil;  // depth-only VBO fragment
  // Depth-only VBO fragment for the PEEL pre-pass: applies the per-rep clip so
  // the depth it records matches what vbo_fragment_oit writes (#488).
  id<MTLFunction> _vboFragmentPeelFunc = nil;
  // Surface interior-cap (stencil): mark = position-only/no-color/stencil-INVERT,
  // fill = full-screen quad gated on stencil. Built once; mark rebuilt per stride.
  id<MTLRenderPipelineState> _capMarkPipeline = nil;
  id<MTLRenderPipelineState> _capFillPipeline = nil;
  id<MTLDepthStencilState> _capMarkDSS = nil;
  id<MTLDepthStencilState> _capFillDSS = nil;
  size_t _capMarkStride = 0;
  // Interior-cap color (ray_interior_color). Override => use _capColor for caps;
  // else per-primitive default (atom color darkened / surface gray).
  float _capColor[3] = {0.32f, 0.32f, 0.36f};
  bool _capColorOverride = false;
  // Per-rep clip planes (eye-space distances) for the next lit-VBO draw.
  // _repClipFront < 0 => disabled (use the global slab). Set via setRepClip.
  float _repClipFront = -1.0f;
  float _repClipBack = 1e6f;
  // The clip's VIEW-INDEPENDENT fractions (surface_clip_front/back, 0..1,
  // referenced to the surface COM). Unlike the eye-space {front,back} depths
  // above (which drift with the camera), these change only when the user drags
  // the clip, so the RT rebuild signature folds THESE — a plain zoom/orbit then
  // triggers no acceleration-structure rebuild (no shadow/AO pop). Set via
  // setRepClip alongside the eye-space depths.
  float _repClipFracFront = 0.0f;
  float _repClipFracBack = 0.0f;
  // Traced-reflection material for the next draw (setRepMaterial): reflect (F0),
  // tint, roughness. Recorded per RT geometry occurrence in _rtFrameMat.
  float _repMat[3] = {0.0f, 0.0f, 0.0f};
  // Full material of the next draw (#503). Bound to the lit fragment shaders as
  // MaterialU; _repMat above is the ray tracer's view of the same three fields.
  MaterialParams _repMatParams;
  int _reflEnv = 1;        // metal_rt_reflect_env
  int _reflSamples = 8;    // metal_rt_reflect_samples (offscreen exports)
  // Surface outer-contour outline (per-surface, coverage-boundary). When armed
  // (setRepContour), the next surface draw is stashed; after the scene the
  // stashed geometry is rendered to a coverage mask and a post pass outlines the
  // mask boundary. Works on transparent/clipped surfaces. See drawVBO / runPostChain.
  bool _repContourEnabled = false;       // arm capture for the current draw
  float _contourColor[4] = {0, 0, 0, 1}; // line RGBA (frame param, last writer)
  float _contourWidth = 2.0f;            // px (constant on-screen)
  bool _contourActive = false;           // any contour draw stashed this frame
  id<MTLTexture> _surfaceCoverageTex = nil;
  id<MTLRenderPipelineState> _coveragePipeline = nil; // stride-keyed
  size_t _coverageStride = 0;
  id<MTLRenderPipelineState> _surfaceContourPipeline = nil;
  id<MTLFunction> _coverageVtxFunc = nil, _coverageFragFunc = nil;
  struct CoverageDraw {
    id<MTLBuffer> vbo;
    id<MTLBuffer> ibo; // nil => non-indexed
    int count;         // index count (indexed) or vertex count (non-indexed)
    size_t stride;
    int posOffset;
    float modelview[16];
    float projection[16];
    float clipFront;
    float clipBack;
  };
  std::vector<CoverageDraw> _coverageDraws;
  // Per-rep screen-space SSAO exemption (#79). Cartoon/ribbon lit-VBO draws are
  // stashed (when _repAOExempt is armed) and rasterized DEPTH-TESTED against
  // _sceneDepth into _aoExemptMaskTex (R8), so only the front-most cartoon pixels
  // are marked. post_ssao_fog reads that mask and skips the SSAO crease/contour
  // term there (cartoons still receive directional shadows), leaving surface
  // pockets untouched.
  bool _repAOExempt = false;                        // armed for the current draw
  std::vector<CoverageDraw> _aoExemptDraws;         // cartoon/ribbon draws this frame
  id<MTLTexture> _aoExemptMaskTex = nil;            // R8 front-most cartoon mask
  id<MTLRenderPipelineState> _aoMaskPipeline = nil; // stride-keyed (coverage fns)
  size_t _aoMaskStride = 0;
  id<MTLDepthStencilState> _aoMaskDepthState = nil; // LessEqual, no depth write
  bool renderAOExemptMask();                        // fills _aoExemptMaskTex; see .mm
  id<MTLFunction> _capMarkVtxFunc = nil, _capMarkFragFunc = nil;
  id<MTLFunction> _capFillVtxFunc = nil, _capFillFragFunc = nil;
  id<MTLRenderPipelineState> _vboShadowPipelineUByte = nil; // stride 28
  id<MTLRenderPipelineState> _vboShadowPipelineFloat = nil; // stride 40
  id<MTLRenderPipelineState> _sphereShadowPipeline = nil;   // Stage 3
  id<MTLRenderPipelineState> _cylinderShadowPipeline = nil; // Stage 3, alias
  bool _shadowMode = false;       // true between begin/endShadowPass
  // The shadow-map pre-pass ran THIS frame, so _shadowDepth / _lightViewProjEye
  // describe this frame's scene. SceneRenderMetal skips the pre-pass in
  // grid_mode (one global map cannot be per-cell), and without this gate the
  // post passes kept PCF-sampling whatever the map held from the last non-grid
  // frame — stale shadows, and from every cell's objects at once (#478).
  bool _shadowMapValid = false;
  float _lightViewProjEye[16];    // eye-space light VP, column-major (PostU)
  float _shadowRadius = 1.0f;     // world half-extent of the shadow ortho box
                                  // (from SceneBuildLightViewProjEye); lets the
                                  // receiver bias be expressed in Angstroms.
  float _shadowBias = 1.0f;       // metal_shadow_bias: user multiplier on the
                                  // self-shadow depth bias.
  void buildShadowPipelines();
  // Depth-only shadow pipeline for an arbitrary lit vertex layout (e.g. the
  // surface's stride-44), mirroring oitPipelineForVD.
  id<MTLRenderPipelineState> shadowPipelineForVD(MTLVertexDescriptor* vd);
  id<MTLRenderPipelineState> _shadowDebugPipeline = nil; // Stage-1 debug blit

  // Anti-aliased screen-space line quads. _vboLinePipeline (lazy, sample-count
  // aware) renders CPU-expanded feathered quads. _lineExpand is the per-frame
  // scratch where segments are expanded (9 floats/vert); each draw uploads it
  // into its OWN transient MTLBuffer (see drawVBOLines: a buffer shared across
  // draws is read by all of them at commit time, #462).
  id<MTLRenderPipelineState> _vboLinePipeline = nil;
  id<MTLFunction> _lineAAVtxFunc = nil;
  id<MTLFunction> _lineAAFragFunc = nil;
  std::vector<float> _lineExpand;

  // GPU-tessellated Bezier tube ("tube cartoon") pipeline.
  id<MTLRenderPipelineState> _bezierTubePipeline = nil;
  id<MTLBuffer> _bezierTessFactors = nil;  // MTLQuadTessellationFactorsHalf/patch
  NSUInteger _bezierTessPatchCap = 0;      // patches the factor buffer covers
  void buildBezierTubePipeline();
  // Per-frame post params (fog/depth-cue + SSAO), set by SceneRenderMetal.
  int _postFogEnabled = 0;
  float _fogStart = 0.f, _fogEnd = 1.f;
  float _bgR = 0.f, _bgG = 0.f, _bgB = 0.f;
  int _aoEnabled = 1;          // SSAO (cSetting_metal_ssao)
  int _shadowEnabled = 1;      // screen-space shadows (cSetting_metal_shadows)
  int _aaEnabled = 1;          // FXAA (cSetting_antialias_shader != 0)
  int _outlineEnabled = 0;     // silhouette outline (cSetting_metal_outline)
  // Outline contour color + thickness in px (cSetting_metal_outline_color/_width).
  float _outlineR = 0.f, _outlineG = 0.f, _outlineB = 0.f;
  float _outlineWidth = 1.4f;
  id<MTLRenderPipelineState> _outlinePipeline = nil;
  // Filmic tone-map + exposure post pass (cSetting_metal_tonemap/_exposure).
  // Milestone 1: operates on the existing LDR scene color (no float promotion).
  int _tonemapEnabled = 0;
  float _exposure = 1.0f;
  id<MTLRenderPipelineState> _tonemapPipeline = nil;
  // Depth-of-field post pass (cSetting_metal_dof/_dof_focus/_dof_range). Default
  // off => the DOF stage is skipped entirely (no regression).
  int _dofEnabled = 0;
  float _dofFocus = 0.0f;   // eye-space focus distance; <=0 => auto (screen center)
  // Range/aperture take 0 at face value (sharp falloff / closed aperture, i.e. no
  // blur); only a NEGATIVE value means "unset" and resolves to the 14.0 default.
  float _dofRange = 14.0f;  // eye-space distance over which CoC ramps to max blur
  float _dofAperture = 14.0f;  // cSetting_metal_dof_aperture: max blur radius (px)
  int _dofQuality = 4;         // cSetting_metal_dof_quality: 1..4 bokeh quality
  id<MTLRenderPipelineState> _dofPipeline = nil;
  id<MTLRenderPipelineState> _dofSmoothPipeline = nil;  // two-pass B: de-noise
  id<MTLTexture> _dofTex = nil;                         // two-pass A gather target
  // Temporal AO accumulation (cSetting_metal_temporal_ao): EMA the RT-AO buffer
  // across frames while the view is still. Default off; RT-path only.
  int _temporalAOEnabled = 0;
  // Reduced-resolution rendering + upscale (cSetting_metal_upscale). When on,
  // the scene + post chain render at _renderScale and the final blit upscales to
  // the native drawable (fragment-bound perf win). _renderScale==1 (default) is
  // byte-identical. Forced to 1 for offscreen export.
  int _upscaleEnabled = 0;
  float _renderScale = 1.0f;
  // MetalFX spatial scaler (typed id<MTLFXSpatialScaler>; untyped here to keep
  // MetalFX out of the header). Recreated when in/out sizes change. When nil/
  // unsupported the present path falls back to the bilinear blit.
  id _upscaler = nil;
  NSUInteger _upInW = 0, _upInH = 0, _upOutW = 0, _upOutH = 0;
  int _metalfxSupported = -1;  // -1 unknown, 0 no, 1 yes (cached per device)
  // Offscreen-export-only pass: rewrites the framebuffer alpha from scene depth
  // (background = far -> alpha 0) so a transparent-background PNG can be written
  // on the Metal fast path. Gated on _offscreen && transparent clear (_clearA<0.5).
  id<MTLRenderPipelineState> _exportAlphaPipeline = nil;
  // PyMOL lighting model (cSetting_ambient/direct/reflect/specular/shininess),
  // set per frame by SceneRenderMetal and uploaded into each lit shader's
  // uniform so the Scene-panel lighting sliders actually affect the render.
  // Defaults match the values the shaders previously hard-coded.
  float _lightAmbient = 0.14f, _lightDirect = 0.45f, _lightReflect = 0.481f;
  float _lightSpecular = 0.5f, _lightShininess = 55.0f;
  // Key-light direction TOWARD the light in eye space = -normalize(cSetting_light).
  // Default reproduces the previously hard-coded normalize(0.4,0.4,1.0), which is
  // exactly -normalize(PyMOL's default light). Fed into every lit/shadow/RT shader.
  float _keyLightEye[3] = {0.34815531f, 0.34815531f, 0.87038828f};
  float _sssWrap = 0.0f;  // cSetting_metal_sss_wrap: 0 = pure Lambert (identity)
  float _projA = -1.f, _projB = 0.f;  // projection[10], projection[14]
  float _projX = 1.f, _projY = 1.f;   // projection[0], projection[5]
  float _projOrtho = 0.f;             // 1 = orthographic (linear eye-z recon; #139)
  float _letterboxAspect = 0.f;       // saved-viewport W/H; 0 = fill window
  int _lbOriginX = 0, _lbOriginY = 0; // letterbox sub-rect origin (backing px)
  std::string _capturePath;           // pending png ray=0 capture (empty = none)
  bool _offscreen = false;            // hi-res offscreen render (no drawable)

  // --- Real-time ray tracing (cSetting_metal_raytrace) ---
  bool _rtSupported = false;      // [_device supportsRaytracing], set in ctor
  int  _rtEnabled = 0;            // requested (gated by _rtSupported)
  int  _rtShadowEnabled = 0;      // metal_rt_shadows: traced hard shadow ray
  bool _rtReady = false;          // instance acceleration structure is built
  // Model-space RT geometry, cached per CPU buffer. Spheres (center+radius) and
  // triangles (tessellated sticks + cartoon/surface meshes, 3 verts / 9 floats
  // per triangle, non-indexed) are derived from the SAME CPU buffers _vboCache
  // keys on, so they are extracted once on first sight and kept alive with the
  // cache entry. A frame then only records WHICH entries it used, which leaves
  // pure camera motion doing no gathering, no copying and no hashing at all.
  struct RTGeom {
    std::vector<float> spheres;  // x,y,z,r per sphere (size scale applied)
    std::vector<float> tris;     // 9 floats per triangle
    // Traced reflections: per-primitive colour + per-vertex normals so a
    // reflection ray can shade what it hits. 3 floats per triangle / per sphere.
    std::vector<float> triCols;
    std::vector<float> triNrms;  // 9 floats per triangle: per-vertex normals
    std::vector<float> sphereCols;
    uint64_t params = 0;         // draw-call scalars the extraction used
    uint64_t gen = 0;            // bumped on every (re)extraction; 0 = never
  };
  std::unordered_map<const void*, RTGeom> _rtGeomCache;
  // Secondary CPU buffer (index data) -> primary key, so invalidating an index
  // buffer also drops the entry keyed on its vertex buffer.
  std::unordered_map<const void*, const void*> _rtGeomAlias;
  // Keys contributing to the frame being accumulated, in draw order (a key may
  // repeat). Keys and not RTGeom* because invalidateVBOCacheEntry can erase an
  // entry mid-frame, and the concatenation runs one frame later.
  std::vector<const void*> _rtFrameKeys;
  uint64_t _rtFrameSig = 1469598103934665603ULL;  // running signature of
                                  // _rtFrameKeys (+ gens); FNV-1a offset basis
  uint64_t _rtGeomGen = 0;        // monotonic source of RTGeom::gen
  bool _rtGeomDirty = false;      // an entry was invalidated: force a rebuild
  size_t _rtTriCount = 0;         // triangles in the built _rtTriBuffer
  uint64_t _rtSphereHash = 0;     // signature of the built set (rebuild on change)
  size_t _rtBuiltCount = 0;

  // Per-occurrence pose + clip captured alongside every _rtFrameKeys entry so
  // the built AS reflects the CURRENTLY VISIBLE geometry, not the cached
  // model-space geometry alone:
  //  * _rtFrameXform: the object's Move-mode pose delta, base^-1 · M_obj. The
  //    shared camera is divided out, so it is identity for an unmoved object and
  //    equals its TTT for a moved one — a pure orbit leaves it unchanged (#427).
  //  * _rtFrameClip: the per-rep clip slab {front,back} in eye depth active for
  //    that draw (front<0 = none). Casters fully outside the slab are dropped so
  //    surface-clipped-open cavities stop occluding (#425).
  std::vector<Mat4> _rtFrameXform;
  std::vector<std::array<float, 2>> _rtFrameClip;
  // Per-occurrence traced-reflection material {reflect, tint, rough, 0}. NOT
  // folded into the rebuild signature: the built AS stores each primitive's
  // occurrence index, and the material table is refreshed from the current
  // frame's record every frame, so dragging a material slider never rebuilds.
  std::vector<std::array<float, 4>> _rtFrameMat;
  std::vector<std::array<float, 4>> _rtBuiltMat;   // table uploaded for the built AS
  Mat4 _rtBaseModelView{};      // camera-only modelview (world -> eye)
  Mat4 _rtBaseModelViewInv{};   // its inverse (eye -> world)

  // Record this frame's use of the RT geometry derived from the CPU buffer
  // `key`, calling `extract(RTGeom&)` only when it has not been extracted yet
  // or when `params` (the draw-call scalars it depends on) changed. `alias`, if
  // non-null, is a second CPU buffer the extraction read (the index buffer).
  template <class Extract>
  void rtNoteGeometry(const void* key, const void* alias, uint64_t params,
      Extract&& extract)
  {
    RTGeom& g = _rtGeomCache[key];
    if (g.gen == 0 || g.params != params) {
      g.spheres.clear();
      g.tris.clear();
      g.triCols.clear();
      g.triNrms.clear();
      g.sphereCols.clear();
      extract(g);
      g.params = params;
      g.gen = ++_rtGeomGen;
      if (alias)
        _rtGeomAlias[alias] = key;
    }
    // Buffers that yield no RT geometry (lines, points, degenerate meshes) are
    // cached as empty but left OUT of the frame record, so churn in e.g. the
    // selection-indicator CGO does not signal a geometry change and force an
    // acceleration-structure rebuild. rtDropGeometry keeps the same rule.
    if (g.spheres.empty() && g.tris.empty())
      return;
    _rtFrameKeys.push_back(key);

    // Pose delta = base^-1 · M_obj: divides the shared camera out of this draw's
    // modelview, leaving identity for an unmoved object and its Move-mode TTT for
    // a moved one. Baked into the caster geometry at build so shadows/AO follow
    // the object (#427); being camera-independent, an orbit does not perturb it.
    simd_float4x4 baseInv, mObj;
    std::memcpy(&baseInv, _rtBaseModelViewInv.data(), 64);
    std::memcpy(&mObj, _modelviewMatrix.data(), 64);
    simd_float4x4 d = simd_mul(baseInv, mObj);
    Mat4 delta;
    std::memcpy(delta.data(), &d, 64);
    _rtFrameXform.push_back(delta);
    _rtFrameClip.push_back({_repClipFront, _repClipBack});
    _rtFrameMat.push_back({_repMat[0], _repMat[1], _repMat[2], 0.0f});

    _rtFrameSig ^= (uint64_t)reinterpret_cast<uintptr_t>(key);
    _rtFrameSig *= 1099511628211ULL;
    _rtFrameSig ^= g.gen;
    _rtFrameSig *= 1099511628211ULL;
    // Fold the pose delta so a Move rebuilds the AS (camera-removed, so a pure
    // orbit does not) ...
    for (float f : delta) {
      uint32_t b;
      std::memcpy(&b, &f, 4);
      _rtFrameSig = (_rtFrameSig ^ b) * 1099511628211ULL;
    }
    // ... and the CLIP FRACTIONS so dragging the clip re-syncs the caster set.
    // surface_clip_front/back are referenced to the surface's center of mass — a
    // VIEW-INDEPENDENT 0..1 fraction of the molecule depth — so the set of
    // casters the clip drops depends only on the geometry, the pose delta (both
    // folded above) and these fractions, NOT on the camera. Folding the
    // fractions (rather than the camera-dependent eye-space slab / modelview)
    // rebuilds the AS when the user drags the clip, while a plain zoom/orbit
    // leaves the fractions unchanged and triggers NO rebuild — so RT shadows/AO
    // no longer pop/flicker during camera moves while a surface clip is active
    // (#425 stays fixed; regression from the earlier camera-folded signature).
    {
      uint32_t bf, bb;
      std::memcpy(&bf, &_repClipFracFront, 4);
      std::memcpy(&bb, &_repClipFracBack, 4);
      _rtFrameSig = (_rtFrameSig ^ bf) * 1099511628211ULL;
      _rtFrameSig = (_rtFrameSig ^ bb) * 1099511628211ULL;
    }
  }
  // Drop the cached RT geometry derived from a CPU buffer that is about to be
  // freed (or whose contents changed). Handles both primary and alias keys.
  void rtDropGeometry(const void* cpuData);
  id<MTLAccelerationStructure> _rtSphereProtoAS = nil;  // unit icosphere (shared)
  // World triangle meshes, one primitive AS per grid cell (a single one when
  // grid_mode is off), all pointing into _rtTriBuffer at that cell's range.
  std::vector<id<MTLAccelerationStructure>> _rtTriProtoASs;
  id<MTLAccelerationStructure> _rtInstanceAS = nil;     // top-level (atoms + tris)
  // Traced reflections: parallel per-triangle colour (3 floats/tri,
  // same global triangle index as _rtTriBuffer) and per-sphere-instance record
  // {cx,cy,cz,r, r,g,b,0} indexed by instance_id (sphere instances come first).
  id<MTLBuffer> _rtTriColBuffer = nil;
  id<MTLBuffer> _rtTriNrmBuffer = nil;   // 9 floats/tri: world-space vertex normals
  id<MTLBuffer> _rtTriMatBuffer = nil;   // uint32/tri: occurrence index into the material table
  id<MTLBuffer> _rtMatBuffer = nil;      // float4 per occurrence: {reflect, tint, rough, 0}
  id<MTLBuffer> _rtSphereBuffer = nil;
  size_t _rtSphereInstCount = 0;
  id<MTLBuffer> _rtTriBuffer = nil;   // world-tri vertices (9 floats/tri), bound to rt_ao so the
                                      // shadow ray can read the hit facet's plane (grazing-hit reject)

  // grid_mode cell attribution (#478). Every cell shares one world space, so
  // an acceleration structure built from all cells' geometry lets cell A's AO
  // and shadow rays hit cell B's objects. SceneRenderMetal calls setGridSlot
  // before each cell's draws; the frame record is split into cells at those
  // points, each cell's instances carry a distinct instance mask bit, and
  // rt_ao traces with the mask of the cell the pixel lies in. Cells past
  // kRTMaxGridCells (32 mask bits) are left out of the AS and render
  // unshadowed, like the raster shadow-map path does for every cell.
  static constexpr int kRTMaxGridCells = 32;
  struct RTFrameCell {
    int slot = 0;                       // grid slot (>= 1)
    float rect[4] = {0.f, 0.f, 1.f, 1.f}; // x0,y0,x1,y1 in scene-texture uv
    size_t firstKey = 0;                // index into _rtFrameKeys of its first draw
  };
  std::vector<RTFrameCell> _rtFrameCells;   // recorded this frame, draw order
  // Snapshot matching the built AS (same one-frame latency as the geometry).
  struct RTBuiltCell {
    float rect[4] = {0.f, 0.f, 1.f, 1.f};
    uint32_t triBase = 0, triCount = 0;   // this cell's range in _rtTriBuffer
    int triInstance = -1;                 // top-level instance id of its tri mesh
  };
  std::vector<RTBuiltCell> _rtBuiltCells;
  bool _rtBuiltGrid = false;              // built AS carries per-cell masks
  id<MTLBuffer> _rtProtoVerts = nil;
  id<MTLBuffer> _rtProtoIndices = nil;
  uint32_t _rtProtoIndexCount = 0;
  id<MTLRenderPipelineState> _rtAOPipeline = nil;       // pass A: raw AO -> R16Float
  id<MTLRenderPipelineState> _rtResolvePipeline = nil;  // pass B: blur AO + shadow/fog composite
  bool _rtCompileTried = false;   // latch: attempt the RT library compile at most once
  // Real-time RT quality knobs (metal_rt_* settings, set via setRayTraceParams).
  int   _rtSamples = 16;           // AO rays/pixel (live); offscreen uses max(48, this)
  float _rtScale = 0.5f;           // metal_rt_scale: RT AO/shadow pass resolution (live); offscreen = 1
  // (Re)allocate _rtAO / history / accum at the RT pass resolution for the
  // current scene size + scale; no-op when already right. Called from
  // ensurePostTargets and at the top of the RT pass (scale can change live).
  void ensureRTAOTargets(NSUInteger w, NSUInteger h);
  float _rtAORadius = 5.0f;        // AO hemisphere radius (Angstroms)
  float _rtAOIntensity = 0.72f;    // AO darkening strength (0..1)
  float _rtShadowIntensity = 0.45f;// cast-shadow darkening strength (0..1)
  // Label/text rendering (screen-aligned textured glyph quads). Initialized to
  // nil — this is a C++ class under MRC, so id ivars are not zero-initialized.
  id<MTLRenderPipelineState> _labelPipeline = nil;
  id<MTLSamplerState> _labelSampler = nil;
  id<MTLTexture> _labelAtlas = nil;  // glyph atlas, uploaded from CPU copy
  uint64_t _labelAtlasGen = 0;       // generation of the uploaded atlas
  // Label connectors (background box / outline / connector line). The vertex
  // shader amplifies one per-connector record into kConnectorVertsPerInstance
  // vertices, so there is no per-vertex buffer to cache beyond the CGO's own.
  id<MTLRenderPipelineState> _connectorPipeline = nil;
  size_t _connectorStride = 0;       // layout the pipeline was built for
  // The per-connector records are uploaded into a transient per-draw buffer
  // (see drawConnectors). Deliberately NOT the pointer-keyed _vboCache: the
  // connector CGO is rebuilt whenever a label setting changes, and a recycled
  // heap address would serve stale background/connector colors from the cache.
  uint32_t _currentProgram = 0;

  // Depth/stencil state
  id<MTLDepthStencilState> _depthStencilState;
  // Cached transparent/opaque-tube depth-stencil states (see oitDepthState/
  // bezierDepthState). nil-init (MRC: not zero-initialized otherwise).
  id<MTLDepthStencilState> _oitDepthState = nil;
  id<MTLDepthStencilState> _bezierDepthState = nil;
  bool _depthTestEnabled = false;
  bool _depthWriteEnabled = true;
  MTLCompareFunction _depthCompareFunc = MTLCompareFunctionLess;
  bool _depthStencilDirty = true;

  // Blend state (tracked, applied when pipeline is created)
  bool _blendEnabled = false;
  MTLBlendFactor _blendSrcFactor = MTLBlendFactorOne;
  MTLBlendFactor _blendDstFactor = MTLBlendFactorZero;

  // Color mask
  MTLColorWriteMask _colorWriteMask = MTLColorWriteMaskAll;

  // VBO buffer cache — reuse Metal buffers across frames
  std::unordered_map<const void*, id<MTLBuffer>> _vboCache;
  // One-off VBO pipeline cache (see cachedVBOPipeline). Owns each +1 pipeline.
  std::unordered_map<uint64_t, id<MTLRenderPipelineState>> _vboPipelineCache;
  id<MTLBuffer> _batchBuffer;  // reusable buffer for batch drawing

  // Clear values
  float _clearR = 0.0f, _clearG = 0.0f, _clearB = 0.0f, _clearA = 1.0f;

  // Viewport
  MTLViewport _viewport = {0, 0, 1, 1, 0.0, 1.0};
  MTLScissorRect _scissorRect = {0, 0, 1, 1};
  bool _scissorEnabled = false;

  // Capability flags
  bool _cullFaceEnabled = false;
  bool _stencilTestEnabled = false;
  bool _lightingEnabled = false;
  bool _fogEnabled = false;

  // Vertex attributes
  static constexpr int kMaxVertexAttribs = 8;
  VertexAttrib _vertexAttribs[kMaxVertexAttribs];

  // Uniform buffer (generic float storage)
  static constexpr int kMaxUniforms = 64;
  float _uniformData[kMaxUniforms * 4];  // up to 64 vec4s

  // Matrix stack — mode 0 = modelview, mode 1 = projection
  int _matrixMode = 0;  // 0x1700 = GL_MODELVIEW mapped to 0
  Mat4 _modelviewMatrix;
  Mat4 _modelviewInv;   // inverse(modelview): eye → model/world (for RT rays)
  Mat4 _modelviewInvPrev{};  // previous-frame _modelviewInv (temporal-AO reset)
  Mat4 _projectionMatrix;
  std::stack<Mat4> _modelviewStack;
  std::stack<Mat4> _projectionStack;

  // Batch system
  struct BatchVertex {
    float x, y, z;
    float r, g, b, a;
    float nx, ny, nz;
  };

  PrimitiveType _batchMode{};
  std::vector<BatchVertex> _batchVertices;
  float _curR = 1.0f, _curG = 1.0f, _curB = 1.0f, _curA = 1.0f;
  float _curNX = 0.0f, _curNY = 0.0f, _curNZ = 1.0f;

  // Line width / point size
  float _lineWidth = 1.0f;
  float _pointSize = 1.0f;

};

} // namespace pymol
