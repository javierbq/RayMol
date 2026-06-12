// PyMOLBridge.mm — C bridge implementation connecting Swift to PyMOL's embedding API
// Compiled as Objective-C++ to access both the C++ PyMOL internals and ObjC Metal APIs.
//
// NOTE: PyMOL include paths come from OTHER_CPLUSPLUSFLAGS in
// PyMOLBridge.xcconfig (not HEADER_SEARCH_PATHS, which would break
// Clang module builds due to layer0/Block.h shadowing system Block.h).

#include "PyMOL.h"
#include "PyMOLOptions.h"
#include "P.h"

#import <Foundation/Foundation.h>
#import <Python.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>

#include "RendererMetal.h"

// The bridging header uses PyMOLHandle (void*) to avoid CPyMOL typedef
// conflicts between the bridging header and PyMOL.h. We include PyMOL.h
// directly here (not the bridging header) and cast at function boundaries.
typedef void* PyMOLHandle;
#define INST(h) static_cast<CPyMOL*>(h)

// Forward declarations from PyMOL internals
extern "C" {
  PyObject *PyInit__cmd(void);
  void init_cmd(void);
}

// C++-linkage forward decl (defined in layer1/SceneRender.cpp). Declared
// OUTSIDE the extern "C" block below so the call resolves to the core's
// C++ (mangled) symbol, not a C one.
void SceneRenderMetal(PyMOLGlobals *G);
extern void ImmBatch_SetActiveRenderer(pymol::Renderer *r);

// All PyMOLBridge_* entry points MUST have C linkage to match the Swift
// bridging header (PyMOLBridge.h declares them inside extern "C"); otherwise
// the Swift side references _PyMOLBridge_* while the .mm emits mangled C++
// names and the link fails.
extern "C" {

// --- Lifecycle ---

PyMOLHandle PyMOLBridge_New(void)
{
    CPyMOLOptions *options = PyMOLOptions_New();
    if (!options) return nullptr;

    options->show_splash = 1;
    options->internal_gui = 0;
    options->internal_feedback = 1;
    options->external_gui = 0;

    CPyMOL *instance = PyMOL_NewWithOptions(options);
    PyMOLOptions_Free(options);
    return static_cast<PyMOLHandle>(instance);
}

void PyMOLBridge_Free(PyMOLHandle h)
{
    if (h) {
        PyMOL_Stop(INST(h));
        PyMOL_Free(INST(h));
    }
}

void PyMOLBridge_InitPython(PyMOLHandle h, const char *resourcePath)
{
    if (!h || !resourcePath) return;

    // Register the statically-linked _cmd builtin BEFORE init (top-level name only).
    PyImport_AppendInittab("_cmd", PyInit__cmd);

    NSString *resPath     = [NSString stringWithUTF8String:resourcePath];
    NSString *pythonHome  = [resPath stringByAppendingPathComponent:@"python"];   // contains lib/python3.13
    NSString *modulesPath = [resPath stringByAppendingPathComponent:@"modules"];
    NSString *dataPath    = [resPath stringByAppendingPathComponent:@"data"];

    // Modern PyConfig boot (mirrors layer5/main_appkit.mm). NOT isolated: PyMOL
    // relies on a normally-populated sys.path + site.py. config.home must be the
    // directory CONTAINING lib/python3.13 (BeeWare layout), i.e. <res>/python.
    PyConfig config;
    PyConfig_InitPythonConfig(&config);
    config.isolated = 0;
    config.site_import = 1;
    config.write_bytecode = 0;   // signed/read-only bundle: cannot write .pyc
    config.buffered_stdio = 0;
    PyConfig_SetBytesString(&config, &config.program_name, "PyMOL");
    PyConfig_SetBytesString(&config, &config.home, [pythonHome UTF8String]);

    PyStatus status = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status)) {
        NSLog(@"[PyMOL] Python init failed: %s", status.err_msg ? status.err_msg : "(unknown)");
        return;
    }

    init_cmd();   // register pymol._cmd in sys.modules

    PyObject *sysPath = PySys_GetObject("path");
    if (sysPath) {
        PyObject *p = PyUnicode_FromString([modulesPath UTF8String]);
        PyList_Insert(sysPath, 0, p);
        Py_DECREF(p);
    }

    setenv("PYMOL_PATH", [resPath UTF8String], 1);
    setenv("PYMOL_DATA", [dataPath UTF8String], 1);

    // NOTE: PInit / PyMOL_Start / stage-1 happen in PyMOLBridge_Start, AFTER the
    // C subsystems exist. Calling them here (before PyMOL_Start) dereferences
    // uninitialized button-mode/Setting state and crashes.
}

