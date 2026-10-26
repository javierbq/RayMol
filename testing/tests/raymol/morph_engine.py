'''
Testing: morph engine helpers and key-frame exactness.

Tests that:
  - key_frames() returns the correct 1-based state numbers
  - residue_order() sorts (resv, resi) keys numerically then by insertion code
  - _Screw.at(1) is exact for 60 random screws (including tiny and ~180 deg)
  - _axis_angle handles 180 deg and 1e-7 rad without collapse
  - _fit (Horn's quaternion method) recovers random rigid motions to 1e-6,
    a 180 deg turn about each principal axis, and never fails on
    near-collinear (strand-like) points; rigid morphs of a bent flat
    peptide and of a flexible-peptide ensemble succeed (the old iterative
    fit raised ValueError on both)
  - _split_runs implements the ChimeraX hinge rule
  - _index_ranges compresses sorted ints to PyMOL range syntax
  - morph() keeps key-frame states as exact copies of the input models
  - multi-state morph with state1=0 / state2=0 / state2=-1 state counts
  - steps=1 / bad method / bad rate / unknown alignment raise CmdException
  - a state with no coordinates raises CmdException and leaves no output
  - the output name: an input object, a group or a selection is refused and
    left as it was; a failed morph leaves an existing object of that name as
    it was, also when the final rename fails; a morph that succeeds replaces
    it (running the same morph command again works); the name is legalised
    before it is compared with the inputs; no scratch object is left behind

Runs on a RayMol --testing build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/morph_engine.py
'''

import math
import random
from unittest import mock

import pymol
from pymol import cmd, testing

import pymol.morphing as morphing


# --------------------------------------------------------------------------
# module-level helpers used by multiple tests

def coords(obj, state):
    '''Dict keyed by (segi, chain, resi, name, alt) -> (x, y, z).'''
    c = {}
    cmd.iterate_state(state, obj,
                      'c[(segi, chain, resi, name, alt)] = (x, y, z)',
                      space={'c': c})
    return c


def max_dev(a, b):
    '''Max per-coordinate absolute deviation between two coord dicts.'''
    shared = set(a) & set(b)
    if not shared:
        return float('inf')
    return max(max(abs(a[k][i] - b[k][i]) for i in range(3)) for k in shared)


def ca_xyz(obj, resi, state=1):
    '''Coordinates of residue *resi*'s CA as a list of 3 floats.'''
    return [float(v) for v in
            cmd.get_coords('%s and resi %d and name CA' % (obj, resi), state)[0]]


def rigidly_moved(pts, rng):
    '''*pts* under a random rotation (any angle up to 180 deg) and a random
    translation.'''
    axis = [rng.gauss(0, 1) for _ in range(3)]
    axis = morphing._scale(axis, 1.0 / morphing._norm(axis))
    R = morphing._rodrigues(axis, rng.uniform(0.0, math.pi))
    t = [rng.uniform(-20, 20) for _ in range(3)]
    return [morphing._add(morphing._rot_apply(R, p), t) for p in pts]


def fitted(R, cs, ct, pts):
    '''_fit's result applied to *pts*: R·(x - cs) + ct.'''
    if R is None:
        return [morphing._add(morphing._sub(p, cs), ct) for p in pts]
    return [morphing._add(morphing._rot_apply(R, morphing._sub(p, cs)), ct)
            for p in pts]


def rmsd(a, b):
    return math.sqrt(sum(morphing._dot(morphing._sub(p, q), morphing._sub(p, q))
                         for p, q in zip(a, b)) / len(a))


def det3(R):
    return morphing._dot(R[0], morphing._cross(R[1], R[2]))


# --------------------------------------------------------------------------

