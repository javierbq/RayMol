"""Predictor contract and input types. No I/O, no network, no PyMOL session access."""
import abc

from .errors import PredictionInputError, PredictionOptionError

#: PDB single-character chain ids, in assignment order.
CHAIN_IDS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'

#: Upper bounds for the inference knobs. Generous -- they exist to keep a value from
#: overflowing the Swift side's Int/UInt64 decode, not to express a useful range.
MAX_RECYCLING_STEPS = 100
MAX_DIFFUSION_STEPS = 10_000
MAX_SEED = 2 ** 64 - 1


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


#: A band is (phase, start, end) on an overall 0..1 scale, and a job's
#: status()['fraction'] is completion WITHIN its phase, restarting at 0 on each
#: phase change. The composition is
#:
#:     overall = start + local * (end - start)
#:
#: `end == start` -- a "zero-span" band -- means the backend reports only that
#: the phase BEGAN, not movement inside it. The composer returns the floor and
#: flags moving=False, and the UI draws an indeterminate bar plus a live elapsed
#: clock rather than a determinate one frozen at a made-up number.
#:
#: BANDS ARE LAYOUT, NOT TIME. Widths cannot track wall clock and must not be
#: read as an estimate of it: 'load' is ~10 s cold and ~0 s warm (the predictor
#: is kept alive across predictions), and boltz2's inference is 6.5 s at 60
#: residues and 675 s at 600. The bar is honest about WHICH PHASE and HOW FAR
#: THROUGH IT, never about time remaining.
#:
#: base.py names no phases on purpose: phase names belong to a backend's
#: pipeline, not to the infrastructure. See Boltz2Predictor.progress_phases.


def compose_progress(status, phases):
    """Fold one status dict into overall progress: (fraction, moving).

    fraction -- 0..1 across the whole run, or None when nothing can be said: a
                phase absent from `phases` (including 'queued', which carries no
                information at all), a missing key, or a fraction that is not a
                number. A caller holding a previous value should keep it; None
                never means zero.
    moving   -- True when the phase's band has width, so a determinate bar is
                honest. False when the backend only reports that the phase began.

    Total by construction: called from a 500 ms poll on the main thread, so it
    MUST NOT raise.
    """
    try:
        phase = status.get('phase')
        for name, start, end in phases:
            if name != phase:
                continue
            if end <= start:
                return start, False
            fraction_raw = status.get('fraction')
            if not isinstance(fraction_raw, (int, float)) or isinstance(fraction_raw, bool):
                return None, False
            local = min(max(float(fraction_raw), 0.0), 1.0)
            return start + local * (end - start), True
    except Exception:
        return None, False
    return None, False


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
        # Bounded at BOTH ends. The lower bounds are semantic; the upper bounds exist
        # because these cross a JSON wire into Swift, which decodes the steps as Int and
        # the seed as UInt64. A value that overflows there fails to decode, and an
        # undecodable request is a job that reports nothing -- so reject it here, where
        # the caller still gets a real error naming the option.
        if not 0 <= recycling_steps <= MAX_RECYCLING_STEPS:
            raise PredictionOptionError(
                'recycling_steps must be between 0 and %d' % MAX_RECYCLING_STEPS)
        if not 1 <= diffusion_steps <= MAX_DIFFUSION_STEPS:
            raise PredictionOptionError(
                'diffusion_steps must be between 1 and %d' % MAX_DIFFUSION_STEPS)
        if not 0 <= seed <= MAX_SEED:
            raise PredictionOptionError('seed must be between 0 and %d' % MAX_SEED)
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

    #: This predictor's pipeline phases, ordered, as (phase, start, end) bands.
    #: EMPTY BY DEFAULT on purpose: the base class makes no claim about anyone's
    #: pipeline. A predictor that declares nothing gets an indeterminate card with
    #: a live elapsed clock -- the correct rendering of no information, and far
    #: better than a bar derived from some other backend's phase names.
    progress_phases = ()

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

    def progress(self, status):
        """Overall progress for one of this predictor's jobs: (fraction, moving).

        CONCRETE, like validate_options -- never abstract. This class is a public
        extension point and a new @abc.abstractmethod would break every predictor
        already written against it. That also makes this the escape hatch: a
        backend the band table cannot express overrides this method instead.

        `status` is exactly what job.status() returned. This DERIVES from it and
        never stores a second copy, so status()['fraction'] stays the single
        source of truth and the two cannot drift.

        Never raises.
        """
        return compose_progress(status, self.progress_phases)
