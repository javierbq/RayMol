#!/usr/bin/env python3
"""L6 timing harness for HDR colour under a light rig (#624, lighting epic #610).

    time_hdr.py --mode export --app APP --out DIR [--pdb-dir DIR] [--runs 3]
                [--frames 48] [--only tag,tag] [--no-warmup] [--timeout S]
                [--start-timeout S] [--dry-run]
    time_hdr.py --mode toggle --app APP --out DIR [--frames 24] [--at K]
                [--runs 1] [--only tag,tag] [--timeout S] [--start-timeout S]
                [--dry-run]

THE ORCHESTRATOR RUNS THE TIMINGS (both build slots held, nothing else
running); the implementer proves the harness with --dry-run and a 2-frame
smoke of each mode (`--frames 2 --runs 1 --only <one 1rx1 config>`), numbers
discarded. CI never asserts timings: testing/tests/raymol/lighting_hdr_check.py
tests the pure parts (the configuration matrices, the generated scripts and
AUTOCMD text, the per-frame parsing, the summaries and tables, --dry-run).

This is #616's scripts/lighting/time_shadows.py and #618's time_air.py,
imported and never edited: time_shadows' run-2 export guard and AUTOEXPORT
probe (an export queued at launch races the first live frame, #654),
launch_env and check_autocmd (AUTOCMD refusals), run_once and Tailer (stamped
`offscreen WxH gpu_ms=` lines, LINES_PER_FRAME = 2 per ray=1 frame),
structure_path (the PDB cache), summarise and table; time_air's air (AIR, its
lines and #618's settings).

--mode export (L6): a 48-frame 1920x1080 movie export with metal_raytrace 1
and metal_shadows 1 (cmd.movie_export(..., quality='standard', ray=1)) of
1rx1, 1ao6 and 7k00 (1aon fallback), each as
    s3            time_shadows' 3-light rig, all three shadowed, at the default
                  (metal_light_hdr 0: HDR on)
    s3_knee       the same at metal_light_hdr 2 (the 8-bit soft knee)
    s3_air        s3 plus time_air's air (haze 0.3, dust 0.5, dust_speed 1;
                  metal_light_air_resolution 1, metal_light_air_shadow_filter 1)
    s3_air_knee   s3_air at metal_light_hdr 2
Per configuration: s/frame over frames 2..N, the median gpu_ms, and the delta
of each HDR configuration against its knee twin. Writes DIR/results.json and
DIR/table.md. HDR is ALU-only: expected under HDR_EXPECT (+2%); a row over
HDR_FLAG (+5%) is flagged for the orchestrator.

--mode toggle (report only): the per-frame wall time of the same movie export
(1920x1080, ray=1) whose rig or switch changes at frame K (--at, default the
middle frame), on 1rx1:
    on_hdr        the rig installed off; `lights on` at frame K (HDR variants)
    on_knee       the same at metal_light_hdr 2 (knee variants)
    flip          the rig on at HDR; `set metal_light_hdr, 2` at frame K and
                  `set metal_light_hdr, 1` at frame K + FLIP_BACK (when inside
                  the movie: the second change must reuse cached pipelines)
    steady        the rig on at HDR throughout (the control)
The frame commands are appended (cmd.mappend) after util.mroll's own. The
spike is frame K's wall time over the median of the other frames (frame 1
excluded: it pays the export's set-up). A setting the build does not have is
never set (the frame command and the knee line check first), so a build before
#624 runs every configuration as the knee.

--dry-run writes the scripts and prints the plan; nothing is downloaded or
launched. Exit codes: 0 ok; 1 a run failed; 2 a refusal or usage error.
"""
import argparse
import contextlib
import datetime
import importlib.util
import json
import os
import statistics
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def _load(name, filename):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ta = _load('lighting_time_air', 'time_air.py')
ts = ta.ts                      # one time_shadows instance, time_air's
Refusal = ts.Refusal
LINES_PER_FRAME = ts.LINES_PER_FRAME
PROBE = ts.PROBE

MODES = ('export', 'toggle')

# --- export (L6) ---------------------------------------------------------------

