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
    'cartoon':    ['cartoon_material',
                   'cartoon_transparency', 'cartoon_loop_radius',
                   'cartoon_tube_radius', 'cartoon_fancy_helices',
                   'cartoon_flat_sheets', 'cartoon_spline'],
    'surface':    ['surface_material',
                   'transparency', 'surface_quality', 'solvent_radius',
                   'surface_clip_front', 'surface_clip_back', 'metal_interior_cap',
                   'surface_contour', 'surface_contour_width',
                   'surface_contour_opaque'],
    'sticks':     ['stick_material',
                   'stick_transparency', 'stick_radius', 'stick_h_scale', 'metal_interior_cap'],
    'spheres':    ['sphere_material',
                   'sphere_transparency', 'sphere_scale', 'metal_interior_cap'],
    'nb_spheres': ['nb_spheres_size'],
    'mesh':       ['transparency', 'mesh_width'],
    'ribbon':     ['ribbon_transparency', 'ribbon_width'],
    'lines':      ['line_width'],
    'dots':       ['transparency', 'dot_density', 'dot_radius'],
    'nonbonded':  ['nonbonded_size'],
    'labels':     ['label_size'],
}

# The material setting each rep reads, with the cRep_t index the C resolver
# wants (#490). Reported as the RESOLVED id -- object value, else the rep's
# global, else material_default -- because that is what the rep actually renders
# with, and a dropdown showing anything else would disagree with the picture.
# `cmd.get` would answer with the NAME, which _num cannot turn into a number.
MATERIAL_REPS = {
    'cartoon': ('cartoon_material', 'cartoon'),
    'surface': ('surface_material', 'surface'),
    'sticks':  ('stick_material',  'sticks'),
    'spheres': ('sphere_material', 'spheres'),
}


# The Custom material's knobs (#568), in the order MaterialKnobSlot has them.
CUSTOM_KNOBS = ('reflect', 'tint', 'rough', 'knob1', 'knob2', 'knob3',
                'knob4', 'knob5', 'knob6')


def material_names():
    """The materials the Inspector dropdown may offer, as [[id, name], ...] with
    `default` first.

    Only the IMPLEMENTED ones: a material whose shader has not landed yet is a
    real id that can be set by name from the command line and round-trips
    through a .pse, but offering it in a dropdown would promise a look that
    silently renders as `default`. Emitted once at startup rather than on every
    poll -- the table cannot change within a session."""
    try:
        from pymol import setting
        return [[int(i), str(n)] for (i, n) in setting.get_material_names(1)]
    except Exception:
        return []


def material_knobs(mid):
    """Material `mid`'s Custom knobs (#569), [[suffix, label, min, max,
    control], ...]: only the ones its shader reads, so the Custom controls come
    from the core. `control` is 'slider', or 'toggle' for an on/off knob
    (min off, max on; #590)."""
    try:
        from pymol import _cmd
        return [[str(k), str(l), float(lo), float(hi), str(c)]
                for (k, l, lo, hi, c) in _cmd.get_material_knobs(int(mid))]
    except Exception:
        return []


def poll_materials():
    """Print `MATERIALS:<json>` once, for the Inspector's material dropdowns,
    then one `MATKNOBS:<id>:<json>` line per material with knobs.

    Separate lines because PyMOL's feedback splits a line at ~1024 chars
    (OrthoLineLength): the whole table with its knobs is over that, and a split
    line fails to parse -- which left every material menu disabled."""
    import json
    try:
        names = material_names()
        print('MATERIALS:' + json.dumps(names, separators=(',', ':')))
        for mid, _name in names:
            knobs = material_knobs(mid)
            if knobs:
                print('MATKNOBS:%d:%s' % (mid, json.dumps(knobs, separators=(',', ':'))))
        # The layer Looks (looks.py): [[name, label, material], ...]
        try:
            from pymol import looks
            print('LOOKS:' + json.dumps(looks.looks_payload(), separators=(',', ':')))
        except Exception:
            pass
    except Exception:
        print('MATERIALS:[]')


def _material_id(rep_name, obj):
    """Resolved material id for `rep_name` on `obj`, or 0 (default) if this
    build has no materials or the lookup fails."""
    try:
        from pymol import _cmd
        from pymol.constants import repres
        entry = MATERIAL_REPS.get(rep_name)
        if not entry:
            return 0.0
        # state=-1 asks for the OBJECT tier, which is the tier the Inspector's
        # dropdown writes. Asking for the drawn state (0) instead would let a
        # state-level value -- which `cmd.set(..., state=N)` stores even though
        # PyMOL warns the setting is object-level -- outrank every write the
        # dropdown makes, so the row would accept clicks and never change.
        # Every other row in the grid reads and writes the object tier too.
        value = _cmd.get_rep_material(cmd._COb, obj or '', repres[entry[1]], -1)
        return float(value) if value is not None else 0.0
    except Exception:
        return 0.0


def _custom_prefix(rep_name):
    """`cartoon` / `surface` / `stick` / `sphere`: the stem of the rep's Custom
    override settings, `<stem>_material_<knob>` (#568)."""
    entry = MATERIAL_REPS.get(rep_name)
    return entry[0][:-len('_material')] if entry else None


