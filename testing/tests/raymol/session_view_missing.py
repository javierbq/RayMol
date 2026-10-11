"""Session restore must never apply an uninitialised view (#636).

ExecutiveSetSession used to call SceneSetView with a stack-allocated, never
written view array when a full (non-partial) session had no 'view' key. The
defined behaviour is now: a missing key leaves the current camera alone, and
a malformed key (wrong type, wrong length, non-numeric entries) is not
applied either; the rest of the session still loads.

Runs on a RayMol build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/session_view_missing.py
"""
import math

from pymol import cmd, testing


def _assert_view_finite(case, view):
    case.assertEqual(len(view), 18)
    for v in view:
        case.assertFalse(math.isnan(v) or math.isinf(v), view)


class TestSessionViewMissing(testing.PyMOLTestCase):
    def _setup(self):
        cmd.reinitialize()
        cmd.fragment('ala', 'm1')
        self.natoms = cmd.count_atoms('m1')
        cmd.turn('x', 37)
        cmd.turn('y', 21)
        cmd.zoom('m1', 5)
        cmd.move('z', 3)

    def _restore_without_view(self, mutate):
        """Save a full session, change the camera, restore it with the
        'view' key removed/replaced by `mutate`; return (camera that was
        current at restore time, camera after restore)."""
        self._setup()
        session = cmd.get_session()
        self.assertIn('view', session)
        mutate(session)
        # A camera different from the one in the session, which the
        # restore must leave alone.
        cmd.turn('z', 55)
        cmd.move('x', 2)
        before = cmd.get_view()
        cmd.set_session(session)
        after = cmd.get_view()
        return before, after

    def _check_untouched(self, before, after):
        _assert_view_finite(self, after)
        for a, b in zip(before, after):
            self.assertAlmostEqual(a, b, places=4)

    def testMissingViewKeyLeavesCameraAlone(self):
        before, after = self._restore_without_view(
            lambda s: s.pop('view'))
        self._check_untouched(before, after)
        # The rest of the session still loaded.
        self.assertEqual(cmd.get_names(), ['m1'])
        self.assertEqual(cmd.count_atoms('m1'), self.natoms)

    def testMissingViewKeyRepeated(self):
        # Uninitialised stack contents vary from call to call; check
        # several restores in a row.
        for _ in range(5):
            before, after = self._restore_without_view(
                lambda s: s.pop('view'))
            self._check_untouched(before, after)

    def testWrongLengthViewNotApplied(self):
        before, after = self._restore_without_view(
            lambda s: s.__setitem__('view', [1.0, 2.0, 3.0]))
        self._check_untouched(before, after)
        self.assertEqual(cmd.count_atoms('m1'), self.natoms)

    def testWrongTypeViewNotApplied(self):
        for bad in ('not a view', None, 7, {'a': 1}):
            before, after = self._restore_without_view(
                lambda s, bad=bad: s.__setitem__('view', bad))
            self._check_untouched(before, after)

    def testNonNumericViewEntriesNotApplied(self):
        before, after = self._restore_without_view(
            lambda s: s.__setitem__('view', ['x'] * 18))
        self._check_untouched(before, after)

    def testValidViewStillRestored(self):
        self._setup()
        want = cmd.get_view()
        session = cmd.get_session()
        cmd.turn('z', 55)
        cmd.set_session(session)
        got = cmd.get_view()
        for a, b in zip(want, got):
            self.assertAlmostEqual(a, b, places=4)

    def testPartialRestoreWithoutViewKeyLeavesCamera(self):
        self._setup()
        session = cmd.get_session()
        session.pop('view')
        cmd.turn('z', 55)
        before = cmd.get_view()
        cmd.set_session(session, partial=1)
        self._check_untouched(before, cmd.get_view())
