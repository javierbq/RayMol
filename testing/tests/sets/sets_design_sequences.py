"""Sequence design takes a set or a view and writes a child set of sequences (#453).

    pymol -ckqy testing/testing.py --run testing/tests/sets/sets_design_sequences.py

A fake sequence designer and a fake predictor, delivered the way the Swift runtime
delivers: by calling `designing_sequences.deliver_result(path, key)` with the job key the
request was given. No host, no weights, no network. The fake's sequences differ per
sample, which is what makes "N sequences per backbone is N entries" a statement about the
delivery rather than about identical inputs.
"""
import json
import os
import shutil
import tempfile

from pymol import cmd, testing
from pymol.metrics import schema as mschema, store as mstore
from pymol.sets import batch, binding, store

DESIGNER = 'fakempnn'
PRED = 'fakefold'

_RESULTS = {'dir': None}

#: One-letter alphabet the fake samples from, in MPNN order.
_LETTERS = 'ACDEFGHIKLMNPQRSTVWY'


def _atom(serial, name, resn, chain, resi, x, y, z):
    padded = name if len(name) >= 4 else ' %-3s' % name
    return ('ATOM  %5d %s %3s %1s%4s    %8.3f%8.3f%8.3f  1.00  0.00          %2s'
            % (serial, padded, resn, chain or 'A', resi, x, y, z, name[0]))


class FakeSequenceJob:
    """Reports done at once; writes n_sequences sequences over the backbone it was given.

    `status()` reports the PATH only and `write()` creates the file, for the reason
    `sets_batch.FakeDesignJob` splits them: a status that wrote a file would make any
    poll-cost test measure the fake.
    """

    _counter = 0

    def __init__(self, spec, options, weights_path):
        FakeSequenceJob._counter += 1
        self.job_id = '%s-%d' % (DESIGNER, FakeSequenceJob._counter)
        self.spec = spec
        self.options = options
        self.cancelled = False
        self.metrics_path = ''

    def status(self):
        return {'state': 'cancelled' if self.cancelled else 'done', 'phase': 'done',
                'fraction': 1.0, 'error': None,
                'result_path': None if self.cancelled else self.result_path,
                'peak_bytes': 2 ** 20, 'elapsed_s': 0.25}

    @property
    def result_path(self):
        return os.path.join(_RESULTS['dir'], '%s.json' % self.job_id)

    def write(self):
        path = self.result_path
        if os.path.exists(path):
            return path
        residues = self.spec.residues
        index = [[r['chain'], r['resi']] for r in residues]
        sequences = []
        for n in range(self.options.n_sequences):
            letters = [_LETTERS[(i + n) % len(_LETTERS)]
                       for i in range(len(residues))]
            chains = {}
            for residue, letter in zip(residues, letters):
                chains[residue['chain']] = chains.get(residue['chain'], '') + letter
            sequences.append({
                'n': n + 1,
                'seed': self.options.seed + n,
                'chains': chains,
                'scalars': {'sequence_recovery': 0.1 * (n + 1),
                            'mean_certainty': 0.5 + 0.01 * n,
                            'mean_native_fit': -1.0 - 0.1 * n,
                            'temperature': self.options.temperature},
                'arrays': {
                    'native_fit': [-0.5 - 0.01 * i for i in range(len(residues))],
                    'certainty': [0.9 - 0.001 * i for i in range(len(residues))],
                },
            })
        with open(path, 'w') as handle:
            json.dump({'job_id': self.job_id, 'designer': DESIGNER,
                       'elapsed_s': 0.25, 'index': index,
                       'sequences': sequences}, handle)
        return path

    def cancel(self):
        self.cancelled = True


