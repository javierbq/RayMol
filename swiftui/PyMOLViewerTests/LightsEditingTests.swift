import Combine
import CoreGraphics
import XCTest
@testable import RayMol

/// The shared edit path of the selected light (#620; LightsEditing.swift) and
/// the controller's eye state (LightsController.swift), on fake seams
/// (FakeRigStore in LightsControllerTests.swift: the core's clamps, wrap,
/// anchor and shadow cap, and eye placements for pinned lights). The same
/// calls on the live engine are in LightsInspectorLiveTests (#620 Part 3);
/// lighting_inspector.py checks LightParameter.range against the core table.

// MARK: - LightParameter

final class LightParameterTests: XCTestCase {
    func testFieldsAreTheCoreNames() {
        XCTAssertEqual(LightParameter.allCases.map(\.field),
                       ["orbit", "pitch", "radius", "intensity", "warmth", "beam", "softness"])
    }

    func testRangesAreTheCores() {
        let expected: [LightParameter: ClosedRange<Double>] = [
            .orbit: -180...180, .pitch: -90...90, .radius: 0.5...8, .intensity: 0...4,
            .warmth: 1500...15000, .beam: 1...170, .softness: 0...1,
        ]
        for parameter in LightParameter.allCases {
            XCTAssertEqual(parameter.range, expected[parameter], parameter.field)
        }
    }

    func testOnlyOrbitWraps() {
        XCTAssertEqual(LightParameter.allCases.filter(\.wraps), [.orbit])
    }

    func testPlacementParameters() {
        XCTAssertEqual(LightParameter.allCases.filter(\.isPlacement), [.orbit, .pitch, .radius])
    }

    func testLabelsFollowDecision11() {
        XCTAssertEqual(LightParameter.allCases.map(\.label),
                       ["Orbit", "Pitch", "Radius", "Intensity", "Warmth", "Beam", "Softness"])
    }

    func testQuantaAndRounding() {
        let quanta: [LightParameter: Double] = [
            .orbit: 1, .pitch: 1, .radius: 0.01, .intensity: 0.01, .warmth: 10,
            .beam: 0.5, .softness: 0.01,
        ]
        for parameter in LightParameter.allCases {
            XCTAssertEqual(parameter.quantum, quanta[parameter], parameter.field)
        }
        XCTAssertEqual(LightParameter.orbit.rounded(-44.6), -45)
        XCTAssertEqual(LightParameter.radius.rounded(3.004), 3.0, accuracy: 1e-12)
        XCTAssertEqual(LightParameter.warmth.rounded(3804), 3800)
        XCTAssertEqual(LightParameter.beam.rounded(40.3), 40.5)
    }
}

// MARK: - LightAngles

final class LightAnglesTests: XCTestCase {
    func testOrbitOrientation() {
        // View coordinates, y down: the camera at the bottom.
        XCTAssertEqual(LightAngles.orbit(dx: 0, dy: 1), 0, accuracy: 1e-12)
        XCTAssertEqual(LightAngles.orbit(dx: 1, dy: 0), 90, accuracy: 1e-12)
        XCTAssertEqual(LightAngles.orbit(dx: 0, dy: -1), 180, accuracy: 1e-12)
        XCTAssertEqual(LightAngles.orbit(dx: -1, dy: 0), -90, accuracy: 1e-12)
        XCTAssertEqual(LightAngles.orbit(dx: -0.0, dy: -1), 180, accuracy: 1e-12,
                       "the top is +180, never -180")
        XCTAssertEqual(LightAngles.orbit(dx: 2, dy: 2), 45, accuracy: 1e-12)
    }

    func testPitchOrientation() {
        XCTAssertEqual(LightAngles.pitch(dx: 1, dy: 0), 0, accuracy: 1e-12)
        XCTAssertEqual(LightAngles.pitch(dx: 0, dy: -1), 90, accuracy: 1e-12)
        XCTAssertEqual(LightAngles.pitch(dx: 0, dy: 1), -90, accuracy: 1e-12)
        XCTAssertEqual(LightAngles.pitch(dx: 1, dy: -1), 45, accuracy: 1e-12)
        // The left half clamps to the nearer pole.
        XCTAssertEqual(LightAngles.pitch(dx: -1, dy: -0.5), 90)
        XCTAssertEqual(LightAngles.pitch(dx: -1, dy: 0.5), -90)
    }

    func testOffsetsInvertTheAngles() {
        for orbit in stride(from: -179.0, through: 180.0, by: 7.0) {
            let o = LightAngles.offset(orbit: orbit)
            XCTAssertEqual(o.dx * o.dx + o.dy * o.dy, 1, accuracy: 1e-12)
            XCTAssertEqual(LightAngles.orbit(dx: o.dx, dy: o.dy), orbit, accuracy: 1e-9)
        }
        for pitch in stride(from: -90.0, through: 90.0, by: 5.0) {
            let o = LightAngles.offset(pitch: pitch)
            XCTAssertEqual(LightAngles.pitch(dx: o.dx, dy: o.dy), pitch, accuracy: 1e-9)
        }
    }

