"""Per-scene "extras" snapshot for RayMol (settings + object TTT + autofocus target).

Classic PyMOL scenes store the camera + representations + colors but NOT setting
values, per-object Move-mode transforms, or the depth-of-field autofocus target,
so the render "look", object arrangement, and DOF focus were not captured by
`scene ... store`. This module snapshots three things per scene name and re-applies
them on recall, persisting them in the .pse via registered session save/restore
tasks (see cmd._deferred_init_pymol_internals):

  * render "look" settings (CAPTURE below) — metal_* / lighting / DOF / fog
  * per-object overrides of the object-scoped ones (OBJECT_CAPTURE below) —
    _scene_object_settings
  * per-object TTT matrices (Move mode) — _scene_ttt
  * the autofocus target selection 'dof_focus' — _scene_focus; a single GLOBAL
    named selection the native scene never stored, so without it every auto-lock
    DOF scene focused on whichever target was locked LAST.

Camera lens / zoom / orthographic / FOV / clip slab are already restored by the
scene's saved view, so they're intentionally NOT captured here (the view owns them).

Driven from `cmd.scene` via the central on_scene_action hook (snapshot on
store/update, apply on recall/prev/next, prune on delete, clear_all on clear,
rename on rename); no per-UI-call-site pairing is needed.
"""
from pymol import cmd

# Render "look" settings a scene captures. All are get/set-able globals.
CAPTURE = [
    "metal_raytrace", "metal_rt_shadows", "metal_shadows", "metal_ssao",
    "metal_rt_samples", "metal_rt_ao_radius", "metal_rt_ao_intensity",
    "metal_rt_shadow_intensity", "metal_rt_scale", "metal_outline", "metal_outline_width",
    "metal_rt_reflect", "metal_rt_reflect_tint", "metal_rt_reflect_rough",
    "metal_rt_reflect_env", "metal_rt_reflect_samples",
    "material_default", "material_env",
    # The per-rep materials are OBJECT-level settings, so they have a global
    # fallback as well as per-object overrides -- exactly like metal_rt_reflect
    # above. Both halves have to be captured: the global is what an object with
    # no override of its own renders with, and what a NEW object created after
    # the recall picks up. OBJECT_CAPTURE below covers the other half.
    "cartoon_material", "surface_material", "stick_material", "sphere_material",
    "transparency_peel",
    "metal_msaa", "metal_tonemap", "metal_exposure", "metal_sss_wrap",
    "metal_dof", "metal_dof_focus", "metal_dof_range", "metal_dof_aperture",
    "metal_dof_quality", "metal_dof_autofocus", "metal_temporal_ao",
    "metal_upscale", "depth_cue", "fog", "surface_quality",
    "ambient", "direct", "reflect", "specular", "shininess",
    "ray_opaque_background",
]

_MATERIAL_ID_SETTINGS = None


def MATERIAL_ID_SETTINGS():
    """Settings in CAPTURE whose value is a material ID.

    `cmd.get` renders those as NAMES, which round-trip only in a build that
    knows the name; the id is what every other part of the format stores,
    including the per-object map below and the setting table in the .pse itself.
    Captured as ints because that is what the rest of the .pse holds: the
    setting table in the same file stores the id, so a scene storing the NAME
    would be the one piece of the session that disagreed with it after a table
    reorder. The id is not portable across a reordered table -- nothing here is
    -- it is merely consistent with everything it sits beside.

    Derived from `setting.material_indices` -- the one list the rest of the code
    resolves material names against -- rather than spelled out here, so a
    material setting added later is captured as an id without touching this
    module. Against a core with no materials this is empty, which degrades to
    capturing those settings the way every other one is captured."""
    global _MATERIAL_ID_SETTINGS
    if _MATERIAL_ID_SETTINGS is not None:
        return _MATERIAL_ID_SETTINGS
    names = set()
    try:
        from pymol import setting
        for n in CAPTURE:
            try:
                if setting._get_index(n) in setting.material_indices:
                    names.add(n)
            except Exception:
                pass
    except Exception:
        # Deliberately NOT memoised. Caching an empty answer -- which is what a
        # failure here produces -- would make every later capture write material
        # NAMES into the .pse and make _setting_differs compare an int against a
        # string, i.e. permanently True, i.e. the full-rebuild regression this
        # module just removed. Better to retry on the next call.
        return frozenset()
    _MATERIAL_ID_SETTINGS = frozenset(names)
    return _MATERIAL_ID_SETTINGS


