/*
 * HDR colour for the light rig (#624): the pure maths. See LightTone.h.
 * Pure functions over plain data: no PyMOLGlobals, no Python.
 */

#include "LightTone.h"

#include <algorithm>
#include <cmath>

namespace pymol
{

namespace
{
/// The NaN rule: non-finite and negative read as 0.
float LightToneClean(float x)
{
  return std::isfinite(x) && x > 0.0f ? x : 0.0f;
}

/// The NaN rule for a colour: any non-finite channel makes it black;
/// negative channels read as 0.
std::array<float, 3> LightToneClean(std::array<float, 3> c)
{
  if (!(std::isfinite(c[0]) && std::isfinite(c[1]) && std::isfinite(c[2])))
    return {0.0f, 0.0f, 0.0f};
  return {std::max(c[0], 0.0f), std::max(c[1], 0.0f), std::max(c[2], 0.0f)};
}

/// c * y / m, channel by channel (the largest channel then gets exactly y).
std::array<float, 3> LightToneRescale(
    const std::array<float, 3>& c, float y, float m)
{
  return {c[0] * y / m, c[1] * y / m, c[2] * y / m};
}
} // namespace

float LightToneScalar(float m)
{
  m = LightToneClean(m);
  if (m <= kLightToneKnee)
    return m;
  if (m >= kLightToneWhite)
    return 1.0f;
  const float s = 1.0f - kLightToneKnee;
  const float w = (kLightToneWhite - kLightToneKnee) / s;
  const float t = (m - kLightToneKnee) / s;
  return kLightToneKnee + s * t * (1.0f + t / (w * w)) / (1.0f + t);
}

float LightToneScalarInverse(float y)
{
  y = LightToneClean(y);
  if (y <= kLightToneKnee)
    return y;
  if (y >= 1.0f)
    return kLightToneWhite;
  const float s = 1.0f - kLightToneKnee;
  const float w = (kLightToneWhite - kLightToneKnee) / s;
  const float u = (y - kLightToneKnee) / s;
  const float t =
      2.0f * u / ((1.0f - u) + std::sqrt((1.0f - u) * (1.0f - u) + 4.0f * u / (w * w)));
  return kLightToneKnee + s * t;
}

std::array<float, 3> LightTone(std::array<float, 3> c)
{
  c = LightToneClean(c);
  const float m = std::max({c[0], c[1], c[2]});
  if (m <= kLightToneKnee)
    return c; // exactly the identity below the knee
  return LightToneRescale(c, LightToneScalar(m), m);
}

std::array<float, 3> LightToneInverse(std::array<float, 3> c)
{
  c = LightToneClean(c);
  c = {std::min(c[0], 1.0f), std::min(c[1], 1.0f), std::min(c[2], 1.0f)};
  const float m = std::max({c[0], c[1], c[2]});
  if (m <= kLightToneKnee)
    return c;
  return LightToneRescale(c, LightToneScalarInverse(m), m);
}

float LightToneExposure(float exposure)
{
  if (!std::isfinite(exposure))
    return 1.0f;
  return std::clamp(exposure, 0.0f, kLightToneMaxExposure);
}

bool LightHdrOn(int setting, bool mobile)
{
  (void) mobile; // on for both platforms; iOS provisional until #623
  if (setting == kLightHdrOn)
    return true;
  if (setting == kLightHdrOff)
    return false;
  return true;
}

} // namespace pymol
