"""The runtime seam and the shipped rfd3 generator's own declarations.

    pymol -ckqy testing/testing.py --run testing/tests/generate/generate_runtime.py

A request names the backend that must run it, and the mismatch is refused TWICE -- once in
check_available before any download, once in the Swift preflight. Tested here rather than
only through one generator, because the mechanism is shared and because its
back-compatibility properties are exactly the kind of thing that rots silently.
"""
import json
import os
import sys

from pymol import cmd

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

from generate_harness import GeneratorTestCase, install_stub, make_zip  # noqa: E402


class RuntimeSeamTest(GeneratorTestCase):

    def setUp(self):
        GeneratorTestCase.setUp(self)
        self.declareHost('boltz,protenix,rfd3')

    def submitted(self, generator_id, length=20, live_view=False):
        """The request dict a generator actually writes, read back off disk."""
        import io
        from contextlib import redirect_stdout
        from pymol import designing
        from pymol.generators import registry
        self.helix('t', length=12, chain='A', first=1)
        structure = designing.resolve_target('t', 't and resi 4+6')
        generator = registry.get(generator_id)
        spec = generator.parse_target(structure, length, name='obj')
        spec.live_view = live_view
        options = generator.validate_options({})
        with redirect_stdout(io.StringIO()):
            job = generator.submit(spec, options, weights_path='/nonexistent')
        with open(job.request_path) as handle:
            request = json.load(handle)
        os.remove(job.request_path)
        return request

    # -- Every generator names a runtime ------------------------------------

    def testEveryRegisteredGeneratorNamesARuntime(self):
        """A request with no runtime is read as BOLTZ at the far end, deliberately.

        That default is what keeps an older Python side working, and it is also the trap: a
        generator that forgets to pass one is silently dispatched to Boltz's featurizer --
        which for a generator means folding an EMPTY chain list. So every registered
        generator is checked, not just the one that exists today.
        """
        from pymol.generators import registry
        for gid in registry.available():
            self.assertIn('runtime', self.submitted(gid), gid)
            self.assertTrue(self.submitted(gid)['runtime'], gid)

    def testTheRuntimeIsNotBoltz(self):
        # Sharper than the check above: a generator whose runtime were literally 'boltz'
        # would pass "names a runtime" and still be dispatched to a sequence featurizer.
        from pymol.generators import registry
        from pymol.predictors import host
        for gid in registry.available():
            self.assertNotEqual(self.submitted(gid)['runtime'], host.DEFAULT_RUNTIME, gid)

    def testTheRequestCarriesTheStructureAndNoSequences(self):
        request = self.submitted('rfd3', length=25)
        # A generator has no sequence input, and `chains` being empty is the honest answer
        # rather than an oversight -- it is why the structural fields had to exist.
        self.assertEqual(request['chains'], [])
        self.assertEqual(request['design_length'], 25)
        self.assertEqual(len(request['target']), 12)
        self.assertEqual(request['target'][0]['resi'], '1')
        self.assertEqual(request['target'][0]['resn'], 'ALA')
        self.assertEqual(request['target'][0]['chain'], 'A')
        self.assertEqual(len(request['target'][0]['atoms'][0]['xyz']), 3)
        self.assertEqual(request['hotspots'], [3, 5])
        self.assertEqual(request['design_chain'], 'B')
        self.assertEqual(len(request['design_key']), 16)

    def testOnlyDeclaredKnobsReachTheWire(self):
        # `msa_depth` must be ABSENT: on the wire it would read as a depth the method
        # honours, and the run would be recorded as having used an alignment it never saw.
        # A generator has no alignment at all.
        request = self.submitted('rfd3')
        self.assertIn('diffusion_steps', request)
        self.assertIn('recycling_steps', request)
        self.assertIn('seed', request)
        self.assertNotIn('msa_depth', request)
        # `alignments` IS written -- as an empty list. The transport always writes the key,
        # and empty is the honest value: a generator has nothing to align, so there is no
        # chain for the far end to fall back to a dummy alignment for. Asserted as empty
        # rather than absent so a non-empty one here would be caught.
        self.assertEqual(request['alignments'], [])

    def testTheHostTransportIsSharedNotForked(self):
        # The marker and the temp-file convention are the PREDICTION transport, reused
        # verbatim: the marker means "a request is on disk", and the request names its
        # runtime. Pinned because forking it would double the number of places a status
        # path convention has to stay in step with InferenceJob.statusURL.
        from pymol.predictors import host
        request = self.submitted('rfd3')
        self.assertTrue(request['status_path'].endswith('.json'))
        self.assertIn('raymol_predict_status_', request['status_path'])
        self.assertEqual(host.HOST_ENV, 'RAYMOL_PREDICT_HOST')
        self.assertEqual(host.RUNTIMES_ENV, 'RAYMOL_PREDICT_RUNTIMES')

    def testAMethodMayNotOverrideARequestKeyItDoesNotOwn(self):
        # `extra` is method-specific INPUT, not a way to redirect a job. Silently replacing
        # `out_path` or `runtime` would produce a job reporting to the wrong file or running
        # on the wrong backend -- neither of which fails.
        from pymol.predictors import host
        from pymol.predictors.errors import PredictionError
        from pymol.generators.base import DesignOptions, DesignSpec, TargetStructure
        spec = DesignSpec(TargetStructure((), (), source='x'), 1, name='n')
        options = DesignOptions()
        for key in ('out_path', 'runtime', 'seed', 'job_id'):
            self.assertRaises(PredictionError, host.submit, spec, options, '',
                              runtime='rfd3', knobs=('seed',), extra={key: 'hijacked'})

    def testAPredictorsRequestIsUnchangedByTheGeneratorAddition(self):
        # The acceptance rule for this whole feature: nothing in the prediction path may
        # behave differently. `extra` defaults to None, so a predictor's request is exactly
        # the keys it always had.
        import io
        from contextlib import redirect_stdout
        from pymol.predictors import registry as pregistry
        predictor = pregistry.get('boltz2')
        spec = predictor.parse_spec('MKTAY', name='p')
        options = predictor.validate_options({})
        with redirect_stdout(io.StringIO()):
            job = predictor.submit(spec, options, '/nonexistent')
        with open(job.request_path) as handle:
            request = json.load(handle)
        os.remove(job.request_path)
        for key in ('target', 'hotspots', 'design_length', 'design_chain', 'design_key'):
            self.assertNotIn(key, request, 'a prediction request must not grow %r' % key)
        self.assertEqual(request['runtime'], 'boltz')
        self.assertEqual(request['chains'], [{'chain': 'A', 'sequence': 'MKTAY'}])

    # -- Availability -------------------------------------------------------

    def testAMissingRuntimeIsRefusedBeforeAnyDownload(self):
        from pymol.predictors.errors import PredictorUnavailable
        from pymol.generators import registry
        self.declareHost('boltz')
        generator = registry.get('rfd3')
        with self.assertRaises(PredictorUnavailable) as caught:
            generator.check_available()
        # The refusal must NAME the missing runtime and say what the build does carry, or
        # the user cannot tell "wrong build" from "wrong command".
        self.assertIn('rfd3', str(caught.exception))
        self.assertIn('boltz', str(caught.exception))

    def testNoHostAtAllIsADifferentRefusal(self):
        # Two failures, two remedies: "you are running headless" versus "this build does
        # not carry that backend". Collapsing them would tell a headless user to go find a
        # different build.
        from pymol.predictors.errors import PredictorUnavailable
        from pymol.generators import registry
        os.environ.pop('RAYMOL_PREDICT_HOST', None)
        with self.assertRaises(PredictorUnavailable) as caught:
            registry.get('rfd3').check_available()
        self.assertIn('host', str(caught.exception))

    # -- The registries stay separate ---------------------------------------

    def testAGeneratorIsNotOfferedWhereAPredictorIsExpected(self):
        # `predict rfd3, MKTAY` must not resolve. A generator reachable from the predictor
        # registry would be handed a sequence and asked for a PredictionSpec, and the only
        # honest implementation of that raises -- so the shared table's contract would
        # become "every entry folds a sequence, except the ones that do not".
        from pymol.predictors import registry as pregistry
        from pymol.predictors.errors import PredictorNotFound
        self.assertNotIn('rfd3', pregistry.available())
        self.assertRaises(PredictorNotFound, pregistry.get, 'rfd3')

    def testAPredictorIsNotOfferedWhereAGeneratorIsExpected(self):
        from pymol.generators import registry
        from pymol.predictors.errors import PredictorNotFound
        self.assertNotIn('boltz2', registry.available())
        self.assertRaises(PredictorNotFound, registry.get, 'boltz2')

    def testNoGeneratorIdIsAPrefixOfAnother(self):
        # The Tab-completion invariant: `design_backbone rf<Tab>` must never stop at a dead
        # end. The prediction registry learned this the hard way with boltz2/boltz2-bf16.
        from pymol.generators import registry
        ids = registry.available()
        for one in ids:
            for other in ids:
                if one != other:
                    self.assertFalse(other.startswith(one),
                                     '%r is a prefix of %r' % (one, other))

    def testEveryGeneratorDeclaresItsMetrics(self):
        from pymol.generators import registry
        from pymol.metrics import schema
        for gid in registry.available():
            generator = registry.get(gid)
            self.assertTrue(generator.metric_specs, gid)
            declared = {spec.key for spec in schema.specs(gid)}
            self.assertEqual(declared, {spec.key for spec in generator.metric_specs}, gid)

    def testAGeometryOnlyGeneratorDeclaresNoConfidenceKeys(self):
        # A generator has no confidence head: the sampler emits coordinates and a sequence
        # and nothing predicts how right they are. A caller that found `plddt` here would be
        # entitled to conclude the tool can produce it.
        from pymol.generators import registry
        for gid in registry.available():
            keys = {spec.key for spec in registry.get(gid).metric_specs}
            for forbidden in ('plddt', 'mean_plddt', 'pae', 'mean_pae', 'min_ipsae',
                              'ipsae', 'ipae', 'msa_depth'):
                self.assertNotIn(forbidden, keys, '%s must not declare %r' % (gid, forbidden))

    def testEveryKnobAGeneratorDeclaresIsANamedCommandParameter(self):
        # A knob a generator declares but the command cannot pass raises TypeError before
        # validate_options ever runs, so the taxonomy's error never reaches the user.
        import inspect
        from pymol.generators import registry
        parameters = set(inspect.signature(cmd.design_backbone).parameters)
        for gid in registry.available():
            for knob in registry.get(gid).option_defaults:
                self.assertIn(knob, parameters, '%s declares %r' % (gid, knob))

    def testLiveViewRidesTheWireOnlyWhenAskedFor(self):
        # A presentation flag, not a sampler knob: it changes nothing about the design,
        # so it is a named command parameter like `name` and `n_designs` rather than an
        # entry in option_defaults, and it must be ABSENT-or-false by default so an
        # ordinary run is byte-for-byte what it was.
        request = self.submitted('rfd3')
        self.assertFalse(request.get('live_view', False))

    def testLiveViewIsOnTheWireWhenRequested(self):
        request = self.submitted('rfd3', live_view=True)
        self.assertIs(request['live_view'], True)


