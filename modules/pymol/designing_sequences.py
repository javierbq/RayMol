"""Sequence design: cmd.design_sequences and friends (#453).

Thin by design, as `predicting.py` is: argument marshalling and session interaction only.
The registry and the methods live in `pymol.designers`, and the set delivery is
`pymol.sets.batch`, shared with `binder_design` and `predict`.

WHY A THIRD COMMAND MODULE. `predicting` owns objects that fill with coordinates and
`designing` owns objects that fill with a design; this one owns NEITHER. A designed
sequence has no object at any point -- it is a row in a set, or a line printed at the
console -- so every table here is keyed by a JOB KEY that need not name anything in the
session, and nothing in this module creates, deletes or loads an object. Sharing
`designing`'s tables would have meant `discard_pending` reaching for an object that was
never a placeholder and deleting the user's own backbone.

Every function ends its signature with _self=cmd. That is load-bearing: pymol2/cmd2.py
binds _self only when it appears in the argspec, and otherwise copies the function
verbatim so it silently drives the GLOBAL instance.

Spec: docs/superpowers/specs/2026-09-16-sets-sequence-design-design.md
"""
import sys

from . import colorprinting
from .designers import base as designer_base, registry
from .predictors.errors import PredictionInputError, PredictionOptionError

cmd = sys.modules["pymol.cmd"]

#: job_id -> the handle the designer returned.
_JOBS = {}

#: job key -> a FIFO of the jobs outstanding under it, oldest first. The job key is the
#: name the runtime echoes back to `deliver_result`, and the key of everything here. For
#: the OBJECT path it is the object's own name; for the set path it is the parent entry's
#: name, moved aside if the session or another live key already answers to it. Nothing
#: here ever creates an object under it: unlike `predicting._PENDING`, this is not a
#: placeholder table.
#:
#: A LIST OF RECORDS, not a mode plus a list of ids, and that is what the #453 review
#: found. Each record is
#:
#:     {'job_id': str,
#:      'members': [member name, ...],       # set path; empty for the object path
#:      'batch_id': str,                     # set path
#:      'object': {'object', 'state', 'designer'} or None}   # object path
#:
#: Two jobs can genuinely share a key -- `design_sequences mpnn, bb` twice before the
#: first lands is what a seed sweep from a script does, because the command returns a
#: handle immediately -- and side tables keyed by name alone lost the second result
#: silently. Worse, a set batch pending under the key `ent` and an object called `ent`
#: (which is exactly what `set_stage` creates: staged objects are named after their
#: entry) put the set job's sequences through the OBJECT path, recording them as metric
#: runs against an unrelated structure and reaping the child set to nothing.
#:
#: FIFO because the runtime's queue is serial per manager: the job submitted first is the
#: job that reports first.
_PENDING = {}

#: Child-set names this session has opened a batch under, LIVE OR SETTLED.
#:
#: Retained after the batch is over so `design_sequences_cancel <child set>` answers
#: quietly instead of raising "unknown sequence-design job" -- pressing Cancel as the
#: last member settles is a race the user cannot avoid, which is what the command's own
#: docstring promises. Bounded by the number of set-driven invocations in a session, so
#: a handful of strings; cleared with the pending table.
_BATCH_IDS = set()

#: Upper bound for a randomly chosen seed. Below 2**53 so the value survives a JSON
#: round-trip through a Double on the Swift side.
RANDOM_SEED_BOUND = 2 ** 32


def job_ids():
    """Ids of jobs this module is still tracking."""
    return sorted(_JOBS)


def pending_objects():
    """Job keys with a job outstanding. Named for the panel contract it shares with
    `predicting`/`designing`, though nothing here is an object."""
    return sorted(_PENDING)


def _sets_batch():
    """The `pymol.sets.batch` module, or None if the set store cannot be imported.
    Lazy, for the import-order reason `designing._sets_batch` gives."""
    try:
        from pymol.sets import batch
        return batch
    except Exception:
        return None


def _settle_members(record):
    """Tell the set batch that every member of this job left the run without landing.
    Idempotent; a member that already landed is untouched."""
    sb = _sets_batch()
    if sb is None or record is None:
        return
    for member in record.get('members') or ():
        try:
            sb.settle(member)
        except Exception:
            pass


def register_pending(key, job_id, members=(), batch_id='', on_object=None):
    """Remember what `key` is waiting for. Creates nothing in the session."""
    _PENDING.setdefault(key, []).append({
        'job_id': str(job_id),
        'members': list(members),
        'batch_id': str(batch_id or ''),
        'object': dict(on_object) if on_object is not None else None,
    })


