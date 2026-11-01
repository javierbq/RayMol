'''
Testing: morph job layer wired into the Object-panel poll and command table.

Tests that:
  - poll_panel() publishes `morph_jobs` (progress-tray records) and `morph`
    (completed morph sources) in the pymol_objpanel JSON payload
  - a running morph's name does NOT appear in `pending` (the row stays enabled)
  - after completion `morph_jobs` is empty and `morph` carries the spec
  - when _pending_maps('morph_jobs') raises, the payload is still written with
    morph_jobs == {} and the object list intact
  - morph_object / morph_cancel / morph_dismiss are registered in cmd.keyword
  - morph_object (with async=0, as for fetch, and a rate with a space),
    morph_cancel and morph_dismiss are exercised through cmd.do() (the parser
    path); morph_object refuses an argument it does not know
  - the inspector detail payload's `objmeta` carries each object's atom count
    (`natoms`), which the Morph sheet's memory estimate reads
  - the main payload's `morph_bytes_per_frame` carries morph_jobs'
    bytes_per_frame for every multi-state molecular object (none for 1-state
    objects, CGOs or the morph being built), and {} when computing it fails;
    figures past their TTL are refreshed within a per-poll budget, oldest
    first
  - the main payload's `morph_atoms_per_frame` carries morph_estimate's
    `atoms` (state 1) from the same cached pass, one model's atoms for a
    discrete object (not the object's total)
  - a refused morph (discrete source, memory limit) leaves a failed card in
    `morph_jobs` that morph_dismiss clears; a refusal while the morph builds
    adds no record, and one after a finished build keeps the finished morph's
    record and files the card under '<name> (refused)'; one filed over a
    failed build the pump has not cleaned up yet cleans it up first

Runs on a RayMol --testing build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/morph_panel.py
'''

import json
from unittest import mock

import pymol
from pymol import appkit_inspector, cgo, cmd, raymol_tmp, testing
import pymol.morph_jobs as mj


def ensemble(name='src', models=4):
    '''ACDEFGHIK with the C-terminal half swung further in every model.'''
    cmd.fab('ACDEFGHIK', name)
    for k in range(2, models + 1):
        cmd.create(name, name, 1, k)
        cmd.rotate('y', 25 * (k - 1), '%s and resi 5-9' % name, k)


