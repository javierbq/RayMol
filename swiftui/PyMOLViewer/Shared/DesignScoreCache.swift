#if RAYMOL_MPNN
import Foundation

struct DesignScores: Equatable { let nativeFit: [Float?]; let certainty: [Float?] }
struct DesignCacheKey: Hashable { let object: String; let state: Int; let sequenceHash: Int }

final class DesignScoreCache {
    private var store: [DesignCacheKey: DesignScores] = [:]
    func get(_ key: DesignCacheKey) -> DesignScores? { store[key] }
    func set(_ key: DesignCacheKey, _ scores: DesignScores) { store[key] = scores }
    func invalidate(object: String) { store = store.filter { $0.key.object != object } }
}
#endif
