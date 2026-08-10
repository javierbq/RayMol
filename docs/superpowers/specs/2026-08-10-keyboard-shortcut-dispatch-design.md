# Keyboard shortcut dispatch (`cmd.set_key`) — design

**Issue:** [RayMol#258](https://github.com/javierbq/RayMol/issues/258)
**Date:** 2026-08-10
**Scope:** macOS only. iPad hardware keyboard is a follow-up.

## Problem

`cmd.set_key` bindings never fire in RayMol. Neither `CTRL-<letter>` nor special keys
(`left`, `pgup`, `F1`, …) have any effect, and PyMOL's own 125 built-in bindings are
equally inert. Reported by Gabriel Rocklin, whose long-standing `obj_arrows.py` startup
script binds `pgup`/`pgdn`/`CTRL-T`/`CTRL-W`/`CTRL-D`/`left`; none of it works.

## Root cause

The Python dispatch layer is intact. The event *source* is missing, in two independent
ways — one per key class.

### `CTRL-<letter>`: the viewport never receives key events

`PyMOLMTKView` sets `acceptsFirstResponder = false`
(`swiftui/PyMOLViewer/Shared/MetalViewport.swift`), deliberately, so a viewport click does
not steal focus from the command line (#73). The view is therefore never in the key
responder chain, `keyDown(with:)` is never called, and
`handleKeyDown` → `engine.key(…)` → `PyMOLBridge_Key` → `PyMOL_Key` is **dead code**. The
comment at that call site already predicts this outcome.

### Special keys: no code path exists

The bridge exposes only `PyMOLBridge_Key` (`swiftui/PyMOLViewer/Bridge/PyMOLBridge.h`).
There is **no** wrapper for `PyMOL_Special` and no caller of `cmd._special` anywhere in the
app. Arrows, `pgup`/`pgdn`, `home`/`end`, `insert`, and `F1`–`F12` are structurally
undeliverable — never built rather than regressed.

### What already works (verified)

Headless, against stock PyMOL using the same `modules/pymol` sources:

```
defaults loaded: 125
left default: _ backward
CTRL-T default: bond;unpick
FIRED: ['left', 'ctrl-t']
```

- `cmd.set_key` (`modules/pymol/controlling.py`) validates and stores into
  `cmd.key_mappings` correctly.
- `_invoke_key` / `_special` / `_ctrl` / `_alt` (`modules/pymol/internal.py`) dispatch
  correctly when called.
- `cmd.key_mappings` is already prepopulated with 125 upstream defaults from
  `modules/pymol/shortcut_dict.py`.
- `~/.raymolrc` already loads at launch, with a one-time `~/.pymolrc` import prompt (#225).

No Python changes are needed for dispatch itself.

## Approaches considered

### A — Swift classifier + dispatch by canonical key token (**chosen**)

Classify the `NSEvent` in Swift into PyMOL's canonical key-token grammar, then call
`internal._invoke_key(token)` through a new synchronous bridge function. Bypasses the
core's line-editing entirely, keeps #73 intact, and makes classification a pure function
that unit-tests without an `NSEvent`.

### B — route through the C++ `PyMOL_Key` / `PyMOL_Special` (rejected)

Superficially attractive: inherits the core's own key behavior, including wizard hooks.
Rejected because `OrthoKey` (`layer1/Ortho.cpp`) is a terminal emulator for the core's
*hidden* prompt, and hardcodes:

| Key | `OrthoKey` meaning |
|---|---|
| `CTRL-M` (13) | carriage return / `OrthoParseCurrentLine` |
| `CTRL-I` (9) | Tab / filename completion |
| `CTRL-V` (22) | `cmd.paste()`, unconditionally |
| `CTRL-H` (8) | backspace |
| `CTRL-[` (27) | Escape |

`PyMOL_Special` additionally grabs `UP`/`DOWN` unconditionally and `LEFT`/`RIGHT` whenever
that prompt holds text (`OrthoArrowsGrabbed`). `set_key` on any of those keys could never
work. RayMol's command line is SwiftUI, not Ortho, so inheriting Ortho's line editing is
pure liability.

### C — re-enable `acceptsFirstResponder` (rejected)

Reverts #73: the command line loses focus on every viewport click.

## Design

### 1. `KeyRouting.swift` — pure classifier

New file, `swiftui/PyMOLViewer/Shared/KeyRouting.swift`. No AppKit state, no engine
reference, no side effects:

```swift
enum KeyRouting {
    /// NSEvent facts -> canonical PyMOL key token, or nil to pass the event through.
    static func token(keyCode: UInt16,
                      charactersIgnoringModifiers: String?,
                      modifiers: NSEvent.ModifierFlags,
                      textFieldFocused: Bool) -> String?
}
```

The character parameter must be `NSEvent.charactersIgnoringModifiers`, **not**
`.characters`: with Control held, `.characters` yields the ASCII control code
(`Ctrl-T` → `\u{14}`), and with Option held it yields the composed glyph
(`Alt-A` → `å`). Only `charactersIgnoringModifiers` gives back the plain letter the
token needs. The existing dead `handleKeyDown` used `.characters`, which would have
mis-tokenized every `ALT-` binding had it ever run.

Token grammar follows `internal.modifier_keys == ['', 'SHFT', 'CTRL', 'CTSH', 'ALT']`, so
valid prefixes are bare, `SHFT-`, `CTRL-`, `CTSH-`, `ALT-`. Special names are lowercase
(`left`, `pgup`); function keys keep their case (`F1`).

Classification rules, in order:

1. `.command` present → `nil`. macOS menus own ⌘, and `set_key`'s grammar has no CMD
   modifier.
2. **Unmodified arrow (`left`/`right`/`up`/`down`) while `textFieldFocused` → `nil`**
   (command line wins; see policy). This guard must precede the special-key mapping
   below, or it can never fire.
3. Special key by `keyCode` → `<prefix->` + name:

   | keyCode | name | | keyCode | name |
   |---|---|---|---|---|
   | 123 | `left` | | 116 | `pgup` |
   | 124 | `right` | | 121 | `pgdn` |
   | 125 | `down` | | 115 | `home` |
   | 126 | `up` | | 119 | `end` |
   | 114 | `insert` | | 122,120,99,118,96,97,98,100,101,109,103,111 | `F1`–`F12` |

4. Letter or digit carrying CTRL / ALT / CTSH → `CTRL-<UPPER>` / `ALT-<UPPER>` /
   `CTSH-<UPPER>`.
5. Anything else (bare printables, `SHFT-<letter>`) → `nil`. `set_key` rejects these
   anyway.

`up`/`down` are dispatchable when the command line is *not* focused, so
`set_key('up', …)` works. Upstream's Qt shortcut editor lists them in
`shortcut_manager.reserved_keys` because it reserves them for command history, but that
editor is not shipped here and rule 2 already protects history where it matters.

`ALT`+`SHFT` on a special key is not representable — `modifier_keys` has no index 5 — so it
classifies as plain `ALT-` and never produces an unmatchable token.

### 2. Focus detection

`NSApp.keyWindow?.firstResponder` is an `NSTextView` (the window's shared field editor,
which is what a focused `NSTextField` actually uses) or an `NSTextField`. Computed at the
monitor, passed into the classifier as a plain `Bool` so the classifier stays pure.

### 3. `PyMOLBridge_InvokeKey` — synchronous dispatch that reports whether it fired

```c
// Returns 1 if a set_key binding fired for `key`, 0 if the key is unbound.
int PyMOLBridge_InvokeKey(const char *key);
```

Implemented in `PyMOLBridge.mm` mirroring the existing `PyMOLBridge_Complete`: take
`PAutoBlock(G)` (PyMOL's GIL model — *not* `PyGILState_Ensure`, which corrupts thread state
against `PyMOL_Idle`'s manual GIL), import `pymol.internal`, call
`_invoke_key(key, 1)`, coerce the result to 0/1, clear any error, `PAutoUnblock`.

Engine wrapper: `PyMOLEngine.invokeKeyBinding(_ token: String) -> Bool`, guarded on
`isReady`.

`_invoke_key` is reached via `pymol.internal` rather than `cmd`, because `cmd` re-exports
only `_special`/`_ctrl`/`_alt`, not `_invoke_key`.

### 4. `installPyMOLKeyMonitor()`

In `ContentView`, beside `installEscKeyMonitor` and sharing its `onAppear`/`onDisappear`
lifecycle and its rationale: an `NSEvent.addLocalMonitorForEvents(matching: .keyDown)`
works regardless of first responder, which is required because #73 keeps the viewport out
of the responder chain.

Body: classify → if `nil`, return the event unchanged → else
`engine.invokeKeyBinding(token)` → return `nil` (consume) if it fired, or the event
(pass through) if it did not.

Esc is keyCode 53 and never yields a token, so this monitor and the Esc monitor do not
interact.

### 5. Shadow-warning audit

New `modules/pymol/raymol_keys.py` holding the app's menu-shortcut table
(`CTRL-M` → Move Objects, `CTRL-D` → Design mode, and the ⌘ entries for completeness) plus
an `audit_shadowed(cmd)` function. Called once after `raymolrc.load()`. Prints one line per
collision:

```
 RayMol: CTRL-D is bound by your startup script; it now overrides the
 Design-mode shortcut (still available from the Mode menu).
```

## Policy decisions

| Decision | Choice | Rationale |
|---|---|---|
| Binding set | Full PyMOL parity: all 125 defaults live, user `set_key` overriding on top | Desktop fidelity for power users; the defaults are already loaded, only undelivered |
| Arrows vs. command line | Command line wins **while it holds keyboard focus** | Preserves caret movement and history; approximates the core's own `OrthoArrowsGrabbed` rule |
| Menu-shortcut conflicts (`⌃M` Move, `⌃D` Design) | Explicit `set_key` wins; audit warns | PyMOL semantics — the user's rc file is the last word. Menu item stays reachable by click |
| ⌘ | Always passes through | macOS menus own it; `set_key` has no CMD modifier |
| Platform | macOS now, iOS follow-up | Engine-side routing is platform-neutral, so iOS is a second key *source*, not a second policy. Same split #235 used for Esc |

The conflict policy needs **no reserved-key table in Swift**: the monitor consumes the
event *iff* a binding fired, so an unbound `CTRL-D` falls through to the Design menu item
naturally, while a user-bound `CTRL-D` shadows it. The Python-side table exists only to
phrase the warning.

## Non-goals

- **Wizard `do_key` / `do_special` hooks.** They live in C++ `WizardDoKey` /
  `WizardDoSpecial`, reachable only via rejected approach B, and are used by 5 niche
  wizards (command, box, pseudoatom, renaming). Follow-up if anyone asks.
- **A shortcut-editor GUI.** `modules/pmg_qt/shortcut_menu_gui.py` is Qt-only and unused
  here. `set_key` from `~/.raymolrc` or the command line is the interface.
- **The upstream `left`-vs-command-line asymmetry.** Gabriel also observed that `left`
  stopped working in *stock* PyMOL years ago while `CTRL-T` kept working: `PyMOL_Special`
  hands `LEFT`/`RIGHT` to the core prompt when it holds text, and the Qt GUI routes arrows
  to the focused command `QLineEdit`. It informs our focus policy but is not ours to fix.

## Verification

The monitor sits in front of **every** key event in the app, so the regression surface is
everything that already responds to a keystroke. Non-regression carries equal weight with
the fix itself.

### Unit

1. **Table-driven XCTest** over `KeyRouting.token`: arrows focused vs. unfocused, ctrl/alt
   letters, ⌘ passthrough, F-keys, modified specials, bare printables, `SHFT-<letter>`,
   and the `charactersIgnoringModifiers` cases (`Ctrl-T` must not tokenize as `\u{14}`;
   `Alt-A` must not tokenize as `å`).
2. **Embedded-Python test** asserting `_invoke_key` fires a user binding, returns false for
   an unbound key, and that the 125-entry default dict loads.

### Regression — existing shortcuts must behave exactly as they do today

Every item below is verified **twice**: once with no `~/.raymolrc`, and once with Gabriel's
`obj_arrows.py` installed (which binds `CTRL-D`, so it exercises the shadow path).

**A. Menu shortcuts carrying ⌘** — rule 1 passes these through untouched, so they should be
structurally immune. Confirm anyway, since a mistake here breaks File-menu basics:

| Shortcut | Command |
|---|---|
| ⌘O / ⇧⌘O | Open… / Fetch from PDB… |
| ⌘S / ⇧⌘S | Save Session / Save Session As… |
| ⇧⌘E | Export Image… |
| ⌘C | Copy Image to Clipboard |
| ⌥⌘M | Edit Timeline |
| ⌃⌘M | Enable AI control (MCP) |

**B. Menu shortcuts *without* ⌘ — the critical case.** `⌃M` (Move Objects) and `⌃D`
(Design mode, `RAYMOL_MPNN`-gated) are not ⌘-modified, so they *do* reach the classifier and
*do* produce tokens `CTRL-M` / `CTRL-D`. Neither appears in the 125 defaults, so
`_invoke_key` returns 0 and the event must fall through to the menu.

- With no user bindings: `⌃M` still toggles Move mode; `⌃D` still toggles Design mode.
  **This is the single most important regression test in the plan** — it is the one place
  where the consume-iff-fired rule carries the whole conflict policy.
- With `set_key('CTRL-D', move_down)` loaded: `⌃D` runs the user's function instead, the
  shadow warning is logged once, and the Design menu item still works by click.

**C. Command panel field-editor paths** (`CommandPanel.swift`) — all while the field holds
focus: Return submits, Tab completes, ↑/↓ recall history, ←/→ move the caret. Return and
Tab produce no token; the arrows are covered by rule 2. A failure here means rule 2 is
mis-ordered.

**D. The Esc ladder** (#163 / #166 / #235) — Esc is keyCode 53 and must yield no token, so
the existing Esc monitor still sees it: dismisses a sheet/panel/popover, else exits an
active Move/Design/Measure mode, else two-stage clears the selection.

**E. Sheets and modals** — the Timeline panel's `.cancelAction` / `.defaultAction` buttons
(Esc / Return) and the What's New modal's `.defaultAction` (Return).

**F. Newly-live defaults, which are a behavior change by design** — with no user rc,
`left`/`right` now step movie frames, `pgup`/`pgdn` change scenes, `home` zooms all.
Confirm they fire when the viewport has focus and do *not* fire while the command line is
focused.

### Functional

Run B–F in a disposable macOS VM per the `raymol-mac-vm` workflow, then the fix itself:
Gabriel's actual `obj_arrows.py` as `~/.raymolrc`, pressing `left`, `pgup`, `pgdn`, and
`CTRL-T` and confirming each runs its bound function.

## Note for affected users

Gabriel's script binds `pgup`/`pgdn` (overriding PyMOL's scene prev/next) and `left`
(overriding movie-frame backward). That is correct `set_key` behavior and exactly what the
script asks for, but it does change those defaults for him — worth saying when we tell him
it's fixed.
