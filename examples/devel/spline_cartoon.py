"""
spline_cartoon.py -- ChimeraX-style ribbon prototype for RayMol, Python only.

Replaces the protein cartoon of an object with a CGO triangle mesh built the
way ChimeraX builds ribbons:

  * one natural cubic spline through the (strand-straightened) CA trace,
  * ndiv samples per residue, path extrapolated 0.3 residue past each end,
  * peptide-plane normals (O - CA) parallel-transported along the path with a
    sigmoid twist distribution so the frame lands on each residue's normal,
  * per-residue front/back half cross sections (coil tube, helix oval,
    faceted strand rectangle, strand arrow over the front half of the last
    strand residue).

Pure Python (no numpy) so it runs inside the RayMol app bundle.

Usage inside RayMol / MCP run_python:

    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "spline_cartoon", "/Users/javier/repos/RayMol/examples/devel/spline_cartoon.py")
    sc = importlib.util.module_from_spec(spec); spec.loader.exec_module(sc)
    sc.show("2kpp", ndiv=20)         # builds 2kpp_spline, skips native protein cartoon
    sc.hide("2kpp")                  # removes the CGO and restores the cartoon

or, after `run examples/devel/spline_cartoon.py` in the RayMol command line:

    spline_cartoon 2kpp, ndiv=20
    spline_cartoon_hide 2kpp
"""

import math

from pymol import cmd, cgo

# ---------------------------------------------------------------- geometry

STRAND_XS = (1.0, 0.2)           # half-width along normal, half-thickness (Angstrom)
# Arrow styles: list of (front scale, back scale) half-segments, applied to the
# last half-residues of the strand (ChimeraX: one half residue, 2x wide;
# pymol: one full residue, 1.5x wide, tapering to the coil radius).
ARROW_STYLES = {
    "chimerax": [((2.0, 0.2), (0.2, 0.2))],
    "pymol": [((1.5, 0.2), (0.85, 0.2)), ((0.85, 0.2), (0.2, 0.2))],
}
ARROW_STYLE = "pymol"
HELIX_XS = (1.0, 0.2)            # oval helix half axes
COIL_RADIUS = 0.2
ROUND_SIDES = 12
END_EXTEND = 0.3                 # residues of spline extrapolated past chain ends
STRAND_SMOOTH = 0.7              # ChimeraX ribbon_adjust default for strands
FLIP_LIMIT = 0.6 * math.pi       # ChimeraX flip threshold

COIL, HELIX, STRAND, ARROW = "coil", "helix", "strand", "arrow"

# residue classes
RC_COIL, RC_HSTART, RC_HMID, RC_HEND, RC_SSTART, RC_SMID, RC_SEND = range(7)


def _sub(a, b): return (a[0] - b[0], a[1] - b[1], a[2] - b[2])
def _add(a, b): return (a[0] + b[0], a[1] + b[1], a[2] + b[2])
def _scale(a, s): return (a[0] * s, a[1] * s, a[2] * s)
def _dot(a, b): return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
def _cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])
def _len(a): return math.sqrt(_dot(a, a))
def _norm(a):
    l = _len(a)
    return (a[0] / l, a[1] / l, a[2] / l) if l > 1e-12 else (0.0, 0.0, 0.0)
def _ortho(v, t):
    """component of v orthogonal to unit vector t"""
    return _sub(v, _scale(t, _dot(v, t)))
def _rotate(v, axis, ang):
    """Rodrigues rotation of v about unit axis by ang"""
    c, s = math.cos(ang), math.sin(ang)
    return _add(_add(_scale(v, c), _scale(_cross(axis, v), s)),
                _scale(axis, _dot(axis, v) * (1.0 - c)))
def _dihedral(u, v, t):
    """signed angle from u to v about unit axis t (both roughly perpendicular to t)"""
    return math.atan2(_dot(t, _cross(u, v)), _dot(u, v))


# ---------------------------------------------------------------- spline

