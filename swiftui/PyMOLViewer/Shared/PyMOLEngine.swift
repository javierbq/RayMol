// PyMOLEngine.swift — Singleton managing the PyMOL instance lifecycle
// Wraps the C bridge API and publishes observable state for SwiftUI views.

import Foundation
import Combine
import MetalKit

/// Frequently-changing movie/timeline playback state, kept in its OWN
/// ObservableObject so the ≈10/s frame ticks during playback re-render only the
/// TransportBar (the lone observer) and not the inspector/menus that observe
/// PyMOLEngine. Mirrors the core; updated by PyMOLEngine.parsePlaybackFeedback.
final class PlaybackState: ObservableObject {
    @Published var currentFrame: Int = 1   // 1-based, == cmd.get_frame()
    @Published var frameCount: Int = 1     // == cmd.count_frames()
    @Published var isPlaying: Bool = false // == cmd.get_movie_playing()
    @Published var movieFPS: Double = 15   // == movie_fps setting
    @Published var movieLoop: Bool = true  // == movie_loop setting
}

enum MeasureKind: String { case distance, angle, dihedral }

final class PyMOLEngine: ObservableObject {
    static let shared = PyMOLEngine()

    // Published state for UI binding
    @Published var feedbackLog: [String] = []
    @Published var objects: [MoleculeObject] = []
    @Published var sequences: [SequenceObject] = []
    @Published var selectedResidueKeys: Set<String> = []
    @Published var isReady = false
    @Published var sequenceVisible = true

    // Current MTKView drawable size in backing pixels (updated by the viewport
    // coordinator on resize). Used by the Export menu's "current size" render.
    @Published var viewportPixelSize: CGSize = .zero

    // Representation inspector state.
    // Per-object active representations + their current setting values + color
    // override, populated by pollDetails()/parseObjectDetailFeedback().
    @Published var objectDetails: [String: [RepState]] = [:]
    // Global "Scene" parameters (metal_*, depth_cue, fog, fov, surface_quality, bg).
    @Published var sceneState = SceneState()
    // Per-object state metadata (effective current state + overlay-all) for the
    // inspector STATE row; populated alongside objectDetails for expanded cards.
    @Published var objectMeta: [String: ObjStateMeta] = [:]
    // Saved scenes (ordered) + the current scene name, for the Scenes strip.
    @Published var sceneNames: [String] = []
    @Published var currentScene: String = ""
    // Live atom-count preview for the selection builder (nil = not previewing).
    @Published var selectionPreviewCount: Int? = nil
    // Interactive measurement: nil = off; otherwise taps pick atoms for a
    // distance/angle/dihedral. measureStatus is the prompt/result shown in the UI.
    @Published var measureMode: MeasureKind? = nil
    @Published var measureStatus: String = ""
    // The single detail view that is currently open (accordion: at most one).
    // nil = none, `sceneDetailKey` = the SCENE card, otherwise an object name.
    // Drives which object the detail poll queries (collapsed = cheap).
    @Published var expandedDetail: String? = nil
    // Sentinel for "the SCENE card is the open detail view" — a control char so
    // it can never collide with a real object name.
    static let sceneDetailKey = "\u{1}scene"

    // Reps the user toggled invisible but wants kept as listed "layers" (per
    // object) so they stay in the inspector and can be toggled back on, instead
    // of vanishing the moment they're hidden. Modified ONLY by explicit user
    // actions (hide keeps, show/delete removes) — never by the detail poll — so
    // there's no re-add race with the ~500ms poll.
    @Published var keptHidden: [String: Set<String>] = [:]

    // MARK: Timeline / playback (states · trajectories · movies)
    // In PyMOL these are ONE concept: a 1-based movie frame index that maps
    // (via mset) to a coordinate state. The CORE drives frame advance
    // (cmd.mplay → SceneIdle, ticked every Metal frame); Swift only scrubs
    // (cmd.frame) and mirrors core state.
    //
    // The per-frame state lives in a SEPARATE ObservableObject so the ≈10/s
    // frame ticks during playback re-render ONLY the TransportBar (which
    // observes `playback`) and NOT the inspector/menus (which observe `engine`).
    // Re-rendering the inspector on every tick was resetting open menus to the
    // top and dropping in-flight button touches during playback.
    let playback = PlaybackState()
    // Lightweight gate the rest of the UI observes to show/hide the transport
    // bar. Flips only when a multi-state object appears/disappears, so it does
    // NOT cause per-frame re-renders of views that observe `engine`.
    @Published var hasTimeline: Bool = false
    // While the user drags the scrubber, the poll must NOT overwrite
    // currentFrame (classic two-way-binding fight). Set on drag start, cleared
    // shortly after release so the next poll can re-sync.
    var isScrubbing: Bool = false
    private var scrubReleaseWork: DispatchWorkItem?
    private var lastScrubFrame: Int = -1