class FakeFoldJob:
    """A predictor just real enough to fold the child set: one CA per residue."""

    _counter = 0

    def __init__(self, spec, options, weights_path):
        FakeFoldJob._counter += 1
        self.job_id = '%s-%d' % (PRED, FakeFoldJob._counter)
        self.spec = spec
        self.options = options
        self.metrics_path = ''

    def status(self):
        return {'state': 'done', 'phase': 'done', 'fraction': 1.0, 'error': None,
                'result_path': self.result_path, 'elapsed_s': 1.0}

    @property
    def result_path(self):
        return os.path.join(_RESULTS['dir'], '%s.pdb' % self.job_id)

    def write(self):
        path = self.result_path
        if not os.path.exists(path):
            lines, serial = [], 1
            for chain, sequence in self.spec.chains:
                for i, letter in enumerate(sequence):
                    lines.append(_atom(serial, 'CA', 'GLY', chain, str(i + 1),
                                       i * 3.8, ord(letter) * 0.1, 0.0))
                    serial += 1
                lines.append('TER')
            lines.append('END')
            with open(path, 'w') as handle:
                handle.write('\n'.join(lines) + '\n')
        return path

    def cancel(self):
        pass


def _install_fakes():
    from pymol.designers import registry as dreg
    from pymol.designers.base import BackboneSpec, SequenceDesigner, require_designable
    from pymol.designers.metrics import DESIGN_SEQUENCE_SPECS
    from pymol.predictors import registry as preg
    from pymol.predictors.base import Predictor, PredictionSpec, parse_chains
    from pymol.predictors.metrics import UNSCORED_SPECS

    class FakeDesigner(SequenceDesigner):
        id = DESIGNER
        name = 'Fake sequence designer'
        weight_bundle = None
        option_defaults = {'seed': 0, 'temperature': 0.1, 'n_sequences': 1, 'omit': ''}
        metric_specs = DESIGN_SEQUENCE_SPECS
        progress_phases = (('design', 0.0, 1.0),)

        def check_available(self):
            return None

        def parse_backbone(self, backbone, name='', fixed=(), source='', state=1):
            spec = BackboneSpec(backbone.get('residues') or (), name=name,
                                designer_id=self.id, fixed=fixed, source=source,
                                state=state)
            require_designable(spec)
            return spec

        def submit(self, spec, options, weights_path):
            return FakeSequenceJob(spec, options, weights_path)

    class FakePred(Predictor):
        id = PRED
        name = 'Fake predictor'
        weight_bundle = None
        metric_specs = UNSCORED_SPECS

        def check_available(self):
            return None

        def parse_spec(self, sequence, name=''):
            return PredictionSpec(parse_chains(sequence), name)

        def submit(self, spec, options, weights_path):
            return FakeFoldJob(spec, options, weights_path)

    dreg.register(FakeDesigner(), replace=True)
    preg.register(FakePred(), replace=True)


def deliver_sequences(jobs):
    from pymol import designing_sequences
    for job in (jobs if isinstance(jobs, (list, tuple)) else [jobs]):
        status = job.status()
        if status['state'] == 'done':
            job.write()
            designing_sequences.deliver_result(status['result_path'], job.spec.name)


def deliver_models(jobs):
    from pymol import predicting
    for job in (jobs if isinstance(jobs, (list, tuple)) else [jobs]):
        job.write()
        predicting.deliver_result(job.status()['result_path'], job.spec.name,
                                  seed=job.options.seed)


