#if RAYMOL_MPNN
import Foundation
import MPNNKit

enum DesignColorMeaning: String, CaseIterable {
    case nativeFit, certainty

    /// Human-readable label used in pickers and tooltips.
    /// Single source of truth — DesignCompactPanel and meaningPicker both reference this.
    var label: String {
        switch self {
        case .nativeFit: return "Native fit"
        case .certainty: return "Certainty"
        }
    }

    /// The key this score is stored under in the metric store (#308).
    /// Snake_case because it is an API: it appears in `metrics_get`, in an exported
    /// CSV and in `metrics_color mpnn, native_fit`, alongside keys from every other
    /// tool. Kept separate from `rawValue` so renaming a Swift case cannot silently
    /// change what a saved .pse means.
    var metricKey: String {
        switch self {
        case .nativeFit: return "native_fit"
        case .certainty: return "certainty"
        }
    }
}

enum DesignColor {
    static let nativeFitDomain: ClosedRange<Float> = (-6.0)...0.0
    static let certaintyDomain: ClosedRange<Float> = 0.0...1.0

    /// 20 standard AAs in MPNN alphabet order (A C D E F G H I K L M N P Q R S T V W Y).
    /// The 21st logit (index 20) is X and is dropped when computing propensities.
    static let mpnnAlphabet: [String] = [
        "A","C","D","E","F","G","H","I","K","L","M","N","P","Q","R","S","T","V","W","Y"
    ]

    /// 1 - Shannon entropy / ln(21), from a log-prob row. 0 = flat, 1 = one-hot.
    static func certainty(fromLogProbsRow row: [Float]) -> Float {
        var h: Float = 0
        for lp in row { let p = expf(lp); if p > 0 { h -= p * lp } }   // H = -sum p ln p
        let hmax = logf(Float(row.count))
        return hmax > 0 ? max(0, min(1, 1 - h / hmax)) : 0
    }

    static func scalar(_ scores: DesignScores, _ meaning: DesignColorMeaning) -> [Float?] {
        meaning == .nativeFit ? scores.nativeFit : scores.certainty
    }

    static func domain(_ meaning: DesignColorMeaning) -> ClosedRange<Float> {
        meaning == .nativeFit ? nativeFitDomain : certaintyDomain
    }

    static func palette(_ meaning: DesignColorMeaning) -> String {
        // native-fit: red(low/bad) -> white -> blue(high/good); certainty: blue(low) -> red(high)
        meaning == .nativeFit ? "red_white_blue" : "blue_white_red"
    }

    /// Softmax over the first 20 logits of a log-prob row, renormalized so the
    /// 20 standard-AA probabilities sum to 1.0. The 21st entry (X, index 20) is
    /// dropped. Returns an empty array if the row has fewer than 1 entry.
    static func propensityRow(from logProbsRow: [Float]) -> [Float] {
        let k = min(20, logProbsRow.count)
        guard k > 0 else { return [] }
        // exp of each logit for indices 0..<k
        var exps = (0..<k).map { expf(logProbsRow[$0]) }
        let total = exps.reduce(0, +)
        if total > 0 { exps = exps.map { $0 / total } }
        return exps
    }

    /// Build DesignScores from one leaveOneOut ScoreResult, aligned to the full residue list.
    /// `validMask[i]` true where residues[i] contributed a row (in order).
    static func scores(from r: MPNNModel.ScoreResult, validMask: [Bool]) -> DesignScores {
        var nf    = [Float?](repeating: nil, count: validMask.count)
        var ce    = [Float?](repeating: nil, count: validMask.count)
        var props = [[Float]?](repeating: nil, count: validMask.count)
        var j = 0
        for i in 0..<validMask.count where validMask[i] {
            if let cur = r.currentAALogProb, j < cur.count { nf[i] = cur[j] }
            if j < r.logProbs.count {
                let row = r.logProbs[j]
                ce[i]    = certainty(fromLogProbsRow: row)
                props[i] = propensityRow(from: row)
            }
            j += 1
        }
        return DesignScores(nativeFit: nf, certainty: ce, propensities: props)
    }
}
#endif
