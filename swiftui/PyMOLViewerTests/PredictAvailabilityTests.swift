import XCTest
@testable import RayMol

/// The Predict tool's offer rules. Every case goes through the pure
/// `isSupported(platform:osMajorVersion:isSimulator:)` so the iOS arms are exercised from
/// a macOS test host — a `#if os(iOS)` rule is a rule that never runs in CI.
final class PredictAvailabilityTests: XCTestCase {

    // The Simulator gate is the one that distinguishes this from DesignAvailability, and
    // it is not a version question: MLX's allocator builds Metal heaps MTLSimDevice
    // rejects outright, so a prediction started there can only abort. Version is
    // irrelevant — even a Simulator running a future iOS must be refused.
    func testSimulatorIsNeverSupportedRegardlessOfVersion() {
        for version in [17, 18, 26, 99] {
            XCTAssertFalse(
                PredictAvailability.isSupported(platform: .iOS, osMajorVersion: version,
                                                isSimulator: true),
                "iOS \(version) Simulator must not offer Predict — MLX cannot run there")
        }
    }

    // Same floor and same reasoning as Design: mlx-swift's Metal path has only ever been
    // validated on iOS 18 hardware, though SPM will resolve against boltz-mlx's iOS 17
    // deployment target.
    func testIOSDeviceRequires18() {
        XCTAssertFalse(PredictAvailability.isSupported(platform: .iOS, osMajorVersion: 16,
                                                       isSimulator: false))
        XCTAssertFalse(PredictAvailability.isSupported(platform: .iOS, osMajorVersion: 17,
                                                       isSimulator: false))
        XCTAssertTrue(PredictAvailability.isSupported(platform: .iOS, osMajorVersion: 18,
                                                      isSimulator: false))
        XCTAssertTrue(PredictAvailability.isSupported(platform: .iOS, osMajorVersion: 26,
                                                      isSimulator: false))
    }

    // Prediction has shipped on macOS since #224 and this port must not narrow it. The
    // `isSimulator` argument is meaningless there and must not leak into the answer.
    func testMacOSAlwaysSupported() {
        XCTAssertTrue(PredictAvailability.isSupported(platform: .macOS, osMajorVersion: 13,
                                                      isSimulator: false))
        XCTAssertTrue(PredictAvailability.isSupported(platform: .macOS, osMajorVersion: 26,
                                                      isSimulator: true))
    }

    func testMinimumIsEighteen() {
        XCTAssertEqual(PredictAvailability.minimumIOSMajorVersion, 18)
    }

    /// Separate constants on purpose: raising Design's floor must not silently raise
    /// Predict's, or vice versa. They may be equal — they must not be the same symbol.
    func testFloorIsIndependentOfDesigns() {
        #if RAYMOL_MPNN
        XCTAssertEqual(PredictAvailability.minimumIOSMajorVersion,
                       DesignAvailability.minimumIOSMajorVersion,
                       "equal today; this test exists to make a divergence deliberate")
        #endif
    }

    // The live property must agree with the pure function for the running host.
    func testLivePropertyMatchesPureFunction() {
        XCTAssertEqual(
            PredictAvailability.isSupported,
            PredictAvailability.isSupported(
                platform: PredictAvailability.current,
                osMajorVersion: PredictAvailability.currentOSMajorVersion,
                isSimulator: PredictAvailability.currentIsSimulator))
    }
}
