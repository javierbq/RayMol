# Object metrics

What a tool measured about an object, kept with the object. A prediction reports
per-residue confidence and pairwise error; a design pass reports native fit and
certainty; anything else you run reports whatever it reports. All of it lands in one
store, survives a `.pse`, and is read by one set of commands.

Generic by construction: a tool declares what it measures **once**, and the store, the
object panel, `metrics_color` and export work off that declaration. Adding a tool never
means editing the store.

## Scope

Scope is the design. A metric declares which of these it is, and it is checked when it
is written -- a number written at the wrong scope reads perfectly and describes
something else.

| Scope | What it is true of | Examples |
|---|---|---|
| `object` | The object as a whole; typically sequence-derived, identical across states | `n_residues`, sequence recovery |
| `state` | One model, one set of coordinates | `mean_plddt`, `elapsed_s`, RMSD to a reference |
| `chain` | One chain, optionally in one state | `msa_depth`, per-chain identity |
| `residue` | An array indexed by `(chain, resi)` | `plddt`, `native_fit`, SASA |
| `pair` | An array indexed by `(chain, resi) x (chain, resi)`, row-major | `pae`, contact probability |

`n_models=5` is the case that forces the distinction: five full runs land as five states
of one object, each with its own `mean_plddt` at `state` scope, while the sequence they
folded and the alignment depth they used are one value at `object` and `chain` scope.

Two rules make scope carry its weight:

* **A scope mismatch is an error, not a coercion.** An `object`-scope value with a
  state, a `state`-scope value without one, an array indexed by residues the object does
  not have -- all refused at write time.
* **The store never aggregates.** A spec may declare that a residue array *summarises*
  by mean, and a tool may write both the array and the summary. The store computes
  neither: which residues went into a mean is a property of the tool.

## Commands

```
metrics_list [object [, tool]]                  runs recorded in this session
metrics_get [run [, key [, object [, state]]]]  one run, or one metric out of it
metrics_color key [, object [, run [, state ...]]]   colour by a residue-scope array
metrics_export filename [, object [, run]]      .json (everything) or .csv (long format)
metrics_load filename [, object]                a document from outside RayMol
metrics_delete name                             a run id, an object, or "all"
metrics_schema [tool]                           what a tool measures, and at what scope
```

The B-factor column is a **view**, not storage. `metrics_color` writes an array into `b`
and spectrums it; the run keeps the array, so it can be re-applied after another tool has
coloured over the column. Before this existed, a design pass overwrote a prediction's
pLDDT and there was no way back.

## Declaring metrics for a tool

```python
from pymol.metrics import schema

schema.register('mytool', [
    schema.MetricSpec('score', schema.STATE, units='kcal/mol',
                      label='Interaction energy', higher_is_better=False),
    schema.MetricSpec('burial', schema.RESIDUE, lo=0, hi=1, summarizes='mean'),
])
```

`lo`/`hi` are the expected domain and become `metrics_color`'s default spectrum range,
so two runs colour comparably instead of each auto-scaling to itself.

A structure predictor declares its set as `Predictor.metric_specs` instead, and the
registry registers it when the predictor is registered -- see `docs/predictors.md`.
Declare only what the method genuinely measures: a caller that finds a key in the schema
is entitled to conclude the tool can produce it.

## Recording a run

```python
from pymol.metrics import binding, store

values = [
    store.value('mytool', 'score', value=-42.1, state=1),
    store.value('mytool', 'burial', state=1, index=index, values=burial),
]
binding.record('my_object', 'mytool', values, inputs={'cutoff': 8.0})
```

`index` is a sequence of `(chain, resi)` pairs, with `resi` as a **string** -- PyMOL's is,
and insertion codes are real. `values` is positionally aligned to it and may contain
`None`: absent is not zero, and a residue that was not measured must not arrive as a
plausible-looking 0.

`inputs` is provenance, not measurement -- options, seed, cutoffs, which alignment. A
metric without it is not evidence of anything, which is why it travels in the same
record.

An object carries **many** runs. Folding it, re-folding it with a deeper alignment and
then designing it are three runs, and none replaces another.

## The document format

`metrics_load` reads, and `metrics_export` writes, a JSON document. It is also what the
Swift inference host writes beside a finished prediction, because pLDDT, PAE and the
interface scores exist only inside the runtime.

```json
{
  "tool": "mytool",
  "tool_version": "v1",
  "object": "my_object",
  "inputs": {"cutoff": 8.0},
  "schema": [{"key": "burial", "scope": "residue", "lo": 0, "hi": 1}],
  "values": [
    {"key": "score", "state": 1, "value": -42.1},
    {"key": "burial", "state": 1,
     "index": [["A", "1"], ["A", "2"]], "values": [0.7, null]}
  ]
}
```

`schema` is required only for a tool this build does not know; a tool RayMol ships
declares its own keys in Python and a document cannot redefine them. Omit `state` for an
`object`-scope value.

## Session behaviour

* Runs ride the `.pse` under `raymol_metrics`, arrays gzipped. A session written with
  metrics still opens in upstream PyMOL, without them.
* A session carrying no metrics **empties** the store, as does `reinitialize` -- runs
  naming objects the new session does not have would be worse than none.
* A run from a tool this build lacks is still restored. A `.pse` may carry a plugin's
  numbers, and dropping them because nothing can currently colour by them would lose the
  data the session was saved to keep.
* `set_name` moves runs; deleting an object drops them. A `create` does **not** inherit
  them -- a copy may be a subset selection, so the array's residues need not apply.
* States are positional. If the object's state count changes after a run is recorded, the
  run is flagged **stale** in `metrics_list`, `metrics_get` and the panel row. Nothing
  repairs it: nothing here can know which state went.
