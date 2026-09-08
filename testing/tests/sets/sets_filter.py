"""The filter expression compiler: grammar, types, offsets, and what SQLite does with it (#415).

    pymol -ckqy testing/testing.py --run testing/tests/sets/sets_filter.py
"""
import sqlite3

from pymol import testing
from pymol.sets import filter as setfilter
from pymol.sets.filter import (compile, parse, validate, columns_used,
                               Or, And, Not, Cmp, In, IsNull, Flag, Column, Value)
from pymol.sets.errors import SetFilterError

COLUMNS = {
    'plddt': 'float',
    'rmsd': 'float',
    'n_contacts': 'int',
    'tool': 'str',
    'passed': 'bool',
    'plddt__b': 'float',
}


class SetFilterTestCase(testing.PyMOLTestCase):

    def compile(self, expr, columns=COLUMNS):
        return compile(expr, columns)

    def assertFails(self, expr, offset, columns=COLUMNS, fragment=None):
        try:
            compile(expr, columns)
        except SetFilterError as e:
            self.assertEqual(e.offset, offset,
                             '%r: offset %r != %r (%s)' % (expr, e.offset, offset, e))
            self.assertIn('offset %d' % offset, str(e))
            if fragment:
                self.assertIn(fragment, str(e))
            return e
        self.fail('%r compiled without error' % expr)


class ProductionTest(SetFilterTestCase):

    def testEmptyIsNoFilter(self):
        self.assertEqual(self.compile(''), ('', ()))
        self.assertEqual(self.compile('   \t\n'), ('', ()))
        self.assertEqual(self.compile(None), ('', ()))

    def testComparisonOps(self):
        for op in ('<', '<=', '>', '>=', '=', '!='):
            sql, params = self.compile('plddt %s 80' % op)
            self.assertEqual(sql, 'm."plddt" %s ?' % op)
            self.assertEqual(params, (80,))

    def testChainColumn(self):
        self.assertEqual(self.compile('plddt__b >= 70'), ('m."plddt__b" >= ?', (70,)))

    def testInList(self):
        sql, params = self.compile('tool in ("boltz", "af3", "chai")')
        self.assertEqual(sql, 'm."tool" IN (?, ?, ?)')
        self.assertEqual(params, ('boltz', 'af3', 'chai'))
        self.assertEqual(self.compile('n_contacts in (1)'), ('m."n_contacts" IN (?)', (1,)))

    def testIsNull(self):
        self.assertEqual(self.compile('plddt is null'), ('m."plddt" IS NULL', ()))
        self.assertEqual(self.compile('plddt is not null'), ('m."plddt" IS NOT NULL', ()))

    def testTagsContains(self):
        sql, params = self.compile('tags contains "lead"')
        self.assertEqual(sql, "(' ' || e.\"tags\" || ' ') LIKE ? ESCAPE '\\'")
        self.assertEqual(params, ('% lead %',))

    def testTagsContainsEscapesWildcards(self):
        # A tag with LIKE metacharacters must match itself, not act as a pattern.
        sql, params = self.compile('tags contains "100%_done\\\\x"')
        self.assertEqual(params, ('% 100\\%\\_done\\\\x %',))
        self.assertIn("ESCAPE '\\'", sql)

    def testNameLikeEqualsNotEquals(self):
        self.assertEqual(self.compile('name like "design_%"'), ('e."name" LIKE ?', ('design_%',)))
        self.assertEqual(self.compile('name = "d1"'), ('e."name" = ?', ('d1',)))
        self.assertEqual(self.compile('name != "d1"'), ('e."name" != ?', ('d1',)))

    def testFlags(self):
        self.assertEqual(self.compile('starred'), ('e."starred" = 1', ()))
        self.assertEqual(self.compile('rejected'), ('e."rejected" = 1', ()))
        self.assertEqual(self.compile('pinned'), ('e."pinned" = 1', ()))
        self.assertEqual(self.compile('staged'), ('e."staged_object" IS NOT NULL', ()))

    def testNegatedFlags(self):
        self.assertEqual(self.compile('not starred'), ('NOT e."starred" = 1', ()))
        self.assertEqual(self.compile('not rejected'), ('NOT e."rejected" = 1', ()))
        self.assertEqual(self.compile('not pinned'), ('NOT e."pinned" = 1', ()))
        self.assertEqual(self.compile('not staged'), ('NOT e."staged_object" IS NOT NULL', ()))

    def testFlagsWorkWithoutAnyMetricColumns(self):
        self.assertEqual(self.compile('starred and not rejected', {}),
                         ('(e."starred" = 1 AND NOT e."rejected" = 1)', ()))

    def testBooleans(self):
        self.assertEqual(self.compile('passed = true'), ('m."passed" = ?', (1,)))
        self.assertEqual(self.compile('passed != false'), ('m."passed" != ?', (0,)))
        self.assertEqual(self.compile('passed = 1'), ('m."passed" = ?', (1,)))
        self.assertEqual(self.compile('passed in (0, 1)'), ('m."passed" IN (?, ?)', (0, 1)))
        # true/false are accepted against numeric columns and bind 1/0
        self.assertEqual(self.compile('n_contacts > false'), ('m."n_contacts" > ?', (0,)))


