'''
Various morphing workflows

(c) 2013 Schrodinger, Inc.
(c) 2011 Thomas Holder
(c) 2009 DeLano Scientific LLC.

RayMol: open-source morph (proof of concept).

Clean-room implementation in the spirit of the Yale Morph Server
(Krebs & Gerstein, Nucleic Acids Res 2000): pair atoms, find a rigid core
per chain by sieve fitting, split each chain into rigid segments at hinges,
move every segment along a screw (helical) path, interpolate what is left
linearly inside the segment frame, blend across hinges, then optionally
clean up intermediates with PyMOL's sculpting engine.
Pure Python, no numpy, no incentive code.
'''

import math
import time

import pymol
from chempy import cpv

cmd = __import__("sys").modules["pymol.cmd"]

_RATES = {
    'linear': lambda f: f,
    'sinusoidal': lambda f: (1.0 - math.cos(math.pi * f)) / 2.0,
    'ramp up': lambda f: 1.0 - math.cos(math.pi * f / 2.0),
    'ramp down': lambda f: math.sin(math.pi * f / 2.0),
}

_GUIDE_NAMES = ('CA', 'P', "C4'", 'N', 'C')


# --------------------------------------------------------------------------
# small vector helpers (pure Python, lists of 3 floats)

def _sub(a, b):
    return [a[0] - b[0], a[1] - b[1], a[2] - b[2]]


def _add(a, b):
    return [a[0] + b[0], a[1] + b[1], a[2] + b[2]]


def _scale(a, s):
    return [a[0] * s, a[1] * s, a[2] * s]


def _dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def _cross(a, b):
    return [a[1] * b[2] - a[2] * b[1],
            a[2] * b[0] - a[0] * b[2],
            a[0] * b[1] - a[1] * b[0]]


def _norm(a):
    return math.sqrt(_dot(a, a))


def _mean(pts):
    n = float(len(pts))
    return [sum(p[0] for p in pts) / n,
            sum(p[1] for p in pts) / n,
            sum(p[2] for p in pts) / n]


def _rot_apply(R, v):
    return cpv.transform(R, v)


def _rot_apply_t(R, v):
    return cpv.inverse_transform(R, v)


def _axis_angle(R):
    '''Rotation axis (unit) and angle (radians, in [0, pi]) of a 3x3 matrix.
    Uses atan2 so tiny angles do not collapse to zero.'''
    a = [R[2][1] - R[1][2], R[0][2] - R[2][0], R[1][0] - R[0][1]]
    s = _norm(a) / 2.0
    c = (R[0][0] + R[1][1] + R[2][2] - 1.0) / 2.0
    theta = math.atan2(s, c)
    if s > 1e-6 or c > 0:
        # antisymmetric part is accurate away from 180 degrees; for tiny
        # angles any axis error is multiplied by the tiny angle anyway
        if s < 1e-300:
            return [1.0, 0.0, 0.0], 0.0
        return _scale(a, 1.0 / (2.0 * s)), theta
    # theta ~ pi: axis from the symmetric part (R + I ~ 2 u u^T); take the
    # largest column, and use the antisymmetric part only for the sign
    best, bestn = None, -1.0
    for j in range(3):
        col = [R[0][j] + (1.0 if j == 0 else 0.0),
               R[1][j] + (1.0 if j == 1 else 0.0),
               R[2][j] + (1.0 if j == 2 else 0.0)]
        n = _norm(col)
        if n > bestn:
            best, bestn = col, n
    u = _scale(best, 1.0 / bestn)
    if _dot(u, a) < 0:
        u = _scale(u, -1.0)
    return u, theta


def _rodrigues(u, phi):
    '''3x3 rotation matrix for angle phi about unit axis u.'''
    c, s = math.cos(phi), math.sin(phi)
    C = 1.0 - c
    x, y, z = u
    return [[c + x * x * C, x * y * C - z * s, x * z * C + y * s],
            [y * x * C + z * s, c + y * y * C, y * z * C - x * s],
            [z * x * C - y * s, z * y * C + x * s, c + z * z * C]]


