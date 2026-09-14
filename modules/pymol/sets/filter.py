"""The filter expression: a small language compiled to a parameterised WHERE clause (#415, spec §5).

    expr     := or
    or       := and ('or' and)*
    and      := not ('and' not)*
    not      := 'not' not | cmp
    cmp      := '(' expr ')'
              | column op value
              | column 'in' '(' value (',' value)* ')'
              | column 'is' ['not'] 'null'
              | 'tags' 'contains' string
              | 'name' ('like' | '=' | '!=') string
              | flag
    op       := '<' | '<=' | '>' | '>=' | '=' | '!='
    column   := [a-z][a-z0-9_]*                  -- a declared column of the set
    value    := number | string | 'true' | 'false'
    flag     := 'starred' | 'rejected' | 'staged' | 'pinned'

Three stages, each usable on its own:

    parse(expr)             -> AST            syntax only; knows nothing about the set
    validate(ast, columns)  -> None           every column declared, every value the right type
    compile(expr, columns)  -> (sql, params)  the two above, then SQL generation

The SQL is a fragment for a WHERE clause over two aliases the caller provides:

    e   the shared `entries` table  (name, tags, starred, rejected, pinned, staged_object)
    m   the set's wide metrics table `m_<set_id>`, one column per declared metric

Identifiers are double-quoted and were validated against the declared columns before any
SQL was built; values are ALWAYS `?` placeholders with a matching params tuple. Nothing
the user typed is ever interpolated into the SQL text, which is what lets a saved view
or an MCP call carry a filter string without the table ever seeing raw SQL.

AST
    Or(left, right) / And(left, right) / Not(operand)
    Cmp(column, op, op_offset, value)     op in < <= > >= = != like contains
    In(column, values)                    values: tuple of Value
    IsNull(column, negated)
    Flag(name, offset)
    Column(name, offset), Value(kind, value, offset)   kind in 'number' 'string' 'bool'

Semantics that fall out of SQL rather than being coded here
    A NULL metric never matches a comparison: `plddt > 80`, `plddt != 5` and
    `plddt in (1, 2)` are all NULL (false) for a row whose plddt is NULL, which is what
    §5 asks for ("absent is not zero"). Consequently `not plddt > 80` is ALSO false for a
    NULL row -- NOT NULL is NULL. Use `plddt is null` to ask about absence explicitly.
    No IS NOT NULL wrappers are added; the SQL is the semantics.

Decisions §5 left open
    - Reserved names: `name`, `tags` and the four flags always mean the entries table,
      even if a set declares a metric column of the same name.
    - `like` is only valid on `name`; a str metric column takes = != in (and is null).
    - `contains` is only valid on `tags` and matches a whole space-separated token:
      `(' ' || e.tags || ' ') LIKE '% x %' ESCAPE '\\'` with the user's %, _ and \\ escaped.
    - Numbers: optional sign, digits, optional fraction, optional exponent. A number with
      neither fraction nor exponent binds as int, otherwise as float.
    - Strings: "..." or '...'; backslash escapes the quote and itself; any other backslash
      sequence is kept verbatim. Unterminated strings report the opening quote's offset.
    - true/false bind 1/0. float and int columns accept numbers or true/false; bool
      columns accept true/false or the numbers 0 and 1; str columns accept only strings.
    - The words and or not in is null like contains true false are case-insensitive.
      Column names are lowercase as declared, and so are name, tags and the four
      flags: they are column tokens of the grammar, not keywords.
    - An empty tag (`tags contains ""`) is an error rather than a match on every
      untagged entry.
    - `columns_used` returns only metric column names (those that resolve to m."col");
      name, tags and the flags are always present and are not reported.
"""

from .errors import SetFilterError

__all__ = ['compile', 'parse', 'validate', 'columns_used',
           'Or', 'And', 'Not', 'Cmp', 'In', 'IsNull', 'Flag', 'Column', 'Value']

KEYWORDS = frozenset(('and', 'or', 'not', 'in', 'is', 'null', 'like', 'contains',
                      'true', 'false'))
FLAGS = frozenset(('starred', 'rejected', 'staged', 'pinned'))
ENTRY_COLUMNS = frozenset(('name', 'tags'))
DTYPES = frozenset(('float', 'int', 'str', 'bool'))
COMPARISON_OPS = frozenset(('<', '<=', '>', '>=', '=', '!='))
EQUALITY_OPS = frozenset(('=', '!='))

_LIKE_ESCAPE = '\\'


# ---------------------------------------------------------------------------- AST

