"""The cmd.set_* surface for sets (#415).

Every drawer action in later steps is one of these, and the MCP story is this file: an
agent that can `set_filter`, `set_stage` and `set_export` can triage a campaign without
the UI. Session-touching work lives in sets.binding; the store itself is sets.store;
entry selectors (spec §4.1) are sets.selectors; the filter language (§5) is sets.filter.
"""
import json
import os

from pymol import cmd, colorprinting
from pymol.sets import binding, document, selectors, store
from pymol.sets.errors import SetInputError, SetNotFound


def _c():
    return store.active()


def _set(name):
    return _c().get_set(str(name).strip())


def _fmt(value):
    if value is None:
        return '-'
    if isinstance(value, float):
        return '%.3g' % value
    return str(value)


def _rows(set_row, entries, quiet):
    if int(quiet):
        return
    key = set_row.get('ranking_key') or set_row.get('sort_key') or ''
    for e in entries:
        flags = ''.join([
            '*' if e.get('starred') else ' ',
            'x' if e.get('rejected') else ' ',
            '@' if e.get('staged_object') else ' ',
            'p' if e.get('pinned') else ' ',
        ])
        shown = ''
        if key:
            shown = '%s=%s' % (key, _fmt((e.get('scalars') or {}).get(key)))
        colorprinting.parrot(' %s %-24s %s' % (flags, e['name'], shown))


# -- Sets ----------------------------------------------------------------------------


def set_create(name, kind='structures', note='', quiet=1, _self=cmd):
    """
DESCRIPTION

    "set_create" makes an empty set. A set is a collection of entries (candidates from
    a design or prediction campaign) browsed apart from the scene; its group holds only
    the entries you stage.

USAGE

    set_create name [, kind [, note ]]

ARGUMENTS

    kind = structures | sequences | mixed {default: structures}
    """
    row = _c().create_set(str(name).strip(), kind=str(kind), note=str(note))
    if not int(quiet):
        colorprinting.parrot(' set_create: %s' % row['name'])
    return row['name']


def set_delete(name, quiet=1, _self=cmd):
    """
DESCRIPTION

    "set_delete" unstages every entry of a set, drops its group if empty, and deletes
    the set with all its entries, blobs and views.

USAGE

    set_delete name
    """
    row = _set(name)
    entries = selectors.resolve(_c(), row, 'staged')
    binding.unstage(row, entries, include_pinned=True, _self=_self)
    binding.clear_peek(_self=_self)
    _c().delete_set(row['id'])
    if not int(quiet):
        colorprinting.parrot(' set_delete: %s' % row['name'])
    return _self.DEFAULT_SUCCESS


def set_rename(name, new_name, quiet=1, _self=cmd):
    """
DESCRIPTION

    "set_rename" renames a set and its group.

USAGE

    set_rename name, new_name
    """
    row = _set(name)
    new_name = str(new_name).strip()
    _c().rename_set(row['id'], new_name)       # rewrites group_name too
    group = row.get('group_name') or row['name']
    if group != new_name and group in (_self.get_names('public_group_objects') or []):
        try:
            _self.set_name(group, new_name)
        except Exception as exc:
            colorprinting.warning(' set_rename: group %s kept its name (%s)' % (group, exc))
            _c().update_set(row['id'], group_name=group)
    return new_name


def set_list(name='', quiet=1, _self=cmd):
    """
DESCRIPTION

    "set_list" lists every set, or the entries of one set under its active filter and
    sort. Flags per entry: * starred, x rejected, @ staged, p pinned.

USAGE

    set_list [ name ]
    """
    c = _c()
    if not str(name).strip():
        rows = [dict(s, count=c.count(s['id']),
                     staged=c.count(s['id'], 'e.staged_object IS NOT NULL'))
                for s in c.sets()]
        if not int(quiet):
            if not rows:
                colorprinting.parrot(' set_list: no sets')
            for s in rows:
                colorprinting.parrot(' %-24s %-11s %6d entries  %d staged'
                                     % (s['name'], s['kind'], s['count'], s['staged']))
        return rows
    row = _set(name)
    entries = selectors.filtered(c, row)
    if not int(quiet):
        colorprinting.parrot(' %s: %d of %d' % (row['name'], len(entries), c.count(row['id'])))
    _rows(row, entries, quiet)
    return entries


