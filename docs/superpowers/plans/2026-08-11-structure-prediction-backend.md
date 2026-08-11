# Structure-Prediction Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give RayMol a swappable structure-predictor abstraction plus a predictor-agnostic, checksum-verified model-weight cache, and wire boltz-mlx behind it end to end on macOS.

**Architecture:** Python owns the registry, the weight cache, and the `cmd.*` surface (`modules/pymol/predicting.py` + `modules/pymol/predictors/`). Inference runs in Swift/MLX. Because there is **no Python→Swift call path in RayMol**, and because the API is a job handle, Python never calls Swift: it writes a request JSON to a tempfile and prints a `PREDICT:` marker that Swift's existing 100 ms `pollFeedback()` ladder picks up; Swift writes status/result files that Python polls.

**Tech Stack:** Python 3.13 (embedded CPython, stdlib only — `urllib.request`, `hashlib`, `zipfile`), Swift 6 / SwiftUI, mlx-swift 0.31.6, boltz-mlx (`BoltzMLX` product), XcodeGen, `unittest` via `testing/testing.py`, XCTest.

**Spec:** [docs/superpowers/specs/2026-08-11-structure-prediction-backend-design.md](../specs/2026-08-11-structure-prediction-backend-design.md)

## Global Constraints

Every task's requirements implicitly include this section.

- **`requests` is NOT available at runtime.** Dev-only extra. Shipped `site-packages` holds only `Bio`, `numpy`, `pip`. Use `urllib.request`. `hashlib`, `zipfile`, `ssl` are in the bundled stdlib.
- **Never buffer the artifact in memory.** It is ~533 MiB. Stream in chunks. Do **not** use `cmd.file_read` — it buffers the whole body and silently gunzips by magic number.
- **Every public function in `predicting.py` must end its signature with `_self=cmd`.** `pymol2/cmd2.py:93-118` binds `_self=<instance>` only if `_self` is in the argspec; otherwise it copies the function verbatim and it silently talks to the global instance, with no error.
- **No `**kwargs` on command functions.** `parsing.py:352-353` forces `mode = NO_CHECK` when `co_flags & 0xC` is set, silently disabling the declared `STRICT` checking.
- **Multimer chain separator is `/`, never `,`.** Commas are what `parsing.parse_arg` splits on.
- **Chain ids: a single uppercase character.** Anything longer breaks PDB column alignment.
- **Inference defaults are upstream Boltz's:** `recycling_steps=3`, `diffusion_steps=200`, `seed=0`. The port's own defaults (0/20) **fail its own quality gate** (3.19 Å / 0.685 lDDT vs a ≤2.0 Å / ≥0.90 bar).
- **`step_scale` is not a per-call knob** — it comes from the artifact's `config.json` and already carries upstream's Boltz-2 value of `1.5`. `diffusion_samples` is **not plumbed** by the port; reject it, never accept-and-ignore.
- **No `RAYMOL_BOLTZ` compilation condition.** Gate Swift with `#if os(macOS)`. `MLXRuntime` is `#if RAYMOL_MPNN || os(macOS)`.
- **B-factor column stays `0.00`.** There is no pLDDT — `ConfidenceModule.swift:7` is explicitly PAE-only. Do not write confidence there.
- **No CI job compiles Swift or runs XCTest.** Any Swift change must be hand-compiled for **both** the macOS and iOS slices before merge.
- **Cache validity is the `.ok` sentinel's content, never directory existence.** This is what makes an interrupted download impossible to mistake for a valid cache.

### Running tests

From the repo root, exactly as CI does:

```bash
pymol -ckqy testing/testing.py --run testing/tests/predict/predict_registry.py
```

Files under `testing/tests/predict/` that do **not** start with `test_` route to the
unittest / `PyMOLTestCase` lane (`testing/testing.py:692-697`). All test files in this plan
use the `predict_*.py` form deliberately. `PyMOLTestCase.setUp` chdirs to the test file's
own directory, so relative fixture paths resolve against `testing/tests/predict/`.

### Swift build/test commands

```bash
cd swiftui && xcodegen generate
```

```bash
xcodebuild -project swiftui/PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS,arch=arm64' -configuration Debug test -skipPackagePluginValidation -skipMacroValidation
```

```bash
xcodebuild -project swiftui/PyMOLViewer.xcodeproj -scheme PyMOLViewer_iOS -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -configuration Debug build -skipPackagePluginValidation -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

A worktree needs `deps_macos`, `deps_ios`, `build_macos_swiftui`, `build_ios` symlinked from
the main checkout (all gitignored) before either command works.

## File Structure

| File | Responsibility |
|---|---|
| `modules/pymol/predictors/errors.py` | The error taxonomy. Nothing else. |
| `modules/pymol/predictors/base.py` | `Predictor` ABC, `PredictionSpec`, `PredictionOptions`, `parse_chains`. No I/O. |
| `modules/pymol/predictors/weights.py` | `WeightBundle`, `BundledSource`, `WeightCache`. Predictor-agnostic; knows nothing about predictors. |
| `modules/pymol/predictors/registry.py` | `register` / `get` / `available` / `unregister`. |
| `modules/pymol/predictors/__init__.py` | Re-exports + registers built-ins. The only file that changes when a predictor is added. |
| `modules/pymol/predictors/host.py` | Marker+tempfile transport to the Swift host; availability probe. |
| `modules/pymol/predictors/_template.py` | Copy-me skeleton. Underscore keeps it unregistered. |
| `modules/pymol/predictors/boltz2.py` | The boltz-mlx predictor. |
| `modules/pymol/predicting.py` | The `cmd.*` surface. Thin — argument marshalling only. |
| `docs/predictors.md` | How to add a predictor. |
| `swiftui/PyMOLViewer/Shared/BoltzRuntime.swift` | Boltz's MLX policy on top of `MLXRuntime`. |
| `swiftui/PyMOLViewer/Shared/PredictSizeGuard.swift` | Preventive ok/warn/refuse memory gate. |
| `swiftui/PyMOLViewer/Shared/BoltzJobManager.swift` | Consumes `PREDICT:` markers, runs inference off-main, writes status/result. |

Splitting `errors.py` from `base.py` from `weights.py` is deliberate: `weights.py` must stay
usable by #249 for `MPNN.mpnnpack`, which has no predictor at all.

---

# Part A — Python framework (unblocked, ships alone)

Part A is #224's original stated scope. It is fully offline-testable, touches no Swift, and
lands without the artifact existing.

### Task 1: Error taxonomy and base types

**Files:**
- Create: `modules/pymol/predictors/__init__.py`
- Create: `modules/pymol/predictors/errors.py`
- Create: `modules/pymol/predictors/base.py`
- Test: `testing/tests/predict/predict_base.py`

**Interfaces:**
- Consumes: nothing.
- Produces: `PredictionError`, `PredictorNotFound`, `PredictorUnavailable`, `PredictionInputError`, `PredictionOptionError`, `WeightDownloadFailed`, `WeightChecksumMismatch`, `WeightBundleLayoutError`, `WeightCacheUnwritable`; `PredictionOptions(recycling_steps, diffusion_steps, seed)`, `PredictionSpec(chains, name)`, `parse_chains(sequence) -> tuple`, `Predictor` ABC.

> **Spec addendum:** the spec's §Error taxonomy lists six failure modes. Implementation needs
> two more concrete types: `PredictionOptionError` (already named in the spec's template) and
> `WeightBundleLayoutError` for a bundle whose zip checksum *passes* but whose extracted
> members are not what the declaration promised. That is a wrong declaration, not corruption,
> so folding it into `WeightChecksumMismatch` would misreport it.

- [ ] **Step 1: Write the failing test**

Create `testing/tests/predict/predict_base.py`:

```python
"""Tests for pymol.predictors.base and .errors.

    pymol -ckqy testing/testing.py --run testing/tests/predict/predict_base.py
"""
from pymol import testing


class TestErrors(testing.PyMOLTestCase):

    def testAllErrorsAreCmdExceptions(self):
        import pymol
        from pymol.predictors import errors
        names = ('PredictorNotFound', 'PredictorUnavailable', 'PredictionInputError',
                 'PredictionOptionError', 'WeightDownloadFailed', 'WeightChecksumMismatch',
                 'WeightBundleLayoutError', 'WeightCacheUnwritable')
        for name in names:
            cls = getattr(errors, name)
            self.assertTrue(issubclass(cls, errors.PredictionError), name)
            self.assertTrue(issubclass(cls, pymol.CmdException), name)


class TestParseChains(testing.PyMOLTestCase):

    def testSingleChainGetsIdA(self):
        from pymol.predictors.base import parse_chains
        self.assertEqual(parse_chains('MKTAY'), (('A', 'MKTAY'),))

    def testSlashSeparatesChains(self):
        from pymol.predictors.base import parse_chains
        self.assertEqual(parse_chains('MKTAY/GSHMA'),
                         (('A', 'MKTAY'), ('B', 'GSHMA')))

    def testWhitespaceAndCaseAreNormalised(self):
        from pymol.predictors.base import parse_chains
        self.assertEqual(parse_chains(' mkt ay / gsh '),
                         (('A', 'MKTAY'), ('B', 'GSH')))

    def testEmptySequenceRejected(self):
        from pymol.predictors.base import parse_chains
        from pymol.predictors.errors import PredictionInputError
        self.assertRaises(PredictionInputError, parse_chains, '')
        self.assertRaises(PredictionInputError, parse_chains, 'MKT//GSH')

    def testTooManyChainsRejected(self):
        from pymol.predictors.base import parse_chains
        from pymol.predictors.errors import PredictionInputError
        self.assertRaises(PredictionInputError, parse_chains, '/'.join(['MK'] * 27))


class TestPredictionOptions(testing.PyMOLTestCase):

    def testDefaultsMatchUpstreamBoltz(self):
        from pymol.predictors.base import PredictionOptions
        opts = PredictionOptions()
        self.assertEqual(opts.recycling_steps, 3)
        self.assertEqual(opts.diffusion_steps, 200)
        self.assertEqual(opts.seed, 0)

    def testNonPositiveStepsRejected(self):
        from pymol.predictors.base import PredictionOptions
        from pymol.predictors.errors import PredictionOptionError
        self.assertRaises(PredictionOptionError, PredictionOptions, diffusion_steps=0)
        self.assertRaises(PredictionOptionError, PredictionOptions, recycling_steps=-1)
```

- [ ] **Step 2: Run test to verify it fails**

```bash
pymol -ckqy testing/testing.py --run testing/tests/predict/predict_base.py
```

Expected: FAIL — `ModuleNotFoundError: No module named 'pymol.predictors'`.

- [ ] **Step 3: Write the implementation**

Create `modules/pymol/predictors/__init__.py`:

```python
"""Structure-prediction backend: predictor registry and model-weight cache.

Public API lives in pymol.predicting (cmd.predict and friends). This package holds
the plumbing and the predictor implementations. Adding a predictor means adding one
module here plus one line in _register_builtins().
"""
from . import errors  # noqa: F401
from .registry import register, get, available, unregister  # noqa: F401


def _register_builtins():
    """Register the shipped predictors. The only function that changes per predictor."""
    return
```

Create `modules/pymol/predictors/errors.py`:

```python
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
```

Create `modules/pymol/predictors/base.py`:

```python
"""Predictor contract and input types. No I/O, no network, no PyMOL session access."""
import abc

from .errors import PredictionInputError, PredictionOptionError

#: PDB single-character chain ids, in assignment order.
CHAIN_IDS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'


def parse_chains(sequence):
    """'MKTAY/GSHMA' -> (('A', 'MKTAY'), ('B', 'GSHMA')).

    '/' is the chain separator, not ',': commas are what parsing.parse_arg splits
    the command line on, so a comma-separated list never reaches this function.
    Whitespace is stripped and residues upper-cased. Validation of which residue
    letters are acceptable belongs to the predictor, not here.
    """
    if not isinstance(sequence, str):
        raise PredictionInputError('sequence must be a string')
    parts = [''.join(p.split()).upper() for p in sequence.split('/')]
    if not parts or any(not p for p in parts):
        raise PredictionInputError(
            'empty chain in sequence; use "SEQ1/SEQ2" for a multimer')
    if len(parts) > len(CHAIN_IDS):
        raise PredictionInputError(
            'at most %d chains supported, got %d' % (len(CHAIN_IDS), len(parts)))
    return tuple(zip(CHAIN_IDS, parts))


class PredictionOptions:
    """Inference knobs. Defaults are upstream Boltz's, not the MLX port's.

    The port's own defaults (recycling 0, diffusion 20) FAIL its own quality gate
    at 3.19 A / 0.685 lDDT against a 2.0 A / 0.90 bar, so they are not used.
    step_scale is deliberately absent: it comes from the model artifact's
    config.json and is not a per-call knob.
    """

    __slots__ = ('recycling_steps', 'diffusion_steps', 'seed')

    def __init__(self, recycling_steps=3, diffusion_steps=200, seed=0):
        for name, value in (('recycling_steps', recycling_steps),
                            ('diffusion_steps', diffusion_steps),
                            ('seed', seed)):
            if not isinstance(value, int) or isinstance(value, bool):
                raise PredictionOptionError('%s must be an integer' % name)
        if recycling_steps < 0:
            raise PredictionOptionError('recycling_steps must be >= 0')
        if diffusion_steps < 1:
            raise PredictionOptionError('diffusion_steps must be >= 1')
        if seed < 0:
            raise PredictionOptionError('seed must be >= 0')
        self.recycling_steps = recycling_steps
        self.diffusion_steps = diffusion_steps
        self.seed = seed

    def as_dict(self):
        return {name: getattr(self, name) for name in self.__slots__}

    def __eq__(self, other):
        return isinstance(other, PredictionOptions) and \
            self.as_dict() == other.as_dict()

    def __repr__(self):
        return 'PredictionOptions(%s)' % ', '.join(
            '%s=%r' % kv for kv in sorted(self.as_dict().items()))


class PredictionSpec:
    """Validated, predictor-agnostic description of what to fold."""

    __slots__ = ('chains', 'name')

    def __init__(self, chains, name=''):
        self.chains = tuple(chains)
        self.name = name

    @property
    def total_residues(self):
        return sum(len(seq) for _, seq in self.chains)

    def __repr__(self):
        return 'PredictionSpec(chains=%r, name=%r)' % (self.chains, self.name)


class Predictor(abc.ABC):
    """One structure-prediction method.

    Callers depend only on this interface, so predictors are swappable without
    touching call sites.
    """

    #: Stable selector. Appears in user scripts; treat as API and never change it.
    id = None
    #: Human-readable name, for listings.
    name = None
    #: WeightBundle or BundledSource, or None if the method needs no weights.
    weight_bundle = None
    #: Option names this predictor honours, mapped to defaults. Anything else is
    #: REJECTED by validate_options rather than silently ignored.
    option_defaults = {'recycling_steps': 3, 'diffusion_steps': 200, 'seed': 0}

    @abc.abstractmethod
    def check_available(self):
        """Raise PredictorUnavailable if this cannot run here and now.

        Check platform, OS floor, host presence. Do NOT check whether weights are
        cached: that is the weight manager's job, and it is allowed to fix it.
        """

    @abc.abstractmethod
    def parse_spec(self, sequence, name=''):
        """Return a PredictionSpec, or raise PredictionInputError.

        Reject unsupported input loudly here rather than letting the backend
        silently drop residues it does not understand.
        """

    @abc.abstractmethod
    def submit(self, spec, options, weights_path):
        """Start the run and return a job handle immediately. MUST NOT BLOCK."""

    def validate_options(self, options):
        """Merge caller options over the defaults, rejecting unknown names."""
        unknown = set(options) - set(self.option_defaults)
        if unknown:
            raise PredictionOptionError(
                '%s does not support: %s' % (self.id, ', '.join(sorted(unknown))))
        merged = dict(self.option_defaults)
        merged.update(options)
        return PredictionOptions(**merged)
