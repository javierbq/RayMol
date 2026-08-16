"""Building an alignment on a ColabFold MSA server: cmd.msa_search (#298).

NOTHING HERE TOUCHES A REAL SERVER, public or private. Every test patches
`pymol.msas.colabfold._urlopen` -- the same kind of seam the weight tests patch on
`pymol.predictors.weights._urlopen` -- and a search that escaped the patch would publish
a sequence to a third party from CI, which is the one failure mode this suite exists to
make impossible.

The properties worth pinning, in order:

  1. the ticket -> poll -> download round trip lands an alignment with the right depth
     and provenance, and the provenance names the server;
  2. the WORKER THREAD CREATES NOTHING in the session -- the alignment appears only when
     the main-thread pump runs, because RayMol's Metal renderer reads session state on
     the main thread without taking PyMOL's API lock;
  3. a refusal (RATELIMIT, ERROR) reads as a refusal that names the server, never as a
     hang;
  4. a cancel leaves no half-built alignment;
  5. the cache makes a repeat search free, and refresh=1 bypasses it;
  6. the first use of a public server says the sequence is leaving this machine.

    pymol -ckqy testing/testing.py --run testing/tests/msa/msa_search.py
"""
import io
import json
import os
import sys
import tarfile
import threading

from unittest.mock import patch
from urllib.error import HTTPError

from pymol import cmd, testing
from pymol import msa as msa_module
from pymol.msas import colabfold, searching, store
from pymol.msas.errors import MSAInputError, MSANotFound

#: 24 residues: over MIN_QUERY_RESIDUES, and the same query testing/data/msa_toy.a3m uses
#: so `fab` can build a target that genuinely matches it.
QUERY = 'MKTAYIAKQRQISFVKSHFSRQLE'

UNIREF_A3M = ('>101\n%s\n'
              '>UniRef100_A\nMKTAYIAKQRQISFVKSHFSRQLD\n'
              '>UniRef100_B\nMKTAYIAKQRQISFVKSHFSRQLA\n' % QUERY)

#: The environmental alignment repeats the query as its first row, exactly as the server
#: does -- which is why the merged depth is 4 and not 5.
ENV_A3M = ('>101\n%s\n'
           '>ENV_1\nMKTAYIAKQRQISFVKSHFSRQLW\n' % QUERY)

MERGED_DEPTH = 4
MERGED_COLUMNS = 24

PRIVATE = 'https://msa.internal.example'


def make_tarball(members=None):
    """A tar.gz shaped like the one /result/download/{id} returns."""
    members = members if members is not None else [
        ('uniref.a3m', UNIREF_A3M),
        ('bfd.mgnify30.metaeuk30.smag30.a3m', ENV_A3M),
    ]
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode='w:gz') as archive:
        for name, text in members:
            raw = text.encode('utf-8')
            info = tarfile.TarInfo(name)
            info.size = len(raw)
            archive.addfile(info, io.BytesIO(raw))
    return buffer.getvalue()


