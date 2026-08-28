"""The object a live design builds up, one state per captured frame.

There is ONE object, not two: live view builds the design's own object -- target and
generated chain, exactly what the result writer emits -- and the finished design arrives
as its last state. So the fixtures here are composed objects, not bare chains, and
`_seed_pdb` reproduces `RFD3ResultWriter.emit`'s layout: target atoms, a TER, then the
generated chain, then a TER, then CONECT, then END.

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
    """Real poly-ALA backbone coordinates, in RFD3Trajectory.seed's slot order.

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


def _jittered(length, sigma, seed=11):
    """What an EARLY captured frame actually looks like: protein-scale, but not settled.

    The stream is px0 -- the denoiser's prediction of the CLEAN structure at that step --
    so every captured frame is protein-scale (measured upstream: 33.9 A at step 1 of a
    50-step albumin rollout, against 6,904.6 A for the raw EDM iterate at the same step).
    What an early frame is NOT is a valid backbone, and that is the case these fixtures
    exist for: real geometry displaced atom-by-atom, so bond lengths are wrong by a
    plausible amount rather than by four orders of magnitude.
    """
    import random
    rng = random.Random(seed)
    return [tuple(value + rng.gauss(0, sigma) for value in point)
            for point in _backbone(length)]


def _cloud(length, scale, seed=3):
    """A protein-scale frame with no backbone left in it at all -- the limiting case of
    `_jittered`, kept because it is where distance inference degrades furthest."""
    import random
    rng = random.Random(seed)
    return [tuple(rng.gauss(0, scale) for _ in range(3))
            for _ in range(length * len(_SLOTS))]


#: Where the fixture target sits, well away from the generated chain so the two are
#: distinguishable by coordinate alone.
_TARGET_OFFSET = (-60.0, 0.0, 0.0)

#: The fixture target's residue name. NOT ALA, so "the generated chain was renamed and
#: the target was not" is an observable rather than a coincidence.
_TARGET_RESN = 'TRP'


def _atom_record(serial, name, resn, chain, resi, xyz):
    x, y, z = xyz
    return ('ATOM  %5d  %-3s %3s %s%4d    %8.3f%8.3f%8.3f  1.00  0.00          %2s'
            % (serial, name, resn, chain, resi, x, y, z, name[0]))


def _target_records(residues, serial, chain='A'):
    """The target half of a composed object: real geometry, its own chain and numbering.

    Five atoms a residue, the same slots the generated chain has -- a real target has
    sidechains too, but nothing here depends on that and reusing `_backbone` keeps the
    fixture's geometry real, which is what PyMOL bonds from.
    """
    lines = []
    if residues <= 0:
        return lines, serial
    coords = _backbone(residues, offset=_TARGET_OFFSET)
    for residue in range(residues):
        for slot, name in enumerate(_SLOTS):
            lines.append(_atom_record(serial, name, _TARGET_RESN, chain, residue + 41,
                                      coords[residue * len(_SLOTS) + slot]))
            serial += 1
    return lines, serial


def _composed_pdb(length=3, chain='B', coords=None, conect=True, target=0,
                  sequence=None, target_chain='A'):
    """What `RFD3ResultWriter.emit` writes: target, TER, generated chain, TER, END.

    ONE builder for the seed and for the result, because that is the property the feature
    rests on -- the finished design is appended to the live object by position, so the two
    have to be the same atoms in the same order. A fixture with two builders would let a
    divergence pass here that cannot happen in the shipped code.

    `sequence` names the generated residues; `None` means poly-ALA, which is what the seed
    is. `target` is a residue COUNT. Zero -- the default for the tests that are only about
    the generated chain -- still emits the leading `TER`, because `emit` does: the
    generated chain starts at serial 2 even with nothing in front of it.
    """
    if coords is None:
        coords = _backbone(length)
    lines, serial = _target_records(target, 1, chain=target_chain)
    lines.append('TER   %5d' % serial)
    serial += 1
    design_first = serial
    for residue in range(length):
        resn = sequence[residue] if sequence else 'ALA'
        for slot, name in enumerate(_SLOTS):
            lines.append(_atom_record(serial, name, resn, chain, residue + 1,
                                      coords[residue * len(_SLOTS) + slot]))
            serial += 1
    lines.append('TER   %5d' % serial)
    if conect:
        for residue in range(length):
            base = design_first + residue * len(_SLOTS)
            for first, second in (('N', 'CA'), ('CA', 'C'), ('C', 'O'), ('CA', 'CB')):
                lines.append('CONECT%5d%5d' % (base + _SLOTS.index(first),
                                               base + _SLOTS.index(second)))
            if residue + 1 < length:
                lines.append('CONECT%5d%5d' % (base + _SLOTS.index('C'),
                                               base + len(_SLOTS)))
    lines.append('END')
    return '\n'.join(lines) + '\n'


def _seed_pdb(length=3, chain='B', coords=None, conect=True, target=0,
              target_chain='A'):
    """The seed: the same object, with the generated chain poly-ALA."""
    return _composed_pdb(length=length, chain=chain, coords=coords, conect=conect,
                         target=target, target_chain=target_chain)


#: The three-letter names a fixture design comes back with -- anything but ALA, so
#: "the generated chain was renamed at delivery" is observable.
_DESIGNED = ('LEU', 'GLY', 'THR', 'VAL', 'PHE', 'SER', 'GLN', 'TYR')


def _result_pdb(length=3, chain='B', coords=None, target=0, target_chain='A'):
    """What the runtime writes at the end: the same object, real sequence, real
    coordinates, and no CONECT -- a result is loaded from a file PyMOL bonds itself."""
    sequence = [_DESIGNED[index % len(_DESIGNED)] for index in range(length)]
    return _composed_pdb(length=length, chain=chain, coords=coords, conect=False,
                         target=target, sequence=sequence, target_chain=target_chain)


class NoCoordsetCmd(object):
    """The `cmd` the SHIPPED APP has: `get_coordset` returns None.

    Not a hypothetical. `cmd.get_coordset` is numpy-backed, and in the packaged macOS app
    its `_cmd` has no such path and it returns None -- while the headless PyMOL this suite
    runs on returns a real array. A live run built on it therefore failed on every real
    design and passed every test: the seed threw, left no record, every frame was dropped,
    and delivery fell back to `cmd.load` ON TOP of the seeded object, taking a real 450-atom
    design to 530.

    Everything else proxies to the real `cmd`, so a test using this exercises the shipped
    code against the shipped app's one relevant difference.
    """

    def __init__(self, real):
        self._real = real

    def __getattr__(self, attribute):
        return getattr(self._real, attribute)

    def get_coordset(self, *args, **kwargs):
        return None


def _seed(designing, name, length=3, chain='B', coords=None, conect=True, target=0,
          _self=None, target_chain='A', keep=1):
    """`trajectory_seed` with the layout the writer would have reported.

    The offset and the atom count are arguments on the wire because the Python side must
    not have to work out where the generated chain starts -- so the fixture states them
    too, from the same two numbers that shaped the string.
    """
    return designing.trajectory_seed(
        name, _seed_pdb(length=length, chain=chain, coords=coords, conect=conect,
                        target=target, target_chain=target_chain),
        target * len(_SLOTS), length * len(_SLOTS), keep=keep,
        **({'_self': _self} if _self is not None else {}))


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
        _seed(self.designing, 'traj', length=3)
        self.assertIn('traj', cmd.get_names('objects'))
        self.assertEqual(cmd.count_atoms('traj'), 15)
        self.assertEqual(cmd.count_states('traj'), 1)

    def testEachFrameAppendsAStateAndTheAtomCountNeverChanges(self):
        # PyMOL states of one object share an atom set; a frame that changed it would be
        # rejected, and a trajectory that grew atoms would not be scrubbable.
        _seed(self.designing, 'traj', length=2)
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
        _seed(self.designing, 'traj', length=1)
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
        _seed(self.designing, 'traj', length=2)
        self.assertFalse(
            self.designing.trajectory_frame('traj', [1.0, 2.0]),   # not a multiple of 3
            'a frame that is not three floats per atom must be refused')
        self.assertFalse(
            self.designing.trajectory_frame('traj', [1.0] * 300),  # wrong atom count
            'a frame with the wrong atom count must be refused')
        self.assertEqual(cmd.count_states('traj'), 1)

    def testARaggedFrameIsRefusedEvenWhenItsAtomCountWouldPass(self):
        # ISOLATES the multiple-of-three guard, which nothing else covers. The case above
        # uses [1.0, 2.0]: 2 // 3 == 0, which the ATOM-COUNT guard on the next line already
        # refuses, so deleting the multiple-of-three guard alone leaves this suite green.
        #
        # 31 floats against a 10-atom object is the input that separates them: 31 % 3 == 1
        # so the multiple-of-three guard refuses it, but 31 // 3 == 10 so the atom-count
        # guard does NOT -- and without the first guard the trailing float is silently
        # dropped and a truncated frame is loaded as a state.
        _seed(self.designing, 'traj', length=2)
        self.assertEqual(cmd.count_atoms('traj'), 10)
        self.assertFalse(
            self.designing.trajectory_frame('traj', [1.0] * 31),
            'a ragged frame must be refused even when it rounds to the right atom count')
        self.assertEqual(cmd.count_states('traj'), 1)

    # -- What was written is what is read back --------------------------------

    def testStateOneReadsBackExactlyTheCoordinatesTheSeedWrote(self):
        # The assertion no test on this branch made, and the reason a nine-column
        # coordinate survived two review rounds: every earlier test checked the object's
        # SHAPE -- atom count, state count, bond count -- and none checked its NUMBERS.
        #
        # The PDB is fixed-column and `%8.3f` has a width minimum, not a maximum, so a
        # value needing nine characters shifts every field after it and is read back as
        # something else entirely. Extremes on purpose: these are the widest values the
        # format can hold, so a writer that is one character off fails here.
        coords = _backbone(4, offset=(-995.0, 9995.0, -995.0))
        _seed(self.designing, 'traj', length=4, coords=coords)
        model = cmd.get_model('traj', state=1)
        self.assertEqual(len(model.atom), 20)
        for index, atom in enumerate(model.atom):
            for axis in range(3):
                self.assertAlmostEqual(
                    atom.coord[axis], coords[index][axis], places=2,
                    msg='atom %d axis %d: wrote %r, read %r'
                        % (index, axis, coords[index][axis], atom.coord[axis]))

    def testANineColumnCoordinateIsReadBackAsSomethingElse(self):
        # The negative control for the round trip above, and the whole reason
        # RFD3ResultWriter.atomRecord refuses a coordinate outside -999.999..9999.999
        # rather than writing it: nothing raises, the line still looks like a PDB record,
        # and y and z are simply gone. Measured here rather than asserted from memory.
        self.assertEqual(len('%8.3f' % -1000.0), 9,
                         'the fixture must actually overflow the eight-column field')
        line = ('ATOM      1  N   ALA B   1    %8.3f%8.3f%8.3f  1.00  0.00           N'
                % (-1000.0, 1.0, 2.0))
        cmd.read_pdbstr(line + '\nTER\nEND\n', 'bad', zoom=0)
        read = list(cmd.get_model('bad').atom[0].coord)
        self.assertAlmostEqual(read[0], -1000.0, places=3)
        # y and z were pushed out of their columns and read as zero.
        self.assertAlmostEqual(read[1], 0.0, places=3)
        self.assertAlmostEqual(read[2], 0.0, places=3)

    def testAnAppendedFrameReadsBackExactlyWhatWasSent(self):
        # Same property for `load_coordset` rather than the PDB reader, at the same
        # extremes: a live view whose later states drifted from what the rollout produced
        # would be a recording of nothing.
        coords = _backbone(4, offset=(-995.0, 9995.0, -995.0))
        _seed(self.designing, 'traj', length=4)
        self.assertTrue(self.designing.trajectory_frame('traj', _flat(coords)))
        model = cmd.get_model('traj', state=2)
        for index, atom in enumerate(model.atom):
            for axis in range(3):
                self.assertAlmostEqual(atom.coord[axis], coords[index][axis], places=2)

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

        _seed(self.designing, 'traj', length=12)

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
        _seed(self.designing, 'traj', length=24)
        self.assertEqual(cmd.count_atoms('traj'), 120)
        bonds = len(cmd.get_model('traj').bond)
        self.assertEqual(bonds, 119)
        self.designing.trajectory_frame('traj', _flat(_backbone(24, offset=(5, 0, 0))))
        self.assertEqual(cmd.count_states('traj'), 2)
        self.assertEqual(len(cmd.get_model('traj').bond), bonds)

    def testAnEarlyFrameStillBondsBecauseTheSeedSaysSo(self):
        # THE case that matters. The seed is the FIRST captured frame -- step 4 of 199 --
        # and connectivity is decided from it once, for the life of the object. px0 makes
        # that frame protein-scale but not a settled backbone, so what distance inference
        # returns from it is a function of how unsettled it happens to be. The CONECT
        # records make the answer 119 regardless.
        for sigma in (1.0, 2.0, 3.0):
            cmd.delete('all')
            _seed(self.designing, 'traj', length=24, coords=_jittered(24, sigma))
            self.assertEqual(len(cmd.get_model('traj').bond), 119,
                             'stated bonds must not depend on how settled the frame is')
        cmd.delete('all')
        _seed(self.designing, 'traj', length=24, coords=_cloud(24, 9.0))
        self.assertEqual(len(cmd.get_model('traj').bond), 119)

    def testWithoutStatedBondsAnEarlyFrameGetsWhateverInferenceMakesOfIt(self):
        # The negative control for the test above: same atoms, same coordinates, no
        # CONECT. Kept so "119" is known to be a property of what the seed SAYS rather
        # than something PyMOL would have produced from the coordinates anyway -- and the
        # numbers here are the honest reason to state connectivity. Inference does not
        # fail loudly at px0 scale, it degrades. Measured with this fixture: 89 / 54 / 37
        # of the 119 backbone bonds at 1 / 2 / 3 A of per-atom jitter, and 5 for a
        # protein-scale cloud. The object then renders with most of its backbone missing,
        # in every state including the converged one, and into any .pse saved from it.
        #
        # The COUNTS are not asserted, because they are properties of PyMOL's bonding
        # heuristic rather than of this feature. What is asserted is the property those
        # counts demonstrate: inference is short of the backbone and depends on how
        # settled the frame is, where the stated records are 119 regardless.
        inferred = {}
        for sigma in (1.0, 2.0, 3.0):
            cmd.delete('all')
            _seed(self.designing, 'traj', length=24, conect=False,
                  coords=_jittered(24, sigma))
            inferred[sigma] = len(cmd.get_model('traj').bond)
        for sigma, count in inferred.items():
            self.assertLess(count, 119,
                            'inference at %.1f A of jitter must fall short of the '
                            'backbone (got %d)' % (sigma, count))
        self.assertGreater(len(set(inferred.values())), 1,
                           'inferred connectivity must depend on how settled the frame '
                           'is -- that dependence is why it is stated instead')
        cmd.delete('all')
        _seed(self.designing, 'cloud', length=24, coords=_cloud(24, 9.0), conect=False)
        self.assertEqual(cmd.count_atoms('cloud'), 120)
        self.assertLess(len(cmd.get_model('cloud').bond), 20)
        # And the defect this replaced: every atom at the origin, which refuses every bond
        # whether or not the coordinates are real.
        zeros = [(0.0, 0.0, 0.0)] * (24 * len(_SLOTS))
        _seed(self.designing, 'zeros', length=24, coords=zeros, conect=False)
        self.assertEqual(len(cmd.get_model('zeros').bond), 0)

    def testSettledGeometryIsNotDoubleBondedByTheStatedRecords(self):
        # CONECT is MERGED with what PyMOL would have inferred, not added to it. Worth
        # pinning, because the converged states are the ones the user looks at longest and
        # a doubled bond set would render as thickened, mis-ordered sticks.
        _seed(self.designing, 'stated', length=24)
        _seed(self.designing, 'inferred', length=24, conect=False)
        self.assertEqual(len(cmd.get_model('stated').bond), 119)
        self.assertEqual(len(cmd.get_model('inferred').bond), 119)

    def testReseedingReplacesThePreviousRunRatherThanAppendingToIt(self):
        # Re-running a named design with Live on hits this: read_pdbstr into an EXISTING
        # object APPENDS states, so without the delete the new run's first frame would land
        # as state 5 of the old run's trajectory and the user would scrub through two
        # designs spliced together.
        _seed(self.designing, 'traj', length=2)
        for _ in range(3):
            self.designing.trajectory_frame('traj', _flat(_backbone(2)))
        self.assertEqual(cmd.count_states('traj'), 4)

        _seed(self.designing, 'traj', length=2)
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
            self.assertTrue(_seed(self.designing, raw, length=2))
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
        _seed(self.designing, 'my design_traj', length=1)
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
        _seed(self.designing, 'my design_traj', length=2)
        _seed(self.designing, 'my design_traj', length=3)
        self.assertEqual(len(cmd.get_names('objects')), 1)
        self.assertEqual(cmd.count_atoms(cmd.get_names('objects')[0]), 15)


