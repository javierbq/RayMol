/*
 * Per-representation acceleration grid for the surface pick -- see
 * PickAccel.h.
 */

#include "os_gl.h"

#include "PickAccel.h"

#include <algorithm>
#include <cmath>
#include <limits>

#include "Basis.h"
#include "CGO.h"

namespace
{

/// Cells per grid at most; the cell size grows until the grid fits.
constexpr std::size_t kMaxCells = std::size_t(4) << 20;
constexpr float kMinCell = 0.25f;
constexpr float kMaxCell = 16.f;

/// Alpha at or below this draws nothing (OIT contributes nothing either).
constexpr float kInvisibleAlpha = 0.001f;

// Same decoding as CGO.cpp's cap1/cap2_from_cyl_shader_bits (file-local
// there): bit 0/1 says the end is capped, the round bit makes it a hemisphere.
PickCap cap1FromShaderBits(int bits)
{
  return (bits & cCylShaderCap1Flat)
             ? ((bits & cCylShaderCap1RoundBit) ? PickCap::Round : PickCap::Flat)
             : PickCap::None;
}

PickCap cap2FromShaderBits(int bits)
{
  return (bits & cCylShaderCap2Flat)
             ? ((bits & cCylShaderCap2RoundBit) ? PickCap::Round : PickCap::Flat)
             : PickCap::None;
}

PickCap capFromCylCap(cCylCap c)
{
  switch (c) {
  case cCylCap::Flat:
    return PickCap::Flat;
  case cCylCap::Round:
    return PickCap::Round;
  default:
    return PickCap::None;
  }
}

} // namespace

void PickAccel::addSphere(const float* c, float r, PickRule rule)
{
  if (!(r > 0.f))
    return;
  m_spheres.push_back({{c[0], c[1], c[2]}, r, rule});
}

void PickAccel::addCylinder(const float* p0, const float* axis, float r,
    PickCap cap0, PickCap cap1, PickRule rule)
{
  if (!(r > 0.f))
    return;
  m_cylinders.push_back({{p0[0], p0[1], p0[2]}, {axis[0], axis[1], axis[2]},
      r, cap0, cap1, rule});
}

void PickAccel::addTriangle(const float* v0, const float* v1,
    const float* v2, const float* n0, const float* n1, const float* n2)
{
  Triangle t;
  std::copy_n(v0, 3, t.v);
  std::copy_n(v1, 3, t.v + 3);
  std::copy_n(v2, 3, t.v + 6);
  t.has_n = n0 && n1 && n2;
  if (t.has_n) {
    std::copy_n(n0, 3, t.n);
    std::copy_n(n1, 3, t.n + 3);
    std::copy_n(n2, 3, t.n + 6);
  } else {
    std::fill_n(t.n, 9, 0.f);
  }
  m_triangles.push_back(t);
}

void PickAccel::addTriangleBlock(int mode, int nverts, const float* verts,
    const float* normals, const float* colors)
{
  if (!verts || nverts < 3)
    return;
  std::uint32_t ntri = 0;
  switch (mode) {
  case GL_TRIANGLES:
    ntri = std::uint32_t(nverts / 3);
    break;
  case GL_TRIANGLE_STRIP:
  case GL_TRIANGLE_FAN:
    ntri = std::uint32_t(nverts - 2);
    break;
  default:
    return; // points and lines are not pickable
  }
  m_blocks.push_back({verts, normals, colors, mode, m_blockTris, ntri});
  m_blockTris += ntri;
}

void PickAccel::setMesh(
    const float* V, const float* VN, int nverts, const int* T, int ntri)
{
  m_mesh = Mesh();
  if (!V || !T || nverts <= 0 || ntri <= 0)
    return;
  m_mesh.V = V;
  m_mesh.VN = VN;
  m_mesh.nverts = std::uint32_t(nverts);
  m_mesh.T = T;
  m_mesh.ntri = std::uint32_t(ntri);
}

namespace
{
/// Corner vertex indices of triangle `l` of a DRAW_ARRAYS block.
void blockCorners(int mode, std::uint32_t l, std::uint32_t* i)
{
  switch (mode) {
  case GL_TRIANGLE_STRIP:
    i[0] = l, i[1] = l + 1, i[2] = l + 2;
    break;
  case GL_TRIANGLE_FAN:
    i[0] = 0, i[1] = l + 1, i[2] = l + 2;
    break;
  default: // GL_TRIANGLES
    i[0] = 3 * l, i[1] = 3 * l + 1, i[2] = 3 * l + 2;
    break;
  }
}
} // namespace

