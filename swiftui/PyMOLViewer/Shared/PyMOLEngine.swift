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
    @Published var sequences: [SequenceObject] = []
    @Published var selectedResidueKeys: Set<String> = []
    @Published var isReady = false
    @Published var sequenceVisible = true

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

        // Test affordance: run arbitrary ;-separated PyMOL commands (parity testing).
        if let c = ProcessInfo.processInfo.environment["PYMOL_AUTOCMD"] {
            for one in c.split(separator: ";") {
                runCommand(one.trimmingCharacters(in: .whitespaces))
            }
        }

        // Test affordance: pick at an NDC point ("x,y") using the real viewport
        // aspect, and record the selection size for verification.
        if let s = ProcessInfo.processInfo.environment["PYMOL_AUTOPICK"] {
            let parts = s.split(separator: ",").compactMap { Float($0) }
            if parts.count == 2 {
                // Delay so the AUTOCMD load/orient has actually been applied and
                // a frame has rendered (the view must be live for projection).
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                    self?.runPython(
                        "from pymol import cmd as _c\n"
                        + "from pymol.metal_pick import pick_at as _pa\n"
                        + "_vp = _c.get_viewport()\n"
                        + "_asp = (_vp[0] / float(_vp[1])) if (_vp and _vp[1]) else 1.0\n"
                        + "_pa(\(parts[0]), \(parts[1]), _asp)"
                    )
                }
            }
        }

        // Test affordance: rotate the camera (confirms view changes render).
        if let t = ProcessInfo.processInfo.environment["PYMOL_AUTOTURN"], let deg = Float(t) {
            runCommand("turn y, \(deg)")
        }

        // Test affordance: simulate a left-drag through PyMOL_Button/Drag to
        // verify the C input path drives rotation (isolates GUI event wiring
        // from the button/drag camera path). Format: "cx,cy" backing px.
        if let d = ProcessInfo.processInfo.environment["PYMOL_AUTODRAG"] {
            let parts = d.split(separator: ",").compactMap { Int32($0) }
            if parts.count == 2 {
                let cx = parts[0], cy = parts[1]
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    guard let self = self else { return }
                    self.button(PYMOL_BUTTON_LEFT, state: PYMOL_BUTTON_DOWN, x: cx, y: cy, modifiers: 0)
                    for i in 1...30 {
                        self.drag(x: cx + Int32(i) * 6, y: cy, modifiers: 0)
                    }
                    self.button(PYMOL_BUTTON_LEFT, state: PYMOL_BUTTON_UP, x: cx + 180, y: cy, modifiers: 0)
                    NSLog("PYMOL_AUTODRAG: simulated left-drag from (\(cx),\(cy)) +180px")
                }
            }
        }

        // Test affordance: simulate a MIDDLE-drag through PyMOL_Button/Drag —
        // the exact button/drag calls the trackpad two-finger pan gesture makes
        // — to verify middle-drag maps to in-plane TRANSLATE. Format: "cx,cy".
        if let d = ProcessInfo.processInfo.environment["PYMOL_AUTOPAN"] {
            let parts = d.split(separator: ",").compactMap { Int32($0) }
            if parts.count == 2 {
                let cx = parts[0], cy = parts[1]
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    guard let self = self else { return }
                    self.button(PYMOL_BUTTON_MIDDLE, state: PYMOL_BUTTON_DOWN, x: cx, y: cy, modifiers: 0)
                    for i in 1...30 {
                        self.drag(x: cx + Int32(i) * 6, y: cy, modifiers: 0)
                    }
                    self.button(PYMOL_BUTTON_MIDDLE, state: PYMOL_BUTTON_UP, x: cx + 180, y: cy, modifiers: 0)
                    NSLog("PYMOL_AUTOPAN: simulated middle-drag from (\(cx),\(cy)) +180px")
                }
            }
        }

        // Test affordance: exercise the pinch zoom path (engine.zoomBy) — the
        // exact call the pinch gesture makes — to verify it ZOOMS (not slabs).
        // Format: "frac[,reps]" (frac>0 zooms in). Fires at t+4s so PyMOL's
        // config_mouse has settled (irrelevant to zoomBy, but keeps it stable).
        if let z = ProcessInfo.processInfo.environment["PYMOL_AUTOZOOM"] {
            let parts = z.split(separator: ",")
            let frac = Float(parts.first ?? "0.1") ?? 0.1
            let reps = parts.count >= 2 ? (Int(parts[1]) ?? 8) : 8
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                guard let self = self else { return }
                for _ in 0..<reps { self.zoomBy(frac) }
                NSLog("PYMOL_AUTOZOOM: zoomBy(\(frac)) x\(reps)")
            }
        }

        // Test affordance: after a few frames render, capture the Metal
        // framebuffer to a PNG (ray=0 => the rendered image, not CPU raytrace).
        if let p = ProcessInfo.processInfo.environment["PYMOL_AUTOPNG"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.runCommand("png \(p), ray=0")
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

    // Fetch per-object residue sequences (one guide atom per residue) and emit
    // a SEQPANEL: feedback line parsed into `sequences`. Run via raw Python so
    // the command isn't echoed to the log.
    func fetchSequences() {
        guard isReady else { return }
        // Write the (potentially large) per-residue JSON to a temp file rather
        // than the feedback buffer — PyMOL feedback lines are capped (~1KB) and
        // long sequences would be split/truncated. Print only a short marker;
        // Swift reads the file (same process TMPDIR) on seeing it.
        // Each residue carries its guide-atom color index; a color table maps
        // index -> RGB so the panel can reflect the real molecular coloring.
        runPython(
            "import json, os, tempfile\n"
            + "from pymol import cmd as _sc\n"
            + "_out = []\n"
            + "_cols = {}\n"
            + "for _o in (_sc.get_names('public_objects') or []):\n"
            + "    _r = []\n"
            + "    try:\n"
            + "        _sc.iterate('(%s) and guide' % _o, '_r.append((chain, resi, resn, str(color)))', space={'_r': _r})\n"
            + "    except Exception:\n"
            + "        pass\n"
            + "    if _r:\n"
            + "        _out.append({'name': _o, 'residues': _r})\n"
            + "        for _t in _r:\n"
            + "            _cols[_t[3]] = None\n"
            + "for _ci in list(_cols.keys()):\n"
            + "    try:\n"
            + "        _cols[_ci] = _sc.get_color_tuple(int(_ci))\n"
            + "    except Exception:\n"
            + "        _cols[_ci] = (0.8, 0.8, 0.8)\n"
            + "_data = {'objects': _out, 'colors': _cols}\n"
            + "open(os.path.join(tempfile.gettempdir(), 'pymol_seq.json'), 'w').write(json.dumps(_data))\n"
            + "print('SEQPANEL:ready')"
        )
    }

    // Poll which residues are in the active 'sele' selection so the sequence
    // panel can highlight them (3D -> sequence sync). Writes compact keys
    // ("obj/chain/resi") to a temp file; emits a short SEQSEL marker.
    func fetchSequenceSelection() {
        guard isReady else { return }
        runPython(
            "import json, os, tempfile\n"
            + "from pymol import cmd as _sc\n"
            + "_sel = []\n"
            + "try:\n"
            + "    if 'sele' in (_sc.get_names('selections') or []):\n"
            + "        _sc.iterate('sele and guide', '_sel.append(model+chr(47)+chain+chr(47)+resi)', space={'_sel': _sel})\n"
            + "except Exception:\n"
            + "    pass\n"
            + "open(os.path.join(tempfile.gettempdir(), 'pymol_seqsel.json'), 'w').write(json.dumps(_sel))\n"
            + "print('SEQSEL:ready')"
        )
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

    // Explicit camera-dolly zoom: frac > 0 zooms IN, frac < 0 zooms OUT.
    // Used by the pinch/scroll gestures instead of the scroll-wheel BUTTON path,
    // because PyMOL's default three_button_viewing binds the bare wheel to
    // 'slab' (clip), not zoom. The dolly distance is scaled by the current slab
    // depth (front+back)/2 so the feel is scene-size-independent, mirroring
    // cButModeZoomForward. get_view() here is the embedded 18-float layout
    // (front=v[15], back=v[16]). move('z', +d) moves the camera in → zoom in.
    func zoomBy(_ frac: Float) {
        guard isReady, frac.isFinite, abs(frac) > 1e-5 else { return }
        runPython("from pymol import cmd as _zc\n"
            + "_zv = _zc.get_view()\n"
            + "_zc.move('z', (_zv[15] + _zv[16]) * 0.5 * (\(frac)))")
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
                } else if line.hasPrefix("SEQPANEL:") {
                    parseSequencePanelFeedback(line)
                } else if line.hasPrefix("SEQSEL:") {
                    parseSequenceSelectionFeedback(line)
                } else if !line.isEmpty {
                    DispatchQueue.main.async {
                        self.feedbackLog.append(line)
                        // Cap the log so it can't grow unbounded and thrash the
                        // SwiftUI list (which would starve the render/input loop).
                        if self.feedbackLog.count > 400 {
                            self.feedbackLog.removeFirst(self.feedbackLog.count - 400)
                        }
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

        // Keep the sequence-panel selection highlight in sync with the active
        // selection (3D-view picks/selects reflect in the sequence).
        if sequenceVisible {
            fetchSequenceSelection()
        }

        // Run via runPython (raw PyRun), NOT runCommand/cmd.do — cmd.do echoes
        // the whole command block into the feedback log every poll, which floods
        // the log and starves the UI. The print('OBJPANEL:') still reaches the
        // feedback buffer (parsed by pollFeedback); only the echo is avoided.
        runPython(
            "import json\n"
            + "from pymol import cmd as _cmd\n"
            + "_objs = list(_cmd.get_names('public_objects') or [])\n"
            + "_sels = list(_cmd.get_names('public_selections') or [])\n"
            + "_en = set(_cmd.get_names('public_objects', enabled_only=1) or [])\n"
            + "_en |= set(_cmd.get_names('public_selections', enabled_only=1) or [])\n"
            + "_sc = {s: _cmd.count_atoms(s) for s in _sels}\n"
            + "print('OBJPANEL:' + json.dumps({'objects': _objs, 'selections': _sels, "
            + "'enabled': list(_en), 'sel_counts': _sc}))"
        )
    }
}

// MARK: - Data models
// ObjectEntry is the canonical model, defined in ObjectPanel.swift.
// MoleculeObject is a typealias for backward compatibility.
typealias MoleculeObject = ObjectEntry