class SequenceDesignTestCase(testing.PyMOLTestCase):

    def setUp(self):
        testing.PyMOLTestCase.setUp(self)
        from pymol.designers import registry as dreg
        from pymol.predictors import registry as preg
        self._designers = {did: dreg.get(did) for did in dreg.available()}
        self._preds = {pid: preg.get(pid) for pid in preg.available()}
        self._schemas = dict(mschema._SCHEMAS)
        _RESULTS['dir'] = tempfile.mkdtemp()
        store.reset()
        # Every test gets its own $RAYMOL_SETS_DIR (#447 review): the working container
        # otherwise lands in the real $TMPDIR and accumulates there.
        self._sets_dir = tempfile.mkdtemp(prefix='raymol_sets_dir_')
        self._had_sets_dir = os.environ.get('RAYMOL_SETS_DIR')
        os.environ['RAYMOL_SETS_DIR'] = self._sets_dir
        batch.clear()
        _install_fakes()

    def tearDown(self):
        from pymol import designing_sequences, predicting
        from pymol.designers import registry as dreg
        from pymol.predictors import registry as preg
        for module in (designing_sequences, predicting):
            try:
                module.clear_pending()
            except Exception:
                pass
            module._JOBS.clear()
        batch.clear()
        binding.clear_peek()
        store.reset()
        mstore.clear()
        for did in list(dreg.available()):
            if did not in self._designers:
                dreg.unregister(did)
        for pid in list(preg.available()):
            if pid not in self._preds:
                preg.unregister(pid)
        mschema._SCHEMAS.clear()
        mschema._SCHEMAS.update(self._schemas)
        shutil.rmtree(_RESULTS['dir'], ignore_errors=True)
        testing.PyMOLTestCase.tearDown(self)
        if self._had_sets_dir is None:
            os.environ.pop('RAYMOL_SETS_DIR', None)
        else:
            os.environ['RAYMOL_SETS_DIR'] = self._had_sets_dir
        shutil.rmtree(self._sets_dir, ignore_errors=True)

    # -- helpers --------------------------------------------------------------------

    def helix(self, name, length=8):
        cmd.fab('A' * length, name, ss=1)
        cmd.alter(name, 'chain="A"')
        cmd.sort(name)
        return name

    def backbone_set(self, name='bb', count=3, length=8):
        """A parent set of `count` backbone entries, captured from real objects."""
        cmd.set_create(name)
        for index in range(count):
            obj = self.helix('bb_%d' % index, length=length)
            cmd.set_add(name, obj)
            cmd.delete(obj)
        return store.active().get_set(name)

    @staticmethod
    def sets():
        return store.active().sets()


