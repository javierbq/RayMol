"""Tests for pymol.appkit_predict.emit — the Predict tool bar's data feed.

emit(input) writes pymol_predict_<pid>.json with the registered predictors and the
chains of the input, resolved exactly as `predict` resolves it, and prints the
short marker PREDICT_FORM:ready. Same tempfile-JSON contract as
appkit_inspector.poll_panel(): the payload can exceed PyMOL's ~1KB feedback-line
cap, so it must never ride the feedback line.
"""

import json
import os
import tempfile

from pymol import cmd, testing
from pymol import appkit_predict

# Data dir relative to this test file (testing/tests/test_appkit_predict.py
# → testing/data/).
_DATA = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'data')


def _payload():
    p = os.path.join(tempfile.gettempdir(), 'pymol_predict_%d.json' % os.getpid())
    with open(p) as f:
        return json.load(f)


class TestAppkitPredict(testing.PyMOLTestCase):

    def setUp(self):
        super().setUp()  # sets self.oldcwd, calls cmd.reinitialize()
        # Pose as an inference host advertising the BOLTZ RUNTIME ALONE.
        #
        # Needed at all because the form list is filtered by check_available (see
        # appkit_predict._predictors), and a bare test process is not a host: without
        # RAYMOL_PREDICT_HOST every predictor correctly refuses and the list is empty.
        # Tests that assert something IS offered must therefore say what host they are.
        #
        # "boltz" alone rather than "boltz,protenix" on purpose: that is exactly what
        # PyMOLBridge.mm advertises on iOS, so this reproduces the iOS filtering
        # condition in a test that runs on a Mac -- the Protenix packs are refused for
        # a missing runtime here for the same reason they are refused on a phone. No CI
        # runs on iOS, so this is the only place that gets checked.
        self._env_backup = {
            k: os.environ.get(k)
            for k in ('RAYMOL_PREDICT_HOST', 'RAYMOL_PREDICT_RUNTIMES')
        }
        os.environ['RAYMOL_PREDICT_HOST'] = '1'
        os.environ['RAYMOL_PREDICT_RUNTIMES'] = 'boltz'

    def tearDown(self):
        for key, value in getattr(self, '_env_backup', {}).items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        super().tearDown()

    def test_predictors_are_listed_with_msa_capability(self):
        appkit_predict.emit('')
        payload = _payload()
        ids = [p['id'] for p in payload['predictors']]
        self.assertIn('boltz2', ids)
        boltz = next(p for p in payload['predictors'] if p['id'] == 'boltz2')
        self.assertTrue(boltz['msa'])
        self.assertEqual(payload['chains'], [])
        self.assertIsNone(payload['error'])

    def test_only_runnable_predictors_are_listed(self):
        """The list is what can RUN here, not what is registered.

        The registry is platform-independent, so an unfiltered list offers methods the
        host will refuse at submit time -- on iOS that is all six Protenix packs, whose
        runtime is not linked. A menu entry that fails after the user has typed a
        sequence and hit Run is worse than no entry.
        """
        from pymol.predictors import registry

        appkit_predict.emit('')
        listed = {p['id'] for p in _payload()['predictors']}

        for pid in registry.available():
            with self.subTest(predictor=pid):
                try:
                    registry.get(pid).check_available()
                except Exception:
                    self.assertNotIn(pid, listed,
                                     '%s refuses check_available yet is offered' % pid)
                else:
                    self.assertIn(pid, listed,
                                  '%s can run yet is hidden' % pid)

        # Concrete instance of the above, spelled out so a regression names itself:
        # setUp advertises the boltz runtime alone, as iOS does.
        self.assertIn('boltz2', listed)
        self.assertFalse([p for p in listed if p.startswith('protenix')],
                         'a protenix pack was offered by a boltz-only host')

    def test_a_non_host_offers_nothing(self):
        """An empty list is the correct answer, not a bug to paper over.

        Under headless `pymol -c` nothing consumes the PREDICT: marker, so a submitted
        job would hang forever. The bar must offer nothing rather than something that
        cannot run. This is also the pre-filter behaviour's sharpest edge: the list used
        to be fully populated here.
        """
        os.environ.pop('RAYMOL_PREDICT_HOST', None)
        appkit_predict.emit('')
        payload = _payload()
        self.assertEqual(payload['predictors'], [])
        self.assertIsNone(payload['error'],
                          'having no runnable predictor is not a form error')

    def test_a_predictor_that_throws_is_hidden_not_fatal(self):
        """One bad method must not empty the menu, and must not be offered either.

        Unavailable is the conservative reading of an unexpected throw: the alternative
        is offering a method whose availability could not be established.
        """
        from pymol.predictors import registry
        from pymol.predictors.base import Predictor

        # A real Predictor subclass: registry.register type-checks, so a bare stub is
        # rejected before it can exercise the filter at all.
        class _Exploding(Predictor):
            id = 'exploding-test-predictor'
            name = 'Exploding test predictor'
            supports_msa = False

            def check_available(self):
                raise RuntimeError('boom')

            # Predictor is an ABC; both are abstract and must exist to instantiate.
            # Never reached: the filter drops this method before either is called.
            def parse_spec(self, sequence, name=''):
                raise AssertionError('unreachable')

            def submit(self, spec, options):
                raise AssertionError('unreachable')

        registry.register(_Exploding(), replace=True)
        try:
            appkit_predict.emit('')
            payload = _payload()
            ids = [p['id'] for p in payload['predictors']]
            self.assertNotIn('exploding-test-predictor', ids)
            self.assertIn('boltz2', ids, 'one bad predictor emptied the menu')
            self.assertIsNone(payload['error'], 'a bad predictor became a form error')
        finally:
            registry.unregister('exploding-test-predictor')

    def test_literal_monomer_resolves_to_one_chain(self):
        appkit_predict.emit('MKTAYIAKQRQISFVKSHFSRQLEERLGLIEVQ')
        payload = _payload()
        self.assertEqual(len(payload['chains']), 1)
        c = payload['chains'][0]
        self.assertEqual(c['id'], 'A')
        self.assertEqual(c['length'], 33)
        self.assertEqual(c['object'], '')   # a literal has no source object
        self.assertEqual(c['chain'], '')

    def test_literal_multimer_splits_on_slash(self):
        appkit_predict.emit('MKTAY/GSHMA')
        payload = _payload()
        self.assertEqual([c['id'] for c in payload['chains']], ['A', 'B'])
        self.assertEqual([c['length'] for c in payload['chains']], [5, 5])

    def test_object_input_carries_source_object_and_chain(self):
        # 1oky-frag.pdb is a small 42-residue single-chain-A fragment.
        cmd.load(os.path.join(_DATA, '1oky-frag.pdb'), 'obj1')
        appkit_predict.emit('obj1')
        payload = _payload()
        self.assertEqual(len(payload['chains']), 1)
        c = payload['chains'][0]
        self.assertEqual(c['object'], 'obj1')
        self.assertEqual(c['chain'], 'A')
        self.assertEqual(c['length'], 42)

    def test_bad_input_is_an_error_not_a_throw(self):
        appkit_predict.emit('not a real selection @@@')
        payload = _payload()
        self.assertEqual(payload['chains'], [])
        self.assertIsNotNone(payload['error'])
        # predictors are still resolved on the error path
        self.assertGreater(len(payload['predictors']), 0)
