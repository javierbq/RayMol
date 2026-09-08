"""The .raymol container: DDL, format guard, wide-table growth, blobs, transactions (#415).

    pymol -ckqy testing/testing.py --run testing/tests/sets/sets_store.py
"""
import os
import sqlite3
import struct
import tempfile

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

    def tearDown(self):
        for c in self.containers:
            c.close()
        store.reset()
        for name in os.listdir(self.dir):
            os.unlink(os.path.join(self.dir, name))
        os.rmdir(self.dir)
        testing.PyMOLTestCase.tearDown(self)

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
