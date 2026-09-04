// ObjectPanel.swift — Object/selection list with A/S/H/L/C action buttons
// SwiftUI replacement for modules/pymol/appkit_object_panel.py

import SwiftUI
import Combine
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

// Touch-vs-pointer control sizing: the panel is dense for a mouse on macOS;
// iPad needs larger hit targets (~Apple's 44pt guidance, balanced against the
// row count). One set of constants drives the action buttons, row height, and
// the leading gutter (expand chevron / visibility toggle).
#if os(iOS)
private let kActBtnW: CGFloat = 42
private let kActBtnH: CGFloat = 40
private let kRowH: CGFloat = 46
private let kGutterW: CGFloat = 40
#else
// macOS: match the iPhone's clearly-boxed A/S/H/L/C cells (the old 22×18 was so
// small the button background barely read as a box). Slightly denser rows than
// iOS since it's pointer-driven.
private let kActBtnW: CGFloat = 38
private let kActBtnH: CGFloat = 30
private let kRowH: CGFloat = 34
private let kGutterW: CGFloat = 26
#endif

// Per-level indent for nested group members (#255), and the depth at which
// indenting stops. Same width as the disclosure column every row already leads
// with, so a member's chevron lines up under its parent's name. Capped because
// the panel is ~300pt on macOS and narrower on a compact iPhone — past three
// levels the name column would be crushed, so deeper nesting stops moving right.
private let kIndentW: CGFloat = 13
private let kMaxIndentDepth: Int = 3

// MARK: - Representation inspector: polled state models
// (Inlined here rather than a separate file so they're in both app targets
// without editing the Xcode project's explicit file references.)

/// One active representation on an object, with current setting values + color.
struct RepState: Equatable {
    let rep: String                 // "cartoon", "surface", …
    var visible: Bool
    var values: [String: Double]    // setting name → current value
    var color: String               // "inherit" or "#rrggbb"
    var settingColors: [String: String] = [:]  // extra color settings → "inherit"/"#rrggbb"
    // Present when this rep has per-atom transparency overriding the object-level
    // slider; carries the transparency setting name and the effective min–max range.
    var atomTransp: AtomTransp? = nil
}

/// Effective per-atom transparency range for a rep whose object-level slider is
/// overridden by atom-level settings (from appkit_inspector's `atom_transp`).
struct AtomTransp: Equatable {
    let setting: String   // e.g. "cartoon_transparency"
    let min: Double
    let max: Double
}

/// Global "Scene" parameters.
struct SceneState: Equatable {
    var values: [String: Double] = [:]   // setting name → value (toggles 0/1)
    var bg: [Double] = [0, 0, 0]         // background r,g,b in 0…1
    var outlineColor: [Double] = [0, 0, 0]  // metal_outline_color r,g,b in 0…1
}

/// Per-object state metadata for the inspector STATE row (multi-state objects).
struct ObjStateMeta: Equatable {
    var state: Int = 1        // effective current state (resolves the frame)
    var overlayAll: Bool = false   // all_states overlay for this object
    // Per-state titles (e.g. compound names from a multi-record SDF). Empty
    // unless at least one state carries a title. Indexed by state-1 (issue #203).
    var titles: [String] = []

    /// Title for a 1-based state, or nil when none/blank.
    func title(forState state: Int) -> String? {
        guard state >= 1, state <= titles.count else { return nil }
        let t = titles[state - 1]
        return t.isEmpty ? nil : t
    }
}

// MARK: - Representation inspector: control metadata

enum RepControlKind { case slider, segmented, toggle, color }

/// One controllable property row (label + control bound to a PyMOL setting).
struct RepProperty: Identifiable {
    var id: String { setting }
    let setting: String
    let label: String
    let kind: RepControlKind
    var min: Double = 0
    var max: Double = 1
    var step: Double = 0.01
    var decimals: Int = 2
    var options: [(label: String, value: Double)] = []   // for .segmented
    // Apply only on release (not on every live drag tick). For settings whose
    // change forces an expensive rebuild (e.g. solvent_radius re-tessellates the
    // whole surface), live updates would recompute on every drag step.
    var commitOnly: Bool = false
}

/// Static description of a representation: display name, color-override setting
/// (empty = no per-rep color), and the property rows it exposes. Setting names
/// MUST match modules/pymol/appkit_inspector.py.
struct RepSpec {
    let rep: String
    let display: String
    let colorSetting: String     // e.g. "surface_color"; "" if none
    let defaultColor: Int        // value meaning "inherit" (-1, labels -6)
    let properties: [RepProperty]
}

enum RepCatalog {
    static let order = ["cartoon", "surface", "sticks", "spheres", "ribbon",
                        "mesh", "lines", "dots", "nonbonded", "nb_spheres", "labels"]

    static let specs: [String: RepSpec] = [
        "cartoon": RepSpec(rep: "cartoon", display: "Cartoon",
            colorSetting: "cartoon_color", defaultColor: -1, properties: [
                RepProperty(setting: "cartoon_transparency", label: "Transparency", kind: .slider),
                RepProperty(setting: "cartoon_loop_radius",   label: "Loop radius",  kind: .slider),
                RepProperty(setting: "cartoon_tube_radius",   label: "Tube radius",  kind: .slider),
                RepProperty(setting: "cartoon_fancy_helices", label: "Fancy helices", kind: .toggle),
                RepProperty(setting: "cartoon_flat_sheets",   label: "Flat sheets",   kind: .toggle),
                RepProperty(setting: "cartoon_spline",        label: "Spline ribbon", kind: .toggle),
            ]),
        "surface": RepSpec(rep: "surface", display: "Surface",
            colorSetting: "surface_color", defaultColor: -1, properties: [
                RepProperty(setting: "transparency",   label: "Transparency", kind: .slider),
                RepProperty(setting: "surface_quality", label: "Quality", kind: .segmented,
                            options: [("0", 0), ("1", 1), ("2", 2)]),
                RepProperty(setting: "solvent_radius", label: "Solvent radius", kind: .slider, min: 0.5, max: 3, step: 0.1, decimals: 1, commitOnly: true),
                RepProperty(setting: "surface_clip_front", label: "Clip front", kind: .slider, min: 0, max: 1, step: 0.02, decimals: 2),
                RepProperty(setting: "surface_clip_back", label: "Clip back", kind: .slider, min: 0, max: 1, step: 0.02, decimals: 2),
                RepProperty(setting: "metal_interior_cap", label: "Solid interior", kind: .toggle),
                RepProperty(setting: "surface_contour", label: "Contour", kind: .toggle),
                RepProperty(setting: "surface_contour_width", label: "Contour width", kind: .slider, min: 0.5, max: 6, step: 0.5, decimals: 1),
                RepProperty(setting: "surface_contour_color", label: "Contour color", kind: .color),
                RepProperty(setting: "surface_contour_opaque", label: "Contour opaque", kind: .toggle),
            ]),
        "sticks": RepSpec(rep: "sticks", display: "Sticks",
            colorSetting: "stick_color", defaultColor: -1, properties: [
                RepProperty(setting: "stick_transparency", label: "Transparency", kind: .slider),
                RepProperty(setting: "stick_radius",   label: "Radius",  kind: .slider),
                RepProperty(setting: "stick_h_scale",  label: "H scale", kind: .slider),
                RepProperty(setting: "metal_interior_cap", label: "Solid interior", kind: .toggle),
            ]),
        "spheres": RepSpec(rep: "spheres", display: "Spheres",
            colorSetting: "sphere_color", defaultColor: -1, properties: [
                RepProperty(setting: "sphere_transparency", label: "Transparency", kind: .slider),
                RepProperty(setting: "sphere_scale", label: "Scale", kind: .slider, max: 3, step: 0.05),
                RepProperty(setting: "metal_interior_cap", label: "Solid interior", kind: .toggle),
            ]),
        "ribbon": RepSpec(rep: "ribbon", display: "Ribbon",
            colorSetting: "ribbon_color", defaultColor: -1, properties: [
                RepProperty(setting: "ribbon_transparency", label: "Transparency", kind: .slider),
                RepProperty(setting: "ribbon_width", label: "Width", kind: .slider, max: 6, step: 0.1, decimals: 1),
            ]),
        "mesh": RepSpec(rep: "mesh", display: "Mesh",
            colorSetting: "mesh_color", defaultColor: -1, properties: [
                RepProperty(setting: "transparency", label: "Transparency", kind: .slider),
                RepProperty(setting: "mesh_width", label: "Width", kind: .slider, max: 2, step: 0.05),
            ]),
        "lines": RepSpec(rep: "lines", display: "Lines",
            colorSetting: "line_color", defaultColor: -1, properties: [
                RepProperty(setting: "line_width", label: "Width", kind: .slider, min: 0.5, max: 10, step: 0.5, decimals: 1),
            ]),
        "dots": RepSpec(rep: "dots", display: "Dots",
            colorSetting: "dot_color", defaultColor: -1, properties: [
                RepProperty(setting: "transparency", label: "Transparency", kind: .slider),
                RepProperty(setting: "dot_density", label: "Density", kind: .segmented,
                            options: [("0", 0), ("1", 1), ("2", 2), ("3", 3)]),
                RepProperty(setting: "dot_radius", label: "Radius", kind: .slider, max: 1, step: 0.05),
            ]),
        "nonbonded": RepSpec(rep: "nonbonded", display: "Nonbonded",
            colorSetting: "", defaultColor: -1, properties: [
                RepProperty(setting: "nonbonded_size", label: "Size", kind: .slider, max: 1, step: 0.05),
            ]),
        "nb_spheres": RepSpec(rep: "nb_spheres", display: "NB spheres",
            colorSetting: "", defaultColor: -1, properties: [
                RepProperty(setting: "nb_spheres_size", label: "Size", kind: .slider, max: 1, step: 0.05),
            ]),
        "labels": RepSpec(rep: "labels", display: "Labels",
            colorSetting: "label_color", defaultColor: -6, properties: [
                RepProperty(setting: "label_size", label: "Size", kind: .slider, min: 5, max: 40, step: 1, decimals: 0),
            ]),
    ]

    static func spec(_ rep: String) -> RepSpec? { specs[rep] }
    static func display(_ rep: String) -> String { specs[rep]?.display ?? rep }
}

// MARK: - Scene (global) parameter table

struct SceneParam: Identifiable {
    var id: String { setting }
    let setting: String
    let label: String
    let kind: RepControlKind
    var min: Double = 0
    var max: Double = 1
    var step: Double = 1
    var decimals: Int = 0
    var options: [(label: String, value: Double)] = []
    let group: String
    // When set, this control is a dependent sub-setting: shown indented under
    // its parent toggle and hidden while the parent (a setting key) is off.
    var dependsOn: String? = nil
    // Color rows (Background, Outline color) bind to sceneState.bg /
    // .outlineColor via a ColorPicker instead of the kind switch.
    var isColor: Bool = false
    // One-line description shown in a (?) popover next to the control.
    var help: String = ""
}

// Camera-control command strings shared by the inspector row and the camera dock,
// so the DOF auto-lock action has a single source of truth.
enum CameraCommands {
    // Auto-lock focus: enabling snapshots the current selection into "dof_focus"
    // (the target the renderer tracks each frame); disabling just clears the flag.
    static func setAutofocus(_ on: Bool) -> String {
        on ? "select dof_focus, (sele)\nset metal_dof_autofocus, 1"
           : "set metal_dof_autofocus, 0"
    }

    // Auto-lock focus on a specific selection: retarget "dof_focus" to `sel` and
    // enable DOF + autofocus so the lock is immediately visible.
    static func lockFocus(on sel: String) -> String {
        "select dof_focus, (\(sel))\nset metal_dof, 1\nset metal_dof_autofocus, 1"
    }
}

enum SceneCatalog {
    // Ordered sub-groups shown inside the SCENE section (see panel reorg).
    static let groups = ["Canvas", "Camera", "Lighting", "Shadows & AO", "Metal optimization", "Effects", "Quality"]
    // Viewport camera dock (see CameraDock): the always-visible strip icons, in
    // order. DOF's sub-controls are rendered by DOFSubPanelContent, not as strip
    // icons. metal_dof_quality is intentionally absent — it defaults to best (4)
    // and lives only in the inspector's Scene → Camera group.
    static let cameraStripKeys = ["field_of_view", "zoom", "metal_dof"]

    // SF Symbol for each strip control.
    static func cameraIcon(for setting: String) -> String {
        switch setting {
        case "field_of_view": return "camera.aperture"
        case "zoom":          return "plus.magnifyingglass"
        case "ortho":         return "cube"
        case "metal_dof":     return "camera.metering.center.weighted"
        default:              return "slider.horizontal.3"
        }
    }

    static func param(for setting: String) -> SceneParam? {
        params.first { $0.setting == setting }
    }
    static let params: [SceneParam] = [
        // --- Canvas: background + multi-object/state layout ---
        SceneParam(setting: "bg_rgb",     label: "Background", kind: .toggle, group: "Canvas", isColor: true,
                   help: "Viewport background color."),
        // grid_mode is an int (0=off, 1=by object, 2=by state); the toggle maps
        // off→0 / on→1 and reads on for any non-zero mode.
        SceneParam(setting: "grid_mode",  label: "Grid", kind: .toggle, group: "Canvas",
                   help: "Lay each object out in its own grid cell instead of overlaid in one view."),
        SceneParam(setting: "all_states", label: "Overlay all states", kind: .toggle, group: "Canvas",
                   help: "Show every coordinate state (NMR models / trajectory frames) at once."),
        // Not a PyMOL setting — bound to engine.hoverPreviewEnabled (see SceneParamRow's
        // special-case) and persisted across launches. Same control as Mouse ▸ Hover.
        SceneParam(setting: "hover_indicator", label: "Hover indicator", kind: .toggle, group: "Canvas",
                   help: "Highlight the residue under the cursor (nearest Cα) before you click, in a distinct cyan — without changing the selection. Also on the Mouse panel; persists across launches."),
        // Also not a PyMOL setting — bound to engine.hoverReadoutEnabled (#359).
        SceneParam(setting: "hover_readout", label: "Hover readout", kind: .toggle, group: "Canvas",
                   help: "Name whatever the cursor is over in the viewport's top-right corner, at the current selection level — object, chain, segment, residue or atom. Persists across launches."),

        // --- Camera: viewpoint + lens ---
        SceneParam(setting: "field_of_view", label: "Lens (mm)", kind: .slider, min: 12, max: 135, step: 0.5, decimals: 0, group: "Camera",
                   help: "Focal length (35mm-equivalent). Like swapping physical lenses: the camera dollies to keep the subject framed, so a short/wide lens (~12mm) exaggerates perspective (fisheye) and a long lens (~135mm) flattens it (macro/telephoto). Drag for a live, continuous perspective change. Pinch to zoom. No effect in orthoscopic mode."),
        SceneParam(setting: "zoom", label: "Zoom (×)", kind: .slider, min: 0.5, max: 8, step: 0.1, decimals: 1, group: "Camera",
                   help: "Apparent magnification — dollies the camera closer/farther. ~1× fits the whole scene; higher zooms in. Independent of the Lens: changing perspective (dolly-zoom) leaves this put, and vice-versa. Pinch to zoom also updates it."),
        SceneParam(setting: "ortho", label: "Orthographic", kind: .toggle, group: "Camera",
                   help: "Orthographic (parallel) projection — no perspective. Disables the Lens control."),
        SceneParam(setting: "metal_dof", label: "Depth of field", kind: .toggle, group: "Camera",
                   help: "Blur objects in front of and behind the focal plane for a photographic bokeh look."),
        SceneParam(setting: "metal_dof_autofocus", label: "Auto lock focus", kind: .toggle, group: "Camera", dependsOn: "metal_dof",
                   help: "Lock focus onto the current selection and keep it sharp as you zoom/rotate. Select an element, then turn this on to snapshot it (it stays locked even if you select elsewhere; toggle off→on to re-target). No selection → focuses the center of interest. Overrides the focus slider."),
        SceneParam(setting: "metal_dof_focus", label: "DOF focus (0=auto)", kind: .slider, min: 0, max: 120, step: 1, decimals: 0, group: "Camera", dependsOn: "metal_dof",
                   help: "Distance of the in-focus plane (eye-space units). 0 = auto-focus on the center of interest. Disabled while Autofocus is on."),
        SceneParam(setting: "metal_dof_range", label: "DOF range", kind: .slider, min: 1, max: 60, step: 0.5, decimals: 1, group: "Camera", dependsOn: "metal_dof",
                   help: "How far beyond focus before blur reaches maximum. Smaller = sharper falloff."),
        SceneParam(setting: "metal_dof_aperture", label: "DOF aperture (blur)", kind: .slider, min: 0, max: 40, step: 1, decimals: 0, group: "Camera", dependsOn: "metal_dof",
                   help: "Maximum out-of-focus blur (bokeh radius). Larger = stronger blur."),
        SceneParam(setting: "metal_dof_quality", label: "DOF quality", kind: .slider, min: 1, max: 4, step: 1, decimals: 0, group: "Camera", dependsOn: "metal_dof",
                   help: "Bokeh quality: higher traces more gather samples (1→16, 2→32, 3→64, 4→96) for denser, cleaner out-of-focus blur; levels 2+ add a de-noise pass. 1 = fastest single-pass, 4 = smoothest (GPU-heavy)."),

        // --- Lighting: real-time lighting model + shading ---
        SceneParam(setting: "ambient",   label: "Ambient",  kind: .slider, min: 0, max: 1, step: 0.01, decimals: 2, group: "Lighting",
                   help: "Baseline fill light hitting all surfaces evenly, even in shadow."),
        SceneParam(setting: "direct",    label: "Direct",   kind: .slider, min: 0, max: 1, step: 0.01, decimals: 2, group: "Lighting",
                   help: "Strength of the main directional light."),
        SceneParam(setting: "reflect",   label: "Reflect",  kind: .slider, min: 0, max: 1, step: 0.01, decimals: 2, group: "Lighting",
                   help: "Overall diffuse reflectivity of surfaces."),
        SceneParam(setting: "specular",  label: "Specular", kind: .slider, min: 0, max: 1, step: 0.01, decimals: 2, group: "Lighting",
                   help: "Intensity of shiny specular highlights."),
        SceneParam(setting: "shininess", label: "Shininess", kind: .slider, min: 0, max: 100, step: 1, decimals: 0, group: "Lighting",
                   help: "Tightness of specular highlights. Higher = smaller, sharper glints."),
        SceneParam(setting: "metal_sss_wrap", label: "Subsurface wrap", kind: .slider, min: 0, max: 1, step: 0.05, decimals: 2, group: "Lighting",
                   help: "Wraps light past the terminator for a soft, waxy/translucent look. 0 = plain Lambert."),

        // --- Shadows & AO: screen-space (non-RT) shadows + occlusion ---
        SceneParam(setting: "metal_shadows", label: "Shadows", kind: .toggle, group: "Shadows & AO",
                   help: "Real-time screen-space directional shadows."),
        SceneParam(setting: "metal_ssao",    label: "Ambient occlusion", kind: .toggle, group: "Shadows & AO",
                   help: "Screen-space ambient occlusion — darkens crevices and contact points for depth."),

        // --- Metal optimization: hardware ray tracing + GPU quality/perf knobs ---
        SceneParam(setting: "metal_raytrace", label: "Ray tracing (AO + shadows)", kind: .toggle, group: "Metal optimization",
                   help: "Hardware ray tracing for higher-quality ambient occlusion and shadows. Requires a supported GPU; it powers the options below."),
        SceneParam(setting: "metal_rt_shadows", label: "RT hard shadows", kind: .toggle, group: "Metal optimization", dependsOn: "metal_raytrace",
                   help: "Trace crisp hard shadow rays instead of the shadow-map approximation. Needs ray tracing on."),
        SceneParam(setting: "metal_temporal_ao", label: "Temporal AO", kind: .toggle, group: "Metal optimization", dependsOn: "metal_raytrace",
                   help: "Accumulate ray-traced AO across frames while the view is still, for cleaner, smoother occlusion. Needs ray tracing on."),
        SceneParam(setting: "metal_rt_samples", label: "RT quality (rays)", kind: .slider, min: 4, max: 128, step: 4, decimals: 0, group: "Metal optimization", dependsOn: "metal_raytrace",
                   help: "Ambient-occlusion rays traced per pixel in the live view. Higher is smoother but slower — lower it on mobile for speed (exports always use at least 48)."),
        SceneParam(setting: "metal_rt_scale", label: "RT resolution", kind: .slider, min: 0.25, max: 1, step: 0.25, decimals: 2, group: "Metal optimization", dependsOn: "metal_raytrace",
                   help: "Resolution of the ray-traced AO and shadow pass in the live view, as a fraction of the window. 0.5 traces a quarter of the rays and is hard to tell apart after the composite blur; 1 is full resolution. Exports always render at full resolution."),
        SceneParam(setting: "metal_rt_ao_radius", label: "AO radius (Å)", kind: .slider, min: 1, max: 15, step: 0.5, decimals: 1, group: "Metal optimization", dependsOn: "metal_raytrace",
                   help: "How far ambient occlusion reaches, in Angstroms. Larger darkens broad pockets and cavities; smaller keeps it to tight contact creases."),
        SceneParam(setting: "metal_rt_ao_intensity", label: "AO strength", kind: .slider, min: 0, max: 1, step: 0.02, decimals: 2, group: "Metal optimization", dependsOn: "metal_raytrace",
                   help: "Ambient-occlusion darkening amount."),
        SceneParam(setting: "metal_rt_shadow_intensity", label: "RT shadow strength", kind: .slider, min: 0, max: 1, step: 0.02, decimals: 2, group: "Metal optimization", dependsOn: "metal_raytrace",
                   help: "Cast-shadow darkening amount (still needs Shadows on)."),
        SceneParam(setting: "metal_msaa",   label: "MSAA 4×", kind: .toggle, group: "Metal optimization",
                   help: "4× multisample antialiasing — smoother edges at some GPU cost."),
        SceneParam(setting: "metal_upscale", label: "Reduced-res upscale", kind: .toggle, group: "Metal optimization",
                   help: "Render at reduced resolution and upscale (MetalFX) for better performance on slower GPUs."),

        // --- Effects: stylization + post-processing ---
        SceneParam(setting: "metal_outline", label: "Outline", kind: .toggle, group: "Effects",
                   help: "Draw a silhouette / toon outline around objects."),
        SceneParam(setting: "metal_outline_color", label: "Outline color", kind: .toggle, group: "Effects", dependsOn: "metal_outline", isColor: true,
                   help: "Color of the outline contour."),
        SceneParam(setting: "metal_outline_width", label: "Outline width", kind: .slider, min: 0.5, max: 5.0, step: 0.1, decimals: 1, group: "Effects", dependsOn: "metal_outline",
                   help: "Thickness of the outline, in pixels."),
        SceneParam(setting: "metal_tonemap", label: "Filmic tone-map", kind: .toggle, group: "Effects",
                   help: "ACES filmic tone-mapping for a cinematic look with a softer highlight rolloff."),
        // Always shown (NOT gated behind metal_tonemap): the renderer applies
        // exposure independently of the tone-map toggle (RendererMetal runs the
        // pass whenever exposure != 1), so hiding the slider when tone-map is off
        // could strand a dimmed value with no way to fix it in the UI.
        SceneParam(setting: "metal_exposure", label: "Exposure", kind: .slider, min: 0.2, max: 2.0, step: 0.05, decimals: 2, group: "Effects",
                   help: "Brightness multiplier (1.0 = neutral). Applies whether or not filmic tone-map is on."),
        SceneParam(setting: "depth_cue",  label: "Depth cue / fog", kind: .toggle, group: "Effects",
                   help: "Fade distant parts of the scene into the background to convey depth."),

        // --- Quality: tessellation ---
        SceneParam(setting: "surface_quality", label: "Surface quality", kind: .segmented,
                   options: [("0", 0), ("1", 1), ("2", 2)], group: "Quality",
                   help: "Surface mesh detail: 0 = coarse/fast, 2 = fine/slow."),
    ]
}

