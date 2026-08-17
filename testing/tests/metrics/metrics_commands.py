"""The cmd.metrics_* surface: listing, reading, colouring, export and load (#308).

    pymol -ckqy testing/testing.py --run testing/tests/metrics/metrics_commands.py
"""
import json
import os
import tempfile

from pymol import cmd, testing
from pymol.metrics import binding, schema, store
from pymol.metrics.errors import (MetricAmbiguous, MetricNotFound,
                                  MetricScopeError)

TOOL = 'cmdtest'


class MetricCommandTestCase(testing.PyMOLTestCase):

    def setUp(self):
        testing.PyMOLTestCase.setUp(self)
        self._saved = dict(schema._SCHEMAS)
        schema.register(TOOL, [
            schema.MetricSpec('recovery', schema.OBJECT, lo=0, hi=100),
            schema.MetricSpec('score', schema.STATE, lo=0, hi=10),
            schema.MetricSpec('conf', schema.RESIDUE, lo=0, hi=100),
        ], replace=True)

    def tearDown(self):
        store.clear()
        schema._SCHEMAS.clear()
        schema._SCHEMAS.update(self._saved)
        testing.PyMOLTestCase.tearDown(self)

    def tmpfile(self, suffix):
        handle, path = tempfile.mkstemp(suffix=suffix)
        os.close(handle)
        self.addCleanup(lambda: os.path.exists(path) and os.unlink(path))
        return path

    def scored(self, name='pep', recovery=42.0, conf=None):
        if name not in cmd.get_names('objects'):
            cmd.fab('ACDEF', name, chain='A')
        index = sorted(binding.residue_index(name))
        values = [store.value(TOOL, 'recovery', value=recovery),
                  store.value(TOOL, 'score', value=5.0, state=1)]
        if conf is not False:
            values.append(store.value(
                TOOL, 'conf', state=1, index=index,
                values=conf if conf else [10.0 * (i + 1) for i in range(len(index))]))
        return name, index, binding.record(name, TOOL, values)


class ListAndGetTest(MetricCommandTestCase):

    def testListSeesEveryRunAndNarrows(self):
        self.scored('pep')
        self.scored('pep')
        cmd.fab('AAA', 'other', chain='A')
        self.scored('other')
        self.assertEqual(len(cmd.metrics_list()), 3)
        self.assertEqual(len(cmd.metrics_list('pep')), 2)
        self.assertEqual(len(cmd.metrics_list(tool=TOOL)), 3)
        self.assertEqual(cmd.metrics_list(tool='nosuch'), [])

    def testGetWholeRun(self):
        name, index, run = self.scored()
        got = cmd.metrics_get(run.id)
        self.assertEqual(got['scalars']['recovery'], 42.0)
        self.assertIn('conf', got['keys'])

    def testGetPrintsEachKeyOnce(self):
        # A chain-scope scalar is listed as `key/chain`, so a naive difference against
        # the scalar names prints every per-chain metric twice -- once with its value,
        # once as an "(array)" it is not.
        schema.register(TOOL, list(schema.specs(TOOL))
                        + [schema.MetricSpec('depth', schema.CHAIN, dtype='int')],
                        replace=True)
        name, index, run = self.scored()
        run.values.append(store.value(TOOL, 'depth', value=1000, chain='A'))
        got = cmd.metrics_get(run.id)
        self.assertIn('depth/A', got['scalars'])
        shown = {key.split('/', 1)[0] for key in got['scalars']}
        self.assertIn('depth', shown)
        self.assertEqual(len([k for k in got['keys'] if k not in shown]), 1)

    def testGetOneScalar(self):
        name, index, run = self.scored()
        self.assertEqual(cmd.metrics_get(run.id, 'recovery')['value'], 42.0)

    def testGetAnArrayCarriesItsIndex(self):
        # Not a bare list: a structure with unobserved residues is exactly where a
        # positional array lands on the wrong ones.
        name, index, run = self.scored()
        got = cmd.metrics_get(run.id, 'conf')
        self.assertEqual([tuple(p) for p in got['index']], index)
        self.assertEqual(len(got['values']), len(index))

    def testGetWithoutARunTakesTheNewestCarryingTheKey(self):
        self.scored('pep', recovery=1.0)
        self.scored('pep', recovery=2.0)
        self.assertEqual(cmd.metrics_get(object='pep', key='recovery')['value'], 2.0)

    def testGetUnknownKeyNamesWhatTheRunHas(self):
        name, index, run = self.scored()
        try:
            cmd.metrics_get(run.id, 'nope')
        except MetricNotFound as exc:
            self.assertIn('recovery', str(exc))
        else:
            self.fail('an absent key must be refused')

    def testDeleteByRunObjectAndAll(self):
        name, index, run = self.scored()
        self.assertEqual(cmd.metrics_delete(run.id), 1)
        self.scored('pep')
        self.scored('pep')
        self.assertEqual(cmd.metrics_delete('pep'), 2)
        self.scored('pep')
        self.assertEqual(cmd.metrics_delete('all'), 1)

    def testSchemaListsScopesAndRanges(self):
        out = cmd.metrics_schema(TOOL)
        keys = {entry['key']: entry for entry in out[TOOL]}
        self.assertEqual(keys['conf']['scope'], schema.RESIDUE)
        self.assertEqual(keys['conf']['hi'], 100.0)


