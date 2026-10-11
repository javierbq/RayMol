'''
Testing: the `fasta` command (issue #355) -- print a selection's sequence to
the console, defaulting to the enabled objects, one record per chain.

Runs on a RayMol --testing build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/fasta_command.py
'''

import contextlib
import io

from pymol import cmd, testing


def run_fasta(*args, **kwargs):
    '''Call cmd.fasta, returning (stdout text, return value).'''
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        ret = cmd.fasta(*args, **kwargs)
    return buf.getvalue(), ret


class TestFastaCommand(testing.PyMOLTestCase):

    def two_chains(self, name='dimer'):
        '''One object with chain A = ACDE and chain B = GHIK.'''
        cmd.fab('ACDE', name)
        cmd.alter(name, 'chain="A"')
        cmd.fab('GHIK', name + '_b')
        cmd.alter(name + '_b', 'chain="B"')
        cmd.create(name, name + ' or ' + name + '_b')
        cmd.delete(name + '_b')

    def testPrintsFasta(self):
        cmd.fab('ACDEFGHIK', 'one')
        out, ret = run_fasta('one')
        self.assertEqual(out, '>one_\nACDEFGHIK\n')
        self.assertEqual(ret, cmd.get_fastastr('one'))

    def testSplitsPerChainByDefault(self):
        self.two_chains()
        out, _ = run_fasta('dimer')
        self.assertEqual(out.splitlines(),
                         ['>dimer_A', 'ACDE', '>dimer_B', 'GHIK'])

    def testChainsOffJoinsPerObject(self):
        self.two_chains()
        out, _ = run_fasta('dimer', chains=0)
        self.assertEqual(out.splitlines(), ['>dimer', 'ACDEGHIK'])

    def testChainsAcceptsStrings(self):
        # what the command-line parser passes
        self.two_chains()
        out, _ = run_fasta('dimer', -1, '0')
        self.assertEqual(out.splitlines(), ['>dimer', 'ACDEGHIK'])

    def testSelectionNarrowsToOneChain(self):
        self.two_chains()
        out, _ = run_fasta('dimer and chain B')
        self.assertEqual(out.splitlines(), ['>dimer_B', 'GHIK'])

    def testDefaultsToEnabledObjects(self):
        cmd.fab('ACDE', 'shown')
        cmd.fab('GHIK', 'off')
        cmd.disable('off')
        out, _ = run_fasta()
        self.assertEqual(out.splitlines(), ['>shown_', 'ACDE'])

    def testDefaultSkipsHiddenObjects(self):
        cmd.fab('ACDE', 'shown')
        cmd.fab('GG', '_internal')
        out, _ = run_fasta()
        self.assertEqual(out.splitlines(), ['>shown_', 'ACDE'])

    def testExplicitSelectionIgnoresEnabled(self):
        cmd.fab('GHIK', 'off')
        cmd.disable('off')
        out, _ = run_fasta('off')
        self.assertEqual(out.splitlines(), ['>off_', 'GHIK'])

    def testLongSequenceWraps(self):
        cmd.fab('A' * 100, 'long')
        out, _ = run_fasta('long')
        self.assertEqual(out.splitlines(), ['>long_', 'A' * 70, 'A' * 30])

    def testNoSequence(self):
        out, ret = run_fasta()
        self.assertIn('no sequence', out)
        self.assertEqual(ret, '')

    def testQuietSuppressesPrint(self):
        cmd.fab('ACDE', 'one')
        out, ret = run_fasta('one', quiet=1)
        self.assertEqual(out, '')
        self.assertEqual(ret, '>one_\nACDE\n')

    def testReachableFromCommandLine(self):
        cmd.fab('ACDE', 'one')
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            cmd.do('fasta one, chains=0')
        self.assertEqual(buf.getvalue(), '>one\nACDE\n')
