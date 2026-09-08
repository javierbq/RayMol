"""The .raymol container's DDL, its format version, and the metric key -> SQL mapping.

Everything that decides what a file LOOKS LIKE lives here and nowhere else, because
three readers have to agree on it: this store, the filter compiler that writes SQL
against aliases `e` (entries) and `m` (the per-set metrics table), and a Swift
connection later (#417) that opens the same file read-only. A column renamed in one
place and not the others is a bug that surfaces as an empty table, so the names are
declared once.

Why a wide table per set rather than entry-attribute-value: the drawer and `set_filter`
only ever look at one set, and `plddt > 80 and rmsd < 1.5 ORDER BY plddt DESC` over a
wide table is one indexed scan where over EAV it is a self-join per predicate. Columns
differ by tool, so the table is created with the set and grown with ALTER TABLE as keys
appear. A key is restricted to ^[a-z][a-z0-9_]*$ so that quoting it into DDL is safe by
construction; a value is never interpolated anywhere in this package.
"""
import re
import sqlite3
import time

from .errors import SetFormatError, SetInputError

#: Bumped only for a change an older reader cannot absorb. A file newer than this
#: refuses to open, naming the build that wrote it; an older file is migrated forward
#: inside one transaction. There is no downgrade path.
FORMAT_VERSION = 1

#: A metric key. Lower-case, starts with a letter, no separators but '_': the same
#: alphabet MetricSpec keys already use, tightened to exclude a leading digit so the
#: filter grammar can tell a column from a number without quoting.
KEY_RE = re.compile(r'^[a-z][a-z0-9_]*$')

_CHAIN_UNSAFE = re.compile(r'[^A-Za-z0-9_]')

#: Names a metric column may NOT take, because `SELECT e.*, m.*` would put two columns
#: of the same name in one row and the filter compiler could no longer tell `e.name`
#: from a metric. Reserved rather than prefixed: a prefix on every metric column would
#: leak into the JSON, the CSV export and the Swift reader for the sake of one clash.
RESERVED_COLUMNS = frozenset((
    'id', 'set_id', 'ord', 'name', 'run_id', 'created', 'sequences', 'n_chains',
    'n_residues', 'parents', 'starred', 'rejected', 'tags', 'note', 'staged_object',
    'pinned', 'entry_id', 'rowid',
))

SET_KINDS = ('structures', 'sequences', 'mixed')
ARRAY_ENCODINGS = ('f32', 'u8q')
BLOB_KINDS = ('cif', 'f32', 'u8q', 'thumb')

#: Format version 1, verbatim from the spec (§2.2). Order matters for the foreign keys.
DDL = (
    """CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)""",
    """CREATE TABLE session (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  pse BLOB NOT NULL, saved REAL NOT NULL, pse_version REAL, app_version TEXT)""",
    """CREATE TABLE sets (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  kind TEXT NOT NULL,
  created REAL NOT NULL, tool TEXT NOT NULL DEFAULT '', note TEXT NOT NULL DEFAULT '',
  group_name TEXT NOT NULL,
  budget INTEGER,
  ranking_key TEXT NOT NULL DEFAULT '',
  sort_key TEXT NOT NULL DEFAULT '', sort_desc INTEGER NOT NULL DEFAULT 1,
  filter TEXT NOT NULL DEFAULT '',
  columns TEXT NOT NULL DEFAULT '[]',
  reference TEXT NOT NULL DEFAULT '')""",
    """CREATE TABLE runs (
  id TEXT PRIMARY KEY, set_id TEXT NOT NULL REFERENCES sets(id) ON DELETE CASCADE,
  tool TEXT NOT NULL, tool_version TEXT NOT NULL DEFAULT '', created REAL NOT NULL,
  inputs TEXT NOT NULL DEFAULT '{}',
  parent_set_id TEXT, note TEXT NOT NULL DEFAULT '')""",
    """CREATE TABLE entries (
  id TEXT PRIMARY KEY, set_id TEXT NOT NULL REFERENCES sets(id) ON DELETE CASCADE,
  ord INTEGER NOT NULL,
  name TEXT NOT NULL,
  run_id TEXT REFERENCES runs(id), created REAL NOT NULL,
  sequences TEXT NOT NULL DEFAULT '{}',
  n_chains INTEGER NOT NULL DEFAULT 0, n_residues INTEGER NOT NULL DEFAULT 0,
  parents TEXT NOT NULL DEFAULT '[]',
  starred INTEGER NOT NULL DEFAULT 0, rejected INTEGER NOT NULL DEFAULT 0,
  tags TEXT NOT NULL DEFAULT '',
  note TEXT NOT NULL DEFAULT '',
  staged_object TEXT, pinned INTEGER NOT NULL DEFAULT 0,
  UNIQUE (set_id, name))""",
    """CREATE INDEX entries_set_ord ON entries(set_id, ord)""",
    """CREATE INDEX entries_staged ON entries(staged_object)
  WHERE staged_object IS NOT NULL""",
    """CREATE TABLE blobs (
  hash TEXT PRIMARY KEY,
  kind TEXT NOT NULL,
  bytes BLOB NOT NULL,
  size INTEGER NOT NULL,
  refs INTEGER NOT NULL DEFAULT 0)""",
    """CREATE TABLE chains (
  entry_id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
  chain TEXT NOT NULL, ord INTEGER NOT NULL,
  blob TEXT NOT NULL REFERENCES blobs(hash),
  PRIMARY KEY (entry_id, chain))""",
    """CREATE TABLE arrays (
  entry_id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
  key TEXT NOT NULL, scope TEXT NOT NULL,
  chain TEXT,
  blob TEXT NOT NULL REFERENCES blobs(hash),
  encoding TEXT NOT NULL,
  scale REAL, offset REAL,
  index_json TEXT NOT NULL,
  PRIMARY KEY (entry_id, key, chain))""",
    """CREATE TABLE views (
  id TEXT PRIMARY KEY, set_id TEXT NOT NULL REFERENCES sets(id) ON DELETE CASCADE,
  name TEXT NOT NULL, filter TEXT NOT NULL DEFAULT '',
  sort_key TEXT NOT NULL DEFAULT '', sort_desc INTEGER NOT NULL DEFAULT 1,
  columns TEXT NOT NULL DEFAULT '[]', created REAL NOT NULL,
  UNIQUE (set_id, name))""",
)

