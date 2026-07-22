"""Tests for pymol.raymol_design.enumerate_design_residues.

Runs via the repo test runner:
    pymol -ckqy testing/testing.py --run tests/raymol/design_enumerate.py
"""
import json
import os
import tempfile

from pymol import cmd, testing


class TestDesignEnumerate(testing.PyMOLTestCase):
    def testGuideOrderAndBackbone(self):
        cmd.reinitialize()
        cmd.fragment('ala', 'm1')            # a tiny residue with N,CA,C,O
        from pymol import raymol_design
        marker = raymol_design.enumerate_design_residues('m1', 1)
        self.assertEqual(marker, 'DESIGN_RESIDUES:ready')
        path = os.path.join(tempfile.gettempdir(), 'raymol_design_residues.json')
        data = json.load(open(path))
        self.assertEqual(data['object'], 'm1')
        r0 = data['residues'][0]
        self.assertEqual(r0['resn'], 'ALA')
        self.assertEqual(r0['aa'], 0)                 # 'A' -> index 0
        self.assertTrue(r0['valid'])
        for k in ('n', 'ca', 'c', 'o'):
            self.assertEqual(len(r0[k]), 3)

    def testMissingBackboneMasked(self):
        cmd.reinitialize()
        cmd.fragment('gly', 'm1')
        cmd.remove('m1 and name O')       # drop an O
        from pymol import raymol_design
        raymol_design.enumerate_design_residues('m1', 1)
        data = json.load(open(os.path.join(tempfile.gettempdir(), 'raymol_design_residues.json')))
        self.assertFalse(data['residues'][0]['valid'])
        self.assertIsNone(data['residues'][0]['o'])