# variant -> (knee, air)
VARIANTS = {
    's3': (False, False),
    's3_knee': (True, False),
    's3_air': (False, True),
    's3_air_knee': (True, True),
}
PAIRS = (('s3', 's3_knee'), ('s3_air', 's3_air_knee'))
HDR_EXPECT = 0.02        # HDR is ALU-only: expected under this over the knee
HDR_FLAG = 0.05          # a row over this is flagged for the orchestrator
SET_LIGHTS = ta.SET_LIGHTS
KNEE_LINE = ("    if 'metal_light_hdr' in cmd.setting.get_name_list(): "
             "cmd.set('metal_light_hdr', 2)")


class HdrConfig(object):
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
        return 'HdrConfig(%r, %r)' % (self.structure, self.variant)


def configs():
    """Every structure x (s3, s3_knee, s3_air, s3_air_knee)."""
    return [HdrConfig(s, v) for s, _, _ in ts.STRUCTURES for v in VARIANTS]


def variant_lines(variant):
    """The lines a variant adds just before its rig is installed."""
    knee, air = VARIANTS[variant]
    lines = ta.air_lines('s3_air') if air else []
    if knee:
        lines.append(KNEE_LINE)
    return lines


def _retitle(text, what):
    return text.replace('# generated by scripts/lighting/time_shadows.py -- do not edit',
                        '# generated by scripts/lighting/time_hdr.py (time_shadows.py %s) '
                        '-- do not edit' % what)


def script_text(render, config, structure_path, mp4, start_file, frames=ts.FRAMES):
    """time_shadows' s3 script (its run-2 export guard, probe-deferred export
    and start stamp, unchanged) with the variant's air and switch added just
    before the rig is installed."""
    base = ts.script_text(render, ts.Config(config.structure, 's3'), structure_path, mp4,
                          start_file, frames)
    if base.count(SET_LIGHTS) != 1:
        raise Refusal('time_shadows.script_text changed: %r not found once' % SET_LIGHTS)
    add = variant_lines(config.variant)
    text = base.replace(SET_LIGHTS, ''.join(l + '\n' for l in add) + SET_LIGHTS)
    stamp = "'tag': %r" % ts.Config(config.structure, 's3').tag
    if text.count(stamp) != 1:
        raise Refusal('time_shadows.script_text changed: %r not found once' % stamp)
    text = text.replace(stamp, "'tag': %r" % config.tag)
    return _retitle(text, 'plus the HDR switch')


def summarise(results):
    """time_shadows.summarise plus 'delta_vs_knee' of each HDR row against its
    knee twin (None on the knee rows)."""
    out = ts.summarise(results)
    twins = dict(PAIRS)
    for row in out.values():
        knee = twins.get(row['rig'])
        base = out.get('%s_%s' % (row['structure'], knee)) if knee else None
        if base and base['s_per_frame'] and row['s_per_frame'] is not None:
            row['delta_vs_knee'] = row['s_per_frame'] / base['s_per_frame'] - 1.0
        else:
            row['delta_vs_knee'] = None
    return out


def table(summary, order=None):
    """time_shadows.table with the delta against the knee in its last column."""
    rows = {t: dict(r, delta_vs_s0=r.get('delta_vs_knee')) for t, r in summary.items()}
    return ts.table(rows, order).replace('| vs s0 |', '| vs knee |')


def flags(summary):
    """HDR rows over HDR_FLAG s/frame against their knee twin."""
    out = []
    for tag in sorted(summary):
        d = summary[tag].get('delta_vs_knee')
        if d is not None and d > HDR_FLAG:
            out.append('FLAG %s: %+.1f%% s/frame over its knee twin (> %+.0f%%; expected '
                       'under %+.0f%%)' % (tag, 100.0 * d, 100.0 * HDR_FLAG,
                                           100.0 * HDR_EXPECT))
    return out


# --- toggle -------------------------------------------------------------------------

TOGGLES = ('on_hdr', 'on_knee', 'flip', 'steady')
TOGGLE_STRUCTURES = ('1rx1',)
TOGGLE_FRAMES = 24
FLIP_BACK = 6
FRAME_LINE = '    cmd.frame(1)\n'
HDR_SET = "'metal_light_hdr' in cmd.setting.get_name_list()"