def set_info(name, quiet=1, _self=cmd):
    """
DESCRIPTION

    "set_info" reports a set's columns, counts, budget, group and reference.

USAGE

    set_info name
    """
    c = _c()
    row = _set(name)
    sid = row['id']
    info = {
        'name': row['name'], 'kind': row['kind'], 'group': row.get('group_name'),
        'reference': row.get('reference') or '', 'filter': row.get('filter') or '',
        'sort': (row.get('sort_key') or '', int(row.get('sort_desc') or 0)),
        'budget': binding.budget(row),
        'counts': {
            'all': c.count(sid), 'filtered': selectors.count_filtered(c, row),
            'staged': c.count(sid, 'e.staged_object IS NOT NULL'),
            'starred': c.count(sid, 'e.starred = 1'),
            'rejected': c.count(sid, 'e.rejected = 1'),
        },
        'columns': c.columns(sid),
        'runs': c.runs(sid),
        'views': [v['name'] for v in c.views(sid)],
    }
    if not int(quiet):
        colorprinting.parrot(' %s (%s) group=%s reference=%s budget=%d'
                             % (info['name'], info['kind'], info['group'],
                                info['reference'] or '-', info['budget']))
        colorprinting.parrot(' entries: %s' % ', '.join(
            '%s=%d' % kv for kv in info['counts'].items()))
        colorprinting.parrot(' columns: %s' % (', '.join(
            col['column'] for col in info['columns'] if col.get('column')) or '(none)'))
    return info


def set_schema(name, quiet=1, _self=cmd):
    """
DESCRIPTION

    "set_schema" prints a set's columns as metrics_schema prints a tool's.

USAGE

    set_schema name
    """
    cols = _c().columns(_set(name)['id'])
    if not int(quiet):
        for col in cols:
            colorprinting.parrot(' %-20s %-8s %-6s %-8s %s' % (
                col.get('column') or ('%s[]' % col.get('key')), col.get('scope', ''), col.get('dtype', ''),
                col.get('tool', ''), col.get('label', '')))
    return cols


# -- Entries -------------------------------------------------------------------------


def set_add(name, source, entries='all', parents='', run='', tool='', tool_version='',
            inputs='', quiet=1, _self=cmd):
    """
DESCRIPTION

    "set_add" adds entries to a set from an object, a structure file, a folder of
    structure files (with its entries.csv if present), or a FASTA file.

USAGE

    set_add name, source [, entries [, parents [, run [, tool [, tool_version [, inputs ]]]]]]

ARGUMENTS

    source = str: an object name, or a path
    entries = all | current: every state of an object, or the current one {default: all}
    parents = str: entry ids this came from, '+'-separated
    run = str: an existing run id of this set to attach the entries to
    tool, tool_version, inputs = str: create a run (inputs as JSON) and attach to it

NOTES

    Names are taken from the object or the file stem and made unique within the set
    (d_0417, d_0417_2, ...). Without run/tool, entries captured from an object are
    attached to one run per metrics-store run on that object.
    """
    row = _set(name)
    sid = row['id']
    source = str(source).strip()
    parent_ids = [p for p in str(parents).split('+') if p]
    run_id = str(run).strip() or None
    if run_id:
        _c().run(run_id)                               # SetNotFound if absent
    elif str(tool).strip():
        try:
            run_inputs = json.loads(inputs) if str(inputs).strip() else {}
        except ValueError:
            raise SetInputError('inputs must be JSON, got %r' % inputs)
        run_id = _c().add_run(sid, str(tool).strip(), tool_version=str(tool_version),
                              inputs=run_inputs)
    if source in (_self.get_names('all') or []):
        ids = binding.capture_object(sid, source, run_id=run_id, parents=parent_ids,
                                     states=str(entries), _self=_self)
    else:
        path = _self.exp_path(source)
        if os.path.isdir(path):
            ids = binding.capture_folder(sid, path, _self=_self)
        elif os.path.isfile(path):
            low = path.lower()
            if any(low.endswith(ext) for ext in document.SEQUENCE_EXTS):
                ids = binding.capture_fasta(sid, path, _self=_self)
            else:
                ids = binding.capture_file(sid, path, run_id=run_id, parents=parent_ids,
                                           _self=_self)
        else:
            raise SetNotFound('%r is neither an object nor a path' % source)
    names = [_c().entry_by_id(i)['name'] for i in ids]
    if not int(quiet):
        colorprinting.parrot(' set_add: %d entr%s into %s' % (
            len(names), 'y' if len(names) == 1 else 'ies', row['name']))
    return names