# {scene_name: {setting: value}} — persisted into the .pse via session tasks.
_scene_settings = {}

# Object-scoped settings a scene also captures PER OBJECT. `cmd.get`/`cmd.set`
# with no object name read and write only the GLOBAL fallback of these, so the
# CAPTURE list above can restore that fallback and nothing else: a scene with
# one reflective object beside a matte one could not be expressed, and an object
# that gained an override AFTER the scene was stored kept it on recall. Captured
# from each object's own table (cmd.get_object_settings — explicitly set entries
# only, so a global value is never baked onto an object) and applied with the
# object argument.
OBJECT_CAPTURE = [
    "metal_rt_reflect", "metal_rt_reflect_tint", "metal_rt_reflect_rough",
    # Materials (#503). Ids, so a scene stores what the object is MADE OF
    # independently of its colour. They step at a scene cut -- there is nothing
    # meaningful to interpolate between two materials -- which is why they are
    # captured here and deliberately absent from raymol_scene_anim.INTERPOLATE.
    "cartoon_material", "surface_material", "stick_material", "sphere_material",
    "transparency_peel",
]

# The OBJECT_CAPTURE names in force when a given scene was STORED. Recall reads
# "name absent from this scene's per-object map" as "the object had no override,
# so unset it" -- which is only sound for names the capture was actually looking
# for. Without this, growing OBJECT_CAPTURE silently re-interprets every scene
# already sitting in a .pse: a scene stored before the materials were captured
# would be read as "this object had no material" and the recall would WIPE one
# the user set afterwards. Persisted per scene; a scene with no record (any .pse
# written before this existed) is read with the list below.
_scene_object_capture = {}

# What OBJECT_CAPTURE was before the materials joined it (#489). Every scene in
# an older .pse was stored with exactly these three.
_LEGACY_OBJECT_CAPTURE = ("metal_rt_reflect", "metal_rt_reflect_tint",
                          "metal_rt_reflect_rough")

# NOTE (#508): a MOVIE built from scenes replays only HALF of this. The animator
# emits camera + global-setting keyframes and per-object TTT (emit_object_motion
# below). Since the four rep materials are in CAPTURE too, the GLOBAL half does
# animate across a scene cut -- but nothing re-applies the per-object overrides,
# so in a marble -> clay movie every object EXCEPT the ones the user deliberately
# styled changes material, and those stay frozen at whatever the last authoring
# recall left on them. Recall itself is unaffected; this is a gap in the movie
# path, tracked separately.

# {scene_name: {obj_name: {setting: value}}} — per-object overrides of
# OBJECT_CAPTURE. Every object alive at store time is a key, with {} when it had
# no override of its own, so recall can UNSET as well as set (the _apply_ttt
# reset pattern). A scene absent from this map — every scene in a .pse written
# before per-object capture existed — leaves each object's own values alone
# instead of unsetting them. Persisted into the .pse alongside the settings.
_scene_object_settings = {}

# Identity TTT (16-float) used when an object has no transform yet / to reset one.
_IDENTITY_TTT = [1.0, 0.0, 0.0, 0.0,
                 0.0, 1.0, 0.0, 0.0,
                 0.0, 0.0, 1.0, 0.0,
                 0.0, 0.0, 0.0, 1.0]

# {scene_name: {obj_name: [16 floats] | None}} — per-object Move-mode TTT.
# None means the object had no TTT (unmoved) when the scene was stored; on recall
# that resets the object to identity. Every object present at store time is a key,
# so recall can reset as well as move. Persisted into the .pse alongside settings.
_scene_ttt = {}

# {scene_name: [(model, index), ...]} — membership of the autofocus target
# selection ('dof_focus'). Auto-lock DOF (metal_dof_autofocus) focuses on this
# selection's centroid each frame; it is a single GLOBAL named selection the
# native scene does not store, so without capturing it every auto-lock scene
# would focus on whichever target was locked LAST. Empty list = no dof_focus at
# store time. Persisted into the .pse alongside the settings + TTT.
_scene_focus = {}

