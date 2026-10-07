// LightsFloatingTools.swift — the iPad's floating orbit view (#623, spec §9,
// sketch 4).
//
// On regular width and height (iPad; LightsToolsPlacement.floating) the
// #621 orbit card floats over the viewport in one of its four corners,
// bottom-leading by default, and the #620 inspector stays at the top
// trailing corner, starting collapsed to its header. With both defaults the
// three_point rig's knobs stay outside the cards at the default panel sizes
// (#692's iPad case; LightsFloatLayoutTests pins it).
// - The orbit card's header row is its grip: drag it and it snaps, on
//   release, to the corner nearest where the drag would have ended (a fling
//   throws it). A cancelled drag leaves nothing behind (@GestureState).
// - The corner is remembered (PanelLayout.lightsOrbitCornerKey).
// - The cards keep clear of the viewport's bottom chrome: the Gesture help
//   button (trailing), the camera button and scene buttons (leading, as
//   measured, ViewportChromeHeightsKey) and an open CameraDock (both).
// - A card sharing the trailing edge with the inspector stacks with it; the
//   inspector's content scrolls in what is left.
// - VoiceOver: the grip is an element with the corner as its value and one
//   `Move to <corner>` action per other corner.
// Empty space passes touches through to the viewport (the camera's).
//
// Like the side column it holds the controller as a plain `let`; each card
// observes what it shows. Every edit goes through the cards' own paths
// (LightsOrbitInteraction, the controller's typed API): no Python per tick
// (#610). This file names no Python, console command or bridge function
// (testing/tests/raymol/lighting_mode.py and lighting_touch.py check that).
// The pure parts (corner, metrics, layout, strings) are unit-tested in
// LightsFloatTests.swift.

import SwiftUI

// MARK: - Corner

/// Where the orbit card floats. Raw values are what PanelLayout stores and
/// the DEBUG `corner:` token and the `tools=float:<corner>` log field name.
enum LightsFloatCorner: String, Equatable, CaseIterable {
    case topLeading = "tl"
    case topTrailing = "tr"
    case bottomLeading = "bl"
    case bottomTrailing = "br"

    /// Bottom-leading: clear of the top-trailing inspector and, with it
    /// collapsed, of every default three_point knob.
    static let `default`: LightsFloatCorner = .bottomLeading

    init(trailing: Bool, bottom: Bool) {
        switch (trailing, bottom) {
        case (false, false): self = .topLeading
        case (true, false): self = .topTrailing
        case (false, true): self = .bottomLeading
        case (true, true): self = .bottomTrailing
        }
    }

    /// A stored value, or the default when it is absent or unknown.
    static func stored(_ raw: String) -> LightsFloatCorner {
        LightsFloatCorner(rawValue: raw) ?? .default
    }

    var isTrailing: Bool { self == .topTrailing || self == .bottomTrailing }
    var isBottom: Bool { self == .bottomLeading || self == .bottomTrailing }

    var alignment: Alignment {
        switch self {
        case .topLeading: return .topLeading
        case .topTrailing: return .topTrailing
        case .bottomLeading: return .bottomLeading
        case .bottomTrailing: return .bottomTrailing
        }
    }

    /// What VoiceOver says (`bottom left`).
    var spokenName: String {
        "\(isBottom ? "bottom" : "top") \(isTrailing ? "right" : "left")"
    }
}

// MARK: - Metrics

enum LightsFloatMetrics {
    /// Between the viewport's edges and the cards.
    static let inset: CGFloat = 8
    /// Between two cards stacked on one edge.
    static let gap: CGFloat = 8
    /// The room a trailing card leaves under it, beyond its inset, for the
    /// viewport's bottom-trailing Gesture help button (a 26 pt glyph with
    /// 12 pt padding, about 50 pt tall). Moved here from LightsSideColumn.
    static let helpButtonClearance: CGFloat = 44
    /// Above the measured bottom-leading chrome (the camera button).
    static let chromeGap: CGFloat = 8
    /// The orbit card as the float draws it on iOS (44 pt header, 284 wide):
    /// a test pins it to the rendered card.
    static let orbitCardSize = CGSize(width: LightsOrbitView.width, height: 252)
    /// The inspector card collapsed to its header on iOS (44 pt targets): a
    /// test pins it to the rendered card.
    static let inspectorHeaderHeight: CGFloat = 44
    /// The grip's capsule, drawn in the orbit card's top padding.
    static let gripSize = CGSize(width: 36, height: 4)
    /// A drag moves the card only past this distance (a tap stays a tap).
    static let gripMinimumDistance: CGFloat = 6
}

