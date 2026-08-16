"""Skeleton for a new RayMol structure predictor.

Copy to modules/pymol/predictors/<your_id>.py, then follow docs/predictors.md.
The leading underscore keeps _register_builtins() from picking this up.
"""
from .base import Predictor
from .errors import PredictionInputError, PredictorUnavailable
from .weights import WeightBundle


class TemplatePredictor(Predictor):

    # -- Identity ----------------------------------------------------------
    id = 'template'                  # stable selector; never change once shipped
    name = 'Template predictor'      # human-readable, for listings

    # -- Weights -----------------------------------------------------------
    # None if the method needs no weights. sha256 and size are of the ZIP's
    # bytes; `members` is the exact expected set of archive-root entries, which
    # WeightCache asserts after extraction because a predictor handed a
    # partially-extracted bundle usually misbehaves instead of failing.
    weight_bundle = WeightBundle(
        id='template-v1',
        version='v1',
        url='https://github.com/OWNER/REPO/releases/download/TAG/bundle.zip',
        sha256='0' * 64,
        size=0,
        members=('config.json', 'model.safetensors'),
    )

    # -- Options -----------------------------------------------------------
    # Only what the backend genuinely honours. Anything omitted is REJECTED by
    # validate_options(), never silently ignored.
    option_defaults = {'recycling_steps': 3, 'diffusion_steps': 200, 'seed': 0}

    # -- Multiple-sequence alignments --------------------------------------
    # True ONLY if this method can genuinely use one. Left False here, which is
    # what makes `predict ..., msa=x` refuse by name: a method that accepted an
    # alignment and folded single-sequence anyway would return a worse structure
    # with nothing in the result saying the alignment had been dropped.
    #
    # Setting this True means implementing two things: reading spec.alignments in
    # submit() (a chain id -> MSA map, PARTIAL -- chains without one fold
    # single-sequence), and adding 'msa_depth': MAX_MSA_DEPTH to option_defaults
    # above so the depth lever is accepted rather than rejected by name. Override
    # bind_alignments() for any constraint beyond "the query must be the sequence".
    supports_msa = False

    # -- Capability --------------------------------------------------------
    def check_available(self):
        """Raise PredictorUnavailable if this cannot run here and now.

        Check what is true before any work starts: platform, OS version, whether
        a host capable of running the backend is present. Do NOT check whether
        weights are cached -- that is the weight manager's job, and it is
        allowed to fix it by downloading.
        """
        raise PredictorUnavailable('%s: not implemented' % self.id)

    # -- Input validation --------------------------------------------------
    def parse_spec(self, sequence, name=''):
        """Return a PredictionSpec, or raise PredictionInputError.

        Reject here, loudly, rather than letting the backend silently drop
        residues it does not understand. Use base.parse_chains() for the "/"
        separator and single-uppercase chain ids.
        """
        raise PredictionInputError('%s: not implemented' % self.id)

    # -- Run ---------------------------------------------------------------
    def submit(self, spec, options, weights_path):
        """Start the run and return a job handle immediately.

        MUST NOT BLOCK. cmd.predict is reachable from the console, which runs on
        the main thread; blocking here stalls the render loop for the whole
        inference. Return a handle whose status() is a cheap poll and which
        exposes job_id, status(), cancel().
        """
        raise NotImplementedError


PREDICTOR = TemplatePredictor()
