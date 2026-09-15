// SequencePanel.swift — the sequence viewer, and since #419 the Data drawer's
// Sequences tab (spec §4.4, §8 decision 2, wireframe frame 3).
//
// SwiftUI reimplementation of PyMOL's seq_view (layer3/Seeker.cpp + layer1/Seq.cpp).
//
// Features mirrored from the original:
//  - One-letter codes per residue, colored by the residue's ACTUAL molecular
//    color (guide-atom color) so spectrum/by-element/custom coloring shows.
//  - Selection highlight synced both ways with the active 'sele' selection.
//  - Click to select a residue; drag to select a range; Shift extends,
//    Ctrl selects-and-centers; click on empty space deselects.
//  - Residue-number ruler above each sequence (every N residues).
//
// #419 moved this into the drawer and added ENTRY rows under the scene rows. The
// split is deliberate and is the compatibility contract: `SequencePanel` — the scene
// rows, their ruler, their colors, their click and drag selection — is UNCHANGED, so
// with no set open the tab is the strip, character for character (spec §8 decision 2,
// and the #380 enabled-only rule that `appkit_sequence._visible_objects` enforces).
// Everything new is below it: `SequenceRowModel` lays entry rows out, and
// `SequencesTabView` stacks the two.
//
// `SequenceRowModel` is pure — no SwiftUI, no engine — for the reason `SetTableModel`
// and `SetPlotModel` are: alignment by shared parent, the collapse threshold, the
// consensus band and the mapping of a residue array onto a row's cells are all
// decisions, and a decision with a test on it is one that cannot drift.

import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - Data Models

/// A single residue in the sequence display.
struct SequenceResidue: Identifiable, Equatable {
    let id: String          // unique key: "obj/chain/resi/index"
    let objectName: String
    let chain: String
    let oneLetter: String
    let resi: String        // residue index (e.g. "42")
    let resn: String        // three-letter code (e.g. "ALA")
    let color: Color        // real guide-atom color
    var isGap: Bool = false // alignment gap placeholder (not a real residue)
    var isBreak: Bool = false // chain-boundary separator bar (not a real residue)
    var isChainLabel: Bool = false // chain-ID indicator at a chain run's start
    var chainLabel: String = ""    // the chain ID shown when isChainLabel

    /// Real, selectable residue (excludes gap / break / chain-label placeholders).
    var isSelectable: Bool { !isGap && !isBreak && !isChainLabel }

    /// Identity used to match against the active selection set (obj/chain/resi).
    var selKey: String { "\(objectName)/\(chain)/\(resi)" }
}

/// A group of residues belonging to one molecular object.
struct SequenceObject: Identifiable, Equatable {
    let id: String          // object name
    let name: String
    let residues: [SequenceResidue]
}

// MARK: - Three-letter to one-letter mapping

private let aa3to1: [String: String] = [
    "ALA": "A", "ARG": "R", "ASN": "N", "ASP": "D", "CYS": "C",
    "GLN": "Q", "GLU": "E", "GLY": "G", "HIS": "H", "ILE": "I",
    "LEU": "L", "LYS": "K", "MET": "M", "PHE": "F", "PRO": "P",
    "SER": "S", "THR": "T", "TRP": "W", "TYR": "Y", "VAL": "V",
    "MSE": "M", "HSD": "H", "HSE": "H", "HSP": "H",
    "DA": "A", "DC": "C", "DG": "G", "DT": "T",
    "A": "A", "C": "C", "G": "G", "U": "U",
]

// MARK: - Theme

// Theme-driven (reads ThemeManager.shared.active). The SequencePanel view
// observes ThemeManager so these re-resolve on a theme switch.
private var headerColor: Color { ThemeManager.shared.active.accent.color }
// Selected-residue highlight uses the theme's selection color (matching the 3D
// selection indicator); text flips to black/white for contrast on that color.
private var selectionBG: Color { ThemeManager.shared.active.selectionName.color }
private var selectionFG: Color {
    let s = ThemeManager.shared.active.selectionName
    let lum: Double = 0.299 * s.r + 0.587 * s.g + 0.114 * s.b
    return lum > 0.6 ? Color.black : Color.white
}
private var rulerColor: Color { ThemeManager.shared.active.panelText.color.opacity(0.6) }
private var panelBackground: Color { ThemeManager.shared.active.panelBackground.color }
private let cellWidth: CGFloat = 10
private let rulerSpacing = 10  // draw a residue number every N residues

// MARK: - Drag hit-testing

/// Collects each residue cell's frame (in the "seq" coordinate space) so a
/// drag can map a point back to a residue.
private struct SeqResidueFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - SequencePanel View

struct SequencePanel: View {
    @EnvironmentObject var engine: PyMOLEngine
    @EnvironmentObject private var themeManager: ThemeManager   // re-render on theme switch
    @State private var residueFrames: [String: CGRect] = [:]
    @State private var lastRange: ClosedRange<Int>? = nil
    @State private var anchorIndex: Int? = nil  // for Shift-click range

    /// Flattened residue list (object order) for range/index mapping.
    private var flat: [SequenceResidue] { engine.sequences.flatMap { $0.residues } }

    /// Fixed gutter width for object-name labels, so every object's residues
    /// start at the same x — required for alignment columns (and aligned rulers)
    /// to line up across the stacked object rows.
    private var labelWidth: CGFloat {
        let longest = engine.sequences.map { $0.name.count }.max() ?? 0
        // ~6.5 pt per bold size-10 char + trailing space; clamp to a sane range.
        return min(max(CGFloat(longest) * 6.5 + 8, 48), 180)
    }

    /// Map residue id -> flat index (for click handling).
    private var idToIndex: [String: Int] {
        var m: [String: Int] = [:]
        for (i, r) in flat.enumerated() { m[r.id] = i }
        return m
    }

    var body: some View {
        // Scroll BOTH axes: horizontally through long sequences, vertically when
        // several objects are loaded (otherwise extra object rows clip against a
        // fixed-height container — the iPad sequence-bar overflow).
        ScrollView([.horizontal, .vertical], showsIndicators: true) {
            content
                .padding(.horizontal, 4)
                .padding(.vertical, 1)   // minimal padding — shrink to fit the text
                .coordinateSpace(name: "seq")
                .onPreferenceChange(SeqResidueFrames.self) { residueFrames = $0 }
                #if os(macOS)
                .gesture(selectionDrag)
                #endif
        }
        .frame(maxWidth: .infinity)
        .background(panelBackground)
        .onAppear { engine.fetchSequences() }
        .onChange(of: engine.objects) { _ in engine.fetchSequences() }
    }