void PickAccel::blockTriangle(
    std::uint32_t t, const float* v[3], const float* n[3]) const
{
  // The block holding triangle t: the last one whose first triangle is <= t.
  auto it = std::upper_bound(m_blocks.begin(), m_blocks.end(), t,
      [](std::uint32_t x, const TriBlock& b) { return x < b.first; });
  const TriBlock& b = *(it - 1);
  std::uint32_t i[3];
  blockCorners(b.mode, t - b.first, i);
  for (int k = 0; k < 3; ++k) {
    v[k] = b.verts + 3 * std::size_t(i[k]);
    n[k] = b.normals ? b.normals + 3 * std::size_t(i[k]) : nullptr;
  }
}

namespace
{
void triangleBounds(const float* const v[3], float* lo, float* hi)
{
  for (int k = 0; k < 3; ++k) {
    lo[k] = std::min(std::min(v[0][k], v[1][k]), v[2][k]);
    hi[k] = std::max(std::max(v[0][k], v[1][k]), v[2][k]);
  }
}

bool finite3(const float* lo, const float* hi)
{
  for (int k = 0; k < 3; ++k)
    if (!std::isfinite(lo[k]) || !std::isfinite(hi[k]))
      return false;
  return true;
}
} // namespace

template <typename Fn> void PickAccel::forEachItemBounds(Fn&& fn) const
{
  float lo[3], hi[3];
  std::uint32_t id = 0;
  for (const auto& sp : m_spheres) {
    for (int k = 0; k < 3; ++k) {
      lo[k] = sp.c[k] - sp.r;
      hi[k] = sp.c[k] + sp.r;
    }
    fn(id++, lo, hi);
  }
  for (const auto& cy : m_cylinders) {
    // Both end points padded by the radius: covers the body and round caps.
    // A pointed end first moves out by its overlap and tip.
    float out0 = 0.f, out1 = 0.f;
    const float len = std::sqrt(cy.axis[0] * cy.axis[0] +
                                cy.axis[1] * cy.axis[1] +
                                cy.axis[2] * cy.axis[2]);
    if (len > 0.f) {
      const float reach =
          std::max(0.f, m_nub.overlap + std::max(0.f, m_nub.length)) * cy.r /
          len;
      if (cy.cap0 == PickCap::Pointed)
        out0 = reach;
      if (cy.cap1 == PickCap::Pointed)
        out1 = reach;
    }
    for (int k = 0; k < 3; ++k) {
      const float b = cy.p0[k] - out0 * cy.axis[k];
      const float e = cy.p0[k] + (1.f + out1) * cy.axis[k];
      lo[k] = std::min(b, e) - cy.r;
      hi[k] = std::max(b, e) + cy.r;
    }
    fn(id++, lo, hi);
  }
  for (const auto& t : m_triangles) {
    const float* v[3] = {t.v, t.v + 3, t.v + 6};
    triangleBounds(v, lo, hi);
    fn(id++, lo, hi);
  }
  for (const auto& b : m_blocks) {
    for (std::uint32_t l = 0; l < b.ntri; ++l, ++id) {
      std::uint32_t i[3];
      blockCorners(b.mode, l, i);
      if (b.colors) {
        // Per-vertex alpha (4th colour component): a triangle drawn with
        // nothing visible at any corner is not drawn at all.
        if (std::max(std::max(b.colors[4 * std::size_t(i[0]) + 3],
                         b.colors[4 * std::size_t(i[1]) + 3]),
                b.colors[4 * std::size_t(i[2]) + 3]) <= kInvisibleAlpha)
          continue;
      }
      const float* v[3] = {b.verts + 3 * std::size_t(i[0]),
          b.verts + 3 * std::size_t(i[1]), b.verts + 3 * std::size_t(i[2])};
      triangleBounds(v, lo, hi);
      fn(id, lo, hi);
    }
  }
  for (std::uint32_t t = 0; t < m_mesh.ntri; ++t, ++id) {
    const int* tt = m_mesh.T + 3 * std::size_t(t);
    // A corner out of range is never binned, so never tested.
    if (std::uint32_t(tt[0]) >= m_mesh.nverts ||
        std::uint32_t(tt[1]) >= m_mesh.nverts ||
        std::uint32_t(tt[2]) >= m_mesh.nverts)
      continue;
    const float* v[3] = {m_mesh.V + 3 * std::size_t(tt[0]),
        m_mesh.V + 3 * std::size_t(tt[1]), m_mesh.V + 3 * std::size_t(tt[2])};
    triangleBounds(v, lo, hi);
    fn(id, lo, hi);
  }
}

