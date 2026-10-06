import AppKit
import Combine
import SwiftUI
import XCTest
@testable import RayMol

/// The selected-light inspector (#620): its number formats, the Orbit/Pitch
/// field editing model, what the card shows for each rig state
/// (LightsInspectorState, no drawing), the DEBUG simulator edit hook, the
/// VoiceOver strings, two-way mirroring with the bar, and pictures of the card
/// drawn offscreen with a controller on fake seams (FakeRigStore, in
/// LightsControllerTests.swift).

// MARK: - Formats

final class LightInspectorFormatTests: XCTestCase {
    func testAngles() {
        XCTAssertEqual(LightInspectorFormat.angle(-45), "−45°")
        XCTAssertEqual(LightInspectorFormat.angle(35, plus: true), "+35°")
        XCTAssertEqual(LightInspectorFormat.angle(0), "0°")
        XCTAssertEqual(LightInspectorFormat.angle(0, plus: true), "0°")
        XCTAssertEqual(LightInspectorFormat.angle(-0.04), "0°", "never −0°")
        XCTAssertEqual(LightInspectorFormat.angle(47.3), "47.3°")
        XCTAssertEqual(LightInspectorFormat.angle(-47.26), "−47.3°")
        XCTAssertEqual(LightInspectorFormat.angle(180), "180°")
        XCTAssertEqual(LightInspectorFormat.angle(-90, plus: true), "−90°")
    }

    func testParsing() {
        XCTAssertEqual(LightInspectorFormat.parseAngle("−45"), -45)
        XCTAssertEqual(LightInspectorFormat.parseAngle("-45°"), -45)
        XCTAssertEqual(LightInspectorFormat.parseAngle(" 30 "), 30)
        XCTAssertEqual(LightInspectorFormat.parseAngle("+12"), 12)
        XCTAssertEqual(LightInspectorFormat.parseAngle("190"), 190, "out of range as typed: the core wraps")
        XCTAssertEqual(LightInspectorFormat.parseAngle("12.5 °"), 12.5)
        XCTAssertEqual(LightInspectorFormat.parseAngle("+35°"), 35, "the field's own text parses")
        XCTAssertNil(LightInspectorFormat.parseAngle("abc"))
        XCTAssertNil(LightInspectorFormat.parseAngle(""))
        XCTAssertNil(LightInspectorFormat.parseAngle("°"))
        XCTAssertNil(LightInspectorFormat.parseAngle("nan"))
        XCTAssertNil(LightInspectorFormat.parseAngle("inf"))
        XCTAssertNil(LightInspectorFormat.parseAngle("1e999"))
    }

    func testRadiusWarmthAndFractions() {
        XCTAssertEqual(LightInspectorFormat.radius(3, frameSize: 14), "3.0× · 42 Å")
        XCTAssertEqual(LightInspectorFormat.radius(3, frameSize: nil), "3.0×")
        XCTAssertEqual(LightInspectorFormat.kelvin(3800), "3800 K")
        XCTAssertEqual(LightInspectorFormat.fraction(1.8), "1.80")
        XCTAssertEqual(LightInspectorFormat.fraction(0.5), "0.50")
    }

    func testSpokenValues() {
        XCTAssertEqual(LightInspectorFormat.spokenAngle(-45), "-45 degrees")
        XCTAssertEqual(LightInspectorFormat.spokenAngle(35), "35 degrees")
        XCTAssertEqual(LightInspectorFormat.spokenAngle(1), "1 degree")
        XCTAssertEqual(LightInspectorFormat.spokenRadius(3, frameSize: 14), "3.0 scene sizes, 42 angstroms")
        XCTAssertEqual(LightInspectorFormat.spokenRadius(3, frameSize: nil), "3.0 scene sizes")
        XCTAssertEqual(LightInspectorFormat.spokenKelvin(3800), "3800 kelvin")
    }

    func testEveryParameterHasATextAndASpokenValue() {
        let expected: [LightParameter: (String, String)] = [
            .orbit: ("−45°", "-45 degrees"),
            .pitch: ("+35°", "35 degrees"),
            .radius: ("3.0× · 42 Å", "3.0 scene sizes, 42 angstroms"),
            .intensity: ("1.80", "1.80"),
            .warmth: ("3800 K", "3800 kelvin"),
            .beam: ("40°", "40 degrees"),
            .softness: ("0.50", "0.50"),
        ]
        let values: [LightParameter: Double] = [.orbit: -45, .pitch: 35, .radius: 3, .intensity: 1.8,
                                                .warmth: 3800, .beam: 40, .softness: 0.5]
        for p in LightParameter.allCases {
            XCTAssertEqual(LightInspectorFormat.text(p, values[p]!, frameSize: 14), expected[p]!.0, "\(p)")
            XCTAssertEqual(LightInspectorFormat.spoken(p, values[p]!, frameSize: 14), expected[p]!.1, "\(p)")
        }
    }