class FakeResponse:
    """urlopen's result: a context manager whose read() takes an optional size."""

    def __init__(self, payload):
        self._buffer = io.BytesIO(payload)

    def read(self, size=-1):
        return self._buffer.read(size if size and size > 0 else None)

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class FakeServer:
    """A ColabFold MSA server at the _urlopen seam.

    Records every request so a test can assert what was sent -- the posted mode, the
    User-Agent the public server asks for, and above all HOW MANY searches happened,
    which is the only way to tell a cache hit from a repeat search.
    """

    def __init__(self, statuses=('COMPLETE',), submit_status='PENDING',
                 tarball=None, submit_error=None):
        #: Statuses handed out by /ticket/{id}, last one repeating forever.
        self.statuses = list(statuses)
        self.submit_status = submit_status
        self.submit_error = submit_error
        self.tarball = make_tarball() if tarball is None else tarball
        self.submits = 0
        self.downloads = 0
        self.polls = 0
        self.urls = []
        self.posted = []
        self.agents = []
        #: Set once the ticket has been polled at least once, so a test can act
        #: mid-search instead of sleeping and hoping.
        self.polling = threading.Event()

    def __call__(self, request, timeout=None):
        url = request.full_url
        self.urls.append(url)
        self.agents.append(request.get_header('User-agent'))
        if url.endswith('/ticket/msa'):
            self.submits += 1
            if self.submit_error is not None:
                raise self.submit_error
            self.posted.append((request.data or b'').decode('utf-8'))
            return self._json({'id': 'ticket-1', 'status': self.submit_status})
        if '/ticket/' in url:
            self.polls += 1
            self.polling.set()
            status = (self.statuses.pop(0) if len(self.statuses) > 1
                      else self.statuses[0])
            return self._json({'id': 'ticket-1', 'status': status})
        if '/result/download/' in url:
            self.downloads += 1
            return FakeResponse(self.tarball)
        raise AssertionError('unexpected request to %s' % url)

    @staticmethod
    def _json(payload):
        return FakeResponse(json.dumps(payload).encode('utf-8'))


def rate_limited(url='https://api.colabfold.com/ticket/msa'):
    """The 429 tollbooth answers a rate-limited submit with (server.go)."""
    body = json.dumps({'status': 'RATELIMIT', 'reason': 'too many requests'})
    return HTTPError(url, 429, 'Too Many Requests', {},
                     io.BytesIO(body.encode('utf-8')))


class captured_output:
    """Collect what was printed while this context is open.

    stdout rather than cmd._get_feedback(): under `pymol -c` a Python print goes to the
    real stdout and never enters the Ortho queue, so asserting on the queue headlessly
    would pass vacuously. In the app that same write is what the feedback buffer captures.
    """

    def __enter__(self):
        self._saved = sys.stdout
        self._buffer = io.StringIO()
        sys.stdout = self._buffer
        return self

    def __exit__(self, *exc):
        sys.stdout = self._saved
        return False

    def text(self):
        return self._buffer.getvalue()

    def markers(self):
        out = []
        for line in self.text().split('\n'):
            if line.startswith(searching.MARKER):
                out.append(json.loads(line[len(searching.MARKER):]))
        return out


class MSASearchTestCase(testing.PyMOLTestCase):
    """Shared fixture: a private server by default, a temp cache, no live searches."""

    def setUp(self):
        testing.PyMOLTestCase.setUp(self)
        self._tmp = testing.mkdtemp()
        self.root = self._tmp.__enter__()
        os.environ['RAYMOL_MSA_DIR'] = self.root
        self._saved_env = os.environ.pop(colabfold.SERVER_ENV, None)
        # Private by default: the public-server warning is a property one test asserts,
        # not noise every other test has to tolerate.
        colabfold.set_server(PRIVATE)
        msa_module._PUBLIC_WARNED.clear()
        # Polling is what makes a search take minutes in production and would make this
        # suite take minutes too. Cancellation is an Event, so it stays instant.
        self._poll = (searching.POLL_SECONDS, searching.FIRST_POLL_SECONDS)
        searching.POLL_SECONDS = 0.01
        searching.FIRST_POLL_SECONDS = 0.0

    def tearDown(self):
        # Stop the workers BEFORE the cache root goes: one still writing into it turns
        # the rmtree below into an intermittent "directory not empty", and the next test
        # would inherit a live thread holding this test's patched _urlopen.
        searching.shutdown()
        searching.POLL_SECONDS, searching.FIRST_POLL_SECONDS = self._poll
        colabfold.set_server('')
        msa_module._PUBLIC_WARNED.clear()
        os.environ.pop('RAYMOL_MSA_DIR', None)
        if self._saved_env is not None:
            os.environ[colabfold.SERVER_ENV] = self._saved_env
        self._tmp.__exit__(None, None, None)
        testing.PyMOLTestCase.tearDown(self)

    def run_search(self, fake, sequence=QUERY, **kwargs):
        """Search and wait for it to settle, WITHOUT pumping. Returns the search id."""
        with patch('pymol.msas.colabfold._urlopen', fake):
            search_id = cmd.msa_search(sequence, **kwargs)
            searching.join(search_id, timeout=10)
        return search_id


