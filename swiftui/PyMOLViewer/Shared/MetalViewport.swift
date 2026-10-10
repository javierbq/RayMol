// MetalViewport.swift — Cross-platform MTKView wrapper for SwiftUI
// Uses NSViewRepresentable on macOS, UIViewRepresentable on iPadOS.

import SwiftUI
import Combine
import MetalKit
import QuartzCore   // CACurrentMediaTime (the air redraw policy, #618)
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Render-loop gate (#396)

/// The decision the render loop makes on every display-link tick, factored out
/// as a pure type so it can be tested (a test cannot drive a CADisplayLink).
///
/// Two things had to change here. The old gate consumed PyMOL's redisplay flag
/// with `GetRedisplay(inst, reset: 1)` *before* the drawable was acquired, so a
/// frame that then failed to get a drawable dropped both the frame and the
/// request for it — the same shape as the earlier "mouse rotate silently
/// dropped" bug. And with ray tracing on, the GPU is the bottleneck: the loop
/// would keep handing frames to a queue that could not retire them, so the main
/// thread sat in `currentDrawable` (blocking input, the feedback timer and
/// SwiftUI commits) for about half of every rotation.
///
/// So: the gate PEEKS the flag (`reset: 0`), a separate in-flight cap makes the
/// loop skip a tick rather than pile on, and the flag is consumed only once the
/// frame is actually about to be encoded.
enum RenderGate {

    /// Committed-but-not-completed frames allowed before a tick is skipped.
    ///
    /// `CAMetalLayer.maximumDrawableCount` is 3, so staying below it leaves a
    /// drawable free and keeps the (now late) `currentDrawable` wait short.
    /// Two is still enough in-flight work to keep the GPU fed.
    static let maxFramesInFlight = 2

    enum Decision: Equatable {
        /// Encode a frame. The caller consumes the redisplay flag first.
        case render
        /// Nothing has changed; leave the last presented frame on screen.
        case skip
        /// There IS work to do, but too many frames are already in flight.
        /// The redisplay flag is left set, so a later tick picks this up.
        case throttle
    }

    static func decide(forceRedraw: Bool,
                       hasRenderedOnce: Bool,
                       redisplayPending: Bool,
                       framesInFlight: Int) -> Decision {
        // The very first frame always renders (defensive against a blank start
        // before anything has flagged a redisplay), and so does a forced one
        // after a wake/activate — the display can discard the drawable's
        // contents while asleep, and an unchanged scene flags no redisplay.
        let wants = forceRedraw || !hasRenderedOnce || redisplayPending
        guard wants else { return .skip }
        return framesInFlight >= maxFramesInFlight ? .throttle : .render
    }

    /// Whether the next tick must render unconditionally, given whether the
    /// frame just encoded reached the screen. A frame with no drawable rendered
    /// into the offscreen targets but presented nothing, and its redisplay flag
    /// is already consumed — without this the viewport would hold a stale image
    /// until the next interaction.
    static func forceRedrawAfterRender(presented: Bool) -> Bool { !presented }

    /// Display-link ceiling. Ray tracing makes frames GPU-bound well below
    /// 120 Hz, where the extra ticks buy nothing and each one still costs a
    /// `PyMOL_Idle` poll on the main thread.
    static func preferredFPS(rayTracing: Bool) -> Float { rayTracing ? 60 : 120 }
}

// MARK: - Air redraw policy (#618)

/// When the light rig's moving dust may ask the render loop for a frame.
///
/// The dust (`atmosphere dust=...`) moves with the clock, so it needs frames
/// that no redisplay flag asks for. Animated dust must not keep the GPU busy
/// when nobody can see it or the device is saving power, and must not run at
/// the display's full rate otherwise. So, like `RenderGate`, the decision is
/// a pure type the tests pin down, and `draw(in:)` only feeds it:
///
/// - no air tick at all while the app is inactive, its window hidden,
///   occluded or miniaturised, in Low Power Mode, or at a serious or critical
///   thermal state (the dust holds still; the next real change still renders);
/// - otherwise at most `activeFPS` air ticks a second.
///
/// The core is asked whether the dust moves (`PyMOLEngine.lightAirAnimating`,
/// plain C++) only on a tick this allows. A due tick then goes through the
/// unchanged `RenderGate.decide`, so the in-flight cap, the first frame and
/// wake behave as for any other redisplay.
///
/// Two launch switches support #623's device calibration, in any build and
/// read once per launch; neither changes a default:
/// - `RAYMOL_AIR_FPS=<1...120>` replaces the cap (`fps(environment:)`);
/// - `RAYMOL_AIR_LOG=1` logs each change of why the dust holds still, with
///   Low Power Mode and the thermal state (`holdLine`), so a device run can
///   see the hold policy act.
enum AirRedrawGate {

    /// Air ticks a second while the app is active and visible. Provisional:
    /// #623's device runs (appendix A) decide whether it stays.
    static let defaultFPS: Double = 30

    /// The caps `RAYMOL_AIR_FPS` may set, in air ticks a second.
    static let fpsRange: ClosedRange<Double> = 1...120

    /// The cap for this launch: `RAYMOL_AIR_FPS` when set to a number in
    /// `fpsRange`, else `defaultFPS`.
    static let activeFPS: Double = fps(environment: ProcessInfo.processInfo.environment)

    /// Whether this launch logs the hold reason's changes (`RAYMOL_AIR_LOG=1`).
    static let logsHolds: Bool = logEnabled(environment: ProcessInfo.processInfo.environment)

    /// The dust cap an environment asks for: `RAYMOL_AIR_FPS` as a finite
    /// number in `fpsRange`; anything else (unset, empty, out of range, not a
    /// number) is `defaultFPS`.
    static func fps(environment: [String: String]) -> Double {
        guard let raw = environment["RAYMOL_AIR_FPS"],
              let value = Double(raw.trimmingCharacters(in: .whitespaces)),
              value.isFinite, fpsRange.contains(value) else { return defaultFPS }
        return value
    }

    /// Whether an environment turns the hold log on: `RAYMOL_AIR_LOG=1` only.
    static func logEnabled(environment: [String: String]) -> Bool {
        environment["RAYMOL_AIR_LOG"]?.trimmingCharacters(in: .whitespaces) == "1"
    }

    /// A tick counts as due at this share of the interval, so display-link
    /// jitter (a tick landing a hair early) does not drop the dust to half
    /// the rate.
    static let dueShare: Double = 0.95

    /// What the platform says about the app and its window this tick.
    struct Activity: Equatable {
        /// The app is the active one (macOS) or its scene is in the
        /// foreground and active (iOS).
        var active: Bool
        /// The viewport's window is on screen: present, not occluded and not
        /// miniaturised.
        var visible: Bool
        /// Low Power Mode is on or the thermal state is serious or critical.
        var lowPower: Bool
    }

    /// Whether the device is saving power: Low Power Mode, or a thermal state
    /// of serious or worse.
    static func lowPower(lowPowerMode: Bool, thermalState: ProcessInfo.ThermalState) -> Bool {
        lowPowerMode || thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
    }

    /// The time between air ticks, or nil when the dust must hold still.
    static func interval(_ activity: Activity) -> TimeInterval? {
        guard activity.active, activity.visible, !activity.lowPower else { return nil }
        return 1 / activeFPS
    }

    /// Whether an air tick is due `now`, given when the last one was taken
    /// (both in seconds on the same clock).
    static func due(interval: TimeInterval, now: TimeInterval, lastFrame: TimeInterval) -> Bool {
        now - lastFrame >= dueShare * interval
    }

    // MARK: Hold log (#623's calibration)

    /// Why the dust holds still. The raw values are the log's words.
    enum HoldReason: String {
        /// The app is not the active one (another app, Control Centre or the
        /// app switcher in front).
        case inactive
        /// The viewport's window is not on screen.
        case hidden
        /// Low Power Mode, or a serious or critical thermal state.
        case lowPower = "low_power"
    }

    /// Why `interval` holds the dust still for `activity`, or nil when it
    /// may tick. The first failing condition of `interval`'s guard wins.
    static func holdReason(_ activity: Activity) -> HoldReason? {
        if !activity.active { return .inactive }
        if !activity.visible { return .hidden }
        if activity.lowPower { return .lowPower }
        return nil
    }

    /// What one hold log line reports. A new line is logged only when this
    /// changes, so a thermal step inside a hold (serious to critical) is
    /// logged too.
    struct HoldState: Equatable {
        var reason: HoldReason?
        var lowPowerMode: Bool
        var thermalState: ProcessInfo.ThermalState
    }

    /// The thermal state's word in the hold log.
    static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    /// The hold log line: `AirRedrawGate: hold=<reason|none>
    /// low_power_mode=<0|1> thermal=<state> fps=<cap>`.
    static func holdLine(_ state: HoldState, fps: Double) -> String {
        let cap = fps == fps.rounded() ? String(Int(fps)) : String(fps)
        return "AirRedrawGate: hold=\(state.reason?.rawValue ?? "none")"
            + " low_power_mode=\(state.lowPowerMode ? 1 : 0)"
            + " thermal=\(thermalName(state.thermalState)) fps=\(cap)"
    }
}

#if DEBUG
/// DEBUG check for the light gizmo (#622): the overlay lays the gizmo out at
/// its own size (`LightGizmoUIState.viewSize`), the viewport hit-tests it at
/// the MTKView's bounds. A difference over half a point (safe area or
/// letterbox drift) would put targets where nothing is drawn, so it is
/// logged, once per Lights session: the overlay's size is nil between
/// sessions, which re-arms the check.
struct LightGizmoSizeCheck: Equatable {
    static let tolerance: CGFloat = 0.5

    /// Lines produced so far, and the last one.
    private(set) var count = 0
    private(set) var lastLine: String?
    private var armed = true

    /// The line to log for this comparison, or nil.
    mutating func check(overlay: CGSize?, viewport: CGSize) -> String? {
        guard let overlay else {
            armed = true
            return nil
        }
        guard armed,
              abs(overlay.width - viewport.width) > Self.tolerance
                || abs(overlay.height - viewport.height) > Self.tolerance else { return nil }
        armed = false
        count += 1
        let line = String(format: "LightGizmo: overlay size %.1fx%.1f != viewport %.1fx%.1f",
                          overlay.width, overlay.height, viewport.width, viewport.height)
        lastLine = line
        return line
    }
}
#endif

#if os(macOS)
struct MetalViewport: NSViewRepresentable {
    @EnvironmentObject var engine: PyMOLEngine

    func makeNSView(context: Context) -> MTKView {
        let view = PyMOLMTKView(frame: .zero)
        view.device = MTLCreateSystemDefaultDevice()
        view.delegate = context.coordinator
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float_stencil8
        // Allow ProMotion (120Hz) on capable displays; the system clamps this to
        // the panel's actual max (e.g. 60 on non-ProMotion). The on-demand gate in
        // draw(in:) keeps the GPU idle on a static scene, so the higher tick only
        // costs a cheap idle poll when nothing is moving. The rate actually in
        // force comes from the view's own display link (setPreferredFPS), which
        // draw(in:) halves while ray tracing is on (#396).
        view.preferredFramesPerSecond = 120
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        context.coordinator.engine = engine
        context.coordinator.mtkView = view
        // Leaving Lights mode (Esc, Done) restores the normal cursor even
        // when the pointer never moves (#701).
        context.coordinator.modeCursorSink = engine.$interactionMode
            .receive(on: DispatchQueue.main)
            .sink { [weak coordinator = context.coordinator] _ in coordinator?.updateGizmoCursor() }
        // Back-reference so the view's NSEvent overrides can reach the
        // coordinator's input handlers. Without this, mouseDown/Dragged/etc.
        // call `coordinator?.handle...` on a nil coordinator and silently
        // no-op — mouse rotate/zoom/pan never reach PyMOL.
        view.coordinator = context.coordinator

        // Repaint when the app re-activates or the system wakes from sleep: the
        // display can discard the drawable's contents while asleep/locked, and
        // the on-demand gate (a static scene flags no redisplay) would otherwise
        // leave the viewport black until the next interaction.
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.handleWake),
            name: NSApplication.didBecomeActiveNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            context.coordinator, selector: #selector(Coordinator.handleWake),
            name: NSWorkspace.didWakeNotification, object: nil)
        // A state/frame change while a movie exists can leave the viewport on its
        // on-demand gate with nothing to repaint it; the engine posts this to
        // force one unconditional frame so the new state shows (issue #132).
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.handleWake),
            name: PyMOLEngine.forceRedrawNotification, object: nil)

        // Trackpad pinch → zoom. Two-finger drag (scrollWheel) → translate;
        // see handleScrollWheel. A real mouse wheel still zooms.
        let magnify = NSMagnificationGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleMagnification(_:)))
        view.addGestureRecognizer(magnify)

        // Trackpad two-finger twist → Z-axis roll. Only acts while the engine's
        // "Trackpad" mouse mode is on (engine.trackpadMode), mirroring the iOS
        // two-finger rotation gesture. Otherwise it's a no-op so it never fights
        // the classic per-button mouse modes.
        let rotate = NSRotationGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleRotationGesture(_:)))
        view.addGestureRecognizer(rotate)

        // Click-debug harness (PYMOL_AUTOCLICK="ndcx,ndcy[;ndcx,ndcy...]"): after
        // the scene renders, synthesize real clicks at the given NDC points
        // through the genuine mouse path. Each click's mouse→NDC math and the
        // resulting pick land in PYMOL_PICKDEBUG.
        if let spec = ProcessInfo.processInfo.environment["PYMOL_AUTOCLICK"] {
            let pts: [(CGFloat, CGFloat)] = spec.split(separator: ";").compactMap {
                let c = $0.split(separator: ",").compactMap { Double($0) }
                return c.count == 2 ? (CGFloat(c[0]), CGFloat(c[1])) : nil
            }
            for (i, p) in pts.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0 + Double(i) * 1.0) { [weak coordinator = context.coordinator] in
                    coordinator?.debugClick(ndcX: p.0, ndcY: p.1, in: view)
                }
            }
        }

        // Move-mode tap harness (PYMOL_AUTOMOVETAP="ndcx,ndcy[,jitterpx]"): see
        // Coordinator.debugMoveTap. Fires once the scene has rendered.
        if let spec = ProcessInfo.processInfo.environment["PYMOL_AUTOMOVETAP"] {
            let c = spec.split(separator: ",").compactMap { Double($0) }
            if c.count >= 2 {
                let jitter = c.count >= 3 ? CGFloat(c[2]) : 0
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak coordinator = context.coordinator] in
                    coordinator?.debugMoveTap(ndcX: CGFloat(c[0]), ndcY: CGFloat(c[1]), jitter: jitter, in: view)
                }
            }
        }

        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }
}