    func testSliderTrackMapping() {
        XCTAssertEqual(LightsInspectorState.sliderRange(.warmth), 0...1, "warmth runs on the log-K track")
        XCTAssertEqual(LightsInspectorState.sliderRange(.radius), LightParameter.radius.range)
        XCTAssertEqual(LightsInspectorState.sliderPosition(.warmth, 1500), 0, accuracy: 1e-12)
        XCTAssertEqual(LightsInspectorState.sliderPosition(.warmth, 15000), 1, accuracy: 1e-12)
        XCTAssertEqual(LightsInspectorState.sliderValue(.warmth, LightsInspectorState.sliderPosition(.warmth, 3800)),
                       3800, "a slider position comes back as kelvin, rounded to 10 K")
        XCTAssertEqual(LightsInspectorState.sliderValue(.radius, 3.04), 3.04, accuracy: 1e-12)
        XCTAssertEqual(LightsInspectorState.sliderValue(.radius, 3.046), 3.05, accuracy: 1e-12)
        XCTAssertEqual(LightsInspectorState.sliderValue(.beam, 40.3), 40.5, accuracy: 1e-12)
        XCTAssertEqual(LightsInspectorState.sliderPosition(.intensity, 9), 4, "clamped into the core's range")
    }
}

// MARK: - The field editor

final class LightFieldEditorTests: XCTestCase {
    func testShowReplacesTheTextWhileNotEditing() {
        var e = LightFieldEditor(parameter: .orbit)
        e.show(-45, light: "key")
        XCTAssertEqual(e.text, "−45°")
        e.show(12, light: "key")
        XCTAssertEqual(e.text, "12°")
        XCTAssertFalse(e.isEditing)
        var pitch = LightFieldEditor(parameter: .pitch)
        pitch.show(35, light: "key")
        XCTAssertEqual(pitch.text, "+35°")
    }

    func testShowKeepsTypedTextForTheSameLight() {
        var e = LightFieldEditor(parameter: .orbit)
        e.show(-45, light: "key")
        e.begin(light: "key")
        e.type("12")
        for frame in 0..<60 { e.show(Double(frame), light: "key") }   // a pinned light per frame
        XCTAssertEqual(e.text, "12", "per-frame placements never overwrite typing")
        XCTAssertTrue(e.isEditing)
        XCTAssertEqual(e.commit(selected: "key"), 12)
    }

    func testAFocusedUntouchedFieldFollowsTheModel() {
        var e = LightFieldEditor(parameter: .orbit)
        e.show(-45, light: "key")
        e.begin(light: "key")
        e.show(-40, light: "key")
        XCTAssertEqual(e.text, "−40°")
        XCTAssertNil(e.commit(selected: "key"), "nothing typed: focus loss writes nothing")
        XCTAssertEqual(e.text, "−40°")
    }

    func testCommitWithTheOwnerSelectedReturnsTheValue() {
        var e = LightFieldEditor(parameter: .pitch)
        e.show(35, light: "key")
        e.begin(light: "key")
        e.type(" -20.5 ")
        XCTAssertEqual(e.commit(selected: "key"), -20.5, "typed values are exact")
        XCTAssertEqual(e.text, "−20.5°")
        XCTAssertFalse(e.isEditing)
    }

    func testSelectionChangeDropsTheText() {
        var e = LightFieldEditor(parameter: .orbit)
        e.show(-45, light: "key")
        e.begin(light: "key")
        e.type("99")
        e.selectionChanged(to: "fill", value: 30)
        XCTAssertEqual(e.text, "30°")
        XCTAssertFalse(e.isEditing)
        XCTAssertNil(e.commit(selected: "fill"), "text typed for key is never written to fill")
    }

    func testACommitAfterTheOwnerWasRemovedWritesNothing() {
        var e = LightFieldEditor(parameter: .orbit)
        e.show(-45, light: "key")
        e.begin(light: "key")
        e.type("99")
        // key removed from the console: fill slid into the index.
        XCTAssertNil(e.commit(selected: "fill"))
        XCTAssertEqual(e.text, "−45°", "the model's text comes back")
    }

    func testShowForAnotherLightEndsTheEditing() {
        var e = LightFieldEditor(parameter: .orbit)
        e.show(-45, light: "key")
        e.begin(light: "key")
        e.type("99")
        e.show(30, light: "fill")
        XCTAssertEqual(e.text, "30°")
        XCTAssertFalse(e.isEditing)
    }

    func testAnUnparsableCommitRestoresTheModelText() {
        var e = LightFieldEditor(parameter: .orbit)
        e.show(-45, light: "key")
        e.begin(light: "key")
        e.type("abc")
        XCTAssertNil(e.commit(selected: "key"))
        XCTAssertEqual(e.text, "−45°")
        XCTAssertFalse(e.isEditing)
    }

    func testTheOwnerMatchIgnoresCase() {
        var e = LightFieldEditor(parameter: .orbit)
        e.show(-45, light: "Key")
        e.begin(light: "Key")
        e.type("10")
        XCTAssertEqual(e.owner, "key")
        XCTAssertEqual(e.commit(selected: "KEY"), 10)
    }

    func testGestureDropsTypedText() {
        // 30 typed for key, then the key's lamp dragged to 105 on the orbit
        // plan: the field shows the drag's value and Return writes nothing.
        var e = LightFieldEditor(parameter: .orbit)
        e.show(-45, light: "key")
        e.begin(light: "key")
        e.type("30")
        e.gestureBegan(value: 105, light: "key")
        XCTAssertEqual(e.text, "105°")
        XCTAssertFalse(e.isEditing)
        XCTAssertNil(e.commit(selected: "key"), "the typed 30 never overwrites the drag")
        XCTAssertEqual(e.text, "105°")
        // Per-frame placements show again.
        e.show(110, light: "key")
        XCTAssertEqual(e.text, "110°")
    }

