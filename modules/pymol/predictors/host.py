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


class HostJob:
    """Handle on a job owned by the Swift side. Every method is a cheap poll."""

    def __init__(self, job_id, spec, options):
        self.job_id = job_id
        self.spec = spec
        self.options = options
        self.request_path = _path('req', job_id)
        self.status_path = _path('status', job_id)
        self.out_path = _path('result', job_id, 'pdb')

    def status(self):
        """The host's last written status, or 'queued' if it has not started."""
        try:
            with open(self.status_path) as handle:
                return json.load(handle)
        except (IOError, OSError, ValueError):
            return {'state': 'queued', 'phase': 'queued', 'fraction': 0.0,
                    'error': None, 'result_path': None}

    def cancel(self):
        """Ask the host to stop. Cancellation is cooperative and coarse: it lands
        on the per-diffusion-step checkCancellation, so worst case is one step."""
        print('PREDICT:cancel:%s' % self.job_id)


def submit(spec, options, weights_path):
    """Write the request, print the marker, return the handle. Never blocks."""
    job_id = uuid.uuid4().hex[:12]
    job = HostJob(job_id, spec, options)
    request = {
        'job_id': job_id,
        'weights_dir': weights_path or '',
        # Objects, not pairs: BoltzJobManager.Chain is a Codable struct with named
        # keys, so a positional array would fail to decode.
        'chains': [{'chain': chain, 'sequence': sequence}
                   for chain, sequence in spec.chains],
        'recycling_steps': options.recycling_steps,
        'diffusion_steps': options.diffusion_steps,
        'seed': options.seed,
        'out_path': job.out_path,
        'status_path': job.status_path,
    }
    # Write completely before announcing it: the host reads on the next 100 ms
    # tick and must never see a partial request.
    temp = job.request_path + '.tmp'
    with open(temp, 'w') as handle:
        json.dump(request, handle)
    os.replace(temp, job.request_path)
    print('PREDICT:submit:%s' % job_id)
    return job