def _custom_state(rep_name, obj, explicit):
    """What the Inspector's Custom controls need for one rep (#569):
    {'drawn': the material id the layer DRAWS with, 'knobs': {suffix: value
    the draw uses}, 'custom': [overridden suffixes that material has],
    'set': [every override the object carries for the layer], 'follows':
    whether the layer draws with the cartoon's material} -- `set` is what a
    pick, Inherit or Reset unsets.

    `drawn` is the draw's own answer, not the setting: a material id this build
    does not implement (from a newer build's session) draws `default` (0),
    which has no knobs, so Custom must not be offered there. `custom` counts
    only the knobs `drawn` has -- an override left over from another material (the core ignores it) must
    not make the row read Custom. `explicit` is the set of setting indices the
    object itself carries (cmd.get_object_settings), so a global value never
    reads as an override; the core does not treat it as one either."""
    try:
        from pymol import _cmd, setting
        from pymol.constants import repres
        prefix = _custom_prefix(rep_name)
        if not prefix:
            return None
        params = _cmd.get_material_draw_params(
            cmd._COb, obj or '', repres[MATERIAL_REPS[rep_name][1]])
        if not params:
            return None
        values = [params[2], params[3], params[4]] + list(params[5])[:6]
        knobs = {k: float(v) for k, v in zip(CUSTOM_KNOBS, values)}
        drawn = int(params[1]) if int(params[0]) != 0 else 0
        has = {row[0] for row in _cmd.get_material_knobs(drawn)}
        custom = [k for k in CUSTOM_KNOBS if k in has and
                  setting._get_index('%s_material_%s' % (prefix, k)) in explicit]
        # every override the object carries for this layer, knob or not: what
        # a pick or Reset has to unset (and nothing else, so it stays quiet)
        explicit_here = [k for k in CUSTOM_KNOBS
                         if setting._get_index('%s_material_%s' % (prefix, k)) in explicit]
        # A stick or sphere layer with no material of its own draws with the
        # cartoon's while one is shown (MaterialSourceRep): its row then says
        # so, and offers no Custom -- the knobs it draws with are the cartoon's.
        rep_index = repres[MATERIAL_REPS[rep_name][1]]
        source = _cmd.get_rep_material(cmd._COb, obj or '', rep_index, -1, 1)
        follows = source is not None and source != rep_index
        return {'drawn': drawn, 'knobs': knobs, 'custom': custom,
                'set': explicit_here, 'follows': follows}
    except Exception:
        return None


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

# Transparency settings that PyMOL actually supports at the ATOM level, i.e. that
# can carry per-atom overrides. ribbon_transparency and stick_transparency are
# object-level only and can never differ per atom, so they are intentionally
# excluded (they would never flag). `transparency` is the surface/mesh/dots one.
REP_TRANSP = {
    'cartoon': 'cartoon_transparency',
    'spheres': 'sphere_transparency',
    'surface': 'transparency',
    'mesh': 'transparency',
    'dots': 'transparency',
}
TRANSP_SETTINGS = ['cartoon_transparency', 'sphere_transparency', 'transparency']

SCENE_SETTINGS = ['metal_raytrace', 'metal_rt_shadows', 'metal_shadows', 'metal_ssao',
                  'metal_rt_samples', 'metal_rt_ao_radius', 'metal_rt_ao_intensity',
                  'metal_rt_shadow_intensity', 'metal_rt_scale',
                  'metal_rt_reflect_env', 'metal_rt_reflect_samples',
                  'metal_rt_transparent',
                  'metal_outline', 'metal_outline_width', 'metal_msaa',
                  'metal_tonemap', 'metal_exposure',
                  'metal_sss_wrap', 'metal_dof', 'metal_dof_focus',
                  'metal_dof_range', 'metal_dof_aperture', 'metal_dof_quality',
                  'metal_dof_autofocus',
                  'metal_temporal_ao', 'metal_upscale',
                  'depth_cue', 'fog', 'field_of_view', 'ortho', 'surface_quality',
                  'grid_mode', 'all_states', 'mouse_selection_mode',
                  'ambient', 'direct', 'reflect', 'specular', 'shininess',
                  # The two scene-wide material rows (#498). `material_default`
                  # is a material ID and `material_env` an enum; both are read
                  # as plain numbers here and named by the Inspector.
                  'material_default', 'material_env',
                  'ray_opaque_background']


#: Settings whose value is a MATERIAL ID. `cmd.get` renders one as a NAME
#: ('marble'), so float() raises and the generic fallback below answers 0 --
#: i.e. `default`. The rep loop already resolves its four through
#: _material_id(); these are the scene-level ones (#498).
MATERIAL_VALUED = ('material_default',)


def _num(setting, obj):
    """cmd.get a setting (object-scoped if obj else global) as a float; bools→0/1."""
    if setting in MATERIAL_VALUED:
        return _material_setting_id(setting, obj)
    try:
        v = cmd.get(setting, obj) if obj else cmd.get(setting)
    except Exception:
        return 0.0
    try:
        return float(v)
    except Exception:
        return 1.0 if v in (True, 'on', '1', 'yes') else 0.0


def _material_setting_id(setting, obj):
    """A material-valued setting as its ID.

    `cmd.get` returns the NAME so that `get`/`set` round-trip for humans, which
    is exactly what breaks a numeric poll: float('marble') raises and the row
    renders as `default` however it is set. get_setting_int returns the stored
    integer."""
    try:
        if obj:
            return float(cmd.get_setting_int(setting, obj))
        return float(cmd.get_setting_int(setting))
    except Exception:
        return 0.0


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


# Object types the C++ selector accepts as an atom selection. A GROUP belongs
# here even though it is not itself a molecule: it resolves to its members'
# atoms, so `iterate`/`count_atoms` on a group name succeed and describe the
# union of the members (issue #256). Measurements, CGOs and maps do not.
SELECTABLE_TYPES = ('object:molecule', 'object:group')


def takes_atom_selection(obj):
    """True when `obj` may be handed to `cmd.iterate` / `cmd.count_atoms`.

    Measurement objects (`dist01`/`ang01`/`dih01`), CGOs and maps may not.
    Handing one to the selector makes it reject the name and write
    `Selector-Error: Invalid selection name "<obj>"` straight to the feedback log.
    A Python-level try/except cannot suppress that: the selector has already
    emitted the line by the time it raises. Since the object panel polls
    ~2x/second, an unguarded probe floods the console for as long as the object
    exists — issue #219.

    Groups were originally caught by this guard too, which silently blanked their
    rep list and per-atom transparency badge even though probing them is both safe
    and meaningful — issue #256.

    A name that no longer EXISTS is the same trap by another route, and the one a
    user actually hits: `cmd.get_type` runs the name through the selector, so it
    emits the Selector-Error line before raising, and the `except` below catches an
    exception that has already been logged. Deleting an inspected object -- or
    `reinitialize`, which deletes everything while the panel still holds the name --
    then floods the console once per poll tick. Check existence FIRST, via
    `get_names`, which does not touch the selector.
    """
    if obj not in cmd.get_names('all'):
        return False
    try:
        return cmd.get_type(obj) in SELECTABLE_TYPES
    except Exception:
        return False


