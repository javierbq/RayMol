"""Regression tests for pymol.raymol_theme.apply_to (issue #272).

Opening a .pse used to log on every session open:

    raymol_theme.apply_to('top6_candidates') failed:  Error: Invalid selection
    name "top6_candidates".

because the app themed a filename-derived object name that a session restore
never creates (a .pse restores its OWN object names). apply_to must no-op for a
name that doesn't resolve — and it must decide that BEFORE touching the
selector, because the C++ selector writes `Invalid selection name` straight to
the console feedback stream (fd 1), out of reach of apply_to's try/except (same
mechanism as issue #219).

Runs under the embedded harness: pymol -ckqy testing/testing.py --run <this>.
"""

import contextlib
import os
import sys
import tempfile

from pymol import cmd, testing
from pymol import raymol_theme


@contextlib.contextmanager
def capture_console():
    """Capture the REAL console stream (fd 1), not just sys.stdout.

    The selector error is written by C++ through PyMOL's feedback system
    directly to fd 1; contextlib.redirect_stdout never sees it, so a test built
    on it would pass against the unfixed code. Same helper as
    test_appkit_objpanel_poll.py (issue #219).
    """
    sys.stdout.flush()
    saved = os.dup(1)
    tmp = tempfile.TemporaryFile(mode='w+b')
    try:
        os.dup2(tmp.fileno(), 1)
        yield tmp
        sys.stdout.flush()
    finally:
        os.dup2(saved, 1)
        os.close(saved)
        tmp.seek(0)


@contextlib.contextmanager
def capture_all_output():
    """Capture fd 1 AND the current sys.stdout object, yield a getter for both.

    Both layers matter: the fork's embedded build emits the selector error
    through C++ straight to fd 1, while apply_to's own `failed:` fallback is a
    Python print — and under pytest, sys.stdout is pytest's capture object,
    which does NOT write through fd 1. Capturing only the fd let the unfixed
    code pass this test.
    """
    import io
    pyout = io.StringIO()
    result = {}
    with capture_console() as fdout, contextlib.redirect_stdout(pyout):
        yield lambda: result['console']
    # capture_console's finally has restored fd 1 and rewound the temp file;
    # only now is its content readable.
    result['console'] = (fdout.read().decode(errors='replace')
                         + pyout.getvalue())


SELECTOR_ERROR = 'Invalid selection name'


class TestApplyToUnknownName(testing.PyMOLTestCase):

    def testUnknownNameIsSilent(self):
        # Non-empty session, then theme a name nothing created — the exact call
        # the app used to make after `load session.pse, <filename-stem>`.
        cmd.pseudoatom('s26_r3d56_il2')

        with capture_all_output() as get_console:
            raymol_theme.apply_to('top6_candidates')
        console = get_console()

        self.assertNotIn(SELECTOR_ERROR, console,
                         'apply_to on a missing name must not reach the '
                         'selector (issue #272); console was: %r' % console)
        self.assertNotIn('failed', console,
                         'apply_to on a missing name must no-op silently, not '
                         'print its failure fallback; console was: %r' % console)

    def testSessionRestoreSequenceIsSilent(self):
        # Full issue-#272 sequence: save a session, restore it, then theme the
        # filename-derived name the restore never creates.
        cmd.pseudoatom('s26_r3d56_il2')
        with testing.mktemp('.pse') as session:
            cmd.save(session)
            cmd.reinitialize()

            with capture_all_output() as get_console:
                cmd.load(session)
                raymol_theme.apply_to('top6_candidates')
            console = get_console()

        # The restore itself must have worked...
        self.assertIn('s26_r3d56_il2', cmd.get_names('objects'))
        # ...and the bogus theming call must leave no trace on the console.
        self.assertNotIn(SELECTOR_ERROR, console,
                         'session open must not log a selector error '
                         '(issue #272); console was: %r' % console)

    def testExistingObjectIsStillThemed(self):
        # The guard must only skip MISSING names — a real freshly loaded object
        # still gets the default style (spheres here: visible on any atoms).
        cmd.pseudoatom('m1')
        saved_style = raymol_theme._default_style
        raymol_theme._default_style = 'spheres'
        try:
            raymol_theme.apply_to('m1')
        finally:
            raymol_theme._default_style = saved_style

        self.assertEqual(cmd.count_atoms('m1 and rep spheres'),
                         cmd.count_atoms('m1'),
                         'apply_to must still theme an object that exists')
