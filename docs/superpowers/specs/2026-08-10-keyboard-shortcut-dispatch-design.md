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
                      textFieldFocused: Bool,
                      textEditingActive: Bool) -> String?
}
```

> **Amendment (2026-08-10):** The signature takes two booleans — see the amendment
> section below for the distinction and why `textFieldFocused` alone is insufficient.

The character parameter must be `NSEvent.charactersIgnoringModifiers`, **not**
`.characters`: with Control held, `.characters` yields the ASCII control code
(`Ctrl-T` → `\u{14}`), and with Option held it yields the composed glyph
(`Alt-A` → `å`). Only `charactersIgnoringModifiers` gives back the plain letter the
token needs. The existing dead `handleKeyDown` used `.characters`, which would have
mis-tokenized every `ALT-` binding had it ever run.

Token grammar follows `internal.modifier_keys == ['', 'SHFT', 'CTRL', 'CTSH', 'ALT']`, so
valid prefixes are bare, `SHFT-`, `CTRL-`, `CTSH-`, `ALT-`. Special names are lowercase
(`left`, `pgup`); function keys keep their case (`F1`).

Classification rules, in order (see amendment for the two-tier yield policy):

1. `.command` present → `nil`. macOS menus own ⌘, and `set_key`'s grammar has no CMD
   modifier.
2. **Tier A — while `textFieldFocused` (even empty field):** `ALT-<letter>`,
   `ALT-<digit>`, and `CTSH-<letter>` → `nil`. Rationale: Option is the compose modifier
   on non-US keyboards (German `@`=⌥L, `[`=⌥5); PyMOL's ALT defaults create objects.
   ⌃⇧ combos are macOS extend-selection chords. See amendment for the complete rule.
   **Tier B — while `textEditingActive` (focused AND non-empty):** ANY arrow (all
   modifiers), ANY `home`/`end` (all modifiers), and `CTRL-<editing-letters>` → `nil`.
   This guard must precede the special-key mapping below, or it can never fire.
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
which is what a focused `NSTextField` actually uses) or an `NSTextField`. Two `Bool`
values are computed at the monitor and passed into the classifier:

- `textFieldFocused` — the responder is an **editable** NSTextView or NSTextField (i.e.
  `tv.isEditable || tv.isFieldEditor`, or `tf.isEditable`). Read-only/selectable text
  views (e.g. the feedback log, which uses `.textSelection(.enabled)`) are excluded:
  their `string` could be the entire log and would falsely disable all arrow dispatch.
- `textEditingActive` — `textFieldFocused` AND the field is non-empty.

> **Amendment (2026-08-10):** the original design passed only `textFieldFocused`; two
> booleans are required — see the amendment section below for the two-tier yield rule.

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
(`CTRL-M` → Move Objects, `CTRL-D` → Design mode). Note: ⌘ shortcuts are deliberately
**absent** from `APP_SHORTCUTS` — ⌘ never reaches the classifier (rule 1), so there is
nothing to audit. A comment in the module explains this. The actual signature is:

```python
def audit_shadowed(has_design=False, _self=None) -> list[str]:
```

Called once after `raymolrc.load()` (as a separate `runPython` call so a broken audit
cannot abort the startup script). Prints one line per collision:

```
 RayMol: CTRL-D is bound by your startup script; it now overrides the "Enter/Exit Design Mode (Design menu)" shortcut (the menu item still works by click).
```

The `has_design` parameter controls whether `CTRL-D` is included (it only exists in
`RAYMOL_MPNN` builds).

## Policy decisions

| Decision | Choice | Rationale |
|---|---|---|
| Binding set | Full PyMOL parity: all 125 defaults live, user `set_key` overriding on top | Desktop fidelity for power users; the defaults are already loaded, only undelivered |
| Text editing vs. bindings | The focused field wins **only while it actually has text** (amended — see below) | Preserves caret movement, history and the emacs editing keys mid-typing, while leaving every binding reachable from the resting state. This *is* the core's `OrthoArrowsGrabbed` rule |
| Menu-shortcut conflicts (`⌃M` Move, `⌃D` Design) | Explicit `set_key` wins; audit warns | PyMOL semantics — the user's rc file is the last word. Menu item stays reachable by click |
| ⌘ | Always passes through | macOS menus own it; `set_key` has no CMD modifier |
| Platform | macOS now, iOS follow-up | Engine-side routing is platform-neutral, so iOS is a second key *source*, not a second policy. Same split #235 used for Esc |

The conflict policy needs **no reserved-key table in Swift**: the monitor consumes the
event *iff* a binding fired, so an unbound `CTRL-D` falls through to the Design menu item
naturally, while a user-bound `CTRL-D` shadows it. The Python-side table exists only to
phrase the warning.

### Amendment (2026-08-10): the focus exemption is content-aware, not focus-only

The original rule — "the command line wins while it holds keyboard focus", exempting
unmodified arrows — was found during implementation review to be wrong in both directions.

Because `acceptsFirstResponder` is `false` (#73), the command line holds focus by *default*,
so the monitor sits in front of a focused text field essentially all the time. Exempting
only arrows meant PyMOL's built-in `home` → `zoom animate=-1` and `end` → `mtoggle`, plus
`CTRL-A/F/H/I/L/T/V/X`, fired *while the user was typing a command*: End toggled movie
playback instead of moving the caret, `⌃A` selected all atoms, `⌃H` opened help instead of
deleting a character. Exempting all of those unconditionally would have been just as wrong
— it makes `CTRL-T`, `CTRL-D`, `CTRL-P` and `CTRL-B` unreachable in the default focused
state, which is most of a real user's rc file.

**The rule is therefore content-aware.** The focused field wins only while it is
**non-empty**:

- **Empty prompt** (the resting state) — everything dispatches. Bindings are reachable
  without clicking the viewport first.
- **Non-empty prompt** — the field owns unmodified arrows, unmodified `home`/`end`, and the
  macOS text-editing control letters **A B D E F H K L N O P T V Y**. Everything else still
  dispatches: `pgup`/`pgdn` and F-keys are never text-editing keys, and neither are ⌃
  combinations outside that set (`CTRL-W`, `CTRL-G`, …).

This is not a new invention — it is precisely the core's own `OrthoArrowsGrabbed` test
(`I->CurChar > I->PromptChar`, `layer1/Ortho.cpp:414`), which the approaches section had
already identified as "closest to desktop PyMOL". The classifier's parameter is named
`textEditingActive` rather than `textFieldFocused` to keep the distinction honest.

Two smaller corrections landed with it: the monitor now mirrors the Esc handler's
modal/sheet/panel guard (otherwise `pgup` changed scenes behind an open sheet), and the
`~/.raymolrc` load and the shadow audit are separate `runPython` calls so a failure in the
audit can never abort the user's startup script.

### Two-tier yield rule (final policy, supersedes "focused vs. unfocused" framing)

A second review found that even the content-aware rule was incomplete: on **non-US
keyboards** Option is the compose modifier (German `@`=⌥L, `[`=⌥5, `]`=⌥6, `{`=⌥8,
`}`=⌥9, `|`=⌥7; Spanish `|`=⌥1, `@`=⌥2, `#`=⌥3), so every `ALT-<letter>` and
`ALT-<digit>` token that PyMOL's defaults bind to `editor.attach_amino_acid` or
`attach_fragment` would fire while the user was literally typing those characters into
the command line — even with an **empty** field (so the content-aware rule wouldn't
catch it). `CTSH-<letter>` has the same problem: ⌃⇧A/E/F/B/N/P are macOS
extend-selection chords, and PyMOL binds `CTSH-A` → `redo`, `CTSH-N` → `replace N,4,3`,
etc. Upstream PyMOL patched one symptom of this (`layer1/Ortho.cpp:836`, `'@'` special
case) but did not close the root cause.

The fix splits the yield into **two tiers**:

**Tier A — yield whenever `textFieldFocused`, content irrelevant:**
- `ALT-<letter>` and `ALT-<digit>` → `nil` (compose modifier on non-US keyboards).
- `CTSH-<letter>` → `nil` (extend-selection chords).
These must not dispatch the moment an editable field is focused, regardless of whether
it is empty.

**Tier B — yield only when `textEditingActive` (focused AND non-empty):**
- **Any** arrow key (all modifiers) → `nil`. ⌥←/⌥→ = word-movement; ⇧← = extend
  selection. Every modified arrow is a text-navigation gesture mid-typing.
- **Any** `home`/`end` (all modifiers) → `nil`. ⇧Home extends selection.
- `CTRL-<A B D E F H K L N O P T V Y>` with no Option → `nil` (emacs editing chords).

**Never yield (no text-field meaning at any time):**
`pgup`, `pgdn`, `insert`, `F1`–`F12` — these dispatch even mid-typing.

The classifier signature therefore takes two booleans:
```swift
static func token(…, textFieldFocused: Bool, textEditingActive: Bool) -> String?
```

`ContentView` computes them by requiring the first responder to be **editable**
(`tv.isEditable || tv.isFieldEditor` for NSTextView; `tf.isEditable` for NSTextField),
specifically excluding read-only/selectable views like the feedback log.

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

1. **Table-driven XCTest** over `KeyRouting.token` (see amendment for two-tier policy):
   `ALT-<letter>`/`CTSH-<letter>` yield when `textFieldFocused` even with empty field
   (Tier A); modified arrows and `home`/`end` yield when `textEditingActive` (Tier B);
   `pgup`/`pgdn`/F-keys dispatch even when both flags are true; ctrl/alt letters,
   ⌘ passthrough, modified specials, bare printables, `SHFT-<letter>`, and the
   `charactersIgnoringModifiers` cases (`Ctrl-T` must not tokenize as `\u{14}`;
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
Tab produce no token; the arrows are covered by the Tier B yield (amendment). Also verify
that Option-key composition (`⌥L` → `@` on German layout) passes through untouched when
the field is focused — this is the Tier A guard. A failure here means rule 2 is
mis-ordered or the Tier A/B split is wrong.

**D. The Esc ladder** (#163 / #166 / #235) — Esc is keyCode 53 and must yield no token, so
the existing Esc monitor still sees it: dismisses a sheet/panel/popover, else exits an
active Move/Design/Measure mode, else two-stage clears the selection.

**E. Sheets and modals** — the Timeline panel's `.cancelAction` / `.defaultAction` buttons
(Esc / Return) and the What's New modal's `.defaultAction` (Return).

**F. Newly-live defaults, which are a behavior change by design** — with no user rc,
`left`/`right` now step movie frames, `pgup`/`pgdn` change scenes, `home` zooms all.
Confirm they fire when the field is empty AND do *not* fire while the command line holds
text (Tier B). `pgup`/`pgdn` must still fire even while the field holds text (they are
never text-navigation gestures — see amendment).

### Functional

Run B–F in a disposable macOS VM per the `raymol-mac-vm` workflow, then the fix itself:
Gabriel's actual `obj_arrows.py` as `~/.raymolrc`, pressing `left`, `pgup`, `pgdn`, and
`CTRL-T` and confirming each runs its bound function.

## Note for affected users

Gabriel's script binds `pgup`/`pgdn` (overriding PyMOL's scene prev/next) and `left`
(overriding movie-frame backward). That is correct `set_key` behavior and exactly what the
script asks for, but it does change those defaults for him — worth saying when we tell him
it's fixed.
