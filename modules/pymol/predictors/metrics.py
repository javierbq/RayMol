"""What a structure predictor measures, declared once (#308).

Split out of the individual predictors because most of these keys are shared: every
method takes time and memory, and every method that carries a confidence head reports
pLDDT the same way. A method then declares the SUBSET it can actually produce -- a
sampler that emits coordinates and nothing else takes UNSCORED_SPECS and no confidence
keys at all -- which is the same discipline `option_defaults` and `supports_msa` already
apply to the inference knobs: a capability is named, not assumed.

Scope is the part worth reading. `n_residues` is object-scope because it is a property
of the sequence and is identical for all five models of `n_models=5`; `mean_plddt` is
state-scope because each model has its own; `msa_depth` is chain-scope because a
designed binder legitimately has an alignment for the target and none for itself.
"""
from pymol.metrics.schema import CHAIN, OBJECT, PAIR, RESIDUE, STATE, MetricSpec

#: True of the fold as a whole, whatever ran it.
INPUT_SPECS = (
    MetricSpec('n_residues', OBJECT, dtype='int', units='residues',
               label='Residues folded',
               description='Total residues across every chain of the prediction.'),
    MetricSpec('n_chains', OBJECT, dtype='int', units='chains',
               label='Chains'),
    MetricSpec('msa_depth', CHAIN, dtype='int', units='sequences',
               label='Alignment depth used',
               description='Rows of this chain\'s alignment the run actually read.'
                           ' Absent for a chain folded single-sequence, which is the'
                           ' designed-binder case rather than an error.'),
)

#: What running it cost. Reported by the host for every method, and state-scope because
#: with n_models each model is a full independent run with its own cost.
RUNTIME_SPECS = (
    MetricSpec('elapsed_s', STATE, units='s', label='Inference time',
               higher_is_better=False,
               description='Wall clock inside the runtime: featurization is not'
                           ' included, and neither is a weight download.'),
    MetricSpec('peak_bytes', STATE, dtype='int', units='B', label='Peak memory',
               higher_is_better=False),
)

#: The confidence head. Only for a method that HAS one -- a method without a confidence
#: module must not declare these, because a caller that finds `plddt` in the schema is
#: entitled to conclude the tool can produce it.
CONFIDENCE_SPECS = (
    MetricSpec('plddt', RESIDUE, units='pLDDT', label='Per-residue confidence',
               lo=0, hi=100, higher_is_better=True, summarizes='mean',
               description='Predicted lDDT per residue, 0-100. The array the viewer'
                           ' colours by; `mean_plddt` is its declared summary, written'
                           ' by the producer rather than derived here.'),
    MetricSpec('mean_plddt', STATE, units='pLDDT', label='Mean confidence',
               lo=0, hi=100, higher_is_better=True),
    MetricSpec('pae', PAIR, units='A', label='Predicted aligned error',
               lo=0, hi=32, higher_is_better=False,
               description='Row-major over the residue index: the expected error in'
                           ' residue i once the structure is aligned on residue j.'),
    MetricSpec('min_ipsae', STATE, label='min ipSAE', lo=0, hi=1,
               higher_is_better=True,
               description='Interface score between the first two chains. ABSENT for'
                           ' a single chain, where an interface score is undefined --'
                           ' not zero, which would read as a terrible interface.'),
    MetricSpec('ipae', STATE, units='A', label='Interface PAE', lo=0, hi=32,
               higher_is_better=False),
)

#: The usual set for a method with a confidence head.
SCORED_SPECS = INPUT_SPECS + RUNTIME_SPECS + CONFIDENCE_SPECS

#: The usual set for a method without one.
UNSCORED_SPECS = INPUT_SPECS + RUNTIME_SPECS
