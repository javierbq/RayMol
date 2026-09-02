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

    def testAtomAndCAlphaModesStillMeanTheResidue(self):
        # What survives of the old "Design ignores mouse_selection_mode" rule
        # (which #371 replaced -- see TestDesignClickSelectionLevel): a lone ATOM
        # (mode 0) or a lone CA (mode 6) maps to a scope with nothing designable in
        # it, so a click at those levels would select nothing at all. Design's unit
        # is a residue, so both still expand to one.
        obj = self._peptide()
        from pymol import raymol_design as rd
        self.addCleanup(cmd.set, 'mouse_selection_mode', 1)
        for mode in (0, 1, 6):
            cmd.set('mouse_selection_mode', mode)
            rd.clear_sele()
            rd.toggle_sele_residue(obj, '', '2')
            self.assertEqual(self._sele_resis(), ['2'],
                             'mouse_selection_mode %d must still mean the residue'
                             % mode)

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


class TestDesignFields(testing.PyMOLTestCase):
    """The Design tool's two typed inputs (#371).

    `resolve_target` backs the target text box: it answers "which ONE structure
    does this expression mean", so the field accepts a selection expression and
    not merely an object name. `select_region` backs the region text box: it
    points 'sele' at the expression, which is why clicking residues and typing an
    expression stay one pipeline rather than two.

    Both take base64 so a user's quotes, backslashes and non-ASCII never become
    Python: the Swift side interpolates the argument into a runPython string.
    """

    def _b64(self, expr):
        import base64
        return base64.b64encode(expr.encode('utf-8')).decode('ascii')

    def _target_payload(self):
        with open(os.path.join(tempfile.gettempdir(),
                               'raymol_design_target.json')) as f:
            return json.load(f)

    def _select_payload(self):
        with open(os.path.join(tempfile.gettempdir(),
                               'raymol_design_select.json')) as f:
            return json.load(f)

    def _two(self):
        cmd.reinitialize()
        cmd.fab('AAAAA', 'm1')
        cmd.fab('GGGGG', 'm2')
        # cmd.fab leaves the chain EMPTY, so a chain-scoped expression would match
        # nothing and every assertion about one would pass vacuously.
        cmd.alter('m1', 'chain = "A"')
        cmd.alter('m2', 'chain = "B"')
        cmd.sort()

    # ── resolve_target ─────────────────────────────────────────────────────────

    def testResolveTargetAcceptsAnObjectName(self):
        self._two()
        from pymol import raymol_design as rd
        rd.resolve_target(self._b64('m2'))
        self.assertEqual(self._target_payload()['object'], 'm2')

    def testResolveTargetResolvesASubSelectionToItsObject(self):
        self._two()
        from pymol import raymol_design as rd
        rd.resolve_target(self._b64('m2 and chain B and resi 2-4'))
        data = self._target_payload()
        self.assertEqual(data['object'], 'm2')
        self.assertEqual(data['error'], '')

    def testResolveTargetTakesTheFirstOfSeveralObjects(self):
        self._two()
        from pymol import raymol_design as rd
        rd.resolve_target(self._b64('polymer'))
        data = self._target_payload()
        # Design only ever works on ONE structure, so a multi-object expression
        # resolves rather than failing — and reports that it narrowed.
        self.assertEqual(data['object'], 'm1')
        self.assertEqual(data['n_objects'], 2)

    def testResolveTargetReportsAnExpressionThatMatchesNothing(self):
        self._two()
        from pymol import raymol_design as rd
        rd.resolve_target(self._b64('resi 900-999'))
        data = self._target_payload()
        self.assertEqual(data['object'], '')

    def testResolveTargetReportsAnInvalidSelector(self):
        self._two()
        from pymol import raymol_design as rd
        rd.resolve_target(self._b64('chain (('))
        data = self._target_payload()
        self.assertEqual(data['object'], '')
        self.assertTrue(data['error'], 'a rejected selector must say why')

    # ── select_region ──────────────────────────────────────────────────────────

    def testSelectRegionPointsSeleAtTheExpression(self):
        self._two()
        from pymol import raymol_design as rd
        rd.select_region(self._b64('m1 and resi 2+4'))
        data = self._select_payload()
        self.assertTrue(data['ok'])
        self.assertEqual(data['count'], cmd.count_atoms('m1 and resi 2+4'))
        # 'sele' IS the region: the whole point is that the field feeds the same
        # selection a click builds.
        self.assertEqual(cmd.count_atoms('sele'), data['count'])

    def testSelectRegionReplacesAnEarlierSelection(self):
        self._two()
        from pymol import raymol_design as rd
        cmd.select('sele', 'm1 and resi 1')
        rd.select_region(self._b64('m1 and resi 3+4'))
        self.assertEqual(cmd.count_atoms('sele and resi 1'), 0)
        self.assertEqual(cmd.count_atoms('sele'),
                         cmd.count_atoms('m1 and resi 3+4'))

    def testSelectRegionReportsAnEmptyMatch(self):
        self._two()
        from pymol import raymol_design as rd
        rd.select_region(self._b64('m1 and resi 900'))
        data = self._select_payload()
        self.assertTrue(data['ok'], 'valid syntax, no atoms — that is not an error')
        self.assertEqual(data['count'], 0)

    def testSelectRegionReportsAnInvalidSelector(self):
        self._two()
        from pymol import raymol_design as rd
        cmd.select('sele', 'm1 and resi 1')
        rd.select_region(self._b64('chain (('))
        data = self._select_payload()
        self.assertFalse(data['ok'])
        self.assertEqual(cmd.count_atoms('sele'), cmd.count_atoms('m1 and resi 1'),
                         'a rejected selector must leave the live selection alone')

    def testSelectRegionSurvivesQuotesInTheExpression(self):
        self._two()
        from pymol import raymol_design as rd
        # Quotes are legal PyMOL and would end a Python string literal; base64 is
        # why they reach the selector intact.
        rd.select_region(self._b64('m1 and chain "A"'))
        data = self._select_payload()
        self.assertTrue(data['ok'])
        self.assertEqual(data['count'], cmd.count_atoms('m1 and chain A'))


