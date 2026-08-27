"""Generator contract and input types. No I/O, no network, no PyMOL session access.

A GENERATOR is not a predictor, and the difference is the whole reason this module
exists beside `pymol.predictors` rather than inside it. Every predictor maps chain
SEQUENCES to a structure: `PredictionSpec(chains, name, alignments)` is the input, and
`parse_spec(sequence)` is how it is built. A generator is handed a target STRUCTURE --
coordinates, plus the residues at the interface it should engage -- and returns a chain
that did not exist. There is no sequence to put in `chains`, so `Predictor` is the wrong
base class and `predict` is the wrong verb.

What IS shared is reused rather than forked, because none of it is sequence-shaped:
`predictors.weights` (bundles and the cache), `predictors.fetching` (the non-blocking
weight fetch), `predictors.host` (the request/status file transport) and
`predictors.metrics` (the shared metric spec sets) are all method-agnostic. Only the
spec, the contract and the command surface are new.

NAMING. A generated chain is a DESIGNED BACKBONE, never a "binder". Nothing here has
generated an interface until the design has been refolded and passed an interface gate,
neither of which happens in this package -- so the word is not earned yet, and using it
early is a claim about a measurement nobody made. The Swift package this drives calls
its own API `designBinder`; that is upstream's choice, and the boundary where it stops
is here.
"""
import abc
import hashlib
import re

from ..predictors.base import (MAX_DIFFUSION_STEPS, MAX_RECYCLING_STEPS, MAX_SEED,
                               compose_progress)
from ..predictors.errors import PredictionInputError, PredictionOptionError

#: Residues the target may be built from. The engine's featurizer carries dense atom
#: templates for exactly these -- anything else is DROPPED by its PDB reader with no
#: diagnostic, which is why `parse_target` refuses rather than trusting it. Three-letter
#: codes, because that is what a PDB record carries and what the templates are keyed by.
STANDARD_AA3 = frozenset((
    'ALA', 'ARG', 'ASN', 'ASP', 'CYS', 'GLN', 'GLU', 'GLY', 'HIS', 'ILE',
    'LEU', 'LYS', 'MET', 'PHE', 'PRO', 'SER', 'THR', 'TRP', 'TYR', 'VAL'))

#: Hex digits of the design key. Sixteen, not eight: this key is what a later refold is
#: matched against, and two DIFFERENT designs colliding would attribute one design's
#: refold to the other -- a wrong number rather than a name clash. Widen, never narrow.
DESIGN_KEY_DIGEST_CHARS = 16


#: Chain ids a generated chain may be given, in preference order. 'B' first because the
#: object is a two-chain complex and that is how RFD3Kit's own output reads; the rest exist
#: so a target that IS chain B still gets a free id rather than one that merges with it.
CHAIN_ID_POOL = 'BCDEFGHIJKLMNOPQRSTUVWXYZA'

#: Alternate-location indicators a target is built from: the blank one, and 'A'. Everything
#: else is a second modelled conformer of the same atom, and the engine has one slot per atom
#: name.
KEPT_ALTLOCS = frozenset(('', 'A'))