def transp_summary(obj, settings=None):
    """One pass over `obj`'s atoms → {setting: (min, max, over)} for the atom-level
    transparency settings, where min/max are the EFFECTIVE per-atom transparency
    (the atom-level value if set, else the object-level value) and `over` is True
    when that range differs from the object-level value — i.e. per-atom overrides
    make the object-level slider misleading. Settings with no atoms are omitted.

    Reading `s.<setting>` in iterate always resolves to the object-level value when
    no atom-level override exists (it never returns None here), so comparing the
    effective range to the object-level value is what detects a genuine override.

    Objects the selector won't take are rejected up front (see
    takes_atom_selection): they cannot carry per-atom transparency anyway, so
    probing them is both wrong and noisy.

    `settings` narrows the scan to a subset of TRANSP_SETTINGS (default: all).
    Every `s.<setting>` that misses an atom-level override raises and formats an
    AttributeError inside iterate, so a caller that only needs some settings
    should not pay for the others (#271).
    """
    if not takes_atom_selection(obj):
        return {}
    settings = list(TRANSP_SETTINGS if settings is None else settings)
    if not settings:
        return {}
    objlv = {s: _num(s, obj) for s in settings}
    mn = {s: None for s in settings}
    mx = {s: None for s in settings}

    def _visit(vals):
        for i, s in enumerate(settings):
            e = objlv[s] if vals[i] is None else float(vals[i])
            if mn[s] is None or e < mn[s]:
                mn[s] = e
            if mx[s] is None or e > mx[s]:
                mx[s] = e

    # Trailing comma: a single setting must still be a 1-tuple, not a bare value.
    expr = '_visit((%s,))' % ', '.join('s.%s' % s for s in settings)
    try:
        cmd.iterate(obj, expr, space={'_visit': _visit})
    except Exception:
        return {}
    out = {}
    for s in settings:
        if mn[s] is None:
            continue
        over = (round(mn[s], 4) != round(objlv[s], 4)) or (round(mx[s], 4) != round(objlv[s], 4))
        out[s] = (round(mn[s], 4), round(mx[s], 4), over)
    return out


def object_has_atom_transp(obj):
    """True when any ACTIVE rep of `obj` has a per-atom transparency override — the
    signal for the collapsed-row badge. Rep-gated so an override on a hidden rep
    (which the user can't see and the expanded card wouldn't show) doesn't flag.

    The shown reps are probed FIRST (one cheap core call, #398) and the per-atom
    iterate is skipped outright when no transparency-capable rep is shown (the
    answer is then always False), and otherwise narrowed to the settings of the
    reps that are shown (#271).
    """
    if not takes_atom_selection(obj):
        return False
    shown = _shown_reps(obj)
    reps = [r for r in REP_TRANSP if r in shown]
    if not reps:
        return False
    settings = [s for s in TRANSP_SETTINGS
                if s in {REP_TRANSP[r] for r in reps}]
    summ = transp_summary(obj, settings)
    for r in reps:
        entry = summ.get(REP_TRANSP[r])
        if entry and entry[2]:
            return True
    return False


def _shown_reps(o):
    """Set of rep names shown on `o` (e.g. {'cartoon', 'sticks'}).

    One core call (`_cmd.get_atom_reps`: the OR of the atoms' visRep, a
    single selector pass) instead of a count_atoms pass per rep, each over
    every loaded atom (#398). An older core without the call, or an error,
    falls back to the per-rep probe.
    """
    try:
        from pymol import _cmd
        from pymol.constants import repres
        names = {repres[r]: r for r in REPS}
        return {names[i] for i in _cmd.get_atom_reps(cmd._COb, o)
                if i in names}
    except Exception:
        shown = set()
        for r in REPS:
            try:
                if cmd.count_atoms('(%s) & rep %s' % (o, r)) > 0:
                    shown.add(r)
            except Exception:
                pass
        return shown


