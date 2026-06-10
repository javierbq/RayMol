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

private let headerColor = Color(red: 0.55, green: 0.75, blue: 1.0)
private let rulerColor = Color(red: 0.55, green: 0.55, blue: 0.58)
private let panelBackground = Color(red: 0.165, green: 0.165, blue: 0.172)
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
    @State private var residueFrames: [String: CGRect] = [:]
    @State private var lastRange: ClosedRange<Int>? = nil
    @State private var anchorIndex: Int? = nil  // for Shift-click range

    /// Flattened residue list (object order) for range/index mapping.
    private var flat: [SequenceResidue] { engine.sequences.flatMap { $0.residues } }

    /// Map residue id -> flat index (for click handling).
    private var idToIndex: [String: Int] {
        var m: [String: Int] = [:]
        for (i, r) in flat.enumerated() { m[r.id] = i }
        return m
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            content
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
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
            // Residue-number ruler
            HStack(spacing: 0) {
                ForEach(Array(rulerChars(obj.residues).enumerated()), id: \.offset) { _, ch in
                    Text(String(ch))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(rulerColor)
                        .frame(width: cellWidth, alignment: .leading)
                }
            }
            .frame(height: 11)

            // Residues
            HStack(spacing: 0) {
                Text(obj.name + " ")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(headerColor)
                    .onTapGesture {
                        // Click object name → select the whole object.
                        anchorIndex = nil
                        applySelection(residues: obj.residues, extend: false, center: false)
                    }
                ForEach(obj.residues) { r in
                    residueCell(r)
                }
            }
        }
    }

    private func residueCell(_ r: SequenceResidue) -> some View {
        let selected = engine.selectedResidueKeys.contains(r.selKey)
        return Text(r.oneLetter)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(selected ? .black : r.color)
            .frame(width: cellWidth, alignment: .center)
            .padding(.vertical, 1)
            .background(selected ? Color.white : Color.clear)
            .contentShape(Rectangle())
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: SeqResidueFrames.self,
                        value: [r.id: geo.frame(in: .named("seq"))])
                }
            )
            .onTapGesture { handleClick(on: r) }
            .help(tooltip(r))
    }

    /// Click selection: plain = single (set anchor), Shift = range from anchor,
    /// Ctrl = single + center. Modifiers read from the current NSEvent on macOS.
    private func handleClick(on r: SequenceResidue) {
        guard let idx = idToIndex[r.id] else { return }
        var shift = false, ctrl = false
        #if os(macOS)
        let mods = NSEvent.modifierFlags
        shift = mods.contains(.shift)
        ctrl = mods.contains(.control)
        #endif
        if shift, let a = anchorIndex {
            let lo = min(a, idx), hi = max(a, idx)
            applySelection(residues: Array(flat[lo...hi]), extend: false, center: false)
        } else {
            anchorIndex = idx
            applySelection(residues: [r], extend: false, center: ctrl)
        }
    }

    // MARK: - Residue-number ruler

    /// One character per residue slot; numbers (every `rulerSpacing`) are written
    /// left-aligned starting at the labeled residue, overflowing into following
    /// slots. Aligns with residue cells because both use `cellWidth` slots.
    private func rulerChars(_ residues: [SequenceResidue]) -> [Character] {
        var chars = Array(repeating: Character(" "), count: residues.count)
        for (i, r) in residues.enumerated() {
            guard let n = Int(r.resi), n % rulerSpacing == 0 else { continue }
            for (j, c) in Array(r.resi).enumerated() where i + j < chars.count {
                chars[i + j] = c
            }
        }
        return chars
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
                let ctrl = NSEvent.modifierFlags.contains(.control)
                applySelection(residues: Array(flat[range]), extend: false, center: ctrl)
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

    private func applySelection(residues: [SequenceResidue], extend: Bool, center: Bool) {
        guard !residues.isEmpty else { return }
        let expr = selectionExpression(residues)
        if extend {
            engine.runCommand("select sele, (sele) or (\(expr))")
        } else {
            engine.runCommand("select sele, \(expr)")
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
            for (i, t) in o.residues.enumerated() where t.count >= 4 {
                let chain = t[0], resi = t[1], resn = t[2], cidx = t[3]
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
