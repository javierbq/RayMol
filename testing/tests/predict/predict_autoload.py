"""Auto-load: a prediction lands in the session by itself, under a content-derived name.

    pymol -ckqy testing/testing.py --run testing/tests/predict/predict_autoload.py
"""
import os
import sys
from unittest.mock import patch

from pymol import cmd, testing

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

from predict_weights_download import FakeResponse, make_zip
from predict_api import install_stub


class TestDefaultName(testing.PyMOLTestCase):

    def testNameIsDerivedFromTheSequence(self):
        from pymol.predicting import default_object_name
        name = default_object_name('MKTAYIAKQRQ')
        self.assertTrue(name.startswith('prediction_'), name)
        self.assertEqual(len(name), len('prediction_') + 8)

    def testMethodIsPrependedWhenGiven(self):
        from pymol.predicting import default_object_name
        name = default_object_name('MKTAY', 'boltz2')
        self.assertTrue(name.startswith('boltz2_prediction_'), name)

    def testDifferentMethodsGiveDifferentObjects(self):
        """Two methods folding one sequence are not two models of one distribution."""
        from pymol.predicting import default_object_name
        self.assertNotEqual(default_object_name('MKTAY', 'boltz2'),
                            default_object_name('MKTAY', 'other'))

    def testMethodNameIsSanitisedIntoAValidObjectName(self):
        from pymol.predicting import default_object_name
        name = default_object_name('MKTAY', 'we/ird name!')
        cmd.create(name, 'none')
        self.assertIn(name, cmd.get_names('objects'))

    def testSameSequenceGivesTheSameName(self):
        from pymol.predicting import default_object_name
        self.assertEqual(default_object_name('MKTAY'), default_object_name('MKTAY'))

    def testNameIsCaseAndWhitespaceInsensitive(self):
        """Otherwise 'mktay' and 'MKTAY ' produce two objects for one protein."""
        from pymol.predicting import default_object_name
        self.assertEqual(default_object_name('MKTAY'),
                         default_object_name(' mktay\n'))

    def testDifferentSequencesGiveDifferentNames(self):
        from pymol.predicting import default_object_name
        self.assertNotEqual(default_object_name('MKTAY'),
                            default_object_name('MKTAW'))

    def testMultimerSeparatorIsPartOfTheIdentity(self):
        """A/B is a different complex from the concatenation AB."""
        from pymol.predicting import default_object_name
        self.assertNotEqual(default_object_name('MK/TAY'),
                            default_object_name('MKTAY'))

    def testNameIsAValidPyMOLObjectName(self):
        from pymol.predicting import default_object_name
        name = default_object_name('MKTAY')
        cmd.create(name, 'none')
        self.assertIn(name, cmd.get_names('objects'))


class TestPlaceholder(testing.PyMOLTestCase):

    def setUp(self):
        testing.PyMOLTestCase.setUp(self)
        from pymol.predictors import registry
        self._saved = dict(registry._REGISTRY)
        self._tmp = testing.mkdtemp()
        self.root = self._tmp.__enter__()
        os.environ['RAYMOL_WEIGHTS_DIR'] = self.root
        self.data, self.digest = make_zip()
        install_stub(self.root, self.digest, len(self.data))

    def tearDown(self):
        from pymol import predicting
        from pymol.predictors import registry
        predicting.clear_pending()
        registry._REGISTRY.clear()
        registry._REGISTRY.update(self._saved)
        os.environ.pop('RAYMOL_WEIGHTS_DIR', None)
        self._tmp.__exit__(None, None, None)
        testing.PyMOLTestCase.tearDown(self)

    def _submit(self, seq='AG', **kw):
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data)):
            return cmd.predict('stub', seq, **kw)

    def testSubmitCreatesAnEmptyPlaceholder(self):
        job = self._submit()
        from pymol.predicting import default_object_name
        name = default_object_name('AG', 'stub')
        self.assertIn(name, cmd.get_names('objects'))
        self.assertEqual(cmd.count_atoms(name), 0)

    def testExplicitNameOverridesTheDerivedOne(self):
        self._submit(name='my_test')
        self.assertIn('my_test', cmd.get_names('objects'))

    def testPlaceholderIsRegisteredAsPending(self):
        job = self._submit(name='my_test')
        from pymol.predicting import pending_objects
        self.assertIn('my_test', pending_objects())
        self.assertEqual(pending_objects()['my_test'], job.job_id)

    def testPendingDetailDescribesTheJob(self):
        """This string is what the object panel shows on hover."""
        self._submit(name='my_test')
        from pymol.predicting import pending_detail
        detail = pending_detail('my_test')
        self.assertIsNotNone(detail)
        self.assertIn('pending', detail.lower())

    def testCleanupRemovesAnEmptyPlaceholder(self):
        self._submit(name='my_test')
        from pymol import predicting
        predicting.discard_pending('my_test')
        self.assertNotIn('my_test', cmd.get_names('objects'))
        self.assertNotIn('my_test', predicting.pending_objects())

    def testCleanupKeepsAnObjectThatAlreadyHasAtoms(self):
        """A completed job's object must never be deleted by late cleanup."""
        self._submit(name='my_test')
        cmd.pseudoatom('my_test')
        from pymol import predicting
        predicting.discard_pending('my_test')
        self.assertIn('my_test', cmd.get_names('objects'))
        self.assertNotIn('my_test', predicting.pending_objects())


