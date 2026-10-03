/*
 * Per-representation acceleration grid for the surface pick (#614).
 *
 * A PickAccel holds the pickable primitives of ONE representation, in that
 * representation's local (coordinate-set) frame, bucketed into a uniform grid.
 * It is built lazily on the first pick and cached on the Rep
 * (Rep::m_pickAccel), so it lives exactly as long as the geometry it was built
 * from: a rebuilt rep is a new Rep object with no cache.
 *
 * Nothing in here is read by the renderer. Building or querying a PickAccel
 * never changes what is drawn.
 */
#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

#include "PickMath.h"

class CGO;

/**
 * What a cached grid was built from. A cache whose key no longer matches the
 * rep's current source (another CGO, another size, or other pick rules) is
 * rebuilt.
 */
struct PickAccelKey {
  const void* source = nullptr;
  std::size_t size = 0;
  std::uintptr_t rules = 0;

  bool operator==(const PickAccelKey& o) const
  {
    return source == o.source && size == o.size && rules == o.rules;
  }
  bool operator!=(const PickAccelKey& o) const { return !(*this == o); }
};

/// The clip rule for each kind of CGO primitive, chosen by the rep from what
/// the Metal renderer draws for it (see PickMath.h).
struct PickCGORules {
  PickRule sphere = PickRule::Impostor;
  PickRule cylinder = PickRule::Impostor;
  /// CGOSimplify (the Mesh path for SHADER_CYLINDER_WITH_2ND_COLOR) passes an
  /// interpolated cylinder's caps swapped; the Mesh rule mirrors that.
  bool simplified_cylinders = false;

  std::uintptr_t bits() const
  {
    return std::uintptr_t(sphere) | (std::uintptr_t(cylinder) << 2) |
           (std::uintptr_t(simplified_cylinders) << 4);
  }
};

class PickAccel
{
public:
  struct Sphere {
    float c[3];
    float r;
    PickRule rule;
  };

  struct Cylinder {
    float p0[3];
    float axis[3];
    float r;
    PickCap cap0, cap1;
    PickRule rule;
  };

  PickAccelKey key;

  void addSphere(const float* c, float r, PickRule rule);
  void addCylinder(const float* p0, const float* axis, float r, PickCap cap0,
      PickCap cap1, PickRule rule);

  /// Bucket the items into the grid. Call once, after adding every item.
  void build();

  /**
   * Front-most primitive along `ray` within [ray.smin, ray.smax], with the
   * items' clip rules applied (`cap_on` enables impostor interior caps).
   * Fills `hit` in this accel's frame.
   */
  bool intersect(const PickRay& ray, bool cap_on, PickRayHit& hit) const;

  std::size_t itemCount() const { return m_spheres.size() + m_cylinders.size(); }
  bool empty() const { return itemCount() == 0; }

  /// Heap bytes held (items + grid), for prepare's report.
  std::size_t bytes() const;

private:
  bool testItem(std::uint32_t id, const PickRay& ray, bool cap_on, float smax,
      PickRayHit& hit) const;
  void itemBounds(std::uint32_t id, float* lo, float* hi) const;

  std::vector<Sphere> m_spheres;
  std::vector<Cylinder> m_cylinders;

  // Uniform grid in CSR form: the items overlapping cell i are
  // m_refs[m_cellStart[i] .. m_cellStart[i + 1]).
  float m_lo[3] = {0.f, 0.f, 0.f};
  float m_hi[3] = {0.f, 0.f, 0.f};
  float m_cell = 1.f;
  int m_n[3] = {0, 0, 0};
  std::vector<std::uint32_t> m_cellStart;
  std::vector<std::uint32_t> m_refs;
  bool m_built = false;
};

/**
 * Add the pickable primitives of `cgo` to `accel`, walking the ops the way
 * CGORenderRay does. Spheres and cylinder-type ops (CYLINDER,
 * SHADER_CYLINDER(_WITH_2ND_COLOR), CUSTOM_CYLINDER(_ALPHA), SAUSAGE) get the
 * caller's rules. Primitives drawn fully transparent are skipped. Cones,
 * ellipsoids, quadrics, lines, points and labels are not pickable.
 */
void PickAccelAddCGO(const CGO* cgo, PickAccel& accel, const PickCGORules& rules);
