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
ones step at the scene cut via enter_scene(), and depth of field gets a
dedicated builder — the captured focus number is not the distance on screen
(0 means "auto") and metal_dof is boolean, so DOF would otherwise both refuse to
pull and pop on/off.

The authored track is persisted as STRUCTURED DATA and the command strings are
regenerated locally on restore — never persisted or replayed as text. Frame
commands in a .pse trip MovieSetLock, which disables the entire per-frame path
(commands, scene recall AND the camera track), so this module also blanks its own
commands out of the saved session.

Light rigs (#617). Each scene stores its own rig (raymol_scenes._scene_lights:
a get_lights() dict when the rig is on, else 'off'; no entry for an older
scene). enter_scene applies the scene's rig exactly at its keyframe, and every
interior frame of a transition between two DISTINCT scenes where at least one
has an entry carries one compact frame command, `_lights_blend <A>, <B>, <t>`
(scene names as UTF-8 hex, t the camera's eased position, pre-rounded). It
reads both stored rigs at play time, so re-storing a scene's rig needs no
re-authoring. The blend is computed by the core (pymol::LightRigBlend, #661);
an interactive animated recall is blended by the core with the camera (#661).
blend_rigs starts from a copy of A, so every field steps at the cut unless it
is listed there: angles take the shortest path, colour interpolates in linear
RGB, pinned lights arc around the blended centre, and a light in only one
scene fades its intensity from or to 0. Rig on/off steps at the cut. The track
is saved as structured data under 'lights' (only when there is one), stripped
from the saved movie and regenerated on load like the rest. Loop-wrap
transitions (#656): when the movie loops (movie_loop on or wrap=True), a
pseudo-transition from the last keyframe back to the first shifted by the movie
length blends settings, DOF and the light rig across the wrap span.
Dust phase (#687): when dust_speed differs between scenes, enter_scene and
_lights_blend write metal_light_air_phase so the dust time is the integrated
speed across the movie and the dust does not jump. When the movie has a rig
blend, every other frame carries a phase-only command (_a.dust_hold()), so a
hold frame re-applies its scene's rig so a jump equals playback (#661) and
renders the same dust time as playback; author() starts each movie from
phase 0.
"""
import base64
import copy
import math
import re

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

# The aperture a DOF fade ramps to on the side where DOF is off: 0 is a closed
# aperture, which the renderer skips outright (RendererMetal.mm, #472), so the
# effect dissolves all the way out. Before #472 zero was the renderer's "unset"
# sentinel and meant MAXIMUM blur, so the fade had to stop just short of it.
_OFF_APERTURE = 0.0

# Settings build_track must NOT emit because build_dof_transition owns them
# outright. Focus is not a plain number: the renderer RESOLVES it every frame
# (0 = auto), so only the DOF builder — which resolves both sides under each
# frame's camera and switches autofocus off while it drives them — may write it.
# Two writers on one setting would fight, the later dict.update winning by
# accident of ordering.
_DOF_OWNED = frozenset(["metal_dof_focus"])

# Everything build_dof_transition can put on a track. Together with INTERPOLATE
# (all build_track can emit) this is the COMPLETE set of names author() is able
# to produce, which is what session_restore validates against.
_DOF_EMITTED = frozenset(["metal_dof", "metal_dof_aperture", "metal_dof_focus",
                          "metal_dof_autofocus"])

# Focus distances closer together than this (Angstroms) are the same plane;
# ramping between them would only switch autofocus off for no visible gain.
_FOCUS_EPS = 1e-6

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
    """True if `setting` should ramp between numeric endpoints a and b.

    Note there is no 0-endpoint exception for metal_dof_focus: 0 means AUTO, not
    "no value", and the renderer resolves it to a real distance every frame
    (SceneRender.cpp:2043-2072), so it is always rampable in principle. What it
    is NOT rampable between are the CAPTURED numbers, which is why build_track
    leaves focus alone entirely (_DOF_OWNED) and build_dof_transition ramps the
    RESOLVED distances instead."""
    if setting not in INTERPOLATE:
        return False
    if a is None or b is None:
        return False
    return True


def value_at(setting, a, b, e):
    """Interpolated value at eased position `e`.

    `setting` is unused — it was the hook for per-setting clamping, which only
    ever existed to keep DOF fades off the renderer's zero sentinel (#472). The
    argument stays so callers and the ramp table read the same way."""
    return a + (b - a) * e


def transitions(keyframes, wrap_length=0):
    """[((f0, n0, p0), (f1, n1, p1))] for each consecutive keyframe pair
    (frames as int, sorted by frame), plus -- when wrap_length > 0 -- the
    loop-wrap pseudo-transition from the last keyframe to the first at
    first_frame + wrap_length (the camera's own wrap, Movie.cpp
    MViewAction::Interpolate). The wrap pair is added only with >= 2
    keyframes and a last keyframe at or before wrap_length."""
    kfs = [(int(f), n, p) for f, n, p in sorted(keyframes, key=lambda k: int(k[0]))]
    pairs = list(zip(kfs, kfs[1:]))
    if len(kfs) >= 2 and wrap_length > 0 and kfs[-1][0] <= wrap_length:
        f0, n0, p0 = kfs[0]
        pairs.append((kfs[-1], (f0 + wrap_length, n0, p0)))
    return pairs


def _slot(f, wrap_length):
    """The real movie frame for transition frame f: f - wrap_length past
    the end of a wrapping movie, else f."""
    return f - wrap_length if wrap_length > 0 and f > wrap_length else f


def build_track(keyframes, power=None, wrap_length=0):
    """Per-frame interpolated values for the INTERIOR frames of each transition.

    `keyframes` is an ordered iterable of (frame, scene_name, power) where power is
    the one stored WITH that keyframe (as passed to mview store). `power` is the
    movie-wide override the path passed to mview interpolate/reinterpolate, if any.
    `wrap_length` > 0 adds the loop-wrap transition back to the first keyframe.
    Both endpoints of a transition contribute — see effective_power.
    Returns {frame: {setting: float}}. Scene keyframes themselves are applied by
    enter_scene (exact captured values), so they are deliberately absent here,
    as is everything in _DOF_OWNED (build_dof_transition's territory)."""
    from pymol import raymol_scenes as _rs
    track = {}
    for (f0, n0, p0), (f1, n1, p1) in transitions(keyframes, wrap_length):
        span = f1 - f0
        if span < 2:
            continue                      # no interior frames
        a = _rs.scene_settings_map(n0)
        b = _rs.scene_settings_map(n1)
        pairs = {}
        for s, bv in b.items():
            if s in _DOF_OWNED:
                continue                  # build_dof_transition drives this one
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
            slot = track.setdefault(_slot(f, wrap_length), {})
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
    frame commands in movie.add_scenes survive. Returns the frames touched.

    Note: this invariant holds only on the SAVE path. The re-author path
    (clear_authored) deliberately blanks whole slots before re-emitting — a
    third-party command sharing an exact frame with ours is dropped. See
    clear_authored for the rationale."""
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


def _view_origin(view):
    """The rotation origin (PyMOL's "centre of interest") inside a cmd.get_view()
    result, or None if `view` is not one. Sole home for the origin's layout
    indices so eye_depth and resolve_focus cannot disagree about where it lives."""
    if not view:
        return None
    if len(view) >= 25:
        return [view[19], view[20], view[21]]
    if len(view) >= 18:                     # 18-float layout (this build)
        return [view[12], view[13], view[14]]
    return None


def eye_depth(point, view):
    """Positive eye-space distance (Angstroms, in front of the camera) of a
    MODEL-space point under `view` (a cmd.get_view() result). Same camera math as
    metal_pick._eye_distance: eye_z = R_row2 . (p - origin) + tz, depth = -eye_z."""
    o = _view_origin(view)
    if o is None:
        return None
    if len(view) >= 25:
        r20, r21, r22 = view[2], view[6], view[10]
        tz = view[18]
    else:                                   # 18-float layout (this build)
        r20, r21, r22 = view[2], view[5], view[8]
        tz = view[11]
    ez = (r20 * (point[0] - o[0]) + r21 * (point[1] - o[1])
          + r22 * (point[2] - o[2]) + tz)
    return -ez


def focus_centroid(name, _self=cmd):
    """Bounding-box MIDPOINT of scene `name`'s captured autofocus target atoms,
    skipping objects that no longer exist. None if unresolvable.

    Must match the renderer exactly, which autofocuses on the midpoint of
    ExecutiveGetExtent(G, "dof_focus", mn, mx, /*transformed*/ true, -1, false)
    (SceneRender.cpp:2053-2056) — the bbox midpoint, not the arithmetic mean of
    the coordinates, in TRANSFORMED space. The C++ state argument -1 takes the
    OMOP_MNMX path (ObjectMolecule.cpp:9927,9947) and loops over ALL coordinate
    sets (all states of the object). cmd.get_extent(state=0) passes int(0)-1=-1
    to the same ExecutiveGetExtent (Cmd.cpp:4523), so the pull's interior
    distances agree with what the renderer computes at the bracketing keyframes
    (no snap at either end) for both single-state and multi-state (NMR/MD)
    objects alike, and follow an object displaced by a Move-mode TTT."""
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
        mn, mx = _self.get_extent(sel, state=0)   # ALL_STATES -> C++ -1 (all coord sets)
        mid = [(mn[i] + mx[i]) * 0.5 for i in range(3)]
    except Exception:
        return None
    # ExecutiveGetExtent returning false yields this placeholder unit box
    # (Cmd.cpp:4529) — nothing resolved, so there is nothing to focus on.
    if list(mn) == [-0.5, -0.5, -0.5] and list(mx) == [0.5, 0.5, 0.5]:
        return None
    return mid


def resolve_focus(name, view, _self=cmd):
    """Effective eye-space focus distance for scene `name` under `view`, mirroring
    how the renderer resolves it (SceneRender.cpp:2043-2072):
      the autofocus target's transformed bbox-midpoint depth -> else the manual
      metal_dof_focus if > 0 -> else the centre of interest (rotation origin).
    Returns a positive distance, or None if nothing resolves.

    metal_dof_focus == 0 therefore does NOT mean "no value": it means AUTO, and
    the renderer still shows a concrete plane for it. Treating 0 as unrampable is
    what left a captured 0 -> 120 focus change completely dead.

    Precedence detail: the renderer zeroes dofFocus BEFORE the autofocus block
    (SceneRender.cpp:2050), so an enabled autofocus discards the manual value
    outright — and a stale one is always there, because the UI only disables the
    focus slider while auto-lock is on (ObjectPanel.swift:2521-2530) rather than
    clearing it. Consulting manual first would aim at a plane the renderer never
    shows, and snap back at the keyframe."""
    from pymol import raymol_scenes as _rs
    settings = _rs.scene_settings_map(name)
    if _truthy(settings.get('metal_dof_autofocus')):
        centroid = focus_centroid(name, _self)
        if centroid is not None:
            d = eye_depth(centroid, view)
            if d is not None and d > 0.0:
                return d
        # Target gone/unresolvable: the renderer falls through to the origin, NOT
        # back to the manual value it just discarded.
    else:
        manual = _as_float(settings.get('metal_dof_focus'))
        if manual is not None and manual > 0.0:
            return manual
    d = eye_depth(_view_origin(view), view)      # centre of interest: -tz
    if d is not None and d > 0.0:
        return d
    return None


def build_dof_transition(keyframes, _self=cmd, power=None, wrap_length=0):
    """Per-frame depth-of-field animation across each transition: a focus pull
    while DOF stays on, and a blur FADE where it switches on or off.

    Two things the plain build_track ramp cannot do:

    * metal_dof is boolean, so a scene that turns DOF on or off POPS. Across such
      a transition DOF is force-enabled for the interior frames and the aperture
      ramps between the enabled scene's value and _OFF_APERTURE (0 = closed
      aperture = no blur), dissolving the effect in or out. The aperture
      captured on the DISABLED side is meaningless — nothing was ever rendered
      with it — so it takes no part.
    * metal_dof_focus is resolved by the renderer every frame, so the captured
      numbers are not the distances on screen. resolve_focus turns each side into
      the distance the renderer would actually use under THAT frame's
      interpolated camera and the ramp runs between those (a lerp of two
      endpoint depths would drift whenever the camera dollies). Autofocus is
      switched off whenever we drive focus, or the renderer discards our value
      (SceneRender.cpp:2050).

    Returns {frame: {setting: float}} for interior frames only; author() overlays
    it on top of build_track, so these win. `wrap_length` > 0 adds the loop-wrap
    transition. Must run AFTER cmd.mview ('interpolate') so cmd.frame(f) yields
    the interpolated view. Note: this function leaves the playhead at the last
    interior frame it visited; callers should reset to a specific frame afterwards
    if they need a known frame active."""
    from pymol import raymol_scenes as _rs
    out = {}
    for (f0, n0, p0), (f1, n1, p1) in transitions(keyframes, wrap_length):
        span = f1 - f0
        if span < 2:
            continue
        sa = _rs.scene_settings_map(n0)
        sb = _rs.scene_settings_map(n1)
        dof_a = _truthy(sa.get('metal_dof'))
        dof_b = _truthy(sb.get('metal_dof'))
        if not (dof_a or dof_b):
            continue                      # DOF never visible -> nothing to animate
        fade = dof_a != dof_b
        if fade:
            # The enabled side owns both the aperture and the focus target; the
            # other side contributes only the fact that it is off.
            on_name = n1 if dof_b else n0
            ap_on = _as_float((sb if dof_b else sa).get('metal_dof_aperture'))
            if ap_on is None:
                ap_on = 14.0              # metal_dof_aperture's own default
            ap_on = max(ap_on, _OFF_APERTURE)
            ap_from, ap_to = ((_OFF_APERTURE, ap_on) if dof_b
                              else (ap_on, _OFF_APERTURE))
        pw = effective_power(p0, p1, power)
        for f in range(f0 + 1, f1):
            e = ease((f - f0) / float(span), pw)
            slot = _slot(f, wrap_length)
            try:
                _self.frame(slot)
                view = _self.get_view()
            except Exception:
                view = None               # focus cannot resolve; the fade still can
            vals = {}
            if fade:
                vals['metal_dof'] = 1.0
                vals['metal_dof_aperture'] = value_at(
                    'metal_dof_aperture', ap_from, ap_to, e)
                # Focus HOLDS on the enabled side's target — re-resolved per frame,
                # so it stays glued to it as the camera moves.
                d = resolve_focus(on_name, view, _self)
                if d:
                    vals['metal_dof_focus'] = d
                    vals['metal_dof_autofocus'] = 0.0
            else:
                da = resolve_focus(n0, view, _self)
                db = resolve_focus(n1, view, _self)
                if da is not None and db is not None and abs(db - da) > _FOCUS_EPS:
                    vals['metal_dof_focus'] = da + (db - da) * e
                    vals['metal_dof_autofocus'] = 0.0
                # Equal distances: same plane. Emitting nothing leaves autofocus
                # on, still tracking its target correctly by itself.
            if vals:
                out[slot] = vals
    return out


# --- Light rig blend (#617) --------------------------------------------------
# Computed by the core (pymol::LightRigBlend, #661).

_RIG_AIR_LERP = ('haze', 'dust', 'dust_size', 'dust_speed', 'scatter')


def _is_num(v):
    return (isinstance(v, (int, float)) and not isinstance(v, bool)
            and math.isfinite(v))


def _lerp(a, b, e):
    return a + (b - a) * e


def rig_on(r):
    """Decision 15's "the rig is on" (raymol_scenes.rig_on): a dict that is
    enabled with at least one light."""
    from pymol import raymol_scenes as _rs
    return _rs.rig_on(r)


def blend_rigs(a, b, e, _self=cmd):
    """Rig dicts `a` and `b` (both on) blended at eased position `e` (#617,
    computed by the core, pymol::LightRigBlend, #661).

    Starts from a copy of A, so a field steps at the cut unless listed here
    (a field a later ticket adds steps by default). The rig is enabled;
    centre, size, ambient, classic and the air's haze, dust, dust_size,
    dust_speed and scatter lerp (seed stays A's). Lights match by name
    ignoring case and keep A's spelling. A matched light lerps beam,
    softness, highlight, falloff, warmth and intensity, colour in linear RGB,
    and orbit (shortest path), pitch and radius when both are camera lights,
    its position (an arc about the blended centre) when both are pinned, and
    its aim point when both aim at points; anchor, aim, aim_selection, shadow
    and outline are A's. A light only in A fades to intensity 0; one only in
    B fades in from 0 with shadow and outline off until the cut. Order: A's
    lights, then B's own, so shadow slots stay A's. Past six lights, the
    dimmest one-sided lights at this frame are left out (ties: the later
    one first)."""
    a = dict(a)
    b = dict(b)
    air_a = a.get('air')
    air_b = b.get('air')
    if isinstance(air_a, dict) and isinstance(air_b, dict):
        air_b = dict(air_b)
        for k in _RIG_AIR_LERP:
            if not (_is_num(air_a.get(k)) and _is_num(air_b.get(k))):
                if _is_num(air_a.get(k)):
                    air_b[k] = air_a[k]
                else:
                    air_b.pop(k, None)
        b['air'] = air_b
    elif isinstance(air_a, dict):
        b['air'] = dict(air_a)
    else:
        b.pop('air', None)
    from pymol import lighting
    return lighting._blend_lights(a, b, e, _self=_self)


def blend_target(ra, rb, t, _self=cmd):
    """What the rig should be at position `t` of a transition from scene
    entry `ra` to `rb` (each a rig dict, 'off' or None for no entry):
    None (leave the rig alone) when A has no entry; B's entry from t >= 1
    (what the cut applies); the blend while 0 < t < 1 and both rigs are on;
    otherwise A's entry -- rig on/off steps at the cut."""
    if ra is None:
        return None
    t = float(t)
    if t >= 1.0:
        return copy.deepcopy(rb)
    if t > 0.0 and rig_on(ra) and rig_on(rb):
        return blend_rigs(ra, rb, t, _self=_self)
    return copy.deepcopy(ra)


_PHASE_SETTING = 'metal_light_air_phase'
_DEFAULT_FPS = 30.0        # LightAir.h kLightAirDefaultFps
_MAX_DUST_SPEED = 10.0     # LightRig.cpp's dust_speed range


def _rig_speed(rig):
    """The dust speed the core would hold for rig dict `rig` (on): air
    dust_speed clamped to 0..10, 1.0 (the core default) when absent."""
    if isinstance(rig, dict):
        air = rig.get('air')
        if isinstance(air, dict):
            s = air.get('dust_speed')
            if _is_num(s):
                return min(max(float(s), 0.0), _MAX_DUST_SPEED)
    return 1.0


def _entry_speed(entry):
    """A scene entry's speed: None for no entry (the rig is left alone);
    _rig_speed for a rig that is on; 0.0 for 'off' or a rig that is not on
    (no air is drawn, the dust holds)."""
    if entry is None:
        return None
    if rig_on(entry):
        return _rig_speed(entry)
    return 0.0


def _blend_speed(ra, rb, t):
    """The speed blend_target(ra, rb, t) leaves the rig with, without
    building the rig: None when ra is None; _entry_speed(rb) when t >= 1;
    when 0 < t < 1 and both rig_on: _lerp of the two RAW air dust_speed
    values (then clamped like _rig_speed) when both air dicts hold numbers,
    else _rig_speed(ra) (blend_rigs keeps A's air); otherwise
    _entry_speed(ra)."""
    if ra is None:
        return None
    t = float(t)
    if t >= 1.0:
        return _entry_speed(rb)
    if t > 0.0 and rig_on(ra) and rig_on(rb):
        air_a = ra.get('air') if isinstance(ra, dict) else None
        air_b = rb.get('air') if isinstance(rb, dict) else None
        if (isinstance(air_a, dict) and isinstance(air_b, dict)
                and _is_num(air_a.get('dust_speed'))
                and _is_num(air_b.get('dust_speed'))):
            sa = min(max(float(air_a['dust_speed']), 0.0), _MAX_DUST_SPEED)
            sb = min(max(float(air_b['dust_speed']), 0.0), _MAX_DUST_SPEED)
            lerped = _lerp(sa, sb, t)
            return min(max(float(lerped), 0.0), _MAX_DUST_SPEED)
        return _rig_speed(ra)
    return _entry_speed(ra)


def dust_speeds(marks=None, lights_track=None, entries=None):
    """[s(1), ..., s(L)]: the rig's dust speed at each 1-based movie frame
    of the authored movie, L the last frame either list names (0 frames -> []).
    `marks` / `lights_track` default to the module's _scene_marks and
    _lights_track; `entries` maps a scene name to its rig entry and defaults
    to raymol_scenes.scene_lights (read ONCE per name, cached in a local
    dict). A transition frame takes _blend_speed; else a keyframe takes
    _entry_speed of its scene (the last mark wins if a frame has several);
    a frame with neither, or whose value is None, keeps the previous frame's
    speed. Frames before the first known speed take the FIRST known speed of
    the movie (the live rig before it is unknown). With no known speed at
    all (no scene stores a rig) it is [], and the phase stays 0: the dust
    keeps clock x speed, as before #687."""
    if marks is None:
        marks = _scene_marks
    if lights_track is None:
        lights_track = _lights_track

    cache = {}

    def get_entry(name):
        if name not in cache:
            if entries is None:
                from pymol import raymol_scenes as _rs
                cache[name] = _rs.scene_lights(name)
            elif callable(entries):
                cache[name] = entries(name)
            elif isinstance(entries, dict):
                cache[name] = entries.get(name)
            else:
                cache[name] = None
        return cache[name]

    mark_frames = []
    keyframe_scenes = {}
    for f, name in marks:
        fi = int(f)
        keyframe_scenes[fi] = name
        mark_frames.append(fi)

    track_frames = []
    trans_map = {}
    if isinstance(lights_track, dict):
        for f, val in lights_track.items():
            fi = int(f)
            trans_map[fi] = (val[0], val[1], val[2])
            track_frames.append(fi)
    elif lights_track:
        for it in lights_track:
            fi = int(it[0])
            trans_map[fi] = (it[1], it[2], it[3])
            track_frames.append(fi)

    all_frames = mark_frames + track_frames
    if not all_frames:
        return []
    L = max(all_frames)
    if L < 1:
        return []

    raw = [None] * L
    for f in range(1, L + 1):
        s = None
        if f in trans_map:
            a, b, t = trans_map[f]
            s = _blend_speed(get_entry(a), get_entry(b), t)
        if s is None and f in keyframe_scenes:
            s = _entry_speed(get_entry(keyframe_scenes[f]))
        raw[f - 1] = s

    first_known = None
    for s in raw:
        if s is not None:
            first_known = s
            break

    if first_known is None:
        return []

    out = []
    cur = first_known
    for s in raw:
        if s is not None:
            cur = s
        out.append(float(cur))
    return out


def dust_phase(frame, fps, speeds, speed=None):
    """metal_light_air_phase for 1-based movie `frame`: (sum of speeds of
    the frames before it - (frame - 1) x its own speed) / fps, so that
    (frame - 1) / fps x speed + phase is the integral of the speed over the
    movie so far. fps <= 0 or not finite reads as 30. A frame past the end
    keeps the last speed; frame < 1 or an empty list gives 0.0. `speed`,
    when given, is the speed the rig actually holds now and replaces the
    frame's own: the phase then makes the dust time the integral whatever
    speed a jump left on the rig."""
    if not speeds or frame < 1:
        return 0.0
    try:
        fps = float(fps)
        if not (fps > 0.0 and math.isfinite(fps)):
            fps = _DEFAULT_FPS
    except (TypeError, ValueError):
        fps = _DEFAULT_FPS

    frame = int(frame)
    i = frame - 1
    L = len(speeds)
    if i < L:
        s_i = speeds[i]
        sum_before = sum(speeds[:i])
    else:
        s_i = speeds[-1]
        sum_before = sum(speeds) + (i - L) * s_i
    if speed is not None:
        s_i = float(speed)

    return float((sum_before - i * s_i) / fps)


def _live_speed(_self):
    """The dust speed of the rig as it is now (after this frame's commands),
    or None when the rig is off or cannot be read (a stand-in cmd). A hold
    frame reached by a jump keeps the rig of the frame shown before it; the
    phase is computed against that speed so the dust time is still right."""
    try:
        from pymol import lighting
        live = lighting.get_lights(_self=_self)
    except Exception:
        return None
    return _rig_speed(live) if rig_on(live) else None


def _write_phase(_self):
    """Write metal_light_air_phase for the current movie frame
    (_self.get_frame()) and movie_fps (float(_self.get('movie_fps'))). Writes
    only when it differs from the current value (read with
    _self.get_setting_float; if that is unavailable, write). Never raises:
    a core without the setting, or a stand-in cmd without get_frame, writes
    nothing."""
    try:
        get_frame = getattr(_self, 'get_frame', None)
        if get_frame is None:
            return
        frame = int(get_frame())
        try:
            fps_val = _self.get('movie_fps')
            fps = float(fps_val) if fps_val is not None else _DEFAULT_FPS
        except Exception:
            fps = _DEFAULT_FPS

        speeds = dust_speeds()
        phase = dust_phase(frame, fps, speeds, _live_speed(_self))

        _set_phase(phase, _self)
    except Exception:
        pass


def _name_hex(name):
    return name.encode('utf-8').hex()


_HEX_RE = re.compile(r'(?:[0-9a-fA-F]{2})+')


def _name_from_hex(s):
    """A scene name from its UTF-8 hex, or None for anything else."""
    if not isinstance(s, str) or not _HEX_RE.fullmatch(s):
        return None
    try:
        return bytes.fromhex(s).decode('utf-8')
    except (ValueError, UnicodeDecodeError):
        return None


def _movie_length(_self):
    try:
        return max(0, int(_self.get_movie_length()))
    except Exception:
        return 0


def _set_phase(phase, _self):
    """Write metal_light_air_phase when it differs from the setting (a
    float32, so compared at its precision). Never raises: a core without
    the setting writes nothing."""
    try:
        getter = getattr(_self, 'get_setting_float', None)
        if getter is not None:
            cur = float(getter(_PHASE_SETTING))
            if abs(cur - phase) <= 1e-6 * max(1.0, abs(phase)):
                return
        _self.set(_PHASE_SETTING, phase, quiet=1)
    except Exception:
        pass


def phase_command():
    """The frame command of a hold frame (#687): it only writes the dust
    phase. No arguments: the phase is computed from the authored movie."""
    return "from pymol import raymol_scene_anim as _a; _a.dust_hold()"


def build_phase_frames(marks, lights_track, length):
    """The frames 1..`length` that carry neither a scene mark nor a rig
    blend, when there is a rig blend at all (else []): a jump to one of them
    (frame N then png, an export starting mid-movie) runs only that frame's
    command, so each needs its own phase write or it renders with whatever
    phase the last frame shown left behind."""
    if not lights_track or length < 1:
        return []
    busy = set(int(f) for f, _n in marks) | set(int(f) for f in lights_track)
    return [f for f in range(1, int(length) + 1) if f not in busy]


def emit_phase_frames(frames, _self=cmd):
    """One mappend of phase_command per hold frame. Returns the frames
    touched."""
    done = []
    text = phase_command()
    for f in frames:
        try:
            _self.mappend(int(f), text)
            done.append(int(f))
        except Exception as e:
            print('MOVIE_ERR:' + str(e))
    return done


def dust_hold(_self=cmd):
    """The hold frames' command: re-apply the held scene's light rig (#661) so
    a jump equals playback, and write the dust phase for this frame (#687)."""
    try:
        get_frame = getattr(_self, 'get_frame', None)
        if get_frame is not None and _scene_marks:
            frame = int(get_frame())
            held = None
            for f, name in sorted(_scene_marks):
                if int(f) <= frame:
                    held = name
            if held is not None:
                from pymol import raymol_scenes as _rs
                _rs.apply_lights(held, _self)
    except Exception:
        pass
    _write_phase(_self)


def lights_command(a, b, t):
    """The frame command for position `t` from scene `a` to `b`. Names are
    UTF-8 hex: [0-9a-f] only, so no quote, ',', ';' or '=' reaches the
    parser (base64's '=' padding would read as a keyword argument)."""
    return '_lights_blend %s, %s, %s' % (_name_hex(a), _name_hex(b), _fmt(t))


def build_lights_track(keyframes, power=None, wrap_length=0):
    """{frame: (scene_a, scene_b, t)} for the interior frames of every
    transition between two DISTINCT scenes, at least one of which holds a rig
    entry now ('off' or a dict). `wrap_length` > 0 adds the loop-wrap
    transition. `t` is the camera's eased position (the easing build_track
    uses), stored pre-rounded so a restore regenerates the same command text."""
    from pymol import raymol_scenes as _rs
    track = {}
    for (f0, n0, p0), (f1, n1, p1) in transitions(keyframes, wrap_length):
        span = f1 - f0
        if span < 2 or n0 == n1:
            continue
        if _rs.scene_lights(n0) is None and _rs.scene_lights(n1) is None:
            continue
        pw = effective_power(p0, p1, power)
        for f in range(f0 + 1, f1):
            t = float(_fmt(ease((f - f0) / float(span), pw)))
            track[_slot(f, wrap_length)] = (n0, n1, t)
    return track


def emit_lights_track(track, _self=cmd):
    """One mappend of lights_command per frame. Returns the frames touched."""
    done = []
    for f in sorted(track):
        a, b, t = track[f]
        try:
            _self.mappend(int(f), lights_command(a, b, t))
            done.append(int(f))
        except Exception as e:
            print('MOVIE_ERR:' + str(e))
    return done


def lights_blend(a_hex, b_hex, t, _self=cmd):
    """The `_lights_blend` frame command: blend scene A's stored rig towards
    B's at position `t`, reading both now. Bad arguments (not hex, odd
    length, not UTF-8, t not a finite number) do nothing; it never raises and
    prints nothing itself (a stored rig the core refuses warns once per scene
    through raymol_scenes)."""
    try:
        a = _name_from_hex(a_hex)
        b = _name_from_hex(b_hex)
        if a is None or b is None:
            return
        t = float(t)
        if not math.isfinite(t):
            return
        t = min(max(t, 0.0), 1.0)
        from pymol import raymol_scenes as _rs
        target = None
        try:
            target = blend_target(_rs.scene_lights(a), _rs.scene_lights(b), t, _self=_self)
        except Exception as exc:
            _rs._warn_lights(a, 'light rig of scene "%s" could not be blended: %s' % (a, exc))
        if target is not None:
            _rs._apply_lights_target(target, _self, report=a)
    except Exception:
        pass
    _write_phase(_self)


# The animation authored into the CURRENT movie, regenerated on every rebuild.
# {frame: {setting: float}} for interior transition frames...
_track = {}
# ...and [(frame, scene_name)] for the scene keyframes carrying enter_scene...
_scene_marks = []
# ...and {frame: (scene_a, scene_b, t)} for the rig blend's _lights_blend.
_lights_track = {}
# ...and [frame] for the hold frames carrying the dust phase write (#687).
_phase_frames = []


def reset():
    """Forget the whole authored animation WITHOUT touching the movie (#657).

    For `reinitialize everything`, which has already dropped the movie: author([])
    or clear_authored() would mdo frames of a movie that no longer exists (one
    Movie-Error per frame), and a .pse saved or loaded afterwards would carry the
    stale marks and tracks into the fresh session."""
    _track.clear()
    _scene_marks[:] = []
    _lights_track.clear()
    _phase_frames[:] = []


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
    frames.update(int(f) for f in _lights_track)
    # A hold frame (#687) carries only the phase write, and can be any frame
    # of the movie, so its slot is edited, not blanked: a user's own command
    # there survives a re-author (blanking is the fallback without a reader).
    hold = sorted(set(int(f) for f in _phase_frames) - frames)
    try:
        length = int(_self.get_movie_length())
    except Exception:
        length = 0
    done = []
    text = phase_command()
    for f in hold:
        if length > 0 and f > length:
            continue
        try:
            slot = _frame_command(f, _self)
        except Exception:
            frames.add(f)
            continue
        try:
            _self.mdo(f, slot.replace(';' + text, '').replace(text, ''))
            done.append(f)
        except Exception as e:
            print('MOVIE_ERR:' + str(e))
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
    return sorted(done)


def _wrap_length(wrap, _self):
    """Movie length for a wrapping movie, 0 if wrap is off or length <= 0."""
    if wrap is None:
        try:
            wrap = _truthy(_self.get('movie_loop'))
        except Exception:
            wrap = False
    if not wrap:
        return 0
    try:
        return max(0, int(_self.get_movie_length()))
    except Exception:
        return 0


def author(keyframes, _self=cmd, power=None, wrap=None):
    """Author the whole per-scene setting animation for a movie.

    `keyframes` is [(frame, scene_name, power)] for every scene keyframe in the
    movie, in any order (sorted internally by frame), each power being the one
    stored with that keyframe. `power` is the movie-wide easing override the path
    passed to cmd.mview('interpolate'/'reinterpolate') — 0/None means it passed
    none and the endpoints decide. `wrap` governs loop-wrap pseudo-transitions:
    None follows the `movie_loop` setting (like `mview interpolate`'s wrap=-1);
    True/False forces wrapping on or off (pass what the camera's interpolate used).
    Call AFTER the path's cmd.mset and cmd.mview('interpolate') so the movie
    length is final and the camera track is interpolated. Returns the number of
    frames touched.

    author([]) is the reset: it un-emits the previous pass and clears the track,
    so call it unconditionally — including on a rebuild that has no scenes at all,
    which would otherwise persist a stale animation into the new movie."""
    keyframes = list(keyframes)
    clear_authored(_self)             # BEFORE the reset: needs the old frame list
    _track.clear()
    _scene_marks[:] = []
    _lights_track.clear()
    _phase_frames[:] = []
    # #687: no phase from a previous movie survives into this one; the
    # frames below write their own.
    _set_phase(0.0, _self)
    wrap_length = _wrap_length(wrap, _self) if keyframes else 0
    marks = [(int(f), n) for f, n, _p in keyframes]
    track = build_track(keyframes, power, wrap_length=wrap_length)
    # DOF owns focus/aperture/enable wherever it applies, so it goes on LAST and
    # overrides the plain ramp (build_track's aperture ramp across a fade would
    # otherwise start from the disabled side's meaningless captured value).
    for f, vals in build_dof_transition(keyframes, _self, power, wrap_length=wrap_length).items():
        track.setdefault(f, {}).update(vals)
    _track.update(track)
    _scene_marks[:] = sorted(set(marks))
    # The rig blend (#617): read at play time, so it only records which
    # transitions to blend and where along each one the camera is.
    _lights_track.update(build_lights_track(keyframes, power, wrap_length=wrap_length))
    touched = set(emit_scene_marks(_scene_marks, _self))
    touched.update(emit_track(_track, _self))
    touched.update(emit_lights_track(_lights_track, _self))
    _phase_frames[:] = build_phase_frames(_scene_marks, _lights_track,
                                          _movie_length(_self))
    touched.update(emit_phase_frames(_phase_frames, _self))
    return len(touched)


def _frame_command(frame, _self=cmd):
    """The movie command text of `frame` as the core holds it (#655)."""
    getter = getattr(_self, 'get_frame_command', None)   # test doubles
    if getter is not None:
        return getter(int(frame))
    from pymol import _cmd
    return _cmd.get_frame_command(_self._COb, int(frame))


def rename_scene(old, new, _self=cmd):
    """Re-key the authored movie when scene `old` is renamed to `new` (#655).

    `_scene_marks` and `_lights_track` name scenes, and so does the frame
    command text emitted from them, so after a rename the movie would neither
    apply the scene at its keyframe nor blend into it. Re-key both, then edit
    each affected frame slot in place: only our own command pieces naming
    `old` are replaced, so a user's mdo/mappend text sharing the slot
    survives (a rename is not a re-author; clear_authored would blank whole
    slots). Without a slot reader (an older core: AttributeError) it falls
    back to clear_authored + re-emit; any other read error restores the
    state, writes nothing and propagates. Returns the number of frames
    touched (0 when nothing referenced `old`)."""
    if not old or not new or old == new:
        return 0
    in_marks = any(n == old for _f, n in _scene_marks)
    in_lights = any(old in (a, b) for a, b, _t in _lights_track.values())
    if not (in_marks or in_lights):
        return 0
    before = _our_commands()
    saved = (list(_scene_marks), dict(_lights_track))
    _scene_marks[:] = [(int(f), new if n == old else n) for f, n in _scene_marks]
    for f, (a, b, t) in list(_lights_track.items()):
        _lights_track[f] = (new if a == old else a, new if b == old else b, t)
    after = _our_commands()
    changed = [f for f in sorted(set(before) | set(after))
               if before.get(f) != after.get(f)]
    try:
        slots = {f: _frame_command(f, _self) for f in changed}
    except AttributeError:
        # An older core with no slot reader: the old trade-off (see
        # clear_authored), re-emitted whole. clear_authored only needs the
        # frame lists, which a rename does not change.
        clear_authored(_self)
        touched = set(emit_scene_marks(_scene_marks, _self))
        touched.update(emit_track(_track, _self))
        touched.update(emit_lights_track(_lights_track, _self))
        touched.update(emit_phase_frames(_phase_frames, _self))
        return len(touched)
    except Exception:
        # Any other read failure: nothing was written yet, so put the state
        # back and leave the movie as it was (the caller reports the error).
        _scene_marks[:] = saved[0]
        _lights_track.clear()
        _lights_track.update(saved[1])
        raise
    done = []
    for f in changed:
        slot = slots[f]
        for o, n in zip(before.get(f, []), after.get(f, [])):
            slot = slot.replace(o, n, 1) if o in slot else slot + ';' + n
        try:
            _self.mdo(f, slot)
            done.append(f)
        except Exception as e:
            print('MOVIE_ERR:' + str(e))
    return len(done)


def _our_commands():
    """{frame: [piece, ...]} for every frame command piece this module authored."""
    out = {}
    for f, name in _scene_marks:
        out.setdefault(int(f), []).append(scene_mark_command(name))
    for f, vals in _track.items():
        s = frame_command(vals)
        if s:
            out.setdefault(int(f), []).append(s)
    for f, (a, b, t) in _lights_track.items():
        out.setdefault(int(f), []).append(lights_command(a, b, t))
    for f in _phase_frames:
        out.setdefault(int(f), []).append(phase_command())
    return out


# --- .pse persistence (registered in cmd._deferred_init_pymol_internals) ---
def session_save(session, *, _self=cmd):
    """Persist the animation as STRUCTURED data and strip our own frame commands
    out of the saved movie.

    Stripping matters: any non-empty frame command makes session load call
    MovieSetLock (Movie.cpp:459-462), and MovieDoFrameCommand is gated on
    !Locked (Movie.cpp:1051) — so a locked movie loses its commands, its scene
    recall AND its camera track, and RayMol has no security-wizard UI to unlock
    it. We remove only OUR text so a co-located rock/nutate command survives.

    Note: this invariant holds only on the SAVE path. The re-author path uses
    clear_authored (mdo '', overwriting the whole slot) to blank previously-
    authored frames before re-emitting — that is intentional, not a bug; a
    re-author that only appended would pile new commands on top of stale ones
    and session_save could no longer strip what it cannot regenerate. See
    clear_authored for the full rationale."""
    payload = {
        'track': {str(f): dict(v) for f, v in _track.items()},
        'marks': [[int(f), n] for f, n in _scene_marks],
    }
    # Only when there is one, so a movie without rig blends saves exactly
    # what it did before (and older builds ignore the extra key anyway).
    if _lights_track:
        payload['lights'] = [[int(f), a, b, float(t)] for f, (a, b, t)
                             in sorted(_lights_track.items())]
    session['raymol_movie_anim'] = payload
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
    .pse cannot smuggle executable code through our session key.

    A partial restore leaves the live movie alone (#617): the core skips the
    session's movie and scenes then, so re-authoring its track would write a
    foreign animation into the movie that stays."""
    from pymol import raymol_scenes as _rs
    if _rs.restoring_partial(_self):
        return 1
    _track.clear()
    _scene_marks[:] = []
    _lights_track.clear()
    _phase_frames[:] = []
    d = session.get('raymol_movie_anim')
    if not isinstance(d, dict):
        return 1
    # What author() can actually emit -- an ALLOWLIST, not the whole CAPTURE
    # list minus the names that happen to look dangerous today.
    #
    # A track value used to be validated as "a name in CAPTURE + parses as a
    # float". CAPTURE is the set a scene SNAPSHOTS, which is much larger than
    # the set a movie can ramp, and it holds several settings that force a
    # rebuild on every write: the material ids (cRepInvColor on all four reps)
    # and, worse, surface_quality, which is cRepInvRep -- a full surface
    # re-tessellation. None can be produced by author(), but all were accepted
    # from a .pse, so a corrupted or hand-edited session could put one on every
    # interior frame and make playback rebuild the geometry per frame.
    # Validating against what the author emits closes all of them at once and
    # stays closed the next time CAPTURE grows.
    known = set(INTERPOLATE) | set(_DOF_EMITTED)
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
    _restore_lights_track(d.get('lights'), _self)
    emit_scene_marks(_scene_marks, _self)
    emit_track(_track, _self)
    emit_lights_track(_lights_track, _self)
    # The hold frames' phase writes (#687) are not saved: they follow from
    # the marks, the rig blends and the movie length.
    _phase_frames[:] = build_phase_frames(_scene_marks, _lights_track,
                                          _movie_length(_self))
    emit_phase_frames(_phase_frames, _self)
    return 1


def _restore_lights_track(raw, _self=cmd):
    """Read the saved rig-blend track into _lights_track. Each entry must be
    [frame, scene_a, scene_b, t]: an int frame >= 1 within the movie (bool
    refused; frames past the end are skipped, so a hostile payload cannot
    print a Movie-Error per frame), two str names (bytes refused) and a
    finite t in [0, 1]. Anything else is dropped. The command text is
    regenerated from these values, never read from the file."""
    if not isinstance(raw, (list, tuple)):
        return
    try:
        length = int(_self.get_movie_length())
    except Exception:
        length = None
    for ent in raw:
        if not isinstance(ent, (list, tuple)) or len(ent) != 4:
            continue
        f, a, b, t = ent
        if isinstance(f, bool) or not isinstance(f, int) or f < 1:
            continue
        if length is not None and f > length:
            continue
        if not isinstance(a, str) or not isinstance(b, str):
            continue
        if not _is_num(t) or not 0.0 <= t <= 1.0:
            continue
        _lights_track[f] = (a, b, float(t))


def enter_scene(name_b64, _self=cmd):
    """Movie-frame callback: make scene `name`'s captured render settings and
    autofocus target current. Restores every captured setting that DIFFERS (at a
    keyframe the scene's own values are by definition the correct endpoint, and
    re-asserting one that already matches costs a full rebuild for several of
    them) but deliberately NOT object TTT — the movie owns object motion through
    its own keyframes and re-applying would fight the interpolation."""
    try:
        name = base64.b64decode(name_b64).decode('utf-8')
    except Exception:
        return
    from pymol import raymol_scenes as _rs
    # The same conditional-write path a recall uses, not a second copy of the
    # loop. The material settings invalidate every representation on every
    # write, so re-asserting a scene's values unchanged at each keyframe rebuilt
    # cartoon, surface, stick and sphere geometry for every object -- twice per
    # scene, on every pass of a looping movie and on every frame of an export.
    try:
        # apply_settings reports a per-setting failure itself, so this only
        # catches something structural -- the scene having no payload at all.
        _rs.apply_settings(name, _self)
    except Exception as e:
        print('MOVIE_ERR:' + str(e))
    # ...then the per-object overrides, after the globals so an object's own
    # value wins over the fallback just written -- the same order a recall
    # uses (#508). Without this a movie replayed only the GLOBAL half of each
    # scene: in a marble -> clay movie every object changed material except
    # the ones the user had styled, which stayed frozen. Same conditional
    # writes as a recall, so an unchanged override costs nothing per frame.
    try:
        _rs.apply_object_settings(name, _self)
    except Exception as e:
        print('MOVIE_ERR:' + str(e))
    try:
        _rs.apply_focus_target(name, _self)
    except Exception:
        pass
    # ...and the scene's light rig, exactly (#617): the cut is where the
    # stepped fields (shadow, outline, anchor, aim, on/off) change. A scene
    # with no entry leaves the rig alone; a matching rig writes nothing.
    try:
        _rs.apply_lights(name, _self)
    except Exception:
        pass
    try:
        _write_phase(_self)
    except Exception:
        pass