class RFD3PackTest(GeneratorTestCase):
    """The shipped pack's declaration. Every field here fails only on a user's machine,
    after the download, if it is wrong."""

    def setUp(self):
        GeneratorTestCase.setUp(self)
        from pymol.generators import registry
        self.generator = registry.get('rfd3')
        self.bundle = self.generator.weight_bundle

    def testTheDigestIsARealSHA256(self):
        self.assertEqual(len(self.bundle.sha256), 64)
        self.assertEqual(self.bundle.sha256, self.bundle.sha256.lower())
        int(self.bundle.sha256, 16)          # raises if it is not hex
        self.assertNotEqual(set(self.bundle.sha256), {'0'}, 'placeholder digest')

    def testTheSizeIsPlausibleForAnFP32Pack(self):
        # 672 MB of fp32 weights compresses to ~625 MB. A size that drifted an order of
        # magnitude means the URL points at something else entirely.
        self.assertGreater(self.bundle.size, 300_000_000)
        self.assertLess(self.bundle.size, 2_000_000_000)

    def testTheMembersAreThePacksOwnLayout(self):
        # RFD3Kit reads `manifest.json` (format 2, required weight provenance) and
        # `rfd3_core.safetensors` from the directory it is handed. WeightCache asserts this
        # set after extraction, because a partially-extracted pack fails on a sha256 INSIDE
        # the pack rather than on the missing file -- a much worse error to read.
        self.assertEqual(self.bundle.members,
                         ('manifest.json', 'rfd3_core.safetensors'))

    def testTheURLIsAPinnedReleaseAsset(self):
        self.assertTrue(self.bundle.url.startswith('https://'), self.bundle.url)
        self.assertIn('/releases/download/', self.bundle.url)
        self.assertTrue(self.bundle.url.endswith('.zip'), self.bundle.url)

    def testTheOperatingPointIsUpstreamsProductionSchedule(self):
        self.assertEqual(self.generator.option_defaults,
                         {'recycling_steps': 2, 'diffusion_steps': 200, 'seed': 0})

    def testTheProgressBandsCoverTheWholeBarInOrder(self):
        # A generator that declares none gets a spinner, which is the correct rendering of
        # no information -- and a missed opportunity when a per-step count exists.
        phases = self.generator.progress_phases
        self.assertTrue(phases)
        self.assertEqual(phases[0][1], 0.0)
        self.assertEqual(phases[-1][2], 1.0)
        previous = 0.0
        for name, start, end in phases:
            self.assertLessEqual(start, end, name)
            self.assertGreaterEqual(start, previous - 1e-9, name)
            previous = start
        # And 'diffusion' owns most of it, because it genuinely does: 200 steps x 2
        # recycles of an 18-block transformer against a one-off featurization.
        widths = {name: end - start for name, start, end in phases}
        self.assertGreater(widths['diffusion'], 0.5)

    def testTheSizeCeilingsAreStatedAndOrdered(self):
        from pymol.generators import rfd3
        self.assertGreater(rfd3.MAX_TOKENS, rfd3.MAX_DESIGN_LENGTH)
        self.assertGreaterEqual(rfd3.MAX_DESIGNS, 1)
        # No MIN_HOTSPOTS any more, and the absence is asserted rather than merely
        # deleted: unguided placement is a mode the engine has, so a floor reappearing
        # here would silently take it away again.
        self.assertFalse(hasattr(rfd3, 'MIN_HOTSPOTS'))

    def testTheLengthCeilingRefusalExplainsItself(self):
        from pymol import designing
        from pymol.generators import rfd3
        from pymol.predictors.errors import PredictionInputError
        self.helix('t', length=12)
        structure = designing.resolve_target('t', 't and resi 5')
        with self.assertRaises(PredictionInputError) as caught:
            self.generator.parse_target(structure, rfd3.MAX_DESIGN_LENGTH + 1)
        message = str(caught.exception)
        self.assertIn(str(rfd3.MAX_DESIGN_LENGTH), message)
        # Says WHY length is the axis that runs out first, and that the exact wall is the
        # runtime's -- otherwise this reads as an arbitrary cap.
        self.assertIn('14 atom', message)
        self.assertIn('runtime', message)

    def testTheTokenCeilingRefusalSaysItIsAboutTime(self):
        # Built without a session: 690 residues through `cmd.fab` is slow, and the ceiling
        # is a property of the residue COUNT rather than of any particular structure.
        from pymol.generators import rfd3
        from pymol.generators.base import TargetResidue, TargetStructure
        from pymol.predictors.errors import PredictionInputError
        residues = [TargetResidue('A', str(i + 1), 'ALA',
                                  [('N', (0.0, 0.0, 0.0)), ('CA', (1.5, 0.0, 0.0))])
                    for i in range(rfd3.MAX_TOKENS)]
        structure = TargetStructure(residues, (0,), source='synthetic')
        with self.assertRaises(PredictionInputError) as caught:
            self.generator.parse_target(structure, 60)
        message = str(caught.exception)
        self.assertIn(str(rfd3.MAX_TOKENS), message)
        # WHICH KIND of limit it is, because "too large" reads as a memory wall when this
        # one is about how long one design is worth waiting for.
        self.assertIn('TIME', message)
        self.assertIn('target', message)

    def testATargetThatFitsIsNotRefused(self):
        # The other half, so the ceiling tests are size decisions rather than
        # "parse_target always raises".
        from pymol.generators import rfd3
        from pymol.generators.base import TargetResidue, TargetStructure
        residues = [TargetResidue('A', str(i + 1), 'ALA',
                                  [('N', (0.0, 0.0, 0.0)), ('CA', (1.5, 0.0, 0.0))])
                    for i in range(rfd3.MAX_TOKENS - 60)]
        structure = TargetStructure(residues, (0, 1), source='synthetic')
        spec = self.generator.parse_target(structure, 60, name='big')
        self.assertEqual(spec.total_residues, rfd3.MAX_TOKENS)
