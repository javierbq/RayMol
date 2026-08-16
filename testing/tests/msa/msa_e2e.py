"""The three MSA PRs meeting each other: search (#298) -> store (#296) -> fold (#297).

Each PR has its own suite and each passes on its own. What none of them covers is the
SEAM: msa_search's output is only ever asserted as a store entry, predict's alignments
only ever arrive from load_msa, and the .pse round trip is never asked whether what it
restored can still be folded. This file drives the chain the way a user does, and every
test here fails if any one of the three ends is changed in isolation.

Only two things are stubbed, both at the same seams the per-PR suites use:
`pymol.msas.colabfold._urlopen`, so no sequence leaves this machine, and the predictor,
so no weights are downloaded. The store, the session tasks, the panel poll, the request
JSON and the a3m files on disk are all real.

    pymol -ckqy testing/testing.py --run testing/tests/msa/msa_e2e.py
"""
import io
import json
import os
import tarfile

from contextlib import redirect_stdout
from unittest.mock import patch

from pymol import cmd, predicting, testing
from pymol import msa as msa_module
from pymol.msas import colabfold, searching, store
from pymol.predictors import host, registry
from pymol.predictors.base import (MAX_MSA_DEPTH, PredictionOptions, PredictionSpec,
                                   Predictor, parse_chains)
from pymol.predictors.errors import PredictionInputError

#: 24 residues, the query testing/data/msa_toy.a3m uses, so `fab` builds a target that
#: genuinely matches what the fake server returns for it.
QUERY = 'MKTAYIAKQRQISFVKSHFSRQLE'

#: A second chain, long enough for msa_search's 10-residue floor and different from
#: QUERY, so a dimer's two slots cannot be confused for each other.
QUERY_B = 'GSHMASNEELYQRVKAL'

PRIVATE = 'https://msa.internal.example'


def a3m_for(query, tag):
    """A two-database result for `query`: the merged depth is 3, columns len(query)."""
    mutate = lambda ch: {'A': 'S', 'S': 'A'}.get(ch, ch)
    uniref = ('>101\n%s\n>UniRef100_%s_1\n%s\n'
              % (query, tag, ''.join(mutate(c) for c in query)))
    env = ('>101\n%s\n>ENV_%s_1\n%sW\n'
           % (query, tag, query[:-1]))
    return uniref, env


MERGED_DEPTH = 3


def make_tarball(query, tag='X'):
    """A tar.gz shaped like the one /result/download/{id} returns."""
    uniref, env = a3m_for(query, tag)
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode='w:gz') as archive:
        for name, text in (('uniref.a3m', uniref),
                           ('bfd.mgnify30.metaeuk30.smag30.a3m', env)):
            raw = text.encode('utf-8')
            info = tarfile.TarInfo(name)
            info.size = len(raw)
            archive.addfile(info, io.BytesIO(raw))
    return buffer.getvalue()


class FakeResponse:

    def __init__(self, payload):
        self._buffer = io.BytesIO(payload)

    def read(self, size=-1):
        return self._buffer.read(size if size and size > 0 else None)

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class FakeServer:
    """A ColabFold MSA server at the _urlopen seam, answering PER QUERY.

    Keyed on what was posted rather than handing out one fixed tarball, because the
    dimer test searches two different chains and a server that answered both with the
    same alignment would let a mis-slotted map pass.
    """

    def __init__(self, queries=(QUERY,)):
        self.tarballs = {q: make_tarball(q, tag=chr(ord('A') + i))
                         for i, q in enumerate(queries)}
        self.submits = 0
        self.downloads = 0
        #: ticket id -> the query it was submitted for.
        self.tickets = {}

    def __call__(self, request, timeout=None):
        url = request.full_url
        if url.endswith('/ticket/msa'):
            self.submits += 1
            posted = (request.data or b'').decode('utf-8')
            for query in self.tarballs:
                if query in posted:
                    ticket = 'ticket-%d' % self.submits
                    self.tickets[ticket] = query
                    return self._json({'id': ticket, 'status': 'PENDING'})
            raise AssertionError('submitted a query the server has no answer for')
        if '/ticket/' in url:
            return self._json({'id': url.rsplit('/', 1)[-1], 'status': 'COMPLETE'})
        if '/result/download/' in url:
            self.downloads += 1
            return FakeResponse(self.tarballs[self.tickets[url.rsplit('/', 1)[-1]]])
        raise AssertionError('unexpected request to %s' % url)

    @staticmethod
    def _json(payload):
        return FakeResponse(json.dumps(payload).encode('utf-8'))


