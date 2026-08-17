"""Boltz-2 via boltz-mlx: a Swift/MLX int8 port running on-device.

Protein-only, canonical-20, single-sequence (no MSA). Ligands, nucleic acids,
modified residues, cyclic peptides and structural templates are unsupported by the
featurizer and are rejected here rather than silently dropped.
"""
from . import host
from .base import Predictor, PredictionSpec, parse_chains
from .errors import PredictionInputError
from .weights import WeightBundle

#: The canonical 20. X, U, B and Z are deliberately absent: the featurizer throws
#: on any letter outside this set, so accepting them here would only defer the error.
CANONICAL = set('ACDEFGHIKLMNPQRSTVWY')

#: BoltzInputLimits.desktop caps at 1024 tokens, and one token is one residue.
MAX_RESIDUES = 1024


class Boltz2Predictor(Predictor):

    id = 'boltz2'
    name = 'Boltz-2 (MLX, int8)'

    # sha256 and size are of the published zip's bytes -- of the artifact actually
    # uploaded, not of a local re-export, because int8 quantization runs on Metal
    # and is not guaranteed bitwise-reproducible across machines.
    weight_bundle = WeightBundle(
        id='boltz2-mlx-int8',
        version='v1',
        url='https://github.com/javierbq/boltz-mlx/releases/download/weights-v1/'
            'boltz2-mlx-int8-v1.zip',
        sha256='ce9637f65f169cf98989d6b068469cf446fef49b9b90859d26f65f9853ea0cbd',
        size=529_338_573,
        members=('config.json', 'manifest.json', 'model.safetensors'),
    )

    # Upstream Boltz's defaults. The MLX port's own (0, 20) fail its own quality
    # gate at 3.19 A / 0.685 lDDT. step_scale is absent deliberately: it comes from
    # the artifact's config.json (already 1.5) and is not a per-call knob.
    # diffusion_samples is absent because the port does not plumb it and only
    # diffusion sample 0 escapes BoltzPredictor.
    option_defaults = {'recycling_steps': 3, 'diffusion_steps': 200, 'seed': 0}

    #: 'inference' is the coarse phase the host writes today, and it is zero-span
    #: because boltz-mlx v0.1.1 reports nothing from inside predictScored. 'trunk'
    #: and 'diffusion' replace it once v0.1.2's per-step callbacks land -- declared
    #: from day one so that increment is a Swift-side change with no rename and no
    #: edit here. They overlap 'inference' deliberately: they are alternative names
    #: for the same span, and exactly one of the three is ever the current phase.
    #:
    #: The weight fetch is absent on purpose. Its card owns that window and has a
    #: genuinely measured bytes/total bar; including it here would leave a
    #: warm-cache run -- every run after the first -- starting at ~25%.
    progress_phases = (
        ('featurize', 0.00, 0.03),
        ('load',      0.03, 0.10),
        ('inference', 0.10, 0.10),
        ('trunk',     0.10, 0.40),
        ('diffusion', 0.40, 0.97),
        ('write',     0.97, 1.00),
        ('done',      1.00, 1.00),
    )

    def check_available(self):
        host.require_available(self.id)

    def parse_spec(self, sequence, name=''):
        chains = parse_chains(sequence)
        total = 0
        for chain, seq in chains:
            bad = sorted(set(seq) - CANONICAL)
            if bad:
                raise PredictionInputError(
                    'chain %s contains residues Boltz-2 cannot fold: %s '
                    '(canonical 20 only; X, U, B and Z are not accepted)'
                    % (chain, ', '.join(bad)))
            total += len(seq)
        if total > MAX_RESIDUES:
            raise PredictionInputError(
                '%d residues exceeds the %d-residue limit' % (total, MAX_RESIDUES))
        return PredictionSpec(chains, name)

    def submit(self, spec, options, weights_path):
        return host.submit(spec, options, weights_path)
