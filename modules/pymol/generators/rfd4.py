"""RFD4-Proteina via rfd4-proteina-mlx: on-device backbone generation in Swift/MLX.

The second backbone generator in RayMol, beside `rfd3`, and a different kind of model
rather than a newer version of the same one. RFdiffusion3 is an all-atom EDM DIFFUSION
rollout that holds the target fixed; RFD4-Proteina is a FLOW-MATCHING model that
generates sequence and structure jointly, and it generates the target too.

**What comes back is a DESIGNED BACKBONE, and nothing that names or describes it calls
it a "binder"** -- object names, metric keys, metric labels, status lines. The naming
split is `generators/base`'s and applies here unchanged: the TOOL is Binder Design and
its command is `binder_design`, which is a claim about what the method is FOR and is
true; the OUTPUT is a designed backbone until a refold and an interface gate say
otherwise, neither of which happens in this package.

THE TARGET IS GENERATED, NOT HELD FIXED, AND THAT CHANGES WHAT THE NUMBERS MEAN. This is
the one thing to carry over from `rfd3` with the sign flipped. There, the target is
masked out of the noise and reproduced atom-for-atom, so `target_drift_max` is a CONTRACT
check that reads 0.000 A on a correct run. Here the target is entered as a coordinate
group that is centred and RANDOMLY ROTATED on the way in, and the model must place it --
so the generated complex arrives in an arbitrary frame, a small rebuild error is the
expected result, and there is no drift to measure. The engine superposes the rebuilt
target back onto the supplied one and carries the design through the same motion, and
`target_rebuild_rmsd` reports how faithfully the conditioning was honoured. It is a
separate metric key from RFD3's for exactly this reason (see `generators/metrics`).

GAPS IN THE TARGET ARE HANDLED, AND THIS IS THE REAL DIFFERENCE IN PRACTICE. The engine
splits the target wherever the backbone is not bonded -- decided from the C(i)-N(i+1)
distance rather than from residue numbering -- and emits each stretch as its own contig
segment with its own chain id. A target with an unmodelled loop is therefore designed
against correctly instead of being asked to bond across the gap. Nothing is required of
the caller for this, which is why there is no option for it.

WHAT IT MEASURES, AND WHAT IT DOES NOT. There is no confidence head in this model, so
this declares geometry only: bond-length sanity, compactness, interface distance, hotspot
distance, and the target rebuild RMSD above. A design that passes every one of them is
geometrically sane, which is not designable and is certainly not a binder.

MEASURED QUALITY. A 100-design campaign against HSA 190-339, validated with Boltz-MLX as
the oracle, gave 87/100 designable (median scRMSD 0.59 A, with NO ProteinMPNN redesign)
and 35/100 through all four gates. That is the number that justifies shipping this at
all; it is not a per-design guarantee, and picking among samples is still the workflow.

MEASURED COST. The released schedule is 60 flow steps, and `thinking_medium` runs 180
trunk passes over them. Peak memory is quadratic in TOKEN count -- tokens being target
residues plus designed residues, since one token is one residue here rather than one
atom -- and at fp16 it is 6.62 GB at 638 tokens against 13.24 GB at fp32. fp16 is what
ships and what `RFD4SizeGuard` is denominated in.
"""
from .base import (CHAIN_ID_POOL, DesignSpec, Generator, STANDARD_AA3,
                   require_single_chain)
from .metrics import RFD4_DESIGN_SPECS
from ..predictors import host
from ..predictors.errors import PredictionInputError
from ..predictors.weights import WeightBundle

#: The backend the Swift host must dispatch to, as it appears on the wire. Kept in step
#: with `RFD4JobManager.runtimeName` and with what `PyMOLBridge` advertises in
#: `RAYMOL_PREDICT_RUNTIMES`. Not optional in the sense that matters: a request with NO
#: runtime key is read as `boltz`, so a generator that forgot this would be handed to
#: Boltz's featurizer -- which would not fail, it would fold the empty chain list.
RUNTIME = 'rfd4'

#: Flow steps in the released schedule. FIXED, not a knob: every released `thinking`
#: strategy is defined over a 60-step trajectory (`ReleasedRecycleStrategy.nsteps`), and
#: the recycle bands are indexed against those 60 steps. Changing it would not make the
#: model think longer, it would misalign the bands.
RELEASED_FLOW_STEPS = 60

