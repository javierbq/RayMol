"""RFdiffusion3 via rfd3-mlx: on-device backbone generation in Swift/MLX.

The first method in RayMol that GENERATES a chain instead of folding one. Given a target
structure and the interface residues to engage, it runs an all-atom EDM diffusion rollout
and returns a new backbone -- with a sequence, because RFdiffusion3 carries a sequence
head, which is what makes a design usable on its own rather than only as input to an
inverse-folding pass.

**What comes back is a DESIGNED BACKBONE, and the word "binder" is not used for it
anywhere.** Not a style preference: generation alone does not establish that the chain
binds anything. Confirming that needs a refold of the pair and an interface gate, neither
of which exists in RayMol yet. A measured run from the port's own benchmarking makes the
point concretely -- a design scoring min_ipSAE 0.70 had its chain docked 15.6 A from the
reference pose. The scalar passed it; the pose is what failed.

WHAT IT MEASURES, AND WHAT IT DOES NOT. The sampler has no confidence module, so this
declares geometry only (see `generators/metrics.py`): bond-length sanity, compactness,
interface distance, hotspot distance, and the target's drift from where it was supplied.
That last one is a CONTRACT check rather than a quality score -- the target is held fixed,
so it reads 0.000 A on a correct run.

TARGET IS ONE CHAIN, CANONICAL RESIDUES ONLY, AND THAT IS ENFORCED HERE. The engine's
featurizer gives every target residue the same `asym_id` and numbers them contiguously,
and its PDB reader silently drops anything outside the standard twenty; a target it
cannot represent therefore produces a confident design against a structure the user did
not select. Every one of those cases is refused by name below, before a 625 MB download.

MEASURED COST. On an M3 Pro, fp32, 200 diffusion steps x 2 recycles, against full human
serum albumin (578 target residues + a 60-residue design = 638 tokens): seven designs
took 821-1321 s, median 1001 s -- about 17 minutes EACH. Target drift 0.000 A, 98.3% of
backbone bonds in range, interface 3.0 A. A small target is far cheaper (the port's
standalone 50-mer generation is 15.5 s at the same schedule), so the cost is dominated by
the target, quadratically. That is why `n_designs` is capped and why the progress tray and
a working cancel are not polish here.
"""
from .base import (CHAIN_ID_POOL, DesignSpec, Generator, STANDARD_AA3,
                   require_single_chain)
from .metrics import DESIGN_SPECS
from ..predictors import host
from ..predictors.errors import PredictionInputError
from ..predictors.weights import WeightBundle

#: The backend the Swift host must dispatch to, as it appears on the wire. Not optional
#: at the far end in the sense that matters: a request with NO runtime key is read as
#: `boltz`, so a generator that forgot to send this would be handed to Boltz's featurizer
#: -- which would not fail, it would fold the empty chain list.
RUNTIME = 'rfd3'

#: Ceiling on target residues + designed residues, and it is a TIME bound, not a memory
#: one. The memory refusal is exact and lives at the far end: `RFD3Budget` fits a
#: measured quadratic to this machine's own physical memory and refuses before any GPU
#: work (see RFD3SizeGuard). Duplicating those coefficients here would give two guards
#: that drift, and the Python one has no way to know the machine's budget anyway.
#:
#: So this number answers a different question: where does one design stop being worth
#: waiting for. 638 tokens is 17 minutes on an M3 Pro (see the module docstring), and
#: peak cost grows quadratically in atom count, so 700 is roughly a 20-minute design and
#: the last point close to something measured. Above it the honest answer is to shrink
#: the target selection -- a target residue is 5-8 atoms against a designed residue's 14,
#: so the target is where the tokens are.
MAX_TOKENS = 700

#: Ceiling on the designed chain. A designed residue costs exactly 14 dense atom slots
#: against a target residue's ~4.9 (backbone + CB) to ~7.8 (all-atom), so length is 2-3x
#: more expensive per residue than target size and is the axis that runs out first.
#:
#: 150 rather than 60, and 60 is the only length measured END TO END -- nine designs, all
#: docked, 97.6% of bonds in range. That makes this a foot-gun bound rather than a
#: measured ceiling, and it is set where it is because the exact memory refusal at the far
#: end is a real refusal rather than a crash: an over-large design is rejected precisely,
#: by a guard that knows the machine, instead of being guessed at here.
MAX_DESIGN_LENGTH = 150

#: Ceiling on designs per command. Each is a FULL independent rollout -- there is no
#: shared trunk to amortise -- so ten designs against a 638-token target is roughly three
#: hours. Ten rather than one because a single design is not a result: the port's own
#: benchmark discarded one of ten seeds as a runaway outlier, and picking among samples is
#: the whole workflow this is a stage of.
MAX_DESIGNS = 10

#: Fewest hotspots worth conditioning on. The featurizer derives the sampler's ORIGIN
#: from the hotspot centre of mass, offset 10 A along the core-to-hotspot normal, so
#: hotspots decide where the design is placed and not merely how it is scored. With none
#: at all the origin collapses to the target's centre of mass and the atom-level hotspot
#: feature is uniformly zero -- a legitimate unconditioned mode, but not this one, and
#: silently substituting it for what was asked would produce a design aimed nowhere.
MIN_HOTSPOTS = 1


