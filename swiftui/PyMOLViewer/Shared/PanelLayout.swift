// PanelLayout.swift — the persisted panel-layout contract shared by the macOS and
// iOS layouts in ContentView (#331 console default, #332 persistence).
//
// Two responsibilities, both deliberately free of SwiftUI:
//
//   1. The UserDefaults key namespace (`raymol.panels.*`). Both platform layouts
//      read the SAME keys through @AppStorage, so a pane's visibility survives a
//      relaunch — and, on a device that runs both idioms, means the same thing.
//   2. The sizing arithmetic. Sizes are stored as FRACTIONS of the window
//      dimension, never as absolute points: a height that was sensible in a
//      1600pt window must not be restored into a 700pt one, where it would leave
//      no viewport. Fractions are clamped on the way in AND on the way out.
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
    /// Console height as a fraction of the window height (#331 default 0.2).
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

    /// #331: a fresh launch puts the console at a fifth of the window height.
    static let defaultConsoleFrac: CGFloat = 0.2
    /// Hard ceiling on the console's share. Outranks the caller's minimum height
    /// (see `consoleHeight`) so the viewport always keeps 60% of the window.
    static let maxConsoleFrac: CGFloat = 0.4
    /// Floor on what we're willing to STORE. A user who drags the console shut is
    /// expressing "hidden", which the visibility flag records; storing ~0 here
    /// would instead restore an unusable sliver.
    static let minStorableFrac: CGFloat = 0.01

    /// macOS console height used only for the single layout pass before the left
    /// column has reported a height (the pre-#331 launch default).
    static let macConsoleFallback: CGFloat = 60
    /// Usable console minimums: the macOS splitter pane vs. the iOS drag divider.
    static let macMinConsoleHeight: CGFloat = 44
    static let iosMinConsoleHeight: CGFloat = 60

    static let defaultPanelFrac: CGFloat = 0.53
    static let minPanelFrac: CGFloat = 0.2
    static let maxPanelFrac: CGFloat = 0.8

    // MARK: - Console sizing

    /// The console's height in a window of `windowHeight`, from a stored fraction.
    ///
    /// `minHeight` is the platform's usable floor (44pt on macOS, 60pt on iOS).
    /// When the 40% ceiling falls below that floor — a very short window — the
    /// CEILING WINS: better a cramped console than no viewport.
    ///
    /// A missing, zero, negative or non-finite `frac` (an unset UserDefaults
    /// Double reads as 0) falls back to `defaultConsoleFrac`.
    static func consoleHeight(frac: CGFloat, windowHeight: CGFloat,
                              minHeight: CGFloat) -> CGFloat {
        guard windowHeight.isFinite, windowHeight > 0 else { return minHeight }
        let f = (frac.isFinite && frac > 0) ? frac : defaultConsoleFrac
        return min(max(f * windowHeight, minHeight), maxConsoleFrac * windowHeight)
    }

    /// The fraction to persist for a console measured at `height`. Inverse of
    /// `consoleHeight`, clamped into `[minStorableFrac, maxConsoleFrac]` so
    /// nothing unrestorable can ever be written.
    static func consoleFrac(height: CGFloat, windowHeight: CGFloat) -> CGFloat {
        guard windowHeight.isFinite, windowHeight > 0,
              height.isFinite else { return defaultConsoleFrac }
        return min(max(height / windowHeight, minStorableFrac), maxConsoleFrac)
    }

    // MARK: - iPad bottom panel

    /// Clamp a restored iPad panel share into a band that leaves both the panel
    /// and the viewport usable. Zero (unset) or non-finite falls back to default.
    static func clampPanelFrac(_ frac: CGFloat) -> CGFloat {
        guard frac.isFinite, frac > 0 else { return defaultPanelFrac }
        return min(max(frac, minPanelFrac), maxPanelFrac)
    }
}