def set_remove(name, entries, quiet=1, _self=cmd):
    """
DESCRIPTION

    "set_remove" drops entries from a set, unstaging them first.

USAGE

    set_remove name, entries
    """
    row = _set(name)
    found = selectors.resolve(_c(), row, entries)
    binding.unstage(row, found, include_pinned=True, _self=_self)
    _c().delete_entries([e['id'] for e in found])
    return len(found)


def set_get(name, entries, key='', quiet=1, _self=cmd):
    """
DESCRIPTION

    "set_get" reads entries' scalars, or one array.

USAGE

    set_get name, entries [, key ]

NOTES

    Without a key: {entry name: {column: value, plus id, run_id, parents, sequences,
    starred, rejected, pinned, tags, note, staged}}. With an array key: {entry name:
    (index, values)}; with a scalar key or one of the fields above: {entry name: value}.
    """
    c = _c()
    row = _set(name)
    found = selectors.resolve(c, row, entries)
    key = str(key).strip()
    out = {}
    for e in found:
        scalars = e.get('scalars') or {}
        fields = dict(id=e['id'], run_id=e.get('run_id'), parents=e.get('parents') or [],
                      sequences=e.get('sequences') or {}, starred=e.get('starred'),
                      rejected=e.get('rejected'), pinned=e.get('pinned'),
                      tags=e.get('tags'), note=e.get('note'), staged=e.get('staged_object'))
        if not key:
            out[e['name']] = dict(scalars, **fields)
        elif key in scalars:
            out[e['name']] = scalars[key]
        elif key in fields:
            out[e['name']] = fields[key]
        else:
            arrays = [a for a in c.arrays_of(e['id']) if a['key'] == key]
            if not arrays:
                raise SetNotFound('%s has no column or array %r' % (e['name'], key))
            out[e['name']] = c.array(e['id'], key, chain=arrays[0].get('chain'))
    if not int(quiet):
        for ename, value in out.items():
            colorprinting.parrot(' %-24s %s' % (ename, json.dumps(value, default=str)[:200]))
    return out


def set_set(name, entries, key, value, quiet=1, _self=cmd):
    """
DESCRIPTION

    "set_set" writes a value into entries: note, tags, or a column that belongs to the
    user (tool 'user' or 'import'). A tool's own measurements are read-only here: a
    number a predictor wrote must keep meaning what the predictor measured.

USAGE

    set_set name, entries, key, value
    """
    c = _c()
    row = _set(name)
    found = selectors.resolve(c, row, entries)
    key = str(key).strip()
    cols = {col['column']: col for col in c.columns(row['id'])
            if col.get('column') and (col.get('tool') or 'user') in ('user', 'import')}
    for e in found:
        if key in ('note', 'tags'):
            c.update_entry(e['id'], **{key: str(value)})
        elif key in cols:
            c.set_scalar(e['id'], key,
                         document.coerce_sidecar_value(cols[key].get('dtype', 'float'),
                                                       str(value)))
        else:
            raise SetInputError('%r is not note, tags, or a user column of %s'
                                % (key, row['name']))
    return len(found)


def _flag(name, entries, field, on, _self):
    row = _set(name)
    found = selectors.resolve(_c(), row, entries)
    for e in found:
        _c().update_entry(e['id'], **{field: 1 if int(on) else 0})
    return [e['name'] for e in found]


def set_star(name, entries, on=1, quiet=1, _self=cmd):
    """
DESCRIPTION

    "set_star" stars (on=1) or unstars (on=0) entries.

USAGE

    set_star name, entries [, on ]
    """
    return _flag(name, entries, 'starred', on, _self)


def set_reject(name, entries, on=1, quiet=1, _self=cmd):
    """
DESCRIPTION

    "set_reject" marks entries rejected (on=1) or clears it (on=0). Rejected entries
    stay in the set; filters can exclude them with `not rejected`.

USAGE

    set_reject name, entries [, on ]
    """
    return _flag(name, entries, 'rejected', on, _self)


def set_pin(name, entries, on=1, quiet=1, _self=cmd):
    """
DESCRIPTION

    "set_pin" pins staged entries so `set_unstage` leaves them alone unless named.

USAGE

    set_pin name, entries [, on ]
    """
    row = _set(name)
    found = selectors.resolve(_c(), row, entries)
    names = []
    for e in found:
        if not e.get('staged_object'):
            raise SetInputError('%s is not staged; stage it before pinning' % e['name'])
        _c().update_entry(e['id'], pinned=1 if int(on) else 0)
        names.append(e['name'])
    return names