class StubJob:

    _counter = 0

    def __init__(self, spec, options):
        StubJob._counter += 1
        self.job_id = 'e2estub-%d' % StubJob._counter
        self.spec = spec
        self.options = options

    def status(self):
        return {'state': 'running', 'phase': 'inference', 'fraction': 0.5,
                'error': None, 'result_path': None}

    def cancel(self):
        pass


def stub_predictor(predictor_id, supports_msa=True):
    """A registered predictor with no weights, so predict() submits immediately."""

    class Stub(Predictor):
        id = predictor_id
        name = 'Stub (%s)' % predictor_id
        weight_bundle = None
        option_defaults = {'recycling_steps': 3, 'diffusion_steps': 200, 'seed': 0}
        if supports_msa:
            option_defaults['msa_depth'] = MAX_MSA_DEPTH

        def check_available(self):
            return None

        def parse_spec(self, sequence, name=''):
            return PredictionSpec(parse_chains(sequence), name)

        def submit(self, spec, options, weights_path):
            return StubJob(spec, options)

    Stub.supports_msa = supports_msa
    return registry.register(Stub(), replace=True)


class MSAEndToEndTestCase(testing.PyMOLTestCase):
    """Both fixtures at once: a private fake server AND a clean predictor registry."""

    def setUp(self):
        testing.PyMOLTestCase.setUp(self)
        self._tmp = testing.mkdtemp()
        self.root = self._tmp.__enter__()
        os.environ['RAYMOL_MSA_DIR'] = self.root
        self._saved_env = os.environ.pop(colabfold.SERVER_ENV, None)
        colabfold.set_server(PRIVATE)
        msa_module._PUBLIC_WARNED.clear()
        self._poll = (searching.POLL_SECONDS, searching.FIRST_POLL_SECONDS)
        searching.POLL_SECONDS = 0.01
        searching.FIRST_POLL_SECONDS = 0.0
        self._saved_registry = dict(registry._REGISTRY)
        store.clear()

    def tearDown(self):
        searching.shutdown()
        searching.POLL_SECONDS, searching.FIRST_POLL_SECONDS = self._poll
        colabfold.set_server('')
        msa_module._PUBLIC_WARNED.clear()
        os.environ.pop('RAYMOL_MSA_DIR', None)
        if self._saved_env is not None:
            os.environ[colabfold.SERVER_ENV] = self._saved_env
        self._tmp.__exit__(None, None, None)
        store.clear()
        predicting._JOBS.clear()
        predicting._PENDING.clear()
        registry._REGISTRY.clear()
        registry._REGISTRY.update(self._saved_registry)
        testing.PyMOLTestCase.tearDown(self)

    def search(self, server, sequence=QUERY, **kwargs):
        """Run a search to completion and land it. Returns the stored name."""
        before = set(store.names())
        with patch('pymol.msas.colabfold._urlopen', server):
            search_id = cmd.msa_search(sequence, **kwargs)
            searching.join(search_id, timeout=10)
        with redirect_stdout(io.StringIO()):
            msa_module.pump()
        landed = [n for n in store.names() if n not in before]
        self.assertEqual(len(landed), 1, 'search did not land exactly one alignment')
        return landed[0]

    def quiet_predict(self, *args, **kwargs):
        buf = io.StringIO()
        with redirect_stdout(buf):
            job = cmd.predict(*args, **kwargs)
        return job, buf.getvalue()

    def wire(self, spec, options=None):
        """Submit through the REAL host and return the request JSON it wrote."""
        with redirect_stdout(io.StringIO()):
            job = host.submit(spec, options or PredictionOptions(), '/tmp/weights')
        self.addCleanup(job._discard_inputs)
        with open(job.request_path) as handle:
            return job, json.load(handle)


