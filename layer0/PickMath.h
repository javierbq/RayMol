/*
 * Ray-primitive tests for the surface pick (#614).
 *
 * Header-only and free of PyMOLGlobals: everything here is plain geometry in
 * one coordinate frame, so it can be reused by any caller (the per-rep
 * acceleration grid in layer1/PickAccel, and later anything else).
 *
 * The pick ray is the SEGMENT between the near and the far plane of the clip
 * slab, parameterised as
 *
 *     p(s) = a + s * d,     s = 0 on the near plane, s = 1 on the far plane.
 *
 * An affine map preserves s, so a hit found in a representation's local frame
 * can be compared directly with hits from other objects and reps.
 *
 * The clip rules encode what the Metal renderer turns each primitive into:
 *
 *  - PickRule::Impostor -- sphere and cylinder impostors. Their fragment shader
 *    ray-casts only the FRONT surface. When the near plane cuts in front of
 *    that point, the fragment is discarded (the primitive becomes see-through)
 *    unless `metal_interior_cap` fills the cross-section with a flat cap at the
 *    near plane (RendererMetal.mm, sphere and cylinder impostor fragments).
 *  - PickRule::Mesh -- real triangles (and analytic shapes Metal tessellates).
 *    Nothing is culled on Metal, so when the near plane cuts a closed mesh the
 *    inside of the far wall is what shows.
 */
#pragma once

#include <algorithm>
#include <cmath>

/// Segment p(s) = a + s * d, accepted for s in [smin, smax].
struct PickRay {
  float a[3] = {0.f, 0.f, 0.f};
  float d[3] = {0.f, 0.f, -1.f};
  float smin = 0.f; ///< the near clip plane for impostors; the window start
  float smax = 1.f; ///< the window end (shrinks to the best hit so far)
};

/**
 * Eye depth in the ray's frame, depth(p) = -(row . (p, 1)), and the slab's
 * near and far planes: what Metal's clipping of the impostor proxies
 * depends on (PickAccel::intersect).
 */
struct PickEyeDepth {
  float row[4] = {0.f, 0.f, -1.f, 0.f};
  float near = 0.f;
  float far = 1e30f;

  float depth(const float* p) const
  {
    return -(row[0] * p[0] + row[1] * p[1] + row[2] * p[2] + row[3]);
  }
};

/// A hit in the frame the ray was given in.
struct PickRayHit {
  float s = 1.f;
  /// Outward normal of the primitive at the hit (for a triangle: the smooth
  /// normal, aligned with the geometric one). Not meaningful when `cap`.
  float n[3] = {0.f, 0.f, 1.f};
  bool inside = false; ///< the ray met the primitive from inside (back face)
  bool cap = false;    ///< flat interior cap at the near plane (impostors)
};

enum class PickRule : unsigned char {
  Impostor,
  Mesh,
};

enum class PickCap : unsigned char {
  None,
  Flat,
  Round,
  /// CGOSimpleCylinder's pointed nub (a tessellated Round end with
  /// stick_round_nub off): the body runs on PickNubShape::overlap * r past
  /// the end, then a cone of height PickNubShape::length * r closes it. Its
  /// triangle fan carries the axis as the tip's normal and radial normals on
  /// the rim, so the drawn normal turns from radial to axial toward the tip.
  Pointed,
};

/// The proportions of a PickCap::Pointed end, in units of the cylinder's
/// radius (stick_overlap and stick_nub).
struct PickNubShape {
  float overlap = 0.f;
  float length = 0.f;
};

/**
 * Where a ray enters and leaves a primitive. `has_in`/`has_out` are false when
 * the ray crosses an open (uncapped) cylinder end there: no surface is drawn
 * at that crossing.
 */
