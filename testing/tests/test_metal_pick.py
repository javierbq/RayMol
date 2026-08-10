"""Unit tests for pymol.metal_pick — headless, no PyMOL required.

Tests the NDC-to-world coordinate math with known view matrices.
"""

import math
import os
import sys
import types
import unittest
from unittest.mock import MagicMock, patch

# ---------------------------------------------------------------------------
# Bootstrap pymol package stub
# ---------------------------------------------------------------------------

_MODULES_DIR = os.path.join(
    os.path.dirname(__file__), os.pardir, os.pardir, "modules"
)
_MODULES_DIR = os.path.normpath(_MODULES_DIR)

if "pymol" not in sys.modules or not hasattr(sys.modules["pymol"], "__path__"):
    _pymol_stub = types.ModuleType("pymol")
    _pymol_stub.__path__ = [os.path.join(_MODULES_DIR, "pymol")]
    _pymol_stub.__package__ = "pymol"
    sys.modules["pymol"] = _pymol_stub


def _ndc_to_world(ndc_x, ndc_y, aspect, view, fov):
    """Reproduce the NDC-to-world math from metal_pick.pick_at().

    Extracted here so we can test the math independently of cmd.
    """
    R = [
        [view[0], view[1], view[2]],
        [view[3], view[4], view[5]],
        [view[6], view[7], view[8]],
    ]
    tx, ty, tz = view[9], view[10], view[11]
    ox, oy, oz = view[12], view[13], view[14]

    dist = abs(tz)
    half_h = dist * math.tan(math.radians(fov / 2.0))
    half_w = half_h * aspect

    px = ndc_x * half_w - tx
    py = ndc_y * half_h - ty
    pz = 0.0

    wx = R[0][0] * px + R[1][0] * py + R[2][0] * pz + ox
    wy = R[0][1] * px + R[1][1] * py + R[2][1] * pz + oy
    wz = R[0][2] * px + R[1][2] * py + R[2][2] * pz + oz

    return (wx, wy, wz)


class TestNDCToWorldMath(unittest.TestCase):
    """Test the NDC-to-world coordinate transformation."""

    def _identity_view(self, tx=0.0, ty=0.0, tz=-50.0, ox=0.0, oy=0.0, oz=0.0):
        """Build an 18-float view tuple with identity rotation."""
        return (
            1.0, 0.0, 0.0,   # rotation row 0
            0.0, 1.0, 0.0,   # rotation row 1
            0.0, 0.0, 1.0,   # rotation row 2
            tx,  ty,  tz,    # translation
            ox,  oy,  oz,    # origin
            0.0, 0.0, 0.0,   # clipping/fog (unused)
        )

    def test_center_click_identity(self):
        """NDC (0,0) with identity rotation and no translation offset -> origin."""
        view = self._identity_view(tx=0.0, ty=0.0, tz=-50.0, ox=10.0, oy=20.0, oz=30.0)
        fov = 30.0
        wx, wy, wz = _ndc_to_world(0.0, 0.0, 1.0, view, fov)
        self.assertAlmostEqual(wx, 10.0)
        self.assertAlmostEqual(wy, 20.0)
        self.assertAlmostEqual(wz, 30.0)

    def test_off_center_click(self):
        """NDC (1,0) with identity rotation should shift in x by half_w."""
        view = self._identity_view(tx=0.0, ty=0.0, tz=-50.0, ox=0.0, oy=0.0, oz=0.0)
        fov = 30.0
        dist = 50.0
        half_h = dist * math.tan(math.radians(fov / 2.0))
        half_w = half_h * 1.5  # aspect = 1.5

        wx, wy, wz = _ndc_to_world(1.0, 0.0, 1.5, view, fov)
        self.assertAlmostEqual(wx, half_w, places=6)
        self.assertAlmostEqual(wy, 0.0, places=6)
        self.assertAlmostEqual(wz, 0.0, places=6)

    def test_translation_offset(self):
        """Translation (tx, ty) shifts the world position."""
        view = self._identity_view(tx=5.0, ty=-3.0, tz=-50.0, ox=0.0, oy=0.0, oz=0.0)
        fov = 30.0
        wx, wy, wz = _ndc_to_world(0.0, 0.0, 1.0, view, fov)
        self.assertAlmostEqual(wx, -5.0)
        self.assertAlmostEqual(wy, 3.0)

    def test_90_degree_rotation(self):
        """90-degree rotation about z-axis swaps x and y."""
        view = (
            0.0, -1.0, 0.0,   # row 0
            1.0,  0.0, 0.0,   # row 1
            0.0,  0.0, 1.0,   # row 2
            0.0,  0.0, -50.0, # translation
            0.0,  0.0, 0.0,   # origin
            0.0,  0.0, 0.0,   # clipping
        )
        fov = 30.0
        dist = 50.0
        half_h = dist * math.tan(math.radians(fov / 2.0))

        wx, wy, wz = _ndc_to_world(1.0, 0.0, 1.0, view, fov)
        # R[0][0]*px + R[1][0]*py = 0*half_h + 1*0 = 0
        # R[0][1]*px + R[1][1]*py = -1*half_h + 0*0 = -half_h
        self.assertAlmostEqual(wx, 0.0, places=6)
        self.assertAlmostEqual(wy, -half_h, places=6)
        self.assertAlmostEqual(wz, 0.0, places=6)

    def test_aspect_ratio_effect(self):
        """Different aspect ratios scale x differently."""
        view = self._identity_view(tx=0.0, ty=0.0, tz=-50.0)
        fov = 30.0

        wx1, _, _ = _ndc_to_world(1.0, 0.0, 1.0, view, fov)
        wx2, _, _ = _ndc_to_world(1.0, 0.0, 2.0, view, fov)
        self.assertAlmostEqual(wx2, 2.0 * wx1, places=6)

    def test_fov_effect(self):
        """Larger FOV produces larger half_h/half_w."""
        view = self._identity_view(tx=0.0, ty=0.0, tz=-50.0)

        wx_small, _, _ = _ndc_to_world(1.0, 0.0, 1.0, view, 15.0)
        wx_large, _, _ = _ndc_to_world(1.0, 0.0, 1.0, view, 60.0)
        self.assertGreater(abs(wx_large), abs(wx_small))

    def test_negative_ndc(self):
        """Negative NDC coordinates produce negative world offsets."""
        view = self._identity_view(tx=0.0, ty=0.0, tz=-50.0)
        fov = 30.0
        wx, wy, _ = _ndc_to_world(-1.0, -1.0, 1.0, view, fov)
        self.assertLess(wx, 0.0)
        self.assertLess(wy, 0.0)


