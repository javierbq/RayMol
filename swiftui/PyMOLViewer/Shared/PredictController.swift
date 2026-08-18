#if os(macOS)
import Foundation

// MARK: - Wire types (decoded from pymol_predict_<pid>.json; see appkit_predict.emit)

struct PredictorInfo: Codable, Equatable, Identifiable {
    let id: String
    let msa: Bool          // supports_msa: the method can genuinely use an alignment
}

struct PredictChain: Codable, Equatable, Identifiable {
    let id: String         // spec chain id assigned in order: A, B, C, ...
    let length: Int
    let object: String     // source object, "" for a literal sequence
    let chain: String      // source chain id, "" for a literal sequence
    var isFromObject: Bool { !object.isEmpty }
}

struct PredictFormPayload: Codable, Equatable {
    let predictors: [PredictorInfo]
    let chains: [PredictChain]
    let error: String?
}

enum PredictPhase: Equatable {
    case idle
    case searching(remaining: Int)
    case predicting
    case error(String)
}

struct PredictSizeWarning: Equatable {
    let estimatedBytes: Int
    let availableBytes: Int
}

// MARK: - Pure command composition (unit-tested without an engine)

extension PredictController {

    /// A Python single-quoted string literal. Matches BoltzJobManager.pythonLiteral.
    nonisolated static func pythonLiteral(_ value: String) -> String {
        "'" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "") + "'"
    }

    /// `from pymol import cmd as _c\n_c.predict(...)`. Optional args are omitted when
    /// nil so predict applies its own defaults (notably: no seed → a fresh seed per
    /// run). `msa` is passed only on the literal-sequence path; object inputs let
    /// predict pick up attached alignments.
    nonisolated static func predictPython(predictor: String, input: String, nModels: Int,
                              recyclingSteps: Int, diffusionSteps: Int,
                              seed: Int?, msaDepth: Int?, name: String?,
                              msa: String?) -> String {
        var args = ["\(pythonLiteral(predictor)), \(pythonLiteral(input))"]
        args.append("n_models=\(nModels)")
        args.append("recycling_steps=\(recyclingSteps)")
        args.append("diffusion_steps=\(diffusionSteps)")
        if let seed { args.append("seed=\(seed)") }
        if let msaDepth { args.append("msa_depth=\(msaDepth)") }
        if let name, !name.isEmpty { args.append("name=\(pythonLiteral(name))") }
        if let msa, !msa.isEmpty { args.append("msa=\(pythonLiteral(msa))") }
        return "from pymol import cmd as _c\n_c.predict(\(args.joined(separator: ", ")))"
    }

    /// `_c.msa_search(...)`. `target`/`chain` are passed only when non-empty (the
    /// object path); a literal sequence lands the alignment unattached under `name`.
    nonisolated static func msaSearchPython(sequence: String, name: String, target: String,
                                chain: String, mode: String, server: String) -> String {
        var args = ["\(pythonLiteral(sequence))"]
        args.append("name=\(pythonLiteral(name))")
        if !target.isEmpty { args.append("target=\(pythonLiteral(target))") }
        if !chain.isEmpty { args.append("chain=\(pythonLiteral(chain))") }
        args.append("mode=\(pythonLiteral(mode))")
        if !server.isEmpty { args.append("server=\(pythonLiteral(server))") }
        return "from pymol import cmd as _c\n_c.msa_search(\(args.joined(separator: ", ")))"
    }

    /// Per-chain sequences of a literal input: split on '/', strip whitespace,
    /// upper-case — exactly what parse_chains does on the Python side.
    nonisolated static func literalChainSequences(_ input: String) -> [String] {
        input.split(separator: "/").map {
            $0.replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "\t", with: "")
                .uppercased()
        }
    }

    /// `msa=` slots: one '/'-joined entry per chain in order, the alignment name for
    /// a requested chain and empty otherwise (empty folds that chain single-sequence).
    nonisolated static func msaSlots(orderedChains: [PredictChain], requested: Set<String>,
                         nameFor: (PredictChain) -> String) -> String {
        orderedChains.map { requested.contains($0.id) ? nameFor($0) : "" }
            .joined(separator: "/")
    }

    /// A deterministic, collision-resistant alignment name for a requested chain, so
    /// the running search and the landed alignment share a name the state machine can
    /// match on. Object path keys on (object, source chain); literal path on an FNV
    /// hash of the chain's sequence so a re-run reuses the cached alignment.
    nonisolated static func alignmentBaseName(for chain: PredictChain,
                                  literalSequence: String?) -> String {
        if chain.isFromObject {
            let obj = sanitize(chain.object)
            let ch = chain.chain.isEmpty ? "x" : sanitize(chain.chain)
            return "predui_\(obj)_\(ch)"
        }
        let seq = literalSequence ?? ""
        return "predui_\(fnvHex(seq))_\(chain.id)"
    }

    nonisolated static func sanitize(_ s: String) -> String {
        String(s.map { $0.isLetter || $0.isNumber ? $0 : "_" })
    }

    /// FNV-1a 32-bit, hex. A fixed hash (not Swift's randomized Hasher) so the name is
    /// stable across launches and a re-run hits msa_search's on-disk cache.
    nonisolated static func fnvHex(_ s: String) -> String {
        var h: UInt32 = 0x811c9dc5
        for b in s.utf8 { h = (h ^ UInt32(b)) &* 0x0100_0193 }
        return String(format: "%08x", h)
    }
}