class TestDesignClickSelectionLevel(testing.PyMOLTestCase):
    """A Design-mode click means what a click means everywhere else.

    'sele' IS the design region, so what a click puts in 'sele' has to obey the
    same `mouse_selection_mode` the rest of the app obeys: in chain mode a click
    designates the chain, not the one residue under the pointer. Design used to
    force residue scope at every level, which left the region saying "one residue"
    while the mode said "chains" and the viewport drew the whole chain pink.

    The expansion is re-derived from (obj, chain, resi) rather than taken from
    metal_pick._mode_expr, because the design pick payload carries no atom name --
    and the by* selection keywords need none.
    """

    def setUp(self):
        super(TestDesignClickSelectionLevel, self).setUp()
        # Never leak a non-default level: every later test in this interpreter
        # would inherit it, and a click would silently mean something else.
        self.addCleanup(cmd.set, 'mouse_selection_mode', 1)

    def _two_chains(self):
        """One object, chain A = resi 1-3, chain B = resi 4-6."""
        cmd.reinitialize()
        cmd.fab('AAAAAA', 'm1')
        cmd.alter('m1 and resi 1-3', 'chain = "A"')
        cmd.alter('m1 and resi 4-6', 'chain = "B"')
        cmd.alter('m1 and resi 1-3', 'segi = "S1"')
        cmd.alter('m1 and resi 4-6', 'segi = "S2"')
        cmd.sort()
        return 'm1'

    def _resis(self, sel='(?sele)'):
        out = set()
        cmd.iterate('%s and polymer and guide' % sel, 'out.add(resi)', space={'out': out})
        return sorted(out, key=int)

    def testChainModeClickSelectsTheWholeChain(self):
        obj = self._two_chains()
        from pymol import raymol_design as rd
        cmd.set('mouse_selection_mode', 2)
        rd.toggle_sele_residue(obj, 'A', '2')
        self.assertEqual(self._resis(), ['1', '2', '3'])

    def testChainModeClickTogglesTheWholeChainOff(self):
        obj = self._two_chains()
        from pymol import raymol_design as rd
        cmd.set('mouse_selection_mode', 2)
        rd.toggle_sele_residue(obj, 'A', '2')
        rd.toggle_sele_residue(obj, 'A', '3')   # same chain, different residue
        self.assertEqual(self._resis(), [],
                         'a second click at chain level clears the chain it added')

    def testChainModeLeavesTheOtherChainAlone(self):
        obj = self._two_chains()
        from pymol import raymol_design as rd
        cmd.set('mouse_selection_mode', 2)
        rd.toggle_sele_residue(obj, 'B', '5')
        self.assertEqual(self._resis(), ['4', '5', '6'])

    def testSegmentModeClickSelectsTheSegment(self):
        obj = self._two_chains()
        from pymol import raymol_design as rd
        cmd.set('mouse_selection_mode', 3)
        rd.toggle_sele_residue(obj, 'B', '5')
        self.assertEqual(self._resis(), ['4', '5', '6'])

    def testObjectModeClickSelectsTheWholeObjectAndNothingElse(self):
        obj = self._two_chains()
        cmd.fab('GGG', 'other')
        from pymol import raymol_design as rd
        cmd.set('mouse_selection_mode', 4)
        rd.toggle_sele_residue(obj, 'A', '2')
        self.assertEqual(self._resis(), ['1', '2', '3', '4', '5', '6'])
        self.assertEqual(cmd.count_atoms('other and (?sele)'), 0,
                         'object level means THAT object, not every object')

    def testMoleculeModeClickSelectsTheConnectedMolecule(self):
        obj = self._two_chains()
        from pymol import raymol_design as rd
        cmd.set('mouse_selection_mode', 5)
        rd.toggle_sele_residue(obj, 'A', '2')
        # cmd.fab builds one continuous peptide, so the molecule is all six
        # residues even though they were relabelled into two chains.
        self.assertEqual(self._resis(), ['1', '2', '3', '4', '5', '6'])

    def testTheRegionArmsWithEveryDesignableResidueOfTheChain(self):
        # The user-visible outcome: the read the UI performs reports the whole
        # chain, so Redesign says "3 res" rather than "1 res".
        obj = self._two_chains()
        from pymol import raymol_design as rd
        cmd.set('mouse_selection_mode', 2)
        rd.toggle_sele_residue(obj, 'A', '2')
        rd.sele_design_indices(obj, 1)
        with open(os.path.join(tempfile.gettempdir(),
                               'raymol_design_sele.json')) as f:
            data = json.load(f)
        self.assertEqual(data['indices'], [0, 1, 2])
        self.assertEqual(data['n_off'], 0)

    def testSetSeleResidueHonoursTheSelectionLevel(self):
        # The refocus path (a click on a DIFFERENT structure) replaces 'sele'
        # rather than toggling, and must replace it with the same scope.
        obj = self._two_chains()
        from pymol import raymol_design as rd
        cmd.select('sele', '%s and resi 5' % obj)
        cmd.set('mouse_selection_mode', 2)
        rd.set_sele_residue(obj, 'A', '2')
        self.assertEqual(self._resis(), ['1', '2', '3'],
                         'the replacement is chain-scoped, and drops the old resi 5')

    def testChainModeClickInAnEditSessionReachesBothCopies(self):
        # Same invariant the residue-scoped toggle has: the write must resolve in
        # the scope the read uses, or a region member cannot be removed once an
        # edit session repoints the focus at the working copy.
        obj = self._two_chains()
        cmd.create('m1_design', obj, zoom=0)
        from pymol import raymol_design as rd
        cmd.set('mouse_selection_mode', 2)
        rd.toggle_sele_residue('m1_design', 'A', '2', src=obj)
        self.assertEqual(self._resis('(m1_design and (?sele))'), ['1', '2', '3'])
        self.assertEqual(self._resis('(m1 and (?sele))'), ['1', '2', '3'],
                         'the original carries the same membership, by residue identity')