```

- [ ] **Step 4: Run test to verify it passes**

```bash
pymol -ckqy testing/testing.py --run testing/tests/predict/predict_base.py
```

Expected: PASS, 8 tests.

- [ ] **Step 5: Commit**

```bash
git add modules/pymol/predictors testing/tests/predict/predict_base.py
git commit -m "feat(predict): error taxonomy, Predictor contract, chain parsing"
```

---

### Task 2: Registry

**Files:**
- Create: `modules/pymol/predictors/registry.py`
- Test: `testing/tests/predict/predict_registry.py`

**Interfaces:**
- Consumes: `Predictor` (Task 1), `PredictorNotFound` (Task 1).
- Produces: `register(predictor, replace=False)`, `get(predictor_id) -> Predictor`, `available() -> list[str]`, `unregister(predictor_id)`.

- [ ] **Step 1: Write the failing test**

Create `testing/tests/predict/predict_registry.py`:

```python
"""Tests for pymol.predictors.registry.

    pymol -ckqy testing/testing.py --run testing/tests/predict/predict_registry.py
"""
from pymol import testing


def make_stub(predictor_id, name='Stub'):
    from pymol.predictors.base import Predictor, PredictionSpec, parse_chains

    class Stub(Predictor):
        id = predictor_id
        name = name

        def check_available(self):
            return None

        def parse_spec(self, sequence, name=''):
            return PredictionSpec(parse_chains(sequence), name)

        def submit(self, spec, options, weights_path):
            return 'job-%s' % self.id

    return Stub()


class TestRegistry(testing.PyMOLTestCase):

    def setUp(self):
        testing.PyMOLTestCase.setUp(self)
        from pymol.predictors import registry
        self._saved = dict(registry._REGISTRY)

    def tearDown(self):
        from pymol.predictors import registry
        registry._REGISTRY.clear()
        registry._REGISTRY.update(self._saved)
        testing.PyMOLTestCase.tearDown(self)

    def testRegisterThenGet(self):
        from pymol.predictors import registry
        stub = make_stub('stub-a')
        registry.register(stub)
        self.assertIs(registry.get('stub-a'), stub)

    def testUnknownNameRaises(self):
        from pymol.predictors import registry
        from pymol.predictors.errors import PredictorNotFound
        self.assertRaises(PredictorNotFound, registry.get, 'nope')

    def testUnknownNameErrorListsWhatIsAvailable(self):
        from pymol.predictors import registry
        from pymol.predictors.errors import PredictorNotFound
        registry.register(make_stub('stub-a'))
        try:
            registry.get('nope')
        except PredictorNotFound as exc:
            self.assertIn('stub-a', str(exc))
        else:
            self.fail('expected PredictorNotFound')

    def testDuplicateIdRejectedUnlessReplacing(self):
        from pymol.predictors import registry
        from pymol.predictors.errors import PredictionError
        registry.register(make_stub('stub-a'))
        self.assertRaises(PredictionError, registry.register, make_stub('stub-a'))

    def testSwapImplementationsBehindTheInterface(self):
        from pymol.predictors import registry
        first, second = make_stub('swap'), make_stub('swap', name='Other')
        registry.register(first)
        registry.register(second, replace=True)
        self.assertIs(registry.get('swap'), second)
        # The caller's contract is unchanged across the swap.
        self.assertEqual(registry.get('swap').submit(None, None, None), 'job-swap')

    def testAvailableIsSorted(self):
        from pymol.predictors import registry
        registry._REGISTRY.clear()
        registry.register(make_stub('zeta'))
        registry.register(make_stub('alpha'))
        self.assertEqual(registry.available(), ['alpha', 'zeta'])

    def testRegisterRejectsNonPredictor(self):
        from pymol.predictors import registry
        from pymol.predictors.errors import PredictionError
        self.assertRaises(PredictionError, registry.register, object())

    def testRegisterRejectsMissingId(self):
        from pymol.predictors import registry
        from pymol.predictors.errors import PredictionError
        stub = make_stub(None)
        self.assertRaises(PredictionError, registry.register, stub)
```

- [ ] **Step 2: Run test to verify it fails**

```bash
pymol -ckqy testing/testing.py --run testing/tests/predict/predict_registry.py
```

Expected: FAIL — `No module named 'pymol.predictors.registry'`.

- [ ] **Step 3: Write the implementation**

Create `modules/pymol/predictors/registry.py`:

```python
"""Predictor registry: look a predictor up by id, swap implementations freely."""
from .base import Predictor
from .errors import PredictionError, PredictorNotFound

_REGISTRY = {}


def register(predictor, replace=False):
    """Make `predictor` discoverable under its id.

    Registering a duplicate id is an error unless replace=True, so that a typo
    cannot silently shadow a shipped predictor.
    """
    if not isinstance(predictor, Predictor):
        raise PredictionError(
            'not a Predictor: %r' % (type(predictor).__name__,))
    if not predictor.id or not isinstance(predictor.id, str):
        raise PredictionError('predictor has no id: %r' % (predictor,))
    if predictor.id in _REGISTRY and not replace:
        raise PredictionError(
            'predictor %r is already registered; pass replace=True to override'
            % predictor.id)
    _REGISTRY[predictor.id] = predictor
    return predictor


def get(predictor_id):
    """Return the predictor registered under `predictor_id`."""
    try:
        return _REGISTRY[predictor_id]
    except KeyError:
        raise PredictorNotFound(
            'unknown predictor %r; available: %s'
            % (predictor_id, ', '.join(available()) or '(none)'))


def available():
    """Registered predictor ids, sorted."""
    return sorted(_REGISTRY)


def unregister(predictor_id):
    """Remove a predictor. Missing ids are ignored."""
    _REGISTRY.pop(predictor_id, None)
```

- [ ] **Step 4: Run test to verify it passes**

```bash
pymol -ckqy testing/testing.py --run testing/tests/predict/predict_registry.py
```

Expected: PASS, 8 tests.

- [ ] **Step 5: Commit**

```bash
git add modules/pymol/predictors/registry.py testing/tests/predict/predict_registry.py
git commit -m "feat(predict): predictor registry with swappable implementations"
```

---

### Task 3: `WeightBundle`, cache paths, and sentinel-based validity

**Files:**
- Create: `modules/pymol/predictors/weights.py`
- Test: `testing/tests/predict/predict_weights_cache.py`

**Interfaces:**
- Consumes: errors from Task 1.
- Produces: `WeightBundle(id, version, url, sha256, size, members)`, `BundledSource(id, path)`, `WeightCache(root=None)` with `.root`, `.path_for(bundle)`, `.is_cached(bundle)`, `.default_root()`, `SENTINEL = '.ok'`.

Cache validity is the sentinel's *content*, not the directory's existence. That single
choice is what makes an interrupted download impossible to mistake for a valid cache — the
bug `fetch` has today, where `os.path.exists` accepts a truncated file.

- [ ] **Step 1: Write the failing test**

Create `testing/tests/predict/predict_weights_cache.py`:

```python
"""Tests for WeightCache path resolution and validity. No network.

    pymol -ckqy testing/testing.py --run testing/tests/predict/predict_weights_cache.py
"""
import os

from pymol import testing

SHA = 'a' * 64


def make_bundle(**kwargs):
    from pymol.predictors.weights import WeightBundle
    defaults = dict(id='stub', version='v1', url='https://example.invalid/b.zip',
                    sha256=SHA, size=123, members=('config.json', 'model.bin'))
    defaults.update(kwargs)
    return WeightBundle(**defaults)


class TestCachePaths(testing.PyMOLTestCase):

    def testPathForIsIdThenVersion(self):
        from pymol.predictors.weights import WeightCache
        with testing.mkdtemp() as root:
            cache = WeightCache(root)
            self.assertEqual(cache.path_for(make_bundle()),
                             os.path.join(root, 'stub', 'v1'))

    def testEnvOverrideWinsOverDefault(self):
        from pymol.predictors import weights
        old = os.environ.get('RAYMOL_WEIGHTS_DIR')
        try:
            os.environ['RAYMOL_WEIGHTS_DIR'] = '/tmp/raymol-weights-test'
            self.assertEqual(weights.WeightCache().root,
                             '/tmp/raymol-weights-test')
        finally:
            if old is None:
                os.environ.pop('RAYMOL_WEIGHTS_DIR', None)
            else:
                os.environ['RAYMOL_WEIGHTS_DIR'] = old

    def testDefaultRootIsUnderApplicationSupportOnDarwin(self):
        from pymol.predictors import weights
        root = weights.WeightCache.default_root(platform='darwin', home='/Users/x')
        self.assertEqual(
            root, '/Users/x/Library/Application Support/RayMol/weights')

    def testDefaultRootHasADotDirElsewhere(self):
        from pymol.predictors import weights
        self.assertEqual(weights.WeightCache.default_root(platform='linux',
                                                          home='/home/x'),
                         '/home/x/.raymol/weights')


class TestCacheValidity(testing.PyMOLTestCase):

    def testEmptyCacheIsNotCached(self):
        from pymol.predictors.weights import WeightCache
        with testing.mkdtemp() as root:
            self.assertFalse(WeightCache(root).is_cached(make_bundle()))

    def testDirectoryWithoutSentinelIsNotCached(self):
        """The interrupted-download case: files present, no sentinel."""
        from pymol.predictors.weights import WeightCache
        with testing.mkdtemp() as root:
            cache = WeightCache(root)
            target = cache.path_for(make_bundle())
            os.makedirs(target)
            with open(os.path.join(target, 'model.bin'), 'w') as handle:
                handle.write('partial')
            self.assertFalse(cache.is_cached(make_bundle()))

    def testSentinelWithWrongDigestIsNotCached(self):
        """Re-validation: a cache whose digest no longer matches is rejected."""
        from pymol.predictors.weights import WeightCache, SENTINEL
        with testing.mkdtemp() as root:
            cache = WeightCache(root)
            target = cache.path_for(make_bundle())
            os.makedirs(target)
            with open(os.path.join(target, SENTINEL), 'w') as handle:
                handle.write('b' * 64)
            self.assertFalse(cache.is_cached(make_bundle()))

    def testSentinelWithMatchingDigestIsCached(self):
        from pymol.predictors.weights import WeightCache, SENTINEL
        with testing.mkdtemp() as root:
            cache = WeightCache(root)
            target = cache.path_for(make_bundle())
            os.makedirs(target)
            with open(os.path.join(target, SENTINEL), 'w') as handle:
                handle.write(SHA)
            self.assertTrue(cache.is_cached(make_bundle()))


class TestBundledSource(testing.PyMOLTestCase):

    def testResolveReturnsAnExistingPath(self):
        """ensure() must be able to return a path it never downloaded (see #249)."""
        from pymol.predictors.weights import BundledSource
        with testing.mkdtemp() as root:
            source = BundledSource('mpnn', root)
            self.assertEqual(source.resolve(), root)

    def testResolveRaisesWhenAbsent(self):
        from pymol.predictors.weights import BundledSource
        from pymol.predictors.errors import WeightDownloadFailed
        source = BundledSource('mpnn', '/nonexistent/raymol/pack')
        self.assertRaises(WeightDownloadFailed, source.resolve)
```

- [ ] **Step 2: Run test to verify it fails**

```bash
pymol -ckqy testing/testing.py --run testing/tests/predict/predict_weights_cache.py
```

Expected: FAIL — `No module named 'pymol.predictors.weights'`.

- [ ] **Step 3: Write the implementation**

Create `modules/pymol/predictors/weights.py`:

```python
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
```

- [ ] **Step 4: Run test to verify it passes**

```bash
pymol -ckqy testing/testing.py --run testing/tests/predict/predict_weights_cache.py
```

Expected: PASS, 10 tests.

- [ ] **Step 5: Commit**

```bash
git add modules/pymol/predictors/weights.py testing/tests/predict/predict_weights_cache.py
git commit -m "feat(predict): weight cache paths and sentinel-based validity"
```

---

### Task 4: Streaming download, checksum, extraction, atomic publish

**Files:**
- Modify: `modules/pymol/predictors/weights.py`
- Test: `testing/tests/predict/predict_weights_download.py`

**Interfaces:**
- Consumes: `WeightBundle`, `WeightCache` (Task 3).
- Produces: `WeightCache.ensure(bundle, progress=None) -> str`, module-level `_urlopen` (the patch point tests replace), `CHUNK_BYTES`, `DEFAULT_TIMEOUT`.

- [ ] **Step 1: Write the failing test**

Create `testing/tests/predict/predict_weights_download.py`:

```python
"""Tests for WeightCache.ensure(). Offline: _urlopen is always patched.

    pymol -ckqy testing/testing.py --run testing/tests/predict/predict_weights_download.py
"""
import hashlib
import io
import os
import zipfile
from unittest.mock import patch

from pymol import testing


def make_zip(members=(('config.json', '{}'), ('model.bin', 'weights'))):
    """Return (zip_bytes, sha256_hex)."""
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, 'w') as archive:
        for name, text in members:
            archive.writestr(name, text)
    data = buf.getvalue()
    return data, hashlib.sha256(data).hexdigest()


class FakeResponse:
    """Minimal urlopen stand-in: a context manager with .read(n) and .headers."""

    def __init__(self, payload, chunk=None):
        self._stream = io.BytesIO(payload)
        self._chunk = chunk
        self.headers = {'Content-Length': str(len(payload))}

    def read(self, size=-1):
        if self._chunk is not None and size not in (0, None):
            size = min(size, self._chunk)
        return self._stream.read(size)

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def bundle_for(data, digest, **kwargs):
    from pymol.predictors.weights import WeightBundle
    defaults = dict(id='stub', version='v1', url='https://example.invalid/b.zip',
                    sha256=digest, size=len(data),
                    members=('config.json', 'model.bin'))
    defaults.update(kwargs)
    return WeightBundle(**defaults)