    func testTypingWithoutBeginWritesNothing() {
        var e = LightFieldEditor(parameter: .orbit)
        e.show(-45, light: "key")
        e.type("10")
        XCTAssertNil(e.commit(selected: "key"))
        XCTAssertEqual(e.text, "−45°")
    }
}

// MARK: - What the inspector shows

@MainActor
final class LightsInspectorStateTests: XCTestCase {
    private var store: FakeRigStore!
    private var controller: LightsController!

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

    private func begin(with lights: [String]?, enabled: Bool = true) {
        if let lights { store.setRig(lights, enabled: enabled) }
        controller.begin()
    }

    func testNilWithoutARigLightsOrTheMode() {
        begin(with: nil)
        XCTAssertNil(LightsInspectorState(controller), "no rig")
        controller.end()
        store.setRig([])
        controller.begin()
        XCTAssertNil(LightsInspectorState(controller), "no lights")
        controller.end()
        store.setRig(["key"])
        XCTAssertNil(LightsInspectorState(controller), "inactive")
        controller.begin()
        XCTAssertNotNil(LightsInspectorState(controller))
        controller.end()
        XCTAssertNil(LightsInspectorState(controller), "after Done")
    }

    func testRowsShowTheSelectedLight() throws {
        store.setRig(["key", "fill", "rim"])
        store.lights[1].orbit = -45
        store.lights[1].pitch = 35
        store.lights[1].radius = 3
        store.lights[1].intensity = 1.8
        store.lights[1].warmth = 3800
        store.lights[1].beam = 40
        store.lights[1].softness = 0.5
        controller.begin()
        controller.select(name: "fill")
        let state = try XCTUnwrap(LightsInspectorState(controller))
        XCTAssertEqual(state.name, "fill")
        XCTAssertEqual(state.index, 1)
        XCTAssertEqual(state.rows.map(\.parameter), LightParameter.allCases)
        XCTAssertEqual(state.rows.map(\.value), [-45, 35, 3, 1.8, 3800, 40, 0.5])
        XCTAssertEqual(state.rows.map(\.text),
                       ["−45°", "+35°", "3.0× · 30 Å", "1.80", "3800 K", "40°", "0.50"])
        XCTAssertFalse(state.isPinned)
        XCTAssertEqual(state.pinValue, "Off")
    }

    func testAPinnedLightShowsItsEyePlacement() throws {
        store.setRig(["key", "fill", "rim"])
        store.lights[2].pinned = true
        store.eyePlacements["rim"] = LightPlacement(orbit: 100, pitch: -20, radius: 2)
        controller.begin()
        controller.select(name: "rim")
        let state = try XCTUnwrap(LightsInspectorState(controller))
        XCTAssertTrue(state.isPinned)
        XCTAssertEqual(state.pinValue, "On")
        XCTAssertEqual(state.row(.orbit)?.value, 100, "the eye-space orbit, not the stored 0")
        XCTAssertEqual(state.row(.pitch)?.value, -20)
        XCTAssertEqual(state.row(.radius)?.value, 2)
        XCTAssertEqual(state.row(.beam)?.value, 45, "the stored beam")
    }

    func testHeaderMenuCarriesTheSlotsAndTheCheckmark() throws {
        begin(with: ["key", "fill", "rim"])
        controller.select(index: 2)
        let state = try XCTUnwrap(LightsInspectorState(controller))
        XCTAssertEqual(state.menu.map(\.name), ["key", "fill", "rim"])
        XCTAssertEqual(state.menu.map(\.slot), [0, 1, 2])
        XCTAssertEqual(state.menu.map(\.isSelected), [false, false, true])
        XCTAssertEqual(state.slot, 2)
        XCTAssertEqual(state.slot, controller.identitySlot(for: "rim"), "the same dot as the chip")
    }

    func testSwatchSelection() throws {
        store.setRig(["key"])
        store.lights[0].color = SIMD3(0, 1, 1)
        controller.begin()
        var state = try XCTUnwrap(LightsInspectorState(controller))
        XCTAssertEqual(state.swatchIndex, 1)
        XCTAssertEqual(state.swatches.map(\.name), ["White", "Cyan", "Magenta", "Violet", "Green", "Red"])
        XCTAssertEqual(state.swatches.map(\.isSelected), [false, true, false, false, false, false])

        store.lights[0].color = SIMD3(0.3, 0.2, 0.1)
        controller.refresh()
        state = try XCTUnwrap(LightsInspectorState(controller))
        XCTAssertNil(state.swatchIndex, "a custom colour selects no swatch")
        XCTAssertFalse(state.swatches.contains(where: \.isSelected))

        // Cyan as a colour picker hands it back through Display P3.
        let p3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let echoed = try XCTUnwrap(LightColour.cgColor(SIMD3(0, 1, 1))
            .converted(to: p3, intent: .defaultIntent, options: nil))
        store.lights[0].color = try XCTUnwrap(LightColour.srgb(from: echoed))
        controller.refresh()
        state = try XCTUnwrap(LightsInspectorState(controller))
        XCTAssertEqual(state.swatchIndex, 1, "a P3-echoed cyan still selects cyan")
    }

