"""End-to-end flow through cmd.binder_design with a stub generator. No Swift, no network.

    pymol -ckqy testing/testing.py --run testing/tests/generate/generate_api.py
"""
import os
import sys
from unittest.mock import patch

from pymol import cmd

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

from generate_harness import (FakeResponse, GeneratorTestCase,  # noqa: E402
                             deliver, install_stub, make_zip, settle)


class BinderDesignTest(GeneratorTestCase):

    def setUp(self):
        GeneratorTestCase.setUp(self)
        import tempfile
        self.data, self.digest = make_zip()
        self.root = tempfile.mkdtemp()
        os.environ['RAYMOL_WEIGHTS_DIR'] = self.root
        install_stub(self.digest, len(self.data))
        self.declareHost('stubruntime')
        self.helix()

    # -- The happy path ------------------------------------------------------

    def testADesignLandsAsOneObjectHoldingTargetAndDesignedChain(self):
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data)):
            job = cmd.binder_design('stubgen', 'tgt', 'tgt and resi 5+8+11', length=12)
            settle()
        deliver(job)
        name = job.spec.name
        self.assertIn(name, cmd.get_names('objects'))
        # The PAIR, not the design alone. Splitting them here would make the refold step
        # re-derive the complex, which is the thing this data model exists to avoid.
        self.assertEqual(sorted(cmd.get_chains(name)), ['A', 'B'])
        self.assertEqual(cmd.count_atoms('%s and chain B and name CA' % name), 12)
        self.assertEqual(cmd.count_atoms('%s and chain A and name CA' % name), 20)

    def testADesignWithNoHotspotsRunsAndSaysItIsUnguided(self):
        # The hotspot argument is now OPTIONAL. Omitted entirely -- not passed empty --
        # because that is the command line a user will actually type.
        import io as _io
        from contextlib import redirect_stdout
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data)):
            with redirect_stdout(_io.StringIO()) as buf:
                job = cmd.binder_design('stubgen', 'tgt', length=8)
            settle()
        deliver(job)
        self.assertEqual(job.spec.target.hotspots, ())
        self.assertIn(job.spec.name, cmd.get_names('objects'))
        # And it is AUDIBLE regardless of `quiet`: unguided placement changes what the run
        # means, and the two ways of reaching it read differently.
        said = buf.getvalue()
        self.assertIn('UNGUIDED', said)
        self.assertIn('no hotspots given', said)

    def testASelectionThatMatchedNothingSaysSoRatherThanNothing(self):
        # The other arm. A selection WAS given and did not resolve -- the user believes
        # they pointed at something, so the warning names what they typed.
        import io as _io
        from contextlib import redirect_stdout
        cmd.select('sele', 'none')
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data)):
            with redirect_stdout(_io.StringIO()) as buf:
                job = cmd.binder_design('stubgen', 'tgt', 'sele', length=8)
            settle()
        deliver(job)
        self.assertEqual(job.spec.target.hotspots, ())
        said = buf.getvalue()
        self.assertIn('UNGUIDED', said)
        self.assertIn("'sele' matches no atoms", said)

    def testAGuidedRunSaysNothingAboutBeingUnguided(self):
        # The control for both of the above, in the suite rather than in my shell: the
        # warning must be a property of having no hotspots, not something printed always.
        import io as _io
        from contextlib import redirect_stdout
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data)):
            with redirect_stdout(_io.StringIO()) as buf:
                job = cmd.binder_design('stubgen', 'tgt', 'tgt and resi 5', length=8)
            settle()
        deliver(job)
        self.assertNotIn('UNGUIDED', buf.getvalue())

    def testTheHotspotsAreStillPartOfTheDesignKey(self):
        # Unguided is a DIFFERENT design from a guided one, so it must not key the same.
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data)):
            guided = cmd.binder_design('stubgen', 'tgt', 'tgt and resi 5', length=8,
                                         seed=1)
            settle()
            free = cmd.binder_design('stubgen', 'tgt', length=8, seed=1)
            settle()
        self.assertNotEqual(guided.spec.design_key(guided.options),
                            free.spec.design_key(free.options))

    def testTheTargetIsUnmovedInTheEmittedObject(self):
        # The contract is that the target is held fixed, so the emitted copy must sit on
        # the source atom for atom. Asserted as a real distance rather than a chain count.
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data)):
            job = cmd.binder_design('stubgen', 'tgt', 'tgt and resi 5', length=6)
            settle()
        deliver(job)
        name = job.spec.name
        source = cmd.get_coords('tgt and name CA')
        landed = cmd.get_coords('%s and chain A and name CA' % name)
        self.assertEqual(len(source), len(landed))
        worst = max(sum((a - b) ** 2 for a, b in zip(p, q)) ** 0.5
                    for p, q in zip(source, landed))
        self.assertLess(worst, 1e-3, 'target drifted by %.4f A' % worst)

    def testTheObjectNameIsDerivedFromTheDesignKey(self):
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data)):
            job = cmd.binder_design('stubgen', 'tgt', 'tgt and resi 5', length=6, seed=3)
            settle()
        from pymol.designing import default_object_name
        key = job.spec.design_key(job.options, weights_version='stubgen v1')
        self.assertEqual(job.spec.name, default_object_name(key, 'stubgen'))
        self.assertTrue(job.spec.name.startswith('stubgen_design_'), job.spec.name)

    def testTwoSeedsAreTwoObjectsNotTwoStates(self):
        # A design is a molecule, not a sample of one distribution over one input, so two
        # seeds must not stack as states of one object -- there would be one metric row per
        # state with nothing saying which sequence each described.
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data)):
            jobs = cmd.binder_design('stubgen', 'tgt', 'tgt and resi 5', length=6,
                                       n_designs=3, seed=1)
            settle()
        deliver(jobs)
        names = {job.spec.name for job in jobs}
        self.assertEqual(len(names), 3, names)
        for name in names:
            self.assertEqual(cmd.count_states(name), 1)
        self.assertEqual(len({job.options.seed for job in jobs}), 3,
                         'each design needs its own seed or they are the same molecule')

    def testAnIdenticalRerunLandsInTheSameObject(self):
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data)):
            first = cmd.binder_design('stubgen', 'tgt', 'tgt and resi 5', length=6,
                                        seed=42)
            settle()
        with patch('pymol.predictors.weights._urlopen',
                   side_effect=AssertionError('must not re-download')):
            second = cmd.binder_design('stubgen', 'tgt', 'tgt and resi 5', length=6,
                                         seed=42)
            settle()
        self.assertEqual(first.spec.name, second.spec.name)

    def testAnExplicitNameIsHonouredAndIndexedForSeveral(self):
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data)):
            job = cmd.binder_design('stubgen', 'tgt', 'tgt and resi 5', length=6,
                                      name='mine')
            settle()
        self.assertEqual(job.spec.name, 'mine')
        with patch('pymol.predictors.weights._urlopen',
                   side_effect=AssertionError('must not re-download')):
            jobs = cmd.binder_design('stubgen', 'tgt', 'tgt and resi 5', length=6,
                                       name='several', n_designs=2)
            settle()
        self.assertEqual([job.spec.name for job in jobs], ['several_01', 'several_02'])

    # -- The batch: one invocation, one group, one progress row ----------------

    def _batch(self, count=3, **kwargs):
        """Submit `count` designs in one command and return the job handles."""
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data)):
            jobs = cmd.binder_design('stubgen', 'tgt', 'tgt and resi 5', length=6,
                                       n_designs=count, **kwargs)
            settle()
        return jobs

    def groups(self):
        return list(cmd.get_names('public_group_objects'))

    @staticmethod
    def children(group):
        """Real membership of `group`, from the session record.

        NOT `cmd.get_object_list`, which reports a group's molecular leaves and therefore
        answers `[]` for a group of zero-atom placeholders -- which is most of a batch's
        life. `entry[6]` is the parent, the same field `appkit_inspector.group_parents`
        reads.
        """
        return [entry[0] for entry in (cmd.get_session(partial=1).get('names') or [])
                if entry and len(entry) > 6 and entry[6] == group]

    @staticmethod
    def real(job):
        """The submitted job behind a deferred handle -- what a test pokes at.

        `binder_design` returns a `_DeferredDesignJob` whenever the weights were not
        already cached, and the stub it wraps is what records a cancel and what reports a
        status. Same unwrapping the harness's `deliver` does.
        """
        return getattr(job, '_real', None) or job

    def testTheDesignsOfOneCommandLandInOneGroup(self):
        # The user's request, in its plainest form: ten designs should be one expandable
        # row in the object panel, not ten flat ones.
        jobs = self._batch(3, seed=11)
        deliver(jobs)
        self.assertEqual(len(self.groups()), 1, self.groups())
        group = self.groups()[0]
        self.assertEqual(sorted(cmd.get_object_list(group)),
                         sorted(job.spec.name for job in jobs))
        # And they are still THERE, enabled, with their atoms -- grouping is organisation,
        # not a move into a drawer that turns them off.
        enabled = set(cmd.get_names('objects', enabled_only=1))
        for job in jobs:
            self.assertIn(job.spec.name, enabled)
            self.assertEqual(sorted(cmd.get_chains(job.spec.name)), ['A', 'B'])

    def testTheGroupIsNamedForTheBatchAndNeverCallsAnythingABinder(self):
        jobs = self._batch(2, seed=11)
        deliver(jobs)
        group = self.groups()[0]
        from pymol.designing import default_group_name
        key = jobs[0].spec.design_key(jobs[0].options, weights_version='stubgen v1')
        self.assertEqual(group, default_group_name(key, 'stubgen'))
        self.assertTrue(group.startswith('stubgen_batch_'), group)
        # The naming rule: the tool may be called Binder Design, but nothing that NAMES
        # the output may call it a binder -- and a group name is a name for N of them.
        self.assertNotIn('binder', group.lower())

    def testASingleDesignMakesNoGroupAtAll(self):
        # A group of one is noise. n_designs=1 must be untouched by any of this.
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data)):
            job = cmd.binder_design('stubgen', 'tgt', 'tgt and resi 5', length=6)
            settle()
        deliver(job)
        self.assertEqual(self.groups(), [])
        self.assertIn(job.spec.name, cmd.get_names('objects'))
        from pymol import designing
        self.assertEqual(designing._BATCH, {})
        self.assertIsNone(designing.pending_info(job.spec.name))

    def testTheGroupExistsFromTheMOMENTTheCommandReturns(self):
        # The clutter this removes is MID-RUN clutter: ten `rfd3_design_*` rows sitting at
        # top level for the hours the batch takes. A group that only formed at delivery
        # would leave that picture unchanged for the whole run.
        jobs = self._batch(3, seed=11)
        self.assertEqual(len(self.groups()), 1, self.groups())
        group = self.groups()[0]
        self.assertEqual(sorted(self.children(group)),
                         sorted(job.spec.name for job in jobs),
                         'every placeholder is in the group before anything has run')
        # And they are still greyed as pending, which is what the group must not change.
        from pymol import designing
        for job in jobs:
            self.assertIsNotNone(designing.pending_info(job.spec.name))
        deliver(jobs)
        self.assertEqual(sorted(self.children(group)),
                         sorted(job.spec.name for job in jobs))

    def testAnEmptyPLACEHOLDERGroupIsNotVisibleToGetObjectList(self):
        # Why the teardown reads the session record instead. `get_object_list` reports a
        # group's MOLECULAR LEAVES, so on a group of zero-atom placeholders it answers
        # "empty" -- and the teardown's whole job is to decide whether the group is empty
        # before deleting it, which takes its members with it.
        jobs = self._batch(2, seed=11)
        group = self.groups()[0]
        self.assertEqual(cmd.get_object_list(group), [])
        self.assertEqual(len(self.children(group)), 2)

    def testABatchThatNeverLANDSAnythingLeavesNoGroupBehind(self):
        # The first cost of being early, handled rather than avoided: cancelled or failed,
        # a batch leaves no group, exactly as it leaves no placeholders.
        jobs = self._batch(3, seed=11)
        from pymol import designing
        group = self.groups()[0]
        for job in jobs:
            self.real(job).status = lambda: {
                'state': 'cancelled', 'phase': 'diffusion', 'fraction': 0.0,
                'error': None, 'result_path': None, 'peak_bytes': None,
                'elapsed_s': 2.0}
            designing.discard_pending(job.spec.name)
        self.assertEqual(self.groups(), [], 'the empty group must go with its members')
        self.assertNotIn(group, cmd.get_names('objects'))

    def testAGroupIsNEVERDeletedWhileAnythingIsStillInIt(self):
        # `cmd.delete` on a group deletes its MEMBERS TOO -- measured -- so the teardown
        # firing one design too early would destroy a design that took minutes. Two
        # deliver, one is cancelled: the group and both designs must survive.
        jobs = self._batch(3, seed=11)
        from pymol import designing
        group = self.groups()[0]
        deliver([jobs[0], jobs[2]])
        self.real(jobs[1]).status = lambda: {
            'state': 'cancelled', 'phase': 'diffusion', 'fraction': 0.0, 'error': None,
            'result_path': None, 'peak_bytes': None, 'elapsed_s': 2.0}
        designing.discard_pending(jobs[1].spec.name)
        self.assertEqual(self.groups(), [group])
        self.assertEqual(sorted(self.children(group)),
                         sorted([jobs[0].spec.name, jobs[2].spec.name]))
        for job in (jobs[0], jobs[2]):
            self.assertGreater(cmd.count_atoms(job.spec.name), 0)

    def testTheTeardownDoesNotREADTheSessionUntilItsLastMemberIsGone(self):
        # The pre-filter is an OPTIMISATION, and it is covered as one rather than left as
        # a branch with no observable. `get_session(partial=1)` is the only complete
        # source of a group's membership and it serialises every object: measured 0.11 ms
        # at 200 atoms, 1.29 ms at 2,000 and 7.01 ms at 10,000. `discard_pending` runs on
        # the main thread every time a job settles, so a ten-design batch against a real
        # target would pay that ten times to answer "no" nine of them.
        jobs = self._batch(3, seed=11)
        from pymol import designing
        reads = []

        class CountingCmd:
            def __init__(self, inner): self._inner = inner
            def __getattr__(self, name): return getattr(self._inner, name)
            def get_session(self, *args, **kwargs):
                reads.append(1)
                return self._inner.get_session(*args, **kwargs)

        counting = CountingCmd(cmd)
        for job in jobs[:2]:
            self.real(job).status = lambda: {
                'state': 'cancelled', 'phase': 'diffusion', 'fraction': 0.0,
                'error': None, 'result_path': None, 'peak_bytes': None,
                'elapsed_s': 2.0}
            designing.discard_pending(job.spec.name, _self=counting)
        self.assertEqual(reads, [], 'nothing may read the session while members remain')
        self.real(jobs[2]).status = lambda: {
            'state': 'cancelled', 'phase': 'diffusion', 'fraction': 0.0, 'error': None,
            'result_path': None, 'peak_bytes': None, 'elapsed_s': 2.0}
        designing.discard_pending(jobs[2].spec.name, _self=counting)
        self.assertEqual(len(reads), 1, 'exactly once, on the last member')
        self.assertEqual(self.groups(), [])

    def testAGroupHOLDINGSOMETHINGTheUserPutThereIsNotDeleted(self):
        # The reason the teardown reads real membership rather than trusting its own list:
        # a group deletion takes everything inside with it, so an object the user dragged
        # in must veto it.
        jobs = self._batch(2, seed=11)
        from pymol import designing
        group = self.groups()[0]
        cmd.fab('AAAA', 'mine', ss=1)
        cmd.group(group, 'mine', action='add')
        for job in jobs:
            self.real(job).status = lambda: {
                'state': 'cancelled', 'phase': 'diffusion', 'fraction': 0.0,
                'error': None, 'result_path': None, 'peak_bytes': None,
                'elapsed_s': 2.0}
            designing.discard_pending(job.spec.name)
        self.assertEqual(self.groups(), [group], 'the group still holds the user\'s object')
        self.assertEqual(cmd.count_atoms('mine'), 40)

    def testAPARTIALSessionIsAReadAndIsNotFiltered(self):
        # THE reason up-front grouping works at all, and it is not obvious: RayMol reads
        # the object TREE out of `cmd.get_session(partial=1)` -- `entry[6]` is the parent,
        # and nothing else reports a group's non-molecular children. Filtering that read
        # made a batch's pending placeholders invisible to `group_parents`, so the panel
        # drew ten flat rows next to an empty group -- the exact clutter grouping early is
        # meant to remove. Measured before the fix: `group_parents` returned {}.
        from pymol import appkit_inspector, designing
        jobs = self._batch(3, seed=11)
        group = self.groups()[0]
        parents = appkit_inspector.group_parents(cmd.get_names('objects'),
                                                 cmd.get_names('public_group_objects'))
        for job in jobs:
            self.assertEqual(parents.get(job.spec.name), group,
                             'the panel must see a pending placeholder inside its group')
        # ...and a FULL session is still filtered, which is what session_save is for.
        full = cmd.get_session(partial=0)
        saved = [entry[0] for entry in (full.get('names') or []) if entry]
        for job in jobs:
            self.assertNotIn(job.spec.name, saved)

    def testAMidRunSessionSaveCarriesNeitherThePlaceholdersNorTheirGroup(self):
        # The second cost of being early. An empty group is a real object and DOES survive
        # a .pse round trip (measured), so without this a session saved mid-batch reopens
        # holding a container named after designs that never existed.
        jobs = self._batch(3, seed=11)
        from pymol import designing
        group = self.groups()[0]
        session = {'names': [[name] + [None] * 6 for name in cmd.get_names('objects')]}
        for entry in session['names']:
            entry[6] = group if entry[0] != group and entry[0] != 'tgt' else ''
        designing.session_save(session)
        saved = [entry[0] for entry in session['names']]
        self.assertEqual(saved, ['tgt'])
        self.assertNotIn(group, saved)

    def testASessionSaveKEEPSTheGroupOnceADesignHasLanded(self):
        # ...and only then. A group holding a finished design is a real result and must
        # round-trip with it.
        jobs = self._batch(3, seed=11)
        from pymol import designing
        group = self.groups()[0]
        deliver(jobs[0])
        session = {'names': [[name] + [None] * 6 for name in cmd.get_names('objects')]}
        for entry in session['names']:
            entry[6] = group if entry[0] not in (group, 'tgt') else ''
        designing.session_save(session)
        saved = [entry[0] for entry in session['names']]
        self.assertIn(group, saved)
        self.assertIn(jobs[0].spec.name, saved)
        self.assertNotIn(jobs[1].spec.name, saved)

    def testAnExplicitNameBecomesTheGroupAndTheIndexedObjectsItsMembers(self):
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data)):
            jobs = cmd.binder_design('stubgen', 'tgt', 'tgt and resi 5', length=6,
                                       name='several', n_designs=2)
            settle()
        deliver(jobs)
        self.assertEqual(self.groups(), ['several'])
        self.assertEqual(sorted(cmd.get_object_list('several')),
                         ['several_01', 'several_02'])

    def testAGroupNameAlreadyTakenByAMoleculeMovesAside(self):
        # `cmd.group` on a name that is already a molecule RAISES -- measured, not
        # assumed -- and it would do so inside delivery, minutes after the command
        # returned. So the collision is resolved at submit time.
        cmd.fab('AAAA', 'several', ss=1)
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data)):
            jobs = cmd.binder_design('stubgen', 'tgt', 'tgt and resi 5', length=6,
                                       name='several', n_designs=2)
            settle()
        deliver(jobs)
        self.assertEqual(self.groups(), ['several_2'])
        self.assertEqual(sorted(cmd.get_object_list('several_2')),
                         ['several_01', 'several_02'])
        # And the object that was in the way is untouched.
        self.assertEqual(cmd.count_atoms('several'), 40)

    def testAnExplicitNameThatSomethingElseAnswersToIsRefused(self):
        # THE DESTRUCTIVE ONE. A design does not land BESIDE the object it names, it
        # lands IN it: `register_pending` adopts an existing object rather than creating
        # one, `deliver_result` loads into it -- and `cmd.load` into a non-empty object
        # ADDS atoms rather than replacing them -- while a live run calls `cmd.delete` on
        # the name first to start its recording clean. So `name=<the target>` on a live
        # run deletes the structure the design was generated against, seventeen minutes
        # after the command returned.
        #
        # Refused rather than moved aside, and refused BEFORE the weight fetch: the user
        # typed this string in order to find the design under it, so quietly delivering
        # to `tgt_2` is a design they will not look for.
        from pymol.predictors.errors import PredictionInputError
        before = cmd.count_atoms('tgt')
        with patch('pymol.predictors.weights._urlopen',
                   side_effect=AssertionError('must not fetch: refuse before the fetch')):
            with self.assertRaises(PredictionInputError) as caught:
                cmd.binder_design('stubgen', 'tgt', 'tgt and resi 5', length=6,
                                  name='tgt')
        self.assertIn('already taken', str(caught.exception))
        # Untouched, and still not pending -- a refusal leaves no bookkeeping behind.
        self.assertEqual(cmd.count_atoms('tgt'), before)
        from pymol import designing
        self.assertNotIn('tgt', designing._PENDING)

    def testAnExplicitNameIsAlsoRefusedForEveryMemberOfABatch(self):
        # `n_designs=2, name=X` delivers into `X_01` and `X_02`, so those are the names
        # that have to be free -- checking `X` alone would miss it. `X` itself is only
        # the GROUP, which is never loaded into and is moved aside non-destructively by
        # `_free_group_name` (see testAGroupNameAlreadyTakenByAMoleculeMovesAside).
        from pymol.predictors.errors import PredictionInputError
        cmd.fab('AAAA', 'several_02', ss=1)
        with patch('pymol.predictors.weights._urlopen',
                   side_effect=AssertionError('must not fetch: refuse before the fetch')):
            with self.assertRaises(PredictionInputError) as caught:
                cmd.binder_design('stubgen', 'tgt', 'tgt and resi 5', length=6,
                                  name='several', n_designs=2)
        self.assertIn('several_02', str(caught.exception))

    def testADerivedNameMovesAsideRatherThanLoadingOnTopOfAFinishedDesign(self):
        # The other half of the rule. Nobody chose `stubgen_design_<key>` -- it is a
        # digest -- so a suffix costs nothing and is better than a refusal for a name the
        # user never typed. What it must NOT do is deliver into the finished design that
        # already holds that name: `cmd.load` would double every atom, leaving one object
        # holding two copies of a design and nothing saying so.
        #
        # This is the case `testAnIdenticalRerunLandsInTheSameObject` does NOT cover: there
        # the first run is still pending, so its placeholder is empty and sharing it is
        # right. Here the first run has DELIVERED.
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data)):
            first = cmd.binder_design('stubgen', 'tgt', 'tgt and resi 5', length=6,
                                      seed=42)
            settle()
        deliver(first)
        atoms = cmd.count_atoms(first.spec.name)
        self.assertGreater(atoms, 0)
        with patch('pymol.predictors.weights._urlopen',
                   side_effect=AssertionError('must not re-download')):
            second = cmd.binder_design('stubgen', 'tgt', 'tgt and resi 5', length=6,
                                       seed=42)
            settle()
        self.assertEqual(second.spec.name, first.spec.name + '_2')
        deliver(second)
        # The first design is exactly as it was -- not doubled.
        self.assertEqual(cmd.count_atoms(first.spec.name), atoms)

    def testEveryDesignOfABatchPublishesTheSameBatchIdentity(self):
        # What the tray groups by. Published on the PANEL wire, in the record
        # `designing.pending_info` writes -- the runtime is told nothing about batches
        # because it has nothing to do with one.
        jobs = self._batch(3, seed=11)
        from pymol import designing
        seen = set()
        for position, job in enumerate(jobs, start=1):
            info = designing.pending_info(job.spec.name)
            seen.add(info['batch'])
            self.assertEqual(info['batch_index'], position)
            self.assertEqual(info['batch_total'], 3)
        self.assertEqual(len(seen), 1, 'one command is one batch: %r' % seen)
        # And that identity IS the group name the finished designs will land in -- one
        # string for the group, the tray row and the cancel argument.
        self.assertEqual(list(seen)[0], list(designing._BATCH)[0])
        deliver(jobs)
        self.assertEqual(self.groups(), [list(seen)[0]])

    def testASingleDesignsRecordCarriesNoBatchFields(self):
        # The negative half, and the reason the prediction lane cannot be affected: the
        # keys are absent unless a batch put them there.
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data)):
            job = cmd.binder_design('stubgen', 'tgt', 'tgt and resi 5', length=6)
            settle()
        from pymol import designing
        info = designing.pending_info(job.spec.name)
        self.assertEqual((info['batch'], info['batch_index'], info['batch_total']),
                         (None, None, None))

    def testCancellingTheBatchStopsEveryDesignQueuedBehindTheRunningOne(self):
        # ONE Cancel for the whole invocation: the design that is running and the ones
        # still queued on the runtime's serial queue. Passed the BATCH id, which is the
        # group name, because that is what the single tray row is keyed by.
        jobs = self._batch(3, seed=11)
        from pymol import designing
        batch = list(designing._BATCH)[0]
        cmd.design_cancel(batch)
        for job in jobs:
            self.assertTrue(self.real(job).cancelled,
                            '%s was left running' % job.spec.name)

    def testCancellingTheBatchLeavesADesignThatAlreadyLandedAlone(self):
        # Cancel stops what has not finished. What HAS finished took minutes and is a
        # real design -- it stays, in the group, with its atoms.
        jobs = self._batch(3, seed=11)
        deliver(jobs[0])
        from pymol import designing
        batch = list(designing._BATCH)[0]
        cmd.design_cancel(batch)
        for job in jobs[1:]:
            self.assertTrue(self.real(job).cancelled)
        # What the runtime does next for each cancelled job: settle, which discards the
        # placeholder. Driven here because there is no host in a headless test.
        for job in jobs[1:]:
            self.real(job).status = lambda: {
                'state': 'cancelled', 'phase': 'diffusion', 'fraction': 0.0,
                'error': None, 'result_path': None, 'peak_bytes': None,
                'elapsed_s': 2.0}
            designing.discard_pending(job.spec.name)
        landed = jobs[0].spec.name
        # The finished design stays, in the group, with its atoms.
        self.assertIn(landed, cmd.get_names('objects'))
        self.assertEqual(cmd.get_object_list(batch), [landed])
        self.assertGreater(cmd.count_atoms(landed), 0)
        # The two that never finished leave NOTHING -- their placeholders go with them,
        # which is the cancellation rule this branch already settled: the name means the
        # finished design or nothing.
        for job in jobs[1:]:
            self.assertNotIn(job.spec.name, cmd.get_names('objects'))
        # And their cards are RETAINED, still carrying the batch, so the row can say what
        # became of the invocation rather than vanishing.
        self.assertEqual(sorted(designing.recent_objects()),
                         sorted(job.spec.name for job in jobs[1:]))
        for job in jobs[1:]:
            self.assertEqual(designing.pending_info(job.spec.name)['batch'], batch)

    def testCancellingABatchWithNothingLeftToStopIsQuietRatherThanAnError(self):
        # A reachable race, not a hypothetical: the tray is drawn from a 2 Hz poll, and a
        # batch whose only surviving record is a RETAINED failure still has a row -- so
        # Cancel can arrive after the last outstanding design has settled. Nothing to
        # stop is not an error to raise at the user.
        jobs = self._batch(3, seed=11)
        from pymol import designing
        batch = list(designing._BATCH)[0]
        self.real(jobs[0]).status = lambda: {
            'state': 'failed', 'phase': 'diffusion', 'fraction': 0.0, 'error': 'boom',
            'result_path': None, 'peak_bytes': None, 'elapsed_s': 1.0}
        designing.discard_pending(jobs[0].spec.name)
        deliver(jobs[1:])
        self.assertEqual(designing.pending_objects(), {})
        self.assertIn(batch, designing._BATCH, 'a retained failure keeps the row up')
        self.assertEqual(cmd.design_cancel(batch), batch)

    def testOneDesignFailingDoesNotClaimTheOthersFailedOrStopThem(self):
        # THE PARTIAL FAILURE. Design 2 of 3 fails; the other two still deliver, land in
        # the group, and the failed one's card is retained -- still carrying its batch
        # identity, or the row would come apart from the batch on the tick it failed.
        jobs = self._batch(3, seed=11)
        from pymol import designing
        batch = list(designing._BATCH)[0]
        bad = jobs[1]
        self.real(bad).status = lambda: {'state': 'failed', 'phase': 'diffusion', 'fraction': 0.0,
                              'error': 'the target moved 3.500 A', 'result_path': None,
                              'peak_bytes': None, 'elapsed_s': 4.0}
        designing.discard_pending(bad.spec.name)          # what settle() does
        deliver([jobs[0], jobs[2]])
        retained = designing.pending_info(bad.spec.name)
        self.assertEqual(retained['state'], 'failed')
        self.assertEqual(retained['error'], 'the target moved 3.500 A')
        self.assertEqual(retained['batch'], batch)
        self.assertEqual(retained['batch_total'], 3)
        self.assertEqual(sorted(cmd.get_object_list(batch)),
                         sorted([jobs[0].spec.name, jobs[2].spec.name]))
        self.assertNotIn(bad.spec.name, cmd.get_names('objects'))

    def testDismissingTheBatchClearsEveryCardItStoodFor(self):
        # The failure card's Dismiss carries the batch id too, and has to reach members
        # that have already left `_PENDING` -- which is why the membership list is the
        # complete one rather than what is still outstanding.
        jobs = self._batch(3, seed=11)
        from pymol import designing
        batch = list(designing._BATCH)[0]
        for job in jobs:
            self.real(job).status = lambda: {'state': 'failed', 'phase': 'diffusion',
                                  'fraction': 0.0, 'error': 'boom', 'result_path': None,
                                  'peak_bytes': None, 'elapsed_s': 1.0}
            designing.discard_pending(job.spec.name)
        self.assertEqual(len(designing.recent_objects()), 3)
        cmd.design_dismiss(batch)
        self.assertEqual(designing.recent_objects(), [])
        self.assertEqual(designing._BATCH, {})

    def testBatchingChangesNothingAboutADESIGNSOwnIdentityOrItsMetrics(self):
        # The batch is presentation and organisation: which row a run occupies and which
        # group its object sits in. It must not touch the design key, the object name or
        # the metric run -- the three things a later refold is matched against.
        from pymol.metrics import store
        batched = self._batch(2, seed=7)
        with patch('pymol.predictors.weights._urlopen',
                   side_effect=AssertionError('must not re-download')):
            lone = cmd.binder_design('stubgen', 'tgt', 'tgt and resi 5', length=6,
                                       seed=7)
            settle()
        version = 'stubgen v1'
        self.assertEqual(
            batched[0].spec.design_key(batched[0].options, weights_version=version),
            lone.spec.design_key(lone.options, weights_version=version))
        # Same key, so the same derived object name -- and `register_pending` put both
        # jobs on that one placeholder rather than inventing a second object.
        self.assertEqual(batched[0].spec.name, lone.spec.name)
        deliver(batched)
        for job in batched:
            self.assertEqual(len(store.runs(object=job.spec.name)), 1,
                             'one metric run per delivered design, filed against its '
                             'own object and not against the group')
        self.addCleanup(store.clear)

    def testTheBatchIsForgottenOnceEveryDesignHasSettled(self):
        # Bounded, and it is what lets an identical re-run land back in the SAME group
        # rather than creeping to _2, _3 forever.
        jobs = self._batch(2, seed=11)
        from pymol import designing
        first = list(designing._BATCH)[0]
        deliver(jobs)
        self.assertEqual(designing._BATCH, {})
        self.assertEqual(designing._BATCH_OF, {})
        again = self._batch(2, seed=11)
        deliver(again)
        self.assertEqual(self.groups(), [first])

    # -- Live view -----------------------------------------------------------

    def testLiveViewRidesFromTheCommandOntoEveryDesignsSpec(self):
        # NOTHING else in the suite joins the command parameter to the spec field: with
        # the one line in binder_design that carries it deleted, 82 of 82 tests still
        # passed. This is also the only place the Python KWARG NAME is pinned -- it is
        # what a user types, and renaming it broke nothing.
        #
        # n_designs=2 on purpose: the per-design spec is rebuilt field by field, so a new
        # field that is not carried explicitly silently defaults to off for every design.
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data)):
            jobs = cmd.binder_design('stubgen', 'tgt', 'tgt and resi 5', length=6,
                                       n_designs=2, live_view=1)
            settle()
        self.assertEqual(len(jobs), 2)
        for job in jobs:
            self.assertIs(job.spec.live_view, True, job.spec.name)

    def testADesignIsNotWatchedUnlessItIsAskedFor(self):
        # Off by default, and a bool rather than the 0 that was passed in: the runtime
        # tests the flag with `== true`, and the wire carries whatever this holds.
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data)):
            job = cmd.binder_design('stubgen', 'tgt', 'tgt and resi 5', length=6)
            settle()
        self.assertIs(job.spec.live_view, False)

    # -- live_steps: how many states the recording ends up with ---------------

    def _design(self, **kwargs):
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data)):
            job = cmd.binder_design('stubgen', 'tgt', 'tgt and resi 5', length=6,
                                      **kwargs)
            settle()
        return job if not isinstance(job, list) else job[0]

    def testAskingForAStateCountTurnsTheLiveViewOnByItself(self):
        # Passing live_steps is an explicit opt-in -- having to pass live_view=1 as well
        # would be asking the user to say the same thing twice.
        from pymol import designing
        job = self._design(live_steps=12)
        self.assertIs(job.spec.live_view, True)
        # The spec carries the DERIVED interval, not the count that was asked for: the
        # arithmetic happens once, here, and the wire carries its answer.
        self.assertEqual(job.spec.live_interval, designing.capture_interval(12, 199))

    def testAskingForAStateCountAndAlsoTurningTheViewOffIsRefused(self):
        # A CONTRADICTION, refused rather than absorbed: it asks for a recording length
        # and for no recording in the same breath, and either reading throws one of the
        # two away silently -- which is the "a parameter you passed did nothing" failure
        # this feature keeps closing. Refusing also makes the case observable in something
        # other than a log line, which is all that used to distinguish the two paths.
        from pymol.predictors.errors import PredictionOptionError
        with self.assertRaises(PredictionOptionError) as caught:
            cmd.binder_design('stubgen', 'tgt', 'tgt and resi 5', length=6,
                                live_view=0, live_steps=12)
        message = str(caught.exception)
        self.assertIn('live_steps=12', message)
        self.assertIn('live_view=0', message)
        self.assertIn('drop whichever one you did not mean', message)

    def testLiveViewOnWithoutACountUsesTheRuntimeDefault(self):
        job = self._design(live_view=1)
        self.assertIs(job.spec.live_view, True)
        self.assertIsNone(job.spec.live_interval,
                          'absent must mean "the runtime default", not a number chosen '
                          'on this side')

    def testEveryDesignOfARunCarriesTheStateCount(self):
        # DesignSpec is a __slots__ class rebuilt field by field per design, so anything
        # not carried explicitly silently reverts for every design after the first.
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data)):
            jobs = cmd.binder_design('stubgen', 'tgt', 'tgt and resi 5', length=6,
                                       n_designs=2, live_steps=9)
            settle()
        self.assertEqual(len(jobs), 2)
        from pymol import designing
        expected = designing.capture_interval(9, 199)
        for job in jobs:
            self.assertEqual(job.spec.live_interval, expected, job.spec.name)
            self.assertIs(job.spec.live_view, True, job.spec.name)

    def testAStateCountOutsideWhatTheRolloutCanSupplyIsRefused(self):
        # Refused, not clamped, and before anything is allocated -- this is input
        # validation, not a runtime degrade.
        from pymol.predictors.errors import PredictionOptionError
        for bad in (0, -3, 200, 10000):
            with self.assertRaises(PredictionOptionError) as caught:
                cmd.binder_design('stubgen', 'tgt', 'tgt and resi 5', length=6,
                                    diffusion_steps=200, live_steps=bad)
            message = str(caught.exception)
            self.assertIn('live_steps must be between 1 and 199', message)
            self.assertIn('diffusion_steps=200', message,
                          'the message must name the schedule the bound came from')

    def testTheBoundFollowsDiffusionSteps(self):
        # The ceiling is the rollout's own step count, so it moves with the schedule.
        from pymol import designing
        from pymol.predictors.errors import PredictionOptionError
        job = self._design(diffusion_steps=20, live_steps=19)
        self.assertEqual(job.spec.live_interval, designing.capture_interval(19, 19))
        with self.assertRaises(PredictionOptionError) as caught:
            cmd.binder_design('stubgen', 'tgt', 'tgt and resi 5', length=6,
                                diffusion_steps=20, live_steps=20)
        self.assertIn('between 1 and 19', str(caught.exception))

    def testAMalformedStateCountIsRefusedWithTheSameGuidance(self):
        from pymol.predictors.errors import PredictionOptionError
        with self.assertRaises(PredictionOptionError) as caught:
            cmd.binder_design('stubgen', 'tgt', 'tgt and resi 5', length=6,
                                live_steps='lots')
        self.assertIn('live_steps must be a whole number', str(caught.exception))

    def testTheStateCountIsAbsentFromTheWireUnlessAskedFor(self):
        # Absent means "the runtime's default", which is also what a Python side that
        # predates this parameter says -- so the two are the SAME request, rather than one
        # of them pinning a number the other would not have.
        from pymol import designing
        from pymol.generators import rfd3
        from pymol.predictors import host

        structure = designing.resolve_target('tgt', 'tgt and resi 5')
        generator = rfd3.RFD3Generator()
        spec = generator.parse_target(structure, 6, name='wire_probe')
        options = generator.validate_options(
            dict(recycling_steps=2, diffusion_steps=200, seed=1))
        sent = {}

        def capture(spec_, options_, weights_path, runtime=None, knobs=None, extra=None):
            sent.clear()
            sent.update(extra or {})
            return object()

        with patch.object(host, 'submit', side_effect=capture):
            spec.live_view = True
            spec.live_interval = None
            generator.submit(spec, options, '/tmp')
            self.assertIn('live_view', sent)
            self.assertNotIn('live_interval', sent,
                             'an unasked-for cadence must not be pinned on the wire')

            spec.live_interval = 17
            generator.submit(spec, options, '/tmp')
            self.assertEqual(sent.get('live_interval'), 17,
                             'the wire carries the derived INTERVAL, not the count')
            self.assertNotIn('live_steps', sent)

    def testTheEchoSaysTheFramesAreKeptWhenTheyAre(self):
        from pymol import designing
        said = []
        original = designing.colorprinting.parrot
        designing.colorprinting.parrot = lambda text: said.append(text)
        try:
            self._design(live_steps=50, keep_frames=1, quiet=0)
        finally:
            designing.colorprinting.parrot = original
        live = [t for t in said if 'live view will capture' in t]
        self.assertTrue(live)
        self.assertIn('kept as states', live[0])
        self.assertNotIn('discarded', live[0])

    def testKeepingFramesTurnsTheLiveViewOnByItself(self):
        job = self._design(keep_frames=1)
        self.assertIs(job.spec.live_view, True)
        self.assertIs(job.spec.keep_frames, True)

    def testFramesAreDiscardedUnlessAskedFor(self):
        job = self._design(live_view=1)
        self.assertIs(job.spec.keep_frames, False,
                      'watching is the point; the states are opt-in')

    def testKeepingFramesWithTheLiveViewOffIsRefused(self):
        from pymol.predictors.errors import PredictionOptionError
        with self.assertRaises(PredictionOptionError) as caught:
            cmd.binder_design('stubgen', 'tgt', 'tgt and resi 5', length=6,
                                live_view=0, keep_frames=1)
        message = str(caught.exception)
        self.assertIn('keep_frames=1', message)
        self.assertIn('live_view=0', message)
        self.assertIn('drop whichever one you did not mean', message)

    def testEveryDesignOfARunCarriesTheKeepFlag(self):
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data)):
            jobs = cmd.binder_design('stubgen', 'tgt', 'tgt and resi 5', length=6,
                                       n_designs=2, keep_frames=1)
            settle()
        self.assertEqual(len(jobs), 2)
        for job in jobs:
            self.assertIs(job.spec.keep_frames, True, job.spec.name)

    def testTheKeepFlagIsAbsentFromTheWireUnlessAskedFor(self):
        from pymol import designing
        from pymol.generators import rfd3
        from pymol.predictors import host

        structure = designing.resolve_target('tgt', 'tgt and resi 5')
        generator = rfd3.RFD3Generator()
        spec = generator.parse_target(structure, 6, name='keep_probe')
        options = generator.validate_options(
            dict(recycling_steps=2, diffusion_steps=200, seed=1))
        sent = {}

        def capture(spec_, options_, weights_path, runtime=None, knobs=None, extra=None):
            sent.clear()
            sent.update(extra or {})
            return object()

        with patch.object(host, 'submit', side_effect=capture):
            spec.live_view = True
            spec.keep_frames = False
            generator.submit(spec, options, '/tmp')
            self.assertNotIn('keep_frames', sent,
                             'the default must not be pinned on the wire')
            spec.keep_frames = True
            generator.submit(spec, options, '/tmp')
            self.assertIs(sent.get('keep_frames'), True)

    # -- The derivation: a wanted state count -> an every-Nth-step -------------

    def _captured(self, interval, total):
        """What the rollout would actually capture, replaying Swift's capture RULE.

        `shouldCapture` is `step % interval == 0 || step == total`. Reproduced here on
        purpose: `capture_frame_count` is arithmetic ABOUT that rule, and if the two ever
        disagreed every derived interval would be wrong and nothing else would notice.
        """
        return [step for step in range(1, total + 1)
                if step % interval == 0 or step == total]

    def testTheFrameCountAgreesWithWhatTheCaptureRuleYields(self):
        from pymol import designing
        for total in (199, 99, 60, 19, 5, 1):
            for interval in range(1, total + 1):
                self.assertEqual(
                    designing.capture_frame_count(interval, total),
                    len(self._captured(interval, total)),
                    'interval %d over %d' % (interval, total))

    def testTheDerivedIntervalYieldsTheRequestedNumberOfStates(self):
        # Including 1, counts that divide evenly, and counts that cannot land exactly.
        # 199 steps admits 199, 100, 67, 50, 40, 34, ... so 7 IS reachable (interval 29),
        # while round(199/7) = 28 would give 8 -- which is why the derivation scans.
        from pymol import designing
        total = 199
        for wanted in (1, 2, 4, 7, 10, 12, 25, 40, 50, 67, 100, 199):
            interval = designing.capture_interval(wanted, total)
            self.assertEqual(len(self._captured(interval, total)), wanted,
                             'asked %d, interval %d' % (wanted, interval))

    def testAnUnreachableCountLandsOnTheNearestAchievableOne(self):
        # Nearest, not nearest-below: asked 99 of 199, "at most" would give 67.
        from pymol import designing
        total = 199
        interval = designing.capture_interval(99, total)
        self.assertEqual(len(self._captured(interval, total)), 100)
        # And it really is the nearest -- no interval does better.
        for candidate in range(1, total + 1):
            count = designing.capture_frame_count(candidate, total)
            self.assertGreaterEqual(abs(count - 99), 1,
                                    'interval %d gave %d' % (candidate, count))

    def testABadScheduleIsBlamedOnTheScheduleAndPromisesNothing(self):
        # The live block runs AFTER `validate_options`, and both halves of that matter.
        #
        # Before: `diffusion_steps=0, live_steps=5` raised "live_steps must be between 1
        # and 1" -- blaming the wrong parameter for a bad schedule -- and
        # `diffusion_steps=1, live_steps=1, quiet=0` PRINTED "will capture 1 state, every
        # 1 of the 1 rollout steps" and only then refused, promising a state count for a
        # run that never started.
        from pymol import designing
        from pymol.predictors.errors import PredictionOptionError
        for steps in (0, 1):
            said = []
            original = designing.colorprinting.parrot
            designing.colorprinting.parrot = lambda text: said.append(text)
            try:
                with self.assertRaises(PredictionOptionError) as caught:
                    cmd.binder_design('stubgen', 'tgt', 'tgt and resi 5', length=6,
                                        diffusion_steps=steps, live_steps=1, quiet=0)
            finally:
                designing.colorprinting.parrot = original
            message = str(caught.exception)
            self.assertIn('diffusion_steps', message,
                          'a bad schedule must be blamed on the schedule, got: %s'
                          % message)
            self.assertNotIn('live_steps must be', message,
                             'and must not be blamed on live_steps: %s' % message)
            self.assertFalse([t for t in said if 'live view will capture' in t],
                             'nothing may be promised for a run that never starts: %r'
                             % said)

    def testATIEKeepsTheFinerRecording(self):
        # THE unguarded decision, until now. `distance < best_distance` (strict) vs `<=`
        # is a real policy: when two intervals are equally far from what was asked, the
        # smaller one wins, because someone who asked for more states is better served by
        # one extra than by one fewer.
        #
        # The nearest test above uses 99/199, where nearest wins by 1 against 32 -- a
        # strict win, never a tie -- so flipping the comparison left all 147 tests green.
        # These five are every `live_steps` value at the default schedule whose outcome
        # the tie rule decides.
        from pymol import designing
        total = 199
        for wanted, finer, coarser in ((18, 19, 17), (24, 25, 23), (27, 29, 25),
                                       (37, 40, 34), (45, 50, 40)):
            interval = designing.capture_interval(wanted, total)
            got = designing.capture_frame_count(interval, total)
            # Precondition: this really is a tie, or the assertion below proves nothing.
            self.assertEqual(abs(finer - wanted), abs(coarser - wanted),
                             'live_steps=%d is not a tie between %d and %d'
                             % (wanted, finer, coarser))
            self.assertEqual(got, finer,
                             'live_steps=%d: a tie must keep the finer recording (%d), '
                             'not the coarser one (%d)' % (wanted, finer, coarser))

    # -- The one cross-language coupling, and the one call site ----------------

    def _swift_source(self, name):
        """Read a shipped Swift file, the way RFD3RuntimeTests already does.

        Greping the source is not elegant, and it is the only tool available: the code
        below lives inside `RFD3JobManager.run`, which needs a 672 MB weight pack and a
        real MLX rollout, so no unit test on either side can execute it.
        """
        import os
        here = os.path.dirname(os.path.abspath(__file__))
        root = os.path.abspath(os.path.join(here, '..', '..', '..'))
        path = os.path.join(root, 'swiftui', 'PyMOLViewer', 'Shared', name)
        self.assertTrue(os.path.exists(path), path)
        with open(path) as handle:
            return handle.read()

    def testTheDerivedIntervalIsActuallyWhatTheRuntimeCapturesAt(self):
        # `captureInterval(for:)` having a test is not the same as it being USED. Its one
        # production reference is inside `run`, so reverting that line to the fallback
        # would leave the function tested-but-unused and both suites green -- the whole
        # feature silently ignoring `live_steps`.
        source = self._swift_source('RFD3JobManager.swift')
        self.assertIn('let interval = Self.captureInterval(for: request)', source,
                      'the rollout must take its cadence from the request, via '
                      'captureInterval(for:)')
        self.assertIn('static func captureInterval(for request: InferenceJob.Request)',
                      source)

    def testAQueuedDesignIsRefusedBeforeItFeaturizesAnything(self):
        # One Cancel stops a whole batch, and a batch is enqueued on a SERIAL queue -- so
        # nine of ten designs are sitting in `run` waiting their turn when the cancel
        # lands. Without a check before the work, each of those still builds its feature
        # set (seconds of CPU on a real target) before noticing at the existing
        # cancellation point after `RFD3Model.preflight`, so a batch cancel drains slowly
        # instead of at once. Pinned by SOURCE, because `run` needs a 672 MB pack.
        source = self._swift_source('RFD3JobManager.swift')
        head = source.split('report("running", "featurize", 0.0)')[0]
        self.assertIn('if isCancelled() {', head,
                      'run() must refuse an already-cancelled job before it does any '
                      'work, or a batch cancel featurizes every queued design first')
        self.assertIn('settle(cancelledStatus(phase: "queued")); return', head)

    def testTheRolloutLengthMatchesTheRuntimes(self):
        # THE cross-language coupling. `rollout_step_count` decides the interval AND the
        # count echoed before the run; the runtime computes the same quantity for
        # `shouldCapture`'s final-step arm. If they disagreed the echo would be a lie
        # about the object the user actually gets.
        from pymol import designing
        source = self._swift_source('RFD3JobManager.swift')
        self.assertIn('total: max(request.diffusionSteps - 1, 1)) else { return }',
                      source,
                      'the runtime computes the rollout length as diffusionSteps - 1; '
                      'designing.rollout_step_count must match it')
        # And the Python end really is that formula, at the schedules that matter.
        for steps in (200, 100, 20, 6, 2):
            self.assertEqual(designing.rollout_step_count(steps), max(steps - 1, 1),
                             'diffusion_steps=%d' % steps)

    def testTheFinalRolloutStepIsAlwaysCaptured(self):
        # At every count, at every schedule: the recording must end where the design does,
        # not up to `interval - 1` steps short of it.
        from pymol import designing
        for total in (199, 99, 60, 19, 5, 1):
            for wanted in (1, 3, 7, 12, 50, total):
                if wanted > total:
                    continue
                interval = designing.capture_interval(wanted, total)
                self.assertIn(total, self._captured(interval, total),
                              'wanted %d of %d -> interval %d' % (wanted, total, interval))

    def testTheDerivationNeverYieldsAnIntervalThatCapturesNothing(self):
        # Python refuses these before a job exists; this is the structural invariant, and
        # the one thing the derivation may not do is make the runtime skip every step.
        from pymol import designing
        for frames in (0, -1, 1000000):
            for total in (199, 1):
                interval = designing.capture_interval(frames, total)
                self.assertGreaterEqual(interval, 1, 'frames %r' % frames)
                self.assertTrue(self._captured(interval, total))
        self.assertGreaterEqual(designing.capture_interval(5, 0), 1)

    def testTheDefaultCadenceIsUnchangedAtTheDefaultSchedule(self):
        # The old fixed interval of 4 over 199 steps gave 50 frames. Whatever the
        # derivation does, asking for 50 must still be interval 4 -- otherwise this is a
        # change to the default rather than a parameter added beside it.
        from pymol import designing
        self.assertEqual(designing.capture_interval(50, 199), 4)
        self.assertEqual(designing.capture_frame_count(4, 199), 50)

    def testTheAchievableCountIsReportedBeforeTheRunStarts(self):
        # The point of deriving on this side. The counts are quantised, so asking for 30
        # and silently getting 34 is a small surprise that costs nothing to remove.
        from pymol import designing
        said = []
        original = designing.colorprinting.parrot
        designing.colorprinting.parrot = lambda text: said.append(text)
        try:
            self._design(live_steps=30, quiet=0)
        finally:
            designing.colorprinting.parrot = original
        live = [t for t in said if 'live view will capture' in t]
        self.assertTrue(live, 'the achievable count must be reported: %r' % said)
        achievable = designing.capture_frame_count(
            designing.capture_interval(30, 199), 199)
        self.assertIn('capture %d model frame' % achievable, live[0])
        self.assertIn('nearest to the 30 requested', live[0],
                      'and must say so when it is not what was asked for')
        # MODEL FRAMES, not states -- and it must say what becomes of them, because with
        # keep_frames off (the default) the states it would otherwise be promising will
        # not exist.
        self.assertIn('animated and discarded', live[0],
                      'the echo must not promise states that will not exist: %s'
                      % live[0])

    def testAnExactlyAchievableCountIsReportedWithoutTheCaveat(self):
        from pymol import designing
        said = []
        original = designing.colorprinting.parrot
        designing.colorprinting.parrot = lambda text: said.append(text)
        try:
            self._design(live_steps=50, quiet=0)
        finally:
            designing.colorprinting.parrot = original
        live = [t for t in said if 'live view will capture' in t]
        self.assertTrue(live)
        self.assertIn('capture 50 model frames', live[0])
        self.assertNotIn('nearest', live[0])
        self.assertIn('every 4 of the 199 rollout steps', live[0])

    # -- Placeholders, weights, cancellation ---------------------------------

    def testThePlaceholderExistsBeforeTheDesignDoes(self):
        from pymol import designing
        # Seventeen minutes is a long time to look at nothing. The placeholder is a real
        # zero-atom object, so the design appears in the object panel immediately.
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data)):
            job = cmd.binder_design('stubgen', 'tgt', 'tgt and resi 5', length=6)
            self.assertIn(job.spec.name, designing.pending_objects())
            self.assertEqual(cmd.count_atoms(job.spec.name), 0)
            settle()
            # Still pending: the fetch has landed and the job is submitted, but nothing has
            # DELIVERED it. That is the real mid-flight state, and it is what the progress
            # tray renders for the whole seventeen minutes.
            self.assertIn(job.spec.name, designing.pending_objects())
        deliver(job)
        self.assertNotIn(job.spec.name, designing.pending_objects())
        self.assertGreater(cmd.count_atoms(job.spec.name), 0)

    def testWeightsAreFetchedLazilyAndOnlyOnce(self):
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data)) as opener:
            cmd.binder_design('stubgen', 'tgt', 'tgt and resi 5', length=6)
            settle()
            self.assertEqual(opener.call_count, 1)
        with patch('pymol.predictors.weights._urlopen',
                   side_effect=AssertionError('must not re-download')):
            cmd.binder_design('stubgen', 'tgt', 'tgt and resi 5', length=6, seed=99)
            settle()

    def testAPendingPlaceholderIsKeptOutOfASavedSession(self):
        from pymol import designing
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data)):
            job = cmd.binder_design('stubgen', 'tgt', 'tgt and resi 5', length=6)
            # Mid-flight: the placeholder exists and is empty, and a .pse carrying it
            # would hold an object that can never fill -- the job is gone on reload.
            session = {'names': [[job.spec.name, 1], ['tgt', 1]]}
            designing.session_save(session)
            self.assertEqual([entry[0] for entry in session['names']], ['tgt'])
            settle()
        # Once it has landed and has atoms it is saved like anything else -- only the
        # BOTH-pending-and-empty case is dropped, so a job that finished between submit and
        # save is never lost.
        deliver(job)
        session = {'names': [[job.spec.name, 1]]}
        designing.session_save(session)
        self.assertEqual([entry[0] for entry in session['names']], [job.spec.name])

    def testCancelReachesTheJobHandle(self):
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data)):
            job = cmd.binder_design('stubgen', 'tgt', 'tgt and resi 5', length=6)
            settle()
        cmd.design_cancel(job.job_id)
        # The handle the command returned is the DEFERRED wrapper -- its job id is its own,
        # not the host's -- so the cancel has to reach the real job it forwards to.
        self.assertTrue((getattr(job, '_real', None) or job).cancelled)

    def testCancelAcceptsThePendingOBJECTNameTheTrayActuallySends(self):
        """The progress tray's Cancel is keyed by OBJECT, not by job id.

        `ProgressItem.design` builds `design_cancel('<object name>')`, because a card's
        id IS the object name. Accepting only a job id made that button raise KeyError in
        front of a user -- and neither side's tests caught it: the Swift test asserted the
        command STRING carried the object name, this suite asserted the job-id path, and
        nothing checked that one accepts what the other sends. `predict_cancel` has taken
        an object name since #291 for exactly this reason.
        """
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data)):
            job = cmd.binder_design('stubgen', 'tgt', 'tgt and resi 5', length=6)
            settle()
        real = getattr(job, '_real', None) or job
        self.assertFalse(real.cancelled)
        # The exact string the tray sends: the object name, not job.job_id.
        cmd.design_cancel(job.spec.name)
        self.assertTrue(real.cancelled,
                        'cancelling by object name must reach the running job')

    def testCancelStillAcceptsAJobId(self):
        # The scripted path, which a user typing at the prompt takes. Both spellings work,
        # and job ids never collide with object names.
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data)):
            job = cmd.binder_design('stubgen', 'tgt', 'tgt and resi 5', length=6)
            settle()
        real = getattr(job, '_real', None) or job
        cmd.design_cancel(job.job_id)
        self.assertTrue(real.cancelled)

    def testCancellingAnUnknownNameStillRaises(self):
        # The object-name path must not swallow a genuine typo into silence.
        self.assertRaises(Exception, cmd.design_cancel, 'no_such_object_or_job')

    def testStatusReportsEveryJobThisSession(self):
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data)):
            job = cmd.binder_design('stubgen', 'tgt', 'tgt and resi 5', length=6)
            settle()
        status = cmd.design_status()
        self.assertIn(job.job_id, status)
        self.assertEqual(status[job.job_id]['state'], 'done')
        self.assertEqual(cmd.design_status(job.job_id)[job.job_id]['state'], 'done')

    def testWeightsSurfaceReportsTheBundleWithoutFetchingIt(self):
        with patch('pymol.predictors.weights._urlopen',
                   side_effect=AssertionError('must not fetch')):
            report = cmd.design_weights('stubgen')
        self.assertEqual(report['stubgen']['bundle'], 'stubgen')
        self.assertFalse(report['stubgen']['cached'])
        self.assertTrue(report['stubgen']['runnable'])

    def testAGeneratorWhoseRuntimeIsAbsentIsReportedButNotFetched(self):
        # A bulk `download=1` must not pull hundreds of megabytes for a method whose Swift
        # half is not in this build. Reported, not fetched.
        self.declareHost('boltz')
        with patch('pymol.predictors.weights._urlopen',
                   side_effect=AssertionError('must not fetch what cannot run')):
            report = cmd.design_weights('stubgen', download=1)
        self.assertFalse(report['stubgen']['runnable'])
        self.assertNotIn('fetching', report['stubgen'])

    def testARefusalCostsNoDownload(self):
        # Every input check runs before the fetch starts, so a bad target never costs a
        # user a 625 MB transfer. That ordering is the point of the test, not the message.
        with patch('pymol.predictors.weights._urlopen',
                   side_effect=AssertionError('must not fetch for a refused design')):
            # An UNEVALUABLE hotspot expression -- `tgt and resi 999` resolves fine
            # these days and simply runs unguided, which is the point of that change.
            self.assertRaises(Exception, cmd.binder_design,
                              'stubgen', 'tgt', 'chian A and resi 5', length=6)
            self.assertRaises(Exception, cmd.binder_design,
                              'stubgen', 'tgt', 'tgt and resi 5', length=0)
            self.assertRaises(Exception, cmd.binder_design,
                              'stubgen', 'nosuchobject', 'tgt and resi 5')

    def testAnUnknownGeneratorIsRefusedByName(self):
        from pymol.predictors.errors import PredictorNotFound
        self.assertRaises(PredictorNotFound, cmd.binder_design,
                          'nosuchgenerator', 'tgt', 'tgt and resi 5')

    def testHeadlessRefusesRatherThanHanging(self):
        # Without a host nothing consumes the marker, so a submitted job would wait
        # forever. Refused by name instead.
        from pymol.predictors.errors import PredictorUnavailable
        os.environ.pop('RAYMOL_PREDICT_HOST', None)
        self.assertRaises(PredictorUnavailable, cmd.binder_design,
                          'stubgen', 'tgt', 'tgt and resi 5')

    def testNDesignsIsBounded(self):
        from pymol.predictors.errors import PredictionOptionError
        self.assertRaises(PredictionOptionError, cmd.binder_design,
                          'stubgen', 'tgt', 'tgt and resi 5', n_designs=0)
        self.assertRaises(PredictionOptionError, cmd.binder_design,
                          'stubgen', 'tgt', 'tgt and resi 5', n_designs=1000)

    # -- quiet=0 is the COMMAND-LINE default ---------------------------------
    #
    # parsing.py:417-420 sets quiet=0 for any command-line invocation whose argspec
    # contains `quiet`, while the Python API defaults to quiet=1. A suite that only
    # exercises quiet=1 never takes a single message-emitting branch -- the first cut of
    # the prediction backend was 48/48 green while every one of those branches raised
    # AttributeError on a colorprinting helper that does not exist.

    def testTheWholeSurfaceIsVerboseWithoutRaising(self):
        import io
        from contextlib import redirect_stdout
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data, chunk=4)):
            with redirect_stdout(io.StringIO()):
                job = cmd.binder_design('stubgen', 'tgt', 'tgt and resi 5+8',
                                          length=6, quiet=0)
                settle()
        with redirect_stdout(io.StringIO()):
            cmd.design_status(quiet=0)
            cmd.design_status(job.job_id, quiet=0)
            cmd.design_weights('stubgen', quiet=0)
            cmd.design_weights(quiet=0)
            deliver(job)
            cmd.design_result(job.job_id, name='byhand', quiet=0)
            cmd.design_cancel(job.job_id, quiet=0)
            cmd.design_weights_cancel('stubgen', quiet=0)
            cmd.design_dismiss(quiet=0)
        self.assertIn('byhand', cmd.get_names('objects'))

    def testRefusalsAreReportedAtBothVerbosities(self):
        import io
        from contextlib import redirect_stdout
        for quiet in (0, 1):
            with redirect_stdout(io.StringIO()):
                self.assertRaises(Exception, cmd.binder_design, 'stubgen', 'tgt',
                                  'chian A', quiet=quiet)

    def testTheBarsFormFeedResolvesATargetTheSameWayTheCommandDoes(self):
        """appkit_design.emit is what the Binder Design bar reads.

        It must resolve through `designing.resolve_target` and the generator's own
        `parse_target`, so the bar reports exactly what a run would design against --
        including a refusal, BEFORE a run that takes minutes. A second resolver here
        would be a second set of rules, and the bar would disagree with the command.
        """
        import json
        import os
        import tempfile
        from pymol import appkit_design
        appkit_design.emit('tgt', 'tgt and resi 5+8+11', 'stubgen')
        path = os.path.join(tempfile.gettempdir(),
                            'pymol_design_%d.json' % os.getpid())
        with open(path) as handle:
            payload = json.load(handle)
        self.assertIsNone(payload['error'])
        self.assertEqual(payload['target']['residues'], 20)
        self.assertEqual(payload['target']['hotspots'], 3)
        self.assertEqual(payload['target']['chain'], 'A')
        self.assertIn({'id': 'stubgen'}, payload['generators'])

    def testTheFormFeedReportsARefusalInsteadOfRaising(self):
        # A bad selection is a message in the bar, not a crash in the poll -- a throw here
        # would also leave a stale or zero-byte payload behind.
        import json
        import os
        import tempfile
        from pymol import appkit_design
        appkit_design.emit('tgt', 'chian A', 'stubgen')
        path = os.path.join(tempfile.gettempdir(),
                            'pymol_design_%d.json' % os.getpid())
        with open(path) as handle:
            payload = json.load(handle)
        self.assertIsNone(payload['target'])
        self.assertTrue(payload['error'])

    def testTheFormFeedOffersNoGeneratorItCannotRun(self):
        # The registry is platform-independent; the runtime is not. Offering a method the
        # host cannot run turns "not in this build" into a menu entry that fails at submit.
        import json
        import os
        import tempfile
        from pymol import appkit_design
        self.declareHost('boltz')          # stubgen needs 'stubruntime'
        appkit_design.emit('tgt', 'tgt and resi 5', '')
        path = os.path.join(tempfile.gettempdir(),
                            'pymol_design_%d.json' % os.getpid())
        with open(path) as handle:
            payload = json.load(handle)
        self.assertNotIn({'id': 'stubgen'}, payload['generators'])

    def testEveryMessageHelperUsedByDesigningExists(self):
        """Guards the whole class of bug: a message helper that is not there.

        colorprinting exposes error/warning/suggest/parrot -- there is no info(). Every
        name designing.py reaches for must resolve, or a branch no test happens to take
        crashes in front of a user. The prediction suite has the same guard for the same
        reason, and it is there because that bug actually shipped.
        """
        import re
        from pymol import colorprinting, designing
        with open(designing.__file__) as handle:
            used = set(re.findall(r'colorprinting\.(\w+)', handle.read()))
        self.assertTrue(used, 'expected designing.py to emit messages')
        for helper in sorted(used):
            self.assertTrue(hasattr(colorprinting, helper),
                            'colorprinting has no %r' % helper)

    # -- Object names PyMOL rewrites -----------------------------------------
    #
    # Creating an object LEGALISES its name: an apostrophe, a space and a forward slash
    # all become underscores. Nothing tells the caller, so a name chosen here and the
    # object that actually exists can be two different strings -- and every table keyed on
    # the chosen one then addresses an object that is not there.

    def testAPlaceholderIsKeyedUnderTheNameTheObjectActuallyHas(self):
        from pymol import designing
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data)):
            job = cmd.binder_design('stubgen', 'tgt', 'tgt and resi 5',
                                      length=6, name='my design')
            # The invariant everything else here depends on: the pending key IS the
            # object. session_save looks the placeholder up by the object's real name,
            # and discard deletes by it.
            self.assertIn(job.spec.name, cmd.get_names('objects'))
            self.assertIn(job.spec.name, designing.pending_objects())
            settle()

    def testAPendingPlaceholderWithARewrittenNameIsKeptOutOfASavedSession(self):
        # session_save drops an object only if it is BOTH pending and empty, and it tests
        # membership with the name the SESSION carries -- which is the object's real one.
        # Keyed under anything else, a zero-atom placeholder that can never fill is
        # written into the .pse.
        from pymol import designing
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data)):
            job = cmd.binder_design('stubgen', 'tgt', 'tgt and resi 5',
                                      length=6, name='my design')
            real = cmd.get_legal_name('my design')
            self.assertEqual(job.spec.name, real)
            session = {'names': [[real, 1], ['tgt', 1]]}
            designing.session_save(session)
            self.assertEqual([entry[0] for entry in session['names']], ['tgt'])
            settle()

    def testDismissingARewrittenNameActuallyRemovesThePlaceholder(self):
        # The leak: discard_pending deletes the object only if it can find it. Keyed under
        # the raw name it finds nothing, drops the record, and leaves a zero-atom object
        # in the session with no job behind it and no card to dismiss it from.
        from pymol import designing
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data)):
            cmd.binder_design('stubgen', 'tgt', 'tgt and resi 5',
                                length=6, name='my design')
            settle()
        real = cmd.get_legal_name('my design')
        self.assertIn(real, cmd.get_names('objects'))
        self.assertEqual(cmd.count_atoms(real), 0, 'must still be an empty placeholder')
        designing.discard_pending(real)
        self.assertNotIn(real, cmd.get_names('objects'))
        # The WHOLE table, not just this key: keyed under the raw name the record is
        # orphaned rather than removed, and `assertNotIn(real, ...)` would pass while a
        # dead entry kept the object listed as pending for the rest of the session.
        self.assertEqual(designing.pending_objects(), {})

    def testDismissingByTheNameTheUserTypedAlsoWorks(self):
        # design_dismiss is user-facing: the name typed at the prompt is the raw one, not
        # the rewritten one the object ended up with.
        from pymol import designing
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data)):
            cmd.binder_design('stubgen', 'tgt', 'tgt and resi 5',
                                length=6, name='my design')
            settle()
        cmd.design_dismiss('my design')
        self.assertNotIn(cmd.get_legal_name('my design'), cmd.get_names('objects'))
        self.assertEqual(designing.pending_objects(), {})

    def testAResultStillLandsInTheRewrittenPlaceholder(self):
        # Delivery must fill the SAME object the placeholder created rather than making a
        # second one, and must retire the pending mark that session_save keys off.
        from pymol import designing
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data)):
            job = cmd.binder_design('stubgen', 'tgt', 'tgt and resi 5',
                                      length=6, name='my design')
            settle()
        before = len(cmd.get_names('objects'))
        deliver(job)
        real = cmd.get_legal_name('my design')
        self.assertEqual(len(cmd.get_names('objects')), before, 'delivery made a 2nd object')
        self.assertGreater(cmd.count_atoms(real), 0)
        # Same reason as above: a record left under the raw name would keep this finished
        # design pending forever, and session_save strips a pending object from the .pse.
        self.assertEqual(designing.pending_objects(), {})


