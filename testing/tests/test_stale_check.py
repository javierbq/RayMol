"""Unit tests for testing/stale_check.py — headless, no PyMOL required.

stale_check guards against the runner silently testing an OLD installed copy of
the Python layer (see the module docstring). These tests pin the comparison
semantics: content drift is stale, absence is missing, a symlinked/editable
install is up to date, and files the source doesn't own are none of our
business.
"""

import importlib.util
import os
import sys
import tempfile
import unittest

_STALE_CHECK = os.path.join(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))), "stale_check.py")
_spec = importlib.util.spec_from_file_location("raymol_stale_check", _STALE_CHECK)
sc = importlib.util.module_from_spec(_spec)
sys.modules["raymol_stale_check"] = sc
_spec.loader.exec_module(sc)


def _write(dirname, name, text):
    path = os.path.join(dirname, name)
    with open(path, "w") as handle:
        handle.write(text)
    return path


class ComparePythonLayerTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.src = os.path.join(self._tmp.name, "src")
        self.dst = os.path.join(self._tmp.name, "dst")
        os.makedirs(self.src)
        os.makedirs(self.dst)
        self.addCleanup(self._tmp.cleanup)

    def test_identical_layer_is_clean(self):
        _write(self.src, "a.py", "x = 1\n")
        _write(self.dst, "a.py", "x = 1\n")
        self.assertEqual(sc.compare_python_layer(self.src, self.dst), ([], []))

    def test_content_drift_is_stale(self):
        _write(self.src, "a.py", "x = 2\n")   # checkout moved on
        _write(self.dst, "a.py", "x = 1\n")   # installed copy is old
        self.assertEqual(sc.compare_python_layer(self.src, self.dst),
                         (["a.py"], []))

    def test_same_size_different_bytes_is_stale(self):
        # Guards against a shallow (size/mtime-only) comparison.
        _write(self.src, "a.py", "x = 1\n")
        _write(self.dst, "a.py", "x = 9\n")
        self.assertEqual(sc.compare_python_layer(self.src, self.dst),
                         (["a.py"], []))

    def test_absent_from_install_is_missing(self):
        _write(self.src, "new_module.py", "x = 1\n")
        self.assertEqual(sc.compare_python_layer(self.src, self.dst),
                         ([], ["new_module.py"]))

    def test_symlinked_install_is_up_to_date(self):
        # The documented dev fix: site-packages symlinked at the checkout.
        src = _write(self.src, "a.py", "x = 1\n")
        os.symlink(src, os.path.join(self.dst, "a.py"))
        self.assertEqual(sc.compare_python_layer(self.src, self.dst), ([], []))

    def test_extra_installed_file_is_ignored(self):
        # Vanilla-PyMOL modules the fork doesn't ship are not our business.
        _write(self.dst, "only_installed.py", "x = 1\n")
        self.assertEqual(sc.compare_python_layer(self.src, self.dst), ([], []))

    def test_non_python_files_ignored(self):
        _write(self.src, "notes.txt", "hello\n")
        self.assertEqual(sc.compare_python_layer(self.src, self.dst), ([], []))

    def test_results_are_sorted_and_partitioned(self):
        for name in ("b.py", "a.py"):
            _write(self.src, name, "new\n")
            _write(self.dst, name, "old\n")
        for name in ("z.py", "c.py"):
            _write(self.src, name, "new\n")
        self.assertEqual(sc.compare_python_layer(self.src, self.dst),
                         (["a.py", "b.py"], ["c.py", "z.py"]))

    def test_missing_source_dir_is_clean(self):
        # Not running from a source checkout (installed pymol only) — no noise.
        self.assertEqual(
            sc.compare_python_layer(os.path.join(self._tmp.name, "nope"),
                                    self.dst), ([], []))

    def test_unreadable_file_does_not_raise(self):
        path = _write(self.src, "a.py", "x = 1\n")
        _write(self.dst, "a.py", "x = 1\n")
        os.chmod(path, 0o000)
        self.addCleanup(os.chmod, path, 0o644)
        if os.access(path, os.R_OK):
            self.skipTest("running as root; cannot make a file unreadable")
        # Must degrade to a report, never crash the whole test run.
        stale, missing = sc.compare_python_layer(self.src, self.dst)
        self.assertEqual(missing, [])


class FormatWarningTest(unittest.TestCase):
    def test_clean_layer_returns_none(self):
        self.assertIsNone(sc.format_warning([], [], "/src", "/dst"))

    def test_warning_names_files_and_dirs(self):
        text = sc.format_warning(["appkit_theme_preview.py"], ["metal_move.py"],
                                 "/repo/modules/pymol", "/sp/pymol")
        self.assertIn("appkit_theme_preview.py", text)
        self.assertIn("metal_move.py", text)
        self.assertIn("/repo/modules/pymol", text)
        self.assertIn("/sp/pymol", text)

    def test_warning_states_counts_and_offers_a_fix(self):
        text = sc.format_warning(["a.py", "b.py"], ["c.py"], "/src", "/dst")
        self.assertIn("2 stale", text)
        self.assertIn("1 missing", text)
        # Must be actionable, not just alarming.
        self.assertIn("ln -sfn", text)

    def test_long_lists_are_truncated(self):
        many = ["mod%02d.py" % i for i in range(40)]
        text = sc.format_warning(many, [], "/src", "/dst")
        self.assertIn("40 stale", text)
        self.assertLess(len(text.splitlines()), 30)
        self.assertIn("more", text)


if __name__ == "__main__":
    unittest.main()