class SearchToFoldTest(MSAEndToEndTestCase):
    """#298 -> #296 -> #297: an alignment nobody typed a filename for gets folded."""

    def testASearchedAlignmentIsFoldedThroughItsAttachmentWithoutBeingNamed(self):
        """The whole point of target= on msa_search: search once, then fold the object
        and have the alignment come along."""
        stub_predictor('e2e')
        cmd.fab(QUERY, 'prot', chain='A')
        name = self.search(FakeServer(), 'prot', target='prot')

        job, printed = self.quiet_predict('e2e', 'prot')
        self.assertEqual(list(job.spec.alignments), ['A'])
        self.assertEqual(job.spec.alignments['A'].name, name)
        self.assertEqual(job.spec.alignments['A'].depth, MERGED_DEPTH)
        # Reported even though quiet=1, because the command that started this run does
        # not name the alignment anywhere.
        self.assertIn(name, printed)

    def testTheSearchedNameIsDerivedFromTheObjectAndIsWhatMsaEqualsTakes(self):
        """`<object>_msa` is only useful if it is addressable; this is the round trip
        from the name #298 invents to the name #297 looks up."""
        stub_predictor('e2e')
        cmd.fab(QUERY, 'prot', chain='A')
        name = self.search(FakeServer(), 'prot')
        self.assertEqual(name, 'prot_msa')
        job, _ = self.quiet_predict('e2e', 'prot', msa='prot_msa')
        self.assertEqual(job.spec.alignments['A'].name, 'prot_msa')

    def testTheSearchedA3mReachesTheHostWireByteIdentical(self):
        """Two hand-offs (server -> store, store -> a3m file) and neither may re-encode:
        boltz-mlx's parity claim is about the bytes the server produced."""
        cmd.fab(QUERY, 'prot', chain='A')
        name = self.search(FakeServer(), 'prot', target='prot')

        sequence, sources = predicting.resolve_input('prot')
        spec = PredictionSpec(parse_chains(sequence), 'out')
        spec.alignments = predicting.alignments_from_attachments(sources, spec.chains)
        job, request = self.wire(spec)

        self.assertEqual([e['chain'] for e in request['alignments']], ['A'])
        with open(request['alignments'][0]['a3m_path']) as handle:
            on_disk = handle.read()
        self.assertEqual(on_disk, store.get(name).a3m)
        # And it really is the merged result of both databases, not the query echoed
        # back: the environmental row only exists in the second tarball member.
        self.assertIn('UniRef100_A_1', on_disk)
        self.assertIn('ENV_A_1', on_disk)

    def testTheWireKeepsTheDuplicateRowThatTheStoredDepthDoesNot(self):
        """Both databases repeat the query as their first row, so the merged file has
        four rows and depth 3. The DEPTH is deduped because that is what the featurizer
        will see; the BYTES are not, because boltz-mlx dedups them itself and the parity
        claim is about the file the server produced."""
        name = self.search(FakeServer(), QUERY, name='aln')
        self.assertEqual(store.get(name).depth, MERGED_DEPTH)
        spec = PredictionSpec((('A', QUERY),), 'out', {'A': store.get(name)})
        _, request = self.wire(spec)
        with open(request['alignments'][0]['a3m_path']) as handle:
            self.assertEqual(handle.read().count('>'), MERGED_DEPTH + 1)

    def testTwoSearchedChainsFoldAsADimerBySlot(self):
        """Per-chain unpaired alignments are #298's contract; msa=a/b is #297's way of
        spending them. Different alignments per chain, so a swap cannot pass."""
        stub_predictor('e2e')
        server = FakeServer(queries=(QUERY, QUERY_B))
        first = self.search(server, QUERY, name='aln_a')
        second = self.search(server, QUERY_B, name='aln_b')

        job, _ = self.quiet_predict('e2e', '%s/%s' % (QUERY, QUERY_B),
                                    msa='%s/%s' % (first, second))
        self.assertEqual(job.spec.alignments['A'].name, 'aln_a')
        self.assertEqual(job.spec.alignments['B'].name, 'aln_b')
        self.assertEqual(job.spec.alignments['A'].query, QUERY)
        self.assertEqual(job.spec.alignments['B'].query, QUERY_B)

    def testEachSearchedChainGetsItsOwnFileOnTheWire(self):
        server = FakeServer(queries=(QUERY, QUERY_B))
        first = self.search(server, QUERY, name='aln_a')
        second = self.search(server, QUERY_B, name='aln_b')
        spec = PredictionSpec((('A', QUERY), ('B', QUERY_B)), 'out',
                              {'A': store.get(first), 'B': store.get(second)})
        job, request = self.wire(spec)

        paths = {e['chain']: e['a3m_path'] for e in request['alignments']}
        self.assertEqual(sorted(paths), ['A', 'B'])
        self.assertNotEqual(paths['A'], paths['B'])
        for chain, query in (('A', QUERY), ('B', QUERY_B)):
            with open(paths[chain]) as handle:
                self.assertIn(query, handle.read())

    def testASearchedAlignmentIsRefusedByAMethodThatCannotUseOne(self):
        """The capability check is #297's, but the alignment it refuses is #298's --
        and it must refuse before submitting, not after."""
        stub_predictor('nomsa', supports_msa=False)
        name = self.search(FakeServer(), QUERY, name='aln')
        with self.assertRaises(PredictionInputError) as caught:
            self.quiet_predict('nomsa', QUERY, msa=name)
        self.assertIn(name, str(caught.exception))
        self.assertEqual(predicting._JOBS, {})

    def testRenamingASearchedAlignmentMovesBothTheLookupAndTheAttachment(self):
        """#296's rename has to be honoured by #297's two entry points at once."""
        stub_predictor('e2e')
        cmd.fab(QUERY, 'prot', chain='A')
        name = self.search(FakeServer(), 'prot', target='prot')
        cmd.msa_rename(name, 'curated')

        by_name, _ = self.quiet_predict('e2e', QUERY, msa='curated')
        self.assertEqual(by_name.spec.alignments['A'].name, 'curated')
        attached, _ = self.quiet_predict('e2e', 'prot')
        self.assertEqual(attached.spec.alignments['A'].name, 'curated')

    def testDeletingASearchedAlignmentReturnsTheObjectToSingleSequence(self):
        """A deleted alignment must leave no dangling attachment that folds anyway."""
        stub_predictor('e2e')
        cmd.fab(QUERY, 'prot', chain='A')
        name = self.search(FakeServer(), 'prot', target='prot')
        cmd.msa_delete(name)
        job, _ = self.quiet_predict('e2e', 'prot')
        self.assertEqual(job.spec.alignments, {})

    def testASearchStillRunningWhenTheSessionIsReplacedCannotAttachToTheNewOne(self):
        """A search takes minutes and the store is cleared on restore, so the worker can
        land into a session that was not open when it started. It must not bind to an
        object that merely inherited the name: the check is re-run at landing, and a
        mismatch stores the alignment unattached rather than silently folding with it."""
        import threading

        stub_predictor('e2e')
        server = FakeServer()
        release = threading.Event()
        polling = threading.Event()

        def hold(request, timeout=None):
            url = request.full_url
            if '/ticket/' in url and not url.endswith('/ticket/msa'):
                polling.set()
                if not release.is_set():
                    return FakeServer._json({'id': 'ticket-1', 'status': 'RUNNING'})
            return server(request, timeout)

        with patch('pymol.msas.colabfold._urlopen', hold):
            cmd.fab(QUERY, 'prot', chain='A')
            search_id = cmd.msa_search('prot', target='prot')
            self.assertTrue(polling.wait(10))

            # A different session, whose object took the same name.
            other = os.path.join(self.root, 'other.pse')
            cmd.delete('all')
            cmd.fab(QUERY_B, 'prot', chain='A')
            cmd.save(other)
            cmd.delete('all')
            with redirect_stdout(io.StringIO()):
                cmd.load(other)
            self.assertEqual(store.names(), [])

            release.set()
            searching.join(search_id, timeout=10)
            buf = io.StringIO()
            with redirect_stdout(buf):
                msa_module.pump()

        landed = store.names()
        self.assertEqual(len(landed), 1)
        alignment = store.get(landed[0])
        self.assertEqual(alignment.target, '', 'attached to the wrong molecule')
        self.assertEqual(alignment.query, QUERY)
        self.assertIn('no longer matches', buf.getvalue())
        # And so the object that inherited the name folds single-sequence.
        job, _ = self.quiet_predict('e2e', 'prot')
        self.assertEqual(job.spec.alignments, {})

    def testASearchedAndALoadedAlignmentOnOneChainAreRefusedRatherThanPicked(self):
        """The two ways an alignment can reach a chain are #298's and #296's, and they
        can both reach the same one. Folding with whichever landed first would make the
        result depend on load order."""
        stub_predictor('e2e')
        cmd.fab(QUERY, 'prot', chain='A')
        searched = self.search(FakeServer(), 'prot', target='prot')
        cmd.load_msa(self.datafile('msa_toy.a3m'), 'toy', 'prot', 'A')

        with self.assertRaises(PredictionInputError) as caught:
            self.quiet_predict('e2e', 'prot')
        message = str(caught.exception)
        self.assertIn(searched, message)
        self.assertIn('toy', message)
        # And naming one resolves it, rather than leaving the object unfoldable.
        job, _ = self.quiet_predict('e2e', 'prot', msa=searched)
        self.assertEqual(job.spec.alignments['A'].name, searched)

    def testACachedSearchIsFoldableOnTheVeryNextLine(self):
        """msa_search's cache is what makes re-folding a target cheap, and its docstring
        promises a cached result lands before the call returns -- so a script can search
        and fold in two consecutive statements with no pump between them."""
        stub_predictor('e2e')
        server = FakeServer()
        first = self.search(server, QUERY, name='aln')
        self.assertEqual(server.submits, 1)
        store.delete(first)

        with patch('pymol.msas.colabfold._urlopen', server):
            cmd.msa_search(QUERY, name='again')
        # No join, no pump: already in the store.
        self.assertEqual(store.names(), ['again'])
        self.assertEqual(server.submits, 1, 'a cached query was searched again')
        job, _ = self.quiet_predict('e2e', QUERY, msa='again')
        self.assertEqual(job.spec.alignments['A'].depth, MERGED_DEPTH)

    def testTheDepthLeverTruncatesASearchedAlignmentAndSaysSo(self):
        """msa_depth is #297's memory lever and the searched depth is #298's number;
        the report has to quote both."""
        stub_predictor('e2e')
        name = self.search(FakeServer(), QUERY, name='aln')
        job, printed = self.quiet_predict('e2e', QUERY, msa=name, msa_depth=2)
        self.assertIn('2 of %d sequences' % MERGED_DEPTH, printed)
        _, request = self.wire(job.spec, PredictionOptions(msa_depth=2))
        self.assertEqual(request['msa_depth'], 2)


