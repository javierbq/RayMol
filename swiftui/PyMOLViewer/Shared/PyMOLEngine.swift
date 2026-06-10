// PyMOLEngine.swift — Singleton managing the PyMOL instance lifecycle
// Wraps the C bridge API and publishes observable state for SwiftUI views.

import Foundation
import Combine
import MetalKit

final class PyMOLEngine: ObservableObject {
    static let shared = PyMOLEngine()

    // Published state for UI binding
    @Published var feedbackLog: [String] = []
    @Published var objects: [MoleculeObject] = []
    @Published var isReady = false
    @Published var sequenceVisible = false

    // The opaque PyMOL instance pointer
    private(set) var instance: PyMOLHandle?

    private var feedbackTimer: Timer?

    private init() {}

    // MARK: - Lifecycle

    func initialize(resourcePath: String) {
        guard instance == nil else { return }

        instance = PyMOLBridge_New()
        guard let inst = instance else { return }

        PyMOLBridge_InitPython(inst, resourcePath)
        PyMOLBridge_Start(inst)

        isReady = true

        // Test affordance (no-op unless env var set): auto-load a bundled
        // structure so a screenshot has content without UI typing.
        if let f = ProcessInfo.processInfo.environment["PYMOL_AUTOLOAD"] {
            let name = (f as NSString).deletingPathExtension
            let ext = (f as NSString).pathExtension
            if let path = Bundle.main.path(forResource: name, ofType: ext) {
                runCommand("load \(path), mol")
                runCommand("hide everything")
                runCommand("show cartoon")
                runCommand("orient")
            }
        }

        // Test affordance: pick at an NDC point ("x,y") and record the selection
        // size to a file for verification (no-op unless env var set).
        if let s = ProcessInfo.processInfo.environment["PYMOL_AUTOPICK"] {
            let parts = s.split(separator: ",").compactMap { Float($0) }
            if parts.count == 2 {
                pick(ndcX: parts[0], ndcY: parts[1], aspect: 1.0)
                runPython("import os; from pymol import cmd; open(os.path.join(os.environ.get('TMPDIR','/tmp'),'pymol_pick.txt'),'w').write('selcount=%d' % cmd.count_atoms('sele'))")
            }
        }

        // Poll feedback every 100ms
        feedbackTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.pollFeedback()
            self?.pollObjects()
        }
    }

    func shutdown() {
        feedbackTimer?.invalidate()
        feedbackTimer = nil
        if let inst = instance {
            PyMOLBridge_Free(inst)
        }
        instance = nil
        isReady = false
    }

    // MARK: - Commands

    func runCommand(_ command: String) {
        guard isReady else { return }
        PyMOLBridge_RunCommand(command)
    }

    // Debug: run raw Python in the embedded interpreter.
    func runPython(_ code: String) {
        guard isReady else { return }
        PyMOLBridge_RunPython(code)
    }

    // Tap-to-select via metal_pick (NDC in [-1,1], aspect = width/height).
    func pick(ndcX: Float, ndcY: Float, aspect: Float) {
        guard let inst = instance else { return }
        PyMOLBridge_Pick(inst, ndcX, ndcY, aspect)
    }

    // MARK: - Render loop hooks (called by MetalViewport)

    func idle() {
        guard let inst = instance else { return }
        _ = PyMOLBridge_Idle(inst)
    }

    func reshape(width: Int, height: Int) {
        guard let inst = instance else { return }
        PyMOLBridge_Reshape(inst, Int32(width), Int32(height))
    }

    func button(_ btn: Int32, state: Int32, x: Int32, y: Int32, modifiers: Int32) {
        guard let inst = instance else { return }
        PyMOLBridge_Button(inst, btn, state, x, y, modifiers)
    }

    func drag(x: Int32, y: Int32, modifiers: Int32) {
        guard let inst = instance else { return }
        PyMOLBridge_Drag(inst, x, y, modifiers)
    }

    func key(_ k: UInt8, x: Int32, y: Int32, modifiers: Int32) {
        guard let inst = instance else { return }
        PyMOLBridge_Key(inst, k, x, y, modifiers)
    }

    func renderMetal() {
        guard let inst = instance else { return }
        PyMOLBridge_RenderMetal(inst)
    }

    func pushValidContext() {
        guard let inst = instance else { return }
        PyMOLBridge_PushValidContext(inst)
    }

    func popValidContext() {
        guard let inst = instance else { return }
        PyMOLBridge_PopValidContext(inst)
    }

    // Construct the Metal renderer from the MTKView (idempotent in the bridge).
    func setupMetalRenderer(view: MTKView) {
        guard let inst = instance else { return }
        PyMOLBridge_SetupMetalRenderer(inst, Unmanaged.passUnretained(view).toOpaque())
    }

    // Hand the current frame's drawable + render-pass descriptor to RendererMetal.
    func renderMetalFrame(drawable: CAMetalDrawable, passDescriptor: MTLRenderPassDescriptor, width: Int, height: Int) {
        guard let inst = instance else { return }
        let dPtr = Unmanaged.passUnretained(drawable as AnyObject).toOpaque()
        let pPtr = Unmanaged.passUnretained(passDescriptor).toOpaque()
        PyMOLBridge_RenderMetalFrame(inst, dPtr, pPtr, Int32(width), Int32(height))
    }

    // MARK: - Polling

    private func pollFeedback() {
        guard let inst = instance else { return }
        guard let cStr = PyMOLBridge_GetFeedback(inst) else { return }
        let text = String(cString: cStr)
        PyMOLBridge_FreeFeedback(cStr)
        if !text.isEmpty {
            // Check for ObjectPanel feedback before appending to log
            for line in text.components(separatedBy: "\n") {
                if line.hasPrefix("OBJPANEL:") {
                    parseObjectPanelFeedback(line)
                } else if !line.isEmpty {
                    DispatchQueue.main.async {
                        self.feedbackLog.append(line)
                    }
                }
            }
        }
    }

    private var objectPollCounter = 0

    private func pollObjects() {
        // Poll every 5th tick (~500ms at 100ms timer) to avoid flooding
        objectPollCounter += 1
        guard objectPollCounter % 5 == 0 else { return }

        runCommand(
            "python\n"
            + "import json\n"
            + "from pymol import cmd\n"
            + "objs = list(cmd.get_names('public_objects') or [])\n"
            + "sels = list(cmd.get_names('public_selections') or [])\n"
            + "enabled = set(cmd.get_names('public_objects', enabled_only=1) or [])\n"
            + "enabled |= set(cmd.get_names('public_selections', enabled_only=1) or [])\n"
            + "sel_counts = {s: cmd.count_atoms(s) for s in sels}\n"
            + "print('OBJPANEL:' + json.dumps({'objects': objs, 'selections': sels, "
            + "'enabled': list(enabled), 'sel_counts': sel_counts}))\n"
            + "python end"
        )
    }
}

// MARK: - Data models
// ObjectEntry is the canonical model, defined in ObjectPanel.swift.
// MoleculeObject is a typealias for backward compatibility.
typealias MoleculeObject = ObjectEntry
