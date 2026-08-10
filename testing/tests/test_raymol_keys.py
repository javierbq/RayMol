"""Unit tests for pymol.raymol_keys — headless, no PyMOL core required.

Covers the shadow-warning audit (RayMol#258): when a user's ~/.raymolrc binds a
key that RayMol also uses as a menu shortcut, the user is told once rather than
left wondering why the menu item stopped responding to its key.

Only ⌃M and ⌃D can collide: every other RayMol menu shortcut carries ⌘, and the
classifier passes ⌘ events straight through to the menus.
"""

import contextlib
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


class ExplodingMappings(dict):
    """A dict that passes isinstance checks but raises on .get()."""
    def get(self, key, default=None):
        raise RuntimeError("boom")


class ExplodingStdout:
    """A stdout stand-in whose write() raises, to test the handler's inner guard."""
    def write(self, *a, **k):
        raise OSError("stdout closed")
    def flush(self, *a, **k):
        pass


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

    def test_internal_failure_degrades_to_no_warning(self):
        # A mapping that passes isinstance() but raises on .get() exercises the
        # outer except handler: the function must return [] without raising.
        fake = FakeCmd()
        fake.key_mappings = ExplodingMappings({"CTRL-M": "zoom"})
        self.assertEqual(raymol_keys.audit_shadowed(_self=fake), [])

    def test_reporting_print_failure_does_not_propagate(self):
        # Same explosion path, but stdout is also broken — exercises the nested
        # try/except inside the handler that guards the diagnostic print itself.
        fake = FakeCmd()
        fake.key_mappings = ExplodingMappings({"CTRL-M": "zoom"})
        with contextlib.redirect_stdout(ExplodingStdout()):
            self.assertEqual(raymol_keys.audit_shadowed(_self=fake), [])


if __name__ == "__main__":
    unittest.main()
