"""Boltz-2 via boltz-mlx: a Swift/MLX int8 port running on-device.

Protein-only, canonical-20. Ligands, nucleic acids, modified residues, cyclic
peptides and structural templates are unsupported by the featurizer and are rejected
here rather than silently dropped.

Multiple-sequence alignments ARE supported (#297): the featurizer takes a per-chain
map and falls back to upstream's depth-1 dummy alignment for any chain without one.
Cross-chain PAIRING is inert for locally generated a3m files -- taxonomy is read only
from `>UniRef100_*` headers and only when a taxonomy database is supplied, which
nothing here supplies -- so a multimer gets per-chain alignments, not a paired one.
"""
from . import host
from .base import MAX_MSA_DEPTH, Predictor, PredictionSpec, parse_chains
from .errors import PredictionInputError
from .weights import WeightBundle

#: The canonical 20. X, U, B and Z are deliberately absent: the featurizer throws
#: on any letter outside this set, so accepting them here would only defer the error.
CANONICAL = set('ACDEFGHIKLMNPQRSTVWY')

#: BoltzInputLimits.desktop caps at 1024 tokens, and one token is one residue.
MAX_RESIDUES = 1024

#: The backend the Swift host dispatches to. Also what a request with no `runtime` at all
#: is taken to mean, so an older Python side keeps working -- see host.DEFAULT_RUNTIME.
RUNTIME = 'boltz'


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
    #
    # msa_depth is the memory lever: MSA tensors are depth x tokens, so it is the one
    # knob that changes peak memory without changing what is being folded. Defaulted to
    # the ceiling, so an alignment is used in full unless the user says otherwise.
    option_defaults = {'recycling_steps': 3, 'diffusion_steps': 200, 'seed': 0,
                       'msa_depth': MAX_MSA_DEPTH}

    # The featurizer takes `alignments:` and throws msaLengthMismatch / msaQueryMismatch
    # on a mismatch rather than falling back to a dummy MSA the way upstream does.
    supports_msa = True

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
        return host.submit(spec, options, weights_path, runtime=RUNTIME,
                           knobs=self.option_defaults)