    @ViewBuilder
    private var content: some View {
        if engine.sequences.isEmpty {
            Text("No sequence — load a structure")
                .font(.system(size: 10))
                .foregroundColor(rulerColor)
                .padding(.horizontal, 8)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(engine.sequences) { obj in
                    objectBlock(obj)
                }
            }
        }
    }

    // MARK: - Per-object block (label + ruler + residues)

    @ViewBuilder
    private func objectBlock(_ obj: SequenceObject) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Ruler row (offset by the label gutter): residue numbers, plus the
            // chain-ID indicator sitting above the first residue of each chain run.
            HStack(spacing: 0) {
                Color.clear.frame(width: labelWidth, height: 1)
                ForEach(Array(rulerCells(obj.residues).enumerated()), id: \.offset) { _, cell in
                    Text(cell.text)
                        .font(.system(size: 9,
                                      weight: cell.isChain ? .bold : .regular,
                                      design: .monospaced))
                        .foregroundColor(cell.isChain ? headerColor : rulerColor)
                        .frame(width: cellWidth, alignment: .leading)
                }
            }
            .frame(height: 11)

            // Residues
            HStack(spacing: 0) {
                Text(obj.name)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(headerColor)
                    .lineLimit(1)
                    .frame(width: labelWidth, alignment: .leading)
                    .onTapGesture {
                        // Click object name → add the whole object to 'sele'.
                        anchorIndex = nil
                        applyToggle(residues: obj.residues, add: true)
                    }
                ForEach(obj.residues) { r in
                    residueCell(r)
                }
            }
        }
    }

    @ViewBuilder
    private func residueCell(_ r: SequenceResidue) -> some View {
        if r.isBreak {
            // Chain-boundary separator: a thin vertical rule in a normal-width slot
            // so the ruler stays aligned with the residues below it.
            Rectangle()
                .fill(rulerColor.opacity(0.5))
                .frame(width: 1, height: 13)
                .frame(width: cellWidth, alignment: .center)
                .padding(.vertical, 1)
        } else if r.isChainLabel {
            // Holds the column under the chain-ID shown in the ruler row above;
            // the residue row itself stays blank here.
            Color.clear
                .frame(width: cellWidth, height: 13)
                .padding(.vertical, 1)
        } else {
            realResidueCell(r)
        }
    }

    private func realResidueCell(_ r: SequenceResidue) -> some View {
        let selected = r.isSelectable && engine.selectedResidueKeys.contains(r.selKey)
        return Text(r.oneLetter)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(selected ? selectionFG : r.color)
            // Left-align every cell so residues (and gap dashes) form a tight,
            // continuous run rather than floating centered in each slot.
            .frame(width: cellWidth, alignment: .leading)
            .padding(.vertical, 1)
            .background(selected ? selectionBG : Color.clear)
            .contentShape(Rectangle())
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: SeqResidueFrames.self,
                        value: [r.id: geo.frame(in: .named("seq"))])
                }
            )
            .onTapGesture { if r.isSelectable { handleClick(on: r) } }
            .help(r.isSelectable ? tooltip(r) : "")
    }

    /// Click selection (PyMOL-style, additive/toggle):
    ///  - plain click toggles the residue in/out of 'sele' (add if not
    ///    selected, remove if selected), setting the range anchor;
    ///  - Shift-click adds the range from the anchor to here;
    ///  - Ctrl-click toggles + centers.
    /// Modifiers are read from the current NSEvent on macOS.
    private func handleClick(on r: SequenceResidue) {
        guard let idx = idToIndex[r.id] else { return }
        var shift = false, ctrl = false
        #if os(macOS)
        let mods = NSEvent.modifierFlags
        shift = mods.contains(.shift)
        ctrl = mods.contains(.control)
        #endif
        if shift, let a = anchorIndex, !flat.isEmpty {
            // `idx` is resolved against the current `flat`, but `a` was captured on
            // an earlier click; if `flat` shrank since then (an object was removed/
            // replaced), `a` can be >= flat.count. Clamp both ends so the range
            // subscript can never trap out of bounds.
            let n = flat.count
            let lo = max(0, min(min(a, idx), n - 1))
            let hi = max(0, min(max(a, idx), n - 1))
            if lo <= hi {
                applyToggle(residues: Array(flat[lo...hi]), add: true)
            }
        } else {
            anchorIndex = idx
            let isSelected = engine.selectedResidueKeys.contains(r.selKey)
            applyToggle(residues: [r], add: !isSelected, center: ctrl)
        }
    }

    // MARK: - Residue-number ruler

    /// One cell per residue slot, aligned with the residue row below (both use
    /// `cellWidth` slots). Cells carry either a residue-number digit (every
    /// `rulerSpacing`, overflowing into following slots) or — at the start of a
    /// chain run — the chain-ID indicator (`isChain`), which takes priority.
    private func rulerCells(_ residues: [SequenceResidue]) -> [(text: String, isChain: Bool)] {
        var cells = Array(repeating: (text: " ", isChain: false), count: residues.count)
        // Residue numbers (real residues only; numbering restarts per chain).
        for (i, r) in residues.enumerated() where r.isSelectable {
            guard let n = Int(r.resi), n % rulerSpacing == 0 else { continue }
            for (j, c) in Array(r.resi).enumerated() where i + j < cells.count {
                cells[i + j] = (text: String(c), isChain: false)
            }
        }
        // Chain IDs sit above each chain run's first residue and win their cell.
        for (i, r) in residues.enumerated() where r.isChainLabel {
            cells[i] = (text: r.chainLabel, isChain: true)
        }
        return cells
    }

    private func tooltip(_ r: SequenceResidue) -> String {
        var tip = r.resn.isEmpty ? r.oneLetter : r.resn
        if !r.resi.isEmpty { tip += " \(r.resi)" }
        if !r.chain.isEmpty { tip += " (chain \(r.chain))" }
        return tip
    }

    // MARK: - Drag selection (macOS)

    #if os(macOS)
    // Range drag: minimumDistance is deliberately > 0 so a bare mouse-over on
    // window activation can't synthesize a selection; the drag must start ON a
    // residue and actually move.
    private var selectionDrag: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named("seq"))
            .onChanged { value in
                guard let startIdx = residueIndex(at: value.startLocation) else { return }
                let curIdx = residueIndex(at: value.location) ?? startIdx
                let range = min(startIdx, curIdx)...max(startIdx, curIdx)
                guard range != lastRange else { return }
                lastRange = range
                // Drag adds the swept range to the selection (additive).
                applyToggle(residues: Array(flat[range]), add: true)
                anchorIndex = startIdx
            }
            .onEnded { _ in lastRange = nil }
    }

    private func residueIndex(at point: CGPoint) -> Int? {
        // Match the residue cell whose frame contains the point.
        for (idx, r) in flat.enumerated() {
            if let rect = residueFrames[r.id], rect.contains(point) {
                return idx
            }
        }
        return nil
    }
    #endif

    // MARK: - Selection dispatch

    /// Toggle residues into/out of the active 'sele', mirroring PyMOL's
    /// SeekerSelectionToggle: `add` => `(?sele) or (expr)` (additive),
    /// otherwise `(sele) and not (expr)` (remove). Never replaces — clicks
    /// accumulate, and clicking a selected residue removes just that residue.
    private func applyToggle(residues: [SequenceResidue], add: Bool, center: Bool = false) {
        // Gap/break placeholders carry no real residue — drop them before building
        // a selection expression (an empty resi would produce malformed PyMOL).
        let residues = residues.filter { $0.isSelectable }
        guard !residues.isEmpty else { return }
        let expr = selectionExpression(residues)
        if add {
            engine.runCommand("select sele, (?sele) or (\(expr)), enable=1")
        } else {
            engine.runCommand("select sele, (sele) and not (\(expr)), enable=1")
        }
        if center {
            engine.runCommand("center sele, animate=-1")
        }
        // Refresh the highlight promptly (don't wait for the 500ms poll).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.engine.fetchSequenceSelection()
        }
    }

    /// Build a PyMOL selection expression, grouping residues by object+chain
    /// and listing residue numbers (robust to gaps).
    private func selectionExpression(_ residues: [SequenceResidue]) -> String {
        var groups: [String: (obj: String, chain: String, resis: [String])] = [:]
        for r in residues {
            let key = "\(r.objectName)|\(r.chain)"
            if groups[key] == nil {
                groups[key] = (r.objectName, r.chain, [])
            }
            groups[key]!.resis.append(r.resi)
        }
        let parts = groups.values.map { g -> String in
            let resiList = g.resis.joined(separator: "+")
            if g.chain.isEmpty {
                return "(\(g.obj) and resi \(resiList))"
            }
            return "(\(g.obj) and chain \(g.chain) and resi \(resiList))"
        }
        return parts.joined(separator: " or ")
    }
}

