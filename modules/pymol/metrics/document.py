"""The on-disk metric document: one JSON shape for everything computed elsewhere.

Both producers use it. The Swift inference host writes one beside a finished
prediction, because pLDDT, PAE and the interface scores exist only inside the runtime
and would otherwise be discarded -- today RayMol reads exactly one of them, as rounded
B-factors, and drops the rest. And a user with numbers from their own pipeline loads
one with `metrics_load`. Two producers, one reader, no second format to keep in step.

    {
      "tool": "boltz2",                  # required
      "tool_version": "boltz2-bf16",     # optional
      "object": "pred_ab12cd34",         # optional; the caller may name it instead
      "note": "",                        # optional, free text for the panel row
      "inputs": {...},                   # optional provenance: options, seed, msa
      "schema": [ {"key": ..., "scope": ...}, ... ],   # required for an unknown tool
      "values": [
        {"key": "mean_plddt", "state": 1, "value": 84.2},
        {"key": "plddt", "state": 1,
         "index": [["A", "1"], ["A", "2"]], "values": [83.1, 91.7]}
      ]
    }

`schema` is only consulted for a tool this build has never heard of -- a plugin, or a
pipeline of the user's own. A tool RayMol ships declares its own keys in Python, and a
document claiming otherwise does not get to redefine them: that would let a file change
what `plddt` means for every run in the session.
"""
import json

from . import schema as schema_module
from . import store
from .errors import MetricInputError


def parse(payload, object=''):
    """A document dict -> everything binding.record() needs. Registers an ad-hoc
    schema for an unknown tool as a side effect.

    Returns a dict with `tool`, `tool_version`, `object`, `inputs`, `note` and
    `values` (a list of MetricValue).
    """
    if not isinstance(payload, dict):
        raise MetricInputError('a metric document must be a JSON object')
    tool = str(payload.get('tool') or '').strip()
    if not tool:
        raise MetricInputError('a metric document must name its "tool"')
    target = str(object or payload.get('object') or '').strip()
    if not target:
        raise MetricInputError(
            'a metric document must name the "object" it measured, or the caller must')

    declared = payload.get('schema') or []
    if not schema_module.declared(tool):
        if not declared:
            raise MetricInputError(
                'tool %r is unknown to this build, so the document must carry a'
                ' "schema" declaring its keys -- otherwise nothing can say what its'
                ' numbers are, at what scope, or in what units' % tool)
        schema_module.register(tool, [
            schema_module.MetricSpec(**entry) for entry in declared])

    values = []
    for entry in payload.get('values') or []:
        if not isinstance(entry, dict) or 'key' not in entry:
            raise MetricInputError('malformed value entry: %r' % (entry,))
        values.append(store.value(
            tool, entry['key'],
            value=entry.get('value'),
            state=entry.get('state'),
            chain=entry.get('chain'),
            index=entry.get('index'),
            values=entry.get('values')))

    return {
        'tool': tool,
        'tool_version': str(payload.get('tool_version') or ''),
        'object': target,
        'inputs': payload.get('inputs') or {},
        'note': str(payload.get('note') or ''),
        'values': values,
    }


def parse_all(payload, object=''):
    """One document, or a list of them, -> a list of parsed documents.

    A file may hold several: `dump()` writes one per RUN, and an object with a fold and
    a design pass on it exports as two. A single document is accepted as itself so a
    hand-written file -- or one from a pipeline that only ever produces one -- does not
    have to be wrapped in a list to be loadable.
    """
    if isinstance(payload, list):
        return [parse(entry, object=object) for entry in payload]
    return [parse(payload, object=object)]


def load(path, object=''):
    """Read and parse every document in the file at `path`."""
    with open(path) as handle:
        return parse_all(json.load(handle), object=object)


def dump(runs, with_schema=True):
    """Runs -> a JSON-ready payload. The inverse of parse(), for export.

    A LIST of documents, because runs may come from several tools and a document names
    exactly one. Arrays go in verbatim and uncompressed: an export is meant to be read
    by something that is not RayMol.
    """
    out = []
    for run in runs:
        entries = []
        for value in run.values:
            entry = {'key': value.key}
            if value.state is not None:
                entry['state'] = value.state
            if value.chain is not None:
                entry['chain'] = value.chain
            if value.is_array:
                entry['index'] = [list(pair) for pair in value.index]
                entry['values'] = list(value.values)
            else:
                entry['value'] = value.value
            entries.append(entry)
        document = {
            'tool': run.tool,
            'tool_version': run.tool_version,
            'object': run.object,
            'run': run.id,
            'created': run.created,
            'states': list(run.states),
            'note': run.note,
            'inputs': run.inputs,
            'values': entries,
        }
        if with_schema and schema_module.declared(run.tool):
            # Carried so the export round-trips into a RayMol that does not have the
            # tool -- which is the ordinary case for anything sent to a collaborator.
            document['schema'] = [spec.as_dict()
                                  for spec in schema_module.specs(run.tool)
                                  if spec.key in run.keys()]
        out.append(document)
    return out


def rows(runs):
    """Runs -> flat (run, tool, object, key, scope, state, chain, resi, value) rows.

    The long format, which is what a spreadsheet or a dataframe wants and what makes
    one CSV able to hold every scope at once. A pair array is NOT flattened here: it is
    the index squared, and a 900-residue PAE would be 810 000 rows in a file someone
    opened to look at eight confidence numbers. Export it as JSON.
    """
    out = []
    for run in runs:
        for value in run.values:
            if value.scope == schema_module.PAIR:
                continue
            if value.is_array:
                for chain, resi, number in value.pairs():
                    out.append((run.id, run.tool, run.object, value.key, value.scope,
                                value.state, chain, resi, number))
            else:
                out.append((run.id, run.tool, run.object, value.key, value.scope,
                            value.state, value.chain, '', value.value))
    return out
