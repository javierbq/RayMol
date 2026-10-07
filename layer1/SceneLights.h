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
#include <vector>

#include <glm/mat4x4.hpp>

#include "LightAir.h"
#include "LightRig.h"
#include "LightRigBlock.h"
#include "LightShading.h"
#include "LightShadows.h"
#include "LightTone.h"
#include "Result.h"

struct PyMOLGlobals;
namespace pymol
{
struct CObject;
}

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

/**
 * What one frame needs from the lighting (#613): PyMOL's classic light terms,
 * after decision 15, and the rig packed for the GPU; and (#616) its studio
 * shadow maps.
 */
struct SceneLightFrame {
  /// What setLightingParams() receives: the ambient, direct and reflect
  /// settings and the adjusted reflect specular (SceneGetAdjustedLightValues),
  /// or decision 15's terms while the rig is on (LightRigClassic).
  pymol::LightClassicTerms classic{};
  /// The adjusted shininess (spec_power); never scaled by the rig.
  float shininess = 0.0f;
  /// The rig resolved with the frame's world->eye matrix and packed
  /// (LightRigFrameBlock); nullopt when there is no rig or it is off. While
  /// `shadows` is set its shadow slots, head.w, maps and grid are filled in
  /// (LightShadowPlan).
  std::optional<pymol::LightRigBlock> rig;
  /// Studio shadows are on (#616): the rig is on, metal_shadows is on and a
  /// light has `shadow`. Whatever the casters, the grid or the GPU, the
  /// whole-pixel (classic) shadow is then off.
  bool studioShadows = false;
  /// Each map's texels per side (LightShadowMapSize) while studioShadows,
  /// else 0.
  int shadowMapSize = 0;
  /// This frame's maps: set when studioShadows and there are casters
  /// (SceneGetLightShadowExtent) in front of at least one shadowed light.
  std::optional<pymol::LightShadowFrame> shadows;
  /// The air (#618): the rig's haze and dust with its frame in eye space,
  /// copied from the frame's one rig read; set only when the rig is on and
  /// haze or dust is above 0. Nothing else is read for it here: the gates
  /// (grid, geometry), the clock and the settings are SceneLightsAir's.
  std::optional<pymol::LightAirSource> airSource;
};

/**
 * Read the lighting for one frame: the settings the Metal renderer has always
 * read, and the rig, once (the frame's snapshot point). `worldToEye` is the
 * frame's render modelview; _cmd.get_light_frame passes the live camera
 * (SceneGetWorldToEye) when it is given no matrix. Writes nothing. With no
 * rig, or a rig that is off, `classic` is the settings bit for bit and
 * nothing is resolved.
 *
 * Studio shadows (#616) are planned only when the rig is on, metal_shadows is
 * on and a light has `shadow`: only then are metal_light_shadow_size,
 * metal_shadow_bias, the overlay-free caster extent and the grid read. The
 * grid is the scene's (G->Scene->grid, laid out by SceneRenderMetal before
 * this call) unless `grid` overrides it (_cmd.get_light_frame, tests).
 */
SceneLightFrame SceneLightsFrame(PyMOLGlobals* G, const glm::dmat4& worldToEye,
    const pymol::LightShadowGridOverride* grid = nullptr);

/**
 * HDR (#624): fill `block.tone` for a frame whose rig is on: x the exposure
 * (LightToneExposure of metal_exposure), y 1 for HDR else 0 (LightHdrOn of
 * metal_light_hdr, with the platform's default), z and w 0. Reads those two
 * settings and nothing else. SceneLightsFrame calls it only when the rig is
 * on (frame.rig), so with no rig, or a rig that is off, neither setting is
 * read.
 */
void SceneLightsToneFill(PyMOLGlobals* G, pymol::LightRigBlock& block);

/* ---- The air (#618) ------------------------------------------------------
 * Haze and dust, drawn by the Metal renderer's air pass. SceneRenderMetal
 * calls SceneLightsAir() once per frame, after SceneLightsFrame(), and hands
 * the block to the renderer (setLightAir). No air without a rig that is on
 * with haze or dust (airSource), without geometry, or in grid mode.
 */

/// Overrides for _cmd.get_light_air_frame (CI has no renderer, grid or live
/// clock): each unset field reads what a frame reads.
struct SceneLightAirOptions {
  /// The frame renders offscreen (else Renderer::offscreenFrame()).
  std::optional<bool> offscreen;
  /// The live clock in seconds (else UtilGetSeconds).
  std::optional<double> wallSeconds;
  /// The grid layout (else the scene's, G->Scene->grid).
  const pymol::LightShadowGridOverride* grid = nullptr;
};

/**
 * This frame's air block, or nullopt when the frame draws no air. Tests, in
 * order and reading nothing before its turn: the frame's airSource; grid
 * mode (D8: no air in a grid); something to light (the overlay-free extent,
 * SceneGetLightShadowExtent, so overlays alone never get air); then reads
 * the dust clock (LightAirClock: metal_light_air_time, movie frame and
 * movie_fps, the renderer's offscreen flag, MoviePlaying on live frames only,
 * the wall clock) and metal_light_air_resolution and
 * metal_light_air_shadow_filter, and packs (LightAirPack). Writes nothing and
 * never requests a redraw.
 */
std::optional<pymol::LightAirBlock> SceneLightsAir(PyMOLGlobals* G,
    const SceneLightFrame& frame, const SceneLightAirOptions* options = nullptr);

/**
 * The dust moves on its own, so the live view must redraw for it
 * (LightAirAnimating): the rig is on, dust and dust_speed are above 0, the
 * clock is not pinned, no movie plays, no grid and there is geometry. Cheap
 * tests first, the extent last. Main thread (MoviePlaying). Writes nothing and
 * never requests a redraw: the app's redraw policy asks it (#618 D11).
 */
bool SceneLightsAirAnimating(PyMOLGlobals* G);

/* ---- Studio shadow casters (#616) ----------------------------------------
 * Overlays never cast studio shadows (#433): the studio pre-pass excludes
 * them and the frusta are fitted to an extent without them.
 */

/// The Move gizmo's CGO (modules/pymol/metal_move.py, _GIZMO_OBJ).
inline constexpr const char* kSceneMoveGizmoName = "_move_gizmo";

/// True for an overlay: a gadget, a gizmo, or the Move gizmo's CGO.
bool SceneObjectIsOverlay(const pymol::CObject* obj);

/// The scene's overlays (scene members that SceneObjectIsOverlay), for the
/// studio pre-pass's `exclude` list. Call after ExecutiveUpdateSceneMembers.
std::vector<pymol::CObject*> SceneLightShadowOverlays(PyMOLGlobals* G);

/// The scene members' names, split into casters and excluded overlays
/// (_cmd.get_light_shadow_casters). Call after ExecutiveUpdateSceneMembers.
void SceneLightShadowCasterNames(PyMOLGlobals* G,
    std::vector<std::string>& casters, std::vector<std::string>& excluded);
