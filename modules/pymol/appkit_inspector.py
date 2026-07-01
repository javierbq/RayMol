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
                   'cartoon_tube_radius', 'cartoon_fancy_helices',
                   'cartoon_flat_sheets'],
    'surface':    ['transparency', 'surface_quality', 'solvent_radius',
                   'surface_clip_front', 'surface_clip_back', 'metal_interior_cap',
                   'surface_contour', 'surface_contour_width',
                   'surface_contour_opaque'],
    'sticks':     ['stick_transparency', 'stick_radius', 'stick_h_scale', 'metal_interior_cap'],
    'spheres':    ['sphere_transparency', 'sphere_scale', 'metal_interior_cap'],
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

# Extra per-rep color settings (besides the main rep color), resolved to
# '#rrggbb'/'inherit' and sent in the rep's 'colors' dict for color-kind controls.
REP_EXTRA_COLORS = {
    'surface': ['surface_contour_color'],
}

SCENE_SETTINGS = ['metal_raytrace', 'metal_rt_shadows', 'metal_shadows', 'metal_ssao',
                  'metal_outline', 'metal_outline_width', 'metal_msaa',
                  'metal_tonemap', 'metal_exposure',
                  'metal_sss_wrap', 'metal_dof', 'metal_dof_focus',
                  'metal_dof_range', 'metal_dof_aperture', 'metal_temporal_ao', 'metal_upscale',
                  'depth_cue', 'fog', 'field_of_view', 'surface_quality',
                  'grid_mode', 'all_states', 'mouse_selection_mode',
                  'ambient', 'direct', 'reflect', 'specular', 'shininess',
                  'ray_opaque_background']


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
    """Background color → [r,g,b] floats. `bg_rgb` resolves to a hex string, an
    (r,g,b) tuple, OR a named color / index — the last happens after the panel
    runs `bg_color <name>` (cmd.get returns the name, e.g. '_bgcol'). Resolve it
    the same robust way as any other color setting so the swatch never falls
    back to black for a non-hex background."""
    return _color_setting_rgb('bg_rgb')


def _color_setting_rgb(setting, fallback=(0.0, 0.0, 0.0)):
    """Resolve a color-type global setting (e.g. metal_outline_color) to [r,g,b]
    floats in 0…1. Handles (r,g,b) tuples, '0xRRGGBB' hex, color names, and
    numeric color indices."""
    try:
        v = cmd.get(setting)
    except Exception:
        return list(fallback)
    if isinstance(v, (list, tuple)):
        try:
            return [float(x) for x in v][:3]
        except Exception:
            return list(fallback)
    s = str(v).strip()
    if s[:2] in ('0x', '0X') and len(s) == 8:
        try:
            return [int(s[2:4], 16) / 255.0, int(s[4:6], 16) / 255.0,
                    int(s[6:8], 16) / 255.0]
        except Exception:
            pass
    try:
        ci = int(float(s))
    except Exception:
        try:
            ci = cmd.get_color_index(s)
        except Exception:
            return list(fallback)
    try:
        t = cmd.get_color_tuple(ci)
    except Exception:
        return list(fallback)
    if not t or t == -1:
        return list(fallback)
    return [float(t[0]), float(t[1]), float(t[2])]


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
            cols = {s: _rep_color(o, s) for s in REP_EXTRA_COLORS.get(r, [])}
            reps.append({'rep': r, 'vis': 1, 'vals': vals, 'color': col,
                         'colors': cols})
        detail[o] = reps
    scene = {s: _num(s, '') for s in SCENE_SETTINGS}
    scene['bg'] = _bg_rgb()
    scene['outline_rgb'] = _color_setting_rgb('metal_outline_color')
    # Per-object state metadata for the inspector STATE row: the effective
    # current state (the object's 'state' setting, which resolves to the global
    # frame's state when not pinned) and whether all states are overlaid.
    objmeta = {}
    for o in objs:
        objmeta[o] = {'state': int(round(_num('state', o))),
                      'all': int(round(_num('all_states', o)))}
    # Saved scenes (ordered) + the current one, for the Scenes strip.
    try:
        scenes = list(cmd.get_scene_list() or [])
    except Exception:
        scenes = []
    try:
        cur_scene = cmd.get('scene_current_name') or ''
    except Exception:
        cur_scene = ''
    return {'detail': detail, 'scene': scene, 'objmeta': objmeta,
            'scenes': scenes, 'cur_scene': cur_scene}


def poll(objs):
    """Write the inspector JSON to a temp file and print a short marker.

    The payload (per-rep detail + scene params + objmeta + scene list) can exceed
    PyMOL's ~1KB feedback-line cap; printing it inline made the overflow split
    across feedback lines, and the continuation lines (no OBJDETAIL: prefix)
    leaked into the terminal log. So write the full JSON to a temp file (same
    TMPDIR the Swift app reads) and emit only `OBJDETAIL:ready` — same pattern as
    the sequence panel."""
    import json, os, tempfile
    try:
        p = os.path.join(tempfile.gettempdir(), 'pymol_objdetail.json')
        with open(p, 'w') as _f:
            _f.write(json.dumps(_build(objs)))
        print('OBJDETAIL:ready')
    except Exception as e:
        print('OBJDETAIL_ERR:' + str(e))


def widen_clip_for_surface(buffer=12.0):
    """When a probe-extended rep (surface / mesh / dots) is shown, widen the
    clipping slab so the rep's ~solvent_radius shell (~3 A beyond the atoms) isn't
    front-clipped by the atom-fit slab that orient/reset/load set (which would
    slice the surface front and expose the interior).

    Re-fit tight to the visible content first (zoom buffer 0 — idempotent, keeps
    the molecule the same size), THEN push the near/far planes out by `buffer`.
    The zoom reset makes repeated calls non-accumulating; the direct plane move
    (not a camera dolly) clears the shell without shrinking the molecule, and
    moving BOTH planes keeps the slab centered so depth precision stays good.
    No-op when no such rep is shown."""
    try:
        if (cmd.count_atoms('rep surface') + cmd.count_atoms('rep mesh')
                + cmd.count_atoms('rep dots')) > 0:
            cmd.zoom('visible', 0.0, complete=1)   # reset slab to tight visible fit
            # `clip near, +d` moves the near plane TOWARD the viewer (front -= d);
            # `clip far, -d` moves the far plane AWAY (back += d). Together they
            # WIDEN the slab so the ~solvent_radius surface shell at both faces is
            # inside it. (The opposite signs would narrow the slab and clip the
            # surface — and the interior — away.)
            cmd.clip('near', float(buffer))
            cmd.clip('far', -float(buffer))
    except Exception:
        pass
