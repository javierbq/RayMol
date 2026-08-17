# Object Metrics

Object Metrics keeps the numbers a tool measured beside the structure it measured them
on. A prediction reports per-residue confidence, a pairwise error matrix and how long it
took; a design pass reports native fit and certainty per residue. All of it stays with the
object, survives a session save, and can be re-read, re-coloured and exported long after
the run finished.

An object carries **many** runs. Folding it, re-folding it with a deeper alignment, then
designing it are three runs, and none overwrites another.

## Seeing what has been measured

In the app, open the object panel: a **METRICS** section appears once anything has been
recorded, one row per run, showing the tool, the object and its first few numbers. Hover a
row for the full list. Right-click offers **Color by**, **Print values** and **Delete**.

At the command line:

```
PyMOL> metrics_list pred
 boltz2_1877b875   boltz2   pred/1   n_residues=117, msa_depth/A=1000, elapsed_s=14.1
 boltz2_6a86f4b4   boltz2   pred/2   n_residues=117, msa_depth/A=1000, elapsed_s=14.2

PyMOL> metrics_get pred, mean_plddt, state=2
 mean_plddt: 84.2
```

The second column is `object/state`. `metrics_get <object>` with no key lists everything
one run holds; per-residue and pairwise arrays are named rather than dumped, and you ask
for one by key.

`metrics_schema boltz2` says what any number is, in what units and over what range:

```
PyMOL> metrics_schema boltz2
 boltz2
   n_residues         object   residues Residues folded
   n_chains           object   chains   Chains
   msa_depth          chain    sequences Alignment depth used
   elapsed_s          state    s        Inference time
   peak_bytes         state    B        Peak memory
   plddt              residue  pLDDT    Per-residue confidence  [0..100]
   mean_plddt         state    pLDDT    Mean confidence  [0..100]
   pae                pair     A        Predicted aligned error  [0..32]
   min_ipsae          state    -        min ipSAE  [0..1]
   ipae               state    A        Interface PAE  [0..32]
```

## Colouring by a metric

```
metrics_color plddt, pred                 # per-residue confidence
metrics_color plddt, pred, state=2        # a particular model
metrics_color native_fit, my_design       # a design pass's score
```

Only the residues the metric was actually measured on are recoloured; everything else keeps
its colour instead of being clamped to the end of the palette. The spectrum spans the range
the tool declared for that metric, so two runs colour comparably rather than each
auto-scaling to itself — override with `minimum=` / `maximum=` if you want otherwise.

The B-factor column is a **view** here, not storage. It holds one scalar per atom, so only
one metric can be displayed through it at a time and anything that colours by it — a
second `metrics_color`, a `spectrum count` — displaces what was there. Because the run
keeps the array, colouring by a design score and then putting the prediction's confidence
back is two commands, in either order, any number of times.

Nor is an atom property the record. RayMol does implement `p.*` (Design writes
`p.mpnn_conf`, `assign_stereo` writes `p.stereo`), but a property is per atom: it carries
no run, no units and no provenance, cannot hold a per-state or per-pair value, and does not
survive a `.pse`.

## Several models in one object

`predict ..., n_models=5` is five independent runs landing as five states of **one**
object. Each writes its own per-model numbers — `mean_plddt`, `elapsed_s`, its `plddt`
array — while the sequence folded and the alignment depth used are properties of the
object and the chain, recorded with no state at all.

Pick a model with `state=`:

```
metrics_get pred, mean_plddt, state=2
metrics_color plddt, pred, state=2
```

Asking **without** one is refused, because the models are not revisions of each other and
answering with the last is how an ensemble gets misreported:

```
PyMOL> metrics_get pred, mean_plddt
 Error: 'pred' carries 'mean_plddt' for state(s) 1, 2, 3 -- separate models, not
 revisions of one. Name one with state=, a run with run=, or list them all with
 "metrics_list pred".
```

To compare models, read the runs:

```python
from pymol.metrics import store
runs = store.runs(object='pred')
[(r.states[0], r.one('mean_plddt', state=r.states[0]).value) for r in runs]
# [(1, 71.0), (2, 84.2), (3, 62.5)]

best = max(runs, key=lambda r: r.one('mean_plddt', state=r.states[0]).value)
best.states[0], best.inputs['seed']      # (2, 102) — the seed reproduces that model
```

