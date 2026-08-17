"""Numbers a tool measured about an object, scoped and kept with the object (#308).

    metric.py     the cmd.* surface (metrics_list, metrics_get, metrics_color, ...)
    schema.py     Scope, MetricSpec, and the per-tool schema registry
    store.py      runs and their values, the named store, and the .pse round trip
    binding.py    everything that has to ASK THE SESSION: scope checks, staleness
    errors.py     the exception taxonomy

The machinery is tool-agnostic on purpose. A tool declares what it measures once --
key, scope, dtype, units -- and the store, the panel, `metrics_color` and export work
from that declaration, so the fifth predictor needs no edit in here. Nothing in this
package imports a predictor, a design module, or `cmd` except `binding.py`, which is
the one place a session is consulted.

The design problem is SCOPE, not storage. `mean_plddt` is about one model, sequence
recovery is about the sequence and is identical across all five, an RMSD is about a
pair of objects, and a confidence array is about residues. A metric written at the
wrong scope reads perfectly and describes something else, so scope is declared by the
tool and enforced at write time rather than inferred here.
"""
