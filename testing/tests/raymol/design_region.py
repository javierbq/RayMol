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
