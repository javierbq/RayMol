#!/usr/bin/env python3
"""Lighting render harness (#611): headless RayMol renders for the lighting epic.

    render.py [--root CHECKOUT] --app APP --out DIR --set l1 --rig none|off [--only tag,tag]
    render.py [--root CHECKOUT] --app APP --out DIR --scenes FILE [--only tag,tag]
    render.py --compare DIR_A DIR_B
    render.py --sheet DIR [--cols N]

EDITING THIS FILE CHANGES THE L1 BASELINE KEY. The key is the merge-base with
master plus the sha256 of this file, and a master baseline is rendered with a
lone copy of it (`--root` pointing at a tree that holds only
testing/data/1rx1.pdb). Any edit means a new baseline request and a new
determinism proof (two runs of the same app, max difference 0).

L1 (checklist, docs/superpowers/checklists/2026-10-02-lighting-checklist.md):
16 images of 1rx1 at 1280x720 -- cartoon, surface, sticks, spheres, mesh, a 50%
transparent surface (the OIT path) and a glass surface, each with
metal_raytrace 0 and 1 and metal_shadows 0, plus cartoon with organic sticks
at metal_shadows 1 with metal_raytrace 0 and 1.

  --rig none  asserts that no light rig exists.
  --rig off   defines a 3-light rig plus air and switches it off: `lights
              three_point` then `lights off` once the `lights` command exists
              (#612), otherwise cmd.set_lights(<rig>) with enabled false. Which
              one runs is decided inside the generated scene script.

Every image is one `open -n` of the app: PYMOL_AUTOCMD='run <scene script>'
and PYMOL_AUTOEXPORT=<png>,<w>,<h>,<rt>. The app runs PYMOL_AUTOCMD twice (at
launch, and again right before the export) and splits it on every ';', so each
generated script starts with cmd.reinitialize(), is idempotent, and bakes in
every input: nothing is read from the environment. Each run appends one line to
<out>/_work/<tag>.ran, and an image passes only when both runs left their line.

What the export path needs, learnt the hard way (see also
scripts/materials_gallery/render.py):
  * the app has its own CFBundleIdentifier (a copy sharing io.raymol.RayMol
    with a running RayMol never renders); refused here;
  * the first export after a fresh copy is staged differs, so one throwaway
    render goes first;
  * `run` takes its path unquoted, AUTOCMD splits on ';' and AUTOEXPORT on ',',
    and the app acts on some words inside a command's text (orient, reset,
    load, fetch, show, .pse); paths with any of these are refused;
  * no `orient` at render time: a literal view, because the camera distance
    `orient` picks depends on the window shape each bundle id persists;
  * scripts reset to factory settings (reinitialize original_settings), so
    they must turn use_shaders back on: the Metal app sets it at its first
    draw, and without it cartoons and the background are not drawn;
  * an export without ray tracing is a single offscreen frame, and the Metal
    renderer clears each frame with the background the PREVIOUS frame set
    (SceneRender hands bg_rgb to the next beginFrame). So the background of
    every metal_raytrace 0 image is whatever the app last drew: nothing on a
    locked screen (the initial black), else the live view under the theme.
    The harness therefore renders on black and pins the theme to Classic
    (black viewport; PYMOL_AUTOTHEME), so that input is the same with the
    screen locked or not, and skips the first-boot Theme Studio, which would
    otherwise swap the scene for a preview on a fresh bundle id. (A scene file
    that changes bg_rgb changes the fog everywhere, but the background pixels
    only in metal_raytrace 1 images.);
  * time-dependent inputs are pinned here (metal_dof 0, metal_temporal_ao 0),
    never in the renderer.

--scenes FILE (JSON) lets later tickets define their own image lists without
editing this file:
    {"base": "l1" | null,             reproduce the 16 L1 tags (default null)
     "rig": "none" | "off" | "on",    default "none"; "on" = the rig, enabled
     "only": [tag, ...],              optional subset
     "extra": [python line, ...],     appended to every scene, after the view
     "size": [w, h],                  default [1280, 720]
     "scenes": [{"tag": t, "from": <l1 tag>, "rt": 0|1, "rig": ..., "size": [w, h],
                 "lines": [python line, ...]}, ...]}   add or override tags
A scene's lines run after the file's extra lines, before the rig block.

Exit codes: 0 ok; 1 an image failed, or --compare found a difference;
2 a refusal or usage error.

Python 3 standard library; Pillow and numpy are imported only where images
are decoded (--compare, --sheet, and the checks after each render).
"""
import argparse
import datetime
import hashlib
import json
import os
import plistlib
import re
import signal
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_ROOT = os.path.normpath(os.path.join(HERE, os.pardir, os.pardir))
PDB_REL = os.path.join('testing', 'data', '1rx1.pdb')
SIZE = (1280, 720)

