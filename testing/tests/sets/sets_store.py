"""The .raymol container: DDL, format guard, wide-table growth, blobs, transactions (#415).

    pymol -ckqy testing/testing.py --run testing/tests/sets/sets_store.py
"""
import os
import sqlite3
import struct
import tempfile
import time

from pymol import testing
from pymol.metrics.schema import MetricSpec
from pymol.sets import blobs, schema, store
from pymol.sets.errors import (SetFormatError, SetInputError, SetNameConflict,
                               SetNotFound)

CIF_A = 'data_a\n_atom_site.id 1\n'
CIF_B = 'data_b\n_atom_site.id 2\n'


class SetStoreTestCase(testing.PyMOLTestCase):

    def setUp(self):
        testing.PyMOLTestCase.setUp(self)
        self.dir = tempfile.mkdtemp(prefix='raymol_sets_test_')
        self.path = os.path.join(self.dir, 'doc.raymol')
        self.containers = []
        # Every test gets its own $RAYMOL_SETS_DIR (#447 review): the working
        # container -- and anything preserved from it -- otherwise lands in the real
        # $TMPDIR, where it accumulates a few MB per run and where the retention
        # sweep would take a CLI user's own recovered sessions with it.
        self._had_sets_dir = os.environ.get('RAYMOL_SETS_DIR')
        os.environ['RAYMOL_SETS_DIR'] = self.dir

    def tearDown(self):
        for c in self.containers:
            c.close()
        store.reset()
        for name in os.listdir(self.dir):
            os.unlink(os.path.join(self.dir, name))
        os.rmdir(self.dir)
        testing.PyMOLTestCase.tearDown(self)
        # Last, so PyMOLTestCase's own reinitialize still resets the store with the
        # private $RAYMOL_SETS_DIR in place.
        if self._had_sets_dir is None:
            os.environ.pop('RAYMOL_SETS_DIR', None)
        else:
            os.environ['RAYMOL_SETS_DIR'] = self._had_sets_dir

    def open(self, path=None):
        c = store.Container(path or self.path)
        self.containers.append(c)
        return c

    def specs(self):
        return [
            MetricSpec('plddt', 'state', lo=0, hi=100),
            MetricSpec('n_models', 'state', dtype='int'),
            MetricSpec('label', 'object', dtype='str'),
            MetricSpec('ok', 'state', dtype='bool'),
            dict(key='iptm', scope='chain', chain='B', tool='boltz2'),
            MetricSpec('pae', 'pair', lo=0, hi=31.75),
        ]

    def populated(self):
        c = self.open()
        s = c.create_set('demo')
        c.declare_columns(s['id'], self.specs())
        return c, s['id']


class FormatTest(SetStoreTestCase):

    def testFreshFileHasSchema(self):
        c = self.open()
        self.assertEqual(c.meta_get('format_version'), '1')
        self.assertEqual(c.version(), 0)
        tables = {r[0] for r in sqlite3.connect(self.path).execute(
            "SELECT name FROM sqlite_master WHERE type='table'")}
        for table in schema.TABLES:
            self.assertIn(table, tables)
        self.assertEqual(c.sets(), [])

    def testPragmas(self):
        c = self.open()
        self.assertEqual(c._conn.execute('PRAGMA journal_mode').fetchone()[0], 'wal')
        self.assertEqual(c._conn.execute('PRAGMA foreign_keys').fetchone()[0], 1)

    def testNotSqliteRefused(self):
        with open(self.path, 'w') as handle:
            handle.write('this is not a database, it is a text file ' * 4)
        self.assertRaises(SetFormatError, store.Container, self.path)

    def testSqliteWithoutMetaRefused(self):
        conn = sqlite3.connect(self.path)
        conn.execute('CREATE TABLE unrelated (x)')
        conn.commit()
        conn.close()
        self.assertRaises(SetFormatError, store.Container, self.path)

    def testNewerFormatRefusedNamingTheBuild(self):
        c = self.open()
        c._conn.execute("UPDATE meta SET value = '99' WHERE key = 'format_version'")
        c._conn.execute("UPDATE meta SET value = 'RayMol 9.9' WHERE key = 'app_version'")
        c.close()
        try:
            store.Container(self.path)
        except SetFormatError as exc:
            self.assertIn('99', str(exc))
            self.assertIn('RayMol 9.9', str(exc))
        else:
            self.fail('a newer format version must be refused')

    def testOlderFormatMigratesThroughTheHook(self):
        c = self.open()
        c._conn.execute("UPDATE meta SET value = '0' WHERE key = 'format_version'")
        c.close()
        called = []
        schema.MIGRATIONS[0] = lambda conn: called.append(True)
        try:
            c = self.open()
            self.assertEqual(called, [True])
            self.assertEqual(c.meta_get('format_version'), '1')
        finally:
            del schema.MIGRATIONS[0]

    def testMetaGetSet(self):
        c = self.open()
        self.assertIsNone(c.meta_get('stage_budget'))
        self.assertEqual(c.meta_get('stage_budget', 6), 6)
        v = c.version()
        c.meta_set('stage_budget', 8)
        self.assertEqual(c.meta_get('stage_budget'), '8')
        self.assertEqual(c.version(), v + 1)


class MappingTest(SetStoreTestCase):

    def testSqlType(self):
        self.assertEqual(schema.sql_type('float'), 'REAL')
        self.assertEqual(schema.sql_type('int'), 'INTEGER')
        self.assertEqual(schema.sql_type('bool'), 'INTEGER')
        self.assertEqual(schema.sql_type('str'), 'TEXT')
        self.assertRaises(SetInputError, schema.sql_type, 'complex')

    def testColumnName(self):
        self.assertEqual(schema.column_name('plddt'), 'plddt')
        self.assertEqual(schema.column_name('plddt', 'B'), 'plddt__b')
        self.assertEqual(schema.column_name('plddt', 'A/1'), 'plddt__a_1')
        self.assertEqual(schema.metrics_table('abcd1234'), 'm_abcd1234')

    def testKeyAlphabet(self):
        self.assertEqual(schema.check_key('mean_plddt2'), 'mean_plddt2')
        for bad in ('Plddt', '2fast', 'a-b', 'a b', 'a;drop', '', None, 'a"b'):
            self.assertRaises(SetInputError, schema.check_key, bad)