class TwoToolsOnOneObjectTest(MetricCommandTestCase):
    """An object carries runs from several tools. They must not silently mix."""

    OTHER = 'cmdtest_other'

    def setUp(self):
        MetricCommandTestCase.setUp(self)
        # A second tool declaring the SAME key name at the same scope: the case where
        # recency is an arbitrary choice between different measurements.
        schema.register(self.OTHER, [
            schema.MetricSpec('conf', schema.RESIDUE, lo=0, hi=1),
        ], replace=True)

    def both(self):
        name, index, mine = self.scored()
        theirs = binding.record(name, self.OTHER, [
            store.value(self.OTHER, 'conf', state=1, index=index,
                        values=[0.5] * len(index))])
        return name, index, mine, theirs

    def testRunsFromTwoToolsCoexist(self):
        name, index, mine, theirs = self.both()
        self.assertEqual([r.tool for r in store.runs(object=name)],
                         [TOOL, self.OTHER])
        self.assertEqual(mine.one('conf', state=1).values[0], 10.0)
        self.assertEqual(theirs.one('conf', state=1).values[0], 0.5)

    def testTwoToolsSharingAKeyIsRefusedNotResolvedByRecency(self):
        name, index, mine, theirs = self.both()
        for call in (lambda: cmd.metrics_get(object=name, key='conf'),
                     lambda: cmd.metrics_color('conf', object=name)):
            try:
                call()
            except MetricAmbiguous as exc:
                self.assertIn(TOOL, str(exc))
                self.assertIn(self.OTHER, str(exc))
            else:
                self.fail('two tools carrying one key must not resolve silently')

    def testToolNamesWhichOneToUse(self):
        name, index, mine, theirs = self.both()
        self.assertEqual(cmd.metrics_get(object=name, key='conf',
                                         tool=self.OTHER)['values'][0], 0.5)
        self.assertEqual(cmd.metrics_get(object=name, key='conf',
                                         tool=TOOL)['values'][0], 10.0)
        cmd.metrics_color('conf', object=name, tool=self.OTHER)
        painted = []
        cmd.iterate('%s and name CA' % name, 'painted.append(b)',
                    space={'painted': painted})
        self.assertEqual(set(painted), {0.5})

    def testAnObjectNameInTheRunSlotIsReadAsAnObject(self):
        # `metrics_get my_object` is what a user types, and `run` is the first
        # positional. The id is tried first, so a run can never be shadowed.
        self.scored('pep', recovery=7.0)
        self.assertEqual(cmd.metrics_get('pep', 'recovery')['value'], 7.0)

    def testNeitherARunNorAnObjectStillRaises(self):
        self.scored('pep')
        self.assertRaises(MetricNotFound, cmd.metrics_get, 'not_a_thing')

    def testARunIdStillWinsOutright(self):
        name, index, mine, theirs = self.both()
        self.assertEqual(cmd.metrics_get(mine.id, 'conf')['values'][0], 10.0)

    def testOneToolRunTwiceIsNotAmbiguous(self):
        # Re-running supersedes: that IS an ordering, so the newest wins without
        # anyone having to say so.
        self.scored('pep', recovery=1.0)
        self.scored('pep', recovery=2.0)
        self.assertEqual(cmd.metrics_get(object='pep', key='recovery')['value'], 2.0)

    def testAKeyOnlyOneToolHasNeedsNoDisambiguation(self):
        # `recovery` is this tool's alone, so the other tool's run is not a candidate
        # and nothing has to be named.
        name, index, mine, theirs = self.both()
        self.assertEqual(cmd.metrics_get(object=name, key='recovery')['value'], 42.0)

    def testAnUnknownToolSaysSoRatherThanFallingBack(self):
        name, index, mine, theirs = self.both()
        self.assertRaises(MetricNotFound, cmd.metrics_get,
                          object=name, key='conf', tool='nosuchtool')