    func testWrapMatchesTheCore() {
        XCTAssertEqual(LightAngles.wrap(190), -170)
        XCTAssertEqual(LightAngles.wrap(-180), 180)
        XCTAssertEqual(LightAngles.wrap(180), 180)
        XCTAssertEqual(LightAngles.wrap(0), 0)
        XCTAssertEqual(LightAngles.wrap(-190), 170)
        XCTAssertEqual(LightAngles.wrap(183), -177)
        XCTAssertEqual(LightAngles.wrap(720 + 45), 45)
        XCTAssertTrue(LightAngles.wrap(.nan).isNaN)
    }

    func testPlacementDifferenceGoesAroundTheCircle() {
        let a = LightPlacement(orbit: 180, pitch: 10, radius: 3)
        XCTAssertFalse(a.differs(from: LightPlacement(orbit: -180, pitch: 10, radius: 3), by: 1e-6))
        XCTAssertFalse(a.differs(from: LightPlacement(orbit: -179.99995, pitch: 10, radius: 3), by: 1e-4))
        XCTAssertTrue(a.differs(from: LightPlacement(orbit: 179.9, pitch: 10, radius: 3), by: 1e-4))
        XCTAssertTrue(a.differs(from: LightPlacement(orbit: 180, pitch: 10.001, radius: 3), by: 1e-4))
        XCTAssertTrue(a.differs(from: LightPlacement(orbit: 180, pitch: 10, radius: 3.001), by: 1e-4))
    }
}

// MARK: - LightColour

final class LightColourTests: XCTestCase {
    private func assertClose(_ a: SIMD3<Double>?, _ b: SIMD3<Double>, _ accuracy: Double,
                             _ message: String = "", line: UInt = #line) {
        guard let a else { return XCTFail("no colour \(message)", line: line) }
        for i in 0..<3 {
            XCTAssertEqual(a[i], b[i], accuracy: accuracy, "channel \(i) \(message)", line: line)
        }
    }

    func testSwatchesArePresetColours() {
        XCTAssertEqual(LightColour.swatches.map(\.name),
                       ["White", "Cyan", "Magenta", "Violet", "Green", "Red"])
        XCTAssertEqual(LightColour.swatches[3].rgb, SIMD3(0.5, 0.5, 1))
        XCTAssertEqual(LightColour.swatches[4].rgb, SIMD3(0.6, 1, 0.55))
    }

    func testSwatchesRoundTripAndSelectThemselves() {
        for (index, swatch) in LightColour.swatches.enumerated() {
            let back = LightColour.srgb(from: LightColour.cgColor(swatch.rgb))
            assertClose(back, swatch.rgb, 1e-6, swatch.name)
            XCTAssertEqual(back.flatMap(LightColour.swatchIndex(of:)), index, swatch.name)
        }
    }

    func testCustomColourRoundTrips() {
        let rgb = SIMD3(0.123, 0.456, 0.789)
        assertClose(LightColour.srgb(from: LightColour.cgColor(rgb)), rgb, 1e-6)
        XCTAssertNil(LightColour.swatchIndex(of: rgb))
    }

    func testDisplayP3EchoStillMatchesTheSwatch() throws {
        // A colour picker may hand back the colour in Display P3.
        let p3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        for (index, swatch) in LightColour.swatches.enumerated() {
            let echoed = try XCTUnwrap(LightColour.cgColor(swatch.rgb)
                .converted(to: p3, intent: .defaultIntent, options: nil))
            let back = try XCTUnwrap(LightColour.srgb(from: echoed), swatch.name)
            XCTAssertTrue(LightColour.matches(back, swatch.rgb), "\(swatch.name): \(back)")
            XCTAssertEqual(LightColour.swatchIndex(of: back), index, swatch.name)
        }
    }

    func testExtendedRangeClampsIntoUnit() throws {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedDisplayP3))
        let red = try XCTUnwrap(CGColor(colorSpace: space, components: [1.2, -0.1, 0, 1]))
        let rgb = try XCTUnwrap(LightColour.srgb(from: red))
        for i in 0..<3 {
            XCTAssertTrue((0...1).contains(rgb[i]), "channel \(i) = \(rgb[i])")
        }
        XCTAssertEqual(rgb.x, 1, accuracy: 1e-6)
    }

    func testGreyConverts() throws {
        let grey = CGColor(gray: 0.5, alpha: 1)
        let rgb = try XCTUnwrap(LightColour.srgb(from: grey))
        XCTAssertEqual(rgb.x, rgb.y, accuracy: 1e-6)
        XCTAssertEqual(rgb.y, rgb.z, accuracy: 1e-6)
        XCTAssertTrue((0.3...0.7).contains(rgb.x), "\(rgb)")
    }

    func testToleranceIsOneStep() {
        let base = SIMD3(0.5, 0.5, 0.5)
        XCTAssertTrue(LightColour.matches(base, base + SIMD3(1.0 / 255, 0, 0)))
        XCTAssertTrue(LightColour.matches(base, base - SIMD3(0, 0, 1.0 / 255)))
        XCTAssertFalse(LightColour.matches(base, base + SIMD3(2.0 / 255, 0, 0)))
        XCTAssertFalse(LightColour.matches(base, base + SIMD3(0, 0, 2.0 / 255)))
    }
}

// MARK: - WarmthScale