    func testBusyAndRigOff() throws {
        begin(with: ["key", "fill"], enabled: false)
        var state = try XCTUnwrap(LightsInspectorState(controller))
        XCTAssertFalse(state.isOn)
        XCTAssertEqual(state.status, "Lights off")
        XCTAssertEqual(state.status, LightsInspectorState.rigOffText)
        XCTAssertTrue(state.canEdit, "edits still apply while the rig is off")
        XCTAssertEqual(controller.set(.intensity, 2), .ok)

        controller.setEnabled(true)
        state = try XCTUnwrap(LightsInspectorState(controller))
        XCTAssertNil(state.status)
        XCTAssertTrue(state.canDelete)

        store.busy = true
        state = try XCTUnwrap(LightsInspectorState(controller))
        XCTAssertFalse(state.canEdit)
        XCTAssertFalse(state.canDelete)
        XCTAssertFalse(state.canRevertLight)
    }

    func testRevertThisLightEnablement() throws {
        begin(with: ["key", "fill"])
        XCTAssertFalse(try XCTUnwrap(LightsInspectorState(controller)).canRevertLight, "unchanged")
        controller.set(.beam, 60)
        XCTAssertTrue(try XCTUnwrap(LightsInspectorState(controller)).canRevertLight)
        controller.select(name: "fill")
        XCTAssertFalse(try XCTUnwrap(LightsInspectorState(controller)).canRevertLight, "fill unchanged")
    }

    func testLabelsAndSummary() throws {
        store.setRig(["key", "fill"])
        store.lights[0].orbit = -45
        store.lights[0].pitch = 35
        store.lights[0].radius = 3
        store.lights[0].intensity = 1.8
        store.lights[0].warmth = 3800
        store.lights[0].beam = 40
        store.lights[0].softness = 0.5
        store.lights[0].color = SIMD3(0, 1, 1)
        controller.begin()
        let state = try XCTUnwrap(LightsInspectorState(controller))
        XCTAssertEqual(state.containerLabel, "Light inspector, key")
        XCTAssertEqual(state.summary,
                       "key slot=0 pin=0 shadow=0 on=1 orbit=-45.0 pitch=35.0 radius=3.00 intensity=1.80"
                       + " warmth=3800 beam=40.0 softness=0.50 color=0.000,1.000,1.000 swatch=Cyan"
                       + " edit=1 revert=0")
        XCTAssertEqual(state.summary, try XCTUnwrap(LightsInspectorState(controller)).summary, "stable")
    }

    // MARK: Shadow, the refusal notice and the Shadows hint (Part 5)

    func testShadowToggleState() throws {
        begin(with: ["key", "fill"])
        var state = try XCTUnwrap(LightsInspectorState(controller))
        XCTAssertFalse(state.isShadowed)
        XCTAssertEqual(state.shadowValue, "Off")
        XCTAssertEqual(controller.setShadow(true), .ok)   // what the chip does
        state = try XCTUnwrap(LightsInspectorState(controller))
        XCTAssertTrue(state.isShadowed)
        XCTAssertEqual(state.shadowValue, "On")
        XCTAssertTrue(state.summary.contains(" shadow=1 "), state.summary)
        controller.select(name: "fill")
        XCTAssertFalse(try XCTUnwrap(LightsInspectorState(controller)).isShadowed, "per light")
    }

    func testTheRefusalNotice() throws {
        store.setRig(["key", "fill", "rim", "light4"])
        for i in 0..<3 { store.lights[i].shadow = true }
        controller.begin()
        controller.select(name: "light4")
        XCTAssertNil(try XCTUnwrap(LightsInspectorState(controller)).notice)
        XCTAssertEqual(controller.setShadow(true), .refused)
        var state = try XCTUnwrap(LightsInspectorState(controller))
        XCTAssertEqual(state.notice, "At most 3 lights cast shadows. Turn one off first.")
        XCTAssertEqual(state.notice, LightsInspectorState.shadowCapNotice)
        XCTAssertFalse(state.isShadowed, "the toggle stays off")
        XCTAssertTrue(state.summary.hasSuffix(" notice=shadow_cap"), state.summary)
        // The next edit clears it.
        XCTAssertEqual(controller.set(.beam, 50), .ok)
        state = try XCTUnwrap(LightsInspectorState(controller))
        XCTAssertNil(state.notice)
        XCTAssertFalse(state.summary.contains("notice="), state.summary)
        // So does a selection change.
        XCTAssertEqual(controller.setShadow(true), .refused)
        controller.select(name: "key")
        XCTAssertNil(try XCTUnwrap(LightsInspectorState(controller)).notice)
    }