#: Ceiling on target residues + designed residues, and it is a MEMORY bound here, unlike
#: rfd3's, where the same constant is about time.
#:
#: The exact refusal still lives at the far end -- `RFD4SizeGuard` fits the measured fp16
#: curve to THIS machine's physical memory and refuses before any GPU work. This number
#: is the point past which the curve itself stops being measured: the fit was taken over
#: 256-638 tokens, 638 is 6.62 GB at fp16, and extrapolating a quadratic past its last
#: measured point to decide whether a process survives is not a guard, it is a guess.
#:
#: Above it the honest answer is to shrink the target selection, which is where the
#: tokens are: one target residue is one token exactly as one designed residue is.
MAX_TOKENS = 700

#: Ceiling on the designed chain. A foot-gun bound rather than a measured ceiling, and
#: lower than rfd3's 150 for a reason that is specific to this model: the 100-design
#: campaign that establishes the quality number above ran 60-80 residue designs, so
#: beyond roughly that range there is no evidence about what comes out -- only about
#: whether it fits. The exact memory refusal at the far end is a real refusal rather than
#: a crash, so this does not have to be the memory limit as well.
MAX_DESIGN_LENGTH = 150

#: Ceiling on designs per command. Each is a FULL independent trajectory -- there is no
#: shared trunk to amortise -- and a single design is not a result: the campaign that
#: measures this model discards most samples at the gates, so picking among them is the
#: workflow this is one stage of.
MAX_DESIGNS = 10

#: Largest number of disjoint backbone stretches the target may break into.
#:
#: The engine gives every stretch its own input chain id, out of 'B'..'Z', because its
#: contig parser refuses two runs claiming the same chain -- so a target assembled out of
#: many disconnected pieces runs out of letters. Refused here BY NAME so the message is
#: about the selection rather than about letters, and `RFD4Design.targetChainIDs.count`
#: is the same 25 at the far end.
MAX_TARGET_SEGMENTS = 25

#: Columns a PDB ATOM record gives each identifier: one for the chain id (column 22),
#: four for the residue sequence number (23-26), one for the insertion code (27).
PDB_CHAIN_WIDTH = 1
PDB_RESI_WIDTH = 4


def _split_resi(resi):
    """`resi` as (numeric part, insertion code), neither of them clipped.

    The twin of `RFD4ResultWriter.splitResi`, and a SECOND implementation rather than a
    shared one because there is no Python->Swift call path: the choice is between
    checking here and not checking here. Drift is bounded -- the Swift side refuses on
    its own terms -- so the worst a disagreement costs is a design that fails late
    rather than one refused early, never a silent truncation.
    """
    digits, rest = '', ''
    for character in str(resi):
        if not rest and (character.isdigit() or (not digits and character == '-')):
            digits += character
        else:
            rest += character
    return (digits or '0'), rest


def _require_pdb_representable(chain, resi):
    """Refuse a target identifier the result could only come back from as something else.

    The result crosses back from the runtime as PDB TEXT, and the PDB is a fixed-column
    format whose writer keeps the SUFFIX of anything too long. So chain `AA` returns as
    `A`, residue `10000` as `0000`, and `-1000` as `1000` -- a different residue, and in
    the last case a different sign -- in an object the user is told holds their target
    exactly as it was.

    Refused HERE, before the weight download and before the GPU, because the whole value
    of catching it is catching it early. `RFD4ResultWriter` refuses again on its own
    terms; this is the friendly half of the same rule, not the only half.
    """
    if len(str(chain)) > PDB_CHAIN_WIDTH:
        raise PredictionInputError(
            'chain %r cannot be written to the PDB\'s single chain-id column, so the'
            ' target would be reloaded as chain %r -- a different chain, silently. The'
            ' result crosses back as PDB text, which is why this is a limit at all.'
            ' Rename the chain, or select one whose id is a single character.'
            % (str(chain), str(chain)[:PDB_CHAIN_WIDTH]))
    number, insertion = _split_resi(resi)
    if len(number) > PDB_RESI_WIDTH or len(insertion) > 1:
        raise PredictionInputError(
            'residue number %r does not fit the PDB\'s four-column residue field (plus'
            ' one for an insertion code), so the target would come back renumbered --'
            ' and the numbering is what the hotspot selection was written in. Renumber'
            ' the target with "alter ... resi=..." and design against that.'
            % (str(resi),))


