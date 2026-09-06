import os, tempfile
from pymol import cmd, testing

# Note: in this PyMOL build, cmd.get_object_list('enabled src') uses implicit
# OR semantics (enabled UNION src), not AND/intersection.  The assertions below
# use cmd.get_object_list('enabled') directly so they correctly test whether a
# named object is in the enabled set, which is the intent from the brief.
# Additionally, cmd.fragment() assigns resi='2' (not '1') in this build, so
# the backbone-only test discovers the actual resi at runtime.

def _make(src):
    """Call make_working_copy and return the chosen dst name."""
    from pymol import raymol_design as rd
    result = rd.make_working_copy(src)
    assert result.startswith('DESIGN_WORK:'), result
    return result[len('DESIGN_WORK:'):]

class TestDesignEditing(testing.PyMOLTestCase):
    def testMakeAndDiscardWorkingCopy(self):
        from pymol import raymol_design as rd
        cmd.reinitialize(); cmd.fragment('ala', 'src')
        dst = _make('src')
        # I2: returned name is used (defaults to src_design when no collision)
        self.assertIn(dst, cmd.get_object_list())
        self.assertEqual(cmd.count_atoms('src'), cmd.count_atoms(dst))
        # original disabled, copy enabled
        self.assertNotIn('src', cmd.get_object_list('enabled'))
        rd.discard_working_copy('src', dst)
        self.assertNotIn(dst, cmd.get_object_list())
        self.assertIn('src', cmd.get_object_list('enabled'))

    def testMakeWorkingCopyUniqueName(self):
        """I2: re-editing after a Keep must not clobber the previously-kept copy."""
        from pymol import raymol_design as rd
        cmd.reinitialize()
        cmd.fragment('ala', 'src')
        # Simulate a "Keep" — the first working copy stays in the scene.
        dst1 = _make('src'); cmd.enable('src')   # re-enable src as Keep would
        # Start a second edit session; must choose a DIFFERENT name.
        dst2 = _make('src')
        self.assertNotEqual(dst1, dst2)
        self.assertIn(dst1, cmd.get_object_list())  # first copy untouched
        self.assertIn(dst2, cmd.get_object_list())  # second copy also present

    def testCompareToggle(self):
        from pymol import raymol_design as rd
        cmd.reinitialize(); cmd.fragment('ala', 'src'); dst = _make('src')
        rd.set_compare('src', True);  self.assertIn('src', cmd.get_object_list('enabled'))
        rd.set_compare('src', False); self.assertNotIn('src', cmd.get_object_list('enabled'))

    def testCompareGridAndReferenceColor(self):
        """set_compare side_by_side=False (overlap, default):
             grid_mode 0 + src enabled + src atoms greyed + transparency > 0.
           set_compare side_by_side=True (grid):
             grid_mode 1 + src enabled + src colors restored (not grey) + transparency 0.
           set_compare OFF:
             grid_mode 0 + src disabled + colors restored + transparency restored.
           reset_compare:
             grid_mode 0 + colors restored (no enable/disable side-effect).
        """
        from pymol import raymol_design as rd
        cmd.reinitialize()
        cmd.fragment('ala', 'src')
        cmd.fragment('ala', 'dst')
        # Capture baseline per-atom colors before any compare.
        baseline = {}
        cmd.iterate('src', 'baseline[index] = color', space={'baseline': baseline})
        self.assertTrue(baseline, "no atoms found on src")

        # --- compare ON, overlap mode (default: side_by_side=False) ---
        result_on = rd.set_compare('src', True, side_by_side=False)
        self.assertEqual(result_on, 'DESIGN_CMP:ok')
        self.assertEqual(cmd.get_setting_int('grid_mode'), 0,
                         "overlap mode must use grid_mode 0")
        self.assertIn('src', cmd.get_object_list('enabled'))
        after_grey = {}
        cmd.iterate('src', 'after_grey[index] = color', space={'after_grey': after_grey})
        self.assertNotEqual(baseline, after_grey,
                            "overlap mode did not change src atom colors to grey")
        ct = cmd.get_setting_float('cartoon_transparency', 'src')
        self.assertGreater(ct, 0,
                           "overlap mode did not set transparency > 0 on src")

        # --- switch to grid mode (side_by_side=True) without re-saving state ---
        result_grid = rd.set_compare('src', True, side_by_side=True)
        self.assertEqual(result_grid, 'DESIGN_CMP:ok')
        self.assertEqual(cmd.get_setting_int('grid_mode'), 1,
                         "grid mode must use grid_mode 1")
        self.assertIn('src', cmd.get_object_list('enabled'))
        restored_grid = {}
        cmd.iterate('src', 'restored_grid[index] = color',
                    space={'restored_grid': restored_grid})
        self.assertEqual(baseline, restored_grid,
                         "grid mode did not restore src colors (should un-grey)")
        ct2 = cmd.get_setting_float('cartoon_transparency', 'src')
        self.assertEqual(ct2, 0.0,
                         "grid mode did not set transparency to 0")

        # --- compare OFF ---
        result_off = rd.set_compare('src', False)
        self.assertEqual(result_off, 'DESIGN_CMP:ok')
        self.assertEqual(cmd.get_setting_int('grid_mode'), 0)
        self.assertNotIn('src', cmd.get_object_list('enabled'))
        restored_off = {}
        cmd.iterate('src', 'restored_off[index] = color',
                    space={'restored_off': restored_off})
        self.assertEqual(baseline, restored_off,
                         "colors not restored to baseline after set_compare(on=False)")

        # --- reset_compare: ON then reset (no enable/disable side-effect) ---
        rd.set_compare('src', True)                   # back on (overlap mode)
        result_reset = rd.reset_compare('src')
        self.assertEqual(result_reset, 'DESIGN_CMPRESET:ok')
        self.assertEqual(cmd.get_setting_int('grid_mode'), 0)
        reset_colors = {}
        cmd.iterate('src', 'reset_colors[index] = color',
                    space={'reset_colors': reset_colors})
        self.assertEqual(baseline, reset_colors,
                         "reset_compare did not restore src colors")
        # reset_compare must NOT disable src (no enable/disable side-effect).
        self.assertIn('src', cmd.get_object_list('enabled'),
                      "reset_compare incorrectly disabled src")

    def testShowAllSidechains(self):
        """show_all_sidechains on: sidechain sticks shown (count > 0).
        show_all_sidechains off: sidechain sticks hidden.
        """
        from pymol import raymol_design as rd
        cmd.reinitialize()
        # Use ARG (long sidechain) for a clear signal.
        cmd.fragment('arg', 'm')
        # Sticks off initially (cartoon only after fragment).
        side_sel = 'm and (sidechain or name CA)'
        before = cmd.count_atoms('%s and rep sticks' % side_sel)
        self.assertEqual(before, 0, "pre-condition: no sidechain sticks expected initially")

        result_on = rd.show_all_sidechains('m', True)
        self.assertEqual(result_on, 'DESIGN_SIDECHAINS:on')
        after_on = cmd.count_atoms('%s and rep sticks' % side_sel)
        self.assertGreater(after_on, 0,
                           "show_all_sidechains(on=True) did not add sidechain sticks")

        result_off = rd.show_all_sidechains('m', False)
        self.assertEqual(result_off, 'DESIGN_SIDECHAINS:off')
        after_off = cmd.count_atoms('%s and rep sticks' % side_sel)
        self.assertEqual(after_off, 0,
                         "show_all_sidechains(on=False) did not hide sidechain sticks")

    def testBackboneOnlyHidesSidechain(self):
        from pymol import raymol_design as rd
        cmd.reinitialize(); cmd.fragment('arg', 'm')     # ARG has a long sidechain
        cmd.show('sticks', 'm')
        before = cmd.count_atoms('m and rep sticks and sidechain')
        self.assertGreater(before, 0)
        # Discover actual resi assigned by cmd.fragment (build-dependent; '2' here)
        resis = []
        cmd.iterate('m and guide', 'resis.append(resi)', space={'resis': resis})
        actual_resi = resis[0]
        rd.set_residue_backbone_only('m', '', actual_resi, True)
        self.assertEqual(cmd.count_atoms('m and rep sticks and sidechain'), 0)

    def testMutateResidueDisplay(self):
        from pymol import raymol_design as rd
        cmd.reinitialize(); cmd.fragment('arg', 'm')   # ARG, long sidechain
        cmd.show('sticks', 'm')
        gi = []; cmd.iterate('m and guide', 'gi.append((chain, resi))', space={'gi': gi})
        chain, resi = gi[0]
        # mutate to LEU (MPNN index 9)
        result = rd.mutate_residue_display('m', chain, resi, 9)
        self.assertEqual(result, 'DESIGN_MUTDISP:ok')
        # verify resn changed to LEU via get_model (avoids iterate name-shadowing)
        m = cmd.get_model('m and guide')
        self.assertEqual(m.atom[0].resn, 'LEU')
        # stale sidechain hidden (backbone only: N, CA, C, O kept)
        self.assertEqual(cmd.count_atoms('m and rep sticks and not name N+CA+C+O'), 0)
        # idx >= 20 is a no-op
        noop = rd.mutate_residue_display('m', chain, resi, 20)
        self.assertIn('noop', noop)

    def testLoadRepacked(self):
        from pymol import raymol_design as rd
        cmd.reinitialize(); cmd.fragment('ala', 'obj')
        pdb = cmd.get_pdbstr('obj')
        self.assertEqual(rd.load_repacked('obj', pdb), 'DESIGN_REPACKED:ok')
        self.assertIn('obj', cmd.get_object_list())
        # a malformed PDB must not leak a temp object or raise into the caller
        before = set(cmd.get_object_list())
        try:
            rd.load_repacked('obj', 'not a pdb')
        except Exception:
            pass
        self.assertEqual(set(cmd.get_object_list()) - before, set(), "temp object leaked")

    def testSetPinnedIndicator(self):
        """set_pinned_indicator: set → 'sele' contains the residue's atoms; clear → 'sele' empty."""
        from pymol import raymol_design as rd
        cmd.reinitialize()
        cmd.fragment('arg', 'obj')   # ARG: long sidechain, clear signal
        # Discover actual chain and resi assigned by cmd.fragment (build-dependent).
        gi = []
        cmd.iterate('obj and guide', 'gi.append((chain, resi))', space={'gi': gi})
        chain, resi = gi[0]

        # Set pin → 'sele' must contain atoms from the pinned residue.
        result = rd.set_pinned_indicator('obj', chain, resi)
        self.assertEqual(result, 'DESIGN_PIN:ok')
        n = cmd.count_atoms('(sele) and obj and resi %s' % resi)
        self.assertGreater(n, 0,
                           "sele should contain the pinned residue's atoms after set_pinned_indicator")

        # Clear pin → 'sele' must be empty.
        result_clear = rd.set_pinned_indicator('obj', '', '')
        self.assertEqual(result_clear, 'DESIGN_PIN:ok')
        n_clear = cmd.count_atoms('(?sele) and obj')
        self.assertEqual(n_clear, 0,
                         "sele should be empty after clearing the pinned indicator")

    def testLoadRepackedChangesTopology(self):
        """Full topology replace: loading a TRP PDB into an ALA object must adopt the
        TRP atom set (incl. NE1 which is absent in ALA) and preserve the object name.
        This fails against the old cmd.update(matchmaker=1) path that only copies
        coordinates onto atoms that already exist by name — new atoms are ignored.
        """
        from pymol import raymol_design as rd
        cmd.reinitialize()
        cmd.fragment('ala', 'obj')   # ALA: 5 heavy atoms (N CA C O CB), no NE1
        cmd.fragment('trp', 't')     # TRP: 14 heavy atoms (incl. NE1 unique to TRP)
        pdb = cmd.get_pdbstr('t')
        result = rd.load_repacked('obj', pdb)
        self.assertEqual(result, 'DESIGN_REPACKED:ok')
        # Object name must be preserved.
        self.assertIn('obj', cmd.get_object_list())
        # Topology adopted: NE1 is present only in TRP, never in ALA.
        self.assertEqual(cmd.count_atoms('obj and name NE1'), 1,
                         "NE1 not found after topology replace — old ALA atom set retained")
        # Atom count must match the TRP source (both from same fragment, same build).
        trp_count = cmd.count_atoms('t')
        obj_count = cmd.count_atoms('obj')
        self.assertEqual(obj_count, trp_count,
                         "atom count after replace (%d) != TRP source (%d)" %
                         (obj_count, trp_count))

    def testProlineRingClosesInSidechainSticks(self):
        """Proline's ring must not be drawn open (#405).

        PRO closes its ring CD->N onto the *backbone* nitrogen, which PyMOL's
        `sidechain` selection excludes. Showing sidechain sticks without that N
        leaves the CD->N bond with only one drawn endpoint, so the ring renders
        as an open, dangling zig-zag. Every other residue is unaffected: their
        N's heavy neighbours are CA and the preceding C, neither a sidechain
        atom.
        """
        from pymol import raymol_design as rd
        cmd.reinitialize()
        cmd.fragment('pro', 'm')
        # Fragments arrive with representations already on, which would make the
        # assertions below pass without show_all_sidechains doing anything.
        cmd.hide('everything', 'm')

        rd.show_all_sidechains('m', True)

        shown = set()
        cmd.iterate('m and rep sticks', 'shown.add(name)', space={'shown': shown})
        # All five ring atoms, so all five ring bonds have both endpoints drawn.
        for atom in ('N', 'CA', 'CB', 'CG', 'CD'):
            self.assertIn(atom, shown,
                          "PRO ring atom %s missing from sidechain sticks: "
                          "the ring renders open (#405)" % atom)

        # ...and hiding takes the N back off, or it is orphaned on the backbone.
        rd.show_all_sidechains('m', False)
        self.assertEqual(cmd.count_atoms('m and name N and rep sticks'), 0,
                         "PRO backbone N left behind as a stick after hide")

    def testSidechainSticksAddNoBackboneNOutsideProline(self):
        """The proline fix must not drag backbone N into other residues (#405)."""
        from pymol import raymol_design as rd
        cmd.reinitialize()
        for frag in ('arg', 'gly', 'ala', 'trp'):
            cmd.delete('m')
            cmd.fragment(frag, 'm')
            cmd.hide('everything', 'm')
            rd.show_all_sidechains('m', True)
            self.assertEqual(
                cmd.count_atoms('m and name N and rep sticks'), 0,
                "%s: backbone N should not be in sidechain sticks" % frag.upper())

    def testSidechainSticksSkipHydrogenatedNTerminus(self):
        """Only PRO's N joins the sticks, even with hydrogens present (#405).

        `h_add` puts an extra amide H on the N-terminal nitrogen, and PyMOL
        classifies that H as *sidechain*. A neighbour test that does not exclude
        hydrogens therefore pulls residue 1's backbone N into the sticks of
        every hydrogenated structure.
        """
        from pymol import raymol_design as rd
        cmd.reinitialize()
        cmd.fab('AGPRA', 'pep')      # N-terminus, plus PRO at residue 3
        cmd.h_add('pep')
        cmd.hide('everything', 'pep')

        rd.show_all_sidechains('pep', True)

        got = set()
        cmd.iterate('pep and name N and rep sticks', 'got.add(resi)',
                    space={'got': got})
        self.assertEqual(got, {'3'},
                         "backbone N drawn outside PRO 3 (got residues %s): the "
                         "neighbour test is matching an amide hydrogen" % sorted(got))