void PyMOLBridge_Start(PyMOLHandle h)
{
    if (!h) return;
    // Mirror the macOS embedding sequence (layer5/main_appkit.mm): PyMOL_Start
    // brings up all C subsystems (Setting/ButMode/Scene/...), THEN PInit wires
    // the Python layer as the global instance, THEN stage 1 enables deferred
    // command processing in PyMOL_Idle. (PyMOL_StartWithPython would PInit with
    // global_instance=false; macOS uses true, so we do the steps explicitly.)
    PyMOLGlobals *G = PyMOL_GetGlobals(INST(h));
    // Bind the high-level pymol.cmd singleton to THIS instance's globals BEFORE
    // PInit (mirrors main_appkit.mm:353). PInit wraps &SingletonPyMOLGlobals in a
    // capsule for the Python cmd singleton; without this it has no G and every
    // cmd.* call raises CmdException('G'). Also gates Python stdout->feedback.
    SingletonPyMOLGlobals = G;
    G->HaveGUI = true;
    PyMOL_Start(INST(h));
    PInit(G, true);
    PyMOL_SetPythonInitStage(INST(h), 1);
}

void PyMOLBridge_Stop(PyMOLHandle h)
{
    if (h) PyMOL_Stop(INST(h));
}

// --- Render loop ---

int PyMOLBridge_Idle(PyMOLHandle h)
{
    return h ? PyMOL_Idle(INST(h)) : 0;
}

void PyMOLBridge_Draw(PyMOLHandle h)
{
    if (h) PyMOL_Draw(INST(h));
}

void PyMOLBridge_Reshape(PyMOLHandle h, int width, int height)
{
    if (h) PyMOL_Reshape(INST(h), width, height, 0);
}

int PyMOLBridge_GetRedisplay(PyMOLHandle h, int reset)
{
    return h ? PyMOL_GetRedisplay(INST(h), reset) : 0;
}

// --- Input ---

// Shift incoming mouse coords (full-drawable backing px) into the letterboxed
// scene sub-rect's coordinate frame, so picking/drag line up with the render.
static void lbOffset(PyMOLHandle h, int& x, int& y)
{
    PyMOLGlobals* G = PyMOL_GetGlobals(INST(h));
    if (!G) return;
    auto* r = static_cast<pymol::RendererMetal*>(G->Renderer);
    if (!r) return;
    x -= r->letterboxOriginX();
    y -= r->letterboxOriginY();
}

void PyMOLBridge_Button(PyMOLHandle h, int button, int state,
                        int x, int y, int modifiers)
{
    if (!h) return;
    lbOffset(h, x, y);
    PyMOL_Button(INST(h), button, state, x, y, modifiers);
}

void PyMOLBridge_Drag(PyMOLHandle h, int x, int y, int modifiers)
{
    if (!h) return;
    lbOffset(h, x, y);
    PyMOL_Drag(INST(h), x, y, modifiers);
}

void PyMOLBridge_SetLetterboxAspect(PyMOLHandle h, float aspect)
{
    if (!h) return;
    PyMOLGlobals* G = PyMOL_GetGlobals(INST(h));
    if (!G) return;
    auto* r = static_cast<pymol::RendererMetal*>(G->Renderer);
    if (r) r->setLetterboxAspect(aspect);
}

void PyMOLBridge_CapturePNG(PyMOLHandle h, const char* path)
{
    if (!h || !path) return;
    PyMOLGlobals* G = PyMOL_GetGlobals(INST(h));
    if (!G) return;
    auto* r = static_cast<pymol::RendererMetal*>(G->Renderer);
    if (r) r->requestPNGCapture(std::string(path));
}

void PyMOLBridge_Key(PyMOLHandle h, unsigned char k, int x, int y, int modifiers)
{
    if (h) PyMOL_Key(INST(h), k, x, y, modifiers);
}

// --- Context management ---

void PyMOLBridge_PushValidContext(PyMOLHandle h)
{
    if (h) PyMOL_PushValidContext(INST(h));
}