// MARK: - The viewport's bottom chrome

/// The heights of the viewport's bottom overlays, from the viewport's
/// bottom edge to their top (their padding included): the bottom-leading
/// chrome (scene buttons and the camera button) and the CameraDock while
/// it is open (0 when absent).
struct ViewportChromeHeights: Equatable {
    var bottomLeading: CGFloat = 0
    var dock: CGFloat = 0
}

/// Reported by the bottom-leading chrome and the CameraDock; the float
/// keeps clear of both.
struct ViewportChromeHeightsKey: PreferenceKey {
    static var defaultValue = ViewportChromeHeights()
    static func reduce(value: inout ViewportChromeHeights, nextValue: () -> ViewportChromeHeights) {
        let next = nextValue()
        value.bottomLeading = max(value.bottomLeading, next.bottomLeading)
        value.dock = max(value.dock, next.dock)
    }
}

extension View {
    /// Reports this view's height (padding included) as one of the
    /// viewport's bottom chrome heights; 0 while `shown` is false (an empty
    /// chrome stack still measures its padding).
    func reportsViewportChrome(_ field: WritableKeyPath<ViewportChromeHeights, CGFloat>,
                               shown: Bool = true) -> some View {
        background(GeometryReader { g in
            Color.clear.preference(key: ViewportChromeHeightsKey.self, value: {
                var heights = ViewportChromeHeights()
                heights[keyPath: field] = shown ? g.size.height : 0
                return heights
            }())
        })
    }
}

// MARK: - Layout (pure)

enum LightsFloatLayout {
    /// The orbit card's and the inspector's frames in the viewport.
    struct Frames: Equatable {
        var card: CGRect
        var inspector: CGRect

        var all: [CGRect] { [card, inspector] }
    }

    /// The room a column on that side leaves under it, beyond its inset:
    /// trailing, the help button or an open dock; leading, the measured
    /// bottom-leading chrome plus a gap, or an open dock.
    static func bottomClearance(trailing: Bool, chrome: ViewportChromeHeights) -> CGFloat {
        if trailing {
            return max(LightsFloatMetrics.helpButtonClearance, chrome.dock)
        }
        let leading = chrome.bottomLeading > 0 ? chrome.bottomLeading + LightsFloatMetrics.chromeGap : 0
        return max(leading, chrome.dock)
    }

    static func bottomClearance(corner: LightsFloatCorner, chrome: ViewportChromeHeights) -> CGFloat {
        bottomClearance(trailing: corner.isTrailing, chrome: chrome)
    }

    /// The corner whose quadrant holds `point`.
    static func nearest(to point: CGPoint, in container: CGSize) -> LightsFloatCorner {
        LightsFloatCorner(trailing: point.x >= container.width / 2, bottom: point.y >= container.height / 2)
    }

    /// Where a released card goes: the corner nearest its centre moved by
    /// the drag's predicted end (a fling throws it), else by the drag.
    static func dropCorner(cardFrame: CGRect, translation: CGSize, predicted: CGSize?,
                           container: CGSize) -> LightsFloatCorner {
        var moved = translation
        if let predicted, predicted.width.isFinite, predicted.height.isFinite { moved = predicted }
        return nearest(to: CGPoint(x: cardFrame.midX + moved.width, y: cardFrame.midY + moved.height),
                       in: container)
    }

