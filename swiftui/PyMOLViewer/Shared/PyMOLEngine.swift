// PyMOLEngine.swift — Singleton managing the PyMOL instance lifecycle
// Wraps the C bridge API and publishes observable state for SwiftUI views.

import Foundation
import Combine
import MetalKit
#if os(iOS)
import UIKit
#endif

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

/// One PyMOL setting for the Settings panel. type: 1 bool, 2 int, 3 float,
/// 4 float3, 5 color, 6 string (pymol.setting type codes).
struct SettingItem: Identifiable, Equatable, Codable {
    let name: String
    let type: Int
    var val: String
    var id: String { name }
}

final class PyMOLEngine: ObservableObject {
    static let shared = PyMOLEngine()

    // Published state for UI binding
    @Published var feedbackLog: [String] = []
    @Published var objects: [MoleculeObject] = []
    @Published var sequences: [SequenceObject] = []
    @Published var selectedResidueKeys: Set<String> = []
    @Published var isReady = false
    // Long-op ("Calculating…") overlay state. isBusy flips on only after a 2s
    // delay so quick ops never flash it; busyLabel describes the operation.
    @Published var isBusy = false
    @Published var busyLabel = ""
    @Published var sequenceVisible = false {
        // Showing the strip must (re)fetch the sequence data — toggling the
        // panel on (menu/toolbar) only flipped this bool, so the strip rendered
        // empty until an unrelated load/refresh happened to repopulate it (the
        // "sequence only shows when the console is open" bug). Fetch on the
        // false→true edge; fetchSequences() no-ops until the engine is ready,
        // and the load path re-fetches then.
        didSet { if sequenceVisible && !oldValue { fetchSequences() } }
    }
    // True while the Theme studio preview is active: the viewport shows the
    // reserved __theme_preview example, so the sequence panel must read THAT
    // object (it's underscore-prefixed → excluded from public_objects) to stay
    // in sync with the displayed structure instead of the user's hidden objects.
    var themePreviewActive = false

    // macOS "Trackpad" mouse mode: when on, the MetalViewport trackpad gesture
    // handlers (scroll/pinch) drive rotate/pan/zoom/roll/clip directly, mirroring
    // the iOS touch defaults, rather than routing the bare wheel to PyMOL's
    // mouse_mode binding (slab). Toggled by selecting "Trackpad" in MousePanel;
    // the chosen mode is persisted via @AppStorage in MousePanel.
    @Published var trackpadMode: Bool = false

    // Current MTKView drawable size in backing pixels (updated by the viewport
    // coordinator on resize). Used by the Export menu's "current size" render.
    @Published var viewportPixelSize: CGSize = .zero

    // While true (set during a panel-divider drag), the MetalViewport freezes its
    // drawable size so a fast drag doesn't reallocate all offscreen targets every
    // frame (choppy + OOM). Cleared on release → one reshape at the final size.
    var suppressDrawableResize = false

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
    // Set by the action menu's "Rename" to request a rename modal for this object
    // name (PyMOL's `wizard renaming` has no UI on the Metal/SwiftUI app). The
    // ObjectPanel observes this and presents a name-entry alert.
    @Published var pendingRename: String? = nil
    // Pick-debug instrumentation (active when PYMOL_PICKDEBUG is set): the last
    // click point in viewport (top-down, SwiftUI) points, drawn as a crosshair so
    // a screenshot shows click-vs-selection alignment. Set by MetalViewport.
    static let debugPickEnabled = ProcessInfo.processInfo.environment["PYMOL_PICKDEBUG"] != nil
    @Published var debugClickPoint: CGPoint? = nil
    // Interactive measurement: nil = off; otherwise taps pick atoms for a
    // distance/angle/dihedral. measureStatus is the prompt/result shown in the UI.
    @Published var measureMode: MeasureKind? = nil
    @Published var measureStatus: String = ""
    // Full settings catalog for the searchable Settings panel (loaded on demand).
    @Published var settingsCatalog: [SettingItem] = []
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

