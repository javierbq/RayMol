"""Playback / movie query + authoring for the native SwiftUI app.

Emits one feedback line `PLAYBACK:<json>` that PyMOLEngine.parsePlaybackFeedback()
consumes to drive the Timeline transport bar (frame counter, scrubber, play state,
loop, fps). In PyMOL, NMR models, MD-trajectory frames and movie frames are all the
SAME thing — a 1-based movie frame index that maps (via mset) to a coordinate state
— so a single `frame`/`count_frames` pair drives every case.

Playback itself is CORE-driven: the Swift layer calls cmd.mplay()/cmd.mstop() and
the renderer's idle tick (SceneIdle, run every Metal frame) advances frames at
movie_fps, honoring movie_loop and firing any mview/mdo keyframe commands. The
Swift layer only scrubs (cmd.frame) and mirrors this state for the UI.

Kept as a bundled module (not an inline Swift string) so it stays readable and
testable. Mirrors the appkit_inspector.poll pattern.
"""

import contextlib
import copy

from pymol import cmd


def _drop_scene_animation():
    """Forget the per-scene setting animation authored into the OLD movie. Must
    run BEFORE the mset that discards it: author([]) blanks the frame commands it
    owns (while those slots still exist) and clears its track, so the animation
    cannot be persisted into — or re-authored on top of — an unrelated movie."""
    try:
        from pymol import raymol_scene_anim as _an
        _an.author([])
    except Exception as e:
        print('MOVIE_ERR:' + str(e))


def reset_movie():
    """Clear the movie timeline (frame sequence + camera keyframes) and rewind."""
    try:
        _drop_scene_animation()
        cmd.mview('reset')
        cmd.mset('')
        cmd.rewind()
    except Exception as e:
        print('MOVIE_ERR:' + str(e))


def new_timeline(frames):
    """Create a blank camera movie canvas of `frames` frames (mset), so manually
    stored camera keyframes have a timeline to interpolate across. Every frame
    shows state 1. Rewinds to the start."""
    try:
        n = max(2, int(frames))
        _drop_scene_animation()
        cmd.mview('reset')
        cmd.mset('1 x%d' % n)
        cmd.rewind()
    except Exception as e:
        print('MOVIE_ERR:' + str(e))


def _ease(linear):
    """(power, linear) mview args for the Smooth/Linear choice. linear=1 →
    constant-speed straight motion; linear=0 → eased, curved motion (the
    smooth default)."""
    v = 1.0 if int(linear) else 0.0
    return v, v


def _multistate_objects(names=None):
    """{objname: nstates} for objects with >1 coordinate state. `names` (list)
    restricts to those objects, a group standing for every object inside it
    (a CGO or a map too, not only molecules: a store through the group used to
    reach them all); None = every molecule in the session."""
    out = {}
    try:
        objs = names if names else cmd.get_object_list()
    except Exception:
        objs = []
    expanded = []
    for o in (objs or []):
        try:
            if names and cmd.get_type(o) == 'object:group':
                expanded += [m for m in sorted(_group_members([o], cmd))
                             if cmd.get_type(m) != 'object:group']
                continue
        except Exception:
            pass
        expanded.append(o)
    for o in expanded:
        try:
            ns = int(cmd.count_states(o))
            if ns > 1:
                out[o] = ns
        except Exception:
            pass
    return out


def _store_state_track(obj, pts, total, scene_keys=None):
    """Store `obj`'s own STATE track: the model keyframes `pts` ({frame: model}),
    held from frame 1 and to frame `total`, linear in between as the core
    interpolates them. The per-object ViewElem sets the object's own `state` at
    render, independent of the mset and of other objects.

    Frames 1 and `total` are always keyed, so interpolating has no loop seam to
    fill: with movie_loop on it wraps from the last key back round to the
    first, which ran the models backwards through a Roll placed before a
    Play-models clip. Every keyframe of an object's track carries both a model
    and a Move-mode matrix (`mview store, object=` writes the object's current
    TTT, and without state= it flags the object's own `state` setting). So the
    frames the scenes keyed for it (`scene_keys`, {frame: that scene's TTT, None
    for unmoved}) are stored again with the model the track has there, and
    every keyframe gets the TTT of the scene key at or before it (the first
    one, before any): a hold keeps the scenes' positions, and a scene key no
    longer carries a stale model in between the track's keys. A key strictly
    between two scenes that move the object holds the earlier scene's position
    there, so that move happens after the key rather than across the whole
    transition.

    movie_auto_store is off while the keys are stored: with a movie defined,
    set_object_ttt would also store a keyframe, with no model, at the current
    frame (the last item rebuild visited), breaking the model ramp across it,
    and reinterpolate every track each time. The track is then reinterpolated
    whole: a plain interpolate refills only never-filled frames, and the scene
    pass has filled them all."""
    import bisect
    try:
        total = max(int(total), 2)
        pts = {int(f): int(m) for f, m in pts.items()}
        if not pts:
            return
        fs = sorted(pts)
        pts.setdefault(1, pts[fs[0]])
        pts.setdefault(total, pts[fs[-1]])
        fs = sorted(pts)
        keys = {int(f): t for f, t in (scene_keys or {}).items() if 1 <= int(f) <= total}
        ks = sorted(keys)
        identity = None
        if ks:
            from pymol.raymol_scenes import _IDENTITY_TTT as identity

        def model_at(f):
            if f in pts:
                return pts[f]
            i = bisect.bisect(fs, f)
            a, b = fs[i - 1], fs[i]
            return max(1, int(round(pts[a] + (pts[b] - pts[a]) * (f - a) / float(b - a))))

        with _no_auto_store():
            for f in sorted(set(fs) | set(ks)):
                if ks:
                    i = bisect.bisect(ks, f)
                    ttt = keys[ks[i - 1] if i else ks[0]]
                    cmd.set_object_ttt(obj, list(ttt) if ttt else list(identity))
                cmd.mview('store', object=obj, first=f, state=model_at(f), freeze=1)
        cmd.mview('reinterpolate', object=obj, wrap=0)
    except Exception as ex:
        print('MOVIE_ERR:' + str(ex))