def _take_pending(key):
    """Pop and return the OLDEST job outstanding under `key`, or None.

    The key goes when its last job does, so `pending_objects()` stops naming it -- but
    not before, or a second job under the same key would be delivered as if it had never
    been registered (#453 review, finding 2).
    """
    queue = _PENDING.get(key)
    if not queue:
        return None
    record = queue.pop(0)
    if not queue:
        _PENDING.pop(key, None)
    return record


def discard_pending(name, _self=cmd):
    """Forget the oldest job outstanding under `name`: it failed, was cancelled, or was
    dismissed.

    Called by the Swift shell's `InferenceJob.discardPlaceholder` on every terminal
    status that is not a delivery. It DELETES NOTHING, and that is the difference from
    its namesakes: the key may be the name of the user's own backbone object, and
    `designing.discard_pending`'s "delete it if it has no atoms" would be a loaded gun
    pointed at it.

    ONE job, not the whole key: two jobs can share a key, and retiring both on the first
    terminal status is how the second one's result used to be dropped in silence.
    """
    _settle_members(_take_pending(str(name)))


def clear_pending(_self=cmd):
    """Drop every pending job. For `reinitialize` and tests."""
    for name in list(_PENDING):
        while name in _PENDING:
            discard_pending(name, _self=_self)
    _PENDING.clear()
    _BATCH_IDS.clear()


def _job(job_id):
    try:
        return _JOBS[job_id]
    except KeyError:
        raise PredictionInputError('unknown sequence-design job %r' % job_id)


# -- Reading a backbone out of the session or out of a set ---------------------


def _one_object(source, _self=cmd):
    """The single object `source` selects, or a refusal naming what it found instead."""
    try:
        objects = _self.get_object_list('(%s)' % source) or []
    except Exception as exc:
        raise PredictionInputError('%s is not a selection this session can resolve (%s)'
                                   % (source, exc))
    if len(objects) != 1:
        raise PredictionInputError(
            '%s must name exactly one object to design on, not %d (%s). A sequence is'
            ' designed against ONE backbone; two objects would be two runs.'
            % (source, len(objects), ', '.join(objects) or 'none'))
    return str(objects[0])


def _positions_of(backbone, selection, obj, what, _self=cmd):
    """POSITIONS in `backbone['residues']` that `selection` covers, within `obj`.

    Positions, not residue numbers: the model identifies a residue purely by where it is
    in the array it was handed, so this is the one translation that has to happen on this
    side and happen once.
    """
    keys = set()
    try:
        _self.iterate('(%s) and (%s) and polymer and guide' % (obj, selection),
                      'keys.add((chain, resi))', space={'keys': keys})
    except Exception as exc:
        raise PredictionInputError('%s=%s is not a selection this session can resolve'
                                   ' (%s)' % (what, selection, exc))
    return [index for index, residue in enumerate(backbone['residues'])
            if (residue['chain'], residue['resi']) in keys]


def _held_positions(backbone, source, fixed, obj, _self=cmd):
    """The positions to hold at their native identity: everything OUTSIDE `source`, plus
    whatever `fixed` names inside it.

    THE SOURCE SELECTION IS THE REGION TO REDESIGN, which is what Design mode means by a
    region and therefore what `design_sequences mpnn, sele` has to mean too. Naming the
    whole object designs the whole object, because then nothing is outside it. Without
    this, a narrower selection would resolve to its object and silently redesign every
    residue in it -- a different answer from the one the panel gives for the same picks.

    `fixed` is the second knob rather than the only one because the two questions are
    different: `source` says what is being designed, `fixed` pins residues inside it that
    must not move (a catalytic triad, a motif).
    """
    residues = backbone['residues']
    held = set(_positions_of(backbone, fixed, obj, 'fixed', _self=_self)
               if str(fixed or '').strip() else ())
    region = set(_positions_of(backbone, source, obj, 'source', _self=_self))
    if not region:
        # Said HERE rather than left to `require_designable`, whose message ("every one
        # of the N residues is either fixed or missing a backbone atom") describes a
        # backbone problem when the real one is that the selection landed on nothing
        # designable -- a ligand, a water, an empty `sele`.
        raise PredictionInputError(
            '%s selects no polymer residue of %s that can be designed. A residue is'
            ' designable when it is protein and has all of N, CA, C and O; a ligand,'
            ' a nucleic acid or an empty selection leaves nothing to redesign.'
            % (source, obj))
    if len(region) < len(residues):
        held |= set(range(len(residues))) - region
    return sorted(held)


