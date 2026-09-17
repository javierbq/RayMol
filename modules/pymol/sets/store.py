"""The Container: one open .raymol database and everything in it.

WHY A DATABASE AND NOT A DICT WITH A .pse ROUND TRIP, which is what the metrics and MSA
stores are. A set is the record of a campaign: a thousand designs, each a structure and
a row of numbers, delivered over hours by a tool that may crash the app half-way. That
record has to be on disk the moment a result lands -- not on Save -- and has to be
filtered and sorted without loading it all, which is what SQLite is for and a pickle is
not. So results are written in place as they arrive, only the session blob waits for an
explicit Save, and `save x.raymol` to a new path is `VACUUM INTO` followed by carrying
on in the new file.

WHY NOTHING HERE IMPORTS `cmd`. An entry is data; an object is a scene actor. The two
meet only in binding.py, when an entry is staged or peeked. Keeping the session out of
this module is what lets a test, an importer or a Swift reader exercise the container
without one, and is why every method here takes ids and text rather than objects.

WHY ONE WRITER AND EXPLICIT TRANSACTIONS. The connection runs in autocommit mode and
every mutating method wraps itself in `_tx()`, which begins on the outermost call,
bumps `meta.version` once, and commits -- or rolls the whole thing back, DDL included,
on any exception. So `add_entry` (which declares columns, writes blobs, scalars and
arrays) either lands whole or not at all, and a watcher polling `version()` can tell
"something changed" with one integer read.

Blob reference counts are maintained here, on every insert and delete, rather than by
a periodic scan: a scan would have to read every `chains` and `arrays` row to find out
what is still referenced, and `blob_stats()` should be a cheap question.
"""
import atexit
import json
import os
import secrets
import sqlite3
import threading
import tempfile
import time

from ..metrics.schema import MetricSpec, ARRAY_SCOPES
from ..metrics.errors import MetricSchemaError
from ..msas.store import _FORBIDDEN as _FORBIDDEN_NAME_CHARS
from . import blobs, schema
from .errors import (SetError, SetFormatError, SetInputError, SetNameConflict,
                     SetNotFound)

#: Fields `update_set` may write. Anything else is either identity (id, name, kind,
#: created) with its own path, or does not exist and would be a caller's typo.
SET_FIELDS = frozenset(('note', 'tool', 'group_name', 'budget', 'ranking_key',
                        'sort_key', 'sort_desc', 'filter', 'columns', 'reference'))

#: Fields `update_entry` may write: the user-facing flags and links, never the
#: identity or the derived counts.
ENTRY_FIELDS = frozenset(('starred', 'rejected', 'tags', 'note', 'staged_object',
                          'pinned', 'parents'))

_ENTRY_JSON = ('sequences', 'parents')
_SET_JSON = ('columns',)
_VIEW_JSON = ('columns',)

#: Batch size for `IN (?, ?, ...)` lists. Well under any SQLite variable limit.
_CHUNK = 500


def _now():
    return time.time()


def _dumps(value):
    return json.dumps(value, sort_keys=True, default=str)


def _row(cursor, row):
    return {description[0]: row[i] for i, description in enumerate(cursor.description)}


def _parse_json(record, fields):
    for field in fields:
        text = record.get(field)
        if isinstance(text, str):
            try:
                record[field] = json.loads(text)
            except ValueError:
                pass
    return record


#: Extra rules for ENTRY names, which also have to survive the selector language
#: (spec §4.1): '+' joins names and ':' introduces top:/view:/run:, and the keyword
#: forms are resolved before a bare name is.
_ENTRY_FORBIDDEN_CHARS = set('+:')
ENTRY_RESERVED = frozenset(('all', 'filtered', 'starred', 'rejected', 'staged', 'pinned'))


def check_name(name, what='set'):
    """`name` if it can be a set, entry or view name, else raise SetInputError.

    The alphabet is the MSA store's: an entry name becomes the staged object's name
    and a set name a group's, and both pass through the command parser, which splits
    on ',' and whitespace and quotes with the rest. An entry name additionally may not
    contain '+' or ':' or be one of the selector keywords, or `set_stage s, <name>`
    could never mean it.
    """
    if not isinstance(name, str) or not name.strip():
        raise SetInputError('a %s needs a name' % what)
    name = name.strip()
    forbidden = _FORBIDDEN_NAME_CHARS
    if what == 'entry':
        forbidden = forbidden | _ENTRY_FORBIDDEN_CHARS
        if name.lower() in ENTRY_RESERVED:
            raise SetInputError('%r is a selector keyword and cannot name an entry' % name)
    bad = sorted(set(name) & forbidden)
    if bad:
        raise SetInputError(
            'invalid %s name %r: %s cannot appear in it'
            % (what, name, ', '.join(repr(c) for c in bad)))
    return name


def legal_entry_name(name):
    """The nearest legal entry name: forbidden characters become '_', a reserved word
    gets a trailing '_', an empty name becomes 'entry'. For names that come from files
    and objects, where refusing would be unhelpful; `check_name` is for names typed."""
    text = ''.join('_' if c in (_FORBIDDEN_NAME_CHARS | _ENTRY_FORBIDDEN_CHARS) else c
                   for c in str(name or '').strip()) or 'entry'
    if text.lower() in ENTRY_RESERVED:
        text += '_'
    return text


def _coerce(dtype, value):
    """`value` as SQLite wants it for `dtype`, with None passing through untouched.

    Mirrors MetricSpec.cast: absent is not zero, and NaN/inf are absent.
    """
    if value is None:
        return None
    try:
        if dtype == 'float':
            value = float(value)
            if value != value or value in (float('inf'), float('-inf')):
                return None
            return value
        if dtype in ('int', 'bool'):
            return int(value)
        return str(value)
    except (TypeError, ValueError):
        raise SetInputError('expected %s, got %r' % (dtype, value))


class _Transaction:
    """Reentrant BEGIN/COMMIT with a single version bump at the outermost level.

    Holds the container's lock for the whole transaction. PyMOL runs commands from more
    than one thread (the GUI/parser thread, `cmd.do`, the MCP server, `spawn`), so the
    connection is opened with `check_same_thread=False` and every statement goes
    through this lock or the `_q`/`_one`/`_all` helpers, which take it too. A reentrant
    lock, because `add_entry` nests `declare_columns` inside its own transaction.
    """

    def __init__(self, container):
        self.container = container

    def __enter__(self):
        c = self.container
        c._lock.acquire()
        if c._depth == 0:
            c._conn.execute('BEGIN IMMEDIATE')
        c._depth += 1
        return c._conn

    def __exit__(self, exc_type, exc, tb):
        c = self.container
        try:
            c._depth -= 1
            if c._depth:
                return False
            if exc_type is None:
                try:
                    c._conn.execute(
                        "UPDATE meta SET value = CAST(CAST(value AS INTEGER) + 1 AS TEXT)"
                        " WHERE key = 'version'")
                    c._conn.execute('COMMIT')
                except sqlite3.Error:
                    # A failed COMMIT (disk full, BUSY) leaves the transaction open;
                    # without this every later BEGIN fails for the rest of the process.
                    try:
                        c._conn.execute('ROLLBACK')
                    except sqlite3.Error:
                        pass
                    raise
            else:
                c._conn.execute('ROLLBACK')
            return False
        finally:
            c._lock.release()


