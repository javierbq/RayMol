#ifndef _H_os_gl
#define _H_os_gl

#include"os_predef.h"
#include"os_proprietary.h"

// hardcode either true, or (x)
#define ALWAYS_IMMEDIATE_OR(x) true

#if 1
  #define _PYMOL_NO_AA_SHADERS
#endif

#ifdef _PYMOL_NO_OPENGL
/* -----------------------------------------------------------------------
 * Stub GL types and constants for non-GL builds (iOS / Metal-only).
 * Real GL headers are never included; only the type aliases and enum
 * values that leak into data-structures and CGO opcodes are provided.
 * ----------------------------------------------------------------------- */
#include <cstddef>   /* ptrdiff_t */
#include <cstdint>

typedef unsigned int  GLenum;
typedef unsigned int  GLuint;
typedef int           GLint;
typedef int           GLsizei;
typedef unsigned char GLubyte;
typedef unsigned char GLboolean;
typedef float         GLfloat;
typedef double        GLdouble;
typedef void          GLvoid;
typedef unsigned short GLushort;
typedef char          GLchar;
typedef ptrdiff_t     GLsizeiptr;
typedef ptrdiff_t     GLintptr;

/* Boolean */
#define GL_FALSE 0
#define GL_TRUE  1

/* Data types */
#define GL_BYTE           0x1400
#define GL_UNSIGNED_BYTE  0x1401
#define GL_SHORT          0x1402
#define GL_UNSIGNED_SHORT 0x1403
#define GL_INT            0x1404
#define GL_UNSIGNED_INT   0x1405
#define GL_FLOAT          0x1406

/* Primitives */
#define GL_POINTS         0x0000
#define GL_LINES          0x0001
#define GL_LINE_LOOP      0x0002
#define GL_LINE_STRIP     0x0003
#define GL_TRIANGLES      0x0004
#define GL_TRIANGLE_STRIP 0x0005
#define GL_TRIANGLE_FAN   0x0006

/* Blending */
#define GL_SRC_ALPHA           0x0302
#define GL_ONE_MINUS_SRC_ALPHA 0x0303

/* Matrix modes */
#define GL_MODELVIEW  0x1700
#define GL_PROJECTION 0x1701

/* Capabilities */
#define GL_DEPTH_TEST  0x0B71
#define GL_BLEND       0x0BE2
#define GL_LINE_SMOOTH 0x0B20
#define GL_SCISSOR_TEST 0x0C11

/* Buffers / draw */
#define GL_BACK       0x0405
#define GL_BACK_LEFT  0x0402
#define GL_BACK_RIGHT 0x0403

/* Texture */
#define GL_TEXTURE_2D 0x0DE1

/* Errors */
#define GL_NO_ERROR 0

/* Misc constants referenced in data structures */
#define GL_PACK_ALIGNMENT     0x0D05
#define GL_UNPACK_ALIGNMENT   0x0CF5

/* Texture parameters */
#define GL_TEXTURE_2D         0x0DE1
#define GL_TEXTURE_3D         0x806F
#define GL_TEXTURE0           0x84C0
#define GL_TEXTURE_MIN_FILTER 0x2801
#define GL_TEXTURE_MAG_FILTER 0x2800
#define GL_TEXTURE_WRAP_S     0x2802
#define GL_TEXTURE_WRAP_T     0x2803
#define GL_TEXTURE_WRAP_R     0x8072
#define GL_TEXTURE_ENV        0x2300
#define GL_TEXTURE_ENV_MODE   0x2200
#define GL_REPLACE            0x1E01
#define GL_NEAREST            0x2600
#define GL_LINEAR             0x2601
#define GL_LINEAR_MIPMAP_LINEAR   0x2703
#define GL_LINEAR_MIPMAP_NEAREST  0x2701
#define GL_NEAREST_MIPMAP_LINEAR  0x2702
#define GL_NEAREST_MIPMAP_NEAREST 0x2700
#define GL_REPEAT             0x2901
#define GL_CLAMP              0x2900
#define GL_CLAMP_TO_EDGE      0x812F
#define GL_CLAMP_TO_BORDER    0x812D
#define GL_MIRRORED_REPEAT    0x8370
#define GL_MIRROR_CLAMP_TO_EDGE 0x8743

