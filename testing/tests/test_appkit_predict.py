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

    def test_predictors_are_listed_with_msa_capability(self):
        appkit_predict.emit('')
        payload = _payload()
        ids = [p['id'] for p in payload['predictors']]
        self.assertIn('boltz2', ids)
        boltz = next(p for p in payload['predictors'] if p['id'] == 'boltz2')
        self.assertTrue(boltz['msa'])
        self.assertEqual(payload['chains'], [])
        self.assertIsNone(payload['error'])

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