class Container:
    """One .raymol file, open for writing.

    Creating a Container on a path that does not exist (or is empty) lays down the
    schema; on an existing file it checks the format version and migrates forward.
    Both use the same pragmas, so a file written here and a `VACUUM INTO` copy behave
    alike once reopened.
    """

    def __init__(self, path):
        path = os.fspath(path)
        fresh = not os.path.exists(path) or os.path.getsize(path) == 0
        self._path = path
        self._depth = 0
        self._conn = None
        self._lock = threading.RLock()
        try:
            conn = sqlite3.connect(path, isolation_level=None, check_same_thread=False)
        except sqlite3.Error as exc:
            raise SetFormatError('cannot open %s: %s' % (path, exc))
        if not fresh:
            # Look before touching: setting WAL on someone else's database (a file
            # misnamed .raymol) would persist in THEIR file.
            try:
                has_meta = conn.execute(
                    "SELECT 1 FROM sqlite_master WHERE type='table' AND name='meta'"
                ).fetchone()
            except sqlite3.DatabaseError as exc:
                conn.close()
                raise SetFormatError('%s is not a .raymol file: %s' % (path, exc))
            if not has_meta:
                conn.close()
                raise SetFormatError('%s is not a .raymol file (no meta table)' % path)
        try:
            conn.execute('PRAGMA journal_mode=WAL')
            conn.execute('PRAGMA synchronous=NORMAL')
            conn.execute('PRAGMA foreign_keys=ON')
        except sqlite3.DatabaseError as exc:
            conn.close()
            raise SetFormatError('%s is not a .raymol file: %s' % (path, exc))
        self._conn = conn
        # From here on this path is OPEN IN THIS PROCESS, and no sweep may unlink it
        # (#447 review): `close()` is what takes it out again, including the `close()`
        # in the failure path below.
        _register_open(path)
        try:
            if fresh:
                schema.create(conn)
            else:
                schema.open_or_migrate(conn)
        except SetError:
            self.close()
            raise

    # -- lifecycle ---------------------------------------------------------------

    @property
    def path(self):
        return self._path

    @property
    def closed(self):
        return self._conn is None

    def _tx(self):
        return _Transaction(self)

    def _q(self, sql, params=()):
        with self._lock:
            return self._conn.execute(sql, params)

    def _one(self, sql, params=()):
        with self._lock:
            cursor = self._conn.execute(sql, params)
            row = cursor.fetchone()
        return None if row is None else _row(cursor, row)

    def _all(self, sql, params=()):
        with self._lock:
            cursor = self._conn.execute(sql, params)
            rows = cursor.fetchall()
        return [_row(cursor, row) for row in rows]

    def close(self):
        """Checkpoint and close. Idempotent, so `save_into` and `replace` may both call
        it on the same container without one having to know about the other."""
        if self._conn is None:
            return
        try:
            self._conn.execute('PRAGMA wal_checkpoint(TRUNCATE)')
        except sqlite3.Error:
            pass
        self._conn.close()
        self._conn = None
        _unregister_open(self._path)

    def holds_entries(self):
        """True / False / None: does any set in this container hold an entry (#447)?

        The question "is there anything in here worth keeping" is asked on the way
        out -- in `reset`, which every quit reaches through atexit -- and it is asked
        HERE, of the live connection, rather than by reopening the file afterwards:
        the connection is already warm, `EXISTS` stops at the first row, and a reopen
        would have to cope with the WAL we are about to checkpoint away.

        NONE MEANS "I CANNOT ANSWER", and is not False, because the caller's False
        branch DELETES THE FILE. A closed container (a failed `save_raymol` can leave
        one installed) and an IO error on the EXISTS are both "ask the disk instead",
        which `retire_working_file` does; only a clean `entries = 0` may delete.

        An entry is the unit, so a set with columns and a run but no landed result --
        a quit between launching a batch and its first design -- counts as empty and
        its container goes. That is spec §2.1's rule ("a non-empty set"), and the
        thing being protected is results, of which there are none yet.
        """
        if self._conn is None:
            return None
        try:
            row = self._one('SELECT EXISTS(SELECT 1 FROM entries) AS held')
        except sqlite3.Error:
            return None
        return bool(row and row['held'])

    def version(self):
        return int(self.meta_get('version', '0'))

    def bump(self):
        """Advance `meta.version` with no other change. Public so a caller that
        mutates something the store does not know about (a scene link, say) can still
        signal watchers through the one integer they poll."""
        with self._tx():
            pass

    def meta_get(self, key, default=None):
        row = self._one('SELECT value FROM meta WHERE key = ?', (str(key),))
        return default if row is None else row['value']

    def meta_set(self, key, value):
        with self._tx() as conn:
            conn.execute('INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)',
                         (str(key), str(value)))

    def save_into(self, path):
        """Copy this database to `path`, close this one, return a Container on the copy.

        Save As. The copy is a checkpointed, compacted snapshot; the old file is left
        where it was because whether it should go (a pid-scoped working file) or stay
        (the user's previous document) is the caller's decision, not the store's.
        """
        path = os.fspath(path)
        if os.path.abspath(path) == os.path.abspath(self._path):
            raise SetInputError('%s is already the open document' % path)
        with self._lock:
            if self._depth:
                raise SetInputError('cannot save while a write is in progress')
            remove_db_files(path)
            try:
                self._conn.execute('PRAGMA wal_checkpoint(TRUNCATE)')
                self._conn.execute('VACUUM INTO ?', (path,))
            except sqlite3.Error as exc:
                raise SetFormatError('could not save into %s: %s' % (path, exc))
            self.close()
        return Container(path)

    # -- session -----------------------------------------------------------------

    def write_session(self, pse_bytes, pse_version=None, app_version=''):
        if not isinstance(pse_bytes, (bytes, bytearray, memoryview)):
            raise SetInputError('the session must be bytes')
        with self._tx() as conn:
            conn.execute(
                'INSERT OR REPLACE INTO session'
                ' (id, pse, saved, pse_version, app_version) VALUES (1, ?, ?, ?, ?)',
                (sqlite3.Binary(bytes(pse_bytes)), _now(),
                 None if pse_version is None else float(pse_version),
                 str(app_version or '')))
            if app_version:
                conn.execute("UPDATE meta SET value = ? WHERE key = 'app_version'",
                             (str(app_version),))

    def read_session(self):
        row = self._one('SELECT pse FROM session WHERE id = 1')
        return None if row is None else bytes(row['pse'])

    # -- ids ---------------------------------------------------------------------

    def _new_id(self, table):
        while True:
            candidate = secrets.token_hex(4)
            if self._one('SELECT 1 FROM %s WHERE id = ?' % table, (candidate,)) is None:
                return candidate

    # -- sets --------------------------------------------------------------------

    def _set_dict(self, record):
        return _parse_json(record, _SET_JSON)

    def _set_row(self, set_id):
        row = self._one('SELECT * FROM sets WHERE id = ?', (set_id,))
        if row is None:
            raise SetNotFound('no set with id %r' % (set_id,))
        return row

    def _table(self, set_id):
        return schema.quote(schema.metrics_table(set_id))

    def _table_columns(self, set_id):
        return [r['name'] for r in
                self._all('PRAGMA table_info(%s)' % self._table(set_id))]

    def create_set(self, name, kind='structures', note='', tool='', group_name=None,
                   ranking_key=''):
        name = check_name(name, 'set')
        if kind not in schema.SET_KINDS:
            raise SetInputError('unknown set kind %r; kinds are: %s'
                                % (kind, ', '.join(schema.SET_KINDS)))
        if ranking_key:
            schema.check_key(ranking_key.split('__')[0])
        with self._tx() as conn:
            if self._one('SELECT 1 FROM sets WHERE name = ?', (name,)):
                raise SetNameConflict('a set named %r already exists' % name)
            set_id = self._new_id('sets')
            conn.execute(
                'INSERT INTO sets (id, name, kind, created, tool, note, group_name,'
                ' ranking_key) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
                (set_id, name, kind, _now(), str(tool or ''), str(note or ''),
                 str(group_name if group_name is not None else name),
                 str(ranking_key or '')))
            conn.execute(
                'CREATE TABLE %s (entry_id TEXT PRIMARY KEY'
                ' REFERENCES entries(id) ON DELETE CASCADE)' % self._table(set_id))
        return self.get_set(set_id)

    def get_set(self, name_or_id):
        """The set called `name_or_id`, tried as an id first: ids are generated, so
        the more specific reading is the safer one if a user names a set '1a2b3c4d'."""
        row = self._one('SELECT * FROM sets WHERE id = ?', (str(name_or_id),))
        if row is None:
            row = self._one('SELECT * FROM sets WHERE name = ?', (str(name_or_id),))
        if row is None:
            known = [r['name'] for r in
                     self._all('SELECT name FROM sets ORDER BY created')]
            raise SetNotFound('no set named %r; sets: %s'
                              % (name_or_id, ', '.join(known) or '(none)'))
        return self._set_dict(row)

    def sets(self):
        return [self._set_dict(r) for r in
                self._all('SELECT * FROM sets ORDER BY created, rowid')]

    def rename_set(self, set_id, new_name):
        """Rename. The group name follows when it was the set's own name, so a set
        that never had a custom group keeps matching its group after the rename."""
        new_name = check_name(new_name, 'set')
        with self._tx() as conn:
            row = self._set_row(set_id)
            if new_name == row['name']:
                return
            if self._one('SELECT 1 FROM sets WHERE name = ?', (new_name,)):
                raise SetNameConflict('a set named %r already exists' % new_name)
            conn.execute('UPDATE sets SET name = ? WHERE id = ?', (new_name, set_id))
            if row['group_name'] == row['name']:
                conn.execute('UPDATE sets SET group_name = ? WHERE id = ?',
                             (new_name, set_id))

    def update_set(self, set_id, **fields):
        bad = sorted(set(fields) - SET_FIELDS)
        if bad:
            raise SetInputError('update_set cannot change %s; allowed: %s'
                                % (', '.join(bad), ', '.join(sorted(SET_FIELDS))))
        if not fields:
            return
        values = {}
        for key, value in fields.items():
            if key == 'columns':
                values[key] = _dumps(list(value))
            elif key == 'budget':
                values[key] = None if value is None else int(value)
            elif key == 'sort_desc':
                values[key] = int(bool(int(value)))
            elif key in ('ranking_key', 'sort_key') and value:
                values[key] = str(value)
            else:
                values[key] = str(value if value is not None else '')
        assignments = ', '.join('%s = ?' % schema.quote(k) for k in values)
        with self._tx() as conn:
            self._set_row(set_id)
            conn.execute('UPDATE sets SET %s WHERE id = ?' % assignments,
                         tuple(values.values()) + (set_id,))
            if 'ranking_key' in values:
                self._ensure_ranking_index(set_id)

    def delete_set(self, set_id):
        with self._tx() as conn:
            self._set_row(set_id)
            ids = [r['id'] for r in
                   self._all('SELECT id FROM entries WHERE set_id = ?', (set_id,))]
            self._release_blobs(ids)
            conn.execute('DELETE FROM sets WHERE id = ?', (set_id,))
            conn.execute('DROP TABLE IF EXISTS %s' % self._table(set_id))
            self._delete_orphan_blobs()

    # -- columns -----------------------------------------------------------------

    def _ensure_ranking_index(self, set_id):
        row = self._set_row(set_id)
        key = row['ranking_key']
        if not key or key not in self._table_columns(set_id):
            return
        self._conn.execute(
            'CREATE INDEX IF NOT EXISTS %s ON %s (%s)'
            % (schema.quote('%s_%s' % (schema.metrics_table(set_id), key)),
               self._table(set_id), schema.quote(key)))

    def declare_columns(self, set_id, specs):
        """Add scalar columns for `specs` and record every spec in `sets.columns`.

        A spec is a MetricSpec, or a dict of its fields plus optional `chain` (which
        makes the column `key__chain`) and optional `tool` (kept, so the columns can be
        grouped back into runs when a staged entry's metrics are copied to the metrics
        store). Array-scope specs get no column -- their values live in `arrays` -- but
        are recorded with `column: None` so `set_info` and a plot can list them.
        Re-declaring a column is a no-op; changing its dtype is not attempted.
        """
        specs = list(specs)
        if not specs:
            return
        with self._tx() as conn:
            row = self._set_row(set_id)
            declared = list(json.loads(row['columns'] or '[]'))
            seen = {_column_identity(c) for c in declared}
            existing = set(self._table_columns(set_id))
            for spec in specs:
                chain = None
                tool = ''
                if isinstance(spec, dict):
                    fields = dict(spec)
                    chain = fields.pop('chain', None)
                    tool = str(fields.pop('tool', '') or '')
                    fields.pop('column', None)
                    try:
                        spec = MetricSpec(**fields)
                    except (MetricSchemaError, TypeError) as exc:
                        raise SetInputError('bad column spec %r: %s' % (spec, exc))
                elif not isinstance(spec, MetricSpec):
                    raise SetInputError(
                        'expected a MetricSpec or a dict of its fields, got %r' % (spec,))
                schema.check_key(spec.key)
                record = spec.as_dict()
                record['chain'] = None if chain in (None, '') else str(chain)
                record['tool'] = tool
                if spec.scope in ARRAY_SCOPES:
                    record['column'] = None
                else:
                    column = schema.column_name(spec.key, chain)
                    if column in schema.RESERVED_COLUMNS:
                        raise SetInputError(
                            '%r is a reserved column name (an entries field)' % column)
                    record['column'] = column
                    if column not in existing:
                        conn.execute('ALTER TABLE %s ADD COLUMN %s %s'
                                     % (self._table(set_id), schema.quote(column),
                                        schema.sql_type(spec.dtype)))
                        existing.add(column)
                identity = _column_identity(record)
                if identity not in seen:
                    declared.append(record)
                    seen.add(identity)
            conn.execute('UPDATE sets SET columns = ? WHERE id = ?',
                         (_dumps(declared), set_id))
            self._ensure_ranking_index(set_id)

    def columns(self, set_id):
        return list(json.loads(self._set_row(set_id)['columns'] or '[]'))

    def _column_dtypes(self, set_id):
        return {c['column']: c['dtype'] for c in self.columns(set_id) if c.get('column')}

    # -- runs --------------------------------------------------------------------

    def add_run(self, set_id, tool, tool_version='', inputs=None, parent_set_id=None,
                note=''):
        tool = str(tool or '').strip()
        if not tool:
            raise SetInputError('a run needs a tool')
        with self._tx() as conn:
            self._set_row(set_id)
            run_id = self._new_id('runs')
            conn.execute(
                'INSERT INTO runs (id, set_id, tool, tool_version, created, inputs,'
                ' parent_set_id, note) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
                (run_id, set_id, tool, str(tool_version or ''), _now(),
                 _dumps(dict(inputs or {})), parent_set_id, str(note or '')))
        return run_id

    def runs(self, set_id):
        return [_parse_json(r, ('inputs',)) for r in self._all(
            'SELECT * FROM runs WHERE set_id = ? ORDER BY created, rowid', (set_id,))]

    def run(self, run_id):
        row = self._one('SELECT * FROM runs WHERE id = ?', (run_id,))
        if row is None:
            raise SetNotFound('no run with id %r' % (run_id,))
        return _parse_json(row, ('inputs',))

    # -- blobs -------------------------------------------------------------------

    def _hold_blob(self, hash, kind, data, size):
        """Insert or re-reference a blob. One statement, so a hash that already
        exists costs a conflict, not a read followed by a write."""
        self._conn.execute(
            'INSERT INTO blobs (hash, kind, bytes, size, refs) VALUES (?, ?, ?, ?, 1)'
            ' ON CONFLICT(hash) DO UPDATE SET refs = refs + 1',
            (hash, kind, sqlite3.Binary(data), size))

    def _release_blobs(self, entry_ids):
        """refs-- once per chains/arrays row of `entry_ids`. Per row, not per distinct
        hash: a homodimer holds the same blob twice and was counted twice."""
        for chunk in _chunks(entry_ids):
            marks = ','.join('?' * len(chunk))
            hashes = self._all(
                'SELECT blob FROM chains WHERE entry_id IN (%s)'
                ' UNION ALL SELECT blob FROM arrays WHERE entry_id IN (%s)'
                % (marks, marks), tuple(chunk) * 2)
            self._conn.executemany(
                'UPDATE blobs SET refs = refs - 1 WHERE hash = ?',
                [(h['blob'],) for h in hashes])

    def _delete_orphan_blobs(self):
        self._conn.execute(
            'DELETE FROM blobs WHERE refs <= 0'
            ' AND hash NOT IN (SELECT blob FROM chains)'
            ' AND hash NOT IN (SELECT blob FROM arrays)')

    def blob_stats(self):
        row = self._one(
            'SELECT count(*) AS count, COALESCE(sum(length(bytes)), 0) AS bytes,'
            ' COALESCE(sum(refs <= 0), 0) AS orphans FROM blobs')
        return {'count': int(row['count']), 'bytes': int(row['bytes']),
                'orphans': int(row['orphans'])}

    # -- entries -----------------------------------------------------------------

    def add_entry(self, set_id, name, run_id=None, sequences=None, parents=(),
                  chains=(), scalars=None, arrays=(), specs=()):
        """One entry, whole or not at all.

        `chains` is (chain_id, cif_text) pairs in display order; `scalars` maps a
        column name -- or a (key, chain) pair -- to a value; `arrays` is dicts of
        key, scope, chain, index, values and the MetricSpec (for the encoding choice).
        `specs` is declared first so a caller can deliver a tool's first result with
        its schema in one call.
        """
        name = check_name(name, 'entry')
        sequences = dict(sequences or {})
        chains = list(chains)
        with self._tx() as conn:
            self._set_row(set_id)
            if specs:
                self.declare_columns(set_id, specs)
            if run_id is not None and self._one(
                    'SELECT 1 FROM runs WHERE id = ? AND set_id = ?',
                    (run_id, set_id)) is None:
                raise SetNotFound('no run %r in set %r' % (run_id, set_id))
            if self._one('SELECT 1 FROM entries WHERE set_id = ? AND name = ?',
                         (set_id, name)):
                raise SetNameConflict('an entry named %r already exists in this set'
                                      % name)
            ord = self._one('SELECT COALESCE(MAX(ord), 0) + 1 AS n FROM entries'
                            ' WHERE set_id = ?', (set_id,))['n']
            entry_id = self._new_id('entries')
            chain_ids = {str(c) for c, _ in chains} | {str(c) for c in sequences}
            conn.execute(
                'INSERT INTO entries (id, set_id, ord, name, run_id, created,'
                ' sequences, n_chains, n_residues, parents)'
                ' VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
                (entry_id, set_id, ord, name, run_id, _now(),
                 _dumps({str(c): str(s) for c, s in sequences.items()}),
                 len(chain_ids), sum(len(s) for s in sequences.values()),
                 _dumps([str(p) for p in parents or ()])))
            conn.execute('INSERT INTO %s (entry_id) VALUES (?)' % self._table(set_id),
                         (entry_id,))
            for i, (chain, text) in enumerate(chains):
                self._add_chain(entry_id, str(chain), i, text)
            if scalars:
                self._write_scalars(set_id, entry_id, scalars)
            for spec in arrays:
                self._add_array(entry_id, spec)
        return entry_id

    def _add_chain(self, entry_id, chain, ord, text):
        hash, gz, size = blobs.encode_cif(text)
        self._hold_blob(hash, 'cif', gz, size)
        try:
            self._conn.execute(
                'INSERT INTO chains (entry_id, chain, ord, blob) VALUES (?, ?, ?, ?)',
                (entry_id, chain, ord, hash))
        except sqlite3.IntegrityError:
            raise SetInputError('chain %r given twice for one entry' % chain)

    def _resolve_column(self, set_id, key, chain=None):
        if isinstance(key, (tuple, list)):
            if len(key) != 2:
                raise SetInputError('a scalar key is a column name or (key, chain),'
                                    ' got %r' % (key,))
            key, chain = key
        if chain not in (None, ''):
            column = schema.column_name(key, chain)
        elif isinstance(key, str) and '__' in key:
            base, _, chain_part = key.partition('__')
            column = schema.column_name(base, chain_part)
        else:
            column = schema.check_key(key)
        dtypes = self._column_dtypes(set_id)
        if column not in dtypes:
            raise SetInputError(
                'column %r is not declared for this set; declare it first'
                ' (declared: %s)' % (column, ', '.join(sorted(dtypes)) or '(none)'))
        return column, dtypes[column]

    def _write_scalars(self, set_id, entry_id, scalars):
        columns = []
        values = []
        for key, value in dict(scalars).items():
            column, dtype = self._resolve_column(set_id, key)
            columns.append(schema.quote(column))
            values.append(_coerce(dtype, value))
        if not columns:
            return
        self._conn.execute(
            'UPDATE %s SET %s WHERE entry_id = ?'
            % (self._table(set_id), ', '.join('%s = ?' % c for c in columns)),
            tuple(values) + (entry_id,))

    def _add_array(self, entry_id, item):
        try:
            key = schema.check_key(item['key'])
            scope = item['scope']
            index = list(item['index'])
            values = list(item['values'])
        except KeyError as exc:
            raise SetInputError('an array needs %s' % exc)
        if scope not in ARRAY_SCOPES:
            raise SetInputError('%r is not an array scope (residue or pair)' % (scope,))
        chain = item.get('chain')
        chain = None if chain in (None, '') else str(chain)
        spec = item.get('spec')
        index = [[str(c), str(r)] for c, r in index]
        expected = len(index) ** 2 if scope == 'pair' else len(index)
        if len(values) != expected:
            raise SetInputError(
                '%r is %s-scope over %d residues, so it needs %d values, got %d'
                % (key, scope, len(index), expected, len(values)))
        encoding = blobs.choose_encoding(scope, spec)
        if encoding == 'u8q':
            lo = spec['lo'] if isinstance(spec, dict) else spec.lo
            hi = spec['hi'] if isinstance(spec, dict) else spec.hi
            data, scale, offset = blobs.encode_u8q(values, lo, hi)
        else:
            data, scale, offset = blobs.encode_f32(values), None, None
        hash = blobs.sha256_hex(data)
        self._hold_blob(hash, encoding, data, len(data))
        try:
            self._conn.execute(
                'INSERT INTO arrays (entry_id, key, scope, chain, blob, encoding,'
                ' scale, offset, index_json) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
                (entry_id, key, scope, chain, hash, encoding, scale, offset,
                 json.dumps(index)))
        except sqlite3.IntegrityError:
            raise SetInputError('array %r%s given twice for one entry'
                                % (key, '' if chain is None else ' for chain %s' % chain))

    def _entry_dict(self, record, scalar_columns=None):
        """An entries row as a dict with its JSON fields parsed and its wide-table
        values under 'scalars'. One shape for entry(), entry_by_id() and entries()."""
        record = _parse_json(record, _ENTRY_JSON)
        scalars = {}
        if scalar_columns:
            for column in scalar_columns:
                if column != 'entry_id':
                    scalars[column] = record.pop(column, None)
            record.pop('entry_id', None)
        record['scalars'] = scalars
        return record

    def entry(self, set_id, name):
        row = self._one('SELECT id FROM entries WHERE set_id = ? AND name = ?',
                        (set_id, name))
        if row is None:
            raise SetNotFound('no entry named %r in set %r' % (name, set_id))
        return self.entry_by_id(row['id'])

    def entry_by_id(self, entry_id):
        head = self._one('SELECT set_id FROM entries WHERE id = ?', (entry_id,))
        if head is None:
            raise SetNotFound('no entry with id %r' % (entry_id,))
        rows = self.entries(head['set_id'], where='e.id = ?', params=(entry_id,),
                            limit=1)
        if not rows:
            raise SetNotFound('no entry with id %r' % (entry_id,))
        return rows[0]

    def _entries_sql(self, set_id, select, where, order_by='', limit=None, offset=0):
        sql = ('%s FROM entries e LEFT JOIN %s m ON m.entry_id = e.id WHERE e.set_id = ?'
               % (select, self._table(set_id)))
        if where:
            sql += ' AND (%s)' % where
        if order_by is not None:
            sql += ' ORDER BY %s' % (order_by or 'e.ord')
        params = ()
        if limit is not None or offset:
            sql += ' LIMIT ? OFFSET ?'
            params = (-1 if limit is None else int(limit), int(offset or 0))
        return sql, params

    def entries(self, set_id, where='', params=(), order_by='', limit=None, offset=0):
        """Entries of a set, filtered by an SQL fragment over aliases `e` and `m`.

        `where` and `order_by` are trusted SQL from filter.py, whose grammar admits no
        raw identifiers or literals; `params` are bound after the set id.
        """
        sql, tail = self._entries_sql(set_id, 'SELECT e.*, m.*', where, order_by,
                                      limit, offset)
        with self._lock:
            cursor = self._conn.execute(sql, (set_id,) + tuple(params) + tail)
            fetched = cursor.fetchall()
        names = [d[0] for d in cursor.description]
        split = names.index('entry_id')     # e.* has no entry_id; m.* starts with it
        entry_names = names[:split]
        m_names = names[split:]
        out = []
        for row in fetched:
            record = dict(zip(entry_names, row[:len(entry_names)]))
            record = _parse_json(record, _ENTRY_JSON)
            record['scalars'] = {k: v for k, v in zip(m_names, row[len(entry_names):])
                                 if k != 'entry_id'}
            out.append(record)
        return out

    def has_entry_name(self, set_id, name):
        """True when this set already holds an entry called `name`.

        A POINT LOOKUP on the `UNIQUE (set_id, name)` index, and that is the whole
        reason it exists: `binding._unique_entry_name` used to answer the same question
        by reading every row of the set through `entries()`, which JSON-decodes
        `sequences` and `parents` per row and carries the whole metrics table along.
        Measured at 1000 landing entries (#453 review): 11.1 s of delivery, 16.8 s of
        18.6 s profiled inside that one call, 509k `_parse_json` calls. A batch lands one
        entry at a time, so the cost was quadratic in the set's own size.
        """
        return self._one('SELECT 1 FROM entries WHERE set_id = ? AND name = ?',
                         (set_id, str(name))) is not None

    def count(self, set_id, where='', params=()):
        sql, _ = self._entries_sql(set_id, 'SELECT count(*)', where, order_by=None)
        with self._lock:
            return int(self._conn.execute(sql, (set_id,) + tuple(params)).fetchone()[0])

    def update_entry(self, entry_id, **fields):
        bad = sorted(set(fields) - ENTRY_FIELDS)
        if bad:
            raise SetInputError('update_entry cannot change %s; allowed: %s'
                                % (', '.join(bad), ', '.join(sorted(ENTRY_FIELDS))))
        if not fields:
            return
        values = {}
        for key, value in fields.items():
            if key == 'parents':
                values[key] = _dumps([str(p) for p in value or ()])
            elif key in ('starred', 'rejected', 'pinned'):
                values[key] = int(bool(int(value)))
            elif key == 'staged_object':
                values[key] = None if value in (None, '') else str(value)
            else:
                values[key] = str(value if value is not None else '')
        assignments = ', '.join('%s = ?' % schema.quote(k) for k in values)
        with self._tx() as conn:
            cursor = conn.execute('UPDATE entries SET %s WHERE id = ?' % assignments,
                                  tuple(values.values()) + (entry_id,))
            if cursor.rowcount == 0:
                raise SetNotFound('no entry with id %r' % (entry_id,))

    def set_scalar(self, entry_id, key, value, chain=None):
        head = self._one('SELECT set_id FROM entries WHERE id = ?', (entry_id,))
        if head is None:
            raise SetNotFound('no entry with id %r' % (entry_id,))
        set_id = head['set_id']
        column, dtype = self._resolve_column(set_id, key, chain)
        with self._tx() as conn:
            conn.execute('INSERT OR IGNORE INTO %s (entry_id) VALUES (?)'
                         % self._table(set_id), (entry_id,))
            conn.execute('UPDATE %s SET %s = ? WHERE entry_id = ?'
                         % (self._table(set_id), schema.quote(column)),
                         (_coerce(dtype, value), entry_id))

    def delete_entries(self, entry_ids):
        entry_ids = [str(e) for e in entry_ids]
        if not entry_ids:
            return 0
        deleted = 0
        with self._tx() as conn:
            self._release_blobs(entry_ids)
            for chunk in _chunks(entry_ids):
                cursor = conn.execute(
                    'DELETE FROM entries WHERE id IN (%s)' % ','.join('?' * len(chunk)),
                    tuple(chunk))
                deleted += cursor.rowcount
            self._delete_orphan_blobs()
        return deleted

    def chain_cifs(self, entry_id):
        rows = self._all(
            'SELECT c.chain, b.bytes FROM chains c JOIN blobs b ON b.hash = c.blob'
            ' WHERE c.entry_id = ? ORDER BY c.ord', (entry_id,))
        return [(r['chain'], blobs.decode_cif(r['bytes'])) for r in rows]

    def array(self, entry_id, key, chain=None):
        """(index, values) for one array, decoded. `index` is [[chain, resi], ...]
        and `values` has len(index) entries for residue scope, its square for pair."""
        chain = None if chain in (None, '') else str(chain)
        row = self._one(
            'SELECT a.*, b.bytes FROM arrays a JOIN blobs b ON b.hash = a.blob'
            ' WHERE a.entry_id = ? AND a.key = ? AND a.chain IS ?',
            (entry_id, key, chain))
        if row is None:
            raise SetNotFound('entry %r has no array %r%s'
                              % (entry_id, key,
                                 '' if chain is None else ' for chain %s' % chain))
        index = json.loads(row['index_json'])
        n = len(index) ** 2 if row['scope'] == 'pair' else len(index)
        if row['encoding'] == 'u8q':
            values = blobs.decode_u8q(row['bytes'], row['scale'], row['offset'])
            if len(values) != n:
                raise SetInputError('u8q blob holds %d values, expected %d'
                                    % (len(values), n))
        else:
            values = blobs.decode_f32(row['bytes'], n)
        return index, values

    def arrays_of(self, entry_id):
        """The arrays rows of an entry, index parsed, blobs untouched."""
        out = []
        for row in self._all('SELECT * FROM arrays WHERE entry_id = ? ORDER BY rowid',
                             (entry_id,)):
            row['index'] = json.loads(row.pop('index_json'))
            out.append(row)
        return out

    # -- views -------------------------------------------------------------------

    def save_view(self, set_id, name, filter='', sort_key='', sort_desc=1, columns=()):
        name = check_name(name, 'view')
        with self._tx() as conn:
            self._set_row(set_id)
            row = self._one('SELECT id FROM views WHERE set_id = ? AND name = ?',
                            (set_id, name))
            values = (str(filter or ''), str(sort_key or ''), int(bool(int(sort_desc))),
                      _dumps(list(columns or ())))
            if row:
                conn.execute(
                    'UPDATE views SET filter = ?, sort_key = ?, sort_desc = ?,'
                    ' columns = ? WHERE id = ?', values + (row['id'],))
                return row['id']
            view_id = self._new_id('views')
            conn.execute(
                'INSERT INTO views (id, set_id, name, filter, sort_key, sort_desc,'
                ' columns, created) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
                (view_id, set_id, name) + values + (_now(),))
            return view_id

    def views(self, set_id):
        return [_parse_json(r, _VIEW_JSON) for r in self._all(
            'SELECT * FROM views WHERE set_id = ? ORDER BY created, rowid', (set_id,))]

    def view(self, set_id, name):
        row = self._one('SELECT * FROM views WHERE set_id = ? AND name = ?',
                        (set_id, name))
        if row is None:
            raise SetNotFound('no view named %r in set %r' % (name, set_id))
        return _parse_json(row, _VIEW_JSON)

    def delete_view(self, set_id, name):
        with self._tx() as conn:
            cursor = conn.execute('DELETE FROM views WHERE set_id = ? AND name = ?',
                                  (set_id, name))
            if cursor.rowcount == 0:
                raise SetNotFound('no view named %r in set %r' % (name, set_id))

    def __repr__(self):
        return 'Container(%r%s)' % (self._path, ', closed' if self.closed else '')


