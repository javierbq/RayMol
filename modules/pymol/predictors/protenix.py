"""Protenix via protenix-mlx: ByteDance's AlphaFold3-class predictor, in Swift/MLX.

Twelve packs: four model variants at three precisions each, every one a separate
predictor id. That is the `boltz2` / `boltz2-bf16` pattern taken to its conclusion — one
runtime, many tools — and it works for the same reason: `host.submit` sends `weights_dir`
per job and the Swift side picks its matmul path from the artifact manifest, so a dense
pack needs no code of its own.

Protein-only, canonical-20, complexes included: the port's featurizer groups chains into
entities and builds the cross-chain pair features, so a multimer is something this method
genuinely models rather than approximates. What it carries no reference conformers for --
ligands, nucleic acids, modified residues, anything needing the chemical component
dictionary at fold time -- is refused by name rather than folded as an approximation.

Single-sequence. `supports_msa` is False and staying so until an a3m can reach
`msa_features`: the port feeds the network upstream's depth-1 dummy alignment, and a
method that accepted a real alignment then folded against that dummy would return a worse
structure with nothing in the result saying so. The MSA module IS ported, so this becomes
reachable rather than remaining structural -- see #274.

**Which one to use.** `protenix-base-int8` is the default choice and the one whose memory
is measured most thoroughly. tiny and mini are v0.5.0 models at 4 recycles / 5 diffusion
steps: seconds rather than minutes, and correspondingly rough -- they exist for iteration,
not for answers. The dense precisions cost roughly twice the disk and more memory for no
demonstrated accuracy, exactly as `boltz2-bf16` does; they are here so that experiment is
possible on-device rather than because they are better.

**What single-sequence folding is worth.** Mean pLDDT falls off sharply with length, on
complete domains: 94.8 at 35 residues, 67.5 at 76, 58.9 at 110, 37.0 at 129, ~26 from 400
up. That is the documented behaviour of an AF3-class model with no alignment, not a fault
in the port -- the same pack scores villin 94.8 against poly-alanine 78.4 at equal length.
It means this method earns its time on small domains until #274 gives it an alignment.
"""
from . import host
from .base import Predictor, PredictionSpec, parse_chains
from .errors import PredictionInputError
from .weights import WeightBundle

#: The canonical 20. Everything else is refused rather than substituted: the port's
#: featurizer raises on an unknown letter instead of resolving it to X, so accepting one
#: here would only defer the same error past a multi-hundred-megabyte download.
CANONICAL = set('ACDEFGHIKLMNPQRSTVWY')

#: The backend the Swift host must dispatch to, as it appears on the wire. One runtime
#: serves every pack below.
RUNTIME = 'protenix'

#: Measured peak memory (MiB) at each variant's own operating point, int8, with the
#: confidence head, on an M-series Mac. MLX's own high-water mark, not process RSS --
#: measured by RSS the same sweep reads 400 residues as costing LESS than 60, because MLX
#: recycles buffers in a cache it need not return to the OS.
#:
#:                60 res   250 res   400 res
#:     tiny          250      2083      3494
#:     mini          298      2172      3625
#:     base          547      2279      3868
#:     v2            -- (509 MiB at 15 residues; its 256-wide pair track costs more)
#:
#: The variants converge as the input grows: at 400 residues they are within 10% of each
#: other, because the N^2 pair representation dwarfs the weights. Which is why the cap
#: below is the same for all of them rather than scaled by parameter count -- the thing
#: that decides whether a fold fits is the sequence, not the pack.
MEASURED_PEAK_MIB = {
    'tiny': ((60, 250), (250, 2083), (400, 3494)),
    'mini': ((60, 298), (250, 2172), (400, 3625)),
    'base': ((60, 547), (120, 942), (250, 2279), (400, 3868), (550, 6303), (700, 8622)),
    # v2 is swept only at the short end so far. Its pair track is 256 wide against every
    # other variant's 128, so the N^2 term is doubled and base's curve UNDERSTATES it --
    # which is the direction that gets a session jetsam-killed. Until it is swept
    # properly, V2_MAX_RESIDUES caps it well inside what has been run.
    'v2': ((15, 509),),
}

#: Hard ceiling, in residues, across every variant.
#:
#: Below the largest measurement (700 for base, at 8.6 GB and six minutes) on purpose:
#: alongside a loaded session that is where a jetsam kill takes the user's unsaved work,
#: and the model's own confidence at that length is 26 -- six minutes to produce a
#: structure it says nothing can be concluded from. 400 is the largest length that both
#: fits comfortably and is worth the wait. Raise it with a measurement AND a reason.
MAX_RESIDUES = 400

#: v2's own ceiling, lower because its memory is only measured at the short end and its
#: pair representation is twice as wide. Not a judgement about the model -- it scores
#: highest of the four on a short probe -- but about what has been measured.
V2_MAX_RESIDUES = 250