class RunEstimateTest(GeneratorTestCase):
    """The whole-run countdown: `run_remaining` on the wire, and what it is made of.

    A separate class because it needs a design that is RUNNING, which the ordinary
    `StubDesignJob` never is -- it reports `done` on its first status read.

    Time is BACKDATED rather than slept through, the technique `predict_progress` uses:
    `_TRACK[name]['run_started']` and `['phase_started']` are the clocks under test, so
    moving them IS moving time, and a sleeping suite is a suite nobody runs.
    """

    def setUp(self):
        GeneratorTestCase.setUp(self)
        import tempfile
        from generate_harness import ProgressDesignJob
        from pymol import designing
        self.designing = designing
        self.data, self.digest = make_zip()
        self.root = tempfile.mkdtemp()
        os.environ['RAYMOL_WEIGHTS_DIR'] = self.root
        install_stub(self.digest, len(self.data), job_class=ProgressDesignJob)
        self.declareHost('stubruntime')
        self.helix()

    # -- Driving -------------------------------------------------------------

    def submit(self, count=3, **kwargs):
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data)):
            jobs = cmd.binder_design('stubgen', 'tgt', 'tgt and resi 5', length=6,
                                       n_designs=count, **kwargs)
            settle()
        return jobs if isinstance(jobs, (list, tuple)) else [jobs]

    @staticmethod
    def real(job):
        return getattr(job, '_real', None) or job

    def poll(self, jobs):
        """One panel tick: every member's record, in submission order.

        Through `pending_info` for every name, which is what `appkit_inspector`
        `_pending_maps` does -- so a value that is only right for the member polled
        first cannot pass. `None` for a member that has already been delivered, which
        is exactly what the wire shows.
        """
        return [self.designing.pending_info(job.spec.name) for job in jobs]

    def live(self, jobs):
        """The records still on the wire, in submission order."""
        return [info for info in self.poll(jobs) if info is not None]

    def raw(self, jobs):
        """One poll with the moving average taken out of the way.

        Every test that asserts the estimator's ARITHMETIC drops the remembered value
        first, so the poll publishes the raw projection exactly. Deliberately NOT
        "poll until the average catches up": that answer depends on how long the polls
        took -- the average winds its previous value forward by real wall time -- so on
        a loaded machine it drifts, and a test that drifts is a test that will one day
        fail for no reason. The smoothing has tests of its own.
        """
        for store in (list(self.designing._BATCH.values())
                      + list(self.designing._TRACK.values())):
            store.pop('eta', None)
            store.pop('eta_at', None)
        return self.live(jobs)

    def age(self, job, seconds):
        """Backdate this design's own clocks by `seconds`."""
        track = self.designing._TRACK[job.spec.name]
        for key in ('run_started', 'phase_started', 'started'):
            if track.get(key) is not None:
                track[key] -= seconds

    def batch(self):
        return self.designing._BATCH[list(self.designing._BATCH)[0]]

    def running(self, jobs, index, fraction, elapsed, **kwargs):
        """Put design `index` (1-based) at `fraction` of diffusion, `elapsed` s in."""
        job = jobs[index - 1]
        self.real(job).run(fraction, **kwargs)
        self.poll(jobs)                     # latch run_started / phase_started
        self.age(job, elapsed)
        return self.live(jobs)

    # -- What it is ----------------------------------------------------------

    def testTheEstimateCoversTheDesignsThatHaveNotStartedYet(self):
        # The whole point: a batch row is asked "how long for the run", not "how long
        # for the design that happens to be in flight".
        jobs = self.submit(3)
        infos = self.running(jobs, 1, 0.5, 60.0)
        # The design in flight: 60 s for half of diffusion -> 60 s left. Nothing has
        # finished, so the queued two are charged its projected total, 120 s each.
        self.assertAlmostEqual(infos[0]['run_remaining'], 60.0 + 2 * 120.0, delta=2.0)
        # ...and that is FIVE times what the design's own phase countdown says, which is
        # the number this row used to show.
        self.assertAlmostEqual(infos[0]['remaining'], 60.0, delta=2.0)

    def testALoneDesignGetsAnEstimateOfItsOwn(self):
        # A batch of one is still a run, and it must not be charged for siblings it
        # does not have.
        jobs = self.submit(1)
        infos = self.running(jobs, 1, 0.5, 60.0)
        self.assertIsNone(infos[0]['batch'], 'pre-condition: no batch')
        self.assertAlmostEqual(infos[0]['run_remaining'], 60.0, delta=2.0)

    def testAMeasuredDesignPricesTheOnesStillQueued(self):
        # The rule the brief asked for: once a design has really finished you have a
        # wall clock that includes everything a design costs -- featurization, the pack
        # read, the write -- and no projection off a progress bar can see all of that.
        jobs = self.submit(3)
        self.running(jobs, 1, 0.5, 100.0)
        self.real(jobs[0]).finish()
        deliver(jobs[0])
        banked = self.batch()['durations']
        self.assertEqual(len(banked), 1)
        self.assertAlmostEqual(banked[0], 100.0, delta=2.0)
        # Design 2 is 10 s into a rollout of its own; design 3 has not started.
        self.running(jobs, 2, 0.1, 10.0)
        # 90 s left of design 2 (its own rate), + ONE queued design at the measured 100.
        self.assertAlmostEqual(self.raw(jobs)[0]['run_remaining'],
                               90.0 + 100.0, delta=4.0)

    def testTheMeasuredTimeBeatsAProjectionThatCannotSeeTheTail(self):
        # A design's phase countdown covers the phase, and the phase is not the design:
        # `write`, and PyMOL's own load of the result, come after it. The larger of the
        # two views is the one that has not forgotten something.
        jobs = self.submit(2)
        self.running(jobs, 1, 0.5, 100.0)
        self.real(jobs[0]).finish()
        deliver(jobs[0])
        # Design 2 says it is 90% done after 30 s -- i.e. 3 s left -- while a real
        # design of this batch took 100 s. The estimate refuses to promise 3 s.
        self.running(jobs, 2, 0.9, 30.0)
        info = self.raw(jobs)[0]
        self.assertAlmostEqual(info['remaining'], 30.0 / 0.9 - 30.0, delta=1.0)
        self.assertAlmostEqual(info['run_remaining'], 100.0 - 30.0, delta=3.0)

    def testAFailedDesignIsNotStillCountedAsWorkToDo(self):
        # A failure SHORTENS the run. Counted through the frontier -- the same rule the
        # tray uses to say "design k of N" -- rather than through a second notion of
        # what is left.
        jobs = self.submit(3)
        self.running(jobs, 1, 0.5, 100.0)
        self.real(jobs[0]).fail()
        self.poll(jobs)
        self.running(jobs, 2, 0.5, 60.0)
        # design 1 failed, 2 is running with 60 s left, 3 is queued at 120 s. Design 1
        # is NOT charged again -- three designs would have been 60 + 240.
        self.assertAlmostEqual(self.raw(jobs)[1]['run_remaining'],
                               60.0 + 120.0, delta=3.0)

    def testAFailedDesignContributesNoDurationToThePrice(self):
        # It settles at any point at all -- instantly, or after seventeen minutes -- so
        # its wall time says nothing about what a design costs.
        jobs = self.submit(3)
        self.running(jobs, 1, 0.5, 100.0)
        self.real(jobs[0]).fail()
        self.poll(jobs)
        cmd.design_dismiss(jobs[0].spec.name)
        self.assertEqual(self.batch().get('durations', []), [])

    def testACancelledDesignContributesNoDurationEither(self):
        jobs = self.submit(3)
        self.running(jobs, 1, 0.5, 100.0)
        cmd.design_cancel(list(self.designing._BATCH)[0])
        for job in jobs:
            self.designing.discard_pending(job.spec.name)
        self.assertEqual([b.get('durations', []) for b in self.designing._BATCH.values()],
                         [] if not self.designing._BATCH else [[]])

    # -- When it refuses to speak --------------------------------------------

    def testNothingIsProjectedFromADesignThatHasBarelyStarted(self):
        # `remaining` divides by a fraction, and on a batch row the answer is then
        # multiplied by the designs still queued. A confidently wrong countdown is
        # worse than no countdown.
        jobs = self.submit(3)
        infos = self.running(jobs, 1, 0.5, 3.0)
        self.assertIsNone(infos[0]['run_remaining'])
        # ...and it appears once there is signal, from the same design.
        infos = self.running(jobs, 1, 0.5, 40.0)
        self.assertIsNotNone(infos[0]['run_remaining'])

    def testNothingIsProjectedWhileNoDesignIsRunning(self):
        # Nothing is running -- waiting on a weight fetch, or in the gap between two
        # designs -- so there is no rate to extrapolate and no measured duration to fall
        # back on.
        #
        # Driven through the QUEUED state itself rather than through the fetch. The
        # fetch is a real background thread, and "the bundle is still downloading" is a
        # pre-condition that races it: under load it had ALREADY finished by the time
        # this looked, and the test failed on its own setup rather than on the product.
        jobs = self.submit(3)
        infos = self.poll(jobs)
        self.assertEqual([info['state'] for info in infos], ['queued'] * 3,
                         'pre-condition: nothing has started')
        self.assertEqual([info['run_remaining'] for info in infos], [None] * 3)
        # And ageing them conjures nothing: `elapsed` is the clock since the COMMAND was
        # typed, which every member shares, so it is not evidence about any design.
        for job in jobs:
            self.age(job, 600.0)
        infos = self.poll(jobs)
        self.assertGreater(infos[0]['elapsed'], 500.0, 'pre-condition: an old batch')
        self.assertEqual([info['run_remaining'] for info in infos], [None] * 3)

    def testAQueuedDesignIsNotMistakenForARunningOne(self):
        # `elapsed` reads the SAME on the design that is running and on the nine sitting
        # behind it -- every member is registered in the same instant -- so a rate taken
        # from it would be the batch's, not the design's. `run_started` is latched off
        # the runtime's own 'running' state instead.
        jobs = self.submit(3)
        self.poll(jobs)
        for job in jobs[1:]:
            self.assertIsNone(self.designing._TRACK[job.spec.name].get('run_started'),
                              '%s never ran' % job.spec.name)
        self.real(jobs[0]).run(0.5)
        self.poll(jobs)
        self.assertIsNotNone(self.designing._TRACK[jobs[0].spec.name]['run_started'])

    def testTheDominantPhaseIsReadOffTheGeneratorsOwnBands(self):
        # The phase countdown is trusted as the DESIGN's countdown only where the
        # generator says that phase owns the bar. A generator with four even bands is
        # making no such claim and gets the composed-fraction fallback instead.
        from generate_harness import ProgressDesignJob
        install_stub(self.digest, len(self.data), job_class=ProgressDesignJob,
                     phases=(('a', 0.0, 0.25), ('b', 0.25, 0.5),
                             ('c', 0.5, 0.75), ('d', 0.75, 1.0)))
        jobs = self.submit(1)
        self.real(jobs[0]).run(0.5, phase='c')
        self.poll(jobs)
        self.assertEqual(self.designing._TRACK[jobs[0].spec.name]['dominant_phase'], '')
        self.age(jobs[0], 60.0)
        info = self.poll(jobs)[0]
        # Composed fraction is 0.5 + 0.5 * 0.25 = 0.625, so 60 s buys 36 s more -- NOT
        # the 60 s the phase countdown alone would have said.
        self.assertAlmostEqual(info['fraction'], 0.625, places=3)
        self.assertAlmostEqual(info['run_remaining'], 60.0 / 0.625 - 60.0, delta=2.0)

    # -- Behaviour over a run -------------------------------------------------

    def testEveryMemberOfABatchPublishesTheSameEstimateOnce(self):
        # Whichever record the tray picks as `current` must carry the same number -- and
        # the moving average must advance once per TICK, not once per member, or a
        # ten-design batch would smooth ten times as fast as a three-design one.
        jobs = self.submit(3)
        infos = self.running(jobs, 1, 0.5, 60.0)
        self.assertEqual(len(infos), 3, 'pre-condition: three members on the wire')
        values = [info['run_remaining'] for info in infos]
        self.assertEqual(len(set(values)), 1, values)
        # One advance for the whole poll, from the frontier alone: the other two read
        # the stored value back. Proved by BLINDING the frontier -- with design 1 out
        # of the picture the value cannot be recomputed at all, and the members that
        # are left still answer.
        stored = self.batch()['published']
        self.designing._TRACK[jobs[0].spec.name].pop('run_started')
        again = [self.designing.pending_info(job.spec.name) for job in jobs[1:]]
        self.assertEqual([info['run_remaining'] for info in again], [stored, stored])

    def testWhenTheFRONTIERHasNothingToSayNeitherDoesTheRestOfTheBatch(self):
        # The whole batch is one row and one number, so the members must not disagree
        # about whether there IS one. The moving average deliberately keeps its state
        # across the gap between two designs -- that gap is real time it should
        # consume -- so what is PUBLISHED has to be tracked separately from what is
        # remembered, or the queued members would go on showing a countdown the row
        # itself had stopped showing.
        jobs = self.submit(3)
        self.running(jobs, 1, 0.5, 60.0)
        self.assertIsNotNone(self.poll(jobs)[0]['run_remaining'],
                             'pre-condition: an estimate exists')
        # Design 1 finishes; design 2 has not been picked up by the queue yet.
        self.real(jobs[0]).finish()
        deliver(jobs[0])
        infos = self.live(jobs)
        self.assertEqual([info['run_remaining'] for info in infos], [None, None])
        self.assertIsNotNone(self.batch().get('eta'),
                             'the average remembers, even while nothing is shown')

    def testAConstantEstimateStillCountsDownAsTimePasses(self):
        # THE reason the moving average winds the previous value forward before it
        # blends. A plain EMA over a countdown drags the old number along, so a design
        # ticking along at a steady rate would show an estimate that barely moved. Here
        # the raw projection is held EXACTLY constant and only the clock advances.
        jobs = self.submit(1)
        self.running(jobs, 1, 0.5, 100.0)
        raw = self.raw(jobs)[0]['run_remaining']
        self.assertAlmostEqual(raw, 100.0, delta=3.0)
        import time
        store = self.designing._TRACK[jobs[0].spec.name]
        store['eta_at'] -= 10.0             # ten seconds of wall clock, no new evidence
        mark = time.monotonic()
        after = self.poll(jobs)[0]['run_remaining']
        # A plain EMA would answer `raw` (both terms equal); the wind-forward answers
        # 0.2*raw + 0.8*(raw - 10) = raw - 8. The poll's OWN duration is part of the
        # wall clock the wind-forward consumes, so it is measured rather than absorbed
        # into a tolerance -- a test whose margin is really "how fast is this machine
        # today" is a test that eventually fails for no reason.
        gap = time.monotonic() - mark
        self.assertAlmostEqual(after, raw - 8.0 - 0.8 * gap, delta=0.5)
        self.assertLess(after, raw - 5.0, 'the estimate did not count down at all')

    def testTheEstimateIsSmoothedRatherThanFollowingEveryJump(self):
        # The raw projection steps whenever the fraction does, and it steps hardest at
        # the moment one design ends and the next starts from zero. Damped, so the row
        # does not swing on a tick.
        jobs = self.submit(1)
        self.running(jobs, 1, 0.5, 100.0)
        settled = self.raw(jobs)[0]['run_remaining']
        self.assertAlmostEqual(settled, 100.0, delta=3.0)
        # The design suddenly reports itself 90% done: raw collapses to ~11 s.
        self.real(jobs[0]).run(0.9)
        jumped = self.poll(jobs)[0]['run_remaining']
        raw = 100.0 * (0.1 / 0.9)
        self.assertAlmostEqual(raw, 11.1, delta=0.5, msg='pre-condition: the raw moved')
        self.assertLess(jumped, settled, 'it must move towards the new evidence')
        self.assertGreater(jumped, settled * 0.5,
                           'one sample must not carry the estimate to the raw value')
        # ...and it gets there in the end rather than sticking. Stated as a
        # COMPARISON rather than a tolerance, because how far it gets in 40 polls
        # depends on how long those polls took on the machine of the day.
        for _ in range(40):
            settling = self.live(jobs)[0]['run_remaining']
        self.assertLess(abs(settling - raw), abs(settling - settled),
                        'it stuck near the old value instead of following the new')

    def testTheEstimateSurvivesThePayloadAsAScalar(self):
        # A non-scalar would fail the WHOLE PanelPayload decode in Swift and take the
        # object list down with it.
        import json
        from pymol import appkit_inspector
        jobs = self.submit(3)
        infos = self.running(jobs, 1, 0.5, 60.0)
        _, records = appkit_inspector._pending_maps('designing')
        record = records[jobs[0].spec.name]
        self.assertIsInstance(record['run_remaining'], float)
        self.assertEqual(json.loads(json.dumps(record))['run_remaining'],
                         record['run_remaining'])
        self.assertAlmostEqual(record['run_remaining'], infos[0]['run_remaining'],
                               delta=1.0)

    def testARecordAlwaysCARRIESTheKeyEvenWhenTheJobExplodes(self):
        # The key is seeded in the record's initial dict, not only assigned on the happy
        # path: `pending_info` wraps everything after that in one `except: pass`, so a
        # generator whose `status()` raises would otherwise publish a record with the key
        # MISSING -- and a missing key is a different shape on a wire a strongly-typed
        # decoder reads.
        jobs = self.submit(1)

        def explode():
            raise RuntimeError('boom')

        self.real(jobs[0]).status = explode
        info = self.designing.pending_info(jobs[0].spec.name)
        self.assertIn('run_remaining', info)
        self.assertIsNone(info['run_remaining'])

    def testAPredictionsRecordCarriesNoWholeRunEstimateAtAll(self):
        # The tray is SHARED, and one decoder serves both records. A prediction must
        # render exactly as it does today, which it does because `predicting` publishes
        # no such key -- so `PredictionJobState.runRemaining` decodes nil and the
        # prediction branch never reaches the new wording.
        #
        # Driven through `predicting`'s own register_pending rather than asserted about
        # its source, because "the key is absent" is a fact about the RECORD.
        from pymol import predicting

        class Bare(object):
            job_id = 'bare-1'

            def status(self):
                return {'state': 'running', 'phase': 'diffusion', 'fraction': 0.5,
                        'error': None, 'result_path': None}

        job = Bare()
        predicting._JOBS[job.job_id] = job
        try:
            predicting.register_pending('pred_probe', job.job_id, _self=cmd)
            prediction = predicting.pending_info('pred_probe', _self=cmd)
            self.assertEqual(prediction['state'], 'running',
                             'pre-condition: a real pending prediction record')
            self.assertNotIn('run_remaining', prediction)
        finally:
            predicting.discard_pending('pred_probe', _self=cmd)
            predicting._JOBS.pop(job.job_id, None)
        # ...while a design's does carry it.
        design = self.designing.pending_info(self.submit(1)[0].spec.name)
        self.assertIn('run_remaining', design)
