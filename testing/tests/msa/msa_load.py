"""Reading an alignment into a named object: cmd.load_msa and the store (#296).

No predictor, no network -- just the file, what the summary says about it, and the
checks that refuse an alignment before it can waste a prediction.

    pymol -ckqy testing/testing.py --run testing/tests/msa/msa_load.py
"""
import gzip
import os
import tempfile

from pymol import cmd, testing
from pymol.msa import default_name
from pymol.msas import parse, store
from pymol.msas.errors import MSAInputError, MSANameConflict, MSANotFound

#: The query of testing/data/msa_toy.a3m. Also what `fab` is handed, so that a target
#: object and the alignment genuinely agree.
QUERY = 'MKTAYIAKQRQISFVKSHFSRQLE'

#: What the fixture summarizes to: nine sequence lines, one of which repeats another.
TOY_DEPTH = 8
TOY_COLUMNS = 24
TOY_DUPLICATES = 1


class MSATestCase(testing.PyMOLTestCase):
    """Shared fixture plumbing. Holds no tests of its own."""

    def toy(self):
        return self.datafile('msa_toy.a3m')

    def write(self, text, suffix='.a3m'):
        """A temp file holding `text`, removed when the test ends."""
        handle, path = tempfile.mkstemp(suffix=suffix)
        with os.fdopen(handle, 'w') as out:
            out.write(text)
        self.addCleanup(os.unlink, path)
        return path


class MSAParseTest(MSATestCase):
    """The summary rules, which are boltz-mlx's rules."""

    def testDepthColumnsAndQuery(self):
        summary = parse.summarize(parse.read(self.toy()))
        self.assertEqual(summary['depth'], TOY_DEPTH)
        self.assertEqual(summary['columns'], TOY_COLUMNS)
        self.assertEqual(summary['query'], QUERY)

    def testDuplicateRowsAreDroppedBeforeDepthIsCounted(self):
        """Depth means depth AFTER dedup, because that is what the featurizer sees."""
        summary = parse.summarize(parse.read(self.toy()))
        self.assertEqual(summary['duplicates'], TOY_DUPLICATES)

    def testDedupIgnoresGapPlacement(self):
        """The dedup key strips gaps, so a row with the same residues in different
        columns collides with the query -- and is dropped before it can be found
        ragged, which is the order boltz-mlx uses too."""
        summary = parse.summarize('>q\nMKTAY\n>h\nMKTA-Y\n')
        self.assertEqual(summary['depth'], 1)
        self.assertEqual(summary['duplicates'], 1)

    def testLowercaseIsAnInsertionAndNotAColumn(self):
        summary = parse.summarize('>q\nMKTAY\n>h\nMKTaaaAY\n')
        self.assertEqual(summary['depth'], 2)
        self.assertEqual(summary['columns'], 5)

    def testDotIsAColumnNotAnInsertion(self):
        """HHsuite pads insert columns with '.'; the featurizer counts it as a column
        and folds it as an unknown residue."""
        summary = parse.summarize('>q\nMKTAY\n>h\nMK.AY\n')
        self.assertEqual(summary['columns'], 5)
        self.assertEqual(summary['dots'], 1)

    def testDotShiftingAColumnCountIsRefused(self):
        """The same '.' HHsuite means as padding makes this row one column too long."""
        self.assertRaises(MSAInputError, parse.summarize, '>q\nMKTAY\n>h\nMK.TAY\n')

    def testRaggedRowRefused(self):
        with self.assertRaises(MSAInputError) as caught:
            parse.summarize('>q\nMKTAY\n>h\nMKT\n')
        self.assertIn('row 2', str(caught.exception))

    def testCommentsAndBlankLinesIgnored(self):
        summary = parse.summarize('# a comment\n\n>q\nMKTAY\n\n# another\n>h\nMKTAF\n')
        self.assertEqual(summary['depth'], 2)

    def testNoSequencesRefused(self):
        self.assertRaises(MSAInputError, parse.summarize, '# nothing but a comment\n')

    def testUnreadableFileRefused(self):
        self.assertRaises(MSAInputError, parse.read, 'no_such_alignment.a3m')

    def testEmptyFileRefused(self):
        self.assertRaises(MSAInputError, parse.read, self.write('   \n\n'))

    def testBinaryFileRefused(self):
        path = self.write('', '.a3m')
        with open(path, 'wb') as out:
            out.write(b'\xff\xfe\x00\x01 not text at all \xff')
        self.assertRaises(MSAInputError, parse.read, path)


