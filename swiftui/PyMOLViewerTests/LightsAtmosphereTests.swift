import XCTest
@testable import RayMol

// The Atmosphere card's model (#726, LightsAtmosphere.swift) and the air half
// of LightsController, on the FakeRigStore (LightsControllerTests.swift):
// the field table, the slider grid and its square-root track, the number
// text, the typed field, the hints, the card's state, the setter path at
// index -1 (no Python per tick), the On/Off switch and its per-visit memory,
// and the mirroring with Revert.
//
// The same paths against the live engine are in LightsAtmosphereLiveTests;
// the command strings in LightsModeTests (LightsActionInvocationTests); the
// Python half in testing/tests/raymol/lighting_atmosphere.py.

// MARK: - The field table

final class AirFieldDecodeTests: XCTestCase {
    /// What appkit_lights.write_air_fields writes today, byte for byte:
    /// lighting_atmosphere.py HELPER_JSON holds the same literal (change both
    /// together).
    static let helperJSON =
        #"[{"name": "haze", "kind": "float", "default": 0.0, "min": 0.0, "max": 1.0}, "#
        + #"{"name": "dust", "kind": "float", "default": 0.0, "min": 0.0, "max": 1.0}, "#
        + #"{"name": "dust_size", "kind": "float", "default": 0.35, "min": 0.05, "max": 2.0}, "#
        + #"{"name": "dust_speed", "kind": "float", "default": 1.0, "min": 0.0, "max": 10.0}, "#
        + #"{"name": "scatter", "kind": "float", "default": 0.55, "min": -0.9, "max": 0.9}, "#
        + #"{"name": "seed", "kind": "int", "default": 0, "min": 0, "max": 1000000}]"#

    func testDecodesTheHelperJSON() throws {
        let fields = try AirField.decodeList(Data(Self.helperJSON.utf8))
        XCTAssertEqual(fields.map(\.name), ["haze", "dust", "dust_size", "dust_speed", "scatter", "seed"])
        XCTAssertEqual(fields.map(\.kind), ["float", "float", "float", "float", "float", "int"])
        XCTAssertEqual(fields.map(\.defaultValue), [0, 0, 0.35, 1, 0.55, 0])
        XCTAssertEqual(fields.map(\.range), [0...1, 0...1, 0.05...2, 0...10, -0.9...0.9, 0...1_000_000])
        XCTAssertEqual(fields, FakeRigStore.airTable, "the fake's table is the helper's")
    }

    func testEveryParameterHasARow() throws {
        let fields = try AirField.decodeList(Data(Self.helperJSON.utf8))
        for parameter in AirParameter.allCases {
            let field = fields.first { $0.name == parameter.field }
            XCTAssertEqual(field?.kind, "float", parameter.field)
        }
        XCTAssertEqual(AirValue.commandFields, fields.map(\.name),
                       "the command's fields are the table's air fields, in order")
    }

    func testBadRowsThrow() {
        let bad = [
            #"[{"name": "haze", "kind": "float", "default": 0.0, "min": 1.0, "max": 0.0}]"#,
            #"[{"name": "haze", "kind": "float", "default": 0.0, "min": 0.0}]"#,
            #"[{"name": "haze", "kind": "float", "default": "x", "min": 0.0, "max": 1.0}]"#,
            #"{"name": "haze"}"#,
            "",
        ]
        for json in bad {
            XCTAssertThrowsError(try AirField.decodeList(Data(json.utf8)), json)
        }
    }
}

// MARK: - Parameters and the slider grid

final class AirParameterTests: XCTestCase {
    private func field(_ p: AirParameter) -> AirField {
        FakeRigStore.airTable.first { $0.name == p.field }!
    }