class ToggleConfig(object):
    def __init__(self, structure, toggle):
        if toggle not in TOGGLES:
            raise Refusal('unknown toggle %r (known: %s)' % (toggle, ', '.join(TOGGLES)))
        self.structure = structure
        self.toggle = toggle
        self.rig = toggle
        self.size = 0

    @property
    def tag(self):
        return '%s_%s' % (self.structure, self.toggle)

    def __repr__(self):
        return 'ToggleConfig(%r, %r)' % (self.structure, self.toggle)


def toggle_configs():
    return [ToggleConfig(s, t) for s in TOGGLE_STRUCTURES for t in TOGGLES]


def default_at(frames):
    """The frame the change lands on: the middle, never frame 1."""
    return max(2, (frames + 1) // 2)


def toggle_lines(toggle, at, frames):
    """(lines before the rig is installed, lines after cmd.frame(1)): the
    frame commands are appended to util.mroll's own (cmd.mappend)."""
    before, after = [], []
    if toggle in ('on_hdr', 'on_knee'):
        before.append("    rig['enabled'] = False")
        if toggle == 'on_knee':
            before.append(KNEE_LINE)
        after.append("    cmd.mappend(%d, 'lights on')" % at)
    elif toggle == 'flip':
        after.append('    if %s: cmd.mappend(%d, %r)' % (HDR_SET, at, 'set metal_light_hdr, 2'))
        if at + FLIP_BACK <= frames:
            after.append('    if %s: cmd.mappend(%d, %r)' % (
                HDR_SET, at + FLIP_BACK, 'set metal_light_hdr, 1'))
    return before, after


def toggle_script_text(render, config, structure_path, mp4, start_file, frames, at):
    """time_shadows' s3 script with the toggle's lines."""
    if not 2 <= at <= frames:
        raise Refusal('--at must be in 2..frames (%d), not %d' % (frames, at))
    base = ts.script_text(render, ts.Config(config.structure, 's3'), structure_path, mp4,
                          start_file, frames)
    for marker in (SET_LIGHTS, FRAME_LINE):
        if base.count(marker) != 1:
            raise Refusal('time_shadows.script_text changed: %r not found once' % marker)
    before, after = toggle_lines(config.toggle, at, frames)
    text = base.replace(SET_LIGHTS, ''.join(l + '\n' for l in before) + SET_LIGHTS)
    text = text.replace(FRAME_LINE, FRAME_LINE + ''.join(l + '\n' for l in after))
    stamp = "'tag': %r" % ts.Config(config.structure, 's3').tag
    text = text.replace(stamp, "'tag': %r" % config.tag)
    return _retitle(text, 'plus a toggle at frame %d' % at)


def toggle_frames(stamped, frames):
    """[(end stamp, gpu_ms)] per exported frame from a Tailer's [(stamp, line)]:
    time_shadows' offscreen lines, LINES_PER_FRAME per frame."""
    seen = [(t, ms) for t, line in stamped for ms in [ts.parse_gpu_ms(line)]
            if ms is not None]
    return ts.frame_times(seen, frames)


def toggle_summary(done, at, frames):
    """{'wall': [s per frame], 'median', 'at', 'spike', 'back', 'spike_back'}
    from toggle_frames: frame k's wall time is its end stamp minus frame
    k - 1's (frame 1 has none); the median is over frames 2..N except the
    changed ones."""
    wall = [None] + [b[0] - a[0] for a, b in zip(done, done[1:])]
    changed = {at} | ({at + FLIP_BACK} if at + FLIP_BACK <= frames else set())
    others = [w for k, w in enumerate(wall, 1) if k >= 2 and k not in changed and w is not None]
    med = statistics.median(others) if others else None

    def at_frame(k):
        return wall[k - 1] if 1 <= k <= len(wall) else None
    out = {'frames': len(done), 'wall': wall, 'median': med, 'at': at,
           'wall_at': at_frame(at), 'back': at + FLIP_BACK if at + FLIP_BACK <= frames else None}
    out['wall_back'] = at_frame(out['back']) if out['back'] else None
    out['spike'] = (out['wall_at'] / med) if (med and out['wall_at'] is not None) else None
    out['spike_back'] = (out['wall_back'] / med) if (med and out['wall_back'] is not None) else None
    out['gpu_ms'] = [ms for _, ms in done]
    return out


def toggle_table(rows, order=None):
    lines = ['| Config | frames | median s/frame | frame K | s at K | spike | s at K+%d | '
             'spike back |' % FLIP_BACK,
             '| --- | --- | --- | --- | --- | --- | --- | --- |']
    for tag in order or sorted(rows):
        r = rows[tag]
        lines.append('| %s | %d | %s | %d | %s | %s | %s | %s |' % (
            tag, r['frames'], ts._num(r['median'], '%.3f'), r['at'],
            ts._num(r['wall_at'], '%.3f'), ts._num(r['spike'], 'x%.2f'),
            ts._num(r['wall_back'], '%.3f'), ts._num(r['spike_back'], 'x%.2f')))
    return '\n'.join(lines) + '\n'


@contextlib.contextmanager
def recording_tailers():
    """Swap time_shadows' Tailer for one that remembers every instance, so
    run_once's stamped lines can be read after it returns."""
    seen = []
    original = ts.Tailer

    class Recording(original):
        def __init__(self, *args, **kwargs):
            original.__init__(self, *args, **kwargs)
            seen.append(self)
    ts.Tailer = Recording
    try:
        yield seen
    finally:
        ts.Tailer = original


def run_toggle_once(render, app, binaries, files, frames, at, timeout, start_timeout):
    """One toggle export through time_shadows.run_once: (toggle_summary, error
    or None), the per-frame stamps read from run_once's own Tailer."""
    with recording_tailers() as tails:
        _summary, err = ts.run_once(render, app, binaries, files['script'], files['timing'],
                                    files['mp4'], files['start'], frames, timeout,
                                    files['probe'], start_timeout)
    done = toggle_frames(tails[-1].stamped if tails else [], frames)
    if err is None and len(done) < frames:
        err = '%d complete frames, expected %d' % (len(done), frames)
    return toggle_summary(done, at, frames), err


# --- main ------------------------------------------------------------------------

def _app(render, args):
    return ta._app(render, args)


def _plan_files(render, work, out, stem_tag, run):
    stem = os.path.join(work, '%s_r%d' % (stem_tag, run))
    files = {'script': stem + '.py', 'timing': stem + '.timing',
             'mp4': os.path.join(out, '%s_r%d.mp4' % (stem_tag, run)),
             'start': stem + '.start.json', 'probe': stem + '.probe.png'}
    for label, p in files.items():
        render.check_path(label, p)
    return files


def main_export(render, args, out, pdb_dir):
    if args.runs < 1 or args.frames < 2 or args.start_timeout < 1:
        raise Refusal('--runs must be >= 1, --frames >= 2 and --start-timeout >= 1')
    todo = ta._select(configs(), args.only, lambda c: c.tag)
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
            files = _plan_files(render, work, out, config.tag, run)
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
        json.dump({'app': app, 'app_sha': ta._app_sha(app), 'mode': 'export',
                   'started': started,
                   'ended': datetime.datetime.now().isoformat(timespec='seconds'),
                   'frames': args.frames, 'size': list(ts.SIZE),
                   'lines_per_frame': LINES_PER_FRAME, 'air': ta.AIR,
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


def main_toggle(render, args, out, pdb_dir):
    frames = args.frames if args.frames_given else TOGGLE_FRAMES
    at = args.at if args.at is not None else default_at(frames)
    if args.runs < 1 or frames < 2 or args.start_timeout < 1:
        raise Refusal('--runs must be >= 1, --frames >= 2 and --start-timeout >= 1')
    if not 2 <= at <= frames:
        raise Refusal('--at must be in 2..%d, not %d' % (frames, at))
    todo = ta._select(toggle_configs(), args.only, lambda c: c.tag)
    app, binaries = _app(render, args)
    work = os.path.join(out, '_work')
    os.makedirs(work, exist_ok=True)
    paths = {}
    for tag in sorted({c.structure for c in todo}):
        used, path = ts.structure_path(tag, pdb_dir, download=not args.dry_run)
        render.check_path('structure', path)
        paths[tag] = (used, path)
    plan = []
    for config in todo:
        for run in range(1, args.runs + 1):
            files = _plan_files(render, work, out, config.tag, run)
            with open(files['script'], 'w') as fh:
                fh.write(toggle_script_text(render, config, paths[config.structure][1],
                                            files['mp4'], files['start'], frames, at))
            plan.append((config, run, files))
            print('%-14s run %d  frame %d  AUTOCMD=%s' % (config.tag, run, at,
                                                         ts.autocmd(files['script'])),
                  flush=True)
    if args.dry_run:
        print('dry run: %d toggle runs, %d frames, the change at frame %d, scripts in %s' % (
            len(plan), frames, at, work))
        return 0
    rows, errors, runs = {}, [], {}
    for config, run, files in plan:
        row, err = run_toggle_once(render, app, binaries, files, frames, at, args.timeout,
                                   args.start_timeout)
        row['error'] = err
        runs.setdefault(config.tag, []).append(row)
        rows[config.tag] = row          # the last run's row goes in the table
        print('%s run %d: %s' % (config.tag, run, err or 'spike %s (median %s s/frame)' % (
            ts._num(row['spike'], 'x%.2f'), ts._num(row['median'], '%.3f'))), flush=True)
        if err:
            errors.append('%s_r%d: %s' % (config.tag, run, err))
    order = [c.tag for c in todo if c.tag in rows]
    text = toggle_table(rows, order)
    with open(os.path.join(out, 'toggle.json'), 'w') as fh:
        json.dump({'app': app, 'app_sha': ta._app_sha(app), 'mode': 'toggle', 'frames': frames,
                   'at': at, 'flip_back': FLIP_BACK, 'size': list(ts.SIZE),
                   'lines_per_frame': LINES_PER_FRAME, 'runs': runs, 'errors': errors},
                  fh, indent=2)
    with open(os.path.join(out, 'toggle.md'), 'w') as fh:
        fh.write(text)
    print(text + ''.join(e + '\n' for e in errors), flush=True)
    return 1 if errors else 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--mode', choices=MODES, default='export')
    ap.add_argument('--app', help='the staged dev app (its own bundle id)')
    ap.add_argument('--out', required=True)
    ap.add_argument('--pdb-dir', help='structure cache (default OUT/pdb)')
    ap.add_argument('--runs', type=int, default=None)
    ap.add_argument('--frames', type=int, default=None)
    ap.add_argument('--at', type=int, default=None, help='toggle: the frame the change lands on')
    ap.add_argument('--only', help='comma-separated config tags')
    ap.add_argument('--no-warmup', action='store_true')
    ap.add_argument('--timeout', type=int, default=3600, help='seconds per launch')
    ap.add_argument('--start-timeout', type=int, default=ts.START_TIMEOUT)
    ap.add_argument('--dry-run', action='store_true',
                    help='write the scripts and print the plan; launch nothing')
    args = ap.parse_args(argv)
    args.frames_given = args.frames is not None
    if args.frames is None:
        args.frames = ts.FRAMES
    if args.runs is None:
        args.runs = ts.RUNS if args.mode == 'export' else 1
    try:
        render = ts.load_render()
        out = os.path.abspath(args.out)
        pdb_dir = os.path.abspath(args.pdb_dir or os.path.join(out, 'pdb'))
        render.check_path('--out', out)
        render.check_path('--pdb-dir', pdb_dir)
        os.makedirs(out, exist_ok=True)
        return {'export': main_export, 'toggle': main_toggle}[args.mode](
            render, args, out, pdb_dir)
    except Refusal as e:
        print('time_hdr.py: %s' % e, file=sys.stderr)
        return 2
    except Exception as e:     # render.Refusal and friends
        if type(e).__name__ == 'Refusal':
            print('time_hdr.py: %s' % e, file=sys.stderr)
            return 2
        raise


if __name__ == '__main__':
    sys.exit(main())