## Several tools on one object

They do not collide: keys are namespaced by tool, so two tools may both report a `score`
without meaning the same thing by it. When a command has to pick a run for you it takes
the newest **within one tool** — re-running is how a result is superseded — but across
tools there is no such ordering, so it refuses and names them:

```
PyMOL> metrics_color conf, my_object
 Error: mpnn, mytool have all measured 'conf' on 'my_object'. Name one with tool=, or
 a run with run= -- taking the newest would pick between different measurements rather
 than between versions of one.

PyMOL> metrics_color conf, my_object, tool=mpnn
```

A key only one tool declares needs no disambiguation, and `run=` always wins outright.

## Reading the values

```python
from pymol.metrics import store
run, = store.runs(object='pred_x')

run.scalars()   # {'n_residues': 117, 'mean_plddt': 84.2, 'msa_depth/A': 1000}
run.inputs      # {'seed': 99, 'options': {...}, 'alignments': {'A': 'aln'}}
run.tool, run.tool_version, run.states

plddt = run.one('plddt', state=1)
plddt.as_map()  # {('A','1'): 91.0, ('A','3'): 78.5, ...}  unmeasured residues dropped
plddt.pairs()   # [('A','1',91.0), ('A','2',None), ...]    every residue, None kept
```

`as_map()` drops unmeasured residues; `pairs()` keeps them as `None`. Absence is never
`0.0` — a residue with no backbone was not scored, and a single-chain fold has no interface
score, so both come back absent rather than as a plausible-looking zero.

A pairwise array is row-major over its own index:

```python
pae = run.one('pae', state=1)
matrix = np.array(pae.values).reshape(len(pae.index), -1)
```

The same values are reachable without importing anything, which is what a script or the
MCP bridge wants: `cmd.metrics_get(object='pred_x', key='plddt')` returns a dict carrying
`index` and `values`.

## Taking them out of RayMol

```
metrics_export scores.csv, pred        # long format: run, tool, object, key, scope,
                                       # state, chain, resi, value
metrics_export scores.json, pred       # everything, including pairwise matrices
metrics_load  from_my_pipeline.json    # numbers computed elsewhere
```

CSV omits pairwise metrics: a PAE matrix is the residue index squared, so a 900-residue
prediction would be 810 000 rows in a file opened to look at eight confidence numbers.
Export those as JSON.

## Session behaviour

- Metrics travel inside the `.pse`. A session written with them still opens in upstream
  PyMOL, without them.
- Opening a session that carries none **empties** the store, as does `reinitialize`: runs
  naming objects the new session does not have would be worse than none.
- A run from a tool this build does not have is still restored. A `.pse` may carry a
  plugin's numbers, and dropping them because nothing can currently colour by them would
  lose the data the session was saved to keep.
- Renaming an object moves its runs; deleting it drops them. `create` does **not** copy
  them — a copy may be a subset selection, so the array's residues need not apply.
- States are positional. If an object's state count changes after a run was recorded, the
  run is flagged **stale** in `metrics_list`, in `metrics_get` and on the panel row.
  Nothing repairs it, because nothing can know which state went.

## Commands

```
metrics_list [object [, tool]]                            runs in this session
metrics_get [run [, key [, object [, state [, tool]]]]]    a run, or one metric
metrics_color key [, object [, run [, state [, palette
    [, minimum [, maximum [, selection [, tool]]]]]]]]     colour by a residue array
metrics_export filename [, object [, run]]                 .json or .csv
metrics_load filename [, object]                           a document from elsewhere
metrics_delete name                                        a run id, an object, or "all"
metrics_schema [tool]                                      what a tool measures
```

---

# For tool authors

The machinery is tool-agnostic. A tool declares what it measures **once**; the store, the
object panel, `metrics_color` and export all work off that declaration, so adding a tool
never means editing the store.

## Scope

Scope is the design, and it is checked when a value is written — a number at the wrong
scope reads perfectly and describes something else.

