#!/usr/bin/env python3
"""L6 timing, idle and movie-export harness for the air (#618, lighting epic #610).

    time_air.py --mode export --app APP --out DIR [--pdb-dir DIR] [--runs 3]
                [--frames 48] [--only tag,tag] [--no-warmup] [--timeout S]
                [--start-timeout S] [--dry-run]
    time_air.py --mode idle --app APP --out DIR [--only cfg,cfg] [--settle 15]
                [--measure 10] [--dry-run]
    time_air.py --mode movie --app APP --out DIR [--frames 4] [--timeout S]
                [--dry-run]

THE ORCHESTRATOR RUNS export and idle (both build slots held, nothing else
running); the implementer runs a 2-frame export smoke, a short idle smoke and
the movie check. CI never asserts timings: testing/tests/raymol/
lighting_air_check.py tests the pure parts (the configuration matrices, the
generated scripts and AUTOCMD text, the idle parsing and verdicts, the movie
comparisons and the tables).

This is #616's scripts/lighting/time_shadows.py, imported and never edited:
its run-2 export guard and AUTOEXPORT probe (an export queued at launch
races the first live frame, #654), launch_env and check_autocmd (AUTOCMD
refusals), run_once and Tailer (stamped `offscreen WxH gpu_ms=` lines,
LINES_PER_FRAME = 2 per ray=1 frame), structure_path (the PDB cache),
summarise and table.

--mode export (L6): a 48-frame 1920x1080 movie export with metal_raytrace 1
and metal_shadows 1 (cmd.movie_export(..., quality='standard', ray=1)) of
1rx1, 1ao6 and 7k00 (1aon fallback), each as
    s3            time_shadows' 3-light rig, all three shadowed, no air (the base)
    s3_air        + haze 0.3, dust 0.5, dust_speed 1; metal_light_air_resolution 1,
                  metal_light_air_shadow_filter 1
    s0_air        no shadowed light, with the same air
and, on 1rx1 and 7k00 only,
    s3_air_half   s3_air at metal_light_air_resolution 2
    s3_air_f9     s3_air at metal_light_air_shadow_filter 2 (#616's 3x3 lookup)
The dust clock is not pinned: export frame N has dust time (N - 1) / movie_fps.
Per configuration: s/frame over frames 2..N, the median gpu_ms, and the delta
against the structure's s3. Writes DIR/results.json and DIR/table.md. Report
only (Q8): a row over AIR_FLAG (+25%) is flagged for the orchestrator, and
s3_air against s3_air_f9 informs the haze shadow-filter default (Q1).

--mode idle: one `open -n` launch per configuration (1rx1, cartoon and organic
sticks, a live view at metal_raytrace 0):
    norig        no rig                   rig_noair    a rig without air
    haze         haze only (still)        dust_speed0  dust at dust_speed 0
    dust_pinned  dust, metal_light_air_time 1         dust  dust moving (the control)
After --settle seconds it measures --measure seconds: live frames/s from the
RAYMOL_GPU_TIMING `frames/s=` lines that arrive in the window (no line reads
as 0 frames/s) and CPU% from `ps -o %cpu=` once a second. Pass: every
configuration but dust at most IDLE_FPS frames/s with CPU within CPU_TOL points
of norig, and dust between DUST_FPS. dust at 0 frames/s means a locked or
sleeping display: INCONCLUSIVE (exit 3), never a pass. The app activates itself
at launch, so background, inactive and Low Power are not measured here
(AirRedrawGateTests and the manual checks cover them).

--mode movie (done-when: dust follows movie time in exports): a shadowed spot,
haze 0.3, dust 0.8, dust_speed 1, `mset 1 x<frames>` with a still camera,
movie_fps 30. Two launches each export the movie as a PNG sequence at
MOVIE_SIZE with ray=1 (the scripted exporter runs one export at a time, so one
launch each), then one launch per frame k renders a still (PYMOL_AUTOEXPORT,
ray-traced) at frame k with metal_light_air_time pinned to (k - 1) / 30. Pass:
the two exports are byte-identical frame for frame; consecutive frames differ;
frame k is nearest to still k of all the stills, within MOVIE_STILL_TOL.

--dry-run writes the scripts and prints the plan; nothing is downloaded or
launched. Exit codes: 0 ok; 1 a run or check failed; 2 a refusal or usage
error; 3 the idle run was inconclusive.
"""
import argparse
import datetime
import importlib.util
import json
import os
import re
import statistics
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))


def _load(name, filename):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ts = _load('lighting_time_shadows', 'time_shadows.py')
Refusal = ts.Refusal
LINES_PER_FRAME = ts.LINES_PER_FRAME
PROBE = ts.PROBE

