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

    PyImport_AppendInittab("_cmd", PyInit__cmd);
    Py_Initialize();

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

    init_cmd();

    PyMOLGlobals *G = PyMOL_GetGlobals(INST(h));
    PInit(G, true);

    PyMOL_SetDefaultMouse(INST(h));
    PyMOL_SetPythonInitStage(INST(h), 1);
}

void PyMOLBridge_Start(PyMOLHandle h)
{
    if (h) PyMOL_StartWithPython(INST(h));
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

    extern void SceneRenderMetal(PyMOLGlobals *);
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