class _Node(object):
    __slots__ = ()
    _fields = ()

    def __init__(self, *args):
        if len(args) != len(self._fields):
            raise TypeError('%s takes %d arguments' % (type(self).__name__, len(self._fields)))
        for name, value in zip(self._fields, args):
            object.__setattr__(self, name, value)

    def __setattr__(self, name, value):
        raise AttributeError('AST nodes are immutable')

    def __eq__(self, other):
        return type(self) is type(other) and all(
            getattr(self, f) == getattr(other, f) for f in self._fields)

    def __ne__(self, other):
        return not self.__eq__(other)

    def __hash__(self):
        return hash((type(self).__name__,) + tuple(getattr(self, f) for f in self._fields))

    def __repr__(self):
        return '%s(%s)' % (type(self).__name__, ', '.join(
            '%s=%r' % (f, getattr(self, f)) for f in self._fields))


class Or(_Node):
    __slots__ = _fields = ('left', 'right')


class And(_Node):
    __slots__ = _fields = ('left', 'right')


class Not(_Node):
    __slots__ = _fields = ('operand',)


class Column(_Node):
    """A column reference: `name` as typed, `offset` where it starts."""
    __slots__ = _fields = ('name', 'offset')


class Value(_Node):
    """A literal: `kind` in 'number', 'string', 'bool'; `value` the Python value."""
    __slots__ = _fields = ('kind', 'value', 'offset')


class Cmp(_Node):
    """`column op value`; op is one of < <= > >= = != like contains."""
    __slots__ = _fields = ('column', 'op', 'op_offset', 'value')


class In(_Node):
    """`column in (v, v, ...)`; values is a non-empty tuple of Value."""
    __slots__ = _fields = ('column', 'values')


class IsNull(_Node):
    """`column is null` (negated=False) or `column is not null` (negated=True)."""
    __slots__ = _fields = ('column', 'negated')


class Flag(_Node):
    """One of starred, rejected, staged, pinned."""
    __slots__ = _fields = ('name', 'offset')


# ------------------------------------------------------------------------ tokenizer

# Token kinds
IDENT, KEYWORD, NUMBER, STRING, OP, LPAREN, RPAREN, COMMA, EOF = (
    'identifier', 'keyword', 'number', 'string', 'operator', '(', ')', ',', 'end of input')


class _Token(object):
    __slots__ = ('kind', 'text', 'value', 'offset')

    def __init__(self, kind, text, value, offset):
        self.kind = kind
        self.text = text
        self.value = value
        self.offset = offset

    def describe(self):
        if self.kind == EOF:
            return 'end of input'
        return '%s %r' % (self.kind, self.text)

    def __repr__(self):
        return '_Token(%s, %r, %r, %d)' % (self.kind, self.text, self.value, self.offset)


def _is_word_start(c):
    return c.isalpha() or c == '_'


def _is_word_char(c):
    return c.isalnum() or c == '_'


def _is_column_name(word):
    # column := [a-z][a-z0-9_]*   (ASCII only; str.isalpha is too generous)
    if not word or not ('a' <= word[0] <= 'z'):
        return False
    for c in word:
        if not ('a' <= c <= 'z' or '0' <= c <= '9' or c == '_'):
            return False
    return True


def _tokenize(expr):
    tokens = []
    i, n = 0, len(expr)
    while i < n:
        c = expr[i]
        if c in ' \t\r\n':
            i += 1
            continue
        start = i
        if c in '()':
            tokens.append(_Token(LPAREN if c == '(' else RPAREN, c, c, start))
            i += 1
        elif c == ',':
            tokens.append(_Token(COMMA, c, c, start))
            i += 1
        elif c in '<>!=':
            two = expr[i:i + 2]
            if two in ('<=', '>=', '!='):
                tokens.append(_Token(OP, two, two, start))
                i += 2
            elif c == '!':
                raise SetFilterError("unexpected character '!' at offset %d "
                                     "(did you mean '!=')" % start, offset=start)
            elif two == '==':
                raise SetFilterError("unexpected character '=' at offset %d "
                                     "(equality is a single '=')" % (start + 1),
                                     offset=start + 1)
            else:
                tokens.append(_Token(OP, c, c, start))
                i += 1
        elif c in '"\'':
            value, i = _read_string(expr, i)
            tokens.append(_Token(STRING, expr[start:i], value, start))
        elif c.isdigit() or (c in '+-.' and _starts_number(expr, i)):
            value, i = _read_number(expr, i)
            tokens.append(_Token(NUMBER, expr[start:i], value, start))
        elif _is_word_start(c):
            while i < n and _is_word_char(expr[i]):
                i += 1
            word = expr[start:i]
            lowered = word.lower()
            if lowered in KEYWORDS:
                tokens.append(_Token(KEYWORD, word, lowered, start))
            else:
                tokens.append(_Token(IDENT, word, word, start))
        else:
            raise SetFilterError('unexpected character %r at offset %d' % (c, start),
                                 offset=start)
    tokens.append(_Token(EOF, '', None, n))
    return tokens


