// LightsOrbitView.swift — the orbit mini viewer's card (#621, spec §9,
// sketches 1 and 2).
//
// A card in the Lights side column, above the inspector: a flat plan of the
// rig seen from above (the camera at the bottom, +90° to the right) beside a
// pitch arc for the selected light.
// - Drag a lamp: orbit only, every 15°; a press on another lamp selects it
//   (a tap only selects).
// - Drag the square on the selected light's ring, or pinch the plan: radius
//   only, every 0.5× (the core keeps the beam).
// - Drag the arc: pitch only.
// - VoiceOver: the plan and the arc are adjustable elements, with named
//   actions for the radius and for selecting the other lights.
//
// Everything that is not drawing lives in LightsOrbitModel.swift (layouts,
// hit tests, gesture sessions, LightsOrbitState, LightsOrbitInteraction), so
// the tests and the DEBUG simulator gestures run the same code. This file
// writes only through LightsOrbitInteraction (the owner-guarded shared edit
// path) and names no Python, console command or bridge function
// (testing/tests/raymol/lighting_mode.py and lighting_orbit.py check that).
//
// Observation in two layers: LightsOrbitView observes the controller only
// (visibility, header, collapse); OrbitCanvases and the collapsed summary also
// observe `controller.eye`, so a pinned light's per-frame placement redraws
// them and nothing else (not the header, the inspector's other rows or the
// bar). The card never asks for per-frame eye reads (#620's gated hook
// publishes them only while a light is pinned).

import SwiftUI

/// The orbit card. Draws nothing unless Lights mode is active with a selected
/// light (LightsOrbitState is nil otherwise).
struct LightsOrbitView: View {
    @ObservedObject var controller: LightsController
    var style: LightsBarStyle

    /// Collapsed to its header (with a one-line summary). Plain view state,
    /// seeded per mode entry and never persisted.
    @State private var collapsed: Bool
    /// 44 on iOS (the chevron a 44 pt target, #623), 0 on macOS.
    @Environment(\.lightsTouchMinimum) private var touchMinimum

    static let width: CGFloat = LightsInspector.width
    /// The header row's height on macOS; on iOS the 44 pt chevron sets it.
    static let headerHeight: CGFloat = 18
    /// Between the card's edge and the canvases, and between the canvases.
    static let inset: CGFloat = 12
    static let gap: CGFloat = 8

    init(controller: LightsController, style: LightsBarStyle, initiallyCollapsed: Bool = false) {
        self.controller = controller
        self.style = style
        _collapsed = State(initialValue: initiallyCollapsed)
    }

    var body: some View {
        if let state = LightsOrbitState(controller) {
            card(state)
        }
    }

    private func card(_ state: LightsOrbitState) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // On iOS the 44 pt header carries the vertical padding.
            header(state)
                .padding(.horizontal, Self.inset)
                .padding(.top, touchMinimum > 0 ? 0 : 8)
                .padding(.bottom, collapsed && touchMinimum == 0 ? 8 : 2)
            if !collapsed {
                OrbitCanvases(controller: controller, eye: controller.eye, style: style)
                    .padding(.horizontal, Self.inset)
                    .padding(.bottom, 10)
            }
        }
        .frame(width: Self.width)
        .background(style.background)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(style.text.opacity(0.18), lineWidth: 0.5))
        .tint(style.accent)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(state.containerLabel)
        .accessibilityIdentifier(LightsOrbitState.identifier)
    }

    // `Orbit` over the plan and `Pitch` over the arc (spec decision 11); the
    // collapsed header shows the selected light's values on one line instead.
    private func header(_ state: LightsOrbitState) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle()
                    .fill(LightPalette.color(state.selected.slot))
                    .frame(width: 10, height: 10)
                    .opacity(state.isOn ? 1 : 0.45)
                    .accessibilityHidden(true)
                title(LightsOrbitState.orbitTitle)
                if collapsed {
                    OrbitCollapsedSummary(controller: controller, eye: controller.eye, style: style)
                } else {
                    Text(verbatim: state.selected.name)
                        .font(.system(size: 11))
                        .foregroundColor(style.text.opacity(0.55))
                        .lineLimit(1)
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 2)
            }
            .frame(width: collapsed ? nil : LightsOrbitMetrics.planSize.width + Self.gap, alignment: .leading)
            if !collapsed {
                title(LightsOrbitState.pitchTitle)
                Spacer(minLength: 2)
            }
            collapseButton
        }
        .frame(height: max(Self.headerHeight, touchMinimum))
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(style.text)
            .lineLimit(1)
            .fixedSize()
            .accessibilityHidden(true)
    }

    private var collapseButton: some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { collapsed.toggle() } } label: {
            Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(style.text.opacity(0.7))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
                .lightsTouchTarget()
        }
        .buttonStyle(.plain)
        .help(LightsOrbitState.collapseLabel(collapsed: collapsed))
        .accessibilityLabel(LightsOrbitState.collapseLabel(collapsed: collapsed))
        .accessibilityIdentifier(LightsOrbitState.collapseIdentifier)
    }
}

