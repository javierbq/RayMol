"""Batch delivery lands in a set; predict reads a set or view (#416).

    pymol -ckqy testing/testing.py --run testing/tests/sets/sets_batch.py

A fake generator and a fake predictor, delivered the way the Swift runtime delivers:
by calling `deliver_result(path, name, seed)` with the object name the job was given.
No host, no weights, no network. The generator's designs are jittered by seed so their
designed chains are distinct blobs, which is what makes "the target chain is ONE blob"
a statement about the target and not about identical inputs.
"""
import io
import os
import tempfile
import time
from contextlib import redirect_stdout

from pymol import cmd, testing
from pymol.metrics import schema as mschema, store as mstore
from pymol.sets import batch, binding, store
from pymol.sets.errors import SetError

#: `designing._max_designs` reads the generator CLASS's module for this. This file is
#: that module, so the fake can accept the batch sizes the issue's gate needs.
MAX_DESIGNS = 1000

GEN = 'fakegen'
PRED = 'fakepred'

_RESULTS = {'dir': None}


def _atom(serial, name, resn, chain, resi, x, y, z):
    padded = name if len(name) >= 4 else ' %-3s' % name
    return ('ATOM  %5d %s %3s %1s%4s    %8.3f%8.3f%8.3f  1.00  0.00          %2s'
            % (serial, padded, resn, chain or 'A', resi, x, y, z, name[0]))


class FakeDesignJob:
    """Reports done at once; writes target + a designed chain jittered by seed."""

    _counter = 0

    def __init__(self, spec, options, weights_path):
        FakeDesignJob._counter += 1
        self.job_id = '%s-%d' % (GEN, FakeDesignJob._counter)
        self.spec = spec
        self.options = options
        self.cancelled = False
        self.metrics_path = ''

    def status(self):
        return {'state': 'cancelled' if self.cancelled else 'done', 'phase': 'done',
                'fraction': 1.0, 'error': None,
                'result_path': None if self.cancelled else self.result_path,
                'peak_bytes': 2 ** 30, 'elapsed_s': 12.5}

    @property
    def result_path(self):
        # The PATH only, as a real host job's status reports it. The file is written by
        # `write()` at delivery: a `status()` that wrote a file would make the panel poll
        # in the thousand-member test measure the fake, not the poll.
        return os.path.join(_RESULTS['dir'], '%s.pdb' % self.job_id)

    def write(self):
        path = self.result_path
        if not os.path.exists(path):
            lines, serial = [], 1
            for residue in self.spec.target.residues:
                for name, (x, y, z) in residue.atoms:
                    lines.append(_atom(serial, name, residue.resn, residue.chain,
                                       residue.resi, x, y, z))
                    serial += 1
            lines.append('TER')
            # Distinct per JOB, not per seed modulo something: fifty random seeds
            # collide in any small modulus (measured: two did in 997), and this test
            # asserts on the blob count.
            jitter = int(self.job_id.rsplit('-', 1)[1]) * 0.01
            for index in range(self.spec.length):
                for offset, name in enumerate(('N', 'CA', 'C', 'O')):
                    lines.append(_atom(serial, name, 'GLY', self.spec.design_chain,
                                       str(index + 1),
                                       30.0 + index * 3.8 + offset * 0.5, 5.0 + jitter, 5.0))
                    serial += 1
            lines += ['TER', 'END']
            with open(path, 'w') as handle:
                handle.write('\n'.join(lines) + '\n')
        return path

    def cancel(self):
        self.cancelled = True


