#pragma once
#include "Renderer.h"
#include <vector>

namespace pymol {

class RendererGL : public Renderer {
public:
  RendererGL();
  ~RendererGL() override;

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
  void batchNormal3fv(const float* n) override;
  void endBatch() override;

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

private:
  struct BatchVertex {
    float x, y, z;
    float r, g, b, a;
    float nx, ny, nz;
  };

  PrimitiveType m_batchMode{};
  std::vector<BatchVertex> m_batchVertices;
  float m_curR{1.0f}, m_curG{1.0f}, m_curB{1.0f}, m_curA{1.0f};
  float m_curNX{0.0f}, m_curNY{0.0f}, m_curNZ{1.0f};
  uint32_t m_batchVBO{0};
};

} // namespace pymol