class TargetResidue:
    """One residue of the target: its identity in the session, and its atoms.

    Read straight out of the session -- never round-tripped through PDB text. That is a
    correctness decision, not a convenience. RFD3Kit offers a `designBinder(targetPDB:)`
    entry point, and it does NOT design against the PDB you give it: it routes through
    `autoTarget`, which picks its own most-compact 95-residue window and its own three
    hotspots and designs against that instead. And its PDB reader keys residues on
    (chain, resSeq, resName) without reading the insertion code, so residues 45 and 45A
    would merge into one residue holding both sets of atoms.

    Building the residue array here and shipping it as data avoids both: there is exactly
    one parse, on this side, and `resi` keeps its insertion code because nothing at the
    far end re-derives it (the featurizer uses array ORDER and ignores chain and resSeq
    entirely).
    """

    __slots__ = ('chain', 'resi', 'resn', 'atoms')

    def __init__(self, chain, resi, resn, atoms=()):
        self.chain = chain
        #: PyMOL's residue identifier, insertion code included, as a str -- because
        #: PyMOL's is, and insertion codes are real.
        self.resi = str(resi)
        self.resn = resn
        #: [(atom name, (x, y, z))], in session order. Heavy atoms only; the engine's
        #: dense templates are keyed by heavy-atom name, and an atom it has no slot for
        #: is ignored rather than being an error.
        self.atoms = list(atoms)

    def as_wire(self):
        """This residue as the far end decodes it."""
        return {'chain': self.chain, 'resi': self.resi, 'resn': self.resn,
                'atoms': [{'name': name, 'xyz': [float(x), float(y), float(z)]}
                          for name, (x, y, z) in self.atoms]}

    def __repr__(self):
        return 'TargetResidue(%s/%s %s, %d atoms)' % (
            self.chain, self.resi, self.resn, len(self.atoms))


class TargetStructure:
    """The target a design is generated against: coordinates in, nothing derived.

    Built by the command layer from a selection -- that is the only part of this package
    that touches the session -- and validated by the generator.
    """

    __slots__ = ('residues', 'hotspots', 'source', 'state')

    def __init__(self, residues, hotspots, source='', state=1):
        self.residues = tuple(residues)
        #: Indices INTO `residues` of the interface residues the design should engage.
        #:
        #: Indices, not residue numbers, and the distinction is a silent-wrong-answer
        #: away: the featurizer tests `hotspots.contains(i)` against the position of each
        #: residue in the array it was handed, and never looks at `resSeq` at all. A
        #: hotspot given as residue number 45 would condition the design on the 46th
        #: residue of the target. Resolved from identifiers exactly once, by
        #: `designing._resolve_hotspots`, against the array shipped beside them.
        self.hotspots = tuple(sorted(set(int(index) for index in hotspots)))
        #: What the user named, for provenance. Never re-read: everything downstream
        #: must see the residues resolved at submit time, not whatever the session
        #: holds minutes later.
        self.source = source
        #: Which state the coordinates came from. Part of the identity: state 3 of an
        #: NMR ensemble is a different target from state 1.
        self.state = int(state)

    @property
    def n_residues(self):
        return len(self.residues)

    def __repr__(self):
        return 'TargetStructure(%d residues, %d hotspots, source=%r)' % (
            len(self.residues), len(self.hotspots), self.source)


class DesignOptions:
    """Sampler knobs for one design.

    Deliberately NOT `predictors.base.PredictionOptions`, whose slots include
    `msa_depth`. A generator has no alignment, so carrying a depth would put a number
    in every run's provenance saying an alignment was read at some depth when none
    exists -- the same failure `Predictor.supports_msa` refuses by name.

    The names are the shared ones on purpose: `diffusion_steps` IS the engine's
    `numTimesteps` and `recycling_steps` IS its `nRecycle`, so the wire keys, the
    command arguments and the two backends' vocabularies all line up, and a user who
    knows `predict` needs no second mental model.
    """

    __slots__ = ('recycling_steps', 'diffusion_steps', 'seed')

    def __init__(self, recycling_steps=2, diffusion_steps=200, seed=0):
        for name, value in (('recycling_steps', recycling_steps),
                            ('diffusion_steps', diffusion_steps),
                            ('seed', seed)):
            if not isinstance(value, int) or isinstance(value, bool):
                raise PredictionOptionError('%s must be an integer' % name)
        # Bounded at both ends, and the LOWER bounds here are not the predictors'.
        # RFdiffusion3 divides by (numTimesteps - 1) in its EDM schedule, so one step
        # returns all-NaN coordinates rather than a fast answer, and a zero-recycle
        # pass never runs the trunk at all. The upper bounds exist because these cross
        # a JSON wire into a Swift Int/UInt64 decode.
        if not 1 <= recycling_steps <= MAX_RECYCLING_STEPS:
            raise PredictionOptionError(
                'recycling_steps must be between 1 and %d' % MAX_RECYCLING_STEPS)
        if not 2 <= diffusion_steps <= MAX_DIFFUSION_STEPS:
            raise PredictionOptionError(
                'diffusion_steps must be between 2 and %d (one step divides by zero'
                ' in the diffusion schedule and returns NaN coordinates)'
                % MAX_DIFFUSION_STEPS)
        if not 0 <= seed <= MAX_SEED:
            raise PredictionOptionError('seed must be between 0 and %d' % MAX_SEED)
        self.recycling_steps = recycling_steps
        self.diffusion_steps = diffusion_steps
        self.seed = seed

    def as_dict(self):
        return {name: getattr(self, name) for name in self.__slots__}

    def __eq__(self, other):
        return isinstance(other, DesignOptions) and self.as_dict() == other.as_dict()

    def __repr__(self):
        return 'DesignOptions(%s)' % ', '.join(
            '%s=%r' % kv for kv in sorted(self.as_dict().items()))