def _column_identity(record):
    """What makes two declared columns the same: the wide-table column for a scalar,
    the (key, chain) for an array."""
    column = record.get('column')
    if column:
        return column
    return 'array:%s:%s' % (record.get('key'), record.get('chain') or '')


def _chunks(items, size=_CHUNK):
    items = list(items)
    for i in range(0, len(items), size):
        yield items[i:i + size]


def remove_db_files(path):
    for suffix in ('', '-wal', '-shm'):
        try:
            os.unlink(path + suffix)
        except OSError:
            pass


# -- The active container -------------------------------------------------------------
#
# The store always has a database, so a run never needs a Save first. Without a document
# the working file is pid-scoped in TMPDIR (or RAYMOL_SETS_DIR), for the reason #399
# pid-scoped the panel channels: two RayMols must not share one, and a file left by a
# crash must be identifiable as stale by the next launch.

_ACTIVE = None
_WORKING_PREFIX = 'raymol_sets_'
_WORKING_SUFFIX = '.raymol'

#: A working file that held entries when its process let go of it is renamed to
#: `recovered_<stamp>_<pid>.raymol` and offered back on the next cold launch (#447).
#: OUT of the pid-scoped namespace on purpose: `working_path()` is pid-scoped and pids
#: are reused, so a file left under `raymol_sets_<pid>` would be adopted as its own by
#: the next process that happens to get that pid -- which is exactly what `active()`
#: refuses to let happen. The rename also makes "preserved" a fact about the NAME, so
#: a sweep never has to guess.
_RECOVERED_PREFIX = 'recovered_'

