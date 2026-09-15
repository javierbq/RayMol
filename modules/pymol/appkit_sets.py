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
    sel      entry ids of the ACTIVE set whose STAGED OBJECT holds atoms of the
             `sele` selection, so a click in the viewport can select and scroll to
             the row (#418). Omitted entirely when empty, which is the usual case,
             so an idle marker is what it always was.
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
    payload = {
        'v': version,
        'path': path,
        'active': _active_set_id if store.is_open() else '',
        'peek': _peek_entry_id,
        'running': _running(),
    }
    # Only when there IS one: an empty list would put four bytes on every idle tick
    # and change the marker a no-set session has always printed (#418).
    selected = _selected_entry_ids(_self=_self)
    if selected:
        payload['sel'] = selected
    return payload


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
    # `sel` goes first of all: it is a convenience (the table scrolls itself to the
    # object you clicked) and the user is looking at the object either way, where a
    # missing batch badge reads as "the batch finished" -- a wrong statement.
    payload.pop('sel', None)
    text = _encode(payload)
    if len(text.encode('utf-8')) <= MAX_MARKER_BYTES:
        return text
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
    # The compiled filter (#418) rides its own channel, on the same tick and under the
    # same "only when it changed" rule. Its own try for the reason poll() has one: a
    # failure in the filter layer must not cost the drawer its marker.
    try:
        _poll_filter()
    except Exception:
        pass


def reset_marker():
    """Forget the last marker so the next poll re-emits. Used after `load` paths that
    replace the Swift side's state wholesale, and by tests."""
    global _last_marker, _last_filter_key
    _last_marker = None
    _last_filter_key = None


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
    # The set's saved filter, compiled, on this call rather than on the next poll:
    # the drawer reads its rows the moment it opens, and half a second of showing
    # rows the active filter excludes is half a second of the wrong table (#418).
    try:
        _emit_filter(filter_payload(row, row.get('filter') or '', applied=1))
    except Exception:
        pass
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


# -- The filter channel (#418) ------------------------------------------------------------
#
# There is exactly ONE filter grammar and it is `pymol.sets.filter`. The drawer's filter
# bar, the header-histogram brushes and the Plot tab's axis brushes all produce the same
# kind of string (`plddt >= 80 and plddt <= 92`), and every one of them comes HERE to
# find out what it means. Swift never parses an expression.
#
# What goes back is not a row list and not a count: it is the COMPILED FRAGMENT -- the
# `WHERE` text with `?` placeholders that `filter.compile` produced, plus its bound
# params. Swift already holds a read-only connection to the same container (SetsStore),
# and its row query is `FROM entries e LEFT JOIN m_<set> m`, which is the pair of aliases
# the fragment is written against; so it binds the params and runs the predicate the
# grammar decided on. Three things fall out of that choice:
#
#   * the drawer re-filters LOCALLY when entries land, with no round trip per delivery,
#     which is what keeps #421's "never poll a set" true while a batch is still running;
#   * the Plot tab and the Table tab cannot disagree about what matches, because they run
#     the same fragment over the same rows;
#   * nothing the user typed is ever interpolated into SQL on either side -- values are
#     `?` here and bound there, exactly as `filter.py`'s docstring promises.
#
# The payload rides a TEMP FILE, not the feedback line, for the reason appkit_inspector's
# object list does (#231): a long expression compiles to a long fragment, and PyMOL's
# feedback line is capped at 1024 bytes. A cap would have meant a "your filter is too
# long to show" state that is impossible to explain; a file has no cap.

FILTER_STEM = 'pymol_sets_filter'
FILTER_PREFIX = 'SETSFILTER:'

#: (set id, expression) last written to the channel, so the 500 ms poll re-emits when a
#: console `set_filter`, an MCP agent or an applied view moved the active set's filter --
#: and stays silent, as every other part of this module does, when nothing changed.
_last_filter_key = None


def _columns_map(set_id):
    from pymol.sets import filter as _f  # noqa: F401  (import order: errors first)
    return {col['column']: col.get('dtype', 'float')
            for col in _store().active().columns(set_id) if col.get('column')}


def filter_payload(set_row, expr, applied=0):
    """Compile `expr` against `set_row`'s declared columns and describe the result.

    Never raises for a bad expression: a filter bar that the user is still typing into
    is wrong most of the time, and a traceback per keystroke is not an error message.
    `error` carries `SetFilterError.message` (not `str(exc)`, which prefixes " Error: ")
    and `offset` the character the parser stopped at, so the field can underline it.
    """
    from pymol.sets import filter as setfilter
    from pymol.sets.errors import SetFilterError
    c = _store().active()
    set_id = set_row['id']
    payload = {
        'set': set_id,
        'expr': str(expr or ''),
        'applied': 1 if applied else 0,
        'sql': '',
        'params': [],
        'n': 0,
        'total': c.count(set_id),
        'error': '',
        'offset': -1,
    }
    try:
        sql, params = setfilter.compile(payload['expr'], _columns_map(set_id))
    except SetFilterError as exc:
        payload['error'] = exc.message or 'the filter expression is not valid'
        payload['offset'] = -1 if exc.offset is None else int(exc.offset)
        return payload
    payload['sql'] = sql
    payload['params'] = list(params)
    payload['n'] = c.count(set_id, where=sql, params=params)
    return payload


def _emit_filter(payload, key=None):
    """Write the payload to this process's channel file and print the short marker.

    `key` is what `_poll_filter` compares against; it is the payload's own (set, expr)
    for an APPLIED filter, and the set's STORED expression for a preview. Getting that
    distinction wrong is visible: a preview that recorded itself as the key would leave
    the poll thinking the stored filter had drifted, and the next tick would push the
    stored one back over the preview -- the field would flicker back mid-drag.
    """
    global _last_filter_key
    from pymol import raymol_tmp
    try:
        with open(raymol_tmp.channel_path(FILTER_STEM), 'w') as handle:
            json.dump(payload, handle)
    except OSError as exc:
        colorprinting.warning(' sets: could not write the filter channel (%s)' % exc)
        return payload
    _last_filter_key = (payload['set'], payload['expr']) if key is None else key
    print(FILTER_PREFIX + 'ready')
    return payload


def preview_filter(name, expr='', _self=cmd):
    """Compile an expression WITHOUT applying it: what the filter bar asks on every
    keystroke and what a histogram brush asks on every drag step. The set keeps
    whatever filter it had, so a half-typed expression never becomes the one
    `set_export` or `predict set:x@filtered` would use, and a drag does not write to
    the container (and bump its version, and re-read every row) once per pixel."""
    row = _set_row(name)
    return _emit_filter(filter_payload(row, expr, applied=0),
                        key=(row['id'], row.get('filter') or ''))


def apply_filter(name, expr='', _self=cmd):
    """`set_filter name, expr`, then report the compiled result on the channel.

    A rejected expression is reported, not raised: the drawer shows the message beside
    the field, and the set's previous filter is left in place -- `set_filter` validates
    before it writes, so a bad expression has already changed nothing.
    """
    from pymol.sets.errors import SetFilterError
    row = _set_row(name)
    expr = str(expr or '')
    try:
        _self.set_filter(row['name'], expr, quiet=1)
    except SetFilterError:
        pass          # filter_payload below reports the same failure, with its offset
    return _emit_filter(filter_payload(row, expr, applied=1))


def apply_view(name, view, _self=cmd):
    """Make a saved view the set's active filter and sort (spec §4.2, "Save as View").

    The view's COLUMNS are not applied here: which columns are visible is a property of
    the drawer, not of the store, and Swift reads the same `views` row from the file.
    """
    row = _set_row(name)
    saved = _store().active().view(row['id'], str(view).strip())
    expr = saved.get('filter') or ''
    _self.set_filter(row['name'], expr, quiet=1)
    if saved.get('sort_key'):
        _self.set_sort(row['name'], saved['sort_key'],
                       1 if int(saved.get('sort_desc') or 0) else 0, quiet=1)
    _emit_filter(filter_payload(row, expr, applied=1))
    return str(view).strip()


def _poll_filter():
    """Re-emit the compiled filter when the ACTIVE set's expression moved under us.

    The drawer's own edits already emitted; this is for the other writers -- a console
    or MCP `set_filter`, `apply_view`, opening a different set, or a `load` that brought
    a set whose filter was saved with it. One indexed row read per tick, and only while
    a set is open, so requirement 7 ("nothing changes when no set is open") holds.
    """
    global _last_filter_key
    store = _store()
    if not (_active_set_id and store.is_open()):
        if _last_filter_key is not None:
            _last_filter_key = None
        return
    try:
        row = store.active().get_set(_active_set_id)
    except Exception:
        return
    expr = row.get('filter') or ''
    if _last_filter_key == (row['id'], expr):
        return
    _emit_filter(filter_payload(row, expr, applied=1))


# -- Viewport -> row (#418) ---------------------------------------------------------------
#
# "Clicking a staged object in the viewport selects and scrolls to its row" needs the
# object -> entry link, and that link already exists: `entries.staged_object`, written by
# sets.binding when the entry was staged. Nothing here invents a second mapping.
#
# It rides the SETS: marker rather than a poll of its own, and it is computed only while
# a set is open AND that set has staged entries -- which the budget keeps in the single
# digits. The cost is one `get_object_list` over the active selection plus one indexed
# read of at most `budget` rows; both are O(staged), not O(entries), which is the rule
# #421 states. The field is omitted entirely when nothing is selected, so an idle marker
# is byte-for-byte what it was before this ticket.

#: At most this many entry ids ride the marker. The stage budget is a single digit by
#: default, so this is already generous; a scene someone raised the budget on reports
#: the first few and the drawer selects those, which is better than a split line.
MAX_SELECTED_IDS = 8


def _selected_entry_ids(_self=cmd):
    """Entry ids of the active set whose staged object holds atoms of `sele`."""
    store = _store()
    if not (_active_set_id and store.is_open()):
        return []
    try:
        if 'sele' not in (_self.get_names('selections') or []):
            return []
        objects = set(_self.get_object_list('sele') or [])
    except Exception:
        return []
    if not objects:
        return []
    try:
        staged = store.active().entries(
            _active_set_id, where='e.staged_object IS NOT NULL')
    except Exception:
        return []
    out = [e['id'] for e in staged if e.get('staged_object') in objects]
    return out[:MAX_SELECTED_IDS]
