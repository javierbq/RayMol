"""Analysis Notes ride in the .pse; a partial restore leaves the live ones alone (#658).

    pymol -ckqy testing/testing.py --run testing/tests/raymol/notes_session.py
"""
import os
import tempfile

from pymol import cmd, raymol_notes, testing


class NotesSessionTest(testing.PyMOLTestCase):

    def setUp(self):
        testing.PyMOLTestCase.setUp(self)
        raymol_notes.clear()
        self.addCleanup(raymol_notes.clear)

    def pse(self):
        handle, path = tempfile.mkstemp(suffix='.pse')
        os.close(handle)
        self.addCleanup(lambda: os.path.exists(path) and os.unlink(path))
        return path

    def stage(self, text):
        raymol_notes._payload = {'version': 1, 'markdown': text,
                                 'document': {'version': 1, 'text': text},
                                 'assets': {}}

    def testFullRestoreReplacesTheNotes(self):
        self.stage('saved')
        saved = self.pse()
        cmd.save(saved)
        self.stage('live')
        cmd.load(saved)
        self.assertEqual(raymol_notes._payload['markdown'], 'saved')

    def testFullRestoreOfASessionWithoutNotesClearsThem(self):
        empty = self.pse()
        cmd.save(empty)
        self.stage('live')
        cmd.load(empty)
        self.assertIsNone(raymol_notes._payload)

    def testPartialRestoreLeavesTheNotesAlone(self):
        empty = self.pse()
        cmd.save(empty)
        self.stage('saved')
        other = self.pse()
        cmd.save(other)
        self.stage('live')
        for path in (empty, other):
            cmd.load(path, partial=1)
            self.assertEqual(raymol_notes._payload['markdown'], 'live')