    /// The text of a slider value: an optional minus, digits, at most two
    /// decimals (lighting_atmosphere.py TWO_DECIMALS).
    private func isShort(_ text: String) -> Bool {
        text.range(of: #"^-?\d+(\.\d{1,2})?$"#, options: .regularExpression) != nil
    }

    func testLabelsFieldsAndValues() {
        XCTAssertEqual(AirParameter.allCases.map(\.field), ["haze", "dust", "dust_size", "dust_speed", "scatter"])
        XCTAssertEqual(AirParameter.allCases.map(\.label),
                       ["Haze", "Dust", "Dust size", "Dust speed", "Scatter (g)"])
        let air = LightRigSnapshot.Air(haze: 0.1, dust: 0.2, dustSize: 0.3, dustSpeed: 0.4,
                                       scatter: -0.5, seed: 6)
        XCTAssertEqual(AirParameter.allCases.map { $0.value(in: air) }, [0.1, 0.2, 0.3, 0.4, -0.5])
        XCTAssertEqual(air.value(of: "seed"), 6)
        XCTAssertEqual(air.value(of: "dust_speed"), 0.4)
        XCTAssertNil(air.value(of: "fog"))
    }

    func testEverySliderStopPrintsAtMostTwoDecimals() {
        for p in AirParameter.allCases {
            let f = field(p)
            let first = Int((f.min * p.stepsPerUnit).rounded())
            let last = Int((f.max * p.stepsPerUnit).rounded())
            for k in first...last {
                let exact = Double(k) / p.stepsPerUnit
                // The slider position that stands for this stop, then what a
                // tick there writes.
                let value = p.sliderValue(p.sliderPosition(exact, f), f)
                XCTAssertEqual(value, exact, "\(p.field) stop \(k)")
                let text = AirValue(p.field, value).text
                XCTAssertTrue(isShort(text), "\(p.field) stop \(k): \(text)")
                XCTAssertEqual(Double(text), value, "\(p.field) \(text) reads back")
            }
            // Positions between stops land on a stop too.
            let range = p.sliderRange(f)
            for i in 0...997 {
                let position = range.lowerBound + (range.upperBound - range.lowerBound) * Double(i) / 997
                let value = p.sliderValue(position, f)
                XCTAssertTrue(f.range.contains(value), "\(p.field) \(position) -> \(value)")
                XCTAssertTrue(isShort(AirValue(p.field, value).text), "\(p.field) \(value)")
            }
        }
    }

    func testRoundedIsTheNearestDoubleToTheStop() {
        XCTAssertEqual(AirParameter.haze.rounded(0.35000000000000003), 0.35)
        XCTAssertEqual(String(describing: AirParameter.haze.rounded(0.1 + 0.2 + 0.05)), "0.35")
        XCTAssertEqual(AirParameter.dustSpeed.rounded(1.024), 1.0)
        XCTAssertEqual(AirParameter.dustSpeed.rounded(1.026), 1.05)
        XCTAssertEqual(AirParameter.scatter.rounded(-0.254), -0.25)
        let zero = AirParameter.scatter.rounded(-0.001)
        XCTAssertEqual(zero, 0)
        XCTAssertEqual(zero.sign, .plus, "no -0.0 in the command")
    }

    func testLinearTracksAreTheTableRange() {
        for p in [AirParameter.haze, .dust, .dustSize, .scatter] {
            let f = field(p)
            XCTAssertFalse(p.usesSquareRootTrack)
            XCTAssertEqual(p.sliderRange(f), f.range)
            XCTAssertEqual(p.sliderPosition(f.max + 5, f), f.max, "clamped")
            XCTAssertEqual(p.sliderPosition(f.min - 5, f), f.min, "clamped")
            XCTAssertEqual(p.sliderValue(f.max + 5, f), f.max)
            XCTAssertEqual(p.sliderValue(f.min - 5, f), f.min)
        }
    }

    func testDustSpeedRunsOnASquareRootTrack() {
        let p = AirParameter.dustSpeed
        let f = field(p)
        XCTAssertTrue(p.usesSquareRootTrack)
        XCTAssertEqual(p.sliderRange(f), 0...1)
        // The ends are exact.
        XCTAssertEqual(p.sliderValue(0, f), f.min)
        XCTAssertEqual(p.sliderValue(1, f), f.max)
        XCTAssertEqual(p.sliderPosition(f.min, f), 0)
        XCTAssertEqual(p.sliderPosition(f.max, f), 1)
        XCTAssertEqual(p.sliderValue(-0.5, f), f.min, "clamped")
        XCTAssertEqual(p.sliderValue(1.5, f), f.max, "clamped")
        // Real time (1.0) at about 32% of the track, not 10%.
        XCTAssertEqual(p.sliderPosition(1, f), 0.1.squareRoot(), accuracy: 1e-12)
        XCTAssertEqual(p.sliderPosition(1, f), 0.316, accuracy: 0.001)
        // position(value(p)) is p within the half-step the grid moves it.
        for i in 0...100 {
            let position = Double(i) / 100
            let back = p.sliderPosition(p.sliderValue(position, f), f)
            let value = f.min + (f.max - f.min) * position * position
            let halfStep = 0.5 / p.stepsPerUnit
            let lo = ((max(value - halfStep, f.min) - f.min) / (f.max - f.min)).squareRoot()
            let hi = ((min(value + halfStep, f.max) - f.min) / (f.max - f.min)).squareRoot()
            XCTAssertTrue(back >= lo - 1e-12 && back <= hi + 1e-12, "\(position) -> \(back)")
        }
    }
}

// MARK: - Formatting

final class AtmosphereFormatTests: XCTestCase {
    func testText() {
        XCTAssertEqual(AtmosphereFormat.text(.haze, 0.25), "0.25")
        XCTAssertEqual(AtmosphereFormat.text(.haze, 0), "0.00")
        XCTAssertEqual(AtmosphereFormat.text(.dustSpeed, 10), "10.00")
        XCTAssertEqual(AtmosphereFormat.text(.dustSize, 0.355), "0.36")
        XCTAssertEqual(AtmosphereFormat.text(.scatter, -0.3), "\u{2212}0.30")
        XCTAssertEqual(AtmosphereFormat.text(.scatter, 0.55), "0.55")
        XCTAssertEqual(AtmosphereFormat.text(.scatter, -0.001), "0.00", "never −0.00")
    }

    func testSpoken() {
        XCTAssertEqual(AtmosphereFormat.spoken(.haze, 0.25), "0.25")
        XCTAssertEqual(AtmosphereFormat.spoken(.scatter, -0.3), "-0.30")
        XCTAssertEqual(AtmosphereFormat.spoken(.scatter, -0.001), "0.00")
    }

    func testParse() {
        let good: [(String, Double)] = [
            ("0.4", 0.4), (" 0.4 ", 0.4), ("+0.5", 0.5), ("-0.25", -0.25),
            ("\u{2212}0.25", -0.25), ("2×", 2), ("2 ×", 2), (".5", 0.5), ("1e-3", 0.001), ("7", 7),
            ("1.5\n", 1.5),
        ]
        for (text, value) in good {
            XCTAssertEqual(AtmosphereFormat.parse(text), value, text)
        }
        for text in ["", " ", "abc", "nan", "inf", "1e999", "0.4°", "1,5", "--1", "×"] {
            XCTAssertNil(AtmosphereFormat.parse(text), text)
        }
    }
}

// MARK: - The typed field

final class AirFieldEditorTests: XCTestCase {
    func testShowFollowsTheModelUntilTheUserTypes() {
        var editor = AirFieldEditor(parameter: .haze)
        editor.show(0.25)
        XCTAssertEqual(editor.text, "0.25")
        editor.begin()
        XCTAssertTrue(editor.isEditing)
        editor.show(0.3)
        XCTAssertEqual(editor.text, "0.30", "focus alone keeps following the model")
        editor.type("0.4")
        editor.show(0.5)
        XCTAssertEqual(editor.text, "0.4", "typed text is kept while the model moves")
        XCTAssertEqual(editor.commit(), 0.4)
        XCTAssertEqual(editor.text, "0.40")
        XCTAssertFalse(editor.isEditing)
        XCTAssertFalse(editor.typed)
    }