def _starts_number(expr, i):
    """True if expr[i] (one of + - .) begins a numeric literal."""
    c = expr[i]
    nxt = expr[i + 1] if i + 1 < len(expr) else ''
    if c == '.':
        return nxt.isdigit()
    # sign: followed by a digit, or by '.' then a digit
    if nxt.isdigit():
        return True
    return nxt == '.' and i + 2 < len(expr) and expr[i + 2].isdigit()


def _read_number(expr, i):
    n = len(expr)
    start = i
    if expr[i] in '+-':
        i += 1
    is_float = False
    while i < n and expr[i].isdigit():
        i += 1
    if i < n and expr[i] == '.':
        is_float = True
        i += 1
        while i < n and expr[i].isdigit():
            i += 1
    if i < n and expr[i] in 'eE':
        j = i + 1
        if j < n and expr[j] in '+-':
            j += 1
        if j < n and expr[j].isdigit():
            is_float = True
            i = j
            while i < n and expr[i].isdigit():
                i += 1
        else:
            raise SetFilterError('malformed number %r at offset %d' % (expr[start:j], start),
                                 offset=start)
    if i < n and _is_word_char(expr[i]):
        # 80abc, 1.5x -- a number glued to letters is not a number
        j = i
        while j < n and _is_word_char(expr[j]):
            j += 1
        raise SetFilterError('malformed number %r at offset %d' % (expr[start:j], start),
                             offset=start)
    text = expr[start:i]
    if is_float:
        return float(text), i
    return int(text), i


def _read_string(expr, i):
    quote = expr[i]
    start = i
    i += 1
    n = len(expr)
    out = []
    while i < n:
        c = expr[i]
        if c == '\\' and i + 1 < n and expr[i + 1] in ('\\', quote):
            out.append(expr[i + 1])
            i += 2
            continue
        if c == quote:
            return ''.join(out), i + 1
        out.append(c)
        i += 1
    raise SetFilterError('unterminated string starting at offset %d' % start, offset=start)


# --------------------------------------------------------------------------- parser

class _Parser(object):

    def __init__(self, expr):
        self.expr = expr
        self.tokens = _tokenize(expr)
        self.pos = 0

    # -- token helpers

    def peek(self):
        return self.tokens[self.pos]

    def advance(self):
        tok = self.tokens[self.pos]
        self.pos += 1
        return tok

    def at_keyword(self, *words):
        tok = self.peek()
        return tok.kind == KEYWORD and tok.value in words

    def fail(self, expected, tok=None):
        tok = tok or self.peek()
        raise SetFilterError('expected %s but found %s at offset %d'
                             % (expected, tok.describe(), tok.offset), offset=tok.offset)

    def expect_keyword(self, word):
        if not self.at_keyword(word):
            self.fail("'%s'" % word)
        return self.advance()

    # -- productions

    def parse(self):
        if self.peek().kind == EOF:
            raise SetFilterError('empty expression', offset=0)
        node = self.parse_or()
        tok = self.peek()
        if tok.kind != EOF:
            raise SetFilterError('unexpected %s after the end of the expression at offset %d'
                                 % (tok.describe(), tok.offset), offset=tok.offset)
        return node

    def parse_or(self):
        node = self.parse_and()
        while self.at_keyword('or'):
            self.advance()
            node = Or(node, self.parse_and())
        return node

    def parse_and(self):
        node = self.parse_not()
        while self.at_keyword('and'):
            self.advance()
            node = And(node, self.parse_not())
        return node

    def parse_not(self):
        if self.at_keyword('not'):
            self.advance()
            return Not(self.parse_not())
        return self.parse_cmp()

    def parse_cmp(self):
        tok = self.peek()
        if tok.kind == LPAREN:
            self.advance()
            node = self.parse_or()
            if self.peek().kind != RPAREN:
                self.fail("')'")
            self.advance()
            return node
        if tok.kind != IDENT:
            self.fail('a column, flag or "("')
        self.advance()
        if tok.value in FLAGS:
            return Flag(tok.value, tok.offset)
        if not _is_column_name(tok.value):
            raise SetFilterError('invalid column name %r at offset %d (columns are '
                                 '[a-z][a-z0-9_]*)' % (tok.value, tok.offset),
                                 offset=tok.offset)
        column = Column(tok.value, tok.offset)
        nxt = self.peek()
        if nxt.kind == OP:
            self.advance()
            return Cmp(column, nxt.value, nxt.offset, self.parse_value())
        if nxt.kind == KEYWORD:
            if nxt.value in ('like', 'contains'):
                self.advance()
                return Cmp(column, nxt.value, nxt.offset, self.parse_value())
            if nxt.value == 'in':
                self.advance()
                return self.parse_in(column)
            if nxt.value == 'is':
                self.advance()
                negated = False
                if self.at_keyword('not'):
                    self.advance()
                    negated = True
                self.expect_keyword('null')
                return IsNull(column, negated)
        self.fail("an operator after column '%s'" % column.name)

    def parse_in(self, column):
        if self.peek().kind != LPAREN:
            self.fail("'(' after 'in'")
        self.advance()
        values = [self.parse_value()]
        while self.peek().kind == COMMA:
            self.advance()
            values.append(self.parse_value())
        if self.peek().kind != RPAREN:
            self.fail("',' or ')'")
        self.advance()
        return In(column, tuple(values))

    def parse_value(self):
        tok = self.peek()
        if tok.kind == NUMBER:
            self.advance()
            return Value('number', tok.value, tok.offset)
        if tok.kind == STRING:
            self.advance()
            return Value('string', tok.value, tok.offset)
        if tok.kind == KEYWORD and tok.value in ('true', 'false'):
            self.advance()
            return Value('bool', tok.value == 'true', tok.offset)
        self.fail('a value (number, string, true or false)')


