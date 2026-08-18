#!/usr/bin/env python3
"""Measure Protenix peak memory against sequence length, and print the table.

`pymol.predictors.protenix.MEASURED_PEAK_MIB` and `ProtenixSizeGuard.measured` are the
only thing standing between a user and a jetsam SIGKILL mid-fold, and both are hand-typed
pairs of numbers. Until this script existed, the procedure that produced them lived
nowhere: the numbers were committed, the runs were not, and the probe sequence, machine
and build were never written down (see the METHOD block of
docs/predict-benchmark-boltz2-m3pro.csv for what that provenance looks like when it IS
recorded). That is why `MEASURED_PEAK_MIB['v2']` still has one point in it -- extending it
meant reconstructing an undocumented procedure first.

    scripts/protenix_memory_sweep.py --variant v2 --residues 60,120,250,400

What it does is deliberately dull: for each length, fold an N-terminal prefix of one
sequence at the pack's own operating point and record what MLX says it peaked at.

**It reads MLX's high-water mark, never process RSS.** Not a preference -- RSS is not
merely noisier, it is WRONG, and wrong in the direction that kills sessions. MLX allocates
Metal buffers RSS does not attribute and recycles them in a cache it need not return to
the OS, so RSS is not even monotonic in problem size: the sweep that produced base's table
read 400 residues as costing LESS than 60, and the Boltz sweep read 0.1 GB of RSS against
a 32.71 GB MLX peak. A guard fitted to RSS concludes big inputs are cheap. `ProtenixMLXCLI
predict` prints `MLX.Memory.peakMemory` and this parses that line.

**Run the control first, and do not skip it.** `--variant base` re-measures lengths that
are already in `MEASURED_PEAK_MIB`, so the run either reproduces the shipped table or
proves this harness is measuring something other than what the table records. A v2 row
taken from a harness that cannot reproduce base is not evidence about v2; it is evidence
about the harness. The script diffs against the table itself and says so.

**Release only.** A Debug (-Onone) build changes wall clock by ~10x. Peak memory survives
it -- the allocations are the same -- but a table whose seconds column came from Debug
must never be quoted, and the seconds column is half of why the caps sit where they do
(900 residues fits base and takes 2.5 hours).

Each point is its own process. That makes the high-water mark independent per point for
free, and it costs one model load per point, which is why `elapsed_s` below INCLUDES that
load and is therefore an over-estimate of inference alone by roughly the 60-residue point.

Ascending order, and the table is written after every point, so a run that has to be cut
short -- or that gets killed at the top end, which is the whole risk being characterised
-- still leaves every point it did reach.
"""
import argparse
import csv
import os
import platform
import re
import subprocess
import sys
import tempfile
import time

#: Lengths base was swept at, and therefore the lengths to sweep anything else at: a
#: variant is only comparable to base where the two were measured at the same place.
DEFAULT_RESIDUES = (60, 120, 250, 400, 550, 700)

#: Where WeightCache extracts a pack: <root>/<bundle id>/<version>.
WEIGHTS_ROOT = os.path.expanduser(
    '~/Library/Application Support/RayMol/weights')

#: Anything else is refused rather than substituted, exactly as the predictor does.
CANONICAL = 'ACDEFGHIKLMNPQRSTVWY'


def probe_sequence(length, seed=0x9E37_79B9_7F4A_7C15):
    """A deterministic canonical-20 sequence, as N-terminal prefixes of one draw.

    Prefixes of ONE sequence rather than an independent draw per length, so that length
    is the only thing that varies between points -- the same choice the Boltz benchmark
    records making with a real protein.

    Synthetic rather than a real protein, which is sound HERE and would not be for
    anything else. Peak memory is decided by the token count and the atom count, and the
    atom count follows the residue COMPOSITION, not the fold; a fixed-seed uniform draw
    over the canonical 20 lands on the same ~7.8 atoms per residue a real protein does,
    and does it reproducibly from this file alone. The structures this emits are
    meaningless and nothing should look at them.

    splitmix64 rather than `random`, so this agrees with the Swift-side generator in
    PredictMSAMemorySweepTests.sequence(length:seed:) and a number measured by either
    harness is a number about the same input.
    """
    mask = (1 << 64) - 1
    state = seed
    out = []
    for _ in range(length):
        state = (state + 0x9E37_79B9_7F4A_7C15) & mask
        z = state
        z = ((z ^ (z >> 30)) * 0xBF58_476D_1CE4_E5B9) & mask
        z = ((z ^ (z >> 27)) * 0x94D0_49BB_1331_11EB) & mask
        z ^= (z >> 31)
        out.append(CANONICAL[z % len(CANONICAL)])
    return ''.join(out)


