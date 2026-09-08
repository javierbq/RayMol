"""Everything in the set store that has to ASK THE SESSION (#415).

The one module in `pymol.sets` that imports `cmd`. Four jobs:

  capture   an object (or a file, via the peek object) becomes entries: chains as CIF
            blobs, sequences, and every metrics-store run on it as columns and arrays
  stage     an entry becomes an object in the set's group, superposed on the reference,
            with its metrics written back into the metrics store; unstage reverses it
  peek      one hidden object, `_raymol_peek`, shows an entry without staging it
  session   `save x.raymol` / `load x.raymol`, and what `.pse` save and load do to the
            store (warn, and clear, respectively)

Nothing here is reached by a poll. The Swift side (#417) will read the database itself
and call these through `set_*` commands.
"""
import json
import os
import pickle

from pymol import cmd, colorprinting
from pymol.metrics import binding as mbinding, schema as mschema, store as mstore
from pymol.metrics.errors import MetricError

from . import document, store
from .errors import SetBudgetExceeded, SetInputError, SetNameConflict, SetNotFound

#: The peek object. The leading underscore keeps it out of `get_names('public_objects')`,
#: so the object panel and the sequence rows never see it; `session_save` strips it from
#: a .pse as well, so it cannot come back from a file as a real object.
PEEK = '_raymol_peek'

#: Default stage budget when neither the set nor the container says otherwise. Small on
#: purpose; the structure-count measurements in the MCP notes are the place to read
#: before raising it.
DEFAULT_BUDGET = 6

_SAVING_RAYMOL = False    # suppresses the .pse warning while the container's own blob is built
_LOADING_RAYMOL = False   # tells session_restore not to reset the store


def container():
    return store.active()


# -- Small session helpers ---------------------------------------------------------


def _exists(name, _self=cmd):
    return name in (_self.get_names('all') or [])


def _legal(name, _self=cmd):
    return _self.get_legal_name(str(name))


def _chains(sel, _self=cmd):
    return list(_self.get_chains(sel) or [])


def _chain_sel(obj, chain):
    return '(%s) and chain %s' % (obj, chain if chain else '""')


def _sequence(sel, state, _self=cmd):
    """One-letter sequence of the polymer in `sel`, or ''."""
    try:
        text = _self.get_fastastr('(%s) and polymer' % sel, state) or ''
    except Exception:
        return ''
    return ''.join(line.strip() for line in text.splitlines()
                   if line and not line.startswith('>'))


def _load_cif_text(text, name, _self=cmd):
    _self.load_raw(text, 'cif', name, 0, 1, -1, 1, None, 0)


def _load_chains(chains, obj, _self=cmd):
    """An entry's chain CIFs as ONE object.

    The CIF reader refuses to load into an existing object ("please use 'create' to
    append"), so each chain goes into its own hidden temporary and one `create` merges
    them. `_`-prefixed temporaries stay out of the panel for the instant they exist.
    """
    temps = []
    try:
        for i, (_chain, text) in enumerate(chains):
            temp = '_raymol_chain_%d' % i
            if _exists(temp, _self=_self):
                _self.delete(temp)
            _load_cif_text(text, temp, _self=_self)
            temps.append(temp)
        if _exists(obj, _self=_self):
            _self.delete(obj)
        _self.create(obj, ' or '.join(temps), zoom=0, quiet=1)
    finally:
        for temp in temps:
            if _exists(temp, _self=_self):
                _self.delete(temp)


def _spec_or_none(tool, key):
    """`MetricSpec` for a declared (tool, key), else None. `schema.spec` raises for an
    undeclared tool or key; here absence is a normal case, not an error."""
    try:
        return mschema.spec(tool, key)
    except MetricError:
        return None