class LexicalTest(SetFilterTestCase):

    def testNumbers(self):
        cases = [
            ('plddt > 80', 80), ('plddt > -3', -3), ('plddt > +3', 3),
            ('plddt > 1.5', 1.5), ('plddt > .5', 0.5), ('plddt > -.5', -0.5),
            ('plddt > 1e3', 1000.0), ('plddt > 2.5E-1', 0.25), ('plddt > -1e+2', -100.0),
        ]
        for expr, expected in cases:
            sql, params = self.compile(expr)
            self.assertEqual(sql, 'm."plddt" > ?')
            self.assertEqual(params, (expected,), expr)
            self.assertIs(type(params[0]), type(expected), expr)

    def testNoSpaceBeforeNegativeNumber(self):
        self.assertEqual(self.compile('plddt>-1'), ('m."plddt" > ?', (-1,)))

    def testStringQuoteStyles(self):
        self.assertEqual(self.compile('tool = "boltz"')[1], ('boltz',))
        self.assertEqual(self.compile("tool = 'boltz'")[1], ('boltz',))

    def testStringEscapes(self):
        self.assertEqual(self.compile(r'tool = "a\"b"')[1], ('a"b',))
        self.assertEqual(self.compile(r"tool = 'a\'b'")[1], ("a'b",))
        self.assertEqual(self.compile(r'tool = "a\\b"')[1], ('a\\b',))
        # the other quote needs no escaping inside a string
        self.assertEqual(self.compile('''tool = "it's"''')[1], ("it's",))
        self.assertEqual(self.compile("""tool = 'say "hi"'""")[1], ('say "hi"',))
        # an unknown backslash sequence is kept verbatim
        self.assertEqual(self.compile(r'tool = "a\nb"')[1], ('a\\nb',))

    def testKeywordsAreCaseInsensitive(self):
        sql, params = self.compile('plddt > 1 AND (NOT passed = TRUE OR tool IN ("x")) '
                                   'Or plddt Is Not NULL or tags Contains "a" or name LIKE "b"')
        self.assertEqual(sql, '((((m."plddt" > ? AND (NOT m."passed" = ? OR m."tool" IN (?))) '
                              'OR m."plddt" IS NOT NULL) '
                              'OR (\' \' || e."tags" || \' \') LIKE ? ESCAPE \'\\\') '
                              'OR e."name" LIKE ?)')
        self.assertEqual(params, (1, 1, 'x', '% a %', 'b'))
        self.assertEqual(self.compile('passed = False'), ('m."passed" = ?', (0,)))

    def testColumnNamesAreCaseSensitive(self):
        # Metric columns, name, tags and the flags are all column tokens of the grammar
        # ([a-z][a-z0-9_]*); only the operator words are case-insensitive.
        self.assertFails('PLDDT > 1', 0)
        self.assertFails('Plddt > 1', 0)
        self.assertFails('STARRED', 0)
        self.assertFails('TAGS contains "a"', 0)
        self.assertFails('Name = "a"', 0)

    def testWhitespaceIsFree(self):
        self.assertEqual(self.compile('\n plddt\t>\n80 \n'), ('m."plddt" > ?', (80,)))
        self.assertEqual(self.compile('plddt>80'), ('m."plddt" > ?', (80,)))


