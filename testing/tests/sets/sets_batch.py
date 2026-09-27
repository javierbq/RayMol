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
from unittest.mock import patch

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
        ranking_metrics = ('min_ipsae', 'mean_plddt')     # as boltz2 declares (#546)

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
        # Every test gets its own $RAYMOL_SETS_DIR (#447 review): the working
        # container -- and anything preserved from it -- otherwise lands in the real
        # $TMPDIR, where it accumulates a few MB per run and where the retention sweep
        # would take a CLI user's own recovered sessions with it.
        self._sets_dir = tempfile.mkdtemp(prefix='raymol_sets_dir_')
        self._had_sets_dir = os.environ.get('RAYMOL_SETS_DIR')
        os.environ['RAYMOL_SETS_DIR'] = self._sets_dir
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
        # Last, so PyMOLTestCase's own reinitialize still resets the store with the
        # private $RAYMOL_SETS_DIR in place.
        if self._had_sets_dir is None:
            os.environ.pop('RAYMOL_SETS_DIR', None)
        else:
            os.environ['RAYMOL_SETS_DIR'] = self._had_sets_dir
        __import__('shutil').rmtree(self._sets_dir, ignore_errors=True)

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

    @staticmethod
    def target(set_row):
        """The set's shared target object (#545), or ''."""
        return binding.shared_target_object(store.active(), set_row['id'])


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
        # Six binders over ONE shared target (#545), not six complexes.
        target = self.target(row)
        self.assertEqual(target, 'target_%s' % group)
        # And the group's name still selects the whole group, not the target alone:
        # `<set>_target` would be a unique prefix match for it (see `target_name`).
        self.assertEqual(sorted(cmd.get_object_list(group)),
                         sorted([e['staged_object'] for e in staged] + [target]))
        self.assertEqual(sorted(self.children(group)),
                         sorted([e['staged_object'] for e in staged] + [target]))
        # The Objects panel never saw more than the footprint: the design target, the
        # group, 6 designs and their shared target.
        molecules = [n for n in cmd.get_names('objects') if n not in self.groups()]
        self.assertEqual(len(molecules), 2 + binding.DEFAULT_BUDGET, molecules)
        for e in staged:
            self.assertEqual(cmd.get_chains(e['staged_object']), ['B'])
            self.assertEqual(e['design_chains'], ['B'])
        self.assertEqual(cmd.get_chains(target), ['A'])
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
        self.assertEqual(self.target(again), target)
        self.assertEqual(sorted(self.children(group)),
                         sorted([e['staged_object'] for e in staged] + [target]))

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
                         sorted([e['staged_object'] for e in self.staged(row)]
                                + [self.target(row)]))
        # An unstaged entry comes back by hand, and staging refuses past the budget.
        unstaged = [e for e in c.entries(row['id']) if not e.get('staged_object')]
        self.assertEqual(len(unstaged), 3)
        from pymol.sets.errors import SetBudgetExceeded
        self.assertRaises(SetBudgetExceeded, cmd.set_stage, row['name'], unstaged[0]['name'])
        cmd.set_unstage(row['name'])
        self.assertEqual(self.target(row), '', 'the last unstage takes the target')
        names = cmd.set_stage(row['name'], unstaged[0]['name'])
        self.assertEqual(cmd.get_chains(names[0]), ['B'])
        self.assertEqual(cmd.get_chains(self.target(row)), ['A'])

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

    def testASingleDesignNeverLosesItsObjectToAFullSet(self):
        # Review fix 2 (n=1): with budget 2, the third identical single design used to
        # get a placeholder, land, be measured and then have its object deleted with an
        # empty console. It gets its own set instead and stays on screen.
        cmd.set_budget(2)
        self.helix()
        jobs = []
        out = io.StringIO()
        with redirect_stdout(out):
            for _ in range(3):
                # Delivered before the next is submitted: three CONCURRENT batches
                # correctly get a set each (a live batch id is taken), so the case
                # under test is the sequential one a user actually runs.
                job = cmd.binder_design(GEN, 'tgt', 'tgt and resi 5', length=6, seed=7)
                deliver_designs(job)
                jobs.append(job)
        c = store.active()
        names = [s['name'] for s in c.sets()]
        self.assertEqual(len(names), 2)
        self.assertEqual(names[1], names[0] + '_2')
        for job in jobs:
            self.assertIn(job.spec.name, cmd.get_names('objects'))
            self.assertEqual(sorted(cmd.get_chains(job.spec.name)), ['A', 'B'])
        self.assertEqual(len(self.staged(c.get_set(names[0]))), 2)
        self.assertEqual(len(self.staged(c.get_set(names[1]))), 1)
        self.assertEqual(self.groups(), [])
        self.assertNotIn('budget full', out.getvalue())

    def testExtendingAFullSetMakesNoPlaceholderAndSaysWhereTheDesignWent(self):
        # Review fixes 2 (n>1) and 4: a re-run into a set with no free slot creates no
        # placeholder it would then delete, and every over-budget landing is announced.
        cmd.set_budget(2)
        first = self.design(2, seed=7)
        deliver_designs(first)
        row = self.only_set()
        before = sorted(cmd.get_names('objects'))
        again = cmd.binder_design(GEN, 'tgt', 'tgt and resi 5', length=6, n_designs=2,
                                  seed=7)
        self.assertEqual(sorted(cmd.get_names('objects')), before,
                         'no placeholder for a member that cannot be staged')
        out = io.StringIO()
        with redirect_stdout(out):
            deliver_designs(again)
        c = store.active()
        self.assertEqual([s['name'] for s in c.sets()], [row['name']])
        self.assertEqual(c.count(row['id']), 4)
        self.assertEqual(len(self.staged(row)), 2)
        self.assertEqual(sorted(cmd.get_names('objects')), before)
        self.assertEqual(out.getvalue().count('budget full'), 2)
        self.assertIn('set_stage %s' % row['name'], out.getvalue())

    def testASetBuiltAgainstAnotherTargetIsNotExtended(self):
        # Review fix 3: same tool, same name, different reference -> a second set, or
        # `predict set:` would superpose the new designs on the old target.
        self.helix('tgt')
        self.helix('tgt2', length=9)
        jobs = cmd.binder_design(GEN, 'tgt', 'tgt and resi 5', length=6, n_designs=2,
                                 name='camp')
        deliver_designs(jobs)
        cmd.set_unstage('camp', 'all')
        jobs2 = cmd.binder_design(GEN, 'tgt2', 'tgt2 and resi 5', length=6, n_designs=2,
                                  name='camp')
        deliver_designs(jobs2)
        c = store.active()
        self.assertEqual([s['name'] for s in c.sets()], ['camp', 'camp_2'])
        self.assertEqual(c.get_set('camp')['reference'], 'tgt')
        self.assertEqual(c.get_set('camp_2')['reference'], 'tgt2')
        self.assertEqual(c.count(c.get_set('camp')['id']), 2)
        self.assertEqual(c.count(c.get_set('camp_2')['id']), 2)


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
        # Objects in the session: target, the parent's two staged binders and their
        # shared target, the child's two -- whole: a fold is never split (#545).
        molecules = [n for n in cmd.get_names('objects') if n not in self.groups()]
        self.assertEqual(len(molecules), 6, molecules)
        self.assertEqual(self.target(child), '')
        for e in self.staged(child):
            self.assertEqual(sorted(cmd.get_chains(e['staged_object'])), ['A', 'B'])

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

    def testASingleModelOfASingleEntryMakesNoGroup(self):
        # Review fix 11: as for a single design, a group of one is noise.
        parent = self.parent(2)
        jobs = cmd.predict(PRED, 'set:%s@top:1' % parent['name'])
        deliver_models(jobs)
        c = store.active()
        child = c.get_set('%s_1' % PRED)
        self.assertEqual(len(self.staged(child)), 1)
        self.assertEqual(self.groups(), [parent['group_name']])
        self.assertIn(jobs[0].spec.name, cmd.get_names('objects'))

    def testARefusedMemberLeavesNoJobRunningAndNoSet(self):
        # Review fix 10: expect() runs BEFORE submit, and a failed submit loop cancels
        # what it started.
        from pymol import predicting
        from pymol.sets.errors import SetInputError
        parent = self.parent(2)
        submitted = FakePredictJob._counter
        with patch.object(batch, 'expect', side_effect=SetInputError('refused')):
            self.assertRaises(SetInputError, cmd.predict, PRED,
                              'set:%s' % parent['name'])
        self.assertEqual(FakePredictJob._counter, submitted, 'nothing was submitted')
        self.assertEqual(predicting._PENDING, {})
        self.assertEqual([s['name'] for s in store.active().sets()], [parent['name']])
        self.assertEqual(batch.running(), {})

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
        cmd.set_budget(1)
        jobs = self.design(3)
        deliver_designs(jobs[:2])                      # one staged, one entry-only
        row = self.only_set()
        path = os.path.join(_RESULTS['dir'], 'mid.pse')
        out = io.StringIO()
        with redirect_stdout(out):
            cmd.save(path)
        self.assertIn(row['name'], out.getvalue())
        with redirect_stdout(io.StringIO()):
            cmd.load(path)
        # The shared target goes into the .pse as the plain object it is (#545).
        molecules = [n for n in cmd.get_names('objects') if n not in self.groups()]
        self.assertEqual(sorted(molecules), sorted(['tgt', jobs[0].spec.name,
                                                    'target_%s' % row['name']]))
        self.assertEqual(cmd.get_chains(jobs[0].spec.name), ['B'])
        self.assertEqual(store.active().sets(), [])

    def testAPseSaveIsQuietWhenEverySetEntryIsStaged(self):
        # Review fix 7: since every single design has a one-entry set behind it, the
        # ".pse cannot hold sets" warning must not fire when nothing is actually lost.
        job = self.design(1)
        deliver_designs(job)
        out = io.StringIO()
        with redirect_stdout(out):
            cmd.save(os.path.join(_RESULTS['dir'], 'one.pse'))
        self.assertNotIn('cannot hold sets', out.getvalue())
        self.assertFalse(binding.warn_if_pse_leaves_sets())
        # Unstage it and the set IS left behind: warn.
        row = self.only_set()
        cmd.set_unstage(row['name'], 'all')
        self.assertTrue(binding.warn_if_pse_leaves_sets())

    def testSaveAsMidBatchKeepsTheBatchLandingInTheMovedDocument(self):
        # Review fix 1: Save As from an untitled session is the same document moved,
        # not a document change. The counter said otherwise; identity does not.
        jobs = self.design(4)
        deliver_designs(jobs[:1])
        row = self.only_set()
        path = os.path.join(_RESULTS['dir'], 'campaign.raymol')
        out = io.StringIO()
        with redirect_stdout(out):
            cmd.save(path)
            deliver_designs(jobs[1:3])
        self.assertNotIn('was not written', out.getvalue())
        self.assertEqual(os.path.realpath(store.active().path), os.path.realpath(path))
        self.assertEqual(batch.running()[row['id']], {'done': 3, 'total': 4, 'tool': GEN})
        deliver_designs(jobs[3:])
        self.assertEqual(batch.running(), {})
        c = store.active()
        self.assertEqual(c.count(row['id']), 4)
        self.assertEqual(len(self.staged(row)), 4)
        self.assertEqual(sorted(self.children(row['name'])),
                         sorted([j.spec.name for j in jobs] + [self.target(row)]))

    def testLandSurvivesAStagingFailureAsWrittenNotStaged(self):
        # Review fix 5: once add_entry has committed, a failure is "written, not
        # staged" -- said so, and the object is not put in the group unlinked.
        jobs = self.design(2)
        row = self.only_set()
        out = io.StringIO()
        with redirect_stdout(out), patch.object(batch, '_stage_or_discard',
                                                side_effect=RuntimeError('boom')):
            deliver_designs(jobs[:1])
        self.assertIn('could not be staged', out.getvalue())
        self.assertNotIn('was not written', out.getvalue())
        c = store.active()
        self.assertEqual(c.count(row['id']), 1)
        self.assertIn(jobs[0].spec.name, cmd.get_names('objects'))
        self.assertEqual(self.staged(row), [])
        self.assertEqual(batch.running()[row['id']]['done'], 1)
        deliver_designs(jobs[1:])
        self.assertEqual(len(self.staged(row)), 1)