def _superpose(obj, ref, _self=cmd):
    """`super` obj onto ref; a failure is a warning, never an error."""
    if not ref or ref == obj or not _exists(ref, _self=_self):
        return False
    try:
        if _self.count_atoms('(%s) and polymer' % obj) == 0 or \
                _self.count_atoms('(%s) and polymer' % ref) == 0:
            return False
        _self.super(obj, ref, quiet=1)
        return True
    except Exception as exc:
        colorprinting.warning(' sets: could not superpose %s onto %s (%s)' % (obj, ref, exc))
        return False


def _group_children(group, _self=cmd):
    """Names whose parent is `group`, or None if unknown. From the session record, for
    the reason designing._group_children gives: `get_object_list` misses zero-atom
    members and answers "empty" for a group that is not."""
    try:
        return [entry[0] for entry in (_self.get_session(partial=1).get('names') or [])
                if entry and len(entry) > 6 and entry[6] == group]
    except Exception:
        return None


# -- Capture: object -> entries ------------------------------------------------------


def _metric_payload(obj, state):
    """(scalars, arrays, specs, runs) from every metrics-store run on `obj` for `state`.

    Object-scope values apply to every state. State-bearing values are taken only when
    they name this state, or name none.
    """
    scalars, arrays, specs, runs = {}, [], [], []
    for run in mstore.runs(object=obj):
        runs.append(run)
        for entry in run.values:
            if entry.state is not None and int(entry.state) != int(state):
                continue
            spec = _spec_or_none(run.tool, entry.key)
            spec_dict = dict(spec.as_dict()) if spec is not None else \
                {'key': entry.key, 'scope': entry.scope, 'dtype': 'float'}
            spec_dict['tool'] = run.tool
            if entry.is_array:
                if entry.chain:
                    spec_dict = dict(spec_dict, chain=entry.chain)
                arrays.append({'key': entry.key, 'scope': entry.scope,
                               'chain': entry.chain, 'index': list(entry.index),
                               'values': list(entry.values), 'spec': spec_dict})
                specs.append(spec_dict)
            else:
                if entry.chain:
                    spec_dict = dict(spec_dict, chain=entry.chain)
                    scalars[(entry.key, entry.chain)] = entry.value
                else:
                    scalars[entry.key] = entry.value
                specs.append(spec_dict)
    return scalars, arrays, specs, runs


def capture_object(set_id, obj, name='', run_id=None, parents=(), states='all',
                   _self=cmd):
    """Add `obj` to a set. One entry per state (`states='all'`) or the current state
    only (`states='current'`). Returns the new entry ids.

    Chains are stored as one CIF blob each, from `get_cifstr`, so a chain shared by many
    entries is one blob. Sequences come from the polymer of each chain. Metrics are the
    metrics store's runs on the object, narrowed to the state.
    """
    if not _exists(obj, _self=_self):
        raise SetNotFound('no object %r' % obj)
    c = container()
    n_states = max(1, int(_self.count_states(obj) or 1))
    if states == 'current':
        cur = int(_self.get_state() or 1)
        state_list = [min(max(cur, 1), n_states)]
    else:
        state_list = list(range(1, n_states + 1))
    base = store.legal_entry_name(name or obj)
    chains = _chains(obj, _self=_self)
    ids = []
    for state in state_list:
        entry_name = base if len(state_list) == 1 else '%s_%d' % (base, state)
        cifs, seqs = [], {}
        for ch in chains:
            sel = _chain_sel(obj, ch)
            try:
                text = _self.get_cifstr(sel, state)
            except Exception as exc:
                raise SetInputError('could not export %s chain %r: %s' % (obj, ch, exc))
            if not text or not text.strip():
                continue
            cifs.append((ch, text))
            seq = _sequence(sel, state, _self=_self)
            if seq:
                seqs[ch] = seq
        scalars, arrays, specs, runs = _metric_payload(obj, state)
        this_run = run_id
        if this_run is None and runs:
            # One set-level run per metrics run id, so provenance is not duplicated
            # per entry: the tool and its inputs are written once and shared.
            first = runs[0]
            this_run = _run_for(c, set_id, first)
        ids.append(c.add_entry(set_id, entry_name, run_id=this_run, sequences=seqs,
                               parents=parents, chains=cifs, scalars=scalars,
                               arrays=arrays, specs=specs))
    return ids


