"""Surface-pick timing entry point (#614).

Times pymol.metal_pick.surface_at -- the drawn point and normal under a screen
point (layer3/SurfacePick.cpp) -- on a large structure, per representation
set. Run it under PyMOL's own interpreter, from the repository root:

    pymol -ckq scripts/lighting/pick_bench.py -- \\
        --pdb testing/data/1aon.pdb.gz \\
        --reps cartoon,surface,spheres,sticks,all --n 20 --viewport 1280x720

For each representation set (`all` = the four together) it hides everything,
shows the set, orients, and prints one line:

    PICKBENCH reps=<set> atoms=<N> n=<n> hits=<k> rep_build_ms=...
        accel_build_ms=... accel_mb=... cold_ms=... median_ms=... p90_ms=...
        core_median_ms=...

  rep_build_ms    the frame's update phase building the set's reps
                  (_cmd.surface_pick_prepare, update on, build off)
  accel_build_ms  building the pick grids of those reps, nothing else
                  (_cmd.surface_pick_prepare, update off, build on)
  accel_mb        heap the grids hold, in MiB (2^20 bytes)
  cold_ms         after cmd.rebuild() and an untimed update: the first
                  surface_at, which builds the grids it needs on the way
  median_ms, p90_ms
                  n warm metal_pick.surface_at(update=True) calls -- the
                  Python path #612 uses -- at n deterministic points: a grid
                  over the central 60% of the structure's projected box
                  (5 x 4 for n = 20), each point moved to the nearest
                  projected CA atom so it aims at the structure.
                  The "under 5 ms" budget is median_ms.
  core_median_ms  the same points through _cmd.surface_pick with update off:
                  what the bridge (PyMOLBridge_SurfacePick, #622's drag tick)
                  pays, plus one Python call
  hits            how many of the n warm picks hit something

Every pick and prepare considers all four pickable reps (surface, cartoon,
spheres, sticks), as #612's default and the bridge do; the set only decides
what is shown. rep_build_ms and cold_ms are first-pick costs outside the
budget; surface_warm / PyMOLBridge_SurfacePickPrepare move them off a click.

--check runs the same steps on 1rx1 (testing/data/1rx1.pdb) with n=4 and
prints NO timings: it asserts that every set hits at least once, that every
hit lies on its camera ray inside the slab with a unit normal facing the
camera, that repeat picks and the core path give identical answers, and that
the grids are reused (a repeat prepare builds nothing). It ends with
`PICKBENCH CHECK ok` (exit status 0) or `PICKBENCH CHECK FAIL ...` (exit
status 1). --pdb and --n override its structure and count.

The bench turns use_shaders on, as the app does, so sticks are built with the
app's open ends at branched atoms. The venv core and the app core share the
C++ but not necessarily the compiler flags, so the numbers are
representative, not identical. Standard library
only (numpy, when present, only speeds up projecting the atoms).
"""

import argparse
import gc
import math
import os
import statistics
import sys
import time

SETS = {
    'cartoon': ('cartoon',),
    'surface': ('surface',),
    'spheres': ('spheres',),
    'sticks': ('sticks',),
    'all': ('cartoon', 'surface', 'spheres', 'sticks'),
}
DEFAULT_SETS = 'cartoon,surface,spheres,sticks,all'
OBJECT = 'pickbench'
CHECK_PDB = os.path.join('testing', 'data', '1rx1.pdb')
TIMED_PDB = os.path.join('testing', 'data', '1aon.pdb.gz')
CHECK_N = 4
TIMED_N = 20
INSET = 0.2  # points cover the central 60% of the projected box
ON_RAY_TOL = 5e-3  # Angstrom; float32 at eye depths of a few hundred
NUDGE_MIN = 0.05  # SurfacePick's silhouette nudge: dot(normal, v) >= 0.05


class CheckError(Exception):
    pass