// MARK: - Data Models

/// Represents a PyMOL object or selection in the panel
struct ObjectEntry: Identifiable, Equatable {
    let id: String
    let name: String
    var isEnabled: Bool
    var isSelection: Bool
    var atomCount: Int?
    // Number of coordinate states (NMR models / trajectory frames). >1 surfaces
    // the per-object STATE controls in the inspector. Defaults to 1.
    var stateCount: Int = 1
    // True when an active rep has per-atom transparency overrides — drives the
    // discoverability badge, since the object-level transparency slider then
    // doesn't reflect what's rendered. See appkit_inspector.object_has_atom_transp.
    var hasAtomTransp: Bool = false
    // Group tree (#255). `isGroup` marks an `object:group`; `parent` is the name
    // of the group this row lives in (nil = top level). Both default so the
    // existing memberwise initializers keep compiling.
    var isGroup: Bool = false
    var parent: String? = nil
    // Structure prediction (#224): an empty placeholder waiting on a running job.
    // Its enable-toggle is disabled — there is nothing to show yet — and
    // `pendingDetail` is the hover tooltip describing the job's progress. Defaults keep
    // the existing memberwise initializers compiling.
    var isPending: Bool = false
    var pendingDetail: String? = nil

    var displayName: String {
        if isSelection, let count = atomCount {
            return "\(name) (\(count))"
        }
        return name
    }
}

// MARK: - Alignments (#296)

/// One loaded multiple-sequence alignment.
///
/// Deliberately NOT an `ObjectEntry`. An alignment has no geometry, nothing in the
/// Executive knows about it, and not one of A/S/H/L/C means anything for it — so it
/// gets its own type and its own section rather than a row that looks actionable and
/// is not. Everything here was computed once, at load time, on the Python side: the
/// panel polls every 500 ms and must never make anyone re-read an a3m to draw a row.
struct AlignmentEntry: Identifiable, Equatable {
    let id: String
    let name: String
    /// Sequences, AFTER duplicate rows are dropped — what the featurizer will see.
    let depth: Int
    /// Aligned columns, which is the query's length with its gaps.
    let columns: Int
    /// The query's length without them.
    let residues: Int
    /// Object and chain this alignment was attached to, by NAME: renaming or deleting
    /// the object does not update it, so this can outlive what it points at.
    let target: String
    let chain: String

    /// "8 × 24" — sequences by columns.
    var shape: String { "\(depth) × \(columns)" }

    var attachment: String? {
        guard !target.isEmpty else { return nil }
        return chain.isEmpty ? target : "\(target)/\(chain)"
    }
}

/// One MSA search still running (#298).
///
/// A search takes MINUTES and produces nothing until it lands, so without a row for it
/// the panel is silent for the whole time — and because the ALIGNMENTS section hides
/// itself when empty, a user's first search shows no sign of anything happening at all.
///
/// Carries no progress fraction because the ColabFold server reports none. The phase
/// and the age are what is actually known, and showing a bar derived from neither would
/// be a plausible-looking lie.
struct MSASearchEntry: Identifiable, Equatable {
    let id: String
    /// The name the alignment will land under, so the row and its result read the same.
    let name: String
    /// submit | queued | search | download | read | cached
    let phase: String
    let server: String
    /// Seconds since the search began, quantised by the Python side — see
    /// `appkit_inspector.SEARCH_ELAPSED_BUCKET` for why it is not the raw value.
    let elapsed: Int

    /// "searching" — what the phase means to someone who did not write it.
    var phaseText: String {
        switch phase {
        case "submit": return "submitting"
        case "queued": return "queued"
        case "search": return "searching"
        case "download": return "downloading"
        case "read": return "reading"
        case "cached": return "cached"
        default: return phase
        }
    }

    /// "searching · 2m 15s". Coarse on purpose; see the type comment.
    var detail: String {
        guard elapsed > 0 else { return phaseText }
        let minutes = elapsed / 60, seconds = elapsed % 60
        let age = minutes > 0 ? "\(minutes)m \(String(format: "%02d", seconds))s"
                              : "\(seconds)s"
        return "\(phaseText) · \(age)"
    }
}

// MARK: - Group tree (#255)

/// One drawn row of the flattened object tree.
private struct TreeRow: Identifiable {
    let entry: ObjectEntry
    let depth: Int
    var id: String { entry.id }
}

/// Three-way visibility state. A group summarises its descendants, so it can be
/// partially on in a way a single object never is.
private enum CheckState { case on, off, mixed }

/// Flatten the object list into the rows the panel draws, parents before children.
///
/// `engine.objects` mirrors PyMOL's own ordering and must NOT be reordered in
/// place — `parseObjectPanelFeedback`'s equality guard and `setObjectEnabled`'s
/// index lookup both assume it does. So nesting is derived here, at render time.
///
/// Children of a *collapsed* group are omitted entirely, which is what makes the
/// disclosure a real collapse rather than a styling choice. Two robustness rules:
/// an entry whose parent is not in the list is drawn at top level, and anything
/// left unreachable (a cycle from a corrupt parent map) is drawn at top level too
/// — an object must never silently disappear from the panel.
private func flattenObjectTree(_ objects: [ObjectEntry],
                               openGroups: Set<String>) -> [TreeRow] {
    let known = Set(objects.map { $0.name })
    let byParent = Dictionary(grouping: objects.filter {
        if let p = $0.parent { return known.contains(p) } else { return false }
    }, by: { $0.parent! })

    let roots = objects.filter { $0.parent == nil || !known.contains($0.parent!) }

    // Reachability ignores open/closed, so a collapsed child is not mistaken for
    // an orphan and re-emitted at top level.
    var reachable = Set<String>()
    func mark(_ name: String) {
        guard !reachable.contains(name) else { return }
        reachable.insert(name)
        for c in byParent[name] ?? [] { mark(c.name) }
    }
    for r in roots { mark(r.name) }

    var rows: [TreeRow] = []
    func emit(_ entry: ObjectEntry, _ depth: Int) {
        rows.append(TreeRow(entry: entry, depth: depth))
        guard entry.isGroup, openGroups.contains(entry.name) else { return }
        for child in byParent[entry.name] ?? [] { emit(child, depth + 1) }
    }
    for r in roots { emit(r, 0) }
    for entry in objects where !reachable.contains(entry.name) { emit(entry, 0) }
    return rows
}

/// True when every ancestor of `entry` is enabled.
///
/// A member keeps reporting `enabled` while it is hidden by a disabled parent —
/// `disable grp` leaves `get_names('public_objects', enabled_only=1)` returning
/// the members — so a row must not take `isEnabled` at face value or it will show
/// a checked box for something invisible.
private func ancestorsEnabled(_ entry: ObjectEntry, byName: [String: ObjectEntry]) -> Bool {
    var seen = Set<String>()
    var next = entry.parent
    while let name = next, !seen.contains(name), let anc = byName[name] {
        if !anc.isEnabled { return false }
        seen.insert(name)
        next = anc.parent
    }
    return true
}

/// Checkbox state for a row; groups fold in their whole subtree.
private func checkState(for entry: ObjectEntry,
                        byParent: [String: [ObjectEntry]]) -> CheckState {
    guard entry.isGroup else { return entry.isEnabled ? .on : .off }
    if !entry.isEnabled { return .off }
    var anyOn = false, anyOff = false
    var seen = Set<String>()
    var stack = byParent[entry.name] ?? []
    while let c = stack.popLast() {
        guard !seen.contains(c.name) else { continue }
        seen.insert(c.name)
        if c.isEnabled { anyOn = true } else { anyOff = true }
        stack.append(contentsOf: byParent[c.name] ?? [])
    }
    return (anyOn && anyOff) ? .mixed : (anyOff ? .off : .on)
}

/// The shared visibility checkbox. Factored out because the same control is drawn
/// by the object row, the selection row and the pinned "all" row.
@ViewBuilder
private func checkboxImage(_ state: CheckState) -> some View {
    Image(systemName: state == .on ? "checkmark.square.fill"
                    : state == .mixed ? "minus.square.fill" : "square")
        .font(.system(size: 12))
        .foregroundColor(state == .off ? PanelTheme.disabledColor : PanelTheme.textColor)
}

// MARK: - Menu Option Definitions

/// Show/Hide representation options
private let showHideOptions: [(label: String, rep: String?)] = [
    ("everything",  "everything"),
    ("---",         nil),
    ("lines",       "lines"),
    ("nonbonded",   "nonbonded"),
    ("---",         nil),
    ("sticks",      "sticks"),
    ("nb_spheres",  "nb_spheres"),
    ("---",         nil),
    ("ribbon",      "ribbon"),
    ("cartoon",     "cartoon"),
    ("labels",      "labels"),
    ("cell",        "cell"),
    ("dots",        "dots"),
    ("spheres",     "spheres"),
    ("mesh",        "mesh"),
    ("surface",     "surface"),
    ("volume",      "volume"),
    ("slice",       "slice"),
    ("extent",      "extent"),
    ("---",         nil),
    ("licorice",    "licorice"),
    ("wire",        "wire"),
    ("dashes",      "dashes"),
]

/// Label options
private let labelOptions: [(label: String, expr: String?)] = [
    ("None",      ""),
    ("---",       nil),
    ("Residues",  "resn+resi"),
    ("Chains",    "chain"),
    ("Segments",  "segi"),
    ("Atoms",     "name"),
    ("Elements",  "elem"),
]

/// Color options with optional swatch color
private struct ColorOption {
    let label: String
    let command: String?
    let swatch: Color?
}

private let colorOptions: [ColorOption] = [
    ColorOption(label: "by element",  command: "util.cnc",   swatch: nil),
    ColorOption(label: "by chain",    command: "util.cbc",   swatch: nil),
    ColorOption(label: "by ss",       command: "util.cbss",  swatch: nil),
    ColorOption(label: "spectrum",    command: "spectrum",    swatch: nil),
    ColorOption(label: "by b-factor", command: "spectrum_b",  swatch: nil),
    ColorOption(label: "---",         command: nil,           swatch: nil),
    ColorOption(label: "red",         command: "red",         swatch: Color(.sRGB, red: 1.0, green: 0.0, blue: 0.0)),
    ColorOption(label: "green",       command: "green",       swatch: Color(.sRGB, red: 0.0, green: 1.0, blue: 0.0)),
    ColorOption(label: "blue",        command: "blue",        swatch: Color(.sRGB, red: 0.0, green: 0.3, blue: 1.0)),
    ColorOption(label: "yellow",      command: "yellow",      swatch: Color(.sRGB, red: 1.0, green: 1.0, blue: 0.0)),
    ColorOption(label: "magenta",     command: "magenta",     swatch: Color(.sRGB, red: 1.0, green: 0.0, blue: 1.0)),
    ColorOption(label: "cyan",        command: "cyan",        swatch: Color(.sRGB, red: 0.0, green: 1.0, blue: 1.0)),
    ColorOption(label: "orange",      command: "orange",      swatch: Color(.sRGB, red: 1.0, green: 0.5, blue: 0.0)),
    ColorOption(label: "lightteal",   command: "lightteal",   swatch: Color(.sRGB, red: 0.7, green: 0.9, blue: 0.9)),
    ColorOption(label: "gray",        command: "gray",        swatch: Color(.sRGB, red: 0.5, green: 0.5, blue: 0.5)),
    ColorOption(label: "white",       command: "white",       swatch: Color.white),
]

// MARK: - Action Menu Structure

/// Hierarchical action menu item
private indirect enum ActionMenuItem {
    case action(label: String, key: String)
    case separator
    case submenu(label: String, children: [ActionMenuItem])
    // Dynamic submenus whose children are the currently-loaded molecule
    // objects / public selections (built at render time from engine.objects),
    // mirroring desktop PyMOL's "to molecule (*/CA)" / "to selection (*/CA)"
    // align entries.
    case alignToMolecule(label: String)
    case alignToSelection(label: String)
    /// Dynamic submenu listing existing groups plus "New Group…" (#255). Built at
    /// render time from engine.objects, like the align cases, because the set of
    /// groups changes with every poll.
    case moveToGroup(label: String)
}

private let baseActionMenuItems: [ActionMenuItem] = [
    .action(label: "Zoom",               key: "zoom"),
    .action(label: "Orient",             key: "orient"),
    .action(label: "Center",             key: "center"),
    .action(label: "Origin",             key: "origin"),
    .separator,
    .action(label: "Drag Matrix",        key: "drag_matrix"),
    .action(label: "Reset Matrix",       key: "reset_matrix"),
    .separator,
    .action(label: "Drag Coordinates",   key: "drag_coords"),
    .action(label: "Clean",              key: "clean"),
    .separator,
    .submenu(label: "Preset", children: [
        .action(label: "classified",                  key: "preset_classified"),
        .separator,
        .action(label: "simple",                      key: "preset_simple"),
        .action(label: "simple (no solvent)",          key: "preset_simple_no_solv"),
        .action(label: "ball and stick",               key: "preset_ball_and_stick"),
        .action(label: "b factor putty",               key: "preset_b_factor_putty"),
        .action(label: "technical",                    key: "preset_technical"),
        .action(label: "ligands",                      key: "preset_ligands"),
        .action(label: "pretty",                       key: "preset_pretty"),
        .action(label: "pretty (with solvent)",        key: "preset_pretty_solv"),
        .action(label: "publication",                  key: "preset_publication"),
        .action(label: "publication (with solvent)",   key: "preset_pub_solv"),
        .separator,
        .action(label: "protein interface",            key: "preset_interface"),
        .separator,
        .action(label: "default",                      key: "preset_default"),
    ]),
    .submenu(label: "Find", children: [
        .action(label: "polar contacts (within)",   key: "find_polar_within"),
        .action(label: "polar contacts (to other)", key: "find_polar_other"),
        .action(label: "polar contacts (any)",      key: "find_polar_any"),
        .separator,
        .action(label: "halogen bonds",             key: "find_halogen_bond"),
        .action(label: "salt bridges",              key: "find_salt_bridge"),
        .separator,
        .action(label: "pi interactions (all)",     key: "find_pi_all"),
        .action(label: "pi-pi",                     key: "find_pi_pi"),
        .action(label: "pi-cation",                 key: "find_pi_cation"),
    ]),
    .submenu(label: "Align", children: [
        .alignToMolecule(label: "to molecule (*/CA)"),
        .alignToSelection(label: "to selection (*/CA)"),
        .separator,
        .action(label: "enabled to this (*/CA)",  key: "align_enabled"),
        .action(label: "all to this (*/CA)",      key: "align_all"),
        .separator,
        .action(label: "states (*/CA)",           key: "align_states_ca"),
        .action(label: "states",                  key: "align_states"),
        .separator,
        .action(label: "matrix reset",            key: "matrix_reset"),
    ]),
    .submenu(label: "Generate", children: [
        .action(label: "vacuum electrostatics",  key: "gen_vacuum_esp"),
        .separator,
        .action(label: "symmetry mates 4 A",     key: "gen_symm_4"),
        .action(label: "symmetry mates 8 A",     key: "gen_symm_8"),
        .action(label: "symmetry mates 20 A",    key: "gen_symm_20"),
    ]),
    .separator,
    .action(label: "Assign Sec. Struc.",  key: "dss"),
    .separator,
    .submenu(label: "Hydrogens", children: [
        .action(label: "hide",             key: "h_hide"),
        .action(label: "show",             key: "h_show"),
        .separator,
        .action(label: "add",              key: "h_add"),
        .action(label: "add polar",        key: "h_add_polar"),
        .separator,
        .action(label: "remove",           key: "h_remove"),
        .action(label: "remove nonpolar",  key: "h_remove_nonpolar"),
    ]),
    .action(label: "Remove Waters",       key: "remove_waters"),
    .separator,
    .submenu(label: "State", children: [
        .action(label: "freeze",      key: "state_freeze"),
        .action(label: "all states",  key: "state_all"),
        .action(label: "thaw",        key: "state_thaw"),
        .separator,
        .action(label: "split",       key: "state_split"),
    ]),
    .submenu(label: "Sequence", children: [
        .action(label: "include",  key: "seq_include"),
        .action(label: "exclude",  key: "seq_exclude"),
        .action(label: "default",  key: "seq_default"),
    ]),
    .submenu(label: "Movement", children: [
        .action(label: "protect",    key: "movement_protect"),
        .action(label: "deprotect",  key: "movement_deprotect"),
    ]),
    .submenu(label: "Masking", children: [
        .action(label: "mask",    key: "masking_mask"),
        .action(label: "unmask",  key: "masking_unmask"),
    ]),
    .submenu(label: "Compute", children: [
        .action(label: "atom count",              key: "compute_count"),
        .separator,
        .action(label: "formal charge sum",       key: "compute_formal_charge"),
        .action(label: "partial charge sum",      key: "compute_partial_charge"),
        .separator,
        .action(label: "molecular surface area",  key: "compute_mol_area"),
        .action(label: "solvent accessible area", key: "compute_sasa"),
        .separator,
        .action(label: "mol. weight (explicit)",  key: "compute_mass_explicit"),
        .action(label: "mol. weight (with H)",    key: "compute_mass_implicit"),
    ]),
    .separator,
    .moveToGroup(label: "Move to Group"),
    .separator,
    .action(label: "Rename",     key: "rename"),
    .action(label: "Duplicate",  key: "copy"),
    .action(label: "Delete",     key: "delete"),
]

/// The object/selection action menu, tailored to the row it's shown on.
///
/// Selections additionally get **Remove Atoms** — PyMOL's selection-menu
/// `remove atoms` (`cmd.remove(sele); cmd.delete(sele)`): it strips the matched
/// atoms *out of their parent object* and then drops the now-empty selection.
/// This is the quick-cleanup path from issue #202 (strip waters, delete an
/// unwanted chain, trim to a binding site) — distinct from "Delete", which only
/// removes the selection marker and leaves every atom in place. Objects don't
/// get it (they keep Delete + Remove Waters), matching desktop PyMOL.
/// Action menu for a GROUP row (#255).
///
/// Deliberately much shorter than `baseActionMenuItems`: most of that menu is
/// atom-level (Preset, Find, Compute, dss) and would be wrong or slow applied to
/// a whole subtree. What remains is camera framing, the visibility verbs, and
/// group lifecycle.
///
/// The two destructive entries are kept apart on purpose. "Ungroup" dissolves the
/// group and leaves every object at top level; "Delete Group + Contents" removes
/// the members too, because `delete <group>` in PyMOL takes the whole subtree with
/// it. Labelling them identically would make an irreversible action look routine.
private let groupActionMenuItems: [ActionMenuItem] = [
    .action(label: "Zoom", key: "zoom"),
    .action(label: "Orient", key: "orient"),
    .action(label: "Center", key: "center"),
    .separator,
    .action(label: "Inspect Group…", key: "group_inspect"),
    .separator,
    .action(label: "Enable All Members", key: "group_enable_members"),
    .action(label: "Disable All Members", key: "group_disable_members"),
    .separator,
    .action(label: "Rename…", key: "rename"),
    .action(label: "Ungroup (keep objects)", key: "group_ungroup"),
    .action(label: "Delete Group + Contents", key: "group_delete"),
]

private func actionMenuItems(isSelection: Bool, isGroup: Bool = false) -> [ActionMenuItem] {
    if isGroup { return groupActionMenuItems }
    guard isSelection else { return baseActionMenuItems }
    var items = baseActionMenuItems
    // Place "Remove Atoms" in the cleanup section right after "Remove Waters" —
    // both strip atoms out of the parent object, so they belong together next to
    // Hydrogens. This is distinct from the trailing "Delete", which only drops
    // the selection marker and leaves every atom in place.
    let removeAtoms = ActionMenuItem.action(label: "Remove Atoms", key: "remove_atoms")
    if let watersIdx = items.firstIndex(where: {
        if case .action(_, "remove_waters") = $0 { return true }
        return false
    }) {
        items.insert(removeAtoms, at: watersIdx + 1)
    } else {
        items.append(removeAtoms)
    }
    return items
}