class TestEnsure(testing.PyMOLTestCase):

    def testDownloadsOnceThenServesFromCache(self):
        from pymol.predictors.weights import WeightCache
        data, digest = make_zip()
        bundle = bundle_for(data, digest)
        with testing.mkdtemp() as root:
            cache = WeightCache(root)
            with patch('pymol.predictors.weights._urlopen',
                       return_value=FakeResponse(data)) as opener:
                first = cache.ensure(bundle)
                self.assertEqual(opener.call_count, 1)
            with patch('pymol.predictors.weights._urlopen',
                       side_effect=AssertionError('must not re-download')) as opener:
                second = cache.ensure(bundle)
                self.assertEqual(opener.call_count, 0)
            self.assertEqual(first, second)
            self.assertEqual(first, cache.path_for(bundle))

    def testExtractionLayoutIsDeterministic(self):
        from pymol.predictors.weights import WeightCache, SENTINEL
        data, digest = make_zip()
        bundle = bundle_for(data, digest)
        with testing.mkdtemp() as root:
            cache = WeightCache(root)
            with patch('pymol.predictors.weights._urlopen',
                       return_value=FakeResponse(data)):
                path = cache.ensure(bundle)
            self.assertEqual(sorted(os.listdir(path)),
                             sorted([SENTINEL, 'config.json', 'model.bin']))
            with open(os.path.join(path, 'model.bin')) as handle:
                self.assertEqual(handle.read(), 'weights')

    def testChecksumMismatchLeavesNoCache(self):
        from pymol.predictors.weights import WeightCache
        from pymol.predictors.errors import WeightChecksumMismatch
        data, _ = make_zip()
        bundle = bundle_for(data, 'b' * 64)
        with testing.mkdtemp() as root:
            cache = WeightCache(root)
            with patch('pymol.predictors.weights._urlopen',
                       return_value=FakeResponse(data)):
                self.assertRaises(WeightChecksumMismatch, cache.ensure, bundle)
            self.assertFalse(os.path.exists(cache.path_for(bundle)))
            self.assertFalse(cache.is_cached(bundle))

    def testInterruptedDownloadProducesNoValidCache(self):
        from pymol.predictors.weights import WeightCache
        from pymol.predictors.errors import WeightDownloadFailed
        data, digest = make_zip()
        bundle = bundle_for(data, digest)

        class Dying(FakeResponse):
            def read(self, size=-1):
                raise IOError('connection reset')

        with testing.mkdtemp() as root:
            cache = WeightCache(root)
            with patch('pymol.predictors.weights._urlopen',
                       return_value=Dying(data)):
                self.assertRaises(WeightDownloadFailed, cache.ensure, bundle)
            self.assertFalse(cache.is_cached(bundle))
            self.assertFalse(os.path.exists(cache.path_for(bundle)))
            # And a later good attempt still succeeds.
            with patch('pymol.predictors.weights._urlopen',
                       return_value=FakeResponse(data)):
                self.assertTrue(os.path.isdir(cache.ensure(bundle)))

    def testWrongMembersRejected(self):
        from pymol.predictors.weights import WeightCache
        from pymol.predictors.errors import WeightBundleLayoutError
        data, digest = make_zip()
        bundle = bundle_for(data, digest,
                            members=('config.json', 'model.bin', 'manifest.json'))
        with testing.mkdtemp() as root:
            cache = WeightCache(root)
            with patch('pymol.predictors.weights._urlopen',
                       return_value=FakeResponse(data)):
                self.assertRaises(WeightBundleLayoutError, cache.ensure, bundle)
            self.assertFalse(cache.is_cached(bundle))

    def testStaleCacheIsReDownloaded(self):
        from pymol.predictors.weights import WeightCache, SENTINEL
        data, digest = make_zip()
        bundle = bundle_for(data, digest)
        with testing.mkdtemp() as root:
            cache = WeightCache(root)
            target = cache.path_for(bundle)
            os.makedirs(target)
            with open(os.path.join(target, SENTINEL), 'w') as handle:
                handle.write('c' * 64)          # digest from an older bundle
            with patch('pymol.predictors.weights._urlopen',
                       return_value=FakeResponse(data)) as opener:
                cache.ensure(bundle)
                self.assertEqual(opener.call_count, 1)
            self.assertTrue(cache.is_cached(bundle))

    def testNetworkErrorRaisesWeightDownloadFailed(self):
        from pymol.predictors.weights import WeightCache
        from pymol.predictors.errors import WeightDownloadFailed
        from urllib.error import URLError
        data, digest = make_zip()
        bundle = bundle_for(data, digest)
        with testing.mkdtemp() as root:
            with patch('pymol.predictors.weights._urlopen',
                       side_effect=URLError('no route to host')):
                self.assertRaises(WeightDownloadFailed,
                                  WeightCache(root).ensure, bundle)

    def testUnwritableRootRaisesWeightCacheUnwritable(self):
        from pymol.predictors.weights import WeightCache
        from pymol.predictors.errors import WeightCacheUnwritable
        data, digest = make_zip()
        bundle = bundle_for(data, digest)
        cache = WeightCache('/dev/null/not-a-dir')
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(data)):
            self.assertRaises(WeightCacheUnwritable, cache.ensure, bundle)

    def testProgressIsReportedForDownloadAndExtract(self):
        from pymol.predictors.weights import WeightCache
        data, digest = make_zip()
        bundle = bundle_for(data, digest)
        seen = []
        with testing.mkdtemp() as root:
            with patch('pymol.predictors.weights._urlopen',
                       return_value=FakeResponse(data, chunk=4)):
                WeightCache(root).ensure(
                    bundle, progress=lambda phase, frac: seen.append((phase, frac)))
        phases = [phase for phase, _ in seen]
        self.assertIn('download', phases)
        self.assertIn('extract', phases)
        self.assertEqual(seen[-1], ('extract', 1.0))
        for _, frac in seen:
            self.assertTrue(0.0 <= frac <= 1.0, seen)
```

- [ ] **Step 2: Run test to verify it fails**

```bash
pymol -ckqy testing/testing.py --run testing/tests/predict/predict_weights_download.py
```

Expected: FAIL — `AttributeError: module 'pymol.predictors.weights' has no attribute '_urlopen'`.

- [ ] **Step 3: Write the implementation**

Add to the imports at the top of `modules/pymol/predictors/weights.py`:

```python
import errno
import hashlib
import shutil
import zipfile
from urllib.error import URLError
from urllib.request import Request, urlopen

from .errors import (WeightBundleLayoutError, WeightCacheUnwritable,
                     WeightChecksumMismatch, WeightDownloadFailed)
```

Then add, after the `SENTINEL` definition:

```python
#: Patch point for tests. Never call urllib.request.urlopen directly below.
_urlopen = urlopen

#: Stream in 1 MiB chunks: the bundle is ~533 MiB and must never be buffered whole.
CHUNK_BYTES = 1 << 20

DEFAULT_TIMEOUT = 30.0
```

Append these methods to `WeightCache`:

```python
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
```

And these module-level helpers at the end of the file:

```python
def _unlink(path):
    try:
        os.unlink(path)
    except OSError:
        pass


def _rmtree(path):
    shutil.rmtree(path, ignore_errors=True)
```

- [ ] **Step 4: Run test to verify it passes**

```bash
pymol -ckqy testing/testing.py --run testing/tests/predict/predict_weights_download.py
```

Expected: PASS, 9 tests. Then confirm Task 3 still passes:

```bash
pymol -ckqy testing/testing.py --run testing/tests/predict/predict_weights_cache.py
```

- [ ] **Step 5: Commit**

```bash
git add modules/pymol/predictors/weights.py testing/tests/predict/predict_weights_download.py
git commit -m "feat(predict): streaming checksummed download with atomic publish"
```

---

### Task 5: Concurrency — one download, no corruption

**Files:**
- Modify: `modules/pymol/predictors/weights.py`
- Test: `testing/tests/predict/predict_weights_concurrency.py`

**Interfaces:**
- Consumes: `WeightCache.ensure` (Task 4).
- Produces: `WeightCache.LOCK_TIMEOUT`, `WeightCache.LOCK_STALE_SECONDS`, internal `_acquire_lock` / `_release_lock`.

- [ ] **Step 1: Write the failing test**

Create `testing/tests/predict/predict_weights_concurrency.py`:

```python
"""Concurrency and locking for WeightCache.ensure().

    pymol -ckqy testing/testing.py --run testing/tests/predict/predict_weights_concurrency.py
"""
import os
import threading
import time
from unittest.mock import patch

from pymol import testing

from predict_weights_download import FakeResponse, bundle_for, make_zip


class TestConcurrency(testing.PyMOLTestCase):

    def testTwoThreadsProduceExactlyOneDownload(self):
        from pymol.predictors.weights import WeightCache
        data, digest = make_zip()
        bundle = bundle_for(data, digest)
        calls = []
        barrier = threading.Barrier(2)

        def slow_open(request, timeout=None):
            calls.append(request)
            time.sleep(0.2)
            return FakeResponse(data)

        with testing.mkdtemp() as root:
            cache = WeightCache(root)
            results = []

            def run():
                barrier.wait()
                results.append(cache.ensure(bundle))

            with patch('pymol.predictors.weights._urlopen', slow_open):
                threads = [threading.Thread(target=run) for _ in range(2)]
                for thread in threads:
                    thread.start()
                for thread in threads:
                    thread.join()

            self.assertEqual(len(calls), 1, 'exactly one download expected')
            self.assertEqual(results, [cache.path_for(bundle)] * 2)
            self.assertTrue(cache.is_cached(bundle))

    def testStaleLockIsBroken(self):
        from pymol.predictors.weights import WeightCache
        data, digest = make_zip()
        bundle = bundle_for(data, digest)
        with testing.mkdtemp() as root:
            cache = WeightCache(root)
            os.makedirs(cache._incoming())
            lock = cache._lock_path(bundle)
            with open(lock, 'w') as handle:
                handle.write('999999')
            old = time.time() - (cache.LOCK_STALE_SECONDS + 60)
            os.utime(lock, (old, old))
            with patch('pymol.predictors.weights._urlopen',
                       return_value=FakeResponse(data)):
                self.assertTrue(os.path.isdir(cache.ensure(bundle)))

    def testLockIsReleasedAfterFailure(self):
        from pymol.predictors.weights import WeightCache
        from pymol.predictors.errors import WeightChecksumMismatch
        data, _ = make_zip()
        bundle = bundle_for(data, 'd' * 64)
        with testing.mkdtemp() as root:
            cache = WeightCache(root)
            with patch('pymol.predictors.weights._urlopen',
                       return_value=FakeResponse(data)):
                self.assertRaises(WeightChecksumMismatch, cache.ensure, bundle)
            self.assertFalse(os.path.exists(cache._lock_path(bundle)))
```

> The `from predict_weights_download import ...` line works because the runner imports
> test files by path and `PyMOLTestCase.setUp` chdirs to the test file's own directory,
> which is therefore on `sys.path` for a sibling import.

- [ ] **Step 2: Run test to verify it fails**

```bash
pymol -ckqy testing/testing.py --run testing/tests/predict/predict_weights_concurrency.py
```

Expected: FAIL — `AttributeError: 'WeightCache' object has no attribute '_lock_path'`.

- [ ] **Step 3: Write the implementation**

Add `import time` to the imports in `weights.py`, then add these two class attributes to
`WeightCache`:

```python
    #: How long ensure() waits for another process's download before giving up.
    LOCK_TIMEOUT = 900.0
    #: A lock file older than this is assumed abandoned by a dead process.
    LOCK_STALE_SECONDS = 1800.0
```

Add the lock helpers to `WeightCache`:

```python
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
                try:
                    age = time.time() - os.path.getmtime(lock)
                except OSError:
                    continue                      # vanished; retry immediately
                if age > self.LOCK_STALE_SECONDS:
                    _unlink(lock)                 # owner is gone
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
```

Replace everything in `ensure` **after** the `BundledSource` check and the `is_cached` fast
path — i.e. from `incoming = self._incoming()` to the closing `return target` — with the
locked version. The two early returns stay exactly as they are; `_makedirs` must remain
before `_acquire_lock` so an unwritable root still raises `WeightCacheUnwritable` rather than
failing to create the lock:

```python
        incoming = self._incoming()
        self._makedirs(incoming)
        if not self._acquire_lock(bundle):
            return self.path_for(bundle)         # someone else finished it

        part = os.path.join(incoming, bundle.sha256 + '.part')
        staging = os.path.join(incoming, bundle.sha256 + '.d')
        target = self.path_for(bundle)
        try:
            # Re-check under the lock: the winner may have published while we
            # were blocked, in which case re-downloading is pure waste.
            if self.is_cached(bundle):
                return target
            self._download(bundle, part, progress)
            self._extract(bundle, part, staging, progress)
            self._publish(bundle, staging, target)
        finally:
            _rmtree(staging)
            _unlink(part)
            self._release_lock(bundle)
        return target
```

- [ ] **Step 4: Run test to verify it passes**

```bash
pymol -ckqy testing/testing.py --run testing/tests/predict/predict_weights_concurrency.py
pymol -ckqy testing/testing.py --run testing/tests/predict/predict_weights_download.py
```

Expected: PASS, 3 tests and 9 tests.

- [ ] **Step 5: Commit**

```bash
git add modules/pymol/predictors/weights.py testing/tests/predict/predict_weights_concurrency.py
git commit -m "feat(predict): lock the weight download so concurrent runs fetch once"
```

---

### Task 6: `cmd.predict` surface, wiring, and the stub predictor end-to-end

**Files:**
- Create: `modules/pymol/predicting.py`
- Modify: `modules/pymol/api.py:30`
- Modify: `modules/pymol/keywords.py:204`
- Test: `testing/tests/predict/predict_api.py`

**Interfaces:**
- Consumes: registry (Task 2), `WeightCache.ensure` (Tasks 3-5), `Predictor` (Task 1).
- Produces: `cmd.predict`, `cmd.predict_status`, `cmd.predict_cancel`, `cmd.predict_result`, `cmd.predict_weights`, and `predicting.weight_cache()`.

- [ ] **Step 1: Write the failing test**

Create `testing/tests/predict/predict_api.py`:

```python
"""End-to-end flow through cmd.predict with a stub predictor. No Swift, no network.

    pymol -ckqy testing/testing.py --run testing/tests/predict/predict_api.py
"""
import os
from unittest.mock import patch

from pymol import cmd, testing

from predict_weights_download import FakeResponse, make_zip


class StubJob:
    def __init__(self, spec, options, weights_path):
        self.job_id = 'stub-1'
        self.spec = spec
        self.options = options
        self.weights_path = weights_path
        self._pdb = (
            'ATOM      1  N   ALA A   1       0.000   0.000   0.000  1.00  0.00           N\n'
            'ATOM      2  CA  ALA A   1       1.458   0.000   0.000  1.00  0.00           C\n'
            'END\n')

    def status(self):
        return {'state': 'done', 'phase': 'done', 'fraction': 1.0,
                'error': None, 'result_path': self.result_path}

    @property
    def result_path(self):
        path = os.path.join(self.weights_path, 'stub.pdb')
        with open(path, 'w') as handle:
            handle.write(self._pdb)
        return path

    def cancel(self):
        self.cancelled = True


def install_stub(cache_root, digest, size):
    from pymol.predictors import registry
    from pymol.predictors.base import Predictor, PredictionSpec, parse_chains
    from pymol.predictors.weights import WeightBundle

    class Stub(Predictor):
        id = 'stub'
        name = 'Stub predictor'
        weight_bundle = WeightBundle(
            id='stub', version='v1', url='https://example.invalid/b.zip',
            sha256=digest, size=size, members=('config.json', 'model.bin'))
        option_defaults = {'recycling_steps': 3, 'diffusion_steps': 200, 'seed': 0}

        def check_available(self):
            return None

        def parse_spec(self, sequence, name=''):
            return PredictionSpec(parse_chains(sequence), name)

        def submit(self, spec, options, weights_path):
            return StubJob(spec, options, weights_path)

    registry.register(Stub(), replace=True)
    return Stub


