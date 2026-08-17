"""Protenix via protenix-mlx: ByteDance's AlphaFold3-class predictor, in Swift/MLX.

Protein-only, canonical-20, complexes included: the port's featurizer groups chains into
entities and builds the cross-chain pair features, so a multimer is something this method
genuinely models rather than something it approximates. What it carries no reference
conformers for -- ligands, nucleic acids, modified residues, anything needing the chemical
component dictionary at fold time -- is refused by name rather than folded as an
approximation of itself.

This is also the SECOND inference runtime, and the first request that has to say so. The
`runtime` field, `host.require_runtime` and `RAYMOL_PREDICT_RUNTIMES` exist because of it:
weights and featurizer are method-specific, so a Protenix request that reached the Boltz
backend would not fail, it would return a confident wrong structure.

Single-sequence. `supports_msa` is False and staying False until an a3m can actually
reach `msa_features`: the port feeds the network upstream's depth-1 dummy alignment, and
a method that accepted a real alignment and then folded against that dummy would return
a worse structure with nothing in the result saying so. The MSA module itself IS ported,
so this becomes possible rather than remaining structural -- see #274.

The port DOES have a confidence head -- pLDDT, PAE, PDE and resolved, verified against
PyTorch to 2e-4 -- and this predictor deliberately declares none of it yet. `metric_specs`
needs the per-object metric store (#308) to have somewhere to put a per-residue array, so
the declaration lands with that rather than here. Until then a fold arrives with its
provenance and cost and no confidence numbers, which is the honest state: the runtime can
compute them and RayMol cannot yet keep them.

Worth knowing before running it: single-sequence output degrades sharply with length. On
complete domains, mean pLDDT goes 94.8 at 35 residues, 67.5 at 76, 58.9 at 110, 37.0 at
129, and sits near 26 from 400 up. That is the documented behaviour of an AF3-class model
with no alignment rather than a fault in the port, and it means this method earns its time
on small domains and not much else until #274 gives it a real one.
"""
from . import host
from .base import Predictor, PredictionSpec, parse_chains
from .errors import PredictionInputError, PredictorUnavailable
from .weights import WeightBundle

#: The canonical 20. Everything else is refused rather than substituted: the port's
#: featurizer raises on an unknown letter instead of resolving it to X, so accepting one
#: here would only defer the same error past a 214 MB download.
CANONICAL = set('ACDEFGHIKLMNPQRSTVWY')

#: Measured peak memory at the shipped operating point (recycling 10 / 200 steps, with
#: the confidence head), on an M-series Mac against the base int8 pack. This is MLX's own
#: high-water mark, not process RSS: the two are different numbers and RSS is not even
#: monotonic in problem size, because MLX recycles buffers in a cache it need not return
#: to the OS -- measured by RSS, 400 residues appears to cost LESS than 60.
#:
#:     residues     60    120    250    400    550    700
#:     peak        547    942   2279   3868   6303   8622  MiB
#:     mean pLDDT 82.7   47.3   30.9   27.2   26.2   26.3
MEASURED_PEAK_MIB = ((60, 547), (120, 942), (250, 2279), (400, 3868), (550, 6303),
                     (700, 8622))

#: The cap sits BELOW the largest measurement rather than at it, which is the one place
#: this file departs from "the largest input measured".
#:
#: 700 residues runs, at 8.6 GB and six minutes. That is not a fold to permit by default:
#: alongside a loaded session it is where a jetsam kill takes the user's unsaved work,
#: which `PredictSizeGuard` exists to prevent and which no Swift handler can intercept.
#: And the model's own confidence at that length is 26 -- the run costs six minutes to
#: produce a structure it says nothing can be concluded from.
#:
#: 400 (3.9 GB) is the largest length that both fits comfortably and is worth the wait.
#: Raise it with a measurement AND a reason, never with either alone.
MAX_RESIDUES = 400

