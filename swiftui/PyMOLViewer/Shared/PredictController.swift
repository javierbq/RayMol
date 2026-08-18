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

    // Filled in Task 3.
}
#endif
