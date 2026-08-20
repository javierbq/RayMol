"""Predictor-agnostic model-weight cache.

Deliberately knows nothing about predictors: #249 needs it for Design mode's
bundled MPNN.mpnnpack, which has no predictor at all.

Why none of pymol.importing's fetch machinery is reused:
  * cmd.file_read buffers the whole body in memory (bundles here are ~505 MiB) and
    silently gunzips by magic number;
  * nothing there hashes anything, and cache validity is a bare os.path.exists,
    which accepts a truncated file as a valid cache;
  * there is no atomic publish, no locking, and no timeout anywhere.
"""
import errno
import hashlib
import os
import shutil
import sys
import time
import zipfile
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from .errors import (WeightBundleLayoutError, WeightCacheUnwritable,
                     WeightChecksumMismatch, WeightDownloadCancelled,
                     WeightDownloadFailed)

#: Written LAST, holds the verified digest. Its content -- not the directory's
#: existence -- is what makes a cache valid.
SENTINEL = '.ok'

#: Patch points for tests. Never call urllib.request.urlopen or time.sleep
#: directly below.
_urlopen = urlopen
_sleep = time.sleep

#: Stream in 1 MiB chunks: bundles are hundreds of MiB (see WeightBundle.size)
#: and must never be buffered whole.
CHUNK_BYTES = 1 << 20

DEFAULT_TIMEOUT = 30.0

#: Hard ceiling on transfer attempts for one bundle. Two budgets rather than one
#: because they bound different failures: MAX_STALLED_ATTEMPTS ends a transfer that
#: cannot get past a given byte, while MAX_DOWNLOAD_ATTEMPTS ends one that keeps
#: creeping forward. A ~1 GiB bundle over a CDN serving under 1 MiB/s takes tens of
#: minutes, so a handful of stalls along the way is normal and must not be fatal --
#: only a stall that no longer makes progress is.
MAX_DOWNLOAD_ATTEMPTS = 20
MAX_STALLED_ATTEMPTS = 4

RETRY_BACKOFF_BASE = 0.5
RETRY_BACKOFF_MAX = 15.0

#: Statuses worth another attempt. Any other 4xx is a bad URL or a withdrawn
#: release asset, where retrying only delays the error the user needs to see.
#: 416 is handled separately: it means our .part is longer than the resource,
#: which is a local problem to fix by restarting, not a server problem to wait out.
RETRYABLE_STATUSES = frozenset([408, 429, 500, 502, 503, 504, 507, 509])

#: Errno values that mean the cache -- not the network -- is the problem.
UNWRITABLE_ERRNOS = frozenset(
    [errno.ENOSPC, errno.EACCES, errno.EROFS, errno.ENOTDIR])


class WeightBundle:
    """A downloadable weight archive.

    sha256 and size are of the ZIP's bytes. `members` is the exact expected set of
    archive entries at the root; WeightCache asserts it after extraction, because a
    predictor handed a partially-extracted bundle usually misbehaves instead of
    failing (boltz-mlx, for one, treats a missing config.json as non-fatal).
    """

    __slots__ = ('id', 'version', 'url', 'sha256', 'size', 'members')

    def __init__(self, id, version, url, sha256, size, members):
        self.id = id
        self.version = version
        self.url = url
        self.sha256 = sha256.lower()
        self.size = size
        self.members = tuple(members)

    def __repr__(self):
        return 'WeightBundle(id=%r, version=%r)' % (self.id, self.version)


class BundledSource:
    """Weights that ship inside the app and are never downloaded.

    Exists so that ensure() can return a path it did not fetch -- the shape #249
    needs for MPNN.mpnnpack, which is copied into the .app at build time.
    """

    __slots__ = ('id', 'path')

    def __init__(self, id, path):
        self.id = id
        self.path = path

    def resolve(self):
        if not os.path.isdir(self.path):
            raise WeightDownloadFailed(
                'bundled weights for %r are missing at %s' % (self.id, self.path))
        return self.path


