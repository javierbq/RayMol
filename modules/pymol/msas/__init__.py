"""Multiple-sequence alignments as named, session-stored objects.

    msa.py        the cmd.* surface (load_msa, msa_search, msa_list, ...)
    store.py      the named store, and the .pse round trip
    parse.py      a3m / aligned-FASTA reading -- validation and summary only
    colabfold.py  the ColabFold MSA-server protocol -- tickets and the tarball
    searching.py  the background half of a search, and its on-disk cache
    errors.py     the exception taxonomy

Nothing here folds anything. An alignment is loaded once and reused: across
predictors, across targets, and across sessions. What consumes it lives in
pymol.predictors (#297); what generates it is colabfold.py + searching.py (#298),
driven from pymol.msa, which owns everything that touches the session.
"""
