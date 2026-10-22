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
  - MorphJob pipeline: start_job / step / pump land one leg at a time,
    morph_object(async_=0) runs it to completion, cancel deletes the partial
    object, the pending surface publishes designing-shaped records, and the
    reuse and explicit-name rules hold

Runs on a RayMol --testing build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/morph_jobs.py
'''

import json

import pymol
import pymol.setting
from pymol import cmd, testing

import pymol.morph_jobs as mj


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


#: The record keys designing.pending_info publishes; the Swift tray decodes
#: exactly this shape.
_RECORD_KEYS = {'state', 'phase', 'fraction', 'moving', 'models_done',
                'models_total', 'elapsed', 'error', 'detail', 'bundle',
                'step', 'total_steps', 'remaining', 'batch', 'batch_index',
                'batch_total', 'run_remaining'}


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


class TestMorphJobPipeline(testing.PyMOLTestCase):

    def setUp(self):
        super(TestMorphJobPipeline, self).setUp()
        mj._JOBS.clear()    # session registry: reinitialize does not clear it

    def tearDown(self):
        mj._JOBS.clear()
        super(TestMorphJobPipeline, self).tearDown()

    def ensemble(self, name='src', models=4):
        '''ACDEFGHIK with the C-terminal half swung further in every model.'''
        cmd.fab('ACDEFGHIK', name)
        for k in range(2, models + 1):
            cmd.create(name, name, 1, k)
            cmd.rotate('y', 25 * (k - 1), '%s and resi 5-9' % name, k)

    def testSyncMorphObject(self):
        self.ensemble()
        n = mj.morph_object('src', frames_per_model=5, loop=1, async_=0)
        self.assertEqual(n, 'src_morph')
        self.assertEqual(cmd.count_states('src_morph'), 20)
        self.assertEqual(cmd.get_title('src_morph', 6), 'model 2')
        self.assertEqual(cmd.get_title('src_morph', 2), '1 → 2')
        self.assertEqual(cmd.get_title('src_morph', 19), '4 → 1')
        enabled = cmd.get_names('objects', enabled_only=1)
        self.assertNotIn('src', enabled)                    # hidden on completion
        self.assertIn('src_morph', enabled)                 # shown on completion
        # key frames are the models; the wrap leg ends on model 1
        for state, model in ((1, 1), (6, 2), (11, 3), (16, 4), (20, 1)):
            self.assertLess(
                max_dev(coords('src_morph', state), coords('src', model)), 1e-4,
                'state %d should be model %d' % (state, model))
        # an intermediate really lies between its two models
        self.assertGreater(max_dev(coords('src_morph', 8), coords('src', 2)), 0.1)
        self.assertGreater(max_dev(coords('src_morph', 8), coords('src', 3)), 0.1)
        self.assertEqual(mj.pending_objects(), {})
        self.assertEqual(mj.recent_objects(), [])
        self.assertIsNone(mj.pending_info('src_morph'))     # success leaves no tray record
        self.assertEqual(mj.morph_sources()['src_morph']['source'], 'src')
        self.assertEqual(mj.morph_sources()['src_morph']['spec']['frames_per_model'], 5)
        self.assertEqual(mj.morph_spec('src_morph')['spec']['frames_per_model'], 5)
        self.assertEqual(mj.morph_spec('src_morph')['state'], 'done')

    def testSpecIsIntsNotBools(self):
        # Swift decodes loop/copy_look as Int; a JSON true fails the whole
        # Object-panel payload.
        self.ensemble(models=3)
        mj.morph_object('src', frames_per_model=3, loop=True, copy_look=True,
                        refinement=0, async_=0)
        spec = mj.morph_sources()['src_morph']['spec']
        self.assertEqual(spec, {'frames_per_model': 3, 'loop': 1,
                                'method': 'rigimol', 'refinement': 0,
                                'rate': 'linear', 'copy_look': 1})
        self.assertEqual([k for k, v in spec.items() if isinstance(v, bool)], [])
        self.assertIn('"loop": 1', json.dumps(spec))

    def testReuseWhenUnchanged(self):
        self.ensemble()
        mj.morph_object('src', frames_per_model=5, async_=0)
        started = mj.morph_spec('src_morph')['started']
        mj.morph_object('src', frames_per_model=5, async_=0, reuse=1)
        self.assertEqual(mj.morph_spec('src_morph')['started'], started)    # untouched
        cmd.create('src', 'src', 1, -1)                                       # fingerprint changes
        mj.morph_object('src', frames_per_model=5, async_=0, reuse=1)
        self.assertEqual(cmd.count_states('src_morph'), 25)                  # rebuilt for 5 models

    def testStepAndPumpOneLeg(self):
        self.ensemble()
        job = mj.start_job('src', frames_per_model=5)
        self.assertEqual(cmd.count_states('src_morph'), 1)
        self.assertEqual(job.state, 'queued')
        self.assertNotIn('src_morph', cmd.get_names('objects', enabled_only=1))  # built hidden
        self.assertTrue(job.step())
        mj.pump()
        self.assertEqual(cmd.count_states('src_morph'), 6)
        self.assertEqual(job.landed_legs, 1)
        self.assertLess(max_dev(coords('src_morph', 6), coords('src', 2)), 1e-4)
        info = mj.pending_info('src_morph')
        self.assertEqual(set(info), _RECORD_KEYS)
        self.assertEqual((info['models_done'], info['models_total']), (1, 4))
        self.assertEqual(info['state'], 'running')
        self.assertTrue(info['moving'])
        self.assertAlmostEqual(info['fraction'], 0.25)
        self.assertTrue('leg 1 of 4' in info['detail'])
        self.assertEqual(mj.pending_objects(), {'src_morph': ['src_morph']})
        self.assertTrue('src' in cmd.get_names('objects', enabled_only=1))  # source visible until done

    def testCancelDeletesPartial(self):
        self.ensemble()
        job = mj.start_job('src', frames_per_model=5)
        job.step()
        mj.pump()
        mj.morph_cancel('src_morph')
        self.assertNotIn('src_morph', cmd.get_names('objects'))
        self.assertIn('src', cmd.get_names('objects', enabled_only=1))
        self.assertEqual(mj.pending_info('src_morph')['state'], 'cancelled')
        self.assertEqual(mj.recent_objects(), ['src_morph'])
        self.assertEqual(mj.pending_objects(), {})
        self.assertFalse(job.step())                        # a cancelled job computes nothing
        mj.morph_dismiss('src_morph')
        self.assertEqual(mj.recent_objects(), [])
        self.assertIsNone(mj.pending_info('src_morph'))

    def testStartTwiceIsRefused(self):
        self.ensemble()
        mj.start_job('src', frames_per_model=5)
        with self.assertRaisesRegex(pymol.CmdException, 'already being built'):
            mj.start_job('src', frames_per_model=5)

    def testRemorphRebuildsSameName(self):
        self.ensemble()
        mj.morph_object('src', frames_per_model=5, async_=0)
        mj.morph_object('src', frames_per_model=3, async_=0)
        self.assertEqual(cmd.count_states('src_morph'), 12)
        self.assertEqual(cmd.get_names('objects').count('src_morph'), 1)

    def testExplicitNameRefusesForeignObject(self):
        self.ensemble()
        cmd.fab('ACD', 'other')
        natoms = cmd.count_atoms('other')
        with self.assertRaisesRegex(pymol.CmdException,
                                    'other exists and is not a morph of src'):
            mj.morph_object('src', name='other', async_=0)
        self.assertEqual(cmd.count_atoms('other'), natoms)  # left alone
        self.assertEqual(cmd.count_states('other'), 1)
        self.assertNotIn('other', mj._JOBS)

    def testExplicitNameConventionRebuilds(self):
        # Session restore: a .pse brings src_morph back with no job registered.
        self.ensemble()
        cmd.create('src_morph', 'src')
        self.assertEqual(cmd.count_states('src_morph'), 4)
        self.assertEqual(
            mj.morph_object('src', name='src_morph', frames_per_model=5, async_=0),
            'src_morph')
        self.assertEqual(cmd.count_states('src_morph'), 20)
        self.assertEqual(cmd.get_names('objects').count('src_morph'), 1)

    def testPumpBudgetAndIdempotence(self):
        self.ensemble(models=6)
        job = mj.start_job('src', frames_per_model=20)
        while job.step():
            pass
        mj.pump(budget_ms=0)
        n = cmd.count_states('src_morph')
        self.assertTrue(1 < n <= 21, n)       # progress even at budget 0, at most one leg
        for _ in range(50):
            mj.pump()
        self.assertEqual(job.state, 'done')
        self.assertEqual(cmd.count_states('src_morph'), 120)
        mj.pump()
        mj.pump()                             # no-op after done, never raises
        self.assertEqual(cmd.count_states('src_morph'), 120)

    def testAsyncDrivenByPump(self):
        self.ensemble()
        name = mj.morph_object('src', frames_per_model=5, async_=1)
        job = mj._JOBS[name]
        self.assertEqual(cmd.count_states(name), 1)          # returned before any leg landed
        for _ in range(200):
            if job.state == 'done':
                break
            mj.pump()
        self.assertEqual(job.state, 'done')
        self.assertEqual(cmd.count_states(name), 20)

    def testPumpErrorPathNeverRaises(self):
        self.ensemble()
        job = mj.start_job('src', frames_per_model=5)
        job.step()
        mj.pump()
        cmd.delete('src_morph')               # the user deletes the half-built morph
        job.step()
        mj.pump()                             # must not raise
        self.assertEqual(job.state, 'error')
        info = mj.pending_info('src_morph')
        self.assertEqual(info['state'], 'error')
        self.assertIn('src_morph', info['error'])
        self.assertEqual(mj.recent_objects(), ['src_morph'])
        self.assertIn('src', cmd.get_names('objects', enabled_only=1))

    def testRefuseAboveHardLimit(self):
        self.ensemble()
        mj.REFUSE_BYTES = 10
        try:
            with self.assertRaisesRegex(pymol.CmdException, 'Reduce frames per model'):
                mj.start_job('src')
            self.assertNotIn('src_morph', cmd.get_names('objects'))
        finally:
            mj.REFUSE_BYTES = mj._platform_refuse()
