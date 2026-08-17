"""The cmd.* surface for per-object metrics (#308).

Every command here is tool-agnostic: it works off the schema a tool declared, so a
predictor, a design pass, a plugin or a file from someone else's pipeline are all read,
coloured and exported by the same code. Adding a tool never means editing this file.

Session-touching work lives in metrics.binding; the store itself is metrics.store.
"""
import json
import os

from pymol import cmd, colorprinting
from pymol.metrics import binding, document, schema, store
from pymol.metrics.errors import MetricAmbiguous, MetricNotFound


def _fmt(value):
    """A number for a feedback line: short, and honest about absence."""
    if value is None:
        return '-'
    if isinstance(value, float):
        return '%.4g' % value
    return str(value)


def _warn_if_stale(run, _self=cmd):
    reason = binding.stale_reason(run, _self=_self)
    if reason:
        colorprinting.warning(' metrics: run %s may be stale -- %s' % (run.id, reason))
    return reason


def _run_states(run, key=''):
    """Which states a run describes, as far as this lookup is concerned.

    For a key, the states of the entries carrying it -- `{None}` for an object-scope
    metric, which is about the object rather than any model. Without a key, the run's
    own state list.
    """
    if not key:
        return frozenset(run.states)
    return frozenset(entry.state for entry in run.values if entry.key == key)


def _resolve(run='', object='', key='', tool='', state=0, _self=cmd):
    """The run a command should act on.

    An explicit run id wins. Otherwise the NEWEST matching run on `object` -- newest
    because re-running a tool is how a user supersedes a result, and reaching for the
    older one by default would make the second run look as though it had not happened.

    That ordering only means something between runs that describe THE SAME THING. Two
    cases where they do not, and where "newest" would be an arbitrary pick between
    different measurements rather than the latest version of one:

    - several TOOLS have measured the object -- fold it, then design it;
    - several STATES have been measured, which is exactly what `n_models=N` produces:
      N independent runs landing as N states of one object, each with its own
      confidence. Silently answering with the last model's numbers for a question
      about the object is the single most likely way to misreport an ensemble.

    Both are refused, naming the tools or the states. `state=` and `tool=` resolve
    them; so does `run=`. A single candidate is never ambiguous -- one run that
    measured several states hands them all back, narrowed by `state` downstream.
    """
    if run:
        if store.have(run):
            return store.get(run)
        # `metrics_get my_object` is what a user types, and `run` is the first
        # positional. So an unmatched run id that names an OBJECT with runs is read as
        # one -- the same precedence metrics_delete already applies, id first. Anything
        # matching neither still raises below, naming the run ids that do exist.
        if run in store.objects():
            object = run
        else:
            return store.get(run)
    if not object:
        raise MetricNotFound('name a run, or an object to take the newest run of')
    candidates = [r for r in store.runs(object=object, tool=str(tool or ''))
                  if not key or key in r.keys()]
    if not candidates:
        raise MetricNotFound(
            'no run on %r%s%s; recorded objects: %s'
            % (object,
               ' from %r' % tool if tool else '',
               ' carrying %r' % key if key else '',
               ', '.join(store.objects()) or '(none)'))

    if state:
        # Narrowed HERE, not after a run has been picked. Filtering inside an
        # already-chosen run is what made `state=2` fail on a three-model object: the
        # newest run was model 3's, and it has nothing for state 2.
        state = int(state)
        wanted = [r for r in candidates
                  if state in _run_states(r, key) or _run_states(r, key) == {None}]
        if not wanted:
            available = sorted(
                s for r in candidates for s in _run_states(r, key) if s is not None)
            raise MetricNotFound(
                'nothing on %r describes state %d%s; measured on state(s): %s'
                % (object, state, ' for %r' % key if key else '',
                   ', '.join(str(s) for s in available) or 'none'))
        candidates = wanted

    if len(candidates) > 1:
        tools = sorted({r.tool for r in candidates})
        if len(tools) > 1:
            raise MetricAmbiguous(
                '%s have all measured %son %r. Name one with tool=, or a run with'
                ' run= -- taking the newest would pick between different measurements'
                ' rather than between versions of one.'
                % (', '.join(tools), '%r ' % key if key else '', object))
        described = {_run_states(r, key) for r in candidates}
        if len(described) > 1:
            states = sorted(s for group in described for s in group if s is not None)
            raise MetricAmbiguous(
                '%r carries %sfor state(s) %s -- separate models, not revisions of one.'
                ' Name one with state=, a run with run=, or list them all with'
                ' "metrics_list %s".'
                % (object, '%r ' % key if key else 'measurements ',
                   ', '.join(str(s) for s in states), object))
    return candidates[-1]