class _no_auto_store(object):
    """movie_auto_store off for the duration, restored exactly: its default is
    -1, which `set` would turn into 1, so the default is put back by unset."""

    def __enter__(self):
        self.was = cmd.get_setting_int('movie_auto_store')
        cmd.set('movie_auto_store', 0)

    def __exit__(self, *exc):
        if self.was == -1:
            cmd.unset('movie_auto_store')
        else:
            cmd.set('movie_auto_store', self.was)
        return False


def _share_scene_steps(scene_keys, state_clips, pins, total):
    """Stopgap (#920): a model track keys frames the scenes don't (a clip's
    ends and Loop midpoint, a hold, a camera item's pin), and such a key inside
    a scene transition holds the earlier scene's position (_store_state_track).
    Key every object the scenes really move (two different positions) at all of
    those frames, with that same step, in `scene_keys` ({obj: {frame: TTT}}),
    so objects moved together, an ensemble and its ligand, keep together.
    Keeping the interpolated move exactly needs the core to interpolate models
    apart from positions (#920)."""
    import bisect
    total = max(int(total), 2)
    frames = {1, total}
    for clip in state_clips:
        s = int(clip['frame'])
        e = int(clip.get('end', total))
        frames.update((s - 1, s, (s + e) // 2, e))
    for ps in pins.values():
        frames.update(int(f) for f, _ in ps)
    for keys in scene_keys.values():
        if len({tuple(t) if t else None for t in keys.values()}) < 2:
            continue
        ks = sorted(keys)
        for f in frames:
            if 1 <= f <= total and f not in keys:
                i = bisect.bisect(ks, f)
                keys[f] = keys[ks[i - 1] if i else ks[0]]


def _hold_scene_positions(obj, total, scene_keys):
    """Stopgap (#920): hold an object the scenes move but no model track keys
    (a one-state object, say) on the first scene's position before its first
    scene key and the last scene's after its last, as _store_state_track does
    for the ensembles, instead of gliding round the loop seam, and key it at
    the frames _share_scene_steps added like them; a ligand moved with its
    ensemble would otherwise come apart from it. The camera still wraps."""
    try:
        total = max(int(total), 2)
        keys = {int(f): t for f, t in (scene_keys or {}).items() if 1 <= int(f) <= total}
        if not keys:
            return
        from pymol.raymol_scenes import _IDENTITY_TTT as identity
        ks = sorted(keys)
        keys.setdefault(1, keys[ks[0]])
        keys.setdefault(total, keys[ks[-1]])
        with _no_auto_store():
            for f in sorted(keys):
                t = keys[f]
                cmd.set_object_ttt(obj, list(t) if t else list(identity))
                cmd.mview('store', object=obj, first=f, freeze=1)
        cmd.mview('reinterpolate', object=obj, wrap=0)
    except Exception as ex:
        print('MOVIE_ERR:' + str(ex))


def _emit_state_clips(obj, clips, total, scene_keys=None):
    """`obj`'s STATE track for its Sweep and Loop clips, (start, end, lo, hi,
    mode): models lo..hi across movie frames [start, end] ('loop' going back to
    lo by the end), and a model held on every other frame: the first clip's
    first model before it, and a clip's last model until the next clip starts
    or the movie ends. Keys at the clips' own ends alone left the frames outside
    them to the core: unkeyed frames keep whatever model was last applied, and
    the loop wrap ran them backwards (see _store_state_track)."""
    try:
        pts = {}
        first_lo = last_state = last_end = None
        for s, e, lo, hi, mode in sorted(clips, key=lambda c: int(c[0])):
            s = int(s); e = int(e); lo = int(lo); hi = int(hi)
            if e <= s:
                e = s + 1
            if hi < lo:
                lo, hi = hi, lo
            if first_lo is None:
                first_lo = lo
            elif s - 1 > last_end:
                pts[s - 1] = last_state      # hold until this clip starts
            pts[s] = lo
            if mode == 'loop':
                pts[(s + e) // 2] = hi
                pts[e] = last_state = lo
            else:
                pts[e] = last_state = hi
            last_end = e
        if first_lo is None:
            return
        pts.setdefault(1, first_lo)
        _store_state_track(obj, pts, total, scene_keys)
    except Exception as ex:
        print('MOVIE_ERR:' + str(ex))


def _reset_object_motions():
    """Drop every object's own mview track. `mview reset` alone clears only the
    camera track, so per-object state/matrix keyframes from the previous build
    would survive at frames the new build doesn't overwrite (e.g. a hold pinned
    at frame 41 bleeding into a shorter lane). The authoring paths here own
    those tracks and re-emit them on every build."""
    for o in cmd.get_object_list() or []:
        try:
            cmd.mview('reset', object=o)
        except Exception:
            pass


def _current_states():
    """{objname: model shown now} for every multi-state object. Reads the
    object's own `state` (which falls back to the global state when unset), so
    a model picked in the Object panel is honored as well as `set state, N`."""
    out = {}
    for o, n in _multistate_objects().items():
        try:
            s = int(cmd.get('state', o))
        except Exception:
            continue
        out[o] = max(1, min(s, n))
    return out


def _emit_state_hold(obj, pins, total, scene_keys=None):
    """Hold `obj` on the models it was pinned to (#579): per-object STATE
    keyframes at each (frame, state) in `pins`, extended to frames 1 and `total`
    so the object never falls back to the global mset (model 1) before the first
    pin or after the last. Equal pins interpolate to a constant model; unequal
    ones move between them like any other keyframed channel."""
    try:
        pts = {}
        for f, s in pins:
            pts[int(f)] = int(s)
        _store_state_track(obj, pts, total, scene_keys)
    except Exception as ex:
        print('MOVIE_ERR:' + str(ex))


def reset_ensemble():
    """Drop all movie authoring and rewind so a multi-state object plays its raw
    models again (count_frames falls back to the state count)."""
    try:
        _drop_scene_animation()
        cmd.mview('reset')
        cmd.mset('')
        cmd.rewind()
    except Exception as e:
        print('MOVIE_ERR:' + str(e))


def capture_keyframe(linear=0):
    """Store a camera keyframe at the current frame and (re)interpolate all
    stored keyframes with the chosen easing. 'reinterpolate' redoes every
    segment so the easing is applied consistently — plain 'interpolate' only
    fills gaps and would ignore a later Smooth/Linear change."""
    try:
        power, lin = _ease(linear)
        cmd.mview('store')
        cmd.mview('reinterpolate', power=power, linear=lin)
    except Exception as e:
        print('MOVIE_ERR:' + str(e))


def clear_keyframe(frame, linear=0):
    """Remove the stored camera keyframe at `frame` and re-interpolate the
    remaining keyframes with the chosen easing."""
    try:
        f = int(frame)
        power, lin = _ease(linear)
        cmd.mview('clear', first=f, last=f)
        cmd.mview('reinterpolate', power=power, linear=lin)
    except Exception as e:
        print('MOVIE_ERR:' + str(e))


def _movie_keyframes(_self=cmd):
    """[(frame, scene_name_or_None, power)] for every stored camera keyframe
    (ViewElem specification_level 2), in frame order (1-based), read from the
    core's movie ViewElem list. The core only exports that list with a
    session, so this exports one limited to an empty hidden selection (a names
    pattern that matches nothing would serialize every object). Nothing is
    displayed: the playhead and the live settings are untouched.

    The name is the scene the core tagged the keyframe with. Note that a plain
    `mview store` tags it with the scene current at that moment, and playback
    then recalls that scene there, so such a keyframe counts as a scene marker
    too. `power` is the keyframe's stored easing power, 0.0 when none is
    stored. Returns [] on any failure or when there is no movie."""
    try:
        d = {}
        # an unused name: never overwrite (and then delete) a user's object
        probe = _self.get_unused_name('_raymol_kf_probe')
        try:
            _self.select(probe, 'none', enable=0)
            with _self.lockcm:
                _self._cmd.get_session(_self._COb, d, probe, 0, 1)
        finally:
            try:
                _self.delete(probe)
            except Exception:
                pass
        movie = d.get('movie')
        if not movie or len(movie) < 7:
            return []
        elems = movie[6]
        if not elems or not isinstance(elems, list):
            return []
        out = []
        for i, v in enumerate(elems):
            if v and len(v) > 12 and v[12] == 2:
                scene = v[14] if (len(v) > 14 and v[13] and isinstance(v[14], str) and v[14]) else None
                # v[16] is exported only with ortho_flag, which SceneToViewElem
                # always sets on a stored keyframe
                power = 0.0
                if len(v) > 16 and v[15] and isinstance(v[16], (int, float)):
                    power = float(v[16])
                out.append((i + 1, scene, power))
        return out
    except Exception:
        return []


def _scene_keyframes(_self=cmd):
    """[(frame, scene_name, power)] for every scene-tagged keyframe currently on
    the timeline, read from the core's ViewElem list. It reports the MARKER
    frames; the old scrub of scene_current_name reported where the camera
    interpolation cuts between scenes (halfway, by mview's default cut), so the
    blends finished halfway through the camera move (#659).

    Each power is the one stored with that keyframe (0.0 = none stored), so
    raymol_scene_anim.author resolves the easing exactly like the core does
    for the callers' movie-wide `mview reinterpolate power=` (endpoint powers
    of, say, a Timeline rebuild survive a later place_scene)."""
    return [(f, name, p) for f, name, p in _movie_keyframes(_self) if name]


def _scene_wrap(_self=cmd):
    """None (follow movie_loop, like the camera's wrap=-1) when the movie has at
    least one stored keyframe and both the first and last stored keyframes from
    _movie_keyframes are scene markers; otherwise False (the camera would wrap
    to or from a non-scene keyframe, so the settings must not wrap, #656, #659)."""
    kfs = _movie_keyframes(_self)
    if kfs and kfs[0][1] and kfs[-1][1]:
        return None
    return False


def place_scene(frame, name, linear=0):
    """Place scene `name` as a timeline marker at `frame`. Moves the playhead
    there, recalls the scene (so the live camera == the scene's camera), then
    stores an mview keyframe TAGGED with the scene and reinterpolates. Because
    it is an mview keyframe the camera interpolates into/out of it; because it
    carries scene= the scene's reps/colors cut in at playback (PyMOL's native
    scene-movie behaviour)."""
    try:
        n = int(frame)
        power, lin = _ease(linear)
        cmd.frame(n)                 # playhead to n first (applies interpolation)
        # Recall only to READ the scene into the live view for the keyframe:
        # suspended, so the Python hook does not apply its settings and
        # per-object overrides to the live session (#508) -- enter_scene
        # replays those at playback.
        # `mview store ... scene=` recalls the scene again itself, so it belongs
        # inside the same suspension.
        from pymol import raymol_scenes as _rs
        with _rs.suspended():
            cmd.scene(name, 'recall')    # now the live view+reps ARE the scene
            cmd.mview('store', first=n, scene=name)
        try:
            motion = _rs.emit_object_motion(name, n)
        except Exception:
            motion = []
        cmd.mview('reinterpolate', power=power, linear=lin)
        for obj in dict.fromkeys(motion):
            try:
                cmd.mview('interpolate', object=obj)
            except Exception:
                pass
        # Re-author the setting animation across the WHOLE movie: a single dropped
        # marker changes the transitions on both sides of it. `power` is the same
        # easing override just handed to reinterpolate (1.0 = Linear), so the
        # settings ease exactly like the camera.
        try:
            from pymol import raymol_scene_anim as _an
            # Settings wrap only when the camera wraps scene to scene (#656, #659).
            _an.author(_scene_keyframes(), power=power, wrap=_scene_wrap())
        except Exception as e:
            print('MOVIE_ERR:' + str(e))
    except Exception as e:
        print('MOVIE_ERR:' + str(e))


def move_keyframe(old, new, linear=0):
    """Re-time a plain camera keyframe from frame `old` to frame `new`, keeping
    its stored view. Reads the view at the old keyframe, clears it, and re-stores
    that view at the new frame, then reinterpolates."""
    try:
        o = int(old); n = int(new)
        if o == n:
            return
        power, lin = _ease(linear)
        cmd.frame(o)                       # at an exact keyframe get_view == stored view
        v = cmd.get_view()
        cmd.mview('clear', first=o, last=o)
        cmd.frame(n)                       # interpolation at n (from remaining keyframes)
        cmd.set_view(v)                    # override with the moved keyframe's view
        cmd.mview('store', first=n)
        cmd.mview('reinterpolate', power=power, linear=lin)
    except Exception as e:
        print('MOVIE_ERR:' + str(e))


def move_scene_marker(old, name, new, linear=0):
    """Re-time a scene marker from frame `old` to frame `new`. Clears the old
    keyframe and re-places the scene at the new frame (see place_scene)."""
    try:
        o = int(old)
        cmd.mview('clear', first=o, last=o)
        place_scene(new, name, linear)
    except Exception as e:
        print('MOVIE_ERR:' + str(e))


def make_movie(kind, duration=12.0, angle=30.0, axis='y', loop=1,
               factor=1, pause=2.0, scenes=None, reset=1):
    """Author a movie via the high-level movie.add_* builders (the desktop
    'Movie > Program' builders). kind: roll | rock | nutate | state_loop |
    state_sweep | scenes. When reset, clears the existing timeline first so the
    result is a clean single-motion movie. Leaves the playhead at frame 1."""
    from pymol import movie
    try:
        # Camera motions hold the models showing now (#579); the builders' own
        # `mset 1 xN` would otherwise drop every ensemble to model 1.
        held = _current_states() if str(kind) in ('roll', 'rock', 'nutate') else {}
        if int(reset):
            cmd.mview('reset')
            _reset_object_motions()
            cmd.mset('')
        k = str(kind)
        loop = int(loop)
        if k == 'roll':
            movie.add_roll(duration=float(duration), loop=loop, axis=str(axis))
        elif k == 'rock':
            movie.add_rock(duration=float(duration), angle=float(angle),
                           loop=loop, axis=str(axis))
        elif k == 'nutate':
            movie.add_nutate(duration=float(duration), angle=float(angle), loop=loop)
        elif k == 'state_loop':
            movie.add_state_loop(factor=int(factor), pause=float(pause), loop=loop)
        elif k == 'state_sweep':
            movie.add_state_sweep(factor=int(factor), pause=float(pause), loop=loop)
        elif k == 'scenes':
            names = scenes if scenes else None
            # add_scenes stores each scene with `mview store ... scene=`, which
            # recalls it: read, not apply (#508), like the other authoring paths.
            from pymol import raymol_scenes as _rs
            with _rs.suspended():
                movie.add_scenes(names=names, pause=float(pause), loop=loop)
        total = cmd.count_frames()
        for obj, s in held.items():
            _emit_state_hold(obj, [(1, s)], total)
        cmd.rewind()
    except Exception as e:
        print('MOVIE_ERR:' + str(e))


def append_template(kind, duration=8.0, axis='y', angle=30.0,
                    seconds_per_scene=4.0, scenes=None, factor=1):
    """APPEND a template to the END of the current timeline (never clears), so
    the movie is composed by stacking templates. Places the keyframes itself at
    deterministic frames — the Swift TimelinePanel computes the SAME frames to
    draw the camera diamonds / scene markers (keep the two in sync):

      roll : camera keyframes at [start+1, +n/3, +2n/3, start+n], 360 spin
      rock : camera keyframes at [start+1, +n/4, +3n/4, start+n], +/-angle
      scenes : a scene marker (mview store, scene=) every seconds_per_scene
      state_loop/sweep : cycle object states (no camera/scene markers)

    `start` is the current frame count (0 when there's no movie yet, so the
    first template starts at frame 1). Uses `madd` to extend without disturbing
    existing keyframes."""
    try:
        fps = cmd.get_setting_float('movie_fps') or 30.0
        cur = cmd.count_frames()
        start = 0 if cur <= 1 else cur

        def ensure(nn):
            if start == 0:
                cmd.mset('1 x%d' % nn)
            else:
                cmd.madd('1 x%d' % nn)

        k = str(kind)
        if k in ('roll', 'rock'):
            n = max(2, int(round(duration * fps)))
            ensure(n)
            v = cmd.get_view()
            if k == 'roll':
                frames = [start + 1, start + 1 + n // 3, start + 1 + (2 * n) // 3, start + n]
                turns = [0, 120, 240, 360]
            else:
                frames = [start + 1, start + 1 + n // 4, start + 1 + (3 * n) // 4, start + n]
                turns = [0, float(angle), -float(angle), 0]
            for f, deg in zip(frames, turns):
                cmd.frame(f)
                cmd.set_view(v)
                if deg:
                    cmd.turn(str(axis), float(deg))
                cmd.mview('store', first=f)
            cmd.mview('reinterpolate', power=0.0, linear=0.0)

        elif k == 'scenes':
            names = [x for x in (scenes if scenes else cmd.get_scene_list()) if x]
            if names:
                per = max(2, int(round(float(seconds_per_scene) * fps)))
                ensure(per * len(names))
                motion = []
                for i, nm in enumerate(names):
                    f = start + 1 + i * per
                    cmd.frame(f)
                    from pymol import raymol_scenes as _rs
                    with _rs.suspended():   # read, not apply (#508)
                        cmd.scene(nm, 'recall')
                        cmd.mview('store', first=f, scene=nm)   # recalls too
                    try:
                        from pymol import raymol_scenes as _rs
                        motion += _rs.emit_object_motion(nm, f)
                    except Exception:
                        pass
                cmd.mview('reinterpolate', power=0.0, linear=0.0)
                for obj in dict.fromkeys(motion):
                    try:
                        cmd.mview('interpolate', object=obj)
                    except Exception:
                        pass
                # Author from ALL markers currently on the timeline (not just the
                # ones this batch placed). _scene_keyframes() reads every
                # scene-tagged keyframe from the core ViewElem list, so calling
                # append_template a second time does not wipe the first batch's
                # animation: author runs once over the union, not twice over
                # disjoint sets.
                # Unconditional: author([]) is the reset when names is empty;
                # guarding would leave a previous movie's animation live in the
                # module for the non-scenes path.
                try:
                    from pymol import raymol_scene_anim as _an
                    # Settings wrap only when the camera wraps scene to scene (#656, #659).
                    _an.author(_scene_keyframes(), wrap=_scene_wrap())
                except Exception as e:
                    print('MOVIE_ERR:' + str(e))

        elif k in ('state_loop', 'state_sweep'):
            maxs = 1
            for o in cmd.get_object_list():
                try:
                    maxs = max(maxs, cmd.count_states(o))
                except Exception:
                    pass
            if maxs > 1:
                fac = max(1, int(factor))
                seq = list(range(1, maxs + 1))
                if k == 'state_sweep':
                    seq = seq + list(range(maxs - 1, 1, -1))
                spec = ' '.join(str(s) for s in seq for _ in range(fac))
                if start == 0:
                    cmd.mset(spec)
                else:
                    cmd.madd(spec)

        cmd.rewind()
    except Exception as e:
        print('MOVIE_ERR:' + str(e))


# --- Unified single-track timeline ------------------------------------------
#
# The docked TimelinePanel edits ONE ordered lane of "objects" (camera keyframes
# + scene markers) joined by transitions (duration + easing). Swift owns the
# order/timing/easing (the things the UI edits); Python owns the heavy camera
# view matrices, keyed by the item's UUID. On every edit Swift calls rebuild()
# with the ordered spec and we lay a fresh movie. Alongside each view we keep
# the model every multi-state object showed when the item was captured (#579),
# so a camera item holds that model instead of sweeping the ensemble.
#
# Swift also stages its editable item list here (stage_timeline) so the lane
# rides in the .pse under `raymol_timeline` with the views it needs (#901).

_views = {}
_states = {}   # cam UUID -> {objname: state} at capture time
_timeline = None   # the item list Swift staged last; None = empty lane

SESSION_KEY = 'raymol_timeline'


def capture_view(cam_id):
    """Store the current camera view under `cam_id` (a camera item's UUID)."""
    try:
        _views[str(cam_id)] = list(cmd.get_view())
        _states[str(cam_id)] = _current_states()
    except Exception as e:
        print('MOVIE_ERR:' + str(e))


def forget_view(cam_id):
    """Drop the stored view for a deleted camera item."""
    _views.pop(str(cam_id), None)
    _states.pop(str(cam_id), None)


def forget_all_views():
    """Drop every stored camera view and the staged lane (timeline cleared /
    new session)."""
    global _timeline
    _views.clear()
    _states.clear()
    _timeline = None


def reset():
    """Empty the lane after a full `reinitialize`, which drops the core movie
    and scenes it describes, and tell the app so it empties its copy too. The
    objects the players played are gone too."""
    forget_all_views()
    _playing.clear()
    _emit_timeline([])


def stage_timeline(items_json):
    """Keep Swift's editable item list (a JSON list of item dicts) for the next
    session save. An empty list empties the lane."""
    global _timeline
    import json
    try:
        items = json.loads(items_json)
        _timeline = items if isinstance(items, list) and items else None
    except Exception as e:
        print('MOVIE_ERR:' + str(e))


def rename_scene(old, new):
    """Re-key the staged lane's scene items (#655), so a session saved before
    the app restages still names the scene the .pse holds."""
    for it in _timeline or []:
        if isinstance(it, dict) and it.get('kind') == 'scene' and it.get('scene') == old:
            it['scene'] = new


def _emit_timeline(items, untracked_movie=False):
    """Hand a restored lane to the app: the item list and whether the session
    carries a movie no lane describes (an older .pse), which the first
    Timeline add must not replace unasked. The payload goes to the
    `pymol_timeline` tempfile channel and only `TIMELINE:ready` rides the
    feedback line: a lane of a few items is already over PyMOL's ~1 KB line
    cap, and a split line would not parse. pcatch when embedded, like
    raymol_scenes._emit_rename."""
    import json
    from pymol import raymol_tmp
    payload = {'items': items or [], 'untrackedMovie': bool(untracked_movie)}
    try:
        with open(raymol_tmp.channel_path('pymol_timeline'), 'w', encoding='utf-8') as handle:
            json.dump(payload, handle)
    except Exception as e:
        print('MOVIE_ERR:' + str(e))
        return
    line = 'TIMELINE:ready'
    try:
        import pcatch
        pcatch.write(line + '\n')
    except ImportError:
        print(line)


def _camera_ids(items):
    return [str(it.get('id')) for it in items or []
            if isinstance(it, dict) and it.get('kind') == 'camera']


# --- Objects-panel players (morph close-out B) ------------------------------
#
# PyMOLEngine.startObjectStates animates an object on a Swift timer that sends
# `set state, k, name`, so while it plays the object carries an object-level
# `state` setting (a pin) nobody asked for. Written into a .pse, the pin
# outlives the timer: the reopened object ignores the movie's frames, so a
# Lockstep clip, mplay and movie export show it frozen on the saved frame. The
# app notes here which objects it is playing (one call per start or stop,
# never per tick), and session_save leaves those objects' pins out of the
# session it writes. A pin on any other object is the user's (a typed
# `set state`, a Play stopped on a frame) and stays.

_playing = set()
_renamed = {}   # old player name -> the name set_name gave its object, until the app stops it


def note_object_playing(name, on=True):
    """The app started (`on`) or stopped playing `name` in the Objects panel."""
    if on:
        _playing.add(str(name))
    else:
        _playing.discard(str(name))
        _release_renamed(str(name))


def clear_playing_objects():
    """The app stopped every Objects-panel player."""
    _playing.clear()
    for old in list(_renamed):
        _release_renamed(old)


def _release_renamed(old, _self=cmd):
    """The app stopped the player of `old`, an object renamed while it played:
    its ticks (`set state, k, old`) reached the renamed object until then, since
    PyMOL takes `old` as an unambiguous prefix of the new name, so drop the pin
    they left there, or it would stay live and in every later save."""
    new = _renamed.pop(old, None)
    if new and new in (_self.get_names('all') or []):
        try:
            _self.unset('state', new, quiet=1)
        except Exception:
            pass


def playing_objects():
    """The objects the app is playing, sorted."""
    return sorted(_playing)


@contextlib.contextmanager
def players_go_on():
    """Around an in-memory snapshot or restore of the live session (the Theme
    studio's get_session / set_session): it is the same session, and the app
    keeps playing through it, so the snapshot keeps the players' pins and the
    restore keeps the registry."""
    kept, renamed = set(_playing), dict(_renamed)
    _playing.clear()
    _renamed.clear()
    try:
        yield
    finally:
        _playing.clear()
        _playing.update(kept)
        _renamed.clear()
        _renamed.update(renamed)


def object_renamed(old, new, _self=cmd):
    """`set_name old, new` just ran. A playing object's timer goes on sending
    `set state, k, old` until the panel poll stops that player, so it no longer
    reaches the renamed object: drop the pin it left there (on a group, its
    members), or the object would keep it live and in every later save. The
    registry keeps `old`, which the timer still targets, until the app stops
    it. set_name legalises `new` ('my morph' becomes 'my_morph'), so the
    object may carry the legal form."""
    if str(old) not in _playing:
        return
    new = str(new)
    if new not in (_self.get_names('all') or []):
        new = _self.get_legal_name(new)
    _self.unset('state', new, quiet=1)
    # Its ticks may still pin it (a prefix match) until the app stops the
    # player: release it again then (_release_renamed), and leave it out of
    # saves meanwhile (_pinned_by_players).
    _renamed[str(old)] = new


def _pinned_by_players(entries, _self):
    """The names in `entries` whose `state` a player's ticks set. `set state,
    k, <group>` pins the objects inside the group, all the way down, and not
    the group, so a playing group stands for its members. The session's own
    group links (entry[6]) reach every member it holds, whatever its type; a
    partial save may hold a member without the groups above it, so a playing
    group the session lacks adds its live members (_group_members). A full
    save holds every group, so it never reads them."""
    parent = {}
    for entry in entries:
        try:
            parent[entry[0]] = entry[6]
        except (IndexError, KeyError, TypeError):
            continue
    names = set()
    for name in parent:
        seen = set()
        node = name
        while node and node not in seen:
            if node in _playing or node in _renamed.values():
                names.add(name)
                break
            seen.add(node)
            node = parent.get(node)
    missing = set()
    try:
        missing = _playing.intersection(
            _self.get_names('group_objects') or []) - set(parent)
        if missing:
            names.update(_group_members(sorted(missing), _self) & set(parent))
    except Exception:
        # at least the molecules, which a selection reaches
        for group in missing:
            try:
                names.update(_self.get_object_list('(%s)' % group) or [])
            except Exception:
                pass
    return names


def _group_members(groups, _self):
    """Every object inside `groups`, all the way down and of every type (a CGO,
    a map: get_object_list reports only molecules). The core expands a group
    named to get_session into its members, so a partial read of these groups
    lists them. The core call, not cmd.get_session: that would run the
    session-save tasks again, this one among them. A binary dump at the
    current version, whatever the user's pse settings: only the names are
    read, so the members' data is not worth turning into Python lists."""
    sub = {}
    with _self.lockcm:
        _self._cmd.get_session(_self._COb, sub, ' '.join(groups), 1, 1, 1, 0.0)
    return {e[0] for e in sub.get('names') or [] if e} - set(groups)


def _leave_player_pins_out(session, _self=cmd):
    """Drop the object-level `state` of every playing object (a playing
    group's: of its members) from `session`, the copy get_session just
    filled, so the live objects keep theirs and the players go on. An entry of
    ``session['names']`` is ``[name, type, visible, None, objtype, data,
    group]``; ``data[0]`` is the object's ObjectAsPyList, whose item 8 lists
    its settings as ``[index, type, value]`` (None when it has none)."""
    if not _playing:
        return
    from pymol import setting
    index = setting._get_index('state')
    entries = [e for e in session.get('names') or [] if e]
    pinned = _pinned_by_players(entries, _self)
    for entry in entries:
        if entry[0] not in pinned:
            continue
        try:
            base = entry[5][0]
            settings = base[8]
        except (IndexError, KeyError, TypeError):
            continue
        if settings:
            base[8] = [s for s in settings if not (s and s[0] == index)]


def session_save(session, *, _self=None, **_kwargs):
    """Write the staged lane and the camera views its items use (#901), and
    leave the Objects-panel players' pins out (they reopen on the movie's
    frame)."""
    _leave_player_pins_out(session, cmd if _self is None else _self)
    if _timeline:
        ids = _camera_ids(_timeline)
        session[SESSION_KEY] = {
            'version': 1,
            # copies: the session dict must not share records with the live
            # lane, which a later scene rename edits in place
            'items': copy.deepcopy(_timeline),
            'views': {i: list(_views[i]) for i in ids if i in _views},
            'states': {i: dict(_states[i]) for i in ids if i in _states},
        }
    return 1


def session_restore(session, *, _self=None, **_kwargs):
    """Replace the lane and its views with the session's and tell the app.
    A session with no lane empties it, and reports whether the session still
    carries a movie of its own (left as it is). A partial restore
    (`load x.pse, partial=1`) leaves the live lane alone, as the core leaves
    the movie (#617). A full restore also forgets the players: the objects
    they played are gone."""
    global _timeline
    from pymol import raymol_scenes
    _self = cmd if _self is None else _self
    if raymol_scenes.restoring_partial(_self):
        return 1
    _playing.clear()
    value = session.get(SESSION_KEY)
    items = value.get('items') if isinstance(value, dict) else None
    _views.clear()
    _states.clear()
    if isinstance(items, list) and items:
        # a copy, so editing the live lane never edits the restored snapshot
        _timeline = copy.deepcopy(items)
        for k, v in (value.get('views') or {}).items():
            _views[str(k)] = list(v)
        for k, v in (value.get('states') or {}).items():
            _states[str(k)] = dict(v)
        _emit_timeline(_timeline)
    else:
        _timeline = None
        try:
            untracked = int(_self.get_movie_length()) > 0
        except Exception:
            untracked = False
        _emit_timeline([], untracked)
    return 1


def capture_template_views(ids_json, kind, axis='y', angle=30.0):
    """Compute + store the waypoint camera views for a roll/rock template under
    the ordered `ids` (Swift pre-generates one UUID per waypoint). Views are
    derived from the CURRENT view so the template spins/rocks around wherever
    the molecule is now; the live view is left unchanged. Every waypoint also
    records the models showing now, so the motion holds them (#579).

      roll : equal steps around a full 360 turn about `axis`.
      rock : 0 -> +angle -> -angle -> 0 about `axis` (the canonical 4 points)."""
    import json
    try:
        ids = json.loads(ids_json)
        if not ids:
            return
        v0 = cmd.get_view()
        held = _current_states()
        n = len(ids)
        k = str(kind)
        ax = str(axis)
        if k == 'roll':
            turns = [i * (360.0 / (n - 1)) for i in range(n)] if n > 1 else [0.0]
        elif k == 'rock' and n == 4:
            turns = [0.0, float(angle), -float(angle), 0.0]
        elif k == 'rock':
            turns = [0.0] + [(float(angle) if i % 2 else -float(angle))
                             for i in range(1, n)]
        else:
            turns = [0.0] * n
        for cid, deg in zip(ids, turns):
            cmd.set_view(v0)
            if deg:
                cmd.turn(ax, float(deg))
            _views[str(cid)] = list(cmd.get_view())
            _states[str(cid)] = dict(held)
        cmd.set_view(v0)                          # restore the live view
    except Exception as e:
        print('MOVIE_ERR:' + str(e))


def rebuild(spec_json):
    """Rebuild the ENTIRE movie from an ordered item list (the unified-track
    source of truth lives in Swift). `spec_json` decodes to an ordered list of
    ``{frame, cam:<uuid>|null, scene:<base64 name>|null, power, linear}``:

      - camera item : ``cam`` is a UUID whose 18-float view is in ``_views``.
      - scene item  : ``scene`` is the base64-encoded scene name; the scene is
        recalled to establish the live camera before storing.

    ``power``/``linear`` are the easing of the transition INTO that item
    (0/0 = smooth default, 1/1 = linear). We clear the timeline, lay a fresh
    ``mset`` of the right length, store each keyframe with its per-keyframe
    easing, then a single ``mview interpolate`` fills the gaps (validated to
    honor per-keyframe easing) and rewind. Base64 keeps arbitrary scene names
    safe across the Swift->Python string boundary."""
    import json
    import base64
    try:
        spec = json.loads(spec_json)
        if not spec:
            reset_ensemble()
            return
        cmd.mview('reset')
        _reset_object_motions()
        total = max(2, max(int(it.get('end', it['frame'])) for it in spec))
        cmd.mset('1 x%d' % total)

        state_clips = [it for it in spec if it.get('states')]
        cam_scene = [it for it in spec if not it.get('states')]
        motion = []   # objects that received per-scene TTT keyframes (#204)
        scene_keys = {}  # objname -> {frame: that scene's TTT}, for the state tracks
        scene_kfs = []   # (frame, scene_name, power) for the setting animation
        pins = {}        # objname -> [(frame, state)] the items hold it on (#579)

        # Camera + scene keyframes on the GLOBAL track (camera view / scene reps),
        # plus an optional pinned global state for non-swept objects.
        for it in cam_scene:
            f = int(it['frame'])
            power = float(it.get('power', 0.0))
            linear = int(it.get('linear', 0))
            cmd.frame(f)
            sc = it.get('scene')
            if sc:
                name = base64.b64decode(sc).decode('utf-8')
                from pymol import raymol_scenes as _rs
                with _rs.suspended():           # read, not apply (#508)
                    cmd.scene(name, 'recall')   # live view+reps become the scene
                    # mview store ... scene= recalls the scene itself as well
                    cmd.mview('store', first=f, scene=name, power=power, linear=linear)
                # Preserve the scene's stored state for non-swept objects.
                try:
                    cmd.mview('store', first=f, state=int(cmd.get_state()))
                except Exception:
                    pass
                # #204: author per-object Move-mode TTT keyframes for this scene.
                try:
                    from pymol import raymol_scenes as _rs
                    keyed = _rs.emit_object_motion(name, f)
                    motion += keyed
                    ttts = _rs._scene_ttt.get(name) or {}
                    for o in keyed:
                        scene_keys.setdefault(o, {})[f] = ttts.get(o)
                except Exception:
                    pass
                scene_kfs.append((f, name, power))
            else:
                cam = it.get('cam')
                v = _views.get(str(cam)) if cam is not None else None
                if v:
                    cmd.set_view(v)
                cmd.mview('store', first=f, power=power, linear=linear)
                for obj, s in _states.get(str(cam), {}).items():
                    pins.setdefault(obj, []).append((f, s))
            ps = it.get('state')
            if ps is not None:
                cmd.mview('store', first=f, state=int(ps))
                # An explicit pin wins over the capture-time snapshot, and must
                # land on the per-object tracks too: those win at render.
                for obj in _multistate_objects():
                    pins.setdefault(obj, []).append((f, int(ps)))
        if cam_scene:
            cmd.mview('interpolate')
        # #204: interpolate each object's matrix track once (keyframes stored with
        # freeze=1 above). dict.fromkeys de-dups while preserving order.
        for obj in dict.fromkeys(motion):
            try:
                cmd.mview('interpolate', object=obj)
            except Exception as e:
                print('MOVIE_ERR:' + str(e))
        # Per-scene render settings (DOF etc.) across the transitions. AFTER the
        # interpolate above: the DOF builder resolves focus under each frame's
        # interpolated view.
        # UNCONDITIONAL — a rebuild whose scene items were all deleted must reach
        # author([]) to drop the previous movie's animation, which mset wipes from
        # Cmd[] but which would otherwise still be persisted and re-authored.
        try:
            from pymol import raymol_scene_anim as _an
            _an.author(scene_kfs)
        except Exception as e:
            print('MOVIE_ERR:' + str(e))

        _share_scene_steps(scene_keys, state_clips, pins, total)
        tracked = set()   # objects given a model track below

        # State sweeps — per-object tracks (independent; no clamping between objects).
        if state_clips:
            swept = set()
            sweeps = {}   # objname -> [(start, end, lo, hi, mode)], all its clips
            for clip in state_clips:
                start = int(clip['frame']); end = int(clip.get('end', total))
                mode = str(clip.get('mode', 'sweep'))
                req_first = int(clip.get('first', 1) or 1)
                req_last = int(clip.get('last', 0) or 0)   # 0 = through the last model
                ms = _multistate_objects(clip.get('objects'))
                swept.update(ms)
                if mode == 'lockstep':
                    # One global state sweep across [start,end]; shorter objects clamp.
                    mx = max(ms.values()) if ms else 1
                    lo = max(1, min(req_first, mx))
                    hi = mx if req_last <= 0 else max(1, min(req_last, mx))
                    span = max(1, end - start)
                    seq = ' '.join(
                        str(int(lo + round((hi - lo) * (i - start) / span)))
                        for i in range(start, end + 1))
                    cmd.mset(seq, start)   # overwrite that span of the global mset
                else:
                    for obj, n in ms.items():
                        lo = max(1, min(req_first, n))
                        hi = n if req_last <= 0 else max(1, min(req_last, n))
                        sweeps.setdefault(obj, []).append((start, end, lo, hi, mode))
            # One track per object across all its clips, held between them.
            for obj, clips in sweeps.items():
                _emit_state_clips(obj, clips, total, scene_keys.get(obj))
                tracked.add(obj)
            # Objects no clip plays keep the models their camera items hold.
            for obj in _multistate_objects():
                if obj in pins and obj not in swept:
                    _emit_state_hold(obj, pins[obj], total, scene_keys.get(obj))
                    tracked.add(obj)
        else:
            # A camera item holds the models it was captured on (#579): a Roll
            # moves the camera, not the ensemble. Objects no item pins (loaded
            # after the camera items, or a scenes-only lane) keep the
            # non-destructive default — auto-sweep across the whole movie so
            # they never freeze on model 1.
            for obj, n in _multistate_objects().items():
                if obj in pins:
                    _emit_state_hold(obj, pins[obj], total, scene_keys.get(obj))
                else:
                    _store_state_track(obj, {1: 1, total: n}, total,
                                       scene_keys.get(obj))
                tracked.add(obj)

        # Stopgap (#920): objects the scenes move but no model track keys hold
        # like the tracks above.
        for obj, keys in scene_keys.items():
            if obj not in tracked:
                _hold_scene_positions(obj, total, keys)

        cmd.rewind()
    except Exception as e:
        print('MOVIE_ERR:' + str(e))


def poll():
    """Emit the PLAYBACK feedback line (current frame / length / play state)."""
    import json
    try:
        # count_frames() == SceneCountFrames: the movie length when an mset
        # exists, else max(state count) across objects — so a plain multi-state
        # NMR/trajectory object (no explicit movie) still reports its length.
        d = {
            'frame': int(cmd.get_frame()),
            'count': int(cmd.count_frames()),
            'playing': 1 if cmd.get_movie_playing() else 0,
            'loop': int(cmd.get_setting_int('movie_loop')),
            'fps': float(cmd.get_setting_float('movie_fps')),
        }
        print('PLAYBACK:' + json.dumps(d))
    except Exception as e:
        print('PLAYBACK_ERR:' + str(e))
