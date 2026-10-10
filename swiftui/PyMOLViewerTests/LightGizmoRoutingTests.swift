#if os(macOS)
import XCTest
import AppKit
import CoreGraphics
@testable import RayMol

// The light gizmo's input routing (#622) through the REAL viewport handlers:
// a PyMOLMTKView in an offscreen window (never ordered in), with a
// MetalViewport.Coordinator wired to the live engine, fed synthesized
// NSEvents (mouse) and CGEvent-made scroll events. The engine's
// viewportInputTap records what reaches the camera path (PyMOL button and
// drag events, the click's atom pick) instead of handing it to the core, so
// the shared engine's camera never moves.
//
// - a press on a knob drags it: the rig changes, no PyMOL button is sent;
// - a press on empty space is today's camera drag (button down, drags, up);
// - hover marks the target under the pointer; leaving clears it;
// - a wheel notch over a knob steps its radius, elsewhere clips as today; a
//   trackpad scroll that begins over a knob is latched, momentum included;
// - an option-click places one highlight on the molecule, runs nothing off
//   it, and never runs the atom pick;
// - Esc mid-drag: the rest of the drag and the release reach nothing;
// - the DEBUG overlay-size check logs a mismatch once per session.
//
// The model behind it is tested on fakes in LightGizmoTests.swift and on the
// live engine in LightGizmoLiveTests.swift.

@MainActor
final class LightGizmoRoutingTests: XCTestCase {
    private var engine: PyMOLEngine { PyMOLEngine.shared }
    private var controller: LightsController { engine.lightsController }
    private var ui: LightGizmoUIState { engine.lightGizmoUI }

    private final class Lines { var lines: [String] = [] }
    private final class Events { var list: [PyMOLEngine.ViewportInputEvent] = [] }
    private struct Missing: Error, CustomStringConvertible { let description: String }

    // PyMOL's button codes (layer5/PyMOL.h; the bridging header is the app's).
    private static let left: Int32 = 0, middle: Int32 = 1
    private static let scrollForward: Int32 = 3, scrollReverse: Int32 = 4
    private static let down: Int32 = 0, up: Int32 = 1

    /// The pinned camera of SurfacePickTests and LightGizmoLiveTests.
    private static let pinnedView =
        "(1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, "
        + "0.0, 0.0, -100.0, 0.0, 0.0, 0.0, 50.0, 150.0, -20.0)"

    private var viewSize = CGSize(width: 800, height: 600)
    private var window: NSWindow?
    private var view: PyMOLMTKView!
    private var coordinator: MetalViewport.Coordinator!
    private var sceneBuilt = false

    override func setUp() {
        super.setUp()
        engine.setDesignMode(false)
        engine.setMeasureMode(nil)
        engine.setPredictMode(false)
        engine.setBinderDesignMode(false)
        engine.setInteractionMode(.viewing)
    }

    override func tearDown() {
        engine.viewportInputTap = nil
        engine.lightGizmoPointer.cancel()
        if let window {
            window.contentView = nil
            window.close()
        }
        window = nil
        view = nil
        coordinator = nil
        if sceneBuilt {
            engine.setInteractionMode(.viewing)
            engine.runPython(
                "from pymol import cmd as _lgr_c\n"
                + "for _k, _v in globals().pop('_lgr_saved', {}).items():\n"
                + "    _lgr_c.set(_k, _v)\n"
                + "for _n in globals().pop('_lgr_enabled', []):\n"
                + "    _lgr_c.enable(_n)\n")
            sceneBuilt = false
        }
        LightsLive.tearDown()
        super.tearDown()
    }

    // MARK: the scene and the viewport