final class WarmthScaleTests: XCTestCase {
    func testEndpoints() {
        XCTAssertEqual(WarmthScale.position(kelvin: 1500), 0, accuracy: 1e-12)
        XCTAssertEqual(WarmthScale.position(kelvin: 15000), 1, accuracy: 1e-12)
        XCTAssertEqual(WarmthScale.kelvin(position: 0), 1500, accuracy: 1e-9)
        XCTAssertEqual(WarmthScale.kelvin(position: 1), 15000, accuracy: 1e-9)
        // Outside the range: clamped.
        XCTAssertEqual(WarmthScale.position(kelvin: 100), 0)
        XCTAssertEqual(WarmthScale.position(kelvin: 99999), 1, accuracy: 1e-12)
        XCTAssertEqual(WarmthScale.kelvin(position: 2), 15000, accuracy: 1e-9)
    }

    func testWarmRangeGetsMoreTrack() {
        XCTAssertEqual(WarmthScale.position(kelvin: 6500), 0.64, accuracy: 0.005)
        XCTAssertEqual(WarmthScale.position(kelvin: 3800), 0.40, accuracy: 0.005)
    }

    func testRoundTrip() {
        for k in stride(from: 1500.0, through: 15000.0, by: 250.0) {
            XCTAssertEqual(WarmthScale.kelvin(position: WarmthScale.position(kelvin: k)), k,
                           accuracy: 1e-9)
        }
    }
}

// MARK: - The typed edits

@MainActor
final class LightsEditTests: XCTestCase {
    private var store: FakeRigStore!
    private var controller: LightsController!

    override func setUp() {
        super.setUp()
        store = FakeRigStore()
        controller = LightsController(seams: store.seams)
        store.setRig(["key", "fill", "rim"])
        controller.begin()
    }

    override func tearDown() {
        controller = nil
        store = nil
        super.tearDown()
    }

    /// The fake store's light `name`.
    private func light(_ name: String) -> FakeRigStore.Light? {
        store.lights.first { $0.name == name }
    }

    func testSetWritesTheFieldOfTheSelectedLight() {
        controller.select(name: "fill")
        let values: [LightParameter: Double] = [
            .orbit: -45, .pitch: 35, .radius: 3, .intensity: 1.8, .warmth: 3800,
            .beam: 40, .softness: 0.5,
        ]
        for parameter in LightParameter.allCases {
            let before = store.numberWrites.count
            let value = values[parameter]!
            XCTAssertEqual(controller.set(parameter, value), .ok, parameter.field)
            XCTAssertEqual(store.numberWrites.count, before + 1, parameter.field)
            let write = store.numberWrites.last!
            XCTAssertEqual(write.index, 1)
            XCTAssertEqual(write.field, parameter.field)
            XCTAssertEqual(write.value, value)
            // The mirror shows it in the same turn.
            XCTAssertEqual(controller.value(parameter), value, parameter.field)
            XCTAssertEqual(controller.selectedLight.map { $0.value(of: parameter) }, value)
        }
        XCTAssertTrue(store.performed.isEmpty)
    }

    func testTheCoreClampsAndTheMirrorShowsIt() {
        for parameter in LightParameter.allCases where !parameter.wraps {
            XCTAssertEqual(controller.set(parameter, parameter.range.upperBound + 1), .ok)
            XCTAssertEqual(controller.value(parameter), parameter.range.upperBound, parameter.field)
            XCTAssertEqual(controller.set(parameter, parameter.range.lowerBound - 1), .ok)
            XCTAssertEqual(controller.value(parameter), parameter.range.lowerBound, parameter.field)
        }
        XCTAssertEqual(controller.set(.orbit, 200), .ok)
        XCTAssertEqual(controller.value(.orbit), -160)
        XCTAssertEqual(controller.set(.beam, .nan), .badValue)
    }

    func testStepUsesAFreshValue() {
        XCTAssertEqual(controller.set(.orbit, 10), .ok)
        // The console moves key behind the mirror's back; a second later the
        // step adds to the new value, not the mirrored 10.
        store.lights[0].orbit = 50
        store.clock += 1
        XCTAssertEqual(controller.step(.orbit, by: 5), .ok)
        XCTAssertEqual(store.lights[0].orbit, 55)
        XCTAssertEqual(controller.value(.orbit), 55)
        XCTAssertEqual(controller.step(.pitch, by: -5), .ok)
        XCTAssertEqual(store.lights[0].pitch, 25)
        XCTAssertEqual(controller.step(.intensity, by: 0.25), .ok)
        XCTAssertEqual(store.lights[0].intensity, 1.25)
    }

    func testOrbitStepWraps() {
        XCTAssertEqual(controller.set(.orbit, 178), .ok)
        XCTAssertEqual(controller.step(.orbit, by: 5), .ok)
        XCTAssertEqual(controller.value(.orbit), -177)
        XCTAssertEqual(controller.step(.orbit, by: -5), .ok)
        XCTAssertEqual(controller.value(.orbit), 178)
    }

