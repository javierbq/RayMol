"""What a finished prediction leaves behind on its object (#308).

The adapter, without a host: a stand-in job carries the spec, options and status a real
one would, and the metrics document is written by hand exactly as BoltzJobManager
writes it. What is under test is the seam -- that provenance, cost and the host's
confidence numbers all land on the object the model was loaded into, at the right
scopes and on the right state.

    pymol -ckqy testing/testing.py --run testing/tests/metrics/metrics_predict.py
"""
import json
import os
import tempfile

from pymol import cmd, predicting, testing
from pymol.metrics import store
from pymol.predictors.base import PredictionSpec, parse_chains

SEQUENCE = 'ACDEF'


class FakeMSA:
    """Whatever has `name`, `query` and `depth` will do -- predictors.base says so."""

    def __init__(self, name, depth):
        self.name = name
        self.depth = depth
        self.query = SEQUENCE


class FakeJob:
    """A job handle with the surface record_run() reads: spec, options, status, paths."""

    def __init__(self, spec, options, metrics_path, status=None):
        self.job_id = 'fake-job'
        self.spec = spec
        self.options = options
        self.predictor_id = 'boltz2'
        self.metrics_path = metrics_path
        self._status = status if status is not None else {
            'state': 'done', 'phase': 'done', 'fraction': 1.0, 'error': None,
            'result_path': None, 'peak_bytes': 620_000_000, 'elapsed_s': 14.5}

    def status(self):
        return self._status


class PredictMetricTestCase(testing.PyMOLTestCase):

    def setUp(self):
        testing.PyMOLTestCase.setUp(self)
        from pymol.predictors import registry
        registry.get('boltz2')      # ensure the shipped schema is declared
        self._jobs = dict(predicting._JOBS)
        self._pending = dict(predicting._PENDING)

    def tearDown(self):
        store.clear()
        predicting._JOBS.clear()
        predicting._JOBS.update(self._jobs)
        predicting._PENDING.clear()
        predicting._PENDING.update(self._pending)
        testing.PyMOLTestCase.tearDown(self)

    def tmpfile(self, suffix):
        handle, path = tempfile.mkstemp(suffix=suffix)
        os.close(handle)
        self.addCleanup(lambda: os.path.exists(path) and os.unlink(path))
        return path

    def structure(self):
        """A PDB the host might have written: one chain, residues 1..5."""
        path = self.tmpfile('.pdb')
        cmd.fab(SEQUENCE, 'source_for_pdb', chain='A')
        cmd.save(path, 'source_for_pdb')
        cmd.delete('source_for_pdb')
        return path

    def spec(self, alignments=None, name='pred'):
        spec = PredictionSpec(parse_chains(SEQUENCE), name, alignments)
        return spec

    def options(self, **kwargs):
        from pymol.predictors.base import PredictionOptions
        settings = dict(recycling_steps=3, diffusion_steps=200, seed=99,
                        msa_depth=1000)
        settings.update(kwargs)
        return PredictionOptions(**settings)

    def document(self, path, residues=5, with_interface=True):
        """A metrics document in the shape BoltzJobManager.writeMetrics writes."""
        index = [['A', str(i + 1)] for i in range(residues)]
        values = [
            {'key': 'plddt', 'state': 0, 'index': index,
             'values': [80.0 + i for i in range(residues)]},
            {'key': 'mean_plddt', 'state': 0, 'value': 82.0},
            {'key': 'pae', 'state': 0, 'index': index,
             'values': [1.0] * (residues * residues)},
        ]
        if with_interface:
            values.append({'key': 'min_ipsae', 'state': 0, 'value': 0.71})
            values.append({'key': 'ipae', 'state': 0, 'value': 4.2})
        with open(path, 'w') as handle:
            json.dump({'tool': 'boltz2', 'object': 'pred', 'values': values}, handle)
        return path

    def deliver(self, job, name='pred', seed=99):
        """Stand in for the host: register the pending job, then land the model."""
        predicting._JOBS[job.job_id] = job
        predicting.register_pending(name, job.job_id)
        predicting.deliver_result(self.structure(), name, seed=seed)
        return store.runs(object=name)[-1]