    /// A six-residue peptide as spheres at the origin, every other object
    /// hidden, the pinned camera, the three-light rig (centre at the origin),
    /// the pick grids built; Lights mode entered with `key` selected and a
    /// frame's eye read; then the viewport.
    private func enterGizmo() throws {
        try LightsLive.requireEngine()
        LightsLive.addPeptide()
        sceneBuilt = true
        let path = NSTemporaryDirectory() + "lgr_\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        engine.runPython(
            "import json as _lgr_json\n"
            + "from pymol import cmd as _c\n"
            + "if '_lgr_saved' not in globals():\n"
            + "    _lgr_saved = {_k: _c.get(_k) for _k in ('orthoscopic', 'field_of_view')}\n"
            + "    _lgr_enabled = [_n for _n in _c.get_names('objects', enabled_only=1) if _n != 'lmt_pep']\n"
            + "for _n in _lgr_enabled:\n"
            + "    _c.disable(_n)\n"
            + "_c.show_as('spheres', 'lmt_pep')\n"
            + "_e = _c.get_extent('lmt_pep')\n"
            + "_c.translate([-(_e[0][i] + _e[1][i]) / 2.0 for i in range(3)],\n"
            + "             selection='lmt_pep', camera=0)\n"
            + "_c.set('orthoscopic', 0)\n"
            + "_c.set_view(\(Self.pinnedView))\n"
            + "open(r'\(path)', 'w').write(_lgr_json.dumps(list(_c.get_viewport(output=0))))\n")
        let data = try XCTUnwrap(FileManager.default.contents(atPath: path), "the scene setup failed")
        let viewport = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [Double])
        XCTAssertEqual(viewport.count, 2)
        // 600 points tall at the core's aspect, so a view point picks what
        // the core draws there.
        viewSize = CGSize(width: (600 * viewport[0] / viewport[1]).rounded(), height: 600)
        _ = try XCTUnwrap(LightsLive.setRig(LightsLive.threeLights(enabled: true)))
        XCTAssertGreaterThan(engine.prepareSurfacePick(updateReps: true), 0, "no pick grid was built")

        engine.setInteractionMode(.lights)
        XCTAssertEqual(controller.eyeDemand, .everyFrame)
        controller.select(name: "key")
        engine.lightsFrameRendered()

        // The viewport: no delegate and no device, so it never renders; the
        // window is never ordered in.
        let frame = NSRect(origin: .zero, size: viewSize)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let view = PyMOLMTKView(frame: frame)
        window.contentView = view
        let coordinator = MetalViewport.Coordinator()
        coordinator.engine = engine
        coordinator.mtkView = view
        view.coordinator = coordinator
        self.window = window
        self.view = view
        self.coordinator = coordinator
        XCTAssertEqual(view.bounds.size, viewSize)
    }

    /// The gizmo as the viewport lays it out (the MTKView's bounds).
    private func layout(file: StaticString = #filePath, line: UInt = #line) throws -> LightGizmoLayout {
        try XCTUnwrap(engine.lightGizmoLayout(viewSize: view.bounds.size), "the gizmo is hidden",
                      file: file, line: line)
    }

    private func rig(file: StaticString = #filePath, line: UInt = #line) throws -> LightRigSnapshot {
        try XCTUnwrap(engine.lightRig(), "no rig", file: file, line: line)
    }

    /// A point (top-left) that is no gizmo target and over no molecule.
    private func emptyPoint(in l: LightGizmoLayout) -> CGPoint {
        let p = CGPoint(x: 24, y: 24)
        XCTAssertNil(LightGizmoHitTest.target(at: p, layout: l), "the corner is a gizmo target")
        return p
    }

    /// A point over the peptide that is no gizmo target and whose pick faces
    /// the camera (scanned outwards from the rig centre's projection).
    private func moleculePoint(in l: LightGizmoLayout) throws -> CGPoint {
        for ring in 0..<60 {
            let r = CGFloat(ring) * 3
            let count = max(1, ring * 6)
            for k in 0..<count {
                let a = 2 * CGFloat.pi * CGFloat(k) / CGFloat(count)
                let p = CGPoint(x: l.centre.x + r * cos(a), y: l.centre.y + r * sin(a))
                guard LightGizmoHitTest.target(at: p, layout: l) == nil else { continue }
                let ndc = l.projection.viewNDC(point: p)
                guard let hit = engine.pickSurface(viewNDCX: Float(ndc.x), viewNDCY: Float(ndc.y),
                                                   viewAspect: Float(viewSize.width / viewSize.height),
                                                   updateReps: false),
                      hit.facing >= 0.5 else { continue }
                return p
            }
        }
        XCTFail("no point over the peptide is clear of the gizmo")
        throw Missing(description: "no molecule point")
    }

    /// Record what reaches the camera path, the Python and the console.
    private func taps() -> (events: Events, python: Lines, commands: Lines, stop: () -> Void) {
        let events = Events(), python = Lines(), commands = Lines()
        let engine = self.engine
        engine.viewportInputTap = { events.list.append($0) }
        engine.pythonTap = { python.lines.append($0) }
        engine.commandTap = { commands.lines.append($0) }
        return (events, python, commands, {
            engine.pythonTap = nil
            engine.commandTap = nil
        })
    }

    private func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    private func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    // MARK: events (points are the gizmo's: top-left)

    private func mouse(_ type: NSEvent.EventType, at p: CGPoint, option: Bool = false) throws -> NSEvent {
        let window = try XCTUnwrap(window)
        let location = CGPoint(x: p.x, y: viewSize.height - p.y)   // window: bottom-left
        return try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: option ? [.option] : [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
    }

    private func press(_ p: CGPoint, option: Bool = false) throws {
        view.mouseDown(with: try mouse(.leftMouseDown, at: p, option: option))
    }

    private func dragTo(_ p: CGPoint, option: Bool = false) throws {
        view.mouseDragged(with: try mouse(.leftMouseDragged, at: p, option: option))
    }

    private func release(_ p: CGPoint, option: Bool = false) throws {
        view.mouseUp(with: try mouse(.leftMouseUp, at: p, option: option))
    }

    private func hover(_ p: CGPoint) throws {
        view.mouseMoved(with: try mouse(.mouseMoved, at: p))
    }

    /// Press at `from`, drag in `steps` ticks to `to`, no release.
    private func drag(from: CGPoint, to: CGPoint, steps: Int = 12) throws {
        for k in 1...steps { try dragTo(lerp(from, to, CGFloat(k) / CGFloat(steps))) }
    }

    /// A scroll event at `p`: `units` .line with no phase is a mouse-wheel
    /// notch; .pixel with a phase (or momentum phase) and the continuous flag
    /// is a trackpad scroll. Its location is calibrated against what
    /// NSEvent reports, whatever screen the host has.
    private func scrollEvent(at p: CGPoint, deltaY: Int32, units: CGScrollEventUnit = .pixel,
                             phase: CGScrollPhase? = nil,
                             momentum: CGMomentumScrollPhase? = nil) throws -> NSEvent {
        func make(_ location: CGPoint) -> NSEvent? {
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 1,
                                   wheel1: deltaY, wheel2: 0, wheel3: 0) else { return nil }
            cg.location = location
            if units == .pixel { cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1) }
            if let phase { cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue)) }
            if let momentum {
                cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue))
            }
            return NSEvent(cgEvent: cg)
        }
        let want = CGPoint(x: p.x, y: viewSize.height - p.y)
        let e0 = try XCTUnwrap(make(.zero)).locationInWindow
        let e1 = try XCTUnwrap(make(CGPoint(x: 100, y: 100))).locationInWindow
        let sx = (e1.x - e0.x) / 100, sy = (e1.y - e0.y) / 100
        guard abs(abs(sx) - 1) < 1e-6, abs(abs(sy) - 1) < 1e-6 else {
            throw Missing(description: "scroll locations do not map 1:1 (\(e0), \(e1))")
        }
        let event = try XCTUnwrap(make(CGPoint(x: (want.x - e0.x) / sx, y: (want.y - e0.y) / sy)))
        XCTAssertLessThan(dist(event.locationInWindow, want), 0.5, "scroll location \(event.locationInWindow)")
        return event
    }

    private func scroll(_ event: NSEvent) { view.scrollWheel(with: event) }

    // MARK: knob drag vs camera drag

    /// A press on a knob, drags and the release are the gizmo's: the rig
    /// changes on the drags, the knob follows the pointer, the overlay shows
    /// the drag, and no PyMOL button, drag or pick is sent, with no Python
    /// and no console command.
    func testKnobDragWritesTheRigAndSendsNoButton() throws {
        try enterGizmo()
        let l = try layout()
        let key = try XCTUnwrap(l.knob(named: "key"))
        let before = try rig().lights[0]
        let target = CGPoint(x: l.centre.x + l.sphereRadius * 0.35, y: l.centre.y - l.sphereRadius * 0.4)
        XCTAssertGreaterThan(dist(target, key.centre), 10)

        let t = taps()
        try press(key.centre)
        XCTAssertTrue(engine.lightGizmoPointer.ownsPress)
        XCTAssertEqual(ui.active, .knob("key"))
        // Entering Lights mode cleared the hover preview and none can show
        // since, so the press runs no Python at all (#694).
        XCTAssertEqual(t.python.lines, [], "a Lights-mode press runs no Python")
        try drag(from: key.centre, to: target)
        XCTAssertNotNil(ui.readout, "the drag shows its readout")
        XCTAssertEqual(ui.hemisphere, .front)
        try release(target)
        t.stop()

        XCTAssertEqual(t.events.list, [], "a gizmo drag sends no PyMOL button, drag or pick")
        XCTAssertEqual(t.python.lines, [], "no Python on the press, a drag tick or the release")
        XCTAssertEqual(t.commands.lines, [])
        XCTAssertFalse(engine.lightGizmoPointer.ownsPress)
        XCTAssertNil(ui.active)
        XCTAssertNil(ui.readout)
        let after = try rig().lights[0]
        XCTAssertTrue(after.orbit != before.orbit || after.pitch != before.pitch, "the rig was written")
        XCTAssertEqual(after.radius, before.radius)
        let moved = try XCTUnwrap(try layout().knob(named: "key"))
        XCTAssertLessThan(dist(moved.centre, target), 4, "the knob is under the pointer again")
    }

    /// A press off every target is today's camera drag: the button-down at
    /// the press point on the first drag, the drags, the button-up; the rig
    /// is untouched.
    func testEmptySpaceDragOrbitsTheCamera() throws {
        try enterGizmo()
        let l = try layout()
        let p = emptyPoint(in: l)
        let json = engine.lightRigJSON()

        let t = taps()
        try press(p)
        XCTAssertFalse(engine.lightGizmoPointer.ownsPress)
        try drag(from: p, to: CGPoint(x: p.x + 40, y: p.y + 20), steps: 4)
        try release(CGPoint(x: p.x + 40, y: p.y + 20))
        t.stop()

        let events = t.events.list
        XCTAssertEqual(events.count, 6, "\(events)")
        guard case .button(Self.left, Self.down, _, _, _)? = events.first else {
            return XCTFail("the drag must start with a left button-down: \(events)")
        }
        XCTAssertEqual(events.dropFirst().dropLast().filter {
            if case .drag = $0 { return true } else { return false }
        }.count, 4)
        guard case .button(Self.left, Self.up, _, _, _)? = events.last else {
            return XCTFail("the drag must end with a left button-up: \(events)")
        }
        XCTAssertEqual(engine.lightRigJSON(), json, "a camera drag writes no light")
        XCTAssertNil(ui.active)
    }

    // MARK: hover

    /// Moving the pointer marks the target under it (knob, aim dot), nothing
    /// off the gizmo; leaving the view clears it. No pick runs.
    func testHoverMarksTheTargetUnderThePointer() throws {
        try enterGizmo()
        let l = try layout()
        let key = try XCTUnwrap(l.knob(named: "key"))
        let fill = try XCTUnwrap(l.knob(named: "fill"))

        let t = taps()
        try hover(key.centre)
        XCTAssertEqual(ui.hovered, .knob("key"))
        try hover(emptyPoint(in: l))
        XCTAssertNil(ui.hovered)
        try hover(fill.centre)
        XCTAssertEqual(ui.hovered, LightGizmoHitTest.target(at: fill.centre, layout: l))
        XCTAssertEqual(ui.hovered, .knob("fill"))
        XCTAssertEqual(t.python.lines, [], "hover runs no pick")
        view.mouseExited(with: try XCTUnwrap(NSEvent.enterExitEvent(
            with: .mouseExited, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: try XCTUnwrap(window).windowNumber,
            context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)))
        XCTAssertNil(ui.hovered, "leaving the view clears the hover")
        t.stop()
        XCTAssertEqual(t.events.list, [])
        XCTAssertEqual(controller.selection.name, "key", "hover selects nothing")
    }

    // MARK: scroll

    /// A wheel notch over a knob is one 0.5× radius step (forward: farther)
    /// with the radius readout; elsewhere it is today's bare-wheel button
    /// (clip). A trackpad scroll that begins over a knob selects that light
    /// and steps its radius per 24 pt, momentum swallowed; elsewhere it is
    /// today's pan.
    func testWheelOverAKnobStepsTheRadiusElsewhereClips() throws {
        try enterGizmo()
        let l = try layout()
        let key = try XCTUnwrap(l.knob(named: "key"))
        let fill = try XCTUnwrap(l.knob(named: "fill"))
        let empty = emptyPoint(in: l)
        let before = try rig()

        // A wheel notch over key.
        let notch = try scrollEvent(at: key.centre, deltaY: 1, units: .line)
        XCTAssertEqual(notch.phase, [])
        XCTAssertEqual(notch.momentumPhase, [])
        let wheel = notch.scrollingDeltaY != 0 ? notch.scrollingDeltaY : notch.deltaY
        XCTAssertNotEqual(wheel, 0)
        var t = taps()
        scroll(notch)
        t.stop()
        XCTAssertEqual(t.events.list, [], "a notch over a knob is not the camera's")
        XCTAssertEqual(t.python.lines, [])
        let stepped = try XCTUnwrap(LightSnap.nextRadius(from: before.lights[0].radius, up: wheel > 0))
        XCTAssertEqual(try rig().lights[0].radius, stepped, "one 0.5× step")
        XCTAssertEqual(ui.active, .knob("key"))
        XCTAssertEqual(ui.readout?.hasPrefix(LightParameter.radius.label), true, "\(ui.readout ?? "nil")")

        // A wheel notch elsewhere: today's bare-wheel button.
        t = taps()
        scroll(try scrollEvent(at: empty, deltaY: 1, units: .line))
        t.stop()
        guard t.events.list.count == 1, case .button(let button, Self.down, _, _, _) = t.events.list[0] else {
            return XCTFail("a notch off the gizmo is one scroll button: \(t.events.list)")
        }
        XCTAssertEqual(button, wheel > 0 ? Self.scrollForward : Self.scrollReverse)
        XCTAssertEqual(try rig().lights[0].radius, stepped, "the radius is kept")

        // A trackpad scroll that begins over fill: latched to its momentum's end.
        let fillBefore = try rig().lights[1].radius
        var sequence = [try scrollEvent(at: fill.centre, deltaY: 0, phase: .began)]
        for k in 0..<5 {
            // The pointer leaves the knob mid-scroll: still latched.
            let p = CGPoint(x: fill.centre.x + CGFloat(k) * 15, y: fill.centre.y)
            sequence.append(try scrollEvent(at: p, deltaY: 10, phase: .changed))
        }
        sequence.append(try scrollEvent(at: empty, deltaY: 0, phase: .ended))
        sequence.append(try scrollEvent(at: empty, deltaY: 6, momentum: .begin))
        sequence.append(try scrollEvent(at: empty, deltaY: 4, momentum: .continuous))
        sequence.append(try scrollEvent(at: empty, deltaY: 0, momentum: .end))
        XCTAssertEqual(sequence[0].phase, .began)
        XCTAssertEqual(sequence[1].phase, .changed)
        XCTAssertEqual(sequence[6].phase, .ended)
        XCTAssertEqual(sequence[9].momentumPhase, .ended)
        let total = sequence[0...5].reduce(CGFloat(0)) { $0 + $1.scrollingDeltaY }
        let steps = Int((total / LightGizmoMetrics().trackpadStep).rounded(.towardZero))
        XCTAssertNotEqual(steps, 0, "the scroll must cross at least one step (\(total) pt)")
        var expected = fillBefore
        for _ in 0..<abs(steps) {
            expected = try XCTUnwrap(LightSnap.nextRadius(from: expected, up: steps > 0))
        }
        t = taps()
        sequence.forEach(scroll)
        t.stop()
        XCTAssertEqual(t.events.list, [], "no pan: the scroll and its momentum are the gizmo's")
        XCTAssertEqual(t.python.lines, [])
        XCTAssertEqual(controller.selection.name, "fill", "a scroll on a knob selects its light")
        XCTAssertEqual(try rig().lights[1].radius, expected)
        XCTAssertNil(ui.active, "the readout goes when the fingers lift")

        // A trackpad scroll elsewhere: today's pan (middle button).
        t = taps()
        scroll(try scrollEvent(at: empty, deltaY: 0, phase: .began))
        scroll(try scrollEvent(at: empty, deltaY: 10, phase: .changed))
        scroll(try scrollEvent(at: empty, deltaY: 0, phase: .ended))
        scroll(try scrollEvent(at: empty, deltaY: 0, momentum: .end))
        t.stop()
        guard case .button(Self.middle, Self.down, _, _, _)? = t.events.list.first,
              case .button(Self.middle, Self.up, _, _, _)? = t.events.list.last else {
            return XCTFail("a scroll off the gizmo is today's pan: \(t.events.list)")
        }
        XCTAssertEqual(try rig().lights[1].radius, expected, "the pan keeps the radius")
        let after = try rig()
        for i in 0..<3 {
            XCTAssertEqual(after.lights[i].beam, before.lights[i].beam, "the beam is kept")
        }
    }

    // MARK: option-click

    /// An option-click on the molecule off every target runs one `lights
    /// <name>, click=` command and no atom pick; off the molecule it runs
    /// nothing; on a knob it selects that light. A plain click off the
    /// gizmo is still today's atom pick.
    func testOptionClickPlacesAHighlightOnAHitOnly() throws {
        try enterGizmo()
        var l = try layout()
        let p = try moleculePoint(in: l)
        let ndc = try XCTUnwrap(l.projection.sceneNDC(point: p))

        var t = taps()
        try press(p, option: true)
        try release(p, option: true)
        t.stop()
        XCTAssertEqual(t.events.list, [], "no atom pick and no button")
        XCTAssertEqual(t.commands.lines.count, 1, "\(t.commands.lines)")
        XCTAssertEqual(t.commands.lines.first?.hasPrefix("lights key, click="), true, "\(t.commands.lines)")
        if case .command(let command)? = LightsAction.highlight(name: "key", x: ndc.x, y: ndc.y, rim: nil,
                                                                pin: false).invocation {
            XCTAssertEqual(t.commands.lines, [command])
        } else {
            XCTFail("no highlight invocation")
        }
        XCTAssertEqual(engine.lightGizmoPointer.lastHighlight, .placed(rim: nil))
        XCTAssertEqual(try rig().lights[0].aim, .point, "aimed at the picked point")

        // Off the molecule: nothing runs, and still no atom pick.
        l = try layout()
        let empty = emptyPoint(in: l)
        let json = engine.lightRigJSON()
        t = taps()
        try press(empty, option: true)
        try dragTo(CGPoint(x: empty.x + 1, y: empty.y + 1), option: true)   // inside the drag slop
        try release(CGPoint(x: empty.x + 1, y: empty.y + 1), option: true)
        t.stop()
        XCTAssertEqual(engine.lightGizmoPointer.lastHighlight, .miss)
        XCTAssertEqual(t.events.list, [], "a miss runs no atom pick and sends no button")
        XCTAssertEqual(t.commands.lines, [])
        XCTAssertEqual(engine.lightRigJSON(), json)

        // On a knob: selects it, runs nothing.
        let fill = try XCTUnwrap(l.knob(named: "fill"))
        t = taps()
        try press(fill.centre, option: true)
        try release(fill.centre, option: true)
        t.stop()
        XCTAssertEqual(controller.selection.name, "fill")
        XCTAssertEqual(t.events.list, [])
        XCTAssertEqual(t.commands.lines, [])
        XCTAssertEqual(engine.lightRigJSON(), json)

        // An option-drag past the slop is today's camera drag.
        t = taps()
        try press(empty, option: true)
        try drag(from: empty, to: CGPoint(x: empty.x + 30, y: empty.y), steps: 3)
        try release(CGPoint(x: empty.x + 30, y: empty.y), option: true)
        t.stop()
        guard case .button(Self.left, Self.down, _, _, _)? = t.events.list.first,
              case .button(Self.left, Self.up, _, _, _)? = t.events.list.last else {
            return XCTFail("an option-drag is the camera's: \(t.events.list)")
        }
        XCTAssertEqual(t.commands.lines, [])

        // A plain click off the gizmo: today's atom pick.
        t = taps()
        try press(empty)
        try release(empty)
        t.stop()
        guard t.events.list.count == 1, case .pick = t.events.list[0] else {
            return XCTFail("a plain click is today's atom pick: \(t.events.list)")
        }
    }

    // MARK: Esc mid-drag

    /// Esc (Done) in the middle of a knob drag keeps the edits made so far;
    /// the rest of the drag writes nothing and, with the release, sends no
    /// PyMOL button (no camera drag from the press point, no atom pick). The
    /// next press is today's camera path again.
    func testEscMidDragSwallowsTheRestOfThePress() throws {
        try enterGizmo()
        let l = try layout()
        let key = try XCTUnwrap(l.knob(named: "key"))
        let before = try rig().lights[0]
        let target = CGPoint(x: l.centre.x - l.sphereRadius * 0.4, y: l.centre.y + l.sphereRadius * 0.3)

        let t = taps()
        try press(key.centre)
        let midway = lerp(key.centre, target, 0.5)
        try drag(from: key.centre, to: midway, steps: 4)
        let edited = try rig().lights[0]
        XCTAssertTrue(edited.orbit != before.orbit || edited.pitch != before.pitch, "the first ticks wrote")

        XCTAssertTrue(engine.exitActiveInteractionMode(), "Esc leaves Lights mode")
        XCTAssertEqual(engine.interactionMode, .viewing)
        XCTAssertTrue(engine.lightGizmoPointer.ownsPress, "the press is still the gizmo's")
        XCTAssertEqual(engine.lightGizmoPointer.session?.isEnded ?? true, true, "its session writes no more")
        try drag(from: midway, to: target, steps: 4)
        try release(target)
        XCTAssertEqual(t.events.list, [], "nothing after Esc reaches the camera or the atom pick")
        XCTAssertEqual(try rig().lights[0], edited, "Esc = Done: the edits stay, no more are made")
        XCTAssertFalse(engine.lightGizmoPointer.ownsPress)
        XCTAssertNil(ui.active)

        // The next press is the camera's again.
        let empty = CGPoint(x: 24, y: 24)
        try press(empty)
        try drag(from: empty, to: CGPoint(x: 60, y: 40), steps: 2)
        try release(CGPoint(x: 60, y: 40))
        t.stop()
        guard case .button(Self.left, Self.down, _, _, _)? = t.events.list.first,
              case .button(Self.left, Self.up, _, _, _)? = t.events.list.last else {
            return XCTFail("after the release the camera has the next drag: \(t.events.list)")
        }
    }

    // MARK: hover clear (#694)

    /// The hover clear skips its Python select when no preview has run since
    /// the last clear (#694). A press in Lights mode (and every idle clear)
    /// runs no Python.
    func testHoverClearRunsPythonOnlyAfterAPreview() throws {
        try LightsLive.requireEngine()
        let saved = engine.hoverPreviewEnabled
        defer { engine.hoverPreviewEnabled = saved }
        engine.hoverPreviewEnabled = true

        engine.clearHoverPreview()

        let t = taps()
        defer { t.stop() }

        engine.clearHoverPreview()
        XCTAssertEqual(t.python.lines, [], "an idle clear runs no Python")
        XCTAssertFalse(engine.hoverPreviewMayBeShown)

        // Wait past the hover throttle so the next hover fires on the leading edge.
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        engine.hoverPreview(0.9, 0.9, 1.0)
        XCTAssertTrue(engine.hoverPreviewMayBeShown)
        XCTAssertEqual(t.python.lines.count, 1)
        XCTAssertTrue(t.python.lines.first?.contains("hover_preview_at") == true, "\(t.python.lines)")

        t.python.lines = []
        engine.clearHoverPreview()
        XCTAssertEqual(t.python.lines.count, 1)
        XCTAssertTrue(t.python.lines.first?.contains("_preselect") == true, "\(t.python.lines)")

        engine.clearHoverPreview()
        XCTAssertEqual(t.python.lines.count, 1, "the second clear adds none")
    }

    // MARK: DEBUG size check

    #if DEBUG
    /// The overlay's size against the MTKView's bounds: a mismatch over half
    /// a point is logged once per Lights session (the overlay's size going
    /// back to nil re-arms it); a match logs nothing.
    func testOverlaySizeMismatchIsLoggedOnce() throws {
        try enterGizmo()
        let l = try layout()
        let points = [CGPoint(x: 30, y: 30), CGPoint(x: 60, y: 30), CGPoint(x: 90, y: 30), CGPoint(x: 120, y: 30)]
        for p in points { XCTAssertNil(LightGizmoHitTest.target(at: p, layout: l)) }

        ui.viewSize = viewSize
        try hover(points[0])
        XCTAssertEqual(coordinator.lightGizmoSizeCheck.count, 0, "the sizes agree")
        ui.viewSize = CGSize(width: viewSize.width - 10, height: viewSize.height + 0.25)
        try hover(points[1])
        try hover(points[2])
        XCTAssertEqual(coordinator.lightGizmoSizeCheck.count, 1, "logged once")
        XCTAssertEqual(coordinator.lightGizmoSizeCheck.lastLine,
                       String(format: "LightGizmo: overlay size %.1fx%.1f != viewport %.1fx%.1f",
                              viewSize.width - 10, viewSize.height + 0.25, viewSize.width, viewSize.height))
        ui.viewSize = nil   // the overlay went away (the mode ended): re-armed
        try hover(points[3])
        ui.viewSize = CGSize(width: viewSize.width + 3, height: viewSize.height)
        try hover(points[0])
        XCTAssertEqual(coordinator.lightGizmoSizeCheck.count, 2, "once per session")
        ui.viewSize = CGSize(width: viewSize.width + 0.4, height: viewSize.height - 0.4)
        var check = LightGizmoSizeCheck()
        XCTAssertNil(check.check(overlay: ui.viewSize, viewport: viewSize), "within half a point")
    }
    #endif
}
#endif