def _root():
    here = globals().get('__script__') or globals().get('__file__') or \
        (sys.argv[0] if sys.argv else '')
    return os.path.normpath(os.path.join(
        os.path.dirname(os.path.abspath(here)), os.pardir, os.pardir))


def _resolve(path):
    if os.path.exists(path):
        return path
    alt = os.path.join(_root(), path)
    return alt if os.path.exists(alt) else path


def parse_args(argv):
    p = argparse.ArgumentParser(
        prog='pick_bench.py', description=__doc__.split('\n\n')[0])
    p.add_argument('--pdb', default=None,
                   help='structure (default %s; --check: %s)' %
                   (TIMED_PDB, CHECK_PDB))
    p.add_argument('--reps', default=DEFAULT_SETS,
                   help='comma-separated sets out of %s (default: all of '
                   'them)' % ', '.join(SETS))
    p.add_argument('--n', type=int, default=None,
                   help='warm picks per set (default %d; --check: %d)' %
                   (TIMED_N, CHECK_N))
    p.add_argument('--viewport', default='1280x720', help='WxH')
    p.add_argument('--check', action='store_true',
                   help='correctness only, no timings')
    args = p.parse_args(argv)
    args.sets = [s for s in args.reps.replace(' ', '').split(',') if s]
    bad = [s for s in args.sets if s not in SETS]
    if bad or not args.sets:
        p.error('unknown --reps set(s): %s' % ', '.join(bad or ['(none)']))
    try:
        w, h = (int(v) for v in args.viewport.lower().split('x'))
        assert w > 0 and h > 0
    except Exception:
        p.error('--viewport must be WxH, e.g. 1280x720')
    args.size = (w, h)
    if args.n is None:
        args.n = CHECK_N if args.check else TIMED_N
    if args.n < 1:
        p.error('--n must be >= 1')
    if args.pdb is None:
        args.pdb = CHECK_PDB if args.check else TIMED_PDB
    args.pdb = _resolve(args.pdb)
    return args


# -- camera (metal_pick.camera's conventions) ----------------------------------

def _world_ray(cam, aspect, x, y):
    '''(o, d) of the camera ray through NDC (x, y): the world point at eye
    depth D is o + D * d (perspective; the bench never turns orthoscopic on).'''
    d_eye = (x * cam.tan_half * aspect, y * cam.tan_half, -1.0)
    o = tuple(sum(cam.rot[3 * k + i] * -cam.pos[k] for k in range(3)) +
              cam.origin[i] for i in range(3))
    d = tuple(sum(cam.rot[3 * k + i] * d_eye[k] for k in range(3))
              for i in range(3))
    return o, d


def _project(cam, aspect, coords):
    '''NDC (x, y) of each point in front of the camera, as a list.'''
    rot, pos, org = cam.rot, cam.pos, cam.origin
    try:
        import numpy
    except ImportError:
        numpy = None
    if numpy is not None:
        c = numpy.asarray(coords, dtype=float).reshape(-1, 3) - \
            numpy.asarray(org)
        e = c @ numpy.asarray(rot).reshape(3, 3).T + numpy.asarray(pos)
        e = e[e[:, 2] < 0]
        hh = -e[:, 2] * cam.tan_half
        return list(zip((e[:, 0] / (hh * aspect)).tolist(),
                        (e[:, 1] / hh).tolist()))
    out = []
    for p in coords:
        q = (p[0] - org[0], p[1] - org[1], p[2] - org[2])
        e = [rot[3 * k] * q[0] + rot[3 * k + 1] * q[1] + rot[3 * k + 2] * q[2]
             + pos[k] for k in range(3)]
        if e[2] < 0:
            hh = -e[2] * cam.tan_half
            out.append((e[0] / (hh * aspect), e[1] / hh))
    return out