/* Pixel formats */
#define GL_RED                0x1903
#define GL_RG                 0x8227
#define GL_RGB                0x1907
#define GL_RGBA               0x1908
#define GL_R8                 0x8229
#define GL_RG8                0x822B
#define GL_RGB8               0x8051
#define GL_RGBA8              0x8058
#define GL_R16F               0x822D
#define GL_RG16F              0x822F
#define GL_RGB16F             0x881B
#define GL_RGBA16F            0x881A
#define GL_HALF_FLOAT         0x140B
#define GL_LUMINANCE          0x1909

/* Framebuffer */
#define GL_FRAMEBUFFER        0x8D40
#define GL_RENDERBUFFER       0x8D41
#define GL_COLOR_ATTACHMENT0  0x8CE0
#define GL_COLOR_ATTACHMENT1  0x8CE1
#define GL_COLOR_ATTACHMENT2  0x8CE2
#define GL_COLOR_ATTACHMENT3  0x8CE3
#define GL_DEPTH_ATTACHMENT   0x8D00
#define GL_DEPTH_COMPONENT16  0x81A5
#define GL_DEPTH_COMPONENT24  0x81A6
#define GL_FRAMEBUFFER_COMPLETE 0x8CD5
#define GL_DRAW_FRAMEBUFFER   0x8CA9
#define GL_READ_FRAMEBUFFER   0x8CA8

/* Buffer objects */
#define GL_ARRAY_BUFFER       0x8892
#define GL_ELEMENT_ARRAY_BUFFER 0x8893
#define GL_STATIC_DRAW        0x88E4
#define GL_STREAM_DRAW        0x88E0
#define GL_DYNAMIC_DRAW       0x88E8

/* Clear bits */
#define GL_COLOR_BUFFER_BIT   0x4000
#define GL_DEPTH_BUFFER_BIT   0x0100
#define GL_STENCIL_BUFFER_BIT 0x0400

/* Shader */
#define GL_VERTEX_SHADER      0x8B31
#define GL_FRAGMENT_SHADER    0x8B30
#define GL_GEOMETRY_SHADER    0x8DD9
#define GL_TESS_CONTROL_SHADER 0x8E88
#define GL_TESS_EVALUATION_SHADER 0x8E87
#define GL_COMPILE_STATUS     0x8B81
#define GL_LINK_STATUS        0x8B82
#define GL_INFO_LOG_LENGTH    0x8B84

/* Enable caps */
#define GL_CULL_FACE          0x0B44
#define GL_STENCIL_TEST       0x0B90
#define GL_MULTISAMPLE        0x809D
#define GL_LINE_SMOOTH        0x0B20
#define GL_DEPTH_TEST         0x0B71
#define GL_BLEND              0x0BE2
#define GL_SCISSOR_TEST       0x0C11
#define GL_COLOR_LOGIC_OP     0x0BF2
#define GL_ALPHA_TEST         0x0BC0

/* Depth / Stencil */
#define GL_LEQUAL             0x0203
#define GL_LESS               0x0201
#define GL_ALWAYS             0x0207
#define GL_KEEP               0x1E00
#define GL_INCR               0x1E02
#define GL_EQUAL              0x0202
#define GL_REPLACE_GL         0x1E01

/* Draw modes */
#define GL_QUADS              0x0007
#define GL_POLYGON            0x0009