class MSALoadTest(MSATestCase):
    """cmd.load_msa itself."""

    def testLoadFromFile(self):
        name = cmd.load_msa(self.toy())
        self.assertEqual(name, 'msa_toy')
        self.assertEqual(store.names(), ['msa_toy'])
        msa = store.get(name)
        self.assertEqual(msa.depth, TOY_DEPTH)
        self.assertEqual(msa.columns, TOY_COLUMNS)
        self.assertEqual(msa.query, QUERY)
        self.assertEqual(msa.target, '')

    def testLoadFromFileNotQuiet(self):
        """The message-emitting branch. quiet=0 is what the command line always uses."""
        self.assertEqual(cmd.load_msa(self.toy(), quiet=0), 'msa_toy')

    def testStoredTextIsByteIdentical(self):
        """The featurizer reproduces upstream's parser bug for bug, so the bytes it
        eventually reads have to be the bytes that were loaded."""
        with open(self.toy(), 'rb') as handle:
            original = handle.read().decode('utf-8')
        cmd.load_msa(self.toy())
        self.assertEqual(store.get('msa_toy').a3m, original)

    def testGzippedAlignmentLoads(self):
        with open(self.toy(), 'rb') as handle:
            raw = handle.read()
        path = self.write('', '.a3m.gz')
        with gzip.open(path, 'wb') as out:
            out.write(raw)
        name = cmd.load_msa(path)
        self.assertEqual(store.get(name).a3m, raw.decode('utf-8'))
        self.assertEqual(store.get(name).depth, TOY_DEPTH)

    def testProvenanceIsRecorded(self):
        """Where an alignment came from is the only thing a .pse can still tell you."""
        cmd.load_msa(self.toy())
        source = store.get('msa_toy').source
        self.assertEqual(source['kind'], 'file')
        self.assertEqual(source['path'], os.path.abspath(self.toy()))

    # -- naming ----------------------------------------------------------------

    def testDefaultNameIsTheFileStem(self):
        path = self.write('>q\nMKTAY\n')
        self.assertEqual(cmd.load_msa(path),
                         default_name(os.path.basename(path)))

    def testSuffixesAreStripped(self):
        self.assertEqual(default_name('/tmp/barnase.a3m'), 'barnase')
        self.assertEqual(default_name('/tmp/barnase.a3m.gz'), 'barnase')
        self.assertEqual(default_name('/tmp/barnase.fasta'), 'barnase')
        self.assertEqual(default_name('/tmp/weird name,here.a3m'), 'weird_name_here')

    def testSecondLoadOfTheSameFileGetsAFreeName(self):
        self.assertEqual(cmd.load_msa(self.toy()), 'msa_toy')
        self.assertEqual(cmd.load_msa(self.toy()), 'msa_toy_2')
        self.assertEqual(cmd.load_msa(self.toy()), 'msa_toy_3')

    def testExplicitDuplicateNameRefused(self):
        """An alignment costs minutes to build; two files sharing a stem must not
        silently replace one."""
        cmd.load_msa(self.toy(), 'shared')
        self.assertRaises(MSANameConflict, cmd.load_msa, self.toy(), 'shared')

    def testUnaddressableNameRefused(self):
        """'/' will separate per-chain alignments in `predict ..., msa=a/b` (#297)."""
        self.assertRaises(MSAInputError, cmd.load_msa, self.toy(), 'has/slash')
        self.assertRaises(MSAInputError, cmd.load_msa, self.toy(), 'has,comma')
        self.assertRaises(MSAInputError, cmd.load_msa, self.toy(), 'has space')

    # -- attachment ------------------------------------------------------------

    def testAttachAtLoadTime(self):
        cmd.fab(QUERY, 'tgt')
        name = cmd.load_msa(self.toy(), target='tgt')
        msa = store.get(name)
        self.assertEqual(msa.target, 'tgt')
        # fab leaves the chain id blank, and it is the only chain, so that is the one.
        self.assertEqual(msa.chain, '')

    def testAttachToNamedChain(self):
        cmd.fab(QUERY, 'chA', chain='A')
        cmd.fab('GSHMAGSHMA', 'chB', chain='B')
        cmd.create('dimer', 'chA or chB')
        name = cmd.load_msa(self.toy(), target='dimer', chain='A')
        self.assertEqual(store.get(name).chain, 'A')

    def testMultiChainTargetNeedsAChain(self):
        """Guessing here is how an alignment ends up on the wrong half of a complex."""
        cmd.fab(QUERY, 'chA', chain='A')
        cmd.fab('GSHMAGSHMA', 'chB', chain='B')
        cmd.create('dimer', 'chA or chB')
        with self.assertRaises(MSAInputError) as caught:
            cmd.load_msa(self.toy(), target='dimer')
        self.assertIn('chain=', str(caught.exception))

    def testUnknownChainRefused(self):
        cmd.fab(QUERY, 'tgt', chain='A')
        self.assertRaises(MSAInputError, cmd.load_msa, self.toy(), '', 'tgt', 'Z')

    def testTargetWithNoProteinRefused(self):
        cmd.pseudoatom('blob')
        self.assertRaises(MSAInputError, cmd.load_msa, self.toy(), '', 'blob')

    def testLengthMismatchRefusedAndExplained(self):
        """The common cause is not a wrong file but a structure missing loops."""
        cmd.fab(QUERY[:-4], 'shorter')
        with self.assertRaises(MSAInputError) as caught:
            cmd.load_msa(self.toy(), target='shorter')
        message = str(caught.exception)
        self.assertIn('24 residues', message)
        self.assertIn('20', message)

    def testResidueMismatchNamesThePosition(self):
        cmd.fab('W' + QUERY[1:], 'mutant')
        with self.assertRaises(MSAInputError) as caught:
            cmd.load_msa(self.toy(), target='mutant')
        self.assertIn('residue 1', str(caught.exception))

    def testNothingIsStoredWhenTheTargetCheckFails(self):
        cmd.fab(QUERY[:-4], 'shorter')
        self.assertRaises(MSAInputError, cmd.load_msa, self.toy(), '', 'shorter')
        self.assertEqual(store.names(), [])