    func testCommitWithoutTypingWritesNothing() {
        var editor = AirFieldEditor(parameter: .dust)
        editor.show(0.5)
        editor.begin()
        XCTAssertNil(editor.commit())
        XCTAssertEqual(editor.text, "0.50")
    }

    func testUnparseableTextBringsTheModelBack() {
        var editor = AirFieldEditor(parameter: .scatter)
        editor.show(-0.25)
        editor.begin()
        editor.type("abc")
        XCTAssertNil(editor.commit())
        XCTAssertEqual(editor.text, "\u{2212}0.25")
    }

    func testTypedValuesPassUnrounded() {
        var editor = AirFieldEditor(parameter: .dustSize)
        editor.show(0.35)
        editor.begin()
        editor.type("0.123456")
        XCTAssertEqual(editor.commit(), 0.123456, "a typed value is not put on the slider grid")
    }

    func testTheSliderMovingDropsTypedText() {
        var editor = AirFieldEditor(parameter: .haze)
        editor.show(0.2)
        editor.begin()
        editor.type("0.9")
        editor.sliderMoved(value: 0.33)
        XCTAssertEqual(editor.text, "0.33")
        XCTAssertFalse(editor.isEditing)
        XCTAssertFalse(editor.typed)
        XCTAssertNil(editor.commit(), "a later Return must not write the stale 0.9 over the drag")
        XCTAssertEqual(editor.text, "0.33")
    }

    func testTypingWithoutFocusIsNotAnEdit() {
        var editor = AirFieldEditor(parameter: .haze)
        editor.show(0.2)
        editor.type("0.7")
        XCTAssertFalse(editor.typed)
        XCTAssertNil(editor.commit())
        XCTAssertEqual(editor.text, "0.20")
    }
}

// MARK: - Start state

final class AtmosphereStartTests: XCTestCase {
    func testStartsExpanded() {
        XCTAssertFalse(LightsAtmosphereStart.collapsed.startsExpanded(airIsOn: true))
        XCTAssertFalse(LightsAtmosphereStart.collapsed.startsExpanded(airIsOn: false))
        XCTAssertTrue(LightsAtmosphereStart.expanded.startsExpanded(airIsOn: false))
        XCTAssertTrue(LightsAtmosphereStart.expanded.startsExpanded(airIsOn: true))
        XCTAssertTrue(LightsAtmosphereStart.expandedIfOn.startsExpanded(airIsOn: true))
        XCTAssertFalse(LightsAtmosphereStart.expandedIfOn.startsExpanded(airIsOn: false))
    }
}

// MARK: - Shared fixture

/// A controller over a FakeRigStore, for the controller-level tests below.
@MainActor
class AtmosphereControllerCase: XCTestCase {
    var store: FakeRigStore!
    var controller: LightsController!

    override func setUp() {
        super.setUp()
        store = FakeRigStore()
        controller = LightsController(seams: store.seams)
    }

    override func tearDown() {
        controller = nil
        store = nil
        super.tearDown()
    }

    /// Enter Lights mode with these lights (nil: no rig) and this air.
    func begin(_ lights: [String]?, enabled: Bool = true,
               air: LightRigSnapshot.Air = FakeRigStore.defaultAir) {
        if let lights {
            store.setRig(lights, enabled: enabled)
            store.air = air
        }
        controller.begin()
    }

    /// Haze 0.3, dust 0.4, dust size 0.6, dust speed 2.5, scatter -0.25,
    /// seed 7: an air away from every default.
    static let remembered = LightRigSnapshot.Air(haze: 0.3, dust: 0.4, dustSize: 0.6, dustSpeed: 2.5,
                                                 scatter: -0.25, seed: 7)

    var state: AtmosphereCardState? { AtmosphereCardState(controller) }
}

// MARK: - The card's state

final class AtmosphereCardStateTests: AtmosphereControllerCase {
    func testNilWhileInactive() {
        store.setRig(["key"])
        XCTAssertNil(state)
        controller.begin()
        XCTAssertNotNil(state)
        controller.end()
        XCTAssertNil(state)
    }

    func testTheTableLoadsWithThePresetsOnEntry() {
        XCTAssertTrue(controller.airFields.isEmpty)
        begin(["key"])
        XCTAssertEqual(controller.airFields, FakeRigStore.airTable)
        XCTAssertEqual(store.airFieldLoads, 1)
        controller.end()
        controller.begin()
        XCTAssertEqual(store.airFieldLoads, 1, "cached after the first load")
    }

    func testAnEmptyTableIsRetriedOnTheNextEntry() {
        store.airFieldList = []
        begin(["key"])
        XCTAssertTrue(controller.airFields.isEmpty)
        XCTAssertFalse(controller.canToggleAir)
        XCTAssertFalse(controller.canEditAir)
        let s = state!
        XCTAssertTrue(s.rows.isEmpty)
        XCTAssertTrue(s.isUnavailable)
        XCTAssertFalse(s.canToggle)
        XCTAssertFalse(s.canEdit)
        XCTAssertEqual(store.airFieldLoads, 1)

        store.airFieldList = FakeRigStore.airTable
        controller.end()
        controller.begin()
        XCTAssertEqual(controller.airFields, FakeRigStore.airTable)
        XCTAssertEqual(store.airFieldLoads, 2)
        XCTAssertFalse(state!.isUnavailable)
    }