// Custom MTKView subclass to handle mouse/keyboard events on macOS
class PyMOLMTKView: MTKView {
    weak var coordinator: MetalViewport.Coordinator?

    // Decline keyboard first-responder so a click in the viewport does NOT steal
    // focus from the command-line input (issue #73): the command line stays "hot"
    // for typing while the user rotates/picks, matching desktop PyMOL. Mouse events
    // are still delivered to this view via the mouse overrides below + acceptsFirstMouse
    // (they don't require first-responder status).
    // Keyboard shortcuts do NOT depend on this view's responder status: cmd.set_key
    // bindings are dispatched from an app-level NSEvent monitor in ContentView
    // (installPyMOLKeyMonitor, #258), which sees keys regardless of focus.
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Render loop
    //
    // Drive draw(in:) from a display link we own instead of MetalKit's.
    //
    // MTKView creates its own CVDisplayLink in viewDidMoveToWindow, but only
    // starts it for a window that is already visible — and it never retries. A
    // launch that opens a document (Finder double-click on a .pse, `open file.pse`)
    // attaches this view to a window that is not visible yet, so the loop never
    // starts: draw(in:) is then reached ONLY by the handful of manual draw() calls
    // in PyMOLEngine.initialize()'s blank-on-launch guard and in handleWake. The
    // window paints those few frames and is stale from then on. Because PyMOL
    // executes queued mouse input inside a rendered frame (OrthoExecDeferred runs
    // from SceneRenderMetal), every drag is silently swallowed too — the viewport
    // looks frozen while menus, panels and the console stay responsive. Launching
    // the app first and opening the file afterwards hid it, since that view was
    // attached to a window that did become visible in time.
    //
    // Toggling isPaused does NOT fix it: MetalKit will not rebuild a display link
    // it never created. Owning the link sidesteps the ordering entirely. It ticks
    // at the screen's refresh rate and follows the view across displays; the
    // on-demand gate in draw(in:) still skips the GPU work for a static scene, so
    // a still viewport costs the same idle poll it did before.
    private var renderLink: CADisplayLink?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            // No window: drop our link and hand the loop back to MetalKit, so a
            // view that is re-attached later is never left with nothing driving it.
            renderLink?.invalidate()
            renderLink = nil
            isPaused = false
            return
        }
        guard renderLink == nil else { return }
        let link = displayLink(target: self, selector: #selector(renderTick))
        link.add(to: .main, forMode: .common)
        renderLink = link
        applyFPSToLink()  // re-assert a rate requested before the link existed
        isPaused = true   // ours drives now; don't let both loops draw
    }

    @objc private func renderTick() { draw() }

    // Ceiling for our display link, in Hz. Called every tick by the render loop
    // (which lowers it while ray tracing is on, #396) and applied only on a
    // change, so a steady rate costs one comparison. The link is created in
    // viewDidMoveToWindow, which may not have run yet — the value is remembered
    // and re-applied there.
    private var appliedFPS: Float = 0
    func setPreferredFPS(_ fps: Float) {
        guard fps > 0 else { return }
        appliedFPS = fps
        applyFPSToLink()
    }
    private func applyFPSToLink() {
        guard let link = renderLink, appliedFPS > 0 else { return }
        // A range, not a fixed rate: the system is free to tick slower when the
        // display or thermal state calls for it. The 30 Hz floor keeps a scene
        // that IS animating from being throttled to a crawl.
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: min(30, appliedFPS), maximum: appliedFPS, preferred: appliedFPS)
    }

    // Track pointer motion over the viewport so the hover pre-selection preview
    // (issue #165) can update as the mouse moves WITHOUT any button held. A
    // tracking area is required for mouseMoved/mouseExited to fire; recreate it
    // on every layout change so it always spans the current visible bounds.
    private var hoverTrackingArea: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = hoverTrackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow,
                      .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    // Light gizmo cursor (#701). A cursor rect over the whole view, so AppKit
    // owns the cursor and nothing is pushed (it cannot stick): the open hand
    // over a target, the closed hand while dragging, nothing otherwise.
    var gizmoCursorKind: LightGizmoCursorKind = .normal {
        didSet {
            guard gizmoCursorKind != oldValue else { return }
            window?.invalidateCursorRects(for: self)
            switch gizmoCursorKind {
            case .openHand: NSCursor.openHand.set()
            case .closedHand: NSCursor.closedHand.set()
            case .normal: NSCursor.arrow.set()
            }
        }
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        switch gizmoCursorKind {
        case .openHand: addCursorRect(visibleRect, cursor: .openHand)
        case .closedHand: addCursorRect(visibleRect, cursor: .closedHand)
        case .normal: break
        }
    }

    override func mouseMoved(with event: NSEvent) {
        coordinator?.handleMouseMoved(event, in: self)
    }
    override func mouseExited(with event: NSEvent) {
        coordinator?.handleMouseExited(event, in: self)
    }

    override func mouseDown(with event: NSEvent) {
        coordinator?.handleMouseDown(event, in: self)
    }
    override func mouseUp(with event: NSEvent) {
        coordinator?.handleMouseUp(event, in: self)
    }
    override func mouseDragged(with event: NSEvent) {
        coordinator?.handleMouseDragged(event, in: self)
    }
    override func rightMouseDown(with event: NSEvent) {
        coordinator?.handleRightMouseDown(event, in: self)
    }
    override func rightMouseUp(with event: NSEvent) {
        coordinator?.handleRightMouseUp(event, in: self)
    }
    override func rightMouseDragged(with event: NSEvent) {
        coordinator?.handleRightMouseDragged(event, in: self)
    }
    override func otherMouseDown(with event: NSEvent) {
        coordinator?.handleOtherMouseDown(event, in: self)
    }
    override func otherMouseUp(with event: NSEvent) {
        coordinator?.handleOtherMouseUp(event, in: self)
    }
    override func otherMouseDragged(with event: NSEvent) {
        coordinator?.handleOtherMouseDragged(event, in: self)
    }
    override func scrollWheel(with event: NSEvent) {
        coordinator?.handleScrollWheel(event, in: self)
    }
}

#elseif os(iOS)
struct MetalViewport: UIViewRepresentable {
    @EnvironmentObject var engine: PyMOLEngine

    #if DEBUG
    /// MTKViews made this launch: a simulator log shows one viewport per
    /// launch (`MetalViewport: makeUIView n=1`), so the phone light sheet's
    /// layouts never rebuild it (#623).
    private static var makeCount = 0
    #endif

    func makeUIView(context: Context) -> MTKView {
        #if DEBUG
        MetalViewport.makeCount += 1
        NSLog("MetalViewport: makeUIView n=\(MetalViewport.makeCount)")
        #endif
        let view = MTKView(frame: .zero)
        view.device = MTLCreateSystemDefaultDevice()
        view.delegate = context.coordinator
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float_stencil8
        // Allow ProMotion (120Hz) on capable displays; the system clamps this to
        // the panel's actual max (e.g. 60 on non-ProMotion). The on-demand gate in
        // draw(in:) keeps the GPU idle on a static scene, so the higher tick only
        // costs a cheap idle poll when nothing is moving. draw(in:) lowers this
        // to 60 while ray tracing is on, where frames are GPU-bound anyway (#396).
        view.preferredFramesPerSecond = 120
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.isMultipleTouchEnabled = true
        context.coordinator.engine = engine
        context.coordinator.mtkView = view
        // Repaint when the app returns to the foreground: backgrounding can
        // discard the drawable, and the on-demand gate would otherwise leave a
        // static scene's viewport black until the next touch.
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.handleWake),
            name: UIApplication.didBecomeActiveNotification, object: nil)
        // A state/frame change while a movie exists can leave the viewport on its
        // on-demand gate with nothing to repaint it; the engine posts this to
        // force one unconditional frame so the new state shows (issue #132).
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.handleWake),
            name: PyMOLEngine.forceRedrawNotification, object: nil)

        // Gesture recognizers for touch input
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        // TWO-finger drag = TRANSLATE (move). Composes with pinch (zoom) and
        // two-finger rotation (Z-roll) so one two-finger gesture pans + zooms +
        // rolls together — the standard "move and zoom" touch idiom.
        let twoPan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTwoFingerPan(_:)))
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        let rotation = UIRotationGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleRotation(_:)))
        let longPress = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        // THREE-finger drag = CLIP (slab): vertical moves the slab through the
        // scene, horizontal changes its thickness — the Shift+Right "clip"
        // interaction the macOS trackpad gesture uses (handleClip). Exclusive
        // (not in the two-finger compose family below).
        let clipPan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleClip(_:)))

        // One finger rotates; TWO fingers translate + zoom + roll (compose);
        // THREE fingers clip (slab). Pinch (zoom), the two-finger pan
        // (translate), and two-finger rotation (Z-roll) all recognize
        // simultaneously so you can move + zoom + roll in one gesture.
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        twoPan.minimumNumberOfTouches = 2
        twoPan.maximumNumberOfTouches = 2
        clipPan.minimumNumberOfTouches = 3
        clipPan.maximumNumberOfTouches = 3
        twoPan.delegate = context.coordinator
        pinch.delegate = context.coordinator
        rotation.delegate = context.coordinator
        // Lights mode (#623): the delegate declines a long-press on a light
        // gizmo knob, aim dot or handle (gestureRecognizerShouldBegin), so a
        // press held there and dragged still drags the target.
        longPress.delegate = context.coordinator

        view.addGestureRecognizer(tap)
        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(twoPan)
        view.addGestureRecognizer(clipPan)
        view.addGestureRecognizer(pinch)
        view.addGestureRecognizer(rotation)
        view.addGestureRecognizer(longPress)

        // iPad hover pre-selection preview (issue #165): a UIHoverGestureRecognizer
        // fires ONLY for an indirect pointer hover — trackpad (Magic Keyboard),
        // mouse, or Apple Pencil hover — with no button/touch held, mirroring the
        // macOS NSTrackingArea/mouseMoved path. It drives the same
        // engine.hoverPreview(...) → hover_preview_at → `_preselect` machinery.
        // Touch input never triggers it (no persistent cursor), so it needs no
        // gate against tap/drag.
        let hover = UIHoverGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleHover(_:)))
        view.addGestureRecognizer(hover)

        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }
}
#endif

// MARK: - Shared Coordinator (MTKViewDelegate + input handling)

extension MetalViewport {
    class Coordinator: NSObject, MTKViewDelegate {
        weak var engine: PyMOLEngine?
        weak var mtkView: MTKView?
        #if os(macOS)
        var modeCursorSink: AnyCancellable?
        #endif
        private var viewportSize: CGSize = .zero
        // Set when the app/display wakes (unlock, system wake, re-activate). The
        // next draw(in:) then renders unconditionally, bypassing the on-demand
        // gate, to repaint a drawable whose contents were discarded during sleep.
        fileprivate var forceRedraw = false

        // Wake/activate -> force one repaint. Also kicks an immediate draw() in
        // case the display link hasn't resumed ticking yet.
        @objc fileprivate func handleWake() {
            forceRedraw = true
            DispatchQueue.main.async { [weak self] in self?.mtkView?.draw() }
        }
        deinit {
            NotificationCenter.default.removeObserver(self)
            #if os(macOS)
            NSWorkspace.shared.notificationCenter.removeObserver(self)
            #endif
        }
        #if os(macOS)
        // Track the mouse-down point to distinguish a click (pick/select) from
        // a drag (rotate). Point space, view coordinates.
        private var mouseDownLoc: CGPoint = .zero
        private var didDrag = false
        // Move mode: distance (view points) the pointer must travel before a
        // press becomes a DRAG (orbit / gizmo-handle manipulation). Below it, the
        // press stays a candidate TAP → object select. Without this dead-zone a
        // sub-pixel jitter during a tap (macOS emits mouseDragged for <1pt moves)
        // armed didDrag and routed the release to the orbit path, so tap-to-select
        // only worked for a perfectly still click ("doesn't work consistently").
        private let moveDragSlop: CGFloat = 6
        // Move mode: the gizmo handle grabbed at mouse-down (nil = none → camera).
        private var moveHandle: GizmoHandle?
        // Right-button equivalents: a pure right-click raises the viewport
        // context menu (CPU pick → engine.longPressHit), while a right-DRAG
        // still drives PyMOL's clip (slab). The button-down is deferred to the
        // first drag so a bare click never enters clip mode.
        private var rightDownLoc: CGPoint = .zero
        private var rightDidDrag = false

        // Trackpad pinch (NSMagnificationGestureRecognizer) → zoom via an
        // explicit camera dolly (engine.zoomBy). We can't use the scroll-wheel
        // BUTTON path: PyMOL's default three_button_viewing binds the bare wheel
        // to 'slab' (clip), so it would change the slab, not zoom. magnification
        // is cumulative from gesture start; feed the per-callback delta as a
        // zoom fraction (spread = positive = zoom in).
        private var lastMag: CGFloat = 0
        private let kZoomGain: CGFloat = 1.0

        // Trackpad two-finger twist → Z-roll (Trackpad mode only). NSRotationGesture
        // .rotation is cumulative radians; feed the per-callback delta as `turn z`.
        // Negated so a clockwise twist rolls the molecule clockwise on screen, to
        // match the iOS handleRotation sign.
        private var lastRoll: CGFloat = 0
        private let kRollSign: Float = -1

