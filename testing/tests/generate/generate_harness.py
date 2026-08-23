"""Shared fakes for the backbone-generation suite. No Swift, no network, no GPU.

The sibling of `testing/tests/predict/predict_weights_download.py`, and it imports the
network fakes from there rather than growing a second copy: a zip and a fake urlopen are
not generator-specific, and two versions of "what a weight download looks like" would
drift exactly where a drift is invisible.
"""
import os
import sys

# The runner imports test files by path (testing.py:48) and never puts their directory on
# sys.path, so a sibling import needs it added explicitly. At import time, before setUp's
# chdir, hence __file__ and not '.'.
_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)
_PREDICT = os.path.join(os.path.dirname(_HERE), 'predict')
if _PREDICT not in sys.path:
    sys.path.insert(0, _PREDICT)

from predict_weights_download import FakeResponse, make_zip  # noqa: E402,F401

from pymol import cmd, testing  # noqa: E402
from pymol.predictors import host  # noqa: E402


def settle(bundle_id='stubgen', timeout=10.0):
    """Wait out the background weight fetch, then run the main-thread pump.

    `design_backbone` never downloads inline (#284): a cold cache starts a worker thread
    and the job is submitted later, by pump(), on the main thread. Tests do explicitly what
    the app's panel poll does for them.

    CALL THIS INSIDE the `with patch(_urlopen)` block. The worker outlives the call that
    started it, so an exited patch leaves the thread reaching for the real URL -- which
    surfaces as a DNS error inside some other, unrelated test.
    """
    from pymol import designing
    from pymol.predictors import fetching
    fetching.join(bundle_id, timeout=timeout)
    designing.pump()


def deliver(jobs):
    """Do what the Swift runtime does when a design finishes: load it and record it.

    There is no host in a headless test, so nothing prints the result into the session --
    the autoload path is `InferenceJob.loadResult` calling `designing.deliver_result`.
    Tests drive that call themselves, which is also how the prediction suite exercises its
    own delivery path rather than asserting on a mock.
    """
    from pymol import designing
    for job in (jobs if isinstance(jobs, (list, tuple)) else [jobs]):
        real = getattr(job, '_real', None) or job
        status = real.status()
        if status.get('state') == 'done' and status.get('result_path'):
            designing.deliver_result(status['result_path'], job.spec.name,
                                     seed=real.options.seed)


class StubDesignJob:
    """A job handle that writes a two-chain PDB on demand and reports done."""

    _counter = 0

    def __init__(self, spec, options, weights_path):
        StubDesignJob._counter += 1
        self.job_id = 'stubgen-%d' % StubDesignJob._counter
        self.spec = spec
        self.options = options
        self.weights_path = weights_path
        self.cancelled = False
        #: Where a real job's runtime would write its metric document. Left absent unless a
        #: test writes one, so the no-document path is the default -- which is the path a
        #: host that measured nothing takes.
        self.metrics_path = os.path.join(weights_path or '.',
                                         '%s-metrics.json' % self.job_id)

    def status(self):
        return {'state': 'done', 'phase': 'done', 'fraction': 1.0, 'error': None,
                'result_path': self.result_path, 'peak_bytes': 2 ** 30,
                'elapsed_s': 12.5}

    @property
    def result_path(self):
        """The target plus a designed chain, which is what a design IS.

        Two chains rather than one, because the pair being emitted together is a decision
        this feature makes rather than an accident: a test that accepted a one-chain result
        would pass while the thing the refold step needs went missing.
        """
        path = os.path.join(self.weights_path, '%s.pdb' % self.job_id)
        if not os.path.exists(path):
            lines = []
            serial = 1
            for index, residue in enumerate(self.spec.target.residues):
                for name, (x, y, z) in residue.atoms:
                    lines.append(_atom(serial, name, residue.resn, residue.chain,
                                       residue.resi, x, y, z))
                    serial += 1
            lines.append('TER')
            for index in range(self.spec.length):
                for offset, name in enumerate(('N', 'CA', 'C', 'O')):
                    lines.append(_atom(serial, name, 'ALA', self.spec.design_chain,
                                       str(index + 1),
                                       30.0 + index * 3.8 + offset * 0.5, 5.0, 5.0))
                    serial += 1
            lines.append('TER')
            lines.append('END')
            with open(path, 'w') as handle:
                handle.write('\n'.join(lines) + '\n')
        return path

    def cancel(self):
        self.cancelled = True


