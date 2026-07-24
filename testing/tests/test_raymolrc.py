"""Unit tests for pymol.raymolrc — headless, no PyMOL GUI required.

Covers the ~/.raymolrc startup-script logic that the native macOS/iOS
embeddings drive (RayMol#225): migration_candidate() decides whether a
~/.pymolrc(.py) is offered for import, migrate() copies it, decline_migration()
records a skip so we don't re-ask, and load() runs whichever ~/.raymolrc(.py)
files exist (WITHOUT migrating). The GUI (SwiftUI .alert / AppKit NSAlert) is
only responsible for asking; all the file logic lives here and is tested here.

The module computes its paths from ~ at import time, so each test repoints
those module-level constants at a temp HOME.
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
# pymol.stored is what _seed_main_namespace copies into __main__; a real
# `pymol -ckqy` run already has it, so only stub it when absent.
if not hasattr(sys.modules["pymol"], "stored"):
    sys.modules["pymol"].stored = types.SimpleNamespace()

from pymol import raymolrc


class FakeCmd:
    """Records run()/do() calls so load() can be asserted without a real core."""

    def __init__(self):
        self.runs = []   # (filename, namespace)
        self.dos = []     # command strings

    def run(self, filename, namespace="global", _spawn=0, _self=None):
        self.runs.append((filename, namespace))

    def do(self, command):
        self.dos.append(command)


class RaymolrcTestCase(unittest.TestCase):
    def setUp(self):
        # Fresh temp HOME per test; repoint every module-level path at it so
        # tests never touch the real ~ and never see each other's files.
        self._tmp = tempfile.TemporaryDirectory()
        home = self._tmp.name
        self._saved = {
            k: getattr(raymolrc, k) for k in
            ("RAYMOLRC_PY", "RAYMOLRC_PML", "PYMOLRC_PY", "PYMOLRC_PML",
             "MIGRATION_SKIP_MARKER")
        }
        raymolrc.RAYMOLRC_PY = os.path.join(home, ".raymolrc.py")
        raymolrc.RAYMOLRC_PML = os.path.join(home, ".raymolrc")
        raymolrc.PYMOLRC_PY = os.path.join(home, ".pymolrc.py")
        raymolrc.PYMOLRC_PML = os.path.join(home, ".pymolrc")
        raymolrc.MIGRATION_SKIP_MARKER = os.path.join(home, ".raymolrc.skip")

    def tearDown(self):
        for k, v in self._saved.items():
            setattr(raymolrc, k, v)
        self._tmp.cleanup()

    def _write(self, path, text):
        with open(path, "w") as f:
            f.write(text)

    # --- migration_candidate -------------------------------------------------

    def test_candidate_none_when_nothing_present(self):
        self.assertIsNone(raymolrc.migration_candidate())

    def test_candidate_offers_pymolrc_py(self):
        self._write(raymolrc.PYMOLRC_PY, "print('x')")
        self.assertEqual(raymolrc.migration_candidate(), raymolrc.PYMOLRC_PY)

    def test_candidate_offers_pymolrc_pml_when_no_py(self):
        self._write(raymolrc.PYMOLRC_PML, "bg_color red")
        self.assertEqual(raymolrc.migration_candidate(), raymolrc.PYMOLRC_PML)

    def test_candidate_prefers_py_over_pml(self):
        self._write(raymolrc.PYMOLRC_PY, "print('x')")
        self._write(raymolrc.PYMOLRC_PML, "bg_color red")
        self.assertEqual(raymolrc.migration_candidate(), raymolrc.PYMOLRC_PY)

    def test_candidate_none_when_raymolrc_py_exists(self):
        self._write(raymolrc.PYMOLRC_PY, "print('x')")
        self._write(raymolrc.RAYMOLRC_PY, "print('already here')")
        self.assertIsNone(raymolrc.migration_candidate())

    def test_candidate_none_when_raymolrc_pml_exists(self):
        self._write(raymolrc.PYMOLRC_PY, "print('x')")
        self._write(raymolrc.RAYMOLRC_PML, "bg_color blue")
        self.assertIsNone(raymolrc.migration_candidate())

    def test_candidate_none_when_declined(self):
        self._write(raymolrc.PYMOLRC_PY, "print('x')")
        open(raymolrc.MIGRATION_SKIP_MARKER, "a").close()
        self.assertIsNone(raymolrc.migration_candidate())

    # --- migrate -------------------------------------------------------------

    def test_migrate_copies_py_to_raymolrc_py(self):
        self._write(raymolrc.PYMOLRC_PY, "cmd.set('bg_rgb', 'red')\n")
        raymolrc.migrate()
        self.assertTrue(os.path.exists(raymolrc.RAYMOLRC_PY))
        with open(raymolrc.RAYMOLRC_PY) as f:
            self.assertEqual(f.read(), "cmd.set('bg_rgb', 'red')\n")

    def test_migrate_copies_pml_to_raymolrc_pml(self):
        self._write(raymolrc.PYMOLRC_PML, "bg_color red\n")
        raymolrc.migrate()
        self.assertTrue(os.path.exists(raymolrc.RAYMOLRC_PML))
        self.assertFalse(os.path.exists(raymolrc.RAYMOLRC_PY))

    def test_migrate_noop_when_no_candidate(self):
        raymolrc.migrate()
        self.assertFalse(os.path.exists(raymolrc.RAYMOLRC_PY))
        self.assertFalse(os.path.exists(raymolrc.RAYMOLRC_PML))

    def test_migrate_does_not_clobber_existing_raymolrc(self):
        # An existing raymolrc means migration_candidate() is None, so migrate()
        # must leave the user's file untouched.
        self._write(raymolrc.PYMOLRC_PY, "cmd.set('bg_rgb', 'red')\n")
        self._write(raymolrc.RAYMOLRC_PY, "cmd.set('bg_rgb', 'blue')\n")
        raymolrc.migrate()
        with open(raymolrc.RAYMOLRC_PY) as f:
            self.assertEqual(f.read(), "cmd.set('bg_rgb', 'blue')\n")

    # --- decline_migration ---------------------------------------------------

    def test_decline_writes_skip_marker(self):
        self.assertFalse(os.path.exists(raymolrc.MIGRATION_SKIP_MARKER))
        raymolrc.decline_migration()
        self.assertTrue(os.path.exists(raymolrc.MIGRATION_SKIP_MARKER))

    def test_decline_then_no_candidate(self):
        self._write(raymolrc.PYMOLRC_PY, "print('x')")
        self.assertIsNotNone(raymolrc.migration_candidate())
        raymolrc.decline_migration()
        self.assertIsNone(raymolrc.migration_candidate())

    def test_decline_does_not_create_raymolrc(self):
        self._write(raymolrc.PYMOLRC_PY, "print('x')")
        raymolrc.decline_migration()
        self.assertFalse(os.path.exists(raymolrc.RAYMOLRC_PY))
        self.assertFalse(os.path.exists(raymolrc.RAYMOLRC_PML))

    # --- load ----------------------------------------------------------------

    def test_load_runs_raymolrc_py_in_main_namespace(self):
        self._write(raymolrc.RAYMOLRC_PY, "cmd.set('bg_rgb', 'red')\n")
        fake = FakeCmd()
        raymolrc.load(fake)
        self.assertEqual(fake.runs, [(raymolrc.RAYMOLRC_PY, "main")])

    def test_load_ats_raymolrc_pml(self):
        self._write(raymolrc.RAYMOLRC_PML, "bg_color red\n")
        fake = FakeCmd()
        raymolrc.load(fake)
        self.assertEqual(fake.dos, ["@" + raymolrc.RAYMOLRC_PML])

    def test_load_does_not_migrate(self):
        # load() is deliberately dumb: a ~/.pymolrc present but no ~/.raymolrc
        # must NOT be imported or executed (that decision belongs to the UI).
        self._write(raymolrc.PYMOLRC_PY, "cmd.set('bg_rgb', 'red')\n")
        fake = FakeCmd()
        raymolrc.load(fake)
        self.assertEqual(fake.runs, [])
        self.assertEqual(fake.dos, [])
        self.assertFalse(os.path.exists(raymolrc.RAYMOLRC_PY))

    def test_load_noop_when_nothing_present(self):
        fake = FakeCmd()
        raymolrc.load(fake)
        self.assertEqual(fake.runs, [])
        self.assertEqual(fake.dos, [])

    def test_load_seeds_main_namespace_with_cmd(self):
        # Migrated ~/.pymolrc scripts call bare cmd.xxx(); load() must seed
        # __main__ so that convention works in these embeddings.
        import __main__
        had_cmd = "cmd" in __main__.__dict__
        saved = __main__.__dict__.get("cmd")
        if had_cmd:
            del __main__.__dict__["cmd"]
        try:
            self._write(raymolrc.RAYMOLRC_PY, "cmd.bg_color('red')\n")
            fake = FakeCmd()
            raymolrc.load(fake)
            self.assertIs(__main__.__dict__.get("cmd"), fake)
        finally:
            if had_cmd:
                __main__.__dict__["cmd"] = saved
            else:
                __main__.__dict__.pop("cmd", None)

    # --- end-to-end sequence mirroring the GUI ------------------------------

    def test_import_flow(self):
        # User has ~/.pymolrc.py, taps "Import": migrate() then load().
        self._write(raymolrc.PYMOLRC_PY, "cmd.set('bg_rgb', 'red')\n")
        self.assertIsNotNone(raymolrc.migration_candidate())
        raymolrc.migrate()
        fake = FakeCmd()
        raymolrc.load(fake)
        self.assertTrue(os.path.exists(raymolrc.RAYMOLRC_PY))
        self.assertEqual(fake.runs, [(raymolrc.RAYMOLRC_PY, "main")])

    def test_decline_flow_and_no_reprompt(self):
        # User taps "Not Now": decline_migration() then load() (which no-ops).
        # A second launch must not re-offer.
        self._write(raymolrc.PYMOLRC_PY, "cmd.set('bg_rgb', 'red')\n")
        raymolrc.decline_migration()
        fake = FakeCmd()
        raymolrc.load(fake)
        self.assertFalse(os.path.exists(raymolrc.RAYMOLRC_PY))
        self.assertEqual(fake.runs, [])
        # Second launch: still nothing to offer.
        self.assertIsNone(raymolrc.migration_candidate())


if __name__ == "__main__":
    unittest.main()
