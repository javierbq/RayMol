/*
 * What the renderer needs from the light rig each frame (#613, epic #610).
 *
 * Pure functions over plain data, like LightRig.h: no PyMOLGlobals, no Python,
 * no file statics. CI tests them from Python through _cmd.get_light_frame and
 * _cmd.light_warmth_rgb (no CI job builds catch2), and a future catch2 job
 * could call them directly. The scene glue is SceneLightsFrame()
 * (SceneLights.h).
 *
 * - LightWarmthRGB(): a light's warmth (kelvin) as an RGB multiplier.
 * - LightRigIsOn(): the one test of "the rig is on" (decision 15).
 * - LightRigClassic(): decision 15, applied to PyMOL's classic light terms.
 * - LightRigPack() / LightRigFrameBlock(): the rig packed for the GPU
 *   (LightRigBlock.h).
 *
 * With no rig, or a rig that is off, LightRigClassic() returns the settings
 * untouched and LightRigFrameBlock() returns nullopt without resolving
 * anything: the renderer then gets exactly what it got before #613.
 */

#pragma once

#include <optional>

#include <glm/mat4x4.hpp>
#include <glm/vec3.hpp>

#include "LightRig.h"
#include "LightRigBlock.h"

namespace pymol
{

static_assert(kLightRigMaxLights == kLightRigBlockSlots,
    "every light the rig can hold has a GPU slot");

/// The warmth field's range (spec §4.2) and its neutral value.
inline constexpr double kLightWarmthMin = 1500.0;
inline constexpr double kLightWarmthMax = 15000.0;
inline constexpr double kLightWarmthNeutral = 6500.0;

/**
 * A light's warmth as an RGB multiplier on its colour.
 *
 * The colour of a black body at `kelvin`: Krystek's (1985) rational fit of
 * the Planckian locus in CIE 1960 (u, v), valid over 1000-15000 K, to CIE 1931
 * xy, to XYZ (Y = 1), to linear sRGB (D65 primaries). Negative channels (deep
 * reds have no blue) are clamped to 0. The result is then white-balanced to
 * 6500 K, channel by channel, and divided by its largest channel.
 *
 * So 6500 K is exactly (1, 1, 1), the largest channel is always 1 (warmth
 * tints a light and never brightens it), red is 1 below 6500 K and blue above,
 * and red/blue falls steadily as kelvin rises. The fit is one smooth function
 * over the whole range, so a warmth slider never crosses a seam (the
 * prototype's piecewise fit jumped at 6600 K).
 *
 * `kelvin` is clamped to [kLightWarmthMin, kLightWarmthMax]; NaN is neutral.
 */
glm::dvec3 LightWarmthRGB(double kelvin);

/**
 * True when the rig is on: enabled with at least one light (decision 15).
 * Intensities do not count: a rig whose lights are all at 0 is on. The frame
 * clause is defensive (a validated rig with lights always has one).
 */
bool LightRigIsOn(const LightRig* rig);

/// PyMOL's classic light terms as the Metal renderer receives them.
struct LightClassicTerms {
  float ambient;
  float direct;
  float reflect;
  float specular; ///< the reflect light's adjusted specular
};

/**
 * Decision 15. When the rig is on, the rig's `ambient` replaces the ambient
 * setting and `direct`, `reflect` and `specular` are scaled by its `classic`
 * (float multiplication). Otherwise `settings` comes back as it is, with no
 * arithmetic. Nothing is written anywhere.
 */
LightClassicTerms LightRigClassic(
    const LightRig* rig, const LightClassicTerms& settings);

/**
 * Pack a resolved rig (`eye` = LightRigResolve(rig, ...)) for the GPU:
 * - head = (count, shininess, 0, 0), count = min(lights, 6);
 * - per light: pos = (position, -1), axis = (direction, cosOuter),
 *   radiance = (color * LightWarmthRGB(warmth) * intensity, cosInner)
 *   computed in double, misc = (highlight, falloff, falloff reference,
 *   outline 0|1);
 * - unused slots are zero.
 * The falloff reference is the aim distance. For a light aimed at its own
 * position (aim distance <= 1e-3 Å) it is the distance to the rig centre,
 * else the rig size, and never below 1e-3: such a light is never black.
 * The `shadow` flag has no effect yet: slot -1 and no shadow maps (#616).
 */
LightRigBlock LightRigPack(
    const LightRig& rig, const LightRigEye& eye, float shininess);

/**
 * This frame's block: nullopt, before anything is resolved, unless
 * LightRigIsOn(rig); otherwise LightRigPack(*rig, LightRigResolve(*rig,
 * worldToEye), shininess).
 */
std::optional<LightRigBlock> LightRigFrameBlock(
    const LightRig* rig, const glm::dmat4& worldToEye, float shininess);

} // namespace pymol