/// The collapsed header's `−45° · +35° · 3.0×`. Observes `eye`, so a pinned
/// light's summary follows the camera.
struct OrbitCollapsedSummary: View {
    @ObservedObject var controller: LightsController
    @ObservedObject var eye: LightsEyeState
    var style: LightsBarStyle

    var body: some View {
        Text(verbatim: LightsOrbitState(controller)?.collapsedSummary ?? "")
            .font(.system(size: 11).monospacedDigit())
            .foregroundColor(style.text.opacity(0.75))
            .lineLimit(1)
            .accessibilityIdentifier("lights.orbit.summary")
    }
}

// MARK: - The canvases and their gestures

/// The plan and the pitch arc, side by side, with their gestures and their
/// VoiceOver elements. Observes the controller and `eye` (pinned lamps move
/// with the camera) and holds the gesture sessions.
///
/// The card draws them at LightsOrbitMetrics' sizes; the iPhone sheet and the
/// side panel (#623, LightsSheet.swift) pass their own: a 164 pt plan alone in
/// the compact sheet, a pinned plan and a wider arc when pulled up. The
/// layouts, the hit tests and the gestures all follow the sizes given.
struct OrbitCanvases: View {
    @ObservedObject var controller: LightsController
    @ObservedObject var eye: LightsEyeState
    var style: LightsBarStyle
    var slop: CGFloat
    /// The plan canvas's size, the arc canvas's, and whether the arc shows.
    var planSize: CGSize
    var arcSize: CGSize
    var showsArc: Bool

    init(controller: LightsController, eye: LightsEyeState, style: LightsBarStyle,
         slop: CGFloat = LightsOrbitMetrics.defaultSlop,
         planSize: CGSize = LightsOrbitMetrics.planSize,
         arcSize: CGSize = LightsOrbitMetrics.arcSize,
         showsArc: Bool = true) {
        self.controller = controller
        self.eye = eye
        self.style = style
        self.slop = slop
        self.planSize = planSize
        self.arcSize = arcSize
        self.showsArc = showsArc
    }

    // One drag on the plan, one on the arc and one pinch at a time. A
    // `…Touch` sequence marks a drag whose press was handled (hit or miss),
    // so a press that missed never starts a session mid-drag; it tells a new
    // press by its start, so a cancelled drag (no `onEnded`) never carries
    // its session into the next press.
    @State private var planSession: OrbitDragSession?
    @State private var planTouch = OrbitTouchSequence()
    @State private var arcSession: OrbitDragSession?
    @State private var arcTouch = OrbitTouchSequence()
    @State private var pinchSession: OrbitPinchSession?
    @State private var pinchActive = false
    /// True while a pinch runs; SwiftUI resets it when the pinch ends or is
    /// cancelled, and the reset ends the pinch (`onEnded` misses a cancel).
    @GestureState private var pinching = false
    /// The plan's extent while a pinch runs (the plan never rescales under
    /// the fingers).
    @State private var pinchExtent: Double?
    /// A pinch began during this touch sequence: its drag ticks are ignored.
    @State private var dragSuppressed = false

