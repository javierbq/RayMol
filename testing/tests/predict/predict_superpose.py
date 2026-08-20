"""Appended models land in the frame of model 1 (#329).

A folding backend has no shared frame of reference: each seed comes back in whatever
orientation the network produced. Without a superposition, stepping through the states of
an `n_models` object makes the structure jump across the viewport, and every
`intra_rms_cur` reading is dominated by an arbitrary rigid-body offset rather than by the
conformational difference the number is supposed to report.

    pymol -ckqy testing/testing.py --run testing/tests/predict/predict_superpose.py
"""
import math
import os

from pymol import cmd, testing


def _write_helix(path, shift=(0.0, 0.0, 0.0), turn=0.0, bend=0.0):
    """An ideal 12-residue alpha helix, optionally rotated about z and translated.

    Backbone only (N/CA/C/O), which is what dss reads. `turn`/`shift` re-express the
    SAME molecule in another frame -- the cheapest faithful stand-in for two seeds of one
    prediction, because any residual RMSD between two of these files is purely the offset
    under test and never a real conformational difference.
    """
    rot = turn * math.pi / 180.0
    with open(path, 'w') as handle:
        serial = 1
        for i in range(12):
            phase = i * 100.0 * math.pi / 180.0
            for atom, elem, dr, dz in (('N', 'N', 1.5, 0.0), ('CA', 'C', 2.3, 0.4),
                                       ('C', 'C', 1.9, 0.9), ('O', 'O', 2.1, 1.2)):
                x, y, z = (dr * math.cos(phase), dr * math.sin(phase) + bend * i,
                           i * 1.5 + dz)
                x, y = x * math.cos(rot) - y * math.sin(rot), \
                       x * math.sin(rot) + y * math.cos(rot)
                handle.write('ATOM  %5d  %-3s ALA A%4d    %8.3f%8.3f%8.3f'
                             '  1.00  0.00          %2s\n'
                             % (serial, atom, i + 1, x + shift[0], y + shift[1],
                                z + shift[2], elem))
                serial += 1
        handle.write('END\n')