#: What one CLI run reports. Anything absent means the run did not get far enough to be a
#: measurement, and the point is dropped rather than recorded with a hole in it.
_FIELDS = {
    'tokens': re.compile(r'^tokens/atoms\s+(\d+) / (\d+)$', re.M),
    'peak_mib': re.compile(r'^peak memory\s+(\d+) MiB$', re.M),
    'elapsed_s': re.compile(r'^elapsed\s+([\d.]+) s$', re.M),
    'mean_plddt': re.compile(r'^mean pLDDT\s+([\d.]+)$', re.M),
    'recycles': re.compile(r'^recycling\s+(\d+)$', re.M),
    'diffusion': re.compile(r'^diffusion\s+(\d+) steps$', re.M),
}


def fold(cli, model, sequence, seed=0):
    """Run one fold and return what it reported. Raises on a run that did not finish.

    stdout is returned alongside the parsed values because a run that is refused, killed,
    or silently short of the operating point has to be readable afterwards; a table row
    is not enough to tell those apart.
    """
    handle, output = tempfile.mkstemp(suffix='.pdb', prefix='protenix_sweep_')
    os.close(handle)
    try:
        started = time.time()
        # --confidence because the shipped operating point runs the confidence head, and
        # that head is four more Pairformer blocks over the same N^2 pair tensor. A sweep
        # without it measures a cheaper model than the one the app runs.
        process = subprocess.run(
            [cli, 'predict', '--model', model, '--sequence', sequence,
             '--output', output, '--seed', str(seed), '--confidence'],
            capture_output=True, text=True)
        wall = time.time() - started
        text = process.stdout + process.stderr
        if process.returncode != 0:
            raise RuntimeError('fold failed (exit %d, %.0f s wall)\n%s'
                               % (process.returncode, wall, text.strip()))
        row = {'wall_s': round(wall, 1)}
        for name, pattern in _FIELDS.items():
            match = pattern.search(text)
            if match is None:
                if name == 'mean_plddt':
                    continue
                raise RuntimeError('no %r in the CLI output:\n%s' % (name, text.strip()))
            row[name] = match.group(1)
        row['atoms'] = _FIELDS['tokens'].search(text).group(2)
        return row, text
    finally:
        if os.path.exists(output):
            os.unlink(output)


def shipped_table(variant):
    """MEASURED_PEAK_MIB[variant] if this checkout's pymol layer can be imported.

    Optional on purpose: the whole point of the control is to compare against the
    committed numbers, but a machine that can run folds and cannot import pymol should
    still be able to take the measurements.
    """
    try:
        from pymol.predictors.protenix import MEASURED_PEAK_MIB
    except ImportError:
        return None
    return dict(MEASURED_PEAK_MIB.get(variant) or ())