# The view of `load 1rx1; remove solvent; orient m` (computed once with the
# headless core), with the slab widened by 10 A at each end so no surface is
# clipped. Never call orient at render time.
VIEW = (0.3716067671775818, 0.9216808080673218, 0.11141323298215866,
        -0.8250541687011719, 0.2728343904018402, 0.49482017755508423,
        0.42566895484924316, -0.27580052614212036, 0.8618237972259521,
        0.0, 0.0, -136.68341064453125,
        27.469600677490234, 44.069026947021484, 13.284542083740234,
        97.76224517822266, 175.60458374023438, -20.0)

# Black: see the docstring (rt0 exports clear with the previous frame's
# background, which is black whether or not the live view drew).
BG = [0.0, 0.0, 0.0]
# The theme PYMOL_AUTOTHEME selects at launch: Classic has a black viewport.
THEME = 'Classic'

_CARTOON = [
    "cmd.show('cartoon', 'm')",
    "cmd.color('grey80', 'm')",
    "cmd.spectrum('count', 'rainbow', 'm and name CA')",
]
_SURFACE_OVER_CARTOON = _CARTOON + [
    "cmd.show('surface', 'm and polymer')",
    "cmd.set('surface_color', 'grey80', 'm')",
]
# representation -> scene lines (object `m`)
REPS = {
    'cartoon': list(_CARTOON),
    'surface': [
        "cmd.show('surface', 'm and polymer')",
        "cmd.color('grey80', 'm')",
        "cmd.color('marine', 'm and resn LYS+ARG')",
        "cmd.color('red', 'm and resn ASP+GLU')",
    ],
    'sticks': [
        "cmd.show('sticks', 'm and not hydro')",
        "util.cbag('m')",
    ],
    'spheres': [
        "cmd.show('spheres', 'm and not hydro')",
        "util.cbag('m')",
    ],
    'mesh': [
        "cmd.show('mesh', 'm and polymer')",
        "cmd.color('slate', 'm')",
    ],
    'transparent': _SURFACE_OVER_CARTOON + ["cmd.set('transparency', 0.5)"],
    'glass': _SURFACE_OVER_CARTOON + ["cmd.set('surface_material', 'glass')"],
    'shadows': _CARTOON + [
        "cmd.show('sticks', 'm and organic and not hydro')",
        "util.cbag('m and organic')",
    ],
}
REP_ORDER = ('cartoon', 'surface', 'sticks', 'spheres', 'mesh', 'transparent',
             'glass', 'shadows')
SHADOW_REPS = ('shadows',)   # metal_shadows 1; every other tag bakes 0


def l1_tags():
    """The 16 L1 tags, in render order."""
    return ['%s_rt%d' % (rep, rt) for rep in REP_ORDER for rt in (0, 1)]


def _l1_parts(tag):
    rep, rt = tag.rsplit('_rt', 1)
    return rep, int(rt)


def baked_settings(rt, shadows):
    """Every global the image depends on, set explicitly even where it equals
    the factory value: the persisted theme or a scene could otherwise differ."""
    return [
        # The Metal app turns use_shaders on at its first draw
        # (PyMOL_DrawWithoutLock: Metal draws VBOs, never immediate mode), and
        # reinitialize original_settings puts back the factory 0, which drops
        # cartoons and the background from the export. Set it back.
        ('use_shaders', 1),
        ('bg_rgb', BG),
        ('ray_opaque_background', 1),
        ('depth_cue', 1),
        ('orthoscopic', 0),
        ('field_of_view', 20.0),
        ('metal_raytrace', rt),
        ('metal_shadows', shadows),
        ('metal_rt_shadows', 1),
        ('metal_ssao', 1),
        ('metal_outline', 0),
        ('metal_tonemap', 0),
        ('metal_msaa', 1),
        ('metal_upscale', 0),
        # time-dependent inputs, pinned
        ('metal_dof', 0),
        ('metal_temporal_ao', 0),
        # themes toggle these
        ('cartoon_flat_sheets', 0),
        ('cartoon_fancy_helices', 0),
    ]


