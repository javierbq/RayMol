// LightGizmoOverlay.swift — the in-scene light gizmo as drawn (#622, spec §9,
// §10, the gizmo mock-up).
//
// A SwiftUI overlay on the viewport, never scene geometry: it creates no
// object, CGO or setting, so it cannot cast a shadow, enter ray tracing or
// widen the scene's extent (#610; #433 is the counter-example). ContentView
// shows it in Lights mode only, on MetalViewport (macOS: under the bar and
// the side column; iOS: early in viewportView, one site for the four layouts).
// - A Canvas with `.allowsHitTesting(false)` draws the display sphere, the
//   band while a knob is dragged, every light's knob (filled in front, hollow
//   and dashed behind, dimmed while the rig is off, a dark crescent when it
//   casts a shadow), the labels, the selected light's aim line, rings,
//   handles and aim dot, the hover and active strokes and the transient
//   readout. Everything comes from LightGizmoLayout, the value the viewport
//   hit-tests (LightGizmoModel.swift), so what is drawn is what is hit.
// - The Shadow chip beside the selected knob is the only hit-testable part:
//   the inspector's strings and call (`setShadow` through
//   LightGizmoInteraction.toggleShadow), with the cap notice and the
//   Shadows-off hint (Turn On) in a callout. Hidden while a target is dragged.
// - VoiceOver: the canvas is a `Light gizmo` container with one element per
//   knob (`key light`, front or behind plus orbit, pitch and radius, a Select
//   action); the chip is a button. Aim and highlight placement stay
//   pointer-only; every other gizmo edit is in the inspector and the orbit
//   view.
// - LightGizmoUIState holds what input routing tells the drawing (hover, the
//   active target, the live side and band state, the readout) and the
//   overlay's own size, which the DEBUG gestures and the viewport's size check
//   read.
//
// Writes: only the chip (the inspector's shadow call), its Turn On (the
// inspector's closure) and the VoiceOver Select action. This file names no
// Python, console or bridge entry point (testing/tests/raymol/lighting_mode.py
// and lighting_gizmo.py check that).

import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - UI state

/// What input routing tells the gizmo's drawing, plus the overlay's size. An
/// engine lazy var (`PyMOLEngine.lightGizmoUI`) observed only by the overlay;
/// every setter publishes only on change, so a hover that stays on one
/// target, or a drag tick that changes nothing shown, re-renders nothing.
/// Reset when Lights mode ends.
@MainActor
final class LightGizmoUIState: ObservableObject {
    /// The side a dragged knob is on (the trackball's, flipped by the band).
    enum Hemisphere: Equatable {
        case front, behind
    }

    struct Values: Equatable {
        /// The target under the pointer (macOS, iPad pointer).
        var hovered: LightGizmoTarget?
        /// The target being dragged (or a knob whose radius a scroll or a
        /// pinch is setting).
        var active: LightGizmoTarget?
        /// A dragged knob's side, nil for other targets.
        var hemisphere: Hemisphere?
        /// A dragged knob's pointer is outside the sphere's outline.
        var outside = false
        /// The transient readout (`Orbit −60° · Pitch +25°`), nil when none.
        var readout: String?
        /// The overlay's size in points, nil until it appears.
        var viewSize: CGSize?
        /// The edges covered by chrome drawn over the viewport (#693).
        var chromeInsets = LightGizmoInsets.zero
    }

    private(set) var values = Values()

    init() {}

    var hovered: LightGizmoTarget? {
        get { values.hovered }
        set { update(\.hovered, newValue) }
    }

    var active: LightGizmoTarget? {
        get { values.active }
        set { update(\.active, newValue) }
    }

    var hemisphere: Hemisphere? {
        get { values.hemisphere }
        set { update(\.hemisphere, newValue) }
    }

    var outside: Bool {
        get { values.outside }
        set { update(\.outside, newValue) }
    }

    var readout: String? {
        get { values.readout }
        set { update(\.readout, newValue) }
    }

    var viewSize: CGSize? {
        get { values.viewSize }
        set { update(\.viewSize, newValue) }
    }

    var chromeInsets: LightGizmoInsets {
        get { values.chromeInsets }
        set { update(\.chromeInsets, newValue) }
    }

