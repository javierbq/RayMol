#pragma once
#include "Renderer.h"

#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>

#include <array>
#include <cstring>
#include <stack>
#include <string>
#include <unordered_map>
#include <vector>

namespace pymol {

class RendererMetal : public Renderer {
public:
  RendererMetal(id<MTLDevice> device, id<MTLCommandQueue> queue);
  ~RendererMetal() override;

  // Call before each frame to provide the view's drawable and pass descriptor
  void setDrawable(
      id<CAMetalDrawable> drawable, MTLRenderPassDescriptor* passDesc);

  // Frame lifecycle
  void beginFrame() override;
  void endFrame() override;

  // MSAA: stash the desired sample count (from metal_msaa). Applied at the top
  // of the next setDrawable, before any encoder is open, so a toggle never
  // mismatches an in-flight encoder. n < 1 is clamped to 1.
  void setDesiredSampleCount(int n) override
  {
    _desiredSampleCount = (n < 1) ? 1 : (NSUInteger)n;
  }

  // Viewport and clear
  void viewport(int x, int y, int w, int h) override;
  bool getViewportRect(int& x, int& y, int& w, int& h) const override;
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
  void invalidateVBOCache(uint64_t key) override;
  void drawLabels(const LabelDrawCall& call) override;
  void drawSphereImpostors(const SphereImpostorDrawCall& call) override;
  void drawCylinderImpostors(const CylinderImpostorDrawCall& call) override;
  void setPostParams(int fogEnabled, float fogStart, float fogEnd, float bgR,
      float bgG, float bgB, int aoEnabled, int shadowEnabled, int aaEnabled,
      int outlineEnabled, float projA, float projB, float projX,
      float projY, int rtEnabled, int tonemapEnabled = 0,
      float exposure = 1.0f, int rtShadowEnabled = 0) override;
  void setLightingParams(float ambient, float direct, float reflect,
      float specular, float shininess) override;

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
  // Targets self-heal to the window size on the next live setDrawable.
  void beginOffscreen(int w, int h, const std::string& path);
  void endOffscreen();
  void beginTransparentOIT() override;
  void endTransparentOIT() override;
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

private:
  void buildImpostorPipelines();
  // The cylinder VBO layout (stride/offsets/formats) varies with the rep, so
  // the cylinder pipeline is built lazily from the first draw call's layout
  // and rebuilt only if a later call has a different stride.
  void buildCylinderImpostorPipeline(const CylinderImpostorDrawCall& call);
  void buildLabelPipeline();
  // (Re)upload the glyph atlas to an MTLTexture if the generation changed.
  void ensureLabelAtlas(const unsigned char* pixels, int w, int h,
      uint64_t generation);

  // 4x4 matrix stored column-major
  using Mat4 = std::array<float, 16>;

  static Mat4 identityMatrix();
  static Mat4 multiplyMatrices(const Mat4& a, const Mat4& b);
  static Mat4 translationMatrix(float x, float y, float z);
  static Mat4 scaleMatrix(float x, float y, float z);

  void ensureEncoder();
  void applyDepthStencilState();
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
  id<MTLRenderPipelineState> _vboPipelineUByte; // VBO with UByte4Norm color
  id<MTLRenderPipelineState> _vboPipelineFloat; // VBO with Float4 color
  id<MTLFunction> _vboVertexFunc;
  id<MTLFunction> _vboFragmentFunc;
  id<MTLFunction> _vboVertexUnlitFunc;   // flat-color (no normal) for lines/dots
  id<MTLFunction> _vboFragmentUnlitFunc;
  // Unlit, position-ONLY (no per-vertex color attribute): used for uniform-
  // colored line geometry (alignment objects, distance/angle dashes) whose VBO
  // has no a_Color. Reads its color from a uniform (buffer 2) instead of an
  // attribute, so the pipeline can be created (the regular unlit shader requires
  // attribute 2 and would fail to compile a pipeline for such a layout).
  id<MTLFunction> _vboVertexUnlitFlatFunc;
  // Impostor ray-casting (analytic spheres/cylinders). nil-init (MRC).
  id<MTLRenderPipelineState> _sphereImpostorPipeline = nil;
  id<MTLRenderPipelineState> _cylinderImpostorPipeline = nil;
  NSUInteger _cylinderPipelineStride = 0; // stride the cyl pipeline was built for