# The rig for --rig off (enabled False) and "rig": "on" (enabled True): the
# version-1 dict of cmd.set_lights. Every value is inside the field ranges.
# The fill light's aim_point and the pinned rim's position depend on the
# molecule and are filled in by the scene script (placeholders here).
RIG_OFF = {
    'version': 1,
    'enabled': False,
    'ambient': 0.1,
    'classic': 0.0,
    'air': {'haze': 0.3, 'dust': 0.5, 'dust_size': 0.4, 'dust_speed': 1.0,
            'scatter': 0.55, 'seed': 7},
    'lights': [
        {'name': 'key', 'anchor': 'camera', 'orbit': -45.0, 'pitch': 35.0,
         'beam': 55.0, 'softness': 0.5, 'warmth': 4500.0, 'intensity': 1.15,
         'shadow': True},
        {'name': 'fill', 'anchor': 'camera', 'orbit': 55.0, 'pitch': 5.0,
         'beam': 80.0, 'softness': 0.8, 'warmth': 8000.0, 'intensity': 0.35,
         'aim': 'point', 'aim_point': [0.0, 0.0, 0.0], 'aim_selection': 'm'},
        {'name': 'rim', 'anchor': 'pinned', 'position': [0.0, 0.0, 0.0],
         'beam': 40.0, 'intensity': 1.6, 'outline': True},
    ],
}
RIGS = ('none', 'off', 'on')

# Text the app acts on inside a command (PyMOLEngine.runCommandCore:
# maybeWidenClipForSurface, handleSessionViewport), or that `run`, AUTOCMD (';')
# and AUTOEXPORT (',') would split or expand.
FORBIDDEN_WORDS = ('orient', 'reset', 'load ', 'fetch ', 'show ', '.pse')
FORBIDDEN_CHARS = (',', ';', '$', "'", '"')
MAIN_BUNDLE_ID = 'io.raymol.RayMol'
TAG_RE = re.compile(r'^[a-z0-9][a-z0-9_]*$')


class Refusal(Exception):
    """A usage error or a refused input: exit 2, nothing launched."""


# --- jobs and scene scripts -------------------------------------------------

class Job(object):
    def __init__(self, tag, rep_lines, rt, shadows, rig, extra=(), size=SIZE):
        self.tag = tag
        self.rep_lines = list(rep_lines)
        self.rt = int(rt)
        self.shadows = int(shadows)
        self.rig = rig
        self.extra = list(extra)
        self.size = (int(size[0]), int(size[1]))

    def describe(self):
        return '%s rt=%d shadows=%d rig=%s size=%dx%d extra=%d' % (
            self.tag, self.rt, self.shadows, self.rig, self.size[0],
            self.size[1], len(self.extra))


def l1_job(tag, rig, extra=(), size=SIZE):
    rep, rt = _l1_parts(tag)
    return Job(tag, REPS[rep], rt, 1 if rep in SHADOW_REPS else 0, rig,
               extra, size)


def l1_jobs(rig):
    if rig not in ('none', 'off'):
        raise Refusal('--set l1 takes --rig none or off, not %r' % (rig,))
    return [l1_job(tag, rig) for tag in l1_tags()]


def _rig_block(rig):
    if rig == 'none':
        return [
            '# rig: none',
            "assert getattr(cmd, 'get_lights', lambda: None)() is None, "
            "'a light rig is present in a --rig none scene'",
        ]
    enabled = rig == 'on'
    lines = [
        '# rig: %s' % rig,
        '_lh_rig = %r' % (RIG_OFF,),
        "_lh_rig['enabled'] = %r" % (enabled,),
        "_lh_mn, _lh_mx = cmd.get_extent('m')",
        "_lh_rig['lights'][1]['aim_point'] = ["
        "(_lh_mn[0] + _lh_mx[0]) / 2.0 + 5.0, "
        "(_lh_mn[1] + _lh_mx[1]) / 2.0, (_lh_mn[2] + _lh_mx[2]) / 2.0]",
        "_lh_rig['lights'][2]['position'] = ["
        "_lh_mx[0] + 10.0, _lh_mx[1] + 10.0, _lh_mx[2] + 10.0]",
    ]
    if rig == 'off':
        lines += [
            "if 'lights' in cmd.keyword:",
            "    cmd.keyword['lights'][0]('three_point')",
            "    cmd.keyword['lights'][0]('off')",
            "elif hasattr(cmd, 'set_lights'):",
            "    cmd.set_lights(_lh_rig)",
            "else:",
            "    raise RuntimeError('no light rig API')",
        ]
    else:
        lines += [
            "if not hasattr(cmd, 'set_lights'):",
            "    raise RuntimeError('no light rig API')",
            "cmd.set_lights(_lh_rig)",
        ]
    lines += [
        "_lh_got = cmd.get_lights()",
        "assert _lh_got is not None and bool(_lh_got['enabled']) is %r "
        "and len(_lh_got['lights']) >= 1, 'rig not as expected: %%r' %% (_lh_got,)"
        % (enabled,),
    ]
    return lines


