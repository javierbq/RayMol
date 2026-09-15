"""Sets change-marker and Data-drawer helpers for the native SwiftUI app (#417).

The drawer never receives set CONTENTS from here. A set can hold ten thousand entries,
and the object panel's 500 ms poll (appkit_inspector.poll_panel) must not grow with
that count (#271, #398, tracking #421). Swift opens the `.raymol` container itself,
read-only, and re-reads it only when the version in the marker below changes. So the
whole Python -> Swift channel for sets is one short line, printed ONLY when something
in it changed since the last poll:

    SETS:{"v":12,"path":"/…/x.raymol","active":"1a2b3c4d","peek":"9f8e7d6c","running":{}}

    v        store.active().version() -- meta.version, bumped by every write -- or 0
             when no container is open. Read through store.is_open() first, so polling
             never CREATES the pid-scoped working file as a side effect.
    path     the container's path, or "" when none is open. Carried on every change
             because `load x.raymol` and Save As move the document under Swift's feet.
    active   the id of the set the drawer is open on, or "". Owned HERE, not in Swift,
             so an MCP agent can open a set in the drawer with the same call the UI
             makes, and so the drawer follows a `set_delete` of what it was showing.
    peek     the id of the entry currently shown in the hidden peek object, or "".
    running  {set_id: {"done": n, "total": n, "tool": name}} for batches still
             landing, from pymol.sets.batch (#416) when that module exists; {} when it
             does not. Imported lazily and guarded, because the two tickets land
             independently and the badge must simply appear the day both are in.
             With `trunc` set it is instead a LIST of set ids, the counts having been
             dropped to keep the line under the cap -- see `marker`.
    trunc    present and 1 only when something was dropped to fit the line.

The helpers below are what the drawer calls so that Swift sends one short line per
action rather than composing Python. Every one of them goes through a public `set_*`
command (setting_sets.py); nothing here writes the store directly, and nothing here
touches the scene except through those commands.
"""
import json

from pymol import cmd, colorprinting

#: PyMOL's feedback line is capped at OrthoLineLength (1024). The marker is normally
#: ~150 bytes; a pathological path plus a dozen running batches could approach the
#: cap, so `marker()` drops `running` to {} (with `trunc: 1`) before it ever splits.
MARKER_PREFIX = 'SETS:'
MAX_MARKER_BYTES = 900


_last_marker = None
_active_set_id = ''
_peek_set_id = ''
_peek_entry_id = ''
_seen_generation = -1


def _store():
    from pymol.sets import store
    return store


def _running():
    """`pymol.sets.batch.running()` when #416 has landed, else {}. Never raises: a
    broken progress table must not cost the panel its poll."""
    try:
        from pymol.sets import batch
    except ImportError:
        return {}
    try:
        out = batch.running() or {}
    except Exception:
        return {}
    if not isinstance(out, dict):
        return {}
    clean = {}
    for set_id, rec in out.items():
        if not isinstance(rec, dict):
            continue
        try:
            clean[str(set_id)] = {
                'done': int(rec.get('done', 0) or 0),
                'total': int(rec.get('total', 0) or 0),
                'tool': str(rec.get('tool', '') or ''),
            }
        except (TypeError, ValueError):
            continue
    return clean


def _peek_object_present(_self=cmd):
    from pymol.sets import binding
    try:
        return binding.PEEK in (_self.get_names('all') or [])
    except Exception:
        return False


def _peek_stamp(_self=cmd):
    """The entry id stamped on the peek object, or '' if it carries none.

    `binding.peek` keeps no record of WHICH entry it drew -- the peek object is
    anonymous by design, so a console `set_peek` needs nothing from the UI -- and
    without a record the drawer cannot mark the row. So the id is stamped on the
    object here, as its state title, and read back on every poll.

    What that buys is staleness detection: a console (or MCP) `set_peek s, e`
    deletes and reloads the object, which drops the stamp, so the next poll sees a
    peek that is not the one we recorded and stops marking a row that is no longer
    the one on screen. Without this the drawer kept ◐ on the PREVIOUS row, which is
    worse than showing no mark at all.
    """
    from pymol.sets import binding
    try:
        return str(_self.get_title(binding.PEEK, 1, quiet=1) or '')
    except Exception:
        return ''


def _stamp_peek(entry_id, _self=cmd):
    from pymol.sets import binding
    try:
        _self.set_title(binding.PEEK, 1, str(entry_id))
    except Exception:
        pass