MODES = ('export', 'idle', 'movie')

# --- export (L6) ---------------------------------------------------------------

AIR = {'haze': 0.3, 'dust': 0.5, 'dust_size': 0.35, 'dust_speed': 1.0,
       'scatter': 0.55, 'seed': 7}
# variant -> (shadowed lights, air, metal_light_air_resolution, metal_light_air_shadow_filter)
VARIANTS = {
    's3': (3, None, None, None),
    's3_air': (3, AIR, 1, 1),
    's0_air': (0, AIR, 1, 1),
    's3_air_half': (3, AIR, 2, 1),
    's3_air_f9': (3, AIR, 1, 2),
}
EVERY = ('s3', 's3_air', 's0_air')
SWEEP = ('s3_air_half', 's3_air_f9')
SWEEP_STRUCTURES = ('1rx1', '7k00')
AIR_FLAG = 0.25          # Q8: report a configuration adding more than this over s3


class AirConfig(object):
    def __init__(self, structure, variant):
        if variant not in VARIANTS:
            raise Refusal('unknown variant %r' % (variant,))
        self.structure = structure
        self.variant = variant
        # what time_shadows.summarise and table read
        self.rig = variant
        self.size = 0

    @property
    def tag(self):
        return '%s_%s' % (self.structure, self.variant)

    def __repr__(self):
        return 'AirConfig(%r, %r)' % (self.structure, self.variant)


def configs():
    """Every structure x (s3, s3_air, s0_air), plus the half-resolution and
    3x3-filter sweeps on 1rx1 and 7k00."""
    out = []
    for s, _, _ in ts.STRUCTURES:
        out += [AirConfig(s, v) for v in EVERY]
        if s in SWEEP_STRUCTURES:
            out += [AirConfig(s, v) for v in SWEEP]
    return out


SET_LIGHTS = '    cmd.set_lights(rig)\n'


def air_lines(variant, indent='    '):
    """The lines a variant adds before its rig is installed."""
    _, air, res, filt = VARIANTS[variant]
    lines = []
    if air is not None:
        lines.append("%srig['air'] = %r" % (indent, air))
    if res is not None:
        lines.append("%scmd.set('metal_light_air_resolution', %d)" % (indent, res))
    if filt is not None:
        lines.append("%scmd.set('metal_light_air_shadow_filter', %d)" % (indent, filt))
    return lines


def script_text(render, config, structure_path, mp4, start_file, frames=ts.FRAMES):
    """time_shadows' script for the variant's rig (its run-2 export guard,
    probe-deferred export and start stamp, unchanged), with the air and the
    #618 settings added just before the rig is installed."""
    shadowed = VARIANTS[config.variant][0]
    base = ts.script_text(render, ts.Config(config.structure, 's%d' % shadowed),
                          structure_path, mp4, start_file, frames)
    if base.count(SET_LIGHTS) != 1:
        raise Refusal('time_shadows.script_text changed: %r not found once' % SET_LIGHTS)
    add = air_lines(config.variant)
    text = base.replace(SET_LIGHTS, ''.join(l + '\n' for l in add) + SET_LIGHTS)
    stamp = "'tag': %r" % ts.Config(config.structure, 's%d' % shadowed).tag
    text = text.replace(stamp, "'tag': %r" % config.tag)
    return text.replace('# generated by scripts/lighting/time_shadows.py -- do not edit',
                        '# generated by scripts/lighting/time_air.py (time_shadows.py '
                        'plus the air) -- do not edit')


def summarise(results):
    """time_shadows.summarise plus 'delta_vs_s3' against the structure's s3."""
    out = ts.summarise(results)
    for row in out.values():
        base = out.get('%s_s3' % row['structure'])
        if (row['rig'] != 's3' and base and base['s_per_frame'] and
                row['s_per_frame'] is not None):
            row['delta_vs_s3'] = row['s_per_frame'] / base['s_per_frame'] - 1.0
        else:
            row['delta_vs_s3'] = None
    return out


def table(summary, order=None):
    """time_shadows.table with the delta against s3 in its last column."""
    rows = {t: dict(r, delta_vs_s0=r.get('delta_vs_s3')) for t, r in summary.items()}
    return ts.table(rows, order).replace('| vs s0 |', '| vs s3 |')


