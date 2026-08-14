"""Background, cancellable weight fetching.

WHY THIS EXISTS (issue #284): WeightCache.ensure is a half-gigabyte download plus an
extraction, and cmd.predict used to call it inline. In the RayMol app the console runs
on the main thread, so that stalled the run loop for the whole transfer -- and, worse,
made its own progress messages unrenderable: the app DRAINS PyMOL's feedback buffer from
a main-run-loop Timer, and a blocked main thread cannot service its own run loop. Every
`download NN%` line sat in the buffer until the download it was describing had finished.

So the transfer moves to a Python thread and the main thread stays free to poll.

WHAT THE THREAD MAY TOUCH: the filesystem, and `print`. That is the whole contract.

It must NOT create, delete or otherwise mutate PyMOL objects. PyMOL's API lock would
serialize such a call correctly, but RayMol's Metal renderer reads object state on the
main thread WITHOUT taking that lock, so mutating objects from here races the renderer.
Everything that touches the session is therefore done by predicting.pump(), which runs
on the main thread. `print` is safe by contrast: it goes through the same API lock, and
the reader (internal._get_feedback) uses a NON-blocking lock_attempt, so at worst a
contended tick is skipped and the line arrives on the next one.
"""
import json
import threading
import time

from .errors import WeightDownloadCancelled
from .weights import BundledSource

#: Marker the app scans for on the feedback line, alongside PREDICT: and OBJPANEL:.
#: The payload is a fixed set of scalar keys -- unlike the object panel's list, it cannot
#: grow with the session -- so it stays far below the 1024-char OrthoLineLength cap and
#: can safely be sent inline instead of through a tempfile.
MARKER = 'WEIGHTS:'

#: Floor on the gap between two progress markers. 1 MiB chunks over a 529 MB bundle is
#: ~505 callbacks; every one of them on the feedback line would be pure noise next to a
#: progress bar that repaints at 60 Hz at best.
MARKER_INTERVAL = 0.15

#: ...but always emit when the bar would visibly move, so a slow link still updates.
MARKER_FRACTION_STEP = 0.01

_LOCK = threading.Lock()
#: bundle id -> Fetch. One entry per bundle: two predicts racing on a cold cache must
#: share a single transfer, not start two.
_FETCHES = {}


class Fetch:
    """One in-flight (or finished) weight transfer.

    Every attribute is written by the worker thread and read by the main thread, so all
    access goes through `_LOCK`. The values are plain scalars -- there is nothing here
    whose identity matters, which is what makes the coarse lock adequate.
    """

    def __init__(self, bundle, cache):
        self.bundle = bundle
        self.cache = cache
        self.state = 'running'        # running | done | error | cancelled
        self.phase = 'download'       # download | extract
        self.fraction = 0.0
        self.path = None
        self.error = None
        self.cancelled = False
        self.thread = None
        self._last_marker = 0.0
        self._last_fraction = -1.0

    # -- snapshot ------------------------------------------------------------
    def snapshot(self):
        """Thread-safe copy of the fields anything outside this module may read."""
        with _LOCK:
            # getattr: BundledSource carries no size -- it is never downloaded.
            total = getattr(self.bundle, 'size', 0) or 0
            return {
                'id': self.bundle.id,
                'state': self.state,
                'phase': self.phase,
                'fraction': self.fraction,
                # Bytes only make sense while downloading: during extraction the
                # fraction counts archive members, and a byte count derived from it
                # would be a plausible-looking lie.
                'received': int(self.fraction * total) if (
                    self.phase == 'download' and total) else 0,
                'total': total,
                'error': self.error,
            }


def start(bundle, cache, on_marker=None):
    """Begin fetching `bundle`, or join a fetch already running for it.

    Returns the Fetch. Never blocks: the caller gets a handle to poll, which is what
    lets cmd.predict return while half a gigabyte is still in flight.

    A bundle already cached still returns a Fetch -- in state 'done' -- so callers have
    exactly one shape to handle rather than a path-or-handle union.
    """
    with _LOCK:
        existing = _FETCHES.get(bundle.id)
        # Only a LIVE fetch is shared, and only one landing in the SAME cache. The root
        # can change under us (RAYMOL_WEIGHTS_DIR is an override seam, and every test
        # points it at its own temp dir), and handing back a fetch that will publish
        # somewhere else would leave the caller waiting on a cache it never fills.
        # A finished fetch is always replaced, so a failed or cancelled attempt can be
        # retried simply by asking again.
        if (existing is not None and existing.state == 'running'
                and existing.cache.root == cache.root):
            return existing

    # Weights that ship inside the app, and weights already on disk, both resolve with no
    # thread at all. BundledSource is checked FIRST and resolved by delegating to ensure():
    # it has no `version`, so cache.is_cached() -> path_for() would raise AttributeError on
    # one. Nothing ships a BundledSource today, but Predictor.weight_bundle documents it as
    # valid and #275 plans to use it, so this must not sit here as a landmine.
    if isinstance(bundle, BundledSource) or cache.is_cached(bundle):
        fetch = Fetch(bundle, cache)
        fetch.state = 'done'
        fetch.phase = 'cached'
        fetch.fraction = 1.0
        fetch.path = cache.ensure(bundle)
        with _LOCK:
            _FETCHES[bundle.id] = fetch
        return fetch

    fetch = Fetch(bundle, cache)
    with _LOCK:
        _FETCHES[bundle.id] = fetch
    fetch.thread = threading.Thread(
        target=_run, args=(fetch, on_marker),
        name='raymol-weights-%s' % bundle.id, daemon=True)
    # daemon=True so a quit during a download does not hang the process on join. The
    # partial file is scratch under .incoming and the sentinel is written last, so an
    # abandoned transfer leaves nothing a later run would mistake for a valid cache.
    fetch.thread.start()
    return fetch


