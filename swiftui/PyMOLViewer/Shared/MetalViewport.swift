// MetalViewport.swift — Cross-platform MTKView wrapper for SwiftUI
// Uses NSViewRepresentable on macOS, UIViewRepresentable on iPadOS.

import SwiftUI
import MetalKit
#if canImport(UIKit)
import UIKit
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
        // costs a cheap idle poll when nothing is moving.
        view.preferredFramesPerSecond = 120
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        context.coordinator.engine = engine
        context.coordinator.mtkView = view
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
    // (they don't require first-responder status). Trade-off: single-key PyMOL
    // shortcuts routed through keyDown -> handleKeyDown no longer fire while the
    // command line holds focus; RayMol is command-line/UI-driven, so keeping the
    // prompt focused is the intended behavior.
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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
    override func keyDown(with event: NSEvent) {
        coordinator?.handleKeyDown(event, in: self)
    }
}

#elseif os(iOS)
struct MetalViewport: UIViewRepresentable {
    @EnvironmentObject var engine: PyMOLEngine

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero)
        view.device = MTLCreateSystemDefaultDevice()
        view.delegate = context.coordinator
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float_stencil8
        // Allow ProMotion (120Hz) on capable displays; the system clamps this to
        // the panel's actual max (e.g. 60 on non-ProMotion). The on-demand gate in
        // draw(in:) keeps the GPU idle on a static scene, so the higher tick only
        // costs a cheap idle poll when nothing is moving.
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

        view.addGestureRecognizer(tap)
        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(twoPan)
        view.addGestureRecognizer(clipPan)
        view.addGestureRecognizer(pinch)
        view.addGestureRecognizer(rotation)
        view.addGestureRecognizer(longPress)

        // TODO(#165, iPad hover follow-up): add a UIHoverGestureRecognizer here
        // (target: coordinator) so a trackpad/Apple-Pencil-hover on iPadOS drives
        // the same hover pre-selection preview as macOS mouseMoved. Its .changed
        // handler would compute NDC exactly like handleTap and call
        // engine.hoverPreview(...); .ended would call engine.clearHoverPreview().
        // Deferred: touch has no persistent cursor, so this only helps the
        // pointer/pencil-hover case and needs its own gate against tap/drag.

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
        #endif

        // MARK: - MTKViewDelegate

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            viewportSize = size
            engine?.viewportPixelSize = size
            engine?.reshape(width: Int(size.width), height: Int(size.height))
        }

        private var wasSuppressed = false
        private var hasRenderedOnce = false

        func draw(in view: MTKView) {
            guard let engine = engine, engine.isReady else { return }
            // A movie export renders frames off the main thread and owns the core
            // exclusively (it reshapes global state per frame). Skip the live
            // render meanwhile so we never race it; the exporter restores the
            // scene + clears this flag when done, and the next tick redraws. (#58 L-59)
            if engine.exportRenderActive { return }
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
            // then hand off this frame's drawable + pass descriptor and render.
            engine.setupMetalRenderer(view: view)
            engine.idle()
            // On-demand rendering: after idle() (which advances movies/animations
            // and sets PyMOL's redisplay flag), skip the GPU-expensive frame when
            // nothing needs redrawing — a static structure then costs only a cheap
            // idle poll instead of a full render every tick, the bulk of the
            // battery/thermal win. The last presented frame stays on screen.
            // Mirrors the legacy AppKit loop (main_appkit.mm). The first frame
            // always renders (defensive against a blank start before any redisplay).
            // forceRedraw bypasses the gate after a wake/activate: the display can
            // discard the drawable's contents during sleep, and since the scene is
            // unchanged the redisplay flag alone wouldn't repaint it (-> a black
            // viewport until the next interaction). It's cleared only once a frame
            // actually renders below, so a not-yet-ready drawable doesn't drop it.
            if !forceRedraw, hasRenderedOnce, let inst = engine.instance,
               PyMOLBridge_GetRedisplay(inst, 1) == 0 {
                return
            }
            guard let drawable = view.currentDrawable,
                  let passDesc = view.currentRenderPassDescriptor else { return }
            let size = view.drawableSize
            engine.renderMetalFrame(drawable: drawable, passDescriptor: passDesc,
                                    width: Int(size.width), height: Int(size.height))
            hasRenderedOnce = true
            forceRedraw = false
            // This frame built any deferred rep geometry (e.g. a surface mesh);
            // let the engine clear the "Calculating…" overlay once the build
            // frame(s) have completed.
            engine.heavyRenderTick()
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

        // The gizmo handle under a view point (Move mode only), or nil.
        private func gizmoHit(in view: MTKView, at p: CGPoint) -> GizmoHandle? {
            guard let g = engine?.gizmo, let (nx, ny, aspect) = gizmoNDC(in: view, at: p) else { return nil }
            return g.hitTest(ndc: CGPoint(x: CGFloat(nx), y: CGFloat(ny)), aspect: CGFloat(aspect))
        }

        // MARK: - macOS mouse handling

        #if os(macOS)
        func handleMouseDown(_ event: NSEvent, in view: MTKView) {
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
            // Move mode: remember whether the press landed on a gizmo handle, so
            // the drag manipulates the object; otherwise the drag orbits the camera.
            moveHandle = nil
            if engine?.interactionMode == .move {
                // Shift → adjust-frame mode for this drag (re-anchor the gizmo).
                engine?.moveShiftHeld = event.modifierFlags.contains(.shift)
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
            guard !didDrag else { return }
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
                let hit = gizmoHit(in: view, at: loc)
                if engine?.hoveredHandle != hit { engine?.hoveredHandle = hit }
                return
            }
            guard engine?.measureMode == nil else { return }
            let w = view.bounds.width, h = view.bounds.height
            guard w > 0, h > 0 else { return }
            let ndcX = Float(loc.x / w) * 2 - 1
            let ndcY = Float(loc.y / h) * 2 - 1
            engine?.hoverPreview(ndcX, ndcY, Float(w / h))
        }

        // Pointer left the viewport → clear the preview so it doesn't linger.
        func handleMouseExited(_ event: NSEvent, in view: MTKView) {
            lastHoverLoc = .zero
            engine?.clearHoverPreview()
            if engine?.hoveredHandle != nil { engine?.hoveredHandle = nil }
            // Drop Shift adjust-mode when the pointer leaves, so the gizmo doesn't
            // stay greyed if Shift is released outside the viewport.
            if engine?.moveShiftHeld == true { engine?.moveShiftHeld = false }
        }

        func handleMouseUp(_ event: NSEvent, in view: MTKView) {
            // Clear the drag flag on exit so passive hover (which is gated on
            // !didDrag) resumes immediately after a drag, not only after the next
            // mouse-down.
            defer { didDrag = false }
            let loc = view.convert(event.locationInWindow, from: nil)
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
            // Defer PyMOL's button-down: raising it here would immediately enter
            // clip mode, and PyMOL's own pop-up menu is never rendered under this
            // Metal backend (internal_gui=0). A bare right-click instead pops the
            // native SwiftUI context menu in handleRightMouseUp; a right-DRAG
            // starts the clip on first movement (handleRightMouseDragged).
            rightDownLoc = view.convert(event.locationInWindow, from: nil)
            rightDidDrag = false
        }

        func handleRightMouseUp(_ event: NSEvent, in view: MTKView) {
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
            let pt = pymolPoint(in: view, at: view.convert(event.locationInWindow, from: nil))
            let mods = pymolModifiers(event.modifierFlags.rawValue)
            engine?.button(PYMOL_BUTTON_MIDDLE, state: PYMOL_BUTTON_DOWN, x: pt.0, y: pt.1, modifiers: mods)
        }

        func handleOtherMouseUp(_ event: NSEvent, in view: MTKView) {
            let pt = pymolPoint(in: view, at: view.convert(event.locationInWindow, from: nil))
            let mods = pymolModifiers(event.modifierFlags.rawValue)
            engine?.button(PYMOL_BUTTON_MIDDLE, state: PYMOL_BUTTON_UP, x: pt.0, y: pt.1, modifiers: mods)
        }

        func handleOtherMouseDragged(_ event: NSEvent, in view: MTKView) {
            let pt = pymolPoint(in: view, at: view.convert(event.locationInWindow, from: nil))
            let mods = pymolModifiers(event.modifierFlags.rawValue)
            engine?.drag(x: pt.0, y: pt.1, modifiers: mods)
        }

        func handleScrollWheel(_ event: NSEvent, in view: MTKView) {
            let loc = view.convert(event.locationInWindow, from: nil)
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
            // A two-finger pan is a scene translation, so the 3D gizmo CGO moved on
            // screen while its cached 2D hit-test geometry (engine.gizmo) did not.
            // Re-emit it so a hover/grab after panning maps to the handle the user
            // now sees. Matches the refresh already done on orbit mouseUp and
            // pinch-end; no-op outside Move mode. (Clip drags don't move the gizmo,
            // but the refresh is harmless and this is the shared settle point.)
            engine?.refreshGizmo()
        }

        @objc func handleMagnification(_ gesture: NSMagnificationGestureRecognizer) {
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
            guard engine?.trackpadMode == true else { return }
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
                // The Z-roll rotated the view, so the gizmo moved on screen; resync
                // its cached hit-test geometry (no-op outside Move mode).
                engine?.refreshGizmo()
            default:
                break
            }
        }

        func handleKeyDown(_ event: NSEvent, in view: MTKView) {
            guard let chars = event.characters, let firstChar = chars.first else { return }
            let mods = pymolModifiers(event.modifierFlags.rawValue)
            engine?.key(UInt8(firstChar.asciiValue ?? 0), x: 0, y: 0, modifiers: mods)
        }
        #endif

        // MARK: - iPadOS gesture handling

        #if os(iOS)
        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let engine = engine, let view = mtkView else { return }
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
            if engine.measureMode != nil {
                engine.measurePick(ndcX: ndcX, ndcY: ndcY, aspect: aspect)
            } else {
                engine.pick(ndcX: ndcX, ndcY: ndcY, aspect: aspect)
            }
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let view = mtkView else { return }
            let location = gesture.location(in: view)

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
                var handle = engine.gizmo?.hitTest(ndc: CGPoint(x: CGFloat(nx), y: CGFloat(ny)),
                                                   aspect: CGFloat(aspect))
                if handle == nil { handle = engine.armedAxis }  // armed-axis drag
                panMoveHandle = handle
                if let hnd = handle {
                    engine.gizmoBeginDrag(hnd, ndcX: nx, ndcY: ny, aspect: aspect)
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
            guard let view = mtkView else { return }
            let loc = gesture.location(in: view)
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
            guard let view = mtkView else { return }
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
            guard engine.interactionMode != .move else { return }
            // Identify the atom/residue under the press and let ContentView show
            // a native context menu. NDC in point space with Y flipped (same as
            // handleTap). This replaces the old right-click, which fired a PyMOL
            // pop-up menu that this Metal backend never renders (internal_gui=0)
            // — so long-press used to do nothing visible.
            let p = gesture.location(in: view)
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
}
#endif
