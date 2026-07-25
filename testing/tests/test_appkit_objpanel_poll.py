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
"""

import contextlib
import io
import json
import os
import tempfile

from pymol import cmd, testing
from pymol import appkit_inspector as ai

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

    def testMarkerLengthDoesNotGrowWithObjectCount(self):
        # Constant-length marker is the property that makes the panel immune to
        # the cap regardless of how many objects the session holds.
        cmd.delete('all')
        cmd.fab('ACDEFG', 'one')
        small, _ = self._poll()

        self._split_ensemble(base='many', nstates=20)
        large, _ = self._poll()

        self.assertEqual(small, large)