class _Pack:
    """One published weight pack: what to fetch, and how the model it holds behaves."""

    __slots__ = ('variant', 'precision', 'url', 'sha256', 'size')

    def __init__(self, variant, precision, url, sha256, size):
        self.variant = variant
        self.precision = precision
        self.url = url
        self.sha256 = sha256
        self.size = size


#: Precision as it appears in a predictor id. Shortened for the same reason `boltz2-bf16`
#: is: the id is typed at a prompt. Every id ends in one of these, so no id is a PREFIX of
#: another and `predict protenix-b<Tab>` never lands on a dead end -- the trap
#: docs/predictors.md step 1 records `boltz2` falling into.
_SUFFIX = {'int8': 'int8', 'float16': 'fp16', 'bfloat16': 'bf16'}

#: Recycles and diffusion steps, from each variant's own config.json. tiny and mini are
#: v0.5.0 models trained to a much shorter schedule; using base's 10/200 on them would
#: spend forty times the compute on a model that was not trained to use it.
_OPERATING_POINT = {
    'tiny': (4, 5),
    'mini': (4, 5),
    'base': (10, 200),
    'v2': (10, 200),
}

_DESCRIPTION = {
    'tiny': 'Protenix tiny v0.5.0',
    'mini': 'Protenix mini v0.5.0',
    'base': 'Protenix base v1.0.0',
    'v2': 'Protenix v2',
}

#: Every published pack, transcribed from protenix-mlx's WEIGHTS.md, which records the
#: digest of the UPLOADED asset rather than of a local rebuild -- int8 quantization runs
#: on Metal and is not bitwise reproducible across machines, so a re-export would not
#: match. Generated from that file rather than typed: twelve hand-copied digests is
#: twelve chances to paste the wrong one, and a wrong digest fails only on a user's
#: machine, after the download.
_PACKS = (
    _Pack('tiny', 'int8',
          'https://github.com/javierbq/protenix-mlx/releases/download/weights-tiny-v1/'
          'protenix-tiny-mlx-int8-v1.zip',
          '11716a7c69d10c0b9c90410503bc2b4b05a3c83f8b39c572bf4d962a56094858',
          87_543_789),
    _Pack('tiny', 'float16',
          'https://github.com/javierbq/protenix-mlx/releases/download/weights-tiny-v1/'
          'protenix-tiny-mlx-float16-v1.zip',
          '73fdf864366461380cee4b316b354018118e55f5d0ce6ee7be698d30b64274a1',
          173_209_981),
    _Pack('tiny', 'bfloat16',
          'https://github.com/javierbq/protenix-mlx/releases/download/weights-tiny-v1/'
          'protenix-tiny-mlx-bfloat16-v1.zip',
          '77777d1a40dc45b5de900978e2d0018fd361e93fdebb4384c4928c07866b99b9',
          151_635_809),
    _Pack('mini', 'int8',
          'https://github.com/javierbq/protenix-mlx/releases/download/weights-mini-v1/'
          'protenix-mini-mlx-int8-v1.zip',
          'ea3a8f81ad8ce055b5b3d1dba92f595b5284dfc2c13b8eedd0458827babc0cea',
          96_248_656),
    _Pack('mini', 'float16',
          'https://github.com/javierbq/protenix-mlx/releases/download/weights-mini-v1/'
          'protenix-mini-mlx-float16-v1.zip',
          '159206251babea99824110da45546707ed1428f0cf1b5a38025cc2db76f7337d',
          193_494_769),
    _Pack('mini', 'bfloat16',
          'https://github.com/javierbq/protenix-mlx/releases/download/weights-mini-v1/'
          'protenix-mini-mlx-bfloat16-v1.zip',
          '9dc3a7397d054421d1b9a64959477c927a86b56446b1f24fa642a57d4a5a8837',
          171_699_965),
    _Pack('base', 'int8',
          'https://github.com/javierbq/protenix-mlx/releases/download/weights-base-v1/'
          'protenix-base-mlx-int8-v1.zip',
          '6a405fbfb0f3b331315bc317106f22ed5daf10eb7b9b1122c4eae5db77b26977',
          224_688_268),
    _Pack('base', 'float16',
          'https://github.com/javierbq/protenix-mlx/releases/download/weights-base-v1/'
          'protenix-base-mlx-float16-v1.zip',
          'b849de70134b8b64f63274c7ec6b578b8ab83d22960d22fd76226ad76c17873d',
          468_919_887),
    _Pack('base', 'bfloat16',
          'https://github.com/javierbq/protenix-mlx/releases/download/weights-base-v1/'
          'protenix-base-mlx-bfloat16-v1.zip',
          'ee2d1d8e2070c2325eff3c2f5803ebe1266e8c182ea4e58fa14a1f6d280907e9',
          417_731_102),
    _Pack('v2', 'int8',
          'https://github.com/javierbq/protenix-mlx/releases/download/weights-v2-v1/'
          'protenix-v2-mlx-int8-v1.zip',
          '1eef8793e18be9f4a5dd040392e4358fbac1bfbf1d63dee33b7a5bc9398d4432',
          299_351_203),
    _Pack('v2', 'float16',
          'https://github.com/javierbq/protenix-mlx/releases/download/weights-v2-v1/'
          'protenix-v2-mlx-float16-v1.zip',
          '130018dec413a2c8054fa3f89c99bde7158a403b58462f5c429144098a06d860',
          610_453_479),
    _Pack('v2', 'bfloat16',
          'https://github.com/javierbq/protenix-mlx/releases/download/weights-v2-v1/'
          'protenix-v2-mlx-bfloat16-v1.zip',
          '80232df8dfb6b04db6163a6c845598d45f3bef9239f909fcd66e23688fb2c00e',
          560_585_456),
)