    // # of heavy ops queued-but-not-finished; isBusy stays true until it hits 0
    // (so back-to-back heavy ops keep the overlay up instead of flickering).
    private var busyDepth = 0
    // After a heavy rep op flags a deferred build, hold the overlay this many
    // completed render frames (the build happens during them), then clear.
    private var pendingHeavyClearFrames = 0
    // Backstop that clears a stuck overlay if the render loop ever stalls.
    private var busyBackstop: DispatchWorkItem?

    #if os(iOS)
    // iOS session auto-save / resume. iOS purges backgrounded apps to reclaim
    // memory (jetsam), and the whole session lives only in the in-memory core,
    // so without this the user loses their work on the next cold launch. We
    // snapshot a full .pse on background and silently reload it on cold launch.
    // One-shot per process so a warm foreground (memory intact) never re-restores.
    private var didRestoreAutosave = false
    // Set by .onOpenURL: the app was launched to open a specific file, which
    // takes precedence over the autosaved scene (don't merge the old session
    // underneath the opened document).
    var launchOpenRequested = false
    // A snapshot of the viewport captured alongside the autosave, shown over the
    // viewport while the session reloads on cold launch so the user sees their
    // last scene instead of the empty "open a file" state flashing. Cleared once
    // the restored scene has had time to render.
    @Published var restoreSnapshot: UIImage?
    #endif

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
            self?.feedbackLog.append(" [build] v30  (Live-RT grain fix + Calculating overlay + immediate inspector poll)")
        }

        // `fetch` downloads into fetch_path. Use the temp directory: it's always
        // writable, is the app's own (container) tmp under the sandbox, and is NOT
        // TCC-protected — so fetching never triggers the macOS "access your
        // Documents folder" prompt. Fetched structures are transient cache, not
        // user documents, so a temp location is the right home for them.
        let tmp = NSTemporaryDirectory()
        runPython("from pymol import cmd as _c; _c.set('fetch_path', '\(tmp)')")

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

        // Test affordance: open the sequence viewer panel at launch so its layout
        // (incl. alignment gap columns) can be screenshotted. PYMOL_AUTOSEQ=1.
        if ProcessInfo.processInfo.environment["PYMOL_AUTOSEQ"] != nil {
            DispatchQueue.main.async { [weak self] in
                self?.sequenceVisible = true
                self?.fetchSequences()
            }
        }

        // Test affordance: after the app is idle/rendering (3s), simulate a long
        // heavy op so the "Calculating…" overlay can be screenshotted in a
        // real-usage-like state (init-time AUTOCMD can't — its asyncAfter hop
        // elapses before the first render). Just blocks the main thread; no core.
        if ProcessInfo.processInfo.environment["PYMOL_AUTOHEAVY"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.runHeavy("Calculating surface…") { Thread.sleep(forTimeInterval: 5.0) }
            }
        }
        // Test affordance: after the app is interactive (3s), issue a REAL
        // `show surface, <arg>` through the normal heavy path so the deferred
        // build + overlay can be verified end-to-end. PYMOL_AUTOSURF=<selection>.
        if let sel = ProcessInfo.processInfo.environment["PYMOL_AUTOSURF"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.runCommand("show surface, \(sel)")
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
        //
        // Determinism (GitHub issue #19): the exported background must reflect the
        // caller's requested bg_rgb on every run. Three things set the background
        // at launch — PYMOL_AUTOCMD (synchronous, at init), the persisted theme
        // (applied from ContentView.onAppear), and PYMOL_AUTOTHEME (at +2.5s) —
        // so a fixed-delay export raced them and captured navy/cream/peach
        // depending on ordering. We therefore (1) fire AFTER the theme paths have
        // settled and (2) re-assert PYMOL_AUTOCMD synchronously on the same
        // main-thread turn as the (synchronous) render, so the caller's explicit
        // settings — bg_color included — are authoritative at scene-clear time.
        if let e = ProcessInfo.processInfo.environment["PYMOL_AUTOEXPORT"] {
            let parts = e.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count >= 3, let w = Int(parts[1]), let h = Int(parts[2]) {
                let rt = parts.count >= 4 ? (Int(parts[3]) ?? -1) : -1
                let autoCmd = ProcessInfo.processInfo.environment["PYMOL_AUTOCMD"]
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                    guard let self = self else { return }
                    // Re-assert the caller's explicit state last, so neither the
                    // persisted theme nor PYMOL_AUTOTHEME can clobber the requested
                    // background between init and this render.
                    if let c = autoCmd {
                        for one in c.split(separator: ";") {
                            self.runCommand(one.trimmingCharacters(in: .whitespaces))
                        }
                    }
                    self.renderHiResPNG(parts[0], width: w, height: h, rayTraced: rt)
                    NSLog("PYMOL_AUTOEXPORT: \(parts[0]) \(w)x\(h) rt=\(rt)")
                }
            }
        }

        #if os(iOS)
        // Cold-launch resume: reload the session iOS purged when the app was
        // backgrounded. Skipped when a test affordance scripts the scene
        // (PYMOL_AUTOLOAD/PYMOL_AUTOCMD imply deterministic screenshot content)
        // and when launched to open a specific file (handled by .onOpenURL).
        let env = ProcessInfo.processInfo.environment
        if env["PYMOL_AUTOLOAD"] == nil && env["PYMOL_AUTOCMD"] == nil {
            restoreAutosaveIfAvailable()
        }
        #endif

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

    #if os(iOS)
    // MARK: - Session auto-save / resume (iOS)

    private static let autosaveDefaultsKey = "raymol.autosave.present"

    // Persistent home for the rolling autosave. A subfolder of Library survives
    // across launches (unlike tmp, which iOS may purge) and isn't surfaced in
    // the Files app. The directory name is intentionally space-free: the path is
    // passed through PyMOL's `load`/`save` command parser, and the conventional
    // "Application Support" location's space risks argument-splitting ambiguity.
    // Created on first access.
    private var autosaveURL: URL? {
        guard let dir = FileManager.default.urls(
            for: .libraryDirectory, in: .userDomainMask).first else { return nil }
        let appDir = dir.appendingPathComponent("RayMolState", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("autosave.pse")
    }

    // Viewport snapshot saved next to the .pse, shown during the cold-launch
    // reload so the empty state never flashes.
    private var autosaveImageURL: URL? {
        autosaveURL?.deletingLastPathComponent().appendingPathComponent("autosave.png")
    }

    private func clearAutosave() {
        if let url = autosaveURL { try? FileManager.default.removeItem(at: url) }
        if let img = autosaveImageURL { try? FileManager.default.removeItem(at: img) }
        UserDefaults.standard.set(false, forKey: Self.autosaveDefaultsKey)
    }

    /// Snapshot the full session to the autosave .pse. Called when the app is
    /// backgrounded (scenePhase → .background), the point at which iOS may
    /// subsequently terminate the process. An empty scene clears any prior
    /// autosave so the user isn't resurrected into a scene they deliberately
    /// cleared. The save runs synchronously on the main thread because the
    /// embedded core's GIL model is not safe off-main (see runHeavy), and is
    /// wrapped in a background-task assertion so a large session finishes
    /// writing within iOS's background grace window.
    func autosaveSession() {
        guard isReady, let url = autosaveURL else { return }
        guard !objects.isEmpty else { clearAutosave(); return }

        let bgTask = UIApplication.shared.beginBackgroundTask(withName: "RayMolAutosave")
        defer { if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) } }

        runPython("from pymol import cmd as _c; _c.save(r'''\(url.path)''')")
        let saved = FileManager.default.fileExists(atPath: url.path)
        UserDefaults.standard.set(saved, forKey: Self.autosaveDefaultsKey)
        // The viewport snapshot is captured separately on `.inactive` (see
        // captureRestoreSnapshot) — iOS forbids GPU/Metal work once the app is
        // already in `.background`, so it must be grabbed while still foreground.
    }

    /// Capture a snapshot of the current viewport for the cold-launch restore
    /// overlay. Must run while the app is still foreground (scenePhase
    /// `.inactive`, just before `.background`): iOS blocks Metal command-buffer
    /// submission in the background, so capturing there yields nothing. Cheap
    /// and idempotent; skipped for an empty scene.
    func captureRestoreSnapshot() {
        guard isReady, !objects.isEmpty, let img = autosaveImageURL else { return }
        // Offscreen render (NOT capturePNG): the live drawable is already gone by
        // the time scenePhase hits .inactive, so reading it yields nothing.
        // renderHiResPNG builds its own offscreen target — and .inactive is still
        // foreground, so the GPU submit is permitted (it isn't in .background).
        // Half-screen resolution keeps the one-off render cheap; it's only a
        // placeholder shown briefly during the cold-launch reload.
        let scale = UIScreen.main.scale
        let sz = UIScreen.main.bounds.size
        let w = max(Int(sz.width * scale / 2), 1)
        let h = max(Int(sz.height * scale / 2), 1)
        renderHiResPNG(img.path, width: w, height: h, rayTraced: 0)
    }

    /// Reload the autosaved session on cold launch. One-shot per process, and
    /// suppressed when the launch is opening a specific file. Routing through
    /// runCommand("load …pse") reuses handleSessionViewport, which restores the
    /// saved camera and letterbox aspect; refreshAfterRestore republishes the
    /// panels. The .pse carries its own scene settings (bg_color, metal_*), so
    /// we deliberately do NOT re-assert the active theme here — that would
    /// override the saved scene and the goal is to resume it exactly. Loading
    /// into the empty cold-launch scene reproduces the prior session exactly.
    func restoreAutosaveIfAvailable() {
        guard isReady, !didRestoreAutosave, !launchOpenRequested else { return }
        guard UserDefaults.standard.bool(forKey: Self.autosaveDefaultsKey),
              let url = autosaveURL,
              FileManager.default.fileExists(atPath: url.path) else { return }
        didRestoreAutosave = true
        // Show the last-scene snapshot over the viewport immediately so the
        // empty "open a file" state never flashes while the .pse reloads.
        if let img = autosaveImageURL,
           let data = try? Data(contentsOf: img),
           let snap = UIImage(data: data) {
            restoreSnapshot = snap
        }
        runCommand("load \(url.path)")
        refreshAfterRestore()
        // Clear the snapshot once the restored scene has had time to build and
        // render its first frame; cross-fade so the handoff is seamless.
        if restoreSnapshot != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
                self?.restoreSnapshot = nil   // ContentView fades it via .animation(value:)
            }
        }
    }
    #endif

    // MARK: - Commands

    func runCommand(_ command: String) {
        guard isReady else { return }
        // A plain `png <file>` (ray=0) wants the RENDERED frame, but PyMOL's
        // ScenePNG reads a GL framebuffer we don't have → it writes nothing.
        // Capture the Metal render ourselves instead. `ray=1` still uses the
        // (working) core CPU ray-trace path.
        if maybeCaptureRenderedPNG(command) { return }
        // Known long ops (surface build, in-place ray-trace, quality bumps) run
        // off-main so the "Calculating…" overlay can render + animate. The
        // overlay's blocking scrim prevents the user from issuing an interleaved
        // command mid-op, so selectively backgrounding these stays correctly
        // ordered. Light/interactive commands stay synchronous (snappy).
        if let label = heavyLabel(for: command) {
            runHeavy(label) { [weak self] in self?.runCommandCore(command) }
        } else {
            runCommandCore(command)
        }
    }

    // Synchronous command body. Safe on the main thread (light commands) or on
    // coreQueue (heavy commands): it calls only direct bridge/runPython helpers,
    // never runCommand, so it can't re-enter the heavy-dispatch path.
    private func runCommandCore(_ command: String) {
        PyMOLBridge_RunCommand(command)
        handleSessionViewport(for: command)
        maybeWidenClipForSurface(for: command)
    }

    // Classify a command as a known long (>~2s) operation that deserves the
    // "Calculating…" overlay. Only fire-and-forget ops (no synchronous return
    // value the caller reads) are listed — export/PNG paths drive the busy flag
    // through their own runHeavy completion. nil = light/interactive.
    private func heavyLabel(for command: String) -> String? {
        let l = command.lowercased()
        if l.hasPrefix("ray ") || l == "ray" { return "Ray tracing…" }
        if l.contains("show surface") || l.contains("as surface") { return "Calculating surface…" }
        if l.contains("show mesh") || l.contains("as mesh") { return "Calculating mesh…" }
        if l.contains("show dots") || l.contains("as dots") { return "Calculating dots…" }
        if l.contains("set surface_quality") || l.contains("set solvent_radius")
            || l.contains("set surface_carve") { return "Recomputing surface…" }
        return nil
    }

    // MARK: - Busy overlay (heavy-op dispatch)

    // Run a heavy op while showing the "Calculating…" overlay. The embedded
    // core's GIL model (PAutoBlock) is NOT safe to call off the main thread —
    // an unregistered background thread corrupts the interpreter state — so the
    // op stays on the main thread. We paint the overlay first (set isBusy, then
    // defer the op one runloop hop so SwiftUI commits the overlay before the
    // op blocks), so the card is visible for the duration of the operation.
    func runHeavy(_ label: String, _ work: @escaping () -> Void) {
        busyLabel = label
        busyDepth += 1
        isBusy = true
        // 50ms hop guarantees SwiftUI commits the overlay frame BEFORE the
        // (main-thread-blocking) op starts — a bare async can run before the
        // render commit, leaving the overlay unpainted until after the block.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            work()
            guard let self else { return }
            self.busyDepth = max(0, self.busyDepth - 1)
            if self.busyDepth == 0 {
                // `show surface`/`mesh`/`dots` (and surface-quality changes) only
                // FLAG the rep here — PyMOL builds the actual mesh lazily on the
                // next Metal frame, which is the slow part. So don't clear the
                // overlay now (it would only flash); hold it until the build
                // frame(s) complete (heavyRenderTick, called after each render).
                // Synchronous ops (ray/export) already finished inside work(), so
                // the 2 frames just clear promptly. Backstop guards a stuck overlay
                // if the render loop ever stalls.
                self.pendingHeavyClearFrames = 2
                self.busyBackstop?.cancel()
                let bs = DispatchWorkItem { [weak self] in
                    self?.pendingHeavyClearFrames = 0
                    self?.isBusy = false
                }
                self.busyBackstop = bs
                DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: bs)
            }
        }
    }

    // Called once per completed Metal frame (from MetalViewport.draw, main thread).
    // Clears the "Calculating…" overlay after the render frame that actually built
    // the deferred rep geometry, so the overlay spans the real build work.
    func heavyRenderTick() {
        guard pendingHeavyClearFrames > 0 else { return }
        pendingHeavyClearFrames -= 1
        if pendingHeavyClearFrames == 0 {
            busyBackstop?.cancel(); busyBackstop = nil
            isBusy = false
        }
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
            // grid_mode (objects laid out in side-by-side cells) is now rendered
            // natively by the Metal renderer (per-slot viewport loop in
            // SceneRenderMetal), so the session keeps whatever grid_mode it saved
            // — no reset needed. See GitHub issue: grid-mode Metal support.
            // Read the session's 'main' [W,H] (→ letterbox via SESSIONVP) AND fix
            // the camera: modern .pse files store a 25-float SceneViewType, but
            // our embedded core is 18-float and mis-restores it (front/back
            // flip). Convert the stored col-major 4x4 rotation into the 18-float
            // set_view's 9-float rotation, which is ALSO column-major (same as
            // get_view — do NOT transpose, or the restored camera orientation
            // differs from the saved one). Take the 4x4's upper-left 3x3 in the
            // same column-major order. (18-float sessions restore natively.)
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
                + "                _R[_i*3+_j] = _v[_i*4+_j]\n"
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

    // MARK: - Theme

    /// Push a theme's molecular/viewport defaults into PyMOL. Chrome is handled
    /// in SwiftUI; this covers bg_color + render toggles + the default palette
    /// that NEW objects pick up via raymol_theme.apply_to. Does NOT restyle or
    /// recolor existing objects.
    func applyTheme(_ theme: Theme) {
        guard isReady else { return }
        // 3D selection-indicator color follows the theme's selection color.
        if let inst = instance {
            let s = theme.selectionName
            PyMOLBridge_SetSelectionColor(inst, Float(s.r), Float(s.g), Float(s.b))
        }
        let chains = theme.chainCycle.map { "(\($0.pymolTriplet))" }.joined(separator: ", ")
        let elems = theme.elementColors
            .map { "'\($0.key)': (\($0.value.pymolTriplet))" }
            .joined(separator: ", ")
        let bgHex = String(format: "0x%02x%02x%02x",
                           Int(theme.viewportBackground.r * 255),
                           Int(theme.viewportBackground.g * 255),
                           Int(theme.viewportBackground.b * 255))
        // Prefer the rich raymol_theme palette; fall back to the immediate
        // scene-wide bits so chrome (bg/outline) still themes if the module is
        // somehow unavailable.
        var py = "try:\n"
        py += "    from pymol import raymol_theme as _rt\n"
        py += "    _rt.set_palette(bg=(\(theme.viewportBackground.pymolTriplet)),"
        py += " outline=\(theme.outline ? "True" : "False"),"
        py += " flat_sheets=\(theme.flatSheets ? "True" : "False"),"
        py += " fancy_helices=\(theme.fancyHelices ? "True" : "False"),"
        py += " ray_trace=\(theme.rayTrace ? "True" : "False"),"
        py += " shadows=\(theme.shadows ? "True" : "False"),"
        py += " default_style='\(theme.defaultStyle.rawValue)',"
        py += " chain_cycle=[\(chains)], element_colors={\(elems)})\n"
        py += "except Exception as _e:\n"
        py += "    from pymol import cmd as _c\n"
        py += "    _c.bg_color('\(bgHex)'); _c.set('metal_outline', \(theme.outline ? 1 : 0))\n"
        py += "    _c.set('metal_raytrace', \(theme.rayTrace ? 1 : 0)); _c.set('metal_shadows', \(theme.shadows ? 1 : 0))\n"
        runPython(py)
    }

    /// Load a structure then theme it (default style + chain/element colors) for
    /// the NEW object only. Routes all UI/agent/open-with load paths.
    func loadStructure(path: String, name: String) {
        guard isReady else { return }
        runCommand("load \(path), \(name)")
        runPython("from pymol import raymol_theme as _rt; _rt.apply_to('\(name)')")
    }

    /// Fetch a PDB id then theme the NEW object.
    func fetchStructure(id: String) {
        guard isReady else { return }
        let clean = id.replacingOccurrences(of: "'", with: "")
        runCommand("fetch \(clean), async=0, type=pdb")
        runPython("from pymol import raymol_theme as _rt; _rt.apply_to('\(clean)')")
    }

    // MARK: - Theme studio live preview
    //
    // While the Theme studio is open we snapshot the full session in memory and
    // momentarily replace the scene with a small bundled example (cartoon +
    // sidechain sticks) so the user sees the theme's impact on a real molecule.
    // Closing the studio restores the exact prior scene + camera. Driven by
    // ContentView's `.onChange(of: showThemeStudio)` so rotation doesn't trigger
    // a spurious restore/re-snapshot.

    /// Snapshot current session, then show only the themed example molecule.
    func beginThemePreview() {
        guard isReady else { return }
        // data/demo/pept.pdb is bundled on both platforms (project.yml ditto data/).
        let path = Bundle.main.path(forResource: "pept", ofType: "pdb", inDirectory: "data/demo")
            ?? Bundle.main.path(forResource: "pept", ofType: "pdb") ?? ""
        themePreviewActive = true
        runPython("from pymol import appkit_theme_preview as _tp\n_tp.begin(r'''\(path)''')")
        if sequenceVisible { fetchSequences() }
    }

    /// Re-apply the themed cartoon+sticks rep to the example after a live edit.
    func refreshThemePreview() {
        guard isReady else { return }
        runPython("from pymol import appkit_theme_preview as _tp\n_tp.style()")
        // Re-publish the example's sequence so chain/element color edits recolor
        // the sequence strip live, keeping it in sync with the previewed structure.
        if sequenceVisible { fetchSequences() }
    }

    /// Delete the example and restore the captured session, then refresh panels.
    /// The snapshot captured the pre-studio bg_color/metal_outline; if the user
    /// changed the theme while previewing, re-assert the now-active theme's
    /// global scene settings after the restore so they don't revert. (Object
    /// reps/colors restored by set_session are intentionally left as-is — theme
    /// changes never restyle existing objects.)
    func endThemePreview() {
        guard isReady else { return }
        themePreviewActive = false
        runPython("from pymol import appkit_theme_preview as _tp\n_tp.restore()")
        applyTheme(ThemeManager.shared.active)
        refreshAfterRestore()
    }

    /// One-shot, non-throttled object/detail/sequence refresh (pollObjects is
    /// throttled ~500ms and equality-guards, so force an immediate republish so
    /// the panels reflect the restored scene without lag).
    func refreshAfterRestore() {
        guard isReady else { return }
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
        refreshExpandedDetail()
        if sequenceVisible { fetchSequences() }
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

    // MARK: - Settings panel

    func loadSettingsCatalog() {
        runPython("from pymol import appkit_settings as _as\n_as.catalog()")
    }

    func setSetting(_ name: String, _ value: String) {
        let n = name.replacingOccurrences(of: "'", with: "")
        let v = value.replacingOccurrences(of: "'", with: "")
        runPython("from pymol import appkit_settings as _as\n_as.set_value(r'''\(n)''', r'''\(v)''')")
    }

    // Read the settings catalog JSON the bridge wrote to the temp dir.
    private func loadSettingsCatalogFile() {
        let path = NSTemporaryDirectory() + "pymol_settings.json"
        guard let data = FileManager.default.contents(atPath: path),
              let items = try? JSONDecoder().decode([SettingItem].self, from: data)
        else { return }
        DispatchQueue.main.async { self.settingsCatalog = items }
    }

    // SETVAL:<name>=<val> — update one row after an edit (reflects clamping/parse).
    private func parseSetValFeedback(_ line: String) {
        let body = String(line.dropFirst("SETVAL:".count))
        guard let eq = body.firstIndex(of: "=") else { return }
        let name = String(body[..<eq])
        let val = String(body[body.index(after: eq)...])
        DispatchQueue.main.async {
            if let i = self.settingsCatalog.firstIndex(where: { $0.name == name }) {
                self.settingsCatalog[i].val = val
            }
        }
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
        // While the theme studio preview is active, read the reserved example
        // object (excluded from public_objects) so the strip matches the viewport.
        // The query (incl. BIMO-style alignment gap layout) lives in the bundled
        // pymol.appkit_sequence module so it stays readable and testable.
        let preview = themePreviewActive ? "True" : "False"
        runPython(
            "from pymol import appkit_sequence as _sq\n"
            + "_sq.poll(preview=\(preview))\n"
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
                } else if line.hasPrefix("SETTINGS:ready") {
                    loadSettingsCatalogFile()
                } else if line.hasPrefix("SETTINGS:err") {
                    // swallow
                } else if line.hasPrefix("SETVAL:") {
                    parseSetValFeedback(line)
                } else if line.hasPrefix("MCP:") {
                    #if os(macOS) && !RAYMOL_MAS_RESTRICTED
                    let body = String(line.dropFirst("MCP:".count))
                    if let colon = body.firstIndex(of: ":") {
                        let kind = String(body[..<colon])
                        let b64 = String(body[body.index(after: colon)...])
                        let detail = Data(base64Encoded: b64)
                            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
                        DispatchQueue.main.async {
                            MCPServerManager.shared.handleFeedbackEvent(kind, detail)
                        }
                    }
                    #endif
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
    // Public trigger: poll the expanded object's rep detail RIGHT NOW instead of
    // waiting up to ~500ms for the next pollObjects tick. Called when a card is
    // expanded so the rep list appears immediately (otherwise a heavy surface
    // build can starve the timer and the card lingers on "No representations").
    func refreshExpandedDetail() {
        pollDetails()
    }

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

    // Parse the inspector JSON (written by appkit_inspector.poll to a temp file;
    // the feedback line is just the "OBJDETAIL:ready" trigger) → objectDetails +
    // sceneState. File-based to avoid the ~1KB feedback-line cap splitting the
    // payload and leaking continuation lines into the terminal log.
    func parseObjectDetailFeedback(_ line: String) {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("pymol_objdetail.json")
        guard let data = FileManager.default.contents(atPath: path),
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