def _marker_block(tag, marker):
    return [
        '# marker (last): one line per run of this script',
        '_lh_marker = %r' % (marker,),
        'try:',
        '    with open(_lh_marker) as _lh_fh:',
        '        _lh_runs = len(_lh_fh.read().splitlines())',
        'except OSError:',
        '    _lh_runs = 0',
        "_lh_get = getattr(cmd, 'get_lights', None)",
        'if _lh_get is None:',
        "    _lh_state = 'absent'",
        'else:',
        '    _lh_r = _lh_get()',
        "    _lh_state = 'none' if _lh_r is None else {"
        "'enabled': bool(_lh_r['enabled']), 'lights': len(_lh_r['lights'])}",
        "with open(_lh_marker, 'a') as _lh_fh:",
        "    _lh_fh.write(_lh_json.dumps({'tag': %r, 'run': _lh_runs + 1, "
        "'atoms': cmd.count_atoms('m'), 'rig': _lh_state}) + '\\n')" % (tag,),
    ]


def scene_script(root, job, marker):
    """The text of one idempotent scene script. Pure: same inputs, same text."""
    pdb = os.path.join(root, PDB_REL)
    lines = [
        '# generated by scripts/lighting/render.py -- do not edit',
        'from pymol import cmd, util',
        'cmd.reinitialize()',
        "cmd.reinitialize('original_settings')",
        'import json as _lh_json',
        'cmd.load(%r, %r)' % (pdb, 'm'),
        "cmd.remove('solvent')",
        "cmd.hide('everything')",
    ]
    lines += job.rep_lines
    for name, value in baked_settings(job.rt, job.shadows):
        lines.append('cmd.set(%r, %r)' % (name, value))
    lines.append('cmd.set_view(%r, animate=0)' % (VIEW,))
    lines += job.extra
    lines += _rig_block(job.rig)
    lines += _marker_block(job.tag, marker)
    return '\n'.join(lines) + '\n'


def work_dir(out):
    return os.path.join(out, '_work')


def script_path(out, tag):
    return os.path.join(work_dir(out), tag + '.py')


def marker_path(out, tag):
    return os.path.join(work_dir(out), tag + '.ran')


def png_path(out, tag):
    return os.path.join(out, tag + '.png')


def write_scripts(root, out, jobs):
    os.makedirs(work_dir(out), exist_ok=True)
    paths = []
    for job in jobs:
        path = script_path(out, job.tag)
        with open(path, 'w') as handle:
            handle.write(scene_script(root, job, marker_path(out, job.tag)))
        paths.append(path)
    return paths


# --- scene files --------------------------------------------------------------

_FILE_KEYS = {'base', 'rig', 'only', 'extra', 'size', 'scenes', 'comment'}
_SCENE_KEYS = {'tag', 'from', 'rt', 'rig', 'size', 'lines', 'comment'}


def _lines(value, what):
    if not isinstance(value, list) or not all(isinstance(v, str) for v in value):
        raise Refusal('%s must be a list of strings' % what)
    for v in value:
        if '\n' in v:
            raise Refusal('%s: one statement per string, no newlines' % what)
    return value


def _size(value, what):
    if (not isinstance(value, list) or len(value) != 2 or
            not all(isinstance(v, int) and not isinstance(v, bool) and
                    16 <= v <= 8192 for v in value)):
        raise Refusal('%s must be [width, height] (integers, 16..8192)' % what)
    return tuple(value)


def _rig(value, what):
    if value not in RIGS:
        raise Refusal('%s must be one of %s, not %r' % (what, ', '.join(RIGS), value))
    return value