class SessionRoundTripTest(MSAEndToEndTestCase):
    """#296's .pse task carrying #298's output to #297, across a save and a reopen."""

    def save_and_reopen(self):
        """Write a .pse, wipe everything a reopen would wipe, and read it back."""
        path = os.path.join(self.root, 'session.pse')
        cmd.save(path)
        cmd.delete('all')
        store.clear()
        self.assertEqual(store.names(), [])
        with redirect_stdout(io.StringIO()):
            cmd.load(path)
        return path

    def testASearchedAlignmentSurvivesASaveAndStillFolds(self):
        stub_predictor('e2e')
        cmd.fab(QUERY, 'prot', chain='A')
        name = self.search(FakeServer(), 'prot', target='prot')
        before = store.get(name).a3m

        self.save_and_reopen()
        self.assertEqual(store.names(), [name])
        # Byte-identical through gzip+base64, or the parity claim dies in the .pse.
        self.assertEqual(store.get(name).a3m, before)

        job, printed = self.quiet_predict('e2e', 'prot')
        self.assertEqual(job.spec.alignments['A'].name, name)
        self.assertEqual(job.spec.alignments['A'].depth, MERGED_DEPTH)
        self.assertIn(name, printed)

    def testProvenanceOfARestoredSearchStillNamesTheServer(self):
        """Inside a reopened .pse this is the only record that a sequence was sent
        somewhere -- and for a public server, that it left the machine at all."""
        name = self.search(FakeServer(), QUERY, name='aln')
        self.save_and_reopen()
        source = store.get(name).source
        self.assertEqual(source['kind'], 'search')
        self.assertEqual(source['server'], PRIVATE)
        self.assertEqual(source['mode'], 'env')

    def testARestoredAlignmentGoesToTheHostWireUnchanged(self):
        name = self.search(FakeServer(), QUERY, name='aln')
        original = store.get(name).a3m
        self.save_and_reopen()
        spec = PredictionSpec((('A', QUERY),), 'out', {'A': store.get(name)})
        _, request = self.wire(spec)
        with open(request['alignments'][0]['a3m_path']) as handle:
            self.assertEqual(handle.read(), original)

    def testOpeningASessionWithoutAlignmentsDropsTheSearchedOnes(self):
        """Otherwise the previous session's alignment stays attached to an object name
        that now means something else -- and folds silently."""
        stub_predictor('e2e')
        cmd.fab(QUERY, 'prot', chain='A')
        self.search(FakeServer(), 'prot', target='prot')

        empty = os.path.join(self.root, 'empty.pse')
        cmd.delete('all')
        store.clear()
        cmd.fab(QUERY, 'prot', chain='A')
        cmd.save(empty)

        # Reload the alignment-bearing session, then the empty one over it.
        with redirect_stdout(io.StringIO()):
            cmd.load(empty)
        self.assertEqual(store.names(), [])
        job, _ = self.quiet_predict('e2e', 'prot')
        self.assertEqual(job.spec.alignments, {})