class FakePredictJob:
    """Reports done at once; writes one CA per residue, placed by the sequence."""

    _counter = 0

    def __init__(self, spec, options, weights_path):
        FakePredictJob._counter += 1
        self.job_id = '%s-%d' % (PRED, FakePredictJob._counter)
        self.spec = spec
        self.options = options
        self.cancelled = False
        self.metrics_path = ''

    def status(self):
        return {'state': 'done', 'phase': 'done', 'fraction': 1.0, 'error': None,
                'result_path': self.result_path, 'elapsed_s': 3.0, 'seed': self.options.seed}

    @property
    def result_path(self):
        return os.path.join(_RESULTS['dir'], '%s.pdb' % self.job_id)

    def write(self):
        path = self.result_path
        if not os.path.exists(path):
            from pymol.exporting import _resn_to_aa
            aa_to_resn = {v: k for k, v in _resn_to_aa.items()}
            lines, serial = [], 1
            for chain, sequence in self.spec.chains:
                for i, letter in enumerate(sequence):
                    lines.append(_atom(serial, 'CA', aa_to_resn.get(letter, 'GLY'), chain,
                                       str(i + 1), i * 3.8, ord(letter) * 0.1,
                                       self.options.seed % 7))
                    serial += 1
                lines.append('TER')
            lines.append('END')
            with open(path, 'w') as handle:
                handle.write('\n'.join(lines) + '\n')
        return path

    def cancel(self):
        self.cancelled = True


def _install_fakes():
    from pymol.generators import registry as greg
    from pymol.generators.base import DesignSpec, Generator, require_single_chain
    from pymol.generators.metrics import DESIGN_SPECS
    from pymol.predictors import registry as preg
    from pymol.predictors.base import Predictor, PredictionSpec, parse_chains
    from pymol.predictors.metrics import SCORED_SPECS

    class FakeGen(Generator):
        id = GEN
        name = 'Fake generator'
        weight_bundle = None
        metric_specs = DESIGN_SPECS
        progress_phases = (('diffusion', 0.0, 1.0),)

        def check_available(self):
            return None

        def parse_target(self, target, length, name=''):
            require_single_chain(target.residues)
            return DesignSpec(target, length, name=name, generator_id=self.id,
                              design_chain='B')

        def submit(self, spec, options, weights_path):
            return FakeDesignJob(spec, options, weights_path)

    class FakePred(Predictor):
        id = PRED
        name = 'Fake predictor'
        weight_bundle = None
        metric_specs = SCORED_SPECS

        def check_available(self):
            return None

        def parse_spec(self, sequence, name=''):
            return PredictionSpec(parse_chains(sequence), name)

        def submit(self, spec, options, weights_path):
            return FakePredictJob(spec, options, weights_path)

    greg.register(FakeGen(), replace=True)
    preg.register(FakePred(), replace=True)


def deliver_designs(jobs):
    from pymol import designing
    for job in (jobs if isinstance(jobs, (list, tuple)) else [jobs]):
        status = job.status()
        if status['state'] == 'done':
            job.write()
            designing.deliver_result(status['result_path'], job.spec.name,
                                     seed=job.options.seed)


def deliver_models(jobs):
    from pymol import predicting
    for job in (jobs if isinstance(jobs, (list, tuple)) else [jobs]):
        status = job.status()
        job.write()
        predicting.deliver_result(status['result_path'], job.spec.name,
                                  seed=job.options.seed)


class BatchTestCase(testing.PyMOLTestCase):

    def setUp(self):
        testing.PyMOLTestCase.setUp(self)
        from pymol.generators import registry as greg
        from pymol.predictors import registry as preg
        self._gens = {gid: greg.get(gid) for gid in greg.available()}
        self._preds = {pid: preg.get(pid) for pid in preg.available()}
        self._schemas = dict(mschema._SCHEMAS)
        _RESULTS['dir'] = tempfile.mkdtemp()
        store.reset()
        batch.clear()
        _install_fakes()

    def tearDown(self):
        from pymol import designing, predicting
        from pymol.generators import registry as greg
        from pymol.predictors import registry as preg
        for module in (designing, predicting):
            try:
                module.clear_pending()
            except Exception:
                pass
            module._JOBS.clear()
        batch.clear()
        binding.clear_peek()
        store.reset()
        mstore.clear()
        for gid in list(greg.available()):
            if gid not in self._gens:
                greg.unregister(gid)
        for pid in list(preg.available()):
            if pid not in self._preds:
                preg.unregister(pid)
        mschema._SCHEMAS.clear()
        mschema._SCHEMAS.update(self._schemas)
        __import__('shutil').rmtree(_RESULTS['dir'], ignore_errors=True)
        testing.PyMOLTestCase.tearDown(self)

    # -- helpers --------------------------------------------------------------------

    def helix(self, name='tgt', length=12):
        cmd.fab('A' * length, name, ss=1)
        cmd.alter(name, 'chain="A"')
        cmd.sort(name)
        return name

    def design(self, n, **kwargs):
        self.helix()
        return cmd.binder_design(GEN, 'tgt', 'tgt and resi 5', length=6, n_designs=n,
                                 **kwargs)

    @staticmethod
    def groups():
        return list(cmd.get_names('public_group_objects') or [])

    @staticmethod
    def children(group):
        return [entry[0] for entry in (cmd.get_session(partial=1).get('names') or [])
                if entry and len(entry) > 6 and entry[6] == group]

    @staticmethod
    def only_set():
        sets = store.active().sets()
        assert len(sets) == 1, [s['name'] for s in sets]
        return sets[0]

    @staticmethod
    def staged(set_row):
        return [e for e in store.active().entries(set_row['id'])
                if e.get('staged_object')]


