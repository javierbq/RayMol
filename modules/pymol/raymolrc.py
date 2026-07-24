# raymolrc.py
#
# RayMol's native macOS/iOS embeddings (SwiftUI/Metal and the legacy AppKit
# app) boot Python directly and never go through pymol.invocation.parse_args,
# so a user's ~/.pymolrc is silently ignored there (see RayMol#225). This
# module gives the native apps an equivalent startup script, ~/.raymolrc(.py).
#
# Migrating an existing ~/.pymolrc(.py) is user-confirmed, not automatic: the
# app checks migration_candidate() and, the first time it returns non-None,
# presents a native prompt before ever calling migrate() (see
# ContentView.loadRaymolrcOrOfferMigration). decline_migration() records a
# "don't ask again" choice so a user who says no isn't re-prompted every
# launch.

import os
import shutil

_HOME = os.path.expanduser('~')

RAYMOLRC_PY = os.path.join(_HOME, '.raymolrc.py')
RAYMOLRC_PML = os.path.join(_HOME, '.raymolrc')

PYMOLRC_PY = os.path.join(_HOME, '.pymolrc.py')
PYMOLRC_PML = os.path.join(_HOME, '.pymolrc')

# Written when the user declines the import prompt, so we don't ask again.
MIGRATION_SKIP_MARKER = os.path.join(_HOME, '.raymolrc.skip')


def migration_candidate():
    '''
    Path to a ~/.pymolrc(.py) that could be imported into ~/.raymolrc(.py),
    or None if there's nothing to offer: a raymolrc already exists, no
    pymolrc was found, or the user already declined once.
    '''
    if os.path.exists(RAYMOLRC_PY) or os.path.exists(RAYMOLRC_PML):
        return None
    if os.path.exists(MIGRATION_SKIP_MARKER):
        return None
    if os.path.exists(PYMOLRC_PY):
        return PYMOLRC_PY
    if os.path.exists(PYMOLRC_PML):
        return PYMOLRC_PML
    return None


def migrate():
    '''Copy the current migration_candidate(), if any, into ~/.raymolrc(.py).'''
    src = migration_candidate()
    if src is None:
        return
    dst = RAYMOLRC_PY if src == PYMOLRC_PY else RAYMOLRC_PML
    try:
        shutil.copyfile(src, dst)
    except OSError as e:
        print(' Warning: could not import %s to %s: %s' % (src, dst, e))


def decline_migration():
    '''Record that the user was asked and said no, so we don't ask again.'''
    try:
        open(MIGRATION_SKIP_MARKER, 'a').close()
    except OSError as e:
        print(' Warning: could not write %s: %s' % (MIGRATION_SKIP_MARKER, e))


def _seed_main_namespace(_self):
    # The vanilla `pymol` CLI executable IS the process's real __main__
    # module, so it already has `cmd`/`stored` etc. in scope when it runs a
    # user's .pymolrc.py via `run(path, 'main')` — that's what lets pymolrc
    # scripts call bare cmd.xxx() without importing it. RayMol's native
    # embeddings boot Python directly, so __main__ starts empty; without
    # this, every migrated .pymolrc.py using that (extremely common)
    # convention would fail with NameError('cmd' is not defined).
    import __main__
    import pymol
    __main__.__dict__.setdefault('cmd', _self)
    __main__.__dict__.setdefault('stored', pymol.stored)


def load(_self=None):
    '''
    Load ~/.raymolrc(.py) if present. Does not migrate from ~/.pymolrc — the
    caller should check migration_candidate() (typically behind a
    user-facing confirmation) and call migrate() first if appropriate.
    '''
    if _self is None:
        from pymol import cmd as _self

    if os.path.exists(RAYMOLRC_PY):
        _seed_main_namespace(_self)
        _self.run(RAYMOLRC_PY, 'main')

    if os.path.exists(RAYMOLRC_PML):
        _self.do('@' + RAYMOLRC_PML)
