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
        """set_compare ON: grid_mode 1 + src enabled + src atoms greyed.
        set_compare OFF: grid_mode 0 + src disabled + colors restored.
        reset_compare: grid_mode 0 + colors restored (no enable/disable side-effect).
        """
        from pymol import raymol_design as rd
        cmd.reinitialize()
        cmd.fragment('ala', 'src')
        cmd.fragment('ala', 'dst')
        # Capture baseline per-atom colors before greying.
        baseline = {}
        cmd.iterate('src', 'baseline[index] = color', space={'baseline': baseline})
        self.assertTrue(baseline, "no atoms found on src")

        # --- compare ON ---
        result_on = rd.set_compare('src', True)
        self.assertEqual(result_on, 'DESIGN_CMP:ok')
        self.assertEqual(cmd.get_setting_int('grid_mode'), 1)
        self.assertIn('src', cmd.get_object_list('enabled'))
        after_grey = {}
        cmd.iterate('src', 'after_grey[index] = color', space={'after_grey': after_grey})
        # At least one atom must have had its color changed to grey70.
        self.assertNotEqual(baseline, after_grey,
                            "set_compare(on=True) did not change src atom colors to grey")

        # --- compare OFF ---
        result_off = rd.set_compare('src', False)
        self.assertEqual(result_off, 'DESIGN_CMP:ok')
        self.assertEqual(cmd.get_setting_int('grid_mode'), 0)
        self.assertNotIn('src', cmd.get_object_list('enabled'))
        restored = {}
        cmd.iterate('src', 'restored[index] = color', space={'restored': restored})
        self.assertEqual(baseline, restored,
                         "colors not restored to baseline after set_compare(on=False)")

        # --- reset_compare: ON then reset (no enable/disable changes) ---
        rd.set_compare('src', True)                      # back on
        result_reset = rd.reset_compare('src')
        self.assertEqual(result_reset, 'DESIGN_CMPRESET:ok')
        self.assertEqual(cmd.get_setting_int('grid_mode'), 0)
        # reset_compare must restore colors...
        reset_colors = {}
        cmd.iterate('src', 'reset_colors[index] = color', space={'reset_colors': reset_colors})
        self.assertEqual(baseline, reset_colors,
                         "reset_compare did not restore src colors")
        # ...but must NOT disable src (no enable/disable side-effect).
        self.assertIn('src', cmd.get_object_list('enabled'),
                      "reset_compare incorrectly disabled src")

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
