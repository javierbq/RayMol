"""Tab completion for the predict commands.

    pymol -ckqy testing/testing.py --run testing/tests/predict/predict_completion.py

Registering a command in keywords.py makes its NAME completable but gives Tab nothing
to offer for its arguments -- that needs an entry in completing.get_auto_arg_list().
The app reaches this through PyMOLBridge_Complete -> cmd._parser.complete, so these
tests drive that same call rather than inspecting the table.
"""
from pymol import cmd, testing


class TestPredictCompletion(testing.PyMOLTestCase):

    def testPredictOffersRegisteredPredictors(self):
        self.assertEqual(cmd._parser.complete('predict '), 'predict boltz2')

    def testPartialPredictorNameCompletes(self):
        self.assertEqual(cmd._parser.complete('predict b'), 'predict boltz2, ')

    def testPredictWeightsAlsoOffersPredictors(self):
        self.assertEqual(cmd._parser.complete('predict_weights '),
                         'predict_weights boltz2')

    def testCommandNameItselfStillCompletes(self):
        self.assertEqual(cmd._parser.complete('predic'), 'predict')

    def testJobCommandsCompleteWithoutRaisingWhenThereAreNoJobs(self):
        """Returning None is fine; raising would break Tab for EVERY command."""
        for line in ('predict_status ', 'predict_cancel ', 'predict_result '):
            self.assertIsNone(cmd._parser.complete(line))

    def testJobCommandsOfferSubmittedJobIds(self):
        from pymol import predicting
        marker = 'zz_completion_probe'
        predicting._JOBS[marker] = object()
        try:
            self.assertIn(marker, predicting.job_ids())
            self.assertEqual(cmd._parser.complete('predict_status zz_'),
                             'predict_status %s, ' % marker)
        finally:
            predicting._JOBS.pop(marker, None)

    def testACompleterNeverRaisesEvenIfItsSourceIsBroken(self):
        """A throwing completer takes Tab down for the whole console, not just here."""
        from pymol import completing, predicting
        original = predicting.job_ids
        predicting.job_ids = lambda: (_ for _ in ()).throw(RuntimeError('boom'))
        try:
            self.assertIsNotNone(completing._predict_job_shortcut())
        finally:
            predicting.job_ids = original
