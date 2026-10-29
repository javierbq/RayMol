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

    def test_morph_clip_keeps_its_stride_through_a_session(self):
        # A morph clip's first/last are model indices; the app maps them to
        # the morph's states with morphStride, so the key must come back
        # untouched in the TIMELINE:ready payload after save -> restore.
        appkit_movie._emit_timeline = type(self).real_emit
        from pymol import raymol_tmp
        morph = {'id': 'st-morph', 'kind': 'states', 'seconds': 1.0,
                 'linear': True,
                 'states': {'objects': ['pep_morph'], 'mode': 'sweep',
                            'first': 3, 'last': 8, 'seconds': 10.0,
                            'morphStride': 15}}
        items = ITEMS + [morph]
        cmd.reinitialize()
        cmd.fab('AGA', 'pep')
        appkit_movie.stage_timeline(json.dumps(items))
        saved = self.pse()
        cmd.save(saved)

        appkit_movie.forget_all_views()
        cmd.reinitialize()
        out = io.StringIO()
        sink = types.ModuleType('pcatch')
        sink.write = out.write
        with mock.patch.dict(sys.modules, {'pcatch': sink}):
            cmd.load(saved)

        self.assertEqual(appkit_movie._timeline, items)
        self.assertTrue(out.getvalue().endswith('TIMELINE:ready\n'))
        with open(raymol_tmp.channel_path('pymol_timeline'), encoding='utf-8') as handle:
            payload = json.load(handle)
        self.assertEqual(payload, {'items': items, 'untrackedMovie': False})
        self.assertEqual(payload['items'][-1]['states']['morphStride'], 15)

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


STATE = 193     # the `state` setting's index (setting.index_dict['state'])


