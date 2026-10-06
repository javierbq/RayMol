/*
 * The air (haze and dust, #618): the pure maths. See LightAir.h.
 * Pure functions over plain data: no PyMOLGlobals, no Python.
 */

#include "LightAir.h"

#include <algorithm>
#include <cmath>

#include <glm/geometric.hpp>

namespace pymol
{

bool LightAirActive(const LightAir& air)
{
  return air.haze > 0.0 || air.dust > 0.0;
}

LightAirSource LightAirSourceOf(const LightRig& rig, const glm::dmat4& worldToEye)
{
  LightAirSource out;
  out.air = rig.air;
  const glm::dvec3 centre = rig.centre.value_or(glm::dvec3(0.0));
  const double size = rig.size.value_or(1.0);
  out.centreEye = glm::vec3(worldToEye * glm::dvec4(centre, 1.0));
  // The matrix's largest column scale: 1 for a camera (rigid).
  const double scale = std::max({glm::length(glm::dvec3(worldToEye[0])),
      glm::length(glm::dvec3(worldToEye[1])),
      glm::length(glm::dvec3(worldToEye[2]))});
  out.sizeEye = float(size * scale);
  return out;
}

int LightAirResolution(int setting, bool mobile)
{
  if (setting == kLightAirFull || setting == kLightAirHalf)
    return setting;
  return mobile ? kLightAirHalf : kLightAirFull;
}

int LightAirShadowFilter(int setting, bool mobile)
{
  (void) mobile; // one tap on both platforms until L6 and #623 say otherwise
  if (setting == kLightAirOneTap || setting == kLightAirLookup)
    return setting;
  return kLightAirOneTap;
}

double LightAirClock(const LightAirClockInputs& in)
{
  if (in.pinned >= 0.0 && std::isfinite(in.pinned))
    return in.pinned;
  if (in.frames > 1 && (in.offscreen || in.playing)) {
    const double fps =
        in.fps > 0.0 && std::isfinite(in.fps) ? in.fps : kLightAirDefaultFps;
    return std::max(in.frame, 0) / fps;
  }
  if (in.offscreen)
    return 0.0;
  return std::isfinite(in.wallSeconds) ? in.wallSeconds : 0.0;
}

double LightAirTime(double clock, double speed)
{
  const double t = std::max(clock, 0.0) * std::max(speed, 0.0);
  if (!std::isfinite(t))
    return 0.0;
  return std::fmod(t, kLightAirTimeWrap);
}

float LightAirSeedOffset(int seed)
{
  const double v = double(std::max(seed, 0)) * 0.6180339887498949;
  return float((v - std::floor(v)) * 1000.0);
}

bool LightAirAnimating(const LightAir& air, double pinned, bool playing,
    bool geometry, bool grid)
{
  return air.dust > 0.0 && air.dustSpeed > 0.0 && !(pinned >= 0.0) &&
         !playing && !grid && geometry;
}

std::optional<LightAirBlock> LightAirPack(const LightAirSource& source,
    double clock, int resolution, int shadowFilter)
{
  const LightAir& air = source.air;
  if (!LightAirActive(air))
    return std::nullopt;
  const double s = source.sizeEye;
  const double zc = -double(source.centreEye.z);
  if (!(s > 1e-3) || !std::isfinite(s) || !std::isfinite(zc))
    return std::nullopt;
  const double nearZ = std::max(zc - kLightAirRangeSizes * s, kLightAirMinNear);
  const double farZ = zc + kLightAirRangeSizes * s;
  if (!(farZ > nearZ))
    return std::nullopt; // the rig is behind the camera
  const double cell = std::max(kLightAirCellSizes * s, kLightAirMinCell);

  LightAirBlock b{};
  b.medium[0] = float(std::clamp(air.haze, 0.0, 1.0) * kLightAirHazeDensity / s);
  b.medium[1] = float(kLightAirOccupancy * std::clamp(air.dust, 0.0, 1.0));
  b.medium[2] =
      float(std::clamp(air.scatter, -kLightAirMaxScatter, kLightAirMaxScatter));
  b.medium[3] = LightAirSeedOffset(air.seed);
  b.range[0] = float(nearZ);
  b.range[1] = float(farZ);
  b.range[2] = float(zc);
  b.range[3] = float(cell);
  b.motion[0] = float(LightAirTime(clock, air.dustSpeed));
  b.motion[1] = float(air.dustSize * kLightAirMoteCells * cell);
  b.motion[2] = float(kLightAirDefocus / s);
  b.motion[3] = float(shadowFilter == kLightAirLookup ? kLightAirLookup
                                                      : kLightAirOneTap);
  b.view[0] = resolution == kLightAirHalf ? 0.5f : 1.0f;
  return b;
}

} // namespace pymol