void PickAccel::build()
{
  m_built = true;
  m_cellStart.clear();
  m_refs.clear();
  m_firstCyl = std::uint32_t(m_spheres.size());
  m_firstTri = m_firstCyl + std::uint32_t(m_cylinders.size());
  m_firstBlock = m_firstTri + std::uint32_t(m_triangles.size());
  m_firstMesh = m_firstBlock + m_blockTris;
  // Item ids are 32-bit; a rep this large (billions of primitives) is not
  // pickable rather than wrong.
  if (itemCount() >= std::size_t(std::numeric_limits<std::uint32_t>::max()))
    return;

  // Bounds of every binned item (NaN or infinite coordinates are skipped).
  std::size_t n = 0;
  for (int k = 0; k < 3; ++k) {
    m_lo[k] = std::numeric_limits<float>::max();
    m_hi[k] = -std::numeric_limits<float>::max();
  }
  forEachItemBounds([&](std::uint32_t, const float* lo, const float* hi) {
    if (!finite3(lo, hi))
      return;
    ++n;
    for (int k = 0; k < 3; ++k) {
      m_lo[k] = std::min(m_lo[k], lo[k]);
      m_hi[k] = std::max(m_hi[k], hi[k]);
    }
  });
  if (!n)
    return;

  // About four items' worth of volume per cell, clamped, then grown until
  // the cell count fits.
  float ext[3];
  double vol = 1.0;
  for (int k = 0; k < 3; ++k) {
    ext[k] = std::max(m_hi[k] - m_lo[k], 1e-3f);
    vol *= ext[k];
  }
  float h = float(std::cbrt(vol * 4.0 / double(n)));
  h = std::min(std::max(h, kMinCell), kMaxCell);
  for (;;) {
    std::size_t cells = 1;
    for (int k = 0; k < 3; ++k) {
      m_n[k] = std::max(1, int(std::ceil(ext[k] / h)));
      cells *= std::size_t(m_n[k]);
    }
    if (cells <= kMaxCells)
      break;
    h *= 1.26f;
  }
  m_cell = h;
  // Make the box an exact multiple of the cell so cell coordinates and the
  // traversal agree on every boundary.
  for (int k = 0; k < 3; ++k)
    m_hi[k] = m_lo[k] + m_n[k] * h;

  const std::size_t ncell = std::size_t(m_n[0]) * m_n[1] * m_n[2];
  auto cellRange = [&](const float* blo, const float* bhi, int* c0, int* c1) {
    for (int k = 0; k < 3; ++k) {
      c0[k] = std::min(m_n[k] - 1,
          std::max(0, int(std::floor((blo[k] - m_lo[k]) / h))));
      c1[k] = std::min(m_n[k] - 1,
          std::max(0, int(std::floor((bhi[k] - m_lo[k]) / h))));
    }
  };

  // Counting pass, prefix sum, fill pass.
  m_cellStart.assign(ncell + 1, 0);
  forEachItemBounds([&](std::uint32_t, const float* lo, const float* hi) {
    if (!finite3(lo, hi))
      return;
    int c0[3], c1[3];
    cellRange(lo, hi, c0, c1);
    for (int z = c0[2]; z <= c1[2]; ++z)
      for (int y = c0[1]; y <= c1[1]; ++y)
        for (int x = c0[0]; x <= c1[0]; ++x)
          ++m_cellStart[(std::size_t(z) * m_n[1] + y) * m_n[0] + x + 1];
  });
  for (std::size_t i = 0; i < ncell; ++i)
    m_cellStart[i + 1] += m_cellStart[i];
  m_refs.resize(m_cellStart[ncell]);
  std::vector<std::uint32_t> fill(m_cellStart.begin(), m_cellStart.end() - 1);
  forEachItemBounds([&](std::uint32_t id, const float* lo, const float* hi) {
    if (!finite3(lo, hi))
      return;
    int c0[3], c1[3];
    cellRange(lo, hi, c0, c1);
    for (int z = c0[2]; z <= c1[2]; ++z)
      for (int y = c0[1]; y <= c1[1]; ++y)
        for (int x = c0[0]; x <= c1[0]; ++x)
          m_refs[fill[(std::size_t(z) * m_n[1] + y) * m_n[0] + x]++] = id;
  });
}

