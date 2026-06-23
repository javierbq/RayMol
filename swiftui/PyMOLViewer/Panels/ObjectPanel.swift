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
private let kActBtnW: CGFloat = 22
private let kActBtnH: CGFloat = 18
private let kRowH: CGFloat = 24
private let kGutterW: CGFloat = 18
#endif

// MARK: - Representation inspector: polled state models
// (Inlined here rather than a separate file so they're in both app targets
// without editing the Xcode project's explicit file references.)

/// One active representation on an object, with current setting values + color.
struct RepState: Equatable {
    let rep: String                 // "cartoon", "surface", …
    var visible: Bool
    var values: [String: Double]    // setting name → current value
    var color: String               // "inherit" or "#rrggbb"
}

/// Global "Scene" parameters.
struct SceneState: Equatable {
    var values: [String: Double] = [:]   // setting name → value (toggles 0/1)
    var bg: [Double] = [0, 0, 0]         // background r,g,b in 0…1
}

/// Per-object state metadata for the inspector STATE row (multi-state objects).
struct ObjStateMeta: Equatable {
    var state: Int = 1        // effective current state (resolves the frame)
    var overlayAll: Bool = false   // all_states overlay for this object
}

// MARK: - Representation inspector: control metadata

enum RepControlKind { case slider, segmented, toggle }

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
            ]),
        "surface": RepSpec(rep: "surface", display: "Surface",
            colorSetting: "surface_color", defaultColor: -1, properties: [
                RepProperty(setting: "transparency",   label: "Transparency", kind: .slider),
                RepProperty(setting: "surface_quality", label: "Quality", kind: .segmented,
                            options: [("0", 0), ("1", 1), ("2", 2)]),
                RepProperty(setting: "solvent_radius", label: "Solvent radius", kind: .slider, min: 0.5, max: 3, step: 0.1, decimals: 1, commitOnly: true),
                RepProperty(setting: "metal_interior_cap", label: "Solid interior", kind: .toggle),
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
}

enum SceneCatalog {
    static let groups = ["Lighting & Quality", "Camera"]
    static let params: [SceneParam] = [
        SceneParam(setting: "metal_raytrace", label: "Ray tracing", kind: .toggle, group: "Lighting & Quality"),
        SceneParam(setting: "metal_rt_shadows", label: "RT hard shadows", kind: .toggle, group: "Lighting & Quality"),
        SceneParam(setting: "metal_shadows", label: "Shadows", kind: .toggle, group: "Lighting & Quality"),
        SceneParam(setting: "metal_ssao",    label: "Ambient occlusion", kind: .toggle, group: "Lighting & Quality"),
        SceneParam(setting: "metal_outline", label: "Outline", kind: .toggle, group: "Lighting & Quality"),
        SceneParam(setting: "metal_msaa",    label: "MSAA 4×", kind: .toggle, group: "Lighting & Quality"),
        SceneParam(setting: "metal_tonemap", label: "Filmic tone-map", kind: .toggle, group: "Lighting & Quality"),
        SceneParam(setting: "metal_exposure", label: "Exposure", kind: .slider, min: 0.2, max: 2.0, step: 0.05, decimals: 2, group: "Lighting & Quality"),
        SceneParam(setting: "depth_cue",     label: "Depth cue / fog", kind: .toggle, group: "Lighting & Quality"),
        // grid_mode is an int (0=off, 1=by object, 2=by state); the toggle maps
        // off→0 / on→1 and reads on for any non-zero mode. Lays each object out
        // in its own viewport cell (Metal grid support added in 1.2.0).
        SceneParam(setting: "grid_mode",     label: "Grid", kind: .toggle, group: "Lighting & Quality"),
        SceneParam(setting: "all_states",    label: "Overlay all states", kind: .toggle, group: "Lighting & Quality"),
        // Lighting (made real-time on Metal in Phase 3; tunable here in Phase 2).
        SceneParam(setting: "ambient",   label: "Ambient",  kind: .slider, min: 0, max: 1, step: 0.01, decimals: 2, group: "Lighting & Quality"),
        SceneParam(setting: "direct",    label: "Direct",   kind: .slider, min: 0, max: 1, step: 0.01, decimals: 2, group: "Lighting & Quality"),
        SceneParam(setting: "reflect",   label: "Reflect",  kind: .slider, min: 0, max: 1, step: 0.01, decimals: 2, group: "Lighting & Quality"),
        SceneParam(setting: "specular",  label: "Specular", kind: .slider, min: 0, max: 1, step: 0.01, decimals: 2, group: "Lighting & Quality"),
        SceneParam(setting: "shininess", label: "Shininess", kind: .slider, min: 0, max: 100, step: 1, decimals: 0, group: "Lighting & Quality"),
        SceneParam(setting: "field_of_view", label: "Field of view", kind: .slider, min: 10, max: 60, step: 1, decimals: 0, group: "Camera"),
        SceneParam(setting: "surface_quality", label: "Surface quality", kind: .segmented,
                   options: [("0", 0), ("1", 1), ("2", 2)], group: "Camera"),
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

    var displayName: String {
        if isSelection, let count = atomCount {
            return "\(name) (\(count))"
        }
        return name
    }
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
}

private let actionMenuItems: [ActionMenuItem] = [
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
    .action(label: "Rename",     key: "rename"),
    .action(label: "Duplicate",  key: "copy"),
    .action(label: "Delete",     key: "delete"),
]

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
    // Global ("all" row) actions
    case "deselect":           cmd = "deselect"
    case "hide_everything":    cmd = "hide everything, \(n)"
    case "reset_view":         cmd = "reset"
    default:                   return
    }
    engine.runCommand(cmd)
}

