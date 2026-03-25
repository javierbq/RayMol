// Helper to initialize GLEW from contexts that can't include GLEW headers
#include "os_predef.h"

#ifndef _PYMOL_NO_OPENGL
#include <GL/glew.h>

extern "C" void initGLEWForDummyContext(void) {
    glewExperimental = GL_TRUE;
    glewInit();
    // Clear any error from glewInit (common on macOS)
    glGetError();
}
#else
extern "C" void initGLEWForDummyContext(void) {}
#endif