def set_tag(name, entries, tag, remove=0, quiet=1, _self=cmd):
    """
DESCRIPTION

    "set_tag" adds (or with remove=1 removes) a tag on entries. Tags are single tokens.

USAGE

    set_tag name, entries, tag [, remove ]
    """
    tag = str(tag).strip()
    if not tag or ' ' in tag:
        raise SetInputError('a tag is one token without spaces')
    row = _set(name)
    found = selectors.resolve(_c(), row, entries)
    for e in found:
        tags = [t for t in (e.get('tags') or '').split() if t]
        if int(remove):
            tags = [t for t in tags if t != tag]
        elif tag not in tags:
            tags.append(tag)
        _c().update_entry(e['id'], tags=' '.join(tags))
    return [e['name'] for e in found]


# -- Filter / sort / views --------------------------------------------------------------


def set_filter(name, expr='', quiet=1, _self=cmd):
    """
DESCRIPTION

    "set_filter" sets (or with no expression clears) a set's active filter, which
    `filtered`, `top:N`, set_list and set_export read.

USAGE

    set_filter name [, expr ]

NOTES

    On the command line everything after the set name is the expression, so '=' and
    commas inside it are safe. Clearing: `set_filter name` with nothing after it.

EXAMPLES

    set_filter rfd3_a1, plddt > 80 and rmsd < 1.5 and not rejected
    set_filter rfd3_a1, tags contains "patch-A" or starred
    """
    c = _c()
    row = _set(name)
    expr = str(expr or '').strip()
    n = selectors.count_filtered(c, row, expr=expr)      # SetFilterError before any write
    c.update_set(row['id'], filter=expr)
    total = c.count(row['id'])
    if not int(quiet):
        colorprinting.parrot(' set_filter: %d of %d match%s' % (
            n, total, '' if expr else ' (filter cleared)'))
    return n


def set_sort(name, key, desc=1, quiet=1, _self=cmd):
    """
DESCRIPTION

    "set_sort" sets a set's active sort: a column, or name / ord / created. A column
    also becomes the set's ranking key, the one `top:N`, the inspector histogram and
    the wide table's index follow.

USAGE

    set_sort name, key [, desc ]
    """
    c = _c()
    row = _set(name)
    key = str(key).strip()
    cols = {col['column'] for col in c.columns(row['id']) if col.get('column')}
    if key and key not in cols and key not in ('name', 'ord', 'created'):
        raise SetInputError('%r is not a column of %s (columns: %s)'
                            % (key, row['name'], ', '.join(sorted(cols)) or 'none'))
    fields = dict(sort_key=key, sort_desc=1 if int(desc) else 0)
    if key in cols:
        fields['ranking_key'] = key
    c.update_set(row['id'], **fields)
    return key


def set_view_save(name, view, filter=None, sort='', quiet=1, _self=cmd):
    """
DESCRIPTION

    "set_view_save" saves the active filter and sort as a named view, usable as the
    selector view:NAME. A filter expression given as the third argument replaces the
    active one; on the command line everything after the view name is that expression
    (the sort is always the active sort there; pass sort= from Python).

USAGE

    set_view_save name, view [, filter ]

EXAMPLES

    set_view_save rfd3_a1, top50
    set_view_save rfd3_a1, tight, rmsd < 1.0 and plddt > 85
    """
    c = _c()
    row = _set(name)
    expr = (row.get('filter') or '') if filter is None else str(filter).strip()
    selectors.count_filtered(c, row, expr=expr)    # validate
    sort = str(sort).strip() or (row.get('sort_key') or '')
    c.save_view(row['id'], str(view).strip(), filter=expr, sort_key=sort,
                sort_desc=int(row.get('sort_desc') or 1))
    return str(view).strip()


def set_view_delete(name, view, quiet=1, _self=cmd):
    """
DESCRIPTION

    "set_view_delete" removes a saved view.

USAGE

    set_view_delete name, view
    """
    row = _set(name)
    _c().delete_view(row['id'], str(view).strip())
    return _self.DEFAULT_SUCCESS


# -- Scene ------------------------------------------------------------------------------


def set_stage(name, entries, budget=0, quiet=1, _self=cmd):
    """
DESCRIPTION

    "set_stage" loads entries as objects in the set's group, superposed on the set's
    reference, with their metrics available to metrics_color. Refuses past the stage
    budget, naming what it would have to unstage.

USAGE

    set_stage name, entries [, budget ]

EXAMPLES

    set_stage rfd3_a1, top:3
    set_stage rfd3_a1, d_0417+d_0088
    """
    row = _set(name)
    found = selectors.resolve(_c(), row, entries)
    names = binding.stage(row, found, budget_override=int(budget) or None, _self=_self)
    if not int(quiet):
        colorprinting.parrot(' set_stage: %s' % ', '.join(names))
    return names