class NaturalCubic:
    """Natural cubic spline through points at integer parameters 0..n-1."""

    def __init__(self, pts):
        self.n = n = len(pts)
        self.pts = pts
        self.coef = []            # per interval, per axis: (a, b, c, d)
        if n < 2:
            return
        m = [[0.0] * n for _ in range(3)]
        if n > 2:
            for ax in range(3):
                y = [p[ax] for p in pts]
                # tridiagonal: M[i-1] + 4 M[i] + M[i+1] = 6 (y[i+1]-2y[i]+y[i-1])
                k = n - 2
                diag = [4.0] * k
                rhs = [6.0 * (y[i + 1] - 2.0 * y[i] + y[i - 1]) for i in range(1, n - 1)]
                for i in range(1, k):
                    w = 1.0 / diag[i - 1]
                    diag[i] -= w
                    rhs[i] -= w * rhs[i - 1]
                sol = [0.0] * k
                sol[-1] = rhs[-1] / diag[-1]
                for i in range(k - 2, -1, -1):
                    sol[i] = (rhs[i] - sol[i + 1]) / diag[i]
                for i in range(k):
                    m[ax][i + 1] = sol[i]
        for i in range(n - 1):
            per_axis = []
            for ax in range(3):
                y0, y1 = pts[i][ax], pts[i + 1][ax]
                m0, m1 = m[ax][i], m[ax][i + 1]
                a = y0
                b = (y1 - y0) - (2.0 * m0 + m1) / 6.0
                c = m0 / 2.0
                d = (m1 - m0) / 6.0
                per_axis.append((a, b, c, d))
            self.coef.append(per_axis)

    def eval(self, t):
        """position and unit tangent at parameter t (extrapolates past ends)"""
        i = int(math.floor(t))
        i = max(0, min(self.n - 2, i))
        s = t - i
        p, d = [], []
        for a, b, c, dd in self.coef[i]:
            p.append(a + s * (b + s * (c + s * dd)))
            d.append(b + s * (2.0 * c + 3.0 * s * dd))
        return tuple(p), _norm(tuple(d))


# ---------------------------------------------------------------- data

def _collect(obj, state):
    """Return list of segments; each segment is a list of residue dicts in
    chain order with keys ca, o, ss, color."""
    res = []
    cmd.iterate_state(
        state, "(%s) and polymer.protein and name CA and not alt B+C+D" % obj,
        "res.append(dict(key=(segi, chain, resi), ss=ss, color=color, ca=(x, y, z)))",
        space={"res": res})
    oxy = {}
    cmd.iterate_state(
        state, "(%s) and polymer.protein and name O and not alt B+C+D" % obj,
        "oxy.__setitem__((segi, chain, resi), (x, y, z))", space={"oxy": oxy})
    segs, cur, last = [], [], None
    for r in res:
        r["o"] = oxy.get(r["key"])
        r["sel"] = "(%s) and segi '%s' and chain '%s' and resi %s" % (
            obj, r["key"][0], r["key"][1], r["key"][2])
        brk = (last is not None and (
            last["key"][:2] != r["key"][:2] or _len(_sub(r["ca"], last["ca"])) > 4.5))
        if brk and cur:
            segs.append(cur)
            cur = []
        cur.append(r)
        last = r
    if cur:
        segs.append(cur)
    return [s for s in segs if len(s) >= 2]


def _classify(seg):
    """ChimeraX-style residue classes; single-residue helices/strands -> coil."""
    n = len(seg)
    kind = []
    for r in seg:
        s = r["ss"]
        kind.append("H" if s in ("H", "G", "I") else "S" if s == "S" else "L")
    # dissolve singletons
    for i in range(n):
        if kind[i] != "L":
            prev = kind[i - 1] if i > 0 else None
            nxt = kind[i + 1] if i < n - 1 else None
            if prev != kind[i] and nxt != kind[i]:
                kind[i] = "L"
    rc = []
    for i in range(n):
        k = kind[i]
        if k == "L":
            rc.append(RC_COIL)
            continue
        first = (i == 0 or kind[i - 1] != k)
        lastr = (i == n - 1 or kind[i + 1] != k)
        if k == "H":
            rc.append(RC_HSTART if first else RC_HEND if lastr else RC_HMID)
        else:
            rc.append(RC_SSTART if first else RC_SEND if lastr else RC_SMID)
    return rc, kind