    /// Where the cards sit for `corner` in a viewport of `container`: the
    /// card in its corner, clear of the bottom chrome; the inspector at the
    /// top-trailing corner, under the card when it is top-trailing and
    /// above it when it is bottom-trailing. A collapsed inspector is its
    /// header; an expanded one takes `inspectorHeight` (its content) up to
    /// the room it has (nil: all of it).
    static func frames(corner: LightsFloatCorner, container: CGSize, inspectorCollapsed: Bool,
                       chrome: ViewportChromeHeights = ViewportChromeHeights(),
                       cardSize: CGSize = LightsFloatMetrics.orbitCardSize,
                       inspectorHeight: CGFloat? = nil) -> Frames {
        let inset = LightsFloatMetrics.inset, gap = LightsFloatMetrics.gap
        let width = LightsInspector.width
        let trailingBottom = container.height - inset - bottomClearance(trailing: true, chrome: chrome)
        let leadingBottom = container.height - inset - bottomClearance(trailing: false, chrome: chrome)
        let cardX = corner.isTrailing ? container.width - inset - cardSize.width : inset
        let cardY = corner.isBottom
            ? (corner.isTrailing ? trailingBottom : leadingBottom) - cardSize.height
            : inset
        let card = CGRect(x: cardX, y: cardY, width: cardSize.width, height: cardSize.height)
        let top = corner == .topTrailing ? card.maxY + gap : inset
        let limit = corner == .bottomTrailing ? card.minY - gap : trailingBottom
        let room = max(0, limit - top)
        let height = inspectorCollapsed
            ? min(LightsFloatMetrics.inspectorHeaderHeight, room)
            : min(inspectorHeight ?? room, room)
        let inspector = CGRect(x: container.width - inset - width, y: top, width: width, height: height)
        return Frames(card: card, inspector: inspector)
    }

    /// The lights whose knob, with its whole touch target, lies under any
    /// of `frames` (rig order; empty when the gizmo is hidden).
    static func coveredKnobs(layout: LightGizmoLayout?, frames: [CGRect]) -> [String] {
        guard let layout else { return [] }
        return layout.knobs.filter { knob in
            let reach = layout.metrics.reach(knob.radius)
            return frames.contains { overlaps($0, centre: knob.centre, radius: reach) }
        }.map(\.name)
    }

    /// The `covered=` log field: the names, or `none`.
    static func coveredSummary(_ names: [String]) -> String {
        names.isEmpty ? "none" : names.joined(separator: ",")
    }

    /// A circle of `radius` at `centre` meets `rect`.
    static func overlaps(_ rect: CGRect, centre: CGPoint, radius: CGFloat) -> Bool {
        guard !rect.isEmpty else { return false }
        let dx = centre.x - min(max(centre.x, rect.minX), rect.maxX)
        let dy = centre.y - min(max(centre.y, rect.minY), rect.maxY)
        return dx * dx + dy * dy < radius * radius
    }
}

// MARK: - Strings

/// The float's VoiceOver strings and identifiers.
enum LightsFloatState {
    static let identifier = "lights.float"
    static let gripIdentifier = "lights.float.grip"
    static let gripLabel = "Orbit view position"
    static let gripHint = "Drag the header to move the orbit view to another corner."

    static func gripValue(_ corner: LightsFloatCorner) -> String { corner.spokenName }

    static func moveActionName(_ corner: LightsFloatCorner) -> String { "Move to \(corner.spokenName)" }

    /// One move action per other corner, in a fixed order.
    static func moveTargets(from corner: LightsFloatCorner) -> [LightsFloatCorner] {
        LightsFloatCorner.allCases.filter { $0 != corner }
    }
}

/// The cards' frames as the float laid them out (before any drag offset),
/// in the viewport's coordinates: `card` and `inspector`.
struct LightsFloatFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// The orbit card moved by the grip's drag `offset`, reporting its
    /// laid-out frame (before the offset) in `space` as `card`. The reader
    /// sits outside the offset: a GeometryReader inside it would report the
    /// dragged frame, so the drop would count the drag twice (the moved
    /// centre plus the translation again) and the frames would change on
    /// every drag tick.
    func lightsFloatCard(offset: CGSize, space: String) -> some View {
        self.offset(offset)
            .background(GeometryReader { g in
                Color.clear.preference(key: LightsFloatFramesKey.self, value: ["card": g.frame(in: .named(space))])
            })
    }
}

// MARK: - The view

/// The floating orbit card and the top-trailing inspector, over the
/// viewport (ContentView places it after the gizmo, so the cards sit above
/// it). Draws nothing unless Lights mode is active with a selected light.
struct LightsFloatingTools: View {
    let controller: LightsController
    var style: LightsBarStyle
    @Binding var corner: LightsFloatCorner
    /// The viewport's bottom chrome, as it reported itself.
    var chrome: ViewportChromeHeights
    /// The inspector starts collapsed to its header (the iPad default).
    var inspectorStartsCollapsed: Bool
    var sceneShadowsOn: Bool? = nil
    var onEnableSceneShadows: () -> Void = {}
    /// The cards' frames (card, inspector) in the viewport's coordinates
    /// when they change, never per drag tick (the drag only offsets).
    var onFrames: (LightsFloatLayout.Frames) -> Void = { _ in }