_FOCUS_SEL = 'dof_focus'

# Reentrancy guard: internal temp-scene machinery (.pse legacy convert, multi-scene
# export) increments this so the cmd.scene hook does NOT capture/apply during its
# throwaway store/recall/clear (see viewing.session_restore_scenes / exporting).
_suspend = 0


class _Suspend:
    def __enter__(self):
        global _suspend
        _suspend += 1
        return self

    def __exit__(self, *exc):
        global _suspend
        _suspend = max(0, _suspend - 1)
        return False


def suspended():
    """Context manager: pause the cmd.scene capture/apply hook for internal
    temp-scene operations."""
    return _Suspend()


def _current(_self=cmd):
    try:
        return _self.get("scene_current_name") or ""
    except Exception:
        return ""


def _capture(_self=cmd):
    out = {}
    for s in CAPTURE:
        try:
            out[s] = (_self.get_setting_int(s) if s in MATERIAL_ID_SETTINGS()
                      else _self.get(s))
        except Exception:
            pass   # setting absent in this build — skip
    return out


def _object_capture_indices():
    """{setting index: name} for OBJECT_CAPTURE, skipping names this build does
    not define (the module can be imported against an older core)."""
    from pymol import setting
    out = {}
    for s in OBJECT_CAPTURE:
        try:
            out[setting._get_index(s)] = s
        except Exception:
            pass
    return out


def _material_objects(_self=cmd):
    """Current objects that own settings, WITHOUT groups.

    `get_names('objects')` includes group objects, and `cmd.set`/`cmd.unset`
    expand a group name to its members. Capturing a group would therefore record
    the group's own (always empty) table and then, on recall, `unset` the
    setting on every member -- wiping exactly the per-object overrides this
    module exists to restore, in an order that depends on where the group
    happens to sit in the name list."""
    try:
        objs = _self.get_names('objects') or []
    except Exception:
        return []
    out = []
    for o in objs:
        try:
            if _self.get_type(o) == 'object:group':
                continue
        except Exception:
            pass
        out.append(o)
    return out


def _capture_object_settings(_self=cmd):
    """{obj: {setting: value}} for every current object, read from each object's
    own explicitly-set table. An object with no override of its own gets {},
    which is what tells recall to unset rather than to leave it alone."""
    want = _object_capture_indices()
    out = {}
    if not want:
        return out
    objs = _material_objects(_self)
    for o in objs:
        d = {}
        try:
            entries = _self.get_object_settings(o) or []
        except Exception:
            entries = []
        for e in entries:
            try:
                name = want.get(e[0])   # [index, type, value], SettingAsPyList
            except Exception:
                continue
            if name is not None:
                d[name] = e[2]
        out[o] = d
    return out


def apply_settings(name, _self=cmd):
    """Make scene `name`'s captured GLOBAL settings current, skipping every
    write that would not change anything.

    Public because the movie animator replays the same payload at each scene
    keyframe (raymol_scene_anim.enter_scene). It used to have its own copy of
    this loop; the two then have to be fixed twice, and the second copy was
    missed exactly once -- see below for why that is expensive.

    Only what CHANGES is written. The material settings carry a cRepInvColor
    side effect, so an unconditional re-write rebuilds cartoon, surface, stick
    and sphere geometry on every object even when no material differs. Measured
    on 1aon (58 870 atoms, cartoon + surface): 144 s per no-op recall before
    this, 0.0002 s after."""
    d = _scene_settings.get(name)
    if not d:
        return
    for s, v in d.items():
        try:
            if _setting_differs(s, v, '', _self):
                _self.set(s, v)
        except Exception as exc:
            # A value this build cannot accept -- an unknown material NAME from
            # a .pse written by a build with a different table is the realistic
            # case. Say so rather than dropping it silently: a scene that
            # quietly stops restoring one setting is much harder to diagnose
            # than one that names it once.
            try:
                from pymol import colorprinting
                colorprinting.warning(
                    ' scene: %s could not be restored for scene "%s": %s'
                    % (s, name, exc))
            except Exception:
                pass