| Scope | True of | Examples |
|---|---|---|
| `object` | the object as a whole; typically sequence-derived, identical across states | `n_residues`, sequence recovery |
| `state` | one model, one set of coordinates | `mean_plddt`, `elapsed_s`, RMSD to a reference |
| `chain` | one chain, optionally in one state | `msa_depth`, per-chain identity |
| `residue` | an array indexed by `(chain, resi)` | `plddt`, `native_fit`, SASA |
| `pair` | an array indexed by `(chain, resi) x (chain, resi)`, row-major | `pae`, contact probability |

`n_models=5` is what forces the distinction: five models each have their own
`mean_plddt`, while the sequence they folded is one value for the object and the alignment
depth is one value per chain.

Two rules make scope carry its weight:

- **A scope mismatch is an error, not a coercion.** An `object`-scope value carrying a
  state, a state that does not exist, an array indexed by residues the object does not
  have — all refused at write time, naming the offender.
- **The store never aggregates.** A spec may *declare* that an array summarises by mean,
  and a tool may write both the array and the summary; the store computes neither. Which
  residues went into a mean is a property of the tool, and re-deriving one from a rounded
  B-factor column is the lossy path this package exists to close.

## Declaring what a tool measures

```python
from pymol.metrics import schema

schema.register('mytool', [
    schema.MetricSpec('score', schema.STATE, units='kcal/mol',
                      label='Interaction energy', higher_is_better=False),
    schema.MetricSpec('burial', schema.RESIDUE, lo=0, hi=1, summarizes='mean'),
])
```

`lo`/`hi` are the expected domain and become `metrics_color`'s default spectrum range.

Declare only what the tool genuinely produces: a caller that finds a key in the schema is
entitled to conclude the tool can produce it. A structure predictor declares its set as
`Predictor.metric_specs` instead, registered when the predictor is — see
[predictors.md](predictors.md) step 8.

## Recording a run

```python
from pymol.metrics import binding, store

binding.record('my_object', 'mytool', [
    store.value('mytool', 'score', value=-42.1, state=1),
    store.value('mytool', 'burial', state=1, index=index, values=burial),
], inputs={'cutoff': 8.0})
```

`index` is a sequence of `(chain, resi)` pairs with `resi` as a **string** — PyMOL's is,
and insertion codes are real. `values` is positionally aligned to it and may contain
`None`.

`inputs` is provenance, not measurement: options, seed, cutoffs, which alignment. A metric
without it is not evidence of anything — a second weight pack or a different alignment
depth changes the number without changing the sequence — which is why it travels in the
same record.

`binding.record` validates against the object and raises rather than storing something
that does not fit. Use it from the main thread; `pymol.metrics.store` itself touches no
session and is safe to exercise without one.

## The document format

`metrics_load` reads, and `metrics_export` writes, this shape. So does the Swift inference
host, beside a finished prediction — pLDDT, PAE and the interface scores exist only inside
the runtime.

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

`schema` is consulted only for a tool this build does not know — a plugin, or a pipeline of
your own. A tool RayMol ships declares its keys in Python and a document cannot redefine
them, which would let a file change what `plddt` means for every run in the session. Omit
`state` for an `object`-scope value.

For metrics produced by a Swift runtime, write the document to `request.metrics_path` and
let `deliver_result` bind it; `BoltzJobManager.writeMetrics` is the worked example. Elapsed
time and peak memory already reach the store through the status file — do not send them
twice from two sources that could disagree.

## Layout

| File | Responsibility |
|---|---|
| `modules/pymol/metric.py` | the `cmd.*` surface |
| `modules/pymol/metrics/store.py` | runs, values, the named store, the `.pse` round trip |
| `modules/pymol/metrics/schema.py` | `Scope`, `MetricSpec`, the per-tool registry |
| `modules/pymol/metrics/binding.py` | everything that asks the session: scope checks, staleness, colouring |
| `modules/pymol/metrics/document.py` | the on-disk document, in and out |
| `modules/pymol/predictors/metrics.py` | the shared predictor spec sets |

Tests are in `testing/tests/metrics/`:

```
pymol -ckqy testing/testing.py --run testing/tests/metrics
```

One constraint worth knowing before touching the panel path: the object panel polls the
main thread every 500 ms, so its payload carries precomputed scalars only and never walks
an array. A PAE matrix is the residue index squared.