def parse(expr):
    """Parse `expr` to an AST (see the module docstring). Raises SetFilterError.

    Syntax only: columns are not checked against a set here; see `validate`.
    An empty or whitespace-only expression is an error at this level -- `compile`
    is the entry point that maps it to no filter.
    """
    return _Parser(expr).parse()


# ------------------------------------------------------------------------ validation

def _type_error(value, message):
    raise SetFilterError('%s at offset %d' % (message, value.offset), offset=value.offset)


def _check_value(column, dtype, value):
    """`value` may be compared with `column` of `dtype`, or raise at the value's offset."""
    if dtype in ('float', 'int'):
        if value.kind not in ('number', 'bool'):
            _type_error(value, "column '%s' is %s; cannot compare with %s %r"
                        % (column.name, dtype, value.kind, value.value))
    elif dtype == 'str':
        if value.kind != 'string':
            _type_error(value, "column '%s' is a string; cannot compare with %s %r"
                        % (column.name, value.kind, value.value))
    elif dtype == 'bool':
        if value.kind == 'string' or (value.kind == 'number' and value.value not in (0, 1)):
            _type_error(value, "column '%s' is a boolean; expected true, false, 0 or 1, "
                        "not %r" % (column.name, value.value))
    else:
        raise ValueError('unknown dtype %r for column %r' % (dtype, column.name))


def _resolve(column, columns):
    """The dtype of a metric column, or raise unknown column at its offset."""
    if column.name in columns:
        return columns[column.name]
    raise SetFilterError("unknown column '%s' at offset %d" % (column.name, column.offset),
                         offset=column.offset)


def _validate_node(node, columns):
    if isinstance(node, (Or, And)):
        _validate_node(node.left, columns)
        _validate_node(node.right, columns)
    elif isinstance(node, Not):
        _validate_node(node.operand, columns)
    elif isinstance(node, Flag):
        pass
    elif isinstance(node, Cmp):
        _validate_cmp(node, columns)
    elif isinstance(node, In):
        name = node.column.name
        if name in ENTRY_COLUMNS:
            raise SetFilterError("'in' is not valid on %s at offset %d"
                                 % (name, node.column.offset), offset=node.column.offset)
        dtype = _resolve(node.column, columns)
        for value in node.values:
            _check_value(node.column, dtype, value)
    elif isinstance(node, IsNull):
        name = node.column.name
        if name in ENTRY_COLUMNS:
            raise SetFilterError("'is null' is not valid on %s (it is never null) at "
                                 "offset %d" % (name, node.column.offset),
                                 offset=node.column.offset)
        _resolve(node.column, columns)
    else:
        raise TypeError('not an AST node: %r' % (node,))