def _reconcile_ids(store):
    """Drop the active-set / peek ids when the container they belong to is gone.

    The store's generation changes on every `load x.raymol`, Save As and reset, so a
    set id kept from the previous document would otherwise name nothing -- or, worse,
    something else in the new file. Cheap: an integer compare per poll, and a
    `get_set` only when the container has actually changed or a write happened.
    """
    global _active_set_id, _peek_set_id, _peek_entry_id, _seen_generation
    generation = store.generation()
    if generation != _seen_generation:
        _seen_generation = generation
        if not store.is_open():
            _active_set_id = ''
            _peek_set_id = _peek_entry_id = ''
            return
    if not _active_set_id:
        return
    if not store.is_open():
        _active_set_id = ''
        return
    try:
        store.active().get_set(_active_set_id)
    except Exception:
        _active_set_id = ''


def state(_self=cmd):
    """The marker's payload as a dict. Pure read: never opens a container."""
    global _peek_set_id, _peek_entry_id
    store = _store()
    _reconcile_ids(store)
    version, path = 0, ''
    if store.is_open():
        c = store.active()
        try:
            version = int(c.version())
        except Exception:
            version = 0
        path = c.path or ''
    else:
        # `reinitialize`, `load x.pse` and set_delete of the last set reset the store;
        # a stale active id would keep the drawer open on nothing.
        pass
    # The peek is ours only while the object we stamped is still the one on screen.
    # A bare `set_peek` (or a `delete _raymol_peek`) removes it; a console
    # `set_peek s, e` replaces its contents and so drops the stamp. Either way the
    # drawer must stop marking a row. Checked only when we believe something is
    # peeked, so the common idle tick costs neither call.
    if _peek_entry_id and not (_peek_object_present(_self=_self)
                               and _peek_stamp(_self=_self) == _peek_entry_id):
        _peek_set_id = _peek_entry_id = ''
    return {
        'v': version,
        'path': path,
        'active': _active_set_id if store.is_open() else '',
        'peek': _peek_entry_id,
        'running': _running(),
    }


def _encode(payload):
    return MARKER_PREFIX + json.dumps(payload, separators=(',', ':'))


def marker(_self=cmd):
    """The marker line, trimmed in stages so it can never split.

    The COUNTS go before the sets themselves do. A badge that says only "a batch is
    running", on the right rows, is still true and still useful; dropping `running`
    outright makes the badge vanish, which reads as "the batch finished".

    So the truncated form is a LIST OF IDS, not a dict of emptied records. The
    difference is the whole point of the stage: `{"id":{"done":0,"total":0,"tool":""}}`
    costs ~41 bytes per batch and blows the 900-byte cap at about twenty, which is
    fewer than the number of batches that would make anyone want the stage in the
    first place -- so it fell through to "drop everything" exactly when it was
    needed. A bare `"id"` costs ~11, so around sixty-nine fit. `trunc` is set either
    way, and the far side reads it as "these are running, the numbers are unknown".
    """
    payload = state(_self=_self)
    text = _encode(payload)
    if len(text.encode('utf-8')) <= MAX_MARKER_BYTES:
        return text
    payload['trunc'] = 1
    payload['running'] = sorted(payload.get('running') or {})
    text = _encode(payload)
    if len(text.encode('utf-8')) <= MAX_MARKER_BYTES:
        return text
    # Even the ids do not fit. Nothing left to give: the fields the drawer cannot
    # work without (path, version, active set, peek) are the ones that stay.
    payload['running'] = []
    return _encode(payload)


def poll(_self=cmd):
    """Print the marker if it differs from the last one printed. Called from
    appkit_inspector.poll_panel every 500 ms; its own try there and here, because a
    failure in the sets layer must never cost the object panel its update."""
    global _last_marker
    try:
        text = marker(_self=_self)
    except Exception:
        return
    if text != _last_marker:
        _last_marker = text
        print(text)


def reset_marker():
    """Forget the last marker so the next poll re-emits. Used after `load` paths that
    replace the Swift side's state wholesale, and by tests."""
    global _last_marker
    _last_marker = None


# -- Cold-launch recovery (#447) ----------------------------------------------------------
#
# Spec §2.1: the working file for an untitled session IS the autosave, and is offered
# back on cold launch. `store.recoverable()` answers "is there anything to recover",
# and this marker carries the answer to Swift ONCE, at launch -- never from the 500 ms
# poll. It stats and opens files, and the answer cannot change while the app runs:
# a container is preserved by the process that is exiting, not by this one.

