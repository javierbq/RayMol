// SequencePanel.swift — Horizontal scrollable sequence viewer
// Replaces modules/pymol/appkit_sequence_panel.py with a SwiftUI implementation.
//
// Displays one-letter amino acid codes in a horizontal bar, color-coded by
// chain. Tapping a residue selects it in PyMOL. Visibility is driven by
// engine.sequenceVisible.

import SwiftUI

// MARK: - Data Models

/// A single residue in the sequence display.
struct SequenceResidue: Identifiable, Equatable {
    let id: String          // unique key: "obj/chain/resi"
    let objectName: String
    let chain: String
    let oneLetter: String
    let resi: String        // residue index (e.g. "42")
    let resn: String        // three-letter code (e.g. "ALA")
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
    // Common modified residues
    "MSE": "M", "HSD": "H", "HSE": "H", "HSP": "H",
    // Nucleic acids
    "DA": "A", "DC": "C", "DG": "G", "DT": "T",
    "A": "A", "C": "C", "G": "G", "U": "U",
]

// MARK: - Chain Colors

/// Colors cycled per chain, matching the AppKit version.
private let chainColors: [Color] = [
    Color(red: 0.3, green: 1.0, blue: 0.3),   // green
    Color(red: 0.3, green: 0.8, blue: 1.0),   // cyan
    Color(red: 1.0, green: 1.0, blue: 0.3),   // yellow
    Color(red: 1.0, green: 0.5, blue: 0.3),   // orange
    Color(red: 1.0, green: 0.3, blue: 1.0),   // magenta
    Color(red: 0.85, green: 0.85, blue: 0.85), // white
]

private let headerColor = Color(red: 0.55, green: 0.75, blue: 1.0)
private let separatorColor = Color(red: 0.4, green: 0.4, blue: 0.4)
private let panelBackground = Color(red: 0.165, green: 0.165, blue: 0.172) // #2A2A2C

/// Returns a deterministic color for a chain ID by cycling through chainColors.
private func colorForChain(_ chain: String, in colorMap: [String: Color]) -> Color {
    colorMap[chain] ?? chainColors[0]
}

// MARK: - Placeholder Data

/// Placeholder sequence data for development. Will be replaced by polling
/// PyMOL's sequence state via the engine.
private func placeholderSequences() -> [SequenceObject] {
    let chainsA = "MVLSPADKTNVKAAWGKVGAHAGEYGAEALERMFLSFPTTKTYFPHFDLSH"
    let chainsB = "VHLTPEEKSAVTALWGKVNVDEVGGEALGRLLVVYPWTQRFFESFGDLSTPDAVMGNPKVKAHGKKVL"

    var residuesA: [SequenceResidue] = []
    for (i, ch) in chainsA.enumerated() {
        let resi = "\(i + 1)"
        residuesA.append(SequenceResidue(
            id: "1HBB/A/\(resi)",
            objectName: "1HBB",
            chain: "A",
            oneLetter: String(ch),
            resi: resi,
            resn: ""
        ))
    }

    var residuesB: [SequenceResidue] = []
    for (i, ch) in chainsB.enumerated() {
        let resi = "\(i + 1)"
        residuesB.append(SequenceResidue(
            id: "1HBB/B/\(resi)",
            objectName: "1HBB",
            chain: "B",
            oneLetter: String(ch),
            resi: resi,
            resn: ""
        ))
    }

    return [
        SequenceObject(
            id: "1HBB",
            name: "1HBB",
            residues: residuesA + residuesB
        )
    ]
}

// MARK: - SequencePanel View