    func testNoRigShowsTheDefaultsWithTheSwitchEnabled() {
        begin(nil)
        let s = state!
        XCTAssertFalse(s.hasRig)
        XCTAssertFalse(s.isOn)
        XCTAssertEqual(s.switchValue, "Off")
        XCTAssertTrue(s.canToggle, "On creates a rig")
        XCTAssertFalse(s.canEdit, "the setter has no rig to write to")
        XCTAssertEqual(s.hint, .noLights)
        XCTAssertEqual(s.rows.map(\.parameter), AirParameter.allCases)
        XCTAssertEqual(s.rows.map(\.value), [0, 0, 0.35, 1, 0.55])
        XCTAssertEqual(s.rows.map(\.text), ["0.00", "0.00", "0.35", "1.00", "0.55"])
        XCTAssertEqual(s.row(.dustSize)?.range, 0.05...2)
        XCTAssertEqual(s.containerLabel, "Atmosphere")
    }

    func testRowsShowTheRigsAir() {
        begin(["key", "fill"], air: Self.remembered)
        let s = state!
        XCTAssertTrue(s.isOn)
        XCTAssertEqual(s.switchValue, "On")
        XCTAssertTrue(s.canEdit)
        XCTAssertEqual(s.rows.map(\.value), [0.3, 0.4, 0.6, 2.5, -0.25])
        XCTAssertEqual(s.row(.scatter)?.text, "\u{2212}0.25")
        XCTAssertEqual(s.row(.scatter)?.spoken, "-0.25")
        XCTAssertEqual(s.row(.scatter)?.range, -0.9...0.9)
        XCTAssertNil(s.hint)
    }

    func testOnMeansHazeOrDust() {
        var air = FakeRigStore.defaultAir
        begin(["key"], air: air)
        XCTAssertFalse(state!.isOn)
        air.dustSize = 1.5
        air.scatter = -0.5
        store.air = air
        controller.refresh()
        XCTAssertFalse(state!.isOn, "only haze and dust draw")
        store.air.dust = 0.01
        controller.refresh()
        XCTAssertTrue(state!.isOn)
        store.air.dust = 0
        store.air.haze = 0.01
        controller.refresh()
        XCTAssertTrue(state!.isOn)
    }

    func testBusyDisablesEverything() {
        begin(["key"], air: Self.remembered)
        store.busy = true
        let s = state!
        XCTAssertFalse(s.canToggle)
        XCTAssertFalse(s.canEdit)
    }

    func testNoLightsHint() {
        // An empty rig (the switch's own) and no rig at all.
        begin([], enabled: false, air: Self.remembered)
        XCTAssertEqual(state?.hint, .noLights)
        XCTAssertEqual(state?.summary,
                       "on=1 haze=0.30 dust=0.40 dust_size=0.60 dust_speed=2.50 scatter=-0.25"
                       + " rig=1 hint=no_lights edit=1 memory=0")
    }

    func testLightsOffHintOnlyWhileTheAirIsOn() {
        begin(["key", "fill"], enabled: false)
        XCTAssertNil(state?.hint, "lights off with no air: nothing to say")
        store.air.haze = 0.1
        controller.refresh()
        XCTAssertEqual(state?.hint, .lightsOff)
        store.air.haze = 0
        store.air.dust = 0.2
        controller.refresh()
        XCTAssertEqual(state?.hint, .lightsOff)
    }

    func testBacklitHazeHint() {
        var air = FakeRigStore.defaultAir
        air.haze = 0.31
        store.setRig(["key", "fill", "rim"])
        store.air = air
        store.lights[2].orbit = 180   // the rim behind the molecule
        controller.begin()
        XCTAssertTrue(controller.facing.isBehind("rim"))
        XCTAssertEqual(state?.hint, .backlitHaze)

        // Not at 0.30.
        store.air.haze = 0.3
        controller.refresh()
        XCTAssertNil(state?.hint)

        // Not with no light behind.
        store.air.haze = 0.5
        store.lights[2].orbit = 90
        controller.refresh()
        XCTAssertFalse(controller.facing.isBehind("rim"))
        XCTAssertNil(state?.hint)

        // Not when the light behind gives no light.
        store.lights[2].orbit = 180
        store.lights[2].intensity = 0
        controller.refresh()
        XCTAssertTrue(controller.facing.isBehind("rim"))
        XCTAssertNil(state?.hint)
        store.lights[2].intensity = 0.2
        controller.refresh()
        XCTAssertEqual(state?.hint, .backlitHaze)
    }

    func testHintPriority() {
        let lit = LightRigSnapshot.Air(haze: 0.6, dust: 0.5, dustSize: 0.35, dustSpeed: 1,
                                       scatter: 0.55, seed: 0)
        // No lights wins over everything.
        XCTAssertEqual(AtmosphereHint.current(rig: nil, behind: ["rim"]), .noLights)
        begin(["key", "rim"], enabled: false, air: lit)
        store.lights[1].orbit = 180
        controller.refresh()
        // Lights off wins over backlit.
        XCTAssertEqual(AtmosphereCardState(controller, behind: ["rim"])?.hint, .lightsOff)
        store.enabled = true
        controller.refresh()
        XCTAssertEqual(AtmosphereCardState(controller, behind: ["rim"])?.hint, .backlitHaze)
        XCTAssertNil(AtmosphereCardState(controller, behind: [])?.hint)
    }

