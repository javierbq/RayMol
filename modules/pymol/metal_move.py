"""Unified molecular-frame Move gizmo for the Metal backend.

One gizmo per active object, anchored on a per-object orthonormal frame derived
from molecular features:

    origin = center of mass
    x      = normalize(Cterm - COM)
    z      = normalize((Nterm - COM) x x)     (perpendicular to the N.COM.C plane)
    y      = z x x                             (right-handed)

Termini are the whole object's first/last polymer CA (atom order = N->C). Objects
with no protein termini fall back to PCA principal axes; a last resort is world
axes. The frame is computed once in the object's LOCAL coordinates and displayed
through the object's current transform (TTT), so it tumbles with the molecule.

The SAME frame drives both translation (drag an axis arrow) and rotation (drag a
ring) — there is no mode switch. All manipulation is non-destructive TTT
(cmd.translate/cmd.rotate with object=); Reset is matrix_reset. Gizmo geometry is
written to <tmpdir>/pymol_gizmo_<pid>.json, which Swift reads back synchronously.

NDC convention matches metal_pick / the gesture handlers: bottom-left origin,
+x right, +y up, in [-1, 1].
"""
import json
import math

from pymol import cmd
from pymol import raymol_tmp

# Module state --------------------------------------------------------------
_active = None          # active object name, or None
_aspect = 1.0           # last viewport aspect (width / height)
_drag = None            # in-flight drag: {handle, px, py, dist, deg, dx, dy}
_hover = ''             # hovered handle name ('x'/'rx'/... or '') for highlight
# Per-object model-space frame: obj -> (com[3], (bx, by, bz)) unit column vectors.
_frame = {}
# Adjust-frame mode: when True the gizmo controls EDIT the gizmo's own frame
# (origin + inclination) instead of moving the structure. The gizmo renders gray
# + semitransparent as a signal. Driven by Shift-held (macOS) or an overlay toggle.
_adjust = False
# Per-object CUSTOM frame override in MODEL coords: obj -> (com, (bx,by,bz), radius),
# same shape as _frame. When present it REPLACES the auto molecular frame (so all
# normal translate/rotate pivots about this custom origin/axes). Edited in adjust
# mode; cleared by reset_gizmo. Persists across move-mode enter/leave.
_frame_override = {}

# The gizmo is drawn as a real 3D CGO object (lit tubes, like sticks) so it wraps
# the molecule with proper depth. It is built once in the object's LOCAL frame and
# rides along by copying the molecule's TTT (no per-frame rebuild); the 2D
# projection below is used only for hit-testing.
_GIZMO_OBJ = '_move_gizmo'
_COL = {'x': (1.0, 0.36, 0.36), 'y': (0.37, 0.84, 0.41), 'z': (0.30, 0.48, 1.0)}

# Gizmo size scales with the object's RADIUS OF GYRATION (world Angstroms) — a
# robust "protein radius" that, unlike the max-extent bounding radius, isn't
# inflated by a flexible terminus. So the gizmo stays proportional to the bulk of
# the molecule as you zoom, wrapping the core rather than dominating the view.
_AXIS_FRAC = 1.35       # axis arrow length as a multiple of Rg
_RING_FRAC = 1.1        # rotation ring radius as a multiple of Rg
_MIN_RADIUS = 3.0       # Angstrom floor so tiny objects still get a visible gizmo
_RING_SEG = 48
_ELEM_MASS = {'H': 1.008, 'C': 12.011, 'N': 14.007, 'O': 15.999, 'S': 32.06,
              'P': 30.974, 'FE': 55.845, 'ZN': 65.38, 'MG': 24.305,
              'CA': 40.078, 'NA': 22.99, 'CL': 35.45, 'K': 39.098}
_PATH = raymol_tmp.channel_path('pymol_gizmo')


# --- vector helpers ---------------------------------------------------------

def _sub(a, b):
    return [a[0] - b[0], a[1] - b[1], a[2] - b[2]]


def _cross(a, b):
    return [a[1] * b[2] - a[2] * b[1],
            a[2] * b[0] - a[0] * b[2],
            a[0] * b[1] - a[1] * b[0]]


