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
        with open(path) as f:
            data = json.load(f)
        self.assertEqual(data['object'], 'm1')
        self.assertEqual(data['state'], 1)
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
        path = os.path.join(tempfile.gettempdir(), 'raymol_design_residues.json')
        with open(path) as f:
            data = json.load(f)
        r0 = data['residues'][0]
        self.assertFalse(r0['valid'])
        self.assertIsNone(r0['o'])
        # The three remaining backbone atoms must still be present
        for k in ('n', 'ca', 'c'):
            self.assertIsNotNone(r0[k])
            self.assertEqual(len(r0[k]), 3)

    def testCoordsComeFromPassedState(self):
        cmd.reinitialize()
        cmd.fragment('ala', 'm1')
        cmd.create('multi', 'm1', 1, 1)          # state 1
        cmd.create('multi', 'm1', 1, 2)          # state 2 (copy of state 1)
        cmd.translate([10, 0, 0], 'multi', state=2)   # shift state 2 so coords differ
        from pymol import raymol_design
        path = os.path.join(tempfile.gettempdir(), 'raymol_design_residues.json')
        raymol_design.enumerate_design_residues('multi', 1)
        with open(path) as f:
            s1 = json.load(f)
        raymol_design.enumerate_design_residues('multi', 2)
        with open(path) as f:
            s2 = json.load(f)
        self.assertEqual(s1['state'], 1)
        self.assertEqual(s2['state'], 2)
        # CA coords must differ between states
        self.assertNotEqual(s1['residues'][0]['ca'], s2['residues'][0]['ca'])
        # The translation was exactly 10 Å along X
        self.assertAlmostEqual(
            s2['residues'][0]['ca'][0] - s1['residues'][0]['ca'][0], 10.0, places=3
        )