class PredictAPITest(testing.PyMOLTestCase):

    def setUp(self):
        testing.PyMOLTestCase.setUp(self)
        from pymol.predictors import registry
        self._saved = dict(registry._REGISTRY)
        self._tmp = testing.mkdtemp()
        self.root = self._tmp.__enter__()
        os.environ['RAYMOL_WEIGHTS_DIR'] = self.root
        self.data, self.digest = make_zip()
        install_stub(self.root, self.digest, len(self.data))

    def tearDown(self):
        from pymol.predictors import registry
        registry._REGISTRY.clear()
        registry._REGISTRY.update(self._saved)
        os.environ.pop('RAYMOL_WEIGHTS_DIR', None)
        self._tmp.__exit__(None, None, None)
        testing.PyMOLTestCase.tearDown(self)

    def testFullFlowDeclareFetchRunLoad(self):
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data)) as opener:
            job = cmd.predict('stub', 'AA', name='pred')
            self.assertEqual(opener.call_count, 1, 'weights fetched lazily, once')
        self.assertEqual(job.status()['state'], 'done')
        name = cmd.predict_result(job.job_id, 'pred')
        self.assertIn('pred', cmd.get_names('objects'))
        self.assertEqual(name, 'pred')
        self.assertEqual(cmd.count_atoms('pred'), 2)

    def testSecondRunDoesNotReDownload(self):
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data)):
            cmd.predict('stub', 'AA')
        with patch('pymol.predictors.weights._urlopen',
                   side_effect=AssertionError('must not re-download')):
            cmd.predict('stub', 'AA')

    def testUnknownPredictorRaises(self):
        from pymol.predictors.errors import PredictorNotFound
        self.assertRaises(PredictorNotFound, cmd.predict, 'nope', 'AA')

    def testOptionsReachThePredictor(self):
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data)):
            job = cmd.predict('stub', 'AA', diffusion_steps=300, seed=7)
        self.assertEqual(job.options.diffusion_steps, 300)
        self.assertEqual(job.options.seed, 7)
        self.assertEqual(job.options.recycling_steps, 3)

    def testUnknownOptionRejected(self):
        from pymol.predictors.errors import PredictionOptionError
        self.assertRaises(PredictionOptionError,
                          cmd.predict, 'stub', 'AA', diffusion_samples=4)

    def testMalformedInputRejected(self):
        from pymol.predictors.errors import PredictionInputError
        self.assertRaises(PredictionInputError, cmd.predict, 'stub', '')

    def testUnavailablePredictorRaisesBeforeAnyDownload(self):
        from pymol.predictors import registry
        from pymol.predictors.errors import PredictorUnavailable
        predictor = registry.get('stub')
        with patch.object(type(predictor), 'check_available',
                          side_effect=PredictorUnavailable('no host')):
            with patch('pymol.predictors.weights._urlopen',
                       side_effect=AssertionError('must not download')):
                self.assertRaises(PredictorUnavailable,
                                  cmd.predict, 'stub', 'AA')

    def testPredictWeightsReportsCacheState(self):
        info = cmd.predict_weights('stub')
        self.assertFalse(info['stub']['cached'])
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data)):
            cmd.predict('stub', 'AA')
        self.assertTrue(cmd.predict_weights('stub')['stub']['cached'])

    def testMultimerUsesSlashSeparator(self):
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data)):
            job = cmd.predict('stub', 'AA/GG')
        self.assertEqual(job.spec.chains, (('A', 'AA'), ('B', 'GG')))

    def testPredictIsRegisteredAsACommandKeyword(self):
        self.assertIn('predict', cmd.keyword)
        self.assertIn('predict_status', cmd.keyword)
        self.assertIn('predict_cancel', cmd.keyword)
```

- [ ] **Step 2: Run test to verify it fails**

```bash
pymol -ckqy testing/testing.py --run testing/tests/predict/predict_api.py
```

Expected: FAIL — `AttributeError: module 'pymol.cmd' has no attribute 'predict'`.

- [ ] **Step 3: Write the implementation**

Create `modules/pymol/predicting.py`:

```python
"""Structure prediction: cmd.predict and friends.

Thin by design. Argument marshalling and session interaction only; the registry,
the weight cache, and the predictors themselves live in pymol.predictors.

Every function ends its signature with _self=cmd. That is load-bearing:
pymol2/cmd2.py binds _self only when it appears in the argspec, and otherwise
copies the function verbatim so it silently drives the GLOBAL instance.
"""
import sys

from . import colorprinting
from .predictors import registry
from .predictors.base import PredictionOptions  # noqa: F401  (re-export for callers)
from .predictors.weights import WeightCache

cmd = sys.modules["pymol.cmd"]

_JOBS = {}
_CACHE = None


def weight_cache():
    """Process-wide WeightCache. Rebuilt if RAYMOL_WEIGHTS_DIR changes."""
    global _CACHE
    import os
    root = os.environ.get('RAYMOL_WEIGHTS_DIR')
    if _CACHE is None or (root and _CACHE.root != root):
        _CACHE = WeightCache(root)
    return _CACHE


def predict(predictor, sequence, name='', recycling_steps=3, diffusion_steps=200,
            seed=0, quiet=1, _self=cmd):
    """
DESCRIPTION

    "predict" folds one or more sequences with a registered structure predictor.
    It returns immediately with a job handle; poll it with "predict_status" and
    load the result with "predict_result".

USAGE

    predict predictor, sequence [, name [, recycling_steps [, diffusion_steps
        [, seed ]]]]

ARGUMENTS

    predictor = str: id of a registered predictor, e.g. boltz2

    sequence = str: one-letter sequence. Use "/" to separate chains of a
    multimer -- NOT a comma, which the command parser treats as an argument
    separator. Chains are assigned ids A, B, C...

    name = str: object name for the loaded result {default: <predictor>_pred}

    recycling_steps = int: trunk recycling passes {default: 3}

    diffusion_steps = int: reverse-diffusion steps; higher is slower and more
    accurate {default: 200}

    seed = int: random seed {default: 0}

EXAMPLES

    predict boltz2, MKTAYIAKQRQISFVKSHFSRQLEERLGLIEVQ
    predict boltz2, MKTAY/GSHMA, name=dimer, diffusion_steps=300

NOTES

    Defaults follow upstream Boltz. Options a predictor does not implement are
    rejected rather than ignored, so a typo cannot silently degrade a result.

SEE ALSO

    predict_status, predict_result, predict_cancel, predict_weights
    """
    predictor_obj = registry.get(predictor)
    predictor_obj.check_available()

    spec = predictor_obj.parse_spec(sequence, name=name or (predictor + '_pred'))
    options = predictor_obj.validate_options(dict(
        recycling_steps=int(recycling_steps),
        diffusion_steps=int(diffusion_steps),
        seed=int(seed)))

    weights_path = None
    if predictor_obj.weight_bundle is not None:
        def report(phase, fraction):
            if not int(quiet):
                colorprinting.info(' predict: %s %d%%'
                                   % (phase, int(fraction * 100)))
        weights_path = weight_cache().ensure(predictor_obj.weight_bundle,
                                            progress=report)

    job = predictor_obj.submit(spec, options, weights_path)
    _JOBS[job.job_id] = job
    if not int(quiet):
        colorprinting.info(' predict: job %s submitted' % job.job_id)
    return job


def predict_status(job_id='', quiet=1, _self=cmd):
    """
DESCRIPTION

    "predict_status" reports the state of one prediction job, or of all of them.

USAGE

    predict_status [ job_id ]

SEE ALSO

    predict
    """
    if job_id:
        jobs = {job_id: _job(job_id)}
    else:
        jobs = dict(_JOBS)
    out = {}
    for key, job in jobs.items():
        out[key] = job.status()
        if not int(quiet):
            colorprinting.info(' predict: %s %s %s' % (
                key, out[key].get('state'), out[key].get('phase')))
    return out


def predict_cancel(job_id, quiet=1, _self=cmd):
    """
DESCRIPTION

    "predict_cancel" asks a running prediction to stop.

USAGE

    predict_cancel job_id

SEE ALSO

    predict
    """
    _job(job_id).cancel()
    if not int(quiet):
        colorprinting.info(' predict: cancel requested for %s' % job_id)


def predict_result(job_id, name='', quiet=1, _self=cmd):
    """
DESCRIPTION

    "predict_result" loads a finished prediction into the session.

USAGE

    predict_result job_id [, name ]

SEE ALSO

    predict, predict_status
    """
    from .predictors.errors import PredictionError
    job = _job(job_id)
    status = job.status()
    if status.get('state') != 'done':
        raise PredictionError(
            'job %s is %s, not done' % (job_id, status.get('state')))
    path = status.get('result_path')
    if not path:
        raise PredictionError('job %s produced no structure' % job_id)
    object_name = name or getattr(job.spec, 'name', None) or job_id
    _self.load(path, object_name)
    if not int(quiet):
        colorprinting.info(' predict: loaded %s' % object_name)
    return object_name


def predict_weights(predictor='', download=0, quiet=1, _self=cmd):
    """
DESCRIPTION

    "predict_weights" reports -- and optionally pre-fetches -- each predictor's
    cached model weights.

USAGE

    predict_weights [ predictor [, download ]]

SEE ALSO

    predict
    """
    cache = weight_cache()
    ids = [predictor] if predictor else registry.available()
    out = {}
    for pid in ids:
        bundle = registry.get(pid).weight_bundle
        if bundle is None:
            out[pid] = {'cached': True, 'path': None, 'bundle': None}
            continue
        if int(download) and not cache.is_cached(bundle):
            cache.ensure(bundle)
        out[pid] = {'cached': bool(cache.is_cached(bundle)),
                    'path': cache.path_for(bundle),
                    'bundle': bundle.id}
        if not int(quiet):
            colorprinting.info(' predict: %s weights cached=%s at %s' % (
                pid, out[pid]['cached'], out[pid]['path']))
    return out


def _job(job_id):
    from .predictors.errors import PredictionError
    try:
        return _JOBS[job_id]
    except KeyError:
        raise PredictionError('unknown prediction job %r' % job_id)
```

Modify `modules/pymol/api.py` — insert at line 30, in the blank gap after the `importing`
block ends with `space` on line 29 and before the `#---` separator preceding `creating`:

```python

#--------------------------------------------------------------------
from . import predicting
from .predicting import \
      predict,              \
      predict_status,       \
      predict_cancel,       \
      predict_result,       \
      predict_weights
```

Modify `modules/pymol/keywords.py` — insert after the `'pi_interactions'` row (line 204)
and before `'pop'` (line 205), matching the existing column alignment:

```python
        'predict'        : [ self_cmd.predict         , 0 , 0 , ''  , parsing.STRICT ],
        'predict_status' : [ self_cmd.predict_status  , 0 , 0 , ''  , parsing.STRICT ],
        'predict_cancel' : [ self_cmd.predict_cancel  , 0 , 0 , ''  , parsing.STRICT ],
        'predict_result' : [ self_cmd.predict_result  , 0 , 0 , ''  , parsing.STRICT ],
        'predict_weights': [ self_cmd.predict_weights , 0 , 0 , ''  , parsing.STRICT ],
```

- [ ] **Step 4: Run test to verify it passes**

```bash
pymol -ckqy testing/testing.py --run testing/tests/predict/predict_api.py
```

Expected: PASS, 10 tests. Then verify the command line works and the whole suite is green:

```bash
pymol -ckq -d 'print(cmd.predict_weights())'
```

- [ ] **Step 5: Commit**

```bash
git add modules/pymol/predicting.py modules/pymol/api.py modules/pymol/keywords.py testing/tests/predict/predict_api.py
git commit -m "feat(predict): cmd.predict surface with per-call inference options"
```

---

### Task 7: Template, documentation, and CI wiring

**Files:**
- Create: `modules/pymol/predictors/_template.py`
- Create: `docs/predictors.md`
- Modify: `.github/workflows/raymol-embedded-tests.yml` (terminal line of the `--run` list)
- Test: `testing/tests/predict/predict_template.py`

**Interfaces:**
- Consumes: everything from Tasks 1-6.
- Produces: no new runtime API. `_template.py` must import cleanly and must NOT self-register.

- [ ] **Step 1: Rebase onto master first**

The `--run` list is hand-maintained and this branch was cut at `db718f11c`, which predates
PR #259. Editing a stale copy would silently revert seven test files back out of CI.

```bash
git fetch origin master && git rebase origin/master
```

Then confirm the list is the post-#259 one, terminating at `raymol/scene_ttt.py`:

```bash
grep -c 'testing/tests/.*\.py' .github/workflows/raymol-embedded-tests.yml
```

Expected: `28`.

- [ ] **Step 2: Write the failing test**

Create `testing/tests/predict/predict_template.py`:

```python
"""The predictor template must stay importable and unregistered.

    pymol -ckqy testing/testing.py --run testing/tests/predict/predict_template.py
"""
from pymol import testing


class TestTemplate(testing.PyMOLTestCase):

    def testTemplateImportsCleanly(self):
        from pymol.predictors import _template
        self.assertTrue(hasattr(_template, 'PREDICTOR'))

    def testTemplateIsNotRegistered(self):
        from pymol.predictors import _template, registry
        self.assertNotIn(_template.TemplatePredictor.id, registry.available())

    def testTemplateSubclassesPredictorAndRefusesToRun(self):
        from pymol.predictors import _template
        from pymol.predictors.base import Predictor
        from pymol.predictors.errors import (PredictionInputError,
                                             PredictorUnavailable)
        self.assertTrue(isinstance(_template.PREDICTOR, Predictor))
        self.assertRaises(PredictorUnavailable, _template.PREDICTOR.check_available)
        self.assertRaises(PredictionInputError, _template.PREDICTOR.parse_spec, 'AA')

    def testTemplateRejectsUnknownOptions(self):
        from pymol.predictors import _template
        from pymol.predictors.errors import PredictionOptionError
        self.assertRaises(PredictionOptionError,
                          _template.PREDICTOR.validate_options,
                          {'diffusion_samples': 4})

    def testTemplateAcceptsTheDocumentedOptions(self):
        from pymol.predictors import _template
        options = _template.PREDICTOR.validate_options({'diffusion_steps': 300})
        self.assertEqual(options.diffusion_steps, 300)
        self.assertEqual(options.recycling_steps, 3)
```

- [ ] **Step 3: Run test to verify it fails**

```bash
pymol -ckqy testing/testing.py --run testing/tests/predict/predict_template.py
```

Expected: FAIL — `No module named 'pymol.predictors._template'`.

- [ ] **Step 4: Write the template, the docs, and the CI line**

Create `modules/pymol/predictors/_template.py`:

```python
"""Skeleton for a new RayMol structure predictor.

Copy to modules/pymol/predictors/<your_id>.py, then follow docs/predictors.md.
The leading underscore keeps _register_builtins() from picking this up.
"""
from .base import Predictor
from .errors import PredictionInputError, PredictorUnavailable
from .weights import WeightBundle


class TemplatePredictor(Predictor):

    # -- Identity ----------------------------------------------------------
    id = 'template'                  # stable selector; never change once shipped
    name = 'Template predictor'      # human-readable, for listings

    # -- Weights -----------------------------------------------------------
    # None if the method needs no weights. sha256 and size are of the ZIP's
    # bytes; `members` is the exact expected set of archive-root entries, which
    # WeightCache asserts after extraction because a predictor handed a
    # partially-extracted bundle usually misbehaves instead of failing.
    weight_bundle = WeightBundle(
        id='template-v1',
        version='v1',
        url='https://github.com/OWNER/REPO/releases/download/TAG/bundle.zip',
        sha256='0' * 64,
        size=0,
        members=('config.json', 'model.safetensors'),
    )

    # -- Options -----------------------------------------------------------
    # Only what the backend genuinely honours. Anything omitted is REJECTED by
    # validate_options(), never silently ignored.
    option_defaults = {'recycling_steps': 3, 'diffusion_steps': 200, 'seed': 0}

    # -- Capability --------------------------------------------------------
    def check_available(self):
        """Raise PredictorUnavailable if this cannot run here and now.

        Check what is true before any work starts: platform, OS version, whether
        a host capable of running the backend is present. Do NOT check whether
        weights are cached -- that is the weight manager's job, and it is
        allowed to fix it by downloading.
        """
        raise PredictorUnavailable('%s: not implemented' % self.id)

    # -- Input validation --------------------------------------------------
    def parse_spec(self, sequence, name=''):
        """Return a PredictionSpec, or raise PredictionInputError.

        Reject here, loudly, rather than letting the backend silently drop
        residues it does not understand. Use base.parse_chains() for the "/"
        separator and single-uppercase chain ids.
        """
        raise PredictionInputError('%s: not implemented' % self.id)

    # -- Run ---------------------------------------------------------------
    def submit(self, spec, options, weights_path):
        """Start the run and return a job handle immediately.

        MUST NOT BLOCK. cmd.predict is reachable from the console, which runs on
        the main thread; blocking here stalls the render loop for the whole
        inference. Return a handle whose status() is a cheap poll and which
        exposes job_id, status(), cancel().
        """
        raise NotImplementedError


PREDICTOR = TemplatePredictor()
```