class MSASearchHappyPathTest(MSASearchTestCase):

    def testTicketPollDownloadLandsAnAlignment(self):
        server = FakeServer(statuses=['PENDING', 'RUNNING', 'COMPLETE'])
        search_id = self.run_search(server)
        # Landed by the pump, not by the worker -- see MSASearchThreadingTest.
        cmd.msa_status()
        self.assertEqual(server.submits, 1)
        self.assertEqual(server.downloads, 1)
        name = cmd.msa_list()[0]
        alignment = store.get(name)
        self.assertEqual(alignment.query, QUERY)
        self.assertEqual(alignment.depth, MERGED_DEPTH)
        self.assertEqual(alignment.columns, MERGED_COLUMNS)
        self.assertEqual(cmd.msa_status(search_id)[search_id]['state'], 'done')

    def testProvenanceNamesTheServer(self):
        """Inside a saved .pse this is the only record of where an alignment came from
        -- and, for a public search, that the sequence left this machine."""
        self.run_search(FakeServer())
        cmd.msa_status()
        source = store.get(cmd.msa_list()[0]).source
        self.assertEqual(source['kind'], 'search')
        self.assertEqual(source['server'], PRIVATE)
        self.assertEqual(source['mode'], 'env')
        self.assertEqual(source['ticket'], 'ticket-1')
        self.assertIn('uniref.a3m', source['databases'])

    def testTheEnvironmentalAlignmentIsMergedAfterUniref(self):
        """ColabFold's own assembly order. An alignment that differs from the one
        colabfold_batch would have produced is a different input, not a tidier one."""
        self.run_search(FakeServer())
        cmd.msa_status()
        text = store.get(cmd.msa_list()[0]).a3m
        self.assertTrue(text.startswith('>101'))
        self.assertLess(text.index('UniRef100_A'), text.index('ENV_1'))

    def testAPairedAlignmentInTheTarballIsIgnored(self):
        """The server may return one; nothing here will fold it. See #298's
        non-negotiable -- fake pairing fails by reading HIGH, not by crashing."""
        tarball = make_tarball([('uniref.a3m', UNIREF_A3M),
                                ('pair.a3m', '>101\n%s\n' % QUERY)])
        self.run_search(FakeServer(tarball=tarball))
        cmd.msa_status()
        self.assertEqual(store.get(cmd.msa_list()[0]).depth, 3)

    def testTheSubmitCarriesTheQueryModeAndAUserAgent(self):
        """The public server asks for a real User-Agent and throttles anonymous traffic
        harder; ColabFold's client warns that the warning will become an error."""
        server = FakeServer()
        self.run_search(server)
        self.assertIn('mode=env', server.posted[0])
        self.assertIn(QUERY, server.posted[0])
        self.assertTrue(server.agents[0].startswith('RayMol/'), server.agents[0])

    def testACompleteTicketAtSubmitIsNotPolled(self):
        """The backend keys a job on its query hash, so a query it has already run comes
        back COMPLETE from the submit itself."""
        server = FakeServer(submit_status='COMPLETE')
        self.run_search(server)
        cmd.msa_status()
        self.assertEqual(server.polls, 0)
        self.assertEqual(len(cmd.msa_list()), 1)

    def testQuietZeroTakesTheMessageEmittingPath(self):
        """parsing.py forces quiet=0 for every command-line invocation, so a suite that
        only exercises quiet=1 never runs the lines a user actually sees."""
        server = FakeServer()
        with captured_output() as out:
            search_id = self.run_search(server, quiet=0)
            cmd.msa_status(quiet=0)
        self.assertIn(PRIVATE, out.text())
        self.assertIn(search_id, out.text())
        self.assertEqual(len(cmd.msa_list()), 1)

    def testTheNameFollowsTheObjectWhenTheQueryCameFromOne(self):
        cmd.fab(QUERY, 'binder')
        self.run_search(FakeServer(), sequence='binder')
        cmd.msa_status()
        self.assertEqual(cmd.msa_list(), ['binder_msa'])

    def testAnExplicitTargetIsCheckedAndRecorded(self):
        cmd.fab(QUERY, 'binder')
        self.run_search(FakeServer(), target='binder')
        cmd.msa_status()
        alignment = store.get(cmd.msa_list()[0])
        self.assertEqual(alignment.target, 'binder')

    def testAMismatchedTargetIsRefusedBeforeAnySearchRuns(self):
        """Minutes of searching for an alignment that would be refused on arrival."""
        cmd.fab('GSHMAGSHMAGSHMA', 'other')
        server = FakeServer()
        with patch('pymol.msas.colabfold._urlopen', server):
            self.assertRaises(MSAInputError, cmd.msa_search, QUERY, target='other')
        self.assertEqual(server.submits, 0)

    def testAnAlignmentStillLandsWhenItsTargetDisappeared(self):
        """It cost minutes; losing it because the object was deleted meanwhile would be
        worse than storing it unattached."""
        cmd.fab(QUERY, 'binder')
        search_id = self.run_search(FakeServer(), target='binder')
        cmd.delete('binder')
        cmd.msa_status()
        self.assertEqual(cmd.msa_status(search_id)[search_id]['state'], 'done')
        alignment = store.get(cmd.msa_list()[0])
        self.assertEqual(alignment.target, '')

    def testAMarkerIsEmittedForTheAppToRead(self):
        """The app's progress row is driven by these, alongside PREDICT: and WEIGHTS:."""
        with captured_output() as out:
            self.run_search(FakeServer())
            markers = out.markers()
        self.assertTrue(markers, 'no MSA: marker was emitted')
        self.assertEqual(markers[-1]['state'], 'done')
        self.assertEqual(markers[-1]['server'], PRIVATE)
        for marker in markers:
            self.assertLess(len(searching.MARKER + json.dumps(marker)), 1024,
                            'marker would overflow the feedback line')