_RUN_MAP = {}   # metrics run id -> set run id, per process


def _run_for(c, set_id, run):
    key = (c.path, set_id, run.id)
    if key not in _RUN_MAP:
        _RUN_MAP[key] = c.add_run(set_id, run.tool, tool_version=run.tool_version,
                                  inputs=run.inputs, note='from metrics run %s' % run.id)
    return _RUN_MAP[key]


def capture_file(set_id, path, name='', run_id=None, parents=(), _self=cmd):
    """Add a structure file to a set by loading it into the peek object and capturing
    that. The one path for files, so a file and an object always yield the same entry."""
    if not os.path.isfile(path):
        raise SetInputError('no such file: %s' % path)
    clear_peek(_self=_self)
    try:
        _self.load(path, PEEK, zoom=0, quiet=1)
    except Exception as exc:
        raise SetInputError('could not read %s: %s' % (path, exc))
    try:
        return capture_object(set_id, PEEK, name=name or document.stem(path),
                              run_id=run_id, parents=parents, _self=_self)
    finally:
        clear_peek(_self=_self)


def capture_folder(set_id, folder, _self=cmd):
    """Every structure file in a folder, plus the sidecar's columns if it has one."""
    c = container()
    files, sidecar = document.scan_folder(folder)
    rows = document.read_sidecar(sidecar) if sidecar else {}
    known = {col['column'] for col in c.columns(set_id) if col.get('column')}
    extra = document.sidecar_columns(rows, known)
    if extra:
        c.declare_columns(set_id, [{'key': col, 'scope': 'object', 'dtype': dtype,
                                    'tool': 'import'} for col, dtype in extra])
    ids = []
    coltypes = {col['column']: col.get('dtype', 'float') for col in c.columns(set_id)
                if col.get('column')}
    for path in files:
        entry_name = document.stem(path)
        new_ids = capture_file(set_id, path, name=entry_name, _self=_self)
        ids.extend(new_ids)
        row = rows.get(entry_name)
        if row and new_ids:
            _apply_sidecar_row(c, new_ids[0], row, coltypes)
    # Sequence-only rows: in the sidecar but with no structure file.
    for entry_name, row in rows.items():
        if any(document.stem(p) == entry_name for p in files):
            continue
        try:
            seqs = json.loads(row.get('sequences') or '{}')
        except ValueError:
            seqs = {}
        eid = c.add_entry(set_id, entry_name, sequences=seqs)
        _apply_sidecar_row(c, eid, row, coltypes)
        ids.append(eid)
    return ids


def _apply_sidecar_row(c, entry_id, row, coltypes):
    fields = {}
    if row.get('starred', '') != '':
        fields['starred'] = int(document.coerce_sidecar_value('bool', row['starred']))
    if row.get('rejected', '') != '':
        fields['rejected'] = int(document.coerce_sidecar_value('bool', row['rejected']))
    for key in ('tags', 'note'):
        if row.get(key):
            fields[key] = row[key]
    if row.get('parents'):
        try:
            parents = json.loads(row['parents'])
        except ValueError:
            parents = [p for p in row['parents'].split('+') if p]
        if isinstance(parents, list):
            fields['parents'] = parents
    if fields:
        c.update_entry(entry_id, **fields)
    for col, dtype in coltypes.items():
        if col in row and row[col] != '':
            c.set_scalar(entry_id, col, document.coerce_sidecar_value(dtype, row[col]))


def capture_fasta(set_id, path, _self=cmd):
    c = container()
    return [c.add_entry(set_id, name, sequences={'A': seq})
            for name, seq in document.read_fasta(path)]


# -- Stage / unstage ------------------------------------------------------------------


def budget(set_row):
    if set_row.get('budget'):
        return int(set_row['budget'])
    raw = container().meta_get('stage_budget', None)
    try:
        return int(raw) if raw not in (None, '') else DEFAULT_BUDGET
    except ValueError:
        return DEFAULT_BUDGET


