#if os(macOS)
import Foundation
import SwiftUI

/// Form state for the Binder Design bar (#342). The peer of ``PredictController``.
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
    ///
    /// OPTIONAL. Empty -- or `sele` with nothing picked, which is the state the bar opens
    /// in -- runs UNGUIDED: the sampler origin falls back to the target's centre of mass.
    /// The bar says so in its status row rather than refusing, because the Python side
    /// no longer refuses either.
    @Published var hotspotsText = "sele"
    @Published var generator = ""
    @Published var length = 60
    @Published var nDesigns = 1
    @Published var seedText = ""        // empty → omit (fresh per run)
    @Published var diffusionSteps = 200
    @Published var recyclingSteps = 2
    @Published var resultName = ""

    /// Build the result object live, one state per captured frame, instead of only at the
    /// end.
    ///
    /// The same single object either way -- there is no second object, and the finished
    /// design is its last state. Persisted and OFF by default: it costs a little
    /// main-thread work per frame, which is a reasonable thing to opt into and an
    /// unreasonable thing to be given. It does NOT by itself change what the finished
    /// object is -- that is `keepFrames`, which turns a one-state result into a ~51-state
    /// one.
    @Published var liveView = UserDefaults.standard.bool(forKey: DesignBackboneController.liveViewKey) {
        didSet { UserDefaults.standard.set(liveView, forKey: Self.liveViewKey) }
    }

    static let liveViewKey = "designBackboneLiveView"

    /// Keep the live view's captured frames as states, instead of discarding them.
    ///
    /// Only meaningful with Live on, and the bar disables the checkbox otherwise. The
    /// VALUE is remembered across that, deliberately: switching Live off for a moment and
    /// back on should not silently forget a preference the user set, and a greyed control
    /// that keeps its tick is the ordinary macOS reading of "not applicable right now"
    /// rather than "reset". `run()` only emits the argument when Live is actually on, so
    /// a remembered tick can never compose the contradiction Python refuses.
    @Published var keepFrames = UserDefaults.standard.bool(forKey: DesignBackboneController.keepFramesKey) {
        didSet { UserDefaults.standard.set(keepFrames, forKey: Self.keepFramesKey) }
    }

    static let keepFramesKey = "designBackboneKeepFrames"

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

    /// Hotspots are NOT required: an empty field is a legitimate unguided run, so
    /// requiring one here would refuse in the UI what Python accepts.
    var canRun: Bool {
        !generator.isEmpty && !targetText.isEmpty
            && resolveError == nil && target != nil
    }

    func run() {
        guard canRun else {
            runError = resolveError ?? "Pick a target structure to design against."
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
        var parts = ["design_backbone \(generator)", Self.sanitise(targetText)]
        // OMITTED rather than passed as an empty slot. `design_backbone rfd3, t, ,
        // length=60` would put an empty positional between two commas, and PyMOL's
        // parser has no spelling for "skip this one" -- so an unguided run leaves the
        // argument out entirely and takes the Python default.
        let hotspots = Self.sanitise(hotspotsText)
        if !hotspots.isEmpty { parts.append(hotspots) }
        parts.append("length=\(length)")
        if nDesigns != 1 { parts.append("n_designs=\(nDesigns)") }
        if diffusionSteps != 200 { parts.append("diffusion_steps=\(diffusionSteps)") }
        if recyclingSteps != 2 { parts.append("recycling_steps=\(recyclingSteps)") }
        if liveView {
            parts.append("live_view=1")
            // Only with Live on: `keep_frames=1, live_view=0` is a contradiction Python
            // refuses, and a remembered tick must not be able to compose one.
            if keepFrames { parts.append("keep_frames=1") }
        }
        if let seed = Int(seedText.trimmingCharacters(in: .whitespaces)) {
            parts.append("seed=\(seed)")
        }
        let name = Self.sanitise(resultName)
        if !name.isEmpty { parts.append("name=\(name)") }
        return parts.joined(separator: ", ")
    }

    /// What a typed number in a stepper-backed field commits to.
    ///
    /// Pure and static so the bar's text boxes and their tests share ONE rule, and so the
    /// rule is testable without a view. The four cases the boxes actually see:
    ///
    /// * a whole number in range -> itself.
    /// * out of range -> CLAMPED to the nearest bound, not refused. The stepper on the
    ///   same control cannot leave `range`, so the text box must not be able to compose a
    ///   command the bar could not otherwise compose -- and the caller writes the clamped
    ///   value straight back into the box, so what is displayed is always what will run.
    /// * empty, or not a whole number ("", "abc", "4.5", "42x") -> the FALLBACK, which the
    ///   caller passes as the current value. Reverting is the only non-destructive answer:
    ///   there is no number to honour, and substituting a bound would silently change a
    ///   setting the user did not touch.
    ///
    /// `range` is the stepper's own, so this adds no second copy of a limit; the real
    /// ceilings live in `pymol.generators.rfd3` and refuse at the command.
    /// `nonisolated` because it is pure: no state, no view, nothing to serialise. The
    /// enclosing type is `@MainActor`, which would otherwise isolate this too and make it
    /// unreachable from a plain test method.
    nonisolated static func committed(_ text: String, into range: ClosedRange<Int>,
                                      fallback: Int) -> Int {
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)) else {
            return fallback
        }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// A selection safe to put in one comma-separated argument slot.
    static func sanitise(_ text: String) -> String {
        text.replacingOccurrences(of: ",", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
