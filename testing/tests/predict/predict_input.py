"""Resolving the `sequence` argument: a sequence string, an object, or a selection.

No predictor, no weights, no network -- just the session read that turns whatever the
user typed into the one-letter sequence a predictor is handed.

    pymol -ckqy testing/testing.py --run testing/tests/predict/predict_input.py
"""
from pymol import cmd, predicting, testing
from pymol.predictors.errors import PredictionInputError

#: One residue per line, with a full backbone so PyMOL classifies it as protein even
#: when the record is HETATM (Selector.cpp falls back to atom names + the C-N bond).
#: Written out rather than built with fab because the point of the fixture is the
#: NON-canonical residue in the middle, which fab cannot make.
MSE_PDB = """\
ATOM      1  N   ALA A   1       0.000   0.000   0.000  1.00  0.00           N
ATOM      2  CA  ALA A   1       1.458   0.000   0.000  1.00  0.00           C
ATOM      3  C   ALA A   1       2.009   1.420   0.000  1.00  0.00           C
ATOM      4  O   ALA A   1       1.251   2.390   0.000  1.00  0.00           O
HETATM    5  N   MSE A   2       3.332   1.540   0.000  1.00  0.00           N
HETATM    6  CA  MSE A   2       3.970   2.850   0.000  1.00  0.00           C
HETATM    7  C   MSE A   2       5.480   2.700   0.000  1.00  0.00           C
HETATM    8  O   MSE A   2       6.000   1.590   0.000  1.00  0.00           O
ATOM      9  N   GLY A   3       6.150   3.840   0.000  1.00  0.00           N
ATOM     10  CA  GLY A   3       7.600   3.900   0.000  1.00  0.00           C
ATOM     11  C   GLY A   3       8.200   5.290   0.000  1.00  0.00           C
ATOM     12  O   GLY A   3       7.500   6.300   0.000  1.00  0.00           O
END
"""


class PredictInputTest(testing.PyMOLTestCase):

    # -- literal sequences ------------------------------------------------------

    def testPlainSequencePassesThrough(self):
        self.assertEqual(predicting.resolve_sequence('MKTAY'), 'MKTAY')

    def testMultimerSequencePassesThrough(self):
        """'/' reads as a selection macro, so this must survive the selection probe."""
        self.assertEqual(predicting.resolve_sequence('MKTAY/GSHMA'), 'MKTAY/GSHMA')

    def testSequenceIsStrippedButNotOtherwiseTouched(self):
        self.assertEqual(predicting.resolve_sequence('  MKTAY\n'), 'MKTAY')

    def testEmptyInputRejected(self):
        self.assertRaises(PredictionInputError, predicting.resolve_sequence, '   ')

    def testNonStringRejected(self):
        self.assertRaises(PredictionInputError, predicting.resolve_sequence, 42)

    # -- objects and selections -------------------------------------------------

    def testObjectNameBecomesItsSequence(self):
        cmd.fab('ACDEFG', 'pep')
        self.assertEqual(predicting.resolve_sequence('pep'), 'ACDEFG')

    def testSelectionExpressionBecomesItsSequence(self):
        cmd.fab('ACDEFG', 'pep')
        self.assertEqual(predicting.resolve_sequence('pep and resi 1-3'), 'ACD')

    def testTwoObjectsFoldAsAComplex(self):
        """One chain per (object, chain id) -- a complex, not two monomers."""
        cmd.fab('ACDEFG', 'one')
        cmd.fab('GHIKL', 'two')
        self.assertEqual(predicting.resolve_sequence('one or two'), 'ACDEFG/GHIKL')

    def testAnObjectWinsOverASameSpelledSequence(self):
        """Documented precedence: the session is asked first."""
        cmd.fab('ACDEFG', 'AAA')
        self.assertEqual(predicting.resolve_sequence('AAA'), 'ACDEFG')

    def testNonProteinIsIgnored(self):
        cmd.fab('ACDEFG', 'pep')
        cmd.pseudoatom('pep', pos=[20., 20., 20.], resn='LIG', name='C1', elem='C')
        cmd.pseudoatom('pep', pos=[25., 25., 25.], resn='HOH', name='O', elem='O')
        self.assertEqual(predicting.resolve_sequence('pep'), 'ACDEFG')

    def testSelectionWithNoProteinRejected(self):
        cmd.pseudoatom('lig', pos=[0., 0., 0.], resn='LIG', name='C1', elem='C')
        self.assertRaises(PredictionInputError, predicting.resolve_sequence, 'lig')

    def testModifiedResidueReadsAsItsParent(self):
        """MSE -> M. Selenomethionine is in a large share of crystal structures, and
        get_fastastr's '?' would make every one of them unfoldable. Verified against
        real entries too: 1A8O is 4x MSE and comes back as the HIV-1 capsid sequence."""
        cmd.read_pdbstr(MSE_PDB, 'mse')
        self.assertEqual(predicting.resolve_sequence('mse'), 'AMG')

    def testPhosphoResidueReadsAsItsParent(self):
        """The modification is not modelled by any predictor here, so the choice is
        the parent residue or no prediction at all."""
        cmd.read_pdbstr(MSE_PDB, 'mse')
        cmd.alter('mse and resi 2', 'resn="PTR"')
        cmd.sort('mse')
        self.assertEqual(predicting.resolve_sequence('mse'), 'AYG')

    def testResidueWithNoUnambiguousParentRejected(self):
        """Refused, not silently dropped: a sequence shorter than the structure it
        came from, spliced across the hole, is a wrong answer nothing downstream
        could detect. DAL is a D-amino acid -- listing a parent would be a guess."""
        cmd.read_pdbstr(MSE_PDB, 'mse')
        cmd.alter('mse and resi 2', 'resn="DAL"')
        cmd.sort('mse')
        with self.assertRaises(PredictionInputError) as caught:
            predicting.resolve_sequence('mse')
        self.assertIn('DAL', str(caught.exception))

    # -- the failure that motivates the resolution ORDER ------------------------

    def testSelectionKeywordIsNotFoldedAsAPeptide(self):
        """'polymer' is seven valid residue letters. Sniffing the text instead of
        asking the session would fold it while the real structure sat loaded."""
        cmd.fab('ACDEFG', 'pep')
        self.assertEqual(predicting.resolve_sequence('polymer'), 'ACDEFG')

    def testMistypedSelectionRaisesInsteadOfFolding(self):
        """'chian A' must not become the pentapeptide CHIANA."""
        cmd.fab('ACDEFG', 'pep')
        self.assertRaises(Exception, predicting.resolve_sequence, 'chian A')

    def testSelectionMatchingNothingRaises(self):
        cmd.fab('ACDEFG', 'pep')
        self.assertRaises(PredictionInputError,
                          predicting.resolve_sequence, 'pep and resi 999')

    def testUnknownObjectNameRaises(self):
        """Not sequence-shaped (digits), so it is a selection -- and a broken one."""
        self.assertRaises(Exception, predicting.resolve_sequence, '1ubq')

    # -- verbose path -----------------------------------------------------------

    def testVerboseResolutionDoesNotRaise(self):
        """quiet=0 is what the command line uses (parsing.py:417)."""
        cmd.fab('ACDEFG', 'pep')
        self.assertEqual(predicting.resolve_sequence('pep', quiet=0), 'ACDEFG')