class PrecedenceTest(SetFilterTestCase):

    def testAndBindsTighterThanOr(self):
        ast = parse('plddt > 1 or rmsd > 2 and n_contacts > 3')
        self.assertIsInstance(ast, Or)
        self.assertIsInstance(ast.right, And)
        self.assertEqual(ast.left.column.name, 'plddt')
        self.assertEqual(ast.right.left.column.name, 'rmsd')
        self.assertEqual(ast.right.right.column.name, 'n_contacts')
        sql, params = self.compile('plddt > 1 or rmsd > 2 and n_contacts > 3')
        self.assertEqual(sql, '(m."plddt" > ? OR (m."rmsd" > ? AND m."n_contacts" > ?))')
        self.assertEqual(params, (1, 2, 3))

    def testNotBindsTighterThanAnd(self):
        ast = parse('not plddt > 1 and rmsd > 2')
        self.assertIsInstance(ast, And)
        self.assertIsInstance(ast.left, Not)
        self.assertIsInstance(ast.left.operand, Cmp)
        sql, params = self.compile('not plddt > 1 and rmsd > 2')
        self.assertEqual(sql, '(NOT m."plddt" > ? AND m."rmsd" > ?)')

    def testParenthesesOverride(self):
        sql, params = self.compile('(plddt > 1 or rmsd > 2) and n_contacts > 3')
        self.assertEqual(sql, '((m."plddt" > ? OR m."rmsd" > ?) AND m."n_contacts" > ?)')
        sql, params = self.compile('not (plddt > 1 and rmsd > 2)')
        self.assertEqual(sql, 'NOT (m."plddt" > ? AND m."rmsd" > ?)')
        self.assertEqual(self.compile('((plddt > 1))'), ('m."plddt" > ?', (1,)))

    def testChainsAreLeftAssociative(self):
        ast = parse('plddt > 1 and rmsd > 2 and n_contacts > 3')
        self.assertIsInstance(ast.left, And)
        self.assertIsInstance(ast.right, Cmp)

    def testDoubleNot(self):
        self.assertEqual(self.compile('not not starred'), ('NOT NOT e."starred" = 1', ()))


class AstTest(SetFilterTestCase):

    def testNodesCarryOffsets(self):
        ast = parse('plddt >= 80.5')
        self.assertEqual(ast, Cmp(Column('plddt', 0), '>=', 6, Value('number', 80.5, 9)))
        self.assertEqual(parse('starred'), Flag('starred', 0))
        self.assertEqual(parse('tool in ("a", "b")'),
                         In(Column('tool', 0), (Value('string', 'a', 9), Value('string', 'b', 14))))
        self.assertEqual(parse('rmsd is not null'), IsNull(Column('rmsd', 0), True))
        self.assertEqual(parse('passed = true'),
                         Cmp(Column('passed', 0), '=', 7, Value('bool', True, 9)))

    def testParseDoesNotNeedColumns(self):
        # Syntax and semantics are separate stages: parse accepts an undeclared column
        # and validate is what refuses it.
        ast = parse('nosuch > 1')
        self.assertRaises(SetFilterError, validate, ast, COLUMNS)
        validate(ast, {'nosuch': 'int'})

    def testParseRejectsEmpty(self):
        self.assertRaises(SetFilterError, parse, '')
        self.assertRaises(SetFilterError, parse, '   ')

    def testNodesAreImmutable(self):
        ast = parse('starred')
        with self.assertRaises(AttributeError):
            ast.name = 'rejected'

    def testColumnsUsed(self):
        ast = parse('plddt > 1 and (rmsd is null or tool in ("a")) and not plddt__b < 2 '
                    'and starred and tags contains "x" and name like "y"')
        self.assertEqual(columns_used(ast), {'plddt', 'rmsd', 'tool', 'plddt__b'})
        self.assertEqual(columns_used(parse('starred')), set())
        self.assertEqual(columns_used(parse('name = "a"')), set())