    /// The drag state of `session` (nil or ended: none) with the readout of
    /// `layout` (the layout after the tick's write): the target shown active
    /// (coincident rings as the ring the first move chose), the knob's side,
    /// the band state and the readout. One publish at most.
    func track(_ session: LightGizmoDragSession?, layout: LightGizmoLayout?) {
        var next = values
        if let session, !session.isEnded {
            let shown = Self.shownTarget(session)
            next.active = shown
            next.hemisphere = session.isBehind.map { $0 ? .behind : .front }
            next.outside = session.isOutside
            next.readout = layout?.readout(for: shown)
        } else {
            next.active = nil
            next.hemisphere = nil
            next.outside = false
            next.readout = nil
        }
        set(next)
    }

    /// A scroll or a pinch is setting the radius of `name`'s light: its knob
    /// shown active with `Radius 2.5× · 25 Å`; nil ends it.
    func showRadius(of name: String?, layout: LightGizmoLayout?) {
        var next = values
        next.hemisphere = nil
        next.outside = false
        if let name, let readout = layout?.radiusReadout(name) {
            next.active = .knob(name)
            next.readout = readout
        } else {
            next.active = nil
            next.readout = nil
        }
        set(next)
    }

    /// Everything back to its start (Lights mode ended): no hover, no drag,
    /// no readout, no size until the overlay appears again.
    func reset() {
        set(Values())
    }

    /// The target a session shows as active: coincident rings as the ring
    /// its first move chose.
    static func shownTarget(_ session: LightGizmoDragSession) -> LightGizmoTarget {
        guard session.target == .rings else { return session.target }
        switch session.mode {
        case .outer: return .outerRing
        case .inner: return .innerRing
        default: return .rings
        }
    }

    private func update<T: Equatable>(_ key: WritableKeyPath<Values, T>, _ value: T) {
        guard values[keyPath: key] != value else { return }
        objectWillChange.send()
        values[keyPath: key] = value
    }

    private func set(_ next: Values) {
        guard next != values else { return }
        objectWillChange.send()
        values = next
    }
}

// MARK: - The overlay

/// The gizmo over the viewport. Draws nothing unless the layout exists
/// (Lights mode active with lights and eye data, not busy, not grid mode).
/// Observes the controller (selection, rig), its eye state (every published
/// frame moves the knobs), its facing state (the VoiceOver values) and the UI
/// state (hover, drag, readout).
struct LightGizmoOverlay: View {
    @ObservedObject var controller: LightsController
    @ObservedObject var eye: LightsEyeState
    @ObservedObject var facing: LightsFacingState
    @ObservedObject var ui: LightGizmoUIState
    var style: LightsBarStyle
    /// `grid_mode` is on (the scene poll's): the gizmo hides.
    var gridMode: Bool
    /// The scene's Shadows switch as last read (nil: unknown, no hint).
    var sceneShadowsOn: Bool?
    var metrics: LightGizmoMetrics
    /// Turn the scene's Shadows switch on (the hint's Turn On button).
    var onEnableSceneShadows: () -> Void

    init(controller: LightsController, ui: LightGizmoUIState, style: LightsBarStyle,
         gridMode: Bool = false, sceneShadowsOn: Bool? = nil,
         metrics: LightGizmoMetrics = LightGizmoMetrics(),
         onEnableSceneShadows: @escaping () -> Void = {}) {
        self.controller = controller
        self.eye = controller.eye
        self.facing = controller.facing
        self.ui = ui
        self.style = style
        self.gridMode = gridMode
        self.sceneShadowsOn = sceneShadowsOn
        self.metrics = metrics
        self.onEnableSceneShadows = onEnableSceneShadows
    }