def metrics_list(object='', tool='', quiet=1, _self=cmd):
    """
DESCRIPTION

    "metrics_list" reports the measurement runs recorded against objects in this
    session -- what a prediction, a design pass or any other tool measured.

USAGE

    metrics_list [ object [, tool ]]

ARGUMENTS

    object = str: show only runs on this object {default: all}

    tool = str: show only runs from this tool, e.g. boltz2 {default: all}

NOTES

    An object carries MANY runs: folding it, re-folding it with a deeper alignment
    and then designing it are three runs, and none replaces another.

SEE ALSO

    metrics_get, metrics_color, metrics_export, metrics_schema
    """
    runs = store.runs(object=str(object or ''), tool=str(tool or ''))
    if not int(quiet):
        if not runs:
            colorprinting.parrot(' metrics_list: nothing recorded')
        for run in runs:
            scalars = run.scalars()
            shown = ', '.join('%s=%s' % (key, _fmt(value))
                              for key, value in list(scalars.items())[:4])
            # The state is on the line, not just in the payload: with `n_models=N` this
            # listing is N rows on ONE object, and without it they are indistinguishable
            # apart from an opaque run id.
            where = run.object
            if run.states:
                where += '/' + '+'.join(str(s) for s in run.states)
            colorprinting.parrot(
                ' %-22s %-12s %-18s %s'
                % (run.id, run.tool, where, shown or '(arrays only)'))
            _warn_if_stale(run, _self=_self)
    return [run.summary() for run in runs]


def metrics_get(run='', key='', object='', state=0, tool='', quiet=1, _self=cmd):
    """
DESCRIPTION

    "metrics_get" returns what one run measured, or one metric out of it.

USAGE

    metrics_get [ run [, key [, object [, state [, tool ]]]]]

ARGUMENTS

    run = str: run id, as shown by metrics_list. {default: the newest run on
    "object" that carries "key"}

    key = str: one metric, e.g. plddt or mean_plddt. {default: the whole run}

    object = str: used to find the run when no run id is given.

    state = int: narrow to one model. {default: 0, meaning every state}

    tool = str: which tool's run to take, e.g. boltz2. Needed only when several
    tools have measured the same object -- that case is refused rather than
    resolved by recency, because the newest of two DIFFERENT measurements is an
    arbitrary choice. {default: none, meaning any}

NOTES

    A residue- or pair-scope metric comes back with its INDEX -- the (chain, resi)
    pairs it was measured on -- not as a bare array. A structure with unobserved
    residues is exactly where a positional array lands on the wrong ones.

SEE ALSO

    metrics_list, metrics_color, metrics_export
    """
    state = int(state or 0)
    run_obj = _resolve(run=str(run or ''), object=str(object or ''),
                       key=str(key or ''), tool=str(tool or ''), state=state,
                       _self=_self)
    _warn_if_stale(run_obj, _self=_self)

    if not key:
        out = run_obj.summary(state=state or None)
        out['inputs'] = dict(run_obj.inputs)
        if not int(quiet):
            colorprinting.parrot(' metrics_get: run %s (%s on %s)'
                                 % (run_obj.id, run_obj.tool, run_obj.object))
            for name, value in out['scalars'].items():
                colorprinting.parrot('   %-24s %s' % (name, _fmt(value)))
            # A chain-scope scalar is listed as `key/chain`, so the base key has to be
            # recovered before deciding what is left -- otherwise every per-chain metric
            # prints twice, once with its value and once as an "(array)" it is not.
            shown = {name.split('/', 1)[0] for name in out['scalars']}
            for name in out['keys']:
                if name not in shown:
                    colorprinting.parrot('   %-24s (array)' % name)
        return out

    entries = run_obj.find(str(key), state=state or None)
    if not entries:
        raise MetricNotFound(
            'run %s has no %r%s; it has: %s'
            % (run_obj.id, key, ' for state %d' % state if state else '',
               ', '.join(run_obj.keys()) or '(none)'))
    results = []
    for entry in entries:
        if entry.is_array:
            results.append({'key': entry.key, 'scope': entry.scope,
                            'state': entry.state, 'chain': entry.chain,
                            'index': [list(pair) for pair in entry.index],
                            'values': list(entry.values)})
        else:
            results.append({'key': entry.key, 'scope': entry.scope,
                            'state': entry.state, 'chain': entry.chain,
                            'value': entry.value})
    if not int(quiet):
        for item in results:
            if 'values' in item:
                colorprinting.parrot(' %s: %s array over %d residues'
                                     % (item['key'], item['scope'],
                                        len(item['index'])))
            else:
                colorprinting.parrot(' %s: %s' % (item['key'], _fmt(item['value'])))
    # One value is the overwhelmingly common case (a scalar, or one state's array), and
    # unwrapping it keeps `metrics_get(run, 'mean_plddt')['value']` from needing an
    # index into a list of one.
    return results[0] if len(results) == 1 else results