#: Retention for preserved containers, swept on the first open of a process. Kept
#: forever is a leak -- these are whole structure databases -- and dropped on the next
#: launch is the bug this file is fixing, so: the ten most recent survive, and anything
#: older than thirty days goes even if there are fewer than ten. Ten is more crashes
#: than a user will work through in a sitting, and thirty days is longer than anyone
#: leaves an unsaved campaign unclaimed.
RECOVERED_KEEP = 10
RECOVERED_MAX_AGE = 30 * 86400


def working_dir():
    return os.environ.get('RAYMOL_SETS_DIR') or tempfile.gettempdir()


def working_path():
    return os.path.join(working_dir(), '%s%d%s'
                        % (_WORKING_PREFIX, os.getpid(), _WORKING_SUFFIX))


def is_open():
    """True when a container is open, without opening one. For code paths that only
    want to LOOK (the .pse warning) and must not create a working file as a side effect."""
    return _ACTIVE is not None and not _ACTIVE.closed


#: Bumped every time the active container changes. A long-running writer (a batch
#: delivering results) captures it when it starts and compares before each write, so a
#: `load other.raymol` under its feet is a clean SetError rather than a write into the
#: wrong document or a raw sqlite ProgrammingError on a closed connection.
_GENERATION = 0
_SWEPT = False