/* Misc */
#define GL_BACK               0x0405
#define GL_BACK_LEFT          0x0402
#define GL_BACK_RIGHT         0x0403
#define GL_FRONT              0x0404
#define GL_FRONT_AND_BACK     0x0408
#define GL_NONE_GL            0
#define GL_ONE                1
#define GL_ZERO               0
#define GL_MODELVIEW_MATRIX   0x0BA6
#define GL_PROJECTION_MATRIX  0x0BA7
#define GL_VIEWPORT           0x0BA2
#define GL_MAX_TEXTURE_SIZE   0x0D33
#define GL_CURRENT_COLOR      0x0B00
#define GL_LIGHT0             0x4000
#define GL_LIGHT1             0x4001
#define GL_AMBIENT            0x1200
#define GL_DIFFUSE            0x1201
#define GL_SPECULAR           0x1202
#define GL_POSITION           0x1203
#define GL_SHININESS          0x1601
#define GL_EMISSION           0x1600
#define GL_LIGHT_MODEL_AMBIENT 0x0B53
#define GL_LIGHT_MODEL_TWO_SIDE 0x0B52
#define GL_FLAT               0x1D00
#define GL_SMOOTH             0x1D01
#define GL_LIGHTING           0x0B50
#define GL_COLOR_MATERIAL     0x0B57
#define GL_NORMALIZE          0x0BA1
#define GL_FOG                0x0B60
#define GL_FOG_MODE           0x0B65
#define GL_FOG_COLOR          0x0B66
#define GL_FOG_DENSITY        0x0B62
#define GL_FOG_START          0x0B63
#define GL_FOG_END            0x0B64
#define GL_FOG_HINT           0x0C54
#define GL_DONT_CARE          0x1100
#define GL_VERTEX_ARRAY       0x8074
#define GL_NORMAL_ARRAY       0x8075
#define GL_COLOR_ARRAY        0x8076
#define GL_XOR                0x1506
#define GL_DITHER             0x0BD0
#define GL_ACCUM              0x0100
#define GL_LOAD               0x0101
#define GL_RETURN             0x0102
#define GL_RENDERER           0x1F01
#define GL_SHADING_LANGUAGE_VERSION 0x8B8C
#define GL_VERSION            0x1F02
#define GL_PATCHES            0x000E
#define GL_PATCH_VERTICES     0x8E72
#define GL_DEBUG_OUTPUT       0x92E2
#define GL_DEBUG_SOURCE_APPLICATION 0x824A
#define GL_DEBUG_TYPE_ERROR   0x824C

#define GLEW_KHR_debug        0
#define GLEW_VERSION_2_0      0
#define GLEW_VERSION_3_0      0
#define GLEW_VERSION_4_0      0
#define GLEW_ARB_gpu_shader5  0
#define GLEW_ARB_tessellation_shader 0
#define GLEW_EXT_draw_buffers2 0
#define GLEW_EXT_geometry_shader4 0
#define GLEW_EXT_gpu_shader4  0
#define GLEW_OK               0
#define GLEW_ERROR_NO_GLX_DISPLAY 4

#ifndef GLAPIENTRY
#define GLAPIENTRY
#endif

#define GL_DEBUG_FUN()

/* -----------------------------------------------------------------------
 * Stub GL functions — no-ops so that code which references GL calls in
 * non-Metal paths still compiles.  None of these are reached at runtime
 * when the Metal renderer is active.
 * ----------------------------------------------------------------------- */
static inline GLenum glGetError() { return GL_NO_ERROR; }
static inline void glEnable(GLenum) {}
static inline void glDisable(GLenum) {}
static inline void glClear(GLuint) {}
static inline void glClearColor(GLfloat, GLfloat, GLfloat, GLfloat) {}
static inline void glClearStencil(GLint) {}
static inline void glViewport(GLint, GLint, GLsizei, GLsizei) {}
static inline void glScissor(GLint, GLint, GLsizei, GLsizei) {}
static inline void glLineWidth(GLfloat) {}
static inline void glPointSize(GLfloat) {}
static inline void glDepthMask(GLboolean) {}
static inline void glDepthFunc(GLenum) {}
static inline void glColorMask(GLboolean, GLboolean, GLboolean, GLboolean) {}
static inline void glBlendFunc(GLenum, GLenum) {}
static inline void* glBlendFuncSeparate = nullptr;
static inline void glStencilFunc(GLenum, GLint, GLuint) {}
static inline void glStencilOp(GLenum, GLenum, GLenum) {}
static inline void glCullFace(GLenum) {}
static inline void glDrawBuffer(GLenum) {}
static inline void glReadBuffer(GLenum) {}
static inline void glFlush() {}
static inline void glFinish() {}
static inline void glHint(GLenum, GLenum) {}
static inline void glPixelStorei(GLenum, GLint) {}