    func testHintTextsAndGlyphs() {
        XCTAssertEqual(AtmosphereHint.noLights.text,
                       "Haze and dust show only inside a light's beam. Add a light to see them.")
        XCTAssertEqual(AtmosphereHint.lightsOff.text, "The air shows only while the lights are on.")
        XCTAssertEqual(AtmosphereHint.backlitHaze.text,
                       "Haze above about 0.3 with a light behind the molecule can wash the picture out. "
                       + "Lower the haze or move the light.")
        XCTAssertEqual(AtmosphereHint.noLights.glyph, "info.circle")
        XCTAssertEqual(AtmosphereHint.lightsOff.glyph, "exclamationmark.triangle")
        XCTAssertEqual(AtmosphereHint.backlitHaze.glyph, "exclamationmark.triangle")
        XCTAssertEqual([AtmosphereHint.noLights, .lightsOff, .backlitHaze].map(\.identifier),
                       ["no_lights", "lights_off", "backlit"])
        XCTAssertEqual(AtmosphereHint.backlitHazeThreshold, 0.3)
    }

    func testCollapsedGlyph() {
        begin(nil)
        XCTAssertEqual(state?.collapsedGlyph,
                       AtmosphereCardState.Glyph(systemImage: "info.circle", label: AtmosphereHint.noLights.text))
        controller.end()
        begin(["key"], enabled: false, air: Self.remembered)
        XCTAssertEqual(state?.collapsedGlyph?.systemImage, "exclamationmark.triangle")
        XCTAssertEqual(state?.collapsedGlyph?.label, AtmosphereHint.lightsOff.text)
        store.enabled = true
        controller.refresh()
        XCTAssertNil(state?.collapsedGlyph)
    }

    func testSummary() {
        begin(["key"], air: LightRigSnapshot.Air(haze: 0.25, dust: 0.5, dustSize: 0.35, dustSpeed: 1,
                                                 scatter: 0.55, seed: 3))
        XCTAssertEqual(state?.summary,
                       "on=1 haze=0.25 dust=0.50 dust_size=0.35 dust_speed=1.00 scatter=0.55"
                       + " rig=1 hint=none edit=1 memory=0")
        controller.setAtmosphere(on: false)
        XCTAssertEqual(state?.summary,
                       "on=0 haze=0.00 dust=0.00 dust_size=0.35 dust_speed=1.00 scatter=0.55"
                       + " rig=1 hint=none edit=1 memory=1")
        let empty = FakeRigStore()
        empty.airFieldList = []
        let bare = LightsController(seams: empty.seams)
        bare.begin()
        XCTAssertEqual(AtmosphereCardState(bare)?.summary,
                       "on=0 haze=- dust=- dust_size=- dust_speed=- scatter=- rig=0 hint=no_lights"
                       + " edit=0 memory=0")
    }
}

// MARK: - Slider ticks and typed values (the setter path)

final class AtmosphereEditTests: AtmosphereControllerCase {
    func testAWriteGoesToIndexMinusOneAndRepublishesInTheSameTurn() {
        begin(["key", "fill"])
        let reads = store.reads
        XCTAssertEqual(controller.setAir(.haze, 0.4), .ok)
        XCTAssertEqual(store.numberWrites.count, 1)
        XCTAssertEqual(store.numberWrites.last?.index, -1)
        XCTAssertEqual(store.numberWrites.last?.field, "haze")
        XCTAssertEqual(store.numberWrites.last?.value, 0.4)
        XCTAssertEqual(store.air.haze, 0.4)
        XCTAssertEqual(controller.rig?.air.haze, 0.4, "the mirror shows it in the same turn")
        XCTAssertEqual(state?.row(.haze)?.value, 0.4)
        XCTAssertEqual(store.reads, reads + 1, "one re-read per write")
    }

    func testEveryParameterReachesItsField() {
        begin(["key"])
        let values: [AirParameter: Double] = [.haze: 0.12, .dust: 0.34, .dustSize: 0.56,
                                              .dustSpeed: 7.5, .scatter: -0.78]
        for p in AirParameter.allCases {
            XCTAssertEqual(controller.setAir(p, values[p]!), .ok, p.field)
            XCTAssertEqual(store.numberWrites.last?.field, p.field)
            XCTAssertEqual(controller.airValue(p), values[p], p.field)
        }
        XCTAssertEqual(controller.air, LightRigSnapshot.Air(haze: 0.12, dust: 0.34, dustSize: 0.56,
                                                            dustSpeed: 7.5, scatter: -0.78, seed: 0))
    }

    func testTypedValuesAreWrittenExactlyAndTheCoreClamps() {
        begin(["key"])
        XCTAssertEqual(controller.setAir(.dustSize, 0.123456), .ok)
        XCTAssertEqual(store.numberWrites.last?.value, 0.123456, "no rounding on the typed path")
        XCTAssertEqual(controller.air?.dustSize, 0.123456)
        XCTAssertEqual(controller.setAir(.haze, 2), .ok)
        XCTAssertEqual(controller.air?.haze, 1, "clamped to the table's max")
        XCTAssertEqual(controller.setAir(.scatter, -5), .ok)
        XCTAssertEqual(controller.air?.scatter, -0.9, "clamped to the table's min")
        XCTAssertEqual(controller.setAir(.dust, .nan), .badValue)
    }

    func testTicksRunNoAction() {
        begin(["key", "fill", "rim"])
        for p in AirParameter.allCases {
            for i in 0..<10 {
                let f = controller.airField(p)!
                let position = p.sliderRange(f).lowerBound
                    + (p.sliderRange(f).upperBound - p.sliderRange(f).lowerBound) * Double(i + 1) / 11
                XCTAssertEqual(controller.setAirIfChanged(p, p.sliderValue(position, f)), .ok)
            }
        }
        XCTAssertEqual(store.performed, [], "a tick is a setter write, never a command or Python")
        XCTAssertEqual(store.numberWrites.count, 50)
        XCTAssertTrue(store.numberWrites.allSatisfy { $0.index == -1 })
    }

