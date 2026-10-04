/*
 * Surface pick (#614) -- see SurfacePick.h.
 */

#include "SurfacePick.h"

#include <algorithm>
#include <cmath>

#include "Base.h"
#include "CoordSet.h"
#include "Executive.h"
#include "ObjectMolecule.h"
#include "PickAccel.h"
#include "PickMath.h"
#include "PyMOLObject.h"
#include "Rep.h"
#include "Scene.h"
#include "SceneDef.h"
#include "Setting.h"
#include "Vector.h"

#include <glm/gtc/type_ptr.hpp>

namespace
{

/// Row-major 3x4 affine map: p' = L p + t, with L = m[0..2], m[4..6],
/// m[8..10] and t = (m[3], m[7], m[11]) -- the upper rows of PyMOL's
/// row-major 4x4 convention (transform44d3f, convertTTTfR44f).
struct Affine {
  double m[12] = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0};
};

Affine affineFrom44f(const float* h)
{
  Affine a;
  std::copy_n(h, 12, a.m);
  return a;
}

Affine affineFrom44d(const double* h)
{
  Affine a;
  std::copy_n(h, 12, a.m);
  return a;
}

/// (x ∘ y)(p) = x(y(p))
Affine affineMul(const Affine& x, const Affine& y)
{
  Affine r;
  for (int i = 0; i < 3; ++i) {
    for (int j = 0; j < 4; ++j) {
      double v = x.m[4 * i + 0] * y.m[0 + j] + x.m[4 * i + 1] * y.m[4 + j] +
                 x.m[4 * i + 2] * y.m[8 + j];
      if (j == 3)
        v += x.m[4 * i + 3];
      r.m[4 * i + j] = v;
    }
  }
  return r;
}

bool affineInvert(const Affine& a, Affine& inv)
{
  const double* m = a.m;
  const double c00 = m[5] * m[10] - m[6] * m[9];
  const double c01 = m[6] * m[8] - m[4] * m[10];
  const double c02 = m[4] * m[9] - m[5] * m[8];
  const double det = m[0] * c00 + m[1] * c01 + m[2] * c02;
  if (!(std::fabs(det) > 1e-12) || !std::isfinite(det))
    return false;
  const double id = 1.0 / det;
  double L[9];
  L[0] = c00 * id;
  L[1] = (m[2] * m[9] - m[1] * m[10]) * id;
  L[2] = (m[1] * m[6] - m[2] * m[5]) * id;
  L[3] = c01 * id;
  L[4] = (m[0] * m[10] - m[2] * m[8]) * id;
  L[5] = (m[2] * m[4] - m[0] * m[6]) * id;
  L[6] = c02 * id;
  L[7] = (m[1] * m[8] - m[0] * m[9]) * id;
  L[8] = (m[0] * m[5] - m[1] * m[4]) * id;
  const double t[3] = {m[3], m[7], m[11]};
  for (int i = 0; i < 3; ++i) {
    inv.m[4 * i + 0] = L[3 * i + 0];
    inv.m[4 * i + 1] = L[3 * i + 1];
    inv.m[4 * i + 2] = L[3 * i + 2];
    inv.m[4 * i + 3] =
        -(L[3 * i + 0] * t[0] + L[3 * i + 1] * t[1] + L[3 * i + 2] * t[2]);
  }
  return true;
}

void affineApply(const Affine& a, const float* p, double* out)
{
  for (int i = 0; i < 3; ++i)
    out[i] = a.m[4 * i] * p[0] + a.m[4 * i + 1] * p[1] +
             a.m[4 * i + 2] * p[2] + a.m[4 * i + 3];
}

/// The scene camera as SceneComposeModelViewMatrix composes it:
/// eye = R (world - origin) + pos, R row-major.
struct PickCamera {
  double R[9];
  double pos[3];
  double origin[3];
  float front, back;
};