def _dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def _norm(v):
    n = math.sqrt(_dot(v, v))
    return [v[0] / n, v[1] / n, v[2] / n] if n > 1e-9 else None


def _world_to_model_vec(obj, wv):
    """Rotate a WORLD-space displacement into the object's MODEL frame (R^T · wv),
    so a screen-space drag can edit a frame stored in model coords."""
    try:
        m = cmd.get_object_matrix(obj)
    except Exception:
        m = None
    if not m or len(m) < 16:
        return list(wv)
    return [m[0] * wv[0] + m[4] * wv[1] + m[8] * wv[2],
            m[1] * wv[0] + m[5] * wv[1] + m[9] * wv[2],
            m[2] * wv[0] + m[6] * wv[1] + m[10] * wv[2]]


def _rotate_basis(basis, axis, theta):
    """Rigidly rotate an orthonormal basis about `axis` by `theta` (Rodrigues),
    re-orthonormalizing to prevent drift over many small steps."""
    k = _norm(axis)
    if k is None:
        return basis
    ct, st = math.cos(theta), math.sin(theta)

    def rod(v):
        kv = _dot(k, v)
        kxv = _cross(k, v)
        return [v[i] * ct + kxv[i] * st + k[i] * kv * (1.0 - ct) for i in range(3)]

    nb = [rod(basis[0]), rod(basis[1]), rod(basis[2])]
    x = _norm(nb[0]) or basis[0]
    z = _norm(_cross(x, nb[1]))
    if z is None:
        return basis
    y = _cross(z, x)
    return (x, y, z)


# --- View / projection (mirrors metal_pick) --------------------------------

def _view_params(aspect):
    try:
        v = cmd.get_view()
    except Exception:
        return None
    if not v:
        return None
    if len(v) >= 25:
        r0 = (v[0], v[4], v[8]); r1 = (v[1], v[5], v[9]); r2 = (v[2], v[6], v[10])
        t = (v[16], v[17], v[18]); o = (v[19], v[20], v[21]); fov = abs(v[24])
    else:  # 18-float embedded layout (what this build returns)
        r0 = (v[0], v[3], v[6]); r1 = (v[1], v[4], v[7]); r2 = (v[2], v[5], v[8])
        t = (v[9], v[10], v[11]); o = (v[12], v[13], v[14]); fov = abs(v[17])
    if fov <= 1.0:
        try:
            fov = cmd.get_setting_float('field_of_view')
        except Exception:
            fov = 20.0
    fov_width = 2.0 * math.tan(math.radians(fov) / 2.0)
    tan_half = math.tan(fov_width / 2.0)
    if tan_half <= 0.0 or aspect <= 0.0:
        return None
    return (r0, r1, r2, t, o, tan_half, aspect)


def _project(params, p):
    r0, r1, r2, t, o, tan_half, aspect = params
    dx = p[0] - o[0]; dy = p[1] - o[1]; dz = p[2] - o[2]
    ex = r0[0] * dx + r0[1] * dy + r0[2] * dz + t[0]
    ey = r1[0] * dx + r1[1] * dy + r1[2] * dz + t[1]
    ez = r2[0] * dx + r2[1] * dy + r2[2] * dz + t[2]
    depth = -ez
    if depth <= 0.01:
        return None
    half_h = depth * tan_half
    half_w = half_h * aspect
    return (ex / half_w, ey / half_h, depth)


def _axis_screen_dir(params, center, axis):
    """Screen displacement (ndc) of a 1 Angstrom step along `axis` at `center`."""
    c = _project(params, center)
    a = _project(params, [center[0] + axis[0], center[1] + axis[1], center[2] + axis[2]])
    if c is None or a is None:
        return None
    return (a[0] - c[0], a[1] - c[1])


def _object_exists(obj):
    if not obj:
        return False
    try:
        return obj in (cmd.get_names('objects') or [])
    except Exception:
        return False


# --- Per-object molecular frame --------------------------------------------

def _model_com(obj):
    """Mass-weighted center of mass in MODEL (untransformed) coordinates."""
    acc = [0.0, 0.0, 0.0, 0.0]
    try:
        cmd.iterate_state(
            1, '(%s)' % obj,
            'm = MASS.get(elem.upper(), 12.0); '
            'acc[0] += m * x; acc[1] += m * y; acc[2] += m * z; acc[3] += m',
            space={'acc': acc, 'MASS': _ELEM_MASS})
    except Exception:
        return None
    if acc[3] <= 0:
        return None
    return [acc[0] / acc[3], acc[1] / acc[3], acc[2] / acc[3]]