class SwiftWireContractTest(MSAEndToEndTestCase):
    """The Python/Swift halves of #297 agreeing on the JSON between them.

    Both sides have tests and both pass, because each writes its own fixture: Python
    asserts the keys it emits, and BoltzJobManagerMSATests.swift hand-builds a
    dictionary with the keys it expects. Nothing compares the two, so a rename on one
    side is a silent decode failure at runtime -- an alignment quietly not used, which
    upstream Boltz then papers over with a depth-1 dummy.

    Read out of the Swift source rather than compiled, so this runs in the same headless
    suite as everything else here. It checks the NAMES, which is the half that drifts;
    the types are checked by the Swift tests.
    """

    #: The struct whose CodingKeys must cover the request Python writes.
    SWIFT_SOURCE = os.path.join('swiftui', 'PyMOLViewer', 'Shared',
                                'BoltzJobManager.swift')

    def swift_wire_names(self, after):
        """Wire names in the first `enum CodingKeys` following `after` in the source."""
        import re

        root = os.path.join(os.path.dirname(__file__), os.pardir, os.pardir, os.pardir)
        path = os.path.normpath(os.path.join(root, self.SWIFT_SOURCE))
        if not os.path.isfile(path):
            # Skipped rather than passed: a source-reading contract test that cannot
            # find the source has not checked anything, and saying so is the only
            # honest outcome. Reached only outside a repo checkout -- CI runs these
            # from the worktree, where the file is always there.
            self.skipTest('%s not present; not a repo checkout' % self.SWIFT_SOURCE)
        with open(path) as handle:
            source = handle.read()
        start = source.index(after)
        block = source[source.index('enum CodingKeys', start):]
        block = block[:block.index('}')]
        names = set()
        for entry in re.findall(r'case\s+([^\n]+)', block):
            for part in entry.split(','):
                part = part.strip().rstrip('}').strip()
                if not part:
                    continue
                if '=' in part:
                    names.add(part.split('=', 1)[1].strip().strip('"'))
                else:
                    names.add(part)
        return names

    def testEveryKeyPythonWritesIsOneSwiftDecodes(self):
        name = self.search(FakeServer(), QUERY, name='aln')
        spec = PredictionSpec((('A', QUERY),), 'out', {'A': store.get(name)})
        _, request = self.wire(spec, PredictionOptions(msa_depth=64))

        swift = self.swift_wire_names('struct Request: Codable')
        unknown = set(request) - swift
        self.assertEqual(unknown, set(),
                         'Python writes %s, which Swift Request does not decode'
                         % sorted(unknown))
        # The MSA keys specifically, so this fails loudly if the feature is dropped
        # from either side rather than passing vacuously on an empty request.
        self.assertIn('alignments', request)
        self.assertIn('msa_depth', request)
        self.assertEqual(request['msa_depth'], 64)

    def testEveryKeyOfAnAlignmentEntryIsOneSwiftDecodes(self):
        name = self.search(FakeServer(), QUERY, name='aln')
        spec = PredictionSpec((('A', QUERY),), 'out', {'A': store.get(name)})
        _, request = self.wire(spec)

        swift = self.swift_wire_names('struct Alignment: Codable')
        self.assertEqual(swift, {'chain', 'a3m_path'})
        for entry in request['alignments']:
            self.assertEqual(set(entry), swift)

    def testTheAlignmentPathSwiftIsToldToOpenReallyExists(self):
        """The one failure a key check cannot see: a path that decodes and then is not
        there. Python writes the a3m before the request, so by the time the request is
        readable the file it names must be too."""
        name = self.search(FakeServer(), QUERY, name='aln')
        spec = PredictionSpec((('A', QUERY),), 'out', {'A': store.get(name)})
        _, request = self.wire(spec)
        path = request['alignments'][0]['a3m_path']
        self.assertTrue(os.path.isfile(path), '%s does not exist' % path)
        with open(path) as handle:
            self.assertEqual(handle.read(), store.get(name).a3m)