class ManyModelsInOneObjectTest(MetricCommandTestCase):
    """`n_models=N` lands N independent runs as N states of one object (#308).

    The case the scope model exists for, and the one where answering with the last
    model's numbers for a question about the object misreports an ensemble.
    """

    def ensemble(self, means=(71.0, 84.0, 62.0)):
        cmd.fab('ACDEF', 'pred', chain='A')
        for extra in range(2, len(means) + 1):
            cmd.create('pred', 'pred', 1, extra)
        index = sorted(binding.residue_index('pred'))
        runs = []
        for state, mean in enumerate(means, start=1):
            runs.append(binding.record('pred', TOOL, [
                store.value(TOOL, 'recovery', value=5.0),
                store.value(TOOL, 'score', value=mean, state=state),
                store.value(TOOL, 'conf', state=state, index=index,
                            values=[mean] * len(index)),
            ], inputs={'seed': 100 + state}))
        return 'pred', index, runs

    def testOneRunPerModel(self):
        name, index, runs = self.ensemble()
        self.assertEqual(cmd.count_states(name), 3)
        self.assertEqual([r.states for r in store.runs(object=name)],
                         [(1,), (2,), (3,)])

    def testAskingWithoutAStateIsRefusedNotAnsweredWithTheLastModel(self):
        name, index, runs = self.ensemble()
        try:
            cmd.metrics_get(object=name, key='score')
        except MetricAmbiguous as exc:
            self.assertIn('1, 2, 3', str(exc))
        else:
            self.fail('three models must not resolve to the newest silently')

    def testStateSelectsTheModel(self):
        # The regression: `state` used to be applied INSIDE an already-chosen run, so
        # the newest run (model 3) was picked and then had nothing for state 2.
        name, index, runs = self.ensemble()
        for state, expected in ((1, 71.0), (2, 84.0), (3, 62.0)):
            self.assertEqual(
                cmd.metrics_get(object=name, key='score', state=state)['value'],
                expected)

    def testColorTakesTheModelAsked(self):
        name, index, runs = self.ensemble()
        cmd.metrics_color('conf', object=name, state=2)
        painted = []
        cmd.iterate('%s and name CA' % name, 'painted.append(b)',
                    space={'painted': painted})
        self.assertEqual(set(painted), {84.0})

    def testARunIdIsAlwaysUnambiguous(self):
        name, index, runs = self.ensemble()
        self.assertEqual(cmd.metrics_get(runs[0].id, 'score')['value'], 71.0)

    def testAnObjectScopeKeyIsNotAmbiguousAcrossModels(self):
        # `recovery` is a property of the sequence: every model's run carries the same
        # value and none of them carries a state, so there is nothing to disambiguate.
        name, index, runs = self.ensemble()
        self.assertEqual(cmd.metrics_get(object=name, key='recovery')['value'], 5.0)

    def testAStateNothingMeasuredSaysWhatWasMeasured(self):
        name, index, runs = self.ensemble()
        try:
            cmd.metrics_get(object=name, key='score', state=9)
        except MetricNotFound as exc:
            self.assertIn('1, 2, 3', str(exc))
        else:
            self.fail('an unmeasured state must be refused')

    def testOneRunCoveringSeveralStatesIsNotAmbiguous(self):
        # A tool that scores every model in one pass: one run, several states. There is
        # no choice BETWEEN runs to make, so nothing is refused.
        cmd.fab('ACDEF', 'multi', chain='A')
        cmd.create('multi', 'multi', 1, 2)
        run = binding.record('multi', TOOL, [
            store.value(TOOL, 'score', value=1.0, state=1),
            store.value(TOOL, 'score', value=2.0, state=2)])
        self.assertEqual(cmd.metrics_get(object='multi', key='score', state=2)['value'],
                         2.0)
        both = cmd.metrics_get(run.id, 'score')
        self.assertEqual([entry['value'] for entry in both], [1.0, 2.0])

    def testRerunningOneModelStillSupersedes(self):
        # Two runs describing the SAME state are versions of one measurement, so the
        # newest wins without anyone having to say so.
        name, index, runs = self.ensemble(means=(71.0,))
        binding.record(name, TOOL, [
            store.value(TOOL, 'score', value=99.0, state=1)])
        self.assertEqual(cmd.metrics_get(object=name, key='score')['value'], 99.0)


