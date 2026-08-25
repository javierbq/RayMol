#if os(macOS)
import Foundation
import SwiftUI

/// Form state for the Design Backbone bar (#342). The peer of ``PredictController``.
///
/// Thin on purpose: it composes a `design_backbone` command and hands it to the engine.
/// Every refusal, every ceiling and every message lives in `pymol.designing` and
/// `pymol.generators`, where they are testable — a control here that second-guessed them
/// would be a second copy of a rule, and the two would drift.
///
/// The resolved target comes back the same way Predict's chains do: `appkit_design.emit`
/// writes a tempfile and prints `DESIGN_FORM:ready`, which `PyMOLEngine` routes into
/// ``loadFormPayload(_:)``. That round trip is what lets the bar say "40 residues, chain A,
/// 3 hotspots" — or name the problem — BEFORE a run that takes minutes.
@MainActor
final class DesignBackboneController: ObservableObject {

    // MARK: Form

    /// The structure to design against. Empty until ``prepare(defaultTarget:)`` seeds it
    /// with a loaded object.
    ///
    /// NOT prefilled with `sele`, which was the first thing tried and is wrong: `sele` is
    /// the interface residues, so target and hotspots both defaulting to it made the target
    /// BE the hotspots — the bar opened reading "chain A · 3 res · 3 hotspots" against a
    /// 40-residue structure. The workflow is: pick the interface in the viewport, and the
    /// target is the thing it is part of.
    @Published var targetText = ""
    /// `sele` IS right here: it is what the viewport writes and what Design mode's residue
    /// picking writes, so clicking residues then opening the bar needs no retyping.
    @Published var hotspotsText = "sele"
    @Published var generator = ""
    @Published var length = 60
    @Published var nDesigns = 1
    @Published var seedText = ""        // empty → omit (fresh per run)
    @Published var diffusionSteps = 200
    @Published var recyclingSteps = 2
    @Published var resultName = ""

    // MARK: Resolved state, from the Python round trip

    @Published var availableGenerators: [DesignGeneratorInfo] = []
    @Published var target: DesignTargetInfo?
    @Published var resolveError: String?

    /// Set by `run()` and cleared on the next resolve. The bar shows it in the status row
    /// so a refused Generate says why in the bar rather than only in the console.
    @Published var runError: String?

    // MARK: Seams (injected by PyMOLEngine, so this type is testable without one)

    /// Runs a PyMOL COMMAND. Deliberately the command channel rather than runPython: it
    /// lands in the console history like anything typed there, which is what lets a user
    /// adapt and re-run it.
    var runCommandSeam: ((String) -> Void)?
    /// Triggers the tempfile-JSON feed for (target, hotspots, generator).
    var refreshTrigger: ((String, String, String) -> Void)?

    // MARK: Entering the mode / input changes

    /// Seed the target with a loaded object, if the user has not named one.
    ///
    /// Only when empty, so re-entering the mode never clobbers what someone typed. The
    /// caller supplies the name because the controller deliberately knows nothing about
    /// the session — the same reason every other seam here is injected.
    func prepare(defaultTarget: String) {
        if targetText.isEmpty { targetText = defaultTarget }
    }

    /// Load generators and re-resolve whatever is in the fields.
    func refresh() {
        resolveError = nil
        runError = nil
        target = nil
        emit()
    }

    /// Re-resolve after an edit. Called by the bar on a field change.
    func inputChanged() {
        runError = nil
        emit()
    }

    private func emit() {
        refreshTrigger?(targetText, hotspotsText, generator)
    }

    /// Apply a decoded `pymol_design_<pid>.json` payload.
    func loadFormPayload(_ payload: DesignFormPayload) {
        availableGenerators = payload.generators
        if generator.isEmpty || !payload.generators.contains(where: { $0.id == generator }) {
            generator = payload.generators.first?.id ?? ""
        }
        target = payload.target
        resolveError = payload.error
    }

    /// Cleared when the mode closes, so re-entering does not show a stale resolve.
    func cancel() {
        target = nil
        resolveError = nil
        runError = nil
    }

    // MARK: Run

    var canRun: Bool {
        !generator.isEmpty && !targetText.isEmpty && !hotspotsText.isEmpty
            && resolveError == nil && target != nil
    }

    func run() {
        guard canRun else {
            runError = resolveError
                ?? "Pick a target and the interface residues to design against."
            return
        }
        runCommandSeam?(command)
    }

    /// The `design_backbone` command line for the current form.
    ///
    /// Pure and internal so the quoting is unit-testable without a view. Quoting matters:
    /// PyMOL's parser splits arguments on COMMAS, so a selection with spaces is one
    /// argument and needs no quotes, while a comma inside one cannot be passed at all.
    /// Commas are stripped rather than escaped, because there is no escape for them at
    /// this layer — and silently sending half a selection would design against the wrong
    /// structure.
    var command: String {
        var parts = ["design_backbone \(generator)",
                     Self.sanitise(targetText),
                     Self.sanitise(hotspotsText),
                     "length=\(length)"]
        if nDesigns != 1 { parts.append("n_designs=\(nDesigns)") }
        if diffusionSteps != 200 { parts.append("diffusion_steps=\(diffusionSteps)") }
        if recyclingSteps != 2 { parts.append("recycling_steps=\(recyclingSteps)") }
        if let seed = Int(seedText.trimmingCharacters(in: .whitespaces)) {
            parts.append("seed=\(seed)")
        }
        let name = Self.sanitise(resultName)
        if !name.isEmpty { parts.append("name=\(name)") }
        return parts.joined(separator: ", ")
    }

    /// A selection safe to put in one comma-separated argument slot.
    static func sanitise(_ text: String) -> String {
        text.replacingOccurrences(of: ",", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A Python single-quoted string literal, for the emit trigger.
    static func pythonLiteral(_ value: String) -> String {
        "'" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "") + "'"
    }
}

/// One generator the host can actually run.
struct DesignGeneratorInfo: Decodable, Identifiable, Equatable {
    let id: String
}

/// The target as `designing.resolve_target` read it.
struct DesignTargetInfo: Decodable, Equatable {
    let residues: Int
    let chain: String
    let state: Int
    let hotspots: Int
}

struct DesignFormPayload: Decodable {
    let generators: [DesignGeneratorInfo]
    let target: DesignTargetInfo?
    let error: String?
}
#endif
