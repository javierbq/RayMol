// MutagenesisWizardContract.swift — platform-neutral state/action contract for
// the native Mutagenesis wizard prototype.
//
// This milestone deliberately contains no PyMOL bridge calls. A later milestone
// can adapt live wizard data to this contract after the presentation and
// interaction model have maintainer approval.

import Foundation
import Combine

struct MutagenesisResidueMode: Identifiable, Equatable {
    let id: String
    let label: String
}

struct MutagenesisResidue: Equatable {
    let objectName: String
    let chain: String
    let name: String
    let number: String

    var displayName: String {
        let chainPrefix = chain.isEmpty ? "" : "\(chain)/"
        return "\(name) \(chainPrefix)\(number)"
    }
}

struct MutagenesisRotamer: Identifiable, Equatable {
    let id: String
    let name: String
    let probability: Double
    let clashScore: Double
}

/// Lifecycle states exposed by a future PyMOL adapter.
///
/// `awaitingResidue` is an active wizard with no picked residue. `loading`
/// separates an asynchronous refresh from a populated result, while `failed`
/// keeps recovery controls available without inventing live command behavior.
enum MutagenesisWizardPhase: Equatable {
    case inactive
    case awaitingResidue
    case loading(residue: MutagenesisResidue)
    case ready(residue: MutagenesisResidue, rotamers: [MutagenesisRotamer])
    case failed(message: String)
}

enum MutagenesisWizardAction: Equatable {
    case selectMode(String)
    case selectRotamer(String)
    case apply
    case clear
    case done
}

struct MutagenesisWizardCommandAvailability: Equatable {
    let canSelectMode: Bool
    let canSelectRotamer: Bool
    let canApply: Bool
    let canClear: Bool
    let canDone: Bool
}

/// Presentation policy shared by every Apple platform. A phone-sized or narrow
/// split-view surface stacks the controls; wider inspectors use two columns.
enum MutagenesisWizardLayoutClass: Equatable {
    case compact
    case regular

    static func resolve(availableWidth: Double) -> Self {
        availableWidth < 560 ? .compact : .regular
    }
}

struct MutagenesisWizardState: Equatable {
    var phase: MutagenesisWizardPhase
    var residueModes: [MutagenesisResidueMode]
    var selectedModeID: String?
    var selectedRotamerID: String?

    var isActive: Bool {
        if case .inactive = phase { return false }
        return true
    }

    var residue: MutagenesisResidue? {
        switch phase {
        case .loading(let residue), .ready(let residue, _): return residue
        case .inactive, .awaitingResidue, .failed: return nil
        }
    }

    var rotamers: [MutagenesisRotamer] {
        if case .ready(_, let rotamers) = phase { return rotamers }
        return []
    }

    var errorMessage: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }

    var commandAvailability: MutagenesisWizardCommandAvailability {
        let ready: Bool
        if case .ready = phase { ready = true } else { ready = false }
        let hasValidRotamer = rotamers.contains { $0.id == selectedRotamerID }
        return MutagenesisWizardCommandAvailability(
            canSelectMode: isActive && !isLoading,
            canSelectRotamer: ready && !rotamers.isEmpty,
            canApply: ready && hasValidRotamer,
            canClear: isActive,
            canDone: isActive
        )
    }

    private var isLoading: Bool {
        if case .loading = phase { return true }
        return false
    }

    /// Applies only prototype-local selection/lifecycle changes. The action is
    /// still forwarded to the injected sink, but no structural mutation or
    /// PyMOL command is performed in this milestone.
    mutating func applyPrototypeAction(_ action: MutagenesisWizardAction) {
        switch action {
        case .selectMode(let id):
            guard commandAvailability.canSelectMode,
                  residueModes.contains(where: { $0.id == id }) else { return }
            selectedModeID = id
            selectedRotamerID = nil
        case .selectRotamer(let id):
            guard commandAvailability.canSelectRotamer,
                  rotamers.contains(where: { $0.id == id }) else { return }
            selectedRotamerID = id
        case .apply:
            break
        case .clear:
            guard commandAvailability.canClear else { return }
            phase = .awaitingResidue
            selectedRotamerID = nil
        case .done:
            guard commandAvailability.canDone else { return }
            phase = .inactive
            selectedRotamerID = nil
        }
    }
}

final class MutagenesisWizardPrototypeController: ObservableObject {
    @Published private(set) var state: MutagenesisWizardState
    private let actionSink: (MutagenesisWizardAction) -> Void

    init(
        state: MutagenesisWizardState,
        actionSink: @escaping (MutagenesisWizardAction) -> Void = { _ in }
    ) {
        self.state = state
        self.actionSink = actionSink
    }

    func send(_ action: MutagenesisWizardAction) {
        let before = state
        state.applyPrototypeAction(action)

        // Invalid or unavailable selections are not forwarded as commands.
        if case .selectMode = action, state == before { return }
        if case .selectRotamer = action, state == before { return }
        if action == .apply && !before.commandAvailability.canApply { return }
        if action == .clear && !before.commandAvailability.canClear { return }
        if action == .done && !before.commandAvailability.canDone { return }
        actionSink(action)
    }
}

extension MutagenesisWizardState {
    /// Mock data used only by the SwiftUI prototype and Xcode previews.
    static let prototype = MutagenesisWizardState(
        phase: .ready(
            residue: MutagenesisResidue(
                objectName: "6f8p",
                chain: "A",
                name: "ARG",
                number: "159"
            ),
            rotamers: [
                MutagenesisRotamer(id: "rotamer-1", name: "Rotamer 1", probability: 0.42, clashScore: 0.8),
                MutagenesisRotamer(id: "rotamer-2", name: "Rotamer 2", probability: 0.31, clashScore: 1.4),
                MutagenesisRotamer(id: "rotamer-3", name: "Rotamer 3", probability: 0.17, clashScore: 2.1)
            ]
        ),
        residueModes: [
            MutagenesisResidueMode(id: "current", label: "No mutation"),
            MutagenesisResidueMode(id: "ALA", label: "Alanine (ALA)"),
            MutagenesisResidueMode(id: "GLY", label: "Glycine (GLY)"),
            MutagenesisResidueMode(id: "LYS", label: "Lysine (LYS)")
        ],
        selectedModeID: "ALA",
        selectedRotamerID: "rotamer-1"
    )
}
