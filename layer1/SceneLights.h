/*
 * The scene's light rig (#611): ownership, frame capture and re-centre.
 *
 * One rig per PyMOL instance, held by the scene (CScene::lightRig; decision 1
 * of #610). No rig (std::nullopt) and a rig that is present but disabled are
 * different states: sessions, scenes and the L1 check rely on telling them
 * apart. Nothing in rendering reads the rig yet (#613 will).
 *
 * No Python here (LightRigPy.h has the conversions), so the app bridge can
 * call these directly, one call per drag tick, on the main thread.
 */

#pragma once

#include <optional>
#include <string>
#include <string_view>

#include <glm/mat4x4.hpp>

#include "LightRig.h"
#include "Result.h"

struct PyMOLGlobals;

/// The rig, or nullptr when there is none.
const pymol::LightRig* SceneGetLightRig(PyMOLGlobals* G);

/**
 * Store `rig` (std::nullopt removes it) and request a redraw. Setting no rig
 * when there is none does nothing at all, so the no-rig path runs no code.
 * The rig is stored as given: callers validate first.
 */
void SceneSetLightRig(PyMOLGlobals* G, std::optional<pymol::LightRig> rig);

/**
 * Replace the rig with `rig`: capture its frame when it has lights and no
 * centre/size, then validate, then store. On error the current rig is left
 * unchanged.
 */
pymol::Result<> SceneLightsReplace(PyMOLGlobals* G, pymol::LightRig rig);

/**
 * The rig frame for the current scene (spec §4.3, Q5): the box of the
 * enabled objects in the current state, that is the enabled atoms with
 * solvent excluded, plus the cached extents of enabled objects that are not
 * molecules (maps, meshes, isosurfaces, CGOs, measurements, slices, volumes;
 * not gadgets or gizmos). The centre is the box midpoint and the size half
 * its diagonal (at least 1 Å). Falls back to every enabled atom when only
 * solvent is enabled, and to the rotation origin with 10 Å when nothing
 * enabled has an extent.
 */
void SceneLightRigCapture(PyMOLGlobals* G, glm::dvec3& centre, double& size);

/// Capture the frame again (`lights recenter`). Error when there is no rig.
pymol::Result<> SceneLightsRecenter(PyMOLGlobals* G);

/**
 * The live camera's world->eye matrix, T(pos)·R·T(-origin): the matrix
 * SceneComposeModelViewMatrix() builds and cmd.get_view() describes. It is
 * the mono view; the renderer (#613) resolves with its own per-frame
 * modelview instead.
 */
glm::dmat4 SceneGetWorldToEye(PyMOLGlobals* G);

/**
 * LightRigSet() on the scene's rig with the live camera (the pin
 * conversions use it), then a redraw request when the rig changed. NoRig
 * when there is no rig. The app bridge calls this once per drag tick.
 */
pymol::LightSetStatus SceneLightSet(PyMOLGlobals* G, int index,
    std::string_view field, const double* v, int n, std::string* msg = nullptr);

/// LightRigGet() on the scene's rig; NoRig when there is none.
pymol::LightSetStatus SceneLightGet(PyMOLGlobals* G, int index,
    std::string_view field, pymol::LightValue& out,
    const pymol::LightField** info = nullptr, std::string* msg = nullptr);

/**
 * The rig resolved to eye space with `worldToEye`, or with the live camera
 * (SceneGetWorldToEye) when it is null. nullopt when there is no rig.
 */
std::optional<pymol::LightRigEye> SceneLightsResolve(
    PyMOLGlobals* G, const glm::dmat4* worldToEye = nullptr);

/// The rig as JSON (LightRigToJSON), or nullopt when there is no rig.
std::optional<std::string> SceneLightsJSON(PyMOLGlobals* G);

/* ---- CPU ray notice (#626) -----------------------------------------------
 * Studio lighting is drawn only by the Metal renderer. The CPU tracer (`ray`,
 * `png ..., ray=1`, a headless `png`, `mpng` in ray mode, POV-Ray immediate
 * mode) keeps PyMOL's own lights and never reads the rig, so a CPU image made
 * while the rig is on says so, once per command.
 */

/// The rig is on: present, enabled, with at least one light (and its frame).
/// False when there is no rig. "Studio lights in use" everywhere in the core.
bool SceneLightsOn(PyMOLGlobals* G);

/// "studio lights are Metal-only; this ray-traced image uses PyMOL's lights."
/// when SceneLightsOn, else nullptr. The one copy of the text (C++, _cmd, MCP).
const char* SceneLightsRayNoticeText(PyMOLGlobals* G);

/**
 * For a CPU image about to be traced with SceneRay mode `mode`: when mode is
 * 0 (built-in) or 1 (POV-Ray) and the rig is on, print " Ray: <text>" through
 * PRINTFB(FB_Ray, FB_Warnings) and return true; otherwise do nothing and
 * return false. Call once per command, never per frame, tile or stereo eye.
 * It is a warning, so it ignores `quiet` (`feedback disable, ray, warnings`
 * silences it). Writes no setting and no scene state.
 */
bool SceneLightsRayNotice(PyMOLGlobals* G, int mode);