bool PickAccel::testItem(std::uint32_t id, const PickRay& ray, bool cap_on,
    float smax, PickRayHit& hit, const PickTriFilter* filter) const
{
  if (id >= m_firstTri) {
    // Triangles: the Mesh rule, one crossing each.
    const float* v[3];
    const float* n[3];
    if (id >= m_firstMesh) {
      const std::uint32_t t = id - m_firstMesh;
      if (filter && filter->accept && !filter->accept(filter->ctx, t))
        return false;
      const int* tt = m_mesh.T + 3 * std::size_t(t);
      for (int k = 0; k < 3; ++k) {
        v[k] = m_mesh.V + 3 * std::size_t(tt[k]);
        n[k] = m_mesh.VN ? m_mesh.VN + 3 * std::size_t(tt[k]) : nullptr;
      }
    } else if (id >= m_firstBlock) {
      blockTriangle(id - m_firstBlock, v, n);
    } else {
      const Triangle& t = m_triangles[id - m_firstTri];
      for (int k = 0; k < 3; ++k) {
        v[k] = t.v + 3 * k;
        n[k] = t.has_n ? t.n + 3 * k : nullptr;
      }
    }
    return pickTriangleMesh(ray.a, ray.d, v[0], v[1], v[2], n[0], n[1], n[2],
        ray.smin, smax, hit);
  }

  PickSpan span;
  PickRule rule;
  if (id < m_firstCyl) {
    const auto& sp = m_spheres[id];
    if (!pickSphere(ray.a, ray.d, sp.c, sp.r, span))
      return false;
    rule = sp.rule;
  } else {
    const auto& cy = m_cylinders[id - m_firstCyl];
    if (!pickCylinder(ray.a, ray.d, cy.p0, cy.axis, cy.r, cy.cap0, cy.cap1,
            span, m_nub))
      return false;
    rule = cy.rule;
  }
  return pickApplyRule(rule, cap_on, span, ray.smin, smax, hit);
}

bool PickAccel::intersect(const PickRay& ray, bool cap_on, PickRayHit& hit,
    const PickTriFilter* filter) const
{
  if (!m_built || m_cellStart.empty() || !(ray.smin <= ray.smax))
    return false;

  // Clip the window to the grid box (slab method).
  double t0 = ray.smin, t1 = ray.smax;
  for (int k = 0; k < 3; ++k) {
    const double dk = ray.d[k];
    if (std::fabs(dk) < 1e-30) {
      if (ray.a[k] < m_lo[k] || ray.a[k] > m_hi[k])
        return false;
      continue;
    }
    double ta = (m_lo[k] - ray.a[k]) / dk;
    double tb = (m_hi[k] - ray.a[k]) / dk;
    if (ta > tb)
      std::swap(ta, tb);
    t0 = std::max(t0, ta);
    t1 = std::min(t1, tb);
    if (t0 > t1)
      return false;
  }

  // 3D-DDA (Amanatides & Woo) from the clipped start.
  int c[3], step[3];
  double tmax[3], tdelta[3];
  for (int k = 0; k < 3; ++k) {
    const double p = ray.a[k] + t0 * ray.d[k];
    c[k] = std::min(m_n[k] - 1,
        std::max(0, int(std::floor((p - m_lo[k]) / m_cell))));
    const double dk = ray.d[k];
    if (dk > 1e-30) {
      step[k] = 1;
      tmax[k] = (m_lo[k] + (c[k] + 1) * double(m_cell) - ray.a[k]) / dk;
      tdelta[k] = m_cell / dk;
    } else if (dk < -1e-30) {
      step[k] = -1;
      tmax[k] = (m_lo[k] + c[k] * double(m_cell) - ray.a[k]) / dk;
      tdelta[k] = -m_cell / dk;
    } else {
      step[k] = 0;
      tmax[k] = std::numeric_limits<double>::infinity();
      tdelta[k] = std::numeric_limits<double>::infinity();
    }
  }

  bool found = false;
  PickRayHit best;
  float smax = ray.smax;
  for (;;) {
    const std::size_t cell = (std::size_t(c[2]) * m_n[1] + c[1]) * m_n[0] + c[0];
    for (std::uint32_t r = m_cellStart[cell], e = m_cellStart[cell + 1]; r < e;
         ++r) {
      PickRayHit h;
      if (testItem(m_refs[r], ray, cap_on, smax, h, filter) &&
          (!found || h.s < best.s)) {
        best = h;
        found = true;
        smax = h.s;
      }
    }
    const double t_exit = std::min(std::min(tmax[0], tmax[1]), tmax[2]);
    // Every item that could still beat `best` overlaps a later cell.
    if (found && best.s <= t_exit)
      break;
    if (t_exit >= t1)
      break;
    const int k = (tmax[0] <= tmax[1] && tmax[0] <= tmax[2]) ? 0
                  : (tmax[1] <= tmax[2])                    ? 1
                                                            : 2;
    c[k] += step[k];
    if (c[k] < 0 || c[k] >= m_n[k])
      break;
    tmax[k] += tdelta[k];
  }

  if (found)
    hit = best;
  return found;
}

