"""Scale targets from spec §8, asserted loosely (3x) so a slow CI does not fail them (#415).

    pymol -ckqy testing/testing.py --run testing/tests/sets/sets_perf.py
"""
import os
import tempfile
import time

from pymol import cmd, testing
from pymol.sets import filter as sfilter, selectors, store

# 20k rather than the spec's 100k so the suite stays under ~3 s; the assertions are
# proportionally loose, which makes this a smoke test of the scaling shape, not a gate.
N = 20000


class SetPerfTestCase(testing.PyMOLTestCase):

    def setUp(self):
        testing.PyMOLTestCase.setUp(self)
        store.reset()

    def tearDown(self):
        store.reset()
        testing.PyMOLTestCase.tearDown(self)

    def testFilterAndOpenAtScale(self):
        c = store.active()
        row = c.create_set('big', ranking_key='plddt')
        specs = [{'key': 'plddt', 'scope': 'object', 'dtype': 'float', 'tool': 'perf'},
                 {'key': 'rmsd', 'scope': 'object', 'dtype': 'float', 'tool': 'perf'}]
        c.declare_columns(row['id'], specs)
        t0 = time.time()
        for i in range(N):
            c.add_entry(row['id'], 'e%05d' % i, sequences={'A': 'ACDEFG'},
                        scalars={'plddt': (i * 7919) % 100, 'rmsd': (i % 13) / 4.0})
        add_s = time.time() - t0
        row = c.get_set('big')

        t0 = time.time()
        n = selectors.count_filtered(c, row, expr='plddt > 80 and rmsd < 1.5')
        rows = selectors.filtered(c, dict(row, sort_key='plddt', sort_desc=1),
                                  expr='plddt > 80 and rmsd < 1.5', limit=50)
        filter_s = time.time() - t0
        self.assertGreater(n, 0)
        self.assertEqual(len(rows), 50)

        path = os.path.join(tempfile.mkdtemp(), 'big.raymol')
        c.write_session(b'x')
        moved = c.save_into(path)
        moved.close()
        t0 = time.time()
        reopened = store.Container(path)
        sets = reopened.sets()
        open_s = time.time() - t0
        reopened.close()
        self.assertEqual(sets[0]['name'], 'big')

        print(' sets_perf: add %d entries %.2fs, filter+top50 %.3fs, open %.3fs'
              % (N, add_s, filter_s, open_s))
        self.assertLess(filter_s, 0.3, 'spec target 100 ms, 3x margin')
        self.assertLess(open_s, 0.6, 'spec target 200 ms, 3x margin')
        self.assertLess(add_s / N, 0.003, 'more than 3 ms per sequence entry')
