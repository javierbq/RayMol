#if RAYMOL_MPNN
import XCTest
@testable import RayMol

final class DesignAvailabilityTests: XCTestCase {

    // iOS 18 is the only configuration ever validated on real hardware; 17 merely
    // resolves in SPM. Design must be absent below 18 rather than present-and-unproven.
    func testIOSRequires18() {
        XCTAssertFalse(DesignAvailability.isSupported(platform: .iOS, osMajorVersion: 17))
        XCTAssertFalse(DesignAvailability.isSupported(platform: .iOS, osMajorVersion: 16))
        XCTAssertTrue(DesignAvailability.isSupported(platform: .iOS, osMajorVersion: 18))
        XCTAssertTrue(DesignAvailability.isSupported(platform: .iOS, osMajorVersion: 26))
    }

    // macOS shipped Design in Phase 2a; its availability must not change.
    func testMacOSAlwaysSupported() {
        XCTAssertTrue(DesignAvailability.isSupported(platform: .macOS, osMajorVersion: 14))
        XCTAssertTrue(DesignAvailability.isSupported(platform: .macOS, osMajorVersion: 26))
    }

    func testMinimumIsEighteen() {
        XCTAssertEqual(DesignAvailability.minimumIOSMajorVersion, 18)
    }

    // The live property must agree with the pure function for the running host.
    func testLivePropertyMatchesPureFunction() {
        XCTAssertEqual(DesignAvailability.isSupported,
                       DesignAvailability.isSupported(platform: DesignAvailability.current,
                                                      osMajorVersion: DesignAvailability.currentOSMajorVersion))
    }
}
#endif