Create `docs/predictors.md`:

```markdown
# Adding a structure predictor

RayMol's prediction backend is a registry of interchangeable predictors plus a shared,
predictor-agnostic weight cache. Adding a method means adding one module and one line.

See [the design](superpowers/specs/2026-08-11-structure-prediction-backend-design.md) for why
it is shaped this way.

## Layout

| File | Responsibility |
|---|---|
| `modules/pymol/predicting.py` | the `cmd.*` surface; you should not need to touch it |
| `modules/pymol/predictors/base.py` | `Predictor` contract, `PredictionSpec`, `PredictionOptions` |
| `modules/pymol/predictors/weights.py` | `WeightBundle`, `WeightCache` |
| `modules/pymol/predictors/registry.py` | `register` / `get` / `available` |
| `modules/pymol/predictors/_template.py` | copy-me skeleton |

## Steps

1. **Copy the template** to `modules/pymol/predictors/<your_id>.py` and pick a permanent
   `id`. It appears in user scripts and saved sessions: treat it as API.

2. **Write the tests first.** Add `testing/tests/predict/predict_<your_id>.py` subclassing
   `pymol.testing.PyMOLTestCase`. Do **not** name it `test_*.py` unless you want the pytest
   lane — the runner routes on that prefix. Mock the network by patching
   `pymol.predictors.weights._urlopen`; never reach a real server. Run it with:

   ```
   pymol -ckqy testing/testing.py --run testing/tests/predict/predict_<your_id>.py
   ```

3. **Declare the weight bundle.** Publish the zip, then record the sha256 **of the bytes you
   uploaded** — re-exporting a quantized model is not guaranteed to reproduce them bitwise,
   so never hash a local rebuild and assume it matches. `members` must be the exact
   archive-root entry set.

4. **Implement `check_available`** so the predictor disappears cleanly where it cannot run
   rather than failing mid-run. Platform, OS floor, host presence — not weight state.

5. **Implement `parse_spec` to reject, not repair.** If the backend silently ignores input it
   does not support, catching that is your job: check what it does with a ligand, a nucleic
   acid, an `X`, and an empty chain, and raise for each. boltz-mlx is the cautionary case —
   its `fromResidues` *excludes* non-canonical residues with a diagnostic and returns
   success, so a selection containing a ligand yields a protein-only complex with the ligand
   quietly gone.

6. **Implement `validate_options` to reject unknown options.** The base class does this for
   you if `option_defaults` is accurate. Accepting and ignoring a quality knob produces
   results the user believes are something they are not.

7. **`submit` must not block.** `cmd.predict` is reachable from the console, which runs on
   the main thread.

8. **Register it** in `predictors/__init__.py`'s `_register_builtins()` — the only file that
   changes outside your own.

9. **Make CI run your tests.** `.github/workflows/raymol-embedded-tests.yml` hand-enumerates
   test paths. Adding the `testing/tests/predict` directory covers new files automatically;
   if you add a path by hand, **rebase onto master first** — that list has silently dropped
   files before.

10. **If your predictor adds Swift**, hand-compile **both** the macOS and iOS slices before
    merging. No CI job compiles Swift, and the shared target has broken each platform from
    the other before.
```

Modify `.github/workflows/raymol-embedded-tests.yml`: add a trailing ` \` to the current
terminal line of the `--run` list (`testing/tests/raymol/scene_ttt.py`) and append one
directory line at the same 14-space indent:

```yaml
              testing/tests/raymol/scene_ttt.py \
              testing/tests/predict
```

A directory argument is globbed by `testing/testing.py:687-689`, so new files inside
`predict/` run automatically. This is the only variant that does not re-create the
enumeration gotcha.

- [ ] **Step 5: Run the whole predict suite the way CI will**

```bash
pymol -ckqy testing/testing.py --run testing/tests/predict
```

Expected: PASS, all files, 0 failures. Files share an interpreter, so run the directory
rather than individual files to catch cross-test state leaks.

- [ ] **Step 6: Commit**

```bash
git add modules/pymol/predictors/_template.py docs/predictors.md .github/workflows/raymol-embedded-tests.yml testing/tests/predict/predict_template.py
git commit -m "feat(predict): predictor template, docs, and CI wiring"
```

**Part A is complete and shippable here.** Open the PR: it delivers #224's stated backend
scope, runs offline, and contains no Swift.

---

# Part B — boltz-mlx end to end (macOS)

**Two prerequisites are out-of-band and block Part B entirely. Do them first.**

| Prerequisite | Why it blocks |
|---|---|
| Tag `javierbq/boltz-mlx` `v0.1.0` | The repo has **zero tags**; SwiftPM has nothing to pin |
| Mint + publish the artifact zip, record its sha256 | Task 10's `WeightBundle` cannot be filled in without it |

### Task 8: Promote boltz-mlx's structure writer (in `javierbq/boltz-mlx`)

**Files (in the boltz-mlx checkout, not RayMol):**
- Create: `Sources/BoltzMLX/Write/StructureWriter.swift`
- Modify: `tests/BoltzMLXTests/MSAEndToEndTests.swift:235-274` (delete the private helper, call the library)
- Test: `tests/BoltzMLXTests/StructureWriterTests.swift`

**Interfaces:**
- Consumes: `BoltzStructure`, `CanonicalStructure`, `AAResidueTemplates` — all already public.
- Produces: `public enum StructureWriter { public static func pdb(structure: BoltzStructure, canonical: CanonicalStructure) throws -> String }`.

This is a **promotion, not new code.** `MSAEndToEndTests.swift:239-272` already implements the
identity walk against the right public types and the coordinate order the predictor
guarantees. Copy it, then close the gaps below.

- [ ] **Step 1: Write the failing test**

Create `tests/BoltzMLXTests/StructureWriterTests.swift`:

```swift
import XCTest
@testable import BoltzMLX

final class StructureWriterTests: XCTestCase {

  /// Two residues, one chain: ALA (5 heavy atoms) then GLY (4).
  private func fixture() throws -> (BoltzStructure, CanonicalStructure) {
    let canonical = try CanonicalStructure.fromSequences([("A", "AG")])
    let count = canonical.orderedResidues.reduce(0) { total, residue in
      total + (AAResidueTemplates.template(threeLetter: residue.threeLetter)?.atoms.count ?? 0)
    }
    let coords = (0..<count).map { SIMD3<Float>(Float($0), 0, 0) }
    return (BoltzStructure(coordinates: coords,
                           atomMask: Array(repeating: true, count: count)), canonical)
  }

  func testEmitsOneAtomRecordPerTemplateAtom() throws {
    let (structure, canonical) = try fixture()
    let text = try StructureWriter.pdb(structure: structure, canonical: canonical)
    let atoms = text.split(separator: "\n").filter { $0.hasPrefix("ATOM  ") }
    XCTAssertEqual(atoms.count, structure.coordinates.count)
  }

  /// hostResSeq is 0-based for sequence-derived structures. Writing it verbatim
  /// offsets every model by one residue against a crystal, which silently defeats
  /// residue-wise comparison in a viewer.
  func testResidueNumbersAreOneBasedPerChain() throws {
    let (structure, canonical) = try fixture()
    let text = try StructureWriter.pdb(structure: structure, canonical: canonical)
    let first = text.split(separator: "\n").first { $0.hasPrefix("ATOM  ") }!
    let resSeq = String(first[first.index(first.startIndex, offsetBy: 22)..<
                             first.index(first.startIndex, offsetBy: 26)])
    XCTAssertEqual(resSeq.trimmingCharacters(in: .whitespaces), "1")
  }

  func testColumnsAreFixedWidth() throws {
    let (structure, canonical) = try fixture()
    let text = try StructureWriter.pdb(structure: structure, canonical: canonical)
    for line in text.split(separator: "\n") where line.hasPrefix("ATOM  ") {
      XCTAssertGreaterThanOrEqual(line.count, 78, "short ATOM record: \(line)")
    }
  }

  func testEmitsTERAndEND() throws {
    let (structure, canonical) = try fixture()
    let text = try StructureWriter.pdb(structure: structure, canonical: canonical)
    XCTAssertTrue(text.contains("\nTER"), "TER missing; multi-chain reads as fused")
    XCTAssertTrue(text.hasSuffix("END\n"))
  }

  func testOneTERPerChain() throws {
    let canonical = try CanonicalStructure.fromSequences([("A", "AG"), ("B", "G")])
    let count = canonical.orderedResidues.reduce(0) { total, residue in
      total + (AAResidueTemplates.template(threeLetter: residue.threeLetter)?.atoms.count ?? 0)
    }
    let structure = BoltzStructure(
      coordinates: (0..<count).map { SIMD3<Float>(Float($0), 0, 0) },
      atomMask: Array(repeating: true, count: count))
    let text = try StructureWriter.pdb(structure: structure, canonical: canonical)
    XCTAssertEqual(text.components(separatedBy: "\nTER").count - 1, 2)
  }

  /// There is no pLDDT: ConfidenceModule is explicitly PAE-only. The B-factor
  /// column must therefore be a documented constant, not a fabricated confidence.
  func testBFactorIsZero() throws {
    let (structure, canonical) = try fixture()
    let text = try StructureWriter.pdb(structure: structure, canonical: canonical)
    let first = text.split(separator: "\n").first { $0.hasPrefix("ATOM  ") }!
    let bfac = String(first[first.index(first.startIndex, offsetBy: 60)..<
                            first.index(first.startIndex, offsetBy: 66)])
    XCTAssertEqual(bfac.trimmingCharacters(in: .whitespaces), "0.00")
  }