PickCamera pickCamera(PyMOLGlobals* G)
{
  CScene* I = G->Scene;
  PickCamera cam;
  // glm is column-major: element (row i, col j) is value_ptr[4 j + i].
  const float* r = glm::value_ptr(I->m_view.rotMatrix());
  for (int i = 0; i < 3; ++i)
    for (int j = 0; j < 3; ++j)
      cam.R[3 * i + j] = r[4 * j + i];
  const auto& pos = I->m_view.pos();
  const auto& ori = I->m_view.origin();
  cam.pos[0] = pos.x;
  cam.pos[1] = pos.y;
  cam.pos[2] = pos.z;
  cam.origin[0] = ori.x;
  cam.origin[1] = ori.y;
  cam.origin[2] = ori.z;
  cam.front = I->m_view.m_clipSafe().m_front;
  cam.back = I->m_view.m_clipSafe().m_back;
  return cam;
}

/// world -> eye as an affine map.
Affine worldToEye(const PickCamera& cam)
{
  Affine a;
  for (int i = 0; i < 3; ++i) {
    a.m[4 * i + 0] = cam.R[3 * i + 0];
    a.m[4 * i + 1] = cam.R[3 * i + 1];
    a.m[4 * i + 2] = cam.R[3 * i + 2];
    a.m[4 * i + 3] = cam.pos[i] - (cam.R[3 * i + 0] * cam.origin[0] +
                                      cam.R[3 * i + 1] * cam.origin[1] +
                                      cam.R[3 * i + 2] * cam.origin[2]);
  }
  return a;
}

void eyeToWorld(const PickCamera& cam, const double* e, float* w)
{
  const double q[3] = {e[0] - cam.pos[0], e[1] - cam.pos[1], e[2] - cam.pos[2]};
  for (int j = 0; j < 3; ++j)
    w[j] = float(cam.R[0 + j] * q[0] + cam.R[3 + j] * q[1] +
                 cam.R[6 + j] * q[2] + cam.origin[j]);
}

bool objectWanted(const char* name, const std::vector<std::string>* objects)
{
  if (objects)
    return std::find(objects->begin(), objects->end(), name) != objects->end();
  return name[0] != '_';
}

/// Draw order does not matter (the nearest hit wins); this is just the set.
const cRep_t kPickReps[] = {cRepSurface, cRepCartoon, cRepSphere, cRepCyl};

/**
 * The object-to-world transform the renderer applies to a coordinate set:
 * the object's TTT after the state matrix (ObjectPrepareContext, then
 * ObjectStatePushAndApplyMatrix when the object-level matrix_mode > 0, as in
 * ObjectMolecule::render).
 *
 * Known gap, kept on purpose: the Metal renderer does not draw the state
 * matrix yet. ObjectStatePushAndApplyMatrix multiplies it into the scene
 * modelview but never loads it into G->Renderer (ObjectPrepareContext's TTT
 * branch does), and Metal draws read the renderer's cached modelview. So for
 * an object with matrix_mode > 0 and a stored state matrix, the app draws it
 * without that matrix while this pick (like GL and the ray tracer) places it
 * with it. The fix belongs in ObjectStatePushAndApplyMatrix, not here.
 */
Affine coordSetToWorld(const ObjectMolecule* obj,
    const CoordSet* cs, bool use_matrices)
{
  Affine M;
  if (obj->TTTFlag) {
    float h[16];
    convertTTTfR44f(obj->TTT, h);
    M = affineFrom44f(h);
  }
  if (use_matrices && !cs->Matrix.empty())
    M = affineMul(M, affineFrom44d(cs->Matrix.data()));
  return M;
}

/**
 * Calls `fn(obj, cs, state)` for every coordinate set the scene draws of
 * every considered molecule, as SceneRenderAllObject + ObjectMolecule::render
 * pick them: in `cell`'s slot, or (`all_slots`) in any slot of its grid.
 * Each coordinate set is visited once.
 */
