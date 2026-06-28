// SequencePanel.swift — Horizontal scrollable sequence viewer
// SwiftUI reimplementation of PyMOL's seq_view (layer3/Seeker.cpp + layer1/Seq.cpp).
//
// Features mirrored from the original:
//  - One-letter codes per residue, colored by the residue's ACTUAL molecular
//    color (guide-atom color) so spectrum/by-element/custom coloring shows.
//  - Selection highlight synced both ways with the active 'sele' selection.
//  - Click to select a residue; drag to select a range; Shift extends,
//    Ctrl selects-and-centers; click on empty space deselects.
//  - Residue-number ruler above each sequence (every N residues).

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
        let path = NSTemporaryDirectory() + "pymol_seq.json"
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
        let path = NSTemporaryDirectory() + "pymol_seqsel.json"
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
