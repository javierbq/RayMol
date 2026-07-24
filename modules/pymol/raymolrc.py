# raymolrc.py
#
# RayMol's native macOS/iOS embeddings (SwiftUI/Metal and the legacy AppKit
# app) boot Python directly and never go through pymol.invocation.parse_args,
# so a user's ~/.pymolrc is silently ignored there (see RayMol#225). This
# module gives the native apps an equivalent startup script, ~/.raymolrc(.py),
# and migrates an existing ~/.pymolrc(.py) into it the first time it's found.

import os
import shutil

_HOME = os.path.expanduser('~')

RAYMOLRC_PY = os.path.join(_HOME, '.raymolrc.py')
RAYMOLRC_PML = os.path.join(_HOME, '.raymolrc')

PYMOLRC_PY = os.path.join(_HOME, '.pymolrc.py')
PYMOLRC_PML = os.path.join(_HOME, '.pymolrc')


def _migrate(src, dst):
    if os.path.exists(dst) or not os.path.exists(src):
        return
    try:
        shutil.copyfile(src, dst)
    except OSError as e:
        print(' Warning: could not import %s to %s: %s' % (src, dst, e))


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
    Load ~/.raymolrc(.py) if present. The first time neither file exists yet,
    import it from ~/.pymolrc(.py) so existing PyMOL customizations carry
    over. Safe to call once per process at startup, after the command API is
    available.
    '''
    if _self is None:
        from pymol import cmd as _self

    _migrate(PYMOLRC_PY, RAYMOLRC_PY)
    _migrate(PYMOLRC_PML, RAYMOLRC_PML)

    if os.path.exists(RAYMOLRC_PY):
        _seed_main_namespace(_self)
        _self.run(RAYMOLRC_PY, 'main')

    if os.path.exists(RAYMOLRC_PML):
        _self.do('@' + RAYMOLRC_PML)
