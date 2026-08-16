"""Background, cancellable MSA searches, and the on-disk cache of their results.

WHY THIS EXISTS, and why it looks exactly like `predictors/fetching.py`: a search is
MINUTES on someone else's machine, `cmd.msa_search` is reachable from the console, and
in the RayMol app the console runs on the main thread. RayMol drains PyMOL's feedback
buffer from a main-run-loop timer, so a blocked main thread cannot deliver even the
messages describing why it is blocked -- which is precisely how #284 happened with the
weight download. A search that ran inline would reproduce that bug with a longer wait.

WHAT THE WORKER MAY TOUCH: the filesystem, and `print`. That is the whole contract.

It must NOT create, delete or mutate anything in the session -- not even the MSA store.
PyMOL's API lock would serialize such a call correctly, but RayMol's Metal renderer reads
object state on the main thread WITHOUT taking that lock, and the object panel's poll
reads `msas.store` from the main thread on the same tick. So the worker leaves the
finished alignment ON THE SEARCH RECORD, and `pymol.msa.pump()` -- main thread, driven by
the panel's existing 500 ms poll, by msa_status and by msa_cancel -- is what puts it in
the store. `print` is safe by contrast: it goes through the same API lock, and the reader
(internal._get_feedback) uses a NON-blocking lock_attempt, so at worst a contended tick is
skipped and the line arrives on the next one.

THE CACHE is here rather than in the worker's head because a search that costs minutes and
is thrown away on the next call is the thing users notice first. Keyed on the normalised
query, the server and the mode: the same query against a different deployment, or with the
environmental databases switched off, is a different alignment and must not collide.
"""
import hashlib
import json
import os
import sys
import threading
import time
import uuid

from . import colabfold, parse
from .errors import MSAInputError, MSASearchCancelled, MSAServerError

#: Marker the app scans for on the feedback line, alongside PREDICT:, WEIGHTS: and
#: OBJPANEL:. Scalars only -- unlike the object panel's list it cannot grow with the
#: session -- so it stays far below the ~1 KB OrthoLineLength cap and can be sent inline
#: instead of through a tempfile. `error` is the one unbounded field, so it is clipped.
MARKER = 'MSA:'

#: Longest error text the marker carries. A server's own `reason` can be a paragraph, and
#: a marker that overflows the feedback line is split by the core into a fragment that
#: fails JSON decode plus a prefix-less remainder that leaks into the console (#231).
MARKER_ERROR_CHARS = 300

#: Gap between two polls of a running ticket. ColabFold's client uses 5-10 s; the server
#: measures a search in minutes, so anything tighter is load without information.
#: Read at call time so a test can shorten it.
POLL_SECONDS = 5.0

#: The first poll comes sooner: the backend dedups jobs by hash, so a query it has already
#: run is COMPLETE immediately and waiting 5 s to notice would be pure latency.
FIRST_POLL_SECONDS = 1.0

#: Ceiling on one search. Long, because a deep search of a long chain genuinely takes
#: tens of minutes on a loaded public server -- but not unbounded, because a ticket the
#: server has quietly abandoned would otherwise be polled until RayMol quits.
MAX_WALL_SECONDS = 3600.0

#: Env override for the cache location -- the seam tests point at their own temp dir,
#: mirroring RAYMOL_WEIGHTS_DIR.
CACHE_ENV = 'RAYMOL_MSA_DIR'

_LOCK = threading.Lock()

#: search id -> Search, in submission order. Never pruned automatically: msa_status with
#: no argument reports the session's searches, the way predict_status does.
_SEARCHES = {}


def default_root(platform=None, home=None):
    """Where searched alignments live. Same convention as WeightCache.default_root.

    Application Support rather than Caches for the same reason the weights use it: the
    user waited minutes for this, and Caches is purgeable. Under the App Sandbox this
    path already resolves inside the container.
    """
    platform = sys.platform if platform is None else platform
    home = os.path.expanduser('~') if home is None else home
    if platform == 'darwin':
        return os.path.join(home, 'Library', 'Application Support', 'RayMol', 'msa')
    return os.path.join(home, '.raymol', 'msa')