/* Shader stubs */
static inline GLuint glCreateShader(GLenum) { return 0; }
static inline GLuint glCreateProgram() { return 0; }
static inline void glShaderSource(GLuint, GLsizei, const GLchar**, const GLint*) {}
static inline void glCompileShader(GLuint) {}
static inline void glAttachShader(GLuint, GLuint) {}
static inline void glDetachShader(GLuint, GLuint) {}
static inline void glLinkProgram(GLuint) {}
static inline void glUseProgram(GLuint) {}
static inline void glDeleteShader(GLuint) {}
static inline void glDeleteProgram(GLuint) {}
static inline GLint glGetUniformLocation(GLuint, const GLchar*) { return -1; }
static inline GLint glGetAttribLocation(GLuint, const GLchar*) { return -1; }
static inline void glGetShaderiv(GLuint, GLenum, GLint* p) { if(p) *p = 0; }
static inline void glGetProgramiv(GLuint, GLenum, GLint* p) { if(p) *p = 0; }
static inline void glGetShaderInfoLog(GLuint, GLsizei, GLsizei*, GLchar*) {}
static inline void glGetProgramInfoLog(GLuint, GLsizei, GLsizei*, GLchar*) {}
static inline void glBindAttribLocation(GLuint, GLuint, const GLchar*) {}
static inline void glUniform1i(GLint, GLint) {}
static inline void glUniform1f(GLint, GLfloat) {}
static inline void glUniform2f(GLint, GLfloat, GLfloat) {}
static inline void glUniform3f(GLint, GLfloat, GLfloat, GLfloat) {}
static inline void glUniform4f(GLint, GLfloat, GLfloat, GLfloat, GLfloat) {}
static inline void glUniformMatrix3fv(GLint, GLsizei, GLboolean, const GLfloat*) {}
static inline void glUniformMatrix4fv(GLint, GLsizei, GLboolean, const GLfloat*) {}
static inline void glProgramParameteriEXT(GLuint, GLenum, GLint) {}
static inline void glPatchParameteri(GLenum, GLint) {}

/* Vertex attribs */
static inline void glVertexAttrib1f(GLuint, GLfloat) {}
static inline void glVertexAttrib3f(GLuint, GLfloat, GLfloat, GLfloat) {}
static inline void glVertexAttrib3fv(GLuint, const GLfloat*) {}
static inline void glVertexAttrib4f(GLuint, GLfloat, GLfloat, GLfloat, GLfloat) {}
static inline void glVertexAttrib4ubv(GLuint, const GLubyte*) {}
static inline void glVertexAttribPointer(GLuint, GLint, GLenum, GLboolean, GLsizei, const void*) {}
static inline void glEnableVertexAttribArray(GLuint) {}
static inline void glDisableVertexAttribArray(GLuint) {}

/* Buffer objects */
static inline void glGenBuffers(GLsizei, GLuint*) {}
static inline void glDeleteBuffers(GLsizei, const GLuint*) {}
static inline void glBindBuffer(GLenum, GLuint) {}
static inline void glBufferData(GLenum, GLsizeiptr, const void*, GLenum) {}
static inline void glBufferSubData(GLenum, GLintptr, GLsizeiptr, const void*) {}
static inline GLboolean glIsBuffer(GLuint) { return GL_FALSE; }

/* Draw calls */
static inline void glDrawArrays(GLenum, GLint, GLsizei) {}
static inline void glDrawElements(GLenum, GLsizei, GLenum, const void*) {}
static inline void glDrawBuffers(GLsizei, const GLenum*) {}

/* Texture */
static inline void glGenTextures(GLsizei, GLuint*) {}
static inline void glDeleteTextures(GLsizei, const GLuint*) {}
static inline void glBindTexture(GLenum, GLuint) {}
static inline void glActiveTexture(GLenum) {}
static inline void glTexParameteri(GLenum, GLenum, GLint) {}
static inline void glTexEnvf(GLenum, GLenum, GLfloat) {}
static inline void glTexImage1D(GLenum, GLint, GLint, GLsizei, GLint, GLenum, GLenum, const void*) {}
static inline void glTexImage2D(GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, const void*) {}
static inline void glTexImage3D(GLenum, GLint, GLint, GLsizei, GLsizei, GLsizei, GLint, GLenum, GLenum, const void*) {}
static inline void glTexSubImage2D(GLenum, GLint, GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, const void*) {}
static inline GLboolean glIsTexture(GLuint) { return GL_FALSE; }

/* Framebuffer */
static inline void glGenFramebuffers(GLsizei, GLuint*) {}
static inline void glDeleteFramebuffers(GLsizei, const GLuint*) {}
static inline void glBindFramebuffer(GLenum, GLuint) {}
static inline void glFramebufferTexture2D(GLenum, GLenum, GLenum, GLuint, GLint) {}
static inline void glFramebufferRenderbuffer(GLenum, GLenum, GLenum, GLuint) {}
static inline GLenum glCheckFramebufferStatus(GLenum) { return GL_FRAMEBUFFER_COMPLETE; }
static inline void glBlitFramebuffer(GLint, GLint, GLint, GLint, GLint, GLint, GLint, GLint, GLuint, GLenum) {}

