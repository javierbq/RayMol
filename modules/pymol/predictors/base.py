"""Predictor contract and input types. No I/O, no network, no PyMOL session access."""
import abc
import math

from .errors import PredictionInputError, PredictionOptionError

#: PDB single-character chain ids, in assignment order.
CHAIN_IDS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'

#: Upper bounds for the inference knobs. Generous -- they exist to keep a value from
#: overflowing the Swift side's Int/UInt64 decode, not to express a useful range.
MAX_RECYCLING_STEPS = 100
MAX_DIFFUSION_STEPS = 10_000
MAX_SEED = 2 ** 64 - 1

#: Most alignment rows a prediction may use. boltz-mlx's `BoltzInputLimits.desktop`
#: `maximumSequences`, which is upstream's `const.max_msa_seqs`. Both ends must agree:
#: the Swift side passes this to `MSAAlignment.a3m(maximumSequences:)`, so a value
#: above it would be silently ignored there rather than honoured.
MAX_MSA_DEPTH = 16384


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
            local = float(fraction_raw)
            # BEFORE the clamp, never by it: min(max(nan, 0.0), 1.0) is still nan,
            # because every comparison with NaN is False. A NaN reaching the caller
            # poisons the monotone floor forever and writes `NaN` into the panel
            # JSON, which is not valid JSON and fails the whole payload decode.
            if not math.isfinite(local):
                return None, False
            local = min(max(local, 0.0), 1.0)
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

    __slots__ = ('recycling_steps', 'diffusion_steps', 'seed', 'msa_depth')

    def __init__(self, recycling_steps=3, diffusion_steps=200, seed=0,
                 msa_depth=MAX_MSA_DEPTH):
        for name, value in (('recycling_steps', recycling_steps),
                            ('diffusion_steps', diffusion_steps),
                            ('seed', seed),
                            ('msa_depth', msa_depth)):
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
        # Not clamped. A depth above the ceiling is silently ignored by the parser that
        # eventually reads it, so accepting one would report a run using more of the
        # alignment than it actually did -- and depth is the single largest determinant
        # of both runtime and peak memory, so that is not a harmless overstatement.
        if not 1 <= msa_depth <= MAX_MSA_DEPTH:
            raise PredictionOptionError(
                'msa_depth must be between 1 and %d' % MAX_MSA_DEPTH)
        self.recycling_steps = recycling_steps
        self.diffusion_steps = diffusion_steps
        self.seed = seed
        self.msa_depth = msa_depth

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

    __slots__ = ('chains', 'name', 'alignments')

    def __init__(self, chains, name='', alignments=None):
        self.chains = tuple(chains)
        self.name = name
        # chain id -> pymol.msas.store.MSA, for the chains that have one. PARTIAL BY
        # DESIGN: a chain with no entry is folded single-sequence, which is exactly the
        # designed-binder case -- a real alignment for the target, none for the binder.
        # Empty rather than None so every caller can iterate it without a guard.
        self.alignments = dict(alignments or {})

    @property
    def total_residues(self):
        return sum(len(seq) for _, seq in self.chains)

    def __repr__(self):
        return 'PredictionSpec(chains=%r, name=%r, alignments=%r)' % (
            self.chains, self.name, sorted(self.alignments))


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
    #: True only if this method can GENUINELY use a multiple-sequence alignment.
    #:
    #: Default False, so a predictor that cannot is rejected BY NAME. Accepting an
    #: alignment and folding single-sequence anyway produces a worse structure with
    #: nothing in the output saying so -- the same failure mode validate_options()
    #: already exists to prevent for the inference knobs. A method that supports MSAs
    #: also wants `msa_depth` in its option_defaults; without it the depth lever is
    #: rejected by name, which is correct for a method that has no depth to lever.
    supports_msa = False

    #: MetricSpecs this method can produce (#308). Registered under `id` when the
    #: predictor is, so a run's numbers arrive with a scope, units and a range, and the
    #: panel, `metrics_color` and export can handle a method they have never heard of.
    #:
    #: Declare only what this method GENUINELY measures. `pymol.predictors.metrics`
    #: carries the shared sets; a method with no confidence module must not declare
    #: `plddt`, for the same reason it must not claim `supports_msa`: a caller that
    #: finds a key in the schema is entitled to conclude the tool can produce it.
    metric_specs = ()

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

    def bind_alignments(self, spec, alignments):
        """Attach {chain_id: MSA} to `spec` and return it, or raise.

        `alignments` is keyed by the spec's own chain ids ('A', 'B', ...) and may cover
        only some of them; the rest are folded single-sequence. Each value is a
        pymol.msas.store.MSA -- anything with `name`, `query` and `depth` will do.

        The base implementation enforces the two things that are true of every method:
        it refuses outright unless `supports_msa`, and it refuses an alignment whose
        query is not exactly the sequence of the chain it is bound to. Both are checked
        HERE, before submit, because the alternative is a half-gigabyte weight download
        and minutes of featurization before the backend says the same thing.

        Override to add a method's own constraints, then call super().
        """
        alignments = dict(alignments or {})
        if not alignments:
            spec.alignments = {}
            return spec
        if not self.supports_msa:
            raise PredictionInputError(
                '%s cannot use a multiple-sequence alignment, so %s %s refused rather'
                ' than ignored: this method would fold single-sequence and nothing in'
                ' the result would say the alignment had been dropped.'
                % (self.id,
                   ', '.join(repr(alignments[c].name) for c in sorted(alignments)),
                   'is' if len(alignments) == 1 else 'are'))
        sequences = dict(spec.chains)
        for chain_id in sorted(alignments):
            msa = alignments[chain_id]
            if chain_id not in sequences:
                raise PredictionInputError(
                    'alignment %r is for chain %s, but this prediction has %s'
                    % (msa.name, chain_id,
                       'chain(s) ' + ', '.join(sorted(sequences)) if sequences
                       else 'no chains'))
            _check_alignment_query(chain_id, sequences[chain_id], msa)
        spec.alignments = alignments
        return spec


def _check_alignment_query(chain_id, sequence, msa):
    """Refuse an alignment whose query is not the sequence it would be folded against.

    Length first: the overwhelmingly common cause is not a wrong file but a structure
    with unobserved residues, whose sequence is legitimately shorter than the
    full-construct alignment built from it. Saying which of the two it is saves the
    user diffing two sequences by eye.
    """
    query = msa.query
    if query == sequence:
        return
    if len(query) != len(sequence):
        raise PredictionInputError(
            'alignment %r has a %d-residue query but chain %s is %d residues.'
            ' An alignment must be the alignment OF the sequence being folded --'
            ' unobserved residues are absent from a structure, so an alignment built'
            ' from the full construct will not match one read out of a crystal'
            ' structure.' % (msa.name, len(query), chain_id, len(sequence)))
    first = next(i for i, (a, b) in enumerate(zip(sequence, query)) if a != b)
    raise PredictionInputError(
        'alignment %r does not match chain %s: they differ at residue %d (%s in the'
        ' sequence being folded, %s in the alignment).'
        % (msa.name, chain_id, first + 1, sequence[first], query[first]))
