"""Unit tests for pymol.appkit_settings — headless, no PyMOL required.

Covers the searchable-settings catalog builder and single-setting writer:
catalog() enumerates (name, type, val), writes JSON to a temp file, and prints
SETTINGS:ready; set_value() writes one setting and echoes SETVAL:<name>=<val>.
`cmd` and `pymol.setting` are replaced with fakes after import.
"""

import io
import json
import os
import sys
import types
import unittest
from contextlib import redirect_stdout

_MODULES_DIR = os.path.normpath(
    os.path.join(os.path.dirname(__file__), os.pardir, os.pardir, "modules")
)
if "pymol" not in sys.modules or not hasattr(sys.modules["pymol"], "__path__"):
    _pymol_stub = types.ModuleType("pymol")
    _pymol_stub.__path__ = [os.path.join(_MODULES_DIR, "pymol")]
    _pymol_stub.__package__ = "pymol"
    sys.modules["pymol"] = _pymol_stub
# Only when absent (a real `pymol -ckqy` run already has these; don't clobber them).
if not hasattr(sys.modules["pymol"], "cmd"):
    sys.modules["pymol"].cmd = types.SimpleNamespace()
if not hasattr(sys.modules["pymol"], "setting"):
    sys.modules["pymol"].setting = types.SimpleNamespace()

from pymol import appkit_settings as st


class FakeSetting:
    def __init__(self, names):
        self._names = names

    def get_name_list(self):
        return self._names


class FakeCmd:
    def __init__(self, tuples=None, values=None, raise_on_set=False):
        # tuples: {name: (type_int, ...)}; values: {name: value}
        self._tuples = tuples or {}
        self._values = values or {}
        self._raise_on_set = raise_on_set
        self.sets = []

    def get_setting_tuple(self, name):
        return self._tuples[name]   # KeyError -> caught & skipped

    def get(self, name):
        return self._values.get(name)

    def set(self, name, value):
        if self._raise_on_set:
            raise RuntimeError("bad value")
        self.sets.append((name, value))
        self._values[name] = value


def _lines(buf):
    return buf.getvalue().splitlines()


def _load(path):
    with open(path) as f:
        return json.load(f)


class CatalogTest(unittest.TestCase):
    def test_catalog_writes_sorted_json_and_marker(self):
        st._setting = FakeSetting(["ray_trace_mode", "bg_rgb"])
        st.cmd = FakeCmd(
            tuples={"bg_rgb": (4,), "ray_trace_mode": (2,)},
            values={"bg_rgb": [0.0, 0.0, 0.0], "ray_trace_mode": 1},
        )
        buf = io.StringIO()
        with redirect_stdout(buf):
            st.catalog()
        self.assertIn("SETTINGS:ready", _lines(buf))
        data = _load(st._path())
        # Sorted by name: bg_rgb before ray_trace_mode.
        self.assertEqual([d["name"] for d in data], ["bg_rgb", "ray_trace_mode"])
        self.assertEqual(data[0]["type"], 4)
        self.assertEqual(data[1], {"name": "ray_trace_mode", "type": 2, "val": "1"})

    def test_catalog_skips_settings_that_error(self):
        st._setting = FakeSetting(["good", "bad"])
        st.cmd = FakeCmd(
            tuples={"good": (2,)},           # 'bad' missing -> KeyError -> skipped
            values={"good": 5, "bad": 9},
        )
        with redirect_stdout(io.StringIO()):
            st.catalog()
        names = [d["name"] for d in _load(st._path())]
        self.assertEqual(names, ["good"])

    def test_catalog_stringifies_none_value_as_empty(self):
        st._setting = FakeSetting(["x"])
        st.cmd = FakeCmd(tuples={"x": (6,)}, values={"x": None})
        with redirect_stdout(io.StringIO()):
            st.catalog()
        self.assertEqual(_load(st._path())[0]["val"], "")


class SetValueTest(unittest.TestCase):
    def test_set_value_writes_and_echoes(self):
        st.cmd = FakeCmd(values={})
        buf = io.StringIO()
        with redirect_stdout(buf):
            st.set_value("sphere_scale", 0.5)
        self.assertIn(("sphere_scale", 0.5), st.cmd.sets)
        self.assertIn("SETVAL:sphere_scale=0.5", _lines(buf))

    def test_set_value_error_emits_err_marker(self):
        st.cmd = FakeCmd(raise_on_set=True)
        buf = io.StringIO()
        with redirect_stdout(buf):
            st.set_value("sphere_scale", 0.5)
        self.assertTrue(any(l.startswith("SETTINGS:err") for l in _lines(buf)))

    def test_path_is_in_tempdir(self):
        import os
        import tempfile
        self.assertTrue(st._path().startswith(tempfile.gettempdir()))
        # pid-scoped (#399): a second RayMol on the same machine must not be
        # able to hand this instance its settings catalog.
        self.assertTrue(st._path().endswith(
            "pymol_settings_%d.json" % os.getpid()))


if __name__ == "__main__":
    unittest.main()
