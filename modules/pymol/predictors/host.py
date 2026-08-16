"""Transport to the Swift inference host.

RayMol has no Python->Swift call path: PyMOLBridge.h is one-directional and no
Swift function carries a C symbol. So this module writes a request JSON to the
temp dir and prints a short PREDICT: marker on the feedback line, which the app's
existing 100 ms pollFeedback() already scans -- the same mechanism OBJPANEL: and
SETTINGS:ready use. Payloads go through files because the feedback line caps at
~1 KB.

Because cmd.predict returns a job handle, nothing here needs a synchronous return
value from Swift: status and result are files this module polls.

The JSON keys below are a contract with BoltzJobManager.Request / .Status.
"""
import json
import os
import tempfile
import uuid

from .base import PredictionOptions
from .errors import PredictorUnavailable

#: Set by the Swift host next to PYMOL_PATH so Python can tell it is present.
HOST_ENV = 'RAYMOL_PREDICT_HOST'

#: Comma-separated inference runtimes the host has actually linked, set beside
#: HOST_ENV. A host is not one capability but several: the app may carry the Boltz
#: runtime and not the SimpleFold one, and a predictor whose runtime is missing must
#: say so in check_available rather than submit a job that would be refused, or worse
#: run on the wrong backend.
RUNTIMES_ENV = 'RAYMOL_PREDICT_RUNTIMES'

#: What a host that does not declare RUNTIMES_ENV is assumed to carry. Every build
#: before this variable existed had exactly the Boltz runtime, so this keeps an older
#: app -- or a test that only sets HOST_ENV -- working unchanged.
DEFAULT_RUNTIME = 'boltz'


def available():
    """True when an inference host is listening for PREDICT: markers.

    False under headless `pymol -c`, where nothing consumes the marker. Callers
    must refuse rather than submit a job that would hang forever.
    """
    return bool(os.environ.get(HOST_ENV))


def supported_runtimes():
    """Inference runtimes this host can actually run, as a tuple."""
    declared = os.environ.get(RUNTIMES_ENV, '')
    names = tuple(part.strip() for part in declared.split(',') if part.strip())
    return names or (DEFAULT_RUNTIME,)


def require_available(predictor_id):
    if not available():
        raise PredictorUnavailable(
            '%s needs the RayMol application host; it is not available in this '
            'process (headless PyMOL cannot run on-device inference)'
            % predictor_id)


def require_runtime(predictor_id, runtime):
    """Raise unless the host declares `runtime`. Call after require_available().

    Separate from require_available() because the two failures have different
    remedies: no host at all means "you are running headless", while a missing
    runtime means "this build of RayMol does not carry that backend".
    """
    if runtime not in supported_runtimes():
        raise PredictorUnavailable(
            '%s needs the %r inference runtime, which this build of RayMol does '
            'not carry (it has: %s)'
            % (predictor_id, runtime, ', '.join(supported_runtimes())))


def _path(kind, job_id, suffix='json'):
    return os.path.join(tempfile.gettempdir(),
                        'raymol_predict_%s_%s.%s' % (kind, job_id, suffix))


#: A job's outcome is decided once and never revisited.
TERMINAL_STATES = ('done', 'failed', 'cancelled')


class HostJob:
    """Handle on a job owned by the Swift side. Every method is a cheap poll."""

    def __init__(self, job_id, spec, options):
        self.job_id = job_id
        self.spec = spec
        self.options = options
        self.request_path = _path('req', job_id)
        self.status_path = _path('status', job_id)
        self.out_path = _path('result', job_id, 'pdb')
        #: Chain id -> a3m written for this job. Cleaned up when the job settles.
        self.a3m_paths = {}

    def status(self):
        """The host's last written status, or 'queued' if it has not started."""
        try:
            with open(self.status_path) as handle:
                state = json.load(handle)
        except (IOError, OSError, ValueError):
            return {'state': 'queued', 'phase': 'queued', 'fraction': 0.0,
                    'error': None, 'result_path': None,
                    'peak_bytes': None, 'elapsed_s': None}
        if state.get('state') in TERMINAL_STATES:
            self._discard_inputs()
        return state

    def _discard_inputs(self):
        """Delete what only the host needed to READ, once it can no longer need it.

        An alignment is megabytes and a session can submit many jobs, so leaving them
        in the temp dir for the OS to reap eventually is not good enough. Driven off a
        TERMINAL status rather than a timer: the host reads the a3m during featurize,
        which is reported as `running`, so this cannot race the reader.

        Deliberately not the RESULT: `predict_result` loads it by path, and a user may
        do so long after the job finished. The status file stays too -- predict_status
        must keep answering for a job that has already settled.
        """
        for path in list(self.a3m_paths.values()) + [self.request_path]:
            try:
                os.remove(path)
            except OSError:
                pass
        self.a3m_paths = {}

    def cancel(self):
        """Ask the host to stop.

        Cancellation is cooperative. The host cancels the Swift Task running inference,
        which boltz-mlx observes at each diffusion step -- so during the diffusion phase
        the worst case is roughly one step. It is coarser elsewhere: the trunk has no
        cancellation points at all, so a cancel arriving during featurization or the
        trunk pass is not observed until that phase completes.
        """
        print('PREDICT:cancel:%s' % self.job_id)


