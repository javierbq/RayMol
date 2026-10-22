'''
#901: the Timeline lane rides in the .pse.

The app stages its editable item list in appkit_movie; a session save writes it
under `raymol_timeline` with the camera views its items use, and a full restore
puts both back and hands the lane to the app (a tempfile plus a short
`TIMELINE:ready` feedback line).
A session with no lane empties it, reports whether the session still carries a
movie of its own, and leaves that movie as it is.

    pymol -ckqy testing/testing.py --run testing/tests/raymol/timeline_session.py
'''

import base64
import copy
import io
import json
import os
import sys
import tempfile
import types
from unittest import mock

from pymol import cmd, testing, appkit_movie


ITEMS = [
    {'id': 'cam-1', 'kind': 'camera', 'seconds': 2.0, 'linear': False},
    {'id': 'scn-1', 'kind': 'scene', 'scene': 'F1 é', 'seconds': 3.0,
     'linear': True, 'pinnedState': 2},
    {'id': 'cam-2', 'kind': 'camera', 'seconds': 1.5, 'linear': True,
     'atFrame': 40},
    {'id': 'st-1', 'kind': 'states', 'seconds': 2.0, 'linear': False,
     'states': {'objects': None, 'mode': 'loop', 'first': 1, 'last': 0,
                'seconds': 4.0}},
]