    // The opaque PyMOL instance pointer
    private(set) var instance: PyMOLHandle?

    private var feedbackTimer: Timer?

    private init() {}

    // MARK: - Lifecycle

    func initialize(resourcePath: String) {
        guard instance == nil else { return }

        instance = PyMOLBridge_New()
        guard let inst = instance else { return }

        // Point the embedded Python's TLS at the bundled CA bundle BEFORE init,
        // so `fetch` (HTTPS to RCSB/PDB) can verify certificates — iOS has no
        // system cert file reachable from the sandbox. Must precede Py init.
        if let ca = Bundle.main.path(forResource: "cacert", ofType: "pem", inDirectory: "data") {
            setenv("SSL_CERT_FILE", ca, 1)
        }

        PyMOLBridge_InitPython(inst, resourcePath)
        PyMOLBridge_Start(inst)

        isReady = true

        // Build marker — lets us confirm the device is running THIS binary (not a
        // cached/stale install) when verifying gesture-direction fixes. Bump the
        // tag whenever gesture behavior changes; it shows at the top of the log.
        DispatchQueue.main.async { [weak self] in
            self?.feedbackLog.append(" [build] v24  (selection mode: atom/residue/chain/segment/object/molecule)")
        }

        // `fetch` downloads into fetch_path; the process cwd is read-only on iOS,
        // so point it at the writable Documents directory.
        if let docs = FileManager.default.urls(for: .documentDirectory,
                                               in: .userDomainMask).first {
            runPython("from pymol import cmd as _c; _c.set('fetch_path', '\(docs.path)')")
        }

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

        // Test affordance: simulate a Shift+RIGHT vertical drag — the exact calls
        // the Shift+two-finger trackpad gesture makes — to verify it CLIPS (moves
        // the slab through the scene). Format: "cx,cy". Fires at t+4s (after
        // config_mouse settles, so Right+Shift maps to 'clip').
        if let d = ProcessInfo.processInfo.environment["PYMOL_AUTOCLIP"] {
            let parts = d.split(separator: ",").compactMap { Int32($0) }
            if parts.count == 2 {
                let cx = parts[0], cy = parts[1]
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                    guard let self = self else { return }
                    let s = PYMOL_MOD_SHIFT
                    self.button(PYMOL_BUTTON_RIGHT, state: PYMOL_BUTTON_DOWN, x: cx, y: cy, modifiers: s)
                    for i in 1...30 {
                        self.drag(x: cx, y: cy + Int32(i) * 6, modifiers: s)
                    }
                    self.button(PYMOL_BUTTON_RIGHT, state: PYMOL_BUTTON_UP, x: cx, y: cy + 180, modifiers: s)
                    NSLog("PYMOL_AUTOCLIP: simulated Shift+right-drag from (\(cx),\(cy)) +180px up")
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

        // Test affordance: seed the inspector's expanded object cards so the
        // expanded representation grid can be screenshotted without a click.
        // Format: comma-separated object names.
        if let ex = ProcessInfo.processInfo.environment["PYMOL_AUTOEXPAND"] {
            let names = ex.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.expandedDetail = names.first(where: { !$0.isEmpty })
            }
        }

        // Test affordance: after a few frames render, capture the Metal
        // framebuffer to a PNG (ray=0 => the rendered image, not CPU raytrace).
        if let p = ProcessInfo.processInfo.environment["PYMOL_AUTOPNG"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.runCommand("png \(p), ray=0")
            }
        }

        // Test affordance: exercise the Export menu's GPU hi-res render path with
        // an explicit ray-traced flag — the exact call Save Image / Copy make.
        // Format: "path,W,H[,rt]" (rt: -1 WYSIWYG default, 0 off, 1 force on).
        if let e = ProcessInfo.processInfo.environment["PYMOL_AUTOEXPORT"] {
            let parts = e.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count >= 3, let w = Int(parts[1]), let h = Int(parts[2]) {
                let rt = parts.count >= 4 ? (Int(parts[3]) ?? -1) : -1
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                    self?.renderHiResPNG(parts[0], width: w, height: h, rayTraced: rt)
                    NSLog("PYMOL_AUTOEXPORT: \(parts[0]) \(w)x\(h) rt=\(rt)")
                }
            }
        }

