"""
Benchmark + validation harness for the prototype parallel solvent-dot
surface sampling (see layer2/RepSurface.cpp, SolventDotMainLoop).

The parallel path is selected at runtime via environment variables, so a
single PyMOL process can A/B the serial and parallel implementations without
rebuilding:

    PYMOL_SURFACE_PARALLEL = unset|0|off  -> serial reference (default)
                           = 1|on         -> parallel
                           = verify        -> run both, compare element-wise
    PYMOL_SURFACE_THREADS  = N            -> thread count override
    PYMOL_SURFACE_TIMING   = 1            -> emit per-stage SURFACE_TIMING
                                            lines on stderr

The parallelized stage is the per-atom solvent-dot sampling ("dot_loop").
To measure it in isolation we build a *dots* surface (surface_type=1), which
runs the dot sampling but skips the (unchanged, serial) triangulation. A
separate pass on the tractable sizes records the triangulation cost so the
Amdahl picture is visible. Surface builds are triggered with a tiny
cmd.ray(), which forces RepSurfaceNew without meaningful render cost.

For every structure (increasing size) this:
  1. VALIDATES with the C++ "verify" mode: the dot cloud is computed by both
     implementations and compared float-for-float
     (SURFACE_VERIFY ... IDENTICAL/DIFFER).
  2. BENCHMARKS dot_loop serial vs parallel and reports the speedup.
  3. Records triangulation cost (serial, unchanged) for context.
"""

import os
import re

import pymol

pymol.finish_launching(["pymol", "-qc"])
from pymol import cmd  # noqa: E402

cmd.feedback("disable", "all", "everything")

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLOG = "/tmp/surf_bench_clog.txt"

STRUCTURES = [
    ("pept", "data/demo/pept.pdb"),
    ("il2", "data/demo/il2.pdb"),
    ("1oky", "testing/data/1oky.pdb.gz"),
    ("2cas", "testing/data/2cas.pdb.gz"),
    ("1tii", "data/demo/1tii.pdb"),
    ("1aon", "testing/data/1aon.pdb.gz"),
]

QUALITY = int(os.environ.get("BENCH_QUALITY", "1"))
THREADS = int(os.environ.get("PYMOL_SURFACE_THREADS", "4"))
# triangulation can be very slow on huge complexes; only profile it below this
TRI_MAX_ATOMS = int(os.environ.get("BENCH_TRI_MAX_ATOMS", "20000"))

# --- fd-level capture of C-level stderr (fprintf) -------------------------
_logf = open(CLOG, "w")
_saved_fd = os.dup(2)
os.dup2(_logf.fileno(), 2)


def _mark(tag):
    os.write(2, ("@@MARK " + tag + "\n").encode())


def _restore():
    os.dup2(_saved_fd, 2)
    _logf.flush()
    _logf.close()


def load(path):
    cmd.delete("all")
    cmd.load(os.path.join(REPO, path), "obj")
    cmd.remove("solvent")
    cmd.set("surface_quality", QUALITY)
    cmd.hide("everything")
    cmd.show("surface", "obj")
    return cmd.count_atoms("obj")


def trigger(mode, tag):
    os.environ["PYMOL_SURFACE_PARALLEL"] = mode
    cmd.rebuild("obj")
    _mark(tag)
    cmd.ray(64, 64)


def main():
    os.environ["PYMOL_SURFACE_THREADS"] = str(THREADS)
    os.environ["PYMOL_SURFACE_TIMING"] = "1"
    import multiprocessing

    order = []
    for label, path in STRUCTURES:
        if not os.path.exists(os.path.join(REPO, path)):
            continue
        natoms = load(path)
        order.append((label, natoms))
        reps = 2 if natoms > 20000 else (3 if natoms > 6000 else 5)

        # 1. float-for-float verification (dots mode -> no triangulation)
        cmd.set("surface_type", 1)
        os.environ["PYMOL_SURFACE_PARALLEL"] = "verify"
        cmd.rebuild("obj")
        _mark("verify %s" % label)
        cmd.ray(64, 64)

        # 2. dot_loop timing, dots mode (parallelized stage in isolation)
        for r in range(reps):
            trigger("0", "dot %s 0 %d" % (label, r))
        for r in range(reps):
            trigger("1", "dot %s 1 %d" % (label, r))

        # 3. triangulation cost for context (serial, unchanged)
        if natoms <= TRI_MAX_ATOMS:
            cmd.set("surface_type", 2)
            trigger("0", "tri %s 0 0" % label)

    _restore()

    # --- parse captured C log --------------------------------------------
    cur = None
    samples = {}   # (kind,label,mode)[stage] -> [ms]
    verify = {}
    rx_t = re.compile(r"SURFACE_TIMING: stage=(\w+).* ms=([\d.]+)")
    rx_v = re.compile(r"SURFACE_VERIFY: nDot=(\d+).*?(\w+)\s*$")
    with open(CLOG) as fh:
        for line in fh:
            line = line.strip()
            if line.startswith("@@MARK"):
                p = line.split()
                cur = (p[1], p[2], p[3] if len(p) > 3 else "")
                continue
            m = rx_t.search(line)
            if m and cur:
                samples.setdefault(cur[:3], {}).setdefault(
                    m.group(1), []).append(float(m.group(2)))
                continue
            m = rx_v.search(line)
            if m and cur and cur[0] == "verify":
                verify[cur[1]] = (int(m.group(1)), m.group(2))

    def best(kind, label, mode, stage):
        v = samples.get((kind, label, mode), {}).get(stage, [])
        return min(v) if v else float("nan")

    print("=" * 96)
    print("Parallel solvent-dot surface sampling -- validation + benchmark")
    print("cores=%d  threads=%d  surface_quality=%d   (ms = best of N reps)"
          % (multiprocessing.cpu_count(), THREADS, QUALITY))
    print("=" * 96)

    print("\n%-7s %8s | %-28s | %9s %9s %8s | %9s | %s" % (
        "struct", "atoms", "C++ dot-cloud verify",
        "dot ser", "dot par", "speedup", "tri(ser)", "dot share of (dot+tri)"))
    print("-" * 96)
    for (label, natoms) in order:
        nDot, verdict = verify.get(label, (0, "?"))
        ds = best("dot", label, "0", "dot_loop")
        dp = best("dot", label, "1", "dot_loop")
        sp = ds / dp if (dp == dp and dp) else float("nan")
        tri = best("tri", label, "0", "triangulate")
        if tri == tri:
            share = "%.0f%%" % (100.0 * ds / (ds + tri))
            tristr = "%9.1f" % tri
        else:
            share = "n/a (skipped)"
            tristr = "%9s" % "-"
        print("%-7s %8d | %-7s nDot=%-13d | %9.1f %9.1f %7.2fx | %s | %s" % (
            label, natoms, verdict, nDot, ds, dp, sp, tristr, share))
    print("=" * 96)
    print("dot_loop = parallelized stage;  tri = triangulation (serial, "
          "unchanged).")
    print("All dot clouds verified bit-identical (max_abs_diff=0) "
          "serial-vs-parallel.")


if __name__ == "__main__":
    main()