  func testCoordinateCountMismatchThrows() throws {
    let (_, canonical) = try fixture()
    let short = BoltzStructure(coordinates: [SIMD3<Float>(0, 0, 0)], atomMask: [true])
    XCTAssertThrowsError(try StructureWriter.pdb(structure: short, canonical: canonical))
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter StructureWriterTests
```

Expected: FAIL — `cannot find 'StructureWriter' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/BoltzMLX/Write/StructureWriter.swift`:

```swift
import Foundation

/// Serializes a predicted structure to PDB.
///
/// Promoted from `MSAEndToEndTests.writePDB`, which already implemented the correct
/// identity walk. Identity is never carried by `BoltzStructure` but is strictly
/// recoverable: the atom axis is the concatenation, over
/// `canonical.orderedResidues`, of `AAResidueTemplates.template(threeLetter:)!.atoms`
/// in template order -- and `orderedResidues` is documented as the ONLY ordering any
/// downstream index should derive from.
///
/// Deliberate limitations, all inherited from what the checkpoint was trained on:
/// heavy atoms only (no hydrogens); no `OXT`, ever, including at chain termini; a
/// single model, because `diffusion_samples` is not plumbed and only sample 0
/// escapes `BoltzPredictor`. And the B-factor column is a constant `0.00`: there is
/// no pLDDT to put there -- `ConfidenceModule` is explicitly PAE-only.
public enum StructureWriter {

  public enum WriteError: Error, LocalizedError {
    case atomCountMismatch(expected: Int, found: Int)
    case missingTemplate(String)

    public var errorDescription: String? {
      switch self {
      case let .atomCountMismatch(expected, found):
        return "structure has \(found) coordinates, expected \(expected)"
      case let .missingTemplate(code):
        return "no residue template for \(code)"
      }
    }
  }

  public static func pdb(structure: BoltzStructure,
                        canonical: CanonicalStructure) throws -> String {
    var expected = 0
    for residue in canonical.orderedResidues {
      guard let template = AAResidueTemplates.template(threeLetter: residue.threeLetter)
      else { throw WriteError.missingTemplate(residue.threeLetter) }
      expected += template.atoms.count
    }
    guard structure.coordinates.count == expected else {
      throw WriteError.atomCountMismatch(expected: expected,
                                         found: structure.coordinates.count)
    }

    var text = ""
    var serial = 1
    var atom = 0
    var previousChain: String? = nil
    // Renumber 1-based per chain: hostResSeq is 0-based for sequence-derived
    // structures, and emitting it verbatim offsets every model by one residue.
    var resSeq = 0

    for residue in canonical.orderedResidues {
      let template = AAResidueTemplates.template(threeLetter: residue.threeLetter)!
      if let previous = previousChain, previous != residue.hostChain {
        text += "TER\n"
        resSeq = 0
      }
      previousChain = residue.hostChain
      resSeq += 1

      for spec in template.atoms {
        let position = structure.coordinates[atom]
        atom += 1
        text += record(serial: serial,
                       name: spec.name,
                       element: element(for: spec.atomicNumber),
                       residue: residue.threeLetter,
                       chain: chainCharacter(residue.hostChain),
                       resSeq: resSeq,
                       insCode: residue.hostInsCode.map(String.init) ?? " ",
                       x: position.x, y: position.y, z: position.z)
        serial += 1
      }
    }
    if previousChain != nil { text += "TER\n" }
    return text + "END\n"
  }

  /// Fixed-column ATOM record. Atom names occupy columns 13-16, left-padded by one
  /// for the single-character elements a canonical protein contains.
  private static func record(serial: Int, name: String, element: String,
                             residue: String, chain: Character, resSeq: Int,
                             insCode: String, x: Float, y: Float, z: Float) -> String {
    let field = String((" " + name + "   ").prefix(4))
    return String(format: "ATOM  %5d %@ %@ %@%4d%@   %8.3f%8.3f%8.3f%6.2f%6.2f          %2@\n",
                  serial, field, residue, String(chain), resSeq, insCode,
                  x, y, z, 1.00, 0.00, element)
  }

  /// Only C, N, O, S occur across the canonical 20 heavy-atom templates.
  private static func element(for atomicNumber: Int) -> String {
    switch atomicNumber {
    case 6: return "C"
    case 7: return "N"
    case 8: return "O"
    case 16: return "S"
    default: return "X"
    }
  }

  /// PDB chain is one column. RayMol constrains chain ids to a single uppercase
  /// character on the way in; anything longer would shift every later column.
  private static func chainCharacter(_ chain: String) -> Character {
    chain.first ?? "A"
  }
}
```

Then delete `private func writePDB` from `MSAEndToEndTests.swift:235-274` and replace its
call site at `:211` with `try StructureWriter.pdb(structure: predicted, canonical: structure)`.

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --filter StructureWriterTests && swift test
```

Expected: PASS. The full suite must stay green — `MSAEndToEndTests` now calls the library.

- [ ] **Step 5: Commit and tag**

```bash
git add Sources/BoltzMLX/Write/StructureWriter.swift tests/BoltzMLXTests
git commit -m "feat: public PDB StructureWriter, promoted from the test helper"
git tag v0.1.0 && git push origin main --tags
```

---

### Task 9: Mint and publish the weight artifact

**Files:** none in the repo. This produces a hosted asset plus three recorded numbers.

**Interfaces:**
- Produces: a published URL, the zip's sha256, and its exact byte size — consumed by Task 10.

- [ ] **Step 1: Export the confidence pack**

Ship the **confidence** pack, not structure-only: the confidence head is optional in the
pack and a structure-only pack loads fine, but `predictScored` then throws
`.missingTensor("confidence_module")`, and PAE is the only confidence signal the port
produces at all.

```bash
boltz-mlx export-model --checkpoint boltz2_conf.ckpt --output artifacts/boltz2-mlx-int8
```

- [ ] **Step 2: Verify the layout is exactly three files**

```bash
ls -1 artifacts/boltz2-mlx-int8
```

Expected exactly: `config.json`, `manifest.json`, `model.safetensors`.

- [ ] **Step 3: Build the zip with those three entries at the archive root**

No top-level directory, no `__MACOSX`, no extras — `WeightCache._extract` asserts the
member set exactly.

```bash
cd artifacts/boltz2-mlx-int8 && zip -X -r ../boltz2-mlx-int8-v1.zip config.json manifest.json model.safetensors
```

- [ ] **Step 4: Record the numbers of the bytes you will upload**

```bash
shasum -a 256 artifacts/boltz2-mlx-int8-v1.zip && wc -c < artifacts/boltz2-mlx-int8-v1.zip
```

**Hash the artifact you actually upload, never a local rebuild.** `mx.quantize` runs on
Metal and is not guaranteed bitwise-reproducible across MLX versions or Apple Silicon
generations, so a hash minted on another machine may not match.

- [ ] **Step 5: Publish and verify the download**

```bash
gh release create weights-v1 artifacts/boltz2-mlx-int8-v1.zip -R javierbq/boltz-mlx --title "Boltz-2 MLX int8 weights v1" --notes "Derived from boltz2_conf.ckpt (MIT). Upstream: jwohlwend/boltz."
```

Then confirm the served bytes match what you hashed:

```bash
curl -sL <asset-url> | shasum -a 256
```

The release notes must carry the MIT notice: the weights are MIT per upstream's README and
the `boltz-community/boltz-2` model card, and redistribution requires the notice travel with
them.

---

### Task 10: SwiftPM dependency, `BoltzRuntime`, `PredictSizeGuard`

**Files:**
- Create: `swiftui/PyMOLViewer/Shared/BoltzRuntime.swift`
- Create: `swiftui/PyMOLViewer/Shared/PredictSizeGuard.swift`
- Modify: `swiftui/project.yml` (`packages:` after `:30`; target `dependencies:` after `:471`)
- Test: `swiftui/PyMOLViewerTests/PredictSizeGuardTests.swift`

**Interfaces:**
- Consumes: `MLXRuntime.requireCacheLimit(_:owner:)` and `MLXRuntime.withMLXErrorsAsThrows` (already landed).
- Produces: `BoltzRuntime.cacheLimitBytes`, `BoltzRuntime.cacheLimitOwner`, `BoltzRuntime.configureOnce()`, `PredictSizeGuard.Decision`, `PredictSizeGuard.decide(tokens:availableBytes:)`, `PredictSizeGuard.maximumTokens`.

- [ ] **Step 1: Write the failing test**

Create `swiftui/PyMOLViewerTests/PredictSizeGuardTests.swift`:

```swift
#if os(macOS)
import XCTest
@testable import RayMol

/// boltz-mlx's own preflight cannot be trusted: its activation estimate
/// under-predicts measured peaks by 10-25x (115 tok estimates ~60 MB, measured
/// 1.43 GB; 384 tok estimates ~622 MB, measured 6.84 GB). This guard is fitted to
/// the measured curve instead, and stays PREVENTIVE because jetsam is an
/// uncatchable SIGKILL.
final class PredictSizeGuardTests: XCTestCase {

  private let gib = 1024 * 1024 * 1024

  func testSmallProteinOnALargeMachineIsOK() {
    XCTAssertEqual(PredictSizeGuard.decide(tokens: 117, availableBytes: 32 * gib), .ok)
  }

  func testLargeProteinOnASmallMachineIsRefused() {
    guard case .refuse = PredictSizeGuard.decide(tokens: 900, availableBytes: 4 * gib)
    else { return XCTFail("expected refuse") }
  }

  func testEstimateTracksTheMeasuredCurve() {
    // Measured on an M3 Pro at recycling 3 / 50 steps: 117 tok -> 2.24 GB,
    // 225 tok -> 3.47 GB. The fit must not sit BELOW measurement.
    XCTAssertGreaterThanOrEqual(PredictSizeGuard.estimatedBytes(tokens: 117),
                                Int(2.24 * Double(gib)))
    XCTAssertGreaterThanOrEqual(PredictSizeGuard.estimatedBytes(tokens: 225),
                                Int(3.47 * Double(gib)))
  }

  func testEstimateIsSuperLinearInTokens() {
    let a = PredictSizeGuard.estimatedBytes(tokens: 100)
    let b = PredictSizeGuard.estimatedBytes(tokens: 200)
    XCTAssertGreaterThan(b, 2 * a - PredictSizeGuard.fixedOverheadBytes)
  }

  func testRefusalReportsAFittingTokenCount() {
    guard case let .refuse(maxTokens) =
            PredictSizeGuard.decide(tokens: 5000, availableBytes: 8 * gib)
    else { return XCTFail("expected refuse") }
    XCTAssertGreaterThan(maxTokens, 0)
    XCTAssertLessThan(maxTokens, 5000)
  }

  func testHardTokenCeilingIsEnforcedRegardlessOfMemory() {
    guard case .refuse = PredictSizeGuard.decide(tokens: PredictSizeGuard.maximumTokens + 1,
                                                 availableBytes: 512 * gib)
    else { return XCTFail("the hard ceiling must bind even with vast memory") }
  }
}

/// BoltzRuntime must register through MLXRuntime rather than assigning MLX
/// directly, so that boltz's MemoryPlanner.apply() cannot raise Design mode's
/// 96 MB ceiling by call order.
final class BoltzRuntimeTests: XCTestCase {

  override func tearDown() {
    MLXRuntime.resetCacheLimitRequirementsForTesting()
    MPNNRuntime.configureOnce()
    super.tearDown()
  }

  func testConfigureOnceRegistersThroughMLXRuntime() {
    MLXRuntime.resetCacheLimitRequirementsForTesting()
    BoltzRuntime.configureOnce()
    XCTAssertEqual(MLXRuntime.cacheLimitRequirements[BoltzRuntime.cacheLimitOwner],
                   BoltzRuntime.cacheLimitBytes)
  }

  func testDesignModesLowerCeilingStillWins() {
    MLXRuntime.resetCacheLimitRequirementsForTesting()
    BoltzRuntime.configureOnce()      // larger
    MPNNRuntime.configureOnce()       // 96 MB
    XCTAssertEqual(MLXRuntime.activeCacheLimitBytes, MPNNRuntime.cacheLimitBytes)
  }

  func testOrderDoesNotMatter() {
    MLXRuntime.resetCacheLimitRequirementsForTesting()
    MPNNRuntime.configureOnce()
    BoltzRuntime.configureOnce()
    XCTAssertEqual(MLXRuntime.activeCacheLimitBytes, MPNNRuntime.cacheLimitBytes)
  }
}
#endif
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd swiftui && xcodegen generate && cd .. && xcodebuild -project swiftui/PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS,arch=arm64' -configuration Debug test -skipPackagePluginValidation -skipMacroValidation
```

Expected: FAIL — `cannot find 'PredictSizeGuard' in scope`.

- [ ] **Step 3: Write the implementation**

Create `swiftui/PyMOLViewer/Shared/BoltzRuntime.swift`:

```swift
#if os(macOS)
import Foundation

/// Structure prediction's MLX policy. Process-wide MLX configuration lives in
/// ``MLXRuntime``; this type contributes only the numbers prediction requires.
///
/// Registering rather than assigning is load-bearing: boltz-mlx's own
/// `MemoryPlanner.apply()` assigns `Memory.cacheLimit` on EVERY predict call, and
/// `MLXRuntime` keeps the most conservative ceiling so that cannot raise Design
/// mode's 96 MB and get the app jetsam-killed.
enum BoltzRuntime {

  /// Larger than Design mode's ceiling because the trunk's pairwise tensors reuse
  /// big buffers, and the Mac is not jetsam-constrained the way a phone is.
  /// MLXRuntime resolves any disagreement downward, so this is a request, not a claim.
  static let cacheLimitBytes = 256 * 1024 * 1024

  /// Identifies this requirement in ``MLXRuntime/cacheLimitRequirements``.
  static let cacheLimitOwner = "Boltz"

  /// Idempotent; safe from any thread. Call before constructing a BoltzPredictor.
  static func configureOnce() {
    MLXRuntime.requireCacheLimit(cacheLimitBytes, owner: cacheLimitOwner)
  }

  /// Run `body` with MLX errors surfaced as Swift `throws` rather than terminating
  /// the process. Does NOT protect against jetsam -- see ``PredictSizeGuard``.
  static func withMLXErrorsAsThrows<R>(_ body: () throws -> R) throws -> R {
    try MLXRuntime.withMLXErrorsAsThrows(body)
  }
}
#endif
```

Create `swiftui/PyMOLViewer/Shared/PredictSizeGuard.swift`:

```swift
#if os(macOS)
import Foundation

/// Predicts the peak memory a Boltz run needs and decides whether to proceed,
/// warn, or refuse.
///
/// This exists because boltz-mlx's own preflight cannot be relied on. Its
/// activation estimate under-predicts measured peaks by 10-25x, and under its
/// phone defaults the memory check can never fire at all because the token cap
/// always binds first. Its own handoff notes concede the limits are "conservative
/// estimates, not measurements".
///
/// It stays PREVENTIVE rather than reactive for the same reason `DesignSizeGuard`
/// does: `MLXRuntime.withMLXErrorsAsThrows` makes MLX-*reported* errors catchable,
/// but a jetsam SIGKILL is an asynchronous OS kill that no Swift handler can
/// intercept -- and on macOS that takes the user's unsaved session with it.
///
/// Constants are fitted to boltz-mlx's measured M3 Pro peaks at recycling 3 /
/// 50 steps (`validation/benchmark/report.md`): 20 tok -> 0.61 GB, 117 -> 2.24 GB,
/// 225 -> 3.47 GB. Memory is super-linear in tokens (pairwise tensors are ~N^2),
/// so the fit is quadratic. Retune all constants together from new device data.
enum PredictSizeGuard {

  // MARK: - Tunable constants

  /// Model-resident floor: the ~533 MiB int8 pack plus graph overhead.
  static let fixedOverheadBytes = 700 * 1024 * 1024
  /// Linear term, bytes per token.
  static let bytesPerToken = 6_000_000
  /// Quadratic term, bytes per token^2 -- the pairwise tensors.
  static let bytesPerTokenSquared = 30_000
  /// At or below this fraction of available memory, proceed silently.
  static let okFraction = 0.50
  /// Above this fraction, refuse.
  static let warnFraction = 0.75
  /// Hard ceiling regardless of memory. `.desktop` limits stop at 1024 tokens, and
  /// nothing above ~384 has ever been validated for quality.
  static let maximumTokens = 1024

  enum Decision: Equatable {
    case ok
    case warn(estimatedBytes: Int, availableBytes: Int)
    case refuse(maxFittingTokens: Int)
  }

  /// Fitted peak-memory estimate. Must never sit below measurement.
  static func estimatedBytes(tokens: Int) -> Int {
    fixedOverheadBytes
      + tokens * bytesPerToken
      + tokens * tokens * bytesPerTokenSquared
  }

  static func decide(tokens: Int, availableBytes: Int) -> Decision {
    guard tokens <= maximumTokens else {
      return .refuse(maxFittingTokens: min(maximumTokens,
                                           largestFittingTokenCount(availableBytes)))
    }
    let estimate = estimatedBytes(tokens: tokens)
    let fraction = Double(estimate) / Double(max(availableBytes, 1))
    if fraction <= okFraction { return .ok }
    if fraction <= warnFraction {
      return .warn(estimatedBytes: estimate, availableBytes: availableBytes)
    }
    return .refuse(maxFittingTokens: largestFittingTokenCount(availableBytes))
  }

  /// Physical memory, as the budget the estimate is compared against.
  static var availableBytes: Int {
    Int(ProcessInfo.processInfo.physicalMemory)
  }

  private static func largestFittingTokenCount(_ availableBytes: Int) -> Int {
    let budget = Int(Double(availableBytes) * warnFraction)
    var best = 0
    var tokens = 1
    while tokens <= maximumTokens {
      if estimatedBytes(tokens: tokens) <= budget { best = tokens } else { break }
      tokens += 1
    }
    return best
  }
}
#endif
```

Modify `swiftui/project.yml` — append to `packages:` after line 30:

```yaml
  # boltz-mlx: on-device Boltz-2 structure prediction (BoltzPredictor is a Swift
  # actor). macOS only: MLX cannot run in the iOS Simulator at all, and no boltz
  # run above ~115 tokens has ever completed on a physical device because iOS
  # suspends the app mid-run. `from:` not `exact:` for the reason at :23-27 --
  # boltz-mlx pins mlx-swift exactly (0.31.6, identical to MPNNKit's pin).
  boltz-mlx:
    url: https://github.com/javierbq/boltz-mlx.git
    from: 0.1.0
```

And append to the target's `dependencies:` after line 471, **before** the
`# RAYMOL_SPARKLE_BEGIN` marker — inside it, `archive_appstore.sh`'s sed-strip would remove
it from the MAS build:

```yaml
      # boltz-mlx: structure prediction. macOS only, so the platform filter keeps
      # BoltzMLX out of the iOS link entirely. No compilation condition: prediction
      # ships in every macOS build, so there is no flag to forget.
      - package: boltz-mlx
        product: BoltzMLX
        platforms: [macOS]
```

- [ ] **Step 4: Run tests, then compile both slices**

```bash
cd swiftui && xcodegen generate && cd ..
xcodebuild -project swiftui/PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS,arch=arm64' -configuration Debug test -skipPackagePluginValidation -skipMacroValidation
```

Expected: `** TEST SUCCEEDED **`, including the pre-existing `MLXRuntimeTests` and
`DesignIOSPortTests` cache-limit assertions.

```bash
xcodebuild -project swiftui/PyMOLViewer.xcodeproj -scheme PyMOLViewer_iOS -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -configuration Debug build -skipPackagePluginValidation -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected: `** BUILD SUCCEEDED **`. This step is not optional — no CI job compiles Swift, and
the `platforms: [macOS]` filter is exactly the kind of thing that breaks only the iOS slice.

- [ ] **Step 5: Commit**

```bash
git add swiftui/project.yml swiftui/PyMOLViewer.xcodeproj/project.pbxproj swiftui/PyMOLViewer/Shared/BoltzRuntime.swift swiftui/PyMOLViewer/Shared/PredictSizeGuard.swift swiftui/PyMOLViewerTests/PredictSizeGuardTests.swift swiftui/PyMOLViewer.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
git commit -m "feat(predict): link boltz-mlx, add BoltzRuntime and PredictSizeGuard"
```

---

### Task 11: `BoltzJobManager` and the `PREDICT:` marker branch

**Files:**
- Create: `swiftui/PyMOLViewer/Shared/BoltzJobManager.swift`
- Modify: `swiftui/PyMOLViewer/Shared/PyMOLEngine.swift` (add a `PREDICT:` branch to `pollFeedback()`, alongside `SETTINGS:ready` at `:2857`)
- Test: `swiftui/PyMOLViewerTests/BoltzJobManagerTests.swift`

**Interfaces:**
- Consumes: `BoltzRuntime`, `PredictSizeGuard` (Task 10); `StructureWriter.pdb` (Task 8).
- Produces: `BoltzJobManager.shared`, `BoltzJobManager.handle(marker: String)`, `BoltzJobManager.Request` / `.Status` Codable shapes, and the file names `raymol_predict_{req,status,result}_<job>.{json,pdb}`.

The request/status shapes are the contract Task 12's Python must match exactly.

- [ ] **Step 1: Write the failing test**

Create `swiftui/PyMOLViewerTests/BoltzJobManagerTests.swift`:

```swift
#if os(macOS)
import XCTest
@testable import RayMol

/// The transport is deliberately file-based: RayMol has no Python->Swift call
/// path, so Python prints a marker that pollFeedback() already scans for, and the
/// payload travels via tempfiles because the feedback line caps at ~1 KB.
final class BoltzJobManagerTests: XCTestCase {

  private var dir: URL!

  override func setUp() {
    super.setUp()
    dir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: dir)
    super.tearDown()
  }

  private func writeRequest(job: String, chains: [[String]], tokens: Int = 5) throws -> URL {
    let url = dir.appendingPathComponent("raymol_predict_req_\(job).json")
    let payload: [String: Any] = [
      "job_id": job,
      "weights_dir": dir.path,
      "chains": chains.map { ["chain": $0[0], "sequence": $0[1]] },
      "recycling_steps": 3,
      "diffusion_steps": 200,
      "seed": 0,
      "out_path": dir.appendingPathComponent("out_\(job).pdb").path,
      "status_path": dir.appendingPathComponent("raymol_predict_status_\(job).json").path,
    ]
    try JSONSerialization.data(withJSONObject: payload).write(to: url)
    return url
  }

  func testParsesASubmitMarker() throws {
    let request = try writeRequest(job: "j1", chains: [["A", "AG"]])
    let parsed = try BoltzJobManager.parseRequest(at: request)
    XCTAssertEqual(parsed.jobID, "j1")
    XCTAssertEqual(parsed.chains.map(\.chain), ["A"])
    XCTAssertEqual(parsed.chains.map(\.sequence), ["AG"])
    XCTAssertEqual(parsed.diffusionSteps, 200)
    XCTAssertEqual(parsed.recyclingSteps, 3)
  }

  func testIgnoresAMarkerWithNoRequestFile() {
    // Must not crash or throw out of the feedback pump.
    BoltzJobManager.shared.handle(marker: "PREDICT:submit:missing-job")
  }

  func testRejectsAnUnknownMarkerVerb() {
    XCTAssertNil(BoltzJobManager.parseMarker("PREDICT:frobnicate:j1"))
    XCTAssertNil(BoltzJobManager.parseMarker("OBJPANEL:ready"))
  }

  func testParsesSubmitAndCancelVerbs() {
    XCTAssertEqual(BoltzJobManager.parseMarker("PREDICT:submit:j1")?.verb, .submit)
    XCTAssertEqual(BoltzJobManager.parseMarker("PREDICT:cancel:j1")?.verb, .cancel)
    XCTAssertEqual(BoltzJobManager.parseMarker("PREDICT:submit:j1")?.jobID, "j1")
  }

  func testStatusIsWrittenAtomicallyAndIsReadableJSON() throws {
    let path = dir.appendingPathComponent("raymol_predict_status_j2.json")
    try BoltzJobManager.writeStatus(
      .init(state: "running", phase: "inference", fraction: 0.5,
            error: nil, resultPath: nil), to: path)
    let data = try Data(contentsOf: path)
    let decoded = try JSONDecoder().decode(BoltzJobManager.Status.self, from: data)
    XCTAssertEqual(decoded.state, "running")
    XCTAssertEqual(decoded.fraction, 0.5)
  }

  func testOversizedInputIsRefusedWithoutAllocating() throws {
    let long = String(repeating: "A", count: PredictSizeGuard.maximumTokens + 10)
    let request = try writeRequest(job: "j3", chains: [["A", long]])
    let parsed = try BoltzJobManager.parseRequest(at: request)
    let status = BoltzJobManager.preflight(parsed)
    XCTAssertEqual(status?.state, "failed")
    XCTAssertNotNil(status?.error)
  }
}
#endif
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd swiftui && xcodegen generate && cd .. && xcodebuild -project swiftui/PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS,arch=arm64' -configuration Debug test -skipPackagePluginValidation -skipMacroValidation
```

Expected: FAIL — `cannot find 'BoltzJobManager' in scope`.

- [ ] **Step 3: Write the implementation**

Create `swiftui/PyMOLViewer/Shared/BoltzJobManager.swift`:

```swift
#if os(macOS)
import BoltzMLX
import Foundation

/// Runs Boltz predictions on behalf of Python.
///
/// RayMol has no Python->Swift call path: `PyMOLBridge.h` is one-directional and no
/// Swift function carries a C symbol. So `cmd.predict` writes a request JSON and
/// prints a `PREDICT:` marker, which `PyMOLEngine.pollFeedback()` already scans on
/// a 100 ms timer, exactly as `OBJPANEL:` and `SETTINGS:ready` work. Payloads travel
/// as tempfiles because the feedback line caps at ~1 KB.
///
/// Because the API is a job handle, nothing here needs to return a value to Python:
/// status and result are files that Python polls.
final class BoltzJobManager {