def set_unstage(name, entries='staged', quiet=1, _self=cmd):
    """
DESCRIPTION

    "set_unstage" deletes staged entries' objects. With the default selector, pinned
    entries stay; name them explicitly to unstage them too.

USAGE

    set_unstage name [, entries ]
    """
    row = _set(name)
    found = selectors.resolve(_c(), row, entries)
    explicit = str(entries).strip().lower() not in ('staged', 'all', 'filtered')
    removed = binding.unstage(row, found, include_pinned=explicit, _self=_self)
    if not int(quiet):
        colorprinting.parrot(' set_unstage: %s' % (', '.join(removed) or 'nothing'))
    return removed


def set_peek(name='', entry='', quiet=1, _self=cmd):
    """
DESCRIPTION

    "set_peek" shows one entry in the hidden peek object, replacing the previous peek.
    With no arguments it clears the peek.

USAGE

    set_peek [ name, entry ]
    """
    if not str(name).strip():
        binding.clear_peek(_self=_self)
        return ''
    row = _set(name)
    found = selectors.resolve(_c(), row, entry)
    if len(found) != 1:
        raise SetInputError('set_peek shows one entry; %r names %d' % (entry, len(found)))
    return binding.peek(row, found[0], _self=_self)


def set_reference(name, object='', quiet=1, _self=cmd):
    """
DESCRIPTION

    "set_reference" names the object staged and peeked entries are superposed on.
    With no object, prints the current one.

USAGE

    set_reference name [, object ]
    """
    row = _set(name)
    obj = str(object).strip()
    if obj:
        if obj not in (_self.get_names('all') or []):
            raise SetNotFound('no object %r' % obj)
        _c().update_set(row['id'], reference=obj)
        return obj
    if not int(quiet):
        colorprinting.parrot(' set_reference: %s' % (row.get('reference') or '(none)'))
    return row.get('reference') or ''


def set_budget(n, name='', quiet=1, _self=cmd):
    """
DESCRIPTION

    "set_budget" sets how many staged objects a set may put in the scene, or without a
    set name the default for every set in this file.

USAGE

    set_budget n [, name ]
    """
    n = int(n)
    if n < 1:
        raise SetInputError('the budget must be at least 1')
    if str(name).strip():
        _c().update_set(_set(name)['id'], budget=n)
    else:
        _c().meta_set('stage_budget', str(n))
    return n


# -- Files -------------------------------------------------------------------------------


def set_export(name, path, entries='filtered', format='', quiet=1, _self=cmd):
    """
DESCRIPTION

    "set_export" writes entries out: a folder (one CIF per entry plus entries.csv), a
    CSV of the table, or a FASTA of the sequences. The format comes from the path's
    extension when not given; no extension means a folder.

USAGE

    set_export name, path [, entries [, format ]]
    """
    c = _c()
    row = _set(name)
    found = selectors.resolve(c, row, entries)
    path = _self.exp_path(str(path))
    fmt = str(format).strip().lower()
    if not fmt:
        ext = os.path.splitext(path)[1].lower()
        fmt = {'.csv': 'csv', '.fasta': 'fasta', '.fa': 'fasta'}.get(ext, 'folder')
    if fmt == 'csv':
        document.write_csv(c, row['id'], found, path)
    elif fmt == 'fasta':
        document.write_fasta(c, found, path)
    elif fmt == 'folder':
        document.write_folder(c, row['id'], found, path)
    else:
        raise SetInputError('format must be folder, csv or fasta')
    if not int(quiet):
        colorprinting.parrot(' set_export: %d entries to %s' % (len(found), path))
    return path


def set_import(path, name='', kind='structures', quiet=1, _self=cmd):
    """
DESCRIPTION

    "set_import" creates a set from a folder, a structure file or a FASTA, named after
    it unless a name is given.

USAGE

    set_import path [, name [, kind ]]
    """
    path = _self.exp_path(str(path))
    if not os.path.exists(path):
        raise SetNotFound('no such path: %s' % path)
    set_name = str(name).strip() or document.stem(path.rstrip('/'))
    set_create(set_name, kind=kind, quiet=1, _self=_self)
    try:
        set_add(set_name, path, quiet=quiet, _self=_self)
    except Exception:
        try:
            _c().delete_set(_set(set_name)['id'])
        except Exception:
            pass
        raise
    return set_name