import Combine

@MainActor
final class PredictController: ObservableObject {
    // Inputs (bound by PredictBar)
    @Published var inputText = ""
    @Published var predictor = ""
    @Published var useMSA = false
    @Published var msaChains: Set<String> = []
    @Published var nModels = 1
    // Advanced
    @Published var recyclingSteps = 3
    @Published var diffusionSteps = 200
    @Published var seedText = ""        // empty → omit (fresh per run)
    @Published var msaDepthText = ""    // empty → omit (predictor default)
    @Published var msaMode = "env"
    @Published var resultName = ""
    @Published var server = ""

    // Resolved / status (rendered by PredictBar)
    @Published var availablePredictors: [PredictorInfo] = []
    @Published var chains: [PredictChain] = []
    @Published var resolveError: String?
    @Published var phase: PredictPhase = .idle
    @Published var pendingSizeWarning: PredictSizeWarning?

    // Injected seams (default no-ops; PyMOLEngine wires real ones in Task 4).
    var runPythonSeam: (String) -> Void = { _ in }
    var refreshTrigger: (String) -> Void = { _ in }
    var availableBytesProvider: () -> Int = { PredictSizeGuard.availableBytes }

    // Per-run plan: the alignment name expected for each requested spec-chain id.
    private var plannedNames: [String: String] = [:]

    // Fix A: latest snapshot from onEngineState (updated even while idle).
    private var latestAlignments: [AlignmentEntry] = []

    // Fix B: one-tick grace so the just-fired search can register before being declared failed.
    private var failGraceTicks = 0

    // MARK: entering the mode / input changes

    /// Load predictors (input-independent) and clear the form's resolved state.
    func refresh() {
        chains = []
        msaChains = []
        resolveError = nil
        phase = .idle
        pendingSizeWarning = nil
        refreshTrigger("")          // emit('') → predictors only
    }

    /// Re-resolve the current input (called debounced by PredictBar on inputText edits).
    func inputChanged() { refreshTrigger(inputText) }

    /// Apply a decoded pymol_predict_<pid>.json payload.
    func loadFormPayload(_ payload: PredictFormPayload) {
        availablePredictors = payload.predictors
        if predictor.isEmpty || !payload.predictors.contains(where: { $0.id == predictor }) {
            predictor = payload.predictors.first?.id ?? ""
        }
        chains = payload.chains
        resolveError = payload.error
        // Drop any selected MSA chains that no longer exist in the resolved input.
        let ids = Set(payload.chains.map(\.id))
        msaChains = msaChains.intersection(ids)
    }

    // MARK: run

    private var selectedSupportsMSA: Bool {
        availablePredictors.first { $0.id == predictor }?.msa ?? false
    }

    private var tokenCount: Int { chains.reduce(0) { $0 + $1.length } }

    private var effectiveMSADepth: Int {
        if let d = Int(msaDepthText), d > 0 { return d }
        return (useMSA && selectedSupportsMSA && !msaChains.isEmpty)
            ? PredictSizeGuard.maximumMSADepth : 1
    }

    func run() {
        guard !predictor.isEmpty, !chains.isEmpty else {
            phase = .error(resolveError ?? "Nothing to fold — enter a sequence, "
                           + "selection, or object.")
            return
        }
        // Size guard (per predictor). A warn stops for confirmation; a refusal is fatal.
        let decision = predictor.hasPrefix("protenix")
            ? ProtenixSizeGuard.decide(tokens: tokenCount,
                                       availableBytes: availableBytesProvider())
            : PredictSizeGuard.decide(tokens: tokenCount, msaDepth: effectiveMSADepth,
                                      availableBytes: availableBytesProvider())
        switch decision {
        case .ok:
            proceed()
        case let .warn(estimatedBytes, availableBytes):
            pendingSizeWarning = PredictSizeWarning(estimatedBytes: estimatedBytes,
                                                    availableBytes: availableBytes)
        case let .refuse(maxFittingTokens):
            phase = .error("Too large for this machine — at most about "
                           + "\(maxFittingTokens) residues fit.")
        case let .refuseDepth(maxFittingDepth):
            phase = .error("The alignment is too deep for this machine — set "
                           + "msa_depth to at most \(maxFittingDepth).")
        }
    }

