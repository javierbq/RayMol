'''
#579: a camera item holds the model showing when it was added.

Adding a Roll (or any camera keyframe) to an ensemble used to sweep every model
across the movie, starting from model 1, whatever model the user was on. These
gates pin the fix in appkit_movie: the views captured for camera items record
each multi-state object's model, and rebuild() holds it.

Per-object ViewElem state is applied at RENDER (ObjectPrepareContext), so each
sampled frame rays a tiny image before reading the object's own `state`.
'''

from pymol import cmd, testing, appkit_movie
import json


class TestMovieHoldModel(testing.PyMOLTestCase):

    def setUp(self):
        super().setUp()
        appkit_movie.forget_all_views()

    def _ensemble(self, name, n):
        # An n-state object: a monomer's state 1 copied into states 1..n.
        cmd.fab('AG', name + '_src')
        cmd.disable(name + '_src')
        for i in range(1, n + 1):
            cmd.create(name, name + '_src', 1, i)
        self.assertEqual(cmd.count_states(name), n)

    def _states(self, obj):
        seen = []
        last = cmd.count_frames()
        for f in list(range(1, last + 1, 10)) + [last]:
            cmd.frame(f)
            cmd.ray(20, 20)
            seen.append(int(cmd.get('state', obj)))
        return seen

    def _roll(self, ids=('r1', 'r2', 'r3', 'r4'), frames=(1, 41, 81, 121)):
        appkit_movie.capture_template_views(json.dumps(list(ids)), 'roll', axis='y')
        return [{'frame': f, 'cam': c, 'power': 0.0, 'linear': 0}
                for f, c in zip(frames, ids)]

    def test_roll_holds_the_current_model(self):
        cmd.reinitialize()
        self._ensemble('nmr', 20)
        cmd.set('state', 7)
        appkit_movie.rebuild(json.dumps(self._roll()))
        self.assertEqual(set(self._states('nmr')), {7})

    def test_captured_keyframe_holds_the_objects_own_model(self):
        cmd.reinitialize()
        self._ensemble('nmr', 10)
        cmd.set('state', 4, 'nmr')          # Object-panel slider: per-object state
        appkit_movie.capture_view('k1')
        cmd.turn('y', 90)
        appkit_movie.capture_view('k2')
        spec = [{'frame': 1, 'cam': 'k1', 'power': 0.0, 'linear': 0},
                {'frame': 60, 'cam': 'k2', 'power': 0.0, 'linear': 0}]
        appkit_movie.rebuild(json.dumps(spec))
        self.assertEqual(set(self._states('nmr')), {4})

    def test_each_ensemble_holds_its_own_model(self):
        cmd.reinitialize()
        self._ensemble('ens1', 10)
        self._ensemble('ens2', 10)
        cmd.set('state', 3, 'ens1')
        cmd.set('state', 9, 'ens2')
        appkit_movie.rebuild(json.dumps(self._roll()))
        self.assertEqual(set(self._states('ens1')), {3})
        self.assertEqual(set(self._states('ens2')), {9})

    def test_explicit_pin_wins_over_the_capture(self):
        cmd.reinitialize()
        self._ensemble('nmr', 10)
        cmd.set('state', 2)
        spec = self._roll()
        for it in spec:
            it['state'] = 6
        appkit_movie.rebuild(json.dumps(spec))
        self.assertEqual(set(self._states('nmr')), {6})

    def test_object_loaded_after_the_roll_still_sweeps(self):
        # Unpinned ensembles keep the non-destructive default.
        cmd.reinitialize()
        self._ensemble('old', 10)
        cmd.set('state', 5)
        spec = self._roll()
        self._ensemble('new', 10)
        appkit_movie.rebuild(json.dumps(spec))
        self.assertEqual(set(self._states('old')), {5})
        self.assertGreaterEqual(len(set(self._states('new'))), 5)

    def test_states_clip_plays_its_object_and_holds_the_rest(self):
        cmd.reinitialize()
        self._ensemble('played', 10)
        self._ensemble('held', 10)
        cmd.set('state', 8, 'held')
        spec = self._roll()
        spec.append({'frame': 1, 'end': 121, 'states': 1,
                     'objects': ['played'], 'mode': 'sweep'})
        appkit_movie.rebuild(json.dumps(spec))
        self.assertEqual(max(self._states('played')), 10)
        self.assertEqual(set(self._states('held')), {8})

    def test_forgotten_view_drops_its_pin(self):
        cmd.reinitialize()
        self._ensemble('nmr', 10)
        cmd.set('state', 7)
        spec = self._roll()
        for c in ('r1', 'r2', 'r3', 'r4'):
            appkit_movie.forget_view(c)
        appkit_movie.rebuild(json.dumps(spec))
        self.assertGreaterEqual(len(set(self._states('nmr'))), 5)

    def test_movie_builder_roll_holds_the_current_model(self):
        cmd.reinitialize()
        self._ensemble('nmr', 10)
        cmd.set('state', 6)
        appkit_movie.make_movie('roll', duration=4.0, loop=0)
        self.assertGreater(cmd.count_frames(), 10)
        self.assertEqual(set(self._states('nmr')), {6})

    def test_rebuild_drops_the_previous_builds_pins(self):
        # `mview reset` only clears the camera track: a hold pinned at frame 41
        # must not bleed into a later, shorter lane pinned on another model.
        cmd.reinitialize()
        self._ensemble('nmr', 10)
        cmd.set('state', 7)
        appkit_movie.rebuild(json.dumps(self._roll()))
        for c in ('r1', 'r2', 'r3', 'r4'):
            appkit_movie.forget_view(c)
        cmd.frame(1)
        cmd.set('state', 3, 'nmr')
        spec = self._roll(ids=('s1', 's2', 's3', 's4'), frames=(1, 20, 40, 61))
        appkit_movie.rebuild(json.dumps(spec))
        self.assertEqual(set(self._states('nmr')), {3})
