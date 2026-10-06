// LightsTouch.swift — touch targets for the Lights tools (#623, spec §9).
//
// On iOS every light target is a 44 pt target: a press within 22 pt of its
// centre (or of its line, for the gizmo's rings and the pitch track) hits it.
// That is a floor, not a bigger slop: a target already reached farther by its
// drawn size plus the slop keeps its reach, so only small targets grow, and
// the drawing never changes (spec decision 10: hit areas grow, visuals do
// not). macOS keeps its pointer reach (a floor of 0).
//
// - LightsTouch: the floor, the reach rule and the iOS swatch columns; the
//   orbit view's and the gizmo's hit tests read them, with the profile as a
//   parameter so the macOS unit tests check the iOS numbers too;
// - lightsTouchTarget(): a 44 pt frame for a control's label on iOS (the
//   Lights bar, its chips, the cards' header controls, the gizmo's Shadow
//   chip), keyed by the `lightsTouchMinimum` environment value so snapshot
//   tests on macOS can draw the iOS profile.
//
// Nothing here edits a light or names Python (testing/tests/raymol/
// lighting_mode.py and lighting_touch.py check that).

import SwiftUI

enum LightsTouch {
    /// The smallest target side: 44 pt on iOS (Apple's minimum for a finger),
    /// 0 on macOS (the pointer keeps the drawn size plus the slop).
    static var minimumTarget: CGFloat {
        #if os(iOS)
        return 44
        #else
        return 0
        #endif
    }

    /// How far from its centre (or its line) a target is hit: its drawn size
    /// plus the slop, but never less than half the minimum target.
    static func reach(drawn: CGFloat, slop: CGFloat, minimumTarget: CGFloat) -> CGFloat {
        max(drawn + slop, minimumTarget / 2)
    }

    /// The side of a colour swatch's target on iOS.
    static let swatchTarget: CGFloat = 44

    /// How many columns of 44 pt swatch targets a row of `width` points
    /// holds: all six when they fit side by side, else three (two rows).
    static func swatchColumns(width: CGFloat) -> Int {
        width >= 6 * swatchTarget ? 6 : 3
    }
}

// MARK: - The touch profile in the environment

private struct LightsTouchMinimumKey: EnvironmentKey {
    static let defaultValue: CGFloat = LightsTouch.minimumTarget
}

extension EnvironmentValues {
    /// The smallest control target the Lights views draw: the platform's
    /// `LightsTouch.minimumTarget` (44 on iOS, 0 on macOS). Snapshot tests
    /// set 44 to draw the iOS profile on macOS.
    var lightsTouchMinimum: CGFloat {
        get { self[LightsTouchMinimumKey.self] }
        set { self[LightsTouchMinimumKey.self] = newValue }
    }
}

/// A control label's touch frame: at least the minimum target tall (and
/// wide, unless `width` is false), the whole frame hit-testable. Nothing on
/// macOS (minimum 0).
struct LightsTouchTargetModifier: ViewModifier {
    var width: Bool
    @Environment(\.lightsTouchMinimum) private var minimum

    func body(content: Content) -> some View {
        if minimum > 0 {
            content
                .frame(minWidth: width ? minimum : nil, minHeight: minimum)
                .contentShape(Rectangle())
        } else {
            content
        }
    }
}

extension View {
    /// A 44 pt touch target on iOS, nothing on macOS. Apply it to a button's
    /// or a menu's label (inside the label, where SwiftUI hit-tests the
    /// control), after the label's own background, so the drawing keeps its
    /// size and only the hit area grows.
    func lightsTouchTarget(width: Bool = true) -> some View {
        modifier(LightsTouchTargetModifier(width: width))
    }
}