  // Post-processing: the scene renders to offscreen color+depth, then
  // fullscreen passes (SSAO, fog/depth-cue, FXAA) composite to the drawable.
  // _passDesc is pointed at _scenePassDesc so existing scene-draw code is
  // unchanged; _screenPassDesc (from Swift) is used only by the final pass.
  id<MTLTexture> _sceneColor = nil;  // resolved (single-sample), post chain reads
  id<MTLTexture> _sceneDepth = nil;  // resolved (single-sample), post chain reads
  id<MTLTexture> _postColor = nil;   // ping-pong target for intermediate passes
  id<MTLTexture> _rtAO = nil;        // R16Float raw RT AO term (blurred in composite)
  // MSAA: when _sampleCount > 1 the scene renders to these multisampled targets
  // and resolves into _sceneColor/_sceneDepth. Opaque pipelines use
  // _sampleCount; OIT + post pipelines stay single-sample.
  id<MTLTexture> _sceneColorMS = nil;
  id<MTLTexture> _sceneDepthMS = nil;
  NSUInteger _sampleCount = 4;        // 4x MSAA by default (metal_msaa)
  NSUInteger _desiredSampleCount = 4; // applied at next setDrawable (no encoder)
  void setSampleCount(NSUInteger n);  // rebuilds targets+pipelines on change
  void buildBatchPipeline();
  MTLRenderPassDescriptor* _scenePassDesc = nil;
  MTLRenderPassDescriptor* _screenPassDesc = nil;
  NSUInteger _rtW = 0, _rtH = 0;
  id<MTLRenderPipelineState> _blitPipeline = nil;
  id<MTLRenderPipelineState> _ssaoPipeline = nil;
  id<MTLRenderPipelineState> _fxaaPipeline = nil;
  id<MTLSamplerState> _postSampler = nil;
  void ensurePostTargets(NSUInteger w, NSUInteger h);
  void buildPostPipelines();
  void runPostChain();

  // Real-time ray tracing: build the shared unit-icosphere primitive
  // acceleration structure (once) + (re)build the per-atom instance
  // acceleration structure when the accumulated sphere set changes.
  void buildSphereProtoAS();
  void ensureRayTracingAS();
  id<MTLAccelerationStructure> buildAccelStructure(MTLAccelerationStructureDescriptor* desc);

  // Order-independent transparency (weighted-blended). Transparent geometry
  // accumulates here (depth-tested vs opaque _sceneDepth, no write); a resolve
  // pass composites over the opaque color during runPostChain.
  id<MTLTexture> _oitAccum = nil;    // RGBA16Float, additive
  id<MTLTexture> _oitReveal = nil;   // R16Float, revealage (multiplicative)
  MTLRenderPassDescriptor* _oitPassDesc = nil;
  id<MTLRenderPipelineState> _vboOitPipelineUByte = nil;
  id<MTLRenderPipelineState> _vboOitPipelineFloat = nil;
  id<MTLFunction> _vboFragmentOitFunc = nil;  // for one-off OIT pipelines
  // Build a weighted-blended OIT MRT pipeline (vbo_vertex + vbo_fragment_oit)
  // for an arbitrary vertex layout (e.g. the surface's stride-44 layout).
  id<MTLRenderPipelineState> oitPipelineForVD(MTLVertexDescriptor* vd);
  id<MTLRenderPipelineState> _sphereOitPipeline = nil;
  id<MTLRenderPipelineState> _cylinderOitPipeline = nil;
  NSUInteger _cylinderOitStride = 0;
  id<MTLRenderPipelineState> _oitResolvePipeline = nil;
  bool _oitActive = false;      // true while the transparent pass is rendering
  bool _oitHasContent = false;  // true if any transparent fragments drew

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
  id<MTLFunction> _capMarkVtxFunc = nil, _capMarkFragFunc = nil;
  id<MTLFunction> _capFillVtxFunc = nil, _capFillFragFunc = nil;
  id<MTLRenderPipelineState> _vboShadowPipelineUByte = nil; // stride 28
  id<MTLRenderPipelineState> _vboShadowPipelineFloat = nil; // stride 40
  id<MTLRenderPipelineState> _sphereShadowPipeline = nil;   // Stage 3
  id<MTLRenderPipelineState> _cylinderShadowPipeline = nil; // Stage 3
  NSUInteger _cylinderShadowStride = 0;
  bool _shadowMode = false;       // true between begin/endShadowPass
  float _lightViewProjEye[16];    // eye-space light VP, column-major (PostU)
  void buildShadowPipelines();
  // Depth-only shadow pipeline for an arbitrary lit vertex layout (e.g. the
  // surface's stride-44), mirroring oitPipelineForVD.
  id<MTLRenderPipelineState> shadowPipelineForVD(MTLVertexDescriptor* vd);
  id<MTLRenderPipelineState> _shadowDebugPipeline = nil; // Stage-1 debug blit

