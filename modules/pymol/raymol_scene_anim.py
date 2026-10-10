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
re-authoring. blend_rigs starts from a copy of A, so every field steps at the
cut unless it is listed there: angles take the shortest path, colour
interpolates in linear RGB, pinned lights arc around the blended centre, and a
light in only one scene fades its intensity from or to 0. Rig on/off steps at
the cut. The track is saved as structured data under 'lights' (only when there
is one), stripped from the saved movie and regenerated on load like the rest.
Known limit: the loop-wrap span of a looping movie (camera flying from the
last scene back to the first) has no keyframe pair, so neither the settings
nor the rig blend there; the rig pops to the first scene's at frame 1.
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


def build_track(keyframes, power=None):
    """Per-frame interpolated values for the INTERIOR frames of each transition.

    `keyframes` is an ordered iterable of (frame, scene_name, power) where power is
    the one stored WITH that keyframe (as passed to mview store). `power` is the
    movie-wide override the path passed to mview interpolate/reinterpolate, if any.
    Both endpoints of a transition contribute — see effective_power.
    Returns {frame: {setting: float}}. Scene keyframes themselves are applied by
    enter_scene (exact captured values), so they are deliberately absent here,
    as is everything in _DOF_OWNED (build_dof_transition's territory)."""
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


def build_dof_transition(keyframes, _self=cmd, power=None):
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
    it on top of build_track, so these win. Must run AFTER cmd.mview
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
            try:
                _self.frame(f)
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
                out[f] = vals
    return out


# --- Light rig blend (#617) --------------------------------------------------
# Pure Python: no PyMOLGlobals, no cmd. The core clamps whatever set_lights
# receives, and every value here stays between its two (valid) endpoints.

# The rig's light cap (LightRig.h): a blend of two rigs never exceeds it.
_MAX_LIGHTS = 6

# Two pinned directions further apart than this are "opposite": the arc then
# turns about a fixed axis so the path is deterministic.
_ANTIPODAL = math.radians(179.9)

_RIG_AIR_LERP = ('haze', 'dust', 'dust_size', 'dust_speed', 'scatter')
_LIGHT_LERP = ('beam', 'softness', 'highlight', 'falloff', 'warmth',
               'intensity')


def _is_num(v):
    return (isinstance(v, (int, float)) and not isinstance(v, bool)
            and math.isfinite(v))


def _is_vec3(v):
    return (isinstance(v, (list, tuple)) and len(v) == 3
            and all(_is_num(x) for x in v))


def _lerp(a, b, e):
    return a + (b - a) * e


def _lerp3(a, b, e):
    return [_lerp(float(x), float(y), e) for x, y in zip(a, b)]


def _wrap180(x):
    """x wrapped into (-180, 180], untouched when already there (so an
    endpoint stays exact)."""
    if -180.0 < x <= 180.0:
        return x
    r = math.fmod(x + 180.0, 360.0)
    if r <= 0.0:
        r += 360.0
    return r - 180.0


def _lerp_angle(a, b, e):
    """Degrees, along the shortest path: the delta is wrapped into
    (-180, 180] and so is the result (160 -> -160 passes through 180)."""
    a = float(a)
    return _wrap180(a + _wrap180(float(b) - a) * e)


def _srgb_to_linear(c):
    """IEC 61966-2-1 decode of one channel in [0, 1]."""
    c = min(max(float(c), 0.0), 1.0)
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def _linear_to_srgb(v):
    """IEC 61966-2-1 encode of one channel in [0, 1]."""
    v = min(max(float(v), 0.0), 1.0)
    s = 12.92 * v if v <= 0.0031308 else 1.055 * v ** (1.0 / 2.4) - 0.055
    return min(max(s, 0.0), 1.0)


