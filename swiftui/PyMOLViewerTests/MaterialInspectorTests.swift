import XCTest
import SwiftUI
import ImageIO
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
    /// (a material id from a newer build): knobs come from the DRAWN
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

/// Glass glints on sphere impostors (#713). The sphere OIT fragment used to
/// fold glass's glints into the colour, and weighted-blended OIT scales a
/// fragment's colour by its coverage -- glass's body coverage, 0.15 -- so the
/// glints reached the screen at 15% of their strength: on surface dots the
/// glints-on and glints-off renders differed by at most 7 levels. #833 gave
/// the fragment the coverage split the VBO and cylinder paths have
/// (mat_glass_cover / light_glass_cover): the body sits at its coverage and the
/// glints go on top at full strength. These pin that.
///
/// Each test renders a red glass scene over black twice, glints on and off.
/// A pure red body has no green or blue, and over black the room reflection
/// adds none, so green and blue come from the (white) glints alone: the
/// glints-off renders measure 0 in both. The `specular` setting is not the
/// switch -- glass's glints are its own (mat_glass_shade) and ignore it -- so
/// the classic glints are toggled the way the rig scales them, by its
/// `classic` (1 vs 0) with every rig light dark, and a light's glint by its
/// `highlight`.
@MainActor
final class SphereGlassGlintTests: XCTestCase {
    private var engine: PyMOLEngine { PyMOLEngine.shared }
    private var sceneBuilt = false
    private var savedView: [Float]?
    private let w = 400, h = 300

    override func tearDown() {
        if sceneBuilt {
            engine.runPython("""
            from pymol import cmd as _c
            _c.delete('gg713')
            for _n in globals().pop('_gg713_enabled', []):
                _c.enable(_n)
            _c.set('bg_rgb', globals().pop('_gg713_bg', [0.0, 0.0, 0.0]))
            _c.set('ray_opaque_background', globals().pop('_gg713_ray_bg', 1))
            _c.set_lights(globals().pop('_gg713_rig', None))
            """)
            sceneBuilt = false
        }
        if let savedView {
            engine.restoreView(savedView, animate: 0)
            self.savedView = nil
        }
        super.tearDown()
    }

    private func requireEngine() throws {
        let deadline = Date().addingTimeInterval(20)
        while !engine.isReady && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        guard engine.isReady else {
            throw XCTSkip("the PyMOL engine did not come up under the test host")
        }
        // No export until the Metal renderer exists (a cold launch before the
        // first live frame, #654): wait for it, as McpCaptureMetalTests does.
        while !engine.metalRendererReady() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        guard engine.metalRendererReady() else {
            throw XCTSkip("no Metal renderer under the test host")
        }
    }

    /// A red glass sphere -- or, with `dots`, a red glass dot surface, which
    /// draws its dots as sphere impostors through the same fragment -- at the
    /// centre of a black background, with no rig.
    private func setupScene(dots: Bool) {
        savedView = engine.captureView()
        sceneBuilt = true
        let rep = dots
            ? """
            _c.alter('gg713', 'vdw=1.5')
            _c.set('surface_type', 1, 'gg713')
            _c.set('dot_as_spheres', 1, 'gg713')
            _c.show_as('surface', 'gg713')
            _c.set('surface_material', 'glass', 'gg713')
            """
            : """
            _c.alter('gg713', 'vdw=1.0')
            _c.show_as('spheres', 'gg713')
            _c.set('sphere_scale', 1.0, 'gg713')
            _c.set('sphere_material', 'glass', 'gg713')
            """
        engine.runPython("""
        from pymol import cmd as _c
        _gg713_enabled = _c.get_names('objects', enabled_only=1)
        _gg713_bg = list(_c.get_setting_tuple('bg_rgb')[1])
        _gg713_ray_bg = _c.get_setting_int('ray_opaque_background')
        _gg713_rig = _c.get_lights()
        for _n in _gg713_enabled:
            _c.disable(_n)
        _c.set_lights(None)
        _c.pseudoatom('gg713', pos=[0.0, 0.0, 0.0])
        \(rep)
        _c.color('red', 'gg713')
        _c.set('bg_rgb', [0.0, 0.0, 0.0])
        _c.set('ray_opaque_background', 1)
        _c.set_view((1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0,
                     0.0, 0.0, -\(dots ? "20.0" : "12.0"), 0.0, 0.0, 0.0, 5.0, 100.0, -20.0))
        """)
    }