        // Trackpad two-finger drag (delivered as precise scrollWheel events) →
        // translate. Synthesized as a PyMOL middle-button drag: a MIDDLE-DOWN at
        // the start, drag events that follow an accumulated synthetic cursor, and
        // a MIDDLE-UP when the gesture (incl. momentum) ends. A real mouse wheel
        // (no precise deltas) still zooms.
        private var panActive = false
        private var panCursorX: Int32 = 0
        private var panCursorY: Int32 = 0
        private var panEndDebounce: DispatchWorkItem?
        // Sign so the molecule follows the fingers (grab-and-move). Tunable.
        // Y is negated: macOS scrollingDeltaY is opposite the on-screen pan we
        // want (verified — up/down was inverted before the flip).
        private let kPanSignX: CGFloat = 1
        private let kPanSignY: CGFloat = -1

        // Gesture mode latched at drag START (a mid-drag modifier change can't
        // switch it). Shift held → synthesize a Shift+Right-button drag, which
        // PyMOL's three_button_viewing binds to 'clip' (vertical = move the slab
        // through the scene, horizontal = slab thickness). Otherwise a Middle-drag
        // = translate. Clip is not grab-and-move, so its Y is NOT negated; flip
        // kClipSignY if the up/down direction feels inverted.
        private var gestureButton: Int32 = PYMOL_BUTTON_MIDDLE
        private var gestureMods: Int32 = 0
        private var gestureIsClip = false
        private let kClipSignX: CGFloat = 1
        private let kClipSignY: CGFloat = 1

        // Hover pre-selection preview (issue #165): last view-point location fed
        // to a preview, used to skip re-picking when the pointer barely moved.
        // .zero is treated as "no prior move" (any first move re-picks).
        private var lastHoverLoc: CGPoint = .zero
        #endif

        #if os(iOS)
        // Pinch → zoom via explicit camera dolly (engine.zoomBy), not the wheel
        // BUTTON path (which maps to 'slab'). Feed the per-callback change in the
        // cumulative gesture.scale as a zoom fraction.
        private var pinchLastScale: CGFloat = 1.0
        private let kZoomGain: CGFloat = 1.0
        // Two-finger rotation → Z-axis roll. UIRotationGestureRecognizer.rotation
        // is cumulative radians; feed the per-callback delta as a `turn z` (deg).
        // Negated so a clockwise twist rolls the molecule clockwise on screen;
        // flip kRollSign if it feels inverted.
        private var lastRotation: CGFloat = 0
        private let kRollSign: Float = -1
        // Last position fed to a multi-finger drag (translate / clip). On release
        // the touches lift unevenly and the pan recognizer's centroid jumps to the
        // remaining finger; replaying that jumped location as the button-UP would
        // translate/clip by a phantom delta (the structure "jumps" on release). We
        // send the UP at this last dragged point instead, making release a no-op.
        private var lastDragPt: (Int32, Int32)?
        // Clip drags anchor their X so only the NEAR plane moves (front-only
        // clip): cButModeClipNF maps horizontal→far, vertical→near, and a
        // touch/trackpad drag has both components, so feeding X too would move
        // both planes (a slab) — the "cull from front AND back" the user saw.
        private var clipAnchorX: Int32?
        // Move mode: the gizmo handle a one-finger pan is manipulating (nil =
        // none → the pan orbits the camera).
        private var panMoveHandle: GizmoHandle?
        // Hover pre-selection preview (issue #165): last hover location fed to a
        // preview, used to skip re-picking when the pointer barely moved. .zero
        // is treated as "no prior move" (any first move re-picks).
        private var lastHoverLoc: CGPoint = .zero
        // Lights mode (#623): the two-finger sequence under way (pinch, two-
        // finger pan and twist recognize together); its first recognizer to
        // begin decides whether the gizmo (a pinch on a knob) or the camera
        // owns all three. And the scale the gizmo's pinch began at.
        private var lightTwoFinger = LightTwoFingerSequence()
        private var lightPinchStartScale: CGFloat = 1
        #endif

        // MARK: - MTKViewDelegate

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            viewportSize = size
            engine?.viewportPixelSize = size
            engine?.reshape(width: Int(size.width), height: Int(size.height))
        }

        private var wasSuppressed = false
        private var hasRenderedOnce = false
        private var moveSyncCounter = 0
        // The air redraw policy (#618, AirRedrawGate): when the last frame
        // rendered, and when the core was last asked whether the dust moves
        // (so a rig whose dust holds still is asked at most activeFPS times
        // a second, not on every display tick). CACurrentMediaTime seconds.
        private var lastFrameTime: CFTimeInterval = 0
        private var lastAirCheckTime: CFTimeInterval = 0
        // The last hold state logged under RAYMOL_AIR_LOG=1 (#623), nil
        // before the first line.
        private var lastAirHold: AirRedrawGate.HoldState?

        // Keep the tick rate matched to how expensive frames currently are
        // (#396). On macOS the view owns the display link we drive; on iOS
        // MetalKit's own loop is still in charge, so this goes through the
        // view's preferredFramesPerSecond.
        private func applyPreferredFPS(to view: MTKView, engine: PyMOLEngine) {
            let fps = RenderGate.preferredFPS(rayTracing: engine.metalRayTracing)
            #if os(macOS)
            (view as? PyMOLMTKView)?.setPreferredFPS(fps)
            #else
            let target = Int(fps)
            if view.preferredFramesPerSecond != target {
                view.preferredFramesPerSecond = target
            }
            #endif
        }

        /// What the platform says about the app and the viewport's window this
        /// tick, for AirRedrawGate (#618). Main thread (draw(in:)).
        private func airActivity(of view: MTKView) -> AirRedrawGate.Activity {
            let info = ProcessInfo.processInfo
            let lowPower = AirRedrawGate.lowPower(lowPowerMode: info.isLowPowerModeEnabled,
                                                  thermalState: info.thermalState)
            #if os(macOS)
            let visible = view.window.map {
                $0.isVisible && $0.occlusionState.contains(.visible) && !$0.isMiniaturized
            } ?? false
            return AirRedrawGate.Activity(active: NSApp.isActive, visible: visible,
                                          lowPower: lowPower)
            #else
            let window = view.window
            let active = window?.windowScene?.activationState == .foregroundActive
            return AirRedrawGate.Activity(active: active, visible: window != nil && !view.isHidden,
                                          lowPower: lowPower)
            #endif
        }

        /// Whether this tick should render for the moving dust alone (#618).
        /// The core is asked only when AirRedrawGate allows a tick and one is
        /// due; otherwise this costs a few platform reads and no bridge call.
        private func airTickDue(view: MTKView, engine: PyMOLEngine) -> Bool {
            let activity = airActivity(of: view)
            if AirRedrawGate.logsHolds { noteAirHold(activity) }
            guard let interval = AirRedrawGate.interval(activity) else { return false }
            let now = CACurrentMediaTime()
            guard AirRedrawGate.due(interval: interval, now: now,
                                    lastFrame: max(lastFrameTime, lastAirCheckTime)) else {
                return false
            }
            lastAirCheckTime = now
            return engine.lightAirAnimating
        }

        /// Logs the hold state when it changed since the last line
        /// (RAYMOL_AIR_LOG=1 only, any build; #623's calibration). Runs on
        /// the idle ticks airTickDue sees, so it never asks the core.
        private func noteAirHold(_ activity: AirRedrawGate.Activity) {
            let info = ProcessInfo.processInfo
            let state = AirRedrawGate.HoldState(reason: AirRedrawGate.holdReason(activity),
                                                lowPowerMode: info.isLowPowerModeEnabled,
                                                thermalState: info.thermalState)
            guard state != lastAirHold else { return }
            lastAirHold = state
            NSLog("%@", AirRedrawGate.holdLine(state, fps: AirRedrawGate.activeFPS))
        }

        func draw(in view: MTKView) {
            guard let engine = engine, engine.isReady else { return }
            // A movie export renders frames off the main thread and owns the core
            // exclusively (it reshapes global state per frame). Skip the live
            // render meanwhile so we never race it; the exporter restores the
            // scene + clears this flag when done, and the next tick redraws. (#58 L-59)
            if engine.exportRenderActive { return }
            // Keep the Move gizmo's 2D hit-geometry (+ debug bullseye overlay)
            // continuously in sync with the camera — not just on mouse-move — so a
            // cursor parked after an orbit/zoom still sees current targets and the
            // next grab maps to the visible gizmo. Throttled to ~15 Hz; readGizmo
            // republishes only when the projection actually moved (no churn on a
            // static view). Skipped WHILE dragging a handle: metal_move omits the
            // per-tick emit there and the CGO already tracks via its synced TTT.
            if engine.interactionMode == .move {
                #if os(macOS)
                let draggingGizmo = moveHandle != nil
                #else
                let draggingGizmo = panMoveHandle != nil
                #endif
                if !draggingGizmo {
                    moveSyncCounter += 1
                    if moveSyncCounter >= 8 { moveSyncCounter = 0; engine.refreshGizmo() }
                } else {
                    moveSyncCounter = 0
                }
            }
            // Panel-resize drag: while suppressed, freeze the drawable size so the
            // renderer doesn't reallocate offscreen targets on every frame (choppy
            // + OOM). On resume, snap the drawable to the current bounds ONCE,
            // which fires drawableSizeWillChange → a single reshape.
            let suppress = engine.suppressDrawableResize
            if suppress != wasSuppressed {
                wasSuppressed = suppress
                view.autoResizeDrawable = !suppress
                if !suppress {
                    #if os(iOS)
                    let scale = view.contentScaleFactor
                    #else
                    let scale = view.window?.backingScaleFactor ?? 2.0
                    #endif
                    let target = CGSize(width: view.bounds.width * scale,
                                        height: view.bounds.height * scale)
                    if target.width > 0, target.height > 0, target != view.drawableSize {
                        view.drawableSize = target   // → drawableSizeWillChange → one reshape
                    }
                }
            }
            // Build RendererMetal on the first frame (bridge no-ops thereafter),
            // then run PyMOL's idle work (advances movies/animations and sets the
            // redisplay flag).
            engine.setupMetalRenderer(view: view)
            // Ray tracing makes frames GPU-bound far below 120 Hz; drop the tick
            // rate so the surplus ticks stop costing a PyMOL_Idle each (#396).
            // Cheap and idempotent, so it can ride along on every tick.
            applyPreferredFPS(to: view, engine: engine)
            engine.idle()

            // On-demand rendering: skip the GPU-expensive frame when nothing
            // needs redrawing — a static structure then costs only a cheap idle
            // poll instead of a full render every tick, the bulk of the
            // battery/thermal win. The last presented frame stays on screen.
            // Mirrors the legacy AppKit loop (main_appkit.mm).
            //
            // The flag is PEEKED here (reset: 0) and consumed below only once
            // this tick has committed to encoding a frame, so a throttled tick
            // leaves the request standing instead of swallowing it (#396).
            let pending = engine.instance.map { PyMOLBridge_GetRedisplay($0, 0) != 0 } ?? false
            // Moving dust (#618) asks for a frame that no flag requests, but
            // only on a tick AirRedrawGate allows, and only when nothing else
            // already renders this tick: the core is not asked otherwise.
            let airDue = !pending && !forceRedraw && hasRenderedOnce
                && airTickDue(view: view, engine: engine)
            switch RenderGate.decide(forceRedraw: forceRedraw,
                                     hasRenderedOnce: hasRenderedOnce,
                                     redisplayPending: pending || airDue,
                                     framesInFlight: engine.metalFramesInFlight) {
            case .skip:
                // Nothing is dirty, so no deferred rep build is waiting on a
                // frame. A synchronous heavy op (image export / Copy Image)
                // leaves the scene clean, and waiting for "build frames" that
                // never render held its overlay up until the 60 s backstop.
                engine.heavyRenderTick(presented: false)
                return
            case .throttle:
                return
            case .render:
                break
            }

            // Consume the flag NOW, before the scene traversal: PyMOL sets it
            // again from inside SceneRenderMetal when queued input (a drag, a
            // click) needs another frame, so clearing it afterwards would eat
            // the next frame of every drag.
            if let inst = engine.instance { _ = PyMOLBridge_GetRedisplay(inst, 1) }

            // The bridge acquires the drawable itself, after the scene is
            // encoded — see PyMOLBridge_RenderMetalFrame. `presented` is false
            // when no drawable arrived: the frame rendered offscreen but nothing
            // reached the screen, so force the next tick to render again.
            let size = view.drawableSize
            let presented = engine.renderMetalFrame(view: view,
                                                    width: Int(size.width),
                                                    height: Int(size.height))
            hasRenderedOnce = hasRenderedOnce || presented
            forceRedraw = RenderGate.forceRedrawAfterRender(presented: presented)
            lastFrameTime = CACurrentMediaTime()
            // This frame built any deferred rep geometry (e.g. a surface mesh);
            // let the engine clear the "Calculating…" overlay once the build
            // frame(s) have completed.
            engine.heavyRenderTick(presented: presented)
            // Lights mode only (#620): refresh the light tools' per-frame eye
            // data (a pinned light's placement follows the camera). Outside
            // the mode this is one enum compare per rendered frame.
            if engine.interactionMode == .lights {
                engine.lightsFrameRendered()
            }
        }

        // MARK: - Coordinate conversion

        private func pymolPoint(in view: MTKView, at point: CGPoint) -> (Int32, Int32) {
            #if os(macOS)
            let backing = view.convertToBacking(point)
            return (Int32(backing.x), Int32(backing.y))
            #else
            let scale = view.contentScaleFactor
            return (Int32(point.x * scale), Int32(point.y * scale))
            #endif
        }

        private func pymolModifiers(_ flags: UInt) -> Int32 {
            var mods: Int32 = 0
            #if os(macOS)
            let nsFlags = NSEvent.ModifierFlags(rawValue: flags)
            if nsFlags.contains(.shift) { mods |= PYMOL_MOD_SHIFT }
            if nsFlags.contains(.control) { mods |= PYMOL_MOD_CTRL }
            if nsFlags.contains(.option) { mods |= PYMOL_MOD_ALT }
            #endif
            return mods
        }

