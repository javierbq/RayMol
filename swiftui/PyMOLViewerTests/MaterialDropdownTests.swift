import XCTest
import SwiftUI
@testable import RayMol

/// The Inspector's per-representation Material dropdown (#490).
///
/// The material table lives in `layer1/Material.cpp` and reaches the app at
/// runtime, so these pin the two halves the Swift side owns: that the four
/// representations which HAVE a material expose the row (and the ones that do
/// not, don't), and that the runtime table is parsed and offered faithfully.
final class MaterialDropdownTests: XCTestCase {

    // MARK: - which rows exist

    /// Exactly the four representations `MaterialSettingForRep` answers for.
    /// Ribbon, mesh, dots, lines and labels keep default shading in v1, so a
    /// Material row there would promise something the renderer ignores.
    func testOnlyTheFourMaterialRepsExposeTheRow() {
        let expected = ["cartoon": "cartoon_material",
                        "surface": "surface_material",
                        "sticks": "stick_material",
                        "spheres": "sphere_material"]
        for rep in RepCatalog.order {
            guard let spec = RepCatalog.specs[rep] else { continue }
            let menus = spec.properties.filter { $0.optionSource == .materials }
            if let setting = expected[rep] {
                XCTAssertEqual(menus.count, 1, "\(rep) should have one material row")
                XCTAssertEqual(menus.first?.setting, setting)
                XCTAssertEqual(menus.first?.label, "Material")
                XCTAssertEqual(menus.first?.kind, .menu)
            } else {
                XCTAssertTrue(menus.isEmpty,
                              "\(rep) has no material setting; it must not offer the row")
            }
        }
    }

    /// The row leads its representation: the material is what the thing is made
    /// of, so it reads above transparency and the geometry knobs.
    func testTheMaterialRowComesFirst() {
        for rep in ["cartoon", "surface", "sticks", "spheres"] {
            XCTAssertEqual(RepCatalog.specs[rep]?.properties.first?.optionSource,
                           .materials, "\(rep)")
        }
    }

    /// A material must never be mistaken for a colour control: #503's
    /// non-negotiable is that materials never touch colour.
    func testTheMaterialRowIsNotAColorControl() {
        for rep in ["cartoon", "surface", "sticks", "spheres"] {
            let p = RepCatalog.specs[rep]?.properties.first
            XCTAssertNotEqual(p?.kind, .color)
            XCTAssertFalse(p?.setting.contains("color") ?? true)
        }
    }

    // MARK: - the table arrives from the core

    private func names(_ json: String) -> [(id: Int, name: String)]? {
        PyMOLEngine.parseMaterials("MATERIALS:" + json)
    }

    func testTheTableIsParsedInOrderWithDefaultFirst() {
        let m = names(#"[[0,"default"],[1,"matte"],[7,"marble"],[8,"clay"],[9,"rubber"]]"#)
        XCTAssertEqual(m?.map(\.name),
                       ["default", "matte", "marble", "clay", "rubber"])
        XCTAssertEqual(m?.map(\.id), [0, 1, 7, 8, 9])
    }

    /// Ids are NOT positions. `marble` is row 7, and a dropdown that wrote the
    /// index instead would silently set a different material.
    func testTheDropdownWritesTheIdNotTheIndex() {
        let m = names(#"[[0,"default"],[7,"marble"],[8,"clay"]]"#)
        let marble = m?.first { $0.name == "marble" }
        XCTAssertEqual(marble?.id, 7)
        XCTAssertNotEqual(marble?.id, 1)   // its position in the list
    }

    /// A malformed or empty payload yields nil, so the caller keeps the table it
    /// already has rather than emptying the menus mid-session.
    func testAMalformedPayloadIsRejectedRatherThanEmptying() {
        XCTAssertNil(names("not json"))
        XCTAssertNil(names("[]"))
        XCTAssertNil(PyMOLEngine.parseMaterials("MATERIALS:"))
    }

    /// Rows that are not [id, name] pairs are dropped, not crashed on.
    func testPartialRowsAreSkipped() {
        XCTAssertEqual(names(#"[[0,"default"],[1],["x","y"],[7,"marble"]]"#)?.map(\.name),
                       ["default", "marble"])
    }
}
