#pragma once

#include <vector>
#include <GL/glew.h>
#include "Renderer.h"

/**
 * ImmBatch — a drop-in replacement for glBegin/glEnd immediate mode.
 *
 * Collects vertices with per-vertex color/normal into a temporary buffer,
 * then flushes them through a VBO + client-state arrays on end().
 *
 * When a pymol::Renderer is active (Metal backend), the batch is flushed
 * through the Renderer's batch API instead of GL.
 *
 * Usage:
 *   ImmBatch batch;
 *   batch.begin(GL_TRIANGLE_STRIP);
 *   batch.color3f(1, 0, 0);
 *   batch.vertex2i(x1, y1);
 *   batch.vertex2i(x2, y2);
 *   batch.end();
 */
class ImmBatch {
public:
  // Set the active renderer for all ImmBatch instances.
  // When non-null, end() routes through the Renderer batch API.
  static void setActiveRenderer(pymol::Renderer* r) { s_renderer = r; }
  static pymol::Renderer* activeRenderer() { return s_renderer; }

  void begin(GLenum mode)
  {
    m_mode = mode;
    m_verts.clear();
    if (!s_renderer) {
      // Inherit the current GL color so that callers who set glColor
      // before a batch (e.g. glColor3fv(BackColor); fill()) get the
      // expected result.
      GLfloat c[4];
      glGetFloatv(GL_CURRENT_COLOR, c);
      m_r = c[0];
      m_g = c[1];
      m_b = c[2];
      m_a = c[3];
    }
  }

  void color3f(float r, float g, float b)
  {
    m_r = r;
    m_g = g;
    m_b = b;
    m_a = 1.0f;
  }

  void color3fv(const float* c) { color3f(c[0], c[1], c[2]); }

  void color4f(float r, float g, float b, float a)
  {
    m_r = r;
    m_g = g;
    m_b = b;
    m_a = a;
  }

  void normal3fv(const float* n)
  {
    m_nx = n[0];
    m_ny = n[1];
    m_nz = n[2];
  }

  void vertex3f(float x, float y, float z)
  {
    m_verts.push_back({x, y, z, m_r, m_g, m_b, m_a, m_nx, m_ny, m_nz});
  }

  void vertex3fv(const float* v) { vertex3f(v[0], v[1], v[2]); }

  void vertex2f(float x, float y) { vertex3f(x, y, 0.0f); }

  void vertex2i(int x, int y)
  {
    vertex3f(static_cast<float>(x), static_cast<float>(y), 0.0f);
  }

  void vertex3i(int x, int y, int z)
  {
    vertex3f(
        static_cast<float>(x), static_cast<float>(y), static_cast<float>(z));
  }

  void end()
  {
    if (m_verts.empty())
      return;

    if (s_renderer) {
      endRenderer();
      return;
    }

    GLuint vbo = 0;
    glGenBuffers(1, &vbo);
    glBindBuffer(GL_ARRAY_BUFFER, vbo);
    glBufferData(GL_ARRAY_BUFFER,
        m_verts.size() * sizeof(Vert), m_verts.data(), GL_STREAM_DRAW);

    glEnableClientState(GL_VERTEX_ARRAY);
    glVertexPointer(3, GL_FLOAT, sizeof(Vert), nullptr);

    glEnableClientState(GL_COLOR_ARRAY);
    glColorPointer(4, GL_FLOAT, sizeof(Vert),
        reinterpret_cast<const void*>(3 * sizeof(float)));

    glEnableClientState(GL_NORMAL_ARRAY);
    glNormalPointer(GL_FLOAT, sizeof(Vert),
        reinterpret_cast<const void*>(7 * sizeof(float)));

    glDrawArrays(m_mode, 0, static_cast<GLsizei>(m_verts.size()));

    glDisableClientState(GL_NORMAL_ARRAY);
    glDisableClientState(GL_COLOR_ARRAY);
    glDisableClientState(GL_VERTEX_ARRAY);
    glBindBuffer(GL_ARRAY_BUFFER, 0);
    glDeleteBuffers(1, &vbo);

    m_verts.clear();
  }

private:
  void endRenderer()
  {
    pymol::PrimitiveType pt;
    switch (m_mode) {
    case GL_POINTS: pt = pymol::PrimitiveType::Points; break;
    case GL_LINES: pt = pymol::PrimitiveType::Lines; break;
    case GL_LINE_STRIP: pt = pymol::PrimitiveType::LineStrip; break;
    case GL_TRIANGLES: pt = pymol::PrimitiveType::Triangles; break;
    case GL_TRIANGLE_STRIP: pt = pymol::PrimitiveType::TriangleStrip; break;
    case GL_TRIANGLE_FAN: pt = pymol::PrimitiveType::TriangleFan; break;
    default: pt = pymol::PrimitiveType::Triangles; break;
    }

    s_renderer->beginBatch(pt);
    for (auto& v : m_verts) {
      s_renderer->batchColor4f(v.r, v.g, v.b, v.a);
      s_renderer->batchNormal3fv(&v.nx);
      s_renderer->batchVertex3f(v.x, v.y, v.z);
    }
    s_renderer->endBatch();
    m_verts.clear();
  }

  struct Vert {
    float x, y, z;
    float r, g, b, a;
    float nx, ny, nz;
  };

  static inline pymol::Renderer* s_renderer = nullptr;

  GLenum m_mode{GL_TRIANGLES};
  std::vector<Vert> m_verts;
  float m_r{1.0f}, m_g{1.0f}, m_b{1.0f}, m_a{1.0f};
  float m_nx{0.0f}, m_ny{0.0f}, m_nz{1.0f};
};

// Free function bridge — can be forward-declared in files that cannot
// include GLEW (e.g. main_appkit.mm which uses framework GL headers).
void ImmBatch_SetActiveRenderer(pymol::Renderer* r);
