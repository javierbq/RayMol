#if RAYMOL_MPNN
import Foundation

struct DesignScores: Equatable {
    let nativeFit: [Float?]
    let certainty: [Float?]
    /// Per-residue AA probability distribution over the 20 standard AAs (MPNN
    /// alphabet indices 0..19, dropping X at index 20). Each entry is a length-20
    /// array summing to ~1.0 (renormalized softmax of logProbs[i][0..<20]),
    /// or nil at masked positions.
    let propensities: [[Float]?]

    /// Backward-compatible init: existing callers that don't pass propensities
    /// (unit tests that construct DesignScores directly) default to an empty array.
    init(nativeFit: [Float?], certainty: [Float?], propensities: [[Float]?] = []) {
        self.nativeFit = nativeFit
        self.certainty = certainty
        self.propensities = propensities
    }
}
struct DesignCacheKey: Hashable { let object: String; let state: Int; let sequenceHash: Int }

final class DesignScoreCache {
    private var store: [DesignCacheKey: DesignScores] = [:]
    func get(_ key: DesignCacheKey) -> DesignScores? { store[key] }
    func set(_ key: DesignCacheKey, _ scores: DesignScores) { store[key] = scores }
    func invalidate(object: String) { store = store.filter { $0.key.object != object } }
}
#endif
