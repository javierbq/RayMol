"""Tab completion for the predict commands.

    pymol -ckqy testing/testing.py --run testing/tests/predict/predict_completion.py

Registering a command in keywords.py makes its NAME completable but gives Tab nothing
to offer for its arguments -- that needs an entry in completing.get_auto_arg_list().
The app reaches this through PyMOLBridge_Complete -> cmd._parser.complete, so these
tests drive that same call rather than inspecting the table.
"""
from pymol import cmd, testing


class TestPredictCompletion(testing.PyMOLTestCase):

    def testPredictCompletesNothingWhenTheIdsShareNoPrefix(self):
        """Tab extends the line to the LONGEST COMMON PREFIX, or not at all.

        With `boltz2`, `boltz2-bf16` and `protenix-base` registered there is no common
        prefix, so an empty argument completes to nothing and the parser returns None.
        The candidate list is still shown -- that is `complete`'s side effect, not its
        return value. This assertion is about the registry's contents, so it moves every
        time a predictor whose id starts with a new letter is added.
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

    def testAnIdSharingNoPrefixCompletesInOneStep(self):
        """The payoff for NOT naming it `protenix`: 'p' identifies it uniquely.

        Had a second Protenix pack shipped as `protenix`, this would stop at the bare
        `protenix` with no separator -- the dead end `boltz2` already creates above.
        """
        self.assertEqual(cmd._parser.complete('predict p'),
                         'predict protenix-base, ')

    def testPredictWeightsAlsoOffersPredictors(self):
        self.assertEqual(cmd._parser.complete('predict_weights b'),
                         'predict_weights boltz2')
        self.assertIsNone(cmd._parser.complete('predict_weights '))

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
