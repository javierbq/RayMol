'''
Testing: morph_jobs.py building blocks — naming, estimate, validation,
look copy, titles, fingerprint.

Tests that:
  - morph_name() returns the expected name and handles collisions
  - validate_source() returns (atoms, models) and raises on bad input:
    discrete, different atoms (also at equal counts), no alt ''/A atoms,
    not a molecular object
  - morph_estimate() returns correct fields: bytes_per_frame() (measured
    costs of coordinates and the shown reps) times frames, compared above
    the thresholds, which scale with the machine's memory (constants are
    floors); the estimate matches the memory a built morph really holds
  - copy_look() copies explicit per-object settings, hides surface/mesh
  - set_state_titles() labels key frames and intermediates correctly
  - fingerprint() returns a dict that changes when state count changes
  - MorphJob pipeline: start_job / step / pump land one leg at a time,
    morph_object(async_=0) runs it to completion, cancel deletes the partial
    object, the pending surface publishes designing-shaped records, and the
    reuse and explicit-name rules hold, and pump() builds the representations
    of the frames it lands while the morph is still hidden; a refused morph
    creates nothing, and the memory refusal comes before the per-state check
  - morph_object(async_=1) computes legs on a worker thread and pump() lands
    them: completion, cancel between legs, cancel while a leg is in flight
    (ends 'cancelled', never 'error'), source deleted mid-job, a worker
    exception finalised on the main thread, the worker holding at most one
    computed leg that has not landed, and pump() waiting for the worker's
    next leg only within its budget.  Tests synchronise with the worker
    through mj._leg_hook (a _Gate) and pump(), never through sleeps.
  - Session replacement: a .pse load (full or partial) or reinitialize stops
    a job without touching the objects that replaced its own, the registry
    forgets a morph the load replaced (and keeps one it restored unchanged),
    a job whose object was replaced stops, and a save while a morph builds
    leaves the partial morph out of the .pse.

Runs on a RayMol --testing build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/morph_jobs.py
'''

import json
import os
import tempfile
import threading
import time
from unittest import mock

import pymol
import pymol.setting
from pymol import appkit_movie, cgo, cmd, testing

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