def flags(summary):
    """Q8: configurations whose air adds more than AIR_FLAG s/frame over s3;
    Q1: the 3x3 haze lookup against the one tap."""
    out = []
    for tag in sorted(summary):
        d = summary[tag].get('delta_vs_s3')
        if d is not None and d > AIR_FLAG:
            out.append('FLAG %s: %+.1f%% s/frame over s3 (> %+.0f%%)' % (
                tag, 100.0 * d, 100.0 * AIR_FLAG))
    for s in SWEEP_STRUCTURES:
        one, nine = summary.get('%s_s3_air' % s), summary.get('%s_s3_air_f9' % s)
        if one and nine and one['s_per_frame'] and nine['s_per_frame'] is not None:
            out.append('Q1 %s: 3x3 haze lookup %+.1f%% s/frame against the one tap' % (
                s, 100.0 * (nine['s_per_frame'] / one['s_per_frame'] - 1.0)))
    return out


# --- idle -------------------------------------------------------------------------

IDLE_CONFIGS = ('norig', 'rig_noair', 'haze', 'dust_speed0', 'dust_pinned', 'dust')
IDLE_FPS = 0.5           # idle: at most this many frames/s (a stray frame in the window)
CPU_TOL = 3.0            # idle: CPU% within this many points of norig
DUST_FPS = (20.0, 31.0)  # the moving-dust control: the 30 Hz cap, give or take
SETTLE = 15
MEASURE = 10
FRAMES_RE = re.compile(r'\bframes/s=([0-9.]+)')


def idle_air(config):
    """(air dict or None, metal_light_air_time or None, rig or None) of an idle
    configuration."""
    if config not in IDLE_CONFIGS:
        raise Refusal('unknown idle config %r (known: %s)' % (config, ', '.join(IDLE_CONFIGS)))
    return {
        'norig': (None, None, False),
        'rig_noair': (None, None, True),
        'haze': (dict(AIR, dust=0.0), None, True),
        'dust_speed0': (dict(AIR, dust_speed=0.0), None, True),
        'dust_pinned': (dict(AIR), 1.0, True),
        'dust': (dict(AIR), None, True),
    }[config]


def idle_script_text(render, config, structure_path):
    """An idempotent live-view scene (every AUTOCMD run re-applies it)."""
    air, pin, rig = idle_air(config)
    lines = [
        '# generated by scripts/lighting/time_air.py (idle) -- do not edit',
        'from pymol import cmd, util',
        'cmd.reinitialize()',
        "cmd.reinitialize('original_settings')",
        'cmd.load(%r, %r)' % (structure_path, 'm'),
        "cmd.remove('solvent')",
        "cmd.hide('everything')",
        "cmd.show('cartoon', 'm')",
        "cmd.show('sticks', 'm and organic and not hydro')",
        "util.cbag('m and organic')",
    ]
    for name, value in render.baked_settings(0, 1):
        lines.append('cmd.set(%r, %r)' % (name, value))
    if pin is not None:
        lines.append("cmd.set('metal_light_air_time', %r)" % pin)
    lines += [
        "cmd.orient('m')",
        "mn, mx = cmd.get_extent('m')",
    ]
    if not rig:
        lines.append('cmd.set_lights(None)')
    else:
        lines += [
            'rig = %r' % (ts.rig_dict(1),),
            "rig['centre'] = [(a + b) / 2.0 for a, b in zip(mn, mx)]",
            "rig['size'] = sum((b - a) ** 2 for a, b in zip(mn, mx)) ** 0.5 / 2.0",
        ]
        if air is not None:
            lines.append("rig['air'] = %r" % (air,))
        lines.append('cmd.set_lights(rig)')
    return '\n'.join(lines) + '\n'


def parse_frames(line):
    """The frames/s of a RAYMOL_GPU_TIMING live line, else None."""
    m = FRAMES_RE.search(line)
    if not m:
        return None
    try:
        return float(m.group(1))
    except ValueError:
        return None


def idle_summary(stamped, start, end, cpu):
    """{'fps', 'lines', 'cpu', 'cpu_samples'} of one idle run: the mean
    frames/s of the live lines stamped in [start, end] (no line: 0), and the
    mean of the CPU% samples."""
    values = [v for t, line in stamped if start <= t <= end
              for v in [parse_frames(line)] if v is not None]
    return {'fps': statistics.mean(values) if values else 0.0, 'lines': len(values),
            'cpu': statistics.mean(cpu) if cpu else None, 'cpu_samples': len(cpu)}


