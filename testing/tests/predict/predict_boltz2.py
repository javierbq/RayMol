"""boltz2 predictor and the Swift-host transport. No Swift required: the host is
simulated by writing the status file the Swift side would write.

    pymol -ckqy testing/testing.py --run testing/tests/predict/predict_boltz2.py
"""
import json
import os

from pymol import testing


class TestAvailability(testing.PyMOLTestCase):

    def setUp(self):
        testing.PyMOLTestCase.setUp(self)
        self._saved = os.environ.get('RAYMOL_PREDICT_HOST')

    def tearDown(self):
        if self._saved is None:
            os.environ.pop('RAYMOL_PREDICT_HOST', None)
        else:
            os.environ['RAYMOL_PREDICT_HOST'] = self._saved
        testing.PyMOLTestCase.tearDown(self)

    def testUnavailableWithoutAHost(self):
        from pymol.predictors.boltz2 import Boltz2Predictor
        from pymol.predictors.errors import PredictorUnavailable
        os.environ.pop('RAYMOL_PREDICT_HOST', None)
        self.assertRaises(PredictorUnavailable,
                          Boltz2Predictor().check_available)

    def testAvailableWithAHost(self):
        from pymol.predictors.boltz2 import Boltz2Predictor
        os.environ['RAYMOL_PREDICT_HOST'] = '1'
        self.assertIsNone(Boltz2Predictor().check_available())


class TestSpecValidation(testing.PyMOLTestCase):

    def predictor(self):
        from pymol.predictors.boltz2 import Boltz2Predictor
        return Boltz2Predictor()

    def testCanonicalSequenceAccepted(self):
        spec = self.predictor().parse_spec('MKTAY')
        self.assertEqual(spec.chains, (('A', 'MKTAY'),))

    def testNonCanonicalLettersRejected(self):
        from pymol.predictors.errors import PredictionInputError
        for bad in ('MKTX', 'MKTU', 'MKTB', 'MKTZ', 'MKT1'):
            self.assertRaises(PredictionInputError,
                              self.predictor().parse_spec, bad)

    def testTooLongRejected(self):
        from pymol.predictors.errors import PredictionInputError
        from pymol.predictors.boltz2 import MAX_RESIDUES
        self.assertRaises(PredictionInputError, self.predictor().parse_spec,
                          'A' * (MAX_RESIDUES + 1))

    def testDiffusionSamplesRejectedByName(self):
        from pymol.predictors.errors import PredictionOptionError
        try:
            self.predictor().validate_options({'diffusion_samples': 4})
        except PredictionOptionError as exc:
            self.assertIn('diffusion_samples', str(exc))
        else:
            self.fail('expected PredictionOptionError')

    def testDefaultsAreUpstreamBoltz(self):
        options = self.predictor().validate_options({})
        self.assertEqual(options.recycling_steps, 3)
        self.assertEqual(options.diffusion_steps, 200)


