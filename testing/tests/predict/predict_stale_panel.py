"""A deleted object must not be probed by the inspector poll.

    pymol -ckqy testing/testing.py --run testing/tests/predict/predict_stale_panel.py

The panel keeps polling names it was last told about. When one of those objects is
gone -- deleted, or wiped by `reinitialize` -- probing it makes the SELECTOR write
`Selector-Error: Invalid selection name "<obj>"` to the feedback log. A Python
try/except cannot suppress that: the line is emitted before the call raises. The poll
runs ~2x/second, so it floods the console forever. Same failure as issue #219, reached
through a missing object rather than a wrong-typed one, and easy to hit now that
cmd.predict creates objects that later disappear.
"""
from pymol import cmd, testing


class TestStaleObjectPoll(testing.PyMOLTestCase):

    def testGuardShortCircuitsBeforeTouchingTheSelector(self):
        """get_type itself runs the name through the selector, so the existence check
        has to come FIRST -- catching the exception is already too late."""
        from pymol import appkit_inspector as ai
        seen = []
        original = ai.cmd.get_type
        ai.cmd.get_type = lambda obj, *a, **k: (seen.append(obj), original(obj, *a, **k))[1]
        try:
            self.assertFalse(ai.takes_atom_selection('definitely_not_an_object'))
        finally:
            ai.cmd.get_type = original
        self.assertEqual(seen, [], 'get_type was called on a name that does not exist')

    def testPollOfAStaleNameProducesAnEmptyEntryAndDoesNotRaise(self):
        from pymol import appkit_inspector as ai
        cmd.pseudoatom('temp_obj')
        cmd.delete('temp_obj')
        built = ai._build(['temp_obj'])
        self.assertEqual(built['detail'].get('temp_obj'), [])
        self.assertNotIn('temp_obj', built['objmeta'],
                         'a deleted object must not reach objmeta either')

    def testStateTitlePassAlsoSkipsAStaleName(self):
        """The objmeta pass calls count_states, which also runs the selector. It is a
        SECOND loop over the same names, so guarding only the rep loop left the flood."""
        from pymol import appkit_inspector as ai
        cmd.pseudoatom('temp_obj2')
        cmd.delete('temp_obj2')
        seen = []
        original = ai.cmd.count_states
        ai.cmd.count_states = lambda obj, *a, **k: (seen.append(obj),
                                                    original(obj, *a, **k))[1]
        try:
            ai._build(['temp_obj2'])
        finally:
            ai.cmd.count_states = original
        self.assertEqual(seen, [], 'count_states was called on a deleted object')

    def testALiveObjectIsStillFullyDescribed(self):
        """The guard must not blank real objects."""
        from pymol import appkit_inspector as ai
        cmd.fragment('ala', 'live_obj')
        built = ai._build(['live_obj'])
        self.assertIn('live_obj', built['detail'])
        self.assertIn('live_obj', built['objmeta'],
                      'the guard blanked a live object')

    def testSurvivesReinitializeWithAPendingPrediction(self):
        """The path the user actually hit: predict creates a placeholder, reinitialize
        wipes it, and the panel keeps polling the name."""
        from pymol import appkit_inspector as ai, predicting
        predicting.register_pending('boltz2_prediction_deadbeef', 'job1')
        cmd.reinitialize()
        built = ai._build(['boltz2_prediction_deadbeef'])
        self.assertEqual(built['detail'].get('boltz2_prediction_deadbeef'), [])
        predicting.clear_pending()