class MSASearchThreadingTest(MSASearchTestCase):
    """The rule the whole design exists for: the worker touches no session state."""

    def testTheWorkerCreatesNothingAndThePumpDoes(self):
        server = FakeServer()
        search_id = self.run_search(server)
        # The worker has finished -- join() returned -- and yet:
        self.assertEqual(store.names(), [],
                         'the search thread put an alignment in the store; the panel'
                         ' and the Metal renderer read it from the main thread')
        self.assertEqual(msa_module.pump(), 1)
        self.assertEqual(len(store.names()), 1)
        # Idempotent: the panel calls this every 500 ms.
        self.assertEqual(msa_module.pump(), 0)
        self.assertEqual(len(store.names()), 1)
        self.assertEqual(cmd.msa_status(search_id)[search_id]['state'], 'done')

    def testMsaSearchReturnsWhileTheSearchIsStillRunning(self):
        """A search is minutes, and the console runs on the main thread (#284)."""
        server = FakeServer(statuses=['RUNNING'])
        with patch('pymol.msas.colabfold._urlopen', server):
            search_id = cmd.msa_search(QUERY)
            self.assertTrue(server.polling.wait(5), 'the search never started')
            status = cmd.msa_status(search_id)[search_id]
            self.assertEqual(status['state'], 'running')
            self.assertEqual(store.names(), [])
            cmd.msa_cancel(search_id)


