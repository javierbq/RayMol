"""What happens to an alignment when the session changes, and what the panel sees (#296).

Covers the .pse round trip, the two ways a store must be emptied (a session that
carries no alignments, and `reinitialize`), and the object-panel payload.

    pymol -ckqy testing/testing.py --run testing/tests/msa/msa_session.py
"""
import json
import os
import tempfile

from pymol import appkit_inspector as ai
from pymol import cmd, testing
from pymol.msas import store

QUERY = 'MKTAYIAKQRQISFVKSHFSRQLE'

PANEL_JSON = os.path.join(
    tempfile.gettempdir(), 'pymol_objpanel_%d.json' % os.getpid())


class MSASessionTestCase(testing.PyMOLTestCase):
    """Shared fixture plumbing. Holds no tests of its own."""

    def toy(self):
        return self.datafile('msa_toy.a3m')

    def pse(self):
        handle, path = tempfile.mkstemp(suffix='.pse')
        os.close(handle)
        self.addCleanup(lambda: os.path.exists(path) and os.unlink(path))
        return path


class MSASessionTest(MSASessionTestCase):

    def testRoundTrip(self):
        cmd.fab(QUERY, 'tgt', chain='A')
        cmd.load_msa(self.toy(), 'aln', 'tgt', 'A')
        original = store.get('aln').a3m
        path = self.pse()
        cmd.save(path)

        cmd.reinitialize()
        self.assertEqual(store.names(), [])

        cmd.load(path)
        self.assertEqual(store.names(), ['aln'])
        restored = store.get('aln')
        # The bytes matter more than anything else here: the featurizer reproduces
        # upstream's parser bug for bug, so an alignment that survives a session save
        # in a "cleaned up" form is a different alignment.
        self.assertEqual(restored.a3m, original)
        self.assertEqual(restored.query, QUERY)
        self.assertEqual(restored.depth, 8)
        self.assertEqual(restored.columns, 24)
        self.assertEqual(restored.target, 'tgt')
        self.assertEqual(restored.chain, 'A')
        self.assertEqual(restored.source['kind'], 'file')

    def testLoadOrderSurvives(self):
        cmd.load_msa(self.toy(), 'first')
        cmd.load_msa(self.toy(), 'second')
        cmd.load_msa(self.toy(), 'third')
        path = self.pse()
        cmd.save(path)
        cmd.reinitialize()
        cmd.load(path)
        self.assertEqual(store.names(), ['first', 'second', 'third'])

    def testSessionWithoutAlignmentsEmptiesTheStore(self):
        """Opening a session with no alignments must not leave the previous
        session's lying around, attached to objects that are gone."""
        empty = self.pse()
        cmd.save(empty)
        cmd.load_msa(self.toy(), 'aln')
        self.assertEqual(store.names(), ['aln'])
        cmd.load(empty)
        self.assertEqual(store.names(), [])

    def testKeyIsAbsentWhenNothingIsLoaded(self):
        """A user who never touched an alignment gets the .pse they always got."""
        self.assertNotIn(store.SESSION_KEY, cmd.get_session())

    def testReinitializeClearsTheStore(self):
        """The C reinitialize cannot see a Python-side store, so without the hook the
        alignments outlive the objects they are attached to."""
        cmd.load_msa(self.toy(), 'aln')
        cmd.reinitialize()
        self.assertEqual(store.names(), [])

    def testReinitializeOfSettingsOnlyKeepsAlignments(self):
        cmd.load_msa(self.toy(), 'aln')
        cmd.reinitialize('settings')
        self.assertEqual(store.names(), ['aln'])

    def testTheAlignmentIsCompressedInTheSession(self):
        """A depth-6628 alignment is ~1.3 MB of text and boltz-mlx admits 16384 rows;
        stored raw, a couple of those would dominate the .pse."""
        cmd.load_msa(self.toy(), 'aln')
        session = {}
        store.session_save(session)
        blob = session[store.SESSION_KEY]['alignments'][0]['a3m_gz_b64']
        self.assertLess(len(blob), len(store.get('aln').a3m))

    def testAMalformedEntryIsSkippedRatherThanRaised(self):
        """A restore task that throws takes the whole session load with it."""
        session = {store.SESSION_KEY: {'version': 1, 'alignments': [
            {'name': 'broken', 'a3m_gz_b64': 'not base64 at all!!'},
            None,
        ]}}
        self.assertTrue(store.session_restore(session))
        self.assertEqual(store.names(), [])

    def testANewerFormatIsDeclinedRatherThanGuessedAt(self):
        session = {store.SESSION_KEY: {
            'version': store.SESSION_VERSION + 1, 'alignments': [{'name': 'x'}]}}
        self.assertTrue(store.session_restore(session))
        self.assertEqual(store.names(), [])

    def testANonDictPayloadIsIgnored(self):
        self.assertTrue(store.session_restore({store.SESSION_KEY: 'nonsense'}))
        self.assertEqual(store.names(), [])


class MSAPanelPayloadTest(MSASessionTestCase):
    """What the object panel is told. Both panels read this one payload."""

    def payload(self):
        ai.poll_panel()
        with open(PANEL_JSON) as handle:
            return json.load(handle)

    def testAlignmentsAppearInThePayload(self):
        cmd.fab(QUERY, 'tgt', chain='A')
        cmd.load_msa(self.toy(), 'aln', 'tgt', 'A')
        entry = self.payload()['alignments']['aln']
        self.assertEqual(entry['depth'], 8)
        self.assertEqual(entry['columns'], 24)
        self.assertEqual(entry['residues'], len(QUERY))
        self.assertEqual(entry['target'], 'tgt')
        self.assertEqual(entry['chain'], 'A')

    def testKeyIsPresentAndEmptyWithNoAlignments(self):
        """Present unconditionally: a missing key would make the panel keep whatever
        it drew last."""
        self.assertEqual(self.payload()['alignments'], {})

    def testAnAlignmentIsNotAnObject(self):
        cmd.load_msa(self.toy(), 'aln')
        payload = self.payload()
        self.assertNotIn('aln', payload['objects'])
        self.assertNotIn('aln', payload['selections'])

    def testNoAlignmentBytesReachThePanel(self):
        """The payload is written every 500 ms on the main thread. An alignment is
        megabytes; only the scalars computed at load time may travel."""
        cmd.load_msa(self.toy(), 'aln')
        ai.poll_panel()
        with open(PANEL_JSON) as handle:
            text = handle.read()
        self.assertNotIn(QUERY, text)
        self.assertLess(len(text), 1024)

    def testAFailingStoreCannotFreezeThePanel(self):
        """poll_panel's single `except` writes no file at all, so anything that
        throws in here would leave the panel on a stale list forever."""
        original = store.panel_summary
        store.panel_summary = lambda: (_ for _ in ()).throw(RuntimeError('boom'))
        try:
            self.assertEqual(ai._alignment_map(), {})
            self.assertIn('alignments', self.payload())
        finally:
            store.panel_summary = original