def _build(objs):
    detail = {}
    # One lookup for the whole tick. takes_atom_selection() also guards, but calling
    # get_names per object would make a hot main-thread poll quadratic.
    try:
        known = set(cmd.get_names('all') or [])
    except Exception:
        known = None
    # Objects the selector accepts, recorded by the rep loop so the objmeta pass
    # below can count atoms without repeating the #219 guard.
    atomic = set()
    for o in objs:
        if known is not None and o not in known:
            # Stale name from the panel: object deleted, or reinitialize ran. Emitting
            # nothing is right -- probing it would log a Selector-Error per tick.
            detail[o] = []
            continue
        reps = []
        # Measurements, CGOs and maps have no reps to describe, and every probe
        # below — transp_summary's iterate and the per-rep count_atoms — would make
        # the selector log an error per poll tick (issue #219). Emit an empty rep
        # list instead of interrogating them. Groups DO describe their members'
        # reps and are deliberately not excluded here (issue #256).
        if not takes_atom_selection(o):
            detail[o] = reps
            continue
        atomic.add(o)
        # Effective per-atom transparency range per setting, computed once per
        # object; attached to the rep whose transparency setting is overridden so
        # the expanded card can show "per-atom: min–max" and a Clear action.
        summ = transp_summary(o)
        try:
            explicit = {e[0] for e in (cmd.get_object_settings(o) or [])}
        except Exception:
            explicit = set()
        shown = _shown_reps(o)
        for r in REPS:
            present = r in shown
            if not present:
                continue
            vals = {}
            for s in REP_SETTINGS.get(r, []):
                entry = MATERIAL_REPS.get(r)
                # A material is an id, not a quantity, and `cmd.get` renders it
                # as a NAME -- _num would read that as 0 and every rep would
                # report `default`.
                vals[s] = (_material_id(r, o) if entry and s == entry[0]
                           else _num(s, o))
            col = _rep_color(o, REP_COLOR[r]) if r in REP_COLOR else 'inherit'
            cols = {s: _rep_color(o, s) for s in REP_EXTRA_COLORS.get(r, [])}
            rep = {'rep': r, 'vis': 1, 'vals': vals, 'color': col, 'colors': cols}
            if r in MATERIAL_REPS:
                cs = _custom_state(r, o, explicit)
                if cs is not None:
                    rep['material'] = cs
            tset = REP_TRANSP.get(r)
            tsumm = summ.get(tset) if tset else None
            if tsumm and tsumm[2]:
                rep['atom_transp'] = {'setting': tset, 'min': tsumm[0], 'max': tsumm[1]}
            reps.append(rep)
        detail[o] = reps
    scene = {s: _num(s, '') for s in SCENE_SETTINGS}
    scene['bg'] = _bg_rgb()
    scene['outline_rgb'] = _color_setting_rgb('metal_outline_color')
    # Camera distance + scene radius drive the Zoom (magnification) control.
    # cam_dist = |get_view()[11]| (camera→center distance); scene_radius = half the
    # diagonal of the whole scene's extent. The Swift Zoom slider forms an apparent
    # magnification M = scene_radius / (cam_dist * tan(fov/2)) that is ~1 at the
    # fitted framing and invariant under the Lens dolly-zoom.
    try:
        import math
        _v = cmd.get_view()
        scene['cam_dist'] = abs(_v[11])
        _mn, _mx = cmd.get_extent('all')
        scene['scene_radius'] = 0.5 * math.sqrt(sum((_mx[i] - _mn[i]) ** 2 for i in range(3)))
    except Exception:
        scene['cam_dist'] = 0.0
        scene['scene_radius'] = 0.0
    # Per-object state metadata for the inspector STATE row: the effective
    # current state (the object's 'state' setting, which resolves to the global
    # frame's state when not pinned) and whether all states are overlaid.
    objmeta = {}
    for o in objs:
        # Same stale-name guard as the rep loop above. This second pass probes
        # count_states/get_title, and count_states runs the name through the
        # SELECTOR -- so a deleted or reinitialized object logs a Selector-Error
        # here once per poll tick even though the rep loop already skipped it.
        if known is not None and o not in known:
            continue
        entry = {'state': int(round(_num('state', o))),
                 'all': int(round(_num('all_states', o)))}
        # Atom count for the Morph sheet's memory estimate (#morph). Only for
        # objects the selector accepts (#219); absent otherwise, and the sheet
        # then leaves the estimate out rather than showing 0.
        if o in atomic:
            try:
                entry['natoms'] = int(cmd.count_atoms('?' + o))
            except Exception:
                pass
        # Object-wide peel row (#498). It lives on the object header rather
        # than in a rep panel because the setting is object-scoped, and only
        # for objects the scene loop can peel.
        kind = _object_kind(o)
        entry['peel_row'] = int(_takes_peel_row(kind))
        if entry['peel_row']:
            entry['peel'] = int(round(_num('transparency_peel', o)))
            entry['peel_resolved'] = _object_peel(o)
        # Per-state titles (e.g. compound names from a multi-record SDF, which
        # PyMOL stores as each state's title). Included only when at least one
        # state carries a non-empty title, so ordinary single structures add
        # nothing to the payload (issue #203).
        try:
            _ns = cmd.count_states(o)
            _titles = [cmd.get_title(o, _s) or '' for _s in range(1, _ns + 1)]
            if any(_titles):
                entry['titles'] = _titles
        except Exception:
            pass
        objmeta[o] = entry
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
    import json
    from pymol import raymol_tmp
    try:
        p = raymol_tmp.channel_path('pymol_objdetail')
        with open(p, 'w') as _f:
            _f.write(json.dumps(_build(objs)))
        print('OBJDETAIL:ready')
    except Exception as e:
        print('OBJDETAIL_ERR:' + str(e))


# Cache backing group_parents(): the cheap shape fingerprint of the last build,
# and the {child: parent} map it produced.
_GROUP_FP = None
_GROUP_PARENTS = {}


def _group_fingerprint(objs, groups):
    """Cheap (~0.1 ms) signature of the object tree's SHAPE.

    Every call here is a name walk with no serialization: `get_object_list`
    resolves a group to its molecular leaves. Any create, delete, rename,
    group/ungroup, or re-parent that involves a molecule changes this tuple.
    """
    return (tuple(objs), tuple(groups),
            tuple((g, tuple(cmd.get_object_list(g) or [])) for g in groups))


def group_parents(objs, groups):
    """{child: parent} for every object that lives inside a group.

    The only COMPLETE source is the session's per-object record — entry[6] is the
    parent name. Nothing cheaper covers the whole tree: `get_object_list` reports a
    group's MOLECULAR leaves only, so a measurement, CGO or map inside a group is
    invisible to it (and to every other selection-based API), and no API at all
    reports group-in-group nesting.

    But `get_session` serializes every object — measured at ~8 ms and ~2.5 MB for a
    single 10k-atom molecule, scaling with atom count — which is far too expensive
    to run at the ~2x/second poll cadence. So it runs only when the cheap
    fingerprint above changes, and the result is cached.

    The residue: a re-parent that does NOT move the fingerprint (moving a
    non-molecular object between groups, or re-nesting a group whose molecular
    leaves are unchanged) is not picked up until the next structural edit. Both are
    rare and self-heal. Replacing this whole function with a C++ accessor over
    SpecRec.group_name would make it exact and free — see #255.
    """
    global _GROUP_FP, _GROUP_PARENTS
    if not groups:
        _GROUP_FP, _GROUP_PARENTS = None, {}
        return {}
    try:
        fp = _group_fingerprint(objs, groups)
    except Exception:
        return dict(_GROUP_PARENTS)
    if fp == _GROUP_FP:
        return dict(_GROUP_PARENTS)
    parents = {}
    try:
        for ent in (cmd.get_session(partial=1).get('names') or []):
            # entry = [name, ..., parent_group_name]; '' means top level.
            if ent and len(ent) > 6 and ent[6]:
                parents[ent[0]] = ent[6]
    except Exception:
        return dict(_GROUP_PARENTS)      # keep the last good map on failure
    _GROUP_FP, _GROUP_PARENTS = fp, parents
    return dict(parents)