def scene_file_jobs(path):
    """Jobs from a --scenes JSON file (see the module docstring)."""
    try:
        with open(path) as handle:
            spec = json.load(handle)
    except (OSError, ValueError) as e:
        raise Refusal('cannot read scene file %s: %s' % (path, e))
    if not isinstance(spec, dict):
        raise Refusal('%s: the top level must be an object' % path)
    unknown = sorted(set(spec) - _FILE_KEYS)
    if unknown:
        raise Refusal('%s: unknown keys %s' % (path, ', '.join(unknown)))
    rig = _rig(spec.get('rig', 'none'), '%s: rig' % path)
    extra = _lines(spec.get('extra', []), '%s: extra' % path)
    size = _size(spec['size'], '%s: size' % path) if 'size' in spec else SIZE
    base = spec.get('base')
    if base not in (None, 'l1'):
        raise Refusal('%s: base must be "l1" or null, not %r' % (path, base))
    jobs = []
    if base == 'l1':
        jobs = [l1_job(tag, rig, extra, size) for tag in l1_tags()]
    scenes = spec.get('scenes', [])
    if not isinstance(scenes, list):
        raise Refusal('%s: scenes must be a list' % path)
    for n, entry in enumerate(scenes):
        what = '%s: scenes[%d]' % (path, n)
        if not isinstance(entry, dict):
            raise Refusal('%s must be an object' % what)
        unknown = sorted(set(entry) - _SCENE_KEYS)
        if unknown:
            raise Refusal('%s: unknown keys %s' % (what, ', '.join(unknown)))
        tag = entry.get('tag')
        if not isinstance(tag, str) or not TAG_RE.match(tag):
            raise Refusal('%s: tag must match %s' % (what, TAG_RE.pattern))
        source = entry.get('from')
        if source is not None and source not in l1_tags():
            raise Refusal('%s: from must be an L1 tag, not %r' % (what, source))
        if source is None:
            rep_lines, rt, shadows = [], 0, 0
        else:
            rep, rt = _l1_parts(source)
            rep_lines, shadows = REPS[rep], 1 if rep in SHADOW_REPS else 0
        if 'rt' in entry:
            if entry['rt'] not in (0, 1) or isinstance(entry['rt'], bool):
                raise Refusal('%s: rt must be 0 or 1' % what)
            rt = entry['rt']
        job = Job(tag, rep_lines, rt, shadows,
                  _rig(entry.get('rig', rig), '%s: rig' % what),
                  extra + _lines(entry.get('lines', []), '%s: lines' % what),
                  _size(entry['size'], '%s: size' % what) if 'size' in entry else size)
        jobs = [j for j in jobs if j.tag != tag] + [job]
    only = spec.get('only')
    if only is not None:
        only = _lines(only, '%s: only' % path)
        jobs = select(jobs, only, '%s: only' % path)
    if not jobs:
        raise Refusal('%s defines no images' % path)
    return jobs


def select(jobs, tags, what='--only'):
    known = [j.tag for j in jobs]
    unknown = [t for t in tags if t not in known]
    if unknown:
        raise Refusal('%s: unknown tags %s (known: %s)' % (
            what, ', '.join(unknown), ', '.join(known)))
    return [j for j in jobs if j.tag in tags]


# --- refusals -----------------------------------------------------------------

def check_path(label, path):
    """Refuse a path the app's command handling would split, expand or act on."""
    if any(c.isspace() for c in path):
        raise Refusal('%s %r contains whitespace: `run` takes its path unquoted'
                      % (label, path))
    for c in FORBIDDEN_CHARS:
        if c in path:
            raise Refusal('%s %r contains %r: PYMOL_AUTOCMD splits on ";", '
                          'PYMOL_AUTOEXPORT on ",", and `run` expands "$"'
                          % (label, path, c))
    lower = path.lower()
    for word in FORBIDDEN_WORDS:
        if word in lower:
            raise Refusal('%s %r contains %r, which the app acts on inside a '
                          'command (PyMOLEngine.runCommandCore)' % (label, path, word))


def app_info(app):
    plist = os.path.join(app, 'Contents', 'Info.plist')
    try:
        with open(plist, 'rb') as handle:
            info = plistlib.load(handle)
        return info['CFBundleIdentifier'], info['CFBundleExecutable']
    except (OSError, KeyError, ValueError, plistlib.InvalidFileException) as e:
        raise Refusal('%s is not an app bundle (%s): %s' % (app, plist, e))


def check_app(app):
    """Refuse the canonical bundle id and a dev app with MCP enabled."""
    ident, exe = app_info(app)
    if ident == MAIN_BUNDLE_ID:
        raise Refusal('refusing %s: its CFBundleIdentifier is %s; a copy sharing '
                      'it with a running RayMol never renders. Give it its own id.'
                      % (app, ident))
    try:
        res = subprocess.run(['defaults', 'read', ident, 'raymol.mcp.enabled'],
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             universal_newlines=True, timeout=20)
        if res.returncode == 0 and res.stdout.strip() == '1':
            raise Refusal('refusing %s: raymol.mcp.enabled is 1 for %s; a dev '
                          'app must not write the canonical mcp.json' % (app, ident))
    except (OSError, subprocess.SubprocessError):
        pass   # no `defaults` (not macOS): nothing to check
    return ident, exe


def check_root(root):
    pdb = os.path.join(root, PDB_REL)
    if not os.path.isfile(pdb):
        raise Refusal('--root %s does not contain %s' % (root, PDB_REL))


# --- running the app ----------------------------------------------------------

