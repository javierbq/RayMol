"""The trajectory object a live design builds up, one state per captured frame.

    pymol -ckqy testing/testing.py --run testing/tests/generate/generate_trajectory.py
"""
import os
import sys

from pymol import cmd

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

from generate_harness import GeneratorTestCase  # noqa: E402


_SLOTS = ('N', 'CA', 'C', 'O', 'CB')


def _backbone(length, offset=(0.0, 0.0, 0.0)):
    """Real poly-ALA backbone coordinates, in RFD3Trajectory.seedPDB's slot order.

    Built with PyMOL's own builder rather than invented, because the seed's coordinates
    are what PyMOL infers the trajectory's BONDS from -- a fixture with made-up geometry
    would bond differently from anything a rollout ever produces and prove nothing.
    """
    # auto_zoom off around the builder: `fab` creates an object, which fires auto-zoom and
    # would move the camera from inside a FIXTURE -- the very thing the camera test is
    # trying to attribute to trajectory_seed.
    saved = cmd.get('auto_zoom')
    cmd.set('auto_zoom', 0)
    try:
        cmd.fab('A' * length, '_bbsrc', ss=1)
        by_residue = {}
        for atom in cmd.get_model('_bbsrc and name N+CA+C+O+CB').atom:
            by_residue.setdefault(int(atom.resi), {})[atom.name] = atom.coord
        cmd.delete('_bbsrc')
    finally:
        cmd.set('auto_zoom', saved)
    coords = []
    for resi in sorted(by_residue):
        for name in _SLOTS:
            x, y, z = by_residue[resi][name]
            coords.append((x + offset[0], y + offset[1], z + offset[2]))
    return coords


def _noise(length, scale, seed=3):
    """What an EARLY captured frame actually looks like: a cloud, not a backbone.

    The rollout's coordinates are the raw EDM iterate, whose schedule starts at
    `sigma_data` (16) x `s_max` (160) = 2560 A. A measured 24-residue live run put state 1
    across 153,687 A. Nothing at that scale is within bonding distance of anything.
    """
    import random
    rng = random.Random(seed)
    return [tuple(rng.gauss(0, scale) for _ in range(3))
            for _ in range(length * len(_SLOTS))]


def _seed_pdb(length=3, chain='B', coords=None, conect=True):
    """The shape RFD3Trajectory.seedPDB emits: the FIRST captured frame, plus CONECT.

    `coords=None` means real backbone geometry. Pass explicit coordinates (a block of
    zeros, or `_noise(...)`) to reproduce what a degenerate or early seed does, and
    `conect=False` to reproduce what leaving connectivity to distance inference does.
    """
    if coords is None:
        coords = _backbone(length)
    lines = []
    serial = 1
    for residue in range(length):
        for slot, name in enumerate(_SLOTS):
            x, y, z = coords[residue * len(_SLOTS) + slot]
            lines.append(
                'ATOM  %5d  %-3s ALA %s%4d    %8.3f%8.3f%8.3f  1.00  0.00'
                '          %2s' % (serial, name, chain, residue + 1, x, y, z, name[0]))
            serial += 1
    lines.append('TER')
    if conect:
        for residue in range(length):
            base = residue * len(_SLOTS) + 1
            for first, second in (('N', 'CA'), ('CA', 'C'), ('C', 'O'), ('CA', 'CB')):
                lines.append('CONECT%5d%5d' % (base + _SLOTS.index(first),
                                               base + _SLOTS.index(second)))
            if residue + 1 < length:
                lines.append('CONECT%5d%5d' % (base + _SLOTS.index('C'),
                                               base + len(_SLOTS)))
    lines.append('END')
    return '\n'.join(lines) + '\n'


def _flat(coords):
    """A frame as trajectory_frame takes it: flat, three floats per atom."""
    return [float(value) for xyz in coords for value in xyz]


def _depth(view, point):
    """How far `point` is from the camera along the view axis, in the same units as the
    clipping planes `view[15]` (near) and `view[16]` (far)."""
    rotation, origin = view[0:9], view[12:15]
    delta = [point[i] - origin[i] for i in range(3)]
    camera_z = (rotation[6] * delta[0] + rotation[7] * delta[1]
                + rotation[8] * delta[2])
    return -(camera_z + view[11])