def _lerp_color(a, b, e):
    """sRGB colours interpolated in linear RGB (decode, lerp, encode), exact
    at both ends: red -> blue passes (0.735, 0, 0.735), not (0.5, 0, 0.5)."""
    if e <= 0.0:
        return [float(v) for v in a]
    if e >= 1.0:
        return [float(v) for v in b]
    return [_linear_to_srgb(_lerp(_srgb_to_linear(x), _srgb_to_linear(y), e))
            for x, y in zip(a, b)]


def _norm(v):
    return math.sqrt(sum(x * x for x in v))


def _cross(a, b):
    return [a[1] * b[2] - a[2] * b[1],
            a[2] * b[0] - a[0] * b[2],
            a[0] * b[1] - a[1] * b[0]]


def _slerp_offset(oa, ob, e):
    """An offset from a rig centre moving from `oa` to `ob`: the direction
    along the shortest great-circle arc, the distance lerped. Exact at both
    ends. Nearly opposite directions (> 179.9 degrees) turn about
    normalize(oa x y), or the x axis when oa is vertical, so the path is
    deterministic; a zero-length offset falls back to a straight lerp."""
    oa = [float(x) for x in oa]
    ob = [float(x) for x in ob]
    if e <= 0.0:
        return oa
    if e >= 1.0:
        return ob
    la, lb = _norm(oa), _norm(ob)
    if la < 1e-9 or lb < 1e-9:
        return _lerp3(oa, ob, e)
    ua = [x / la for x in oa]
    ub = [x / lb for x in ob]
    dot = min(max(sum(x * y for x, y in zip(ua, ub)), -1.0), 1.0)
    theta = math.acos(dot)
    if theta < 1e-6:
        d = ua
    elif theta > _ANTIPODAL:
        k = _cross(ua, [0.0, 1.0, 0.0])
        nk = _norm(k)
        k = [x / nk for x in k] if nk > 1e-6 else [1.0, 0.0, 0.0]
        # Rodrigues for an axis perpendicular to ua
        phi = theta * e
        kxu = _cross(k, ua)
        d = [u * math.cos(phi) + w * math.sin(phi) for u, w in zip(ua, kxu)]
    else:
        s = math.sin(theta)
        wa = math.sin((1.0 - e) * theta) / s
        wb = math.sin(e * theta) / s
        d = [wa * x + wb * y for x, y in zip(ua, ub)]
    dist = _lerp(la, lb, e)
    return [dist * x for x in d]


def rig_on(r):
    """Decision 15's "the rig is on" (raymol_scenes.rig_on): a dict that is
    enabled with at least one light."""
    from pymol import raymol_scenes as _rs
    return _rs.rig_on(r)


def _light_key(light):
    """Lights match by name ignoring case: the rig's own uniqueness rule."""
    return str(light.get('name', '')).lower()


def _blend_light(la, lb, e, ca, cb, c):
    """A light present in both rigs, starting from A's (every field steps
    unless it is listed here)."""
    out = copy.deepcopy(la)
    for k in _LIGHT_LERP:
        if _is_num(la.get(k)) and _is_num(lb.get(k)):
            out[k] = _lerp(float(la[k]), float(lb[k]), e)
    if _is_vec3(la.get('color')) and _is_vec3(lb.get('color')):
        out['color'] = _lerp_color(la['color'], lb['color'], e)
    anchor_a = la.get('anchor', 'camera')
    anchor_b = lb.get('anchor', 'camera')
    if anchor_a == 'camera' and anchor_b == 'camera':
        if _is_num(la.get('orbit')) and _is_num(lb.get('orbit')):
            out['orbit'] = _lerp_angle(la['orbit'], lb['orbit'], e)
        for k in ('pitch', 'radius'):
            if _is_num(la.get(k)) and _is_num(lb.get(k)):
                out[k] = _lerp(float(la[k]), float(lb[k]), e)
    elif anchor_a == 'pinned' and anchor_b == 'pinned':
        pa, pb = la.get('position'), lb.get('position')
        if _is_vec3(pa) and _is_vec3(pb):
            if e <= 0.0:
                out['position'] = [float(x) for x in pa]
            elif c is not None:
                # Pins are fixed in world space (decision 17): arc around the
                # blended centre so the light never cuts through the molecule.
                off = _slerp_offset([p - q for p, q in zip(pa, ca)],
                                    [p - q for p, q in zip(pb, cb)], e)
                out['position'] = [q + o for q, o in zip(c, off)]
            else:
                out['position'] = _lerp3(pa, pb, e)
    if la.get('aim') == 'point' and lb.get('aim') == 'point':
        if _is_vec3(la.get('aim_point')) and _is_vec3(lb.get('aim_point')):
            out['aim_point'] = _lerp3(la['aim_point'], lb['aim_point'], e)
    return out


