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
from pymol.metrics.schema import (CHAIN, OBJECT, PAIR, PROVENANCE, RESIDUE, SCORE, STATE,
                                  MetricSpec)

#: True of the fold as a whole, whatever ran it.
INPUT_SPECS = (
    MetricSpec('n_residues', OBJECT, role=PROVENANCE, dtype='int', units='residues',
               label='Residues folded',
               description='Total residues across every chain of the prediction.'),
    MetricSpec('n_chains', OBJECT, role=PROVENANCE, dtype='int', units='chains',
               label='Chains'),
    MetricSpec('msa_depth', CHAIN, role=PROVENANCE, dtype='int', units='sequences',
               label='Alignment depth used',
               description='Rows of this chain\'s alignment the run actually read.'
                           ' Absent for a chain folded single-sequence, which is the'
                           ' designed-binder case rather than an error.'),
)

#: What running it cost. Reported by the host for every method, and state-scope because
#: with n_models each model is a full independent run with its own cost.
#: PROVENANCE despite `higher_is_better=False`, which is why every spec here names its
#: role rather than taking `default_role`: a faster run is better, but nobody triages
#: designs on how long the GPU took, and the drawer must not put it beside pLDDT (#544).
RUNTIME_SPECS = (
    MetricSpec('elapsed_s', STATE, role=PROVENANCE, units='s', label='Inference time',
               higher_is_better=False,
               description='Wall clock inside the runtime: featurization is not'
                           ' included, and neither is a weight download.'),
    MetricSpec('peak_bytes', STATE, role=PROVENANCE, dtype='int', units='B', label='Peak memory',
               higher_is_better=False),
)

#: The confidence head. Only for a method that HAS one -- a method without a confidence
#: module must not declare these, because a caller that finds `plddt` in the schema is
#: entitled to conclude the tool can produce it.
CONFIDENCE_SPECS = (
    MetricSpec('plddt', RESIDUE, role=SCORE, units='pLDDT', label='Per-residue confidence',
               lo=0, hi=100, higher_is_better=True, summarizes='mean',
               description='Predicted lDDT per residue, 0-100. The array the viewer'
                           ' colours by; `mean_plddt` is its declared summary, written'
                           ' by the producer rather than derived here.'),
    MetricSpec('mean_plddt', STATE, role=SCORE, units='pLDDT', label='Mean confidence',
               lo=0, hi=100, higher_is_better=True),
    MetricSpec('pae', PAIR, role=SCORE, units='A', label='Predicted aligned error',
               lo=0, hi=32, higher_is_better=False,
               description='Row-major over the residue index: the expected error in'
                           ' residue i once the structure is aligned on residue j.'),
    MetricSpec('mean_pae', STATE, role=SCORE, units='A', label='Mean predicted aligned error',
               lo=0, hi=32, higher_is_better=False,
               description='Mean of the PAE matrix OFF THE DIAGONAL. PAE(i, i) is'
                           ' definitionally near zero and carries no information, so'
                           ' including it would dilute the mean by 1/n -- 3% for a'
                           ' 35-residue peptide, and the shorter the chain the worse.'
                           ' Distinct from `ipae`, which is inter-chain pairs only:'
                           ' this one is defined for a single chain too.'),
    MetricSpec('min_ipsae', STATE, role=SCORE, label='min ipSAE', lo=0, hi=1,
               higher_is_better=True,
               description='min(A->B, B->A) between the first two chains -- the GATE'
                           ' metric, because the worse direction is what a designed'
                           ' interface should be judged on. ABSENT for a single chain,'
                           ' where an interface score is undefined -- not zero, which'
                           ' would read as a terrible interface. No threshold is'
                           ' implied: boltz-mlx computes the combined-length (d0chn)'
                           ' variant, and a cutoff quoted for another variant moves the'
                           ' operating point permissively.'),
    MetricSpec('ipsae', STATE, role=SCORE, label='ipSAE', lo=0, hi=1, higher_is_better=True,
               description='max(A->B, B->A). Reported for continuity with the ipSAE'
                           ' reference implementation; NOT the gate -- use `min_ipsae`'
                           ' for that, and expect this to read higher.'),
    MetricSpec('ipae', STATE, role=SCORE, units='A', label='Interface PAE', lo=0, hi=32,
               higher_is_better=False,
               description='Mean PAE over inter-chain pairs, both directions. < 10 A is'
                           ' the conventional confident-interface mark.'),
)

#: The usual set for a method with a confidence head.
SCORED_SPECS = INPUT_SPECS + RUNTIME_SPECS + CONFIDENCE_SPECS

#: The usual set for a method without one.
UNSCORED_SPECS = INPUT_SPECS + RUNTIME_SPECS