def _smooth_strands(seg, rc):
    """ChimeraX _smooth_strand: pull strand CAs toward the neighbour average."""
    n = len(rc)
    i = 0
    while i < n:
        if rc[i] == RC_SSTART:
            j = i
            while j < n and rc[j] != RC_SEND:
                j += 1
            if j < n and j - i + 1 > 2:
                pts = [seg[k]["ca"] for k in range(i, j + 1)]
                m = len(pts)
                ideal = list(pts)
                for k in range(1, m - 1):
                    ideal[k] = _scale(_add(_add(_scale(pts[k], 2.0), pts[k - 1]), pts[k + 1]), 0.25)
                f = 0.99 if m == 3 else 1.0
                ideal[0] = _sub(pts[0], _scale(_sub(ideal[1], pts[1]), f))
                ideal[-1] = _sub(pts[-1], _scale(_sub(ideal[-2], pts[-2]), f))
                for k in range(m):
                    off = _scale(_sub(ideal[k], pts[k]), STRAND_SMOOTH)
                    r = seg[i + k]
                    r["ca"] = _add(r["ca"], off)
                    if r["o"] is not None:
                        r["o"] = _add(r["o"], off)
            i = j + 1
        else:
            i += 1


# ---------------------------------------------------------------- path

def _sigmoid01(f):
    s = lambda x: 1.0 / (1.0 + math.exp(-8.0 * (x - 0.5)))
    return (s(f) - s(0.0)) / (s(1.0) - s(0.0))


def _control_normals(seg, kind, tangents, i0, ndiv, flatten):
    """Per-residue target normals, ChimeraX style:
    strands -> peptide guide (O - CA), helices/coils -> path-plane normal
    cross(prev - cur, next - cur) with sign continuity.  Optional RayMol-style
    flattening averages the strand normals along each strand run."""
    n = len(seg)
    pts = [r["ca"] for r in seg]
    ctan = [tangents[i0 + i * ndiv] for i in range(n)]

    def fallback(tg):
        up = (0.0, 0.0, 1.0) if abs(tg[2]) < 0.9 else (1.0, 0.0, 0.0)
        return _norm(_cross(tg, up))

    # path-plane normals
    plane = [None] * n
    for i in range(1, n - 1):
        v = _cross(_sub(pts[i - 1], pts[i]), _sub(pts[i + 1], pts[i]))
        v = _ortho(v, ctan[i])
        if _len(v) > 1e-3:
            plane[i] = _norm(v)
    # fill ends / degenerate (collinear) points from neighbours
    for i in range(n):
        if plane[i] is None:
            src = None
            for j in list(range(i + 1, n)) + list(range(i - 1, -1, -1)):
                if plane[j] is not None:
                    src = plane[j]
                    break
            plane[i] = _norm(_ortho(src, ctan[i])) if src is not None else fallback(ctan[i])
            if _len(plane[i]) < 0.5:
                plane[i] = fallback(ctan[i])
    # sign continuity
    for i in range(1, n):
        if _dot(plane[i], plane[i - 1]) < 0.0:
            plane[i] = _scale(plane[i], -1.0)

    # peptide guides for strands
    guides = list(plane)
    for i, r in enumerate(seg):
        if kind[i] != "S":
            continue
        if r["o"] is not None:
            g = _ortho(_sub(r["o"], r["ca"]), ctan[i])
            if _len(g) > 1e-3:
                guides[i] = _norm(g)

    # optional flattening of strand runs (RayMol cartoon_flat_sheets analogue):
    # align signs along the run, then box-average, then re-orthogonalize
    if flatten > 0:
        i = 0
        while i < n:
            if kind[i] != "S":
                i += 1
                continue
            j = i
            while j + 1 < n and kind[j + 1] == "S":
                j += 1
            run = list(range(i, j + 1))
            for k in run[1:]:
                if _dot(guides[k], guides[k - 1]) < 0.0:
                    guides[k] = _scale(guides[k], -1.0)
            for _ in range(flatten):
                avg = {}
                for k in run:
                    acc = guides[k]
                    if k - 1 >= i:
                        acc = _add(acc, guides[k - 1])
                    if k + 1 <= j:
                        acc = _add(acc, guides[k + 1])
                    avg[k] = acc
                for k in run:
                    g = _norm(_ortho(avg[k], ctan[k]))
                    if _len(g) > 0.5:
                        guides[k] = g
            i = j + 1
    return guides