struct PickSpan {
  float s_in = 0.f, s_out = 0.f;
  float n_in[3] = {0.f, 0.f, 1.f};  ///< outward normal at the entry
  float n_out[3] = {0.f, 0.f, 1.f}; ///< outward normal at the exit
  bool has_in = false, has_out = false;
  /**
   * The far wall the impostor shader tests when the near plane cuts its
   * front surface (Impostor rule, interior cap): for a sphere its exit; for
   * a cylinder the INFINITE tube's far crossing, whatever the ends are
   * (cyl_shade's `dist2`, RendererMetal.mm), so a round or open end does not
   * change it.
   */
  float s_cap_far = 0.f;
};

namespace pickmath
{

inline double dot3(const double* u, const double* v)
{
  return u[0] * v[0] + u[1] * v[1] + u[2] * v[2];
}

inline void normalize3(double* v)
{
  double len = std::sqrt(dot3(v, v));
  if (len > 0.0) {
    v[0] /= len;
    v[1] /= len;
    v[2] /= len;
  }
}

inline void store3(float* out, const double* v)
{
  out[0] = float(v[0]);
  out[1] = float(v[1]);
  out[2] = float(v[2]);
}

/**
 * Line-sphere interval, computed from the point of closest approach so that a
 * small sphere far from the segment start stays precise.
 */
inline bool sphereInterval(const float* a, const float* d, const double* c,
    double r, double& s0, double& s1)
{
  const double dv[3] = {d[0], d[1], d[2]};
  const double dd = dot3(dv, dv);
  if (!(dd > 0.0) || !(r > 0.0))
    return false;
  const double l[3] = {c[0] - a[0], c[1] - a[1], c[2] - a[2]};
  const double tca = dot3(l, dv) / dd;
  const double q[3] = {
      a[0] + tca * dv[0] - c[0],
      a[1] + tca * dv[1] - c[1],
      a[2] + tca * dv[2] - c[2],
  };
  const double q2 = dot3(q, q);
  const double r2 = r * r;
  if (q2 > r2)
    return false;
  const double half = std::sqrt((r2 - q2) / dd);
  s0 = tca - half;
  s1 = tca + half;
  return true;
}

inline void sphereNormal(const float* a, const float* d, const double* c,
    double s, float* n)
{
  double v[3] = {
      a[0] + s * d[0] - c[0],
      a[1] + s * d[1] - c[1],
      a[2] + s * d[2] - c[2],
  };
  normalize3(v);
  store3(n, v);
}

} // namespace pickmath

/**
 * Entry and exit of the line a + s d through a sphere.
 */
inline bool pickSphere(
    const float* a, const float* d, const float* c, float r, PickSpan& span)
{
  const double cd[3] = {c[0], c[1], c[2]};
  double s0, s1;
  if (!pickmath::sphereInterval(a, d, cd, r, s0, s1))
    return false;
  span.s_in = float(s0);
  span.s_out = float(s1);
  span.s_cap_far = span.s_out;
  pickmath::sphereNormal(a, d, cd, s0, span.n_in);
  pickmath::sphereNormal(a, d, cd, s1, span.n_out);
  span.has_in = span.has_out = true;
  return true;
}

/**
 * Entry and exit of the line a + s d through a cylinder from p0 to p0 + axis
 * with radius r and the given end caps (Round is a hemisphere, so
 * Round + Round is a sausage; Pointed is shaped by `nub`).
 *
 * Mirrors the Metal cylinder impostor: the entry is the front crossing of the
 * INFINITE cylinder when it falls between the end planes; beyond an end it is
 * that end's cap (flat disc, sphere or cone), and nothing when the end is
 * open. The exit is the same construction from the back crossing. For two
 * closed ends this is exactly the convex solid's entry and exit.
 */