def _validate_cmp(node, columns):
    column, op, value = node.column, node.op, node.value
    name = column.name
    if name == 'tags':
        if op != 'contains':
            raise SetFilterError("tags only supports 'contains' at offset %d"
                                 % node.op_offset, offset=node.op_offset)
        if value.kind != 'string':
            _type_error(value, "'tags contains' needs a string, not %s %r"
                        % (value.kind, value.value))
        if not value.value:
            # '%  %' would match every entry with no tags; an empty tag is nothing
            _type_error(value, "'tags contains' needs a non-empty tag")
        return
    if name == 'name':
        if op not in ('like', '=', '!='):
            raise SetFilterError("name only supports like, = and != at offset %d"
                                 % node.op_offset, offset=node.op_offset)
        if value.kind != 'string':
            _type_error(value, "name needs a string, not %s %r" % (value.kind, value.value))
        return
    dtype = _resolve(column, columns)
    if op == 'contains':
        raise SetFilterError("'contains' is only valid on tags at offset %d"
                             % node.op_offset, offset=node.op_offset)
    if op == 'like':
        raise SetFilterError("'like' is only valid on name at offset %d"
                             % node.op_offset, offset=node.op_offset)
    if dtype == 'str' and op not in EQUALITY_OPS:
        raise SetFilterError("column '%s' is a string; only = and != apply at offset %d"
                             % (name, node.op_offset), offset=node.op_offset)
    _check_value(column, dtype, value)


def validate(ast, columns):
    """Check `ast` against `columns` ({metric column name: dtype}); raise SetFilterError.

    Every referenced metric column must be declared, and every literal must fit its
    column's dtype (float/int: numbers or true/false; str: strings; bool: true, false,
    0 or 1). `like` is only valid on name, `contains` only on tags, and str columns only
    take = and != (plus `in` and `is null`).
    """
    _validate_node(ast, columns)


def columns_used(ast):
    """The metric column names an AST references (not name, tags or the flags)."""
    out = set()

    def walk(node):
        if isinstance(node, (Or, And)):
            walk(node.left)
            walk(node.right)
        elif isinstance(node, Not):
            walk(node.operand)
        elif isinstance(node, (Cmp, In, IsNull)):
            if node.column.name not in ENTRY_COLUMNS:
                out.add(node.column.name)
    walk(ast)
    return out


# -------------------------------------------------------------------------- codegen

def _bind(value):
    if value.kind == 'bool':
        return 1 if value.value else 0
    return value.value


def _column_sql(column):
    if column.name in ENTRY_COLUMNS:
        return 'e."%s"' % column.name
    return 'm."%s"' % column.name


def _escape_like(text):
    return (text.replace(_LIKE_ESCAPE, _LIKE_ESCAPE + _LIKE_ESCAPE)
                .replace('%', _LIKE_ESCAPE + '%')
                .replace('_', _LIKE_ESCAPE + '_'))


def _gen(node, params):
    if isinstance(node, Or):
        return '(%s OR %s)' % (_gen(node.left, params), _gen(node.right, params))
    if isinstance(node, And):
        return '(%s AND %s)' % (_gen(node.left, params), _gen(node.right, params))
    if isinstance(node, Not):
        return 'NOT %s' % _gen(node.operand, params)
    if isinstance(node, Flag):
        if node.name == 'staged':
            return 'e."staged_object" IS NOT NULL'
        return 'e."%s" = 1' % node.name
    if isinstance(node, Cmp):
        if node.op == 'contains':
            params.append('% ' + _escape_like(node.value.value) + ' %')
            return "(' ' || e.\"tags\" || ' ') LIKE ? ESCAPE '%s'" % _LIKE_ESCAPE
        col = _column_sql(node.column)
        params.append(_bind(node.value))
        if node.op == 'like':
            return '%s LIKE ?' % col
        return '%s %s ?' % (col, node.op)
    if isinstance(node, In):
        for value in node.values:
            params.append(_bind(value))
        return '%s IN (%s)' % (_column_sql(node.column), ', '.join('?' * len(node.values)))
    if isinstance(node, IsNull):
        return '%s IS %sNULL' % (_column_sql(node.column), 'NOT ' if node.negated else '')
    raise TypeError('not an AST node: %r' % (node,))


def compile(expr, columns):
    """Compile a filter expression to `(sql_fragment, params)`.

    `columns` maps each declared metric column name to its dtype ('float', 'int', 'str'
    or 'bool'); the store gets it from the set's columns JSON. The fragment is meant for
    `... FROM entries e LEFT JOIN m_<set> m ON m.entry_id = e.id WHERE <fragment>`.
    An empty or whitespace-only expression compiles to ('', ()): no filter.
    Raises SetFilterError with the offset of the offending token.
    """
    if not expr or not expr.strip():
        return '', ()
    ast = parse(expr)
    validate(ast, columns)
    params = []
    sql = _gen(ast, params)
    return sql, tuple(params)