    func testTheShadowsHint() throws {
        store.setRig(["key", "fill"])
        store.lights[0].shadow = true
        controller.begin()
        func hint(_ scene: Bool?) throws -> Bool {
            try XCTUnwrap(LightsInspectorState(controller, sceneShadowsOn: scene)).showsShadowsHint
        }
        XCTAssertTrue(try hint(false), "a shadowed light while the Shadows switch is off")
        XCTAssertFalse(try hint(true), "the switch is on: the shadow shows")
        XCTAssertFalse(try hint(nil), "not read yet: no hint")
        XCTAssertFalse(try XCTUnwrap(LightsInspectorState(controller)).showsShadowsHint,
                       "unknown by default")
        let state = try XCTUnwrap(LightsInspectorState(controller, sceneShadowsOn: false))
        XCTAssertTrue(state.summary.hasSuffix(" hint=shadows_off"), state.summary)
        // A light without a shadow needs no hint.
        controller.select(name: "fill")
        XCTAssertFalse(try hint(false))
        // Turning its shadow on brings the hint.
        XCTAssertEqual(controller.setShadow(true), .ok)
        XCTAssertTrue(try hint(false))
        // The rig being off does not change it (the Lights off status says that).
        store.enabled = false
        controller.refresh()
        XCTAssertTrue(try hint(false))
    }
}

// MARK: - The DEBUG edit hook

#if DEBUG
@MainActor
final class LightsAutoEditTests: XCTestCase {
    func testParsesEveryTokenKind() {
        let parsed = LightsAutoEdit.parse("orbit:120;pin:1;color:0:1:1;expand")
        XCTAssertEqual(parsed.tokens, [.set(.orbit, 120), .pin(true), .color(SIMD3(0, 1, 1)), .expand])
        XCTAssertEqual(parsed.rejected, [])
        XCTAssertTrue(parsed.expands)
        for p in LightParameter.allCases {
            XCTAssertEqual(LightsAutoEdit.parse("\(p.rawValue):2").tokens, [.set(p, 2)], "\(p)")
        }
        XCTAssertEqual(LightsAutoEdit.parse("pin:0").tokens, [.pin(false)])
        XCTAssertEqual(LightsAutoEdit.parse("shadow:1;shadow:0").tokens, [.shadow(true), .shadow(false)])
        XCTAssertFalse(LightsAutoEdit.parse("orbit:1").expands)
        XCTAssertEqual(LightsAutoEdit.parse("").tokens, [])
    }

    func testUnknownTokensAndBadNumbersAreReported() {
        let parsed = LightsAutoEdit.parse(
            "spin:3;orbit:x;pin:2;color:1:2;; beam:40 ;warmth:nan;expand:1;shadow:2;shadow")
        XCTAssertEqual(parsed.tokens, [.set(.beam, 40)])
        XCTAssertEqual(parsed.rejected, ["spin:3", "orbit:x", "pin:2", "color:1:2", "warmth:nan", "expand:1",
                                         "shadow:2", "shadow"])
    }

    func testAppliesThroughTheController() {
        let store = FakeRigStore()
        store.setRig(["key", "fill"])
        let controller = LightsController(seams: store.seams)
        controller.begin()
        controller.select(name: "fill")
        let entries = LightsAutoEdit.apply(
            LightsAutoEdit.parse("orbit:120;pin:1;shadow:1;color:0:1:1;expand").tokens, to: controller)
        XCTAssertEqual(entries, ["orbit=120 -> ok", "pin=1 -> ok", "shadow=1 -> ok", "color=0:1:1 -> ok"])
        XCTAssertEqual(store.lights[1].orbit, 120)
        XCTAssertTrue(store.lights[1].pinned)
        XCTAssertTrue(store.lights[1].shadow)
        XCTAssertEqual(store.lights[1].color, SIMD3(0, 1, 1))
        XCTAssertEqual(store.lights[0], FakeRigStore.Light(name: "key"), "key untouched")
        XCTAssertTrue(store.performed.isEmpty, "no button press, no Python")
    }
}
#endif

// MARK: - VoiceOver

