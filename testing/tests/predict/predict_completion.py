"""Tab completion for the predict commands.

    pymol -ckqy testing/testing.py --run testing/tests/predict/predict_completion.py

Registering a command in keywords.py makes its NAME completable but gives Tab nothing
to offer for its arguments -- that needs an entry in completing.get_auto_arg_list().
The app reaches this through PyMOLBridge_Complete -> cmd._parser.complete, so these
tests drive that same call rather than inspecting the table.
"""
from pymol import cmd, testing


class TestPredictCompletion(testing.PyMOLTestCase):

    def testPredictListsPredictorsWhenNothingIsUnambiguous(self):
        """Nothing typed yet: the ids share no common prefix, so there is nothing to
        INSERT and Tab prints the list instead. None means "listed", not "failed" --
        the completer only returns a string when it has characters to add.

        This changed when simplefold was registered. While boltz2 and boltz2-bf16
        were the only ids, every id began with 'boltz2' and Tab silently filled that
        in; an id from a different family is what makes the listing appear.
        """
        self.assertIsNone(cmd._parser.complete('predict '))

    def testPartialPredictorNameCompletesAsFarAsItIsUnambiguous(self):
        """'boltz2' is a PREFIX of 'boltz2-bf16', so Tab stops there with no separator.

        The trailing ', ' only appears once one predictor is uniquely identified --
        which for the shorter id means the user has to type the comma themselves.
        """
        self.assertEqual(cmd._parser.complete('predict b'), 'predict boltz2')
        self.assertEqual(cmd._parser.complete('predict boltz2-'),
                         'predict boltz2-bf16, ')

    def testAnIdOutsideTheBoltzFamilyCompletesInOneKeystroke(self):
        """The payoff for not making the id a prefix-extension of an existing one:
        'simplefold' is unique from its first letter, separator and all."""
        self.assertEqual(cmd._parser.complete('predict s'), 'predict simplefold, ')

    def testPredictWeightsAlsoOffersPredictors(self):
        self.assertIsNone(cmd._parser.complete('predict_weights '))
        self.assertEqual(cmd._parser.complete('predict_weights s'),
                         'predict_weights simplefold, ')

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
