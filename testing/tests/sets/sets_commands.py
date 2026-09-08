"""The cmd.set_* surface: entries in and out, selectors, flags, stage and peek (#415).

    pymol -ckqy testing/testing.py --run testing/tests/sets/sets_commands.py
"""
import os
import tempfile

from pymol import cmd, testing
from pymol.metrics import binding as mbinding, schema as mschema, store as mstore
from pymol.sets import binding, store
from pymol.sets.errors import (SetBudgetExceeded, SetFilterError, SetInputError,
                               SetNameConflict, SetNotFound)

TOOL = 'settest'


class SetCommandTestCase(testing.PyMOLTestCase):

    def setUp(self):
        testing.PyMOLTestCase.setUp(self)
        self._saved = dict(mschema._SCHEMAS)
        mschema.register(TOOL, [
            mschema.MetricSpec('score', mschema.OBJECT, lo=0, hi=100, higher_is_better=True),
            mschema.MetricSpec('rmsd', mschema.STATE, lo=0, hi=10, units='A'),
            mschema.MetricSpec('conf', mschema.RESIDUE, lo=0, hi=100),
        ], replace=True)
        store.reset()

    def tearDown(self):
        binding.clear_peek()
        store.reset()
        mstore.clear()
        mschema._SCHEMAS.clear()
        mschema._SCHEMAS.update(self._saved)
        testing.PyMOLTestCase.tearDown(self)

    def tmpdir(self):
        path = tempfile.mkdtemp()
        self.addCleanup(lambda: os.path.exists(path) and __import__('shutil').rmtree(path))
        return path

    def peptide(self, name, seq='ACDEF', score=50.0, rmsd=1.0):
        cmd.fab(seq, name, chain='A')
        index = sorted(mbinding.residue_index(name))
        mbinding.record(name, TOOL, [
            mstore.value(TOOL, 'score', value=score),
            mstore.value(TOOL, 'rmsd', value=rmsd, state=1),
            mstore.value(TOOL, 'conf', state=1, index=index,
                         values=[float(i * 10) for i in range(len(index))]),
        ], inputs={'seed': 1}, tool_version='t1')
        return name

    def populated(self, n=5):
        cmd.set_create('s')
        for i in range(n):
            self.peptide('p%d' % i, score=10.0 * (i + 1), rmsd=0.5 * (i + 1))
            cmd.set_add('s', 'p%d' % i)
            cmd.delete('p%d' % i)
        mstore.clear()
        return 's'


