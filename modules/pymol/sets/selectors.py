"""Entry selectors: the one-string way every `set_*` command names entries (#415, spec §4.1).

    d_0417            one entry by name
    d_0417+d_0088     several
    all               every entry
    filtered          the active filter's matches, in the active sort
    top:20            the first 20 of `filtered`
    starred rejected staged pinned      by flag
    view:top50        a saved view's matches
    run:<id>          produced by one run

Selectors are not composable with and/or; that is what `set_filter` is for. A name that
matches nothing raises SetNotFound, never yields an empty selection: an agent that
mistypes a name over MCP must hear about it rather than stage nothing.

No session access here. `resolve` needs only a Container and the filter compiler.
"""
from . import filter as _filter
from .errors import SetInputError, SetNotFound

FLAGS = ('starred', 'rejected', 'staged', 'pinned')
KEYWORDS = ('all', 'filtered') + FLAGS


def _columns_map(container, set_id):
    return {c['column']: c.get('dtype', 'float') for c in container.columns(set_id)
            if c.get('column')}


def _order(set_row, columns):
    """The ORDER BY for a set's active sort, or '' for delivery order.

    The sort key is validated against the declared columns here, so a stale
    `sets.sort_key` (its column was never declared in this file) falls back to `e.ord`
    instead of raising inside a SELECT.
    """
    key = set_row.get('sort_key') or ''
    if not key:
        return ''
    direction = 'DESC' if int(set_row.get('sort_desc') or 0) else 'ASC'
    if key in columns:
        # NULLs last whichever way we sort: an unmeasured entry is not "the worst".
        return 'm."%s" IS NULL, m."%s" %s, e.ord' % (key, key, direction)
    if key in ('name', 'ord', 'created'):
        return 'e.%s %s' % (key, direction)
    return ''


def filtered(container, set_row, expr=None, order_by=None, limit=None):
    """Entries matching `expr` (default: the set's active filter) in the active sort."""
    columns = _columns_map(container, set_row['id'])
    if expr is None:
        expr = set_row.get('filter') or ''
    where, params = _filter.compile(expr, columns)
    if order_by is None:
        order_by = _order(set_row, columns)
    return container.entries(set_row['id'], where=where, params=params,
                             order_by=order_by, limit=limit)


def count_filtered(container, set_row, expr=None):
    columns = _columns_map(container, set_row['id'])
    if expr is None:
        expr = set_row.get('filter') or ''
    where, params = _filter.compile(expr, columns)
    return container.count(set_row['id'], where=where, params=params)


def resolve(container, set_row, selector):
    """The entry dicts a selector names, in selector order (or sort order for the
    keyword forms). Raises SetNotFound for an unknown name/view/run, SetInputError for
    a malformed selector."""
    sel = str(selector or '').strip()
    if not sel:
        raise SetInputError('an entry selector is required (a name, all, filtered,'
                            ' top:N, starred, view:NAME, run:ID)')
    set_id = set_row['id']
    low = sel.lower()

    if low == 'all':
        return container.entries(set_id)
    if low == 'filtered':
        return filtered(container, set_row)
    if low in FLAGS:
        where = {'starred': 'e.starred = 1', 'rejected': 'e.rejected = 1',
                 'pinned': 'e.pinned = 1',
                 'staged': 'e.staged_object IS NOT NULL'}[low]
        return container.entries(set_id, where=where)
    if low.startswith('top:'):
        try:
            n = int(sel[4:])
        except ValueError:
            raise SetInputError('top:N needs an integer, got %r' % sel[4:])
        if n < 1:
            raise SetInputError('top:N needs N >= 1')
        return filtered(container, set_row, limit=n)
    if low.startswith('view:'):
        name = sel[5:]
        view = container.view(set_id, name)        # SetNotFound if absent
        row = dict(set_row)
        row['sort_key'] = view.get('sort_key') or ''
        row['sort_desc'] = view.get('sort_desc', 1)
        return filtered(container, row, expr=view.get('filter') or '')
    if low.startswith('run:'):
        run_id = sel[4:]
        container.run(run_id)                      # SetNotFound if absent
        return container.entries(set_id, where='e.run_id = ?', params=(run_id,))

    out = []
    for name in sel.split('+'):
        name = name.strip()
        if not name:
            continue
        out.append(container.entry(set_id, name))  # SetNotFound if absent
    if not out:
        raise SetInputError('selector %r names no entries' % selector)
    return out