class MSASearchFailureTest(MSASearchTestCase):
    """A refusal must read as a refusal, and must name the host that refused."""

    def testRateLimitSurfacesAsAnErrorNamingTheServer(self):
        """The common case on the public server -- and it arrives as HTTP 429 with the
        status in the BODY, not as a job state, so it is easy to misreport as a
        transport failure."""
        colabfold.set_server(colabfold.PUBLIC_SERVER)
        server = FakeServer(submit_error=rate_limited())
        with captured_output() as out:
            search_id = self.run_search(server)
            cmd.msa_status()
        status = cmd.msa_status(search_id)[search_id]
        self.assertEqual(status['state'], 'error')
        self.assertIn('api.colabfold.com', status['error'])
        self.assertIn('rate-limit', status['error'])
        # Reported even though quiet=1: it is the only account of a search the user has
        # been waiting on.
        self.assertIn('api.colabfold.com', out.text())
        self.assertEqual(store.names(), [])

    def testAnErrorStateSurfacesAsAnErrorNamingTheServer(self):
        server = FakeServer(statuses=['RUNNING', 'ERROR'])
        search_id = self.run_search(server)
        cmd.msa_status()
        status = cmd.msa_status(search_id)[search_id]
        self.assertEqual(status['state'], 'error')
        self.assertIn('msa.internal.example', status['error'])
        self.assertEqual(server.downloads, 0)
        self.assertEqual(store.names(), [])

    def testMaintenanceSurfacesAsAnErrorNamingTheServer(self):
        server = FakeServer(statuses=['MAINTENANCE'])
        search_id = self.run_search(server)
        status = cmd.msa_status(search_id)[search_id]
        self.assertEqual(status['state'], 'error')
        self.assertIn('maintenance', status['error'])
        self.assertIn('msa.internal.example', status['error'])

    def testAnUnreachableServerSaysSoAndNamesIt(self):
        server = FakeServer(submit_error=IOError('no route to host'))
        search_id = self.run_search(server)
        status = cmd.msa_status(search_id)[search_id]
        self.assertEqual(status['state'], 'error')
        self.assertIn('msa.internal.example', status['error'])

    def testAServerThatIsNotAnMsaServerSaysSo(self):
        """Pointing msa_server at the wrong URL is a mistake worth naming."""
        class NotJson(FakeServer):
            def __call__(self, request, timeout=None):
                return FakeResponse(b'<html>hello</html>')
        search_id = self.run_search(NotJson())
        self.assertIn('JSON', cmd.msa_status(search_id)[search_id]['error'])

    def testAnEmptyResultIsAnErrorNotAnEmptyAlignment(self):
        search_id = self.run_search(FakeServer(tarball=make_tarball([])))
        cmd.msa_status()
        self.assertEqual(cmd.msa_status(search_id)[search_id]['state'], 'error')
        self.assertEqual(store.names(), [])


class MSASearchCancelTest(MSASearchTestCase):

    def testCancelMidPollLeavesNoHalfBuiltAlignment(self):
        server = FakeServer(statuses=['RUNNING'])
        with patch('pymol.msas.colabfold._urlopen', server):
            search_id = cmd.msa_search(QUERY)
            self.assertTrue(server.polling.wait(5), 'the search never started')
            self.assertEqual(cmd.msa_cancel(search_id, quiet=0), 1)
            # Reported as cancelled at once, without waiting for the worker to reach its
            # next poll -- otherwise the button looks dead.
            self.assertEqual(cmd.msa_status(search_id)[search_id]['state'], 'cancelled')
            searching.join(search_id, timeout=10)
        cmd.msa_status()
        self.assertEqual(store.names(), [])
        self.assertEqual(server.downloads, 0)

    def testCancelAllStopsEveryRunningSearch(self):
        server = FakeServer(statuses=['RUNNING'])
        with patch('pymol.msas.colabfold._urlopen', server):
            cmd.msa_search(QUERY)
            cmd.msa_search(QUERY + 'AAA')
            self.assertTrue(server.polling.wait(5))
            self.assertEqual(cmd.msa_cancel(), 2)
        self.assertEqual(store.names(), [])

    def testCancelIsHarmlessWhenNothingIsRunning(self):
        self.assertEqual(cmd.msa_cancel(), 0)

    def testCancellingAnUnknownSearchIsAnError(self):
        self.assertRaises(MSANotFound, cmd.msa_cancel, 'msa-nope')
        self.assertRaises(MSANotFound, cmd.msa_status, 'msa-nope')