        // Poll feedback every 100ms
        feedbackTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.pollFeedback()
            self.pollObjects()
            // While the core is advancing frames, mirror the frame counter at
            // the full 100ms tick so the scrubber tracks playback smoothly.
            // When idle, the cheaper 500ms pollObjects() discovery suffices.
            if self.playback.isPlaying { self.pollPlayback() }
        }
    }

    // Ask the core for the current frame / length / play state. Cheap (a few
    // cmd gets); the PLAYBACK: line is read on the next pollFeedback tick.
    private func pollPlayback() {
        runPython("from pymol import appkit_movie as _am\n_am.poll()")
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
        // A plain `png <file>` (ray=0) wants the RENDERED frame, but PyMOL's
        // ScenePNG reads a GL framebuffer we don't have → it writes nothing.
        // Capture the Metal render ourselves instead. `ray=1` still uses the
        // (working) core CPU ray-trace path.
        if maybeCaptureRenderedPNG(command) { return }
        PyMOLBridge_RunCommand(command)
        handleSessionViewport(for: command)
        maybeWidenClipForSurface(for: command)
    }

    // Whole-structure view fits (orient/reset, load/fetch auto_zoom) + showing a
    // surface/mesh/dots set an atom-fit slab; those reps add a ~solvent_radius
    // shell beyond the atoms, so the near plane slices the surface front (exposing
    // the interior). After such a command, re-fit the view with a buffer so the
    // whole surface stays visible (runs synchronously after the command — cmd.do
    // is blocking). .pse loads restore their own exact view → excluded. Bare zoom
    // / center are user-directed framing → not overridden.
    private func maybeWidenClipForSurface(for command: String) {
        let l = command.lowercased()
        if l.contains(".pse") { return }
        let triggers = ["orient", "reset", "load ", "fetch ",
                        "show surface", "show mesh", "show dots"]
        guard triggers.contains(where: { l.contains($0) }) else { return }
        runPython("from pymol import appkit_inspector as _ai\n_ai.widen_clip_for_surface()")
    }

    private func maybeCaptureRenderedPNG(_ command: String) -> Bool {
        let t = command.trimmingCharacters(in: .whitespaces)
        let lower = t.lowercased()
        guard lower == "png" || lower.hasPrefix("png ") else { return false }
        // Ray-traced export → let the core handle it (that path works).
        if lower.replacingOccurrences(of: " ", with: "").contains("ray=1") { return false }

        // Parse `png file[, width[, height[, ...]]]` — both positional and
        // keyword (width=, height=) forms. Filename is the first arg.
        let argStr = String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        let args = argStr.split(separator: ",").map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        }
        guard let first = args.first, !first.isEmpty else { return false }
        let path = (first as NSString).expandingTildeInPath

        // Resolve explicit width/height: positional args 2 & 3, or width=/height=.
        var w = 0, h = 0
        for (i, a) in args.enumerated() {
            let kv = a.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 {
                let key = kv[0].lowercased().trimmingCharacters(in: .whitespaces)
                let val = Int(Double(kv[1].trimmingCharacters(in: .whitespaces)) ?? 0)
                if key == "width" { w = val }
                if key == "height" { h = val }
            } else if i == 1 { w = Int(Double(a) ?? 0)
            } else if i == 2 { h = Int(Double(a) ?? 0) }
        }

        // Explicit resolution → GPU hi-res offscreen render. Otherwise capture
        // the live Metal frame at window resolution.
        if w > 0 && h > 0 {
            renderHiResPNG(path, width: w, height: h)
        } else {
            capturePNG(path)
        }
        return true
    }

    // Save the next rendered Metal frame to a PNG (captures at window resolution).
    func capturePNG(_ path: String) {
        guard let inst = instance else { return }
        PyMOLBridge_CapturePNG(inst, path)
    }

    // Render the full Metal pipeline offscreen at an arbitrary resolution and
    // write a PNG (Metal-accelerated export — all reps + hardware-RT AO/shadows).
    // Synchronous; runs on the main thread. rayTraced: -1 = use the current
    // metal_raytrace setting (WYSIWYG); 0 = force off; 1 = force on for this
    // export only (live view unchanged).
    func renderHiResPNG(_ path: String, width: Int, height: Int, rayTraced: Int = -1) {
        guard let inst = instance else { return }
        PyMOLBridge_RenderHiResPNG(inst, path, Int32(width), Int32(height), Int32(rayTraced))
    }

    // Whether the active GPU supports hardware ray tracing. The UI gates the
    // metal_raytrace toggle on this so it isn't offered where it has no effect
    // (iOS Simulator, A-series iPads). Defaults to true when unknown (renderer
    // not yet created) so the control isn't hidden before the engine is ready.
    var rayTracingSupported: Bool {
        guard let inst = instance else { return true }
        return PyMOLBridge_SupportsRayTracing(inst) != 0
    }

    // Apply a Metal-renderer letterbox so a loaded .pse reproduces its saved
    // viewport aspect. Loading non-session content (or reinitialize) clears it.
    private func handleSessionViewport(for command: String) {
        let lower = command.lowercased()
        if lower.contains(".pse"), let path = sessionPath(from: command) {
            // Read the session's 'main' [W,H] (→ letterbox via SESSIONVP) AND fix
            // the camera: modern .pse files store a 25-float SceneViewType, but
            // our embedded core is 18-float and mis-restores it (front/back
            // flip). Transpose the stored col-major 4x4 rotation into our
            // row-major 3x3 and re-apply via set_view so the framing matches the
            // session exactly. (18-float sessions restore natively — left alone.)
            runPython(
                "import pickle, os\n"
                + "from pymol import cmd as _sc\n"
                + "try:\n"
                + "    _d = pickle.load(open(os.path.expanduser(r'''\(path)'''), 'rb'))\n"
                + "    _m = _d.get('main')\n"
                + "    if _m and _m[0] and _m[1]: print('SESSIONVP:%d,%d' % (int(_m[0]), int(_m[1])))\n"
                + "    _v = _d.get('view')\n"
                + "    if _v and len(_v) >= 25:\n"
                + "        _R = [0.0]*9\n"
                + "        for _i in range(3):\n"
                + "            for _j in range(3):\n"
                + "                _R[_i*3+_j] = _v[_j*4+_i]\n"
                + "        _sc.set_view(_R + list(_v[16:19]) + list(_v[19:22]) + list(_v[22:24]) + [_v[24]])\n"
                + "except Exception:\n"
                + "    pass")
        } else if lower.hasPrefix("load ") || lower.hasPrefix("fetch ")
                    || lower.hasPrefix("reinitialize") {
            setLetterboxAspect(0)   // new non-session content → fill the window
        }
    }

    // Tab autocomplete: run PyMOL's own CLI completion on the partial input and
    // return the completed string (extended to the unambiguous prefix). The
    // candidate list (when ambiguous) is printed to the feedback log by the core.
    // Returns nil if there's no completion.
    func complete(_ text: String) -> String? {
        guard isReady, let c = PyMOLBridge_Complete(text) else { return nil }
        defer { PyMOLBridge_FreeFeedback(c) }
        let s = String(cString: c)
        return s.isEmpty ? nil : s
    }

    // Extract the file path from a `load <path>[, ...]` command (best effort).
    private func sessionPath(from command: String) -> String? {
        let t = command.trimmingCharacters(in: .whitespaces)
        guard let r = t.range(of: "load ", options: [.caseInsensitive]) else { return nil }
        var rest = String(t[r.upperBound...])
        if let comma = rest.firstIndex(of: ",") { rest = String(rest[..<comma]) }
        rest = rest.trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : rest
    }

    func setLetterboxAspect(_ aspect: Float) {
        guard let inst = instance else { return }
        PyMOLBridge_SetLetterboxAspect(inst, aspect)
    }

    // Debug: run raw Python in the embedded interpreter.
    func runPython(_ code: String) {
        guard isReady else { return }
        PyMOLBridge_RunPython(code)
    }

    // MARK: - Timeline / playback controls
    //
    // All routed through runPython (raw PyRun, no log echo) so high-rate scrub
    // calls don't flood the feedback log. Play/pause uses cmd.mplay/mstop and
    // lets the core's SceneIdle advance frames (the Metal draw loop ticks idle()
    // every frame); we never run a Swift frame-advance timer, which would race
    // the core and double-advance.

    private func movieCmd(_ call: String) {
        runPython("from pymol import cmd as _m\n_m.\(call)")
    }

    func play() { movieCmd("mplay()"); playback.isPlaying = true }
    func pause() { movieCmd("mstop()"); playback.isPlaying = false }
    func togglePlay() { playback.isPlaying ? pause() : play() }

    func rewindMovie() { movieCmd("rewind()") }
    func endingMovie() { movieCmd("ending()") }
    func stepForward() { movieCmd("forward()") }
    func stepBackward() { movieCmd("backward()") }

    // Live scrub: clamp, set immediately for snappy UI, throttle the core call.
    func scrub(to frame: Int) {
        let f = max(1, min(frame, max(playback.frameCount, 1)))
        isScrubbing = true
        playback.currentFrame = f
        scrubReleaseWork?.cancel()
        guard f != lastScrubFrame else { return }
        lastScrubFrame = f
        movieCmd("frame(\(f))")
    }

    // Drag ended: commit the final frame and release the scrub lock after a
    // beat so the ~poll can resume mirroring core state without yanking.
    func endScrub() {
        let work = DispatchWorkItem { [weak self] in
            self?.isScrubbing = false
            self?.lastScrubFrame = -1
        }
        scrubReleaseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func setMovieFPS(_ fps: Double) {
        let f = max(0.1, fps)
        playback.movieFPS = f
        movieCmd("set('movie_fps', \(f))")
    }

    func setMovieLoop(_ on: Bool) {
        playback.movieLoop = on
        movieCmd("set('movie_loop', \(on ? 1 : 0))")
    }

    func setShowFrameRate(_ on: Bool) {
        movieCmd("set('show_frame_rate', \(on ? 1 : 0))")
    }

    // Reset the whole movie timeline (clear mset/mview) and rewind.
    func clearMovie() {
        runPython("from pymol import appkit_movie as _am\n_am.reset_movie()")
    }

    // Author a movie via the high-level builders (appkit_movie.make_movie).
    // kind: roll | rock | nutate | state_loop | state_sweep | scenes.
    func buildMovie(kind: String, duration: Double = 12, angle: Double = 30,
                    loop: Bool = true, factor: Int = 1, pause: Double = 2,
                    scenes: [String]? = nil) {
        var args = "kind='\(kind)', duration=\(duration), angle=\(angle), "
            + "loop=\(loop ? 1 : 0), factor=\(factor), pause=\(pause)"
        if let s = scenes {
            let list = s.map { "'\($0.replacingOccurrences(of: "'", with: ""))'" }
                .joined(separator: ", ")
            args += ", scenes=[\(list)]"
        }
        runPython("from pymol import appkit_movie as _am\n_am.make_movie(\(args))")
    }

    // Store a camera keyframe at the current frame + interpolate (mview).
    func captureKeyframe() {
        runPython("from pymol import appkit_movie as _am\n_am.capture_keyframe()")
    }

    // MARK: - Selection builder support

    // Preview how many atoms a selection expression would match, without
    // creating a lasting selection. Emits SELPREVIEW:<n> (or :err). The caller
    // debounces. Uses a throwaway '_pv' selection.
    func previewSelection(_ expr: String) {
        let e = expr.replacingOccurrences(of: "\\", with: "")
        runPython(
            "from pymol import cmd as _c\n"
            + "try:\n"
            + "    _n = _c.select('_pv', r'''\(e)''')\n"
            + "    print('SELPREVIEW:%d' % int(_n))\n"
            + "    _c.delete('_pv')\n"
            + "except Exception:\n"
            + "    print('SELPREVIEW:err')")
    }

    // Create/overwrite a named selection and enable it.
    func createSelection(name: String, expr: String) {
        let n = name.replacingOccurrences(of: "'", with: "")
        let e = expr.replacingOccurrences(of: "\\", with: "")
        runPython("from pymol import cmd as _c\n_c.select(r'''\(n)''', r'''\(e)''', enable=1)")
    }

    // Rename an object/selection.
    func renameObject(_ old: String, to newName: String) {
        let o = old.replacingOccurrences(of: "'", with: "")
        let n = newName.replacingOccurrences(of: "'", with: "")
        guard !n.isEmpty else { return }
        runPython("from pymol import cmd as _c\n_c.set_name(r'''\(o)''', r'''\(n)''')")
    }

    // MARK: - Interactive measurement

    func setMeasureMode(_ k: MeasureKind?) {
        measureMode = k
        if let k = k {
            runPython("from pymol import appkit_measure as _am\n_am.set_mode('\(k.rawValue)')")
        } else {
            runPython("from pymol import appkit_measure as _am\n_am.reset()")
        }
    }

    // A tap while in measure mode: accumulate an atom pick (NDC in [-1,1]).
    func measurePick(ndcX: Float, ndcY: Float, aspect: Float) {
        runPython("from pymol import appkit_measure as _am\n_am.pick(\(ndcX), \(ndcY), \(aspect))")
    }

    func clearMeasurements() {
        runPython("from pymol import appkit_measure as _am\n_am.clear_all()")
    }

    // Parse MEASURE:<json> {kind,count,need,value?} → measureStatus text.
    func parseMeasureFeedback(_ line: String) {
        let js = String(line.dropFirst("MEASURE:".count))
        guard let data = js.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        let kind = root["kind"] as? String ?? "distance"
        let count = (root["count"] as? NSNumber)?.intValue ?? 0
        let need = (root["need"] as? NSNumber)?.intValue ?? 2
        let value = (root["value"] as? NSNumber)?.doubleValue
        let unit = kind == "distance" ? " Å" : "°"
        let status: String
        if let v = value {
            let s = (v == v.rounded()) ? String(Int(v)) : String(format: kind == "distance" ? "%.2f" : "%.1f", v)
            status = "\(kind.capitalized): \(s)\(unit)  ·  tap to start another"
        } else if count == 0 {
            status = "Tap \(need) atoms"
        } else {
            status = "Tap \(need - count) more atom\(need - count == 1 ? "" : "s")"
        }
        DispatchQueue.main.async { self.measureStatus = status }
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
                } else if line.hasPrefix("OBJDETAIL:") {
                    parseObjectDetailFeedback(line)
                } else if line.hasPrefix("SESSIONVP:") {
                    let parts = line.dropFirst("SESSIONVP:".count).split(separator: ",")
                    if parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]), h > 0 {
                        let aspect = Float(w / h)
                        DispatchQueue.main.async { self.setLetterboxAspect(aspect) }
                    }
                } else if line.hasPrefix("SEQPANEL:") {
                    parseSequencePanelFeedback(line)
                } else if line.hasPrefix("SEQSEL:") {
                    parseSequenceSelectionFeedback(line)
                } else if line.hasPrefix("PLAYBACK:") {
                    parsePlaybackFeedback(line)
                } else if line.hasPrefix("PLAYBACK_ERR:") {
                    // swallow (don't flood the log with poll errors)
                } else if line.hasPrefix("SELPREVIEW:") {
                    let v = String(line.dropFirst("SELPREVIEW:".count))
                    let count = Int(v)
                    DispatchQueue.main.async { self.selectionPreviewCount = count }
                } else if line.hasPrefix("MEASURE:") {
                    parseMeasureFeedback(line)
                } else if line.hasPrefix("MEASURE_ERR:") {
                    // swallow
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
            + "_ns = {o: _cmd.count_states('?' + o) for o in _objs}\n"
            + "print('OBJPANEL:' + json.dumps({'objects': _objs, 'selections': _sels, "
            + "'enabled': list(_en), 'sel_counts': _sc, 'nstate': _ns}))"
        )

        pollDetails()
        // Discover/refresh the timeline length + frame (cheap). Fast updates
        // during playback are handled by pollPlayback() on the 100ms tick.
        pollPlayback()
    }

    // Query active reps + per-rep settings + scene globals for the currently
    // EXPANDED object cards only (collapsed cards cost nothing). Emits an
    // OBJDETAIL feedback line via the bundled appkit_inspector module.
    private func pollDetails() {
        // Always run (cheap when nothing expanded — just the ~8 scene gets) so
        // the Scene card stays fresh; per-object rep detail is queried only for
        // expanded cards.
        // At most one object card is open; the SCENE sentinel polls no object.
        var names: [String] = []
        if let d = expandedDetail, d != Self.sceneDetailKey { names = [d] }
        let pyList = names.map { "'\($0.replacingOccurrences(of: "'", with: ""))'" }.joined(separator: ", ")
        runPython("from pymol import appkit_inspector as _ai\n_ai.poll([\(pyList)])")
    }

    // Parse OBJDETAIL:<json> → objectDetails + sceneState.
    func parseObjectDetailFeedback(_ line: String) {
        let js = String(line.dropFirst("OBJDETAIL:".count))
        guard let data = js.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        var details: [String: [RepState]] = [:]
        if let detail = root["detail"] as? [String: Any] {
            for (obj, repsAny) in detail {
                guard let reps = repsAny as? [[String: Any]] else { continue }
                details[obj] = reps.map { r in
                    var values: [String: Double] = [:]
                    if let vals = r["vals"] as? [String: Any] {
                        for (k, v) in vals { values[k] = (v as? NSNumber)?.doubleValue ?? 0 }
                    }
                    return RepState(
                        rep: r["rep"] as? String ?? "",
                        visible: ((r["vis"] as? NSNumber)?.intValue ?? 1) != 0,
                        values: values,
                        color: r["color"] as? String ?? "inherit")
                }
            }
        }

        var scene = SceneState()
        if let sc = root["scene"] as? [String: Any] {
            for (k, v) in sc {
                if k == "bg", let arr = v as? [Any] {
                    scene.bg = arr.map { ($0 as? NSNumber)?.doubleValue ?? 0 }
                } else {
                    scene.values[k] = (v as? NSNumber)?.doubleValue ?? 0
                }
            }
        }

        var meta: [String: ObjStateMeta] = [:]
        if let om = root["objmeta"] as? [String: Any] {
            for (obj, mAny) in om {
                guard let m = mAny as? [String: Any] else { continue }
                meta[obj] = ObjStateMeta(
                    state: (m["state"] as? NSNumber)?.intValue ?? 1,
                    overlayAll: ((m["all"] as? NSNumber)?.intValue ?? 0) != 0)
            }
        }

        let scenes = (root["scenes"] as? [String]) ?? []
        let curScene = (root["cur_scene"] as? String) ?? ""

        DispatchQueue.main.async {
            // Equality-guard: the ~500ms poll re-emits identical detail most of
            // the time; re-publishing unchanged values re-renders the inspector
            // and resets any open menu to the top. Only assign on real changes.
            if self.objectDetails != details { self.objectDetails = details }
            if self.sceneState != scene { self.sceneState = scene }
            if self.objectMeta != meta { self.objectMeta = meta }
            if self.sceneNames != scenes { self.sceneNames = scenes }
            if self.currentScene != curScene { self.currentScene = curScene }
        }
    }

    // Parse PLAYBACK:<json> → currentFrame / frameCount / isPlaying / fps / loop.
    // Mirrors core state; never overrides a user scrub in progress.
    func parsePlaybackFeedback(_ line: String) {
        let js = String(line.dropFirst("PLAYBACK:".count))
        guard let data = js.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        let frame = (root["frame"] as? NSNumber)?.intValue ?? 1
        let count = max((root["count"] as? NSNumber)?.intValue ?? 1, 1)
        let playing = ((root["playing"] as? NSNumber)?.intValue ?? 0) != 0
        let loop = ((root["loop"] as? NSNumber)?.intValue ?? 1) != 0
        let fps = (root["fps"] as? NSNumber)?.doubleValue ?? 15

        DispatchQueue.main.async {
            // Equality-guard every assignment: a @Published set fires the
            // publisher even when the value is unchanged, so unguarded writes
            // here would re-render the transport bar on every poll. Only the
            // genuinely-changing currentFrame ticks during playback.
            let pb = self.playback
            if pb.frameCount != count { pb.frameCount = count }
            if pb.isPlaying != playing { pb.isPlaying = playing }
            if pb.movieLoop != loop { pb.movieLoop = loop }
            if fps > 0 && pb.movieFPS != fps { pb.movieFPS = fps }
            // Don't fight an active drag; otherwise track the core frame.
            if !self.isScrubbing {
                let f = min(max(frame, 1), count)
                if pb.currentFrame != f { pb.currentFrame = f }
            }
            // The transport-bar visibility gate (observed by `engine`) flips
            // only when crossing the 1-frame threshold — not per frame.
            let has = count > 1
            if self.hasTimeline != has { self.hasTimeline = has }
        }
    }
}

// MARK: - Data models
// ObjectEntry is the canonical model, defined in ObjectPanel.swift.
// MoleculeObject is a typealias for backward compatibility.
typealias MoleculeObject = ObjectEntry
