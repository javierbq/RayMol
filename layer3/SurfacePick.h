/*
 * Surface pick (#614): the world-space point and normal of the drawn geometry
 * under a screen point.
 *
 * The camera ray, clipped to the scene's slab, is intersected with what each
 * representation actually draws -- surface triangles, the cartoon's primitive
 * CGO, sphere and stick impostors -- under the clip rule of what the Metal
 * renderer turns each primitive into (layer0/PickMath.h). Each rep keeps a
 * lazily built acceleration grid (layer1/PickAccel.h).
 *
 * The pick only reads: it never draws and never changes anything a render
 * reads. With `update`, it first runs the same update phase the next frame
 * would (ExecutiveUpdateSceneMembers + SceneUpdate).
 *
 * Exposed as _cmd.surface_pick / _cmd.surface_pick_prepare, and through
 * pymol.metal_pick.surface_at / surface_warm.
 */
#pragma once

#include <cstddef>
#include <string>
#include <vector>

#include "PyMOLGlobals.h"
#include "Rep.h"

/// Representations the surface pick knows how to intersect.
constexpr int cSurfacePickRepMask =
    cRepCylBit | cRepSphereBit | cRepSurfaceBit | cRepCartoonBit;

struct SurfacePickRequest {
  //! Scene-viewport NDC, x and y in [-1, 1], +y up
  float ndc_x = 0.f;
  float ndc_y = 0.f;
  //! width / height of the viewport; <= 0 means the scene's own aspect
  float aspect = 0.f;
  //! visRep bits of the reps to intersect (masked to cSurfacePickRepMask)
  int rep_mask = cSurfacePickRepMask;
  //! object names to consider; nullptr means every enabled molecule whose
  //! name does not start with '_' (a listed '_' object is considered)
  const std::vector<std::string>* objects = nullptr;
  //! run the frame's update phase first (may build reps; may reach Python)
  bool update = false;
};

struct SurfacePickHit {
  bool hit = false;
  float point[3] = {0.f, 0.f, 0.f};  ///< world (model) space
  float normal[3] = {0.f, 0.f, 1.f}; ///< unit, facing the camera (see below)
  float depth = 0.f;  ///< eye-space distance along the view axis, in Angstrom
  //! dot(oriented normal, toward-camera direction) BEFORE the silhouette
  //! nudge; > 0 on every hit that is not grazing
  float facing = 0.f;
  std::string object;
  int state = -1; ///< 0-based object state
  int rep = -1;   ///< cRep_t of the rep that was hit
  //! the ray met the geometry from inside (the far wall of a clipped closed
  //! shape; on open two-sided geometry it only means "back face")
  bool inside = false;
  //! a flat interior cap at the clip plane (metal_interior_cap)
  bool cap = false;
};

/// A screen point mapped into the viewport (or grid cell) that draws it.
struct ScenePickCell {
  float ndc_x = 0.f;
  float ndc_y = 0.f;
  float aspect = 1.f;
  bool grid = false; ///< a grid cell (grid_mode); false = the whole viewport
  int slot = 0;      ///< 1-based grid slot when `grid`
};

/**
 * Map a viewport point to the grid cell that draws it. Read-only.
 * Without an active grid, this is the identity.
 */
ScenePickCell ScenePickGridCell(
    PyMOLGlobals* G, float ndc_x, float ndc_y, float aspect);

/**
 * The pick segment for a viewport point: world points `A` on the near clip
 * plane and `B` on the far one, built the way SceneProjectionMatrix builds
 * the frustum (perspective or orthoscopic). False when the camera has no
 * usable slab.
 */
bool ScenePickSegment(PyMOLGlobals* G, float ndc_x, float ndc_y, float aspect,
    float* A, float* B);

/// The front-most drawn surface point under the request's screen point.
SurfacePickHit ScenePickSurface(PyMOLGlobals* G, const SurfacePickRequest& req);

struct SurfacePickPrepareStats {
  int accels = 0;          ///< pick grids held by the considered reps
  std::size_t bytes = 0;   ///< heap bytes they hold
  int built = 0;           ///< how many of them this call had to build
};

/**
 * Build the pick grid of every drawn, pickable rep without picking, so the
 * first pick (or drag) does not pay for it. `build == false` only runs the
 * update (when `update`) and reports what is already cached.
 */
SurfacePickPrepareStats ScenePickSurfacePrepare(PyMOLGlobals* G, int rep_mask,
    const std::vector<std::string>* objects, bool update, bool build);