class ColorTest(MetricCommandTestCase):

    def bfactors(self, name):
        out = []
        cmd.iterate('%s and name CA' % name, 'out.append(b)', space={'out': out})
        return out

    def testColorWritesTheStoredArrayIntoB(self):
        name, index, run = self.scored()
        cmd.alter(name, 'b = 0.0')
        self.assertEqual(cmd.metrics_color('conf', object=name), len(index))
        self.assertEqual(sorted(self.bfactors(name)),
                         sorted([10.0 * (i + 1) for i in range(len(index))]))

    def testColorIsRepeatableAfterAnotherToolOverwritesB(self):
        # The bug this closes: a design pass used to overwrite a prediction's pLDDT in
        # the B-factor column with nothing saying the column had changed meaning.
        name, index, run = self.scored()
        cmd.metrics_color('conf', object=name)
        cmd.alter(name, 'b = -1.0')             # another tool colours over it
        cmd.metrics_color('conf', object=name)
        self.assertNotIn(-1.0, self.bfactors(name))

    def testUnmeasuredResiduesKeepTheirBFactor(self):
        name, index, run = self.scored(conf=[None, 20.0, None, 40.0, None])
        cmd.alter(name, 'b = -7.0')
        self.assertEqual(cmd.metrics_color('conf', object=name), 2)
        self.assertEqual(sorted(self.bfactors(name)), [-7.0, -7.0, -7.0, 20.0, 40.0])

    def testColoringByAScalarIsRefused(self):
        name, index, run = self.scored()
        self.assertRaises(MetricScopeError, cmd.metrics_color, 'recovery',
                          object=name)


class ExportLoadTest(MetricCommandTestCase):

    def testJsonRoundTripsThroughLoad(self):
        name, index, run = self.scored()
        path = self.tmpfile('.json')
        cmd.metrics_export(path, object=name)
        cmd.metrics_delete('all')
        # A document carries the schema, so it loads into a build that never had the
        # tool -- which is the ordinary case for anything sent to a collaborator.
        schema.forget(TOOL)
        loaded = cmd.metrics_load(path)
        back = store.get(loaded)
        self.assertEqual(back.scalars()['recovery'], 42.0)
        self.assertEqual([tuple(p) for p in back.one('conf', state=1).index], index)

    def testCsvIsLongFormatAndCoversEveryScope(self):
        name, index, run = self.scored()
        path = self.tmpfile('.csv')
        cmd.metrics_export(path, object=name)
        with open(path) as handle:
            rows = [line.rstrip('\n').split(',') for line in handle]
        header, body = rows[0], rows[1:]
        self.assertEqual(header[0], 'run')
        self.assertEqual(header[-1], 'value')
        keys = [row[3] for row in body]
        self.assertIn('recovery', keys)
        self.assertIn('score', keys)
        self.assertEqual(keys.count('conf'), len(index))

    def testLoadChecksTheDocumentAgainstTheObject(self):
        cmd.fab('ACDEF', 'pep', chain='A')
        path = self.tmpfile('.json')
        with open(path, 'w') as handle:
            json.dump({'tool': 'outside', 'object': 'pep',
                       'schema': [{'key': 'q', 'scope': 'residue'}],
                       'values': [{'key': 'q', 'state': 1,
                                   'index': [['Z', '99']], 'values': [1.0]}]}, handle)
        self.addCleanup(schema.forget, 'outside')
        self.assertRaises(MetricScopeError, cmd.metrics_load, path)

    def testLoadRefusesAnUnknownToolWithNoSchema(self):
        cmd.fab('ACDEF', 'pep', chain='A')
        path = self.tmpfile('.json')
        with open(path, 'w') as handle:
            json.dump({'tool': 'mystery', 'object': 'pep',
                       'values': [{'key': 'q', 'value': 1.0}]}, handle)
        self.assertRaises(Exception, cmd.metrics_load, path)