        // MARK: - Move-mode gizmo hit-testing (shared)

        // A view point -> (ndc_x, ndc_y, aspect) in PyMOL NDC (bottom-left, +y up).
        // macOS view points are already bottom-left; UIKit points are top-left.
        private func gizmoNDC(in view: MTKView, at p: CGPoint) -> (Float, Float, Float)? {
            let w = view.bounds.width, h = view.bounds.height
            guard w > 0, h > 0 else { return nil }
            let nx = Float(p.x / w) * 2 - 1
            #if os(macOS)
            let ny = Float(p.y / h) * 2 - 1
            #else
            let ny = 1 - Float(p.y / h) * 2
            #endif
            return (nx, ny, Float(w / h))
        }

        // MARK: - Box Select input (#358)

        // True while Box Select owns the viewport. Every camera gesture below
        // early-returns on this: the issue's "camera controls are disabled" is
        // what makes drawing the box possible at all, since otherwise the same
        // drag would orbit the scene out from under the rectangle.
        var boxSelectActive: Bool { engine?.interactionMode == .boxSelect }

        // Grab band around the box's edges/corners, in NDC-Y units (~1.75% of the
        // viewport height each side, so ~20 pt of target on a 600 pt viewport).
        private let boxGrabSlop: CGFloat = 0.035

        // Press: grab an edge / corner / the interior of the existing box, or —
        // if the press misses it — start drawing a new one.
        //
        // A NEW box opens a session (snapshotting the selection it will compose
        // against); adjusting the existing one keeps the session it already has,
        // so dragging a corner back in takes atoms away again instead of
        // ratcheting them on.
        private func boxBegin(in view: MTKView, at p: CGPoint) {
            guard let engine = engine, let (nx, ny, aspect) = gizmoNDC(in: view, at: p) else { return }
            let ndc = CGPoint(x: CGFloat(nx), y: CGFloat(ny))
            if let existing = engine.boxRect,
               let drag = existing.beginDrag(at: ndc, aspect: CGFloat(aspect), slop: boxGrabSlop) {
                engine.boxDrag = drag
            } else {
                engine.boxDrag = BoxRect.beginNewDrag(at: ndc)
                engine.beginBoxSession()
            }
        }

        private func boxUpdate(in view: MTKView, at p: CGPoint) {
            guard let engine = engine, let drag = engine.boxDrag,
                  let (nx, ny, _) = gizmoNDC(in: view, at: p) else { return }
            engine.setBoxRect(drag.rect(at: CGPoint(x: CGFloat(nx), y: CGFloat(ny))))
        }

        // Release. The drag has been committing all along, so this just lands the
        // final rectangle. A press that never moved is a TAP: on the box it
        // leaves it alone, outside it dismisses the box — WITHOUT committing an
        // empty rectangle, so a stray click can't wipe the selection the box just
        // made.
        private func boxEnd(in view: MTKView, at p: CGPoint) {
            guard let engine = engine else { return }
            defer { engine.boxDrag = nil }
            guard let drag = engine.boxDrag,
                  let (nx, ny, _) = gizmoNDC(in: view, at: p) else { return }
            let rect = drag.rect(at: CGPoint(x: CGFloat(nx), y: CGFloat(ny)))
            if rect.isDegenerate {
                engine.setBoxRect(drag.translates ? drag.origin : nil)
            } else {
                engine.setBoxRect(rect)
            }
        }

        // The gizmo handle under a view point (Move mode only), or nil.
        private func gizmoHit(in view: MTKView, at p: CGPoint) -> GizmoHandle? {
            guard let g = engine?.gizmo, let (nx, ny, aspect) = gizmoNDC(in: view, at: p) else { return nil }
            return g.hitTest(ndc: CGPoint(x: CGFloat(nx), y: CGFloat(ny)), aspect: CGFloat(aspect))
        }

        // MARK: - Light gizmo input (#622)
        //
        // The overlay draws the gizmo (LightGizmoOverlay, SwiftUI); the
        // viewport hit-tests the same layout (the Box Select pattern), built
        // by the engine from the controller's published eye space and
        // projection at the MTKView's own size. Every branch below runs only
        // in Lights mode, or for a press, scroll or pinch the gizmo already
        // owns; a miss keeps today's camera gesture. A drag tick reaches only
        // the owner-guarded light setters (bridge, no Python, #610).

        /// A scroll the gizmo owns: the trackpad scroll that began over a
        /// knob, latched from its `.began` to the end of its momentum (the
        /// momentum is swallowed, never a camera pan).
        private var lightScroll: LightGizmoScrollSession?
        private var lightScrollLatched = false
        /// A pinch that began over a knob (macOS trackpad), or the pinch of a
        /// two-finger sequence the gizmo owns (iOS, #623).
        private var lightPinch: OrbitPinchSession?
        /// Clears a mouse-wheel notch's radius readout once the wheel rests.
        private var lightReadoutClear: DispatchWorkItem?

        #if DEBUG
        /// The overlay draws at its own size and the viewport hit-tests at
        /// the MTKView's bounds; a difference (safe area, letterbox drift)
        /// would put targets where nothing is drawn. Logged once per Lights
        /// session.
        var lightGizmoSizeCheck = LightGizmoSizeCheck()
        #endif

        /// A view point in the top-left points the gizmo is laid out in
        /// (macOS views are bottom-left; UIKit's are already top-left).
        private func lightGizmoPoint(_ p: CGPoint, in view: MTKView) -> CGPoint {
            #if os(macOS)
            return CGPoint(x: p.x, y: view.bounds.height - p.y)
            #else
            return p
            #endif
        }

        /// The gizmo as drawn now over `view`, or nil when it is hidden (not
        /// Lights mode, no lights or eye data, grid mode, an export).
        private func lightGizmoLayout(in view: MTKView) -> LightGizmoLayout? {
            guard let engine, engine.interactionMode == .lights else { return nil }
            let size = view.bounds.size
            #if DEBUG
            let overlay = MainActor.assumeIsolated { engine.lightGizmoUI.viewSize }
            if let line = lightGizmoSizeCheck.check(overlay: overlay, viewport: size) {
                NSLog("%@", line)
            }
            #endif
            return engine.lightGizmoLayout(viewSize: size)
        }

        private func lightGizmoInteraction(_ engine: PyMOLEngine) -> LightGizmoInteraction {
            MainActor.assumeIsolated {
                LightGizmoInteraction(controller: engine.lightsController, picker: engine.lightGizmoPicker)
            }
        }

        /// The overlay shows the pointer's drag (none once it ended), with
        /// the readout of the layout after the tick's write beside `pointer`
        /// (top-left points; nil: beside the target) (#703).
        private func showLightGizmoDrag(_ engine: PyMOLEngine, in view: MTKView, at pointer: CGPoint?) {
            let layout = engine.lightGizmoPointer.session == nil ? nil : lightGizmoLayout(in: view)
            MainActor.assumeIsolated {
                engine.lightGizmoUI.track(engine.lightGizmoPointer.session, layout: layout, pointer: pointer)
            }
        }

        /// The overlay shows the radius of `name`'s light (a scroll or a
        /// pinch on its knob), or no readout when `name` is nil.
        private func showLightGizmoRadius(of name: String?, _ engine: PyMOLEngine, in view: MTKView) {
            let layout = name == nil ? nil : lightGizmoLayout(in: view)
            let shown = name.flatMap { layout?.knob(named: $0)?.name }
            MainActor.assumeIsolated { engine.lightGizmoUI.showRadius(of: shown, layout: layout) }
        }

        /// Hover (macOS pointer, iPad pointer): the target under `p`
        /// (top-left points), nil off every target or when `p` is nil (the
        /// pointer left). Lights mode only.
        private func lightGizmoHover(at p: CGPoint?, in view: MTKView) {
            guard let engine, engine.interactionMode == .lights else { return }
            let target = p.flatMap { point in
                lightGizmoLayout(in: view).flatMap { LightGizmoHitTest.target(at: point, layout: $0) }
            }
            MainActor.assumeIsolated { engine.lightGizmoUI.hovered = target }
        }

        #if os(macOS)
        /// The viewport's cursor for the gizmo state (#701). The pointer is
        /// outside the view (`inside` false) or the mode is not Lights: normal.
        func updateGizmoCursor(inside: Bool = true) {
            guard let engine, let view = mtkView as? PyMOLMTKView else { return }
            let kind: LightGizmoCursorKind = MainActor.assumeIsolated {
                LightGizmoCursorKind.cursor(
                    mode: engine.interactionMode,
                    hovered: inside ? engine.lightGizmoUI.hovered : nil,
                    isDragging: engine.lightGizmoPointer.ownsPress)
            }
            view.gizmoCursorKind = kind
        }
        #endif

        /// A press at `p` (top-left points): true when the gizmo took it (a
        /// target was hit and its session opened, or an option-press off
        /// every target waits to be a click). `clickCount` is the event's: a
        /// double-click's second press on the aim dot re-aims the light at the
        /// centre on its release (#699). Outside Lights mode it only forgets a
        /// press the gizmo still held (its release never came).
        private func lightGizmoPress(at p: CGPoint, option: Bool, clickCount: Int, in view: MTKView) -> Bool {
            guard let engine else { return false }
            guard engine.interactionMode == .lights else {
                let pointer = engine.lightGizmoPointer
                if pointer.ownsPress || pointer.candidate != nil { engine.lightGizmoPointer.cancel() }
                return false
            }
            let layout = lightGizmoLayout(in: view)
            let interaction = lightGizmoInteraction(engine)
            let route = MainActor.assumeIsolated {
                engine.lightGizmoPointer.press(at: p, option: option, layout: layout, interaction: interaction,
                                               clickCount: clickCount)
            }
            if route == .gizmo { showLightGizmoDrag(engine, in: view, at: p) }
            return route != .camera
        }

        /// A drag to `p`: true while the gizmo owns the press, whatever the
        /// mode is now (after Esc the session writes no more and the rest of
        /// the drag is swallowed), or while an option-press is still within
        /// its slop. False hands it to today's camera path.
        private func lightGizmoDrag(to p: CGPoint, in view: MTKView) -> Bool {
            guard let engine else { return false }
            let pointer = engine.lightGizmoPointer
            guard pointer.ownsPress || pointer.candidate != nil else { return false }
            let interaction = lightGizmoInteraction(engine)
            let route = MainActor.assumeIsolated {
                engine.lightGizmoPointer.drag(to: p, interaction: interaction)
            }
            if route == .gizmo { showLightGizmoDrag(engine, in: view, at: p) }
            return route != .camera
        }

        /// The press ends at `p`: true when it was the gizmo's (the session
        /// ends; an option-click that never dragged places a highlight at its
        /// press point). No atom pick and no button-up follow.
        private func lightGizmoRelease(at p: CGPoint, in view: MTKView) -> Bool {
            guard let engine else { return false }
            let pointer = engine.lightGizmoPointer
            guard pointer.ownsPress || pointer.candidate != nil else { return false }
            let interaction = lightGizmoInteraction(engine)
            let route = MainActor.assumeIsolated {
                engine.lightGizmoPointer.release(at: p, interaction: interaction)
            }
            showLightGizmoDrag(engine, in: view, at: nil)
            return route != .camera
        }

        // MARK: - macOS mouse handling

        #if os(macOS)
        func handleMouseDown(_ event: NSEvent, in view: MTKView) {
            defer { updateGizmoCursor() }
            // Don't send PyMOL a button-down yet: a left-click in PyMOL's
            // viewing mode runs SceneClick/Release, whose GL pick is dead on
            // Metal and ends up CLEARING the active selection. We only want
            // PyMOL's mouse handling for an actual drag (rotate), so the
            // button-down is deferred to the first drag event (below). A pure
            // click selects via metal_pick in mouseUp instead.
            // A committing click starts: drop any hover preview so it can't
            // linger under (or fight) the committed selection.
            engine?.clearHoverPreview()
            lastHoverLoc = .zero
            mouseDownLoc = view.convert(event.locationInWindow, from: nil)
            didDrag = false
            // Box Select: the press starts (or grabs) the rectangle; no PyMOL
            // button event is ever sent, so the camera cannot move.
            if boxSelectActive {
                boxBegin(in: view, at: mouseDownLoc)
                return
            }
            // Lights mode (#622): a press on a light gizmo target is the
            // gizmo's to its release; no PyMOL button event is ever sent.
            if lightGizmoPress(at: lightGizmoPoint(mouseDownLoc, in: view),
                               option: event.modifierFlags.contains(.option),
                               clickCount: event.clickCount, in: view) {
                return
            }
            // Move mode: remember whether the press landed on a gizmo handle, so
            // the drag manipulates the object; otherwise the drag orbits the camera.
            moveHandle = nil
            if engine?.interactionMode == .move {
                // Shift → adjust-frame mode for this drag (re-anchor the gizmo).
                engine?.moveShiftHeld = event.modifierFlags.contains(.shift)
                // Refresh the hit geometry in case the click arrived with no prior
                // hover move (e.g. right after an external view change), so the grab
                // maps to the currently-visible handle. No-op cost if already fresh.
                if let (_, _, a) = gizmoNDC(in: view, at: mouseDownLoc) {
                    engine?.refreshGizmo(aspect: a)
                }
                moveHandle = gizmoHit(in: view, at: mouseDownLoc)
            }
        }