class SharedTarget(BatchTestCase):
    """#545: a design run's entries share one target; the designed chain is the subject."""

    @staticmethod
    def metrics_of(obj):
        """Every value the metrics store holds on `obj`, in a comparable shape."""
        out = []
        for run in mstore.runs(object=obj):
            for v in run.values:
                out.append((run.tool, v.key, v.scope, v.chain, v.state,
                            None if v.is_array else v.value,
                            tuple(map(tuple, v.index)) if v.is_array else None,
                            tuple(v.values) if v.is_array else None))
        return sorted(out, key=repr)

    def testSixDesignsAreSevenObjectsAndTheTargetIsNotCharged(self):
        jobs = self.design(8)
        deliver_designs(jobs)
        row = self.only_set()
        c = store.active()
        staged = self.staged(row)
        target = self.target(row)
        self.assertEqual(len(staged), binding.DEFAULT_BUDGET)
        children = self.children(row['group_name'])
        self.assertEqual(len(children), binding.DEFAULT_BUDGET + 1, children)
        self.assertIn(target, children)
        # Every entry records its designed chain, from the run's DesignSpec.
        self.assertTrue(all(e['design_chains'] == ['B'] for e in c.entries(row['id'])))
        self.assertEqual(c.shared_target(row['id'])['entries'],
                         [e['id'] for e in staged])
        # The delivered binders keep the metrics run filed on them, current.
        from pymol.metrics import binding as mbinding
        for e in staged:
            runs = mstore.runs(object=e['staged_object'])
            self.assertTrue(runs)
            self.assertEqual([mbinding.stale_reason(r) for r in runs], [''] * len(runs))
        # The budget counts ENTRIES: six binders fill it; the target is not a seventh.
        from pymol.sets.errors import SetBudgetExceeded
        spare = [e for e in c.entries(row['id']) if not e.get('staged_object')][0]
        self.assertRaises(SetBudgetExceeded, cmd.set_stage, row['name'], spare['name'])
        # Unstaging some keeps the target; the last one takes it, and the group.
        cmd.set_unstage(row['name'], '+'.join(e['name'] for e in staged[:5]))
        self.assertEqual(self.target(row), target)
        self.assertEqual(sorted(self.children(row['group_name'])),
                         sorted([staged[5]['staged_object'], target]))
        cmd.set_unstage(row['name'], staged[5]['name'])
        self.assertNotIn(target, cmd.get_names('all'))
        self.assertIsNone(c.shared_target(row['id']))
        self.assertEqual(self.groups(), [])

    def testSharedStagingKeepsTheMetricsAndTheBinderWhereTheComplexPutIt(self):
        jobs = self.design(3)
        deliver_designs(jobs)
        row = self.only_set()
        names = [e['name'] for e in self.staged(row)]
        cmd.set_unstage(row['name'], 'all')
        # Today's behaviour, forced: every entry staged whole.
        with patch.object(binding, 'split_plan', return_value=None):
            whole = cmd.set_stage(row['name'], '+'.join(names))
        self.assertEqual(self.target(row), '')
        before = {n: self.metrics_of(n) for n in whole}
        coords = {n: cmd.get_coords('%s and chain B' % n) for n in whole}
        for n in whole:
            self.assertEqual(sorted(cmd.get_chains(n)), ['A', 'B'])
            self.assertTrue(before[n], 'the entry wrote metrics back')
        cmd.set_unstage(row['name'], 'all')
        shared = cmd.set_stage(row['name'], '+'.join(names))
        self.assertEqual(sorted(shared), sorted(whole))
        target = self.target(row)
        self.assertTrue(target)
        for n in shared:
            self.assertEqual(cmd.get_chains(n), ['B'])
            self.assertEqual(self.metrics_of(n), before[n])
            # The first is superposed on the reference as before; the rest are FIT onto
            # the target it made, which agrees to float precision.
            self.assertLess(abs(cmd.get_coords(n) - coords[n]).max(), 1e-3)
        # The target is the complex's chain A, where the complex put it.
        probe = binding.container().entry(row['id'], names[0])
        binding._load_entry_into(binding.container(), probe, 'probe')
        binding._superpose('probe', row['reference'])
        self.assertEqual(cmd.get_coords(target).tolist(),
                         cmd.get_coords('probe and chain A').tolist())

    def _manual_run(self, objects, design_chain='B', name='manual'):
        """A set filled through the store API, with a run that says what it designed."""
        c = store.active()
        row = c.create_set(name, tool=GEN, group_name=name)
        run = c.add_run(row['id'], GEN, inputs={'design_chain': design_chain})
        for obj in objects:
            binding.capture_object(row['id'], obj, run_id=run)
        return c.get_set(row['id'])

    def _complex(self, name, target_shift=0.0, binder='KLMNP'):
        # One template target: `fab` places each new peptide away from what is already
        # in the scene, so two `fab`s of the same sequence are NOT the same chain.
        if '_tpl' not in cmd.get_names('all'):
            cmd.fab('ACDEFGHIK', '_tpl', chain='A')
            cmd.disable('_tpl')
        cmd.create('_t', '_tpl', zoom=0)
        cmd.fab(binder, '_b', chain='B')
        cmd.translate([12.0, 0, 0], '_b', camera=0)
        if target_shift:
            cmd.translate([0, target_shift, 0], '_t', camera=0)
        cmd.create(name, '_t or _b')
        cmd.delete('_t or _b')
        return name

    def testAnIdenticalTargetIsSharedByContentAndADifferingOneIsStagedWhole(self):
        same = self._manual_run([self._complex('s1'), self._complex('s2', binder='WYVRS')],
                                name='same')
        differ = self._manual_run([self._complex('d1'),
                                   self._complex('d2', target_shift=3.0)], name='differ')
        cmd.delete('s1 or s2 or d1 or d2')
        cmd.set_stage('same', 'all')
        cmd.set_stage('differ', 'all')
        self.assertEqual(sorted(self.children('same')), ['s1', 's2', 'target_same'])
        self.assertEqual(sorted(self.children('differ')), ['d1', 'd2'])
        for obj in ('d1', 'd2'):
            self.assertEqual(sorted(cmd.get_chains(obj)), ['A', 'B'])
        self.assertEqual(self.target(differ), '')
        self.assertEqual(self.target(same), 'target_same')

    def testAMetricOnTheTargetChainKeepsTheEntryWhole(self):
        c = store.active()
        row = c.create_set('m', tool=GEN, group_name='m')
        run = c.add_run(row['id'], GEN, inputs={'design_chain': 'B'})
        binding.capture_object(row['id'], self._complex('m1'), run_id=run,
                               scalars={('contact', 'A'): 3.0},
                               specs=[{'key': 'contact', 'scope': 'chain', 'chain': 'A',
                                       'dtype': 'float', 'tool': 'import'}])
        cmd.delete('m1')
        cmd.set_stage('m', 'all')
        self.assertEqual(sorted(cmd.get_chains('m1')), ['A', 'B'])
        self.assertEqual(self.target(c.get_set('m')), '')

    def testAFoldOfTheDesignsInheritsTheDesignChainAndStagesWhole(self):
        jobs = self.design(2)
        deliver_designs(jobs)
        parent = self.only_set()
        deliver_models(cmd.predict(PRED, 'set:%s' % parent['name']))
        c = store.active()
        child = c.get_set('%s_1' % PRED)
        for e in c.entries(child['id']):
            self.assertEqual(e['design_chains'], ['B'])
        for e in self.staged(child):
            self.assertEqual(sorted(cmd.get_chains(e['staged_object'])), ['A', 'B'])
        self.assertEqual(self.target(child), '')

    def testPeekGhostsOnlyTheDesignChain(self):
        jobs = self.design(8)
        deliver_designs(jobs)
        row = self.only_set()
        spare = [e for e in store.active().entries(row['id'])
                 if not e.get('staged_object')][0]
        cmd.set_peek(row['name'], spare['name'])
        self.assertEqual(cmd.get_chains(binding.PEEK), ['B'])
        # An entry with no designed chain still ghosts whole.
        other = self._manual_run([self._complex('x1')], design_chain='', name='plain')
        cmd.delete('x1')
        entry = store.active().entries(other['id'])[0]
        self.assertEqual(entry['design_chains'], [])
        cmd.set_peek('plain', entry['name'])
        self.assertEqual(sorted(cmd.get_chains(binding.PEEK)), ['A', 'B'])

    def testTheSharedTargetSurvivesASessionRoundTripAndItsOwnDeletion(self):
        jobs = self.design(3)
        deliver_designs(jobs)
        row = self.only_set()
        target = self.target(row)
        path = os.path.join(_RESULTS['dir'], 'shared.raymol')
        with redirect_stdout(io.StringIO()):
            cmd.save(path)
            cmd.reinitialize()
            self.assertNotIn(target, cmd.get_names('all'))
            cmd.load(path)
        c = store.active()
        self.assertEqual(self.target(row), target)
        self.assertEqual(sorted(self.children(row['name'])),
                         sorted([j.spec.name for j in jobs] + [target]))
        self.assertEqual(len(c.shared_target(row['id'])['entries']), 3)
        # The user deletes the target: the binders stay linked, and the next stage
        # brings it back under the same name.
        cmd.delete(target)
        self.assertEqual(len(self.staged(row)), 3)
        cmd.set_unstage(row['name'], jobs[0].spec.name)
        cmd.set_stage(row['name'], jobs[0].spec.name)
        self.assertIn(target, cmd.get_names('objects'))
        # Renamed, it keeps its record; deleting every binder takes it with them.
        cmd.set_name(target, 'renamed_target')
        self.assertEqual(c.shared_target(row['id'])['object'], 'renamed_target')
        cmd.delete(' or '.join(j.spec.name for j in jobs))
        self.assertNotIn('renamed_target', cmd.get_names('all'))
        self.assertIsNone(c.shared_target(row['id']))

    # -- review round 1 ------------------------------------------------------------

    def assertOnTarget(self, row, entry_name):
        """The staged binder sits where its own complex puts it relative to the shared
        target: fit the stored complex onto the target by its target chain, and chain
        B must land on the staged binder."""
        c = store.active()
        e = c.entry(row['id'], entry_name)
        target = self.target(row)
        self.assertTrue(target)
        probe = cmd.get_unused_name('_probe')
        binding._load_entry_into(c, e, probe)
        try:
            cmd.fit('%s and chain A' % probe, target)
            got = cmd.get_coords(e['staged_object'])
            want = cmd.get_coords('%s and chain B' % probe)
            self.assertEqual(got.shape, want.shape)
            self.assertLess(abs(got - want).max(), 1e-2, entry_name)
        finally:
            cmd.delete(probe)

    def testTheBinderStaysOnTheTargetWhenTheReferenceMovesOrChanges(self):
        jobs = self.design(3)
        deliver_designs(jobs)
        row = self.only_set()
        names = [e['name'] for e in self.staged(row)]
        for name in names:
            self.assertOnTarget(row, name)
        # The user moves their target (or a runtime recentred it), then restages.
        cmd.translate([15, 0, 0], row['reference'], camera=0)
        cmd.set_unstage(row['name'], names[0])
        cmd.set_stage(row['name'], names[0])
        self.assertOnTarget(row, names[0])
        # A different reference altogether, far away.
        cmd.create('far', row['reference'])
        cmd.translate([0, 126, 0], 'far', camera=0)
        cmd.set_reference(row['name'], 'far')
        cmd.set_unstage(row['name'], names[1])
        cmd.set_stage(row['name'], names[1])
        for name in names:
            self.assertOnTarget(row, name)

    def testDeliveryAndLaterStagingAgreeOnPlacement(self):
        cmd.set_budget(2)
        jobs = self.design(4)
        deliver_designs(jobs)
        row = self.only_set()
        cmd.translate([7, -3, 2], row['reference'], camera=0)
        cmd.set_budget(4)
        rest = [e['name'] for e in store.active().entries(row['id'])
                if not e.get('staged_object')]
        self.assertEqual(len(rest), 2)
        cmd.set_stage(row['name'], '+'.join(rest))
        self.assertEqual(len(self.staged(row)), 4)
        for e in self.staged(row):
            self.assertOnTarget(row, e['name'])

    def testTheTargetIsVisibleWhicheverPathMadeIt(self):
        jobs = self.design(2)
        deliver_designs(jobs)
        row = self.only_set()
        target = self.target(row)
        n = cmd.count_atoms(target)
        self.assertGreater(n, 0)
        self.assertEqual(cmd.count_atoms('%s and rep cartoon' % target), n,
                         'made at delivery, from a design whose target copy is hidden')
        cmd.set_unstage(row['name'], 'all')
        cmd.set_stage(row['name'], 'all')
        target = self.target(row)
        self.assertEqual(cmd.count_atoms('%s and rep cartoon' % target), n)

    def testSetDeleteTakesTheTargetAndReconcileForgetsAStaleRecord(self):
        jobs = self.design(2)
        deliver_designs(jobs)
        row = self.only_set()
        target = self.target(row)
        cmd.set_delete(row['name'])
        self.assertNotIn(target, cmd.get_names('all'))
        c = store.active()
        self.assertEqual(c.shared_targets(), {})
        # A record whose set is gone (written by an older build, say) is dropped.
        c.set_shared_target('gone1234', {'object': 'x', 'signature': [], 'entries': ['e']})
        binding.reconcile()
        self.assertEqual(c.shared_targets(), {})

    def testTheTargetNameIsNeverAPrefixMatchForItsGroup(self):
        for group in ('t', 'ta', 'tar', 'target', 'target_t', 's', 'rfd3_a1'):
            name = binding.target_name(group)
            self.assertFalse(name.startswith(group), (group, name))
        self.assertEqual(binding.target_name('rfd3_a1'), 'target_rfd3_a1')
        row = self._manual_run([self._complex('ta1'), self._complex('ta2', binder='WYVRS')],
                               name='ta')
        cmd.delete('ta1 or ta2')
        cmd.set_stage('ta', 'all')
        self.assertEqual(self.target(row), 'shared_ta')
        self.assertEqual(sorted(cmd.get_object_list('ta')), ['shared_ta', 'ta1', 'ta2'])

    def testAUnitCellDoesNotMakeEveryChainItsOwnBlob(self):
        objs = [self._complex('u1'), self._complex('u2', binder='WYVRS')]
        for obj in objs:
            cmd.set_symmetry(obj, 50.0, 60.0, 70.0, 90.0, 90.0, 90.0, 'P 1')
        self.assertIn('_cell.entry_id', cmd.get_cifstr('u1 and chain A'))
        row = self._manual_run(objs, name='cells')
        cmd.delete('u1 or u2')
        c = store.active()
        hashes = {dict(c.chain_blobs(e['id']))['A'] for e in c.entries(row['id'])}
        self.assertEqual(len(hashes), 1, 'one target blob, whatever the objects were called')
        cmd.set_stage('cells', 'all')
        self.assertEqual(self.target(row), 'target_cells')

    def testAPseWarnsWhenTheBindersWouldGoWithoutTheirTarget(self):
        jobs = self.design(2)
        deliver_designs(jobs)
        row = self.only_set()
        self.assertFalse(binding.warn_if_pse_leaves_sets(),
                         'every entry staged, target present: nothing is lost')
        cmd.delete(self.target(row))
        out = io.StringIO()
        with redirect_stdout(out):
            self.assertTrue(binding.warn_if_pse_leaves_sets())
        self.assertIn(row['name'], out.getvalue())

    def testRenamingTheSetRenamesItsTarget(self):
        jobs = self.design(2)
        deliver_designs(jobs)
        row = self.only_set()
        cmd.set_rename(row['name'], 'renamed')
        self.assertIn('target_renamed', cmd.get_names('objects'))
        self.assertEqual(store.active().shared_target(row['id'])['object'],
                         'target_renamed')

    def testAFailureAfterTheTargetIsMadeLeavesNoOrphan(self):
        jobs = self.design(2)
        deliver_designs(jobs)
        row = self.only_set()
        cmd.set_unstage(row['name'], 'all')
        self.assertEqual(self.target(row), '')
        before = set(cmd.get_names('all'))
        with patch.object(binding, '_adopt_target', side_effect=RuntimeError('boom')):
            self.assertRaises(Exception, cmd.set_stage, row['name'], jobs[0].spec.name)
        leaked = {n for n in set(cmd.get_names('all')) - before
                  if not n.startswith('_')} - {jobs[0].spec.name, row['name']}
        self.assertEqual(leaked, set(), 'no orphan target')
        self.assertNotIn(binding.target_name(row['name']), cmd.get_names('all'))

    def testObjectToolsSeeTheComplexNotTheHalfOnDisplay(self):
        jobs = self.design(2)
        deliver_designs(jobs)
        row = self.only_set()
        binder = self.staged(row)[0]['staged_object']
        target = self.target(row)
        self.assertEqual(binding.split_context(binder), target)
        self.assertEqual(binding.split_context(target), '')
        # set_add captures the complex, with the design chain still known.
        cmd.set_create('picked')
        cmd.set_add('picked', binder)
        c = store.active()
        e = c.entries(c.get_set('picked')['id'])[0]
        self.assertEqual([ch for ch, _ in c.chain_cifs(e['id'])], ['A', 'B'])
        self.assertEqual(e['design_chains'], ['B'])
        # predict folds the complex.
        from pymol import predicting
        with redirect_stdout(io.StringIO()):
            seq, sources = predicting.resolve_input(binder)
        self.assertEqual(sorted(chain for _, chain in sources), ['A', 'B'])
        self.assertEqual(len(seq.split('/')), 2)
        # And nothing was left in the scene by reading it.
        self.assertFalse([n for n in cmd.get_names('all') if n.startswith('_raymol_')])

    def testAFoldWithItsOwnTargetIsGhostedWhole(self):
        jobs = self.design(2)
        deliver_designs(jobs)
        parent = self.only_set()
        deliver_models(cmd.predict(PRED, 'set:%s' % parent['name']))
        c = store.active()
        child = c.get_set('%s_1' % PRED)
        entry = c.entries(child['id'])[0]
        self.assertEqual(entry['design_chains'], ['B'])
        cmd.set_peek(child['name'], entry['name'])
        self.assertEqual(sorted(cmd.get_chains(binding.PEEK)), ['A', 'B'])

    def testAFailedMigrationRollsBackAndAnUnreadableSessionIsRefusedUnmigrated(self):
        import sqlite3
        from pymol.sets import schema
        from pymol.sets.errors import SetFormatError
        jobs = self.design(1)
        deliver_designs(jobs)
        path = os.path.join(_RESULTS['dir'], 'v1.raymol')
        with redirect_stdout(io.StringIO()):
            cmd.save(path)
            cmd.reinitialize()

        def to_v1(extra=''):
            conn = sqlite3.connect(path)
            conn.execute("UPDATE meta SET value = '1' WHERE key = 'format_version'")
            if extra:
                conn.execute(extra)
            conn.commit()
            conn.close()

        def version():
            conn = sqlite3.connect(path)
            try:
                return conn.execute("SELECT value FROM meta WHERE key ="
                                    " 'format_version'").fetchone()[0]
            finally:
                conn.close()

        to_v1()
        with patch.dict(schema.MIGRATIONS, {1: lambda conn: [][0]}):
            self.assertRaises(SetFormatError, store.Container, path)
        self.assertEqual(version(), '1', 'rolled back, not half-migrated')
        # A session this build cannot unpickle is refused BEFORE the file is migrated.
        to_v1("UPDATE session SET pse = X'00ff00ff'")
        self.assertRaises(Exception, cmd.load, path)
        self.assertEqual(version(), '1')
        # A good one migrates, and stamps this build as the writer.
        to_v1("UPDATE session SET pse = X'00ff00ff'")
        conn = sqlite3.connect(path)
        conn.execute('DELETE FROM session')
        conn.commit()
        conn.close()
        c = store.Container(path)
        self.assertEqual(c.meta_get('format_version'), str(schema.FORMAT_VERSION))
        self.assertTrue(c.meta_get('app_version'))
        c.close()

    # -- review round 2 ------------------------------------------------------------

    def testPredictReadsABinderInItsStoredChainOrderHoweverItWasStaged(self):
        from pymol import predicting
        jobs = self.design(2)
        deliver_designs(jobs)
        row = self.only_set()
        c = store.active()
        delivered = self.staged(row)[0]
        order = [ch for ch, _ in c.chain_blobs(delivered['id'])]
        self.assertEqual(order, ['A', 'B'])
        with redirect_stdout(io.StringIO()):
            _seq, sources = predicting.resolve_input(delivered['staged_object'])
        self.assertEqual([ch for _, ch in sources], order, 'delivered binder')
        self.assertEqual(dict(sources)[delivered['staged_object']], 'B')
        cmd.set_unstage(row['name'], delivered['name'])
        cmd.set_stage(row['name'], delivered['name'])
        with redirect_stdout(io.StringIO()):
            _seq, again = predicting.resolve_input(delivered['staged_object'])
        self.assertEqual([ch for _, ch in again], order, 'restaged binder')

    def testATargetDeletedUnderLiveBindersIsRebuiltWhereTheyAre(self):
        jobs = self.design(3)
        deliver_designs(jobs)
        row = self.only_set()
        names = [e['name'] for e in self.staged(row)]
        cmd.create('far', row['reference'])
        cmd.translate([0, 122, 0], 'far', camera=0)
        cmd.set_reference(row['name'], 'far')
        cmd.translate([9, 0, 0], row['reference'], camera=0)
        target = self.target(row)
        cmd.delete(target)
        cmd.set_unstage(row['name'], names[0])
        cmd.set_stage(row['name'], names[0])
        self.assertEqual(self.target(row), target)
        for name in names:
            self.assertOnTarget(row, name)

    def testATargetOnTopOfTheReferenceIsMadeDisabledAndOtherwiseShown(self):
        jobs = self.design(2)
        deliver_designs(jobs)
        row = self.only_set()
        target = self.target(row)
        enabled = cmd.get_names('objects', enabled_only=1)
        self.assertNotIn(target, enabled, 'the design target copy IS the reference')
        n = cmd.count_atoms(target)
        self.assertEqual(cmd.count_atoms('%s and rep cartoon' % target), n,
                         'disabled, not repless: the panel toggle shows it')
        # Staged from the drawer against a reference that is somewhere else: shown.
        cmd.set_unstage(row['name'], 'all')
        cmd.translate([30, 0, 0], row['reference'], camera=0)
        with patch.object(binding, '_superpose', return_value=False):
            cmd.set_stage(row['name'], 'all')
        target = self.target(row)
        self.assertIn(target, cmd.get_names('objects', enabled_only=1))
        self.assertEqual(cmd.count_atoms('%s and rep cartoon' % target), n)
        # And by the same rule on the stage path: superposed onto it, it coincides.
        cmd.set_unstage(row['name'], 'all')
        cmd.set_stage(row['name'], 'all')
        self.assertNotIn(self.target(row), cmd.get_names('objects', enabled_only=1))

    def testAFailureInsideTheSplitLeavesTheComplexWholeAndNoTarget(self):
        jobs = self.design(2)
        deliver_designs(jobs)
        row = self.only_set()
        cmd.set_unstage(row['name'], 'all')
        name = jobs[0].spec.name
        real_remove = cmd.remove

        def failing(selection, *a, **k):
            if 'not (' in str(selection):
                raise RuntimeError('injected')
            return real_remove(selection, *a, **k)
        with patch.object(cmd, 'remove', side_effect=failing):
            self.assertRaises(Exception, cmd.set_stage, row['name'], name)
        self.assertNotIn(binding.target_name(row['name']), cmd.get_names('all'))
        self.assertEqual(sorted(cmd.get_chains(name)), ['A', 'B'])
        self.assertIsNone(store.active().entry(row['id'], name)['staged_object'])
        # A failure AFTER the split: the binder is put back whole, too.
        cmd.delete(name)
        with patch.object(binding, '_adopt_target', side_effect=RuntimeError('boom')):
            self.assertRaises(Exception, cmd.set_stage, row['name'], name)
        self.assertEqual(sorted(cmd.get_chains(name)), ['A', 'B'])
        self.assertNotIn(binding.target_name(row['name']), cmd.get_names('all'))

    def testObjectToolsRebuildTheComplexWhenTheTargetIsGone(self):
        from pymol import predicting
        jobs = self.design(2)
        deliver_designs(jobs)
        row = self.only_set()
        binder = self.staged(row)[0]['staged_object']
        cmd.delete(self.target(row))
        self.assertTrue(binding.is_split(binder))
        out = io.StringIO()
        with redirect_stdout(out):
            _seq, sources = predicting.resolve_input(binder)
        self.assertEqual([ch for _, ch in sources], ['A', 'B'])
        self.assertIn('not in the scene', out.getvalue())
        cmd.set_create('picked')
        with redirect_stdout(io.StringIO()):
            cmd.set_add('picked', binder)
        c = store.active()
        e = c.entries(c.get_set('picked')['id'])[0]
        self.assertEqual([ch for ch, _ in c.chain_cifs(e['id'])], ['A', 'B'])
        self.assertFalse([n for n in cmd.get_names('all') if n.startswith('_raymol_')])

    def testATargetThatCannotBeFitStagesWholeOnTheReference(self):
        jobs = self.design(3)
        deliver_designs(jobs)
        row = self.only_set()
        name = self.staged(row)[0]['name']
        cmd.alter(self.target(row), 'chain="Q"')
        cmd.set_unstage(row['name'], name)
        out = io.StringIO()
        with redirect_stdout(out):
            obj = cmd.set_stage(row['name'], name)[0]
        self.assertIn('could not fit', out.getvalue())
        self.assertEqual(sorted(cmd.get_chains(obj)), ['A', 'B'])

    def testLoadingARaymolUnpicklesItsSessionOnce(self):
        jobs = self.design(1)
        deliver_designs(jobs)
        path = os.path.join(_RESULTS['dir'], 'once.raymol')
        with redirect_stdout(io.StringIO()):
            cmd.save(path)
            cmd.reinitialize()
        import pickle
        calls = []
        real = pickle.loads

        def counting(data, *a, **k):
            calls.append(len(data))
            return real(data, *a, **k)
        with patch.object(binding.pickle, 'loads', side_effect=counting), \
                redirect_stdout(io.StringIO()):
            cmd.load(path)
        self.assertEqual(len(calls), 1)

    def testAVersionOneFileIsBackfilledFromItsMetricsAndItsRuns(self):
        import sqlite3
        jobs = self.design(2)
        deliver_designs(jobs)
        row = self.only_set()
        path = os.path.join(_RESULTS['dir'], 'old.raymol')
        with redirect_stdout(io.StringIO()):
            cmd.save(path)
            cmd.reinitialize()
        conn = sqlite3.connect(path)
        conn.execute('ALTER TABLE entries DROP COLUMN design_chains')
        # One entry keeps its `design_chain` metric; the other must fall back to the
        # run's inputs.
        first = conn.execute('SELECT id FROM entries ORDER BY ord').fetchone()[0]
        conn.execute('UPDATE "m_%s" SET design_chain = NULL WHERE entry_id = ?'
                     % row['id'], (first,))
        conn.execute("UPDATE meta SET value = '1' WHERE key = 'format_version'")
        conn.commit()
        conn.close()
        with redirect_stdout(io.StringIO()):
            cmd.load(path)
        c = store.active()
        from pymol.sets import schema
        self.assertEqual(c.meta_get('format_version'), str(schema.FORMAT_VERSION))
        self.assertEqual([e['design_chains'] for e in c.entries(row['id'])],
                         [['B'], ['B']])


