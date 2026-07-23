"""Tests for pymol.raymol_design.apply_design_coloring.

Runs via the repo test runner:
    pymol -ckqy testing/testing.py --run tests/raymol/design_color.py
"""
import json
import os
import tempfile

from pymol import cmd, testing


class TestDesignColor(testing.PyMOLTestCase):
    def testAppliesPropertyAndSpectrum(self):
        cmd.reinitialize()
        cmd.fragment('ala', 'm1')
        # Discover the guide atom's actual chain/resi (fragment defaults vary).
        guide_info = []
        cmd.iterate('m1 and guide', 'guide_info.append((chain, resi))',
                    space={'guide_info': guide_info})
        self.assertTrue(len(guide_info) > 0, "No guide atom found in fragment")
        chain, resi = guide_info[0]
        path = os.path.join(tempfile.gettempdir(), 'raymol_design_vals.json')
        json.dump([{'chain': chain, 'resi': resi, 'value': 0.5}], open(path, 'w'))
        from pymol import raymol_design
        out = raymol_design.apply_design_coloring('m1', path, 'blue_white_red', 0.0, 1.0)
        self.assertEqual(out, 'DESIGN_COLOR:ok')
        got = []
        # Incentive PyMOL stores in p.mpnn_conf; Open-Source falls back to b.
        try:
            cmd.iterate('m1 and guide', 'got.append(p.mpnn_conf)', space={'got': got})
        except Exception:
            cmd.iterate('m1 and guide', 'got.append(b)', space={'got': got})
        self.assertAlmostEqual(got[0], 0.5, places=5)

    def testUndimOnColoring(self):
        """apply_design_coloring resets a dimmed object's transparency to baseline.

        Reproduces the bug: focusing object A dims B (0.7 transparency), then
        focusing B re-colors it but left it at 0.7 transparent — now fixed.
        """
        cmd.reinitialize()
        cmd.fragment('ala', 'm1')
        from pymol import raymol_design
        # Snapshot baseline: transparency should be 0.0 for a fresh fragment.
        raymol_design.snapshot_visual_state('m1')
        # Dim the object (simulates focusAwait dimming non-focus objects).
        raymol_design.dim_object('m1', 'gray70', 0.7)
        dimmed_t = cmd.get_setting_float('transparency', 'm1')
        self.assertAlmostEqual(dimmed_t, 0.7, places=5,
                               msg="dim_object did not set transparency to 0.7")
        # Build a values JSON for the one guide residue.
        guide_info = []
        cmd.iterate('m1 and guide', 'guide_info.append((chain, resi))',
                    space={'guide_info': guide_info})
        self.assertTrue(guide_info, "No guide atom in fragment")
        chain, resi = guide_info[0]
        path = os.path.join(tempfile.gettempdir(), 'raymol_design_undim_vals.json')
        json.dump([{'chain': chain, 'resi': resi, 'value': 0.5}], open(path, 'w'))
        # apply_design_coloring must un-dim (restore transparency to baseline ~0).
        out = raymol_design.apply_design_coloring('m1', path, 'blue_white_red', 0.0, 1.0)
        self.assertEqual(out, 'DESIGN_COLOR:ok')
        restored_t = cmd.get_setting_float('transparency', 'm1')
        self.assertAlmostEqual(restored_t, 0.0, places=5,
                               msg="transparency not restored to baseline after coloring")
        restored_ct = cmd.get_setting_float('cartoon_transparency', 'm1')
        self.assertAlmostEqual(restored_ct, 0.0, places=5,
                               msg="cartoon_transparency not restored to baseline after coloring")

    def testMaskedResidueNeutral(self):
        """Masked residues (value=null) are excluded from spectrum; scored ones colored.

        Also verifies non-polymer / absent atoms keep their baseline b-factor since
        the spectrum selection is constrained to 'polymer and (scored chain/resi)'.
        """
        cmd.reinitialize()
        # Create a minimal 2-residue peptide via inline PDB so chain/resi are known.
        pdb_str = (
            "ATOM      1  N   ALA A   1       1.000   2.000   3.000  1.00  0.00           N\n"
            "ATOM      2  CA  ALA A   1       2.000   2.000   3.000  1.00  0.00           C\n"
            "ATOM      3  C   ALA A   1       3.000   2.000   3.000  1.00  0.00           C\n"
            "ATOM      4  O   ALA A   1       3.000   3.000   3.000  1.00  0.00           O\n"
            "ATOM      5  N   GLY A   2       4.000   2.000   3.000  1.00  0.00           N\n"
            "ATOM      6  CA  GLY A   2       5.000   2.000   3.000  1.00  0.00           C\n"
            "ATOM      7  C   GLY A   2       6.000   2.000   3.000  1.00  0.00           C\n"
            "ATOM      8  O   GLY A   2       6.000   3.000   3.000  1.00  0.00           O\n"
            "END\n"
        )
        cmd.read_pdbstr(pdb_str, 'm_ag')
        # Set all b-factors to a known baseline so we can detect unwanted changes.
        cmd.alter('m_ag', 'b = 0.0')
        # resi 1 is scored (0.5); resi 2 is masked (null — missing backbone).
        path = os.path.join(tempfile.gettempdir(), 'raymol_design_masked_vals.json')
        json.dump([
            {'chain': 'A', 'resi': '1', 'value': 0.5},
            {'chain': 'A', 'resi': '2', 'value': None},
        ], open(path, 'w'))
        from pymol import raymol_design
        out = raymol_design.apply_design_coloring('m_ag', path, 'blue_white_red', 0.0, 1.0)
        self.assertEqual(out, 'DESIGN_COLOR:ok')
        # Scored residue (resi 1) must have its per-atom value set to 0.5.
        scored_vals = []
        try:
            cmd.iterate('m_ag and resi 1 and name CA',
                        'scored_vals.append(p.mpnn_conf)',
                        space={'scored_vals': scored_vals})
        except Exception:
            # Open-Source PyMOL: p.* unavailable, use b-factor fallback.
            cmd.iterate('m_ag and resi 1 and name CA',
                        'scored_vals.append(b)',
                        space={'scored_vals': scored_vals})
        self.assertTrue(scored_vals, "No CA atom found for scored residue")
        self.assertAlmostEqual(scored_vals[0], 0.5, places=5,
                               msg="Scored residue value was not set correctly")
        # Masked residue (resi 2) b-factor must be unchanged (still 0.0), NOT the
        # -9999 sentinel that the old code would have written via the whole-object alter.
        masked_b = []
        cmd.iterate('m_ag and resi 2 and name CA', 'masked_b.append(b)',
                    space={'masked_b': masked_b})
        self.assertTrue(masked_b, "No CA atom found for masked residue")
        self.assertAlmostEqual(masked_b[0], 0.0, places=5,
                               msg="Masked residue b-factor should remain at baseline 0.0")
