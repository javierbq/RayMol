"""Materials in scenes (#489).

A scene stores what each object is MADE OF, not just how it is lit: the four
per-representation material settings and `transparency_peel` per object, and
`material_default` / `material_env` globally. Ids step at a scene cut -- there
is nothing meaningful to interpolate between two materials -- so they are
captured, never ramped.

Runs on a RayMol --testing build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/scene_materials.py
"""
from pymol import cmd, testing
from pymol import raymol_scenes as rs

REP_MATERIALS = ['cartoon_material', 'surface_material',
                 'stick_material', 'sphere_material']

MATERIAL_SETTINGS = REP_MATERIALS + ['material_default', 'material_env',
                                     'transparency_peel']


def material_id(name):
    """The id of a material by NAME, from the live table -- never a literal, so
    the test keeps passing when a row is inserted above it."""
    from pymol import setting
    return setting.material_id_dict[name]


class _Recorder:
    """cmd proxy that records every set/unset and still performs it.

    Lets a test assert on the WRITES a recall makes, not only on the values it
    ends with: the material settings carry a rep-rebuild side effect, so a write
    that changes nothing still costs a full geometry rebuild."""

    def __init__(self, target=cmd):
        self._t = target
        self.sets = []
        self.unsets = []

    def __getattr__(self, k):
        return getattr(self._t, k)

    def set(self, *a, **kw):
        self.sets.append(a)
        return self._t.set(*a, **kw)

    def unset(self, *a, **kw):
        self.unsets.append(a)
        return self._t.unset(*a, **kw)