template <typename Fn>
void forEachDrawnCoordSet(PyMOLGlobals* G,
    const std::vector<std::string>* objects, const ScenePickCell& cell,
    bool all_slots, Fn&& fn)
{
  const int first = !cell.grid ? 0 : all_slots ? 1 : cell.slot;
  const int last = !cell.grid ? 0 : all_slots ? cell.size : cell.slot;
  std::vector<int> csets;
  for (pymol::CObject* obj : G->Scene->Obj) {
    if (obj->type != cObjectMolecule)
      continue;
    if (!objectWanted(obj->Name, objects))
      continue;
    auto* om = static_cast<ObjectMolecule*>(obj);
    csets.clear();
    for (int slot = first; slot <= last; ++slot) {
      int state;
      if (!ScenePickCellState(G, cell, slot, obj, &state))
        continue;
      for (StateIterator iter(G, obj->Setting.get(), state, om->NCSet);
           iter.next();)
        csets.push_back(iter.state);
    }
    // Several slots can draw the same coordinate set (ByObjectStates with a
    // static singleton draws state 1 in every cell).
    std::sort(csets.begin(), csets.end());
    csets.erase(std::unique(csets.begin(), csets.end()), csets.end());
    for (int state : csets) {
      CoordSet* cs = om->CSet[state];
      if (cs)
        fn(om, cs, state);
    }
  }
}

/**
 * The grid layout of the next frame, built as SceneRenderMetal builds it
 * (SceneGetGridSize, then GridUpdate) but into `cell` alone. SceneGetGridSize
 * itself writes the scene's m_slots and, in ByObjectByState, every object's
 * grid_slot, so it must not be called from a pick; this is its read-only
 * replica (keep the two in step).
 */
void pickGridLayout(PyMOLGlobals* G, float aspect, ScenePickCell& cell)
{
  const CScene* I = G->Scene;
  const auto mode = SettingGet<GridMode>(G, cSetting_grid_mode);
  if (mode == GridMode::NoGrid)
    return;

  int size = 0;
  switch (mode) {
  case GridMode::ByObject: {
    // m_slots: every positive grid_slot in use, renumbered 1..n in order.
    int max_slot = 0;
    for (const pymol::CObject* obj : I->Obj)
      max_slot = std::max(max_slot, obj->grid_slot);
    cell.slot_table.assign(max_slot + 1, 0);
    for (const pymol::CObject* obj : I->Obj)
      if (obj->grid_slot > 0)
        cell.slot_table[obj->grid_slot] = 1;
    for (int& s : cell.slot_table)
      if (s)
        s = ++size;
    break;
  }
  case GridMode::ByObjectStates:
  case GridMode::ByObjectByState: {
    int max_slot = 0;
    for (const pymol::CObject* obj : I->Obj) {
      const int nframe = obj->getNFrame();
      if (mode == GridMode::ByObjectByState) {
        cell.state_offsets[obj] = max_slot; // what grid_slot would hold
        max_slot += nframe;
      } else if (max_slot < nframe) {
        max_slot = nframe;
      }
    }
    size = max_slot;
    break;
  }
  default:
    break; // ByCamera: SceneGetGridSize sizes no grid for it
  }
  const auto grid_max = SettingGet<int>(G, cSetting_grid_max);
  if (grid_max >= 0)
    size = std::min(size, grid_max);

  // GridUpdate is pure on its argument: run it on a local GridInfo.
  GridInfo grid{};
  GridUpdate(&grid, aspect, mode, size);
  if (!grid.active)
    return;
  cell.grid = true;
  cell.mode = mode;
  cell.size = grid.last_slot;
  cell.n_col = grid.n_col;
  cell.n_row = grid.n_row;
}

} // namespace