    var body: some View {
        if let state = LightsOrbitState(controller) {
            HStack(alignment: .top, spacing: LightsOrbitView.gap) {
                plan(state)
                if showsArc {
                    arc(state)
                }
            }
            .opacity(state.canEdit ? 1 : 0.5)
        }
    }

    private var interaction: LightsOrbitInteraction { LightsOrbitInteraction(controller: controller) }

    /// The plan's layout now: frozen at the press during a drag or a pinch,
    /// else fitted to the lamps.
    static func planLayout(_ state: LightsOrbitState, frozenExtent: Double?,
                           slop: CGFloat = LightsOrbitMetrics.defaultSlop,
                           size: CGSize = LightsOrbitMetrics.planSize) -> OrbitPlanLayout {
        OrbitPlanLayout(size: size, extent: frozenExtent ?? state.extent, slop: slop)
    }

    private var frozenExtent: Double? { planSession?.plan?.extent ?? pinchExtent }

    /// The square's angle while the square itself is dragged (it does not
    /// slide around its ring as the radius changes).
    private var frozenSquareAngle: Double? {
        guard let planSession, planSession.target == .radiusSquare else { return nil }
        return planSession.squareAngle
    }

    // MARK: plan

    private func plan(_ state: LightsOrbitState) -> some View {
        let layout = Self.planLayout(state, frozenExtent: frozenExtent, slop: slop, size: planSize)
        let painter = OrbitPlanPainter(state: state, layout: layout, squareAngle: frozenSquareAngle,
                                       style: style)
        let owner = state.selected.name
        return OrbitCanvas(size: planSize) { painter.draw(in: &$0) }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { planChanged($0, state: state, layout: layout) }
                    .onEnded { _ in planEnded() }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .updating($pinching) { _, active, _ in active = true }
                    .onChanged { pinchChanged($0.magnification, state: state) }
                    .onEnded { _ in pinchEnded() }
            )
            .onChange(of: pinching) { _, now in
                if !now { pinchEnded() }
            }
            .accessibilityElement()
            .accessibilityLabel(state.planLabel)
            .accessibilityValue(state.planValue)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: interaction.stepOrbit(up: true, owner: owner)
                case .decrement: interaction.stepOrbit(up: false, owner: owner)
                @unknown default: break
                }
            }
            .accessibilityAction(named: Text(LightsOrbitState.increaseRadiusAction)) {
                interaction.stepRadius(up: true, owner: owner)
            }
            .accessibilityAction(named: Text(LightsOrbitState.decreaseRadiusAction)) {
                interaction.stepRadius(up: false, owner: owner)
            }
            .accessibilityActions {
                ForEach(state.others) { lamp in
                    Button(LightsOrbitState.selectAction(lamp.name)) {
                        interaction.select(name: lamp.name)
                    }
                }
            }
            .accessibilityIdentifier(LightsOrbitState.planIdentifier)
    }

    private func planChanged(_ drag: DragGesture.Value, state: LightsOrbitState, layout: OrbitPlanLayout) {
        if planTouch.isNewPress(startingAt: drag.startLocation) {
            // Whatever a cancelled sequence left behind is dropped here.
            planSession = nil
            if !pinchActive { dragSuppressed = false }
            guard !dragSuppressed, !pinchActive else { return }
            planSession = interaction.beginPlan(at: drag.startLocation, state: state, layout: layout)
        }
        guard !dragSuppressed, var session = planSession else { return }
        interaction.move(&session, to: drag.location)
        planSession = session
    }

    private func planEnded() {
        planSession = nil
        planTouch.end()
        if !pinchActive { dragSuppressed = false }
    }

    // A pinch ends any drag on the plan and suppresses the rest of that
    // touch sequence's drag ticks. Nothing is reverted: the 3 pt drag slop
    // means a lone first finger rarely writes before the pinch is recognised.
    private func pinchChanged(_ magnification: CGFloat, state: LightsOrbitState) {
        if !pinchActive {
            pinchActive = true
            dragSuppressed = true
            pinchExtent = frozenExtent ?? state.extent
            planSession = nil
            pinchSession = interaction.beginPinch()
        }
        guard var session = pinchSession else { return }
        interaction.pinch(&session, magnification: Double(magnification))
        pinchSession = session
    }

    private func pinchEnded() {
        pinchSession = nil
        pinchActive = false
        pinchExtent = nil
        if !planTouch.isActive { dragSuppressed = false }
    }

    // MARK: arc

    private func arc(_ state: LightsOrbitState) -> some View {
        let layout = PitchArcLayout(size: arcSize, slop: slop)
        let painter = PitchArcPainter(state: state, layout: layout, style: style)
        let owner = state.selected.name
        return OrbitCanvas(size: arcSize) { painter.draw(in: &$0) }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { arcChanged($0, state: state, layout: layout) }
                    .onEnded { _ in
                        arcSession = nil
                        arcTouch.end()
                    }
            )
            .accessibilityElement()
            .accessibilityLabel(state.pitchLabel)
            .accessibilityValue(state.pitchValue)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: interaction.stepPitch(up: true, owner: owner)
                case .decrement: interaction.stepPitch(up: false, owner: owner)
                @unknown default: break
                }
            }
            .accessibilityIdentifier(LightsOrbitState.pitchIdentifier)
    }

    private func arcChanged(_ drag: DragGesture.Value, state: LightsOrbitState, layout: PitchArcLayout) {
        if arcTouch.isNewPress(startingAt: drag.startLocation) {
            arcSession = interaction.beginArc(at: drag.startLocation, state: state, layout: layout)
        }
        guard var session = arcSession else { return }
        interaction.move(&session, to: drag.location)
        arcSession = session
    }
}