class RestageByRanking(BatchTestCase):
    """#546: while a run lands, staging is provisional; when it ends, the set's top
    entries by ranking key replace the provisional ones, and nothing a person staged,
    pinned or unstaged is touched."""

    KEY = 'backbone_valid_pct'          # a GEOMETRY_SPEC, higher_is_better=True

    def score(self, jobs, scores):
        """Give each job a runtime metric document with KEY = its score, the channel a
        real runtime reports geometry on (`designing._document_values`)."""
        import json
        for job, value in zip(jobs, scores):
            real = getattr(job, '_real', None) or job
            path = os.path.join(_RESULTS['dir'], '%s.metrics.json' % real.job_id)
            with open(path, 'w') as handle:
                json.dump({'tool': GEN, 'values': [
                    {'key': self.KEY, 'state': 1, 'value': float(value)}]}, handle)
            real.metrics_path = path

    def scored(self, row):
        c = store.active()
        return {e['name']: (e.get('scalars') or {}).get(self.KEY)
                for e in c.entries(row['id'])}

    def staged_names(self, row):
        return sorted(e['name'] for e in self.staged(row))

    def top(self, row, n, exclude=()):
        values = {k: v for k, v in self.scored(row).items() if k not in exclude}
        return sorted(sorted(values, key=lambda k: -values[k])[:n])

    def run_ascending(self, n, scores=None, before_rest=None, **kwargs):
        """Submit `n`, deliver the first, sort by KEY (as a header click would), call
        `before_rest(row, jobs)` -- which returns how many jobs have been delivered by
        then, when it delivered some itself -- then deliver the rest: the best arrive
        LAST."""
        jobs = self.design(n, **kwargs)
        self.score(jobs, scores or [10.0 * (i + 1) for i in range(n)])
        deliver_designs(jobs[:1])
        row = self.only_set()
        cmd.set_sort(row['name'], self.KEY, 1)
        done = 1
        if before_rest:
            done = before_rest(row, jobs) or 1
        out = io.StringIO()
        with redirect_stdout(out):
            deliver_designs(jobs[done:])
        return row, jobs, out.getvalue()

    def testBestDesignsArrivingLastEndUpStaged(self):
        row, jobs, printed = self.run_ascending(10)
        self.assertEqual(batch.running(), {})
        self.assertEqual(self.staged_names(row), self.top(row, 6))
        self.assertIn('Restaged top 6 by Backbone bonds in range', printed)
        self.assertEqual(printed.count('Restaged'), 1, 'one line, not one per design')
        c = store.active()
        self.assertEqual({e['staged_by'] for e in self.staged(row)}, {'auto'})
        self.assertEqual(c.notice(row['id'])['text'],
                         'Restaged top 6 by Backbone bonds in range')
        # The shared target (#545) came through the swap: one target, its users are
        # exactly the staged entries, and the group holds those plus the target.
        target = self.target(row)
        self.assertTrue(target)
        record = c.shared_target(row['id'])
        self.assertEqual(sorted(record['entries']),
                         sorted(e['id'] for e in self.staged(row)))
        self.assertEqual(sorted(self.children(row['group_name'])),
                         sorted([e['staged_object'] for e in self.staged(row)] + [target]))
        for e in self.staged(row):
            self.assertEqual(cmd.get_chains(e['staged_object']), ['B'])
        # A staging action answers the notice.
        cmd.set_unstage(row['name'], self.staged(row)[0]['name'])
        self.assertIsNone(c.notice(row['id']))

    def testPinnedHandStagedAndHandUnstagedEntriesAreLeftAlone(self):
        names = {}

        def mid_run(row, jobs):
            deliver_designs(jobs[1:4])          # four landed, all provisional
            staged = self.staged_names(row)
            self.assertEqual(len(staged), 4)
            first, second, third, fourth = [jobs[i].spec.name for i in range(4)]
            cmd.set_pin(row['name'], first)
            cmd.set_stage(row['name'], second)  # already staged: now the user's
            cmd.set_unstage(row['name'], third)
            cmd.delete(self.staged_object(row, fourth))   # unstaged by hand, too
            names.update(pinned=first, kept=second, out=third, deleted=fourth)
            return 4

        row, jobs, printed = self.run_ascending(10, before_rest=mid_run)
        # The four earliest scored lowest; two of them are protected, two stay out.
        staged = self.staged_names(row)
        self.assertIn(names['pinned'], staged)
        self.assertIn(names['kept'], staged)
        self.assertNotIn(names['out'], staged)
        self.assertNotIn(names['deleted'], staged)
        self.assertEqual(len(staged), 6)
        self.assertEqual(sorted(set(staged) - {names['pinned'], names['kept']}),
                         self.top(row, 4, exclude=names.values()))
        self.assertIn('Restaged top 4 by Backbone bonds in range (2 pinned or staged by'
                      ' you kept)', printed)
        by = {e['name']: e['staged_by'] for e in store.active().entries(row['id'])}
        self.assertEqual(by[names['kept']], 'user')
        self.assertEqual(by[names['out']], 'user')
        self.assertEqual(by[names['deleted']], 'user')

    def staged_object(self, row, name):
        return store.active().entry(row['id'], name)['staged_object']

    def testNoRankingKeyLeavesTheProvisionalStagingAsItLanded(self):
        jobs = self.design(8)
        self.score(jobs, [10.0 * (i + 1) for i in range(8)])
        out = io.StringIO()
        with redirect_stdout(out):
            deliver_designs(jobs)
        row = self.only_set()
        self.assertEqual(self.staged_names(row),
                         sorted(j.spec.name for j in jobs[:6]))
        self.assertNotIn('Restaged', out.getvalue())
        self.assertIsNone(store.active().notice(row['id']))

    def testARankingKeyWithNoValuesLeavesTheStagingAlone(self):
        def rank_on_empty(row, jobs):
            c = store.active()
            c.declare_columns(row['id'], [{'key': 'unscored', 'scope': 'object',
                                           'dtype': 'float', 'label': 'Unscored'}])
            cmd.set_sort(row['name'], 'unscored', 1)

        row, jobs, printed = self.run_ascending(8, before_rest=rank_on_empty)
        self.assertEqual(self.staged_names(row), sorted(j.spec.name for j in jobs[:6]))
        self.assertNotIn('Restaged', printed)

    def testAnExtendingRunRanksTheWholeSetEvenIntoAFullBudget(self):
        row, first, _ = self.run_ascending(6, seed=7)
        self.assertEqual(self.staged_names(row), sorted(j.spec.name for j in first))
        # Ten more like these, all better: the set is full, so none get a slot as they
        # land, and the end of the run still puts the best six of all sixteen in view.
        again = cmd.binder_design(GEN, 'tgt', 'tgt and resi 5', length=6, n_designs=10,
                                  seed=7)
        self.score(again, [100.0 + i for i in range(10)])
        out = io.StringIO()
        with redirect_stdout(out):
            deliver_designs(again)
        c = store.active()
        self.assertEqual([s['name'] for s in c.sets()], [row['name']])
        self.assertEqual(c.count(row['id']), 16)
        self.assertEqual(self.staged_names(row), self.top(row, 6))
        self.assertTrue(set(self.staged_names(row)) <= {j.spec.name for j in again})
        self.assertIn('Restaged top 6', out.getvalue())
        self.assertEqual(len(self.children(row['group_name'])), 7, 'six and the target')

    def testACancelledRunIsRestagedOverWhatLanded(self):
        from pymol import designing
        jobs = self.design(10)
        self.score(jobs, [10.0 * (i + 1) for i in range(10)])
        deliver_designs(jobs[:1])
        row = self.only_set()
        cmd.set_sort(row['name'], self.KEY, 1)
        deliver_designs(jobs[1:7])
        self.assertTrue(batch.running())
        out = io.StringIO()
        with redirect_stdout(out):
            for job in jobs[7:]:
                job.cancel()
                designing.discard_pending(job.spec.name)
        self.assertEqual(batch.running(), {})
        self.assertEqual(store.active().count(row['id']), 7)
        self.assertEqual(self.staged_names(row), self.top(row, 6))
        self.assertIn('Restaged top 6', out.getvalue())
        # The notice is readable and dismissable from the command line, as in the drawer.
        self.assertEqual(cmd.set_notice(row['name']),
                         'Restaged top 6 by Backbone bonds in range')
        cmd.set_notice(row['name'], 1)
        self.assertIsNone(store.active().notice(row['id']))
        self.assertEqual(cmd.set_notice(row['name']), '')

    def testALaterSortDoesNotRestage(self):
        row, jobs, _ = self.run_ascending(10)
        before = self.staged_names(row)
        cmd.set_sort(row['name'], self.KEY, 0)          # worst first now
        self.assertEqual(self.staged_names(row), before)

    def testABudgetHeldByTheUserLeavesNoRoomAndMovesNothing(self):
        def take_it(row, jobs):
            deliver_designs(jobs[1:2])
            cmd.set_stage(row['name'], '%s+%s' % (jobs[0].spec.name, jobs[1].spec.name))
            cmd.set_budget(1, row['name'])
            return 2

        row, jobs, printed = self.run_ascending(6, before_rest=take_it)
        self.assertEqual(self.staged_names(row),
                         sorted([jobs[0].spec.name, jobs[1].spec.name]))
        self.assertNotIn('Restaged', printed)

    def testASingleDesignIsNeverRestaged(self):
        self.helix()
        jobs = [cmd.binder_design(GEN, 'tgt', 'tgt and resi 5', length=6, n_designs=1)]
        self.score(jobs, [5.0])
        deliver_designs(jobs)
        row = self.only_set()
        self.assertEqual(self.staged_names(row), [jobs[0].spec.name])
        self.assertIn(jobs[0].spec.name, cmd.get_names('objects'))

    def testAVersionTwoFileGainsStagedBy(self):
        import sqlite3
        from pymol.sets import schema
        jobs = self.design(2)
        deliver_designs(jobs)
        row = self.only_set()
        path = os.path.join(_RESULTS['dir'], 'v2.raymol')
        with redirect_stdout(io.StringIO()):
            cmd.save(path)
            cmd.reinitialize()
        conn = sqlite3.connect(path)
        conn.execute('ALTER TABLE entries DROP COLUMN staged_by')
        conn.execute("UPDATE meta SET value = '2' WHERE key = 'format_version'")
        conn.commit()
        conn.close()
        with redirect_stdout(io.StringIO()):
            cmd.load(path)
        c = store.active()
        self.assertEqual(c.meta_get('format_version'), str(schema.FORMAT_VERSION))
        self.assertEqual([e['staged_by'] for e in c.entries(row['id'])], ['', ''])
        # '' on a staged entry is the user's: a restage never replaces it.
        self.assertEqual(len(self.staged(row)), 2)
        cmd.set_sort(row['name'], 'seed', 1)
        result = binding.restage_by_ranking(c.get_set(row['id']))
        self.assertEqual(result['kept'], 2)
        self.assertEqual(result['staged'] + result['unstaged'], [])


