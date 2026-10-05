/*
 * Per-light shadow maps (#616, lighting epic #610): the plan of one frame.
 *
 * Pure functions over plain data, like LightShading.h: no PyMOLGlobals, no
 * Python, no file statics. CI tests them from Python through _cmd
 * (get_light_frame, light_shadow_frustum, light_shadow_map_size,
 * light_shadow_tile); the scene glue is SceneLightsFrame() (SceneLights.h).
 *
 * - LightShadowMapSize(): the texels per side of each studio shadow map, from
 *   metal_light_shadow_size and the platform.
 * - LightShadowFrustum(): one shadowed light's perspective frustum, fitted to
 *   the casters' bounding sphere, with a conservative near plane.
 * - LightShadowTileRect(): one grid cell's tile in a map (grid mode).
 * - LightShadowPlan(): which lights get a map this frame, written into the
 *   packed block (LightRigBlock.h), and each map's matrices.
 *
 * Nothing here runs unless a studio shadow is on: with no rig, a rig that is
 * off, no shadowed light, or metal_shadows off, SceneLightsFrame() never calls
 * these and the block is #613's, bit for bit.
 */

#pragma once

#include <optional>

#include <glm/mat4x4.hpp>
#include <glm/vec3.hpp>

#include "LightRig.h"
#include "LightRigBlock.h"