def _fit(target_pts, source_pts):
    '''Rigid transform taking source onto target (least squares).
    Returns (R, c_src, c_tgt): fitted = R·(x - c_src) + c_tgt.
    R is None when fewer than three points (translation only).'''
    if len(target_pts) < 3:
        return None, _mean(source_pts), _mean(target_pts)
    t1, t2, R, rmsd = cpv.fit(target_pts, source_pts)
    return R, t2, t1


class _Screw(object):
    '''Rigid motion T(x) = R(x - c0) + c1, decomposed as a screw so that the
    fraction-f motion rotates by f*theta about the screw axis and slides
    f of the way along it.  For tiny angles the screw axis runs away, so we
    rotate about c0 instead and translate linearly; both are exact at f=1.'''

    def __init__(self, R, c0, c1):
        self.R = R
        self.c0 = c0
        if R is None:
            self.t = _sub(c1, c0)
            self.p = None
            return
        self.t = _sub(c1, _rot_apply(R, c0))       # T(x) = R x + t
        u, theta = _axis_angle(R)
        self.u, self.theta = u, theta
        if theta < 1e-4:
            self.p = c0
            self.d = _sub(c1, c0)
            return
        tpar = _dot(self.t, u)
        self.d = _scale(u, tpar)                    # slide along the axis
        t_perp = _sub(self.t, self.d)
        # point on the screw axis closest to the origin: (I - R) p = t_perp
        self.p = _add(_scale(t_perp, 0.5),
                      _scale(_cross(u, t_perp), 1.0 / (2.0 * math.tan(theta / 2.0))))

    def pull_back(self, x):
        '''T^-1(x): express an end-frame point in the start frame.'''
        if self.R is None:
            return _sub(x, self.t)
        return _rot_apply_t(self.R, _sub(x, self.t))

    def at(self, f):
        '''Return a function applying the fraction-f rigid motion.'''
        if self.R is None:
            d = _scale(self.t, f)
            return lambda x: _add(x, d)
        Rf = _rodrigues(self.u, f * self.theta)
        p = self.p
        off = _add(p, _scale(self.d, f))
        return lambda x: _add(_rot_apply(Rf, _sub(x, p)), off)


# --------------------------------------------------------------------------
# atom pairing

def _single_object(sele, _self):
    objs = _self.get_object_list(sele)
    if len(objs) != 1:
        raise pymol.CmdException('morph: selection "%s" must lie within exactly '
                                 'one object (found %d)' % (sele, len(objs)))
    return objs[0]


_KEY_IN = '(segi, chain, resi, resn, name)'
_KEY_LIKE = '(segi, chain, resi, name)'


def _index_by_key(sele, keyexpr, _self):
    m = {}
    _self.iterate(sele, 'm[%s] = index' % keyexpr, space={'m': m})
    return m


def _pairs_by_identifiers(sele1, sele2, keyexpr, _self):
    m1 = _index_by_key(sele1, keyexpr, _self)
    m2 = _index_by_key(sele2, keyexpr, _self)
    return {i1: m2[k] for k, i1 in m1.items() if k in m2}


def _pairs_from_alignment(aln, obj1, obj2, _self):
    pairs = {}
    for col in _self.get_raw_alignment(aln):
        d = dict(col)
        if obj1 in d and obj2 in d:
            pairs[d[obj1]] = d[obj2]
    return pairs