ScenePickCell ScenePickGridCell(
    PyMOLGlobals* G, float ndc_x, float ndc_y, float aspect)
{
  ScenePickCell cell;
  cell.ndc_x = ndc_x;
  cell.ndc_y = ndc_y;
  cell.aspect = aspect;
  pickGridLayout(G, aspect, cell);
  if (!cell.grid)
    return cell;

  // Every cell shares the frame's camera and projection; only the viewport
  // moves (SceneSetMetalGridCell: columns left to right, row 0 at the top),
  // and the projection's aspect is the cell's (aspRat *= grid.asp_adjust).
  if (!(std::fabs(ndc_x) <= 1.f) || !(std::fabs(ndc_y) <= 1.f)) {
    cell.valid = false;
    return cell;
  }
  const double u = (double(ndc_x) + 1.0) / 2.0 * cell.n_col;
  const double t = (1.0 - double(ndc_y)) / 2.0 * cell.n_row;
  const int col = std::min(int(std::floor(u)), cell.n_col - 1);
  const int row = std::min(int(std::floor(t)), cell.n_row - 1);
  cell.slot = 1 + row * cell.n_col + col;
  cell.valid = cell.slot <= cell.size;
  cell.ndc_x = float((u - col) * 2.0 - 1.0);
  cell.ndc_y = float(1.0 - (t - row) * 2.0);
  cell.aspect = float(aspect * (float(cell.n_row) / cell.n_col));
  return cell;
}

bool ScenePickCellState(PyMOLGlobals* G, const ScenePickCell& cell, int slot,
    const pymol::CObject* obj, int* state)
{
  if (!cell.grid) {
    *state = ObjectGetCurrentState(obj, false);
    return true;
  }
  if (slot < 1 || slot > cell.size)
    return false;
  switch (cell.mode) {
  case GridMode::ByObject: {
    // SceneGetDrawFlag with grid->slot = slot (Metal draws slots 1..size,
    // never the whole-window slot 0, so grid_slot 0 is never drawn).
    const int gs = obj->grid_slot;
    const bool drawn = gs < 0 ||
                       (gs > 0 && gs < int(cell.slot_table.size()) &&
                           cell.slot_table[gs] == slot);
    if (!drawn)
      return false;
    *state = ObjectGetCurrentState(obj, false);
    return true;
  }
  case GridMode::ByObjectStates:
    *state = SceneGetState(G) + slot - 1;
    return *state >= 0;
  case GridMode::ByObjectByState: {
    const auto it = cell.state_offsets.find(obj);
    if (it == cell.state_offsets.end())
      return false;
    *state = slot - it->second - 1;
    return *state >= 0 && *state < obj->getNFrame();
  }
  default:
    return false;
  }
}

bool ScenePickSegment(PyMOLGlobals* G, float ndc_x, float ndc_y, float aspect,
    float* A, float* B)
{
  const PickCamera cam = pickCamera(G);
  if (!(cam.back > cam.front) || !(cam.front > 0.f) || !(aspect > 0.f))
    return false;
  const double fovw = GetFovWidth(G);
  double ae[3], be[3];
  if (!SettingGet<bool>(G, cSetting_ortho)) {
    // glm::perspective(GetFovWidth, ...) takes tan(fovy / 2) of its argument.
    const double t = std::tan(fovw / 2.0);
    const double e[3] = {ndc_x * t * aspect, ndc_y * t, -1.0};
    for (int k = 0; k < 3; ++k) {
      ae[k] = e[k] * cam.front;
      be[k] = e[k] * cam.back;
    }
  } else {
    // glm::ortho(±h·aspect, ±h, front, back), h as SceneProjectionMatrix.
    const double h = std::max<double>(R_SMALL4, -cam.pos[2]) * fovw / 2.0;
    ae[0] = be[0] = ndc_x * h * aspect;
    ae[1] = be[1] = ndc_y * h;
    ae[2] = -cam.front;
    be[2] = -cam.back;
  }
  eyeToWorld(cam, ae, A);
  eyeToWorld(cam, be, B);
  return true;
}

