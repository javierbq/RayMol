"""What a sequence designer measures, declared once (#308, #453).

THE SINGLE DECLARATION OF THE `mpnn` SCHEMA. `raymol_design.py` -- Design mode's UI
plumbing -- used to declare `native_fit` and `certainty` here-equivalent inline and
register them under the same tool id with `replace=True`. Two registrations of one tool
id with different spec sets is last-one-wins: whichever module imported second decided
whether the object-scope columns below existed. So the tuple lives here and
`raymol_design` imports it, which makes the two registrations identical rather than
ordered.

WHAT IS MEASURED, AND WHAT IS NOT. ProteinMPNN has no confidence head and makes no claim
that a sequence folds: `certainty` is the sharpness of its own distribution and
`native_fit` is how well the residue present fits the backbone. Neither is a designability
score, and the honest test of a designed sequence is a refold -- which is what
`predict set:<child>` is for.

The scopes follow from what varies. The residue arrays are per RESIDUE, indexed by
(chain, resi) over the backbone the sequence was threaded onto. Their summaries and the
recovery are per OBJECT: they are properties of one designed sequence, which is one
entry, and a sequence entry has no coordinates and therefore no states to vary over.
"""
from pymol.metrics.schema import MetricSpec, OBJECT, RESIDUE

from ..predictors.metrics import RUNTIME_SPECS

#: The two per-residue arrays Design mode already draws. The domains are
#: `DesignColor.nativeFitDomain` and `.certaintyDomain`, kept in step with the Swift
#: legend so a stored array colours the way the live panel did.
#:
#: Written as ARRAYS rather than as a per-residue column so #419's heat strips can draw
#: them under a row without a query per residue.
RESIDUE_SPECS = (
    MetricSpec('native_fit', RESIDUE, units='log P', label='Native fit',
               lo=-6.0, hi=0.0, higher_is_better=True, summarizes='mean',
               description='Log-probability MPNN assigns to the residue actually'
                           ' present, scored leave-one-out against the backbone.'),
    MetricSpec('certainty', RESIDUE, label='Certainty', lo=0.0, hi=1.0,
               higher_is_better=True, summarizes='mean',
               description='1 - Shannon entropy / ln(21) over the 21-letter'
                           ' distribution: 0 is flat, 1 is one-hot.'),
)

#: One designed sequence, summarised. Written BESIDE the arrays rather than derived from
#: them, for the reason `metrics.schema.SUMMARY_RULES` gives: a summary the store computed
#: and an array the runtime wrote could disagree about which residues were included, and
#: `summarizes` is advisory on purpose.
SEQUENCE_SPECS = (
    MetricSpec('sequence_recovery', OBJECT, label='Native recovery', lo=0.0, hi=1.0,
               summarizes='mean',
               description='Fraction of DESIGNED positions whose letter matches the'
                           ' backbone\'s own. Deliberately declares no'
                           ' `higher_is_better`: recovering the native sequence is a'
                           ' sanity signal on a natural backbone and a null result on a'
                           ' generated one, where there is no native to recover.'),
    MetricSpec('mean_native_fit', OBJECT, units='log P', label='Mean native fit',
               lo=-6.0, hi=0.0, higher_is_better=True,
               description='Mean of `native_fit` over the scored residues of this'
                           ' sequence. Masked residues are absent, not zero.'),
    MetricSpec('mean_certainty', OBJECT, label='Mean certainty', lo=0.0, hi=1.0,
               higher_is_better=True,
               description='Mean of `certainty` over the scored residues of this'
                           ' sequence.'),
    MetricSpec('temperature', OBJECT, label='Sampling temperature', lo=0.0,
               description='What this sequence was sampled at. 0 is greedy argmax, so'
                           ' every sequence of a run at 0 is the same sequence --'
                           ' recorded because it is the knob that decides whether a'
                           ' batch of N is N results or one repeated N times.'),
)

#: The set a sequence designer declares. `RUNTIME_SPECS` comes in whole, as a
#: generator's does, so inference time and peak memory read the same in the drawer
#: whichever tool wrote the row.
#:
#: `INPUT_SPECS` deliberately does NOT: `n_residues` and `n_chains` are fields of the
#: entries row that the store computes from what it is given, and declaring them as
#: columns as well is the collision #416 found (`binding._reserved_column`).
DESIGN_SEQUENCE_SPECS = RESIDUE_SPECS + SEQUENCE_SPECS + RUNTIME_SPECS