/// The VoiceOver label and value of every control and of the card, as the
/// view takes them from LightsInspectorState. (A walk of the offscreen
/// NSHostingView's in-process accessibility tree was tried as well: SwiftUI
/// exposes no children there without an assistive client, so that check was
/// dropped, as the plan allows. VoiceOver by ear is on the #610 manual list.)
@MainActor
final class LightsInspectorAccessibilityTests: XCTestCase {
    func testModelStrings() throws {
        let store = FakeRigStore()
        store.setRig(["key", "fill"])
        store.lights[0].orbit = -45
        store.lights[0].pitch = 35
        store.lights[0].radius = 3
        let controller = LightsController(seams: store.seams)
        controller.begin()
        let state = try XCTUnwrap(LightsInspectorState(controller))

        XCTAssertEqual(state.containerLabel, "Light inspector, key")
        XCTAssertEqual(LightsInspectorState.menuLabel, "Light")
        XCTAssertEqual(LightsInspectorState.menuHint, "Choose the light to edit")
        XCTAssertEqual(LightsInspectorState.pinLabel, "Pin")
        XCTAssertEqual(state.pinValue, "Off")
        XCTAssertEqual(LightsInspectorState.collapseLabel(collapsed: false), "Collapse inspector")
        XCTAssertEqual(LightsInspectorState.collapseLabel(collapsed: true), "Expand inspector")
        XCTAssertEqual(LightsInspectorState.fieldLabel(.orbit), "Orbit in degrees")
        XCTAssertEqual(LightsInspectorState.fieldLabel(.pitch), "Pitch in degrees")
        XCTAssertEqual(state.rows.map(\.parameter.label),
                       ["Orbit", "Pitch", "Radius", "Intensity", "Warmth", "Beam", "Softness"])
        XCTAssertEqual(state.row(.orbit)?.spoken, "-45 degrees")
        XCTAssertEqual(state.row(.pitch)?.spoken, "35 degrees")
        XCTAssertEqual(state.row(.radius)?.spoken, "3.0 scene sizes, 30 angstroms")
        XCTAssertEqual(state.row(.intensity)?.spoken, "1.00")
        XCTAssertEqual(state.row(.warmth)?.spoken, "6500 kelvin")
        XCTAssertEqual(state.row(.beam)?.spoken, "45 degrees")
        XCTAssertEqual(state.row(.softness)?.spoken, "0.40")
        XCTAssertEqual(state.swatches.map(\.name), ["White", "Cyan", "Magenta", "Violet", "Green", "Red"])
        XCTAssertEqual(state.swatches.map(\.isSelected), [true, false, false, false, false, false])
        XCTAssertEqual(LightsInspectorState.customColourLabel, "Custom colour")
        XCTAssertEqual(state.revertLabel, "Revert key")
        XCTAssertEqual(state.deleteLabel, "Delete key")
        // Part 5: the Shadow chip, the notice and the Shadows hint.
        XCTAssertEqual(LightsInspectorState.shadowLabel, "Shadow")
        XCTAssertEqual(state.shadowValue, "Off")
        XCTAssertEqual(LightsInspectorState.shadowCapNotice,
                       "At most 3 lights cast shadows. Turn one off first.")
        XCTAssertEqual(LightsInspectorState.shadowsOffHint, "Shadows are off for this scene")
        XCTAssertEqual(LightsInspectorState.turnOnTitle, "Turn On")
        XCTAssertEqual(LightsInspectorState.turnOnLabel, "Turn on scene shadows")
    }
}

// MARK: - Mirroring with the bar

@MainActor
final class LightsMirroringTests: XCTestCase {
    private var store: FakeRigStore!
    private var controller: LightsController!

    override func setUp() {
        super.setUp()
        store = FakeRigStore()
        store.setRig(["key", "fill", "rim"])
        controller = LightsController(seams: store.seams)
        controller.begin()
    }

    override func tearDown() {
        controller = nil
        store = nil
        super.tearDown()
    }

    private var inspector: LightsInspectorState? { LightsInspectorState(controller) }
    private var bar: LightsBarState { LightsBarState(controller) }
    private var selectedChip: String? { bar.chips.first(where: \.isSelected)?.name }

    func testAChipTapShowsInTheInspector() {
        let chip = bar.chips[1]
        controller.select(index: chip.index)   // what the chip's button does
        XCTAssertEqual(inspector?.name, "fill")
        XCTAssertEqual(inspector?.menu.first(where: \.isSelected)?.name, "fill")
    }

    func testAHeaderMenuPickShowsAsTheSelectedChip() throws {
        let item = try XCTUnwrap(inspector?.menu[2])
        controller.select(index: item.index)   // what the menu item does
        XCTAssertEqual(selectedChip, "rim")
    }

    func testDeleteUpdatesBoth() {
        controller.select(name: "fill")
        controller.removeSelected()             // the inspector's Delete
        XCTAssertEqual(store.performed, [.remove("fill")])
        XCTAssertEqual(bar.chips.map(\.name), ["key", "rim"])
        XCTAssertEqual(inspector?.name, "rim", "the light that slid into the index")
        XCTAssertEqual(selectedChip, "rim")
        XCTAssertEqual(inspector?.menu.map(\.name), ["key", "rim"])
    }

    func testABarPresetSelectsTheFirstLightInBoth() {
        controller.select(name: "rim")
        controller.applyPreset("softbox")
        XCTAssertEqual(inspector?.name, "left")
        XCTAssertEqual(selectedChip, "left")
    }

    func testTheSlotsAgree() throws {
        for index in 0..<3 {
            controller.select(index: index)
            let state = try XCTUnwrap(inspector)
            XCTAssertEqual(state.slot, bar.chips[index].slot)
            XCTAssertEqual(state.menu.map(\.slot), bar.chips.map(\.slot))
        }
    }

    func testEditsFromTheSharedPathShowAtOnce() {
        controller.set(.intensity, 2.5)
        XCTAssertEqual(inspector?.row(.intensity)?.value, 2.5, "no run-loop turn")
        controller.setPlacement(orbit: 30, pitch: 20, radius: 2)   // what #621 and #622 call
        XCTAssertEqual(inspector?.row(.orbit)?.value, 30)
        XCTAssertEqual(inspector?.row(.pitch)?.value, 20)
        XCTAssertEqual(inspector?.row(.radius)?.value, 2)
        controller.setColour(SIMD3(1, 0, 1))
        XCTAssertEqual(inspector?.swatchIndex, 2)
        controller.setPinned(true)
        XCTAssertEqual(inspector?.isPinned, true)
        XCTAssertTrue(store.performed.isEmpty)
    }

