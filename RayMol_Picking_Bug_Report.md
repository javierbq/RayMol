# Technical Investigation Report: CPU Screen-Space Picking Misalignment in RayMol

## 🔍 Executive Summary
A detailed visual frame-by-frame analysis of the screen recording (`Screen Recording 2026-06-18 at 12.04.12 PM.mov`) reveals two independent issues occurring simultaneously when clicking to select residues on the macOS Metal backend:
1. **Vertical Flip/Mirror Bug:** Clicking on a residue selects a completely different residue in the vertically mirrored position of the viewport.
2. **Console Error Noise Bug:** Clicking outputs a heavy C++ traceback in the dropdown terminal log (`Selector-Error: Invalid selection name "dist03"`).

Both bugs originate from discrepancies between coordinates and types expected by the CPU unprojection picking system (`metal_pick.py` and `MetalViewport.swift`) and what is returned under SwiftUI layout hosting on macOS.

---

## 🐞 Bug 1: Vertical Offset / Flip (Coordinate Inversion)

### 1. Symptoms & Visual Evidence
* In **Frame 4**, the cursor clicks on the **bottom-left** of the protein (the green ribbon around coordinate `y = 630` in logical space). However, the resulting pink selection squares appear near the **top-left** of the protein (the orange ribbon around `y = 320`).
* In **Frame 5**, the cursor clicks at the **bottom-center** (green ribbon, `y = 570`), but the new pink squares appear at the **top-center** (orange/green interface, `y = 310`).
* In **Frame 6**, the cursor clicks on the blue helix near the **bottom-right** (`y = 570`), but the selection appears near the **top-right** of the helix (`y = 440`).

### 2. Deep Root-Cause Analysis
* **The File:** `swiftui/PyMOLViewer/Shared/MetalViewport.swift`
* **The Code:**
  ```swift
  func handleMouseUp(_ event: NSEvent, in view: MTKView) {
      let loc = view.convert(event.locationInWindow, from: nil)
      // ...
      let ndcX = Float(loc.x / w) * 2 - 1
      let ndcY = Float(loc.y / h) * 2 - 1 // <--- Origin of the bug
  ```
* **The Explanation:**
  1. Traditional macOS AppKit views (`NSView` / `MTKView`) are natively **bottom-up** (with `Y = 0` at the bottom and `Y = h` at the top).
  2. However, because our `MTKView` is hosted inside SwiftUI (using `NSViewRepresentable`), SwiftUI wraps it in its own hosting hierarchy where `isFlipped` is `true` (standard top-down coordinates).
  3. Under a flipped AppKit hierarchy, coordinate conversions like `view.convert(point, from: nil)` inherit the flipped state and return coordinates with a **top-left origin** (`Y = 0` is at the top of the viewport, increasing downwards).
  4. The coordinate translation `Float(loc.y / h) * 2 - 1` assumes bottom-up coordinates. Under top-down coordinates, it **vertically mirrors the mouse position**:
     * Clicking near the **top** (`loc.y ≈ 0`) maps to NDC `ndcY ≈ -1` (interpreted as the bottom).
     * Clicking near the **bottom** (`loc.y ≈ h`) maps to NDC `ndcY ≈ 1` (interpreted as the top).

---

## 🐞 Bug 2: Selector-Error Console Noise

### 1. Symptoms
Every residue click triggers a verbose error block printed to the C++ terminal log:
```text
Selector-Error: Invalid selection name "dist03".
( ( dist03 ) and ( rep spheres or rep sticks ...
```

### 2. Deep Root-Cause Analysis
* **The File:** `modules/pymol/metal_pick.py`
* **The Code:**
  ```python
  for obj in (cmd.get_names('objects', enabled_only=1) or []):
      if obj.startswith('_'):
          continue
      try:
          model = cmd.get_model('(%s) and (%s)' % (obj, _DRAWN_REPS))
      except Exception:
          continue
  ```
* **The Explanation:**
  1. Inside the right sidebar panel of the video, several distance measurements (`dist03` and `dist04`) are checked/enabled.
  2. `cmd.get_names('objects', enabled_only=1)` returns *all* enabled objects, which includes these distance measurements.
  3. Distance measurements are of type `"object:measurement"`. They are not molecules and do not have coordinates or atoms in the selection system.
  4. Passing `(dist03)` as a selection expression to `cmd.get_model` causes the C++ selection parser to fail with a `Selector-Error`, printing tracebacks and polluting internal C++ selection engine buffers.

---

# Proposed Fixes

Here is the exact code architecture needed to resolve both issues permanently:

### 1. Fixing Bug 1 (Vertical Flip) in `MetalViewport.swift`
To resolve the coordinate flip under SwiftUI hosting, we must apply the same vertical Y-flip on macOS that we already do on iOS:

#### A. Update the standard mouse-up NDC mapping:
In `swiftui/PyMOLViewer/Shared/MetalViewport.swift` (around line 363), change `ndcY` to flip the top-down coordinates:
```swift
// FROM:
let ndcY = Float(loc.y / h) * 2 - 1

// TO:
let ndcY = 1 - Float(loc.y / h) * 2
```

#### B. Update the debug click generator:
In the test harness helper `debugClick` (around line 399), flip the Y coordinate as well so it converts the NDC bottom-up target correctly into top-down viewport points:
```swift
// FROM:
let vp = CGPoint(x: (ndcX + 1) / 2 * w, y: (ndcY + 1) / 2 * h)

// TO:
let vp = CGPoint(x: (ndcX + 1) / 2 * w, y: (1 - ndcY) / 2 * h)
```

---

### 2. Fixing Bug 2 (Selector-Error Noise) in `metal_pick.py`
Before querying atoms of an enabled object, check if the object is actually a molecule (`"object:molecule"`). If it is a distance measurement (`"object:measurement"`) or group/map/volume, skip it entirely:

In `modules/pymol/metal_pick.py` (inside the `_pick_atom` loop around line 118):
```python
# FROM:
for obj in (cmd.get_names('objects', enabled_only=1) or []):
    if obj.startswith('_'):
        continue
    try:
        model = cmd.get_model('(%s) and (%s)' % (obj, _DRAWN_REPS))
    except Exception:
        continue

# TO:
for obj in (cmd.get_names('objects', enabled_only=1) or []):
    if obj.startswith('_'):
        continue
    try:
        if cmd.get_type(obj) != 'object:molecule':
            continue
    except Exception:
        continue
    try:
        model = cmd.get_model('(%s) and (%s)' % (obj, _DRAWN_REPS))
    except Exception:
        continue
```