def metrics_delete(name, quiet=1, _self=cmd):
    """
DESCRIPTION

    "metrics_delete" forgets a run, every run on an object, or all of them.

USAGE

    metrics_delete name

ARGUMENTS

    name = str: a run id, an object name, or "all".

SEE ALSO

    metrics_list
    """
    removed = store.delete(str(name))
    if not int(quiet):
        colorprinting.parrot(' metrics_delete: removed %d run(s)' % removed)
    return removed


def metrics_color(key, object='', run='', state=0, palette='blue_white_red',
                  minimum=None, maximum=None, selection='', tool='', quiet=1,
                  _self=cmd):
    """
DESCRIPTION

    "metrics_color" colours by a stored per-residue metric -- confidence, design
    certainty, anything a tool measured per residue.

USAGE

    metrics_color key [, object [, run [, state [, palette
        [, minimum [, maximum [, selection [, tool ]]]]]]]]

ARGUMENTS

    key = str: the residue-scope metric to colour by, e.g. plddt.

    object = str: which object. {default: taken from the run}

    run = str: run id. {default: the newest run on "object" carrying "key"}

    state = int: which model's values to use. {default: 0, meaning the run's only
    set of values -- required when the run measured several states}

    palette = str: any PyMOL palette {default: blue_white_red}

    minimum, maximum = float: spectrum domain {default: the range the tool declared
    for this metric, so two runs colour comparably instead of each auto-scaling}

    tool = str: which tool's run to colour by. Needed only when several tools have
    measured "key" on this object -- with no way to tell them apart that case is
    refused, because colouring by whichever tool ran last is not a choice the user
    made. {default: none, meaning any}

NOTES

    The B-factor column is a VIEW here, not storage: the run keeps the array, so this
    can be re-run after anything has coloured over the column -- a second
    metrics_color, a design pass on a build with no p.* properties, or a plain
    "spectrum count". Only one metric fits in "b" at a time; the record is elsewhere.

    Only the residues the metric was measured on are recoloured; everything else keeps
    its colour rather than being clamped to the end of the palette.

SEE ALSO

    metrics_get, spectrum
    """
    run_obj = _resolve(run=str(run or ''), object=str(object or ''),
                       key=str(key), tool=str(tool or ''), state=int(state or 0),
                       _self=_self)
    _warn_if_stale(run_obj, _self=_self)
    count = binding.color(
        run_obj, str(key), palette=str(palette),
        state=int(state) or None,
        minimum=None if minimum in (None, '') else float(minimum),
        maximum=None if maximum in (None, '') else float(maximum),
        selection=str(selection or ''), _self=_self)
    if not int(quiet):
        colorprinting.parrot(' metrics_color: %s coloured by %s over %d residues'
                             % (run_obj.object, key, count))
    return count


