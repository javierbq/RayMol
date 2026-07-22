#if RAYMOL_MPNN
import Foundation
import MPNNKit

enum DesignColorMeaning: String, CaseIterable { case nativeFit, certainty }

enum DesignColor {
    static let nativeFitDomain: ClosedRange<Float> = (-6.0)...0.0
    static let certaintyDomain: ClosedRange<Float> = 0.0...1.0

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

    /// Build DesignScores from one leaveOneOut ScoreResult, aligned to the full residue list.
    /// `validMask[i]` true where residues[i] contributed a row (in order).
    static func scores(from r: MPNNModel.ScoreResult, validMask: [Bool]) -> DesignScores {
        var nf = [Float?](repeating: nil, count: validMask.count)
        var ce = [Float?](repeating: nil, count: validMask.count)
        var j = 0
        for i in 0..<validMask.count where validMask[i] {
            if let cur = r.currentAALogProb, j < cur.count { nf[i] = cur[j] }
            if j < r.logProbs.count { ce[i] = certainty(fromLogProbsRow: r.logProbs[j]) }
            j += 1
        }
        return DesignScores(nativeFit: nf, certainty: ce)
    }
}
#endif