class SetTest(SetStoreTestCase):

    def testCreateRejectsBadNamesAndDuplicates(self):
        c = self.open()
        for bad in ('', ' ', 'a b', 'a,b', 'a/b', "a'b", 'a(b)'):
            self.assertRaises(SetInputError, c.create_set, bad)
        self.assertRaises(SetInputError, c.create_set, 'x', kind='blobs')
        s = c.create_set('demo', note='n', tool='rfd3')
        self.assertEqual(s['group_name'], 'demo')
        self.assertEqual(s['kind'], 'structures')
        self.assertEqual(s['columns'], [])
        self.assertEqual(s['reference'], '')
        self.assertRaises(SetNameConflict, c.create_set, 'demo')
        self.assertEqual(len(s['id']), 8)
        self.assertEqual(c.get_set('demo')['id'], s['id'])
        self.assertEqual(c.get_set(s['id'])['name'], 'demo')
        self.assertRaises(SetNotFound, c.get_set, 'nope')

    def testRename(self):
        c = self.open()
        a = c.create_set('a')
        c.create_set('b')
        self.assertRaises(SetNameConflict, c.rename_set, a['id'], 'b')
        self.assertRaises(SetInputError, c.rename_set, a['id'], 'a b')
        c.rename_set(a['id'], 'c')
        self.assertEqual(c.get_set('c')['id'], a['id'])
        self.assertEqual(c.get_set('c')['group_name'], 'c')
        self.assertEqual([s['name'] for s in c.sets()], ['c', 'b'])

    def testUpdateSetFields(self):
        c, sid = self.populated()
        c.update_set(sid, note='x', budget=3, ranking_key='plddt', sort_desc=0,
                     filter='plddt > 50', columns=['plddt'], reference='target')
        s = c.get_set(sid)
        self.assertEqual((s['note'], s['budget'], s['ranking_key'], s['sort_desc'],
                          s['filter'], s['columns'], s['reference']),
                         ('x', 3, 'plddt', 0, 'plddt > 50', ['plddt'], 'target'))
        self.assertRaises(SetInputError, c.update_set, sid, name='other')
        self.assertRaises(SetInputError, c.update_set, sid, id='other')
        c.update_set(sid, budget=None)
        self.assertIsNone(c.get_set(sid)['budget'])
        indexes = [r[0] for r in c._conn.execute(
            "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name=?",
            ('m_' + sid,))]
        self.assertIn('m_%s_plddt' % sid, indexes)

    def testDeleteSetDropsTableAndBlobs(self):
        c, sid = self.populated()
        c.add_entry(sid, 'd1', chains=[('A', CIF_A)])
        other = c.create_set('other')
        c.add_entry(other['id'], 'd1', chains=[('A', CIF_A), ('B', CIF_B)])
        self.assertEqual(c.blob_stats()['count'], 2)
        c.delete_set(other['id'])
        self.assertRaises(SetNotFound, c.get_set, 'other')
        stats = c.blob_stats()
        self.assertEqual((stats['count'], stats['orphans']), (1, 0))
        tables = {r[0] for r in c._conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table'")}
        self.assertIn('m_' + sid, tables)
        self.assertNotIn('m_' + other['id'], tables)
        self.assertEqual(c.count(sid), 1)


class ColumnTest(SetStoreTestCase):

    def columns_of(self, c, sid):
        return [r[1] for r in c._conn.execute('PRAGMA table_info("m_%s")' % sid)]

    def testDeclareGrowsTheTable(self):
        c = self.open()
        sid = c.create_set('demo')['id']
        self.assertEqual(self.columns_of(c, sid), ['entry_id'])
        c.declare_columns(sid, self.specs())
        cols = self.columns_of(c, sid)
        self.assertEqual(cols, ['entry_id', 'plddt', 'n_models', 'label', 'ok',
                                'iptm__b'])
        types = {r[1]: r[2] for r in c._conn.execute('PRAGMA table_info("m_%s")' % sid)}
        self.assertEqual(types['plddt'], 'REAL')
        self.assertEqual(types['n_models'], 'INTEGER')
        self.assertEqual(types['ok'], 'INTEGER')
        self.assertEqual(types['label'], 'TEXT')
        # Re-declaring is a no-op, not an error and not a duplicate.
        c.declare_columns(sid, self.specs())
        self.assertEqual(self.columns_of(c, sid), cols)
        declared = c.columns(sid)
        self.assertEqual(len(declared), 6)
        self.assertEqual([d['column'] for d in declared],
                         ['plddt', 'n_models', 'label', 'ok', 'iptm__b', None])
        self.assertEqual(declared[5]['scope'], 'pair')

    def testToolSurvivesTheRoundTrip(self):
        c = self.open()
        sid = c.create_set('demo')['id']
        c.declare_columns(sid, [dict(key='plddt', scope='state', tool='boltz2'),
                                MetricSpec('score', 'state')])
        by_key = {d['key']: d for d in c.columns(sid)}
        self.assertEqual(by_key['plddt']['tool'], 'boltz2')
        self.assertEqual(by_key['score']['tool'], '')
        # And the stored dicts can be fed straight back in.
        c.declare_columns(sid, c.columns(sid))
        self.assertEqual(len(c.columns(sid)), 2)

    def testBadKeyRefused(self):
        c = self.open()
        sid = c.create_set('demo')['id']
        self.assertRaises(SetInputError, c.declare_columns, sid,
                          [dict(key='pLDDT', scope='state')])
        self.assertRaises(SetInputError, c.declare_columns, sid,
                          [dict(key='a; drop table sets', scope='state')])
        self.assertRaises(SetInputError, c.declare_columns, sid,
                          [dict(key='name', scope='state')])
        self.assertRaises(SetInputError, c.declare_columns, sid,
                          [dict(key='x', scope='nowhere')])
        self.assertRaises(SetInputError, c.declare_columns, sid, ['plddt'])
        self.assertEqual(self.columns_of(c, sid), ['entry_id'])


class EntryTest(SetStoreTestCase):

    def add(self, c, sid, name, cif=CIF_A, plddt=80.0):
        return c.add_entry(
            sid, name, sequences={'A': 'ACDEFG', 'B': 'KLM'},
            chains=[('A', cif), ('B', CIF_B)],
            scalars={'plddt': plddt, 'n_models': 5, 'label': 'x', 'ok': True,
                     ('iptm', 'B'): 0.5},
            arrays=[dict(key='pae', scope='pair', chain=None,
                         index=[('A', '1'), ('A', '2'), ('B', '1')],
                         values=[0.0, 1.0, 2.0, None, 4.0, 5.0, 6.0, 7.0, 31.75],
                         spec=MetricSpec('pae', 'pair', lo=0, hi=31.75)),
                    dict(key='conf', scope='residue', chain='A',
                         index=[('A', '1'), ('A', '2')], values=[0.5, None],
                         spec=MetricSpec('conf', 'residue'))])

    def testAddEntryWritesEverything(self):
        c, sid = self.populated()
        v = c.version()
        eid = self.add(c, sid, 'd1')
        self.assertEqual(c.version(), v + 1, 'one transaction, one bump')
        e = c.entry(sid, 'd1')
        self.assertEqual(e['id'], eid)
        self.assertEqual(e['ord'], 1)
        self.assertEqual(e['n_chains'], 2)
        self.assertEqual(e['n_residues'], 9)
        self.assertEqual(e['sequences'], {'A': 'ACDEFG', 'B': 'KLM'})
        self.assertEqual(e['parents'], [])
        self.assertEqual(e['scalars'], {'plddt': 80.0, 'n_models': 5, 'label': 'x',
                                        'ok': 1, 'iptm__b': 0.5})
        self.assertEqual(c.chain_cifs(eid), [('A', CIF_A), ('B', CIF_B)])
        index, values = c.array(eid, 'pae')
        self.assertEqual(index, [['A', '1'], ['A', '2'], ['B', '1']])
        self.assertIsNone(values[3])
        self.assertAlmostEqual(values[8], 31.75, places=6)
        index, values = c.array(eid, 'conf', chain='A')
        self.assertEqual(values, [0.5, None])
        rows = c.arrays_of(eid)
        self.assertEqual(sorted((r['key'], r['encoding']) for r in rows),
                         [('conf', 'f32'), ('pae', 'u8q')])
        self.assertEqual(c.entry_by_id(eid)['name'], 'd1')
        self.assertRaises(SetNotFound, c.array, eid, 'nope')
        self.assertRaises(SetNotFound, c.entry, sid, 'nope')
        self.assertEqual(self.add(c, sid, 'd2') != eid, True)
        self.assertEqual(c.entry(sid, 'd2')['ord'], 2)

    def testAddEntryRollsBackWhole(self):
        c, sid = self.populated()
        self.add(c, sid, 'd1')
        before = (c.blob_stats(), c.version(), c.count(sid))
        refs_before = dict(c._conn.execute('SELECT hash, refs FROM blobs').fetchall())
        # Same name: fails after the entries INSERT would have been reached; blobs for
        # the chains must not have been counted.
        self.assertRaises(SetNameConflict, self.add, c, sid, 'd1', cif='data_new\n')
        # An undeclared scalar column: fails AFTER chains and their blobs were written.
        self.assertRaises(SetInputError, c.add_entry, sid, 'd3',
                          chains=[('A', 'data_fresh\n')], scalars={'nope': 1})
        # A ragged array: fails after chains and scalars.
        self.assertRaises(SetInputError, c.add_entry, sid, 'd4',
                          chains=[('A', 'data_fresh2\n')], scalars={'plddt': 1},
                          arrays=[dict(key='conf', scope='residue',
                                       index=[('A', '1')], values=[1, 2])])
        self.assertEqual((c.blob_stats(), c.version(), c.count(sid)), before)
        self.assertEqual(dict(c._conn.execute('SELECT hash, refs FROM blobs').fetchall()),
                         refs_before)
        self.assertRaises(SetNotFound, c.entry, sid, 'd3')
        self.assertEqual(c.count(sid), 1)

    def testSpecsDeclaredWithTheEntry(self):
        c = self.open()
        sid = c.create_set('demo')['id']
        c.add_entry(sid, 'd1', scalars={'score': 1.5},
                    specs=[MetricSpec('score', 'state')])
        self.assertEqual(c.entry(sid, 'd1')['scalars'], {'score': 1.5})
        self.assertEqual([d['column'] for d in c.columns(sid)], ['score'])
        self.assertRaises(SetNameConflict, c.add_entry, sid, 'd1')
        self.assertRaises(SetInputError, c.add_entry, sid, 'd two')

    def testChainDedupeAndRefcount(self):
        c, sid = self.populated()
        e1 = c.add_entry(sid, 'd1', chains=[('A', CIF_A)])
        e2 = c.add_entry(sid, 'd2', chains=[('A', CIF_A), ('B', CIF_B)])
        stats = c.blob_stats()
        self.assertEqual(stats['count'], 2)
        self.assertEqual(stats['orphans'], 0)
        refs = dict(c._conn.execute('SELECT hash, refs FROM blobs').fetchall())
        hash_a = blobs.sha256_hex(CIF_A.encode('utf-8'))
        self.assertEqual(refs[hash_a], 2)
        c.delete_entries([e1])
        refs = dict(c._conn.execute('SELECT hash, refs FROM blobs').fetchall())
        self.assertEqual(refs[hash_a], 1)
        self.assertEqual(c.chain_cifs(e2)[0], ('A', CIF_A))
        c.delete_entries([e2])
        self.assertEqual(c.blob_stats(), {'count': 0, 'bytes': 0, 'orphans': 0})
        self.assertEqual(c.count(sid), 0)

    def testHomodimerCountsTwice(self):
        # The same blob referenced twice by one entry is released twice.
        c, sid = self.populated()
        eid = c.add_entry(sid, 'dimer', chains=[('A', CIF_A), ('B', CIF_A)])
        refs = dict(c._conn.execute('SELECT hash, refs FROM blobs').fetchall())
        self.assertEqual(list(refs.values()), [2])
        c.delete_entries([eid])
        self.assertEqual(c.blob_stats()['count'], 0)

    def testEntriesWhereAndCount(self):
        c, sid = self.populated()
        for i in range(6):
            self.add(c, sid, 'd%d' % i, plddt=50.0 + 10 * i)
        rows = c.entries(sid, where='m.plddt > ? AND e.name != ?', params=(70.0, 'd5'))
        self.assertEqual([r['name'] for r in rows], ['d3', 'd4'])
        self.assertEqual(c.count(sid, 'm.plddt > ? AND e.name != ?', (70.0, 'd5')), 2)
        self.assertEqual(c.count(sid), 6)
        rows = c.entries(sid, order_by='m.plddt DESC', limit=2, offset=1)
        self.assertEqual([r['name'] for r in rows], ['d4', 'd3'])
        self.assertEqual(rows[0]['scalars']['plddt'], 90.0)
        self.assertEqual([r['name'] for r in c.entries(sid)],
                         ['d0', 'd1', 'd2', 'd3', 'd4', 'd5'])

    def testUpdateEntryAndScalar(self):
        c, sid = self.populated()
        eid = self.add(c, sid, 'd1')
        c.update_entry(eid, starred=1, tags='good hit', staged_object='d1_2',
                       parents=['abc'], note='n')
        e = c.entry_by_id(eid)
        self.assertEqual((e['starred'], e['tags'], e['staged_object'], e['parents'],
                          e['note']), (1, 'good hit', 'd1_2', ['abc'], 'n'))
        self.assertRaises(SetInputError, c.update_entry, eid, name='x')
        self.assertRaises(SetNotFound, c.update_entry, 'nope', starred=1)
        c.set_scalar(eid, 'plddt', 12.5)
        c.set_scalar(eid, 'iptm', 0.9, chain='B')
        c.set_scalar(eid, 'plddt', float('nan'))
        e = c.entry_by_id(eid)
        self.assertIsNone(e['scalars']['plddt'])
        self.assertEqual(e['scalars']['iptm__b'], 0.9)
        self.assertRaises(SetInputError, c.set_scalar, eid, 'nope', 1)
        self.assertRaises(SetInputError, c.set_scalar, eid, 'n_models', 'seven')

    def testRuns(self):
        c, sid = self.populated()
        rid = c.add_run(sid, 'boltz2', tool_version='2.1', inputs={'seed': 7})
        self.assertEqual(c.run(rid)['inputs'], {'seed': 7})
        self.assertEqual([r['id'] for r in c.runs(sid)], [rid])
        eid = c.add_entry(sid, 'd1', run_id=rid)
        self.assertEqual(c.entry_by_id(eid)['run_id'], rid)
        self.assertRaises(SetNotFound, c.add_entry, sid, 'd2', run_id='nope')
        self.assertRaises(SetNotFound, c.run, 'nope')


class BlobCodecTest(SetStoreTestCase):

    def testF32RoundTripExact(self):
        values = [0.0, 1.0, -2.5, 0.125, 1048576.5, None, 1.0e-3]
        blob = blobs.encode_f32(values)
        self.assertEqual(len(blob), 4 * len(values))
        out = blobs.decode_f32(blob, len(values))
        self.assertEqual(out[:5], values[:5])
        self.assertIsNone(out[5])
        self.assertEqual(out[6], struct.unpack('<f', struct.pack('<f', 1.0e-3))[0])
        self.assertEqual(blob[:4], struct.pack('<f', 0.0))
        self.assertEqual(blob[4:8], struct.pack('<f', 1.0))
        self.assertRaises(SetInputError, blobs.decode_f32, blob, 3)

    def testU8qRoundTripWithinHalfAStep(self):
        values = [0.0, 0.1, 5.0, 17.3, 31.75, None, 40.0, -3.0]
        blob, scale, offset = blobs.encode_u8q(values, 0, 31.75)
        self.assertEqual(offset, 0.0)
        self.assertAlmostEqual(scale, 31.75 / 254)
        self.assertEqual(blob[5], 255)
        out = blobs.decode_u8q(blob, scale, offset)
        for got, want in zip(out[:5], values[:5]):
            self.assertLessEqual(abs(got - want), scale / 2 + 1e-9)
        self.assertIsNone(out[5])
        self.assertAlmostEqual(out[6], 31.75, places=6)     # clamped
        self.assertEqual(out[7], 0.0)                        # clamped
        self.assertEqual(max(b for b in blob if b != 255), 254)

    def testCifDeterministicAndHashOfPlainText(self):
        h1, gz1, size = blobs.encode_cif(CIF_A)
        h2, gz2, _ = blobs.encode_cif(CIF_A)
        self.assertEqual(gz1, gz2)
        self.assertEqual(h1, blobs.sha256_hex(CIF_A.encode('utf-8')))
        self.assertEqual(size, len(CIF_A.encode('utf-8')))
        self.assertEqual(blobs.decode_cif(gz1), CIF_A)

    def testChooseEncoding(self):
        self.assertEqual(blobs.choose_encoding('pair', MetricSpec('p', 'pair', lo=0,
                                                                  hi=1)), 'u8q')
        self.assertEqual(blobs.choose_encoding('pair', MetricSpec('p', 'pair')), 'f32')
        self.assertEqual(blobs.choose_encoding('pair', dict(lo=0, hi=1)), 'u8q')
        self.assertEqual(blobs.choose_encoding('residue', MetricSpec('p', 'residue',
                                                                     lo=0, hi=1)),
                         'f32')
        self.assertEqual(blobs.choose_encoding('pair', None), 'f32')


class ViewTest(SetStoreTestCase):

    def testUpsertAndDelete(self):
        c, sid = self.populated()
        v1 = c.save_view(sid, 'top', filter='plddt > 80', sort_key='plddt')
        v2 = c.save_view(sid, 'top', filter='plddt > 90', sort_desc=0, columns=['plddt'])
        self.assertEqual(v1, v2)
        self.assertEqual(len(c.views(sid)), 1)
        view = c.view(sid, 'top')
        self.assertEqual((view['filter'], view['sort_desc'], view['columns']),
                         ('plddt > 90', 0, ['plddt']))
        c.save_view(sid, 'other')
        self.assertEqual([v['name'] for v in c.views(sid)], ['top', 'other'])
        c.delete_view(sid, 'top')
        self.assertRaises(SetNotFound, c.view, sid, 'top')
        self.assertRaises(SetNotFound, c.delete_view, sid, 'top')
        c.delete_set(sid)
        self.assertEqual(c._conn.execute('SELECT count(*) FROM views').fetchone()[0], 0)


class LifecycleTest(SetStoreTestCase):

    def testVersionBumpsOnEveryWrite(self):
        c, sid = self.populated()
        seen = [c.version()]

        def step(fn, *args, **kwargs):
            result = fn(*args, **kwargs)
            self.assertEqual(c.version(), seen[-1] + 1, fn.__name__)
            seen.append(c.version())
            return result

        eid = step(c.add_entry, sid, 'd1', chains=[('A', CIF_A)])
        rid = step(c.add_run, sid, 'rfd3')
        step(c.update_entry, eid, starred=1)
        step(c.set_scalar, eid, 'plddt', 1.0)
        step(c.update_set, sid, note='x')
        step(c.rename_set, sid, 'renamed')
        step(c.save_view, sid, 'v')
        step(c.delete_view, sid, 'v')
        step(c.write_session, b'pse', pse_version=1.8, app_version='RayMol test')
        step(c.declare_columns, sid, [MetricSpec('new', 'state')])
        step(c.delete_entries, [eid])
        step(c.bump)
        step(c.delete_set, sid)
        self.assertEqual(c.read_session(), b'pse')
        self.assertEqual(c.meta_get('app_version'), 'RayMol test')
        # Reads do not bump.
        c.sets()
        c.blob_stats()
        self.assertRaises(SetNotFound, c.run, rid)   # cascaded with the set
        self.assertEqual(c.version(), seen[-1])

    def testSaveIntoIsLive(self):
        c, sid = self.populated()
        eid = EntryTest.add(self, c, sid, 'd1')
        c.write_session(b'session')
        before = (c.sets(), c.entries(sid), c.blob_stats(), c.columns(sid))
        target = os.path.join(self.dir, 'saved.raymol')
        new = c.save_into(target)
        self.containers.append(new)
        self.assertTrue(c.closed)
        self.assertEqual(new.path, target)
        self.assertEqual((new.sets(), new.entries(sid), new.blob_stats(),
                          new.columns(sid)), before)
        self.assertEqual(new.read_session(), b'session')
        self.assertEqual(new.chain_cifs(eid), [('A', CIF_A), ('B', CIF_B)])
        # The returned container is the live one: a write lands in the new path only.
        new.add_entry(sid, 'd2')
        self.assertEqual(new.count(sid), 2)
        again = self.open(target)
        self.assertEqual(again.count(sid), 2)
        old = self.open()
        self.assertEqual(old.count(sid), 1)
        self.assertRaises(SetInputError, again.save_into, target)

    def testSaveIntoOverwrites(self):
        c, sid = self.populated()
        target = os.path.join(self.dir, 'saved.raymol')
        other = self.open(target)
        other.create_set('stale')
        other.close()
        new = c.save_into(target)
        self.containers.append(new)
        self.assertEqual([s['name'] for s in new.sets()], ['demo'])

    def testActiveReplaceReset(self):
        os.environ['RAYMOL_SETS_DIR'] = self.dir
        try:
            expected = os.path.join(self.dir, 'raymol_sets_%d.raymol' % os.getpid())
            self.assertEqual(store.working_path(), expected)
            a = store.active()
            self.assertIs(store.active(), a)
            self.assertEqual(a.path, expected)
            a.create_set('x')
            self.assertTrue(os.path.exists(expected))
            doc = self.open()
            self.assertIs(store.replace(doc), doc)
            self.assertTrue(a.closed)
            self.assertTrue(os.path.exists(expected), 'replace must not delete files')
            self.assertIs(store.active(), doc)
            store.reset()
            self.assertTrue(doc.closed)
            self.assertTrue(os.path.exists(self.path), 'reset never deletes a document')
            b = store.active()
            self.assertEqual(b.path, expected)
            self.assertEqual([s['name'] for s in b.sets()], ['x'],
                             'the working file replace() left behind is reopened as-is')
            store.reset()
            self.assertFalse(os.path.exists(expected))
            # Sweep: a dead pid's file goes, ours and a live one stay.
            stale = os.path.join(self.dir, 'raymol_sets_999999.raymol')
            with open(stale, 'wb'):
                pass
            with open(stale + '-wal', 'wb'):
                pass
            live = os.path.join(self.dir, 'raymol_sets_%d.raymol' % os.getppid())
            with open(live, 'wb'):
                pass
            removed = store.sweep_stale_working_files()
            self.assertEqual(removed, [stale])
            self.assertFalse(os.path.exists(stale + '-wal'))
            self.assertTrue(os.path.exists(live))
        finally:
            del os.environ['RAYMOL_SETS_DIR']
            store.reset()


class DurabilityTest(SetStoreTestCase):
    """A working container that holds a non-empty set is never deleted (#447).

    Quitting used to delete it (atexit -> reset) and the next launch used to sweep it
    (dead pid), so an untitled session's six-hour batch went with the app. Everything
    here is that rule and the retention policy that keeps "never deleted" from meaning
    "kept forever".
    """

    def setUp(self):
        SetStoreTestCase.setUp(self)      # $RAYMOL_SETS_DIR is self.dir
        # Both launch one-shots are spent, so no test sweeps or retires by accident;
        # the ones that mean to (a "relaunch") clear them explicitly.
        self._had_swept = store._SWEPT
        self._had_own = store._OWN_RETIRED
        store._SWEPT = store._OWN_RETIRED = True

    def relaunch(self):
        """Put the process back in the state a cold launch is in: nothing swept, our
        own pid's leftovers not yet dealt with."""
        store._SWEPT = store._OWN_RETIRED = False

    def tearDown(self):
        store._SWEPT = self._had_swept
        store._OWN_RETIRED = self._had_own
        SetStoreTestCase.tearDown(self)

    def working(self, entries=1, sets=1):
        """The pid-scoped working container, with `entries` entries in it."""
        c = store.active()
        for i in range(sets):
            sid = c.create_set('s%d' % i)['id']
            for n in range(entries):
                c.add_entry(sid, 'd%d_%d' % (i, n), chains=[('A', CIF_A)])
        return c

    def recovered(self):
        return sorted(name for name in os.listdir(self.dir)
                      if name.startswith(store._RECOVERED_PREFIX))

    def dead_working_file(self, pid=999999, entries=1):
        """A working file left by a process that is gone, with `entries` in it."""
        path = os.path.join(self.dir, 'raymol_sets_%d.raymol' % pid)
        c = store.Container(path)
        sid = c.create_set('left%d' % pid)['id']
        for n in range(entries):
            c.add_entry(sid, 'd%d' % n, chains=[('A', CIF_A)])
        c.close()
        return path

    # -- the must: quitting does not destroy data ------------------------------------

    def testQuitKeepsAWorkingFileThatHoldsEntries(self):
        path = self.working().path
        store._at_exit()                       # what ⌘Q reaches through atexit
        self.assertFalse(os.path.exists(path), 'the pid-scoped name is released')
        kept = self.recovered()
        self.assertEqual(len(kept), 1, kept)
        found = store.recoverable()
        self.assertEqual([(r['sets'], r['entries']) for r in found], [(1, 1)])
        self.assertEqual(os.path.basename(found[0]['path']), kept[0])

    def testQuitDeletesAWorkingFileWhoseSetsAreEmpty(self):
        # The other half of the rule: a user who never filled a set leaves nothing
        # behind, and is never offered an empty container to "recover".
        path = self.working(entries=0).path
        store._at_exit()
        self.assertFalse(os.path.exists(path))
        self.assertEqual(self.recovered(), [])
        self.assertEqual(store.recoverable(), [])

    def testResetKeepsTheEntriesAndStillRepointsTheStore(self):
        # `load x.pse`, `reinitialize` and the tests all come through reset(): only the
        # FILE deletion is conditional, never the close-and-repoint.
        c = self.working()
        path = c.path
        store.reset()
        self.assertTrue(c.closed)
        self.assertFalse(store.is_open())
        self.assertEqual(len(self.recovered()), 1)
        fresh = store.active()
        self.assertEqual(fresh.path, path, 'the working name is free again')
        self.assertEqual(fresh.sets(), [], 'and the new container is empty')

    def testSweepPreservesADeadPidsEntriesAndRemovesWhatIsEmpty(self):
        full = self.dead_working_file(999999, entries=2)
        empty = self.dead_working_file(999998, entries=0)
        removed = store.sweep_stale_working_files()
        self.assertEqual(removed, [empty], 'only an empty container is swept')
        self.assertFalse(os.path.exists(full))
        found = store.recoverable()
        self.assertEqual([r['entries'] for r in found], [2])

    def testAPreservedFileIsNotSweptWhileItHasEntries(self):
        self.working()
        store._at_exit()
        kept = self.recovered()
        for _ in range(3):
            self.relaunch()
            store.sweep_once()                 # three more launches
        self.assertEqual(self.recovered(), kept)

    def testAPreservedFileIsNeverAdoptedAsAWorkingFile(self):
        # pids are reused; active() already treats a file under OUR pid as stale, and
        # that property has to survive preservation -- a recovered container must not
        # come back as the next session's own working file.
        self.working()
        store._at_exit()
        kept = self.recovered()
        self.relaunch()
        c = store.active()                     # the next "launch", same pid
        self.assertEqual(c.path, store.working_path())
        self.assertEqual(c.sets(), [], 'a new session starts empty')
        self.assertEqual(self.recovered(), kept, 'and the preserved file is untouched')

    # -- retention -------------------------------------------------------------------

    def preserved(self, n, age_days=0.0):
        """`n` preserved containers, each with one entry, aged `age_days`."""
        out = []
        for i in range(n):
            path = self.dead_working_file(900000 + i)
            kept = store.preserve_working_file(path)
            when = store._now() - age_days * 86400 - (n - i)
            os.utime(kept, (when, when))
            out.append(kept)
        return out

    def testRetentionKeepsTheTenNewestAndDropsTheRest(self):
        paths = self.preserved(12)             # oldest first
        removed = store.sweep_recovered()
        self.assertEqual(sorted(removed), sorted(paths[:2]))
        self.assertEqual(len(store.recovered_files()), store.RECOVERED_KEEP)

    def testRetentionDropsAnythingOlderThanThirtyDays(self):
        old = self.preserved(2, age_days=31)
        new = self.preserved(2)
        removed = store.sweep_recovered()
        self.assertEqual(sorted(removed), sorted(old), 'age goes before count')
        self.assertEqual(sorted(store.recovered_files()), sorted(new))

    def testRetentionDropsAPreservedFileThatCanNeverBeOffered(self):
        # An empty or unreadable preserved file is not a recovery, whatever its age.
        junk = os.path.join(self.dir, 'recovered_20260101-000000_1.raymol')
        with open(junk, 'wb') as fh:
            fh.write(b'not a database')
        keep = self.preserved(1)
        self.assertEqual(store.sweep_recovered(), [junk])
        self.assertEqual(store.recovered_files(), keep)

    # -- the question Swift asks at launch -------------------------------------------

    def testRecoverableReportsSetsEntriesAndModifiedNewestFirst(self):
        first = store.preserve_working_file(self.dead_working_file(999999, entries=1))
        second = store.preserve_working_file(self.dead_working_file(999998, entries=3))
        os.utime(first, (store._now() - 500, store._now() - 500))
        found = store.recoverable()
        self.assertEqual([r['path'] for r in found], [second, first])
        self.assertEqual([r['entries'] for r in found], [3, 1])
        self.assertEqual([r['sets'] for r in found], [1, 1])
        self.assertFalse(any(r['session'] for r in found), 'no Save, no session blob')
        self.assertGreater(found[0]['modified'], 0)

    def testRecoverableIsCheapAndOpensNothing(self):
        # It is a launch-time question, not a poll: it must not create the working
        # container as a side effect, and it must count rows rather than read them --
        # the file it is asked about can hold ten thousand entries.
        c = store.active()
        sid = c.create_set('big')['id']
        for i in range(400):
            c.add_entry(sid, 'd%d' % i, chains=[('A', CIF_A)])
        store._at_exit()
        self.assertFalse(store.is_open())
        started = time.time()
        found = store.recoverable()
        elapsed = time.time() - started
        self.assertEqual([r['entries'] for r in found], [400])
        self.assertFalse(store.is_open(), 'asking must not open a container')
        self.assertLess(elapsed, 1.0, 'counts, not rows: %.3fs' % elapsed)

    def testDiscardRemovesOneContainerAndRefusesAnythingElse(self):
        kept = self.preserved(2)
        store.discard_recoverable(kept[0])
        self.assertEqual(store.recovered_files(), [kept[1]])
        self.assertRaises(SetInputError, store.discard_recoverable, self.path)
        self.assertRaises(SetInputError, store.discard_recoverable,
                          os.path.join(self.dir, 'raymol_sets_1.raymol'))


class DurabilityReviewTest(DurabilityTest):
    """The review's findings on #447: the ways the fix could still destroy data.

    Each of these was reproduced with real processes before it was fixed, and each
    fails if its fix is backed out.
    """

    # -- the pid guard must not depend on who swept ----------------------------------

    def testTheOwnPidGuardStillRunsWhenRecoverableAskedFirst(self):
        # The app's actual order: poll_recovery() at launch, before anything opens a
        # container. When the pid guard was conditional on sweep_once()'s return, the
        # sweep was already spent by the time active() ran and a file under OUR pid --
        # a crashed session's, pids being reused -- was adopted whole. The drawer then
        # listed sets whose staged objects are not in the scene, and a set_delete of
        # that unexpected set destroyed the previous session's work.
        c = store.Container(store.working_path())
        sid = c.create_set('ghost')['id']
        c.add_entry(sid, 'd0', chains=[('A', CIF_A)])
        c.close()
        self.relaunch()
        self.assertEqual([r['entries'] for r in store.recoverable()], [1])
        fresh = store.active()
        self.assertEqual(fresh.sets(), [], 'a new session must not inherit a dead one')
        self.assertEqual([r['entries'] for r in store.recoverable()], [1],
                         'and the dead session is still recoverable, not adopted')

    # -- nothing unlinks a container somebody has open -------------------------------

    def aged(self, days=31, entries=1):
        """A preserved container old enough for the retention policy to drop."""
        kept = store.preserve_working_file(self.dead_working_file(999999, entries=entries))
        return self.age(kept, days)

    def age(self, path, days=31):
        """Backdate `path`. Re-applied after anything WRITES to the container: a
        checkpoint refreshes its mtime, and retention reads mtime."""
        when = store._now() - days * 86400
        os.utime(path, (when, when))
        return path

    def testTheRetentionSweepNeverUnlinksAContainerWeHaveOpen(self):
        # load_raymol opens the file and THEN reaches active() -> sweep. With the
        # sweep free to drop it (31 days old, or past the 10-file cap), the document
        # was unlinked under the open connection: every later write landed in an
        # unlinked inode, with no error and no file.
        kept = self.aged()
        c = store.Container(kept)
        self.containers.append(c)
        self.assertEqual(store.sweep_recovered(), [])
        self.assertTrue(os.path.exists(kept), 'the open document survives the sweep')
        c.close()
        self.assertEqual(store.sweep_recovered(), [kept], 'and goes once it is closed')

    def testTheRetentionSweepLeavesAContainerANOTHERPROCESSHasOpen(self):
        # A registry is per-process; another RayMol holding a preserved container as
        # its document is invisible to it. What IS visible is the -wal/-shm SQLite
        # leaves beside an open file and removes on the last close.
        kept = self.aged()
        other = sqlite3.connect(kept)
        try:
            other.execute('PRAGMA journal_mode=WAL')
            other.execute('BEGIN IMMEDIATE')
            other.execute("INSERT OR REPLACE INTO meta VALUES ('probe', '1')")
            other.execute('COMMIT')
            self.age(kept)                     # the write refreshed its mtime
            self.assertTrue(store._has_sidecar(kept), 'the fixture must leave a -wal')
            self.assertEqual(store.sweep_recovered(), [], 'somebody is using it')
            self.assertTrue(os.path.exists(kept))
        finally:
            other.close()                      # checkpoints, and touches it again
        self.age(kept)
        self.assertEqual(store.sweep_recovered(), [kept], 'and goes once nobody is')

    def testTheOpenDocumentIsNotOfferedBackToItself(self):
        kept = self.aged(days=0)
        c = store.Container(kept)
        self.containers.append(c)
        self.assertEqual(store.recoverable(), [])
        c.close()
        self.assertEqual([r['path'] for r in store.recoverable()], [kept])

    # -- "I cannot answer" is not "it is empty" --------------------------------------

    def testAClosedContainerIsInspectedNotDeleted(self):
        # save_raymol's failure path can leave a CLOSED container installed as the
        # active one. holds_entries() cannot answer through a closed connection, and
        # answering False there deleted the file.
        c = self.working()
        path = c.path
        c.close()                              # still installed as _ACTIVE
        self.assertIsNone(c.holds_entries(), 'a closed container cannot answer')
        store.reset()
        self.assertFalse(os.path.exists(path))
        self.assertEqual([r['entries'] for r in store.recoverable()], [1],
                         'reset asked the disk instead of assuming empty')

    def testAnUnreadableWorkingFileIsPreservedNotDeleted(self):
        # A transient sqlite error at exit (locked, out of descriptors, a format
        # version from a newer build) must not be read as "nothing in here".
        path = self.dead_working_file(999999, entries=1)
        boom = self.no_sqlite()
        try:
            self.assertIsNone(store.inspect_container(path))
            self.assertTrue(store.looks_like_container(path))
            self.assertIsNotNone(store.retire_working_file(path))
        finally:
            boom()
        self.assertFalse(os.path.exists(path), 'it was preserved, not left in place')
        self.assertEqual(len(self.recovered()), 1)

    def testAnUnreadablePreservedFileIsKeptByTheSweep(self):
        # Same rule for the retention sweep: only a file that is not a database at
        # all is junk. One that is a database we could not read TODAY is kept.
        good = store.preserve_working_file(self.dead_working_file(999999, entries=1))
        alien = os.path.join(self.dir, 'recovered_20260101-000000_5.raymol')
        conn = sqlite3.connect(alien)
        conn.execute('CREATE TABLE something_else (x)')
        conn.close()
        self.assertIsNone(store.inspect_container(alien), 'not one of ours to read')
        self.assertTrue(store.looks_like_container(alien))
        self.assertEqual(store.sweep_recovered(), [])
        self.assertEqual(sorted(store.recovered_files()), sorted([good, alien]))

    def no_sqlite(self):
        """Make every sqlite3.connect fail, as a locked file or an exhausted
        descriptor table would. Returns the undo."""
        original = store.sqlite3.connect

        def boom(*args, **kwargs):
            raise store.sqlite3.OperationalError('unable to open database file')
        store.sqlite3.connect = boom
        return lambda: setattr(store.sqlite3, 'connect', original)

    # -- a failed rename is not a deletion -------------------------------------------

    def testAFileThatCouldNotBeRenamedIsReportedWhereItIs(self):
        # preserve_working_file returning None read as "removed": the sweep counted
        # it swept and load_raymol printed no "kept in ..." line, so the one case
        # where the user most needs to be told said nothing.
        path = self.dead_working_file(999999, entries=1)
        original = os.rename

        def boom(*args, **kwargs):
            raise OSError('read-only file system')
        os.rename = boom
        try:
            self.assertEqual(store.retire_working_file(path), path)
            self.assertEqual(store.sweep_stale_working_files(), [],
                             'a file still on disk was not removed')
        finally:
            os.rename = original
        self.assertTrue(os.path.exists(path), 'and it is still there to retire later')

    # -- the real interpreter shutdown, in a real process ----------------------------

    def run_child(self, body):
        """Run `body` in a child interpreter with our $RAYMOL_SETS_DIR, and let it
        EXIT normally. Everything else here calls `store._at_exit()` by hand, which
        proves the function does the right thing but not that atexit reaches it."""
        import subprocess
        import sys
        env = dict(os.environ)
        env['RAYMOL_SETS_DIR'] = self.dir
        env['PYTHONPATH'] = os.pathsep.join(p for p in sys.path if p)
        out = subprocess.run([sys.executable, '-c', body], env=env,
                             capture_output=True, text=True, timeout=120)
        self.assertEqual(out.returncode, 0, out.stderr)
        return out.stdout.strip()

    def testAChildProcessThatSIMPLYEXITSLeavesItsEntriesBehind(self):
        self.run_child(
            'from pymol.sets import store\n'
            'c = store.active()\n'
            "sid = c.create_set('campaign')['id']\n"
            "c.add_entry(sid, 'd0')\n")
        found = store.recoverable()
        self.assertEqual([(r['sets'], r['entries']) for r in found], [(1, 1)],
                         'atexit -> reset -> preserve, in a process that really ended')

    def testAChildProcessWithAnEmptySetLeavesNothing(self):
        self.run_child(
            'from pymol.sets import store\n'
            "store.active().create_set('empty')\n")
        self.assertEqual(store.recoverable(), [])
        self.assertEqual(os.listdir(self.dir), [])

