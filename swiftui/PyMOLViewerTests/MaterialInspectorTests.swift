import XCTest
import SwiftUI
@testable import RayMol

/// The Inspector's OBJECT-wide material controls (#498): the peel tri-state,
/// the collapsed legacy reflection group, the suggested-lighting join, and the
/// two scene-wide material rows.
///
/// What these pin is the Swift half. The decisions themselves live in the core
/// and in `modules/pymol/appkit_inspector.py` — whether the legacy triple is
/// dead for an object, what auto-peel resolves to — and are tested there. Here:
/// that the rows exist where they should, that nothing duplicates them, and
/// that the payload is parsed without inventing values.
final class MaterialInspectorTests: XCTestCase {

    // MARK: - the legacy reflection triple is object-wide, once

    /// It used to be three slider rows in EACH of the four material-bearing rep
    /// panels: twelve controls over three object-scoped settings, every one
    /// showing the same value, and moving any one moved the other eleven.
    ///
    /// Asserted over the WHOLE catalog, not the four: a copy left behind in
    /// ribbon or mesh would be exactly as wrong and is the one a reviewer
    /// scanning the four would miss.
    func testNoRepPanelCarriesTheObjectScopedReflectionTriple() {
        let objectScoped = ["metal_rt_reflect", "metal_rt_reflect_tint",
                            "metal_rt_reflect_rough"]
        for rep in RepCatalog.order {
            guard let spec = RepCatalog.specs[rep] else { continue }
            for setting in objectScoped {
                XCTAssertFalse(spec.properties.contains { $0.setting == setting },
                               "\(rep) still carries \(setting); it is object-scoped "
                               + "and belongs on the object header")
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
        XCTAssertFalse(meta.legacyReflectionDead)
        XCTAssertEqual(meta.reflect, [0, 0, 0])
    }

    func testTheObjectRowsAreParsedFromThePayload() {
        let meta = PyMOLEngine.parseObjMeta([
            "state": 1, "all": 0,
            "peel": 1, "peel_resolved": 1,
            "refl": [0.6, 0.35, 0.2], "legacy_dead": 1,
        ])
        XCTAssertEqual(meta.peel, 1)
        XCTAssertTrue(meta.peelResolved)
        XCTAssertEqual(meta.reflect, [0.6, 0.35, 0.2])
        XCTAssertTrue(meta.legacyReflectionDead)
    }

    // MARK: - suggested lighting: the join key comes from the core

    private func bundles(_ json: String) -> [(attr: String, label: String, material: String)]? {
        PyMOLEngine.parseBundles("BUNDLES:" + json)
    }

    func testBundlesAreParsedWithTheirMaterial() {
        let out = bundles("""
            [["marble","Marble (statuary)","marble"],["gold","Gold","metallic"]]
            """)
        XCTAssertEqual(out?.count, 2)
        XCTAssertEqual(out?[0].attr, "marble")
        XCTAssertEqual(out?[0].label, "Marble (statuary)")
        XCTAssertEqual(out?[0].material, "marble")
        XCTAssertEqual(out?[1].material, "metallic")
    }

    /// Several bundles share a material — the four metals are all `metallic` —
    /// which is why the control is a menu rather than a button when more than
    /// one matches, and why the parse must not collapse them into a map.
    func testSeveralBundlesMayShareTheSameMaterial() {
        let out = bundles("""
            [["copper","Copper","metallic"],["gold","Gold","metallic"],
             ["steel","Steel","metallic"],["chrome","Chrome","metallic"]]
            """)
        XCTAssertEqual(out?.count, 4)
        XCTAssertEqual(Set(out?.map { $0.material } ?? []), ["metallic"])
    }

    /// A malformed payload must leave the previous list alone rather than
    /// emptying it: the control simply not appearing is a much quieter failure
    /// than the app deciding there are no bundles.
    func testAMalformedPayloadIsRejectedRatherThanEmptying() {
        XCTAssertNil(bundles("not json"))
        XCTAssertNil(bundles("[]"))
        XCTAssertNil(PyMOLEngine.parseBundles("MATERIALS:[[0,\"default\"]]"))
    }

    /// A row missing its material, or carrying an empty attr, is DROPPED. The
    /// attr is what gets executed — a button that runs `materials.()` would be
    /// worse than no button.
    func testIncompleteBundleRowsAreSkipped() {
        let out = bundles("""
            [["marble","Marble","marble"],["clay","Clay"],["","Nameless","x"],
             ["ok","Ok",""]]
            """)
        XCTAssertEqual(out?.count, 1)
        XCTAssertEqual(out?[0].attr, "marble")
    }

    // MARK: - what the controls SEND

    // The Inspector cannot be driven headlessly, so these pin the command each
    // control emits and `testing/tests/raymol/inspector_materials.py` runs the
    // same strings and pins what they do. The literal is the join; changing it
    // in one place without the other breaks a test rather than the feature
    // quietly.

    func testThePeelControlWritesTheTriStateOnTheObject() {
        XCTAssertEqual(MaterialCommands.setPeel(-1, on: "m1"),
                       "set transparency_peel, -1, m1")
        XCTAssertEqual(MaterialCommands.setPeel(0, on: "m1"),
                       "set transparency_peel, 0, m1")
        XCTAssertEqual(MaterialCommands.setPeel(1, on: "m1"),
                       "set transparency_peel, 1, m1")
    }

    /// Object-scoped, always. A selection-scoped `set` of these would be
    /// accepted and write an atom-level value no draw path reads.
    func testTheReflectionSlidersWriteTheObject() {
        XCTAssertEqual(MaterialCommands.setReflect("metal_rt_reflect", 0.5, on: "m1"),
                       "set metal_rt_reflect, 0.5000, m1")
        XCTAssertEqual(MaterialCommands.setReflect("metal_rt_reflect_rough", 0.05, on: "obj2"),
                       "set metal_rt_reflect_rough, 0.0500, obj2")
    }

    /// The bundle is CALLED, not reimplemented: it writes global lighting as
    /// well as the object's material, and a copy of that list here would drift
    /// from modules/pymol/materials.py with nothing to catch it.
    func testTheLookButtonCallsTheBundle() {
        XCTAssertEqual(MaterialCommands.runBundle("marble", on: "m1"),
                       "python\nfrom pymol import materials; "
                       + "materials.marble('m1', _self=cmd)\npython end")
    }

    /// The chip's help has to say that the bundle rewrites the material on
    /// EVERY representation, because it does -- `_apply_material` loops all
    /// four settings by design. #498 calls this "Suggested lighting" and the
    /// first version was labelled that way, which would have let a click
    /// beside the Sticks dropdown silently replace a deliberate
    /// `surface_material, glass` with marble and never mention the surface.
    func testTheLookButtonSaysItRewritesEveryRepresentation() {
        let help = MaterialCommands.bundleHelp("Marble (statuary)")
        XCTAssertTrue(help.contains("Marble (statuary)"), help)
        XCTAssertTrue(help.contains("EVERY representation"), help)
        XCTAssertTrue(help.contains("lighting"), help)
        // The named metals write NO lighting setting -- no specular, no
        // shininess, no shadows. They write a colour and the reflect triple,
        // i.e. the group directly below the chip. An earlier version promised
        // lighting for them and said nothing about the reflection.
        XCTAssertTrue(help.contains("reflection"), help)
        XCTAssertTrue(help.contains("colour"), help)
        // ...and the many-bundles variant, which has no single label to name.
        XCTAssertTrue(MaterialCommands.bundleHelp(nil).contains("EVERY representation"))
    }

    /// The gates that keep the rows off the objects they do not apply to.
    ///
    /// They are GATES, not values, so unlike every other key in this payload
    /// they default to OFF rather than to the setting's own default: a payload
    /// that predates them renders no rows rather than inert ones.
    func testTheObjectRowsAreOffByDefaultUntilThePayloadSaysOtherwise() {
        XCTAssertFalse(ObjStateMeta().hasMaterialRows)
        XCTAssertFalse(ObjStateMeta().hasPeelRow)
        XCTAssertFalse(ObjStateMeta().showsObjectMaterialRows)
        XCTAssertFalse(PyMOLEngine.parseObjMeta(["state": 1]).showsObjectMaterialRows)
        XCTAssertTrue(PyMOLEngine.parseObjMeta(["material_rows": 1]).hasMaterialRows)
        XCTAssertTrue(PyMOLEngine.parseObjMeta(["peel_row": 1]).hasPeelRow)
    }

    /// The two gates are independent, and that asymmetry is the point: peel
    /// applies to anything SceneCollectPeelObjects can peel (an isosurface
    /// included), materials only to molecules. A single flag hid the peel
    /// control from the object class whose front/back double blend it exists
    /// to fix.
    func testPeelAndMaterialRowsAreGatedSeparately() {
        let surface = PyMOLEngine.parseObjMeta(["peel_row": 1, "material_rows": 0])
        XCTAssertTrue(surface.hasPeelRow)
        XCTAssertFalse(surface.hasMaterialRows)
        XCTAssertTrue(surface.showsObjectMaterialRows)   // the header still shows

        let group = PyMOLEngine.parseObjMeta(["peel_row": 0, "material_rows": 0])
        XCTAssertFalse(group.showsObjectMaterialRows)
    }

    /// Clearing restores the undefined state, which nothing else in the panel
    /// offers: a reflective material draws its own table row until one of
    /// these is set, and the first touch of a slider makes the displayed 0
    /// real and detaches it for good.
    func testClearingReflectionUnsetsAllThree() {
        let cmdText = MaterialCommands.clearReflect(on: "m1")
        XCTAssertEqual(cmdText, "unset metal_rt_reflect, m1\n"
                              + "unset metal_rt_reflect_tint, m1\n"
                              + "unset metal_rt_reflect_rough, m1")
    }

    /// An object name reaches a PYTHON string literal here, so a quote in it
    /// is a syntax error rather than a name. `foo'bar.pdb` loads as foo'bar.
    func testTheLookButtonEscapesTheObjectName() {
        XCTAssertEqual(MaterialCommands.runBundle("marble", on: "foo'bar"),
                       "python\nfrom pymol import materials; "
                       + "materials.marble('foo\\'bar', _self=cmd)\npython end")
    }

    // MARK: - the two scene-wide rows

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
