"""Failure modes for the set store (#415).

Every error is a pymol.CmdException so the PyMOL command layer reports it the way it
reports any other command failure -- the same reasoning as pymol.metrics.errors.
"""
import pymol


class SetError(pymol.CmdException):
    """Base for every set-store failure."""


class SetNotFound(SetError):
    """No set, entry, run or view under the requested name.

    A name that matches nothing is an error, never an empty selection: an agent that
    mistypes an entry name over MCP must hear about it rather than stage nothing.
    """


class SetNameConflict(SetError):
    """The name is taken -- by another set, another entry in the same set, or an object
    the store did not create."""


class SetInputError(SetError):
    """The input itself is unusable: a key that is not [a-z0-9_]+, a ragged array, an
    unreadable structure file, a selector with no meaning."""


class SetFilterError(SetError):
    """The filter expression does not parse, or names a column the set does not have.

    Carries `offset`, the character position the parser stopped at, so a UI can point
    at the token rather than the user having to guess.
    """

    def __init__(self, message, offset=None):
        SetError.__init__(self, message)
        self.offset = offset


class SetBudgetExceeded(SetError):
    """Staging would put more objects in the scene than the budget allows.

    Carries `unpinned`, the staged-but-unpinned entry names the caller could drop. The
    store never drops them itself: which candidate leaves the scene is the user's call.
    """

    def __init__(self, message, unpinned=()):
        SetError.__init__(self, message)
        self.unpinned = tuple(unpinned)


class SetFormatError(SetError):
    """The .raymol file cannot be opened: not SQLite, a newer format version than this
    build reads, or a failed migration."""
