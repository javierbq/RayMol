"""Per-scene "extras" snapshot for RayMol (settings + object TTT + autofocus target).

Classic PyMOL scenes store the camera + representations + colors but NOT setting
values, per-object Move-mode transforms, or the depth-of-field autofocus target,
so the render "look", object arrangement, and DOF focus were not captured by
`scene ... store`. This module snapshots three things per scene name and re-applies
them on recall, persisting them in the .pse via registered session save/restore
tasks (see cmd._deferred_init_pymol_internals):

  * render "look" settings (CAPTURE below) — metal_* / lighting / DOF / fog
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
    "metal_msaa", "metal_tonemap", "metal_exposure", "metal_sss_wrap",
    "metal_dof", "metal_dof_focus", "metal_dof_range", "metal_dof_aperture",
    "metal_dof_quality", "metal_dof_autofocus", "metal_temporal_ao",
    "metal_upscale", "depth_cue", "fog", "surface_quality",
    "ambient", "direct", "reflect", "specular", "shininess",
    "ray_opaque_background",
]

# {scene_name: {setting: value}} — persisted into the .pse via session tasks.
_scene_settings = {}

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
            out[s] = _self.get(s)
        except Exception:
            pass   # setting absent in this build — skip
    return out


def _capture_ttt(_self=cmd):
    """Per-object TTT for every current object (None where unmoved)."""
    out = {}
    try:
        objs = _self.get_names('objects') or []
    except Exception:
        objs = []
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
    try:
        live = set(_self.get_names('objects') or [])
    except Exception:
        live = set()
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
        _scene_ttt[name] = _capture_ttt(_self)
        _scene_focus[name] = _capture_focus(_self)
    return name


def apply(name, _self=cmd):
    """Re-apply scene `name`'s captured render settings, per-object TTT, and
    autofocus target."""
    d = _scene_settings.get(name)
    if d:
        for s, v in d.items():
            try:
                _self.set(s, v)
            except Exception:
                pass
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
    for name in list(_scene_ttt.keys()):
        if name not in live:
            _scene_ttt.pop(name, None)
    for name in list(_scene_focus.keys()):
        if name not in live:
            _scene_focus.pop(name, None)


def clear_all(_self=cmd):
    """Forget all snapshots (call after `scene *, clear`)."""
    _scene_settings.clear()
    _scene_ttt.clear()
    _scene_focus.clear()


def rename(old, new, _self=cmd):
    """Re-key snapshots when a scene is renamed (old -> new)."""
    if not old or not new or old == new:
        return
    if old in _scene_settings:
        _scene_settings[new] = _scene_settings.pop(old)
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
    session["raymol_scene_ttt"] = {k: dict(v) for k, v in _scene_ttt.items()}
    session["raymol_scene_focus"] = {k: list(v) for k, v in _scene_focus.items()}
    return 1


def session_restore(session, *, _self=cmd):
    _scene_settings.clear()
    _scene_ttt.clear()
    _scene_focus.clear()
    d = session.get("raymol_scene_settings")
    if isinstance(d, dict):
        _scene_settings.update(d)
    t = session.get("raymol_scene_ttt")
    if isinstance(t, dict):
        _scene_ttt.update({k: dict(v) for k, v in t.items()})
    f = session.get("raymol_scene_focus")
    if isinstance(f, dict):
        _scene_focus.update({k: list(v) for k, v in f.items()})
    return 1