def idle_verdict(rows):
    """(exit code, [notes]) for {config: idle_summary}: 0 pass, 1 fail, 3
    inconclusive (the moving-dust control drew nothing)."""
    notes, failed = [], False
    base = rows.get('norig', {}).get('cpu')
    for config in IDLE_CONFIGS:
        if config not in rows:
            continue
        r = rows[config]
        if config == 'dust':
            continue
        if r['fps'] > IDLE_FPS:
            failed = True
            notes.append('%s: %.2f frames/s (<= %.1f)' % (config, r['fps'], IDLE_FPS))
        if base is not None and r['cpu'] is not None and r['cpu'] - base > CPU_TOL:
            failed = True
            notes.append('%s: CPU %.1f%% vs norig %.1f%% (within %.0f)' % (
                config, r['cpu'], base, CPU_TOL))
    if 'dust' in rows:
        fps = rows['dust']['fps']
        if fps <= 0.0:
            notes.append('dust: 0 frames/s: a locked or sleeping display? INCONCLUSIVE')
            return (1 if failed else 3), notes
        if not DUST_FPS[0] <= fps <= DUST_FPS[1]:
            failed = True
            notes.append('dust: %.1f frames/s (%.0f..%.0f)' % ((fps,) + DUST_FPS))
    return (1 if failed else 0), notes


def idle_table(rows):
    out = ['| Config | frames/s | lines | CPU % | samples |', '| --- | --- | --- | --- | --- |']
    for config in IDLE_CONFIGS:
        if config in rows:
            r = rows[config]
            out.append('| %s | %.2f | %d | %s | %d |' % (
                config, r['fps'], r['lines'], ts._num(r['cpu'], '%.1f'), r['cpu_samples']))
    return '\n'.join(out) + '\n'


def cpu_percent(pids):
    total = None
    for pid in pids:
        try:
            out = subprocess.run(['ps', '-o', '%cpu=', '-p', str(pid)], stdout=subprocess.PIPE,
                                 stderr=subprocess.DEVNULL, universal_newlines=True).stdout
            total = (total or 0.0) + float(out.strip())
        except (OSError, ValueError):
            pass
    return total


def run_idle(render, app, binaries, script, timing, probe, settle, measure):
    for p in (timing, probe):
        if os.path.exists(p):
            os.remove(p)
    render.kill_app(binaries)
    env = []
    for item in ts.launch_env(script, timing, probe):
        env += ['--env', item]
    tail = ts.Tailer(timing)
    cpu = []
    try:
        res = subprocess.run(['open', '-n'] + env + [app])
        if res.returncode != 0:
            return idle_summary([], 0, 0, []), 'open exited %d' % res.returncode
        launched = time.time()
        while time.time() < launched + settle:
            tail.poll()
            time.sleep(0.25)
        start = time.time()
        next_sample = start
        while time.time() < start + measure:
            tail.poll()
            if time.time() >= next_sample:
                c = cpu_percent(render.app_pids(binaries))
                if c is not None:
                    cpu.append(c)
                next_sample += 1.0
            time.sleep(0.1)
        end = time.time()
        tail.poll()
    finally:
        render.kill_app(binaries)
    err = None if cpu else 'no CPU sample (the app was not running)'
    return idle_summary(tail.stamped, start, end, cpu), err


# --- movie ------------------------------------------------------------------------

MOVIE_FRAMES = 4
MOVIE_SIZE = (640, 360)
MOVIE_FPS = 30
MOVIE_STILL_TOL = 2      # frame k against still k: max |d| at most this
MOVIE_DIFFERS_MIN = 50   # consecutive frames: at least this many pixels differ
MOVIE_SPOT = {'name': 'spot', 'orbit': -50.0, 'pitch': 45.0, 'radius': 3.0, 'beam': 30.0,
              'softness': 0.45, 'color': [1.0, 0.8, 0.55], 'intensity': 2.0, 'shadow': True}
MOVIE_AIR = {'haze': 0.3, 'dust': 0.8, 'dust_size': 0.35, 'dust_speed': 1.0,
             'scatter': 0.55, 'seed': 7}


def guard_lines(render):
    """time_shadows' run-2 guard (the lines from its 'Run 1 is at launch'
    comment on), taken from a script it generates: it calls _ts_main() on the
    second AUTOCMD run of a process only."""
    text = ts.script_text(render, ts.Config('1rx1', 's0'), 'x.pdb', 'x.mp4', 'x.json', 2)
    lines = text.rstrip('\n').split('\n')
    for i, line in enumerate(lines):
        if line.startswith('# Run 1 is at launch'):
            return lines[i:]
    raise Refusal('time_shadows.script_text has no run-2 guard')


