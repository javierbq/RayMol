"""Every `set` must ask the viewport to repaint (#424).

Runs under the embedded core:
    pymol -ckqy testing/testing.py --run testing/tests/test_setting_redisplay.py

The macOS app draws on demand: its Metal view skips the frame unless PyMOL's
redisplay flag is raised. Settings with a dedicated side effect (fog, the
lights, ...) raise it via SceneInvalidate, but any setting that fell through
to `default:` in SettingGenerateSideEffects did not -- so the Effects sliders
(metal_exposure), toggles (metal_outline) and the per-object surface clip
sliders only showed once a mouse move over the viewport forced a frame.
"""

from pymol import cmd, testing, _cmd


class TestSetRaisesRedisplay(testing.PyMOLTestCase):

    def _clear(self):
        _cmd._getRedisplay(cmd._COb, 1)          # read + reset
        self.assertEqual(_cmd._getRedisplay(cmd._COb, 0), 0)

    def _pending(self):
        return _cmd._getRedisplay(cmd._COb, 0)

    def testGlobalFloatWithoutSideEffectCase(self):
        cmd.reinitialize()
        self._clear()
        cmd.set('metal_exposure', 1.25, quiet=1)
        self.assertEqual(self._pending(), 1)

    def testGlobalBoolWithoutSideEffectCase(self):
        cmd.reinitialize()
        self._clear()
        cmd.set('metal_outline', 1, quiet=1)
        self.assertEqual(self._pending(), 1)

    def testPerObjectSetting(self):
        cmd.reinitialize()
        cmd.fragment('ala', 'm1')
        self._clear()
        cmd.set('surface_clip_front', 5.0, 'm1', quiet=1)
        self.assertEqual(self._pending(), 1)

    def testCommandLanguagePath(self):
        # The inspector's surface sliders go through cmd.do("set ...") rather
        # than cmd.set(); same core path, pinned separately.
        cmd.reinitialize()
        self._clear()
        cmd.do('set metal_exposure, 0.8', echo=0)
        self.assertEqual(self._pending(), 1)

    def testUpdatesZeroStaysSilent(self):
        # updates=0 is the documented "no side effects" escape hatch (session
        # restore uses it); it must keep not raising a frame.
        cmd.reinitialize()
        self._clear()
        cmd.set('metal_exposure', 1.5, quiet=1, updates=0)
        self.assertEqual(self._pending(), 0)
