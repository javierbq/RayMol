#pragma once

struct RenderInfo;
struct Rep;
struct PyMOLGlobals;
struct CSetting;

struct CCGORenderer {
  PyMOLGlobals* G = nullptr;
  RenderInfo* info = nullptr;
  Rep* rep = nullptr;
  const float* color = nullptr;
  float alpha{};
  short sphere_quality{};
  bool isPicking{};
  unsigned pick_pass() const noexcept;
  bool use_shader{}; // OpenGL 1.4+, e.g., glEnableVertexAttribArray() (on) vs.
                     // glEnableClientState() (off)
  bool debug{};
  CSetting* set1 = nullptr;
  CSetting* set2 = nullptr;
  // Metal impostor path: the cylinder `a_cap` flags are usually supplied as a
  // constant generic vertex attribute via a CGO_VERTEX_ATTRIBUTE_1F op (which
  // the GL path applies with glVertexAttrib1f). We capture that constant here
  // so the Metal cylinder draw can pass it as a uniform. Default =
  // cCylShaderBothCapsRound (0x0F).
  float metalCylCapConst = 15.0f;
};

bool CGORendererInit(PyMOLGlobals* G);
void CGORendererFree(PyMOLGlobals* G);