/// A canvas of `size` whose drawing may spill `bleed` points past its edges
/// (a lamp on the outer ring, the camera mark), in the canvas's own
/// coordinates: what the layouts and the gestures use.
struct OrbitCanvas: View {
    var size: CGSize
    var draw: (inout GraphicsContext) -> Void

    static let bleed: CGFloat = 8

    var body: some View {
        Canvas { context, _ in
            context.translateBy(x: Self.bleed, y: Self.bleed)
            draw(&context)
        }
        .frame(width: size.width + 2 * Self.bleed, height: size.height + 2 * Self.bleed)
        .padding(-Self.bleed)
        .frame(width: size.width, height: size.height)
    }
}

// MARK: - Drawing

/// Where a label beside a point goes: to the side the direction `(dx, dy)`
/// points (a unit vector, screen axes), clear of a mark of radius `clear`:
/// beside it when the direction is mostly horizontal, else above or below.
struct OrbitLabelPlacement: Equatable {
    var point: CGPoint
    var anchor: UnitPoint

    /// How horizontal a direction must be for a label beside the mark.
    static let sideways: CGFloat = 0.7

    init(beside p: CGPoint, dx: CGFloat, dy: CGFloat, clear: CGFloat) {
        if dx > Self.sideways {
            point = CGPoint(x: p.x + clear + 3, y: p.y)
            anchor = .leading
        } else if dx < -Self.sideways {
            point = CGPoint(x: p.x - clear - 3, y: p.y)
            anchor = .trailing
        } else {
            point = CGPoint(x: p.x, y: p.y + (dy >= 0 ? clear + 2 : -clear - 2))
            anchor = dy >= 0 ? .top : .bottom
        }
    }

