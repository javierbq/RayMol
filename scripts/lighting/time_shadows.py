#!/usr/bin/env python3
"""L6 timing harness for per-light shadow maps (#616, lighting epic #610).

    time_shadows.py --app APP --out DIR [--pdb-dir DIR] [--runs 3] [--frames 48]
                    [--only tag,tag] [--no-warmup] [--timeout S] [--dry-run]

THE ORCHESTRATOR RUNS THIS (both build slots held, nothing else running). CI
never asserts timings; testing/tests/raymol/lighting_shadow_check.py tests
the pure parts (the configuration matrix, the generated scripts and AUTOCMD
text, the stamped-line parsing, the arithmetic and the table).

What it measures: a 48-frame 1920x1080 movie export with metal_raytrace 1 and
metal_shadows 1 (cmd.movie_export(..., quality='standard', ray=1)) of three
public PDB structures:

    1rx1   testing/data/1rx1.pdb (about 1.3k atoms)
    1ao6   serum albumin dimer (about 9k atoms), files.rcsb.org
    7k00   E. coli 70S ribosome (mmCIF), files.rcsb.org; 1aon (58,870 atoms)
           is the fallback when 7K00 cannot be downloaded

each with no rig (norig) and with a 3-light rig whose 0, 1 or 3 lights are
shadowed (s0, s1, s3) at the default map size, plus the ribosome's s3 at
metal_light_shadow_size 1024 and 4096. Structures are downloaded once into
--pdb-dir; their atom counts are printed.

One run is one `open -n` of the app with PYMOL_AUTOCMD=run <script> and
RAYMOL_GPU_TIMING=<file>. The script loads the structure (cartoon plus
organic sticks), bakes render.py's settings plus metal_raytrace 1 and
metal_shadows 1, installs the rig with an explicit centre and size, makes a
48-frame roll (mset 1 x48, util.mroll), writes a start stamp and queues the
export ONCE per process (the app may run PYMOL_AUTOCMD twice). The renderer
writes one `offscreen 1920x1080 gpu_ms=..` line per offscreen frame, with no
time on it, so this harness tails the file every 50 ms and STAMPS each new
line on arrival. It waits for the frames' lines and a stable mp4, then ends
the app by PID (its exact binary path; never pkill -f).

Per run:
    s_per_frame    (stamp of the last line - stamp of line 1) / (frames - 1):
                   frame 1 (pipeline compiles) is left out
    s_per_frame_mp4  (mp4 final mtime - the script's start stamp) / frames
    gpu_ms_median  the median gpu_ms of lines 2..frames
Per configuration: the median over runs, and the delta of s_per_frame
against the same structure's s0. Writes DIR/results.json and DIR/table.md.

Decision rule (plans/616.md 10.6, recorded on #616 by the orchestrator): keep
the cap of 3 and the 2048 Mac default unless 3 shadowed lights add more than
25% s/frame over s0 on the ribosome; then lower the Mac default to 1024
first, and touch the cap only if that is not enough.

--dry-run writes the scripts and prints the plan; nothing is downloaded or
launched. Exit codes: 0 ok; 1 a run failed; 2 a refusal or usage error.
"""
import argparse
import datetime
import importlib.util
import json
import os
import statistics
import subprocess
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, os.pardir, os.pardir))
SIZE = (1920, 1080)
FRAMES = 48
RUNS = 3
RCSB = 'https://files.rcsb.org/download/'

# tag -> (file name, source): 'repo' (a path under the checkout) or 'rcsb'
STRUCTURES = [
    ('1rx1', 'testing/data/1rx1.pdb', 'repo'),
    ('1ao6', '1AO6.pdb', 'rcsb'),
    ('7k00', '7K00.cif', 'rcsb'),
]
FALLBACK = {'7k00': ('1aon', '1AON.pdb', 'rcsb')}
RIBOSOME = '7k00'

