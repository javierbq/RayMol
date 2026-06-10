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
    PyMOL_Start(INST(h));
    PyMOLGlobals *G = PyMOL_GetGlobals(INST(h));
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

void PyMOLBridge_Button(PyMOLHandle h, int button, int state,
                        int x, int y, int modifiers)
{
    if (h) PyMOL_Button(INST(h), button, state, x, y, modifiers);
}

void PyMOLBridge_Drag(PyMOLHandle h, int x, int y, int modifiers)
{
    if (h) PyMOL_Drag(INST(h), x, y, modifiers);
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
    if (command) {
        PyGILState_STATE gstate = PyGILState_Ensure();
        PyRun_SimpleString(command);
        PyGILState_Release(gstate);
    }
}

char *PyMOLBridge_GetFeedback(PyMOLHandle h)
{
    if (!h) return nullptr;

    PyMOLGlobals *G = PyMOL_GetGlobals(INST(h));
    if (!G) return nullptr;

    PyGILState_STATE gstate = PyGILState_Ensure();
    PyObject *result = PyRun_String(
        "from pymol import cmd\n"
        "_fb = cmd._get_feedback()\n"
        "_fb_text = '\\n'.join(_fb) if _fb else ''\n",
        Py_file_input, PyEval_GetGlobals(), PyEval_GetLocals());

    char *text = nullptr;
    if (result) {
        Py_DECREF(result);
        PyObject *fb = PyDict_GetItemString(PyEval_GetLocals(), "_fb_text");
        if (fb && PyUnicode_Check(fb)) {
            const char *str = PyUnicode_AsUTF8(fb);
            if (str && str[0]) {
                text = strdup(str);
            }
        }
    }

    PyGILState_Release(gstate);
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