def _build_path(seg, kind, ndiv, flatten=0):
    """Sample the spline. Returns (centers, tangents, normals, i0) where
    control point i sits at sample index i0 + i*ndiv."""
    n = len(seg)
    pts = [r["ca"] for r in seg]
    sp = NaturalCubic(pts)
    h_end = max(1, int(round(END_EXTEND * ndiv)))
    i0 = h_end
    total = (n - 1) * ndiv + 2 * h_end + 1
    centers, tangents = [], []
    for j in range(total):
        t = (j - i0) / float(ndiv)
        c, tg = sp.eval(t)
        centers.append(c)
        tangents.append(tg)

    guides = _control_normals(seg, kind, tangents, i0, ndiv, flatten)

    # parallel transport + per-segment twist to land on each residue's normal
    normals = [None] * total
    nrm = guides[0]
    normals[0] = _norm(_ortho(nrm, tangents[0]))

    def transport(k_from, k_to):
        nv = normals[k_from]
        for k in range(k_from + 1, k_to + 1):
            t0, t1 = tangents[k - 1], tangents[k]
            axis = _cross(t0, t1)
            al = _len(axis)
            if al > 1e-8:
                ang = math.atan2(al, _dot(t0, t1))
                nv = _rotate(nv, _scale(axis, 1.0 / al), ang)
            nv = _norm(_ortho(nv, t1))
            normals[k] = nv

    # leading tail (index 0 .. i0): start from the guide at control 0, transported backwards
    for k in range(i0, -1, -1):
        normals[k] = None
    normals[i0] = guides[0]
    # backwards transport
    nv = guides[0]
    for k in range(i0 - 1, -1, -1):
        t0, t1 = tangents[k + 1], tangents[k]
        axis = _cross(t0, t1)
        al = _len(axis)
        if al > 1e-8:
            nv = _rotate(nv, _scale(axis, 1.0 / al), math.atan2(al, _dot(t0, t1)))
        nv = _norm(_ortho(nv, t1))
        normals[k] = nv

    for i in range(n - 1):
        a, b = i0 + i * ndiv, i0 + (i + 1) * ndiv
        transport(a, b)
        target = _norm(_ortho(guides[i + 1], tangents[b]))
        allow_flip = not (kind[i] == "H" and kind[i + 1] == "H")
        ang = _dihedral(normals[b], target, tangents[b])
        if allow_flip and abs(ang) > FLIP_LIMIT:
            target = _scale(target, -1.0)
            ang = _dihedral(normals[b], target, tangents[b])
        # distribute the twist along the segment with a sigmoid
        for k in range(a + 1, b + 1):
            f = (k - a) / float(ndiv)
            normals[k] = _norm(_rotate(normals[k], tangents[k], ang * _sigmoid01(f)))
        normals[b] = target
    # trailing tail
    transport(i0 + (n - 1) * ndiv, total - 1)
    return centers, tangents, normals, i0


# ---------------------------------------------------------------- cross sections

def _xs_round(a, b):
    """smooth oval: list of (cn, cb, nn, nb)"""
    out = []
    for k in range(ROUND_SIDES):
        th = 2.0 * math.pi * k / ROUND_SIDES
        c, s = math.cos(th), math.sin(th)
        nn, nb = c / a, s / b
        l = math.hypot(nn, nb)
        out.append((a * c, b * s, nn / l, nb / l))
    return out


def _xs_for(kind_name):
    if kind_name == COIL:
        return ("round", _xs_round(COIL_RADIUS, COIL_RADIUS), None)
    if kind_name == HELIX:
        return ("round", _xs_round(HELIX_XS[0], HELIX_XS[1]), None)
    if kind_name == STRAND:
        return ("rect", STRAND_XS, STRAND_XS)
    if kind_name.startswith(ARROW):
        front, back = ARROW_STYLES[ARROW_STYLE][int(kind_name[len(ARROW):])]
        return ("rect", front, back)
    raise ValueError(kind_name)


def _differs(a, b):
    """Do two adjacent half-section kinds need a cap between them?"""
    if a is None or b is None:
        return True
    if a.startswith(ARROW) and b.startswith(ARROW):
        return False          # consecutive arrow pieces are continuous
    return a != b


def _assign(rc0, rc1, rc2):
    """front/back cross-section kinds for residue with class rc1 (ChimeraX assign)."""
    parts = ARROW_STYLES[ARROW_STYLE]
    last_arrow = ARROW + str(len(parts) - 1)
    # with a two-piece arrow the residue before the strand end carries piece 0
    pre_arrow = (ARROW + "0") if (len(parts) == 2 and rc2 == RC_SEND) else None
    if rc1 == RC_COIL:
        return COIL, COIL
    if rc1 == RC_HMID:
        return HELIX, HELIX
    if rc1 == RC_SMID:
        return STRAND, (pre_arrow or STRAND)
    if rc1 == RC_HSTART:
        return COIL, HELIX
    if rc1 == RC_HEND:
        return HELIX, COIL
    if rc1 == RC_SSTART:
        return COIL, (pre_arrow or STRAND)
    if rc1 == RC_SEND:
        return last_arrow, COIL
    return COIL, COIL


