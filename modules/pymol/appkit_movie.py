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

from pymol import cmd


def reset_movie():
    """Clear the movie timeline (frame sequence + camera keyframes) and rewind."""
    try:
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
    restricts to those objects; None = every object in the session."""
    out = {}
    try:
        objs = names if names else cmd.get_object_list()
    except Exception:
        objs = []
    for o in (objs or []):
        try:
            ns = int(cmd.count_states(o))
            if ns > 1:
                out[o] = ns
        except Exception:
            pass
    return out


def _emit_state_sweep(obj, lo, hi, start, end, mode='sweep'):
    """Store per-object STATE keyframes so `obj` sweeps models lo..hi across movie
    frames [start,end], then interpolate that object's own track. Both endpoints
    are flagged (state=) so View.cpp interpolates the state channel; the per-object
    ViewElem sets the object's own `state` at render (independent of the mset and
    of other objects). mode: 'sweep' (lo->hi) or 'loop' (lo->hi->lo)."""
    try:
        s = int(start); e = int(end); lo = int(lo); hi = int(hi)
        if e <= s:
            e = s + 1
        if hi < lo:
            lo, hi = hi, lo
        if mode == 'loop':
            mid = (s + e) // 2
            cmd.mview('store', object=obj, first=s,   state=lo)
            cmd.mview('store', object=obj, first=mid, state=hi)
            cmd.mview('store', object=obj, first=e,   state=lo)
        else:
            cmd.mview('store', object=obj, first=s, state=lo)
            cmd.mview('store', object=obj, first=e, state=hi)
        cmd.mview('interpolate', object=obj)
    except Exception as ex:
        print('MOVIE_ERR:' + str(ex))


def reset_ensemble():
    """Drop all movie authoring and rewind so a multi-state object plays its raw
    models again (count_frames falls back to the state count)."""
    try:
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
        cmd.scene(name, 'recall')    # now the live view+reps ARE the scene
        cmd.mview('store', first=n, scene=name)
        try:
            from pymol import raymol_scenes as _rs
            motion = _rs.emit_object_motion(name, n)
        except Exception:
            motion = []
        cmd.mview('reinterpolate', power=power, linear=lin)
        for obj in dict.fromkeys(motion):
            try:
                cmd.mview('interpolate', object=obj)
            except Exception:
                pass
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
        if int(reset):
            cmd.mview('reset')
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
            movie.add_scenes(names=names, pause=float(pause), loop=loop)
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
                    cmd.scene(nm, 'recall')
                    cmd.mview('store', first=f, scene=nm)
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
# with the ordered spec and we lay a fresh movie. Session-scoped (the dict lives
# for the process, like the Swift-side item list) — not restored from a .pse.

_views = {}


def capture_view(cam_id):
    """Store the current camera view under `cam_id` (a camera item's UUID)."""
    try:
        _views[str(cam_id)] = list(cmd.get_view())
    except Exception as e:
        print('MOVIE_ERR:' + str(e))


def forget_view(cam_id):
    """Drop the stored view for a deleted camera item."""
    _views.pop(str(cam_id), None)


def forget_all_views():
    """Drop every stored camera view (timeline cleared / new session)."""
    _views.clear()


def capture_template_views(ids_json, kind, axis='y', angle=30.0):
    """Compute + store the waypoint camera views for a roll/rock template under
    the ordered `ids` (Swift pre-generates one UUID per waypoint). Views are
    derived from the CURRENT view so the template spins/rocks around wherever
    the molecule is now; the live view is left unchanged.

      roll : equal steps around a full 360 turn about `axis`.
      rock : 0 -> +angle -> -angle -> 0 about `axis` (the canonical 4 points)."""
    import json
    try:
        ids = json.loads(ids_json)
        if not ids:
            return
        v0 = cmd.get_view()
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
        total = max(2, max(int(it.get('end', it['frame'])) for it in spec))
        cmd.mset('1 x%d' % total)

        state_clips = [it for it in spec if it.get('states')]
        cam_scene = [it for it in spec if not it.get('states')]
        motion = []   # objects that received per-scene TTT keyframes (#204)

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
                cmd.scene(name, 'recall')       # live view+reps become the scene
                cmd.mview('store', first=f, scene=name, power=power, linear=linear)
                # Preserve the scene's stored state for non-swept objects.
                try:
                    cmd.mview('store', first=f, state=int(cmd.get_state()))
                except Exception:
                    pass
                # #204: author per-object Move-mode TTT keyframes for this scene.
                try:
                    from pymol import raymol_scenes as _rs
                    motion += _rs.emit_object_motion(name, f)
                except Exception:
                    pass
            else:
                cam = it.get('cam')
                v = _views.get(str(cam)) if cam is not None else None
                if v:
                    cmd.set_view(v)
                cmd.mview('store', first=f, power=power, linear=linear)
            ps = it.get('state')
            if ps is not None:
                cmd.mview('store', first=f, state=int(ps))
        if cam_scene:
            cmd.mview('interpolate')
        # #204: interpolate each object's matrix track once (keyframes stored with
        # freeze=1 above). dict.fromkeys de-dups while preserving order.
        for obj in dict.fromkeys(motion):
            try:
                cmd.mview('interpolate', object=obj)
            except Exception as e:
                print('MOVIE_ERR:' + str(e))

        # State sweeps — per-object tracks (independent; no clamping between objects).
        if state_clips:
            for clip in state_clips:
                start = int(clip['frame']); end = int(clip.get('end', total))
                mode = str(clip.get('mode', 'sweep'))
                req_first = int(clip.get('first', 1) or 1)
                req_last = int(clip.get('last', 0) or 0)   # 0 = through the last model
                ms = _multistate_objects(clip.get('objects'))
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
                        _emit_state_sweep(obj, lo, hi, start, end, mode)
        else:
            # Non-destructive default: auto-sweep every multi-state object across
            # the whole movie so a camera/scene movie never freezes the ensemble.
            for obj, n in _multistate_objects().items():
                _emit_state_sweep(obj, 1, n, 1, total, 'sweep')

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