def app_pids(binaries):
    """PIDs whose argv[0] is exactly one of `binaries` (never pkill -f)."""
    try:
        out = subprocess.run(['ps', '-axww', '-o', 'pid=,args='],
                             stdout=subprocess.PIPE, universal_newlines=True,
                             check=True).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    pids = []
    for line in out.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and parts[1].split(' ', 1)[0] in binaries:
            try:
                pids.append(int(parts[0]))
            except ValueError:
                pass
    return [p for p in pids if p != os.getpid()]


def kill_app(binaries):
    pids = app_pids(binaries)
    for pid in pids:
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass
    deadline = time.time() + 5
    while pids and time.time() < deadline:
        time.sleep(0.25)
        pids = [p for p in pids if p in app_pids(binaries)]
    for pid in pids:
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass
    if pids:
        time.sleep(1)


def launch_env(script, png, size, rt):
    """The environment of one export (`open --env` passes only these)."""
    return [
        'PYMOL_SKIP_WHATS_NEW=1',
        'PYMOL_SKIP_FIRSTBOOT_THEME=1',
        'PYMOL_AUTOTHEME=%s' % THEME,
        'PYMOL_AUTOCMD=run %s' % script,
        'PYMOL_AUTOEXPORT=%s,%d,%d,%d' % (png, size[0], size[1], rt),
    ]


def launch(app, binaries, script, png, size, rt, timeout):
    """One export. Returns an error string, or None once the PNG is written."""
    kill_app(binaries)
    if os.path.exists(png):
        os.remove(png)
    env = []
    for item in launch_env(script, png, size, rt):
        env += ['--env', item]
    try:
        res = subprocess.run(['open', '-n'] + env + [app])
        if res.returncode != 0:
            return 'open exited %d' % res.returncode
        deadline = time.time() + timeout
        last = -1
        while time.time() < deadline:
            if os.path.exists(png):
                size_now = os.path.getsize(png)
                if size_now > 0 and size_now == last:
                    time.sleep(2)
                    return None
                last = size_now
            time.sleep(1)
        return 'no PNG after %ds' % timeout
    finally:
        kill_app(binaries)


def check_marker(path, tag, rig):
    """Both runs of the scene script left their line. Returns an error or None."""
    try:
        with open(path) as handle:
            rows = [json.loads(line) for line in handle.read().splitlines()]
    except (OSError, ValueError) as e:
        return 'marker unreadable: %s' % e
    if len(rows) != 2:
        return 'marker has %d lines, expected 2 (init run + pre-export run)' % len(rows)
    if [r.get('run') for r in rows] != [1, 2]:
        return 'marker runs %r, expected [1, 2]' % [r.get('run') for r in rows]
    if any(r.get('tag') != tag for r in rows):
        return 'marker tags %r, expected %r' % ([r.get('tag') for r in rows], tag)
    atoms = [r.get('atoms') for r in rows]
    if not (isinstance(atoms[0], int) and atoms[0] > 0 and atoms[0] == atoms[1]):
        return 'marker atom counts %r' % atoms
    for r in rows:
        state = r.get('rig')
        if rig == 'none':
            ok = state in ('absent', 'none')
        else:
            ok = (isinstance(state, dict) and state.get('enabled') is (rig == 'on')
                  and isinstance(state.get('lights'), int) and state['lights'] >= 1)
        if not ok:
            return 'marker rig state %r does not match --rig %s' % (state, rig)
    return None


def load_rgba(path):
    from PIL import Image
    import numpy
    with Image.open(path) as image:
        return numpy.asarray(image.convert('RGBA'), dtype=numpy.int16)


def check_image(path, size):
    """The PNG decodes, has the requested size and is not a single colour."""
    try:
        pixels = load_rgba(path)
    except Exception as e:   # Pillow raises several types for a bad file
        return 'PNG does not decode: %s' % e
    if (pixels.shape[1], pixels.shape[0]) != tuple(size):
        return 'PNG is %dx%d, expected %dx%d' % (
            pixels.shape[1], pixels.shape[0], size[0], size[1])
    if (pixels == pixels[0, 0]).all():
        return 'PNG is a single colour %r' % (tuple(int(v) for v in pixels[0, 0]),)
    return None


def sha256(path):
    with open(path, 'rb') as handle:
        return hashlib.sha256(handle.read()).hexdigest()


