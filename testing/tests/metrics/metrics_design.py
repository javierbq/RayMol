"""A design pass keeps its scores instead of only painting them (#308).

The collision this closes is concrete: on an open-source build MPNN's per-residue score
falls back to the B-factor column, which is where a prediction's pLDDT already lives.
Colouring a predicted object by design score used to overwrite it, with nothing in the
session saying the column had changed meaning.

    pymol -ckqy testing/testing.py --run testing/tests/metrics/metrics_design.py
"""
import json
import os
import tempfile

from pymol import cmd, raymol_design, testing
from pymol.metrics import binding, schema, store


class DesignMetricTest(testing.PyMOLTestCase):

    def setUp(self):
        testing.PyMOLTestCase.setUp(self)
        cmd.fab('ACDEF', 'design_obj', chain='A')
        self.index = sorted(binding.residue_index('design_obj'))

    def tearDown(self):
        store.clear()
        testing.PyMOLTestCase.tearDown(self)

    def values_file(self, values):
        handle, path = tempfile.mkstemp(suffix='.json')
        os.close(handle)
        self.addCleanup(lambda: os.path.exists(path) and os.unlink(path))
        rows = [{'chain': chain, 'resi': resi, 'value': value}
                for (chain, resi), value in zip(self.index, values)]
        with open(path, 'w') as stream:
            json.dump(rows, stream)
        return path

    def color(self, values, metric='native_fit'):
        path = self.values_file(values)
        raymol_design.apply_design_coloring('design_obj', path, 'red_white_blue',
                                            -6.0, 0.0, metric, 1)
        return store.runs(object='design_obj')

    def testScoresAreRecordedNotJustPainted(self):
        runs = self.color([-1.0, -2.0, -3.0, -4.0, -5.0])
        self.assertEqual(len(runs), 1)
        entry = runs[0].one('native_fit', state=1)
        self.assertEqual(runs[0].tool, 'mpnn')
        self.assertEqual([tuple(p) for p in entry.index], self.index)
        self.assertEqual(entry.values, [-1.0, -2.0, -3.0, -4.0, -5.0])

    def testMaskedResiduesStayAbsent(self):
        # A residue with no backbone was not scored. Recording it as 0.0 would be a
        # perfect native fit rather than no measurement.
        runs = self.color([-1.0, None, -3.0, None, -5.0])
        entry = runs[0].one('native_fit', state=1)
        self.assertEqual(entry.values, [-1.0, None, -3.0, None, -5.0])
        self.assertEqual(len(entry.as_map()), 3)
        self.assertEqual(runs[0].inputs['n_scored'], 3)

    def testEachScoringPassIsItsOwnRun(self):
        self.color([-1.0] * 5)
        runs = self.color([-2.0] * 5)
        self.assertEqual(len(runs), 2)
        self.assertEqual(runs[0].one('native_fit', state=1).values[0], -1.0)
        self.assertEqual(runs[1].one('native_fit', state=1).values[0], -2.0)

    def testCertaintyAndNativeFitAreDifferentKeys(self):
        self.color([-1.0] * 5, metric='native_fit')
        runs = self.color([0.5] * 5, metric='certainty')
        self.assertEqual(runs[1].keys(), ['certainty'])
        self.assertEqual(schema.spec('mpnn', 'certainty').hi, 1.0)

    def testAnUnnamedMetricIsNotRecordedUnderAGuessedKey(self):
        # An older caller that does not say which score it is passing. Guessing would
        # file native-fit numbers in a certainty column.
        self.assertEqual(self.color([-1.0] * 5, metric=''), [])

    def testAPredictionsConfidenceSurvivesADesignPass(self):
        # The whole point. pLDDT is recorded, the design pass overwrites the B-factor
        # column, and the confidence can be put back because the store still has it.
        from pymol.predictors import registry
        registry.get('boltz2')
        plddt = [90.0, 85.0, 80.0, 75.0, 70.0]
        prediction = binding.record('design_obj', 'boltz2', [
            store.value('boltz2', 'plddt', state=1, index=self.index, values=plddt)])
        cmd.metrics_color('plddt', run=prediction.id)

        self.color([-1.0, -2.0, -3.0, -4.0, -5.0])
        painted = []
        cmd.iterate('design_obj and name CA', 'painted.append(b)',
                    space={'painted': painted})
        self.assertEqual(sorted(painted), [-5.0, -4.0, -3.0, -2.0, -1.0],
                         'the design pass owns the B-factor column while it colours')

        cmd.metrics_color('plddt', run=prediction.id)
        restored = []
        cmd.iterate('design_obj and name CA', 'restored.append(b)',
                    space={'restored': restored})
        self.assertEqual(sorted(restored), sorted(plddt))
