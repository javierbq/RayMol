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
