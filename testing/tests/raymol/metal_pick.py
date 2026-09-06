'''
Screen-space atom picking against a live core -- pymol.metal_pick (#394).

The camera is pinned with set_view so every expected screen position is
hand-computable rather than whatever zoom() happened to pick:

    rotation = identity, origin = (0,0,0), camera at z = +100 looking down -Z,
    slab [50, 150], field of view 20 deg.

Under that camera a model point (X, Y, Z) has eye depth 100 - Z, and the
renderer's half-height at depth D is

    tan_half = tan(2*tan(radians(20)/2) / 2) = tan(tan(radians(10)))
    half_h   = D * tan_half
    half_w   = half_h * (W / H)

so ndc = (X / half_w, Y / half_h). Same camera as api/box_select.py.

The pick itself runs in C++ (_cmd.metal_pick); metal_pick._python_pick is the
reference implementation of the same math, and TestNativeParity holds the two
to the same answers.
'''

import math

from pymol import cmd, testing, metal_pick

VIEW = (1.0, 0.0, 0.0,
        0.0, 1.0, 0.0,
        0.0, 0.0, 1.0,
        0.0, 0.0, -100.0,
        0.0, 0.0, 0.0,
        50.0, 150.0, -20.0)

CAM_DEPTH = 100.0
TAN_HALF = math.tan(2.0 * math.tan(math.radians(20.0) / 2.0) / 2.0)

# Reps whose geometry sits at the atom's own position, so a pick may land on
# it. Spelled out here rather than read off metal_pick, so that dropping one
# there fails a test instead of quietly deleting it. Cartoon and ribbon are
# deliberately absent -- they only draw through guide atoms, which
# testCartoonPicksResolveToGuideAtoms covers.
DRAWN_REPS = ('spheres', 'sticks', 'lines', 'nb_spheres', 'nonbonded',
              'surface', 'dots', 'mesh', 'ellipsoids')


class PickBase(testing.PyMOLTestCase):
    '''Pinned camera + geometry helpers shared by the cases below. Carries no
    test methods of its own.'''

    def setUp(self):
        super(PickBase, self).setUp()
        cmd.viewport(400, 300)
        self.width, self.height = cmd.get_viewport()
        cmd.set_view(VIEW)

    # -- helpers ----------------------------------------------------------

    def aspect(self):
        return float(self.width) / float(self.height)

    def ndc(self, model_x, model_y, model_z=0.0):
        '''Where a model point lands in NDC under the pinned camera.'''
        half_h = (CAM_DEPTH - model_z) * TAN_HALF
        return (model_x / (half_h * self.aspect()), model_y / half_h)

    def project(self, xyz):
        '''The same thing for the CURRENT camera, whatever it is -- the mapping
        documented at the top of metal_pick.'''
        cam = metal_pick.camera()
        d = [xyz[i] - cam.origin[i] for i in range(3)]
        eye = [sum(cam.rot[3 * k + i] * d[i] for i in range(3)) + cam.pos[k]
               for k in range(3)]
        half_h = -eye[2] * cam.tan_half
        return (eye[0] / (half_h * self.aspect()), eye[1] / half_h)

    def atoms(self, coords, obj='m1', rep='spheres'):
        '''One pseudoatom per (x, y, z), named a0, a1, ... in order.'''
        for i, xyz in enumerate(coords):
            cmd.pseudoatom(obj, name='a%d' % i, pos=list(xyz))
        cmd.show_as(rep, obj)
        return obj

    def pick(self, ndc_x, ndc_y, **kwargs):
        return metal_pick._pick_atom(ndc_x, ndc_y, self.aspect(), **kwargs)

    def picked_name(self, ndc_x, ndc_y, **kwargs):
        '''Name of the atom under (ndc_x, ndc_y), or None for empty space.'''
        best = self.pick(ndc_x, ndc_y, **kwargs)
        return None if best is None else best[6]

    def picked_object(self, ndc_x, ndc_y, **kwargs):
        best = self.pick(ndc_x, ndc_y, **kwargs)
        return None if best is None else best[1]


