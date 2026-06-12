"""Representation-inspector data query for the native SwiftUI macOS app.

Enumerates, per object, the ACTIVE representations and the current values of the
renderable settings the inspector UI exposes, plus each rep's color-override
state (two-layer color model: '<rep>_color' defaults to -1 = inherit atom color)
and the global "Scene" parameters. Emits one feedback line `OBJDETAIL:<json>`
that PyMOLEngine.parseObjectDetailFeedback() consumes.

Kept as a bundled module (not an inline Swift string) so it stays readable and
testable. Mirrors the appkit_object_panel / appkit_ray_overlay pattern.
"""

from pymol import cmd

# Order roughly matches PyMOL's representation indices; only active ones surface.
REPS = ['lines', 'sticks', 'ribbon', 'cartoon', 'dots', 'spheres',
        'mesh', 'surface', 'nonbonded', 'nb_spheres', 'labels']

# Numeric/bool settings exposed per rep (besides color, handled separately).
REP_SETTINGS = {
    'cartoon':    ['cartoon_transparency', 'cartoon_loop_radius',
                   'cartoon_tube_radius', 'cartoon_fancy_helices'],
    'surface':    ['transparency', 'surface_quality', 'solvent_radius'],
    'sticks':     ['stick_transparency', 'stick_radius', 'stick_h_scale'],
    'spheres':    ['sphere_transparency', 'sphere_scale'],
    'nb_spheres': ['nb_spheres_size'],
    'mesh':       ['transparency', 'mesh_width'],
    'ribbon':     ['ribbon_transparency', 'ribbon_width'],
    'lines':      ['line_width'],
    'dots':       ['transparency', 'dot_density', 'dot_radius'],
    'nonbonded':  ['nonbonded_size'],
    'labels':     ['label_size'],
}

# Per-rep color-override setting (default -1 / -6 = inherit the atom color).
REP_COLOR = {
    'cartoon': 'cartoon_color', 'surface': 'surface_color',
    'sticks': 'stick_color', 'spheres': 'sphere_color',
    'ribbon': 'ribbon_color', 'mesh': 'mesh_color',
    'dots': 'dot_color', 'lines': 'line_color', 'labels': 'label_color',
}

SCENE_SETTINGS = ['metal_raytrace', 'metal_shadows', 'metal_ssao', 'metal_outline',
                  'metal_msaa', 'depth_cue', 'fog', 'field_of_view', 'surface_quality']


def _num(setting, obj):
    """cmd.get a setting (object-scoped if obj else global) as a float; bools→0/1."""
    try:
        v = cmd.get(setting, obj) if obj else cmd.get(setting)
    except Exception:
        return 0.0
    try:
        return float(v)
    except Exception:
        return 1.0 if v in (True, 'on', '1', 'yes') else 0.0


def _rep_color(obj, setting):
    """Resolve a rep color-override to '#rrggbb', or 'inherit' if -1/unset."""
    try:
        raw = cmd.get(setting, obj)
    except Exception:
        return 'inherit'
    ci = None
    try:
        ci = int(float(raw))
    except Exception:
        try:
            ci = cmd.get_color_index(raw)
        except Exception:
            return 'inherit'
    if ci is None or ci < 0:
        return 'inherit'
    try:
        t = cmd.get_color_tuple(ci)
    except Exception:
        return 'inherit'
    if not t or t == -1:
        return 'inherit'
    return '#%02x%02x%02x' % (int(t[0] * 255), int(t[1] * 255), int(t[2] * 255))


def _bg_rgb():
    """bg_rgb may be a hex string ('0x000000') or an (r,g,b) tuple → [r,g,b] floats."""
    try:
        v = cmd.get('bg_rgb')
    except Exception:
        return [0.0, 0.0, 0.0]
    if isinstance(v, (list, tuple)):
        try:
            return [float(x) for x in v][:3]
        except Exception:
            return [0.0, 0.0, 0.0]
    s = str(v).strip()
    if s[:2] in ('0x', '0X'):
        s = s[2:]
    if len(s) == 6:
        try:
            return [int(s[0:2], 16) / 255.0, int(s[2:4], 16) / 255.0,
                    int(s[4:6], 16) / 255.0]
        except Exception:
            pass
    return [0.0, 0.0, 0.0]


def _build(objs):
    detail = {}
    for o in objs:
        reps = []
        for r in REPS:
            try:
                present = cmd.count_atoms('(%s) & rep %s' % (o, r)) > 0
            except Exception:
                present = False
            if not present:
                continue
            vals = {s: _num(s, o) for s in REP_SETTINGS.get(r, [])}
            col = _rep_color(o, REP_COLOR[r]) if r in REP_COLOR else 'inherit'
            reps.append({'rep': r, 'vis': 1, 'vals': vals, 'color': col})
        detail[o] = reps
    scene = {s: _num(s, '') for s in SCENE_SETTINGS}
    scene['bg'] = _bg_rgb()
    return {'detail': detail, 'scene': scene}


def poll(objs):
    """Emit the OBJDETAIL feedback line for the given object names."""
    import json
    try:
        print('OBJDETAIL:' + json.dumps(_build(objs)))
    except Exception as e:
        print('OBJDETAIL_ERR:' + str(e))
