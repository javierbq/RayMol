/*
 * Per-representation acceleration grid for the surface pick -- see
 * PickAccel.h.
 */

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

void PickAccel::itemBounds(std::uint32_t id, float* lo, float* hi) const
{
  const std::size_t ns = m_spheres.size();
  if (id < ns) {
    const auto& sp = m_spheres[id];
    for (int k = 0; k < 3; ++k) {
      lo[k] = sp.c[k] - sp.r;
      hi[k] = sp.c[k] + sp.r;
    }
    return;
  }
  const auto& cy = m_cylinders[id - ns];
  // Both end points padded by the radius: covers the body and round caps.
  for (int k = 0; k < 3; ++k) {
    const float e = cy.p0[k] + cy.axis[k];
    lo[k] = std::min(cy.p0[k], e) - cy.r;
    hi[k] = std::max(cy.p0[k], e) + cy.r;
  }
}

void PickAccel::build()
{
  m_built = true;
  m_cellStart.clear();
  m_refs.clear();
  const std::uint32_t n = std::uint32_t(itemCount());
  if (!n)
    return;

  float lo[3], hi[3];
  for (int k = 0; k < 3; ++k) {
    m_lo[k] = std::numeric_limits<float>::max();
    m_hi[k] = -std::numeric_limits<float>::max();
  }
  for (std::uint32_t id = 0; id < n; ++id) {
    itemBounds(id, lo, hi);
    for (int k = 0; k < 3; ++k) {
      m_lo[k] = std::min(m_lo[k], lo[k]);
      m_hi[k] = std::max(m_hi[k], hi[k]);
    }
  }

  // About four items' worth of volume per cell, clamped, then grown until
  // the cell count fits.
  float ext[3];
  double vol = 1.0;
  for (int k = 0; k < 3; ++k) {
    ext[k] = std::max(m_hi[k] - m_lo[k], 1e-3f);
    vol *= ext[k];
  }
  float h = float(std::cbrt(vol * 4.0 / n));
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
  int c0[3], c1[3];
  for (std::uint32_t id = 0; id < n; ++id) {
    itemBounds(id, lo, hi);
    cellRange(lo, hi, c0, c1);
    for (int z = c0[2]; z <= c1[2]; ++z)
      for (int y = c0[1]; y <= c1[1]; ++y)
        for (int x = c0[0]; x <= c1[0]; ++x)
          ++m_cellStart[(std::size_t(z) * m_n[1] + y) * m_n[0] + x + 1];
  }
  for (std::size_t i = 0; i < ncell; ++i)
    m_cellStart[i + 1] += m_cellStart[i];
  m_refs.resize(m_cellStart[ncell]);
  std::vector<std::uint32_t> fill(m_cellStart.begin(), m_cellStart.end() - 1);
  for (std::uint32_t id = 0; id < n; ++id) {
    itemBounds(id, lo, hi);
    cellRange(lo, hi, c0, c1);
    for (int z = c0[2]; z <= c1[2]; ++z)
      for (int y = c0[1]; y <= c1[1]; ++y)
        for (int x = c0[0]; x <= c1[0]; ++x)
          m_refs[fill[(std::size_t(z) * m_n[1] + y) * m_n[0] + x]++] = id;
  }
}

bool PickAccel::testItem(std::uint32_t id, const PickRay& ray, bool cap_on,
    float smax, PickRayHit& hit) const
{
  PickSpan span;
  PickRule rule;
  const std::size_t ns = m_spheres.size();
  if (id < ns) {
    const auto& sp = m_spheres[id];
    if (!pickSphere(ray.a, ray.d, sp.c, sp.r, span))
      return false;
    rule = sp.rule;
  } else {
    const auto& cy = m_cylinders[id - ns];
    if (!pickCylinder(
            ray.a, ray.d, cy.p0, cy.axis, cy.r, cy.cap0, cy.cap1, span))
      return false;
    rule = cy.rule;
  }
  return pickApplyRule(rule, cap_on, span, ray.smin, smax, hit);
}

bool PickAccel::intersect(
    const PickRay& ray, bool cap_on, PickRayHit& hit) const
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
      if (testItem(m_refs[r], ray, cap_on, smax, h) &&
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
         m_cellStart.capacity() * sizeof(std::uint32_t) +
         m_refs.capacity() * sizeof(std::uint32_t);
}

void PickAccelAddCGO(
    const CGO* cgo, PickAccel& accel, const PickCGORules& rules)
{
  if (!cgo)
    return;
  float alpha = 1.f;
  for (auto it = cgo->begin(); !it.is_stop(); ++it) {
    const auto pc = it.data();
    switch (it.op_code()) {
    case CGO_ALPHA:
      alpha = *pc;
      break;
    case CGO_SPHERE:
      // CGOSphere stores the radius in the slot the struct calls `diamter`.
      if (alpha > kInvisibleAlpha)
        accel.addSphere(pc, pc[3], rules.sphere);
      break;
    case CGO_SHADER_CYLINDER: {
      auto cyl = it.cast<cgo::draw::shadercylinder>();
      if (alpha > kInvisibleAlpha)
        accel.addCylinder(cyl->origin, cyl->axis, cyl->tube_size,
            cap1FromShaderBits(cyl->cap), cap2FromShaderBits(cyl->cap),
            rules.cylinder);
    } break;
    case CGO_SHADER_CYLINDER_WITH_2ND_COLOR: {
      auto cyl = it.cast<cgo::draw::shadercylinder2ndcolor>();
      if (alpha > kInvisibleAlpha) {
        PickCap c1 = cap1FromShaderBits(cyl->cap);
        PickCap c2 = cap2FromShaderBits(cyl->cap);
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
            capFromCylCap(cyl->get_cap1()), capFromCylCap(cyl->get_cap2()),
            rules.cylinder);
    } break;
    case CGO_CUSTOM_CYLINDER_ALPHA: {
      auto cyl = it.cast<cgo::draw::custom_cylinder_alpha>();
      const float axis[3] = {cyl->vertex2[0] - cyl->vertex1[0],
          cyl->vertex2[1] - cyl->vertex1[1], cyl->vertex2[2] - cyl->vertex1[2]};
      if (std::max(cyl->color1[3], cyl->color2[3]) > kInvisibleAlpha)
        accel.addCylinder(cyl->vertex1, axis, cyl->radius,
            capFromCylCap(cyl->get_cap1()), capFromCylCap(cyl->get_cap2()),
            rules.cylinder);
    } break;
    case CGO_SAUSAGE: {
      const float axis[3] = {pc[3] - pc[0], pc[4] - pc[1], pc[5] - pc[2]};
      if (alpha > kInvisibleAlpha)
        accel.addCylinder(
            pc, axis, pc[6], PickCap::Round, PickCap::Round, rules.cylinder);
    } break;
    default:
      // Triangles (DRAW_ARRAYS, TRIANGLE, BEGIN/END runs) join in with the
      // surface and cartoon picks; everything else is not pickable.
      break;
    }
  }
}
