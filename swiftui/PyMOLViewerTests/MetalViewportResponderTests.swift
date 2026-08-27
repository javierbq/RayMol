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

/// Coverage for the Box Select rubber-band geometry (#358): `BoxRect` and the
/// `BoxDrag` it hands back.
///
/// The gestures themselves live in MetalViewport's coordinator and cannot be
/// unit-tested (a test cannot drag a mouse), so — exactly as with KeyRouting —
/// all of the geometry sits in pure value types and is pinned down here. Both
/// the SwiftUI overlay that DRAWS the box and the coordinator that ROUTES drags
/// into it read these same types, so an error here is an error in both.
final class BoxSelectGeometryTests: XCTestCase {

    // A 0.4 x 0.4 NDC box centred on the origin, used by most cases below.
    private let box = BoxRect(minX: -0.2, minY: -0.2, maxX: 0.2, maxY: 0.2)

    // MARK: - Normalization

    func testCornersMayBeGivenInAnyOrder() {
        let a = BoxRect(from: CGPoint(x: 0.5, y: 0.5), to: CGPoint(x: -0.5, y: -0.5))
        XCTAssertEqual(a, BoxRect(minX: -0.5, minY: -0.5, maxX: 0.5, maxY: 0.5),
                       "a box dragged up-left must normalize to the same rect as down-right")
    }

    func testDegenerateIsOnlyTinyOnBothAxes() {
        XCTAssertTrue(BoxRect(minX: 0, minY: 0, maxX: 0, maxY: 0).isDegenerate)
        XCTAssertFalse(BoxRect(minX: 0, minY: 0, maxX: 0.5, maxY: 0.001).isDegenerate,
                       "a thin but long band is a real box — only a stray click is degenerate")
    }

    func testInitialRectIsCentredAndGrabbable() {
        let r = BoxRect.initial
        XCTAssertEqual((r.minX + r.maxX) / 2, 0, accuracy: 0.0001, "centred in x")
        XCTAssertEqual((r.minY + r.maxY) / 2, 0, accuracy: 0.0001, "centred in y")
        XCTAssertFalse(r.isDegenerate, "the armed box must select something at once")
        XCTAssertLessThan(r.maxX, 1.0, "leave room to grab the edges from outside")
        XCTAssertLessThan(r.maxY, 1.0)
    }

    // MARK: - NDC -> points

    func testInPointsFlipsY() {
        // NDC +y is up; SwiftUI +y is down. The box's TOP (maxY) must come out as
        // the rect's SMALLEST point-space y, or the overlay draws it upside down
        // relative to the atoms the same rect selects.
        let r = BoxRect(minX: -1, minY: 0, maxX: 0, maxY: 1)
            .inPoints(CGSize(width: 400, height: 300))
        XCTAssertEqual(r.minX, 0, accuracy: 0.001)
        XCTAssertEqual(r.maxX, 200, accuracy: 0.001)
        XCTAssertEqual(r.minY, 0, accuracy: 0.001)        // NDC y = +1 -> top
        XCTAssertEqual(r.maxY, 150, accuracy: 0.001)      // NDC y =  0 -> middle
    }

    // MARK: - Grab classification

    func testInteriorGrab() {
        let e = box.edges(at: CGPoint(x: 0, y: 0), aspect: 1, slop: 0.03)
        XCTAssertEqual(e, BoxEdges.interior)
    }

    func testEdgeAndCornerGrabs() {
        let left = box.edges(at: CGPoint(x: -0.2, y: 0), aspect: 1, slop: 0.03)
        XCTAssertEqual(left, BoxEdges(left: true, right: false, bottom: false, top: false))

        let corner = box.edges(at: CGPoint(x: 0.2, y: -0.2), aspect: 1, slop: 0.03)
        XCTAssertEqual(corner, BoxEdges(left: false, right: true, bottom: true, top: false))
    }

    func testMissReturnsNil() {
        XCTAssertNil(box.edges(at: CGPoint(x: 0.9, y: 0.9), aspect: 1, slop: 0.03))
    }

    func testGrabBandIsAspectCorrectedOnX() {
        // At aspect 2 the x band is half as wide in NDC, so the same NDC offset
        // that grabs the left edge at aspect 1 must miss it — otherwise the band
        // is twice as many pixels horizontally as vertically.
        let p = CGPoint(x: -0.175, y: 0)
        XCTAssertEqual(box.edges(at: p, aspect: 1, slop: 0.03)?.left, true)
        XCTAssertEqual(box.edges(at: p, aspect: 2, slop: 0.03)?.left, false)
    }

    // MARK: - Dragging

    func testNewBoxFollowsThePointer() {
        let drag = BoxRect.beginNewDrag(at: CGPoint(x: -0.5, y: -0.5))
        XCTAssertEqual(drag.rect(at: CGPoint(x: 0.5, y: 0.25)),
                       BoxRect(minX: -0.5, minY: -0.5, maxX: 0.5, maxY: 0.25))
        // Dragged back past the anchor: still a valid (normalized) box.
        XCTAssertEqual(drag.rect(at: CGPoint(x: -0.9, y: -0.9)),
                       BoxRect(minX: -0.9, minY: -0.9, maxX: -0.5, maxY: -0.5))
    }

    func testCornerDragMovesOnlyThatCorner() {
        let drag = box.beginDrag(at: CGPoint(x: 0.2, y: 0.2), aspect: 1, slop: 0.03)
        XCTAssertEqual(drag?.rect(at: CGPoint(x: 0.6, y: 0.7)),
                       BoxRect(minX: -0.2, minY: -0.2, maxX: 0.6, maxY: 0.7))
    }

    func testEdgeDragMovesOnlyThatAxis() {
        let drag = box.beginDrag(at: CGPoint(x: -0.2, y: 0), aspect: 1, slop: 0.03)
        // The pointer wandered in y too; the left-edge grab must ignore that.
        XCTAssertEqual(drag?.rect(at: CGPoint(x: -0.8, y: 0.9)),
                       BoxRect(minX: -0.8, minY: -0.2, maxX: 0.2, maxY: 0.2))
    }

    func testInteriorDragTranslatesWithoutResizing() {
        let drag = box.beginDrag(at: CGPoint(x: 0, y: 0), aspect: 1, slop: 0.03)
        let moved = drag?.rect(at: CGPoint(x: 0.3, y: -0.1))
        // By component with a tolerance: the translate is a float addition, so
        // exact struct equality would trip over 0.1 - 0.2 + 0.2.
        XCTAssertEqual(moved?.minX ?? 0, 0.1, accuracy: 0.0001)
        XCTAssertEqual(moved?.minY ?? 0, -0.3, accuracy: 0.0001)
        XCTAssertEqual(moved?.maxX ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(moved?.maxY ?? 0, 0.1, accuracy: 0.0001)
        XCTAssertEqual(moved?.width ?? 0, box.width, accuracy: 0.0001)
        XCTAssertEqual(moved?.height ?? 0, box.height, accuracy: 0.0001)
    }

    func testMissedGrabStartsNoDrag() {
        XCTAssertNil(box.beginDrag(at: CGPoint(x: -0.9, y: 0.9), aspect: 1, slop: 0.03),
                     "a press that misses the box must fall through to drawing a new one")
    }
}
