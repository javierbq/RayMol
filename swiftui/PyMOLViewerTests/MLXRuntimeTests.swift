#if RAYMOL_MPNN || RAYMOL_BOLTZ
import XCTest
@testable import RayMol   // module name = PRODUCT_NAME "RayMol"

/// Tests for `MLXRuntime`, the single process-wide owner of MLX configuration.
///
/// The behaviour under test that did NOT exist before this type: `MLX.Memory.cacheLimit`
/// is process-global, and RayMol now has more than one feature that wants to set it
/// (Design mode via `MPNNRuntime`, structure prediction via the Boltz runtime). Whoever
/// wrote last used to win, silently and by call order. `MLXRuntime` arbitrates instead,
/// installing the most conservative ceiling any registered owner requires.
///
/// Direction matters and is asymmetric: a cache limit that is too LOW only costs
/// allocator churn, while one that is too HIGH risks a jetsam SIGKILL that no Swift
/// handler can catch. So the safe rule is min-wins, and the regression that must never
/// come back is a later, larger request RAISING a ceiling somebody else needs low.
final class MLXRuntimeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MLXRuntime.resetCacheLimitRequirementsForTesting()
    }

    override func tearDown() {
        // Leave the process as Design mode expects it, so this class cannot perturb
        // MPNNRuntime's own assertions regardless of test-execution order.
        MLXRuntime.resetCacheLimitRequirementsForTesting()
        MPNNRuntime.configureOnce()
        super.tearDown()
    }

    // MARK: – Cache-limit arbitration

    func testSingleOwnerInstallsItsLimit() {
        MLXRuntime.requireCacheLimit(128 * 1024 * 1024, owner: "test.a")
        XCTAssertEqual(MLXRuntime.activeCacheLimitBytes, 128 * 1024 * 1024)
    }

    func testMostConservativeOwnerWins() {
        MLXRuntime.requireCacheLimit(256 * 1024 * 1024, owner: "test.boltz")
        MLXRuntime.requireCacheLimit(96 * 1024 * 1024, owner: "test.mpnn")
        XCTAssertEqual(MLXRuntime.activeCacheLimitBytes, 96 * 1024 * 1024,
                       "the smallest requirement must win")
    }

    /// The actual regression this type exists to prevent. Registration order must not
    /// change the outcome: a later, larger request must NOT raise a ceiling that an
    /// earlier owner needs low, because that is the direction that gets the app killed.
    func testLaterLargerRequestDoesNotRaiseTheCeiling() {
        MLXRuntime.requireCacheLimit(96 * 1024 * 1024, owner: "test.mpnn")
        MLXRuntime.requireCacheLimit(256 * 1024 * 1024, owner: "test.boltz")
        XCTAssertEqual(MLXRuntime.activeCacheLimitBytes, 96 * 1024 * 1024,
                       "a later larger request must not raise the ceiling")
    }

    func testRepeatedRequestFromSameOwnerReplacesRatherThanAccumulates() {
        MLXRuntime.requireCacheLimit(64 * 1024 * 1024, owner: "test.a")
        MLXRuntime.requireCacheLimit(192 * 1024 * 1024, owner: "test.a")
        XCTAssertEqual(MLXRuntime.cacheLimitRequirements, ["test.a": 192 * 1024 * 1024])
        XCTAssertEqual(MLXRuntime.activeCacheLimitBytes, 192 * 1024 * 1024,
                       "one owner revising its own requirement is not a conflict")
    }

    func testRequirementsAreRecordedPerOwnerForDiagnostics() {
        MLXRuntime.requireCacheLimit(96 * 1024 * 1024, owner: "test.mpnn")
        MLXRuntime.requireCacheLimit(256 * 1024 * 1024, owner: "test.boltz")
        XCTAssertEqual(MLXRuntime.cacheLimitRequirements,
                       ["test.mpnn": 96 * 1024 * 1024, "test.boltz": 256 * 1024 * 1024],
                       "each owner's ask stays visible so a conflict can be diagnosed")
    }

    // MARK: – Error handling

    func testWithMLXErrorsAsThrowsReturnsTheBodyValue() throws {
        let value = try MLXRuntime.withMLXErrorsAsThrows { 42 }
        XCTAssertEqual(value, 42)
    }

    func testWithMLXErrorsAsThrowsPropagatesASwiftError() {
        struct Boom: Error {}
        XCTAssertThrowsError(try MLXRuntime.withMLXErrorsAsThrows { throw Boom() }) { error in
            XCTAssertTrue(error is Boom)
        }
    }

    // MARK: – MPNNRuntime still satisfies its own contract through the shared owner

    func testMPNNRuntimeDelegatesAndStillInstallsIts96MBLimit() {
        MPNNRuntime.configureOnce()
        XCTAssertEqual(MPNNRuntime.cacheLimitBytes, 96 * 1024 * 1024)
        XCTAssertEqual(MPNNRuntime.activeCacheLimitBytes, MPNNRuntime.cacheLimitBytes)
        XCTAssertEqual(MLXRuntime.cacheLimitRequirements[MPNNRuntime.cacheLimitOwner],
                       MPNNRuntime.cacheLimitBytes,
                       "MPNNRuntime must register through MLXRuntime, not write MLX directly")
    }
}
#endif
