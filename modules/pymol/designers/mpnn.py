"""ProteinMPNN via proteinmpnn-mlx: on-device inverse folding in Swift/MLX.

The method Design mode has run in-process since Phase 2a, given a command surface and a
set-delivery path (#453). NOTHING HERE IS A SECOND IMPLEMENTATION: the request is handed
to `MPNNJobManager`, which calls the same `MPNNModel.design` and `MPNNModel.score` the
Design panel calls, and reads the per-residue arrays back through the same
`DesignColor.scores`.

WHAT IT PRODUCES, AND WHAT IT DOES NOT. A sequence, and two per-residue numbers about the
model's own distribution. It does not say the sequence folds -- ProteinMPNN has no
structure head and no confidence head. The honest test is a refold, which is the next
link in the chain: `predict <predictor>, set:<child>@all`.

WEIGHTS SHIP INSIDE THE APP. `MPNN.mpnnpack` is a bundle resource (MPNNGate.packURL), not
a download, so `weight_bundle` is None and no run can be gated on a fetch. That is the one
structural difference from every other method here, and it is why this module has no
`WeightBundle` and `designing_sequences` has no deferred-job path.

ONE JOB PER BACKBONE, N SEQUENCES OUT. MPNN samples N sequences from one encoder pass, so
a job per sequence would re-run the encoder N times for nothing. The result file therefore
carries a LIST -- see `designing_sequences.deliver_result`, which is the reader of the
contract this module writes.

MEASURED COST. Design mode's own interactive use is the measurement: a click on a
~100-residue region returns in well under a second on an M3 Pro, which is why there is no
progress tray card per sequence and why `MAX_SEQUENCES` is a foot-gun bound rather than a
time budget. A backbone's cost grows with its residue count; `DesignSizeGuard` at the far
end refuses one too large for this machine before any GPU work.
"""
from .base import BackboneSpec, SequenceDesigner, require_designable
from .metrics import DESIGN_SEQUENCE_SPECS
from ..predictors import host
from ..predictors.errors import PredictionInputError, PredictionOptionError

#: The backend the Swift host must dispatch to, as it appears on the wire. A request with
#: NO runtime key is read as `boltz` at the far end, so a designer that forgot to send
#: this would be handed to Boltz's featurizer -- which does not fail, it folds the empty
#: chain list.
RUNTIME = 'mpnn'

#: Ceiling on sequences per backbone. A foot-gun bound, not a measured one: sampling is
#: sub-second per sequence, and the cost of 32 is seconds. It exists so a typo in
#: `n_sequences` cannot ask for a hundred thousand entries in a set.
MAX_SEQUENCES = 32

#: Ceiling on backbone residues. `DesignSizeGuard` at the far end is the exact refusal --
#: it fits a measured per-residue cost to this machine's own free memory and refuses
#: before touching the GPU. This is the friendly half of the same rule, and it refuses
#: here so a 1000-member batch does not submit 1000 jobs that are all refused one by one.
MAX_RESIDUES = 2000

#: Sampling temperature bounds. 0 is legal and means greedy argmax -- worth keeping,
#: because it is the only setting that makes a run reproducible residue for residue, and
#: it is also the setting that makes `n_sequences=8` eight copies of one sequence.
MIN_TEMPERATURE = 0.0
MAX_TEMPERATURE = 2.0


