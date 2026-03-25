#pragma once

#include "os_gl.h"

#include <string_view>

struct PyMOLGlobals;

#ifndef _PYMOL_NO_OPENGL
bool CheckGLErrorOK(PyMOLGlobals* G, std::string_view errString);

void GLAPIENTRY gl_debug_proc(GLenum, GLenum, GLuint, GLenum, GLsizei, const GLchar *, const void *);
// userParam is qualified as const in OpenGL 4.4 spec but non-const in OpenGL 4.3 spec
void GLAPIENTRY gl_debug_proc(GLenum, GLenum, GLuint, GLenum, GLsizei, const GLchar *, void *);
#else
static inline bool CheckGLErrorOK(PyMOLGlobals*, std::string_view) { return true; }
#endif

size_t gl_sizeof(GLenum type);
