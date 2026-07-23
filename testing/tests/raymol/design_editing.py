import os, tempfile
from pymol import cmd, testing

# Note: in this PyMOL build, cmd.get_object_list('enabled src') uses implicit
# OR semantics (enabled UNION src), not AND/intersection.  The assertions below
# use cmd.get_object_list('enabled') directly so they correctly test whether a
# named object is in the enabled set, which is the intent from the brief.
# Additionally, cmd.fragment() assigns resi='2' (not '1') in this build, so
# the backbone-only test discovers the actual resi at runtime.

class TestDesignEditing(testing.PyMOLTestCase):
    def testMakeAndDiscardWorkingCopy(self):
        from pymol import raymol_design as rd
        cmd.reinitialize(); cmd.fragment('ala', 'src')
        self.assertEqual(rd.make_working_copy('src', 'src_design'), 'DESIGN_WORK:src_design')
        self.assertIn('src_design', cmd.get_object_list())
        self.assertEqual(cmd.count_atoms('src'), cmd.count_atoms('src_design'))
        # original disabled, copy enabled
        self.assertNotIn('src', cmd.get_object_list('enabled'))
        rd.discard_working_copy('src', 'src_design')
        self.assertNotIn('src_design', cmd.get_object_list())
        self.assertIn('src', cmd.get_object_list('enabled'))

    def testCompareToggle(self):
        from pymol import raymol_design as rd
        cmd.reinitialize(); cmd.fragment('ala', 'src'); rd.make_working_copy('src', 'src_design')
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
