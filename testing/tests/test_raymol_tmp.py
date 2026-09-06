"""Unit tests for pymol.raymol_tmp — headless, no PyMOL required.

The tempfile channels are how Python hands the native app payloads too large for
PyMOL's ~1 KB feedback line. Two RayMol processes share $TMPDIR, so the ONE
property that matters is that every name carries this process's pid (issue
#399): without it, a dev build beside the installed app reads the other's
sequence rows, gizmo geometry or settings catalog.
"""

import os
import sys
import tempfile
import types
import unittest

_MODULES_DIR = os.path.normpath(
    os.path.join(os.path.dirname(__file__), os.pardir, os.pardir, "modules")
)
if "pymol" not in sys.modules or not hasattr(sys.modules["pymol"], "__path__"):
    _pymol_stub = types.ModuleType("pymol")
    _pymol_stub.__path__ = [os.path.join(_MODULES_DIR, "pymol")]
    _pymol_stub.__package__ = "pymol"
    sys.modules["pymol"] = _pymol_stub

from pymol import raymol_tmp


class ChannelPathTest(unittest.TestCase):
    def test_lives_in_tempdir(self):
        p = raymol_tmp.channel_path("pymol_seq")
        self.assertEqual(os.path.dirname(p), tempfile.gettempdir())

    def test_carries_this_pid(self):
        p = raymol_tmp.channel_path("pymol_seq")
        self.assertEqual(os.path.basename(p),
                         "pymol_seq_%d.json" % os.getpid())

    def test_extension_is_overridable(self):
        p = raymol_tmp.channel_path("_pymol_ray_overlay", "png")
        self.assertEqual(os.path.basename(p),
                         "_pymol_ray_overlay_%d.png" % os.getpid())

    def test_distinct_stems_do_not_collide(self):
        self.assertNotEqual(raymol_tmp.channel_path("pymol_seq"),
                            raymol_tmp.channel_path("pymol_seqsel"))


class ChannelWritersTest(unittest.TestCase):
    """Every module that writes a channel must route through channel_path, so
    none of them can drift back to a fixed name (which is what #399 was)."""

    _WRITERS = {
        "appkit_sequence.py": "pymol_seq",
        "appkit_settings.py": "pymol_settings",
        "appkit_ray_overlay.py": "_pymol_ray_overlay",
        "appkit_inspector.py": "pymol_objpanel",
        "appkit_predict.py": "pymol_predict",
        "appkit_design.py": "pymol_design",
        "metal_move.py": "pymol_gizmo",
        "metal_pick.py": "pymol_hover_info",
    }

    def test_no_writer_builds_a_fixed_channel_name(self):
        for name, stem in self._WRITERS.items():
            path = os.path.join(_MODULES_DIR, "pymol", name)
            with open(path) as f:
                src = f.read()
            self.assertIn("channel_path", src,
                          "%s must build its channel path via raymol_tmp" % name)
            self.assertNotIn("'%s.json'" % stem, src,
                             "%s still writes a fixed, pid-less name" % name)
            self.assertNotIn('"%s.json"' % stem, src,
                             "%s still writes a fixed, pid-less name" % name)


if __name__ == "__main__":
    unittest.main()