class FiftyDesigns(BatchTestCase):

    def testFiftyDesignsLandInASetWithBudgetStagedAndOneTargetBlob(self):
        jobs = self.design(50)
        self.assertEqual(len(jobs), 50)
        c = store.active()
        row = self.only_set()
        self.assertEqual(row['tool'], GEN)
        self.assertEqual(row['reference'], 'tgt')
        self.assertEqual(row['group_name'], row['name'])
        # BEFORE delivery: placeholders only for what will be staged; the tray sees all 50.
        from pymol import designing
        self.assertEqual(len(designing._PENDING), 50)
        placeholders = [n for n in cmd.get_names('objects') if n != 'tgt'
                        and n not in self.groups()]
        self.assertEqual(len(placeholders), binding.DEFAULT_BUDGET, placeholders)
        self.assertEqual(batch.running(),
                         {row['id']: {'done': 0, 'total': 50, 'tool': GEN}})
        runs = c.runs(row['id'])
        self.assertEqual(len(runs), 1)
        self.assertEqual(len(runs[0]['inputs']['seeds']), 50)
        self.assertEqual(runs[0]['inputs']['n_designs'], 50)
        self.assertEqual(runs[0]['inputs']['design_length'], 6)

        deliver_designs(jobs)

        self.assertEqual(c.count(row['id']), 50)
        staged = self.staged(row)
        self.assertEqual(len(staged), binding.DEFAULT_BUDGET)
        group = row['group_name']
        self.assertEqual(self.groups(), [group])
        self.assertEqual(sorted(self.children(group)),
                         sorted(e['staged_object'] for e in staged))
        # The Objects panel never saw more than the footprint: target, group, 6 designs.
        molecules = [n for n in cmd.get_names('objects') if n not in self.groups()]
        self.assertEqual(len(molecules), 1 + binding.DEFAULT_BUDGET, molecules)
        for e in staged:
            self.assertEqual(sorted(cmd.get_chains(e['staged_object'])), ['A', 'B'])
        # The target chain is ONE blob; every designed chain its own.
        stats = c.blob_stats()
        print(' sets_batch: blob_stats after 50 designs: %r' % (stats,))
        self.assertEqual(stats['count'], 51, stats)
        # Columns from DESIGN_SPECS plus the seed; every entry carries its numbers.
        columns = {col['column'] for col in c.columns(row['id']) if col.get('column')}
        self.assertIn('design_length', columns)
        self.assertIn('design_key', columns)
        self.assertIn('seed', columns)
        self.assertIn('elapsed_s', columns)
        self.assertNotIn('n_residues', columns)      # an entries field, not a column
        entries = c.entries(row['id'])
        self.assertEqual(sorted(e['scalars']['seed'] for e in entries),
                         sorted(runs[0]['inputs']['seeds']))
        self.assertTrue(all(e['scalars']['design_length'] == 6 for e in entries))
        self.assertTrue(all(e['n_chains'] == 2 for e in entries))
        self.assertTrue(all(e['run_id'] == runs[0]['id'] for e in entries))
        self.assertTrue(all(e['sequences'].get('B') for e in entries))
        # Every member settled: the badge is gone, the pending tables are empty.
        self.assertEqual(batch.running(), {})
        self.assertEqual(designing._PENDING, {})
        self.assertEqual(designing._BATCH, {})

        # And the document reopens to the same state.
        path = os.path.join(_RESULTS['dir'], 'fifty.raymol')
        with redirect_stdout(io.StringIO()):
            cmd.save(path)
            # `reinitialize`, not `delete all`: Save made the document the live
            # container, and deleting the objects first would reconcile the links away
            # IN that document before it was reopened (as it should -- the objects are
            # gone). A fresh session is what "reopen tomorrow" looks like.
            cmd.reinitialize()
            self.assertEqual(store.active().sets(), [])
            cmd.load(path)
        c = store.active()
        again = c.get_set(row['id'])
        self.assertEqual(c.count(again['id']), 50)
        self.assertEqual(c.blob_stats()['count'], 51)
        self.assertEqual(sorted(e['staged_object'] for e in self.staged(again)),
                         sorted(e['staged_object'] for e in staged))
        self.assertEqual(sorted(self.children(group)),
                         sorted(e['staged_object'] for e in staged))

    def testTheBudgetIsReadFromTheStoreAndCountsLiveLinks(self):
        cmd.set_budget(2)
        jobs = self.design(5)
        row = self.only_set()
        placeholders = [n for n in cmd.get_names('objects') if n != 'tgt'
                        and n not in self.groups()]
        self.assertEqual(len(placeholders), 2)
        deliver_designs(jobs[:3])
        self.assertEqual(len(self.staged(row)), 2)
        # The user drops a staged design: the slot is free for the next one to land.
        cmd.delete(self.staged(row)[0]['staged_object'])
        deliver_designs(jobs[3:])
        c = store.active()
        self.assertEqual(c.count(row['id']), 5)
        self.assertEqual(len(self.staged(row)), 2)
        self.assertEqual(sorted(self.children(row['group_name'])),
                         sorted(e['staged_object'] for e in self.staged(row)))
        # An unstaged entry comes back by hand, and staging refuses past the budget.
        unstaged = [e for e in c.entries(row['id']) if not e.get('staged_object')]
        self.assertEqual(len(unstaged), 3)
        from pymol.sets.errors import SetBudgetExceeded
        self.assertRaises(SetBudgetExceeded, cmd.set_stage, row['name'], unstaged[0]['name'])
        cmd.set_unstage(row['name'])
        names = cmd.set_stage(row['name'], unstaged[0]['name'])
        self.assertEqual(sorted(cmd.get_chains(names[0])), ['A', 'B'])

    def testAFailedMemberFreesItsSlotAndSettles(self):
        jobs = self.design(3)
        row = self.only_set()
        from pymol import designing
        jobs[0].cancel()
        designing.discard_pending(jobs[0].spec.name)
        self.assertEqual(batch.running()[row['id']]['done'], 1)
        deliver_designs(jobs[1:])
        self.assertEqual(store.active().count(row['id']), 2)
        self.assertEqual(batch.running(), {})

    def testABatchThatLandsNothingLeavesNoSet(self):
        jobs = self.design(3)
        from pymol import designing
        for job in jobs:
            job.cancel()
            designing.discard_pending(job.spec.name)
        self.assertEqual(store.active().sets(), [])
        self.assertEqual(self.groups(), [])
        self.assertEqual(batch.running(), {})

    def testAnIdenticalRerunExtendsItsSetAsItLandsBackInItsGroup(self):
        jobs = self.design(2, seed=7)
        deliver_designs(jobs)
        first = self.only_set()
        again = cmd.binder_design(GEN, 'tgt', 'tgt and resi 5', length=6, n_designs=2,
                                  seed=7)
        deliver_designs(again)
        c = store.active()
        self.assertEqual([s['name'] for s in c.sets()], [first['name']])
        self.assertEqual(self.groups(), [first['name']])
        self.assertEqual(c.count(first['id']), 4)
        self.assertEqual(len(c.runs(first['id'])), 2)
        self.assertEqual(len(self.staged(first)), 4)
        # Only the FIRST design repeats its seed (the rest are drawn fresh), so exactly
        # that design key is two ENTRIES, `_2` on the second, as it is two objects; the
        # target chain is still one blob.
        self.assertEqual(again[0].spec.name, jobs[0].spec.name + '_2')
        names = [e['name'] for e in c.entries(first['id'])]
        self.assertIn(jobs[0].spec.name, names)
        self.assertIn(jobs[0].spec.name + '_2', names)
        self.assertEqual(c.blob_stats()['count'], 5)

    def testASetOfAnotherToolUnderTheBatchNameIsLeftAlone(self):
        self.helix()
        cmd.set_create('mine')
        jobs = cmd.binder_design(GEN, 'tgt', 'tgt and resi 5', length=6, n_designs=2,
                                 name='mine')
        deliver_designs(jobs)
        c = store.active()
        self.assertEqual([s['name'] for s in c.sets()], ['mine', 'mine_2'])
        self.assertEqual(c.count(c.get_set('mine')['id']), 0)
        self.assertEqual(c.count(c.get_set('mine_2')['id']), 2)
        self.assertEqual(self.groups(), ['mine_2'])