class ChildSetOfSequences(SequenceDesignTestCase):

    def testEveryBackboneTimesEverySequenceIsAnEntryWithItsParent(self):
        """3 backbones x 4 sequences is a 12-entry child set, one run, parents intact."""
        parent = self.backbone_set(count=3)
        jobs = cmd.design_sequences(DESIGNER, 'set:bb@all', n_sequences=4, seed=7)
        self.assertEqual(len(jobs), 3)                 # ONE job per backbone, not 12

        child = [row for row in self.sets() if row['name'] != 'bb']
        self.assertEqual(len(child), 1, [row['name'] for row in child])
        child = child[0]
        self.assertEqual(child['kind'], 'sequences')
        self.assertEqual(child['tool'], DESIGNER)
        self.assertTrue(child['name'].startswith(DESIGNER + '_'), child['name'])

        c = store.active()
        runs = c.runs(child['id'])
        self.assertEqual(len(runs), 1)
        self.assertEqual(runs[0]['parent_set_id'], parent['id'])
        self.assertEqual(runs[0]['inputs']['selector'], 'all')
        self.assertEqual(runs[0]['inputs']['n_sequences'], 4)
        self.assertEqual(runs[0]['inputs']['seed'], 7)
        self.assertEqual(sorted(runs[0]['inputs']['parents']),
                         sorted(e['id'] for e in c.entries(parent['id'])))
        # The badge counts SEQUENCES, not backbones: 3 x 4 members are outstanding.
        self.assertEqual(batch.running()[child['id']]['total'], 12)

        deliver_sequences(jobs)

        self.assertEqual(c.count(child['id']), 12)
        entries = c.entries(child['id'])
        by_parent = {}
        for entry in entries:
            self.assertEqual(len(entry['parents']), 1)
            by_parent.setdefault(entry['parents'][0], []).append(
                entry['scalars']['sequence_n'])
            self.assertEqual(entry['run_id'], runs[0]['id'])
            self.assertEqual(entry['sequences'].keys(), {'A'})
            # No structure blob: a sequence entry has none until something folds it.
            self.assertEqual(c.chain_cifs(entry['id']), [])
            self.assertIsNone(entry['staged_object'])
        self.assertEqual(sorted(by_parent),
                         sorted(e['id'] for e in c.entries(parent['id'])))
        self.assertTrue(all(sorted(v) == [1, 2, 3, 4] for v in by_parent.values()),
                        by_parent)

        columns = {col['column'] for col in c.columns(child['id']) if col.get('column')}
        for key in ('sequence_n', 'seed', 'sequence_recovery', 'mean_certainty',
                    'mean_native_fit', 'temperature', 'elapsed_s'):
            self.assertIn(key, columns)
        # The residue arrays are there for #419's heat strips to draw.
        arrays = c.arrays_of(entries[0]['id'])
        self.assertEqual(sorted(a['key'] for a in arrays),
                         ['certainty', 'native_fit'])
        index, values = c.array(entries[0]['id'], 'certainty')
        self.assertEqual(len(index), len(values))
        self.assertEqual(len(values), 8)

        # Every member settled: the badge is gone and nothing is pending.
        from pymol import designing_sequences
        self.assertEqual(batch.running(), {})
        self.assertEqual(designing_sequences._PENDING, {})

    def testOneSequenceKeepsTheParentsName(self):
        self.backbone_set(count=2)
        jobs = cmd.design_sequences(DESIGNER, 'set:bb@all')
        deliver_sequences(jobs)
        c = store.active()
        child = [row for row in self.sets() if row['name'] != 'bb'][0]
        parents = {e['id']: e['name'] for e in c.entries(c.get_set('bb')['id'])}
        for entry in c.entries(child['id']):
            self.assertEqual(entry['name'], parents[entry['parents'][0]])

    def testASecondRunNumbersItsChildSetAndNameIsHonoured(self):
        self.backbone_set(count=1)
        deliver_sequences(cmd.design_sequences(DESIGNER, 'set:bb@all'))
        deliver_sequences(cmd.design_sequences(DESIGNER, 'set:bb@all'))
        names = sorted(row['name'] for row in self.sets())
        self.assertEqual(names, sorted(['%s_1' % DESIGNER, '%s_2' % DESIGNER, 'bb']))
        deliver_sequences(cmd.design_sequences(DESIGNER, 'set:bb@all', name='chosen'))
        self.assertIn('chosen', [row['name'] for row in self.sets()])
        with self.assertRaises(Exception):
            cmd.design_sequences(DESIGNER, 'set:bb@all', name='chosen')

    def testASequenceOnlyParentIsRefusedBeforeAnyJobStarts(self):
        """A sequence cannot be redesigned: there is no backbone to thread onto."""
        cmd.set_create('seqs', kind='sequences')
        c = store.active()
        c.add_entry(c.get_set('seqs')['id'], 'lonely', sequences={'A': 'ACDEFGHI'})
        with self.assertRaises(Exception) as caught:
            cmd.design_sequences(DESIGNER, 'set:seqs@all')
        self.assertIn('no structure to design against', str(caught.exception))
        from pymol import designing_sequences
        self.assertEqual(designing_sequences._PENDING, {})
        # No half-made child set: the refusal came before `batch.open`.
        self.assertEqual([row['name'] for row in self.sets()], ['seqs'])

    def testFixedIsRefusedForASetBecauseASelectionMeansNothingThere(self):
        self.backbone_set(count=1)
        with self.assertRaises(Exception) as caught:
            cmd.design_sequences(DESIGNER, 'set:bb@all', fixed='resi 3')
        self.assertIn('only means something for an object input',
                      str(caught.exception))