    /// The callout's width (the chip's notice and hint).
    static let calloutWidth: CGFloat = 220
    /// The chip and its callout keep this far inside the view.
    static let margin: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                Color.clear
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                if let layout = LightGizmoLayout.make(
                    LightGizmoInputs(controller: controller, viewSize: size, gridMode: gridMode,
                                     sceneShadowsOn: sceneShadowsOn, chromeInsets: ui.chromeInsets),
                    metrics: metrics) {
                    gizmo(layout, state: LightGizmoState(controller, sceneShadowsOn: sceneShadowsOn))
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            // The overlay's size, for the DEBUG gestures and the viewport's
            // size check (hit tests use the viewport's own bounds).
            .onAppear { ui.viewSize = size }
            .onChange(of: size) { _, newSize in ui.viewSize = newSize }
        }
    }

    @ViewBuilder
    private func gizmo(_ layout: LightGizmoLayout, state: LightGizmoState?) -> some View {
        let painter = LightGizmoPainter(layout: layout, ui: ui.values)
        Canvas { context, _ in painter.draw(in: &context) }
            .allowsHitTesting(false)
            .accessibilityLabel(LightGizmoState.containerLabel)
            .accessibilityIdentifier(LightGizmoState.identifier)
            .accessibilityChildren { knobElements(layout, state: state) }
        if let state, ui.active == nil, let place = Self.chipPlacement(layout) {
            LightGizmoChipLayout(point: place.point, anchor: place.anchor, calloutAbove: place.calloutAbove,
                                 margin: Self.margin, calloutWidth: Self.calloutWidth) {
                chip(state.chip)
                if state.chip.notice != nil || state.chip.showsHint {
                    callout(state.chip)
                }
            }
        }
    }

    // MARK: VoiceOver

    /// One element per knob at the knob's hit area, in rig order.
    private func knobElements(_ layout: LightGizmoLayout, state: LightGizmoState?) -> some View {
        let elements = Self.knobElements(layout, state: state)
        return ZStack(alignment: .topLeading) {
            ForEach(elements) { element in
                Circle()
                    .frame(width: element.frame.width, height: element.frame.height)
                    .position(x: element.frame.midX, y: element.frame.midY)
                    .accessibilityElement()
                    .accessibilityLabel(element.knob.label)
                    .accessibilityValue(element.knob.value)
                    // A button whose press selects the light (a role VoiceOver
                    // lands on), with the same as a named action.
                    .accessibilityAddTraits(element.knob.isSelected ? [.isButton, .isSelected] : .isButton)
                    .accessibilityAction { controller.select(name: element.knob.name) }
                    .accessibilityAction(named: Text(element.knob.selectAction)) {
                        controller.select(name: element.knob.name)
                    }
                    .accessibilityIdentifier(element.knob.identifier)
            }
        }
        .frame(width: layout.projection.viewSize.width, height: layout.projection.viewSize.height,
               alignment: .topLeading)
    }

    /// A knob's VoiceOver element and where it sits (its hit area).
    struct KnobElement: Identifiable, Equatable {
        var knob: LightGizmoState.KnobElement
        var frame: CGRect
        var id: String { knob.id }
    }

    /// The VoiceOver elements: LightGizmoState's per-knob strings at each
    /// knob's hit area (its reach: radius plus slop, at least 22 pt on iOS),
    /// rig order. Empty without a state.
    static func knobElements(_ layout: LightGizmoLayout, state: LightGizmoState?) -> [KnobElement] {
        (state?.knobs ?? []).compactMap { element in
            guard let knob = layout.knob(named: element.name) else { return nil }
            let r = layout.metrics.reach(knob.radius)
            return KnobElement(knob: element,
                               frame: CGRect(x: knob.centre.x - r, y: knob.centre.y - r, width: 2 * r, height: 2 * r))
        }
    }

    // MARK: the Shadow chip

    /// Drawn as the inspector's Shadow chip is (a capsule, accent when on),
    /// on an opaque fill so it reads over the scene.
    private func chip(_ chip: LightGizmoState.Chip) -> some View {
        let on = chip.isOn
        let enabled = controller.canEdit
        return Button {
            LightGizmoInteraction(controller: controller).toggleShadow()
        } label: {
            Text(chip.label).font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .fixedSize()
            .foregroundColor(on ? style.accent : style.text.opacity(0.85))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(style.background.opacity(0.92)))
            .background(Capsule().fill(on ? style.accent.opacity(0.15) : Color.clear))
            .overlay(Capsule().stroke(on ? style.accent : style.text.opacity(0.3), lineWidth: on ? 1.5 : 1))
            .contentShape(Capsule())
            .lightsTouchTarget()
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .help(chip.help)
        .accessibilityLabel(chip.label)
        .accessibilityValue(chip.value)
        .accessibilityAddTraits(.isToggle)
        .accessibilityIdentifier(chip.identifier)
    }

    /// The cap notice and the Shadows-off hint with Turn On, as the
    /// inspector shows them.
    private func callout(_ chip: LightGizmoState.Chip) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let notice = chip.notice {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                        .accessibilityHidden(true)
                    Text(verbatim: notice)
                        .font(.system(size: 11))
                        .foregroundColor(style.text.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(LightGizmoOverlay.noticeIdentifier)
            }
            if chip.showsHint {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                        .foregroundColor(style.text.opacity(0.7))
                        .accessibilityHidden(true)
                    Text(chip.hint)
                        .font(.system(size: 11))
                        .foregroundColor(style.text.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(LightGizmoOverlay.hintIdentifier)
                    Spacer(minLength: 4)
                    Button(chip.turnOnTitle) { onEnableSceneShadows() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .font(.system(size: 11, weight: .medium))
                        .disabled(!controller.canEdit)
                        .help(chip.turnOnHelp)
                        .accessibilityLabel(chip.turnOnLabel)
                        .accessibilityIdentifier(LightGizmoOverlay.turnOnIdentifier)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(width: Self.calloutWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(style.background.opacity(0.95)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(style.text.opacity(0.18), lineWidth: 0.5))
        .tint(style.accent)
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(LightGizmoOverlay.calloutIdentifier)
    }

    static let noticeIdentifier = "lights.gizmo.notice"
    static let hintIdentifier = "lights.gizmo.shadows_hint"
    static let turnOnIdentifier = "lights.gizmo.shadows_turn_on"
    static let calloutIdentifier = "lights.gizmo.callout"

    // MARK: where the chip goes

    /// Where the chip sits: on the ray from the sphere's centre through the
    /// selected knob, past the knob's hit area and past its label (so it
    /// covers neither), anchored like the label (its inner side towards the
    /// knob). The callout goes above the chip when the knob is in the upper
    /// part of the sphere, else below it.
    struct ChipPlacement: Equatable {
        var point: CGPoint
        var anchor: UnitPoint
        var calloutAbove: Bool
    }

    /// The gap between the label and the chip.
    static let chipGap: CGFloat = 4

    static func chipPlacement(_ layout: LightGizmoLayout) -> ChipPlacement? {
        guard let s = layout.selected, layout.knobs.indices.contains(s.index) else { return nil }
        let knob = layout.knobs[s.index]
        let u = knob.labelDirection
        let label = LightGizmoPainter.labelSize(knob.label, selected: true)
        let extent = abs(u.dx) * label.width + abs(u.dy) * label.height
        let reach = max(knob.radius + layout.metrics.labelGap + extent, layout.metrics.reach(knob.radius)) + chipGap
        return ChipPlacement(point: CGPoint(x: knob.centre.x + u.dx * reach, y: knob.centre.y + u.dy * reach),
                             anchor: LightGizmoPainter.labelAnchor(u),
                             calloutAbove: u.dy < -0.3)
    }
}

// MARK: - Chip layout

/// Places the chip (first subview) with its `anchor` point at `point`, and
/// the callout (second subview, optional) above or below it, aligned with the
/// chip as the anchor says; both kept `margin` points inside the view.
struct LightGizmoChipLayout: Layout {
    var point: CGPoint
    var anchor: UnitPoint
    var calloutAbove: Bool
    var margin: CGFloat
    var calloutWidth: CGFloat

    /// Between the chip and its callout.
    static let spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let chip = subviews.first else { return }
        let chipSize = chip.sizeThatFits(.unspecified)
        var calloutSize: CGSize?
        if subviews.count > 1 {
            let width = max(0, min(calloutWidth, bounds.width - 2 * margin))
            calloutSize = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil))
        }
        let frames = Self.frames(point: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                                 anchor: anchor, calloutAbove: calloutAbove, chipSize: chipSize,
                                 calloutSize: calloutSize, bounds: bounds, margin: margin)
        chip.place(at: frames.chip.origin, anchor: .topLeading, proposal: ProposedViewSize(frames.chip.size))
        if subviews.count > 1, let callout = frames.callout {
            subviews[1].place(at: callout.origin, anchor: .topLeading, proposal: ProposedViewSize(callout.size))
        }
    }

    /// The chip's and the callout's frames (pure, for the tests).
    static func frames(point: CGPoint, anchor: UnitPoint, calloutAbove: Bool, chipSize: CGSize,
                       calloutSize: CGSize?, bounds: CGRect,
                       margin: CGFloat) -> (chip: CGRect, callout: CGRect?) {
        func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { hi < lo ? lo : min(max(v, lo), hi) }
        let chip = CGRect(
            x: clamp(point.x - anchor.x * chipSize.width, bounds.minX + margin,
                     bounds.maxX - margin - chipSize.width),
            y: clamp(point.y - anchor.y * chipSize.height, bounds.minY + margin,
                     bounds.maxY - margin - chipSize.height),
            width: chipSize.width, height: chipSize.height)
        guard let size = calloutSize else { return (chip, nil) }
        let x = chip.minX + anchor.x * (chip.width - size.width)
        let y = calloutAbove ? chip.minY - spacing - size.height : chip.maxY + spacing
        let callout = CGRect(
            x: clamp(x, bounds.minX + margin, bounds.maxX - margin - size.width),
            y: clamp(y, bounds.minY + margin, bounds.maxY - margin - size.height),
            width: size.width, height: size.height)
        return (chip, callout)
    }
}