    func testStepOnAPinnedLightReadsTheEyeNow() {
        XCTAssertEqual(controller.setPinned(true), .ok)
        // The camera turned: key's eye placement moved, no frame rendered yet.
        store.eyePlacements["key"] = LightPlacement(orbit: 40, pitch: 12, radius: 5)
        XCTAssertEqual(controller.value(.orbit), 0, "the published placement is a frame old")
        let eyeReads = store.eyeReads
        XCTAssertEqual(controller.step(.orbit, by: 5), .ok)
        XCTAssertEqual(store.numberWrites.last?.field, "orbit")
        XCTAssertEqual(store.numberWrites.last?.value, 45, "the step adds to the eye value")
        // One read on the press, one in the refresh after the write.
        XCTAssertEqual(store.eyeReads - eyeReads, 2)
        XCTAssertEqual(controller.placement(at: 0), LightPlacement(orbit: 45, pitch: 12, radius: 5))
        XCTAssertEqual(controller.selectedLight?.anchor, .pinned, "an orbit edit keeps it pinned")

        // A camera light's step reads no eye.
        controller.select(name: "fill")
        let reads = store.eyeReads
        XCTAssertEqual(controller.step(.orbit, by: 5), .ok)
        XCTAssertEqual(store.lights[1].orbit, 5)
        // key is still pinned, so the refresh after the write reads once.
        XCTAssertEqual(store.eyeReads - reads, 1)
    }

    func testSetPlacementWritesEachFieldAndRefreshesOnce() {
        controller.select(name: "rim")
        let reads = store.reads
        XCTAssertEqual(controller.setPlacement(orbit: 30, pitch: 20, radius: 2), .ok)
        XCTAssertEqual(store.numberWrites.map(\.field), ["pitch", "orbit", "radius"])
        XCTAssertEqual(store.numberWrites.map(\.index), [2, 2, 2])
        XCTAssertEqual(store.reads - reads, 1, "one mirror read after all three writes")
        XCTAssertEqual(controller.placement(at: 2), LightPlacement(orbit: 30, pitch: 20, radius: 2))

        // Only the given fields, still in that order.
        XCTAssertEqual(controller.setPlacement(orbit: -10, radius: 6), .ok)
        XCTAssertEqual(store.numberWrites.suffix(2).map(\.field), ["orbit", "radius"])
        XCTAssertEqual(controller.setPlacement(pitch: 5), .ok)
        XCTAssertEqual(store.numberWrites.last?.field, "pitch")
        // Nothing given: nothing written or read.
        let writes = store.numberWrites.count
        let reads2 = store.reads
        XCTAssertEqual(controller.setPlacement(), .ok)
        XCTAssertEqual(store.numberWrites.count, writes)
        XCTAssertEqual(store.reads, reads2)
    }

    func testSetPlacementStopsAtTheFirstFailure() {
        // The first write fails: nothing more is written and nothing re-read.
        var reads = store.reads
        XCTAssertEqual(controller.setPlacement(orbit: 30, pitch: .nan, radius: 2), .badValue)
        XCTAssertEqual(store.numberWrites.map(\.field), ["pitch"])
        XCTAssertEqual(store.reads, reads)
        XCTAssertEqual(store.lights[0].orbit, 0)

        // The second fails: the first stays written, one re-read, radius untouched.
        reads = store.reads
        XCTAssertEqual(controller.setPlacement(orbit: .infinity, pitch: 10, radius: 2), .badValue)
        XCTAssertEqual(store.numberWrites.suffix(2).map(\.field), ["pitch", "orbit"])
        XCTAssertEqual(store.reads - reads, 1)
        XCTAssertEqual(store.lights[0].pitch, 10)
        XCTAssertEqual(store.lights[0].radius, 4)
        XCTAssertEqual(controller.value(.pitch), 10)
    }

    func testSetPlacementKeepsTheIndex() {
        controller.select(name: "rim")
        // Something selects another light in the middle of the call: the rest
        // of the call still writes to the light it started on.
        let live: LightsController = controller
        store.afterNumberWrite = { [unowned live] in
            MainActor.assumeIsolated { live.select(index: 0) }
        }
        XCTAssertEqual(controller.setPlacement(orbit: 30, pitch: 20, radius: 2), .ok)
        store.afterNumberWrite = nil
        XCTAssertEqual(store.numberWrites.map(\.index), [2, 2, 2])
        XCTAssertEqual(store.lights[2].placement, LightPlacement(orbit: 30, pitch: 20, radius: 2))
        XCTAssertEqual(store.lights[0].placement, LightPlacement(orbit: 0, pitch: 30, radius: 4))
    }

    func testSetPlacementOnAPinnedLightGoesPitchFirst() {
        XCTAssertEqual(controller.setPinned(true), .ok)
        store.eyePlacements["key"] = LightPlacement(orbit: 0, pitch: 90, radius: 3)
        XCTAssertEqual(controller.setPlacement(orbit: 30, pitch: 20), .ok)
        XCTAssertEqual(store.numberWrites.suffix(2).map(\.field), ["pitch", "orbit"])
        XCTAssertEqual(controller.placement(at: 0), LightPlacement(orbit: 30, pitch: 20, radius: 3))
        XCTAssertEqual(controller.selectedLight?.anchor, .pinned)
    }

