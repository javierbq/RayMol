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
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        let rotation = UIRotationGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleRotation(_:)))
        let longPress = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))

        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1

        view.addGestureRecognizer(tap)
        view.addGestureRecognizer(pan)
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

        // MARK: - MTKViewDelegate

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            viewportSize = size
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
            let pt = pymolPoint(in: view, at: view.convert(event.locationInWindow, from: nil))
            let mods = pymolModifiers(event.modifierFlags.rawValue)
            engine?.button(PYMOL_BUTTON_LEFT, state: PYMOL_BUTTON_DOWN, x: pt.0, y: pt.1, modifiers: mods)
        }

        func handleMouseUp(_ event: NSEvent, in view: MTKView) {
            let pt = pymolPoint(in: view, at: view.convert(event.locationInWindow, from: nil))
            let mods = pymolModifiers(event.modifierFlags.rawValue)
            engine?.button(PYMOL_BUTTON_LEFT, state: PYMOL_BUTTON_UP, x: pt.0, y: pt.1, modifiers: mods)
        }

        func handleMouseDragged(_ event: NSEvent, in view: MTKView) {
            let pt = pymolPoint(in: view, at: view.convert(event.locationInWindow, from: nil))
            let mods = pymolModifiers(event.modifierFlags.rawValue)
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
            let pt = pymolPoint(in: view, at: view.convert(event.locationInWindow, from: nil))
            let mods = pymolModifiers(event.modifierFlags.rawValue)
            let btn: Int32 = event.deltaY > 0 ? PYMOL_BUTTON_SCROLL_FORWARD : PYMOL_BUTTON_SCROLL_REVERSE
            engine?.button(btn, state: PYMOL_BUTTON_DOWN, x: pt.0, y: pt.1, modifiers: mods)
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
            guard let view = mtkView else { return }
            let location = gesture.location(in: view)
            let pt = pymolPoint(in: view, at: location)
            // Tap = left click down + up
            engine?.button(PYMOL_BUTTON_LEFT, state: PYMOL_BUTTON_DOWN, x: pt.0, y: pt.1, modifiers: 0)
            engine?.button(PYMOL_BUTTON_LEFT, state: PYMOL_BUTTON_UP, x: pt.0, y: pt.1, modifiers: 0)
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
            guard let view = mtkView else { return }
            let center = gesture.location(in: view)
            let pt = pymolPoint(in: view, at: center)

            // Pinch = scroll wheel (zoom)
            if gesture.state == .changed {
                let btn: Int32 = gesture.velocity > 0 ? PYMOL_BUTTON_SCROLL_FORWARD : PYMOL_BUTTON_SCROLL_REVERSE
                engine?.button(btn, state: PYMOL_BUTTON_DOWN, x: pt.0, y: pt.1, modifiers: 0)
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