    /// One camera-anchored key light, framed on the scene explicitly (so it
    /// sits well outside the dot surface), with the rig's classic and the
    /// light's intensity and highlight as given.
    private func setRig(classic: Double, intensity: Double, highlight: Double) {
        engine.runPython("""
        from pymol import cmd as _c
        _c.set_lights({'enabled': True, 'centre': [0.0, 0.0, 0.0], 'size': 3.0,
                       'classic': \(classic),
                       'lights': [{'name': 'key', 'anchor': 'camera', 'orbit': -30.0,
                                   'pitch': 20.0, 'intensity': \(intensity),
                                   'highlight': \(highlight)}]})
        """)
    }

    private func render(_ tag: String) throws -> [UInt8] {
        let png = NSTemporaryDirectory() + "gg713_\(tag)_\(UUID().uuidString).png"
        defer { try? FileManager.default.removeItem(atPath: png) }
        engine.renderHiResPNG(png, width: w, height: h, rayTraced: 0)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: png) as CFURL, nil),
                                   "no export written (\(tag))")
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil),
                                  "export unreadable (\(tag))")
        guard image.width == w, image.height == h else {
            XCTFail("export is \(image.width)x\(image.height), not \(w)x\(h) (\(tag))")
            throw CocoaError(.fileReadCorruptFile)
        }
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        XCTAssertTrue(drawn)
        return rgba
    }

    /// The largest green or blue difference between two renders -- the glints'
    /// channels; red also carries the body, whose lighting the classic toggle
    /// changes too -- and how many pixels have every channel >= `floor` in
    /// `on` but not in `off`.
    private func compare(_ on: [UInt8], _ off: [UInt8], floor: Int) -> (maxDelta: Int, onOnly: Int) {
        var maxDelta = 0, onOnly = 0
        for i in 0..<(w * h) {
            var onBright = true, offBright = true
            for c in 0..<3 {
                let a = Int(on[i * 4 + c]), b = Int(off[i * 4 + c])
                if c > 0 { maxDelta = max(maxDelta, abs(a - b)) }
                if a < floor { onBright = false }
                if b < floor { offBright = false }
            }
            if onBright && !offBright { onOnly += 1 }
        }
        return (maxDelta, onOnly)
    }

    /// PyMOL's own lights' glints (the key light and the headlight). They are
    /// soft by design (glass's glints peak near 0.49, #590), so they are pinned
    /// as visible, not white: >= 40 levels where the folded glints reached 7,
    /// and a glint patch whose green and blue -- absent from the red body --
    /// both clear 60. Also checked without a rig, the classic pipeline proper.
    private func assertClassicGlints(dots: Bool) throws {
        let what = dots ? "glass dots" : "glass sphere"
        setRig(classic: 0.0, intensity: 0.0, highlight: 0.0)
        let off = try render("c0")
        setRig(classic: 1.0, intensity: 0.0, highlight: 0.0)
        let onRig = try render("c1")
        engine.runPython("from pymol import cmd as _c\n_c.set_lights(None)")
        let onClassic = try render("norig")
        // Glass's body is 85% see-through, so over black it stays dark: no
        // bright, glint-free red. An opaque red sphere fills its disc with it
        // (before #833 -- and #635 -- a glass sphere drew as `default`).
        var opaqueRed = 0
        for i in stride(from: 0, to: onClassic.count, by: 4)
            where onClassic[i] >= 150 && onClassic[i + 1] < 40 && onClassic[i + 2] < 40 {
            opaqueRed += 1
        }
        print("713-body \(what) opaque red pixels: \(opaqueRed)")
        XCTAssertLessThan(opaqueRed, 50, "\(what) should draw as glass, not as an opaque red body")
        for (name, on) in [("rig classic 1", onRig), ("no rig", onClassic)] {
            let r = compare(on, off, floor: 60)
            print("713-classic \(what) \(name) vs classic 0: \(r)")
            XCTAssertGreaterThanOrEqual(r.maxDelta, 40,
                "\(what), \(name): the classic glints should move a pixel >= 40 levels (#713)")
            XCTAssertGreaterThanOrEqual(r.onOnly, 10,
                "\(what), \(name): the classic glints should leave a patch with green and blue >= 60 (#713)")
        }
    }

    /// A studio light's glint at full highlight: sharp and near white.
    private func assertKeyLightGlint(dots: Bool) throws {
        let what = dots ? "glass dots" : "glass sphere"
        setRig(classic: 0.0, intensity: 1.0, highlight: 0.0)
        let off = try render("hi0")
        setRig(classic: 0.0, intensity: 1.0, highlight: 1.0)
        let on = try render("hi1")
        let r = compare(on, off, floor: 200)
        print("713-key \(what) highlight 1 vs 0: \(r)")
        XCTAssertGreaterThanOrEqual(r.maxDelta, 40,
            "\(what): the key light's glint should move a pixel >= 40 levels (#713)")
        XCTAssertGreaterThanOrEqual(r.onOnly, 10,
            "\(what): the key light's glint should be near white (every channel >= 200) (#713)")
    }

    func testClassicGlintsShowOnAGlassSphere() throws {
        try requireEngine()
        setupScene(dots: false)
        try assertClassicGlints(dots: false)
    }

    func testStudioKeyLightGlintShowsOnAGlassSphere() throws {
        try requireEngine()
        setupScene(dots: false)
        try assertKeyLightGlint(dots: false)
    }

    /// The case #713 was measured on: surface dots in glass, drawn as sphere
    /// impostors through the same OIT fragment.
    func testGlintsShowOnGlassSurfaceDots() throws {
        try requireEngine()
        setupScene(dots: true)
        try assertClassicGlints(dots: true)
        try assertKeyLightGlint(dots: true)
    }
}

