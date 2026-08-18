"""A design pass keeps its scores instead of only painting them (#308).

MPNN's per-residue score was a colour and nothing else: written to `p.mpnn_conf` where
this fork's atom properties are available, and to the B-factor column where they are not
(stock open-source PyMOL). Neither is a record. A property carries no run, no units and
no provenance and does not survive a .pse; `b` is one unlabelled scalar per atom that the
next thing to colour by it displaces -- and on the fallback build that next thing landed
on a prediction's pLDDT.

Which column is used is build-dependent, so the tests below probe for it rather than
assuming, and assert the part that holds either way: the numbers are in the store.

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

    def bfactors(self):
        out = []
        cmd.iterate('design_obj and name CA', 'out.append(b)', space={'out': out})
        return sorted(out)

    def properties_supported(self):
        """True where `p.*` atom properties work, which decides who owns `b`.

        THIS FORK IMPLEMENTS THEM -- `layer1/Property.cpp` is a real implementation and
        nothing gates it -- so `apply_design_coloring` writes `p.mpnn_conf` and never
        touches the B-factor column. Stock open-source PyMOL raises
        IncentiveOnlyException instead, and there the design score falls back to `b`,
        on top of whatever a prediction left in it.

        Probed rather than assumed, because these tests run under both: the fork's own
        build in CI and the app, and a plain `pymol` locally.
        """
        try:
            cmd.alter('design_obj and index 1', 'p.raymol_probe = 1.0')
            return True
        except Exception:
            return False

    def testAPredictionsConfidenceSurvivesADesignPass(self):
        # pLDDT is recorded, a design pass runs over the same object, and the confidence
        # is still readable afterwards because the store holds it -- whichever column
        # the design score went into.
        from pymol.predictors import registry
        registry.get('boltz2')
        plddt = [90.0, 85.0, 80.0, 75.0, 70.0]
        prediction = binding.record('design_obj', 'boltz2', [
            store.value('boltz2', 'plddt', state=1, index=self.index, values=plddt)])
        cmd.metrics_color('plddt', run=prediction.id)
        self.assertEqual(self.bfactors(), sorted(plddt))

        properties = self.properties_supported()
        self.color([-1.0, -2.0, -3.0, -4.0, -5.0])

        if properties:
            # What RayMol itself does: the design score goes to p.mpnn_conf, so the two
            # metrics occupy different columns and neither is destroyed. The store is
            # what makes them READABLE and exportable -- p.mpnn_conf carries no run, no
            # units, no provenance, and does not survive a .pse.
            self.assertEqual(self.bfactors(), sorted(plddt),
                             'with p.* available the design pass must not touch b')
        else:
            # The fallback build: one unlabelled scalar per atom, so the design score
            # lands on top of the confidence with nothing saying the column changed
            # meaning. Without the store there is no way back from here.
            self.assertEqual(self.bfactors(), [-5.0, -4.0, -3.0, -2.0, -1.0],
                             'without p.* the design score falls back to b')

        # Build-independent, and the actual point: both runs are in the store, and the
        # confidence can be re-applied whenever it is wanted.
        self.assertEqual(len(store.runs(object='design_obj')), 2)
        cmd.metrics_color('plddt', run=prediction.id)
        self.assertEqual(self.bfactors(), sorted(plddt))