def _termini(obj):
    """(N-term CA, C-term CA) in model coords — first/last polymer CA in atom
    order (files run N->C). None if fewer than two CAs."""
    cas = []
    try:
        cmd.iterate_state(1, '(%s) and polymer and name CA' % obj,
                          'cas.append((x, y, z))', space={'cas': cas})
    except Exception:
        return None
    if len(cas) < 2:
        return None
    return (list(cas[0]), list(cas[-1]))


def _jacobi3(A):
    """Eigenpairs of a symmetric 3x3 matrix (Jacobi), sorted by descending value.
    Returns [(eigenvalue, eigenvector), ...]."""
    a = [[A[i][j] for j in range(3)] for i in range(3)]
    v = [[1.0 if i == j else 0.0 for j in range(3)] for i in range(3)]
    for _ in range(100):
        p, q, off = 0, 1, abs(a[0][1])
        for (i, j) in ((0, 2), (1, 2)):
            if abs(a[i][j]) > off:
                p, q, off = i, j, abs(a[i][j])
        if off < 1e-14:
            break
        if abs(a[p][p] - a[q][q]) < 1e-18:
            theta = math.pi / 4.0
        else:
            theta = 0.5 * math.atan2(2.0 * a[p][q], a[p][p] - a[q][q])
        c = math.cos(theta); s = math.sin(theta)
        for k in range(3):              # A = J^T A
            akp = a[k][p]; akq = a[k][q]
            a[k][p] = c * akp + s * akq
            a[k][q] = -s * akp + c * akq
        for k in range(3):              # A = A J
            apk = a[p][k]; aqk = a[q][k]
            a[p][k] = c * apk + s * aqk
            a[q][k] = -s * apk + c * aqk
        for k in range(3):              # V = V J
            vkp = v[k][p]; vkq = v[k][q]
            v[k][p] = c * vkp + s * vkq
            v[k][q] = -s * vkp + c * vkq
    eig = [(a[i][i], [v[0][i], v[1][i], v[2][i]]) for i in range(3)]
    eig.sort(key=lambda e: -e[0])
    return eig


def _pca_axes(obj, com):
    """Principal axes (orthonormal, right-handed) of the object's coordinates."""
    C = [[0.0] * 3 for _ in range(3)]
    n = [0]
    try:
        cmd.iterate_state(
            1, '(%s)' % obj,
            'a = x - COM[0]; b = y - COM[1]; c = z - COM[2]; '
            'C[0][0] += a * a; C[0][1] += a * b; C[0][2] += a * c; '
            'C[1][1] += b * b; C[1][2] += b * c; C[2][2] += c * c; n[0] += 1',
            space={'C': C, 'COM': com, 'n': n, 'a': 0, 'b': 0, 'c': 0})
    except Exception:
        return None
    if n[0] < 3:
        return None
    C[1][0] = C[0][1]; C[2][0] = C[0][2]; C[2][1] = C[1][2]
    eig = _jacobi3(C)
    x = _norm(eig[0][1]); y = _norm(eig[1][1]); z = _norm(eig[2][1])
    if not (x and y and z):
        return None
    if _dot(_cross(x, y), z) < 0:   # enforce right-handed
        z = [-c for c in z]
    return (x, y, z)


def _compute_frame(obj):
    com = _model_com(obj)
    if com is None:
        return None
    basis = None
    t = _termini(obj)
    if t is not None:
        nterm, cterm = t
        x = _norm(_sub(cterm, com))
        if x is not None:
            z = _norm(_cross(_sub(nterm, com), x))
            if z is not None:
                basis = (x, _cross(z, x), z)
    if basis is None:
        basis = _pca_axes(obj, com)
    if basis is None:
        basis = ([1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0])
    # Object radius = radius of gyration (RMS distance of atoms from the COM).
    acc = [0.0, 0]
    try:
        cmd.iterate_state(
            1, '(%s)' % obj,
            'd = (x - COM[0])**2 + (y - COM[1])**2 + (z - COM[2])**2; '
            'acc[0] += d; acc[1] += 1',
            space={'acc': acc, 'COM': com, 'd': 0})
    except Exception:
        pass
    rg = math.sqrt(acc[0] / acc[1]) if acc[1] else 0.0
    radius = max(rg, _MIN_RADIUS)
    return (com, basis, radius)