class DesignSpec:
    """Validated, generator-agnostic description of one design to generate.

    Shaped so `predictors.host.submit` can ship it unchanged: `chains` is empty and
    `alignments` is empty, which is the honest answer for a method whose input is not a
    sequence, and `name` is the object the result lands in. The structural half travels
    as `extra` (see `rfd3.py`), which is the one addition the shared transport needed.
    """

    __slots__ = ('target', 'length', 'name', 'generator_id', 'design_chain', 'live_view',
                 'live_interval', 'keep_frames')

    def __init__(self, target, length, name='', generator_id='', design_chain='B',
                 live_view=False, live_interval=None, keep_frames=False):
        self.target = target
        self.length = int(length)
        self.name = name
        self.generator_id = generator_id
        #: Chain id the generated chain gets in the emitted object. Chosen HERE rather
        #: than at the far end, because "free" is a fact about the target: the object is
        #: the target plus the design, so any id the target does not use will do, and the
        #: runtime has no reason to re-derive it. Recorded as a metric, because computing
        #: refold-vs-design RMSD later means knowing which chain the design is.
        self.design_chain = design_chain
        #: Stream the rollout's coordinates so the run can be watched. PRESENTATION only:
        #: it changes nothing about the design, which is why it is not a sampler knob and
        #: is deliberately absent from `design_key` -- the same design watched and unwatched
        #: is the same design and must key the same.
        self.live_view = bool(live_view)
        #: Capture every Nth rollout step in the live recording, or None for the
        #: runtime's default. The INTERVAL rather than the frame count the user asked
        #: for: `designing.capture_interval` turns one into the other at submit time, on
        #: this side, so the achievable count can be reported before the run starts and
        #: the runtime needs no arithmetic of its own -- one derivation, one place.
        #: PRESENTATION only for the same reason `live_view` is, and absent from
        #: `design_key` for the same reason: watching a design at 12 states or at 50 does
        #: not make it a different design, and two runs differing only here must key the
        #: same and produce the same bytes.
        #:
        #: The `int()` is a live guard, not decoration: `design_backbone` builds every
        #: per-design copy through this constructor rather than patching the attribute
        #: afterwards, so this is the one path the value takes.
        self.live_interval = None if live_interval is None else int(live_interval)
        #: Keep the live view's captured frames as states of the finished object.
        #: PRESENTATION only, and absent from `design_key` for the same reason the other
        #: two are: whether the rollout's frames are kept does not change what the design
        #: IS, and two runs differing only here must key the same and produce the same
        #: bytes. Off by default -- watching is the point, the states are opt-in.
        self.keep_frames = bool(keep_frames)

    #: No sequence input. Present because the shared transport writes `spec.chains` into
    #: every request; an empty list is what a generator genuinely has, and the far end's
    #: `chains` is a `[Chain]` that decodes fine when empty.
    chains = ()

    #: No alignments, ever. A generator has nothing to align: the target's own sequence
    #: is a fixed condition rather than something being folded, and the designed chain
    #: has no homologs by construction.
    alignments = {}

    @property
    def total_residues(self):
        """Residues in the object this produces: the target, plus the designed chain.

        Both, because the object IS both -- the target is emitted beside the design and
        held fixed, which is what makes the pair a refold's input without re-deriving it.
        """
        return self.target.n_residues + self.length

    def hotspot_ids(self):
        """The hotspots as (chain, resi) identifiers -- for humans, not for the engine.

        The wire carries INDICES (see TargetStructure.hotspots). These are what a message,
        a metric record and the design key use, because an index into an array nobody else
        can see says nothing to a reader, while `A/45` is the thing the user selected.
        """
        return [{'chain': self.target.residues[index].chain,
                 'resi': self.target.residues[index].resi}
                for index in self.target.hotspots]

    def target_wire(self):
        """The target as the runtime decodes it: one entry per residue, in order.

        ORDER IS THE CONTRACT. The featurizer assigns tokens in exactly this order and
        resolves hotspots as positions in it, so nothing may reorder, filter or deduplicate
        this list downstream. It is already filtered to the residues the engine has
        templates for -- see `rfd3.parse_target` -- which is what keeps the featurizer's own
        skip-a-residue-it-cannot-template branch from firing and shifting every later index.
        """
        return [residue.as_wire() for residue in self.target.residues]

    def design_key(self, options, weights_version=''):
        """A stable identity for this design: what a later refold is keyed to.

        Everything that changes the coordinates goes in, and nothing that does not.
        The point is stated in the negative: given a refolded complex, its own metric
        record carries this key, so `refold-vs-design` RMSD is computable without
        guessing which of a session's designs a prediction came from. A key that
        omitted the seed, or the target's state, or which weight pack ran, would
        collide two designs that are not the same design.

        The target enters as its RESIDUE IDENTITIES and coordinates rather than as the
        PDB text, so a cosmetic difference in the file -- atom serial numbers, a
        different writer -- does not change the identity of the same target.
        """
        digest = hashlib.sha256()
        for part in (self.generator_id, weights_version, str(self.length),
                     self.design_chain, str(self.target.state), str(options.seed),
                     str(options.diffusion_steps), str(options.recycling_steps)):
            digest.update(part.encode('utf-8'))
            digest.update(b'\x00')
        for residue in self.target.residues:
            digest.update(('%s|%s|%s|' % (residue.chain, residue.resi,
                                          residue.resn)).encode('utf-8'))
            for name, (x, y, z) in residue.atoms:
                digest.update(('%s%.3f,%.3f,%.3f;' % (name, x, y, z)).encode('utf-8'))
        digest.update(b'\x00hotspots\x00')
        for entry in self.hotspot_ids():
            digest.update(('%s|%s;' % (entry['chain'], entry['resi'])).encode('utf-8'))
        return digest.hexdigest()[:DESIGN_KEY_DIGEST_CHARS]

    def __repr__(self):
        return 'DesignSpec(target=%r, length=%d, name=%r)' % (
            self.target, self.length, self.name)


