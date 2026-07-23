"""Tests for pymol.raymol_design snapshot/dim/restore functions.

Runs via the repo test runner:
    pymol -ckqy testing/testing.py --run tests/raymol/design_saverestore.py
"""
from pymol import cmd, testing

_TSET = ['cartoon_transparency', 'transparency', 'stick_transparency', 'sphere_transparency']


class TestDesignSaveRestore(testing.PyMOLTestCase):
    def testColorAndTransparencyRestoredExactly(self):
        cmd.reinitialize()
        cmd.fragment('ala', 'm1')
        cmd.fragment('gly', 'm2')
        cmd.color('red', 'm1')
        cmd.color('green', 'm2')
        before1 = []
        cmd.iterate('m1', 'before1.append(color)', space={'before1': before1})
        from pymol import raymol_design
        result = raymol_design.snapshot_visual_state('m1,m2')
        self.assertEqual(result, 'DESIGN_SNAP:ok')
        result = raymol_design.dim_object('m2', 'gray70', 0.7)
        self.assertEqual(result, 'DESIGN_DIM:ok')
        cmd.color('blue', 'm1')  # recolor m1 (as if scored)
        result = raymol_design.restore_visual_state()
        self.assertEqual(result, 'DESIGN_RESTORE:ok')
        after1 = []
        cmd.iterate('m1', 'after1.append(color)', space={'after1': after1})
        # Exact per-atom color restore for m1.
        self.assertEqual(before1, after1)
        # Transparency on m2 restored to original (0.0).
        self.assertAlmostEqual(
            cmd.get_setting_float('transparency', 'm2'), 0.0, places=5
        )
        # Verify m2 colors are also restored (were green before dim).
        before2 = []
        cmd.color('green', 'm2')  # re-apply green to get reference values
        cmd.reinitialize()
        cmd.fragment('ala', 'm1')
        cmd.fragment('gly', 'm2')
        cmd.color('red', 'm1')
        cmd.color('green', 'm2')
        before2_ref = []
        cmd.iterate('m2', 'before2_ref.append(color)', space={'before2_ref': before2_ref})
        raymol_design.snapshot_visual_state('m1,m2')
        raymol_design.dim_object('m2', 'gray70', 0.7)
        cmd.color('blue', 'm1')
        raymol_design.restore_visual_state()
        after2 = []
        cmd.iterate('m2', 'after2.append(color)', space={'after2': after2})
        self.assertEqual(before2_ref, after2)
        # Transparency for both objects restored.
        self.assertAlmostEqual(
            cmd.get_setting_float('transparency', 'm1'), 0.0, places=5
        )
        self.assertAlmostEqual(
            cmd.get_setting_float('transparency', 'm2'), 0.0, places=5
        )
        # No leftover custom properties (our JSON mechanism uses no p.* props).
        # On open-source PyMOL p.all raises IncentiveOnlyException; skip in that case.
        try:
            leftover = []
            cmd.iterate(
                'm1',
                'leftover.append(1 if "_design_savedcolor" in (p.all or {}) else 0)',
                space={'leftover': leftover},
            )
            self.assertEqual(sum(leftover), 0)
        except Exception as e:
            if 'IncentiveOnly' not in type(e).__name__ and 'incentive' not in str(e).lower():
                raise
            # Open-source build: p.all unavailable → no incentive properties set, pass.