class LiveObjectTest(GeneratorTestCase):
    """ONE object: the design's own, built up live and finished in place.

    The behaviour the tests above cover in pieces, asserted end to end on what the user
    can actually see -- how many objects there are, which state is displayed, what the
    residues are called, and whether the numbers in the last state are the design's.
    """

    #: Residues of target and of generated chain in the fixtures below. 4 and 2 give a
    #: 20-atom target and a 10-atom chain, so a frame sized for the WHOLE object (30) is
    #: a different number from a frame sized for the chain (10) and the guard can be
    #: told apart from no guard.
    TARGET = 4
    LENGTH = 2

    def setUp(self):
        import shutil
        import tempfile
        GeneratorTestCase.setUp(self)
        from pymol import designing
        self.designing = designing
        self.name = 'rfd3_design_ab12cd34'
        self._tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self._tmp, True)
        self._files = 0

    def tempfile(self):
        self._files += 1
        return os.path.join(self._tmp, 'result_%d.pdb' % self._files)

    def seed(self, coords=None):
        return _seed(self.designing, self.name, length=self.LENGTH, coords=coords,
                     target=self.TARGET)

    def result_path(self, coords=None):
        """A finished design on disk, laid out exactly as the seed was."""
        path = self.tempfile()
        with open(path, 'w') as handle:
            handle.write(_result_pdb(length=self.LENGTH, target=self.TARGET,
                                     coords=coords))
        return path

    @property
    def target_atoms(self):
        return self.TARGET * len(_SLOTS)

    @property
    def design_atoms(self):
        return self.LENGTH * len(_SLOTS)

    def displayed_state(self, name=None):
        """Which state the OBJECT shows -- `CObject::getCurrentState`'s own precedence.

        Not `cmd.get_state()`. That is the global movie frame, which an object consults
        only as a fallback, so it agrees with reality exactly until the session has an
        `mset` -- and then stops, silently. Asserting on it is what let a live view that
        never moved pass every test.
        """
        return int(cmd.get('state', name or self.name))

    def chain_coords(self, chain, state):
        return [tuple(atom.coord)
                for atom in cmd.get_model('%s and chain %s' % (self.name, chain),
                                          state=state).atom]

    # -- What the object IS ---------------------------------------------------

    def testTheLiveObjectHoldsTheTargetAsWellAsTheGeneratedChain(self):
        # It is the RESULT's object, under the result's own name, holding what the result
        # holds -- which is what lets the finished design be appended to it instead of
        # loaded beside it.
        self.assertTrue(self.seed())
        self.assertEqual(cmd.get_names('objects'), [self.name])
        self.assertEqual(cmd.count_atoms(self.name),
                         self.target_atoms + self.design_atoms)
        self.assertEqual(cmd.count_atoms('%s and chain A' % self.name),
                         self.target_atoms)
        self.assertEqual(cmd.count_atoms('%s and chain B' % self.name),
                         self.design_atoms)

    def testNothingIsNamedWithATrajectorySuffix(self):
        # The regression for the two-object model this replaced. `<result>_traj` was a
        # second object in the session that carried no metrics and no design key.
        self.assertTrue(self.seed())
        self.designing.trajectory_frame(self.name, _flat(_backbone(self.LENGTH)))
        self.designing.deliver_result(self.result_path(), self.name)
        self.assertEqual(cmd.get_names('objects'), [self.name])
        self.assertNotIn('%s_traj' % self.name, cmd.get_names('objects'))

    def testTheGeneratedChainIsNeverBondedToTheTarget(self):
        # The one hazard the target and the design sharing an object introduces, and it
        # is permanent when it fires: PyMOL decides connectivity ONCE, from the first
        # captured frame, which is step 4 of 199. A generated chain is MEANT to sit
        # against the target, so an early frame routinely puts its atoms within bonding
        # distance of target atoms -- and the phantom sticks joining the two would then be
        # drawn in every state, including the delivered one, and saved into any .pse.
        overlapping = _backbone(self.LENGTH, offset=_TARGET_OFFSET)

        # Across BOTH orderings. 'A'/'B' is the pairing where PyMOL's sorted order happens
        # to agree with the file's; 'H'/'B' is the one where the design sorts FIRST, so an
        # unbond addressed by `index` takes a slice that spans both chains and misses the
        # bonds it was aimed at. Only the second can tell `rank` from `index`.
        for target_chain, design_chain in (('A', 'B'), ('H', 'B')):
            cmd.delete('all')
            self.designing._TRAJECTORY.clear()
            label = 'target %s / design %s' % (target_chain, design_chain)

            # PRECONDITION, so this test can fail: the same string read WITHOUT the fix
            # does produce inter-chain bonds. Without this the assertion below would pass
            # on a fixture that simply never overlapped.
            raw = _seed_pdb(length=self.LENGTH, chain=design_chain, coords=overlapping,
                            target=self.TARGET, target_chain=target_chain)
            cmd.read_pdbstr(raw, 'unfixed', zoom=0)
            self.assertGreater(self._inter_chain_bonds('unfixed'), 0,
                               '%s: the fixture must put the chains in contact' % label)
            cmd.delete('unfixed')

            self.assertTrue(_seed(self.designing, self.name, length=self.LENGTH,
                                  chain=design_chain, coords=overlapping,
                                  target=self.TARGET, target_chain=target_chain), label)
            self.assertEqual(self._inter_chain_bonds(self.name), 0, label)
            # And the generated chain still has its own backbone: the unbond must take the
            # inter-chain bonds and nothing else.
            self.assertEqual(
                len(cmd.get_model('%s and chain %s'
                                  % (self.name, design_chain)).bond),
                4 * self.LENGTH + (self.LENGTH - 1), label)

    def _inter_chain_bonds(self, obj):
        model = cmd.get_model(obj)
        chains = [atom.chain for atom in model.atom]
        return sum(1 for bond in model.bond
                   if chains[bond.index[0]] != chains[bond.index[1]])

    # -- What a frame does ----------------------------------------------------

    def testAFrameMovesTheGeneratedChainAndLeavesTheTargetWhereItIs(self):
        # The frame on the wire carries the generated chain ONLY -- resending the target
        # fifty times would be pointless traffic -- so the target's half of every state is
        # spliced in from the seed. If the splice were off by anything the target would
        # jump, and the design would be posed against a structure that had moved.
        self.assertTrue(self.seed())
        before = self.chain_coords('A', 1)
        moved = _backbone(self.LENGTH, offset=(7.0, -3.0, 11.0))
        self.assertTrue(self.designing.trajectory_frame(self.name, _flat(moved)))
        self.assertEqual(cmd.count_states(self.name), 2)
        self.assertEqual(self.chain_coords('A', 2), before)
        for atom, expected in zip(self.chain_coords('B', 2), moved):
            for axis in range(3):
                self.assertAlmostEqual(atom[axis], expected[axis], places=3)

    def testTheDisplayedStateFollowsEveryFrame(self):
        # The thing the user asked for: the object progresses as it is built, rather than
        # sitting on state 1 while fifty more appear behind it.
        self.assertTrue(self.seed())
        for expected in range(2, 7):
            self.assertTrue(
                self.designing.trajectory_frame(self.name, _flat(_backbone(self.LENGTH))))
            self.assertEqual(cmd.count_states(self.name), expected)
            self.assertEqual(self.displayed_state(), expected,
                             'the displayed state must follow the frame that just landed')

    def testAFrameSizedForTheWHOLEObjectIsRefused(self):
        # The guard's arithmetic changed with the object: it compares against the
        # GENERATED CHAIN's atom count, not the object's. A frame carrying 30 atoms --
        # what the whole object holds -- is not a frame, and accepting it would put target
        # coordinates on the generated chain.
        self.assertTrue(self.seed())
        whole = self.target_atoms + self.design_atoms
        self.assertEqual(cmd.count_atoms(self.name), whole)
        self.assertFalse(
            self.designing.trajectory_frame(self.name, [1.0] * (whole * 3)),
            'a frame sized for the whole object must be refused')
        self.assertEqual(cmd.count_states(self.name), 1)
        # And the positive control, so this is not passing because everything is refused.
        self.assertTrue(
            self.designing.trajectory_frame(self.name, [1.0] * (self.design_atoms * 3)))

    def testAFrameIsRefusedOnceTheObjectIsNoLongerTheShapeTheSeedRecorded(self):
        # The user can edit the object mid-run. Splicing into a shape that has changed
        # would misplace every atom rather than fail.
        self.assertTrue(self.seed())
        cmd.remove('%s and chain A and resi 41' % self.name)
        self.assertNotEqual(cmd.count_atoms(self.name),
                            self.target_atoms + self.design_atoms)
        self.assertFalse(
            self.designing.trajectory_frame(self.name,
                                            _flat(_backbone(self.LENGTH))))

    # -- What delivery does ---------------------------------------------------

    def testDeliveryAppendsTheDesignAsTheFinalStateAndShowsIt(self):
        self.assertTrue(self.seed())
        for _ in range(3):
            self.designing.trajectory_frame(self.name, _flat(_backbone(self.LENGTH)))
        atoms = cmd.count_atoms(self.name)
        bonds = len(cmd.get_model(self.name).bond)
        states = cmd.count_states(self.name)

        final = _backbone(self.LENGTH, offset=(2.5, -6.0, 0.5))
        self.designing.deliver_result(self.result_path(coords=final), self.name)

        self.assertEqual(cmd.count_states(self.name), states + 1)
        # `cmd.load` into an existing object does NOT merge: with the residue names
        # changing under it, it took a 450-atom object to 530. This is that regression.
        self.assertEqual(cmd.count_atoms(self.name), atoms)
        self.assertEqual(len(cmd.get_model(self.name).bond), bonds)
        self.assertEqual(self.displayed_state(), cmd.count_states(self.name),
                         'the finished design must be the state on show')
        for atom, expected in zip(self.chain_coords('B', cmd.count_states(self.name)),
                                  final):
            for axis in range(3):
                self.assertAlmostEqual(atom[axis], expected[axis], places=3)

    def testDeliveryRenamesTheGeneratedChainToTheDesignedSequence(self):
        # Residue names in PyMOL are per-OBJECT, not per-state, so this renames every
        # state -- which is the honest outcome: the object's residues ARE the design's,
        # and poly-ALA was only ever a stand-in while the sequence head was still moving.
        # The TARGET's names must not move with them.
        self.assertTrue(self.seed())
        self.designing.trajectory_frame(self.name, _flat(_backbone(self.LENGTH)))
        before = []
        cmd.iterate('%s and chain B and name CA' % self.name, 'L.append(resn)',
                    space={'L': before})
        self.assertEqual(before, ['ALA'] * self.LENGTH)

        self.designing.deliver_result(self.result_path(), self.name)

        after = []
        cmd.iterate('%s and chain B and name CA' % self.name, 'L.append(resn)',
                    space={'L': after})
        self.assertEqual(after,
                         [_DESIGNED[i % len(_DESIGNED)] for i in range(self.LENGTH)])
        target_names = set()
        cmd.iterate('%s and chain A' % self.name, 'S.add(resn)',
                    space={'S': target_names})
        self.assertEqual(target_names, {_TARGET_RESN})

    def testDeliveryFallsBackToAPlainLoadWhenTheRecordingCannotBeFinished(self):
        # Live view may cost the recording; it may never cost the design. A recording that
        # no longer lines up with the result is thrown away and the result is loaded
        # exactly as a non-live run loads it -- and NOT on top of the recording, which
        # would double the atoms.
        self.assertTrue(self.seed())
        self.designing.trajectory_frame(self.name, _flat(_backbone(self.LENGTH)))
        # A result with a different number of residues than the recording has atoms for.
        path = self.tempfile()
        with open(path, 'w') as handle:
            handle.write(_result_pdb(length=self.LENGTH + 3, target=self.TARGET))

        self.designing.deliver_result(path, self.name)

        self.assertEqual(cmd.get_names('objects'), [self.name])
        self.assertEqual(cmd.count_atoms(self.name),
                         self.target_atoms + (self.LENGTH + 3) * len(_SLOTS))
        self.assertEqual(cmd.count_states(self.name), 1)

    def testAPlainDeliveryIsUntouchedByAnyOfThis(self):
        # live_view=0: no recording, a placeholder, one `cmd.load`, one state. The
        # control for everything above.
        self.designing.register_pending(self.name, 'job-1')
        self.assertEqual(cmd.count_atoms(self.name), 0)
        self.designing.deliver_result(self.result_path(), self.name)
        self.assertEqual(cmd.get_names('objects'), [self.name])
        self.assertEqual(cmd.count_states(self.name), 1)
        self.assertEqual(cmd.count_atoms(self.name),
                         self.target_atoms + self.design_atoms)
        self.assertNotIn(self.name, self.designing.pending_objects())

    def testTheWholeRunWorksWithoutTheNumpyBackedCoordinateReader(self):
        # THE regression, and the reason a live run can fail while every test passes:
        # `cmd.get_coordset` returns None in the packaged app and an array under the
        # headless PyMOL this suite runs on. Built on it, the seed threw, left no record,
        # dropped all fifty frames, and delivery fell back to `cmd.load` on top of the
        # seeded object -- measured on a real design, 450 atoms became 530.
        #
        # So the whole flow runs here against a `cmd` that behaves like the app's.
        fake = NoCoordsetCmd(cmd)
        self.assertIsNone(fake.get_coordset(self.name, 1), 'the fake must be faithful')

        self.assertTrue(_seed(self.designing, self.name, length=self.LENGTH,
                              target=self.TARGET, _self=fake))
        for _ in range(3):
            self.assertTrue(
                self.designing.trajectory_frame(self.name,
                                                _flat(_backbone(self.LENGTH)),
                                                _self=fake))
        self.assertEqual(cmd.count_states(self.name), 4)

        final = _backbone(self.LENGTH, offset=(2.5, -6.0, 0.5))
        self.designing.deliver_result(self.result_path(coords=final), self.name,
                                      _self=fake)
        self.assertEqual(cmd.count_states(self.name), 5)
        self.assertEqual(cmd.count_atoms(self.name),
                         self.target_atoms + self.design_atoms)
        for atom, expected in zip(self.chain_coords('B', 5), final):
            for axis in range(3):
                self.assertAlmostEqual(atom[axis], expected[axis], places=3)

    def testASeedWhosePDBDoesNotMatchTheStatedLayoutLeavesNothing(self):
        # The layout is the writer's word; if the string does not back it up there is no
        # live view AND no half-seeded object under the design's name -- the same rule a
        # cancelled run follows, for the same reason.
        self.assertFalse(self.designing.trajectory_seed(
            self.name, _seed_pdb(length=self.LENGTH, target=self.TARGET),
            self.target_atoms, self.design_atoms + 5))
        self.assertNotIn(self.name, cmd.get_names('objects'))
        self.assertNotIn(self.name, self.designing._TRAJECTORY)

    def _bond_list(self, obj):
        """Every bond as `(rank, rank, order)`, sorted. ORDER included on purpose.

        Counting bonds is what missed this: a bond set can match in size and still
        describe different chemistry.
        """
        ranks = []
        cmd.iterate(obj, 'L.append(rank)', space={'L': ranks})
        model = cmd.get_model(obj)
        return sorted((min(ranks[b.index[0]], ranks[b.index[1]]),
                       max(ranks[b.index[0]], ranks[b.index[1]]), b.order)
                      for b in model.bond)

    def testADeliveredLiveObjectHasEXACTLYAPLAINRUNSBONDS(self):
        # A delivered design's CHEMISTRY must not depend on a view-only checkbox.
        #
        # The seed states connectivity with CONECT records, and a plain CONECT is order
        # ONE. The result file carries no CONECT, so a plain run INFERS the generated
        # chain's carbonyls as DOUBLE bonds. Nothing re-derived them, so the same design
        # came out with C=O order 2 without Live and order 1 with it -- measured on an
        # 8-residue design, 8 double bonds on the generated chain against 0. `valence` is
        # on by default and the wire and cylinder renderers branch on `b->order`, so it
        # was visible, and it persisted into any saved session.
        #
        # Bond LIST including orders, not bond count: the counts matched in some fixtures
        # while every carbonyl in the design was wrong.
        final = _backbone(self.LENGTH, offset=(2.5, -6.0, 0.5))
        path = self.result_path(coords=final)

        self.designing.register_pending('plain_run', 'job-plain')
        self.designing.deliver_result(path, 'plain_run')
        plain = self._bond_list('plain_run')

        # Seeded from an UNSETTLED frame, which is what a real seed is (step 4 of 199).
        # It also pins WHICH state the re-derivation must use: rebonding from state 1
        # here would bond a cloud, so a fix that re-derived from the wrong state would
        # fail this and not just look tidy.
        self.assertTrue(self.seed(coords=_cloud(self.LENGTH, 9.0)))
        for _ in range(3):
            self.designing.trajectory_frame(self.name, _flat(_jittered(self.LENGTH, 2.0)))
        self.designing.deliver_result(path, self.name)
        live = self._bond_list(self.name)

        self.assertEqual(live, plain,
                         'a live-built design must have a plain run\'s exact bonds, '
                         'orders included')
        # Named explicitly, because equality above would also hold if BOTH were wrong.
        design_doubles = len([1 for a, b, o in plain
                              if o == 2 and a >= self.target_atoms])
        self.assertEqual(design_doubles, self.LENGTH,
                         'the fixture must really have one carbonyl per designed residue')
        self.assertEqual(len([1 for a, b, o in live
                              if o == 2 and a >= self.target_atoms]), self.LENGTH)
        # And no bond joining the two chains survives on the settled geometry.
        self.assertEqual(self._inter_chain_bonds(self.name), 0)

    def testDeliveryRefusesAnObjectThisRunDidNotSeed(self):
        # The identity check is applied at DELIVERY as well as per frame. Counting alone
        # cannot see this -- an impostor matches on atoms exactly -- and delivery would
        # otherwise append a state to the user's reopened saved design and rename its
        # residues, a silent rewrite of an object this run does not own.
        self.assertTrue(self.seed())
        self.designing.trajectory_frame(self.name, _flat(_backbone(self.LENGTH)))
        cmd.delete(self.name)
        cmd.read_pdbstr(_result_pdb(length=self.LENGTH, target=self.TARGET,
                                    coords=_backbone(self.LENGTH, offset=(9.0, 0, 0))),
                        self.name, zoom=0)
        before = []
        cmd.iterate('%s and chain B and name CA' % self.name, 'L.append(resn)',
                    space={'L': before})

        self.designing.deliver_result(self.result_path(), self.name)

        # It went down the plain path: one state, the design the name promises, and the
        # impostor was NOT appended to or renamed in place.
        self.assertEqual(cmd.count_states(self.name), 1)
        self.assertEqual(cmd.count_atoms(self.name),
                         self.target_atoms + self.design_atoms)
        # The counts above are satisfied by the impostor ITSELF, so they cannot tell
        # "replaced by the design" from "left alone". COORDINATES can, and only they:
        # the impostor is a delivered design too, so it already carries the designed
        # SEQUENCE -- `before` and `after` are equal and prove nothing. It was built 9 A
        # away precisely so the two are distinguishable by position.
        after = []
        cmd.iterate('%s and chain B and name CA' % self.name, 'L.append(resn)',
                    space={'L': after})
        self.assertEqual(after, before)          # the sequence is NOT the discriminator
        self.assertAlmostEqual(
            cmd.get_model('%s and chain B and name CA' % self.name).atom[0].coord[0],
            _backbone(self.LENGTH)[1][0], places=3,
            msg='delivery left the impostor in place instead of replacing it')

    # -- The interpolation itself, which is pure arithmetic --------------------

    def testTheENDPOINTSAreExactBitForBit(self):
        # The whole design rests on the model's own coordinates never being approximated.
        # `a + (b - a) * t` is NOT bit-for-bit `a` at t=0 nor `b` at t=1 in floating
        # point, so both ends are returned by copy instead of computed.
        from pymol import designing
        start = [[0.1, 0.2, 0.3], [-7.7, 1e-8, 12345.6789]]
        end = [[9.9, -3.3, 0.0], [0.30000000000000004, 2.5, -1e-9]]
        self.assertEqual(designing.interpolate_frame(start, end, 0.0), start)
        self.assertEqual(designing.interpolate_frame(start, end, 1.0), end)
        # Out of range clamps to the endpoints rather than extrapolating past a
        # coordinate the model produced.
        self.assertEqual(designing.interpolate_frame(start, end, -5.0), start)
        self.assertEqual(designing.interpolate_frame(start, end, 99.0), end)
        # And it is a copy, so a caller cannot mutate the record through it.
        out = designing.interpolate_frame(start, end, 0.0)
        out[0][0] = 999.0
        self.assertEqual(start[0][0], 0.1)

    def testTheMidpointIsTheMidpointAndMotionIsMonotonic(self):
        from pymol import designing
        start = [[0.0, 0.0, 0.0]]
        end = [[10.0, -20.0, 5.0]]
        self.assertEqual(designing.interpolate_frame(start, end, 0.5),
                         [[5.0, -10.0, 2.5]])
        previous = None
        for step in range(0, 101):
            point = designing.interpolate_frame(start, end, step / 100.0)[0]
            if previous is not None:
                self.assertGreaterEqual(point[0], previous[0])
                self.assertLessEqual(point[1], previous[1])
                self.assertGreaterEqual(point[2], previous[2])
            previous = point

    def testDegenerateInterpolationsDegradeRatherThanCorrupt(self):
        from pymol import designing
        frame = [[1.0, 2.0, 3.0]]
        # Identical consecutive frames: every fraction is that frame.
        for fraction in (0.0, 0.25, 0.5, 1.0):
            self.assertEqual(designing.interpolate_frame(frame, frame, fraction), frame)
        # Mismatched atom counts, and empty: no smoothing rather than a mis-shaped state.
        self.assertEqual(designing.interpolate_frame(frame, frame + frame, 0.5), [])
        self.assertEqual(designing.interpolate_frame([], [], 0.5), [])
        self.assertEqual(designing.interpolate_frame([], frame, 0.5), [])

    def testTheDisplayFractionIsTimeBasedAndSaturates(self):
        from pymol import designing
        self.assertEqual(designing.display_fraction(0.0, 1.0), 0.0)
        self.assertEqual(designing.display_fraction(0.5, 1.0), 0.5)
        self.assertEqual(designing.display_fraction(1.0, 1.0), 1.0)
        # Saturates rather than extrapolating: a late next frame means the display waits
        # on the newest captured one, never past it.
        self.assertEqual(designing.display_fraction(9.0, 1.0), 1.0)
        self.assertEqual(designing.display_fraction(-1.0, 1.0), 0.0)
        # Degenerate gaps mean "just show the newest", not a divide by zero.
        for gap in (0, -1, None, 'x'):
            self.assertEqual(designing.display_fraction(0.5, gap), 1.0)

    # -- Smooth motion by rewriting ONE display state -------------------------

    def _state_coords(self, state):
        return [tuple(a.coord)
                for a in cmd.get_model(self.name, state=state).atom]

    def _capture(self, coords, smooth=1):
        return self.designing.trajectory_frame(self.name, _flat(coords),
                                               advance=0, smooth=smooth)

    def testTheFirstCapturedFrameHasNothingToInterpolateFrom(self):
        # Defined behaviour at the near end: no predecessor, so no display state and no
        # animation -- the seed is simply shown. `trajectory_display` says so rather than
        # inventing a starting point.
        self.assertTrue(self.seed())
        self.assertIsNone(self.designing._TRAJECTORY[self.name]['display_state'])
        self.assertFalse(self.designing.trajectory_display(self.name))
        self.assertEqual(cmd.count_states(self.name), 1)
        self.assertEqual(self.displayed_state(), 1)

    def testTheDISPLAYSTATEISNEVERSTATEONEWhenFramesAreKept(self):
        # With frames kept, states 1..N are model output and the display sits after them,
        # so it must never land on state 1. (With `keep_frames=0` it deliberately IS
        # state 1 -- there are no captured states for it to sit after -- which is why the
        # identity check follows what was last WRITTEN rather than the seed.)
        self.assertTrue(self.seed())
        for step in range(4):
            self._capture(_backbone(self.LENGTH, offset=(step, 0, 0)))
            display = self.designing._TRAJECTORY[self.name]['display_state']
            if display is not None:
                self.assertGreaterEqual(display, 3, 'step %d' % step)
            # And the identity check still passes at every point.
            self.assertTrue(self.designing._holds_our_writes(
                self.name, self.designing._TRAJECTORY[self.name]))

    def testACAPTUREDSTATEISNEVERMODIFIEDAFTERITLANDS(self):
        # THE invariant this whole approach exists for. States 1..N are model output; the
        # smoothing rewrites one extra state and must never reach back into them. Checked
        # by keeping every captured frame's coordinates and re-reading them after a run's
        # worth of display rewrites.
        self.assertTrue(self.seed())
        captured = {1: self._state_coords(1)}
        for step in range(1, 6):
            self.assertTrue(self._capture(_backbone(self.LENGTH,
                                                    offset=(step * 3.0, 0, 0))))
            index = self.designing._TRAJECTORY[self.name]['captured']
            captured[index] = self._state_coords(index)
            # Animate that gap, the way the head would.
            for _ in range(8):
                self.designing.trajectory_display(self.name)
        for index, coords in captured.items():
            self.assertEqual(self._state_coords(index), coords,
                             'captured state %d was modified by the smoothing' % index)

    def testTheDisplayStateIsTheONLYThingTheAnimationTouches(self):
        # The other half of the invariant: it does move something, so the test above is
        # not passing because nothing happens at all.
        self.assertTrue(self.seed())
        self._capture(_backbone(self.LENGTH))
        self._capture(_backbone(self.LENGTH, offset=(10.0, 0, 0)))
        display = self.designing._TRAJECTORY[self.name]['display_state']
        before = self._state_coords(display)
        import time
        time.sleep(0.05)
        self.assertTrue(self.designing.trajectory_display(self.name))
        self.assertNotEqual(self._state_coords(display), before,
                            'the display state must actually move')

    def testTheTargetHalfNeverMovesWhileAnimating(self):
        self.assertTrue(self.seed())
        self._capture(_backbone(self.LENGTH))
        self._capture(_backbone(self.LENGTH, offset=(10.0, 0, 0)))
        display = self.designing._TRAJECTORY[self.name]['display_state']
        target = self.chain_coords('A', 1)
        for _ in range(6):
            self.designing.trajectory_display(self.name)
        self.assertEqual(
            [tuple(a.coord) for a in
             cmd.get_model('%s and chain A' % self.name, state=display).atom],
            target)

    def testASmoothedRunEndsWithTHESAMESTATESAsAPlainOne(self):
        # The count is the claim: smoothing must not change what the finished object is.
        counts = {}
        for smooth in (0, 1):
            cmd.delete('all')
            self.designing._TRAJECTORY.clear()
            self.assertTrue(self.seed())
            for step in range(1, 6):
                self._capture(_backbone(self.LENGTH, offset=(step * 2.0, 0, 0)),
                              smooth=smooth)
                if smooth:
                    self.designing.trajectory_display(self.name)
            self.designing.deliver_result(self.result_path(), self.name)
            counts[smooth] = cmd.count_states(self.name)
        self.assertEqual(counts[1], counts[0],
                         'a smoothed run must end with the same state count')
        self.assertEqual(counts[0], 7, '6 captured frames + the delivered design')

    def testDeliveryOverwritesTheDisplayStateWithTheDesign(self):
        self.assertTrue(self.seed())
        for step in range(1, 4):
            self._capture(_backbone(self.LENGTH, offset=(step * 2.0, 0, 0)))
            self.designing.trajectory_display(self.name)
        display = self.designing._TRAJECTORY[self.name]['display_state']
        final = _backbone(self.LENGTH, offset=(2.5, -6.0, 0.5))
        self.designing.deliver_result(self.result_path(coords=final), self.name)
        self.assertEqual(cmd.count_states(self.name), display,
                         'the design must land IN the display slot, not after it')
        self.assertEqual(self.displayed_state(), display)
        for atom, expected in zip(self.chain_coords('B', display), final):
            for axis in range(3):
                self.assertAlmostEqual(atom[axis], expected[axis], places=3)

    def testTheAnimationStopsForGoodOnceTheUserMovesTheObject(self):
        self.assertTrue(self.seed())
        self._capture(_backbone(self.LENGTH))
        self._capture(_backbone(self.LENGTH, offset=(10.0, 0, 0)))
        self.assertTrue(self.designing.trajectory_display(self.name))

        said = []
        original = self.designing.colorprinting.parrot
        self.designing.colorprinting.parrot = lambda text: said.append(text)
        try:
            cmd.set('state', 2, self.name)          # the user scrubs to a real frame
            self.assertFalse(self.designing.trajectory_display(self.name))
            self.assertEqual(self.displayed_state(), 2, 'the user must be left alone')

            # AND ACROSS SUBSEQUENT CAPTURED FRAMES, which is the thing a real run does
            # every second for the rest of a multi-minute rollout. Without this the test
            # latched, printed "the live view has stopped animating it", and then let
            # every following frame move the user anyway -- contradicting the message it
            # had just printed.
            for step in range(3):
                self._capture(_backbone(self.LENGTH, offset=(20.0 + step, 0, 0)))
                self.assertEqual(self.displayed_state(), 2,
                                 'captured frame %d moved a user who had taken over'
                                 % step)
                for _ in range(10):
                    self.assertFalse(self.designing.trajectory_display(self.name))

            # And it stays stopped even if they scrub back to where the head had been.
            display = self.designing._TRAJECTORY[self.name]['display_state']
            cmd.set('state', display, self.name)
            self.assertFalse(self.designing.trajectory_display(self.name))
        finally:
            self.designing.colorprinting.parrot = original

        # SAID ONCE, over ~34 calls. The latch is what makes that true: without it every
        # call re-derives "the user has moved this" and re-announces it, which at 30 Hz is
        # thirty lines a second for the rest of the run.
        self.assertEqual(len([t for t in said if 'you moved' in t]), 1,
                         'the reason must be given exactly once: %r' % said)
        # The recording still grew underneath them, so delivery has the right shape.
        self.assertEqual(self.designing._TRAJECTORY[self.name]['captured'], 6)

    def testAFrameLandingBetweenTheScrubAndTheNextTickCannotUndoIt(self):
        # The ~33 ms window. `trajectory_frame` overwrote `head_state` before
        # `trajectory_display` could compare against it, so a frame arriving in that gap
        # -- about 3% of scrubs at 30 Hz -- silently undid the scrub and the latch never
        # fired. The frame path now makes the comparison itself, BEFORE it overwrites.
        self.assertTrue(self.seed())
        self._capture(_backbone(self.LENGTH))
        self._capture(_backbone(self.LENGTH, offset=(10.0, 0, 0)))
        self.assertTrue(self.designing.trajectory_display(self.name))

        said = []
        original = self.designing.colorprinting.parrot
        self.designing.colorprinting.parrot = lambda text: said.append(text)
        try:
            cmd.set('state', 2, self.name)          # the user scrubs ...
            self._capture(_backbone(self.LENGTH, offset=(20.0, 0, 0)))  # ... frame first
        finally:
            self.designing.colorprinting.parrot = original
        self.assertTrue(self.designing._TRAJECTORY[self.name].get('user_scrubbed'),
                        'the frame path must notice the scrub itself')
        self.assertEqual(self.displayed_state(), 2)
        self.assertTrue([t for t in said if 'you moved' in t], said)
        self.assertFalse(self.designing.trajectory_display(self.name))

    def testAnIdleTickWritesNothingAtAll(self):
        # The fraction early-out. It sits AHEAD of the identity check because a tick that
        # writes nothing needs no guard on a write -- which is also what keeps it cheap.
        self.assertTrue(self.seed())
        self._capture(_backbone(self.LENGTH))
        self._capture(_backbone(self.LENGTH, offset=(10.0, 0, 0)))
        record = self.designing._TRAJECTORY[self.name]
        record['gap'] = 0.000001                    # the gap has long since run out
        self.assertTrue(self.designing.trajectory_display(self.name))

        touched = []

        class WatchingCmd(object):
            def __init__(self, real):
                self._real = real

            def __getattr__(self, attribute):
                return getattr(self._real, attribute)

            def load_coordset(self, *args, **kwargs):
                touched.append('load_coordset')

            def iterate_state(self, *args, **kwargs):
                touched.append('iterate_state')      # the identity check

        for _ in range(5):
            self.assertFalse(self.designing.trajectory_display(
                self.name, _self=WatchingCmd(cmd)))
        self.assertEqual(touched, [],
                         'an idle tick must neither reload coordinates nor pay the '
                         'identity check that guards the reload')

    def testTheANIMATIONRefusesAnObjectThisRunDidNotSeed(self):
        # The third writer. `trajectory_frame` and `_finish_trajectory` both make the
        # identity check and the record's own comment states the rule for all of them --
        # this one did not, and it is the writer that matters most: it writes COORDINATES,
        # thirty times a second, so an unverified object here is the user's reopened
        # design being silently overwritten rather than merely shown a different state.
        #
        # PINNED TO THE DISPLAY STATE on purpose. The scrub check catches an impostor
        # showing anything else, so that is the one arrangement where the identity check
        # is the only thing standing between the animation and someone else's object --
        # and "caught incidentally" is not the contract.
        self.assertTrue(self.seed())
        self._capture(_backbone(self.LENGTH))
        self._capture(_backbone(self.LENGTH, offset=(10.0, 0, 0)))
        record = self.designing._TRAJECTORY[self.name]
        display = record['display_state']

        # A DELIVERED design under the same name: same atoms, and its state 1 is the
        # finished structure rather than the poly-ALA seed.
        cmd.delete(self.name)
        cmd.read_pdbstr(_result_pdb(length=self.LENGTH, target=self.TARGET,
                                    coords=_backbone(self.LENGTH, offset=(9.0, 0, 0))),
                        self.name, zoom=0)
        while cmd.count_states(self.name) < display:
            cmd.load_coordset(cmd.get_coordset(self.name, 1), self.name,
                              cmd.count_states(self.name) + 1)
        cmd.set('state', display, self.name)
        record['head_state'] = display
        self.assertEqual(cmd.count_atoms(self.name),
                         self.target_atoms + self.design_atoms,
                         'the impostor must be indistinguishable by atom count')
        before = self._state_coords(display)

        warned = []
        original = self.designing.colorprinting.warning
        self.designing.colorprinting.warning = lambda text: warned.append(text)
        try:
            self.assertFalse(self.designing.trajectory_display(self.name),
                             'the animation must refuse an object it did not seed')
        finally:
            self.designing.colorprinting.warning = original
        self.assertEqual(self._state_coords(display), before,
                         "the impostor's coordinates must not be touched")
        self.assertTrue(record.get('user_scrubbed'), 'and it must stop for the run')
        self.assertTrue([t for t in warned if 'no longer the object' in t], warned)

    def testADeletedObjectIsNotEvenQUERIED(self):
        # Asking a gone object anything raises AND prints a Selector-Error -- thirty times
        # a second here. The fake RECORDS rather than raises, because this function
        # swallows everything by contract and a raising fake would be swallowed with it.
        self.assertTrue(self.seed())
        self._capture(_backbone(self.LENGTH))
        self._capture(_backbone(self.LENGTH, offset=(10.0, 0, 0)))
        queried = []

        class GoneCmd(object):
            def __init__(self, real):
                self._real = real

            def __getattr__(self, attribute):
                return getattr(self._real, attribute)

            def get_names(self, *args, **kwargs):
                return []

            def get(self, *args, **kwargs):
                queried.append('get')
                return '1'

            def load_coordset(self, *args, **kwargs):
                queried.append('load_coordset')

        self.assertFalse(self.designing.trajectory_display(self.name,
                                                           _self=GoneCmd(cmd)))
        self.assertEqual(queried, [], 'a deleted object must not be queried at all')

    def testTheSeedShowsItsOwnStateWhateverTheSessionWasShowing(self):
        # The animation's user-control check compares against what it last set, so the
        # baseline has to be a fact rather than an inherited default: a fresh object
        # reports the GLOBAL state setting until something sets its own.
        cmd.set('state', 3)
        self.addCleanup(cmd.set, 'state', 1)
        self.assertTrue(self.seed())
        self.assertEqual(self.displayed_state(), 1)
        self._capture(_backbone(self.LENGTH))
        self._capture(_backbone(self.LENGTH, offset=(10.0, 0, 0)))
        self.assertTrue(self.designing.trajectory_display(self.name),
                        'the head must not mistake that default for the user')

    def testAFrameFromTheAppDoesNotJumpTheDisplayToItself(self):
        # `advance=0`: the captured frame lands as a state without the display snapping to
        # it. With `smooth=1` the display moves to the new slot instead, which is where
        # the animation into that frame plays out.
        self.assertTrue(self.seed())
        self.assertEqual(self.displayed_state(), 1)
        # The SEED is captured frame 1, so the very first appended frame already has a
        # predecessor and a gap to animate: 2 captured states plus the display.
        self._capture(_backbone(self.LENGTH))
        self.assertEqual(cmd.count_states(self.name), 3, '2 captured + 1 display')
        self.assertEqual(self.displayed_state(), 3)
        # The next frame overwrites that display slot with model output and opens a new
        # one, so the object grows by exactly one state per captured frame.
        self._capture(_backbone(self.LENGTH, offset=(10.0, 0, 0)))
        self.assertEqual(cmd.count_states(self.name), 4, '3 captured + 1 display')
        self.assertEqual(self.displayed_state(), 4)
        self.assertEqual(self.designing._TRAJECTORY[self.name]['captured'], 3)

    # -- keep_frames: the states are opt-in ------------------------------------

    def _seed_keeping(self, keep, coords=None):
        return self.designing.trajectory_seed(
            self.name,
            _seed_pdb(length=self.LENGTH, coords=coords, target=self.TARGET),
            self.target_atoms, self.design_atoms, keep=keep)

    def _run(self, keep, frames=5):
        """Seed, animate through `frames` captured frames, deliver. Returns the object."""
        cmd.delete('all')
        self.designing._TRAJECTORY.clear()
        self.assertTrue(self._seed_keeping(keep))
        for step in range(1, frames + 1):
            self.assertTrue(self.designing.trajectory_frame(
                self.name, _flat(_backbone(self.LENGTH, offset=(step * 2.0, 0, 0))),
                advance=0, smooth=1))
            for _ in range(3):
                self.designing.trajectory_display(self.name)
        final = _backbone(self.LENGTH, offset=(2.5, -6.0, 0.5))
        self.designing.deliver_result(self.result_path(coords=final), self.name)

    def _fingerprint(self):
        """Everything about the finished object a user could tell apart."""
        ranks = []
        cmd.iterate(self.name, 'L.append(rank)', space={'L': ranks})
        model = cmd.get_model(self.name)
        resn = []
        cmd.iterate(self.name, 'L.append(resn)', space={'L': resn})
        return {
            'states': cmd.count_states(self.name),
            'atoms': cmd.count_atoms(self.name),
            'coords': [tuple(round(c, 4) for c in a.coord)
                       for a in cmd.get_model(self.name, state=1).atom],
            'bonds': sorted((min(ranks[b.index[0]], ranks[b.index[1]]),
                             max(ranks[b.index[0]], ranks[b.index[1]]), b.order)
                            for b in model.bond),
            'resn': resn,
            'ss': [a.ss for a in model.atom],
            # A leftover per-object `state` pin is itself a difference, and detecting one
            # takes a probe: `cmd.get('state', obj)` returns the object's own setting when
            # it has one and FALLS BACK to the global when it does not. So move the global
            # somewhere distinctive and see whether the object follows it.
            'pinned': self._has_state_pin(),
            # Visibility is deliberately SET now (the target copy is hidden), so it is
            # part of what the two arms have to agree on rather than something neither
            # touches.
            'visible_chains': sorted(self._visible_chains()),
            'visible_atoms': cmd.count_atoms('%s and visible' % self.name),
            # The three axes the invariant was silently false on. They are nothing to do
            # with the live view -- they came from deleting the placeholder and building
            # a fresh object where the plain path loads into it in place -- but a claim
            # of "indistinguishable" has to be checked, not asserted.
            'carbons': sorted(self._carbon_colours()),
            'objlist': cmd.get_names('objects'),
            'auto_color_next': cmd.get('auto_color_next'),
            # WHICH GROUP the object ended up in, if any. An n_designs batch groups its
            # placeholders at SUBMIT, so a live design spends its whole rollout inside a
            # group; this axis is what says the plain run spends it in the same one.
            'parent': self._parent_of(self.name),
        }

    @staticmethod
    def _parent_of(name):
        """The object's group, or '' -- from the session record, `entry[6]`.

        NOT `cmd.get_object_list` over the groups: that reports molecular leaves only, so
        it cannot see a zero-atom placeholder inside a group at all.
        """
        for entry in (cmd.get_session(partial=1).get('names') or []):
            if entry and entry[0] == name and len(entry) > 6:
                return entry[6] or ''
        return ''

    def _carbon_colours(self):
        colours = set()
        cmd.iterate('%s and elem C' % self.name, 'S.add(color)', space={'S': colours})
        return colours

    def _visible_chains(self):
        chains = set()
        cmd.iterate('%s and visible' % self.name, 'S.add(chain)', space={'S': chains})
        return chains

    def _has_state_pin(self):
        sentinel = 9
        cmd.set('state', sentinel)
        try:
            return int(cmd.get('state', self.name)) != sentinel
        finally:
            cmd.set('state', 1)

    def testWithFramesDISCARDEDTheObjectIsIndistinguishableFromAPlainRun(self):
        self._indistinguishable(batched=False)

    def testTheINVARIANTHoldsWithTheObjectInsideItsBatchGroupToo(self):
        # An n_designs batch groups its placeholders AT SUBMIT, so a live design is
        # seeded, animated and delivered from INSIDE a group. The invariant has to hold
        # with grouping on BOTH arms, or being early bought a tidy object panel at the
        # cost of the thing that makes `keep_frames=0` safe.
        self._indistinguishable(batched=True)

    def _indistinguishable(self, batched):
        # THE invariant, and the thing that makes the default safe. With the toggle off a
        # live run must leave exactly what `live_view=0` leaves -- states, coordinates,
        # bonds INCLUDING ORDERS, residue names, secondary structure, what is visible,
        # the object's COLOUR, its POSITION in the object list, and the session's
        # `auto_color_next`; and no leftover per-object `state` pin.
        #
        # The last three were false for several rounds and this test did not look at
        # them: `trajectory_seed` deleted the placeholder and built a fresh object where
        # the plain path loads into it in place, so the design came out a different
        # colour, at the end of the object panel, and every object opened afterwards was
        # shifted one auto-colour slot.
        #
        # EVERY FIXTURE IS BUILT UP FRONT, before either arm starts. `_backbone` uses
        # `cmd.fab`, which consumes an auto colour, and the two arms do different amounts
        # of fixture work -- so building fixtures inside the arms makes the test measure
        # the fixture rather than the product. That is what it did on the first attempt.
        seed_pdb = _seed_pdb(length=self.LENGTH, target=self.TARGET)
        frames = [_flat(_backbone(self.LENGTH, offset=(step * 2.0, 0, 0)))
                  for step in range(1, 6)]
        path = self.result_path(coords=_backbone(self.LENGTH, offset=(2.5, -6.0, 0.5)))
        # Something the user opens while the design runs, so an object-list or colour
        # difference has somewhere to show up. Prebuilt, and read identically in both.
        bystander = _seed_pdb(length=2, target=1)

        def arm(build):
            cmd.delete('all')
            self.designing._TRAJECTORY.clear()
            self.designing._BATCH.clear()
            self.designing._BATCH_OF.clear()
            cmd.set('auto_color_next', 0)
            if batched:
                # What `design_backbone` stamps for an n_designs command, in the order the
                # command does it: stamp, create the placeholder, join the group.
                self.designing._BATCH['a_batch'] = {'names': [self.name], 'total': 2}
                self.designing._BATCH_OF[self.name] = {'batch': 'a_batch', 'index': 1,
                                                       'total': 2}
            self.designing.register_pending(self.name, 'job')
            if batched:
                self.designing._join_batch_group(self.name)
            cmd.read_pdbstr(bystander, 'opened_meanwhile', zoom=0)
            build()
            return self._fingerprint()

        def plain_run():
            self.designing.deliver_result(path, self.name)

        def live_run():
            self.assertTrue(self.designing.trajectory_seed(
                self.name, seed_pdb, self.target_atoms, self.design_atoms, keep=0))
            for coords in frames:
                self.assertTrue(self.designing.trajectory_frame(
                    self.name, coords, advance=0, smooth=1))
                for _ in range(3):
                    self.designing.trajectory_display(self.name)
            self.designing.deliver_result(path, self.name)

        plain = arm(plain_run)
        live = arm(live_run)

        self.assertEqual(live['states'], 1, 'discarded frames must leave one state')
        for key in ('states', 'atoms', 'coords', 'bonds', 'resn', 'ss', 'pinned',
                    'visible_chains', 'visible_atoms', 'carbons', 'objlist',
                    'auto_color_next', 'parent'):
            self.assertEqual(live[key], plain[key],
                             '%s differs between a discarded-frame live run and a '
                             'plain one (batched=%s)' % (key, batched))
        # And the fixture really did put the object where it claims to have -- without
        # this the grouped arm passes by both arms being ungrouped.
        self.assertEqual(live['parent'], 'a_batch' if batched else '')

    def testTheLIVEObjectSTAYSInItsGroupForTheWholeRollout(self):
        # An n_designs batch groups its placeholder at SUBMIT, so the object is seeded,
        # animated and delivered from INSIDE a group. The fingerprint test above compares
        # the two arms at the END; this one samples the whole run, because the seed reads
        # into the placeholder in place and any path that deleted and recreated it would
        # silently drop the object out of its group mid-rollout.
        self.designing._BATCH.clear()
        self.designing._BATCH_OF.clear()
        self.designing._BATCH['a_batch'] = {'names': [self.name], 'total': 2}
        self.designing._BATCH_OF[self.name] = {'batch': 'a_batch', 'index': 1,
                                               'total': 2}
        self.designing.register_pending(self.name, 'job')
        self.designing._join_batch_group(self.name)
        seen = [self._parent_of(self.name)]
        self.assertTrue(self.designing.trajectory_seed(
            self.name, _seed_pdb(length=self.LENGTH, target=self.TARGET),
            self.target_atoms, self.design_atoms, keep=1))
        seen.append(self._parent_of(self.name))
        for step in range(1, 4):
            # A True return from each of these IS the identity check (`_holds_our_writes`)
            # passing for an object that lives inside a group.
            self.assertTrue(self.designing.trajectory_frame(
                self.name, _flat(_backbone(self.LENGTH, offset=(step * 2.0, 0, 0))),
                advance=0, smooth=1))
            self.assertTrue(self.designing.trajectory_display(self.name))
            seen.append(self._parent_of(self.name))
        # The animation really is running, inside the group.
        self.assertGreater(cmd.count_states(self.name), 1)
        self.designing.deliver_result(self.result_path(), self.name)
        seen.append(self._parent_of(self.name))
        self.assertEqual(seen, ['a_batch'] * len(seen), seen)
        # Delivery's own state pin still lands on the OBJECT, not on the group.
        self.assertEqual(int(cmd.get('state', self.name)),
                         cmd.count_states(self.name))

    def testADeliveryFALLBACKPutsTheObjectBackInItsGroup(self):
        # `deliver_result` deletes and reloads the object when a recording cannot be
        # finished, and a deleted object takes its group membership with it -- which is
        # why the join is made again at delivery and not only at submit.
        self.designing._BATCH.clear()
        self.designing._BATCH_OF.clear()
        self.designing._BATCH['a_batch'] = {'names': [self.name], 'total': 2}
        self.designing._BATCH_OF[self.name] = {'batch': 'a_batch', 'index': 1,
                                               'total': 2}
        self.designing.register_pending(self.name, 'job')
        self.designing._join_batch_group(self.name)
        self.assertTrue(self.designing.trajectory_seed(
            self.name, _seed_pdb(length=self.LENGTH, target=self.TARGET),
            self.target_atoms, self.design_atoms, keep=1))
        # A recording that cannot be finished: the result is laid out with a DIFFERENT
        # design length, so `_finish_trajectory` refuses on the atom-count guard and
        # delivery falls back to delete-then-load.
        path = self.tempfile()
        with open(path, 'w') as handle:
            handle.write(_result_pdb(length=self.LENGTH + 1, target=self.TARGET))
        self.designing.deliver_result(path, self.name)
        # The fallback really did fire -- otherwise the assertion below is vacuous,
        # because a recording that finishes never leaves the group in the first place.
        self.assertEqual(cmd.count_atoms(self.name),
                         (self.TARGET + self.LENGTH + 1) * len(_SLOTS),
                         'the object must be the RELOADED result, not the recording')
        self.assertEqual(self._parent_of(self.name), 'a_batch',
                         'the reloaded object must go back into its group')

    def testADeliveryOutsideABatchJoinsNoGroup(self):
        # The control for the test above: grouping is a property of the BATCH stamp, not
        # something delivery does to everything -- so with no stamp there is no group,
        # which is what n_designs=1 gets.
        self.designing._BATCH.clear()
        self.designing._BATCH_OF.clear()
        self.designing.register_pending(self.name, 'job')
        self.designing.deliver_result(self.result_path(), self.name)
        self.assertEqual(list(cmd.get_names('public_group_objects')), [])

    def testDeliveryNeverSays1States(self):
        # The message a keep_frames=0 run ends on. It used to read "... was built live --
        # 1 states, the last one the finished design", which is both ungrammatical and
        # wrong about what happened: nothing was kept, so there are no rollout states to
        # be the last of. The conditional that fixed it was guarded by nothing -- reverting
        # it failed no test.
        import io as _io
        from contextlib import redirect_stdout
        path = self.result_path()
        self.assertTrue(self._seed_keeping(0))
        self.designing.trajectory_frame(self.name, _flat(_backbone(self.LENGTH)),
                                        advance=0, smooth=1)
        with redirect_stdout(_io.StringIO()) as buf:
            self.designing.deliver_result(path, self.name)
        said = buf.getvalue()
        self.assertIn('was built live', said)
        self.assertNotIn('1 states', said)
        self.assertIn('discarded', said,
                      'the line has to say what became of the frames: %r' % said)
        # And the OTHER arm still names the count, or the fix would have been to delete
        # the number rather than to make it conditional.
        cmd.delete('all')
        self.designing._TRAJECTORY.clear()
        self.assertTrue(self._seed_keeping(1))
        for _ in range(2):
            self.designing.trajectory_frame(self.name, _flat(_backbone(self.LENGTH)),
                                            advance=0, smooth=1)
        with redirect_stdout(_io.StringIO()) as buf:
            self.designing.deliver_result(path, self.name)
        self.assertIn('states, the last one the finished design', buf.getvalue())

    def testWithFramesKEPTTheStatesAreThereToScrub(self):
        # The positive control for the test above: with the toggle ON the states exist,
        # so "indistinguishable" is a property of the toggle rather than of the code
        # never keeping anything.
        self._run(keep=1, frames=5)
        self.assertEqual(cmd.count_states(self.name), 7, '6 captured + the design')
        self.assertGreater(cmd.count_states(self.name), 1)

    def testDiscardingFramesStillAnimates(self):
        # The whole point of the option: the run looks the same, only the leftovers
        # differ. Nothing is appended, and the single state still moves.
        self.assertTrue(self._seed_keeping(0))
        self.assertEqual(cmd.count_states(self.name), 1)
        self.designing.trajectory_frame(self.name, _flat(_backbone(self.LENGTH)),
                                        advance=0, smooth=1)
        self.designing.trajectory_frame(
            self.name, _flat(_backbone(self.LENGTH, offset=(10.0, 0, 0))),
            advance=0, smooth=1)
        self.assertEqual(cmd.count_states(self.name), 1,
                         'nothing may be appended when frames are discarded')
        self.assertEqual(self.designing._TRAJECTORY[self.name]['display_state'], 1,
                         'the object\'s only state IS the display')
        before = self._state_coords(1)
        import time
        time.sleep(0.05)
        self.assertTrue(self.designing.trajectory_display(self.name))
        self.assertNotEqual(self._state_coords(1), before,
                            'the single state must still animate')
        # And the captured count still tracks the model frames, because `live_steps`
        # means model frames whether or not they are kept.
        self.assertEqual(self.designing._TRAJECTORY[self.name]['captured'], 3)

    def testTheIdentityCheckStillHoldsWithNothingAppended(self):
        # The anchor moved: with frames discarded, state 1 IS the animated display, so
        # comparing it against the SEED would fail on the first tick. It follows what was
        # last written instead -- and must still reject an object it did not seed.
        self.assertTrue(self._seed_keeping(0))
        self.designing.trajectory_frame(self.name, _flat(_backbone(self.LENGTH)),
                                        advance=0, smooth=1)
        self.designing.trajectory_frame(
            self.name, _flat(_backbone(self.LENGTH, offset=(10.0, 0, 0))),
            advance=0, smooth=1)
        record = self.designing._TRAJECTORY[self.name]
        for _ in range(5):
            self.assertTrue(self.designing.trajectory_display(self.name))
            self.assertTrue(self.designing._holds_our_writes(self.name, record),
                            'the anchor must follow the animation, not the seed')
        # An impostor is still rejected.
        cmd.delete(self.name)
        cmd.read_pdbstr(_result_pdb(length=self.LENGTH, target=self.TARGET,
                                    coords=_backbone(self.LENGTH, offset=(99.0, 0, 0))),
                        self.name, zoom=0)
        cmd.set('state', 1, self.name)
        record['head_state'] = 1
        self.assertFalse(self.designing._holds_our_writes(self.name, record))
        self.assertFalse(self.designing.trajectory_display(self.name))

    # -- The target copy is hidden, and the cartoon evolves --------------------

    def testTheTargetCopyIsHiddenAndOnlyTheGeneratedChainIsShown(self):
        # The object carries a copy of the target, and the user already has their own
        # target loaded -- so it draws duplicate geometry on top of their structure.
        self.assertTrue(self.seed())
        self.assertEqual(self._visible_chains(), {'B'},
                         'only the generated chain may be displayed')
        self.assertEqual(cmd.count_atoms('%s and visible' % self.name),
                         self.design_atoms)

    def testTheHIDDENTargetAtomsAreStillTHERE(self):
        # Hiding is a display flag, not a deletion. The atoms are what makes the pair a
        # refold's input, and they are in the result file and the metrics.
        self.assertTrue(self.seed())
        self.assertEqual(cmd.count_atoms(self.name),
                         self.target_atoms + self.design_atoms)
        self.assertEqual(cmd.count_atoms('%s and chain A' % self.name),
                         self.target_atoms)
        # And they still move with the recording, which is what the frame path splices.
        self.designing.trajectory_frame(self.name, _flat(_backbone(self.LENGTH)),
                                        advance=0, smooth=1)
        self.assertEqual(cmd.count_atoms('%s and chain A' % self.name),
                         self.target_atoms)

    def testAPlainRunGetsTheSameTreatment(self):
        # Applied to BOTH, so `keep_frames=0` stays indistinguishable from a plain run.
        # The reason for hiding -- this chain duplicates a target you already have -- is
        # just as true without the live view.
        self.designing.register_pending(self.name, 'job-plain')
        self.designing.deliver_result(self.result_path(), self.name)
        self.assertEqual(self._visible_chains(), {'B'})
        self.assertEqual(cmd.count_atoms(self.name),
                         self.target_atoms + self.design_atoms)

    def testShowingTheTargetYourselfIsNotUndone(self):
        # Hidden ONCE, where the object is created. A user who shows the target chain
        # mid-run must not have it hidden again by the next captured frame.
        self.assertTrue(self.seed())
        cmd.show('lines', '%s and chain A' % self.name)
        self.assertIn('A', self._visible_chains())
        for step in range(3):
            self.designing.trajectory_frame(
                self.name, _flat(_backbone(self.LENGTH, offset=(step, 0, 0))),
                advance=0, smooth=1)
            self.designing.trajectory_display(self.name)
        self.assertIn('A', self._visible_chains(),
                      'a captured frame must not re-hide what the user showed')

    def testSecondaryStructureIsAssignedOnEVERYCapturedFrame(self):
        # The cartoon has to evolve with the rollout, not appear only at the end.
        #
        # Twenty residues, because two cannot form a helix and `dss` would answer "loop"
        # either way -- the assertion has to be able to change. Seeded from a CLOUD so the
        # ss starts as loops, then fed the real helical backbone `cmd.fab(..., ss=1)`
        # builds: if `dss` only ran at delivery this would still be all loops.
        length = 20
        cmd.delete('all')
        self.designing._TRAJECTORY.clear()
        self.assertTrue(_seed(self.designing, self.name, length=length,
                              target=self.TARGET, coords=_cloud(length, 9.0)))
        before = []
        cmd.iterate('%s and chain B and name CA' % self.name, 'L.append(ss)',
                    space={'L': before})
        self.assertEqual(set(before), {'L'}, 'the fixture must start as loops: %r'
                         % before)

        for _ in range(2):
            self.assertTrue(self.designing.trajectory_frame(
                self.name, _flat(_backbone(length)), advance=0, smooth=1))
        after = []
        cmd.iterate('%s and chain B and name CA' % self.name, 'L.append(ss)',
                    space={'L': after})
        self.assertIn('H', after,
                      'secondary structure must be re-assigned as frames land, not only '
                      'at delivery (was %r, still %r)' % (before, after))

    def testSecondaryStructureIsAssignedWithFramesDISCARDEDToo(self):
        # The keep_frames=0 branch is the DEFAULT path and had no coverage: both of the
        # tests above seed with keep=1, so `ss_state = state if keep else <display>` could
        # have gone dead -- two mutations of the else arm survived the whole suite.
        #
        # It also LAGS ONE CAPTURED FRAME, and that is correct rather than a defect: with
        # frames discarded nothing is written at capture time, so the display still holds
        # the previous frame (or an interpolation towards it) when `dss` runs. The cartoon
        # therefore matches what is on screen, which is the point. Asserted explicitly so
        # nobody "fixes" the lag into an assignment against coordinates nobody can see.
        length = 20
        cmd.delete('all')
        self.designing._TRAJECTORY.clear()
        self.assertTrue(_seed(self.designing, self.name, length=length,
                              target=self.TARGET, coords=_cloud(length, 9.0), keep=0))
        self.assertEqual(cmd.count_states(self.name), 1)

        def ss_now():
            out = []
            cmd.iterate('%s and chain B and name CA' % self.name, 'L.append(ss)',
                        space={'L': out})
            return out

        self.assertEqual(set(ss_now()), {'L'}, 'the fixture must start as loops')
        # Frame 1 supplies helical coordinates but nothing is WRITTEN with frames
        # discarded, so the display still holds the cloud and the ss is still loops --
        # the lag, measured.
        self.assertTrue(self.designing.trajectory_frame(
            self.name, _flat(_backbone(length)), advance=0, smooth=1))
        self.assertEqual(set(ss_now()), {'L'},
                         'the assignment reads the DISPLAY, which still holds the seed')
        # Frame 2 gives the tween both of its ends, and the head then writes the
        # interpolation into the single state. `trajectory_display` is what moves the
        # atoms on this path -- `trajectory_frame` writes nothing at all.
        self.assertTrue(self.designing.trajectory_frame(
            self.name, _flat(_backbone(length)), advance=0, smooth=1))
        for _ in range(4):
            self.designing.trajectory_display(self.name)
        self.assertTrue(self.designing.trajectory_frame(
            self.name, _flat(_backbone(length)), advance=0, smooth=1))
        self.assertIn('H', ss_now(),
                      'with frames discarded the cartoon must still evolve')
        # And nothing was appended on the way -- this is still the one-state path.
        self.assertEqual(cmd.count_states(self.name), 1)

    def testTheAssignmentIsScopedToTheGeneratedChain(self):
        # The target's coordinates never move, so re-deriving its ss every second is work
        # for an answer that cannot change -- and it must not be silently overwritten.
        self.assertTrue(self.seed())
        cmd.alter('%s and chain A' % self.name, 'ss = "S"')
        cmd.rebuild(self.name)
        for _ in range(3):
            self.designing.trajectory_frame(self.name, _flat(_backbone(self.LENGTH)),
                                            advance=0, smooth=1)
        target_ss = set()
        cmd.iterate('%s and chain A' % self.name, 'S.add(ss)', space={'S': target_ss})
        self.assertEqual(target_ss, {'S'},
                         'the per-frame assignment must not touch the target chain')

    # -- What a run that never finishes leaves behind --------------------------

    def testACancelledRunLeavesNoObjectRatherThanAHalfDiffusedOne(self):
        # The object now bears the DESIGN's name, so leaving a rollout frozen at step 84
        # under it would put something in the session -- and in any .pse saved afterwards
        # -- that is indistinguishable from a finished design and carries no metrics.
        # `discard_pending` is what the runtime calls when a job is cancelled or fails.
        self.designing.register_pending(self.name, 'job-1')
        self.assertTrue(self.seed())
        for _ in range(4):
            self.designing.trajectory_frame(self.name, _flat(_backbone(self.LENGTH)))
        self.assertEqual(cmd.count_states(self.name), 5)

        self.designing.discard_pending(self.name)

        self.assertNotIn(self.name, cmd.get_names('objects'))
        self.assertNotIn(self.name, self.designing.pending_objects())
        # And a stray frame that arrives afterwards must not resurrect anything.
        self.assertFalse(
            self.designing.trajectory_frame(self.name, _flat(_backbone(self.LENGTH))))
        self.assertNotIn(self.name, cmd.get_names('objects'))

    def testADeliveredDesignSurvivesADiscardThatRacesIt(self):
        # The other half of the rule above: once the design has landed the object is a
        # result, not a recording, and cleanup must never delete it. Seventeen minutes of
        # GPU time depends on this branch.
        self.designing.register_pending(self.name, 'job-1')
        self.assertTrue(self.seed())
        self.designing.trajectory_frame(self.name, _flat(_backbone(self.LENGTH)))
        self.designing.deliver_result(self.result_path(), self.name)

        self.designing.discard_pending(self.name)

        self.assertIn(self.name, cmd.get_names('objects'))
        self.assertEqual(cmd.count_atoms(self.name),
                         self.target_atoms + self.design_atoms)

    def testAMidRunSessionSaveDropsTheUnfinishedObject(self):
        # A .pse saved while a live design is running must not carry the rollout. The
        # object has atoms, so "is it empty" no longer answers this on its own.
        self.designing.register_pending(self.name, 'job-1')
        self.assertTrue(self.seed())
        self.designing.trajectory_frame(self.name, _flat(_backbone(self.LENGTH)))
        session = {'names': [[self.name, 0], ['something_else', 0]]}
        self.designing.session_save(session)
        self.assertEqual([entry[0] for entry in session['names']], ['something_else'])

    def testASessionSaveDropsARecordingThatHasLeftThePendingTable(self):
        # `session_save` used to be gated on `_PENDING` alone. Two jobs can share an object
        # name, and job A's `discard_pending` pops the WHOLE list -- queued job B included.
        # B then seeds live under a name `_PENDING` no longer knows, and a `cmd.save`
        # mid-run persists a half-diffused poly-ALA rollout into the .pse: exactly the
        # artefact the cancellation rule exists to prevent.
        self.designing.register_pending(self.name, 'job-A')
        self.assertTrue(self.seed())
        self.designing.trajectory_frame(self.name, _flat(_backbone(self.LENGTH)))
        # A sibling job's discard takes the name out of _PENDING, but the recording is
        # still running.
        self.designing._PENDING.pop(self.name, None)
        self.assertIn(self.name, self.designing._TRAJECTORY)

        session = {'names': [[self.name, 0], ['something_else', 0]]}
        self.designing.session_save(session)
        self.assertEqual([entry[0] for entry in session['names']], ['something_else'],
                         'an unfinished recording must not reach the .pse just because '
                         'its name left the pending table')

    def testAFinishedDesignIsKeptByASessionSave(self):
        # The negative control: same object, after delivery.
        self.designing.register_pending(self.name, 'job-1')
        self.assertTrue(self.seed())
        self.designing.deliver_result(self.result_path(), self.name)
        session = {'names': [[self.name, 0], ['something_else', 0]]}
        self.designing.session_save(session)
        self.assertEqual([entry[0] for entry in session['names']],
                         [self.name, 'something_else'])

    # -- The two orders PyMOL keeps, and the one the writer wrote in ------------

    def testALiveRunSurvivesEveryTargetChainLetter(self):
        # THE regression. PyMOL keeps atoms in a SORTED order (`AtomInfoCompare` orders by
        # chain before residue number, and `retain_order` is 0) which is not the file order
        # the writer emitted. `_free_chain_id` gives the generated chain 'B' for every
        # target except a chain-B one, so for 24 of 26 target letters the DESIGN sorts
        # first and `index 1-<offset>` spans both chains.
        #
        # Every earlier test used target 'A' + design 'B' -- the one pairing where the two
        # orders agree -- so 120 of them stayed green while a design against, say, an
        # antibody heavy chain got no live view at all and lost its row in the object
        # panel for the whole run. `rank` is the file order and is what the layout is
        # addressed in.
        for target_chain, design_chain in (('A', 'B'), ('B', 'C'), ('H', 'B'),
                                           ('C', 'B'), ('L', 'B')):
            cmd.delete('all')
            self.designing._TRAJECTORY.clear()
            label = 'target %s / design %s' % (target_chain, design_chain)

            self.assertTrue(
                _seed(self.designing, self.name, length=self.LENGTH,
                      chain=design_chain, target=self.TARGET,
                      target_chain=target_chain),
                '%s: the seed must be accepted' % label)
            self.assertIn(self.name, cmd.get_names('objects'), label)
            self.assertEqual(cmd.count_atoms(self.name),
                             self.target_atoms + self.design_atoms, label)

            target_before = self.chain_coords(target_chain, 1)
            self.assertEqual(len(target_before), self.target_atoms, label)
            for step in range(3):
                # A marker the target could never carry: the design pushed far along x.
                moved = _backbone(self.LENGTH, offset=(500.0 + step, 0.0, 0.0))
                self.assertTrue(
                    self.designing.trajectory_frame(self.name, _flat(moved)), label)
                state = cmd.count_states(self.name)
                self.assertEqual(state, step + 2, label)
                self.assertEqual(self.displayed_state(), state, label)
                # The target's half is bit-identical to state 1 ...
                self.assertEqual(self.chain_coords(target_chain, state), target_before,
                                 '%s: the target moved' % label)
                # ... and the marker landed on the DESIGN, not on the target.
                for atom, expected in zip(self.chain_coords(design_chain, state), moved):
                    for axis in range(3):
                        self.assertAlmostEqual(atom[axis], expected[axis], places=3,
                                               msg=label)

            final = _backbone(self.LENGTH, offset=(2.5, -6.0, 0.5))
            path = self.tempfile()
            with open(path, 'w') as handle:
                handle.write(_result_pdb(length=self.LENGTH, chain=design_chain,
                                         target=self.TARGET, coords=final,
                                         target_chain=target_chain))
            self.designing.deliver_result(path, self.name)

            self.assertEqual(cmd.get_names('objects'), [self.name], label)
            self.assertEqual(cmd.count_atoms(self.name),
                             self.target_atoms + self.design_atoms, label)
            self.assertEqual(cmd.count_states(self.name), 5, label)
            self.assertEqual(self.displayed_state(), 5, label)
            # The rename hit the generated chain and left the target alone -- which is the
            # `alter` range, and it is addressed in the same order as the unbond.
            designed = []
            cmd.iterate('%s and chain %s and name CA' % (self.name, design_chain),
                        'L.append(resn)', space={'L': designed})
            self.assertEqual(
                designed, [_DESIGNED[i % len(_DESIGNED)] for i in range(self.LENGTH)],
                label)
            target_names = set()
            cmd.iterate('%s and chain %s' % (self.name, target_chain), 'S.add(resn)',
                        space={'S': target_names})
            self.assertEqual(target_names, {_TARGET_RESN}, label)

    def testTheSeedRefusesAudiblyAndGivesThePlaceholderBack(self):
        # Every refusal branch used to `return False` in silence, and the object it had
        # already created was deleted -- so the design's row vanished from the object panel
        # for the rest of a seventeen-minute run with nothing said anywhere.
        self.designing.register_pending(self.name, 'job-1')
        warned = []
        original = self.designing.colorprinting.warning
        self.designing.colorprinting.warning = lambda text: warned.append(text)
        try:
            self.assertFalse(self.designing.trajectory_seed(
                self.name, _seed_pdb(length=self.LENGTH, target=self.TARGET),
                self.target_atoms, self.design_atoms + 5))
        finally:
            self.designing.colorprinting.warning = original
        self.assertTrue(warned, 'a refused seed must say so')
        self.assertIn('no live view', warned[0])
        self.assertIn(self.name, warned[0])
        # And the placeholder is back, so the row stays.
        self.assertIn(self.name, cmd.get_names('objects'))
        self.assertEqual(cmd.count_atoms(self.name), 0)
        self.assertNotIn(self.name, self.designing._TRAJECTORY)

    def testARefusedSeedLEAVESTHEROWWHEREITWAS(self):
        # The same defect class the success path fixed: `_refuse_seed` used to delete the
        # object and `create` another, which puts the design's row at the END of the object
        # panel -- and the run then delivers plainly into it, so the FINISHED object sits
        # somewhere a plain run's never would. `cmd.remove` empties it in place instead.
        #
        # Both orders that matter: refused BEFORE any load (the common case) and refused
        # AFTER a partial one (the atom-count mismatch), because only the second used to
        # have atoms to delete.
        for label, pdb, atoms in (
                ('before the load', _seed_pdb(length=self.LENGTH, target=self.TARGET),
                 -1),
                ('after a partial load',
                 _seed_pdb(length=self.LENGTH, target=self.TARGET),
                 self.design_atoms + 5)):
            cmd.delete('all')
            self.designing._TRAJECTORY.clear()
            self.designing._PENDING.clear()
            self.designing.register_pending(self.name, 'job-1')
            cmd.read_pdbstr(_result_pdb(length=2), 'opened_after', zoom=0)
            before = cmd.get_names('objects')
            self.assertEqual(before, [self.name, 'opened_after'], label)
            self.assertFalse(self.designing.trajectory_seed(
                self.name, pdb, self.target_atoms,
                atoms if atoms > 0 else -1))
            self.assertEqual(cmd.get_names('objects'), before,
                             'a seed refused %s moved the design\'s row' % label)
            self.assertEqual(cmd.count_atoms(self.name), 0, label)

    # -- A session that already has a movie -------------------------------------

    def testTheObjectStillAdvancesWhenTheSessionHasAMovie(self):
        # `cmd.frame` writes the GLOBAL movie frame, and `CObject::getCurrentState` prefers
        # the object's own `state` setting and only falls back to the global. So in any
        # session carrying an `mset` -- a Timeline the user built, a movie, a reopened .pse
        # -- driving the view with `cmd.frame` leaves the object on state 1 for the whole
        # run, and after delivery shows the step-4 poly-ALA seed wearing the DESIGNED
        # residue names. `cmd.save` at its default state=-1 would export that as the design.
        cmd.mset('1 x10')
        self.assertEqual(cmd.count_frames(), 10, 'the fixture must really have a movie')
        self.assertTrue(self.seed())
        for step in range(4):
            self.assertTrue(
                self.designing.trajectory_frame(self.name,
                                                _flat(_backbone(self.LENGTH))))
            self.assertEqual(self.displayed_state(), cmd.count_states(self.name),
                             'the object must advance even with a movie in the session')
        final = _backbone(self.LENGTH, offset=(2.5, -6.0, 0.5))
        self.designing.deliver_result(self.result_path(coords=final), self.name)
        self.assertEqual(cmd.count_states(self.name), 6)
        self.assertEqual(self.displayed_state(), 6,
                         'the delivered design must be what the object shows')
        # And the state it shows really is the design, not the seed.
        for atom, expected in zip(self.chain_coords('B', self.displayed_state()), final):
            for axis in range(3):
                self.assertAlmostEqual(atom[axis], expected[axis], places=3)

    def testAFrameCannotLandOnADifferentObjectOfTheSameName(self):
        # Open yesterday's .pse of this very design mid-run and the atom count matches
        # exactly, so counting cannot tell the two apart. The user's saved design would be
        # handed this run's rollout states -- and at delivery a rename of its residues,
        # because residue names are per-object.
        #
        # What the two do NOT share is state 1: this recording's is the step-4 poly-ALA
        # seed, and the saved design's is the finished structure. The impostor here is
        # therefore a DELIVERED design, which is what would actually be reopened -- an
        # impostor built from the same seed string would be the same object by every
        # measure that matters and there would be nothing to detect.
        self.assertTrue(self.seed())
        self.assertTrue(self.designing.trajectory_frame(self.name,
                                                        _flat(_backbone(self.LENGTH))))
        cmd.delete(self.name)
        cmd.read_pdbstr(_result_pdb(length=self.LENGTH, target=self.TARGET,
                                    coords=_backbone(self.LENGTH, offset=(9.0, 0, 0))),
                        self.name, zoom=0)
        self.assertEqual(cmd.count_atoms(self.name),
                         self.target_atoms + self.design_atoms,
                         'the impostor must be indistinguishable by atom count')
        self.assertFalse(
            self.designing.trajectory_frame(self.name, _flat(_backbone(self.LENGTH))),
            'a frame must not land on an object this recording did not seed')
        self.assertEqual(cmd.count_states(self.name), 1)

    def testTheRecordingLeavesNoTitleOnANYSTATE(self):
        # The regression, and the assertion shape matters as much as the assertion. A
        # previous version identified the recording with a token stamped into state 1's
        # TITLE. `ObjectMoleculeLoadCoords` builds every appended state by copying the
        # FIRST coordinate set and `CoordSet`'s copy carries `Name`, so the token spread
        # to every state as the recording grew -- and `appkit_inspector` emits `titles`
        # for any object where some state has one, which the panel renders as a "Name"
        # row in accent colour. The user read `raymol-live:<uuid>` in the inspector for
        # the whole multi-minute run, and it survived into their .pse on states 2..N.
        #
        # Checking state 1 alone is exactly what let that through, so this checks every
        # state, and the payload the panel actually reads.
        from pymol import appkit_inspector

        def titles():
            return [cmd.get_title(self.name, s) or ''
                    for s in range(1, cmd.count_states(self.name) + 1)]

        self.assertTrue(self.seed())
        for _ in range(4):
            self.designing.trajectory_frame(self.name, _flat(_backbone(self.LENGTH)))
        self.assertEqual(cmd.count_states(self.name), 5)
        self.assertEqual(titles(), [''] * 5,
                         'a running recording must leave no state title anywhere')
        objmeta = appkit_inspector._build([self.name])['objmeta']
        self.assertNotIn('titles', objmeta[self.name],
                         'the inspector must not be given a Name row to render')

        self.designing.deliver_result(self.result_path(), self.name)
        self.assertEqual(titles(), [''] * 6,
                         'delivery must leave no state title anywhere either')
        objmeta = appkit_inspector._build([self.name])['objmeta']
        self.assertNotIn('titles', objmeta[self.name])

    def testDeliverySaysTheObjectIsPinned(self):
        # The pin survives a .pse round trip, so a user who later drags the frame slider
        # finds this one object frozen. Nothing else in the session behaves that way and
        # nothing would explain it, so delivery says so and names the way out.
        said = []
        original = self.designing.colorprinting.parrot
        self.designing.colorprinting.parrot = lambda text: said.append(text)
        try:
            self.assertTrue(self.seed())
            self.designing.trajectory_frame(self.name, _flat(_backbone(self.LENGTH)))
            self.designing.deliver_result(self.result_path(), self.name)
        finally:
            self.designing.colorprinting.parrot = original
        pinned = [t for t in said if 'pinned' in t]
        self.assertTrue(pinned, 'delivery must say the object is pinned: %r' % said)
        self.assertIn('unset state, %s' % self.name, pinned[0],
                      'and must name the way out')
        # And that the recording was completed at all. Both failure paths warn, so a
        # silent success left a degraded 2-state run indistinguishable from a good one in
        # the log.
        self.assertTrue([t for t in said if 'built live' in t],
                        'a completed recording must say so: %r' % said)

    def testTheOnlyTitleADeliveredDesignCarriesIsItsSeed(self):
        # The positive control for the test above, so "no titles" is not achieved by
        # having broken the seed provenance that predates all of this: with `seed=`, the
        # FINAL state is titled and nothing else is -- and nothing anywhere says
        # `raymol-live`.
        self.assertTrue(self.seed())
        for _ in range(3):
            self.designing.trajectory_frame(self.name, _flat(_backbone(self.LENGTH)))
        self.designing.deliver_result(self.result_path(), self.name, seed=7)
        titles = [cmd.get_title(self.name, s) or ''
                  for s in range(1, cmd.count_states(self.name) + 1)]
        self.assertEqual(titles[-1], 'seed=7')
        self.assertEqual(titles[:-1], [''] * (len(titles) - 1))
        self.assertFalse([t for t in titles if 'raymol-live' in t])

    def testDeliveryAssignsSecondaryStructureFromTheDESIGNNotTheRollout(self):
        # `dss`'s default is state 0 = ALL states, and a live object's earlier states are
        # unsettled rollout frames. Letting step 4 vote is the "every design renders as
        # featureless loops" failure the explicit state exists to prevent.
        helix = _backbone(20)                       # cmd.fab(..., ss=1) is a helix
        self.assertTrue(_seed(self.designing, self.name, length=20,
                              target=self.TARGET, coords=_cloud(20, 9.0)))
        for _ in range(4):
            self.designing.trajectory_frame(self.name, _flat(_cloud(20, 9.0)))
        path = self.tempfile()
        with open(path, 'w') as handle:
            handle.write(_result_pdb(length=20, target=self.TARGET, coords=helix))
        self.designing.deliver_result(path, self.name)

        assigned = []
        cmd.iterate('%s and chain B and name CA' % self.name, 'L.append(ss)',
                    space={'L': assigned})
        self.assertEqual(len(assigned), 20)
        self.assertIn('H', assigned,
                      'secondary structure must come from the delivered design, not from '
                      'the noise states in front of it (got %r)' % ''.join(assigned))

    # -- The camera, across the whole run --------------------------------------

    def testNothingInALiveRunMovesTheCamera(self):
        # Seeding, every frame, and delivery. The user is looking at the target for
        # minutes; a single auto-zoom on a chain that is still noise leaves them watching
        # a blank viewport for the rest of the run.
        cmd.fab('A' * 30, 'view_target', ss=1)
        cmd.translate([100.0, 100.0, 100.0], object='view_target', camera=0)
        cmd.orient('view_target')
        before = cmd.get_view()

        self.assertTrue(self.seed())
        self.assertEqual(cmd.get_view(), before, 'seeding moved the camera')
        for _ in range(3):
            self.designing.trajectory_frame(self.name, _flat(_backbone(self.LENGTH)))
        self.assertEqual(cmd.get_view(), before, 'a frame moved the camera')
        self.designing.deliver_result(self.result_path(), self.name)
        self.assertEqual(cmd.get_view(), before, 'delivery moved the camera')