std::size_t PickAccel::bytes() const
{
  return m_spheres.capacity() * sizeof(Sphere) +
         m_cylinders.capacity() * sizeof(Cylinder) +
         m_triangles.capacity() * sizeof(Triangle) +
         m_blocks.capacity() * sizeof(TriBlock) +
         m_cellStart.capacity() * sizeof(std::uint32_t) +
         m_refs.capacity() * sizeof(std::uint32_t);
}

void PickAccelAddCGO(
    const CGO* cgo, PickAccel& accel, const PickCGORules& rules)
{
  if (!cgo)
    return;
  float alpha = 1.f;

  // CGOSimplify with stick_round_nub off draws a round end as a pointed nub.
  const bool pointed = rules.pointed();
  if (pointed)
    accel.setNubShape(rules.nub);
  auto end = [pointed](PickCap c) {
    return (pointed && c == PickCap::Round) ? PickCap::Pointed : c;
  };

  // A BEGIN/END run: its vertices with the normal and alpha current at each
  // (CGORenderRay's walk), turned into triangles at END.
  struct RunVertex {
    const float* v;
    const float* n; // nullptr before the run's first NORMAL
    float alpha;
  };
  int run_mode = -1;
  const float* run_normal = nullptr;
  std::vector<RunVertex> run;
  auto emitRun = [&]() {
    auto tri = [&](const RunVertex& a, const RunVertex& b,
                   const RunVertex& c) {
      if (std::max(std::max(a.alpha, b.alpha), c.alpha) > kInvisibleAlpha)
        accel.addTriangle(a.v, b.v, c.v, a.n, b.n, c.n);
    };
    const std::size_t nv = run.size();
    switch (run_mode) {
    case GL_TRIANGLES:
      for (std::size_t i = 0; i + 2 < nv; i += 3)
        tri(run[i], run[i + 1], run[i + 2]);
      break;
    case GL_TRIANGLE_STRIP:
      for (std::size_t i = 0; i + 2 < nv; ++i)
        tri(run[i], run[i + 1], run[i + 2]);
      break;
    case GL_TRIANGLE_FAN:
      for (std::size_t i = 1; i + 1 < nv; ++i)
        tri(run[0], run[i], run[i + 1]);
      break;
    default:
      break; // points and lines are not pickable
    }
    run.clear();
  };

  for (auto it = cgo->begin(); !it.is_stop(); ++it) {
    const auto pc = it.data();
    switch (it.op_code()) {
    case CGO_ALPHA:
      alpha = *pc;
      break;
    case CGO_BEGIN:
      if (rules.triangles) {
        run_mode = CGO_get_int(pc);
        run_normal = nullptr;
        run.clear();
      }
      break;
    case CGO_END:
      if (rules.triangles && run_mode >= 0) {
        emitRun();
        run_mode = -1;
      }
      break;
    case CGO_NORMAL:
      run_normal = pc;
      break;
    case CGO_VERTEX:
      if (rules.triangles && (run_mode == GL_TRIANGLES ||
                                 run_mode == GL_TRIANGLE_STRIP ||
                                 run_mode == GL_TRIANGLE_FAN))
        run.push_back({pc, run_normal, alpha});
      break;
    case CGO_TRIANGLE:
      // v0 v1 v2, n0 n1 n2, then colours
      if (rules.triangles && alpha > kInvisibleAlpha)
        accel.addTriangle(pc, pc + 3, pc + 6, pc + 9, pc + 12, pc + 15);
      break;
    case CGO_DRAW_ARRAYS: {
      if (!rules.triangles)
        break;
      auto sp = it.cast<cgo::draw::arrays>();
      const int bits = sp->arraybits;
      if (!(bits & CGO_VERTEX_ARRAY))
        break;
      // The arrays follow each other in this order (CGORenderRay).
      const float* data = sp->get_data();
      const int nv = sp->nverts;
      const float* verts = data;
      std::size_t offset = std::size_t(nv) * 3;
      const float* normals = nullptr;
      const float* colors = nullptr;
      if (bits & CGO_NORMAL_ARRAY) {
        normals = data + offset;
        offset += std::size_t(nv) * 3;
      }
      if (bits & CGO_COLOR_ARRAY)
        colors = data + offset;
      // Without a colour array the block is drawn at the current alpha.
      if (colors || alpha > kInvisibleAlpha)
        accel.addTriangleBlock(sp->mode, nv, verts, normals, colors);
    } break;
    case CGO_SPHERE:
      // CGOSphere stores the radius in the slot the struct calls `diamter`.
      if (alpha > kInvisibleAlpha)
        accel.addSphere(pc, pc[3], rules.sphere);
      break;
    case CGO_SHADER_CYLINDER: {
      auto cyl = it.cast<cgo::draw::shadercylinder>();
      if (alpha > kInvisibleAlpha)
        accel.addCylinder(cyl->origin, cyl->axis, cyl->tube_size,
            end(cap1FromShaderBits(cyl->cap)),
            end(cap2FromShaderBits(cyl->cap)), rules.cylinder);
    } break;
    case CGO_SHADER_CYLINDER_WITH_2ND_COLOR: {
      auto cyl = it.cast<cgo::draw::shadercylinder2ndcolor>();
      if (alpha > kInvisibleAlpha) {
        PickCap c1 = end(cap1FromShaderBits(cyl->cap));
        PickCap c2 = end(cap2FromShaderBits(cyl->cap));
        // CGOSimplify hands an interpolated one to CGOSimpleCylinder as
        // (bcap, fcap) -- mirror what the tessellated mesh draws.
        if (rules.simplified_cylinders && (cyl->cap & cCylShaderInterpColor))
          std::swap(c1, c2);
        accel.addCylinder(cyl->origin, cyl->axis, cyl->tube_size, c1, c2,
            rules.cylinder);
      }
    } break;
    case CGO_CYLINDER: {
      // CGOSimplify draws plain cylinders with flat caps.
      auto cyl = it.cast<cgo::draw::cylinder>();
      const float axis[3] = {cyl->vertex2[0] - cyl->vertex1[0],
          cyl->vertex2[1] - cyl->vertex1[1], cyl->vertex2[2] - cyl->vertex1[2]};
      if (alpha > kInvisibleAlpha)
        accel.addCylinder(cyl->vertex1, axis, cyl->radius, PickCap::Flat,
            PickCap::Flat, rules.cylinder);
    } break;
    case CGO_CUSTOM_CYLINDER: {
      auto cyl = it.cast<cgo::draw::custom_cylinder>();
      const float axis[3] = {cyl->vertex2[0] - cyl->vertex1[0],
          cyl->vertex2[1] - cyl->vertex1[1], cyl->vertex2[2] - cyl->vertex1[2]};
      if (alpha > kInvisibleAlpha)
        accel.addCylinder(cyl->vertex1, axis, cyl->radius,
            end(capFromCylCap(cyl->get_cap1())),
            end(capFromCylCap(cyl->get_cap2())), rules.cylinder);
    } break;
    case CGO_CUSTOM_CYLINDER_ALPHA: {
      auto cyl = it.cast<cgo::draw::custom_cylinder_alpha>();
      const float axis[3] = {cyl->vertex2[0] - cyl->vertex1[0],
          cyl->vertex2[1] - cyl->vertex1[1], cyl->vertex2[2] - cyl->vertex1[2]};
      if (std::max(cyl->color1[3], cyl->color2[3]) > kInvisibleAlpha)
        accel.addCylinder(cyl->vertex1, axis, cyl->radius,
            end(capFromCylCap(cyl->get_cap1())),
            end(capFromCylCap(cyl->get_cap2())), rules.cylinder);
    } break;
    case CGO_SAUSAGE: {
      const float axis[3] = {pc[3] - pc[0], pc[4] - pc[1], pc[5] - pc[2]};
      if (alpha > kInvisibleAlpha)
        accel.addCylinder(pc, axis, pc[6], end(PickCap::Round),
            end(PickCap::Round), rules.cylinder);
    } break;
    default:
      // Cones, ellipsoids, quadrics, lines, points, labels: not pickable.
      break;
    }
  }
}