#: Set the first time `active()` deals with a file already under our own pid. Its OWN
#: flag, not `_SWEPT`'s return value: the app asks `recoverable()` at launch, before
#: anything touches the store, so the sweep is already spent by the time `active()`
#: runs and the pid guard would never fire (#447 review). The two questions are
#: independent and now have independent one-shots.
_OWN_RETIRED = False

#: Paths this process has open, as realpaths, with a count (the same file may be
#: opened twice -- a test, a `save_into` to a path that is reopened). NOTHING may
#: unlink a file in here: `sweep_recovered` would otherwise delete a preserved
#: container out from under the connection that is writing to it, and the writes
#: would go to an unlinked inode with no error (#447 review).
_OPEN_PATHS = {}
_OPEN_PATHS_LOCK = threading.RLock()


def _register_open(path):
    key = os.path.realpath(path)
    with _OPEN_PATHS_LOCK:
        _OPEN_PATHS[key] = _OPEN_PATHS.get(key, 0) + 1


def _unregister_open(path):
    key = os.path.realpath(path)
    with _OPEN_PATHS_LOCK:
        count = _OPEN_PATHS.get(key, 0) - 1
        if count > 0:
            _OPEN_PATHS[key] = count
        else:
            _OPEN_PATHS.pop(key, None)