inline bool pickCylinder(const float* a, const float* d, const float* p0,
    const float* axis, float r, PickCap cap0, PickCap cap1, PickSpan& span,
    const PickNubShape& nub = PickNubShape())
{
  using namespace pickmath;
  const double ax[3] = {axis[0], axis[1], axis[2]};
  const double h = std::sqrt(dot3(ax, ax));
  if (!(r > 0.f))
    return false;
  const double rr = r;
  const double dv[3] = {d[0], d[1], d[2]};
  const double dd = dot3(dv, dv);
  if (!(dd > 0.0))
    return false;

  const double c0[3] = {p0[0], p0[1], p0[2]};
  const double c1[3] = {p0[0] + ax[0], p0[1] + ax[1], p0[2] + ax[2]};
  const bool pointed = cap0 == PickCap::Pointed || cap1 == PickCap::Pointed;

  // The ray in the axis frame: along the axis md + t du, across it mp + t dp.
  // (With no axis at all, u = 0 and nothing below reads the tube.)
  double u[3] = {0.0, 0.0, 0.0};
  if (h > 0.0) {
    u[0] = ax[0] / h;
    u[1] = ax[1] / h;
    u[2] = ax[2] / h;
  }
  const double m[3] = {a[0] - c0[0], a[1] - c0[1], a[2] - c0[2]};
  const double md = dot3(m, u);
  const double du = dot3(dv, u);
  const double mp[3] = {m[0] - md * u[0], m[1] - md * u[1], m[2] - md * u[2]};
  const double dp[3] = {dv[0] - du * u[0], dv[1] - du * u[1], dv[2] - du * u[2]};
  const double A = dot3(dp, dp);
  const double B = dot3(mp, dp);
  const double C = dot3(mp, mp) - rr * rr;

  // Infinite-cylinder crossings. Parallel to the axis: the ray is inside the
  // tube everywhere or nowhere, and only the end planes can stop it.
  double t0 = -1e30, t1 = 1e30;
  const bool parallel = A <= 1e-12 * dd;
  bool tube;
  if (parallel) {
    // The tube never stops the ray, so the "crossings" are at infinity and
    // resolve() goes straight to the end caps.
    tube = C <= 0.0;
  } else {
    const double disc = B * B - A * C;
    tube = disc >= 0.0;
    if (tube) {
      const double sq = std::sqrt(disc);
      t0 = (-B - sq) / A;
      t1 = (-B + sq) / A;
    }
  }

  // A (near) zero-length cylinder: RepCylBond draws a lone zero-order-bond
  // atom as one (axis 1e-4) with round caps, i.e. a sphere. The impostor
  // still decides its interior cap from the tube about that tiny axis.
  // (Pointed ends draw a double cone there, handled below.)
  if (h < 1e-3 && !pointed) {
    if (cap0 != PickCap::Round && cap1 != PickCap::Round)
      return false;
    double s0, s1;
    if (!sphereInterval(a, d, c0, r, s0, s1))
      return false;
    span.s_in = float(s0);
    span.s_out = float(s1);
    span.s_cap_far = float((h > 0.0 && tube && !parallel) ? t1 : s1);
    sphereNormal(a, d, c0, s0, span.n_in);
    sphereNormal(a, d, c0, s1, span.n_out);
    span.has_in = span.has_out = true;
    return true;
  }
  if (!tube)
    return false;
  // CGOSimpleCylinder normalizes an axis this short to nothing: no surface.
  if (!(h > 1e-8))
    return false;

  // Pointed ends move their end plane out by the overlap; the cone (tip
  // `tip` long) sits beyond it.
  const double ext0 = cap0 == PickCap::Pointed ? double(nub.overlap) * rr : 0.0;
  const double ext1 = cap1 == PickCap::Pointed ? double(nub.overlap) * rr : 0.0;
  const double z_lo = -ext0, z_hi = h + ext1;
  const double tip = std::max(0.0, double(nub.length) * rr);

  // Resolve one crossing of the infinite cylinder into a crossing of the
  // capped solid. `entering` picks the front (true) or back (false) root.
  auto resolve = [&](double t, bool entering, double& s, float* n) -> int {
    // returns 1 = surface, 0 = open end (no surface), -1 = no crossing.
    // Parallel to the axis, the ray enters through the end it moves away
    // from and leaves through the other one.
    const double z = parallel
                         ? ((entering == (du > 0)) ? z_lo - 1.0 : z_hi + 1.0)
                         : md + t * du;
    if (!parallel && z >= z_lo && z <= z_hi) {
      s = t;
      double p[3] = {m[0] + t * dv[0], m[1] + t * dv[1], m[2] + t * dv[2]};
      const double pz = dot3(p, u);
      double nn[3] = {p[0] - pz * u[0], p[1] - pz * u[1], p[2] - pz * u[2]};
      normalize3(nn);
      store3(n, nn);
      return 1;
    }
    const bool at_end0 = z < z_lo;
    const PickCap cap = at_end0 ? cap0 : cap1;
    if (cap == PickCap::None)
      return 0;
    if (cap == PickCap::Round) {
      const double* cc = at_end0 ? c0 : c1;
      double s0, s1;
      if (!sphereInterval(a, d, cc, r, s0, s1))
        return -1;
      s = entering ? s0 : s1;
      sphereNormal(a, d, cc, s, n);
      return 1;
    }
    const double plane_z = at_end0 ? z_lo : z_hi;
    const double out = at_end0 ? -1.0 : 1.0; // outward along the axis
    if (cap == PickCap::Pointed && tip > 0.0) {
      // The cone: radius r (tip - hh) / tip at height hh = out (z - plane_z)
      // in [0, tip]. With k = r / tip and tip - hh = e - f t, the crossings
      // solve |mp + t dp|^2 = k^2 (e - f t)^2.
      const double k2 = (rr / tip) * (rr / tip);
      const double e = tip - out * (md - plane_z);
      const double f = out * du;
      const double qa = A - k2 * f * f;
      const double qb = B + k2 * e * f;
      const double qc = (C + rr * rr) - k2 * e * e;
      double roots[2];
      int nroots = 0;
      if (std::fabs(qa) <= 1e-12 * (A + k2 * f * f)) {
        // Along a generator: one crossing (the other is at infinity).
        if (qb != 0.0)
          roots[nroots++] = -qc / (2.0 * qb);
      } else {
        double disc = qb * qb - qa * qc;
        // Through the tip (down the axis, say) the two roots meet; keep
        // rounding from losing them.
        if (disc < 0.0 && disc > -1e-12 * (qb * qb + std::fabs(qa * qc)))
          disc = 0.0;
        if (disc >= 0.0) {
          const double sq = std::sqrt(disc);
          roots[nroots++] = (-qb - sq) / qa;
          roots[nroots++] = (-qb + sq) / qa;
        }
      }
      // Keep the crossings on this nappe, between the rim and the tip: the
      // first one entering, the last one leaving (the solid is convex).
      const double eps = 1e-7 * (tip + rr);
      bool found = false;
      double best = 0.0;
      for (int i = 0; i < nroots; ++i) {
        const double hh = tip - (e - f * roots[i]);
        if (hh < -eps || hh > tip + eps)
          continue;
        if (!found || (entering ? roots[i] < best : roots[i] > best)) {
          best = roots[i];
          found = true;
        }
      }
      if (!found)
        return -1;
      s = best;
      // The fan's normals interpolated: the axis at the tip, radial at the
      // rim, weighted by height (the tip's barycentric weight).
      double p[3] = {m[0] + s * dv[0], m[1] + s * dv[1], m[2] + s * dv[2]};
      const double pz = dot3(p, u);
      double q[3] = {p[0] - pz * u[0], p[1] - pz * u[1], p[2] - pz * u[2]};
      normalize3(q);
      const double w = std::min(1.0, std::max(0.0, out * (pz - plane_z) / tip));
      double nn[3];
      for (int k = 0; k < 3; ++k)
        nn[k] = w * out * u[k] + (1.0 - w) * q[k];
      normalize3(nn);
      store3(n, nn);
      return 1;
    }
    // Flat (or a pointed end with no tip: a flat fan): the end plane,
    // crossed in the right direction, inside the disc. The outward normal of
    // end 0 is -u, of end 1 is +u.
    if (std::fabs(du) < 1e-300)
      return -1;
    const double sp = (plane_z - md) / du;
    // Entering through end 0 means moving along +u; through end 1, along -u.
    const bool moving_plus = du > 0;
    if (entering != (at_end0 == moving_plus))
      return -1;
    double p[3] = {m[0] + sp * dv[0], m[1] + sp * dv[1], m[2] + sp * dv[2]};
    const double pz = dot3(p, u);
    const double q[3] = {p[0] - pz * u[0], p[1] - pz * u[1], p[2] - pz * u[2]};
    if (dot3(q, q) > rr * rr)
      return -1;
    s = sp;
    double nn[3] = {out * u[0], out * u[1], out * u[2]};
    if (cap == PickCap::Pointed) {
      // The flat fan's normals: the axis at the centre, radial at the rim.
      const double rho = std::sqrt(dot3(q, q)) / rr;
      for (int k = 0; k < 3; ++k)
        nn[k] = (1.0 - rho) * out * u[k] + q[k] / rr;
      normalize3(nn);
    }
    store3(n, nn);
    return 1;
  };

  double s_in = 0.0, s_out = 0.0;
  const int rin = resolve(t0, true, s_in, span.n_in);
  const int rout = resolve(t1, false, s_out, span.n_out);
  if (rin < 0 && rout < 0)
    return false;
  if (rin < 0 || rout < 0) {
    // One side resolved and the other missed: a grazing ray past a cap rim.
    // Treat as a miss rather than invent a crossing.
    return false;
  }
  if (rin == 0 && rout == 0)
    return false; // straight through both open ends: nothing drawn
  span.has_in = rin == 1;
  span.has_out = rout == 1;
  // An open end still has a crossing parameter; keep it ordered so the
  // impostor cap test (s_in < 0 < s_out) stays meaningful.
  span.s_in = float(rin == 1 ? s_in : t0);
  span.s_out = float(rout == 1 ? s_out : t1);
  if (span.s_in > span.s_out)
    return false;
  // cyl_shade's far body crossing. Exactly parallel to the axis it has none
  // (the shader divides by zero there): fall back to the solid's exit.
  span.s_cap_far = parallel ? span.s_out : float(t1);
  return true;
}

