# Investigation Report: RayMol Sequence Viewer Selection Logic vs. Vanilla PyMOL

## 🔍 Overview
Selecting residues in the AppKit/SwiftUI Sequence Viewer panel behaves differently than vanilla PyMOL. Specifically, clicking a residue in the panel:
1. Hardcodes the selection name to `"sele"`, erasing any active custom selections.
2. Overwrites the active selection entirely instead of toggling residues in/out of selection.
3. Force-centers the camera on the clicked residue, which can cause jarring camera animations on simple selection changes.

This report analyzes the underlying mechanics of both architectures and proposes a python-native solution for RayMol to mirror vanilla PyMOL's sequence selection capabilities.

---

## 🏛️ Architecture Comparison

### 1. Vanilla PyMOL (`CSeeker` C++ Selection Engine)
In standard PyMOL, clicking on sequence characters is handled by `SeekerClick` inside `layer3/Seeker.cpp` and `CSeeker` (inheriting from `CSeqHandler`):
* **Respects Active Selection:** It checks the currently active selection via `ExecutiveGetActiveSeleName(G, name, ...)`. Clicking adds to or removes from this active selection instead of hardcoding `"sele"`.
* **Additive/Subtractive Toggling:** It calls `SeekerSelectionToggle(G, rowVLA, row_num, col_num, ...)` to toggle individual residues. If a clicked residue is already highlighted, it is sliced out (`(active_sele) and not (residue)`); otherwise, it is joined (`(active_sele) or (residue)`).
* **Multi-Select and Drag:** Dragging highlights continuous blocks, and Shift-clicks extend selections by executing a contiguous range query.
* **No Forced Centering:** A simple left-click only modifies selection state. Camera centering is reserved for middle-clicks or double-clicks.

### 2. RayMol Sequence Panel (`appkit_sequence_panel.py`)
In RayMol, the sequence viewer is an AppKit horizontal scroll view composed of individual text button labels. Selection is intercepted in Python by **`SeqPanel_ClickTarget`** inside `modules/pymol/appkit_sequence_panel.py`:
```python
class SeqPanel_ClickTarget(AppKit.NSObject):
    ...
    @objc.typedSelector(b'v@:@')
    def clicked_(self, sender):
        try:
            sel = self._obj_name
            if self._chain:
                sel += " and chain " + self._chain
            if self._resi:
                sel += " and resi " + str(self._resi)
            self._cmd.select("sele", sel)              # 1. Hardcoded "sele" & Overwrite
            self._cmd.center(sel, animate=-1)          # 2. Forced camera centering
```

---

## 💡 Proposed Solution

To align RayMol's sequence panel with the traditional PyMOL selection paradigm, the click target logic in `modules/pymol/appkit_sequence_panel.py` should be redesigned.

### Features of the Proposed Solution:
1. **Dynamic Active Selection:** Query the active named selection, falling back to `"sele"` only if none exists.
2. **Residue-Level Toggling (Additive Selection):** Toggle the clicked residue in/out of the selection based on its current membership.
3. **Configurable Camera Centering:** Remove or gate the forced `center` call (e.g. only center if holding `Control` or on double-clicks), matching the behavior of `metal_pick.py`.

### Code Implementation Proposal
Replace `clicked_` inside `SeqPanel_ClickTarget` with the following clean, PyMOL-idiomatic Python implementation:

```python
    @objc.typedSelector(b'v@:@')
    def clicked_(self, sender):
        try:
            # 1. Build the specific residue selection expression
            res_expr = self._obj_name
            if self._chain:
                res_expr += " and chain " + self._chain
            if self._resi:
                res_expr += " and resi " + str(self._resi)
            res_expr = "(%s)" % res_expr

            # 2. Determine target selection name (active selection, falling back to 'sele')
            # Check for existing custom selections to see if one is currently active
            all_sels = self._cmd.get_names('selections') or []
            target_sele = "sele"
            for s in all_sels:
                # If there's an enabled custom selection, we target it
                if self._cmd.get_setting_int('enabled', s) == 1:
                    target_sele = s
                    break

            # 3. Additive / Subtractive Toggle
            exists = target_sele in all_sels
            # Check if this residue is already part of the active selection
            already_selected = exists and self._cmd.count_atoms('(%s) and %s' % (target_sele, res_expr)) > 0

            if already_selected:
                # Subtractive selection: remove residue from active selection
                self._cmd.select(target_sele, '(%s) and not %s' % (target_sele, res_expr))
            else:
                # Additive selection: join residue with active selection
                self._cmd.select(target_sele, '(?%s) or %s' % (target_sele, res_expr))

            self._cmd.enable(target_sele)

            # 4. Optional: Only center on Ctrl+Click (matching Seeker's middle-click/modifier paradigm)
            # In pure AppKit, we can check modifier keys via NSEvent:
            # from AppKit import NSEvent, NSControlKeyMask
            # if NSEvent.modifierFlags() & NSControlKeyMask:
            #     self._cmd.center(res_expr, animate=-1)

        except Exception as e:
            print(f"SeqPanel click error: {e}")
```

---

## 📈 Impact & Improvements
By adopting this proposed solution:
* **Peer Consistency:** The Sequence Viewer selections will interact seamlessly with selections created in the 3D viewport (via clicks) and the named selections sidebar.
* **Complex Selections:** Users can select non-contiguous sets of residues across different chains and domains directly from the sequence bar.
* **Viewport Stability:** The camera remains stable during sequential sequence selections, allowing users to build up a visual selection map without the viewport spinning/animating on every character click.