class _Gate(object):
    '''An mj._leg_hook that holds the worker as it begins leg *leg* (its
    snapshot taken, no frame computed) until ``released`` is set.'''

    def __init__(self, leg):
        self.leg = leg
        self.entered = threading.Event()
        self.released = threading.Event()

    def __call__(self, job, leg):
        if leg == self.leg:
            self.entered.set()
            self.released.wait(10.0)


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

        # Non-existent object must raise, with a message a tray card can show
        with self.assertRaisesRegex(pymol.CmdException,
                                    'there is no object named nosuch_object_xyz'):
            mj.validate_source('nosuch_object_xyz')

    def testValidateRefusesSameCountDifferentAtoms(self):
        # Equal atom counts per state, different atoms: state 2 has CX where
        # state 1 has CB.  Counting alone passed this and the morph then died
        # on a KeyError inside start_job.
        cmd.fab('ACD', 'swap')
        cmd.create('swap_tmp', 'swap')
        cmd.alter('swap_tmp and resi 2 and name CB', "name='CX'")
        cmd.create('swap', 'swap_tmp', 1, 2)
        cmd.delete('swap_tmp')
        self.assertEqual(cmd.count_atoms('swap', state=1),
                         cmd.count_atoms('swap', state=2))
        with self.assertRaisesRegex(pymol.CmdException, 'models have different atoms'):
            mj.validate_source('swap')

    def testValidateRefusesEmptyAndNonMolecularSources(self):
        cmd.fab('ACD', 'altb')
        cmd.create('altb', 'altb', 1, 2)
        cmd.alter('altb', "alt='B'")
        with self.assertRaisesRegex(pymol.CmdException,
                                    "altb has no atoms in alt '' or A"):
            mj.validate_source('altb')
        cmd.load_cgo([cgo.SPHERE, 0.0, 0.0, 0.0, 1.0], 'arrows', 1)
        cmd.load_cgo([cgo.SPHERE, 1.0, 0.0, 0.0, 1.0], 'arrows', 2)
        self.assertEqual(cmd.count_states('arrows'), 2)
        with self.assertRaisesRegex(pymol.CmdException,
                                    'arrows is not a molecular object'):
            mj.validate_source('arrows')

    # ---- morph_estimate ------------------------------------------------------

    def testEstimate(self):
        cmd.fab('ACDEFGHIK', 'ee')
        cmd.create('ee', 'ee', 1, 2)
        cmd.create('ee', 'ee', 1, 3)
        cmd.hide('everything', 'ee')

        est = mj.morph_estimate('ee', frames_per_model=10, loop=1)
        self.assertEqual((est['models'], est['legs'], est['frames']), (3, 3, 30))

        # one frame's bytes times the frames, nothing on top
        atoms = cmd.count_atoms('ee')
        self.assertEqual(est['bytes'], mj.bytes_per_frame('ee') * 30)
        self.assertEqual(est['bytes'], int(1.1 * mj._COORD_COST * atoms) * 30)

        # With cartoon shown, bytes should grow (larger rep_cost)
        cmd.show('cartoon', 'ee')
        self.assertGreater(mj.morph_estimate('ee', 10, 1)['bytes'], est['bytes'])

        # Small molecule → warn/refuse should be False
        self.assertFalse(est['warn'])
        self.assertFalse(est['refuse'])

        # loop=0 → legs = models - 1 = 2
        self.assertEqual(mj.morph_estimate('ee', 10, 0)['legs'], 2)

    def testBytesPerFrameCountsTheShownReps(self):
        # Coordinates for every alt ''/A atom, plus each representation the
        # source shows at its measured cost: cartoon and ribbon per residue
        # (their geometry scales with residues, not atoms; a helix residue's
        # cartoon costs about twice a loop's), the others per atom showing
        # them.  Surfaces and meshes cost nothing: the morph never carries
        # them.
        cmd.fab('ACDEFGHIK', 'bp')
        cmd.create('bp', 'bp', 1, 2)
        cmd.alter('bp', "ss='L'")
        cmd.alter('bp and resi 7-9', "ss='S'")
        atoms = cmd.count_atoms('bp')
        res = cmd.count_atoms('bp and name CA')
        coord = mj._COORD_COST * atoms
        cmd.hide('everything', 'bp')
        self.assertEqual(mj.bytes_per_frame('bp'), int(1.1 * coord))
        cmd.show('surface', 'bp')
        self.assertEqual(mj.bytes_per_frame('bp'), int(1.1 * coord))
        cmd.show('cartoon', 'bp')
        cartoon = mj._RESIDUE_REP_COST['cartoon'] * res
        helix = mj._HELIX_CARTOON_COST
        self.assertEqual(mj.bytes_per_frame('bp'), int(1.1 * (coord + cartoon)))
        cmd.alter('bp and resi 2-5', "ss='H'")
        self.assertEqual(mj.bytes_per_frame('bp'),
                         int(1.1 * (coord + cartoon + 4 * helix)))
        # No secondary structure assigned at all: the morph's own (auto_dss on
        # its one-state creation) is unknown, so every residue counts as helix
        cmd.alter('bp', "ss='L'")
        self.assertEqual(mj.bytes_per_frame('bp'),
                         int(1.1 * (coord + cartoon + res * helix)))
        cmd.set('auto_dss', 0)              # the morph keeps the source's ss
        self.assertEqual(mj.bytes_per_frame('bp'), int(1.1 * (coord + cartoon)))
        cmd.set('auto_dss', 1)
        cmd.alter('bp and resi 7-9', "ss='S'")
        cmd.show('sticks', 'bp and resi 1-3')
        sticks = mj._ATOM_REP_COST['sticks'] * cmd.count_atoms('bp and resi 1-3')
        self.assertEqual(mj.bytes_per_frame('bp'),
                         int(1.1 * (coord + cartoon + sticks)))
        # atoms in other alternate locations are not morphed
        cmd.alter('bp and resi 9', "alt='B'")
        alt = cmd.count_atoms('bp and resi 9')
        self.assertEqual(mj.bytes_per_frame('bp'),
                         int(1.1 * (mj._COORD_COST * (atoms - alt)
                                    + mj._RESIDUE_REP_COST['cartoon'] * (res - 1)
                                    + sticks)))
        # the measured magnitudes, not the old guesses (cartoon 36 B per atom)
        self.assertGreater(mj._RESIDUE_REP_COST['cartoon'], 10000)
        self.assertGreater(mj._COORD_COST, 30)

    def testThresholdsScaleWithMemory(self):
        # None: the platform's live figure; the constants are floors only.
        self.assertIsNone(mj.WARN_BYTES)
        self.assertIsNone(mj.REFUSE_BYTES)
        phys = os.sysconf('SC_PHYS_PAGES') * os.sysconf('SC_PAGE_SIZE')
        self.assertEqual(mj.thresholds(), (max(200e6, phys / 16.0),
                                           max(1e9, phys / 4.0)))
        with mock.patch.object(mj, '_physical_memory', return_value=64e9):
            self.assertEqual(mj.thresholds(), (4e9, 16e9))
        with mock.patch.object(mj, '_physical_memory', return_value=2e9):
            self.assertEqual(mj.thresholds(), (200e6, 1e9))
        with mock.patch.object(mj, '_physical_memory', side_effect=OSError):
            self.assertEqual(mj.thresholds(), (200e6, 1e9))
        # iPhone and iPad: what the app may still allocate
        with mock.patch.object(mj, '_is_ios', return_value=True):
            with mock.patch.object(mj, '_ios_available_memory', return_value=3e9):
                self.assertEqual(mj.thresholds(), (750e6, 1.5e9))
            with mock.patch.object(mj, '_ios_available_memory', return_value=1e8):
                self.assertEqual(mj.thresholds(), (100e6, 400e6))
            with mock.patch.object(mj, '_ios_available_memory', side_effect=OSError):
                self.assertEqual(mj.thresholds(), (100e6, 400e6))
        # a number set by a test or a user is used as is
        self.addCleanup(setattr, mj, 'WARN_BYTES', None)
        self.addCleanup(setattr, mj, 'REFUSE_BYTES', None)
        mj.WARN_BYTES, mj.REFUSE_BYTES = 5, 10
        self.assertEqual(mj.thresholds(), (5, 10))

    def testEstimateWarnsAndRefusesAboveTheThresholds(self):
        # "above": an estimate equal to a threshold passes it (Swift uses >)
        cmd.fab('ACDEFGHIK', 'ee')
        cmd.create('ee', 'ee', 1, 2)
        nbytes = mj.morph_estimate('ee', 10, 1)['bytes']
        self.addCleanup(setattr, mj, 'WARN_BYTES', None)
        self.addCleanup(setattr, mj, 'REFUSE_BYTES', None)
        mj.WARN_BYTES = mj.REFUSE_BYTES = nbytes
        est = mj.morph_estimate('ee', 10, 1)
        self.assertEqual((est['warn'], est['refuse']), (False, False))
        mj.WARN_BYTES = mj.REFUSE_BYTES = nbytes - 1
        est = mj.morph_estimate('ee', 10, 1)
        self.assertEqual((est['warn'], est['refuse']), (True, True))

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
        self._gate = None

    def tearDown(self):
        mj._JOBS.clear()
        super(TestMorphJobPipeline, self).tearDown()

    def ensemble(self, name='src', models=4):
        '''ACDEFGHIK with the C-terminal half swung further in every model.'''
        cmd.fab('ACDEFGHIK', name)
        for k in range(2, models + 1):
            cmd.create(name, name, 1, k)
            cmd.rotate('y', 25 * (k - 1), '%s and resi 5-9' % name, k)

    def gate(self, leg):
        '''Install a _Gate on leg *leg*; removed when the test ends.'''
        self._gate = gate = _Gate(leg)
        mj._leg_hook = gate
        self.addCleanup(setattr, mj, '_leg_hook', None)
        return gate

    def async_morph(self, **kw):
        '''morph_object('src', async_=1) -> (name, job).  However the test
        ends, the worker is released from any gate, cancelled and joined.'''
        name = mj.morph_object('src', async_=1, **kw)
        job = mj._JOBS[name]
        self.addCleanup(self._stop, job)
        return name, job

    def _stop(self, job):
        if self._gate is not None:
            self._gate.released.set()
        job.cancel()
        job.join(10.0)

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

    def testEachBuildHasItsOwnNumber(self):
        # The app learns a morph finished from this number: a small morph can
        # land inside one panel poll's pump, so no poll ever lists it as being
        # built, and a rebuild with the same spec changes nothing else.
        self.ensemble()
        mj.morph_object('src', frames_per_model=5, refinement=0, async_=0)
        first = mj.morph_sources()['src_morph']['build']
        self.assertIsInstance(first, int)
        mj.morph_object('src', frames_per_model=5, refinement=0, async_=0, reuse=1)
        self.assertEqual(mj.morph_sources()['src_morph']['build'], first)   # reused
        mj.morph_object('src', frames_per_model=5, refinement=0, async_=0)  # rebuilt
        again = mj.morph_sources()['src_morph']
        self.assertNotEqual(again['build'], first)
        self.assertEqual(again['spec']['frames_per_model'], 5)
        self.assertNotIn('build', again['spec'])        # the spec is the settings only

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

    def testDefaultNameSkipsGroup(self):
        # A group (or map, CGO...) squatting on <source>_morph is not a morph:
        # deleting it would take its members with it.
        self.ensemble()
        cmd.pseudoatom('keepme')
        cmd.group('src_morph', 'keepme')
        self.assertEqual(mj.morph_object('src', frames_per_model=3, async_=0),
                         'src_morph2')
        self.assertEqual(cmd.get_type('src_morph'), 'object:group')
        self.assertIn('keepme', cmd.get_names('objects'))
        self.assertEqual(cmd.count_states('src_morph2'), 12)
        # the session-restore convention covers molecular objects only
        with self.assertRaisesRegex(pymol.CmdException,
                                    'src_morph exists and is not a morph of src'):
            mj.morph_object('src', name='src_morph', frames_per_model=3, async_=0)
        self.assertIn('keepme', cmd.get_names('objects'))

    def testStaleRecordDoesNotClaimName(self):
        # The registry outlives the object: a record whose object was deleted
        # must not claim whatever is created under that name later.
        self.ensemble()
        mj.morph_object('src', frames_per_model=3, async_=0)
        cmd.delete('src_morph')
        cmd.load_cgo([cgo.SPHERE, 0.0, 0.0, 0.0, 1.0], 'src_morph')
        self.assertEqual(mj.morph_object('src', frames_per_model=3, async_=0),
                         'src_morph2')
        self.assertEqual(cmd.get_type('src_morph'), 'object:cgo')
        # an unrelated molecule under the old name is not the morph either
        cmd.delete('src_morph')
        cmd.fab('GG', 'src_morph')
        natoms = cmd.count_atoms('src_morph')
        self.assertEqual(mj.morph_object('src', frames_per_model=3, async_=0),
                         'src_morph2')                   # rebuilt in place
        self.assertEqual(cmd.count_atoms('src_morph'), natoms)
        self.assertEqual(cmd.count_states('src_morph'), 1)

    def testCopyLookOffStillDropsSurfaces(self):
        # Surfaces are per state (one mesh per frame); never carried (spec 5.5).
        self.ensemble()
        cmd.show('sticks', 'src')
        cmd.show('surface', 'src')
        cmd.show('mesh', 'src')
        self.assertGreater(cmd.count_atoms('src and rep surface'), 0)
        mj.morph_object('src', frames_per_model=3, copy_look=0, async_=0)
        self.assertEqual(cmd.count_atoms('src_morph and rep surface'), 0)
        self.assertEqual(cmd.count_atoms('src_morph and rep mesh'), 0)
        self.assertEqual(cmd.count_atoms('src_morph and rep sticks'),
                         cmd.count_atoms('src_morph'))  # other reps are carried

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

    def built_states(self, name):
        '''States of *name* whose cartoon representation exists, read without
        building any: with update=0 the surface-pick prepare call only looks
        at the reps the drawn state already has (it counts one pick grid per
        existing pickable rep).  *name* must be enabled.'''
        from pymol.cmd import _cmd
        from pymol.constants import repmasks
        built = []
        for state in range(1, cmd.count_states(name) + 1):
            cmd.set('state', state, name)
            with cmd.lockcm:
                accels, _, _ = _cmd.surface_pick_prepare(
                    cmd._COb, [name], repmasks['cartoon'], 0, 1)
            if accels:
                built.append(state)
        return built

    def testFramesAreBuiltWhileHidden(self):
        # The core builds an object's representations only while it is in
        # the scene, and an object with its own `state` setting (per-object
        # playback) gets every state built in one update.  A morph that grew
        # hidden made the first frame after completion build all of it: a
        # 1.5-2 s frame for 1200 frames of 2kpo.  pump() builds the frames
        # while the morph is still hidden, each leg's before its key frame
        # releases the worker, so nothing is left for that first frame.
        self.ensemble()
        cmd.show_as('cartoon', 'src')
        job = mj.start_job('src', frames_per_model=5)
        while job.step():
            mj.pump()
        mj.pump()
        self.assertEqual(job.state, 'done')
        n = cmd.count_states('src_morph')
        self.assertEqual(n, 20)
        self.assertEqual(set(range(1, n + 1)) - set(self.built_states('src_morph')), set())

    def testPumpStaysInBudgetWithCartoon(self):
        # Building the frames a pump landed is part of the pump.  With cartoon
        # on this 1500-atom helix a frame takes ~2 ms to build, and a pump that
        # waited for the next leg until its deadline, then landed and built the
        # whole 40-frame leg, ran ~0.18 s on a 0.1 s budget.  (The bare
        # peptides of the other budget tests build in ~0 ms, so they cannot
        # see this.)  Margin 1.5x: a pump reserves every cost from measurements
        # taken on the same machine in the same run, so a slow or loaded
        # machine scales the estimate and the work alike; what remains is one
        # frame landed and built plus the estimate's error, a few ms of the
        # 50 ms margin, against ~80 ms for the overrun this guards.
        cmd.fab('A' * 150, 'src', ss=1)
        for k in (2, 3):
            cmd.create('src', 'src', 1, k)
            cmd.rotate('y', 20 * (k - 1), 'src and resi 75-150', k)
        cmd.show_as('cartoon', 'src')
        name, job = self.async_morph(frames_per_model=40, refinement=0)
        pumps = []
        deadline = time.monotonic() + 60
        while job.state != 'done' and time.monotonic() < deadline:
            t = time.monotonic()
            mj.pump(budget_ms=100)
            pumps.append(time.monotonic() - t)
            time.sleep(0.05)
        self.assertEqual(job.state, 'done')
        self.assertLess(max(pumps), 0.150, ['%.3f' % p for p in pumps])
        n = cmd.count_states(name)
        self.assertEqual(n, 120)
        self.assertEqual(set(range(1, n + 1)) - set(self.built_states(name)), set())

    def testPrebuildLeavesUserVisibilityAlone(self):
        # Building while hidden toggles the morph into the scene for one update
        # phase; a morph the user switched on mid-build stays on, and a hidden
        # one is hidden again before anything can draw it.
        self.ensemble()
        cmd.show_as('cartoon', 'src')
        job = mj.start_job('src', frames_per_model=5)
        job.step()
        mj.pump()
        self.assertNotIn('src_morph', cmd.get_names('objects', enabled_only=1))
        cmd.enable('src_morph')
        job.step()
        mj.pump()
        self.assertIn('src_morph', cmd.get_names('objects', enabled_only=1))

    def testAsyncDrivenByPump(self):
        self.ensemble()
        name = mj.morph_object('src', frames_per_model=5, async_=1)
        job = mj._JOBS[name]
        self.addCleanup(self._stop, job)
        self.assertEqual(cmd.count_states(name), 1)          # returned before any leg landed
        deadline = time.monotonic() + 10    # the worker waits for pump to take legs
        while job.state != 'done' and time.monotonic() < deadline:
            mj.pump()
        self.assertEqual(job.state, 'done')
        self.assertEqual(cmd.count_states(name), 20)

    def testAsyncCompletesThroughPump(self):
        self.ensemble(models=5)
        name, job = self.async_morph(frames_per_model=5)
        self.assertIn(job.state, ('queued', 'running'))      # returned immediately
        self.assertEqual(cmd.count_states(name), 1)          # only pump lands
        deadline = time.monotonic() + 10    # the worker waits for pump to take legs
        while job.state != 'done' and time.monotonic() < deadline:
            mj.pump()
        self.assertEqual(job.state, 'done')
        self.assertTrue(job.join(10.0))                      # the worker has exited
        self.assertEqual(cmd.count_states(name), 25)
        self.assertLess(max_dev(coords(name, 25), coords('src', 1)), 1e-4)

    def testWorkerHoldsOneUnlandedLeg(self):
        # Backpressure: the worker computes a leg only once the leg before it
        # has fully landed, so a slow or absent pump never buffers more than
        # one leg of frames; a cancel wakes a worker waiting for room.
        self.ensemble()
        gate = self.gate(leg=0)
        started = []                                # (leg, landed_legs) as each leg begins

        def hook(job, leg):
            started.append((leg, job.landed_legs))
            gate(job, leg)
        mj._leg_hook = hook
        name, job = self.async_morph(frames_per_model=20)
        self.assertTrue(gate.entered.wait(10.0))    # held as leg 0 begins
        blocked = threading.Event()                 # set: the worker waits for room
        wait = job._room.wait

        def recording_wait(*args):
            blocked.set()
            return wait(*args)
        job._room.wait = recording_wait
        gate.released.set()
        self.assertTrue(blocked.wait(10.0))         # leg 0 computed, nothing pumped
        self.assertEqual((started, job.done_legs), ([(0, 0)], 1))
        blocked.clear()
        for _ in range(100):                        # land leg 0, one frame per pump
            mj.pump(budget_ms=0)
            if job.landed_legs:
                break
            self.assertEqual((started, job.done_legs), ([(0, 0)], 1))  # leg 1 waits
        self.assertEqual(job.landed_legs, 1)
        self.assertTrue(blocked.wait(10.0))         # leg 1 computed, waits in turn
        self.assertEqual((started, job.done_legs), ([(0, 0), (1, 1)], 2))
        job.cancel()                                # wakes the waiting worker
        self.assertTrue(job.join(10.0))
        self.assertEqual(len(started), 2)
        mj.pump()
        self.assertEqual(mj.pending_info(name)['state'], 'cancelled')
        self.assertNotIn(name, cmd.get_names('objects'))

    def testTwoModelMorphHoldsOneLeg(self):
        # Default loop=1: two models make two legs, and the worker must not
        # hold both while the first one lands.
        self.ensemble(models=2)
        name, job = self.async_morph(frames_per_model=20)
        for _ in range(200):                        # one frame per pump
            mj.pump(budget_ms=0)
            if job.landed_legs:
                break
            self.assertLessEqual(job.done_legs, 1)
        self.assertEqual(job.landed_legs, 1)
        deadline = time.monotonic() + 10
        while job.state != 'done' and time.monotonic() < deadline:
            mj.pump()
        self.assertEqual(job.state, 'done')
        self.assertEqual(cmd.count_states(name), 40)

    def testSmallMorphLandsInFewPumps(self):
        # pump() waits, within its budget, for the leg the worker is
        # computing instead of ending at every leg boundary.  The whole job
        # (6 legs x 5 frames of a 9-residue peptide, sculpted) costs a few
        # tens of ms, so a 1000 ms budget lands it in one call; 3 leaves room
        # for a heavily loaded machine.  Without the wait it takes 6 calls.
        self.ensemble(models=6)
        name, job = self.async_morph(frames_per_model=5)
        calls = 0
        while job.state != 'done' and calls < 10:
            mj.pump(budget_ms=1000)
            calls += 1
        self.assertEqual(job.state, 'done')
        self.assertEqual(cmd.count_states(name), 30)
        self.assertLessEqual(calls, 3)

    def testPumpWaitIsBoundedByBudget(self):
        # The worker is held inside leg 1 (leg 0 has landed).  pump(0) never
        # waits for it; pump(200) waits exactly its budget; neither lands.
        self.ensemble()
        gate = self.gate(leg=1)
        name, job = self.async_morph(frames_per_model=5)
        deadline = time.monotonic() + 10
        while not gate.entered.is_set() and time.monotonic() < deadline:
            mj.pump(budget_ms=0)
        self.assertTrue(gate.entered.is_set())
        self.assertEqual(cmd.count_states(name), 6)
        t = time.monotonic()
        mj.pump(budget_ms=0)
        self.assertLess(time.monotonic() - t, 1.0)  # an unbounded wait: the gate's 10 s
        t = time.monotonic()
        mj.pump(budget_ms=200)
        waited = time.monotonic() - t
        self.assertGreaterEqual(waited, 0.2)        # waited for leg 1 for the budget...
        self.assertLess(waited, 5.0)                # ... and no longer
        self.assertEqual(cmd.count_states(name), 6)
        gate.released.set()
        deadline = time.monotonic() + 10
        while job.state != 'done' and time.monotonic() < deadline:
            mj.pump()
        self.assertEqual(job.state, 'done')
        self.assertEqual(cmd.count_states(name), 20)

    def testPumpWaitSharesOneBudget(self):
        # Two jobs whose workers are both held inside leg 1: one pump waits
        # its budget once in all (>= 0.5 s), not once per job (>= 1.0 s).
        self.ensemble('src')
        self.ensemble('oth')
        entered, release = set(), threading.Event()

        def hook(job, leg):
            if leg == 1:
                entered.add(job.name)
                release.wait(10.0)
        mj._leg_hook = hook
        self.addCleanup(setattr, mj, '_leg_hook', None)
        _, job = self.async_morph(frames_per_model=5)
        other = mj._JOBS[mj.morph_object('oth', frames_per_model=5, async_=1)]
        self.addCleanup(self._stop, other)
        self.addCleanup(release.set)                # runs first: frees both workers
        deadline = time.monotonic() + 10
        while len(entered) < 2 and time.monotonic() < deadline:
            mj.pump(budget_ms=0)                    # land leg 0 of each
        self.assertEqual(entered, {job.name, other.name})
        t = time.monotonic()
        mj.pump(budget_ms=500)
        waited = time.monotonic() - t
        self.assertGreaterEqual(waited, 0.5)
        self.assertLess(waited, 1.0)

    def testPumpWaitWakesOnWorkerError(self):
        # A pump waiting for the next leg wakes as soon as the worker fails,
        # not when its budget runs out.
        self.ensemble()

        def hook(job, leg):
            if leg == 1:
                raise RuntimeError('boom in leg 1')
        mj._leg_hook = hook
        self.addCleanup(setattr, mj, '_leg_hook', None)
        name, job = self.async_morph(frames_per_model=5)
        t = time.monotonic()
        mj.pump(budget_ms=10000)                    # lands leg 0, waits for leg 1
        self.assertLess(time.monotonic() - t, 5.0)
        self.assertEqual(mj.pending_info(name)['error'], 'boom in leg 1')
        self.assertNotIn(name, cmd.get_names('objects'))

    def testAsyncCancelMidway(self):
        self.ensemble(models=8)
        gate = self.gate(leg=2)
        name, job = self.async_morph(frames_per_model=30)
        deadline = time.monotonic() + 10    # leg 2 starts once leg 1 has landed
        while not gate.entered.is_set() and time.monotonic() < deadline:
            mj.pump()
        self.assertTrue(gate.entered.is_set())
        self.assertEqual(cmd.count_states(name), 61)            # legs 0 and 1 landed
        mj.morph_cancel(name)
        gate.released.set()
        self.assertTrue(job.join(10.0))
        mj.pump()
        self.assertNotIn(name, cmd.get_names('objects'))
        self.assertEqual(mj.pending_info(name)['state'], 'cancelled')
        self.assertEqual(mj.recent_objects(), [name])
        self.assertIn('src', cmd.get_names('objects', enabled_only=1))
        self.assertEqual(job.done_legs, 2)          # the worker stopped at the cancel

    def testCancelMidLegEndsCancelled(self):
        # Race: morph_cancel frees the job's snapshot while the worker is
        # inside a leg.  The worker must finish that leg on its own references
        # and drop it; the job ends 'cancelled', never 'error'.
        self.ensemble()
        gate = self.gate(leg=0)
        name, job = self.async_morph(frames_per_model=5)
        self.assertTrue(gate.entered.wait(10.0))    # the worker is inside leg 0
        # record what the in-flight leg's computation raises (a terminal job
        # swallows it, so state alone would not show an inconsistent snapshot)
        compute, raised = job._compute_leg, []

        def recording(*args):
            try:
                return compute(*args)
            except Exception as e:
                raised.append(e)
                raise
        job._compute_leg = recording
        mj.morph_cancel(name)
        self.assertIsNone(job._coords)              # snapshot freed under the worker
        gate.released.set()
        self.assertTrue(job.join(10.0))
        self.assertEqual(raised, [])                # ... yet the leg computed cleanly
        mj.pump()
        info = mj.pending_info(name)
        self.assertEqual((info['state'], info['error']), ('cancelled', None))
        self.assertEqual(job.done_legs, 0)          # the in-flight leg was dropped
        self.assertNotIn(name, cmd.get_names('objects'))
        self.assertIn('src', cmd.get_names('objects', enabled_only=1))

    def testExceptionAfterCancelStaysCancelled(self):
        # A leg that fails after the user cancelled must not turn the
        # cancelled job into an error.
        self.ensemble()
        gate = self.gate(leg=0)

        def hook(job, leg):
            gate(job, leg)
            raise RuntimeError('late failure')
        mj._leg_hook = hook
        name, job = self.async_morph(frames_per_model=5)
        self.assertTrue(gate.entered.wait(10.0))
        mj.morph_cancel(name)
        gate.released.set()
        self.assertTrue(job.join(10.0))
        mj.pump()
        self.assertEqual((job.state, job.error), ('cancelled', None))
        self.assertEqual(mj.pending_info(name)['state'], 'cancelled')

    def testSourceDeletedMidJob(self):
        self.ensemble(models=6)
        name, job = self.async_morph(frames_per_model=10)
        cmd.delete('src')
        for _ in range(20):
            mj.pump()
        self.assertTrue(job.join(10.0))             # the failure released the worker
        info = mj.pending_info(name)
        self.assertEqual(info['state'], 'error')
        self.assertEqual(info['error'], 'morph: source src was deleted')
        self.assertNotIn(name, cmd.get_names('objects'))
        self.assertEqual(mj.recent_objects(), [name])           # record retained
        self.assertTrue(job._cancel.is_set())

    def testWorkerExceptionFinalisedByPump(self):
        self.ensemble()

        def hook(job, leg):
            if leg == 0:
                raise RuntimeError('boom in leg 0')
        mj._leg_hook = hook
        self.addCleanup(setattr, mj, '_leg_hook', None)
        name, job = self.async_morph(frames_per_model=5)
        self.assertTrue(job.join(10.0))
        self.assertEqual((job.state, job.error), ('error', 'boom in leg 0'))
        self.assertIn(name, cmd.get_names('objects'))      # the worker never touches cmd
        mj.pump()
        self.assertNotIn(name, cmd.get_names('objects'))
        self.assertIn('src', cmd.get_names('objects', enabled_only=1))
        self.assertEqual(mj.pending_info(name)['error'], 'boom in leg 0')
        self.assertEqual(mj.recent_objects(), [name])

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
            mj.REFUSE_BYTES = None

    def testMemoryRefusalComesBeforeThePerStateCheck(self):
        # A refused trajectory never pays validate_source's per-state loop.
        self.ensemble()
        self.addCleanup(setattr, mj, 'REFUSE_BYTES', None)
        mj.REFUSE_BYTES = 10
        with mock.patch.object(mj, 'validate_source',
                               side_effect=AssertionError('per-state check ran')):
            with self.assertRaisesRegex(pymol.CmdException, 'Reduce frames per model'):
                mj.start_job('src')

    #: Run by testEstimateMatchesBuiltMemory in a fresh interpreter.
    _MEMCHECK = '''
import os, subprocess
import pymol
pymol.finish_launching(['pymol', '-qck'])
from pymol import cmd, _cmd
import pymol.morph_jobs as mj

def rss():
    out = subprocess.check_output(['ps', '-o', 'rss=', '-p', str(os.getpid())])
    return int(out) * 1024

cmd.set('defer_builds_mode', 0)
cmd.fab('A' * 120, 'src', ss=1)
for k in (2, 3):
    cmd.create('src', 'src', 1, k)
    cmd.rotate('y', 20 * (k - 1), 'src and resi 60-120', k)
cmd.show_as('cartoon', 'src')
estimate = mj.morph_estimate('src', 40, 1, 0)['bytes']
before = rss()
name = mj.morph_object('src', frames_per_model=40, refinement=0, async_=0)
cmd.enable(name)
with cmd.lockcm:        # build anything still unbuilt (update phase)
    _cmd.surface_pick_prepare(cmd._COb, [name], 0, 1, 0)
line = 'MEMCHECK %d %d %d\\n' % (cmd.count_states(name), estimate, rss() - before)
os.write(1, line.encode())      # fd 1: PyMOL may have replaced sys.stdout
'''

    def testEstimateMatchesBuiltMemory(self):
        # The estimate is what a finished morph really holds: with the app's
        # defer_builds_mode 0 the core keeps every state's representations.
        # The old table read ~20x low for cartoon (8 MB for 383 MB here).
        # Measured in a fresh interpreter: in this long-lived test process
        # RSS also moves with memory earlier tests freed (it fell by 860 MB
        # across this build in a full run).  RSS is noisy, so the window is
        # wide on purpose; the error it guards is far outside it.
        import re
        import subprocess
        import sys
        if not sys.executable:
            self.skipTest('no interpreter to run the measurement in')
        run = subprocess.run([sys.executable, '-c', self._MEMCHECK],
                             capture_output=True, text=True, timeout=600)
        found = re.search(r'MEMCHECK (\d+) (\d+) (-?\d+)', run.stdout)
        self.assertIsNotNone(found, run.stdout[-2000:] + run.stderr[-2000:])
        states, estimate, actual = (int(g) for g in found.groups())
        self.assertEqual(states, 120)
        self.assertGreater(actual, 0)
        self.assertTrue(0.4 <= estimate / float(actual) <= 2.5,
                        'estimate %.0f MB, built %.0f MB' % (estimate / 1e6, actual / 1e6))

    def testMorphRefusesSameCountDifferentAtoms(self):
        cmd.fab('ACDEFGHIK', 'src')
        cmd.create('tmp', 'src')
        cmd.alter('tmp and resi 4 and name CB', "name='CX'")
        cmd.create('src', 'tmp', 1, 2)
        cmd.delete('tmp')
        objects = cmd.get_names('objects')
        with self.assertRaisesRegex(pymol.CmdException, 'models have different atoms'):
            mj.morph_object('src', async_=0)
        self.assertEqual(cmd.get_names('objects'), objects)     # creates nothing

    def testMorphRefusesSourceWithoutAltAAtoms(self):
        self.ensemble('altb')
        cmd.alter('altb', "alt='B'")
        with self.assertRaisesRegex(pymol.CmdException, 'has no atoms'):
            mj.morph_object('altb', async_=0)
        self.assertNotIn('altb_morph', cmd.get_names('objects'))

    def testMorphRefusesNonMolecularObject(self):
        # was "Selector-Error: Invalid selection name"
        cmd.load_cgo([cgo.SPHERE, 0.0, 0.0, 0.0, 1.0], 'arrows', 1)
        cmd.load_cgo([cgo.SPHERE, 1.0, 0.0, 0.0, 1.0], 'arrows', 2)
        with self.assertRaisesRegex(pymol.CmdException, 'not a molecular object'):
            mj.morph_object('arrows', async_=0)
        self.assertNotIn('arrows_morph', cmd.get_names('objects'))