def render(args, jobs, mode):
    root = os.path.abspath(args.root)
    out = os.path.abspath(args.out)
    app = os.path.abspath(args.app).rstrip('/') if args.app else None
    check_path('--out', out)
    check_path('--root', root)
    if args.scenes:
        check_path('--scenes', os.path.abspath(args.scenes))
    for job in jobs:
        check_path('tag', job.tag)
        check_path('scene script', script_path(out, job.tag))
        check_path('image', png_path(out, job.tag))
    check_root(root)
    if app:
        check_path('--app', app)
        ident, exe = check_app(app)
    elif not args.dry_run:
        raise Refusal('--app is required to render')
    if args.only:
        jobs = select(jobs, [t for t in args.only.split(',') if t])
    if not jobs:
        raise Refusal('nothing to render')

    stale = sorted(n for n in _pngs(out) if n[:-4] not in [j.tag for j in jobs]) \
        if os.path.isdir(out) else []
    write_scripts(root, out, jobs)
    if args.dry_run:
        for job in jobs:
            print('%s  %s' % (job.describe(), script_path(out, job.tag)))
        print('dry run: %d scene scripts in %s' % (len(jobs), work_dir(out)))
        return 0
    if stale:
        print('WARNING: %s holds images this run does not render: %s'
              % (out, ', '.join(stale)), flush=True)

    binary = os.path.join(app, 'Contents', 'MacOS', exe)
    binaries = {binary, os.path.realpath(binary)}
    started = datetime.datetime.now().isoformat(timespec='seconds')

    # One throwaway render: the first export after a fresh copy differs.
    warm = os.path.join(work_dir(out), '_warm.py')
    warm_job = jobs[0]
    with open(warm, 'w') as handle:
        handle.write(scene_script(root, warm_job, marker_path(out, '_warm')))
    if os.path.exists(marker_path(out, '_warm')):
        os.remove(marker_path(out, '_warm'))
    err = launch(app, binaries, warm, os.path.join(work_dir(out), '_warm.png'),
                 warm_job.size, warm_job.rt, args.timeout)
    print('[warm] %s' % (err or 'ok'), flush=True)

    failed = []
    for n, job in enumerate(jobs, 1):
        png = png_path(out, job.tag)
        marker = marker_path(out, job.tag)
        if os.path.exists(marker):
            os.remove(marker)
        err = launch(app, binaries, script_path(out, job.tag), png, job.size,
                     job.rt, args.timeout)
        err = err or check_marker(marker, job.tag, job.rig) or check_image(png, job.size)
        print('[%d/%d] %s %s' % (n, len(jobs), job.tag, 'ok' if not err else 'FAIL: ' + err),
              flush=True)
        if err:
            failed.append(job.tag)

    sha_file = app + '.sha'
    app_sha = None
    if os.path.isfile(sha_file):
        with open(sha_file) as handle:
            app_sha = handle.read().strip()
    provenance = {
        'app': app, 'bundle_id': ident, 'app_sha': app_sha,
        'render_py_sha256': sha256(os.path.abspath(__file__)),
        'root': root, 'mode': mode, 'rig': sorted({j.rig for j in jobs}),
        'tags': [j.tag for j in jobs], 'failed': failed,
        'started': started,
        'ended': datetime.datetime.now().isoformat(timespec='seconds'),
    }
    with open(os.path.join(out, 'render.json'), 'w') as handle:
        json.dump(provenance, handle, indent=2)
    if failed:
        print('%d of %d images failed: %s' % (len(failed), len(jobs), ', '.join(failed)))
        return 1
    print('%d images in %s' % (len(jobs), out))
    return 0


# --- compare and sheet --------------------------------------------------------

def _pngs(directory):
    """Top-level images, without sheet.png and names starting with '_'."""
    return sorted(n for n in os.listdir(directory)
                  if n.endswith('.png') and n != 'sheet.png' and not n.startswith('_')
                  and os.path.isfile(os.path.join(directory, n)))


def compare(dir_a, dir_b, out=None):
    """Decoded RGBA, pixel for pixel. 0 only when both sets are equal and
    non-empty, every size matches and every max difference is 0."""
    out = out or sys.stdout
    import numpy
    for d in (dir_a, dir_b):
        if not os.path.isdir(d):
            raise Refusal('--compare: %s is not a directory' % d)
    a, b = _pngs(dir_a), _pngs(dir_b)
    missing = [n for n in a if n not in b]
    extra = [n for n in b if n not in a]
    ok = bool(a) and bool(b) and not missing and not extra
    overall, compared, mismatched = 0, 0, []
    for name in a:
        if name not in b:
            continue
        pa = load_rgba(os.path.join(dir_a, name))
        pb = load_rgba(os.path.join(dir_b, name))
        if pa.shape != pb.shape:
            mismatched.append('%s (%dx%d vs %dx%d)' % (
                name, pa.shape[1], pa.shape[0], pb.shape[1], pb.shape[0]))
            ok = False
            continue
        diff = numpy.abs(pa - pb)
        top = int(diff.max())
        print('%s max=%d differing_px=%d' % (name, top, int((diff.max(axis=2) > 0).sum())),
              file=out)
        overall = max(overall, top)
        compared += 1
        if top:
            ok = False
    if missing:
        print('missing in B: %s' % ', '.join(missing), file=out)
    if extra:
        print('extra in B: %s' % ', '.join(extra), file=out)
    if mismatched:
        print('size mismatch: %s' % ', '.join(mismatched), file=out)
    if compared:
        print('overall max=%d images=%d' % (overall, compared), file=out)
    else:
        print('overall max=n/a images=0', file=out)
    return 0 if ok else 1


