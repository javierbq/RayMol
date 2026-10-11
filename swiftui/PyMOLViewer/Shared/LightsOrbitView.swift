// LightsOrbitView.swift — the orbit mini viewer's card (#621, spec §9,
// sketches 1 and 2).
//
// A card in the Lights side column, above the inspector: a flat plan of the
// rig seen from above (the camera at the bottom, +90° to the right) beside a
// pitch arc for the selected light.
// - Drag a lamp: orbit only, smoothly to 1° (VoiceOver steps 15°); a press on another lamp selects it
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

    /// The iPad float's grip (#623): the header row (not its chevron) drags
    /// the card, with a capsule in the top padding; nil elsewhere.
    var grip: LightsOrbitGrip?

    init(controller: LightsController, style: LightsBarStyle, initiallyCollapsed: Bool = false,
         grip: LightsOrbitGrip? = nil) {
        self.controller = controller
        self.style = style
        self.grip = grip
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
        .overlay(alignment: .top) { if let grip { gripHandle(grip) } }
        .tint(style.accent)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(state.containerLabel)
        .accessibilityIdentifier(LightsOrbitState.identifier)
    }

    // `Orbit` over the plan and `Pitch` over the arc (spec decision 11); the
    // collapsed header shows the selected light's values on one line instead.
    private func header(_ state: LightsOrbitState) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    LightMarkerDot(marker: state.selected.marker, size: 10)
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
            }
            // The float's grip: the header row up to the chevron.
            .modifier(OrbitGripRegion(grip: grip))
            collapseButton
        }
        .frame(height: max(Self.headerHeight, touchMinimum))
    }

    /// The grip's capsule in the top padding, and its VoiceOver element
    /// (the corner as its value, a move action per other corner). Touches
    /// pass through to the header row, which carries the drag.
    private func gripHandle(_ grip: LightsOrbitGrip) -> some View {
        Capsule()
            .fill(style.text.opacity(0.35))
            .frame(width: LightsFloatMetrics.gripSize.width, height: LightsFloatMetrics.gripSize.height)
            .padding(.top, 3)
            .frame(width: 60, height: 14, alignment: .top)
            .contentShape(Rectangle())
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel(grip.label)
            .accessibilityValue(grip.value)
            .accessibilityHint(grip.hint)
            .accessibilityIdentifier(grip.identifier)
            .accessibilityActions {
                ForEach(Array(grip.actions.enumerated()), id: \.offset) { _, action in
                    Button(action.name, action: action.perform)
                }
            }
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

/// What the iPad float hands the orbit card (#623): the drag its header
/// row carries, and the grip's VoiceOver element. The float owns the drag's
/// state (LightsFloatingTools); the card only places it.
struct LightsOrbitGrip {
    struct Action {
        var name: String
        var perform: () -> Void
    }

    var gesture: AnyGesture<Void>
    var label: String
    var value: String
    var hint: String
    var identifier: String
    var actions: [Action]
}

/// The header row as the grip: hit-testable across its width (a 44 pt
/// target on iOS), carrying the float's drag; unchanged without a grip.
private struct OrbitGripRegion: ViewModifier {
    let grip: LightsOrbitGrip?

    func body(content: Content) -> some View {
        if let grip {
            content
                .lightsTouchTarget(width: false)
                .contentShape(Rectangle())
                .gesture(grip.gesture)
        } else {
            content
        }
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

    /// At `point` with `anchor` (a fixed reference label).
    init(point: CGPoint, anchor: UnitPoint) {
        self.point = point
        self.anchor = anchor
    }

    /// The four places beside a mark at `p` of radius `clear`, in the order
    /// tried after a label's preferred one: below, above, right, left.
    static func sides(of p: CGPoint, clear: CGFloat) -> [OrbitLabelPlacement] {
        [OrbitLabelPlacement(beside: p, dx: 0, dy: 1, clear: clear),
         OrbitLabelPlacement(beside: p, dx: 0, dy: -1, clear: clear),
         OrbitLabelPlacement(beside: p, dx: 1, dy: 0, clear: clear),
         OrbitLabelPlacement(beside: p, dx: -1, dy: 0, clear: clear)]
    }

    /// `preferred`, then the sides of `p` it is not.
    static func candidates(_ preferred: OrbitLabelPlacement, around p: CGPoint,
                           clear: CGFloat) -> [OrbitLabelPlacement] {
        [preferred] + sides(of: p, clear: clear).filter { $0 != preferred }
    }
}

/// A circle a label must not cover: a lamp, the selected lamp's halo, the
/// pitch handle; the radius square or an arrowhead.
struct OrbitLabelObstacle: Equatable {
    var centre: CGPoint
    var radius: CGFloat
    /// It hides a ring or tick label it covers. False for the square and the
    /// arrowheads: they are drawn over those labels (as before #676), and
    /// only keep a label that moves from moving onto them.
    var hidesReferences = true

    /// The rect covers some of the circle (touching does not count).
    func overlaps(_ rect: CGRect) -> Bool {
        let x = min(max(centre.x, rect.minX), rect.maxX)
        let y = min(max(centre.y, rect.minY), rect.maxY)
        return hypot(x - centre.x, y - centre.y) < radius
    }
}

/// A label on the plan or the arc: its text and kind, where it may go in order
/// of preference, and where OrbitLabelLayout put it (nil: hidden).
struct OrbitLabel: Equatable {
    enum Kind: Equatable {
        /// The selected light's radius, orbit or pitch: value font, its colour.
        case value
        /// Another lamp's pitch label.
        case lamp
        /// A ring's or a tick's label: hidden when its one place is covered.
        case reference
    }
    var text: String
    var kind: Kind
    var candidates: [OrbitLabelPlacement]
    var frame: CGRect?

    static let labelFont = Font.system(size: 9).monospacedDigit()
    static let valueFont = Font.system(size: 10, weight: .medium).monospacedDigit()

    /// The font the label is measured and drawn in.
    var font: Font { kind == .value ? Self.valueFont : Self.labelFont }

    init(text: String, kind: Kind, candidates: [OrbitLabelPlacement], frame: CGRect? = nil) {
        self.text = text
        self.kind = kind
        self.candidates = candidates
        self.frame = frame
    }
}

/// Places labels so none covers another or a lamp (#676). Pure and
/// deterministic: labels are placed in order, each at its first candidate
/// whose rect (kept inside `bounds`) misses every label placed before it and
/// every obstacle (for a reference label, every one that hides it). A value
/// or lamp label with no clear candidate takes the one that covers the fewest
/// (the first of those); a reference label with none is hidden.
enum OrbitLabelLayout {
    /// How far a label may spill past its canvas (inside OrbitCanvas.bleed).
    static let bleed: CGFloat = 4

    /// The rect labels stay inside for a canvas of `size`.
    static func bounds(for size: CGSize) -> CGRect {
        CGRect(origin: .zero, size: size).insetBy(dx: -bleed, dy: -bleed)
    }

    /// Two label rects overlap (touching does not count).
    static func overlap(_ a: CGRect, _ b: CGRect) -> Bool {
        a.minX < b.maxX && b.minX < a.maxX && a.minY < b.maxY && b.minY < a.maxY
    }

    /// `labels` with their frames set, measured by `size`.
    static func place(_ labels: [OrbitLabel], obstacles: [OrbitLabelObstacle], in bounds: CGRect,
                      size: (OrbitLabel) -> CGSize) -> [OrbitLabel] {
        var placed: [CGRect] = []
        return labels.map { label in
            var label = label
            let s = size(label)
            let rects = label.candidates.map { CGRect(origin: $0.origin(for: s, in: bounds), size: s) }
            let blocking = label.kind == .reference ? obstacles.filter(\.hidesReferences) : obstacles
            let covered = rects.map { r in
                placed.filter { overlap($0, r) }.count + blocking.filter { $0.overlaps(r) }.count
            }
            if let clear = covered.firstIndex(of: 0) {
                label.frame = rects[clear]
            } else if label.kind != .reference, let fewest = covered.min(),
                      let best = covered.firstIndex(of: fewest) {
                label.frame = rects[best]
            } else {
                label.frame = nil
            }
            if let f = label.frame { placed.append(f) }
            return label
        }
    }
}

/// Every label the plan draws (#676), placed by OrbitLabelLayout in priority
/// order: the selected light's radius, then its orbit, then the other lamps'
/// labels in rig order, then the ring and tick labels.
struct OrbitPlanLabels: Equatable {
    var radius: OrbitLabel
    var orbit: OrbitLabel
    /// The other lamps' labels, in rig order (`state.others`).
    var lamps: [OrbitLabel]
    /// The ring labels (inner to outer), then `±180°`, `90°`, `−90°`, `0°`.
    var references: [OrbitLabel]

    var all: [OrbitLabel] { [radius, orbit] + lamps + references }

    /// The selected lamp's halo ring. Obstacles are the drawn circles'
    /// nominal radii, not their outer stroke edges: a label's rect already
    /// runs a point or two past its glyphs (line height), so a rect that only
    /// grazes a stroke leaves its text clear.
    static let haloRadius = LightsOrbitMetrics.selectedLampRadius + 4

    /// The radius of the selected light's orbit wedge (its value sits just
    /// outside or inside it).
    static func wedgeRadius(_ layout: OrbitPlanLayout) -> CGFloat {
        max(layout.ringRadius(1) + 9, 20)
    }

    /// What a label must not cover: every lamp with its outline, the
    /// selected lamp's halo with its stroke; and, for a label that moves,
    /// the radius square (at `squareAngle`, or its resting angle) and a
    /// clamped lamp's outward arrowhead.
    static func obstacles(state: LightsOrbitState, layout: OrbitPlanLayout,
                          squareAngle: Double? = nil) -> [OrbitLabelObstacle] {
        var obstacles = state.lamps.map { lamp in
            OrbitLabelObstacle(centre: layout.lampPoint(orbit: lamp.orbit, radius: lamp.radius),
                               radius: lamp.isSelected ? haloRadius : LightsOrbitMetrics.lampRadius)
        }
        let s = state.selected
        let angle = squareAngle ?? layout.squareAngle(radius: s.radius)
        obstacles.append(OrbitLabelObstacle(
            centre: layout.squarePoint(orbit: s.orbit, radius: s.radius, angle: angle),
            radius: LightsOrbitMetrics.squareHalfSide * 2.squareRoot(), hidesReferences: false))
        for lamp in state.lamps where layout.isClamped(radius: lamp.radius) {
            // OrbitPlanPainter's arrowhead: from `base` to `base + 5` along
            // the orbit, 3.5 either side.
            let p = layout.lampPoint(orbit: lamp.orbit, radius: lamp.radius)
            let o = LightAngles.offset(orbit: lamp.orbit)
            let base = (lamp.isSelected ? LightsOrbitMetrics.selectedLampRadius + 6
                                        : LightsOrbitMetrics.lampRadius + 2) + 2.5
            obstacles.append(OrbitLabelObstacle(
                centre: CGPoint(x: p.x + base * CGFloat(o.dx), y: p.y + base * CGFloat(o.dy)), radius: 4.5,
                hidesReferences: false))
        }
        return obstacles
    }

    init(state: LightsOrbitState, layout: OrbitPlanLayout, squareAngle: Double? = nil,
         size: (OrbitLabel) -> CGSize) {
        let s = state.selected
        let p = layout.lampPoint(orbit: s.orbit, radius: s.radius)
        let clear = Self.haloRadius
        let radiusPreferred = OrbitLabelPlacement(selectedLampAt: p, layout: layout, clear: clear)
        let unplacedRadius = OrbitLabel(
            text: state.radiusText,
            kind: .value,
            candidates: OrbitLabelPlacement.candidates(radiusPreferred, around: p, clear: clear)
        )

        // Its value outside the wedge, or inside it when the lamp or the
        // lamp's radius label is there.
        let wedge = Self.wedgeRadius(layout)
        let unplacedOrbit = OrbitLabel(
            text: state.orbitText,
            kind: .value,
            candidates: [
                OrbitLabelPlacement(centre: layout.point(orbit: s.orbit / 2, distance: wedge + 9)),
                OrbitLabelPlacement(centre: layout.point(orbit: s.orbit / 2, distance: max(wedge - 10, 4)))
            ]
        )

        let unplacedLamps = state.others.map { lamp -> OrbitLabel in
            let lp = layout.lampPoint(orbit: lamp.orbit, radius: lamp.radius)
            let lClear = LightsOrbitMetrics.lampRadius
            let preferred = OrbitLabelPlacement(lampAt: lp, orbit: lamp.orbit,
                                                distance: layout.drawnDistance(radius: lamp.radius),
                                                layout: layout, clear: lClear)
            return OrbitLabel(
                text: lamp.labelText,
                kind: .lamp,
                candidates: OrbitLabelPlacement.candidates(preferred, around: lp, clear: lClear)
            )
        }

        let c = layout.centre
        let outer = layout.outerRadius
        var unplacedReferences: [OrbitLabel] = layout.rings.map { ring in
            OrbitLabel(
                text: String(format: "%.0f×", ring),
                kind: .reference,
                candidates: [OrbitLabelPlacement(point: CGPoint(x: c.x - 3, y: c.y - layout.ringRadius(ring) + 2),
                                                 anchor: .topTrailing)]
            )
        }
        unplacedReferences.append(contentsOf: [
            OrbitLabel(text: "±180°", kind: .reference,
                       candidates: [OrbitLabelPlacement(point: CGPoint(x: c.x + 3, y: c.y - outer + 2),
                                                        anchor: .topLeading)]),
            OrbitLabel(text: "90°", kind: .reference,
                       candidates: [OrbitLabelPlacement(point: CGPoint(x: c.x + outer - 5, y: c.y - 2),
                                                        anchor: .bottomTrailing)]),
            OrbitLabel(text: "\(LightInspectorFormat.minus)90°", kind: .reference,
                       candidates: [OrbitLabelPlacement(point: CGPoint(x: c.x - outer + 5, y: c.y - 2),
                                                        anchor: .bottomLeading)]),
            OrbitLabel(text: "0°", kind: .reference,
                       candidates: [OrbitLabelPlacement(point: CGPoint(x: c.x + 5, y: c.y + outer - 3),
                                                        anchor: .bottomLeading)])
        ])

        let unplacedAll = [unplacedRadius, unplacedOrbit] + unplacedLamps + unplacedReferences
        let bounds = OrbitLabelLayout.bounds(for: layout.size)
        let obstacles = Self.obstacles(state: state, layout: layout, squareAngle: squareAngle)
        let placed = OrbitLabelLayout.place(unplacedAll, obstacles: obstacles, in: bounds, size: size)

        radius = placed[0]
        orbit = placed[1]
        let lampCount = state.others.count
        lamps = Array(placed[2..<(2 + lampCount)])
        references = Array(placed[(2 + lampCount)...])
    }
}

/// Every label the pitch arc draws (#676): the selected light's pitch, then
/// `+90°`, `−90°` and `0°`, hidden when the value or the handle covers them.
struct PitchArcLabels: Equatable {
    var value: OrbitLabel
    var references: [OrbitLabel]
    var all: [OrbitLabel] { [value] + references }

    /// The handle.
    static func obstacles(state: LightsOrbitState, layout: PitchArcLayout) -> [OrbitLabelObstacle] {
        [OrbitLabelObstacle(centre: layout.point(pitch: state.selected.pitch),
                            radius: LightsOrbitMetrics.handleRadius)]
    }

    init(state: LightsOrbitState, layout: PitchArcLayout, size: (OrbitLabel) -> CGSize) {
        let s = state.selected
        let h = layout.point(pitch: s.pitch)
        let hr = LightsOrbitMetrics.handleRadius
        let x = min(h.x, layout.size.width - 2)

        // The value sits away from the level line's 0° label and the ends'
        // labels: above the handle from 0° to +60° and near −90°, below it
        // otherwise.
        let aboveFirst = (s.pitch >= 0 && s.pitch < 60) || s.pitch < -60
        let above = OrbitLabelPlacement(point: CGPoint(x: x, y: h.y - hr - 3), anchor: .bottomTrailing)
        let below = OrbitLabelPlacement(point: CGPoint(x: x, y: h.y + hr + 3), anchor: .topTrailing)
        let unplacedValue = OrbitLabel(
            text: state.pitchText,
            kind: .value,
            candidates: aboveFirst ? [above, below] : [below, above]
        )

        let top = layout.point(pitch: 90)
        let bottom = layout.point(pitch: -90)
        let zero = layout.point(pitch: 0)
        let unplacedReferences = [
            OrbitLabel(text: "+90°", kind: .reference,
                       candidates: [OrbitLabelPlacement(point: CGPoint(x: top.x, y: top.y - 5),
                                                        anchor: .bottomLeading)]),
            OrbitLabel(text: "\(LightInspectorFormat.minus)90°", kind: .reference,
                       candidates: [OrbitLabelPlacement(point: CGPoint(x: bottom.x, y: bottom.y + 5),
                                                        anchor: .topLeading)]),
            OrbitLabel(text: "0°", kind: .reference,
                       candidates: [OrbitLabelPlacement(point: CGPoint(x: zero.x - 4, y: zero.y - 3),
                                                        anchor: .bottomTrailing)])
        ]

        let unplacedAll = [unplacedValue] + unplacedReferences
        let bounds = OrbitLabelLayout.bounds(for: layout.size)
        let obstacles = Self.obstacles(state: state, layout: layout)
        let placed = OrbitLabelLayout.place(unplacedAll, obstacles: obstacles, in: bounds, size: size)

        value = placed[0]
        references = Array(placed.dropFirst())
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

    func draw(in context: inout GraphicsContext) {
        let c = layout.centre
        let outer = layout.outerRadius
        let grey = style.text.opacity(0.2)
        let muted = style.text.opacity(0.55)

        var ink = OrbitLabelInk(context)
        let labels = OrbitPlanLabels(state: state, layout: layout, squareAngle: squareAngle) { ink.measure($0) }

        // The 1× disc: the edge of the molecules when the rig was centred.
        let disc = layout.ringRadius(1)
        context.fill(circle(c, disc), with: .color(style.text.opacity(0.08)))
        context.stroke(circle(c, disc), with: .color(style.text.opacity(0.25)), lineWidth: 0.75)
        // The rings, labelled just inside their tops, left of the axis.
        for (i, ring) in layout.rings.enumerated() {
            let r = layout.ringRadius(ring)
            context.stroke(circle(c, r), with: .color(grey), lineWidth: 1)
            ink.draw(labels.references[i], colour: muted, in: &context)
        }
        // The angle ticks across the outer ring and their labels inside it.
        for orbit in [0.0, 90, 180, -90] {
            var tick = Path()
            tick.move(to: layout.point(orbit: orbit, distance: outer - 3))
            tick.addLine(to: layout.point(orbit: orbit, distance: outer + 3))
            context.stroke(tick, with: .color(style.text.opacity(0.35)), lineWidth: 1)
        }
        for ref in labels.references.dropFirst(layout.rings.count) {
            ink.draw(ref, colour: muted, in: &context)
        }
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
        let wedge = OrbitPlanLabels.wedgeRadius(layout)
        context.stroke(arcPath(from: 0, to: s.orbit, radius: wedge), with: .color(colour), lineWidth: 1.5)
        ink.draw(labels.orbit, colour: colour, in: &context)

        // The dashed line from the centre to the lamp.
        var spoke = Path()
        spoke.move(to: c)
        spoke.addLine(to: selectedPoint)
        context.stroke(spoke, with: .color(colour), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

        // The beam ticks of lights aimed at a point (#678), under the lamps.
        for lamp in state.lamps {
            let r = lamp.isSelected ? LightsOrbitMetrics.selectedLampRadius : LightsOrbitMetrics.lampRadius
            let p = layout.lampPoint(orbit: lamp.orbit, radius: lamp.radius)
            guard let tick = layout.aimTick(from: p, lampRadius: r + (lamp.isSelected ? 4 : 0),
                                            aim: lamp.aimOffset) else { continue }
            var path = Path()
            path.move(to: tick.from)
            path.addLine(to: tick.to)
            context.stroke(path, with: .color(lamp.marker.fillColor.opacity(state.isOn ? 0.55 : 0.25)),
                           style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }

        // The other lamps, in rig order, with their pitch labels.
        for (lamp, label) in zip(state.others, labels.lamps) {
            let p = layout.lampPoint(orbit: lamp.orbit, radius: lamp.radius)
            drawLamp(&context, lamp, at: p, radius: LightsOrbitMetrics.lampRadius)
            ink.draw(label, colour: style.text.opacity(0.8), in: &context)
        }

        // The radius square on the selected ring.
        let angle = squareAngle ?? layout.squareAngle(radius: s.radius)
        let q = layout.squarePoint(orbit: s.orbit, radius: s.radius, angle: angle)
        let h = LightsOrbitMetrics.squareHalfSide
        let square = Path(roundedRect: CGRect(x: q.x - h, y: q.y - h, width: 2 * h, height: 2 * h), cornerRadius: 1.5)
        context.fill(square, with: .color(colour))
        context.stroke(square, with: .color(style.text.opacity(0.85)), lineWidth: 1)

        // The selected lamp, haloed, and its radius label.
        let r = LightsOrbitMetrics.selectedLampRadius
        let halo = OrbitPlanLabels.haloRadius
        context.stroke(circle(selectedPoint, halo),
                       with: .color(s.marker.outlineColor.opacity(state.isOn ? 0.35 : 0.15)), lineWidth: 2.5)
        context.stroke(circle(selectedPoint, halo), with: .color(colour), lineWidth: 1)
        drawLamp(&context, s, at: selectedPoint, radius: r)
        ink.draw(labels.radius, colour: colour, in: &context)
    }

    private func lampColour(_ lamp: LightsOrbitState.Lamp) -> Color {
        lamp.marker.fillColor.opacity(state.isOn ? 1 : 0.45)
    }

    private func drawLamp(_ context: inout GraphicsContext, _ lamp: LightsOrbitState.Lamp, at p: CGPoint,
                          radius r: CGFloat) {
        context.fill(circle(p, r), with: .color(lampColour(lamp)))
        // The marker's contrasting outline, so a white lamp still reads on
        // the dial (#798).
        context.stroke(circle(p, r),
                       with: .color(lamp.marker.outlineColor.opacity(state.isOn ? 0.85 : 0.4)),
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
            pin.shading = .color(lamp.marker.outlineColor)
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
        let rx = layout.radiusX, ry = layout.radiusY
        let muted = style.text.opacity(0.55)

        var ink = OrbitLabelInk(context)
        let labels = PitchArcLabels(state: state, layout: layout) { ink.measure($0) }

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
            tick.move(to: CGPoint(x: c.x + (rx - 3) * CGFloat(o.dx), y: c.y + (ry - 3) * CGFloat(o.dy)))
            tick.addLine(to: CGPoint(x: c.x + (rx + 3) * CGFloat(o.dx), y: c.y + (ry + 3) * CGFloat(o.dy)))
            context.stroke(tick, with: .color(style.text.opacity(0.35)), lineWidth: 1)
        }
        for ref in labels.references {
            ink.draw(ref, colour: muted, in: &context)
        }

        // The selected light: a dashed line to its handle, the handle, its value.
        let s = state.selected
        let colour = s.marker.fillColor.opacity(state.isOn ? 1 : 0.45)
        let h = layout.point(pitch: s.pitch)
        var spoke = Path()
        spoke.move(to: c)
        spoke.addLine(to: h)
        context.stroke(spoke, with: .color(colour), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        let hr = LightsOrbitMetrics.handleRadius
        context.fill(circle(h, hr), with: .color(colour))
        context.stroke(circle(h, hr), with: .color(s.marker.outlineColor.opacity(state.isOn ? 0.85 : 0.4)),
                       lineWidth: 1.5)
        ink.draw(labels.value, colour: colour, in: &context)
    }
}

/// Measures the orbit card's labels for OrbitLabelLayout and draws each into
/// its placed frame (a hidden one not at all), resolving each text once in
/// the label's own font.
private struct OrbitLabelInk {
    private let context: GraphicsContext
    private var resolved: [String: GraphicsContext.ResolvedText] = [:]

    init(_ context: GraphicsContext) {
        self.context = context
    }

    private static func key(_ label: OrbitLabel) -> String { "\(label.kind)|\(label.text)" }

    private mutating func text(_ label: OrbitLabel) -> GraphicsContext.ResolvedText {
        if let text = resolved[Self.key(label)] { return text }
        let text = context.resolve(Text(verbatim: label.text).font(label.font))
        resolved[Self.key(label)] = text
        return text
    }

    mutating func measure(_ label: OrbitLabel) -> CGSize {
        text(label).measure(in: CGSize(width: 1000, height: 1000))
    }

    mutating func draw(_ label: OrbitLabel, colour: Color, in context: inout GraphicsContext) {
        guard let frame = label.frame else { return }
        var text = text(label)
        text.shading = .color(colour)
        context.draw(text, in: frame)
    }
}

private func circle(_ centre: CGPoint, _ radius: CGFloat) -> Path {
    Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: 2 * radius, height: 2 * radius))
}
