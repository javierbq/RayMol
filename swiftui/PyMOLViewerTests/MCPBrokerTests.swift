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
}