def is_container_open(path):
    """True when this process has `path` open as a Container."""
    with _OPEN_PATHS_LOCK:
        return os.path.realpath(os.fspath(path)) in _OPEN_PATHS


def _has_sidecar(path):
    """True when a `-wal` or `-shm` still sits beside `path`.

    The cross-process half of the same guard. SQLite removes both when the LAST
    connection closes, and `inspect_container` opens and closes the file just before
    this is asked -- so a sidecar that is still there means somebody else (another
    RayMol holding this container as its document) has it open right now. A registry
    cannot see that; the filesystem can.
    """
    return any(os.path.exists(path + extra) for extra in ('-wal', '-shm'))


def generation():
    return _GENERATION


def active():
    """The open container, opening the working file if there is none.

    The first open in a process sweeps working files of dead RayMols (spec §2.1) and
    treats a file already under THIS pid as one of them: a pid is reused after a wrap,
    and inheriting a dead session's sets is worse than starting empty. "Treats as
    stale" means `retire_working_file`, not delete: since #447 a container that holds
    entries is preserved for recovery instead of destroyed, here as everywhere.

    The pid guard is `retire_own_leftover`, with its own one-shot: it runs whether the
    sweep was spent by an earlier `recoverable()` (which is the app's actual launch
    order) or by this call, and never again -- the later opens are this process
    reopening the working file `replace()` left behind, which must come back with its
    sets.
    """
    global _ACTIVE, _GENERATION
    if _ACTIVE is None or _ACTIVE.closed:
        sweep_once()
        retire_own_leftover()
        _ACTIVE = Container(working_path())
        _GENERATION += 1
    return _ACTIVE