def movie_scene_lines(render, structure_path, frames):
    """The movie scene (indented for _ts_main): a still camera, a shadowed
    spot, haze and dust, a `frames`-frame movie at MOVIE_FPS."""
    lines = [
        '    cmd.reinitialize()',
        "    cmd.reinitialize('original_settings')",
        '    cmd.load(%r, %r)' % (structure_path, 'm'),
        "    cmd.remove('solvent')",
        "    cmd.hide('everything')",
        "    cmd.show('surface', 'm and polymer')",
        "    cmd.color('grey80', 'm')",
    ]
    for name, value in render.baked_settings(1, 1):
        lines.append('    cmd.set(%r, %r)' % (name, value))
    lines += [
        "    cmd.set('depth_cue', 0)",
        "    cmd.set('metal_light_air_time', -1.0)",
        '    cmd.set_view(%r, animate=0)' % (render.VIEW,),
        "    mn, mx = cmd.get_extent('m')",
        "    cmd.set_lights({'version': 1, 'enabled': True, 'ambient': 0.05, 'classic': 0.0, "
        "'centre': [(a + b) / 2.0 for a, b in zip(mn, mx)], "
        "'size': sum((b - a) ** 2 for a, b in zip(mn, mx)) ** 0.5 / 2.0, "
        "'lights': [%r], 'air': %r})" % (MOVIE_SPOT, MOVIE_AIR),
        "    cmd.mset('1 x%d')" % frames,
        "    cmd.set('movie_fps', %d)" % MOVIE_FPS,
    ]
    return lines


def movie_export_script(render, structure_path, folder, start_file, frames=MOVIE_FRAMES):
    """Export the movie as a PNG sequence into `folder`, ray=1, queued on the
    second AUTOCMD run only (time_shadows' guard)."""
    lines = ['# generated by scripts/lighting/time_air.py (movie export) -- do not edit',
             'import json as _ts_json', 'import time as _ts_time',
             'from pymol import cmd, util', '', 'def _ts_main():']
    lines += movie_scene_lines(render, structure_path, frames)
    lines += [
        '    cmd.frame(1)',
        '    with open(%r, %r) as fh:' % (start_file, 'w'),
        "        _ts_json.dump({'start': _ts_time.time(), 'frames': cmd.count_frames()}, fh)",
        '    cmd.movie_export(%r, %d, %d, quality=%r, format=%r, ray=1)' % (
            folder, MOVIE_SIZE[0], MOVIE_SIZE[1], 'standard', 'png'),
        '',
    ]
    lines += guard_lines(render)
    return '\n'.join(lines) + '\n'


def movie_still_script(render, structure_path, k, frames=MOVIE_FRAMES):
    """Frame k of the same movie with the dust clock pinned to (k - 1) / fps,
    for PYMOL_AUTOEXPORT (idempotent: every AUTOCMD run re-applies it)."""
    lines = ['# generated by scripts/lighting/time_air.py (movie still) -- do not edit',
             'from pymol import cmd, util', 'def _ta_still():']
    lines += movie_scene_lines(render, structure_path, frames)
    lines += [
        "    cmd.set('metal_light_air_time', %r)" % ((k - 1) / float(MOVIE_FPS)),
        '    cmd.frame(%d)' % k,
        '_ta_still()',
    ]
    return '\n'.join(lines) + '\n'


def movie_compare(export_a, export_b, stills, frames=MOVIE_FRAMES):
    """Checks on decoded images (lists of HxWx3 int arrays, frame order):
    [(name, ok, detail)]."""
    import numpy as np

    def maxdiff(a, b):
        return int(np.abs(np.asarray(a, dtype=np.int32) - np.asarray(b, dtype=np.int32)).max())

    def ndiff(a, b):
        d = np.abs(np.asarray(a, dtype=np.int32) - np.asarray(b, dtype=np.int32)).max(axis=2)
        return int((d > 0).sum())

    out = []
    counts = (len(export_a), len(export_b), len(stills))
    if counts != (frames,) * 3:
        return [('frames', False, 'exports %d and %d frames, %d stills (expected %d each)' % (
            counts + (frames,)))]
    same = [maxdiff(a, b) for a, b in zip(export_a, export_b)]
    out.append(('repeatable', all(d == 0 for d in same),
                'export A vs B max |d| per frame %s (all 0)' % same))
    moved = [ndiff(a, b) for a, b in zip(export_a, export_a[1:])]
    out.append(('moves', all(n >= MOVIE_DIFFERS_MIN for n in moved),
                'consecutive frames differ on %s px (each >= %d)' % (moved, MOVIE_DIFFERS_MIN)))
    for k, frame in enumerate(export_a, 1):
        d = [maxdiff(frame, s) for s in stills]
        nearest = min(range(len(d)), key=lambda i: (d[i], i)) + 1
        out.append(('still_%d' % k, nearest == k and d[k - 1] <= MOVIE_STILL_TOL,
                    'frame %d vs stills 1..%d max |d| %s: nearest %d, %d (<= %d)' % (
                        k, len(d), d, nearest, d[k - 1], MOVIE_STILL_TOL)))
    return out


def _pngs(folder):
    if not os.path.isdir(folder):
        return []
    return sorted(os.path.join(folder, n) for n in os.listdir(folder)
                  if n.lower().endswith('.png'))


