# Mode mutual-exclusion teardown symmetry (Move / Design / Measure)

**Date:** 2026-07-25
**Component:** `swiftui/PyMOLViewer/Shared/PyMOLEngine.swift`
**Found while working on:** issue #235 (Escape exits modes), deliberately left out of scope there

## Problem

RayMol has three mutually exclusive interaction modes: Move, Design, and Measure.
Entering any one must exit the other two. Two of the three setters do this
correctly; `setDesignMode` does not.

`setDesignMode(_:)` clears the other two modes with bare property assignments:

```swift
func setDesignMode(_ on: Bool) {
    if on {
        if interactionMode == .move { interactionMode = .viewing }   // bare
        if measureMode != nil { measureMode = nil }                   // bare
    }
    designMode = on
}
```

whereas the siblings delegate to each other:

- `setInteractionMode(.move)` calls `setMeasureMode(nil)`
- `setMeasureMode(k)` calls `setInteractionMode(.viewing)`

### Why the bare assignments are a bug

Teardown for the three modes lives in two different places:

| Mode | Teardown mechanism | Survives a bare assignment? |
|---|---|---|
| Move | **Imperative** — inside `setInteractionMode`'s else-branch: clears seven fields, runs `metal_move.cleanup()` | **No** |
| Measure | **Imperative** — inside `setMeasureMode`'s nil-branch: runs `appkit_measure.reset()` | **No** |
| Design | **Observer-driven** — `.onChange(of: engine.designMode)` in `ContentView.swift:506` calls `designController.exit()` | **Yes** (`@Published` fires on any assignment) |

Design mode is the odd one out. Because its teardown is observer-driven, the
siblings' bare `designMode = false` happens to work. Move and Measure teardown
is imperative, so `setDesignMode`'s bare assignments skip it entirely.

### Observable consequences

Entering Design mode while in Move mode:

- leaves `activeMoveObject`, `gizmo`, `armedAxis`, `hoveredHandle`,
  `adjustFrameToggle`, `moveShiftHeld`, `lastAdjustSent` stale
- never runs `metal_move.cleanup()`, so the `_move_gizmo` CGO stays in the
  scene. It is `_`-prefixed, so the user cannot delete it from the object panel.
  `PyMOLEngine.swift:1034-1043` already carries a session-load workaround for
  exactly this stray-gizmo symptom.

Entering Design mode while in Measure mode never runs `appkit_measure.reset()`.

### Why the existing tests miss it

`swiftui/PyMOLViewerTests/DesignModeStateTests.swift` asserts only flag values
(`designMode`, `interactionMode`, `measureMode`). Those flags are set correctly
by the bare assignments — it is the teardown behind them that is skipped.

## Constraint: unit-test safety

The comment on `setDesignMode` states it is "deliberately Python-free so it is
safe to call from unit tests and in any state." This is the stated reason for
the bare assignments. **Verified: the constraint is already satisfied without
them.**

- `runPython` is `guard isReady else { return }` (`PyMOLEngine.swift:1077`)
- `isReady` defaults to `false` (`PyMOLEngine.swift:63`)

Both teardown paths reached by the fix are test-safe:

- `setInteractionMode(.viewing)` → else-branch only. Bare field clears plus one
  guarded `runPython`. Never reaches `refreshGizmo()`/`readGizmo()` — those are
  `.move`-branch only.
- `setMeasureMode(nil)` → nil-branch only. One guarded `runPython`.

`requestViewportRedraw()` (reachable via the `hoveredHandle` didSet) only posts
a `NotificationCenter` notification — also test-safe.

The comment must be rewritten: the setter is no longer Python-free, but it
remains safe to call in any state, for a different and now-documented reason.

## Design

### 1. Symmetric delegation

`setDesignMode` delegates to the canonical setters, and both siblings delegate
back to `setDesignMode`:

```swift
/// Enter or exit Design mode. Entering clears Move and Measure (mutually
/// exclusive) via their canonical setters — NOT bare assignments: Move and
/// Measure teardown is imperative and lives INSIDE those setters
/// (metal_move.cleanup() / appkit_measure.reset()), so a bare assignment
/// silently skips it and leaves a stray "_move_gizmo" CGO in the scene.
/// designMode is the odd one out — its teardown is observer-driven
/// (.onChange(of: engine.designMode) in ContentView), so it fires on any
/// assignment. Still safe to call in any state, including unit tests:
/// runPython is `guard isReady` and isReady defaults to false.
func setDesignMode(_ on: Bool) {
    if on {
        if interactionMode == .move { setInteractionMode(.viewing) }
        if measureMode != nil { setMeasureMode(nil) }
    }
    designMode = on
}
```

In `setMeasureMode` and `setInteractionMode`, `designMode = false` becomes
`setDesignMode(false)`.

**Recursion-free by construction.** `setDesignMode`'s clearing block is
`if on`-guarded, so `setDesignMode(false)` is a plain assignment. Each sibling
only touches `designMode` in its *entering* branch, so the off-value calls made
by `setDesignMode(true)` cannot re-enter it.

The sibling change is currently behaviour-preserving (`setDesignMode(false)` is
equivalent to `designMode = false` today). It is included to future-proof: if
imperative teardown is ever added to `setDesignMode`, the siblings will not
silently skip it — the exact bug class being fixed here.

`setDesignMode(true)` now walks the same `setInteractionMode(.viewing)` path as
the existing "exit Move mode" button (`ContentView.swift:3059`), so this is not
a new code path.

### 2. DEBUG-only `runPython` tap