def _setting_differs(name, value, obj='', _self=cmd):
    """True when writing `value` would actually change `name`.

    Compared through the same accessor the capture used, so a material captured
    as an id is compared as an id and everything else as the text `cmd.get`
    returns. Unknown or unreadable settings answer True, which degrades to the
    old unconditional write rather than silently skipping one."""
    try:
        if name in MATERIAL_ID_SETTINGS():
            return _self.get_setting_int(name, obj) != value
        return _self.get(name, obj) != value
    except Exception:
        return True


def _object_settings_now(obj, want, _self=cmd):
    """{setting: value} an object has EXPLICITLY set, restricted to `want`
    ({index: name} from _object_capture_indices) -- the same read the capture
    uses, so the two agree on what "the object has this set" means."""
    out = {}
    if not want:
        return out
    for entry in (_self.get_object_settings(obj) or []):
        try:
            nm = want.get(entry[0])
        except Exception:
            continue
        if nm is not None:
            out[nm] = entry[2]
    return out


def _apply_object_settings(name, _self=cmd):
    """Restore per-object overrides for scene `name`; unset the settings an
    object did not have of its own when the scene was stored; skip objects that
    no longer exist. A scene with no recorded map (legacy .pse) is a no-op."""
    d = _scene_object_settings.get(name)
    if not d:
        return
    # Groups are excluded here as well as at capture: a .pse written before this
    # guard existed can still carry a group in its map, and applying it would
    # expand to the members.
    live = set(_material_objects(_self))
    try:
        want = _object_capture_indices()
    except Exception:
        want = {}
    # Only the names this scene was stored with may be unset; see
    # _scene_object_capture.
    captured = _scene_object_capture.get(name) or _LEGACY_OBJECT_CAPTURE
    for o, kv in d.items():
        # Not merely defensive: without this, a scene stored with many objects
        # that were later deleted raises (and swallows) one exception per
        # setting per missing object on every recall.
        if o not in live:
            continue
        try:
            current = _object_settings_now(o, want, _self)
        except Exception:
            current = {}
        for s in captured:
            try:
                if s in kv:
                    # Skip a write that would not change the value: these carry
                    # a rep-rebuild side effect (see apply()).
                    if s not in current or current[s] != kv[s]:
                        _self.set(s, kv[s], o)
                elif s in current:
                    # ...and only unset what the object actually has set.
                    _self.unset(s, o)
            except Exception:
                pass


def _capture_ttt(_self=cmd):
    """Per-object TTT for every current object (None where unmoved).

    Groups are excluded for the same reason as the settings above:
    `set_object_ttt` expands a group name to its members, so capturing a group
    and then resetting it to identity on recall wiped every member's stored
    Move-mode transform."""
    out = {}
    objs = _material_objects(_self)
    for o in objs:
        try:
            out[o] = _self.get_object_ttt(o)   # list[16] or None
        except Exception:
            out[o] = None
    return out


def _apply_ttt(name, _self=cmd):
    """Restore per-object TTT for scene `name`; reset unmoved objects to identity;
    skip objects that no longer exist."""
    d = _scene_ttt.get(name)
    if not d:
        return
    # Groups filtered here too, not only at capture: a .pse written before this
    # guard existed still has them in its map.
    live = set(_material_objects(_self))
    for o, ttt in d.items():
        if o not in live:
            continue
        try:
            _self.set_object_ttt(o, list(ttt) if ttt else list(_IDENTITY_TTT))
        except Exception:
            pass


def _capture_focus(_self=cmd):
    """(model, index) atoms of the 'dof_focus' autofocus target selection ([] if
    the selection is absent/empty)."""
    out = []
    try:
        names = _self.get_names('selections') or []
    except Exception:
        names = []
    if _FOCUS_SEL in names:
        try:
            _self.iterate(_FOCUS_SEL, 'out.append((model, index))',
                          space={'out': out})
        except Exception:
            pass
    return out