// MARK: - Command Dispatch

/// Translates action keys into PyMOL commands and runs them
private func runActionCommand(_ key: String, name: String, engine: PyMOLEngine) {
    let n = name  // shorthand
    let cmd: String
    switch key {
    // View / Transform
    case "zoom":             cmd = "zoom \(n), animate=-1"
    case "orient":           cmd = "orient \(n), animate=-1"
    case "center":           cmd = "center \(n), animate=-1"
    case "origin":           cmd = "origin \(n)"
    case "drag_matrix":      cmd = "drag \(n)"
    case "reset_matrix":     cmd = "reset object=\(n)"
    case "drag_coords":      cmd = "drag (\(n))"
    case "clean":            cmd = "clean \(n)"
    case "dss":              cmd = "dss \(n)"
    // Presets
    case "preset_classified":       cmd = "python\nfrom pymol import preset; preset.classified('\(n)', _self=cmd)\npython end"
    case "preset_simple":           cmd = "python\nfrom pymol import preset; preset.simple('\(n)', _self=cmd)\npython end"
    case "preset_simple_no_solv":   cmd = "python\nfrom pymol import preset; preset.simple_no_solv('\(n)', _self=cmd)\npython end"
    case "preset_ball_and_stick":   cmd = "python\nfrom pymol import preset; preset.ball_and_stick('\(n)', _self=cmd)\npython end"
    case "preset_b_factor_putty":   cmd = "python\nfrom pymol import preset; preset.b_factor_putty('\(n)', _self=cmd)\npython end"
    case "preset_technical":        cmd = "python\nfrom pymol import preset; preset.technical('\(n)', _self=cmd)\npython end"
    case "preset_ligands":          cmd = "python\nfrom pymol import preset; preset.ligands('\(n)', _self=cmd)\npython end"
    case "preset_pretty":           cmd = "python\nfrom pymol import preset; preset.pretty('\(n)', _self=cmd)\npython end"
    case "preset_pretty_solv":      cmd = "python\nfrom pymol import preset; preset.pretty_solv('\(n)', _self=cmd)\npython end"
    case "preset_publication":      cmd = "python\nfrom pymol import preset; preset.publication('\(n)', _self=cmd)\npython end"
    case "preset_pub_solv":         cmd = "python\nfrom pymol import preset; preset.pub_solv('\(n)', _self=cmd)\npython end"
    case "preset_interface":        cmd = "python\nfrom pymol import preset; preset.interface('\(n)', _self=cmd)\npython end"
    case "preset_default":          cmd = "python\nfrom pymol import preset; preset.default('\(n)', _self=cmd)\npython end"
    // Find
    case "find_polar_within":  cmd = "dist \(n)_polar_conts, \(n), \(n), quiet=1, mode=2, label=0, reset=1; enable \(n)_polar_conts"
    case "find_polar_other":   cmd = "dist \(n)_polar_conts, (\(n)), (byobj (\(n))) and (not (\(n))), quiet=1, mode=2, label=0, reset=1; enable \(n)_polar_conts"
    case "find_polar_any":     cmd = "dist \(n)_polar_conts, (\(n)), (not \(n)), quiet=1, mode=2, label=0, reset=1; enable \(n)_polar_conts"
    case "find_halogen_bond":  cmd = "distance \(n)_halogen_bond, \(n), same, reset=1, mode=9"
    case "find_salt_bridge":   cmd = "distance \(n)_salt_bridge, \(n), same, reset=1, mode=10"
    case "find_pi_all":        cmd = "pi_interactions \(n)_pi_interactions, \(n), reset=1"
    case "find_pi_pi":         cmd = "distance \(n)_pi_pi, \(n), same, reset=1, mode=6"
    case "find_pi_cation":     cmd = "distance \(n)_pi_cation, \(n), same, reset=1, mode=7"
    // Align
    case "align_enabled":      cmd = "python\ncmd.util.mass_align('\(n)', 1, _self=cmd)\npython end"
    case "align_all":          cmd = "python\ncmd.util.mass_align('\(n)', 0, _self=cmd)\npython end"
    case "align_states_ca":    cmd = "intra_fit (\(n)) and name CA"
    case "align_states":       cmd = "intra_fit \(n)"
    case "matrix_reset":       cmd = "matrix_reset \(n)"
    // Generate
    case "gen_vacuum_esp":     cmd = "python\ncmd.util.protein_vacuum_esp('\(n)', mode=2, quiet=0, _self=cmd)\npython end"
    case "gen_symm_4":         cmd = "symexp \(n)_, \(n), \(n), cutoff=4, segi=1"
    case "gen_symm_8":         cmd = "symexp \(n)_, \(n), \(n), cutoff=8, segi=1"
    case "gen_symm_20":        cmd = "symexp \(n)_, \(n), \(n), cutoff=20, segi=1"
    // Hydrogens
    case "h_hide":             cmd = "hide everything, (\(n)) and hydro"
    case "h_show":             cmd = "show sticks, (\(n)) and hydro"
    case "h_add":              cmd = "h_add \(n); sort \(n) extend 1"
    case "h_add_polar":        cmd = "h_add \(n) & (don.|acc.); sort \(n) extend 1"
    case "h_remove":           cmd = "remove (\(n)) and hydro"
    case "h_remove_nonpolar":  cmd = "remove \(n) & hydro & not nbr. (don.|acc.)"
    case "remove_waters":      cmd = "remove (solvent and (\(n)))"
    // State
    case "state_freeze":       cmd = "python\ncmd.set('state', cmd.get_state(), '\(n)')\npython end"
    case "state_all":          cmd = "set state, 0, \(n)"
    case "state_thaw":         cmd = "unset all_states, \(n); unset state, \(n)"
    case "state_split":        cmd = "split_states \(n)"
    // Sequence
    case "seq_include":        cmd = "set seq_view, on, \(n)"
    case "seq_exclude":        cmd = "set seq_view, off, \(n)"
    case "seq_default":        cmd = "unset seq_view, \(n)"
    // Movement
    case "movement_protect":   cmd = "protect \(n)"
    case "movement_deprotect": cmd = "deprotect \(n)"
    // Masking
    case "masking_mask":       cmd = "mask \(n)"
    case "masking_unmask":     cmd = "unmask \(n)"
    // Compute
    case "compute_count":           cmd = "count_atoms \(n)"
    case "compute_formal_charge":   cmd = "python\ncmd.util.sum_formal_charges('\(n)', quiet=0, _self=cmd)\npython end"
    case "compute_partial_charge":  cmd = "python\ncmd.util.sum_partial_charges('\(n)', quiet=0, _self=cmd)\npython end"
    case "compute_mol_area":        cmd = "python\ncmd.util.get_area('\(n)', -1, 0, quiet=0, _self=cmd)\npython end"
    case "compute_sasa":            cmd = "python\ncmd.util.get_sasa('\(n)', quiet=0, _self=cmd)\npython end"
    case "compute_mass_explicit":   cmd = "python\ncmd.util.compute_mass('\(n)', implicit=False, quiet=0, _self=cmd)\npython end"
    case "compute_mass_implicit":   cmd = "python\ncmd.util.compute_mass('\(n)', implicit=True, quiet=0, _self=cmd)\npython end"
    // Object management
    case "rename":
        // PyMOL's `wizard renaming` has no UI here — request a name-entry modal
        // (presented by ObjectPanel) instead.
        engine.pendingRename = n
        return
    case "copy":               cmd = "copy \(n)_copy, \(n)"
    case "delete":             cmd = "delete \(n)"
    // Group lifecycle (#255). `action=excise` dissolves the group and leaves its
    // members at top level; plain `delete <group>` removes the members too, which
    // is why the two are separate menu entries with explicit labels.
    case "group_ungroup":      cmd = "group \(n), , action=excise"
    case "group_delete":       cmd = "delete \(n)"
    case "group_enable_members":  cmd = "enable \(n)"
    case "group_disable_members": cmd = "disable \(n)"
    case "group_inspect":
        // A group's rep card is the union of its members' reps (see #256). The
        // chevron on a group row is spoken for by child expansion, so this is how
        // the card is opened.
        engine.expandedDetail = n
        return
    case "group_new":
        // Create a group holding just this object; PyMOL creates the group on
        // first reference, so no separate create step is needed.
        engine.pendingGroupFor = n
        return
    // Strip the selection's atoms out of their parent object(s), then drop the
    // now-empty selection (PyMOL's selection-menu "remove atoms"). Shown only on
    // selection rows — see actionMenuItems(isSelection:).
    case "remove_atoms":       cmd = "remove (\(n)); delete \(n)"
    // Global ("all" row) actions
    case "deselect":           cmd = "deselect"
    case "hide_everything":    cmd = "hide everything, \(n)"
    case "reset_view":         cmd = "reset"
    // Moves the objects, not the camera: every object is shifted so their
    // centers coincide, so switching between unrelated PDBs stops requiring a
    // re-zoom. Non-destructive (object matrix) — `matrix_reset` puts it back.
    // The follow-up zoom frames the stacked result — the camera may be aimed
    // at where things used to be.
    case "center_all":         cmd = "center_all\nzoom visible"
    case "center_all_reset":   cmd = "python\nfor _o in cmd.get_names('public_objects'):\n    cmd.matrix_reset(_o, mode=1)\npython end"
    default:                   return
    }
    engine.runCommand(cmd)
}

/// Action ("A") menu for the global "all" row — a focused, scene-wide subset.
/// Reuses the per-object action keys (all valid with name "all"); deliberately
/// omits per-object items (Rename / Duplicate / Delete) and adds global ones
/// (Deselect, Hide everything, Reset camera).
private let allActionMenuItems: [ActionMenuItem] = [
    .action(label: "Zoom",           key: "zoom"),
    .action(label: "Orient",         key: "orient"),
    .action(label: "Center camera",  key: "center"),
    .action(label: "Reset camera",   key: "reset_view"),
    .separator,
    // "Center all" moves the objects onto a shared center; "Center camera"
    // above only aims the camera. The labels have to carry that distinction —
    // they sit two rows apart in the same menu.
    .submenu(label: "Center all objects", children: [
        .action(label: "stack on first object", key: "center_all"),
        .separator,
        .action(label: "undo (reset matrices)", key: "center_all_reset"),
    ]),
    .separator,
    .action(label: "Deselect",      key: "deselect"),
    .action(label: "Hide everything", key: "hide_everything"),
    .separator,
    .action(label: "Assign Sec. Struc.", key: "dss"),
    .action(label: "Remove Waters",      key: "remove_waters"),
    .submenu(label: "Hydrogens", children: [
        .action(label: "add",        key: "h_add"),
        .action(label: "add polar",  key: "h_add_polar"),
        .action(label: "remove",     key: "h_remove"),
    ]),
    .submenu(label: "Find", children: [
        .action(label: "polar contacts (any)", key: "find_polar_any"),
        .action(label: "salt bridges",         key: "find_salt_bridge"),
    ]),
    .submenu(label: "Preset", children: [
        .action(label: "pretty",         key: "preset_pretty"),
        .action(label: "technical",      key: "preset_technical"),
        .action(label: "ball and stick", key: "preset_ball_and_stick"),
        .action(label: "default",        key: "preset_default"),
    ]),
]

// MARK: - Theme

// Computed from the active theme (ThemeManager.shared). Neutrals are derived by
// blending panelBackground -> panelText so they stay solid (alpha 1), which keeps
// the existing `.opacity(1.3)` call sites a no-op as before. Views that read these
// must observe ThemeManager (@EnvironmentObject) so they re-render on theme switch.
private enum PanelTheme {
    private static var t: Theme { ThemeManager.shared.active }
    static var background: Color { t.panelBackground.color }
    static var rowBackground: Color { t.panelBackground.blended(with: t.panelText, 0.06).color }
    static var rowAltBackground: Color { t.panelBackground.blended(with: t.panelText, 0.03).color }
    static var textColor: Color { t.panelText.color }
    static var selectionTextColor: Color { t.selectionName.color }
    static var buttonBackground: Color { t.panelBackground.blended(with: t.panelText, 0.16).color }
    static var buttonText: Color { t.panelText.color }
    static var accentColor: Color { t.accent.color }
    static var headerColor: Color { t.panelBackground.blended(with: t.panelText, 0.6).color }
    static var disabledColor: Color { t.panelBackground.blended(with: t.panelText, 0.4).color }
    // Amber accent for the per-atom transparency badge / detail row — a fixed hue
    // (not the blue theme accent) that reads as "transparency" and stays legible
    // on both light and dark panel themes.
    static var atomTranspColor: Color { Color(.sRGB, red: 0.90, green: 0.66, blue: 0.30, opacity: 1) }
}

// Chrome for the compact A/S/H/L/C representation menu buttons so they read the
// SAME on both platforms: a blue glyph on a gray rounded box, hugging its cell.
// iOS's `.borderlessButton` menu renders the custom label (box + background)
// verbatim; macOS's `.borderlessButton` instead tints the glyph, DROPS the box,
// and lays out greedily (the letters spread across the row). So on macOS we use
// the `.button` menu style + a plain button style, which render the label as-is
// and size to it. The explicit accent foreground keeps the glyph blue on macOS
// (a plain button would otherwise inherit the primary text color).
private extension View {
    @ViewBuilder func repMenuChrome() -> some View {
        #if os(iOS)
        self.menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .foregroundColor(PanelTheme.accentColor)
        #else
        self.menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .foregroundColor(PanelTheme.accentColor)
            .fixedSize()
        #endif
    }
}

// MARK: - ObjectPanel View

struct ObjectPanel: View {
    @EnvironmentObject var engine: PyMOLEngine
    @EnvironmentObject private var themeManager: ThemeManager   // re-render on theme switch
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSizeClass
    #endif
    @State private var showSelectionBuilder = false
    @State private var renameText = ""
    @State private var groupNameText = ""
    // Independent collapse state for the three top-level sections (Scene starts
    // collapsed, matching the previous default).
    @State private var openSections: Set<String> = ["objects", "selections",
                                                    "alignments"]
    // Which group rows are expanded. Deliberately NOT engine.expandedDetail: that
    // is a single-slot accordion for the rep inspector whose didSet re-polls and
    // which ContentView reads to resize the panel, so reusing it would make
    // opening a group collapse the inspector and resize the pane. Held here rather
    // than as @State on the row because rows live in a LazyVStack, which discards
    // offscreen state. PyMOL's own open/closed flag (SpecRec OpenOrClosed) has no
    // Python accessor, so this is the source of truth and we push it down with
    // `group ..., action=open|close` — see the note in toggleGroupOpen.
    @State private var openGroups: Set<String> = []

    var body: some View {
        panelBody
            // Name-entry modal for the action-menu "Rename" (engine.pendingRename).
            .alert("Rename “\(engine.pendingRename ?? "")”",
                   isPresented: Binding(get: { engine.pendingRename != nil },
                                        set: { if !$0 { engine.pendingRename = nil } })) {
                TextField("New name", text: $renameText)
                Button("Rename") {
                    if let old = engine.pendingRename {
                        let new = renameText.trimmingCharacters(in: .whitespaces)
                        if !new.isEmpty && new != old { engine.renameObject(old, to: new) }
                    }
                    engine.pendingRename = nil
                }
                Button("Cancel", role: .cancel) { engine.pendingRename = nil }
            } message: { Text("Enter a new name for this object.") }
            .onChange(of: engine.pendingRename) { newValue in
                if let n = newValue { renameText = n }   // prefill with current name
            }
            // "New Group…" (#255) — same request-channel shape as the rename alert.
            .alert("New group for “\(engine.pendingGroupFor ?? "")”",
                   isPresented: Binding(get: { engine.pendingGroupFor != nil },
                                        set: { if !$0 { engine.pendingGroupFor = nil } })) {
                TextField("Group name", text: $groupNameText)
                Button("Create") {
                    if let member = engine.pendingGroupFor {
                        let g = groupNameText.trimmingCharacters(in: .whitespaces)
                        if !g.isEmpty && g != member {
                            // PyMOL creates the group on first reference, so this
                            // both creates it and moves the object in.
                            engine.runCommand("group \(g), \(member)")
                            openGroups.insert(g)   // show the result immediately
                        }
                    }
                    engine.pendingGroupFor = nil
                }
                Button("Cancel", role: .cancel) { engine.pendingGroupFor = nil }
            } message: { Text("Enter a name for the new group.") }
            .onChange(of: engine.pendingGroupFor) { newValue in
                if newValue != nil { groupNameText = "" }
            }
    }