The Measure → Design teardown is not observable from Swift state: the bare
assignment already nils `measureMode`, and the missing `appkit_measure.reset()`
leaves no Swift-side trace. There is no existing spy/fake seam in
`PyMOLViewerTests/`. Without a seam, half the fix ships with no unit coverage.

```swift
#if DEBUG
/// Test seam: observes every emitted Python string. Invoked BEFORE the
/// isReady guard so unit tests (isReady == false) still see the emission.
var pythonTap: ((String) -> Void)? = nil
#endif

func runPython(_ code: String) {
    #if DEBUG
    pythonTap?(code)
    #endif
    guard isReady else { return }
    PyMOLBridge_RunPython(code)
}
```

Placement before the `isReady` guard is the load-bearing detail — unit tests run
with `isReady == false`, so a tap after the guard would observe nothing. Cost is
one optional-closure call, compiled out of Release.

### 3. Ordering fix in `setInteractionMode`'s else-branch

Tracing the Move teardown surfaced a resurrection bug at
`PyMOLEngine.swift:2196-2205`:

```swift
armedAxis = nil
hoveredHandle = nil
activeMoveObject = nil
gizmo = nil
adjustFrameToggle = false   // didSet → syncAdjustFrame() → readGizmo()
                            //   → re-reads /tmp/pymol_gizmo.json, still
                            //     "active" because cleanup() runs LAST
                            //   → repopulates gizmo + activeMoveObject
moveShiftHeld = false
lastAdjustSent = false
runPython("...metal_move.cleanup()")
```

`adjustFrameToggle` and `moveShiftHeld` both carry `didSet { syncAdjustFrame() }`.
`syncAdjustFrame` early-returns when `want == lastAdjustSent`, so this only
fires when adjust-frame or Shift was active — but in that case `readGizmo()`
re-populates the two fields that were just nil'd, from a temp file that
`cleanup()` has not yet invalidated.

**Fix:** hoist `lastAdjustSent = false` above `adjustFrameToggle = false`, so
`syncAdjustFrame`'s guard early-returns. The skipped `set_adjust(0)` round-trip
is redundant — `cleanup()` immediately tears the whole gizmo down.

In scope because it is the same "Move teardown does not fully tear down"
defect, and because deterministic teardown is a precondition for the tests
below.

### 4. Test coverage

In `swiftui/PyMOLViewerTests/DesignModeStateTests.swift`.

**`setUp`/`tearDown`.** `PyMOLEngine.shared` is a singleton shared across the
whole test target, so each test resets all three modes and clears `pythonTap`.
Both also delete `/tmp/pymol_gizmo.json`, establishing a known-empty baseline so
`readGizmo()` cannot import a stale gizmo left by a real app run on the dev
machine — without this the assertions are machine-dependent. A test that needs
`readGizmo()` to find something (test 3) writes the file itself as part of its
arrangement; `tearDown` removes it again.

**Tap discipline.** Seeding `adjustFrameToggle`/`moveShiftHeld` fires
`didSet → syncAdjustFrame()`, which emits `set_adjust(1)`. Tests therefore
either install `pythonTap` *after* seeding, or assert with
`contains { $0.contains(...) }` rather than comparing the captured array for
equality. Never assert on exact emission counts.

**New tests:**

1. **Move → Design tears down gizmo state.** Enter Move mode, seed
   `activeMoveObject`, `gizmo`, `armedAxis`, `hoveredHandle`,
   `adjustFrameToggle`, `moveShiftHeld` (Move mode first: the `hoveredHandle`
   didSet is guarded on `interactionMode == .move`); install the tap; call
   `setDesignMode(true)`; assert every seeded field cleared, `interactionMode
   == .viewing`, `designMode == true`, and that `metal_move.cleanup()` was
   emitted.
   *Fails pre-fix:* the seeded fields stay stale and no cleanup is emitted.
2. **Measure → Design runs `appkit_measure.reset()`.** The transition with zero
   coverage today; asserted through the tap.
   *Fails pre-fix:* no `_am.reset()` emission. The `measureMode == nil` flag
   assertion alone passes both pre- and post-fix, which is precisely why the
   tap is needed.
3. **Exiting Move with adjust-frame active does not resurrect the gizmo.**
   Regression test for §3. Write a `/tmp/pymol_gizmo.json` with
   `active: true` and a valid two-element `center`, enter Move mode, set
   `adjustFrameToggle = true`, then `setInteractionMode(.viewing)`; assert
   `gizmo == nil` and `activeMoveObject == nil`.
   *Fails pre-fix:* `syncAdjustFrame`'s `readGizmo()` re-reads the still-active
   file and repopulates both fields.

Seeding is possible because all the fields are internal `@Published var` and
the test target uses `@testable import RayMol`. `GizmoHandle` is a plain enum
(`x, y, z, free, rx, ry, rz`); `GizmoGeometry` has `init?(json:)` and can be
built from a dictionary literal requiring only a two-element `center`.

`lastAdjustSent` is `private` and stays unasserted — it is covered transitively
by test 3.

## Verification

- Build **both** targets. `ContentView.swift` has a large `#if os(iOS)` block
  with shared helpers; a change can compile on one platform and break the other.
- Run the test target.
- Functional check: enter Design mode from Move mode, confirm no stray gizmo
  remains in the scene.

## Out of scope

- Centralising the pairwise mutual-exclusion wiring into a single
  `clearModesExcept(_:)` funnel. Considered and rejected for this change: it
  touches all three load-bearing setters on both platforms and rides a refactor
  along with a bug fix. Worth revisiting if a fourth mode is added.
- Issue #235 (Escape exits modes). Independent, and it benefits from these
  setters being correct.