def _ensure_frame(obj):
    # A custom override (set in adjust mode) replaces the auto molecular frame.
    if obj and obj in _frame_override:
        return _frame_override[obj]
    if obj and obj not in _frame:
        f = _compute_frame(obj)
        if f is not None:
            _frame[obj] = f
    return _frame.get(obj)


def _displayed_frame(obj):
    """(com_world, (dx, dy, dz)) — the model frame transformed by the object's
    current matrix (TTT), so it tumbles with the molecule. None if unavailable."""
    f = _ensure_frame(obj)
    if f is None:
        return None
    com, (bx, by, bz), radius = f
    try:
        m = cmd.get_object_matrix(obj)
    except Exception:
        m = None
    if m and len(m) >= 16:
        def rot(v):
            return [m[0] * v[0] + m[1] * v[1] + m[2] * v[2],
                    m[4] * v[0] + m[5] * v[1] + m[6] * v[2],
                    m[8] * v[0] + m[9] * v[1] + m[10] * v[2]]
        comw = [m[0] * com[0] + m[1] * com[1] + m[2] * com[2] + m[3],
                m[4] * com[0] + m[5] * com[1] + m[6] * com[2] + m[7],
                m[8] * com[0] + m[9] * com[1] + m[10] * com[2] + m[11]]
        return (comw, (rot(bx), rot(by), rot(bz)), radius)
    return (com, (bx, by, bz), radius)


# --- Gizmo geometry emission ------------------------------------------------

def _emit(active=True):
    out = {'active': False}
    try:
        if active and _object_exists(_active):
            params = _view_params(_aspect)
            df = _displayed_frame(_active)
            if params is not None and df is not None:
                com, (dx, dy, dz), radius = df
                cproj = _project(params, com)
                if cproj is not None:
                    out = {'active': True, 'obj': _active,
                           'center': [cproj[0], cproj[1]]}
                    axes = {'x': dx, 'y': dy, 'z': dz}
                    # Axis arrows sized in world units (fraction of the radius).
                    axis_len = _AXIS_FRAC * radius
                    out['axes'] = {}
                    for k, av in axes.items():
                        tip = _project(params, [com[i] + av[i] * axis_len for i in range(3)])
                        if tip is not None:
                            out['axes'][k] = [tip[0], tip[1]]
                    # Rotation rings: one per axis, in the plane of the other two.
                    ringbasis = {'x': (dy, dz), 'y': (dz, dx), 'z': (dx, dy)}
                    r_world = _RING_FRAC * radius
                    out['rings'] = {}
                    for k, (u, vv) in ringbasis.items():
                        pts = []
                        for i in range(_RING_SEG + 1):
                            ang = 2.0 * math.pi * i / _RING_SEG
                            cu = math.cos(ang) * r_world
                            sv = math.sin(ang) * r_world
                            p = [com[j] + u[j] * cu + vv[j] * sv for j in range(3)]
                            pr = _project(params, p)
                            if pr is not None:
                                pts.append([pr[0], pr[1]])
                        out['rings'][k] = pts
    except Exception as e:
        print('METALMOVE_ERR:' + str(e))
        out = {'active': False}
    try:
        with open(_PATH, 'w') as f:
            json.dump(out, f)
    except Exception:
        pass


# --- 3D CGO gizmo (lit tubes, tracks the molecule via a copied TTT) ---------

def _sat(c, s, v=1.0):
    """Scale a color's saturation by `s` about its luminance and brightness by `v`
    (both clamped to [0, 1])."""
    L = 0.30 * c[0] + 0.59 * c[1] + 0.11 * c[2]
    return tuple(max(0.0, min(1.0, (L + (c[i] - L) * s) * v)) for i in range(3))