def _pending_maps(module='predicting'):
    """(detail_map, record_map) for placeholders still waiting.

    Two maps from ONE pass, so the hover tooltip and the progress card are the
    same computation and cannot disagree.

    The two maps do NOT cover the same names, and that asymmetry is the point:

      details -- ONLY genuinely pending objects. Its sole consumer is `isPending`
                 in ObjectPanel, which greys the enable checkbox and blocks the
                 row's tap-to-toggle. A RETAINED terminal record belongs to a real
                 object that may already carry a landed model (n_models=2, model 1
                 lands, model 2 fails), so listing it here would dim and disable a
                 live structure -- and label it "pending: inference" -- until the
                 user found Dismiss.
      records -- pending AND retained. This is what the progress tray renders, and
                 saying WHY an eleven-minute run produced nothing is the whole
                 reason retention exists.

    `module` names the surface that owns the placeholders -- `predicting` for a
    prediction, `designing` for a generated backbone (#342). One function over two
    surfaces rather than two copies: the asymmetry above is subtle enough that a second
    implementation would get it wrong, and both surfaces publish the same three
    functions precisely so this can be shared.

    Never raises: a failure here would freeze the whole object panel on a stale
    list, because the caller's single `except` writes no file at all.
    """
    try:
        import importlib
        surface = importlib.import_module('pymol.%s' % module)
        pending = list(surface.pending_objects())
        retained = [n for n in surface.recent_objects() if n not in pending]
        if not pending and not retained:
            return {}, {}
        details, records = {}, {}
        for name in pending:
            try:
                info = surface.pending_info(name)
            except Exception:
                info = None
            if info is None:
                details[name] = 'pending'
                continue
            details[name] = info.get('detail') or 'pending'
            records[name] = info
        for name in retained:
            try:
                info = surface.pending_info(name)
            except Exception:
                info = None
            if info is not None:
                records[name] = info
        return details, records
    except Exception:
        return {}, {}


def _alignment_map():
    """name -> {depth, columns, residues, target, chain} for every loaded MSA (#296).

    Never raises, for the same reason _pending_maps() does not: the caller's single
    `except` writes no file at all, so a throw here freezes the panel on a stale list.

    Cheap by construction -- every value was computed once at load time. This must
    never re-read or re-parse an a3m: the poll runs on the MAIN thread every 500 ms
    and is already a measured hot spot (PR #270), and an alignment is megabytes.
    """
    try:
        from pymol.msas import store
        return store.panel_summary()
    except Exception:
        return {}


#: Seconds of granularity for a search row's age. The panel repaints when this payload
#: changes, so sending the raw float would repaint it on every 500 ms tick for the
#: several MINUTES a search runs. A bucket makes the row change 12 times a minute
#: instead of 120, and it costs nothing that is visible: the row shows a coarse age
#: because the server reports no progress fraction, and inventing one would be a
#: plausible-looking lie (see Search.snapshot).
SEARCH_ELAPSED_BUCKET = 5


#: How many failed MSA searches the poll reports, newest kept. Enough to cover every
#: chain of one Predict run; bounded so a long session does not grow every tick.
MSA_FAILURES_REPORTED = 8


def _failure_map():
    """Recently failed MSA searches, oldest first: [{'id', 'name', 'error'}] (#598).

    The Predict bar starts searches and waits for their alignments. A search that fails
    simply drops out of msa_searches, and on its own that looks like one about to land,
    so without this the bar waited forever. Carried by id so the bar can ignore failures
    that predate its own run, and with the server's reason so it can say what went
    wrong. A cancelled search counts: its alignment is not coming either.

    Never raises, for the same reason _search_map() does not.
    """
    try:
        from pymol.msas import searching
        rows = []
        for search in searching.all_searches():
            snapshot = search.snapshot()
            if snapshot['state'] not in ('error', 'cancelled'):
                continue
            error = str(snapshot.get('error') or 'the search did not complete').strip()
            if error.startswith('Error:'):
                error = error[len('Error:'):].strip()
            rows.append({'id': snapshot['id'], 'name': snapshot['name'], 'error': error})
        return rows[-MSA_FAILURES_REPORTED:]
    except Exception:
        return []


def _search_map():
    """In-flight MSA searches (#298), oldest first, for the panel's progress rows.

    An alignment takes MINUTES to build and does not exist until it lands, so without
    this the object panel shows nothing at all while one is being searched for -- and
    the ALIGNMENTS section hides itself when empty, so a user's first search gives no
    sign anything is happening. `searching.active()` was written for this ("Drives the
    app's progress row") and had no consumer until now.

    Never raises, for the same reason _pending_maps() and _alignment_map() do not: the
    caller's single `except` writes no file at all, so a throw here freezes the panel
    on a stale list.

    Cheap by construction, and O(searches) rather than O(objects): `active()` is
    normally EMPTY, and a snapshot is a handful of scalars copied under a short lock.
    Nothing here reads the network or touches an a3m.
    """
    try:
        from pymol.msas import searching
        rows = []
        for search in searching.active():
            snapshot = search.snapshot()
            elapsed = snapshot.get('elapsed') or 0
            rows.append({
                'id': snapshot['id'],
                'name': snapshot['name'],
                'phase': snapshot['phase'],
                'server': snapshot['server'],
                'elapsed': int(elapsed // SEARCH_ELAPSED_BUCKET
                               * SEARCH_ELAPSED_BUCKET),
            })
        return rows
    except Exception:
        return []


