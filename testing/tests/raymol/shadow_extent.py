"""Shadow-frustum extent: solvent exclusion + cache invalidation (#393).

The Metal shadow pass used to call ExecutiveGetExtent(G, "not solvent", ...) on
every frame. That is a name *pattern*, not an atom selection, so it matched
every object and named selection not literally called `solvent` (waters were
never excluded) and it re-walked every atom at up to 120 Hz. The extent is now
computed over the scene's own object list, solvent skipped, and cached until the
scene's contents change.

Runs on a RayMol --testing build:
    pymol -ckqy testing/testing.py --run tests/raymol/shadow_extent.py
"""
from pymol import cmd, testing
from pymol import _cmd

# Two protein atoms in a 1 A box at the origin, plus waters 50 A away.
_PDB = """\
ATOM      1  N   ALA A   1       0.000   0.000   0.000  1.00  0.00           N
ATOM      2  CA  ALA A   1       1.000   1.000   1.000  1.00  0.00           C
HETATM    3  O   HOH A   2      50.000  50.000  50.000  1.00  0.00           O
HETATM    4  O   HOH A   3     -50.000 -50.000 -50.000  1.00  0.00           O
END
"""


class TestShadowExtent(testing.PyMOLTestCase):
    def shadowExtent(self):
        """The cached extent, as the Metal shadow pass sees it."""
        with cmd.lockcm:
            return _cmd.get_shadow_extent(cmd._COb)

    def freshExtent(self):
        """The same extent, recomputed from scratch.

        Adding and removing a throwaway object invalidates the cache without
        disturbing any other object's coordinates or enabled state, so this is
        the ground truth the cached value has to keep matching.
        """
        cmd.pseudoatom('_shadow_probe', pos=[0.0, 0.0, 0.0])
        cmd.delete('_shadow_probe')
        return self.shadowExtent()

    def assertExtentEqual(self, a, b, delta=1e-4, msg=None):
        self.assertIsNotNone(a, msg)
        self.assertIsNotNone(b, msg)
        for corner_a, corner_b in zip(a, b):
            for x, y in zip(corner_a, corner_b):
                self.assertAlmostEqual(x, y, delta=delta, msg=msg)

    def assertCacheIsFresh(self, after):
        """The cached extent still agrees with a from-scratch recompute."""
        self.assertExtentEqual(self.shadowExtent(), self.freshExtent(),
                               msg='stale shadow extent after %s' % after)

    # --- what the box covers -------------------------------------------------
    def testSolventIsExcluded(self):
        cmd.reinitialize()
        cmd.read_pdbstr(_PDB, 'm1')
        self.assertEqual(cmd.count_atoms('solvent'), 2)
        # The waters are 50 A out and do bound the model...
        self.assertExtentEqual(cmd.get_extent('all'),
                               [[-50.0, -50.0, -50.0], [50.0, 50.0, 50.0]])
        # ...but the shadow frustum must not be stretched to reach them.
        self.assertExtentEqual(self.shadowExtent(),
                               [[0.0, 0.0, 0.0], [1.0, 1.0, 1.0]])

    def testSolventOnlySceneFallsBackToAllAtoms(self):
        """A frustum sized to nothing would collapse the shadow map."""
        cmd.reinitialize()
        cmd.read_pdbstr(_PDB, 'm1')
        cmd.remove('not solvent')
        self.assertEqual(cmd.count_atoms('all'), 2)
        self.assertExtentEqual(self.shadowExtent(),
                               [[-50.0, -50.0, -50.0], [50.0, 50.0, 50.0]])

    def testEmptySceneHasNoExtent(self):
        cmd.reinitialize()
        self.assertIsNone(self.shadowExtent())

    def testDisabledObjectsAreExcluded(self):
        """Disabled objects cast no shadow, so they must not widen the box."""
        cmd.reinitialize()
        cmd.read_pdbstr(_PDB, 'm1')
        cmd.pseudoatom('m2', pos=[70.0, 0.0, 0.0])
        self.assertAlmostEqual(self.shadowExtent()[1][0], 70.0, delta=1e-4)
        cmd.disable('m2')
        self.assertAlmostEqual(self.shadowExtent()[1][0], 1.0, delta=1e-4)
        cmd.enable('m2')
        self.assertAlmostEqual(self.shadowExtent()[1][0], 70.0, delta=1e-4)

    # --- the cache -----------------------------------------------------------
    def testCameraMotionDoesNotMoveTheBox(self):
        """It is model-space: this is what makes caching it across frames safe."""
        cmd.reinitialize()
        cmd.read_pdbstr(_PDB, 'm1')
        before = self.shadowExtent()
        cmd.turn('x', 37)
        cmd.zoom()
        cmd.move('z', 12)
        self.assertExtentEqual(self.shadowExtent(), before)

    def testCacheTracksContentChanges(self):
        cmd.reinitialize()
        cmd.read_pdbstr(_PDB, 'm1')
        self.assertCacheIsFresh('load')

        cmd.pseudoatom('m2', pos=[70.0, 0.0, 0.0])
        self.assertCacheIsFresh('new object')

        cmd.disable('m2')
        self.assertCacheIsFresh('disable')
        cmd.enable('m2')
        self.assertCacheIsFresh('enable')
        cmd.delete('m2')
        self.assertCacheIsFresh('delete')

        cmd.translate([20.0, 0.0, 0.0], object='m1', camera=0)
        self.assertCacheIsFresh('object TTT translate')
        cmd.rotate('x', 90, object='m1', camera=0)
        self.assertCacheIsFresh('object TTT rotate')
        cmd.matrix_reset('m1', mode=1)
        self.assertCacheIsFresh('TTT reset')

        cmd.set('matrix_mode', 2)
        cmd.rotate('z', 45, object='m1', camera=0)
        self.assertCacheIsFresh('object state-matrix rotate')
        cmd.matrix_reset('m1', mode=2)
        self.assertCacheIsFresh('state-matrix reset')
        cmd.set('matrix_mode', 0)

        cmd.translate([0.0, 30.0, 0.0], selection='m1 and name CA', camera=0)
        self.assertCacheIsFresh('coordinate edit')
        cmd.alter_state(1, 'm1 and name N', '(x,y,z)=(0,0,80)')
        self.assertCacheIsFresh('alter_state')
        cmd.load_coords([[0, 0, 0], [3, 3, 3], [50, 50, 50], [-50, -50, -50]],
                        'm1')
        self.assertCacheIsFresh('load_coords')
        cmd.remove('m1 and name CA')
        self.assertCacheIsFresh('remove atom')

        cmd.fragment('trp', 'm4')
        self.assertCacheIsFresh('fragment')
        cmd.reinitialize()
        self.assertIsNone(self.shadowExtent())
