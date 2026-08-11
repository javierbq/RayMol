"""Failure modes for the prediction backend.

Every error is a pymol.CmdException so that the PyMOL command layer reports it the
same way it reports any other command failure.
"""
import pymol


class PredictionError(pymol.CmdException):
    """Base for every prediction-backend failure."""


class PredictorNotFound(PredictionError):
    """No predictor is registered under the requested id."""


class PredictorUnavailable(PredictionError):
    """The predictor cannot run here: wrong platform, no host, unsupported OS."""


class PredictionInputError(PredictionError):
    """The input sequence or spec is malformed or unsupported."""


class PredictionOptionError(PredictionError):
    """An option is unknown to this predictor, or out of range."""


class WeightDownloadFailed(PredictionError):
    """The weight bundle could not be fetched."""


class WeightChecksumMismatch(PredictionError):
    """The downloaded bundle's digest did not match the declaration."""


class WeightBundleLayoutError(PredictionError):
    """The bundle verified, but its contents are not what the declaration promised."""


class WeightCacheUnwritable(PredictionError):
    """The cache directory cannot be written: permissions, or out of space."""