    func testSetColourSkipsAnEcho() {
        controller.select(name: "fill")
        XCTAssertEqual(controller.setColour(SIMD3(0, 1, 1)), .ok)
        XCTAssertEqual(store.vectorWrites.count, 1)
        XCTAssertEqual(store.vectorWrites.last?.index, 1)
        XCTAssertEqual(store.vectorWrites.last?.field, "color")
        XCTAssertEqual(controller.selectedLight?.color, SIMD3(0, 1, 1))

        // Within one 8-bit step: an echo, no write.
        XCTAssertEqual(controller.setColour(SIMD3(1.0 / 255, 1 - 0.5 / 255, 1)), .ok)
        XCTAssertEqual(store.vectorWrites.count, 1)
        // Two steps away: a real edit.
        XCTAssertEqual(controller.setColour(SIMD3(2.0 / 255, 1, 1)), .ok)
        XCTAssertEqual(store.vectorWrites.count, 2)

        // Inactive: refused, nothing written.
        controller.end()
        XCTAssertEqual(controller.setColour(SIMD3(1, 0, 0)), .badIndex)
        XCTAssertEqual(store.vectorWrites.count, 2)
    }

    func testSetPinnedWritesAnchor() {
        controller.select(name: "rim")
        XCTAssertEqual(controller.setPinned(true), .ok)
        XCTAssertEqual(store.numberWrites.last?.index, 2)
        XCTAssertEqual(store.numberWrites.last?.field, "anchor")
        XCTAssertEqual(store.numberWrites.last?.value, 1)
        XCTAssertEqual(controller.selectedLight?.anchor, .pinned)
        XCTAssertEqual(controller.setPinned(false), .ok)
        XCTAssertEqual(store.numberWrites.last?.value, 0)
        XCTAssertEqual(controller.selectedLight?.anchor, .camera)
    }

    func testUnpinKeepsWhereTheLightIsNow() {
        XCTAssertEqual(controller.setPinned(true), .ok)
        store.eyePlacements["key"] = LightPlacement(orbit: -70, pitch: 15, radius: 6)
        XCTAssertEqual(controller.setPinned(false), .ok)
        XCTAssertEqual(controller.selectedLight?.placement,
                       LightPlacement(orbit: -70, pitch: 15, radius: 6))
        XCTAssertEqual(controller.placement(at: 0), LightPlacement(orbit: -70, pitch: 15, radius: 6))
    }

    func testEditsRefusedWithoutASelectionOrWhenBusy() {
        store.busy = true
        XCTAssertFalse(controller.canEdit)
        XCTAssertEqual(controller.set(.beam, 20), .badIndex)
        XCTAssertEqual(controller.step(.beam, by: 1), .badIndex)
        XCTAssertEqual(controller.setPlacement(orbit: 1), .badIndex)
        XCTAssertEqual(controller.setColour(SIMD3(1, 0, 0)), .badIndex)
        XCTAssertEqual(controller.setPinned(true), .badIndex)
        store.busy = false
        XCTAssertTrue(controller.canEdit)

        controller.end()
        XCTAssertFalse(controller.canEdit)
        XCTAssertEqual(controller.set(.beam, 20), .badIndex)
        XCTAssertTrue(store.numberWrites.isEmpty)
        XCTAssertTrue(store.vectorWrites.isEmpty)

        // Active with no rig: nothing selected, nothing to edit.
        store = FakeRigStore()
        controller = LightsController(seams: store.seams)
        controller.begin()
        XCTAssertFalse(controller.canEdit)
        XCTAssertNil(controller.value(.orbit))
        XCTAssertEqual(controller.step(.orbit, by: 5), .badIndex)
    }

    func testTypedEditsUseOnlyTheBridge() {
        let presetLoads = store.presetLoads
        for tick in 0..<100 {
            let x = Double(tick)
            switch tick % 6 {
            case 0: XCTAssertEqual(controller.set(.orbit, x), .ok)
            case 1: XCTAssertEqual(controller.step(.radius, by: 0.01), .ok)
            case 2: XCTAssertEqual(controller.setPlacement(orbit: x, pitch: x / 4, radius: 2), .ok)
            case 3: XCTAssertEqual(controller.setColour(SIMD3(x / 100, 0.5, 1)), .ok)
            case 4: XCTAssertEqual(controller.setPinned(tick % 4 == 0), .ok)
            default: XCTAssertEqual(controller.set(.warmth, 2000 + x * 10), .ok)
            }
        }
        XCTAssertTrue(store.performed.isEmpty, "an edit must not run a command or Python")
        XCTAssertEqual(store.presetLoads, presetLoads)
        XCTAssertGreaterThan(store.numberWrites.count, 100)
    }

    // MARK: Revert this light

    func testRevertLightPerformsRestoreLightWithTheEntryJSON() throws {
        let entry = try XCTUnwrap(controller.entryJSON)
        controller.select(name: "fill")
        XCTAssertEqual(controller.set(.beam, 20), .ok)
        controller.select(name: "key")
        XCTAssertEqual(controller.set(.intensity, 3), .ok)
        XCTAssertTrue(controller.canRevertLight)
        controller.revertSelectedLight()
        XCTAssertEqual(store.performed, [.restoreLight(name: "key", json: entry)])
        XCTAssertEqual(light("key")?.intensity, 1)
        XCTAssertEqual(light("fill")?.beam, 20, "only that light comes back")
        XCTAssertEqual(controller.selection, LightSelection(name: "key", index: 0))
        XCTAssertFalse(controller.canRevertLight)
        XCTAssertTrue(controller.canRevert, "fill is still edited")

        // Unchanged: nothing is run.
        controller.revertSelectedLight()
        XCTAssertEqual(store.performed.count, 1)
    }

