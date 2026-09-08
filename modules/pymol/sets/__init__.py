"""Records of a design or prediction campaign, kept apart from the scene (#415, #421).

    errors.py     the exception taxonomy
    schema.py     DDL, format version, migrations, the metric key -> SQL type mapping
    store.py      the Container: one open .raymol database and everything in it
    blobs.py      encode/decode for chain CIFs and metric arrays; hashing; chain splitting
    filter.py     the filter-expression grammar, parsed to parameterised SQL
    binding.py    everything that has to ASK THE SESSION: stage, unstage, peek, capture
    document.py   import from folders / files / FASTA and export to folder / CSV / FASTA

An ENTRY is data: sequences, a structure kept as blobs, metrics, provenance. An OBJECT is
a scene actor. The two meet only in `binding.py`, when an entry is staged or peeked, and
only `binding.py` imports `cmd`. `store.py`, `blobs.py`, `filter.py` and `document.py`
never touch a session, which is what lets them be tested without one and read from Swift
later.

Spec: docs/superpowers/specs/2026-09-07-sets-store-and-raymol-container-design.md
"""
