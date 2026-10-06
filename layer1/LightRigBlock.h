/*
 * The light rig as the GPU reads it (#613, lighting epic #610).
 *
 * One frame's rig, resolved to eye space and packed into 672 bytes: #613's
 * 400 (the head and six lights), then #616's shadow maps. The Metal
 * renderer binds it at fragment buffer 9, and only while the rig is on. Its
 * layout mirrors the MSL structs LightRigLight, LightRigShadow and LightRigU in
 * kMaterialSrc (layerGraphics/metal/RendererMetal.mm, and the verbatim copies
 * in kRTSrc): change them together. The layout is APPEND-ONLY. #616 appended
 * its shadow data after the six lights.
 *
 * Plain data with no dependencies beyond the standard library. Renderer.h
 * includes this header, so it must stay safe for the GL and GLUT builds. The
 * packing lives in LightShading.h (LightRigPack).
 *
 * Offsets in floats (_cmd.get_light_frame returns the block as 168 floats):
 *   0..3                 head: count, shininess, orthographic 0|1, shadow maps
 *   4 + 16 i + 0..3      light i: eye-space position xyz, shadow slot or -1
 *   4 + 16 i + 4..7      unit beam axis xyz (light -> aim), cos(outer)
 *   4 + 16 i + 8..11     radiance rgb, cos(inner)
 *   4 + 16 i + 12..15    highlight, falloff, falloff reference (Å), outline 0|1
 *   100 + 20 s + 0..15   shadow map s (#616): eye space -> the light's clip
 *                        space (GL z), column-major
 *   100 + 20 s + 16..19  tan(half field of view), map size (texels per side),
 *                        normal offset (texels), depth bias (window z)
 *   160..163             shadow grid: tiles per side (1 = no grid), first grid
 *                        slot (0 = no grid), columns, rows
 *   164..167             this draw's shadow tile in slice uv: u0, v0, du, dv
 *                        (set per draw by the renderer; 0 here)
 *
 * With no studio shadow (LightShadowPlan, LightShadows.h, not run) every
 * shadow slot is -1, head.w is 0 and the tail from float 100 on is zero: the
 * first 400 bytes are #613's block bit for bit.
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

/// Shadow-map slots in the block (#616). LightShadows.h asserts this equals
/// kLightRigMaxShadowed.
inline constexpr int kLightRigBlockShadowSlots = 3;

/// One studio shadow map (#616). Mirrors MSL LightRigShadow.
struct LightRigBlockShadow {
  /// Camera eye space -> the light's clip space (GL z, -w..w), column-major.
  float viewProj[16];
  /// x tan(half field of view), y map size (texels per side), z normal offset
  /// (texels, times metal_shadow_bias), w depth bias (window z)
  float info[4];
};

/// The whole block. Mirrors MSL LightRigU.
struct LightRigBlock {
  /// x light count (1..6), y shininess, z 1 when this draw is orthographic
  /// (set per draw by the renderer; 0 here), w shadow maps this frame (#616)
  float head[4];
  /// Lights 0..count-1; unused slots are zero.
  LightRigBlockLight light[kLightRigBlockSlots];
  /// Shadow maps 0..head.w-1 (#616); unused slots are zero.
  LightRigBlockShadow shadow[kLightRigBlockShadowSlots];
  /// x tiles per side (1 = no grid), y first grid slot (0 = no grid),
  /// z columns, w rows (#616)
  float shadowGrid[4];
  /// This draw's shadow tile in slice uv: u0, v0, du, dv (#616; set per draw
  /// by the renderer, 0 here)
  float shadowTile[4];
};

static_assert(sizeof(LightRigBlockLight) == 64, "mirrors MSL LightRigLight");
static_assert(sizeof(LightRigBlockShadow) == 80, "mirrors MSL LightRigShadow");
static_assert(sizeof(LightRigBlock) == 672, "mirrors MSL LightRigU");
static_assert(offsetof(LightRigBlock, light) == 16, "head is one float4");
static_assert(offsetof(LightRigBlock, shadow) == 400,
    "#613's 400 bytes come first, unchanged");
static_assert(offsetof(LightRigBlock, shadowGrid) == 640, "after the maps");
static_assert(offsetof(LightRigBlock, shadowTile) == 656, "last float4");
static_assert(offsetof(LightRigBlockShadow, info) == 64, "float4x4 then float4");
static_assert(offsetof(LightRigBlockLight, axis) == 16, "float4 slots");
static_assert(offsetof(LightRigBlockLight, radiance) == 32, "float4 slots");
static_assert(offsetof(LightRigBlockLight, misc) == 48, "float4 slots");
static_assert(std::is_trivially_copyable<LightRigBlock>::value &&
                  std::is_standard_layout<LightRigBlock>::value,
    "copied to the GPU byte for byte");

} // namespace pymol