/**
 * Double-sided Moller-Trumbore. Returns the line parameter s and the
 * barycentrics (u, v) of the crossing (weights 1-u-v, u, v for v0, v1, v2).
 */
inline bool pickTriangle(const float* a, const float* d, const float* v0,
    const float* v1, const float* v2, float& s, float& bu, float& bv)
{
  const float e1[3] = {v1[0] - v0[0], v1[1] - v0[1], v1[2] - v0[2]};
  const float e2[3] = {v2[0] - v0[0], v2[1] - v0[1], v2[2] - v0[2]};
  const float p[3] = {
      d[1] * e2[2] - d[2] * e2[1],
      d[2] * e2[0] - d[0] * e2[2],
      d[0] * e2[1] - d[1] * e2[0],
  };
  const float det = e1[0] * p[0] + e1[1] * p[1] + e1[2] * p[2];
  if (std::fabs(det) < 1e-12f)
    return false;
  const float inv = 1.f / det;
  const float t[3] = {a[0] - v0[0], a[1] - v0[1], a[2] - v0[2]};
  const float u = (t[0] * p[0] + t[1] * p[1] + t[2] * p[2]) * inv;
  if (u < 0.f || u > 1.f)
    return false;
  const float q[3] = {
      t[1] * e1[2] - t[2] * e1[1],
      t[2] * e1[0] - t[0] * e1[2],
      t[0] * e1[1] - t[1] * e1[0],
  };
  const float v = (d[0] * q[0] + d[1] * q[1] + d[2] * q[2]) * inv;
  if (v < 0.f || u + v > 1.f)
    return false;
  s = (e2[0] * q[0] + e2[1] * q[1] + e2[2] * q[2]) * inv;
  bu = u;
  bv = v;
  return true;
}

