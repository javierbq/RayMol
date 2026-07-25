"""Detect a stale installed `pymol` Python layer vs. this source checkout.

The test runner imports `pymol` from wherever it is *installed* (site-packages),
never from this checkout's `modules/pymol`. `pip install .` copies those files,
so a checkout that has moved on since the last install silently exercises OLD
code. That produces failures which look like real bugs on master -- and, worse,
can let a genuine regression pass. CI is immune (it installs from source on
every run); long-lived local venvs are not.

Reporting the drift is all this does; the runner only warns. Pure stdlib, and
deliberately free of any `pymol` import so it can be unit-tested headless.
"""

import filecmp
import os

#: Names listed individually in the warning before it collapses to a count.
_MAX_LISTED = 8


def compare_python_layer(source_dir, installed_dir):
    """Compare ``*.py`` in *source_dir* against *installed_dir*.

    Returns ``(stale, missing)``, each a sorted list of basenames: *stale* is
    present in both but differs in content, *missing* is absent from the
    install. A file that resolves to the same path on disk (a symlinked or
    editable install) is up to date. Files only the install has are ignored --
    the checkout does not claim to own them. A vanished or unreadable
    *source_dir* yields no findings, so a non-checkout run stays quiet.
    """
    stale = []
    missing = []
    try:
        names = os.listdir(source_dir)
    except OSError:
        return [], []
    for name in names:
        if not name.endswith('.py'):
            continue
        source = os.path.join(source_dir, name)
        installed = os.path.join(installed_dir, name)
        if not os.path.exists(installed):
            missing.append(name)
            continue
        try:
            if os.path.realpath(source) == os.path.realpath(installed):
                continue
            if not filecmp.cmp(source, installed, shallow=False):
                stale.append(name)
        except OSError:
            # Unreadable either side: report it rather than crash the run.
            stale.append(name)
    return sorted(stale), sorted(missing)


def _summarize(names):
    if len(names) <= _MAX_LISTED:
        return ', '.join(names)
    return '%s, ... (%d more)' % (', '.join(names[:_MAX_LISTED]),
                                  len(names) - _MAX_LISTED)


def format_warning(stale, missing, source_dir, installed_dir):
    """Render a banner for the findings, or None when the layer is up to date."""
    if not stale and not missing:
        return None
    counts = '%d stale, %d missing' % (len(stale), len(missing))
    lines = [
        '',
        '=' * 78,
        'WARNING: the installed pymol Python layer does not match this checkout',
        '         (%s) -- these tests are NOT exercising your source.' % counts,
        '',
        '  checkout:  %s' % source_dir,
        '  installed: %s' % installed_dir,
    ]
    if stale:
        lines += ['', '  stale (installed copy differs):', '    %s' % _summarize(stale)]
    if missing:
        lines += ['', '  missing from install:', '    %s' % _summarize(missing)]
    lines += [
        '',
        '  Failures below may be bogus -- and real regressions may be hidden.',
        '  Refresh with `pip install .`, or symlink the Python layer:',
        '',
        '    SP="%s"' % installed_dir,
        '    for f in "%s"/*.py; do ln -sfn "$f" "$SP/$(basename "$f")"; done' % source_dir,
        '=' * 78,
        '',
    ]
    return '\n'.join(lines)


def check_installed_layer(source_dir, installed_dir):
    """Convenience wrapper: returns the warning text, or None when clean."""
    stale, missing = compare_python_layer(source_dir, installed_dir)
    return format_warning(stale, missing, source_dir, installed_dir)