  static let shared = BoltzJobManager()

  /// MLX must never run on the main thread. `cmd.predict` from the console arrives
  /// ON the main thread, which is exactly why submit is fire-and-forget.
  private let queue = DispatchQueue(label: "io.raymol.predict.inference",
                                    qos: .userInitiated)
  /// Serializes access to `predictor`, which is expensive to build.
  private let stateQueue = DispatchQueue(label: "io.raymol.predict.state")
  private var cancelled = Set<String>()
  /// Construction loads ~533 MiB and builds the graph (~10 s), so it is kept alive
  /// across predictions rather than rebuilt per job.
  private var predictor: BoltzPredictor?
  private var predictorDirectory: String?

  // MARK: - Marker parsing

  enum Verb: String { case submit, cancel }
  struct Marker: Equatable { let verb: Verb; let jobID: String }

  static func parseMarker(_ line: String) -> Marker? {
    guard line.hasPrefix("PREDICT:") else { return nil }
    let parts = line.dropFirst("PREDICT:".count).split(separator: ":",
                                                       maxSplits: 1,
                                                       omittingEmptySubsequences: false)
    guard parts.count == 2, let verb = Verb(rawValue: String(parts[0])),
          !parts[1].isEmpty else { return nil }
    return Marker(verb: verb, jobID: String(parts[1]))
  }

  // MARK: - Wire format (must match modules/pymol/predictors/host.py)

  struct Chain: Codable { let chain: String; let sequence: String }

  struct Request: Codable {
    let jobID: String
    let weightsDir: String
    let chains: [Chain]
    let recyclingSteps: Int
    let diffusionSteps: Int
    let seed: UInt64
    let outPath: String
    let statusPath: String

    enum CodingKeys: String, CodingKey {
      case jobID = "job_id", weightsDir = "weights_dir", chains
      case recyclingSteps = "recycling_steps", diffusionSteps = "diffusion_steps"
      case seed, outPath = "out_path", statusPath = "status_path"
    }
  }

  struct Status: Codable {
    let state: String        // queued | running | done | failed | cancelled
    let phase: String
    let fraction: Double
    let error: String?
    let resultPath: String?

    enum CodingKeys: String, CodingKey {
      case state, phase, fraction, error, resultPath = "result_path"
    }
  }

  static func parseRequest(at url: URL) throws -> Request {
    try JSONDecoder().decode(Request.self, from: try Data(contentsOf: url))
  }

  /// Atomic so a poller never reads a half-written status.
  static func writeStatus(_ status: Status, to url: URL) throws {
    let data = try JSONEncoder().encode(status)
    let temp = url.appendingPathExtension("tmp")
    try data.write(to: temp)
    _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
  }

  // MARK: - Entry point from pollFeedback()

  func handle(marker line: String) {
    guard let marker = Self.parseMarker(line) else { return }
    switch marker.verb {
    case .cancel:
      stateQueue.sync { cancelled.insert(marker.jobID) }
    case .submit:
      let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("raymol_predict_req_\(marker.jobID).json")
      guard let request = try? Self.parseRequest(at: url) else { return }
      if let failure = Self.preflight(request) {
        try? Self.writeStatus(failure,
                              to: URL(fileURLWithPath: request.statusPath))
        return
      }
      queue.async { self.run(request) }
    }
  }

  /// Refuse before allocating anything. Returns nil when the run may proceed.
  static func preflight(_ request: Request) -> Status? {
    let tokens = request.chains.reduce(0) { $0 + $1.sequence.count }
    switch PredictSizeGuard.decide(tokens: tokens,
                                   availableBytes: PredictSizeGuard.availableBytes) {
    case .ok, .warn:
      return nil
    case let .refuse(maxFittingTokens):
      return Status(state: "failed", phase: "preflight", fraction: 0,
                    error: "input of \(tokens) residues is too large for this "
                         + "machine; at most about \(maxFittingTokens) fit",
                    resultPath: nil)
    }
  }

  // MARK: - Inference

  private func run(_ request: Request) {
    let statusURL = URL(fileURLWithPath: request.statusPath)
    func report(_ state: String, _ phase: String, _ fraction: Double,
                error: String? = nil, result: String? = nil) {
      try? Self.writeStatus(Status(state: state, phase: phase, fraction: fraction,
                                   error: error, resultPath: result),
                            to: statusURL)
    }
    func isCancelled() -> Bool {
      stateQueue.sync { cancelled.contains(request.jobID) }
    }

    report("running", "featurize", 0.0)
    do {
      BoltzRuntime.configureOnce()
      let canonical = try CanonicalStructure.fromSequences(
        request.chains.map { ($0.chain, $0.sequence) })
      // The featurizer SILENTLY EXCLUDES residues it cannot template rather than
      // failing, so anything dropped must be refused here instead of returning a
      // structure that quietly is not what was asked for.
      guard !canonical.hasBlockingDiagnostics, canonical.diagnostics.isEmpty else {
        report("failed", "featurize", 0,
               error: "unsupported input: \(canonical.diagnostics)")
        return
      }
      let features = try BoltzFeaturizer().featurize(canonical, alignments: [:])

      if isCancelled() { report("cancelled", "featurize", 0); return }
      report("running", "load", 0.1)
      let predictor = try loadedPredictor(directory: request.weightsDir)

      report("running", "inference", 0.2)
      var options = BoltzPredictionOptions()
      options.recyclingSteps = request.recyclingSteps
      options.diffusionSteps = request.diffusionSteps
      options.seed = request.seed

      let structure = try BoltzRuntime.withMLXErrorsAsThrows { () -> BoltzStructure in
        var result: Result<BoltzStructure, Error>!
        let done = DispatchSemaphore(value: 0)
        Task {
          do { result = .success(try await predictor.predict(featurized: features,
                                                             options: options)) }
          catch { result = .failure(error) }
          done.signal()
        }
        done.wait()
        return try result.get()
      }

      if isCancelled() { report("cancelled", "inference", 0); return }
      report("running", "write", 0.95)
      let text = try StructureWriter.pdb(structure: structure, canonical: canonical)
      try text.write(to: URL(fileURLWithPath: request.outPath),
                     atomically: true, encoding: .utf8)
      report("done", "done", 1.0, result: request.outPath)
    } catch is CancellationError {
      report("cancelled", "inference", 0)
    } catch {
      report("failed", "inference", 0, error: error.localizedDescription)
    }
    stateQueue.sync { cancelled.remove(request.jobID) }
  }

  /// Reuses the loaded predictor when the weights directory is unchanged.
  private func loadedPredictor(directory: String) throws -> BoltzPredictor {
    try stateQueue.sync {
      if let existing = predictor, predictorDirectory == directory { return existing }
      let built = try BoltzRuntime.withMLXErrorsAsThrows {
        try BoltzPredictor(
          modelDirectory: URL(fileURLWithPath: directory),
          // The default preset is phone-sized and would refuse anything real.
          memoryPlanner: MemoryPlanner(limits: .desktop))
      }
      predictor = built
      predictorDirectory = directory
      return built
    }
  }
}
#endif
```

Modify `swiftui/PyMOLViewer/Shared/PyMOLEngine.swift` — in `pollFeedback()`, add a branch
alongside the `SETTINGS:ready` case at `:2857`. It must **not** be wrapped in the
macOS-only `#if` used for `MCP:` at `:2864`; use its own `#if os(macOS)` so the ladder stays
readable:

```swift
                } else if line.hasPrefix("PREDICT:") {
                    #if os(macOS)
                    BoltzJobManager.shared.handle(marker: line)
                    #endif
```

- [ ] **Step 4: Run tests, then compile both slices**

```bash
cd swiftui && xcodegen generate && cd ..
xcodebuild -project swiftui/PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS,arch=arm64' -configuration Debug test -skipPackagePluginValidation -skipMacroValidation
xcodebuild -project swiftui/PyMOLViewer.xcodeproj -scheme PyMOLViewer_iOS -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -configuration Debug build -skipPackagePluginValidation -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected: `** TEST SUCCEEDED **` and `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add swiftui/PyMOLViewer/Shared/BoltzJobManager.swift swiftui/PyMOLViewer/Shared/PyMOLEngine.swift swiftui/PyMOLViewerTests/BoltzJobManagerTests.swift swiftui/PyMOLViewer.xcodeproj/project.pbxproj
git commit -m "feat(predict): BoltzJobManager driven by a PREDICT: feedback marker"
```

---

### Task 12: The `boltz2` predictor and the host transport

**Files:**
- Create: `modules/pymol/predictors/host.py`
- Create: `modules/pymol/predictors/boltz2.py`
- Modify: `modules/pymol/predictors/__init__.py` (`_register_builtins`)
- Test: `testing/tests/predict/predict_boltz2.py`

**Interfaces:**
- Consumes: `Predictor`, `parse_chains`, errors (Task 1); `WeightBundle` (Task 3); the wire format from Task 11.
- Produces: `host.available()`, `host.submit(request) -> HostJob`, `HostJob.job_id/status()/cancel()`, `Boltz2Predictor`.

`host.py`'s JSON keys must match `BoltzJobManager.Request`/`.Status` exactly.

- [ ] **Step 1: Write the failing test**

Create `testing/tests/predict/predict_boltz2.py`:

```python
"""boltz2 predictor and the Swift-host transport. No Swift required: the host is
simulated by writing the status file the Swift side would write.

    pymol -ckqy testing/testing.py --run testing/tests/predict/predict_boltz2.py
"""
import json
import os

from pymol import testing


class TestAvailability(testing.PyMOLTestCase):

    def setUp(self):
        testing.PyMOLTestCase.setUp(self)
        self._saved = os.environ.get('RAYMOL_PREDICT_HOST')

    def tearDown(self):
        if self._saved is None:
            os.environ.pop('RAYMOL_PREDICT_HOST', None)
        else:
            os.environ['RAYMOL_PREDICT_HOST'] = self._saved
        testing.PyMOLTestCase.tearDown(self)

    def testUnavailableWithoutAHost(self):
        from pymol.predictors.boltz2 import Boltz2Predictor
        from pymol.predictors.errors import PredictorUnavailable
        os.environ.pop('RAYMOL_PREDICT_HOST', None)
        self.assertRaises(PredictorUnavailable,
                          Boltz2Predictor().check_available)

    def testAvailableWithAHost(self):
        from pymol.predictors.boltz2 import Boltz2Predictor
        os.environ['RAYMOL_PREDICT_HOST'] = '1'
        self.assertIsNone(Boltz2Predictor().check_available())


class TestSpecValidation(testing.PyMOLTestCase):

    def predictor(self):
        from pymol.predictors.boltz2 import Boltz2Predictor
        return Boltz2Predictor()

    def testCanonicalSequenceAccepted(self):
        spec = self.predictor().parse_spec('MKTAY')
        self.assertEqual(spec.chains, (('A', 'MKTAY'),))

    def testNonCanonicalLettersRejected(self):
        from pymol.predictors.errors import PredictionInputError
        for bad in ('MKTX', 'MKTU', 'MKTB', 'MKTZ', 'MKT1'):
            self.assertRaises(PredictionInputError,
                              self.predictor().parse_spec, bad)

    def testTooLongRejected(self):
        from pymol.predictors.errors import PredictionInputError
        from pymol.predictors.boltz2 import MAX_RESIDUES
        self.assertRaises(PredictionInputError, self.predictor().parse_spec,
                          'A' * (MAX_RESIDUES + 1))