def _snapshot(name, sele, obj, _self):
    '''Atom table of the output object `name`, just created from `sele`.

    Returns (new_idx, pos, src_of, info): the output's atom indices in
    coordinate-set order, index -> position in that order, output index ->
    index in `sele`'s object, and info[pos] = (segi, chain, resv, resi, name).
    `obj` names the object `sele` lies in, for the error text.'''
    natoms = _self.count_atoms(name)
    key2new = _index_by_key(name, _KEY_IN, _self)
    key2src = _index_by_key(sele, _KEY_IN, _self)
    if len(key2new) != natoms:
        raise pymol.CmdException('morph: atom identifiers in "%s" are not unique' % obj)
    new_idx = sorted(key2new.values())
    pos = {idx: p for p, idx in enumerate(new_idx)}
    src_of = {}
    for k, inew in key2new.items():
        isrc = key2src.get(k)
        if isrc is None:
            raise pymol.CmdException('morph: lost track of atom %s' % (k,))
        src_of[inew] = isrc
    info = [None] * natoms
    _self.iterate(name, 'info[pos[index]] = (segi, chain, resv, resi, name)',
                  space={'info': info, 'pos': pos})
    return new_idx, pos, src_of, info


def _coords_by_pos(obj, state, index_map, pos, _self):
    '''Coordinates of `obj` in `state` as a list ordered by output position;
    index_map maps an output atom index to the matching index in `obj`.'''
    c = {}
    _self.iterate_state(state, obj, 'c[index] = (x, y, z)', space={'c': c})
    out = [None] * len(pos)
    for inew, iobj in index_map.items():
        out[pos[inew]] = list(c[iobj])
    if any(v is None for v in out):
        raise pymol.CmdException('morph: missing coordinates in state %d' % state)
    return out


def key_frames(nstates, steps, nlegs):
    '''1-based state numbers that hold exact copies of the input models.

    With N legs of `steps` frames each, the morph has N*steps total states.
    Key frames are at 1 + k*steps for k = 0..N-1, and the final state N*steps
    is the last leg's target model.

    Example: key_frames(15, 5, 3) == [1, 6, 11, 15]
             key_frames(10, 5, 2) == [1, 6, 10]
    '''
    return [1 + k * steps for k in range(nlegs)] + [nstates]


def residue_order(keys):
    '''Sort (resv, resi) residue keys: numerically by resv first, then by the
    insertion-coded string resi within the same resv.

    resv is an int (for numeric ordering); resi is the full residue-id string
    (e.g. "2", "2A", "-1").  The natural tuple sort on (int, str) is exactly
    what we want.
    '''
    return sorted(keys)


#: Atoms pinned while sculpting cleans up an intermediate, and sculpt cycles
#: per unit of `refinement`. Shared with the morph job layer (morph_jobs.py).
_SCULPT_FIX = 'name N+CA+C+O+P'
_SCULPT_CYCLES = 10


def sculpt_states(name, nstates, steps, nlegs, refinement, _self):
    '''Sculpt every intermediate state except the key frames.

    Key frames (exact copies of the input models) are identified by
    key_frames(nstates, steps, nlegs).  Backbone atoms (N+CA+C+O+P) are
    pinned with a "fix" flag, sculpting runs for 10*refinement cycles per
    state, and the flag is cleared afterwards.
    '''
    if refinement <= 0 or nstates <= 2:
        return
    kf = set(key_frames(nstates, steps, nlegs))
    _self.flag('fix', '%s and %s' % (name, _SCULPT_FIX), 'set', quiet=1)
    try:
        _self.sculpt_activate(name, 1)
        for st in range(2, nstates):
            if st not in kf:
                _self.sculpt_iterate(name, st, _SCULPT_CYCLES * refinement)
    finally:
        _self.sculpt_deactivate(name)
        _self.flag('fix', name, 'clear', quiet=1)


def _index_ranges(indices):
    '''Compress a sorted list of ints into a PyMOL "index 1-5+9+12-20" string.'''
    out = []
    start = prev = None
    for i in indices:
        if start is None:
            start = prev = i
        elif i == prev + 1:
            prev = i
        else:
            out.append('%d-%d' % (start, prev) if start != prev else '%d' % start)
            start = prev = i
    if start is not None:
        out.append('%d-%d' % (start, prev) if start != prev else '%d' % start)
    return '+'.join(out)


