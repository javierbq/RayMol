import XCTest
import SwiftUI
@testable import RayMol

/// The Inspector's OBJECT-wide material controls (#498): the peel tri-state
/// and the two scene-wide material rows. (The legacy reflection group was
/// removed in #565.)
///
/// What these pin is the Swift half. The decisions themselves live in the core
/// and in `modules/pymol/appkit_inspector.py` — what auto-peel resolves to —
/// and are tested there. Here:
/// that the rows exist where they should, that nothing duplicates them, and
/// that the payload is parsed without inventing values.
final class MaterialInspectorTests: XCTestCase {

    // MARK: - the retired reflection triple is in no panel

    /// It used to be three slider rows in EACH of the four material-bearing rep
    /// panels: twelve controls over three object-scoped settings, every one
    /// showing the same value, and moving any one moved the other eleven.
    ///
    /// Asserted over the WHOLE catalog, not the four: a copy left behind in
    /// ribbon or mesh would be exactly as wrong and is the one a reviewer
    /// scanning the four would miss.
    func testNoRepPanelCarriesTheObjectScopedReflectionTriple() {
        // Retired outright in #565; no panel may bring them back either.
        let objectScoped = ["metal_rt_reflect", "metal_rt_reflect_tint",
                            "metal_rt_reflect_rough"]
        for rep in RepCatalog.order {
            guard let spec = RepCatalog.specs[rep] else { continue }
            for setting in objectScoped {
                XCTAssertFalse(spec.properties.contains { $0.setting == setting },
                               "\(rep) still carries \(setting), retired in #565")
            }
        }
    }

    /// The rep panels keep everything else. A collapse that took the material
    /// row or a transparency slider with it would pass the test above.
    func testTheRepPanelsKeepTheirOwnRows() {
        for (rep, setting) in ["cartoon": "cartoon_material", "surface": "surface_material",
                               "sticks": "stick_material", "spheres": "sphere_material"] {
            let props = RepCatalog.specs[rep]?.properties ?? []
            XCTAssertTrue(props.contains { $0.setting == setting }, rep)
            XCTAssertTrue(props.contains { $0.label == "Transparency" }, rep)
        }
    }

    // MARK: - peel is a TRI-state

    /// `transparency_peel` is -1 auto / 0 off / 1 on, and auto is the default.
    /// A Bool here would have to pick a meaning for auto and would write it the
    /// first time the control was touched — turning an object that was
    /// following its material into one pinned against it.
    func testPeelDefaultsToAutoNotOff() {
        XCTAssertEqual(ObjStateMeta().peel, -1)
        XCTAssertFalse(ObjStateMeta().peelResolved)
    }

    /// A payload from a build that predates these keys must read as "auto",
    /// not as "the user turned peeling off".
    func testAPayloadWithoutTheNewKeysReadsAsAuto() {
        let meta = PyMOLEngine.parseObjMeta(["state": 1, "all": 0])
        XCTAssertEqual(meta.peel, -1)
    }

    func testTheObjectRowsAreParsedFromThePayload() {
        let meta = PyMOLEngine.parseObjMeta([
            "state": 1, "all": 0,
            "peel": 1, "peel_resolved": 1,
        ])
        XCTAssertEqual(meta.peel, 1)
        XCTAssertTrue(meta.peelResolved)
    }

    // MARK: - what the controls SEND

    // The Inspector cannot be driven headlessly, so these pin the command each
    // control emits and `testing/tests/raymol/inspector_materials.py` runs the
    // same strings and pins what they do. The literal is the join; changing it
    // in one place without the other breaks a test rather than the feature
    // quietly.

    /// The control says what it does (#567): Nearest only is peel ON (1),
    /// All is peel OFF (0). Swapping the two values would be a control whose
    /// words do the opposite of what they say.
    func testTranslucentLayersLabelsMapToThePeelValues() {
        let byLabel = Dictionary(uniqueKeysWithValues:
            TranslucentLayers.options.map { ($0.label, $0.value) })
        XCTAssertEqual(byLabel["Auto"], -1)
        XCTAssertEqual(byLabel["Nearest only"], 1)
        XCTAssertEqual(byLabel["All"], 0)
        XCTAssertEqual(TranslucentLayers.options.count, 3)
    }

