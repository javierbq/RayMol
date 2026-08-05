// MutagenesisWizardPrototype.swift — non-destructive, mock-backed interaction
// prototype for issue #136. This view is intentionally not wired into
// ContentView until maintainers approve its presentation location.

import SwiftUI

struct MutagenesisWizardPrototype: View {
    @ObservedObject var controller: MutagenesisWizardPrototypeController

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if controller.state.isActive {
                GeometryReader { proxy in
                    ScrollView {
                        // Compact width stacks the mode and rotamers for a phone-sized
                        // surface. Regular width keeps mode/status in a fixed leading
                        // column and gives the rotamer list the remaining space.
                        if MutagenesisWizardLayoutClass.resolve(
                            availableWidth: Double(proxy.size.width)
                        ) == .compact {
                            VStack(alignment: .leading, spacing: 18) {
                                modeSection
                                detailSection
                            }
                            .padding(16)
                        } else {
                            HStack(alignment: .top, spacing: 24) {
                                modeSection.frame(width: 220, alignment: .topLeading)
                                Divider()
                                detailSection.frame(maxWidth: .infinity, alignment: .topLeading)
                            }
                            .padding(20)
                        }
                    }
                }
                Divider()
                actionBar
            } else {
                inactiveContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.gray.opacity(0.06))
        .accessibilityIdentifier("mutagenesis-wizard-prototype")
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "wand.and.stars")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Mutagenesis")
                    .font(.headline)
                Text("Select a residue mode and preview a rotamer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionLabel("Residue mode")
            Picker("Residue mode", selection: selectedModeBinding) {
                ForEach(controller.state.residueModes) { mode in
                    Text(mode.label).tag(mode.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(!controller.state.commandAvailability.canSelectMode)
            .accessibilityIdentifier("mutagenesis-residue-mode")

            if let residue = controller.state.residue {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Selected residue")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(residue.displayName)
                        .font(.body.weight(.semibold))
                    Text(residue.objectName)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var detailSection: some View {
        switch controller.state.phase {
        case .inactive:
            EmptyView()
        case .awaitingResidue:
            statusCard(
                title: "Pick a residue",
                message: "Select a residue in the molecular viewport to load its rotamers.",
                systemImage: "scope"
            )
        case .loading(let residue):
            HStack(spacing: 12) {
                ProgressView()
                VStack(alignment: .leading, spacing: 3) {
                    Text("Loading rotamers…").font(.body.weight(.semibold))
                    Text(residue.displayName).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.1)))
        case .ready(_, let rotamers):
            VStack(alignment: .leading, spacing: 10) {
                sectionLabel("Rotamers")
                if rotamers.isEmpty {
                    statusCard(
                        title: "No rotamers available",
                        message: "Choose another residue mode or clear the residue selection.",
                        systemImage: "exclamationmark.circle"
                    )
                } else {
                    ForEach(rotamers) { rotamer in
                        rotamerRow(rotamer)
                    }
                }
            }
        case .failed(let message):
            statusCard(
                title: "Unable to load rotamers",
                message: message,
                systemImage: "exclamationmark.triangle"
            )
        }
    }

    private func rotamerRow(_ rotamer: MutagenesisRotamer) -> some View {
        let selected = controller.state.selectedRotamerID == rotamer.id
        return Button {
            controller.send(.selectRotamer(rotamer.id))
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(rotamer.name).font(.body.weight(.medium))
                    Text("\(rotamer.probability, format: .percent.precision(.fractionLength(0))) probability")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("Clash \(rotamer.clashScore, format: .number.precision(.fractionLength(1)))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(selected ? Color.accentColor.opacity(0.12) : Color.gray.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
        .disabled(!controller.state.commandAvailability.canSelectRotamer)
        .accessibilityIdentifier("mutagenesis-\(rotamer.id)")
    }

    private var actionBar: some View {
        let availability = controller.state.commandAvailability
        return HStack(spacing: 10) {
            Button("Clear") { controller.send(.clear) }
                .disabled(!availability.canClear)
                .accessibilityIdentifier("mutagenesis-clear")
            Button("Done") { controller.send(.done) }
                .disabled(!availability.canDone)
                .accessibilityIdentifier("mutagenesis-done")
            Spacer()
            Button("Apply") { controller.send(.apply) }
                .buttonStyle(.borderedProminent)
                .disabled(!availability.canApply)
                .accessibilityIdentifier("mutagenesis-apply")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var inactiveContent: some View {
        statusCard(
            title: "No active Mutagenesis wizard",
            message: "Start Mutagenesis to display residue modes, rotamers, and actions here.",
            systemImage: "wand.and.stars.inverse"
        )
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var selectedModeBinding: Binding<String> {
        Binding(
            get: { controller.state.selectedModeID ?? "" },
            set: { controller.send(.selectMode($0)) }
        )
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func statusCard(title: String, message: String, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.semibold))
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.1)))
    }
}

#Preview("Compact") {
    MutagenesisWizardPrototype(
        controller: MutagenesisWizardPrototypeController(state: .prototype)
    )
    .frame(width: 360, height: 620)
}

#Preview("Regular") {
    MutagenesisWizardPrototype(
        controller: MutagenesisWizardPrototypeController(state: .prototype)
    )
    .frame(width: 720, height: 440)
}