def _entry_backbone(container, entry, scratch, _self=cmd):
    """The backbone of one set entry, read by loading its chains into a scratch object.

    A set entry's coordinates live in the container as CIF blobs, not in the session, so
    there is no way around loading them. The scratch object is deleted before this
    returns, whatever happens -- an entry left behind would show up in the object panel
    and in any .pse saved afterwards.
    """
    from pymol.sets import binding
    if not container.chain_cifs(entry['id']):
        raise PredictionInputError(
            'entry %s has no structure to design against (a sequence-only entry cannot'
            ' be redesigned; fold it first with `predict`)' % entry['name'])
    try:
        binding._load_entry_into(container, entry, scratch, _self=_self)
        return designer_base.read_backbone(scratch, 1, _self=_self)
    finally:
        try:
            _self.delete(scratch)
        except Exception:
            pass


def _free_key(name, _self=cmd):
    """`name` moved aside (`_2`, `_3`, ...) while an object or another live job key
    answers to it.

    Both axes matter. An OBJECT of that name is avoided because the object path keys on
    the object's own name, and `set_stage` names a staged object after its entry -- so a
    set batch keyed on entry `ent` and a later `design_sequences mpnn, ent` would collide
    on exactly the name the drawer creates. A live KEY is avoided because the key is what
    the runtime echoes back; two jobs may legitimately queue under one (see `_PENDING`),
    but only when the user asked for that, never because this function handed out a name
    that was already spoken for.
    """
    base = _self.get_legal_name(str(name))
    candidate, n = base, 1
    while candidate in _PENDING or candidate in (_self.get_names('all') or []):
        n += 1
        candidate = _self.get_legal_name('%s_%d' % (base, n))
    return candidate


# -- The command surface -------------------------------------------------------


def design_sequences(designer, source, name='', n_sequences=1, temperature=0.1,
                     seed=None, fixed='', omit='', quiet=1, _self=cmd):
    """
DESCRIPTION

    "design_sequences" designs new sequences for a backbone, with a registered
    inverse-folding method. It returns a job handle (or a list of them); poll with
    "design_sequences_status".

    Given an OBJECT or a SELECTION it does what Design mode does, at the console: it
    samples n_sequences for the region, prints them, and records each one's
    per-residue native fit and certainty against the object so "metrics_color mpnn,
    certainty" can draw them. The selection IS the region -- residues of the object
    outside it are held at their current identity, which is what a region means in
    the panel -- so "design_sequences mpnn, myobj" redesigns everything and
    "design_sequences mpnn, sele" redesigns only what you picked.

    Given a SET or a VIEW it designs every selected entry and writes a CHILD SET of
    sequences -- one entry per designed sequence, each pointing back at the backbone
    it came from, all sharing one run. That is the middle link of a campaign:

        binder_design rfd3, 4HHB, sele, n_designs=1000
        set_filter rfd3_batch_1, starred
        design_sequences mpnn, set:rfd3_batch_1@starred, n_sequences=8
        predict boltz2, set:mpnn_1@all

    WHAT COMES BACK IS A SEQUENCE, NOT A BINDER, AND NOT A FOLD. The two numbers
    recorded per residue describe the model's own distribution over letters; neither
    says the sequence folds to the backbone it was designed for. The honest test is
    the refold on the last line above.

USAGE

    design_sequences designer, source [, name [, n_sequences [, temperature
        [, seed [, fixed [, omit ]]]]]]

ARGUMENTS

    designer = str: id of a registered sequence designer, e.g. mpnn

    source = str: an atom selection inside ONE object -- the REGION to redesign,
    with the rest of that object held fixed -- or "set:<name>" /
    "set:<name>@<selector>" to design every selected entry of a set. The selector
    defaults to "filtered" -- the set's active filter in its active sort.

    name = str: the child set's name, for a set input. Refused if a set, an object or
    a running batch already answers to it. Ignored for an object input, which writes
    no set {default: <designer>_<n>}

    n_sequences = int: sequences to sample per backbone {default: 1}

    temperature = float: sampling temperature. 0 is greedy argmax, which makes every
    sequence of a run identical -- so n_sequences > 1 at 0 is N copies, not N
    results {default: 0.1}

    seed = int: the seed of the FIRST sequence; the rest follow from it. Random when
    omitted, and the value used is recorded on every entry {default: random}

    fixed = str: atom selection for residues to hold at their current identity
    INSIDE the region -- a catalytic triad, a motif that must not move. Everything
    outside `source` is already held {default: ''}

    omit = str: one-letter codes to disallow at every position, e.g. "C" to keep
    cysteines out of a design {default: ''}

NOTES

    The console command has no working-copy concept: inside a Design-mode EDIT session
    the panel's focus is `<obj>_designNN`, and this designs whatever object the
    selection resolves to. Name the working copy if that is what you mean.

SEE ALSO

    design_sequences_status, design_sequences_cancel, predict, binder_design
    """
    designer_obj = registry.get(designer)
    designer_obj.check_available()

    from .predicting import is_set_input
    if is_set_input(source):
        return _design_set(designer_obj, source, name=name, n_sequences=n_sequences,
                           temperature=temperature, seed=seed, fixed=fixed, omit=omit,
                           quiet=quiet, _self=_self)

    obj = _one_object(source, _self=_self)
    state = max(1, int(_self.get_state() or 1))
    backbone = designer_base.read_backbone(obj, state, _self=_self)
    spec = designer_obj.parse_backbone(
        backbone, name=obj, source=obj, state=state,
        fixed=_held_positions(backbone, source, fixed, obj, _self=_self))
    options = _resolve_options(designer_obj, n_sequences, temperature, seed, omit)

    job = designer_obj.submit(spec, options, '')
    job.designer_id = designer_obj.id
    _JOBS[job.job_id] = job
    register_pending(obj, job.job_id,
                     on_object={'object': obj, 'state': state,
                                'designer': designer_obj.id,
                                'n_sequences': options.n_sequences})
    if not int(quiet):
        colorprinting.parrot(
            ' design_sequences: job %s submitted, %d sequence%s for %s (%d of %d'
            ' residues designable, seed %d)'
            % (job.job_id, options.n_sequences, '' if options.n_sequences == 1 else 's',
               obj, spec.n_designable, spec.n_residues, options.seed))
    return job


