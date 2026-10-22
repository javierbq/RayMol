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
    /// The user's macOS inspector (right column) width, as a fraction of the
    /// window width. Absent until they drag the seam (#350), which is what
    /// selects the absolute default width.
    static let inspectorFracKey = ns + "inspectorFrac"
    /// iPad bottom-panel share of the screen.
    static let panelFracKey = ns + "panelFrac"
    /// Sequence strip visible. Written by PyMOLEngine, which owns the flag.
    static let sequenceVisibleKey = ns + "sequenceVisible"
    /// The corner the iPad's floating orbit view snapped to last (#623;
    /// LightsFloatCorner raw value, `bl` when absent).
    static let lightsOrbitCornerKey = ns + "lightsOrbitCorner"

    /// Every key this type defines — the namespace/uniqueness check in the tests
    /// runs off this list, so a new key must be added here too.
    static let allKeys: [String] = [
        consoleVisibleKey, objectsVisibleKey,
        landscapeConsoleVisibleKey, landscapeObjectsVisibleKey,
        consoleFracKey, inspectorFracKey, panelFracKey, sequenceVisibleKey,
        lightsOrbitCornerKey,
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

    /// #350: the macOS inspector column's width on a launch with nothing stored.
    /// ABSOLUTE points for the same reason as the console default — an untouched
    /// inspector looks the same on a laptop and on a 6K display. #914: 380, up
    /// from the 340 the narrow-inspector redesign settled on — the five-label tab
    /// bar's segmented control is 355pt wide intrinsically (measured) plus 10pt
    /// side padding, 375pt in all, so at 340 it overdrew the column by ~17pt each
    /// side (hidden under the seam until a full-width panel exposed it). The
    /// extra 5pt is margin for label/font differences.
    ///
    /// It is also the unit every narrow-window rule is built from — the
    /// window's minimum width, the inspector's minimum, the viewport's share, and
    /// (doubled) the width below which the inspector stops docking.
    static let macDefaultInspectorWidth: CGFloat = 380
    /// The narrowest the inspector may be while docked. #914: the default width,
    /// not the old 280 — anything narrower than the tab bar clipped it and let
    /// the column's content spill over the viewport.
    static let macMinInspectorWidth: CGFloat = macDefaultInspectorWidth
    /// The macOS window's minimum width (#914): one inspector's worth, so the
    /// inspector always fits when the user opens it full-width.
    static let macMinWindowWidth: CGFloat = macDefaultInspectorWidth
    /// The inspector docks beside the viewport only in a window at least this wide
    /// (#914) — room for a minimum inspector AND a viewport of the same width.
    /// Narrower, it auto-hides, and opening it covers the whole window.
    static let macInspectorDockWindowWidth: CGFloat = 2 * macDefaultInspectorWidth
    /// Layout width of the seam between viewport and inspector (macInspectorDivider:
    /// a 1pt hairline plus its 8pt grab band).
    static let macInspectorSeamWidth: CGFloat = 9
    /// The macOS viewport's own minimum WIDTH. The seam is taken out of the
    /// viewport's half, so a window exactly `macInspectorDockWindowWidth` wide
    /// still docks a minimum inspector without overflowing.
    static let macViewportMinWidth: CGFloat = macDefaultInspectorWidth - macInspectorSeamWidth

    // MARK: - macOS inspector presentation (#914)

    /// How the macOS inspector column is shown.
    enum MacInspectorPresentation: Equatable {
        /// Not shown; its tongue rides the viewport's trailing edge.
        case hidden
        /// Beside the viewport, `inspectorWidth` wide.
        case docked
        /// Covering the whole window — opened by the user in a window too narrow
        /// to dock it.
        case fullWidth
    }

    /// Whether a window of `windowWidth` is too narrow to dock the inspector.
    static func macInspectorIsNarrow(windowWidth: CGFloat) -> Bool {
        windowWidth < macInspectorDockWindowWidth
    }

    /// The inspector's presentation in a window of `windowWidth`.
    ///
    /// `userShown` is the persisted side-panel flag — the user's own choice, which
    /// a window shrink never writes. `narrowOpen` is the session-only "opened while
    /// narrow" flag, cleared whenever the window crosses the dock width. So:
    /// wide → `userShown` decides; narrow → hidden (auto-hidden) unless the user
    /// opened it there, and then it takes the whole window. Growing back past the
    /// dock width re-docks whatever `userShown` says, which is what reopens an
    /// auto-hidden panel and keeps a panel the user closed closed.
    static func macInspectorPresentation(windowWidth: CGFloat, userShown: Bool,
                                         narrowOpen: Bool) -> MacInspectorPresentation {
        if macInspectorIsNarrow(windowWidth: windowWidth) {
            return narrowOpen ? .fullWidth : .hidden
        }
        return userShown ? .docked : .hidden
    }

    // MARK: - macOS inspector sizing (#350)

    /// How wide the docked inspector is allowed to get in a window of
    /// `windowWidth`: everything but the viewport's minimum and the seam, and
    /// never more than half the window (the viewport must remain the main event).
    /// #914: never below the inspector's own minimum either — a window too narrow
    /// for both doesn't dock at all (see `macInspectorPresentation`), so the
    /// viewport no longer wins by squeezing the inspector.
    static func maxInspectorWidth(windowWidth: CGFloat,
                                  viewportMin: CGFloat = macViewportMinWidth) -> CGFloat {
        guard windowWidth.isFinite, windowWidth > 0 else { return macMinInspectorWidth }
        return max(min(windowWidth - viewportMin - macInspectorSeamWidth, windowWidth * 0.5),
                   macMinInspectorWidth)
    }

    /// The docked inspector's width in a window of `windowWidth`.
    ///
    /// `frac` is the persisted share and applies only once the user has dragged
    /// the seam themselves; a missing, zero, negative or non-finite value (an
    /// unset UserDefaults Double reads as 0) means "untouched" and yields the
    /// absolute default. The result is clamped into [macMinInspectorWidth,
    /// maxWidth].
    static func inspectorWidth(frac: CGFloat, windowWidth: CGFloat,
                               maxWidth: CGFloat) -> CGFloat {
        guard windowWidth.isFinite, windowWidth > 0 else { return macMinInspectorWidth }
        let w = (frac.isFinite && frac > 0) ? frac * windowWidth : macDefaultInspectorWidth
        return min(max(w, macMinInspectorWidth), max(maxWidth, macMinInspectorWidth))
    }

    /// The fraction to persist for an inspector measured at `width`, clamped into
    /// the storable band so nothing unrestorable can ever be written. nil for a
    /// degenerate window — there is nothing meaningful to store, so don't write.
    static func inspectorFrac(width: CGFloat, windowWidth: CGFloat) -> CGFloat? {
        guard windowWidth.isFinite, windowWidth > 0, width.isFinite else { return nil }
        return min(max(width / windowWidth, minStorableFrac), maxStorableFrac)
    }

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

// MARK: - iPhone viewport chrome auto-fade (#391)

/// The iPhone's camera button and panel tongue float over the molecule, so they
/// fade out of the way: fully shown for `idleDelay` after the last touch, dimmed
/// (still tappable) after that, and gone while a viewport gesture is in progress.
/// Pure so the rule is testable from the macOS test host; ContentView feeds it the
/// clock and the viewport's gesture state. Times are seconds on a MONOTONIC clock
/// (`ProcessInfo.systemUptime`), so a wall-clock change can't stall the dim.
enum PhoneChromeFade {
    /// Seconds of no interaction before the controls dim.
    static let idleDelay: TimeInterval = 3
    /// Opacity once idle: faint but still tappable, so reaching for the button
    /// never needs a touch on the molecule first (a tap there picks atoms).
    static let idleOpacity: Double = 0.25
    /// Opacity while a rotate / pan / pinch is in progress: out of the way.
    static let gestureOpacity: Double = 0
    /// Duration of the opacity animation.
    static let fadeDuration: Double = 0.25

    struct Appearance: Equatable {
        var opacity: Double
        var isHitTestable: Bool
    }

    /// `pinned` keeps the controls fully shown (not an iPhone, VoiceOver on, or
    /// the camera dock open).
    static func appearance(now: TimeInterval, lastInteraction: TimeInterval,
                           gestureActive: Bool, pinned: Bool) -> Appearance {
        if pinned { return Appearance(opacity: 1, isHitTestable: true) }
        if gestureActive { return Appearance(opacity: gestureOpacity, isHitTestable: gestureOpacity > 0) }
        if now - lastInteraction < idleDelay {
            return Appearance(opacity: 1, isHitTestable: true)
        }
        return Appearance(opacity: idleOpacity, isHitTestable: idleOpacity > 0)
    }

    /// When `appearance` will next change with no new input: the idle deadline
    /// while it is still ahead, nil otherwise (pinned, mid-gesture, or already dim).
    static func nextChange(now: TimeInterval, lastInteraction: TimeInterval,
                           gestureActive: Bool, pinned: Bool) -> TimeInterval? {
        guard !pinned, !gestureActive else { return nil }
        let deadline = lastInteraction + idleDelay
        return deadline > now ? deadline : nil
    }
}