def pick_points(cam, aspect, coords, anchors, n):
    '''(centre, points): n deterministic NDC points and the box centre.

    A cols x rows grid (cols = ceil(sqrt(n)); 5 x 4 for n = 20) over the
    central 60% of the atoms' projected box, read row by row from the
    top-left, the first n of it; each point (and the centre) then moves to
    the nearest projected anchor atom (the CA atoms), so every pick aims at
    the structure: a bare grid can fall between the strands of a cartoon.'''
    ndc = _project(cam, aspect, coords)
    xs = [p[0] for p in ndc]
    ys = [p[1] for p in ndc]
    x0, y0, x1, y1 = min(xs), min(ys), max(xs), max(ys)
    x0, x1 = x0 + INSET * (x1 - x0), x1 - INSET * (x1 - x0)
    y0, y1 = y0 + INSET * (y1 - y0), y1 - INSET * (y1 - y0)
    cols = int(math.ceil(math.sqrt(n)))
    rows = int(math.ceil(float(n) / cols))
    lerp = lambda a, b, i, m: a + (b - a) * (i / float(m - 1) if m > 1 else 0.5)
    grid = [(lerp(x0, x1, c, cols), lerp(y1, y0, r, rows))
            for r in range(rows) for c in range(cols)][:n]
    snap_to = _project(cam, aspect, anchors) or ndc

    def snap(p):
        # nearest in pixels (x scaled by the aspect), first one on a tie
        best = min(range(len(snap_to)), key=lambda i: (
            ((snap_to[i][0] - p[0]) * aspect) ** 2 +
            (snap_to[i][1] - p[1]) ** 2, i))
        return tuple(max(-1.0, min(1.0, v)) for v in snap_to[best])

    return snap((0.5 * (x0 + x1), 0.5 * (y0 + y1))), [snap(p) for p in grid]


# -- the steps -------------------------------------------------------------------

def _ms(t0):
    return (time.perf_counter() - t0) * 1000.0


def _p90(values):
    '''Nearest-rank 90th percentile.'''
    s = sorted(values)
    return s[max(0, int(math.ceil(0.9 * len(s))) - 1)]


class _NoGC(object):
    '''Keep the collector out of a timed block.'''

    def __enter__(self):
        self.was = gc.isenabled()
        gc.collect()
        gc.disable()

    def __exit__(self, *exc):
        if self.was:
            gc.enable()


def _prepare(cmd, _cmd, mask, update, build):
    with cmd.lockcm:
        return _cmd.surface_pick_prepare(cmd._COb, None, mask, update, build)


def _rep_mask(reps):
    from pymol.constants import repmasks
    mask = 0
    for r in reps:
        mask |= repmasks[r]
    return mask


