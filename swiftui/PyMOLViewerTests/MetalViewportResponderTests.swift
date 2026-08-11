import XCTest
import AppKit
@testable import RayMol

/// Regression guard for issue #73: the viewport must never accept keyboard
/// first-responder so that clicks in the viewport do not steal focus from the
/// command line.
///
/// This matters for more than UX: the entire `installPyMOLKeyMonitor`
/// architecture in ContentView (#258) exists *because* `acceptsFirstResponder`
/// is false. If this property is ever flipped to `true`, the viewport would
/// steal focus on click AND the key monitor would become redundant — but until
/// that monitor is removed, the two mechanisms would fight each other. Keep
/// this test in place as the explicit contract.
final class MetalViewportResponderTests: XCTestCase {

    func testPyMOLMTKViewDoesNotAcceptFirstResponder() {
        // PyMOLMTKView is the MTKView subclass that backs the Metal viewport on
        // macOS. acceptsFirstResponder must remain false so that:
        //   1. Clicking the viewport does not steal focus from the command line
        //      (issue #73).
        //   2. The app-level NSEvent monitor in ContentView (installPyMOLKeyMonitor,
        //      issue #258) remains the sole key-dispatch path and is not confused
        //      by a competing responder-chain path.
        let view = PyMOLMTKView(frame: .zero)
        XCTAssertFalse(view.acceptsFirstResponder,
                       "PyMOLMTKView.acceptsFirstResponder must be false (#73). "
                       + "The key monitor in ContentView exists because of this; "
                       + "flipping it requires coordinated removal of that monitor.")
    }
}