// MARK: - The drawing

/// Draws one frame of the gizmo from its layout and the UI state. White
/// strokes on a dark halo, so the gizmo reads over any background colour;
/// knobs in their identity colours (the bar chip's).
struct LightGizmoPainter {
    var layout: LightGizmoLayout
    var ui: LightGizmoUIState.Values

    static let halo = Color.black.opacity(0.55)
    static let ink = Color.white
    static let labelFontSize: CGFloat = 11

    /// The label's anchor: its side towards the knob (labels sit outward).
    static func labelAnchor(_ u: CGVector) -> UnitPoint {
        UnitPoint(x: 0.5 - 0.5 * u.dx, y: 0.5 - 0.5 * u.dy)
    }

    /// A label's size in points, as the canvas draws it (the system font, 11
    /// pt, semibold when selected), for placing the chip past it.
    static func labelSize(_ text: String, selected: Bool) -> CGSize {
        #if os(macOS)
        let font = NSFont.systemFont(ofSize: labelFontSize, weight: selected ? .semibold : .medium)
        #else
        let font = UIFont.systemFont(ofSize: labelFontSize, weight: selected ? .semibold : .medium)
        #endif
        let size = (text as NSString).size(withAttributes: [.font: font])
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }

    private var knobDrag: Bool {
        if case .knob = ui.active, ui.hemisphere != nil { return true }
        return false
    }

