/*
 * The air (haze and dust, #618, lighting epic #610) as the GPU reads it.
 *
 * One frame's air, resolved to eye space and packed into 80 bytes: five
 * float4s. The Metal renderer binds it to the air pass (kAirSrc in
 * layerGraphics/metal/RendererMetal.mm) only while the air is drawn. Its
 * layout mirrors the MSL struct LightAirU: change them together. It is a
 * block of its own, so LightRigBlock (#613, #616) and its MSL mirrors are
 * unchanged.
 *
 * Plain data with no dependencies beyond the standard library. Renderer.h
 * includes this header, so it must stay safe for the GL and GLUT builds. The
 * packing lives in LightAir.h (LightAirPack).
 *
 * Offsets in floats (_cmd.get_light_air_frame returns the block as 20
 * floats):
 *   0..3    medium: haze density (per Å), dust occupancy (0..0.35),
 *           scatter g (-0.9..0.9), seed offset (0..1000)
 *   4..7    range: near, far (eye depth, Å), focus (the rig centre's eye
 *           depth), dust cell (Å)
 *   8..11   motion: dust time (s, speed folded in), mote radius (Å),
 *           defocus gain (per Å), haze shadow filter (1 one tap, 2 #616's
 *           3x3 lookup)
 *   12..15  view: scale (1 full resolution, 0.5 half), orthographic 0|1
 *           (set by the renderer; 0 here), 0, 0
 *   16..19  proj: the renderer's projection terms A, B, X, Y (set by the
 *           renderer; 0 here)
 */

#pragma once

#include <cstddef>
#include <type_traits>

namespace pymol
{

/// The air of one frame. Mirrors MSL LightAirU.
struct LightAirBlock {
  /// x haze density per Å (haze x kLightAirHazeDensity / size), y dust
  /// occupancy (kLightAirOccupancy x dust), z scatter g, w seed offset
  float medium[4];
  /// x near, y far (eye depth, Å), z focus depth (the rig centre), w dust
  /// cell (Å)
  float range[4];
  /// x dust time (s), y mote radius (Å, before the per-mote factor),
  /// z defocus gain (per Å), w haze shadow filter (1 | 2)
  float motion[4];
  /// x resolution scale (1 | 0.5), y orthographic 0|1 (renderer), z, w 0
  float view[4];
  /// The renderer's projection terms A, B, X, Y (renderer; 0 here)
  float proj[4];
};

static_assert(sizeof(LightAirBlock) == 80, "mirrors MSL LightAirU");
static_assert(offsetof(LightAirBlock, medium) == 0, "float4 slots");
static_assert(offsetof(LightAirBlock, range) == 16, "float4 slots");
static_assert(offsetof(LightAirBlock, motion) == 32, "float4 slots");
static_assert(offsetof(LightAirBlock, view) == 48, "float4 slots");
static_assert(offsetof(LightAirBlock, proj) == 64, "last float4");
static_assert(std::is_trivially_copyable<LightAirBlock>::value &&
                  std::is_standard_layout<LightAirBlock>::value,
    "copied to the GPU byte for byte");

} // namespace pymol
