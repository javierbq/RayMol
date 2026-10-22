'''
Testing: morph_jobs.py building blocks — naming, estimate, validation,
look copy, titles, fingerprint.

Tests that:
  - morph_name() returns the expected name and handles collisions
  - validate_source() returns (atoms, models) and raises on bad input
  - morph_estimate() returns correct fields and bytes formula
  - copy_look() copies explicit per-object settings, hides surface/mesh
  - set_state_titles() labels key frames and intermediates correctly
  - fingerprint() returns a dict that changes when state count changes

Runs on a RayMol --testing build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/morph_jobs.py
'''

import pymol
import pymol.setting
from pymol import cmd, testing

import pymol.morph_jobs as mj


def _settings_by_name(obj):
    '''Map setting-name -> raw value for per-object explicit settings on obj.'''
    result = cmd.get_object_settings(obj) or []
    return {pymol.setting._get_name(r[0]): r[2] for r in result}


class TestMorphJobsBlocks(testing.PyMOLTestCase):

    # ---- morph_name ----------------------------------------------------------

    def testMorphNameAndCollision(self):
        cmd.fab('ACD', 'src')
        self.assertEqual(mj.morph_name('src'), 'src_morph')
        cmd.fab('ACD', 'src_morph')          # non-morph squats on the name
        self.assertEqual(mj.morph_name('src'), 'src_morph2')

    # ---- validate_source -----------------------------------------------------

    def testValidateRefusesDiscreteAndMismatch(self):
        # Happy path: two identical states
        cmd.fab('ACD', 'ok')
        cmd.create('ok', 'ok', 1, 2)
        self.assertEqual(mj.validate_source('ok'),
                         (cmd.count_atoms('ok'), 2))

        # Atom-count mismatch: state 1 = ACD atoms, state 2 = AC atoms
        cmd.fab('ACD', 'bad')
        cmd.fab('AC', 'bad_tmp')
        cmd.create('bad', 'bad_tmp', 1, 2)   # state 2 has fewer atoms than state 1
        cmd.delete('bad_tmp')
        # Sanity: state counts really differ
        self.assertNotEqual(cmd.count_atoms('bad', state=1),
                            cmd.count_atoms('bad', state=2))
        with self.assertRaisesRegex(pymol.CmdException, 'models have different atoms'):
            mj.validate_source('bad')

        # Discrete object must also be refused
        cmd.fab('ACD', 'dsrc')
        cmd.create('disc', 'dsrc', 0, 0, discrete=1)
        self.assertGreater(cmd.count_discrete('disc'), 0)
        with self.assertRaisesRegex(pymol.CmdException, 'models have different atoms'):
            mj.validate_source('disc')
        cmd.delete('disc')
        cmd.delete('dsrc')

        # Non-existent object must raise
        with self.assertRaises(pymol.CmdException):
            mj.validate_source('nosuch_object_xyz')

    # ---- morph_estimate ------------------------------------------------------

    def testEstimate(self):
        cmd.fab('ACDEFGHIK', 'ee')
        cmd.create('ee', 'ee', 1, 2)
        cmd.create('ee', 'ee', 1, 3)
        cmd.hide('everything', 'ee')

        est = mj.morph_estimate('ee', frames_per_model=10, loop=1)
        self.assertEqual((est['models'], est['legs'], est['frames']), (3, 3, 30))

        atoms = cmd.count_atoms('ee')
        expected_bytes = int(atoms * 30 * 12 * 1.1)
        self.assertAlmostEqual(est['bytes'], expected_bytes,
                               delta=expected_bytes * 0.1)

        # With cartoon shown, bytes should grow (larger rep_cost)
        cmd.show('cartoon', 'ee')
        self.assertGreater(mj.morph_estimate('ee', 10, 1)['bytes'], est['bytes'])

        # Small molecule → warn/refuse should be False
        self.assertFalse(est['warn'])
        self.assertFalse(est['refuse'])

        # loop=0 → legs = models - 1 = 2
        self.assertEqual(mj.morph_estimate('ee', 10, 0)['legs'], 2)

    # ---- copy_look -----------------------------------------------------------

    def testCopyLookExplicitOnly(self):
        cmd.fab('ACD', 'aa')
        cmd.fab('ACD', 'bb')

        cmd.set('cartoon_material', 'metallic', 'aa')
        cmd.set('stick_transparency', 0.4, 'aa')
        cmd.set('state', 1, 'aa')        # should NOT be copied

        cmd.show('surface', 'aa')
        cmd.show('mesh', 'aa')
        cmd.show('cartoon', 'bb')
        cmd.show('surface', 'bb')

        copied = mj.copy_look('aa', 'bb')

        # cartoon_material and stick_transparency copied; state excluded
        self.assertIn('cartoon_material', copied)
        self.assertIn('stick_transparency', copied)
        self.assertNotIn('state', copied)

        # stick_transparency value was transferred
        self.assertAlmostEqual(cmd.get_setting_float('stick_transparency', 'bb'),
                               0.4, places=3)

        # Global-only values (e.g. cartoon_transparency not set on 'aa')
        # must not appear as per-object settings on 'bb'
        bb_settings = _settings_by_name('bb')
        self.assertNotIn('cartoon_transparency', bb_settings)

        # surface and mesh must be hidden on dst regardless of src
        self.assertEqual(cmd.count_atoms('bb and rep surface'), 0)
        self.assertEqual(cmd.count_atoms('bb and rep mesh'), 0)

    # ---- set_state_titles ----------------------------------------------------

    def testTitles(self):
        cmd.fab('ACD', 'tt')
        for _ in range(14):
            cmd.create('tt', 'tt', 1, -1)   # 15 states total = 3 models × 5 frames

        mj.set_state_titles('tt', models=3, frames_per_model=5, loop=1)

        self.assertEqual(
            [cmd.get_title('tt', s) for s in (1, 2, 6, 11, 15)],
            ['model 1', '1 → 2', 'model 2', 'model 3', 'model 1'],
        )

    # ---- fingerprint ---------------------------------------------------------

    def testFingerprintChangesWithStates(self):
        cmd.fab('ACD', 'ff')
        cmd.create('ff', 'ff', 1, 2)

        fp = mj.fingerprint('ff')
        self.assertEqual(fp['state_count'], 2)
        self.assertIn('atom_count', fp)
        self.assertIn('crc32', fp)

        # Adding a third state changes the fingerprint (state_count differs)
        cmd.create('ff', 'ff', 1, 3)
        self.assertNotEqual(fp, mj.fingerprint('ff'))