    private var panelBody: some View {
        VStack(spacing: 0) {
            // Panel-wide toolbar: the selection-pick mode acts on the whole panel,
            // so it lives here rather than in any one section header. (The former
            // "Inspector" label was dropped — the bottom tab already names the pane;
            // SCENE moved fully into the Settings tab.)
            // Selection mode + Clear live in the shared inspector chrome
            // (inspectorSwitcher's tab-description row) on EVERY size class now —
            // iPhone included, since it adopted that chrome — so there's no
            // per-panel header here (it used to duplicate on compact width).

            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    let objects = engine.objects.filter { !$0.isSelection }
                    let selections = engine.objects.filter { $0.isSelection }

                    // SCENE (global display settings) now lives in the Settings tab
                    // → "Scene settings"; it was removed from the Inspector here.

                    // OBJECTS — the loaded molecules + the global "all" row.
                    sectionHeader("OBJECTS", id: "objects",
                                  tag: objects.isEmpty ? nil : "\(objects.count)") { EmptyView() }
                    if openSections.contains("objects") {
                        if objects.isEmpty {
                            emptyHint("No objects loaded")
                        } else {
                            AllControlsRow()
                            // Nested rows come from a flattened tree walk, and the
                            // alternating stripe is indexed over THAT order — striping
                            // the unflattened array desynchronises as groups collapse.
                            let rows = flattenObjectTree(objects, openGroups: openGroups)
                            let byName = Dictionary(objects.map { ($0.name, $0) },
                                                    uniquingKeysWith: { a, _ in a })
                            let byParent = Dictionary(grouping: objects.filter { $0.parent != nil },
                                                      by: { $0.parent! })
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                ObjectCard(
                                    entry: row.entry,
                                    isAlt: index % 2 == 1,
                                    depth: row.depth,
                                    check: checkState(for: row.entry, byParent: byParent),
                                    dimmed: !ancestorsEnabled(row.entry, byName: byName),
                                    isOpen: openGroups.contains(row.entry.name),
                                    onToggleGroup: { toggleGroupOpen(row.entry.name) }
                                )
                                if row.entry.isGroup, openGroups.contains(row.entry.name),
                                   (byParent[row.entry.name] ?? []).isEmpty {
                                    emptyHint("Empty group")
                                        .padding(.leading, kIndentW * CGFloat(min(row.depth + 1, kMaxIndentDepth)))
                                }
                            }
                        }
                    }

                    // SELECTIONS — named atom selections; the lasso enters the
                    // box tool and the + opens the builder. Two ways to make a
                    // selection, side by side: point at it, or describe it.
                    sectionHeader("SELECTIONS", id: "selections",
                                  tag: selections.isEmpty ? nil : "\(selections.count)") {
                        // Box Select (#358). A toggle, not a launcher: it arms a
                        // rectangle in the viewport immediately and 'sele' tracks
                        // it, so the lit state IS "a box is live right now" and
                        // switching it off is a way out of the mode.
                        Button(action: { engine.toggleBoxSelect() }) {
                            Image(systemName: "lasso")
                                .font(.system(size: 11))
                                .foregroundColor(engine.interactionMode == .boxSelect
                                                 ? PanelTheme.accentColor
                                                 : PanelTheme.headerColor)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Box select")
                        // The lasso is the ONLY affordance for this tool, so the
                        // tooltip carries the whole interaction, not just a name.
                        .help("Box select — puts a rectangle on the viewport and adds "
                              + "everything under it to the selection. Drag its edges, "
                              + "corners or middle to adjust. Close with ✕, Esc, or "
                              + "this button.")

                        Button(action: { showSelectionBuilder = true }) {
                            Image(systemName: "plus")
                                .font(.system(size: 11))
                                .foregroundColor(PanelTheme.headerColor)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("New selection")
                        .help("New selection / selection builder")
                    }
                    if openSections.contains("selections") {
                        if selections.isEmpty {
                            emptyHint("No selections")
                        } else {
                            ForEach(Array(selections.enumerated()), id: \.element.id) { index, obj in
                                ObjectRowView(entry: obj, isAlt: index % 2 == 1)
                            }
                        }
                    }

                    // ALIGNMENTS (#296) — shown only when there is something in it.
                    // Unlike OBJECTS and SELECTIONS, which are always meaningful, a
                    // permanently empty third section would be pure chrome for the
                    // many sessions that never load an alignment.
                    //
                    // A running search counts too (#298), or the section stays hidden
                    // for the several minutes before the first alignment lands — which
                    // is precisely when a user most needs to see that something is
                    // happening.
                    if !engine.alignments.isEmpty || !engine.msaSearches.isEmpty {
                        sectionHeader(
                            "ALIGNMENTS", id: "alignments",
                            tag: "\(engine.alignments.count + engine.msaSearches.count)"
                        ) { EmptyView() }
                        if openSections.contains("alignments") {
                            // Searches first: they are what is changing, and each one
                            // is replaced in place by its own result when it lands.
                            ForEach(Array(engine.msaSearches.enumerated()),
                                    id: \.element.id) { index, search in
                                MSASearchRowView(entry: search, isAlt: index % 2 == 1)
                            }
                            ForEach(Array(engine.alignments.enumerated()),
                                    id: \.element.id) { index, aln in
                                AlignmentRowView(
                                    entry: aln,
                                    isAlt: (index + engine.msaSearches.count) % 2 == 1)
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
                // Report natural list height so the portrait panel can hug Objects
                // (capped at 1/3). Harmless in landscape/iPad (no listener there).
                .reportPaneHeight(1)
                .padding(.bottom, 56)   // clearance when capped + scrolling (portrait)
            }
        }
        .background(PanelTheme.background)
        .sheet(isPresented: $showSelectionBuilder) {
            SelectionBuilderSheet()
        }
        .onAppear {
            refreshObjects()
        }
    }

    // One shared header for the three top-level sections (chevron + title +
    // optional count tag + an optional trailing control). Tapping toggles collapse.
    @ViewBuilder
    private func sectionHeader<Trailing: View>(_ title: String, id: String, tag: String?,
                                               @ViewBuilder trailing: () -> Trailing) -> some View {
        let open = openSections.contains(id)
        HStack(spacing: 6) {
            Button { toggleSection(id) } label: {
                HStack(spacing: 4) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9)).foregroundColor(PanelTheme.headerColor)
                    Text(title)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(PanelTheme.headerColor)
                    if let tag {
                        Text(tag).font(.system(size: 9)).foregroundColor(PanelTheme.disabledColor)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            trailing()
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(PanelTheme.background)
    }

    /// Expand/collapse a group row, mirroring the state into PyMOL so the two
    /// agree — `action=open|close` is what a `.pse` records, so a session saved
    /// from here reopens with the same groups expanded.
    private func toggleGroupOpen(_ name: String) {
        let opening = !openGroups.contains(name)
        if opening { openGroups.insert(name) } else { openGroups.remove(name) }
        let escaped = name.replacingOccurrences(of: "'", with: "")
        engine.runCommand("group \(escaped), , action=\(opening ? "open" : "close")")
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(PanelTheme.disabledColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
    }

    private func toggleSection(_ id: String) {
        if openSections.contains(id) { openSections.remove(id) } else { openSections.insert(id) }
    }

    // Pick-granularity menu (mouse_selection_mode): what a viewport tap selects.
    private func refreshObjects() {
        // Same file-based payload as the ~500ms poll (see parseObjectPanelFeedback):
        // poll_panel writes the list to a temp file and prints only the marker, so
        // a large object list can't overflow the feedback-line cap (#231).
        engine.runCommand(
            "python\n"
            + "from pymol import appkit_inspector as _ai\n"
            + "_ai.poll_panel()\n"
            + "python end"
        )
    }
}

// MARK: - Selection mode menu (shared: inspector chrome + iPhone toolbar)

/// The "what does a tap select" mode (atoms / residues / chains / …). Lives in the
/// inspector chrome (right of the tab description) on macOS/iPad so it's reachable
/// from every tab; on iPhone it sits in the Object panel's top toolbar.
struct SelectionModeMenu: View {
    @EnvironmentObject var engine: PyMOLEngine
    // Static so the Tab / Shift+Tab shortcut (#319, installSelectionModeKeyMonitor
    // in ContentView) cycles through exactly the list this menu shows.
    static let modes: [(Int, String)] = [(0, "Atoms"), (1, "Residues"), (2, "Chains"),
                                         (3, "Segments"), (4, "Objects"), (5, "Molecules"), (6, "C-α")]

    /// The mode one entry forward (Tab) or back (Shift+Tab) from `cur`, wrapping
    /// at both ends. The floored modulo also brings an out-of-range setting
    /// value back inside the list rather than going negative.
    static func nextMode(from cur: Int, forward: Bool) -> Int {
        let n = modes.count
        return ((cur + (forward ? 1 : -1)) % n + n) % n
    }

    /// Apply `nextMode` to the live setting — the Tab / Shift+Tab shortcut's action.
    static func cycle(_ engine: PyMOLEngine, forward: Bool) {
        let cur = Int(engine.sceneState.values["mouse_selection_mode"] ?? 1)
        let next = nextMode(from: cur, forward: forward)
        engine.runCommand("set mouse_selection_mode, \(next)")
        // Reflect the new mode immediately instead of waiting for the ~500ms
        // scene poll to report it back: the label above updates on the
        // keystroke, and two quick Tabs advance two modes rather than reading
        // the same stale `cur` twice. The poll still has the last word.
        engine.sceneState.values["mouse_selection_mode"] = Double(next)
    }

    var body: some View {
        let cur = Int(engine.sceneState.values["mouse_selection_mode"] ?? 1)
        Menu {
            ForEach(Self.modes, id: \.0) { m in
                Button { engine.runCommand("set mouse_selection_mode, \(m.0)") } label: {
                    if m.0 == cur { Label(m.1, systemImage: "checkmark") } else { Text(m.1) }
                }
            }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "hand.tap").font(.system(size: 9))
                Text(Self.modes.first(where: { $0.0 == cur })?.1 ?? "Residues").font(.system(size: 10))
            }
            .foregroundColor(PanelTheme.headerColor)
        }
        .repMenuChrome()
        .fixedSize()
        // Tab cycling is the macOS key monitor only, so only macOS advertises it.
        #if os(macOS)
        .help("Selection mode — what a tap selects (Tab / ⇧Tab to cycle)")
        #else
        .help("Selection mode — what a tap selects")
        #endif
    }
}

/// One-click "delete selection" (issue #163): a single tap deletes the `sele`
/// named selection outright (`delete sele`) — removing the pink markers AND the
/// lingering entry from the object list, not just deselecting. (The Esc key,
/// issue #166, is intentionally the two-stage `escapeClearSelection()` —
/// deselect, then delete on a second press.) Lives right next to
/// `SelectionModeMenu` in the shared inspector chrome (macOS/iPad) and the
/// iPhone Object-panel header, so it's reachable from every tab. Dimmed and
/// non-interactive only when there is no `sele` selection at all.
struct ClearSelectionButton: View {
    @EnvironmentObject var engine: PyMOLEngine
    // Enabled whenever a `sele` selection EXISTS (enabled or not); a single
    // click deletes it. Disabled only when no `sele` exists.
    private var hasActiveSelection: Bool {
        engine.objects.contains { $0.isSelection && $0.name == "sele" }
    }
    var body: some View {
        Button { engine.runCommand("delete sele") } label: {
            Image(systemName: "xmark.circle")
                .font(.system(size: 11))
                // Accent (blue) when there's something to clear — matches the
                // panel's action buttons (A/S/H/L/C) — else dimmed grey.
                .foregroundColor(hasActiveSelection ? PanelTheme.accentColor : PanelTheme.disabledColor)
                // A real 18pt hit/hover region (not a bare ~10pt glyph) so the
                // click is easy and the .help tooltip reliably appears on hover.
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!hasActiveSelection)
        .help("Delete selection (sele)")
    }
}

// MARK: - Object Row

private struct ObjectRowView: View {
    let entry: ObjectEntry
    let isAlt: Bool
    @EnvironmentObject var engine: PyMOLEngine

    var body: some View {
        HStack(spacing: 2) {
            // Align with object rows, which lead with a disclosure chevron.
            Spacer().frame(width: 13)
            // Enable/disable toggle
            Button(action: { toggleEnabled() }) {
                Image(systemName: entry.isEnabled ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12))
                    .foregroundColor(entry.isEnabled ? PanelTheme.textColor : PanelTheme.disabledColor)
            }
            .buttonStyle(.plain)
            .frame(width: kGutterW)

            // Object name — tapping it toggles enable, same as the checkbox.
            Text(entry.displayName)
                .font(.system(size: 11))
                .foregroundColor(entry.isSelection ? PanelTheme.selectionTextColor : PanelTheme.textColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .contentShape(Rectangle())
                .onTapGesture { toggleEnabled() }

            Spacer(minLength: 4)

            // Action buttons: A S H L C
            ActionMenuButton(name: entry.name, isSelection: entry.isSelection, isGroup: entry.isGroup)
            ShowButton(name: entry.name)
            HideButton(name: entry.name)
            LabelMenuButton(name: entry.name)
            ColorMenuButton(name: entry.name)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .frame(height: kRowH)
        .background(isAlt ? PanelTheme.rowAltBackground : PanelTheme.rowBackground)
        // Whole-row tap toggles enable. The trailing A/S/H/L/C controls consume
        // their own taps (they sit above this gesture); only the dead Spacer gap
        // falls through to here.
        .contentShape(Rectangle())
        .onTapGesture { toggleEnabled() }
        // Long-press (iOS) / right-click (macOS) opens the action menu.
        .contextMenu { actionMenuContent(actionMenuItems(isSelection: entry.isSelection), name: entry.name, engine: engine) }
    }

    private func toggleEnabled() {
        engine.setObjectEnabled(entry.name, !entry.isEnabled)
    }
}

// MARK: - Alignment row (#296)

/// One alignment: its name, its shape, and what it is attached to.
///
/// No visibility toggle and no A/S/H/L/C. There is nothing to enable, show, hide,
/// label or color — an alignment is data the next prediction reads, not something
/// drawn — and offering the controls anyway would make the row look actionable when
/// every one of them is a no-op. Deleting and renaming are `msa_delete` / `msa_rename`
/// on the command line, which the context menu offers here.
///
/// Clicking REVEALS the target instead: the one relationship the row already shows is
/// which chain this alignment is for, so that is what a tap acts on.
private struct AlignmentRowView: View {
    let entry: AlignmentEntry
    let isAlt: Bool
    @EnvironmentObject var engine: PyMOLEngine

    /// True when the object this alignment names is still here. The attachment is by
    /// NAME and does not follow a rename or a delete, so a row pointing at nothing is
    /// a normal state rather than an error — but clicking one must not fire
    /// `Invalid selection name` into the console, and the row should look different.
    private var targetExists: Bool {
        !entry.target.isEmpty
            && engine.objects.contains { !$0.isSelection && $0.name == entry.target }
    }

    var body: some View {
        HStack(spacing: 6) {
            // Line up with the object rows' chevron + checkbox gutter.
            Spacer().frame(width: 13 + kGutterW)

            Text(entry.name)
                .font(.system(size: 11))
                .foregroundColor(PanelTheme.textColor)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            if let attachment = entry.attachment {
                Text(attachment)
                    .font(.system(size: 9))
                    // Dimmed when the object is gone: the panel is ~300pt wide, so
                    // there is no room to spell it out on the row. The tooltip does.
                    .foregroundColor(targetExists ? PanelTheme.selectionTextColor
                                                  : PanelTheme.disabledColor)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Text(entry.shape)
                .font(.system(size: 9).monospacedDigit())
                .foregroundColor(PanelTheme.disabledColor)
                .lineLimit(1)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .frame(height: kRowH)
        .background(isAlt ? PanelTheme.rowAltBackground : PanelTheme.rowBackground)
        .contentShape(Rectangle())
        .onTapGesture { reveal() }
        .help(tooltip)
        .contextMenu {
            Button("Reveal target") { reveal() }
                .disabled(!targetExists)
            Button("Detach") { engine.runCommand("msa_detach \(entry.name)") }
                .disabled(entry.attachment == nil)
            Divider()
            Button("Delete", role: .destructive) {
                engine.runCommand("msa_delete \(entry.name)")
            }
        }
    }

    /// Take the camera to what this alignment describes: enable the object, zoom the
    /// chain. No named selection is made — one per click would litter the session with
    /// selections the user never asked for.
    ///
    /// `animate=-1` defers to the `animation` setting, matching the panel's own Zoom
    /// action rather than hard-coding a duration.
    private func reveal() {
        guard targetExists else { return }
        let selection = entry.chain.isEmpty
            ? entry.target
            : "(\(entry.target)) and chain \(entry.chain)"
        engine.setObjectEnabled(entry.target, true)
        engine.runCommand("zoom \(selection), animate=-1")
    }

    private var tooltip: String {
        var text = "\(entry.depth) sequences × \(entry.columns) columns"
            + " (\(entry.residues) residues)"
        if let attachment = entry.attachment {
            text += targetExists ? ", for \(attachment) — click to reveal"
                                 : ", for \(attachment), which is not in this session"
        }
        return text
    }
}

// MARK: - MSA search row (#298)

/// One search in flight, in the place its result will appear.
///
/// Deliberately in the ALIGNMENTS section rather than a banner or a sheet: a search is
/// a BACKGROUND operation — `msa_search` returns immediately and the user is expected to
/// keep working — so a modal would be wrong, and the row turning into the alignment it
/// produces is the clearest statement of what is going on.
///
/// An indeterminate spinner, not a bar. The ColabFold server reports queue position and
/// nothing else; a percentage here would have to be invented.
private struct MSASearchRowView: View {
    let entry: MSASearchEntry
    let isAlt: Bool
    @EnvironmentObject var engine: PyMOLEngine

    var body: some View {
        HStack(spacing: 6) {
            // Line up with the object rows' chevron + checkbox gutter, as the
            // alignment rows do.
            Spacer().frame(width: 13 + kGutterW)

            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.mini)
                .frame(width: 10, height: 10)

            Text(entry.name)
                .font(.system(size: 11))
                .foregroundColor(PanelTheme.disabledColor)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            Text(entry.detail)
                .font(.system(size: 9).monospacedDigit())
                .foregroundColor(PanelTheme.disabledColor)
                .lineLimit(1)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .frame(height: kRowH)
        .background(isAlt ? PanelTheme.rowAltBackground : PanelTheme.rowBackground)
        .contentShape(Rectangle())
        .help(tooltip)
        .contextMenu {
            // The one action there is. Cancelling by SEARCH ID rather than by name:
            // the name is not unique until the alignment lands, and two searches for
            // the same object would otherwise cancel whichever msa_cancel found first.
            Button("Cancel search", role: .destructive) {
                engine.runCommand("msa_cancel \(entry.id)")
            }
        }
    }

    private var tooltip: String {
        "Building \(entry.name) on \(entry.server) — \(entry.detail)."
            + " It runs in the background; the alignment appears here when it lands."
    }
}

// MARK: - Global "all" controls row

/// Pinned row above the object list giving the same A/S/H/L/C controls as an
/// object row but acting on the whole scene (selection "all") — mirrors desktop
/// PyMOL's "all" row for quick global Show/Hide/Label/Color and scene actions.
/// Show/Hide/Label/Color reuse the per-object menus with name "all"; the Action
/// (A) menu uses the global subset `allActionMenuItems`.
private struct AllControlsRow: View {
    @EnvironmentObject var engine: PyMOLEngine

    // The objects shown in the panel (selections excluded) — "all current objects".
    private var objects: [ObjectEntry] { engine.objects.filter { !$0.isSelection } }
    private var allEnabled: Bool { !objects.isEmpty && objects.allSatisfy { $0.isEnabled } }

    var body: some View {
        HStack(spacing: 2) {
            // Align with object rows, which lead with a disclosure chevron.
            Spacer().frame(width: 13)
            // Enable/disable ALL objects at once (mirrors desktop PyMOL's "all" row).
            Button(action: { toggleAll() }) {
                Image(systemName: allEnabled ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12))
                    .foregroundColor(allEnabled ? PanelTheme.textColor : PanelTheme.disabledColor)
            }
            .buttonStyle(.plain)
            .frame(width: kGutterW)
            Text("all")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(PanelTheme.textColor)
                .lineLimit(1)
                .contentShape(Rectangle())
                .onTapGesture { toggleAll() }
            Spacer(minLength: 4)
            Menu {
                actionMenuContent(allActionMenuItems, name: "all", engine: engine)
            } label: {
                Text("A")
                    .frame(width: kActBtnW, height: kActBtnH)
                    .background(PanelTheme.buttonBackground)
                    .cornerRadius(2)
                    .contentShape(Rectangle())
            }
            .repMenuChrome()
            ShowButton(name: "all")
            HideButton(name: "all")
            LabelMenuButton(name: "all")
            ColorMenuButton(name: "all")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .frame(height: kRowH)
        .background(PanelTheme.rowBackground)
        // Whole-row tap toggles ALL objects. The trailing A/S/H/L/C controls
        // consume their own taps; only the dead Spacer gap falls through here.
        .contentShape(Rectangle())
        .onTapGesture { toggleAll() }
        .contextMenu { actionMenuContent(allActionMenuItems, name: "all", engine: engine) }
    }

    // Enable or disable every object in one shot. Iterating get_names('objects')
    // targets exactly the current objects (not the "all" atom-selection), so it
    // works regardless of how enable/disable interpret the "all" keyword.
    private func toggleAll() {
        let enable = !allEnabled
        // Optimistic-first: flip every object's checkbox immediately (isEnabled
        // is a var → instant re-render) so the whole "all" row updates this frame
        // instead of waiting on the ~500ms pollObjects reconcile.
        for idx in engine.objects.indices where !engine.objects[idx].isSelection {
            engine.objects[idx].isEnabled = enable
        }
        let action = enable ? "enable" : "disable"
        engine.runPython(
            "from pymol import cmd as _c\n"
            + "for _o in (_c.get_names('objects') or []):\n"
            + "    _c.\(action)(_o)\n")
    }
}

// MARK: - Small Panel Button Style

private struct PanelButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(PanelTheme.buttonText)
            .frame(width: kActBtnW, height: kActBtnH)
            .background(
                configuration.isPressed
                    ? PanelTheme.buttonBackground.opacity(1.3)
                    : PanelTheme.buttonBackground
            )
            .cornerRadius(2)
    }
}

// MARK: - Action (A) Menu

/// Builds the hierarchical Action ("A") menu items. A FREE function so both the
/// "A" button AND the object row's long-press context menu present the same menu.
@ViewBuilder
private func actionMenuContent(_ items: [ActionMenuItem], name: String, engine: PyMOLEngine) -> some View {
    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
        switch item {
        case .action(let label, let key):
            Button(label) { runActionCommand(key, name: name, engine: engine) }
        case .separator:
            Divider()
        case .submenu(let label, let children):
            Menu(label) {
                AnyView(actionMenuContent(children, name: name, engine: engine))  // AnyView breaks recursive opaque-type inference
            }
        case .moveToGroup(let label):
            // Per-object grouping (#255). The panel has no multi-select — its only
            // per-row state is visibility — so grouping is driven one object at a
            // time from here rather than from a checked set.
            Menu(label) {
                let groups = engine.objects.filter { $0.isGroup && $0.name != name }
                ForEach(groups) { g in
                    Button(g.name) {
                        engine.runCommand("group \(g.name), \(name), action=add")
                    }
                }
                if !groups.isEmpty { Divider() }
                Button("New Group…") { engine.pendingGroupFor = name }
                if engine.objects.first(where: { $0.name == name })?.parent != nil {
                    Divider()
                    Button("Remove from Group") { engine.runCommand("ungroup \(name)") }
                }
            }
        case .alignToMolecule(let label):
            // Candidate targets: every OTHER loaded molecule object (mirrors
            // desktop PyMOL's align_to_object). Empty when nothing else is loaded.
            Menu(label) {
                let targets = engine.objects.filter { !$0.isSelection && $0.name != name }
                if targets.isEmpty {
                    Button("(no other molecules)") {}.disabled(true)
                } else {
                    ForEach(targets) { target in
                        Button(target.name) {
                            runAlignCommand(mobile: name, target: target.name, engine: engine)
                        }
                    }
                }
            }
        case .alignToSelection(let label):
            // Candidate targets: every public selection (mirrors desktop PyMOL's
            // align_to_sele). Empty when no selections exist.
            Menu(label) {
                let targets = engine.objects.filter { $0.isSelection && $0.name != name }
                if targets.isEmpty {
                    Button("(no selections)") {}.disabled(true)
                } else {
                    ForEach(targets) { target in
                        Button(target.name) {
                            runAlignCommand(mobile: name, target: target.name, engine: engine)
                        }
                    }
                }
            }
        }
    }
}

/// Align one object onto a target molecule/selection over polymer CA atoms,
/// creating an alignment object (mirrors desktop PyMOL's align_to_object /
/// align_to_sele in modules/pymol/menu.py).
private func runAlignCommand(mobile: String, target: String, engine: PyMOLEngine) {
    let cmd = "python\ncmd.align(\"polymer and name CA and (\(mobile))\", "
        + "\"polymer and name CA and (\(target))\", quiet=0, "
        + "object=\"aln_\(mobile)_to_\(target)\", reset=1)\npython end"
    engine.runCommand(cmd)
}

private struct ActionMenuButton: View {
    let name: String
    var isSelection: Bool = false
    var isGroup: Bool = false
    @EnvironmentObject var engine: PyMOLEngine

    var body: some View {
        Menu {
            actionMenuContent(actionMenuItems(isSelection: isSelection, isGroup: isGroup), name: name, engine: engine)
        } label: {
            Text("A")
                .frame(width: kActBtnW, height: kActBtnH)
                .background(PanelTheme.buttonBackground)
                .cornerRadius(2)
                // Make the entire framed/background area hit-testable, not just
                // the "A" glyph — so a tap anywhere on the button opens the menu.
                .contentShape(Rectangle())
        }
        .repMenuChrome()
    }
}

// MARK: - Show (S) Menu Button

private struct ShowButton: View {
    let name: String
    @EnvironmentObject var engine: PyMOLEngine

    var body: some View {
        Menu {
            // Side chains: show non-backbone atoms (the `sidechain` selection),
            // with the cartoon side-chain helper so it composes cleanly with a
            // cartoon. A common daily-use shortcut absent from the plain rep list.
            Menu("side chains") {
                // Include `name CA` so the CA–CB bond is drawn (PyMOL's `sidechain`
                // selection excludes the alpha-carbon, leaving sidechains floating
                // off the backbone); cartoon_side_chain_helper yields the CA from
                // the cartoon so the stick connects cleanly. Hydrogens excluded.
                Button("as sticks") {
                    engine.runCommand("show sticks, (\(name)) and (sidechain or name CA) and not hydro; set cartoon_side_chain_helper, 1, \(name)")
                }
                Button("as lines") {
                    engine.runCommand("show lines, (\(name)) and (sidechain or name CA) and not hydro; set cartoon_side_chain_helper, 1, \(name)")
                }
                Button("as spheres") {
                    engine.runCommand("show spheres, (\(name)) and sidechain")
                }
            }
            // Hydrogens are a selection, not a rep, so they sit beside "side
            // chains" rather than in the shared rep list (#353). Same command
            // as A → Hydrogens → show.
            Button("hydrogens") {
                engine.runCommand("show sticks, (\(name)) and hydro")
            }
            Divider()
            ForEach(Array(showHideOptions.enumerated()), id: \.offset) { _, opt in
                if opt.label == "---" {
                    Divider()
                } else if let rep = opt.rep, rep != "everything" {
                    // "everything" is meaningful for Hide but not Show — you
                    // can't turn on every representation at once sensibly.
                    Button(opt.label) {
                        engine.runCommand("show \(rep), \(name)")
                    }
                }
            }
        } label: {
            Text("S")
                .frame(width: kActBtnW, height: kActBtnH)
                .background(PanelTheme.buttonBackground)
                .cornerRadius(2)
                .contentShape(Rectangle())
        }
        .repMenuChrome()
    }
}

// MARK: - Hide (H) Menu Button

private struct HideButton: View {
    let name: String
    @EnvironmentObject var engine: PyMOLEngine

    var body: some View {
        Menu {
            Button("side chains") {
                engine.runCommand("hide sticks, (\(name)) and (sidechain or name CA); hide lines, (\(name)) and (sidechain or name CA)")
            }
            // Hydrogens are a selection, not a rep, so they sit beside "side
            // chains" rather than in the shared rep list (#353). Mirrors
            // upstream mol_hide's hydrogens submenu (menu.py hide_hydro).
            Menu("hydrogens") {
                Button("all") {
                    engine.runCommand("hide (\(name) and hydro)")
                }
                Button("nonpolar") {
                    engine.runCommand("hide (\(name) and hydro and (elem C extend 1))")
                }
            }
            Divider()
            ForEach(Array(showHideOptions.enumerated()), id: \.offset) { _, opt in
                if opt.label == "---" {
                    Divider()
                } else if let rep = opt.rep {
                    Button(opt.label) {
                        engine.runCommand("hide \(rep), \(name)")
                    }
                }
            }
        } label: {
            Text("H")
                .frame(width: kActBtnW, height: kActBtnH)
                .background(PanelTheme.buttonBackground)
                .cornerRadius(2)
                .contentShape(Rectangle())
        }
        .repMenuChrome()
    }
}

// MARK: - Label (L) Menu Button

private struct LabelMenuButton: View {
    let name: String
    @EnvironmentObject var engine: PyMOLEngine

    var body: some View {
        Menu {
            ForEach(Array(labelOptions.enumerated()), id: \.offset) { _, opt in
                if opt.label == "---" {
                    Divider()
                } else if let expr = opt.expr {
                    Button(opt.label) {
                        if expr.isEmpty {
                            engine.runCommand("label \(name)")
                        } else {
                            engine.runCommand("label \(name), \(expr)")
                        }
                    }
                }
            }
        } label: {
            Text("L")
                .frame(width: kActBtnW, height: kActBtnH)
                .background(PanelTheme.buttonBackground)
                .cornerRadius(2)
                .contentShape(Rectangle())
        }
        .repMenuChrome()
    }
}

// MARK: - Color (C) Menu Button

private struct ColorMenuButton: View {
    let name: String
    @EnvironmentObject var engine: PyMOLEngine
    @State private var customColor: Color = .white
    @State private var showCustom = false

    var body: some View {
        Menu {
            ForEach(Array(colorOptions.enumerated()), id: \.offset) { _, opt in
                if opt.label == "---" {
                    Divider()
                } else if let command = opt.command {
                    Button {
                        applyColor(command: command)
                    } label: {
                        HStack(spacing: 6) {
                            if let swatch = opt.swatch {
                                Circle()
                                    .fill(swatch)
                                    .frame(width: 10, height: 10)
                            }
                            Text(opt.label)
                        }
                    }
                }
            }
            Divider()
            // A ColorPicker can't live inside a Menu (it renders disabled), so
            // "Custom…" opens a popover that hosts a working ColorPicker.
            Button("Custom…") { showCustom = true }
        } label: {
            Text("C")
                .frame(width: kActBtnW, height: kActBtnH)
                .background(PanelTheme.buttonBackground)
                .cornerRadius(2)
                .contentShape(Rectangle())
        }
        .repMenuChrome()
        .popover(isPresented: $showCustom, arrowEdge: .bottom) {
            VStack(spacing: 8) {
                Text("Custom color").font(.system(size: 11, weight: .semibold))
                DebouncedColorPicker(get: { customColor },
                                     apply: { customColor = $0; applyCustomColor($0) })
            }
            .padding(12)
        }
    }

    private func applyColor(command: String) {
        if command.hasPrefix("util.") {
            let funcName = String(command.dropFirst(5))
            engine.runCommand("python\ncmd.util.\(funcName)('\(name)')\npython end")
        } else if command == "spectrum" {
            engine.runCommand("spectrum count, selection=\(name)")
        } else if command == "spectrum_b" {
            // Color by B-factor: blue (low) → white → red (high), the classic
            // temperature look. Falls back gracefully if b is uniform/zero.
            engine.runCommand("spectrum b, blue_white_red, \(name)")
        } else {
            engine.runCommand("color \(command), \(name)")
        }
    }

    private func applyCustomColor(_ color: Color) {
        engine.runCommand("set_color raymol_custom, \(rgb01List(color))\ncolor raymol_custom, \(name)")
    }
}

// MARK: - Inspector: color helpers

private func colorFromHex(_ hex: String) -> Color? {
    var s = hex
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6, let v = Int(s, radix: 16) else { return nil }
    return Color(.sRGB,
                 red: Double((v >> 16) & 0xff) / 255.0,
                 green: Double((v >> 8) & 0xff) / 255.0,
                 blue: Double(v & 0xff) / 255.0)
}

/// A ColorPicker whose apply action is debounced. SwiftUI fires the binding's
/// `set:` on every tick of the color-wheel drag, which otherwise floods the
/// core with set_color + recolor each tick (review L-58 — a recolor is far
/// heavier than a `set`). We show the dragged color live but coalesce the
/// actual apply to ~150 ms after the last change, mirroring LabeledSlider.
struct DebouncedColorPicker: View {
    let get: () -> Color
    let apply: (Color) -> Void
    @State private var pending: Color? = nil
    @State private var work: DispatchWorkItem? = nil

    var body: some View {
        ColorPicker("", selection: Binding(
            get: { pending ?? get() },
            set: { c in
                pending = c                 // live: track the dragged color
                work?.cancel()
                let w = DispatchWorkItem { apply(c) }   // debounced: hit the core
                work = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w)
            }))
            .labelsHidden()
    }
}

/// SwiftUI Color → PyMOL set_color list "[r,g,b]" in 0…1.
private func rgb01List(_ color: Color) -> String {
#if canImport(AppKit)
    let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.white
    return String(format: "[%.3f,%.3f,%.3f]", ns.redComponent, ns.greenComponent, ns.blueComponent)
#elseif canImport(UIKit)
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
    return String(format: "[%.3f,%.3f,%.3f]", r, g, b)
#else
    return "[1,1,1]"
#endif
}

private func sanitizeName(_ s: String) -> String {
    String(s.map { $0.isLetter || $0.isNumber ? $0 : "_" })
}

private let inspectorNamedColors: [(name: String, color: Color)] = [
    ("red", .red), ("green", Color(.sRGB, red: 0, green: 0.9, blue: 0)),
    ("blue", Color(.sRGB, red: 0.1, green: 0.3, blue: 1)),
    ("yellow", .yellow), ("orange", .orange),
    ("magenta", Color(.sRGB, red: 1, green: 0, blue: 1)), ("cyan", .cyan),
    ("grey70", Color(.sRGB, white: 0.7)), ("grey30", Color(.sRGB, white: 0.3)),
    ("white", .white), ("black", .black),
]

// MARK: - Inspector controls

/// Slider + editable numeric field, debounced live updates, exact commit.
private struct LabeledSlider: View {
    let prop: RepProperty
    let value: Double
    let onLive: (Double) -> Void
    let onCommit: (Double) -> Void
    // When set, caps the slider's width (used by the camera dock); nil = fill the
    // available width, the inspector's default.
    var sliderMaxWidth: CGFloat? = nil

    @State private var local: Double = 0
    @State private var text: String = ""
    @State private var editing = false
    @State private var debounce: DispatchWorkItem?
    @State private var lastLiveAt: Date = .distantPast

    var body: some View {
        HStack(spacing: 6) {
            // Continuous (no `step`): a stepped Slider draws busy tick marks on
            // macOS. Values are rounded for display (fmt) and when applied
            // (fmtScene / the mm/zoom mappings), so dropping the step only removes
            // the ticks, not the effective granularity.
            Slider(value: $local, in: prop.min...prop.max,
                   onEditingChanged: { began in
                       editing = began
                       if !began { onCommit(local) }
                   })
#if os(iOS)
                .controlSize(.regular)
                #else
    #if os(iOS)
            .controlSize(.regular)
            #else
            .controlSize(.mini)
            #endif
                #endif
            .frame(maxWidth: sliderMaxWidth)
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 10, design: .monospaced))
                .frame(width: 40)
                .foregroundColor(PanelTheme.textColor)
                .onSubmit {
                    if let v = Double(text) {
                        local = Swift.min(Swift.max(v, prop.min), prop.max)
                        onCommit(local)
                    }
                    text = fmt(local)
                }
        }
        .onAppear { local = value; text = fmt(value) }
        .onChange(of: value) { v in if !editing { local = v; text = fmt(v) } }
        .onChange(of: local) { v in
            text = fmt(v)
            if editing { scheduleLive(v) }
        }
    }