/**
 * The Mesh rule for one triangle. Metal draws both sides and culls nothing,
 * so any crossing in [smin, smax] is a hit.
 *
 * The reported normal is the smooth normal interpolated from n0..n2 at the
 * crossing. `inside` says the ray met the back face: it travels along the
 * geometric normal once that is turned to agree with the smooth one. With no
 * smooth normals (any of n0..n2 nullptr) a face has no outside: the geometric
 * normal is turned toward the ray's origin and `inside` stays false.
 */
inline bool pickTriangleMesh(const float* a, const float* d, const float* v0,
    const float* v1, const float* v2, const float* n0, const float* n1,
    const float* n2, float smin, float smax, PickRayHit& hit)
{
  using namespace pickmath;
  float s, bu, bv;
  if (!pickTriangle(a, d, v0, v1, v2, s, bu, bv))
    return false;
  if (!(s >= smin && s <= smax))
    return false;
  const double e1[3] = {double(v1[0]) - v0[0], double(v1[1]) - v0[1],
      double(v1[2]) - v0[2]};
  const double e2[3] = {double(v2[0]) - v0[0], double(v2[1]) - v0[1],
      double(v2[2]) - v0[2]};
  double g[3] = {
      e1[1] * e2[2] - e1[2] * e2[1],
      e1[2] * e2[0] - e1[0] * e2[2],
      e1[0] * e2[1] - e1[1] * e2[0],
  };
  const double dv[3] = {d[0], d[1], d[2]};
  double n[3] = {g[0], g[1], g[2]};
  bool smooth = false;
  if (n0 && n1 && n2) {
    const double w = 1.0 - bu - bv;
    for (int k = 0; k < 3; ++k)
      n[k] = w * n0[k] + double(bu) * n1[k] + double(bv) * n2[k];
    smooth = dot3(n, n) > 1e-20;
    if (!smooth)
      std::copy_n(g, 3, n);
  }
  if (smooth) {
    if (dot3(g, n) < 0.0) {
      g[0] = -g[0];
      g[1] = -g[1];
      g[2] = -g[2];
    }
    hit.inside = dot3(g, dv) > 0.0;
  } else {
    if (dot3(n, dv) > 0.0) {
      n[0] = -n[0];
      n[1] = -n[1];
      n[2] = -n[2];
    }
    hit.inside = false;
  }
  normalize3(n);
  store3(hit.n, n);
  hit.s = s;
  hit.cap = false;
  return true;
}

