"""Movies replay each scene's PER-OBJECT settings, and building one leaves the
live session alone (#508).

A scene captures globals and per-object overrides (materials,
metal_rt_reflect*). Two things were wrong with movies built from scenes:

  * playback replayed only the GLOBAL half. raymol_scene_anim.enter_scene,
    the frame command authored at each scene cut, applied the scene's globals
    and never its per-object overrides -- so in a marble -> clay movie every
    object changed except the ones the user had styled, which stayed frozen;
  * AUTHORING mutated the live session. Every authoring path recalled each
    scene -- and `mview store ... scene=` recalls it again by itself -- with
    the recall hook live, then scrubbed every frame (running every authored
    frame command) to find the cuts. The session was left carrying whichever
    scene's values were applied last.

Frame commands run only when THEIR frame is displayed, so playback is
simulated by displaying every frame in order, as the player and an export do.

Runs on a RayMol --testing build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/movie_object_settings.py
"""
import base64
import json

from pymol import cmd, testing
from pymol import appkit_movie as am


def obj_state():
    # o1, o2: an override in both scenes; o4: an override only in s2 (must be
    # UNSET at the cut back to s1); material_default: the global o3 follows.
    return (cmd.get('stick_material', 'o1'), cmd.get('metal_rt_reflect', 'o2'),
            cmd.get('material_default'), cmd.get('stick_material', 'o4'))


class TestMovieObjectSettings(testing.PyMOLTestCase):

    def setUp(self):
        super().setUp()
        cmd.reinitialize()
        cmd.fragment('ala', 'o1')
        cmd.fragment('gly', 'o2')
        cmd.fragment('ser', 'o3')   # never has an override: follows the global
        cmd.fragment('thr', 'o4')
        cmd.hide('everything')
        cmd.show('sticks')
        # scene s1: per-object marble / 0.1, global matte
        cmd.set('stick_material', 'marble', 'o1')
        cmd.set('metal_rt_reflect', 0.1, 'o2')
        cmd.set('material_default', 'matte')
        cmd.select('dof_focus', 'o1')
        cmd.scene('s1', 'store')
        # scene s2: per-object clay / 0.9, global plastic
        cmd.set('stick_material', 'clay', 'o1')
        cmd.set('metal_rt_reflect', 0.9, 'o2')
        cmd.set('material_default', 'plastic')
        cmd.set('stick_material', 'rubber', 'o4')
        cmd.select('dof_focus', 'o2')
        cmd.scene('s2', 'store')
        # the LIVE state authoring must not disturb: neither scene's
        cmd.set('stick_material', 'rubber', 'o1')
        cmd.set('metal_rt_reflect', 0.5, 'o2')
        cmd.set('material_default', 'clay')
        cmd.unset('stick_material', 'o4')
        cmd.select('dof_focus', 'o1 and name CA')
        self.live = obj_state()
        self.live_focus = cmd.count_atoms('dof_focus')

    def play(self):
        """{frame: obj_state()} displaying every frame in order."""
        seen = {}
        for f in range(1, cmd.count_frames() + 1):
            cmd.frame(f)
            seen[f] = obj_state()
        return seen

    def assertAuthoringLeftTheSessionAlone(self):
        """Either untouched, or exactly what the frame now on screen shows in
        playback. rebuild() ends with cmd.rewind(), which DISPLAYS frame 1 and
        so runs its scene cut -- that is the movie showing its first frame, not
        authoring leaking. What must never happen is the LAST authored scene's
        values being left applied (the bug)."""
        after = obj_state()
        here = int(cmd.get_frame() or 1)
        seen = self.play()
        self.assertIn(after, (self.live, seen[here]),
                      'authoring left %r live at frame %d' % (after, here))
        return seen

    def assertStepsBetweenTheScenes(self, seen, loops_back=False):
        # o4 reads as material_default when it has no override of its own
        s1 = ('marble', '0.10000', 'matte', 'default')
        s2 = ('clay', '0.90000', 'plastic', 'rubber')
        # the first frames are inside s1's span, and somewhere later the movie
        # has cut to s2 -- per-object values included, not only the global
        self.assertEqual(seen[2], s1)
        self.assertIn(s2, list(seen.values()))
        firsts2 = min(f for f, v in seen.items() if v == s2)
        self.assertGreater(firsts2, 2)
        # ...and back to s1 after it (the loop cut): o4's s2-only override must
        # be UNSET, not left at rubber
        # Only the paths whose movie actually cuts back to s1 (the loop cut)
        # can show it; make_movie and rebuild end inside s2, so for them this is
        # asserted not at all rather than skipped silently.
        if loops_back:
            later = [v for f, v in sorted(seen.items())
                     if f > firsts2 and v[0] == 'marble']
            self.assertTrue(later, 'no cut back to s1 to check the unset on')
            self.assertEqual(later[0], s1)

    def testPlaceSceneLeavesTheSessionAloneAndPlaybackSteps(self):
        cmd.mset('1 x60')
        am.place_scene(1, 's1')
        am.place_scene(40, 's2')
        # the autofocus target is part of what authoring must leave alone
        self.assertEqual(cmd.count_atoms('dof_focus'), self.live_focus)
        self.assertStepsBetweenTheScenes(
            self.assertAuthoringLeftTheSessionAlone(), loops_back=True)

    def testTheScenesTemplateLeavesTheSessionAloneAndPlaybackSteps(self):
        am.append_template('scenes', seconds_per_scene=1.0, scenes=['s1', 's2'])
        self.assertStepsBetweenTheScenes(
            self.assertAuthoringLeftTheSessionAlone(), loops_back=True)

    def testRebuildLeavesTheSessionAloneAndPlaybackSteps(self):
        spec = [{'frame': 1, 'scene': base64.b64encode(b's1').decode(),
                 'power': 0.0, 'linear': 0},
                {'frame': 40, 'end': 60,
                 'scene': base64.b64encode(b's2').decode(),
                 'power': 0.0, 'linear': 0}]
        am.rebuild(json.dumps(spec))
        self.assertStepsBetweenTheScenes(self.assertAuthoringLeftTheSessionAlone())

    def testMakeMovieScenesLeavesTheSessionAloneAndPlaybackSteps(self):
        am.make_movie('scenes', scenes=['s1', 's2'])
        self.assertStepsBetweenTheScenes(self.assertAuthoringLeftTheSessionAlone())


class TestPreserved(testing.PyMOLTestCase):

    def testNestedBlocksEachRestoreTheirOwnState(self):
        from pymol import raymol_scenes as rs
        cmd.reinitialize()
        cmd.fragment('ala', 'o1')
        cmd.set('stick_material', 'marble', 'o1')
        with rs.preserved():
            cmd.set('stick_material', 'clay', 'o1')
            with rs.preserved():
                cmd.set('stick_material', 'rubber', 'o1')
            self.assertEqual(cmd.get('stick_material', 'o1'), 'clay')
        self.assertEqual(cmd.get('stick_material', 'o1'), 'marble')

    def testNoFocusSelectionBeforeMeansNoneAfter(self):
        from pymol import raymol_scenes as rs
        cmd.reinitialize()
        cmd.fragment('ala', 'o1')
        with rs.preserved():
            cmd.select('dof_focus', 'o1')
        self.assertNotIn('dof_focus', cmd.get_names('selections'))