def metrics_export(filename, object='', run='', quiet=1, _self=cmd):
    """
DESCRIPTION

    "metrics_export" writes recorded metrics to a file.

USAGE

    metrics_export filename [, object [, run ]]

ARGUMENTS

    filename = str: .json for everything including pair matrices, or .csv for a long
    (run, tool, object, key, scope, state, chain, resi, value) table.

    object = str: export only this object's runs {default: all}

    run = str: export only this run {default: all matching}

NOTES

    CSV omits pair-scope metrics: a PAE matrix is the residue index squared, so a
    900-residue prediction would be 810 000 rows. Export those as JSON.

SEE ALSO

    metrics_load, metrics_get
    """
    filename = _self.exp_path(str(filename))
    if run:
        runs = [store.get(str(run))]
    else:
        runs = store.runs(object=str(object or ''))
    if not runs:
        raise MetricNotFound('nothing to export%s'
                             % (' for %r' % object if object else ''))

    if os.path.splitext(filename)[1].lower() == '.csv':
        import csv
        with open(filename, 'w', newline='') as handle:
            writer = csv.writer(handle)
            writer.writerow(('run', 'tool', 'object', 'key', 'scope', 'state',
                             'chain', 'resi', 'value'))
            for row in document.rows(runs):
                writer.writerow(['' if item is None else item for item in row])
    else:
        with open(filename, 'w') as handle:
            json.dump(document.dump(runs), handle, indent=1, default=str)
    if not int(quiet):
        colorprinting.parrot(' metrics_export: wrote %d run(s) to %s'
                             % (len(runs), filename))
    return filename


def metrics_load(filename, object='', quiet=1, _self=cmd):
    """
DESCRIPTION

    "metrics_load" reads a metric document produced outside RayMol and records it
    against an object.

USAGE

    metrics_load filename [, object ]

ARGUMENTS

    filename = str: a JSON metric document. It names its tool and its values, and --
    for a tool this build does not know -- declares their scopes in a "schema" block.

    object = str: the object it measured {default: the document's own "object"}

NOTES

    Values are checked against the object before anything is stored: a state that does
    not exist, or an array indexed by residues the object does not have, is refused
    rather than recorded.

SEE ALSO

    metrics_export, metrics_list
    """
    documents = document.load(_self.exp_path(str(filename)), object=str(object or ''))
    runs = []
    for parsed in documents:
        run = binding.record(parsed['object'], parsed['tool'], parsed['values'],
                             tool_version=parsed['tool_version'],
                             inputs=parsed['inputs'], note=parsed['note'], _self=_self)
        runs.append(run)
        if not int(quiet):
            colorprinting.parrot(' metrics_load: recorded %s (%d value(s)) on %s'
                                 % (run.id, len(run.values), run.object))
    # One file usually holds one run; unwrapping it keeps the common call from having
    # to index into a list of one, the way metrics_get does.
    return runs[0].id if len(runs) == 1 else [run.id for run in runs]


def metrics_schema(tool='', quiet=1, _self=cmd):
    """
DESCRIPTION

    "metrics_schema" lists what a tool measures: each key, its scope, its units and
    the range it is expected to fall in.

USAGE

    metrics_schema [ tool ]

ARGUMENTS

    tool = str: e.g. boltz2 {default: every tool that has declared metrics}

SEE ALSO

    metrics_list, metrics_get
    """
    tools = [str(tool)] if tool else schema.tools()
    out = {}
    for name in tools:
        out[name] = [spec.as_dict() for spec in schema.specs(name)]
        if not int(quiet):
            colorprinting.parrot(' %s' % name)
            for spec in schema.specs(name):
                domain = ('' if spec.lo is None and spec.hi is None
                          else '  [%s..%s]' % (_fmt(spec.lo), _fmt(spec.hi)))
                colorprinting.parrot(
                    '   %-18s %-8s %-8s %s%s'
                    % (spec.key, spec.scope, spec.units or '-', spec.label, domain))
    return out