def _apply_focus(name, _self=cmd):
    """Re-select 'dof_focus' to scene `name`'s stored atoms (skipping objects that
    no longer exist); an empty capture clears any existing dof_focus so the
    renderer falls back to the center of interest — matching a scene stored with
    no autofocus target. Does nothing for scenes with no captured focus entry."""
    if name not in _scene_focus:
        return
    atoms = _scene_focus.get(name) or []
    try:
        live = set(_self.get_names('objects') or [])
    except Exception:
        live = set()
    groups = {}
    for m, i in atoms:
        if m in live:
            groups.setdefault(m, []).append(int(i))
    try:
        if groups:
            expr = ' or '.join(
                '(%s and index %s)' % (m, '+'.join(str(i) for i in idxs))
                for m, idxs in groups.items())
            _self.select(_FOCUS_SEL, expr, quiet=1)
        elif _FOCUS_SEL in (_self.get_names('selections') or []):
            _self.select(_FOCUS_SEL, 'none', quiet=1)   # clear, don't spuriously create
    except Exception:
        pass


def scene_ttt_map(name):
    """Copy of the per-object TTT captured for scene `name` ({} if none)."""
    return dict(_scene_ttt.get(name, {}))


def scene_settings_map(name):
    """Copy of the render settings captured for scene `name` ({} if none)."""
    return dict(_scene_settings.get(name, {}))


def scene_object_settings_map(name):
    """Copy of the per-object setting overrides captured for scene `name`
    ({} if the scene has none, e.g. a .pse written before this existed)."""
    return {o: dict(kv) for o, kv in _scene_object_settings.get(name, {}).items()}


def scene_focus_map(name):
    """Copy of the autofocus target atoms captured for scene `name` ([] if none)."""
    return list(_scene_focus.get(name, []))


def apply_focus_target(name, _self=cmd):
    """Re-point the 'dof_focus' autofocus selection at scene `name`'s captured
    target. Public wrapper over _apply_focus for the movie animator, which must
    restore the focus target WITHOUT touching object TTT (a movie owns object
    motion through its own keyframes)."""
    _apply_focus(name, _self)


def emit_object_motion(name, frame, _self=cmd):
    """Author per-object Move-mode TTT keyframes for scene `name` at movie `frame`:
    apply each captured object TTT, then store an object-matrix mview keyframe
    (freeze=1 — the caller interpolates per object once at the end). Returns the
    list of objects keyframed. [] if no captured TTT / objects absent."""
    d = _scene_ttt.get(name)
    if not d:
        return []
    try:
        live = set(_self.get_names('objects') or [])
    except Exception:
        live = set()
    done = []
    for o, ttt in d.items():
        if o not in live:
            continue
        try:
            _self.set_object_ttt(o, list(ttt) if ttt else list(_IDENTITY_TTT))
            _self.mview('store', object=o, first=int(frame), freeze=1)
            done.append(o)
        except Exception:
            pass
    return done


def snapshot_current(_self=cmd):
    """Capture the current render settings AND per-object TTT for the current
    scene. Call right after `scene ..., store` / `update`."""
    name = _current(_self)
    if name:
        _scene_settings[name] = _capture(_self)
        _scene_object_settings[name] = _capture_object_settings(_self)
        _scene_object_capture[name] = tuple(OBJECT_CAPTURE)
        _scene_ttt[name] = _capture_ttt(_self)
        _scene_focus[name] = _capture_focus(_self)
    return name


def apply(name, _self=cmd):
    """Re-apply scene `name`'s captured render settings, per-object TTT, and
    autofocus target."""
    apply_settings(name, _self)
    # After the globals: a per-object override has to win over the fallback the
    # same recall just wrote.
    _apply_object_settings(name, _self)
    _apply_ttt(name, _self)
    _apply_focus(name, _self)


def apply_current(_self=cmd):
    """Apply the now-current scene's settings (after prev/next navigation)."""
    apply(_current(_self), _self)


def prune(_self=cmd):
    """Drop snapshots for scenes that no longer exist (call after a delete)."""
    try:
        live = set(_self.get_scene_list() or [])
    except Exception:
        return
    for name in list(_scene_settings.keys()):
        if name not in live:
            _scene_settings.pop(name, None)
    for name in list(_scene_object_settings.keys()):
        if name not in live:
            _scene_object_settings.pop(name, None)
            _scene_object_capture.pop(name, None)
    for name in list(_scene_ttt.keys()):
        if name not in live:
            _scene_ttt.pop(name, None)
    for name in list(_scene_focus.keys()):
        if name not in live:
            _scene_focus.pop(name, None)


