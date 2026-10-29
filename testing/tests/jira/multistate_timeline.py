'''
Multi-state objects in the movie timeline (appkit_movie.rebuild).

Verifies the non-destructive default, per-object state sweeps, and independence
of multiple multi-state objects. Per-object ViewElem state is applied at RENDER
(ObjectPrepareContext), so state assertions ray a tiny image per sampled frame
to force the apply, then read the object's own `state` setting.
'''

from pymol import cmd, testing, appkit_movie
import base64
import json


class TestMultistateTimeline(testing.PyMOLTestCase):

    def _ensemble(self, name, n):
        # Build an n-state object by copying a monomer's state 1 into states 1..n.
        cmd.fab('AG', 'mono')
        cmd.disable('mono')
        for i in range(1, n + 1):
            cmd.create(name, 'mono', 1, i)
        self.assertEqual(cmd.count_states(name), n)

    def _ostate(self, obj, frame):
        cmd.frame(frame)
        cmd.ray(20, 20)                     # force ObjectPrepareContext (state apply)
        return int(cmd.get('state', obj))

    def test_multistate_objects_detects_counts(self):
        cmd.reinitialize()
        self._ensemble('nmr', 10)
        cmd.fab('A', 'solo')                # single state
        d = appkit_movie._multistate_objects()
        self.assertEqual(d.get('nmr'), 10)
        self.assertNotIn('solo', d)

    def test_empty_authors_no_mset(self):
        cmd.reinitialize()
        self._ensemble('nmr', 10)
        appkit_movie.rebuild('[]')
        # No mset => count_frames falls back to the state count.
        self.assertEqual(cmd.count_frames(), 10)

    def test_camera_only_does_not_freeze_ensemble(self):
        cmd.reinitialize()
        self._ensemble('nmr', 10)
        spec = [{'frame': 1, 'cam': 'A', 'power': 0.0, 'linear': 0},
                {'frame': 60, 'cam': 'B', 'power': 0.0, 'linear': 0}]
        appkit_movie.rebuild(json.dumps(spec))
        seen = {self._ostate('nmr', f) for f in range(1, cmd.count_frames() + 1, 6)}
        seen.add(self._ostate('nmr', cmd.count_frames()))
        self.assertGreaterEqual(max(seen), 9)   # auto-sweeps, not frozen on state 1
        self.assertGreaterEqual(len(seen), 5)

    def test_two_ensembles_sweep_independently(self):
        cmd.reinitialize()
        self._ensemble('short', 5)
        self._ensemble('long', 40)
        spec = [{'frame': 1, 'end': 80, 'states': 1, 'objects': None, 'mode': 'sweep'}]
        appkit_movie.rebuild(json.dumps(spec))
        ss, ls = set(), set()
        for f in list(range(1, cmd.count_frames() + 1, 8)) + [cmd.count_frames()]:
            cmd.frame(f); cmd.ray(20, 20)
            ss.add(int(cmd.get('state', 'short')))
            ls.add(int(cmd.get('state', 'long')))
        self.assertLessEqual(max(ss), 5)         # short not clamped to long's range
        self.assertEqual(max(ls), 40)            # long reaches its own max
        self.assertGreaterEqual(max(ss), 5)      # and short reaches its own max

    def test_states_clip_model_range(self):
        cmd.reinitialize()
        self._ensemble('nmr', 10)
        spec = [{'frame': 1, 'end': 80, 'states': 1, 'objects': None,
                 'mode': 'sweep', 'first': 3, 'last': 7}]
        appkit_movie.rebuild(json.dumps(spec))
        seen = set()
        for f in list(range(1, cmd.count_frames() + 1, 6)) + [cmd.count_frames()]:
            cmd.frame(f); cmd.ray(20, 20)
            seen.add(int(cmd.get('state', 'nmr')))
        self.assertGreaterEqual(min(seen), 3)     # never below the requested first
        self.assertLessEqual(max(seen), 7)        # never above the requested last
        self.assertEqual(max(seen), 7)

    def test_states_clip_after_a_roll_holds_its_first_model_before_it(self):
        # A Roll, then a Play-models clip: the models hold still through the Roll,
        # also once the movie has played through. The clip's track used to wrap
        # across the loop seam, playing the models backwards during the Roll.
        cmd.reinitialize()
        self._ensemble('nmr', 10)
        spec = [{'frame': f, 'cam': c, 'power': 1.0, 'linear': 1}
                for f, c in ((1, 'A'), (41, 'B'), (81, 'C'))]
        spec.append({'frame': 81, 'end': 161, 'states': 1, 'objects': ['nmr'],
                     'mode': 'sweep', 'first': 1, 'last': 0})
        appkit_movie.rebuild(json.dumps(spec))
        self.assertEqual({self._ostate('nmr', f) for f in range(1, 81, 8)}, {1})
        self.assertEqual(self._ostate('nmr', 161), 10)      # the clip still plays
        self.assertEqual({self._ostate('nmr', f) for f in (1, 40, 80)}, {1})

    def test_states_clip_before_camera_items_holds_its_last_model_after_it(self):
        cmd.reinitialize()
        self._ensemble('nmr', 10)
        spec = [{'frame': 1, 'end': 61, 'states': 1, 'objects': ['nmr'],
                 'mode': 'sweep', 'first': 2, 'last': 8},
                {'frame': 101, 'cam': 'A', 'power': 1.0, 'linear': 1},
                {'frame': 141, 'cam': 'B', 'power': 1.0, 'linear': 1}]
        appkit_movie.rebuild(json.dumps(spec))
        self.assertEqual(self._ostate('nmr', 1), 2)
        for f in range(61, 142, 8):
            # Jump in from frame 1: an unheld frame would keep its model 2.
            self._ostate('nmr', 1)
            self.assertEqual(self._ostate('nmr', f), 8)

    def test_two_clips_of_one_object_hold_between_them(self):
        cmd.reinitialize()
        self._ensemble('nmr', 10)
        spec = [{'frame': 1, 'end': 41, 'states': 1, 'objects': ['nmr'],
                 'mode': 'sweep', 'first': 1, 'last': 5},
                {'frame': 61, 'cam': 'A', 'power': 1.0, 'linear': 1},
                {'frame': 81, 'end': 121, 'states': 1, 'objects': ['nmr'],
                 'mode': 'loop', 'first': 3, 'last': 9}]
        appkit_movie.rebuild(json.dumps(spec))
        self.assertEqual({self._ostate('nmr', f) for f in range(41, 81, 6)}, {5})
        self.assertEqual(self._ostate('nmr', 81), 3)
        self.assertEqual(self._ostate('nmr', 101), 9)
        self.assertEqual(self._ostate('nmr', 121), 3)

    def _xshift(self, obj, frame):
        cmd.frame(frame)
        cmd.ray(20, 20)                     # force ObjectPrepareContext (TTT apply)
        return float((cmd.get_object_ttt(obj) or [0.0] * 16)[3])

    def _scene_item(self, name, frame):
        return {'frame': frame, 'power': 0.0, 'linear': 0,
                'scene': base64.b64encode(name.encode('utf-8')).decode('ascii')}

    def _moved_between_scenes(self, group=False):
        # nmr at x=0 in scene A and moved 12 Å along x (Move mode) in scene B;
        # with `group`, inside group g with a one-state object (made before the
        # scenes, or recalling them would disable the group).
        self._ensemble('nmr', 10)
        if group:
            cmd.fab('A', 'solo')
            cmd.group('g', 'nmr solo')
        cmd.scene('A', 'store')
        cmd.translate([12, 0, 0], object='nmr', camera=0)
        cmd.scene('B', 'store')

    def test_scene_motion_survives_a_later_states_clip(self):
        # The clip's holds used to store nmr's live position over scene A's key,
        # losing the move between the scenes (#204).
        cmd.reinitialize()
        self._moved_between_scenes()
        spec = [self._scene_item('A', 1), self._scene_item('B', 61),
                {'frame': 121, 'end': 241, 'states': 1, 'objects': ['nmr'],
                 'mode': 'sweep', 'first': 1, 'last': 0}]
        appkit_movie.rebuild(json.dumps(spec))
        self.assertAlmostEqual(self._xshift('nmr', 1), 0.0, places=1)
        self.assertTrue(0.5 < self._xshift('nmr', 30) < 11.5)
        self.assertAlmostEqual(self._xshift('nmr', 61), 12.0, places=1)
        # Inside the clip: the models play and the scene-B position holds.
        self.assertIn(self._ostate('nmr', 181), (5, 6))
        self.assertAlmostEqual(self._xshift('nmr', 181), 12.0, places=1)
        self.assertEqual(self._ostate('nmr', 241), 10)

    def test_scenes_only_lane_keeps_an_ensembles_scene_motion(self):
        cmd.reinitialize()
        self._moved_between_scenes()
        appkit_movie.rebuild(json.dumps([self._scene_item('A', 1),
                                         self._scene_item('B', 61)]))
        self.assertAlmostEqual(self._xshift('nmr', 1), 0.0, places=1)
        self.assertAlmostEqual(self._xshift('nmr', 61), 12.0, places=1)
        self.assertIn(self._ostate('nmr', 31), (5, 6))     # and still sweeps

    def test_camera_item_inside_a_clip_after_scenes_keeps_the_ramp(self):
        # Setting a scene position while a movie exists auto-stored a key, with
        # no model, at the last item rebuild visited (here the camera at 101),
        # which broke the clip's model ramp across it.
        cmd.reinitialize()
        self._moved_between_scenes()
        spec = [self._scene_item('A', 1), self._scene_item('B', 41),
                {'frame': 41, 'end': 161, 'states': 1, 'objects': ['nmr'],
                 'mode': 'sweep', 'first': 1, 'last': 0},
                {'frame': 101, 'cam': 'C', 'power': 1.0, 'linear': 1}]
        appkit_movie.rebuild(json.dumps(spec))
        self.assertIn(self._ostate('nmr', 101), (5, 6))
        self.assertIn(self._ostate('nmr', 131), (7, 8))
        self.assertAlmostEqual(self._xshift('nmr', 131), 12.0, places=1)

    def test_states_clip_of_a_group_plays_its_members(self):
        # A store through a group wrote its members' live positions over the
        # first scene's.
        cmd.reinitialize()
        self._moved_between_scenes(group=True)
        spec = [self._scene_item('A', 1), self._scene_item('B', 61),
                {'frame': 61, 'end': 121, 'states': 1, 'objects': ['g'],
                 'mode': 'sweep', 'first': 1, 'last': 0}]
        appkit_movie.rebuild(json.dumps(spec))
        self.assertAlmostEqual(self._xshift('nmr', 1), 0.0, places=1)
        self.assertAlmostEqual(self._xshift('nmr', 61), 12.0, places=1)
        self.assertIn(self._ostate('nmr', 91), (5, 6))
        self.assertEqual(self._ostate('nmr', 121), 10)

    def test_scene_transition_before_a_clip_holds_after_playback(self):
        # Playing the movie leaves nmr's own `state` set, and a scene's key used
        # to carry it: on the next rebuild the models moved during the scene
        # transition before the clip.
        cmd.reinitialize()
        self._ensemble('nmr', 10)
        cmd.scene('A', 'store')
        cmd.turn('y', 40)
        cmd.scene('B', 'store')
        spec = [self._scene_item('A', 1), self._scene_item('B', 61),
                {'frame': 121, 'end': 241, 'states': 1, 'objects': ['nmr'],
                 'mode': 'sweep', 'first': 1, 'last': 0}]
        appkit_movie.rebuild(json.dumps(spec))
        for f in range(1, 242, 10):
            self._ostate('nmr', f)
        appkit_movie.rebuild(json.dumps(spec))  # any lane edit rebuilds
        self.assertEqual({self._ostate('nmr', f) for f in range(1, 121, 8)}, {1})
        self.assertEqual(self._ostate('nmr', 241), 10)

    def test_ensemble_and_ligand_moved_together_stay_together(self):
        # A one-state ligand moved with its ensemble between two scenes that come
        # after a camera item: the ensemble's track holds, so the ligand must
        # too, not glide round the loop seam apart from it (#920 stopgap).
        cmd.reinitialize()
        self._ensemble('rec', 10)
        cmd.fab('A', 'lig')
        cmd.scene('A', 'store')
        cmd.translate([12, 0, 0], object='rec', camera=0)
        cmd.translate([12, 0, 0], object='lig', camera=0)
        cmd.scene('B', 'store')
        spec = [{'frame': 1, 'cam': 'Z', 'power': 1.0, 'linear': 1},
                self._scene_item('A', 61), self._scene_item('B', 121)]
        appkit_movie.rebuild(json.dumps(spec))
        for f in (1, 31, 61, 91, 121):
            self.assertAlmostEqual(self._xshift('rec', f), self._xshift('lig', f),
                                   delta=0.5, msg='frame %d' % f)
        self.assertEqual(cmd.get_setting_int('movie_auto_store'), -1)  # restored

    def test_reset_ensemble_restores_all_models(self):
        cmd.reinitialize()
        self._ensemble('nmr', 10)
        appkit_movie.rebuild(json.dumps([{'frame': 1, 'cam': 'A', 'power': 0.0, 'linear': 0}]))
        appkit_movie.reset_ensemble()
        self.assertEqual(cmd.count_frames(), 10)