class ProtenixPredictor(Predictor):
    """One pack. Subclasses differ only in which -- see `_build`."""

    #: The pack this predictor folds with. Set per subclass.
    pack = None

    #: Longest input this pack may be handed. Per-variant, because v2's is measured less
    #: thoroughly and its pair track is twice as wide.
    max_residues = MAX_RESIDUES

    supports_msa = False

    # Deliberately not declared yet: the runtime computes pLDDT, PAE, PDE and resolved
    # (verified against PyTorch to 2e-4), but a per-residue array needs the metric store
    # from #308 to land in. Declaring keys with nowhere to write them would put numbers
    # in the schema that never arrive. pLDDT still reaches the viewer, in the B-factor
    # column, which is what `spectrum b` colours by.
    metric_specs = ()

    def check_available(self):
        host.require_available(self.id)
        # After require_available, because the two failures have different remedies:
        # "you are headless" versus "this build does not carry that backend". Checking
        # here is what refuses BEFORE the download rather than after it.
        host.require_runtime(self.id, RUNTIME)

    def parse_spec(self, sequence, name=''):
        chains = parse_chains(sequence)
        limit = self.max_residues
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
        if total > limit:
            raise PredictionInputError(
                '%d residues exceeds %s\'s %d-residue limit. That limit is measured, '
                'not intrinsic: peak memory is ~N^2 in tokens and reaches 8.6 GB at 700 '
                'residues, where the model\'s own confidence is 26 anyway.'
                % (total, self.id, limit))
        return PredictionSpec(chains, name)

    def submit(self, spec, options, weights_path):
        return host.submit(spec, options, weights_path, runtime=RUNTIME,
                           knobs=self.option_defaults)


def _build(pack):
    """One Predictor subclass per pack, so each is a first-class id with its own bundle."""
    recycling, diffusion = _OPERATING_POINT[pack.variant]
    identifier = 'protenix-%s-%s' % (pack.variant, _SUFFIX[pack.precision])
    label = '%s (MLX, %s)' % (_DESCRIPTION[pack.variant], pack.precision)
    if pack.variant == 'v2':
        # Said in the NAME, where a user choosing a predictor sees it, not only in a
        # comment. protenix-v2's official checkpoint has answered 403 since April 2026
        # pending a ByteDance internal review, so these packs are built from a Hugging
        # Face mirror by an uploader who states no affiliation. The file audits clean
        # structurally and is pinned by digest, but no official checksum exists for ANY
        # Protenix checkpoint, so nothing authoritative confirms the weight values.
        label += ' - mirror-sourced'
    return type(
        'Protenix%s%sPredictor' % (pack.variant.title(), _SUFFIX[pack.precision].title()),
        (ProtenixPredictor,),
        {
            'id': identifier,
            'name': label,
            'pack': pack,
            'weight_bundle': WeightBundle(
                id='protenix-%s-mlx-%s' % (pack.variant, pack.precision),
                version='v1',
                url=pack.url,
                sha256=pack.sha256,
                size=pack.size,
                # The same three members boltz2's pack has, so WeightCache needs no
                # change. config.json is not decoration: a Protenix checkpoint carries no
                # architecture at all, and the four variants share tensor NAMES while
                # differing in depth and width, so the runtime cannot tell an 8-block
                # Pairformer from a 48-block one without it.
                members=('config.json', 'manifest.json', 'model.safetensors'),
            ),
            # From this variant's own config.json. msa_depth is absent throughout, which
            # is what makes the depth lever rejected by name rather than accepted and
            # ignored: there is no alignment to have a depth.
            'max_residues': V2_MAX_RESIDUES if pack.variant == 'v2' else MAX_RESIDUES,
            'option_defaults': {'recycling_steps': recycling,
                                'diffusion_steps': diffusion,
                                'seed': 0},
            '__doc__': '%s at %s precision, %d recycles / %d diffusion steps.'
                       % (_DESCRIPTION[pack.variant], pack.precision,
                          recycling, diffusion),
        })


#: Every pack as a registered predictor, in the order they should be offered.
PREDICTORS = tuple(_build(pack) for pack in _PACKS)

#: The one to reach for. Named so `predict_weights` and documentation have something to
#: point at without hardcoding a string in three places.
DEFAULT_ID = 'protenix-base-int8'
