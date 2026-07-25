"""Animate per-scene render settings across a scene movie.

Movie playback recalls scenes entirely in C++ (Movie.cpp MovieDoFrameCommand ->
MovieSceneRecall) and never fires the Python cmd.scene hook, so the per-scene
render settings raymol_scenes captures are NOT applied while a movie plays — the
movie keeps whatever was last set interactively (reported as "the DOF setting is
stuck on the last active value"). ViewElem has no channel for global settings, so
the only vehicle is a per-frame movie command.

This module reads raymol_scenes' captures and authors those commands with
cmd.mappend: continuous settings are interpolated across each transition using
the SAME easing curve the camera uses (View.cpp ViewElemInterpolate), discrete
ones step at the scene cut via enter_scene(), and differing depth-of-field
autofocus targets produce a true focus pull.

The authored track is persisted as STRUCTURED DATA and the command strings are
regenerated locally on restore — never persisted or replayed as text. Frame
commands in a .pse trip MovieSetLock, which disables the entire per-frame path
(commands, scene recall AND the camera track), so this module also blanks its own
commands out of the saved session.
"""
import base64

from pymol import cmd

# Continuous settings worth interpolating across a transition. Everything else in
# raymol_scenes.CAPTURE steps at the scene cut: booleans/ints, plus quality knobs
# (surface_quality, metal_dof_quality, metal_msaa, metal_upscale,
# metal_rt_samples) which would force a rebuild hitch every frame.
INTERPOLATE = frozenset([
    "metal_dof_focus", "metal_dof_range", "metal_dof_aperture",
    "metal_exposure", "metal_sss_wrap", "metal_outline_width",
    "metal_rt_ao_radius", "metal_rt_ao_intensity", "metal_rt_shadow_intensity",
    "ambient", "direct", "reflect", "specular", "shininess", "fog",
])

# Values at/below the renderer's sentinel are reinterpreted as 14 (MAXIMUM blur)
# — RendererMetal.mm:2528,2532 — so an interpolated fade must never reach them.
_FLOOR = {"metal_dof_aperture": 0.02, "metal_dof_range": 0.02}

# View.cpp resolves an unspecified mview power to this.
_DEFAULT_POWER = 1.4


def _as_float(v):
    """cmd.get() hands back strings ('0.80000'); booleans come back 'on'/'off'
    and correctly fail here (they are stepped, never interpolated)."""
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def _truthy(v):
    if v is None:
        return False
    if isinstance(v, str):
        return v.strip().lower() in ("on", "1", "true", "yes")
    return bool(v)


def ease(t, power=_DEFAULT_POWER):
    """Normalized transition position -> eased position, mirroring
    ViewElemInterpolate (View.cpp:1165-1177, bias=1, parabolic) so animated
    settings track the camera instead of desyncing (~24% off at t=0.25)."""
    if t <= 0.0:
        return 0.0
    if t >= 1.0:
        return 1.0
    if power == 1.0:
        return t
    if t < 0.5:
        return (t * 2.0) ** power * 0.5
    if t > 0.5:
        return 1.0 - (((1.0 - t) * 2.0) ** power * 0.5)
    return 0.5


def effective_power(power):
    """mview power=0 means 'use the default'; View.cpp's default is 1.4. Swift
    encodes Linear as power=1.0 and Smooth as power=0.0."""
    p = _as_float(power)
    if p is None or p == 0.0:
        return _DEFAULT_POWER
    return p


def interpolatable(setting, a, b):
    """True if `setting` should ramp between numeric endpoints a and b."""
    if setting not in INTERPOLATE:
        return False
    if a is None or b is None:
        return False
    # 0 means "auto (center of interest)" for focus (SceneRender.cpp:2061);
    # ramping through it would sweep to a meaningless plane, so step instead.
    if setting == "metal_dof_focus" and (a == 0.0 or b == 0.0):
        return False
    return True