# The 3-light rig (camera lights; the frame is the structure's extent).
LIGHTS = [
    {'name': 'key', 'orbit': -45.0, 'pitch': 35.0, 'radius': 3.0, 'beam': 55.0,
     'softness': 0.5, 'warmth': 4500.0, 'intensity': 1.15},
    {'name': 'fill', 'orbit': 55.0, 'pitch': 5.0, 'radius': 3.0, 'beam': 80.0,
     'softness': 0.8, 'warmth': 8000.0, 'intensity': 0.35},
    {'name': 'rim', 'orbit': 160.0, 'pitch': 30.0, 'radius': 3.0, 'beam': 40.0,
     'softness': 0.4, 'intensity': 1.6},
]
SHADOWED = {'s0': 0, 's1': 1, 's3': 3}
TIMING_PREFIX = 'offscreen %dx%d gpu_ms=' % SIZE


class Refusal(Exception):
    """A usage error or a refused input: exit 2, nothing launched."""


def load_render():
    """The frozen harness (render.py): its baked settings, path refusals and
    app handling. Imported, never edited."""
    spec = importlib.util.spec_from_file_location('lighting_render',
                                                  os.path.join(HERE, 'render.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# --- the configuration matrix ---------------------------------------------------

class Config(object):
    def __init__(self, structure, rig, size=0):
        self.structure = structure      # a STRUCTURES tag
        self.rig = rig                  # 'norig', 's0', 's1' or 's3'
        self.size = int(size)           # metal_light_shadow_size; 0 = not set (default)

    @property
    def tag(self):
        return '%s_%s%s' % (self.structure, self.rig,
                            '_%d' % self.size if self.size else '')

    def __repr__(self):
        return 'Config(%r, %r, %r)' % (self.structure, self.rig, self.size)


def configs():
    """Every structure x (norig, s0, s1, s3) at the default size, plus the
    ribosome's s3 at 1024 and 4096."""
    out = [Config(s, rig) for s, _, _ in STRUCTURES for rig in ('norig', 's0', 's1', 's3')]
    out += [Config(RIBOSOME, 's3', 1024), Config(RIBOSOME, 's3', 4096)]
    return out


def rig_dict(shadowed):
    """The rig with the first `shadowed` lights shadowed; centre and size are
    filled in by the script from the structure's extent."""
    lights = [dict(l, shadow=i < shadowed) for i, l in enumerate(LIGHTS)]
    return {'version': 1, 'enabled': True, 'ambient': 0.1, 'classic': 0.0,
            'lights': lights}


# --- scripts and AUTOCMD ----------------------------------------------------------

def script_text(render, config, structure_path, mp4, start_file, frames=FRAMES):
    """One timing script: idempotent (a second run in the same process does
    nothing), so the export is queued once per process."""
    settings = render.baked_settings(1, 1)   # metal_raytrace 1, metal_shadows 1
    lines = [
        '# generated by scripts/lighting/time_shadows.py -- do not edit',
        'import json as _ts_json',
        'import time as _ts_time',
        'from pymol import cmd, util',
        '',
        'def _ts_main():',
        '    cmd.reinitialize()',
        "    cmd.reinitialize('original_settings')",
        '    cmd.load(%r, %r)' % (structure_path, 'm'),
        "    cmd.remove('solvent')",
        "    cmd.hide('everything')",
        "    cmd.show('cartoon', 'm')",
        "    cmd.show('sticks', 'm and organic and not hydro')",
        "    util.cbag('m and organic')",
    ]
    for name, value in settings:
        lines.append('    cmd.set(%r, %r)' % (name, value))
    if config.size:
        lines.append("    cmd.set('metal_light_shadow_size', %d)" % config.size)
    lines += [
        "    cmd.orient('m')",
        "    mn, mx = cmd.get_extent('m')",
        '    centre = [(a + b) / 2.0 for a, b in zip(mn, mx)]',
        '    size = sum((b - a) ** 2 for a, b in zip(mn, mx)) ** 0.5 / 2.0',
    ]
    if config.rig == 'norig':
        lines.append('    cmd.set_lights(None)')
    else:
        lines += [
            '    rig = %r' % (rig_dict(SHADOWED[config.rig]),),
            "    rig['centre'] = centre",
            "    rig['size'] = size",
            '    cmd.set_lights(rig)',
        ]
    lines += [
        "    cmd.mset('1 x%d')" % frames,
        '    util.mroll(1, %d, 1)' % frames,
        '    cmd.frame(1)',
        '    with open(%r, %r) as fh:' % (start_file, 'w'),
        "        _ts_json.dump({'tag': %r, 'start': _ts_time.time(), "
        "'atoms': cmd.count_atoms('m'), 'frames': cmd.count_frames()}, fh)" % config.tag,
        '    cmd.movie_export(%r, %d, %d, quality=%r, ray=1)' % (mp4, SIZE[0], SIZE[1], 'standard'),
        '',
        '# PYMOL_AUTOCMD may run this twice: queue the export once per process',
        "if not getattr(cmd, '_ts_started', False):",
        '    cmd._ts_started = True',
        '    _ts_main()',
    ]
    return '\n'.join(lines) + '\n'


def autocmd(script):
    return 'run %s' % script


FORBIDDEN_AUTOCMD = (';', 'orient', 'reset', 'load ', 'fetch ', 'show ', '.pse')


def check_autocmd(text):
    """Refuse AUTOCMD text the app would split or act on."""
    lower = text.lower()
    for word in FORBIDDEN_AUTOCMD:
        if word in lower:
            raise Refusal('AUTOCMD %r contains %r' % (text, word))
    return text


def launch_env(script, timing_file):
    return [
        'PYMOL_SKIP_WHATS_NEW=1',
        'PYMOL_SKIP_FIRSTBOOT_THEME=1',
        'PYMOL_AUTOTHEME=Classic',
        'PYMOL_AUTOCMD=%s' % check_autocmd(autocmd(script)),
        'RAYMOL_GPU_TIMING=%s' % timing_file,
    ]


# --- the timing file ------------------------------------------------------------

def parse_gpu_ms(line):
    """The gpu_ms of an `offscreen 1920x1080 gpu_ms=..` line, else None."""
    line = line.strip()
    if not line.startswith(TIMING_PREFIX):
        return None
    try:
        return float(line[len(TIMING_PREFIX):].split()[0])
    except (ValueError, IndexError):
        return None


class Tailer(object):
    """Reads lines appended to a file and stamps each complete one with
    clock() when it is first seen. Lines carry no time of their own."""

    def __init__(self, path, clock=time.time):
        self.path = path
        self.clock = clock
        self.offset = 0
        self.partial = ''
        self.stamped = []           # [(stamp, line)]

    def poll(self):
        try:
            with open(self.path) as fh:
                fh.seek(self.offset)
                text = fh.read()
                self.offset = fh.tell()
        except OSError:
            return 0
        if not text:
            return 0
        now = self.clock()
        text = self.partial + text
        lines = text.split('\n')
        self.partial = lines.pop()
        for line in lines:
            if line.strip():
                self.stamped.append((now, line))
        return len(lines)

    def frames(self):
        """[(stamp, gpu_ms)] of the offscreen lines at the export size."""
        out = []
        for stamp, line in self.stamped:
            ms = parse_gpu_ms(line)
            if ms is not None:
                out.append((stamp, ms))
        return out


def summarise_run(frames_seen, frames, start=None, mp4_end=None):
    """The numbers of one run from its stamped offscreen lines."""
    n = len(frames_seen)
    out = {'lines': n, 'frames': frames}
    if n >= frames >= 2:
        # line `frames` (48), not the last: a stray extra line never stretches it
        out['s_per_frame'] = (frames_seen[frames - 1][0] - frames_seen[0][0]) / float(frames - 1)
        out['gpu_ms_median'] = statistics.median(ms for _, ms in frames_seen[1:frames])
    else:
        out['s_per_frame'] = None
        out['gpu_ms_median'] = None
    if start is not None and mp4_end is not None and frames:
        out['s_per_frame_mp4'] = (mp4_end - start) / float(frames)
    else:
        out['s_per_frame_mp4'] = None
    out['complete'] = n == frames
    return out


def _median(values):
    values = [v for v in values if v is not None]
    return statistics.median(values) if values else None


def summarise(results):
    """{tag: {...per-config medians..., 'delta_vs_s0'}} from
    {tag: {'config': Config, 'runs': [run summaries], 'atoms': n}}."""
    out = {}
    for tag, entry in results.items():
        runs = entry['runs']
        out[tag] = {
            'structure': entry['config'].structure,
            'rig': entry['config'].rig,
            'size': entry['config'].size,
            'atoms': entry.get('atoms'),
            'runs': len(runs),
            's_per_frame': _median([r['s_per_frame'] for r in runs]),
            's_per_frame_mp4': _median([r['s_per_frame_mp4'] for r in runs]),
            'gpu_ms_median': _median([r['gpu_ms_median'] for r in runs]),
        }
    for tag, row in out.items():
        base = out.get('%s_s0' % row['structure'])
        if (row['rig'] != 'norig' and base and base['s_per_frame'] and
                row['s_per_frame'] is not None):
            row['delta_vs_s0'] = row['s_per_frame'] / base['s_per_frame'] - 1.0
        else:
            row['delta_vs_s0'] = None
    return out


def _num(v, fmt):
    return '-' if v is None else fmt % v


def table(summary, order=None):
    """The markdown table for the issue."""
    rows = ['| Structure | Atoms | Config | Map size | s/frame | s/frame (mp4) | '
            'GPU ms (median) | vs s0 |',
            '| --- | --- | --- | --- | --- | --- | --- | --- |']
    for tag in order or sorted(summary):
        r = summary[tag]
        rows.append('| %s | %s | %s | %s | %s | %s | %s | %s |' % (
            r['structure'], _num(r['atoms'], '%d'), r['rig'],
            r['size'] or 'default', _num(r['s_per_frame'], '%.3f'),
            _num(r['s_per_frame_mp4'], '%.3f'), _num(r['gpu_ms_median'], '%.1f'),
            _num(None if r['delta_vs_s0'] is None else 100.0 * r['delta_vs_s0'], '%+.1f%%')))
    return '\n'.join(rows) + '\n'


# --- structures ------------------------------------------------------------------

def count_atoms(path):
    """ATOM/HETATM records of a PDB or mmCIF file."""
    n = 0
    with open(path) as fh:
        for line in fh:
            if line.startswith('ATOM') or line.startswith('HETATM'):
                n += 1
    return n


def structure_path(tag, pdb_dir, download=True):
    """The local path of a structure, downloading it once. Returns
    (tag actually used, path)."""
    entries = {t: (f, src) for t, f, src in STRUCTURES}
    name, src = entries[tag]
    candidates = [(tag, name, src)]
    if tag in FALLBACK:
        candidates.append(FALLBACK[tag])
    for used, name, src in candidates:
        if src == 'repo':
            return used, os.path.join(ROOT, name)
        path = os.path.join(pdb_dir, name)
        if os.path.isfile(path) and os.path.getsize(path) > 0:
            return used, path
        if not download:
            return used, path
        try:
            os.makedirs(pdb_dir, exist_ok=True)
            tmp = path + '.part'
            urllib.request.urlretrieve(RCSB + name, tmp)
            os.replace(tmp, path)
            return used, path
        except OSError as e:
            print('download of %s failed: %s' % (name, e), flush=True)
    raise Refusal('cannot get structure %s' % tag)


# --- running ------------------------------------------------------------------------

def run_once(render, app, binaries, script, timing, mp4, start_file, frames, timeout):
    """One export; returns (run summary, error or None)."""
    for p in (timing, mp4, start_file):
        if os.path.exists(p):
            os.remove(p)
    render.kill_app(binaries)
    env = []
    for item in launch_env(script, timing):
        env += ['--env', item]
    tail = Tailer(timing)
    err = None
    try:
        res = subprocess.run(['open', '-n'] + env + [app])
        if res.returncode != 0:
            return summarise_run([], frames), 'open exited %d' % res.returncode
        deadline = time.time() + timeout
        last_size, stable_since = -1, None
        while time.time() < deadline:
            tail.poll()
            if len(tail.frames()) >= frames and os.path.isfile(mp4):
                size = os.path.getsize(mp4)
                if size > 0 and size == last_size:
                    if stable_since is None:
                        stable_since = time.time()
                    elif time.time() - stable_since >= 3.0:
                        break
                else:
                    stable_since = None
                last_size = size
            time.sleep(0.05)
        else:
            err = 'timeout after %ds (%d lines, mp4 %s)' % (
                timeout, len(tail.frames()), 'present' if os.path.isfile(mp4) else 'missing')
    finally:
        render.kill_app(binaries)
    start = None
    try:
        with open(start_file) as fh:
            start = json.load(fh)
    except (OSError, ValueError):
        err = err or 'no start stamp (the script did not run)'
    mp4_end = os.path.getmtime(mp4) if os.path.isfile(mp4) else None
    out = summarise_run(tail.frames(), frames, start and start.get('start'), mp4_end)
    out['atoms'] = start and start.get('atoms')
    if not err and not out['complete']:
        err = '%d offscreen lines, expected %d' % (out['lines'], frames)
    return out, err


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--app', help='the staged dev app (its own bundle id)')
    ap.add_argument('--out', required=True)
    ap.add_argument('--pdb-dir', help='structure cache (default OUT/pdb)')
    ap.add_argument('--runs', type=int, default=RUNS)
    ap.add_argument('--frames', type=int, default=FRAMES)
    ap.add_argument('--only', help='comma-separated config tags')
    ap.add_argument('--no-warmup', action='store_true',
                    help='skip the throwaway 2-frame run before the timed ones')
    ap.add_argument('--timeout', type=int, default=3600, help='seconds per run')
    ap.add_argument('--dry-run', action='store_true',
                    help='write the scripts and print the plan; launch nothing')
    args = ap.parse_args(argv)
    try:
        render = load_render()
        out = os.path.abspath(args.out)
        pdb_dir = os.path.abspath(args.pdb_dir or os.path.join(out, 'pdb'))
        render.check_path('--out', out)
        render.check_path('--pdb-dir', pdb_dir)
        if args.runs < 1 or args.frames < 2:
            raise Refusal('--runs must be >= 1 and --frames >= 2')
        todo = configs()
        if args.only:
            wanted = [t for t in args.only.split(',') if t]
            known = [c.tag for c in todo]
            unknown = [t for t in wanted if t not in known]
            if unknown:
                raise Refusal('unknown configs %s (known: %s)' % (
                    ', '.join(unknown), ', '.join(known)))
            todo = [c for c in todo if c.tag in wanted]
        app = binaries = None
        if not args.dry_run:
            if not args.app:
                raise Refusal('--app is required (or --dry-run)')
            app = os.path.abspath(args.app).rstrip('/')
            render.check_path('--app', app)
            _, exe = render.check_app(app)
            binary = os.path.join(app, 'Contents', 'MacOS', exe)
            binaries = {binary, os.path.realpath(binary)}
        work = os.path.join(out, '_work')
        os.makedirs(work, exist_ok=True)
        paths = {}
        for tag, _, _ in STRUCTURES:
            used, path = structure_path(tag, pdb_dir, download=not args.dry_run)
            render.check_path('structure', path)
            paths[tag] = (used, path)
            if os.path.isfile(path):
                print('%s: %s, %d atom records' % (used, path, count_atoms(path)), flush=True)
            else:
                print('%s: %s (not downloaded: dry run)' % (used, path), flush=True)
        plan = []
        for config in todo:
            for run in range(1, args.runs + 1):
                stem = os.path.join(work, '%s_r%d' % (config.tag, run))
                script = stem + '.py'
                files = {'script': script, 'timing': stem + '.timing',
                         'mp4': os.path.join(out, '%s_r%d.mp4' % (config.tag, run)),
                         'start': stem + '.start.json'}
                for label in ('script', 'timing', 'mp4', 'start'):
                    render.check_path(label, files[label])
                with open(script, 'w') as fh:
                    fh.write(script_text(render, config, paths[config.structure][1],
                                         files['mp4'], files['start'], args.frames))
                plan.append((config, run, files))
        for config, run, files in plan:
            print('%-16s run %d  AUTOCMD=%s' % (config.tag, run, autocmd(files['script'])))
        if args.dry_run:
            print('dry run: %d runs of %d configs, scripts in %s' % (
                len(plan), len(todo), work))
            return 0

        if not args.no_warmup:
            warm = Config('1rx1', 'norig')
            stem = os.path.join(work, '_warm')
            with open(stem + '.py', 'w') as fh:
                fh.write(script_text(render, warm, paths['1rx1'][1], stem + '.mp4',
                                     stem + '.start.json', 2))
            _, err = run_once(render, app, binaries, stem + '.py', stem + '.timing',
                              stem + '.mp4', stem + '.start.json', 2, args.timeout)
            print('[warm] %s (numbers discarded)' % (err or 'ok'), flush=True)

        started = datetime.datetime.now().isoformat(timespec='seconds')
        results, failed = {}, []
        for n, (config, run, files) in enumerate(plan, 1):
            summary, err = run_once(render, app, binaries, files['script'], files['timing'],
                                    files['mp4'], files['start'], args.frames, args.timeout)
            summary['error'] = err
            entry = results.setdefault(config.tag, {'config': config, 'runs': []})
            entry['runs'].append(summary)
            entry['atoms'] = summary.get('atoms') or entry.get('atoms')
            print('[%d/%d] %s run %d: %s' % (
                n, len(plan), config.tag, run,
                err or 's/frame %s, gpu_ms median %s' % (
                    _num(summary['s_per_frame'], '%.3f'),
                    _num(summary['gpu_ms_median'], '%.1f'))), flush=True)
            if err:
                failed.append('%s_r%d' % (config.tag, run))
        summary = summarise(results)
        sha = None
        if os.path.isfile(app + '.sha'):
            with open(app + '.sha') as fh:
                sha = fh.read().strip()
        with open(os.path.join(out, 'results.json'), 'w') as fh:
            json.dump({'app': app, 'app_sha': sha, 'started': started,
                       'ended': datetime.datetime.now().isoformat(timespec='seconds'),
                       'frames': args.frames, 'size': list(SIZE),
                       'structures': {t: p for t, p in paths.items()},
                       'summary': summary, 'failed': failed,
                       'runs': {t: e['runs'] for t, e in results.items()}}, fh, indent=2)
        text = table(summary, [c.tag for c in todo if c.tag in summary])
        with open(os.path.join(out, 'table.md'), 'w') as fh:
            fh.write(text)
        print(text)
        if failed:
            print('%d runs failed: %s' % (len(failed), ', '.join(failed)))
            return 1
        return 0
    except Refusal as e:
        print('time_shadows.py: %s' % e, file=sys.stderr)
        return 2
    except Exception as e:     # render.Refusal and friends
        if type(e).__name__ == 'Refusal':
            print('time_shadows.py: %s' % e, file=sys.stderr)
            return 2
        raise


if __name__ == '__main__':
    sys.exit(main())
