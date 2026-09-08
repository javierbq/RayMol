"""Folder / FASTA import and folder / CSV / FASTA export round trips (#415).

    pymol -ckqy testing/testing.py --run testing/tests/sets/sets_document.py
"""
import csv
import os
import shutil
import tempfile

from pymol import cmd, testing
from pymol.metrics import binding as mbinding, schema as mschema, store as mstore
from pymol.sets import document, store
from pymol.sets.errors import SetInputError, SetNotFound

TOOL = 'doctest'


class SetDocumentTestCase(testing.PyMOLTestCase):

    def setUp(self):
        testing.PyMOLTestCase.setUp(self)
        self._saved = dict(mschema._SCHEMAS)
        mschema.register(TOOL, [
            mschema.MetricSpec('score', mschema.OBJECT, lo=0, hi=100),
            mschema.MetricSpec('label', mschema.OBJECT, dtype='str'),
        ], replace=True)
        store.reset()
        self._dir = tempfile.mkdtemp()

    def tearDown(self):
        store.reset()
        mstore.clear()
        mschema._SCHEMAS.clear()
        mschema._SCHEMAS.update(self._saved)
        shutil.rmtree(self._dir, ignore_errors=True)
        testing.PyMOLTestCase.tearDown(self)

    def path(self, *parts):
        return os.path.join(self._dir, *parts)

    def populated(self):
        cmd.set_create('s')
        for i, seq in enumerate(['ACD', 'EFG', 'HIK']):
            cmd.fab(seq, 'd%d' % i, chain='A')
            mbinding.record('d%d' % i, TOOL, [mstore.value(TOOL, 'score', value=1.5 * i),
                                             mstore.value(TOOL, 'label', value='L%d' % i)])
            cmd.set_add('s', 'd%d' % i)
            cmd.delete('d%d' % i)
        mstore.clear()
        cmd.set_star('s', 'd1')
        cmd.set_tag('s', 'd1', 'keep')
        cmd.set_set('s', 'd2', 'note', 'a note')
        c = store.active()
        c.update_entry(c.entry(c.get_set('s')['id'], 'd2')['id'], parents=['abc123'])


class Helpers(SetDocumentTestCase):

    def testStemAndScan(self):
        self.assertEqual(document.stem('/x/d_0417.pdb.gz'), 'd_0417')
        self.assertEqual(document.stem('d_0417.cif'), 'd_0417')
        self.assertEqual(document.stem('seqs.fasta'), 'seqs')
        d = self.path('f')
        os.makedirs(d)
        for name in ('a.pdb', 'a.cif', 'b.pdb', 'notes.txt', 'entries.csv'):
            open(os.path.join(d, name), 'w').close()
        files, sidecar = document.scan_folder(d)
        self.assertEqual([os.path.basename(f) for f in files], ['a.cif', 'b.pdb'])
        self.assertTrue(sidecar.endswith('entries.csv'))
        self.assertRaises(SetInputError, document.scan_folder, self.path('nope'))

    def testSidecarColumnTyping(self):
        rows = {'a': {'name': 'a', 'x': '1.5', 'flag': 'true', 'txt': 'hi', 'empty': ''},
                'b': {'name': 'b', 'x': '2', 'flag': '0', 'txt': '3', 'empty': ''}}
        cols = dict(document.sidecar_columns(rows, known=set()))
        self.assertEqual(cols, {'x': 'float', 'flag': 'bool', 'txt': 'str', 'empty': 'float'})
        self.assertIsNone(document.coerce_sidecar_value('float', ''))
        self.assertRaises(SetInputError, document.coerce_sidecar_value, 'float', 'abc')


class RoundTrips(SetDocumentTestCase):

    def testFolderExportReimportsWithEqualScalarsAndFlags(self):
        self.populated()
        out = self.path('out')
        cmd.set_export('s', out, entries='all')
        self.assertEqual(sorted(os.listdir(out)), ['d0.cif', 'd1.cif', 'd2.cif', 'entries.csv'])
        with open(os.path.join(out, 'entries.csv'), newline='') as h:
            rows = {r['name']: r for r in csv.DictReader(h)}
        self.assertEqual(rows['d1']['starred'], '1')
        self.assertEqual(rows['d1']['tags'], 'keep')
        self.assertEqual(rows['d2']['note'], 'a note')
        self.assertEqual(float(rows['d2']['score']), 3.0)

        name = cmd.set_import(out)
        self.assertEqual(name, 'out')
        back = cmd.set_get('out', 'all')
        self.assertEqual(sorted(back), ['d0', 'd1', 'd2'])
        self.assertEqual(back['d2']['score'], 3.0)
        self.assertEqual(back['d2']['label'], 'L2')
        self.assertEqual(back['d1']['starred'], 1)
        self.assertEqual(back['d1']['tags'], 'keep')
        cols = {c['column']: c for c in cmd.set_info('out')['columns']}
        self.assertEqual(cols['score']['tool'], 'import')
        cmd.set_stage('out', 'd1')
        self.assertEqual(cmd.count_atoms('d1 and name CA'), 3)
        c = store.active()
        e = c.entry(c.get_set('out')['id'], 'd1')
        self.assertEqual(e['parents'], [], 'an empty JSON list re-imports as no parents')
        e2 = c.entry(c.get_set('out')['id'], 'd2')
        self.assertEqual(e2['parents'], ['abc123'], 'parents survive the CSV round trip')

    def testCsvAndFastaExport(self):
        self.populated()
        cmd.set_filter('s', 'score > 1')
        csv_path = self.path('t.csv')
        cmd.set_export('s', csv_path)
        with open(csv_path, newline='') as h:
            names = [r['name'] for r in csv.DictReader(h)]
        self.assertEqual(sorted(names), ['d1', 'd2'], 'the default selector is filtered')
        fa = self.path('t.fasta')
        cmd.set_export('s', fa, entries='all')
        text = open(fa).read()
        self.assertIn('>d0/A\nACD\n', text)
        self.assertEqual(text.count('>'), 3)
        self.assertRaises(SetInputError, cmd.set_export, 's', self.path('x.bin'), format='bin')

    def testSidecarOnlyRowsBecomeSequenceEntries(self):
        d = self.path('mixed')
        os.makedirs(d)
        cmd.fab('AAA', 'a')
        cmd.save(os.path.join(d, 'a.pdb'), 'a')
        cmd.delete('a')
        with open(os.path.join(d, 'entries.csv'), 'w', newline='') as h:
            w = csv.writer(h)
            w.writerow(['name', 'sequences', 'plddt'])
            w.writerow(['a', '', '88.5'])
            w.writerow(['seqonly', '{"A": "MKT"}', '70'])
        cmd.set_import(d, name='mx')
        got = cmd.set_get('mx', 'all')
        self.assertEqual(sorted(got), ['a', 'seqonly'])
        self.assertEqual(got['a']['plddt'], 88.5)
        self.assertEqual(got['seqonly']['plddt'], 70.0)
        self.assertRaises(SetInputError, cmd.set_stage, 'mx', 'seqonly')

    def testImportFailureLeavesNoSet(self):
        self.assertRaises(SetNotFound, cmd.set_import, self.path('missing'))
        self.assertEqual(cmd.set_list(), [])
