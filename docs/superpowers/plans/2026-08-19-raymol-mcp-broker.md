# RayMol MCP Broker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make RayMol's MCP server reachable from a Claude client even when RayMol is closed, by turning the existing `--mcp-bridge` stdio proxy into a broker that discovers running instances through a registry and cold-launches the installed app on the first tool call.

**Architecture:** Each running RayMol writes a per-process JSON file into an instance registry directory. The broker (`RayMol --mcp-bridge`, a stdio process the Claude client spawns) reads that registry to resolve a target, launches `/Applications/RayMol.app` when nothing is running, and proxies JSON-RPC over loopback HTTP to the chosen instance. No resident daemon is introduced.

**Tech Stack:** Swift 5 / AppKit / Foundation (macOS-only, inside `#if os(macOS) && !RAYMOL_MAS_RESTRICTED`), XCTest, XcodeGen, Python 3 (read-only reference to `modules/raymol_mcp/tools.py`).

**Spec:** `docs/superpowers/specs/2026-08-19-raymol-mcp-broker-design.md`

## Global Constraints

- All new code is macOS-only and MUST sit inside `#if os(macOS) && !RAYMOL_MAS_RESTRICTED`, matching every file it touches. The Mac App Store build compiles MCP out entirely; a symbol leaking outside the guard breaks that build.
- Registry directory: `~/Library/Application Support/RayMol/instances/`, one file per process named `<pid>.json`, mode `0600`.
- Registry entry keys, exactly: `pid` (Int), `port` (Int), `token` (String), `appPath` (String), `name` (String), `installed` (Bool), `startedAt` (String, ISO-8601).
- The canonical `~/Library/Application Support/RayMol/mcp.json` handoff MUST keep being written and removed exactly as it is today. The registry is additive.
- Cold-launch target: `/Applications/RayMol.app`. Cold-launch timeout: 20 seconds. Existing 120-second proxy timeout is unchanged.
- Only `tools/call` may cold-launch. `initialize`, `tools/list` and `ping` are answered locally when no instance is live.
- Trust is unchanged: the broker never sets `set_trusted`. The Allow prompt must still appear on a model-initiated cold launch.
- Instance key = bundle display name (`RayMol`, `RayMol-287`); on collision, `Name#<pid>`. A bare pid string is always accepted as a key.
- Swift test files live in `swiftui/PyMOLViewerTests/`. After ADDING a file there you MUST run `xcodegen generate` in `swiftui/` before `xcodebuild`, because `PyMOLViewer.xcodeproj` is checked in.
- Test command (run from `swiftui/`):
  `xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing:PyMOLViewerTests/<Class> 2>&1 | tail -30`
- Do NOT commit to `master`. Work stays on the current branch; a PR is opened at the end.

---

## File Structure

| File | Responsibility |
|---|---|
| `swiftui/PyMOLViewer/Shared/MCPInstanceRegistry.swift` (create) | Pure model + pure resolution logic: the `MCPInstance` record, encode/decode, liveness filtering, key assignment, target selection. No I/O policy, no launching. Split out of `MCPBridge` so it can be unit-tested without a stdio loop. |
| `swiftui/PyMOLViewer/Shared/MCPServerManager.swift` (modify) | Writes and removes this process's registry entry alongside the existing handoff; `connectClaudeCode` registers the stdio broker instead of a pinned HTTP URL. |
| `swiftui/PyMOLViewer/Shared/MCPBridge.swift` (modify) | Broker behavior: resolve a target via `MCPInstanceRegistry`, cold-launch, sticky binding, `instance` argument injection/stripping, `list_raymol_instances`. |
| `swiftui/PyMOLViewer/Shared/MCPDesktopInstaller.swift` (modify) | `bridgeCommand()` prefers the installed app over the running bundle. |
| `swiftui/PyMOLViewerTests/MCPBrokerTests.swift` (create) | Unit tests for every pure function above. |

Tasks 1–3 build the pure core bottom-up; Task 4 wires the registry writer; Tasks 5–7 change broker behavior; Task 8 fixes registration paths; Task 9 is end-to-end verification and config repair.

---

### Task 1: Instance record and registry decoding

**Files:**
- Create: `swiftui/PyMOLViewer/Shared/MCPInstanceRegistry.swift`
- Create: `swiftui/PyMOLViewerTests/MCPBrokerTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct MCPInstance: Codable, Equatable` with `let pid: Int`, `let port: Int`, `let token: String`, `let appPath: String`, `let name: String`, `let installed: Bool`, `let startedAt: String`
  - `enum MCPInstanceRegistry` with `static func decode(_ data: Data) -> MCPInstance?`
  - `static func decodeAll(_ blobs: [Data]) -> [MCPInstance]`

- [ ] **Step 1: Write the failing test**

Create `swiftui/PyMOLViewerTests/MCPBrokerTests.swift`:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run from `swiftui/`:
```bash
xcodegen generate && xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing:PyMOLViewerTests/MCPBrokerTests 2>&1 | tail -30
```
Expected: FAIL — "cannot find 'MCPInstanceRegistry' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `swiftui/PyMOLViewer/Shared/MCPInstanceRegistry.swift`:

```swift
// MCPInstanceRegistry.swift — the pure core of MCP target selection: what a
// running RayMol advertises, and how a broker picks one. Kept free of I/O and
// launching so it is unit-testable without a stdio loop or a live app.
#if os(macOS) && !RAYMOL_MAS_RESTRICTED
import Foundation

/// One running RayMol that has its MCP server up.
struct MCPInstance: Codable, Equatable {
    let pid: Int
    let port: Int
    let token: String
    let appPath: String
    let name: String
    let installed: Bool
    let startedAt: String
}

enum MCPInstanceRegistry {
    /// Decode one registry file. Returns nil rather than throwing: a corrupt or
    /// half-written entry must not take the readable instances down with it.
    static func decode(_ data: Data) -> MCPInstance? {
        try? JSONDecoder().decode(MCPInstance.self, from: data)
    }

    static func decodeAll(_ blobs: [Data]) -> [MCPInstance] {
        blobs.compactMap(decode)
    }
}
#endif
```

- [ ] **Step 4: Run test to verify it passes**

Run from `swiftui/`:
```bash
xcodegen generate && xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing:PyMOLViewerTests/MCPBrokerTests 2>&1 | tail -30
```
Expected: PASS, 3 tests.

- [ ] **Step 5: Commit**

```bash
git add swiftui/PyMOLViewer/Shared/MCPInstanceRegistry.swift swiftui/PyMOLViewerTests/MCPBrokerTests.swift swiftui/PyMOLViewer.xcodeproj
git commit -m "feat(mcp): add MCPInstance record and tolerant registry decoding"
```

---