class RFD4Generator(Generator):

    id = 'rfd4'
    name = 'RFD4-Proteina (MLX, fp16)'

    #: sha256 and size are of the published zip's BYTES, re-read from the release asset
    #: after upload rather than from the local file that was uploaded -- the digest that
    #: matters is the one a user's download produces. Verified identical to the local
    #: build on 2026-11-17.
    #:
    #: fp16, and that is the only precision offered. It is not a compromise: the port's
    #: own validation (`validation/quality/fp16.md`) measures it against fp32 and it is
    #: the default there too, which halves both the download and the peak memory --
    #: 6.62 GB against 13.24 GB at 638 tokens. int8 would be roughly another 1.9x
    #: smaller but needs an exporter and a quantized matmul path that do not exist, and
    #: the pack refuses a `quantization` block for precisely that reason rather than
    #: running dense matmuls over packed integers and producing noise.
    weight_bundle = WeightBundle(
        id='rfd4-proteina-mlx-fp16',
        version='v1',
        url='https://github.com/javierbq/rfd4-proteina-mlx/releases/download/'
            'weights-rfd4-v1/rfd4-proteina-mlx-fp16-v1.zip',
        sha256='c07d977c0c130f7760256f93787f73efde699e17cb526ec6ef935f5d8047a03d',
        size=807_122_869,
        # The pack's own layout, not this cache's convention: the Swift side reads
        # `manifest.json` (which pins a per-file sha256, the precision, and the
        # vocabulary snapshot) and `rfd4_core.safetensors` from the directory it is
        # handed. Asserted after extraction, because a partially-extracted pack
        # otherwise fails on the sha256 INSIDE the pack rather than on the missing
        # file, which is a much worse error to read.
        members=('manifest.json', 'rfd4_core.safetensors'),
    )

    #: THE SEED IS THE ONLY KNOB, and the two that are missing are missing on purpose.
    #:
    #: `diffusion_steps` has no meaning here. The released schedule is 60 flow steps and
    #: the `thinking` recycle bands are indexed against those 60; a different count would
    #: not be a longer run, it would be a misaligned one.
    #:
    #: `recycling_steps` has no scalar form. `thinking_medium` runs depths 6, 5, 4, 3, 2
    #: and 1 across six bands of the trajectory -- 180 trunk passes in all -- so there is
    #: no single number that describes it, and offering one would mean inventing a
    #: setting the engine does not have.
    #:
    #: Declaring them anyway and ignoring them is the option this deliberately does not
    #: take: `validate_options` rejects an undeclared name, so a user who passes
    #: `diffusion_steps=200` is told it is unsupported instead of watching it change
    #: nothing. Exposing the `thinking` level is the real follow-up, and it needs a slot
    #: on `DesignOptions` -- shared code -- because it changes the coordinates and so
    #: must enter `design_key`, which a per-generator attribute could not do.
    option_defaults = {'seed': 0}

    metric_specs = RFD4_DESIGN_SPECS

    #: `sample` owns almost the whole bar because it genuinely does: featurization is
    #: CPU array assembly and the pack load is a one-time safetensors read, while the
    #: rollout is 60 flow steps carrying 180 trunk passes. The runtime reports a step
    #: count per flow step, so this band is real motion rather than a guess.
    #:
    #: The weight fetch is absent for the reason boltz2 and rfd3 give: its own card owns
    #: that window, and including it would leave every warm-cache run -- which is every
    #: run after the first -- starting part-way along.
    progress_phases = (
        ('featurize', 0.00, 0.02),
        ('load',      0.02, 0.06),
        ('sample',    0.06, 0.96),
        ('write',     0.96, 1.00),
        ('done',      1.00, 1.00),
    )

    def check_available(self):
        host.require_available(self.id)
        # After require_available, because the two failures have different remedies:
        # "you are running headless" versus "this build of RayMol does not carry that
        # backend". Checking here is also what refuses BEFORE an 807 MB download rather
        # than after it -- and it is the whole iOS story, since the iOS build advertises
        # `boltz` alone, so no platform test is needed to keep this off a phone.
        host.require_runtime(self.id, RUNTIME)

    def parse_target(self, target, length, name=''):
        """Validate a target the command layer read out of the session.

        Everything here is a refusal the engine would NOT make. Its featurizer skips a
        residue it has no atom template for while the hotspot positions keep counting, so
        one unreadable residue silently shifts which residues the design is aimed at; and
        it designs happily against an empty target.
        """
        residues = target.residues
        if not residues:
            raise PredictionInputError(
                'the target selection contains no standard amino-acid residues that'
                ' this method can read. It takes protein only, from ATOM records: a'
                ' ligand, a nucleic acid, a modified residue or a HETATM-only'
                ' selection leaves nothing to design against.')

        # ONE CHAIN, and unlike rfd3 this is RayMol's restriction rather than the
        # engine's. RFD4's contig can express several target chains -- it already emits
        # one per disconnected backbone stretch -- but the splitting is decided from
        # BACKBONE GEOMETRY at the far end, not from chain ids, so two chains packed
        # against each other could be joined into one segment with a peptide bond that
        # is not there. Lifting this means splitting by chain on the way in, which is a
        # change to the engine's `RFD4Design.runs` rather than to this file.
        require_single_chain(residues)

        # Insertion codes need no special handling here, and that is a consequence of
        # shipping the residue ARRAY rather than PDB text: `resi` keeps its code, and
        # the engine identifies residues by their POSITION in the array and never reads
        # a residue number at all. Routed through a PDB reader instead, 45 and 45A would
        # have merged into one residue holding both sets of atoms.
        #
        # A residue whose atoms are not contiguous in the session arrives as two
        # entries, because the reader groups by adjacency. Detected rather than trusted.
        seen = {}
        for index, residue in enumerate(residues):
            key = (residue.chain, residue.resi)
            if key in seen:
                raise PredictionInputError(
                    'residue %s/%s appears twice in the target as written (positions'
                    ' %d and %d). Atoms are grouped into residues by adjacency, so an'
                    ' interleaved residue becomes two -- which changes the target length'
                    ' and every residue index after it. Try "create" on the selection'
                    ' first, or sort the atoms.'
                    % (residue.chain, residue.resi, seen[key] + 1, index + 1))
            seen[key] = index
            # Belt-and-braces: the command layer already filters to STANDARD_AA3, so
            # reaching this is a bug in the reader rather than a user error. Refused
            # anyway, because the alternative is a residue with no atom template that
            # the featurizer skips with no diagnostic.
            if residue.resn not in STANDARD_AA3:
                raise PredictionInputError(
                    'residue %s/%s is %s, which this method carries no atom template'
                    ' for' % (residue.chain, residue.resi, residue.resn))
            _require_pdb_representable(residue.chain, residue.resi)

        # An EMPTY hotspot set reaches the engine unchanged: unguided placement is a
        # mode the featurizer supports directly. Only the indices that ARE present are
        # bounds-checked -- an out-of-range one is a wire bug, and the featurizer would
        # silently condition on the wrong residue.
        for index in target.hotspots:
            if not 0 <= index < len(residues):
                raise PredictionInputError(
                    'hotspot index %d is outside the %d-residue target'
                    % (index, len(residues)))

        length = int(length)
        if not 1 <= length <= MAX_DESIGN_LENGTH:
            raise PredictionInputError(
                'length must be between 1 and %d residues, got %d. The exact memory'
                ' limit for this machine is applied by the runtime, which refuses'
                ' before touching the GPU; this bound is about where the model has been'
                ' measured, and the campaign behind it ran 60-80 residue designs.'
                % (MAX_DESIGN_LENGTH, length))

        tokens = len(residues) + length
        if tokens > MAX_TOKENS:
            raise PredictionInputError(
                '%d target residues plus a %d-residue design is %d tokens, over the'
                ' %d-token limit. One residue is one token here, target or designed, so'
                ' shrinking the target selection is what buys room. The limit is where'
                ' the measured memory curve stops: it was fitted over 256-638 tokens,'
                ' and extrapolating it further to decide whether the process survives'
                ' would be a guess rather than a guard.'
                % (len(residues), length, tokens, MAX_TOKENS))

        segments = _count_backbone_segments(residues)
        if segments > MAX_TARGET_SEGMENTS:
            raise PredictionInputError(
                'the target breaks into %d separate backbone stretches, over the %d'
                ' this can express. Each gap in the backbone becomes its own contig'
                ' segment with its own chain id, so a selection assembled from many'
                ' disjoint pieces runs out of letters. Select a more contiguous region.'
                % (segments, MAX_TARGET_SEGMENTS))

        return DesignSpec(target, length, name=name, generator_id=self.id,
                          design_chain=_free_chain_id(residues))

    def submit(self, spec, options, weights_path):
        # The target travels INLINE, as data, and both halves of that are deliberate.
        #
        # Inline rather than as a path, unlike an alignment: a target is bounded by
        # MAX_TOKENS at a few hundred kilobytes -- nothing to either json.dumps here or
        # read there -- and inlining removes a temp file whose lifetime would have to be
        # reasoned about against a reader on another thread.
        #
        # As a residue ARRAY rather than PDB text, because a second parse is a second
        # chance to disagree about which residues the user picked. It also keeps
        # insertion codes, which no contig grammar can express and which a PDB
        # round-trip through the engine would collapse.
        extra = {
            'target': spec.target_wire(),
            # Positions in `target`, resolved once on this side. See
            # TargetStructure.hotspots for why a residue number here would be wrong.
            'hotspots': list(spec.target.hotspots),
            'design_length': spec.length,
            'design_chain': spec.design_chain,
            # Carried so the runtime can stamp it into the metric document and into the
            # structure's own REMARKs, which is what makes a design's identity travel
            # with its numbers rather than being re-derived by whoever reads them later.
            'design_key': spec.design_key(
                options, weights_version=_bundle_version(self)),
            # DECODER COMPATIBILITY, not settings. `InferenceJob.Request` decodes both of
            # these as non-optional Ints, so the request will not parse without them --
            # but neither is a knob this method has (see `option_defaults`), and
            # `RFD4JobManager` ignores both in favour of the released schedule.
            #
            # `diffusion_steps` is sent as the count the run ACTUALLY performs, so a
            # reader of the raw request is not misled. `recycling_steps` is sent as 1
            # rather than a plausible-looking number precisely so that nobody reads it
            # as a setting: this model's recycling is a per-band schedule, and no scalar
            # describes it.
            'diffusion_steps': RELEASED_FLOW_STEPS,
            'recycling_steps': 1,
        }
        # NO `live_view`. The live path needs per-step COORDINATES, and this engine's
        # step hook reports only (step, trunk passes) -- there is nothing to draw. Adding
        # it means a new hook in the port, not a flag here, so the key is absent rather
        # than present-and-false: absent is what every request that cannot be watched
        # says, and the runtime's default is off.
        return host.submit(spec, options, weights_path, runtime=RUNTIME,
                           knobs=tuple(self.option_defaults), extra=extra)


