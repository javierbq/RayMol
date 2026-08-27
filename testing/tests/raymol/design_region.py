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
        # Only m1's residue is designable here; m2's is reported as off-scope so the
        # UI can say so rather than silently dropping it.
        self.assertEqual(data['indices'], [1])
        self.assertEqual(data['n_off'], 1)
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

    def testSelectingAMissingNameEmptiesSeleWithoutRaising(self):
        # The '(?name)' form is how a NAMED selection reaches Design mode now that
        # the picker is gone (the PYMOL_AUTODESIGN hook writes exactly this). A
        # misspelled or deleted name must empty 'sele' rather than raise, because
        # the caller reports "matched no designable residues" from the resulting
        # empty selection — an exception would abort before that check.
        obj = self._peptide()
        from pymol import raymol_design as rd
        rd.toggle_sele_residue(obj, '', '2')
        self.assertEqual(self._sele_resis(), ['2'], 'pre-condition: something selected')
        cmd.select('sele', '(?nope)', enable=1)          # must not raise
        self.assertEqual(self._sele_resis(), [])
        # ...and the real thing still works through the same expression.
        cmd.select('loop', '%s and resi 2+3' % obj)
        cmd.select('sele', '(?loop)', enable=1)
        self.assertEqual(self._sele_resis(), ['2', '3'])

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

    # ------------------------------------------------------------------
    # I1: Design-mode 'sele' WRITES must resolve in the same scope the READS do.
    #
    # Inside an edit session the focus object is the working copy while the
    # selection still lives on the ORIGINAL's atoms. sele_design_indices reads
    # through _scope(obj, src) -- residue IDENTITY across both objects -- so a
    # write that only touches the focus object's atoms disagrees with the read
    # from the first mutation onward.
    # ------------------------------------------------------------------

    def _design_session(self):
        """m1 plus the working copy an edit session would focus.

        Built through make_working_copy rather than cmd.create, so the original ends
        up DISABLED exactly as it does in a real session — which is what makes
        "the selection must be on the visible object" a meaningful assertion.
        """
        src = self._peptide()
        from pymol import raymol_design as rd
        work = rd.make_working_copy(src).split(':', 1)[1]
        return src, work

    def _sele_resis_on(self, obj):
        """Sorted resi strings of `obj`'s own guide residues in 'sele'."""
        out = set()
        cmd.iterate('(%s) and (?sele) and polymer and guide' % obj,
                    'out.add(resi)', space={'out': out})
        return sorted(out, key=int)

    def testToggleInEditSessionRemovesRegionMember(self):
        src, work = self._design_session()
        cmd.select('sele', '%s and resi 2+3+4' % src)   # region built pre-session
        from pymol import raymol_design as rd
        # The user clicks residue 4 again to drop it from the region.
        rd.toggle_sele_residue(work, '', '4', src=src)
        rd.sele_design_indices(work, 1, src=src)
        data = self._sele_payload()
        self.assertEqual(data['indices'], [1, 2],
                         'a click inside an edit session must be able to REMOVE a '
                         'region member -- an unscoped write re-adds it instead')
        self.assertEqual(data['n_off'], 0,
                         'a residue in scope on BOTH the working copy and the '
                         'original is not on "another structure"')

    def testToggleInEditSessionAddsResidueExactlyOnce(self):
        src, work = self._design_session()
        cmd.select('sele', '%s and resi 2+3' % src)
        from pymol import raymol_design as rd
        rd.toggle_sele_residue(work, '', '5', src=src)   # a NEW residue, mid-session
        rd.sele_design_indices(work, 1, src=src)
        data = self._sele_payload()
        self.assertEqual(data['indices'], [1, 2, 4])
        self.assertEqual(data['n_off'], 0,
                         'everything selected is inside the scope, so nothing is '
                         'off-structure -- n_total counts (object, residue) keys and '
                         'legitimately sees the mid-session residue on both objects')
        self.assertEqual(data['n_total'], 4)

    def testRepackKeepsResiduesSelectedDuringTheSession(self):
        # autoRepack defaults ON, so every Redesign ends in load_repacked -- a
        # topology replace of the working copy. Residues clicked DURING the session
        # must not lose their region membership when that happens.
        src, work = self._design_session()
        cmd.select('sele', '%s and resi 2+3' % src)
        from pymol import raymol_design as rd
        rd.toggle_sele_residue(work, '', '5', src=src)
        self.assertNotIn(src, cmd.get_names('objects', 1),
                         'pre-condition: a session disables the original, so pink '
                         'markers on it alone would draw nothing')
        rd.load_repacked(work, cmd.get_pdbstr(work), src=src)
        rd.sele_design_indices(work, 1, src=src)
        self.assertEqual(self._sele_payload()['indices'], [1, 2, 4],
                         'a repack must not silently shrink the region')
        # ... and the membership must be on the object the user can SEE. The replace
        # annihilates the working copy's atoms, so without re-assertion the region
        # stays armed while nothing is drawn.
        self.assertEqual(self._sele_resis_on(work), ['2', '3', '5'],
                         'the replaced (visible) object must carry the selection')

    def testSetSeleResidueInEditSessionIsVisibleToTheRead(self):
        src, work = self._design_session()
        from pymol import raymol_design as rd
        rd.set_sele_residue(work, '', '3', src=src)
        rd.sele_design_indices(work, 1, src=src)
        data = self._sele_payload()
        self.assertEqual(data['indices'], [2])
        self.assertEqual(data['n_off'], 0,
                         'the residue is in scope, so it is not off-structure')

    def testDropObjectFromSeleClearsAKeptWorkingCopy(self):
        # A residue clicked during a session is marked on BOTH the copy and the
        # original (that is what survives a repack). The Keep path retains the copy
        # but clears the source, so nothing can address the copy again — the
        # membership must be narrowed off it at teardown or it can never be cleared.
        src, work = self._design_session()
        from pymol import raymol_design as rd
        rd.toggle_sele_residue(work, '', '3', src=src)
        self.assertEqual(self._sele_resis_on(work), ['3'],
                         'pre-condition: the scoped write marks the working copy too')

        rd.drop_object_from_sele(work)
        self.assertEqual(self._sele_resis_on(work), [],
                         "no 'sele' membership may survive on a kept working copy")
        self.assertEqual(self._sele_resis_on(src), ['3'],
                         'the addressable original keeps it')
        # And the post-Keep scope (no src) can now remove it for good.
        rd.toggle_sele_residue(src, '', '3')
        self.assertEqual(self._sele_resis(), [])

    def testDropObjectFromSeleNeverLeavesAnEnabledEmptySele(self):
        # An enabled EMPTY 'sele' would suppress every other selection.
        src, work = self._design_session()
        from pymol import raymol_design as rd
        rd.set_sele_residue(work, '', '3')      # unscoped: only on the copy
        rd.drop_object_from_sele(work)
        self.assertEqual(self._sele_resis(), [])
        self.assertNotIn('sele', cmd.get_names('selections', 1) or [],
                         "an emptied 'sele' must not be left enabled")

    def testSeleDigestAgreesWithSeleIndicesPayload(self):
        # The poll gate compares rd.sele_digest() against the digest the Swift side
        # recorded from sele_design_indices. If the two ever diverge the poll either
        # never fires or fires on every 500 ms tick.
        obj = self._peptide()
        cmd.select('sele', '%s and resi 2+4' % obj)
        from pymol import raymol_design as rd
        rd.set_design_active(1)
        try:
            rd.sele_design_indices(obj, 1)
            self.assertEqual(rd.sele_digest(), self._sele_payload()['digest'],
                             'the two producers of the gating digest must agree')
        finally:
            rd.set_design_active(0)

    def testDigestSeparatesIndependentSimilarlyNamedObjects(self):
        # Two independent structures whose names merely LOOK like a working-copy
        # pair ('foo' and 'foo_design') are an ordinary thing to have loaded in a
        # design workflow. Selecting the same chain/resi on each in turn must change
        # the digest, or the poll skips the re-derive and the region never arms:
        # the user is left with a selected structure and a dead Redesign button.
        cmd.reinitialize()
        cmd.fab('AAAAA', 'foo')
        cmd.fab('AAAAA', 'foo_design')      # NOT a working copy of foo
        from pymol import raymol_design as rd
        rd.set_design_active(1)
        try:
            cmd.select('sele', 'foo_design and resi 2+3')
            d1 = rd.sele_digest()
            cmd.select('sele', 'foo and resi 2+3')
            d2 = rd.sele_digest()
            self.assertNotEqual(d1, d2,
                                'the digest must distinguish the same residues on two '
                                'different objects, whatever they are named')
        finally:
            rd.set_design_active(0)
