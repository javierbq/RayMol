#if RAYMOL_MPNN
import XCTest
@testable import RayMol

final class DesignScoreCacheTests: XCTestCase {
    func testHitMissAndInvalidate() {
        let cache = DesignScoreCache()
        let k1 = DesignCacheKey(object: "m1", state: 1, sequenceHash: 42)
        XCTAssertNil(cache.get(k1))
        cache.set(k1, DesignScores(nativeFit: [-1.0], certainty: [0.5]))
        XCTAssertEqual(cache.get(k1)?.nativeFit, [-1.0])
        // Different sequence hash = miss (sequence changed).
        XCTAssertNil(cache.get(DesignCacheKey(object: "m1", state: 1, sequenceHash: 43)))
        // Different state = miss.
        XCTAssertNil(cache.get(DesignCacheKey(object: "m1", state: 2, sequenceHash: 42)))
        cache.invalidate(object: "m1")
        XCTAssertNil(cache.get(k1))
    }
}
#endif