def cache_root():
    return os.environ.get(CACHE_ENV) or default_root()


def cache_key(query, server, mode):
    """Digest of what makes two searches the same search.

    The query is normalised for whitespace and case -- 'mktay' and 'MKTAY ' are one
    protein -- and the server and mode are folded in because the same query against a
    different deployment, or without the environmental databases, is a different result.
    """
    normalised = ''.join(str(query).split()).upper()
    material = '\n'.join([normalised, str(server), str(mode)])
    return hashlib.sha256(material.encode('utf-8')).hexdigest()


def cached_path(key, root=None):
    return os.path.join(root or cache_root(), key + '.a3m')


def _meta_path(key, root=None):
    return os.path.join(root or cache_root(), key + '.json')


def read_cache(key, root=None):
    """(text, meta) for a cached search, or (None, {}).

    Never raises: a cache that cannot be read is a cache miss, which costs one search --
    whereas a throw here would make a corrupted file permanently fatal.
    """
    try:
        with open(cached_path(key, root), 'r', encoding='utf-8') as handle:
            text = handle.read()
    except (IOError, OSError, UnicodeDecodeError):
        return None, {}
    if not text.strip():
        return None, {}
    meta = {}
    try:
        with open(_meta_path(key, root), 'r', encoding='utf-8') as handle:
            loaded = json.load(handle)
        if isinstance(loaded, dict):
            meta = loaded
    except (IOError, OSError, ValueError):
        pass
    return text, meta


def write_cache(key, text, meta, root=None):
    """Publish a searched alignment. Returns its path, or '' if it could not be written.

    The a3m is written LAST and atomically: its presence is what makes the entry valid,
    so a crash mid-write leaves a miss rather than a truncated alignment that would be
    served forever. An unwritable cache is not fatal -- the alignment is already in hand
    and the only cost is searching again next time.
    """
    root = root or cache_root()
    try:
        os.makedirs(root, exist_ok=True)
        # The pid is in the scratch name so two processes searching the same query cannot
        # each rename the other's half-written file into place.
        scratch = os.path.join(root, '%s-%d.part' % (key, os.getpid()))
        with open(_meta_path(key, root), 'w', encoding='utf-8') as handle:
            json.dump(meta, handle, sort_keys=True)
        with open(scratch, 'w', encoding='utf-8') as handle:
            handle.write(text)
        os.replace(scratch, cached_path(key, root))
    except (IOError, OSError, ValueError):
        return ''
    return cached_path(key, root)


def forget_cache(key, root=None):
    """Drop one cache entry. Used by refresh=1 and by tests; never raises."""
    for path in (cached_path(key, root), _meta_path(key, root)):
        try:
            os.unlink(path)
        except OSError:
            pass


