"""Reading a design target out of the session, and refusing what cannot be represented.

    pymol -ckqy testing/testing.py --run testing/tests/generate/generate_target.py

Every refusal here exists because the ENGINE would not make it. Its featurizer gives every
target residue the same chain and numbers them contiguously, and it skips a residue it has
no atom template for while the hotspot indices keep counting -- so a target it cannot
represent does not fail, it produces a confident design against a structure the user did
not select.
"""
import os
import sys

from pymol import cmd

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

from generate_harness import GeneratorTestCase  # noqa: E402


class ResolveTargetTest(GeneratorTestCase):

    def setUp(self):
        GeneratorTestCase.setUp(self)
        from pymol import designing
        self.designing = designing
        self.generator = __import__('pymol.generators.rfd3', fromlist=['RFD3Generator'])

    def resolve(self, target, hotspots):
        return self.designing.resolve_target(target, hotspots)

    # -- The residue array is what the engine will see -----------------------

    def testResiduesComeBackInSessionOrderWithTheirOwnIdentity(self):
        self.helix('t', length=6, chain='H', first=41)
        structure = self.resolve('t', 't and resi 43')
        self.assertEqual([r.resi for r in structure.residues],
                         ['41', '42', '43', '44', '45', '46'])
        self.assertEqual({r.chain for r in structure.residues}, {'H'})
        self.assertEqual({r.resn for r in structure.residues}, {'ALA'})
        # Heavy atoms only: the engine's dense templates are keyed by heavy-atom name, so a
        # hydrogen is wire weight that reaches nothing.
        self.assertTrue(all(not name.startswith('H') for r in structure.residues
                            for name, _ in r.atoms))

    def testHotspotsResolveToPOSITIONSNotResidueNumbers(self):
        # The single most dangerous mapping in this feature. The featurizer tests hotspot
        # membership against a residue's INDEX in the array it was handed and never reads a
        # residue number, so sending 43 where index 2 was meant conditions the design on
        # the wrong residues -- which looks like a bad design, not like a bug.
        self.helix('t', length=6, chain='H', first=41)
        structure = self.resolve('t', 't and resi 43+45')
        self.assertEqual(structure.hotspots, (2, 4))
        self.assertEqual([structure.residues[i].resi for i in structure.hotspots],
                         ['43', '45'])

    def testTheStateIsRecordedRatherThanLeftAmbiguous(self):
        # State 3 of an NMR ensemble is a different target from state 1, and the design key
        # has to say which. `-1` would leave it to whatever the session happened to show.
        self.helix('t', length=5)
        structure = self.resolve('t', 't and resi 2')
        self.assertEqual(structure.state, cmd.get_state())
        self.assertEqual(structure.source, 't')

    def testInsertionCodesSurvive(self):
        # Supported BECAUSE the target ships as a residue array. Routed through RFD3Kit's
        # own PDB reader instead, 45 and 45A would merge into one residue holding both sets
        # of atoms -- it keys on (chain, resSeq, resName) and never reads column 27.
        self.helix('t', length=3, chain='H', first=45)
        cmd.alter('t and resi 46', 'resi="45A"')
        cmd.sort('t')
        structure = self.resolve('t', 't and resi 45A')
        # As a SET, deliberately: whether PyMOL sorts 45A before or after 45 is its own
        # business, and pinning it here would make this test about `cmd.sort`. What matters
        # is that the two stay DISTINCT residues rather than merging into one.
        self.assertEqual({r.resi for r in structure.residues}, {'45', '45A', '47'})
        self.assertEqual(len(structure.residues), 3)
        # And that the hotspot resolves to whichever position 45A actually holds.
        self.assertEqual(len(structure.hotspots), 1)
        self.assertEqual(structure.residues[structure.hotspots[0]].resi, '45A')

    def testOnlyTheFirstAltlocIsTaken(self):
        self.helix('t', length=3)
        cmd.alter('t and resi 2 and name CB', 'alt="A"')
        cmd.alter('t and resi 2 and name CA', 'alt="B"')
        cmd.sort('t')
        structure = self.resolve('t', 't and resi 2')
        names = [name for name, _ in structure.residues[1].atoms]
        self.assertIn('CB', names, 'altloc A is kept')
        self.assertNotIn('CA', names, 'altloc B is a second conformer of one slot')

    def testAMovedTargetIsReadWHEREITISNotWhereItWasStored(self):
        """`iterate_state` does NOT apply the object's TTT matrix; get_coords does.

        Measured: after `translate [10,0,0], object=t`, `cmd.get_coords` reads 9.999 for an
        atom `cmd.iterate_state` still reads as -0.001. RayMol ships Move mode, which IS a
        TTT matrix, so a user can move a target and then design against it -- and without
        applying the matrix the design is generated against where the target used to be and
        lands ten Angstrom off the structure on screen.

        Asserted against `get_coords`, i.e. against what the viewport draws, rather than
        against a hardcoded offset -- that is the definition that matters.
        """
        self.helix('t', length=5)
        cmd.translate([10, 0, 0], object='t')
        structure = self.resolve('t', 't and resi 2')
        drawn = cmd.get_coords('t and name CA')
        read = [xyz for residue in structure.residues
                for name, xyz in residue.atoms if name == 'CA']
        self.assertEqual(len(drawn), len(read))
        worst = max(sum((a - b) ** 2 for a, b in zip(p, q)) ** 0.5
                    for p, q in zip(drawn, read))
        self.assertLess(worst, 1e-3,
                        'target read %.3f A from where it is drawn' % worst)

    def testAnUnmovedTargetIsNotTouchedByTheMatrixPath(self):
        # The identity case must be bit-identical, not merely close: the design key hashes
        # these coordinates, so float noise from a needless multiply would make two runs of
        # the same design key differently.
        self.helix('t', length=5)
        before = self.resolve('t', 't and resi 2')
        after = self.resolve('t', 't and resi 2')
        self.assertEqual([r.atoms for r in before.residues],
                         [r.atoms for r in after.residues])
        raw = []
        cmd.iterate_state(cmd.get_state(), 't and name CA',
                          'raw.append((x, y, z))', space={'raw': raw})
        read = [xyz for residue in before.residues
                for name, xyz in residue.atoms if name == 'CA']
        self.assertEqual(raw, read)

    # -- Refusals ------------------------------------------------------------

    def testANonStandardResidueIsExcludedAndReported(self):
        # Excluded rather than substituted, and REPORTED because it leaves a hole: the
        # residues on either side are then presented to the network as neighbours.
        import io
        from contextlib import redirect_stdout
        self.helix('t', length=5)
        cmd.alter('t and resi 3', 'resn="MSE"')
        cmd.sort('t')
        with redirect_stdout(io.StringIO()) as buf:
            structure = self.resolve('t', 't and resi 2')
        self.assertEqual([r.resi for r in structure.residues], ['1', '2', '4', '5'])
        self.assertIn('EXCLUDED', buf.getvalue())
        self.assertIn('/3', buf.getvalue())

    def testATargetSpanningTwoObjectsIsRefused(self):
        from pymol.predictors.errors import PredictionInputError
        # Not 'a' and 'b': `b` is PyMOL's B-factor selection keyword and `cmd.fab` builds
        # internal selections from the object name, so an object called `b` cannot be made.
        self.helix('one', length=4)
        self.helix('two', length=4)
        self.assertRaises(PredictionInputError, self.resolve, 'one or two',
                          'one and resi 2')

    def testATargetSpanningTwoChainsIsRefusedByTheGenerator(self):
        from pymol.predictors.errors import PredictionInputError
        self.helix('t', length=6, chain='A')
        cmd.alter('t and resi 4-6', 'chain="B"')
        cmd.sort('t')
        structure = self.resolve('t', 't and resi 2')
        generator = self.generator.RFD3Generator()
        with self.assertRaises(PredictionInputError) as caught:
            generator.parse_target(structure, 30)
        # The message has to say WHY, because "one chain only" sounds like a limitation of
        # RayMol rather than a misrepresentation of the target.
        self.assertIn('chain', str(caught.exception))
        self.assertIn('peptide bond', str(caught.exception))

    def testAnEmptySelectionIsRefused(self):
        from pymol.predictors.errors import PredictionInputError
        self.helix('t', length=4)
        self.assertRaises(PredictionInputError, self.resolve, 't and resi 99',
                          't and resi 2')

    def testNoHotspotsIsRefusedWithTheReason(self):
        from pymol.predictors.errors import PredictionInputError
        self.helix('t', length=4)
        with self.assertRaises(PredictionInputError) as caught:
            self.resolve('t', '')
        self.assertIn('origin', str(caught.exception))

    def testABareResidueListIsRefusedWithTheSelectionToUse(self):
        # `hotspots=45+48` is the mistake a user makes first: it is a valid thing to type
        # and selects nothing. The refusal shows the working spelling.
        from pymol.predictors.errors import PredictionInputError
        self.helix('t', length=6)
        with self.assertRaises(PredictionInputError) as caught:
            self.resolve('t', '2+4')
        self.assertIn('resi 2+4', str(caught.exception))

    def testAHotspotOutsideTheTargetIsRefusedNotDropped(self):
        # Dropping it silently would aim the design somewhere other than where it was
        # pointed, which is indistinguishable from a bad design.
        from pymol.predictors.errors import PredictionInputError
        self.helix('t', length=10)
        with self.assertRaises(PredictionInputError) as caught:
            self.resolve('t and resi 1-5', 't and resi 8')
        self.assertIn('/8', str(caught.exception))

    def testAHotspotSelectionThatSelectsNothingIsRefused(self):
        from pymol.predictors.errors import PredictionInputError
        self.helix('t', length=4)
        self.assertRaises(PredictionInputError, self.resolve, 't', 't and resi 77')