/// Glass and frosted glass on ball-and-stick spheres (issue #834). The same
/// scene as `SphereGlassRenderTests`, but the red 1 A ball at the centre is a
/// `stick_ball` of a stick rep (radius = ratio 20 x stick_radius 0.05); the
/// thin stick runs off to the right through a sliver of the centre box.
@MainActor
final class StickBallGlassRenderTests: XCTestCase {
    private var engine: PyMOLEngine { PyMOLEngine.shared }
    private var sceneBuilt = false
    private var savedView: [Float]?

    override func tearDown() {
        if sceneBuilt {
            engine.runPython("""
            from pymol import cmd as _c
            _c.delete('sb834')
            _c.set('bg_rgb', globals().pop('_sb834_bg', [0.0, 0.0, 0.0]))
            _c.set('ray_opaque_background', globals().pop('_sb834_ray_bg', 1))
            for _n in globals().pop('_sb834_enabled', []):
                _c.enable(_n)
            """)
            sceneBuilt = false
        }
        if let savedView {
            engine.restoreView(savedView, animate: 0)
            self.savedView = nil
        }
        super.tearDown()
    }

    private func requireEngine() throws {
        let deadline = Date().addingTimeInterval(20)
        while !engine.isReady && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        guard engine.isReady else {
            throw XCTSkip("the PyMOL engine did not come up under the test host")
        }
    }

