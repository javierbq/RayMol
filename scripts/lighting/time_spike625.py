#!/usr/bin/env python3
"""SPIKE #625 (scratch, never merged): L6-style timings of the soft-shadow options.

    time_spike625.py --app APP --out DIR --pdb-dir DIR [--runs 3] [--frames 48]
                     [--only tag,tag] [--no-warmup] [--dry-run]

#616's scripts/lighting/time_shadows.py, imported and never edited: its run-2
export guard and AUTOEXPORT probe (#654), Tailer, structure cache, rig and
summaries. A 48-frame 1920x1080 movie export of 1rx1, 1ao6 and 7k00 with the
3-light rig, per configuration:

    norig      no rig
    s0         the rig, no light shadowed (metal_shadows 1: the classic traced
               key-light ray is on, as on master)
    s3         3 shadowed lights, #616's maps and 3x3 PCF (master)
    s3pcss     s3 with the spike's PCSS kernel (RAYMOL_SPIKE625_PCSS=F,16,32)
    rtK        no maps; per-light traced soft shadows in the RT pass, K rays per
               light per pixel, light radius F x aim distance
               (RAYMOL_SPIKE625_RT=K,F,3); rt1 is F=0 (hard traced, per light)

and with metal_raytrace 0 (raster only, 1 offscreen line per frame):
    s0_r0, s3_r0, s3pcss_r0
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

HERE = os.path.dirname(os.path.abspath(__file__))


def _load(name, filename):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ts = _load('lighting_time_shadows', 'time_shadows.py')
F = 0.1

# label -> (shadowed lights, rt, env)
CONFIGS = [
    ('norig', None, 1, []),
    ('s0', 0, 1, []),
    ('s3', 3, 1, []),
    ('s3pcss', 3, 1, ['RAYMOL_SPIKE625_PCSS=%g,16,32' % F]),
    ('rt1', 0, 1, ['RAYMOL_SPIKE625_RT=1,0,3']),
    ('rt4', 0, 1, ['RAYMOL_SPIKE625_RT=4,%g,3' % F]),
    ('rt16', 0, 1, ['RAYMOL_SPIKE625_RT=16,%g,3' % F]),
    ('s0_r0', 0, 0, []),
    ('s3_r0', 3, 0, []),
    ('s3pcss_r0', 3, 0, ['RAYMOL_SPIKE625_PCSS=%g,16,32' % F]),
]


class Cfg(object):
    def __init__(self, structure, label, shadowed, rt, env):
        self.structure, self.label, self.shadowed, self.rt, self.env = \
            structure, label, shadowed, rt, env
        self.size = 0
        self.rig = 'norig' if shadowed is None else 's%d' % shadowed

    @property
    def tag(self):
        return '%s_%s' % (self.structure, self.label)


def all_configs():
    return [Cfg(s, *c) for s, _, _ in ts.STRUCTURES for c in CONFIGS]


def script(render, cfg, path, mp4, start, frames):
    text = ts.script_text(render, cfg, path, mp4, start, frames)
    if cfg.rt == 0:
        a, b = "cmd.set('metal_raytrace', 1)", "cmd.set('metal_raytrace', 0)"
        assert text.count(a) == 1
        text = text.replace(a, b)
        a = ", quality='standard', ray=1)"
        assert text.count(a) == 1
        text = text.replace(a, ", quality='standard', ray=0)")
    return text


def run_once(render, app, binaries, cfg, files, frames, timeout, start_timeout):
    per = 2 if cfg.rt else 1
    for p in (files['timing'], files['mp4'], files['start'], files['probe']):
        if os.path.exists(p):
            os.remove(p)
    render.kill_app(binaries)
    env = []
    for item in ts.launch_env(files['script'], files['timing'], files['probe']) + cfg.env:
        env += ['--env', item]
    tail = ts.Tailer(files['timing'])
    err = None
    need = frames * per
    try:
        res = subprocess.run(['open', '-n'] + env + [app])
        if res.returncode != 0:
            return ts.summarise_run([], frames, per=per), 'open exited %d' % res.returncode
        launched = time.time()
        deadline = launched + timeout
        last_size, stable_since = -1, None
        while time.time() < deadline:
            tail.poll()
            if not tail.frames() and time.time() - launched > start_timeout:
                err = 'no export line %ds after launch' % start_timeout
                break
            if len(tail.frames()) >= need and os.path.isfile(files['mp4']):
                size = os.path.getsize(files['mp4'])
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
            err = 'timeout after %ds (%d lines)' % (timeout, len(tail.frames()))
    finally:
        render.kill_app(binaries)
    start = None
    try:
        with open(files['start']) as fh:
            start = json.load(fh)
    except (OSError, ValueError):
        err = err or 'no start stamp'
    mp4_end = os.path.getmtime(files['mp4']) if os.path.isfile(files['mp4']) else None
    out = ts.summarise_run(tail.frames(), frames, start and start.get('start'), mp4_end, per=per)
    out['atoms'] = start and start.get('atoms')
    if not err and not out['complete']:
        err = '%d offscreen lines, expected %d' % (out['lines'], need)
    return out, err


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--app')
    ap.add_argument('--out', required=True)
    ap.add_argument('--pdb-dir', required=True)
    ap.add_argument('--runs', type=int, default=3)
    ap.add_argument('--frames', type=int, default=48)
    ap.add_argument('--only')
    ap.add_argument('--no-warmup', action='store_true')
    ap.add_argument('--timeout', type=int, default=3600)
    ap.add_argument('--start-timeout', type=int, default=300)
    ap.add_argument('--dry-run', action='store_true')
    args = ap.parse_args(argv)
    render = ts.load_render()
    out = os.path.abspath(args.out)
    pdb_dir = os.path.abspath(args.pdb_dir)
    render.check_path('--out', out)
    todo = all_configs()
    if args.only:
        wanted = args.only.split(',')
        todo = [c for c in todo if c.tag in wanted or c.label in wanted or c.structure in wanted]
    paths = {}
    for tag, _, _ in ts.STRUCTURES:
        used, path = ts.structure_path(tag, pdb_dir, download=False)
        paths[tag] = path
        print('%s: %s (%s)' % (tag, path, 'ok' if os.path.isfile(path) else 'MISSING'), flush=True)
    work = os.path.join(out, '_work')
    os.makedirs(work, exist_ok=True)
    plan = []
    for cfg in todo:
        for run in range(1, args.runs + 1):
            stem = os.path.join(work, '%s_r%d' % (cfg.tag, run))
            files = {'script': stem + '.py', 'timing': stem + '.timing',
                     'mp4': os.path.join(out, '%s_r%d.mp4' % (cfg.tag, run)),
                     'start': stem + '.start.json', 'probe': stem + '.probe.png'}
            for k in files:
                render.check_path(k, files[k])
            with open(files['script'], 'w') as fh:
                fh.write(script(render, cfg, paths[cfg.structure], files['mp4'],
                                files['start'], args.frames))
            plan.append((cfg, run, files))
    for cfg, run, files in plan:
        print('%-18s run %d env=%s rt=%d' % (cfg.tag, run, cfg.env, cfg.rt), flush=True)
    if args.dry_run:
        return 0
    app = os.path.abspath(args.app).rstrip('/')
    _, exe = render.check_app(app)
    binary = os.path.join(app, 'Contents', 'MacOS', exe)
    binaries = {binary, os.path.realpath(binary)}
    if not args.no_warmup:
        warm = Cfg('1rx1', 'warm', None, 1, [])
        stem = os.path.join(work, '_warm')
        files = {'script': stem + '.py', 'timing': stem + '.timing', 'mp4': stem + '.mp4',
                 'start': stem + '.start.json', 'probe': stem + '.probe.png'}
        with open(files['script'], 'w') as fh:
            fh.write(script(render, warm, paths['1rx1'], files['mp4'], files['start'], 2))
        _, err = run_once(render, app, binaries, warm, files, 2, args.timeout, args.start_timeout)
        print('[warm] %s' % (err or 'ok'), flush=True)
    started = datetime.datetime.now().isoformat(timespec='seconds')
    results, failed = {}, []
    for n, (cfg, run, files) in enumerate(plan, 1):
        summ, err = run_once(render, app, binaries, cfg, files, args.frames, args.timeout,
                             args.start_timeout)
        summ['error'] = err
        e = results.setdefault(cfg.tag, {'cfg': cfg, 'runs': []})
        e['runs'].append(summ)
        e['atoms'] = summ.get('atoms') or e.get('atoms')
        print('[%d/%d] %s run %d: %s' % (n, len(plan), cfg.tag, run, err or
              's/frame %s gpu_ms %s' % (ts._num(summ['s_per_frame'], '%.4f'),
                                        ts._num(summ['gpu_ms_median'], '%.1f'))), flush=True)
        if err:
            failed.append('%s_r%d' % (cfg.tag, run))
    summary = {}
    for tag, e in results.items():
        med = lambda k: ts._median([r[k] for r in e['runs']])
        summary[tag] = {'structure': e['cfg'].structure, 'label': e['cfg'].label,
                        'rt': e['cfg'].rt, 'env': e['cfg'].env, 'atoms': e.get('atoms'),
                        'runs': len(e['runs']), 's_per_frame': med('s_per_frame'),
                        's_per_frame_mp4': med('s_per_frame_mp4'),
                        'gpu_ms_median': med('gpu_ms_median')}
    rows = ['| Structure | Atoms | Config | RT | s/frame | GPU ms/frame (median) | vs s0 (s/frame) | vs s0 (GPU ms) |',
            '| --- | --- | --- | --- | --- | --- | --- | --- |']
    for cfg in todo:
        if cfg.tag not in summary:
            continue
        r = summary[cfg.tag]
        base = summary.get('%s_%s' % (cfg.structure, 's0' if cfg.rt else 's0_r0'))
        d1 = d2 = None
        if base and r['s_per_frame'] and base['s_per_frame']:
            d1 = 100.0 * (r['s_per_frame'] / base['s_per_frame'] - 1.0)
        if base and r['gpu_ms_median'] and base['gpu_ms_median']:
            d2 = r['gpu_ms_median'] - base['gpu_ms_median']
        rows.append('| %s | %s | %s | %d | %s | %s | %s | %s |' % (
            cfg.structure, ts._num(r['atoms'], '%d'), cfg.label, cfg.rt,
            ts._num(r['s_per_frame'], '%.4f'), ts._num(r['gpu_ms_median'], '%.1f'),
            ts._num(d1, '%+.1f%%'), ts._num(d2, '%+.1f ms')))
    text = '\n'.join(rows) + '\n'
    sha = None
    if os.path.isfile(app + '.sha'):
        sha = open(app + '.sha').read().strip()
    with open(os.path.join(out, 'results.json'), 'w') as fh:
        json.dump({'app': app, 'app_sha': sha, 'started': started,
                   'ended': datetime.datetime.now().isoformat(timespec='seconds'),
                   'frames': args.frames, 'summary': summary, 'failed': failed,
                   'runs': {t: e['runs'] for t, e in results.items()}}, fh, indent=2)
    with open(os.path.join(out, 'table.md'), 'w') as fh:
        fh.write(text)
    print(text, flush=True)
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
