/*
 * The scene's light rig (#611). See SceneLights.h.
 */

#include "SceneLights.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <utility>

#include <glm/geometric.hpp>

#include "Executive.h"
#include "Feedback.h"
#include "Movie.h"
#include "PyMOLGlobals.h"
#include "PyMOLObject.h"
#include "Renderer.h"
#include "Scene.h"
#include "SceneDef.h"
#include "Selector.h"
#include "Setting.h"
#include "Util.h"

const pymol::LightRig* SceneGetLightRig(PyMOLGlobals* G)
{
  const auto& rig = G->Scene->lightRig;
  return rig ? &*rig : nullptr;
}

void SceneSetLightRig(PyMOLGlobals* G, std::optional<pymol::LightRig> rig)
{
  auto& current = G->Scene->lightRig;
  if (!current && !rig)
    return;
  current = std::move(rig);
  SceneInvalidate(G);
}

pymol::Result<> SceneLightsReplace(PyMOLGlobals* G, pymol::LightRig rig)
{
  if (!rig.lights.empty() && !rig.centre && !rig.size) {
    glm::dvec3 centre;
    double size;
    SceneLightRigCapture(G, centre, size);
    rig.centre = centre;
    rig.size = size;
  }
  auto valid = pymol::LightRigValidate(rig);
  p_return_if_error(valid);
  SceneSetLightRig(G, std::move(rig));
  return {};
}

void SceneLightRigCapture(PyMOLGlobals* G, glm::dvec3& centre, double& size)
{
  float mn[3], mx[3];
  bool found = false;
  auto include = [&](const float* lo, const float* hi) {
    for (int i = 0; i < 3; ++i) {
      mn[i] = found ? std::min(mn[i], lo[i]) : lo[i];
      mx[i] = found ? std::max(mx[i], hi[i]) : hi[i];
    }
    found = true;
  };
  auto includeAtoms = [&](const char* expr) {
    SelectorTmp tmp(G, expr);
    float lo[3], hi[3];
    if (tmp.getAtomCount() > 0 &&
        ExecutiveGetExtent(G, tmp.getName(), lo, hi, /* transformed */ true,
            /* current state */ -2, /* weighted */ false))
      include(lo, hi);
  };

  // The extent of the enabled objects in the current state (§4.3). Atoms
  // with solvent left out, as for the shadow frustum: scattered waters would
  // inflate 1x.
  includeAtoms("(enabled and not solvent)");

  // Enabled objects that are not molecules (maps, meshes, isosurfaces, CGOs,
  // measurements, slices, volumes): their cached extents, as zoom and the
  // shadow frustum use them. Left out: alignments (their atoms are the
  // molecules'), gadgets (drawn in screen space) and gizmos (UI).
  ExecutiveUpdateSceneMembers(G);
  for (auto* obj : G->Scene->Obj) {
    switch (obj->type) {
    case cObjectMolecule:
    case cObjectAlignment:
    case cObjectGadget:
    case cObjectGizmo:
    case cObjectGroup:
      continue;
    case cObjectMap:
    case cObjectMesh:
    case cObjectSurface:
      if (!obj->ExtentFlag)
        obj->update(); // as ExecutiveGetExtent: let it compute its extent
      break;
    default:
      break;
    }
    if (obj->ExtentFlag)
      include(obj->ExtentMin, obj->ExtentMax);
  }

  // Only solvent enabled: every enabled atom.
  if (!found)
    includeAtoms("(enabled)");

  if (!found) {
    float origin[3];
    SceneOriginGet(G, origin);
    centre = glm::dvec3(origin[0], origin[1], origin[2]);
    size = 10.0;
    return;
  }

  const glm::dvec3 lo(mn[0], mn[1], mn[2]);
  const glm::dvec3 hi(mx[0], mx[1], mx[2]);
  const glm::dvec3 d = hi - lo;
  centre = (lo + hi) * 0.5;
  size = std::max(0.5 * std::sqrt(d.x * d.x + d.y * d.y + d.z * d.z), 1.0);
}

