"""Scopes, metric declarations, and the per-tool registry.

A tool declares what it measures ONCE, here, and everything generic falls out of that
declaration: a listing renders a run without knowing the tool, `metrics_color` can
colour by any residue-scope key by name, export is one code path, and two runs of one
tool are comparable because they share a schema. If adding a tool needs an edit inside
store.py or metric.py, this declaration is not carrying enough.
"""
from .errors import MetricSchemaError

#: True of the object as a whole. Typically sequence-derived, and therefore identical
#: across every state -- the sequence folded, the alignment depth used, the recovery
#: measured against it. `n_models=5` writes ONE of these, not five copies.
OBJECT = 'object'
#: True of one model: one set of coordinates. Mean pLDDT, clash score, radius of
#: gyration, RMSD to a reference. Five models means five of these.
STATE = 'state'
#: Per chain. Carries a state as well when the value depends on the coordinates
#: (per-chain pLDDT) and omits it when it does not (per-chain identity).
CHAIN = 'chain'
#: An array indexed by (chain, resi). Per-residue confidence, design certainty, SASA.
RESIDUE = 'residue'
#: An array indexed by (chain, resi) x (chain, resi), row-major over the same index.
#: Predicted aligned error, contact probability, coevolutionary coupling.
PAIR = 'pair'

SCOPES = (OBJECT, STATE, CHAIN, RESIDUE, PAIR)

#: Scopes whose value is a single number, not an array.
SCALAR_SCOPES = (OBJECT, STATE, CHAIN)
#: Scopes that carry an index alongside their values.
ARRAY_SCOPES = (RESIDUE, PAIR)
#: Scopes whose value depends on coordinates, so a state is meaningful. `chain` is in
#: both this and the list above: a per-chain value may or may not be per-state, which
#: is why `state` is optional there and required for STATE/RESIDUE/PAIR.
STATE_BEARING_SCOPES = (STATE, CHAIN, RESIDUE, PAIR)

DTYPES = ('float', 'int', 'str', 'bool')

#: Declared summarisation rules. ADVISORY: the store never applies one. A tool that
#: wants `mean_plddt` beside its per-residue array writes both, because deriving one
#: from the other here would mean the summary and the array could disagree about which
#: residues were included -- and re-deriving from a rounded B-factor column is exactly
#: the lossy path this package exists to close.
SUMMARY_RULES = ('mean', 'median', 'min', 'max', 'sum', 'count')


class MetricSpec:
    """One thing a tool measures.

    `scope` decides where the value may be written; everything else is what a generic
    consumer needs in order to render, colour or export a number it has never heard of.
    `lo`/`hi` are the expected domain (pLDDT is 0-100, ipSAE is 0-1), used as the
    default spectrum range so colouring is comparable between runs rather than
    auto-scaled to each one. `higher_is_better` is None when the question does not
    apply -- an elapsed time is neither.
    """

    __slots__ = ('key', 'scope', 'dtype', 'units', 'label', 'lo', 'hi',
                 'higher_is_better', 'summarizes', 'description')

    def __init__(self, key, scope, dtype='float', units='', label='',
                 lo=None, hi=None, higher_is_better=None, summarizes='',
                 description=''):
        key = str(key or '').strip()
        if not key:
            raise MetricSchemaError('a metric needs a key')
        if scope not in SCOPES:
            raise MetricSchemaError(
                'unknown scope %r for %r; scopes are: %s'
                % (scope, key, ', '.join(SCOPES)))
        if dtype not in DTYPES:
            raise MetricSchemaError(
                'unknown dtype %r for %r; dtypes are: %s'
                % (dtype, key, ', '.join(DTYPES)))
        if scope in ARRAY_SCOPES and dtype == 'str':
            # Not a limitation worth working around: an array of strings is a label
            # track, and the things that consume arrays here -- spectrum colouring,
            # numeric export -- have nothing to do with one.
            raise MetricSchemaError(
                '%r is a %s array, which must be numeric or boolean, not str' %
                (key, scope))
        if summarizes and summarizes not in SUMMARY_RULES:
            raise MetricSchemaError(
                'unknown summary rule %r for %r; rules are: %s'
                % (summarizes, key, ', '.join(SUMMARY_RULES)))
        if lo is not None and hi is not None and float(lo) > float(hi):
            raise MetricSchemaError(
                'range for %r is inverted: lo=%r > hi=%r' % (key, lo, hi))
        self.key = key
        self.scope = scope
        self.dtype = dtype
        self.units = str(units or '')
        self.label = str(label or key)
        self.lo = None if lo is None else float(lo)
        self.hi = None if hi is None else float(hi)
        self.higher_is_better = higher_is_better
        self.summarizes = summarizes
        self.description = str(description or '')

    def cast(self, value):
        """`value` as this spec's dtype, or raise.

        None passes through UNTOUCHED. Absent is not zero: a single-chain fold has no
        interface score and a masked residue has no design score, and coercing either
        to 0.0 would put a real-looking number where there is no measurement.
        """
        from .errors import MetricInputError
        if value is None:
            return None
        try:
            if self.dtype == 'float':
                value = float(value)
                # NaN/inf are how a runtime says "this did not compute". They survive
                # neither JSON nor a useful spectrum, so they are absent instead --
                # and absent is a thing this package represents honestly.
                if value != value or value in (float('inf'), float('-inf')):
                    return None
                return value
            if self.dtype == 'int':
                return int(value)
            if self.dtype == 'bool':
                return bool(value)
            return str(value)
        except (TypeError, ValueError):
            raise MetricInputError(
                '%r expects %s, got %r' % (self.key, self.dtype, value))

    def as_dict(self):
        return {name: getattr(self, name) for name in self.__slots__}

    def __repr__(self):
        return 'MetricSpec(%r, %r, dtype=%r)' % (self.key, self.scope, self.dtype)


