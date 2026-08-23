"""What a backbone generator measures, declared once (#308).

These are GEOMETRY, not confidence. A generator has no confidence head: RFdiffusion3's
sampler emits coordinates and a sequence, and nothing in it predicts how right they are.
So none of `plddt`, `pae`, `min_ipsae` appears here, for exactly the reason
`Predictor.supports_msa` is False by default -- a caller that finds `min_ipsae` in the
schema is entitled to conclude the tool can produce it, and the whole point of the
refold step that is NOT in this issue is that generation alone cannot.

What IS here is a screening aid, and the distinction matters enough to say twice: a
design whose backbone bonds are all in range and whose chain sits 3 A from the target is
geometrically sane, which is not the same as designable. The honest test is a refold.

The scopes follow from what varies. `design_length` is object-scope -- it is a property
of what was asked for, identical for every state of the object. Every geometry number is
state-scope, because a state is one set of coordinates and that is what geometry is
measured on.
"""
from pymol.metrics.schema import MetricSpec, OBJECT, STATE

from ..predictors.metrics import INPUT_SPECS, RUNTIME_SPECS

#: The shared input facts that apply to a generator. `msa_depth` is filtered out rather
#: than re-declared without it: taking the tuple and dropping one key keeps `n_residues`
#: and `n_chains` -- their labels, descriptions and scopes -- identical to a
#: prediction's, so the two are comparable in the same panel, and a later edit to those
#: descriptions cannot drift between the two packages.
SHARED_INPUT_SPECS = tuple(spec for spec in INPUT_SPECS if spec.key != 'msa_depth')

#: What was ASKED FOR, as opposed to what came back. Object-scope provenance that a
#: reader needs in order to interpret the geometry below: an interface distance means
#: something different for a 40-residue design than for a 120-residue one.
DESIGN_INPUT_SPECS = (
    MetricSpec('design_length', OBJECT, dtype='int', units='residues',
               label='Designed residues',
               description='Length of the generated chain. The target is the rest of'
                           ' the object and is held fixed.'),
    MetricSpec('design_target_residues', OBJECT, dtype='int', units='residues',
               label='Target residues',
               description='Residues of the target the design was conditioned on --'
                           ' the selection as the engine read it, after non-standard'
                           ' residues and alternate locations were excluded.'),
    MetricSpec('design_hotspots', OBJECT, dtype='int', units='residues',
               label='Hotspots',
               description='Interface residues of the target the design was directed'
                           ' at. They set the sampler origin, so they change the'
                           ' result rather than only scoring it.'),
    MetricSpec('design_chain', OBJECT, dtype='str', label='Designed chain',
               description='Chain id of the generated chain in this object. The rest is'
                           ' the target, held fixed. Recorded rather than assumed'
                           ' because computing refold-versus-design RMSD later means'
                           ' knowing which chain the design is.'),
    MetricSpec('design_key', OBJECT, dtype='str', label='Design key',
               description='Stable identity of this design: the generator, the weight'
                           ' pack, the target residues and their coordinates, the'
                           ' hotspots, the length, the seed and the sampler schedule.'
                           ' A later refold of this design carries the same key, which'
                           ' is what makes refold-vs-design RMSD computable without'
                           ' guessing which design a prediction came from.'),
)

#: What the run MEASURED about the coordinates it produced. Every one of these comes out
#: of the runtime, which is the only place the coordinates exist while it is running.
GEOMETRY_SPECS = (
    MetricSpec('design_ca_ca_mean', STATE, units='A', label='Designed CA-CA mean',
               lo=3.0, hi=4.5,
               description='Mean distance between consecutive CA atoms of the designed'
                           ' chain. An ideal peptide is 3.80 A; a sampler that has not'
                           ' converged reads low.'),
    MetricSpec('backbone_valid_pct', STATE, units='%', label='Backbone bonds in range',
               lo=0, hi=100, higher_is_better=True,
               description='Percentage of consecutive CA-CA distances inside'
                           ' [3.6, 4.0] A. The bond-length sanity check, not a'
                           ' designability score.'),
    MetricSpec('design_radius_of_gyration', STATE, units='A',
               label='Designed chain radius of gyration',
               description='Compactness of the designed chain, over its CA atoms. A'
                           ' number far above what its length implies is an extended'
                           ' or unfolded sample.'),
    MetricSpec('interface_min_distance', STATE, units='A', label='Interface distance',
               description='Closest CA-CA approach between the designed chain and the'
                           ' target. NEITHER DIRECTION IS BETTER: around 4-6 A is'
                           ' contact, far above that is a chain floating off the'
                           ' surface, and far below it is a clash. Deliberately'
                           ' declares no `higher_is_better`, so nothing sorts or'
                           ' colours it as though one end were good.'),
    MetricSpec('contacts_under_8a', STATE, dtype='int', units='pairs',
               label='CA pairs within 8 A', higher_is_better=True,
               description='Designed-chain CA to target CA pairs closer than 8 A -- how'
                           ' much surface the design actually engages, rather than'
                           ' whether it touches at all.'),
    MetricSpec('hotspot_min_distance', STATE, units='A', label='Hotspot distance',
               higher_is_better=False,
               description='Closest approach from the designed chain to any hotspot CA.'
                           ' This is the one number that says whether the design went'
                           ' where it was aimed: a geometrically fine design docked on'
                           ' the far side of the target reads large here.'),
    MetricSpec('target_drift_max', STATE, units='A', label='Target drift',
               lo=0, higher_is_better=False,
               description='Largest movement of any target atom from where it was'
                           ' supplied. The contract is that the target is HELD FIXED,'
                           ' so this is 0.000 A on a correct run and a bug -- not a'
                           ' quality signal -- on any other.'),
)

#: The set a geometry-only generator declares.
DESIGN_SPECS = (SHARED_INPUT_SPECS + DESIGN_INPUT_SPECS + RUNTIME_SPECS
                + GEOMETRY_SPECS)

#: Runtime metric key -> the `Stats` field it comes from, as RFD3Kit spells it. The
#: renaming is not cosmetic: the engine's field names say "binder", and by the naming
#: rule in `generators/base` nothing RayMol shows a user may. Keeping the mapping as
#: data rather than in the translating code means the two vocabularies are written down
#: side by side exactly once, where a mismatch is visible.
STATS_FIELDS = (
    ('design_ca_ca_mean', 'binderCACAmeanA'),
    ('backbone_valid_pct', 'backboneValidPct'),
    ('design_radius_of_gyration', 'radiusOfGyrationA'),
    ('interface_min_distance', 'interfaceMinA'),
    ('contacts_under_8a', 'contactsUnder8A'),
    ('hotspot_min_distance', 'binderToHotspotMinA'),
    ('target_drift_max', 'targetDriftMaxA'),
)