class RecordedRunTest(PredictMetricTestCase):

    def testProvenanceAndCostAreRecorded(self):
        job = FakeJob(self.spec(), self.options(), self.tmpfile('.json'))
        run = self.deliver(job)
        self.assertEqual(run.tool, 'boltz2')
        self.assertEqual(run.object, 'pred')
        self.assertEqual(run.inputs['seed'], 99)
        self.assertEqual(run.inputs['options']['diffusion_steps'], 200)
        self.assertEqual(run.inputs['chains'], [{'chain': 'A', 'length': 5}])
        self.assertEqual(run.scalars()['elapsed_s'], 14.5)
        self.assertEqual(run.scalars()['peak_bytes'], 620_000_000)

    def testWeightPackIsRecorded(self):
        # The likeliest difference between two runs that otherwise look identical:
        # boltz2 and boltz2-bf16 are one model at two precisions (#293).
        job = FakeJob(self.spec(), self.options(), self.tmpfile('.json'))
        self.assertIn('boltz2-mlx-int8', self.deliver(job).tool_version)

    def testSequenceFactsAreObjectScopeNotPerState(self):
        job = FakeJob(self.spec(), self.options(), self.tmpfile('.json'))
        run = self.deliver(job)
        residues = run.one('n_residues')
        self.assertEqual(residues.value, 5)
        self.assertIsNone(residues.state)

    def testAlignmentDepthIsPerChainAndIsTheDepthActuallyREAD(self):
        # A designed binder has an alignment for the target and none for itself, and a
        # run capped at msa_depth read fewer rows than the alignment holds.
        job = FakeJob(self.spec(alignments={'A': FakeMSA('aln', 6628)}),
                      self.options(msa_depth=1000), self.tmpfile('.json'))
        run = self.deliver(job)
        depth = run.one('msa_depth', chain='A')
        self.assertEqual(depth.value, 1000)
        self.assertEqual(depth.chain, 'A')
        self.assertEqual(run.inputs['alignments'], {'A': 'aln'})

    def testNoAlignmentMeansNoDepthRatherThanZero(self):
        job = FakeJob(self.spec(), self.options(), self.tmpfile('.json'))
        run = self.deliver(job)
        self.assertEqual(run.find('msa_depth'), [])


class HostDocumentTest(PredictMetricTestCase):

    def testConfidenceNumbersFromTheHostAreRecorded(self):
        path = self.tmpfile('.json')
        job = FakeJob(self.spec(), self.options(), self.document(path))
        run = self.deliver(job)
        self.assertEqual(run.one('mean_plddt', state=1).value, 82.0)
        # PAE used to be computed on every run and dropped on the floor.
        self.assertEqual(len(run.one('pae', state=1).values), 25)
        self.assertEqual(run.one('min_ipsae', state=1).value, 0.71)
        plddt = run.one('plddt', state=1)
        self.assertEqual([tuple(p) for p in plddt.index],
                         [('A', str(i + 1)) for i in range(5)])

    def testTheStateIsTheOneTheModelLandedIn(self):
        # The host cannot know how many models preceded it in the object, so the state
        # is stamped on this side. With n_models that is the whole difference between
        # model 1's confidence and model 2's.
        path = self.tmpfile('.json')
        job = FakeJob(self.spec(), self.options(), self.document(path))
        self.deliver(job)
        second = FakeJob(self.spec(), self.options(), self.document(self.tmpfile('.json')))
        second.job_id = 'fake-job-2'
        run = self.deliver(second)
        self.assertEqual(cmd.count_states('pred'), 2)
        self.assertEqual(run.one('mean_plddt').state, 2)
        self.assertEqual(run.one('plddt').state, 2)

    def testAMissingDocumentStillRecordsTheRun(self):
        # A host that predates the metrics document, or a runtime with no confidence
        # module: the run still carries what it cost and what it was over.
        job = FakeJob(self.spec(), self.options(), self.tmpfile('.json'))
        os.unlink(job.metrics_path)
        run = self.deliver(job)
        self.assertEqual(run.find('plddt'), [])
        self.assertEqual(run.scalars()['elapsed_s'], 14.5)

    def testAMalformedDocumentDoesNotCostTheRunItsOtherNumbers(self):
        job = FakeJob(self.spec(), self.options(), self.tmpfile('.json'))
        with open(job.metrics_path, 'w') as handle:
            handle.write('{not json')
        run = self.deliver(job)
        self.assertEqual(run.scalars()['elapsed_s'], 14.5)

    def testASingleChainCarriesNoInterfaceScore(self):
        # Absent, not zero -- zero reads as a terrible interface rather than none.
        path = self.tmpfile('.json')
        job = FakeJob(self.spec(), self.options(),
                      self.document(path, with_interface=False))
        run = self.deliver(job)
        self.assertEqual(run.find('min_ipsae'), [])

    def testTheStructureStillLoadsWhenMetricsCannotBeRecorded(self):
        # A prediction that folded must not fail to appear because its numbers could
        # not be filed.
        job = FakeJob(self.spec(), self.options(), self.tmpfile('.json'))
        job.predictor_id = 'no-such-predictor'
        predicting._JOBS[job.job_id] = job
        predicting.register_pending('pred', job.job_id)
        predicting.deliver_result(self.structure(), 'pred', seed=1)
        self.assertEqual(cmd.count_atoms('pred and name CA'), 5)
        self.assertEqual(store.runs(object='pred'), [])