def _staged(c, set_id, _self=cmd):
    """Entries whose staged object still exists. A link to an object the user deleted
    is cleared here, so a ghost never counts against the budget or blocks a re-stage."""
    present = set(_self.get_names('all') or [])
    live = []
    for e in c.entries(set_id, where='e.staged_object IS NOT NULL'):
        if e['staged_object'] in present:
            live.append(e)
        else:
            c.update_entry(e['id'], staged_object=None, pinned=0)
    return live


def _free_object_name(name, _self=cmd):
    base = _legal(name, _self=_self)
    candidate, n = base, 1
    while _exists(candidate, _self=_self):
        n += 1
        candidate = '%s_%d' % (base, n)
    return candidate


def _ensure_group(group, _self=cmd):
    if group in (_self.get_names('public_group_objects') or []):
        return
    if _exists(group, _self=_self):
        raise SetNameConflict('%r is an object, not a group; rename the set or the object'
                              % group)
    _self.group(group, quiet=1)


def _write_back_metrics(c, entry, obj, _self=cmd):
    """The entry's columns and arrays as metrics-store runs on the staged object, one run
    per tool this build declares. Undeclared tools and keys are skipped: the numbers stay
    in the set, they just cannot colour an object here."""
    columns = c.columns(entry['set_id'])
    array_tool = {col.get('key'): col.get('tool') or '' for col in columns
                  if not col.get('column')}
    by_tool = {}
    for col in columns:
        if not col.get('column'):
            continue                      # an array declaration; handled below
        tool = col.get('tool') or ''
        key = col.get('key') or col['column']
        if not tool or _spec_or_none(tool, key) is None:
            continue
        value = (entry.get('scalars') or {}).get(col['column'])
        if value is None:
            continue
        kw = {}
        if col.get('scope', 'object') == 'state':
            kw['state'] = 1
        if col.get('chain'):
            kw['chain'] = col['chain']
        by_tool.setdefault(tool, []).append(mstore.value(tool, key, value=value, **kw))
    for row in c.arrays_of(entry['id']):
        tool = array_tool.get(row['key'], '')
        if not tool or _spec_or_none(tool, row['key']) is None:
            continue
        index, values = c.array(entry['id'], row['key'], chain=row.get('chain'))
        kw = {'state': 1, 'index': [tuple(p) for p in index], 'values': values}
        if row.get('chain'):
            kw['chain'] = row['chain']
        by_tool.setdefault(tool, []).append(mstore.value(tool, row['key'], **kw))
    for tool, values in by_tool.items():
        try:
            mbinding.record(obj, tool, values, inputs={'set': entry['set_id'],
                                                       'entry': entry['name']},
                            _self=_self)
        except Exception as exc:
            colorprinting.warning(' sets: metrics for %s (%s) not written: %s'
                                  % (obj, tool, exc))


def _load_entry_into(c, entry, obj, _self=cmd):
    chains = c.chain_cifs(entry['id'])
    if not chains:
        raise SetInputError('%s has no structure to show' % entry['name'])
    _load_chains(chains, obj, _self=_self)
    try:
        _self.dss(obj)
    except Exception:
        pass