def _resolve_options(designer_obj, n_sequences, temperature, seed, omit):
    """The validated options for one invocation, seed drawn if it was not given.

    A fresh seed per invocation unless one is asked for, so two runs of the same command
    are genuinely different samples -- and the seed used is RECORDED, on every entry and
    in the run row, because a random seed you cannot recover makes a result
    unreproducible.
    """
    if seed is None:
        import random
        seed = random.randrange(RANDOM_SEED_BOUND)
    return designer_obj.validate_options(dict(
        n_sequences=int(n_sequences), temperature=float(temperature), seed=int(seed),
        omit=str(omit or '')))


def _design_set(designer_obj, source, name='', n_sequences=1, temperature=0.1,
                seed=None, fixed='', omit='', quiet=1, _self=cmd):
    """`design_sequences m, set:<name>@<selector>`: design every selected entry into a
    child set of sequences.

    One job per ENTRY and one entry per SEQUENCE (spec §3): the model samples N
    sequences from one encoder pass, so a job per sequence would re-run the encoder N
    times for nothing, while an entry per sequence is what makes every row in the table
    something that can be folded on its own.

    The child set, its run row -- carrying the parent set id, the selector as typed and
    every parent entry id -- and every member exist before the first job is submitted, so
    the inspector's badge has a set to hang off and a crash mid-run leaves a set that
    says what was attempted.
    """
    from pymol.sets import selectors, store as set_store
    from .predicting import parse_set_input
    sb = _sets_batch()
    if sb is None:
        raise PredictionInputError('the set store is not available in this build')
    set_name, selector = parse_set_input(source)
    c = set_store.active()
    parent = c.get_set(set_name)                              # SetNotFound if absent
    entries = selectors.resolve(c, parent, selector)          # SetNotFound / SetInputError
    if not entries:
        raise PredictionInputError('%s selects no entries of %s' % (selector, set_name))
    if str(fixed or '').strip():
        # Refused rather than silently ignored: a selection is resolved against the
        # SESSION, and a set entry is not in the session -- so `fixed` here would mean
        # whichever residues of some staged object happened to match, which is a
        # different set of positions per entry and a different one again tomorrow.
        raise PredictionOptionError(
            'fixed= takes a selection, which only means something for an object input;'
            ' a set entry is not in the session. Stage the entry and design on the'
            ' object if you need to hold residues.')

    options = _resolve_options(designer_obj, n_sequences, temperature, seed, omit)

    # Backbones and specs FIRST, so every refusal -- an entry with no structure, a
    # backbone too large -- costs nothing: no set, no job. Read through one scratch
    # object, deleted after each entry.
    scratch = _self.get_unused_name('_seqdesign_src')
    specs = []
    for entry in entries:
        backbone = _entry_backbone(c, entry, scratch, _self=_self)
        specs.append(designer_obj.parse_backbone(
            backbone, name=entry['name'], source=entry['name'], state=1))

    if name:
        child_name = _self.get_legal_name(str(name))
        if (sb.name_taken(child_name) or child_name in (_self.get_names('all') or [])
                or sb.is_running(child_name)):
            raise PredictionInputError(
                'name=%s is already taken by a set, an object or a running batch;'
                ' pick a free name or leave name= off' % name)
    else:
        child_name = sb.free_numbered_name(designer_obj.id, _self=_self)

    knobs = options.as_dict()
    knobs.pop('seed', None)
    inputs = {'designer': designer_obj.id, 'options': knobs,
              'n_sequences': options.n_sequences, 'seed': options.seed,
              'parent_set': parent['id'], 'selector': selector,
              'parents': [entry['id'] for entry in entries]}
    total = len(entries) * options.n_sequences
    # `kind='sequences'`: these entries have no structure blob until something folds
    # them (store spec §1). `group=False` and `superpose=False` follow from that -- a
    # group holds staged OBJECTS and there are none, ever.
    batch = sb.open(child_name, designer_obj.id, inputs=inputs, total=total,
                    reference=parent.get('reference') or '',
                    parent_set_id=parent['id'], group=False, superpose=False,
                    kind='sequences', _self=_self)
    _BATCH_IDS.add(batch.id)

    jobs = []
    try:
        for entry, spec in zip(entries, specs):
            key = _free_key(entry['name'], _self=_self)
            spec.name = key
            members = []
            for index in range(options.n_sequences):
                member = '%s_s%d' % (key, index + 1)
                entry_name = (entry['name'] if options.n_sequences == 1
                              else '%s_s%d' % (entry['name'], index + 1))
                # BEFORE submit: a member the set refuses must not leave a job running.
                sb.expect(batch, member, entry_name=entry_name,
                          parents=[entry['id']],
                          scalars={'sequence_n': index + 1, 'seed': options.seed},
                          specs=[sb.SEQUENCE_SPEC, sb.SEED_SPEC])
                members.append(member)
            job = designer_obj.submit(spec, options, '')
            job.designer_id = designer_obj.id
            _JOBS[job.job_id] = job
            register_pending(key, job.job_id, members=members, batch_id=batch.id)
            jobs.append(job)
            if not int(quiet):
                colorprinting.parrot(
                    ' design_sequences: job %s submitted, %d sequence%s for %s -> set %s'
                    % (job.job_id, options.n_sequences,
                       '' if options.n_sequences == 1 else 's', entry['name'],
                       child_name))
    except Exception:
        # Nothing of a half-submitted run survives: the jobs already started are
        # cancelled and forgotten, and the set goes if it is empty.
        for job in jobs:
            try:
                job.cancel()
            except Exception:
                pass
            discard_pending(job.spec.name, _self=_self)
        sb.abandon(batch)
        raise
    if not int(quiet):
        colorprinting.parrot(
            ' design_sequences: %d entr%s of %s x %d sequence%s -> set %s'
            % (len(entries), 'y' if len(entries) == 1 else 'ies', set_name,
               options.n_sequences, '' if options.n_sequences == 1 else 's', child_name))
    return jobs


