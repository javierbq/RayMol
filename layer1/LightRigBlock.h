/*
 * The light rig as the GPU reads it (#613, lighting epic #610).
 *
 * One frame's rig, resolved to eye space and packed into 400 bytes. The Metal
 * renderer binds it at fragment buffer 9, and only while the rig is on. Its
 * layout mirrors the MSL structs LightRigLight and LightRigU in kMaterialSrc
 * (layerGraphics/metal/RendererMetal.mm): change both together. The layout is
 * APPEND-ONLY. #616 appends its shadow data after the six lights.
 *
 * Plain data with no dependencies beyond the standard library. Renderer.h
 * includes this header, so it must stay safe for the GL and GLUT builds. The
 * packing lives in LightShading.h (LightRigPack).
 *
 * Offsets in floats (_cmd.get_light_frame returns the block as 100 floats):
 *   0..3                 head: count, shininess, orthographic 0|1, shadow maps
 *   4 + 16 i + 0..3      light i: eye-space position xyz, shadow slot (-1)
 *   4 + 16 i + 4..7      unit beam axis xyz (light -> aim), cos(outer)
 *   4 + 16 i + 8..11     radiance rgb, cos(inner)
 *   4 + 16 i + 12..15    highlight, falloff, falloff reference (Å), outline 0|1
 */

#pragma once

#include <cstddef>
#include <type_traits>

namespace pymol
{

/// Light slots in the block. LightShading.h asserts this equals
/// kLightRigMaxLights.
inline constexpr int kLightRigBlockSlots = 6;

/// One light as the GPU reads it. Mirrors MSL LightRigLight.
struct LightRigBlockLight {
  /// xyz eye-space position (Å); w the shadow slot, -1 = none (#616 fills it)
  float pos[4];
  /// xyz unit beam direction, from the light to its aim point; w cos(outer)
  float axis[4];
  /// rgb color * LightWarmthRGB(warmth) * intensity; w cos(inner)
  float radiance[4];
  /// x highlight, y falloff exponent, z falloff reference distance (Å,
  /// >= 1e-3), w outline 0|1
  float misc[4];
};

/// The whole block. Mirrors MSL LightRigU.
struct LightRigBlock {
  /// x light count (1..6), y shininess, z 1 when this draw is orthographic
  /// (set per draw by the renderer; 0 here), w shadow maps this frame (#616; 0)
  float head[4];
  /// Lights 0..count-1; unused slots are zero.
  LightRigBlockLight light[kLightRigBlockSlots];
};

static_assert(sizeof(LightRigBlockLight) == 64, "mirrors MSL LightRigLight");
static_assert(sizeof(LightRigBlock) == 400, "mirrors MSL LightRigU");
static_assert(offsetof(LightRigBlock, light) == 16, "head is one float4");
static_assert(offsetof(LightRigBlockLight, axis) == 16, "float4 slots");
static_assert(offsetof(LightRigBlockLight, radiance) == 32, "float4 slots");
static_assert(offsetof(LightRigBlockLight, misc) == 48, "float4 slots");
static_assert(std::is_trivially_copyable<LightRigBlock>::value &&
                  std::is_standard_layout<LightRigBlock>::value,
    "copied to the GPU byte for byte");

} // namespace pymol
