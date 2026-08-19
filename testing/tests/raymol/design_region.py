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