class WeightCache:
    """On-disk cache of weight bundles.

    Location resolution order: explicit root, then RAYMOL_WEIGHTS_DIR, then a
    per-platform default.

    RAYMOL_WEIGHTS_DIR is an override seam for tests and for a future host that needs
    to dictate the path; NOTHING SETS IT TODAY. In the app the default_root() branch is
    what runs, and it lands inside the container on a sandboxed build because
    expanduser('~') is already container-relative there — no host cooperation needed. Application Support rather than Caches, because Caches is purgeable and
    the user waited for half a gigabyte.
    """

    #: How long ensure() waits for another process's download before giving up.
    LOCK_TIMEOUT = 900.0
    #: A lock file older than this is assumed abandoned. MUST stay <= LOCK_TIMEOUT: if it
    #: were larger, a caller arriving after a downloader crashed would spin for the whole
    #: timeout and then fail with a misleading "another download in progress" instead of
    #: reclaiming the lock. Liveness is checked first anyway (see _acquire_lock), so this
    #: is only the fallback for a pid that has been recycled.
    LOCK_STALE_SECONDS = 600.0

    def __init__(self, root=None):
        self.root = root or os.environ.get('RAYMOL_WEIGHTS_DIR') \
            or self.default_root()

    @staticmethod
    def default_root(platform=None, home=None):
        platform = sys.platform if platform is None else platform
        home = os.path.expanduser('~') if home is None else home
        if platform in ('darwin', 'ios'):
            # Under the App Sandbox this same path resolves inside the container.
            #
            # 'ios' is NOT cosmetic. CPython reports sys.platform == 'ios' there, not
            # 'darwin', so an iPhone used to fall through to the ~/.raymol branch below --
            # and on iOS $HOME is the app's DATA CONTAINER ROOT, which is readable but not
            # writable. The download failed at the first mkdir with
            #   [Errno 1] Operation not permitted:
            #   /var/mobile/Containers/Data/Application/<uuid>/.raymol
            # after the user had already asked for a 529 MB fetch. Only Documents/,
            # Library/ and tmp/ are writable inside the container, so the same
            # Library/Application Support path the sandboxed Mac build uses is both the
            # correct location here and already covered by this branch.
            #
            # Library/Application Support rather than Documents/ on purpose: weights are
            # a reproducible cache, not user data, and Documents/ is surfaced in the Files
            # app (UIFileSharingEnabled) where half a gigabyte of model shards would sit
            # among the user's own structures inviting deletion.
            return os.path.join(home, 'Library', 'Application Support',
                                'RayMol', 'weights')
        return os.path.join(home, '.raymol', 'weights')

    def path_for(self, bundle):
        """Deterministic extracted location: <root>/<id>/<version>."""
        return os.path.join(self.root, bundle.id, bundle.version)

    def sentinel_for(self, bundle):
        return os.path.join(self.path_for(bundle), SENTINEL)

    def is_cached(self, bundle):
        """True only if the sentinel exists AND records the expected digest."""
        try:
            with open(self.sentinel_for(bundle)) as handle:
                return handle.read().strip().lower() == bundle.sha256
        except (IOError, OSError):
            return False

    def _incoming(self):
        return os.path.join(self.root, '.incoming')

    def _makedirs(self, path):
        try:
            os.makedirs(path, exist_ok=True)
        except OSError as exc:
            raise WeightCacheUnwritable(
                'cannot create %s: %s' % (path, exc))

    def sweep_incoming(self):
        """Reclaim scratch left behind by a process that is no longer running.

        ensure()'s `finally` covers every exit path it is given the chance to run on,
        but the fetch runs on a daemon thread (see predictors.fetching): quitting the
        app mid-download tears the interpreter down without unwinding it, and a
        half-gigabyte `.part` plus its `.d` staging directory are stranded under
        .incoming with nothing that would ever look at them again. One observed
        instance held 529 MiB for weeks.

        The pid baked into the scratch token is what makes them reclaimable -- the
        same liveness test the stale-lock path already relies on, and the reason the
        token carries a pid in the first place. A recycled pid only means the debris
        waits for the next sweep.

        Never fatal: this is housekeeping in front of a download, and an entry that
        cannot be classified or removed is simply left where it is.
        """
        incoming = self._incoming()
        try:
            entries = os.listdir(incoming)
        except OSError:
            return
        for name in entries:
            stem, extension = os.path.splitext(name)
            if extension not in ('.part', '.d'):
                continue
            pid = _pid_from_token(stem)
            if pid is None or _pid_alive(pid):
                continue
            path = os.path.join(incoming, name)
            if extension == '.d':
                _rmtree(path)
            else:
                _unlink(path)

    def _lock_path(self, bundle):
        return os.path.join(self._incoming(),
                            '%s-%s.lock' % (bundle.id, bundle.version))

    def _acquire_lock(self, bundle):
        """Return True when this caller owns the download.

        Returns False when another caller completed it while we waited -- the
        cache is then valid and there is nothing left to do.
        """
        lock = self._lock_path(bundle)
        deadline = time.monotonic() + self.LOCK_TIMEOUT
        while True:
            try:
                handle = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
                os.write(handle, str(os.getpid()).encode())
                os.close(handle)
                return True
            except FileExistsError:
                if self.is_cached(bundle):
                    return False
                # Liveness first: a crashed downloader's lock should be reclaimed at once,
                # not after the full timeout. The pid is written into the lock precisely so
                # it can be read back.
                if not _pid_alive(_read_pid(lock)):
                    _unlink(lock)
                    continue
                try:
                    age = time.time() - os.path.getmtime(lock)
                except OSError:
                    continue                      # vanished; retry immediately
                if age > self.LOCK_STALE_SECONDS:
                    _unlink(lock)                 # owner is gone, or its pid was recycled
                    continue
                if time.monotonic() > deadline:
                    raise WeightDownloadFailed(
                        'timed out waiting for another download of %r' % bundle.id)
                time.sleep(0.05)
            except OSError as exc:
                raise WeightCacheUnwritable(
                    'cannot create lock %s: %s' % (lock, exc))

    def _release_lock(self, bundle):
        _unlink(self._lock_path(bundle))

    def ensure(self, bundle, progress=None, should_cancel=None):
        """Return a local directory holding `bundle`, downloading it if needed.

        Bundles that ship inside the app resolve without any network access.

        `should_cancel` is polled between chunks and between archive members; when it
        returns true this raises WeightDownloadCancelled. Cancellation is checked at
        those boundaries only, so the worst-case latency is one 1 MiB read -- there is
        no way to interrupt a socket read already in flight, and the alternative
        (closing the socket underneath urllib) surfaces as a misleading transport
        error rather than as the cancel the user asked for.

        Nothing partial survives either way: the `finally` below removes the scratch
        file and staging directory, and the sentinel that makes a cache valid is only
        written by _publish. The one exit that skips that `finally` -- the process
        dying under the daemon thread this runs on -- is swept up here on the next
        call rather than left on disk (see sweep_incoming).
        """
        if isinstance(bundle, BundledSource):
            return bundle.resolve()
        if self.is_cached(bundle):
            return self.path_for(bundle)

        incoming = self._incoming()
        self._makedirs(incoming)
        self.sweep_incoming()
        if not self._acquire_lock(bundle):
            return self.path_for(bundle)         # someone else finished it

        # Keyed on the pid as well as the digest: two processes that both believe they
        # hold the lock (a recycled pid, a wrongly-reclaimed stale lock) must not share
        # scratch paths, or each one's `finally` deletes the other's work. Integrity was
        # never at risk -- each hashes its own stream -- but the cross-deletion turns a
        # rare race into a spurious failure and a wasted re-download.
        token = '%s-%d' % (bundle.sha256, os.getpid())
        part = os.path.join(incoming, token + '.part')
        staging = os.path.join(incoming, token + '.d')
        target = self.path_for(bundle)
        try:
            # Re-check under the lock: the winner may have published while we
            # were blocked, in which case re-downloading is pure waste.
            if self.is_cached(bundle):
                return target
            self._download(bundle, part, progress, should_cancel)
            self._extract(bundle, part, staging, progress, should_cancel)
            self._publish(bundle, staging, target)
        finally:
            _rmtree(staging)
            _unlink(part)
            self._release_lock(bundle)
        return target

    def _download(self, bundle, part, progress, should_cancel=None):
        """Stream to `part`, hashing as we go, and verify before anything is published.

        Resumable, because one stalled socket must not cost the whole transfer.
        Bundles here run 500 MiB to 1 GiB and the release CDN routinely serves them at
        well under 1 MiB/s, which leaves a window of tens of minutes in which a single
        read that stalls past DEFAULT_TIMEOUT used to discard everything received so
        far and restart from byte zero (observed on the 996 MiB boltz2-mlx-bf16 bundle:
        a timeout at ~84% threw away ~875 MiB).

        The resume is per-call: `part` is keyed on this process's pid, so an attempt
        only ever continues a prefix this call itself wrote. Scratch stranded by an
        earlier process is reclaimed by sweep_incoming, not adopted -- adopting it
        would mean trusting bytes whose provenance nothing here can check.
        """
        # Before opening the socket at all: a cancel that arrives while this caller was
        # queued on the lock should cost nothing.
        _raise_if_cancelled(should_cancel, bundle)
        _unlink(part)
        expected = bundle.size or 0
        received, digest = 0, hashlib.sha256()
        attempts = stalled = 0
        while True:
            try:
                received, digest = self._stream_to_part(
                    bundle, part, received, digest, progress, should_cancel)
                if not expected or received >= expected:
                    break
                # A body that simply stops short raises nothing at all. Before
                # resume existed this could only ever become a checksum mismatch;
                # now it is just another interrupted transfer to continue.
                reason = ('download of %s ended early at %d of %d bytes'
                          % (bundle.url, received, expected))
            except HTTPError as exc:
                if exc.code == 416 and received:
                    # We asked to resume past the end of the resource: the .part is
                    # longer than what the server holds. That is ours to fix.
                    _unlink(part)
                elif exc.code not in RETRYABLE_STATUSES:
                    _unlink(part)
                    raise WeightDownloadFailed(
                        'failed to fetch %s: %s' % (bundle.url, exc))
                reason = 'failed to fetch %s: %s' % (bundle.url, exc)
            except URLError as exc:
                reason = 'failed to fetch %s: %s' % (bundle.url, exc.reason)
            except OSError as exc:
                if exc.errno in UNWRITABLE_ERRNOS:
                    _unlink(part)
                    raise WeightCacheUnwritable(
                        'cannot write %s: %s' % (part, exc))
                reason = ('download of %s was interrupted: %s'
                          % (bundle.url, exc))

            # Re-derive both the byte count and the running hash from the file on
            # disk. The hasher inside the failed attempt may have absorbed bytes that
            # never reached the disk, and a sha256 cannot be rolled back -- so the
            # file, which is what the next attempt appends to, is the only honest
            # source for both.
            resumed, digest = _rehash_part(part, should_cancel, bundle)
            stalled = 0 if resumed > received else stalled + 1
            received = resumed
            attempts += 1
            if attempts >= MAX_DOWNLOAD_ATTEMPTS or stalled >= MAX_STALLED_ATTEMPTS:
                _unlink(part)
                raise WeightDownloadFailed(
                    '%s (gave up after %d attempts)' % (reason, attempts))
            _backoff(stalled, should_cancel, bundle)

        actual = digest.hexdigest()
        if actual != bundle.sha256:
            _unlink(part)
            raise WeightChecksumMismatch(
                'checksum mismatch for %s: expected %s, got %s'
                % (bundle.id, bundle.sha256, actual))

    def _stream_to_part(self, bundle, part, offset, digest, progress,
                        should_cancel):
        """One transfer attempt. Returns (bytes on disk, hash of those bytes).

        With `offset` > 0 this asks for `Range: bytes=<offset>-` and appends the
        response. A server that ignores Range answers 200 with the WHOLE body:
        appending that would splice a duplicate prefix into the file and surface only
        much later, as a checksum mismatch after another full download. So anything
        but a 206 discards the prefix and restarts the attempt from zero, which is
        exactly what the un-resumed path did anyway.
        """
        headers = {'User-Agent': 'RayMol'}
        if offset:
            headers['Range'] = 'bytes=%d-' % offset
        request = Request(bundle.url, headers=headers)
        expected = bundle.size or 0
        with _urlopen(request, timeout=DEFAULT_TIMEOUT) as response:
            resuming = bool(offset) and _status_of(response) == 206
            if not resuming:
                offset, digest = 0, hashlib.sha256()
            received = offset
            with open(part, 'r+b' if resuming else 'wb') as handle:
                if resuming:
                    # Write exactly where the hash ends, whatever else is in the
                    # file: `digest` covers the first `offset` bytes and nothing
                    # beyond them may survive.
                    handle.seek(offset)
                    handle.truncate()
                while True:
                    chunk = response.read(CHUNK_BYTES)
                    if not chunk:
                        break
                    handle.write(chunk)
                    digest.update(chunk)
                    received += len(chunk)
                    if progress and expected:
                        progress('download',
                                 min(1.0, float(received) / expected))
                    # After the write, not before: a cancelled chunk is still
                    # hashed and written, so `received` never overstates the file.
                    _raise_if_cancelled(should_cancel, bundle)
        return received, digest

    def _extract(self, bundle, part, staging, progress, should_cancel=None):
        """Extract to staging, then assert the layout is exactly what was declared."""
        _rmtree(staging)
        try:
            os.makedirs(staging)
            with zipfile.ZipFile(part) as archive:
                names = archive.namelist()
                if set(names) != set(bundle.members):
                    raise WeightBundleLayoutError(
                        'bundle %s contains %s, expected %s'
                        % (bundle.id, sorted(names), sorted(bundle.members)))
                for index, name in enumerate(names):
                    archive.extract(name, staging)
                    if progress:
                        progress('extract', float(index + 1) / len(names))
                    _raise_if_cancelled(should_cancel, bundle)
        except zipfile.BadZipFile as exc:
            raise WeightBundleLayoutError(
                'bundle %s is not a readable zip: %s' % (bundle.id, exc))
        except OSError as exc:
            raise WeightCacheUnwritable(
                'cannot extract into %s: %s' % (staging, exc))

    def _publish(self, bundle, staging, target):
        """Atomically move staging into place, then write the sentinel LAST."""
        try:
            self._makedirs(os.path.dirname(target))
            _rmtree(target)
            os.replace(staging, target)
            with open(os.path.join(target, SENTINEL), 'w') as handle:
                handle.write(bundle.sha256)
        except OSError as exc:
            _rmtree(target)
            raise WeightCacheUnwritable(
                'cannot publish %s: %s' % (target, exc))


