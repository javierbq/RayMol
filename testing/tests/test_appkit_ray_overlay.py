"""Unit tests for pymol.appkit_ray_overlay — headless, no PyMOL/AppKit.

Covers the overlay lifecycle logic that does not require a live window:
is_visible() state, hide() teardown, and the early-return guards of
show_ray_image() (no AppKit, png export failure, missing output file).
AppKit/objc/Foundation stubbed permissively before import.
"""

import importlib
import os
import sys
import types
import unittest
from unittest.mock import MagicMock


class _PermissiveModule(types.ModuleType):
    def __getattr__(self, name):
        mock = MagicMock(name="AppKit.%s" % name)
        setattr(self, name, mock)
        return mock


def _install_appkit_stubs():
    appkit = _PermissiveModule("AppKit")
    appkit.NSObject = type("NSObject", (), {})
    objc = _PermissiveModule("objc")

    class _ObjcSuperProxy:
        def __init__(self, *a):
            pass

        def init(self):
            return None

    objc.super = _ObjcSuperProxy
    objc.typedSelector = lambda sig: (lambda fn: fn)
    objc.selector = lambda fn, signature=b"": fn
    sys.modules["AppKit"] = appkit
    sys.modules["objc"] = objc
    sys.modules["Foundation"] = _PermissiveModule("Foundation")


_install_appkit_stubs()

_MODULES_DIR = os.path.normpath(
    os.path.join(os.path.dirname(__file__), os.pardir, os.pardir, "modules")
)
if "pymol" not in sys.modules or not hasattr(sys.modules["pymol"], "__path__"):
    _pymol_stub = types.ModuleType("pymol")
    _pymol_stub.__path__ = [os.path.join(_MODULES_DIR, "pymol")]
    _pymol_stub.__package__ = "pymol"
    sys.modules["pymol"] = _pymol_stub

# cmd.ray()/cmd.draw() lazily do `from pymol import appkit_ray_overlay`, so any
# earlier test in this process that rendered has already imported this module
# WITHOUT the stubs installed above. On a host with no pyobjc (every CI runner)
# that bakes in _HAS_APPKIT=False, show_ray_image() then returns at its first
# guard, and the tests below fail for a reason that has nothing to do with the
# code under test. Drop any cached copy so the stubs govern this import.
# Popping sys.modules alone is not enough: `from pymol import ...` would still
# find the stale module as an attribute of the package.
sys.modules.pop("pymol.appkit_ray_overlay", None)
ro = importlib.import_module("pymol.appkit_ray_overlay")


class FakeImageView:
    def __init__(self, hidden=False, superview=None):
        self._hidden = hidden
        self._superview = superview if superview is not None else object()
        self.calls = []

    def isHidden(self):
        return self._hidden

    def superview(self):
        return self._superview

    def setHidden_(self, b):
        self._hidden = b
        self.calls.append(("setHidden_", b))

    def removeFromSuperview(self):
        self._superview = None
        self.calls.append(("removeFromSuperview",))


class OverlayTestBase(unittest.TestCase):
    def setUp(self):
        ro._image_view = None
        ro._metal_view = None
        ro._event_monitor = None
        self._tmp = ro.raymol_tmp.channel_path("_pymol_ray_overlay", "png")
        try:
            os.unlink(self._tmp)
        except OSError:
            pass


class IsVisibleTest(OverlayTestBase):
    def test_false_when_no_view(self):
        ro._image_view = None
        self.assertFalse(ro.is_visible())

    def test_false_when_hidden(self):
        ro._image_view = FakeImageView(hidden=True)
        self.assertFalse(ro.is_visible())

    def test_false_when_detached(self):
        ro._image_view = FakeImageView(hidden=False, superview=None)
        # superview() is None -> not visible even if not hidden
        ro._image_view._superview = None
        self.assertFalse(ro.is_visible())

    def test_true_when_shown_and_attached(self):
        ro._image_view = FakeImageView(hidden=False)
        self.assertTrue(ro.is_visible())


class HideTest(OverlayTestBase):
    def test_hide_hides_and_detaches(self):
        view = FakeImageView(hidden=False)
        ro._image_view = view
        ro.hide()
        self.assertIn(("setHidden_", True), view.calls)
        self.assertIn(("removeFromSuperview",), view.calls)

    def test_hide_is_noop_without_view(self):
        ro._image_view = None
        ro.hide()   # must not raise


class ShowRayImageGuardsTest(OverlayTestBase):
    def test_noop_without_appkit(self):
        cmd = MagicMock()
        orig = ro._HAS_APPKIT
        ro._HAS_APPKIT = False
        try:
            ro.show_ray_image(cmd)
        finally:
            ro._HAS_APPKIT = orig
        cmd.png.assert_not_called()

    def test_returns_when_png_export_raises(self):
        # Bypass the metal-view guard by pretending one is cached.
        ro._metal_view = object()
        cmd = MagicMock()
        cmd.png.side_effect = RuntimeError("no image")
        ro.show_ray_image(cmd)                 # must not raise
        cmd.png.assert_called_once()
        self.assertEqual(cmd.png.call_args.kwargs.get("prior"), 1)
        self.assertFalse(ro.is_visible())      # nothing displayed

    def test_returns_when_output_file_missing(self):
        ro._metal_view = object()
        cmd = MagicMock()
        cmd.png.return_value = None            # writes nothing
        ro.show_ray_image(cmd)                 # file absent -> early return
        self.assertFalse(os.path.isfile(self._tmp))
        self.assertFalse(ro.is_visible())


if __name__ == "__main__":
    unittest.main()
