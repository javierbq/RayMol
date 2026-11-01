"""Tests for representation inspector query optimizations (#398).

Verifies that cmd._cmd.get_atom_reps returns the active atom representation
indices directly from the C++ core in O(atoms) rather than 11 count_atoms
selector passes, that groups return the union of member reps, that bad/empty
names return [], and that appkit_inspector._build produces identical rep lists
with and without fallback.

Runs on a RayMol --testing build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/inspector_reps.py
"""
import unittest.mock

from pymol import appkit_inspector as ai
from pymol import cmd, testing
from pymol.constants import repres


class TestInspectorAtomReps(testing.PyMOLTestCase):

    def setUp(self):
        super().setUp()
        cmd.reinitialize()

    def testGetAtomRepsFragmentAndHide(self):
        """get_atom_reps for peptide shown as cartoon+sticks returns those rep
        indices; after hide everything it returns []."""
        cmd.fragment('ala', 'm1')
        cmd.hide('everything', 'm1')
        cmd.show('cartoon', 'm1')
        cmd.show('sticks', 'm1')

        reps = cmd._cmd.get_atom_reps(cmd._COb, 'm1')
        expected = {repres['cartoon'], repres['sticks']}
        self.assertEqual(set(reps), expected)

        cmd.hide('everything', 'm1')
        reps_hidden = cmd._cmd.get_atom_reps(cmd._COb, 'm1')
        self.assertEqual(reps_hidden, [])

    def testGroupReturnsUnionOfMemberReps(self):
        """A group of two objects returns the union of member reps."""
        cmd.fragment('ala', 'm1')
        cmd.fragment('gly', 'm2')
        cmd.hide('everything', 'all')
        cmd.show('cartoon', 'm1')
        cmd.show('sticks', 'm2')
        cmd.show('spheres', 'm2')
        cmd.group('grp', 'm1 m2')

        reps = cmd._cmd.get_atom_reps(cmd._COb, 'grp')
        expected = {repres['cartoon'], repres['sticks'], repres['spheres']}
        self.assertEqual(set(reps), expected)

    def testBadNameReturnsEmpty(self):
        """A nonexistent name or invalid selection returns [] without crashing."""
        reps = cmd._cmd.get_atom_reps(cmd._COb, 'nonexistent_object_xyz')
        self.assertEqual(reps, [])

        reps_bad_syntax = cmd._cmd.get_atom_reps(cmd._COb, 'bad(syntax((')
        self.assertEqual(reps_bad_syntax, [])

    def testBuildMatchesCountAtomsInRepsOrder(self):
        """_build([obj])['detail'][obj] lists exactly the shown reps, in REPS order,
        identical to what count_atoms probe gives."""
        cmd.fragment('ala', 'm1')
        cmd.hide('everything', 'm1')
        cmd.show('cartoon', 'm1')
        cmd.show('sticks', 'm1')
        cmd.show('surface', 'm1')

        expected_reps = [
            r for r in ai.REPS
            if cmd.count_atoms('(%s) & rep %s' % ('m1', r)) > 0
        ]
        detail = ai._build(['m1'])['detail']['m1']
        actual_reps = [item['rep'] for item in detail]
        self.assertEqual(actual_reps, expected_reps)

    def testFallbackPathWhenGetAtomRepsRaises(self):
        """When get_atom_reps raises AttributeError (e.g. older core), fallback
        path returns the exact same result."""
        cmd.fragment('ala', 'm1')
        cmd.hide('everything', 'm1')
        cmd.show('cartoon', 'm1')
        cmd.show('lines', 'm1')

        normal_detail = ai._build(['m1'])['detail']['m1']
        normal_reps = [item['rep'] for item in normal_detail]

        with unittest.mock.patch.object(cmd._cmd, 'get_atom_reps', side_effect=AttributeError):
            fallback_shown = ai._shown_reps('m1')
            fallback_detail = ai._build(['m1'])['detail']['m1']
            fallback_reps = [item['rep'] for item in fallback_detail]

        self.assertEqual(fallback_shown, set(normal_reps))
        self.assertEqual(fallback_reps, normal_reps)