def stage(set_row, entries, budget_override=None, _self=cmd):
    """Load entries as objects in the set's group. Returns the object names.

    Refuses past the budget with the unpinned staged names it would need to drop; it
    never drops them itself. An entry already staged is left alone and its object name
    returned.
    """
    c = container()
    set_id = set_row['id']
    staged = _staged(c, set_id, _self=_self)
    already = {e['id'] for e in staged}
    todo = [e for e in entries if e['id'] not in already]
    limit = int(budget_override) if budget_override else budget(set_row)
    if len(staged) + len(todo) > limit:
        unpinned = [e['name'] for e in staged if not e.get('pinned')]
        raise SetBudgetExceeded(
            'staging %d more would put %d objects in the scene; the budget is %d.'
            ' Unstage some of: %s (or raise the budget with set_budget)'
            % (len(todo), len(staged) + len(todo), limit,
               ', '.join(unpinned) or 'nothing is unpinned'), unpinned=unpinned)
    names = [e['staged_object'] for e in entries if e['id'] in already]
    if not todo:
        return names
    group = set_row.get('group_name') or set_row['name']
    _ensure_group(group, _self=_self)
    ref = set_row.get('reference') or ''
    for e in todo:
        obj = _free_object_name(e['name'], _self=_self)
        _load_entry_into(c, e, obj, _self=_self)
        try:
            _self.group(group, obj, 'add', quiet=1)
        except Exception as exc:
            colorprinting.warning(' sets: could not add %s to group %s (%s)' % (obj, group, exc))
        _superpose(obj, ref, _self=_self)
        c.update_entry(e['id'], staged_object=obj)
        _write_back_metrics(c, dict(e, staged_object=obj), obj, _self=_self)
        names.append(obj)
    return names


def unstage(set_row, entries, include_pinned=False, _self=cmd):
    """Delete the entries' objects and their metrics runs; clear the links. Pinned
    entries are skipped unless `include_pinned` (the caller named them explicitly)."""
    c = container()
    removed = []
    for e in entries:
        obj = e.get('staged_object')
        if not obj:
            continue
        if e.get('pinned') and not include_pinned:
            continue
        try:
            mstore.forget_object(obj)
        except Exception:
            pass
        if _exists(obj, _self=_self):
            _self.delete(obj)
        c.update_entry(e['id'], staged_object=None, pinned=0)
        removed.append(obj)
    _drop_empty_group(set_row, _self=_self)
    return removed


def _drop_empty_group(set_row, _self=cmd):
    group = set_row.get('group_name') or set_row['name']
    if group not in (_self.get_names('public_group_objects') or []):
        return
    if _staged(container(), set_row['id'], _self=_self):
        return
    children = _group_children(group, _self=_self)
    if children is None or children:
        return
    try:
        _self.delete(group)
    except Exception:
        pass


def reconcile(_self=cmd):
    """Clear links whose object is gone (deleted by the user, or absent from the session
    that was just loaded). Called after every session restore."""
    if not store.is_open():
        return
    c = container()
    for s in c.sets():
        _staged(c, s['id'], _self=_self)


# -- Peek ------------------------------------------------------------------------------


def clear_peek(_self=cmd):
    if _exists(PEEK, _self=_self):
        _self.delete(PEEK)


def peek(set_row, entry, _self=cmd):
    """Show one entry in the peek object, replacing whatever it showed. Fixed look: a
    dim, half-transparent cartoon, so it cannot be mistaken for a staged object."""
    c = container()
    clear_peek(_self=_self)
    _load_entry_into(c, entry, PEEK, _self=_self)
    _superpose(PEEK, set_row.get('reference') or '', _self=_self)
    try:
        _self.hide('everything', PEEK)
        _self.show('cartoon', PEEK)
        _self.color('grey70', PEEK)
        _self.set('cartoon_transparency', 0.5, PEEK)
    except Exception:
        pass
    return PEEK


# -- Session: .raymol save/load, .pse save/load ------------------------------------------


def _strip_peek(session):
    names = session.get('names')
    if isinstance(names, list):
        session['names'] = [entry for entry in names
                            if not (entry and entry[0] == PEEK)]


def session_save(session, _self=cmd, **_kwargs):
    """Session-save task. Keeps the peek object out of every session dictionary, so it
    can never come back from a .pse as a real object. Never touches the store."""
    _strip_peek(session)
    return 1


def warn_if_pse_leaves_sets(filename='', _self=cmd):
    """Called by `save` on the .pse/.psw path (not from the session task: `get_session`
    is also used for reads like the group-membership check, and a warning on every read
    would be noise). Names the sets a plain .pse leaves behind."""
    if _SAVING_RAYMOL or not store.is_open():
        return False
    try:
        names = [s['name'] for s in container().sets()]
    except Exception:
        return False
    if not names:
        return False
    colorprinting.warning(
        ' sets: a .pse cannot hold sets; %s left out. Use `save name.raymol` to keep'
        ' the whole session in one file.' % ', '.join(names))
    return True