#: What single-sequence folding is actually worth here, measured on the same pack. Mean
#: pLDDT against length, over COMPLETE domains rather than truncations (a truncation
#: scores badly for reasons of its own):
#:
#:     villin 35   GB1 56   ubiquitin 76   barnase 110   lysozyme 129
#:       94.8       72.3        67.5          58.9          37.0
#:
#: That is the documented behaviour of an AF3-class model with no alignment, not a fault
#: in the port -- the same pack discriminates correctly at small sizes (villin 94.8
#: against 78.4 for poly-alanine of the same length). It is recorded here because it is
#: the single most useful thing to know before spending two minutes on a fold: past
#: roughly a hundred residues, single-sequence output is not worth much, and #274 is what
#: changes that rather than a bigger pack. Lysozyme is the low outlier for a second
#: reason worth naming -- it has four disulfides, and `token_bonds` is all zeros here.
MEASURED_CONFIDENCE = ((35, 94.8), (56, 72.3), (76, 67.5), (110, 58.9), (129, 37.0))

#: The backend the Swift host must dispatch to, as it appears on the wire.
RUNTIME = 'protenix'


class ProtenixBasePredictor(Predictor):

    id = 'protenix-base'
    name = 'Protenix base (MLX, int8)'

    # sha256 and size are of the bytes GitHub serves, taken from protenix-mlx's
    # WEIGHTS.md, which records the digest of the uploaded asset rather than of a local
    # rebuild -- int8 quantization runs on Metal and is not bitwise reproducible across
    # machines, so a re-export would not match.
    #
    # Three members, the same shape boltz2's pack has, so WeightCache needs no change.
    # `config.json` is not optional decoration here: a Protenix checkpoint carries no
    # architecture at all (it is `{"model": state_dict, "model_version"}`), and the four
    # variants share tensor NAMES while differing in depth and width, so the runtime
    # cannot tell an 8-block Pairformer from a 48-block one without it.
    weight_bundle = WeightBundle(
        id='protenix-base-mlx-int8',
        version='v1',
        url='https://github.com/javierbq/protenix-mlx/releases/download/weights-base-v1/'
            'protenix-base-mlx-int8-v1.zip',
        sha256='6a405fbfb0f3b331315bc317106f22ed5daf10eb7b9b1122c4eae5db77b26977',
        size=224_688_268,
        members=('config.json', 'manifest.json', 'model.safetensors'),
    )

    # The released model's own operating point, from its config.json: 10 recycles and
    # 200 diffusion steps. Both knobs already exist on cmd.predict because Boltz-2 has
    # them and they mean the same thing here -- Protenix recycles a trunk and runs
    # reverse diffusion -- so this is the first predictor that adds no knob to
    # predicting.py at all.
    #
    # msa_depth is absent, which is what makes the depth lever rejected by name rather
    # than accepted and ignored: there is no alignment to have a depth.
    option_defaults = {'recycling_steps': 10, 'diffusion_steps': 200, 'seed': 0}

    # Single-sequence; see the module docstring.
    supports_msa = False

    # Deliberately not declared yet: the runtime computes pLDDT and the PAE matrix, and
    # a per-residue array needs the metric store (#308) to land in. Declaring keys with
    # nowhere to write them would put numbers in the schema that never arrive.
    metric_specs = ()

    def check_available(self):
        host.require_available(self.id)
        # After require_available, because the two failures have different remedies:
        # "you are headless" versus "this build does not carry that backend". Checking
        # here is what refuses BEFORE a 214 MB download rather than after it.
        host.require_runtime(self.id, RUNTIME)

    def parse_spec(self, sequence, name=''):
        chains = parse_chains(sequence)
        total = 0
        for chain, seq in chains:
            bad = sorted(set(seq) - CANONICAL)
            if bad:
                raise PredictionInputError(
                    'chain %s contains residues Protenix cannot fold here: %s. This '
                    'runtime carries reference conformers for the canonical 20 only, '
                    'so ligands, nucleic acids, modified residues and X, U, B and Z '
                    'are refused rather than folded as something else.'
                    % (chain, ', '.join(bad)))
            total += len(seq)
        if total > MAX_RESIDUES:
            raise PredictionInputError(
                '%d residues exceeds the %d-residue limit. That limit is the largest '
                'input measured on this device class, not a limit of the method: '
                'Protenix is ~N^2 in tokens across 48 Pairformer blocks and ten '
                'recycles, and an unmeasured extrapolation is how a run gets killed '
                'mid-fold.' % (total, MAX_RESIDUES))
        return PredictionSpec(chains, name)

    def submit(self, spec, options, weights_path):
        return host.submit(spec, options, weights_path, runtime=RUNTIME,
                           knobs=self.option_defaults)