    func testAFramePublishDoesNotRerenderTheBar() throws {
        controller.setPinned(true)
        XCTAssertEqual(inspector?.row(.orbit)?.value, 0)
        var controllerChanges = 0
        var eyeChanges = 0
        let controllerSink = controller.objectWillChange.sink { controllerChanges += 1 }
        let eyeSink = controller.eye.objectWillChange.sink { eyeChanges += 1 }
        defer {
            controllerSink.cancel()
            eyeSink.cancel()
        }
        // The camera turns: the pinned key's eye placement moves.
        store.eyePlacements["key"] = LightPlacement(orbit: 30, pitch: 30, radius: 4)
        controller.frameRendered()
        XCTAssertEqual(controllerChanges, 0, "the bar and the rest of the card are not re-rendered")
        XCTAssertGreaterThan(eyeChanges, 0, "the placement rows are")
        XCTAssertEqual(inspector?.row(.orbit)?.value, 30)
        controller.frameRendered()
        XCTAssertEqual(controllerChanges, 0)
    }
}

// MARK: - Pictures

/// The card drawn offscreen, as LightsBarSnapshotTests draws the bar (the
/// inspector alone, or the bar above the side column in the with-bar shots): an
/// NSHostingView in a borderless window far off any screen, then cacheDisplay
/// into a bitmap (the app's own view drawn into memory, no screen capture).
/// PNGs go to $RAYMOL_LIGHTSINSPECTOR_SNAPSHOT_DIR
/// (TEST_RUNNER_RAYMOL_LIGHTSINSPECTOR_SNAPSHOT_DIR on the xcodebuild line),
/// else NSTemporaryDirectory()/raymol-lightsinspector-snapshots; each is
/// logged as `LIGHTSINSPECTOR_SNAPSHOT: <path>`. Drawing must write nothing:
/// every shot checks the fake store saw no write and no button press.
@MainActor
final class LightsInspectorSnapshotTests: XCTestCase {
    private struct Shot {
        var name: String
        var dark = false
        var width: CGFloat = LightsInspector.width + 24
        var height: CGFloat = 520
        var collapsed = false
        var withBar = false
        var sceneShadowsOn: Bool?
        /// The touch profile's minimum target (44: iOS, drawn on macOS).
        var touch: CGFloat = 0
        var setUp: (FakeRigStore) -> Void = { _ in }
        var after: (LightsController, FakeRigStore) -> Void = { _, _ in }
    }