#: tool id -> {key: MetricSpec}. Process-wide, like the predictor registry and the MSA
#: store; a second pymol2 instance shares it. Insertion-ordered, which is the order
#: `metrics_schema` lists keys in.
_SCHEMAS = {}


def register(tool, specs, replace=False):
    """Declare what `tool` measures. Returns the tool's schema.

    `specs` is an iterable of MetricSpec, or of kwargs dicts for one. Re-registering a
    tool is an error unless `replace` -- two modules declaring the same tool with
    different keys is a bug that would otherwise surface much later, as a write
    rejected for a key its author can see in their own source.
    """
    tool = str(tool or '').strip()
    if not tool:
        raise MetricSchemaError('a schema needs a tool id')
    if tool in _SCHEMAS and not replace:
        raise MetricSchemaError(
            'tool %r already declared %d metric(s); pass replace=1 to redeclare'
            % (tool, len(_SCHEMAS[tool])))
    table = {}
    for spec in specs:
        if isinstance(spec, dict):
            spec = MetricSpec(**spec)
        if not isinstance(spec, MetricSpec):
            raise MetricSchemaError(
                'expected a MetricSpec or a dict of its arguments, got %r' % (spec,))
        if spec.key in table:
            raise MetricSchemaError(
                'tool %r declares %r twice' % (tool, spec.key))
        table[spec.key] = spec
    _SCHEMAS[tool] = table
    return table


def declared(tool):
    """True if `tool` has a schema. Cheap enough for a write path to ask first."""
    return str(tool) in _SCHEMAS


def spec(tool, key):
    """The MetricSpec for `key`, or raise naming what the tool DOES declare."""
    try:
        table = _SCHEMAS[tool]
    except KeyError:
        raise MetricSchemaError(
            'tool %r has declared no metrics; known tools: %s'
            % (tool, ', '.join(tools()) or '(none)'))
    try:
        return table[key]
    except KeyError:
        raise MetricSchemaError(
            '%s does not declare %r; it declares: %s'
            % (tool, key, ', '.join(table) or '(none)'))


def specs(tool):
    """Every MetricSpec `tool` declares, in declaration order."""
    try:
        return list(_SCHEMAS[tool].values())
    except KeyError:
        raise MetricSchemaError(
            'tool %r has declared no metrics; known tools: %s'
            % (tool, ', '.join(tools()) or '(none)'))


def tools():
    """Tools with a schema, in registration order."""
    return list(_SCHEMAS)


def forget(tool):
    """Drop a schema. For tests and for `metrics_load`'s ad-hoc tool declarations."""
    _SCHEMAS.pop(tool, None)
