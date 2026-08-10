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

/// Bounded score cache with insertion-order (FIFO) eviction.
///
/// The key includes the sequence hash, so every edit inserts a fresh entry and an
/// unbounded dict grows for the whole session. Each entry holds three per-residue
/// arrays — including a 20-wide propensity row per residue — so a 2000-residue
/// object costs on the order of a megabyte.
///
/// FIFO rather than LRU is deliberate: the access pattern is "latest sequence
/// wins", so recency of *insertion* already tracks usefulness, and FIFO avoids
/// touching bookkeeping on every read.
final class DesignScoreCache {
    /// Retained entries. Roughly a session's worth of edits on one object.
    static let defaultCapacity = 24

    private let capacity: Int
    private var store: [DesignCacheKey: DesignScores] = [:]
    private var order: [DesignCacheKey] = []   // oldest first

    init(capacity: Int = DesignScoreCache.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    var count: Int { store.count }

    func get(_ key: DesignCacheKey) -> DesignScores? { store[key] }

    func set(_ key: DesignCacheKey, _ scores: DesignScores) {
        if store[key] == nil { order.append(key) }   // overwrite keeps its slot
        store[key] = scores
        while order.count > capacity {
            let oldest = order.removeFirst()
            store[oldest] = nil
        }
    }

    func invalidate(object: String) {
        store = store.filter { $0.key.object != object }
        order = order.filter { store[$0] != nil }
    }
}
#endif
