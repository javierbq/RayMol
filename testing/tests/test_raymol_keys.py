"""Unit tests for pymol.raymol_keys — headless, no PyMOL core required.

Covers the shadow-warning audit (RayMol#258): when a user's ~/.raymolrc binds a
key that RayMol also uses as a menu shortcut, the user is told once rather than
left wondering why the menu item stopped responding to its key.

Only ⌃M and ⌃D can collide: every other RayMol menu shortcut carries ⌘, and the
classifier passes ⌘ events straight through to the menus.
"""

import os
import sys
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

from pymol import raymol_keys


class FakeCmd:
    """Just enough cmd surface for the audit: the key_mappings dict."""

    def __init__(self, mappings=None):
        self.key_mappings = dict(mappings or {})


class AuditShadowedTests(unittest.TestCase):

    def test_no_bindings_no_warnings(self):
        self.assertEqual(raymol_keys.audit_shadowed(_self=FakeCmd()), [])

    def test_unrelated_bindings_no_warnings(self):
        fake = FakeCmd({"CTRL-T": "bond;unpick", "left": "_ backward", "F1": "ray"})
        self.assertEqual(raymol_keys.audit_shadowed(_self=fake), [])

    def test_warns_for_shadowed_move_shortcut(self):
        fake = FakeCmd({"CTRL-M": "zoom"})
        lines = raymol_keys.audit_shadowed(_self=fake)
        self.assertEqual(len(lines), 1)
        self.assertIn("CTRL-M", lines[0])
        self.assertIn("Move Objects", lines[0])

    def test_design_warning_only_in_design_builds(self):
        fake = FakeCmd({"CTRL-D": "turn x, 5"})
        # Non-MPNN build: there is no Design menu item, so nothing is shadowed.
        self.assertEqual(raymol_keys.audit_shadowed(has_design=False, _self=fake), [])
        lines = raymol_keys.audit_shadowed(has_design=True, _self=fake)
        self.assertEqual(len(lines), 1)
        self.assertIn("CTRL-D", lines[0])
        self.assertIn("Design", lines[0])

    def test_warns_once_per_shadowed_key(self):
        fake = FakeCmd({"CTRL-M": "zoom", "CTRL-D": "turn x, 5"})
        lines = raymol_keys.audit_shadowed(has_design=True, _self=fake)
        self.assertEqual(len(lines), 2)

    def test_empty_binding_is_not_a_shadow(self):
        # cmd.set_key(key, '') is how a binding is CLEARED; it shadows nothing.
        fake = FakeCmd({"CTRL-M": ""})
        self.assertEqual(raymol_keys.audit_shadowed(_self=fake), [])

    def test_missing_key_mappings_is_harmless(self):
        self.assertEqual(raymol_keys.audit_shadowed(_self=object()), [])


if __name__ == "__main__":
    unittest.main()
