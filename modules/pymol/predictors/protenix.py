"""Protenix via protenix-mlx: ByteDance's AlphaFold3-class predictor, in Swift/MLX.

Six packs: the base and v2 variants at three precisions each, every one a separate
predictor id. That is the `boltz2` / `boltz2-bf16` pattern -- one runtime, many tools --
and it works for the same reason: `host.submit` sends `weights_dir` per job and the Swift
side picks its matmul path from the artifact manifest, so a dense pack needs no code.

**tiny and mini are published but NOT offered here.** They are v0.5.0 models trained to 4
recycles / 5 diffusion steps, and five steps does not converge the geometry: at a fixed
seed tiny gives CA-CA distances of 3.26 A against base's 3.67 and an ideal 3.80, which is
loose enough that DSSP stops calling helices and the cartoon breaks into segments. They
are fast -- 11 s against base's 35 -- but a fold nobody should trust is not worth 11
seconds either, and offering it invites exactly that. protenix-mlx still builds and
publishes them; add them back here if a use appears that wants speed over geometry.

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
is measured most thoroughly. v2 scores highest on a short probe but is mirror-sourced and
measured least. The dense precisions cost roughly twice the disk and more memory for no
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
#:                60 res   250 res   400 res   550 res   700 res   900 res
#:     base          547      2279      3868      6303      8622     16513
#:     v2            738      2777      5914      9068        --        --
#:
#: v2 is now swept too, and the gap is what the shape of the two networks predicts: its
#: pair track is 256 wide against base's 128, and it costs 35% more at 60 residues and
#: 53% more at 400. Sizing a v2 fold from base's row would have been optimistic at every
#: single length -- which is why the row existed as a placeholder until it could be run,
#: rather than being interpolated from the row above it.
#:
#: Variants converge as the input grows: the now-unshipped tiny and mini measured 3494 and
#: 3625 MiB at 400 residues against base's 3868, within 10% of each other, because the
#: N^2 pair representation dwarfs the weights. That is why the cap is driven by sequence
#: length rather than scaled by parameter count -- what decides whether a fold fits is how
#: long it is, not which pack runs it.
MEASURED_PEAK_MIB = {
    'base': ((60, 547), (120, 942), (250, 2279), (400, 3868), (550, 6303), (700, 8622),
             (900, 16513)),
    # Swept with scripts/protenix_memory_sweep.py, at the same lengths as base so the two
    # rows are comparable point for point. The run's control -- the same harness against
    # base at 60 and 120 -- reproduced base's committed numbers to within 3.5%, which is
    # what licenses reading this row alongside that one; a v2 row from a harness that
    # cannot reproduce base would be evidence about the harness.
    #
    # The single (15, 509) point this replaces was never wrong, only lonely.
    'v2': ((60, 738), (120, 1649), (250, 2777), (400, 5914), (550, 9068)),
}

#: Hard ceiling, in residues, across every variant except v2.
#:
#: The largest length actually MEASURED (700 for base, at 8.6 GB and six minutes). It was
#: 400 -- chosen because a fold whose own confidence is 26 is rarely worth six minutes --
#: and was raised deliberately, since that is a judgement for whoever is waiting.
#:
#: 900 residues IS measured and does fit -- 16.1 GiB, half the 32 GB budget -- and the cap
#: still sits below it, for a reason that only measuring found: it took **2.5 hours**.
#: That is 24x the wall clock of 700 residues for 1.3x the length, because at 16 GiB on a
#: 32 GiB machine the fold stops being compute-bound and starts paging. The model's own
#: confidence there is 26.4, so it is two and a half hours for a structure that says
#: nothing can be concluded from it.
#:
#: So the ceiling is no longer "where the data runs out" but "where the time stops being
#: worth it", which is a judgement -- raise it to 900 if you want the option and can leave
#: a machine to it. Beyond 900 nothing has been run at all.
#:
#: The memory budget (ProtenixSizeGuard.budgetBytes, 32 GB) is the other half of the
#: policy: on a 32 GiB machine that is effectively all of it, so a long fold and an
#: unsaved session are a bad combination.
MAX_RESIDUES = 700

#: v2's own ceiling: the largest length it has actually been RUN at, the same rule
#: MAX_RESIDUES follows.
#:
#: It was 250, and 250 was never a measurement -- v2 had been swept at one point, 15
#: residues, and 250 was picked to sit well inside what had been run because base's curve
#: understates v2 rather than overstating it. The sweep exists now (#316,
#: scripts/protenix_memory_sweep.py), so this is data again: 550 residues peaks at 9068 MiB
#: and takes 497 s on an M1 Max / 32 GiB.
#:
#: **700 was attempted and abandoned, which is why this is not 700.** It is the same
#: wall base hit at 900 and for the same reason: 550 finishes in 8 minutes, and 700 was
#: still running past 20 with the machine 15 GB into swap -- superlinear in exactly the
#: way a fold looks when it stops being compute-bound and starts paging. Its peak is
#: therefore unknown, and an unknown peak is not a ceiling. Whoever wants 700 can measure
#: it: leave the machine to it, and this constant follows the number.
#:
#: Still its own constant rather than merged into MAX_RESIDUES, because v2 costs 44%
#: more memory than base at the same length -- the two ceilings are independent, and the
#: next one to move will move for one variant and not the other.
V2_MAX_RESIDUES = 550

#: Why a variant's ceiling sits where it does, when that ceiling is NOT itself one of the
#: points in MEASURED_PEAK_MIB. Keyed by variant; a variant absent from here has a cap the
#: sweep actually reached, and `_limit_rationale` reads the reason off the table instead
#: of out of prose. Data rather than an if-branch so that the day v2 is swept properly,
#: deleting its entry is the whole change.
#:
#: Empty, and that is the goal state rather than an oversight: every variant offered here
#: is now capped at a length it has been run at. It stays because the branch it feeds
#: does -- a variant added without a sweep, or a ceiling set above one, has to say so
#: rather than borrow the word "measured" from a neighbour.
_UNMEASURED_CAP_REASON = {}


def _limit_rationale(variant, limit):
    """Why THIS variant refuses at THIS length, in its own measured numbers.

    The refusal this feeds used to quote base's 700 residues / 8.6 GB / confidence 26 no
    matter which pack raised it, which told a v2 user three facts about a pack they were
    not running and implied v2's 250 was a memory measurement. It is not one: v2 has been
    swept at a single point, 15 residues. A refusal that misreports its own evidence is
    worse than a terse one, because the reader's next move -- accept a hard memory wall,
    or go measure -- is exactly the thing the wrong numbers decide for them.

    Two branches, chosen by the data and not by the variant name: if the cap is at or
    below the largest length this variant has actually been run at, it IS a measurement,
    and the peak at that length is quoted. If the cap sits above the sweep, it is a
    placeholder, and the message says so along with how far the sweep really got.
    """
    points = MEASURED_PEAK_MIB.get(variant) or ()
    if not points:
        return ("That limit is a conservative placeholder: no memory sweep exists for "
                "this pack at all, so nothing here is known either to fit or not to.")
    measured_to, peak_mib = points[-1]
    if limit <= measured_to:
        at_cap = [point for point in points if point[0] <= limit][-1]
        return ("That limit is measured, not intrinsic: peak memory is ~N^2 in tokens, "
                "and this pack's own sweep reaches %.1f GiB at %d residues. Single-"
                "sequence confidence is ~26 from 400 residues up, so folding longer is "
                "rarely worth the wait even where it fits."
                % (at_cap[1] / 1024.0, at_cap[0]))
    return ("That limit is a conservative placeholder rather than a measured ceiling: "
            "this pack has only been swept up to %d residues (%d MiB peak)%s. Guessing "
            "past measured data is how a fold gets SIGKILLed mid-run instead of cleanly "
            "refused, so the cap sits well inside what has been run until a real sweep "
            "raises it -- see MEASURED_PEAK_MIB. %s is measured to %d residues if you "
            "need the length now."
            % (measured_to, peak_mib,
               ', and ' + _UNMEASURED_CAP_REASON[variant]
               if variant in _UNMEASURED_CAP_REASON else '',
               DEFAULT_ID, MAX_RESIDUES))


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
    'base': (10, 200),
    'v2': (10, 200),
}

_DESCRIPTION = {
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
            # The rationale comes from THIS pack's row of MEASURED_PEAK_MIB rather than
            # from a sentence about base's sweep -- see `_limit_rationale`.
            raise PredictionInputError(
                '%d residues exceeds %s\'s %d-residue limit. %s'
                % (total, self.id, limit,
                   _limit_rationale(self.pack.variant if self.pack else None, limit)))
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

#: Shorthand -> real id. `protenix` is not itself a registered id -- see _SUFFIX above
#: for why no id may be a prefix of another -- but it is a convenient thing to type at
#: a prompt, so registry.get() resolves it without registry.available() ever offering
#: it. Points at v2, not DEFAULT_ID: base is still the thoroughly-measured, non-mirror
#: choice for a script that wants that explicitly, but the bare shorthand is worth
#: keeping pointed at whichever pack should get a plain `predict protenix, ...` today.
ALIASES = {'protenix': 'protenix-v2-int8'}