/// Action ("A") menu for the global "all" row — a focused, scene-wide subset.
/// Reuses the per-object action keys (all valid with name "all"); deliberately
/// omits per-object items (Rename / Duplicate / Delete) and adds global ones
/// (Deselect, Hide everything, Reset camera).
private let allActionMenuItems: [ActionMenuItem] = [
    .action(label: "Zoom",          key: "zoom"),
    .action(label: "Orient",        key: "orient"),
    .action(label: "Center",        key: "center"),
    .action(label: "Reset camera",  key: "reset_view"),
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
    static var headerColor: Color { t.panelBackground.blended(with: t.panelText, 0.6).color }
    static var disabledColor: Color { t.panelBackground.blended(with: t.panelText, 0.4).color }
}

// MARK: - ObjectPanel View

struct ObjectPanel: View {
    @EnvironmentObject var engine: PyMOLEngine
    @EnvironmentObject private var themeManager: ThemeManager   // re-render on theme switch
    @State private var showSelectionBuilder = false
    @State private var renameText = ""

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
    }

    private var panelBody: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                Text("Objects")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(PanelTheme.headerColor)
                Spacer()
                selectionModeMenu
                Button(action: { showSelectionBuilder = true }) {
                    Image(systemName: "plus.viewfinder")
                        .font(.system(size: 11))
                        .foregroundColor(PanelTheme.headerColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New selection")
                .help("New selection / selection builder")
                Button(action: { refreshObjects() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                        .foregroundColor(PanelTheme.headerColor)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            Divider()

            // Object/selection list
            ScrollView(.vertical) {
                LazyVStack(spacing: 1) {
                    let objects = engine.objects.filter { !$0.isSelection }
                    let selections = engine.objects.filter { $0.isSelection }

                    // Global scene parameters (collapsible, pinned on top)
                    SceneCard()

                    // Objects section — each is an expandable inspector card
                    if !objects.isEmpty {
                        // Global "all" controls (A/S/H/L/C on the whole scene),
                        // pinned above the per-object cards.
                        AllControlsRow()
                        ForEach(Array(objects.enumerated()), id: \.element.id) { index, obj in
                            ObjectCard(entry: obj, isAlt: index % 2 == 1)
                        }
                    }

                    // Selections section
                    if !selections.isEmpty {
                        HStack {
                            Text("Selections")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(PanelTheme.headerColor)
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .padding(.top, 6)
                        .padding(.bottom, 2)

                        ForEach(Array(selections.enumerated()), id: \.element.id) { index, obj in
                            ObjectRowView(entry: obj, isAlt: index % 2 == 1)
                        }
                    }

                    // Empty state
                    if engine.objects.isEmpty {
                        Text("No objects loaded")
                            .font(.system(size: 11))
                            .foregroundColor(PanelTheme.disabledColor)
                            .padding(.top, 20)
                    }
                }
                .padding(.vertical, 2)
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

    // Pick-granularity menu (mouse_selection_mode): what a viewport tap selects.
    private var selectionModeMenu: some View {
        let modes: [(Int, String)] = [(0, "Atoms"), (1, "Residues"), (2, "Chains"),
                                      (3, "Segments"), (4, "Objects"), (5, "Molecules"), (6, "C-α")]
        let cur = Int(engine.sceneState.values["mouse_selection_mode"] ?? 1)
        return Menu {
            ForEach(modes, id: \.0) { m in
                Button {
                    engine.runCommand("set mouse_selection_mode, \(m.0)")
                } label: {
                    if m.0 == cur { Label(m.1, systemImage: "checkmark") } else { Text(m.1) }
                }
            }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "hand.tap").font(.system(size: 9))
                Text(modes.first(where: { $0.0 == cur })?.1 ?? "Residues")
                    .font(.system(size: 10))
            }
            .foregroundColor(PanelTheme.headerColor)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Selection mode — what a tap selects")
    }

    private func refreshObjects() {
        engine.runCommand(
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

// MARK: - Object Row

private struct ObjectRowView: View {
    let entry: ObjectEntry
    let isAlt: Bool
    @EnvironmentObject var engine: PyMOLEngine

    var body: some View {
        HStack(spacing: 2) {
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
            ActionMenuButton(name: entry.name)
            ShowButton(name: entry.name)
            HideButton(name: entry.name)
            LabelMenuButton(name: entry.name)
            ColorMenuButton(name: entry.name)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .frame(height: kRowH)
        .background(isAlt ? PanelTheme.rowAltBackground : PanelTheme.rowBackground)
        // Long-press (iOS) / right-click (macOS) opens the action menu.
        .contextMenu { actionMenuContent(actionMenuItems, name: entry.name, engine: engine) }
    }

    private func toggleEnabled() {
        if entry.isEnabled {
            engine.runCommand("disable \(entry.name)")
        } else {
            engine.runCommand("enable \(entry.name)")
        }
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

    var body: some View {
        HStack(spacing: 2) {
            // No enable checkbox — "all" is a selection, not a toggleable object.
            Spacer().frame(width: kGutterW)
            Text("all")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(PanelTheme.textColor)
                .lineLimit(1)
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
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            ShowButton(name: "all")
            HideButton(name: "all")
            LabelMenuButton(name: "all")
            ColorMenuButton(name: "all")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .frame(height: kRowH)
        .background(PanelTheme.rowBackground)
        .contextMenu { actionMenuContent(allActionMenuItems, name: "all", engine: engine) }
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
        }
    }
}

private struct ActionMenuButton: View {
    let name: String
    @EnvironmentObject var engine: PyMOLEngine

    var body: some View {
        Menu {
            actionMenuContent(actionMenuItems, name: name, engine: engine)
        } label: {
            Text("A")
                .frame(width: kActBtnW, height: kActBtnH)
                .background(PanelTheme.buttonBackground)
                .cornerRadius(2)
                // Make the entire framed/background area hit-testable, not just
                // the "A" glyph — so a tap anywhere on the button opens the menu.
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
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
            Divider()
            ForEach(Array(showHideOptions.enumerated()), id: \.offset) { _, opt in
                if opt.label == "---" {
                    Divider()
                } else if let rep = opt.rep {
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
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
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
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
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
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
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
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .popover(isPresented: $showCustom, arrowEdge: .bottom) {
            VStack(spacing: 8) {
                Text("Custom color").font(.system(size: 11, weight: .semibold))
                ColorPicker("", selection: Binding(
                    get: { customColor },
                    set: { customColor = $0; applyCustomColor($0) }))
                    .labelsHidden()
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

    @State private var local: Double = 0
    @State private var text: String = ""
    @State private var editing = false
    @State private var debounce: DispatchWorkItem?

    var body: some View {
        HStack(spacing: 6) {
            Slider(value: $local, in: prop.min...prop.max, step: prop.step,
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
    private func scheduleLive(_ v: Double) {
        debounce?.cancel()
        let w = DispatchWorkItem { onLive(v) }
        debounce = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: w)
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
            ColorPicker("", selection: Binding(
                get: { colorFromHex(colorState) ?? .white },
                set: { applyCustom($0) }))
                .labelsHidden()
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
            ColorPicker("", selection: Binding(get: { .white }, set: { applyCustom($0) }))
                .labelsHidden()
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
    @EnvironmentObject var engine: PyMOLEngine

    var body: some View {
        Button(action: { toggleEnabled() }) {
            Image(systemName: entry.isEnabled ? "checkmark.square.fill" : "square")
                .font(.system(size: 12))
                .foregroundColor(entry.isEnabled ? PanelTheme.textColor : PanelTheme.disabledColor)
        }
        .buttonStyle(.plain)
        .frame(width: kGutterW)

        Text(entry.displayName)
            .font(.system(size: 11))
            .foregroundColor(entry.isSelection ? PanelTheme.selectionTextColor : PanelTheme.textColor)
            .lineLimit(1)
            .truncationMode(.tail)
            .contentShape(Rectangle())
            .onTapGesture { toggleEnabled() }   // tap name = toggle enable

        Spacer(minLength: 4)

        ActionMenuButton(name: entry.name)
        ShowButton(name: entry.name)
        HideButton(name: entry.name)
        LabelMenuButton(name: entry.name)
        ColorMenuButton(name: entry.name)
    }

    private func toggleEnabled() {
        engine.runCommand(entry.isEnabled ? "disable \(entry.name)" : "enable \(entry.name)")
    }
}

// MARK: - Expandable object card

private struct ObjectCard: View {
    let entry: ObjectEntry
    let isAlt: Bool
    @EnvironmentObject var engine: PyMOLEngine
    @State private var selectedRep: String?

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
                Button(action: toggleExpand) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9))
                        .foregroundColor(PanelTheme.headerColor)
                        .frame(width: 13)
                }
                .buttonStyle(.plain)
                ObjectRowContent(entry: entry)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .frame(height: kRowH)
            .background(isAlt ? PanelTheme.rowAltBackground : PanelTheme.rowBackground)
            // Long-press (iOS) / right-click (macOS) opens the action menu.
            .contextMenu { actionMenuContent(actionMenuItems, name: entry.name, engine: engine) }

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
        let cur = min(max(meta?.state ?? 1, 1), total)
        VStack(spacing: 3) {
            HStack(spacing: 6) {
                Text("State")
                    .font(.system(size: 10)).foregroundColor(PanelTheme.textColor)
                    .frame(width: 78, alignment: .leading)
                Button { setState(max(cur - 1, 1)) } label: {
                    Image(systemName: "minus.circle").font(.system(size: 14))
                }
                .buttonStyle(.plain).foregroundColor(TimelineTheme.accent)
                Slider(value: Binding(get: { Double(cur) },
                                      set: { setState(Int($0.rounded())) }),
                       in: 1...Double(max(total, 2)), step: 1)
                    .tint(TimelineTheme.accent)
                Button { setState(min(cur + 1, total)) } label: {
                    Image(systemName: "plus.circle").font(.system(size: 14))
                }
                .buttonStyle(.plain).foregroundColor(TimelineTheme.accent)
                Text("\(cur)/\(total)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(PanelTheme.textColor)
                    .frame(width: 42, alignment: .trailing)
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
            }
        }
        .padding(.top, 2)
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

private struct SceneCard: View {
    @EnvironmentObject var engine: PyMOLEngine
    @State private var showSettings = false
    // Collapsed by default and part of the accordion: at most one detail view
    // (SCENE or an object card) is open at a time. This is the single home for
    // display settings now (the redundant toolbar "View" menu was removed).
    private var expanded: Bool { engine.expandedDetail == PyMOLEngine.sceneDetailKey }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: {
                engine.expandedDetail = expanded ? nil : PyMOLEngine.sceneDetailKey
            }) {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9)).foregroundColor(PanelTheme.headerColor)
                    Text("SCENE")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(PanelTheme.headerColor)
                    Spacer()
                    Text("global").font(.system(size: 9)).foregroundColor(PanelTheme.disabledColor)
                }
                .padding(.horizontal, 6).frame(height: 22)
                .background(PanelTheme.background)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(spacing: 3) {
                    SceneStrip()
                    Divider().background(PanelTheme.disabledColor.opacity(0.3))
                    sceneRow("Background") {
                        ColorPicker("", selection: Binding(
                            get: { Color(.sRGB,
                                         red: engine.sceneState.bg.count > 0 ? engine.sceneState.bg[0] : 0,
                                         green: engine.sceneState.bg.count > 1 ? engine.sceneState.bg[1] : 0,
                                         blue: engine.sceneState.bg.count > 2 ? engine.sceneState.bg[2] : 0) },
                            set: { setBackground($0) }))
                            .labelsHidden().frame(width: 28)
                    }
                    ForEach(SceneCatalog.params) { p in
                        // Hardware ray tracing is unavailable on some GPUs
                        // (Simulator, A-series iPads); gray the row out there
                        // so the toggle doesn't read as a working control.
                        let rtUnavailable = p.setting == "metal_raytrace" && !engine.rayTracingSupported
                        sceneRow(rtUnavailable ? "\(p.label) (unavailable)" : p.label) {
                            sceneControl(p)
                        }
                        .disabled(rtUnavailable)
                        .opacity(rtUnavailable ? 0.45 : 1)
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
                    Divider().background(PanelTheme.disabledColor.opacity(0.3))
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(PanelTheme.rowAltBackground.opacity(0.6))
            }
        }
        .sheet(isPresented: $showSettings) { SettingsSheet() }
    }

    @ViewBuilder
    private func sceneControl(_ p: SceneParam) -> some View {
        let v = engine.sceneState.values[p.setting] ?? 0
        switch p.kind {
        case .toggle:
            ToggleSetting(value: v) { on in engine.runCommand("set \(p.setting), \(on ? 1 : 0)") }
        case .segmented:
            SegmentedSetting(prop: RepProperty(setting: p.setting, label: p.label, kind: .segmented, options: p.options),
                             value: v) { engine.runCommand("set \(p.setting), \(Int($0))") }
        case .slider:
            LabeledSlider(prop: RepProperty(setting: p.setting, label: p.label, kind: .slider,
                                            min: p.min, max: p.max, step: p.step, decimals: p.decimals),
                          value: v,
                          onLive: { engine.runCommand("set \(p.setting), \(fmtScene($0, p))") },
                          onCommit: { engine.runCommand("set \(p.setting), \(fmtScene($0, p))") })
        }
    }

    private func fmtScene(_ v: Double, _ p: SceneParam) -> String {
        p.decimals == 0 ? String(Int(v.rounded())) : String(format: "%.4f", v)
    }

    private func setBackground(_ color: Color) {
        engine.runCommand("set_color _bgcol, \(rgb01List(color))\nbg_color _bgcol")
    }

    @ViewBuilder
    private func sceneRow<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(PanelTheme.textColor)
                .frame(width: 110, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Scenes strip (saved camera/representation snapshots)

private struct SceneStrip: View {
    @EnvironmentObject var engine: PyMOLEngine
    @State private var showBuilder = false

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Text("Scenes")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(PanelTheme.textColor)
                Spacer(minLength: 0)
                actionIcon("plus") { engine.runCommand("scene new, store") }
                    .accessibilityLabel("Store new scene")
                actionIcon("arrow.clockwise") { engine.runCommand("scene auto, update") }
                    .accessibilityLabel("Update current scene")
                actionIcon("xmark") { engine.runCommand("scene auto, delete") }
                    .accessibilityLabel("Delete current scene")
                actionIcon("film") { showBuilder = true }
                    .accessibilityLabel("Make scene-loop movie")
            }
            if engine.sceneNames.isEmpty {
                Text("No scenes — tap + to store the current view.")
                    .font(.system(size: 9))
                    .foregroundColor(PanelTheme.disabledColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(engine.sceneNames, id: \.self) { name in
                            let sel = name == engine.currentScene
                            Button {
                                engine.runCommand("scene \(name), recall, animate=1")
                            } label: {
                                Text(name)
                                    .font(.system(size: 9, weight: sel ? .bold : .regular))
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(sel ? TimelineTheme.accent : PanelTheme.buttonBackground)
                                    .foregroundColor(sel ? Color.black : PanelTheme.buttonText)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showBuilder) {
            MovieBuilderSheet(initialTab: .scenes)
        }
    }

    private func actionIcon(_ systemName: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(PanelTheme.buttonText)
                .frame(width: 24, height: 22)
                .background(PanelTheme.buttonBackground)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
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

// MARK: - PyMOLEngine extensions for object polling

extension PyMOLEngine {
    /// Parse the OBJPANEL JSON output from feedback and update the objects array.
    /// Called by the existing pollFeedback timer. Feedback lines starting with
    /// "OBJPANEL:" carry the JSON payload from our Python query.
    func parseObjectPanelFeedback(_ line: String) {
        guard line.hasPrefix("OBJPANEL:") else { return }
        let jsonStr = String(line.dropFirst("OBJPANEL:".count))
        guard let data = jsonStr.data(using: .utf8) else { return }

        struct PanelPayload: Decodable {
            let objects: [String]
            let selections: [String]
            let enabled: [String]
            let sel_counts: [String: Int]
            let nstate: [String: Int]?
        }

        guard let payload = try? JSONDecoder().decode(PanelPayload.self, from: data) else {
            return
        }

        let enabledSet = Set(payload.enabled)
        var entries: [ObjectEntry] = []

        for name in payload.objects {
            entries.append(ObjectEntry(
                id: "obj_\(name)",
                name: name,
                isEnabled: enabledSet.contains(name),
                isSelection: false,
                atomCount: nil,
                stateCount: max(payload.nstate?[name] ?? 1, 1)
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

        DispatchQueue.main.async {
            // Guard: the ~500ms poll usually returns the same object list;
            // re-assigning an equal array still fires @Published and re-renders
            // the panel (resetting open menus). Only assign on real changes.
            if self.objects != entries { self.objects = entries }
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
