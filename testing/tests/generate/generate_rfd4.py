"""The shipped rfd4 generator's own declarations and refusals.

    pymol -ckqy testing/testing.py --run testing/tests/generate/generate_rfd4.py

What is tested here is everything RFD4-Proteina would ACCEPT and quietly reinterpret, plus
the two places it must not be confused with rfd3: it generates its target rather than
holding it fixed, so it declares a different metric key, and it exposes no schedule knobs,
so it declares a different option set.
"""
import json
import os
import sys

from pymol import cmd

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

from generate_harness import GeneratorTestCase  # noqa: E402


class RFD4GeneratorTest(GeneratorTestCase):

    def setUp(self):
        GeneratorTestCase.setUp(self)
        self.declareHost('boltz,protenix,rfd3,rfd4')

    def generator(self):
        from pymol.generators import registry
        return registry.get('rfd4')

    def target(self, name='t', length=12, chain='A', first=1, hotspots='resi 4+6'):
        from pymol import designing
        self.helix(name, length=length, chain=chain, first=first)
        return designing.resolve_target(name, '%s and %s' % (name, hotspots))

    def submitted(self, length=20, **kwargs):
        """The request dict rfd4 actually writes, read back off disk."""
        import io
        from contextlib import redirect_stdout
        structure = self.target(**kwargs)
        generator = self.generator()
        spec = generator.parse_target(structure, length, name='obj')
        options = generator.validate_options({})
        with redirect_stdout(io.StringIO()):
            job = generator.submit(spec, options, weights_path='/nonexistent')
        with open(job.request_path) as handle:
            request = json.load(handle)
        os.remove(job.request_path)
        return request

    # -- Registration ------------------------------------------------------

    def testItIsRegisteredAndNamesItsOwnRuntime(self):
        from pymol.generators import registry
        self.assertIn('rfd4', registry.available())
        from pymol.generators import rfd4
        self.assertEqual(self.generator().id, 'rfd4')
        self.assertEqual(rfd4.RUNTIME, 'rfd4')
        # A request with NO runtime key is read as boltz at the far end, which for a
        # generator means folding an empty chain list -- a confident wrong answer rather
        # than a failure.
        self.assertEqual(self.submitted()['runtime'], 'rfd4')

    def testItDoesNotShadowRFD3(self):
        from pymol.generators import registry
        self.assertIn('rfd3', registry.available())
        self.assertNotEqual(registry.get('rfd3'), registry.get('rfd4'))
        self.assertNotEqual(registry.get('rfd3').weight_bundle.id,
                            self.generator().weight_bundle.id)

    # -- The weight bundle -------------------------------------------------

    def testTheBundleIsDeclaredFlatAndPinnedToAPublishedAsset(self):
        bundle = self.generator().weight_bundle
        self.assertEqual(bundle.id, 'rfd4-proteina-mlx-fp16')
        self.assertEqual(bundle.version, 'v1')
        # The members the pack actually holds. RayMol's extractor compares the archive's
        # member set against this and rejects anything that is not a plain file name, so a
        # nested zip fails here rather than inside the loader.
        self.assertEqual(bundle.members, ('manifest.json', 'rfd4_core.safetensors'))
        # A 64-hex sha256, taken from the uploaded asset rather than the local build. The
        # pack carries an `exportedAt` timestamp, so no two exports hash the same and a
        # digest from a rebuild would never match what a user downloads.
        self.assertEqual(len(bundle.sha256), 64)
        self.assertEqual(bundle.sha256, bundle.sha256.lower())
        self.assertTrue(bundle.url.endswith('.zip'))
        self.assertIn('releases/download/', bundle.url)
        self.assertGreater(bundle.size, 0)

    # -- Options -----------------------------------------------------------

    def testTheSeedIsTheOnlyKnobAndTheOthersAreRefusedByName(self):
        from pymol.predictors.errors import PredictionOptionError
        generator = self.generator()
        self.assertEqual(set(generator.option_defaults), {'seed'})
        # Declared-and-ignored is the option this deliberately does not take: the released
        # schedule is 60 flow steps with the recycle bands indexed against them, so a
        # different count would be a misaligned run rather than a longer one. A user who
        # asks for one is told, instead of watching it change nothing.
        for name in ('diffusion_steps', 'recycling_steps', 'msa_depth'):
            self.assertRaises(PredictionOptionError,
                              generator.validate_options, {name: 4})
        self.assertEqual(generator.validate_options({'seed': 11}).seed, 11)

    def testTheWireCarriesTheStepCountTheRunActuallyPerforms(self):
        from pymol.generators import rfd4
        request = self.submitted()
        # Both fields exist only because `InferenceJob.Request` decodes them as
        # non-optional Ints. `diffusion_steps` is the real count so a reader of the raw
        # request is not misled; `recycling_steps` is 1 precisely so nobody reads it as a
        # setting, since this model's recycling is a per-band schedule with no scalar form.
        self.assertEqual(request['diffusion_steps'], rfd4.RELEASED_FLOW_STEPS)
        self.assertEqual(request['diffusion_steps'], 60)
        self.assertEqual(request['recycling_steps'], 1)

    def testNoLiveViewKeyIsSentAtAll(self):
        # This engine's step hook reports (step, trunk passes) and no coordinates, so there
        # is nothing to stream. Absent rather than present-and-false: absent is what every
        # request that cannot be watched says, and the runtime's default is off.
        self.assertNotIn('live_view', self.submitted())
        self.assertNotIn('live_interval', self.submitted())

    # -- Metrics -----------------------------------------------------------

    def testItDeclaresARebuildRMSDRatherThanRFD3sDrift(self):
        from pymol.generators import registry
        keys = set(spec.key for spec in self.generator().metric_specs)
        rfd3_keys = set(spec.key for spec in registry.get('rfd3').metric_specs)
        # THE KEY THAT MUST NOT BE SHARED. rfd3's `target_drift_max` declares lo=0 and is
        # documented as "0.000 A on a correct run, a bug on any other", because there the
        # target is held fixed. This model GENERATES its target, so a correct run reads
        # non-zero -- recording it under that key would brand every correct design a
        # defect, in a field whose own description says it should be zero.
        self.assertIn('target_rebuild_rmsd', keys)
        self.assertNotIn('target_drift_max', keys)
        self.assertIn('target_drift_max', rfd3_keys)
        self.assertNotIn('target_rebuild_rmsd', rfd3_keys)
        # Everything else is shared, so the two methods' designs compare in one panel.
        self.assertEqual(keys - {'target_rebuild_rmsd'},
                         rfd3_keys - {'target_drift_max'})

    def testNoMetricKeyCallsTheOutputABinder(self):
        # The naming split from `generators/base`: the TOOL may be called Binder Design,
        # the OUTPUT may not be called a binder until a refold and an interface gate say
        # so. The port's own API says `binder`; this is where that stops.
        for spec in self.generator().metric_specs:
            self.assertNotIn('binder', spec.key.lower())
            self.assertNotIn('binder', (spec.label or '').lower())

    # -- Refusals the engine would not make --------------------------------

    def testAnEmptyTargetIsRefused(self):
        from pymol.generators.base import TargetStructure
        from pymol.predictors.errors import PredictionInputError
        self.assertRaises(PredictionInputError, self.generator().parse_target,
                          TargetStructure([], []), 30)

    def testATwoChainTargetIsRefusedWithARemedy(self):
        from pymol.generators.base import TargetStructure
        from pymol.predictors.errors import PredictionInputError
        structure = self.target()
        residues = list(structure.residues)
        residues[-1].chain = 'B'
        try:
            self.generator().parse_target(TargetStructure(residues, []), 30)
        except PredictionInputError as exc:
            self.assertIn('chain', str(exc))
        else:
            self.fail('a two-chain target must be refused')

    def testALengthOutsideTheMeasuredRangeIsRefused(self):
        from pymol.generators import rfd4
        from pymol.predictors.errors import PredictionInputError
        structure = self.target()
        for length in (0, -1, rfd4.MAX_DESIGN_LENGTH + 1):
            self.assertRaises(PredictionInputError,
                              self.generator().parse_target, structure, length)
        # And the shape that is fine.
        self.generator().parse_target(structure, rfd4.MAX_DESIGN_LENGTH)

    def testTooManyTokensIsRefusedInTokensRatherThanAtoms(self):
        from pymol.generators import rfd4
        from pymol.predictors.errors import PredictionInputError
        # One residue is one token here, target or designed -- unlike rfd3, which is sized
        # in atoms. A 690-residue target plus a 30-residue design is 720 tokens.
        structure = self.target(length=rfd4.MAX_TOKENS - 10)
        try:
            self.generator().parse_target(structure, 30)
        except PredictionInputError as exc:
            self.assertIn('token', str(exc))
        else:
            self.fail('%d tokens must be refused' % (rfd4.MAX_TOKENS + 20))

    def testAHotspotOutsideTheTargetIsRefusedByIndex(self):
        from pymol.generators.base import TargetStructure
        from pymol.predictors.errors import PredictionInputError
        structure = self.target()
        bad = TargetStructure(structure.residues, [999])
        self.assertRaises(PredictionInputError,
                          self.generator().parse_target, bad, 30)

    def testNoHotspotsAtAllIsAcceptedAsUnguidedPlacement(self):
        from pymol.generators.base import TargetStructure
        # Unguided placement is a mode the featurizer supports directly. A floor that
        # refused it would be OURS rather than the engine's.
        structure = self.target()
        spec = self.generator().parse_target(
            TargetStructure(structure.residues, []), 30)
        self.assertEqual(spec.target.hotspots, ())

    def testAnIdentifierThePDBCannotHoldIsRefusedBeforeTheDownload(self):
        from pymol.generators.base import TargetStructure
        from pymol.predictors.errors import PredictionInputError
        # The result crosses back as PDB TEXT, whose writer keeps the SUFFIX of anything
        # too long -- so chain 'AA' would return as 'A' and residue 10000 as '0000', in an
        # object the user is told holds their target exactly as it was.
        structure = self.target()
        for attribute, value in (('chain', 'AA'), ('resi', '10000')):
            residues = list(structure.residues)
            setattr(residues[0], attribute, value)
            self.assertRaises(PredictionInputError, self.generator().parse_target,
                              TargetStructure(residues, []), 30)

    # -- The gap rule ------------------------------------------------------

    def testAGapInTheBackboneIsCountedAsASeparateSegment(self):
        from pymol.generators import rfd4
        # The engine splits the target wherever the backbone is not bonded, decided from
        # the C(i)-N(i+1) distance rather than from residue numbering, and gives each
        # stretch its own contig chain id. A contiguous helix is one segment.
        structure = self.target(length=10)
        residues = list(structure.residues)
        self.assertEqual(rfd4._count_backbone_segments(residues), 1)
        # Move the second half far away: now there is no peptide bond across the join.
        for residue in residues[5:]:
            residue.atoms = [(name, (x + 500.0, y, z))
                             for name, (x, y, z) in residue.atoms]
        self.assertEqual(rfd4._count_backbone_segments(residues), 2)

    def testAMissingBackboneAtomReadsAsABreakRatherThanABond(self):
        from pymol.generators import rfd4
        # A residue whose backbone is incomplete is in no position to vouch for a peptide
        # bond. Assuming one would be the silent-wrong-answer this rule exists to prevent.
        structure = self.target(length=6)
        residues = list(structure.residues)
        residues[2].atoms = [(name, xyz) for name, xyz in residues[2].atoms
                             if name != 'C']
        self.assertEqual(rfd4._count_backbone_segments(residues), 2)

    def testAnImpossiblyFragmentedTargetIsRefusedByItsOwnMessage(self):
        from pymol.generators import rfd4
        from pymol.generators.base import TargetStructure
        from pymol.predictors.errors import PredictionInputError
        structure = self.target(length=rfd4.MAX_TARGET_SEGMENTS + 3)
        residues = list(structure.residues)
        # Scatter every residue, so each becomes its own segment and the contig runs out
        # of chain ids. Refused BY NAME here, so the message is about the selection rather
        # than about letters.
        for index, residue in enumerate(residues):
            residue.atoms = [(name, (x + 500.0 * index, y, z))
                             for name, (x, y, z) in residue.atoms]
        try:
            self.generator().parse_target(TargetStructure(residues, []), 30)
        except PredictionInputError as exc:
            self.assertIn('stretch', str(exc))
        else:
            self.fail('a fully fragmented target must be refused')

    # -- The design chain --------------------------------------------------

    def testTheDesignGetsAChainTheTargetDoesNotUse(self):
        # A design sharing the target's chain id would merge with it on load, and nothing
        # afterwards could tell them apart.
        self.assertEqual(self.generator().parse_target(
            self.target(chain='A'), 30).design_chain, 'B')
        self.assertNotEqual(self.generator().parse_target(
            self.target(name='u', chain='B'), 30).design_chain, 'B')

    # -- The design key ----------------------------------------------------

    def testTheDesignKeyMovesWithEverythingThatChangesTheCoordinates(self):
        generator = self.generator()
        structure = self.target()
        spec = generator.parse_target(structure, 30, name='obj')
        base = spec.design_key(generator.validate_options({'seed': 0}))
        self.assertEqual(base, spec.design_key(generator.validate_options({'seed': 0})))
        # The seed is the one knob, so it must key differently.
        self.assertNotEqual(base,
                            spec.design_key(generator.validate_options({'seed': 1})))
        # So must the weight pack: the same target at the same seed against different
        # weights is a different design.
        self.assertNotEqual(base, spec.design_key(generator.validate_options({'seed': 0}),
                                                  weights_version='other v2'))
        # And so must the length.
        other = generator.parse_target(structure, 31, name='obj')
        self.assertNotEqual(base,
                            other.design_key(generator.validate_options({'seed': 0})))