def run_movie_export(render, app, binaries, script, folder, timing, probe, frames, timeout):
    """One launch exporting the PNG sequence; returns an error or None."""
    for p in (timing, probe):
        if os.path.exists(p):
            os.remove(p)
    render.kill_app(binaries)
    env = []
    for item in ts.launch_env(script, timing, probe):
        env += ['--env', item]
    try:
        res = subprocess.run(['open', '-n'] + env + [app])
        if res.returncode != 0:
            return 'open exited %d' % res.returncode
        deadline = time.time() + timeout
        last, stable = None, None
        while time.time() < deadline:
            names = _pngs(folder)
            if len(names) >= frames:
                if names == last:
                    if stable is None:
                        stable = time.time()
                    elif time.time() - stable >= 3.0:
                        return None
                else:
                    stable = None
                last = names
            time.sleep(0.5)
        return 'timeout after %ds (%d of %d frames in %s)' % (
            timeout, len(_pngs(folder)), frames, folder)
    finally:
        render.kill_app(binaries)


# --- main ----------------------------------------------------------------------

def _app(render, args):
    if args.dry_run:
        return None, None
    if not args.app:
        raise Refusal('--app is required (or --dry-run)')
    app = os.path.abspath(args.app).rstrip('/')
    render.check_path('--app', app)
    _, exe = render.check_app(app)
    binary = os.path.join(app, 'Contents', 'MacOS', exe)
    return app, {binary, os.path.realpath(binary)}


def _app_sha(app):
    if app and os.path.isfile(app + '.sha'):
        with open(app + '.sha') as fh:
            return fh.read().strip()
    return None


def _select(todo, only, key):
    if not only:
        return todo
    wanted = [t for t in only.split(',') if t]
    known = [key(c) for c in todo]
    unknown = [t for t in wanted if t not in known]
    if unknown:
        raise Refusal('unknown configs %s (known: %s)' % (', '.join(unknown), ', '.join(known)))
    return [c for c in todo if key(c) in wanted]


def main_export(render, args, out, pdb_dir):
    if args.runs < 1 or args.frames < 2 or args.start_timeout < 1:
        raise Refusal('--runs must be >= 1, --frames >= 2 and --start-timeout >= 1')
    todo = _select(configs(), args.only, lambda c: c.tag)
    app, binaries = _app(render, args)
    work = os.path.join(out, '_work')
    os.makedirs(work, exist_ok=True)
    paths = {}
    for tag in sorted({c.structure for c in todo} | {'1rx1'}):
        used, path = ts.structure_path(tag, pdb_dir, download=not args.dry_run)
        render.check_path('structure', path)
        paths[tag] = (used, path)
        print('%s: %s%s' % (used, path, '' if os.path.isfile(path) else ' (not downloaded)'),
              flush=True)
    plan = []
    for config in todo:
        for run in range(1, args.runs + 1):
            stem = os.path.join(work, '%s_r%d' % (config.tag, run))
            files = {'script': stem + '.py', 'timing': stem + '.timing',
                     'mp4': os.path.join(out, '%s_r%d.mp4' % (config.tag, run)),
                     'start': stem + '.start.json', 'probe': stem + '.probe.png'}
            for label, p in files.items():
                render.check_path(label, p)
            with open(files['script'], 'w') as fh:
                fh.write(script_text(render, config, paths[config.structure][1],
                                     files['mp4'], files['start'], args.frames))
            plan.append((config, run, files))
    for config, run, files in plan:
        print('%-18s run %d  AUTOCMD=%s' % (config.tag, run, ts.autocmd(files['script'])),
              flush=True)
    if args.dry_run:
        print('dry run: %d runs of %d configs, scripts in %s' % (len(plan), len(todo), work))
        return 0
    if not args.no_warmup:
        stem = os.path.join(work, '_warm')
        with open(stem + '.py', 'w') as fh:
            fh.write(ts.script_text(render, ts.Config('1rx1', 'norig'), paths['1rx1'][1],
                                    stem + '.mp4', stem + '.start.json', 2))
        _, err = ts.run_once(render, app, binaries, stem + '.py', stem + '.timing',
                             stem + '.mp4', stem + '.start.json', 2, args.timeout,
                             stem + '.probe.png', args.start_timeout)
        print('[warm] %s (numbers discarded)' % (err or 'ok'), flush=True)
    started = datetime.datetime.now().isoformat(timespec='seconds')
    results, failed = {}, []
    for n, (config, run, files) in enumerate(plan, 1):
        summary, err = ts.run_once(render, app, binaries, files['script'], files['timing'],
                                   files['mp4'], files['start'], args.frames, args.timeout,
                                   files['probe'], args.start_timeout)
        summary['error'] = err
        entry = results.setdefault(config.tag, {'config': config, 'runs': []})
        entry['runs'].append(summary)
        entry['atoms'] = summary.get('atoms') or entry.get('atoms')
        print('[%d/%d] %s run %d: %s' % (n, len(plan), config.tag, run, err or (
            's/frame %s, gpu_ms median %s' % (ts._num(summary['s_per_frame'], '%.3f'),
                                             ts._num(summary['gpu_ms_median'], '%.1f')))),
              flush=True)
        if err:
            failed.append('%s_r%d' % (config.tag, run))
    summary = summarise(results)
    order = [c.tag for c in todo if c.tag in summary]
    text = table(summary, order)
    notes = flags(summary)
    with open(os.path.join(out, 'results.json'), 'w') as fh:
        json.dump({'app': app, 'app_sha': _app_sha(app), 'mode': 'export', 'started': started,
                   'ended': datetime.datetime.now().isoformat(timespec='seconds'),
                   'frames': args.frames, 'size': list(ts.SIZE),
                   'lines_per_frame': LINES_PER_FRAME, 'air': AIR,
                   'structures': paths, 'summary': summary, 'flags': notes,
                   'failed': failed, 'runs': {t: e['runs'] for t, e in results.items()}},
                  fh, indent=2)
    with open(os.path.join(out, 'table.md'), 'w') as fh:
        fh.write(text + ''.join('\n' + n for n in notes) + ('\n' if notes else ''))
    print(text, flush=True)
    for n in notes:
        print(n, flush=True)
    if failed:
        print('%d runs failed: %s' % (len(failed), ', '.join(failed)), flush=True)
        return 1
    return 0