class PlayerPinSessionTest(testing.PyMOLTestCase):
    '''Morph close-out B (F5 residual): the Objects-panel player animates an
    object by sending `set state, k, name` on a timer, so while it plays the
    object carries an object-level `state` (a pin). The app notes the objects
    it plays in appkit_movie; a session written meanwhile leaves their pins
    out, so the reopened morph follows the movie (Lockstep, mplay, export)
    instead of freezing on the saved frame. Every other pin is the user's and
    stays (C2), and the live objects keep theirs.'''

    def setUp(self):
        super().setUp()
        cmd.reinitialize()
        appkit_movie.clear_playing_objects()
        self.addCleanup(appkit_movie.clear_playing_objects)
        real = appkit_movie._emit_timeline
        appkit_movie._emit_timeline = lambda items, untracked_movie=False: None
        self.addCleanup(setattr, appkit_movie, '_emit_timeline', real)

    def pse(self):
        handle, path = tempfile.mkstemp(suffix='.pse')
        os.close(handle)
        self.addCleanup(lambda: os.path.exists(path) and os.unlink(path))
        return path

    def ensemble(self, name, states=12):
        cmd.fab('AGA', name)
        for k in range(2, states + 1):
            cmd.create(name, name, 1, k)

    def pin(self, name):
        '''The object-level `state` setting, or None. get_object_settings
        runs no session-save task, so this reads the live object.'''
        for index, _type, value in cmd.get_object_settings(name) or []:
            if index == STATE:
                return value
        return None

    def reopen(self, path):
        cmd.reinitialize()
        cmd.load(path)
        cmd.mset('1 -12')
        cmd.frame(7)

    def test_state_index(self):
        from pymol import setting
        self.assertEqual(setting._get_index('state'), STATE)

    @testing.foreach(0, 1)
    def test_save_while_playing_leaves_the_timer_pin_out(self, binary):
        cmd.set('pse_binary_dump', binary)
        self.ensemble('src_morph')
        cmd.set('state', 5, 'src_morph')
        cmd.set('sphere_scale', 0.5, 'src_morph')
        appkit_movie.note_object_playing('src_morph', True)
        saved = self.pse()
        cmd.save(saved)
        # The live object keeps its pin: the player goes on.
        self.assertEqual(self.pin('src_morph'), 5)
        self.assertEqual(appkit_movie.playing_objects(), ['src_morph'])

        self.reopen(saved)
        self.assertIsNone(self.pin('src_morph'))
        self.assertEqual(cmd.get_setting_int('state', 'src_morph'), 7)
        # Only `state` goes: the object's other settings ride along.
        self.assertEqual(cmd.get_setting_float('sphere_scale', 'src_morph'), 0.5)

    def test_a_pin_on_an_object_not_playing_stays(self):
        self.ensemble('src_morph')
        self.ensemble('other')
        cmd.set('state', 5, 'src_morph')
        cmd.set('state', 3, 'other')
        appkit_movie.note_object_playing('other', True)
        saved = self.pse()
        cmd.save(saved)

        self.reopen(saved)
        self.assertEqual(self.pin('src_morph'), 5)
        self.assertEqual(cmd.get_setting_int('state', 'src_morph'), 5)
        self.assertIsNone(self.pin('other'))
        self.assertEqual(cmd.get_setting_int('state', 'other'), 7)

    def test_a_player_stopped_on_a_frame_keeps_its_pin(self):
        self.ensemble('src_morph')
        cmd.set('state', 5, 'src_morph')
        appkit_movie.note_object_playing('src_morph', True)
        appkit_movie.note_object_playing('src_morph', False)
        self.assertEqual(appkit_movie.playing_objects(), [])
        saved = self.pse()
        cmd.save(saved)

        self.reopen(saved)
        self.assertEqual(self.pin('src_morph'), 5)

    def test_a_snapshot_is_a_copy(self):
        self.ensemble('src_morph')
        cmd.set('state', 5, 'src_morph')
        appkit_movie.note_object_playing('src_morph', True)
        session = cmd.get_session()
        entry = next(e for e in session['names'] if e and e[0] == 'src_morph')
        self.assertNotIn(STATE, [s[0] for s in entry[5][0][8] or []])
        self.assertEqual(self.pin('src_morph'), 5)

    def test_a_partial_save_leaves_the_timer_pin_out(self):
        self.ensemble('src_morph')
        cmd.set('state', 5, 'src_morph')
        appkit_movie.note_object_playing('src_morph', True)
        saved = self.pse()
        cmd.save(saved, 'src_morph')

        self.reopen(saved)
        self.assertIsNone(self.pin('src_morph'))

    def cgo_ensemble(self, name, states=5):
        from pymol.cgo import SPHERE
        for k in range(1, states + 1):
            cmd.load_cgo([SPHERE, float(k), 0.0, 0.0, 1.0], name, state=k)

    def test_a_group_player_leaves_its_members_pins_out(self):
        # `set state, k, <group>` pins the objects inside the group, all the
        # way down, and not the group itself. The registry holds the group's
        # name, so the save strips its members: molecules, and objects no
        # selection reaches (a CGO).
        self.ensemble('m1')
        self.cgo_ensemble('cg')
        self.ensemble('outside')
        cmd.group('grp', 'm1 cg')
        cmd.group('outer', 'grp')
        cmd.set('state', 5, 'outer')
        cmd.set('state', 3, 'outside')
        self.assertEqual(self.pin('m1'), 5)
        self.assertEqual(self.pin('cg'), 5)
        appkit_movie.note_object_playing('outer', True)
        saved = self.pse()
        cmd.save(saved)
        self.assertEqual(self.pin('m1'), 5)

        self.reopen(saved)
        self.assertIsNone(self.pin('m1'))
        self.assertEqual(cmd.get_setting_int('state', 'm1'), 7)
        self.assertIsNone(self.pin('cg'))
        # C2: an object outside the playing group keeps its pin.
        self.assertEqual(self.pin('outside'), 3)

    def test_a_partial_save_of_a_group_players_member_leaves_its_pin_out(self):
        # The file holds the member but not the groups above it, so only the
        # live group still names it.
        self.ensemble('m1')
        cmd.group('grp', 'm1')
        cmd.group('outer', 'grp')
        cmd.set('state', 5, 'outer')
        appkit_movie.note_object_playing('outer', True)
        saved = self.pse()
        cmd.save(saved, 'm1')

        self.reopen(saved)
        self.assertIsNone(self.pin('m1'))

    def test_a_partial_save_of_a_nested_group_players_cgo_leaves_its_pin_out(self):
        # Two group levels above a CGO are missing from the file, and a
        # selection never reaches a CGO: the live group's members come from a
        # core read of that group instead. (The molecule makes the group
        # playable: a CGO-only group counts no states.)
        self.cgo_ensemble('cg')
        self.ensemble('m1')
        cmd.group('inner', 'cg m1')
        cmd.group('outer', 'inner')
        cmd.set('state', 3, 'outer')
        self.assertEqual(self.pin('cg'), 3)
        appkit_movie.note_object_playing('outer', True)
        saved = self.pse()
        cmd.save(saved, 'cg')
        self.assertEqual(self.pin('cg'), 3)     # the live player goes on

        self.reopen(saved)
        self.assertIsNone(self.pin('cg'))

    def test_renaming_a_playing_object_lets_it_go(self):
        # The player's timer goes on sending `set state, k, <old name>` until
        # the panel poll stops it, so it no longer reaches the renamed object:
        # the rename drops the pin the timer left on it, live and so in every
        # later save. The registry keeps the old name, which the timer still
        # targets, until the app stops that player.
        self.ensemble('src_morph')
        cmd.set('state', 5, 'src_morph')
        appkit_movie.note_object_playing('src_morph', True)
        cmd.set_name('src_morph', 'renamed')
        self.assertIsNone(self.pin('renamed'))
        self.assertEqual(appkit_movie.playing_objects(), ['src_morph'])
        appkit_movie.note_object_playing('src_morph', False)   # the poll's prune
        saved = self.pse()
        cmd.save(saved)

        self.reopen(saved)
        self.assertIsNone(self.pin('renamed'))
        self.assertEqual(cmd.get_setting_int('state', 'renamed'), 7)

    def test_a_tick_after_a_prefix_rename_does_not_keep_the_pin(self):
        # `src` is an unambiguous prefix of `src2`, so a tick sent between the
        # rename and the poll that stops the player pins the renamed object
        # again: a save meanwhile leaves it out, and stopping the player drops it.
        self.ensemble('src')
        appkit_movie.note_object_playing('src', True)
        cmd.set_name('src', 'src2')
        cmd.set('state', 6, 'src')                    # the timer's next tick
        self.assertEqual(self.pin('src2'), 6)
        saved = self.pse()
        cmd.save(saved)
        appkit_movie.note_object_playing('src', False)   # the poll's prune
        self.assertIsNone(self.pin('src2'))
        self.reopen(saved)
        self.assertIsNone(self.pin('src2'))

    def test_renaming_to_a_name_the_core_rewrites_lets_it_go(self):
        # set_name legalises the new name ('my morph' -> 'my_morph').
        self.ensemble('src_morph')
        cmd.set('state', 5, 'src_morph')
        appkit_movie.note_object_playing('src_morph', True)
        cmd.set_name('src_morph', 'my morph')
        self.assertIn('my_morph', cmd.get_names('objects'))
        self.assertIsNone(self.pin('my_morph'))

    def test_renaming_a_playing_group_lets_its_members_go(self):
        self.ensemble('m1')
        cmd.group('grp', 'm1')
        cmd.set('state', 5, 'grp')
        appkit_movie.note_object_playing('grp', True)
        cmd.set_name('grp', 'grp2')
        self.assertIsNone(self.pin('m1'))

    def test_renaming_an_object_not_playing_keeps_its_pin(self):
        # C2: a player stopped on a frame, or a typed `set state`.
        self.ensemble('src_morph')
        self.ensemble('other')
        cmd.set('state', 5, 'src_morph')
        cmd.set('state', 3, 'other')
        appkit_movie.note_object_playing('src_morph', True)
        appkit_movie.note_object_playing('src_morph', False)
        appkit_movie.note_object_playing('third', True)
        cmd.set_name('src_morph', 'stopped')
        cmd.set_name('other', 'typed')
        self.assertEqual(self.pin('stopped'), 5)
        self.assertEqual(self.pin('typed'), 3)

    def test_a_player_with_nothing_to_strip_saves(self):
        # No object settings at all (None in the session), and a name the
        # session does not hold.
        self.ensemble('src_morph')
        appkit_movie.note_object_playing('src_morph', True)
        appkit_movie.note_object_playing('gone', True)
        saved = self.pse()
        cmd.save(saved)
        self.reopen(saved)
        self.assertIsNone(self.pin('src_morph'))

    def test_reinitialize_clears_the_registry(self):
        appkit_movie.note_object_playing('src_morph', True)
        cmd.reinitialize()
        self.assertEqual(appkit_movie.playing_objects(), [])

    def test_reinitialize_of_settings_keeps_the_registry(self):
        appkit_movie.note_object_playing('src_morph', True)
        cmd.reinitialize('settings')
        self.assertEqual(appkit_movie.playing_objects(), ['src_morph'])

    def test_a_full_restore_clears_the_registry_a_partial_keeps_it(self):
        self.ensemble('src_morph')
        saved = self.pse()
        cmd.save(saved)
        appkit_movie.note_object_playing('src_morph', True)
        cmd.load(saved, partial=1)
        self.assertEqual(appkit_movie.playing_objects(), ['src_morph'])
        cmd.load(saved)
        self.assertEqual(appkit_movie.playing_objects(), [])

    def test_theme_studio_round_trip_keeps_players_and_their_pins(self):
        # The studio snapshots the session in memory and puts it back: the
        # same session, so the players go on (PyMOLEngine keeps their timers
        # through the restore) and the objects keep their pins.
        from pymol import appkit_theme_preview as tp
        self.addCleanup(setattr, tp, '_saved', None)
        self.ensemble('src_morph')
        cmd.set('state', 5, 'src_morph')
        appkit_movie.note_object_playing('src_morph', True)
        tp.begin(cmd.exp_path('$PYMOL_DATA/demo/pept.pdb'))
        self.assertEqual(appkit_movie.playing_objects(), ['src_morph'])
        tp.restore()
        self.assertEqual(appkit_movie.playing_objects(), ['src_morph'])
        self.assertEqual(self.pin('src_morph'), 5)
