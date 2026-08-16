"""SimpleFold via simplefold-mlx: an MLX-Swift port of Apple's flow-matching folder.

A SINGLE CHAIN, protein, canonical-20. SimpleFold has no notion of a complex --
`fold(sequence:)` takes one string, the tokenizer wraps it in a single CLS/EOS pair,
and the port has no chain-break token, no per-chain index and no cross-chain pair
feature. Handed two chains it would fold their CONCATENATION as one continuous chain
and emit a PDB nothing downstream could distinguish from a real prediction, so a
multi-chain input is refused here, plainly, before anything is submitted.

Single-sequence by construction: ESM2 embeddings plus a FoldingDiT sampler, with no
MSA anywhere in the pipeline. `supports_msa` is therefore False and left False, which
is what makes `predict ..., msa=...` refuse BY NAME rather than quietly folding
single-sequence -- see Predictor.bind_alignments.

Its one quality knob is `num_steps`, the number of flow-matching integration steps.
Nothing it shares with Boltz-2: there is no trunk to recycle and no reverse diffusion,
so `recycling_steps` and `diffusion_steps` are rejected by name.
"""
from . import host
from .base import Predictor, PredictionSpec, parse_chains
from .errors import PredictionInputError, PredictorUnavailable

#: The canonical 20. Everything else is refused rather than passed through: the
#: port's tokenizer resolves an unknown letter to X (`restypes.firstIndex(of:) ?? 20`)
#: instead of failing, so a typo would fold as an unknown residue with nothing in the
#: result saying a substitution had happened.
CANONICAL = set('ACDEFGHIKLMNPQRSTVWY')

#: Largest input measured end to end. Not a limit of the method -- SimpleFold's memory
#: is dominated by the ESM2 weights and is nearly flat in length -- but the point past
#: which nothing has been measured, and PredictSizeGuard's history is that an
#: unmeasured extrapolation is how a run gets jetsam-killed. Raise it with a
#: measurement, never without one.
MAX_RESIDUES = 900

#: The backend the Swift host must dispatch to, as it appears on the wire.
RUNTIME = 'simplefold'


class SimpleFoldPredictor(Predictor):

    id = 'simplefold'
    name = 'SimpleFold (MLX, int4)'

    # None until the quantized pack is published as a release asset, at which point
    # this becomes a WeightBundle and nothing else here changes.
    #
    # Deliberately not a placeholder bundle: `predict_weights download=1` iterates
    # EVERY registered predictor without consulting check_available, so a bundle
    # carrying a stand-in URL would be fetched by a command aimed at a different
    # predictor. The pack is three archive-root members -- esm2_3B_int4.safetensors
    # (~1.5 GB), fold_100M_int4.safetensors (~74 MB), aa_templates.json (~26 KB) --
    # and its sha256 must be taken from the bytes actually uploaded, not from a local
    # re-quantize, which is not bitwise reproducible.
    weight_bundle = None

    # No trunk, no reverse diffusion: `num_steps` is the flow-matching integration
    # count and the only quality lever. `msa_depth` is absent because there is no
    # alignment to have a depth, and its absence is what makes the depth lever
    # rejected by name rather than accepted and ignored.
    option_defaults = {'num_steps': 500, 'seed': 0}

    # Single-sequence by construction; see the module docstring.
    supports_msa = False

    def check_available(self):
        host.require_available(self.id)
        host.require_runtime(self.id, RUNTIME)
        if self.weight_bundle is None:
            # Weight state is normally none of check_available's business -- the
            # weight manager is allowed to fix a cold cache by downloading. An
            # UNPUBLISHED pack is a different thing: there is nothing to download, so
            # this is a capability the host lacks, which is exactly what belongs here.
            raise PredictorUnavailable(
                '%s has no published weight pack yet, so it cannot run. See #306.'
                % self.id)

    def parse_spec(self, sequence, name=''):
        chains = parse_chains(sequence)
        if len(chains) > 1:
            # A plain error, never a warning and never a fold of the first chain.
            # Both input paths land here: a typed "A/B", and an object or selection
            # spanning several chains, which resolve_input joins with "/" before this
            # is called -- so this one check covers a user who never typed a
            # separator at all.
            raise PredictionInputError(
                'simplefold cannot fold a complex: it models a single chain, and %d '
                'were given (%s). Fold each chain separately, or use boltz2 for a '
                'complex.' % (len(chains), ', '.join(c for c, _ in chains)))
        for chain, seq in chains:
            bad = sorted(set(seq) - CANONICAL)
            if bad:
                raise PredictionInputError(
                    'chain %s contains residues SimpleFold cannot fold: %s '
                    '(canonical 20 only; X, U, B and Z are not accepted)'
                    % (chain, ', '.join(bad)))
            if len(seq) > MAX_RESIDUES:
                raise PredictionInputError(
                    '%d residues exceeds the %d-residue limit'
                    % (len(seq), MAX_RESIDUES))
        return PredictionSpec(chains, name)

    def submit(self, spec, options, weights_path):
        return host.submit(spec, options, weights_path, runtime=RUNTIME,
                           knobs=self.option_defaults)
