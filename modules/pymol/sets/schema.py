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
import json
import re
import sqlite3
import time

from .errors import SetFormatError, SetInputError

#: Bumped only for a change an older reader cannot absorb. A file newer than this
#: refuses to open, naming the build that wrote it; an older file is migrated forward
#: inside one transaction. There is no downgrade path.
FORMAT_VERSION = 2

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
    'pinned', 'entry_id', 'rowid', 'design_chains',
))

SET_KINDS = ('structures', 'sequences', 'mixed')
ARRAY_ENCODINGS = ('f32', 'u8q')
BLOB_KINDS = ('cif', 'f32', 'u8q', 'thumb')

#: Format version 1 from the spec (§2.2), plus `entries.design_chains` (version 2,
#: #545). Order matters for the foreign keys.
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
  design_chains TEXT NOT NULL DEFAULT '[]',
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

def _json_or(text, default):
    try:
        value = json.loads(text) if isinstance(text, str) else default
    except ValueError:
        return default
    return value if isinstance(value, type(default)) else default


def resolve_design_chains(chain_ids, explicit=None, metric=None, run_inputs=None,
                          parent_chains=()):
    """Which of an entry's chains were DESIGNED, as a sorted list (#545).

    The first source that names a chain the entry actually has wins, in this order:
    what the caller said (`explicit`), the entry's own `design_chain` metric (every
    generator records it, `generators/metrics.py`), its run's `inputs['design_chain']`
    (what `DesignSpec.design_chain` asked for), and then its parents' design chains --
    so a refold or a redesign of a design keeps pointing at the binder. `[]` when none
    applies: an entry with no designed chain is shown and staged whole, as before.

    One function for delivery and for the v1 -> v2 backfill, so a migrated file and a
    fresh one say the same thing about the same entry.
    """
    have = {str(c) for c in chain_ids or ()}

    def pick(value):
        if value is None or value == '':
            return []
        if isinstance(value, (list, tuple, set)):
            names = [str(v) for v in value if v not in (None, '')]
        else:
            names = [c.strip() for c in str(value).split(',') if c.strip()]
        return sorted({c for c in names if c in have})

    for candidate in (explicit, metric, (run_inputs or {}).get('design_chain'),
                      list(parent_chains or ())):
        chosen = pick(candidate)
        if chosen:
            return chosen
    return []


def _migrate_1_to_2(conn):
    """v1 -> v2: `entries.design_chains`, backfilled from what the file already knows
    (#545) -- each entry's `design_chain` metric column where its set has one, else
    its run's inputs, else its parents'. Oldest entries first, so a parent in another
    set is resolved before the child that inherits from it."""
    have_column = any(r[1] == 'design_chains'
                      for r in conn.execute('PRAGMA table_info(entries)'))
    if not have_column:
        # Idempotent, so a file a test walked forward from an older hook still opens.
        conn.execute("ALTER TABLE entries ADD COLUMN design_chains TEXT NOT NULL"
                     " DEFAULT '[]'")
    runs = {rid: _json_or(inputs, {})
            for rid, inputs in conn.execute('SELECT id, inputs FROM runs')}
    metric = {}
    for (set_id,) in conn.execute('SELECT id FROM sets').fetchall():
        table = metrics_table(set_id)
        try:
            cols = [r[1] for r in conn.execute('PRAGMA table_info(%s)' % quote(table))]
        except sqlite3.Error:
            continue
        if 'design_chain' in cols:
            for eid, value in conn.execute(
                    'SELECT entry_id, "design_chain" FROM %s' % quote(table)):
                if value not in (None, ''):
                    metric[eid] = value
    chains = {}
    for eid, chain in conn.execute('SELECT entry_id, chain FROM chains'):
        chains.setdefault(eid, set()).add(chain)
    done = {}
    rows = conn.execute('SELECT id, run_id, sequences, parents FROM entries'
                        ' ORDER BY created, ord').fetchall()
    for eid, run_id, sequences, parents in rows:
        have = set(chains.get(eid, ())) | set(_json_or(sequences, {}))
        inherited = []
        for parent in _json_or(parents, []):
            inherited.extend(done.get(parent, ()))
        picked = resolve_design_chains(have, metric=metric.get(eid),
                                       run_inputs=runs.get(run_id),
                                       parent_chains=inherited)
        done[eid] = picked
        if picked:
            conn.execute('UPDATE entries SET design_chains = ? WHERE id = ?',
                         (json.dumps(picked), eid))


#: from_version -> callable(conn) that brings the file to from_version + 1.
#: `open_or_migrate` walks it inside one transaction.
MIGRATIONS = {1: _migrate_1_to_2}


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
