"""End-to-end flow through cmd.design_backbone with a stub generator. No Swift, no network.

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


class DesignBackboneTest(GeneratorTestCase):

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
            job = cmd.design_backbone('stubgen', 'tgt', 'tgt and resi 5+8+11', length=12)
            settle()
        deliver(job)
        name = job.spec.name
        self.assertIn(name, cmd.get_names('objects'))
        # The PAIR, not the design alone. Splitting them here would make the refold step
        # re-derive the complex, which is the thing this data model exists to avoid.
        self.assertEqual(sorted(cmd.get_chains(name)), ['A', 'B'])
        self.assertEqual(cmd.count_atoms('%s and chain B and name CA' % name), 12)
        self.assertEqual(cmd.count_atoms('%s and chain A and name CA' % name), 20)

    def testTheTargetIsUnmovedInTheEmittedObject(self):
        # The contract is that the target is held fixed, so the emitted copy must sit on
        # the source atom for atom. Asserted as a real distance rather than a chain count.
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data)):
            job = cmd.design_backbone('stubgen', 'tgt', 'tgt and resi 5', length=6)
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
            job = cmd.design_backbone('stubgen', 'tgt', 'tgt and resi 5', length=6, seed=3)
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
            jobs = cmd.design_backbone('stubgen', 'tgt', 'tgt and resi 5', length=6,
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
            first = cmd.design_backbone('stubgen', 'tgt', 'tgt and resi 5', length=6,
                                        seed=42)
            settle()
        with patch('pymol.predictors.weights._urlopen',
                   side_effect=AssertionError('must not re-download')):
            second = cmd.design_backbone('stubgen', 'tgt', 'tgt and resi 5', length=6,
                                         seed=42)
            settle()
        self.assertEqual(first.spec.name, second.spec.name)

    def testAnExplicitNameIsHonouredAndIndexedForSeveral(self):
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data)):
            job = cmd.design_backbone('stubgen', 'tgt', 'tgt and resi 5', length=6,
                                      name='mine')
            settle()
        self.assertEqual(job.spec.name, 'mine')
        with patch('pymol.predictors.weights._urlopen',
                   side_effect=AssertionError('must not re-download')):
            jobs = cmd.design_backbone('stubgen', 'tgt', 'tgt and resi 5', length=6,
                                       name='several', n_designs=2)
            settle()
        self.assertEqual([job.spec.name for job in jobs], ['several_01', 'several_02'])

    # -- Live view -----------------------------------------------------------

    def testLiveViewRidesFromTheCommandOntoEveryDesignsSpec(self):
        # NOTHING else in the suite joins the command parameter to the spec field: with
        # the one line in design_backbone that carries it deleted, 82 of 82 tests still
        # passed. This is also the only place the Python KWARG NAME is pinned -- it is
        # what a user types, and renaming it broke nothing.
        #
        # n_designs=2 on purpose: the per-design spec is rebuilt field by field, so a new
        # field that is not carried explicitly silently defaults to off for every design.
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data)):
            jobs = cmd.design_backbone('stubgen', 'tgt', 'tgt and resi 5', length=6,
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
            job = cmd.design_backbone('stubgen', 'tgt', 'tgt and resi 5', length=6)
            settle()
        self.assertIs(job.spec.live_view, False)

    # -- live_steps: how many states the recording ends up with ---------------

    def _design(self, **kwargs):
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data)):
            job = cmd.design_backbone('stubgen', 'tgt', 'tgt and resi 5', length=6,
                                      **kwargs)
            settle()
        return job

    def testAskingForAStateCountTurnsTheLiveViewOnByItself(self):
        # Passing live_steps is an explicit opt-in -- having to pass live_view=1 as well
        # would be asking the user to say the same thing twice.
        job = self._design(live_steps=12)
        self.assertIs(job.spec.live_view, True)
        self.assertEqual(job.spec.live_steps, 12)

    def testAnExplicitLiveViewOffBeatsAStateCountAndSaysSo(self):
        # "Off" has to mean off. The count is dropped with it, so nothing downstream sees
        # a recording length for a run that is not being recorded -- and the user is TOLD,
        # because they asked for two things and only got one of them. Asserting the
        # warning is what makes this test able to fail: without it, `live_view=0` already
        # forces both fields to their off values and the branch is invisible.
        from pymol import designing
        said = []
        original = designing.colorprinting.warning
        designing.colorprinting.warning = lambda text: said.append(text)
        try:
            job = self._design(live_view=0, live_steps=12)
        finally:
            designing.colorprinting.warning = original
        self.assertIs(job.spec.live_view, False)
        self.assertIsNone(job.spec.live_steps)
        ignored = [t for t in said if 'live_steps' in t and 'ignored' in t]
        self.assertTrue(ignored, 'the ignored parameter must be reported: %r' % said)
        self.assertIn('live_view=0', ignored[0])

    def testLiveViewOnWithoutACountUsesTheRuntimeDefault(self):
        job = self._design(live_view=1)
        self.assertIs(job.spec.live_view, True)
        self.assertIsNone(job.spec.live_steps,
                          'absent must mean "the runtime default", not a number chosen '
                          'on this side')

    def testEveryDesignOfARunCarriesTheStateCount(self):
        # DesignSpec is a __slots__ class rebuilt field by field per design, so anything
        # not carried explicitly silently reverts for every design after the first.
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data)):
            jobs = cmd.design_backbone('stubgen', 'tgt', 'tgt and resi 5', length=6,
                                       n_designs=2, live_steps=9)
            settle()
        self.assertEqual(len(jobs), 2)
        for job in jobs:
            self.assertEqual(job.spec.live_steps, 9, job.spec.name)
            self.assertIs(job.spec.live_view, True, job.spec.name)

    def testAStateCountOutsideWhatTheRolloutCanSupplyIsRefused(self):
        # Refused, not clamped, and before anything is allocated -- this is input
        # validation, not a runtime degrade.
        from pymol.predictors.errors import PredictionOptionError
        for bad in (0, -3, 200, 10000):
            with self.assertRaises(PredictionOptionError) as caught:
                cmd.design_backbone('stubgen', 'tgt', 'tgt and resi 5', length=6,
                                    diffusion_steps=200, live_steps=bad)
            message = str(caught.exception)
            self.assertIn('live_steps must be between 1 and 199', message)
            self.assertIn('diffusion_steps=200', message,
                          'the message must name the schedule the bound came from')

    def testTheBoundFollowsDiffusionSteps(self):
        # The ceiling is the rollout's own step count, so it moves with the schedule.
        from pymol.predictors.errors import PredictionOptionError
        job = self._design(diffusion_steps=20, live_steps=19)
        self.assertEqual(job.spec.live_steps, 19)
        with self.assertRaises(PredictionOptionError) as caught:
            cmd.design_backbone('stubgen', 'tgt', 'tgt and resi 5', length=6,
                                diffusion_steps=20, live_steps=20)
        self.assertIn('between 1 and 19', str(caught.exception))

    def testAMalformedStateCountIsRefusedWithTheSameGuidance(self):
        from pymol.predictors.errors import PredictionOptionError
        with self.assertRaises(PredictionOptionError) as caught:
            cmd.design_backbone('stubgen', 'tgt', 'tgt and resi 5', length=6,
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
            spec.live_steps = None
            generator.submit(spec, options, '/tmp')
            self.assertIn('live_view', sent)
            self.assertNotIn('live_steps', sent,
                             'an unasked-for count must not be pinned on the wire')

            spec.live_steps = 12
            generator.submit(spec, options, '/tmp')
            self.assertEqual(sent.get('live_steps'), 12)

    # -- Placeholders, weights, cancellation ---------------------------------

    def testThePlaceholderExistsBeforeTheDesignDoes(self):
        from pymol import designing
        # Seventeen minutes is a long time to look at nothing. The placeholder is a real
        # zero-atom object, so the design appears in the object panel immediately.
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data)):
            job = cmd.design_backbone('stubgen', 'tgt', 'tgt and resi 5', length=6)
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
            cmd.design_backbone('stubgen', 'tgt', 'tgt and resi 5', length=6)
            settle()
            self.assertEqual(opener.call_count, 1)
        with patch('pymol.predictors.weights._urlopen',
                   side_effect=AssertionError('must not re-download')):
            cmd.design_backbone('stubgen', 'tgt', 'tgt and resi 5', length=6, seed=99)
            settle()

    def testAPendingPlaceholderIsKeptOutOfASavedSession(self):
        from pymol import designing
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data)):
            job = cmd.design_backbone('stubgen', 'tgt', 'tgt and resi 5', length=6)
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
            job = cmd.design_backbone('stubgen', 'tgt', 'tgt and resi 5', length=6)
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
            job = cmd.design_backbone('stubgen', 'tgt', 'tgt and resi 5', length=6)
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
            job = cmd.design_backbone('stubgen', 'tgt', 'tgt and resi 5', length=6)
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
            job = cmd.design_backbone('stubgen', 'tgt', 'tgt and resi 5', length=6)
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
            self.assertRaises(Exception, cmd.design_backbone,
                              'stubgen', 'tgt', 'tgt and resi 999', length=6)
            self.assertRaises(Exception, cmd.design_backbone,
                              'stubgen', 'tgt', 'tgt and resi 5', length=0)
            self.assertRaises(Exception, cmd.design_backbone,
                              'stubgen', 'nosuchobject', 'tgt and resi 5')

    def testAnUnknownGeneratorIsRefusedByName(self):
        from pymol.predictors.errors import PredictorNotFound
        self.assertRaises(PredictorNotFound, cmd.design_backbone,
                          'nosuchgenerator', 'tgt', 'tgt and resi 5')

    def testHeadlessRefusesRatherThanHanging(self):
        # Without a host nothing consumes the marker, so a submitted job would wait
        # forever. Refused by name instead.
        from pymol.predictors.errors import PredictorUnavailable
        os.environ.pop('RAYMOL_PREDICT_HOST', None)
        self.assertRaises(PredictorUnavailable, cmd.design_backbone,
                          'stubgen', 'tgt', 'tgt and resi 5')

    def testNDesignsIsBounded(self):
        from pymol.predictors.errors import PredictionOptionError
        self.assertRaises(PredictionOptionError, cmd.design_backbone,
                          'stubgen', 'tgt', 'tgt and resi 5', n_designs=0)
        self.assertRaises(PredictionOptionError, cmd.design_backbone,
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
                job = cmd.design_backbone('stubgen', 'tgt', 'tgt and resi 5+8',
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
                self.assertRaises(Exception, cmd.design_backbone, 'stubgen', 'tgt', '',
                                  quiet=quiet)

    def testTheBarsFormFeedResolvesATargetTheSameWayTheCommandDoes(self):
        """appkit_design.emit is what the Design Backbone bar reads.

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
        appkit_design.emit('tgt', 'tgt and resi 999', 'stubgen')
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
            job = cmd.design_backbone('stubgen', 'tgt', 'tgt and resi 5',
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
            job = cmd.design_backbone('stubgen', 'tgt', 'tgt and resi 5',
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
            cmd.design_backbone('stubgen', 'tgt', 'tgt and resi 5',
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
            cmd.design_backbone('stubgen', 'tgt', 'tgt and resi 5',
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
            job = cmd.design_backbone('stubgen', 'tgt', 'tgt and resi 5',
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