class TimelineSessionTest(testing.PyMOLTestCase):

    real_emit = staticmethod(appkit_movie._emit_timeline)

    def setUp(self):
        super().setUp()
        appkit_movie.forget_all_views()
        self.addCleanup(appkit_movie.forget_all_views)
        self.emitted = []
        real = appkit_movie._emit_timeline
        appkit_movie._emit_timeline = lambda items, untracked_movie=False: \
            self.emitted.append((items, untracked_movie))
        self.addCleanup(setattr, appkit_movie, '_emit_timeline', real)

    def pse(self):
        handle, path = tempfile.mkstemp(suffix='.pse')
        os.close(handle)
        self.addCleanup(lambda: os.path.exists(path) and os.unlink(path))
        return path

    def build(self):
        cmd.fab('AGA', 'pep')
        cmd.scene('F1 é', 'store')
        appkit_movie.capture_view('cam-1')
        cmd.turn('y', 90)
        appkit_movie.capture_view('cam-2')
        appkit_movie.capture_view('unused')
        appkit_movie.stage_timeline(json.dumps(ITEMS))
        appkit_movie.rebuild(json.dumps([
            {'frame': 1, 'cam': 'cam-1', 'power': 0.0, 'linear': 0},
            {'frame': 60, 'scene': base64.b64encode(
                'F1 é'.encode('utf-8')).decode('ascii'),
             'power': 1.0, 'linear': 1, 'state': 2},
            {'frame': 40, 'cam': 'cam-2', 'power': 1.0, 'linear': 1},
        ]))

    def test_round_trip_restores_items_and_views(self):
        cmd.reinitialize()
        self.build()
        views = {k: list(appkit_movie._views[k]) for k in ('cam-1', 'cam-2')}
        frames = cmd.count_frames()
        saved = self.pse()
        cmd.save(saved)

        appkit_movie.forget_all_views()
        cmd.reinitialize()
        cmd.load(saved)

        self.assertEqual(appkit_movie._timeline, ITEMS)
        self.assertEqual(self.emitted[-1:], [(ITEMS, False)])
        # Only the views the lane uses ride along.
        self.assertEqual(sorted(appkit_movie._views), ['cam-1', 'cam-2'])
        for k, v in views.items():
            self.assertArrayEqual(appkit_movie._views[k], v, delta=1e-4)
        self.assertEqual(cmd.count_frames(), frames)

    def test_restored_lane_saves_again(self):
        cmd.reinitialize()
        self.build()
        first = self.pse()
        cmd.save(first)
        appkit_movie.forget_all_views()
        cmd.load(first)
        second = self.pse()
        cmd.save(second)
        appkit_movie.forget_all_views()
        cmd.load(second)
        self.assertEqual(appkit_movie._timeline, ITEMS)
        self.assertEqual(sorted(appkit_movie._views), ['cam-1', 'cam-2'])

    def test_old_session_keeps_its_movie_and_reports_it(self):
        cmd.reinitialize()
        cmd.fab('AGA', 'pep')
        cmd.mset('1 x30')
        cmd.mview('store', first=1)
        cmd.turn('y', 90)
        cmd.mview('store', first=30)
        old = self.pse()
        cmd.save(old)          # nothing staged: no `raymol_timeline` key

        appkit_movie.stage_timeline(json.dumps(ITEMS))
        appkit_movie.capture_view('cam-1')
        cmd.load(old)

        self.assertIsNone(appkit_movie._timeline)
        self.assertEqual(appkit_movie._views, {})
        self.assertEqual(self.emitted[-1:], [([], True)])
        self.assertEqual(cmd.get_movie_length(), 30)

    def test_session_without_movie_reports_none(self):
        cmd.reinitialize()
        cmd.fab('AGA', 'pep')
        plain = self.pse()
        cmd.save(plain)
        cmd.load(plain)
        self.assertEqual(self.emitted[-1:], [([], False)])

    def test_partial_restore_leaves_the_lane_alone(self):
        cmd.reinitialize()
        cmd.fab('AGA', 'pep')
        other = self.pse()
        cmd.save(other)
        self.build()
        self.emitted.clear()
        cmd.load(other, partial=1)
        self.assertEqual(appkit_movie._timeline, ITEMS)
        self.assertIn('cam-1', appkit_movie._views)
        self.assertEqual(self.emitted, [])

    def test_empty_stage_empties_the_lane(self):
        appkit_movie.stage_timeline(json.dumps(ITEMS))
        appkit_movie.stage_timeline('[]')
        self.assertIsNone(appkit_movie._timeline)
        session = {}
        appkit_movie.session_save(session)
        self.assertNotIn(appkit_movie.SESSION_KEY, session)

    def test_scene_rename_rekeys_the_saved_lane(self):
        cmd.reinitialize()
        self.build()
        cmd.scene('F1 \u00e9', 'rename', new_key='Intro')
        saved = self.pse()
        cmd.save(saved)
        appkit_movie.forget_all_views()
        cmd.load(saved)
        expected = copy.deepcopy(ITEMS)
        expected[1]['scene'] = 'Intro'
        self.assertEqual(appkit_movie._timeline, expected)
        self.assertIn('Intro', cmd.get_scene_list())

    def test_reinitialize_empties_the_lane_and_tells_the_app(self):
        cmd.reinitialize()
        self.build()
        self.emitted.clear()
        cmd.reinitialize()
        self.assertIsNone(appkit_movie._timeline)
        self.assertEqual(appkit_movie._views, {})
        self.assertEqual(self.emitted, [([], False)])
        session = {}
        appkit_movie.session_save(session)
        self.assertNotIn(appkit_movie.SESSION_KEY, session)

    def test_reinitialize_of_settings_keeps_the_lane(self):
        appkit_movie.stage_timeline(json.dumps(ITEMS))
        cmd.reinitialize('settings')
        self.assertEqual(appkit_movie._timeline, ITEMS)

    def test_snapshots_do_not_share_records_with_the_live_lane(self):
        cmd.reinitialize()
        self.build()
        snapshot = cmd.get_session()
        cmd.scene('F1 \u00e9', 'rename', new_key='Intro')
        saved = snapshot[appkit_movie.SESSION_KEY]['items']
        self.assertEqual(saved[1]['scene'], 'F1 \u00e9')

        cmd.set_session(snapshot)
        cmd.scene('F1 \u00e9', 'rename', new_key='Outro')
        self.assertEqual(appkit_movie._timeline[1]['scene'], 'Outro')
        self.assertEqual(saved[1]['scene'], 'F1 \u00e9')

    def test_a_long_lane_reaches_the_app_whole(self):
        # Through the real emitter: the line must stay under PyMOL's ~1 KB
        # feedback cap whatever the lane's size, and the file holds it all.
        appkit_movie._emit_timeline = type(self).real_emit
        from pymol import raymol_tmp
        items = [dict(ITEMS[0], id='cam-%03d' % i) for i in range(200)]
        out = io.StringIO()
        sink = types.ModuleType('pcatch')
        sink.write = out.write
        with mock.patch.dict(sys.modules, {'pcatch': sink}):
            appkit_movie._emit_timeline(items, False)
        self.assertEqual(out.getvalue(), 'TIMELINE:ready\n')
        with open(raymol_tmp.channel_path('pymol_timeline'), encoding='utf-8') as handle:
            self.assertEqual(json.load(handle),
                             {'items': items, 'untrackedMovie': False})
