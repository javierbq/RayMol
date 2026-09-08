"""Import from and export to the file system, without a session (#415).

Everything here is a pure function of a Container and paths. Reading a structure file
into an entry needs a session (the peek object is what parses it), so that half lives in
`binding.capture_file`; this module decides WHICH files a folder import means, reads and
writes the tabular sidecars, and writes sequences and CIFs back out.

Export is lossless for what the table holds: `entries.csv` carries every scalar column,
the flags and the tags, and the CIFs are the chain blobs concatenated per entry. A folder
written here re-imports to a set with equal scalars (sets_document.py pins that), so
"export, hand to a colleague, re-import" is a round trip and not a copy that drifts.
"""
import csv
import json
import os

from .errors import SetInputError

#: Extensions a folder import takes as structures, lowercase, in the order a stem with
#: more than one of them is preferred (a folder with both `x.cif` and `x.pdb` yields one
#: entry from the CIF).
STRUCTURE_EXTS = ('.cif', '.mmcif', '.pdb', '.ent', '.pdb.gz', '.cif.gz')
SEQUENCE_EXTS = ('.fasta', '.fa', '.faa', '.a3m')

#: The sidecar an export writes and an import reads back. `score.sc` and friends are #420.
SIDECAR = 'entries.csv'

#: Columns the CSV always carries first, before the metric columns. `name` is the join
#: key back to the structure file; `structure` is the file's basename or '' for a
#: sequence entry; `sequences` is the JSON the entries table holds.
FIXED_COLUMNS = ('name', 'structure', 'sequences', 'starred', 'rejected', 'tags', 'note',
                 'parents')


def stem(path):
    """The entry name a file yields: the basename with every structure/sequence
    extension stripped, so `d_0417.pdb.gz` and `d_0417.cif` both mean `d_0417`."""
    base = os.path.basename(path)
    low = base.lower()
    for ext in sorted(STRUCTURE_EXTS + SEQUENCE_EXTS, key=len, reverse=True):
        if low.endswith(ext):
            return base[:len(base) - len(ext)]
    return os.path.splitext(base)[0]


def scan_folder(folder):
    """The structure files a folder import means, one per stem, sorted by name.

    Returns (files, sidecar) where `files` is a list of absolute paths and `sidecar` is
    the path of `entries.csv` if present, else None. Non-recursive on purpose: a design
    run's output folder is flat, and a recursive walk over a project tree would pull in
    inputs and references alongside the designs.
    """
    if not os.path.isdir(folder):
        raise SetInputError('%r is not a folder' % folder)
    by_stem = {}
    for name in sorted(os.listdir(folder)):
        low = name.lower()
        for rank, ext in enumerate(STRUCTURE_EXTS):
            if low.endswith(ext):
                key = stem(name)
                prev = by_stem.get(key)
                if prev is None or rank < prev[0]:
                    by_stem[key] = (rank, os.path.join(folder, name))
                break
    files = [path for _rank, path in sorted(by_stem.values(), key=lambda t: t[1])]
    sidecar = os.path.join(folder, SIDECAR)
    return files, (sidecar if os.path.isfile(sidecar) else None)


def read_sidecar(path):
    """{name: {column: raw string}} from an `entries.csv`, or raise SetInputError."""
    out = {}
    with open(path, newline='') as handle:
        reader = csv.DictReader(handle)
        if not reader.fieldnames or 'name' not in reader.fieldnames:
            raise SetInputError('%s has no "name" column' % path)
        for row in reader:
            name = (row.get('name') or '').strip()
            if not name:
                continue
            out[name] = row
    return out


def read_fasta(path):
    """[(name, sequence)] from a FASTA/a3m; lowercase (a3m insertions) and gaps dropped.

    The header up to the first whitespace is the name. Duplicate names get `_2`, `_3`
    so nothing is silently overwritten -- the same rule `binding` applies to objects.
    """
    records = []
    seen = {}
    name, parts = None, []

    def flush():
        if name is None:
            return
        seq = ''.join(parts)
        seq = ''.join(c for c in seq if c.isupper() and c != '-')
        base = name
        n = seen.get(base, 0) + 1
        seen[base] = n
        records.append((base if n == 1 else '%s_%d' % (base, n), seq))

    with open(path) as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            if line.startswith('>'):
                flush()
                name = line[1:].split()[0] if line[1:].split() else 'seq'
                parts = []
            else:
                parts.append(line)
    flush()
    if not records:
        raise SetInputError('%s holds no sequences' % path)
    return records