def _hl(key):
    """Color for gizmo handle `key` ('x'/'y'/'z' or 'rx'/'ry'/'rz'). The ACTIVE
    (hovered/grabbed) handle is vivid — more saturated + brighter — while any
    handle is active the others are MUTED (desaturated + dimmer) so the live
    control clearly stands out. In adjust-frame mode the base is gray, so this
    reads as a brighter-vs-dimmer gray."""
    base = (0.62, 0.62, 0.62) if _adjust else _COL[key[-1]]
    if _hover == key:
        return _sat(base, 1.6, 1.12)     # active: vivid
    if _hover:
        return _sat(base, 0.6, 0.78)     # something else active: gently muted
    return base


def _delete_cgo():
    try:
        if _GIZMO_OBJ in (cmd.get_names('objects') or []):
            cmd.delete(_GIZMO_OBJ)
    except Exception:
        pass


# Identity TTT (16-float TTT format) used to CLEAR the gizmo's transform.
_IDENTITY_TTT = [1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0,
                 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0]


def _sync_gizmo_ttt():
    """Match the gizmo CGO's transform to the active object's so it moves/tumbles
    with it AND stays aligned with the 2D hit-test geometry.

    Use get_object_MATRIX, not get_object_ttt. In this embedded core the two
    DIVERGE after a gizmo rotation about an off-center origin (cmd.rotate
    object=, origin=com): they keep the same rotation but accumulate different
    translations. get_object_matrix is the transform the molecule actually
    RENDERS at (get_model bakes it; metal_pick projects it and picks correctly),
    and _emit/_displayed_frame projects the hit geometry through it too — so
    riding get_object_ttt here made the rendered gizmo drift off the molecule
    (and off its own hit-targets) once you dragged it, which read as "the gizmo
    ring/element hover is broken" (you hovered the visible gizmo but the
    hit-geometry was elsewhere). Matching get_object_matrix keeps the CGO, the
    molecule, and the hit-test all co-located. Verified live via MCP: matrix
    projection == get_model COM projection == emit center.

    ALWAYS set it explicitly — identity when the target has none — never fall
    back to matrix_reset: matrix_reset(mode=1) does not clear a CGO object's
    transform (verified on this build), so a stale (moved) transform would
    otherwise linger when switching to an un-moved target."""
    if not _object_exists(_GIZMO_OBJ) or not _object_exists(_active):
        return
    try:
        m = cmd.get_object_matrix(_active)
        cmd.set_object_ttt(_GIZMO_OBJ, list(m) if m else list(_IDENTITY_TTT))
    except Exception as e:
        print('METALMOVE_ERR:' + str(e))


