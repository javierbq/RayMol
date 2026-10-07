/*
 * HDR colour for the light rig (#624, lighting epic #610): the tone curve,
 * its inverse, exposure and the metal_light_hdr switch, as pure functions.
 *
 * Like LightShading.h, LightShadows.h and LightAir.h: no PyMOLGlobals, no
 * Python, no file statics. CI tests them from Python through _cmd
 * (light_tone, light_tone_scalar, light_tone_exposure, light_hdr,
 * get_light_hdr); the scene glue is SceneLightsToneFill() (SceneLights.h).
 *
 * The curve T. While the rig is on with HDR, a rig fragment's light is kept
 * in scene units (above 1 where the rig is bright), multiplied by the
 * exposure and mapped once through T before the 8-bit store:
 *
 *   m = max(r, g, b); T(c) = c when m <= k, else c * T1(m) / m
 *
 * so the hue and the channel ratios are kept (the largest channel is mapped,
 * the others follow it). T1 is the identity up to the knee k, then an
 * extended-Reinhard shoulder that is C1 at the knee (slope 1), exactly 1 at
 * the white point W and 1 beyond. With s = 1 - k, w = (W - k) / s and
 * t = (m - k) / s:
 *
 *   T1(m) = k + s * t * (1 + t / w^2) / (1 + t)
 *
 * The inverse (the air adds light in scene units over a display colour) is
 * closed form, rationalised so it stays stable near the knee: with
 * u = (y - k) / s,
 *
 *   t = 2 u / ((1 - u) + sqrt((1 - u)^2 + 4 u / w^2)),  Tinv(y) = k + s t
 *
 * and Tinv(1) = W. NaN rule: a value (or a colour with any channel) that is
 * not finite reads as 0, and negatives read as 0, so T's output is always in
 * 0..1.
 *
 * The constants are named once here, and once in each MSL copy (kMaterialSrc
 * and kRTSrc, layerGraphics/metal/RendererMetal.mm); the MSL functions mirror
 * these operation for operation, in float. A source test pins them equal, and
 * scripts/lighting/check_hdr.py holds the python twin CI ties to this one.
 *
 * Nothing here runs unless the rig is on: with no rig, or a rig that is off,
 * SceneLightsFrame() never calls SceneLightsToneFill() and no setting is read.
 */

#pragma once

#include <array>

namespace pymol
{

/// T's knee k: the identity up to here.
inline constexpr float kLightToneKnee = 0.6f;
/// T's white point W: scene light this bright (largest channel) maps to 1.
inline constexpr float kLightToneWhite = 8.0f;
/// LightToneExposure clamps metal_exposure to 0..this.
inline constexpr float kLightToneMaxExposure = 16.0f;

/// metal_light_hdr values: 1 on, 2 off (the 8-bit soft knee); 0 and anything
/// else is the platform default (LightHdrOn).
inline constexpr int kLightHdrOn = 1;
inline constexpr int kLightHdrOff = 2;

/// T1(m): the identity to the knee, the shoulder to 1 at the white point,
/// 1 beyond. Non-finite and negative input reads as 0.
float LightToneScalar(float m);

/// T1's inverse on 0..1: the identity to the knee, W at 1 (and above 1).
/// Non-finite and negative input reads as 0.
float LightToneScalarInverse(float y);

/// T(c), hue-preserving on the largest channel. A colour with any non-finite
/// channel is black; negative channels read as 0. Each channel of the result
/// is in 0..1, and the largest is exactly 1 at or beyond W.
std::array<float, 3> LightTone(std::array<float, 3> c);

/// T's inverse on a display colour (channels clipped to 0..1 first; NaN rule
/// as LightTone).
std::array<float, 3> LightToneInverse(std::array<float, 3> c);

/// The exposure a rig frame applies in scene units: metal_exposure clamped to
/// 0..kLightToneMaxExposure; non-finite reads as 1.
float LightToneExposure(float exposure);

/**
 * metal_light_hdr: true for HDR (exposure and T), false for the 8-bit soft
 * knee as before #624. 1 on, 2 off; 0 and anything else is the platform
 * default: on for the desktop and on for `mobile` (the iOS value is
 * provisional until #623 measures it on devices).
 */
bool LightHdrOn(int setting, bool mobile);

} // namespace pymol
