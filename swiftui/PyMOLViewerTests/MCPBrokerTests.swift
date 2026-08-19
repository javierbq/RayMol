import XCTest
@testable import RayMol

/// Covers the pure core of the MCP broker: how a client decides WHICH RayMol
/// it is talking to.
///
/// This matters because the broker is spawned by a Claude client with no user
/// present to correct it. A stale registry entry that survives filtering means
/// tool calls are proxied to a dead port; a wrong disambiguation means Claude
/// silently drives a different window than the one the user is looking at.
final class MCPBrokerTests: XCTestCase {

    // MARK: - decode

    private func blob(pid: Int = 4412, port: Int = 51737, name: String = "RayMol",
                      installed: Bool = true) -> Data {
        Data("""
        {"pid":\(pid),"port":\(port),"token":"deadbeef","appPath":"/Applications/\(name).app",
         "name":"\(name)","installed":\(installed),"startedAt":"2026-08-19T10:31:02Z"}
        """.utf8)
    }

    func testDecodeReadsEveryField() {
        let i = MCPInstanceRegistry.decode(blob())
        XCTAssertEqual(i?.pid, 4412)
        XCTAssertEqual(i?.port, 51737)
        XCTAssertEqual(i?.token, "deadbeef")
        XCTAssertEqual(i?.name, "RayMol")
        XCTAssertEqual(i?.installed, true)
    }

    // A half-written or hand-edited file must not take the whole registry down:
    // the broker's job is to keep working with the instances it CAN read.
    func testDecodeRejectsGarbageWithoutThrowing() {
        XCTAssertNil(MCPInstanceRegistry.decode(Data("not json".utf8)))
        XCTAssertNil(MCPInstanceRegistry.decode(Data("{\"pid\":1}".utf8)))
        XCTAssertNil(MCPInstanceRegistry.decode(Data()))
    }

    func testDecodeAllSkipsBadEntriesAndKeepsGoodOnes() {
        let out = MCPInstanceRegistry.decodeAll([
            blob(pid: 1, name: "RayMol"),
            Data("{".utf8),
            blob(pid: 2, name: "RayMol-287", installed: false),
        ])
        XCTAssertEqual(out.map(\.pid), [1, 2])
    }

    // MARK: - keys

    func testKeyIsTheDisplayNameWhenUnique() {
        let k = MCPInstanceRegistry.keys(for: MCPInstanceRegistry.decodeAll([
            blob(pid: 1, name: "RayMol"),
            blob(pid: 2, name: "RayMol-287"),
        ]))
        XCTAssertEqual(k[1], "RayMol")
        XCTAssertEqual(k[2], "RayMol-287")
    }

    // Two checkouts can produce two apps with the SAME display name. Handing
    // Claude two identical keys would make disambiguation impossible, so the
    // pid has to enter the key — but only for the colliding names.
    func testCollidingNamesGetPidSuffixedKeys() {
        let k = MCPInstanceRegistry.keys(for: MCPInstanceRegistry.decodeAll([
            blob(pid: 1, name: "RayMol"),
            blob(pid: 2, name: "RayMol"),
            blob(pid: 3, name: "RayMol-287"),
        ]))
        XCTAssertEqual(k[1], "RayMol#1")
        XCTAssertEqual(k[2], "RayMol#2")
        XCTAssertEqual(k[3], "RayMol-287")
    }

    // MARK: - match

    func testMatchAcceptsName_KeyForm_AndBarePid() {
        let list = MCPInstanceRegistry.decodeAll([
            blob(pid: 1, name: "RayMol"),
            blob(pid: 2, name: "RayMol"),
            blob(pid: 3, name: "RayMol-287"),
        ])
        XCTAssertEqual(MCPInstanceRegistry.match("RayMol-287", in: list)?.pid, 3)
        XCTAssertEqual(MCPInstanceRegistry.match("RayMol#2", in: list)?.pid, 2)
        XCTAssertEqual(MCPInstanceRegistry.match("3", in: list)?.pid, 3)
    }

    // An ambiguous bare name must NOT resolve to an arbitrary instance —
    // silently driving the wrong window is the failure this whole design exists
    // to prevent.
    func testMatchRefusesAnAmbiguousName() {
        let list = MCPInstanceRegistry.decodeAll([
            blob(pid: 1, name: "RayMol"),
            blob(pid: 2, name: "RayMol"),
        ])
        XCTAssertNil(MCPInstanceRegistry.match("RayMol", in: list))
    }

    func testMatchReturnsNilForUnknownKey() {
        let list = MCPInstanceRegistry.decodeAll([blob(pid: 1, name: "RayMol")])
        XCTAssertNil(MCPInstanceRegistry.match("Nope", in: list))
        XCTAssertNil(MCPInstanceRegistry.match("999", in: list))
    }
}