class ErrorTest(SetFilterTestCase):

    HOSTILE = [
        # expression, offset, message fragment
        ('plddt > 80; DROP TABLE entries', 10, "unexpected character ';'"),
        ('plddt > 80 --', 11, "unexpected character '-'"),
        ('"plddt" > 80', 0, 'string'),
        ('plddt >', 7, 'end of input'),
        ('plddt > "80"', 8, 'float'),
        ('nosuch > 1', 0, "unknown column 'nosuch'"),
        ('(plddt > 1', 10, "')'"),
        ('plddt > 1)', 9, 'after the end'),
        ('plddt like "x"', 6, "'like' is only valid on name"),
        ('tags contains 5', 14, 'needs a string'),
        ('plddt > "abc', 8, 'unterminated string'),
        ("plddt > 'abc\\'", 8, 'unterminated string'),
        ('plddt > 80 and', 14, 'end of input'),
        ('and plddt > 80', 0, "keyword 'and'"),
        ('plddt', 5, 'operator'),
        ('plddt and rmsd', 6, 'operator'),
        ('plddt in ()', 10, 'a value'),
        ('plddt in (1, )', 13, 'a value'),
        ('plddt in 1', 9, "'('"),
        ('plddt is 5', 9, "'null'"),
        ('plddt is not 5', 13, "'null'"),
        ('plddt = null', 8, 'a value'),
        ('plddt == 1', 7, "unexpected character '='"),
        ('plddt ! 1', 6, "unexpected character '!'"),
        ('plddt > 80abc', 8, 'malformed number'),
        ('plddt > 1e', 8, 'malformed number'),
        ('plddt > 1 rmsd > 2', 10, 'after the end'),
        ('plddt > 1 and (rmsd > 2', 23, "')'"),
        ('plddt > 1 and rmsd > 2)', 22, 'after the end'),
        ('plddt > 1 or', 12, 'end of input'),
        ('not', 3, 'a column'),
        ('()', 1, 'a column'),
        ('plddt > 1 and and rmsd > 2', 14, "keyword 'and'"),
        ('plddt > 1 and nosuch > 2', 14, "unknown column 'nosuch'"),
        ('nosuch is null', 0, "unknown column 'nosuch'"),
        ('nosuch in (1)', 0, "unknown column 'nosuch'"),
        ('rmsd contains "x"', 5, "'contains' is only valid on tags"),
        ('tags = "x"', 5, "tags only supports 'contains'"),
        ('tags is null', 0, "'is null' is not valid on tags"),
        ('tags in ("a")', 0, "'in' is not valid on tags"),
        ('name > "x"', 5, 'name only supports like, = and !='),
        ('name = 5', 7, 'name needs a string'),
        ('name is null', 0, "'is null' is not valid on name"),
        ('name in ("a")', 0, "'in' is not valid on name"),
        ('tool < "a"', 5, 'only = and != apply'),
        ('tool = 5', 7, 'string'),
        ('tool in ("a", 5)', 14, 'string'),
        ('passed = 2', 9, 'boolean'),
        ('passed = "yes"', 9, 'boolean'),
        ('n_contacts = "3"', 13, 'int'),
        ('plddt > 1 and rmsd > "x"', 21, 'float'),
        ('starred = 1', 8, 'after the end'),
        ('plddt > 1 # comment', 10, "unexpected character '#'"),
        ('plddt > 1 /* x */', 10, "unexpected character '/'"),
        ('plddt > 1 and rmsd > (2)', 21, 'a value'),
        ('plddt > 1 and rmsd > 2 and 3', 27, 'a column'),
        ('plddt > `1`', 8, "unexpected character '`'"),
        ('plddt > 1 and $x', 14, "unexpected character '$'"),
        ('_x > 1', 0, 'invalid column name'),
        ('plddt > 1 and Rmsd > 2', 14, "invalid column name 'Rmsd'"),
        ('tags contains ""', 14, 'non-empty tag'),
    ]

    def testHostileInputs(self):
        for expr, offset, fragment in self.HOSTILE:
            self.assertFails(expr, offset, fragment=fragment)

    def testErrorsAreSetFilterErrors(self):
        # SetFilterError is a CmdException, so the command layer reports it normally;
        # the offset rides along for a UI to point at the token.
        import pymol
        for expr, offset, _ in self.HOSTILE:
            with self.assertRaises(pymol.CmdException) as cm:
                compile(expr, COLUMNS)
            self.assertEqual(cm.exception.offset, offset)

    def testUnicodeIdentifierIsRejected(self):
        # str.isalpha would let this through as a word; the column charset does not.
        self.assertFails('plädt > 1', 0, fragment='invalid column name')

    def testReservedNamesShadowMetricColumns(self):
        # A set that declares a metric called 'name' or 'starred' does not change what
        # the words mean in a filter: the entries table wins, by design.
        cols = {'name': 'str', 'starred': 'int', 'tags': 'str'}
        self.assertEqual(compile('name = "a"', cols), ('e."name" = ?', ('a',)))
        self.assertEqual(compile('starred', cols), ('e."starred" = 1', ()))
        self.assertEqual(compile('tags contains "a"', cols)[1], ('% a %',))

    def testUnknownDtypeIsAProgrammingError(self):
        self.assertRaises(ValueError, compile, 'plddt > 1', {'plddt': 'complex'})