// MARK: - PyMOLEngine extensions for sequence polling

extension PyMOLEngine {
    /// Parse the SEQPANEL JSON emitted by fetchSequences() into `sequences`.
    /// Payload: { "objects": [{ "name", "residues": [[chain, resi, resn, colorIdx], ...] }],
    ///            "colors": { "<idx>": [r, g, b] } }
    func parseSequencePanelFeedback(_ line: String) {
        guard line.hasPrefix("SEQPANEL:") else { return }
        let path = TempChannel.path(TempChannel.Stem.sequence)
        guard let data = FileManager.default.contents(atPath: path) else { return }

        struct Payload: Decodable {
            struct Obj: Decodable {
                let name: String
                let residues: [[String]]
            }
            let objects: [Obj]
            let colors: [String: [Double]]
        }

        guard let p = try? JSONDecoder().decode(Payload.self, from: data) else { return }

        var objs: [SequenceObject] = []
        for o in p.objects {
            var residues: [SequenceResidue] = []
            var prevChain: String? = nil   // last real residue's chain (for breaks)
            for (i, t) in o.residues.enumerated() where t.count >= 4 {
                let chain = t[0], resi = t[1], resn = t[2], cidx = t[3]
                // Alignment gap placeholder (emitted by appkit_sequence): a dim,
                // non-selectable dash that keeps aligned residues column-aligned.
                if resn == "-" {
                    residues.append(SequenceResidue(
                        id: "\(o.name)/gap/\(i)",
                        objectName: o.name,
                        chain: "", oneLetter: "-", resi: "", resn: "-",
                        color: Color.gray.opacity(0.35),
                        isGap: true))
                    continue
                }
                // Chain boundary / first chain: insert a separator bar (between
                // chains only) and a chain-ID label at the start of each chain run
                // (skipped for blank/unnamed chains). Both are non-selectable.
                let chainChanged = (prevChain != chain)
                if chainChanged {
                    if prevChain != nil {
                        residues.append(SequenceResidue(
                            id: "\(o.name)/brk/\(i)",
                            objectName: o.name,
                            chain: "", oneLetter: "", resi: "", resn: "",
                            color: rulerColor, isBreak: true))
                    }
                    if !chain.isEmpty {
                        residues.append(SequenceResidue(
                            id: "\(o.name)/chid/\(i)",
                            objectName: o.name,
                            chain: chain, oneLetter: "", resi: "", resn: "",
                            color: headerColor, isChainLabel: true, chainLabel: chain))
                    }
                }
                prevChain = chain
                let rgb = p.colors[cidx] ?? [0.8, 0.8, 0.8]
                let color = Color(.sRGB,
                    red: rgb.count > 0 ? rgb[0] : 0.8,
                    green: rgb.count > 1 ? rgb[1] : 0.8,
                    blue: rgb.count > 2 ? rgb[2] : 0.8)
                // HETATM groups (ligands, ions, waters) are tagged 'het' by
                // appkit_sequence. They have no 1-letter code, so spread the
                // 3-letter resn (SY7, EDO, HOH…) across adjacent columns like
                // PyMOL — every cell shares one selKey (obj/chain/resi), so a
                // click on any character selects the whole group (issue #201).
                if t.count >= 5 && t[4] == "het" {
                    let letters = resn.isEmpty ? ["?"] : resn.map { String($0) }
                    for (j, ch) in letters.enumerated() {
                        residues.append(SequenceResidue(
                            id: "\(o.name)/\(chain)/\(resi)/\(i)/\(j)",
                            objectName: o.name,
                            chain: chain,
                            oneLetter: ch,
                            resi: resi,
                            resn: resn,
                            color: color
                        ))
                    }
                    continue
                }
                residues.append(SequenceResidue(
                    id: "\(o.name)/\(chain)/\(resi)/\(i)",
                    objectName: o.name,
                    chain: chain,
                    oneLetter: aa3to1[resn.uppercased()] ?? "X",
                    resi: resi,
                    resn: resn,
                    color: color
                ))
            }
            if !residues.isEmpty {
                objs.append(SequenceObject(id: o.name, name: o.name, residues: residues))
            }
        }

        DispatchQueue.main.async {
            self.sequences = objs
        }
    }

