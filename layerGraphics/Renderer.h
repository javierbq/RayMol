#pragma once
#include <cstdint>

namespace pymol {

enum class PrimitiveType {
  Points,
  Lines,
  LineStrip,
  Triangles,
  TriangleStrip,
  TriangleFan,
  Quads
};

enum class BlendFunc {
  Zero,
  One,
  SrcAlpha,
  OneMinusSrcAlpha,
  DstAlpha,
  OneMinusDstAlpha,
  SrcColor,
  OneMinusSrcColor
};

enum class DepthFunc {
  Never,
  Less,
  Equal,
  LessEqual,
  Greater,
  NotEqual,
  GreaterEqual,
  Always
};

enum class BufferTarget { Array, ElementArray };

enum class BufferUsage { StaticDraw, DynamicDraw, StreamDraw };

enum class TextureTarget { Texture1D, Texture2D, Texture3D };

enum class Capability {
  DepthTest,
  Blend,
  CullFace,
  ScissorTest,
  StencilTest,
  Lighting,
  Fog,
  LineSmooth,
  Normalize,
  ColorMaterial,
  AlphaTest,
  PolygonOffset,
  Texture2D
};

class Renderer {
public:
  virtual ~Renderer() = default;

  // Frame lifecycle
  virtual void beginFrame() = 0;
  virtual void endFrame() = 0;

  // Viewport and clear
  virtual void viewport(int x, int y, int w, int h) = 0;
  virtual void clear(bool color, bool depth, bool stencil) = 0;
  virtual void clearColor(float r, float g, float b, float a) = 0;
  virtual void scissor(int x, int y, int w, int h) = 0;

  // State management
  virtual void enable(Capability cap) = 0;
  virtual void disable(Capability cap) = 0;
  virtual void blendFunc(BlendFunc src, BlendFunc dst) = 0;
  virtual void depthFunc(DepthFunc func) = 0;
  virtual void depthMask(bool write) = 0;
  virtual void colorMask(bool r, bool g, bool b, bool a) = 0;
  virtual void lineWidth(float w) = 0;
  virtual void pointSize(float s) = 0;

  // Drawing
  virtual void drawArrays(PrimitiveType mode, int first, int count) = 0;
  virtual void drawElements(
      PrimitiveType mode, int count, const void* indices) = 0;

  // Buffers
  virtual uint32_t createBuffer() = 0;
  virtual void deleteBuffer(uint32_t id) = 0;
  virtual void bindBuffer(BufferTarget target, uint32_t id) = 0;
  virtual void bufferData(BufferTarget target, size_t size, const void* data,
      BufferUsage usage) = 0;

  // Vertex attributes
  virtual void vertexAttribPointer(int index, int size, int type,
      bool normalized, int stride, const void* offset) = 0;
  virtual void enableVertexAttribArray(int index) = 0;
  virtual void disableVertexAttribArray(int index) = 0;

  // Shaders
  virtual void useProgram(uint32_t programId) = 0;
  virtual void setUniform1i(int location, int v) = 0;
  virtual void setUniform1f(int location, float v) = 0;
  virtual void setUniform2f(int location, float v0, float v1) = 0;
  virtual void setUniform3f(int location, float v0, float v1, float v2) = 0;
  virtual void setUniform4f(
      int location, float v0, float v1, float v2, float v3) = 0;
  virtual void setUniformMatrix4fv(int location, const float* value) = 0;
  virtual void setUniformMatrix3fv(int location, const float* value) = 0;

  // Textures
  virtual uint32_t createTexture() = 0;
  virtual void deleteTexture(uint32_t id) = 0;
  virtual void bindTexture(TextureTarget target, uint32_t id) = 0;
  virtual void activeTexture(int unit) = 0;
  virtual void texParameteri(TextureTarget target, int pname, int param) = 0;

  // Framebuffers
  virtual uint32_t createFramebuffer() = 0;
  virtual void deleteFramebuffer(uint32_t id) = 0;
  virtual void bindFramebuffer(uint32_t id) = 0;

  // Matrix stack (legacy compatibility)
  virtual void matrixMode(int mode) = 0;
  virtual void loadIdentity() = 0;
  virtual void loadMatrixf(const float* m) = 0;
  virtual void pushMatrix() = 0;
  virtual void popMatrix() = 0;
  virtual void translatef(float x, float y, float z) = 0;
  virtual void scalef(float x, float y, float z) = 0;
  virtual void multMatrixf(const float* m) = 0;

  // Immediate mode replacement
  virtual void beginBatch(PrimitiveType mode) = 0;
  virtual void batchVertex3f(float x, float y, float z) = 0;
  virtual void batchVertex3fv(const float* v) = 0;
  virtual void batchVertex2f(float x, float y) = 0;
  virtual void batchVertex2i(int x, int y) = 0;
  virtual void batchColor3f(float r, float g, float b) = 0;
  virtual void batchColor3fv(const float* c) = 0;
  virtual void batchColor4f(float r, float g, float b, float a) = 0;
  virtual void batchNormal3fv(const float* n) = 0;
  virtual void endBatch() = 0;

  // Queries
  virtual void getIntegerv(int pname, int* params) = 0;
  virtual const char* getString(int name) = 0;
  virtual int getError() = 0;

  // Misc
  virtual void flush() = 0;
  virtual void finish() = 0;
  virtual void readPixels(
      int x, int y, int w, int h, int format, int type, void* pixels) = 0;
  virtual void pixelStorei(int pname, int param) = 0;
};

} // namespace pymol
