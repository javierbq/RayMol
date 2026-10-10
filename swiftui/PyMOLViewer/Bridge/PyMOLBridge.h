// PyMOLBridge.h — C bridging header for Swift ↔ PyMOL embedding API
// This header exposes the C functions Swift needs to drive PyMOL.

#pragma once

#ifdef __cplusplus
extern "C" {
#endif

#include <stdbool.h>

#include "PyMOLBridgeLights.h"   // light-rig types and PYMOL_LIGHT_SET_* (#611)

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
// RGB (0..1) of the 3D selection indicator squares — set from the active theme.
void PyMOLBridge_SetSelectionColor(PyMOLHandle instance, float r, float g, float b);
// RGB (0..1) of the transient hover-preview indicator points (issue #165).
void PyMOLBridge_SetPreselectionColor(PyMOLHandle instance, float r, float g, float b);
void PyMOLBridge_CapturePNG(PyMOLHandle instance, const char* path);
// Hi-res offscreen render → PNG: reshape PyMOL to width×height, render the full
// Metal pipeline (all reps + hardware-RT AO/shadows) into offscreen targets at
// that resolution, write the PNG, then restore the window size. Synchronous
// (blocks until the file is written). Runs on the main thread, sequenced with
// the live draw loop. rayTraced: -1 = use the current metal_raytrace setting
// (WYSIWYG); 0 = force OFF; 1 = force ON for this export only (the live setting
// is saved and restored, so the on-screen view is unchanged).
void PyMOLBridge_RenderHiResPNG(PyMOLHandle instance, const char* path, int width, int height, int rayTraced);
/// #601: write PNGs uncompressed and unfiltered (process-wide) -- for a movie
/// export's throwaway per-frame files only; turn it back off after the render.
void PyMOLBridge_SetFastPNG(int on);
// Rebuild dirty object representations on the calling thread. Call on the MAIN
// thread before an off-main renderHiResPNG so the rep rebuild (which touches the
// Python C-API via the busy-status callback) doesn't run on the render queue.
void PyMOLBridge_UpdateScene(PyMOLHandle instance);
// Hardware ray-tracing capability of the active GPU. 1 = supported,
// 0 = not supported, -1 = unknown (renderer not yet created). Lets the UI
// gate the metal_raytrace toggle so it isn't offered where it does nothing.
int PyMOLBridge_SupportsRayTracing(PyMOLHandle instance);
// Fires a cmd.set_key binding by its canonical PyMOL key token ("left",
// "CTRL-T", "ALT-A", "F1"). Returns 1 if a binding existed and was invoked
// (including when the binding's callable raised — the key is still consumed so
// it isn't ALSO dispatched to a menu). Returns 0 when the key is unbound, and
// also 0 when pymol.internal cannot be imported (shutdown / corrupted state) —
// in that case no binding could have run, so the key falls through to macOS
// menus and RayMol's own ⌃M / ⌃D shortcuts keep working (#258).
int PyMOLBridge_InvokeKey(const char *key);

// --- Context management ---
void PyMOLBridge_PushValidContext(PyMOLHandle instance);
void PyMOLBridge_PopValidContext(PyMOLHandle instance);

// --- Python execution ---
void PyMOLBridge_RunCommand(const char *command);

// Capture/restore PyMOL's complete camera state (rotation, origin, zoom, and
// clipping). `view` must point to exactly 25 floats (cSceneViewSize).
int PyMOLBridge_GetView(PyMOLHandle instance, float *view, int count);
int PyMOLBridge_SetView(PyMOLHandle instance, const float *view, int count, float animate);

// --- Light rig (#611, spec §4.4) ---
// Direct C++ on the scene's rig (layer1/SceneLights.h): no Python, so one call
// per drag tick is cheap. MAIN THREAD ONLY, like GetView/SetView, and never
// while a movie export is rendering off-main. Types and codes:
// PyMOLBridgeLights.h.
//
// The rig as JSON, with the keys, order and types of cmd.get_lights(); NULL
// when there is no rig. Free with PyMOLBridge_FreeFeedback.
char *PyMOLBridge_LightsJSON(PyMOLHandle instance);
// Set one number field of light `index` (>= 0), or of the rig and its air
// (index -1): orbit, pitch, radius, beam, softness, warmth, intensity,
// highlight, falloff, shadow, outline, anchor (0 camera, 1 pin where it is
// now), aim (0 centre, 1 point); enabled, ambient, classic, haze, dust,
// dust_size, dust_speed, scatter, seed. Numbers are clamped into range.
// Returns a PYMOL_LIGHT_SET_* code; the rig is unchanged unless it is OK.
int PyMOLBridge_LightSet(PyMOLHandle instance, int index, const char *field, double value);
// Set one vector field of light `index`: color (sRGB 0..1), aim_point (world
// Å; aims the light at it) or position (world Å; pins the light there).
int PyMOLBridge_LightSetVector(PyMOLHandle instance, int index, const char *field, double x, double y, double z);
// Resolve the rig for the live camera, including each light's shadow-map
// slot (#673). Fills *rig (when not NULL) and the first min(count, capacity)
// entries of `lights`; returns the light count, or -1 when there is no rig.
// PYMOL_LIGHTS_MAX entries always suffice.
int PyMOLBridge_LightsEyeSpace(PyMOLHandle instance, PyMOLLightRigEye *rig, PyMOLLightEye *lights, int capacity);

// --- The rig's air (#618) ---
// 1 when the rig's dust moves on its own, so the live view needs a frame per
// air tick even though nothing else changed (SceneLightsAirAnimating: the rig
// is on, dust and dust_speed > 0, metal_light_air_time does not pin the clock,
// no movie plays, grid_mode is off and something is shown); 0 otherwise.
// Plain C++ on the scene's rig, no Python. The render loop asks it at most
// once per air tick, and only when its redraw policy (AirRedrawGate,
// MetalViewport.swift) allows a tick. MAIN THREAD ONLY (it asks whether a
// movie plays), never while a movie export renders off-main. Named outside
// PyMOLBridge_Light*, whose set lighting_bridge.py pins.
int PyMOLBridge_AirAnimating(PyMOLHandle instance);

// Document-generation counter (#649); 0 when there is no instance.
unsigned PyMOLBridge_DocumentGeneration(PyMOLHandle instance);

// Tab autocomplete: runs PyMOL's own command-line completion (cmd._parser.complete)
// on the current input and returns the completed string (extended to the
// unambiguous prefix; the candidate list, when ambiguous, is printed to the
// feedback log). Returns NULL if there's no completion. Caller frees with
// PyMOLBridge_FreeFeedback.
char *PyMOLBridge_Complete(const char *text);
char *PyMOLBridge_GetFeedback(PyMOLHandle instance);
void PyMOLBridge_FreeFeedback(char *str);

// --- Metal rendering ---
void PyMOLBridge_RenderMetal(PyMOLHandle instance);

// Construct the Metal renderer from the MTKView (idempotent), and hand off the
// per-frame drawable + render-pass descriptor (mtkView/drawable/passDescriptor
// passed as opaque void* so this C header needs no Metal import).
void PyMOLBridge_SetupMetalRenderer(PyMOLHandle instance, void *mtkView);

// Render one live frame at width x height (backing pixels).
//
// The CAMetalDrawable is acquired HERE, from the view, only once the scene has
// been encoded — not by the caller beforehand (#396). Only the final post pass
// writes to the drawable, so asking for it earlier just parked the main thread
// in `currentDrawable` (and stalled input) for as long as the GPU was behind.
//
// Returns 1 if a frame was presented, 0 if the drawable never arrived (the
// offscreen work is still committed; the caller should render again) or if
// there is no renderer yet.
int PyMOLBridge_RenderMetalFrame(PyMOLHandle instance, void *mtkView, int width, int height);

// Live Metal frames committed but not yet completed on the GPU. The render loop
// skips a tick above a small cap so the late currentDrawable wait stays short.
// 0 when there is no renderer.
int PyMOLBridge_MetalFramesInFlight(PyMOLHandle instance);

// Current value of cSetting_metal_raytrace (1/0). Ray tracing is the GPU-bound
// case, where the render loop drops its display link to 60 Hz.
int PyMOLBridge_GetMetalRaytrace(PyMOLHandle instance);

// Debug: execute raw Python (PyRun_SimpleString) under the GIL.
void PyMOLBridge_RunPython(const char *code);
// Run read-only Python (the periodic UI polls) WITHOUT leaving a redisplay
// behind: if PyMOL's redisplay flag was clear before, it is cleared again
// afterwards. The polls create/destroy temporary selections (count_atoms,
// count_states, ...), and the core marks the scene changed for those, so an
// idle window was re-rendering a full frame — with ray tracing, 20-30 ms of
// GPU — on every poll (~2-3 frames/s while nothing moved).
void PyMOLBridge_RunPythonQuiet(PyMOLHandle instance, const char *code);

// Tap-to-select: NDC coords in [-1,1], aspect = width/height. Runs the CPU-side
// metal_pick.pick_at (GL color picking is unavailable on the Metal backend).
void PyMOLBridge_Pick(PyMOLHandle instance, float ndcX, float ndcY, float aspect);

// --- Surface pick (#614) ---
//
// The drawn surface point and normal under a screen point: the camera ray,
// clipped to the slab, against the geometry surfaces, cartoons, spheres and
// sticks actually draw (layer3/SurfacePick.h). Read-only: never draws and
// never changes anything a render reads.
//
// sceneNdcX/Y: NDC of the SCENE viewport (the letterboxed sub-rect when a
// letterbox is set, see PyMOLBridge_GetLetterboxAspect), x and y in [-1, 1],
// +y up. In grid_mode it is still the whole scene viewport; the core finds
// the cell.
//
// flags & 1 ("update"): first run the frame's update phase (rebuild dirty
// representations). That can reach the Python C-API, so it is MAIN THREAD
// ONLY. With flags & 1 == 0 nothing touches Python: it picks what was last
// built (what the last frame drew), which is what a drag tick wants.
//
// out must hold count == 8 floats: x, y, z (world point), nx, ny, nz (unit
// normal facing the camera), depth (eye-space distance along the view axis,
// Angstrom), facing (dot of the oriented normal with the toward-camera
// direction BEFORE the silhouette nudge).
//
// Returns 0 on a miss, a null handle, a null out, a bad count, or while a
// modal draw owns the core -- out is then left untouched. Otherwise
// 1 | inside << 1 | cap << 2: inside = the ray met the geometry from inside
// (the far wall of a clipped closed shape; "back face" on open geometry);
// cap = a flat interior cap at a clip plane (metal_interior_cap).
int PyMOLBridge_SurfacePick(PyMOLHandle instance, float sceneNdcX, float sceneNdcY,
                            int flags, float *out, int count);
// Build the surface-pick grid of every drawn pickable representation without
// picking, so the first pick or drag does not pay for it. flags & 1 = update
// first (main thread only, as above). Returns how many grids are held after
// the call (0 on a null handle or under a modal draw).
int PyMOLBridge_SurfacePickPrepare(PyMOLHandle instance, int flags);
// Drop every surface-pick grid (all molecules, all states), giving their
// memory back: call it on leaving a mode that picks, or on a memory warning.
// The next pick or prepare rebuilds what it needs. Never touches Python and
// changes nothing a render reads; the same thread rules as
// PyMOLBridge_SurfacePick with flags 0. Returns how many grids were dropped
// (0 on a null handle or under a modal draw).
int PyMOLBridge_SurfacePickRelease(PyMOLHandle instance);
// The letterbox aspect (width / height) the live frame renders the scene into,
// as set by PyMOLBridge_SetLetterboxAspect; 0 = the scene fills the view (also
// when there is no renderer yet).
float PyMOLBridge_GetLetterboxAspect(PyMOLHandle instance);

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
