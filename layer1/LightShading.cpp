/*
 * What the renderer needs from the light rig each frame (#613). See
 * LightShading.h. Pure functions over plain data: no PyMOLGlobals, no Python.
 */

#include "LightShading.h"

#include <algorithm>
#include <cmath>
#include <cstddef>

#include <glm/common.hpp>
#include <glm/geometric.hpp>

// LightWarmthRGB(6500) must be exactly (1, 1, 1): the colour at 6500 K is
// divided by the reference colour at 6500 K, so the two must round the same
// way. With fused multiply-adds (clang contracts a * b + c by default where
// the target has FMA) a constant-folded reference could round differently
// from a run-time value. With contraction off every step is one IEEE
// operation, which rounds the same at compile time and at run time.
#if defined(__clang__)
#pragma STDC FP_CONTRACT OFF
#endif

namespace pymol
{

namespace
{

/**
 * The colour of a black body at `t` kelvin, in linear sRGB, not normalised.
 * Krystek's (1985) rational fit of the Planckian locus in CIE 1960 (u, v)
 * (valid 1000-15000 K): one smooth function over the whole warmth range, with
 * no pieces and so no seams.
 */
glm::dvec3 planckLinearSRGB(double t)
{
  const double t2 = t * t;
  const double u = (0.860117757 + 1.54118254e-4 * t + 1.28641212e-7 * t2) /
                   (1.0 + 8.42420235e-4 * t + 7.08145163e-7 * t2);
  const double v = (0.317398726 + 4.22806245e-5 * t + 4.20481691e-8 * t2) /
                   (1.0 - 2.89741816e-5 * t + 1.61456053e-7 * t2);
  // CIE 1960 (u, v) -> CIE 1931 (x, y)
  const double d = 2.0 * u - 8.0 * v + 4.0;
  const double x = 3.0 * u / d;
  const double y = 2.0 * v / d;
  // xyY with Y = 1 -> XYZ
  const double X = x / y;
  const double Y = 1.0;
  const double Z = (1.0 - x - y) / y;
  // XYZ -> linear sRGB (sRGB primaries, D65 white)
  return glm::dvec3(3.2404542 * X - 1.5371385 * Y - 0.4985314 * Z,
      -0.9692660 * X + 1.8760108 * Y + 0.0415560 * Z,
      0.0556434 * X - 0.2040259 * Y + 1.0572252 * Z);
}

/// The falloff reference distance of light `e` (see LightRigPack).
float falloffReference(const LightRigEye& eye, const LightEye& e)
{
  constexpr float kMin = 1e-3f;
  float ref = e.aimDistance;
  if (!(ref > kMin)) // aimed at its own position
    ref = glm::length(eye.centre - e.position);
  if (!(ref > kMin)) // ... and sitting on the rig centre
    ref = eye.size;
  return std::max(ref, kMin);
}

} // namespace

glm::dvec3 LightWarmthRGB(double kelvin)
{
  if (std::isnan(kelvin))
    kelvin = kLightWarmthNeutral;
  kelvin = std::clamp(kelvin, kLightWarmthMin, kLightWarmthMax);

  // The reference goes through the same code at run time (the volatile stops
  // the compiler folding it), so 6500 K divides by itself: exactly 1.
  const volatile double neutral = kLightWarmthNeutral;
  const glm::dvec3 ref = planckLinearSRGB(neutral);

  glm::dvec3 c = planckLinearSRGB(kelvin) / ref;
  c = glm::max(c, glm::dvec3(0.0));
  const double top = std::max({c.r, c.g, c.b});
  return c / top; // top > 0: red leads below 6500 K, blue above
}

bool LightRigIsOn(const LightRig* rig)
{
  return rig && rig->enabled && !rig->lights.empty() &&
         rig->centre.has_value() && rig->size.has_value();
}

LightClassicTerms LightRigClassic(
    const LightRig* rig, const LightClassicTerms& settings)
{
  if (!LightRigIsOn(rig))
    return settings;
  const float classic = float(rig->classic);
  return {float(rig->ambient), settings.direct * classic,
      settings.reflect * classic, settings.specular * classic, classic};
}

LightRigBlock LightRigPack(
    const LightRig& rig, const LightRigEye& eye, float shininess)
{
  LightRigBlock block{}; // unused slots stay zero
  const std::size_t n = std::min({eye.lights.size(), rig.lights.size(),
      static_cast<std::size_t>(kLightRigBlockSlots)});
  block.head[0] = float(n);
  block.head[1] = shininess;
  block.head[2] = 0.0f; // orthographic: the renderer sets it per draw
  block.head[3] = 0.0f; // shadow maps this frame (#616)

  for (std::size_t i = 0; i < n; ++i) {
    const Light& light = rig.lights[i];
    const LightEye& e = eye.lights[i];
    LightRigBlockLight& out = block.light[i];
    const glm::dvec3 radiance =
        light.color * LightWarmthRGB(light.warmth) * light.intensity;

    out.pos[0] = e.position.x;
    out.pos[1] = e.position.y;
    out.pos[2] = e.position.z;
    out.pos[3] = -1.0f; // no shadow slot until #616

    out.axis[0] = e.direction.x;
    out.axis[1] = e.direction.y;
    out.axis[2] = e.direction.z;
    out.axis[3] = e.cosOuter;

    out.radiance[0] = float(radiance.r);
    out.radiance[1] = float(radiance.g);
    out.radiance[2] = float(radiance.b);
    out.radiance[3] = e.cosInner;

    out.misc[0] = float(light.highlight);
    out.misc[1] = float(light.falloff);
    out.misc[2] = falloffReference(eye, e);
    out.misc[3] = e.outline ? 1.0f : 0.0f;
  }
  return block;
}

std::optional<LightRigBlock> LightRigFrameBlock(
    const LightRig* rig, const glm::dmat4& worldToEye, float shininess)
{
  if (!LightRigIsOn(rig))
    return std::nullopt;
  return LightRigPack(*rig, LightRigResolve(*rig, worldToEye), shininess);
}

} // namespace pymol
