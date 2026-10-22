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
  - morph_cancel and morph_dismiss are exercised through cmd.do() (the parser path)
  - the inspector detail payload's `objmeta` carries each object's atom count
    (`natoms`), which the Morph sheet's memory estimate reads

Runs on a RayMol --testing build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/morph_panel.py
'''

import json

from pymol import appkit_inspector, cmd, raymol_tmp, testing
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
        # morph_object: call via Python API because async_=0 maps to the `async`
        # keyword, which is a Python reserved word and rejected by the STRICT parser.
        ensemble('src')
        cmd.morph_object('src', frames_per_model=4, async_=0)
        self.assertEqual(cmd.count_states('src_morph'), 16)

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

    def testObjmetaCarriesAtomCount(self):
        '''The Morph sheet's memory estimate reads the atom count from the
        inspector detail payload rather than issuing a query of its own.'''
        cmd.fab('ACD', 'a')
        appkit_inspector.poll(['a'])
        p = json.load(open(raymol_tmp.channel_path('pymol_objdetail')))
        self.assertEqual(p['objmeta']['a']['natoms'], cmd.count_atoms('a'))
