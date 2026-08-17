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
    no label, so nothing downstream -- `metrics_color`, export, a listing -- can do
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


class MetricAmbiguous(MetricError):
    """The request names something two different tools measured.

    Distinct from MetricNotFound because the remedy is opposite: there is not too
    little to act on but too much, and picking one silently is how a user ends up
    colouring by a metric they did not ask for. Re-running ONE tool supersedes its own
    earlier run -- that is not ambiguous and does not raise this -- but two tools that
    happen to share a key name have no ordering between them that means anything.
    """


class MetricInputError(MetricError):
    """The value itself is unusable -- wrong type, ragged array, malformed index."""