        // Pointer moved over the viewport with no button held → refresh the hover
        // pre-selection preview (issue #165). No-op while measuring or during a
        // drag (didDrag guards the button-held drag path). Computes NDC EXACTLY
        // like handleMouseUp — bottom-left origin, no Y flip — so the preview
        // aligns with what a click would select. A sub-pixel move gate skips the
        // re-pick when the pointer barely moved; the engine additionally
        // debounces the actual Python pick.
        func handleMouseMoved(_ event: NSEvent, in view: MTKView) {
            defer { updateGizmoCursor() }
            guard !didDrag else { return }
            // No hover picking while the box tool is on: the box is already
            // driving the selection, and a hover pick would fight it.
            guard !boxSelectActive else { return }
            let loc = view.convert(event.locationInWindow, from: nil)
            if lastHoverLoc != .zero,
               hypot(loc.x - lastHoverLoc.x, loc.y - lastHoverLoc.y) < 2 {
                return
            }
            lastHoverLoc = loc
            // Move mode: highlight the gizmo handle under the cursor so it's
            // obvious which axis/ring/center a drag will grab. Also reflect Shift
            // so the gizmo greys out (adjust-frame mode) as you hover with it held.
            if engine?.interactionMode == .move {
                engine?.moveShiftHeld = event.modifierFlags.contains(.shift)
                // Re-emit the hit-test geometry for the CURRENT view before testing.
                // The cached 2D projection goes stale on ANY view change — not just
                // the four gesture-end sites that call refreshGizmo, but also the
                // camera dock / Lens, Scene orient·reset·center, MCP/AI commands,
                // movie playback and window resizes. Hovering the visible ring then
                // hit the OLD cached ring (→ no highlight, wrong grab). Refreshing
                // here — gated by the 2px hover step, cheaper than the per-hover atom
                // pick already run in viewing mode, and republished only when the
                // projection actually moved — makes hover + the subsequent grab
                // always map to the handle the user sees. Uses the hover's own aspect
                // so the emitted geometry and the cursor share one aspect.
                if let (nx, ny, a) = gizmoNDC(in: view, at: loc) {
                    engine?.refreshGizmo(aspect: a)
                    if PyMOLEngine.bullseyeEnabled {
                        engine?.bullseyeCursorNDC = CGPoint(x: CGFloat(nx), y: CGFloat(ny))
                    }
                }
                let hit = gizmoHit(in: view, at: loc)
                if engine?.hoveredHandle != hit { engine?.hoveredHandle = hit }
                return
            }
            guard engine?.measureMode == nil else { return }
            // Lights mode (#619) skips the atom hover pick: its readout would
            // cover the Lights bar's Done. The light gizmo's hover hit test
            // runs instead (#622): the overlay strokes the target a press
            // would take.
            if engine?.interactionMode == .lights {
                lightGizmoHover(at: lightGizmoPoint(loc, in: view), in: view)
                return
            }
            let w = view.bounds.width, h = view.bounds.height
            guard w > 0, h > 0 else { return }
            let ndcX = Float(loc.x / w) * 2 - 1
            let ndcY = Float(loc.y / h) * 2 - 1
            #if RAYMOL_MPNN
            if engine?.designMode == true {
                engine?.hoverDesignPreview(ndcX, ndcY, Float(w / h))
            } else {
                engine?.hoverPreview(ndcX, ndcY, Float(w / h))
            }
            #else
            engine?.hoverPreview(ndcX, ndcY, Float(w / h))
            #endif
        }

        // Pointer left the viewport → clear the preview so it doesn't linger.
        func handleMouseExited(_ event: NSEvent, in view: MTKView) {
            lastHoverLoc = .zero
            engine?.clearHoverPreview()
            if engine?.hoveredHandle != nil { engine?.hoveredHandle = nil }
            // Drop Shift adjust-mode when the pointer leaves, so the gizmo doesn't
            // stay greyed if Shift is released outside the viewport.
            if engine?.moveShiftHeld == true { engine?.moveShiftHeld = false }
            // Lights mode (#622): no light gizmo hover once the pointer left.
            lightGizmoHover(at: nil, in: view)
            updateGizmoCursor(inside: false)
        }

        func handleMouseUp(_ event: NSEvent, in view: MTKView) {
            defer { updateGizmoCursor() }
            // Clear the drag flag on exit so passive hover (which is gated on
            // !didDrag) resumes immediately after a drag, not only after the next
            // mouse-down.
            defer { didDrag = false }
            let loc = view.convert(event.locationInWindow, from: nil)
            if boxSelectActive {
                boxEnd(in: view, at: loc)
                return
            }
            // A press the light gizmo owns ends here, whatever the mode is now
            // (#622): no button-up and no atom pick. An option-click that never
            // dragged places a highlight instead of picking an atom.
            if lightGizmoRelease(at: lightGizmoPoint(loc, in: view), in: view) {
                return
            }
            let mods = pymolModifiers(event.modifierFlags.rawValue)
            let moved = hypot(loc.x - mouseDownLoc.x, loc.y - mouseDownLoc.y)

            if engine?.interactionMode == .move {
                let aspect = Float(view.bounds.width / max(view.bounds.height, 1))
                if moveHandle != nil, didDrag {
                    engine?.gizmoEndDrag()
                    moveHandle = nil
                    return
                }
                moveHandle = nil
                if didDrag {
                    // Finish the camera orbit (empty-space drag).
                    let pt = pymolPoint(in: view, at: loc)
                    engine?.button(PYMOL_BUTTON_LEFT, state: PYMOL_BUTTON_UP, x: pt.0, y: pt.1, modifiers: mods)
                    engine?.refreshGizmo(aspect: aspect)
                    return
                }
                // Not a drag (the press stayed inside moveDragSlop) → treat as a
                // TAP and grab-what-you-touch. No separate distance gate here: the
                // dead-zone in handleMouseDragged already guarantees didDrag is only
                // set once the pointer really moved, so a shaky tap still selects.
                if let (nx, ny, a) = gizmoNDC(in: view, at: loc) {
                    engine?.moveSetActiveAt(ndcX: nx, ndcY: ny, aspect: a)
                }
                return
            }

            if didDrag {
                // Finish the rotate drag.
                let pt = pymolPoint(in: view, at: loc)
                engine?.button(PYMOL_BUTTON_LEFT, state: PYMOL_BUTTON_UP, x: pt.0, y: pt.1, modifiers: mods)
                // Reset the drag latch so hover resumes after the rotate ends.
                // (didDrag is only cleared on mouseDown; without this, a drag
                // leaves it true and handleMouseMoved's `!didDrag` guard blocks
                // all hover until the next click — hover "stopped after rotating".)
                didDrag = false
                lastHoverLoc = .zero
                return
            }

            // Pure click (no drag, no PyMOL button events sent) → CPU pick.
            // NDC in view-point space, bottom-left origin (macOS views aren't
            // flipped, matching PyMOL's NDC) so no Y flip.
            if moved < 4 {
                let w = view.bounds.width, h = view.bounds.height
                if w > 0, h > 0 {
                    let ndcX = Float(loc.x / w) * 2 - 1
                    let ndcY = Float(loc.y / h) * 2 - 1
                    // Pick-debug: record the click in top-down (SwiftUI) points so
                    // the overlay crosshair lands exactly where the user clicked.
                    if PyMOLEngine.debugPickEnabled {
                        engine?.debugClickPoint = CGPoint(x: loc.x, y: h - loc.y)
                    }
                    Self.pickDbg(String(format:
                        "mouseUp loc=(%.1f,%.1f) bounds=(%.1f,%.1f) backing=%.2f -> ndc=(%.4f,%.4f) aspect=%.4f",
                        loc.x, loc.y, w, h, view.window?.backingScaleFactor ?? 0,
                        ndcX, ndcY, Float(w / h)))
                    if engine?.measureMode != nil {
                        engine?.measurePick(ndcX: ndcX, ndcY: ndcY, aspect: Float(w / h))
                    } else if engine?.designMode == true {
                        // Design mode: identify the object under the click so
                        // ContentView can route it to DesignController.focus.
                        engine?.longPressPick(ndcX: ndcX, ndcY: ndcY, aspect: Float(w / h))
                    } else {
                        engine?.pick(ndcX: ndcX, ndcY: ndcY, aspect: Float(w / h))
                    }
                }
            }
        }

        // --- Click-debug harness (PYMOL_AUTOCLICK) ---
        // Append a line to PYMOL_PICKDEBUG so the mouse→NDC math is visible
        // alongside pick_at's projection (which logs to the same file).
        static func pickDbg(_ s: String) {
            guard let path = ProcessInfo.processInfo.environment["PYMOL_PICKDEBUG"] else { return }
            if let fh = FileHandle(forWritingAtPath: path) ?? {
                FileManager.default.createFile(atPath: path, contents: nil)
                return FileHandle(forWritingAtPath: path)
            }() {
                fh.seekToEndOfFile()
                fh.write((s + "\n").data(using: .utf8)!)
                try? fh.close()
            }
        }