def bench_set(label, ctx, check):
    '''Time one representation set; returns its result dict. With `check`,
    raises CheckError on the first wrong answer.'''
    from pymol import cmd, metal_pick
    from pymol.cmd import _cmd
    from pymol.constants import repres

    reps = SETS[label]
    mask = _rep_mask(metal_pick.SURFACE_REPS)  # the bridge's mask
    name, aspect = ctx['name'], ctx['aspect']

    cmd.hide('everything', name)
    for r in reps:
        cmd.show(r, name)
    cmd.orient(name)
    cam = metal_pick.camera()
    centre, points = pick_points(cam, aspect, ctx['coords'],
                                  ctx['anchors'], ctx['n'])

    # Fresh reps: an earlier set may already have built some of these.
    cmd.rebuild()
    with _NoGC():
        t0 = time.perf_counter()
        _prepare(cmd, _cmd, mask, 1, 0)
        rep_build_ms = _ms(t0)
        t0 = time.perf_counter()
        accels, nbytes, built = _prepare(cmd, _cmd, mask, 0, 1)
        accel_build_ms = _ms(t0)

    # Cold: reps rebuilt (untimed), grids gone; the first pick builds them.
    cmd.rebuild()
    _prepare(cmd, _cmd, mask, 1, 0)
    with _NoGC():
        t0 = time.perf_counter()
        cold = metal_pick.surface_at(centre[0], centre[1], aspect=aspect,
                                     update=True)
        cold_ms = _ms(t0)

    warm, warm_ms = [], []
    with _NoGC():
        for x, y in points:
            t0 = time.perf_counter()
            hit = metal_pick.surface_at(x, y, aspect=aspect, update=True)
            warm_ms.append(_ms(t0))
            warm.append(hit)

    core, core_ms = [], []
    with _NoGC(), cmd.lockcm:
        for x, y in points:
            t0 = time.perf_counter()
            r = _cmd.surface_pick(cmd._COb, x, y, aspect, None, mask, 0)
            core_ms.append(_ms(t0))
            core.append(r)

    result = {
        'reps': label, 'n': len(points),
        'hits': sum(1 for h in warm if h is not None),
        'accels': accels,
        'rep_build_ms': rep_build_ms, 'accel_build_ms': accel_build_ms,
        'accel_mb': nbytes / float(1 << 20), 'cold_ms': cold_ms,
        'median_ms': statistics.median(warm_ms), 'p90_ms': _p90(warm_ms),
        'core_median_ms': statistics.median(core_ms),
    }
    if not check:
        return result

    # -- correctness (--check) ----------------------------------------------
    def fail(msg):
        raise CheckError('reps=%s: %s' % (label, msg))

    if built < 1 or accels != len(reps) or nbytes <= 0:
        fail('prepare built %d grid(s), holds %d (%d bytes); expected one '
             'per shown rep (%d)' % (built, accels, nbytes, len(reps)))
    if result['hits'] < 1:
        fail('none of the %d picks hit' % len(points))
    rep_index = {r: repres[r] for r in metal_pick.SURFACE_REPS}
    front, back = cam.clip_front, cam.clip_back
    for (x, y), hit, raw in zip(points, warm, core):
        if hit is None:
            if raw is not None:
                fail('core hit %r where surface_at missed at %r' %
                     (raw, (x, y)))
            continue
        where = 'at %r: %r' % ((x, y), hit)
        if hit.object != name or hit.state != 1 or hit.rep not in reps:
            fail('wrong object/state/rep ' + where)
        o, d = _world_ray(cam, aspect, x, y)
        on = tuple(o[i] + hit.depth * d[i] for i in range(3))
        if math.sqrt(sum((a - b) ** 2 for a, b in zip(on, hit.point))) > \
                ON_RAY_TOL:
            fail('hit not on its camera ray (expected %r) %s' % (on, where))
        if front is not None and not \
                (front - 1e-3 <= hit.depth <= back + 1e-3):
            fail('depth outside the slab [%g, %g] %s' % (front, back, where))
        if abs(math.sqrt(sum(c * c for c in hit.normal)) - 1.0) > 1e-4:
            fail('normal not unit ' + where)
        dn = math.sqrt(sum(c * c for c in d))
        toward = sum(-d[i] / dn * hit.normal[i] for i in range(3))
        if toward < NUDGE_MIN - 1e-4:
            fail('normal does not face the camera (%.4f) %s' % (toward, where))
        if not -1.0 - 1e-4 <= hit.facing <= 1.0 + 1e-4:
            fail('facing out of range ' + where)
        if raw is None or tuple(raw[:8]) != tuple(hit.point) + \
                tuple(hit.normal) + (hit.depth, hit.facing) or \
                raw[8] != hit.object or raw[9] != hit.state or \
                raw[10] != rep_index[hit.rep] or \
                (bool(raw[11]), bool(raw[12])) != (hit.inside, hit.cap):
            fail('core path %r differs from surface_at %s' % (raw, where))
    again = [metal_pick.surface_at(x, y, aspect=aspect, update=True)
             for x, y in points]
    if again != warm:
        fail('repeat picks differ')
    if cold != metal_pick.surface_at(centre[0], centre[1], aspect=aspect,
                                     update=True):
        fail('the cold pick differs from a warm one at the same point')
    accels2, _, built2 = _prepare(cmd, _cmd, mask, 0, 1)
    if built2 != 0 or accels2 != len(reps):
        fail('a repeat prepare built %d grid(s) (holds %d): the grids were '
             'not reused' % (built2, accels2))
    return result


