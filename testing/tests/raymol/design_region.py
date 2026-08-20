"""Tests for pymol.raymol_design region-redesign selection helpers.

Runs via the repo test runner:
    pymol -ckqy testing/testing.py --run tests/raymol/design_region.py
"""
import json
import os
import tempfile

from pymol import cmd, testing


class TestDesignRegion(testing.PyMOLTestCase):
    def _peptide(self):
        cmd.reinitialize()
        cmd.fab('AAAAA', 'm1')          # 5-residue poly-Ala with full backbone
        return 'm1'

    def testSelectedIndicesMapInGuideOrder(self):
        obj = self._peptide()
        cmd.select('reg', '%s and resi 2+4' % obj)
        from pymol import raymol_design as rd
        marker = rd.selected_design_indices(obj, 'reg', 1)
        self.assertTrue(marker.startswith('DESIGN_SELECTED:'))
        with open(os.path.join(tempfile.gettempdir(),
                               'raymol_design_selected.json')) as f:
            data = json.load(f)
        # resi 2 and 4 → 0-based guide-order indices 1 and 3.
        self.assertEqual(data['indices'], [1, 3])

    def testListSelectionsCountsAndFilters(self):
        obj = self._peptide()
        cmd.select('reg', '%s and resi 2+3+4' % obj)
        cmd.select('empty', 'resn HOH')          # matches nothing on m1
        from pymol import raymol_design as rd
        rd.list_design_selections(obj, 1)
        with open(os.path.join(tempfile.gettempdir(),
                               'raymol_design_selections.json')) as f:
            data = json.load(f)
        names = {d['name']: d['n'] for d in data['selections']}
        self.assertEqual(names.get('reg'), 3)
        self.assertNotIn('empty', names)         # zero-intersection selection filtered out

    def testExcludesInternalSelections(self):
        obj = self._peptide()
        cmd.select('reg', '%s and resi 2+3' % obj)
        cmd.select('_preselect', '%s and resi 1' % obj)   # PyMOL-internal style name
        from pymol import raymol_design as rd
        rd.list_design_selections(obj, 1)
        with open(os.path.join(tempfile.gettempdir(),
                               'raymol_design_selections.json')) as f:
            data = json.load(f)
        names = {d['name'] for d in data['selections']}
        self.assertIn('reg', names)
        self.assertNotIn('_preselect', names)    # internal '_' selections hidden

    def testSourceScopingResolvesOriginalSelection(self):
        # A selection made on the original resolves onto the focused working copy
        # (identical residues) when src is supplied — object-membership vs identity.
        obj = self._peptide()
        cmd.create('%s_design' % obj, obj, zoom=0)   # working copy
        cmd.select('loop', '%s and resi 2+4' % obj)  # selection on the ORIGINAL
        from pymol import raymol_design as rd
        # Focus = working copy; without src the original selection doesn't intersect.
        rd.selected_design_indices('%s_design' % obj, 'loop', 1)
        with open(os.path.join(tempfile.gettempdir(),
                               'raymol_design_selected.json')) as f:
            self.assertEqual(json.load(f)['indices'], [])
        # With src = original, it maps by (chain, resi) to the copy's guide order.
        rd.selected_design_indices('%s_design' % obj, 'loop', 1, src=obj)
        with open(os.path.join(tempfile.gettempdir(),
                               'raymol_design_selected.json')) as f:
            self.assertEqual(json.load(f)['indices'], [1, 3])

    def _sele_payload(self):
        with open(os.path.join(tempfile.gettempdir(),
                               'raymol_design_sele.json')) as f:
            return json.load(f)

    def testSeleIndicesMapInGuideOrder(self):
        obj = self._peptide()
        cmd.select('sele', '%s and resi 2+4' % obj)
        from pymol import raymol_design as rd
        marker = rd.sele_design_indices(obj, 1)
        self.assertTrue(marker.startswith('DESIGN_SELE:'))
        data = self._sele_payload()
        # resi 2 and 4 -> 0-based guide-order indices 1 and 3.
        self.assertEqual(data['indices'], [1, 3])
        self.assertEqual(data['n_total'], 2)

    def testSeleIndicesEmptyWithoutSele(self):
        obj = self._peptide()          # reinitialize() in _peptide drops any 'sele'
        from pymol import raymol_design as rd
        rd.sele_design_indices(obj, 1)
        data = self._sele_payload()
        self.assertEqual(data['indices'], [])
        self.assertEqual(data['n_total'], 0)

    def testSeleIndicesScopeToFocusObject(self):
        obj = self._peptide()
        cmd.fab('AAAAA', 'm2')
        cmd.select('sele', '(m1 and resi 2) or (m2 and resi 3)')
        from pymol import raymol_design as rd
        rd.sele_design_indices('m1', 1)
        data = self._sele_payload()
        # Only m1's residue is designable here; m2's still counts toward n_total.
        self.assertEqual(data['indices'], [1])
        self.assertEqual(data['n_total'], 2)

    def testSeleIndicesResolveOriginalOntoWorkingCopy(self):
        obj = self._peptide()
        cmd.create('%s_design' % obj, obj, zoom=0)
        cmd.select('sele', '%s and resi 2+4' % obj)   # selection on the ORIGINAL
        from pymol import raymol_design as rd
        # Focus = working copy, no src: the original's selection does not intersect.
        rd.sele_design_indices('%s_design' % obj, 1)
        self.assertEqual(self._sele_payload()['indices'], [])
        # With src = original it maps by (chain, resi) onto the copy's guide order.
        rd.sele_design_indices('%s_design' % obj, 1, src=obj)
        self.assertEqual(self._sele_payload()['indices'], [1, 3])

    def testSeleDigestIsGatedOnDesignActive(self):
        obj = self._peptide()
        cmd.select('sele', '%s and resi 2' % obj)
        from pymol import raymol_design as rd
        rd.set_design_active(0)
        self.assertEqual(rd.sele_digest(), '',
                         'digest must cost nothing while Design mode is off')
        rd.set_design_active(1)
        try:
            d1 = rd.sele_digest()
            self.assertTrue(d1)
            # Re-selecting the SAME residues must not change the digest.
            cmd.select('sele', '%s and resi 2' % obj)
            self.assertEqual(rd.sele_digest(), d1)
            # A different residue set must change it.
            cmd.select('sele', '%s and resi 2+3' % obj)
            self.assertNotEqual(rd.sele_digest(), d1)
        finally:
            rd.set_design_active(0)   # never leak the flag into another test

    def _sele_resis(self):
        """Sorted resi strings of the guide residues currently in 'sele'."""
        out = set()
        cmd.iterate('(?sele) and polymer and guide',
                    'out.add(resi)', space={'out': out})
        return sorted(out, key=int)

    def testToggleSeleResidueAddsThenRemoves(self):
        obj = self._peptide()
        from pymol import raymol_design as rd
        self.assertEqual(rd.toggle_sele_residue(obj, '', '2'),
                         'DESIGN_SELE_TOGGLE:on')
        self.assertEqual(self._sele_resis(), ['2'])
        rd.toggle_sele_residue(obj, '', '4')
        self.assertEqual(self._sele_resis(), ['2', '4'])
        # Same residue again -> removed, matching a normal-mode click.
        self.assertEqual(rd.toggle_sele_residue(obj, '', '2'),
                         'DESIGN_SELE_TOGGLE:off')
        self.assertEqual(self._sele_resis(), ['4'])

    def testSetSeleResidueReplaces(self):
        obj = self._peptide()
        from pymol import raymol_design as rd
        rd.toggle_sele_residue(obj, '', '2')
        rd.toggle_sele_residue(obj, '', '3')
        rd.set_sele_residue(obj, '', '5')
        self.assertEqual(self._sele_resis(), ['5'],
                         'set must replace the selection, not extend it')

    def testSetSeleFromSelectionCopiesNamedRegion(self):
        obj = self._peptide()
        cmd.select('loop', '%s and resi 2+3' % obj)
        from pymol import raymol_design as rd
        rd.set_sele_from_selection('loop')
        self.assertEqual(self._sele_resis(), ['2', '3'])

    def testSetSeleFromMissingSelectionEmpties(self):
        obj = self._peptide()
        from pymol import raymol_design as rd
        rd.toggle_sele_residue(obj, '', '2')
        # A name that does not exist must empty 'sele', never raise.
        rd.set_sele_from_selection('nope')
        self.assertEqual(self._sele_resis(), [])

    def testToggleIsResidueScopedRegardlessOfMouseSelectionMode(self):
        # D1: Design clicks always expand to RESIDUE scope. With
        # mouse_selection_mode = 0 (atom) a normal-mode click would commit a single
        # ATOM, which maps to zero guide residues -- a click that silently selects
        # nothing. Design must ignore the setting entirely.
        obj = self._peptide()
        from pymol import raymol_design as rd
        for mode in (0, 1, 2, 4):
            cmd.set('mouse_selection_mode', mode)
            rd.clear_sele()
            rd.toggle_sele_residue(obj, '', '2')
            self.assertEqual(self._sele_resis(), ['2'],
                             'mouse_selection_mode %d must not change the scope '
                             'of a Design-mode click' % mode)
        cmd.set('mouse_selection_mode', 1)   # restore the default

    def testClearSeleEmpties(self):
        obj = self._peptide()
        from pymol import raymol_design as rd
        rd.toggle_sele_residue(obj, '', '2')
        self.assertEqual(rd.clear_sele(), 'DESIGN_SELE_CLEAR:ok')
        self.assertEqual(self._sele_resis(), [])

    def testPollPanelCarriesDesignSeleDigest(self):
        obj = self._peptide()
        cmd.select('sele', '%s and resi 2' % obj)
        from pymol import appkit_inspector as ai
        from pymol import raymol_design as rd
        rd.set_design_active(1)
        try:
            ai.poll_panel()
            path = os.path.join(tempfile.gettempdir(),
                                'pymol_objpanel_%d.json' % os.getpid())
            with open(path) as f:
                payload = json.load(f)
            self.assertTrue(payload.get('design_sele'),
                            "poll_panel must carry the digest while Design is active")
            # And it must cost nothing once Design mode is off.
            rd.set_design_active(0)
            ai.poll_panel()
            with open(path) as f:
                payload = json.load(f)
            self.assertEqual(payload.get('design_sele'), '')
        finally:
            rd.set_design_active(0)