class CreateAndAdd(SetCommandTestCase):

    def testCreateListDeleteRename(self):
        cmd.set_create('a', note='first')
        cmd.set_create('b', kind='sequences')
        names = [s['name'] for s in cmd.set_list()]
        self.assertEqual(names, ['a', 'b'])
        self.assertRaises(SetNameConflict, cmd.set_create, 'a')
        self.assertRaises(SetInputError, cmd.set_create, 'bad name')
        cmd.set_rename('a', 'c')
        self.assertEqual([s['name'] for s in cmd.set_list()], ['c', 'b'])
        cmd.set_delete('c')
        self.assertEqual([s['name'] for s in cmd.set_list()], ['b'])
        self.assertRaises(SetNotFound, cmd.set_info, 'c')

    def testAddFromObjectCapturesChainsSequenceAndMetrics(self):
        cmd.set_create('s')
        self.peptide('pep', score=42.0, rmsd=1.5)
        names = cmd.set_add('s', 'pep')
        self.assertEqual(names, ['pep'])
        info = cmd.set_info('s')
        self.assertEqual(info['counts']['all'], 1)
        cols = {c['column']: c for c in info['columns']}
        self.assertIn('score', cols)
        self.assertIn('rmsd', cols)
        self.assertEqual(cols['score']['tool'], TOOL)
        got = cmd.set_get('s', 'pep')['pep']
        self.assertEqual(got['score'], 42.0)
        self.assertEqual(got['rmsd'], 1.5)
        index, values = cmd.set_get('s', 'pep', key='conf')['pep']
        self.assertEqual(len(index), 5)
        self.assertEqual(values[1], 10.0)
        entry = store.active().entry(store.active().get_set('s')['id'], 'pep')
        self.assertEqual(entry['n_chains'], 1)
        self.assertEqual(entry['sequences'], {'A': 'ACDEF'})
        chains = store.active().chain_cifs(entry['id'])
        self.assertEqual([c for c, _ in chains], ['A'])
        self.assertIn('data_', chains[0][1])

    def testAddMultiStateObjectMakesOneEntryPerState(self):
        cmd.set_create('s')
        cmd.fab('AAA', 'm', chain='A')
        cmd.create('m', 'm', 1, 2)
        self.assertEqual(cmd.count_states('m'), 2)
        self.assertEqual(cmd.set_add('s', 'm'), ['m_1', 'm_2'])
        self.assertEqual(cmd.set_add('s', 'm', entries='current'), ['m'],
                         'a single captured state takes the bare name')

    def testAddingTheSameNameTwiceIsSuffixed(self):
        cmd.set_create('s')
        self.peptide('pep')
        self.assertEqual(cmd.set_add('s', 'pep'), ['pep'])
        self.assertEqual(cmd.set_add('s', 'pep'), ['pep_2'])
        self.assertEqual(cmd.set_add('s', 'pep'), ['pep_3'])
        # A name TYPED for an entry is still refused on conflict, at the store.
        c = store.active()
        self.assertRaises(SetNameConflict, c.add_entry, c.get_set('s')['id'], 'pep')

    def testProvenanceArgumentsOnSetAdd(self):
        cmd.set_create('s')
        self.peptide('pep')
        cmd.set_add('s', 'pep', tool='rfd3', tool_version='3.0', inputs='{"seed": 7}')
        got = cmd.set_get('s', 'pep')['pep']
        c = store.active()
        run = c.run(got['run_id'])
        self.assertEqual((run['tool'], run['tool_version'], run['inputs']),
                         ('rfd3', '3.0', {'seed': 7}))
        self.assertEqual(sorted(cmd.set_get('s', 'run:%s' % got['run_id'])), ['pep'])
        self.assertEqual(cmd.set_add('s', 'pep', run=got['run_id'], parents=got['id']),
                         ['pep_2'])
        self.assertEqual(cmd.set_get('s', 'pep_2', key='parents')['pep_2'], [got['id']])
        self.assertRaises(SetNotFound, cmd.set_add, 's', 'pep', run='nosuch')
        self.assertRaises(SetInputError, cmd.set_add, 's', 'pep', tool='t', inputs='{bad')
        self.assertRaises(SetNotFound, cmd.set_get, 's', 'run:nosuch')

    def testAddFromFileAndFasta(self):
        cmd.set_create('s')
        d = self.tmpdir()
        cmd.fab('GGG', 'g', chain='B')
        path = os.path.join(d, 'g_design.pdb')
        cmd.save(path, 'g')
        cmd.delete('g')
        self.assertEqual(cmd.set_add('s', path), ['g_design'])
        self.assertFalse(binding.PEEK in cmd.get_names('all'), 'capture must clear the peek')
        fasta = os.path.join(d, 'seqs.fasta')
        with open(fasta, 'w') as h:
            h.write('>one\nMKT\n>two desc\nAAA\nCCC\n>one\nGG\n')
        self.assertEqual(cmd.set_add('s', fasta), ['one', 'two', 'one_2'])
        self.assertEqual(cmd.set_get('s', 'two')['two']['tags'], '')
        self.assertRaises(SetNotFound, cmd.set_add, 's', os.path.join(d, 'missing.pdb'))


