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
import math

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
    ViewElemInterpolate (View.cpp:1165-1177, bias=1) so animated settings track
    the camera instead of desyncing (~24% off at t=0.25). A NEGATIVE power means
    parabolic=false there (View.cpp:897-900): a circular warp is applied first and
    the magnitude is used as the exponent."""
    if t <= 0.0:
        return 0.0
    if t >= 1.0:
        return 1.0
    parabolic = power >= 0.0
    if not parabolic:
        power = -power
    if power == 1.0 and parabolic:
        return t
    if t == 0.5:
        return 0.5
    flip = t > 0.5
    if flip:
        t = 1.0 - t
    if not parabolic:
        t = (1.0 - math.cos(math.pi * t)) * 0.5    # circular
    t = (t * 2.0) ** power * 0.5                   # parabolic
    return 1.0 - t if flip else t


def effective_power(first, last=None, override=None):
    """The easing power the core would use for a transition, per
    ViewElemInterpolate (View.cpp:877-897).

    A non-zero `override` — the power handed to mview interpolate/reinterpolate —
    wins outright. Otherwise BOTH endpoints decide: `mview store` records a power
    only when it is non-zero (Movie.cpp:1183-1185), so a 0/None endpoint carries no
    power_flag and simply does not vote. Two same-sign powers average; a mixed pair
    resolves the way View.cpp does; neither flagged falls back to 1.4. Using the
    destination alone desyncs the settings from the camera on a mixed
    Linear/Smooth timeline — exactly the defect this module exists to remove."""
    ov = _as_float(override)
    if ov is not None and ov != 0.0:
        return ov
    a = _as_float(first)
    b = _as_float(last)
    if a == 0.0:
        a = None                      # power=0 -> power_flag never set
    if b == 0.0:
        b = None
    if a is None:
        return _DEFAULT_POWER if b is None else b
    if b is None:
        return a
    if (a > 0.0) == (b > 0.0):
        return (a + b) / 2.0
    if abs(a) > abs(b):
        return a
    return b if b < 0.0 else a


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


def build_track(keyframes, power=None):
    """Per-frame interpolated values for the INTERIOR frames of each transition.

    `keyframes` is an ordered iterable of (frame, scene_name, power) where power is
    the one stored WITH that keyframe (as passed to mview store). `power` is the
    movie-wide override the path passed to mview interpolate/reinterpolate, if any.
    Both endpoints of a transition contribute — see effective_power.
    Returns {frame: {setting: float}}. Scene keyframes themselves are applied by
    enter_scene (exact captured values), so they are deliberately absent here."""
    from pymol import raymol_scenes as _rs
    track = {}
    kfs = sorted(keyframes, key=lambda k: int(k[0]))
    for (f0, n0, p0), (f1, n1, p1) in zip(kfs, kfs[1:]):
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
        pw = effective_power(p0, p1, power)
        for f in range(f0 + 1, f1):
            e = ease((f - f0) / float(span), pw)
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


def eye_depth(point, view):
    """Positive eye-space distance (Angstroms, in front of the camera) of a
    MODEL-space point under `view` (a cmd.get_view() result). Same camera math as
    metal_pick._eye_distance: eye_z = R_row2 . (p - origin) + tz, depth = -eye_z."""
    if not view:
        return None
    if len(view) >= 25:
        r20, r21, r22 = view[2], view[6], view[10]
        tz = view[18]
        ox, oy, oz = view[19], view[20], view[21]
    else:                                   # 18-float layout (this build)
        r20, r21, r22 = view[2], view[5], view[8]
        tz = view[11]
        ox, oy, oz = view[12], view[13], view[14]
    ez = (r20 * (point[0] - ox) + r21 * (point[1] - oy)
          + r22 * (point[2] - oz) + tz)
    return -ez


def focus_centroid(name, _self=cmd):
    """Bounding-box MIDPOINT of scene `name`'s captured autofocus target atoms,
    skipping objects that no longer exist. None if unresolvable.

    Must match the renderer exactly, which autofocuses on the midpoint of
    ExecutiveGetExtent(G, "dof_focus", mn, mx, /*transformed*/ true, -1, false)
    (SceneRender.cpp:2053-2056) — the bbox midpoint, not the arithmetic mean of
    the coordinates, and in TRANSFORMED space. cmd.get_extent goes through the
    identical ExecutiveGetExtent (Cmd.cpp:4523), so the pull's interior distances
    agree with what the renderer computes at the bracketing keyframes (no snap at
    either end) and follow an object displaced by a Move-mode TTT."""
    from pymol import raymol_scenes as _rs
    atoms = _rs.scene_focus_map(name)
    if not atoms:
        return None
    try:
        live = set(_self.get_names('objects') or [])
    except Exception:
        live = set()
    groups = {}
    for m, i in atoms:
        if m in live:
            groups.setdefault(m, []).append(int(i))
    if not groups:
        return None
    # One selection over every surviving object: the renderer likewise takes a
    # single bbox over the whole 'dof_focus' selection.
    sel = ' or '.join('(%s and index %s)' % (m, '+'.join(str(i) for i in idxs))
                      for m, idxs in sorted(groups.items()))
    try:
        mn, mx = _self.get_extent(sel, state=1)
        mid = [(mn[i] + mx[i]) * 0.5 for i in range(3)]
    except Exception:
        return None
    # ExecutiveGetExtent returning false yields this placeholder unit box
    # (Cmd.cpp:4529) — nothing resolved, so there is nothing to focus on.
    if list(mn) == [-0.5, -0.5, -0.5] and list(mx) == [0.5, 0.5, 0.5]:
        return None
    return mid


def build_focus_pull(keyframes, _self=cmd, power=None):
    """Per-frame focus distance for transitions whose autofocus target moves.

    With metal_dof_autofocus on, the renderer recomputes focus from the
    'dof_focus' selection every frame and DISCARDS metal_dof_focus
    (SceneRender.cpp:2051), so a changing target can only snap. To pull instead,
    autofocus is switched off across the transition and the distance is driven
    per frame: the target centroid is interpolated in model space and its depth
    resolved under THAT frame's interpolated camera (a straight lerp of the two
    endpoint distances would drift whenever the camera dollies).

    Only authored when both scenes have autofocus on and their centroids differ;
    every other combination steps at the cut. Must run AFTER cmd.mview
    ('interpolate') so cmd.frame(f) yields the interpolated view. Note: this
    function leaves the playhead at the last interior frame it visited; callers
    should reset to a specific frame afterwards if they need a known frame active."""
    from pymol import raymol_scenes as _rs
    out = {}
    kfs = sorted(keyframes, key=lambda k: int(k[0]))
    for (f0, n0, p0), (f1, n1, p1) in zip(kfs, kfs[1:]):
        f0, f1 = int(f0), int(f1)
        span = f1 - f0
        if span < 2:
            continue
        sa = _rs.scene_settings_map(n0)
        sb = _rs.scene_settings_map(n1)
        if not (_truthy(sa.get('metal_dof_autofocus'))
                and _truthy(sb.get('metal_dof_autofocus'))):
            continue                          # not both locked -> step at the cut
        ca = focus_centroid(n0, _self)
        cb = focus_centroid(n1, _self)
        if ca is None or cb is None or ca == cb:
            continue
        pw = effective_power(p0, p1, power)
        for f in range(f0 + 1, f1):
            e = ease((f - f0) / float(span), pw)
            pt = [ca[i] + (cb[i] - ca[i]) * e for i in range(3)]
            try:
                _self.frame(f)
                d = eye_depth(pt, _self.get_view())
            except Exception:
                d = None
            if d is None or d <= 0.0:
                continue
            out[f] = {'metal_dof_autofocus': 0.0, 'metal_dof_focus': d}
    return out


# The animation authored into the CURRENT movie, regenerated on every rebuild.
# {frame: {setting: float}} for interior transition frames...
_track = {}
# ...and [(frame, scene_name)] for the scene keyframes carrying enter_scene.
_scene_marks = []


def clear_authored(_self=cmd):
    """Blank the frames a previous author() pass wrote. mdo (not mappend) SETS the
    slot, so this removes our text; without it a re-author appends on top of the
    old commands and session_save can no longer strip what it cannot regenerate,
    leaving a .pse that loads with a LOCKED (dead) movie.

    Trade-off: blanking a slot also drops a third-party command sharing that exact
    frame. Accepted deliberately — the only frame commands PyMOL's own scene-movie
    authoring could co-locate with ours would come from movie.add_scenes' camera
    animation, and its _rock/_nutate (movie.py:490,543) author `mview store`
    keyframes, not frame commands. Returns the frames blanked."""
    frames = set(int(f) for f in _track)
    frames.update(int(f) for f, _n in _scene_marks)
    try:
        length = int(_self.get_movie_length())
    except Exception:
        length = 0
    done = []
    for f in sorted(frames):
        # Past the end of the current movie there is no Cmd[] slot to blank (a
        # shorter mset already dropped it); mdo would only print a Movie-Error.
        if length > 0 and f > length:
            continue
        try:
            _self.mdo(f, '')
            done.append(f)
        except Exception as e:
            print('MOVIE_ERR:' + str(e))
    return done


def author(keyframes, _self=cmd, power=None):
    """Author the whole per-scene setting animation for a movie.

    `keyframes` is [(frame, scene_name, power)] for every scene keyframe in the
    movie, in any order (sorted internally by frame), each power being the one
    stored with that keyframe. `power` is the movie-wide easing override the path
    passed to cmd.mview('interpolate'/'reinterpolate') — 0/None means it passed
    none and the endpoints decide. Call AFTER the path's cmd.mset and
    cmd.mview('interpolate'). Returns the number of frames touched.

    author([]) is the reset: it un-emits the previous pass and clears the track,
    so call it unconditionally — including on a rebuild that has no scenes at all,
    which would otherwise persist a stale animation into the new movie."""
    keyframes = list(keyframes)
    clear_authored(_self)             # BEFORE the reset: needs the old frame list
    _track.clear()
    _scene_marks[:] = []
    marks = [(int(f), n) for f, n, _p in keyframes]
    track = build_track(keyframes, power)
    # The pull owns focus wherever it applies, so it overrides the plain ramp.
    for f, vals in build_focus_pull(keyframes, _self, power).items():
        track.setdefault(f, {}).update(vals)
    _track.update(track)
    _scene_marks[:] = sorted(set(marks))
    touched = set(emit_scene_marks(_scene_marks, _self))
    touched.update(emit_track(_track, _self))
    return len(touched)


def _our_commands():
    """{frame: [piece, ...]} for every frame command piece this module authored."""
    out = {}
    for f, name in _scene_marks:
        out.setdefault(int(f), []).append(scene_mark_command(name))
    for f, vals in _track.items():
        s = frame_command(vals)
        if s:
            out.setdefault(int(f), []).append(s)
    return out


# --- .pse persistence (registered in cmd._deferred_init_pymol_internals) ---
def session_save(session, *, _self=cmd):
    """Persist the animation as STRUCTURED data and strip our own frame commands
    out of the saved movie.

    Stripping matters: any non-empty frame command makes session load call
    MovieSetLock (Movie.cpp:459-462), and MovieDoFrameCommand is gated on
    !Locked (Movie.cpp:1051) — so a locked movie loses its commands, its scene
    recall AND its camera track, and RayMol has no security-wizard UI to unlock
    it. We remove only OUR text so a co-located rock/nutate command survives."""
    session['raymol_movie_anim'] = {
        'track': {str(f): dict(v) for f, v in _track.items()},
        'marks': [[int(f), n] for f, n in _scene_marks],
    }
    try:
        mv = session.get('movie')
        cmds = mv[5] if (isinstance(mv, list) and len(mv) > 5) else None
        if isinstance(cmds, list):
            for f, pieces in _our_commands().items():
                i = int(f) - 1                  # movie Cmd[] is 0-based
                if 0 <= i < len(cmds) and isinstance(cmds[i], str):
                    for s in pieces:
                        cmds[i] = cmds[i].replace(';' + s, '').replace(s, '')
    except Exception as e:
        print('MOVIE_ERR:' + str(e))
    return 1


def session_restore(session, *, _self=cmd):
    """Rebuild the animation from structured data and RE-AUTHOR the commands.

    Values are validated (known captured setting + real number) and the command
    strings are regenerated here — stored text is never replayed, so a hostile
    .pse cannot smuggle executable code through our session key."""
    _track.clear()
    _scene_marks[:] = []
    d = session.get('raymol_movie_anim')
    if not isinstance(d, dict):
        return 1
    from pymol import raymol_scenes as _rs
    known = set(_rs.CAPTURE)
    raw = d.get('track')
    if isinstance(raw, dict):
        for fs, vals in raw.items():
            try:
                f = int(fs)
            except (TypeError, ValueError):
                continue
            if not isinstance(vals, dict):
                continue
            clean = {}
            for s, v in vals.items():
                if s not in known:
                    continue
                fv = _as_float(v)
                if fv is None:
                    continue
                clean[s] = fv
            if clean:
                _track[f] = clean
    marks = d.get('marks')
    if isinstance(marks, list):
        for m in marks:
            try:
                _scene_marks.append((int(m[0]), str(m[1])))
            except Exception:
                continue
    _scene_marks[:] = sorted(set(_scene_marks))
    emit_scene_marks(_scene_marks, _self)
    emit_track(_track, _self)
    return 1


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
        except Exception as e:
            print('MOVIE_ERR:' + str(e))
    try:
        _rs.apply_focus_target(name, _self)
    except Exception:
        pass