/* Renderbuffer */
static inline void glGenRenderbuffers(GLsizei, GLuint*) {}
static inline void glDeleteRenderbuffers(GLsizei, const GLuint*) {}
static inline void glBindRenderbuffer(GLenum, GLuint) {}
static inline void glRenderbufferStorage(GLenum, GLenum, GLsizei, GLsizei) {}

/* Legacy fixed-function (needed by code compiled under PURE_OPENGL_ES_2) */
static inline void glGetFloatv(GLenum, GLfloat*) {}
static inline void glGetIntegerv(GLenum, GLint*) {}
static inline void glGetBooleanv(GLenum, GLboolean*) {}
static inline const GLubyte* glGetString(GLenum) { return (const GLubyte*)""; }
static inline void glReadPixels(GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, void*) {}

/* Matrix stubs (used by some code paths even in shader mode) */
static inline void glMatrixMode(GLenum) {}
static inline void glLoadIdentity() {}
static inline void glLoadMatrixf(const GLfloat*) {}
static inline void glMultMatrixf(const GLfloat*) {}
static inline void glMultMatrixd(const GLdouble*) {}
static inline void glPushMatrix() {}
static inline void glPopMatrix() {}
static inline void glTranslatef(GLfloat, GLfloat, GLfloat) {}
static inline void glTranslated(GLdouble, GLdouble, GLdouble) {}
static inline void glScalef(GLfloat, GLfloat, GLfloat) {}
static inline void glOrtho(GLdouble, GLdouble, GLdouble, GLdouble, GLdouble, GLdouble) {}
static inline void glFrustum(GLdouble, GLdouble, GLdouble, GLdouble, GLdouble, GLdouble) {}

/* Immediate mode (shouldn't be reached but referenced in some code) */
static inline void glBegin(GLenum) {}
static inline void glEnd() {}
static inline void glVertex2i(GLint, GLint) {}
static inline void glVertex3f(GLfloat, GLfloat, GLfloat) {}
static inline void glVertex3fv(const GLfloat*) {}
static inline void glNormal3f(GLfloat, GLfloat, GLfloat) {}
static inline void glNormal3fv(const GLfloat*) {}
static inline void glColor3f(GLfloat, GLfloat, GLfloat) {}
static inline void glColor3fv(const GLfloat*) {}
static inline void glColor4f(GLfloat, GLfloat, GLfloat, GLfloat) {}
static inline void glColor4ub(GLubyte, GLubyte, GLubyte, GLubyte) {}
static inline void glColor4ubv(const GLubyte*) {}
static inline void glTexCoord2f(GLfloat, GLfloat) {}
static inline void glTexCoord3fv(const GLfloat*) {}
static inline void glRasterPos3f(GLfloat, GLfloat, GLfloat) {}
static inline void glRasterPos3i(GLint, GLint, GLint) {}
static inline void glRasterPos4f(GLfloat, GLfloat, GLfloat, GLfloat) {}
static inline void glRasterPos4fv(const GLfloat*) {}
static inline void glBitmap(GLsizei, GLsizei, GLfloat, GLfloat, GLfloat, GLfloat, const GLubyte*) {}
static inline void glDrawPixels(GLsizei, GLsizei, GLenum, GLenum, const void*) {}

/* Client state (legacy) */
static inline void glEnableClientState(GLenum) {}
static inline void glDisableClientState(GLenum) {}
static inline void glVertexPointer(GLint, GLenum, GLsizei, const void*) {}
static inline void glNormalPointer(GLenum, GLsizei, const void*) {}
static inline void glColorPointer(GLint, GLenum, GLsizei, const void*) {}

/* Lighting */
static inline void glLightfv(GLenum, GLenum, const GLfloat*) {}
static inline void glLightModelfv(GLenum, const GLfloat*) {}
static inline void glLightModeli(GLenum, GLint) {}
static inline void glMaterialf(GLenum, GLenum, GLfloat) {}
static inline void glMaterialfv(GLenum, GLenum, const GLfloat*) {}
static inline void glColorMaterial(GLenum, GLenum) {}
static inline void glShadeModel(GLenum) {}
static inline void glFogf(GLenum, GLfloat) {}
static inline void glFogfv(GLenum, const GLfloat*) {}
static inline void glAlphaFunc(GLenum, GLfloat) {}

