import XCTest
@testable import RayMol   // module name = PRODUCT_NAME "RayMol"; try `import PyMOLViewer` if this fails

final class SmokeTests: XCTestCase {
    func testHarnessRuns() { XCTAssertEqual(1 + 1, 2) }
}