class SqliteTest(SetFilterTestCase):
    """The compiled fragment, run against the two tables it targets."""

    ROWS = [
        # name,   tags,             starred, rejected, pinned, staged, plddt, rmsd, tool
        ('d1',    'lead',           1, 0, 1, 'd1',  92.5,  0.8,  'boltz'),
        ('d2',    'lead 100%',      0, 0, 0, None,  85.0,  1.2,  'boltz'),
        ('d3',    '',               0, 1, 0, None,  60.0,  3.5,  'af3'),
        ('d4',    'weird_tag',      0, 0, 0, 'd4',  None,  None, 'af3'),
        ('d5',    'leader',         1, 0, 0, None,  78.0,  None, None),
        ('d6',    'a b',            0, 0, 0, None,  None,  2.0,  'chai'),
        ('x_7',   'lead b',         0, 1, 1, 'x_7', 70.0,  1.5,  'chai'),
        ('d8',    "it's",           0, 0, 0, None,  80.0,  0.0,  'boltz'),
    ]
    METRIC_COLUMNS = {'plddt': 'float', 'rmsd': 'float', 'tool': 'str'}

    def setUp(self):
        SetFilterTestCase.setUp(self)
        self.db = sqlite3.connect(':memory:')
        self.db.executescript('''
            CREATE TABLE entries (id TEXT PRIMARY KEY, name TEXT NOT NULL,
                tags TEXT NOT NULL DEFAULT '', starred INTEGER NOT NULL DEFAULT 0,
                rejected INTEGER NOT NULL DEFAULT 0, pinned INTEGER NOT NULL DEFAULT 0,
                staged_object TEXT);
            CREATE TABLE m_x (entry_id TEXT PRIMARY KEY REFERENCES entries(id),
                plddt REAL, rmsd REAL, tool TEXT);
        ''')
        for i, row in enumerate(self.ROWS):
            name, tags, starred, rejected, pinned, staged, plddt, rmsd, tool = row
            eid = 'e%d' % i
            self.db.execute('INSERT INTO entries VALUES (?,?,?,?,?,?,?)',
                            (eid, name, tags, starred, rejected, pinned, staged))
            if name != 'd5':   # one entry with no metrics row at all (LEFT JOIN -> NULLs)
                self.db.execute('INSERT INTO m_x VALUES (?,?,?,?)', (eid, plddt, rmsd, tool))
        # d5 has a plddt in ROWS for readability, but no row in m_x: everything is NULL
        self.db.commit()

    def tearDown(self):
        self.db.close()
        SetFilterTestCase.tearDown(self)

    def names(self, expr):
        sql, params = compile(expr, self.METRIC_COLUMNS)
        query = 'SELECT e.name FROM entries e LEFT JOIN m_x m ON m.entry_id = e.id'
        if sql:
            query += ' WHERE ' + sql
        query += ' ORDER BY e.rowid'
        return [r[0] for r in self.db.execute(query, params)]

    def testEmptyFilterReturnsEverything(self):
        self.assertEqual(self.names(''), [r[0] for r in self.ROWS])

    def testExpressions(self):
        cases = [
            ('plddt > 80', ['d1', 'd2']),
            ('plddt >= 80', ['d1', 'd2', 'd8']),
            ('plddt < 80', ['d3', 'x_7']),                    # NULLs never match
            ('plddt != 80', ['d1', 'd2', 'd3', 'x_7']),       # NULL != 80 is not true
            ('not plddt > 80', ['d3', 'x_7', 'd8']),          # NOT NULL is still NULL
            ('plddt is null', ['d4', 'd5', 'd6']),
            ('plddt is not null', ['d1', 'd2', 'd3', 'x_7', 'd8']),
            ('plddt is null or plddt > 90', ['d1', 'd4', 'd5', 'd6']),
            ('plddt > 80 and rmsd < 1', ['d1']),
            ('plddt > 80 or rmsd < 1 and tool = "boltz"', ['d1', 'd2', 'd8']),
            ('(plddt > 80 or rmsd < 1) and tool = "boltz"', ['d1', 'd2', 'd8']),
            ('(plddt > 80 or rmsd < 1) and tool != "boltz"', []),
            ('tool in ("af3", "chai")', ['d3', 'd4', 'd6', 'x_7']),
            ('tool in ("af3", "chai") and rmsd is null', ['d4']),
            ('rmsd = 0', ['d8']),
            ('rmsd = 0.0', ['d8']),
            ('rmsd > 1e0', ['d2', 'd3', 'd6', 'x_7']),
            ('rmsd > -1', ['d1', 'd2', 'd3', 'd6', 'x_7', 'd8']),
            ('starred', ['d1', 'd5']),
            ('not starred', ['d2', 'd3', 'd4', 'd6', 'x_7', 'd8']),
            ('rejected', ['d3', 'x_7']),
            ('pinned', ['d1', 'x_7']),
            ('staged', ['d1', 'd4', 'x_7']),
            ('not staged', ['d2', 'd3', 'd5', 'd6', 'd8']),
            ('staged and not pinned', ['d4']),
            ('starred and not rejected and plddt > 90', ['d1']),
            ('tags contains "lead"', ['d1', 'd2', 'x_7']),    # not 'leader'
            ('tags contains "b"', ['d6', 'x_7']),
            ('tags contains "100%"', ['d2']),                 # % is literal
            ('tags contains "100_"', []),                     # _ is literal, not a wildcard
            ('tags contains "weird_tag"', ['d4']),
            ('tags contains "weird%"', []),
            ("tags contains 'it\\'s'", ['d8']),
            ('not tags contains "lead"', ['d3', 'd4', 'd5', 'd6', 'd8']),
            ('name like "d%"', ['d1', 'd2', 'd3', 'd4', 'd5', 'd6', 'd8']),
            ('name like "d_"', ['d1', 'd2', 'd3', 'd4', 'd5', 'd6', 'd8']),
            ('name like "x%"', ['x_7']),
            ('name like "%_7"', ['x_7']),
            ('name = "d1"', ['d1']),
            ('name = "D1"', []),                              # = is exact; like is not
            ('name != "d1"', ['d2', 'd3', 'd4', 'd5', 'd6', 'x_7', 'd8']),
            ('name = "d1" or name = "d2" or name = "d3"', ['d1', 'd2', 'd3']),
            ('plddt in (60, 70, 80)', ['d3', 'x_7', 'd8']),
            ('not plddt in (60, 70, 80)', ['d1', 'd2']),      # NULL rows drop out
        ]
        for expr, expected in cases:
            self.assertEqual(self.names(expr), expected, expr)

    def testInjectionAttemptsNeverReachSqlite(self):
        # A hostile value is bound, never spliced. The table survives and the
        # expression is a string comparison that matches nothing.
        self.assertEqual(self.names('''tool = "x' OR 1=1 --"'''), [])
        self.assertEqual(self.names('''name = "'; DROP TABLE entries; --"'''), [])
        self.assertEqual(self.names('''tags contains "%' OR 1=1 --"'''), [])
        self.assertEqual(self.db.execute('SELECT count(*) FROM entries').fetchone()[0],
                         len(self.ROWS))
        # A hostile identifier position fails before any SQL is built.
        self.assertRaises(SetFilterError, self.names, 'plddt > 1; DROP TABLE entries')
        self.assertRaises(SetFilterError, self.names, '"m"."plddt" > 1')
        self.assertRaises(SetFilterError, self.names, 'entries.name = "d1"')