    private func fmt(_ v: Double) -> String { String(format: "%.\(prop.decimals)f", v) }
    // Leading-edge throttle (~30 Hz): fire onLive immediately during a
    // continuous drag, rate-limited, with a trailing call so the final value
    // always lands. A plain trailing debounce (cancel + reschedule on every
    // change) starved the update until the finger paused, so the view chased
    // the drag instead of tracking it — the perceived slider lag.
    private func scheduleLive(_ v: Double) {
        let interval = 0.033
        debounce?.cancel()
        let now = Date()
        let wait = interval - now.timeIntervalSince(lastLiveAt)
        if wait <= 0 {
            lastLiveAt = now
            onLive(v)
        } else {
            let w = DispatchWorkItem { lastLiveAt = Date(); onLive(v) }
            debounce = w
            DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: w)
        }
    }
}

private struct SegmentedSetting: View {
    let prop: RepProperty
    let value: Double
    let onSelect: (Double) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(prop.options.enumerated()), id: \.offset) { _, opt in
                let sel = abs(opt.value - value) < 0.5
                Button(action: { onSelect(opt.value) }) {
                    Text(opt.label)
                        .font(.system(size: 9, weight: sel ? .bold : .regular))
                        .frame(width: 20, height: 16)
                        .background(sel ? PanelTheme.selectionTextColor : PanelTheme.buttonBackground)
                        .foregroundColor(sel ? Color.black : PanelTheme.buttonText)
                }
                .buttonStyle(.plain)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

private struct ToggleSetting: View {
    let value: Double
    let onToggle: (Bool) -> Void
    // Optimistic local state. Previously the switch derived its position directly
    // from `value` (a ~500ms-lagged poll) on EVERY re-render, so it flickered /
    // snapped back: opening the panel, a rotation-driven refresh, or the gap
    // between a tap and the next poll would re-render with the stale value and
    // flip the switch (and its tint) back. Driving the switch from local @State
    // that changes ONLY on a user flip or a genuine polled-value change makes a
    // re-render with an unchanged value a no-op for the switch.
    @State private var isOn = false
    var body: some View {
        Toggle("", isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(PanelTheme.selectionTextColor)
            .onAppear { isOn = value > 0.5 }
            .onChange(of: value) { v in
                let want = v > 0.5
                if want != isOn { isOn = want }          // adopt real external changes
            }
            .onChange(of: isOn) { on in
                if on != (value > 0.5) { onToggle(on) }   // user flip → push once
            }
    }
}

/// Per-rep color OVERRIDE control (writes `<rep>_color`): Inherit / named / custom RGB.
private struct RepColorControl: View {
    let objName: String
    let rep: String
    let colorSetting: String
    let defaultColor: Int
    let colorState: String        // "inherit" or "#rrggbb"
    @EnvironmentObject var engine: PyMOLEngine

    var body: some View {
        HStack(spacing: 6) {
            swatch
            Menu {
                Button("Inherit") { setOverride("\(defaultColor)") }
                Divider()
                // Coloring schemes — atom-level (the standard PyMOL behavior); this
                // rep is reset to inherit so the scheme shows through on it.
                Button("by element")  { applyScheme("util.cnc") }
                Button("by chain")    { applyScheme("util.cbc") }
                Button("by ss")       { applyScheme("util.cbss") }
                Button("spectrum")    { applyScheme("spectrum") }
                Button("by b-factor") { applyScheme("spectrum_b") }
                Divider()
                ForEach(Array(inspectorNamedColors.enumerated()), id: \.offset) { _, c in
                    Button(action: { setOverride(c.name) }) {
                        Label(c.name, systemImage: "circle.fill")
                    }
                }
            } label: {
                Text(colorState == "inherit" ? "Inherit" : "Custom")
                    .font(.system(size: 10))
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .frame(maxWidth: 70)
            DebouncedColorPicker(get: { colorFromHex(colorState) ?? .white },
                                 apply: { applyCustom($0) })
                .frame(width: 28)
        }
    }

    @ViewBuilder private var swatch: some View {
        if colorState == "inherit" {
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(PanelTheme.disabledColor, lineWidth: 1)
                .frame(width: 14, height: 14)
        } else {
            RoundedRectangle(cornerRadius: 3)
                .fill(colorFromHex(colorState) ?? .gray)
                .frame(width: 14, height: 14)
        }
    }

    private func setOverride(_ c: String) {
        engine.runCommand("set \(colorSetting), \(c), \(objName)")
    }
    // Apply an atom-level coloring scheme, resetting this rep to inherit so the
    // scheme is visible on it (PyMOL has no true per-rep scheme coloring).
    private func applyScheme(_ s: String) {
        setOverride("\(defaultColor)")
        switch s {
        case "spectrum":
            engine.runCommand("spectrum count, selection=\(objName)")
        case "spectrum_b":
            engine.runCommand("spectrum b, blue_white_red, \(objName)")
        default:   // util.cnc / util.cbc / util.cbss
            engine.runCommand("python\ncmd.\(s)('\(objName)')\npython end")
        }
    }
    private func applyCustom(_ color: Color) {
        let nm = "tmp_\(sanitizeName(objName))_\(rep)"
        engine.runCommand("set_color \(nm), \(rgb01List(color))\nset \(colorSetting), \(nm), \(objName)")
    }
}

/// Color control bound to an arbitrary per-rep color setting (e.g.
/// surface_contour_color). "Inherit" sets -1 (here the surface color); named
/// colors / the custom picker set an explicit color. Mirrors RepColorControl but
/// without the atom-coloring schemes (which don't apply to a contour line).
private struct SettingColorControl: View {
    let objName: String
    let rep: String
    let setting: String
    let colorState: String        // "inherit" or "#rrggbb"
    @EnvironmentObject var engine: PyMOLEngine

    var body: some View {
        HStack(spacing: 6) {
            swatch
            Menu {
                Button("Inherit") { setColor("-1") }
                Divider()
                ForEach(Array(inspectorNamedColors.enumerated()), id: \.offset) { _, c in
                    Button(action: { setColor(c.name) }) {
                        Label(c.name, systemImage: "circle.fill")
                    }
                }
            } label: {
                Text(colorState == "inherit" ? "Inherit" : "Custom")
                    .font(.system(size: 10))
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .frame(maxWidth: 70)
            DebouncedColorPicker(get: { colorFromHex(colorState) ?? .white },
                                 apply: { applyCustom($0) })
                .frame(width: 28)
        }
    }

    @ViewBuilder private var swatch: some View {
        if colorState == "inherit" {
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(PanelTheme.disabledColor, lineWidth: 1)
                .frame(width: 14, height: 14)
        } else {
            RoundedRectangle(cornerRadius: 3)
                .fill(colorFromHex(colorState) ?? .gray)
                .frame(width: 14, height: 14)
        }
    }

    private func setColor(_ c: String) {
        engine.runCommand("set \(setting), \(c), \(objName)")
    }
    private func applyCustom(_ color: Color) {
        let nm = "tmp_\(sanitizeName(objName))_\(rep)_ctr"
        engine.runCommand("set_color \(nm), \(rgb01List(color))\nset \(setting), \(nm), \(objName)")
    }
}

/// Object-level (Layer-1) color: presets + named + custom; affects all reps on "Inherit".
private struct ObjectColorRow: View {
    let objName: String
    @EnvironmentObject var engine: PyMOLEngine

    var body: some View {
        HStack(spacing: 6) {
            Text("Object color")
                .font(.system(size: 10))
                .foregroundColor(PanelTheme.headerColor)
            Spacer()
            Menu {
                Button("by element") { engine.runCommand("python\ncmd.util.cnc('\(objName)')\npython end") }
                Button("by chain")   { engine.runCommand("python\ncmd.util.cbc('\(objName)')\npython end") }
                Button("by ss")      { engine.runCommand("python\ncmd.util.cbss('\(objName)')\npython end") }
                Button("spectrum")   { engine.runCommand("spectrum count, selection=\(objName)") }
                Divider()
                ForEach(Array(inspectorNamedColors.enumerated()), id: \.offset) { _, c in
                    Button(c.name) { engine.runCommand("color \(c.name), \(objName)") }
                }
            } label: {
                Text("Set").font(.system(size: 10))
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .frame(maxWidth: 60)
            DebouncedColorPicker(get: { .white }, apply: { applyCustom($0) })
                .frame(width: 28)
        }
        .padding(.vertical, 2)
    }

    private func applyCustom(_ color: Color) {
        let nm = "tmp_\(sanitizeName(objName))_obj"
        engine.runCommand("set_color \(nm), \(rgb01List(color))\ncolor \(nm), \(objName)")
    }
}

// MARK: - Object row content (shared by selection rows and object cards)

private struct ObjectRowContent: View {
    let entry: ObjectEntry
    // Tri-state for group rows (some descendants on). Defaults keep the plain
    // object/selection behaviour for callers that don't compute it.
    var check: CheckState? = nil
    @EnvironmentObject var engine: PyMOLEngine

    var body: some View {
        Button(action: { toggleEnabled() }) {
            checkboxImage(check ?? (entry.isEnabled ? .on : .off))
        }
        .buttonStyle(.plain)
        // A pending prediction placeholder has no atoms, so showing/hiding it is
        // meaningless. Disabled rather than hidden, so the row still reads as a real
        // object that is on its way.
        .disabled(entry.isPending)
        .opacity(entry.isPending ? 0.35 : 1.0)
        .frame(width: kGutterW)

        Text(entry.displayName)
            .font(.system(size: 11))
            .fontWeight(entry.isGroup ? .semibold : .regular)
            .foregroundColor(entry.isSelection ? PanelTheme.selectionTextColor : PanelTheme.textColor)
            .lineLimit(1)
            .truncationMode(.tail)
            .contentShape(Rectangle())
            .onTapGesture { toggleEnabled() }   // tap name = toggle enable
            // #350: a row's fixed chrome (gutter + five action buttons) leaves the
            // name column narrow, so names that differ only in a long suffix
            // ("…_relaxed_model_2") truncate to the same thing. Widening the panel
            // is the fix; this tooltip reads the full name without resizing at all.
            .help(entry.displayName)

        // Model / state count, right of the name (the structure's "frame count").
        if entry.stateCount > 1 {
            Text("\(entry.stateCount)")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundColor(PanelTheme.headerColor)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(Capsule().fill(PanelTheme.buttonBackground))
                .help("\(entry.stateCount) models / states")
        }

        // Discoverability badge: this object has per-atom transparency overrides,
        // so the object-level transparency slider doesn't reflect what's rendered.
        // Visible even when the card is collapsed. Expand to see the range + Clear.
        if entry.hasAtomTransp {
            Image(systemName: "drop.halffull")
                .font(.system(size: 10))
                .foregroundColor(PanelTheme.atomTranspColor)
                .help("Per-atom transparency is set — the object-level transparency slider won’t fully apply. Expand a representation to view the range or clear it.")
                .accessibilityLabel("Per-atom transparency set")
        }

        Spacer(minLength: 4)

        ActionMenuButton(name: entry.name, isSelection: entry.isSelection)
        ShowButton(name: entry.name)
        HideButton(name: entry.name)
        LabelMenuButton(name: entry.name)
        ColorMenuButton(name: entry.name)
    }

    private func toggleEnabled() {
        engine.setObjectEnabled(entry.name, !entry.isEnabled)
    }
}

// MARK: - Expandable object card

private struct ObjectCard: View {
    let entry: ObjectEntry
    let isAlt: Bool
    // Group-tree presentation (#255). All defaulted so the preview/memberwise
    // call sites that predate the tree keep compiling.
    var depth: Int = 0
    var check: CheckState = .on
    var dimmed: Bool = false
    var isOpen: Bool = false
    var onToggleGroup: (() -> Void)? = nil
    @EnvironmentObject var engine: PyMOLEngine
    @State private var selectedRep: String?
    // Live state-slider value while dragging (nil = follow the object poll). Keeps
    // the thumb from snapping back to the last-polled state mid-drag.
    @State private var scrubState: Int? = nil

    private var expanded: Bool { engine.expandedDetail == entry.name }
    private var reps: [RepState] { engine.objectDetails[entry.name] ?? [] }
    // Reps currently SHOWN (have drawn atoms, from the poll).
    private var activeSet: Set<String> { Set(reps.map { $0.rep }) }
    // Reps hidden via the Visible toggle but kept listed as layers.
    private var keptHidden: Set<String> { engine.keptHidden[entry.name] ?? [] }
    // Layers shown in the inspector = shown ∪ kept-hidden, in catalog order.
    private var listedReps: [String] {
        RepCatalog.order.filter { activeSet.contains($0) || keptHidden.contains($0) }
    }
    private var currentRep: String? {
        if let s = selectedRep, listedReps.contains(s) { return s }
        return listedReps.first
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                // Indent nested members. Applied in THIS HStack, before the
                // chevron — ObjectRowContent is a bare column tuple spliced into
                // this stack, so wrapping it to indent would break its alignment
                // with the selection and "all" rows.
                if depth > 0 {
                    Spacer().frame(width: kIndentW * CGFloat(min(depth, kMaxIndentDepth)))
                }
                // Groups get +/-, plain objects keep the chevron, because the two
                // disclosures do genuinely DIFFERENT things: +/- expands the
                // group's children, the chevron opens that object's rep inspector.
                // Sharing one glyph read as a single behaviour that sometimes
                // produced a subtree and sometimes a settings card. The group's own
                // rep card is reached from the A menu ("Inspect Group…").
                // CIRCLE variants, not square and not bare: the tri-state checkbox
                // immediately to the right is minus.square.fill, and an expanded
                // group would otherwise put a bare "-" right beside a boxed "[-]".
                // The enclosing shape is what separates them at a glance.
                Button(action: { entry.isGroup ? (onToggleGroup?() ?? ()) : toggleExpand() }) {
                    Image(systemName: entry.isGroup
                          ? (isOpen ? "minus.circle" : "plus.circle")
                          : (expanded ? "chevron.down" : "chevron.right"))
                        .font(.system(size: entry.isGroup ? 10 : 9))
                        .foregroundColor(PanelTheme.headerColor)
                        .frame(width: 13)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(entry.isGroup
                    ? "\(isOpen ? "Collapse" : "Expand") group \(entry.name)"
                    : "\(expanded ? "Collapse" : "Expand") \(entry.name)")
                ObjectRowContent(entry: entry, check: check)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .frame(height: kRowH)
            .background(isAlt ? PanelTheme.rowAltBackground : PanelTheme.rowBackground)
            // A member hidden by a disabled ancestor is dimmed: it still reports
            // enabled, so without this the box reads as checked while nothing is
            // on screen. Opacity rather than a new colour, because the A/S/H/L/C
            // cells compute their own.
            .opacity(dimmed ? 0.45 : 1.0)
            // Whole HEADER-row tap toggles enable. Applied to the header HStack
            // only (NOT the outer VStack) so the expanded rep-detail below stays
            // interactive. The disclosure chevron Button and the trailing
            // A/S/H/L/C controls consume their own taps (expand-only for the
            // chevron); only the dead Spacer gap falls through to here.
            .contentShape(Rectangle())
            .onTapGesture {
                // Same reason the checkbox is disabled: nothing to show until the job
                // lands. Guarded here too, or the dead gap in the row would still toggle.
                guard !entry.isPending else { return }
                engine.setObjectEnabled(entry.name, !entry.isEnabled)
            }
            // Hover detail for a running prediction: phase and progress, refreshed by the
            // 500 ms panel poll. `.help` is a tooltip on macOS and a no-op on iOS.
            .help(entry.pendingDetail ?? "")
            // Long-press (iOS) / right-click (macOS) opens the action menu.
            .contextMenu { actionMenuContent(actionMenuItems(isSelection: entry.isSelection, isGroup: entry.isGroup), name: entry.name, engine: engine) }

            if expanded {
                VStack(spacing: 3) {
                    // Multi-state objects (NMR models / trajectory frames) get a
                    // STATE row: pin this object to a state independent of the
                    // global timeline, overlay all states, or fit/split them.
                    if entry.stateCount > 1 {
                        stateRow()
                        Divider().background(PanelTheme.disabledColor.opacity(0.3))
                    }
                    // Object/layer-level coloring (by element/chain/ss/spectrum/
                    // named) is the structure row's "C" button — not duplicated
                    // here. The per-rep grid below controls per-rep color overrides.
                    // Always show the chips bar (it holds the "+" add menu) so a
                    // layer can be added even after the last one is deleted.
                    RepChips(objName: entry.name, listed: listedReps,
                             active: activeSet, current: currentRep,
                             onSelect: { selectedRep = $0 })
                    if let rep = currentRep {
                        // Always present (even when hidden): show/hide the layer
                        // + delete it. Hiding keeps the layer listed so it can be
                        // toggled back on; the X removes it.
                        layerHeader(rep)
                        // Full per-rep settings only while the layer is shown
                        // (a hidden layer reports no state).
                        if let spec = RepCatalog.spec(rep),
                           let st = reps.first(where: { $0.rep == rep }) {
                            RepPropertyGrid(objName: entry.name, spec: spec, state: st)
                        }
                    } else {
                        Text("No representations shown — tap + to add one.")
                            .font(.system(size: 10))
                            .foregroundColor(PanelTheme.disabledColor)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.leading, 18)
                .padding(.trailing, 8)
                .padding(.vertical, 4)
                .background(PanelTheme.rowAltBackground.opacity(0.6))
            }
        }
    }

    private func toggleExpand() {
        // Accordion: opening this card closes whatever else was open.
        engine.expandedDetail = expanded ? nil : entry.name
    }

    // Per-object STATE controls for multi-state objects (NMR / trajectory).
    // The slider/steppers PIN this object to a state via `set state, N, obj`
    // (so it stops following the global timeline); "Sync" un-pins it. Distinct
    // from the global "Overlay all states" in the SCENE card.
    @ViewBuilder
    private func stateRow() -> some View {
        let total = max(entry.stateCount, 1)
        let meta = engine.objectMeta[entry.name]
        // Use the object's effective state from the poll; default to 1 (avoid
        // depending on playback.currentFrame so the inspector doesn't re-render
        // on every frame tick during playback).
        // While dragging, show the live scrub value; otherwise follow the poll.
        let cur = min(max(scrubState ?? meta?.state ?? 1, 1), total)
        VStack(spacing: 3) {
            HStack(spacing: 6) {
                Text("State")
                    .font(.system(size: 10)).foregroundColor(PanelTheme.textColor)
                    .frame(width: 78, alignment: .leading)
                Button { scrubState = nil; setState(max(cur - 1, 1)) } label: {
                    Image(systemName: "minus.circle").font(.system(size: 14))
                }
                .buttonStyle(.plain).foregroundColor(TimelineTheme.accent)
                Slider(value: Binding(get: { Double(cur) },
                                      set: { v in
                                          let n = min(max(Int(v.rounded()), 1), total)
                                          if n != cur { scrubState = n; setState(n) }  // apply only on integer change
                                      }),
                       in: 1...Double(max(total, 2)), step: 1,
                       onEditingChanged: { editing in if !editing { scrubState = nil } })
                    .tint(TimelineTheme.accent)
                Button { scrubState = nil; setState(min(cur + 1, total)) } label: {
                    Image(systemName: "plus.circle").font(.system(size: 14))
                }
                .buttonStyle(.plain).foregroundColor(TimelineTheme.accent)
                Text("\(cur)/\(total)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(PanelTheme.textColor)
                    .frame(width: 42, alignment: .trailing)
            }
            // Compound name for this state, when present (e.g. a multi-record
            // SDF's per-record title), so docking-pose / library sets can be
            // navigated by name while scrubbing states (issue #203).
            if let name = meta?.title(forState: cur) {
                HStack(spacing: 6) {
                    Text("Name")
                        .font(.system(size: 10)).foregroundColor(PanelTheme.textColor)
                        .frame(width: 78, alignment: .leading)
                    Text(name)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(TimelineTheme.accent)
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(name)
                    Spacer(minLength: 0)
                }
            }
            // Play/pause + per-object fps — animates THIS object's models (via a
            // Swift timer + `set state`), independent of the movie and other objects.
            HStack(spacing: 6) {
                Text("Play")
                    .font(.system(size: 10)).foregroundColor(PanelTheme.textColor)
                    .frame(width: 78, alignment: .leading)
                Button { engine.toggleObjectStates(entry.name) } label: {
                    Image(systemName: engine.playingObjects.contains(entry.name) ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(engine.timelineMode ? PanelTheme.disabledColor : TimelineTheme.accent)
                        .frame(width: 24, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(engine.timelineMode)   // authoring a movie → model playback off
                // A disabled Button swallows its own hover events, so `.help()` on
                // it never fires. Wrap it so the tooltip lives on a non-disabled
                // container that still receives hover while playback is off.
                .allowsHitTesting(!engine.timelineMode)
                .overlay {
                    if engine.timelineMode {
                        Color.clear.contentShape(Rectangle())
                            .help("Model playback is off while the movie timeline is open — close it to inspect models")
                    }
                }
                .help(engine.playingObjects.contains(entry.name) ? "Pause" : "Play models")
                #if os(iOS)
                // On iOS `.help()` degrades to a VoiceOver-only hint with no visible
                // surface, so the macOS hover tooltip added in #144 never reaches a
                // touch user — they just see a greyed-out Play button with no reason.
                // Surface the same explanation as a tappable (?) that reveals it in a
                // popover. macOS keeps its hover tooltip and is left untouched.
                if engine.timelineMode {
                    HelpButton(text: "Model playback is off while the movie timeline is open — close it to inspect models.")
                }
                #endif
                Spacer(minLength: 0)
                Menu {
                    ForEach([1.0, 5.0, 10.0, 15.0, 30.0], id: \.self) { f in
                        Button("\(Int(f)) fps") { engine.setObjectFPS(entry.name, f) }
                    }
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "speedometer").font(.system(size: 9))
                        Text("\(Int(engine.objectPlaybackFPS(entry.name))) fps")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(TimelineTheme.accent)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Playback speed for this object")
            }
            HStack(spacing: 6) {
                Text("Overlay all")
                    .font(.system(size: 10)).foregroundColor(PanelTheme.textColor)
                    .frame(width: 78, alignment: .leading)
                ToggleSetting(value: (meta?.overlayAll ?? false) ? 1 : 0) { on in
                    engine.runCommand("set all_states, \(on ? 1 : 0), \(entry.name)")
                }
                Spacer(minLength: 0)
                stateActionButton("Fit") { engine.runCommand("intra_fit \(entry.name)") }
                stateActionButton("Split") { engine.runCommand("split_states \(entry.name)") }
                stateActionButton("Sync") { engine.runCommand("unset state, \(entry.name)") }
            }
        }
    }

    private func setState(_ n: Int) {
        engine.runCommand("set state, \(n), \(entry.name)")
    }

    private func stateActionButton(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(PanelTheme.buttonBackground)
                .foregroundColor(PanelTheme.buttonText)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // Visible toggle + delete (X) for the current layer. Shown whether the layer
    // is visible or hidden — hiding keeps it listed (toggle back on to reset),
    // the X removes the layer entirely.
    @ViewBuilder
    private func layerHeader(_ rep: String) -> some View {
        let shown = activeSet.contains(rep)
        HStack(spacing: 6) {
            Text("Visible")
                .font(.system(size: 10))
                .foregroundColor(PanelTheme.textColor)
                .frame(width: 78, alignment: .leading)
            ToggleSetting(value: shown ? 1 : 0) { on in
                if on {
                    engine.runCommand("show \(rep), \(entry.name)")
                    engine.keptHidden[entry.name]?.remove(rep)
                } else {
                    engine.runCommand("hide \(rep), \(entry.name)")
                    engine.keptHidden[entry.name, default: []].insert(rep)
                }
            }
            Spacer(minLength: 0)
            Button {
                engine.runCommand("hide \(rep), \(entry.name)")
                engine.keptHidden[entry.name]?.remove(rep)
                if selectedRep == rep { selectedRep = nil }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundColor(PanelTheme.disabledColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete \(RepCatalog.display(rep)) layer")
        }
    }
}

// MARK: - Representation chips

private struct RepChips: View {
    let objName: String
    let listed: [String]        // shown ∪ kept-hidden, in catalog order
    let active: Set<String>     // currently shown (others are dimmed = hidden)
    let current: String?
    let onSelect: (String) -> Void
    @EnvironmentObject var engine: PyMOLEngine

    // The "+" menu offers only reps not already listed as a layer.
    private var inactive: [String] {
        RepCatalog.order.filter { !listed.contains($0) }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(listed, id: \.self) { rep in
                    let sel = rep == current
                    let shown = active.contains(rep)
                    Button(action: { onSelect(rep) }) {
                        Text(RepCatalog.display(rep))
                            .font(.system(size: 9, weight: sel ? .bold : .regular))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(sel ? PanelTheme.selectionTextColor : PanelTheme.buttonBackground)
                            .foregroundColor(sel ? Color.black : PanelTheme.buttonText)
                            .opacity(shown ? 1.0 : 0.4)   // hidden layers are dimmed
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Menu {
                    ForEach(inactive, id: \.self) { rep in
                        Button(RepCatalog.display(rep)) {
                            engine.runCommand("show \(rep), \(objName)")
                            engine.keptHidden[objName]?.remove(rep)
                            onSelect(rep)
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(PanelTheme.buttonBackground)
                        .foregroundColor(PanelTheme.buttonText)
                        .clipShape(Capsule())
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
    }
}

// MARK: - Property grid

private struct RepPropertyGrid: View {
    let objName: String
    let spec: RepSpec
    let state: RepState
    @EnvironmentObject var engine: PyMOLEngine

    var body: some View {
        VStack(spacing: 3) {
            if !spec.colorSetting.isEmpty {
                gridRow("Color") {
                    RepColorControl(objName: objName, rep: spec.rep,
                                    colorSetting: spec.colorSetting,
                                    defaultColor: spec.defaultColor,
                                    colorState: state.color)
                }
            }
            ForEach(spec.properties) { p in
                gridRow(p.label) { control(for: p) }
                // Per-atom transparency detail sits directly under the matching
                // transparency slider so it's clear the slider is only a baseline.
                if let at = state.atomTransp, at.setting == p.setting {
                    atomTranspRow(at)
                }
            }
            // Fallback: surface the detail even if this rep's spec has no slider
            // for its transparency setting (so the info is never lost).
            if let at = state.atomTransp,
               !spec.properties.contains(where: { $0.setting == at.setting }) {
                atomTranspRow(at)
            }
        }
        .padding(.top, 2)
    }

    // "per-atom: min–max" readout + a Clear action, shown when atom-level
    // transparency overrides the object-level slider for this rep.
    @ViewBuilder
    private func atomTranspRow(_ at: AtomTransp) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "drop.halffull").font(.system(size: 10))
            Text("per-atom: \(rangeLabel(at))").font(.system(size: 10))
            Spacer(minLength: 4)
            Button(action: { clearAtomTransp(at.setting) }) {
                Text("Clear")
                    .font(.system(size: 10))
                    .padding(.horizontal, 8).padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 4)
                        .stroke(PanelTheme.atomTranspColor.opacity(0.55), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
        }
        .foregroundColor(PanelTheme.atomTranspColor)
        .padding(.leading, 84)   // align under the control column (label width 78 + gap)
        .help("Some atoms set \(at.setting) individually, so the slider above only sets a baseline. Clear removes the per-atom values and hands control back to the slider.")
    }

    private func rangeLabel(_ at: AtomTransp) -> String {
        let lo = fmtTransp(at.min), hi = fmtTransp(at.max)
        return lo == hi ? lo : "\(lo)–\(hi)"
    }

    private func fmtTransp(_ v: Double) -> String {
        var s = String(format: "%.2f", v)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }

    // Remove the per-atom overrides for `setting` on this object. The
    // atom-selection form `unset(setting, (obj))` clears atom-level values while
    // keeping the object-level slider value; a rebuild refreshes the baked
    // cartoon/surface geometry, then re-poll so the row disappears promptly.
    private func clearAtomTransp(_ setting: String) {
        engine.runCommand("unset \(setting), (\(objName))")
        engine.runCommand("rebuild \(objName)")
        engine.refreshExpandedDetail()
    }

    @ViewBuilder
    private func control(for p: RepProperty) -> some View {
        let v = state.values[p.setting] ?? 0
        switch p.kind {
        case .slider:
            // commitOnly props skip live updates — they apply once on release
            // (avoids re-running an expensive rebuild on every drag tick).
            LabeledSlider(prop: p, value: v,
                          onLive: { if !p.commitOnly { set(p.setting, $0) } },
                          onCommit: { set(p.setting, $0) })
        case .segmented:
            SegmentedSetting(prop: p, value: v) { set(p.setting, $0) }
        case .toggle:
            ToggleSetting(value: v) { set(p.setting, $0 ? 1 : 0) }
        case .color:
            // A standalone color control bound to an arbitrary color setting
            // (e.g. surface_contour_color). -1 = inherit (here: the surface color).
            SettingColorControl(objName: objName, rep: spec.rep, setting: p.setting,
                                colorState: state.settingColors[p.setting] ?? "inherit")
        }
    }

    private func set(_ setting: String, _ value: Double) {
        let s = (value == value.rounded()) ? String(Int(value)) : String(format: "%.4f", value)
        engine.runCommand("set \(setting), \(s), \(objName)")
    }

    @ViewBuilder
    private func gridRow<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(PanelTheme.textColor)
                .frame(width: 78, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Scene (global) card

// Small (?) affordance that reveals a one-line description on click (and on hover).
private struct HelpButton: View {
    let text: String
    @State private var show = false
    var body: some View {
        Button { show.toggle() } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 11))
                .foregroundColor(PanelTheme.disabledColor)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(text)
        .popover(isPresented: $show, arrowEdge: .trailing) {
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(PanelTheme.textColor)
                .frame(width: 230, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
        }
    }
}

// Non-private: also hosted in the Settings tab (ContentView.settingsPane) now
// that SCENE lives fully under Settings rather than the Inspector.
struct SceneCard: View {
    @EnvironmentObject var engine: PyMOLEngine
    @State private var showSettings = false
    // Per-sub-group expand state; the heavier groups start collapsed.
    @State private var openGroups: Set<String> = ["Canvas", "Camera", "Lighting", "Effects"]
    // Rendered as the BODY of the SCENE section; the collapsible header now lives
    // in ObjectPanel (shared with Objects / Selections).
    var body: some View {
        VStack(spacing: 3) {
            // Scene management (the strip) now lives in the dedicated Scenes tab;
            // this card holds the global DISPLAY settings only.
            ForEach(SceneCatalog.groups, id: \.self) { group in
                sceneGroup(group)
            }
            Button { showSettings = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.3")
                    Text("All settings…")
                    Spacer()
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(PanelTheme.selectionTextColor)
                .padding(.top, 4).padding(.bottom, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(PanelTheme.rowAltBackground.opacity(0.6))
        .sheet(isPresented: $showSettings) { SettingsSheet() }
    }

    // A collapsible sub-group of Scene settings (Canvas, Camera, Lighting, …).
    @ViewBuilder
    private func sceneGroup(_ group: String) -> some View {
        let isOpen = openGroups.contains(group)
        VStack(spacing: 3) {
            Button {
                if isOpen { openGroups.remove(group) } else { openGroups.insert(group) }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(PanelTheme.disabledColor)
                        .frame(width: 10)
                    Text(group.uppercased())
                        .font(.system(size: 9.5, weight: .semibold))
                        .tracking(0.4)
                        .foregroundColor(PanelTheme.headerColor)
                    Spacer()
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen {
                ForEach(SceneCatalog.params.filter { $0.group == group }) { p in
                    SceneParamRow(param: p, engine: engine)
                }
                if group == "Effects" { resetEffectsButton }
            }
        }
    }

    // One-tap restore of the Effects group to its built-in defaults. Filmic
    // tone-map (white → ~80% grey via ACES) and a dimmed exposure muddle the
    // whole frame, and the iOS autosave persists that look across launches with
    // no obvious cause — this gives an obvious way back to a neutral render.
    private var resetEffectsButton: some View {
        Button { resetEffects() } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.counterclockwise")
                Text("Reset effects to defaults")
                Spacer()
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(PanelTheme.selectionTextColor)
            .padding(.leading, 10).padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // Defaults live on the engine (engine.resetEffects) so the iOS toolbar reset
    // menu and this Inspector button share one source of truth. The ~500ms
    // scene-state poll re-syncs the toggles/sliders after the sets land.
    private func resetEffects() { engine.resetEffects() }

}

// MARK: - Shared scene-setting row + Camera dock

// One scene-setting row (label + control + help), shared by the inspector's
// Scene section (SceneCard) and the viewport camera dock (CameraDock).
// Self-hides when its dependsOn parent toggle is off, so callers render it
// unconditionally.
struct SceneParamRow: View {
    let param: SceneParam
    @ObservedObject var engine: PyMOLEngine
    // Compact layout for the camera dock: natural-width label and no trailing
    // Spacer, so the slider fills the row instead of splitting the space with a
    // Spacer (the dock card bounds the overall width). Inspector uses the default.
    var compact: Bool = false

    var body: some View {
        if let dep = param.dependsOn, (engine.sceneState.values[dep] ?? 0) <= 0.5 {
            EmptyView()
        } else {
            let rtUnavailable = param.setting == "metal_raytrace" && !engine.rayTracingSupported
            sceneRow(rtUnavailable ? "\(param.label) (unavailable)" : param.label, help: param.help) {
                sceneControl(param)
            }
            .padding(.leading, param.dependsOn != nil ? 12 : 0)
            .disabled(rtUnavailable)
            .opacity(rtUnavailable ? 0.45 : 1)
        }
    }

    @ViewBuilder
    private func sceneControl(_ p: SceneParam) -> some View {
        if p.isColor {
            DebouncedColorPicker(
                get: {
                    let c = (p.setting == "bg_rgb") ? engine.sceneState.bg : engine.sceneState.outlineColor
                    return Color(.sRGB, red: c.count > 0 ? c[0] : 0,
                                 green: c.count > 1 ? c[1] : 0, blue: c.count > 2 ? c[2] : 0)
                },
                apply: { c in
                    if p.setting == "bg_rgb" { setBackground(c) } else { setOutlineColor(c) }
                })
                .frame(width: 28)
        } else {
            let v = engine.sceneState.values[p.setting] ?? 0
            switch p.kind {
            case .toggle:
                if p.setting == "metal_dof_autofocus" {
                    // Enabling snapshots the current selection into "dof_focus" —
                    // the locked target the renderer tracks each frame (see the
                    // SceneRender auto-focus block). Disabling just clears the flag.
                    ToggleSetting(value: v) { on in
                        engine.runCommand(CameraCommands.setAutofocus(on))
                    }
                } else if p.setting == "hover_indicator" {
                    // Not a PyMOL setting: an app-level preference (persisted via
                    // UserDefaults) that gates the hover pre-selection preview.
                    ToggleSetting(value: engine.hoverPreviewEnabled ? 1 : 0) { on in
                        engine.hoverPreviewEnabled = on
                        if !on { engine.clearHoverPreview() }
                    }
                } else if p.setting == "hover_readout" {
                    // Likewise app-level (#359): gates the top-right identity chip.
                    // Turning it off clears the chip via the property's didSet; the
                    // hover pick itself keeps running only if the indicator is on.
                    ToggleSetting(value: engine.hoverReadoutEnabled ? 1 : 0) { on in
                        engine.hoverReadoutEnabled = on
                    }
                } else {
                    ToggleSetting(value: v) { on in engine.runCommand("set \(p.setting), \(on ? 1 : 0)") }
                }
            case .segmented:
                SegmentedSetting(prop: RepProperty(setting: p.setting, label: p.label, kind: .segmented, options: p.options),
                                 value: v) { engine.runCommand("set \(p.setting), \(Int($0))") }
            case .slider:
                if p.setting == "field_of_view" {
                    // Lens control: the slider is a 35mm-equivalent focal length (mm),
                    // shown by converting the polled field_of_view, and applied via
                    // set_fov (a dolly zoom) so it swaps perspective rather than
                    // zooming. Inert in orthoscopic mode.
                    let fovDeg = engine.sceneState.values["field_of_view"] ?? 20
                    let orthoOn = (engine.sceneState.values["ortho"] ?? 0) > 0.5
                    LabeledSlider(prop: RepProperty(setting: p.setting, label: p.label, kind: .slider,
                                                    min: p.min, max: p.max, step: p.step, decimals: p.decimals),
                                  value: fovToMM(fovDeg),
                                  onLive: { engine.runCommand("set_fov \(String(format: "%.3f", mmToFOV($0)))") },
                                  onCommit: { engine.runCommand("set_fov \(String(format: "%.3f", mmToFOV($0)))") })
                        .disabled(orthoOn)
                        .opacity(orthoOn ? 0.4 : 1.0)
                } else if p.setting == "zoom" {
                    // Zoom: absolute apparent MAGNIFICATION, independent of the Lens.
                    // M = scene_radius / (cam_dist * tan(fov/2)) is invariant under
                    // the Lens dolly-zoom, so the two sliders don't fight. Dragging
                    // dollies the camera to the target distance.
                    let camDist = engine.sceneState.values["cam_dist"] ?? 0
                    let radius = engine.sceneState.values["scene_radius"] ?? 0
                    let fovDeg = engine.sceneState.values["field_of_view"] ?? 20
                    let zoomReady = radius > 0 && camDist > 0
                    LabeledSlider(prop: RepProperty(setting: p.setting, label: p.label, kind: .slider,
                                                    min: p.min, max: p.max, step: p.step, decimals: p.decimals),
                                  value: zoomMag(camDist: camDist, radius: radius, fovDeg: fovDeg),
                                  onLive: { engine.setZoomMagnification($0, radius: radius, fovDeg: fovDeg) },
                                  onCommit: { engine.setZoomMagnification($0, radius: radius, fovDeg: fovDeg) })
                        .disabled(!zoomReady)
                        .opacity(zoomReady ? 1.0 : 0.4)
                } else {
                    // The DOF focus slider is driven by autofocus while it's on.
                    let dofAuto = p.setting == "metal_dof_focus"
                        && (engine.sceneState.values["metal_dof_autofocus"] ?? 0) > 0.5
                    LabeledSlider(prop: RepProperty(setting: p.setting, label: p.label, kind: .slider,
                                                    min: p.min, max: p.max, step: p.step, decimals: p.decimals),
                                  value: v,
                                  onLive: { engine.runCommand("set \(p.setting), \(fmtScene($0, p))") },
                                  onCommit: { engine.runCommand("set \(p.setting), \(fmtScene($0, p))") })
                        .disabled(dofAuto)
                        .opacity(dofAuto ? 0.4 : 1.0)
                }
            case .color:
                EmptyView()  // scene colors use p.isColor above, not the .color kind
            }
        }
    }

    private func fmtScene(_ v: Double, _ p: SceneParam) -> String {
        p.decimals == 0 ? String(Int(v.rounded())) : String(format: "%.4f", v)
    }

    // Lens control: map PyMOL's vertical field_of_view (degrees) to a 35mm-
    // equivalent focal length using the full-frame sensor height (24mm):
    //   fov = 2*atan(12/f)   <->   f = 12/tan(fov/2)
    // fovToMM clamps into the slider's mm range so the thumb never leaves bounds.
    private func fovToMM(_ fovDeg: Double) -> Double {
        let f = 12.0 / tan(fovDeg * .pi / 360.0)
        return min(max(f, 12.0), 135.0)
    }
    private func mmToFOV(_ mm: Double) -> Double {
        2.0 * atan(12.0 / mm) * 180.0 / .pi
    }

    // Apparent magnification for the Zoom slider: ~1 when the scene fits the view,
    // higher when zoomed in. Clamped to the slider's [0.5, 8] range.
    private func zoomMag(camDist: Double, radius: Double, fovDeg: Double) -> Double {
        let t = tan(fovDeg * .pi / 360.0)
        guard camDist > 1e-4, t > 1e-6, radius > 0 else { return 1.0 }
        return min(max(radius / (camDist * t), 0.5), 8.0)
    }

    private func setBackground(_ color: Color) {
        engine.runCommand("set_color _bgcol, \(rgb01List(color))\nbg_color _bgcol")
    }

    private func setOutlineColor(_ color: Color) {
        engine.runCommand("set_color _outlinecol, \(rgb01List(color))\nset metal_outline_color, _outlinecol")
    }

    @ViewBuilder
    private func sceneRow<Content: View>(_ label: String, help: String = "", @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(PanelTheme.textColor)
                .frame(width: compact ? nil : 110, alignment: .leading)
                .fixedSize(horizontal: compact, vertical: false)
            content()
            if !compact { Spacer(minLength: 0) }
            if !help.isEmpty { HelpButton(text: help) }
        }
    }
}

// The Depth-of-field sub-panel shown inside the camera dock when "Depth" is
// selected. Enabled + Auto lock share the top row (both switches); Focus and
// Aperture reuse the inspector rows and self-hide (dependsOn: metal_dof) until
// DOF is enabled. Quality is intentionally not here — it lives in the inspector.
struct DOFSubPanelContent: View {
    @ObservedObject var engine: PyMOLEngine
    private var dofOn: Bool { (engine.sceneState.values["metal_dof"] ?? 0) > 0.5 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "camera.metering.center.weighted")
                Text("Depth of field").font(.system(size: 13, weight: .medium))
                Spacer()
            }
            .foregroundColor(PanelTheme.textColor)
            .padding(.bottom, 2)

            HStack(spacing: 20) {
                dofToggle("Enabled", key: "metal_dof", id: "dof.enabled", enabled: true) { on in
                    engine.runCommand("set metal_dof, \(on ? 1 : 0)")
                }
                HStack(spacing: 5) {
                    dofToggle("Auto lock", key: "metal_dof_autofocus", id: "dof.autolock", enabled: dofOn) { on in
                        engine.runCommand(CameraCommands.setAutofocus(on))
                    }
                    HelpButton(text: "Auto lock focus keeps the current selection in sharp focus. Select the atoms you want sharp, then turn this on — the focus point tracks that selection as the camera moves. Off lets you set the focus distance by hand with the slider below.")
                }
                Spacer()
            }

            if let focus = SceneCatalog.param(for: "metal_dof_focus") {
                SceneParamRow(param: focus, engine: engine, compact: true)
            }
            if let aperture = SceneCatalog.param(for: "metal_dof_aperture") {
                SceneParamRow(param: aperture, engine: engine, compact: true)
            }
        }
    }

    private func dofToggle(_ label: String, key: String, id: String,
                           enabled: Bool, onToggle: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 11)).foregroundColor(PanelTheme.textColor)
            ToggleSetting(value: engine.sceneState.values[key] ?? 0, onToggle: onToggle)
                .accessibilityIdentifier(id)
                .accessibilityLabel(label)
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

// Bottom-docked camera control strip (Photos-app "Adjust" model): a row of icon
// buttons where one control opens at a time above the strip. Reuses SceneParamRow
// for every slider control so all camera logic stays in one place. Used on all
// platforms via ContentView's bottom overlay.
struct CameraDock: View {
    @ObservedObject var engine: PyMOLEngine
    // Dismisses the whole dock (the ✕ close button).
    let onClose: () -> Void
    // Which control's surface is open above the strip. nil = strip only.
    // "ortho" toggles instantly and never becomes `open`.
    @State private var open: String? = nil

    private var orthoOn: Bool { (engine.sceneState.values["ortho"] ?? 0) > 0.5 }
    private var dofOn: Bool { (engine.sceneState.values["metal_dof"] ?? 0) > 0.5 }

    var body: some View {
        VStack(spacing: 8) {
            if let key = open {
                Group {
                    if key == "metal_dof" {
                        DOFSubPanelContent(engine: engine)
                    } else if key == "field_of_view", let p = SceneCatalog.param(for: key) {
                        // Lens row: Ortho toggle on the left; the Lens slider greys
                        // itself out (via SceneParamRow) while Ortho is on.
                        HStack(spacing: 10) {
                            orthoToggle
                            SceneParamRow(param: p, engine: engine, compact: true)
                        }
                    } else if let p = SceneCatalog.param(for: key) {
                        SceneParamRow(param: p, engine: engine, compact: true)
                    }
                }
                .padding(.horizontal, 4)
                Divider().overlay(PanelTheme.textColor.opacity(0.15))
            }
            HStack(spacing: 10) {
                ForEach(SceneCatalog.cameraStripKeys, id: \.self) { stripIcon($0) }
                stripAction(icon: "xmark", label: "Close", id: "camDock.close") {
                    onClose()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 12)
        // Hug the icon strip tightly when collapsed (a compact centered pill); when
        // a control is open, expand to fit the slider submenu, capped so it never
        // spans the whole viewport. The bottom overlay centers it either way.
        .fixedSize(horizontal: open == nil, vertical: false)
        .frame(maxWidth: open == nil ? nil : 360)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
        .animation(.easeOut(duration: 0.18), value: open)
    }

    private func tap(_ key: String) {
        open = (open == key) ? nil : key
    }

    // Ortho lives in the Lens row (perspective vs orthographic). Toggling it greys
    // the Lens slider (SceneParamRow self-disables field_of_view while ortho is on).
    private var orthoToggle: some View {
        Button {
            engine.runCommand("set ortho, \(orthoOn ? 0 : 1)")
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "cube")
                Text("Ortho")
            }
            .font(.system(size: 12))
            .foregroundColor(orthoOn ? .black : PanelTheme.buttonText)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(orthoOn ? PanelTheme.selectionTextColor : PanelTheme.buttonBackground,
                        in: Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityIdentifier("camDock.ortho")
        .accessibilityLabel("Orthographic")
    }

    @ViewBuilder
    private func stripIcon(_ key: String) -> some View {
        let active = (open == key)
        Button { tap(key) } label: {
            VStack(spacing: 3) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: SceneCatalog.cameraIcon(for: key))
                        .font(.system(size: 17))
                        .foregroundColor(active ? .black : PanelTheme.buttonText)
                        .frame(width: 42, height: 42)
                        .background(active ? PanelTheme.selectionTextColor : PanelTheme.buttonBackground,
                                    in: Circle())
                    if key == "metal_dof" && dofOn {
                        Circle().fill(PanelTheme.selectionTextColor)
                            .frame(width: 9, height: 9)
                            .overlay(Circle().strokeBorder(.white, lineWidth: 1))
                            .offset(x: 2, y: -2)
                    }
                }
                Text(shortLabel(key)).font(.system(size: 10))
                    .foregroundColor(active ? PanelTheme.selectionTextColor : PanelTheme.textColor)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(axID(key))
        .accessibilityLabel(fullLabel(key))
    }

    private func stripAction(icon: String, label: String, id: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 17))
                    .foregroundColor(PanelTheme.buttonText)
                    .frame(width: 42, height: 42)
                    .background(PanelTheme.buttonBackground, in: Circle())
                Text(label).font(.system(size: 10)).foregroundColor(PanelTheme.textColor)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityLabel(label)
    }

    private func shortLabel(_ key: String) -> String {
        switch key {
        case "field_of_view": return "Lens"
        case "zoom":          return "Zoom"
        case "ortho":         return "Ortho"
        case "metal_dof":     return "Depth"
        default:              return key
        }
    }
    private func fullLabel(_ key: String) -> String {
        switch key {
        case "field_of_view": return "Lens"
        case "zoom":          return "Zoom"
        case "ortho":         return "Orthographic"
        case "metal_dof":     return "Depth of field"
        default:              return key
        }
    }
    private func axID(_ key: String) -> String {
        switch key {
        case "field_of_view": return "camDock.lens"
        case "zoom":          return "camDock.zoom"
        case "ortho":         return "camDock.ortho"
        case "metal_dof":     return "camDock.depth"
        default:              return "camDock.\(key)"
        }
    }
}

// MARK: - Scenes strip (saved camera/representation snapshots)

// The Scenes content tab — a full scene manager (PyMOL's Scene menu) in the
// global/teal language. Scenes recall the whole visualization, so everything
// here uses TimelineTheme.accent (teal), distinct from the per-object coral
// A/S/H/L/C. Append wires to the movie; an opt-in toggle shows glanceable scene
// buttons over the 3D viewport.
struct ScenesPane: View {
    @EnvironmentObject var engine: PyMOLEngine
    /// Drives the in-viewport scene-button overlay (owned by ContentView).
    @Binding var showViewportButtons: Bool
    /// Jump to the Movie tab (set by ContentView).
    var onOpenMovie: (() -> Void)? = nil

    private let danger = Color(red: 0.75, green: 0.29, blue: 0.23)

    // Local order mirror so chips can be reordered by hold+drag; persisted to
    // PyMOL via `scene_order`. Synced from engine.sceneNames on add/remove.
    @State private var sceneOrder: [String] = []
    @State private var draggingScene: String?
    // Scene-chip long-press "Rename…" flow (nil = alert hidden).
    @State private var sceneRenameTarget: String? = nil
    @State private var sceneRenameText: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                // Scene chips with an inline "+" chip that stores the current
                // view as a new scene (in line with the existing scenes). Chips
                // wrap onto multiple rows rather than overflowing (issue #114).
                FlowLayout(spacing: 8) {
                    ForEach(sceneOrder, id: \.self) { name in
                        sceneChip(name)
                            .opacity(draggingScene == name ? 0.35 : 1)
                            .onDrag {
                                draggingScene = name
                                return NSItemProvider(object: name as NSString)
                            }
                            .onDrop(of: ["public.text"],
                                    delegate: SceneDropDelegate(item: name, order: $sceneOrder,
                                                                dragging: $draggingScene,
                                                                onReorder: applySceneOrder))
                    }
                    addChip
                }
                .padding(.vertical, 4)
                .onAppear { sceneOrder = engine.sceneNames }
                .onChange(of: engine.sceneNames) { newNames in
                    // Resync only when the SET changes (scene added/removed); a
                    // pure reorder (same set) keeps the user's dragged order.
                    if Set(newNames) != Set(sceneOrder) { sceneOrder = newNames }
                }

                if engine.sceneNames.isEmpty {
                    Text("Tap + to store the current view as your first scene.")
                        .font(.system(size: 12))
                        .foregroundColor(PanelTheme.disabledColor)
                } else {
                    // Per-scene actions, all on one row for vertical efficiency.
                    HStack(spacing: 8) {
                        sceneActionButton("Update", "arrow.clockwise") {
                            engine.runCommand("scene auto, update")
                        }
                        sceneActionButton("Prev", "chevron.left") {
                            engine.runCommand("scene auto, previous")
                        }
                        sceneActionButton("Next", "chevron.right") {
                            engine.runCommand("scene auto, next")
                        }
                        sceneActionButton("Delete", "trash", danger: true) {
                            engine.runCommand("scene auto, delete")
                        }
                    }
                }

                Toggle(isOn: $showViewportButtons) {
                    Label("Show scene buttons in viewport", systemImage: "rectangle.grid.1x2")
                        .font(.system(size: 14))
                }
                .tint(TimelineTheme.accent)
                .padding(.top, 2)

                Divider().padding(.vertical, 2)
                actionRow("Build movie from scenes", "film") { onOpenMovie?() }
                actionRow("Clear all scenes", "xmark", destructive: true) {
                    engine.runCommand("scene *, clear")
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .reportPaneHeight(5)    // natural height (before tab-bar clearance)
            .padding(.bottom, 56)   // clear the floating tab-bar pill
        }
        .alert("Rename scene", isPresented: Binding(
            get: { sceneRenameTarget != nil },
            set: { if !$0 { sceneRenameTarget = nil } })) {
            TextField("Scene name", text: $sceneRenameText)
            Button("Rename") {
                if let t = sceneRenameTarget { engine.renameScene(t, to: sceneRenameText) }
                sceneRenameTarget = nil
            }
            Button("Cancel", role: .cancel) { sceneRenameTarget = nil }
        }
    }

    private func sceneChip(_ name: String) -> some View {
        let sel = name == engine.currentScene
        return Button {
            engine.runCommand("scene \(name), recall, animate=1")
        } label: {
            Text(name)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .padding(.horizontal, 14).frame(height: 38)
                .background(sel ? TimelineTheme.accent : Color.white)
                .foregroundColor(sel ? .white : TimelineTheme.accent)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(TimelineTheme.accent.opacity(sel ? 0 : 0.5), lineWidth: 1.5)
                )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Text(name)
            Button { engine.updateScene(name) } label: { Label("Reset to current view", systemImage: "arrow.clockwise") }
            Button { sceneRenameText = name; sceneRenameTarget = name } label: { Label("Rename…", systemImage: "pencil") }
            Button(role: .destructive) { engine.deleteScene(name) } label: { Label("Delete", systemImage: "trash") }
        }
    }

    // Trailing "+" chip in the scene row — stores the current view as a new scene.
    private var addChip: some View {
        Button {
            engine.runCommand("scene new, store")
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .bold))
                .frame(width: 44, height: 38)
                .foregroundColor(TimelineTheme.accent)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(TimelineTheme.accent.opacity(0.5),
                                      style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                )
                // Hit the whole dashed tile, not just the glyph: without this the
                // transparent interior between the "+" and the border isn't
                // tappable (the Image only hit-tests its rendered glyph). (#130)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New scene from current view")
    }

    // Persist the dragged chip order to PyMOL.
    private func applySceneOrder() {
        guard !sceneOrder.isEmpty else { return }
        engine.runCommand("scene_order " + sceneOrder.joined(separator: " "))
    }

    // Compact icon+label button; several sit on one row (Update/Prev/Next/Delete).
    private func sceneActionButton(_ title: String, _ icon: String,
                                   danger: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 15, weight: .medium))
                Text(title).font(.system(size: 10, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .foregroundColor(danger ? self.danger : TimelineTheme.accent)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.gray.opacity(0.13)))
        }
        .buttonStyle(.plain)
    }

    private func actionRow(_ title: String, _ icon: String,
                           destructive: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).frame(width: 22)
                    .foregroundColor(destructive ? danger : TimelineTheme.accent)
                Text(title).font(.system(size: 15))
                    .foregroundColor(destructive ? danger : PanelTheme.textColor)
                Spacer()
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) { Divider() }
    }
}

// Reorders scene chips live as one is dragged over another (hold + move).
private struct SceneDropDelegate: DropDelegate {
    let item: String
    @Binding var order: [String]
    @Binding var dragging: String?
    let onReorder: () -> Void

    func dropEntered(info: DropInfo) {
        guard let dragging = dragging, dragging != item,
              let from = order.firstIndex(of: dragging),
              let to = order.firstIndex(of: item) else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            order.move(fromOffsets: IndexSet(integer: from),
                       toOffset: to > from ? to + 1 : to)
        }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        onReorder()
        return true
    }
}

/// Left-aligned wrapping layout: places subviews left-to-right and wraps to a
/// new row when the next subview would overflow the proposed width. Used for
/// the scene-chip row so chips flow onto multiple rows instead of overflowing
/// or requiring horizontal scrolling (issue #114).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0 && rowWidth + spacing + size.width > maxWidth {
                // wrap to next row
                totalWidth = max(totalWidth, rowWidth)
                totalHeight += rowHeight + spacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalWidth = max(totalWidth, rowWidth)
        totalHeight += rowHeight
        return CGSize(width: totalWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let maxWidth = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.minX + maxWidth {
                // wrap to next row
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                          proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Selection builder (named selections + spatial algebra)

struct SelectionBuilderSheet: View {
    @EnvironmentObject var engine: PyMOLEngine
    @Environment(\.dismiss) private var dismiss

    enum Op: String, CaseIterable, Identifiable {
        case none = "base only", within = "within … of", around = "around",
             expand = "expand", extend = "extend (bonds)", and = "and", or = "or", not = "not"
        var id: String { rawValue }
        var needsDist: Bool { self == .within || self == .around || self == .expand }
        var needsCount: Bool { self == .extend }
        var needsOther: Bool { self == .within || self == .and || self == .or }
    }

    @State private var base = "sele"
    @State private var op: Op = .around
    @State private var dist = "5"
    @State private var other = "all"
    @State private var byres = true
    @State private var name = "sel01"
    @State private var previewWork: DispatchWorkItem?

    @State private var showRename = false
    @State private var renameTarget = ""
    @State private var renameText = ""

    private var bases: [String] {
        ["sele", "all", "polymer", "organic", "solvent"] + engine.objects.map { $0.name }
    }
    private var selections: [ObjectEntry] { engine.objects.filter { $0.isSelection } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Selections").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }.padding(16)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    builder
                    Divider()
                    manage
                }.padding(16)
            }
        }
        .onChange(of: expr) { _ in schedulePreview() }
        .onAppear { schedulePreview() }
        .onDisappear { engine.selectionPreviewCount = nil }
        .alert("Rename “\(renameTarget)”", isPresented: $showRename) {
            TextField("New name", text: $renameText)
            Button("Rename") { engine.renameObject(renameTarget, to: renameText) }
            Button("Cancel", role: .cancel) {}
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #else
        .frame(width: 440, height: 540)
        #endif
    }

    // MARK: builder

    private var expr: String {
        let b = "(\(base))"
        var e: String
        switch op {
        case .none:   e = b
        case .within: e = "\(b) within \(distNum) of (\(other))"
        case .around: e = "\(b) around \(distNum)"
        case .expand: e = "\(b) expand \(distNum)"
        case .extend: e = "\(b) extend \(Int(distNum.rounded()))"
        case .and:    e = "\(b) and (\(other))"
        case .or:     e = "\(b) or (\(other))"
        case .not:    e = "not \(b)"
        }
        if byres { e = "byres (\(e))" }
        return e
    }
    private var distNum: Double { Double(dist) ?? 5 }

    private var builder: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New selection").font(.system(size: 13, weight: .semibold))
            row("From") { picker($base, bases) }
            row("Operator") {
                Picker("", selection: $op) { ForEach(Op.allCases) { Text($0.rawValue).tag($0) } }
                    .labelsHidden()
            }
            if op.needsDist || op.needsCount {
                row(op.needsCount ? "Bonds" : "Distance (Å)") {
                    TextField("5", text: $dist)
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                        .frame(width: 70).textFieldStyle(.roundedBorder)
                }
            }
            if op.needsOther {
                row("Of") { picker($other, bases) }
            }
            Toggle("Whole residues (byres)", isOn: $byres).tint(TimelineTheme.accent)

            // Live preview of the composed expression + match count.
            VStack(alignment: .leading, spacing: 4) {
                Text(expr).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary).textSelection(.enabled)
                Text(previewText).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                TextField("name", text: $name).frame(width: 120).textFieldStyle(.roundedBorder)
                Spacer()
                Button {
                    engine.createSelection(name: name, expr: expr)
                    dismiss()
                } label: {
                    Label("Create", systemImage: "plus").font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.borderedProminent).tint(TimelineTheme.accent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var previewText: String {
        if let c = engine.selectionPreviewCount { return "\(c) atom\(c == 1 ? "" : "s")" }
        return "…"
    }

    private func schedulePreview() {
        previewWork?.cancel()
        let e = expr
        let work = DispatchWorkItem { engine.previewSelection(e) }
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    // MARK: manage existing selections

    private var manage: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Manage").font(.system(size: 13, weight: .semibold))
            if selections.isEmpty {
                Text("No named selections yet.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(selections) { sel in
                    HStack(spacing: 10) {
                        Toggle("", isOn: Binding(
                            get: { sel.isEnabled },
                            set: { on in engine.runCommand("\(on ? "enable" : "disable") \(sel.name)") }))
                            .labelsHidden()
                        Text(sel.name).font(.system(size: 13))
                        if let c = sel.atomCount { Text("(\(c))").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button { renameTarget = sel.name; renameText = sel.name; showRename = true } label: {
                            Image(systemName: "pencil")
                        }.buttonStyle(.borderless)
                        Button(role: .destructive) {
                            engine.runCommand("delete \(sel.name)")
                        } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    // MARK: helpers

    @ViewBuilder
    private func row<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack { Text(label).font(.system(size: 12)).frame(width: 90, alignment: .leading); content(); Spacer() }
    }

    private func picker(_ sel: Binding<String>, _ opts: [String]) -> some View {
        Picker("", selection: sel) { ForEach(opts, id: \.self) { Text($0).tag($0) } }
            .labelsHidden()
    }
}

// MARK: - Searchable Settings panel (all ~825 PyMOL settings)

struct SettingsSheet: View {
    @EnvironmentObject var engine: PyMOLEngine
    @EnvironmentObject private var themeManager: ThemeManager   // re-render on theme switch
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    private var filtered: [SettingItem] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return engine.settingsCatalog }
        return engine.settingsCatalog.filter { $0.name.contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }.padding(16)

            #if os(iOS)
            // "What's New" entry point. Close Settings first, then open the splash
            // (a slight delay avoids presenting one sheet on top of another).
            Button {
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    NotificationCenter.default.post(name: .raymolShowWhatsNew, object: nil)
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                    Text("What's New in RayMol")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 10).padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.gray.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            .accessibilityIdentifier("whatsNewSettingsRow")
            #endif

            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search \(engine.settingsCatalog.count) settings…", text: $search)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(8).background(Color.gray.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 16)

            if engine.settingsCatalog.isEmpty {
                Spacer(); ProgressView("Loading settings…"); Spacer()
            } else {
                List(filtered) { item in
                    SettingRow(item: item)
                }
                .listStyle(.plain)
            }
        }
        .onAppear {
            if engine.settingsCatalog.isEmpty { engine.loadSettingsCatalog() }
        }
        #if os(iOS)
        .presentationDetents([.large])
        #else
        .frame(width: 460, height: 560)
        #endif
    }

}

private struct SettingRow: View {
    let item: SettingItem
    @EnvironmentObject var engine: PyMOLEngine
    @State private var text = ""

    private var isBool: Bool { item.type == 1 }
    private var boolOn: Bool {
        if let d = Double(item.val) { return d != 0 }
        return ["on", "true", "yes"].contains(item.val.lowercased())
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(item.name)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1).minimumScaleFactor(0.7)
            Spacer(minLength: 8)
            if isBool {
                Toggle("", isOn: Binding(
                    get: { boolOn },
                    set: { engine.setSetting(item.name, $0 ? "1" : "0") }))
                    .labelsHidden().tint(TimelineTheme.accent)
            } else {
                TextField("", text: $text)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 110)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .onSubmit { engine.setSetting(item.name, text) }
                    .onAppear { text = item.val }
                    .onChange(of: item.val) { text = $0 }
            }
        }
        .font(.system(size: 12))
    }
}

// MARK: - ObjectEntry extension for MoleculeObject bridging

extension ObjectEntry {
    /// Create from the engine's MoleculeObject model
    init(from mol: MoleculeObject) {
        self.id = mol.id
        self.name = mol.name
        self.isEnabled = mol.isEnabled
        self.isSelection = false
        self.atomCount = nil
    }
}

// MARK: - Prediction job state

/// One pending prediction, as reported by `predicting.pending_info`.
///
/// Every field except `state` and `phase` is Optional-or-defaulted on the wire:
/// a partially-populated record must not fail the WHOLE PanelPayload decode and
/// take the object list down with it.
struct PredictionJobState: Codable, Equatable, Identifiable {
    /// The object name. Unique per pending placeholder, which is exactly the
    /// granularity of one card -- n_models shares one object and one card.
    let id: String
    let state: String
    let phase: String
    let fraction: Double?
    let moving: Bool
    let detail: String
    let modelsDone: Int
    let modelsTotal: Int
    let elapsed: Double
    let error: String?
    /// The weight bundle this job is still waiting on, or nil once submitted.
    /// The tray hides this card while that bundle's own download card is up.
    let bundle: String?
    /// Position WITHIN the current phase, e.g. diffusion step 84 of 200. Absent
    /// for a phase that reports no steps, and for any status written before
    /// boltz-mlx v0.2.1 gave RayMol a per-step callback to read.
    let step: Int?
    let totalSteps: Int?
    /// Seconds left in the CURRENT PHASE, measured by Python from that phase's
    /// own rate. Not a whole-job estimate: the band table the bar is composed
    /// through is layout, not time (see compose_progress), so there is nothing
    /// honest to extrapolate a whole-job countdown from.
    let remaining: Double?
    /// The BATCH this job belongs to: one `binder_design n_designs=N` invocation, named
    /// by the group its finished designs land in. Nil for a design submitted on its own,
    /// and nil for EVERY prediction — `predicting.pending_info` publishes no such key, so
    /// a prediction can never be collapsed and its row is untouched by this.
    ///
    /// The runtime runs a batch on a SERIAL queue, so exactly one of its designs is ever
    /// running; without this the tray listed the other nine as separate jobs reading
    /// "Queued", which is work that has not started shown as if it had.
    let batch: String?
    /// This design's 1-based position in its batch, in submission order — which is also
    /// the order the serial queue runs them in, so the lowest index that has not settled
    /// is how far through the batch the run is.
    let batchIndex: Int?
    /// How many designs the command asked for. Carried rather than counted from the
    /// records present: a design that succeeds leaves NO record, so counting rows would
    /// make the batch shrink as it progressed.
    let batchTotal: Int?
    /// Seconds left for the WHOLE run this record belongs to: the entire batch when the
    /// design is part of one, and the design itself when it is not. Unlike `remaining`,
    /// which is scoped to the current phase of the current design.
    ///
    /// Computed by `designing._run_remaining`, and computed there rather than here for
    /// two reasons that are not style: a design that has already succeeded leaves NO
    /// record on the wire, so Swift cannot see how long it took — and it is that
    /// measured wall time that prices the designs still queued. And the estimate is
    /// smoothed, which needs state the tray does not have: the tray is recomposed from
    /// scratch on every poll.
    ///
    /// Nil for EVERY prediction — `predicting.pending_info` publishes no such key, so
    /// the prediction row is untouched by this — and nil for a design that has not been
    /// running long enough to say anything.
    let runRemaining: Double?

    /// Swift's host writes "failed"; _DeferredJob writes "error". Neither wire is
    /// migrated, so the single consumer accepts both. "cancelled" is included
    /// because it is TERMINAL and needs the same card affordances (Dismiss, no bar,
    /// sorted below live jobs) — see `isCancelled` for why it is still not a failure.
    var isError: Bool { state == "error" || state == "failed" || state == "cancelled" }

    /// Terminal, but the user's own doing. `settle("cancelled", …)` writes
    /// `error: nil`, so without this the card read "Prediction failed: X — Unknown
    /// error" for someone who had just pressed Cancel.
    var isCancelled: Bool { state == "cancelled" }

    enum CodingKeys: String, CodingKey {
        case state, phase, fraction, moving, detail, error, bundle
        case modelsDone = "models_done", modelsTotal = "models_total", elapsed
        case step, totalSteps = "total_steps", remaining
        case batch, batchIndex = "batch_index", batchTotal = "batch_total"
        case runRemaining = "run_remaining"
    }

    init(id: String, state: String, phase: String, fraction: Double?, moving: Bool,
         detail: String, modelsDone: Int, modelsTotal: Int, elapsed: Double,
         error: String?, bundle: String? = nil,
         step: Int? = nil, totalSteps: Int? = nil, remaining: Double? = nil,
         batch: String? = nil, batchIndex: Int? = nil, batchTotal: Int? = nil,
         runRemaining: Double? = nil) {
        self.id = id; self.state = state; self.phase = phase
        self.fraction = fraction; self.moving = moving; self.detail = detail
        self.modelsDone = modelsDone; self.modelsTotal = modelsTotal
        self.elapsed = elapsed; self.error = error; self.bundle = bundle
        self.step = step; self.totalSteps = totalSteps; self.remaining = remaining
        self.batch = batch; self.batchIndex = batchIndex; self.batchTotal = batchTotal
        self.runRemaining = runRemaining
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = ""                       // filled in from the dictionary key
        state = try c.decode(String.self, forKey: .state)
        phase = try c.decode(String.self, forKey: .phase)
        fraction = try c.decodeIfPresent(Double.self, forKey: .fraction)
        moving = try c.decodeIfPresent(Bool.self, forKey: .moving) ?? false
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? "pending"
        modelsDone = try c.decodeIfPresent(Int.self, forKey: .modelsDone) ?? 0
        modelsTotal = try c.decodeIfPresent(Int.self, forKey: .modelsTotal) ?? 1
        elapsed = try c.decodeIfPresent(Double.self, forKey: .elapsed) ?? 0
        error = try c.decodeIfPresent(String.self, forKey: .error)
        bundle = try c.decodeIfPresent(String.self, forKey: .bundle)
        step = try c.decodeIfPresent(Int.self, forKey: .step)
        totalSteps = try c.decodeIfPresent(Int.self, forKey: .totalSteps)
        remaining = try c.decodeIfPresent(Double.self, forKey: .remaining)
        batch = try c.decodeIfPresent(String.self, forKey: .batch)
        batchIndex = try c.decodeIfPresent(Int.self, forKey: .batchIndex)
        batchTotal = try c.decodeIfPresent(Int.self, forKey: .batchTotal)
        runRemaining = try c.decodeIfPresent(Double.self, forKey: .runRemaining)
    }

    /// `id` comes from the payload's dictionary key, not the record body.
    func withID(_ name: String) -> PredictionJobState {
        PredictionJobState(id: name, state: state, phase: phase, fraction: fraction,
                           moving: moving, detail: detail, modelsDone: modelsDone,
                           modelsTotal: modelsTotal, elapsed: elapsed, error: error,
                           bundle: bundle, step: step, totalSteps: totalSteps,
                           remaining: remaining, batch: batch, batchIndex: batchIndex,
                           batchTotal: batchTotal, runRemaining: runRemaining)
    }
}

// MARK: - Object panel JSON payload

/// Decoded shape of the tempfile written by `appkit_inspector.poll_panel`.
///
/// Extracted from the function body so `@testable import RayMol` can decode it
/// in unit tests, establishing the same "real payload → real decoder" discipline
/// that `WeightsFetchStateTests` uses for the WEIGHTS: marker.
struct PanelPayload: Decodable {
    let objects: [String]
    let selections: [String]
    let enabled: [String]
    let sel_counts: [String: Int]
    let nstate: [String: Int]?
    let has_transp: [String: Bool]?
    // Group tree (#255). OPTIONAL on purpose: a non-optional field makes
    // the whole decode fail against an older bundled appkit_inspector.py,
    // which would freeze the panel on its last list rather than degrade
    // to a flat one.
    let groups: [String]?
    let parent: [String: String]?
    // Structure prediction (#224). Optional for the same reason as `groups`: a
    // non-optional field would fail the whole decode against an older bundled
    // appkit_inspector.py and freeze the panel on its last list.
    let pending: [String: String]?
    /// #291. Optional so an older bundled Python still decodes and the tray simply
    /// shows no prediction cards.
    let pending_jobs: [String: PredictionJobState]?
    // Alignments (#296), same reasoning again. Values are scalars only — no a3m
    // bytes travel through this payload.
    let alignments: [String: AlignmentSummary]?
    // Searches still running (#298), oldest first. A LIST, unlike `alignments`:
    // the order is the order they were started, and a JSON object would lose it
    // the way the alignments decode has to sort to get it back.
    //
    // Optional for the same reason as every field above, and it matters more
    // here than anywhere: this decode is a single `guard let`, so one missing
    // key does not cost the ALIGNMENTS section, it freezes the ENTIRE object
    // panel on its last list.
    let msa_searches: [MSASearchSummary]?
    /// Design-mode 'sele' fingerprint, '' while Design mode is off. Optional for
    /// the same reason as every field above: a non-optional would fail the whole
    /// decode against an older bundled appkit_inspector.py and freeze the panel on
    /// its last list.
    let design_sele: String?
    /// Running and recently-failed BACKBONE DESIGNS (#342), keyed by object name.
    ///
    /// The same record type as `pending_jobs` -- `designing.pending_info` publishes the
    /// same keys as `predicting.pending_info`, deliberately, so one decoder serves both --
    /// but a separate key, because the two are separate job tables with separate cancel
    /// commands. Merging them would send a design's object name to `predict_cancel`, which
    /// has never heard of it.
    ///
    /// Optional, like every field above, and for the same single-`guard let` reason.
    let design_jobs: [String: PredictionJobState]?

    struct AlignmentSummary: Decodable {
        let depth: Int
        let columns: Int
        let residues: Int
        let target: String
        let chain: String
    }

    struct MSASearchSummary: Decodable {
        let id: String
        let name: String
        let phase: String
        let server: String
        let elapsed: Int
    }
}

// MARK: - PyMOLEngine extensions for object polling

extension PyMOLEngine {
    /// Parse the object-list JSON (written by appkit_inspector.poll_panel to a
    /// temp file; the feedback line is just the "OBJPANEL:ready" trigger) and
    /// update the objects array. Called by the existing pollFeedback timer.
    /// File-based to avoid the ~1KB feedback-line cap splitting the payload —
    /// inline, the list truncated at ~16 objects (so the panel froze on the stale
    /// list after e.g. `split_states`) and the continuation leaked to the log (#231).
    func parseObjectPanelFeedback(_ line: String) {
        guard line.hasPrefix("OBJPANEL:") else { return }
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("pymol_objpanel_\(ProcessInfo.processInfo.processIdentifier).json")
        guard let data = FileManager.default.contents(atPath: path) else { return }

        guard let payload = try? JSONDecoder().decode(PanelPayload.self, from: data) else {
            return
        }

        #if RAYMOL_MPNN
        // 'sele' is the single source of truth for Design mode, so a selection made
        // OUTSIDE it — `select` at the prompt, a Seeker drag, the object panel —
        // must drive it too. Gated on the digest so a quiet tick does no work, and
        // on designMode so nothing runs when the feature is not in use.
        if let digest = payload.design_sele, !digest.isEmpty, designMode {
            MainActor.assumeIsolated {
                designController.syncFromSeleIfChanged(digest: digest)
            }
        }
        #endif

        let enabledSet = Set(payload.enabled)
        let groupSet = Set(payload.groups ?? [])
        let parentMap = payload.parent ?? [:]
        var entries: [ObjectEntry] = []

        for name in payload.objects {
            entries.append(ObjectEntry(
                id: "obj_\(name)",
                name: name,
                isEnabled: enabledSet.contains(name),
                isSelection: false,
                atomCount: nil,
                stateCount: max(payload.nstate?[name] ?? 1, 1),
                hasAtomTransp: payload.has_transp?[name] ?? false,
                isGroup: groupSet.contains(name),
                parent: parentMap[name],
                isPending: payload.pending?[name] != nil,
                pendingDetail: payload.pending?[name]
            ))
        }

        for name in payload.selections {
            entries.append(ObjectEntry(
                id: "sel_\(name)",
                name: name,
                isEnabled: enabledSet.contains(name),
                isSelection: true,
                atomCount: payload.sel_counts[name]
            ))
        }

        let jobs = (payload.pending_jobs ?? [:])
            .map { $0.value.withID($0.key) }
            .sorted { $0.id < $1.id }
        // Backbone designs (#342), same record type, separate array -- see the payload's
        // `design_jobs` comment for why they are not merged.
        let designs = (payload.design_jobs ?? [:])
            .map { $0.value.withID($0.key) }
            .sorted { $0.id < $1.id }
        // Sorted by name so the order is stable: the payload is a JSON object, and
        // Foundation's dictionary decode does not preserve the store's load order.
        let alignments = (payload.alignments ?? [:]).sorted { $0.key < $1.key }.map {
            AlignmentEntry(id: "aln_\($0.key)", name: $0.key,
                           depth: $0.value.depth, columns: $0.value.columns,
                           residues: $0.value.residues,
                           target: $0.value.target, chain: $0.value.chain)
        }

        // Already oldest-first, so no sort: see the payload comment.
        let searches = (payload.msa_searches ?? []).map {
            MSASearchEntry(id: $0.id, name: $0.name, phase: $0.phase,
                           server: $0.server, elapsed: $0.elapsed)
        }

        DispatchQueue.main.async {
            // Guard: the ~500ms poll usually returns the same object list;
            // re-assigning an equal array still fires @Published and re-renders
            // the panel (resetting open menus). Only assign on real changes.
            if self.objects != entries { self.objects = entries }
            if self.predictionJobs != jobs { self.predictionJobs = jobs }
            if self.designJobs != designs { self.designJobs = designs }
            if self.alignments != alignments { self.alignments = alignments }
            // Same guard, and it carries the weight here: with no search running this
            // is empty every tick and must not repaint the panel twice a second.
            if self.msaSearches != searches { self.msaSearches = searches }
        }
    }
}

// MoleculeObject is now a typealias for ObjectEntry — no conversion needed.

// MARK: - Updated ObjectPanel using engine.objects directly

// MARK: - Preview

#if DEBUG
struct ObjectPanel_Previews: PreviewProvider {
    static var previews: some View {
        let engine = PyMOLEngine.shared
        let _ = {
            engine.objects = [
                ObjectEntry(id: "obj_1ake", name: "1ake", isEnabled: true, isSelection: false, atomCount: nil),
                ObjectEntry(id: "obj_2kpo", name: "2kpo", isEnabled: true, isSelection: false, atomCount: nil),
                ObjectEntry(id: "obj_3hyd", name: "3hyd", isEnabled: false, isSelection: false, atomCount: nil),
                ObjectEntry(id: "sel_sele", name: "sele", isEnabled: true, isSelection: true, atomCount: 42),
            ]
        }()

        ObjectPanel()
            .environmentObject(engine)
            .frame(width: 300, height: 400)
            .preferredColorScheme(.dark)
    }
}
#endif