def main_idle(render, args, out, pdb_dir):
    if args.settle < 0 or args.measure < 1:
        raise Refusal('--settle must be >= 0 and --measure >= 1')
    todo = _select(list(IDLE_CONFIGS), args.only, lambda c: c)
    app, binaries = _app(render, args)
    work = os.path.join(out, '_work')
    os.makedirs(work, exist_ok=True)
    _, pdb = ts.structure_path('1rx1', pdb_dir, download=False)
    plan = []
    for config in todo:
        stem = os.path.join(work, 'idle_%s' % config)
        files = {'script': stem + '.py', 'timing': stem + '.timing', 'probe': stem + '.probe.png'}
        for label, p in files.items():
            render.check_path(label, p)
        with open(files['script'], 'w') as fh:
            fh.write(idle_script_text(render, config, pdb))
        plan.append((config, files))
        print('%-12s AUTOCMD=%s' % (config, ts.autocmd(files['script'])), flush=True)
    if args.dry_run:
        print('dry run: %d idle launches, scripts in %s' % (len(plan), work))
        return 0
    rows, errors = {}, []
    for config, files in plan:
        row, err = run_idle(render, app, binaries, files['script'], files['timing'],
                            files['probe'], args.settle, args.measure)
        rows[config] = row
        print('%s: %.2f frames/s (%d lines), CPU %s%s' % (
            config, row['fps'], row['lines'], ts._num(row['cpu'], '%.1f%%'),
            ' ERROR ' + err if err else ''), flush=True)
        if err:
            errors.append('%s: %s' % (config, err))
    rc, notes = idle_verdict(rows)
    if errors:
        rc = 1
    text = idle_table(rows)
    with open(os.path.join(out, 'idle.json'), 'w') as fh:
        json.dump({'app': app, 'app_sha': _app_sha(app), 'mode': 'idle', 'settle': args.settle,
                   'measure': args.measure, 'rows': rows, 'notes': notes, 'errors': errors,
                   'rc': rc}, fh, indent=2)
    with open(os.path.join(out, 'idle.md'), 'w') as fh:
        fh.write(text)
    print(text + ''.join(n + '\n' for n in notes + errors), flush=True)
    print({0: 'idle: PASS', 1: 'idle: FAIL', 3: 'idle: INCONCLUSIVE'}[rc], flush=True)
    return rc