class SelectorsAndFlags(SetCommandTestCase):

    def testSelectorsAndFlags(self):
        self.populated(5)
        self.assertEqual(len(cmd.set_list('s')), 5)
        cmd.set_star('s', 'p1+p3')
        self.assertEqual(sorted(e['name'] for e in cmd.set_list('s') if e['starred']), ['p1', 'p3'])
        cmd.set_reject('s', 'p0')
        cmd.set_tag('s', 'p1', 'nice')
        cmd.set_tag('s', 'p1', 'nice')
        self.assertEqual(cmd.set_get('s', 'p1')['p1']['tags'], 'nice')
        cmd.set_tag('s', 'p1', 'nice', remove=1)
        self.assertEqual(cmd.set_get('s', 'p1')['p1']['tags'], '')
        self.assertRaises(SetInputError, cmd.set_tag, 's', 'p1', 'two words')
        self.assertRaises(SetNotFound, cmd.set_star, 's', 'nosuch')
        self.assertRaises(SetInputError, cmd.set_get, 's', 'top:x')
        self.assertEqual(cmd.set_get('s', 'starred').keys() and
                         sorted(cmd.set_get('s', 'starred')), ['p1', 'p3'])

    def testFilterSortTopAndViews(self):
        self.populated(5)
        self.assertEqual(cmd.set_filter('s', 'score > 25'), 3)
        self.assertEqual(sorted(e['name'] for e in cmd.set_list('s')), ['p2', 'p3', 'p4'])
        cmd.set_sort('s', 'score', desc=1)
        self.assertEqual([e['name'] for e in cmd.set_list('s')], ['p4', 'p3', 'p2'])
        self.assertEqual(sorted(cmd.set_get('s', 'top:2')), ['p3', 'p4'])
        cmd.set_view_save('s', 'good')
        self.assertEqual(cmd.set_filter('s'), 5)
        self.assertEqual(sorted(cmd.set_get('s', 'view:good')), ['p2', 'p3', 'p4'])
        self.assertRaises(SetNotFound, cmd.set_get, 's', 'view:nosuch')
        cmd.set_view_delete('s', 'good')
        self.assertEqual(cmd.set_info('s')['views'], [])
        self.assertRaises(SetFilterError, cmd.set_filter, 's', 'nosuch > 1')
        self.assertEqual(cmd.set_info('s')['filter'], '', 'a bad filter must not be stored')
        self.assertRaises(SetInputError, cmd.set_sort, 's', 'nosuch')

    def testSetSetWritesNoteTagsAndUserColumnsOnly(self):
        self.populated(2)
        cmd.set_set('s', 'p0', 'note', 'hello')
        self.assertEqual(cmd.set_get('s', 'p0', key='note')['p0'], 'hello')
        self.assertEqual(cmd.set_get('s', 'p0')['p0']['note'], 'hello')
        # `score` was measured by a tool: read-only from here.
        self.assertRaises(SetInputError, cmd.set_set, 's', 'all', 'score', '7')
        c = store.active()
        c.declare_columns(c.get_set('s')['id'],
                          [{'key': 'rank', 'scope': 'object', 'dtype': 'int', 'tool': 'user'}])
        cmd.set_set('s', 'all', 'rank', '3')
        self.assertEqual(cmd.set_get('s', 'p1')['p1']['rank'], 3)
        self.assertRaises(SetInputError, cmd.set_set, 's', 'p0', 'nosuch', 1)

    def testSortSetsTheRankingKey(self):
        self.populated(2)
        cmd.set_sort('s', 'score')
        self.assertEqual(store.active().get_set('s')['ranking_key'], 'score')