def sheet(directory, cols=4, cell_width=480):
    """A labelled grid of the top-level images -> DIRECTORY/sheet.png."""
    from PIL import Image, ImageDraw, ImageFont
    names = _pngs(directory)
    if not names:
        raise Refusal('--sheet: no images in %s' % directory)
    cols = max(1, min(int(cols), len(names)))
    thumbs = []
    for name in names:
        with Image.open(os.path.join(directory, name)) as image:
            image = image.convert('RGB')
            height = max(1, round(image.height * cell_width / float(image.width)))
            thumbs.append((name[:-4], image.resize((cell_width, height), Image.LANCZOS)))
    label = 18
    cell_h = max(t.height for _, t in thumbs) + label
    rows = (len(thumbs) + cols - 1) // cols
    grid = Image.new('RGB', (cols * cell_width, rows * cell_h), (255, 255, 255))
    draw = ImageDraw.Draw(grid)
    font = ImageFont.load_default()
    for i, (tag, thumb) in enumerate(thumbs):
        x, y = (i % cols) * cell_width, (i // cols) * cell_h
        grid.paste(thumb, (x, y + label))
        draw.text((x + 4, y + 3), tag, fill=(0, 0, 0), font=font)
    path = os.path.join(directory, 'sheet.png')
    grid.save(path)
    print('sheet: %s (%d images)' % (path, len(thumbs)))
    return 0


# --- CLI ----------------------------------------------------------------------

def parse_args(argv):
    ap = argparse.ArgumentParser(
        description=__doc__.split('\n\n')[0],
        epilog='Exit codes: 0 ok; 1 an image failed or --compare differs; '
               '2 refusal or usage error.')
    ap.add_argument('--root', default=DEFAULT_ROOT,
                    help='checkout holding testing/data/1rx1.pdb (default: this '
                         "file's checkout)")
    ap.add_argument('--app', help='a RayMol .app with its own bundle id '
                                  '(accepted and ignored by --compare/--sheet)')
    ap.add_argument('--out', help='output directory')
    ap.add_argument('--set', choices=('l1',), help='a built-in image set')
    ap.add_argument('--rig', choices=('none', 'off'), help='with --set l1')
    ap.add_argument('--scenes', help='a scene file (JSON; see the docstring)')
    ap.add_argument('--only', default='', help='comma-separated tags')
    ap.add_argument('--timeout', type=int, default=120,
                    help='seconds to wait for each PNG (default 120)')
    ap.add_argument('--dry-run', action='store_true',
                    help='write the scene scripts and list the jobs; launch nothing')
    ap.add_argument('--compare', nargs=2, metavar=('DIR_A', 'DIR_B'),
                    help='compare the top-level PNGs of two directories')
    ap.add_argument('--sheet', metavar='DIR', help='write DIR/sheet.png')
    ap.add_argument('--cols', type=int, default=4, help='columns for --sheet')
    return ap, ap.parse_args(argv)


def main(argv=None):
    ap, args = parse_args(argv)
    try:
        if args.compare:
            if args.sheet or args.set or args.scenes:
                raise Refusal('--compare takes no other mode')
            return compare(*args.compare)
        if args.sheet:
            if args.set or args.scenes:
                raise Refusal('--sheet takes no other mode')
            return sheet(args.sheet, args.cols)
        if bool(args.set) == bool(args.scenes):
            raise Refusal('give exactly one of --set l1, --scenes FILE, '
                          '--compare or --sheet')
        if not args.out:
            raise Refusal('--out is required to render')
        if args.set:
            if not args.rig:
                raise Refusal('--set l1 needs --rig none or --rig off')
            jobs, mode = l1_jobs(args.rig), 'l1'
        else:
            if args.rig:
                raise Refusal('--rig goes with --set l1; a scene file sets its own rig')
            jobs, mode = scene_file_jobs(args.scenes), 'scenes:' + os.path.abspath(args.scenes)
        return render(args, jobs, mode)
    except Refusal as e:
        print('render.py: %s' % e, file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