        // Synthesize a real left-click at the given NDC by converting NDC → view
        // point → window point and dispatching genuine NSEvents through the
        // view's mouseDown/mouseUp — the EXACT path a user click takes. Lets the
        // debug harness click precise scene positions without Accessibility.
        func debugClick(ndcX: CGFloat, ndcY: CGFloat, in view: MTKView) {
            let w = view.bounds.width, h = view.bounds.height
            guard w > 0, h > 0, let win = view.window else { return }
            let vp = CGPoint(x: (ndcX + 1) / 2 * w, y: (ndcY + 1) / 2 * h) // bottom-left
            let winPt = view.convert(vp, to: nil)
            let ts = ProcessInfo.processInfo.systemUptime
            let mk = { (type: NSEvent.EventType) -> NSEvent? in
                NSEvent.mouseEvent(with: type, location: winPt, modifierFlags: [],
                                   timestamp: ts, windowNumber: win.windowNumber,
                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            }
            Self.pickDbg(String(format: "debugClick ndc=(%.4f,%.4f) -> vpoint=(%.1f,%.1f) winpoint=(%.1f,%.1f)",
                                Float(ndcX), Float(ndcY), vp.x, vp.y, winPt.x, winPt.y))
            if let d = mk(.leftMouseDown) { view.mouseDown(with: d) }
            if let u = mk(.leftMouseUp)   { view.mouseUp(with: u) }
        }

        // Move-mode variant of debugClick (PYMOL_AUTOMOVETAP harness): switch to
        // Move mode, then dispatch press → optional jitter mouseDragged → release
        // through the genuine handler path, exercising the tap-vs-drag
        // discrimination (moveDragSlop). Verifies tap-to-select without HID
        // injection (raw CGEvent taps don't reach the window on a second display /
        // in a VM). jitter < moveDragSlop must SELECT; jitter > moveDragSlop must
        // ORBIT. Inspect the resulting active object via MCP.
        func debugMoveTap(ndcX: CGFloat, ndcY: CGFloat, jitter: CGFloat, in view: MTKView) {
            guard let win = view.window else { return }
            engine?.setInteractionMode(.move)
            let w = view.bounds.width, h = view.bounds.height
            guard w > 0, h > 0 else { return }
            let vp = CGPoint(x: (ndcX + 1) / 2 * w, y: (ndcY + 1) / 2 * h) // bottom-left
            let down = view.convert(vp, to: nil)
            let moved = CGPoint(x: down.x + jitter, y: down.y + jitter)
            let ts = ProcessInfo.processInfo.systemUptime
            let mk = { (type: NSEvent.EventType, p: CGPoint) -> NSEvent? in
                NSEvent.mouseEvent(with: type, location: p, modifierFlags: [],
                                   timestamp: ts, windowNumber: win.windowNumber,
                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            }
            Self.pickDbg(String(format: "debugMoveTap ndc=(%.4f,%.4f) jitter=%.1f",
                                Float(ndcX), Float(ndcY), Float(jitter)))
            if let d = mk(.leftMouseDown, down) { view.mouseDown(with: d) }
            if jitter != 0, let g = mk(.leftMouseDragged, moved) { view.mouseDragged(with: g) }
            if let u = mk(.leftMouseUp, jitter != 0 ? moved : down) { view.mouseUp(with: u) }
        }

        func handleMouseDragged(_ event: NSEvent, in view: MTKView) {
            let loc = view.convert(event.locationInWindow, from: nil)
            if boxSelectActive {
                didDrag = true
                boxUpdate(in: view, at: loc)
                return
            }
            // A press the light gizmo owns drags the gizmo, even after Esc
            // (#622): nothing reaches the camera until the release.
            if lightGizmoDrag(to: lightGizmoPoint(loc, in: view), in: view) {
                return
            }
            let mods = pymolModifiers(event.modifierFlags.rawValue)

            if engine?.interactionMode == .move {
                guard let (nx, ny, aspect) = gizmoNDC(in: view, at: loc) else { return }
                // Dead-zone: until the pointer has travelled past the slop, keep the
                // press a candidate TAP (don't arm didDrag or start orbit/handle
                // drag). This is what makes tap-to-select fire on a slightly shaky
                // click instead of being swallowed as a tiny camera orbit.
                if !didDrag,
                   hypot(loc.x - mouseDownLoc.x, loc.y - mouseDownLoc.y) < moveDragSlop {
                    return
                }
                if let h = moveHandle {
                    // Dragging a gizmo handle → manipulate the active object.
                    if !didDrag {
                        didDrag = true
                        if let (dnx, dny, _) = gizmoNDC(in: view, at: mouseDownLoc) {
                            engine?.gizmoBeginDrag(h, ndcX: dnx, ndcY: dny, aspect: aspect)
                        }
                    }
                    engine?.gizmoUpdateDrag(ndcX: nx, ndcY: ny, aspect: aspect)
                    return
                }
                // Empty-space drag → orbit the camera. The gizmo is a 3D CGO that
                // re-renders from the new camera automatically, so we do NOT refresh
                // its 2D hit-test geometry per tick — that per-tick Python round-trip
                // + JSON file I/O is what made orbiting laggy (even with no active
                // object). It's refreshed once on mouseUp for the next hover/click.
                if !didDrag {
                    didDrag = true
                    let down = pymolPoint(in: view, at: mouseDownLoc)
                    engine?.button(PYMOL_BUTTON_LEFT, state: PYMOL_BUTTON_DOWN, x: down.0, y: down.1, modifiers: mods)
                }
                let pt = pymolPoint(in: view, at: loc)
                engine?.drag(x: pt.0, y: pt.1, modifiers: mods)
                return
            }

            if !didDrag {
                // First movement: now send the button-down (at the press point)
                // so PyMOL enters rotate mode for this drag.
                didDrag = true
                // A rotate/drag begins: drop the hover preview (the pointer is no
                // longer just hovering) and reset the move gate.
                engine?.clearHoverPreview()
                lastHoverLoc = .zero
                let down = pymolPoint(in: view, at: mouseDownLoc)
                engine?.button(PYMOL_BUTTON_LEFT, state: PYMOL_BUTTON_DOWN, x: down.0, y: down.1, modifiers: mods)
            }
            let pt = pymolPoint(in: view, at: loc)
            engine?.drag(x: pt.0, y: pt.1, modifiers: mods)
        }

        func handleRightMouseDown(_ event: NSEvent, in view: MTKView) {
            guard !boxSelectActive else { return }   // camera frozen (#358)
            // Defer PyMOL's button-down: raising it here would immediately enter
            // clip mode, and PyMOL's own pop-up menu is never rendered under this
            // Metal backend (internal_gui=0). A bare right-click instead pops the
            // native SwiftUI context menu in handleRightMouseUp; a right-DRAG
            // starts the clip on first movement (handleRightMouseDragged).
            rightDownLoc = view.convert(event.locationInWindow, from: nil)
            rightDidDrag = false
        }

        func handleRightMouseUp(_ event: NSEvent, in view: MTKView) {
            guard !boxSelectActive else { return }   // camera frozen (#358)
            let loc = view.convert(event.locationInWindow, from: nil)
            let mods = pymolModifiers(event.modifierFlags.rawValue)

            if rightDidDrag {
                // Finish the clip (slab) drag.
                let pt = pymolPoint(in: view, at: loc)
                engine?.button(PYMOL_BUTTON_RIGHT, state: PYMOL_BUTTON_UP, x: pt.0, y: pt.1, modifiers: mods)
                return
            }

            // Pure right-click → identify the atom/residue under the cursor and
            // publish it so ContentView shows the viewport context menu. NDC in
            // view-point space, bottom-left origin (macOS views aren't flipped),
            // matching the left-click pick — so no Y flip.
            let w = view.bounds.width, h = view.bounds.height
            guard w > 0, h > 0 else { return }
            let ndcX = Float(loc.x / w) * 2 - 1
            let ndcY = Float(loc.y / h) * 2 - 1
            engine?.longPressPick(ndcX: ndcX, ndcY: ndcY, aspect: Float(w / h))
        }

        func handleRightMouseDragged(_ event: NSEvent, in view: MTKView) {
            guard !boxSelectActive else { return }   // camera frozen (#358)
            let loc = view.convert(event.locationInWindow, from: nil)
            let mods = pymolModifiers(event.modifierFlags.rawValue)
            let moved = hypot(loc.x - rightDownLoc.x, loc.y - rightDownLoc.y)
            if !rightDidDrag {
                // First real movement past the click threshold: now raise the
                // deferred button-down (at the press point) to begin the clip.
                guard moved >= 4 else { return }
                rightDidDrag = true
                let down = pymolPoint(in: view, at: rightDownLoc)
                engine?.button(PYMOL_BUTTON_RIGHT, state: PYMOL_BUTTON_DOWN, x: down.0, y: down.1, modifiers: mods)
            }
            let pt = pymolPoint(in: view, at: loc)
            engine?.drag(x: pt.0, y: pt.1, modifiers: mods)
        }

        func handleOtherMouseDown(_ event: NSEvent, in view: MTKView) {
            guard !boxSelectActive else { return }   // camera frozen (#358)
            let pt = pymolPoint(in: view, at: view.convert(event.locationInWindow, from: nil))
            let mods = pymolModifiers(event.modifierFlags.rawValue)
            engine?.button(PYMOL_BUTTON_MIDDLE, state: PYMOL_BUTTON_DOWN, x: pt.0, y: pt.1, modifiers: mods)
        }

        func handleOtherMouseUp(_ event: NSEvent, in view: MTKView) {
            guard !boxSelectActive else { return }   // camera frozen (#358)
            let pt = pymolPoint(in: view, at: view.convert(event.locationInWindow, from: nil))
            let mods = pymolModifiers(event.modifierFlags.rawValue)
            engine?.button(PYMOL_BUTTON_MIDDLE, state: PYMOL_BUTTON_UP, x: pt.0, y: pt.1, modifiers: mods)
        }

        func handleOtherMouseDragged(_ event: NSEvent, in view: MTKView) {
            guard !boxSelectActive else { return }   // camera frozen (#358)
            let pt = pymolPoint(in: view, at: view.convert(event.locationInWindow, from: nil))
            let mods = pymolModifiers(event.modifierFlags.rawValue)
            engine?.drag(x: pt.0, y: pt.1, modifiers: mods)
        }

        func handleScrollWheel(_ event: NSEvent, in view: MTKView) {
            guard !boxSelectActive else { return }   // camera frozen (#358)
            let loc = view.convert(event.locationInWindow, from: nil)
            // Lights mode (#622): a wheel notch, or a trackpad scroll that
            // begins, over a light's knob sets that light's radius.
            if lightGizmoScroll(event, at: lightGizmoPoint(loc, in: view), in: view) {
                return
            }
            let pt = pymolPoint(in: view, at: loc)
            let mods = pymolModifiers(event.modifierFlags.rawValue)

            let phase = event.phase
            let momentum = event.momentumPhase

            // A traditional scroll WHEEL has no touch phase (a trackpad / Magic
            // Mouse gesture always sets phase or momentumPhase). Route the wheel
            // to PyMOL's default bare-wheel binding = SLAB (clip), via the scroll
            // button. Touch-surface two-finger scroll falls through to PAN below.
            if phase == [] && momentum == [] {
                let wheel = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.deltaY
                guard wheel != 0 else { return }
                let btn: Int32 = wheel > 0 ? PYMOL_BUTTON_SCROLL_FORWARD : PYMOL_BUTTON_SCROLL_REVERSE
                engine?.button(btn, state: PYMOL_BUTTON_DOWN, x: pt.0, y: pt.1, modifiers: mods)
                return
            }

            // Trackpad two-finger drag. Latch the mode at the START: Shift held →
            // CLIP (Shift+Right-drag), else PAN (Middle-drag). Real trackpad
            // gestures begin with phase == .began; synthetic/no-phase precise
            // scrolls (and momentum without a prior .began) start on first delta.
            let scale = view.window?.backingScaleFactor ?? 2.0
            if !panActive && (phase == .began || (phase == [] && momentum != .ended)) {
                gestureIsClip = event.modifierFlags.contains(.shift)
                gestureButton = gestureIsClip ? PYMOL_BUTTON_RIGHT : PYMOL_BUTTON_MIDDLE
                gestureMods = gestureIsClip ? PYMOL_MOD_SHIFT : 0
                panActive = true
                panCursorX = pt.0
                panCursorY = pt.1
                engine?.button(gestureButton, state: PYMOL_BUTTON_DOWN,
                               x: panCursorX, y: panCursorY, modifiers: gestureMods)
            }

            let signX = gestureIsClip ? kClipSignX : kPanSignX
            let signY = gestureIsClip ? kClipSignY : kPanSignY
            let dx = Int32((event.scrollingDeltaX * scale * signX).rounded())
            let dy = Int32((event.scrollingDeltaY * scale * signY).rounded())

            if panActive && (dx != 0 || dy != 0) {
                // macOS views are bottom-left origin (matching PyMOL); a finger
                // moving up has positive scrollingDeltaY, so add directly.
                // For CLIP, hold X fixed so only the near plane (vertical →
                // front clip) moves — horizontal would move the far plane,
                // closing the slab from both sides.
                if !gestureIsClip { panCursorX += dx }
                panCursorY += dy
                engine?.drag(x: panCursorX, y: panCursorY, modifiers: gestureMods)
            }

            // End when the momentum glide finishes (the true end), or on cancel.
            // We deliberately DON'T end at phase == .ended (fingers up): momentum
            // events follow with phase == [] and would re-trigger the start
            // condition, restarting the drag mid-glide. The debounce is the
            // safety net for flicks that produce no momentum and for synthetic
            // no-phase event streams.
            if phase == .cancelled || momentum == .ended {
                endTrackpadPan()
            } else if panActive {
                armPanEndDebounce()
            }
        }

        private func armPanEndDebounce() {
            panEndDebounce?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.endTrackpadPan() }
            panEndDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }

        private func endTrackpadPan() {
            panEndDebounce?.cancel()
            panEndDebounce = nil
            guard panActive else { return }
            panActive = false
            engine?.button(gestureButton, state: PYMOL_BUTTON_UP,
                           x: panCursorX, y: panCursorY, modifiers: gestureMods)
        }

        /// The light gizmo's share of a scroll event (#622), at `p` (top-left
        /// points): true when it is consumed.
        /// - A trackpad scroll that began over a knob stays the gizmo's from
        ///   its `.began` to the end of its momentum: each change adds to the
        ///   radius (one 0.5× step per `trackpadStep` points; positive
        ///   `scrollingDeltaY` is farther, as a wheel's forward); the
        ///   momentum is swallowed. A new gesture or a wheel notch ends it.
        /// - In Lights mode, a wheel notch over a knob is one step (forward:
        ///   farther), and a trackpad scroll whose `.began` lands on a knob
        ///   latches. Anywhere else, today's clip and pan.
        private func lightGizmoScroll(_ event: NSEvent, at p: CGPoint, in view: MTKView) -> Bool {
            guard let engine else { return false }
            let phase = event.phase, momentum = event.momentumPhase
            let isWheel = phase == [] && momentum == []
            if lightScrollLatched {
                if isWheel || phase == .began || phase == .mayBegin {
                    lightScrollLatched = false
                    lightScroll = nil
                } else {
                    if phase == .changed, var session = lightScroll {
                        let interaction = lightGizmoInteraction(engine)
                        MainActor.assumeIsolated { _ = interaction.scroll(&session, deltaY: event.scrollingDeltaY) }
                        lightScroll = session
                        showLightGizmoRadius(of: session.owner, engine, in: view)
                    }
                    if phase == .ended || phase == .cancelled, lightScroll != nil {
                        lightScroll = nil
                        showLightGizmoRadius(of: nil, engine, in: view)
                    }
                    if phase == .cancelled || momentum == .ended { lightScrollLatched = false }
                    return true
                }
            }
            guard engine.interactionMode == .lights else { return false }
            if isWheel {
                guard let layout = lightGizmoLayout(in: view),
                      let name = LightGizmoHitTest.knob(at: p, layout: layout) else { return false }
                let wheel = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.deltaY
                guard wheel != 0 else { return true }
                let interaction = lightGizmoInteraction(engine)
                MainActor.assumeIsolated { _ = interaction.scrollWheel(at: p, up: wheel > 0, layout: layout) }
                showLightGizmoRadius(of: name, engine, in: view)
                lightReadoutClear?.cancel()
                let clear = DispatchWorkItem { [weak self, weak engine, weak view] in
                    guard let self, let engine, let view, self.lightScroll == nil, self.lightPinch == nil else { return }
                    self.showLightGizmoRadius(of: nil, engine, in: view)
                }
                lightReadoutClear = clear
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: clear)
                return true
            }
            guard phase == .began, !panActive, let layout = lightGizmoLayout(in: view) else { return false }
            let interaction = lightGizmoInteraction(engine)
            guard var session = MainActor.assumeIsolated({ interaction.beginScroll(at: p, layout: layout) }) else {
                return false
            }
            lightReadoutClear?.cancel()
            MainActor.assumeIsolated { _ = interaction.scroll(&session, deltaY: event.scrollingDeltaY) }
            lightScroll = session
            lightScrollLatched = true
            showLightGizmoRadius(of: session.owner, engine, in: view)
            return true
        }

        /// The light gizmo's share of a trackpad pinch (#622): one that
        /// begins over a knob sets that light's radius (#621's pinch session,
        /// the 0.5× grid) until it ends; true when it is consumed.
        private func lightGizmoMagnification(_ gesture: NSMagnificationGestureRecognizer) -> Bool {
            guard let engine, let view = mtkView else { return false }
            switch gesture.state {
            case .began:
                lightPinch = nil
                guard engine.interactionMode == .lights, let layout = lightGizmoLayout(in: view) else { return false }
                let p = lightGizmoPoint(gesture.location(in: view), in: view)
                let interaction = lightGizmoInteraction(engine)
                guard let session = MainActor.assumeIsolated({ interaction.beginPinch(at: p, layout: layout) }) else {
                    return false
                }
                lightReadoutClear?.cancel()
                lightPinch = session
                showLightGizmoRadius(of: session.owner, engine, in: view)
                return true
            case .changed:
                guard var session = lightPinch else { return false }
                let interaction = lightGizmoInteraction(engine)
                // NSMagnificationGestureRecognizer counts from 0; the pinch
                // session takes a scale that starts at 1 (SwiftUI's).
                let scale = 1 + Double(gesture.magnification)
                MainActor.assumeIsolated { _ = interaction.pinch(&session, magnification: scale) }
                lightPinch = session
                showLightGizmoRadius(of: session.owner, engine, in: view)
                return true
            case .ended, .cancelled, .failed:
                guard lightPinch != nil else { return false }
                lightPinch = nil
                showLightGizmoRadius(of: nil, engine, in: view)
                return true
            default:
                return lightPinch != nil
            }
        }

        @objc func handleMagnification(_ gesture: NSMagnificationGestureRecognizer) {
            guard !boxSelectActive else { return }   // camera frozen (#358)
            // Lights mode (#622): a pinch that begins over a knob is the light
            // gizmo's (radius); anywhere else, today's zoom.
            if lightGizmoMagnification(gesture) { return }
            switch gesture.state {
            case .began:
                lastMag = 0
            case .changed:
                // Spreading fingers (magnification increasing) = zoom in.
                let delta = gesture.magnification - lastMag
                lastMag = gesture.magnification
                engine?.zoomBy(Float(delta * kZoomGain))
            case .ended, .cancelled:
                lastMag = 0
                // Zoom changed the projection scale → refresh the gizmo hit-test
                // once (guarded to move mode) so a handle grab after zooming is
                // accurate. Not done per .changed tick — that would relag zoom.
                engine?.refreshGizmo()
            default:
                break
            }
        }