# --------------------------------------------------------------------------
# rigid-core / hinge segmentation (per chain)

def _sieve_core(S, E, guides, fraction):
    '''Iteratively drop the worst-fitting guide atom until `fraction` remain.
    Residuals are measured in the START frame after fitting END onto START,
    so the result does not depend on how the inputs happen to be oriented.'''
    cur = list(guides)
    keep = max(3, int(len(cur) * fraction))
    while len(cur) > keep:
        tgt = [S[p] for p in cur]
        src = [E[p] for p in cur]
        R, c_src, c_tgt = _fit(tgt, src)
        if R is None:
            break
        worst, worst_d, rms = -1, -1.0, 0.0
        for k, p in enumerate(cur):
            fitted = _add(_rot_apply(R, _sub(src[k], c_src)), c_tgt)
            dv = _sub(fitted, tgt[k])
            d = _dot(dv, dv)
            rms += d
            if d > worst_d:
                worst, worst_d = k, d
        if math.sqrt(rms / len(cur)) < 0.1:
            break
        del cur[worst]
    return set(cur)


def _split_runs(labels, min_len):
    '''Hinge rule: a label change becomes a cut only when the accumulated
    block before it and the run after it are both at least min_len long.
    Returns the cut positions (index of the first residue after a hinge).'''
    n = len(labels)
    cuts = []
    i = 0
    block_start = 0
    while i < n:
        j = i
        while j < n and labels[j] == labels[i]:
            j += 1
        if i > 0 and (i - block_start) >= min_len and (j - i) >= min_len:
            cuts.append(i)
            block_start = i
        i = j
    return cuts


class _Segment(object):
    __slots__ = ('atoms', 'guides', 'screw', 'pulled')

    def __init__(self):
        self.atoms = []
        self.guides = []
        self.screw = None
        self.pulled = {}


def _segment_chains(S, E, info, core_fraction, min_hinge, blend):
    '''Group atoms into rigid segments, one chain at a time.
    info[p] = (segi, chain, resv, resi, name).
    Returns (segments, blend_of_pos, report) where blend_of_pos maps an atom
    position to (other_segment_id, weight) for atoms near a hinge.'''
    chains = {}
    for p, (segi, chain, resv, resi, name) in enumerate(info):
        chains.setdefault((segi, chain), {}).setdefault((resv, resi), []).append(p)
    segments = []
    blend_of_pos = {}
    report = []
    for ckey in sorted(chains):
        residues = chains[ckey]
        order = residue_order(residues)
        guides = []
        for rkey in order:
            atoms = residues[rkey]
            names = {info[p][4]: p for p in atoms}
            g = None
            for gn in _GUIDE_NAMES:
                if gn in names:
                    g = names[gn]
                    break
            guides.append(g if g is not None else atoms[0])
        if len(order) < 2 * min_hinge:
            cuts = []
        else:
            core = _sieve_core(S, E, guides, core_fraction)
            labels = [g in core for g in guides]
            cuts = _split_runs(labels, min_hinge)
        bounds = [0] + cuts + [len(order)]
        first_id = len(segments)
        seg_of_res = [None] * len(order)
        for k in range(len(bounds) - 1):
            seg = _Segment()
            for r in range(bounds[k], bounds[k + 1]):
                seg.atoms.extend(residues[order[r]])
                seg.guides.append(guides[r])
                seg_of_res[r] = first_id + k
            segments.append(seg)
        # blend weights across each hinge: ramp over 2*blend+1 residues
        if blend > 0:
            span = 2 * blend + 1
            for h in cuts:
                seg_a, seg_b = seg_of_res[h - 1], seg_of_res[h]
                for r in range(max(0, h - blend), min(len(order), h + blend + 1)):
                    w_b = (r - h + blend + 0.5) / span
                    own = seg_of_res[r]
                    other, w = (seg_b, w_b) if own == seg_a else (seg_a, 1.0 - w_b)
                    if 0.0 < w < 1.0:
                        for p in residues[order[r]]:
                            blend_of_pos[p] = (other, w)
        report.append((ckey, len(bounds) - 1, [order[h][1] for h in cuts]))
    return segments, blend_of_pos, report