class TestSceneMaterials(testing.PyMOLTestCase):
    def setUp(self):
        super().setUp()
        cmd.reinitialize()
        rs.clear_all()
        cmd.fragment('ala', 'm1')
        cmd.fragment('gly', 'm2')

    def testEveryMaterialSettingIsCaptured(self):
        for name in REP_MATERIALS:
            self.assertIn(name, rs.OBJECT_CAPTURE, name)
        self.assertIn('transparency_peel', rs.OBJECT_CAPTURE)
        for name in ('material_default', 'material_env'):
            self.assertIn(name, rs.CAPTURE, name)

    def testMaterialsAreNotInterpolated(self):
        """A material id is a table row, not a quantity: ramping 7 -> 8 would
        walk through unrelated materials."""
        from pymol import raymol_scene_anim
        for name in REP_MATERIALS + ['transparency_peel', 'material_default',
                                     'material_env']:
            self.assertNotIn(name, raymol_scene_anim.INTERPOLATE, name)

    def testPerObjectMaterialsRecallPerScene(self):
        cmd.set('cartoon_material', 'marble', 'm1')
        cmd.set('surface_material', 'clay', 'm2')
        cmd.scene('A', 'store')
        cmd.set('cartoon_material', 'rubber', 'm1')
        cmd.unset('surface_material', 'm2')
        cmd.scene('B', 'store')

        cmd.scene('A', 'recall', animate=0)
        self.assertEqual(cmd.get('cartoon_material', 'm1'), 'marble')
        self.assertEqual(cmd.get('surface_material', 'm2'), 'clay')
        cmd.scene('B', 'recall', animate=0)
        self.assertEqual(cmd.get('cartoon_material', 'm1'), 'rubber')
        # ...and the object that lost its material gets it UNSET, not left behind.
        self.assertEqual(cmd.get_setting_int('surface_material', 'm2'), 0)

    def testTheGlobalDefaultIsCapturedAsAnId(self):
        """`cmd.get` renders material_default as a NAME; the scene stores the
        id, which is what the rest of the .pse format uses."""
        cmd.set('material_default', 'clay')
        cmd.scene('A', 'store')
        self.assertEqual(rs.scene_settings_map('A')['material_default'],
                         material_id('clay'))

    def testEveryMaterialSettingIsCapturedAsAnId(self):
        """Not just material_default: each of the five is id-valued, and the
        id-valued set is derived from the table rather than listed by hand."""
        for name in REP_MATERIALS + ['material_default']:
            self.assertIn(name, rs.MATERIAL_ID_SETTINGS(), name)
        cmd.set('cartoon_material', 'marble')
        cmd.scene('A', 'store')
        self.assertEqual(rs.scene_settings_map('A')['cartoon_material'],
                         material_id('marble'))

    def testTheGlobalDefaultRecalls(self):
        cmd.set('material_default', 'clay')
        cmd.scene('A', 'store')
        cmd.set('material_default', 'default')
        cmd.scene('A', 'recall', animate=0)
        self.assertEqual(cmd.get('material_default'), 'clay')

    def testPeelIsCapturedPerObject(self):
        cmd.set('transparency_peel', 1, 'm1')
        cmd.scene('A', 'store')
        cmd.set('transparency_peel', 0, 'm1')
        cmd.scene('A', 'recall', animate=0)
        self.assertEqual(cmd.get_setting_int('transparency_peel', 'm1'), 1)

    def testTwoObjectsWithDifferentMaterialsRoundTripThroughAPse(self):
        cmd.set('cartoon_material', 'marble', 'm1')
        cmd.set('cartoon_material', 'rubber', 'm2')
        cmd.set('material_default', 'matte')
        cmd.scene('A', 'store')
        with testing.mktemp('.pse') as fn:
            cmd.save(fn)
            cmd.reinitialize()
            rs.clear_all()
            cmd.load(fn)
        # the live values survive the session...
        self.assertEqual(cmd.get('cartoon_material', 'm1'), 'marble')
        self.assertEqual(cmd.get('cartoon_material', 'm2'), 'rubber')
        # ...and so does the scene that captured them.
        cmd.set('cartoon_material', 'default', 'm1')
        cmd.set('cartoon_material', 'default', 'm2')
        cmd.set('material_default', 'default')
        cmd.scene('A', 'recall', animate=0)
        self.assertEqual(cmd.get('cartoon_material', 'm1'), 'marble')
        self.assertEqual(cmd.get('cartoon_material', 'm2'), 'rubber')
        self.assertEqual(cmd.get('material_default'), 'matte')

    def testTheGlobalRepMaterialsAreCapturedAndRecalled(self):
        """The four rep materials are OBJECT-level settings: they have a global
        fallback AS WELL AS per-object overrides, and an object with no override
        of its own renders with the global. Capturing only the per-object half
        left that global to whatever was set last."""
        for name in REP_MATERIALS:
            self.assertIn(name, rs.CAPTURE, name)
        cmd.set('cartoon_material', 'marble')       # global, no object
        cmd.set('stick_material', 'rubber')
        cmd.scene('A', 'store')
        cmd.set('cartoon_material', 'default')
        cmd.set('stick_material', 'default')
        cmd.scene('A', 'recall', animate=0)
        self.assertEqual(cmd.get('cartoon_material'), 'marble')
        self.assertEqual(cmd.get('stick_material'), 'rubber')
        # an object with no override of its own follows the restored global
        self.assertEqual(cmd.get('cartoon_material', 'm1'), 'marble')

    def testTheGlobalEnvironmentRecalls(self):
        cmd.set('material_env', 1)
        cmd.scene('A', 'store')
        cmd.set('material_env', 0)
        cmd.scene('A', 'recall', animate=0)
        self.assertEqual(cmd.get_setting_int('material_env'), 1)

    def testPeelKeepsItsThreeStatesApart(self):
        """`transparency_peel` is a tri-state: -1 follow the global, 0 off,
        1 on. Unset-on-the-object and set-to-0 are different scenes, so a
        recall that confused them would silently flip one object's peel."""
        cmd.set('transparency_peel', 0, 'm1')       # explicitly OFF
        cmd.scene('OFF', 'store')
        cmd.unset('transparency_peel', 'm1')        # follow the global
        cmd.scene('UNSET', 'store')
        cmd.set('transparency_peel', 1, 'm1')
        cmd.scene('ON', 'store')

        self.assertIn('transparency_peel', rs.scene_object_settings_map('OFF')['m1'])
        self.assertNotIn('transparency_peel', rs.scene_object_settings_map('UNSET')['m1'])

        cmd.scene('OFF', 'recall', animate=0)
        self.assertEqual(cmd.get_setting_int('transparency_peel', 'm1'), 0)
        self.assertIn('transparency_peel', _explicit('m1'))
        cmd.scene('UNSET', 'recall', animate=0)
        self.assertNotIn('transparency_peel', _explicit('m1'))
        cmd.scene('ON', 'recall', animate=0)
        self.assertEqual(cmd.get_setting_int('transparency_peel', 'm1'), 1)

    def testRecallWritesNothingWhenNothingChanged(self):
        """Every material setting invalidates the representations it feeds, so
        re-writing a value that already matches costs a full geometry rebuild of
        every object. A recall of the scene already on screen must be silent."""
        cmd.set('cartoon_material', 'marble', 'm1')
        cmd.set('material_default', 'clay')
        cmd.set('transparency_peel', 1, 'm2')
        cmd.scene('A', 'store')

        rec = _Recorder()
        rs.apply('A', rec)
        self.assertEqual([a for a in rec.sets if a[0] in MATERIAL_SETTINGS], [])
        self.assertEqual(rec.unsets, [])

    def testRecallStillWritesWhatDidChange(self):
        """The other direction of the check above: skipping no-op writes must
        not skip the real ones."""
        cmd.set('cartoon_material', 'marble', 'm1')
        cmd.set('material_default', 'clay')
        cmd.scene('A', 'store')
        cmd.set('cartoon_material', 'rubber', 'm1')
        cmd.set('material_default', 'matte')
        cmd.set('surface_material', 'marble', 'm2')   # gained an override

        rec = _Recorder()
        rs.apply('A', rec)
        self.assertIn(('material_default', material_id('clay')), rec.sets)
        self.assertIn(('cartoon_material', material_id('marble'), 'm1'), rec.sets)
        self.assertIn(('surface_material', 'm2'), rec.unsets)
        self.assertEqual(cmd.get('cartoon_material', 'm1'), 'marble')
        self.assertEqual(cmd.get('material_default'), 'clay')
        self.assertEqual(cmd.get_setting_int('surface_material', 'm2'), 0)

    def testTheMovieFrameCallbackWritesNothingWhenNothingChanged(self):
        """`enter_scene` is the second consumer of the captured payload -- it
        runs at every scene keyframe, twice per scene, on every pass of a
        looping movie and every frame of an export. It had its own copy of the
        write loop, so the conditional-write fix reached only half the product:
        a movie with no materials in it at all still rebuilt cartoon, surface,
        stick and sphere geometry at each cut."""
        import base64
        from pymol import raymol_scene_anim as ra
        cmd.set('cartoon_material', 'marble', 'm1')
        cmd.set('material_default', 'clay')
        cmd.scene('A', 'store')

        rec = _Recorder()
        ra.enter_scene(base64.b64encode(b'A').decode(), rec)
        self.assertEqual([a for a in rec.sets if a[0] in MATERIAL_SETTINGS], [])

    def testTheMovieFrameCallbackStillAppliesWhatDidChange(self):
        import base64
        from pymol import raymol_scene_anim as ra
        cmd.set('material_default', 'clay')
        cmd.scene('A', 'store')
        cmd.set('material_default', 'matte')

        rec = _Recorder()
        ra.enter_scene(base64.b64encode(b'A').decode(), rec)
        self.assertIn(('material_default', material_id('clay')), rec.sets)
        self.assertEqual(cmd.get('material_default'), 'clay')

    def testALegacySceneDoesNotUnsetMaterialsItNeverCaptured(self):
        """A scene stored before the materials joined OBJECT_CAPTURE recorded
        only the reflection settings per object. Reading "absent from the map"
        as "the object had no material" would make recalling such a scene WIPE
        a material the user set afterwards -- silently, and only for objects
        with an explicit override, so the scene would half-restore."""
        cmd.scene('A', 'store')
        # Exactly what a .pse from that build leaves behind: a per-object map
        # with no record of which names the capture was looking for.
        rs._scene_object_capture.pop('A', None)
        cmd.set('cartoon_material', 'marble', 'm1')
        cmd.scene('A', 'recall', animate=0)
        self.assertEqual(cmd.get('cartoon_material', 'm1'), 'marble')

    def testASceneStoredNowStillUnsetsWhatItCaptured(self):
        """The other direction: the guard above must not disable unsetting for
        scenes that DID capture the materials."""
        cmd.scene('A', 'store')
        self.assertIn('cartoon_material', rs._scene_object_capture['A'])
        cmd.set('cartoon_material', 'marble', 'm1')
        cmd.scene('A', 'recall', animate=0)
        self.assertEqual(cmd.get_setting_int('cartoon_material', 'm1'), 0)

    def testTheCapturedNameListSurvivesAPse(self):
        cmd.scene('A', 'store')
        with testing.mktemp('.pse') as fn:
            cmd.save(fn)
            cmd.reinitialize()
            rs.clear_all()
            cmd.load(fn)
        self.assertIn('cartoon_material', rs._scene_object_capture['A'])

    def testAMaterialIsNeverBakedOntoAnObjectThatHasNone(self):
        cmd.set('material_default', 'clay')      # global only
        cmd.scene('A', 'store')
        captured = rs.scene_object_settings_map('A')
        for obj in ('m1', 'm2'):
            self.assertNotIn('cartoon_material', captured[obj], obj)


def _explicit(obj):
    """The setting names object `obj` has EXPLICITLY set (its own table), by
    name -- what distinguishes "set to 0" from "not set"."""
    from pymol import setting
    out = set()
    for entry in (cmd.get_object_settings(obj) or []):
        try:
            out.add(setting._get_name(entry[0]))
        except Exception:
            pass
    return out