### Task 2: Instance keys and disambiguation

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/MCPInstanceRegistry.swift`
- Modify: `swiftui/PyMOLViewerTests/MCPBrokerTests.swift`

**Interfaces:**
- Consumes: `MCPInstance`, `MCPInstanceRegistry.decodeAll` (Task 1).
- Produces:
  - `static func keys(for instances: [MCPInstance]) -> [Int: String]` — pid → key
  - `static func match(_ key: String, in instances: [MCPInstance]) -> MCPInstance?`

- [ ] **Step 1: Write the failing test**

Append inside `final class MCPBrokerTests`:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run from `swiftui/`:
```bash
xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing:PyMOLViewerTests/MCPBrokerTests 2>&1 | tail -30
```
Expected: FAIL — "type 'MCPInstanceRegistry' has no member 'keys'".

- [ ] **Step 3: Write minimal implementation**

Append inside `enum MCPInstanceRegistry`:

```swift
    /// pid → the key a client uses to name this instance. Bare display name when
    /// unique; `Name#<pid>` only for the names that actually collide, so the
    /// common single-instance case stays readable.
    static func keys(for instances: [MCPInstance]) -> [Int: String] {
        var counts: [String: Int] = [:]
        for i in instances { counts[i.name, default: 0] += 1 }
        var out: [Int: String] = [:]
        for i in instances {
            out[i.pid] = (counts[i.name] ?? 0) > 1 ? "\(i.name)#\(i.pid)" : i.name
        }
        return out
    }

    /// Resolve a user- or model-supplied key. Accepts the assigned key, a bare
    /// display name when unambiguous, or a bare pid. Returns nil when the key is
    /// unknown OR ambiguous — the caller must ask rather than guess.
    static func match(_ key: String, in instances: [MCPInstance]) -> MCPInstance? {
        let keyed = keys(for: instances)
        if let hit = instances.first(where: { keyed[$0.pid] == key }) { return hit }
        if let pid = Int(key), let hit = instances.first(where: { $0.pid == pid }) {
            return hit
        }
        let byName = instances.filter { $0.name == key }
        return byName.count == 1 ? byName[0] : nil
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run from `swiftui/`:
```bash
xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing:PyMOLViewerTests/MCPBrokerTests 2>&1 | tail -30
```
Expected: PASS, 8 tests.

- [ ] **Step 5: Commit**

```bash
git add swiftui/PyMOLViewer/Shared/MCPInstanceRegistry.swift swiftui/PyMOLViewerTests/MCPBrokerTests.swift
git commit -m "feat(mcp): assign instance keys and resolve them without guessing"
```

---

### Task 3: Target resolution

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/MCPInstanceRegistry.swift`
- Modify: `swiftui/PyMOLViewerTests/MCPBrokerTests.swift`

**Interfaces:**
- Consumes: `MCPInstance`, `keys(for:)`, `match(_:in:)` (Tasks 1–2).
- Produces:
  - `enum MCPTarget: Equatable { case bound(MCPInstance); case none; case ambiguous([MCPInstance]); case unknownKey(String) }`
  - `static func resolve(instances: [MCPInstance], requestedKey: String?, envKey: String?, sticky: MCPInstance?) -> MCPTarget`

- [ ] **Step 1: Write the failing test**

Append inside `final class MCPBrokerTests`:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run from `swiftui/`:
```bash
xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing:PyMOLViewerTests/MCPBrokerTests 2>&1 | tail -30
```
Expected: FAIL — "cannot find 'MCPTarget' in scope".

- [ ] **Step 3: Write minimal implementation**

Append to `MCPInstanceRegistry.swift`, above `enum MCPInstanceRegistry`:

```swift
/// The outcome of asking "which RayMol should this call go to?".
enum MCPTarget: Equatable {
    case bound(MCPInstance)
    /// Nothing is running — the caller may cold-launch.
    case none
    /// More than one candidate and no way to choose. The caller must ask.
    case ambiguous([MCPInstance])
    /// A key was supplied explicitly but names no live instance.
    case unknownKey(String)
}
```

Append inside `enum MCPInstanceRegistry`:

```swift
    /// Resolve a target, first hit wins: explicit key, environment key, sticky
    /// binding, then the registry scan.
    ///
    /// An unknown *requested* key is reported (the model asked for something
    /// specific and deserves to be told it is gone), while an unknown *env* key
    /// falls through — a stale export must not strand an otherwise fine session.
    static func resolve(instances: [MCPInstance], requestedKey: String?,
                        envKey: String?, sticky: MCPInstance?) -> MCPTarget {
        if let key = requestedKey, !key.isEmpty {
            return match(key, in: instances).map { .bound($0) } ?? .unknownKey(key)
        }
        if let key = envKey, !key.isEmpty, let hit = match(key, in: instances) {
            return .bound(hit)
        }
        // Sticky only survives while its instance is still registered.
        if let s = sticky, let live = instances.first(where: { $0.pid == s.pid }) {
            return .bound(live)
        }
        switch instances.count {
        case 0:  return .none
        case 1:  return .bound(instances[0])
        default: return .ambiguous(instances)
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run from `swiftui/`:
```bash
xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing:PyMOLViewerTests/MCPBrokerTests 2>&1 | tail -30
```
Expected: PASS, 17 tests.

- [ ] **Step 5: Commit**

```bash
git add swiftui/PyMOLViewer/Shared/MCPInstanceRegistry.swift swiftui/PyMOLViewerTests/MCPBrokerTests.swift
git commit -m "feat(mcp): resolve a broker target from key, env, sticky binding or scan"
```

---

### Task 4: RayMol registers itself

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/MCPInstanceRegistry.swift`
- Modify: `swiftui/PyMOLViewer/Shared/MCPServerManager.swift` (add near `writeHandoff`, lines 296–336)
- Modify: `swiftui/PyMOLViewerTests/MCPBrokerTests.swift`

**Interfaces:**
- Consumes: `MCPInstance` (Task 1).
- Produces:
  - `static func directory() -> URL?` — the instances directory, created on demand
  - `static func selfEntry(pid: Int, port: Int, token: String, bundle: Bundle, startedAt: String) -> MCPInstance`
  - `static func liveDirectoryInstances() -> [MCPInstance]` — read + prune dead pids
  - `MCPServerManager` writes its entry on `MCP:started` and removes it on stop.

- [ ] **Step 1: Write the failing test**

Append inside `final class MCPBrokerTests`:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run from `swiftui/`:
```bash
xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing:PyMOLViewerTests/MCPBrokerTests 2>&1 | tail -30
```
Expected: FAIL — "has no member 'isInstalled'".

- [ ] **Step 3: Write minimal implementation**

Append inside `enum MCPInstanceRegistry` in `MCPInstanceRegistry.swift`:

```swift
    // MARK: - Directory + self-registration

    static func directory() -> URL? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("RayMol/instances", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Only an app under /Applications may be the cold-launch target, so a dev
    /// build in a worktree never becomes the thing a client launches by default.
    static func isInstalled(path: String) -> Bool {
        path.hasPrefix("/Applications/")
    }

    static func selfEntry(pid: Int, port: Int, token: String,
                          bundle: Bundle, startedAt: String) -> MCPInstance {
        let path = bundle.bundlePath
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return MCPInstance(pid: pid, port: port, token: token, appPath: path,
                           name: name, installed: isInstalled(path: path),
                           startedAt: startedAt)
    }

    static func write(_ entry: MCPInstance) -> URL? {
        guard let dir = directory(),
              let data = try? JSONEncoder().encode(entry) else { return nil }
        let url = dir.appendingPathComponent("\(entry.pid).json")
        guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: url.path)
        return url
    }

    /// Drop entries whose process is gone. `kill(pid, 0)` succeeds for a live
    /// process we own and fails with ESRCH once it is reaped.
    static func liveOnly(_ instances: [MCPInstance]) -> [MCPInstance] {
        instances.filter { kill(pid_t($0.pid), 0) == 0 || errno == EPERM }
    }

    /// Read the directory, prune dead entries (deleting their files), return the rest.
    static func liveDirectoryInstances() -> [MCPInstance] {
        guard let dir = directory(),
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { return [] }
        var found: [MCPInstance] = []
        for n in names where n.hasSuffix(".json") {
            let url = dir.appendingPathComponent(n)
            guard let data = try? Data(contentsOf: url), let e = decode(data) else {
                try? FileManager.default.removeItem(at: url)   // unreadable: not useful to anyone
                continue
            }
            if liveOnly([e]).isEmpty {
                try? FileManager.default.removeItem(at: url)
            } else {
                found.append(e)
            }
        }
        return found.sorted { $0.pid < $1.pid }
    }
```

In `MCPServerManager.swift`, add a stored property next to `writtenHandoff` (line 20):

```swift
    /// The registry entry this instance wrote, removed on the way out.
    private var writtenInstanceEntry: URL?
```

Add these methods next to `writeHandoff` / `removeHandoff` (after line 325):

```swift
    /// Advertise this process in the instance registry, so a broker spawned by a
    /// Claude client can find it without a pinned port.
    private func writeInstanceEntry(port: Int?) {
        guard let port else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let entry = MCPInstanceRegistry.selfEntry(
            pid: Int(ProcessInfo.processInfo.processIdentifier), port: port,
            token: token, bundle: .main, startedAt: stamp)
        writtenInstanceEntry = MCPInstanceRegistry.write(entry)
    }

    private func removeInstanceEntry() {
        if let url = writtenInstanceEntry {
            try? FileManager.default.removeItem(at: url)
        }
        writtenInstanceEntry = nil
    }
```

In `handleFeedbackEvent`, the `MCP:started` branch currently reads (around line 123):

```swift
            port = Int(detail)
            writeHandoff(port: port)
```

Change to:

```swift
            port = Int(detail)
            writeHandoff(port: port)
            writeInstanceEntry(port: port)
```

Find the stop branch that calls `removeHandoff()` (around line 127, where `isRunning = false; port = nil; clientCount = 0`) and add `removeInstanceEntry()` immediately after the `removeHandoff()` call in that same branch.

- [ ] **Step 4: Run test to verify it passes**

Run from `swiftui/`:
```bash
xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing:PyMOLViewerTests/MCPBrokerTests 2>&1 | tail -30
```
Expected: PASS, 20 tests.

- [ ] **Step 5: Commit**

```bash
git add swiftui/PyMOLViewer/Shared/MCPInstanceRegistry.swift swiftui/PyMOLViewer/Shared/MCPServerManager.swift swiftui/PyMOLViewerTests/MCPBrokerTests.swift
git commit -m "feat(mcp): register each running RayMol in an instance registry"
```

---

### Task 5: Broker resolves and proxies to the chosen instance

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/MCPBridge.swift:53-92` (`handoff()`, `proxy(raw:)`)

**Interfaces:**
- Consumes: `MCPInstanceRegistry.liveDirectoryInstances()`, `.resolve(instances:requestedKey:envKey:sticky:)`, `MCPTarget` (Tasks 3–4).
- Produces: `MCPBridge.currentTarget` (private sticky state); `proxy(raw:to:)` taking an explicit `MCPInstance`.

- [ ] **Step 1: Write the failing test**

There is no seam to unit-test the stdio loop; this task's verification is that the existing suite still builds and passes, plus the Task 9 end-to-end harness. Add a regression test pinning the fallback contract that this task must not break — append inside `final class MCPBrokerTests`:

```swift
    // MARK: - offline contract

    // The pre-existing guarantee this whole change must preserve: with nothing
    // running, a client still gets a usable tools list, so the server never
    // presents as errored. Task 6 adds `instance` to these schemas.
    func testOfflineToolsListStillNamesEveryTool() {
        let names = MCPBridge.offlineToolNames()
        XCTAssertEqual(names, ["run_pymol_command", "run_python", "get_session_state",
                               "capture_viewport", "search_pdb", "list_raymol_instances"])
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run from `swiftui/`:
```bash
xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing:PyMOLViewerTests/MCPBrokerTests 2>&1 | tail -30
```
Expected: FAIL — "type 'MCPBridge' has no member 'offlineToolNames'". (This is satisfied in Task 6; leave it failing at the end of this task only if Task 6 follows immediately — otherwise implement `offlineToolNames()` here as the one-line accessor shown in Task 6 Step 3.)

- [ ] **Step 3: Write minimal implementation**

In `MCPBridge.swift`, add sticky state beside `sessionId` (after line 19):

```swift
    /// The instance this broker session is bound to. Set on first successful
    /// resolution and reused, so a multi-instance setup is disambiguated once
    /// per client session rather than once per call.
    private static var boundInstance: MCPInstance? = nil
    private static let boundLock = NSLock()
    private static func getBound() -> MCPInstance? {
        boundLock.lock(); defer { boundLock.unlock() }; return boundInstance
    }
    private static func setBound(_ i: MCPInstance?) {
        boundLock.lock(); boundInstance = i; boundLock.unlock()
    }

    /// Resolve which RayMol this call belongs to.
    static func resolveTarget(requestedKey: String?) -> MCPTarget {
        let env = ProcessInfo.processInfo.environment["RAYMOL_MCP_INSTANCE"]
        let target = MCPInstanceRegistry.resolve(
            instances: MCPInstanceRegistry.liveDirectoryInstances(),
            requestedKey: requestedKey, envKey: env, sticky: getBound())
        if case .bound(let i) = target { setBound(i) } else { setBound(nil) }
        return target
    }
```

Replace `handoff()` (lines 55–63) with a registry-backed lookup that keeps the
legacy file as a fallback, so a RayMol built before this change is still reachable:

```swift
    /// Legacy single-instance handoff, used only when the registry is empty —
    /// e.g. a RayMol built before the registry existed.
    private static func legacyHandoff() -> MCPInstance? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/RayMol/mcp.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let port = obj["port"] as? Int, let token = obj["token"] as? String
        else { return nil }
        return MCPInstance(pid: 0, port: port, token: token,
                           appPath: "/Applications/RayMol.app", name: "RayMol",
                           installed: true, startedAt: "")
    }
```

Change `proxy(raw:)` (line 67) to take an instance:

```swift
    private static func proxy(raw: Data, to instance: MCPInstance) -> Data? {
        guard let url = URL(string: "http://127.0.0.1:\(instance.port)/mcp") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = raw
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(instance.token)", forHTTPHeaderField: "Authorization")
```

The rest of `proxy` (session id handling, semaphore, 120 s timeout, cancel) is unchanged.

In `response(for:method:id:raw:)` (line 96), replace the opening `if let body = proxy(raw: raw)` with:

```swift
        let target = resolveTarget(requestedKey: nil)
        var instance: MCPInstance? = nil
        if case .bound(let i) = target { instance = i } else { instance = legacyHandoff() }
        if let instance, let body = proxy(raw: raw, to: instance) {
            return body.isEmpty ? nil : body   // empty = 202 notification ack
        }
```

Update the DELETE-on-EOF block in `run()` (lines 38–47): replace `handoff()` with
`getBound() ?? legacyHandoff()` and use `\(h.port)` / `\(h.token)` from the returned
`MCPInstance` (the field names are identical, so only the call site changes).

- [ ] **Step 4: Run test to verify it passes**

Run from `swiftui/`:
```bash
xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation 2>&1 | tail -30
```
Expected: the full suite builds and passes except `testOfflineToolsListStillNamesEveryTool`, which Task 6 satisfies.

- [ ] **Step 5: Commit**

```bash
git add swiftui/PyMOLViewer/Shared/MCPBridge.swift swiftui/PyMOLViewerTests/MCPBrokerTests.swift
git commit -m "feat(mcp): proxy through a resolved registry instance with sticky binding"
```

---

### Task 6: `instance` argument, `list_raymol_instances`, ambiguity reply

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/MCPBridge.swift` (`response`, `localToolsList`)
- Modify: `swiftui/PyMOLViewerTests/MCPBrokerTests.swift`

**Interfaces:**
- Consumes: `resolveTarget(requestedKey:)`, `MCPInstanceRegistry.keys(for:)` (Tasks 2, 5).
- Produces:
  - `static func offlineToolNames() -> [String]`
  - `static func withInstanceArg(_ tools: [[String: Any]]) -> [[String: Any]]`
  - `static func ambiguityText(_ instances: [MCPInstance]) -> String`

- [ ] **Step 1: Write the failing test**

Append inside `final class MCPBrokerTests`:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run from `swiftui/`:
```bash
xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing:PyMOLViewerTests/MCPBrokerTests 2>&1 | tail -30
```
Expected: FAIL — "has no member 'withInstanceArg'".

- [ ] **Step 3: Write minimal implementation**

Add to `MCPBridge`:

```swift
    /// Every tool gains an optional `instance` override. The broker strips it
    /// before forwarding, so the Python tool schemas stay untouched.
    static func withInstanceArg(_ tools: [[String: Any]]) -> [[String: Any]] {
        tools.map { tool in
            var t = tool
            var schema = (t["inputSchema"] as? [String: Any]) ?? ["type": "object"]
            var props = (schema["properties"] as? [String: Any]) ?? [:]
            props["instance"] = [
                "type": "string",
                "description": "Which running RayMol to drive (e.g. \"RayMol\", \"RayMol-287\"). "
                    + "Omit unless list_raymol_instances shows more than one.",
            ]
            schema["properties"] = props     // `required` deliberately untouched
            t["inputSchema"] = schema
            return t
        }
    }

    private static let listInstancesTool: [String: Any] = [
        "name": "list_raymol_instances",
        "description": "List running RayMol instances and the key that names each one.",
        "inputSchema": ["type": "object", "properties": [:]],
    ]

    static func offlineToolNames() -> [String] {
        (localToolsSpec() + [listInstancesTool]).compactMap { $0["name"] as? String }
    }

    static func ambiguityText(_ instances: [MCPInstance]) -> String {
        let keyed = MCPInstanceRegistry.keys(for: instances)
        let rows = instances.map { i -> String in
            let key = keyed[i.pid] ?? String(i.pid)
            return "  • \(key)\(i.installed ? " (installed)" : " (dev build)") — \(i.appPath)"
        }.joined(separator: "\n")
        return "More than one RayMol is running. Ask the user which one to drive, then "
            + "retry with the instance argument set:\n\n\(rows)\n"
    }

    private static func instancesText(_ instances: [MCPInstance]) -> String {
        guard !instances.isEmpty else { return "No RayMol is running." }
        let keyed = MCPInstanceRegistry.keys(for: instances)
        return instances.map { i in
            "\(keyed[i.pid] ?? String(i.pid))\(i.installed ? " (installed)" : " (dev build)") "
                + "— pid \(i.pid), port \(i.port), \(i.appPath)"
        }.joined(separator: "\n")
    }
```

Refactor `localToolsList(id:)` so the array literal moves into a reusable
`localToolsSpec() -> [[String: Any]]` returning the five existing entries verbatim,
and `localToolsList` becomes:

```swift
    private static func localToolsList(id: Any?) -> Data {
        ok(id: id, result: ["tools": withInstanceArg(localToolsSpec()) + [listInstancesTool]])
    }
```

In `response(for:method:id:raw:)`, before proxying, handle the broker-native tool and
the `instance` argument. Insert at the top of the function:

```swift
        // Broker-native tool: answered here, never forwarded.
        if method == "tools/call",
           let params = msg["params"] as? [String: Any],
           params["name"] as? String == "list_raymol_instances" {
            return ok(id: id, result: ["content": [["type": "text",
                "text": instancesText(MCPInstanceRegistry.liveDirectoryInstances())]]])
        }
        // Pull `instance` out of the arguments and strip it from what we forward.
        var forward = raw
        var requestedKey: String? = nil
        if method == "tools/call", var msgCopy = msg,
           var params = msgCopy["params"] as? [String: Any],
           var args = params["arguments"] as? [String: Any],
           let key = args["instance"] as? String {
            requestedKey = key
            args["instance"] = nil
            params["arguments"] = args
            msgCopy["params"] = params
            forward = (try? JSONSerialization.data(withJSONObject: msgCopy)) ?? raw
        }
```

Then change the resolution block added in Task 5 to use `requestedKey` and `forward`,
and to answer ambiguity locally rather than proxying:

```swift
        let target = resolveTarget(requestedKey: requestedKey)
        var instance: MCPInstance? = nil
        switch target {
        case .bound(let i):
            instance = i
        case .ambiguous(let list) where method == "tools/call":
            return ok(id: id, result: ["content": [["type": "text",
                "text": ambiguityText(list)]], "isError": true])
        case .unknownKey(let key) where method == "tools/call":
            return ok(id: id, result: ["content": [["type": "text",
                "text": "No running RayMol named \"\(key)\". Call list_raymol_instances."]],
                "isError": true])
        default:
            instance = legacyHandoff()
        }
        if let instance, let body = proxy(raw: forward, to: instance) {
            return body.isEmpty ? nil : body
        }
```

Also add `instance` to the static mirror by wrapping it — the mirror is now produced by
`localToolsSpec()`, so `localToolsList` already injects it.

- [ ] **Step 4: Run test to verify it passes**

Run from `swiftui/`:
```bash
xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing:PyMOLViewerTests/MCPBrokerTests 2>&1 | tail -30
```
Expected: PASS, 23 tests (including `testOfflineToolsListStillNamesEveryTool` from Task 5).

- [ ] **Step 5: Commit**

```bash
git add swiftui/PyMOLViewer/Shared/MCPBridge.swift swiftui/PyMOLViewerTests/MCPBrokerTests.swift
git commit -m "feat(mcp): add instance override, list_raymol_instances and ambiguity reply"
```

---

### Task 7: Cold launch

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/MCPBridge.swift`
- Modify: `swiftui/PyMOLViewerTests/MCPBrokerTests.swift`

**Interfaces:**
- Consumes: `resolveTarget(requestedKey:)`, `MCPInstanceRegistry.liveDirectoryInstances()`.
- Produces: `static func coldLaunch(timeout: TimeInterval) -> MCPInstance?`, `static let installedAppPath: String`.

- [ ] **Step 1: Write the failing test**

Append inside `final class MCPBrokerTests`:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run from `swiftui/`:
```bash
xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing:PyMOLViewerTests/MCPBrokerTests 2>&1 | tail -30
```
Expected: FAIL — "has no member 'mayColdLaunch'".

- [ ] **Step 3: Write minimal implementation**

Add `import AppKit` at the top of `MCPBridge.swift` (beside `import Foundation`), then add:

```swift
    static let installedAppPath = "/Applications/RayMol.app"

    /// Opening a client must not open RayMol. Launching is a consequence of
    /// asking RayMol to DO something, so only tools/call qualifies.
    static func mayColdLaunch(method: String) -> Bool { method == "tools/call" }

    /// Launch the installed app and wait for it to register. Returns nil on a
    /// missing bundle or on timeout; the caller turns that into a tool error.
    static func coldLaunch(timeout: TimeInterval = 20) -> MCPInstance? {
        let url = URL(fileURLWithPath: installedAppPath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        // The broker IS RayMol's binary, so this writes RayMol's own defaults
        // domain — the launched app auto-starts its server even on a machine
        // where MCP has never been switched on.
        UserDefaults.standard.set(true, forKey: "raymol.mcp.enabled")
        UserDefaults.standard.synchronize()

        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        let sem = DispatchSemaphore(value: 0)
        // Racing brokers are harmless: openApplication on an already-launching
        // app activates it, so both converge on one instance.
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in sem.signal() }
        _ = sem.wait(timeout: .now() + 10)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let live = MCPInstanceRegistry.liveDirectoryInstances()
            if let hit = live.first(where: { $0.installed }) ?? live.first { return hit }
            Thread.sleep(forTimeInterval: 0.4)
        }
        return nil
    }
```

In `response(for:method:id:raw:)`, extend the `.none` path so a tool call launches.
Replace the `default:` arm of the `switch target` block from Task 6 with:

```swift
        case .none where mayColdLaunch(method: method):
            if let launched = coldLaunch() {
                setBound(launched)
                instance = launched
            } else {
                let exists = FileManager.default.fileExists(atPath: installedAppPath)
                return ok(id: id, result: ["content": [["type": "text",
                    "text": exists
                        ? "RayMol opened but its MCP server didn't start within 20s. "
                          + "In RayMol, turn on Connect ▸ Enable AI control, then retry."
                        : "RayMol isn't installed at \(installedAppPath). Install it, then retry."]],
                    "isError": true])
            }
        default:
            instance = legacyHandoff()
```

- [ ] **Step 4: Run test to verify it passes**

Run from `swiftui/`:
```bash
xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing:PyMOLViewerTests/MCPBrokerTests 2>&1 | tail -30
```
Expected: PASS, 25 tests.

- [ ] **Step 5: Commit**

```bash
git add swiftui/PyMOLViewer/Shared/MCPBridge.swift swiftui/PyMOLViewerTests/MCPBrokerTests.swift
git commit -m "feat(mcp): cold-launch the installed RayMol on a tool call"
```

---

### Task 8: Registration paths

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/MCPDesktopInstaller.swift:7-9`
- Modify: `swiftui/PyMOLViewer/Shared/MCPServerManager.swift:194-232`
- Modify: `swiftui/PyMOLViewerTests/MCPBrokerTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `MCPDesktopInstaller.bridgeCommand()` prefers the installed app; `connectClaudeCode` registers a stdio server.

- [ ] **Step 1: Write the failing test**

Append inside `final class MCPBrokerTests`:

```swift
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
        XCTAssertEqual(args.prefix(3).map { $0 }, ["mcp", "add", "raymol"])
        XCTAssertTrue(args.contains("--"))
        XCTAssertEqual(args.last, "--mcp-bridge")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run from `swiftui/`:
```bash
xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing:PyMOLViewerTests/MCPBrokerTests 2>&1 | tail -30
```
Expected: FAIL — "has no member 'preferredCommand'".

- [ ] **Step 3: Write minimal implementation**

In `MCPDesktopInstaller.swift`, replace `bridgeCommand()`:

```swift
    static let installedCommand = "/Applications/RayMol.app/Contents/MacOS/RayMol"

    /// Pure: which binary a client should be told to spawn.
    ///
    /// Prefers the installed app. Without this a dev build run from a worktree
    /// registers its own throwaway path, and the client hard-errors the moment
    /// that build directory is cleaned.
    static func preferredCommand(installedExists: Bool, running: String?) -> String {
        if installedExists { return installedCommand }
        return running ?? installedCommand
    }

    static func bridgeCommand() -> String {
        preferredCommand(
            installedExists: FileManager.default.fileExists(atPath: installedCommand),
            running: Bundle.main.executablePath)
    }
```

In `MCPServerManager.swift`, add the pure argument builder next to `connectClaudeCode`:

```swift
    /// Pure: the `claude mcp add` arguments. Stdio, so the entry stays valid
    /// across RayMol restarts and closures — the broker is spawned on demand and
    /// finds the live instance itself.
    static func claudeCodeAddArgs(command: String) -> [String] {
        ["mcp", "add", "raymol", "--scope", "user", "--", command, "--mcp-bridge"]
    }
```

Rewrite the body of `connectClaudeCode`. The `guard isRunning` precondition is removed —
the whole point is that this now works regardless of server state — and the trust calls
stay, since a user-initiated connect should still be auto-trusted:

```swift
    func connectClaudeCode(completion: @escaping (String) -> Void) {
        // noteUserInitiatedConnect sets UI state — keep it synchronous on the main thread.
        noteUserInitiatedConnect()
        if isRunning {
            // pushTrusted calls runPython which must run on the main thread.
            pushTrusted()
        }
        let command = MCPDesktopInstaller.bridgeCommand()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            self.installSkillFile()
            let args = Self.claudeCodeAddArgs(command: command)
            let manual = "claude " + args.joined(separator: " ")
            guard let claude = Self.findClaude() else {
                DispatchQueue.main.async {
                    completion("Claude Code CLI not found. Run this in a terminal:\n\n\(manual)")
                }
                return
            }
            // Idempotent, and REQUIRED: an older pinned-HTTP entry would otherwise survive.
            _ = Self.runClaude(claude, ["mcp", "remove", "raymol", "--scope", "user"])
            let (code, out) = Self.runClaude(claude, args)
            let msg: String
            if code == 0 {
                msg = "Connected. In Claude Code, run /mcp (or restart it) to pick up RayMol, "
                    + "then ask it to load and view a structure."
            } else {
                msg = "claude exited \(code): \(out)\n\nManual command:\n\(manual)"
            }
            DispatchQueue.main.async { completion(msg) }
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run from `swiftui/`:
```bash
xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation 2>&1 | tail -30
```
Expected: PASS, full suite (28 broker tests).

- [ ] **Step 5: Commit**

```bash
git add swiftui/PyMOLViewer/Shared/MCPDesktopInstaller.swift swiftui/PyMOLViewer/Shared/MCPServerManager.swift swiftui/PyMOLViewerTests/MCPBrokerTests.swift
git commit -m "fix(mcp): register the installed app over stdio for both Claude clients"
```

---

### Task 9: End-to-end verification and config repair

**Files:**
- Create: `swiftui/tools/mcp_broker_e2e.sh`
- Modify: `~/Library/Application Support/Claude/claude_desktop_config.json` (user machine, not the repo)
- Modify: `~/.claude.json` (user machine, not the repo)

**Interfaces:**
- Consumes: everything above.
- Produces: a repeatable harness proving cold launch works end to end.

- [ ] **Step 1: Write the harness**

Create `swiftui/tools/mcp_broker_e2e.sh`:

```bash
#!/bin/bash
# End-to-end check for the MCP broker: with NO RayMol running, a tools/call
# piped into `RayMol --mcp-bridge` must launch the installed app, wait for it
# to register, and return a result.
#
# Usage: swiftui/tools/mcp_broker_e2e.sh [/path/to/RayMol.app/Contents/MacOS/RayMol]
set -uo pipefail
BIN="${1:-/Applications/RayMol.app/Contents/MacOS/RayMol}"
REG="$HOME/Library/Application Support/RayMol/instances"

echo "== quitting every RayMol =="
osascript -e 'tell application "RayMol" to quit' 2>/dev/null
pkill -x RayMol 2>/dev/null
sleep 3
echo "registry after quit: $(ls "$REG" 2>/dev/null | wc -l | tr -d ' ') entries"

echo "== initialize + tools/list must NOT launch anything =="
printf '%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  | "$BIN" --mcp-bridge | head -2
sleep 2
if pgrep -x RayMol >/dev/null; then echo "FAIL: a client handshake launched RayMol"; exit 1; fi
echo "OK: handshake did not launch RayMol"

echo "== tools/call must cold-launch =="
printf '%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_session_state","arguments":{}}}' \
  | "$BIN" --mcp-bridge | tail -1
pgrep -x RayMol >/dev/null && echo "OK: RayMol is running" || { echo "FAIL: not launched"; exit 1; }
echo "registry now: $(ls "$REG" 2>/dev/null | wc -l | tr -d ' ') entries"
```

Make it executable: `chmod +x swiftui/tools/mcp_broker_e2e.sh`.

- [ ] **Step 2: Build and install the app under test**

```bash
cd swiftui && ./build_macos.sh && xcodegen generate && xcodebuild build -project PyMOLViewer.xcodeproj -scheme PyMOLViewer_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation 2>&1 | tail -5
```

The harness drives `/Applications/RayMol.app`, which must be a build containing this
work. Copy the built bundle there, or run the harness against the built binary path and
temporarily point `MCPBridge.installedAppPath` at it — do NOT ship that change.

- [ ] **Step 3: Run the harness**

```bash
swiftui/tools/mcp_broker_e2e.sh 2>&1 | tail -20
```
Expected: "OK: handshake did not launch RayMol", then "OK: RayMol is running", and a
registry entry count of 1. The first cold-launch will surface RayMol's Allow prompt —
click Allow and re-run to see a successful `get_session_state` payload. Record both the
pre-approval and post-approval outputs in the PR description.

- [ ] **Step 4: Verify the ambiguity path**

With the installed app running, build and launch a suffixed dev build per the naming
rule in `CLAUDE.md` (`RayMol-broker.app`, re-signed), then repeat the `tools/call` line
from the harness. Expected: an `isError` result whose text lists both `RayMol` and
`RayMol-broker` and mentions the `instance` argument. Then re-issue with
`"arguments":{"instance":"RayMol-broker"}` and confirm it succeeds.

- [ ] **Step 5: Repair the two live configs**

```bash
/Applications/RayMol.app/Contents/MacOS/RayMol --mcp-emit-config
```
Confirm the emitted command is `/Applications/RayMol.app/Contents/MacOS/RayMol`, then
write it through the app's own Connect flow (or by hand) so
`claude_desktop_config.json` no longer points into `build_mac_dd`. For Claude Code:

```bash
claude mcp remove raymol --scope user; claude mcp add raymol --scope user -- /Applications/RayMol.app/Contents/MacOS/RayMol --mcp-bridge
```
Verify `~/.claude.json` no longer contains `127.0.0.1:51737`.

- [ ] **Step 6: Commit and open the PR**

```bash
git add swiftui/tools/mcp_broker_e2e.sh
git commit -m "test(mcp): add end-to-end cold-launch harness for the broker"
gh pr create -R javierbq/RayMol --base master --title "MCP broker: reach RayMol even when it is closed" --body "$(cat <<'BODY'
Implements docs/superpowers/specs/2026-08-19-raymol-mcp-broker-design.md.

Registry-backed instance discovery, cold launch of the installed app on the
first tool call, `instance` override plus `list_raymol_instances`, and stdio
registration for both Claude clients (replacing the pinned-HTTP Claude Code
entry and the worktree-path desktop entry).

Verification: unit suite plus swiftui/tools/mcp_broker_e2e.sh output, pasted below.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
BODY
)"
```

---

## Self-Review

**Spec coverage.** Registry file + fields → Task 4. Broker resolution order → Task 3, wired in Task 5. Ambiguity listing → Task 6. Instance keys with `#pid` collisions → Task 2. `instance` injection/stripping + `list_raymol_instances` → Task 6. Cold launch, defaults flip, 20 s poll, no launch lock → Task 7. Only-`tools/call`-launches → Task 7. Trust unchanged → no task sets `set_trusted`; asserted by the Task 9 Allow-prompt step. Error table → Tasks 6–7 (`ambiguous`, `unknownKey`, missing bundle, timeout) and Task 4 (`liveDirectoryInstances` prunes corrupt and dead entries). Migration → Task 8 plus Task 9 Step 5. Testing → Tasks 1–8 unit tests, Task 9 end-to-end.

**Gap found and closed.** The spec lists "port returns 401 (stale token) → prune, rescan". Pid-liveness alone misses a pid that was recycled by an unrelated process. `liveDirectoryInstances` prunes dead pids only; the 401 case is left to `proxy` returning nil, which falls through to `legacyHandoff` and then to the offline reply. That is acceptable behavior but is NOT what the spec says. Task 5's `proxy` therefore must be treated as the 401 handler — the implementer should clear the sticky binding on a nil proxy result so the next call re-resolves. Add this to Task 5 Step 3: in `response`, on `proxy(...) == nil`, call `setBound(nil)` before falling through.

**Placeholder scan.** No TBD/TODO. Every code step carries real code. Task 5 Step 1 honestly states it has no unit seam rather than inventing one.

**Type consistency.** `MCPInstance` field names are identical across Tasks 1, 4, 5, 7. `resolve(instances:requestedKey:envKey:sticky:)` is called with the same label set in Tasks 3 and 5. `MCPTarget` cases match between Task 3's definition and Tasks 5–7's switches. `localToolsSpec()` is introduced in Task 6 and referenced only there and by `offlineToolNames()`.
