"""The .raymol round trip, and what .pse save/load and reinitialize do to the store (#415).

    pymol -ckqy testing/testing.py --run testing/tests/sets/sets_session.py
"""
import io
import os
import sqlite3
import tempfile
from contextlib import redirect_stdout

from pymol import cmd, testing
from pymol.metrics import binding as mbinding, schema as mschema, store as mstore
from pymol.sets import binding, store
from pymol.sets.errors import SetFormatError

TOOL = 'sesstest'


class SetSessionTestCase(testing.PyMOLTestCase):

    def setUp(self):
        testing.PyMOLTestCase.setUp(self)
        self._saved = dict(mschema._SCHEMAS)
        mschema.register(TOOL, [mschema.MetricSpec('score', mschema.OBJECT, lo=0, hi=100)],
                         replace=True)
        store.reset()
        self._dir = tempfile.mkdtemp()

    def tearDown(self):
        binding.clear_peek()
        store.reset()
        mstore.clear()
        mschema._SCHEMAS.clear()
        mschema._SCHEMAS.update(self._saved)
        __import__('shutil').rmtree(self._dir, ignore_errors=True)
        testing.PyMOLTestCase.tearDown(self)

    def path(self, name):
        return os.path.join(self._dir, name)

    def campaign(self):
        cmd.set_create('s')
        for i in range(3):
            cmd.fab('ACDEF', 'p%d' % i, chain='A')
            mbinding.record('p%d' % i, TOOL, [mstore.value(TOOL, 'score', value=10.0 * i)])
            cmd.set_add('s', 'p%d' % i)
            cmd.delete('p%d' % i)
        mstore.clear()
        cmd.set_filter('s', 'score > 5')
        cmd.set_view_save('s', 'v')
        cmd.set_star('s', 'p2')
        cmd.set_stage('s', 'p2')
        cmd.fab('GGG', 'other')


class RaymolRoundTrip(SetSessionTestCase):

    def testSaveAndLoadRestoresSetsLinksFilterAndViews(self):
        self.campaign()
        working = store.active().path
        path = self.path('c.raymol')
        cmd.save(path)
        self.assertTrue(os.path.exists(path))
        self.assertEqual(os.path.realpath(store.active().path), os.path.realpath(path),
                         'after Save the document is the live container')
        self.assertFalse(os.path.exists(working), 'the pid working file is gone')
        self.assertEqual(cmd.get('session_file'), path.replace('\\', '/'))

        cmd.reinitialize()
        self.assertEqual(cmd.set_list(), [])
        self.assertNotEqual(os.path.realpath(store.active().path), os.path.realpath(path))

        cmd.load(path)
        self.assertEqual(os.path.realpath(store.active().path), os.path.realpath(path))
        self.assertIn('p2', cmd.get_names('all'))
        self.assertIn('other', cmd.get_names('all'))
        info = cmd.set_info('s')
        self.assertEqual(info['counts'], {'all': 3, 'filtered': 2, 'staged': 1,
                                          'starred': 1, 'rejected': 0})
        self.assertEqual(info['filter'], 'score > 5')
        self.assertEqual(info['views'], ['v'])
        self.assertEqual(cmd.set_get('s', 'p2')['p2']['staged'], 'p2')
        self.assertEqual(mstore.runs(object='p2')[0].scalars()['score'], 20.0,
                         'the staged object\'s metrics ride in the .pse blob')

    def testSaveOnOpenDocumentWritesOnlyTheSessionBlob(self):
        self.campaign()
        path = self.path('c.raymol')
        cmd.save(path)
        v1 = store.active().version()
        cmd.fab('AAA', 'later')
        cmd.save(path)
        self.assertEqual(os.path.realpath(store.active().path), os.path.realpath(path))
        self.assertGreater(store.active().version(), v1)
        con = sqlite3.connect(path)
        self.assertEqual(con.execute('SELECT COUNT(*) FROM session').fetchone()[0], 1)
        con.close()

    def testSaveAsOverAStaleWalKeepsTheData(self):
        self.campaign()
        target = self.path('t.raymol')
        with open(target + '-wal', 'wb') as h:
            h.write(b'\x00' * 4096)               # left by a crashed session
        with open(target, 'wb') as h:
            h.write(b'old')
        cmd.save(target)
        self.assertEqual(os.path.realpath(store.active().path), os.path.realpath(target))
        self.assertEqual([s['name'] for s in cmd.set_list()], ['s'])
        self.assertEqual(cmd.set_info('s')['counts']['all'], 3)
        self.assertFalse(os.path.exists(target + '.saving'))

    def testAFailedSaveAsKeepsTheWorkingDocument(self):
        self.campaign()
        working = store.active().path
        bad = os.path.join(self._dir, 'no', 'such', 'dir', 't.raymol')
        self.assertRaises(Exception, cmd.save, bad)
        self.assertEqual(os.path.realpath(store.active().path), os.path.realpath(working))
        self.assertEqual(cmd.set_info('s')['counts']['all'], 3, 'nothing lost')

    def testPartialLoadOfARaymolIsRefused(self):
        self.campaign()
        path = self.path('p.raymol')
        cmd.save(path)
        from pymol.sets.errors import SetInputError
        self.assertRaises(SetInputError, cmd.load, path, partial=1)
        self.assertEqual(cmd.set_info('s')['counts']['all'], 3)

    def testLoadReconcilesLinksTheBlobPredates(self):
        self.campaign()
        path = self.path('r.raymol')
        cmd.save(path)
        cmd.set_stage('s', 'p1')             # written to the document, not to the blob
        cmd.reinitialize()
        cmd.load(path)
        self.assertEqual(cmd.set_get('s', 'p1')['p1']['staged'], None)
        self.assertEqual(cmd.set_get('s', 'p2')['p2']['staged'], 'p2')

    def testSaveAsMovesTheDocument(self):
        self.campaign()
        a, b = self.path('a.raymol'), self.path('b.raymol')
        cmd.save(a)
        cmd.save(b)
        self.assertEqual(os.path.realpath(store.active().path), os.path.realpath(b))
        cmd.set_star('s', 'p0')
        con = sqlite3.connect(a)
        n_a = con.execute('SELECT COUNT(*) FROM entries WHERE starred = 1').fetchone()[0]
        con.close()
        self.assertEqual(n_a, 1, 'later writes land in b, not a')
        self.assertEqual(cmd.set_info('s')['counts']['starred'], 2)

    def testResultsAreOnDiskBeforeSave(self):
        cmd.set_create('s')
        cmd.fab('ACD', 'p')
        cmd.set_add('s', 'p')
        con = sqlite3.connect(store.active().path)
        self.assertEqual(con.execute('SELECT COUNT(*) FROM entries').fetchone()[0], 1)
        con.close()

    def testPeekNeverReachesASession(self):
        self.campaign()
        cmd.set_peek('s', 'p0')
        pse = self.path('x.pse')
        cmd.save(pse)
        names = [e[0] for e in cmd.get_session(partial=1)['names'] if e]
        self.assertNotIn(binding.PEEK, names)
        cmd.reinitialize()
        cmd.load(pse)
        self.assertNotIn(binding.PEEK, cmd.get_names('all'))

    def testLoadingAContainerWithoutASessionKeepsItsSets(self):
        cmd.set_create('s')
        cmd.fab('ACD', 'p')
        cmd.set_add('s', 'p')
        path = self.path('nosession.raymol')
        moved = store.active().save_into(path)     # the store alone: no session blob
        moved.close()
        cmd.reinitialize()
        cmd.fab('GGG', 'junk')
        cmd.load(path)
        self.assertEqual(os.path.realpath(store.active().path), os.path.realpath(path))
        self.assertEqual([s['name'] for s in cmd.set_list()], ['s'])
        self.assertNotIn('junk', cmd.get_names('all'), 'a document load replaces the scene')
        cmd.set_stage('s', 'p')
        self.assertIn('p', cmd.get_names('all'))

    def testLoadingANonRaymolFileRaises(self):
        bogus = self.path('bogus.raymol')
        with open(bogus, 'wb') as h:
            h.write(b'not a database')
        self.assertRaises(SetFormatError, cmd.load, bogus)
        newer = self.path('newer.raymol')
        con = sqlite3.connect(newer)
        con.execute('CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)')
        con.execute("INSERT INTO meta VALUES ('format_version', '99')")
        con.commit(); con.close()
        self.assertRaises(SetFormatError, cmd.load, newer)