class TestDelivery(testing.PyMOLTestCase):
    """Loading a finished result into its placeholder, and retiring the pending mark."""

    def setUp(self):
        testing.PyMOLTestCase.setUp(self)
        self.pdb = os.path.join(self.tmpdir(), 'r.pdb') if hasattr(self, 'tmpdir') else None
        self._tmp = testing.mkdtemp()
        self.root = self._tmp.__enter__()
        self.pdb = os.path.join(self.root, 'r.pdb')
        with open(self.pdb, 'w') as handle:
            handle.write('ATOM      1  N   ALA A   1       0.000   0.000   0.000'
                         '  1.00  0.00           N\nEND\n')

    def tearDown(self):
        from pymol import predicting
        predicting.clear_pending()
        self._tmp.__exit__(None, None, None)
        testing.PyMOLTestCase.tearDown(self)

    def testDeliveryLoadsIntoThePlaceholderAtStateOne(self):
        """The empty placeholder must not consume a state, or model numbering is off."""
        from pymol import predicting
        predicting.register_pending('p1', 'job1')
        predicting.deliver_result(self.pdb, 'p1')
        self.assertEqual(cmd.count_states('p1'), 1)
        self.assertEqual(cmd.count_atoms('p1'), 1)

    def testRepeatDeliveryAppendsAnotherModel(self):
        from pymol import predicting
        predicting.register_pending('p2', 'job2')
        predicting.deliver_result(self.pdb, 'p2')
        predicting.deliver_result(self.pdb, 'p2')
        self.assertEqual(cmd.count_states('p2'), 2)

    def testDeliveryRetiresThePendingMark(self):
        """Left pending, the object would be stripped from every later session save."""
        from pymol import predicting
        predicting.register_pending('p3', 'job3')
        predicting.deliver_result(self.pdb, 'p3')
        self.assertNotIn('p3', predicting.pending_objects())

    def testDeliveryDoesNotMoveTheCamera(self):
        from pymol import predicting
        cmd.pseudoatom('anchor')
        cmd.zoom('anchor')
        before = cmd.get_view()
        predicting.register_pending('p4', 'job4')
        predicting.deliver_result(self.pdb, 'p4')
        self.assertArrayEqual(before, cmd.get_view(), delta=1e-4)


class TestSessionExclusion(testing.PyMOLTestCase):
    """A pending placeholder must not reach the .pse -- it could never fill on reload."""

    def tearDown(self):
        from pymol import predicting
        predicting.clear_pending()
        testing.PyMOLTestCase.tearDown(self)

    def testPendingPlaceholderIsStrippedFromTheSession(self):
        from pymol import predicting
        cmd.pseudoatom('keep_me')
        predicting.register_pending('pending_one', 'jobX')
        session = cmd.get_session()
        predicting.session_save(session)
        names = [e[0] for e in session['names'] if e]
        self.assertIn('keep_me', names)
        self.assertNotIn('pending_one', names)

    def testStructuralNoneEntriesArePreserved(self):
        """PyMOL's names list carries None entries; dropping them corrupts the session."""
        from pymol import predicting
        cmd.pseudoatom('keep_me')
        predicting.register_pending('pending_one', 'jobX')
        session = cmd.get_session()
        before = sum(1 for e in session['names'] if not e)
        predicting.session_save(session)
        self.assertEqual(sum(1 for e in session['names'] if not e), before)

    def testAnObjectThatGainedAtomsIsKeptEvenIfStillMarkedPending(self):
        """A job completing between submit and save must not lose its structure."""
        from pymol import predicting
        predicting.register_pending('almost', 'jobY')
        cmd.pseudoatom('almost')
        session = cmd.get_session()
        predicting.session_save(session)
        self.assertIn('almost', [e[0] for e in session['names'] if e])

    def testTheTaskIsRegisteredSoARealSaveIsCovered(self):
        import pymol
        from pymol import predicting
        names = [getattr(t, '__name__', '') for t in pymol._session_save_tasks]
        self.assertIn('session_save', names)
        self.assertIn(predicting.session_save, pymol._session_save_tasks)

    def testARealPseSaveOmitsThePlaceholder(self):
        """End to end through cmd.save, which is what the user and the UI both call."""
        from pymol import predicting
        with testing.mkdtemp() as root:
            cmd.pseudoatom('keep_me')
            predicting.register_pending('pending_two', 'jobZ')
            path = os.path.join(root, 's.pse')
            cmd.save(path)
            cmd.delete('all')
            cmd.load(path)
            names = cmd.get_names('objects')
            self.assertIn('keep_me', names)
            self.assertNotIn('pending_two', names)