class TestPick(PickBase):

    def testTheAtomUnderTheCursorIsPicked(self):
        self.atoms([(-8, 0, 0), (0, 0, 0), (8, 4, 0)])
        self.assertEqual(self.picked_name(*self.ndc(-8, 0)), 'a0')
        self.assertEqual(self.picked_name(*self.ndc(0, 0)), 'a1')
        self.assertEqual(self.picked_name(*self.ndc(8, 4)), 'a2')

    def testEmptySpaceIsAMiss(self):
        self.atoms([(0, 0, 0)])
        self.assertIsNone(self.picked_name(-0.9, -0.9))

    def testTheFrontMostOfTwoOverlappingAtomsWins(self):
        # Same (x, y), so both project to NDC (0, 0); a1 is 40 A nearer the
        # camera and is the one the renderer put on top.
        self.atoms([(0, 0, -20), (0, 0, 20)])
        self.assertEqual(self.picked_name(0.0, 0.0), 'a1')
        cmd.hide('everything', 'm1 and name a1')
        self.assertEqual(self.picked_name(0.0, 0.0), 'a0')

    def testAtomsOutsideTheClipSlabAreNotPickable(self):
        # depth = 100 - z, and the slab is [50, 150].
        self.atoms([(0, 0, 60)], obj='near')     # depth 40, in front of the slab
        self.atoms([(0, 0, -60)], obj='far')     # depth 160, behind it
        self.assertIsNone(self.picked_name(0.0, 0.0))
        self.atoms([(0, 0, 0)], obj='mid')       # depth 100, inside
        self.assertEqual(self.picked_object(0.0, 0.0), 'mid')

    def testAtomsWithNoDrawnRepAreNotPickable(self):
        self.atoms([(0, 0, 0)])
        self.assertEqual(self.picked_name(0.0, 0.0), 'a0')
        cmd.hide('everything', 'm1')
        self.assertIsNone(self.picked_name(0.0, 0.0))

    def testADisabledObjectIsNotPickable(self):
        self.atoms([(0, 0, 0)], obj='shown')
        self.atoms([(0, 0, 20)], obj='hidden')   # nearer, so it would win
        self.assertEqual(self.picked_object(0.0, 0.0), 'hidden')
        cmd.disable('hidden')
        self.assertEqual(self.picked_object(0.0, 0.0), 'shown')

    def testAMovedObjectPicksWhereItRenders(self):
        # The object matrix (TTT) moves the geometry without touching the
        # coordinates, so a pick that read raw coordinates would keep hitting
        # the old screen position.
        self.atoms([(0, 0, 0)])
        cmd.translate([6.0, 0.0, 0.0], object='m1', camera=0)
        self.assertIsNone(self.picked_name(*self.ndc(0, 0)))
        self.assertEqual(self.picked_name(*self.ndc(6, 0)), 'a0')

    def testTheDisplayedStateIsPicked(self):
        cmd.pseudoatom('m1', name='a0', pos=[-8.0, 0.0, 0.0])
        cmd.create('m1', 'm1', 1, 2)          # same atom, a second state
        cmd.alter_state(2, 'm1', 'x = 8.0')
        cmd.show_as('spheres', 'm1')
        self.assertEqual(cmd.count_states('m1'), 2)
        self.assertEqual(self.picked_name(*self.ndc(-8, 0)), 'a0')
        self.assertIsNone(self.picked_name(*self.ndc(8, 0)))
        cmd.frame(2)
        self.assertIsNone(self.picked_name(*self.ndc(-8, 0)))
        self.assertEqual(self.picked_name(*self.ndc(8, 0)), 'a0')

    def testTheObjectRadiusIsMoreForgivingThanTheAtomRadius(self):
        # Object (move-mode) picking passes the wider radius so a tap anywhere
        # on a molecule identifies it; the default residue radius does not.
        self.atoms([(0, 0, 0)])
        off = self.ndc(0, 0)
        off = (off[0] + 0.2, off[1])
        self.assertIsNone(self.picked_name(*off))
        self.assertEqual(
            self.picked_name(*off, max_ndc2=metal_pick._OBJECT_PICK_NDC2), 'a0')