class StageAndPeek(SetCommandTestCase):

    def testStageMakesObjectsInTheGroupWithMetrics(self):
        self.populated(3)
        names = cmd.set_stage('s', 'p0+p2')
        self.assertEqual(names, ['p0', 'p2'])
        self.assertIn('s', cmd.get_names('public_group_objects'))
        self.assertEqual(cmd.count_atoms('p0 and name CA'), 5)
        runs = mstore.runs(object='p2')
        self.assertEqual(len(runs), 1)
        self.assertEqual(runs[0].scalars()['score'], 30.0)
        self.assertEqual(len(runs[0].one('conf', state=1).values), 5)
        self.assertEqual(cmd.set_info('s')['counts']['staged'], 2)
        # Staging again is a no-op that returns the same names.
        self.assertEqual(cmd.set_stage('s', 'p0'), ['p0'])
        removed = cmd.set_unstage('s')
        self.assertEqual(sorted(removed), ['p0', 'p2'])
        self.assertNotIn('p0', cmd.get_names('all'))
        self.assertEqual(mstore.runs(object='p2'), [])
        self.assertNotIn('s', cmd.get_names('all'), 'an empty footprint group goes away')

    def testStageNameCollisionIsSuffixed(self):
        self.populated(1)
        cmd.fab('AAA', 'p0')
        names = cmd.set_stage('s', 'p0')
        self.assertEqual(names, ['p0_2'])
        self.assertEqual(cmd.set_get('s', 'p0')['p0']['staged'], 'p0_2')
        cmd.set_unstage('s')
        self.assertIn('p0', cmd.get_names('all'), 'the user\'s object is not ours to delete')

    def testBudgetRefusesAndNamesUnpinned(self):
        self.populated(4)
        cmd.set_budget(2, 's')
        cmd.set_stage('s', 'p0+p1')
        cmd.set_pin('s', 'p0')
        try:
            cmd.set_stage('s', 'p2')
        except SetBudgetExceeded as exc:
            self.assertEqual(list(exc.unpinned), ['p1'])
        else:
            self.fail('expected SetBudgetExceeded')
        self.assertEqual(cmd.set_stage('s', 'p2', budget=3), ['p2'])
        self.assertEqual(sorted(cmd.set_unstage('s')), ['p1', 'p2'], 'pinned p0 stays')
        self.assertIn('p0', cmd.get_names('all'))
        self.assertEqual(cmd.set_unstage('s', 'p0'), ['p0'], 'named explicitly, it goes')
        self.assertRaises(SetInputError, cmd.set_pin, 's', 'p3')
        cmd.set_budget(9)
        self.assertEqual(store.active().meta_get('stage_budget'), '9')
        self.assertRaises(SetInputError, cmd.set_budget, 0, 's')

    def testReferenceSuperposes(self):
        self.populated(1)
        cmd.fab('ACDEF', 'ref', chain='A')
        cmd.translate([10, 0, 0], 'ref')
        cmd.set_reference('s', 'ref')
        self.assertEqual(cmd.set_info('s')['reference'], 'ref')
        cmd.set_stage('s', 'p0')
        self.assertLess(cmd.rms_cur('p0 and name CA', 'ref and name CA'), 0.5)
        self.assertRaises(SetNotFound, cmd.set_reference, 's', 'nosuch')

    def testPeekIsHiddenAndReplaced(self):
        self.populated(2)
        self.assertEqual(cmd.set_peek('s', 'p0'), binding.PEEK)
        self.assertNotIn(binding.PEEK, cmd.get_names('public_objects'))
        self.assertIn(binding.PEEK, cmd.get_names('all'))
        n0 = cmd.count_atoms(binding.PEEK)
        cmd.set_peek('s', 'p1')
        self.assertEqual(cmd.count_atoms(binding.PEEK), n0, 'replaced, not appended')
        cmd.set_peek()
        self.assertNotIn(binding.PEEK, cmd.get_names('all'))
        self.assertRaises(SetInputError, cmd.set_peek, 's', 'all')

    def testRemoveUnstagesFirst(self):
        self.populated(2)
        cmd.set_stage('s', 'p1')
        self.assertEqual(cmd.set_remove('s', 'p1'), 1)
        self.assertNotIn('p1', cmd.get_names('all'))
        self.assertEqual(cmd.set_info('s')['counts']['all'], 1)

    def testMultiChainEntryStagesAsOneObject(self):
        cmd.set_create('s')
        cmd.fab('ACD', 'ca', chain='A')
        cmd.fab('EFGH', 'cb', chain='B')
        cmd.create('dimer', 'ca or cb')
        cmd.delete('ca or cb')
        cmd.set_add('s', 'dimer')
        cmd.delete('dimer')
        self.assertEqual(cmd.set_stage('s', 'dimer'), ['dimer'])
        self.assertEqual(cmd.get_chains('dimer'), ['A', 'B'])
        self.assertEqual(cmd.count_atoms('dimer and name CA'), 7)
        self.assertEqual([n for n in cmd.get_names('all') if n.startswith('_raymol_chain')], [])
        cmd.set_peek('s', 'dimer')
        self.assertEqual(cmd.get_chains(binding.PEEK), ['A', 'B'])

    def testEntryNamesFromObjectsAreSanitised(self):
        cmd.set_create('s')
        cmd.fab('AAA', 'starred')
        cmd.fab('AAA', 'ab')
        self.assertEqual(cmd.set_add('s', 'starred'), ['starred_'])
        self.assertEqual(cmd.set_add('s', 'ab'), ['ab'])
        self.assertEqual(sorted(cmd.set_get('s', 'starred')), [], 'the keyword still means the flag')
        self.assertEqual(sorted(cmd.set_get('s', 'starred_+ab')), ['ab', 'starred_'])
        self.assertRaises(SetInputError, store.active().add_entry,
                          store.active().get_set('s')['id'], 'a+b')

    def testChainScalarColumnsAreFilterable(self):
        cmd.set_create('s')
        cmd.fab('ACD', 'pc', chain='A')
        mschema.register('chaintool', [mschema.MetricSpec('iptm', mschema.CHAIN, lo=0, hi=1)],
                         replace=True)
        mbinding.record('pc', 'chaintool', [mstore.value('chaintool', 'iptm', value=0.9, chain='A')])
        cmd.set_add('s', 'pc')
        self.assertIn('iptm__a', [c['column'] for c in cmd.set_info('s')['columns']])
        self.assertEqual(cmd.set_filter('s', 'iptm__a > 0.5'), 1)

    def testARecycledObjectNameIsNotOursToDelete(self):
        self.populated(1)
        cmd.set_stage('s', 'p0')
        cmd.delete('p0')                       # the hook clears the link at once
        cmd.fab('GGGGGGGG', 'p0')              # the user's own object under that name
        self.assertEqual(cmd.set_unstage('s'), [])
        self.assertEqual(cmd.count_atoms('p0 and name CA'), 8, 'the user\'s p0 survives')

    def testRenamingAStagedObjectKeepsItsLink(self):
        self.populated(1)
        cmd.set_stage('s', 'p0')
        cmd.set_name('p0', 'renamed')
        self.assertEqual(cmd.set_get('s', 'p0')['p0']['staged'], 'renamed')
        self.assertEqual(cmd.set_unstage('s'), ['renamed'])
        self.assertNotIn('renamed', cmd.get_names('all'))

    def testAGhostLinkIsClearedWhenTheUserDeletesTheObject(self):
        self.populated(2)
        cmd.set_budget(1, 's')
        cmd.set_stage('s', 'p0')
        cmd.delete('p0')
        self.assertEqual(cmd.set_stage('s', 'p1'), ['p1'], 'the ghost does not count')
        cmd.delete('p1')
        self.assertEqual(cmd.set_stage('s', 'p1'), ['p1'], 're-staging a deleted object works')

    def testReconcileClearsLinksOfDeletedObjects(self):
        self.populated(1)
        cmd.set_stage('s', 'p0')
        cmd.delete('p0')
        binding.reconcile()
        self.assertEqual(cmd.set_info('s')['counts']['staged'], 0)