    func testCanRevertLightRules() {
        // Unchanged.
        XCTAssertFalse(controller.canRevertLight)
        XCTAssertEqual(controller.entryLight?.name, "key")
        // Edited.
        XCTAssertEqual(controller.set(.softness, 0.9), .ok)
        XCTAssertTrue(controller.canRevertLight)
        // Busy or inactive.
        store.busy = true
        XCTAssertFalse(controller.canRevertLight)
        store.busy = false
        XCTAssertTrue(controller.canRevertLight)

        // A light named since entry has nothing to go back to.
        store.lights.append(.init(name: "spot", intensity: 2))
        controller.refresh()
        controller.select(name: "spot")
        XCTAssertNil(controller.entryLight)
        XCTAssertFalse(controller.canRevertLight)
        controller.revertSelectedLight()
        XCTAssertTrue(store.performed.isEmpty)

        // A default name removed and added again counts as the entry light
        // (`lights add` reuses it), so it can be reverted once it differs.
        controller.select(name: "fill")
        controller.removeSelected()
        controller.add()
        XCTAssertEqual(controller.selectedLight?.name, "fill")
        XCTAssertEqual(controller.entryLight?.name, "fill")
        XCTAssertFalse(controller.canRevertLight, "a fresh fill equals the entry fill")
        XCTAssertEqual(controller.set(.beam, 90), .ok)
        XCTAssertTrue(controller.canRevertLight)

        controller.end()
        XCTAssertFalse(controller.canRevertLight)
        XCTAssertNil(controller.entryLight)
    }

    func testRevertLightMatchesNamesIgnoringCase() {
        XCTAssertEqual(controller.set(.beam, 120), .ok)
        store.lights[0].name = "KEY"
        controller.refresh()
        XCTAssertEqual(controller.entryLight?.name, "key")
        XCTAssertTrue(controller.canRevertLight)
    }

    func testRefusedRevertLightChangesNothing() throws {
        // Key had a shadow at entry; three other lights have one now.
        store.lights[0].shadow = true
        store.lights.append(.init(name: "light4"))
        controller.end()
        controller.begin()
        XCTAssertEqual(controller.writeNumbers([("shadow", 0)]), .ok)
        for name in ["fill", "rim", "light4"] {
            controller.select(name: name)
            XCTAssertEqual(controller.writeNumbers([("shadow", 1)]), .ok, name)
        }
        controller.select(name: "key")
        XCTAssertEqual(controller.writeNumbers([("shadow", 1)]), .refused, "a 4th shadow")
        let json = store.json
        XCTAssertTrue(controller.canRevertLight)
        controller.revertSelectedLight()
        XCTAssertEqual(store.json, json)
        XCTAssertEqual(controller.selection.name, "key")
    }
}

// MARK: - The eye state

@MainActor
final class LightsEyeStateTests: XCTestCase {
    private var store: FakeRigStore!
    private var controller: LightsController!

    override func setUp() {
        super.setUp()
        store = FakeRigStore()
        controller = LightsController(seams: store.seams)
        store.setRig(["key", "fill", "rim"])
        store.lights[1].orbit = -60
        store.lights[1].pitch = 20
        store.lights[2].radius = 2.5
    }

    override func tearDown() {
        controller = nil
        store = nil
        super.tearDown()
    }

    /// Pin `name` in the store (behind the controller's back), at `eye`.
    private func pin(_ name: String, at eye: LightPlacement) {
        let index = store.lights.firstIndex { $0.name == name }!
        store.lights[index].pinned = true
        store.eyePlacements[name] = eye
    }

    func testPlacementsCameraLightsUseStoredValues() {
        controller.begin()
        XCTAssertEqual(controller.eye.placements, store.lights.map(\.placement))
        XCTAssertEqual(store.eyeReads, 0, "no pinned light: no eye read")
        XCTAssertNil(controller.eye.eyeSpace)
    }

    func testPlacementsPinnedLightsUseEyeSpace() {
        pin("rim", at: LightPlacement(orbit: 150, pitch: -10, radius: 7))
        controller.begin()
        XCTAssertEqual(controller.eye.placements, [
            store.lights[0].placement, store.lights[1].placement,
            LightPlacement(orbit: 150, pitch: -10, radius: 7),
        ])
        controller.select(name: "rim")
        XCTAssertEqual(controller.value(.orbit), 150)
        XCTAssertEqual(controller.value(.radius), 7)
        XCTAssertEqual(controller.selectedLight?.orbit, 0, "the stored value is the last placed one")
        XCTAssertNil(controller.eye.eyeSpace, "published only in .everyFrame")
    }

    func testRefreshReadsEyeOnlyWithAPinnedLight() {
        controller.begin()
        XCTAssertEqual(controller.set(.beam, 30), .ok)
        XCTAssertEqual(store.eyeReads, 0)

        XCTAssertEqual(controller.setPinned(true), .ok)
        XCTAssertEqual(store.eyeReads, 1)
        // An orbit edit on the pinned light shows in the same turn.
        XCTAssertEqual(controller.set(.orbit, 25), .ok)
        XCTAssertEqual(store.eyeReads, 2)
        XCTAssertEqual(controller.placement(at: 0)?.orbit, 25)
        // An unchanged refresh reads nothing.
        controller.refresh()
        XCTAssertEqual(store.eyeReads, 2)
    }