def value_at(setting, a, b, e):
    """Interpolated value at eased position `e`, clamped off the sentinel floor."""
    v = a + (b - a) * e
    floor = _FLOOR.get(setting)
    if floor is not None and v < floor:
        v = floor
    return v


def build_track(keyframes):
    """Per-frame interpolated values for the INTERIOR frames of each transition.

    `keyframes` is an ordered iterable of (frame, scene_name, power) where power
    is the easing of the transition INTO that keyframe (as passed to mview).
    Returns {frame: {setting: float}}. Scene keyframes themselves are applied by
    enter_scene (exact captured values), so they are deliberately absent here."""
    from pymol import raymol_scenes as _rs
    track = {}
    kfs = sorted(keyframes, key=lambda k: int(k[0]))
    for (f0, n0, _p0), (f1, n1, p1) in zip(kfs, kfs[1:]):
        f0, f1 = int(f0), int(f1)
        span = f1 - f0
        if span < 2:
            continue                      # no interior frames
        a = _rs.scene_settings_map(n0)
        b = _rs.scene_settings_map(n1)
        pairs = {}
        for s, bv in b.items():
            fa, fb = _as_float(a.get(s)), _as_float(bv)
            if fa is None or fb is None or fa == fb:
                continue                  # missing, non-numeric, or unchanged
            if not interpolatable(s, fa, fb):
                continue
            pairs[s] = (fa, fb)
        if not pairs:
            continue
        power = effective_power(p1)
        for f in range(f0 + 1, f1):
            e = ease((f - f0) / float(span), power)
            slot = track.setdefault(f, {})
            for s, (fa, fb) in pairs.items():
                slot[s] = value_at(s, fa, fb, e)
    return track


def _fmt(v):
    """Compact, parser-safe number formatting for a command string."""
    return '%.6g' % float(v)


def frame_command(values):
    """'set a, 1.5; set b, 2' for a frame's {setting: value} map ('' if empty)."""
    return '; '.join('set %s, %s' % (s, _fmt(v))
                     for s, v in sorted(values.items()))


def emit_track(track, _self=cmd):
    """Author one mappend per interior frame. mappend (not mdo) so rock/nutate
    frame commands in movie.add_scenes survive. Returns the frames touched."""
    done = []
    for f in sorted(track):
        s = frame_command(track[f])
        if not s:
            continue
        try:
            _self.mappend(int(f), s)
            done.append(int(f))
        except Exception as e:
            print('MOVIE_ERR:' + str(e))
    return done


def scene_mark_command(name):
    """Frame command that makes a scene's own settings + focus target current.
    The name is base64-encoded because this string is executed by the PyMOL
    parser — a raw name containing a quote or semicolon would be an injection."""
    b64 = base64.b64encode(name.encode('utf-8')).decode('ascii')
    return ("from pymol import raymol_scene_anim as _a; "
            "_a.enter_scene('%s')" % b64)


def emit_scene_marks(marks, _self=cmd):
    """Author the enter_scene call at each scene keyframe. `marks` is
    [(frame, scene_name)]. Returns the frames touched."""
    done = []
    for f, name in marks:
        try:
            _self.mappend(int(f), scene_mark_command(name))
            done.append(int(f))
        except Exception as e:
            print('MOVIE_ERR:' + str(e))
    return done


def enter_scene(name_b64, _self=cmd):
    """Movie-frame callback: make scene `name`'s captured render settings and
    autofocus target current. Applies ALL captured settings (at a keyframe the
    scene's own values are by definition the correct endpoint) but deliberately
    NOT object TTT — the movie owns object motion through its own keyframes and
    re-applying would fight the interpolation."""
    try:
        name = base64.b64decode(name_b64).decode('utf-8')
    except Exception:
        return
    from pymol import raymol_scenes as _rs
    for s, v in _rs.scene_settings_map(name).items():
        try:
            _self.set(s, v)
        except Exception:
            pass
    try:
        _rs.apply_focus_target(name, _self)
    except Exception:
        pass
