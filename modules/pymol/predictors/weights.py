"""Predictor-agnostic model-weight cache.

Deliberately knows nothing about predictors: #249 needs it for Design mode's
bundled MPNN.mpnnpack, which has no predictor at all.

Why none of pymol.importing's fetch machinery is reused:
  * cmd.file_read buffers the whole body in memory (this bundle is ~533 MiB) and
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
import zipfile
from urllib.error import URLError
from urllib.request import Request, urlopen

from .errors import (WeightBundleLayoutError, WeightCacheUnwritable,
                     WeightChecksumMismatch, WeightDownloadFailed)

#: Written LAST, holds the verified digest. Its content -- not the directory's
#: existence -- is what makes a cache valid.
SENTINEL = '.ok'

#: Patch point for tests. Never call urllib.request.urlopen directly below.
_urlopen = urlopen

#: Stream in 1 MiB chunks: the bundle is ~533 MiB and must never be buffered whole.
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

    Location resolution order: explicit root, then RAYMOL_WEIGHTS_DIR (published by
    the Swift host so a sandboxed build gets its container path), then a per-platform
    default. Application Support rather than Caches, because Caches is purgeable and
    the user waited for half a gigabyte.
    """

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

    def ensure(self, bundle, progress=None):
        """Return a local directory holding `bundle`, downloading it if needed.

        Bundles that ship inside the app resolve without any network access.
        """
        if isinstance(bundle, BundledSource):
            return bundle.resolve()
        if self.is_cached(bundle):
            return self.path_for(bundle)

        incoming = self._incoming()
        self._makedirs(incoming)
        part = os.path.join(incoming, bundle.sha256 + '.part')
        staging = os.path.join(incoming, bundle.sha256 + '.d')
        target = self.path_for(bundle)

        try:
            self._download(bundle, part, progress)
            self._extract(bundle, part, staging, progress)
            self._publish(bundle, staging, target)
        finally:
            _rmtree(staging)
            _unlink(part)
        return target

    def _download(self, bundle, part, progress):
        """Stream to `part`, hashing as we go, and verify before anything is published."""
        digest = hashlib.sha256()
        received = 0
        expected = bundle.size or 0
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

    def _extract(self, bundle, part, staging, progress):
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


def _unlink(path):
    try:
        os.unlink(path)
    except OSError:
        pass


def _rmtree(path):
    shutil.rmtree(path, ignore_errors=True)