    private func setupScene() {
        savedView = engine.captureView()
        sceneBuilt = true
        engine.runPython("""
        from pymol import cmd as _c
        _sb834_enabled = _c.get_names('objects', enabled_only=1)
        _sb834_bg = list(_c.get_setting_tuple('bg_rgb')[1])
        _sb834_ray_bg = _c.get_setting_int('ray_opaque_background')
        for _n in _sb834_enabled:
            _c.disable(_n)
        _c.pseudoatom('sb834', name='A1', pos=[0.0, 0.0, 0.0])
        _c.pseudoatom('sb834', name='A2', pos=[3.5, 0.0, 0.0])
        _c.bond('sb834 and name A1', 'sb834 and name A2')
        _c.show_as('sticks', 'sb834')
        _c.color('red', 'sb834')
        _c.set('stick_radius', 0.05, 'sb834')
        _c.set('stick_ball', 1, 'sb834')
        _c.set('stick_ball_ratio', 20.0, 'sb834')
        _c.set('bg_rgb', [0.0, 0.0, 1.0])
        _c.set('ray_opaque_background', 1)
        _c.set_view((1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0,
                     0.0, 0.0, -12.0, 0.0, 0.0, 0.0, 5.0, 100.0, -20.0))
        """)
    }

    private func render(_ material: String) throws -> [UInt8] {
        let w = 400, h = 300
        engine.runPython("from pymol import cmd as _c\n_c.set('stick_material', '\(material)', 'sb834')")
        let png = NSTemporaryDirectory() + "sb834_\(material)_\(UUID().uuidString).png"
        defer { try? FileManager.default.removeItem(atPath: png) }
        engine.renderHiResPNG(png, width: w, height: h, rayTraced: 0)
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: png) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            XCTFail("no export written (\(material))")
            return []
        }
        XCTAssertEqual(image.width, w)
        XCTAssertEqual(image.height, h)
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        XCTAssertTrue(drawn)
        return rgba
    }

    private func centreBoxMeans(_ rgba: [UInt8], width: Int = 400, height: Int = 300) -> (r: Double, g: Double, b: Double) {
        let boxSize = 40
        let startX = (width - boxSize) / 2
        let startY = (height - boxSize) / 2
        var sumR = 0.0, sumG = 0.0, sumB = 0.0
        for y in startY..<(startY + boxSize) {
            for x in startX..<(startX + boxSize) {
                let idx = (y * width + x) * 4
                sumR += Double(rgba[idx])
                sumG += Double(rgba[idx + 1])
                sumB += Double(rgba[idx + 2])
            }
        }
        let total = Double(boxSize * boxSize)
        return (sumR / total, sumG / total, sumB / total)
    }

    func testGlassStickBallShowsTheBackgroundThrough() throws {
        try requireEngine()
        setupScene()

        let defPixels = try render("default")
        let defMeans = centreBoxMeans(defPixels)
        XCTAssertLessThan(defMeans.b, 40, "default centre box mean B should be < 40")
        XCTAssertGreaterThan(defMeans.r, 120, "default centre box mean R should be > 120")

        let glassPixels = try render("glass")
        let glassMeans = centreBoxMeans(glassPixels)
        print("834-centre default \(defMeans) glass \(glassMeans)")
        XCTAssertGreaterThanOrEqual(glassMeans.b, defMeans.b + 80, "glass centre box mean B should be >= default B + 80")
        XCTAssertGreaterThan(glassMeans.b, glassMeans.r, "glass centre box mean B should exceed mean R")
    }

    func testFrostedGlassStickBallDiffersFromClearGlass() throws {
        try requireEngine()
        setupScene()

        let clear = try render("glass")
        let frost = try render("frosted_glass")
        let totalPixels = 400 * 300
        var diffCount = 0
        for i in 0..<totalPixels {
            let dr = abs(Int(clear[i * 4]) - Int(frost[i * 4]))
            let dg = abs(Int(clear[i * 4 + 1]) - Int(frost[i * 4 + 1]))
            let db = abs(Int(clear[i * 4 + 2]) - Int(frost[i * 4 + 2]))
            let maxDiff = max(dr, max(dg, db))
            if maxDiff > 6 {
                diffCount += 1
            }
        }
        print("834-frost-diff \(diffCount)")
        XCTAssertGreaterThan(diffCount, 1000, "frosted glass should differ from clear glass in > 1000 pixels")
    }

    /// Mean RGB over a 20x20 box whose corner is `dx`, `dy` pixels from the
    /// image centre: inside the ball but clear of the sticks along the axes.
    private func offAxisBoxMeans(_ rgba: [UInt8], dx: Int = 20, dy: Int = 20,
                                 width: Int = 400, height: Int = 300) -> (r: Double, g: Double, b: Double) {
        let size = 20
        var sumR = 0.0, sumG = 0.0, sumB = 0.0
        for y in (height / 2 + dy)..<(height / 2 + dy + size) {
            for x in (width / 2 + dx)..<(width / 2 + dx + size) {
                let idx = (y * width + x) * 4
                sumR += Double(rgba[idx])
                sumG += Double(rgba[idx + 1])
                sumB += Double(rgba[idx + 2])
            }
        }
        let total = Double(size * size)
        return (sumR / total, sumG / total, sumB / total)
    }

    /// Gives the centre atom A1 three more bonds (four in all), in the image
    /// plane, so RepCylBond meets its ball once per bond.
    private func addThreeBondsToTheCentre() {
        engine.runPython("""
        from pymol import cmd as _c
        for _i, _p in enumerate(([-3.5, 0.0, 0.0], [0.0, 3.5, 0.0], [0.0, -3.5, 0.0])):
            _c.pseudoatom('sb834', name='E%d' % _i, pos=_p)
            _c.bond('sb834 and name A1', 'sb834 and name E%d' % _i)
        _c.show_as('sticks', 'sb834')
        _c.color('red', 'sb834')
        """)
    }

    /// RepCylBond emits an atom's ball once per bond and skipped a repeat only
    /// when it was strictly smaller, so an atom with four bonds drew four
    /// coincident glass balls: under OIT they stack to about 1 - 0.85^4, half
    /// opaque, where a one-bond atom's ball is 15%. A glass ball has to look
    /// the same whatever its bond count.
    func testAGlassBallLooksTheSameWhateverItsBondCount() throws {
        try requireEngine()
        setupScene()

        let one = offAxisBoxMeans(try render("glass"))
        addThreeBondsToTheCentre()
        let four = offAxisBoxMeans(try render("glass"))
        print("834-bonds one \(one) four \(four)")
        XCTAssertGreaterThan(one.b, one.r, "the one-bond glass ball shows the background")
        XCTAssertEqual(four.r, one.r, accuracy: 8, "a four-bond ball is no redder")
        XCTAssertEqual(four.b, one.b, accuracy: 8, "a four-bond ball is no less clear")
    }

    /// The printed hashes are compared by hand against the same test run on a
    /// master core (see the PR); they are not pinned here, because the exact
    /// bytes depend on the GPU. Jelly is hashed with one bond only: it is
    /// translucent, so its four-bond ball changes on purpose (one ball, not
    /// four stacked).
    func testNonGlassStickBallsAreUnchanged() throws {
        try requireEngine()
        setupScene()

        // One bond on the centre atom, then four: the four-bond scene covers
        // the opaque balls RepCylBond no longer emits twice (#834).
        for bonds in [1, 4] {
            if bonds == 4 { addThreeBondsToTheCentre() }
            var firstDefault: [UInt8] = []
            let opaque = ["default", "matte", "plastic", "metallic"]
            for name in bonds == 1 ? opaque + ["jelly"] : opaque {
                let px = try render(name)
                if name == "default" {
                    firstDefault = px
                }
                var hash: UInt64 = 0xcbf29ce484222325
                for byte in px { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
                print("834-hash \(bonds)-bond \(name) \(String(hash, radix: 16))")
            }

            _ = try render("glass")
            let secondDefault = try render("default")
            XCTAssertEqual(firstDefault, secondDefault, "second default render must be byte-identical to first default render (\(bonds) bonds)")
        }
    }
}