    func testIfChangedSkipsTheCurrentValue() {
        begin(["key"], air: Self.remembered)
        XCTAssertEqual(controller.setAirIfChanged(.dust, 0.4), .ok)
        XCTAssertTrue(store.numberWrites.isEmpty, "the slider echoing its value writes nothing")
        XCTAssertEqual(controller.setAirIfChanged(.dust, 0.41), .ok)
        XCTAssertEqual(store.numberWrites.count, 1)
    }

    func testNoRigInactiveAndBusy() {
        // Inactive.
        store.setRig(["key"])
        XCTAssertEqual(controller.setAir(.haze, 0.2), .badIndex)
        XCTAssertEqual(controller.setAirIfChanged(.haze, 0.2), .badIndex)
        // No rig.
        store.exists = false
        store.lights = []
        controller.begin()
        XCTAssertEqual(controller.setAir(.haze, 0.2), .noRig)
        XCTAssertEqual(controller.setAirIfChanged(.haze, 0.2), .noRig)
        XCTAssertFalse(store.exists, "a slider never creates a rig")
        // Busy.
        controller.end()
        store.setRig(["key"])
        controller.begin()
        store.busy = true
        XCTAssertEqual(controller.setAir(.haze, 0.2), .badIndex)
        XCTAssertEqual(controller.setAirIfChanged(.haze, 0.2), .badIndex)
        XCTAssertTrue(store.numberWrites.isEmpty)
    }

    func testNoTableRefusesTheIfChangedPath() {
        store.airFieldList = []
        begin(["key"])
        XCTAssertEqual(controller.setAirIfChanged(.haze, 0.2), .badIndex)
        XCTAssertTrue(store.numberWrites.isEmpty)
    }

    func testWriteRigNumbersStopsAtTheFirstFailure() {
        begin(["key"])
        let reads = store.reads
        XCTAssertEqual(controller.writeRigNumbers([("haze", 0.3), ("fog", 1), ("dust", 0.4)]), .unknownField)
        XCTAssertEqual(store.numberWrites.map(\.field), ["haze", "fog"])
        XCTAssertEqual(controller.air?.haze, 0.3)
        XCTAssertEqual(controller.air?.dust, 0)
        XCTAssertEqual(store.reads, reads + 1, "one re-read for the write that landed")
        // Nothing landed: no re-read.
        let before = store.reads
        XCTAssertEqual(controller.writeRigNumbers([("fog", 1)]), .unknownField)
        XCTAssertEqual(store.reads, before)
    }

    func testAStaleMirrorIsReReadBeforeTheWrite() {
        begin(["key"])
        // The console removed the rig since the last read.
        store.exists = false
        store.lights = []
        store.clock += 1
        XCTAssertEqual(controller.writeRigNumbers([("haze", 0.3)]), .noRig)
        XCTAssertNil(controller.rig)
        XCTAssertTrue(store.numberWrites.isEmpty, "the re-read found no rig: nothing written")
    }

    func testAnAirWriteLeavesTheShadowNoticeAlone() {
        begin(["key", "fill", "rim", "light4"])
        for i in 0..<3 { store.lights[i].shadow = true }
        controller.refresh()
        controller.select(name: "light4")
        XCTAssertEqual(controller.setShadow(true), .refused)
        XCTAssertTrue(controller.shadowRefused)
        XCTAssertEqual(controller.setAir(.haze, 0.2), .ok)
        XCTAssertTrue(controller.shadowRefused, "the notice is about the selected light")
    }
}

// MARK: - The On/Off switch

final class AtmosphereSwitchTests: AtmosphereControllerCase {
    private var fields: [AirField] { FakeRigStore.airTable }

    func testOffRemembersAndRunsAtmosphereOff() {
        begin(["key"], air: Self.remembered)
        XCTAssertTrue(controller.setAtmosphere(on: false))
        XCTAssertEqual(store.performed, [.atmosphereOff])
        XCTAssertEqual(store.air, FakeRigStore.defaultAir, "every field back to its table default")
        XCTAssertEqual(controller.air, FakeRigStore.defaultAir, "mirrored in the same turn")
        XCTAssertEqual(controller.airMemory, Self.remembered)
        XCTAssertFalse(controller.airIsOn)
        XCTAssertEqual(store.lights.map(\.name), ["key"], "lights untouched")
    }

    func testOnPutsBackTheRememberedAir() {
        begin(["key"], air: Self.remembered)
        controller.setAtmosphere(on: false)
        XCTAssertTrue(controller.setAtmosphere(on: true))
        XCTAssertEqual(store.performed.last, .setAir([
            AirValue("haze", 0.3), AirValue("dust", 0.4), AirValue("dust_size", 0.6),
            AirValue("dust_speed", 2.5), AirValue("scatter", -0.25), AirValue("seed", 7),
        ]))
        XCTAssertEqual(store.air, Self.remembered, "On after Off restores the air exactly")
        XCTAssertTrue(controller.airIsOn)
    }

    func testOnWithNothingRememberedUsesTheStartLook() {
        begin(["key"])
        XCTAssertTrue(controller.setAtmosphere(on: true))
        XCTAssertEqual(store.performed, [.setAir([AirValue("haze", 0.2), AirValue("dust", 0.5)])])
        XCTAssertEqual(controller.air?.haze, 0.2)
        XCTAssertEqual(controller.air?.dust, 0.5)
    }

    func testOnWithNoRigCreatesAnOffEmptyRig() {
        begin(nil)
        XCTAssertTrue(controller.canToggleAir)
        XCTAssertTrue(controller.setAtmosphere(on: true))
        XCTAssertEqual(store.performed, [.setAir([AirValue("haze", 0.2), AirValue("dust", 0.5)])])
        XCTAssertNotNil(controller.rig)
        XCTAssertEqual(controller.rig?.enabled, false)
        XCTAssertEqual(controller.rig?.lights.count, 0)
        XCTAssertTrue(controller.canEditAir, "the rows edit the new rig")
        XCTAssertEqual(state?.hint, .noLights)
    }