    /// The caption is the explanation the old "Peel transp." row lacked, and
    /// for Auto it has to say what Auto currently MEANS.
    func testTranslucentLayersCaptionSaysWhatHappens() {
        XCTAssertTrue(TranslucentLayers.caption(peel: 1, resolved: false).contains("One skin"))
        XCTAssertTrue(TranslucentLayers.caption(peel: 0, resolved: true).contains("Every layer"))
        XCTAssertTrue(TranslucentLayers.caption(peel: -1, resolved: true).contains("nearest only"))
        XCTAssertTrue(TranslucentLayers.caption(peel: -1, resolved: false).contains("all layers"))
        // any other explicit value is Nearest only, as the core reads it --
        // never "Auto"
        XCTAssertTrue(TranslucentLayers.caption(peel: 2, resolved: true).contains("One skin"))
        XCTAssertFalse(TranslucentLayers.caption(peel: 2, resolved: true).contains("Auto"))
    }

    func testThePeelControlWritesTheTriStateOnTheObject() {
        XCTAssertEqual(MaterialCommands.setPeel(-1, on: "m1"),
                       "set transparency_peel, -1, m1")
        XCTAssertEqual(MaterialCommands.setPeel(0, on: "m1"),
                       "set transparency_peel, 0, m1")
        XCTAssertEqual(MaterialCommands.setPeel(1, on: "m1"),
                       "set transparency_peel, 1, m1")
    }

    /// The gate that keeps the peel row off the objects it does not apply to.
    ///
    /// It is a GATE, not a value, so unlike every other key in this payload it
    /// defaults to OFF rather than to the setting's own default: a payload that
    /// predates it renders no row rather than an inert one.
    func testTheObjectRowsAreOffByDefaultUntilThePayloadSaysOtherwise() {
        XCTAssertFalse(ObjStateMeta().hasPeelRow)
        XCTAssertFalse(ObjStateMeta().showsObjectMaterialRows)
        XCTAssertFalse(PyMOLEngine.parseObjMeta(["state": 1]).showsObjectMaterialRows)
        XCTAssertTrue(PyMOLEngine.parseObjMeta(["peel_row": 1]).hasPeelRow)
    }

    // MARK: - the Custom material (#569)

    func testCustomReadsAsCustomOfItsBase() {
        XCTAssertEqual(CustomMaterial.label(base: "metallic", isCustom: true), "Custom (metallic)")
        XCTAssertEqual(CustomMaterial.label(base: "metallic", isCustom: false), "metallic")
        // a side chain following the cartoon says whose material it draws with
        XCTAssertEqual(CustomMaterial.label(base: "metallic", isCustom: true, follows: true),
                       "Cartoon's (metallic)")
    }

    /// The literals are the join with inspector_materials.py, which runs them.
    func testPickingANamedMaterialClearsTheLayersOverrides() {
        let lines = CustomMaterial.pick("stick_material", id: 7, clearing: ["rough", "knob5"],
                                        on: "m1").components(separatedBy: "\n")
        XCTAssertEqual(lines, ["set stick_material, 7, m1",
                               "unset stick_material_rough, m1",
                               "unset stick_material_knob5, m1"])
        // nothing to clear: one line, not ten
        XCTAssertEqual(CustomMaterial.pick("stick_material", id: 7, clearing: [], on: "m1"),
                       "set stick_material, 7, m1")
    }

    func testInheritClearsTheMaterialAndItsOverrides() {
        XCTAssertEqual(CustomMaterial.inherit("surface_material", clearing: ["tint"], on: "m1"),
                       "unset surface_material, m1\nunset surface_material_tint, m1")
        XCTAssertEqual(CustomMaterial.inherit("surface_material", clearing: [], on: "m1"),
                       "unset surface_material, m1")
    }

    func testAKnobWritesTheLayersOverride() {
        XCTAssertEqual(CustomMaterial.setKnob("sphere_material", "knob5", 0.25, on: "m1"),
                       "set sphere_material_knob5, 0.2500, m1")
        XCTAssertEqual(CustomMaterial.stem("cartoon_material"), "cartoon")
    }

