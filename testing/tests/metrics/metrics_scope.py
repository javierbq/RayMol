"""Scope enforcement -- the reason this package exists (#308).

A number written at the wrong scope reads perfectly and describes something else, so
every one of these refusals is the point rather than a guard rail.

    pymol -ckqy testing/testing.py --run testing/tests/metrics/metrics_scope.py
"""
from pymol import cmd, testing
from pymol.metrics import binding, schema, store
from pymol.metrics.errors import MetricScopeError

TOOL = 'scopetest'


class ScopeTestCase(testing.PyMOLTestCase):

    def setUp(self):
        testing.PyMOLTestCase.setUp(self)
        self._saved = dict(schema._SCHEMAS)
        schema.register(TOOL, [
            schema.MetricSpec('recovery', schema.OBJECT, lo=0, hi=100),
            schema.MetricSpec('energy', schema.STATE),
            schema.MetricSpec('identity', schema.CHAIN),
            schema.MetricSpec('conf', schema.RESIDUE, lo=0, hi=100),
            schema.MetricSpec('error', schema.PAIR),
        ], replace=True)

    def tearDown(self):
        store.clear()
        schema._SCHEMAS.clear()
        schema._SCHEMAS.update(self._saved)
        testing.PyMOLTestCase.tearDown(self)

    def peptide(self, name='pep', sequence='ACDEF'):
        cmd.fab(sequence, name, chain='A')
        return name, sorted(binding.residue_index(name))


class ValueScopeTest(ScopeTestCase):
    """Refusals that need no session: the value is wrong on its own terms."""

    def testObjectScopeRefusesAState(self):
        # The likeliest reading of "object-scope, but on state 3" is "this is really
        # per-model", which is exactly what makes n_models wrong.
        self.assertRaises(MetricScopeError, store.value, TOOL, 'recovery',
                          value=50, state=3)

    def testStateScopeNeedsAState(self):
        self.assertRaises(MetricScopeError, store.value, TOOL, 'energy', value=1.0)

    def testChainScopeNeedsAChain(self):
        self.assertRaises(MetricScopeError, store.value, TOOL, 'identity', value=0.9)

    def testScalarScopeRefusesAnArray(self):
        self.assertRaises(MetricScopeError, store.value, TOOL, 'energy',
                          state=1, index=[('A', '1')], values=[1.0])

    def testArrayScopeRefusesAScalar(self):
        self.assertRaises(MetricScopeError, store.value, TOOL, 'conf',
                          state=1, value=88.0)

    def testResidueArrayLengthMustMatchItsIndex(self):
        self.assertRaises(MetricScopeError, store.value, TOOL, 'conf', state=1,
                          index=[('A', '1'), ('A', '2')], values=[1.0])

    def testPairArrayIsTheIndexSquared(self):
        index = [('A', '1'), ('A', '2')]
        self.assertRaises(MetricScopeError, store.value, TOOL, 'error', state=1,
                          index=index, values=[1.0, 2.0])
        entry = store.value(TOOL, 'error', state=1, index=index,
                            values=[1.0, 2.0, 3.0, 4.0])
        self.assertEqual(len(entry.values), 4)

    def testEmptyIndexRefused(self):
        self.assertRaises(Exception, store.value, TOOL, 'conf', state=1,
                          index=[], values=[])

    def testAbsentValuesSurviveInAnArray(self):
        # A masked residue is not a zero. Recording it as one would put a real-looking
        # measurement where there is none.
        entry = store.value(TOOL, 'conf', state=1,
                            index=[('A', '1'), ('A', '2')], values=[None, 42.0])
        self.assertEqual(entry.values, [None, 42.0])
        self.assertEqual(entry.as_map(), {('A', '2'): 42.0})


class SessionScopeTest(ScopeTestCase):
    """Refusals that need the object: the value does not fit what it claims."""

    def testStateMustExist(self):
        name, index = self.peptide()
        value = store.value(TOOL, 'energy', value=1.0, state=4)
        self.assertRaises(MetricScopeError, binding.record, name, TOOL, [value])

    def testChainMustExist(self):
        name, index = self.peptide()
        value = store.value(TOOL, 'identity', value=0.5, chain='Q')
        self.assertRaises(MetricScopeError, binding.record, name, TOOL, [value])

    def testArrayIndexMustBeResiduesTheObjectHas(self):
        name, index = self.peptide()
        value = store.value(TOOL, 'conf', state=1,
                            index=[('A', '1'), ('Z', '99')], values=[1.0, 2.0])
        try:
            binding.record(name, TOOL, [value])
        except MetricScopeError as exc:
            self.assertIn('Z/99', str(exc))
        else:
            self.fail('an array indexed off the object must be refused')

    def testUnknownObjectRefused(self):
        value = store.value(TOOL, 'recovery', value=1.0)
        self.assertRaises(MetricScopeError, binding.record, 'nosuch', TOOL, [value])

    def testARecordThatFitsIsKept(self):
        name, index = self.peptide()
        run = binding.record(name, TOOL, [
            store.value(TOOL, 'recovery', value=42.0),
            store.value(TOOL, 'energy', value=-3.5, state=1),
            store.value(TOOL, 'identity', value=1.0, chain='A'),
            store.value(TOOL, 'conf', state=1, index=index,
                        values=[50.0] * len(index)),
        ], inputs={'seed': 1})
        self.assertEqual(run.object, name)
        self.assertEqual(run.states, (1,))
        self.assertEqual(run.scalars()['recovery'], 42.0)
        # Chain-scope scalars are keyed by chain so two chains can coexist in one row.
        self.assertEqual(run.scalars()['identity/A'], 1.0)
        self.assertEqual(len(run.one('conf', state=1).values), len(index))

    def testManyRunsPerObjectAndNoneReplacesAnother(self):
        name, index = self.peptide()
        first = binding.record(name, TOOL, [store.value(TOOL, 'recovery', value=1.0)])
        second = binding.record(name, TOOL, [store.value(TOOL, 'recovery', value=2.0)])
        self.assertNotEqual(first.id, second.id)
        self.assertEqual([r.id for r in store.runs(object=name)],
                         [first.id, second.id])


class StalenessTest(ScopeTestCase):

    def testStateCountChangeIsReported(self):
        # States are positional. Adding or removing one re-points every state-scope
        # value in every run on the object, and the numbers still look right.
        name, index = self.peptide()
        cmd.create(name, name, 1, 2)          # a second state
        run = binding.record(name, TOOL, [
            store.value(TOOL, 'energy', value=1.0, state=2)])
        self.assertEqual(binding.stale_reason(run), '')
        cmd.create(name, name, 1, 3)          # a third, after the fact
        self.assertIn('state', binding.stale_reason(run))
        self.assertTrue(binding.is_stale(run))

    def testDeletedObjectIsReported(self):
        name, index = self.peptide()
        run = binding.record(name, TOOL, [store.value(TOOL, 'recovery', value=1.0)])
        cmd.delete(name)
        # The delete hook drops the run outright; a run that outlived its object at all
        # would still have to say so.
        self.assertFalse(store.have(run.id))