class SingleDesign(BatchTestCase):

    def testASingleDesignLooksLikeTodayPlusAStagedOneEntrySet(self):
        job = self.design(1)
        from pymol import designing
        self.assertEqual(designing._BATCH, {})
        self.assertIn(job.spec.name, cmd.get_names('objects'))
        self.assertEqual(self.groups(), [])
        deliver_designs(job)
        self.assertEqual(self.groups(), [])
        self.assertEqual(sorted(cmd.get_chains(job.spec.name)), ['A', 'B'])
        self.assertIsNone(designing.pending_info(job.spec.name))
        row = self.only_set()
        self.assertTrue(row['name'].startswith('%s_batch_' % GEN), row['name'])
        c = store.active()
        entries = c.entries(row['id'])
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]['staged_object'], job.spec.name)
        self.assertEqual(entries[0]['name'], job.spec.name)
        self.assertEqual(c.blob_stats()['count'], 2)
        self.assertEqual(batch.running(), {})
        # A second single design against the same target shares the target blob.
        job2 = cmd.binder_design(GEN, 'tgt', 'tgt and resi 5', length=6)
        deliver_designs(job2)
        self.assertEqual(c.blob_stats()['count'], 3)


class PredictOverASet(BatchTestCase):

    def parent(self, n=4):
        jobs = self.design(n)
        deliver_designs(jobs)
        return self.only_set()

    def testTopTwoWithThreeModelsIsAChildSetOfSixWithParentLinks(self):
        parent = self.parent(4)
        c = store.active()
        top2 = c.entries(parent['id'])[:2]
        jobs = cmd.predict(PRED, 'set:%s@top:2' % parent['name'], n_models=3)
        self.assertEqual(len(jobs), 6)
        child = c.get_set('%s_1' % PRED)
        self.assertEqual(child['tool'], PRED)
        self.assertEqual(child['reference'], 'tgt')
        runs = c.runs(child['id'])
        self.assertEqual(len(runs), 1)
        self.assertEqual(runs[0]['parent_set_id'], parent['id'])
        self.assertEqual(runs[0]['inputs']['parents'], [e['id'] for e in top2])
        self.assertEqual(runs[0]['inputs']['selector'], 'top:2')
        self.assertEqual(runs[0]['inputs']['n_models'], 3)
        self.assertEqual(batch.running()[child['id']],
                         {'done': 0, 'total': 6, 'tool': PRED})

        deliver_models(jobs)

        entries = c.entries(child['id'])
        self.assertEqual(len(entries), 6)
        by_parent = {}
        for e in entries:
            self.assertEqual(len(e['parents']), 1)
            by_parent.setdefault(e['parents'][0], []).append(e['scalars']['model'])
            self.assertEqual(e['run_id'], runs[0]['id'])
            self.assertIn('seed', e['scalars'])
            self.assertIn('elapsed_s', e['scalars'])
        self.assertEqual(sorted(by_parent), sorted(e['id'] for e in top2))
        for models in by_parent.values():
            self.assertEqual(sorted(models), [1, 2, 3])
        # Names: <parent>_m<k>, sequences inherited from the parent.
        for e in entries:
            parent_entry = c.entry_by_id(e['parents'][0])
            self.assertTrue(e['name'].startswith(parent_entry['name'] + '_m'), e['name'])
            self.assertEqual(e['sequences'], parent_entry['sequences'])
        # Within budget (6): every model is a staged object in the child's group.
        staged = self.staged(child)
        self.assertEqual(len(staged), 6)
        self.assertEqual(sorted(self.children(child['group_name'])),
                         sorted(e['staged_object'] for e in staged))
        self.assertEqual(batch.running(), {})
        from pymol import predicting
        self.assertEqual(predicting._PENDING, {})

    def testOneModelKeepsTheParentsNameAndBeyondBudgetIsEntriesOnly(self):
        cmd.set_budget(2)
        parent = self.parent(4)
        c = store.active()
        jobs = cmd.predict(PRED, 'set:%s' % parent['name'])     # filtered = all four
        self.assertEqual(len(jobs), 4)
        deliver_models(jobs)
        child = c.get_set('%s_1' % PRED)
        entries = c.entries(child['id'])
        self.assertEqual([e['name'] for e in entries],
                         [e['name'] for e in c.entries(parent['id'])])
        self.assertEqual(len(self.staged(child)), 2)
        # Objects in the session: target, the parent's two staged, the child's two.
        molecules = [n for n in cmd.get_names('objects') if n not in self.groups()]
        self.assertEqual(len(molecules), 5, molecules)

    def testASecondPredictNumbersItsChildSetAndNameIsHonoured(self):
        parent = self.parent(2)
        c = store.active()
        deliver_models(cmd.predict(PRED, 'set:%s@top:1' % parent['name']))
        deliver_models(cmd.predict(PRED, 'set:%s@top:1' % parent['name']))
        deliver_models(cmd.predict(PRED, 'set:%s@top:1' % parent['name'], name='folds'))
        self.assertEqual([s['name'] for s in c.sets()],
                         [parent['name'], '%s_1' % PRED, '%s_2' % PRED, 'folds'])
        from pymol.predictors.errors import PredictionInputError
        self.assertRaises(PredictionInputError, cmd.predict, PRED,
                          'set:%s@top:1' % parent['name'], name='folds')

    def testBadSetInputsAreRefusedByName(self):
        from pymol.predictors.errors import PredictionInputError
        from pymol.sets.errors import SetNotFound
        parent = self.parent(2)
        self.assertRaises(SetNotFound, cmd.predict, PRED, 'set:nope')
        self.assertRaises(SetNotFound, cmd.predict, PRED,
                          'set:%s@d_nope' % parent['name'])
        self.assertRaises(PredictionInputError, cmd.predict, PRED, 'set:')
        cmd.set_create('seqs', kind='sequences')
        store.active().add_entry(store.active().get_set('seqs')['id'], 'empty')
        self.assertRaises(PredictionInputError, cmd.predict, PRED, 'set:seqs')
        self.assertEqual(batch.running(), {})

    def testASequenceOnlySetFoldsToo(self):
        cmd.set_create('seqs', kind='sequences')
        c = store.active()
        sid = c.get_set('seqs')['id']
        c.add_entry(sid, 's1', sequences={'A': 'ACDEFG'})
        c.add_entry(sid, 's2', sequences={'A': 'GGGGKK', 'B': 'AAA'})
        jobs = cmd.predict(PRED, 'set:seqs')
        deliver_models(jobs)
        child = c.get_set('%s_1' % PRED)
        entries = c.entries(child['id'])
        self.assertEqual([e['name'] for e in entries], ['s1', 's2'])
        self.assertEqual(entries[1]['sequences'], {'A': 'GGGGKK', 'B': 'AAA'})
        self.assertEqual(entries[1]['n_chains'], 2)
        self.assertTrue(all(e['staged_object'] for e in entries))

    def testTheLiteralPathIsUntouched(self):
        jobs = cmd.predict(PRED, 'ACDEFGH', n_models=2)
        deliver_models(jobs)
        name = jobs[0].spec.name
        self.assertEqual(cmd.count_states(name), 2)
        self.assertEqual(store.active().sets(), [])
        self.assertEqual(batch.running(), {})