def install_appkit_stubs():
    """AppKit/objc/Foundation, permissively, so the panel modules import headlessly.

    Same stubs testing/tests/test_appkit_object_panel.py installs, for the same reason:
    pyobjc is not present under a headless `pymol -c`. Nothing exercised here touches
    a widget -- `_alignments` and the pump half of `poll_panel` are plain Python -- so
    the stub is only standing in for the import, never for behaviour under test.
    """
    import sys
    import types
    from unittest.mock import MagicMock

    class _Permissive(types.ModuleType):

        def __getattr__(self, name):
            mock = MagicMock(name='%s.%s' % (self.__name__, name))
            setattr(self, name, mock)
            return mock

    if 'objc' not in sys.modules:
        appkit = _Permissive('AppKit')
        appkit.NSObject = type('NSObject', (), {})
        objc = _Permissive('objc')

        class _ObjcSuperProxy:

            def __init__(self, *args):
                pass

            def init(self):
                return None

        objc.super = _ObjcSuperProxy
        objc.typedSelector = lambda sig: (lambda fn: fn)
        objc.selector = lambda fn, signature=b'': fn
        sys.modules['AppKit'] = appkit
        sys.modules['objc'] = objc
        sys.modules['Foundation'] = _Permissive('Foundation')


class PanelPollTest(MSAEndToEndTestCase):
    """The 500 ms poll is where #298's worker hands off to #296's panel section."""

    def setUp(self):
        MSAEndToEndTestCase.setUp(self)
        install_appkit_stubs()

    def testThePollLandsAFinishedSearchAndShowsItInTheSameTick(self):
        """poll_panel pumps before it gathers, so a search that finished between ticks
        appears on this tick rather than the next."""
        from pymol import appkit_inspector, appkit_object_panel

        server = FakeServer()
        with patch('pymol.msas.colabfold._urlopen', server):
            search_id = cmd.msa_search(QUERY, name='aln')
            searching.join(search_id, timeout=10)
        # The worker is done and yet the store is untouched: only the main thread writes.
        self.assertEqual(store.names(), [])

        with redirect_stdout(io.StringIO()):
            appkit_inspector.poll_panel()
        self.assertEqual(store.names(), ['aln'])
        self.assertIn('aln', appkit_object_panel._alignments())

    def testThePayloadSwiftReadsCarriesEverySummaryFieldItRequires(self):
        """ObjectPanel.swift's AlignmentSummary has five NON-optional fields, and the
        whole PanelPayload decode is a single `guard let` -- so an alignment summary
        missing one field does not lose the alignments section, it freezes the entire
        object panel on its stale list. Checked against the file Swift actually reads.
        """
        import tempfile
        from pymol import appkit_inspector

        cmd.fab(QUERY, 'prot', chain='A')
        name = self.search(FakeServer(), 'prot', target='prot')
        with redirect_stdout(io.StringIO()):
            appkit_inspector.poll_panel()

        written = os.path.join(tempfile.gettempdir(),
                               'pymol_objpanel_%d.json' % os.getpid())
        with open(written) as handle:
            payload = json.load(handle)
        summary = payload['alignments'][name]
        # The names and JSON types AlignmentSummary declares.
        for field, kind in (('depth', int), ('columns', int), ('residues', int),
                            ('target', str), ('chain', str)):
            self.assertIn(field, summary)
            self.assertIsInstance(summary[field], kind, field)
        self.assertEqual(summary['depth'], MERGED_DEPTH)
        self.assertEqual(summary['target'], 'prot')

    def testAFoldableAlignmentShowsTheChainItIsAttachedTo(self):
        """The panel row is how a user checks, before spending minutes folding, that
        the alignment predict will silently pick up is on the chain they meant."""
        from pymol import appkit_object_panel

        cmd.fab(QUERY, 'prot', chain='A')
        name = self.search(FakeServer(), 'prot', target='prot')
        entry = appkit_object_panel._alignments()[name]
        self.assertEqual(entry['target'], 'prot')
        self.assertEqual(entry['chain'], 'A')
        self.assertEqual(entry['depth'], MERGED_DEPTH)
        self.assertEqual(entry['residues'], len(QUERY))
