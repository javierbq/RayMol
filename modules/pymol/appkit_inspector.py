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
                  'metal_rt_shadow_intensity',
                  'metal_outline', 'metal_outline_width', 'metal_msaa',
                  'metal_tonemap', 'metal_exposure',
                  'metal_sss_wrap', 'metal_dof', 'metal_dof_focus',
                  'metal_dof_range', 'metal_dof_aperture', 'metal_dof_quality',
                  'metal_dof_autofocus',
                  'metal_temporal_ao', 'metal_upscale',
                  'depth_cue', 'fog', 'field_of_view', 'ortho', 'surface_quality',
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


def transp_summary(obj):
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
    """
    if not takes_atom_selection(obj):
        return {}
    objlv = {s: _num(s, obj) for s in TRANSP_SETTINGS}
    mn = {s: None for s in TRANSP_SETTINGS}
    mx = {s: None for s in TRANSP_SETTINGS}

    def _visit(vals):
        for i, s in enumerate(TRANSP_SETTINGS):
            e = objlv[s] if vals[i] is None else float(vals[i])
            if mn[s] is None or e < mn[s]:
                mn[s] = e
            if mx[s] is None or e > mx[s]:
                mx[s] = e

    expr = '_visit((%s))' % ', '.join('s.%s' % s for s in TRANSP_SETTINGS)
    try:
        cmd.iterate(obj, expr, space={'_visit': _visit})
    except Exception:
        return {}
    out = {}
    for s in TRANSP_SETTINGS:
        if mn[s] is None:
            continue
        over = (round(mn[s], 4) != round(objlv[s], 4)) or (round(mx[s], 4) != round(objlv[s], 4))
        out[s] = (round(mn[s], 4), round(mx[s], 4), over)
    return out


def object_has_atom_transp(obj):
    """True when any ACTIVE rep of `obj` has a per-atom transparency override — the
    signal for the collapsed-row badge. Rep-gated so an override on a hidden rep
    (which the user can't see and the expanded card wouldn't show) doesn't flag.
    The count_atoms probe runs only when an override exists (cheap short-circuit).
    """
    summ = transp_summary(obj)
    for rep, setting in REP_TRANSP.items():
        entry = summ.get(setting)
        if entry and entry[2]:
            try:
                if cmd.count_atoms('(%s) & rep %s' % (obj, rep)) > 0:
                    return True
            except Exception:
                pass
    return False


def _build(objs):
    detail = {}
    # One lookup for the whole tick. takes_atom_selection() also guards, but calling
    # get_names per object would make a hot main-thread poll quadratic.
    try:
        known = set(cmd.get_names('all') or [])
    except Exception:
        known = None
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
        # Effective per-atom transparency range per setting, computed once per
        # object; attached to the rep whose transparency setting is overridden so
        # the expanded card can show "per-atom: min–max" and a Clear action.
        summ = transp_summary(o)
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
            rep = {'rep': r, 'vis': 1, 'vals': vals, 'color': col, 'colors': cols}
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
    import json, os, tempfile
    try:
        p = os.path.join(tempfile.gettempdir(),
                         'pymol_objdetail_%d.json' % os.getpid())
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


def _pending_map():
    """name -> hover detail for prediction placeholders still waiting on a job.

    Never raises: a failure here would freeze the whole object panel on a stale list,
    because the caller's single `except` writes no file at all.
    """
    try:
        from pymol import predicting
        names = predicting.pending_objects()
        if not names:
            return {}
        out = {}
        for name in names:
            try:
                out[name] = predicting.pending_detail(name) or 'pending'
            except Exception:
                out[name] = 'pending'
        return out
    except Exception:
        return {}


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
    import json, os, tempfile
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
    try:
        objs = list(cmd.get_names('public_objects') or [])
        sels = list(cmd.get_names('public_selections') or [])
        enabled = set(cmd.get_names('public_objects', enabled_only=1) or [])
        enabled |= set(cmd.get_names('public_selections', enabled_only=1) or [])
        # Group tree (#255). Kept in its own try so a failure here degrades to a
        # flat list rather than aborting the whole poll — the single except below
        # writes NO file, and Swift only routes lines prefixed 'OBJPANEL:', so an
        # OBJPANEL_ERR would silently freeze the panel on its stale list.
        try:
            groups = list(cmd.get_names('public_group_objects') or [])
            parents = group_parents(objs, groups)
        except Exception:
            groups, parents = [], {}
        payload = {
            'objects': objs,
            'selections': sels,
            'enabled': list(enabled),
            'sel_counts': {s: cmd.count_atoms(s) for s in sels},
            'nstate': {o: cmd.count_states('?' + o) for o in objs},
            'has_transp': {o: object_has_atom_transp(o) for o in objs},
            'groups': groups,
            'parent': parents,
            # Structure prediction (#224): objects that are empty placeholders waiting on
            # a running job. The panel disables their enable-toggle (there is nothing to
            # show) and puts the detail string in a hover tooltip.
            #
            # Cheap by construction: `pending` is normally empty, and only pending names
            # read a status file. This poll runs on the MAIN thread every 500 ms and was
            # already a measured hot spot (PR #270), so it must stay O(pending), never
            # O(objects).
            'pending': _pending_map(),
        }
        # Multiple RayMol windows may run as separate processes. A process-local
        # filename prevents an empty instance from replacing another instance's
        # populated object list and briefly showing the empty-state overlay over
        # a rendered molecule.
        p = os.path.join(tempfile.gettempdir(),
                         'pymol_objpanel_%d.json' % os.getpid())
        with open(p, 'w') as _f:
            _f.write(json.dumps(payload))
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