def design_sequences_status(job_id='', quiet=1, _self=cmd):
    """
DESCRIPTION

    "design_sequences_status" reports on running sequence-design jobs.

USAGE

    design_sequences_status [ job_id ]

ARGUMENTS

    job_id = string: one job, or every tracked job when omitted

SEE ALSO

    design_sequences, design_sequences_cancel
    """
    ids = [job_id] if job_id else job_ids()
    out = {}
    for one in ids:
        status = _job(one).status()
        out[one] = status
        if not int(quiet):
            colorprinting.parrot(' design_sequences: %s %s %s %.0f%%'
                                 % (one, status.get('state'), status.get('phase'),
                                    100.0 * float(status.get('fraction') or 0.0)))
    return out


def design_sequences_cancel(job_id, quiet=1, _self=cmd):
    """
DESCRIPTION

    "design_sequences_cancel" stops running sequence-design jobs.

    Cancellation is observed BETWEEN SEQUENCES: one sample is a single synchronous
    forward pass with no cancellation point inside it, so the worst case is one
    sequence. Sequences already delivered stay in the set; if nothing of the batch
    landed at all, the empty child set goes with it.

USAGE

    design_sequences_cancel job_id

ARGUMENTS

    job_id = string: the job to cancel, a pending job key -- which cancels the job
        outstanding for it -- or the CHILD SET'S NAME, which cancels every job of that
        invocation: the one running and the ones still queued behind it.

SEE ALSO

    design_sequences, design_sequences_status
    """
    job_id = str(job_id)
    # A batch first, but only when the name is not itself a job key: a key still means
    # the key.
    was_batch = job_id not in _PENDING and job_id in _BATCH_IDS
    if was_batch:
        ids = [record['job_id'] for queue in _PENDING.values() for record in queue
               if record['batch_id'] == job_id]
    else:
        ids = [record['job_id'] for record in _PENDING.get(job_id) or ()]
    if not ids:
        # A batch id whose last member already settled is NOT an error: pressing Cancel
        # as the batch finishes is a race the user cannot avoid, and the docstring above
        # promises this. Only a name that was never a batch falls through to `_job`,
        # which raises for an id nothing knows.
        if job_id in _BATCH_IDS:
            return job_id
        _job(job_id).cancel()
        ids = [job_id]
    else:
        for one in ids:
            try:
                _job(one).cancel()
            except Exception as exc:
                colorprinting.warning(' design_sequences_cancel: %s (%s)' % (one, exc))
    if not int(quiet):
        colorprinting.parrot(' design_sequences: cancel requested for %s (%d job(s))'
                             % (job_id, len(ids)))
    return job_id