    func testAFieldChangedWhileOffKeepsItsValue() {
        begin(["key"], air: Self.remembered)
        controller.setAtmosphere(on: false)
        XCTAssertEqual(controller.setAir(.dustSize, 0.9), .ok)
        XCTAssertEqual(controller.setAir(.scatter, 0.55), .ok, "set back to its default: counts as unchanged")
        XCTAssertTrue(controller.setAtmosphere(on: true))
        XCTAssertEqual(store.performed.last, .setAir([
            AirValue("haze", 0.3), AirValue("dust", 0.4), AirValue("dust_speed", 2.5),
            AirValue("scatter", -0.25), AirValue("seed", 7),
        ]))
        XCTAssertEqual(store.air.dustSize, 0.9, "changed since Off: kept")
        XCTAssertEqual(store.air.haze, 0.3)
    }

    func testNothingRunsWhenAlreadyInThatState() {
        begin(["key"])
        XCTAssertFalse(controller.setAtmosphere(on: false), "already off")
        store.air = Self.remembered
        controller.refresh()
        XCTAssertFalse(controller.setAtmosphere(on: true), "already on")
        XCTAssertEqual(store.performed, [])
        XCTAssertNil(controller.airMemory)
    }

    func testOffWithNoRigRunsNothing() {
        begin(nil)
        XCTAssertFalse(controller.setAtmosphere(on: false))
        XCTAssertEqual(store.performed, [])
    }

    func testTheSwitchNeedsTheTableAndTheMode() {
        store.setRig(["key"])
        store.air = Self.remembered
        XCTAssertFalse(controller.setAtmosphere(on: false), "inactive")
        store.airFieldList = []
        controller.begin()
        XCTAssertFalse(controller.setAtmosphere(on: false), "no table")
        controller.end()
        store.airFieldList = FakeRigStore.airTable
        controller.begin()
        store.busy = true
        XCTAssertFalse(controller.setAtmosphere(on: false), "busy")
        XCTAssertEqual(store.performed, [])
    }

    func testEndDropsTheMemory() {
        begin(["key"], air: Self.remembered)
        controller.setAtmosphere(on: false)
        XCTAssertNotNil(controller.airMemory)
        controller.end()
        XCTAssertNil(controller.airMemory, "the memory lasts one Lights-mode visit")
        controller.begin()
        XCTAssertTrue(controller.setAtmosphere(on: true))
        XCTAssertEqual(store.performed.last, .setAir([AirValue("haze", 0.2), AirValue("dust", 0.5)]),
                       "after a new entry, On uses the start look")
    }

    func testAConsoleChangeIsReadBeforeTheSwitch() {
        begin(["key"])
        // The console turned the air on since the last read.
        store.air = Self.remembered
        store.clock += 1
        XCTAssertTrue(controller.setAtmosphere(on: false), "the re-read sees the air on")
        XCTAssertEqual(controller.airMemory, Self.remembered)
    }

    // The pure rule.

    func testOnValuesRule() {
        let defaults = FakeRigStore.defaultAir
        // No rig, no memory: the start look against the table defaults.
        XCTAssertEqual(AtmosphereSwitch.onValues(current: nil, memory: nil, fields: fields),
                       [AirValue("haze", 0.2), AirValue("dust", 0.5)])
        // No rig with a memory (a rig removed since Off): the memory.
        XCTAssertEqual(AtmosphereSwitch.onValues(current: nil, memory: Self.remembered, fields: fields).count, 6)
        // A memory with only dust: the start look is not used.
        var dustOnly = defaults
        dustOnly.dust = 0.7
        XCTAssertEqual(AtmosphereSwitch.onValues(current: defaults, memory: dustOnly, fields: fields),
                       [AirValue("dust", 0.7)])
        // Only fields that differ are sent, in table order, seed included.
        var seedOnly = defaults
        seedOnly.seed = 42
        XCTAssertEqual(AtmosphereSwitch.onValues(current: defaults, memory: seedOnly, fields: fields),
                       [AirValue("haze", 0.2), AirValue("dust", 0.5), AirValue("seed", 42)])
        // No table: nothing to send.
        XCTAssertEqual(AtmosphereSwitch.onValues(current: defaults, memory: Self.remembered, fields: []), [])
    }

    func testStartLook() {
        XCTAssertEqual(AtmosphereSwitch.startLook, [AirValue("haze", 0.2), AirValue("dust", 0.5)])
        for look in AtmosphereSwitch.startLook {
            let field = fields.first { $0.name == look.field }
            XCTAssertNotNil(field)
            XCTAssertTrue(field!.range.contains(look.value), look.field)
        }
    }
}

// MARK: - Mirroring and Revert

final class AtmosphereMirrorTests: AtmosphereControllerCase {
    func testAConsoleChangeShowsAfterARefresh() {
        begin(["key"])
        store.air.haze = 0.3
        store.air.dust = 0.45
        XCTAssertEqual(state?.row(.haze)?.value, 0, "not before the poll")
        controller.refresh()
        XCTAssertEqual(state?.row(.haze)?.value, 0.3)
        XCTAssertEqual(state?.row(.dust)?.value, 0.45)
        XCTAssertEqual(state?.row(.dust)?.text, "0.45")
        XCTAssertTrue(state!.isOn)
    }

