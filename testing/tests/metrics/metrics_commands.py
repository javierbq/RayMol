"""The cmd.metrics_* surface: listing, reading, colouring, export and load (#308).

    pymol -ckqy testing/testing.py --run testing/tests/metrics/metrics_commands.py
"""
import json
import os
import tempfile

from pymol import cmd, testing
from pymol.metrics import binding, schema, store
from pymol.metrics.errors import MetricNotFound, MetricScopeError

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