class MSASearchCacheTest(MSASearchTestCase):
    """A search costs minutes; throwing the result away is what users notice first."""

    def testARepeatSearchHitsTheCache(self):
        first = FakeServer()
        self.run_search(first)
        cmd.msa_status()
        second = FakeServer()
        with patch('pymol.msas.colabfold._urlopen', second):
            search_id = cmd.msa_search(QUERY)
        self.assertEqual(second.submits, 0, 'searched again for a cached query')
        self.assertEqual(cmd.msa_status(search_id)[search_id]['cached'], True)
        # And it is a real alignment, not just a hit: both are in the store now.
        self.assertEqual(len(cmd.msa_list()), 2)
        self.assertEqual(store.get(cmd.msa_list()[1]).depth, MERGED_DEPTH)

    def testACachedSearchLandsBeforeTheCallReturns(self):
        """No pump needed for a hit: a script must be able to use it on the next line."""
        self.run_search(FakeServer())
        cmd.msa_status()
        cmd.msa_delete('all')
        with patch('pymol.msas.colabfold._urlopen', FakeServer()):
            cmd.msa_search(QUERY)
        self.assertEqual(len(cmd.msa_list()), 1)

    def testRefreshMissesTheCache(self):
        self.run_search(FakeServer())
        cmd.msa_status()
        again = FakeServer()
        self.run_search(again, refresh=1)
        self.assertEqual(again.submits, 1)

    def testADifferentServerIsADifferentCacheEntry(self):
        self.run_search(FakeServer())
        cmd.msa_status()
        other = FakeServer()
        self.run_search(other, server='https://elsewhere.example')
        self.assertEqual(other.submits, 1)

    def testADifferentModeIsADifferentCacheEntry(self):
        self.run_search(FakeServer())
        cmd.msa_status()
        other = FakeServer()
        self.run_search(other, mode='all')
        self.assertEqual(other.submits, 1)

    def testTheCacheIsKeyedOnTheNormalisedQuery(self):
        self.run_search(FakeServer())
        cmd.msa_status()
        again = FakeServer()
        with patch('pymol.msas.colabfold._urlopen', again):
            cmd.msa_search(QUERY.lower())
        self.assertEqual(again.submits, 0)

    def testAnUnreadableCacheEntryIsAMissNotAFailure(self):
        self.run_search(FakeServer())
        cmd.msa_status()
        key = searching.cache_key(QUERY, PRIVATE, 'env')
        with open(searching.cached_path(key, self.root), 'w') as handle:
            handle.write('# a comment and no sequences at all\n')
        again = FakeServer()
        self.run_search(again)
        self.assertEqual(again.submits, 1)


class MSAServerSettingTest(MSASearchTestCase):

    def testResolutionOrder(self):
        colabfold.set_server('')
        self.assertEqual(colabfold.resolve()[0], colabfold.PUBLIC_SERVER)
        os.environ[colabfold.SERVER_ENV] = 'https://from-env.example'
        self.assertEqual(colabfold.resolve()[0], 'https://from-env.example')
        cmd.msa_server(PRIVATE)
        self.assertEqual(colabfold.resolve()[0], PRIVATE)
        # The argument wins over everything, which is what per-search override means.
        self.assertEqual(colabfold.resolve('https://explicit.example')[0],
                         'https://explicit.example')
        os.environ.pop(colabfold.SERVER_ENV, None)

    def testMsaServerReportsAndSets(self):
        self.assertEqual(cmd.msa_server(quiet=0), PRIVATE)
        self.assertEqual(cmd.msa_server('https://other.example/', quiet=0),
                         'https://other.example')
        self.assertEqual(cmd.msa_server(), 'https://other.example')

    def testANonUrlIsRefused(self):
        self.assertRaises(MSAInputError, cmd.msa_server, 'not a url')
        self.assertRaises(MSAInputError, cmd.msa_server, 'ftp://nope.example')

    def testThePerSearchServerWins(self):
        server = FakeServer()
        self.run_search(server, server='https://elsewhere.example')
        cmd.msa_status()
        self.assertTrue(server.urls[0].startswith('https://elsewhere.example'))
        self.assertEqual(store.get(cmd.msa_list()[0]).source['server'],
                         'https://elsewhere.example')