glm::dmat4 SceneGetWorldToEye(PyMOLGlobals* G)
{
  return glm::dmat4(G->Scene->m_view.getView().toWorldHomogeneous());
}

pymol::LightSetStatus SceneLightSet(PyMOLGlobals* G, int index,
    std::string_view field, const double* v, int n, std::string* msg)
{
  auto& rig = G->Scene->lightRig;
  if (!rig) {
    if (msg)
      *msg = "there is no light rig";
    return pymol::LightSetStatus::NoRig;
  }
  auto status =
      pymol::LightRigSet(*rig, index, field, v, n, SceneGetWorldToEye(G), msg);
  if (status == pymol::LightSetStatus::Ok)
    SceneInvalidate(G);
  return status;
}

pymol::LightSetStatus SceneLightGet(PyMOLGlobals* G, int index,
    std::string_view field, pymol::LightValue& out,
    const pymol::LightField** info, std::string* msg)
{
  const auto* rig = SceneGetLightRig(G);
  if (!rig) {
    if (msg)
      *msg = "there is no light rig";
    return pymol::LightSetStatus::NoRig;
  }
  return pymol::LightRigGet(*rig, index, field, out, info, msg);
}

std::optional<pymol::LightRigEye> SceneLightsResolve(
    PyMOLGlobals* G, const glm::dmat4* worldToEye)
{
  const auto* rig = SceneGetLightRig(G);
  if (!rig)
    return std::nullopt;
  return pymol::LightRigResolve(
      *rig, worldToEye ? *worldToEye : SceneGetWorldToEye(G));
}

std::optional<std::string> SceneLightsJSON(PyMOLGlobals* G)
{
  const auto* rig = SceneGetLightRig(G);
  if (!rig)
    return std::nullopt;
  return pymol::LightRigToJSON(*rig);
}

pymol::Result<> SceneLightsRecenter(PyMOLGlobals* G)
{
  auto& rig = G->Scene->lightRig;
  if (!rig)
    return pymol::make_error("no light rig");
  glm::dvec3 centre;
  double size;
  SceneLightRigCapture(G, centre, size);
  rig->centre = centre;
  rig->size = size;
  SceneInvalidate(G);
  return {};
}

/* ---- CPU ray notice (#626) ---------------------------------------------- */

bool SceneLightsOn(PyMOLGlobals* G)
{
  // The one rig-on predicate (#613), shared with the renderer.
  return pymol::LightRigIsOn(SceneGetLightRig(G));
}

const char* SceneLightsRayNoticeText(PyMOLGlobals* G)
{
  return SceneLightsOn(G) ? "studio lights are Metal-only; this ray-traced "
                            "image uses PyMOL's lights."
                          : nullptr;
}

bool SceneLightsRayNotice(PyMOLGlobals* G, int mode)
{
#ifdef _PYMOL_NO_RAY
  (void) G;
  (void) mode;
  return false;
#else
  if (mode != 0 && mode != 1)
    return false;
  const char* text = SceneLightsRayNoticeText(G);
  if (!text)
    return false;
  PRINTFB(G, FB_Ray, FB_Warnings)
    " Ray: %s\n", text ENDFB(G);
  return true;
#endif
}

namespace
{
#ifdef _PYMOL_IOS
constexpr bool kSceneLightsMobile = true;
#else
constexpr bool kSceneLightsMobile = false;
#endif

/// A light packed in `block` (the first head.x of `rig`) has `shadow` set.
bool SceneLightsAnyShadowed(
    const pymol::LightRig& rig, const pymol::LightRigBlock& block)
{
  const std::size_t n = std::min(
      rig.lights.size(), static_cast<std::size_t>(std::max(int(block.head[0]), 0)));
  for (std::size_t i = 0; i < n; ++i) {
    if (rig.lights[i].shadow)
      return true;
  }
  return false;
}
} // namespace