def coerce_sidecar_value(dtype, raw):
    """A CSV cell as the column's dtype; '' is absent (None), never zero."""
    if raw is None or raw == '':
        return None
    try:
        if dtype == 'float':
            return float(raw)
        if dtype == 'int':
            return int(float(raw))
        if dtype == 'bool':
            return raw.strip().lower() in ('1', 'true', 'yes')
    except ValueError:
        raise SetInputError('%r is not a %s' % (raw, dtype))
    return str(raw)


def sidecar_columns(rows, known):
    """Metric columns a sidecar carries that the set does not yet declare.

    Returns [(column, dtype)] with dtype guessed from the values: every non-empty cell
    parses as float -> 'float'; everything is 0/1/true/false -> 'bool'; else 'str'. A
    column already in `known` is skipped. The fixed columns are never metrics.
    """
    if not rows:
        return []
    names = [c for c in next(iter(rows.values())).keys()
             if c and c not in FIXED_COLUMNS and c not in known]
    out = []
    for col in names:
        values = [r.get(col, '') for r in rows.values() if (r.get(col) or '') != '']
        if not values:
            out.append((col, 'float'))
            continue
        lowered = {v.strip().lower() for v in values}
        if lowered <= {'0', '1', 'true', 'false'}:
            out.append((col, 'bool'))
            continue
        try:
            for v in values:
                float(v)
            out.append((col, 'float'))
        except ValueError:
            out.append((col, 'str'))
    return out


# -- Export ---------------------------------------------------------------------


def _fmt(value):
    if value is None:
        return ''
    if isinstance(value, float):
        return repr(value)
    return str(value)


def _json_field(value, default):
    """An entry's `sequences`/`parents` as JSON text. `Container.entries` hands them
    back parsed, a raw row hands them back as text; both are accepted."""
    if value is None or value == '':
        return default
    if isinstance(value, str):
        return value
    return json.dumps(value, sort_keys=True)


def _sequences(entry):
    raw = entry.get('sequences')
    if isinstance(raw, dict):
        return raw
    try:
        return json.loads(raw or '{}')
    except ValueError:
        return {}


def write_csv(container, set_id, entries, path):
    """`entries.csv` for the given entry dicts (as `Container.entries` returns them)."""
    columns = [c['column'] for c in container.columns(set_id) if c.get('column')]
    with open(path, 'w', newline='') as handle:
        writer = csv.writer(handle)
        writer.writerow(list(FIXED_COLUMNS) + columns)
        for e in entries:
            has_structure = bool(e.get('n_chains'))
            scalars = e.get('scalars') or {}
            writer.writerow([
                e['name'],
                (e['name'] + '.cif') if has_structure else '',
                _json_field(e.get('sequences'), '{}'),
                int(e.get('starred') or 0), int(e.get('rejected') or 0),
                e.get('tags') or '', e.get('note') or '', _json_field(e.get('parents'), '[]'),
            ] + [_fmt(scalars.get(c)) for c in columns])
    return path


def write_fasta(container, entries, path):
    """One record per polymer chain: `>name/chain` then the sequence."""
    n = 0
    with open(path, 'w') as handle:
        for e in entries:
            for chain, seq in _sequences(e).items():
                if not seq:
                    continue
                handle.write('>%s/%s\n' % (e['name'], chain))
                for i in range(0, len(seq), 80):
                    handle.write(seq[i:i + 80] + '\n')
                n += 1
    if n == 0:
        raise SetInputError('no sequences to write')
    return path


def write_folder(container, set_id, entries, folder):
    """A folder with one CIF per structure entry and the sidecar CSV.

    The CIF is the entry's chain blobs concatenated, each already a complete mmCIF
    document from `get_cifstr`. PyMOL reads multi-block CIF text into one object, which
    is what `binding.capture_file` will do on re-import.
    """
    os.makedirs(folder, exist_ok=True)
    for e in entries:
        chains = container.chain_cifs(e['id'])
        if not chains:
            continue
        with open(os.path.join(folder, e['name'] + '.cif'), 'w') as handle:
            for _chain, text in chains:
                handle.write(text)
                if not text.endswith('\n'):
                    handle.write('\n')
    write_csv(container, set_id, entries, os.path.join(folder, SIDECAR))
    return folder