class MPNNDesigner(SequenceDesigner):

    id = 'mpnn'
    name = 'ProteinMPNN (MLX)'

    #: None: the pack is a bundle resource. See the module docstring.
    weight_bundle = None

    #: `omit` is a string of one-letter codes disallowed at EVERY position. One global
    #: list rather than MPNNModel's per-position `omit`, because `omit=C` -- keep
    #: cysteines out of a designed binder so it cannot form a stray disulfide -- is the
    #: form the flow actually reaches for, and a per-position table has no command-line
    #: spelling worth having.
    option_defaults = {'seed': 0, 'temperature': 0.1, 'n_sequences': 1, 'omit': ''}

    metric_specs = DESIGN_SEQUENCE_SPECS

    #: One band. Sampling is the whole run: there is no featurizer worth a phase (the
    #: backbone arrives as an array) and the pack load is a one-time read the second job
    #: does not pay. The runtime reports a step per finished sequence, so this is real
    #: motion rather than a guess.
    progress_phases = (
        ('design', 0.00, 1.00),
        ('done',   1.00, 1.00),
    )

    def check_available(self):
        host.require_available(self.id)
        # After require_available, because the two failures have different remedies:
        # "you are running headless" versus "this build of RayMol does not carry that
        # backend". The iOS build advertises `boltz` alone, so this is also what keeps
        # the command off a phone without a platform test here.
        host.require_runtime(self.id, RUNTIME)

    def parse_backbone(self, backbone, name='', fixed=(), source='', state=1):
        """Validate a backbone read out of the session or out of a set entry.

        Every refusal is one the runtime would make later or not at all. An empty
        backbone in particular does not fail at the far end -- it returns an empty
        sequence, which lands as an entry that looks like a result.
        """
        residues = list(backbone.get('residues') or ())
        if len(residues) > MAX_RESIDUES:
            raise PredictionInputError(
                '%d residues is over the %d-residue limit for one backbone. The exact'
                ' limit for this machine is applied by the runtime, which refuses'
                ' before touching the GPU; this one refuses before a batch submits a'
                ' job per member.' % (len(residues), MAX_RESIDUES))
        for index in fixed or ():
            if not 0 <= int(index) < len(residues):
                raise PredictionInputError(
                    'fixed position %d is outside the %d-residue backbone'
                    % (int(index), len(residues)))
        spec = BackboneSpec(residues, name=name, designer_id=self.id, fixed=fixed,
                            source=source, state=state)
        require_designable(spec)
        return spec

    def validate_options(self, options):
        opts = SequenceDesigner.validate_options(self, options)
        if not 1 <= opts.n_sequences <= MAX_SEQUENCES:
            raise PredictionOptionError(
                'n_sequences must be between 1 and %d, got %d'
                % (MAX_SEQUENCES, opts.n_sequences))
        if not MIN_TEMPERATURE <= opts.temperature <= MAX_TEMPERATURE:
            raise PredictionOptionError(
                'temperature must be between %g and %g, got %g'
                % (MIN_TEMPERATURE, MAX_TEMPERATURE, opts.temperature))
        unknown = sorted(set(opts.omit) - set('ACDEFGHIKLMNPQRSTVWY'))
        if unknown:
            raise PredictionOptionError(
                'omit takes one-letter amino-acid codes; %s %s not one'
                % (', '.join(unknown), 'is' if len(unknown) == 1 else 'are'))
        return opts

    def submit(self, spec, options, weights_path):
        # The backbone travels as a PATH, unlike a generator's target which is inlined.
        # Two reasons, and the second is the one that decides it:
        #
        # Size: a 2000-residue backbone is a few hundred kilobytes of JSON, and it is
        # already being written to a file by the enumeration step either way.
        #
        # ONE PARSER. The file is byte-identical in shape to what
        # `raymol_design.enumerate_design_residues` writes, which is what Design mode's
        # `DesignResidueSet.parse(jsonAt:)` already reads. Inlining it would mean a
        # second decoder at the far end, and two decoders of one array is two chances to
        # disagree about which residue is index 7 -- the index `fixed_positions` and
        # every returned array are resolved against.
        backbone_path = _write_backbone(spec)
        extra = {
            'backbone_path': backbone_path,
            'fixed_positions': list(spec.fixed),
        }
        # `result_suffix='json'`: the result is N sequences and their per-residue
        # arrays, which is a document, not a structure. Everything downstream --
        # `predict_result`, the Swift `loadResult` -- takes the path off the handle, so
        # naming it here is the whole change.
        return host.submit(spec, options, weights_path or '', runtime=RUNTIME,
                           knobs=('seed', 'temperature', 'n_sequences', 'omit'),
                           extra=extra, input_paths=[backbone_path],
                           result_suffix='json')


def _write_backbone(spec):
    """Write the backbone array beside the request and return its path.

    Written BEFORE the request that names it, for the reason `host.submit` writes an a3m
    first: the host reads on its next 100 ms tick, so a request naming a half-written
    file is the one ordering bug available here.

    `host._path` and `host._write` rather than local copies, so the temp-file naming and
    the write-then-rename stay in one place -- the same place that knows how a job's
    files are cleaned up.
    """
    import json
    import uuid
    path = host._path('backbone', uuid.uuid4().hex[:12], 'json')
    host._write(path, json.dumps({'object': spec.source, 'state': spec.state,
                                  'residues': spec.residues}))
    return path