    /// The race fix: a knob dragged since the last poll is cleared too.
    func testAPickClearsWhatWasTunedSinceTheLastPoll() {
        XCTAssertEqual(CustomMaterial.overrides(set: [], touched: ["rough"]), ["rough"])
        XCTAssertEqual(CustomMaterial.overrides(set: ["rough"], touched: ["rough", "tint"]),
                       ["rough", "tint"])
        XCTAssertEqual(CustomMaterial.overrides(set: ["knob5"], touched: []), ["knob5"])
    }

    /// The gate that keeps Custom off a layer that has degraded to `default`
    /// (glass on spheres or ball-and-stick): knobs come from the DRAWN
    /// material, and only when it is the one the setting names.
    func testCustomIsOfferedOnlyForTheMaterialTheLayerDraws() {
        let rough = MaterialKnobInfo(suffix: "rough", label: "Roughness", min: 0, max: 1)
        let table: [Int: [MaterialKnobInfo]] = [4: [rough], 3: [rough]]
        XCTAssertEqual(CustomMaterial.offeredKnobs(base: 4, drawn: 4, table: table), [rough])
        XCTAssertEqual(CustomMaterial.offeredKnobs(base: 4, drawn: 0, table: table), [])  // degraded
        XCTAssertEqual(CustomMaterial.offeredKnobs(base: 4, drawn: nil, table: table), []) // no payload
        XCTAssertEqual(CustomMaterial.offeredKnobs(base: 0, drawn: 0, table: table), [])
    }

    /// One short line per material: the whole table on one line is over
    /// PyMOL's ~1024-char feedback cap and would be split.
    func testEachMaterialsKnobsArriveOnTheirOwnLine() {
        let parsed = PyMOLEngine.parseMaterialKnobs(
            "MATKNOBS:7:[[\"knob2\",\"Vein scale\",0.02,1],[\"knob6\",\"Vein sharpness\",1,20]]")
        XCTAssertEqual(parsed?.0, 7)
        XCTAssertEqual(parsed?.1.map { $0.suffix }, ["knob2", "knob6"])
        XCTAssertEqual(parsed?.1.last, MaterialKnobInfo(suffix: "knob6", label: "Vein sharpness", min: 1, max: 20))
        XCTAssertNil(PyMOLEngine.parseMaterialKnobs("MATKNOBS:x:[]"))
        XCTAssertNil(PyMOLEngine.parseMaterialKnobs("MATERIALS:[[0,\"default\"]]"))
    }

    /// The fifth field says which control a knob gets (#590); a four-field row,
    /// from an older core, is a slider.
    func testAToggleKnobArrivesAsAToggle() {
        let parsed = PyMOLEngine.parseMaterialKnobs(
            "MATKNOBS:4:[[\"knob1\",\"Reflection\",0,1,\"toggle\"],"
            + "[\"rough\",\"Roughness\",0,1,\"slider\"],[\"knob3\",\"Old\",0,1]]")
        XCTAssertEqual(parsed?.1.map { $0.toggle }, [true, false, false])
        XCTAssertEqual(parsed?.1.first,
                       MaterialKnobInfo(suffix: "knob1", label: "Reflection", min: 0, max: 1, toggle: true))
    }

    /// The switch is on for any amount above the knob's minimum -- every one
    /// has a visible effect, the documented 0.5 included -- and on before the
    /// first poll (every toggle is on in the table).
    func testAToggleReadsOnForAnyAmount() {
        let k = MaterialKnobInfo(suffix: "knob2", label: "Distortion", min: 0, max: 1, toggle: true)
        XCTAssertEqual(CustomMaterial.toggleValue(1, k), 1)
        XCTAssertEqual(CustomMaterial.toggleValue(0, k), 0)
        XCTAssertEqual(CustomMaterial.toggleValue(0.5, k), 1)
        XCTAssertEqual(CustomMaterial.toggleValue(0.16, k), 1)
        XCTAssertEqual(CustomMaterial.toggleValue(nil, k), 1)
    }