    /// Beside a lamp `distance` points from the plan centre in the direction
    /// of `orbit`: outward in the plan's inner half, inward in its outer half
    /// (so labels stay on the card).
    init(lampAt p: CGPoint, orbit: Double, distance: CGFloat, layout: OrbitPlanLayout, clear: CGFloat) {
        let o = LightAngles.offset(orbit: orbit)
        let sign: CGFloat = distance > layout.outerRadius * 0.55 ? -1 : 1
        self.init(beside: p, dx: sign * CGFloat(o.dx), dy: sign * CGFloat(o.dy), clear: clear)
    }

    /// Above or below the selected lamp (its label is the widest): away from
    /// the centre, unless the lamp is near the plan's top or bottom (the
    /// angle labels and the card's edge are there).
    init(selectedLampAt p: CGPoint, layout: OrbitPlanLayout, clear: CGFloat) {
        let dy = p.y - layout.centre.y
        let outward: CGFloat = dy >= 0 ? 1 : -1
        let nearEdge = abs(dy) > layout.outerRadius * 0.6
        self.init(beside: p, dx: 0, dy: nearEdge ? -outward : outward, clear: clear)
    }

    /// Centred on `point`.
    init(centre point: CGPoint) {
        self.point = point
        anchor = .center
    }

    /// The top-left corner of a label of `size` placed here, kept inside
    /// `bounds`.
    func origin(for size: CGSize, in bounds: CGRect) -> CGPoint {
        let x = point.x - anchor.x * size.width
        let y = point.y - anchor.y * size.height
        return CGPoint(x: min(max(x, bounds.minX), max(bounds.maxX - size.width, bounds.minX)),
                       y: min(max(y, bounds.minY), max(bounds.maxY - size.height, bounds.minY)))
    }
}

/// Draws the plan (sketch 2): rings in scene sizes with the 1× disc, the
/// angle ticks and the camera mark at the bottom, every lamp in its identity
/// colour with its pitch label, and for the selected light its ring, orbit
/// wedge, radius label, square and haloed lamp. Pure: drawn from a state and
/// a layout, the same ones the hit test uses.
struct OrbitPlanPainter {
    var state: LightsOrbitState
    var layout: OrbitPlanLayout
    /// The square's angle when frozen by a square drag.
    var squareAngle: Double?
    var style: LightsBarStyle

    static let labelFont = Font.system(size: 9).monospacedDigit()
    static let valueFont = Font.system(size: 10, weight: .medium).monospacedDigit()

