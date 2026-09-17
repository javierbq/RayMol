"""The sequence-designer contract: a backbone in, sequences out (#453).

A designer is handed BACKBONE COORDINATES whose residue identities are the thing being
replaced. That is neither a predictor's input (chain sequences) nor a generator's (a
target to design against, plus a length), which is why this is a third contract rather
than a flag on one of the other two -- see `designers/registry.py`.

The backbone travels as the array `raymol_design.enumerate_design_residues` already
writes, and that is deliberate: Design mode's Swift side parses exactly that shape with
`DesignResidueSet.parse`, so reusing it means ONE parser rather than two that can
disagree about which residue is index 7.
"""
import abc
import sys

from ..predictors.errors import PredictionInputError, PredictionOptionError

cmd = sys.modules['pymol.cmd']

#: MPNN's 21-letter alphabet, index 20 being X (anything the model has no letter for).
#: Here rather than in `raymol_design` because two modules now build the same array and
#: an alphabet that differs by one position silently shifts every logit column.
ALPHABET = 'ACDEFGHIKLMNPQRSTVWYX'

AA_INDEX = {letter: index for index, letter in enumerate(ALPHABET)}

#: Three-letter -> one-letter, for the residues an alphabet index exists for.
THREE_TO_ONE = {
    'ALA': 'A', 'ARG': 'R', 'ASN': 'N', 'ASP': 'D', 'CYS': 'C', 'GLN': 'Q', 'GLU': 'E',
    'GLY': 'G', 'HIS': 'H', 'ILE': 'I', 'LEU': 'L', 'LYS': 'K', 'MET': 'M', 'PHE': 'F',
    'PRO': 'P', 'SER': 'S', 'THR': 'T', 'TRP': 'W', 'TYR': 'Y', 'VAL': 'V',
}

ONE_TO_THREE = dict((one, three) for three, one in THREE_TO_ONE.items())
ONE_TO_THREE['X'] = 'UNK'

INDEX_TO_THREE = dict((index, ONE_TO_THREE.get(letter, 'UNK'))
                      for index, letter in enumerate(ALPHABET))

#: Backbone atoms a residue must have all four of to be designable. A residue missing one
#: is carried in the array with `valid: False` and no coordinates -- present, so every
#: index downstream still lines up, and unscored, so nothing invents a number for it.
BACKBONE_ATOMS = ('N', 'CA', 'C', 'O')


def read_backbone(obj, state, _self=cmd):
    """The designable residues of `obj` at `state`, in canonical order.

    `{'object', 'state', 'residues': [{chain, resi, resn, aa, valid, n, ca, c, o}]}` --
    the shape `DesignResidueSet.parse` reads at the far end. Guide atoms give one row per
    residue in (chain, resv, inscode) order, which is the order the model assigns tokens
    in and the order every position index below is resolved against; nothing may reorder,
    filter or deduplicate it.
    """
    order = []
    _self.iterate('(%s) and polymer and guide' % obj,
                  'order.append((chain, resi, resn))', space={'order': order})
    atoms = {}

    def _collect(chain, resi, name, x, y, z):
        atoms.setdefault((chain, resi), {})[name] = (x, y, z)

    _self.iterate_state(int(state), '(%s) and polymer and name N+CA+C+O' % obj,
                        '_collect(chain, resi, name, x, y, z)',
                        space={'_collect': _collect})
    residues = []
    for (chain, resi, resn) in order:
        bb = atoms.get((chain, resi), {})
        valid = all(name in bb for name in BACKBONE_ATOMS)
        residues.append({
            'chain': chain, 'resi': resi, 'resn': resn,
            'aa': AA_INDEX.get(THREE_TO_ONE.get(resn, 'X'), 20), 'valid': valid,
            'n':  list(bb['N'])  if 'N'  in bb else None,
            'ca': list(bb['CA']) if 'CA' in bb else None,
            'c':  list(bb['C'])  if 'C'  in bb else None,
            'o':  list(bb['O'])  if 'O'  in bb else None,
        })
    return {'object': str(obj), 'state': int(state), 'residues': residues}


class SequenceDesignOptions:
    """The knobs a sequence designer honours. `__slots__` so a typo is an AttributeError
    at the call site rather than an option silently ignored on the wire."""

    __slots__ = ('seed', 'temperature', 'n_sequences', 'omit')

    def __init__(self, seed=0, temperature=0.1, n_sequences=1, omit=''):
        self.seed = int(seed)
        self.temperature = float(temperature)
        self.n_sequences = int(n_sequences)
        self.omit = str(omit or '').upper()

    def as_dict(self):
        return dict((slot, getattr(self, slot)) for slot in self.__slots__)

    def __eq__(self, other):
        return isinstance(other, SequenceDesignOptions) and \
            self.as_dict() == other.as_dict()

    def __repr__(self):
        return 'SequenceDesignOptions(%s)' % ', '.join(
            '%s=%r' % (slot, getattr(self, slot)) for slot in self.__slots__)


