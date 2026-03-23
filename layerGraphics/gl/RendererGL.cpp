#include "RendererGL.h"
#include <GL/glew.h>

namespace pymol {

namespace {

GLenum toGL(PrimitiveType t)
{
  switch (t) {
  case PrimitiveType::Points: return GL_POINTS;
  case PrimitiveType::Lines: return GL_LINES;
  case PrimitiveType::LineStrip: return GL_LINE_STRIP;
  case PrimitiveType::Triangles: return GL_TRIANGLES;
  case PrimitiveType::TriangleStrip: return GL_TRIANGLE_STRIP;
  case PrimitiveType::TriangleFan: return GL_TRIANGLE_FAN;
  case PrimitiveType::Quads: return GL_QUADS;
  }
  return GL_TRIANGLES;
}

GLenum toGL(BlendFunc f)
{
  switch (f) {
  case BlendFunc::Zero: return GL_ZERO;
  case BlendFunc::One: return GL_ONE;
  case BlendFunc::SrcAlpha: return GL_SRC_ALPHA;
  case BlendFunc::OneMinusSrcAlpha: return GL_ONE_MINUS_SRC_ALPHA;
  case BlendFunc::DstAlpha: return GL_DST_ALPHA;
  case BlendFunc::OneMinusDstAlpha: return GL_ONE_MINUS_DST_ALPHA;
  case BlendFunc::SrcColor: return GL_SRC_COLOR;
  case BlendFunc::OneMinusSrcColor: return GL_ONE_MINUS_SRC_COLOR;
  }
  return GL_ONE;
}

GLenum toGL(DepthFunc f)
{
  switch (f) {
  case DepthFunc::Never: return GL_NEVER;
  case DepthFunc::Less: return GL_LESS;
  case DepthFunc::Equal: return GL_EQUAL;
  case DepthFunc::LessEqual: return GL_LEQUAL;
  case DepthFunc::Greater: return GL_GREATER;
  case DepthFunc::NotEqual: return GL_NOTEQUAL;
  case DepthFunc::GreaterEqual: return GL_GEQUAL;
  case DepthFunc::Always: return GL_ALWAYS;
  }
  return GL_LESS;
}

GLenum toGL(BufferTarget t)
{
  switch (t) {
  case BufferTarget::Array: return GL_ARRAY_BUFFER;
  case BufferTarget::ElementArray: return GL_ELEMENT_ARRAY_BUFFER;
  }
  return GL_ARRAY_BUFFER;
}

GLenum toGL(BufferUsage u)
{
  switch (u) {
  case BufferUsage::StaticDraw: return GL_STATIC_DRAW;
  case BufferUsage::DynamicDraw: return GL_DYNAMIC_DRAW;
  case BufferUsage::StreamDraw: return GL_STREAM_DRAW;
  }
  return GL_STATIC_DRAW;
}

GLenum toGL(TextureTarget t)
{
  switch (t) {
  case TextureTarget::Texture1D: return GL_TEXTURE_1D;
  case TextureTarget::Texture2D: return GL_TEXTURE_2D;
  case TextureTarget::Texture3D: return GL_TEXTURE_3D;
  }
  return GL_TEXTURE_2D;
}

GLenum toGL(Capability c)
{
  switch (c) {
  case Capability::DepthTest: return GL_DEPTH_TEST;
  case Capability::Blend: return GL_BLEND;
  case Capability::CullFace: return GL_CULL_FACE;
  case Capability::ScissorTest: return GL_SCISSOR_TEST;
  case Capability::StencilTest: return GL_STENCIL_TEST;
  case Capability::Lighting: return GL_LIGHTING;
  case Capability::Fog: return GL_FOG;
  case Capability::LineSmooth: return GL_LINE_SMOOTH;
  case Capability::Normalize: return GL_NORMALIZE;
  case Capability::ColorMaterial: return GL_COLOR_MATERIAL;
  case Capability::AlphaTest: return GL_ALPHA_TEST;
  case Capability::PolygonOffset: return GL_POLYGON_OFFSET_FILL;
  case Capability::Texture2D: return GL_TEXTURE_2D;
  }
  return GL_DEPTH_TEST;
}

} // anonymous namespace

RendererGL::RendererGL()
{
  glGenBuffers(1, &m_batchVBO);
}

RendererGL::~RendererGL()
{
  if (m_batchVBO) {
    glDeleteBuffers(1, &m_batchVBO);
  }
}

// Frame lifecycle
void RendererGL::beginFrame() {}
void RendererGL::endFrame() {}

// Viewport and clear
void RendererGL::viewport(int x, int y, int w, int h)
{
  glViewport(x, y, w, h);
}

void RendererGL::clear(bool color, bool depth, bool stencil)
{
  GLbitfield mask = 0;
  if (color) mask |= GL_COLOR_BUFFER_BIT;
  if (depth) mask |= GL_DEPTH_BUFFER_BIT;
  if (stencil) mask |= GL_STENCIL_BUFFER_BIT;
  glClear(mask);
}

void RendererGL::clearColor(float r, float g, float b, float a)
{
  glClearColor(r, g, b, a);
}

void RendererGL::scissor(int x, int y, int w, int h)
{
  glScissor(x, y, w, h);
}

// State management
void RendererGL::enable(Capability cap) { glEnable(toGL(cap)); }
void RendererGL::disable(Capability cap) { glDisable(toGL(cap)); }

void RendererGL::blendFunc(BlendFunc src, BlendFunc dst)
{
  glBlendFunc(toGL(src), toGL(dst));
}

void RendererGL::depthFunc(DepthFunc func) { glDepthFunc(toGL(func)); }
void RendererGL::depthMask(bool write) { glDepthMask(write ? GL_TRUE : GL_FALSE); }

void RendererGL::colorMask(bool r, bool g, bool b, bool a)
{
  glColorMask(r, g, b, a);
}

void RendererGL::lineWidth(float w) { glLineWidth(w); }
void RendererGL::pointSize(float s) { glPointSize(s); }

// Drawing
void RendererGL::drawArrays(PrimitiveType mode, int first, int count)
{
  glDrawArrays(toGL(mode), first, count);
}

void RendererGL::drawElements(PrimitiveType mode, int count, const void* indices)
{
  glDrawElements(toGL(mode), count, GL_UNSIGNED_INT, indices);
}

// Buffers
uint32_t RendererGL::createBuffer()
{
  GLuint id = 0;
  glGenBuffers(1, &id);
  return id;
}

void RendererGL::deleteBuffer(uint32_t id)
{
  GLuint glid = id;
  glDeleteBuffers(1, &glid);
}

void RendererGL::bindBuffer(BufferTarget target, uint32_t id)
{
  glBindBuffer(toGL(target), id);
}

void RendererGL::bufferData(
    BufferTarget target, size_t size, const void* data, BufferUsage usage)
{
  glBufferData(toGL(target), size, data, toGL(usage));
}

// Vertex attributes
void RendererGL::vertexAttribPointer(
    int index, int size, int type, bool normalized, int stride, const void* offset)
{
  glVertexAttribPointer(
      index, size, type, normalized ? GL_TRUE : GL_FALSE, stride, offset);
}

void RendererGL::enableVertexAttribArray(int index)
{
  glEnableVertexAttribArray(index);
}

void RendererGL::disableVertexAttribArray(int index)
{
  glDisableVertexAttribArray(index);
}

// Shaders
void RendererGL::useProgram(uint32_t programId) { glUseProgram(programId); }

void RendererGL::setUniform1i(int location, int v)
{
  glUniform1i(location, v);
}

void RendererGL::setUniform1f(int location, float v)
{
  glUniform1f(location, v);
}

void RendererGL::setUniform2f(int location, float v0, float v1)
{
  glUniform2f(location, v0, v1);
}

void RendererGL::setUniform3f(int location, float v0, float v1, float v2)
{
  glUniform3f(location, v0, v1, v2);
}

void RendererGL::setUniform4f(
    int location, float v0, float v1, float v2, float v3)
{
  glUniform4f(location, v0, v1, v2, v3);
}

void RendererGL::setUniformMatrix4fv(int location, const float* value)
{
  glUniformMatrix4fv(location, 1, GL_FALSE, value);
}

void RendererGL::setUniformMatrix3fv(int location, const float* value)
{
  glUniformMatrix3fv(location, 1, GL_FALSE, value);
}

// Textures
uint32_t RendererGL::createTexture()
{
  GLuint id = 0;
  glGenTextures(1, &id);
  return id;
}

void RendererGL::deleteTexture(uint32_t id)
{
  GLuint glid = id;
  glDeleteTextures(1, &glid);
}

void RendererGL::bindTexture(TextureTarget target, uint32_t id)
{
  glBindTexture(toGL(target), id);
}

void RendererGL::activeTexture(int unit)
{
  glActiveTexture(GL_TEXTURE0 + unit);
}

void RendererGL::texParameteri(TextureTarget target, int pname, int param)
{
  glTexParameteri(toGL(target), pname, param);
}

// Framebuffers
uint32_t RendererGL::createFramebuffer()
{
  GLuint id = 0;
  glGenFramebuffers(1, &id);
  return id;
}

void RendererGL::deleteFramebuffer(uint32_t id)
{
  GLuint glid = id;
  glDeleteFramebuffers(1, &glid);
}

void RendererGL::bindFramebuffer(uint32_t id)
{
  glBindFramebuffer(GL_FRAMEBUFFER, id);
}

// Matrix stack (legacy)
void RendererGL::matrixMode(int mode) { glMatrixMode(mode); }
void RendererGL::loadIdentity() { glLoadIdentity(); }
void RendererGL::loadMatrixf(const float* m) { glLoadMatrixf(m); }
void RendererGL::pushMatrix() { glPushMatrix(); }
void RendererGL::popMatrix() { glPopMatrix(); }

void RendererGL::translatef(float x, float y, float z)
{
  glTranslatef(x, y, z);
}

void RendererGL::scalef(float x, float y, float z)
{
  glScalef(x, y, z);
}

void RendererGL::multMatrixf(const float* m) { glMultMatrixf(m); }

// Immediate mode replacement — batch system
void RendererGL::beginBatch(PrimitiveType mode)
{
  m_batchMode = mode;
  m_batchVertices.clear();
}

void RendererGL::batchVertex3f(float x, float y, float z)
{
  m_batchVertices.push_back(
      {x, y, z, m_curR, m_curG, m_curB, m_curA, m_curNX, m_curNY, m_curNZ});
}

void RendererGL::batchVertex3fv(const float* v)
{
  batchVertex3f(v[0], v[1], v[2]);
}

void RendererGL::batchVertex2f(float x, float y)
{
  batchVertex3f(x, y, 0.0f);
}

void RendererGL::batchVertex2i(int x, int y)
{
  batchVertex3f(static_cast<float>(x), static_cast<float>(y), 0.0f);
}

void RendererGL::batchColor3f(float r, float g, float b)
{
  m_curR = r;
  m_curG = g;
  m_curB = b;
  m_curA = 1.0f;
}

void RendererGL::batchColor3fv(const float* c)
{
  batchColor3f(c[0], c[1], c[2]);
}

void RendererGL::batchColor4f(float r, float g, float b, float a)
{
  m_curR = r;
  m_curG = g;
  m_curB = b;
  m_curA = a;
}

void RendererGL::batchNormal3fv(const float* n)
{
  m_curNX = n[0];
  m_curNY = n[1];
  m_curNZ = n[2];
}

void RendererGL::endBatch()
{
  if (m_batchVertices.empty()) return;

  glBindBuffer(GL_ARRAY_BUFFER, m_batchVBO);
  glBufferData(GL_ARRAY_BUFFER,
      m_batchVertices.size() * sizeof(BatchVertex),
      m_batchVertices.data(), GL_STREAM_DRAW);

  // Position: offset 0
  glEnableClientState(GL_VERTEX_ARRAY);
  glVertexPointer(3, GL_FLOAT, sizeof(BatchVertex), nullptr);

  // Color: offset = 3 floats
  glEnableClientState(GL_COLOR_ARRAY);
  glColorPointer(4, GL_FLOAT, sizeof(BatchVertex),
      reinterpret_cast<const void*>(3 * sizeof(float)));

  // Normal: offset = 7 floats
  glEnableClientState(GL_NORMAL_ARRAY);
  glNormalPointer(GL_FLOAT, sizeof(BatchVertex),
      reinterpret_cast<const void*>(7 * sizeof(float)));

  glDrawArrays(toGL(m_batchMode),
      0, static_cast<GLsizei>(m_batchVertices.size()));

  glDisableClientState(GL_NORMAL_ARRAY);
  glDisableClientState(GL_COLOR_ARRAY);
  glDisableClientState(GL_VERTEX_ARRAY);
  glBindBuffer(GL_ARRAY_BUFFER, 0);

  m_batchVertices.clear();
}

// Queries
void RendererGL::getIntegerv(int pname, int* params)
{
  glGetIntegerv(pname, params);
}

const char* RendererGL::getString(int name)
{
  return reinterpret_cast<const char*>(glGetString(name));
}

int RendererGL::getError() { return static_cast<int>(glGetError()); }

// Misc
void RendererGL::flush() { glFlush(); }
void RendererGL::finish() { glFinish(); }

void RendererGL::readPixels(
    int x, int y, int w, int h, int format, int type, void* pixels)
{
  glReadPixels(x, y, w, h, format, type, pixels);
}

void RendererGL::pixelStorei(int pname, int param)
{
  glPixelStorei(pname, param);
}

} // namespace pymol
