// PyMOLBridge.mm — C bridge implementation connecting Swift to PyMOL's embedding API
// Compiled as Objective-C++ to access both the C++ PyMOL internals and ObjC Metal APIs.
//
// NOTE: PyMOL include paths come from OTHER_CPLUSPLUSFLAGS in
// PyMOLBridge.xcconfig (not HEADER_SEARCH_PATHS, which would break
// Clang module builds due to layer0/Block.h shadowing system Block.h).

#include "PyMOLBridge.h"

#include "PyMOL.h"
#include "PyMOLOptions.h"
#include "P.h"

#import <Foundation/Foundation.h>
#import <Python.h>

// Forward declarations from PyMOL internals
extern "C" {
  PyObject *PyInit__cmd(void);
  void init_cmd(void);
}

// --- Lifecycle ---

CPyMOL *PyMOLBridge_New(void)
{
    CPyMOLOptions *options = PyMOLOptions_New();
    if (!options) return nullptr;

    options->show_splash = 1;
    options->internal_gui = 0;       // We provide our own GUI
    options->internal_feedback = 1;
    options->external_gui = 0;

    CPyMOL *instance = PyMOL_NewWithOptions(options);
    PyMOLOptions_Free(options);
    return instance;
}

void PyMOLBridge_Free(CPyMOL *instance)
{
    if (instance) {
        PyMOL_Stop(instance);
        PyMOL_Free(instance);
    }
}

void PyMOLBridge_InitPython(CPyMOL *instance, const char *resourcePath)
{
    if (!instance || !resourcePath) return;

    // Register the _cmd module before Py_Initialize
    PyImport_AppendInittab("_cmd", PyInit__cmd);

    // Initialize Python
    Py_Initialize();

    // Set up module search paths
    NSString *resPath = [NSString stringWithUTF8String:resourcePath];
    NSString *modulesPath = [resPath stringByAppendingPathComponent:@"modules"];
    NSString *dataPath = [resPath stringByAppendingPathComponent:@"data"];

    char script[2048];
    snprintf(script, sizeof(script),
        "import sys, os\n"
        "sys.path.insert(0, '%s')\n"
        "os.environ['PYMOL_DATA'] = '%s'\n"
        "os.environ['PYMOL_PATH'] = '%s'\n",
        [modulesPath UTF8String],
        [dataPath UTF8String],
        [resPath UTF8String]);
    PyRun_SimpleString(script);

    // Initialize the _cmd module and PyMOL's Python layer
    init_cmd();

    PyMOLGlobals *G = PyMOL_GetGlobals(instance);
    PInit(G, true);

    // Configure mouse bindings
    PyMOL_SetDefaultMouse(instance);
    PyMOL_SetPythonInitStage(instance, 1);
}

void PyMOLBridge_Start(CPyMOL *instance)
{
    if (instance) PyMOL_StartWithPython(instance);
}

void PyMOLBridge_Stop(CPyMOL *instance)
{
    if (instance) PyMOL_Stop(instance);
}

// --- Render loop ---

int PyMOLBridge_Idle(CPyMOL *instance)
{
    return instance ? PyMOL_Idle(instance) : 0;
}

void PyMOLBridge_Draw(CPyMOL *instance)
{
    if (instance) PyMOL_Draw(instance);
}

void PyMOLBridge_Reshape(CPyMOL *instance, int width, int height)
{
    if (instance) PyMOL_Reshape(instance, width, height, 0);
}

int PyMOLBridge_GetRedisplay(CPyMOL *instance, int reset)
{
    return instance ? PyMOL_GetRedisplay(instance, reset) : 0;
}

// --- Input ---

void PyMOLBridge_Button(CPyMOL *instance, int button, int state,
                        int x, int y, int modifiers)
{
    if (instance) PyMOL_Button(instance, button, state, x, y, modifiers);
}

void PyMOLBridge_Drag(CPyMOL *instance, int x, int y, int modifiers)
{
    if (instance) PyMOL_Drag(instance, x, y, modifiers);
}

void PyMOLBridge_Key(CPyMOL *instance, unsigned char k, int x, int y, int modifiers)
{
    if (instance) PyMOL_Key(instance, k, x, y, modifiers);
}

// --- Context management ---

void PyMOLBridge_PushValidContext(CPyMOL *instance)
{
    if (instance) PyMOL_PushValidContext(instance);
}

void PyMOLBridge_PopValidContext(CPyMOL *instance)
{
    if (instance) PyMOL_PopValidContext(instance);
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

char *PyMOLBridge_GetFeedback(CPyMOL *instance)
{
    // Polls PyMOL's feedback buffer and returns accumulated text.
    // Caller must free with PyMOLBridge_FreeFeedback.
    if (!instance) return nullptr;

    PyMOLGlobals *G = PyMOL_GetGlobals(instance);
    if (!G) return nullptr;

    // Use Python to poll feedback
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

void PyMOLBridge_RenderMetal(CPyMOL *instance)
{
    if (!instance) return;
    PyMOLGlobals *G = PyMOL_GetGlobals(instance);
    if (!G) return;

    extern void SceneRenderMetal(PyMOLGlobals *);
    SceneRenderMetal(G);
}

// --- Getters ---

void *PyMOLBridge_GetGlobals(CPyMOL *instance)
{
    return instance ? PyMOL_GetGlobals(instance) : nullptr;
}

void *PyMOLBridge_GetRenderer(CPyMOL *instance)
{
    PyMOLGlobals *G = instance ? PyMOL_GetGlobals(instance) : nullptr;
    return G ? G->Renderer : nullptr;
}
