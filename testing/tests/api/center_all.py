'''
Testing: cmd.center_all (issue #354)
'''

from pymol import cmd, stored, testing
from pymol import CmdException
from chempy import cpv


def extent_center(name):
    mn, mx = cmd.get_extent(name)
    return cpv.scale(cpv.add(mn, mx), 0.5)


def raw_coords(name, state=1):
    '''
    Stored coordinates, before the object matrix. get_model applies the matrix,
    so it cannot tell a display transformation from a coordinate rewrite.
    '''
    stored.xyz = []
    cmd.iterate_state(state, name, 'stored.xyz.append([x, y, z])')
    return stored.xyz


class TestCenterAll(testing.PyMOLTestCase):

    def make_scattered(self):
        '''Three single-atom objects sitting far apart.'''
        cmd.pseudoatom('m1', pos=[0., 0., 0.])
        cmd.pseudoatom('m2', pos=[30., 0., 0.])
        cmd.pseudoatom('m3', pos=[0., -50., 12.])

    def assertCentersEqual(self, names, delta=1e-3):
        first = extent_center(names[0])
        for name in names[1:]:
            self.assertArrayEqual(extent_center(name), first, delta=delta)

    def testDefaultsToFirstObject(self):
        self.make_scattered()
        cmd.center_all()
        # Everything lands on m1, which itself must not have moved.
        self.assertArrayEqual(extent_center('m1'), [0., 0., 0.], delta=1e-3)
        self.assertCentersEqual(['m1', 'm2', 'm3'])

    def testExplicitTarget(self):
        self.make_scattered()
        cmd.center_all('m3')
        self.assertArrayEqual(extent_center('m3'), [0., -50., 12.], delta=1e-3)
        self.assertCentersEqual(['m1', 'm2', 'm3'])

    def testUnknownTargetRaises(self):
        self.make_scattered()
        with self.assertRaises(CmdException):
            cmd.center_all('nosuchobject')

    def testMatrixModeLeavesCoordinatesAlone(self):
        self.make_scattered()
        cmd.center_all()
        # The default is a display transformation: the stored coordinates are
        # untouched, so a matrix_reset restores the original layout.
        self.assertArrayEqual(raw_coords('m2')[0], [30., 0., 0.], delta=1e-3)
        cmd.matrix_reset('m2', mode=1)
        self.assertArrayEqual(extent_center('m2'), [30., 0., 0.], delta=1e-3)

    def testCoordsModeRewritesCoordinates(self):
        self.make_scattered()
        cmd.center_all(coords=1)
        self.assertArrayEqual(raw_coords('m2')[0], [0., 0., 0.], delta=1e-3)
        self.assertCentersEqual(['m1', 'm2', 'm3'])

    def testCoordsModeWithRotatedObjectMatrix(self):
        # An object carrying a rotated matrix (as align leaves behind) has a
        # coordinate frame that differs from world space. The shift must be
        # rotated back into that frame or the object slides off sideways.
        self.make_scattered()
        cmd.rotate('z', 90, object='m2', camera=0)
        cmd.center_all(coords=1)
        self.assertCentersEqual(['m1', 'm2', 'm3'])

    def testCenterOfMassMethod(self):
        # COM differs from the bounding-box center when mass is lopsided: one
        # heavy atom and one light one at the ends of a long axis.
        cmd.pseudoatom('m1', pos=[0., 0., 0.], elem='C')
        cmd.pseudoatom('m2', pos=[0., 0., 0.], elem='H')
        cmd.pseudoatom('m2', pos=[60., 0., 0.], elem='W')
        com_before = cmd.centerofmass('m2')
        self.assertTrue(abs(com_before[0] - extent_center('m2')[0]) > 1.,
                        'test needs a case where COM and extent disagree')
        cmd.center_all(method='com')
        self.assertArrayEqual(cmd.centerofmass('m2'), [0., 0., 0.], delta=1e-3)

    def testCenterOfMassFallsBackForMasslessObjects(self):
        # Pseudoatoms have a symbol that is not in the mass table; they must
        # still be centered rather than raising or being silently skipped.
        cmd.pseudoatom('m1', pos=[0., 0., 0.])
        cmd.pseudoatom('m2', pos=[25., 0., 0.])
        cmd.center_all(method='com')
        self.assertCentersEqual(['m1', 'm2'])

    def testMultiStateObjectMovesRigidly(self):
        cmd.pseudoatom('m1', pos=[0., 0., 0.])
        cmd.pseudoatom('m2', pos=[40., 0., 0.])
        cmd.create('m2', 'm2', 1, 2)
        cmd.translate([0., 7., 0.], selection='m2', state=2, camera=0)
        before = cpv.sub(raw_coords('m2', 2)[0], raw_coords('m2', 1)[0])
        cmd.center_all(coords=1)
        after = cpv.sub(raw_coords('m2', 2)[0], raw_coords('m2', 1)[0])
        # Every state shifts by the same vector, so their relative offset holds.
        self.assertArrayEqual(after, before, delta=1e-3)

    def testEnabledOnly(self):
        self.make_scattered()
        cmd.disable('m2')
        cmd.center_all(enabled_only=1)
        self.assertArrayEqual(extent_center('m2'), [30., 0., 0.], delta=1e-3)
        self.assertCentersEqual(['m1', 'm3'])

    def testGroupsAreSkipped(self):
        # A group's matrix propagates to its members, so moving both would
        # shift the members twice.
        self.make_scattered()
        cmd.group('g1', 'm2 m3')
        cmd.center_all('m1')
        self.assertCentersEqual(['m1', 'm2', 'm3'])

    def testNoObjectsIsNotAnError(self):
        cmd.center_all()

    def testSingleObjectIsANoOp(self):
        cmd.pseudoatom('m1', pos=[5., 5., 5.])
        cmd.center_all()
        self.assertArrayEqual(extent_center('m1'), [5., 5., 5.], delta=1e-3)

    def testEmptyObjectIsSkipped(self):
        # An atomless object has no real extent; centering on the unit box
        # get_extent invents for it would fling it somewhere arbitrary.
        self.make_scattered()
        cmd.create('empty', 'none')
        cmd.center_all('m1')
        self.assertCentersEqual(['m1', 'm2', 'm3'])