    func draw(in context: inout GraphicsContext) {
        let c = layout.centre
        let outer = layout.outerRadius
        let grey = style.text.opacity(0.2)
        let muted = style.text.opacity(0.55)

        // The 1× disc: the edge of the molecules when the rig was centred.
        let disc = layout.ringRadius(1)
        context.fill(circle(c, disc), with: .color(style.text.opacity(0.08)))
        context.stroke(circle(c, disc), with: .color(style.text.opacity(0.25)), lineWidth: 0.75)
        // The rings, labelled just inside their tops, left of the axis.
        for ring in layout.rings {
            let r = layout.ringRadius(ring)
            context.stroke(circle(c, r), with: .color(grey), lineWidth: 1)
            text(&context, String(format: "%.0f×", ring), at: CGPoint(x: c.x - 3, y: c.y - r + 2),
                 anchor: .topTrailing, colour: muted)
        }
        // The angle ticks across the outer ring and their labels inside it.
        for orbit in [0.0, 90, 180, -90] {
            var tick = Path()
            tick.move(to: layout.point(orbit: orbit, distance: outer - 3))
            tick.addLine(to: layout.point(orbit: orbit, distance: outer + 3))
            context.stroke(tick, with: .color(style.text.opacity(0.35)), lineWidth: 1)
        }
        text(&context, "±180°", at: CGPoint(x: c.x + 3, y: c.y - outer + 2), anchor: .topLeading, colour: muted)
        text(&context, "90°", at: CGPoint(x: c.x + outer - 5, y: c.y - 2), anchor: .bottomTrailing, colour: muted)
        text(&context, "\(LightInspectorFormat.minus)90°", at: CGPoint(x: c.x - outer + 5, y: c.y - 2),
             anchor: .bottomLeading, colour: muted)
        text(&context, "0°", at: CGPoint(x: c.x + 5, y: c.y + outer - 3), anchor: .bottomLeading, colour: muted)
        // The camera, under the bottom of the outer ring.
        var camera = Path()
        camera.move(to: CGPoint(x: c.x, y: c.y + outer - 1))
        camera.addLine(to: CGPoint(x: c.x - 5, y: c.y + outer + 7))
        camera.addLine(to: CGPoint(x: c.x + 5, y: c.y + outer + 7))
        camera.closeSubpath()
        context.fill(camera, with: .color(style.text.opacity(0.65)))

        let s = state.selected
        let colour = lampColour(s)
        let selectedDistance = layout.drawnDistance(radius: s.radius)
        let selectedPoint = layout.lampPoint(orbit: s.orbit, radius: s.radius)

        // The selected light's ring, its orbit wedge from 0° and its value.
        context.stroke(circle(c, selectedDistance), with: .color(colour.opacity(0.9)), lineWidth: 1.5)
        let wedge = max(layout.ringRadius(1) + 9, 20)
        context.stroke(arcPath(from: 0, to: s.orbit, radius: wedge), with: .color(colour), lineWidth: 1.5)
        // Its value outside the wedge, or inside it when the lamp or the
        // lamp's radius label is there.
        let r = LightsOrbitMetrics.selectedLampRadius
        let radiusLabel = label(&context, state.radiusText,
                                placed: OrbitLabelPlacement(selectedLampAt: selectedPoint, layout: layout,
                                                            clear: r + 4),
                                colour: colour, font: Self.valueFont)
        let lampBox = CGRect(x: selectedPoint.x - r - 4, y: selectedPoint.y - r - 4, width: 2 * r + 8,
                             height: 2 * r + 8)
        var orbitLabel = label(&context, state.orbitText,
                               placed: OrbitLabelPlacement(centre: layout.point(orbit: s.orbit / 2,
                                                                                distance: wedge + 9)),
                               colour: colour, font: Self.valueFont)
        if orbitLabel.frame.intersects(lampBox) || orbitLabel.frame.intersects(radiusLabel.frame) {
            orbitLabel = label(&context, state.orbitText,
                               placed: OrbitLabelPlacement(centre: layout.point(orbit: s.orbit / 2,
                                                                                distance: max(wedge - 10, 4))),
                               colour: colour, font: Self.valueFont)
        }
        draw(&context, orbitLabel)
        // The dashed line from the centre to the lamp.
        var spoke = Path()
        spoke.move(to: c)
        spoke.addLine(to: selectedPoint)
        context.stroke(spoke, with: .color(colour), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

        // The other lamps, in rig order, with their pitch labels.
        for lamp in state.lamps where !lamp.isSelected {
            let p = layout.lampPoint(orbit: lamp.orbit, radius: lamp.radius)
            drawLamp(&context, lamp, at: p, radius: LightsOrbitMetrics.lampRadius)
            let label = OrbitLabelPlacement(lampAt: p, orbit: lamp.orbit,
                                            distance: layout.drawnDistance(radius: lamp.radius),
                                            layout: layout, clear: LightsOrbitMetrics.lampRadius)
            draw(&context, self.label(&context, lamp.labelText, placed: label, colour: style.text.opacity(0.8)))
        }

        // The radius square on the selected ring.
        let angle = squareAngle ?? layout.squareAngle(radius: s.radius)
        let q = layout.squarePoint(orbit: s.orbit, radius: s.radius, angle: angle)
        let h = LightsOrbitMetrics.squareHalfSide
        let square = Path(roundedRect: CGRect(x: q.x - h, y: q.y - h, width: 2 * h, height: 2 * h), cornerRadius: 1.5)
        context.fill(square, with: .color(colour))
        context.stroke(square, with: .color(style.text.opacity(0.85)), lineWidth: 1)

        // The selected lamp, haloed, and its radius label.
        context.stroke(circle(selectedPoint, r + 4), with: .color(colour), lineWidth: 1)
        drawLamp(&context, s, at: selectedPoint, radius: r)
        draw(&context, radiusLabel)
    }

    private func lampColour(_ lamp: LightsOrbitState.Lamp) -> Color {
        LightPalette.color(lamp.slot).opacity(state.isOn ? 1 : 0.45)
    }

    private func drawLamp(_ context: inout GraphicsContext, _ lamp: LightsOrbitState.Lamp, at p: CGPoint,
                          radius r: CGFloat) {
        context.fill(circle(p, r), with: .color(lampColour(lamp)))
        context.stroke(circle(p, r),
                       with: .color(lamp.isSelected ? style.text.opacity(0.85) : style.background),
                       lineWidth: lamp.isSelected ? 1.5 : 1)
        if layout.isClamped(radius: lamp.radius) {
            // Beyond the extent: an outward arrowhead past the lamp (and its
            // halo); the label carries the true radius.
            let o = LightAngles.offset(orbit: lamp.orbit)
            let u = CGVector(dx: CGFloat(o.dx), dy: CGFloat(o.dy))
            let n = CGVector(dx: -u.dy, dy: u.dx)
            let base = r + (lamp.isSelected ? 6 : 2)
            let tip = CGPoint(x: p.x + u.dx * (base + 5), y: p.y + u.dy * (base + 5))
            let back = CGPoint(x: p.x + u.dx * base, y: p.y + u.dy * base)
            var arrow = Path()
            arrow.move(to: CGPoint(x: back.x + n.dx * 3.5, y: back.y + n.dy * 3.5))
            arrow.addLine(to: tip)
            arrow.addLine(to: CGPoint(x: back.x - n.dx * 3.5, y: back.y - n.dy * 3.5))
            arrow.closeSubpath()
            context.fill(arrow, with: .color(lampColour(lamp)))
        }
        if lamp.isPinned {
            // A pin mark inside the lamp.
            var pin = context.resolve(Image(systemName: "pin.fill"))
            pin.shading = .color(style.background)
            let side = r * 1.1
            context.draw(pin, in: CGRect(x: p.x - side / 2, y: p.y - side / 2, width: side, height: side))
        }
    }

    /// An arc around the plan centre from orbit `from` to `to` (LightAngles).
    private func arcPath(from: Double, to: Double, radius: CGFloat) -> Path {
        var path = Path()
        let steps = max(Int(abs(to - from) / 5), 1)
        for k in 0...steps {
            let p = layout.point(orbit: from + (to - from) * Double(k) / Double(steps), distance: radius)
            if k == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }

    private func text(_ context: inout GraphicsContext, _ string: String, at p: CGPoint, anchor: UnitPoint,
                      colour: Color, font: Font = OrbitPlanPainter.labelFont) {
        context.draw(Text(verbatim: string).font(font).foregroundColor(colour), at: p, anchor: anchor)
    }

    /// A label at `placed`, measured and kept inside the canvas (plus a
    /// little of its bleed), so a label near an edge is never cut off.
    private func label(_ context: inout GraphicsContext, _ string: String, placed: OrbitLabelPlacement,
                       colour: Color, font: Font = OrbitPlanPainter.labelFont) -> PlacedLabel {
        let resolved = context.resolve(Text(verbatim: string).font(font).foregroundColor(colour))
        let size = resolved.measure(in: CGSize(width: 1000, height: 1000))
        let bounds = CGRect(origin: .zero, size: layout.size).insetBy(dx: -4, dy: -4)
        return PlacedLabel(text: resolved, frame: CGRect(origin: placed.origin(for: size, in: bounds), size: size))
    }

    private func draw(_ context: inout GraphicsContext, _ label: PlacedLabel) {
        context.draw(label.text, in: label.frame)
    }

    private struct PlacedLabel {
        var text: GraphicsContext.ResolvedText
        var frame: CGRect
    }
}

/// Draws the pitch arc (sketch 2): a half circle from −90° (below) to +90°
/// (above) with ticks every 45°, the level line to 0°, the subject at the
/// centre, and the selected light's handle with its value.
struct PitchArcPainter {
    var state: LightsOrbitState
    var layout: PitchArcLayout
    var style: LightsBarStyle

    func draw(in context: inout GraphicsContext) {
        let c = layout.centre
        let r = layout.radius
        let muted = style.text.opacity(0.55)
        let font = Font.system(size: 9).monospacedDigit()

        // The subject, and the level line to 0°.
        context.fill(circle(c, 6), with: .color(style.text.opacity(0.08)))
        context.stroke(circle(c, 6), with: .color(style.text.opacity(0.25)), lineWidth: 0.75)
        var level = Path()
        level.move(to: c)
        level.addLine(to: layout.point(pitch: 0))
        context.stroke(level, with: .color(style.text.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
        // The arc and its ticks.
        var track = Path()
        for (i, p) in stride(from: -90.0, through: 90.0, by: 5).enumerated() {
            if i == 0 { track.move(to: layout.point(pitch: p)) } else { track.addLine(to: layout.point(pitch: p)) }
        }
        context.stroke(track, with: .color(style.text.opacity(0.3)), lineWidth: 1.2)
        for pitch in PitchArcLayout.ticks {
            let o = LightAngles.offset(pitch: pitch)
            var tick = Path()
            tick.move(to: CGPoint(x: c.x + (r - 3) * CGFloat(o.dx), y: c.y + (r - 3) * CGFloat(o.dy)))
            tick.addLine(to: CGPoint(x: c.x + (r + 3) * CGFloat(o.dx), y: c.y + (r + 3) * CGFloat(o.dy)))
            context.stroke(tick, with: .color(style.text.opacity(0.35)), lineWidth: 1)
        }
        let top = layout.point(pitch: 90), bottom = layout.point(pitch: -90)
        context.draw(Text(verbatim: "+90°").font(font).foregroundColor(muted),
                     at: CGPoint(x: top.x, y: top.y - 5), anchor: .bottomLeading)
        context.draw(Text(verbatim: "\(LightInspectorFormat.minus)90°").font(font).foregroundColor(muted),
                     at: CGPoint(x: bottom.x, y: bottom.y + 5), anchor: .topLeading)
        let zero = layout.point(pitch: 0)
        context.draw(Text(verbatim: "0°").font(font).foregroundColor(muted),
                     at: CGPoint(x: zero.x - 4, y: zero.y - 3), anchor: .bottomTrailing)

        // The selected light: a dashed line to its handle, the handle, its value.
        let s = state.selected
        let colour = LightPalette.color(s.slot).opacity(state.isOn ? 1 : 0.45)
        let h = layout.point(pitch: s.pitch)
        var spoke = Path()
        spoke.move(to: c)
        spoke.addLine(to: h)
        context.stroke(spoke, with: .color(colour), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        let hr = LightsOrbitMetrics.handleRadius
        context.fill(circle(h, hr), with: .color(colour))
        context.stroke(circle(h, hr), with: .color(style.text.opacity(0.85)), lineWidth: 1.5)
        // The value sits away from the level line's 0° label and the ends'
        // labels: above the handle from 0° to +60° and near −90°, below it
        // otherwise.
        let above = (s.pitch >= 0 && s.pitch < 60) || s.pitch < -60
        context.draw(Text(verbatim: state.pitchText).font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundColor(colour),
                     at: CGPoint(x: min(h.x, layout.size.width - 2), y: above ? h.y - hr - 3 : h.y + hr + 3),
                     anchor: above ? .bottomTrailing : .topTrailing)
    }
}

private func circle(_ centre: CGPoint, _ radius: CGFloat) -> Path {
    Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: 2 * radius, height: 2 * radius))
}
