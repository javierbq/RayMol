"""Per-scene render-settings snapshot for RayMol.

Classic PyMOL scenes store the camera + representations + colors but NOT setting
values, so the depth-of-field / lighting / metal_* render "look" is not captured
by `scene ... store` (that's why e.g. metal_dof_aperture didn't persist per
scene). This module snapshots those render settings when a scene is stored/updated
and re-applies them on recall, keyed by scene name, and persists them in the .pse
via registered session save/restore tasks (see cmd._deferred_init_pymol_internals).

Camera lens / zoom / orthographic / FOV are already restored by the scene's saved
view, so they're intentionally NOT captured here (the view owns them).

Driven from the RayMol Scenes UI, which pairs each `scene ... <action>` command
with the matching call below (snapshot_current after store/update; apply/
apply_current after recall/prev/next; prune after delete; clear_all after clear).
"""
from pymol import cmd

# Render "look" settings a scene captures. All are get/set-able globals.
CAPTURE = [
    "metal_raytrace", "metal_rt_shadows", "metal_shadows", "metal_ssao",
    "metal_rt_samples", "metal_rt_ao_radius", "metal_rt_ao_intensity",
    "metal_rt_shadow_intensity", "metal_outline", "metal_outline_width",
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


def scene_ttt_map(name):
    """Copy of the per-object TTT captured for scene `name` ({} if none)."""
    return dict(_scene_ttt.get(name, {}))


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
    return name


def apply(name, _self=cmd):
    """Re-apply scene `name`'s captured render settings and per-object TTT."""
    d = _scene_settings.get(name)
    if d:
        for s, v in d.items():
            try:
                _self.set(s, v)
            except Exception:
                pass
    _apply_ttt(name, _self)


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


def clear_all(_self=cmd):
    """Forget all snapshots (call after `scene *, clear`)."""
    _scene_settings.clear()
    _scene_ttt.clear()


def rename(old, new, _self=cmd):
    """Re-key snapshots when a scene is renamed (old -> new)."""
    if not old or not new or old == new:
        return
    if old in _scene_settings:
        _scene_settings[new] = _scene_settings.pop(old)
    if old in _scene_ttt:
        _scene_ttt[new] = _scene_ttt.pop(old)


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
    return 1


def session_restore(session, *, _self=cmd):
    _scene_settings.clear()
    _scene_ttt.clear()
    d = session.get("raymol_scene_settings")
    if isinstance(d, dict):
        _scene_settings.update(d)
    t = session.get("raymol_scene_ttt")
    if isinstance(t, dict):
        _scene_ttt.update({k: dict(v) for k, v in t.items()})
    return 1