# --------------------------------------------------------------------------
# frame generation

def _frames_linear(S, E, fracs):
    for f in fracs:
        yield [[s[0] + (e[0] - s[0]) * f,
                s[1] + (e[1] - s[1]) * f,
                s[2] + (e[2] - s[2]) * f] for s, e in zip(S, E)]


def _frames_rigid(S, E, segments, blend_of_pos, fracs):
    for seg in segments:
        pts = seg.guides if len(seg.guides) >= 3 else seg.atoms
        R, c0, c1 = _fit([E[p] for p in pts], [S[p] for p in pts])
        seg.screw = _Screw(R, c0, c1)
        seg.pulled = {p: seg.screw.pull_back(E[p]) for p in seg.atoms}
    for p, (other, w) in blend_of_pos.items():
        seg = segments[other]
        seg.pulled[p] = seg.screw.pull_back(E[p])
    n = len(S)
    for f in fracs:
        frame = [None] * n
        maps = [seg.screw.at(f) for seg in segments]
        for sid, seg in enumerate(segments):
            T = maps[sid]
            pulled = seg.pulled
            for p in seg.atoms:
                s = S[p]
                eb = pulled[p]
                frame[p] = T([s[0] + (eb[0] - s[0]) * f,
                              s[1] + (eb[1] - s[1]) * f,
                              s[2] + (eb[2] - s[2]) * f])
        for p, (other, w) in blend_of_pos.items():
            s = S[p]
            eb = segments[other].pulled[p]
            x2 = maps[other]([s[0] + (eb[0] - s[0]) * f,
                              s[1] + (eb[1] - s[1]) * f,
                              s[2] + (eb[2] - s[2]) * f])
            x1 = frame[p]
            frame[p] = [x1[0] + (x2[0] - x1[0]) * w,
                        x1[1] + (x2[1] - x1[1]) * w,
                        x1[2] + (x2[2] - x1[2]) * w]
        yield frame


# --------------------------------------------------------------------------

