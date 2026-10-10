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
//   tests on macOS can draw the iOS profile;
// - the touch routing deciders (LightTwoFingerSequence, LightTouchRouter,
//   LightTouchGeometry, LightAimDoubleTap): the knob pinch, the long-press
//   and option-tap highlights, the touch-down point and the aim dot's
//   double-tap (#699), wired by MetalViewport on iOS.
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

// MARK: - Touch routing (#623 Part 2)
//
// Pure deciders for the viewport's iOS gesture glue (MetalViewport): which
// two-finger sequence is the gizmo's (a pinch on a knob sets that light's
// radius; its pan and twist are swallowed), where a long-press or an
// option-tap places a highlight, and where a one-finger pan really began.
// Everything else stays a camera gesture. They read the gizmo's layout only:
// the writes go through LightGizmoInteraction (owner-guarded bridge setters
// per tick, one `lights` command per press).

enum LightTouchGeometry {
    /// Where a pan's finger came down: UIKit reports `.began` after its own
    /// slop, at `location`, with `translation` already accumulated (#702).
    static func pressPoint(location: CGPoint, translation: CGPoint) -> CGPoint {
        CGPoint(x: location.x - translation.x, y: location.y - translation.y)
    }

    /// The distance between the first two touches, or infinity with fewer
    /// than two (such a sequence is never the gizmo's).
    static func span(_ touches: [CGPoint]) -> CGFloat {
        guard touches.count >= 2 else { return .infinity }
        return hypot(touches[0].x - touches[1].x, touches[0].y - touches[1].y)
    }
}

enum LightTouchMetrics {
    /// The widest finger span (pt) a two-finger sequence may begin with and
    /// still be a pinch on a knob (#623 Q9). A wider pinch near a knob is
    /// the camera's zoom.
    static let knobPinchMaxSpan: CGFloat = 120
}

/// The three recognizers of the two-finger family (they recognize together).
enum LightTwoFingerKind: Hashable, CaseIterable {
    case pinch, pan, rotation
}

/// Who owns a two-finger sequence.
enum LightTwoFingerOwner: Equatable {
    /// The gizmo: a pinch sets this light's radius; the pan and the twist do
    /// nothing (the camera stays put).
    case gizmo(String)
    /// Today's zoom, translate and roll.
    case camera

    var isGizmo: Bool {
        if case .gizmo = self { return true }
        return false
    }
}

/// One two-finger touch sequence: the first recognizer of the family to begin
/// decides its owner, and every recognizer that joins keeps that owner
/// through its `.changed` and `.ended`, so a pan that sent no button-down
/// never sends a button-up, and a twist never runs a turn the pinch did not
/// start. The sequence resets when every recognizer that began has ended.
struct LightTwoFingerSequence {
    private(set) var owner: LightTwoFingerOwner?
    private(set) var active: Set<LightTwoFingerKind> = []

    init() {}

    /// A sequence is under way (some recognizer began and has not ended).
    var isActive: Bool { !active.isEmpty }

    /// `kind` begins with the fingers' centroid at `centroid`, `span` apart.
    /// The first to begin decides: the gizmo's when the span is at most
    /// `knobPinchMaxSpan` and `knob` finds a knob at the centroid (its name
    /// is kept, so the pinch acts on that light wherever the centroid goes
    /// next); else the camera's. Later kinds join the decided owner. A kind
    /// that begins again before it ended (a lost end) starts a new sequence.
    mutating func began(_ kind: LightTwoFingerKind, centroid: CGPoint, span: CGFloat,
                        knob: (CGPoint) -> String?) -> LightTwoFingerOwner {
        if active.contains(kind) { reset() }
        if let owner {
            active.insert(kind)
            return owner
        }
        let decided: LightTwoFingerOwner
        if span.isFinite, span <= LightTouchMetrics.knobPinchMaxSpan, let name = knob(centroid) {
            decided = .gizmo(name)
        } else {
            decided = .camera
        }
        owner = decided
        active.insert(kind)
        return decided
    }