# ---------------------------------------------------------------- extrusion

class Mesh:
    def __init__(self):
        self.tris = []      # list of (color, [(v, n), (v, n), (v, n)])

    def tri(self, color, v0, n0, v1, n1, v2, n2):
        # keep winding consistent with the supplied normals
        g = _cross(_sub(v1, v0), _sub(v2, v0))
        if _dot(g, _add(_add(n0, n1), n2)) < 0.0:
            v1, n1, v2, n2 = v2, n2, v1, n1
        self.tris.append((color, (v0, n0, v1, n1, v2, n2)))


def _ring_rect(c, t, nrm, bnm, hw, ht):
    """4 corners of a rectangle at this path sample; also 4 face normals."""
    corners = []
    for sn, sb in ((1, 1), (-1, 1), (-1, -1), (1, -1)):
        corners.append(_add(c, _add(_scale(nrm, sn * hw), _scale(bnm, sb * ht))))
    # faces between corner k and k+1: 0-1 is +binormal face, 1-2 is -normal, 2-3 -binormal, 3-0 +normal
    faces = [bnm, _scale(nrm, -1.0), _scale(bnm, -1.0), nrm]
    return corners, faces


def _extrude(mesh, color, centers, tangents, normals, idx, xs, cap_front, cap_back):
    """Extrude cross section xs along sample indices idx."""
    style, front, back = xs
    m = len(idx)
    if m < 2:
        return
    rings, ringn = [], []
    if style == "round":
        for j, k in enumerate(idx):
            c, t, nrm = centers[k], tangents[k], normals[k]
            bnm = _norm(_cross(t, nrm))
            ring, rn = [], []
            for cn, cb, nn, nb in front:
                ring.append(_add(c, _add(_scale(nrm, cn), _scale(bnm, cb))))
                rn.append(_norm(_add(_scale(nrm, nn), _scale(bnm, nb))))
            rings.append(ring)
            ringn.append(rn)
        s = len(front)
        for j in range(m - 1):
            for a in range(s):
                b = (a + 1) % s
                mesh.tri(color, rings[j][a], ringn[j][a], rings[j][b], ringn[j][b],
                         rings[j + 1][a], ringn[j + 1][a])
                mesh.tri(color, rings[j][b], ringn[j][b], rings[j + 1][b], ringn[j + 1][b],
                         rings[j + 1][a], ringn[j + 1][a])
        if cap_front:
            _cap(mesh, color, rings[0], _scale(tangents[idx[0]], -1.0))
        if cap_back:
            _cap(mesh, color, rings[-1], tangents[idx[-1]])
    else:
        (hw0, ht0), (hw1, ht1) = front, back
        for j, k in enumerate(idx):
            f = j / float(m - 1)
            hw = hw0 + (hw1 - hw0) * f
            ht = ht0 + (ht1 - ht0) * f
            c, t, nrm = centers[k], tangents[k], normals[k]
            bnm = _norm(_cross(t, nrm))
            corners, faces = _ring_rect(c, t, nrm, bnm, hw, ht)
            rings.append(corners)
            ringn.append(faces)
        for j in range(m - 1):
            for a in range(4):
                b = (a + 1) % 4
                # faceted: both rings use this face's normal; for the arrow the
                # side faces tilt, so blend the geometric slant in.
                fn0, fn1 = ringn[j][a], ringn[j + 1][a]
                if front != back:
                    g = _norm(_cross(_sub(rings[j][b], rings[j][a]),
                                     _sub(rings[j + 1][a], rings[j][a])))
                    if _dot(g, fn0) < 0.0:
                        g = _scale(g, -1.0)
                    fn0 = fn1 = g
                mesh.tri(color, rings[j][a], fn0, rings[j][b], fn0, rings[j + 1][a], fn1)
                mesh.tri(color, rings[j][b], fn0, rings[j + 1][b], fn1, rings[j + 1][a], fn1)
        if cap_front:
            _cap(mesh, color, rings[0], _scale(tangents[idx[0]], -1.0))
        if cap_back:
            _cap(mesh, color, rings[-1], tangents[idx[-1]])


def _cap(mesh, color, ring, nrm):
    for a in range(1, len(ring) - 1):
        mesh.tri(color, ring[0], nrm, ring[a], nrm, ring[a + 1], nrm)


# ---------------------------------------------------------------- assembly