class MSAManagementTest(MSATestCase):
    """The verbs that stand in for delete / set_name on a store the Executive knows
    nothing about."""

    def testList(self):
        cmd.load_msa(self.toy(), 'first')
        cmd.load_msa(self.toy(), 'second')
        self.assertEqual(cmd.msa_list(), ['first', 'second'])
        self.assertEqual(cmd.msa_list(quiet=0), ['first', 'second'])

    def testListEmptyNotQuiet(self):
        self.assertEqual(cmd.msa_list(quiet=0), [])

    def testDelete(self):
        cmd.load_msa(self.toy(), 'gone')
        self.assertEqual(cmd.msa_delete('gone', quiet=0), 1)
        self.assertEqual(cmd.msa_list(), [])

    def testDeleteAll(self):
        cmd.load_msa(self.toy(), 'one')
        cmd.load_msa(self.toy(), 'two')
        self.assertEqual(cmd.msa_delete('all'), 2)
        self.assertEqual(cmd.msa_list(), [])

    def testDeleteUnknownRefused(self):
        self.assertRaises(MSANotFound, cmd.msa_delete, 'never_loaded')

    def testRenameKeepsListOrder(self):
        cmd.load_msa(self.toy(), 'a')
        cmd.load_msa(self.toy(), 'b')
        cmd.load_msa(self.toy(), 'c')
        self.assertEqual(cmd.msa_rename('b', 'z', quiet=0), 'z')
        self.assertEqual(cmd.msa_list(), ['a', 'z', 'c'])
        self.assertEqual(store.get('z').depth, TOY_DEPTH)

    def testRenameOntoATakenNameRefused(self):
        cmd.load_msa(self.toy(), 'a')
        cmd.load_msa(self.toy(), 'b')
        self.assertRaises(MSANameConflict, cmd.msa_rename, 'a', 'b')

    def testAttachAndDetach(self):
        cmd.fab(QUERY, 'tgt', chain='A')
        cmd.load_msa(self.toy(), 'aln')
        self.assertEqual(cmd.msa_attach('aln', 'tgt', 'A', quiet=0), 'aln')
        self.assertEqual(store.get('aln').target, 'tgt')
        self.assertEqual(cmd.msa_detach('aln', quiet=0), 'aln')
        self.assertEqual(store.get('aln').target, '')
        self.assertEqual(store.get('aln').chain, '')

    def testAttachChecksTheSequence(self):
        cmd.fab('GSHMAGSHMA', 'wrong', chain='A')
        cmd.load_msa(self.toy(), 'aln')
        self.assertRaises(MSAInputError, cmd.msa_attach, 'aln', 'wrong', 'A')
        self.assertEqual(store.get('aln').target, '')
