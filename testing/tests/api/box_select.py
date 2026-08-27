'''
Screen-space box (rubber-band) selection -- cmd.box_select (issue #358).

The camera used throughout is pinned with set_view so every expected screen
position is hand-computable rather than whatever zoom() happened to pick:

    rotation = identity, origin = (0,0,0), camera at z = +100 looking down -Z,
    slab [50, 150], field of view 20 deg.

Under that camera an atom at model (X, Y, 0) has eye depth 100, and the
renderer's half-height at that depth is

    tan_half = tan(2*tan(radians(20)/2) / 2) = tan(tan(radians(10)))
    half_h   = 100 * tan_half        ~= 17.82 A
    half_w   = half_h * (W / H)

so ndc_x = X / half_w, ndc_y = Y / half_h, and pixel = (ndc + 1) / 2 * size.
'''

import math

from pymol import cmd, testing

# The pinned camera (18-float set_view layout: 3x3 rotation, pos, origin,
# front, back, fov flag). v[17] < 0 = perspective, |v[17]| = vertical FOV.
VIEW = (1.0, 0.0, 0.0,
        0.0, 1.0, 0.0,
        0.0, 0.0, 1.0,
        0.0, 0.0, -100.0,
        0.0, 0.0, 0.0,
        50.0, 150.0, -20.0)

CAM_DEPTH = 100.0
TAN_HALF = math.tan(2.0 * math.tan(math.radians(20.0) / 2.0) / 2.0)


class BoxSelectBase(testing.PyMOLTestCase):
    '''Pinned camera + geometry helpers shared by the cases below. Carries no
    test methods of its own.'''

    def setUp(self):
        super(BoxSelectBase, self).setUp()
        cmd.viewport(400, 300)
        self.width, self.height = cmd.get_viewport()
        cmd.set_view(VIEW)

    # -- helpers ----------------------------------------------------------

    def half_h(self):
        return CAM_DEPTH * TAN_HALF

    def half_w(self):
        return self.half_h() * self.aspect()

    def aspect(self):
        return float(self.width) / float(self.height)

    def px(self, model_x, model_y):
        '''Pixel position (bottom-left origin) of a model point at z = 0.'''
        return ((model_x / self.half_w() + 1.0) * 0.5 * self.width,
                (model_y / self.half_h() + 1.0) * 0.5 * self.height)

    def ndc(self, model_x, model_y):
        '''The same point in NDC, for the entry points the app calls.'''
        return (model_x / self.half_w(), model_y / self.half_h())

    def atoms(self, coords, obj='m1', rep='spheres'):
        '''One pseudoatom per (x, y, z), named a0, a1, ... in order.'''
        for i, xyz in enumerate(coords):
            cmd.pseudoatom(obj, name='a%d' % i, pos=list(xyz))
        cmd.show_as(rep, obj)
        return obj

    def box_names(self, *box):
        cmd.box_select(*box)
        return self.selected_names()

    def selected_names(self, sele='sele'):
        names = []
        if sele in cmd.get_names('selections'):
            cmd.iterate(sele, 'names.append(name)', space={'names': names})
        return sorted(names)