class Search:
    """One in-flight (or finished) MSA search.

    Every mutable attribute is written by the worker and read by the main thread, so all
    access goes through `_LOCK`. The values are plain scalars and immutable strings --
    nothing here has an identity that matters -- which is what makes the coarse lock
    adequate, exactly as it is for predictors.fetching.Fetch.

    `text` and `summary` are the finished work, parked here for `pymol.msa.pump()` to pick
    up. The worker computes the summary too: it is a linear pass over megabytes, and the
    main thread's job is to store the result, not to re-derive it.
    """

    __slots__ = ('id', 'name', 'query', 'server', 'mode', 'target', 'chain', 'quiet',
                 'key', 'started', 'state', 'phase', 'ticket', 'error', 'reaped',
                 'thread', 'stop', 'text', 'summary', 'path', 'meta', 'from_cache')

    def __init__(self, name, query, server, mode, target='', chain='', quiet=1,
                 key=''):
        self.id = 'msa-%s' % uuid.uuid4().hex[:12]
        self.name = name
        self.query = query
        self.server = server
        self.mode = mode
        self.target = target
        self.chain = chain
        self.quiet = int(quiet)
        self.key = key
        self.started = time.monotonic()
        self.state = 'running'      # running | done | error | cancelled
        self.phase = 'submit'       # submit | queued | search | download | read | cached
        self.ticket = ''
        self.error = None
        self.reaped = False
        self.thread = None
        self.stop = threading.Event()
        self.text = None
        self.summary = None
        self.path = ''
        #: What the cache entry records -- server, mode, ticket, contributing databases
        #: and when the search actually ran. Becomes the MSA's `source` provenance, so a
        #: cache hit is honest about being one and still says where the bytes came from.
        self.meta = {}
        self.from_cache = False

    def snapshot(self):
        """Thread-safe copy of everything outside this module may read."""
        with _LOCK:
            summary = self.summary or {}
            error = self.error
            if error and len(error) > MARKER_ERROR_CHARS:
                error = error[:MARKER_ERROR_CHARS] + '...'
            return {
                'id': self.id,
                'name': self.name,
                'state': self.state,
                'phase': self.phase,
                'server': self.server,
                'mode': self.mode,
                'ticket': self.ticket,
                'cached': bool(self.from_cache),
                # Seconds since the search began, so the UI can say "4 minutes" rather
                # than spin an indeterminate bar: the server reports no progress
                # fraction at all, and inventing one would be a plausible-looking lie.
                'elapsed': round(time.monotonic() - self.started, 3),
                'depth': int(summary.get('depth') or 0),
                'columns': int(summary.get('columns') or 0),
                'error': error,
            }


# -- lifecycle -----------------------------------------------------------------

def start(name, query, server, mode, target='', chain='', quiet=1, refresh=0,
          on_marker=None, root=None):
    """Begin a search, or resolve it from the cache. Never blocks.

    A cache hit still returns a Search -- in state 'done' -- so callers have one shape to
    handle rather than a text-or-handle union, exactly as fetching.start does for a
    bundle already on disk. The alignment is still put in the store by pump(), so the
    cached and the searched path differ in latency only.
    """
    key = cache_key(query, server, mode)
    search = Search(name, query, server, mode, target=target, chain=chain,
                    quiet=quiet, key=key)
    if int(refresh):
        forget_cache(key, root)
    else:
        text, meta = read_cache(key, root)
        if text is not None:
            try:
                summary = parse.summarize(text)
            except MSAInputError:
                # A cached file we can no longer make sense of is a miss, not a failure:
                # the format check lives in one place and the cost of being wrong here is
                # one search.
                forget_cache(key, root)
            else:
                search.state = 'done'
                search.phase = 'cached'
                search.text = text
                search.summary = summary
                search.path = cached_path(key, root)
                search.from_cache = True
                search.meta = meta
                with _LOCK:
                    _SEARCHES[search.id] = search
                _emit(search, on_marker)
                return search

    with _LOCK:
        _SEARCHES[search.id] = search
    search.thread = threading.Thread(
        target=_run, args=(search, on_marker, root),
        name='raymol-msa-%s' % search.id, daemon=True)
    # daemon=True so quitting mid-search does not hang the process on join. Nothing
    # partial survives: the tarball is scratch under .incoming and the cached a3m is
    # renamed into place only once it is whole.
    search.thread.start()
    return search


def get(search_id):
    """The Search for `search_id`, or None. Cheap; safe from any thread."""
    with _LOCK:
        return _SEARCHES.get(search_id)


def all_searches():
    """Every search this session has started, oldest first."""
    with _LOCK:
        return list(_SEARCHES.values())


def active():
    """Searches still running. Drives the app's progress row."""
    with _LOCK:
        return [s for s in _SEARCHES.values() if s.state == 'running']


def unreaped():
    """Searches pump() has not yet dealt with, whatever state they are in."""
    with _LOCK:
        return [s for s in _SEARCHES.values() if not s.reaped]


