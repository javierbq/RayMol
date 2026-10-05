/*
 * Per-light shadow maps (#616): the plan of one frame. See LightShadows.h.
 * Pure functions over plain data: no PyMOLGlobals, no Python.
 */

#include "LightShadows.h"

#include <algorithm>
#include <cmath>
#include <cstring>

#include <glm/ext/matrix_clip_space.hpp>
#include <glm/ext/matrix_transform.hpp>
#include <glm/geometric.hpp>
#include <glm/gtc/type_ptr.hpp>
#include <glm/trigonometric.hpp>

namespace pymol
{

namespace
{

bool finite3(const glm::dvec3& v)
{
  return std::isfinite(v.x) && std::isfinite(v.y) && std::isfinite(v.z);
}

/// The largest power of two <= v (v >= 1).
int floorPow2(int v)
{
  int p = 1;
  while (p <= v / 2)
    p *= 2;
  return p;
}

} // namespace

int LightShadowMapSize(int setting, bool mobile)
{
  if (setting <= 0)
    return mobile ? kLightShadowSizeMobile : kLightShadowSizeDesktop;
  const int hi = mobile ? kLightShadowSizeMaxMobile : kLightShadowSizeMaxDesktop;
  return floorPow2(std::clamp(setting, kLightShadowSizeMin, hi));
}

std::optional<LightShadowView> LightShadowFrustum(glm::vec3 pos,
    glm::vec3 axis, float cosOuter, glm::vec3 centre, float radius)
{
  const glm::dvec3 P(pos);
  const glm::dvec3 C(centre);
  glm::dvec3 A(axis);
  const double R = radius;
  if (!finite3(P) || !finite3(C) || !finite3(A) || !std::isfinite(R) ||
      !std::isfinite(cosOuter) || R < 0.0)
    return std::nullopt;
  const double alen = glm::length(A);
  if (!(alen > 1e-12))
    return std::nullopt;
  A /= alen;

  const double pad = glm::radians(kLightShadowPadDeg);
  const double cap = glm::radians(kLightShadowMaxHalfFovDeg);
  const glm::dvec3 toC = C - P;
  const double dist = glm::length(toC);

  // (a) the beam
  const double beamHalf =
      std::acos(std::clamp(double(cosOuter), -1.0, 1.0));
  double h = beamHalf * kLightShadowFovMargin + pad;
  glm::dvec3 D = A;
  bool beamFit = true;
  // (b) the caster sphere, from outside it; compared before the cap
  if (dist > R) {
    const double sphereHalf =
        std::asin(std::clamp(R / dist, 0.0, 1.0)) * kLightShadowFovMargin + pad;
    if (sphereHalf < h) {
      h = sphereHalf;
      D = toC / dist;
      beamFit = false;
    }
  }
  h = std::min(h, cap);

  const double axial = glm::dot(toC, D);
  const double farZ = (axial + R) * 1.02;
  double nearZ = dist > R
                     ? 0.98 * std::max(axial - R, (dist - R) * std::cos(h))
                     : 0.01 * R;
  nearZ = std::max({nearZ, kLightShadowMinNearOfFar * farZ, kLightShadowMinNear});
  if (!(farZ > nearZ))
    return std::nullopt;

  const glm::dvec3 up = std::abs(D.y) > 0.95 ? glm::dvec3(1.0, 0.0, 0.0)
                                             : glm::dvec3(0.0, 1.0, 0.0);
  const glm::dmat4 view = glm::lookAtRH(P, P + D, up);
  const glm::dmat4 proj = glm::perspectiveRH_NO(2.0 * h, 1.0, nearZ, farZ);

  LightShadowView out;
  out.view = glm::mat4(view);
  out.proj = glm::mat4(proj);
  out.tanHalfFov = float(std::tan(h));
  out.nearZ = float(nearZ);
  out.farZ = float(farZ);
  out.beamFit = beamFit;
  return out;
}

LightShadowTile LightShadowTileRect(int cell, int tiles, int mapSize)
{
  LightShadowTile tile;
  tiles = std::max(tiles, 1);
  if (mapSize <= 0 || cell < 0 || cell >= tiles * tiles)
    return tile;
  const int side = mapSize / tiles;
  if (side <= 0)
    return tile;
  tile.x = (cell % tiles) * side;
  tile.y = (cell / tiles) * side;
  tile.size = side;
  const float s = float(mapSize);
  tile.uv[0] = float(tile.x) / s;
  tile.uv[1] = float(tile.y) / s;
  tile.uv[2] = float(side) / s;
  tile.uv[3] = float(side) / s;
  return tile;
}

std::optional<LightShadowFrame> LightShadowPlan(LightRigBlock& block,
    const LightRig& rig, const LightShadowInputs& inputs)
{
  LightShadowFrame frame;
  frame.size = inputs.mapSize;
  frame.tiles = std::max(inputs.tiles, 1);
  frame.firstSlot = inputs.firstSlot;

  const int count = std::min({int(block.head[0]), int(rig.lights.size()),
      kLightRigBlockSlots});
  for (int i = 0; i < count && frame.count < kLightRigBlockShadowSlots; ++i) {
    if (!rig.lights[size_t(i)].shadow)
      continue; // intensity is never looked at
    const LightRigBlockLight& l = block.light[i];
    auto view = LightShadowFrustum(glm::vec3(l.pos[0], l.pos[1], l.pos[2]),
        glm::vec3(l.axis[0], l.axis[1], l.axis[2]), l.axis[3],
        inputs.casterCentreEye, inputs.casterRadius);
    if (!view)
      continue; // casters behind the light: nothing it lights is shadowed
    frame.light[frame.count] = i;
    frame.view[frame.count] = *view;
    ++frame.count;
  }
  if (frame.count == 0)
    return std::nullopt;

  for (int s = 0; s < frame.count; ++s) {
    const LightShadowView& v = frame.view[s];
    block.light[frame.light[s]].pos[3] = float(s);
    LightRigBlockShadow& out = block.shadow[s];
    const glm::mat4 viewProj = v.proj * v.view;
    std::memcpy(out.viewProj, glm::value_ptr(viewProj), sizeof out.viewProj);
    out.info[0] = v.tanHalfFov;
    out.info[1] = float(inputs.mapSize);
    out.info[2] = kLightShadowNormalOffsetTexels * inputs.biasScale;
    out.info[3] = kLightShadowDepthBias;
  }
  block.head[3] = float(frame.count);
  block.shadowGrid[0] = float(frame.tiles);
  block.shadowGrid[1] = float(inputs.firstSlot);
  block.shadowGrid[2] = float(inputs.nCol);
  block.shadowGrid[3] = float(inputs.nRow);
  return frame;
}

} // namespace pymol