/* Accumulation (legacy) */
static inline void glClearAccum(GLfloat, GLfloat, GLfloat, GLfloat) {}
static inline void glAccum(GLenum, GLfloat) {}

/* Push/Pop attribs */
static inline void glPushAttrib(GLuint) {}
static inline void glPopAttrib() {}

/* Color mask indexed */
static inline void glColorMaski(GLuint, GLboolean, GLboolean, GLboolean, GLboolean) {}

/* Debug */
static inline void glPushDebugGroup(GLenum, GLuint, GLsizei, const GLchar*) {}
static inline void glPopDebugGroup() {}
static inline void glDebugMessageCallback(void*, const void*) {}

#include "os_gl_glut.h"
#include "Spatial.h"

struct GLFramebufferConfig {
  std::uint32_t framebuffer{};
  GLenum drawBuffer{};
};

/* Stub function declarations — these are never called at runtime on iOS,
 * but some translation units reference them in code paths guarded by
 * runtime checks (e.g. if (!G->Renderer) { ... GL calls ... }).           */
static inline void PyMOLReadPixels(GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, GLvoid*) {}
static inline void PyMOLDrawPixels(GLsizei, GLsizei, GLenum, GLenum, const GLvoid*) {}
static inline int  PyMOLCheckOpenGLErr(const char*) { return 0; }

#define VertexIndex_t std::uint32_t
#define VertexIndex_GL_ENUM GL_UNSIGNED_INT
#define SceneGLClearColor(red,green,blue,alpha) ((void)0)

#define hasFrameBufferBinding() false

#else /* !_PYMOL_NO_OPENGL — real GL headers */

#if !defined(GL_GLEXT_PROTOTYPES) && !defined(_WIN32)
#define GL_GLEXT_PROTOTYPES
#endif

#ifndef GLEW_NO_GLU
#define GLEW_NO_GLU
#endif

#ifndef PURE_OPENGL_ES_2
#include <GL/glew.h>
#endif

#ifdef PURE_OPENGL_ES_2
#include "os_gl_es.h"
#elif defined(_PYMOL_OSX)
#import <OpenGL/gl.h>
#import <OpenGL/glext.h>
#else
#include <GL/gl.h>
#endif

#include "os_gl_glut.h"
#include "Spatial.h"

struct GLFramebufferConfig {
  std::uint32_t framebuffer{};
  GLenum drawBuffer{};
};

void PyMOLReadPixels(GLint x,
                     GLint y,
                     GLsizei width,
                     GLsizei height, GLenum format, GLenum type, GLvoid * pixels);

void PyMOLDrawPixels(GLsizei width,
                     GLsizei height, GLenum format, GLenum type, const GLvoid * pixels);

int PyMOLCheckOpenGLErr(const char *pos);

#define VertexIndex_t std::uint32_t
#define VertexIndex_GL_ENUM GL_UNSIGNED_INT
#define SceneGLClearColor(red,green,blue,alpha) glClearColor(red,green,blue,alpha);

#ifndef GLAPIENTRY
#define GLAPIENTRY
#endif

#define hasFrameBufferBinding() false

#ifndef PURE_OPENGL_ES_2
#define GL_DEBUG_PUSH(title) \
  GLEW_KHR_debug ? glPushDebugGroup(GL_DEBUG_SOURCE_APPLICATION, 0, -1, title) : (void)0

#define GL_DEBUG_POP() \
  GLEW_KHR_debug ? glPopDebugGroup() : (void)0

#ifdef __cplusplus

class glDebugBlock {
public:
  explicit glDebugBlock(char const* title) {
    GL_DEBUG_PUSH(title);
  }
  ~glDebugBlock() {
    GL_DEBUG_POP();
  }
};

#define GL_DEBUG_FUN() \
  glDebugBlock glDebugBlockVariable(__FUNCTION__)

#endif /* __cplusplus */
#else
#define GL_DEBUG_FUN()
#endif

#endif /* _PYMOL_NO_OPENGL */

#endif