class TestSuperposeOnFirstModel(testing.PyMOLTestCase):

    def setUp(self):
        testing.PyMOLTestCase.setUp(self)
        self._tmp = testing.mkdtemp()
        self._n = 0
        self.root = self._tmp.__enter__()
        # Same molecule, three frames. `moved` is 25 A away and turned 90 degrees, which
        # is the scale of offset a real backend produces.
        self.origin = os.path.join(self.root, 'origin.pdb')
        self.moved = os.path.join(self.root, 'moved.pdb')
        self.moved2 = os.path.join(self.root, 'moved2.pdb')
        _write_helix(self.origin)
        _write_helix(self.moved, shift=(25.0, 0.0, 0.0), turn=90.0)
        _write_helix(self.moved2, shift=(0.0, -40.0, 12.0), turn=210.0)

    def tearDown(self):
        from pymol import predicting
        predicting.clear_pending()
        self._tmp.__exit__(None, None, None)
        testing.PyMOLTestCase.tearDown(self)

    def _coords(self, name, state):
        out = []
        cmd.iterate_state(state, name, 'out.append((x, y, z))', space={'out': out})
        return out

    def _deliver(self, name, path, seed=None):
        """One model landing, exactly as the host delivers it: a pending mark, then the
        load. Each job id is distinct because deliver_result retires one mark per call."""
        from pymol import predicting
        self._n += 1
        predicting.register_pending(name, 'job%d' % self._n)
        predicting.deliver_result(path, name, seed=seed)

    def testAnAppendedModelIsSuperposedOnTheFirst(self):
        """Delivered 25 A apart; two copies of one molecule must read as one molecule."""
        self._deliver('sup1', self.origin)
        self._deliver('sup1', self.moved)
        self.assertEqual(cmd.count_states('sup1'), 2)
        self.assertAlmostEqual(cmd.intra_rms_cur('sup1')[1], 0.0, places=3)

    def testEveryLaterModelIsSuperposedToo(self):
        """Not just the second: the fit has to run on each delivery, not once."""
        self._deliver('sup2', self.origin)
        self._deliver('sup2', self.moved)
        self._deliver('sup2', self.moved2)
        self.assertEqual(cmd.count_states('sup2'), 3)
        for rms in cmd.intra_rms_cur('sup2')[1:]:
            self.assertAlmostEqual(rms, 0.0, places=3)

    def testTheFirstModelNeverMoves(self):
        """The camera was framed on model 1, and anything positioned relative to it -- a
        co-loaded target, a measurement, a scene -- stays valid only if it holds still."""
        self._deliver('sup3', self.origin)
        before = self._coords('sup3', 1)
        self._deliver('sup3', self.moved)
        self._deliver('sup3', self.moved2)
        self.assertEqual(before, self._coords('sup3', 1))

    def testAlreadyFittedModelsAreNotDisturbedByLaterDeliveries(self):
        """Re-fitting the whole ensemble on each delivery is only acceptable if a settled
        model stays settled. Bound is 1e-4 A: a hair under the 1e-3 A precision the
        coordinates themselves carry, and measured drift is ~1e-6."""
        self._deliver('sup4', self.origin)
        self._deliver('sup4', self.moved)
        settled = self._coords('sup4', 2)
        for _ in range(5):
            self._deliver('sup4', self.moved2)
        for (x, y, z), (a, b, c) in zip(settled, self._coords('sup4', 2)):
            self.assertAlmostEqual(x, a, places=4)
            self.assertAlmostEqual(y, b, places=4)
            self.assertAlmostEqual(z, c, places=4)

    def testTheFirstDeliveryIsNotAFit(self):
        """One state has nothing to be superposed onto, and intra_fit on a single-state
        object must not be reported as a superposition that happened."""
        from pymol import predicting
        predicting.register_pending('sup5', 'j5')
        predicting.deliver_result(self.origin, 'sup5')
        self.assertIsNone(predicting.superpose_on_first_model('sup5'))

    def testADifferentMoleculeInTheSameNameIsLeftAlone(self):
        """Predicting another sequence into an existing name merges the atom sets, so each
        state holds only its own subset and a superposition is undefined. It must decline
        rather than fit garbage -- and the delivery must still succeed."""
        from pymol import predicting
        other = os.path.join(self.root, 'other.pdb')
        with open(other, 'w') as handle:
            handle.write('ATOM      1  N   GLY B   1      70.000  70.000  70.000'
                         '  1.00  0.00           N\nEND\n')
        self._deliver('sup6', self.origin)
        self._deliver('sup6', other)
        self.assertEqual(cmd.count_states('sup6'), 2)
        self.assertIsNone(predicting.superpose_on_first_model('sup6'))
        # The odd atom is still where its file put it: nothing was fitted.
        self.assertAlmostEqual(self._coords('sup6', 2)[-1][0], 70.0, places=2)

    def testTheReportedRMSDIsTheConformationalDifference(self):
        """The number the fit returns is what a user reads as 'how much do my models
        disagree'. For two copies of one molecule that is zero, not the offset they were
        delivered at."""
        from pymol import predicting
        self._deliver('sup7', self.origin)
        self._deliver('sup7', self.moved)
        rms = predicting.superpose_on_first_model('sup7')
        self.assertIsNotNone(rms)
        self.assertAlmostEqual(rms, 0.0, places=3)

    def testARealConformationalDifferenceSurvivesTheFit(self):
        """The point of the fit is to remove the frame offset and NOTHING else. A bent
        copy is delivered 44 A away with a 0.5 A bend the superposition cannot absorb;
        afterwards the reading has to be the bend, not the offset and not zero.

        Identical copies alone cannot show this -- they would also pass against a fit
        that reported zero unconditionally."""
        bent = os.path.join(self.root, 'bent.pdb')
        _write_helix(bent, shift=(0.0, -40.0, 12.0), turn=210.0, bend=0.5)
        self._deliver('sup8', self.origin)
        self._deliver('sup8', bent)
        rms = cmd.intra_rms_cur('sup8')[1]
        self.assertGreater(rms, 0.2, 'a real difference was fitted away')
        self.assertLess(rms, 1.0, 'the 44 A delivery offset was not removed')

