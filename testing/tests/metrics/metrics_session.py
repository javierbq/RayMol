"""The .pse round trip, and what follows an object through a rename or a delete (#308).

    pymol -ckqy testing/testing.py --run testing/tests/metrics/metrics_session.py
"""
import json
import os
import tempfile

from pymol import cmd, testing
from pymol.metrics import binding, schema, store

TOOL = 'sessiontest'


class MetricSessionTestCase(testing.PyMOLTestCase):

    def setUp(self):
        testing.PyMOLTestCase.setUp(self)
        self._saved = dict(schema._SCHEMAS)
        schema.register(TOOL, [
            schema.MetricSpec('recovery', schema.OBJECT, lo=0, hi=100),
            schema.MetricSpec('conf', schema.RESIDUE, lo=0, hi=100),
            schema.MetricSpec('error', schema.PAIR),
        ], replace=True)

    def tearDown(self):
        store.clear()
        schema._SCHEMAS.clear()
        schema._SCHEMAS.update(self._saved)
        testing.PyMOLTestCase.tearDown(self)

    def pse(self):
        handle, path = tempfile.mkstemp(suffix='.pse')
        os.close(handle)
        self.addCleanup(lambda: os.path.exists(path) and os.unlink(path))
        return path

    def scored(self, name='pep'):
        cmd.fab('ACDEF', name, chain='A')
        index = sorted(binding.residue_index(name))
        run = binding.record(name, TOOL, [
            store.value(TOOL, 'recovery', value=42.5),
            store.value(TOOL, 'conf', state=1, index=index,
                        values=[float(i) for i in range(len(index))]),
            store.value(TOOL, 'error', state=1, index=index,
                        values=[1.0] * len(index) ** 2),
        ], inputs={'seed': 7}, tool_version='v1')
        return name, index, run


class RoundTripTest(MetricSessionTestCase):

    def testArraysAndScalarsSurviveAPse(self):
        name, index, run = self.scored()
        path = self.pse()
        cmd.save(path)
        cmd.reinitialize()
        self.assertEqual(store.ids(), [], 'reinitialize must empty the store')
        cmd.load(path)

        back = store.get(run.id)
        self.assertEqual(back.object, name)
        self.assertEqual(back.tool_version, 'v1')
        self.assertEqual(back.inputs['seed'], 7)
        self.assertEqual(back.scalars()['recovery'], 42.5)
        conf = back.one('conf', state=1)
        self.assertEqual([tuple(pair) for pair in conf.index], index)
        self.assertEqual(conf.values, [float(i) for i in range(len(index))])
        self.assertEqual(len(back.one('error', state=1).values), len(index) ** 2)

    def testAbsentValuesSurviveTheRoundTrip(self):
        cmd.fab('ACDEF', 'pep', chain='A')
        index = sorted(binding.residue_index('pep'))
        run = binding.record('pep', TOOL, [
            store.value(TOOL, 'conf', state=1, index=index,
                        values=[None] * len(index))])
        session = {}
        store.session_save(session)
        store.clear()
        store.session_restore(session)
        self.assertEqual(store.get(run.id).one('conf', state=1).values,
                         [None] * len(index))

    def testASessionWithoutMetricsEmptiesTheStore(self):
        # Opening a session with no metrics must not leave the previous session's
        # numbers attached to objects that are gone.
        self.scored()
        store.session_restore({})
        self.assertEqual(store.ids(), [])

    def testNothingIsWrittenWhenNothingIsRecorded(self):
        session = {}
        store.session_save(session)
        self.assertNotIn(store.SESSION_KEY, session)

    def testAFutureFormatIsSkippedNotGuessedAt(self):
        session = {store.SESSION_KEY: {'version': store.SESSION_VERSION + 1,
                                       'runs': [{'id': 'x'}]}}
        store.session_restore(session)
        self.assertEqual(store.ids(), [])

    def testAMalformedRunIsSkippedAndTheRestSurvive(self):
        name, index, run = self.scored()
        session = {}
        store.session_save(session)
        session[store.SESSION_KEY]['runs'].insert(0, {'id': 'broken'})
        store.clear()
        store.session_restore(session)
        self.assertEqual(store.ids(), [run.id])

    def testARunFromAToolThisBuildLacksIsStillRestored(self):
        # A .pse may carry a plugin's numbers. Dropping them because nothing here can
        # colour by them would lose the data the session was saved to keep.
        name, index, run = self.scored()
        session = {}
        store.session_save(session)
        store.clear()
        schema.forget(TOOL)
        store.session_restore(session)
        self.assertEqual(store.get(run.id).scalars()['recovery'], 42.5)


class PanelPayloadTest(MetricSessionTestCase):
    """What the object panel is handed, and what it must never make anyone compute."""

    def payload(self):
        from pymol import appkit_inspector as ai
        path = os.path.join(tempfile.gettempdir(),
                            'pymol_objpanel_%d.json' % os.getpid())
        ai.poll_panel()
        with open(path) as handle:
            return json.load(handle)

    def testRunsReachThePanelKeyedByObject(self):
        name, index, run = self.scored()
        rows = self.payload()['metrics'][name]
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]['run'], run.id)
        self.assertEqual(rows[0]['tool'], TOOL)
        self.assertIn('recovery', [s['key'] for s in rows[0]['scalars']])

    def testArraysAreNamedButNeverSent(self):
        # A PAE matrix is the residue index squared. The panel polls the main thread
        # every 500 ms; it gets the KEY and no values.
        name, index, run = self.scored()
        rows = self.payload()['metrics'][name]
        self.assertIn('conf', rows[0]['keys'])
        self.assertNotIn('conf', [s['key'] for s in rows[0]['scalars']])
        self.assertNotIn('values', json.dumps(rows[0]))

    def testStalenessIsFlaggedForThePanel(self):
        name, index, run = self.scored()
        self.assertFalse(self.payload()['metrics'][name][0]['stale'])
        cmd.create(name, name, 1, 2)
        self.assertTrue(self.payload()['metrics'][name][0]['stale'])

    def testNothingRecordedMeansAnEmptyMap(self):
        cmd.fab('ACDEF', 'bare', chain='A')
        self.assertEqual(self.payload()['metrics'], {})


class FollowsTheObjectTest(MetricSessionTestCase):

    def testRenameIsFollowed(self):
        name, index, run = self.scored()
        cmd.set_name(name, 'renamed')
        self.assertEqual(store.get(run.id).object, 'renamed')

    def testDeleteDropsTheRun(self):
        name, index, run = self.scored()
        cmd.delete(name)
        self.assertFalse(store.have(run.id))

    def testDeleteByWildcardDropsTheRun(self):
        name, index, run = self.scored('pep_one')
        cmd.delete('pep_*')
        self.assertFalse(store.have(run.id))

    def testDeletingAnotherObjectKeepsTheRun(self):
        name, index, run = self.scored()
        cmd.fab('AAA', 'other', chain='A')
        cmd.delete('other')
        self.assertTrue(store.have(run.id))

    def testACreatedCopyDoesNotInheritMetrics(self):
        # A copy may be a subset selection, so its residues need not be the ones the
        # array was indexed by. Inheriting would be a measurement of a different thing.
        name, index, run = self.scored()
        cmd.create('copy_of_pep', name)
        self.assertEqual(store.runs(object='copy_of_pep'), [])
