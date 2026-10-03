/*
 * The scene's light rig (#611). See SceneLights.h.
 */

#include "SceneLights.h"

#include <algorithm>
#include <cmath>
#include <utility>

#include "Executive.h"
#include "PyMOLGlobals.h"
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
  // Solvent excluded, as for the shadow frustum: scattered waters would
  // inflate 1x. A solvent-only scene falls back to every enabled atom.
  for (const char* expr : {"(enabled and not solvent)", "(enabled)"}) {
    SelectorTmp tmp(G, expr);
    if (tmp.getAtomCount() > 0 &&
        ExecutiveGetExtent(G, tmp.getName(), mn, mx, /* transformed */ true,
            /* current state */ -2, /* weighted */ false)) {
      found = true;
      break;
    }
  }

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
