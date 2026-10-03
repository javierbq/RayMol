/*
 * The scene's light rig (#611). See SceneLights.h.
 */

#include "SceneLights.h"

#include <algorithm>
#include <cmath>
#include <utility>

#include "Executive.h"
#include "PyMOLGlobals.h"
#include "PyMOLObject.h"
#include "Scene.h"
#include "SceneDef.h"
#include "Selector.h"

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