    def testDiffusionSamplesRejectedByName(self):
        from pymol.predictors.errors import PredictionOptionError
        try:
            self.predictor().validate_options({'diffusion_samples': 4})
        except PredictionOptionError as exc:
            self.assertIn('diffusion_samples', str(exc))
        else:
            self.fail('expected PredictionOptionError')

    def testDefaultsAreUpstreamBoltz(self):
        options = self.predictor().validate_options({})
        self.assertEqual(options.recycling_steps, 3)
        self.assertEqual(options.diffusion_steps, 200)


class TestHostTransport(testing.PyMOLTestCase):

    def setUp(self):
        testing.PyMOLTestCase.setUp(self)
        os.environ['RAYMOL_PREDICT_HOST'] = '1'

    def tearDown(self):
        os.environ.pop('RAYMOL_PREDICT_HOST', None)
        testing.PyMOLTestCase.tearDown(self)

    def testSubmitWritesARequestAndPrintsAMarker(self):
        import io
        from contextlib import redirect_stdout
        from pymol.predictors import host
        from pymol.predictors.base import PredictionOptions, PredictionSpec

        spec = PredictionSpec((('A', 'AG'),), 'pred')
        buf = io.StringIO()
        with redirect_stdout(buf):
            job = host.submit(spec, PredictionOptions(), '/tmp/weights')
        self.assertIn('PREDICT:submit:%s' % job.job_id, buf.getvalue())

        with open(job.request_path) as handle:
            request = json.load(handle)
        self.assertEqual(request['chains'], [{'chain': 'A', 'sequence': 'AG'}])
        self.assertEqual(request['weights_dir'], '/tmp/weights')
        self.assertEqual(request['diffusion_steps'], 200)
        self.assertEqual(request['job_id'], job.job_id)
        self.assertIn('status_path', request)
        self.assertIn('out_path', request)
        os.unlink(job.request_path)

    def testStatusIsQueuedUntilTheHostWrites(self):
        from pymol.predictors import host
        from pymol.predictors.base import PredictionOptions, PredictionSpec
        import io
        from contextlib import redirect_stdout
        with redirect_stdout(io.StringIO()):
            job = host.submit(PredictionSpec((('A', 'AG'),), 'p'),
                              PredictionOptions(), '/tmp/w')
        self.assertEqual(job.status()['state'], 'queued')
        os.unlink(job.request_path)

    def testStatusReflectsWhatTheHostWrote(self):
        from pymol.predictors import host
        from pymol.predictors.base import PredictionOptions, PredictionSpec
        import io
        from contextlib import redirect_stdout
        with redirect_stdout(io.StringIO()):
            job = host.submit(PredictionSpec((('A', 'AG'),), 'p'),
                              PredictionOptions(), '/tmp/w')
        with open(job.status_path, 'w') as handle:
            json.dump({'state': 'done', 'phase': 'done', 'fraction': 1.0,
                       'error': None, 'result_path': '/tmp/out.pdb'}, handle)
        status = job.status()
        self.assertEqual(status['state'], 'done')
        self.assertEqual(status['result_path'], '/tmp/out.pdb')
        os.unlink(job.request_path)
        os.unlink(job.status_path)

    def testCancelPrintsAMarker(self):
        import io
        from contextlib import redirect_stdout
        from pymol.predictors import host
        from pymol.predictors.base import PredictionOptions, PredictionSpec
        with redirect_stdout(io.StringIO()):
            job = host.submit(PredictionSpec((('A', 'AG'),), 'p'),
                              PredictionOptions(), '/tmp/w')
        buf = io.StringIO()
        with redirect_stdout(buf):
            job.cancel()
        self.assertIn('PREDICT:cancel:%s' % job.job_id, buf.getvalue())
        os.unlink(job.request_path)


class TestRegistration(testing.PyMOLTestCase):

    def testBoltz2IsRegistered(self):
        from pymol.predictors import registry
        self.assertIn('boltz2', registry.available())
```

- [ ] **Step 2: Run test to verify it fails**

```bash
pymol -ckqy testing/testing.py --run testing/tests/predict/predict_boltz2.py
```

Expected: FAIL — `No module named 'pymol.predictors.host'`.

- [ ] **Step 3: Write the implementation**

Create `modules/pymol/predictors/host.py`:

```python
"""Transport to the Swift inference host.

RayMol has no Python->Swift call path: PyMOLBridge.h is one-directional and no
Swift function carries a C symbol. So this module writes a request JSON to the
temp dir and prints a short PREDICT: marker on the feedback line, which the app's
existing 100 ms pollFeedback() already scans -- the same mechanism OBJPANEL: and
SETTINGS:ready use. Payloads go through files because the feedback line caps at
~1 KB.

Because cmd.predict returns a job handle, nothing here needs a synchronous return
value from Swift: status and result are files this module polls.

The JSON keys below are a contract with BoltzJobManager.Request / .Status.
"""
import json
import os
import tempfile
import uuid

from .errors import PredictorUnavailable

#: Set by the Swift host next to PYMOL_PATH so Python can tell it is present.
HOST_ENV = 'RAYMOL_PREDICT_HOST'


def available():
    """True when an inference host is listening for PREDICT: markers.

    False under headless `pymol -c`, where nothing consumes the marker. Callers
    must refuse rather than submit a job that would hang forever.
    """
    return bool(os.environ.get(HOST_ENV))


def require_available(predictor_id):
    if not available():
        raise PredictorUnavailable(
            '%s needs the RayMol application host; it is not available in this '
            'process (headless PyMOL cannot run on-device inference)'
            % predictor_id)


def _path(kind, job_id, suffix='json'):
    return os.path.join(tempfile.gettempdir(),
                        'raymol_predict_%s_%s.%s' % (kind, job_id, suffix))


class HostJob:
    """Handle on a job owned by the Swift side. Every method is a cheap poll."""

    def __init__(self, job_id, spec, options):
        self.job_id = job_id
        self.spec = spec
        self.options = options
        self.request_path = _path('req', job_id)
        self.status_path = _path('status', job_id)
        self.out_path = _path('result', job_id, 'pdb')

    def status(self):
        """The host's last written status, or 'queued' if it has not started."""
        try:
            with open(self.status_path) as handle:
                return json.load(handle)
        except (IOError, OSError, ValueError):
            return {'state': 'queued', 'phase': 'queued', 'fraction': 0.0,
                    'error': None, 'result_path': None}

    def cancel(self):
        """Ask the host to stop. Cancellation is cooperative and coarse: it lands
        on the per-diffusion-step checkCancellation, so worst case is one step."""
        print('PREDICT:cancel:%s' % self.job_id)


def submit(spec, options, weights_path):
    """Write the request, print the marker, return the handle. Never blocks."""
    job_id = uuid.uuid4().hex[:12]
    job = HostJob(job_id, spec, options)
    request = {
        'job_id': job_id,
        'weights_dir': weights_path or '',
        # Objects, not pairs: BoltzJobManager.Chain is a Codable struct with named
        # keys, so a positional array would fail to decode.
        'chains': [{'chain': chain, 'sequence': sequence}
                   for chain, sequence in spec.chains],
        'recycling_steps': options.recycling_steps,
        'diffusion_steps': options.diffusion_steps,
        'seed': options.seed,
        'out_path': job.out_path,
        'status_path': job.status_path,
    }
    # Write completely before announcing it: the host reads on the next 100 ms
    # tick and must never see a partial request.
    temp = job.request_path + '.tmp'
    with open(temp, 'w') as handle:
        json.dump(request, handle)
    os.replace(temp, job.request_path)
    print('PREDICT:submit:%s' % job_id)
    return job
```

Create `modules/pymol/predictors/boltz2.py`:

```python
"""Boltz-2 via boltz-mlx: a Swift/MLX int8 port running on-device.

Protein-only, canonical-20, single-sequence (no MSA). Ligands, nucleic acids,
modified residues, cyclic peptides and structural templates are unsupported by the
featurizer and are rejected here rather than silently dropped.
"""
from . import host
from .base import Predictor, PredictionSpec, parse_chains
from .errors import PredictionInputError
from .weights import WeightBundle

#: The canonical 20. X, U, B and Z are deliberately absent: the featurizer throws
#: on any letter outside this set, so accepting them here would only defer the error.
CANONICAL = set('ACDEFGHIKLMNPQRSTVWY')

#: BoltzInputLimits.desktop caps at 1024 tokens, and one token is one residue.
MAX_RESIDUES = 1024


class Boltz2Predictor(Predictor):

    id = 'boltz2'
    name = 'Boltz-2 (MLX, int8)'

    # sha256 and size are of the published zip's bytes -- of the artifact actually
    # uploaded, not of a local re-export, because int8 quantization runs on Metal
    # and is not guaranteed bitwise-reproducible across machines.
    weight_bundle = WeightBundle(
        id='boltz2-mlx-int8',
        version='v1',
        url='https://github.com/javierbq/boltz-mlx/releases/download/weights-v1/'
            'boltz2-mlx-int8-v1.zip',
        sha256='REPLACE_WITH_PUBLISHED_DIGEST',
        size=0,
        members=('config.json', 'manifest.json', 'model.safetensors'),
    )

    # Upstream Boltz's defaults. The MLX port's own (0, 20) fail its own quality
    # gate at 3.19 A / 0.685 lDDT. step_scale is absent deliberately: it comes from
    # the artifact's config.json (already 1.5) and is not a per-call knob.
    # diffusion_samples is absent because the port does not plumb it and only
    # diffusion sample 0 escapes BoltzPredictor.
    option_defaults = {'recycling_steps': 3, 'diffusion_steps': 200, 'seed': 0}

    def check_available(self):
        host.require_available(self.id)

    def parse_spec(self, sequence, name=''):
        chains = parse_chains(sequence)
        total = 0
        for chain, seq in chains:
            bad = sorted(set(seq) - CANONICAL)
            if bad:
                raise PredictionInputError(
                    'chain %s contains residues Boltz-2 cannot fold: %s '
                    '(canonical 20 only; X, U, B and Z are not accepted)'
                    % (chain, ', '.join(bad)))
            total += len(seq)
        if total > MAX_RESIDUES:
            raise PredictionInputError(
                '%d residues exceeds the %d-residue limit' % (total, MAX_RESIDUES))
        return PredictionSpec(chains, name)

    def submit(self, spec, options, weights_path):
        return host.submit(spec, options, weights_path)
```

Modify `_register_builtins` in `modules/pymol/predictors/__init__.py`:

```python
def _register_builtins():
    """Register the shipped predictors. The only function that changes per predictor."""
    from .boltz2 import Boltz2Predictor
    register(Boltz2Predictor(), replace=True)


_register_builtins()
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
pymol -ckqy testing/testing.py --run testing/tests/predict
```

Expected: PASS, all files, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add modules/pymol/predictors/host.py modules/pymol/predictors/boltz2.py modules/pymol/predictors/__init__.py testing/tests/predict/predict_boltz2.py
git commit -m "feat(predict): boltz2 predictor over the marker/tempfile host transport"
```

---

### Task 13: Fill in the published digest and verify end to end on hardware

**Files:**
- Modify: `modules/pymol/predictors/boltz2.py` (`sha256`, `size`)
- Modify: `swiftui/PyMOLViewer/Bridge/PyMOLBridge.mm:115-116` (publish `RAYMOL_PREDICT_HOST`)

**Interfaces:**
- Consumes: everything. Produces the shipped feature.

- [ ] **Step 1: Publish the host env var**

Beside the existing `setenv("PYMOL_PATH"...)` / `setenv("PYMOL_DATA"...)` calls at
`PyMOLBridge.mm:115-116`, add:

```objc
#if TARGET_OS_OSX
    // Tells modules/pymol/predictors/host.py that a host is listening for
    // PREDICT: markers. Absent under headless pymol -c, where the predictor
    // correctly reports itself unavailable instead of hanging.
    setenv("RAYMOL_PREDICT_HOST", "1", 1);
#endif
```

- [ ] **Step 2: Fill in the real bundle numbers from Task 9**

In `modules/pymol/predictors/boltz2.py`, replace `sha256='REPLACE_WITH_PUBLISHED_DIGEST'`
and `size=0` with the values recorded in Task 9 Step 4.

- [ ] **Step 3: Build and launch the app, then fold a real sequence**

```bash
./swiftui/build_macos.sh && cd swiftui && xcodegen generate && cd .. && xcodebuild -project swiftui/PyMOLViewer.xcodeproj -scheme PyMOLViewer_macOS -configuration Debug build -skipPackagePluginValidation -skipMacroValidation
```

Build the C++ core **first**: `xcodebuild` alone silently links a stale
`libpymol_core.a`. Then, in the running app's command line:

```
predict boltz2, MKTAYIAKQRQISFVKSHFSRQLEERLGLIEVQ, name=trp
```

- [ ] **Step 4: Verify each acceptance criterion by observation**

Record the answers; do not infer them.

1. **Lazy download, once.** First run downloads ~533 MiB; check
   `~/Library/Application Support/RayMol/weights/boltz2-mlx-int8/v1/` holds exactly
   `config.json`, `manifest.json`, `model.safetensors`, `.ok`.
2. **Cache reuse.** A second `predict` performs no download. Confirm by timing and by
   `cmd.predict_weights('boltz2')` reporting `cached=True`.
3. **Result loads.** `trp` appears in the object list with the expected atom count.
4. **Corrupt-cache recovery.** Overwrite `.ok` with garbage, run again: it re-downloads.
5. **Interrupted download.** Kill the app mid-download, relaunch, run again: it restarts
   cleanly and no invalid cache is left. Confirm no `.ok` was written.
6. **Cancellation.** Submit, then `predict_cancel <job>`; state becomes `cancelled` within
   roughly one diffusion step.
7. **Refusal.** Submit a sequence above `PredictSizeGuard`'s fitted ceiling; it fails at
   preflight without the app dying.
8. **Timing and peak memory at 200 steps.** Record both. **Every published figure is at 50
   steps** — this is the first measurement at the shipped operating point, so write it into
   the spec rather than leaving the extrapolation standing.
9. **Design mode still works** after a prediction, and its 96 MB cache ceiling survived:
   `MLXRuntime.cacheLimitRequirements` should hold both owners with the smaller installed.

- [ ] **Step 5: Commit and open the PR**

```bash
git add modules/pymol/predictors/boltz2.py swiftui/PyMOLViewer/Bridge/PyMOLBridge.mm
git commit -m "feat(predict): publish the host probe and the real weight digest"
```

Do not push to `master`; open a PR into it. Include in the PR body the measured timing and
peak memory from Step 4.8, and state the accepted residual risk explicitly: inference runs
in-process, so an OOM that the preventive guard does not catch kills the app and the user's
unsaved session. Out-of-process isolation is the follow-up.

---

## Deferred to follow-up issues

- **iOS enablement.** MLX cannot run in the iOS Simulator at all (verified in
  `MPNNRuntime.swift:35-59` — it aborts even with `Device(.cpu)`), and every boltz on-device
  run above 115 tokens was never completed because iOS suspends the app mid-run. Needs
  background-task handling and probably the increased-memory-limit entitlement.
- **Out-of-process inference isolation** for both boltz and MPNNKit, so an OOM degrades to a
  failed job rather than a lost session.
- **MSA support.** The Swift featurizer implements a3m parsing with bitwise parity tests, but
  the repo's own prose says real MSAs are out of scope; that contradiction is unresolved.
- **Migrate #249's `MPNN.mpnnpack` onto `WeightCache`** via `BundledSource`, so Design mode
  on iOS can fetch rather than bundle 24 MB.
- **mmCIF output**, which removes PDB's 26-chain and 4-character-atom-name ceilings.