def _build_segment(mesh, seg, ndiv, strands_only, flatten, smooth_cycles=1):
    rc, kind = _classify(seg)
    for _ in range(smooth_cycles):
        _smooth_strands(seg, rc)
    centers, tangents, normals, i0 = _build_path(seg, kind, ndiv, flatten)
    half = ndiv // 2
    total = len(centers)
    n = len(seg)
    xs_front, xs_back = [], []
    for i in range(n):
        r0 = rc[i - 1] if i > 0 else RC_COIL
        r2 = rc[i + 1] if i < n - 1 else RC_COIL
        f, b = _assign(r0, rc[i], r2)
        xs_front.append(f)
        xs_back.append(b)
    for i in range(n):
        if strands_only and kind[i] != "S":
            continue
        color = cmd.get_color_tuple(seg[i]["color"])
        c = i0 + i * ndiv
        lo = max(0, c - half)
        hi = min(total - 1, c + half)
        f, b = xs_front[i], xs_back[i]
        prev_b = xs_back[i - 1] if i > 0 else None
        next_f = xs_front[i + 1] if i < n - 1 else None
        if strands_only:
            if i == 0 or kind[i - 1] != "S":
                prev_b = None
            if i == n - 1 or kind[i + 1] != "S":
                next_f = None
        cap_start = _differs(prev_b, f)
        mid_cap = _differs(f, b)
        cap_end = _differs(b, next_f)
        _extrude(mesh, color, centers, tangents, normals, list(range(lo, c + 1)),
                 _xs_for(f), cap_start, mid_cap)
        _extrude(mesh, color, centers, tangents, normals, list(range(c, hi + 1)),
                 _xs_for(b), mid_cap, cap_end)


def _to_cgo(mesh, alpha):
    out = []
    if alpha < 1.0:
        out += [cgo.ALPHA, float(alpha)]
    out += [cgo.BEGIN, cgo.TRIANGLES]
    last_color = None
    for color, (v0, n0, v1, n1, v2, n2) in mesh.tris:
        if color != last_color:
            out += [cgo.COLOR, color[0], color[1], color[2]]
            last_color = color
        out += [cgo.NORMAL, n0[0], n0[1], n0[2], cgo.VERTEX, v0[0], v0[1], v0[2],
                cgo.NORMAL, n1[0], n1[1], n1[2], cgo.VERTEX, v1[0], v1[1], v1[2],
                cgo.NORMAL, n2[0], n2[1], n2[2], cgo.VERTEX, v2[0], v2[1], v2[2]]
    out += [cgo.END]
    return out


def _cgo_name(obj):
    return "%s_spline" % obj


def show(selection="all", ndiv=20, flatten=3, smooth_cycles=3, strands_only=0,
         alpha=1.0, state=1, quiet=1):
    """Build the spline ribbon for every molecular object in selection.

    ndiv           samples per residue (ChimeraX uses 20 at full detail)
    flatten        cycles of strand-normal averaging along each strand
                   (0 = ChimeraX behaviour, 3 = RayMol cartoon_flat_sheets look)
    smooth_cycles  passes of ChimeraX strand straightening (1 = ChimeraX,
                   3 = about as straight as RayMol's flat sheets)
    """
    ndiv = int(ndiv)
    if ndiv % 2:
        ndiv += 1
    strands_only = int(strands_only)
    for obj in cmd.get_object_list("(%s)" % selection):
        segs = _collect(obj, int(state))
        mesh = Mesh()
        for seg in segs:
            _build_segment(mesh, seg, ndiv, strands_only, int(flatten), int(smooth_cycles))
        name = _cgo_name(obj)
        cmd.delete(name)
        if not mesh.tris:
            continue
        cmd.load_cgo(_to_cgo(mesh, float(alpha)), name, zoom=0)
        skip = "(%s) and polymer.protein" % obj
        if strands_only:
            skip += " and ss S"
        cmd.cartoon("skip", skip)
        if not int(quiet):
            print(" spline_cartoon: %s -> %s, %d triangles, %d segments" % (
                obj, name, len(mesh.tris), len(segs)))


def hide(selection="all"):
    """Remove the spline ribbon CGOs and restore the native cartoon."""
    for obj in cmd.get_object_list("(%s)" % selection):
        cmd.delete(_cgo_name(obj))
        cmd.cartoon("automatic", "(%s) and polymer.protein" % obj)


cmd.extend("spline_cartoon", show)
cmd.extend("spline_cartoon_hide", hide)