    func testFrameRenderedNoReadWithoutPinOrDemand() {
        controller.begin()
        let reads = store.reads
        for _ in 0..<10 { controller.frameRendered() }
        XCTAssertEqual(store.eyeReads, 0)
        XCTAssertEqual(store.reads, reads, "no JSON read either")

        // Inactive, busy or not ready: nothing even with a pinned light.
        pin("key", at: LightPlacement(orbit: 1, pitch: 2, radius: 3))
        controller.refresh()
        let eyeReads = store.eyeReads
        store.busy = true
        controller.frameRendered()
        store.busy = false
        store.ready = false
        controller.frameRendered()
        store.ready = true
        controller.end()
        controller.frameRendered()
        XCTAssertEqual(store.eyeReads, eyeReads)
    }

    func testFrameRenderedFollowsAPinnedLight() {
        pin("key", at: LightPlacement(orbit: 10, pitch: 20, radius: 3))
        controller.begin()
        let reads = store.reads
        // The camera turns: each rendered frame reads the eye once.
        for step in 1...30 {
            store.eyePlacements["key"] = LightPlacement(orbit: 10 + Double(step), pitch: 20, radius: 3)
            let eyeReads = store.eyeReads
            controller.frameRendered()
            XCTAssertEqual(store.eyeReads - eyeReads, 1)
            XCTAssertEqual(controller.placement(at: 0)?.orbit, 10 + Double(step))
        }
        XCTAssertEqual(store.reads, reads, "a consistent read re-reads no JSON")
    }

    func testFrameRenderedPublishesOnlyOnChange() {
        pin("key", at: LightPlacement(orbit: 10, pitch: 20, radius: 3))
        controller.begin()
        var eyeChanges = 0
        var controllerChanges = 0
        let eyeSink = controller.eye.objectWillChange.sink { eyeChanges += 1 }
        let controllerSink = controller.objectWillChange.sink { controllerChanges += 1 }
        defer {
            eyeSink.cancel()
            controllerSink.cancel()
        }
        for _ in 0..<10 { controller.frameRendered() }
        XCTAssertEqual(eyeChanges, 0, "nothing moved")

        // Below the publish threshold (float noise): nothing.
        store.eyePlacements["key"] = LightPlacement(orbit: 10.00005, pitch: 20, radius: 3)
        controller.frameRendered()
        XCTAssertEqual(eyeChanges, 0)

        store.eyePlacements["key"] = LightPlacement(orbit: 15, pitch: 20, radius: 3)
        controller.frameRendered()
        XCTAssertEqual(eyeChanges, 1)
        controller.frameRendered()
        XCTAssertEqual(eyeChanges, 1)
        XCTAssertEqual(controllerChanges, 0,
                       "a per-frame update must not re-render the controller's observers (the bar)")
    }

    func testFrameRenderedRefreshesWhenALightIsRemovedBehindItsBack() {
        pin("rim", at: LightPlacement(orbit: 100, pitch: 0, radius: 3))
        controller.begin()
        XCTAssertEqual(controller.eye.placements.count, 3)
        var published: [[LightPlacement]] = []
        let sink = controller.eye.$placements.dropFirst().sink { published.append($0) }
        defer { sink.cancel() }

        // The console removes fill; no refresh yet.
        store.removeLight("fill")
        let reads = store.reads
        controller.frameRendered()
        XCTAssertEqual(store.reads - reads, 1, "the mismatch re-reads the rig")
        XCTAssertEqual(controller.rig?.lights.map(\.name), ["key", "rim"])
        XCTAssertEqual(controller.eye.placements.count, 2)
        XCTAssertEqual(controller.eye.placements[1], LightPlacement(orbit: 100, pitch: 0, radius: 3))
        // Only placements matching a rig were ever published.
        XCTAssertEqual(published.map(\.count), [2])
    }

    func testFrameRenderedRefreshesOnAnchorMismatch() {
        pin("rim", at: LightPlacement(orbit: 100, pitch: 0, radius: 3))
        controller.begin()
        // The console pins key behind the mirror's back.
        pin("key", at: LightPlacement(orbit: -20, pitch: 5, radius: 4))
        let reads = store.reads
        controller.frameRendered()
        XCTAssertEqual(store.reads - reads, 1)
        XCTAssertEqual(controller.rig?.lights[0].anchor, .pinned)
        XCTAssertEqual(controller.placement(at: 0), LightPlacement(orbit: -20, pitch: 5, radius: 4))
    }

    func testFrameRenderedRefreshesOnCameraLightDrift() {
        pin("rim", at: LightPlacement(orbit: 100, pitch: 0, radius: 3))
        controller.begin()
        store.lights[0].orbit = 33
        let reads = store.reads
        controller.frameRendered()
        XCTAssertEqual(store.reads - reads, 1)
        XCTAssertEqual(controller.placement(at: 0)?.orbit, 33)
    }

