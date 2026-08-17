"""Failure modes for the metric store.

Every error is a pymol.CmdException so the PyMOL command layer reports it the way it
reports any other command failure -- the same reasoning as pymol.msas.errors.
"""
import pymol


class MetricError(pymol.CmdException):
    """Base for every metric-store failure."""


class MetricSchemaError(MetricError):
    """A tool wrote a key it never declared, or declared one incoherently.

    Raised rather than accepted because an undeclared key has no scope, no units and
    no label, so nothing downstream -- the panel, `metrics_color`, export -- can do
    anything with it but print a bare number.
    """


class MetricScopeError(MetricError):
    """A value was written at a scope it does not fit.

    The whole point of the package. A `state`-scope metric with no state, or a residue
    array indexed by residues the object does not have, is a number that describes
    something other than what it claims to.
    """


class MetricNotFound(MetricError):
    """No run, or no key within a run, under the requested name."""


class MetricInputError(MetricError):
    """The value itself is unusable -- wrong type, ragged array, malformed index."""