class Generator(abc.ABC):
    """One backbone-generation method.

    The mirror of `predictors.base.Predictor`, and deliberately not a subclass of it:
    `parse_spec(sequence)` and `bind_alignments` have no meaning here, and inheriting
    them would put two methods on every generator whose only correct implementation is
    to raise.
    """

    #: Stable selector. Appears in user scripts and saved metric records; treat as API.
    id = None
    #: Human-readable name, for listings.
    name = None
    #: WeightBundle or BundledSource, or None for a method that needs no weights.
    weight_bundle = None
    #: Option names this generator honours, mapped to defaults. Anything else is
    #: REJECTED by validate_options rather than silently ignored.
    option_defaults = {'recycling_steps': 2, 'diffusion_steps': 200, 'seed': 0}
    #: MetricSpecs this method can produce (#308), registered under `id`.
    metric_specs = ()
    #: This generator's pipeline phases, ordered, as (phase, start, end) bands on an
    #: overall 0..1 scale. Empty means an indeterminate card with a live clock, which
    #: is the correct rendering of no information.
    progress_phases = ()

    @abc.abstractmethod
    def check_available(self):
        """Raise PredictorUnavailable if this cannot run here and now.

        Platform, OS floor, host presence, and whether the build carries this method's
        Swift runtime. NOT weight state: the weight manager is allowed to fix that by
        downloading, and refusing here is what avoids a several-hundred-megabyte
        download for a method that could never have run.
        """

    @abc.abstractmethod
    def parse_target(self, target, length, name=''):
        """Return a DesignSpec, or raise PredictionInputError.

        `target` is a TargetStructure the command layer already read out of the session.
        Reject here anything the backend would accept and quietly reinterpret -- a
        second chain, a ligand, a residue it has no template for. The engine's own
        reader drops what it does not understand and returns success, so catching that
        is this method's job.
        """

    @abc.abstractmethod
    def submit(self, spec, options, weights_path):
        """Start the run and return a job handle immediately. MUST NOT BLOCK.

        `cmd.design_backbone` is reachable from the console, which runs on the main
        thread; the app drains PyMOL's feedback buffer from a main-run-loop timer, so a
        blocked main thread cannot even deliver the messages describing why it is
        blocked.
        """

    def validate_options(self, options):
        """Merge caller options over the defaults, rejecting unknown names."""
        unknown = set(options) - set(self.option_defaults)
        if unknown:
            raise PredictionOptionError(
                '%s does not support: %s' % (self.id, ', '.join(sorted(unknown))))
        merged = dict(self.option_defaults)
        merged.update(options)
        return DesignOptions(**merged)

    def progress(self, status):
        """Overall progress for one of this generator's jobs: (fraction, moving).

        Concrete, never abstract, for the reason `Predictor.progress` is: this class is
        a public extension point and a new abstract method would break every generator
        already written against it. Never raises -- it is called from a 500 ms poll on
        the main thread.
        """
        return compose_progress(status, self.progress_phases)