def reap(search):
    """Mark a search as handled by pump(). Idempotent; returns False if it already was."""
    with _LOCK:
        if search.reaped:
            return False
        search.reaped = True
        return True


def cancel(search_id=''):
    """Stop one search -- or every running one. Returns how many were asked.

    The state flips HERE rather than when the worker next looks, so a cancel is visible
    to msa_status immediately. Waiting for the worker to reach its next boundary would
    leave the UI reporting "running" for up to one poll interval after the button was
    pressed, which reads as a dead button. The worker respects the flag on its side and
    never publishes an alignment for a cancelled search.
    """
    targets = []
    with _LOCK:
        for search in _SEARCHES.values():
            if search.state == 'running' and (not search_id
                                              or search.id == search_id):
                targets.append(search)
        for search in targets:
            search.state = 'cancelled'
            search.phase = 'cancelled'
    for search in targets:
        search.stop.set()
    return len(targets)


def join(search_id, timeout=None):
    """Block until a search settles. For scripts and tests, never for the app's UI."""
    search = get(search_id)
    if search is None:
        return None
    if search.thread is not None:
        search.thread.join(timeout)
    return search


def forget(search_id=''):
    """Drop settled records. Tests use it; nothing in normal operation needs it."""
    with _LOCK:
        for key in [k for k, s in _SEARCHES.items()
                    if s.state != 'running' and (not search_id or k == search_id)]:
            _SEARCHES.pop(key, None)


def shutdown(timeout=5.0):
    """Stop every search and wait for the workers to unwind. True if they all did.

    Needed for the same reason fetching.shutdown is: a worker outlives the call that
    started it, so a test whose tearDown removes the cache root while one is still
    writing gets an intermittent failure, and the next test inherits a live thread still
    holding the previous test's patched _urlopen.
    """
    cancel()
    with _LOCK:
        threads = [s.thread for s in _SEARCHES.values() if s.thread is not None]
    deadline = time.monotonic() + timeout
    for thread in threads:
        thread.join(max(0.0, deadline - time.monotonic()))
    stopped = not any(t.is_alive() for t in threads)
    with _LOCK:
        _SEARCHES.clear()
    return stopped


# -- worker --------------------------------------------------------------------

def _run(search, on_marker, root=None):
    """Worker body. Filesystem and `print` only -- see the module docstring."""
    _emit(search, on_marker)
    try:
        text, meta = _search(search, root)
        summary = parse.summarize(text)
    except MSASearchCancelled:
        with _LOCK:
            search.state = 'cancelled'
            search.phase = 'cancelled'
    except MSAInputError as exc:
        # The server answered, but not with something that is an alignment here. Said
        # against the server, because that is who has to be fixed.
        with _LOCK:
            search.state = 'error'
            search.error = ('the alignment from %s cannot be read: %s'
                            % (colabfold.host_of(search.server), exc))
    except Exception as exc:
        # Deliberately broad: this runs on a thread with no caller to propagate to, so an
        # unclassified failure has to become readable state rather than a traceback on
        # stderr that the app would never show.
        with _LOCK:
            search.state = 'error'
            search.error = str(exc) or exc.__class__.__name__
    else:
        with _LOCK:
            if search.stop.is_set():
                # Cancelled while the last step was in flight. The result is discarded
                # rather than landed: the user said stop, and an object appearing anyway
                # is the one outcome a cancel must never produce. It is still cached, so
                # asking again is instant.
                search.state = 'cancelled'
                search.phase = 'cancelled'
            else:
                search.state = 'done'
                search.phase = 'ready'
                search.text = text
                search.summary = summary
                search.meta = meta
    _emit(search, on_marker)