# -- Delivery ------------------------------------------------------------------


def deliver_result(path, name, seed=None, _self=cmd):
    """Read a finished sequence-design job and write what it produced.

    Called by the Swift shell (`InferenceJob.loadResult`) with the job key the request
    carried. `seed` is accepted and ignored: the seed is already on every member's
    columns and in the run row, written at submit, and the runtime's copy of it is the
    same number.

    Nothing here loads a structure, because there is none: for a set job the sequences
    become entries, and for an object job they become metrics runs on the object and
    lines at the console. The pending mark is retired whatever happened, so a malformed
    result cannot leave a job pending forever.
    """
    name = str(name)
    # Popped FIRST, and routed on the RECORD rather than on the name: which path a result
    # takes is a property of the job that produced it, not of what the session happens to
    # contain now. Routing on `name in _ON_OBJECT` sent a set job's sequences to the
    # object path as soon as an object of that name existed -- and `set_stage` creates
    # exactly that object (#453 review, finding 2).
    record = _take_pending(name)
    try:
        document = _read_result(path)
        if record is None:
            raise PredictionInputError(
                'no sequence-design job is outstanding under %r; the result is dropped'
                % name)
        if record['object'] is not None:
            _deliver_on_object(record, document, _self=_self)
        else:
            _deliver_into_set(name, record, document, _self=_self)
    except Exception as exc:
        colorprinting.warning(' design_sequences: %s produced no usable result (%s)'
                              % (name, exc))
    finally:
        # Whatever happened, the members of THIS job have left the run: the ones that
        # landed are already settled by `land_sequence`, and the rest settle here, which
        # is what lets an all-refused batch reap its empty set.
        _settle_members(record)
        _release_inputs(record)


def _release_inputs(record):
    """Poll the finished job's handle once, which is what deletes the files the host only
    needed to READ -- the request JSON and the backbone array.

    `HostJob._discard_inputs` runs off a TERMINAL status, and nothing on this path ever
    polled: `design_sequences` returns a handle and the delivery comes from Swift, so a
    thousand-backbone campaign left a thousand request/backbone pairs in $TMPDIR for the
    whole session. Never raises: temp hygiene must not be why a delivered result warns.
    """
    if record is None:
        return
    job = _JOBS.get(record['job_id'])
    try:
        if job is not None:
            job.status()
    except Exception:
        pass


def _read_result(path):
    """The result document, checked for the two keys everything below reads.

    The keys are a CONTRACT with `MPNNJobManager` (spec §5). Checked by name here so a
    skew reads as "the runtime wrote a document this build does not understand" rather
    than as a KeyError halfway through writing entries.
    """
    import json
    with open(path) as handle:
        document = json.load(handle)
    if not isinstance(document, dict) or 'sequences' not in document:
        raise PredictionInputError(
            'the result document has no `sequences` list (this build expects the'
            ' format in the #453 spec, §5)')
    return document


def _arrays_for(document, record):
    """The per-residue arrays of one designed sequence, as `Container.add_entry` takes
    them. Empty when the runtime wrote none, which is a result without the numbers
    rather than no result.

    The index is the document's, shared by every sequence because they share a backbone.
    A masked residue is None in the values and stays None: absent is not zero -- a
    residue with no backbone was not scored, and writing 0.0 would put a real-looking
    number where there is no measurement.
    """
    from .designers.metrics import RESIDUE_SPECS
    index = [(str(chain), str(resi)) for chain, resi in (document.get('index') or ())]
    if not index:
        return []
    arrays = []
    for spec in RESIDUE_SPECS:
        values = (record.get('arrays') or {}).get(spec.key)
        if values is None or len(values) != len(index):
            continue
        arrays.append({'key': spec.key, 'scope': spec.scope, 'chain': None,
                       'index': index, 'values': list(values),
                       'spec': dict(spec.as_dict(), tool='mpnn')})
    return arrays