class GenerationCheck(BatchTestCase):

    def testLandRefusesAfterTheStoreChangedUnderTheBatch(self):
        jobs = self.design(3)
        deliver_designs(jobs[:1])
        row = self.only_set()
        self.assertEqual(store.active().count(row['id']), 1)
        # Another document arrives mid-batch.
        other = os.path.join(_RESULTS['dir'], 'other.raymol')
        store.Container(other).close()
        with redirect_stdout(io.StringIO()):
            cmd.load(other)
        self.assertEqual(store.active().sets(), [])
        self.assertEqual(batch.running()[row['id']]['done'], 1)   # not yet detached
        # The next delivery's write is refused, cleanly, ONCE -- and the design is kept
        # as a plain grouped object, with a warning rather than an exception.
        out = io.StringIO()
        with redirect_stdout(out):
            deliver_designs(jobs[1:2])
        self.assertIn('was not written to its set', out.getvalue())
        self.assertIn('document changed', out.getvalue())
        self.assertEqual(batch.running(), {})                    # detached
        self.assertIsNone(batch.land(jobs[2].spec.name))         # no second raise
        out = io.StringIO()
        with redirect_stdout(out):
            deliver_designs(jobs[2:])
        self.assertNotIn('was not written', out.getvalue())
        for job in jobs[1:]:
            self.assertIn(job.spec.name, cmd.get_names('objects'))
            self.assertEqual(sorted(cmd.get_chains(job.spec.name)), ['A', 'B'])
        self.assertEqual(sorted(self.children(row['name'])),
                         sorted(j.spec.name for j in jobs[1:]))
        self.assertEqual(store.active().sets(), [])              # nothing written here

    def testLandRaisesOnceOnAGenerationChangeWithoutASession(self):
        # The store-level contract, without deliver_result in the way.
        cmd.fab('ACDEFG', 'src', chain='A')
        b = batch.open('direct', 'user', total=1, group=False)
        self.assertTrue(batch.expect(b, 'src'))
        store.reset()
        self.assertRaises(SetError, batch.land, 'src')
        self.assertIsNone(batch.land('src'))
        self.assertEqual(batch.running(), {})

    def testAPseSaveMidBatchCarriesStagedDesignsAndWarnsAboutTheSet(self):
        jobs = self.design(3)
        deliver_designs(jobs[:2])
        row = self.only_set()
        path = os.path.join(_RESULTS['dir'], 'mid.pse')
        out = io.StringIO()
        with redirect_stdout(out):
            cmd.save(path)
        self.assertIn(row['name'], out.getvalue())
        with redirect_stdout(io.StringIO()):
            cmd.load(path)
        molecules = [n for n in cmd.get_names('objects') if n not in self.groups()]
        self.assertEqual(sorted(molecules), sorted(['tgt'] + [j.spec.name for j in jobs[:2]]))
        self.assertEqual(store.active().sets(), [])


