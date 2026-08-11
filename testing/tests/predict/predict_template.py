"""The predictor template must stay importable and unregistered.

    pymol -ckqy testing/testing.py --run testing/tests/predict/predict_template.py
"""
from pymol import testing


class TestTemplate(testing.PyMOLTestCase):

    def testTemplateImportsCleanly(self):
        from pymol.predictors import _template
        self.assertTrue(hasattr(_template, 'PREDICTOR'))

    def testTemplateIsNotRegistered(self):
        from pymol.predictors import _template, registry
        self.assertNotIn(_template.TemplatePredictor.id, registry.available())

    def testTemplateSubclassesPredictorAndRefusesToRun(self):
        from pymol.predictors import _template
        from pymol.predictors.base import Predictor
        from pymol.predictors.errors import (PredictionInputError,
                                             PredictorUnavailable)
        self.assertTrue(isinstance(_template.PREDICTOR, Predictor))
        self.assertRaises(PredictorUnavailable, _template.PREDICTOR.check_available)
        self.assertRaises(PredictionInputError, _template.PREDICTOR.parse_spec, 'AA')

    def testTemplateRejectsUnknownOptions(self):
        from pymol.predictors import _template
        from pymol.predictors.errors import PredictionOptionError
        self.assertRaises(PredictionOptionError,
                          _template.PREDICTOR.validate_options,
                          {'diffusion_samples': 4})

    def testTemplateAcceptsTheDocumentedOptions(self):
        from pymol.predictors import _template
        options = _template.PREDICTOR.validate_options({'diffusion_steps': 300})
        self.assertEqual(options.diffusion_steps, 300)
        self.assertEqual(options.recycling_steps, 3)
