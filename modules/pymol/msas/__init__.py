"""Multiple-sequence alignments as named, session-stored objects.

    msa.py     the cmd.* surface (load_msa, msa_list, ...)
    store.py   the named store, and the .pse round trip
    parse.py   a3m / aligned-FASTA reading -- validation and summary only
    errors.py  the exception taxonomy

Nothing here folds anything. An alignment is loaded once and reused: across
predictors, across targets, and across sessions. What consumes it lives in
pymol.predictors (#297), and what generates it lives in msas/colabfold.py (#298).
"""