class Running(BatchTestCase):

    def testRunningIsCheapAndNeverRaises(self):
        self.assertEqual(batch.running(), {})
        jobs = self.design(3)
        row = self.only_set()
        self.assertEqual(batch.running(row['id'])[row['id']]['total'], 3)
        self.assertEqual(batch.running('nope'), {})
        started = time.perf_counter()
        for _ in range(1000):
            batch.running()
        per_call = (time.perf_counter() - started) / 1000
        print(' sets_batch: running() %.1f us per call' % (per_call * 1e6))
        self.assertLess(per_call, 1e-3)
        deliver_designs(jobs)

    def testAThousandPendingMembersKeepThePanelPollAffordable(self):
        from pymol import designing
        from pymol import appkit_inspector
        jobs = self.design(1000)
        self.assertEqual(len(designing._PENDING), 1000)
        molecules = [n for n in cmd.get_names('objects') if n not in self.groups()]
        self.assertEqual(len(molecules), 1 + binding.DEFAULT_BUDGET)
        started = time.perf_counter()
        details, records = appkit_inspector._pending_maps('designing')
        elapsed = time.perf_counter() - started
        print(' sets_batch: _pending_maps over 1000 pending designs: %.1f ms' % (elapsed * 1e3))
        self.assertEqual(len(records), 1000)
        # MEASURED before the `_batch_frontier` prefix cache: 200 ms, 170 of them in the
        # frontier rescan. After: tens of ms. Loose bound so a slow CI does not fail it.
        self.assertLess(elapsed, 0.5)
        row = self.only_set()
        self.assertEqual(batch.running()[row['id']]['total'], 1000)