def _object_kind(obj):
    """`cmd.get_type` without the selector. Empty string when it cannot say.

    Safe to call per poll tick: ExecutiveGetType goes through ExecutiveFindSpec,
    a lexicon lookup that never touches the selector and so never writes to the
    feedback log -- unlike count_atoms/iterate, which is what takes_atom_selection
    exists to guard (issue #219)."""
    try:
        return cmd.get_type(obj) or ''
    except Exception:
        return ''


#: Object kinds the peel row does NOT apply to, by cmd.get_type's vocabulary
#: (ExecutiveGetType). Everything else object:* does.
#:
#: `object:group` -- `set` on a group name expands to its members but `get`
#: reports the group's own value, so a control there writes correctly and then
#: reverts on the next poll. That asymmetry predates this ticket; what is new
#: is putting a control on it.
#:
#: `object:ramp` -- a GADGET. SceneObjectAdd files cObjectGadget into
#: `GadgetObjs` and the peel walk iterates `NonGadgetObjs`, so no value of
#: transparency_peel on a ramp ever reaches a render decision. This is the one
#: the previous version of this predicate got wrong while its own docstring
#: said "walks NonGadgetObjs": the word was in the comment and the exclusion
#: was not in the code.
_NO_PEEL_ROW_KINDS = ('object:group', 'object:ramp')

#: Every string ExecutiveGetType can return for an OBJECT, in its own order
#: (layer3/Executive.cpp). Here so a test can enumerate the gates over the
#: whole vocabulary instead of over a hand-picked subset -- the previous test
#: listed six of these twelve and omitted `object:ramp`, which is the one that
#: was wrong, so the suite was green with the defect in it. A hand-kept copy:
#: inspector_materials.py reads the C switch and fails when the two diverge.
OBJECT_KINDS = ('object:molecule', 'object:map', 'object:mesh', 'object:slice',
                'object:surface', 'object:measurement', 'object:cgo',
                'object:group', 'object:volume', 'object:alignment',
                'object:ramp', 'object:')


def _takes_peel_row(kind):
    """True for the objects `transparency_peel` actually applies to.

    NOT just molecules. SceneCollectPeelObjects walks `NonGadgetObjs`, and
    MaterialObjectWantsPeel returns an explicit object-level value outright
    before it ever looks for an ObjectMolecule -- so an isosurface at
    `transparency_peel 1` really is peeled, and a translucent isosurface's
    front/back double blend is exactly what peel is for. An earlier version of
    this gated peel on `object:molecule` and hid the control from the class
    that most needs it.

    See _NO_PEEL_ROW_KINDS for the two exclusions and why each is there."""
    return bool(kind) and kind not in _NO_PEEL_ROW_KINDS


def _object_peel(obj):
    """The RESOLVED peel answer for `obj` (#488), not the raw tri-state.

    The point of `transparency_peel` -1 is that it is AUTO, so the setting says
    nothing about what the renderer will do -- the answer comes from the
    materials the object's representations resolve to. The header toggle shows
    the resolved value beside the tri-state so "Auto" is legible rather than
    mysterious.

    Note this is the object's REQUEST: the scene loop additionally requires the
    object to be enabled, the renderer to support peeling, and a place within
    kMaxPeeledObjects. See CmdGetObjectPeel."""
    try:
        from pymol import _cmd
        return int(_cmd.get_object_peel(cmd._COb, obj or ''))
    except Exception:
        return 0


#: The morph frame costs' cache (the payload's morph_bytes_per_frame and
#: morph_atoms_per_frame), {name: (signature, (atoms, bytes), monotonic time)}.
_BYTES_PER_FRAME = {}
#: Seconds a cached figure is trusted while its signature holds.
_BYTES_PER_FRAME_TTL = 2.0
#: Seconds of one poll that figures past their TTL may be refreshed in.
_BYTES_PER_FRAME_REFRESH_S = 0.002


def _morph_frame_costs(objs, nstate):
    """{name: morph_jobs.frame_cost(name)} for the multi-state molecules: the
    atoms one morph frame holds (state 1: one model's atoms, also for a
    discrete object) and its bytes (bytes_per_frame), from one pass.

    Only those: nothing else can be morphed, and counting atoms of a CGO or a
    map would log a Selector-Error per tick (#219); the app also reads the
    keys as the morphable molecules (MorphSettings.morphTarget, the Morph…
    button), so keep them exactly these. Nor the morphs being
    built: their state count grows on every poll, so their figure would be
    computed on every poll, and it is never used. A figure takes a few
    selector passes over every loaded atom (about 8 ms for a 100k-atom
    object), so it is cached per object and computed again when the object's
    signature changes (its state count, or its entry in cmd.get_vis(), which
    is free to read) or once it is _BYTES_PER_FRAME_TTL old: a rep shown on
    more atoms, an alter of ss or a removal of atoms leaves the signature
    alone. Figures past their TTL are refreshed, oldest first, while this
    poll has spent less than _BYTES_PER_FRAME_REFRESH_S on such refreshes,
    and at least one per poll, so such a change reaches the figure within the
    TTL plus one poll per refresh that did not fit (one 100k-atom object per
    poll; small ones together). One object at a time: a failing one costs
    only its own entry."""
    import time
    from pymol import morph_jobs
    try:
        vis = cmd.get_vis() or {}
    except Exception:
        vis = {}
    try:
        building = set(morph_jobs.pending_objects())
    except Exception:
        building = set()
    now = time.monotonic()
    out = {}
    refreshes = 0
    spent = 0.0
    # Oldest figure first, so every expired one gets its turn: in object-list
    # order the first few re-expire in time to take every poll's refresh, and
    # a later object's figure never refreshed.
    for o in sorted(objs, key=lambda n: _BYTES_PER_FRAME.get(
            n, (None, None, float('-inf')))[2]):
        if (nstate.get(o, 0) <= 1 or o in building
                or _object_kind(o) != 'object:molecule'):
            continue
        sig = (nstate[o], repr(vis.get(o)))
        hit = _BYTES_PER_FRAME.get(o)
        refresh = False
        if hit is not None and hit[0] == sig:
            if (now - hit[2] < _BYTES_PER_FRAME_TTL
                    or (refreshes and spent >= _BYTES_PER_FRAME_REFRESH_S)):
                out[o] = hit[1]
                continue
            refresh = True
        t0 = time.perf_counter()
        try:
            atoms, nbytes = morph_jobs.frame_cost(o)
            value = (int(atoms), int(nbytes))
        except Exception:
            _BYTES_PER_FRAME.pop(o, None)
            continue
        finally:
            if refresh:
                refreshes += 1
                spent += time.perf_counter() - t0
        _BYTES_PER_FRAME[o] = (sig, value, now)
        out[o] = value
    for o in [n for n in _BYTES_PER_FRAME if n not in out]:
        del _BYTES_PER_FRAME[o]
    return out


