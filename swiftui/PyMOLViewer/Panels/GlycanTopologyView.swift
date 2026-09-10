import SwiftUI

struct GlycanForestPayload: Codable {
    let schema: Int
    let roots: [GlycanTreeNode]
    let residueCount: Int
    let componentCount: Int
    let notice: String
}

struct GlycanTreeNode: Codable, Identifiable {
    let id: String
    let object: String
    let segi: String
    let chain: String
    let resi: String
    let resn: String
    let snfg: GlycanSNFGAssessment
    let puckering: GlycanPuckering?
    let linkage: GlycanLinkage?
    let children: [GlycanTreeNode]

    var outlineChildren: [GlycanTreeNode]? { children.isEmpty ? nil : children }
}

struct GlycanSNFGAssessment: Codable {
    let recognized: Bool
    let resn: String
    let symbol: String
    let shape: String
    let color: String
    let confidence: String
    let reason: String
}

struct GlycanPuckering: Codable {
    let Q: Double
    let theta: Double
    let phi: Double
    let conformation: String
    let advisory: Bool
}

struct GlycanLinkage: Codable {
    let donor: String
    let acceptor: String
    let bond: String
    let phi: Double?
    let psi: Double?
    let omega: Double?
    let status: String
    let advisory: Bool
}

struct GlycanTopologyView: View {
    @EnvironmentObject private var engine: PyMOLEngine
    @Environment(\.dismiss) private var dismiss
    @State private var payload: GlycanForestPayload?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Glycan Topology").font(.headline)
                    if let payload {
                        Text("\(payload.residueCount) residues · \(payload.componentCount) components")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button { reload() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh glycan topology")
                Button("Done") { dismiss() }
            }
            .padding()

            Divider()

            if let errorMessage {
                ContentUnavailableView("Unable to Analyze Glycans",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text(errorMessage))
            } else if let payload, payload.roots.isEmpty {
                ContentUnavailableView("No Recognized Glycans",
                                       systemImage: "hexagon",
                                       description: Text("Load a structure containing a supported carbohydrate residue, then refresh."))
            } else if let payload {
                List {
                    OutlineGroup(payload.roots, children: \.outlineChildren) { node in
                        Button { select(node) } label: {
                            GlycanTopologyRow(node: node)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text(payload.notice)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.bottom, 10)
            } else {
                ProgressView("Analyzing covalent topology…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 420)
        #endif
        .onAppear(perform: reload)
    }

    private func reload() {
        errorMessage = nil
        payload = engine.glycanTopology()
        if payload == nil {
            errorMessage = "RayMol could not read the glycan analysis result."
        }
    }

    private func select(_ node: GlycanTreeNode) {
        engine.selectNoteResidue(object: node.object, chain: node.chain, resi: node.resi)
    }
}

private struct GlycanTopologyRow: View {
    let node: GlycanTreeNode

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbolName)
                .foregroundStyle(Color(rayMolHex: node.snfg.color))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(node.snfg.symbol)  \(node.resn) \(node.resi)")
                    .font(.body.weight(.medium))
                HStack(spacing: 8) {
                    if !node.chain.isEmpty { Text("Chain \(node.chain)") }
                    if let linkage = node.linkage { Text(linkage.bond) }
                    if let puckering = node.puckering { Text(puckering.conformation) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "scope")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .accessibilityLabel("Select \(node.snfg.symbol) residue \(node.resi)")
    }

    private var symbolName: String {
        switch node.snfg.shape {
        case "cube": return "square.fill"
        case "sphere": return "circle.fill"
        case "diamond": return "diamond.fill"
        case "cone": return "triangle.fill"
        default: return "questionmark.circle"
        }
    }
}

private extension Color {
    init(rayMolHex value: String) {
        let cleaned = value.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        let number = UInt64(cleaned, radix: 16) ?? 0x8E8E93
        self.init(.sRGB,
                  red: Double((number >> 16) & 0xFF) / 255.0,
                  green: Double((number >> 8) & 0xFF) / 255.0,
                  blue: Double(number & 0xFF) / 255.0,
                  opacity: 1.0)
    }
}