    func testAStaleEyeReadIsNeverPublished() throws {
        pin("rim", at: LightPlacement(orbit: 100, pitch: 0, radius: 3))
        controller.begin()
        let stored = controller.eye.placements
        // An eye read that disagrees with the rig while the JSON does not
        // change: re-read, and the pinned light falls back to its stored
        // values rather than another light's numbers.
        var stale = try XCTUnwrap(store.eyeSpace)
        stale.lights.swapAt(0, 2)
        store.eyeOverride = .some(stale)
        let reads = store.reads
        controller.frameRendered()
        XCTAssertEqual(store.reads - reads, 1)
        XCTAssertEqual(controller.eye.placements[0], stored[0])
        XCTAssertEqual(controller.eye.placements[2], store.lights[2].placement)

        // No read at all while the rig has lights: the same.
        store.eyeOverride = .some(nil)
        controller.frameRendered()
        XCTAssertEqual(controller.eye.placements[2], store.lights[2].placement)

        store.eyeOverride = .none
        controller.frameRendered()
        XCTAssertEqual(controller.eye.placements[2], LightPlacement(orbit: 100, pitch: 0, radius: 3))
    }

    func testEveryFrameDemandPublishesEyeSpace() {
        controller.begin()
        controller.eyeDemand = .everyFrame
        // No pinned light, but every frame is asked for.
        controller.frameRendered()
        XCTAssertEqual(store.eyeReads, 1)
        XCTAssertEqual(controller.eye.eyeSpace, store.eyeSpace)
        XCTAssertEqual(controller.eye.eyeSpace?.lights.count, 3)

        // An edit refreshes it in the same turn (what #622 projects).
        XCTAssertEqual(controller.set(.beam, 90), .ok)
        let cosOuter = Float(cos(45 * Double.pi / 180))
        XCTAssertEqual(controller.eye.eyeSpace?.lights[0].cosOuter ?? 0, cosOuter, accuracy: 1e-6)

        // Back to pinned-only: cleared, and no more reads.
        controller.eyeDemand = .pinnedOnly
        XCTAssertNil(controller.eye.eyeSpace)
        let reads = store.eyeReads
        controller.frameRendered()
        XCTAssertEqual(store.eyeReads, reads)
    }

    func testPinnedOnlyDemandKeepsEyeSpaceNil() {
        pin("key", at: LightPlacement(orbit: 10, pitch: 20, radius: 3))
        controller.begin()
        for orbit in [11.0, 12, 13] {
            store.eyePlacements["key"] = LightPlacement(orbit: orbit, pitch: 20, radius: 3)
            controller.frameRendered()
            XCTAssertNil(controller.eye.eyeSpace)
        }
        XCTAssertEqual(controller.placement(at: 0)?.orbit, 13)
    }

    func testEndClearsEye() {
        pin("key", at: LightPlacement(orbit: 10, pitch: 20, radius: 3))
        controller.begin()
        controller.eyeDemand = .everyFrame
        controller.frameRendered()
        XCTAssertFalse(controller.eye.placements.isEmpty)
        XCTAssertNotNil(controller.eye.eyeSpace)
        controller.end()
        XCTAssertTrue(controller.eye.placements.isEmpty)
        XCTAssertNil(controller.eye.eyeSpace)
        XCTAssertNil(controller.placement(at: 0))
        // value() falls back to the stored values while the mode is off.
        controller.refresh()
        XCTAssertTrue(controller.eye.placements.isEmpty, "nothing rebuilt while inactive")

        // Entering again with an unchanged rig rebuilds them.
        controller.eyeDemand = .pinnedOnly
        controller.begin()
        XCTAssertEqual(controller.eye.placements.count, 3)
        XCTAssertEqual(controller.placement(at: 0), LightPlacement(orbit: 10, pitch: 20, radius: 3))
    }

    func testRemovingTheRigClearsPlacements() {
        controller.begin()
        XCTAssertEqual(controller.eye.placements.count, 3)
        store.exists = false
        store.lights = []
        controller.refresh()
        XCTAssertTrue(controller.eye.placements.isEmpty)
        controller.eyeDemand = .everyFrame
        controller.frameRendered()
        XCTAssertNil(controller.eye.eyeSpace)
    }

    func testConsistencyRule() throws {
        controller.begin()
        let rig = try XCTUnwrap(controller.rig)
        var read = try XCTUnwrap(store.eyeSpace)
        XCTAssertTrue(LightsController.eye(read, isConsistentWith: rig))
        XCTAssertTrue(LightsController.eye(nil, isConsistentWith: nil))
        XCTAssertFalse(LightsController.eye(nil, isConsistentWith: rig))
        // Float rounding of a camera light is not drift.
        read.lights[1].orbit += 0.0005
        XCTAssertTrue(LightsController.eye(read, isConsistentWith: rig))
        read.lights[1].orbit += 0.01
        XCTAssertFalse(LightsController.eye(read, isConsistentWith: rig))
        read = try XCTUnwrap(store.eyeSpace)
        read.lights[2].anchor = .pinned
        XCTAssertFalse(LightsController.eye(read, isConsistentWith: rig))
        read = try XCTUnwrap(store.eyeSpace)
        read.lights.removeLast()
        XCTAssertFalse(LightsController.eye(read, isConsistentWith: rig))
    }
}