def _build_cgo():
    """(Re)build the gizmo CGO in the object's LOCAL frame, then sync its TTT.
    Cheap enough to call on activate + hover change; NOT called per drag tick."""
    f = _ensure_frame(_active)
    if f is None:
        _delete_cgo()
        return
    from pymol import cgo
    com, (bx, by, bz), radius = f
    axis_len = _AXIS_FRAC * radius
    ring_r = _RING_FRAC * radius
    tube = max(0.02 * radius, 0.12)   # thin, stick-like
    g = []
    # Axis tubes + knob spheres (grab targets). Hovering only THICKENS the tube +
    # brightens it — the axis length stays fixed so the gizmo doesn't resize.
    for k, av in (('x', bx), ('y', by), ('z', bz)):
        r, gg, b = _hl(k)
        hov = (_hover == k)
        t = tube * (1.8 if hov else 1.0)
        al = axis_len
        tip = [com[i] + av[i] * al for i in range(3)]
        g += [cgo.CYLINDER, com[0], com[1], com[2], tip[0], tip[1], tip[2],
              t, r, gg, b, r, gg, b]
        g += [cgo.COLOR, r, gg, b, cgo.SPHERE, tip[0], tip[1], tip[2],
              t * (3.0 if hov else 2.3)]
    # Rotation rings; hovered ring grows in radius + tube.
    for k, u, v in (('x', by, bz), ('y', bz, bx), ('z', bx, by)):
        rk = 'r' + k
        r, gg, b = _hl(rk)
        hov = (_hover == rk)
        # Hover only THICKENS the ring tube — the ring radius stays fixed so the
        # distance from the center sphere out to the ring doesn't change.
        t = tube * 0.8 * (2.0 if hov else 1.0)
        rr = ring_r
        # Dense sampling + a sphere impostor at every joint: the spheres (which the
        # Metal backend ray-traces perfectly smooth) fill the angular seam where
        # two straight cylinders meet, so the ring reads as a smooth torus instead
        # of a faceted polygon with visible junctions.
        N = 96
        pts = [[com[i] + u[i] * math.cos(2.0 * math.pi * j / N) * rr
                + v[i] * math.sin(2.0 * math.pi * j / N) * rr for i in range(3)]
               for j in range(N + 1)]
        for j in range(N):
            p0, p1 = pts[j], pts[j + 1]
            g += [cgo.CYLINDER, p0[0], p0[1], p0[2], p1[0], p1[1], p1[2],
                  t, r, gg, b, r, gg, b]
            g += [cgo.COLOR, r, gg, b, cgo.SPHERE, p0[0], p0[1], p0[2], t]
    # Free center handle (the origin); grows noticeably when hovered. Gray in
    # adjust mode, white otherwise.
    cc = 0.85 if _adjust else 1.0
    g += [cgo.COLOR, cc, cc, cc, cgo.SPHERE, com[0], com[1], com[2],
          tube * (3.4 if _hover == 'free' else 2.1)]
    try:
        # state=1 so each rebuild REPLACES the geometry. With the default state=0,
        # load_cgo APPENDS a new state every call, so every rebuild (hover, drag,
        # target switch) piled up states — and on a target switch the stale
        # old-target geometry stayed in the rendered state, so the gizmo showed up
        # detached from the new target (out in empty space between the objects).
        cmd.load_cgo(g, _GIZMO_OBJ, state=1, zoom=0)
        # Semitransparent while editing the frame; fully opaque while manipulating.
        cmd.set('cgo_transparency', 0.5 if _adjust else 0.0, _GIZMO_OBJ)
    except Exception as e:
        print('METALMOVE_ERR:' + str(e))
    _sync_gizmo_ttt()


# --- Public API (called from Swift) ----------------------------------------

def set_active(obj, aspect):
    """Make `obj` the active object (empty string clears) and emit geometry."""
    global _active, _aspect
    _aspect = float(aspect)
    _active = obj if (obj and _object_exists(obj)) else None
    if _active:
        _ensure_frame(_active)
        _build_cgo()
    else:
        _delete_cgo()
    _emit(_active is not None)


def clear_active():
    global _active
    _active = None
    _delete_cgo()
    _emit(False)


def refresh(aspect):
    global _aspect
    _aspect = float(aspect)
    _emit(_active is not None)


def pick_object(ndc_x, ndc_y, aspect):
    """Grab-what-you-touch: set the active object under the point (clear on empty
    space), compute its frame, emit."""
    global _active, _aspect
    _aspect = float(aspect)
    try:
        from pymol import metal_pick
        # Forgiving radius: identify the object under/near the tap even when it
        # lands in a cartoon gap or the molecule is small (zoomed out). Only a
        # truly-empty tap — beyond _OBJECT_PICK_NDC2 of every atom — returns None
        # and deselects. A precise guide-atom hit is NOT required to grab an
        # object for motion.
        best = metal_pick._pick_atom(ndc_x, ndc_y, aspect,
                                     max_ndc2=metal_pick._OBJECT_PICK_NDC2)
        _active = best[1] if best is not None else None
    except Exception as e:
        print('METALMOVE_ERR:' + str(e))
        _active = None
    if _active:
        _ensure_frame(_active)
        _build_cgo()
    else:
        _delete_cgo()
    _emit(_active is not None)


def set_hover(handle):
    """Highlight the hovered gizmo handle (rebuilds the CGO). '' clears."""
    global _hover
    h = handle or ''
    if h == _hover:
        return
    _hover = h
    if _active and _object_exists(_active):
        _build_cgo()


def begin_drag(handle, ndc_x, ndc_y, aspect):
    global _drag, _aspect, _hover
    _aspect = float(aspect)
    _drag = {'handle': handle, 'px': float(ndc_x), 'py': float(ndc_y),
             'dist': 0.0, 'deg': 0.0, 'dx': 0.0, 'dy': 0.0}
    _hover = handle   # grow the grabbed handle for the duration of the drag
    if _active and _object_exists(_active):
        _build_cgo()
    _emit(_active is not None)


