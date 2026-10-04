/*
 * The scene's light rig (#611): ownership, frame capture and re-centre, and
 * (#613) what a frame reads from it.
 *
 * One rig per PyMOL instance, held by the scene (CScene::lightRig; decision 1
 * of #610). No rig (std::nullopt) and a rig that is present but disabled are
 * different states: sessions, scenes and the L1 check rely on telling them
 * apart. The Metal renderer reads the rig once per frame, through
 * SceneLightsFrame(), which also applies decision 15 to the classic light
 * terms; with no rig, or a rig that is off, it reads exactly the settings it
 * read before #613. The maths is in LightShading.h.
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
#include "LightRigBlock.h"
#include "LightShading.h"
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

/**
 * What one frame needs from the lighting (#613): PyMOL's classic light terms,
 * after decision 15, and the rig packed for the GPU.
 */
struct SceneLightFrame {
  /// What setLightingParams() receives: the ambient, direct and reflect
  /// settings and the adjusted reflect specular (SceneGetAdjustedLightValues),
  /// or decision 15's terms while the rig is on (LightRigClassic).
  pymol::LightClassicTerms classic{};
  /// The adjusted shininess (spec_power); never scaled by the rig.
  float shininess = 0.0f;
  /// The rig resolved with the frame's world->eye matrix and packed
  /// (LightRigFrameBlock); nullopt when there is no rig or it is off.
  std::optional<pymol::LightRigBlock> rig;
};

/**
 * Read the lighting for one frame: the settings the Metal renderer has always
 * read, and the rig, once (the frame's snapshot point). `worldToEye` is the
 * frame's render modelview; _cmd.get_light_frame passes the live camera
 * (SceneGetWorldToEye) when it is given no matrix. Writes nothing. With no
 * rig, or a rig that is off, `classic` is the settings bit for bit and
 * nothing is resolved.
 */
SceneLightFrame SceneLightsFrame(PyMOLGlobals* G, const glm::dmat4& worldToEye);