class RestageReviewRound1(RestageByRanking):
    """#546 review round 1: edits, pins, direction, partial scores, a failed swap, the
    tool's own ranking metric, ties, and restage notices that outlive their session."""

    def testAnEditedProvisionalDesignIsTheUsersAndSurvives(self):
        info = {}

        def mid(row, jobs):
            deliver_designs(jobs[1:3])
            obj = store.active().entry(row['id'], jobs[0].spec.name)['staged_object']
            cmd.alter(obj, 'b=99.0')
            info['altered'] = (jobs[0].spec.name, obj)
            obj = store.active().entry(row['id'], jobs[1].spec.name)['staged_object']
            cmd.remove(obj + ' and resi 1')
            info['removed'] = (jobs[1].spec.name, obj)
            return 3

        row, jobs, printed = self.run_ascending(10, before_rest=mid)
        staged = self.staged_names(row)
        by = {e['name']: e['staged_by'] for e in store.active().entries(row['id'])}
        for name, obj in info.values():
            self.assertIn(name, staged)
            self.assertIn(obj, cmd.get_names('objects'))
            self.assertEqual(by[name], 'user')
        self.assertEqual(len(staged), 6)
        self.assertIn('Restaged top 4', printed)
        # An untouched provisional design still goes: jobs[2] scored third-lowest.
        self.assertNotIn(jobs[2].spec.name, staged)

    def testPinningThenUnpinningMakesTheEntryTheUsers(self):
        info = {}

        def mid(row, jobs):
            cmd.set_pin(row['name'], jobs[0].spec.name)
            cmd.set_pin(row['name'], jobs[0].spec.name, 0)
            info['name'] = jobs[0].spec.name

        row, jobs, printed = self.run_ascending(10, before_rest=mid)
        self.assertIn(info['name'], self.staged_names(row))
        self.assertEqual(store.active().entry(row['id'], info['name'])['staged_by'], 'user')

    def testAnAscendingSortStillStagesTheBest(self):
        def mid(row, jobs):
            cmd.set_sort(row['name'], self.KEY, 0)      # the second header click

        row, jobs, printed = self.run_ascending(10, before_rest=mid)
        self.assertEqual(self.staged_names(row), self.top(row, 6))

    def testUnscoredProvisionalEntriesFillWhatTheRankingCannot(self):
        jobs = self.design(10)
        self.score([jobs[0]] + jobs[8:], [1.0, 50.0, 60.0])
        deliver_designs(jobs[:1])
        row = self.only_set()
        cmd.set_sort(row['name'], self.KEY, 1)
        out = io.StringIO()
        with redirect_stdout(out):
            deliver_designs(jobs[1:])
        names = [j.spec.name for j in jobs]
        self.assertEqual(self.staged_names(row),
                         sorted([names[0], names[8], names[9]] + names[1:4]),
                         'the three scored plus the oldest three unscored')
        self.assertIn('Restaged top 3', out.getvalue())
        self.assertIn('3 not yet scored kept', out.getvalue())

    def testAFailedSwapNeverLeavesTheSetOverBudget(self):
        real = binding._load_entry_into
        calls = {'n': 0}

        def flaky(c, entry, obj, _self=cmd):
            calls['n'] += 1
            if calls['n'] == 2:
                raise RuntimeError('injected')
            return real(c, entry, obj, _self=_self)

        def mid(row, jobs):
            deliver_designs(jobs[1:9])
            return 9

        with patch.object(binding, '_load_entry_into', flaky):
            row, jobs, printed = self.run_ascending(10, before_rest=mid)
        self.assertIn('could not follow the ranking', printed)
        staged = self.staged_names(row)
        self.assertEqual(len(staged), 6, 'one new in, one displaced out')
        self.assertLessEqual(len(self.staged(row)), binding.budget(row))
        self.assertNotIn(jobs[0].spec.name, staged, 'the worst goes first')
        self.assertEqual(sorted(store.active().shared_target(row['id'])['entries']),
                         sorted(e['id'] for e in self.staged(row)))

    def testASequenceOnlyEntryIsNeverACandidate(self):
        def mid(row, jobs):
            c = store.active()
            # Chains by SEQUENCE only (n_chains 1), top score, nothing to load.
            c.add_entry(row['id'], 'seq_only', sequences={'B': 'GGGGGG'},
                        scalars={self.KEY: 1000.0})

        row, jobs, printed = self.run_ascending(10, before_rest=mid)
        self.assertNotIn('could not follow', printed)
        self.assertNotIn('seq_only', self.staged_names(row))
        self.assertEqual(self.staged_names(row), self.top(row, 6, exclude=('seq_only',)))

    def testStagingIntoAnEmptySceneShowsTheTargetAndZoomsOntoIt(self):
        jobs = self.design(3)
        deliver_designs(jobs)
        row = self.only_set()
        cmd.set_unstage(row['name'])
        cmd.delete('all')                         # the reference is gone too
        cmd.set_view((1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, -50, 500, 500, 500, 40, 100, -20))
        names = cmd.set_stage(row['name'], '%s+%s' % (jobs[0].spec.name, jobs[1].spec.name))
        target = self.target(row)
        self.assertTrue(target)
        self.assertIn(target, cmd.get_names('objects', enabled_only=1),
                      'no reference in the scene: nothing it coincides with')
        for obj in names:
            self.assertIn(obj, cmd.get_names('objects', enabled_only=1))
        (lo, hi) = cmd.get_extent(row['group_name'])
        # The camera's origin is now on what was staged (it was 500 A away).
        for got, a, b in zip(cmd.get_view()[12:15], lo, hi):
            self.assertTrue(a <= got <= b, (got, a, b))

    def testTiesEverywhereRestageNothing(self):
        row, jobs, printed = self.run_ascending(8, scores=[100.0] * 8)
        self.assertNotIn('Restaged', printed)
        self.assertEqual(self.staged_names(row), sorted(j.spec.name for j in jobs[:6]))

    def testAPredictionIsRestagedByItsToolsDeclaredMetric(self):
        import json
        parent = PredictOverASet.parent(self, 4)
        jobs = cmd.predict(PRED, 'set:%s@top:4' % parent['name'], n_models=3)
        self.assertEqual(len(jobs), 12)
        for i, job in enumerate(jobs):
            path = os.path.join(_RESULTS['dir'], '%s.metrics.json' % job.job_id)
            with open(path, 'w') as handle:
                json.dump({'tool': PRED, 'values': [
                    {'key': 'mean_plddt', 'state': 1, 'value': 40.0 + i}]}, handle)
            (getattr(job, '_real', None) or job).metrics_path = path
        out = io.StringIO()
        with redirect_stdout(out):
            deliver_models(jobs)
        c = store.active()
        child = c.get_set('%s_1' % PRED)
        self.assertEqual(child['ranking_key'], '', 'used, not written into the set')
        values = {e['name']: e['scalars'].get('mean_plddt') for e in c.entries(child['id'])}
        best = sorted(sorted(values, key=lambda k: -values[k])[:6])
        self.assertEqual(sorted(e['name'] for e in self.staged(child)), best)
        self.assertIn('Restaged top 6 by Mean confidence', out.getvalue())

    def testARestageNoticeDoesNotOutliveItsSession(self):
        row, jobs, printed = self.run_ascending(10)
        c = store.active()
        self.assertEqual(c.notice(row['id'])['kind'], 'restage')
        path = os.path.join(_RESULTS['dir'], 'later.raymol')
        with redirect_stdout(io.StringIO()):
            cmd.save(path)
            cmd.reinitialize()
            cmd.load(path)
        self.assertIsNone(store.active().notice(row['id']))


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
        # MEASURED before the `_batch_frontier` prefix cache: 200-256 ms, 170 of them in
        # the frontier rescan; after: 6 ms. The bound is informational -- with the cache
        # reverted this machine measured 47 ms, close enough to it that timing alone
        # would not catch the regression on a fast box. The assertion below is the guard.
        self.assertLess(elapsed, 0.05)
        row = self.only_set()
        self.assertEqual(batch.running()[row['id']]['total'], 1000)
        # And the cache is what does it: the scanned prefix is REMEMBERED across the
        # poll's 1000 `pending_info` calls instead of being rewalked from index 0 by
        # each of them. Without the cache the key does not exist at all.
        batch_id = list(designing._BATCH)[0]
        self.assertIn('frontier', designing._BATCH[batch_id])
        self.assertGreaterEqual(designing._BATCH[batch_id]['frontier'], 999)
        again = time.perf_counter()
        appkit_inspector._pending_maps('designing')
        self.assertLess(time.perf_counter() - again, 0.05)