def _raise_if_cancelled(should_cancel, bundle):
    """Abort the fetch if the caller asked it to stop.

    WeightDownloadCancelled is a pymol.CmdException, so it passes straight through the
    URLError/OSError handlers around the transfer loops instead of being reclassified as
    a download failure -- a cancel must never be reported to the user as an error.
    """
    if should_cancel is not None and should_cancel():
        raise WeightDownloadCancelled(
            'fetch of %s weights was cancelled' % bundle.id)


def _status_of(response):
    """HTTP status of an urlopen result, or 200 when it does not report one.

    200 is the safe default because of what the caller does with it: it reads as
    "the server did not honour Range", which restarts the transfer. Guessing 206
    from a response that never said so would append onto a prefix.
    """
    status = getattr(response, 'status', None)
    if status is None:
        status = getattr(response, 'code', None)
    try:
        return int(status)
    except (TypeError, ValueError):
        return 200


def _rehash_part(part, should_cancel=None, bundle=None):
    """Return (bytes on disk, sha256 of those bytes) for a partial download.

    Re-reading ~1 GiB costs well under a second -- three orders of magnitude less
    than re-fetching it over the link these bundles actually arrive on.

    A partial file we cannot read is not worth diagnosing: dropping it costs one
    restart, whereas resuming from a length we could not verify corrupts the result.
    """
    digest = hashlib.sha256()
    total = 0
    try:
        with open(part, 'rb') as handle:
            while True:
                chunk = handle.read(CHUNK_BYTES)
                if not chunk:
                    break
                digest.update(chunk)
                total += len(chunk)
                _raise_if_cancelled(should_cancel, bundle)
    except OSError:
        _unlink(part)
        return 0, hashlib.sha256()
    return total, digest


