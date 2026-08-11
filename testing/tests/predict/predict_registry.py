"""Tests for pymol.predictors.registry.

    pymol -ckqy testing/testing.py --run testing/tests/predict/predict_registry.py
"""
from pymol import testing


def make_stub(predictor_id, name='Stub'):
    from pymol.predictors.base import Predictor, PredictionSpec, parse_chains

    # Aliased because a class body cannot read an enclosing function's `name`
    # while also binding `name` itself: the class body's own binding wins and
    # `name = name` raises NameError.
    stub_name = name

    class Stub(Predictor):
        id = predictor_id
        name = stub_name

        def check_available(self):
            return None

        def parse_spec(self, sequence, name=''):
            return PredictionSpec(parse_chains(sequence), name)

        def submit(self, spec, options, weights_path):
            return 'job-%s' % self.id

    return Stub()


class TestRegistry(testing.PyMOLTestCase):

    def setUp(self):
        testing.PyMOLTestCase.setUp(self)
        from pymol.predictors import registry
        self._saved = dict(registry._REGISTRY)

    def tearDown(self):
        from pymol.predictors import registry
        registry._REGISTRY.clear()
        registry._REGISTRY.update(self._saved)
        testing.PyMOLTestCase.tearDown(self)

    def testRegisterThenGet(self):
        from pymol.predictors import registry
        stub = make_stub('stub-a')
        registry.register(stub)
        self.assertIs(registry.get('stub-a'), stub)

    def testUnknownNameRaises(self):
        from pymol.predictors import registry
        from pymol.predictors.errors import PredictorNotFound
        self.assertRaises(PredictorNotFound, registry.get, 'nope')

    def testUnknownNameErrorListsWhatIsAvailable(self):
        from pymol.predictors import registry
        from pymol.predictors.errors import PredictorNotFound
        registry.register(make_stub('stub-a'))
        try:
            registry.get('nope')
        except PredictorNotFound as exc:
            self.assertIn('stub-a', str(exc))
        else:
            self.fail('expected PredictorNotFound')

    def testDuplicateIdRejectedUnlessReplacing(self):
        from pymol.predictors import registry
        from pymol.predictors.errors import PredictionError
        registry.register(make_stub('stub-a'))
        self.assertRaises(PredictionError, registry.register, make_stub('stub-a'))

    def testSwapImplementationsBehindTheInterface(self):
        from pymol.predictors import registry
        first, second = make_stub('swap'), make_stub('swap', name='Other')
        registry.register(first)
        registry.register(second, replace=True)
        self.assertIs(registry.get('swap'), second)
        # The caller's contract is unchanged across the swap.
        self.assertEqual(registry.get('swap').submit(None, None, None), 'job-swap')

    def testAvailableIsSorted(self):
        from pymol.predictors import registry
        registry._REGISTRY.clear()
        registry.register(make_stub('zeta'))
        registry.register(make_stub('alpha'))
        self.assertEqual(registry.available(), ['alpha', 'zeta'])

    def testRegisterRejectsNonPredictor(self):
        from pymol.predictors import registry
        from pymol.predictors.errors import PredictionError
        self.assertRaises(PredictionError, registry.register, object())

    def testRegisterRejectsMissingId(self):
        from pymol.predictors import registry
        from pymol.predictors.errors import PredictionError
        stub = make_stub(None)
        self.assertRaises(PredictionError, registry.register, stub)
