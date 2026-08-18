"""What a tool is allowed to declare, and what a declaration buys (#308).

    pymol -ckqy testing/testing.py --run testing/tests/metrics/metrics_schema.py
"""
from pymol import testing
from pymol.metrics import schema
from pymol.metrics.errors import MetricInputError, MetricSchemaError


class SchemaTestCase(testing.PyMOLTestCase):

    def setUp(self):
        testing.PyMOLTestCase.setUp(self)
        self._saved = dict(schema._SCHEMAS)

    def tearDown(self):
        schema._SCHEMAS.clear()
        schema._SCHEMAS.update(self._saved)
        testing.PyMOLTestCase.tearDown(self)


class SpecTest(SchemaTestCase):

    def testUnknownScopeRefused(self):
        self.assertRaises(MetricSchemaError, schema.MetricSpec, 'k', 'per_atom')

    def testUnknownDtypeRefused(self):
        self.assertRaises(MetricSchemaError, schema.MetricSpec, 'k',
                          schema.STATE, 'complex')

    def testStringArrayRefused(self):
        # An array of strings is a label track; nothing that consumes an array here --
        # spectrum colouring, numeric export -- has any use for one.
        self.assertRaises(MetricSchemaError, schema.MetricSpec, 'k',
                          schema.RESIDUE, 'str')

    def testInvertedRangeRefused(self):
        self.assertRaises(MetricSchemaError, schema.MetricSpec, 'k',
                          schema.STATE, 'float', '', '', 10, 0)

    def testUnknownSummaryRuleRefused(self):
        self.assertRaises(MetricSchemaError, schema.MetricSpec, 'k', schema.RESIDUE,
                          summarizes='harmonic_mean')

    def testCastKeepsNoneAsNone(self):
        # Absent is not zero. A masked residue has no score, and a single-chain fold
        # has no interface score; both must survive as absent.
        spec = schema.MetricSpec('k', schema.RESIDUE)
        self.assertIsNone(spec.cast(None))

    def testCastDropsNaNAndInfinity(self):
        # How a runtime says "this did not compute". Neither survives JSON, and both
        # poison a spectrum, so they become the absence they already are.
        spec = schema.MetricSpec('k', schema.STATE)
        self.assertIsNone(spec.cast(float('nan')))
        self.assertIsNone(spec.cast(float('inf')))

    def testCastRejectsNonsense(self):
        spec = schema.MetricSpec('k', schema.STATE)
        self.assertRaises(MetricInputError, spec.cast, 'not a number')

    def testCastAppliesDtype(self):
        self.assertEqual(schema.MetricSpec('k', schema.STATE, 'int').cast('7'), 7)
        self.assertEqual(schema.MetricSpec('k', schema.STATE, 'bool').cast(1), True)
        self.assertEqual(schema.MetricSpec('k', schema.OBJECT, 'str').cast(3), '3')


class RegistryTest(SchemaTestCase):

    def declare(self, tool='t'):
        return schema.register(tool, [
            schema.MetricSpec('score', schema.STATE, lo=0, hi=1),
            dict(key='conf', scope=schema.RESIDUE, lo=0, hi=100),
        ])

    def testRegisterAcceptsSpecsAndDicts(self):
        table = self.declare()
        self.assertEqual(sorted(table), ['conf', 'score'])
        self.assertEqual(schema.spec('t', 'conf').scope, schema.RESIDUE)

    def testRedeclaringIsAnErrorUnlessAsked(self):
        self.declare()
        self.assertRaises(MetricSchemaError, self.declare)
        schema.register('t', [schema.MetricSpec('other', schema.OBJECT)],
                        replace=True)
        self.assertEqual(schema.tools().count('t'), 1)

    def testDuplicateKeyInOneDeclarationRefused(self):
        self.assertRaises(MetricSchemaError, schema.register, 't2', [
            schema.MetricSpec('score', schema.STATE),
            schema.MetricSpec('score', schema.OBJECT)])

    def testUnknownKeyNamesWhatTheToolDoesDeclare(self):
        self.declare()
        try:
            schema.spec('t', 'plddt')
        except MetricSchemaError as exc:
            self.assertIn('conf', str(exc))
            self.assertIn('score', str(exc))
        else:
            self.fail('an undeclared key must be refused')

    def testUnknownToolNamesTheKnownOnes(self):
        self.declare('known')
        try:
            schema.spec('nope', 'score')
        except MetricSchemaError as exc:
            self.assertIn('known', str(exc))
        else:
            self.fail('an unknown tool must be refused')


class ShippedSchemaTest(testing.PyMOLTestCase):
    """The predictors ship declarations, and the capability claim has to be honest."""

    def testPredictorsDeclareTheirMetrics(self):
        from pymol.predictors import registry
        registry.get('boltz2')          # force the built-in registration to run
        self.assertIn('plddt', [s.key for s in schema.specs('boltz2')])
        self.assertEqual(schema.spec('boltz2', 'plddt').scope, schema.RESIDUE)
        self.assertEqual(schema.spec('boltz2', 'pae').scope, schema.PAIR)
        # Both ipSAE variants are declared, because they are not interchangeable.
        self.assertEqual(schema.spec('boltz2', 'ipsae').scope, schema.STATE)
        self.assertEqual(schema.spec('boltz2', 'min_ipsae').scope, schema.STATE)
        self.assertEqual(schema.spec('boltz2', 'mean_pae').units, 'A')
        self.assertEqual(schema.spec('boltz2', 'mean_plddt').scope, schema.STATE)
        self.assertEqual(schema.spec('boltz2', 'msa_depth').scope, schema.CHAIN)

    def testMethodWithoutAConfidenceHeadDeclaresNoConfidence(self):
        # The capability contract: a caller that finds `plddt` in the schema is
        # entitled to conclude the tool can produce it, so a method without a
        # confidence module declares the shared input and cost sets and nothing more.
        #
        # Against a STUB rather than a shipped predictor: which methods lack a
        # confidence head changes as methods are added, and a test that named one
        # would be asserting a fact about that method rather than about the contract.
        from pymol.predictors import metrics as predictor_metrics
        schema.register('unscored-stub', predictor_metrics.UNSCORED_SPECS,
                        replace=True)
        keys = [spec.key for spec in schema.specs('unscored-stub')]
        self.assertNotIn('plddt', keys)
        self.assertNotIn('pae', keys)
        self.assertNotIn('min_ipsae', keys)
        self.assertIn('elapsed_s', keys)
        self.assertIn('n_residues', keys)

    def testDesignDeclaresItsMetrics(self):
        from pymol import raymol_design    # noqa: F401  (registers at import)
        self.assertEqual(schema.spec('mpnn', 'native_fit').scope, schema.RESIDUE)
        self.assertEqual(schema.spec('mpnn', 'certainty').hi, 1.0)