class RFD3Generator(Generator):

    id = 'rfd3'
    name = 'RFdiffusion3 (MLX, fp32)'

    #: sha256 and size are of the published zip's BYTES, re-read from the release asset
    #: after upload rather than from the local file that was uploaded -- the digest that
    #: matters is the one a user's download produces.
    #:
    #: fp32, and that is the only precision offered because it is the only one the Swift
    #: engine has a matmul path for. int8 measures near-lossless on these weights (coord
    #: RMSD 0.06-0.09 A, 97.5-100% sequence agreement, 9/9 designs docked) and is 3.5x
    #: smaller, but it needs `linear()` extended at the far end first -- and its
    #: large-system latency is bimodal, with two of nine runs spiking to 2030 s and
    #: 6979 s against a 389 s median, so it is not a free win either.
    weight_bundle = WeightBundle(
        id='rfd3-mlx-fp32',
        version='v1',
        url='https://github.com/javierbq/rfd3-mlx/releases/download/weights-rfd3-v1/'
            'rfd3-mlx-fp32-v1.zip',
        sha256='27d36afedb13e45ec91482273fd9710e8f14692112f49f06598e128a2f0bf4a6',
        size=625_244_028,
        # The pack's own layout, not this cache's convention: RFD3Kit reads
        # `manifest.json` (format 2, which carries required weight provenance) and
        # `rfd3_core.safetensors` from the directory it is handed. Asserted after
        # extraction, because a partially-extracted pack fails on the sha256 inside the
        # pack rather than on the missing file, which is a much worse error to read.
        members=('manifest.json', 'rfd3_core.safetensors'),
    )

    #: Upstream RFdiffusion3's production schedule. `recycling_steps` is the engine's
    #: `nRecycle` and `diffusion_steps` its `numTimesteps`. Recycling 1 saves about 20%
    #: and is not offered as a default: it can jump the trajectory into a different valid
    #: basin, which is a different design rather than the same design computed faster.
    #:
    #: No `msa_depth`, and none is accepted: there is no alignment. Rejecting it by name
    #: is the point -- see DesignOptions.
    option_defaults = {'recycling_steps': 2, 'diffusion_steps': 200, 'seed': 0}

    metric_specs = DESIGN_SPECS

    #: 'diffusion' owns almost the whole bar because it genuinely does: featurization is
    #: pure CPU array assembly and the pack load is a one-time safetensors read, while
    #: the rollout is 200 steps x 2 recycles of an 18-block transformer. The runtime
    #: reports a step count per denoising step, so this band is real motion rather than
    #: a guess.
    #:
    #: The weight fetch is absent for the reason boltz2 gives: its own card owns that
    #: window, and including it would leave every warm-cache run -- which is every run
    #: after the first -- starting part-way along.
    progress_phases = (
        ('featurize', 0.00, 0.02),
        ('load',      0.02, 0.06),
        ('diffusion', 0.06, 0.96),
        ('write',     0.96, 1.00),
        ('done',      1.00, 1.00),
    )

    def check_available(self):
        host.require_available(self.id)
        # After require_available, because the two failures have different remedies:
        # "you are running headless" versus "this build of RayMol does not carry that
        # backend". Checking here is also what refuses BEFORE a 625 MB download rather
        # than after it -- and it is the whole iOS story, since the iOS build advertises
        # `boltz` alone, so no platform test is needed to keep this off a phone.
        host.require_runtime(self.id, RUNTIME)

    def parse_target(self, target, length, name=''):
        """Validate a target the command layer read out of the session.

        Everything here is a refusal the backend would NOT make. Its PDB reader returns
        success having dropped what it did not understand, so a target containing a
        ligand, a selenomethionine or a second chain yields a design against a different
        structure than the one selected -- and nothing in the result says so.
        """
        residues = target.residues
        if not residues:
            raise PredictionInputError(
                'the target selection contains no standard amino-acid residues that'
                ' this method can read. It takes protein only, from ATOM records: a'
                ' ligand, a nucleic acid, a modified residue or a HETATM-only'
                ' selection leaves nothing to design against.')
        require_single_chain(residues)

        # Insertion codes need no special handling, and that is a consequence of shipping
        # the residue array rather than PDB text: `resi` keeps its code, and the
        # featurizer identifies residues by their POSITION in the array and never reads a
        # residue number at all. Routed through RFD3Kit's own PDB reader instead, 45 and
        # 45A would have merged into one residue holding both sets of atoms.
        #
        # A residue whose atoms are not contiguous in the session arrives as two entries,
        # because the reader groups by adjacency. Detected by identity rather than trusted.
        seen = {}
        for index, residue in enumerate(residues):
            key = (residue.chain, residue.resi)
            if key in seen:
                raise PredictionInputError(
                    'residue %s/%s appears twice in the target as written (positions'
                    ' %d and %d). The engine groups atoms into residues by adjacency,'
                    ' so an interleaved residue becomes two -- which changes the target'
                    ' length and every residue index after it. Try "create" on the'
                    ' selection first, or sort the atoms.'
                    % (residue.chain, residue.resi, seen[key] + 1, index + 1))
            seen[key] = index
            # Belt-and-braces: parse_target_pdb already filters to STANDARD_AA3, so
            # reaching this is a bug in the reader rather than a user error. Refused
            # anyway, because the alternative is a residue with no atom template that
            # the featurizer skips with no diagnostic.
            if residue.resn not in STANDARD_AA3:
                raise PredictionInputError(
                    'residue %s/%s is %s, which this method carries no atom template'
                    ' for' % (residue.chain, residue.resi, residue.resn))

        if len(target.hotspots) < MIN_HOTSPOTS:
            raise PredictionInputError(
                'no hotspot residues were resolved inside the target. Hotspots are'
                ' required rather than optional: they set the sampler origin, so'
                ' without them the design is aimed at the target\'s centre of mass'
                ' instead of at an interface. Name the interface residues, e.g.'
                ' hotspots="chain A and resi 45+48+52".')
        for index in target.hotspots:
            if not 0 <= index < len(residues):
                raise PredictionInputError(
                    'hotspot index %d is outside the %d-residue target'
                    % (index, len(residues)))

        length = int(length)
        if not 1 <= length <= MAX_DESIGN_LENGTH:
            raise PredictionInputError(
                'length must be between 1 and %d residues, got %d. A designed residue'
                ' costs 14 atom slots against a target residue\'s 5-8, so length is the'
                ' axis that runs out of memory first; the exact limit for this machine'
                ' is applied by the runtime, which refuses before touching the GPU.'
                % (MAX_DESIGN_LENGTH, length))

        tokens = len(residues) + length
        if tokens > MAX_TOKENS:
            raise PredictionInputError(
                '%d target residues plus a %d-residue design is %d tokens, over the'
                ' %d-token limit. That limit is about TIME, not memory: 638 tokens is'
                ' about 17 minutes per design on an M3 Pro and the cost is quadratic,'
                ' so this is roughly a 20-minute design. Shrink the target -- it is'
                ' where the tokens are.'
                % (len(residues), length, tokens, MAX_TOKENS))

        return DesignSpec(target, length, name=name, generator_id=self.id,
                          design_chain=_free_chain_id(residues))

    def submit(self, spec, options, weights_path):
        # The target travels INLINE, as data, and both halves of that are deliberate.
        #
        # Inline rather than as a path, unlike an alignment: an a3m is megabytes and is
        # streamed at the far end, while a target is bounded by MAX_TOKENS at a few hundred
        # kilobytes -- nothing to either json.dumps here or one read there -- and inlining
        # removes a temp file whose lifetime would have to be reasoned about against a
        # reader on another thread.
        #
        # As a residue ARRAY rather than PDB text, because a second parse is a second
        # chance to disagree. RFD3Kit's own `designBinder(targetPDB:)` does not even design
        # against the PDB it is given -- it routes through `autoTarget`, which substitutes
        # its own most-compact 95-residue window and its own three hotspots. Shipping the
        # array means the residues the user selected are the residues the model sees, in
        # the order the hotspot indices are resolved against.
        return host.submit(
            spec, options, weights_path, runtime=RUNTIME,
            knobs=self.option_defaults,
            extra={
                'target': spec.target_wire(),
                # Positions in `target`, resolved once on this side. See
                # TargetStructure.hotspots for why a residue number here would be wrong.
                'hotspots': list(spec.target.hotspots),
                'design_length': spec.length,
                'design_chain': spec.design_chain,
                # Carried so the runtime can stamp it into the metric document it writes,
                # which is what makes a design's identity travel with its numbers rather
                # than being re-derived by whoever reads them later.
                'design_key': spec.design_key(
                    options, weights_version=_bundle_version(self)),
            })


def _free_chain_id(residues):
    """A chain id for the generated chain that the target does not already use.

    'B' unless the target is chain B, which is the common case and reads the way RFD3Kit's
    own output does. The object holds only the target and the design, so "free" is decided
    entirely by the target -- no session lookup, which matters because this is computed
    before the object exists.
    """
    used = set(residue.chain for residue in residues)
    for candidate in CHAIN_ID_POOL:
        if candidate not in used:
            return candidate
    # Unreachable while a target is one chain, which `require_single_chain` enforces.
    # Raised rather than defaulted, because a design sharing the target's chain id would
    # merge with it on load and nothing afterwards could tell them apart.
    raise PredictionInputError(
        'no free chain id is left for the generated chain (target uses %s)'
        % ', '.join(sorted(used)))


def _bundle_version(generator):
    """`<bundle id> <version>` for the pack that will run, or '' for a method with none.

    Part of the design key because it is the thing most likely to differ between two
    runs that otherwise look identical -- the same target, hotspots, length and seed
    against a different weight pack is a different design.
    """
    bundle = generator.weight_bundle
    if bundle is None:
        return ''
    return ('%s %s' % (bundle.id, getattr(bundle, 'version', ''))).strip()
