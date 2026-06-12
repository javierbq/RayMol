// PyMOLBridge.h — C bridging header for Swift ↔ PyMOL embedding API
// This header exposes the C functions Swift needs to drive PyMOL.

#pragma once

#ifdef __cplusplus
extern "C" {
#endif

#include <stdbool.h>

// Opaque PyMOL instance handle (CPyMOL* in the implementation)
typedef void* PyMOLHandle;

// --- Lifecycle ---
PyMOLHandle PyMOLBridge_New(void);
void PyMOLBridge_Free(PyMOLHandle instance);
void PyMOLBridge_InitPython(PyMOLHandle instance, const char *resourcePath);
void PyMOLBridge_Start(PyMOLHandle instance);
void PyMOLBridge_Stop(PyMOLHandle instance);

// --- Render loop ---
int  PyMOLBridge_Idle(PyMOLHandle instance);
void PyMOLBridge_Draw(PyMOLHandle instance);
void PyMOLBridge_Reshape(PyMOLHandle instance, int width, int height);
int  PyMOLBridge_GetRedisplay(PyMOLHandle instance, int reset);

// --- Input ---
void PyMOLBridge_Button(PyMOLHandle instance, int button, int state, int x, int y, int modifiers);
void PyMOLBridge_Drag(PyMOLHandle instance, int x, int y, int modifiers);
void PyMOLBridge_SetLetterboxAspect(PyMOLHandle instance, float aspect);
void PyMOLBridge_CapturePNG(PyMOLHandle instance, const char* path);
// Hi-res offscreen render → PNG: reshape PyMOL to width×height, render the full
// Metal pipeline (all reps + hardware-RT AO/shadows when metal_raytrace is on)
// into offscreen targets at that resolution, write the PNG, then restore the
// window size. Synchronous (blocks until the file is written). Runs on the main
// thread, sequenced with the live draw loop.
void PyMOLBridge_RenderHiResPNG(PyMOLHandle instance, const char* path, int width, int height);
void PyMOLBridge_Key(PyMOLHandle instance, unsigned char k, int x, int y, int modifiers);

// --- Context management ---
void PyMOLBridge_PushValidContext(PyMOLHandle instance);
void PyMOLBridge_PopValidContext(PyMOLHandle instance);

// --- Python execution ---
void PyMOLBridge_RunCommand(const char *command);
char *PyMOLBridge_GetFeedback(PyMOLHandle instance);
void PyMOLBridge_FreeFeedback(char *str);

// --- Metal rendering ---
void PyMOLBridge_RenderMetal(PyMOLHandle instance);

// Construct the Metal renderer from the MTKView (idempotent), and hand off the
// per-frame drawable + render-pass descriptor (mtkView/drawable/passDescriptor
// passed as opaque void* so this C header needs no Metal import).
void PyMOLBridge_SetupMetalRenderer(PyMOLHandle instance, void *mtkView);
void PyMOLBridge_RenderMetalFrame(PyMOLHandle instance, void *drawable, void *passDescriptor, int width, int height);

// Debug: execute raw Python (PyRun_SimpleString) under the GIL.
void PyMOLBridge_RunPython(const char *code);

// Tap-to-select: NDC coords in [-1,1], aspect = width/height. Runs the CPU-side
// metal_pick.pick_at (GL color picking is unavailable on the Metal backend).
void PyMOLBridge_Pick(PyMOLHandle instance, float ndcX, float ndcY, float aspect);

// --- Getters ---
void *PyMOLBridge_GetGlobals(PyMOLHandle instance);
void *PyMOLBridge_GetRenderer(PyMOLHandle instance);

// --- Button/modifier constants (match PyMOL's defines) ---
#define PYMOL_BUTTON_LEFT    0
#define PYMOL_BUTTON_MIDDLE  1
#define PYMOL_BUTTON_RIGHT   2
#define PYMOL_BUTTON_SCROLL_FORWARD 3
#define PYMOL_BUTTON_SCROLL_REVERSE 4
#define PYMOL_BUTTON_DOWN    0
#define PYMOL_BUTTON_UP      1

#define PYMOL_MOD_SHIFT  1
#define PYMOL_MOD_CTRL   2
#define PYMOL_MOD_ALT    4

#ifdef __cplusplus
}
#endif
