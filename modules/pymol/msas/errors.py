"""Failure modes for the alignment store.

Every error is a pymol.CmdException so that the PyMOL command layer reports it the
same way it reports any other command failure.
"""
import pymol


class MSAError(pymol.CmdException):
    """Base for every alignment-store failure."""


class MSAInputError(MSAError):
    """The file is not a usable alignment, or does not match what it is attached to."""


class MSANotFound(MSAError):
    """No alignment is stored under the requested name."""


class MSANameConflict(MSAError):
    """The requested name is already taken by another alignment."""
