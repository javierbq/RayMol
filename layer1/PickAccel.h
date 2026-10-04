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
 * rep's current source (another CGO, another size, other pick rules, or for
 * an indexed mesh other normal/index arrays) is rebuilt.
 */
struct PickAccelKey {
  const void* source = nullptr;
  std::size_t size = 0;
  std::uintptr_t rules = 0;
  const void* aux0 = nullptr; ///< e.g. the indexed mesh's normals
  const void* aux1 = nullptr; ///< e.g. the indexed mesh's triangle indices
  std::size_t aux_size = 0;   ///< e.g. the indexed mesh's triangle count
  /// Shape settings the rules apply (the pointed nub's overlap and length).
  float shape[2] = {0.f, 0.f};

  bool operator==(const PickAccelKey& o) const
  {
    return source == o.source && size == o.size && rules == o.rules &&
           aux0 == o.aux0 && aux1 == o.aux1 && aux_size == o.aux_size &&
           shape[0] == o.shape[0] && shape[1] == o.shape[1];
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
  /// Pick the triangle ops (DRAW_ARRAYS triangle modes, TRIANGLE, BEGIN/END
  /// triangle runs). Always the Mesh rule: Metal draws them as triangles and
  /// culls nothing. Off for reps whose draw path drops them (the stick
  /// impostor path keeps only cylinders and spheres).
  bool triangles = false;
  /// The `stick_round_nub` argument the rep's CGOSimplify call passes: true
  /// (its default) draws a Mesh-rule cylinder's round end as a hemisphere,
  /// false as CGOSimpleCylinder's pointed nub, shaped by `nub`
  /// (PickCap::Pointed). Impostors always draw a hemisphere.
  bool round_nub = true;
  /// stick_overlap and stick_nub, read globally as CGOSimpleCylinder reads
  /// them. Only used when pointed().
  PickNubShape nub;

  bool pointed() const { return !round_nub && cylinder == PickRule::Mesh; }

  std::uintptr_t bits() const
  {
    return std::uintptr_t(sphere) | (std::uintptr_t(cylinder) << 2) |
           (std::uintptr_t(simplified_cylinders) << 4) |
           (std::uintptr_t(triangles) << 5) | (std::uintptr_t(pointed()) << 6);
  }

  /// The grid key for a CGO built under these rules.
  PickAccelKey key(const void* source, std::size_t size) const
  {
    PickAccelKey k;
    k.source = source;
    k.size = size;
    k.rules = bits();
    if (pointed()) {
      k.shape[0] = nub.overlap;
      k.shape[1] = nub.length;
    }
    return k;
  }
};

/**
 * Query-time filter for the indexed mesh's triangles. RepSurface decides per
 * triangle what it draws from per-atom visibility and alpha, which recolor()
 * updates in place without rebuilding the rep, so the grid keeps every
 * triangle and asks at query time. `accept(ctx, tri)` gets the triangle's
 * index in the mesh.
 */
struct PickTriFilter {
  bool (*accept)(const void* ctx, std::uint32_t tri) = nullptr;
  const void* ctx = nullptr;
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

  /// A copied triangle (CGO TRIANGLE op, or one of a BEGIN/END run).
  struct Triangle {
    float v[9]; ///< v0, v1, v2
    float n[9]; ///< smooth normals at v0, v1, v2 (unused when !has_n)
    bool has_n;
  };

  /**
   * The triangles of one CGO DRAW_ARRAYS op, referenced IN PLACE: the
   * pointers go into the CGO's data heap, which stays put for the CGO's
   * lifetime (and a rep's grid never outlives the CGO it was keyed on).
   */
  struct TriBlock {
    const float* verts;   ///< 3 floats per vertex
    const float* normals; ///< 3 per vertex, or nullptr
    const float* colors;  ///< 4 per vertex (alpha last), or nullptr
    int mode;             ///< GL_TRIANGLES, _TRIANGLE_STRIP or _TRIANGLE_FAN
    std::uint32_t first;  ///< index of its first triangle among all blocks
    std::uint32_t ntri;
  };

  /// An indexed triangle mesh referenced in place (RepSurface's V/VN/T).
  struct Mesh {
    const float* V = nullptr;
    const float* VN = nullptr; ///< or nullptr
    std::uint32_t nverts = 0;
    const int* T = nullptr;    ///< 3 vertex indices per triangle
    std::uint32_t ntri = 0;
  };

