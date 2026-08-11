// PyMOLEngine.swift — Singleton managing the PyMOL instance lifecycle
// Wraps the C bridge API and publishes observable state for SwiftUI views.

import Foundation
import Combine
import MetalKit
#if os(iOS)
import UIKit
#endif
#if RAYMOL_MPNN
import MPNNKit
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

/// The atom/residue under a long-press, for the iOS context menu. `isEmpty`
/// means the press landed on background (no atom) → scene-level actions.
struct LongPressHit: Equatable, Identifiable {
    let id = UUID()
    var isEmpty: Bool
    var obj = "", chain = "", resi = "", resn = "", name = "", sel = ""
    /// Menu title, e.g. "ALA 42 · chain A" (or "Scene" for empty space).
    var title: String {
        if isEmpty { return "Scene" }
        var t = resn.isEmpty ? resi : "\(resn) \(resi)"
        if !chain.isEmpty { t += " · chain \(chain)" }
        return t
    }
}

final class PyMOLEngine: ObservableObject {
    static let shared = PyMOLEngine()

    // Published state for UI binding
    @Published var feedbackLog: [String] = []
    @Published var objects: [MoleculeObject] = []
    @Published var sequences: [SequenceObject] = []
    @Published var selectedResidueKeys: Set<String> = []
    // Set when an iOS long-press identifies an atom/residue (or empty space);
    // ContentView observes this to present the context menu, then clears it.
    @Published var longPressHit: LongPressHit?
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

    // While a movie export is rendering, it owns the core off the main thread
    // (renderHiResPNG temporarily reshapes global core state + blocks on the
    // GPU). The live draw loop and the feedback poll — the other main-thread
    // core accessors — gate on this flag and skip, so the exporter is the sole
    // core user and the per-frame render no longer beachballs the UI. Set/cleared
    // on the main thread by MovieExporter; the export sheet is modal so no
    // interleaved commands run meanwhile. (#58 L-59)
    var exportRenderActive = false

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
    // Move mode: rigid-body object manipulation via an on-screen gizmo (driven by
    // metal_move.py / TTT matrix). interactionMode gates gesture routing in
    // MetalViewport; gizmo holds the projected handle geometry the overlay draws
    // and the handlers hit-test; armedAxis is the iOS tap-to-arm state.
    @Published var interactionMode: InteractionMode = .viewing
    // Design mode: protein-design overlay (MPNN score/design). Mutually exclusive
    // with Move and Measure modes — entering any one clears the others.
    @Published var designMode: Bool = false
    @Published var activeMoveObject: String? = nil
    @Published var armedAxis: GizmoHandle? = nil        // iOS tap-to-arm
    // Adjust-frame mode: gizmo controls re-anchor the gizmo's own frame (origin +
    // inclination) instead of moving the structure — for precise custom pivots.
    // Active when the overlay toggle is on OR Shift is held (macOS). The gizmo
    // renders gray + semitransparent while active. Synced to metal_move.set_adjust.
    @Published var adjustFrameToggle = false { didSet { syncAdjustFrame() } }
    // @Published so the overlay toggle reflects Shift; callers must only assign it
    // on an actual change (it's polled on every hover move) to avoid re-render spam.
    @Published var moveShiftHeld = false { didSet { syncAdjustFrame() } }
    private var lastAdjustSent = false
    var adjustFrameActive: Bool { interactionMode == .move && (adjustFrameToggle || moveShiftHeld) }
    // macOS hover highlight — pushes the hovered handle to metal_move so the CGO
    // gizmo emphasizes it. Rebuilds are infrequent (only when the handle changes).
    @Published var hoveredHandle: GizmoHandle? = nil {
        didSet {
            guard interactionMode == .move, oldValue != hoveredHandle else { return }
            runPython("from pymol import metal_move as _mm\n_mm.set_hover('\(hoveredHandle?.pyName ?? "")')")
            // set_hover rebuilt the gizmo CGO with the new handle emphasized, but a
            // static scene's on-demand draw gate can consume the redisplay flag
            // before the next tick and leave the highlight unshown (the "hover does
            // nothing" symptom). Force one repaint so the emphasis actually appears.
            requestViewportRedraw()
        }
    }
    @Published var gizmo: GizmoGeometry? = nil
    // Debug bullseye (PYMOL_BULLSEYE=1): the live cursor position in gizmo NDC,
    // published on each move-mode hover so the on-screen overlay can draw a target
    // at the cursor next to the hit-test's handle markers — the visual twin of the
    // PYMOL_GIZMODEBUG log, for spotting cursor↔target mismatches.
    @Published var bullseyeCursorNDC: CGPoint? = nil
    static let bullseyeEnabled = ProcessInfo.processInfo.environment["PYMOL_BULLSEYE"] != nil
    // Hover pre-selection preview (issue #165, macOS): when true, moving the
    // pointer over the viewport highlights what a click WOULD select (in a
    // distinct light-cyan) without committing to 'sele'. User-toggleable in the
    // Mouse panel AND Scene ▸ Canvas. When false, hoverPreview() is a no-op.
    // Persisted across launches via UserDefaults (didSet); default on.
    @Published var hoverPreviewEnabled: Bool =
        (UserDefaults.standard.object(forKey: PyMOLEngine.hoverDefaultsKey) as? Bool ?? true) {
        didSet { UserDefaults.standard.set(hoverPreviewEnabled, forKey: PyMOLEngine.hoverDefaultsKey) }
    }
    static let hoverDefaultsKey = "raymol.hoverPreviewEnabled"
    // Full settings catalog for the searchable Settings panel (loaded on demand).
    @Published var settingsCatalog: [SettingItem] = []
    // The single detail view that is currently open (accordion: at most one).
    // nil = none, `sceneDetailKey` = the SCENE card, otherwise an object name.
    // Drives which object the detail poll queries (collapsed = cheap).
    // Poll the just-expanded object's rep detail IMMEDIATELY here (at the source)
    // rather than waiting up to ~500ms for the next pollObjects tick — a heavy
    // surface build can starve that timer and the card lingers on "No
    // representations shown" / renders empty (#107). Doing it in didSet (instead
    // of a per-layout view .onChange) guarantees EVERY expand path fires the
    // refresh: iOS, macOS (whose layout had no such observer — the empty-panel
    // bug), session restore, and the PYMOL_AUTOEXPAND test hook.
    @Published var expandedDetail: String? = nil {
        didSet {
            guard expandedDetail != oldValue, expandedDetail != nil else { return }
            refreshExpandedDetail()
        }
    }
    // Sentinel for "the SCENE card is the open detail view" — a control char so
    // it can never collide with a real object name.
    static let sceneDetailKey = "\u{1}scene"

    // Reps the user toggled invisible but wants kept as listed "layers" (per
    // object) so they stay in the inspector and can be toggled back on, instead
    // of vanishing the moment they're hidden. Modified ONLY by explicit user
    // actions (hide keeps, show/delete removes) — never by the detail poll — so
    // there's no re-add race with the ~500ms poll.
    @Published var keptHidden: [String: Set<String>] = [:]

    // The .pse session file the user currently has open (Finder open / drag-drop /
    // Open… of a .pse, or the destination of a Save As). nil = never-saved session
    // (or a non-.pse structure was opened). Drives ⌘S overwrite vs Save As, and the
    // macOS window title. Cleared by Clear Session.
    @Published var currentSessionURL: URL? = nil

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
    // Timeline authoring ("movie studio") mode. UI-level state, mirroring the
    // pattern of sequenceVisible/measureMode: entering it docks the multi-track
    // TimelinePanel + always-visible transport so a movie can be authored from a
    // cold start (before any frames exist). Toggled from the toolbar / menu.
    @Published var timelineMode: Bool = false
    // Camera keyframe frames the user has captured this session (1-based, sorted),
    // used to draw the Timeline's camera track. Manual keyframing only — template
    // builders (buildMovie) author their own mview keyframes and clear this list.
    // Session-scoped: not reconstructed from a reloaded .pse (a Phase-2 concern).
    @Published var cameraKeyframes: [Int] = []
    // Scenes placed AS time-positioned markers on the timeline (drag-and-drop),
    // as opposed to the recall palette. Each is an mview keyframe tagged with a
    // scene (camera flies between scenes, reps cut). One keyframe per frame, so
    // sceneMarkers frames are disjoint from cameraKeyframes. Session-scoped too.
    struct SceneMarker: Identifiable, Equatable {
        let frame: Int
        let name: String
        var id: Int { frame }   // one keyframe per frame → frame is a stable id
    }
    @Published var sceneMarkers: [SceneMarker] = []

    // MARK: Unified timeline track
    //
    // The docked TimelinePanel edits ONE ordered lane of "objects" — camera
    // keyframes and scene markers — joined by transitions (duration + easing).
    // Swift is the source of truth for the ORDER, TIMING and EASING (the things
    // the UI edits); the heavy camera view matrices live in Python
    // (appkit_movie._views) keyed by each camera item's UUID. Every edit
    // recomputes frames from the transition durations and rebuilds the whole
    // core movie via appkit_movie.rebuild. Session-scoped, like the legacy
    // tracks above (not reconstructed from a reloaded .pse).
    struct Transition: Equatable {
        var seconds: Double = 2.0    // gap from the previous item to this one
        var linear: Bool = false     // false = smooth (eased) default
    }
    enum StatesMode: String, Equatable { case sweep, loop, lockstep }
    // A "Play models" clip: sweep a model range of one/all multi-state objects.
    struct StatesSpec: Equatable {
        var objects: [String]? = nil          // nil = all multi-state objects
        var mode: StatesMode = .sweep
        var firstModel: Int = 1               // play models firstModel..lastModel
        var lastModel: Int = 0                // 0 = through the object's last model
        var durationSeconds: Double = 4.0
    }
    struct TimelineItem: Identifiable, Equatable {
        enum Kind: Equatable { case camera; case scene(name: String); case states(StatesSpec) }
        let id: UUID
        var kind: Kind
        var transition: Transition   // transition INTO this item (item[0]'s ignored)
        var pinnedState: Int? = nil  // camera/scene: hold this model (opt out of auto-sweep)
        // Explicit timeline frame. When set, the item sits at this absolute frame
        // (may overlap a states clip) instead of the sequential transition layout —
        // used for camera keyframes dropped at the playhead during a clip.
        var atFrame: Int? = nil
        init(id: UUID = UUID(), kind: Kind, transition: Transition = Transition(),
             pinnedState: Int? = nil, atFrame: Int? = nil) {
            self.id = id; self.kind = kind; self.transition = transition
            self.pinnedState = pinnedState; self.atFrame = atFrame
        }
    }
    @Published var timelineItems: [TimelineItem] = []

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
            self?.feedbackLog.append(" [build] v35  (Long-press context menu + iOS reset menu)")
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