class DesignKeyTest(GeneratorTestCase):
    """The identity a later refold is keyed to. Everything that changes the coordinates
    must change it, and nothing that does not may."""

    def setUp(self):
        GeneratorTestCase.setUp(self)
        from pymol import designing
        from pymol.generators.rfd3 import RFD3Generator
        self.designing = designing
        self.generator = RFD3Generator()
        self.helix('t', length=8, chain='A', first=10)
        self.structure = designing.resolve_target('t', 't and resi 12+14')
        self.spec = self.generator.parse_target(self.structure, 20, name='d')
        self.options = self.generator.validate_options({'seed': 7})

    def key(self, **overrides):
        options = self.generator.validate_options(dict({'seed': 7}, **overrides))
        return self.spec.design_key(options, weights_version='rfd3-mlx-fp32 v1')

    def testTheKeyIsStableForTheSameDesign(self):
        self.assertEqual(self.key(), self.key())
        self.assertEqual(len(self.key()), 16)

    def testTheSeedChangesIt(self):
        self.assertNotEqual(self.key(), self.key(seed=8))

    def testTheScheduleChangesIt(self):
        self.assertNotEqual(self.key(), self.key(diffusion_steps=100))
        self.assertNotEqual(self.key(), self.key(recycling_steps=3))

    def testTheWeightPackChangesIt(self):
        self.assertNotEqual(
            self.spec.design_key(self.options, weights_version='rfd3-mlx-fp32 v1'),
            self.spec.design_key(self.options, weights_version='rfd3-mlx-int8 v1'))

    def testTheLengthChangesIt(self):
        other = self.generator.parse_target(self.structure, 21, name='d')
        self.assertNotEqual(self.key(),
                            other.design_key(self.options,
                                             weights_version='rfd3-mlx-fp32 v1'))

    def testTheHOTSPOTSChangeIt(self):
        # The hotspots set the sampler origin, so they change the RESULT and not merely how
        # it is scored. A key that ignored them would call two different designs the same.
        other_structure = self.designing.resolve_target('t', 't and resi 13+15')
        other = self.generator.parse_target(other_structure, 20, name='d')
        self.assertNotEqual(self.key(),
                            other.design_key(self.options,
                                             weights_version='rfd3-mlx-fp32 v1'))

    def testMOVINGTheTargetChangesIt(self):
        # Same residues, different coordinates, is a different design. The key hashes the
        # coordinates for exactly this case -- a target that was translated or minimised
        # between two runs.
        before = self.key()
        cmd.translate([5, 0, 0], object='t')
        moved = self.designing.resolve_target('t', 't and resi 12+14')
        after = self.generator.parse_target(moved, 20, name='d').design_key(
            self.options, weights_version='rfd3-mlx-fp32 v1')
        self.assertNotEqual(before, after)

    def testTheOBJECTNAMEDoesNotChangeIt(self):
        # The name is not part of the design. Two identically-specified designs under
        # different object names are the same design and must key the same, or a refold
        # could not be matched to one.
        renamed = self.generator.parse_target(self.structure, 20, name='somethingelse')
        self.assertEqual(self.key(),
                         renamed.design_key(self.options,
                                            weights_version='rfd3-mlx-fp32 v1'))
