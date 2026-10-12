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


ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), os.pardir, os.pardir))


class TestAutoColorContrast(testing.PyMOLTestCase):
    """Regression tests for auto-colour contrast floor against light backgrounds (issue #392).

    PyMOL's auto-colour cycle contains pale swatches (hydrogen 0.9 grey, grey70,
    lightpink, bluewhite, wheat). When loaded onto light viewport backgrounds
    (Paper white, Dawn off-white), objects taking those swatches can be virtually
    invisible. ColorGetNext must skip swatches lacking a minimum contrast floor
    against the background, while preserving the vanilla sequence on dark backgrounds
    and leaving explicit colours untouched.
    """

    def setUp(self):
        super().setUp()
        self._saved_bg_rgb = cmd.get('bg_rgb')
        self._saved_auto_color_next = cmd.get('auto_color_next')

    def tearDown(self):
        cmd.delete('all')
        if hasattr(self, '_saved_bg_rgb'):
            cmd.set('bg_rgb', self._saved_bg_rgb)
        if hasattr(self, '_saved_auto_color_next'):
            cmd.set('auto_color_next', self._saved_auto_color_next)
        super().tearDown()

    def _carbon_rgb(self, obj):
        colors = []
        cmd.iterate(f'{obj} and name CA', 'colors.append(color)', space={'colors': colors})
        self.assertTrue(len(colors) > 0, f'No CA atoms found in {obj}')
        unique_colors = set(colors)
        self.assertEqual(len(unique_colors), 1,
                         f'Expected single CA colour in {obj}, got {unique_colors}')
        return cmd.get_color_tuple(colors[0])

    def _build_protein(self, name='p1'):
        pdb_path = os.path.join(ROOT, 'test', 'dat', '1tii.pdb')
        if os.path.isfile(pdb_path):
            cmd.load(pdb_path, name)
        else:
            cmd.fab('AKELEAKELEAKELEAKELE', name, ss=1)
        return name

    def testPaleSwatchSkippedOnWhite(self):
        raymol_theme.set_palette(bg=(1.0, 1.0, 1.0))
        # Slot 5 is hydrogen (0.9, 0.9, 0.9)
        cmd.set('auto_color_next', 5)
        self._build_protein('p1')
        rgb = self._carbon_rgb('p1')
        max_dist = max(abs(c - 1.0) for c in rgb)
        self.assertGreaterEqual(
            max_dist, 0.3,
            f'Carbon colour {rgb} too close to white (max channel dist {max_dist:.3f} < 0.3)'
        )

        cmd.delete('p1')
        # Slot 13 is grey70 (0.71, 0.71, 0.71)
        cmd.set('auto_color_next', 13)
        self._build_protein('p2')
        rgb2 = self._carbon_rgb('p2')
        max_dist2 = max(abs(c - 1.0) for c in rgb2)
        self.assertGreaterEqual(
            max_dist2, 0.3,
            f'Carbon colour {rgb2} too close to white (max channel dist {max_dist2:.3f} < 0.3)'
        )

    def testDawnBackgroundSkipsPaleSwatches(self):
        dawn_bg = (1.0, 0.97, 0.93)
        raymol_theme.set_palette(bg=dawn_bg)
        cmd.set('auto_color_next', 5)
        self._build_protein('p1')
        rgb = self._carbon_rgb('p1')
        max_dist = max(abs(c - b) for c, b in zip(rgb, dawn_bg))
        self.assertGreaterEqual(
            max_dist, 0.3,
            f'Carbon colour {rgb} too close to Dawn bg {dawn_bg} (max channel dist {max_dist:.3f} < 0.3)'
        )

    def testDarkBackgroundSequenceUnchanged(self):
        cmd.bg_color('black')
        cmd.set('auto_color_next', 5)
        self._build_protein('p1')
        rgb = self._carbon_rgb('p1')
        expected = cmd.get_color_tuple('hydrogen')
        for c, e in zip(rgb, expected):
            self.assertAlmostEqual(c, e, delta=1e-3, msg=f'Expected hydrogen swatch, got {rgb}')
        self.assertEqual(cmd.get('auto_color_next'), '6')

    def testGradientBackgroundIsWhatCounts(self):
        # With bg_gradient on, the viewport shows bg_rgb_top/bottom, not
        # bg_rgb: a light gradient over a dark bg_rgb must still skip hydrogen.
        cmd.bg_color('black')
        cmd.set('bg_gradient', 1)
        cmd.set('bg_rgb_top', 'white')
        cmd.set('bg_rgb_bottom', 'white')
        cmd.set('auto_color_next', 5)
        self._build_protein('p1')
        rgb = self._carbon_rgb('p1')
        max_dist = max(abs(c - 1.0) for c in rgb)
        self.assertGreaterEqual(
            max_dist, 0.3,
            f'Carbon colour {rgb} too close to the white gradient (max channel dist {max_dist:.3f} < 0.3)'
        )

    def testExplicitColourIsKept(self):
        raymol_theme.set_palette(bg=(1.0, 1.0, 1.0))
        self._build_protein('p1')
        cmd.color('white', 'p1')
        rgb = self._carbon_rgb('p1')
        expected = cmd.get_color_tuple('white')
        self.assertEqual(rgb, expected, f'Explicit white was altered: {rgb}')

    def testRayTracedCartoonContrastsWithWhite(self):
        try:
            from PIL import Image
        except ImportError:
            self.skipTest('Pillow is not installed')

        raymol_theme.set_palette(bg=(1.0, 1.0, 1.0))
        cmd.set('auto_color_next', 5)
        self._build_protein('p1')
        cmd.hide('everything')
        cmd.show('cartoon')
        cmd.orient()
        cmd.set('ray_opaque_background', 1)

        with testing.mktemp('.png') as path:
            cmd.png(path, width=320, height=240, ray=1)
            img = Image.open(path).convert('RGB')

        import numpy as np
        arr = np.array(img, dtype=float)
        bg = arr[0, 0]
        diff = np.abs(arr - bg)
        max_diff = np.max(diff, axis=-1)
        mask = max_diff > 8
        self.assertTrue(np.any(mask), 'No cartoon pixels found distinguishing from background')
        mean_val = float(np.mean(max_diff[mask]))
        # Measured on 1tii: ~79 with the unfixed core (slot 5 = hydrogen grey),
        # ~127 with the fix (slot 5 skipped, slate picked). 100 is the midpoint.
        self.assertGreaterEqual(
            mean_val, 100.0,
            f'Mean max channel difference from background is {mean_val:.2f} (expected >= 100, issue #392)'
        )

