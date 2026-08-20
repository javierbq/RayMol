// PanelLayout.swift — the persisted panel-layout contract shared by the macOS and
// iOS layouts in ContentView (#331 console default, #332 persistence).
//
// Two responsibilities, both deliberately free of SwiftUI:
//
//   1. The UserDefaults key namespace (`raymol.panels.*`). Both platform layouts
//      read the SAME keys through @AppStorage, so a pane's visibility survives a
//      relaunch — and, on a device that runs both idioms, means the same thing.
//   2. The sizing arithmetic. A size the USER chose is stored as a FRACTION of
//      the window dimension, never as absolute points: a height that was sensible
//      in a 1600pt window must not be restored into a 700pt one, where it would
//      leave no viewport. Fractions are clamped on the way in AND on the way out.
//      The untouched DEFAULT is the opposite — absolute points — so a console
//      nobody has resized looks the same on a laptop and on a 6K display.
//
// Everything here is a pure function of its arguments so PanelLayoutTests can
// pin the boundaries without a window.

import CoreGraphics
import Foundation

enum PanelLayout {

    // MARK: - Keys

    private static let ns = "raymol.panels."

    /// Console (CommandPanel) visible. macOS + iPad; iPhone landscape has its own.
    static let consoleVisibleKey = ns + "consoleVisible"
    /// Inspector / Objects panel visible. macOS + iPad.
    static let objectsVisibleKey = ns + "objectsVisible"
    /// iPhone-LANDSCAPE pane visibility, kept separate from the iPad bools so that
    /// layout keeps starting minimal (console off, objects on) — see ContentView.
    static let landscapeConsoleVisibleKey = ns + "landscapeConsoleVisible"
    static let landscapeObjectsVisibleKey = ns + "landscapeObjectsVisible"
    /// The user's console height, as a fraction of the window height. Absent
    /// until they resize it, which is what selects the absolute default (#331).
    static let consoleFracKey = ns + "consoleFrac"
    /// iPad bottom-panel share of the screen.
    static let panelFracKey = ns + "panelFrac"
    /// Sequence strip visible. Written by PyMOLEngine, which owns the flag.
    static let sequenceVisibleKey = ns + "sequenceVisible"

    /// Every key this type defines — the namespace/uniqueness check in the tests
    /// runs off this list, so a new key must be added here too.
    static let allKeys: [String] = [
        consoleVisibleKey, objectsVisibleKey,
        landscapeConsoleVisibleKey, landscapeObjectsVisibleKey,
        consoleFracKey, panelFracKey, sequenceVisibleKey,
    ]

    // MARK: - Bounds

    /// #331: the console's height on a launch with nothing stored. ABSOLUTE
    /// points, not a share of the window, so it matches what the app has always
    /// shown on any display — a fifth of a large monitor is far more room than the
    /// console needs by default. A size the user drags to IS stored as a fraction
    /// (see `consoleFrac`); only this untouched default is fixed.
    static let macDefaultConsoleHeight: CGFloat = 130
    static let iosDefaultConsoleHeight: CGFloat = 110
    /// Storable band. The floor exists because a user who drags the console shut
    /// is expressing "hidden", which the visibility flag records; storing ~0 here
    /// would instead restore an unusable sliver on the next launch.
    static let minStorableFrac: CGFloat = 0.01
    static let maxStorableFrac: CGFloat = 0.95

    /// Usable console minimums: the macOS pane vs. the iOS drag divider.
    static let macMinConsoleHeight: CGFloat = 44
    static let iosMinConsoleHeight: CGFloat = 60
    /// Floor under the growth ceiling (see `maxConsoleHeight`): in a window too
    /// short to satisfy the viewport minimum, the console may still take this
    /// share rather than collapsing to nothing.
    static let minCeilingFrac: CGFloat = 0.2
    /// The macOS viewport's own minimum. The console may grow until the viewport
    /// is down to this, which is what keeps #317 ("drag it open to read a long
    /// predict log") working while still guaranteeing a viewport.
    static let macViewportMinHeight: CGFloat = 360

    static let defaultPanelFrac: CGFloat = 0.53
    static let minPanelFrac: CGFloat = 0.2
    static let maxPanelFrac: CGFloat = 0.8

    // MARK: - Console sizing

    /// How tall the console is allowed to get in a window of `windowHeight`, given
    /// a pane below it that needs `viewportMin`.
    ///
    /// Normally that's "everything except the viewport's minimum" — 324pt of a
    /// 684pt window — which is generous enough to read a long log in. Two guards
    /// bracket it: never more than 85% of the window (the viewport must remain a
    /// viewport), and never less than `minCeilingFrac`.
    static func maxConsoleHeight(windowHeight: CGFloat,
                                 viewportMin: CGFloat = macViewportMinHeight) -> CGFloat {
        guard windowHeight.isFinite, windowHeight > 0 else { return 0 }
        return min(max(windowHeight - viewportMin, windowHeight * minCeilingFrac),
                   windowHeight * 0.85)
    }

    /// The console's height in a window of `windowHeight`.
    ///
    /// `frac` is the persisted share, and applies only once the user has sized the
    /// console themselves; a missing, zero, negative or non-finite value (an unset
    /// UserDefaults Double reads as 0) means "untouched" and yields `defaultHeight`
    /// — an absolute size, so an untouched console looks the same on a laptop and
    /// on a 6K display.
    ///
    /// `minHeight` is the platform's usable floor; `maxHeight` the platform's
    /// ceiling (`maxConsoleHeight` on macOS, the layout's own 33% rule on iOS).
    /// The CEILING WINS when the two cross — in a very short window, better a
    /// cramped console than no viewport.
    static func consoleHeight(frac: CGFloat, windowHeight: CGFloat,
                              defaultHeight: CGFloat,
                              minHeight: CGFloat, maxHeight: CGFloat) -> CGFloat {
        guard windowHeight.isFinite, windowHeight > 0 else { return minHeight }
        let h = (frac.isFinite && frac > 0) ? frac * windowHeight : defaultHeight
        return min(max(h, minHeight), maxHeight)
    }

    /// The fraction to persist for a console measured at `height`, clamped into
    /// the storable band so nothing unrestorable can ever be written. nil for a
    /// degenerate window — there is nothing meaningful to store, so don't write.
    static func consoleFrac(height: CGFloat, windowHeight: CGFloat) -> CGFloat? {
        guard windowHeight.isFinite, windowHeight > 0, height.isFinite else { return nil }
        return min(max(height / windowHeight, minStorableFrac), maxStorableFrac)
    }

    // MARK: - iPad bottom panel

    /// Clamp a restored iPad panel share into a band that leaves both the panel
    /// and the viewport usable. Zero (unset) or non-finite falls back to default.
    static func clampPanelFrac(_ frac: CGFloat) -> CGFloat {
        guard frac.isFinite, frac > 0 else { return defaultPanelFrac }
        return min(max(frac, minPanelFrac), maxPanelFrac)
    }
}