class BackboneSpec:
    """One backbone, ready to submit: what the model sees and where the result goes.

    `chains` and `alignments` are empty and present because the shared transport writes
    both into every request -- a designer has no sequence input (the sequence is the
    OUTPUT) and nothing to align.
    """

    __slots__ = ('residues', 'name', 'designer_id', 'fixed', 'source', 'state',
                 'chains', 'alignments')

    def __init__(self, residues, name='', designer_id='', fixed=(), source='', state=1):
        self.residues = list(residues)
        self.name = str(name or '')
        self.designer_id = str(designer_id or '')
        #: POSITIONS in `residues` held at their native identity. Positions, not residue
        #: numbers, for the reason a generator's hotspots are: the model identifies a
        #: residue purely by where it is in the array it was handed.
        self.fixed = sorted(set(int(index) for index in fixed or ()))
        self.source = str(source or '')
        self.state = int(state)
        self.chains = []
        self.alignments = {}

    @property
    def n_residues(self):
        return len(self.residues)

    @property
    def n_designable(self):
        """Residues that will actually get a new letter: backbone-complete and not
        fixed. The denominator of `sequence_recovery`, and what the refusals below
        count."""
        return len([index for index, residue in enumerate(self.residues)
                    if residue.get('valid') and index not in set(self.fixed)])

    def __repr__(self):
        return 'BackboneSpec(%d residues, %d fixed, name=%r)' % (
            self.n_residues, len(self.fixed), self.name)


class SequenceDesigner(abc.ABC):
    """One inverse-folding method."""

    #: Stable selector. Appears in user scripts and saved metric records; treat as API.
    id = ''
    #: Human-readable name, for listings.
    name = ''
    #: WeightBundle or BundledSource, or None for a method whose weights ship inside the
    #: app. MPNN's do, which is why nothing here can be gated on a download.
    weight_bundle = None
    #: Option names this designer honours, mapped to defaults. Anything else is REJECTED
    #: by validate_options rather than silently ignored.
    option_defaults = {}
    #: MetricSpecs this method can produce (#308), registered under `id`.
    metric_specs = ()
    #: Pipeline phases, ordered, as (phase, start, end) bands on an overall 0..1 scale.
    progress_phases = ()

    @abc.abstractmethod
    def check_available(self):
        """Raise PredictorUnavailable unless this method can run in this process."""

    @abc.abstractmethod
    def parse_backbone(self, backbone, name='', fixed=(), source='', state=1):
        """Validate a backbone read out of the session (or out of a set entry) and
        return the BackboneSpec to submit. Every refusal here is one the backend would
        not make, or would make only after the work."""

    @abc.abstractmethod
    def submit(self, spec, options, weights_path):
        """Start the job. Returns a handle with `job_id`, `status()` and `cancel()`."""

    def validate_options(self, options):
        """`options` as a SequenceDesignOptions, rejecting any key this method does not
        declare. By NAME, because an ignored knob reads on the wire -- and in the run row
        -- as one the method honoured."""
        unknown = sorted(set(options) - set(self.option_defaults))
        if unknown:
            raise PredictionOptionError(
                '%s does not take %s; it takes: %s'
                % (self.id, ', '.join(unknown),
                   ', '.join(sorted(self.option_defaults)) or '(nothing)'))
        merged = dict(self.option_defaults)
        merged.update(options)
        return SequenceDesignOptions(**merged)

    def progress(self, status):
        """(phase, fraction) for a status dict, on this method's bands."""
        phase = str(status.get('phase') or '')
        fraction = float(status.get('fraction') or 0.0)
        for band, start, end in self.progress_phases:
            if band == phase:
                return phase, max(0.0, min(1.0, start + (end - start) * fraction))
        return phase, max(0.0, min(1.0, fraction))


def require_designable(spec, what='backbone'):
    """Refuse a backbone with nothing left to design.

    Raised here rather than at the far end because the far end's answer is an empty
    sequence, which lands as an entry that looks like a result.
    """
    if not spec.residues:
        raise PredictionInputError(
            'the %s contains no polymer residues to design' % what)
    if spec.n_designable == 0:
        raise PredictionInputError(
            'every one of the %d residues of the %s is either fixed or missing a'
            ' backbone atom, so there is nothing to design. A residue needs all of'
            ' N, CA, C and O.' % (spec.n_residues, what))