def _backoff(stalled, should_cancel, bundle):
    """Wait before the next attempt, without swallowing a cancel.

    Slept in short slices rather than one long call: a user who hits cancel during
    the wait should not be made to sit through the rest of it.
    """
    deadline = time.monotonic() + min(RETRY_BACKOFF_MAX,
                                      RETRY_BACKOFF_BASE * (2 ** stalled))
    while True:
        _raise_if_cancelled(should_cancel, bundle)
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return
        _sleep(min(0.05, remaining))


def _pid_from_token(stem):
    """The pid encoded in a `<sha256>-<pid>` scratch token, or None.

    None means "leave it alone": an entry that does not match the shape this module
    writes belongs to something else, and .incoming is not ours to empty.
    """
    sha, _, pid = stem.rpartition('-')
    if len(sha) != 64:
        return None
    try:
        return int(pid)
    except ValueError:
        return None


def _read_pid(path):
    """The pid recorded in a lock file, or None if unreadable/malformed."""
    try:
        with open(path) as handle:
            return int(handle.read().strip())
    except (IOError, OSError, ValueError):
        return None


def _pid_alive(pid):
    """True when `pid` is a live process. An unknown pid counts as ALIVE, so an
    unreadable lock is never reclaimed on a guess."""
    if pid is None:
        return True
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True          # exists, owned by someone else
    except OSError:
        return True
    return True


def _unlink(path):
    try:
        os.unlink(path)
    except OSError:
        pass


def _rmtree(path):
    shutil.rmtree(path, ignore_errors=True)