class TestPickAtIntegration(unittest.TestCase):
    """Test pick_at() with a fully mocked cmd module."""

    def setUp(self):
        # Swapping pymol.cmd for a MagicMock is process-global: it outlives this
        # file and breaks any later test that builds a real pymol2.PyMOL() (its
        # Cmd ctor walks pymol.completing, which needs the genuine submodules).
        # Snapshot every name we clobber and restore it, present or absent.
        _pymol_mod = sys.modules["pymol"]
        _sentinel = object()
        _saved = [(_pymol_mod, "cmd", getattr(_pymol_mod, "cmd", _sentinel))]
        _saved += [(sys.modules, k, sys.modules.get(k, _sentinel))
                   for k in ("pymol.cmd", "pymol.metal_pick")]

        def _restore():
            for holder, key, val in _saved:
                if holder is sys.modules:
                    sys.modules.pop(key, None)
                    if val is not _sentinel:
                        sys.modules[key] = val
                elif val is _sentinel:
                    delattr(holder, key)
                else:
                    setattr(holder, key, val)

        self.addCleanup(_restore)

    def test_pick_at_creates_selection(self):
        mock_cmd = MagicMock()
        mock_cmd.get_view.return_value = (
            1.0, 0.0, 0.0,
            0.0, 1.0, 0.0,
            0.0, 0.0, 1.0,
            0.0, 0.0, -50.0,
            10.0, 20.0, 30.0,
            0.0, 0.0, 0.0,
        )
        mock_cmd.get_setting_float.return_value = 30.0
        # _pick_atom skips non-molecule objects, so the picked object must report
        # as a molecule for the atom to be considered.
        mock_cmd.get_type.return_value = "object:molecule"

        mock_atom = MagicMock()
        mock_atom.coord = [10.0, 20.0, 30.0]   # at the rotation origin -> projects to (0,0) NDC
        mock_atom.chain = "A"
        mock_atom.resi = "42"
        mock_atom.resn = "ALA"
        mock_atom.name = "CA"
        mock_atom.segi = "A"

        mock_model = MagicMock()
        mock_model.atom = [mock_atom]
        mock_cmd.get_model.return_value = mock_model
        # 'objects' enumeration yields the molecule; 'selections' starts empty so
        # the click takes the additive branch that (re)creates 'sele'.
        mock_cmd.get_names.side_effect = \
            lambda kind, **kw: ["protein"] if kind == "objects" else []

        # Patch pymol.cmd inside metal_pick
        _pymol_mod = sys.modules["pymol"]
        _pymol_mod.cmd = mock_cmd
        sys.modules["pymol.cmd"] = mock_cmd

        # Force re-import of metal_pick
        if "pymol.metal_pick" in sys.modules:
            del sys.modules["pymol.metal_pick"]
        from pymol.metal_pick import pick_at
        pick_at(0.0, 0.0, 1.0)

        # pick_at toggles the clicked residue into the named 'sele' (selection
        # indicators are rendered in C++, NOT via a pseudoatom marker) and enables
        # it. Default mouse_selection_mode is residue, so the expr is resi-scoped.
        mock_cmd.select.assert_called_once()
        sel_name, sel_expr = mock_cmd.select.call_args.args[:2]
        self.assertEqual(sel_name, "sele")
        self.assertIn("resi 42", sel_expr)
        self.assertIn("chain A", sel_expr)
        mock_cmd.enable.assert_called_with("sele")


if __name__ == "__main__":
    unittest.main()