    func testTheRepPayloadCarriesTheCustomState() {
        let st = PyMOLEngine.parseMaterialCustom(
            ["material": ["drawn": 3, "knobs": ["reflect": 0.6, "rough": 0.05], "custom": ["rough"],
                          "set": ["rough", "knob5"]]])
        XCTAssertEqual(st?.drawn, 3)
        XCTAssertEqual(st?.set, ["rough", "knob5"])
        XCTAssertEqual(st?.knobs["rough"], 0.05)
        XCTAssertEqual(st?.custom, ["rough"])
        XCTAssertTrue(st?.isCustom ?? false)
        XCTAssertNil(PyMOLEngine.parseMaterialCustom(["vals": [:]]))
        XCTAssertFalse(MaterialCustomState().isCustom)
        XCTAssertFalse(st?.follows ?? true)  // absent reads as its own
        XCTAssertTrue(PyMOLEngine.parseMaterialCustom(
            ["material": ["drawn": 3, "follows": true]])?.follows ?? false)
    }

    // MARK: - layer Looks

    func testALookAppliesToOneLayer() {
        XCTAssertEqual(CustomMaterial.applyLook("gold", "stick_material", on: "m1"),
                       "apply_look gold, m1, stick")
        XCTAssertEqual(CustomMaterial.applyLook("statuary", "surface_material", on: "m1"),
                       "apply_look statuary, m1, surface")
    }

    func testTheLookListParses() {
        let looks = PyMOLEngine.parseLooks(
            "LOOKS:[[\"gold\",\"Gold\",\"metallic\"],[\"statuary\",\"Marble (statuary)\",\"marble\"]]")
        XCTAssertEqual(looks, [MaterialLook(name: "gold", label: "Gold", material: "metallic"),
                               MaterialLook(name: "statuary", label: "Marble (statuary)", material: "marble")])
        XCTAssertNil(PyMOLEngine.parseLooks("LOOKS:[]"))
        XCTAssertNil(PyMOLEngine.parseLooks("MATERIALS:[[0,\"default\"]]"))
    }

    // MARK: - the two scene-wide rows

    /// The Scene panel's global Reflections / tint / roughness sliders drove
    /// the retired triple's global fallback (#565) and went with it.
    func testTheSceneCatalogOffersNoRetiredReflectionSlider() {
        let names = Set(SceneCatalog.params.map { $0.setting })
        for n in ["metal_rt_reflect", "metal_rt_reflect_tint", "metal_rt_reflect_rough"] {
            XCTAssertFalse(names.contains(n), n)
        }
        // ...while the two global RT reflection knobs stay
        XCTAssertTrue(names.contains("metal_rt_reflect_env"))
        XCTAssertTrue(names.contains("metal_rt_reflect_samples"))
    }

    func testTheSceneCatalogOffersBothMaterialRows() {
        let byName = Dictionary(uniqueKeysWithValues:
            SceneCatalog.params.map { ($0.setting, $0) })
        XCTAssertNotNil(byName["material_default"])
        XCTAssertNotNil(byName["material_env"])
        XCTAssertEqual(byName["material_default"]?.kind, .menu)
        XCTAssertEqual(byName["material_env"]?.kind, .menu)
    }

    /// The trap the `materialSettings` set exists for: `material_default` holds
    /// a material ID and takes the runtime table; `material_env` is an enum
    /// over environments that merely sits next to it. Serving the material list
    /// to it would offer "marble" as an environment and write a material id to
    /// a setting that reads 0/1/2.
    func testOnlyTheMaterialValuedSceneRowTakesTheMaterialTable() {
        XCTAssertTrue(SceneCatalog.materialSettings.contains("material_default"))
        XCTAssertFalse(SceneCatalog.materialSettings.contains("material_env"))
        let env = SceneCatalog.params.first { $0.setting == "material_env" }
        XCTAssertEqual(env?.options.map { $0.label }, ["background", "studio", "none"])
        XCTAssertEqual(env?.options.map { Int($0.value) }, [0, 1, 2])
    }

    // The "is it in SCENE_SETTINGS" check that used to live here has been
    // deleted rather than fixed. It grepped the whole of appkit_inspector.py
    // for the literal 'material_default', which also appears in
    // MATERIAL_VALUED — so removing it from SCENE_SETTINGS, the exact mutation
    // its docstring claimed to catch, left it green. That is the epic's
    // recurring shape: an assertion on a nearby observable that survives the
    // feature's death. The real check is Python-side and reads the list
    // itself: TestSceneMaterialRows.testTheSceneParamsArePolled.
}