void PyMOLBridge_PopValidContext(PyMOLHandle h)
{
    if (h) PyMOL_PopValidContext(INST(h));
}

// --- Python execution ---

void PyMOLBridge_RunCommand(const char *command)
{
    if (!command) return;
    // Route through PyMOL's command interpreter (cmd.do) so input is parsed as
    // PyMOL command language ("load ...", "show cartoon", "python ... python
    // end"), NOT raw Python. Use PyMOL's GIL model (PAutoBlock), NOT
    // PyGILState_Ensure — mixing the two with PyMOL_Idle's manual GIL corrupts
    // the interpreter thread state.
    PyMOLGlobals *G = SingletonPyMOLGlobals;
    if (!G) return;
    int blk = PAutoBlock(G);
    PyObject *pymol = PyImport_ImportModule("pymol");
    if (pymol) {
        PyObject *cmd = PyObject_GetAttrString(pymol, "cmd");
        if (cmd) {
            PyObject *res = PyObject_CallMethod(cmd, "do", "s", command);
            Py_XDECREF(res);
            Py_DECREF(cmd);
        }
        Py_DECREF(pymol);
    }
    if (PyErr_Occurred()) PyErr_Print();
    PAutoUnblock(G, blk);
}

void PyMOLBridge_RunPython(const char *code)
{
    if (!code) return;
    PyMOLGlobals *G = SingletonPyMOLGlobals;
    if (!G) return;
    int blk = PAutoBlock(G);
    PyRun_SimpleString(code);
    if (PyErr_Occurred()) PyErr_Print();
    PAutoUnblock(G, blk);
}

void PyMOLBridge_Pick(PyMOLHandle h, float ndcX, float ndcY, float aspect)
{
    if (!h) return;
    PyMOLGlobals *G = PyMOL_GetGlobals(INST(h));
    if (!G) return;
    char script[256];
    snprintf(script, sizeof(script),
             "from pymol.metal_pick import pick_at; pick_at(%f, %f, %f)",
             ndcX, ndcY, aspect);
    int blk = PAutoBlock(G);
    PyRun_SimpleString(script);
    if (PyErr_Occurred()) PyErr_Print();
    PAutoUnblock(G, blk);
}

char *PyMOLBridge_GetFeedback(PyMOLHandle h)
{
    if (!h) return nullptr;
    PyMOLGlobals *G = PyMOL_GetGlobals(INST(h));
    if (!G) return nullptr;

    // Use PAutoBlock + PyObject calls. The old PyRun_String(..., PyEval_GetGlobals(),
    // PyEval_GetLocals()) needed an active Python frame, which does not exist when
    // called from the C timer -> 'SystemError: frame does not exist' every tick.
    int blk = PAutoBlock(G);
    char *text = nullptr;
    PyObject *pymol = PyImport_ImportModule("pymol");
    if (pymol) {
        PyObject *cmd = PyObject_GetAttrString(pymol, "cmd");
        if (cmd) {
            PyObject *fb = PyObject_CallMethod(cmd, "_get_feedback", nullptr);
            if (fb) {
                if (PyList_Check(fb) && PyList_Size(fb) > 0) {
                    PyObject *sep = PyUnicode_FromString("\n");
                    PyObject *joined = PyUnicode_Join(sep, fb);
                    Py_XDECREF(sep);
                    if (joined) {
                        const char *str = PyUnicode_AsUTF8(joined);
                        if (str && str[0]) text = strdup(str);
                        Py_DECREF(joined);
                    }
                }
                Py_DECREF(fb);
            }
            Py_DECREF(cmd);
        }
        Py_DECREF(pymol);
    }
    if (PyErr_Occurred()) PyErr_Clear();
    PAutoUnblock(G, blk);
    return text;
}

void PyMOLBridge_FreeFeedback(char *str)
{
    free(str);
}

// --- Metal rendering ---

void PyMOLBridge_RenderMetal(PyMOLHandle h)
{
    if (!h) return;
    PyMOLGlobals *G = PyMOL_GetGlobals(INST(h));
    if (!G) return;

    SceneRenderMetal(G);
}

