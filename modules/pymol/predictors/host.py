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

from .errors import PredictorUnavailable

#: Set by the Swift host next to PYMOL_PATH so Python can tell it is present.
HOST_ENV = 'RAYMOL_PREDICT_HOST'


def available():
    """True when an inference host is listening for PREDICT: markers.

    False under headless `pymol -c`, where nothing consumes the marker. Callers
    must refuse rather than submit a job that would hang forever.
    """
    return bool(os.environ.get(HOST_ENV))


def require_available(predictor_id):
    if not available():
        raise PredictorUnavailable(
            '%s needs the RayMol application host; it is not available in this '
            'process (headless PyMOL cannot run on-device inference)'
            % predictor_id)


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
        #: Where the host writes what it MEASURED, as a pymol.metrics document (#308).
        #: Separate from the PDB because most of it does not fit in one: a PAE matrix
        #: is per residue PAIR, and the interface scores are per run. Optional at the
        #: far end -- a host that predates it simply writes no file, and the run is
        #: recorded with its provenance and cost and no confidence numbers.
        self.metrics_path = _path('metrics', job_id, 'json')
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


def submit(spec, options, weights_path):
    """Write the request, print the marker, return the handle. Never blocks."""
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
        'weights_dir': weights_path or '',
        # Objects, not pairs: BoltzJobManager.Chain is a Codable struct with named
        # keys, so a positional array would fail to decode.
        'chains': [{'chain': chain, 'sequence': sequence}
                   for chain, sequence in spec.chains],
        # Per-chain alignments, absent when there are none. The host applies its own
        # dummy depth-1 alignment to any chain not listed, which is the designed-binder
        # case: an alignment for the target, none for the binder.
        'alignments': alignments,
        'recycling_steps': options.recycling_steps,
        'diffusion_steps': options.diffusion_steps,
        'seed': options.seed,
        # How many rows of each a3m to read. Applied on the HOST side, by the same
        # parser that reads the file, so the truncation is the parser's own -- the a3m
        # written above is always the whole alignment.
        'msa_depth': options.msa_depth,
        'out_path': job.out_path,
        'status_path': job.status_path,
        # Where to write the metrics document. OPTIONAL at the far end, like `runtime`
        # and `alignments`: a host that does not know the key writes nothing, and
        # deliver_result records the run without the confidence numbers rather than
        # failing to record it at all.
        'metrics_path': job.metrics_path,
        # The object the host loads the finished structure into. Resolved at submit time
        # so an empty placeholder can exist in the session immediately, and so the host
        # needs no second round-trip to find out where the result belongs.
        'object_name': getattr(spec, 'name', '') or '',
    }
    # Write completely before announcing it: the host reads on the next 100 ms
    # tick and must never see a partial request.
    _write(job.request_path, json.dumps(request))
    print('PREDICT:submit:%s' % job_id)
    return job