    func testAnAirEditCanBeReverted() {
        begin(["key", "fill"], air: Self.remembered)
        let entry = controller.entryJSON
        XCTAssertFalse(controller.canRevert)
        XCTAssertEqual(controller.setAir(.haze, 0.8), .ok)
        XCTAssertTrue(controller.canRevert, "an air edit is a change Revert can undo")
        controller.setAtmosphere(on: false)

        controller.revert()
        XCTAssertEqual(store.performed.last, .restore(entry!))
        XCTAssertEqual(store.air, Self.remembered, "Revert puts back the entry air")
        XCTAssertEqual(controller.air, Self.remembered)
        XCTAssertEqual(store.json, entry)
        XCTAssertFalse(controller.canRevert)
    }

    func testRevertRemovesARigTheSwitchCreated() {
        begin(nil)
        controller.setAtmosphere(on: true)
        XCTAssertTrue(controller.canRevert)
        controller.revert()
        XCTAssertEqual(store.performed.last, .restore("null"))
        XCTAssertNil(controller.rig)
        XCTAssertFalse(store.exists)
        XCTAssertEqual(store.air, FakeRigStore.defaultAir, "a removed rig takes its air with it")
    }

    func testDoneKeepsTheAirAndRunsNothing() {
        begin(["key"])
        controller.setAir(.dust, 0.6)
        let performed = store.performed
        controller.end()
        XCTAssertEqual(store.performed, performed, "end() runs nothing")
        XCTAssertEqual(store.air.dust, 0.6, "Done and Esc keep the edits")
    }

    func testTheFakesDefaultJSONIsUnchanged() {
        store.setRig([])
        XCTAssertEqual(store.json,
                       "{\"version\":1,\"enabled\":true,\"centre\":null,\"size\":null,\"ambient\":0.05,"
                       + "\"classic\":0.0,\"air\":{\"haze\":0.0,\"dust\":0.0,\"dust_size\":0.35,"
                       + "\"dust_speed\":1.0,\"scatter\":0.55,\"seed\":0},\"lights\":[]}")
    }
}

// MARK: - The dust pattern seed

final class AtmosphereSeedTests: AtmosphereControllerCase {
    func testTheSeedRowShowsTheRigsSeed() {
        begin(["key"], air: Self.remembered)
        XCTAssertEqual(state?.seed?.value, 7)
        XCTAssertEqual(state?.seed?.text, "7")
        XCTAssertEqual(state?.seed?.range, 0...1_000_000)
    }

    func testNoRigShowsTheTableDefault() {
        begin(nil)
        XCTAssertEqual(state?.seed?.value, 0)
    }

    func testSettingTheSeedWritesTheSetterAtIndexMinusOne() {
        begin(["key"])
        XCTAssertEqual(controller.setAirSeed(42), .ok)
        XCTAssertEqual(store.numberWrites.last?.index, -1)
        XCTAssertEqual(store.numberWrites.last?.field, "seed")
        XCTAssertEqual(store.numberWrites.last?.value, 42)
        XCTAssertEqual(controller.air?.seed, 42)
        XCTAssertEqual(state?.seed?.value, 42)
        XCTAssertEqual(store.performed, [])
    }

    func testTheCoreClampsTheSeed() {
        begin(["key"])
        XCTAssertEqual(controller.setAirSeed(2_000_000), .ok)
        XCTAssertEqual(controller.air?.seed, 1_000_000)
    }

    func testNoRigAndInactive() {
        // Inactive (never begin).
        XCTAssertEqual(controller.setAirSeed(3), .badIndex)
        XCTAssertTrue(store.numberWrites.isEmpty)

        // With no rig after begin(nil).
        begin(nil)
        XCTAssertEqual(controller.setAirSeed(3), .noRig)
        XCTAssertTrue(store.numberWrites.isEmpty)
    }
}

final class AirSeedEditorTests: XCTestCase {
    func testShowFollowsTheModelUntilTheUserTypes() {
        var editor = AirSeedEditor()
        editor.show(7)
        XCTAssertEqual(editor.text, "7")
        editor.begin()
        XCTAssertTrue(editor.isEditing)
        editor.show(8)
        XCTAssertEqual(editor.text, "8", "focus alone keeps following the model")
        editor.type("9")
        editor.show(10)
        XCTAssertEqual(editor.text, "9", "typed text is kept while the model moves")
        XCTAssertEqual(editor.commit(), 9)
        XCTAssertEqual(editor.text, "9")
        XCTAssertFalse(editor.isEditing)
        XCTAssertFalse(editor.typed)
    }

    func testCommitWithoutTypingReturnsNil() {
        var editor = AirSeedEditor()
        editor.show(7)
        editor.begin()
        XCTAssertNil(editor.commit())
        XCTAssertEqual(editor.text, "7")
    }

    func testTypedValuesPassAndTextFormats() {
        var editor = AirSeedEditor()
        editor.show(7)
        editor.begin()
        editor.type("  +12 ")
        XCTAssertEqual(editor.commit(), 12)
        XCTAssertEqual(editor.text, "12")
    }

    func testInvalidTextCommitsNilAndRestoresModelText() {
        for bad in ["3.5", "-4", "1e3", "", "abc"] {
            var editor = AirSeedEditor()
            editor.show(7)
            editor.begin()
            editor.type(bad)
            XCTAssertNil(editor.commit(), bad)
            XCTAssertEqual(editor.text, "7", bad)
        }
    }

    func testParseSeed() {
        let good: [(String, Int)] = [
            ("7", 7), (" 7 ", 7), ("+7", 7), ("0", 0), ("2000000", 2000000),
        ]
        for (text, value) in good {
            XCTAssertEqual(AtmosphereFormat.parseSeed(text), value, text)
        }
        for text in ["-1", "7.0", "1e3", "", "+", "x7"] {
            XCTAssertNil(AtmosphereFormat.parseSeed(text), text)
        }
    }
}