def poll_panel():
    """Write the object-list JSON to a temp file and print a short marker.

    Same rationale as poll(), for the object side-panel's list (#231). The payload
    grows ~62 bytes per object (name + per-object nstate/has_transp), so printing
    it inline as `OBJPANEL:<json>` overflowed PyMOL's ~1KB feedback-line cap at
    ~16 objects — e.g. after `split_states` on a 20-model NMR ensemble. The core
    then split the line: the truncated first fragment still carried the OBJPANEL:
    prefix but failed JSON decode (so the panel froze on the stale list), and the
    prefix-less continuation leaked into the console on every poll tick. Keep the
    payload off the feedback line entirely and emit only `OBJPANEL:ready`."""
    import json
    from pymol import raymol_tmp
    # Structure prediction's main-thread pump (#284). A prediction whose weights are
    # still downloading is submitted from HERE, because the download runs on a thread
    # that must not touch the session. Done before the object list is gathered, so a
    # placeholder created by the pump shows up in this same tick rather than the next.
    # Its own try: a failure must not cost the panel its update.
    try:
        from pymol import predicting
        predicting.pump()
    except Exception:
        pass
    # The MSA search's pump (#298), for exactly the same reason: the search runs on a
    # thread that may not touch the store the panel reads two lines below, so the
    # finished alignment is put there HERE. Its own try, and before the list is
    # gathered, so an alignment that lands shows up on this tick rather than the next.
    try:
        from pymol import msa as _msa
        _msa.pump()
    except Exception:
        pass
    # Backbone generation's pump (#342), for exactly the reason prediction's is here: a
    # design whose weights are still downloading is submitted from the main thread, and the
    # download runs on a thread that must not touch the session. Its own try, and before
    # the object list is gathered, so a placeholder the pump creates appears on this tick.
    try:
        from pymol import designing as _designing
        _designing.pump()
    except Exception:
        pass
    # Morph job pump, for exactly the same reason the design pump is here: a leg
    # whose heavy computation finished on a worker thread lands on the session HERE,
    # on the main thread. Its own try, and before the object list is gathered, so a
    # morph leg that lands this tick appears in the object list on the same tick.
    try:
        from pymol import morph_jobs as _mj
        _mj.pump()
    except Exception:
        pass
    try:
        objs = list(cmd.get_names('public_objects') or [])
        sels = list(cmd.get_names('public_selections') or [])
        enabled = set(cmd.get_names('public_objects', enabled_only=1) or [])
        enabled |= set(cmd.get_names('public_selections', enabled_only=1) or [])
        # Objects that actually draw: enabled_only=1 checks only the object's own
        # flag, so a member of a disabled group would still pass it. Gates the
        # badge scan (#271) only; `enabled` keeps driving the panel toggle.
        try:
            in_scene = set(cmd.get_names('public_objects', enabled_only=2) or [])
        except Exception:
            in_scene = set(enabled)
        # Group tree (#255). Kept in its own try so a failure here degrades to a
        # flat list rather than aborting the whole poll — the single except below
        # writes NO file, and Swift only routes lines prefixed 'OBJPANEL:', so an
        # OBJPANEL_ERR would silently freeze the panel on its stale list.
        try:
            groups = list(cmd.get_names('public_group_objects') or [])
            parents = group_parents(objs, groups)
        except Exception:
            groups, parents = [], {}
        # Structure prediction (#224, #291): objects that are empty placeholders
        # waiting on a running job. `pending` is the hover tooltip (a plain string
        # map -- Swift decodes it as [String: String] and widening it would fail
        # the whole payload decode), and it carries ONLY still-running jobs because
        # its consumer disables the object's enable-toggle. `pending_jobs` is the
        # structured record the progress tray renders, and it additionally carries
        # RETAINED terminal records so a failed run can say why it produced nothing.
        #
        # Cheap by construction: normally empty, and only pending names read a
        # status file -- one read per pending OBJECT, never per model. This poll
        # runs on the MAIN thread every 500 ms and was already a measured hot spot
        # (PR #270), so it must stay O(pending), never O(objects).
        pending_details, pending_records = _pending_maps()
        # Backbone designs (#342), through the same one pass. A design's record has the
        # SAME shape as a prediction's -- designing.pending_info publishes the same keys,
        # deliberately, so one Swift decoder serves both -- but it is a separate key
        # because the two are separate job tables with separate cancel commands, and a
        # merged map would send a design's object name to predict_cancel.
        #
        # Same cost discipline: normally empty, O(pending) and never O(objects).
        design_details, design_records = _pending_maps('designing')
        # Morph jobs, through the same one pass. A morph's record has the SAME shape
        # as a prediction's and a design's (pending_info publishes the same keys,
        # deliberately), but it is a SEPARATE key rather than merged into `pending`:
        # a running morph is a real object whose enable-toggle must stay active -- the
        # user may want to hide it while it builds -- so its name must NOT enter
        # `pending`, which greys and disables the row.
        #
        # Same cost discipline: normally empty, O(pending) and never O(objects).
        # Its own try: a failure must NOT cost the panel its update (the outer except
        # only prints OBJPANEL_ERR and writes no file, which would freeze the panel).
        try:
            _morph_details, morph_records = _pending_maps('morph_jobs')
        except Exception:
            morph_records = {}
        payload = {
            'objects': objs,
            'selections': sels,
            'enabled': list(enabled),
            'sel_counts': {s: cmd.count_atoms(s) for s in sels},
            'nstate': {o: cmd.count_states('?' + o) for o in objs},
            # A disabled object draws nothing, so its badge is skipped (False) rather
            # than paying a per-atom scan per tick for hidden objects (#271).
            'has_transp': {o: (o in in_scene and object_has_atom_transp(o))
                           for o in objs},
            'groups': groups,
            'parent': parents,
            'pending': dict(pending_details, **design_details),
            'pending_jobs': pending_records,
            # OPTIONAL at the far end, like every field added to PanelPayload: one
            # non-optional fails the single `guard let` decode and freezes the panel on its
            # last list. Merged into `pending` above rather than kept separate, because
            # that map's only consumer greys an object's enable-toggle -- and a design
            # placeholder needs greying for the same reason a prediction's does.
            'design_jobs': design_records,
            # Morph progress tray. OPTIONAL on the Swift side, like design_jobs.
            # NOT merged into `pending` -- a morph object's enable-toggle must stay active
            # while the job runs (the user may hide it), so the name must never enter the
            # map that greys and disables the row.
            'morph_jobs': morph_records,
            # Alignments (#296). Not objects -- they have no geometry and nothing in
            # the Executive knows about them -- so the panel draws them as their own
            # section rather than as rows in the object list.
            'alignments': _alignment_map(),
            # Searches still running (#298). Gathered AFTER the pump above, so a search
            # that just finished has already become an alignment and is counted once,
            # in the section below it -- never as both a progress row and a result on
            # the same tick.
            'msa_searches': _search_map(),
            'msa_failures': _failure_map(),
        }
        # Completed morphs with their source, spec and build number. OPTIONAL on the
        # Swift side, like design_jobs and morph_jobs. Its own try: a failure must not
        # cost the panel its update. Gathered after the payload dict so a morph that
        # completes this tick (via the pump above) appears in both morph_jobs (empty,
        # done) and morph (source + spec) on the same tick rather than one tick apart.
        # A small morph can start and finish inside that one pump, so no poll lists
        # it in morph_jobs: the app reports a completion when a build number it has
        # not seen appears here.
        try:
            from pymol import morph_jobs as _mj_src
            payload['morph'] = _mj_src.morph_sources()
        except Exception:
            payload['morph'] = {}
        # Bytes one morph frame of each multi-state molecule would hold
        # (morph_jobs.bytes_per_frame: coordinates plus the reps it shows). The
        # Morph sheet and the Play-models sheet multiply it by their frame count,
        # so their estimate is morph_object's own. Beside it, from the same pass,
        # the atoms one frame holds (morph_estimate's `atoms`, state 1): the Morph
        # sheet's build-time hint, which the object's own atom count overstates
        # for a discrete object (that counts every state's atoms). Both OPTIONAL
        # on the Swift side. Their own try: a failure must not cost the panel its
        # update.
        try:
            costs = _morph_frame_costs(objs, payload['nstate'])
        except Exception:
            costs = {}
        payload['morph_bytes_per_frame'] = {o: c[1] for o, c in costs.items()}
        payload['morph_atoms_per_frame'] = {o: c[0] for o, c in costs.items()}
        # Design-mode selection fingerprint. Computed inside raymol_design and
        # GATED there on Design mode being active, so this main-thread 500 ms poll
        # pays a single boolean check whenever Design mode is off (PR #270 made
        # this tick's cost a standing constraint). Its own try: a failure here must
        # not cost the panel its update.
        try:
            from pymol import raymol_design as _rd
            payload['design_sele'] = _rd.sele_digest()
        except Exception:
            payload['design_sele'] = ''
        # Serialise BEFORE opening the file. open(..., 'w') truncates immediately, so
        # doing the dumps inside the `with` leaves a ZERO-BYTE file behind when a value
        # turns out not to be JSON-serialisable -- worse than a stale one, and it takes
        # every other reader of this path down with the panel.
        blob = json.dumps(payload)
        # Multiple RayMol windows may run as separate processes. A process-local
        # filename prevents an empty instance from replacing another instance's
        # populated object list and briefly showing the empty-state overlay over
        # a rendered molecule.
        p = raymol_tmp.channel_path('pymol_objpanel')
        with open(p, 'w') as _f:
            _f.write(blob)
        print('OBJPANEL:ready')
    except Exception as e:
        print('OBJPANEL_ERR:' + str(e))


def widen_clip_for_surface(buffer=12.0):
    """When a probe-extended rep (surface / mesh / dots) is shown, widen the
    clipping slab so the rep's ~solvent_radius shell (~3 A beyond the atoms) isn't
    front-clipped by the atom-fit slab that orient/reset/load set (which would
    slice the surface front and expose the interior).

    Use `clip atoms, buffer, visible`: it sets the near/far planes from the
    visible atoms' extent about their CURRENT camera positions plus `buffer`,
    touching only the clip planes -- never the camera position, rotation, or
    center of rotation. That preserves the user's current view (previously a
    `zoom visible` here recentered/rezoomed the camera every time dots/surface
    was shown -- issue #195). It is absolute (recomputed from atom extents each
    call), so repeated calls don't accumulate. No-op when no such rep is shown."""
    try:
        if (cmd.count_atoms('rep surface') + cmd.count_atoms('rep mesh')
                + cmd.count_atoms('rep dots')) > 0:
            # Widen the slab to enclose the visible atoms +/- buffer WITHOUT
            # moving the camera: clip atoms only calls SceneClipSet(front, back).
            cmd.clip('atoms', float(buffer), 'visible')
    except Exception:
        pass