SurfacePickHit ScenePickSurface(PyMOLGlobals* G, const SurfacePickRequest& req)
{
  SurfacePickHit out;
  if (req.update) {
    // The frame's own update phase (SceneRenderMetal), so the next frame
    // finds nothing new to do and draws the same pixels.
    ExecutiveUpdateSceneMembers(G);
    SceneUpdate(G, false);
  }

  const float aspect =
      req.aspect > 0.f ? req.aspect : SceneGetAspectRatio(G);
  if (!std::isfinite(aspect) || !(aspect > 0.f) ||
      !std::isfinite(req.ndc_x) || !std::isfinite(req.ndc_y))
    return out;

  const ScenePickCell cell = ScenePickGridCell(G, req.ndc_x, req.ndc_y, aspect);
  if (!cell.valid)
    return out;
  float A[3], B[3];
  if (!ScenePickSegment(G, cell.ndc_x, cell.ndc_y, cell.aspect, A, B))
    return out;

  const PickCamera cam = pickCamera(G);
  const Affine w2e = worldToEye(cam);
  const int mask = req.rep_mask & cSurfacePickRepMask;

  bool found = false;
  PickRayHit best;
  Affine bestInv;
  ObjectMolecule* bestObj = nullptr;
  int bestState = -1;
  cRep_t bestRep = cRepNone;

  forEachDrawnCoordSet(G, req.objects, cell, false,
      [&](ObjectMolecule* obj, CoordSet* cs, int state) {
        int use_matrices = SettingGet_i(
            G, obj->Setting.get(), nullptr, cSetting_matrix_mode);
        const Affine M = coordSetToWorld(obj, cs, use_matrices > 0);
        Affine Minv;
        if (!affineInvert(M, Minv))
          return;

        RepPickArgs args;
        double la[3], lb[3];
        affineApply(Minv, A, la);
        affineApply(Minv, B, lb);
        for (int k = 0; k < 3; ++k) {
          args.ray.a[k] = float(la[k]);
          args.ray.d[k] = float(lb[k] - la[k]);
        }
        args.ray.smin = 0.f;
        args.ray.smax = found ? best.s : 1.f;
        const Affine l2e = affineMul(w2e, M);
        std::copy_n(l2e.m, 12, args.local_to_eye);
        args.local_to_eye[12] = args.local_to_eye[13] =
            args.local_to_eye[14] = 0.f;
        args.local_to_eye[15] = 1.f;
        args.slab_front = cam.front;
        args.slab_back = cam.back;

        for (cRep_t r : kPickReps) {
          if (!(mask & (1 << r)))
            continue;
          const Rep* rep = cs->Rep[r];
          if (!rep || !cs->Active[r])
            continue;
          PickRayHit h;
          if (!rep->pickRay(args, h))
            continue;
          if (found && !(h.s < best.s))
            continue;
          found = true;
          best = h;
          bestInv = Minv;
          bestObj = obj;
          bestState = state;
          bestRep = r;
          args.ray.smax = h.s;
        }
      });

  if (!found)
    return out;

  const double s = best.s;
  double dir[3];
  for (int k = 0; k < 3; ++k) {
    out.point[k] = float(A[k] + s * (B[k] - A[k]));
    dir[k] = double(B[k]) - A[k];
  }
  // Toward the camera, exact for both projections.
  double v[3] = {-dir[0], -dir[1], -dir[2]};
  pickmath::normalize3(v);

  double n[3];
  if (best.cap) {
    // The cap is the slab plane, shaded with eye +z: Rᵀ (0, 0, 1).
    n[0] = cam.R[6];
    n[1] = cam.R[7];
    n[2] = cam.R[8];
  } else {
    // Normals transform with the inverse transpose of the local -> world map.
    for (int j = 0; j < 3; ++j)
      n[j] = bestInv.m[0 + j] * best.n[0] + bestInv.m[4 + j] * best.n[1] +
             bestInv.m[8 + j] * best.n[2];
    if (best.inside) {
      n[0] = -n[0];
      n[1] = -n[1];
      n[2] = -n[2];
    }
  }
  pickmath::normalize3(n);

  // Facing is reported BEFORE the silhouette nudge, so callers (and tests) can
  // tell a grazing hit from a wrongly oriented one.
  const double facing = pickmath::dot3(n, v);
  constexpr double kMinFacing = 0.05;
  if (facing < kMinFacing) {
    // Turn n toward the camera, in the plane of n and v, until it faces it
    // by exactly kMinFacing: keep n's direction across the view (t) and set
    // its component along v. Within asin(kMinFacing) (~2.9 degrees) of the
    // true normal when facing >= 0.
    double t[3] = {n[0] - facing * v[0], n[1] - facing * v[1],
        n[2] - facing * v[2]};
    const double tl = std::sqrt(pickmath::dot3(t, t));
    if (tl > 1e-12) {
      const double across = std::sqrt(1.0 - kMinFacing * kMinFacing) / tl;
      for (int k = 0; k < 3; ++k)
        n[k] = kMinFacing * v[k] + across * t[k];
    } else {
      std::copy_n(v, 3, n); // n was -v: no direction across, face the camera
    }
  }

  out.hit = true;
  pickmath::store3(out.normal, n);
  out.facing = float(facing);
  out.depth = float(cam.front + s * (double(cam.back) - cam.front));
  out.object = bestObj->Name;
  out.state = bestState;
  out.rep = bestRep;
  out.inside = best.inside;
  out.cap = best.cap;
  return out;
}