    /// Parse the SEQSEL JSON (active-selection residue keys) into
    /// `selectedResidueKeys` for highlight sync.
    func parseSequenceSelectionFeedback(_ line: String) {
        guard line.hasPrefix("SEQSEL:") else { return }
        let path = TempChannel.path(TempChannel.Stem.sequenceSelection)
        guard let data = FileManager.default.contents(atPath: path) else { return }
        guard let keys = try? JSONDecoder().decode([String].self, from: data) else { return }
        let set = Set(keys)
        DispatchQueue.main.async {
            if self.selectedResidueKeys != set {
                self.selectedResidueKeys = set
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
struct SequencePanel_Previews: PreviewProvider {
    static var previews: some View {
        SequencePanel()
            .environmentObject(PyMOLEngine.shared)
            .frame(width: 800, height: 60)
            .previewLayout(.sizeThatFits)
    }
}
#endif

// MARK: - Entry rows: the model (#419, pure)

/// One entry as the Sequences tab needs it: what `SetRow` already carries, plus the
/// per-chain sequences that `SetEntryDetail` loads lazily.
///
/// A value type with the sequences ALREADY RESOLVED, rather than a reference to the
/// store, so the layout below can be exercised with three literal sequences and no
/// file — which is what makes "aligned by shared parent" a test rather than a claim.
struct SequenceEntryInput: Equatable, Identifiable {
    let id: String
    let name: String
    let ord: Int
    /// `entries.sequences`: `{chain: one-letter}`.
    let sequences: [String: String]
    /// `entries.parents` — entry ids, which may point into another set.
    let parents: [String]
    /// `entries.run_id`, the fallback alignment group for an entry with no parent.
    let runID: String?
    let starred: Bool
    let rejected: Bool
    let staged: Bool

    init(id: String, name: String, ord: Int = 0, sequences: [String: String],
         parents: [String] = [], runID: String? = nil, starred: Bool = false,
         rejected: Bool = false, staged: Bool = false) {
        self.id = id
        self.name = name
        self.ord = ord
        self.sequences = sequences
        self.parents = parents
        self.runID = runID
        self.starred = starred
        self.rejected = rejected
        self.staged = staged
    }

    /// Chains in a stable, displayable order. The store writes `sequences` as a JSON
    /// object, and a dictionary has no order, so sorting is not a preference — it is
    /// the only way two entries of the same design can lay their chains out the same
    /// way twice running.
    var chainOrder: [String] { sequences.keys.sorted() }

    /// The alignment group this row belongs to (see `SequenceRowModel`).
    var groupKey: String { parents.first ?? runID ?? "" }
}

/// One cell of an entry row. A gap carries no chain and no position: it is a column
/// that this row does not reach, and nothing may select it or read a metric at it.
struct SequenceEntryCell: Equatable {
    let letter: String
    let chain: String
    /// Index of this residue WITHIN its chain, 0-based. -1 for a gap or a break.
    let position: Int
    let isGap: Bool
    let isBreak: Bool

    static func gap(chain: String) -> SequenceEntryCell {
        SequenceEntryCell(letter: "-", chain: chain, position: -1, isGap: true,
                          isBreak: false)
    }
    static let chainBreak = SequenceEntryCell(letter: "", chain: "", position: -1,
                                              isGap: false, isBreak: true)

    var isResidue: Bool { !isGap && !isBreak }
}

/// One laid-out entry row.
struct SequenceEntryRow: Equatable, Identifiable {
    let id: String
    let name: String
    let groupKey: String
    let cells: [SequenceEntryCell]
    let starred: Bool
    let rejected: Bool
    let staged: Bool
    let isSelected: Bool
}

/// One column of the consensus/logo band: what the population has here.
struct ConsensusColumn: Equatable {
    /// The most common residue, or "" when every row gaps this column.
    let letter: String
    /// Rows that have a residue here at all.
    let count: Int
    /// `letter`'s share of `count`, 0…1. The bar's height, and what makes a conserved
    /// column read as one at a glance.
    let fraction: Double
    /// How many different residues appear here. 1 is invariant; the band draws those
    /// solid, because "these 800 sequences never change position 31" is the single
    /// most useful thing a collapsed view can say.
    let distinct: Int

    static let empty = ConsensusColumn(letter: "", count: 0, fraction: 0, distinct: 0)
    var isInvariant: Bool { distinct == 1 && count > 0 }
}

/// Everything the Sequences tab computes from a list of entries.
///
/// Three decisions live here, and all three are pinned by `SequenceRowModelTests`:
///
/// 1. **Alignment by shared parent.** Rows that came from the same backbone are the
///    rows a user is comparing — eight MPNN sequences off one RFD3 design — so they
///    share a column space: per chain, every row in the group is padded to the group's
///    longest run of that chain, and a chain a row does not have at all is a run of
///    gaps. Position 31 is then position 31 on every row of the group, which is the
///    only way "where do they differ" can be read down a column. Rows with no parent
///    fall back to their RUN, which is the same statement one level up (the entries a
///    single tool invocation produced), and then to one shared group.
///
///    It is not a sequence ALIGNMENT and does not pretend to be: nothing here scores a
///    substitution or opens an internal gap. A real alignment is what an alignment
///    OBJECT is for, and when one is enabled the scene rows above carry its gaps,
///    computed by `appkit_sequence._apply_alignments` from `cmd.get_raw_alignment` —
///    the same path, unchanged, that the strip has always used.
///
/// 2. **The collapse threshold, 200.** Above it the rows become a consensus band with
///    the selected rows kept on top. 200 because the drawer's usable height tops out
///    near 1000pt even on a 6K display and an entry row is ~28pt — so 200 rows is
///    already six screenfuls of scrolling, and a user who is six screens deep is not
///    comparing sequences, they are looking for a pattern, which is what the band
///    draws. It is also the point past which the lazy loader stops being able to hide:
///    every row scrolled past is a blob read, and 200 is a scroll, where 8000 is a
///    file read. The number is a `let` on the model and every test names it, so moving
///    it is one edit and a visible diff.
///
/// 3. **What a heat strip is allowed to line up with.** `entries.sequences` carries no
///    residue numbering, so a residue array is mapped onto a row POSITIONALLY, per
///    chain, and only when the array's run for that chain is exactly as long as the
///    sequence. A near-miss draws nothing rather than sliding every value one residue
///    to the left, which is the failure mode that would look plausible and be wrong.
struct SequenceRowModel: Equatable {
    /// See the type doc, decision 2.
    static let defaultCollapseThreshold = 200

    let entries: [SequenceEntryInput]
    let selection: Set<String>
    let collapseThreshold: Int

    /// Every entry, laid out. Always the full list — `displayedRows` is what a view
    /// draws, and the consensus band is computed over THIS.
    let rows: [SequenceEntryRow]
    /// Group key → the chain order and per-chain width that group was padded to.
    let groups: [String: GroupLayout]

    struct GroupLayout: Equatable {
        let chainOrder: [String]
        let width: [String: Int]
        /// Total cells in a row of this group, breaks included.
        let columns: Int
    }

    init(entries: [SequenceEntryInput], selection: Set<String> = [],
         collapseThreshold: Int = SequenceRowModel.defaultCollapseThreshold) {
        self.entries = entries
        self.selection = selection
        self.collapseThreshold = max(collapseThreshold, 1)

        // One pass to size each group, a second to lay its rows out against that size.
        var order: [String] = []
        var chainOrders: [String: [String]] = [:]
        var widths: [String: [String: Int]] = [:]
        for entry in entries {
            let key = entry.groupKey
            if chainOrders[key] == nil {
                chainOrders[key] = []
                widths[key] = [:]
                order.append(key)
            }
            for chain in entry.chainOrder {
                if !(chainOrders[key] ?? []).contains(chain) {
                    chainOrders[key, default: []].append(chain)
                }
                let n = entry.sequences[chain]?.count ?? 0
                widths[key]![chain] = max(widths[key]![chain] ?? 0, n)
            }
        }
        var layouts: [String: GroupLayout] = [:]
        for key in order {
            // Chains sorted, not first-seen: two rows of one group must agree on the
            // order, and "whichever row the store handed us first" is not an order.
            let chains = (chainOrders[key] ?? []).sorted()
            let width = widths[key] ?? [:]
            let cells = chains.reduce(0) { $0 + (width[$1] ?? 0) }
            layouts[key] = GroupLayout(chainOrder: chains, width: width,
                                       columns: cells + max(chains.count - 1, 0))
        }
        self.groups = layouts

        self.rows = entries.map { entry in
            let layout = layouts[entry.groupKey]
                ?? GroupLayout(chainOrder: entry.chainOrder, width: [:], columns: 0)
            var cells: [SequenceEntryCell] = []
            for (i, chain) in layout.chainOrder.enumerated() {
                if i > 0 { cells.append(.chainBreak) }
                let letters = Array(entry.sequences[chain] ?? "")
                let width = layout.width[chain] ?? letters.count
                for position in 0..<width {
                    if position < letters.count {
                        cells.append(SequenceEntryCell(letter: String(letters[position]),
                                                       chain: chain, position: position,
                                                       isGap: false, isBreak: false))
                    } else {
                        cells.append(.gap(chain: chain))
                    }
                }
            }
            return SequenceEntryRow(id: entry.id, name: entry.name,
                                    groupKey: entry.groupKey, cells: cells,
                                    starred: entry.starred, rejected: entry.rejected,
                                    staged: entry.staged,
                                    isSelected: selection.contains(entry.id))
        }
    }

    // MARK: collapse

    var isCollapsed: Bool { rows.count > collapseThreshold }

    /// The rows a view draws. Under the threshold, all of them. Over it, the SELECTED
    /// rows only — spec §4.4's "the selected rows on top" — because the whole point of
    /// selecting three of a thousand is to read those three, and the band below carries
    /// what the other 997 say.
    var displayedRows: [SequenceEntryRow] {
        guard isCollapsed else { return rows }
        return rows.filter { $0.isSelected }
    }

    /// Rows the collapse is hiding.
    var collapsedRowCount: Int {
        isCollapsed ? rows.count - displayedRows.count : 0
    }

    /// How many rows actually CONTRIBUTED to the band — rows with at least one residue
    /// in them.
    ///
    /// This, not `collapsedRowCount`, is what the caption names. The two are equal once
    /// the set's sequences are loaded, and they are not equal while that read is in
    /// flight, and the gap is the whole failure this guards: a caption reading "997 in
    /// the consensus band" over a band computed from the 23 rows that happened to be
    /// resident is a claim about a population from 2% of it. A caption that can only
    /// ever say what it counted cannot make that claim.
    var consensusPopulation: Int {
        rows.reduce(0) { $0 + (($1.cells.contains { $0.isResidue }) ? 1 : 0) }
    }

    // MARK: consensus

    /// The logo band: one column per cell position, over EVERY row (not just the
    /// displayed ones — a consensus of the three you selected is not a consensus).
    ///
    /// Rows of different groups have different column spaces, so column i means
    /// "position i of whatever this row is"; with one group, which is the case the
    /// band exists for, that is exactly position i of the alignment.
    var consensus: [ConsensusColumn] {
        let width = rows.map(\.cells.count).max() ?? 0
        guard width > 0 else { return [] }
        var out: [ConsensusColumn] = []
        out.reserveCapacity(width)
        for column in 0..<width {
            var counts: [String: Int] = [:]
            var total = 0
            for row in rows where column < row.cells.count {
                let cell = row.cells[column]
                guard cell.isResidue else { continue }
                counts[cell.letter, default: 0] += 1
                total += 1
            }
            guard total > 0 else {
                out.append(.empty)
                continue
            }
            // Ties broken alphabetically, so the band is the same band twice running.
            let best = counts.max { a, b in
                a.value == b.value ? a.key > b.key : a.value < b.value
            }
            out.append(ConsensusColumn(letter: best?.key ?? "", count: total,
                                       fraction: Double(best?.value ?? 0) / Double(total),
                                       distinct: counts.count))
        }
        return out
    }

    // MARK: residue arrays

    /// ALL of one metric's residue arrays mapped onto a row's cells: one optional
    /// value per cell, in cell order, so a view can walk the two together with no
    /// arithmetic of its own.
    ///
    /// Takes a LIST, because `arrays`' primary key is `(entry_id, key, chain)` and one
    /// metric legitimately arrives as several rows — a whole-entry array, a per-chain
    /// one, or both. Taking only the first meant every chain but one drew as "not
    /// measured", which turns a chain that scored badly into a chain nobody scored:
    /// `plddt/A = 100` and `plddt/B = 20` drew as a perfect A and a blank B.
    ///
    /// Merged per chain, with the CHAIN-SCOPED array winning over a whole-entry one
    /// for the chain it names — it is the more specific statement, which is why the
    /// store lets both exist. Everything else is unchanged: per chain, joined by chain
    /// NAME rather than by position between chains, and only on an exact length match
    /// (see the type doc, decision 3).
    static func heatValues(row: SequenceEntryRow, arrays: [ResidueArray]) -> [Double?] {
        var byChain: [String: [Double?]] = [:]
        // Whole-entry arrays first so a chain-scoped one overwrites the chain it
        // covers rather than being overwritten by it.
        for array in arrays.sorted(by: { ($0.chain ?? "") < ($1.chain ?? "") })
            .sorted(by: { $0.chain == nil && $1.chain != nil }) {
            var here: [String: [Double?]] = [:]
            for (i, key) in array.index.enumerated() where i < array.values.count {
                here[key.chain, default: []].append(array.values[i])
            }
            // An array whose index names no chain at all (a single unnamed chain,
            // which `_add_array` stores as "") is joined to the row's single chain
            // when the row has exactly one, so a monomer with a blank chain id still
            // gets its strip.
            if here.count == 1, let only = here.first, only.key.isEmpty {
                let rowChains = Set(row.cells.filter(\.isResidue).map(\.chain))
                if rowChains.count == 1, let chain = rowChains.first {
                    here = [chain: only.value]
                }
            }
            for (chain, values) in here { byChain[chain] = values }
        }
        // Length check per chain, up front: a mismatch drops that chain's strip and
        // leaves the others, rather than dropping the whole row for one bad chain.
        var usable: [String: [Double?]] = [:]
        for (chain, values) in byChain {
            let length = row.cells.filter { $0.isResidue && $0.chain == chain }.count
            if length == values.count { usable[chain] = values }
        }
        return row.cells.map { cell in
            guard cell.isResidue, cell.position >= 0,
                  let values = usable[cell.chain], cell.position < values.count
            else { return nil }
            return values[cell.position]
        }
    }
}

// MARK: - Heat tracks (#419)

/// One per-residue metric drawn as a strip under a row (spec §4.4: pLDDT, MPNN native
/// fit and certainty, "using the same domains Design mode uses").
///
/// The domain comes from the SET when the set declares the array — array-scope metrics
/// are in `sets.columns` with `column = null`, carrying their `MetricSpec`'s `lo`/`hi`
/// — so a predictor that scores 0…1 rather than 0…100 needs no edit here. The
/// fallbacks below are `DesignColor`'s own constants, which is what makes a native-fit
/// strip in the drawer the same colour as the same residue in Design mode.
struct SequenceHeatTrack: Equatable, Identifiable {
    let key: String
    let label: String
    let domain: ClosedRange<Double>
    /// nil when the spec says neither — an elapsed time is neither. A track like that
    /// has no good end to ramp towards, so `goodness` returns nil and the strip paints
    /// nothing; `tracks(columns:)` leaves it out entirely rather than offer a pill that
    /// can only draw blank.
    let higherIsBetter: Bool?

    var id: String { key }

    /// Design mode's native-fit domain, widened to Double. Referencing `DesignColor`
    /// where it exists rather than copying the numbers is the point — one constant,
    /// two views — and the `#else` is only for a build without MPNN, where the
    /// value still has to be SOME range for the strip to draw at all.
    static var nativeFitDomain: ClosedRange<Double> {
        #if RAYMOL_MPNN
        return Double(DesignColor.nativeFitDomain.lowerBound)
            ... Double(DesignColor.nativeFitDomain.upperBound)
        #else
        return (-6.0)...0.0
        #endif
    }
    static var certaintyDomain: ClosedRange<Double> {
        #if RAYMOL_MPNN
        return Double(DesignColor.certaintyDomain.lowerBound)
            ... Double(DesignColor.certaintyDomain.upperBound)
        #else
        return 0.0...1.0
        #endif
    }
    /// pLDDT is 0…100 by definition; every predictor's `MetricSpec` declares it that
    /// way, so this is the fallback for an array a set forgot to declare.
    static let plddtDomain: ClosedRange<Double> = 0...100

    /// The three the spec names, in the order they draw.
    static let known: [SequenceHeatTrack] = [
        SequenceHeatTrack(key: "plddt", label: "pLDDT", domain: plddtDomain,
                          higherIsBetter: true),
        SequenceHeatTrack(key: "native_fit", label: "Native fit", domain: nativeFitDomain,
                          higherIsBetter: true),
        SequenceHeatTrack(key: "certainty", label: "Certainty", domain: certaintyDomain,
                          higherIsBetter: true),
    ]

    /// The track for an array key, taking the domain from the set's own declaration
    /// when it has one. nil for a key this build has no strip for — an unknown
    /// residue array is data the tab cannot draw honestly, not a reason to invent a
    /// domain from the values in front of it (the metrics store's rule, which is also
    /// why the table's ramp goes untinted without a domain).
    static func track(key: String, columns: [MetricColumn]) -> SequenceHeatTrack? {
        let declared = columns.first { $0.key == key && $0.scope == "residue" }
        let domain: ClosedRange<Double>?
        if let column = declared, let lo = column.lo, let hi = column.hi, hi > lo {
            domain = lo...hi
        } else {
            domain = nil
        }
        guard let base = known.first(where: { $0.key == key }) else {
            // A metric this build has no strip for. It draws only if the SET declares
            // a domain for it; with neither, there is nothing to ramp against, and a
            // domain taken from the values in front of you is the auto-scaling the
            // metrics store exists to refuse (the table's ramp goes untinted for
            // exactly this reason).
            guard let domain, let column = declared else { return nil }
            return SequenceHeatTrack(key: key, label: column.label.isEmpty ? key : column.label,
                                     domain: domain, higherIsBetter: column.higherIsBetter)
        }
        guard let domain, let column = declared else { return base }
        return SequenceHeatTrack(key: base.key,
                                 label: column.label.isEmpty ? base.label : column.label,
                                 domain: domain,
                                 higherIsBetter: column.higherIsBetter ?? base.higherIsBetter)
    }

    /// Every track a set has a residue array for, in `known` order then declaration
    /// order, so the strips under a row are in the same order under every row.
    static func tracks(columns: [MetricColumn]) -> [SequenceHeatTrack] {
        let residue = columns.filter { $0.scope == "residue" }
        var out: [SequenceHeatTrack] = []
        // A track with no good end can only ever paint blank (see `goodness`), so it
        // is left out rather than offered as a pill that does nothing.
        func add(_ key: String) {
            guard let resolved = self.track(key: key, columns: columns),
                  resolved.higherIsBetter != nil,
                  !out.contains(where: { $0.key == key }) else { return }
            out.append(resolved)
        }
        for track in known where residue.contains(where: { $0.key == track.key }) {
            add(track.key)
        }
        for column in residue { add(column.key) }
        return out
    }

    /// Where a value sits in the domain, 0…1 and oriented so 1 is GOOD — the same
    /// convention `SetTableModel.goodness` uses, so a red cell in the table and a red
    /// residue in the strip mean the same thing.
    ///
    /// nil in three cases, and the third is the one that was wrong: an absent value
    /// (which draws nothing rather than a zero), a degenerate domain, and a metric
    /// whose spec says NEITHER end is better. `higherIsBetter == false ? 1 - f : f`
    /// folded that last case in with "higher is better" and painted an elapsed time
    /// green at the top — while `SetTableModel.goodness` returned nil for the same
    /// metric and left its table cell untinted. Two views, one `MetricSpec`, opposite
    /// claims; this is the one that was lying.
    func goodness(_ value: Double?) -> Double? {
        guard let higherIsBetter, let value, value.isFinite else { return nil }
        let span = domain.upperBound - domain.lowerBound
        guard span > 0 else { return nil }
        let f = min(max((value - domain.lowerBound) / span, 0), 1)
        return higherIsBetter ? f : 1 - f
    }
}

// MARK: - The Sequences tab (#419, macOS)

#if os(macOS)

/// The drawer's Sequences tab: the scene rows on top, the set's entry rows below.
///
/// With no set open this is `SequencePanel()` and nothing else — the strip, in its new
/// home, which is spec §8 decision 2's compatibility contract. With a set open, entry
/// rows follow underneath: the SELECTED entries when there is a selection, and the
/// filtered rows otherwise, which is the same "what am I looking at" rule the Plot tab
/// follows (`engine.filteredSetRows`).
///
/// The two halves keep their own scrollers on purpose. Their column spaces are
/// different things — a scene row is numbered by the structure's own `resi` and is
/// gap-aligned by an alignment OBJECT, an entry row is padded against its parent group
/// — so one shared horizontal scroll would imply a correspondence that is not there.
struct SequencesTabView: View {
    let set: SetEntry?
    let rows: [SetRow]
    @EnvironmentObject var engine: PyMOLEngine
    @EnvironmentObject private var themeManager: ThemeManager

    private var hairline: Color { themeManager.active.panelText.color.opacity(0.18) }

    var body: some View {
        if let set {
            // A VSplitView, not a fixed cap. The strip this replaced sized itself to
            // its row count (up to five rows) and the user could drag it taller still;
            // pinning the scene rows at 130pt was a real reduction for the same
            // content. Same formula, same 400pt ceiling, same `.id(rows)` so the split
            // re-adopts the ideal height when an object is loaded or removed (without
            // it a pinned divider keeps the first-seen height and hides later rows).
            VSplitView {
                SequencePanel()
                    .frame(minHeight: 40, idealHeight: Self.sceneHeight(engine.sequences.count),
                           maxHeight: 400)
                    .id(min(max(engine.sequences.count, 1), 5))
                SequenceEntryRowsView(set: set, rows: entryRows)
                    .frame(minHeight: 60)
            }
        } else {
            SequencePanel()
        }
    }

    /// The strip's own height formula: one block per object (ruler + residues ≈ 28pt,
    /// charged at 30) up to five, plus 30 for the horizontal scrollbar and padding.
    static func sceneHeight(_ objects: Int) -> CGFloat {
        CGFloat(min(max(objects, 1), 5)) * 30 + 30
    }

    /// Selected rows when there are any, else everything the filter admits. Spec §4.4
    /// says "the selected or filtered entries", and the selection is the narrower of
    /// the two by construction.
    private var entryRows: [SetRow] {
        guard !engine.setSelection.isEmpty else { return rows }
        let picked = rows.filter { engine.setSelection.contains($0.id) }
        return picked.isEmpty ? rows : picked
    }
}

/// The entry half: a label gutter, one row per entry, and the heat strips under each.
///
/// `LazyVStack` is the laziness (#421: "residue arrays load on demand for the
/// Sequences tab"). A row that has never been on screen has never been built, so its
/// `.onAppear` has never fired, so its blobs have never been read — and the ids it
/// does ask for go through `PyMOLEngine.requestSequenceDetails`, which batches the
/// window and its look-ahead into ONE pair of queries. A thousand-entry set therefore
/// costs the blobs of the rows a scroll actually passed, which `SequenceLazyLoadTests`
/// asserts on `SetsStore.arrayBlobReads`.
struct SequenceEntryRowsView: View {
    let set: SetEntry
    let rows: [SetRow]
    @EnvironmentObject var engine: PyMOLEngine
    @EnvironmentObject private var themeManager: ThemeManager
    /// Which strips are on. All of the set's residue metrics, until the user says
    /// otherwise; an entry with none draws none and the picker is absent.
    @State private var hiddenTracks: Set<String> = []

    private static let rowHeight: CGFloat = 15
    private static let stripHeight: CGFloat = 4

    private var hairline: Color { themeManager.active.panelText.color.opacity(0.18) }

    private var model: SequenceRowModel {
        SequenceRowModel(entries: rows.map { row in
            SequenceEntryInput(
                id: row.id, name: row.name, ord: row.ord,
                sequences: engine.sequenceDetail(row.id)?.sequences ?? [:],
                parents: row.parents, runID: row.runID,
                starred: row.starred, rejected: row.rejected, staged: row.isStaged)
        }, selection: engine.setSelection)
    }

    private var tracks: [SequenceHeatTrack] {
        SequenceHeatTrack.tracks(columns: set.columns).filter { !hiddenTracks.contains($0.key) }
    }

    private var labelWidth: CGFloat {
        let longest = rows.map { $0.name.count }.max() ?? 0
        return min(max(CGFloat(longest) * 6.5 + 8, 48), 180)
    }

    var body: some View {
        let model = self.model
        VStack(spacing: 0) {
            controls(model: model)
            Rectangle().fill(hairline).frame(height: 1)
            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if model.isCollapsed {
                        consensusBand(model: model)
                    }
                    ForEach(model.displayedRows) { row in
                        entryRow(row)
                            .onAppear { engine.requestSequenceDetails(around: row.id,
                                                                     in: rows.map(\.id)) }
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }
            .background(PanelTheme.background)
        }
        // The band is a statement about the WHOLE set, so it needs every sequence —
        // and above the threshold no row is displayed, so no row's `onAppear` fires
        // and the per-row loader would never run at all. Text only; the arrays stay
        // per-row-lazy, and `loadSequencesForBand` is idempotent per set.
        .onAppear { if model.isCollapsed { engine.loadSequencesForBand(setID: set.id) } }
        .onChange(of: model.isCollapsed) { collapsed in
            if collapsed { engine.loadSequencesForBand(setID: set.id) }
        }
    }

    // MARK: controls

    @ViewBuilder
    private func controls(model: SequenceRowModel) -> some View {
        HStack(spacing: 8) {
            // `consensusPopulation`, not `collapsedRowCount`: the caption may only
            // name what the band was actually computed over. While the set's
            // sequences are still arriving the two differ, and the difference is the
            // whole of the claim.
            Text(model.isCollapsed
                 ? "\(model.displayedRows.count) shown · \(model.consensusPopulation)"
                   + " in the consensus band"
                 : "\(model.rows.count) entr\(model.rows.count == 1 ? "y" : "ies")")
                .font(.system(size: 10))
                .foregroundColor(PanelTheme.disabledColor)
                .help(model.isCollapsed
                      ? "Above \(model.collapseThreshold) rows the tab draws a"
                        + " consensus band and keeps the SELECTED rows above it."
                        + " Select rows in the Table to read them here."
                      : "Rows that share a parent are padded to one column space, so"
                        + " position N is position N on every row of that group.")
            ForEach(SequenceHeatTrack.tracks(columns: set.columns)) { track in
                let on = !hiddenTracks.contains(track.key)
                Text(track.label)
                    .font(.system(size: 9, weight: on ? .semibold : .regular))
                    .foregroundColor(on ? PanelTheme.textColor : PanelTheme.disabledColor)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3)
                                    .fill(on ? PanelTheme.buttonBackground : Color.clear))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if on { hiddenTracks.insert(track.key) }
                        else { hiddenTracks.remove(track.key) }
                    }
                    .help(Self.trackHelp(track))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 18)
    }

    private static func number(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%g", v)
    }

    /// Built outside the view builder: interpolating four calls into one `.help`
    /// pushed the toolbar's expression past the type-checker's budget.
    private static func trackHelp(_ track: SequenceHeatTrack) -> String {
        let lo = number(track.domain.lowerBound)
        let hi = number(track.domain.upperBound)
        return "Per-residue " + track.label + ", " + lo + "–" + hi
            + ", loaded from the set's residue arrays for the rows on screen"
    }

    // MARK: rows

    @ViewBuilder
    private func entryRow(_ row: SequenceEntryRow) -> some View {
        let detail = engine.sequenceDetail(row.id)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text(row.name)
                    .font(.system(size: 10, weight: row.isSelected ? .bold : .regular))
                    .foregroundColor(row.rejected ? PanelTheme.disabledColor
                                     : (row.isSelected ? PanelTheme.textColor
                                        : PanelTheme.headerColor))
                    .strikethrough(row.rejected)
                    .lineLimit(1)
                    .frame(width: labelWidth, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { engine.setSelection = [row.id] }
                    .help(row.groupKey.isEmpty ? row.name
                          : "\(row.name) — aligned with the other rows of \(row.groupKey)")
                if detail == nil {
                    Text("loading…")
                        .font(.system(size: 9))
                        .foregroundColor(PanelTheme.disabledColor)
                } else {
                    ForEach(Array(row.cells.enumerated()), id: \.offset) { _, cell in
                        cellView(cell)
                    }
                }
            }
            .frame(height: Self.rowHeight)
            if let detail {
                ForEach(tracks) { track in
                    // EVERY array under the key — one metric can be several rows, one
                    // per chain (see `SetEntryDetail.arrays(_:)`).
                    let arrays = detail.arrays(track.key)
                    if !arrays.isEmpty {
                        heatStrip(row: row, arrays: arrays, track: track)
                    }
                }
            }
        }
        .background(row.isSelected ? selectionBG.opacity(0.18) : Color.clear)
    }

    @ViewBuilder
    private func cellView(_ cell: SequenceEntryCell) -> some View {
        if cell.isBreak {
            Rectangle().fill(PanelTheme.disabledColor.opacity(0.5))
                .frame(width: 1, height: 11)
                .frame(width: cellWidth, alignment: .center)
        } else {
            Text(cell.letter)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(cell.isGap ? PanelTheme.disabledColor.opacity(0.5)
                                 : PanelTheme.textColor)
                .frame(width: cellWidth, alignment: .leading)
        }
    }

    /// One strip: a rectangle per cell, tinted by `goodness`, absent where the array
    /// has no value. Absent, not grey — "not measured" and "measured badly" are the
    /// distinction the whole metrics store is built on.
    @ViewBuilder
    private func heatStrip(row: SequenceEntryRow, arrays: [ResidueArray],
                           track: SequenceHeatTrack) -> some View {
        let values = SequenceRowModel.heatValues(row: row, arrays: arrays)
        // An array that maps onto nothing — zero index entries, or a length that
        // disagrees with every chain — drew a 4pt row of clear rectangles under the
        // sequence: invisible, but it pushed the next row down and made the spacing
        // between rows depend on data nobody could see. No values, no strip.
        if values.contains(where: { $0 != nil }) {
            HStack(spacing: 0) {
                Color.clear.frame(width: labelWidth, height: Self.stripHeight)
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    Rectangle()
                        .fill(Self.tint(track.goodness(value)))
                        .frame(width: cellWidth, height: Self.stripHeight)
                }
            }
            .help("\(track.label) per residue")
        }
    }