def _search(search, root=None):
    """Submit, poll, download, merge. Returns (a3m text, provenance)."""
    def should_cancel():
        return search.stop.is_set()

    _raise_if_cancelled(search)
    ticket = colabfold.submit(search.server, search.query, search.mode)
    status = colabfold.check_status(ticket, search.server)
    identifier = colabfold.ticket_id(ticket, search.server)
    with _LOCK:
        search.ticket = identifier
        search.phase = 'queued' if status != 'COMPLETE' else 'download'

    deadline = time.monotonic() + MAX_WALL_SECONDS
    wait = FIRST_POLL_SECONDS
    while status != 'COMPLETE':
        # Event.wait rather than sleep: a cancel lands the moment it is asked for,
        # instead of after the rest of a poll interval.
        if search.stop.wait(wait):
            raise MSASearchCancelled('the search for %s was cancelled' % search.name)
        wait = POLL_SECONDS
        if time.monotonic() > deadline:
            raise MSAServerError(
                'the MSA server at %s has not finished this search after %d minutes;'
                ' giving up on ticket %s'
                % (colabfold.host_of(search.server),
                   int(MAX_WALL_SECONDS / 60), identifier))
        ticket = colabfold.poll(search.server, identifier)
        status = colabfold.check_status(ticket, search.server)
        with _LOCK:
            search.phase = 'search' if status == 'RUNNING' else 'queued'

    _raise_if_cancelled(search)
    with _LOCK:
        search.phase = 'download'

    incoming = os.path.join(root or cache_root(), '.incoming')
    scratch = os.path.join(incoming, '%s-%d.tar.gz' % (search.key, os.getpid()))
    try:
        os.makedirs(incoming, exist_ok=True)
    except OSError as exc:
        raise MSAServerError('cannot write to the alignment cache at %s: %s'
                             % (incoming, exc))
    # Reclaim tarballs a previous run left behind before adding one of our own.
    sweep_incoming(root)
    try:
        colabfold.download(search.server, identifier, scratch,
                           should_cancel=should_cancel)
        _raise_if_cancelled(search)
        with _LOCK:
            search.phase = 'read'
        text, sources = colabfold.a3m_from_tar(scratch, search.server)
    finally:
        try:
            os.unlink(scratch)
        except OSError:
            pass

    _raise_if_cancelled(search)
    meta = {
        'server': search.server,
        'mode': search.mode,
        'ticket': identifier,
        'query': search.query,
        'sources': sources,
        'when': time.strftime('%Y-%m-%dT%H:%M:%S'),
    }
    path = write_cache(search.key, text, meta, root)
    with _LOCK:
        search.path = path
    return text, meta


def _raise_if_cancelled(search):
    if search.stop.is_set():
        raise MSASearchCancelled('the search for %s was cancelled' % search.name)


def _emit(search, on_marker=None):
    """Publish the search's state on the feedback line.

    Unthrottled, unlike the weight fetch's marker: a search changes phase a handful of
    times in several minutes, so there is nothing here to throttle.
    """
    payload = search.snapshot()
    if on_marker is not None:
        on_marker(payload)
    else:
        print(MARKER + json.dumps(payload, separators=(',', ':')))


def sweep_incoming(root=None):
    """Remove tarballs left behind by a process that is gone. Never fatal.

    The worker's `finally` covers every exit it is given the chance to run on, but it is
    a daemon thread: quitting the app mid-download tears the interpreter down without
    unwinding it, and a partial tarball is stranded. Same reclaim rule as
    WeightCache.sweep_incoming -- the pid in the name is what makes it reclaimable.
    """
    incoming = os.path.join(root or cache_root(), '.incoming')
    try:
        entries = os.listdir(incoming)
    except OSError:
        return
    for name in entries:
        stem = name.split('.tar.gz')[0]
        _, _, pid = stem.rpartition('-')
        try:
            pid = int(pid)
        except ValueError:
            continue
        if _pid_alive(pid):
            continue
        try:
            os.unlink(os.path.join(incoming, name))
        except OSError:
            pass


def _pid_alive(pid):
    """True when `pid` is live. An unknown pid counts as alive -- never reclaim on a
    guess."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except OSError:
        return True
    return True
