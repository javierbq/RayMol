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
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        context.coordinator.engine = engine
        context.coordinator.mtkView = view
        // Back-reference so the view's NSEvent overrides can reach the
        // coordinator's input handlers. Without this, mouseDown/Dragged/etc.
        // call `coordinator?.handle...` on a nil coordinator and silently
        // no-op — mouse rotate/zoom/pan never reach PyMOL.
        view.coordinator = context.coordinator

        // Trackpad pinch → zoom. Two-finger drag (scrollWheel) → translate;
        // see handleScrollWheel. A real mouse wheel still zooms.
        let magnify = NSMagnificationGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleMagnification(_:)))
        view.addGestureRecognizer(magnify)
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }
}

// Custom MTKView subclass to handle mouse/keyboard events on macOS
class PyMOLMTKView: MTKView {
    weak var coordinator: MetalViewport.Coordinator?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.isMultipleTouchEnabled = true
        context.coordinator.engine = engine
        context.coordinator.mtkView = view

        // Gesture recognizers for touch input
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        let twoPan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTwoFingerPan(_:)))
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        let rotation = UIRotationGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleRotation(_:)))
        let longPress = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))

        // One finger rotates; two fingers translate. Pinch (zoom) and the
        // two-finger pan (translate) must recognize simultaneously so you can
        // zoom and slide at once — that's the "pinch-and-zoom with translation".
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        twoPan.minimumNumberOfTouches = 2
        twoPan.maximumNumberOfTouches = 2
        twoPan.delegate = context.coordinator
        pinch.delegate = context.coordinator

        view.addGestureRecognizer(tap)
        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(twoPan)
        view.addGestureRecognizer(pinch)
        view.addGestureRecognizer(rotation)
        view.addGestureRecognizer(longPress)

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
        #if os(macOS)
        // Track the mouse-down point to distinguish a click (pick/select) from
        // a drag (rotate). Point space, view coordinates.
        private var mouseDownLoc: CGPoint = .zero
        private var didDrag = false

        // Trackpad pinch (NSMagnificationGestureRecognizer) → zoom via an
        // explicit camera dolly (engine.zoomBy). We can't use the scroll-wheel
        // BUTTON path: PyMOL's default three_button_viewing binds the bare wheel
        // to 'slab' (clip), so it would change the slab, not zoom. magnification
        // is cumulative from gesture start; feed the per-callback delta as a
        // zoom fraction (spread = positive = zoom in).
        private var lastMag: CGFloat = 0
        private let kZoomGain: CGFloat = 1.0

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
        #endif

        #if os(iOS)
        // Pinch → zoom via explicit camera dolly (engine.zoomBy), not the wheel
        // BUTTON path (which maps to 'slab'). Feed the per-callback change in the
        // cumulative gesture.scale as a zoom fraction.
        private var pinchLastScale: CGFloat = 1.0
        private let kZoomGain: CGFloat = 1.0
        #endif

        // MARK: - MTKViewDelegate

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            viewportSize = size
            engine?.viewportPixelSize = size
            engine?.reshape(width: Int(size.width), height: Int(size.height))
        }

        func draw(in view: MTKView) {
            guard let engine = engine, engine.isReady else { return }
            // Build RendererMetal on the first frame (bridge no-ops thereafter),
            // then hand off this frame's drawable + pass descriptor and render.
            engine.setupMetalRenderer(view: view)
            guard let drawable = view.currentDrawable,
                  let passDesc = view.currentRenderPassDescriptor else { return }
            engine.idle()
            let size = view.drawableSize
            engine.renderMetalFrame(drawable: drawable, passDescriptor: passDesc,
                                    width: Int(size.width), height: Int(size.height))
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

        // MARK: - macOS mouse handling

        #if os(macOS)
        func handleMouseDown(_ event: NSEvent, in view: MTKView) {
            // Don't send PyMOL a button-down yet: a left-click in PyMOL's
            // viewing mode runs SceneClick/Release, whose GL pick is dead on
            // Metal and ends up CLEARING the active selection. We only want
            // PyMOL's mouse handling for an actual drag (rotate), so the
            // button-down is deferred to the first drag event (below). A pure
            // click selects via metal_pick in mouseUp instead.
            mouseDownLoc = view.convert(event.locationInWindow, from: nil)
            didDrag = false
        }

        func handleMouseUp(_ event: NSEvent, in view: MTKView) {
            let loc = view.convert(event.locationInWindow, from: nil)
            let mods = pymolModifiers(event.modifierFlags.rawValue)
            let moved = hypot(loc.x - mouseDownLoc.x, loc.y - mouseDownLoc.y)

            if didDrag {
                // Finish the rotate drag.
                let pt = pymolPoint(in: view, at: loc)
                engine?.button(PYMOL_BUTTON_LEFT, state: PYMOL_BUTTON_UP, x: pt.0, y: pt.1, modifiers: mods)
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
                    engine?.pick(ndcX: ndcX, ndcY: ndcY, aspect: Float(w / h))
                }
            }
        }

        func handleMouseDragged(_ event: NSEvent, in view: MTKView) {
            let loc = view.convert(event.locationInWindow, from: nil)
            let mods = pymolModifiers(event.modifierFlags.rawValue)
            if !didDrag {
                // First movement: now send the button-down (at the press point)
                // so PyMOL enters rotate mode for this drag.
                didDrag = true
                let down = pymolPoint(in: view, at: mouseDownLoc)
                engine?.button(PYMOL_BUTTON_LEFT, state: PYMOL_BUTTON_DOWN, x: down.0, y: down.1, modifiers: mods)
            }
            let pt = pymolPoint(in: view, at: loc)
            engine?.drag(x: pt.0, y: pt.1, modifiers: mods)
        }

        func handleRightMouseDown(_ event: NSEvent, in view: MTKView) {
            let pt = pymolPoint(in: view, at: view.convert(event.locationInWindow, from: nil))
            let mods = pymolModifiers(event.modifierFlags.rawValue)
            engine?.button(PYMOL_BUTTON_RIGHT, state: PYMOL_BUTTON_DOWN, x: pt.0, y: pt.1, modifiers: mods)
        }

        func handleRightMouseUp(_ event: NSEvent, in view: MTKView) {
            let pt = pymolPoint(in: view, at: view.convert(event.locationInWindow, from: nil))
            let mods = pymolModifiers(event.modifierFlags.rawValue)
            engine?.button(PYMOL_BUTTON_RIGHT, state: PYMOL_BUTTON_UP, x: pt.0, y: pt.1, modifiers: mods)
        }

        func handleRightMouseDragged(_ event: NSEvent, in view: MTKView) {
            let pt = pymolPoint(in: view, at: view.convert(event.locationInWindow, from: nil))
            let mods = pymolModifiers(event.modifierFlags.rawValue)
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

            // Trackpad two-finger drag → translate (middle-drag).
            let scale = view.window?.backingScaleFactor ?? 2.0
            let dx = Int32((event.scrollingDeltaX * scale * kPanSignX).rounded())
            let dy = Int32((event.scrollingDeltaY * scale * kPanSignY).rounded())

            // Start the synthetic middle-drag. Real trackpad gestures begin with
            // phase == .began; synthetic/no-phase precise scrolls (and momentum
            // that arrives without a prior .began) start on first delta.
            if !panActive && (phase == .began || (phase == [] && momentum != .ended)) {
                panActive = true
                panCursorX = pt.0
                panCursorY = pt.1
                engine?.button(PYMOL_BUTTON_MIDDLE, state: PYMOL_BUTTON_DOWN,
                               x: panCursorX, y: panCursorY, modifiers: mods)
            }

            if panActive && (dx != 0 || dy != 0) {
                // macOS views are bottom-left origin (matching PyMOL); a finger
                // moving up has positive scrollingDeltaY, so add directly.
                panCursorX += dx
                panCursorY += dy
                engine?.drag(x: panCursorX, y: panCursorY, modifiers: mods)
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
            engine?.button(PYMOL_BUTTON_MIDDLE, state: PYMOL_BUTTON_UP,
                           x: panCursorX, y: panCursorY, modifiers: 0)
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
            engine.pick(ndcX: ndcX, ndcY: ndcY, aspect: Float(w / h))
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let view = mtkView else { return }
            let location = gesture.location(in: view)
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
            default:
                break
            }
        }

        // Two-finger drag → translate (middle-drag). The pan centroid is fed
        // straight to PyMOL as the drag cursor, so the molecule follows the
        // fingers. Recognizes simultaneously with pinch (see makeUIView).
        @objc func handleTwoFingerPan(_ gesture: UIPanGestureRecognizer) {
            guard let view = mtkView else { return }
            let pt = pymolPoint(in: view, at: gesture.location(in: view))
            switch gesture.state {
            case .began:
                engine?.button(PYMOL_BUTTON_MIDDLE, state: PYMOL_BUTTON_DOWN, x: pt.0, y: pt.1, modifiers: 0)
            case .changed:
                engine?.drag(x: pt.0, y: pt.1, modifiers: 0)
            case .ended, .cancelled:
                engine?.button(PYMOL_BUTTON_MIDDLE, state: PYMOL_BUTTON_UP, x: pt.0, y: pt.1, modifiers: 0)
            default:
                break
            }
        }

        @objc func handleRotation(_ gesture: UIRotationGestureRecognizer) {
            // Two-finger rotation = Z-axis rotation
            // Could map to middle-drag with shift modifier
        }

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard let view = mtkView else { return }
            let location = gesture.location(in: view)
            let pt = pymolPoint(in: view, at: location)

            if gesture.state == .began {
                // Long press = right click (context menu / translate)
                engine?.button(PYMOL_BUTTON_RIGHT, state: PYMOL_BUTTON_DOWN, x: pt.0, y: pt.1, modifiers: 0)
            } else if gesture.state == .ended || gesture.state == .cancelled {
                engine?.button(PYMOL_BUTTON_RIGHT, state: PYMOL_BUTTON_UP, x: pt.0, y: pt.1, modifiers: 0)
            }
        }
        #endif
    }
}

#if os(iOS)
// Allow pinch (zoom) and the two-finger pan (translate) to fire together, so
// the user can zoom and slide in one continuous two-finger gesture.
extension MetalViewport.Coordinator: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        let pinchPan = (g is UIPinchGestureRecognizer && other is UIPanGestureRecognizer)
            || (g is UIPanGestureRecognizer && other is UIPinchGestureRecognizer)
        return pinchPan
    }
}
#endif