class MSAPublicServerWarningTest(MSASearchTestCase):
    """RayMol's users fold unpublished designed binders. A search on the public server
    publishes the sequence, and that has to be said out loud."""

    def testTheFirstPublicSearchWarnsAndNamesTheHost(self):
        colabfold.set_server(colabfold.PUBLIC_SERVER)
        with captured_output() as out:
            # quiet=1 -- the Python API default, and the path a script looping over a
            # hundred designs takes. The warning is NOT progress reporting.
            self.run_search(FakeServer(), quiet=1)
            text = out.text()
        self.assertIn('api.colabfold.com', text)
        self.assertIn('LEAVES THIS MACHINE', text)

    def testItWarnsOnlyOncePerSession(self):
        colabfold.set_server(colabfold.PUBLIC_SERVER)
        self.run_search(FakeServer())
        cmd.msa_status()
        with captured_output() as out:
            self.run_search(FakeServer(), sequence=QUERY + 'AAA')
            text = out.text()
        self.assertNotIn('LEAVES THIS MACHINE', text)

    def testAPrivateServerDoesNotWarn(self):
        with captured_output() as out:
            self.run_search(FakeServer())
            text = out.text()
        self.assertNotIn('LEAVES THIS MACHINE', text)

    def testIsPublicKnowsTheDefault(self):
        self.assertTrue(colabfold.is_public(colabfold.PUBLIC_SERVER))
        self.assertTrue(colabfold.is_public('https://api.colabfold.com:443/x'))
        self.assertFalse(colabfold.is_public(PRIVATE))


class MSASearchInputTest(MSASearchTestCase):
    """What is refused before a single packet leaves."""

    def testAComplexIsRefused(self):
        """Per-chain unpaired alignments only: a query built by joining two chains
        describes a protein that does not exist."""
        with self.assertRaises(MSAInputError) as caught:
            cmd.msa_search(QUERY + '/' + QUERY)
        self.assertIn('ONE chain', str(caught.exception))

    def testAPairingModeIsRefusedByName(self):
        with self.assertRaises(MSAInputError) as caught:
            cmd.msa_search(QUERY, mode='pairgreedy')
        self.assertIn('PAIRED', str(caught.exception))

    def testAnUnknownModeIsRefused(self):
        self.assertRaises(MSAInputError, cmd.msa_search, QUERY, mode='everything')

    def testAQueryWithNonResidueLettersIsRefused(self):
        """A typo caught here costs nothing; the server would spend a minute on it.

        Note what this canNOT catch: ACGT are all valid residue letters, so a literal
        nucleotide sequence is indistinguishable from a peptide -- the same blind spot
        predicting.resolve_sequence documents.
        """
        with self.assertRaises(MSAInputError) as caught:
            cmd.msa_search('MKTAYIAKQJJJ')
        self.assertIn("'J'", str(caught.exception))

    def testAVeryShortQueryIsRefused(self):
        self.assertRaises(MSAInputError, cmd.msa_search, 'MKTAY')

    def testASelectionIsResolvedFromTheSession(self):
        cmd.fab(QUERY, 'binder')
        server = FakeServer()
        self.run_search(server, sequence='binder and resi 1-24')
        self.assertIn(QUERY, server.posted[0])

    def testTheCommandsAreRegisteredKeywords(self):
        for keyword in ('msa_search', 'msa_server', 'msa_status', 'msa_cancel'):
            self.assertIn(keyword, cmd.keyword)