def retire_own_leftover():
    """Deal with a file already sitting under THIS process's working name, once.

    A pid is reused after a wrap, so a file under our own name at startup belongs to a
    RayMol that is gone: inheriting its sets -- a drawer full of sets whose staged
    objects are not in the scene, and a `set_delete` away from destroying them -- is
    worse than starting empty. It is retired, not deleted, so it comes back through
    the recovery alert instead.

    Called from `sweep_once` as well as `active`, because the app asks `recoverable()`
    at launch before anything opens a container (#447 review): doing it only in
    `active` left the leftover under its pid name, where `recoverable` cannot see it,
    so the user was not offered it until the launch after. Guarded by `is_container_open`
    so a mid-session `recoverable()` can never retire the live working file.
    """
    global _OWN_RETIRED
    if _OWN_RETIRED:
        return None
    path = working_path()
    if is_container_open(path):
        return None
    _OWN_RETIRED = True
    if not os.path.exists(path):
        return None
    return retire_working_file(path)


def sweep_once():
    """Run the launch-time sweeps, once per process: stale working files of dead
    RayMols, then the retention policy over what earlier sweeps (and quits) preserved.

    Separate from `active()` because `recoverable()` asks the same question at launch
    and must not have to open a container -- and must not report a stale working file
    under its old name, since the answer it gives is the one the user is offered.
    True when this call is the one that swept; nothing may make a DECISION out of
    that answer (see `active`), it is for tests and callers that want to know.
    """
    global _SWEPT
    if _SWEPT:
        return False
    _SWEPT = True
    sweep_stale_working_files()
    retire_own_leftover()
    sweep_recovered()
    return True


def replace(container):
    """Install `container` as the active one, closing the previous. The previous FILE
    is left alone: whether it goes is binding's call, which knows if it was a document."""
    global _ACTIVE, _GENERATION
    previous = _ACTIVE
    _ACTIVE = container
    _GENERATION += 1
    if previous is not None and previous is not container:
        previous.close()
    return container


def reset():
    """Close the active container; retire it only if it is the pid-scoped working file.

    `load x.pse`, `reinitialize`, the tests and (through atexit) every quit call this so
    a session that never had sets does not inherit the previous document's. A user's
    document is closed, never touched. The working file is closed and then either
    deleted (it holds nothing) or preserved for recovery (it holds entries, #447): ⌘Q
    used to delete it either way, which is how an untitled session's six-hour batch
    disappeared without a word.

    "Holds entries" is asked of the LIVE container, before the close, because that is
    the one moment when the answer is free; see `Container.holds_entries`.
    """
    global _ACTIVE, _GENERATION
    previous = _ACTIVE
    _ACTIVE = None
    _GENERATION += 1
    if previous is None:
        return
    held = previous.holds_entries()
    previous.close()
    if os.path.abspath(previous.path) == os.path.abspath(working_path()):
        retire_working_file(previous.path, held=held)


def retire_working_file(path, held=None, force=False):
    """Finish with the working file at `path`: delete it, or preserve it for recovery.

    The one place the "never destroy a non-empty container" rule of #447 is written
    down, so every caller that used to `remove_db_files` a working file obeys it by
    construction. Returns the preserved path, or None when the file was removed.

    `held` is the answer a caller already has from the live container (the cheap way),
    and None means it could not answer -- a closed connection, an IO error -- in which
    case the file is inspected on disk instead. `force` deletes regardless, and is for
    the callers that know the data is already somewhere better: `save x.raymol` has
    just copied this container into the user's document, and offering the copy back on
    next launch would ask them to recover work they explicitly saved.
    """
    if not force:
        if held is None:
            held = _file_holds_entries(path)
        if held:
            return preserve_working_file(path)
    remove_db_files(path)
    return None


def _file_holds_entries(path):
    """Does the closed container at `path` hold entries -- and, when that cannot be
    answered, does it look like a database at all?

    Only a clean `entries = 0` answers False, because False is the branch that
    DELETES. A file we could not read today (locked, out of file descriptors, a format
    version from a future build) is not an empty one, and six hours of results must
    not turn on a transient sqlite error (#447 review).
    """
    info = inspect_container(path)
    if info is not None:
        return info['entries'] > 0
    return looks_like_container(path)


def looks_like_container(path):
    """True when `path` starts with SQLite's 16-byte magic.

    The cheap half of "is this ours": it needs no connection and cannot fail for a
    reason other than the file itself, which is exactly what tells a junk file apart
    from a database we merely could not open just now.
    """
    try:
        with open(path, 'rb') as fh:
            return fh.read(16) == b'SQLite format 3\x00'
    except OSError:
        return False


def preserve_working_file(path):
    """Rename a working file out of the pid-scoped namespace so it survives, and so no
    later process can mistake it for its own.

    Returns WHERE THE CONTAINER ENDED UP: the new name, or `path` itself when the
    rename failed and the file was left exactly where it was. Never None, so a caller
    cannot read "kept under its old name" as "removed" -- `sweep_stale_working_files`
    would have reported it swept and `load x.raymol` would have printed no line at all
    (#447 review). Losing the name is survivable; losing the file is the bug, and a
    file still under `raymol_sets_<pid>` is retired again on the next launch.
    """
    name = os.path.basename(path)
    pid = os.getpid()
    if name.startswith(_WORKING_PREFIX) and name.endswith(_WORKING_SUFFIX):
        digits = name[len(_WORKING_PREFIX):-len(_WORKING_SUFFIX)]
        if digits.isdigit():
            pid = int(digits)
    stamp = time.strftime('%Y%m%d-%H%M%S', time.localtime(_mtime(path) or _now()))
    folder = os.path.dirname(path) or working_dir()
    for n in range(0, 100):
        suffix = '' if n == 0 else '-%d' % n
        target = os.path.join(folder, '%s%s_%d%s%s'
                              % (_RECOVERED_PREFIX, stamp, pid, suffix, _WORKING_SUFFIX))
        if not os.path.exists(target):
            break
    else:
        return path
    try:
        os.rename(path, target)
    except OSError:
        return path
    # A crash leaves -wal/-shm beside the file; they carry committed transactions that
    # are not in the main database yet, so they move WITH it or the entries they hold
    # are lost. (`inspect_container` will have checkpointed them away in the usual
    # case; this is the path where it never ran.)
    for extra in ('-wal', '-shm'):
        try:
            os.rename(path + extra, target + extra)
        except OSError:
            pass
    return target