        // Trackpad two-finger twist → Z-axis roll, mirroring the iOS handleRotation
        // gesture. Gated on engine.trackpadMode so it never disturbs the classic
        // per-button mouse modes. runPython (not runCommand) to avoid echoing
        // `turn z` into the feedback log every frame.
        @objc func handleRotationGesture(_ gesture: NSRotationGestureRecognizer) {
            guard engine?.trackpadMode == true, !boxSelectActive else { return }
            switch gesture.state {
            case .began:
                lastRoll = 0
            case .changed:
                let delta = gesture.rotation - lastRoll
                lastRoll = gesture.rotation
                let deg = kRollSign * Float(delta) * 180.0 / .pi
                engine?.runPython("from pymol import cmd as _c; _c.turn('z', \(deg))")
            case .ended, .cancelled:
                lastRoll = 0
            default:
                break
            }
        }

        #endif

        // MARK: - iPadOS gesture handling

        #if os(iOS)
        /// A tap at `p` in Lights mode (#622): true when it landed on a light
        /// gizmo target. A knob selects its light (the bar and the inspector
        /// follow); any other target takes the tap with no atom pick. An
        /// option-tap off every target (an iPad hardware keyboard, #623)
        /// places a highlight for the selected light, as a long-press does. A
        /// double-tap on the selected light's aim dot aims it back at the rig
        /// centre (#699).
        private func lightGizmoTap(at p: CGPoint, option: Bool, in view: MTKView) -> Bool {
            guard let engine, engine.interactionMode == .lights,
                  let layout = lightGizmoLayout(in: view) else { return false }
            guard let target = LightGizmoHitTest.target(at: p, layout: layout) else {
                lightAimTaps = LightAimDoubleTap()
                guard option, LightTouchRouter.optionTap(at: p, layout: layout) else { return false }
                let interaction = lightGizmoInteraction(engine)
                _ = MainActor.assumeIsolated { interaction.placeHighlight(at: p, layout: layout) }
                return true
            }
            let selected = MainActor.assumeIsolated { engine.lightsController.selection.name }
            if lightAimTaps.tap(on: target, light: selected, at: p, time: ProcessInfo.processInfo.systemUptime),
               let name = selected {
                let interaction = lightGizmoInteraction(engine)
                _ = MainActor.assumeIsolated { interaction.aimAtCentre(name: name) }
            }
            if case .knob(let name) = target {
                MainActor.assumeIsolated { engine.lightsController.select(name: name) }
            }
            return true
        }

        /// The aim dot's first tap, waiting for a second (#699).
        private var lightAimTaps = LightAimDoubleTap()

        /// A one-finger pan (#622): true when the light gizmo owns it.
        /// UIKit reports `.began` after its own slop, so the press is hit-
        /// tested where the finger came down (`location - translation`); a
        /// hit opens a session and owns the pan to its end, whatever the mode
        /// does meanwhile. A miss keeps today's camera rotation. The pinch
        /// and the long-press on targets are the routines below (#623).
        private func lightGizmoPan(_ gesture: UIPanGestureRecognizer, in view: MTKView,
                                   at location: CGPoint) -> Bool {
            guard let engine else { return false }
            switch gesture.state {
            case .began:
                guard engine.interactionMode == .lights else {
                    if engine.lightGizmoPointer.ownsPress { engine.lightGizmoPointer.cancel() }
                    return false
                }
                let start = LightTouchGeometry.pressPoint(location: location,
                                                          translation: gesture.translation(in: view))
                let layout = lightGizmoLayout(in: view)
                let interaction = lightGizmoInteraction(engine)
                let route = MainActor.assumeIsolated {
                    // A new pan is a new touch sequence.
                    engine.lightGizmoPointer.cancel()
                    return engine.lightGizmoPointer.touchChanged(start: start, at: location, layout: layout,
                                                                 interaction: interaction)
                }
                guard route == .gizmo else { return false }
                showLightGizmoDrag(engine, in: view, at: location)
                return true
            case .changed:
                guard engine.lightGizmoPointer.ownsPress else { return false }
                _ = lightGizmoDrag(to: location, in: view)
                return true
            case .ended, .cancelled, .failed:
                guard engine.lightGizmoPointer.ownsPress else { return false }
                let interaction = lightGizmoInteraction(engine)
                MainActor.assumeIsolated {
                    _ = engine.lightGizmoPointer.touchEnded(at: location, interaction: interaction)
                }
                showLightGizmoDrag(engine, in: view, at: nil)
                return true
            default:
                return engine.lightGizmoPointer.ownsPress
            }
        }

        /// The distance between a recognizer's first two touches (infinity
        /// with fewer).
        private func lightGizmoSpan(_ gesture: UIGestureRecognizer, in view: MTKView) -> CGFloat {
            let n = min(gesture.numberOfTouches, 2)
            return LightTouchGeometry.span((0..<n).map { gesture.location(ofTouch: $0, in: view) })
        }

        /// A two-finger recognizer's share of the sequence (#623): true when
        /// the gizmo owns it, so its camera path (zoom, translate, roll) is
        /// skipped from its `.began` to its end. The first of the family to
        /// begin decides (LightTwoFingerSequence: a knob at `centroid` with
        /// the fingers at most 120 pt apart); the others join that owner.
        /// Outside Lights mode a new sequence is never recorded (today's
        /// camera path), but one the gizmo already owns keeps its owner.
        private func lightGizmoTwoFinger(_ kind: LightTwoFingerKind, _ gesture: UIGestureRecognizer,
                                         at centroid: CGPoint, in view: MTKView) -> Bool {
            guard let engine else { return false }
            switch gesture.state {
            case .began:
                guard engine.interactionMode == .lights || lightTwoFinger.isActive else { return false }
                let layout = lightGizmoLayout(in: view)
                let owner = lightTwoFinger.began(kind, centroid: centroid,
                                                 span: lightGizmoSpan(gesture, in: view)) { p in
                    layout.flatMap { LightGizmoHitTest.knob(at: p, layout: $0) }
                }
                return owner.isGizmo
            case .ended, .cancelled, .failed:
                return lightTwoFinger.ended(kind)?.isGizmo == true
            default:
                return lightTwoFinger.owner(of: kind)?.isGizmo == true
            }
        }

        /// The pinch of a two-finger sequence (#623): when the gizmo owns the
        /// sequence, the pinch opens #621's radius session on the knob the
        /// sequence named (wherever the centroid is by now) and each change
        /// writes the radius through the owner-guarded setter (the 0.5× grid,
        /// the beam kept); true while it is the gizmo's. Otherwise today's
        /// zoom.
        private func lightGizmoPinch(_ gesture: UIPinchGestureRecognizer, in view: MTKView) -> Bool {
            guard let engine else { return false }
            let centroid = gesture.location(in: view)
            switch gesture.state {
            case .began:
                lightPinch = nil
                guard lightGizmoTwoFinger(.pinch, gesture, at: centroid, in: view) else { return false }
                guard case .gizmo(let name)? = lightTwoFinger.owner(of: .pinch) else { return true }
                lightPinchStartScale = gesture.scale > 0 ? gesture.scale : 1
                let interaction = lightGizmoInteraction(engine)
                lightPinch = MainActor.assumeIsolated { interaction.beginPinch(named: name) }
                lightReadoutClear?.cancel()
                showLightGizmoRadius(of: lightPinch?.owner, engine, in: view)
                return true
            case .changed:
                guard lightGizmoTwoFinger(.pinch, gesture, at: centroid, in: view) else { return false }
                guard var session = lightPinch else { return true }
                let interaction = lightGizmoInteraction(engine)
                let scale = Double(gesture.scale / lightPinchStartScale)
                MainActor.assumeIsolated { _ = interaction.pinch(&session, magnification: scale) }
                lightPinch = session
                showLightGizmoRadius(of: session.owner, engine, in: view)
                return true
            case .ended, .cancelled, .failed:
                let owned = lightGizmoTwoFinger(.pinch, gesture, at: centroid, in: view)
                if lightPinch != nil {
                    lightPinch = nil
                    showLightGizmoRadius(of: nil, engine, in: view)
                }
                return owned
            default:
                return lightGizmoTwoFinger(.pinch, gesture, at: centroid, in: view)
            }
        }

        /// May a long-press begin at `p` (the recognizer's delegate, #623)?
        /// In Lights mode, not on a knob, the aim dot or a handle, so press,
        /// hold and drag there still drags the target; anywhere else, and
        /// outside Lights mode, yes.
        private func lightGizmoLongPressMayBegin(at p: CGPoint, in view: MTKView) -> Bool {
            guard let engine, engine.interactionMode == .lights else { return true }
            return LightTouchRouter.shouldBeginLongPress(at: p, layout: lightGizmoLayout(in: view))
        }

        /// A long-press at `p` in Lights mode (#623): true when the gizmo took
        /// it. Off the point targets (a ring line included) it places a
        /// highlight for the selected light (one `lights` command per press);
        /// on a point target it does nothing; with the gizmo hidden it falls
        /// through to today's atom context menu.
        private func lightGizmoLongPress(at p: CGPoint, in view: MTKView) -> Bool {
            guard let engine, engine.interactionMode == .lights else { return false }
            let layout = lightGizmoLayout(in: view)
            let hasSelection = MainActor.assumeIsolated { engine.lightsController.selectedLight != nil }
            switch LightTouchRouter.longPress(at: p, layout: layout, hasSelection: hasSelection) {
            case .contextMenu:
                return false
            case .ignore:
                return true
            case .highlight:
                guard let layout else { return true }
                let interaction = lightGizmoInteraction(engine)
                _ = MainActor.assumeIsolated { interaction.placeHighlight(at: p, layout: layout) }
                return true
            }
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let engine = engine, let view = mtkView else { return }
            // Box Select: taps belong to the box (handlePan resolves them), not
            // to atom picking.
            guard !boxSelectActive else { return }
            // CPU-side pick (metal_pick). Compute NDC in POINT space (not backing
            // pixels) and flip Y: UIKit gesture origin is top-left, PyMOL NDC is
            // bottom-left. (The standard LEFT-click path does NOT select on the
            // Metal backend, so we call the pick directly.)
            let p = gesture.location(in: view)
            let w = view.bounds.width, h = view.bounds.height
            guard w > 0, h > 0 else { return }
            let ndcX = Float(p.x / w) * 2 - 1
            let ndcY = 1 - Float(p.y / h) * 2
            let aspect = Float(w / h)
            // Lights mode (#622): a tap on a light gizmo knob selects that
            // light; a tap on any other gizmo target does nothing (as a macOS
            // click there); an option-tap off every target places a highlight
            // (#623); elsewhere, today's atom pick.
            if lightGizmoTap(at: p, option: gesture.modifierFlags.contains(.alternate), in: view) { return }
            if engine.interactionMode == .move {
                // A tap ALWAYS selects the object under it (grab-what-you-touch).
                // Previously it first hit-tested the gizmo and armed an axis, but
                // the gizmo wraps the whole molecule (rings around it + the center
                // handle on the COM), so tapping the molecule body — the natural
                // place to tap to select — hit a handle and armed it instead of
                // selecting. Handles are manipulated by DRAGGING (handleMovePan),
                // which is unaffected; this makes tap-to-select consistent.
                engine.moveSetActiveAt(ndcX: ndcX, ndcY: ndcY, aspect: aspect)
                return
            }
            #if RAYMOL_MPNN
            if engine.designMode {
                // In Design mode a viewport tap targets a residue, mirroring the
                // macOS long-press path. The tap always TOGGLES that residue in
                // 'sele'; the COUNT of selected residues then decides the mode
                // (1 → pinned, 2+ → region) — see DesignController.syncFromSele.
                engine.designPickResidue(ndcX: ndcX, ndcY: ndcY, aspect: aspect)
                return
            }
            #endif
            if engine.measureMode != nil {
                engine.measurePick(ndcX: ndcX, ndcY: ndcY, aspect: aspect)
            } else {
                engine.pick(ndcX: ndcX, ndcY: ndcY, aspect: aspect)
            }
        }