#: A morph clip in the Timeline lane, as the app stages it (#901).
_LANE_CLIP = {'id': '7B1A3C55-1111-4222-8333-944455556666', 'kind': 'states',
              'states': {'objects': ['src_morph'], 'mode': 'sweep', 'first': 1,
                         'last': 0, 'seconds': 4.0, 'morphStride': 4},
              'seconds': 2.0, 'linear': False}


class TestMorphSessionReplacement(testing.PyMOLTestCase):
    '''A morph job and the registry across a session replacement.  The objects
    a .pse load or reinitialize puts in place belong to that session: a job
    stops without touching them, and the registry speaks only for objects that
    are still a job's own output.'''

    def setUp(self):
        super(TestMorphSessionReplacement, self).setUp()
        mj._JOBS.clear()
        self.addCleanup(mj._JOBS.clear)
        appkit_movie.forget_all_views()
        self.addCleanup(appkit_movie.forget_all_views)
        # the lane restore's hand-off to the app (a tempfile + a feedback line)
        patcher = mock.patch.object(appkit_movie, '_emit_timeline',
                                    lambda items, untracked_movie=False: None)
        patcher.start()
        self.addCleanup(patcher.stop)

    def ensemble(self, name='src', models=4):
        '''ACDEFGHIK with the C-terminal half swung further in every model.'''
        cmd.fab('ACDEFGHIK', name)
        for k in range(2, models + 1):
            cmd.create(name, name, 1, k)
            cmd.rotate('y', 25 * (k - 1), '%s and resi 5-9' % name, k)

    def pse(self):
        handle, path = tempfile.mkstemp(suffix='.pse')
        os.close(handle)
        self.addCleanup(lambda: os.path.exists(path) and os.unlink(path))
        return path

    def building(self, frames_per_model=4):
        '''A caller-driven re-morph of src with its first leg landed.'''
        job = mj.start_job('src', frames_per_model=frames_per_model, refinement=0)
        job.step()
        mj.pump()
        self.assertEqual(cmd.count_states('src_morph'), 1 + frames_per_model)
        return job

    def finish(self, job):
        while job.step():
            mj.pump()
        mj.pump()
        self.assertEqual(job.state, 'done')

    # ---- a job across a load or reinitialize -----------------------------------

    def testLoadStopsTheJobAndLeavesTheSessionAlone(self):
        self.ensemble()
        mj.morph_object('src', frames_per_model=3, refinement=0, async_=0)
        path = self.pse()
        cmd.save(path)                                  # src_morph, 12 states
        job = self.building()
        cmd.load(path)
        self.assertEqual((job.state, job._finalised), ('cancelled', True))
        self.assertIn('session', job.error)
        self.assertFalse(job.step())
        for _ in range(3):
            mj.pump()
        # the session's morph: not grown, not retitled, not deleted
        self.assertEqual(cmd.count_states('src_morph'), 12)
        self.assertEqual(cmd.get_title('src_morph', 5), '2 → 3')
        self.assertEqual(mj.pending_objects(), {})
        self.assertEqual(mj.recent_objects(), ['src_morph'])    # its card says so
        self.assertEqual(mj.pending_info('src_morph')['state'], 'cancelled')
        self.assertEqual(mj.morph_sources(), {})

    def testLoadStopsTheWorker(self):
        self.ensemble()
        path = self.pse()
        cmd.save(path)                                  # no morph in it
        gate = _Gate(1)
        mj._leg_hook = gate
        self.addCleanup(setattr, mj, '_leg_hook', None)
        name = mj.morph_object('src', frames_per_model=4, refinement=0, async_=1)
        job = mj._JOBS[name]
        self.addCleanup(lambda: (gate.released.set(), job.cancel(), job.join(10.0)))
        deadline = time.monotonic() + 10
        while not gate.entered.is_set() and time.monotonic() < deadline:
            mj.pump()
        self.assertTrue(gate.entered.is_set())          # leg 0 landed, leg 1 in flight
        cmd.load(path)
        gate.released.set()
        self.assertTrue(job.join(5.0))
        self.assertEqual(job.state, 'cancelled')
        self.assertEqual(job.done_legs, 1)              # the in-flight leg was dropped
        mj.pump()
        self.assertNotIn(name, cmd.get_names('objects'))
        self.assertIn('src', cmd.get_names('objects', enabled_only=1))

    def testReinitializeStopsJobsAndForgetsFinishedMorphs(self):
        self.ensemble()
        mj.morph_object('src', frames_per_model=3, refinement=0, async_=0)
        self.ensemble('twin')
        job = mj.start_job('twin', frames_per_model=3, refinement=0)
        cmd.reinitialize()
        self.assertNotIn('src_morph', mj._JOBS)
        self.assertEqual((job.state, job._finalised), ('cancelled', True))
        self.assertFalse(job.step())
        self.assertEqual(mj.pending_objects(), {})
        self.assertEqual(mj.recent_objects(), ['twin_morph'])

    def testPartialLoadStopsOnlyTheJobsItReplaces(self):
        self.ensemble()
        cmd.create('src_morph', 'src')                  # 4 states under the morph's name
        path = self.pse()
        cmd.save(path)
        cmd.reinitialize()
        self.ensemble('twin')
        mj.morph_object('twin', frames_per_model=3, refinement=0, async_=0)
        self.ensemble()
        job = self.building()
        cmd.load(path, partial=1)
        self.assertEqual((job.state, job._finalised), ('cancelled', True))
        mj.pump()
        self.assertEqual(cmd.count_states('src_morph'), 4)      # the loaded object
        self.assertEqual(list(mj.morph_sources()), ['twin_morph'])  # untouched by the load

    def testReplacedObjectStopsTheJob(self):
        self.ensemble()
        job = self.building()
        cmd.delete('src_morph')
        cmd.create('src_morph', 'src')                  # same atoms, 4 states
        job.step()
        mj.pump()
        self.assertEqual(job.state, 'error')
        self.assertIn('replaced', job.error)
        self.assertEqual(cmd.count_states('src_morph'), 4)      # left alone
        self.assertEqual(mj.recent_objects(), ['src_morph'])

    # ---- the registry names only a job's own output ----------------------------

    def testLoadForgetsAMorphItReplaced(self):
        self.ensemble()
        mj.morph_object('src', frames_per_model=3, refinement=0, async_=0)
        path = self.pse()
        cmd.save(path)
        mj.morph_object('src', frames_per_model=5, refinement=0, async_=0)
        cmd.load(path)
        self.assertEqual(cmd.count_states('src_morph'), 12)
        self.assertEqual(mj.morph_sources(), {})
        self.assertIsNone(mj.morph_spec('src_morph'))
        # a smooth Play-models Add for 5 frames per model rebuilds it (the app
        # names a restored morph: MorphSettings.morphTarget)
        mj.morph_object('src', name='src_morph', frames_per_model=5, refinement=0,
                        async_=0, reuse=1)
        self.assertEqual(cmd.count_states('src_morph'), 20)

    def testLoadForgetsAnotherBuildWithTheSameStates(self):
        self.ensemble()
        mj.morph_object('src', frames_per_model=3, refinement=0, method='linear',
                        async_=0)
        path = self.pse()
        cmd.save(path)
        mj.morph_object('src', frames_per_model=3, refinement=0, async_=0)
        cmd.load(path)                                  # 12 states either way
        self.assertEqual(mj.morph_sources(), {})

    def testRestoringTheSameMorphKeepsItsRecord(self):
        # The Theme studio snapshots the session and restores it unchanged.
        self.ensemble()
        mj.morph_object('src', frames_per_model=3, refinement=0, async_=0)
        started = mj.morph_spec('src_morph')['started']
        build = mj.morph_sources()['src_morph']['build']
        cmd.set_session(cmd.get_session())
        self.assertEqual(mj.morph_sources()['src_morph']['spec']['frames_per_model'], 3)
        self.assertEqual(mj.morph_spec('src_morph')['started'], started)
        self.assertEqual(mj.morph_sources()['src_morph']['build'], build)  # not a new build

    def testRegistryChecksTheObjectIsStillTheMorph(self):
        self.ensemble()
        mj.morph_object('src', frames_per_model=3, refinement=0, async_=0)
        cmd.delete('src_morph')
        cmd.create('src_morph', 'src')                  # same atoms, 4 states
        self.assertEqual(mj.morph_sources(), {})
        self.assertIsNone(mj.morph_spec('src_morph'))
        mj.morph_object('src', frames_per_model=3, refinement=0, async_=0, reuse=1)
        self.assertEqual(cmd.count_states('src_morph'), 12)     # rebuilt, not reused

    # ---- a save while a morph builds ------------------------------------------

    def testSaveWhileBuildingLeavesThePartialMorphOut(self):
        self.ensemble()
        job = self.building()
        appkit_movie.stage_timeline(json.dumps([_LANE_CLIP]))
        path = self.pse()
        cmd.save(path)
        self.assertEqual(cmd.count_states('src_morph'), 5)      # the live morph is untouched
        self.assertEqual(job.state, 'running')                  # and still building
        self.finish(job)
        cmd.load(path)
        self.assertNotIn('src_morph', cmd.get_names('objects'))
        self.assertIn('src', cmd.get_names('objects', enabled_only=1))
        # the clip stays in the lane: morphing src again fills it
        self.assertEqual(appkit_movie._timeline, [_LANE_CLIP])
        self.assertEqual(mj.morph_sources(), {})
        self.assertEqual(
            mj.morph_object('src', frames_per_model=4, refinement=0, async_=0, reuse=1),
            'src_morph')
        self.assertEqual(cmd.count_states('src_morph'), 16)

    def testSaveKeepsAFinishedMorph(self):
        self.ensemble()
        mj.morph_object('src', frames_per_model=3, refinement=0, async_=0)
        path = self.pse()
        cmd.save(path)
        cmd.load(path)
        self.assertEqual(cmd.count_states('src_morph'), 12)