  // Anti-aliased screen-space line quads. _vboLinePipeline (lazy, sample-count
  // aware) renders CPU-expanded feathered quads. _lineExpand is the per-frame
  // scratch where segments are expanded (9 floats/vert); it's uploaded into
  // _lineBuffer, grown on demand and tracked by _lineBufferSize.
  id<MTLRenderPipelineState> _vboLinePipeline = nil;
  id<MTLFunction> _lineAAVtxFunc = nil;
  id<MTLFunction> _lineAAFragFunc = nil;
  id<MTLBuffer> _lineBuffer = nil;
  size_t _lineBufferSize = 0;
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
  id<MTLRenderPipelineState> _outlinePipeline = nil;
  // Filmic tone-map + exposure post pass (cSetting_metal_tonemap/_exposure).
  // Milestone 1: operates on the existing LDR scene color (no float promotion).
  int _tonemapEnabled = 0;
  float _exposure = 1.0f;
  id<MTLRenderPipelineState> _tonemapPipeline = nil;
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
  float _projA = -1.f, _projB = 0.f;  // projection[10], projection[14]
  float _projX = 1.f, _projY = 1.f;   // projection[0], projection[5]
  float _letterboxAspect = 0.f;       // saved-viewport W/H; 0 = fill window
  int _lbOriginX = 0, _lbOriginY = 0; // letterbox sub-rect origin (backing px)
  std::string _capturePath;           // pending png ray=0 capture (empty = none)
  id<MTLTexture> _captureTex = nil;   // CPU-readable copy for readback
  bool _offscreen = false;            // hi-res offscreen render (no drawable)

  // --- Real-time ray tracing (cSetting_metal_raytrace) ---
  bool _rtSupported = false;      // [_device supportsRaytracing], set in ctor
  int  _rtEnabled = 0;            // requested (gated by _rtSupported)
  int  _rtShadowEnabled = 0;      // metal_rt_shadows: traced hard shadow ray
  bool _rtReady = false;          // instance acceleration structure is built
  // Atom-sphere geometry accumulated each frame (model space, center+radius).
  std::vector<float> _rtSpheres;  // x,y,z,r per sphere
  // Solid triangle geometry (model space): tessellated sticks + cartoon/surface
  // meshes. 3 verts (9 floats) per triangle, non-indexed.
  std::vector<float> _rtTris;
  uint64_t _rtSphereHash = 0;     // checksum of the built set (rebuild on change)
  size_t _rtBuiltCount = 0;
  id<MTLAccelerationStructure> _rtSphereProtoAS = nil;  // unit icosphere (shared)
  id<MTLAccelerationStructure> _rtTriProtoAS = nil;     // world triangle mesh
  id<MTLAccelerationStructure> _rtInstanceAS = nil;     // top-level (atoms + tris)
  id<MTLBuffer> _rtProtoVerts = nil;
  id<MTLBuffer> _rtProtoIndices = nil;
  uint32_t _rtProtoIndexCount = 0;
  id<MTLRenderPipelineState> _rtAOPipeline = nil;       // pass A: raw AO -> R16Float
  id<MTLRenderPipelineState> _rtResolvePipeline = nil;  // pass B: blur AO + shadow/fog composite
  // Label/text rendering (screen-aligned textured glyph quads). Initialized to
  // nil — this is a C++ class under MRC, so id ivars are not zero-initialized.
  id<MTLRenderPipelineState> _labelPipeline = nil;
  id<MTLSamplerState> _labelSampler = nil;
  id<MTLTexture> _labelAtlas = nil;  // glyph atlas, uploaded from CPU copy
  uint64_t _labelAtlasGen = 0;       // generation of the uploaded atlas
  uint32_t _currentProgram = 0;

  // Depth/stencil state
  id<MTLDepthStencilState> _depthStencilState;
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