    /// The table's ramp, at full strength: a 4pt strip has no text to fight, and the
    /// point of it is to be readable at a glance down a column.
    static func tint(_ goodness: Double?) -> Color {
        guard let g = goodness else { return .clear }
        let bad = (r: 0.85, g: 0.35, b: 0.30)
        let good = (r: 0.20, g: 0.65, b: 0.40)
        return Color(.sRGB,
                     red: bad.r + (good.r - bad.r) * g,
                     green: bad.g + (good.g - bad.g) * g,
                     blue: bad.b + (good.b - bad.b) * g,
                     opacity: 0.85)
    }

    // MARK: consensus band

    @ViewBuilder
    private func consensusBand(model: SequenceRowModel) -> some View {
        let columns = model.consensus
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("consensus")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(PanelTheme.headerColor)
                    .frame(width: labelWidth, alignment: .leading)
                ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                    Text(column.letter)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(column.isInvariant ? PanelTheme.textColor
                                         : PanelTheme.headerColor.opacity(
                                            0.35 + 0.65 * column.fraction))
                        .frame(width: cellWidth, alignment: .leading)
                }
            }
            .frame(height: Self.rowHeight)
            // The logo bar: height is the winner's share, so a conserved column is a
            // full bar and a variable one is a stub.
            HStack(alignment: .bottom, spacing: 0) {
                Color.clear.frame(width: labelWidth, height: 10)
                ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                    Rectangle()
                        .fill(PanelTheme.accentColor.opacity(0.55))
                        .frame(width: cellWidth - 1,
                               height: max(1, 10 * CGFloat(column.fraction)))
                        .frame(width: cellWidth, height: 10, alignment: .bottom)
                }
            }
            .frame(height: 10)
        }
        .padding(.bottom, 3)
        .help("Every row's residue at each position: the most common one, with the"
              + " bar showing its share. Solid where the population never varies.")
    }
}

#endif