  PickAccelKey key;

  void addSphere(const float* c, float r, PickRule rule);
  void addCylinder(const float* p0, const float* axis, float r, PickCap cap0,
      PickCap cap1, PickRule rule);
  /// `n0..n2` may be nullptr (the geometric normal is used).
  void addTriangle(const float* v0, const float* v1, const float* v2,
      const float* n0, const float* n1, const float* n2);
  /// A DRAW_ARRAYS triangle block; other modes are ignored.
  void addTriangleBlock(int mode, int nverts, const float* verts,
      const float* normals, const float* colors);
  /// The indexed mesh: `nverts` vertices (and normals, or VN nullptr),
  /// `ntri` index triples. At most one per grid; a second call replaces it.
  void setMesh(
      const float* V, const float* VN, int nverts, const int* T, int ntri);
  /// The shape of every PickCap::Pointed end in this grid.
  void setNubShape(const PickNubShape& nub) { m_nub = nub; }

  /// Bucket the items into the grid. Call once, after adding every item.
  void build();

  /**
   * Front-most primitive along `ray` within [ray.smin, ray.smax], with the
   * items' clip rules applied (`cap_on` enables impostor interior caps).
   * Triangles follow the Mesh rule. `filter` (optional) can reject indexed
   * mesh triangles. Fills `hit` in this accel's frame.
   *
   * With `eye`, impostors follow what Metal rasterizes at the slab's
   * planes. A sphere's quad sits at its centre's depth, so a sphere whose
   * centre is outside the slab draws nothing. With `cap_on`, a cylinder's
   * box follows cyl_impostor_vertex's near-plane clamp: one wholly in front
   * of the plane still caps it where its infinite tube runs on behind the
   * plane, provided Metal keeps its box (the walk starts early enough to
   * meet such cylinders). Without `eye`, every impostor proxy counts as
   * drawn.
   */
  bool intersect(const PickRay& ray, bool cap_on, PickRayHit& hit,
      const PickTriFilter* filter = nullptr,
      const PickEyeDepth* eye = nullptr) const;

  std::size_t itemCount() const
  {
    return m_spheres.size() + m_cylinders.size() + m_triangles.size() +
           m_blockTris + m_mesh.ntri;
  }
  bool empty() const { return itemCount() == 0; }

  /// Heap bytes held (items + grid), for prepare's report. Arrays referenced
  /// in place belong to the rep and are not counted.
  std::size_t bytes() const;

private:
  bool testItem(std::uint32_t id, const PickRay& ray, bool cap_on, float smax,
      PickRayHit& hit, const PickTriFilter* filter,
      const PickEyeDepth* eye) const;
  /// Calls fn(id, lo, hi) for every item worth binning (triangles drawn
  /// fully transparent are left out).
  template <typename Fn> void forEachItemBounds(Fn&& fn) const;
  /// The vertices (and normals, nullptr when none) of block triangle `t`.
  void blockTriangle(
      std::uint32_t t, const float* v[3], const float* n[3]) const;

  std::vector<Sphere> m_spheres;
  std::vector<Cylinder> m_cylinders;
  std::vector<Triangle> m_triangles;
  std::vector<TriBlock> m_blocks;
  std::uint32_t m_blockTris = 0;
  Mesh m_mesh;
  PickNubShape m_nub;
  /// Largest length + 3.5 r of the impostor cylinders: how far in front of
  /// the near plane (in depth) one can sit and still have its box kept.
  float m_capReach = 0.f;
  // First item id of each kind (spheres start at 0); set by build().
  std::uint32_t m_firstCyl = 0, m_firstTri = 0, m_firstBlock = 0,
                m_firstMesh = 0;

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
 * caller's rules; with rules.pointed(), their round ends become
 * PickCap::Pointed. With `rules.triangles`, DRAW_ARRAYS triangle blocks are
 * referenced in place and TRIANGLE ops and BEGIN/END triangle runs are
 * copied. Primitives drawn fully transparent are skipped. Cones, ellipsoids,
 * quadrics, lines, points and labels are not pickable.
 */
void PickAccelAddCGO(const CGO* cgo, PickAccel& accel, const PickCGORules& rules);