void SceneLightsToneFill(PyMOLGlobals* G, pymol::LightRigBlock& block)
{
  block.tone[0] = pymol::LightToneExposure(
      SettingGetGlobal_f(G, cSetting_metal_exposure));
  block.tone[1] = pymol::LightHdrOn(
                      SettingGetGlobal_i(G, cSetting_metal_light_hdr),
                      kSceneLightsMobile)
                      ? 1.0f
                      : 0.0f;
  block.tone[2] = 0.0f;
  block.tone[3] = 0.0f;
}

SceneLightFrame SceneLightsFrame(PyMOLGlobals* G, const glm::dmat4& worldToEye,
    const pymol::LightShadowGridOverride* grid)
{
  // The settings SceneRenderMetal has always read (issue #72 explains the
  // specular adjustment).
  float specReflect, specPower, specDirect, specDirectPower;
  SceneGetAdjustedLightValues(
      G, &specReflect, &specPower, &specDirect, &specDirectPower);
  const pymol::LightClassicTerms settings{
      SettingGetGlobal_f(G, cSetting_ambient),
      SettingGetGlobal_f(G, cSetting_direct),
      SettingGetGlobal_f(G, cSetting_reflect),
      specReflect,
  };

  // The frame's one read of the rig.
  const pymol::LightRig* rig = SceneGetLightRig(G);

  SceneLightFrame frame;
  frame.classic = pymol::LightRigClassic(rig, settings);
  frame.shininess = specPower;
  frame.rig = pymol::LightRigFrameBlock(rig, worldToEye, specPower);
  if (frame.rig)
    SceneLightsToneFill(G, *frame.rig);

  // Studio shadows (#616). Nothing below runs, and nothing more is read,
  // unless the rig is on (frame.rig), metal_shadows is on and a light has
  // `shadow`: the block then stays #613's, bit for bit.
  if (frame.rig && SceneLightsAnyShadowed(*rig, *frame.rig) &&
      SettingGetGlobal_b(G, cSetting_metal_shadows)) {
    frame.studioShadows = true;
    frame.shadowMapSize = pymol::LightShadowMapSize(
        SettingGetGlobal_i(G, cSetting_metal_light_shadow_size),
        kSceneLightsMobile);
    float mn[3], mx[3];
    if (SceneGetLightShadowExtent(G, mn, mx)) {
      pymol::LightShadowInputs in;
      const glm::dvec3 lo(mn[0], mn[1], mn[2]);
      const glm::dvec3 hi(mx[0], mx[1], mx[2]);
      in.casterCentreEye =
          glm::vec3(worldToEye * glm::dvec4((lo + hi) * 0.5, 1.0));
      // The sphere around the box, through the matrix's largest scale (1
      // for a camera), with margins: molecule extents are atom centres.
      const double scale = std::max({glm::length(glm::dvec3(worldToEye[0])),
          glm::length(glm::dvec3(worldToEye[1])),
          glm::length(glm::dvec3(worldToEye[2]))});
      in.casterRadius = float(
          (0.5 * glm::length(hi - lo) * pymol::kLightShadowCasterMargin +
              pymol::kLightShadowCasterPad) *
          scale);
      in.biasScale = SettingGetGlobal_f(G, cSetting_metal_shadow_bias);
      in.mapSize = frame.shadowMapSize;
      pymol::LightShadowGridOverride g;
      if (grid) {
        g = *grid;
      } else {
        const GridInfo& sg = G->Scene->grid;
        g.active = sg.active;
        g.nCol = sg.n_col;
        g.nRow = sg.n_row;
        g.firstSlot = sg.first_slot;
      }
      if (g.active) {
        in.nCol = std::max(g.nCol, 1);
        in.nRow = std::max(g.nRow, 1);
        in.tiles = std::max(in.nCol, in.nRow);
        in.firstSlot = g.firstSlot;
      }
      frame.shadows = pymol::LightShadowPlan(*frame.rig, *rig, in);
    }
  }

  // The air (#618): only while the rig is on with haze or dust, a copy of the
  // rig's air and its frame in eye space, from the read above. Nothing else
  // is read here: SceneLightsAir applies the gates, the clock and the
  // settings.
  if (frame.rig && pymol::LightAirActive(rig->air))
    frame.airSource = pymol::LightAirSourceOf(*rig, worldToEye);
  return frame;
}