    /// The grip drag's translation; reset (animated) on release and on a
    /// cancel, so a cancelled drag leaves nothing behind.
    @GestureState(resetTransaction: Transaction(animation: LightsFloatingTools.snap))
    private var dragOffset: CGSize = .zero
    /// The orbit card's measured height (it can be collapsed).
    @State private var cardHeight: CGFloat = LightsFloatMetrics.orbitCardSize.height
    /// The card's laid-out frame and the viewport's size, for the drop.
    @State private var cardFrame: CGRect = .zero
    @State private var containerSize: CGSize = .zero

    static let space = "lights.float"
    static let snap = Animation.spring(response: 0.3, dampingFraction: 0.86)

    var body: some View {
        let inset = LightsFloatMetrics.inset, gap = LightsFloatMetrics.gap
        let trailingClearance = LightsFloatLayout.bottomClearance(trailing: true, chrome: chrome)
        let cardClearance = LightsFloatLayout.bottomClearance(corner: corner, chrome: chrome)
        ZStack {
            // The inspector, top-trailing; stacked under or over a trailing
            // card (non-hit-testable spacers hold the card's room).
            VStack(alignment: .trailing, spacing: 0) {
                if corner == .topTrailing { Spacer().frame(height: cardHeight + gap) }
                LightsInspector(controller: controller, style: style,
                                initiallyCollapsed: inspectorStartsCollapsed,
                                sceneShadowsOn: sceneShadowsOn,
                                onEnableSceneShadows: onEnableSceneShadows)
                    .background(framesReader("inspector"))
                Spacer(minLength: 0)
                if corner == .bottomTrailing { Spacer().frame(height: cardHeight + gap) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(inset)
            .padding(.bottom, trailingClearance)

            // The orbit card: one view in every corner (its collapse state
            // survives a move), offset while its grip is dragged.
            LightsOrbitView(controller: controller, style: style, initiallyCollapsed: false,
                            grip: grip)
                .lightsFloatCard(offset: dragOffset, space: Self.space)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner.alignment)
                .padding(inset)
                .padding(.bottom, corner.isBottom ? cardClearance : 0)
                .zIndex(1)
        }
        .background(GeometryReader { g in
            Color.clear
                .onAppear { containerSize = g.size }
                .onChange(of: g.size) { _, size in containerSize = size }
        })
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(LightsFloatFramesKey.self) { frames in
            guard let card = frames["card"] else { return }
            if abs(card.height - cardHeight) > 0.5 { cardHeight = card.height }
            cardFrame = card
            onFrames(LightsFloatLayout.Frames(card: card, inspector: frames["inspector"] ?? .zero))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(LightsFloatState.identifier)
    }

    private func framesReader(_ key: String) -> some View {
        GeometryReader { g in
            Color.clear.preference(key: LightsFloatFramesKey.self, value: [key: g.frame(in: .named(Self.space))])
        }
    }

    /// The card's header as the grip: a drag in the float's space (the
    /// card moves under the finger without feeding back into the drag),
    /// snapping on release; the VoiceOver move actions.
    private var grip: LightsOrbitGrip {
        let drag = DragGesture(minimumDistance: LightsFloatMetrics.gripMinimumDistance,
                               coordinateSpace: .named(Self.space))
            .updating($dragOffset) { value, offset, _ in offset = value.translation }
            .onEnded { value in
                let target = LightsFloatLayout.dropCorner(cardFrame: cardFrame, translation: value.translation,
                                                          predicted: value.predictedEndTranslation,
                                                          container: containerSize)
                if target != corner { withAnimation(Self.snap) { corner = target } }
            }
        return LightsOrbitGrip(
            gesture: AnyGesture(drag.map { _ in () }),
            label: LightsFloatState.gripLabel,
            value: LightsFloatState.gripValue(corner),
            hint: LightsFloatState.gripHint,
            identifier: LightsFloatState.gripIdentifier,
            actions: LightsFloatState.moveTargets(from: corner).map { target in
                LightsOrbitGrip.Action(name: LightsFloatState.moveActionName(target)) {
                    withAnimation(Self.snap) { corner = target }
                }
            })
    }
}
