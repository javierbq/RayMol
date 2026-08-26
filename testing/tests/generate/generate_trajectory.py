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


def _target_records(residues, serial):
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
            lines.append(_atom_record(serial, name, _TARGET_RESN, 'A', residue + 41,
                                      coords[residue * len(_SLOTS) + slot]))
            serial += 1
    return lines, serial


def _composed_pdb(length=3, chain='B', coords=None, conect=True, target=0,
                  sequence=None):
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
    lines, serial = _target_records(target, 1)
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


def _seed_pdb(length=3, chain='B', coords=None, conect=True, target=0):
    """The seed: the same object, with the generated chain poly-ALA."""
    return _composed_pdb(length=length, chain=chain, coords=coords, conect=conect,
                         target=target)


#: The three-letter names a fixture design comes back with -- anything but ALA, so
#: "the generated chain was renamed at delivery" is observable.
_DESIGNED = ('LEU', 'GLY', 'THR', 'VAL', 'PHE', 'SER', 'GLN', 'TYR')


def _result_pdb(length=3, chain='B', coords=None, target=0):
    """What the runtime writes at the end: the same object, real sequence, real
    coordinates, and no CONECT -- a result is loaded from a file PyMOL bonds itself."""
    sequence = [_DESIGNED[index % len(_DESIGNED)] for index in range(length)]
    return _composed_pdb(length=length, chain=chain, coords=coords, conect=False,
                         target=target, sequence=sequence)


def _seed(designing, name, length=3, chain='B', coords=None, conect=True, target=0):
    """`trajectory_seed` with the layout the writer would have reported.

    The offset and the atom count are arguments on the wire because the Python side must
    not have to work out where the generated chain starts -- so the fixture states them
    too, from the same two numbers that shaped the string.
    """
    return designing.trajectory_seed(
        name, _seed_pdb(length=length, chain=chain, coords=coords, conect=conect,
                        target=target),
        target * len(_SLOTS), length * len(_SLOTS))


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

        # PRECONDITION, so this test can fail: the same string read WITHOUT the fix does
        # produce inter-chain bonds. Without this the assertion below would pass on a
        # fixture that simply never overlapped.
        raw = _seed_pdb(length=self.LENGTH, coords=overlapping, target=self.TARGET)
        cmd.read_pdbstr(raw, 'unfixed', zoom=0)
        self.assertGreater(self._inter_chain_bonds('unfixed'), 0,
                           'the fixture must actually put the two chains in contact')
        cmd.delete('unfixed')

        self.assertTrue(self.seed(coords=overlapping))
        self.assertEqual(self._inter_chain_bonds(self.name), 0)
        # And the generated chain still has its own backbone: the unbond must take the
        # inter-chain bonds and nothing else.
        self.assertEqual(len(cmd.get_model('%s and chain B' % self.name).bond),
                         4 * self.LENGTH + (self.LENGTH - 1))

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
            self.assertEqual(cmd.get_state(), expected,
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
        self.assertEqual(cmd.get_state(), cmd.count_states(self.name),
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

    def testAFinishedDesignIsKeptByASessionSave(self):
        # The negative control: same object, after delivery.
        self.designing.register_pending(self.name, 'job-1')
        self.assertTrue(self.seed())
        self.designing.deliver_result(self.result_path(), self.name)
        session = {'names': [[self.name, 0], ['something_else', 0]]}
        self.designing.session_save(session)
        self.assertEqual([entry[0] for entry in session['names']],
                         [self.name, 'something_else'])

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