class TestHostTransport(testing.PyMOLTestCase):

    def setUp(self):
        testing.PyMOLTestCase.setUp(self)
        os.environ['RAYMOL_PREDICT_HOST'] = '1'

    def tearDown(self):
        os.environ.pop('RAYMOL_PREDICT_HOST', None)
        testing.PyMOLTestCase.tearDown(self)

    def testSubmitWritesARequestAndPrintsAMarker(self):
        import io
        from contextlib import redirect_stdout
        from pymol.predictors import host
        from pymol.predictors.base import PredictionOptions, PredictionSpec

        spec = PredictionSpec((('A', 'AG'),), 'pred')
        buf = io.StringIO()
        with redirect_stdout(buf):
            job = host.submit(spec, PredictionOptions(), '/tmp/weights')
        self.assertIn('PREDICT:submit:%s' % job.job_id, buf.getvalue())

        with open(job.request_path) as handle:
            request = json.load(handle)
        self.assertEqual(request['chains'], [{'chain': 'A', 'sequence': 'AG'}])
        self.assertEqual(request['weights_dir'], '/tmp/weights')
        self.assertEqual(request['diffusion_steps'], 200)
        self.assertEqual(request['job_id'], job.job_id)
        self.assertIn('status_path', request)
        self.assertIn('out_path', request)
        os.unlink(job.request_path)

    def testStatusIsQueuedUntilTheHostWrites(self):
        from pymol.predictors import host
        from pymol.predictors.base import PredictionOptions, PredictionSpec
        import io
        from contextlib import redirect_stdout
        with redirect_stdout(io.StringIO()):
            job = host.submit(PredictionSpec((('A', 'AG'),), 'p'),
                              PredictionOptions(), '/tmp/w')
        self.assertEqual(job.status()['state'], 'queued')
        os.unlink(job.request_path)

    def testStatusReflectsWhatTheHostWrote(self):
        from pymol.predictors import host
        from pymol.predictors.base import PredictionOptions, PredictionSpec
        import io
        from contextlib import redirect_stdout
        with redirect_stdout(io.StringIO()):
            job = host.submit(PredictionSpec((('A', 'AG'),), 'p'),
                              PredictionOptions(), '/tmp/w')
        with open(job.status_path, 'w') as handle:
            json.dump({'state': 'done', 'phase': 'done', 'fraction': 1.0,
                       'error': None, 'result_path': '/tmp/out.pdb'}, handle)
        status = job.status()
        self.assertEqual(status['state'], 'done')
        self.assertEqual(status['result_path'], '/tmp/out.pdb')
        # Reading a TERMINAL status is also what retires the job's inputs, so the
        # request is gone by now -- see HostJob._discard_inputs. The status file is
        # deliberately kept: predict_status must keep answering for a settled job.
        self.assertFalse(os.path.exists(job.request_path))
        os.unlink(job.status_path)

    def testHalfWrittenStatusFallsBackToQueued(self):
        """The 100 ms poll can read a status mid-write. That must degrade to `queued`,
        not leak a JSONDecodeError out of the caller."""
        from pymol.predictors import host
        from pymol.predictors.base import PredictionOptions, PredictionSpec
        import io
        from contextlib import redirect_stdout
        with redirect_stdout(io.StringIO()):
            job = host.submit(PredictionSpec((('A', 'AG'),), 'p'),
                              PredictionOptions(), '/tmp/w')
        with open(job.status_path, 'w') as handle:
            handle.write('{"state":"run')          # truncated mid-write
        status = job.status()
        self.assertEqual(status['state'], 'queued')
        self.assertIsNone(status['result_path'])
        os.unlink(job.request_path)
        os.unlink(job.status_path)

    def testEmptyStatusFileFallsBackToQueued(self):
        from pymol.predictors import host
        from pymol.predictors.base import PredictionOptions, PredictionSpec
        import io
        from contextlib import redirect_stdout
        with redirect_stdout(io.StringIO()):
            job = host.submit(PredictionSpec((('A', 'AG'),), 'p'),
                              PredictionOptions(), '/tmp/w')
        open(job.status_path, 'w').close()
        self.assertEqual(job.status()['state'], 'queued')
        os.unlink(job.request_path)
        os.unlink(job.status_path)

    def testCancelPrintsAMarker(self):
        import io
        from contextlib import redirect_stdout
        from pymol.predictors import host
        from pymol.predictors.base import PredictionOptions, PredictionSpec
        with redirect_stdout(io.StringIO()):
            job = host.submit(PredictionSpec((('A', 'AG'),), 'p'),
                              PredictionOptions(), '/tmp/w')
        buf = io.StringIO()
        with redirect_stdout(buf):
            job.cancel()
        self.assertIn('PREDICT:cancel:%s' % job.job_id, buf.getvalue())
        os.unlink(job.request_path)


class TestRegistration(testing.PyMOLTestCase):

    def testBoltz2IsRegistered(self):
        from pymol.predictors import registry
        self.assertIn('boltz2', registry.available())