struct SequencePanel: View {
    @EnvironmentObject var engine: PyMOLEngine
    @State private var selectedResidueIDs: Set<String> = []

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: 0) {
                if engine.sequences.isEmpty {
                    Text("No sequence — load a structure")
                        .font(.system(size: 10))
                        .foregroundColor(separatorColor)
                        .padding(.horizontal, 8)
                } else {
                    ForEach(engine.sequences) { seqObj in
                        objectSequenceView(seqObj)
                    }
                }
            }
            .padding(.horizontal, 4)
        }
        .frame(maxWidth: .infinity)
        .background(panelBackground)
        .onAppear { engine.fetchSequences() }
        .onChange(of: engine.objects) { _ in engine.fetchSequences() }
    }

    // MARK: - Per-object sequence row

    @ViewBuilder
    private func objectSequenceView(_ seqObj: SequenceObject) -> some View {
        // Object name label
        Text(seqObj.name + ":")
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(headerColor)
            .padding(.trailing, 2)

        // Build a chain color map for this object
        let colorMap = buildChainColorMap(seqObj.residues)

        // Residues with chain separators
        let residues = seqObj.residues
        ForEach(Array(residues.enumerated()), id: \.element.id) { index, residue in
            // Chain separator when chain changes
            if index > 0 && residues[index].chain != residues[index - 1].chain {
                chainSeparator(label: residue.chain)
            }

            residueButton(residue, color: colorMap[residue.chain] ?? chainColors[0])
        }

        // Gap between objects
        Spacer()
            .frame(width: 16)
    }

    // MARK: - Chain separator

    private func chainSeparator(label: String) -> some View {
        HStack(spacing: 1) {
            Text("|")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(separatorColor)
            Text(label)
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(headerColor)
        }
        .padding(.horizontal, 2)
    }

    // MARK: - Residue button

    private func residueButton(_ residue: SequenceResidue, color: Color) -> some View {
        let isSelected = selectedResidueIDs.contains(residue.id)

        return Text(residue.oneLetter)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(isSelected ? .white : color)
            .frame(width: 10, alignment: .center)
            .padding(.vertical, 2)
            .background(
                isSelected
                    ? RoundedRectangle(cornerRadius: 2).fill(Color.accentColor)
                    : RoundedRectangle(cornerRadius: 2).fill(Color.clear)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                selectResidue(residue)
            }
            .help(residueTooltip(residue))
    }

    // MARK: - Selection

    private func selectResidue(_ residue: SequenceResidue) {
        // Toggle selection state
        if selectedResidueIDs.contains(residue.id) {
            selectedResidueIDs.remove(residue.id)
        } else {
            selectedResidueIDs = [residue.id]
        }

        // Build PyMOL selection expression: /obj/chain/resn`resi
        var sel = "/\(residue.objectName)"
        if !residue.chain.isEmpty {
            sel += "/\(residue.chain)"
        } else {
            sel += "/"
        }
        // resn`resi format
        if !residue.resn.isEmpty {
            sel += "/\(residue.resn)`\(residue.resi)"
        } else {
            sel += "/`\(residue.resi)"
        }

        engine.runCommand("select sele, \(sel)")
    }

    // MARK: - Helpers

    private func buildChainColorMap(_ residues: [SequenceResidue]) -> [String: Color] {
        var map: [String: Color] = [:]
        var idx = 0
        for r in residues {
            if map[r.chain] == nil {
                map[r.chain] = chainColors[idx % chainColors.count]
                idx += 1
            }
        }
        return map
    }

    private func residueTooltip(_ residue: SequenceResidue) -> String {
        var tip = residue.resn.isEmpty ? residue.oneLetter : residue.resn
        if !residue.resi.isEmpty {
            tip += " \(residue.resi)"
        }
        if !residue.chain.isEmpty {
            tip += " (chain \(residue.chain))"
        }
        return tip
    }
}

// MARK: - PyMOLEngine extension for sequence polling

extension PyMOLEngine {
    /// Parse the SEQPANEL JSON emitted by fetchSequences() into `sequences`.
    /// Payload: [{ "name": <obj>, "residues": [[chain, resi, resn], ...] }]
    func parseSequencePanelFeedback(_ line: String) {
        guard line.hasPrefix("SEQPANEL:") else { return }
        // fetchSequences() wrote the JSON to TMPDIR/pymol_seq.json (same process
        // temp dir) and printed "SEQPANEL:ready"; read it here.
        let path = NSTemporaryDirectory() + "pymol_seq.json"
        guard let data = FileManager.default.contents(atPath: path) else { return }

        struct SeqObjPayload: Decodable {
            let name: String
            let residues: [[String]]
        }

        guard let payload = try? JSONDecoder().decode([SeqObjPayload].self, from: data) else {
            return
        }

        var objs: [SequenceObject] = []
        for o in payload {
            var residues: [SequenceResidue] = []
            for (i, t) in o.residues.enumerated() where t.count >= 3 {
                let chain = t[0], resi = t[1], resn = t[2]
                let one = aa3to1[resn.uppercased()] ?? "X"
                residues.append(SequenceResidue(
                    id: "\(o.name)/\(chain)/\(resi)/\(i)",
                    objectName: o.name,
                    chain: chain,
                    oneLetter: one,
                    resi: resi,
                    resn: resn
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
}

// MARK: - Preview

#if DEBUG
struct SequencePanel_Previews: PreviewProvider {
    static var previews: some View {
        SequencePanel()
            .environmentObject(PyMOLEngine.shared)
            .frame(width: 800, height: 40)
            .previewLayout(.sizeThatFits)
    }
}
#endif
