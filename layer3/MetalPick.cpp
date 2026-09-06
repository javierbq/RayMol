/*
 * Screen-space atom picking for the Metal backend -- see MetalPick.h.
 */

#include "MetalPick.h"

#include <algorithm>
#include <cfloat>

#include "AtomInfo.h"
#include "CoordSet.h"
#include "ObjectMolecule.h"
#include "Rep.h"
#include "Setting.h"
#include "Vector.h"

namespace
{

/// An atom that projected inside the pick radius.
struct PickCand {
  float d2;
  float depth;
  ObjectMolecule* obj;
  int atm;
  float sx, sy;
};

/**
 * True if `ai` has geometry a pick can land on.
 *
 * Cartoon and ribbon are special: showing them ORs their bit onto EVERY atom of
 * the object (side chains and solvent included), but the spline only runs
 * through the guide atoms, so only those are hittable. Mirrors the _DRAWN_REPS
 * selection in pymol/metal_pick.py.
 */
inline bool is_drawn(
    const AtomInfoType* ai, int rep_mask, int guide_rep_mask)
{
  if (ai->visRep & rep_mask)
    return true;
  return (ai->visRep & guide_rep_mask) && (ai->flags & cAtomFlag_guide);
}

} // namespace

MetalPickHit MetalPickAtom(PyMOLGlobals* G,
    const std::vector<ObjectMolecule*>& objects, int state,
    const MetalPickCamera& cam, float ndc_x, float ndc_y, float max_ndc2,
    float cluster_ndc2, int rep_mask, int guide_rep_mask)
{
  MetalPickHit hit;

  const float r00 = cam.rot[0], r01 = cam.rot[1], r02 = cam.rot[2];
  const float r10 = cam.rot[3], r11 = cam.rot[4], r12 = cam.rot[5];
  const float r20 = cam.rot[6], r21 = cam.rot[7], r22 = cam.rot[8];
  const float tx = cam.pos[0], ty = cam.pos[1], tz = cam.pos[2];
  const float ox = cam.origin[0], oy = cam.origin[1], oz = cam.origin[2];
  // A degenerate slab (front >= back) means the view layout didn't carry usable
  // clip planes; culling against it would make nothing pickable at all.
  const bool clipped = cam.clip_back > cam.clip_front;

  if (!(cam.tan_half > 0.f) || !(cam.aspect > 0.f))
    return hit;

  std::vector<PickCand> cands;
  float d2min = FLT_MAX;

  for (auto* obj : objects) {
    if (!obj)
      continue;
    const CoordSet* cs = obj->getCoordSet(state);
    if (!cs)
      continue;

    // Same transform CoordSetGetAtomTxfVertex applies, hoisted out of the loop:
    // the pick has to agree with where the renderer put the atom, and for a
    // moved object (non-identity TTT) that is nowhere near the raw coordinate.
    const double* mat = nullptr;
    if (!cs->Matrix.empty() && SettingGet<int>(*cs, cSetting_matrix_mode) > 0)
      mat = cs->Matrix.data();
    const bool use_ttt = obj->TTTFlag != 0;

    const AtomInfoType* atom_info = obj->AtomInfo.data();
    const int n_index = cs->getNIndex();

    for (int idx = 0; idx < n_index; ++idx) {
      const int atm = cs->IdxToAtm[idx];
      const AtomInfoType* ai = atom_info + atm;
      if (!is_drawn(ai, rep_mask, guide_rep_mask))
        continue;

      float v[3];
      copy3f(cs->coordPtr(idx), v);
      if (mat)
        transform44d3f(mat, v, v);
      if (use_ttt)
        transformTTT44f3f(obj->TTT, v, v);

      const float dx = v[0] - ox;
      const float dy = v[1] - oy;
      const float dz = v[2] - oz;

      // eye = R*(model-origin) + pos; the camera looks down -Z.
      const float depth = -(r20 * dx + r21 * dy + r22 * dz + tz);
      if (depth <= 0.01f)
        continue;
      // An atom clipped away isn't visible, so it must not be selectable.
      if (clipped && (depth < cam.clip_front || depth > cam.clip_back))
        continue;

      const float half_h = depth * cam.tan_half;
      const float sx = (r00 * dx + r01 * dy + r02 * dz + tx) /
                       (half_h * cam.aspect); // NDC x, +1 = right
      const float sy =
          (r10 * dx + r11 * dy + r12 * dz + ty) / half_h; // NDC y, +1 = up

      const float ex = sx - ndc_x;
      const float ey = sy - ndc_y;
      const float d2 = ex * ex + ey * ey;
      if (d2 > max_ndc2)
        continue;

      ++hit.ncand;
      if (d2 < d2min)
        d2min = d2;
      // Anything farther than this can't make the final cluster either, since
      // d2min only shrinks from here -- so it never needs to be remembered.
      if (d2 <= d2min + cluster_ndc2)
        cands.push_back({d2, depth, obj, atm, sx, sy});
    }
  }

  if (cands.empty())
    return hit;

  // Where atoms overlap on screen, select the one actually visible (closest to
  // the camera) rather than whichever projects marginally nearer the cursor.
  // Sorting by distance first makes the depth tie-break deterministic.
  std::stable_sort(cands.begin(), cands.end(),
      [](const PickCand& a, const PickCand& b) { return a.d2 < b.d2; });

  const float limit = d2min + cluster_ndc2;
  const PickCand* best = nullptr;
  for (const auto& c : cands) {
    if (c.d2 > limit)
      break; // sorted, so nothing after this qualifies either
    if (!best || c.depth < best->depth)
      best = &c;
  }

  hit.obj = best->obj;
  hit.atm = best->atm;
  hit.d2 = best->d2;
  hit.sx = best->sx;
  hit.sy = best->sy;
  return hit;
}