def _adjust_drag(h, dnx, dny, params, df):
    """Adjust-frame mode: the drag EDITS the active object's gizmo frame (its
    origin and inclination), stored as a model-space override, then rebuilds the
    gizmo. The structure itself is never moved — only the pivot/axes change."""
    fm = _ensure_frame(_active)
    if fm is None:
        return
    com_m, basis_m, radius = fm
    com_w, (dx, dy, dz), _r = df
    axes_w = {'x': dx, 'y': dy, 'z': dz}
    axes_m = {'x': basis_m[0], 'y': basis_m[1], 'z': basis_m[2]}
    new_com = list(com_m)
    new_basis = basis_m
    try:
        if h in ('x', 'y', 'z'):
            # Slide the ORIGIN along the frame axis. Moving the model com by
            # dist*model_axis maps to dist*displayed_axis in the view (R·axis).
            d = _axis_screen_dir(params, com_w, axes_w[h])
            if d:
                denom = d[0] * d[0] + d[1] * d[1]
                if denom > 1e-12:
                    dist = (dnx * d[0] + dny * d[1]) / denom
                    am = axes_m[h]
                    new_com = [com_m[i] + am[i] * dist for i in range(3)]
                    _drag['dist'] += dist
        elif h in ('rx', 'ry', 'rz'):
            # Tilt the whole frame about the ring's axis (the inclination).
            cproj = _project(params, com_w)
            if cproj:
                ang_prev = math.atan2((_drag['py'] - dny) - cproj[1],
                                      (_drag['px'] - dnx) - cproj[0])
                ang_cur = math.atan2(_drag['py'] - cproj[1], _drag['px'] - cproj[0])
                dtheta = ang_cur - ang_prev
                while dtheta > math.pi:
                    dtheta -= 2 * math.pi
                while dtheta < -math.pi:
                    dtheta += 2 * math.pi
                # Same camera-facing sign flip as normal rotation, so tilting the
                # frame follows the drag whether the axis faces toward or away.
                avw = axes_w[h[1]]
                r2 = params[2]
                face = avw[0] * r2[0] + avw[1] * r2[1] + avw[2] * r2[2]
                theta = dtheta * (1.0 if face >= 0.0 else -1.0)
                new_basis = _rotate_basis(basis_m, axes_m[h[1]], theta)
                _drag['deg'] += math.degrees(theta)
        elif h == 'free':
            # Free-slide the ORIGIN in the screen plane.
            cproj = _project(params, com_w)
            if cproj:
                half_h = cproj[2] * params[5]
                half_w = half_h * params[6]
                wx = dnx * half_w
                wy = dny * half_h
                r0, r1 = params[0], params[1]
                world = [wx * r0[i] + wy * r1[i] for i in range(3)]
                md = _world_to_model_vec(_active, world)
                new_com = [com_m[i] + md[i] for i in range(3)]
                _drag['dx'] += wx
                _drag['dy'] += wy
    except Exception as e:
        print('METALMOVE_ERR:' + str(e))
        return
    _frame_override[_active] = (new_com, new_basis, radius)
    _build_cgo()   # show the re-anchored frame (rides the object via synced TTT)


