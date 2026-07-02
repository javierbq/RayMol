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
        cmd.mview('reinterpolate', power=power, linear=lin)
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
                for i, nm in enumerate(names):
                    f = start + 1 + i * per
                    cmd.frame(f)
                    cmd.scene(nm, 'recall')
                    cmd.mview('store', first=f, scene=nm)
                cmd.mview('reinterpolate', power=0.0, linear=0.0)

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