def main_movie(render, args, out, pdb_dir):
    frames = args.frames if args.frames_given else MOVIE_FRAMES
    if frames < 2:
        raise Refusal('--frames must be >= 2')
    app, binaries = _app(render, args)
    work = os.path.join(out, '_work')
    os.makedirs(work, exist_ok=True)
    _, pdb = ts.structure_path('1rx1', pdb_dir, download=False)
    runs = []
    for name in ('a', 'b'):
        folder = os.path.join(out, 'export_%s' % name)
        stem = os.path.join(work, 'movie_%s' % name)
        files = {'script': stem + '.py', 'folder': folder, 'timing': stem + '.timing',
                 'probe': stem + '.probe.png', 'start': stem + '.start.json'}
        for label, p in files.items():
            render.check_path(label, p)
        if _pngs(folder):
            raise Refusal('%s is not empty (a PNG sequence needs a new folder)' % folder)
        with open(files['script'], 'w') as fh:
            fh.write(movie_export_script(render, pdb, folder, files['start'], frames))
        runs.append(files)
    stills = []
    for k in range(1, frames + 1):
        script = os.path.join(work, 'still_%d.py' % k)
        png = os.path.join(out, 'still_%d.png' % k)
        render.check_path('script', script)
        render.check_path('still', png)
        with open(script, 'w') as fh:
            fh.write(movie_still_script(render, pdb, k, frames))
        stills.append((script, png))
    for files in runs:
        print('export -> %s  AUTOCMD=%s' % (files['folder'], ts.autocmd(files['script'])),
              flush=True)
    for script, png in stills:
        print('still  -> %s  AUTOCMD=run %s' % (png, script), flush=True)
    if args.dry_run:
        print('dry run: %d launches, scripts in %s' % (len(runs) + len(stills), work))
        return 0
    errors = []
    for files in runs:
        err = run_movie_export(render, app, binaries, files['script'], files['folder'],
                               files['timing'], files['probe'], frames, args.timeout)
        print('export %s: %s' % (files['folder'], err or 'ok'), flush=True)
        if err:
            errors.append(err)
    for script, png in stills:
        err = render.launch(app, binaries, script, png, MOVIE_SIZE, 1, args.timeout)
        print('still %s: %s' % (png, err or 'ok'), flush=True)
        if err:
            errors.append(err)
    load = _load('lighting_check_shadows', 'check_shadows.py').load
    a = [load(p) for p in _pngs(runs[0]['folder'])]
    b = [load(p) for p in _pngs(runs[1]['folder'])]
    s = [load(png) for _, png in stills if os.path.isfile(png)]
    results = movie_compare(a, b, s, frames)
    lines = ['| Movie check | Result | Measured |', '| --- | --- | --- |']
    lines += ['| %s | %s | %s |' % (n, 'PASS' if ok else 'FAIL', d) for n, ok, d in results]
    text = '\n'.join(lines) + '\n'
    with open(os.path.join(out, 'movie.md'), 'w') as fh:
        fh.write(text)
    with open(os.path.join(out, 'movie.json'), 'w') as fh:
        json.dump({'app': app, 'app_sha': _app_sha(app), 'mode': 'movie', 'frames': frames,
                   'size': list(MOVIE_SIZE), 'fps': MOVIE_FPS, 'errors': errors,
                   'results': [{'check': n, 'ok': ok, 'detail': d} for n, ok, d in results]},
                  fh, indent=2)
    print(text, flush=True)
    return 0 if not errors and all(ok for _, ok, _ in results) else 1


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--mode', choices=MODES, default='export')
    ap.add_argument('--app', help='the staged dev app (its own bundle id)')
    ap.add_argument('--out', required=True)
    ap.add_argument('--pdb-dir', help='structure cache (default OUT/pdb)')
    ap.add_argument('--runs', type=int, default=ts.RUNS)
    ap.add_argument('--frames', type=int, default=None)
    ap.add_argument('--only', help='comma-separated config tags')
    ap.add_argument('--no-warmup', action='store_true')
    ap.add_argument('--timeout', type=int, default=3600, help='seconds per launch')
    ap.add_argument('--start-timeout', type=int, default=ts.START_TIMEOUT)
    ap.add_argument('--settle', type=float, default=SETTLE, help='idle: seconds before measuring')
    ap.add_argument('--measure', type=float, default=MEASURE, help='idle: seconds measured')
    ap.add_argument('--dry-run', action='store_true',
                    help='write the scripts and print the plan; launch nothing')
    args = ap.parse_args(argv)
    args.frames_given = args.frames is not None
    if args.frames is None:
        args.frames = ts.FRAMES
    try:
        render = ts.load_render()
        out = os.path.abspath(args.out)
        pdb_dir = os.path.abspath(args.pdb_dir or os.path.join(out, 'pdb'))
        render.check_path('--out', out)
        render.check_path('--pdb-dir', pdb_dir)
        os.makedirs(out, exist_ok=True)
        return {'export': main_export, 'idle': main_idle,
                'movie': main_movie}[args.mode](render, args, out, pdb_dir)
    except Refusal as e:
        print('time_air.py: %s' % e, file=sys.stderr)
        return 2
    except Exception as e:     # render.Refusal and friends
        if type(e).__name__ == 'Refusal':
            print('time_air.py: %s' % e, file=sys.stderr)
            return 2
        raise


if __name__ == '__main__':
    sys.exit(main())