def _write(path, text):
    """Write `text` where a poller may be watching: complete, or not there at all."""
    temp = path + '.tmp'
    with open(temp, 'w') as handle:
        handle.write(text)
    os.replace(temp, path)


def submit(spec, options, weights_path, runtime=DEFAULT_RUNTIME, knobs=None):
    """Write the request, print the marker, return the handle. Never blocks.

    `runtime` names the backend the host must dispatch to. `knobs` is the option
    names to put on the wire -- pass the predictor's own `option_defaults`, so the
    request carries exactly what that method declared it honours and nothing else.
    A knob absent from the request is one the runtime at the far end must supply a
    default for; sending every predictor every knob would put `recycling_steps` in
    a SimpleFold request, which has no trunk to recycle.
    """
    job_id = uuid.uuid4().hex[:12]
    job = HostJob(job_id, spec, options)

    # Alignments go as PATHS, and the files are written BEFORE the request that names
    # them. Two decisions worth keeping:
    #
    # Paths, not inline text, because an a3m is megabytes -- the barnase alignment is
    # ~1.3 MB -- and base64 inside a JSON the host reads in one gulp buys nothing over
    # a file it streams.
    #
    # Written first, because the request is what ANNOUNCES them: the host reads on its
    # next 100 ms tick, so a request naming a half-written a3m is the one ordering bug
    # available here, and it would surface as a parse error on a file the user can see
    # is complete by the time they look.
    #
    # PER JOB, not per spec, so `n_models=N` writes the same alignment N times. That is
    # deliberate: sharing one file across the N jobs would tie their lifetimes together
    # and need reference counting to know when the last reader is done, to save temp
    # space that is bounded at MAX_MODELS x the a3m -- tens of megabytes for a real
    # alignment. Each job owning its inputs outright is the cheaper correctness.
    alignments = []
    for chain_id, msa in sorted(getattr(spec, 'alignments', {}).items()):
        path = _path('msa', '%s_%s' % (job_id, chain_id), 'a3m')
        _write(path, msa.a3m)
        job.a3m_paths[chain_id] = path
        alignments.append({'chain': chain_id, 'a3m_path': path})

    request = {
        'job_id': job_id,
        # Which backend runs this. OPTIONAL at the far end, absent meaning boltz, so
        # a request written by a Python side that predates the second runtime still
        # decodes -- the same reasoning as `object_name` and `alignments`.
        'runtime': runtime,
        'weights_dir': weights_path or '',
        # Objects, not pairs: BoltzJobManager.Chain is a Codable struct with named
        # keys, so a positional array would fail to decode.
        'chains': [{'chain': chain, 'sequence': sequence}
                   for chain, sequence in spec.chains],
        # Per-chain alignments, absent when there are none. The host applies its own
        # dummy depth-1 alignment to any chain not listed, which is the designed-binder
        # case: an alignment for the target, none for the binder.
        'alignments': alignments,
        'out_path': job.out_path,
        'status_path': job.status_path,
        # The object the host loads the finished structure into. Resolved at submit time
        # so an empty placeholder can exist in the session immediately, and so the host
        # needs no second round-trip to find out where the result belongs.
        'object_name': getattr(spec, 'name', '') or '',
    }
    # The inference knobs, exactly as the predictor declared them. `msa_depth` is one
    # of these for an MSA-capable method: it says how many rows of each a3m to read,
    # applied on the HOST side by the same parser that reads the file, so the
    # truncation is the parser's own -- the a3m written above is always the whole
    # alignment.
    if knobs is None:
        knobs = PredictionOptions.__slots__
    for knob in knobs:
        request[knob] = getattr(options, knob)
    # Write completely before announcing it: the host reads on the next 100 ms
    # tick and must never see a partial request.
    _write(job.request_path, json.dumps(request))
    print('PREDICT:submit:%s' % job_id)
    return job
