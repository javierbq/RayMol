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
from urllib.error import URLError
from urllib.request import Request, urlopen

from .errors import (WeightBundleLayoutError, WeightCacheUnwritable,
                     WeightChecksumMismatch, WeightDownloadCancelled,
                     WeightDownloadFailed)

#: Written LAST, holds the verified digest. Its content -- not the directory's
#: existence -- is what makes a cache valid.
SENTINEL = '.ok'

#: Patch point for tests. Never call urllib.request.urlopen directly below.
_urlopen = urlopen

#: Stream in 1 MiB chunks: bundles are hundreds of MiB (see WeightBundle.size)
#: and must never be buffered whole.
CHUNK_BYTES = 1 << 20

DEFAULT_TIMEOUT = 30.0


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
        if platform == 'darwin':
            # Under the App Sandbox this same path resolves inside the container.
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
        written by _publish.
        """
        if isinstance(bundle, BundledSource):
            return bundle.resolve()
        if self.is_cached(bundle):
            return self.path_for(bundle)

        incoming = self._incoming()
        self._makedirs(incoming)
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
        """Stream to `part`, hashing as we go, and verify before anything is published."""
        digest = hashlib.sha256()
        received = 0
        expected = bundle.size or 0
        # Before opening the socket at all: a cancel that arrives while this caller was
        # queued on the lock should cost nothing.
        _raise_if_cancelled(should_cancel, bundle)
        try:
            request = Request(bundle.url, headers={'User-Agent': 'RayMol'})
            with _urlopen(request, timeout=DEFAULT_TIMEOUT) as response:
                with open(part, 'wb') as handle:
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
        except URLError as exc:
            _unlink(part)
            raise WeightDownloadFailed(
                'failed to fetch %s: %s' % (bundle.url, exc.reason))
        except OSError as exc:
            _unlink(part)
            if exc.errno in (errno.ENOSPC, errno.EACCES, errno.EROFS, errno.ENOTDIR):
                raise WeightCacheUnwritable(
                    'cannot write %s: %s' % (part, exc))
            raise WeightDownloadFailed(
                'download of %s was interrupted: %s' % (bundle.url, exc))

        actual = digest.hexdigest()
        if actual != bundle.sha256:
            _unlink(part)
            raise WeightChecksumMismatch(
                'checksum mismatch for %s: expected %s, got %s'
                % (bundle.id, bundle.sha256, actual))

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