RECOVER_PREFIX = 'SETSRECOVER:'

#: How many preserved containers the marker names. The alert offers the newest one;
#: the rest stay on disk under the retention policy and are offered on a later launch,
#: so carrying more than a handful would only risk the feedback line's length cap.
MAX_RECOVERABLE = 4


def recoverable():
    """The preserved containers worth offering, newest first, as plain dicts. Never
    opens or creates the working container, so asking is free in a session with no
    sets."""
    return _store().recoverable()


def recovery_payload():
    """The recovery marker's payload: the newest few containers, plus how many there
    are in total so the far side can say "and N more" without being sent them."""
    found = recoverable()
    return {
        'n': len(found),
        'files': [{'path': info['path'],
                   'sets': info['sets'],
                   'entries': info['entries'],
                   'session': 1 if info['session'] else 0,
                   'modified': round(float(info['modified']), 3)}
                  for info in found[:MAX_RECOVERABLE]],
    }


def recovery_marker():
    """The marker line, trimmed by DROPPING FILES from the end until it fits. `n` is
    never trimmed: "there is something to recover" is the part the user acts on, and
    a line that split would deliver neither."""
    payload = recovery_payload()
    while True:
        text = RECOVER_PREFIX + json.dumps(payload, separators=(',', ':'))
        if len(text.encode('utf-8')) <= MAX_MARKER_BYTES or not payload['files']:
            return text
        payload['files'] = payload['files'][:-1]


def poll_recovery():
    """Print the recovery marker, once, at launch. Prints even when there is nothing
    to recover -- `{"n":0,"files":[]}` is the answer that lets Swift stop waiting and
    fall through to whatever else a cold launch would do."""
    print(recovery_marker())


def discard_recovered(path):
    """Delete a preserved container the user declined. Goes through the store, which
    refuses any path that is not one of its own."""
    return _store().discard_recoverable(path)


# -- Drawer helpers -----------------------------------------------------------------------
#
# Each takes what the drawer has -- a set NAME (what set_* commands accept) and an entry
# NAME -- and reports back through the marker, never through a return value: Swift's
# runPython has none.


def _set_row(name):
    store = _store()
    return store.active().get_set(str(name).strip())


def open_set(name, _self=cmd):
    """Make `name` the drawer's set. Also the MCP way to point a user at a set."""
    global _active_set_id
    row = _set_row(name)
    _active_set_id = row['id']
    return row['id']


def close_set(_self=cmd):
    global _active_set_id
    _active_set_id = ''
    clear_peek(_self=_self)
    return ''


def active_set_id():
    return _active_set_id


def peek(name, entry, _self=cmd):
    """`set_peek name, entry`, remembering WHICH entry so the marker can mark its row.
    binding.peek itself keeps no record -- the peek object is anonymous by design so a
    console `set_peek` needs nothing from the UI -- so the record lives here."""
    global _peek_set_id, _peek_entry_id
    row = _set_row(name)
    e = _store().active().entry(row['id'], str(entry).strip())
    _self.set_peek(row['name'], e['name'], quiet=1)
    _stamp_peek(e['id'], _self=_self)
    _peek_set_id, _peek_entry_id = row['id'], e['id']
    return e['id']


def clear_peek(_self=cmd):
    global _peek_set_id, _peek_entry_id
    _self.set_peek(quiet=1)
    _peek_set_id = _peek_entry_id = ''
    return ''


def peeked_entry_id():
    return _peek_entry_id


def toggle_stage(name, entries, _self=cmd):
    """Space in the drawer: unstage the named entries when EVERY one of them is
    already staged, else stage them — so a mixed selection fills in the rest rather
    than half-clearing it. A budget refusal is a one-line warning here, not a
    traceback; the drawer's footer states the refusal, and the console names what
    would have to be unstaged."""
    from pymol.sets import selectors
    from pymol.sets.errors import SetBudgetExceeded, SetError
    row = _set_row(name)
    found = selectors.resolve(_store().active(), row, entries)
    if not found:
        return []
    if all(e.get('staged_object') for e in found):
        return _self.set_unstage(row['name'], entries, quiet=1)
    try:
        return _self.set_stage(row['name'], entries, quiet=1)
    except SetBudgetExceeded as exc:
        colorprinting.warning(' sets: %s' % exc)
        return []
    except SetError as exc:
        colorprinting.warning(' sets: %s' % exc)
        return []