#: A hotspot argument is a selection expression, so this is only used to reject the one
#: shape a user is most likely to try instead: a bare `+`-separated residue list, which
#: is not a selection and would select nothing.
_BARE_RESIDUE_LIST = re.compile(r'^\s*\d+[A-Za-z]?(\s*\+\s*\d+[A-Za-z]?)*\s*$')


def looks_like_bare_residue_list(text):
    """True for '45' or '45+48+52' -- valid inside `resi ...`, not on its own."""
    return bool(_BARE_RESIDUE_LIST.match(str(text or '')))


def require_single_chain(residues, what='target'):
    """Raise unless every residue is in one chain.

    NOT a limitation of this package. The engine's featurizer assigns EVERY target
    residue the same `asym_id` and numbers them contiguously in `residue_index`, so a
    two-chain target is presented to the network as one continuous chain with a peptide
    bond where the chain break is. That does not fail; it designs against a target that
    does not exist, which is the failure mode this whole layer refuses by name.
    """
    chains = []
    for residue in residues:
        if residue.chain not in chains:
            chains.append(residue.chain)
    if len(chains) > 1:
        raise PredictionInputError(
            'the %s spans %d chains (%s), and this method can only take one. Its'
            ' featurizer gives every target residue the same chain and numbers them'
            ' contiguously, so a two-chain target would be presented to the network as'
            ' one continuous chain -- joined by a peptide bond that is not there. Pick'
            ' one chain, e.g. "%s and chain %s".'
            % (what, len(chains), ', '.join(chains), what, chains[0]))
    return chains[0] if chains else ''