class TrajectoryTest(GeneratorTestCase):

    def setUp(self):
        GeneratorTestCase.setUp(self)
        from pymol import designing
        self.designing = designing

    def testSeedingCreatesAOneStateObjectWithTheExpectedAtoms(self):
        self.designing.trajectory_seed('traj', _seed_pdb(length=3))
        self.assertIn('traj', cmd.get_names('objects'))
        self.assertEqual(cmd.count_atoms('traj'), 15)
        self.assertEqual(cmd.count_states('traj'), 1)

    def testEachFrameAppendsAStateAndTheAtomCountNeverChanges(self):
        # PyMOL states of one object share an atom set; a frame that changed it would be
        # rejected, and a trajectory that grew atoms would not be scrubbable.
        self.designing.trajectory_seed('traj', _seed_pdb(length=2))
        for step in range(1, 6):
            coords = [float(step)] * 30          # 10 atoms x 3
            self.designing.trajectory_frame('traj', coords)
        self.assertEqual(cmd.count_states('traj'), 6)
        self.assertEqual(cmd.count_atoms('traj'), 10)

    def testAFrameActuallyMovesTheAtoms(self):
        # Coordinates are intentionally distinct per atom: load_coordset loads in the
        # original atom order the seed PDB wrote, and a uniform frame (all atoms identical)
        # would make the assertions order-blind -- they would pass even if atoms were
        # silently permuted.  With range(15), atom 0 expects [0,1,2] and atom 2 (an
        # interior atom) expects [6,7,8]; a misordering yields a wrong value, not a
        # coincidentally-right one.
        self.designing.trajectory_seed('traj', _seed_pdb(length=1))
        self.designing.trajectory_frame('traj', [float(i) for i in range(15)])
        model = cmd.get_model('traj', state=2)
        self.assertAlmostEqual(model.atom[0].coord[0], 0.0, places=3)
        self.assertAlmostEqual(model.atom[0].coord[2], 2.0, places=3)
        # Interior atom -- the load order contract is violated if this is wrong.
        self.assertAlmostEqual(model.atom[2].coord[0], 6.0, places=3)
        self.assertAlmostEqual(model.atom[2].coord[2], 8.0, places=3)

    def testAFrameForAnUnknownObjectIsANoOpNotAnError(self):
        # The user may delete the object mid-run, which is legitimate. Live view must
        # degrade to nothing rather than raise into a running design.
        self.designing.trajectory_frame('nosuchobject', [1.0, 2.0, 3.0])
        self.assertNotIn('nosuchobject', cmd.get_names('objects'))

    def testAWrongLengthFrameIsDroppedRatherThanCorrupting(self):
        # The RETURN VALUE is the observable, not the state count: the C++ layer refuses
        # both of these frames on its own, so count_states stays 1 even with both guards
        # in trajectory_frame deleted. Asserting the refusal is what makes this test able
        # to fail -- a frame that reached load_coordset would return True.
        self.designing.trajectory_seed('traj', _seed_pdb(length=2))
        self.assertFalse(
            self.designing.trajectory_frame('traj', [1.0, 2.0]),   # not a multiple of 3
            'a frame that is not three floats per atom must be refused')
        self.assertFalse(
            self.designing.trajectory_frame('traj', [1.0] * 300),  # wrong atom count
            'a frame with the wrong atom count must be refused')
        self.assertEqual(cmd.count_states('traj'), 1)

    # -- What the user actually sees -----------------------------------------

    def testSeedingLeavesTheCameraExactlyWhereTheUserPutIt(self):
        # The whole point of the feature is watching the design. `read_pdbstr` inherits
        # zoom=-1 -> auto_zoom, which is ON by default, and the trajectory object is brand
        # new on every run, so without zoom=0 the camera is yanked onto a chain that is
        # still noise and the target the user was looking at ends up OUTSIDE the clipping
        # slab -- a blank viewport for the rest of a multi-minute run.
        cmd.fab('A' * 30, 'target', ss=1)
        cmd.translate([100.0, 100.0, 100.0], object='target', camera=0)
        cmd.orient('target')
        before = cmd.get_view()
        extent = cmd.get_extent('target')
        centre = [(extent[0][i] + extent[1][i]) / 2.0 for i in range(3)]
        self.assertTrue(before[15] <= _depth(before, centre) <= before[16],
                        'the fixture must start with the target inside the slab')

        self.designing.trajectory_seed('traj', _seed_pdb(length=12))

        after = cmd.get_view()
        for index, (was, now) in enumerate(zip(before, after)):
            self.assertAlmostEqual(was, now, places=4,
                                   msg='view[%d] moved: %r -> %r' % (index, was, now))
        # Stated as the consequence as well as the cause, because "the camera moved" is
        # only a bug because of this.
        self.assertTrue(after[15] <= _depth(after, centre) <= after[16],
                        'the target fell out of the clipping slab (%.2f not in %.2f-%.2f)'
                        % (_depth(after, centre), after[15], after[16]))

    def testTheSeededObjectHasItsBackboneBondsAndKeepsThem(self):
        # PyMOL infers connectivity ONCE, at read_pdbstr time; load_coordset moves atoms
        # and never re-bonds. So the seed is the only chance this object gets, and without
        # bonds every state -- including the converged one the user scrubs to -- renders as
        # 120 disconnected crosses with no backbone. A 24-residue design is 120 atoms and
        # 119 bonds: four within each residue (N-CA, CA-C, C-O, CA-CB) and 23 peptide
        # bonds between them.
        self.designing.trajectory_seed('traj', _seed_pdb(length=24))
        self.assertEqual(cmd.count_atoms('traj'), 120)
        bonds = len(cmd.get_model('traj').bond)
        self.assertEqual(bonds, 119)
        self.designing.trajectory_frame('traj', _flat(_backbone(24, offset=(5, 0, 0))))
        self.assertEqual(cmd.count_states('traj'), 2)
        self.assertEqual(len(cmd.get_model('traj').bond), bonds)

    def testAnEarlyFrameStillBondsBecauseTheSeedSaysSo(self):
        # THE case that matters, and the one real coordinates alone do not cover: the
        # first captured frame is step 4 of 199 of a schedule that starts at 2560 A, and a
        # measured live run put state 1 across 153,687 A. Distance inference bonds nothing
        # at that scale -- the CONECT records in the seed are the only reason the object
        # ever has a backbone.
        self.designing.trajectory_seed('traj',
                                       _seed_pdb(length=24, coords=_noise(24, 5000.0)))
        self.assertEqual(len(cmd.get_model('traj').bond), 119)

    def testWithoutStatedBondsAnEarlyFrameHasNoneAtAll(self):
        # The negative control for the two tests above: same atoms, same coordinates, no
        # CONECT. Kept so "119" is known to be a property of what the seed SAYS rather
        # than something PyMOL would have produced from the coordinates anyway.
        self.designing.trajectory_seed(
            'cloud', _seed_pdb(length=24, coords=_noise(24, 5000.0), conect=False))
        self.assertEqual(cmd.count_atoms('cloud'), 120)
        self.assertEqual(len(cmd.get_model('cloud').bond), 0)
        # And the defect this replaced: every atom at the origin, which refuses every bond
        # whether or not the coordinates are real.
        zeros = [(0.0, 0.0, 0.0)] * (24 * len(_SLOTS))
        self.designing.trajectory_seed('zeros',
                                       _seed_pdb(length=24, coords=zeros, conect=False))
        self.assertEqual(len(cmd.get_model('zeros').bond), 0)

    def testReseedingReplacesThePreviousRunRatherThanAppendingToIt(self):
        # Re-running a named design with Live on hits this: read_pdbstr into an EXISTING
        # object APPENDS states, so without the delete the new run's first frame would land
        # as state 5 of the old run's trajectory and the user would scrub through two
        # designs spliced together.
        self.designing.trajectory_seed('traj', _seed_pdb(length=2))
        for _ in range(3):
            self.designing.trajectory_frame('traj', _flat(_backbone(2)))
        self.assertEqual(cmd.count_states('traj'), 4)

        self.designing.trajectory_seed('traj', _seed_pdb(length=2))
        self.assertEqual(cmd.count_states('traj'), 1)
        self.assertEqual(cmd.count_atoms('traj'), 10)
    # -- The name the caller uses vs. the name PyMOL creates -------------------
    #
    # PyMOL legalises an object name on creation: an apostrophe, a space and a forward
    # slash all become underscores. The caller does not see that happen -- it holds the
    # name it asked for, and every frame addresses THAT. Seeding under one name while
    # framing under another leaves a seeded object that never moves, and because both
    # functions swallow their failures by design, nothing is printed anywhere.

    def testAFrameLandsWhenPyMOLRewroteTheSeededName(self):
        # The regression. Each of these names is rewritten on creation, so the frame's
        # own lookup is the thing under test: it must find the object the seed made.
        for raw in ("it's_a_traj", 'my design_traj', 'a/b_traj'):
            cmd.delete('all')
            self.assertTrue(self.designing.trajectory_seed(raw, _seed_pdb(length=2)))
            created = cmd.get_names('objects')
            self.assertEqual(len(created), 1)
            # Precondition: this name really is one PyMOL rewrites. If PyMOL ever stopped
            # rewriting it the test would still pass below for the wrong reason.
            self.assertNotEqual(created[0], raw)
            self.assertTrue(self.designing.trajectory_frame(raw, [1.0] * 30))
            self.assertEqual(cmd.count_states(created[0]), 2)

    def testTheRewrittenObjectActuallyReceivesTheCoordinates(self):
        # Not just "a state appeared" -- the atoms of the object the seed created must be
        # the ones that moved.
        cmd.delete('all')
        self.designing.trajectory_seed('my design_traj', _seed_pdb(length=1))
        created = cmd.get_names('objects')[0]
        self.designing.trajectory_frame('my design_traj', [float(i) for i in range(15)])
        model = cmd.get_model(created, state=2)
        self.assertAlmostEqual(model.atom[0].coord[2], 2.0, places=3)
        self.assertAlmostEqual(model.atom[2].coord[0], 6.0, places=3)

    def testReseedingARewrittenNameReplacesRatherThanDuplicates(self):
        # trajectory_seed deletes an existing object before reading. That delete addresses
        # the caller's name too, so a re-seed under a rewritten name must not leave the
        # first object behind next to a second.
        cmd.delete('all')
        self.designing.trajectory_seed('my design_traj', _seed_pdb(length=2))
        self.designing.trajectory_seed('my design_traj', _seed_pdb(length=3))
        self.assertEqual(len(cmd.get_names('objects')), 1)
        self.assertEqual(cmd.count_atoms(cmd.get_names('objects')[0]), 15)
