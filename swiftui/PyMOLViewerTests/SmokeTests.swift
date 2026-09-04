import XCTest
@testable import RayMol   // module name = PRODUCT_NAME "RayMol"; try `import PyMOLViewer` if this fails

final class SmokeTests: XCTestCase {
    func testHarnessRuns() { XCTAssertEqual(1 + 1, 2) }
}

/// The Background swatch's opacity → `ray_opaque_background` mapping (#378).
/// PyMOL's `bg_rgb` has no alpha, so the picker's opacity slider used to be a
/// dead control; it now drives the same binary export switch as the Share menu.
final class BackgroundOpacityTests: XCTestCase {
    func testFullyOpaqueAndTransparentEndpoints() {
        XCTAssertFalse(BackgroundOpacity.isTransparent(alpha: 1))
        XCTAssertTrue(BackgroundOpacity.isTransparent(alpha: 0))
    }

    // The underlying setting is binary, so the threshold sits at the midpoint:
    // a nudge off 100% stays opaque, anything under half becomes transparent.
    func testThresholdIsHalf() {
        XCTAssertFalse(BackgroundOpacity.isTransparent(alpha: 0.5))
        XCTAssertFalse(BackgroundOpacity.isTransparent(alpha: 0.95))
        XCTAssertTrue(BackgroundOpacity.isTransparent(alpha: 0.49))
    }

    // What the swatch shows must round-trip through the policy.
    func testSwatchAlphaRoundTrips() {
        XCTAssertTrue(BackgroundOpacity.isTransparent(alpha: BackgroundOpacity.alpha(transparent: true)))
        XCTAssertFalse(BackgroundOpacity.isTransparent(alpha: BackgroundOpacity.alpha(transparent: false)))
    }

    func testCommandTogglesRayOpaqueBackground() {
        XCTAssertEqual(BackgroundOpacity.command(transparent: true), "set ray_opaque_background, 0")
        XCTAssertEqual(BackgroundOpacity.command(transparent: false), "set ray_opaque_background, 1")
    }

    // Both affordances must persist under the one key ContentView already uses.
    func testSharesTheExportMenuDefaultsKey() {
        XCTAssertEqual(BackgroundOpacity.defaultsKey, "exportTransparent")
    }
}