def run(argv=None, out=print):
    '''Run the bench; returns the exit status (0, or 1 for a failed check).'''
    from pymol import cmd

    args = parse_args(sys.argv[1:] if argv is None else argv)
    if not os.path.exists(args.pdb):
        out('PICKBENCH%s FAIL no structure at %s' %
            (' CHECK' if args.check else '', args.pdb))
        return 1
    cmd.reinitialize()
    cmd.viewport(*args.size)
    cmd.set('async_builds', 0)
    # Build what the app draws: Metal forces use_shaders on, and only then
    # does RepCylBond leave a bond's end open at an atom another bond already
    # capped (most stick ends in a real molecule). Headless it is off after
    # reinitialize, which would time (and check) all-capped sticks.
    cmd.set('use_shaders', 1)
    cmd.load(args.pdb, OBJECT)
    if not cmd.count_atoms(OBJECT):
        out('PICKBENCH%s FAIL no atoms in %s' %
            (' CHECK' if args.check else '', args.pdb))
        return 1
    width, height = cmd.get_viewport()
    ctx = {
        'name': OBJECT, 'n': args.n,
        'aspect': float(width) / float(height),
        'coords': cmd.get_coords(OBJECT),
    }
    # Where the picks aim: the CA trace, else any polymer atom, else any atom.
    for sele in ('%s and polymer and name CA', '%s and polymer', '%s'):
        ctx['anchors'] = cmd.get_coords(sele % OBJECT)
        if ctx['anchors'] is not None and len(ctx['anchors']):
            break
    atoms = cmd.count_atoms(OBJECT)
    if args.check:
        out('PICKBENCH CHECK pdb=%s atoms=%d viewport=%dx%d n=%d sets=%s' %
            (os.path.basename(args.pdb), atoms, width, height, args.n,
             ','.join(args.sets)))
    else:
        out('PICKBENCH setup pdb=%s atoms=%d viewport=%dx%d n=%d' %
            (os.path.basename(args.pdb), atoms, width, height, args.n))
    for label in args.sets:
        try:
            r = bench_set(label, ctx, args.check)
        except CheckError as e:
            out('PICKBENCH CHECK FAIL %s' % e)
            return 1
        if args.check:
            out('PICKBENCH CHECK reps=%s atoms=%d n=%d hits=%d accels=%d ok' %
                (label, atoms, r['n'], r['hits'], r['accels']))
        else:
            out('PICKBENCH reps=%s atoms=%d n=%d hits=%d rep_build_ms=%.3f '
                'accel_build_ms=%.3f accel_mb=%.2f cold_ms=%.3f '
                'median_ms=%.3f p90_ms=%.3f core_median_ms=%.3f' %
                (label, atoms, r['n'], r['hits'], r['rep_build_ms'],
                 r['accel_build_ms'], r['accel_mb'], r['cold_ms'],
                 r['median_ms'], r['p90_ms'], r['core_median_ms']))
    if args.check:
        out('PICKBENCH CHECK ok')
    return 0


def main():
    from pymol import cmd
    try:
        status = run()
    except SystemExit as e:  # argparse: --help, or bad arguments
        status = e.code if isinstance(e.code, int) else 1
    except Exception:
        # PyMOL's `run` would print this and still exit 0.
        import traceback
        traceback.print_exc()
        print('PICKBENCH FAIL (exception)')
        status = 1
    sys.stdout.flush()
    if status:
        cmd.quit(status)


# `pymol script.py` runs this with __name__ == 'pymol'; importing it (the CI
# test does) runs nothing.
if __name__ in ('__main__', 'pymol'):
    main()