class TestMorphEngine(testing.PyMOLTestCase):

    # ---- key_frames helper ---------------------------------------------------

    def testKeyFramesHelper(self):
        self.assertEqual(morphing.key_frames(15, 5, 3), [1, 6, 11, 15])
        self.assertEqual(morphing.key_frames(10, 5, 2), [1, 6, 10])
        # single leg: first and last only
        self.assertEqual(morphing.key_frames(5, 5, 1), [1, 5])

    # ---- residue_order -------------------------------------------------------

    def testInsertionCodesOrder(self):
        keys = [(10, '10'), (2, '2A'), (-1, '-1'), (2, '2')]
        self.assertEqual([k[1] for k in morphing.residue_order(keys)],
                         ['-1', '2', '2A', '10'])
        # morph on an object with insertion codes must not crash
        cmd.fab('ACDEFGHIKLMNPQ', 'ins')
        cmd.alter('ins and resi 1', 'resi="-1"')
        cmd.alter('ins and resi 3', 'resi="2A"')
        cmd.create('ins', 'ins', 1, 2)
        cmd.rotate('y', 60, 'ins and resi 8-14', 2)
        self.assertEqual(
            cmd.morph('mi', 'ins', steps=4, method='rigimol', refinement=0),
            4)

    # ---- key frames stay exact under non-zero refinement ---------------------

    def testKeyFramesExactAtDefaultRefinement(self):
        cmd.fab('ACDEFGHIK', 'm1')
        cmd.create('m1', 'm1', 1, 2)
        cmd.create('m1', 'm1', 1, 3)
        cmd.rotate('x', 90, 'm1', 2)
        cmd.rotate('x', 45, 'm1', 3)
        # 3 states, steps=5 -> 15 total; default refinement=3
        n = cmd.morph('mo', 'm1', None, 0, -1, 3, 5, 'rigimol')
        self.assertEqual(n, 15)
        # key frames at 1, 6, 11 are the input models; state 15 is model 1 again
        for state, model in ((1, 1), (6, 2), (11, 3), (15, 1)):
            self.assertLess(
                max_dev(coords('mo', state), coords('m1', model)), 1e-4,
                'state %d should match model %d' % (state, model))

    # ---- multi-state state count semantics ----------------------------------

    def testMultiStateStateCounts(self):
        cmd.fab('ACD', 'm1')
        cmd.create('m1', 'm1', 1, 2)
        cmd.create('m1', 'm1', 1, 3)
        cmd.rotate('x', 90, 'm1', 2)
        cmd.rotate('x', 45, 'm1', 3)

        # state1=0, state2=0  -> N-1 legs (no wrap) -> (N-1)*steps states
        n = cmd.morph('mout', 'm1', None, 0, 0, 0, 5, 'linear')
        self.assertEqual(n, 10)

        # state1=0, state2=-1 -> N legs (wrap back to 1) -> N*steps states
        n = cmd.morph('mo2', 'm1', None, 0, -1, 0, 5, 'linear')
        self.assertEqual(n, 15)
        self.assertLess(max_dev(coords('mo2', 15), coords('m1', 1)), 1e-4)
        self.assertLess(max_dev(coords('mo2', 6), coords('m1', 2)), 1e-4)

    # ---- screw math: self-tests (ported from POC harness) -------------------

    def testScrewAtOne(self):
        '''_Screw.at(1) reproduces the rigid transform for 60 random screws
        including 1e-6 rad and ~180 deg cases; tolerance 1e-7 Å.'''
        _add = morphing._add
        _sub = morphing._sub
        _rot_apply = morphing._rot_apply
        _rodrigues = morphing._rodrigues
        _norm = morphing._norm
        _Screw = morphing._Screw
        worst_f1 = worst_f0 = worst_pb = 0.0
        rng = random.Random(3)
        special_angles = [1e-6, 5e-5, math.pi - 1e-9, 2.0e-4]
        for trial in range(60):
            u = [rng.gauss(0, 1) for _ in range(3)]
            n = _norm(u)
            u = [x / n for x in u]
            if trial % 10 == 0:
                th = special_angles[trial // 10 % len(special_angles)]
            else:
                th = rng.uniform(1e-3, math.pi - 1e-3)
            R = _rodrigues(u, th)
            c0 = [rng.uniform(-30, 30) for _ in range(3)]
            c1 = [rng.uniform(-30, 30) for _ in range(3)]
            sc = _Screw(R, c0, c1)
            x = [rng.uniform(-20, 20) for _ in range(3)]
            want = _add(_rot_apply(R, _sub(x, c0)), c1)
            got = sc.at(1.0)(x)
            e1 = max(abs(a - b) for a, b in zip(want, got))
            e0 = max(abs(a - b) for a, b in zip(x, sc.at(0.0)(x)))
            eb = max(abs(a - b) for a, b in zip(x, sc.pull_back(want)))
            worst_f1 = max(worst_f1, e1)
            worst_f0 = max(worst_f0, e0)
            worst_pb = max(worst_pb, eb)
        self.assertLess(worst_f1, 1e-7,
            'Screw.at(1) worst error %.2e' % worst_f1)
        self.assertLess(worst_f0, 1e-9,
            'Screw.at(0) worst error %.2e' % worst_f0)
        self.assertLess(worst_pb, 1e-7,
            'Screw.pull_back worst error %.2e' % worst_pb)

    def testScrewCorkscrew(self):
        '''90 deg screw taking origin to (10,10,5): axis point at (0,10,0).'''
        _add = morphing._add
        _sub = morphing._sub
        _norm = morphing._norm
        _rodrigues = morphing._rodrigues
        _Screw = morphing._Screw
        sc = _Screw(_rodrigues([0, 0, 1.0], math.pi / 2),
                    [0.0, 0.0, 0.0], [10.0, 10.0, 5.0])
        self.assertLess(
            max(abs(a - b) for a, b in zip(sc.p, [0.0, 10.0, 0.0])), 1e-9,
            'axis point should be (0,10,0)')
        mid = sc.at(0.5)([0.0, 0.0, 0.0])
        self.assertLess(
            abs(_norm(_sub(mid, [0.0, 10.0, 2.5])) - 10.0), 1e-9,
            'midpoint radius from axis point should be 10')
        self.assertLess(abs(mid[2] - 2.5), 1e-9, 'midpoint z should be 2.5')
        self.assertLess(abs(mid[0] - 10 * math.sin(math.pi / 4)), 1e-9,
                        'midpoint x at 45 deg on the circle')

    # ---- axis-angle corner cases --------------------------------------------

    def testAxisAngleAt180(self):
        ua, ta = morphing._axis_angle(morphing._rodrigues([0, 0, 1.0], math.pi))
        self.assertLess(abs(ta - math.pi), 1e-9, 'angle should be pi')
        self.assertLess(abs(abs(ua[2]) - 1.0), 1e-9, 'axis should be z')

    def testAxisAngleSmall(self):
        _, ta = morphing._axis_angle(morphing._rodrigues([1.0, 0, 0], 1e-7))
        self.assertLess(abs(ta - 1e-7), 1e-12,
                        'axis-angle at 1e-7 rad must not collapse to zero')

    # ---- rigid fit ----------------------------------------------------------

    def testFitRecoversRandomRigidMotions(self):
        '''_fit undoes 200 random rotations + translations of a 30-point
        cloud to 1e-6 Å (the old iterative fit stopped at a 1e-3 tolerance).'''
        rng = random.Random(5)
        cloud = [[rng.uniform(-10, 10) for _ in range(3)] for _ in range(30)]
        worst = 0.0
        for trial in range(200):
            target = rigidly_moved(cloud, rng)
            R, cs, ct = morphing._fit(target, cloud)
            worst = max(worst, max(max(abs(a - b) for a, b in zip(f, t))
                                   for f, t in zip(fitted(R, cs, ct, cloud), target)))
        self.assertLess(worst, 1e-6, 'worst fitted deviation %.2e' % worst)

    def testFitRecovers180AboutPrincipalAxes(self):
        '''A 180 deg turn about a principal axis makes the correlation matrix
        symmetric; the old fit took that for convergence at the identity.'''
        import numpy
        cmd.fab('A' * 15, 'hx', ss=1)
        cloud = [list(map(float, p)) for p in cmd.get_coords('hx and name CA')]
        c = numpy.mean(cloud, axis=0)
        _, axes = numpy.linalg.eigh(numpy.cov((numpy.array(cloud) - c).T))
        for k in range(3):
            R = morphing._rodrigues([float(v) for v in axes[:, k]], math.pi)
            target = [morphing._add(morphing._rot_apply(R, morphing._sub(p, list(c))),
                                    [5.0, -3.0, 2.0]) for p in cloud]
            Rf, cs, ct = morphing._fit(target, cloud)
            _, theta = morphing._axis_angle(Rf)
            self.assertLess(abs(math.degrees(theta) - 180.0), 0.01,
                            'axis %d: fit angle %.4f deg' % (k, math.degrees(theta)))

    def testFitNeverFailsOnStrandLikePoints(self):
        '''Near-collinear guide sets (a beta strand's CAs) made the old fit
        raise a bare ValueError ("too many iterations").'''
        rng = random.Random(7)
        worst = 0.0
        for trial in range(500):
            strand = [[3.3 * i + rng.gauss(0, 0.3),
                       (1.0 if i % 2 else -1.0) + rng.gauss(0, 0.3),
                       rng.gauss(0, 0.3)] for i in range(12)]
            target = rigidly_moved(strand, rng)
            R, cs, ct = morphing._fit(target, strand)
            self.assertLess(abs(det3(R) - 1.0), 1e-9, 'a proper rotation')
            worst = max(worst, rmsd(fitted(R, cs, ct, strand), target))
        self.assertLess(worst, 0.5, 'worst rmsd %.3g' % worst)

    def testRigidMorphOfBentFlatPeptide(self):
        # A flat 24-mer whose C-terminal half turns 60 deg about an axis
        # across the chain at CA 12: the second segment's fit raised
        # ValueError and the whole morph failed.
        cmd.fab('A' * 24, 'pep', ss=0)
        cmd.create('pep', 'pep', 1, 2)
        along = morphing._sub(ca_xyz('pep', 24), ca_xyz('pep', 1))
        across = morphing._cross(along, [0.1, 0.2, 1.0])
        cmd.rotate(across, 60, 'pep and resi 13-24', 2, camera=0,
                   origin=ca_xyz('pep', 12))
        self.assertEqual(cmd.morph('m', 'pep', state1=1, state2=2, steps=10,
                                   refinement=0), 10)
        self.assertLess(max_dev(coords('m', 10), coords('pep', 2)), 1e-3)

    def testRigidMorphOfFlexiblePeptideEnsemble(self):
        # A 5-model GS-repeat ensemble, each model bent +/-30 deg at three
        # points: an ordinary disordered-peptide NMR ensemble, for which the
        # old fit failed in 8 of 10 seeds.
        rng = random.Random(0)
        cmd.fab('GS' * 10, 'p', ss=0)
        for st in range(2, 6):
            cmd.create('p', 'p', 1, st)
            for pivot in (6, 11, 16):
                axis = [rng.gauss(0, 1) for _ in range(3)]
                cmd.rotate(axis, rng.uniform(-30, 30), 'p and resi %d-20' % (pivot + 1),
                           st, camera=0, origin=ca_xyz('p', pivot, st))
        self.assertEqual(cmd.morph('m', 'p', state1=0, steps=4, refinement=0), 20)
        for state, model in ((1, 1), (5, 2), (9, 3), (13, 4), (17, 5), (20, 1)):
            self.assertLess(max_dev(coords('m', state), coords('p', model)), 1e-3,
                            'state %d should be model %d' % (state, model))

    # ---- hinge rule ---------------------------------------------------------

    def testSplitRuns(self):
        T, F = True, False
        self.assertEqual(
            morphing._split_runs([T] * 10 + [F] * 3 + [T] * 10, 6), [13],
            'short false run merges into the preceding block -> cut at 13')
        self.assertEqual(
            morphing._split_runs([T] * 10 + [F] * 8 + [T] * 10, 6), [10, 18],
            'long false run -> cuts at 10 and 18')
        self.assertEqual(
            morphing._split_runs([T] * 4 + [F] * 4 + [T] * 4, 6), [],
            'all runs short -> no cuts')

    # ---- index_ranges -------------------------------------------------------

    def testIndexRanges(self):
        self.assertEqual(
            morphing._index_ranges([1, 2, 3, 7, 9, 10]), '1-3+7+9-10')

    # ---- error handling -----------------------------------------------------

    def testErrorSteps1(self):
        cmd.fab('ACDE', 'e1a')
        cmd.create('e1a', 'e1a', 1, 2)
        try:
            cmd.morph('bad', 'e1a', steps=1)
            self.fail('steps=1 should raise CmdException')
        except pymol.CmdException as e:
            self.assertIn('morph:', str(e),
                          'error text should contain morph: but got: %s' % e)

    def testErrorBadMethod(self):
        cmd.fab('ACDE', 'e2a')
        cmd.create('e2a', 'e2a', 1, 2)
        try:
            cmd.morph('bad', 'e2a', method='bogus')
            self.fail('bad method should raise CmdException')
        except pymol.CmdException as e:
            self.assertIn('morph:', str(e),
                          'error text should contain morph: but got: %s' % e)

    def testErrorBadRate(self):
        cmd.fab('ACDE', 'e3a')
        cmd.create('e3a', 'e3a', 1, 2)
        try:
            cmd.morph('bad', 'e3a', rate='bogus')
            self.fail('bad rate should raise CmdException')
        except pymol.CmdException as e:
            self.assertIn('morph:', str(e),
                          'error text should contain morph: but got: %s' % e)

    def testErrorStateOutOfRangeLeavesNothing(self):
        # state2 beyond the object's states: a CmdException (was a raw
        # KeyError from _coords_by_pos) and no half-built output object.
        cmd.fab('ACDE', 'o5')
        cmd.create('o5', 'o5', 1, 2)
        with self.assertRaisesRegex(pymol.CmdException,
                                    'missing coordinates in state 5'):
            cmd.morph('mb', 'o5', state1=1, state2=5)
        self.assertNotIn('mb', cmd.get_names('objects'))

    # ---- the output name ----------------------------------------------------

    def three_models(self, name):
        cmd.fab('ACDEFGHIK', name)
        cmd.create(name, name, 1, 2)
        cmd.create(name, name, 1, 3)
        cmd.rotate('x', 90, name, 2)
        cmd.rotate('x', 45, name, 3)

    def snapshot(self, obj):
        '''Atom count, state count and every state's coordinates.'''
        n = cmd.count_states(obj)
        return (cmd.count_atoms(obj), n,
                [coords(obj, s) for s in range(1, n + 1)])

    def assertNoScratchObjects(self):
        self.assertEqual([n for n in cmd.get_names('all') if n.startswith('_morph')],
                         [])

    def testOutputCannotBeAnInput(self):
        # `morph a, a` merged the frames into the source, failed on the state
        # count, and the failure clean-up then deleted the source.
        self.three_models('a')
        before = self.snapshot('a')
        with self.assertRaisesRegex(pymol.CmdException, 'cannot be an input'):
            cmd.morph('a', 'a', steps=5, refinement=0)
        self.assertEqual(self.snapshot('a'), before)
        # the second of two objects too
        cmd.create('a2', 'a', 2, 1)
        before = self.snapshot('a2')
        with self.assertRaisesRegex(pymol.CmdException, 'cannot be an input'):
            cmd.morph('a2', 'a', 'a2', steps=5, refinement=0)
        self.assertEqual(self.snapshot('a2'), before)
        self.assertEqual(cmd.get_names('objects'), ['a', 'a2'])
        self.assertNoScratchObjects()

    def testOutputCannotReplaceAGroupOrASelection(self):
        self.three_models('g1')
        cmd.group('grp', 'g1')
        with self.assertRaisesRegex(pymol.CmdException, 'grp is a group'):
            cmd.morph('grp', 'g1', steps=5, refinement=0)
        self.assertEqual(cmd.get_type('grp'), 'object:group')
        self.assertEqual(cmd.count_states('g1'), 3)
        cmd.select('mysel', 'g1 and name CA')
        with self.assertRaisesRegex(pymol.CmdException, 'mysel is a selection'):
            cmd.morph('mysel', 'g1', steps=5, refinement=0)
        self.assertEqual(cmd.count_atoms('mysel'), 9)
        self.assertNoScratchObjects()

    def testFailedMorphLeavesAnExistingObjectAlone(self):
        # The failure clean-up deleted whatever held the name, here an object
        # unrelated to the morph.
        cmd.fab('ACDE', 'o5')
        cmd.create('o5', 'o5', 1, 2)
        cmd.fab('GGG', 'keepme')
        before = self.snapshot('keepme')
        with self.assertRaisesRegex(pymol.CmdException,
                                    'missing coordinates in state 5'):
            cmd.morph('keepme', 'o5', state1=1, state2=5)
        self.assertEqual(self.snapshot('keepme'), before)
        self.assertEqual(cmd.get_names('objects'), ['o5', 'keepme'])
        self.assertNoScratchObjects()

    def testMorphAgainReplacesItsOutput(self):
        # Running the same morph command again failed ("expected 5 states,
        # got 9": create merged into the earlier output) and then deleted it.
        self.three_models('m1')
        self.assertEqual(cmd.morph('mout', 'm1', steps=5, refinement=0), 5)
        self.assertEqual(cmd.morph('mout', 'm1', None, 0, -1, 0, 5, 'linear'), 15)
        self.assertEqual(cmd.count_states('mout'), 15)
        self.assertEqual(cmd.count_atoms('mout'), cmd.count_atoms('m1'))
        self.assertLess(max_dev(coords('mout', 6), coords('m1', 2)), 1e-4)
        self.assertEqual(cmd.get_names('objects'), ['m1', 'mout'])
        # a re-run that fails leaves the earlier output as it was
        before = self.snapshot('mout')
        with self.assertRaisesRegex(pymol.CmdException,
                                    'missing coordinates in state 5'):
            cmd.morph('mout', 'm1', state1=1, state2=5)
        self.assertEqual(self.snapshot('mout'), before)
        self.assertEqual(cmd.get_names('objects'), ['m1', 'mout'])
        self.assertNoScratchObjects()

    def testFailedRenameKeepsTheEarlierOutput(self):
        # The earlier output is moved aside, not deleted, until the new morph
        # holds the name.
        self.three_models('m3')
        cmd.morph('mout', 'm3', steps=5, refinement=0)
        before = self.snapshot('mout')
        real = cmd.set_name

        def failing(old, new, *a, **k):
            if old.startswith('_morph_out'):
                raise pymol.CmdException('simulated rename failure')
            return real(old, new, *a, **k)

        with mock.patch.object(cmd, 'set_name', side_effect=failing):
            with self.assertRaisesRegex(pymol.CmdException, 'simulated'):
                cmd.morph('mout', 'm3', steps=4, refinement=0)
        self.assertEqual(self.snapshot('mout'), before)
        self.assertEqual(cmd.get_names('objects'), ['m3', 'mout'])
        self.assertNoScratchObjects()

    def testOutputNameIsLegalised(self):
        # create legalises the name; the morph then addressed the raw one.
        self.three_models('m2')
        self.assertEqual(cmd.morph('my morph', 'm2', steps=3, refinement=0), 3)
        self.assertEqual(cmd.count_states('my_morph'), 3)
        # a spelling that legalises to an input names that input
        before = self.snapshot('my_morph')
        with self.assertRaisesRegex(pymol.CmdException, 'cannot be an input'):
            cmd.morph('my morph', 'my_morph', steps=3, refinement=0)
        self.assertEqual(self.snapshot('my_morph'), before)
        # an object can be created as "same", but none can be renamed to it
        cmd.create('same', 'm2', 1, 1)
        before = self.snapshot('same')
        with self.assertRaisesRegex(pymol.CmdException, 'same is a selection keyword'):
            cmd.morph('same', 'm2', steps=3, refinement=0)
        self.assertEqual(self.snapshot('same'), before)
        self.assertEqual(cmd.get_names('objects'), ['m2', 'my_morph', 'same'])
        self.assertNoScratchObjects()

    def testErrorUnknownAlignment(self):
        cmd.fab('ACDE', 'e4a')
        cmd.create('e4b', 'e4a', 1, 1)
        try:
            cmd.morph('bad', 'e4a', 'e4b', match='nosuch')
            self.fail('unknown alignment object should raise CmdException')
        except pymol.CmdException as e:
            self.assertIn('morph:', str(e),
                          'error text should contain morph: but got: %s' % e)