def clear_all(_self=cmd):
    """Forget all snapshots (call after `scene *, clear`)."""
    _scene_settings.clear()
    _scene_object_settings.clear()
    _scene_object_capture.clear()
    _scene_ttt.clear()
    _scene_focus.clear()


def rename(old, new, _self=cmd):
    """Re-key snapshots when a scene is renamed (old -> new)."""
    if not old or not new or old == new:
        return
    if old in _scene_settings:
        _scene_settings[new] = _scene_settings.pop(old)
    if old in _scene_object_settings:
        _scene_object_settings[new] = _scene_object_settings.pop(old)
    if old in _scene_object_capture:
        _scene_object_capture[new] = _scene_object_capture.pop(old)
    if old in _scene_ttt:
        _scene_ttt[new] = _scene_ttt.pop(old)
    if old in _scene_focus:
        _scene_focus[new] = _scene_focus.pop(old)


def on_scene_action(key, action, new_key=None, _self=cmd):
    """Central hook called from cmd.scene AFTER the native op completes. `action`
    is already normalized by cmd.scene (update/append -> store, clear -> delete,
    auto-recall -> next). No-op while suspended()."""
    if _suspend:
        return
    if action in ('store', 'insert_after', 'insert_before'):
        snapshot_current(_self)
    elif action in ('recall', 'next', 'previous'):
        apply_current(_self)
    elif action == 'delete':
        if key == '*':
            clear_all(_self)
        else:
            prune(_self)
    elif action == 'rename':
        rename(key, new_key, _self)


# --- .pse persistence (registered in cmd._deferred_init_pymol_internals) ---
def session_save(session, *, _self=cmd):
    session["raymol_scene_settings"] = dict(_scene_settings)
    session["raymol_scene_object_settings"] = {
        k: {o: dict(kv) for o, kv in v.items()}
        for k, v in _scene_object_settings.items()}
    session["raymol_scene_object_capture"] = {
        k: list(v) for k, v in _scene_object_capture.items()}
    session["raymol_scene_ttt"] = {k: dict(v) for k, v in _scene_ttt.items()}
    session["raymol_scene_focus"] = {k: list(v) for k, v in _scene_focus.items()}
    return 1


def _restore_object_settings(session):
    """Read the per-object payload, tolerating everything an older .pse can
    hold. A session written before per-object capture existed has no such key at
    all: it restores as "no per-object data", so recall applies the flat
    (global) payload exactly as that build did and unsets nothing. A payload
    that is not the nested {scene: {object: {setting: value}}} shape is dropped
    for that scene rather than raising."""
    payload = session.get("raymol_scene_object_settings")
    if not isinstance(payload, dict):
        return
    for name, per_obj in payload.items():
        if not isinstance(per_obj, dict):
            continue
        clean = {o: dict(kv) for o, kv in per_obj.items() if isinstance(kv, dict)}
        if len(clean) == len(per_obj):
            _scene_object_settings[name] = clean
    # Which names the capture was LOOKING for when each scene was stored. A .pse
    # without this key predates the materials joining OBJECT_CAPTURE, so its
    # scenes are read with the list that was in force then -- otherwise every one
    # of them would unset materials it never knew about.
    caps = session.get("raymol_scene_object_capture")
    if isinstance(caps, dict):
        for name, names in caps.items():
            if isinstance(names, (list, tuple)):
                _scene_object_capture[name] = tuple(
                    str(n) for n in names if isinstance(n, str))


def session_restore(session, *, _self=cmd):
    _scene_settings.clear()
    _scene_object_settings.clear()
    _scene_object_capture.clear()
    _scene_ttt.clear()
    _scene_focus.clear()
    d = session.get("raymol_scene_settings")
    if isinstance(d, dict):
        _scene_settings.update(d)
    _restore_object_settings(session)
    t = session.get("raymol_scene_ttt")
    if isinstance(t, dict):
        _scene_ttt.update({k: dict(v) for k, v in t.items()})
    f = session.get("raymol_scene_focus")
    if isinstance(f, dict):
        _scene_focus.update({k: list(v) for k, v in f.items()})
    return 1