/**
 * Apply a clip rule to a primitive's span. Returns true and fills `hit`
 * (s, normal, inside, cap) when the primitive is what the ray sees within
 * [smin, smax].
 *
 *  - Impostor: only the front surface exists. An entry in [smin, smax] is a
 *    hit. If the near plane (smin) cuts in front of it, the hit is a flat
 *    cap at smin when `cap_on` and the shader's far wall is behind the plane
 *    (s_cap_far > smin), else the primitive is see-through and the ray
 *    carries on. An open end in front shows nothing.
 *  - Mesh: the first drawn crossing inside the window; when the entry is
 *    clipped away (or open) the far wall is seen from inside.
 */
inline bool pickApplyRule(PickRule rule, bool cap_on, const PickSpan& span,
    float smin, float smax, PickRayHit& hit)
{
  if (smin > smax)
    return false;
  if (rule == PickRule::Impostor) {
    if (!span.has_in)
      return false;
    if (span.s_in >= smin) {
      if (span.s_in > smax)
        return false;
      hit.s = span.s_in;
      std::copy_n(span.n_in, 3, hit.n);
      hit.inside = false;
      hit.cap = false;
      return true;
    }
    if (cap_on && span.s_cap_far > smin) {
      hit.s = smin;
      hit.inside = false;
      hit.cap = true;
      return true;
    }
    return false;
  }

  if (span.has_in && span.s_in >= smin && span.s_in <= smax) {
    hit.s = span.s_in;
    std::copy_n(span.n_in, 3, hit.n);
    hit.inside = false;
    hit.cap = false;
    return true;
  }
  if (span.has_out && (!span.has_in || span.s_in < smin) &&
      span.s_out >= smin && span.s_out <= smax) {
    hit.s = span.s_out;
    std::copy_n(span.n_out, 3, hit.n);
    hit.inside = true;
    hit.cap = false;
    return true;
  }
  return false;
}
