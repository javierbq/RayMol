/*
 * Screen-space atom picking for the Metal backend.
 *
 * GL color-picking (SceneDoXYPick) is unavailable on Metal, so the pick is
 * reproduced by projecting the drawn atoms with the current camera and taking
 * the front-most one under the cursor. This is the hot inner loop of that:
 * `pymol.metal_pick` stays the policy layer (camera parsing, grid-cell mapping,
 * selection-mode expansion, readout payload) and calls in here through
 * `_cmd.metal_pick` for the per-atom work.
 *
 * The projection must agree with what the renderer drew, so it mirrors
 * CoordSetGetAtomTxfVertex (state matrix + object TTT) rather than reading raw
 * coordinates.
 */

#pragma once

#include <vector>

#include "PyMOLGlobals.h"

struct ObjectMolecule;

/**
 * Camera parameters of the projection, as parsed from cmd.get_view() by
 * pymol.metal_pick.camera(). See that docstring for the derivation; the
 * mapping applied here is
 *
 *     eye   = rot * (model - origin) + pos
 *     depth = -eye.z
 *     ndc   = (eye.x / (depth * tan_half * aspect), eye.y / (depth * tan_half))
 */
struct MetalPickCamera {
  float rot[9] = {};    ///< row-major 3x3 model->camera rotation
  float pos[3] = {};    ///< camera position (eye-space translation)
  float origin[3] = {}; ///< rotation origin, in model space
  float tan_half = 0.f; ///< half-height slope at unit depth
  float aspect = 1.f;   ///< width / height of the viewport (or grid cell)
  float clip_front = 0.f;
  float clip_back = 0.f; ///< clip_back <= clip_front disables slab culling
};

/**
 * Outcome of a pick. `obj == nullptr` means the cursor was over empty space.
 */
struct MetalPickHit {
  ObjectMolecule* obj = nullptr;
  int atm = -1;      ///< atom index within `obj`
  float d2 = 0.f;    ///< squared NDC distance from the cursor
  float sx = 0.f;    ///< where the atom projected, in NDC
  float sy = 0.f;
  int ncand = 0;     ///< atoms that projected within the pick radius
};

/**
 * Front-most drawn atom under (ndc_x, ndc_y).
 *
 * @param objects candidate objects, in the order the caller wants ties broken
 * @param state 0-based state to project, or -2 for each object's current state
 * @param max_ndc2 squared NDC pick radius; atoms beyond it are not candidates
 * @param cluster_ndc2 atoms within this squared NDC distance of the closest
 * candidate count as overlapping under the cursor, and the front-most (least
 * depth) of them wins
 * @param rep_mask visRep bits whose geometry is drawn at the atom's own
 * position, so a pick may land on it
 * @param guide_rep_mask visRep bits (cartoon/ribbon) that are set on every atom
 * of an object but only draw through its guide atoms
 */
MetalPickHit MetalPickAtom(PyMOLGlobals* G,
    const std::vector<ObjectMolecule*>& objects, int state,
    const MetalPickCamera& cam, float ndc_x, float ndc_y, float max_ndc2,
    float cluster_ndc2, int rep_mask, int guide_rep_mask);