        // Trackpad / mouse / Apple-Pencil hover (issue #165) → the iPad twin of
        // macOS handleMouseMoved. Fires only for an indirect-pointer hover with
        // nothing held. A sub-pixel move gate skips the re-pick when the pointer
        // barely moved; the engine additionally debounces the Python pick.
        //   • Move mode: highlight the gizmo handle under the pointer (what a drag
        //     would grab) instead of pre-selecting an atom, and reflect Shift
        //     (Magic Keyboard) as adjust-frame mode — mirroring macOS. The gizmo's
        //     cached 2D projection goes stale on any view change since the last
        //     gesture-end, so refresh the hit-test geometry for the CURRENT view
        //     before testing (same as handleMovePan).
        //   • Viewing mode: pre-select the atom under the pointer, computing NDC
        //     EXACTLY like handleTap (top-left origin, Y flipped) so it aligns with
        //     what a tap would select. Suppressed while measuring.
        // .ended/.cancelled (pointer lifted / left the view) clears whatever the
        // hover left behind — atom preview, hovered handle, and Shift-adjust.
        @objc func handleHover(_ gesture: UIHoverGestureRecognizer) {
            guard let engine = engine, let view = mtkView else { return }
            guard !boxSelectActive else { return }   // the box drives the selection
            switch gesture.state {
            case .began, .changed:
                let p = gesture.location(in: view)
                if lastHoverLoc != .zero,
                   hypot(p.x - lastHoverLoc.x, p.y - lastHoverLoc.y) < 2 {
                    return
                }
                lastHoverLoc = p
                if engine.interactionMode == .move {
                    engine.moveShiftHeld = gesture.modifierFlags.contains(.shift)
                    guard let (nx, ny, aspect) = gizmoNDC(in: view, at: p) else { return }
                    engine.refreshGizmo(aspect: aspect)
                    let hit = engine.gizmo?.hitTest(ndc: CGPoint(x: CGFloat(nx), y: CGFloat(ny)),
                                                    aspect: CGFloat(aspect))
                    if engine.hoveredHandle != hit { engine.hoveredHandle = hit }
                    return
                }
                guard engine.measureMode == nil else { return }
                // Lights mode (#619) skips the atom hover pick (see macOS);
                // the light gizmo's hover hit test runs instead (#622).
                if engine.interactionMode == .lights {
                    lightGizmoHover(at: p, in: view)
                    return
                }
                let w = view.bounds.width, h = view.bounds.height
                guard w > 0, h > 0 else { return }
                let ndcX = Float(p.x / w) * 2 - 1
                let ndcY = 1 - Float(p.y / h) * 2
                #if RAYMOL_MPNN
                if engine.designMode {
                    engine.hoverDesignPreview(ndcX, ndcY, Float(w / h))
                } else {
                    engine.hoverPreview(ndcX, ndcY, Float(w / h))
                }
                #else
                engine.hoverPreview(ndcX, ndcY, Float(w / h))
                #endif
            case .ended, .cancelled:
                lastHoverLoc = .zero
                engine.clearHoverPreview()
                if engine.hoveredHandle != nil { engine.hoveredHandle = nil }
                if engine.moveShiftHeld { engine.moveShiftHeld = false }
                lightGizmoHover(at: nil, in: view)   // Lights mode only (#622)
            default:
                break
            }
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let view = mtkView else { return }
            let location = gesture.location(in: view)

            // Box Select: one finger (or the Pencil) draws / adjusts the box.
            if boxSelectActive {
                switch gesture.state {
                case .began:            boxBegin(in: view, at: location)
                case .changed:          boxUpdate(in: view, at: location)
                case .ended, .cancelled: boxEnd(in: view, at: location)
                default: break
                }
                return
            }

            // Lights mode (#622): a pan that starts on a light gizmo target
            // drags it to its end, even if the mode ends meanwhile.
            if lightGizmoPan(gesture, in: view, at: location) { return }

            if engine?.interactionMode == .move {
                handleMovePan(gesture, in: view, at: location)
                return
            }

            let pt = pymolPoint(in: view, at: location)
            switch gesture.state {
            case .began:
                // Single-finger pan = left drag (rotation)
                engine?.button(PYMOL_BUTTON_LEFT, state: PYMOL_BUTTON_DOWN, x: pt.0, y: pt.1, modifiers: 0)
            case .changed:
                engine?.drag(x: pt.0, y: pt.1, modifiers: 0)
            case .ended, .cancelled:
                engine?.button(PYMOL_BUTTON_LEFT, state: PYMOL_BUTTON_UP, x: pt.0, y: pt.1, modifiers: 0)
            default: break
            }
        }

        // One-finger pan in Move mode: if it starts on a gizmo handle (or an axis
        // is armed), drag that handle; otherwise orbit the camera (and keep the
        // gizmo tracking). Pinch/two-finger still zoom/orbit the camera as usual.
        private func handleMovePan(_ gesture: UIPanGestureRecognizer, in view: MTKView, at location: CGPoint) {
            guard let engine = engine, let (nx, ny, aspect) = gizmoNDC(in: view, at: location) else { return }
            switch gesture.state {
            case .began:
                // Re-emit the hit-test geometry for the CURRENT view before the
                // grab. iOS has no hover to keep the cache fresh, so a view change
                // since the last gesture-end (pinch/orbit, or an external change:
                // camera dock, Scene ops, movie playback) would otherwise leave the
                // cached projection stale and grab the wrong handle. Cheap: once per
                // gesture, republished only if the projection actually moved.
                engine.refreshGizmo(aspect: aspect)
                // #702: UIKit reports .began after its pan slop, so hit-test and
                // grab where the finger came down, not where it is now: the
                // handle under the touch-down point is the one dragged.
                let press = LightTouchGeometry.pressPoint(location: location,
                                                          translation: gesture.translation(in: view))
                let (px, py, _) = gizmoNDC(in: view, at: press) ?? (nx, ny, aspect)
                var handle = engine.gizmo?.hitTest(ndc: CGPoint(x: CGFloat(px), y: CGFloat(py)),
                                                   aspect: CGFloat(aspect))
                if handle == nil { handle = engine.armedAxis }  // armed-axis drag
                panMoveHandle = handle
                if let hnd = handle {
                    engine.gizmoBeginDrag(hnd, ndcX: px, ndcY: py, aspect: aspect)
                } else {
                    let pt = pymolPoint(in: view, at: location)
                    engine.button(PYMOL_BUTTON_LEFT, state: PYMOL_BUTTON_DOWN, x: pt.0, y: pt.1, modifiers: 0)
                }
            case .changed:
                if panMoveHandle != nil {
                    engine.gizmoUpdateDrag(ndcX: nx, ndcY: ny, aspect: aspect)
                } else {
                    // Orbit: the 3D CGO gizmo tracks the camera on render, so skip the
                    // per-tick hit-test refresh (Python + file I/O) that made orbiting
                    // laggy; it's refreshed on .ended for the next tap/drag.
                    let pt = pymolPoint(in: view, at: location)
                    engine.drag(x: pt.0, y: pt.1, modifiers: 0)
                }
            case .ended, .cancelled:
                if panMoveHandle != nil {
                    engine.gizmoEndDrag()
                    panMoveHandle = nil
                } else {
                    let pt = pymolPoint(in: view, at: location)
                    engine.button(PYMOL_BUTTON_LEFT, state: PYMOL_BUTTON_UP, x: pt.0, y: pt.1, modifiers: 0)
                    engine.refreshGizmo(aspect: aspect)
                }
            default: break
            }
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard !boxSelectActive else { return }   // camera frozen (#358)
            // Lights mode (#623): a pinch whose two-finger sequence began on a
            // knob sets that light's radius; anywhere else, today's zoom.
            if let view = mtkView, lightGizmoPinch(gesture, in: view) { return }
            // Pinch → zoom via explicit dolly. gesture.scale is cumulative (1.0
            // at start); feed its per-callback change as a zoom fraction (NOT
            // velocity, which fired erratically and only once).
            switch gesture.state {
            case .began:
                pinchLastScale = 1.0
            case .changed:
                let delta = gesture.scale - pinchLastScale
                pinchLastScale = gesture.scale
                engine?.zoomBy(Float(delta * kZoomGain))
            case .ended, .cancelled:
                pinchLastScale = 1.0
                // Zoom changed the projection scale → refresh the gizmo hit-test
                // once (guarded to move mode) so a handle grab after zooming is
                // accurate. Not done per .changed tick — that would relag zoom.
                engine?.refreshGizmo()
            default:
                break
            }
        }

        // Two-finger drag = TRANSLATE (middle-drag). The centroid is fed to
        // PyMOL as the drag cursor so the molecule follows the fingers.
        //
        // Y MUST be flipped to PyMOL's bottom-up window convention. PyMOL's
        // cButModeTransXY (SceneMouse.cpp) translates the scene by +(y-LastY):
        // for grab-and-move (finger up -> molecule up) the window y has to
        // INCREASE going up. UIKit is top-down (y increases going DOWN), and the
        // iOS pymolPoint does not flip, so raw coords invert vertical translate.
        // Flipping the location here (height - y) restores the correct sign.
        // (handleTap already flips Y the same way for picking; macOS gets this
        // for free because NSView is bottom-up.)
        @objc func handleTwoFingerPan(_ gesture: UIPanGestureRecognizer) {
            guard let view = mtkView, !boxSelectActive else { return }   // camera frozen (#358)
            let loc = gesture.location(in: view)
            // Lights mode (#623): a sequence the gizmo owns (a pinch on a knob)
            // sends no button-down and so no button-up: the camera stays put.
            // The pan decides where its fingers came down.
            let press = LightTouchGeometry.pressPoint(location: loc, translation: gesture.translation(in: view))
            if lightGizmoTwoFinger(.pan, gesture, at: press, in: view) { return }
            let pt = pymolPoint(in: view, at: CGPoint(x: loc.x, y: view.bounds.height - loc.y))
            switch gesture.state {
            case .began:
                lastDragPt = pt
                engine?.button(PYMOL_BUTTON_MIDDLE, state: PYMOL_BUTTON_DOWN, x: pt.0, y: pt.1, modifiers: 0)
            case .changed:
                // Once a finger lifts, the recognizer's centroid jumps to the
                // remaining finger; that jumped drag would translate the scene
                // (the "jump on release"). Only feed drags with both fingers down.
                guard gesture.numberOfTouches >= 2 else { break }
                lastDragPt = pt
                engine?.drag(x: pt.0, y: pt.1, modifiers: 0)
            case .ended, .cancelled:
                // Release at the LAST dragged point, not the (possibly jumped)
                // end centroid — see lastDragPt. Avoids the "jump on release".
                let up = lastDragPt ?? pt
                engine?.button(PYMOL_BUTTON_MIDDLE, state: PYMOL_BUTTON_UP, x: up.0, y: up.1, modifiers: 0)
                lastDragPt = nil
            default:
                break
            }
        }

        @objc func handleRotation(_ gesture: UIRotationGestureRecognizer) {
            guard !boxSelectActive else { return }   // camera frozen (#358)
            // Lights mode (#623): the twist of a sequence the gizmo owns (a
            // pinch on a knob) runs nothing.
            if let view = mtkView, lightGizmoTwoFinger(.rotation, gesture, at: gesture.location(in: view), in: view) {
                return
            }
            // Two-finger rotation → Z-axis roll (`turn z`). Per-callback delta of
            // the cumulative gesture.rotation, in degrees. runPython (not run-
            // Command) to avoid echoing into the log every frame.
            switch gesture.state {
            case .began:
                lastRotation = 0
            case .changed:
                let delta = gesture.rotation - lastRotation
                lastRotation = gesture.rotation
                let deg = kRollSign * Float(delta) * 180.0 / .pi
                engine?.runPython("from pymol import cmd as _c; _c.turn('z', \(deg))")
            case .ended, .cancelled:
                lastRotation = 0
            default:
                break
            }
        }

        // Three-finger drag → CLIP. Synthesizes a Shift+Right-button drag, which
        // PyMOL's three_button_viewing binds to 'clip' (vertical = move slab,
        // horizontal = thickness) — the same interaction as the macOS Shift+two-
        // finger trackpad gesture (touch has no Shift, so a 3-finger drag is the
        // iPad idiom). The centroid feeds PyMOL's drag cursor.
        @objc func handleClip(_ gesture: UIPanGestureRecognizer) {
            guard let view = mtkView, !boxSelectActive else { return }   // camera frozen (#358)
            let pt = pymolPoint(in: view, at: gesture.location(in: view))
            let s = PYMOL_MOD_SHIFT
            switch gesture.state {
            case .began:
                clipAnchorX = pt.0       // hold X fixed → near-plane (front) clip only
                lastDragPt = pt
                engine?.button(PYMOL_BUTTON_RIGHT, state: PYMOL_BUTTON_DOWN, x: pt.0, y: pt.1, modifiers: s)
            case .changed:
                // Only feed drags while all three fingers are down (same
                // uneven-lift centroid-jump guard as the translate handler).
                guard gesture.numberOfTouches >= 3 else { break }
                let x = clipAnchorX ?? pt.0
                lastDragPt = (x, pt.1)
                engine?.drag(x: x, y: pt.1, modifiers: s)
            case .ended, .cancelled:
                // Release at the last dragged point — same uneven-lift jump fix
                // as the translate handler (see lastDragPt).
                let up = lastDragPt ?? pt
                engine?.button(PYMOL_BUTTON_RIGHT, state: PYMOL_BUTTON_UP, x: up.0, y: up.1, modifiers: s)
                lastDragPt = nil
                clipAnchorX = nil
            default:
                break
            }
        }

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, let engine = engine, let view = mtkView else { return }
            // No long-press context menu in Move mode — the gizmo owns the
            // gestures there, and the Scene menu (Reset view / Deselect all) just
            // interferes with dragging handles.
            guard engine.interactionMode != .move, !boxSelectActive else { return }
            // Identify the atom/residue under the press and let ContentView show
            // a native context menu. NDC in point space with Y flipped (same as
            // handleTap). This replaces the old right-click, which fired a PyMOL
            // pop-up menu that this Metal backend never renders (internal_gui=0)
            // — so long-press used to do nothing visible.
            let p = gesture.location(in: view)
            // Lights mode (#623): a highlight for the selected light off the
            // point targets; the context menu only while the gizmo is hidden.
            if lightGizmoLongPress(at: p, in: view) { return }
            let w = view.bounds.width, h = view.bounds.height
            guard w > 0, h > 0 else { return }
            let ndcX = Float(p.x / w) * 2 - 1
            let ndcY = 1 - Float(p.y / h) * 2
            engine.longPressPick(ndcX: ndcX, ndcY: ndcY, aspect: Float(w / h))
        }
        #endif
    }
}

#if os(iOS)
// Allow pinch (zoom), the two-finger pan (translate), and two-finger rotation
// (Z-roll) to fire together, so one continuous two-finger gesture moves + zooms
// + rolls the structure (the standard touch idiom).
extension MetalViewport.Coordinator: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // The two-finger family — pinch (zoom), the 2-finger pan (translate), and
        // rotation (Z-roll) — all compose into one continuous gesture. One-finger
        // rotate and the 3-finger clip pan stay exclusive (don't match below).
        func isTwoFinger(_ gr: UIGestureRecognizer) -> Bool {
            if gr is UIPinchGestureRecognizer || gr is UIRotationGestureRecognizer { return true }
            if let p = gr as? UIPanGestureRecognizer { return p.maximumNumberOfTouches == 2 }
            return false
        }
        return isTwoFinger(g) && isTwoFinger(other)
    }

    // Lights mode (#623): a long-press never begins on a light gizmo knob, aim
    // dot or handle (press, hold and drag there drags the target); every
    // other recognizer, and a long-press anywhere else or outside Lights
    // mode, begins as before.
    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard g is UILongPressGestureRecognizer, let view = mtkView else { return true }
        return lightGizmoLongPressMayBegin(at: g.location(in: view), in: view)
    }
}
#endif