class CancelMidBatch(SequenceDesignTestCase):

    def testCancellingEverythingLeavesNoOrphanSet(self):
        self.backbone_set(count=3)
        jobs = cmd.design_sequences(DESIGNER, 'set:bb@all', n_sequences=2)
        child = [row for row in self.sets() if row['name'] != 'bb'][0]
        cmd.design_sequences_cancel(child['name'])
        self.assertTrue(all(job.cancelled for job in jobs))
        # The runtime writes a terminal status and the shell calls discard_pending.
        from pymol import designing_sequences
        for job in jobs:
            designing_sequences.discard_pending(job.spec.name)
        self.assertEqual([row['name'] for row in self.sets()], ['bb'])
        self.assertEqual(batch.running(), {})

    def testWhatLandedBeforeTheCancelIsKept(self):
        self.backbone_set(count=3)
        jobs = cmd.design_sequences(DESIGNER, 'set:bb@all', n_sequences=2)
        deliver_sequences(jobs[0])
        from pymol import designing_sequences
        for job in jobs[1:]:
            job.cancel()
            designing_sequences.discard_pending(job.spec.name)
        child = [row for row in self.sets() if row['name'] != 'bb']
        self.assertEqual(len(child), 1)
        self.assertEqual(store.active().count(child[0]['id']), 2)
        self.assertEqual(batch.running(), {})


class ObjectPath(SequenceDesignTestCase):

    def testAnObjectRecordsOneMetricsRunPerSequenceAndMakesNoSet(self):
        self.helix('bb', length=10)
        job = cmd.design_sequences(DESIGNER, 'bb', n_sequences=3, seed=5)
        self.assertFalse(isinstance(job, list))
        deliver_sequences(job)
        runs = mstore.runs(object='bb')
        self.assertEqual(len(runs), 3)
        self.assertEqual(sorted(r.inputs['sequence_n'] for r in runs), [1, 2, 3])
        keys = {value.key for value in runs[0].values}
        self.assertIn('native_fit', keys)
        self.assertIn('certainty', keys)
        self.assertIn('sequence_recovery', keys)
        # No set is created, and the object is untouched -- nothing here loads or
        # deletes anything in the session.
        self.assertEqual(self.sets(), [])
        self.assertIn('bb', cmd.get_names('objects'))
        self.assertEqual(cmd.count_atoms('bb and name CA'), 10)

    def testTwoObjectsAreRefusedRatherThanRunTwice(self):
        self.helix('one', length=6)
        self.helix('two', length=6)
        with self.assertRaises(Exception) as caught:
            cmd.design_sequences(DESIGNER, 'one or two')
        self.assertIn('exactly one object', str(caught.exception))


class TheWholeChain(SequenceDesignTestCase):

    def testPredictFoldsTheChildSetAndTheLineageSurvivesARaymolRoundTrip(self):
        self.backbone_set(count=2)
        deliver_sequences(cmd.design_sequences(DESIGNER, 'set:bb@all', n_sequences=2))
        child = [row for row in self.sets() if row['name'] != 'bb'][0]

        # The link this issue exists for: the child set folds.
        models = cmd.predict(PRED, 'set:%s@all' % child['name'])
        deliver_models(models)
        c = store.active()
        folded = [row for row in self.sets()
                  if row['name'] not in ('bb', child['name'])]
        self.assertEqual(len(folded), 1, [row['name'] for row in self.sets()])
        folded = folded[0]
        self.assertEqual(folded['kind'], 'structures')
        self.assertEqual(c.count(folded['id']), 4)
        self.assertEqual(c.runs(folded['id'])[0]['parent_set_id'], child['id'])
        child_ids = {e['id'] for e in c.entries(child['id'])}
        for entry in c.entries(folded['id']):
            self.assertIn(entry['parents'][0], child_ids)

        path = os.path.join(_RESULTS['dir'], 'chain.raymol')
        cmd.save(path)
        cmd.reinitialize()
        cmd.load(path)
        c = store.active()
        names = sorted(row['name'] for row in c.sets())
        self.assertEqual(names, sorted(['bb', child['name'], folded['name']]))
        reborn_child = c.get_set(child['name'])
        parents = {e['id'] for e in c.entries(c.get_set('bb')['id'])}
        for entry in c.entries(reborn_child['id']):
            self.assertIn(entry['parents'][0], parents)
            self.assertEqual(sorted(a['key'] for a in c.arrays_of(entry['id'])),
                             ['certainty', 'native_fit'])
        self.assertEqual(len(parents), 2)
        self.assertEqual(c.count(c.get_set(folded['name'])['id']), 4)