def _count_backbone_segments(residues):
    """How many disjoint backbone stretches `residues` breaks into.

    The twin of `RFD4Design.runs`, and deliberately the same RULE rather than the same
    code: a stretch continues only where a real peptide bond is present, decided from the
    C(i)-N(i+1) distance, and a missing C or N reads as a BREAK because a residue whose
    backbone is incomplete is in no position to vouch for a bond.

    It exists here only to turn "the contig ran out of chain ids" into a message about
    the SELECTION, early, before an 807 MB download. The far end decides the real layout
    and refuses on its own terms; a disagreement between the two costs a design that
    fails late rather than one refused early.
    """
    # Upstream's own bond criterion, in Angstrom. Generous on purpose: this is asking
    # "are these two residues connected at all", not "is this bond ideal", and a strained
    # junction in a real structure must not read as a chain break.
    polymerization_limit = 2.0
    atoms = []
    for residue in residues:
        by_name = {name: xyz for name, xyz in residue.atoms}
        atoms.append((by_name.get('C'), by_name.get('N')))
    segments = 1
    for index in range(len(atoms) - 1):
        carbon = atoms[index][0]
        nitrogen = atoms[index + 1][1]
        if carbon is None or nitrogen is None:
            segments += 1
            continue
        distance = sum((a - b) ** 2 for a, b in zip(carbon, nitrogen)) ** 0.5
        if distance > polymerization_limit:
            segments += 1
    return segments


def _free_chain_id(residues):
    """A chain id for the generated chain that the target does not already use.

    'B' unless the target is chain B, which is the common case and reads the way the
    engine's own CLI output does. The object holds only the target and the design, so
    "free" is decided entirely by the target -- no session lookup, which matters because
    this is computed before the object exists.
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

    Part of the design key because it is the thing most likely to differ between two runs
    that otherwise look identical -- the same target, hotspots, length and seed against a
    different weight pack is a different design.
    """
    bundle = generator.weight_bundle
    if bundle is None:
        return ''
    return ('%s %s' % (bundle.id, getattr(bundle, 'version', ''))).strip()