def get(bundle_id):
    """The Fetch for `bundle_id`, or None. Cheap; safe from any thread."""
    with _LOCK:
        return _FETCHES.get(bundle_id)


def active():
    """Every fetch still running, newest last. Used to drive the app's progress sheet."""
    with _LOCK:
        return [f for f in _FETCHES.values() if f.state == 'running']


def cancel(bundle_id=''):
    """Ask one fetch -- or every running fetch -- to stop. Returns how many were asked.

    Only sets a flag: the worker notices it between chunks (see WeightCache.ensure).
    Idempotent, and harmless on a fetch that has already finished.
    """
    with _LOCK:
        targets = [f for f in _FETCHES.values()
                   if f.state == 'running' and (not bundle_id
                                                or f.bundle.id == bundle_id)]
        for fetch in targets:
            fetch.cancelled = True
    return len(targets)


def join(bundle_id, timeout=None):
    """Block until a fetch settles. For scripts and tests, never for the app's UI.

    Returns the finished Fetch, or None if there is no such fetch.
    """
    fetch = get(bundle_id)
    if fetch is None:
        return None
    if fetch.thread is not None:
        fetch.thread.join(timeout)
    return fetch


def forget(bundle_id=''):
    """Drop finished records. Tests use it; nothing in normal operation needs it."""
    with _LOCK:
        for key in [k for k, f in _FETCHES.items()
                    if f.state != 'running' and (not bundle_id or k == bundle_id)]:
            _FETCHES.pop(key, None)


def shutdown(timeout=5.0):
    """Stop every fetch and wait for the workers to unwind. Returns True if all did.

    Needed because a worker outlives the call that started it: a test whose tearDown
    removes the cache root while a transfer is still writing into it gets an
    intermittent "directory not empty", and the NEXT test inherits a live thread that
    is still holding the previous test's patched urlopen. Both were observed.

    Records are dropped even if a worker overran the timeout: it is a daemon writing
    only to scratch under .incoming, and the sentinel that makes a cache valid is
    written last, so the worst case is a stray temp file -- never a cache another run
    could mistake for complete.
    """
    cancel()
    with _LOCK:
        threads = [f.thread for f in _FETCHES.values() if f.thread is not None]
    deadline = time.monotonic() + timeout
    for thread in threads:
        thread.join(max(0.0, deadline - time.monotonic()))
    stopped = not any(t.is_alive() for t in threads)
    with _LOCK:
        _FETCHES.clear()
    return stopped


# -- worker ------------------------------------------------------------------

def _run(fetch, on_marker):
    """Worker body. Filesystem and `print` only -- see the module docstring."""
    bundle = fetch.bundle

    def progress(phase, fraction):
        with _LOCK:
            fetch.phase = phase
            fetch.fraction = float(fraction)
        _emit(fetch, on_marker)

    def should_cancel():
        with _LOCK:
            return fetch.cancelled

    _emit(fetch, on_marker, force=True)
    try:
        path = fetch.cache.ensure(bundle, progress=progress,
                                  should_cancel=should_cancel)
    except WeightDownloadCancelled:
        with _LOCK:
            fetch.state = 'cancelled'
    except Exception as exc:
        # Deliberately broad: this runs on a thread with no caller to propagate to, so
        # an unclassified failure has to become readable state rather than a traceback
        # on stderr that the app would never show.
        with _LOCK:
            fetch.state = 'error'
            fetch.error = str(exc) or exc.__class__.__name__
    else:
        with _LOCK:
            fetch.state = 'done'
            fetch.fraction = 1.0
            fetch.path = path
    _emit(fetch, on_marker, force=True)


def _emit(fetch, on_marker, force=False):
    """Publish progress on the feedback line, throttled.

    Throttling is skipped for `force`, which is how the terminal (start) and settled
    (done/error/cancelled) markers are guaranteed to arrive -- a dropped terminal marker
    would leave the app's sheet on screen forever.
    """
    now = time.monotonic()
    with _LOCK:
        if not force:
            moved = abs(fetch.fraction - fetch._last_fraction)
            if (now - fetch._last_marker < MARKER_INTERVAL
                    and moved < MARKER_FRACTION_STEP):
                return
        fetch._last_marker = now
        fetch._last_fraction = fetch.fraction
    payload = fetch.snapshot()
    if on_marker is not None:
        on_marker(payload)
    else:
        print(MARKER + json.dumps(payload, separators=(',', ':')))
