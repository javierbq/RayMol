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
import os
import sys

from .errors import WeightDownloadFailed

#: Written LAST, holds the verified digest. Its content -- not the directory's
#: existence -- is what makes a cache valid.
SENTINEL = '.ok'


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