def _columns_for(document, record):
    """(scalars, specs) for one designed sequence.

    Cast by the DECLARED spec and declared on the same call that writes them, because a
    set refuses a column it was never told about -- which is right, and which means a
    delivering tool has to hand over both halves together or neither.

    A value the runtime did not measure is simply absent, never 0.0. `elapsed_s` and
    `peak_bytes` describe the JOB, so they are read off the document and shared by every
    sequence it produced.
    """
    from .designers.metrics import SEQUENCE_SPECS
    from .predictors.metrics import RUNTIME_SPECS
    source = dict(record.get('scalars') or {})
    for key in ('elapsed_s', 'peak_bytes'):
        if document.get(key) is not None:
            source.setdefault(key, document[key])
    scalars, specs = {}, []
    for spec in SEQUENCE_SPECS + RUNTIME_SPECS:
        cast = spec.cast(source.get(spec.key))
        if cast is None:
            continue
        scalars[spec.key] = cast
        specs.append(dict(spec.as_dict()))
    # THE SEED THAT PRODUCED THIS SEQUENCE, not the invocation's base seed. Submit
    # registered the base on every member because it is all that is known then; the
    # runtime derives one per sample (`seed &+ index`) and reports it, and an entry whose
    # seed column does not reproduce it is a reproducibility claim that is false. The
    # column is `batch.SEED_SPEC`, already declared by `expect`, so nothing is added to
    # `specs` for it.
    if record.get('seed') is not None:
        try:
            scalars['seed'] = int(record['seed'])
        except (TypeError, ValueError):
            pass
    return scalars, specs


def _sequence_chains(sample):
    """One sample's `{chain: sequence}`, with empty chains dropped -- or `{}` when the
    sample carries no sequence at all, which callers must treat as a refusal.

    The chains are THE PRODUCT. `_read_result` validates only that the document has a
    `sequences` list, so a runtime that wrote records without this key used to land
    entries with `sequences={}`: a complete-looking child set of sequence-less rows that
    the user then hands to `predict` (#453 review, finding 1).
    """
    return {str(chain): str(text) for chain, text in (sample.get('chains') or {}).items()
            if str(text).strip()}


def _ordered_samples(name, document, expected):
    """The document's samples, in the order their `n` says, checked against `expected`.

    `n` is written by the runtime and was previously ignored -- members were zipped with
    samples positionally, so any reordering silently mislabelled every `sequence_n` and
    attached one sample's arrays to another's row. Sorted rather than trusted, then
    verified: 1..len, with no gaps and no duplicates. A document whose `n` values do not
    say that is refused whole rather than landed wrong.
    """
    samples = list(document.get('sequences') or ())
    numbered = [sample.get('n') for sample in samples]
    if all(isinstance(number, int) for number in numbered):
        samples = [sample for _, sample in
                   sorted(zip(numbered, samples), key=lambda pair: pair[0])]
        if sorted(numbered) != list(range(1, len(samples) + 1)):
            raise PredictionInputError(
                'the result numbers its sequences %s, which is not 1..%d'
                % (sorted(numbered), len(samples)))
    if len(samples) > expected:
        colorprinting.warning(
            ' design_sequences: %s returned %d sequences but %d were asked for; the'
            ' extras are dropped' % (name, len(samples), expected))
    elif len(samples) < expected:
        # Said out loud, because the alternative reads as success: a short batch lands
        # fewer rows than the run row promises and nothing else mentions it.
        colorprinting.warning(
            ' design_sequences: %s returned %d sequences of the %d asked for; the rest'
            ' of this backbone is missing from the set' % (name, len(samples), expected))
    return samples[:expected]


def _deliver_into_set(name, record, document, _self=cmd):
    """Write each designed sequence as an entry of its batch's set.

    Members not landed here are settled by the caller, so a runtime that returned fewer
    sequences than were asked for leaves the rest settled-without-landing rather than
    pending forever -- and the batch still reaps, which is what deletes an empty set.
    """
    sb = _sets_batch()
    members = list(record.get('members') or ())
    if sb is None or not members:
        return
    for member, sample in zip(members, _ordered_samples(name, document, len(members))):
        chains = _sequence_chains(sample)
        if not chains:
            # Refused rather than landed empty. The member settles with the rest of the
            # job, so the row is simply absent instead of present and meaningless.
            colorprinting.warning(
                ' design_sequences: %s came back with no sequence; it is not written to'
                ' the set' % member)
            continue
        try:
            scalars, specs = _columns_for(document, sample)
            sb.land_sequence(member, chains, scalars=scalars,
                             arrays=_arrays_for(document, sample), specs=specs,
                             _self=_self)
        except Exception as exc:
            colorprinting.warning(' design_sequences: %s was not written to its set'
                                  ' (%s)' % (member, exc))