def blend_rigs(a, b, e):
    """Rig dicts `a` and `b` (both on) blended at eased position `e`.

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
    e = float(e)
    out = copy.deepcopy(a)
    out['enabled'] = True
    ca, cb = a.get('centre'), b.get('centre')
    c = None
    if (_is_vec3(ca) and _is_vec3(cb) and _is_num(a.get('size'))
            and _is_num(b.get('size'))):
        c = _lerp3(ca, cb, e)
        out['centre'] = c
        out['size'] = _lerp(float(a['size']), float(b['size']), e)
    for k in ('ambient', 'classic'):
        if _is_num(a.get(k)) and _is_num(b.get(k)):
            out[k] = _lerp(float(a[k]), float(b[k]), e)
    air_a, air_b = a.get('air'), b.get('air')
    if isinstance(air_a, dict) and isinstance(air_b, dict):
        air = out['air']
        for k in _RIG_AIR_LERP:
            if _is_num(air_a.get(k)) and _is_num(air_b.get(k)):
                air[k] = _lerp(float(air_a[k]), float(air_b[k]), e)

    lights_a = [l for l in (a.get('lights') or []) if isinstance(l, dict)]
    lights_b = [l for l in (b.get('lights') or []) if isinstance(l, dict)]
    by_key_b = {}
    for l in lights_b:
        by_key_b.setdefault(_light_key(l), l)
    keys_a = set(_light_key(l) for l in lights_a)
    entries = []        # [(light, one_sided)]
    for l in lights_a:
        m = by_key_b.get(_light_key(l))
        if m is not None:
            entries.append((_blend_light(l, m, e, ca, cb, c), False))
        else:
            d = copy.deepcopy(l)
            if _is_num(d.get('intensity')):
                d['intensity'] = float(d['intensity']) * (1.0 - e)
            entries.append((d, True))
    for l in lights_b:
        if _light_key(l) in keys_a:
            continue
        d = copy.deepcopy(l)
        if _is_num(d.get('intensity')):
            d['intensity'] = float(d['intensity']) * e
        d['shadow'] = False
        d['outline'] = False
        entries.append((d, True))
    excess = len(entries) - _MAX_LIGHTS
    if excess > 0:
        one_sided = [i for i, (_d, one) in enumerate(entries) if one]

        def dimmest(i):
            v = entries[i][0].get('intensity')
            return (float(v) if _is_num(v) else 0.0, -i)

        drop = set(sorted(one_sided, key=dimmest)[:excess])
        entries = [x for i, x in enumerate(entries) if i not in drop]
    out['lights'] = [d for d, _one in entries]
    return out


def blend_target(ra, rb, t):
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
        return blend_rigs(ra, rb, t)
    return copy.deepcopy(ra)


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


def lights_command(a, b, t):
    """The frame command for position `t` from scene `a` to `b`. Names are
    UTF-8 hex: [0-9a-f] only, so no quote, ',', ';' or '=' reaches the
    parser (base64's '=' padding would read as a keyword argument)."""
    return '_lights_blend %s, %s, %s' % (_name_hex(a), _name_hex(b), _fmt(t))


def build_lights_track(keyframes, power=None):
    """{frame: (scene_a, scene_b, t)} for the interior frames of every
    transition between two DISTINCT scenes, at least one of which holds a rig
    entry now ('off' or a dict). `t` is the camera's eased position (the
    easing build_track uses), stored pre-rounded so a restore regenerates the
    same command text."""
    from pymol import raymol_scenes as _rs
    track = {}
    kfs = sorted(keyframes, key=lambda k: int(k[0]))
    for (f0, n0, p0), (f1, n1, p1) in zip(kfs, kfs[1:]):
        f0, f1 = int(f0), int(f1)
        span = f1 - f0
        if span < 2 or n0 == n1:
            continue
        if _rs.scene_lights(n0) is None and _rs.scene_lights(n1) is None:
            continue
        pw = effective_power(p0, p1, power)
        for f in range(f0 + 1, f1):
            t = float(_fmt(ease((f - f0) / float(span), pw)))
            track[f] = (n0, n1, t)
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
        target = blend_target(_rs.scene_lights(a), _rs.scene_lights(b), t)
        if target is None:
            return
        _rs._apply_lights_target(target, _self, report=a)
    except Exception:
        pass


# The animation authored into the CURRENT movie, regenerated on every rebuild.
# {frame: {setting: float}} for interior transition frames...
_track = {}
# ...and [(frame, scene_name)] for the scene keyframes carrying enter_scene...
_scene_marks = []
# ...and {frame: (scene_a, scene_b, t)} for the rig blend's _lights_blend.
_lights_track = {}


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
    _lights_track.clear()
    marks = [(int(f), n) for f, n, _p in keyframes]
    track = build_track(keyframes, power)
    # DOF owns focus/aperture/enable wherever it applies, so it goes on LAST and
    # overrides the plain ramp (build_track's aperture ramp across a fade would
    # otherwise start from the disabled side's meaningless captured value).
    for f, vals in build_dof_transition(keyframes, _self, power).items():
        track.setdefault(f, {}).update(vals)
    _track.update(track)
    _scene_marks[:] = sorted(set(marks))
    # The rig blend (#617): read at play time, so it only records which
    # transitions to blend and where along each one the camera is.
    _lights_track.update(build_lights_track(keyframes, power))
    touched = set(emit_scene_marks(_scene_marks, _self))
    touched.update(emit_track(_track, _self))
    touched.update(emit_lights_track(_lights_track, _self))
    return len(touched)


def rename_scene(old, new, _self=cmd):
    """Re-key authored movie tracks when a scene is renamed (issue #655).

    `_scene_marks` and `_lights_track` record scene names so the movie can
    recall a scene at its keyframe and blend rigs during transitions. When a
    scene is renamed, stale names would leave the movie applying missing scenes
    or failing rig blends.

    If `old` appears in `_scene_marks` or either scene slot of `_lights_track`:
    clears previously authored frames, replaces `old` with `new` in
    `_scene_marks` and `_lights_track` (keeping frames and `t`), and re-emits
    scene marks, settings track, and lights blend track. Otherwise does
    nothing (no mdo calls). Returns the number of frames touched (0 when
    nothing referenced `old`).
    """
    if not old or not new or old == new:
        return 0
    in_marks = any(n == old for _f, n in _scene_marks)
    in_lights = any(a == old or b == old for a, b, _t in _lights_track.values())
    if not (in_marks or in_lights):
        return 0

    clear_authored(_self)
    _scene_marks[:] = [(int(f), new if n == old else n) for f, n in _scene_marks]
    for f, (a, b, t) in list(_lights_track.items()):
        _lights_track[f] = (new if a == old else a, new if b == old else b, t)
    touched = set(emit_scene_marks(_scene_marks, _self))
    touched.update(emit_track(_track, _self))
    touched.update(emit_lights_track(_lights_track, _self))
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
    for f, (a, b, t) in _lights_track.items():
        out.setdefault(int(f), []).append(lights_command(a, b, t))
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
