import XCTest
import SwiftUI
@testable import RayMol

/// The tiered "C" color menu (#379) mirrors desktop PyMOL's `all_colors_list`
/// (modules/pymol/menu.py); these pin the table's shape so a stray edit cannot
/// silently drop a family, duplicate a shade, or ship an out-of-range swatch.
final class ColorMenuTests: XCTestCase {

    /// Upstream's family order, so the SwiftUI menu reads like the desktop one.
    func testFamiliesMirrorUpstreamMenuOrder() {
        XCTAssertEqual(PyMOLColorMenu.families.map(\.label),
                       ["reds", "greens", "blues", "yellows", "magentas",
                        "cyans", "oranges", "tints", "grays"])
    }

    /// Each family opens on its canonical base color, like upstream, whose
    /// family label is tinted with the first entry of the list.
    func testEachFamilyLeadsWithItsBaseColor() {
        let leads = Dictionary(uniqueKeysWithValues:
            PyMOLColorMenu.families.map { ($0.label, $0.shades.first?.name) })
        XCTAssertEqual(leads["reds"], "red")
        XCTAssertEqual(leads["greens"], "green")
        XCTAssertEqual(leads["blues"], "blue")
        XCTAssertEqual(leads["yellows"], "yellow")
        XCTAssertEqual(leads["magentas"], "magenta")
        XCTAssertEqual(leads["cyans"], "cyan")
        XCTAssertEqual(leads["oranges"], "orange")
        XCTAssertEqual(leads["grays"], "white")
    }

    func testShadesAreDistinctWithinAFamilyAndInRange() {
        for family in PyMOLColorMenu.families {
            XCTAssertFalse(family.shades.isEmpty, "\(family.label) has no shades")
            let names = family.shades.map(\.name)
            XCTAssertEqual(names.count, Set(names).count,
                           "\(family.label) lists a shade twice: \(names)")
            for shade in family.shades {
                for (channel, v) in [("red", shade.red), ("green", shade.green), ("blue", shade.blue)] {
                    XCTAssertTrue((0.0...1.0).contains(v),
                                  "\(shade.name).\(channel) = \(v) is outside 0…1")
                }
                // Names are sent verbatim as `color <name>, <object>`: no
                // spaces or punctuation the command parser would choke on.
                XCTAssertNil(shade.name.rangeOfCharacter(from: CharacterSet.alphanumerics.union(["_"]).inverted),
                             "\(shade.name) is not a bare PyMOL color name")
            }
        }
    }

    /// Upstream lists some shades under two families (limon is a green and a
    /// yellow; wheat is a yellow and a tint). The table must agree with
    /// itself about their RGB, otherwise the swatch depends on the path taken.
    func testShadesSharedAcrossFamiliesHaveOneColor() {
        var seen: [String: PyMOLNamedColor] = [:]
        for shade in PyMOLColorMenu.families.flatMap(\.shades) {
            if let prior = seen[shade.name] {
                XCTAssertEqual(prior, shade, "\(shade.name) has two different RGB values")
            } else {
                seen[shade.name] = shade
            }
        }
        XCTAssertNotNil(seen["limon"])
        XCTAssertEqual(PyMOLColorMenu.allColorNames.count, seen.count)
    }

    /// The gray ramp in the core is `grayNN = NN / 99`, not NN / 100.
    func testGrayRampMatchesTheCoreFormula() {
        for nn in stride(from: 10, through: 90, by: 10) {
            let shade = PyMOLColorMenu.color(named: "gray\(nn)")
            XCTAssertNotNil(shade, "gray\(nn) missing from the grays family")
            XCTAssertEqual(shade?.red ?? -1, Double(nn) / 99.0, accuracy: 0.0006)
            XCTAssertEqual(shade?.red, shade?.green)
            XCTAssertEqual(shade?.red, shade?.blue)
        }
    }

    /// A few core values spot-checked against layer1/Color.cpp.
    func testSwatchesMatchTheCoreColorTable() {
        XCTAssertEqual(PyMOLColorMenu.color(named: "firebrick"),
                       PyMOLNamedColor(name: "firebrick", red: 0.698, green: 0.13, blue: 0.13))
        XCTAssertEqual(PyMOLColorMenu.color(named: "density"),
                       PyMOLNamedColor(name: "density", red: 0.1, green: 0.1, blue: 0.6))
        XCTAssertEqual(PyMOLColorMenu.color(named: "lightteal"),
                       PyMOLNamedColor(name: "lightteal", red: 0.4, green: 0.7, blue: 0.7))
        XCTAssertNil(PyMOLColorMenu.color(named: "not_a_color"))
    }

    /// The menu's color section is one row per family; a row reads as (and
    /// applies) its base color, and tints — which have no base — only expand.
    func testRowsAreTheFamiliesWithTheirBaseColors() {
        let rows = PyMOLColorMenu.rows
        XCTAssertEqual(rows.map(\.family.label), PyMOLColorMenu.families.map(\.label))
        XCTAssertEqual(rows.map(\.title),
                       ["red", "green", "blue", "yellow", "magenta", "cyan", "orange", "tints", "gray"])
        for row in rows {
            guard let primary = row.primary else {
                XCTAssertEqual(row.family.label, "tints", "only tints should be a bare submenu")
                continue
            }
            XCTAssertEqual(row.title, primary.name)
            // A clickable row must be a real core color name (see the gray note
            // below) — it is sent verbatim as `color <name>`.
            if primary.name != "gray" {
                XCTAssertEqual(PyMOLColorMenu.color(named: primary.name), primary,
                               "\(primary.name) is not in the tiered table")
                XCTAssertEqual(row.family.shades.first, primary,
                               "\(row.family.label) should lead with its base color")
            }
        }
    }

    /// `gray` (0.5) heads the grays row even though upstream's list only has
    /// the gray10…gray90 ramp; it is the classic name people type.
    func testGrayRowUsesClassicGray() {
        XCTAssertEqual(PyMOLColorMenu.gray, PyMOLNamedColor(name: "gray", red: 0.5, green: 0.5, blue: 0.5))
        XCTAssertEqual(PyMOLColorMenu.rows.last?.primary, PyMOLColorMenu.gray)
    }

    /// The modes above the color rows are actions, never bare color names.
    func testTopLevelOptionsAreColoringModes() {
        XCTAssertEqual(colorOptions.map(\.label),
                       ["by element", "by chain", "by ss", "spectrum", "by b-factor"])
        for opt in colorOptions {
            XCTAssertNil(opt.swatch, "\(opt.label) is a mode, not a color")
            XCTAssertNotNil(opt.command)
        }
    }
}