#: The tables `create` makes, for the open-time sanity check and for tests.
TABLES = ('meta', 'session', 'sets', 'runs', 'entries', 'blobs', 'chains', 'arrays',
          'views')

#: from_version -> callable(conn) that brings the file to from_version + 1. Empty at
#: v1; `open_or_migrate` walks it so that the first real migration is one entry here
#: and no change to the open path.
MIGRATIONS = {}


def check_key(key):
    """`key` if it can be quoted into SQL as an identifier, else raise."""
    if not isinstance(key, str) or not KEY_RE.match(key):
        raise SetInputError(
            'invalid metric key %r: a key is lower-case letters, digits and _,'
            ' starting with a letter' % (key,))
    return key


def sql_type(dtype):
    """The SQLite column type for a MetricSpec dtype."""
    if dtype == 'float':
        return 'REAL'
    if dtype in ('int', 'bool'):
        return 'INTEGER'
    if dtype == 'str':
        return 'TEXT'
    raise SetInputError('unknown dtype %r; expected float, int, bool or str' % (dtype,))


def metrics_table(set_id):
    """The wide table that holds `set_id`'s scalars."""
    return 'm_%s' % set_id


def column_name(key, chain=None):
    """The wide-table column for a scalar: `key`, or `key__chain` for a chain scalar.

    `__` because `/` -- the separator MetricRun.scalars uses -- is not a legal
    identifier character. The chain is reduced to [a-z0-9_] for the same reason, and
    LOWERCASED so the filter grammar (whose identifiers are lowercase) can name the
    column: `plddt__b > 80`. SQLite identifiers are case-insensitive anyway, so two
    chains differing only by case were never going to be two columns.
    """
    key = check_key(key)
    if chain is None or chain == '':
        return key
    return '%s__%s' % (key, _CHAIN_UNSAFE.sub('_', str(chain)).lower())


def quote(identifier):
    """Double-quote an identifier that has ALREADY been validated. Never a value."""
    return '"%s"' % identifier.replace('"', '""')


def create(conn):
    """Lay down format version 1 in an empty database. One transaction."""
    try:
        conn.execute('BEGIN IMMEDIATE')
        for statement in DDL:
            conn.execute(statement)
        conn.executemany(
            'INSERT INTO meta (key, value) VALUES (?, ?)',
            [('format_version', str(FORMAT_VERSION)),
             ('created', repr(time.time())),
             ('app_version', ''),
             ('version', '0')])
        conn.execute('COMMIT')
    except sqlite3.Error as exc:
        conn.execute('ROLLBACK')
        raise SetFormatError('could not initialise the container: %s' % exc)


def open_or_migrate(conn):
    """Check `meta.format_version` and bring an older file forward.

    Raises SetFormatError when the file is not SQLite, is SQLite but not a .raymol
    container, or was written by a newer build than this one -- naming that build,
    because "cannot open" with no reason sends the user to the wrong place.
    """
    try:
        row = conn.execute(
            "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='meta'"
        ).fetchone()
    except sqlite3.DatabaseError as exc:
        raise SetFormatError('not a .raymol file: %s' % exc)
    if not row or row[0] != 1:
        raise SetFormatError('not a .raymol file: it has no meta table')

    meta = dict(conn.execute('SELECT key, value FROM meta').fetchall())
    try:
        found = int(meta.get('format_version', ''))
    except ValueError:
        raise SetFormatError('not a .raymol file: meta.format_version is %r'
                             % meta.get('format_version'))
    if found > FORMAT_VERSION:
        raise SetFormatError(
            'this file is format version %d, written by RayMol %s; this build reads'
            ' up to version %d. Open it with the newer RayMol.'
            % (found, meta.get('app_version') or '(unknown)', FORMAT_VERSION))
    if found == FORMAT_VERSION:
        return found

    try:
        conn.execute('BEGIN IMMEDIATE')
        while found < FORMAT_VERSION:
            step = MIGRATIONS.get(found)
            if step is None:
                raise SetFormatError(
                    'no migration from format version %d to %d' % (found, found + 1))
            step(conn)
            found += 1
            conn.execute("UPDATE meta SET value = ? WHERE key = 'format_version'",
                         (str(found),))
        conn.execute('COMMIT')
    except (sqlite3.Error, SetFormatError):
        conn.execute('ROLLBACK')
        raise
    return found