// Keep the Metal device + queue alive for the process lifetime: libpymol_core
// is built WITHOUT ARC, so RendererMetal::_device/_queue are non-retaining raw
// pointers (main_appkit holds them in long-lived view ivars; we hold them here).
// A locally-created queue would be released by ARC on return, leaving _queue
// dangling and crashing in beginFrame's [_queue commandBuffer].
static id<MTLDevice> g_metalDevice = nil;
static id<MTLCommandQueue> g_metalQueue = nil;

void PyMOLBridge_SetupMetalRenderer(PyMOLHandle h, void *mtkViewPtr)
{
    if (!h || !mtkViewPtr) return;
    PyMOLGlobals *G = PyMOL_GetGlobals(INST(h));
    if (!G || G->Renderer) return;   // idempotent: build the renderer once
    MTKView *v = (__bridge MTKView *)mtkViewPtr;
    g_metalDevice = v.device ?: MTLCreateSystemDefaultDevice();
    g_metalQueue = [g_metalDevice newCommandQueue];
    G->HaveGUI = true;               // mirror main_appkit.mm:688
    G->Renderer = new pymol::RendererMetal(g_metalDevice, g_metalQueue);
}

void PyMOLBridge_RenderMetalFrame(PyMOLHandle h, void *drawablePtr,
                                  void *passDescPtr, int width, int height)
{
    if (!h) return;
    PyMOLGlobals *G = PyMOL_GetGlobals(INST(h));
    if (!G) return;
    auto *renderer = static_cast<pymol::RendererMetal *>(G->Renderer);
    if (!renderer) return;
    id<CAMetalDrawable> drawable = (__bridge id<CAMetalDrawable>)drawablePtr;
    MTLRenderPassDescriptor *passDesc = (__bridge MTLRenderPassDescriptor *)passDescPtr;
    if (!drawable || !passDesc) return;

    // Keep PyMOL's window/scene-block size in sync with the actual drawable
    // (backing pixels). Without this the scene block stays at the default
    // 640x480, so mouse clicks/drags outside that region miss the Scene block
    // and never rotate/zoom — even though rendering fills the full viewport.
    // G->Option->winX/winY feed SceneRenderMetal's one-time OrthoReshape; set
    // them here (before SceneRenderMetal) so that reshape uses the real size.
    // Letterbox: when a loaded .pse asks for a specific viewport aspect, render
    // the scene into a centered sub-rect of that aspect (PyMOL reshaped to the
    // sub-rect so the projection matches), reproducing the session's saved
    // framing. The surrounding bars are the cleared background. 0 = fill.
    float lbAspect = renderer->letterboxAspect();
    int vpW = width, vpH = height, ox = 0, oy = 0;
    if (lbAspect > 0.0f && width > 0 && height > 0) {
        float winAspect = (float)width / (float)height;
        if (winAspect > lbAspect) { vpH = height; vpW = (int)(height * lbAspect + 0.5f); }
        else { vpW = width; vpH = (int)(width / lbAspect + 0.5f); }
        ox = (width - vpW) / 2;
        oy = (height - vpH) / 2;
    }

    static int s_lastVpW = 0, s_lastVpH = 0;
    if (vpW != s_lastVpW || vpH != s_lastVpH) {
        G->Option->winX = vpW;
        G->Option->winY = vpH;
        PyMOL_Reshape(INST(h), vpW, vpH, 0);
        s_lastVpW = vpW;
        s_lastVpH = vpH;
    }

    // Mirror main_appkit.mm drawInMTKView (805-869); ordering is load-bearing.
    renderer->setDrawable(drawable, passDesc);
    renderer->setLetterboxOrigin(ox, oy);
    renderer->viewport(ox, oy, vpW, vpH);
    renderer->beginFrame();
    ImmBatch_SetActiveRenderer(renderer);
    PyMOL_PushValidContext(INST(h));
    SceneRenderMetal(G);
    PyMOL_PopValidContext(INST(h));
    ImmBatch_SetActiveRenderer(nullptr);
    renderer->endFrame();
}

// --- Getters ---

void *PyMOLBridge_GetGlobals(PyMOLHandle h)
{
    return h ? PyMOL_GetGlobals(INST(h)) : nullptr;
}

void *PyMOLBridge_GetRenderer(PyMOLHandle h)
{
    PyMOLGlobals *G = h ? PyMOL_GetGlobals(INST(h)) : nullptr;
    return G ? G->Renderer : nullptr;
}

} // extern "C"