class PlainPse(SetSessionTestCase):

    def testPseCarriesNoSetsAndWarns(self):
        self.campaign()
        pse = self.path('x.pse')
        buf = io.StringIO()
        with redirect_stdout(buf):
            cmd.save(pse, quiet=0)
        self.assertIn('cannot hold sets', buf.getvalue())
        import pickle
        with open(pse, 'rb') as h:
            session = pickle.load(h)
        self.assertFalse(any(str(k).startswith('raymol_set') for k in session.keys()),
                         'nothing set-related in a .pse')

    def testLoadingAPseClearsTheStore(self):
        self.campaign()
        pse = self.path('x.pse')
        cmd.save(pse)
        self.assertEqual(len(cmd.set_list()), 1)
        cmd.load(pse)
        self.assertEqual(cmd.set_list(), [], 'a bare .pse is a new session')
        self.assertIn('p2', cmd.get_names('all'), 'the staged object is still an object')

    def testSnapshotRestoreAndPartialLoadKeepTheStore(self):
        self.campaign()
        snapshot = cmd.get_session()
        cmd.set_session(snapshot)                    # what the theme preview does
        self.assertEqual([s['name'] for s in cmd.set_list()], ['s'])
        self.assertEqual(cmd.set_info('s')['counts']['staged'], 1)
        pse = self.path('extra.pse')
        cmd.reinitialize()
        cmd.fab('GGG', 'extra')
        cmd.save(pse)
        cmd.reinitialize()
        self.campaign()
        cmd.load(pse, partial=1)
        self.assertIn('extra', cmd.get_names('all'))
        self.assertEqual([s['name'] for s in cmd.set_list()], ['s'], 'a partial load merges')

    def testSavingDoesNotDisturbThePeek(self):
        self.campaign()
        cmd.set_peek('s', 'p0')
        cmd.save(self.path('k.raymol'))
        self.assertIn(binding.PEEK, cmd.get_names('all'))

    def testAPseSaveWithoutSetsOpensNoWorkingFile(self):
        store.reset()
        cmd.fab('AAA', 'x1')
        cmd.save(self.path('plain.pse'))
        self.assertFalse(store.is_open(), 'a plain save must not create a working file')

    def testReinitializeResetsTheStore(self):
        self.campaign()
        p = store.active().path
        cmd.reinitialize()
        self.assertEqual(cmd.set_list(), [])
        self.assertEqual(os.path.realpath(store.active().path), os.path.realpath(p),
                         'the working file is reused, emptied')