class TestMorphPanelPayload(testing.PyMOLTestCase):

    def setUp(self):
        super(TestMorphPanelPayload, self).setUp()
        mj._JOBS.clear()
        appkit_inspector._BYTES_PER_FRAME.clear()   # objects of earlier tests

    def tearDown(self):
        mj._JOBS.clear()
        super(TestMorphPanelPayload, self).tearDown()

    def testPayloadCarriesMorphJobsAndSources(self):
        ensemble('src')
        job = mj.start_job('src', frames_per_model=5)
        job.step()
        appkit_inspector.poll_panel()          # pumps -> lands leg 1
        p = json.load(open(raymol_tmp.channel_path('pymol_objpanel')))
        # Progress tray row exists for the in-flight morph
        self.assertEqual(p['morph_jobs']['src_morph']['models_done'], 1)
        # The row must NOT be in `pending` — a morph's enable-toggle stays active
        self.assertNotIn('src_morph', p['pending'])
        # Step to completion and let the panel catch up
        while job.step():
            pass
        for _ in range(50):
            appkit_inspector.poll_panel()
        p = json.load(open(raymol_tmp.channel_path('pymol_objpanel')))
        # Completed morph appears in `morph` with full spec
        self.assertEqual(p['morph']['src_morph']['source'], 'src')
        self.assertEqual(p['morph']['src_morph']['spec']['frames_per_model'], 5)
        # No active progress records remain
        self.assertEqual(p['morph_jobs'], {})

    def testCompletedMorphCarriesItsBuildNumber(self):
        '''`morph` numbers each finished build. A morph that lands inside one
        poll's pump is never in `morph_jobs`, and a rebuild with the same
        settings publishes the same source and spec: the number is how the
        app tells it finished.'''
        ensemble('src')
        mj.morph_object('src', frames_per_model=3, refinement=0, async_=0)
        appkit_inspector.poll_panel()
        first = json.load(open(raymol_tmp.channel_path('pymol_objpanel')))['morph']
        self.assertEqual(first['src_morph']['build'], mj._JOBS['src_morph'].build)
        mj.morph_object('src', frames_per_model=3, refinement=0, async_=0)
        appkit_inspector.poll_panel()
        p = json.load(open(raymol_tmp.channel_path('pymol_objpanel')))
        again = p['morph']
        self.assertEqual(p['morph_jobs'], {})
        self.assertEqual(again['src_morph']['spec'], first['src_morph']['spec'])
        self.assertEqual(again['src_morph']['source'], 'src')
        self.assertNotEqual(again['src_morph']['build'], first['src_morph']['build'])

    def testMorphJobsPendingMapFailureWritesPanelWithEmptyMorphJobs(self):
        '''If _pending_maps('morph_jobs') raises, the payload file is still
        written (object list intact) and morph_jobs defaults to {}.'''
        ensemble('src')
        original = mj.pending_objects

        def _raise():
            raise RuntimeError('simulated morph_jobs failure')

        mj.pending_objects = _raise
        self.addCleanup(setattr, mj, 'pending_objects', original)

        appkit_inspector.poll_panel()
        p = json.load(open(raymol_tmp.channel_path('pymol_objpanel')))
        # Panel file was written and object list is intact
        self.assertIn('src', p['objects'])
        # morph_jobs defaults to {} on failure rather than crashing the panel
        self.assertEqual(p['morph_jobs'], {})

    def testCommandsRegistered(self):
        # All three morph commands must be reachable from the PyMOL command line
        for kw in ('morph_object', 'morph_cancel', 'morph_dismiss'):
            self.assertIn(kw, cmd.keyword)
        # the command line users and agents type: async=0 as for fetch, and a
        # rate with a space
        ensemble('src')
        cmd.do('morph_object src, frames_per_model=4, rate=ramp up, async=0')
        self.assertEqual(cmd.count_states('src_morph'), 16)
        self.assertEqual(mj.morph_spec('src_morph')['spec']['rate'], 'ramp up')
        # async_ still works; a misspelt argument is refused, not ignored
        self.assertEqual(mj.morph_object('src', frames_per_model=3, async_=0),
                         'src_morph')
        self.assertEqual(cmd.count_states('src_morph'), 12)
        with self.assertRaisesRegex(pymol.CmdException,
                                    'unknown argument.*frames_per_mode'):
            mj.morph_object('src', frames_per_mode=4, async_=0)
        self.assertEqual(cmd.count_states('src_morph'), 12)

    def testCancelAndDismissViaCommandLine(self):
        '''morph_cancel and morph_dismiss exercise the cmd.do() / STRICT parser path.'''
        ensemble('src')
        job = mj.start_job('src', frames_per_model=5)
        job.step()
        mj.pump()    # land leg 1 so the partial object exists
        # Cancel via the PyMOL command line
        cmd.do('morph_cancel src_morph')
        self.assertNotIn('src_morph', cmd.get_names('objects'))
        rec = mj.pending_info('src_morph')
        self.assertEqual(rec['state'], 'cancelled')
        # Dismiss via the PyMOL command line
        cmd.do('morph_dismiss src_morph')
        self.assertEqual(mj.recent_objects(), [])

    def payload(self):
        appkit_inspector.poll_panel()
        return json.load(open(raymol_tmp.channel_path('pymol_objpanel')))

    def testPayloadCarriesBytesPerFrame(self):
        '''The Morph sheet and the Play-models sheet read the estimate's
        per-frame bytes from here, so they and morph_object agree.'''
        ensemble('src')
        cmd.show('cartoon', 'src')
        cmd.fab('ACD', 'single')
        cmd.load_cgo([cgo.SPHERE, 0.0, 0.0, 0.0, 1.0], 'arrows', 1)
        cmd.load_cgo([cgo.SPHERE, 1.0, 0.0, 0.0, 1.0], 'arrows', 2)
        p = self.payload()
        self.assertEqual(p['morph_bytes_per_frame'],
                         {'src': mj.bytes_per_frame('src')})

    def testPayloadCarriesAtomsPerFrame(self):
        '''The Morph sheet's build-time hint reads the atoms one morph frame
        holds from here: morph_estimate's `atoms` (state 1, alt '' and A).
        For a discrete object that is one model's atoms, not the total the
        object panel shows for it (every state's own atoms).'''
        ensemble('src')
        cmd.create('disc', 'src', 0, 0, discrete=1)
        per_state = cmd.count_atoms('src', state=1)
        self.assertEqual(cmd.count_states('disc'), 4)
        self.assertEqual(cmd.count_atoms('disc'), 4 * per_state)
        p = self.payload()
        self.assertEqual(p['morph_atoms_per_frame'],
                         {'src': per_state, 'disc': per_state})
        self.assertEqual(p['morph_atoms_per_frame']['disc'],
                         mj.morph_estimate('disc')['atoms'])
        self.assertEqual(p['morph_bytes_per_frame'],
                         {'src': mj.bytes_per_frame('src'),
                          'disc': mj.bytes_per_frame('disc')})
        # from the same cached figure: a cached poll does not count again
        with mock.patch.object(mj, 'frame_cost',
                               wraps=mj.frame_cost) as cost:
            again = self.payload()
        self.assertEqual(cost.call_count, 0)
        self.assertEqual(again['morph_atoms_per_frame'], p['morph_atoms_per_frame'])

    def testFrameCostIsTheEstimatesFigures(self):
        '''frame_cost() is the one pass both payload maps come from: the
        atoms morph_estimate reports and bytes_per_frame().'''
        ensemble('src')
        cmd.show('cartoon', 'src')
        atoms, nbytes = mj.frame_cost('src')
        self.assertEqual(atoms, mj.morph_estimate('src')['atoms'])
        self.assertEqual(nbytes, mj.bytes_per_frame('src'))

    def testBytesPerFrameIsCachedBetweenPolls(self):
        '''A figure takes selector passes over every loaded atom, so the poll
        keeps it until the object's signature (state count, cmd.get_vis entry)
        changes, or for at most _BYTES_PER_FRAME_TTL seconds.'''
        ensemble('src')
        cmd.show_as('cartoon', 'src')
        first = self.payload()['morph_bytes_per_frame']['src']
        cmd.show('sticks', 'src and resi 1-3')  # get_vis does not see this
        self.assertEqual(self.payload()['morph_bytes_per_frame']['src'], first)
        with mock.patch.object(appkit_inspector, '_BYTES_PER_FRAME_TTL', 0.0):
            again = self.payload()['morph_bytes_per_frame']['src']
        self.assertEqual(again, mj.bytes_per_frame('src'))
        self.assertGreater(again, first)
        cmd.show('spheres', 'src and resi 4-6')
        self.assertEqual(self.payload()['morph_bytes_per_frame']['src'], again)
        cmd.create('src', 'src', 1, 5)          # a new state: computed at once
        latest = self.payload()['morph_bytes_per_frame']['src']
        self.assertEqual(latest, mj.bytes_per_frame('src'))
        self.assertGreater(latest, again)
        cmd.delete('src')
        self.assertEqual(self.payload()['morph_bytes_per_frame'], {})
        self.assertEqual(appkit_inspector._BYTES_PER_FRAME, {})

    def testExpiredFiguresRefreshWithinABudget(self):
        '''Figures past their TTL are refreshed while the poll's refresh
        budget lasts, at least one per poll: N cheap objects whose TTL ran
        out together do not take N polls.'''
        names = ['e%d' % i for i in range(4)]
        for n in names:
            ensemble(n, models=2)
            cmd.show_as('cartoon', n)
        self.payload()
        for n in names:
            cmd.show('sticks', '%s and resi 1-3' % n)  # get_vis does not see this
        want = {n: mj.bytes_per_frame(n) for n in names}
        with mock.patch.object(appkit_inspector, '_BYTES_PER_FRAME_TTL', 0.0):
            with mock.patch.object(appkit_inspector,
                                   '_BYTES_PER_FRAME_REFRESH_S', 0.0):
                got = self.payload()['morph_bytes_per_frame']
            self.assertEqual(sum(got[n] == want[n] for n in names), 1)
            with mock.patch.object(appkit_inspector,
                                   '_BYTES_PER_FRAME_REFRESH_S', 60.0):
                got = self.payload()['morph_bytes_per_frame']
        self.assertEqual(got, want)

    def testExpiredFiguresRefreshOldestFirst(self):
        '''With more expired figures than a poll's budget refreshes, the
        oldest goes first, so every object gets its turn. In object-list
        order the first few took every poll's refresh: with five sources each
        costing more than the budget (a few ms each beside a 60k-atom
        structure), a 500 ms poll and a 2 s TTL, the fifth one's figure never
        refreshed.'''
        names = ['e%d' % i for i in range(6)]
        for n in names:
            ensemble(n, models=2)
            cmd.show_as('cartoon', n)
        self.payload()
        for n in names:
            cmd.show('sticks', '%s and resi 1-3' % n)  # get_vis does not see this
        want = {n: mj.bytes_per_frame(n) for n in names}
        with mock.patch.object(appkit_inspector, '_BYTES_PER_FRAME_TTL', 0.0), \
                mock.patch.object(appkit_inspector,
                                  '_BYTES_PER_FRAME_REFRESH_S', 0.0), \
                mock.patch.object(mj, 'frame_cost',
                                  wraps=mj.frame_cost) as cost:
            for _ in names:                         # one refresh per poll
                got = self.payload()['morph_bytes_per_frame']
        self.assertEqual(sorted(c.args[0] for c in cost.call_args_list), names)
        self.assertEqual(got, want)

    def testBuildingMorphIsNotMeasured(self):
        '''The morph being built gains states on every poll, so its signature
        never holds; its figure is never used (it is not a morph source while
        it builds) and would cost selector passes on every poll.'''
        ensemble('src')
        job = mj.start_job('src', frames_per_model=5)
        job.step()
        with mock.patch.object(mj, 'frame_cost',
                               wraps=mj.frame_cost) as cost:
            p = self.payload()                  # pumps: lands leg 1
            self.assertGreater(cmd.count_states('src_morph'), 1)
            p = self.payload()
        self.assertIn('src_morph', p['morph_jobs'])
        self.assertNotIn('src_morph', p['morph_bytes_per_frame'])
        self.assertNotIn('src_morph', p['morph_atoms_per_frame'])
        self.assertIn('src', p['morph_bytes_per_frame'])
        self.assertIn('src', p['morph_atoms_per_frame'])
        self.assertNotIn(mock.call('src_morph'), cost.call_args_list)

    def testBytesPerFrameFailureWritesPanelWithEmptyMap(self):
        ensemble('src')
        with mock.patch.object(mj, 'frame_cost',
                               side_effect=RuntimeError('simulated failure')):
            p = self.payload()
        self.assertIn('src', p['objects'])
        self.assertEqual(p['morph_bytes_per_frame'], {})
        self.assertEqual(p['morph_atoms_per_frame'], {})

    def testFrameCostsFailureWritesPanelWithEmptyMaps(self):
        '''A failure of the whole computation (not one object's) costs the
        panel neither its update nor the other key.'''
        ensemble('src')
        with mock.patch.object(appkit_inspector, '_morph_frame_costs',
                               side_effect=RuntimeError('simulated failure')):
            p = self.payload()
        self.assertIn('src', p['objects'])
        self.assertEqual(p['morph_bytes_per_frame'], {})
        self.assertEqual(p['morph_atoms_per_frame'], {})

    def assertFailedCard(self, name, text):
        rec = self.payload()['morph_jobs'][name]
        self.assertEqual(rec['state'], 'error')
        self.assertIn(text, rec['error'])
        self.assertIn(text, rec['detail'])         # not "leg 0 of 0 · 0%"
        mj.morph_dismiss(name)
        self.assertNotIn(name, self.payload()['morph_jobs'])

    def testRefusedSourceLeavesAFailedCard(self):
        '''A refusal raised before the job existed used to reach the console
        only: the sheet closed and nothing appeared.'''
        ensemble('src')
        cmd.create('disc', 'src', 0, 0, discrete=1)
        objects = cmd.get_names('objects')
        with self.assertRaisesRegex(pymol.CmdException, 'different atoms'):
            mj.morph_object('disc', async_=0)
        self.assertEqual(cmd.get_names('objects'), objects)
        self.assertFailedCard('disc_morph', 'different atoms')

    def testMemoryRefusalLeavesAFailedCard(self):
        ensemble('src')
        self.addCleanup(setattr, mj, 'REFUSE_BYTES', None)
        mj.REFUSE_BYTES = 10
        objects = cmd.get_names('objects')
        with self.assertRaisesRegex(pymol.CmdException, 'Reduce frames per model'):
            mj.morph_object('src', async_=0)
        self.assertEqual(cmd.get_names('objects'), objects)
        self.assertFailedCard('src_morph', 'Reduce frames per model')

    def testRefusalWhileBuildingAddsNoRecord(self):
        '''Its running card is showing; the refusal must not replace it.'''
        ensemble('src')
        job = mj.start_job('src', frames_per_model=5)
        with self.assertRaisesRegex(pymol.CmdException, 'already being built'):
            mj.morph_object('src', async_=0)
        self.assertEqual(list(mj._JOBS), ['src_morph'])
        self.assertIs(mj._JOBS['src_morph'], job)
        self.assertIn(self.payload()['morph_jobs']['src_morph']['state'],
                      ('queued', 'running'))

    def testRefusalAfterABuildKeepsTheFinishedMorph(self):
        '''morph_sources, the badge and the clip stride read the finished
        record: the card goes under its own name.'''
        ensemble('src')
        mj.morph_object('src', frames_per_model=3, refinement=0, async_=0)
        self.addCleanup(setattr, mj, 'REFUSE_BYTES', None)
        mj.REFUSE_BYTES = 10
        with self.assertRaisesRegex(pymol.CmdException, 'Reduce frames per model'):
            mj.morph_object('src', async_=0)
        self.assertIn('src_morph', mj.morph_sources())
        self.assertEqual(mj._JOBS['src_morph'].state, 'done')
        self.assertIn('src_morph', self.payload()['morph'])
        self.assertFailedCard('src_morph (refused)', 'Reduce frames per model')
        self.assertIn('src_morph', mj.morph_sources())

    def testRefusalOverAnUnfinishedFailureCleansItUp(self):
        '''A build that failed after landing frames is cleaned up by the next
        pump. A refusal filed before that pump replaced its record, so pump
        never saw it again: the hidden partial morph stayed in the session.'''
        ensemble('src')
        job = mj.start_job('src', frames_per_model=5)
        job.step()
        mj.pump()                                   # the partial morph exists
        self.assertIn('src_morph', cmd.get_names('objects'))
        job._terminate('error', 'morph: simulated leg failure')   # no pump yet
        self.addCleanup(setattr, mj, 'REFUSE_BYTES', None)
        mj.REFUSE_BYTES = 10
        with self.assertRaisesRegex(pymol.CmdException, 'Reduce frames per model'):
            mj.morph_object('src', async_=0)
        self.assertTrue(job._finalised)
        self.assertNotIn('src_morph', cmd.get_names('objects'))
        self.assertIn('src', cmd.get_names('objects', enabled_only=1))
        self.assertFailedCard('src_morph', 'Reduce frames per model')

    def testObjmetaCarriesAtomCount(self):
        '''The Morph sheet's memory estimate reads the atom count from the
        inspector detail payload rather than issuing a query of its own.'''
        cmd.fab('ACD', 'a')
        appkit_inspector.poll(['a'])
        p = json.load(open(raymol_tmp.channel_path('pymol_objdetail')))
        self.assertEqual(p['objmeta']['a']['natoms'], cmd.count_atoms('a'))
