#pragma once
#include "Renderer.h"

#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>

#include <array>
#include <cstring>
#include <stack>
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

  // Viewport and clear
  void viewport(int x, int y, int w, int h) override;
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
      int colorType) override;
  void drawVBOIndexed(PrimitiveType mode, int indexCount,
      const void* vertexData, size_t vertexDataSize, size_t stride,
      int posOffset, int normalOffset, int colorOffset, int colorType,
      const void* indexData, size_t indexDataSize) override;
  void invalidateVBOCache(uint64_t key) override;
  void drawLabels(const LabelDrawCall& call) override;
  void drawSphereImpostors(const SphereImpostorDrawCall& call) override;
  void drawCylinderImpostors(const CylinderImpostorDrawCall& call) override;

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
  // Impostor ray-casting (analytic spheres/cylinders). nil-init (MRC).
  id<MTLRenderPipelineState> _sphereImpostorPipeline = nil;
  id<MTLRenderPipelineState> _cylinderImpostorPipeline = nil;
  NSUInteger _cylinderPipelineStride = 0; // stride the cyl pipeline was built for

  // Post-processing: the scene renders to offscreen color+depth, then
  // fullscreen passes (SSAO, fog/depth-cue, FXAA) composite to the drawable.
  // _passDesc is pointed at _scenePassDesc so existing scene-draw code is
  // unchanged; _screenPassDesc (from Swift) is used only by the final pass.
  id<MTLTexture> _sceneColor = nil;
  id<MTLTexture> _sceneDepth = nil;
  id<MTLTexture> _postColor = nil;   // ping-pong target for intermediate passes
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