class TestBoxSelect(BoxSelectBase):
    '''cmd.box_select -- the scriptable, pixel-space command surface.'''

    def testWholeViewportSelectsEverything(self):
        self.atoms([(-10, 0, 0), (0, 5, 0), (10, -5, 0)])
        n = cmd.box_select(0, 0, self.width, self.height)
        self.assertEqual(n, 3)
        self.assertEqual(cmd.count_atoms('sele'), 3)

    def testEmptyBoxSelectsNothing(self):
        self.atoms([(-10, 0, 0), (10, 0, 0)])
        # A degenerate box in a corner no atom projects into.
        self.assertEqual(cmd.box_select(0, 0, 1, 1), 0)
        self.assertEqual(cmd.count_atoms('sele'), 0)

    def testHalfViewportSplitsByScreenX(self):
        # Screen x ordering follows model x under the identity rotation.
        self.atoms([(-20, 0, 0), (-5, 0, 0), (5, 0, 0), (20, 0, 0)])
        cmd.box_select(0, 0, self.width // 2, self.height)
        self.assertEqual(self.selected_names(), ['a0', 'a1'])
        cmd.box_select(self.width // 2, 0, self.width, self.height)
        self.assertEqual(self.selected_names(), ['a2', 'a3'])

    def testCornerOrderDoesNotMatter(self):
        self.atoms([(-20, 0, 0), (5, 0, 0)])
        cmd.box_select(0, 0, self.width // 2, self.height)
        forward = self.selected_names()
        cmd.box_select(self.width // 2, self.height, 0, 0)
        self.assertEqual(self.selected_names(), forward)
        self.assertEqual(forward, ['a0'])

    def testProjectionMatchesHandComputedPixels(self):
        # The heart of it: a box drawn tightly around ONE atom's computed screen
        # position must catch that atom and only that atom.
        coords = [(-20, 0, 0), (-5, 8, 0), (5, -8, 0), (20, 0, 0)]
        self.atoms(coords)
        for i, xyz in enumerate(coords):
            x, y = self.px(xyz[0], xyz[1])
            cmd.box_select(x - 4, y - 4, x + 4, y + 4)
            self.assertEqual(self.selected_names(), ['a%d' % i],
                             'box around atom %d caught the wrong atoms' % i)

    # -- modes ------------------------------------------------------------

    def testAddAndSubtractModes(self):
        self.atoms([(-20, 0, 0), (-5, 0, 0), (5, 0, 0), (20, 0, 0)])
        left = (0, 0, self.width // 2, self.height)
        right = (self.width // 2, 0, self.width, self.height)

        cmd.box_select(*left)
        self.assertEqual(self.selected_names(), ['a0', 'a1'])
        cmd.box_select(*right, mode='add')
        self.assertEqual(self.selected_names(), ['a0', 'a1', 'a2', 'a3'])
        cmd.box_select(*left, mode='subtract')
        self.assertEqual(self.selected_names(), ['a2', 'a3'])
        # replace (the default) drops whatever was there before
        cmd.box_select(*left, mode='replace')
        self.assertEqual(self.selected_names(), ['a0', 'a1'])

    def testModeIsAbbreviatedAndValidated(self):
        self.atoms([(0, 0, 0)])
        whole = (0, 0, self.width, self.height)
        cmd.box_select(*whole)
        cmd.box_select(*whole, mode='sub')          # Shortcut expansion
        self.assertEqual(cmd.count_atoms('sele'), 0)
        self.assertRaises(Exception, cmd.box_select, 0, 0, 10, 10, mode='bogus')

    def testCustomSelectionName(self):
        self.atoms([(-20, 0, 0), (5, 0, 0)])
        cmd.box_select(0, 0, self.width // 2, self.height, name='mybox')
        self.assertEqual(self.selected_names('mybox'), ['a0'])
        self.assertEqual(cmd.count_atoms('?sele'), 0)
        self.assertTrue('mybox' in cmd.get_names('selections', enabled_only=1))

    def testScratchSelectionsAreCleanedUp(self):
        self.atoms([(0, 0, 0)])
        cmd.box_select(0, 0, self.width, self.height)
        leaked = [n for n in cmd.get_names('all') if n.startswith('_box_select')]
        self.assertEqual(leaked, [])

    # -- what the box is allowed to see -----------------------------------

    def testSelectionArgumentNarrowsCandidates(self):
        self.atoms([(-10, 0, 0), (10, 0, 0)], obj='m1')
        self.atoms([(-8, 0, 0), (8, 0, 0)], obj='m2')
        n = cmd.box_select(0, 0, self.width, self.height, selection='m2')
        self.assertEqual(n, 2)
        self.assertEqual(cmd.count_atoms('sele and m1'), 0)
        self.assertEqual(cmd.count_atoms('sele and m2'), 2)

    def testHiddenAtomsAreNotSelected(self):
        self.atoms([(-10, 0, 0), (10, 0, 0)], obj='m1')
        self.atoms([(-8, 0, 0), (8, 0, 0)], obj='m2')
        whole = (0, 0, self.width, self.height)

        cmd.hide('everything', 'm2')
        self.assertEqual(cmd.box_select(*whole), 2)
        self.assertEqual(cmd.count_atoms('sele and m2'), 0)

        # A disabled object draws nothing either.
        cmd.show_as('spheres', 'm2')
        cmd.disable('m2')
        self.assertEqual(cmd.box_select(*whole), 2)
        self.assertEqual(cmd.count_atoms('sele and m2'), 0)

    def testClippedAtomsAreNotSelected(self):
        # a0 sits at eye depth 100, a1 at depth 80 (20 A nearer the camera).
        self.atoms([(0, 0, 0), (6, 0, 20)])
        whole = (0, 0, self.width, self.height)
        self.assertEqual(self.box_names(*whole), ['a0', 'a1'])

        narrow = list(VIEW)
        narrow[15], narrow[16] = 90.0, 110.0    # slab now clips depth 80 away
        cmd.set_view(narrow)
        self.assertEqual(self.box_names(*whole), ['a0'])

    def testMultipleObjectsInOneBox(self):
        self.atoms([(-10, 0, 0)], obj='m1')
        self.atoms([(10, 0, 0)], obj='m2')
        n = cmd.box_select(0, 0, self.width, self.height)
        self.assertEqual(n, 2)
        self.assertEqual(cmd.count_atoms('sele and m1'), 1)
        self.assertEqual(cmd.count_atoms('sele and m2'), 1)

    def testGridModeBoxesTheCellItWasDrawnOver(self):
        # grid_mode=1 gives every object its own viewport cell, so a full-window
        # projection would be wrong for all of them. The box belongs to the cell
        # under its centre, exactly as a click does. Two objects at aspect 4:3
        # lay out as two columns: m1 left, m2 right.
        self.atoms([(-5, 0, 0), (5, 0, 0)], obj='m1')
        self.atoms([(-5, 0, 0), (5, 0, 0)], obj='m2')
        cmd.set('grid_mode', 1)
        try:
            n = cmd.box_select(0, 0, self.width // 2, self.height)
            self.assertEqual(n, 2)
            self.assertEqual(cmd.count_atoms('sele and m2'), 0,
                             'a box over the left cell must not reach into the right one')
            cmd.box_select(self.width // 2, 0, self.width, self.height)
            self.assertEqual(cmd.count_atoms('sele and m1'), 0)
            self.assertEqual(cmd.count_atoms('sele and m2'), 2)
        finally:
            cmd.set('grid_mode', 0)

    def testUsesTheDisplayedState(self):
        cmd.pseudoatom('m1', name='a0', pos=[-15.0, 0.0, 0.0], state=1)
        cmd.pseudoatom('m1', name='a0', pos=[15.0, 0.0, 0.0], state=2)
        cmd.show_as('spheres', 'm1')
        left = (0, 0, self.width // 2, self.height)

        cmd.frame(1)
        self.assertEqual(cmd.box_select(*left), 1)
        cmd.frame(2)
        self.assertEqual(cmd.box_select(*left), 0)
        # ...and an explicit state overrides the displayed one.
        self.assertEqual(cmd.box_select(*left, state=1), 1)


class TestBoxSession(BoxSelectBase):
    '''The session entry points the macOS/iPadOS Box Select tool calls directly.

    The tool commits on every drag rather than behind an Accept button, so each
    commit has to compose against the box_begin snapshot instead of against its
    own previous result. The Swift side is unit-tested for emitting exactly these
    calls (see BoxSelectModeTests); this is the other half of that contract.
    '''

    def commit(self, model_x0, model_y0, model_x1, model_y1, mode='replace'):
        '''Commit a box given by two model-space points at z = 0.'''
        from pymol import metal_pick
        x0, y0 = self.ndc(model_x0, model_y0)
        x1, y1 = self.ndc(model_x1, model_y1)
        return metal_pick.box_commit_ndc(x0, y0, x1, y1, self.aspect(),
                                         name='sele', mode=mode)

    def testCommitReturnsTheResultingSelectionSize(self):
        from pymol import metal_pick
        self.atoms([(-20, 0, 0), (-5, 0, 0), (5, 0, 0), (20, 0, 0)])
        metal_pick.box_begin('sele')
        self.assertEqual(self.commit(-25, -10, 0, 10), 2)
        self.assertEqual(self.selected_names(), ['a0', 'a1'])

    def testRedraggingTheSameBoxDoesNotRatchet(self):
        # The regression that makes the snapshot necessary: with add mode
        # composing against the LIVE selection, shrinking the box would keep
        # everything it had ever swept over.
        from pymol import metal_pick
        self.atoms([(-20, 0, 0), (-5, 0, 0), (5, 0, 0), (20, 0, 0)])
        cmd.select('sele', 'name a3')
        metal_pick.box_begin('sele')

        self.commit(-25, -10, 10, 10, mode='add')          # sweeps a0..a2
        self.assertEqual(self.selected_names(), ['a0', 'a1', 'a2', 'a3'])
        self.commit(-25, -10, -10, 10, mode='add')         # dragged back to a0
        self.assertEqual(self.selected_names(), ['a0', 'a3'],
                         'shrinking an add-mode box must give the atoms back')

    def testSubtractComposesAgainstTheSnapshotToo(self):
        from pymol import metal_pick
        self.atoms([(-20, 0, 0), (-5, 0, 0), (5, 0, 0), (20, 0, 0)])
        cmd.select('sele', 'all')
        metal_pick.box_begin('sele')

        self.commit(-25, -10, 0, 10, mode='subtract')      # removes a0, a1
        self.assertEqual(self.selected_names(), ['a2', 'a3'])
        self.commit(-25, -10, -10, 10, mode='subtract')    # now only a0
        self.assertEqual(self.selected_names(), ['a1', 'a2', 'a3'],
                         'shrinking a subtract-mode box must put atoms back')

    def testModeCanChangeUnderTheSameBox(self):
        # What the overlay's Replace/Add/Subtract control does to a drawn box.
        from pymol import metal_pick
        self.atoms([(-20, 0, 0), (-5, 0, 0), (5, 0, 0), (20, 0, 0)])
        cmd.select('sele', 'name a3')
        metal_pick.box_begin('sele')

        self.assertEqual(self.selected_names('sele'), ['a3'])
        self.commit(-25, -10, 0, 10, mode='add')
        self.assertEqual(self.selected_names(), ['a0', 'a1', 'a3'])
        self.commit(-25, -10, 0, 10, mode='replace')
        self.assertEqual(self.selected_names(), ['a0', 'a1'])

    def testFinishDropsTheSnapshot(self):
        from pymol import metal_pick
        self.atoms([(0, 0, 0)])
        metal_pick.box_begin('sele')
        self.assertTrue('_box_select_base' in cmd.get_names('all'))
        metal_pick.box_finish()
        self.assertFalse('_box_select_base' in cmd.get_names('all'))

    def testBeginOnAnEmptySelectionIsFine(self):
        from pymol import metal_pick
        self.atoms([(-20, 0, 0), (5, 0, 0)])
        metal_pick.box_begin('sele')          # 'sele' does not exist yet
        self.assertEqual(self.commit(-25, -10, 0, 10, mode='add'), 1)
        self.assertEqual(self.selected_names(), ['a0'])

    def testScriptedCommandStillComposesAgainstTheLiveSelection(self):
        # cmd.box_select is a one-shot: with no session open it must add to
        # whatever 'sele' holds now, not to a stale snapshot.
        self.atoms([(-20, 0, 0), (5, 0, 0)])
        cmd.select('sele', 'name a1')
        cmd.box_select(0, 0, self.width // 2, self.height, mode='add')
        self.assertEqual(self.selected_names(), ['a0', 'a1'])

    def testNdcAndPixelFormsAgree(self):
        from pymol import metal_pick
        coords = [(-20, 0, 0), (-5, 8, 0), (5, -8, 0), (20, 0, 0)]
        self.atoms(coords)
        for i, xyz in enumerate(coords):
            nx, ny = self.ndc(xyz[0], xyz[1])
            d = 0.02
            metal_pick.box_select_ndc(nx - d, ny - d, nx + d, ny + d,
                                      self.aspect(), name='sele')
            self.assertEqual(self.selected_names(), ['a%d' % i])