def update_drag(ndc_x, ndc_y, aspect):
    global _aspect
    _aspect = float(aspect)
    if _drag is None or not _object_exists(_active):
        return
    dnx = float(ndc_x) - _drag['px']
    dny = float(ndc_y) - _drag['py']
    _drag['px'] = float(ndc_x)
    _drag['py'] = float(ndc_y)
    params = _view_params(aspect)
    df = _displayed_frame(_active)
    if params is None or df is None:
        return
    com, (dx, dy, dz), _radius = df
    axes = {'x': dx, 'y': dy, 'z': dz}
    h = _drag['handle']
    if _adjust:
        # Adjust-frame mode: the drag re-anchors the gizmo (origin + inclination)
        # instead of moving the structure. _adjust_drag rebuilds the CGO itself.
        _adjust_drag(h, dnx, dny, params, df)
        return
    try:
        if h in ('x', 'y', 'z'):
            av = axes[h]
            d = _axis_screen_dir(params, com, av)
            if d:
                denom = d[0] * d[0] + d[1] * d[1]
                if denom > 1e-12:
                    dist = (dnx * d[0] + dny * d[1]) / denom   # world Angstrom
                    cmd.translate([av[0] * dist, av[1] * dist, av[2] * dist],
                                  object=_active, camera=0)
                    _drag['dist'] += dist
        elif h in ('rx', 'ry', 'rz'):
            av = axes[h[1]]
            cproj = _project(params, com)
            if cproj:
                ang_prev = math.atan2((_drag['py'] - dny) - cproj[1],
                                      (_drag['px'] - dnx) - cproj[0])
                ang_cur = math.atan2(_drag['py'] - cproj[1], _drag['px'] - cproj[0])
                dtheta = ang_cur - ang_prev
                while dtheta > math.pi:
                    dtheta -= 2 * math.pi
                while dtheta < -math.pi:
                    dtheta += 2 * math.pi
                # +deg about av reads as CCW on screen only when av points TOWARD
                # the camera; flip by the axis's camera-facing sign (r2·av) so the
                # ring always rotates the way you drag it, near side or far side.
                r2 = params[2]
                face = av[0] * r2[0] + av[1] * r2[1] + av[2] * r2[2]
                deg = math.degrees(dtheta) * (1.0 if face >= 0.0 else -1.0)
                cmd.rotate([av[0], av[1], av[2]], deg, object=_active,
                           origin=com, camera=0)
                _drag['deg'] += deg
        elif h == 'free':
            cproj = _project(params, com)
            if cproj:
                half_h = cproj[2] * params[5]
                half_w = half_h * params[6]
                wx = dnx * half_w
                wy = dny * half_h
                cmd.translate([wx, wy, 0.0], object=_active, camera=1)
                _drag['dx'] += wx
                _drag['dy'] += wy
    except Exception as e:
        print('METALMOVE_ERR:' + str(e))
    _sync_gizmo_ttt()   # gizmo rides the molecule via the copied TTT
    # NOTE: deliberately NO _emit() here. Mid-drag we skip the projection +
    # JSON-file write (and Swift skips the file read-back) — the gizmo is a 3D
    # CGO that already tracks the molecule via the synced TTT, and hit-testing
    # is idle while a handle is grabbed. This keeps the drag as light as a
    # vanilla-GL matrix update (one cmd.translate/rotate). The full geometry is
    # re-emitted once on end_drag for the next hit-test.


def end_drag():
    global _drag, _hover
    _drag = None
    _hover = ''
    if _active and _object_exists(_active):
        _build_cgo()   # un-grow the handle
    _emit(_active is not None)


def reset_active():
    """Reset the active object's TTT (matrix_reset) — non-destructive undo."""
    if _object_exists(_active):
        try:
            cmd.matrix_reset(_active, mode=1)
        except Exception as e:
            print('METALMOVE_ERR:' + str(e))
    _sync_gizmo_ttt()
    _emit(_active is not None)


def set_adjust(on):
    """Enter/leave adjust-frame mode (gizmo controls re-anchor the frame instead
    of moving the structure). Rebuilds the gizmo so it greys out / restores."""
    global _adjust
    on = bool(int(on)) if isinstance(on, str) else bool(on)
    if on == _adjust:
        return
    _adjust = on
    if _active and _object_exists(_active):
        _build_cgo()
    _emit(_active is not None)


def reset_gizmo():
    """Clear the active object's custom frame override → the gizmo snaps back to
    the automatic molecular frame. Distinct from reset_active (which resets the
    object's position); this only affects the gizmo's origin/inclination."""
    if _active in _frame_override:
        del _frame_override[_active]
    if _active and _object_exists(_active):
        _frame.pop(_active, None)   # force a fresh auto-frame recompute
        _ensure_frame(_active)
        _build_cgo()
    _emit(_active is not None)


def cleanup():
    """Leave Move mode: delete the gizmo, clear state + the frame cache, and drop
    adjust mode. TTT moves on the molecules AND custom frame overrides persist."""
    global _active, _drag, _hover, _adjust
    _delete_cgo()
    _active = None
    _drag = None
    _hover = ''
    _adjust = False
    _frame.clear()
    _emit(False)