    /// The owner of `kind`'s `.changed`: nil when `kind` has not begun.
    func owner(of kind: LightTwoFingerKind) -> LightTwoFingerOwner? {
        active.contains(kind) ? owner : nil
    }

    /// `kind` ended (or was cancelled or failed): its owner (nil when it had
    /// not begun). The sequence resets once no kind is active.
    @discardableResult
    mutating func ended(_ kind: LightTwoFingerKind) -> LightTwoFingerOwner? {
        let was = owner(of: kind)
        active.remove(kind)
        if active.isEmpty { owner = nil }
        return was
    }

    mutating func reset() {
        owner = nil
        active = []
    }
}

/// What a long-press does in Lights mode.
enum LightLongPressRoute: Equatable {
    /// A highlight for the selected light at the press point (one `lights`
    /// command).
    case highlight
    /// Nothing (a point target, or no light to highlight).
    case ignore
    /// The gizmo is hidden: today's atom context menu.
    case contextMenu
}

/// Where a long-press or an option-tap goes in Lights mode (#623 Q4).
enum LightTouchRouter {
    /// The point targets: a long-press there never begins, so press, hold and
    /// drag still drags the knob, the aim dot or the handle. A ring line is
    /// not one (a ring drag starts by moving; a press held there places a
    /// highlight).
    static func isPointTarget(_ target: LightGizmoTarget) -> Bool {
        switch target {
        case .knob, .aimDot, .outerHandle, .innerHandle: return true
        case .outerRing, .innerRing, .rings: return false
        }
    }

    /// May a long-press begin at `point`? False only on a point target.
    static func shouldBeginLongPress(at point: CGPoint, layout: LightGizmoLayout?) -> Bool {
        guard let layout, let target = LightGizmoHitTest.target(at: point, layout: layout) else { return true }
        return !isPointTarget(target)
    }

    /// A long-press at `point`: a highlight off the point targets (a ring
    /// line included) when a light is selected; the context menu when the
    /// gizmo is hidden (`layout` nil).
    static func longPress(at point: CGPoint, layout: LightGizmoLayout?,
                          hasSelection: Bool) -> LightLongPressRoute {
        guard let layout else { return .contextMenu }
        if let target = LightGizmoHitTest.target(at: point, layout: layout), isPointTarget(target) {
            return .ignore
        }
        return hasSelection ? .highlight : .ignore
    }

    /// An option-tap (iPad hardware keyboard) at `point` places a highlight
    /// when it lands off every target of a shown gizmo; on a target it is an
    /// ordinary tap, and with the gizmo hidden today's pick.
    static func optionTap(at point: CGPoint, layout: LightGizmoLayout?) -> Bool {
        guard let layout else { return false }
        return LightGizmoHitTest.target(at: point, layout: layout) == nil
    }
}

/// #699: a double-tap on the selected light's aim dot (iOS). UIKit's one-tap
/// recognizer reports each tap of a double-tap, so the second is recognised
/// here: the same light's aim dot within `interval` seconds and `slop` points
/// of the first. Any other tap forgets the first.
struct LightAimDoubleTap {
    static let interval: TimeInterval = 0.35
    static let slop: CGFloat = 24

    private(set) var last: (point: CGPoint, time: TimeInterval, light: String)?

    init() {}

    /// A tap at `point` at `time` on `target` (nil: no target) while `light`
    /// is selected. True when it completes a double-tap on the aim dot (and
    /// the pair is forgotten, so a third tap starts over).
    mutating func tap(on target: LightGizmoTarget?, light: String?, at point: CGPoint,
                      time: TimeInterval) -> Bool {
        guard target == .aimDot, let light else {
            last = nil
            return false
        }
        if let first = last, first.light.lowercased() == light.lowercased(),
           (0...Self.interval).contains(time - first.time),
           hypot(point.x - first.point.x, point.y - first.point.y) <= Self.slop {
            last = nil
            return true
        }
        last = (point, time, light)
        return false
    }
}