    func draw(in context: inout GraphicsContext) {
        drawSphere(&context)
        if let s = layout.selected { drawRings(&context, s) }
        for index in layout.drawingOrder { drawKnob(&context, layout.knobs[index]) }
        if let s = layout.selected { drawAim(&context, s) }
        for index in layout.drawingOrder { drawLabel(&context, layout.knobs[index]) }
        drawReadout(&context)
    }

    // MARK: sphere and band

    private func drawSphere(_ context: inout GraphicsContext) {
        let c = layout.centre
        let dragging = knobDrag
        stroke(&context, circle(c, layout.sphereRadius), Self.ink.opacity(dragging ? 0.75 : 0.4),
               dragging ? 1.5 : 1, dash: [4, 4])
        guard dragging else { return }
        // The band: dragging past it swaps the knob's side once.
        stroke(&context, circle(c, layout.bandRadius), Self.ink.opacity(ui.outside ? 0.6 : 0.25), 1,
               dash: [2, 4])
    }

    // MARK: knobs

    private func drawKnob(_ context: inout GraphicsContext, _ knob: LightGizmoLayout.Knob) {
        var c = context
        c.opacity = knob.opacity
        let colour = LightPalette.color(knob.slot)
        let isActive = ui.active == .knob(knob.name)
        // A dragged knob turns hollow (or filled) the moment the band flips it.
        let behind = isActive && ui.hemisphere != nil ? ui.hemisphere == .behind : knob.isBehind
        let r = knob.radius
        if behind {
            c.fill(circle(knob.centre, r), with: .color(Self.halo.opacity(0.4)))
            stroke(&c, circle(knob.centre, r - 1), colour, 2, dash: [3, 2])
            if knob.isSelected {
                c.stroke(circle(knob.centre, r + 1.5), with: .color(Self.ink), lineWidth: 1.5)
            }
        } else {
            c.fill(circle(knob.centre, r + 1), with: .color(Self.halo))
            c.fill(circle(knob.centre, r), with: .color(colour))
            c.stroke(circle(knob.centre, r), with: .color(Self.ink), lineWidth: knob.isSelected ? 2 : 1)
        }
        if knob.isShadowed {
            // A dark crescent along the knob's lower edge.
            var crescent = Path()
            crescent.addArc(center: knob.centre, radius: r * 0.55, startAngle: .degrees(25),
                            endAngle: .degrees(155), clockwise: false)
            let ink: Color = behind ? colour : .black
            c.stroke(crescent, with: .color(ink.opacity(knob.isShadowDimmed ? 0.3 : 0.8)),
                     style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        }
        if isActive {
            stroke(&c, circle(knob.centre, r + 4), Self.ink, 2.5)
        } else if ui.hovered == .knob(knob.name) {
            stroke(&c, circle(knob.centre, r + 3), Self.ink.opacity(0.85), 1.5)
        }
    }

    private func drawLabel(_ context: inout GraphicsContext, _ knob: LightGizmoLayout.Knob) {
        var c = context
        c.opacity = knob.opacity
        let font = Font.system(size: Self.labelFontSize, weight: knob.isSelected ? .semibold : .medium)
        let anchor = Self.labelAnchor(knob.labelDirection)
        let shadow = c.resolve(Text(verbatim: knob.label).font(font).foregroundColor(.black.opacity(0.7)))
        for (dx, dy) in [(-0.75, 0.0), (0.75, 0.0), (0.0, -0.75), (0.0, 0.75)] {
            c.draw(shadow, at: CGPoint(x: knob.labelPoint.x + dx, y: knob.labelPoint.y + dy), anchor: anchor)
        }
        c.draw(Text(verbatim: knob.label).font(font).foregroundColor(Self.ink), at: knob.labelPoint, anchor: anchor)
    }

    // MARK: the selected light

    private func emphasis(_ targets: [LightGizmoTarget]) -> CGFloat {
        if let active = ui.active, targets.contains(active) { return 1.5 }
        if let hovered = ui.hovered, targets.contains(hovered) { return 1 }
        return 0
    }

    private func drawRings(_ context: inout GraphicsContext, _ s: LightGizmoLayout.Selected) {
        let colour = layout.knobs.indices.contains(s.index) ? LightPalette.color(layout.knobs[s.index].slot) : Self.ink
        // The aim line, under everything else.
        if let line = layout.aimLine {
            var path = Path()
            path.move(to: line.from)
            path.addLine(to: line.to)
            stroke(&context, path, Self.ink.opacity(0.6), 1, dash: [2, 3])
        }
        if let outer = s.outerRing {
            let extra = emphasis([.outerRing, .outerHandle, .rings])
            stroke(&context, ringPath(outer), colour, layout.metrics.outerRingWidth + extra)
        }
        if let inner = s.innerRing {
            let extra = emphasis([.innerRing, .innerHandle, .rings])
            stroke(&context, ringPath(inner), colour.opacity(0.9), layout.metrics.innerRingWidth + extra,
                   dash: [4, 3])
        }
    }

    private func drawAim(_ context: inout GraphicsContext, _ s: LightGizmoLayout.Selected) {
        let colour = layout.knobs.indices.contains(s.index) ? LightPalette.color(layout.knobs[s.index].slot) : Self.ink
        let half = layout.metrics.handleHalfSide
        for (handle, target, filled) in [(s.innerHandle, LightGizmoTarget.innerHandle, false),
                                         (s.outerHandle, LightGizmoTarget.outerHandle, true)] {
            guard let h = handle else { continue }
            if h.isOffRing {
                var tick = Path()
                tick.move(to: h.ringPoint)
                tick.addLine(to: h.point)
                stroke(&context, tick, Self.ink.opacity(0.6), 1)
            }
            let square = Path(CGRect(x: h.point.x - half, y: h.point.y - half, width: 2 * half, height: 2 * half))
            context.fill(Path(CGRect(x: h.point.x - half - 1, y: h.point.y - half - 1,
                                     width: 2 * half + 2, height: 2 * half + 2)), with: .color(Self.halo))
            context.fill(square, with: .color(filled ? colour : Self.ink))
            context.stroke(square, with: .color(filled ? Self.ink : colour), lineWidth: filled ? 1 : 1.5)
            let extra = emphasis([target])
            if extra > 0 {
                let ring = Path(CGRect(x: h.point.x - half - 3, y: h.point.y - half - 3,
                                       width: 2 * half + 6, height: 2 * half + 6))
                stroke(&context, ring, Self.ink.opacity(extra > 1 ? 1 : 0.85), extra > 1 ? 2 : 1.5)
            }
        }
        guard let aim = s.aimDot else { return }
        let r = layout.metrics.aimDotRadius
        context.fill(circle(aim, r + 1), with: .color(Self.halo))
        context.fill(circle(aim, r), with: .color(Self.ink))
        context.stroke(circle(aim, r), with: .color(colour), lineWidth: 1.5)
        let extra = emphasis([.aimDot])
        if extra > 0 {
            stroke(&context, circle(aim, r + 3), Self.ink.opacity(extra > 1 ? 1 : 0.85), extra > 1 ? 2 : 1.5)
        }
    }

    // MARK: the readout

    /// Where the readout sits: beside the active target (else the hovered
    /// one; else above the sphere).
    func readoutAnchor() -> CGPoint {
        for target in [ui.active, ui.hovered].compactMap({ $0 }) {
            if let p = point(of: target) { return p }
        }
        return CGPoint(x: layout.centre.x, y: layout.centre.y - layout.sphereRadius)
    }

    private func point(of target: LightGizmoTarget) -> CGPoint? {
        let s = layout.selected
        switch target {
        case .knob(let name): return layout.knob(named: name)?.centre
        case .aimDot: return s?.aimDot
        case .outerHandle, .outerRing, .rings: return s?.outerHandle?.point
        case .innerHandle, .innerRing: return s?.innerHandle?.point
        }
    }

    private func drawReadout(_ context: inout GraphicsContext) {
        guard let text = ui.readout, !text.isEmpty else { return }
        let resolved = context.resolve(Text(verbatim: text)
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundColor(Self.ink))
        let size = resolved.measure(in: CGSize(width: 1000, height: 100))
        let pad = CGSize(width: 6, height: 3)
        let box = CGSize(width: size.width + 2 * pad.width, height: size.height + 2 * pad.height)
        let p = readoutAnchor()
        let view = layout.projection.viewSize
        let margin: CGFloat = 8
        func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { hi < lo ? lo : min(max(v, lo), hi) }
        let origin = CGPoint(x: clamp(p.x + 14, margin, view.width - margin - box.width),
                             y: clamp(p.y - 14 - box.height, margin, view.height - margin - box.height))
        let rect = CGRect(origin: origin, size: box)
        context.fill(Path(roundedRect: rect, cornerRadius: 5), with: .color(.black.opacity(0.72)))
        context.draw(resolved, in: CGRect(x: rect.minX + pad.width, y: rect.minY + pad.height,
                                          width: size.width, height: size.height))
    }

    // MARK: paths

    private func circle(_ c: CGPoint, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    }

    /// The ring as polylines: a new subpath after any sample that does not
    /// project, closed when every sample does.
    private func ringPath(_ ring: LightGizmoLayout.Ring) -> Path {
        var path = Path()
        let samples = ring.samples
        guard samples.count > 1 else { return path }
        if samples.allSatisfy({ $0 != nil }) {
            path.addLines(samples.compactMap { $0 })
            path.closeSubpath()
            return path
        }
        // Start after a gap so a run that wraps the end stays one polyline.
        let start = (samples.firstIndex { $0 == nil } ?? 0) + 1
        var open = false
        for k in 0..<samples.count {
            guard let p = samples[(start + k) % samples.count] else {
                open = false
                continue
            }
            if open { path.addLine(to: p) } else { path.move(to: p); open = true }
        }
        return path
    }

    /// A stroke on a dark halo.
    private func stroke(_ context: inout GraphicsContext, _ path: Path, _ colour: Color, _ width: CGFloat,
                        dash: [CGFloat] = []) {
        context.stroke(path, with: .color(Self.halo),
                       style: StrokeStyle(lineWidth: width + 2, lineCap: .round, lineJoin: .round, dash: dash))
        context.stroke(path, with: .color(colour),
                       style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round, dash: dash))
    }
}