def inspect_container(path):
    """What is in the closed .raymol file at `path`, or None if it is not ours.

    `{'path', 'sets', 'entries', 'session', 'modified'}`. Opened read-WRITE on purpose,
    unlike Swift's reader: the files this is asked about are leftovers of processes
    that are gone, and a read-only connection cannot replay the -wal a crash left
    behind -- so the entries the user is about to be offered would be invisible, and
    the file would look empty and be deleted. Opening normally recovers the WAL and
    closing checkpoints it away. No schema migration is run: this is a look, not an
    open, and a file from a future format version must still be countable.
    """
    try:
        if not os.path.isfile(path) or os.path.getsize(path) == 0:
            return None
        modified = os.path.getmtime(path)
    except OSError:
        return None
    try:
        conn = sqlite3.connect(path)
    except sqlite3.Error:
        return None
    try:
        sets = conn.execute('SELECT COUNT(*) FROM sets').fetchone()[0]
        entries = conn.execute('SELECT COUNT(*) FROM entries').fetchone()[0]
        session = conn.execute('SELECT EXISTS(SELECT 1 FROM session)').fetchone()[0]
    except sqlite3.Error:
        return None
    finally:
        try:
            conn.close()
        except sqlite3.Error:
            pass
    return {'path': path, 'sets': int(sets), 'entries': int(entries),
            'session': bool(session), 'modified': modified}


def is_preserved(path):
    """True when `path` names a preserved container of ours: the `recovered_` name,
    in the working directory. One place, because three callers ask -- the retention
    sweep, `discard_recoverable`'s refusal, and `save x.raymol` deciding whether the
    file it just copied was a recovery (#447 review)."""
    path = os.path.abspath(os.fspath(path))
    name = os.path.basename(path)
    if not (name.startswith(_RECOVERED_PREFIX) and name.endswith(_WORKING_SUFFIX)):
        return False
    # realpath on both sides: on macOS $TMPDIR is /var/folders/... which is a symlink
    # to /private/var/..., and a mismatch there would be a Discard button that
    # silently does nothing.
    return os.path.realpath(os.path.dirname(path)) == os.path.realpath(working_dir())


def recovered_files():
    """Every preserved container in the working directory, newest first.

    Files this process has OPEN are left out: one of them is the document the user
    opened from the recovery alert, and it is neither something to offer back again
    nor something a retention sweep may unlink -- the writes would go to an unlinked
    inode, silently, which is the failure this whole ticket exists to prevent (#447
    review). Paths only; the file may be empty or unreadable, which is
    `recoverable`'s and `sweep_recovered`'s problem.
    """
    folder = working_dir()
    try:
        names = os.listdir(folder)
    except OSError:
        return []
    paths = [os.path.join(folder, name) for name in names
             if name.startswith(_RECOVERED_PREFIX) and name.endswith(_WORKING_SUFFIX)
             and not is_container_open(os.path.join(folder, name))]
    paths.sort(key=lambda p: (_mtime(p) or 0.0, p), reverse=True)
    return paths


def recoverable():
    """The containers a previous RayMol left behind that still hold entries, newest
    first, as `{'path', 'sets', 'entries', 'session', 'modified'}` dicts (#447).

    This is a LAUNCH-TIME question, asked once by the app so it can offer the work
    back, and deliberately not in the 500 ms poll: it opens every preserved container
    read-write, which replays and checkpoints a crashed session's WAL, on whichever
    thread asks. Cheap in the sense that matters -- it counts rows rather than reading
    them, so a ten-thousand-entry container costs what an empty one does, and it never
    opens or CREATES the working container, so a session with no sets pays one
    `listdir` -- but not free, and not something to put on a timer.
    """
    sweep_once()
    out = []
    for path in recovered_files():
        info = inspect_container(path)
        if info and info['entries']:
            out.append(info)
    return out


def discard_recoverable(path):
    """Delete a preserved container the user said they do not want. Refuses anything
    that is not one of ours -- this is reached from a UI button with a path that came
    back out of `recoverable()`, and "delete the file named in this string" is not a
    verb this module should offer anyone."""
    path = os.path.abspath(os.fspath(path))
    if not is_preserved(path):
        raise SetInputError('%s is not a recoverable container' % path)
    remove_db_files(path)
    return path


def sweep_recovered(keep=RECOVERED_KEEP, max_age=RECOVERED_MAX_AGE):
    """Apply the retention policy to preserved containers. Returns the paths removed.

    Age before count, so "older than thirty days" is not saved by being one of the ten
    newest, and an empty container goes whatever its age -- it can never be offered.

    Three things are never unlinked, and each is a way this sweep could have destroyed
    a live document (#447 review):

    * a file this process has open (`recovered_files` has already dropped those);
    * a file another process has open, which is what a `-wal`/`-shm` still sitting
      beside it means once `inspect_container` has opened and closed it;
    * a file we could not READ. "I got a sqlite error" is not "it is empty". Only a
      file that is not a database at all -- no SQLite header -- is junk, and junk is
      the one unreadable thing that is safe to drop.

    A file kept for any of those reasons still counts towards `keep`, so the directory
    stays bounded even when something in it is unreadable every time we look.
    """
    removed = []
    now = _now()
    kept = 0
    for path in recovered_files():
        if not looks_like_container(path):
            remove_db_files(path)
            removed.append(path)
            continue
        mtime = _mtime(path)
        info = inspect_container(path)
        if info is None or is_container_open(path) or _has_sidecar(path):
            kept += 1
            continue
        stale = (max_age and mtime is not None and (now - mtime) > max_age)
        if stale or not info['entries']:
            remove_db_files(path)
            removed.append(path)
            continue
        kept += 1
        if keep and kept > keep:
            remove_db_files(path)
            removed.append(path)
    return removed


def sweep_stale_working_files():
    """Retire working files left by RayMols that are no longer running.

    Returns the paths REMOVED; one that held entries is preserved instead (#447) and
    is not in the list -- `recoverable()` is where those surface. A pid that cannot be
    signalled is dead; one that refuses the signal is alive and belongs to someone else.
    """
    removed = []
    try:
        names = os.listdir(working_dir())
    except OSError:
        return removed
    for name in names:
        if not (name.startswith(_WORKING_PREFIX) and name.endswith(_WORKING_SUFFIX)):
            continue
        pid_text = name[len(_WORKING_PREFIX):-len(_WORKING_SUFFIX)]
        if not pid_text.isdigit() or int(pid_text) == os.getpid():
            continue
        if _alive(int(pid_text)):
            continue
        path = os.path.join(working_dir(), name)
        if retire_working_file(path) is None:
            removed.append(path)
    return removed


def _mtime(path):
    try:
        return os.path.getmtime(path)
    except OSError:
        return None


def _alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return True
    return True


def _at_exit():
    """Clean exit retires the pid-scoped working file: deleted when it holds nothing,
    kept for recovery when it holds entries (#447). A document is only closed."""
    try:
        reset()
    except Exception:
        pass


atexit.register(_at_exit)