def provenance(variant, precision, model):
    """The header the CSV carries, so a number can be traced to what produced it."""
    def shell(command):
        try:
            return subprocess.run(command, capture_output=True, text=True,
                                  shell=True).stdout.strip()
        except OSError:
            return '?'
    memory_bytes = int(shell('sysctl -n hw.memsize') or 0)
    return [
        '# RayMol structure prediction -- Protenix (protenix-mlx) memory sweep',
        '#',
        '# HARDWARE',
        '#   machine          %s' % shell('sysctl -n machdep.cpu.brand_string'),
        '#   model            %s' % shell('sysctl -n hw.model'),
        '#   memory           %.1f GiB (%d bytes)'
        % (memory_bytes / (1024 ** 3), memory_bytes),
        '#   os               %s' % platform.mac_ver()[0],
        '#   toolchain        %s' % (shell('swift --version | head -1') or '?'),
        '#',
        '# BUILD',
        '#   NOTE Release only. A Debug (-Onone) build is ~10x slower; peak memory',
        '#        survives it but the seconds column must never be quoted from one.',
        '#',
        '# WEIGHTS',
        '#   variant          %s' % variant,
        '#   precision        %s' % precision,
        '#   artifact         %s' % model,
        '#',
        '# METHOD',
        '#   peak_mib         MLX.Memory.peakMemory, as ProtenixMLXCLI prints it. NOT',
        '#                    process RSS -- RSS is not monotonic in problem size here',
        '#                    and understates the real peak by orders of magnitude.',
        '#   elapsed_s        as the CLI reports it, INCLUDING the one-time model load,',
        '#                    because every point is its own process.',
        '#   sequences        N-terminal prefixes of one deterministic canonical-20',
        '#                    draw (splitmix64, seed 0x9E3779B97F4A7C15), so only',
        '#                    length varies. The folds are meaningless; the shapes are',
        '#                    the measurement.',
        '#   operating point  the pack\'s own: recycling and diffusion steps come from',
        '#                    its config.json, confidence head ON.',
        '#   date             %s' % time.strftime('%Y-%m-%d'),
        '#',
    ]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--variant', default='v2',
                        help='protenix variant to sweep (default: v2)')
    parser.add_argument('--precision', default='int8',
                        help='int8, float16 or bfloat16 (default: int8)')
    parser.add_argument('--residues', default=','.join(str(n) for n in DEFAULT_RESIDUES),
                        help='comma-separated lengths, ascending')
    parser.add_argument('--cli', required=True,
                        help='path to a RELEASE-built ProtenixMLXCLI')
    parser.add_argument('--model', default=None,
                        help='weights directory (default: the RayMol cache)')
    parser.add_argument('--out', default=None, help='write a CSV here as well')
    parser.add_argument('--seed', type=int, default=0)
    args = parser.parse_args(argv)

    model = args.model or os.path.join(
        WEIGHTS_ROOT, 'protenix-%s-mlx-%s' % (args.variant, args.precision), 'v1')
    if not os.path.isdir(model):
        parser.error('no weights at %s -- run `predict_weights protenix-%s-%s, '
                     'download=1` first' % (model, args.variant, args.precision))
    if not os.access(args.cli, os.X_OK):
        parser.error('%s is not executable' % args.cli)

    lengths = [int(n) for n in args.residues.split(',') if n.strip()]
    longest = probe_sequence(max(lengths), seed=0x9E37_79B9_7F4A_7C15)
    shipped = shipped_table(args.variant)

    rows = []
    header = provenance(args.variant, args.precision, model)

    def flush():
        if not args.out:
            return
        with open(args.out, 'w', newline='') as handle:
            handle.write('\n'.join(header) + '\n')
            writer = csv.writer(handle)
            writer.writerow(['residues', 'atoms', 'peak_mib', 'elapsed_s',
                             'mean_plddt', 'recycles', 'diffusion_steps'])
            writer.writerows(rows)

    print('sweeping protenix-%s-%s at %s' % (args.variant, args.precision, model))
    print('%-9s %-8s %-10s %-10s %-8s %s'
          % ('residues', 'atoms', 'peak_mib', 'elapsed_s', 'pLDDT', 'vs table'))
    for length in lengths:
        try:
            row, _ = fold(args.cli, model, longest[:length], seed=args.seed)
        except RuntimeError as error:
            # Not fatal to the table, only to this point and everything above it: a
            # length that cannot be run is exactly the finding, and the rows already
            # taken are still the honest part of the answer.
            print('\n%d residues did NOT complete -- stopping here.\n%s'
                  % (length, error))
            break
        peak = int(row['peak_mib'])
        against = ''
        if shipped and length in shipped:
            delta = 100.0 * (peak - shipped[length]) / shipped[length]
            against = '%d shipped, %+.1f%%' % (shipped[length], delta)
        print('%-9d %-8s %-10d %-10s %-8s %s'
              % (length, row['atoms'], peak, row['elapsed_s'],
                 row.get('mean_plddt', '-'), against))
        rows.append([length, row['atoms'], peak, row['elapsed_s'],
                     row.get('mean_plddt', ''), row['recycles'], row['diffusion']])
        flush()

    if not rows:
        return 1
    print('\nMEASURED_PEAK_MIB[%r], as this run measured it:' % args.variant)
    print("    %r: (%s)," % (args.variant,
                             ', '.join('(%d, %d)' % (r[0], r[2]) for r in rows)))
    print('\nOnly the lengths above are measured. A cap set above the last one here is a '
          'placeholder,\nnot a measurement -- see MEASURED_PEAK_MIB and _limit_rationale '
          'in modules/pymol/predictors/protenix.py.')
    if args.out:
        print('wrote %s' % args.out)
    return 0


if __name__ == '__main__':
    sys.exit(main())