def morph(name, sele1, sele2=None, state1=-1, state2=-1, refinement=3,
          steps=30, method='rigimol', match='align', quiet=1,
          rate='linear', core_fraction=0.5, min_hinge=6, hinge_blend=3,
          hide=1, color_segments=0, _self=cmd):
    '''
DESCRIPTION

    Creates an interpolated trajectory between two or multiple conformations.
    If the two input objects are not the same, match them based on sequence
    alignment.

    RayMol: open-source implementation. "rigimol" (default) moves rigid
    segments found by core/hinge analysis along screw paths and cleans
    intermediates with sculpting; "linear" is a plain Cartesian morph.

ARGUMENTS

    name = string: name of object to create

    sele1 = string: atom selection of first conformation

    sele2 = string: atom selection of second conformation {default: <sele1>}

    state1 = int: sele1 state {default: 1}. If state1=0 and sele1 has N
    states, create N morphings between all consecutive states and back from
    state N to 1 (so the morph will have N*steps states). If state2=0, create
    N-1 morphings and stop at last state.

    state2 = int: sele2 state {default: 2 if sele1=sele2, else 1}

    refinement = int: number of sculpting refinement cycles to clean
    distorted intermediates {default: 3}

    steps = int: number of states for sele2 object {default: 30}

    method = string: rigimol or linear {default: rigimol}

    match = string: in, like, align, super, or the name of an alignment
    object {default: align}

    rate = string: linear, sinusoidal, "ramp up" or "ramp down"
    {default: linear}

    core_fraction = float: fraction of residues per chain kept as the rigid
    core when looking for hinges {default: 0.5}

    min_hinge = int: minimum residues on both sides of a hinge {default: 6}

    hinge_blend = int: residues on each side of a hinge whose motion is
    blended between the two segments {default: 3}

    color_segments = 0/1: colour the output by rigid segment {default: 0}

EXAMPLE

    fetch 1akeA 4akeA, async=0
    align 1akeA, 4akeA
    morph mout, 1akeA, 4akeA
    '''
    t_start = time.time()
    steps, refinement = int(steps), int(refinement)
    state1, state2 = int(state1), int(state2)
    quiet, hide, color_segments = int(quiet), int(hide), int(color_segments)
    core_fraction, min_hinge = float(core_fraction), int(min_hinge)
    hinge_blend = int(hinge_blend)
    if steps < 2:
        raise pymol.CmdException('morph: steps must be >= 2')
    method = str(method).lower()
    if method in ('rigimol', 'rigid', 'segments', 'corkscrew'):
        method = 'rigid'
    elif method != 'linear':
        raise pymol.CmdException('morph: unknown method "%s"' % method)
    rate_fn = _RATES.get(str(rate).lower().replace('_', ' '))
    if rate_fn is None:
        raise pymol.CmdException('morph: unknown rate "%s"' % rate)
    if sele2 is None:
        sele2 = sele1
    # one alternate location per atom, so identifiers are unique
    sele1 = "((%s) and alt ''+A)" % sele1
    sele2 = "((%s) and alt ''+A)" % sele2
    obj1 = _single_object(sele1, _self)
    obj2 = _single_object(sele2, _self)
    n1 = _self.count_atoms(sele1)
    same_object = (obj1 == obj2 and n1 == _self.count_atoms(sele2)
                   and _self.count_atoms(sele1 + ' and ' + sele2) == n1)
    if state1 == -1:
        state1 = 1
    if state2 == -1:
        state2 = 2 if same_object else 1

    # ---- legs: list of (stateA, stateB) sharing one atom pairing
    if state1 == 0:
        n = _self.count_states(sele1)
        if n < 2:
            raise pymol.CmdException('morph: state1=0 needs a multi-state object')
        seq = list(range(1, n + 1))
        legs = list(zip(seq[:-1], seq[1:])) if state2 == 0 else list(zip(seq, seq[1:] + [1]))
        same_object = True
        sele2, obj2 = sele1, obj1
    else:
        legs = [(state1, state2)]
    first_state = legs[0][0]

    # ---- pairing: source index -> partner index, and the subset to copy
    tmp_aln = None
    if same_object:
        pairs = None
        subset = sele1
    else:
        m = str(match).lower()
        if m in ('in', 'like'):
            pairs = _pairs_by_identifiers(sele1, sele2, _KEY_IN if m == 'in' else _KEY_LIKE, _self)
            subset = '%s and index %s' % (sele1, _index_ranges(sorted(pairs)))
        else:
            if m in ('align', 'super'):
                tmp_aln = _self.get_unused_name('_morph_aln')
                fn = _self.align if m == 'align' else _self.super
                fn(sele1, sele2, cycles=0, transform=0, object=tmp_aln,
                   mobile_state=legs[0][0], target_state=legs[0][1], quiet=1)
                aln = tmp_aln
            else:
                aln = str(match)
                if aln not in _self.get_names('objects'):
                    raise pymol.CmdException('morph: unknown match "%s"' % match)
            pairs = _pairs_from_alignment(aln, obj1, obj2, _self)
            subset = '%s and %s' % (sele1, aln)
        if not pairs:
            if tmp_aln:
                _self.delete(tmp_aln)
            raise pymol.CmdException('morph: no atoms could be paired')

    # ---- output object: first conformation, paired atoms only
    _self.create(name, subset, first_state, 1, zoom=0, quiet=1)
    if tmp_aln:
        _self.delete(tmp_aln)
    natoms = _self.count_atoms(name)
    if natoms == 0:
        raise pymol.CmdException('morph: no atoms in output')

    # new object atom -> source atom (by identifiers) -> partner atom
    new_idx, pos, src_of, info = _snapshot(name, sele1, obj1, _self)
    if pairs is None:
        partner_of = dict(src_of)
    else:
        partner_of = {inew: pairs[isrc] for inew, isrc in src_of.items() if isrc in pairs}
        if len(partner_of) != natoms:
            raise pymol.CmdException('morph: internal pairing mismatch (%d of %d)'
                                     % (len(partner_of), natoms))

    def coords_of(obj, state, index_map):
        return _coords_by_pos(obj, state, index_map, pos, _self)

    # ---- generate frames leg by leg
    nlegs = len(legs)
    frames_written = 1          # state 1 already holds the first conformation
    seg_report = []
    seg_of_pos = None
    E = None
    for li, (sa, sb) in enumerate(legs):
        S = coords_of(obj1, sa, src_of)
        E = coords_of(obj2, sb, partner_of)
        last_leg = (li == nlegs - 1)
        if last_leg:
            raw = [k / float(steps - 1) for k in range(steps)]
        else:
            raw = [k / float(steps) for k in range(steps)]
        fracs = [rate_fn(f) for f in raw]
        if method == 'linear':
            gen = _frames_linear(S, E, fracs)
        else:
            segments, blend_of_pos, report = _segment_chains(
                S, E, info, core_fraction, min_hinge, hinge_blend)
            seg_report.append(report)
            if seg_of_pos is None:
                seg_of_pos = {}
                for sid, seg in enumerate(segments):
                    for p in seg.atoms:
                        seg_of_pos[p] = sid
            gen = _frames_rigid(S, E, segments, blend_of_pos, fracs)
        for k, frame in enumerate(gen):
            if li == 0 and k == 0:
                continue                        # already present as state 1
            if last_leg and k == steps - 1:
                frame = E                       # exact endpoint
            _self.load_coordset(frame, name, 0)
            frames_written += 1

    nstates = _self.count_states(name)
    if nstates != frames_written or nstates != steps * nlegs:
        raise pymol.CmdException('morph: expected %d states, got %d'
                                 % (steps * nlegs, nstates))

    # round-trip check of the write order (load_coordset is order-sensitive)
    chk = {}
    _self.iterate_state(nstates, name, 'chk[index] = (x, y, z)', space={'chk': chk})
    err = max(abs(chk[inew][a] - E[pos[inew]][a]) for inew in new_idx for a in range(3))
    if err > 1e-3:
        raise pymol.CmdException('morph: coordinate write order mismatch (%.3g)' % err)

    # ---- refinement: sculpt side chains, backbone fixed, key frames untouched
    sculpt_states(name, nstates, steps, nlegs, refinement, _self)

    if color_segments and seg_of_pos:
        _self.alter(name, 'b = seg[pos[index]]', space={'seg': seg_of_pos, 'pos': pos})
        _self.spectrum('b', 'rainbow', name)

    if hide:
        for o in {obj1, obj2}:
            if o != name:
                _self.disable(o)
    _self.set('state', 1, name)

    if not quiet:
        print(' morph: %d atoms, %d states (%d leg(s), %s, %s) in %.2fs'
              % (natoms, nstates, nlegs, method, rate, time.time() - t_start))
        for rep in seg_report[:1]:
            for ckey, nseg, hinges in rep:
                print('  chain %s/%s: %d segment(s)%s' % (
                    ckey[0] or '-', ckey[1] or '-', nseg,
                    (', hinges before residues ' + ', '.join(hinges)) if hinges else ''))
    return nstates

# vi: ts=4:sw=4:smarttab:expandtab