/* ---- The air (#618) ------------------------------------------------------ */

std::optional<pymol::LightAirBlock> SceneLightsAir(PyMOLGlobals* G,
    const SceneLightFrame& frame, const SceneLightAirOptions* options)
{
  // No rig that is on with haze or dust: nothing more is read.
  if (!frame.airSource)
    return std::nullopt;

  // D8: no air in grid mode (each cell has its own view; the pass marches
  // one ray per full-frame pixel).
  const bool grid = options && options->grid ? options->grid->active
                                             : G->Scene->grid.active;
  if (grid)
    return std::nullopt;

  // D7: no air without geometry. The overlay-free extent (cached), so a
  // scene holding only gadgets or the Move gizmo gets none.
  float mn[3], mx[3];
  if (!SceneGetLightShadowExtent(G, mn, mx))
    return std::nullopt;

  // D9: the dust clock. Offscreen frames (exports, png, the RT throwaway
  // frame) follow the movie frame; MoviePlaying (which may write Playing on
  // an interrupt) is asked only on live, unpinned frames.
  pymol::LightAirClockInputs in;
  in.pinned = SettingGetGlobal_f(G, cSetting_metal_light_air_time);
  in.offscreen = options && options->offscreen
                     ? *options->offscreen
                     : (G->Renderer && G->Renderer->offscreenFrame());
  in.frames = SceneCountFrames(G);
  in.frame = SceneGetFrame(G);
  in.fps = SettingGetGlobal_f(G, cSetting_movie_fps);
  if (!in.offscreen && !(in.pinned >= 0.0))
    in.playing = MoviePlaying(G) != 0;
  in.wallSeconds = options && options->wallSeconds ? *options->wallSeconds
                                                   : UtilGetSeconds(G);

  const int resolution = pymol::LightAirResolution(
      SettingGetGlobal_i(G, cSetting_metal_light_air_resolution),
      kSceneLightsMobile);
  const int filter = pymol::LightAirShadowFilter(
      SettingGetGlobal_i(G, cSetting_metal_light_air_shadow_filter),
      kSceneLightsMobile);
  return pymol::LightAirPack(
      *frame.airSource, pymol::LightAirClock(in), resolution, filter);
}

bool SceneLightsAirAnimating(PyMOLGlobals* G)
{
  const pymol::LightRig* rig = SceneGetLightRig(G);
  if (!pymol::LightRigIsOn(rig) || !(rig->air.dust > 0.0) ||
      !(rig->air.dustSpeed > 0.0))
    return false;
  const double pinned = SettingGetGlobal_f(G, cSetting_metal_light_air_time);
  if (pinned >= 0.0)
    return false;
  const bool grid = G->Scene->grid.active;
  if (grid)
    return false;
  const bool playing = MoviePlaying(G) != 0;
  if (playing)
    return false;
  float mn[3], mx[3];
  const bool geometry = SceneGetLightShadowExtent(G, mn, mx);
  return pymol::LightAirAnimating(rig->air, pinned, playing, geometry, grid);
}

/* ---- Studio shadow casters (#616) ---------------------------------------- */

bool SceneObjectIsOverlay(const pymol::CObject* obj)
{
  if (!obj)
    return false;
  return obj->type == cObjectGadget || obj->type == cObjectGizmo ||
         std::strcmp(obj->Name, kSceneMoveGizmoName) == 0;
}

std::vector<pymol::CObject*> SceneLightShadowOverlays(PyMOLGlobals* G)
{
  std::vector<pymol::CObject*> out;
  for (auto* obj : G->Scene->Obj) {
    if (SceneObjectIsOverlay(obj))
      out.push_back(obj);
  }
  return out;
}

void SceneLightShadowCasterNames(PyMOLGlobals* G,
    std::vector<std::string>& casters, std::vector<std::string>& excluded)
{
  for (auto* obj : G->Scene->Obj) {
    (SceneObjectIsOverlay(obj) ? excluded : casters).emplace_back(obj->Name);
  }
}
