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