    private static var outputDirectory: URL {
        if let dir = ProcessInfo.processInfo.environment["RAYMOL_LIGHTSINSPECTOR_SNAPSHOT_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("raymol-lightsinspector-snapshots", isDirectory: true)
    }

    static func style(dark: Bool) -> LightsBarStyle {
        dark
            ? LightsBarStyle(accent: Color(.sRGB, red: 0.33, green: 0.60, blue: 1.0, opacity: 1),
                             text: Color(white: 0.92),
                             background: Color(white: 0.16))
            : LightsBarStyle(accent: Color(.sRGB, red: 0.0, green: 0.45, blue: 0.95, opacity: 1),
                             text: Color(white: 0.12),
                             background: Color(white: 0.95))
    }

    /// Sketch 3's key light.
    private static func sketchKey(_ store: FakeRigStore) {
        store.setRig(["key", "fill", "rim"])
        store.lights[0].orbit = -45
        store.lights[0].pitch = 35
        store.lights[0].radius = 3
        store.lights[0].intensity = 1.8
        store.lights[0].warmth = 3800
        store.lights[0].beam = 40
        store.lights[0].softness = 0.5
    }

    private var windows: [NSWindow] = []

    override func tearDown() {
        for window in windows { window.orderOut(nil) }
        windows = []
        super.tearDown()
    }

    func testRenderSnapshots() throws {
        let shots: [Shot] = [
            Shot(name: "key_camera_light", setUp: Self.sketchKey),
            Shot(name: "key_camera_dark", dark: true, setUp: Self.sketchKey),
            Shot(name: "rim_pinned_light", setUp: { store in
                Self.sketchKey(store)
                store.lights[2].pinned = true
                store.lights[2].color = SIMD3(0, 1, 1)
                store.eyePlacements["rim"] = LightPlacement(orbit: 150, pitch: -15, radius: 2.5)
            }, after: { controller, _ in controller.select(name: "rim") }),
            Shot(name: "custom_colour_light", setUp: { store in
                Self.sketchKey(store)
                store.lights[0].color = SIMD3(1, 0.62, 0.3)
            }),
            Shot(name: "rig_off_light", setUp: { store in
                Self.sketchKey(store)
                store.enabled = false
            }),
            Shot(name: "busy_dark", dark: true, setUp: Self.sketchKey,
                 after: { _, store in store.busy = true }),
            Shot(name: "collapsed_light", height: 120, collapsed: true, setUp: Self.sketchKey),
            Shot(name: "short_viewport_scrolls_light", height: 260, setUp: Self.sketchKey),
            // The with-bar shots draw the whole side column (the orbit card
            // above the inspector), as macLightsOverlay does.
            Shot(name: "with_bar_fill_from_bar_light", width: 900, height: 900, withBar: true,
                 setUp: Self.sketchKey,
                 after: { controller, _ in controller.select(index: 1) }),   // a chip tap
            Shot(name: "with_bar_rim_from_header_dark", dark: true, width: 900, height: 900, withBar: true,
                 setUp: Self.sketchKey,
                 after: { controller, _ in controller.select(index: 2) }),   // a header menu pick
            // Part 5: the key casts a shadow while the scene's Shadows switch is off.
            Shot(name: "shadows_off_hint_light", sceneShadowsOn: false, setUp: { store in
                Self.sketchKey(store)
                store.lights[0].shadow = true
            }),
            // Part 5: a 4th Shadow press, refused (key, fill and rim cast one).
            Shot(name: "shadow_cap_notice_dark", dark: true, sceneShadowsOn: true, setUp: { store in
                Self.sketchKey(store)
                store.lights.append(.init(name: "light4"))
                for i in 0..<3 { store.lights[i].shadow = true }
            }, after: { controller, _ in
                controller.select(name: "light4")
                XCTAssertEqual(controller.setShadow(true), .refused)
            }),
            // #623: the iOS profile. The header's menu, Shadow, Pin and
            // chevron are 44 pt targets; the six swatches are 44 pt targets in
            // three columns (the card's 260 pt of content), the custom picker
            // beside the label.
            Shot(name: "ios44_swatch_grid_light", height: 680, touch: 44, setUp: Self.sketchKey),
            Shot(name: "ios44_swatch_grid_custom_dark", dark: true, height: 680, touch: 44, setUp: { store in
                Self.sketchKey(store)
                store.lights[0].color = SIMD3(1, 0.62, 0.3)
            }),
            Shot(name: "ios44_collapsed_light", height: 120, collapsed: true, touch: 44, setUp: Self.sketchKey),
        ]
        let dir = Self.outputDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (i, shot) in shots.enumerated() {
            let url = dir.appendingPathComponent(String(format: "%02d_%@.png", i + 1, shot.name))
            try render(shot, to: url)
        }
    }

    private func render(_ shot: Shot, to url: URL) throws {
        let store = FakeRigStore()
        shot.setUp(store)
        let controller = LightsController(seams: store.seams)
        controller.begin()
        shot.after(controller, store)
        // Drawing must write nothing beyond what `after` did.
        let writesBefore = (store.numberWrites.count, store.vectorWrites.count, store.performed.count)
        let style = Self.style(dark: shot.dark)
        // A neutral viewport behind the card.
        let viewport = shot.dark ? Color(white: 0.08) : Color(white: 0.55)

        let root: AnyView
        if shot.withBar {
            root = AnyView(
                VStack(alignment: .trailing, spacing: 8) {
                    LightsBar(controller: controller, style: style, onDone: {})
                    LightsSideColumn(controller: controller, style: style,
                                     inspectorStartsCollapsed: shot.collapsed,
                                     sceneShadowsOn: shot.sceneShadowsOn)
                        .padding(.trailing, 10).padding(.bottom, 10)
                }
                .frame(width: shot.width, height: shot.height, alignment: .top)
                .background(viewport))
        } else {
            // The inspector card alone, so these pictures keep #620's meaning
            // (the orbit card has its own in LightsOrbitSnapshotTests).
            root = AnyView(
                LightsInspector(controller: controller, style: style,
                                initiallyCollapsed: shot.collapsed,
                                sceneShadowsOn: shot.sceneShadowsOn)
                    .padding(12)
                    .frame(width: shot.width, height: shot.height, alignment: .top)
                    .background(viewport)
                    .environment(\.lightsTouchMinimum, shot.touch))
        }
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: shot.dark ? .darkAqua : .aqua)
        let size = NSSize(width: shot.width, height: shot.height)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        windows.append(window)

        var rep = draw(host, in: window, size: size)
        if rep.map(Self.isFlat) ?? true {
            window.orderFrontRegardless()
            rep = draw(host, in: window, size: size)
        }
        let bitmap = try XCTUnwrap(rep, "\(shot.name): no bitmap")
        XCTAssertFalse(Self.isFlat(bitmap), "\(shot.name): the picture is one flat colour")
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: url)
        NSLog("LIGHTSINSPECTOR_SNAPSHOT: \(url.path)")
        window.orderOut(nil)

        XCTAssertEqual(store.numberWrites.count, writesBefore.0,
                       "\(shot.name): drawing wrote \(store.numberWrites.dropFirst(writesBefore.0))")
        XCTAssertEqual(store.vectorWrites.count, writesBefore.1, "\(shot.name): drawing wrote a colour")
        XCTAssertEqual(store.performed.count, writesBefore.2,
                       "\(shot.name): drawing pressed \(store.performed.dropFirst(writesBefore.2))")
        if shot.name == "shadow_cap_notice_dark" {
            XCTAssertTrue(controller.shadowRefused, "drawing must not clear the notice")
        }
    }

    private func draw(_ host: NSView, in window: NSWindow, size: NSSize) -> NSBitmapImageRep? {
        window.setContentSize(size)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// At most two colours among the sampled pixels: blank, or a bare fill.
    private static func isFlat(_ rep: NSBitmapImageRep) -> Bool {
        var seen = Set<String>()
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                seen.insert(String(format: "%.2f %.2f %.2f %.2f", c.redComponent, c.greenComponent,
                                   c.blueComponent, c.alphaComponent))
                if seen.count > 2 { return false }
            }
        }
        return true
    }
}