def _deliver_on_object(record, document, _self=cmd):
    """Print the designed sequences and record what each one measured, against the
    object they were designed for.

    One metrics run PER SEQUENCE, which is what `raymol_design._record_design_metrics`
    already does for a scored pass: re-designing is a new run rather than an overwrite,
    and that history is the point of a design session.
    """
    where = record['object']
    obj = where.get('object') or ''
    state = int(where.get('state') or 1)
    designer_id = where.get('designer') or 'mpnn'
    index = [(str(chain), str(resi)) for chain, resi in (document.get('index') or ())]
    # Checked ONCE, before anything is written. A false answer suppresses the whole
    # recording rather than just the arrays: the object-scope summaries describe the same
    # run and would be just as wrong against a different structure.
    ours = _object_is_still_the_one(obj, index, _self=_self)
    if not ours:
        colorprinting.warning(
            ' design_sequences: %s is not the structure this run was started against any'
            ' more (a session was loaded, or the object was edited); the %d sequence(s)'
            ' are printed but nothing is recorded against it'
            % (obj, len(document.get('sequences') or ())))
    samples = _ordered_samples(obj, document, where.get('n_sequences')
                               or len(document.get('sequences') or ()))
    for number, sample in enumerate(samples, start=1):
        chains = _sequence_chains(sample)
        if not chains:
            colorprinting.warning(' design_sequences: %s sequence %d came back empty'
                                  % (obj, number))
            continue
        for chain in sorted(chains):
            colorprinting.parrot(' design_sequences: %s sequence %d chain %s: %s'
                                 % (obj, number, chain, chains[chain]))
        # Printed either way: the design took real time and the user has to see it even
        # when nothing can honestly be recorded against the session.
        if ours:
            _record_on_object(obj, designer_id, state, index, sample, number)


def _object_is_still_the_one(obj, index, _self=cmd):
    """True while `obj` is the structure this run was started against.

    IDENTITY, cheaply: the object exists and its designable residues are still the ones
    the result's index names, in the same order. The object path's equivalent of
    `sets.batch._still_ours` -- a `.pse` load mid-flight can put a DIFFERENT structure
    under the same name, and recording a design's per-residue arrays against that would
    colour someone else's protein with numbers measured on this one.

    Never raises: a check that cannot run is not a reason to lose a finished design, so
    a failure here reads as "still ours" and the sequences are still printed.
    """
    try:
        if obj not in (_self.get_names('objects') or []):
            return False
        if not index:
            return True
        keys = []
        _self.iterate('(%s) and polymer and guide' % obj,
                      'keys.append((chain, resi))', space={'keys': keys})
        return [(str(chain), str(resi)) for chain, resi in keys] == list(index)
    except Exception:
        return True


def _record_on_object(obj, designer_id, state, index, sequence, number):
    """One metrics-store run for one designed sequence. Never raises: bookkeeping must
    not be the reason a finished design is lost."""
    try:
        from pymol.metrics import binding as mbinding, store as mstore
        from .designers.metrics import RESIDUE_SPECS, SEQUENCE_SPECS
        values = []
        for spec in RESIDUE_SPECS:
            array = (sequence.get('arrays') or {}).get(spec.key)
            if array is None or not index or len(array) != len(index):
                continue
            # WITH the state: these scores depend on the backbone the sequence was
            # threaded onto, so a design against model 2 of a five-model object is not
            # a statement about model 1.
            values.append(mstore.value(designer_id, spec.key, state=int(state),
                                       index=index, values=list(array)))
        source = dict(sequence.get('scalars') or {})
        # Object-scope summaries only. `elapsed_s` and `peak_bytes` are state-scope and
        # describe the JOB rather than the object, and writing them against a state the
        # user's object happens to have would say this run measured that model.
        for spec in SEQUENCE_SPECS:
            if source.get(spec.key) is not None:
                values.append(mstore.value(designer_id, spec.key,
                                           value=source[spec.key]))
        if not values:
            return None
        return mbinding.record(obj, designer_id, values,
                               inputs={'sequence_n': int(number),
                                       'seed': sequence.get('seed')})
    except Exception as exc:
        colorprinting.warning(' design_sequences: could not record %s sequence %d (%s)'
                              % (obj, number, exc))
        return None