def _atom(serial, name, resn, chain, resi, x, y, z):
    padded = name if len(name) >= 4 else ' %-3s' % name
    return ('ATOM  %5d %s %3s %1s%4s    %8.3f%8.3f%8.3f  1.00  0.00          %2s'
            % (serial, padded, resn, chain or 'A', resi, x, y, z, name[0]))


def install_stub(digest, size, runtime='stubruntime'):
    """Register a stub generator and return its class.

    Its `runtime` is NOT 'rfd3' by default: a stub that claimed the real runtime would
    make every host-availability test pass for the wrong reason.
    """
    from pymol.generators import registry
    from pymol.generators.base import DesignSpec, Generator, require_single_chain
    from pymol.predictors import host as _host
    from pymol.predictors.weights import WeightBundle
    from pymol.generators.metrics import DESIGN_SPECS

    class Stub(Generator):
        id = 'stubgen'
        name = 'Stub generator'
        weight_bundle = WeightBundle(
            id='stubgen', version='v1', url='https://example.invalid/g.zip',
            sha256=digest, size=size, members=('config.json', 'model.bin'))
        option_defaults = {'recycling_steps': 2, 'diffusion_steps': 200, 'seed': 0}
        metric_specs = DESIGN_SPECS
        progress_phases = (('featurize', 0.0, 0.1), ('diffusion', 0.1, 1.0))

        def check_available(self):
            _host.require_available(self.id)
            _host.require_runtime(self.id, runtime)

        def parse_target(self, target, length, name=''):
            require_single_chain(target.residues)
            return DesignSpec(target, length, name=name, generator_id=self.id,
                              design_chain='B')

        def submit(self, spec, options, weights_path):
            return StubDesignJob(spec, options, weights_path)

    registry.register(Stub(), replace=True)
    return Stub


#: Generators registered before a test ran, restored afterwards.
class GeneratorTestCase(testing.PyMOLTestCase):
    """Restores the host env, the weight-dir override, the registry and the job tables.

    Every one of these leaks across files otherwise: the runner shares one interpreter, and
    a stub generator or a stray `RAYMOL_PREDICT_RUNTIMES` left behind makes a LATER file
    pass or fail for a reason that is not in it.
    """

    def setUp(self):
        testing.PyMOLTestCase.setUp(self)
        from pymol.generators import registry
        self._saved_env = {name: os.environ.get(name)
                           for name in (host.HOST_ENV, host.RUNTIMES_ENV,
                                        'RAYMOL_WEIGHTS_DIR')}
        self._saved_generators = {gid: registry.get(gid)
                                  for gid in registry.available()}

    def tearDown(self):
        from pymol import designing
        from pymol.generators import registry
        from pymol.predictors import fetching
        try:
            designing.clear_pending()
        except Exception:
            pass
        designing._JOBS.clear()
        fetching.shutdown()
        for gid in list(registry.available()):
            if gid not in self._saved_generators:
                registry.unregister(gid)
        for gid, generator in self._saved_generators.items():
            registry.register(generator, replace=True)
        for name, value in self._saved_env.items():
            if value is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = value
        testing.PyMOLTestCase.tearDown(self)

    def declareHost(self, runtimes):
        os.environ[host.HOST_ENV] = '1'
        os.environ[host.RUNTIMES_ENV] = runtimes

    def helix(self, name='tgt', length=20, chain='A', first=1):
        """A poly-alanine helix to design against, with a real chain id and numbering."""
        cmd.fab('A' * length, name, ss=1)
        cmd.alter(name, 'chain=%r' % chain)
        cmd.alter(name, 'resi=str(int(resi) + %d)' % (first - 1))
        cmd.sort(name)
        return name
