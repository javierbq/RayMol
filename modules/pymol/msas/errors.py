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


class MSAServerError(MSAError):
    """An MSA server refused the search, failed it, or could not be reached.

    Every message raised as one NAMES THE SERVER. With a public default and a private
    override, "the search failed" is unactionable: which host refused is the difference
    between "our deployment is down" and "that sequence just left this machine".
    """


class MSASearchCancelled(MSAError):
    """The search was stopped before it landed.

    A pymol.CmdException, like WeightDownloadCancelled, so it passes through the
    URLError/OSError handlers around the transfer instead of being reclassified as a
    failure -- a cancel must never be reported to the user as an error.
    """
