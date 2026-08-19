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

    // MARK: - resolve

    private var one: [MCPInstance] { MCPInstanceRegistry.decodeAll([blob(pid: 1, name: "RayMol")]) }
    private var two: [MCPInstance] {
        MCPInstanceRegistry.decodeAll([blob(pid: 1, name: "RayMol"),
                                       blob(pid: 2, name: "RayMol-287")])
    }

    func testSingleLiveInstanceBinds() {
        XCTAssertEqual(
            MCPInstanceRegistry.resolve(instances: one, requestedKey: nil, envKey: nil, sticky: nil),
            .bound(one[0]))
    }

    func testEmptyRegistryReportsNone() {
        XCTAssertEqual(
            MCPInstanceRegistry.resolve(instances: [], requestedKey: nil, envKey: nil, sticky: nil),
            .none)
    }

    func testTwoInstancesAreAmbiguousRatherThanGuessed() {
        XCTAssertEqual(
            MCPInstanceRegistry.resolve(instances: two, requestedKey: nil, envKey: nil, sticky: nil),
            .ambiguous(two))
    }

    // Precedence: an explicit in-conversation key beats env, sticky and the scan,
    // so "use the 287 build" can rebind mid-session.
    func testRequestedKeyWinsOverEverything() {
        XCTAssertEqual(
            MCPInstanceRegistry.resolve(instances: two, requestedKey: "RayMol-287",
                                        envKey: "RayMol", sticky: two[0]),
            .bound(two[1]))
    }

    func testEnvKeyWinsOverStickyAndScan() {
        XCTAssertEqual(
            MCPInstanceRegistry.resolve(instances: two, requestedKey: nil,
                                        envKey: "RayMol-287", sticky: two[0]),
            .bound(two[1]))
    }

    // Without sticky binding a two-instance setup would re-ask on every call.
    func testStickyBindingSurvivesAnAmbiguousScan() {
        XCTAssertEqual(
            MCPInstanceRegistry.resolve(instances: two, requestedKey: nil, envKey: nil,
                                        sticky: two[0]),
            .bound(two[0]))
    }

    // The app the session was bound to quit; its entry is gone. Falling back to
    // the scan is what makes "RayMol quit mid-session" cold-launch again.
    func testStickyBindingIsDroppedWhenItsInstanceDied() {
        XCTAssertEqual(
            MCPInstanceRegistry.resolve(instances: [], requestedKey: nil, envKey: nil,
                                        sticky: two[0]),
            .none)
    }

    func testUnknownRequestedKeyIsReportedNotIgnored() {
        XCTAssertEqual(
            MCPInstanceRegistry.resolve(instances: two, requestedKey: "RayMol-999",
                                        envKey: nil, sticky: nil),
            .unknownKey("RayMol-999"))
    }

    // A stale env var must not strand a working single-instance session.
    func testUnknownEnvKeyFallsThroughToTheScan() {
        XCTAssertEqual(
            MCPInstanceRegistry.resolve(instances: one, requestedKey: nil,
                                        envKey: "RayMol-999", sticky: nil),
            .bound(one[0]))
    }

    // MARK: - selfEntry

    // `installed` decides whether the broker may treat this app as the cold-launch
    // target; deriving it from the bundle path keeps dev builds out of that role.
    func testSelfEntryMarksAnAppOutsideApplicationsAsNotInstalled() {
        XCTAssertFalse(MCPInstanceRegistry.isInstalled(path: "/Users/x/build/RayMol-287.app"))
        XCTAssertTrue(MCPInstanceRegistry.isInstalled(path: "/Applications/RayMol.app"))
    }

    func testSelfEntryRoundTripsThroughDecode() {
        let e = MCPInstance(pid: 7, port: 51737, token: "t", appPath: "/Applications/RayMol.app",
                            name: "RayMol", installed: true, startedAt: "2026-08-19T10:00:00Z")
        let data = try! JSONEncoder().encode(e)
        XCTAssertEqual(MCPInstanceRegistry.decode(data), e)
    }

    // MARK: - liveness

    // A crashed RayMol leaves its file behind. Proxying to that port either fails
    // or, worse, reaches whatever else bound it since.
    func testDeadPidsArePrunedFromAScan() {
        let mine = Int(ProcessInfo.processInfo.processIdentifier)
        let list = MCPInstanceRegistry.decodeAll([blob(pid: mine), blob(pid: 999_999, name: "Ghost")])
        XCTAssertEqual(MCPInstanceRegistry.liveOnly(list).map(\.pid), [mine])
    }

    // MARK: - offline contract

    // The pre-existing guarantee this whole change must preserve: with nothing
    // running, a client still gets a usable tools list, so the server never
    // presents as errored.
    func testOfflineToolsListStillNamesEveryTool() {
        XCTAssertEqual(MCPBridge.offlineToolNames(),
                       ["run_pymol_command", "run_python", "get_session_state",
                        "capture_viewport", "search_pdb", "list_raymol_instances"])
    }

    // MARK: - instance argument

    func testInstanceArgIsAddedToEveryToolSchema() {
        let injected = MCPBridge.withInstanceArg([
            ["name": "run_python",
             "inputSchema": ["type": "object", "properties": ["code": ["type": "string"]],
                             "required": ["code"]]],
        ])
        let schema = injected[0]["inputSchema"] as? [String: Any]
        let props = schema?["properties"] as? [String: Any]
        XCTAssertNotNil(props?["instance"], "every tool must accept an instance override")
        XCTAssertNotNil(props?["code"], "existing properties must survive injection")
        // `instance` is an override, never a requirement.
        XCTAssertEqual(schema?["required"] as? [String], ["code"])
    }

    // MARK: - ambiguity

    // The reply has to be actionable without further tool calls: it names the
    // choices AND the exact way to re-issue, or the model will just guess.
    func testAmbiguityTextListsEveryKeyAndSaysHowToRetry() {
        let list = MCPInstanceRegistry.decodeAll([
            blob(pid: 1, name: "RayMol"),
            blob(pid: 2, name: "RayMol-287", installed: false),
        ])
        let text = MCPBridge.ambiguityText(list)
        XCTAssertTrue(text.contains("RayMol"))
        XCTAssertTrue(text.contains("RayMol-287"))
        XCTAssertTrue(text.contains("instance"))
    }

    // MARK: - cold launch

    // Guards the rule that opening a Claude client must NOT open RayMol: only a
    // tool call may launch. Regressing this turns every client start into a
    // window appearing on the user's screen.
    func testOnlyToolsCallMayColdLaunch() {
        XCTAssertTrue(MCPBridge.mayColdLaunch(method: "tools/call"))
        XCTAssertFalse(MCPBridge.mayColdLaunch(method: "initialize"))
        XCTAssertFalse(MCPBridge.mayColdLaunch(method: "tools/list"))
        XCTAssertFalse(MCPBridge.mayColdLaunch(method: "ping"))
        XCTAssertFalse(MCPBridge.mayColdLaunch(method: "notifications/initialized"))
    }

    func testInstalledAppPathIsTheApplicationsBundle() {
        XCTAssertEqual(MCPBridge.installedAppPath, "/Applications/RayMol.app")
    }

    // MARK: - registration

    // The desktop-app failure this change exists to fix: a Debug build in a
    // worktree wrote its OWN path into claude_desktop_config.json, and Claude
    // reported a hard error once that build directory was cleaned.
    func testBridgeCommandPrefersTheInstalledApp() {
        XCTAssertEqual(
            MCPDesktopInstaller.preferredCommand(
                installedExists: true,
                running: "/Users/x/build_mac_dd/Build/Products/Debug/RayMol.app/Contents/MacOS/RayMol"),
            "/Applications/RayMol.app/Contents/MacOS/RayMol")
    }

    func testBridgeCommandFallsBackToTheRunningBundle() {
        XCTAssertEqual(
            MCPDesktopInstaller.preferredCommand(installedExists: false, running: "/tmp/R.app/C/MacOS/R"),
            "/tmp/R.app/C/MacOS/R")
    }

    // Claude Code must be registered as a spawnable stdio command, never as a
    // pinned loopback URL — the URL is what goes stale on every restart.
    func testClaudeCodeArgsRegisterStdioNotHttp() {
        let args = MCPServerManager.claudeCodeAddArgs(command: "/Applications/RayMol.app/Contents/MacOS/RayMol")
        XCTAssertFalse(args.contains("--transport"))
        XCTAssertFalse(args.contains(where: { $0.contains("127.0.0.1") }))
        XCTAssertEqual(Array(args.prefix(3)), ["mcp", "add", "raymol"])
        XCTAssertTrue(args.contains("--"))
        XCTAssertEqual(args.last, "--mcp-bridge")
    }

    // The e2e harness must be able to cold-launch a SUFFIXED dev build instead of
    // clobbering the user's real /Applications/RayMol.app. Same dev-only escape
    // hatch as RAYMOL_MCP_PORT, and like it, never set in a Finder/`open` launch.
    func testColdLaunchTargetHonoursTheDevOverride() {
        XCTAssertEqual(MCPBridge.coldLaunchTarget(override: nil), "/Applications/RayMol.app")
        XCTAssertEqual(MCPBridge.coldLaunchTarget(override: ""), "/Applications/RayMol.app")
        XCTAssertEqual(MCPBridge.coldLaunchTarget(override: "/tmp/RayMol-broker.app"),
                       "/tmp/RayMol-broker.app")
    }

    // MARK: - cold launch outcomes

    // Every failure must name its OWN cause. The first cut collapsed a failed
    // launch into "the MCP server didn't start", which blames the user's toggle
    // for a LaunchServices problem and sends them to the wrong setting.
    func testEachColdLaunchFailureExplainsItself() {
        let notInstalled = MCPBridge.coldLaunchMessage(.notInstalled, path: "/Applications/RayMol.app")
        XCTAssertTrue(notInstalled.contains("/Applications/RayMol.app"))
        XCTAssertFalse(notInstalled.contains("Enable AI control"))

        let running = MCPBridge.coldLaunchMessage(.alreadyRunningNotRegistered,
                                                  path: "/Applications/RayMol.app")
        XCTAssertTrue(running.contains("Enable AI control"))
        XCTAssertTrue(running.contains("already running"))

        let failed = MCPBridge.coldLaunchMessage(.launchFailed("kLSNoExecutableErr"),
                                                 path: "/Applications/RayMol.app")
        XCTAssertTrue(failed.contains("kLSNoExecutableErr"))
        XCTAssertFalse(failed.contains("Enable AI control"))

        let timedOut = MCPBridge.coldLaunchMessage(.timedOut, path: "/Applications/RayMol.app")
        XCTAssertTrue(timedOut.contains("Enable AI control"))
    }

    // A cold launch must not leave the user's settings changed. Writing
    // raymol.mcp.enabled=true would silently make EVERY future manual launch
    // start the MCP server — a preference the user never chose. The launch
    // environment carries the intent instead, and dies with the process.
    func testLaunchEnvEnablesTheServerWithoutPersistingAPreference() {
        let env = MCPBridge.launchEnvironment(portOverride: nil)
        XCTAssertEqual(env["RAYMOL_MCP_ENABLE"], "1")
        XCTAssertNil(env["RAYMOL_MCP_PORT"])

        // The harness needs the launched app off the default port when another
        // build already owns it.
        let pinned = MCPBridge.launchEnvironment(portOverride: "0")
        XCTAssertEqual(pinned["RAYMOL_MCP_PORT"], "0")
    }

    // A RayMol built BEFORE the registry existed never writes an entry, so the
    // scan sees nothing and the broker would cold-launch a SECOND copy on top of
    // the one the user is already using. The legacy handoff has to be tried
    // first — cold launch is the last resort, not the first.
    func testLegacyHandoffIsTriedBeforeColdLaunching() {
        XCTAssertFalse(MCPBridge.shouldColdLaunch(legacyReachable: true))
        XCTAssertTrue(MCPBridge.shouldColdLaunch(legacyReachable: false))
    }
}
