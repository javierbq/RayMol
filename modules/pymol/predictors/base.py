"""Predictor contract and input types. No I/O, no network, no PyMOL session access."""
import abc

from .errors import PredictionInputError, PredictionOptionError

#: PDB single-character chain ids, in assignment order.
CHAIN_IDS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'


def parse_chains(sequence):
    """'MKTAY/GSHMA' -> (('A', 'MKTAY'), ('B', 'GSHMA')).

    '/' is the chain separator, not ',': commas are what parsing.parse_arg splits
    the command line on, so a comma-separated list never reaches this function.
    Whitespace is stripped and residues upper-cased. Validation of which residue
    letters are acceptable belongs to the predictor, not here.
    """
    if not isinstance(sequence, str):
        raise PredictionInputError('sequence must be a string')
    parts = [''.join(p.split()).upper() for p in sequence.split('/')]
    if not parts or any(not p for p in parts):
        raise PredictionInputError(
            'empty chain in sequence; use "SEQ1/SEQ2" for a multimer')
    if len(parts) > len(CHAIN_IDS):
        raise PredictionInputError(
            'at most %d chains supported, got %d' % (len(CHAIN_IDS), len(parts)))
    return tuple(zip(CHAIN_IDS, parts))


class PredictionOptions:
    """Inference knobs. Defaults are upstream Boltz's, not the MLX port's.

    The port's own defaults (recycling 0, diffusion 20) FAIL its own quality gate
    at 3.19 A / 0.685 lDDT against a 2.0 A / 0.90 bar, so they are not used.
    step_scale is deliberately absent: it comes from the model artifact's
    config.json and is not a per-call knob.
    """

    __slots__ = ('recycling_steps', 'diffusion_steps', 'seed')

    def __init__(self, recycling_steps=3, diffusion_steps=200, seed=0):
        for name, value in (('recycling_steps', recycling_steps),
                            ('diffusion_steps', diffusion_steps),
                            ('seed', seed)):
            if not isinstance(value, int) or isinstance(value, bool):
                raise PredictionOptionError('%s must be an integer' % name)
        if recycling_steps < 0:
            raise PredictionOptionError('recycling_steps must be >= 0')
        if diffusion_steps < 1:
            raise PredictionOptionError('diffusion_steps must be >= 1')
        if seed < 0:
            raise PredictionOptionError('seed must be >= 0')
        self.recycling_steps = recycling_steps
        self.diffusion_steps = diffusion_steps
        self.seed = seed

    def as_dict(self):
        return {name: getattr(self, name) for name in self.__slots__}

    def __eq__(self, other):
        return isinstance(other, PredictionOptions) and \
            self.as_dict() == other.as_dict()

    def __repr__(self):
        return 'PredictionOptions(%s)' % ', '.join(
            '%s=%r' % kv for kv in sorted(self.as_dict().items()))


class PredictionSpec:
    """Validated, predictor-agnostic description of what to fold."""

    __slots__ = ('chains', 'name')

    def __init__(self, chains, name=''):
        self.chains = tuple(chains)
        self.name = name

    @property
    def total_residues(self):
        return sum(len(seq) for _, seq in self.chains)

    def __repr__(self):
        return 'PredictionSpec(chains=%r, name=%r)' % (self.chains, self.name)


class Predictor(abc.ABC):
    """One structure-prediction method.

    Callers depend only on this interface, so predictors are swappable without
    touching call sites.
    """

    #: Stable selector. Appears in user scripts; treat as API and never change it.
    id = None
    #: Human-readable name, for listings.
    name = None
    #: WeightBundle or BundledSource, or None if the method needs no weights.
    weight_bundle = None
    #: Option names this predictor honours, mapped to defaults. Anything else is
    #: REJECTED by validate_options rather than silently ignored.
    option_defaults = {'recycling_steps': 3, 'diffusion_steps': 200, 'seed': 0}

    @abc.abstractmethod
    def check_available(self):
        """Raise PredictorUnavailable if this cannot run here and now.

        Check platform, OS floor, host presence. Do NOT check whether weights are
        cached: that is the weight manager's job, and it is allowed to fix it.
        """

    @abc.abstractmethod
    def parse_spec(self, sequence, name=''):
        """Return a PredictionSpec, or raise PredictionInputError.

        Reject unsupported input loudly here rather than letting the backend
        silently drop residues it does not understand.
        """

    @abc.abstractmethod
    def submit(self, spec, options, weights_path):
        """Start the run and return a job handle immediately. MUST NOT BLOCK."""

    def validate_options(self, options):
        """Merge caller options over the defaults, rejecting unknown names."""
        unknown = set(options) - set(self.option_defaults)
        if unknown:
            raise PredictionOptionError(
                '%s does not support: %s' % (self.id, ', '.join(sorted(unknown))))
        merged = dict(self.option_defaults)
        merged.update(options)
        return PredictionOptions(**merged)