class TestDrawnReps(PickBase):
    '''What counts as "drawn", i.e. what the visRep bitmask the native pick
    tests must mean the same thing as the _DRAWN_REPS selection.'''

    @testing.foreach(*DRAWN_REPS)
    def testEachDrawnRepIsPickable(self, rep):
        self.atoms([(0, 0, 0)], rep=rep)
        self.assertEqual(cmd.count_atoms('(m1) and (%s)' % metal_pick._DRAWN_REPS), 1)
        self.assertEqual(self.picked_name(0.0, 0.0), 'a0')

    def testLabelsAloneAreNotPickable(self):
        self.atoms([(0, 0, 0)], rep='labels')
        self.assertEqual(cmd.count_atoms('(m1) and (%s)' % metal_pick._DRAWN_REPS), 0)
        self.assertIsNone(self.picked_name(0.0, 0.0))

    def testCartoonPicksResolveToGuideAtoms(self):
        # `show cartoon` sets its visRep bit on EVERY atom of the object, but
        # the ribbon is a spline through the guide atoms, so those are the only
        # ones a pick may land on -- otherwise hovering a cartoon snaps to
        # whichever invisible side-chain atom happens to project nearest.
        cmd.fab('AWAWA', 'pep')
        cmd.hide('everything', 'pep')
        cmd.show('cartoon', 'pep')
        cmd.orient('pep')
        hits = 0
        for xyz, name in self._atom_positions('pep and not name CA'):
            best = metal_pick._pick_atom(*(self.project(xyz) + (self.aspect(),)))
            if best is not None:
                hits += 1
                self.assertEqual(best[6], 'CA',
                                 'cursor over %s picked %s' % (name, best[6]))
        self.assertTrue(hits, 'no cartoon atom was hit at all')

    def _atom_positions(self, selection):
        rows = []
        cmd.iterate_state(1, selection, 'rows.append(((x, y, z), name))',
                          space={'rows': rows}, quiet=1)
        return rows


class TestNativeParity(PickBase):
    '''The C++ pick and the Python reference must agree everywhere.'''

    def setUp(self):
        super(TestNativeParity, self).setUp()
        if not metal_pick._have_native_pick():
            self.skipTest('core built without _cmd.metal_pick')

    def _scene(self):
        cmd.fab('AWKGDYF', 'pep')
        cmd.show_as('sticks', 'pep')
        cmd.show('spheres', 'pep and name CA')
        cmd.fab('GGPLA', 'pep2')
        cmd.show_as('cartoon', 'pep2')
        cmd.translate([4.0, 3.0, 2.0], object='pep2', camera=0)
        self.atoms([(0, 0, 5), (2, -2, -5)], obj='dots', rep='dots')
        cmd.zoom('all', buffer=2)
        return [o for o in cmd.get_names('objects', enabled_only=1)]

    def _assertSameHit(self, native, python, where):
        if native is None or python is None:
            self.assertEqual(native, python, where)
            return
        self.assertEqual(native[1:7], python[1:7], where)
        for i in (0, 7, 8):
            self.assertAlmostEqual(native[i], python[i], delta=1e-4, msg=where)

    def testTheTwoPathsAgreeAcrossTheViewport(self):
        objs = self._scene()
        cam = metal_pick.camera()
        aspect = self.aspect()
        thresh = metal_pick._MAX_PICK_NDC2
        seen = 0
        for i in range(11):
            for j in range(11):
                x, y = -1.0 + 0.2 * i, -1.0 + 0.2 * j
                native = metal_pick._native_pick(objs, cam, x, y, aspect, thresh)
                python = metal_pick._python_pick(objs, cam, x, y, aspect, thresh)
                self._assertSameHit(native, python, 'at ndc (%.1f, %.1f)' % (x, y))
                seen += native is not None
        self.assertTrue(seen, 'the sampled grid never hit an atom')

    def testTheTwoPathsAgreeAtTheObjectRadius(self):
        objs = self._scene()
        cam = metal_pick.camera()
        aspect = self.aspect()
        thresh = metal_pick._OBJECT_PICK_NDC2
        for i in range(7):
            x = -0.9 + 0.3 * i
            self._assertSameHit(
                metal_pick._native_pick(objs, cam, x, 0.0, aspect, thresh),
                metal_pick._python_pick(objs, cam, x, 0.0, aspect, thresh),
                'at ndc (%.1f, 0.0)' % x)