namespace pymol
{

static_assert(kLightRigBlockShadowSlots == kLightRigMaxShadowed,
    "every light the rig may shadow has a map slot");

/// metal_light_shadow_size 0: the platform's map size (provisional until
/// #623 calibrates it on devices).
inline constexpr int kLightShadowSizeDesktop = 2048;
inline constexpr int kLightShadowSizeMobile = 1024;
/// The range a non-zero metal_light_shadow_size is clamped to.
inline constexpr int kLightShadowSizeMin = 256;
inline constexpr int kLightShadowSizeMaxDesktop = 4096;
inline constexpr int kLightShadowSizeMaxMobile = 2048;

/// The widest half field of view a map is given (degrees). A wider beam is
/// shadowed only inside this cone.
inline constexpr double kLightShadowMaxHalfFovDeg = 75.0;
/// Each candidate half angle is widened by this factor plus kLightShadowPadDeg,
/// so a caster on the cone's edge still lands inside the map.
inline constexpr double kLightShadowFovMargin = 1.05;
inline constexpr double kLightShadowPadDeg = 0.5;
/// The caster sphere's radius: the box half-diagonal times this factor, plus
/// kLightShadowCasterPad Å (molecule extents are atom centres; spheres and
/// surfaces reach past them).
inline constexpr double kLightShadowCasterMargin = 1.02;
inline constexpr double kLightShadowCasterPad = 3.0;
/// The near plane's floor (Å) and its least fraction of the far plane.
inline constexpr double kLightShadowMinNear = 0.05;
inline constexpr double kLightShadowMinNearOfFar = 1e-3;
/// The lookup's normal offset (texels, times metal_shadow_bias) and its depth
/// bias (window z). Tuned once on the L2 renders, then frozen.
inline constexpr float kLightShadowNormalOffsetTexels = 1.5f;
inline constexpr float kLightShadowDepthBias = 2e-4f;

/**
 * The texels per side of each studio shadow map. `setting` is
 * metal_light_shadow_size: 0 or negative gives the platform default
 * (kLightShadowSizeDesktop, or kLightShadowSizeMobile when `mobile`);
 * anything else is clamped to kLightShadowSizeMin..max (4096 desktop, 2048
 * mobile) and rounded down to a power of two.
 */
int LightShadowMapSize(int setting, bool mobile);

/// One shadowed light's map camera, in camera eye space.
struct LightShadowView {
  glm::mat4 view{1.0f}; ///< eye space -> the light's view (rigid)
  glm::mat4 proj{1.0f}; ///< the light's perspective, GL z (-w..w)
  float tanHalfFov = 0.0f;
  float nearZ = 0.0f;
  float farZ = 0.0f;
  bool beamFit = false; ///< true: fitted to the beam; false: to the casters
};

/**
 * The frustum of a light at `pos` with unit beam axis `axis` and cone
 * cos(outer) `cosOuter`, for casters inside the sphere (`centre`, `radius`).
 * Everything in camera eye space (Å).
 *
 * Two candidate cones, each covering every caster that can shadow a lit
 * point (a lit point is inside the beam, and so is the segment from the light
 * to it):
 * (a) the beam: axis `axis`, half angle acos(cosOuter) x 1.05 + 0.5°;
 * (b) the caster sphere, only when the light is outside it (dist > radius):
 *     axis towards the centre, half angle asin(radius / dist) x 1.05 + 0.5°.
 * The smaller half angle wins (compared before the cap), then it is capped at
 * 75°. A light inside the sphere takes (a).
 *
 * Along the chosen axis D: far = (dot(C - P, D) + R) x 1.02; near =
 * 0.98 x max(dot(C - P, D) - R, (dist - R) cos h) when dist > R (both are
 * lower bounds of the depth of (sphere ∩ cone)), else 0.01 R; then near is at
 * least 1e-3 far and 0.05 Å. nullopt when far <= near (the casters are behind
 * the light) or an input is not finite.
 *
 * view = lookAt(P, P + D, up) with up = +y unless |D.y| > 0.95 (then +x);
 * proj = perspective(2h, 1, near, far), GL z.
 *
 * Limits (documented): beams wider than ~142° are shadowed only inside the
 * 75° cone, and casters nearer a light than `near` (a light inside the
 * casters) cast nothing.
 */
std::optional<LightShadowView> LightShadowFrustum(glm::vec3 pos,
    glm::vec3 axis, float cosOuter, glm::vec3 centre, float radius);

/// One grid cell's tile in a map: texel rect (x, y from the top-left, side
/// `size`) and the same rect in uv (u0, v0, du, dv). size 0 and uv zero for a
/// cell outside the atlas.
struct LightShadowTile {
  int x = 0;
  int y = 0;
  int size = 0;
  float uv[4] = {0.0f, 0.0f, 0.0f, 0.0f};
};

/**
 * Cell `cell` (0-based: grid slot - first slot) of a `tiles` x `tiles` atlas
 * in a `mapSize`² map. The tile side is floor(mapSize / tiles); cell c sits
 * at column c % tiles, row c / tiles. Tiles are square, integer, never
 * overlap and lie inside the map; one tile is the whole map.
 */
LightShadowTile LightShadowTileRect(int cell, int tiles, int mapSize);

/// The grid _cmd.get_light_frame passes in place of the scene's (tests).
struct LightShadowGridOverride {
  bool active = false;
  int nCol = 1;
  int nRow = 1;
  int firstSlot = 1;
};

/// What LightShadowPlan needs besides the rig and its packed block.
struct LightShadowInputs {
  glm::vec3 casterCentreEye{0.0f}; ///< the casters' sphere, eye space
  float casterRadius = 0.0f;       ///< Å, margins included
  float biasScale = 1.0f;          ///< metal_shadow_bias
  int mapSize = kLightShadowSizeDesktop;
  int tiles = 1;     ///< max(columns, rows) in grid mode, else 1
  int firstSlot = 0; ///< the grid's first slot, 0 without grid
  int nCol = 1;
  int nRow = 1;
};

/// The maps of one frame: map s belongs to light light[s].
struct LightShadowFrame {
  int count = 0;
  int size = 0;
  int tiles = 1;
  int firstSlot = 0;
  int light[kLightRigBlockShadowSlots] = {-1, -1, -1};
  LightShadowView view[kLightRigBlockShadowSlots];
};

/**
 * Give the shadowed lights their maps (decision D2 of the #616 plan). The
 * first three lights of `block` (in rig order, packed from `rig`) whose
 * `shadow` is set and whose frustum exists get slots 0, 1, 2; intensity is
 * ignored, so a dark shadowed light keeps its slot. For each: pos.w = slot,
 * shadow[slot] = (proj x view, (tan h, mapSize, 1.5 x biasScale, 2e-4)).
 * Then head.w = the map count and shadowGrid = (tiles, firstSlot, nCol,
 * nRow). Positions, axes and cones are read back from the block: nothing is
 * resolved again. shadowTile is left to the renderer.
 *
 * nullopt, with the block untouched, when no light gets a map.
 */
std::optional<LightShadowFrame> LightShadowPlan(LightRigBlock& block,
    const LightRig& rig, const LightShadowInputs& inputs);

} // namespace pymol