    func confirmPendingWarning() { pendingSizeWarning = nil; proceed() }
    func cancelPendingWarning() { pendingSizeWarning = nil; phase = .idle }

    private var useMSAEffective: Bool {
        useMSA && selectedSupportsMSA && !msaChains.isEmpty
    }

    private func proceed() {
        pendingSizeWarning = nil
        guard useMSAEffective else { submitPredict(); return }

        // Plan one alignment name per requested chain; start a search only for chains
        // not already satisfied by the current latestAlignments snapshot (Fix A).
        plannedNames = [:]
        let literalSeqs = PredictController.literalChainSequences(inputText)
        var started = 0
        for ch in chains where msaChains.contains(ch.id) {
            let literal = ch.isFromObject ? nil
                : (indexOf(ch).map { $0 < literalSeqs.count ? literalSeqs[$0] : "" } ?? "")
            let name = PredictController.alignmentBaseName(for: ch, literalSequence: literal)
            plannedNames[ch.id] = name
            // Fix A: skip search if alignment already landed.
            if isSatisfied(ch, alignments: latestAlignments) { continue }
            let sequence = ch.isFromObject
                ? "(\(inputText)) and chain \(ch.chain)"
                : (literal ?? "")
            let cmd = PredictController.msaSearchPython(
                sequence: sequence, name: name,
                target: ch.isFromObject ? ch.object : "",
                chain: ch.isFromObject ? ch.chain : "",
                mode: msaMode, server: server)
            runPythonSeam(cmd)
            started += 1
        }
        // Fix A: if all chains were already satisfied, predict immediately.
        if started == 0 { submitPredict(); return }
        // Fix B: arm the one-tick grace so the just-fired searches can register.
        failGraceTicks = 1
        phase = .searching(remaining: started)
    }

    private func indexOf(_ ch: PredictChain) -> Int? {
        chains.firstIndex(where: { $0.id == ch.id })
    }

    /// Called from the engine's 500 ms alignment/search poll. Advances or completes
    /// the search-then-predict pipeline.
    func onEngineState(alignments: [AlignmentEntry], searches: [MSASearchEntry]) {
        // Fix A: always record latest state so proceed() can skip already-satisfied chains.
        latestAlignments = alignments
        guard case .searching = phase else { return }
        let searchNames = Set(searches.map(\.name))
        var remaining: [String] = []
        var failed: [String] = []
        for ch in chains where msaChains.contains(ch.id) {
            if isSatisfied(ch, alignments: alignments) { continue }
            let name = plannedNames[ch.id] ?? ""
            if searchNames.contains(name) { remaining.append(ch.id) }  // still running
            else { failed.append(ch.id) }                              // gone, no result
        }
        if !failed.isEmpty {
            // Fix B: one-tick grace before declaring failure — the just-fired search may
            // not have appeared in msaSearches on the very first poll tick.
            if failGraceTicks > 0 {
                failGraceTicks -= 1
                phase = .searching(remaining: failed.count + remaining.count)
                return
            }
            phase = .error("MSA search did not complete for chain(s) "
                           + failed.sorted().joined(separator: ", ") + ".")
            return
        }
        if remaining.isEmpty { submitPredict() }
        else { phase = .searching(remaining: remaining.count) }
    }

    /// A requested chain is satisfied once its alignment exists. Object chains match on
    /// attachment to (object, source chain) — which also reuses an alignment the user
    /// attached earlier; literal chains match on the planned alignment name.
    private func isSatisfied(_ ch: PredictChain, alignments: [AlignmentEntry]) -> Bool {
        if ch.isFromObject {
            return alignments.contains { $0.target == ch.object && $0.chain == ch.chain }
        }
        let name = plannedNames[ch.id] ?? ""
        return alignments.contains { $0.name == name }
    }

    private func submitPredict() {
        let seed = Int(seedText)
        let depth = Int(msaDepthText)
        // msa= slots only for the literal path; object inputs auto-use attachments.
        var slots: String? = nil
        if useMSAEffective, let first = chains.first, !first.isFromObject {
            slots = PredictController.msaSlots(
                orderedChains: chains, requested: msaChains,
                nameFor: { plannedNames[$0.id] ?? "" })
        }
        let cmd = PredictController.predictPython(
            predictor: predictor, input: inputText, nModels: nModels,
            recyclingSteps: recyclingSteps, diffusionSteps: diffusionSteps,
            seed: seed, msaDepth: depth,
            name: resultName.isEmpty ? nil : resultName, msa: slots)
        runPythonSeam(cmd)
        phase = .predicting
    }

    func cancel() {
        for name in plannedNames.values {
            runPythonSeam("from pymol import cmd as _c\n_c.msa_cancel(\(PredictController.pythonLiteral(name)))")
        }
        plannedNames = [:]
        phase = .idle
    }
}
#endif