def session_restore(session, _self=cmd, **_kwargs):
    """Session-restore task: drop links to staged objects the incoming session does not
    have. Never resets the store -- `set_session` also restores in-memory snapshots
    (the theme preview) and partial loads merge, so the reset for a bare `load x.pse`
    lives in `importing.load_pse`, which knows it is one."""
    try:
        reconcile(_self=_self)
    except Exception as exc:
        colorprinting.warning(' sets: could not reconcile staged objects: %s' % exc)
    return 1


def _app_version(_self=cmd):
    try:
        return str(_self.get_version()[0])
    except Exception:
        return ''


def _pse_bytes(_self=cmd):
    global _SAVING_RAYMOL
    _SAVING_RAYMOL = True
    try:
        session = _self.get_session('', 0, 1)      # session_save strips the peek

        return pickle.dumps(session, 1)
    finally:
        _SAVING_RAYMOL = False


def save_raymol(filename, quiet=1, _self=cmd):
    """`save x.raymol`. If the open container is already this file, write the session
    blob; otherwise copy the container there and continue on the copy."""
    filename = os.path.abspath(_self.exp_path(filename))
    c = container()
    same = os.path.exists(filename) and os.path.samefile(filename, c.path)
    if not same:
        tmp = filename + '.saving'
        if os.path.exists(tmp):
            os.remove(tmp)
        moved = c.save_into(tmp)
        moved.close()
        os.replace(tmp, filename)
        old_path = c.path
        c = store.replace(store.Container(filename))
        if os.path.abspath(old_path) == os.path.abspath(store.working_path()):
            for suffix in ('', '-wal', '-shm'):
                try:
                    os.remove(old_path + suffix)
                except OSError:
                    pass
    c.write_session(_pse_bytes(_self=_self),
                    pse_version=_self.get_setting_float('pse_export_version'),
                    app_version=_app_version(_self=_self))
    _self.set('session_file', filename.replace('\\', '/'), quiet=1)
    if not int(quiet):
        colorprinting.parrot(' Save: wrote session and %d set(s) to %s'
                             % (len(c.sets()), filename))
    return _self.DEFAULT_SUCCESS


def load_raymol(filename, partial=0, quiet=1, *, _self=cmd):
    """`load x.raymol`. Opens the container IN PLACE, then restores the session blob it
    carries. Later results write straight into the document."""
    global _LOADING_RAYMOL
    filename = os.path.abspath(_self.exp_path(filename))
    if not os.path.isfile(filename):
        raise SetInputError('no such file: %s' % filename)
    new = store.Container(filename)          # SetFormatError if it is not ours
    blob = new.read_session()
    if not blob and not partial:
        # A container written by the store alone (a batch that never saw Save, an
        # exported set) carries no session. Clear the scene FIRST: `reinitialize`
        # resets the store to a fresh working file, which would close the document if
        # it were already installed.
        _self.reinitialize()
    old = container()
    old_path = old.path
    store.replace(new)
    if os.path.abspath(old_path) == os.path.abspath(store.working_path()) \
            and os.path.abspath(old_path) != os.path.abspath(filename):
        for suffix in ('', '-wal', '-shm'):
            try:
                os.remove(old_path + suffix)
            except OSError:
                pass
    _LOADING_RAYMOL = True
    try:
        if blob:
            session = pickle.loads(blob)
            r = _self.set_session(session, quiet=quiet, partial=partial, steal=1)
        else:
            reconcile(_self=_self)
            r = _self.DEFAULT_SUCCESS
    finally:
        _LOADING_RAYMOL = False
    if not partial:
        _self.set('session_file', filename.replace('\\', '/'), quiet=1)
    return r