SurfacePickPrepareStats ScenePickSurfacePrepare(PyMOLGlobals* G, int rep_mask,
    const std::vector<std::string>* objects, bool update, bool build)
{
  SurfacePickPrepareStats stats;
  if (update) {
    ExecutiveUpdateSceneMembers(G);
    SceneUpdate(G, false);
  }
  const int mask = rep_mask & cSurfacePickRepMask;
  // Every coordinate set any grid cell draws. Which cell draws which does not
  // depend on the aspect, but GridUpdate needs a sane one.
  float aspect = SceneGetAspectRatio(G);
  if (!std::isfinite(aspect) || !(aspect > 0.f))
    aspect = 1.f;
  const ScenePickCell cell = ScenePickGridCell(G, 0.f, 0.f, aspect);
  forEachDrawnCoordSet(
      G, objects, cell, true, [&](ObjectMolecule*, CoordSet* cs, int) {
        for (cRep_t r : kPickReps) {
          if (!(mask & (1 << r)))
            continue;
          const Rep* rep = cs->Rep[r];
          if (!rep || !cs->Active[r])
            continue;
          bool built = false;
          const PickAccel* accel =
              build ? rep->pickPrepare(&built) : rep->pickAccelCached();
          if (!accel)
            continue;
          ++stats.accels;
          stats.bytes += accel->bytes();
          if (built)
            ++stats.built;
        }
      });
  return stats;
}

SurfacePickReleaseStats ScenePickSurfaceRelease(PyMOLGlobals* G, int rep_mask,
    const std::vector<std::string>* objects)
{
  SurfacePickReleaseStats stats;
  const int mask = rep_mask & cSurfacePickRepMask;
  // Every molecule, not just the scene's (enabled) ones: a disabled object
  // keeps the grids its reps were given while it was drawn.
  for (ObjectIterator iter(G); iter.next();) {
    pymol::CObject* obj = iter.getObject();
    if (!obj || obj->type != cObjectMolecule)
      continue;
    if (objects && std::find(objects->begin(), objects->end(), obj->Name) ==
                       objects->end())
      continue;
    auto* om = static_cast<ObjectMolecule*>(obj);
    for (int state = 0; state < om->NCSet; ++state) {
      const CoordSet* cs = om->CSet[state];
      if (!cs)
        continue;
      for (cRep_t r : kPickReps) {
        if (!(mask & (1 << r)) || !cs->Rep[r])
          continue;
        if (!cs->Rep[r]->pickAccelCached())
          continue;
        stats.bytes += cs->Rep[r]->pickRelease();
        ++stats.accels;
      }
    }
  }
  return stats;
}
