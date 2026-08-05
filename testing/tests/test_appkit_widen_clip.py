"""Tests for pymol.appkit_inspector.widen_clip_for_surface — the clip-slab widen
the macOS/iOS app runs whenever a probe-extended rep is shown.

Regression coverage for issue #195: showing dots (or surface, or mesh) reset the
camera. PyMOLEngine.runCommandCore calls maybeWidenClipForSurface for any command
containing `show dots` / `show surface` / `show mesh` (plus orient/reset/load/
fetch), and widen_clip_for_surface opened with `cmd.zoom('visible', 0.0,
complete=1)` to re-fit the slab tight before pushing the planes out. That zoom is
a camera dolly, so every `show dots` yanked the user's view.

The fix keeps the same intent — a slab wide enough for the ~solvent_radius shell —
via `clip atoms, buffer, visible`, which only calls SceneClipSet(front, back).

Measured on the pre-fix build (1UBQ, arm64 macOS): camera z went -165.147 ->
-147.282, an 17.86 A dolly, with rotation and center untouched. So the assertions
below split the view vector: [9:15] (camera position + center of rotation) must
not move, while [15:17] (near/far) is expected and required to change.
"""

from pymol import cmd, testing
from pymol import appkit_inspector as ai

# cmd.get_view() layout — layer1/Scene.cpp / modules/pymol/viewing.py.
ROT = slice(0, 9)        # rotation matrix
CAMERA = slice(9, 15)    # camera position (9:12) + origin of rotation (12:15)
CLIP = slice(15, 17)     # near / far

TOL = 1e-4


class TestWidenClipForSurface(testing.PyMOLTestCase):

    def _scene(self, rep='dots'):
        """A deliberate, non-default camera so any recenter/rezoom is obvious."""
        cmd.delete('all')
        cmd.fab('ACDEFGHIKL', 'mol')
        cmd.hide('everything')
        cmd.orient('mol')
        cmd.turn('y', 35)
        cmd.turn('x', 20)
        cmd.zoom('mol', 8)
        cmd.show(rep, 'mol')
        self.assertGreater(cmd.count_atoms('rep %s' % rep), 0,
                           'fixture must actually flag the %s rep, else '
                           'widen_clip_for_surface no-ops and proves nothing' % rep)
        return list(cmd.get_view())

    def _assertViewPart(self, part, after, before, equal, msg):
        for i, (a, b) in enumerate(zip(after[part], before[part])):
            if equal:
                self.assertAlmostEqual(a, b, delta=TOL,
                                       msg='%s (component %d)' % (msg, i))
        if not equal:
            self.assertFalse(
                all(abs(a - b) <= TOL for a, b in zip(after[part], before[part])),
                msg)

    @testing.foreach('dots', 'surface', 'mesh')
    def testWidenPreservesCamera(self, rep):
        # THE bug: this is the call the Swift layer makes on every `show <rep>`.
        before = self._scene(rep)

        ai.widen_clip_for_surface()
        after = list(cmd.get_view())

        self._assertViewPart(CAMERA, after, before, True,
                             'widen_clip_for_surface must not move the camera '
                             'position or the center of rotation (issue #195)')
        self._assertViewPart(ROT, after, before, True,
                             'widen_clip_for_surface must not rotate the view')

    def testWidenStillAdjustsTheClipSlab(self):
        # Guard against "fixing" #195 by turning the function into a no-op.
        before = self._scene()

        ai.widen_clip_for_surface()
        after = list(cmd.get_view())

        self._assertViewPart(CLIP, after, before, False,
                             'widen_clip_for_surface must still move the near/far '
                             'planes — that is the whole point of the function')

    def testPlainShowDoesNotMoveTheCameraEither(self):
        # Control: proves the camera move seen pre-fix came from the widen call
        # and not from cmd.show itself.
        cmd.delete('all')
        cmd.fab('ACDEFGHIKL', 'mol')
        cmd.hide('everything')
        cmd.orient('mol')
        cmd.zoom('mol', 8)
        before = list(cmd.get_view())

        cmd.show('dots', 'mol')

        self._assertViewPart(CAMERA, list(cmd.get_view()), before, True,
                             'cmd.show alone must never move the camera')

    def testRepeatedCallsDoNotAccumulate(self):
        # The old implementation justified its zoom as making repeated calls
        # idempotent. The replacement is absolute (recomputed from atom extents),
        # so it must be idempotent too — the poll can call this often.
        self._scene()

        ai.widen_clip_for_surface()
        once = list(cmd.get_view())
        for _ in range(4):
            ai.widen_clip_for_surface()
        many = list(cmd.get_view())

        for i, (a, b) in enumerate(zip(many, once)):
            self.assertAlmostEqual(a, b, delta=TOL,
                                   msg='repeated widen drifted at index %d' % i)

    def testNoOpWithoutAProbeExtendedRep(self):
        cmd.delete('all')
        cmd.fab('ACDEFGHIKL', 'mol')
        cmd.hide('everything')
        cmd.show('sticks', 'mol')
        cmd.orient('mol')
        cmd.zoom('mol', 8)
        before = list(cmd.get_view())

        ai.widen_clip_for_surface()

        for i, (a, b) in enumerate(zip(list(cmd.get_view()), before)):
            self.assertAlmostEqual(a, b, delta=TOL,
                                   msg='must be a no-op with no dots/surface/mesh '
                                       'rep shown (index %d)' % i)