        // Blank-on-launch guard: the on-demand draw gate can leave the very first
        // frame — where deferred rep geometry (cartoon/surface) is still being
        // built — unshown, so the scene stays blank until the user interacts
        // (loading a second object or orbiting "fixed" it). One forced frame builds
        // the geometry; the follow-up forced frames actually paint it. Cheap
        // (a handful of extra frames at startup) and harmless once rendered.
        for delay in [0.15, 0.35, 0.6, 1.0, 1.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.requestViewportRedraw()
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

        // Test affordance: enter Timeline mode at launch so the docked movie-studio
        // layout can be screenshotted (the mode toggle is otherwise UI-only).
        // PYMOL_AUTOTIMELINE=1.
        if ProcessInfo.processInfo.environment["PYMOL_AUTOTIMELINE"] != nil {
            DispatchQueue.main.async { [weak self] in self?.timelineMode = true }
        }

        // Test affordance: build the unified lane at launch so it can be
        // screenshotted. PYMOL_AUTOAPPEND is a comma list of:
        //   roll | rock  → appendCameraTemplate (4 camera items)
        //   scenes       → appendScenesTemplate (a scene item per saved scene)
        //   cam          → captureCameraItem (one camera keyframe of the view)
        // (waits for AUTOCMD scenes to load first).
        if let seq = ProcessInfo.processInfo.environment["PYMOL_AUTOAPPEND"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self = self else { return }
                self.timelineMode = true
                for raw in seq.split(separator: ",") {
                    switch String(raw).trimmingCharacters(in: .whitespaces) {
                    case "roll":   self.appendCameraTemplate(kind: "roll", duration: 8, axis: "y", angle: 30)
                    case "rock":   self.appendCameraTemplate(kind: "rock", duration: 8, axis: "y", angle: 30)
                    case "scenes": self.appendScenesTemplate(secondsPerScene: 3)
                    case "cam":    self.captureCameraItem()
                    case "states": self.appendStatesClip(objects: nil, mode: .sweep, seconds: 8)
                    default: break
                    }
                }
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
                    // background between init and this render. Use runCommandCore
                    // (NOT runCommand): runCommand routes heavy ops like `show
                    // surface` to runHeavy, which defers them ~50ms off this turn,
                    // so the synchronous render below would race the surface build
                    // and export with the surface rep still unflagged/unbuilt — the
                    // exported PNG then drops the surface (issue #22). runCommandCore
                    // flags the reps synchronously here, so the offscreen render's
                    // SceneUpdate builds them before the capture.
                    if let c = autoCmd {
                        for one in c.split(separator: ";") {
                            self.runCommandCore(one.trimmingCharacters(in: .whitespaces))
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
            self.drainMCPMainQueue()
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

    /// Full reset for the iOS "Clear session" action. clearSession() wipes the
    /// scene + selections + camera and resets every setting to defaults (then
    /// re-applies the theme); we ALSO delete the autosave here so a force-quit
    /// immediately after the reset can't restore the cleared (or bad) state on
    /// the next launch — the autosave otherwise only clears on a later
    /// background-with-empty-scene cycle. This is the iOS escape hatch from a
    /// persisted bad state (e.g. a stuck filmic tone-map).
    func clearSessionAndAutosave() {
        clearSession()
        clearAutosave()
    }

    /// Snapshot the full session to the autosave .pse. Called when the app is
    /// backgrounded (scenePhase → .background), the point at which iOS may
    /// subsequently terminate the process. An empty scene clears any prior
    /// autosave so the user isn't resurrected into a scene they deliberately
    /// cleared. The save runs synchronously on the main thread because the
    /// embedded core's GIL model is not safe off-main (see runHeavy), and is
    /// wrapped in a background-task assertion so a large session finishes
    /// writing within iOS's background grace window.
    /// - Parameter keepingNotes: pass true when the Analysis Notes store holds
    ///   content. An object-less scene is normally cleared, but notes live only
    ///   inside the .pse on iOS (the store's own recovery file is per-process),
    ///   so clearing here would silently destroy a note written before any
    ///   structure was loaded.
    func autosaveSession(keepingNotes: Bool = false) {
        guard isReady, let url = autosaveURL else { return }
        guard !objects.isEmpty || keepingNotes else { clearAutosave(); return }

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

    /// Toggle an object/selection's enabled state with an OPTIMISTIC UI update.
    /// Flips the matching `objects[idx].isEnabled` immediately on the main thread
    /// (ObjectEntry.isEnabled is a var → the checkbox re-renders this frame, no
    /// waiting on the ~500ms pollObjects round-trip), THEN issues the actual
    /// enable/disable command. The pollObjects/parseObjectPanelFeedback equality
    /// guard reconciles the array later; since we already set the value the poll
    /// will report, the reconcile is a no-op and there is no flicker.
    func setObjectEnabled(_ name: String, _ enabled: Bool) {
        // UI mutation must happen on the main thread (drives @Published).
        if Thread.isMainThread {
            if let idx = objects.firstIndex(where: { $0.name == name }) {
                objects[idx].isEnabled = enabled
            }
        } else {
            DispatchQueue.main.async {
                if let idx = self.objects.firstIndex(where: { $0.name == name }) {
                    self.objects[idx].isEnabled = enabled
                }
            }
        }
        runCommand(enabled ? "enable \(name)" : "disable \(name)")
    }

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

    /// Snapshot the complete PyMOL camera state for a note bookmark.
    func captureView() -> [Float]? {
        guard isReady, let instance else { return nil }
        var view = [Float](repeating: 0, count: 25)
        let captured = view.withUnsafeMutableBufferPointer { buffer in
            PyMOLBridge_GetView(instance, buffer.baseAddress, Int32(buffer.count))
        }
        return captured == 1 ? view : nil
    }

    /// Fly back to a camera state previously captured by `captureView()`.
    func restoreView(_ view: [Float], animate: Float = 0.45) {
        guard isReady, let instance, view.count == 25 else { return }
        let restored = view.withUnsafeBufferPointer { buffer in
            PyMOLBridge_SetView(instance, buffer.baseAddress, Int32(buffer.count), animate)
        }
        if restored == 1 { requestViewportRedraw() }
    }

    // Synchronous command body. Safe on the main thread (light commands) or on
    // coreQueue (heavy commands): it calls only direct bridge/runPython helpers,
    // never runCommand, so it can't re-enter the heavy-dispatch path.
    private func runCommandCore(_ command: String) {
        PyMOLBridge_RunCommand(command)
        handleSessionViewport(for: command)
        maybeWidenClipForSurface(for: command)
        // A per-object `set state, N, obj` (and the related all_states / unset
        // controls) changes which model renders, but once a movie exists the
        // redisplay flag can be consumed before the viewport's on-demand gate
        // checks it — leaving the viewer frozen while the state counter advances
        // (issue #132). Force one repaint so the new state shows.
        let l = command.lowercased()
        if l.hasPrefix("set state") || l.hasPrefix("set_state")
            || l.hasPrefix("set all_states") || l.hasPrefix("unset state")
            || l.hasPrefix("unset all_states") {
            requestViewportRedraw()
        }
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

    // Rebuild dirty object representations for the current frame on the MAIN
    // thread. Movie export calls this before its off-main renderHiResPNG so the
    // rep rebuild — which reaches the Python C-API via the busy-status callback —
    // runs where the embedded interpreter's GIL is held, not on the render queue.
    // MUST be called on the main thread.
    func updateScene() {
        guard let inst = instance else { return }
        PyMOLBridge_UpdateScene(inst)
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
            // A .pse saved while in Move mode bakes in the transient move gizmo
            // (the "_move_gizmo" CGO). interactionMode is NOT persisted, so on
            // cold-launch restore / manual open we'd otherwise show a stray gizmo
            // with no active mode (and its "_"-prefixed name hides it from the
            // object panel, so it can't be removed). Strip it unless we're
            // currently in Move mode — the guard avoids deleting a live gizmo
            // when a file is opened mid-move. cleanup() is idempotent.
            if interactionMode != .move {
                runPython("from pymol import metal_move as _mm\n_mm.cleanup()")
            }
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
#if DEBUG
    /// Test seam: observes every Python string this engine emits. Placed BEFORE
    /// the isReady guard so it reports what the engine *intended* to run,
    /// independent of whether the core is initialized — that keeps tests of
    /// teardown behaviour (metal_move.cleanup / appkit_measure.reset, which
    /// leave no Swift-side trace) working under any host configuration.
    /// Compiled out of Release; cost in Debug is one optional-closure call.
    var pythonTap: ((String) -> Void)? = nil
#endif

    func runPython(_ code: String) {
#if DEBUG
        pythonTap?(code)
#endif
        guard isReady else { return }
        PyMOLBridge_RunPython(code)
    }

    /// Two-stage "clear selection" used by both the selection-chip X and the Esc
    /// key (issues #163 + #166). Stage 1: if any public selection is enabled
    /// (its pink markers are showing), `deselect` — hide the highlight but keep
    /// the named selection so a follow-up refinement is still possible. Stage 2:
    /// if nothing is enabled but a `sele` named selection still exists, `delete`
    /// it outright so the object list is clean. The logic runs INLINE in Python
    /// (one runPython round-trip) rather than in Swift so it reads the CURRENT
    /// core state directly — the Swift `objects` mirror is only refreshed by the
    /// ~500ms feedback poll, so a Swift-side branch would race the poll lag.
    func escapeClearSelection() {
        guard isReady else { return }
        var py = "from pymol import cmd as _c\n"
        py += "if _c.get_names('public_selections', enabled_only=1):\n"
        py += "    _c.deselect()\n"
        py += "elif 'sele' in (_c.get_names('public_selections') or []):\n"
        py += "    _c.delete('sele')\n"
        runPython(py)
    }

    /// Write the whole session to `url` (a .pse) via cmd.save (the only path to the
    /// C++ saver is runPython — there's no Swift cmd.save wrapper) and track it as
    /// the open document so a subsequent ⌘S overwrites it with no panel. Raw triple
    /// quotes tolerate spaces/quotes in the path.
    /// NOTE: writes a plain URL — works for the Developer-ID build and for any
    /// Save-As-chosen URL (auto write-granted). A sandboxed/MAS build that silently
    /// overwrites a Finder-opened file would additionally need a security-scoped
    /// bookmark resolved here.
    /// TODO: security-scoped bookmark for sandboxed overwrite.
    func saveSession(to url: URL) {
        runPython("from pymol import cmd as _c\n_c.save(r'''\(url.path)''')")
        currentSessionURL = url
    }

    /// Stage/export Analysis Notes through the Python session extension. Paths
    /// are base64 encoded so quotes and non-ASCII filenames never become Python.
    func stageAnalysisNotes(documentURL: URL, assetsDirectory: URL) -> Bool {
        guard isReady, FileManager.default.fileExists(atPath: documentURL.path) else { return false }
        let document = Data(documentURL.path.utf8).base64EncodedString()
        let assets = Data(assetsDirectory.path.utf8).base64EncodedString()
        runPython("""
        import base64 as _b64
        from pymol import raymol_notes as _rn
        _rn.stage(_b64.b64decode('\(document)').decode('utf-8'),
                  _b64.b64decode('\(assets)').decode('utf-8'))
        """)
        return true
    }

    func exportAnalysisNotes(documentURL: URL, assetsDirectory: URL) -> Bool {
        guard isReady else { return false }
        try? FileManager.default.removeItem(at: documentURL)
        try? FileManager.default.removeItem(at: assetsDirectory)
        let document = Data(documentURL.path.utf8).base64EncodedString()
        let assets = Data(assetsDirectory.path.utf8).base64EncodedString()
        runPython("""
        import base64 as _b64
        from pymol import raymol_notes as _rn
        _rn.export(_b64.b64decode('\(document)').decode('utf-8'),
                   _b64.b64decode('\(assets)').decode('utf-8'))
        """)
        return FileManager.default.fileExists(atPath: documentURL.path)
    }

    // MARK: - Theme

    /// Whether the passive launch-time theme re-assertion
    /// (ContentView.applyPersistedTheme) should SKIP the theme's render toggles
    /// (metal_outline / metal_raytrace / metal_shadows). True when a session was
    /// restored or a file-open is pending at launch: that session OWNS its render
    /// state and must not be clobbered by the theme (the .pse already restored
    /// them). On a fresh/empty launch this is false so the theme establishes them.
    var suppressLaunchThemeRenderToggles: Bool {
        #if os(iOS)
        return didRestoreAutosave || launchOpenRequested
        #else
        return false   // macOS launch-open loads the .pse AFTER the theme, so the session wins
        #endif
    }

    /// Push a theme's molecular/viewport defaults into PyMOL. Chrome is handled
    /// in SwiftUI; this covers bg_color + render toggles + the default palette
    /// that NEW objects pick up via raymol_theme.apply_to. Does NOT restyle or
    /// recolor existing objects. `applyRenderToggles` gates the three render-state
    /// settings (outline/raytrace/shadows) so the launch-time re-assertion won't
    /// clobber a restored session (see suppressLaunchThemeRenderToggles).
    func applyTheme(_ theme: Theme, applyRenderToggles: Bool = true) {
        guard isReady else { return }
        // 3D selection-indicator color follows the theme's selection color.
        if let inst = instance {
            let s = theme.selectionName
            PyMOLBridge_SetSelectionColor(inst, Float(s.r), Float(s.g), Float(s.b))
            // Hover pre-selection preview color (issue #165): fixed light-cyan,
            // NOT theme-derived, so it reads as distinct from the committed
            // selection color under every theme.
            PyMOLBridge_SetPreselectionColor(inst, 0.40, 0.85, 1.0)
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
        let renderToggles = applyRenderToggles ? "True" : "False"
        var py = "try:\n"
        py += "    from pymol import raymol_theme as _rt\n"
        py += "    _rt.set_palette(bg=(\(theme.viewportBackground.pymolTriplet)),"
        py += " outline=\(theme.outline ? "True" : "False"),"
        py += " flat_sheets=\(theme.flatSheets ? "True" : "False"),"
        py += " fancy_helices=\(theme.fancyHelices ? "True" : "False"),"
        py += " ray_trace=\(theme.rayTrace ? "True" : "False"),"
        py += " shadows=\(theme.shadows ? "True" : "False"),"
        py += " default_style='\(theme.defaultStyle.rawValue)',"
        py += " chain_cycle=[\(chains)], element_colors={\(elems)},"
        py += " apply_render_toggles=\(renderToggles))\n"
        py += "except Exception as _e:\n"
        py += "    from pymol import cmd as _c\n"
        py += "    _c.bg_color('\(bgHex)')\n"
        if applyRenderToggles {
            // Outline is off in every theme (RayMol 1.6.1) — force off regardless
            // of theme.outline, matching raymol_theme.set_palette.
            py += "    _c.set('metal_outline', 0)\n"
            py += "    _c.set('metal_raytrace', \(theme.rayTrace ? 1 : 0)); _c.set('metal_shadows', \(theme.shadows ? 1 : 0))\n"
        }
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

    /// Clear the whole session (File ▸ Clear Session): wipe all objects, selections,
    /// and camera via `reinitialize`, then re-apply RayMol's theme defaults
    /// (bg/palette/render toggles) so the empty viewport keeps the app's look
    /// instead of PyMOL's bare defaults. The objects panel refreshes on the next
    /// poll tick.
    func clearSession() {
        guard isReady else { return }
        // No document is open after a clear — the next ⌘S becomes a Save As.
        currentSessionURL = nil
        // reinitialize wipes the core movie (mset/mview); drop the camera track's
        // keyframes so the Timeline doesn't show diamonds for frames that no
        // longer exist.
        cameraKeyframes.removeAll()
        sceneMarkers.removeAll()
        runCommand("reinitialize")
        // reinitialize also resets engine settings to defaults — restore the
        // fetch_path that initialize() set (the writable temp dir) so a post-clear
        // `fetch` doesn't fall back to cwd (which can fail or prompt for file
        // access), then re-apply the RayMol theme.
        runPython("from pymol import cmd as _c; _c.set('fetch_path', '\(NSTemporaryDirectory())')")
        applyTheme(ThemeManager.shared.active)
    }

    /// Reset the Effects-group post-processing/stylization settings to their
    /// SettingInfo.h defaults. Shared by the Inspector's "Reset effects" button
    /// and the iOS toolbar reset menu. Non-destructive — keeps loaded structures.
    func resetEffects() {
        let defaults: [(String, String)] = [
            ("metal_outline", "0"),
            ("metal_outline_width", "1.4"),
            ("metal_outline_color", "0x000000"),
            ("metal_tonemap", "0"),
            ("metal_exposure", "1.0"),
            ("depth_cue", "1"),
        ]
        for (k, v) in defaults { runCommand("set \(k), \(v)") }
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
        runPython("from pymol import appkit_inspector as _ai\n_ai.poll_panel()")
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

    // These set the movie frame while paused; force one repaint so the viewport
    // leaves the on-demand gate and shows the new frame (issue #132) — mirrors
    // the per-object `set state` case in runCommandCore.
    func rewindMovie() { movieCmd("rewind()"); requestViewportRedraw() }
    func endingMovie() { movieCmd("ending()"); requestViewportRedraw() }
    func stepForward() { movieCmd("forward()"); requestViewportRedraw() }
    func stepBackward() { movieCmd("backward()"); requestViewportRedraw() }

    // MARK: - Per-object model (state) playback — NMR/MD inspection, independent
    // of the movie. Each object animates its OWN coordinate state at its OWN fps
    // via a Swift timer (`set state, k, obj`), so ensembles can play at different
    // rates without touching the global movie frame. The state-row slider follows
    // via the object poll. Opening the Movie tab stops all of these.
    @Published var playingObjects: Set<String> = []
    @Published var objectFPS: [String: Double] = [:]
    private var objectStateTimers: [String: Timer] = [:]

    func objectPlaybackFPS(_ name: String) -> Double { objectFPS[name] ?? 15 }

    func setObjectFPS(_ name: String, _ fps: Double) {
        objectFPS[name] = fps
        if playingObjects.contains(name) { startObjectStates(name) }   // re-time
    }

    func toggleObjectStates(_ name: String) {
        playingObjects.contains(name) ? stopObjectStates(name) : startObjectStates(name)
    }

    func startObjectStates(_ name: String) {
        stopObjectStates(name)
        guard let total = objects.first(where: { $0.name == name })?.stateCount, total > 1 else { return }
        let fps = objectPlaybackFPS(name)
        var k = min(max(objectMeta[name]?.state ?? 1, 1), total)
        playingObjects.insert(name)
        let t = Timer(timeInterval: 1.0 / max(fps, 0.1), repeats: true) { [weak self] _ in
            guard let self else { return }
            k = k >= total ? 1 : k + 1
            self.runCommand("set state, \(k), \(name)")
        }
        RunLoop.main.add(t, forMode: .common)   // keeps ticking during scroll/interaction
        objectStateTimers[name] = t
    }

    func stopObjectStates(_ name: String) {
        objectStateTimers[name]?.invalidate(); objectStateTimers[name] = nil
        playingObjects.remove(name)
    }

    func stopAllObjectStates() {
        objectStateTimers.values.forEach { $0.invalidate() }
        objectStateTimers.removeAll()
        if !playingObjects.isEmpty { playingObjects.removeAll() }
    }

    func stepObjectState(_ name: String, by delta: Int) {
        guard let total = objects.first(where: { $0.name == name })?.stateCount, total > 1 else { return }
        let cur = min(max(objectMeta[name]?.state ?? 1, 1), total)
        var n = cur + delta
        if n < 1 { n = total } else if n > total { n = 1 }
        runCommand("set state, \(n), \(name)")
    }

    // Live scrub: clamp, set immediately for snappy UI, throttle the core call.
    func scrub(to frame: Int) {
        let f = max(1, min(frame, max(playback.frameCount, 1)))
        isScrubbing = true
        playback.currentFrame = f
        scrubReleaseWork?.cancel()
        guard f != lastScrubFrame else { return }
        lastScrubFrame = f
        movieCmd("frame(\(f))")
        // Paused-scrub redraw: without an active mplay the on-demand gate can
        // swallow the frame change once a movie exists, so nudge one repaint
        // (issue #132). Harmless while playing (already redrawing every tick).
        requestViewportRedraw()
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
        cameraKeyframes.removeAll()
        sceneMarkers.removeAll()
    }

    // Create a blank movie canvas of `seconds` (at the current fps) so camera
    // keyframes have a timeline to sit on. mset defines the frame count; every
    // frame shows state 1 (a camera-only movie). Rewinds and clears any manual
    // keyframes from a previous composition.
    func newTimeline(seconds: Double) {
        let frames = max(2, Int((seconds * max(playback.movieFPS, 1)).rounded()))
        runPython("from pymol import appkit_movie as _am\n_am.new_timeline(\(frames))")
        cameraKeyframes.removeAll()
        sceneMarkers.removeAll()
        // Reflect the new canvas immediately — the ~10/s playback poll would
        // otherwise lag a beat, leaving the ruler/scrubber (and a following
        // captureKeyframe, which reads currentFrame) on the old length.
        playback.frameCount = frames
        playback.currentFrame = 1
    }

    // Author a movie via the high-level builders (appkit_movie.make_movie).
    // kind: roll | rock | nutate | state_loop | state_sweep | scenes.
    func buildMovie(kind: String, duration: Double = 12, angle: Double = 30,
                    axis: String = "y", loop: Bool = true, factor: Int = 1, pause: Double = 2,
                    scenes: [String]? = nil) {
        var args = "kind='\(kind)', duration=\(duration), angle=\(angle), axis='\(axis)', "
            + "loop=\(loop ? 1 : 0), factor=\(factor), pause=\(pause)"
        if let s = scenes {
            let list = s.map { "'\($0.replacingOccurrences(of: "'", with: ""))'" }
                .joined(separator: ", ")
            args += ", scenes=[\(list)]"
        }
        runPython("from pymol import appkit_movie as _am\n_am.make_movie(\(args))")
        // The template owns the whole timeline (its own mview keyframes); drop any
        // manual camera keyframes / scene markers so the tracks don't show stale ones.
        cameraKeyframes.removeAll()
        sceneMarkers.removeAll()
    }

    // Append a template to the END of the timeline (compose by stacking). Mirrors
    // appkit_movie.append_template's DETERMINISTIC frame placement so the tracks
    // reflect the appended camera keyframes / scene markers immediately — keep the
    // two frame formulas in sync. kind: roll | rock | scenes | state_loop | state_sweep.
    func appendTemplate(kind: String, duration: Double = 8, axis: String = "y",
                        angle: Double = 30, secondsPerScene: Double = 4,
                        scenes: [String]? = nil, factor: Int = 1) {
        let fps = max(playback.movieFPS, 1)
        let start = playback.frameCount <= 1 ? 0 : playback.frameCount
        let names = scenes ?? sceneNames
        var args = "kind='\(kind)', duration=\(duration), axis='\(axis)', angle=\(angle), "
            + "seconds_per_scene=\(secondsPerScene), factor=\(factor)"
        if kind == "scenes" {
            let list = names.map { "'\($0.replacingOccurrences(of: "'", with: ""))'" }
                .joined(separator: ", ")
            args += ", scenes=[\(list)]"
        }
        runPython("from pymol import appkit_movie as _am\n_am.append_template(\(args))")

        switch kind {
        case "roll", "rock":
            let n = max(2, Int((duration * fps).rounded()))
            let fr = kind == "roll"
                ? [start + 1, start + 1 + n / 3, start + 1 + 2 * n / 3, start + n]
                : [start + 1, start + 1 + n / 4, start + 1 + 3 * n / 4, start + n]
            for f in fr where !cameraKeyframes.contains(f) { cameraKeyframes.append(f) }
            cameraKeyframes.sort()
            playback.frameCount = start + n
        case "scenes":
            let per = max(2, Int((secondsPerScene * fps).rounded()))
            for (i, nm) in names.enumerated() {
                let f = start + 1 + i * per
                sceneMarkers.removeAll { $0.frame == f }
                sceneMarkers.append(SceneMarker(frame: f, name: nm))
            }
            sceneMarkers.sort { $0.frame < $1.frame }
            playback.frameCount = start + per * max(names.count, 1)
        default:
            break   // state_loop / state_sweep: no markers; the poll syncs frameCount
        }
        playback.currentFrame = 1
    }

    // Store a camera keyframe at the current frame + interpolate (mview).
    // `linear` picks linear interpolation between keyframes instead of the default
    // eased (smooth) motion. Tracks the frame in cameraKeyframes for the timeline.
    func captureKeyframe(linear: Bool = false) {
        runPython("from pymol import appkit_movie as _am\n_am.capture_keyframe(linear=\(linear ? 1 : 0))")
        let f = playback.currentFrame
        if !cameraKeyframes.contains(f) {
            cameraKeyframes.append(f)
            cameraKeyframes.sort()
        }
    }

    // Remove the camera keyframe stored at `frame` and re-interpolate the rest.
    func deleteKeyframe(at frame: Int, linear: Bool = false) {
        runPython("from pymol import appkit_movie as _am\n"
            + "_am.clear_keyframe(\(frame), linear=\(linear ? 1 : 0))")
        cameraKeyframes.removeAll { $0 == frame }
    }

    // Recall a saved scene (camera + reps + visibility). Injection-safe (base64).
    func recallScene(_ name: String) {
        guard !name.isEmpty else { return }
        let b64 = Data(name.utf8).base64EncodedString()
        runPython("import base64 as _b64\nfrom pymol import cmd as _c\n"
            + "_c.scene(_b64.b64decode('\(b64)').decode('utf-8'), 'recall')")
    }

    // Per-scene management for the scene chips' long-press menu. Injection-safe.
    // updateScene overwrites the named scene with the CURRENT view/reps.
    func updateScene(_ name: String) { sceneAction(name, "update") }
    func deleteScene(_ name: String) { sceneAction(name, "delete") }

    private func sceneAction(_ name: String, _ action: String) {
        guard !name.isEmpty else { return }
        let b64 = Data(name.utf8).base64EncodedString()
        runPython("import base64 as _b64\nfrom pymol import cmd as _c\n"
            + "_c.scene(_b64.b64decode('\(b64)').decode('utf-8'), '\(action)')")
    }

    func renameScene(_ name: String, to newName: String) {
        let n = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !n.isEmpty, n != name else { return }
        let b = Data(name.utf8).base64EncodedString()
        let nb = Data(n.utf8).base64EncodedString()
        runPython("import base64 as _b64\nfrom pymol import cmd as _c\n"
            + "_c.scene(_b64.b64decode('\(b)').decode('utf-8'), 'rename', "
            + "new_key=_b64.b64decode('\(nb)').decode('utf-8'))")
    }

    // Move the playhead to `frame` and commit (for tapping a keyframe/ruler in
    // the timeline). Wraps the scrub + release pair used by the transport.
    func seek(to frame: Int) {
        scrub(to: frame)
        endScrub()
    }

    // Re-ease the stored camera keyframes when the timeline's Smooth/Linear
    // control changes. Uses 'reinterpolate' (redoes every segment) — plain
    // 'interpolate' only fills un-interpolated gaps, so it wouldn't change the
    // easing of keyframes already interpolated. power/linear = 1.0 gives
    // constant-speed straight motion; 0.0 gives eased, curved motion.
    func setInterpolation(linear: Bool) {
        let v = linear ? "1.0" : "0.0"
        movieCmd("mview('reinterpolate', power=\(v), linear=\(v))")
    }

    // MARK: - Timeline drag-and-drop (re-time keyframes, place/move scenes)

    // Nearest frame to `target` (clamped to the movie) not already holding a
    // keyframe — enforces one keyframe per frame across BOTH tracks. `excluding`
    // is the frame being moved, so a marker doesn't collide with itself.
    private func freeFrame(near target: Int, excluding: Int? = nil) -> Int {
        let count = max(playback.frameCount, 1)
        let clamped = min(max(target, 1), count)
        var occupied = Set(cameraKeyframes)
        occupied.formUnion(sceneMarkers.map { $0.frame })
        if let e = excluding { occupied.remove(e) }
        if !occupied.contains(clamped) { return clamped }
        var lo = clamped - 1, hi = clamped + 1      // search outward for a gap
        while lo >= 1 || hi <= count {
            if hi <= count && !occupied.contains(hi) { return hi }
            if lo >= 1 && !occupied.contains(lo) { return lo }
            lo -= 1; hi += 1
        }
        return clamped                               // movie full — give up
    }

    // Place a saved scene as a time-positioned marker at `frame` (drag from the
    // palette / tap-to-drop). The marker doubles as a camera keyframe, so the
    // view flies between scenes while reps cut. Injection-safe (base64 name).
    func placeScene(_ name: String, at frame: Int, linear: Bool = false) {
        guard !name.isEmpty, playback.frameCount > 1 else { return }
        let f = freeFrame(near: frame)
        let b64 = Data(name.utf8).base64EncodedString()
        runPython("import base64 as _b64\nfrom pymol import appkit_movie as _am\n"
            + "_am.place_scene(\(f), _b64.b64decode('\(b64)').decode('utf-8'), linear=\(linear ? 1 : 0))")
        sceneMarkers.removeAll { $0.frame == f }
        sceneMarkers.append(SceneMarker(frame: f, name: name))
        sceneMarkers.sort { $0.frame < $1.frame }
    }

    // Re-time a plain camera keyframe (drag a diamond) from `old` to `new`.
    func moveKeyframe(from old: Int, to new: Int, linear: Bool = false) {
        let n = freeFrame(near: new, excluding: old)
        guard n != old else { return }
        runPython("from pymol import appkit_movie as _am\n_am.move_keyframe(\(old), \(n), linear=\(linear ? 1 : 0))")
        cameraKeyframes.removeAll { $0 == old }
        if !cameraKeyframes.contains(n) { cameraKeyframes.append(n) }
        cameraKeyframes.sort()
    }

    // Re-time a scene marker (drag a scene chip along the lane) from `old` to `new`.
    func moveSceneMarker(_ name: String, from old: Int, to new: Int, linear: Bool = false) {
        let n = freeFrame(near: new, excluding: old)
        guard n != old else { return }
        let b64 = Data(name.utf8).base64EncodedString()
        runPython("import base64 as _b64\nfrom pymol import appkit_movie as _am\n"
            + "_am.move_scene_marker(\(old), _b64.b64decode('\(b64)').decode('utf-8'), \(n), linear=\(linear ? 1 : 0))")
        sceneMarkers.removeAll { $0.frame == old || $0.frame == n }
        sceneMarkers.append(SceneMarker(frame: n, name: name))
        sceneMarkers.sort { $0.frame < $1.frame }
    }

    // Delete a scene marker (long-press). Clears its mview keyframe.
    func deleteSceneMarker(at frame: Int, linear: Bool = false) {
        runPython("from pymol import appkit_movie as _am\n"
            + "_am.clear_keyframe(\(frame), linear=\(linear ? 1 : 0))")
        sceneMarkers.removeAll { $0.frame == frame }
    }

    // MARK: - Unified timeline track ops
    //
    // The docked TimelinePanel's single lane. Every mutation ends in
    // rebuildMovie(), which recomputes frames from the transition durations and
    // rebuilds the entire core movie from `timelineItems` (Swift is the source
    // of truth). Camera views live in appkit_movie._views, keyed by item UUID.

    // Cumulative 1-based frame of each item, derived from the transition
    // durations: item[0] sits at frame 1 (its inbound transition is ignored);
    // each later item is `transition.seconds` (× fps) past the previous, forced
    // strictly increasing so mview keyframes never collide. [] when empty.
    // Each item's (startFrame, endFrame). Camera/scene are zero-width points
    // (end == start); a states clip occupies its own span (end = start + its
    // duration × fps), so later items begin after it.
    func itemSpans() -> [(start: Int, end: Int)] {
        guard !timelineItems.isEmpty else { return [] }
        let fps = max(playback.movieFPS, 1)
        var out = [(start: Int, end: Int)](repeating: (1, 1), count: timelineItems.count)
        var acc = 0.0
        var lastSeqEnd = 0
        var seenSeq = false
        for (i, it) in timelineItems.enumerated() {
            // Positioned items (a camera dropped at the playhead) sit at their
            // absolute frame and don't participate in the sequential layout.
            if let af = it.atFrame {
                out[i] = (max(1, af), max(1, af)); continue
            }
            let start: Int
            if !seenSeq {
                start = 1; seenSeq = true
            } else {
                acc += max(it.transition.seconds, 0.1)
                start = max(lastSeqEnd + 1, 1 + Int((acc * fps).rounded()))
            }
            var end = start
            if case .states(let spec) = it.kind {
                end = start + max(1, Int((spec.durationSeconds * fps).rounded()))
            }
            out[i] = (start, end); lastSeqEnd = end
        }
        return out
    }

    func itemFrames() -> [Int] { itemSpans().map { $0.start } }

    var timelineTotalFrames: Int { itemSpans().map { $0.end }.max() ?? 1 }

    // Rebuild the whole core movie from `timelineItems`. Serializes an ordered
    // spec (camera → UUID into _views; scene → base64 name) with each item's
    // inbound-transition easing, base64-wrapped so scene names / JSON can't break
    // the Python literal. Mirrors playback.frameCount immediately (the ~10/s poll
    // would otherwise lag the ruler a beat).
    func rebuildMovie() {
        guard isReady else { return }
        if timelineItems.isEmpty {
            // "[]" → clears the movie (see appkit_movie.rebuild).
            runPython("from pymol import appkit_movie as _am\n_am.rebuild('W10=')")
            playback.frameCount = 1
            playback.currentFrame = 1
            return
        }
        let spans = itemSpans()
        var parts: [String] = []
        for (i, it) in timelineItems.enumerated() {
            let (start, end) = spans[i]
            let ease = it.transition.linear
                ? "\"power\":1.0,\"linear\":1"
                : "\"power\":0.0,\"linear\":0"
            switch it.kind {
            case .camera:
                var s = "{\"frame\":\(start),\"cam\":\"\(it.id.uuidString)\",\(ease)"
                if let ps = it.pinnedState { s += ",\"state\":\(ps)" }
                parts.append(s + "}")
            case .scene(let name):
                let b64 = Data(name.utf8).base64EncodedString()
                var s = "{\"frame\":\(start),\"scene\":\"\(b64)\",\(ease)"
                if let ps = it.pinnedState { s += ",\"state\":\(ps)" }
                parts.append(s + "}")
            case .states(let spec):
                let objs = spec.objects.map {
                    "[" + $0.map { "\"\($0)\"" }.joined(separator: ",") + "]"
                } ?? "null"
                parts.append("{\"frame\":\(start),\"end\":\(end),\"states\":1,"
                    + "\"objects\":\(objs),\"mode\":\"\(spec.mode.rawValue)\","
                    + "\"first\":\(spec.firstModel),\"last\":\(spec.lastModel)}")
            }
        }
        let json = "[" + parts.joined(separator: ",") + "]"
        let jb64 = Data(json.utf8).base64EncodedString()
        runPython("import base64 as _b64\nfrom pymol import appkit_movie as _am\n"
            + "_am.rebuild(_b64.b64decode('\(jb64)').decode('utf-8'))")
        playback.frameCount = timelineTotalFrames
        playback.currentFrame = 1
    }

    // Multi-state objects currently loaded (name, state count), and the max — used
    // by the timeline to represent a bare ensemble and to target "Play models".
    func multiStateObjects() -> [(name: String, count: Int)] {
        objects.filter { $0.stateCount > 1 }.map { ($0.name, $0.stateCount) }
    }
    var maxStateCount: Int { objects.map { $0.stateCount }.max() ?? 1 }

    // Append a "Play models" states clip (sweeps a model range over `seconds`).
    func appendStatesClip(objects: [String]? = nil, mode: StatesMode = .sweep,
                          firstModel: Int = 1, lastModel: Int = 0, seconds: Double = 4.0) {
        guard isReady else { return }
        let spec = StatesSpec(objects: objects, mode: mode,
                              firstModel: firstModel, lastModel: lastModel, durationSeconds: seconds)
        timelineItems.append(TimelineItem(kind: .states(spec)))
        rebuildMovie()
    }

    // Re-position a frame-anchored camera item (dragged along the lane).
    func setItemAtFrame(_ id: UUID, _ frame: Int) {
        guard let i = timelineItems.firstIndex(where: { $0.id == id }),
              timelineItems[i].atFrame != nil else { return }
        timelineItems[i].atFrame = max(1, frame)
        rebuildMovie()
    }

    // True when the lane has a "Play models" clip (camera keyframes then anchor to
    // the playhead so they can be placed within the clip's span).
    var hasStatesClip: Bool {
        timelineItems.contains { if case .states = $0.kind { return true } else { return false } }
    }

    // Pin (or clear) the coordinate state a camera/scene item holds.
    func setItemPinnedState(_ id: UUID, _ state: Int?) {
        guard let i = timelineItems.firstIndex(where: { $0.id == id }) else { return }
        timelineItems[i].pinnedState = state
        rebuildMovie()
    }

    // Update a states clip's spec (mode / duration / objects) in place.
    func updateStatesClip(_ id: UUID, _ spec: StatesSpec) {
        guard let i = timelineItems.firstIndex(where: { $0.id == id }) else { return }
        timelineItems[i].kind = .states(spec)
        rebuildMovie()
    }

    // Drop all movie authoring so a multi-state object plays its raw models again.
    func resetToPlainEnsemble() {
        guard isReady else { return }
        timelineItems.removeAll()
        runPython("from pymol import appkit_movie as _am\n_am.reset_ensemble()")
        playback.frameCount = max(maxStateCount, 1)
        playback.currentFrame = 1
    }

    // Append a camera keyframe of the CURRENT view to the end of the lane.
    func captureCameraItem() {
        guard isReady else { return }
        // With a "Play models" clip present, anchor the keyframe at the current
        // playhead so it can be dropped WITHIN the clip's span (camera moves while
        // the models cycle). Otherwise append sequentially as before.
        let at = hasStatesClip ? max(1, playback.currentFrame) : nil
        let item = TimelineItem(kind: .camera, atFrame: at)
        runPython("from pymol import appkit_movie as _am\n_am.capture_view('\(item.id.uuidString)')")
        timelineItems.append(item)
        rebuildMovie()
        seekToItem(item.id)
    }

    // Append a scene marker (from the palette) to the end of the lane. The
    // camera flies into the scene and its reps cut in at playback.
    func appendSceneItem(_ name: String) {
        guard isReady, !name.isEmpty else { return }
        let item = TimelineItem(kind: .scene(name: name))
        timelineItems.append(item)
        rebuildMovie()
        seekToItem(item.id)
    }

    // Reorder: move the item at `from` to final index `to` (drag past a
    // neighbor). Ripples all frames + one rebuild.
    func moveItem(from: Int, to: Int) {
        guard timelineItems.indices.contains(from) else { return }
        let clamped = min(max(to, 0), timelineItems.count - 1)
        guard from != clamped else { return }
        let it = timelineItems.remove(at: from)
        timelineItems.insert(it, at: clamped)
        rebuildMovie()
    }

    func deleteItem(_ id: UUID) {
        guard let idx = timelineItems.firstIndex(where: { $0.id == id }) else { return }
        let it = timelineItems.remove(at: idx)
        if case .camera = it.kind {
            runPython("from pymol import appkit_movie as _am\n_am.forget_view('\(id.uuidString)')")
        }
        rebuildMovie()
    }

    // Edit the transition INTO `id` (duration + easing) — the long-press config.
    func setTransition(_ id: UUID, seconds: Double, linear: Bool) {
        guard let idx = timelineItems.firstIndex(where: { $0.id == id }) else { return }
        timelineItems[idx].transition = Transition(seconds: seconds, linear: linear)
        rebuildMovie()
    }

    func frameForItem(_ id: UUID) -> Int? {
        guard let idx = timelineItems.firstIndex(where: { $0.id == id }) else { return nil }
        let frames = itemFrames()
        return frames.indices.contains(idx) ? frames[idx] : nil
    }

    func seekToItem(_ id: UUID) {
        if let f = frameForItem(id) { seek(to: f) }
    }

    // Append a camera Roll/Rock as a run of 4 camera items joined by equal
    // transitions that sum to `duration`. Python computes the waypoint views
    // (spin/rock around the current view) under Swift-generated UUIDs.
    func appendCameraTemplate(kind: String, duration: Double, axis: String, angle: Double) {
        guard isReady else { return }
        let count = 4
        let ids = (0..<count).map { _ in UUID() }
        let idsJSON = "[" + ids.map { "\"\($0.uuidString)\"" }.joined(separator: ",") + "]"
        let idsB64 = Data(idsJSON.utf8).base64EncodedString()
        runPython("import base64 as _b64\nfrom pymol import appkit_movie as _am\n"
            + "_am.capture_template_views(_b64.b64decode('\(idsB64)').decode('utf-8'), "
            + "'\(kind)', axis='\(axis)', angle=\(angle))")
        let per = max(duration / Double(count - 1), 0.2)   // 3 gaps span the duration
        for id in ids {
            timelineItems.append(TimelineItem(id: id, kind: .camera,
                                              transition: Transition(seconds: per, linear: false)))
        }
        rebuildMovie()
    }

    // Append a scene marker per saved scene, each `secondsPerScene` apart.
    func appendScenesTemplate(secondsPerScene: Double, scenes: [String]? = nil) {
        guard isReady else { return }
        let names = scenes ?? sceneNames
        guard !names.isEmpty else { return }
        for nm in names {
            timelineItems.append(TimelineItem(kind: .scene(name: nm),
                                              transition: Transition(seconds: secondsPerScene, linear: false)))
        }
        rebuildMovie()
    }

    // Empty the unified lane and clear the core movie + stored views.
    func clearMovieItems() {
        guard isReady else { return }
        timelineItems.removeAll()
        runPython("from pymol import appkit_movie as _am\n_am.forget_all_views()\n_am.reset_movie()")
        playback.frameCount = 1
        playback.currentFrame = 1
    }

    // MARK: - Selection builder support

    // Preview how many atoms a selection expression would match, without
    // creating a lasting selection. Emits SELPREVIEW:<n> (or :err). The caller
    // debounces. Uses a throwaway '_pv' selection.
    func previewSelection(_ expr: String) {
        // Pass the expression as base64 and decode in Python, so a selection
        // string containing quotes / ''' / backslashes can neither break the
        // literal nor inject code (the old strip-backslashes + r'''…''' was both
        // lossy and injectable via an embedded ''').
        let b64 = Data(expr.utf8).base64EncodedString()
        runPython(
            "import base64 as _b64\n"
            + "from pymol import cmd as _c\n"
            + "_e = _b64.b64decode('\(b64)').decode('utf-8')\n"
            + "try:\n"
            + "    _n = _c.select('_pv', _e)\n"
            + "    print('SELPREVIEW:%d' % int(_n))\n"
            + "    _c.delete('_pv')\n"
            + "except Exception:\n"
            + "    print('SELPREVIEW:err')")
    }

    // Create/overwrite a named selection and enable it.
    func createSelection(name: String, expr: String) {
        // base64 the name + expression (see previewSelection): injection-safe.
        let nb = Data(name.utf8).base64EncodedString()
        let eb = Data(expr.utf8).base64EncodedString()
        runPython("import base64 as _b64\nfrom pymol import cmd as _c\n"
            + "_c.select(_b64.b64decode('\(nb)').decode('utf-8'), "
            + "_b64.b64decode('\(eb)').decode('utf-8'), enable=1)")
    }

    // Rename an object/selection.
    func renameObject(_ old: String, to newName: String) {
        guard !newName.isEmpty else { return }
        // base64 both names (see previewSelection): injection-safe. The C core
        // sanitizes the decoded name via ObjectMakeValidName.
        let ob = Data(old.utf8).base64EncodedString()
        let nb = Data(newName.utf8).base64EncodedString()
        runPython("import base64 as _b64\nfrom pymol import cmd as _c\n"
            + "_c.set_name(_b64.b64decode('\(ob)').decode('utf-8'), "
            + "_b64.b64decode('\(nb)').decode('utf-8'))")
    }

    // MARK: - Interactive measurement

    func setMeasureMode(_ k: MeasureKind?) {
        #if RAYMOL_MPNN
        if MainActor.assumeIsolated({ designController.isCalculating }) { return }
        #endif
        measureMode = k
        if let k = k {
            if interactionMode == .move { setInteractionMode(.viewing) }   // mutually exclusive
            setDesignMode(false)                                            // mutually exclusive
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

    /// Structured residue rows for Analysis Notes. `contacts` returns residues
    /// outside the current `sele` selection with an atom within the cutoff.
    func noteResidues(contacts: Bool, cutoff: Double = 4.0) -> [[String: String]] {
        guard isReady else { return [] }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("raymol-note-residues-\(UUID().uuidString).json")
        let encodedPath = Data(url.path.utf8).base64EncodedString()
        let selection = contacts
            ? "byres (((sele) around \(cutoff)) and not (sele))"
            : "sele"
        runPython("""
        import base64 as _b64, json as _json
        from pymol import cmd as _c
        _rows, _seen = [], set()
        if 'sele' in (_c.get_names('selections') or []):
            for _a in _c.get_model(r'''\(selection)''').atom:
                _key = (_a.model, _a.chain, _a.resi, _a.resn)
                if _key not in _seen:
                    _seen.add(_key)
                    _rows.append({'object': _a.model, 'chain': _a.chain,
                                  'resi': _a.resi, 'resn': _a.resn})
        with open(_b64.b64decode('\(encodedPath)').decode('utf-8'), 'w') as _f:
            _json.dump(_rows, _f)
        """)
        defer { try? FileManager.default.removeItem(at: url) }
        guard let data = try? Data(contentsOf: url),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else { return [] }
        return rows
    }

    func noteMeasurements() -> [[String: Any]] {
        guard isReady else { return [] }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("raymol-note-measurements-\(UUID().uuidString).json")
        let encodedPath = Data(url.path.utf8).base64EncodedString()
        runPython("""
        import base64 as _b64, json as _json
        from pymol import appkit_measure as _am
        with open(_b64.b64decode('\(encodedPath)').decode('utf-8'), 'w') as _f:
            _json.dump(_am.history(), _f)
        """)
        defer { try? FileManager.default.removeItem(at: url) }
        guard let data = try? Data(contentsOf: url),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return rows
    }

    /// Safe residue selection used by raymol-residue links in note Preview.
    func selectNoteResidue(object: String, chain: String, resi: String) {
        let values = [object, chain, resi].map { Data($0.utf8).base64EncodedString() }
        runPython("""
        import base64 as _b64
        from pymol import cmd as _c
        _o, _ch, _ri = [_b64.b64decode(_v).decode('utf-8') for _v in \(values)]
        _expr = '(model %s and chain %s and resi %s)' % (_o, _ch, _ri)
        _c.select('sele', _expr); _c.enable('sele'); _c.zoom('sele', buffer=4.0, animate=0.45)
        """)
    }

    // MARK: - Design mode (protein-design overlay)

    /// Enter or exit Design mode. Entering clears Move and Measure (mutually
    /// exclusive) through their canonical setters — NOT bare assignments. Move
    /// and Measure teardown is imperative and lives INSIDE those setters
    /// (metal_move.cleanup() / appkit_measure.reset()), so a bare assignment
    /// silently skips it and strands the "_move_gizmo" CGO in the scene, where
    /// its "_" prefix hides it from the object panel and the user cannot delete
    /// it. designMode is the odd one out: its teardown is observer-driven
    /// (.onChange(of: engine.designMode) in ContentView), so it fires on any
    /// assignment — which is why the reverse direction can stay a plain set.
    ///
    /// The MPNN controller startup/teardown is handled by that UI observer.
    /// Still safe to call in any state: the only Python reached goes through
    /// runPython, which no-ops via `guard isReady` before the core is up, and
    /// otherwise runs exactly the paths the "exit Move" / "exit Measure"
    /// buttons already use.
    func setDesignMode(_ on: Bool) {
        #if RAYMOL_MPNN
        if MainActor.assumeIsolated({ designController.isCalculating }) { return }
        #endif
        if on {
            // Recursion-free: both setters only touch designMode in their
            // ENTERING branch, and the clearing block below is `if on`-guarded.
            if interactionMode == .move { setInteractionMode(.viewing) }
            if measureMode != nil { setMeasureMode(nil) }
        }
        designMode = on
    }

    // MARK: - Exclusive interaction modes (Move / Design / Measure)

    /// Leave whichever exclusive interaction mode is active, each through that
    /// mode's OWN existing exit path — so the Esc key (see
    /// ContentView.installEscKeyMonitor) and the overlays' ✕ buttons converge on
    /// identical behavior. In particular Design goes through `setDesignMode(false)`,
    /// whose `.onChange` observer in ContentView runs the visual-state restore and
    /// edit-session teardown; Esc must never grow a second, divergent path. (#235)
    ///
    /// The three modes are mutually exclusive, so in practice at most one branch
    /// runs. They are checked independently rather than with early returns so a
    /// desynchronized state still unwinds completely instead of leaving one mode
    /// stranded.
    ///
    /// - Returns: whether any mode was actually exited. Callers use this to fall
    ///   through to their next behavior (Esc clears the selection) when Escape
    ///   found no mode to leave.
    @discardableResult
    func exitActiveInteractionMode() -> Bool {
        var exited = false
        // Each setter may return early when isCalculating is true (Part 2 guard).
        // Check the actual state AFTER the call so `exited` reflects whether an
        // exit ACTUALLY happened — a blocked setter leaves the mode unchanged, so
        // Esc must not be consumed as if the exit succeeded (Part 3 fix).
        if designMode     { setDesignMode(false);       exited = exited || !designMode }
        if interactionMode == .move { setInteractionMode(.viewing); exited = exited || interactionMode != .move }
        if measureMode != nil { setMeasureMode(nil);    exited = exited || measureMode == nil }
        return exited
    }

#if RAYMOL_MPNN
    /// True while any MLX inference is in flight (DesignController.isCalculating).
    /// Kept in sync via a Combine subscription so PyMOLEngine.objectWillChange fires
    /// and ContentView (which observes engine via @EnvironmentObject) re-renders to
    /// disable the mode controls during calculations. Read this from views; read
    /// `designController.isCalculating` from engine-layer code that already holds a
    /// reference to the controller.
    @Published private(set) var isDesignCalculating: Bool = false
    /// Retains the Combine subscription that keeps `isDesignCalculating` in sync.
    private var _designCalcCancellable: AnyCancellable?

    // Cached MPNNModel: loaded once on first use (throws → returns nil + logs).
    private var _mpnnModel: MPNNModel?
    private func loadedMPNNModel() throws -> MPNNModel {
        // Must precede any MLX allocation: sets the buffer-cache ceiling and, in a
        // simulator, switches MLX to the CPU backend (GPU there aborts).
        MPNNRuntime.configureOnce()
        if let m = _mpnnModel { return m }
        guard let url = MPNNGate.packURL else {
            throw NSError(domain: "raymol.design", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "MPNN model pack not found in bundle."])
        }
        let m = try MPNNRuntime.withMLXErrorsAsThrows { try MPNNModel(packDirectory: url) }
        _mpnnModel = m
        return m
    }

    /// Real DesignController wired to this engine's Python helpers.
    lazy var designController: DesignController = {
        let dc = DesignController(
        enumerate: { [weak self] obj, state in
            guard let self else { throw NSError(domain: "raymol.design", code: 2,
                                                userInfo: [NSLocalizedDescriptionKey: "Engine deallocated"]) }
            self.runPython("""
                from pymol import raymol_design as _rd
                _rd.enumerate_design_residues('\(obj)', \(state))
                """)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("raymol_design_residues.json")
            return try DesignResidueSet.parse(jsonAt: url)
        },
        score: { [weak self] residues, native in
            guard let self else { throw NSError(domain: "raymol.design", code: 2,
                                                userInfo: [NSLocalizedDescriptionKey: "Engine deallocated"]) }
            let model = try self.loadedMPNNModel()
            return try MPNNRuntime.withMLXErrorsAsThrows {
                try model.score(residues, sequence: native, mode: .leaveOneOut, seed: 0)
            }
        },
        applyColoring: { [weak self] obj, values, palette, lo, hi in
            guard let self else { return }
            let rows = values.map { ["chain": $0.0, "resi": $0.1, "value": $0.2 as Any] }
            if let data = try? JSONSerialization.data(withJSONObject: rows) {
                let p = FileManager.default.temporaryDirectory
                    .appendingPathComponent("raymol_design_vals.json")
                try? data.write(to: p)
                self.runPython("""
                    from pymol import raymol_design as _rd
                    _rd.apply_design_coloring('\(obj)', '\(p.path)', '\(palette)', \(lo), \(hi))
                    """)
            }
        },
        dim: { [weak self] obj in
            self?.runPython("""
                from pymol import raymol_design as _rd
                _rd.dim_object('\(obj)', 'gray70', 0.7)
                """)
        },
        snapshot: { [weak self] objs in
            let joined = objs.joined(separator: ",")
            self?.runPython("""
                from pymol import raymol_design as _rd
                _rd.snapshot_visual_state('\(joined)')
                """)
        },
        restore: { [weak self] in
            self?.runPython("""
                from pymol import raymol_design as _rd
                _rd.restore_visual_state()
                """)
        },
        setSticks: { [weak self] obj, chain, resi, on in
            guard let self else { return false }
            // Residue viz touches the core → must run on the main thread; the
            // controller already invokes this on the @MainActor.
            self.runPython("""
                from pymol import raymol_design as _rd
                _rd.set_residue_sticks('\(obj)', '\(chain)', '\(resi)', \(on ? 1 : 0))
                """)
            // On a show, read back whether WE added the sticks (residue had
            // none) so the controller only removes/restores ones we introduced.
            guard on else { return false }
            let path = (NSTemporaryDirectory() as NSString)
                .appendingPathComponent("raymol_design_sticks.json")
            guard let data = FileManager.default.contents(atPath: path),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return false }
            return (root["added"] as? Bool) ?? false
        },
        currentState: { [weak self] object in
            self?.objectMeta[object]?.state ?? 1
        },
        makeWorkingCopy: { [weak self] src in
            // I2: Python chooses the unique dst name via cmd.get_unused_name and writes
            // it to a temp JSON file; we read it back so we track the actual name.
            guard let self else { return src + "_design" }
            self.runPython("""
                from pymol import raymol_design as _rd
                _rd.make_working_copy('\(src)')
                """)
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("raymol_design_working.json")
            if let data = FileManager.default.contents(atPath: path.path),
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dst = root["dst"] as? String, !dst.isEmpty {
                return dst
            }
            return src + "_design"   // safe fallback
        },
        mutateDisplay: { [weak self] obj, chain, resi, aa in
            self?.runPython("""
                from pymol import raymol_design as _rd
                _rd.mutate_residue_display('\(obj)', '\(chain)', '\(resi)', \(aa))
                """)
        },
        discard: { [weak self] src, dst in
            // I2: src is now passed explicitly (stored as editSourceObject) instead of
            // being derived by stripping "_design", which breaks for uniquely-named copies.
            self?.runPython("""
                from pymol import raymol_design as _rd
                _rd.discard_working_copy('\(src)', '\(dst)')
                """)
        },
        enableOriginal: { [weak self] src in
            // Keep path: working copy is preserved; re-enable the original so it is visible.
            self?.runPython("from pymol import cmd as _c; _c.enable('\(src)')")
        },
        compare: { [weak self] on, sideBySide in
            guard let self else { return }
            // editSourceObject is the original (parent); focusObject after beginEditIfNeeded
            // is the working copy — we need the parent for set_compare's color-save/restore.
            // compare is always invoked on the @MainActor (from the @MainActor controller),
            // so MainActor.assumeIsolated is safe here.
            let src = MainActor.assumeIsolated { self.designController.editSourceObject } ?? ""
            guard !src.isEmpty else { return }
            self.runPython("""
                from pymol import raymol_design as _rd
                _rd.set_compare('\(src)', \(on ? 1 : 0), side_by_side=\(sideBySide ? 1 : 0))
                """)
        },
        resetCompare: { [weak self] src in
            guard let self, !src.isEmpty else { return }
            self.runPython("""
                from pymol import raymol_design as _rd
                _rd.reset_compare('\(src)')
                """)
        },
        repack: { [weak self] residues, seq in
            guard let self else {
                throw NSError(domain: "raymol.design", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Engine deallocated"])
            }
            let model = try self.loadedMPNNModel()
            return try MPNNRuntime.withMLXErrorsAsThrows { try model.repack(residues, sequence: seq).pdb }
        },
        loadRepacked: { [weak self] obj, pdb in
            // Write PDB to a temp file; Python reads it back to avoid multi-line
            // escaping in the runPython string (same marshalling as applyColoring).
            let path = (NSTemporaryDirectory() as NSString)
                .appendingPathComponent("raymol_repack.pdb")
            try? pdb.write(toFile: path, atomically: true, encoding: .utf8)
            self?.runPython("""
                from pymol import raymol_design as _rd
                with open('\(path)') as _f:
                    _rd.load_repacked('\(obj)', _f.read())
                """)
        },
        showAllSidechains: { [weak self] obj, on in
            self?.runPython("""
                from pymol import raymol_design as _rd
                _rd.show_all_sidechains('\(obj)', \(on ? 1 : 0))
                """)
        },
        pinnedIndicator: { [weak self] obj, chain, resi in
            // Commit the pinned residue to 'sele' (pink committed-selection pass) or clear it.
            // Uses the same idiom as pick_at: cmd.select('sele', ..., enable=1) for the committed
            // pink pass, or 'none'/enable=0 to clear. Runs on the @MainActor (called from
            // setPinned / exit / focus-change), so runPython is safe on the main thread.
            self?.runPython("""
                from pymol import raymol_design as _rd
                _rd.set_pinned_indicator('\(obj)', '\(chain)', '\(resi)')
                """)
        },
        designRegion: { [weak self] residues, fixed, native, omit, temperature in
            guard let self else {
                throw NSError(domain: "raymol.design", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Engine deallocated"])
            }
            let model = try self.loadedMPNNModel()
            var opts = MPNNModel.DesignOptions()
            opts.temperature = temperature   // slider-controlled sampling temperature
            opts.seed = nil                  // nil seed → non-deterministic (fresh each run)
            opts.fixedPositions = fixed
            opts.nativeSequence = native
            opts.omit = omit
            return try MPNNRuntime.withMLXErrorsAsThrows { try model.design(residues, options: opts).indices }
        },
        listSelections: { [weak self] obj, src, state in
            guard let self else { return [] }
            let srcArg = (src?.isEmpty == false) ? src! : ""
            self.runPython("""
                from pymol import raymol_design as _rd
                _rd.list_design_selections('\(obj)', \(state), src='\(srcArg)')
                """)
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("raymol_design_selections.json")
            guard let data = FileManager.default.contents(atPath: path.path),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = root["selections"] as? [[String: Any]] else { return [] }
            return arr.compactMap { d in
                guard let name = d["name"] as? String, let n = d["n"] as? Int else { return nil }
                return DesignSelectionOption(name: name, count: n)
            }
        },
        selectedIndices: { [weak self] obj, sel, src, state in
            guard let self else { return [] }
            let srcArg = (src?.isEmpty == false) ? src! : ""
            self.runPython("""
                from pymol import raymol_design as _rd
                _rd.selected_design_indices('\(obj)', '\(sel)', \(state), src='\(srcArg)')
                """)
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("raymol_design_selected.json")
            guard let data = FileManager.default.contents(atPath: path.path),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let idx = root["indices"] as? [Int] else { return [] }
            return idx
        },
        releaseModel: { [weak self] in
            // Called on DesignController's inference queue, which is the only
            // context that touches _mpnnModel — see loadedMPNNModel().
            self?._mpnnModel = nil
        }
        )
        // Propagate isCalculating into @Published isDesignCalculating so
        // PyMOLEngine.objectWillChange fires and ContentView (which observes engine)
        // re-renders to disable the mode controls during any MLX inference.
        // CombineLatest4 fires with the NEW value — unlike objectWillChange which fires
        // before the change — so no extra run-loop hop is required.
        // `assumeIsolated` is safe here: designController is always first accessed from
        // @MainActor code (UI callbacks, engine methods) and the pattern is already used
        // throughout this file (clearHoverPreview, designPickResidue, etc.).
        _designCalcCancellable = MainActor.assumeIsolated {
            Publishers.CombineLatest4(
                dc.$isScoring, dc.$isRescoring, dc.$isRedesigning, dc.$isRepacking)
                .map { $0 || $1 || $2 || $3 }
                .receive(on: RunLoop.main)
                .sink { [weak self] in self?.isDesignCalculating = $0 }
        }
        return dc
    }()
#endif

    // MARK: - Move mode (rigid-body object gizmo)

    /// Viewport aspect (width / height) for the gizmo projection. Falls back to
    /// 1.0 before the first reshape.
    var gizmoAspect: Float {
        let s = viewportPixelSize
        return s.height > 0 ? Float(s.width / s.height) : 1.0
    }

    func setInteractionMode(_ mode: InteractionMode) {
        #if RAYMOL_MPNN
        if MainActor.assumeIsolated({ designController.isCalculating }) { return }
        #endif
        interactionMode = mode
        if mode == .move {
            if measureMode != nil { setMeasureMode(nil) }   // mutually exclusive
            setDesignMode(false)                             // mutually exclusive
            refreshGizmo()
        } else {
            armedAxis = nil
            hoveredHandle = nil
            activeMoveObject = nil
            gizmo = nil
            // Clear lastAdjustSent FIRST. adjustFrameToggle and moveShiftHeld
            // both carry `didSet { syncAdjustFrame() }`, and syncAdjustFrame
            // calls readGizmo(), which re-reads the gizmo temp file — still
            // "active" here, because cleanup() below hasn't run yet. That
            // resurrects the gizmo and activeMoveObject just cleared above.
            // Zeroing lastAdjustSent first makes syncAdjustFrame's
            // `want != lastAdjustSent` guard early-return. The skipped
            // set_adjust(0) round-trip is redundant: cleanup() tears the whole
            // gizmo down a few lines later.
            lastAdjustSent = false
            adjustFrameToggle = false
            moveShiftHeld = false
            runPython("from pymol import metal_move as _mm\n_mm.cleanup()")
        }
    }

    /// Push adjust-frame mode to metal_move when it changes (overlay toggle or the
    /// Shift key). set_adjust rebuilds the gizmo (greys it / restores it).
    func syncAdjustFrame() {
        let want = adjustFrameActive
        guard want != lastAdjustSent else { return }
        lastAdjustSent = want
        runPython("from pymol import metal_move as _mm\n_mm.set_adjust(\(want ? 1 : 0))")
        readGizmo()
    }

    /// Clear the active object's custom gizmo frame → snap back to the auto frame.
    /// Distinct from resetActiveMovePosition (which resets the object's position).
    func resetGizmoFrame() {
        runPython("from pymol import metal_move as _mm\n_mm.reset_gizmo()")
        readGizmo()
    }

    /// Grab-what-you-touch: set the active object to whatever is under the point.
    func moveSetActiveAt(ndcX: Float, ndcY: Float, aspect: Float) {
        runPython("from pymol import metal_move as _mm\n_mm.pick_object(\(ndcX), \(ndcY), \(aspect))")
        readGizmo()
    }

    /// Explicitly set the active object (overlay dropdown).
    func setActiveMoveObject(_ name: String) {
        let nb = Data(name.utf8).base64EncodedString()
        runPython("import base64 as _b64\nfrom pymol import metal_move as _mm\n"
            + "_mm.set_active(_b64.b64decode('\(nb)').decode('utf-8'), \(gizmoAspect))")
        readGizmo()
    }

    /// Re-emit the gizmo geometry (after the camera changed).
    func refreshGizmo(aspect: Float? = nil) {
        guard interactionMode == .move else { return }
        runPython("from pymol import metal_move as _mm\n_mm.refresh(\(aspect ?? gizmoAspect))")
        readGizmo()
    }

    func toggleArmedAxis(_ h: GizmoHandle) {
        armedAxis = (armedAxis == h) ? nil : h
    }

    func gizmoBeginDrag(_ handle: GizmoHandle, ndcX: Float, ndcY: Float, aspect: Float) {
        runPython("from pymol import metal_move as _mm\n_mm.begin_drag('\(handle.pyName)', \(ndcX), \(ndcY), \(aspect))")
        readGizmo()
    }

    func gizmoUpdateDrag(ndcX: Float, ndcY: Float, aspect: Float) {
        // Mid-drag: only issue the move. Skip readGizmo() — metal_move deliberately
        // does NOT re-emit geometry per tick (the gizmo is a 3D CGO that tracks the
        // molecule via its synced TTT, and hit-testing is idle while a handle is
        // grabbed), so there is no file to read back. This keeps the drag as light
        // as a vanilla-GL matrix update; the continuous draw loop repaints from
        // PyMOL's redisplay flag. end_drag re-emits geometry for the next hit-test.
        runPython("from pymol import metal_move as _mm\n_mm.update_drag(\(ndcX), \(ndcY), \(aspect))")
    }

    func gizmoEndDrag() {
        runPython("from pymol import metal_move as _mm\n_mm.end_drag()")
        readGizmo()
    }

    func resetActiveMovePosition() {
        runPython("from pymol import metal_move as _mm\n_mm.reset_active()")
        readGizmo()
    }

    // Read the gizmo geometry metal_move wrote to the temp dir (same-process
    // TMPDIR), synchronously — called right after each metal_move call (the
    // longPressPick pattern). Updates the published gizmo + active object.
    private func readGizmo() {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("pymol_gizmo.json")
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        if (root["active"] as? Bool) == true, let g = GizmoGeometry(json: root) {
            // Only republish when the projected geometry actually changed. This is
            // called on every hover step (to keep the hit-test current against any
            // view change), so a static view must not fire objectWillChange each
            // move — that would churn every view observing the engine.
            if gizmo != g { gizmo = g }
            if activeMoveObject != g.obj { activeMoveObject = g.obj }
        } else {
            if gizmo != nil { gizmo = nil }
            if activeMoveObject != nil { activeMoveObject = nil }
        }
    }

    // MARK: - Settings panel

    func loadSettingsCatalog() {
        runPython("from pymol import appkit_settings as _as\n_as.catalog()")
    }

    func setSetting(_ name: String, _ value: String) {
        // base64 the name + value (see previewSelection): injection-safe.
        let nb = Data(name.utf8).base64EncodedString()
        let vb = Data(value.utf8).base64EncodedString()
        runPython("import base64 as _b64\nfrom pymol import appkit_settings as _as\n"
            + "_as.set_value(_b64.b64decode('\(nb)').decode('utf-8'), "
            + "_b64.b64decode('\(vb)').decode('utf-8'))")
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

    // MARK: - Hover pre-selection preview (issue #165)

    // Trailing coalescer for the hover re-pick so a fast mouse sweep collapses to
    // ~one pick every ~33 ms (mirrors MetalViewport.armPanEndDebounce). Plus a
    // last-NDC gate so a barely-moved pointer doesn't re-pick at all — the actual
    // projection over all atoms is the cost we're throttling.
    private var hoverWork: DispatchWorkItem?
    private var lastHoverNDC: (Float, Float)? = nil
    private var lastHoverFire = Date.distantPast
    private let kHoverInterval = 0.045        // leading-edge throttle: ≤~22 picks/s
    private let kHoverMinNDC: Float = 0.004   // sub-pixel move gate (NDC²-ish)
    // Separate throttle state for the design-mode hover path so it doesn't
    // interfere with the viewing-mode hover path's NDC gate / work item.
    #if RAYMOL_MPNN
    private var designHoverWork: DispatchWorkItem?
    private var lastDesignHoverNDC: (Float, Float)? = nil
    private var lastDesignHoverFire = Date.distantPast
    #endif

    /// Update the hover pre-selection preview to what a click at (ndcX,ndcY)
    /// would select, without committing to 'sele'. No-op while the feature is
    /// disabled. LEADING-EDGE throttled (+ trailing catch-up) so the preview
    /// tracks CONTINUOUSLY while the pointer sweeps — a pure trailing debounce
    /// only fired once the pointer paused, which read as "hover doesn't work".
    func hoverPreview(_ ndcX: Float, _ ndcY: Float, _ aspect: Float) {
        guard isReady, hoverPreviewEnabled else { return }
        if let last = lastHoverNDC {
            let dx = ndcX - last.0, dy = ndcY - last.1
            if abs(dx) < kHoverMinNDC && abs(dy) < kHoverMinNDC { return }
        }
        lastHoverNDC = (ndcX, ndcY)
        hoverWork?.cancel()
        let fire: () -> Void = { [weak self] in
            guard let self = self else { return }
            self.lastHoverFire = Date()
            self.runPython(
                "from pymol import metal_pick as _mp; "
                + "_mp.hover_preview_at(\(ndcX), \(ndcY), \(aspect))")
        }
        let elapsed = Date().timeIntervalSince(lastHoverFire)
        if elapsed >= kHoverInterval {
            fire()                                  // leading edge — update now
        } else {
            let work = DispatchWorkItem(block: fire) // trailing — final rest position
            hoverWork = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + (kHoverInterval - elapsed), execute: work)
        }
    }

    /// Cancel any pending hover pick and empty the preview selection. Cheap and
    /// idempotent — safe to call from mouse-down / drag-start / mouse-exit and
    /// when the user toggles the feature off.
    func clearHoverPreview() {
        hoverWork?.cancel()
        hoverWork = nil
        lastHoverNDC = nil
        #if RAYMOL_MPNN
        designHoverWork?.cancel()
        designHoverWork = nil
        lastDesignHoverNDC = nil
        if designMode { MainActor.assumeIsolated { designController.clearHover() } }
        #endif
        guard isReady else { return }
        // enable=0: never enable '_preselect' — enabling a selection is exclusive
        // and would disable the committed 'sele', hiding its markers. (The
        // renderer draws '_preselect' by membership regardless of enabled state.)
        runPython("from pymol import cmd as _c; _c.select('_preselect', 'none', enable=0)")
    }

    #if RAYMOL_MPNN
    /// Design-mode hover: identify the residue under the cursor, update
    /// _preselect for the cyan glow, and update the design controller's
    /// hoveredResidueIndex so the propensity pill row re-renders.
    /// Uses an independent leading-edge throttle (same rate as hoverPreview).
    func hoverDesignPreview(_ ndcX: Float, _ ndcY: Float, _ aspect: Float) {
        guard isReady else { return }
        if let last = lastDesignHoverNDC {
            let dx = ndcX - last.0, dy = ndcY - last.1
            if abs(dx) < kHoverMinNDC && abs(dy) < kHoverMinNDC { return }
        }
        lastDesignHoverNDC = (ndcX, ndcY)
        designHoverWork?.cancel()
        let fire: () -> Void = { [weak self] in
            guard let self else { return }
            self.lastDesignHoverFire = Date()
            self.runPython(
                "from pymol import metal_pick as _mp; "
                + "_mp.hover_design_at(\(ndcX), \(ndcY), \(aspect))")
            self.readDesignHoverHit()
        }
        let elapsed = Date().timeIntervalSince(lastDesignHoverFire)
        if elapsed >= kHoverInterval {
            fire()
        } else {
            let work = DispatchWorkItem(block: fire)
            designHoverWork = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + (kHoverInterval - elapsed), execute: work)
        }
    }

    /// Commit a Design-mode residue pick from a viewport tap (iOS). Calls the same
    /// Python hover pick that the hover path uses (hover_design_at writes the hit
    /// JSON synchronously), reads the result back, resolves a full-length residue
    /// index, and hands it to DesignController.tapResidue, which pins or edits the
    /// region per mode. Only acts when the hit lands on the current focus object.
    /// Runs on the main thread (UIKit tap callback); uses MainActor.assumeIsolated
    /// to satisfy Swift Concurrency's actor-isolation check (same pattern as
    /// readDesignHoverHit).
    func designPickResidue(ndcX: Float, ndcY: Float, aspect: Float) {
        guard designMode, isReady else { return }
        runPython("from pymol import metal_pick as _mp; _mp.hover_design_at(\(ndcX), \(ndcY), \(aspect))")
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("pymol_hover_design.json")
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hit = root["hit"] as? Bool, hit,
              let chain = root["chain"] as? String,
              let resi  = root["resi"]  as? String
        else { return }
        let focusObj = root["obj"] as? String ?? ""
        MainActor.assumeIsolated {
            designController.handleViewportHit(object: focusObj,
                                               chain: chain,
                                               resi: resi,
                                               hasResidue: true)   // guard above ensures hit==true
        }
    }

    /// Read back pymol_hover_design.json (written synchronously by hover_design_at)
    /// and update the design controller's hover state.
    /// Called from the fire closure which already runs on the main queue
    /// (DispatchQueue.main / @MainActor); uses MainActor.assumeIsolated to
    /// satisfy the Swift Concurrency actor-isolation check (macOS 14+).
    private func readDesignHoverHit() {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("pymol_hover_design.json")
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            MainActor.assumeIsolated { designController.clearHover() }
            return
        }
        let hit = (root["hit"] as? Bool) ?? false
        if hit {
            let obj   = root["obj"]   as? String ?? ""
            let chain = root["chain"] as? String ?? ""
            let resi  = root["resi"]  as? String ?? ""
            MainActor.assumeIsolated {
                if obj == designController.focusObject {
                    designController.setHovered(chain: chain, resi: resi)
                } else {
                    designController.clearHover()
                }
            }
        } else {
            MainActor.assumeIsolated { designController.clearHover() }
        }
    }
    #endif

    /// iOS long-press: identify the atom/residue under the press (read-only —
    /// does NOT change the selection) and publish it so ContentView can show the
    /// context menu. pick_info_at writes the hit JSON to the temp dir, which we
    /// read back synchronously (this runs on the main thread from the gesture).
    func longPressPick(ndcX: Float, ndcY: Float, aspect: Float) {
        guard isReady else { return }
        runPython("from pymol import metal_pick as _mp; _mp.pick_info_at(\(ndcX), \(ndcY), \(aspect))")
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("pymol_longpress.json")
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        let hit = (root["hit"] as? Bool) ?? false
        longPressHit = LongPressHit(
            isEmpty: !hit,
            obj: root["obj"] as? String ?? "",
            chain: root["chain"] as? String ?? "",
            resi: root["resi"] as? String ?? "",
            resn: root["resn"] as? String ?? "",
            name: root["name"] as? String ?? "",
            sel: root["sel"] as? String ?? "")
    }

    // MARK: - Render loop hooks (called by MetalViewport)

    func idle() {
        guard let inst = instance else { return }
        _ = PyMOLBridge_Idle(inst)
    }

    // Posted to force the MetalViewport off its on-demand gate for one frame.
    // The coordinator observes this (same handler as wake) and renders once
    // unconditionally. Needed when a command changes what's displayed but the
    // core's redisplay flag doesn't reach the next draw(in:) — notably a
    // per-object `set state` / movie `frame` scrub AFTER a movie exists, where
    // the flag is otherwise consumed before the gate checks it (issue #132).
    static let forceRedrawNotification = Notification.Name("PyMOLEngine.forceRedraw")

    // Request a single unconditional viewport repaint. Cheap (one extra frame);
    // safe during mplay (that path already renders every tick, so an extra
    // forced frame is a no-op there). Main-thread only — the coordinator kicks
    // an immediate draw() which must run on the UI thread.
    func requestViewportRedraw() {
        if Thread.isMainThread {
            NotificationCenter.default.post(name: PyMOLEngine.forceRedrawNotification, object: nil)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: PyMOLEngine.forceRedrawNotification, object: nil)
            }
        }
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

    // Absolute zoom: set the apparent magnification `mag` (independent of the Lens
    // control). Target camera distance = radius / (mag * tan(fov/2)); dolly the
    // camera there via move('z', current - target). `radius`/`fovDeg` come from the
    // scene poll (same values used to display the slider), so the target distance
    // is consistent with the shown magnification. move z + = camera moves in.
    func setZoomMagnification(_ mag: Double, radius: Double, fovDeg: Double) {
        guard isReady, radius > 0, mag > 0 else { return }
        let t = tan(fovDeg * .pi / 360.0)
        guard t > 1e-6 else { return }
        let target = radius / (mag * t)
        guard target.isFinite, target > 0.01 else { return }
        runPython("from pymol import cmd as _zc\n"
            + "_zv = _zc.get_view()\n"
            + "_cur = abs(_zv[11])\n"
            + "_zc.move('z', _cur - \(target))")
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
        // While a movie export owns the core off the main thread, skip polling —
        // reading feedback here is a core access that would race the exclusive
        // exporter (which reshapes global state). The exporter drives its own
        // progress, so nothing is lost. (#58 L-59)
        if exportRenderActive { return }
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

    // Run MCP tool work queued from the in-process server's HTTP request threads
    // on THIS (main) thread — the only thread where touching the embedded core is
    // safe (off-main cmd calls race SceneRenderMetal / corrupt the interpreter).
    // raymol_mcp.mainthread.run_on_main enqueues from the handler thread and blocks
    // until we drain here, once per ~100ms Timer tick. Gated on the server running
    // so there's no per-tick bridge call when MCP is off. A queued op runs
    // synchronously (it can block this tick — the same on-main invariant runHeavy
    // relies on); when idle the drain is an instant empty-queue check.
    private func drainMCPMainQueue() {
        #if os(macOS) && !RAYMOL_MAS_RESTRICTED
        guard isReady, MCPServerManager.shared.isRunning else { return }
        PyMOLBridge_RunPython("import raymol_mcp.mainthread as _mt; _mt.drain_main_thread_queue()")
        #endif
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
        // the log and starves the UI. The print('OBJPANEL:ready') still reaches
        // the feedback buffer (parsed by pollFeedback); only the echo is avoided.
        // poll_panel writes the list to a temp file and prints just that marker,
        // so the payload can't overflow the ~1KB feedback-line cap (#231).
        runPython("from pymol import appkit_inspector as _ai\n_ai.poll_panel()")

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
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("pymol_objdetail_\(ProcessInfo.processInfo.processIdentifier).json")
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
                    var settingColors: [String: String] = [:]
                    if let cols = r["colors"] as? [String: Any] {
                        for (k, v) in cols { settingColors[k] = v as? String ?? "inherit" }
                    }
                    var atomTransp: AtomTransp? = nil
                    if let at = r["atom_transp"] as? [String: Any],
                       let setting = at["setting"] as? String {
                        atomTransp = AtomTransp(
                            setting: setting,
                            min: (at["min"] as? NSNumber)?.doubleValue ?? 0,
                            max: (at["max"] as? NSNumber)?.doubleValue ?? 0)
                    }
                    return RepState(
                        rep: r["rep"] as? String ?? "",
                        visible: ((r["vis"] as? NSNumber)?.intValue ?? 1) != 0,
                        values: values,
                        color: r["color"] as? String ?? "inherit",
                        settingColors: settingColors,
                        atomTransp: atomTransp)
                }
            }
        }

        var scene = SceneState()
        if let sc = root["scene"] as? [String: Any] {
            for (k, v) in sc {
                if k == "bg", let arr = v as? [Any] {
                    scene.bg = arr.map { ($0 as? NSNumber)?.doubleValue ?? 0 }
                } else if k == "outline_rgb", let arr = v as? [Any] {
                    scene.outlineColor = arr.map { ($0 as? NSNumber)?.doubleValue ?? 0 }
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
                    overlayAll: ((m["all"] as? NSNumber)?.intValue ?? 0) != 0,
                    titles: (m["titles"] as? [Any])?.map { $0 as? String ?? "" } ?? [])
            }
        }

        // Note-linked full-scene bookmarks are implementation details. Keep them
        // inside the .pse for reliable restoration without cluttering the user's
        // Scenes panel, timeline composer, or viewport scene chips.
        let scenes = ((root["scenes"] as? [String]) ?? [])
            .filter { !$0.hasPrefix("__raymol_note_") }
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
