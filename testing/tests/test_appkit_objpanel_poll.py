"""Tests for pymol.appkit_inspector.poll_panel — the object side-panel payload.

Regression coverage for issue #231: the macOS object panel used to receive its
object list INLINE on one `OBJPANEL:<json>` feedback line. PyMOL's feedback
buffer caps a line at OrthoLineLength (1024 chars), so once a session held ~16
objects (e.g. after `split_states` on a 20-model NMR ensemble) the core split the
line: the truncated first fragment failed JSON decode (panel froze on the stale
list) and the prefix-less continuation leaked into the console every poll tick.

poll_panel() must therefore keep the payload OFF the feedback line: write the
full JSON to a temp file and print only a short constant marker, exactly as
poll() / OBJDETAIL:ready already does for the rep-detail payload.

Object count is only one way to cross the cap. The session that forced the 1.8.1
hotfix held just 12 objects but 48 long-named chain selections; the payload
carries one `sel_counts` entry per selection, so selection count and name length
inflate it just as fast (3578 bytes measured, 3.5x the cap). Both paths are
covered below.
"""

import contextlib
import io
import json
import os
import sys
import tempfile

from pymol import cmd, testing
from pymol import appkit_inspector as ai


@contextlib.contextmanager
def capture_console():
    """Capture the REAL console stream (fd 1), not just sys.stdout.

    Needed for issue #219: the `Selector-Error: Invalid selection name "dist01".`
    line is written by the C++ selector through PyMOL's feedback system directly
    to fd 1. contextlib.redirect_stdout only rebinds the Python-level sys.stdout
    object, so it never sees that line — a test built on it would pass against the
    unfixed code.
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

# layer0/PyMOLGlobals.h: OrthoLineLength — the per-line feedback cap that the
# old inline payload overflowed.
ORTHO_LINE_LENGTH = 1024

PANEL_JSON = os.path.join(tempfile.gettempdir(), 'pymol_objpanel.json')


class TestObjPanelPoll(testing.PyMOLTestCase):

    def _split_ensemble(self, base='ens', nstates=20):
        """Mirror `fetch 2kn1; split_states 2kn1`: an N-state object split into N
        single-state objects, so the object count crosses the overflow threshold."""
        cmd.delete('all')
        cmd.fab('ACDEFG', base)
        for i in range(2, nstates + 1):
            cmd.create(base, base, 1, i)
        self.assertEqual(cmd.count_states(base), nstates)
        cmd.split_states(base)
        return base

    # Per-chain selection labels in the style of the hotfix session's binder
    # designs, paired with a cheap expression that makes each count distinct.
    DESIGN_CHAINS = (
        ('IL18Ralpha', 'resi 1-2'),
        ('IL18BPmimic', 'resi 3-4'),
        ('binderChainB', 'resi 5-6'),
        ('epitopeHotspot', 'name CA'),
    )

    def _design_session(self, nobj=12):
        """Mirror the session that forced the 1.8.1 hotfix: a dozen binder-design
        complexes — well under the object-count threshold, and no split_states —
        each carrying several long-named chain selections (`s26_r3d28_il18_IL18Ralpha`
        and friends), so the payload crosses the cap through selections instead."""
        cmd.delete('all')
        objs, sels = [], []
        for i in range(nobj):
            obj = 's%02d_r3d28_il18' % (15 + i)
            cmd.fab('ACDEFG', obj)
            objs.append(obj)
            for chain, expr in self.DESIGN_CHAINS:
                sel = '%s_%s' % (obj, chain)
                cmd.select(sel, '%s and (%s)' % (obj, expr), quiet=1)
                sels.append(sel)
        return objs, sels

    def _poll(self):
        """Run poll_panel(), returning (printed_lines, payload_from_temp_file)."""
        if os.path.exists(PANEL_JSON):
            os.remove(PANEL_JSON)
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            ai.poll_panel()
        lines = [ln for ln in buf.getvalue().splitlines() if ln.strip()]
        with open(PANEL_JSON) as f:
            return lines, json.load(f)

    def testMarkerStaysUnderFeedbackCapWithManyObjects(self):
        # The bug: the emitted line grew ~62 bytes per object and blew past 1024
        # at 16 objects. The marker must be short and constant instead.
        base = self._split_ensemble()
        objs = list(cmd.get_names('public_objects'))
        self.assertGreater(len(objs), 16, 'need to cross the old overflow threshold')

        lines, _ = self._poll()

        self.assertEqual(lines, ['OBJPANEL:ready'])
        for ln in lines:
            self.assertLess(len(ln), ORTHO_LINE_LENGTH)

    def testPayloadIsCompleteForEverySplitObject(self):
        # The truncated first fragment used to drop the whole update; the file
        # payload must carry every object the panel needs to render.
        base = self._split_ensemble()
        objs = list(cmd.get_names('public_objects'))

        _, payload = self._poll()

        self.assertEqual(sorted(payload['objects']), sorted(objs))
        self.assertEqual(payload['nstate'][base], 20)
        for i in range(1, 21):
            name = '%s_%04d' % (base, i)
            self.assertIn(name, payload['objects'])
            self.assertEqual(payload['nstate'][name], 1)
            self.assertIn(name, payload['has_transp'])

    def testPayloadCarriesSelectionsAndEnabledState(self):
        base = self._split_ensemble(nstates=2)
        cmd.select('mysele', '%s_0001 and name CA' % base)
        cmd.disable('%s_0002' % base)

        _, payload = self._poll()

        self.assertIn('mysele', payload['selections'])
        self.assertEqual(payload['sel_counts']['mysele'],
                         cmd.count_atoms('mysele'))
        self.assertIn('%s_0001' % base, payload['enabled'])
        self.assertNotIn('%s_0002' % base, payload['enabled'])

    def testMarkerStaysUnderFeedbackCapWithManySelections(self):
        # The 1.8.1 path: few objects, but `sel_counts` + `selections` carry 48
        # ~25-char names. The marker must be immune to that too.
        objs, sels = self._design_session()
        self.assertLess(len(objs), 16,
                        'object count alone must stay under the old threshold, '
                        'so only the selection path can overflow here')
        self.assertEqual(len(sels), 48, 'fixture must match the hotfix session')

        lines, payload = self._poll()

        # Exactly what the pre-#231 code would have put on the feedback line.
        inline = 'OBJPANEL:' + json.dumps(payload)
        self.assertGreater(len(inline), ORTHO_LINE_LENGTH,
                           'selection-heavy payload must cross the cap, else '
                           'this test proves nothing')

        self.assertEqual(lines, ['OBJPANEL:ready'])
        for ln in lines:
            self.assertLess(len(ln), ORTHO_LINE_LENGTH)

    def testPayloadIsCompleteForEveryChainSelection(self):
        # Truncation used to drop the whole update; the file payload must carry
        # every object AND every selection the panel needs to render.
        objs, sels = self._design_session()

        _, payload = self._poll()

        self.assertEqual(sorted(payload['objects']), sorted(objs))
        self.assertEqual(sorted(payload['selections']), sorted(sels))
        for sel in sels:
            self.assertEqual(payload['sel_counts'][sel], cmd.count_atoms(sel))
            self.assertGreater(payload['sel_counts'][sel], 0)

    def testMarkerLengthDoesNotGrowWithObjectCount(self):
        # Constant-length marker is the property that makes the panel immune to
        # the cap regardless of how many objects the session holds.
        cmd.delete('all')
        cmd.fab('ACDEFG', 'one')
        small, _ = self._poll()

        self._split_ensemble(base='many', nstates=20)
        large, _ = self._poll()

        self.assertEqual(small, large)


class TestNonMolecularObjectsAreNotProbed(testing.PyMOLTestCase):
    """Regression coverage for issue #219.

    Creating a measurement made the console repeat

        Selector-Error: Invalid selection name "dist01".
        dist01<--

    at 2.00 lines/second, indefinitely (measured on the pre-fix build). The panel
    poll probed EVERY public object for a per-atom transparency override without
    filtering by type, so `cmd.iterate` was handed a measurement object and the
    C++ selector rejected it. The Python try/except around the iterate swallowed
    the exception but not the already-written feedback line — so it could only be
    fixed by not making the call.
    """

    SELECTOR_ERROR = b'Invalid selection name'

    def _measured_session(self):
        cmd.delete('all')
        cmd.fab('ACDEFG', 'mol')
        cmd.distance('dist01', 'mol and i. 1 and n. CA', 'mol and i. 3 and n. CA')
        cmd.angle('ang01', 'mol and i. 1 and n. CA', 'mol and i. 2 and n. CA',
                  'mol and i. 3 and n. CA')
        self.assertEqual(cmd.get_type('dist01'), 'object:measurement')
        return list(cmd.get_names('public_objects'))

    def testIsMoleculeRejectsMeasurements(self):
        self._measured_session()
        self.assertTrue(ai.is_molecule('mol'))
        self.assertFalse(ai.is_molecule('dist01'))
        self.assertFalse(ai.is_molecule('ang01'))
        self.assertFalse(ai.is_molecule('no_such_object'))

    def testPollPanelEmitsNoSelectorErrorForMeasurements(self):
        objs = self._measured_session()
        self.assertIn('dist01', objs,
                      'the measurement must be in public_objects, else the poll '
                      'never probes it and this test proves nothing')

        with capture_console() as out:
            for _ in range(5):        # the real panel polls ~2x/second
                ai.poll_panel()
        console = out.read()

        self.assertNotIn(self.SELECTOR_ERROR, console,
                         'poll_panel must not hand a non-molecular object to the '
                         'selector (issue #219); console was: %r' % console)

    def testExpandedCardBuildEmitsNoSelectorErrorForMeasurements(self):
        # The rep-detail path reaches transp_summary independently of poll_panel,
        # and spams identically when a measurement's card is expanded.
        objs = self._measured_session()

        with capture_console() as out:
            for _ in range(5):
                ai.poll(objs)
        console = out.read()

        self.assertNotIn(self.SELECTOR_ERROR, console,
                         'poll()/_build must not probe non-molecular objects '
                         '(issue #219); console was: %r' % console)

    def testPanelStillReportsMeasurementsAndRealTransparency(self):
        # The fix must silence the probe without dropping the objects from the
        # panel or breaking per-atom transparency detection on real molecules.
        self._measured_session()
        cmd.show('cartoon', 'mol')
        cmd.alter('mol and resi 1-2', 's.cartoon_transparency = 0.5')

        ai.poll_panel()
        with open(PANEL_JSON) as f:
            payload = json.load(f)

        for name in ('mol', 'dist01', 'ang01'):
            self.assertIn(name, payload['objects'])
            self.assertIn(name, payload['has_transp'])
        self.assertFalse(payload['has_transp']['dist01'])
        self.assertFalse(payload['has_transp']['ang01'])
        # A measurement contributes an empty rep list rather than being probed.
        detail = ai._build(['mol', 'dist01'])['detail']
        self.assertEqual(detail['dist01'], [])
        self.assertTrue(detail['mol'], 'the molecule must still describe its reps')
