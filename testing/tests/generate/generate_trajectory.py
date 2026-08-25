"""The trajectory object a live design builds up, one state per captured frame.

    pymol -ckqy testing/testing.py --run testing/tests/generate/generate_trajectory.py
"""
import os
import sys

from pymol import cmd

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

from generate_harness import GeneratorTestCase  # noqa: E402


def _seed_pdb(length=3, chain='B'):
    """A poly-ALA backbone, the shape RFD3Trajectory.seedPDB emits."""
    lines = []
    serial = 1
    for residue in range(length):
        for name in ('N', 'CA', 'C', 'O', 'CB'):
            lines.append(
                'ATOM  %5d  %-3s ALA %s%4d       0.000   0.000   0.000  1.00  0.00'
                '          %2s' % (serial, name, chain, residue + 1, name[0]))
            serial += 1
    lines.append('TER')
    lines.append('END')
    return '\n'.join(lines) + '\n'


class TrajectoryTest(GeneratorTestCase):

    def setUp(self):
        GeneratorTestCase.setUp(self)
        from pymol import designing
        self.designing = designing

    def testSeedingCreatesAOneStateObjectWithTheExpectedAtoms(self):
        self.designing.trajectory_seed('traj', _seed_pdb(length=3))
        self.assertIn('traj', cmd.get_names('objects'))
        self.assertEqual(cmd.count_atoms('traj'), 15)
        self.assertEqual(cmd.count_states('traj'), 1)

    def testEachFrameAppendsAStateAndTheAtomCountNeverChanges(self):
        # PyMOL states of one object share an atom set; a frame that changed it would be
        # rejected, and a trajectory that grew atoms would not be scrubbable.
        self.designing.trajectory_seed('traj', _seed_pdb(length=2))
        for step in range(1, 6):
            coords = [float(step)] * 30          # 10 atoms x 3
            self.designing.trajectory_frame('traj', coords)
        self.assertEqual(cmd.count_states('traj'), 6)
        self.assertEqual(cmd.count_atoms('traj'), 10)

    def testAFrameActuallyMovesTheAtoms(self):
        # Coordinates are intentionally distinct per atom: load_coordset loads in the
        # original atom order the seed PDB wrote, and a uniform frame (all atoms identical)
        # would make the assertions order-blind -- they would pass even if atoms were
        # silently permuted.  With range(15), atom 0 expects [0,1,2] and atom 2 (an
        # interior atom) expects [6,7,8]; a misordering yields a wrong value, not a
        # coincidentally-right one.
        self.designing.trajectory_seed('traj', _seed_pdb(length=1))
        self.designing.trajectory_frame('traj', [float(i) for i in range(15)])
        model = cmd.get_model('traj', state=2)
        self.assertAlmostEqual(model.atom[0].coord[0], 0.0, places=3)
        self.assertAlmostEqual(model.atom[0].coord[2], 2.0, places=3)
        # Interior atom -- the load order contract is violated if this is wrong.
        self.assertAlmostEqual(model.atom[2].coord[0], 6.0, places=3)
        self.assertAlmostEqual(model.atom[2].coord[2], 8.0, places=3)

    def testAFrameForAnUnknownObjectIsANoOpNotAnError(self):
        # The user may delete the object mid-run, which is legitimate. Live view must
        # degrade to nothing rather than raise into a running design.
        self.designing.trajectory_frame('nosuchobject', [1.0, 2.0, 3.0])
        self.assertNotIn('nosuchobject', cmd.get_names('objects'))

    def testAWrongLengthFrameIsDroppedRatherThanCorrupting(self):
        self.designing.trajectory_seed('traj', _seed_pdb(length=2))
        self.designing.trajectory_frame('traj', [1.0, 2.0])      # not a multiple of 3
        self.designing.trajectory_frame('traj', [1.0] * 300)     # wrong atom count
        self.assertEqual(cmd.count_states('traj'), 1)
