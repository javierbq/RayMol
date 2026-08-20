// MCPBridge.swift — headless stdio<->localhost-HTTP proxy for the Claude desktop
// app. Claude spawns `RayMol --mcp-bridge`; this forwards newline-delimited
// JSON-RPC to RayMol's loopback MCP server, injecting the bearer token. When the
// server is down it answers initialize/tools/list/ping locally and returns a
// friendly error for tool calls, so Claude always shows the server + tools.
#if os(macOS) && !RAYMOL_MAS_RESTRICTED
import Foundation
import AppKit

enum MCPBridge {
    private static let protocolVersion = "2025-06-18"
    // sessionId is written from the URLSession completion queue and read on the
    // run() loop thread, so guard it with a lock for safe cross-thread visibility.
    private static var sessionId: String? = nil
    private static let sessionIdLock = NSLock()
    private static func getSessionId() -> String? {
        sessionIdLock.lock(); defer { sessionIdLock.unlock() }; return sessionId
    }
    private static func setSessionId(_ s: String) {
        sessionIdLock.lock(); sessionId = s; sessionIdLock.unlock()
    }
    /// Forget the session. A session id belongs to ONE server process, so it must
    /// not outlive the binding it came from — replaying it at a relaunched (or
    /// different) RayMol names a session that server never issued.
    private static func clearSessionId() {
        sessionIdLock.lock(); sessionId = nil; sessionIdLock.unlock()
    }

    /// The instance this broker session is bound to. Set on first successful
    /// resolution and reused, so a multi-instance setup is disambiguated once
    /// per client session rather than once per call.
    private static var boundInstance: MCPInstance? = nil
    private static let boundLock = NSLock()
    private static func getBound() -> MCPInstance? {
        boundLock.lock(); defer { boundLock.unlock() }; return boundInstance
    }
    private static func setBound(_ i: MCPInstance?) {
        boundLock.lock()
        let changed = boundInstance?.pid != i?.pid
        boundInstance = i
        boundLock.unlock()
        // The session id was issued by the instance we are leaving; carrying it to
        // a different pid would send a stranger's session to the new server.
        if changed { clearSessionId() }
    }

    static let installedAppPath = "/Applications/RayMol.app"

    /// Which bundle a cold launch opens. `RAYMOL_MCP_INSTALLED_APP` overrides it
    /// so the e2e harness can drive a suffixed dev build instead of clobbering
    /// the user's installed RayMol — dev/testing only, like RAYMOL_MCP_PORT, and
    /// never present in a Finder or `open` launch.
    static func coldLaunchTarget(override: String?) -> String {
        guard let o = override, !o.isEmpty else { return installedAppPath }
        return o
    }

    static var coldLaunchPath: String {
        coldLaunchTarget(override: ProcessInfo.processInfo.environment["RAYMOL_MCP_INSTALLED_APP"])
    }

    /// Opening a client must not open RayMol. Launching is a consequence of
    /// asking RayMol to DO something, so only tools/call qualifies.
    static func mayColdLaunch(method: String) -> Bool { method == "tools/call" }

    enum ColdLaunchOutcome: Equatable {
        case launched(MCPInstance)
        /// The bundle is up but never registered — its MCP server is off.
        case alreadyRunningNotRegistered
        case notInstalled
        case launchFailed(String)
        case timedOut
    }

    /// Pure: what to tell the user. Each failure names its OWN cause — collapsing
    /// them sends the user to a setting that is not the problem.
    static func coldLaunchMessage(_ outcome: ColdLaunchOutcome, path: String) -> String {
        switch outcome {
        case .launched:
            return ""
        case .notInstalled:
            return "RayMol isn't installed at \(path). Install it, then retry."
        case .alreadyRunningNotRegistered:
            return "RayMol is already running but its MCP server is off. "
                + "In RayMol, turn on Connect ▸ Enable AI control, then retry."
        case .launchFailed(let why):
            return "Couldn't launch RayMol at \(path): \(why)"
        case .timedOut:
            return "RayMol opened but its MCP server didn't start within 20s. "
                + "In RayMol, turn on Connect ▸ Enable AI control, then retry."
        }
    }

    /// Cold launch is the LAST resort. A pre-registry RayMol is invisible to the
    /// scan but still answers on its legacy handoff, and launching a second copy
    /// on top of the one the user is working in is worse than any error.
    static func shouldColdLaunch(legacyReachable: Bool) -> Bool { !legacyReachable }

    /// The environment a cold-launched RayMol starts with.
    ///
    /// `RAYMOL_MCP_ENABLE=1` makes it bring its server up without persisting
    /// `raymol.mcp.enabled` — a cold launch must not silently turn the server on
    /// for every future manual launch too. `RAYMOL_MCP_PORT` is forwarded only
    /// when set, so the e2e harness can keep off a port another build owns.
    static func launchEnvironment(portOverride: String?) -> [String: String] {
        var env = ["RAYMOL_MCP_ENABLE": "1"]
        if let p = portOverride, !p.isEmpty { env["RAYMOL_MCP_PORT"] = p }
        return env
    }

    /// Is this exact bundle already up? Checked by PATH, not bundle id: every dev
    /// build shares `io.raymol.RayMol`, so an id check would confuse a worktree
    /// build for the installed app.
    static func isRunning(bundlePath: String) -> Bool {
        let want = URL(fileURLWithPath: bundlePath).standardizedFileURL.path
        return NSWorkspace.shared.runningApplications.contains {
            $0.bundleURL?.standardizedFileURL.path == want
        }
    }

    /// Launch the target app and wait for it to register.
    static func coldLaunch(timeout: TimeInterval = 20) -> ColdLaunchOutcome {
        let path = coldLaunchPath
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return .notInstalled }

        // Already up and still unregistered means its server is off, not that it
        // needs launching. Starting a second copy would just add a window.
        let wasRunning = isRunning(bundlePath: path)
        if !wasRunning {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            // Every RayMol build shares a bundle id, so without this LaunchServices
            // "opens" an already-running dev build from another checkout and never
            // starts the bundle we actually asked for.
            cfg.createsNewApplicationInstance = true
            cfg.environment = launchEnvironment(
                portOverride: ProcessInfo.processInfo.environment["RAYMOL_MCP_PORT"])
            let sem = DispatchSemaphore(value: 0)
            var launchError: String? = nil
            NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, err in
                if let err { launchError = err.localizedDescription }
                sem.signal()
            }
            if sem.wait(timeout: .now() + 15) == .timedOut {
                return .launchFailed("the launch request timed out")
            }
            if let launchError { return .launchFailed(launchError) }
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let live = MCPInstanceRegistry.liveDirectoryInstances()
            if let hit = live.first(where: { $0.appPath == path })
                ?? live.first(where: { $0.installed }) ?? live.first {
                return .launched(hit)
            }
            Thread.sleep(forTimeInterval: 0.4)
        }
        return wasRunning ? .alreadyRunningNotRegistered : .timedOut
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

    static func run() {
        while let line = readLine(strippingNewline: true) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            guard let data = line.data(using: .utf8),
                  let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let id = msg["id"]
            let method = msg["method"] as? String ?? ""
            if let respData = response(for: msg, method: method, id: id, raw: data) {
                FileHandle.standardOutput.write(respData)
                FileHandle.standardOutput.write(Data([0x0A]))
            }
            // Notifications (no id) and 202s produce no line.
        }
        // Claude closed our stdin (it quit) — tell the server to terminate our
        // session so the connected-client count updates immediately instead of
        // waiting for the idle sweep.
        if let sid = getSessionId(), let h = getBound() ?? legacyHandoff(),
           let url = URL(string: "http://127.0.0.1:\(h.port)/mcp") {
            var req = URLRequest(url: url)
            req.httpMethod = "DELETE"
            req.setValue("Bearer \(h.token)", forHTTPHeaderField: "Authorization")
            req.setValue(sid, forHTTPHeaderField: "Mcp-Session-Id")
            let sem = DispatchSemaphore(value: 0)
            URLSession.shared.dataTask(with: req) { _, _, _ in sem.signal() }.resume()
            _ = sem.wait(timeout: .now() + 5)
        }
    }

    // MARK: handoff

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

    // MARK: session establishment

    /// The `initialize` the broker sends on the client's behalf.
    ///
    /// Exposed (and pure) so a test can pin that it really is an `initialize` —
    /// the whole point is that the server sees this method, because that is what
    /// makes it raise the "Allow" prompt.
    static func brokerInitializeRequest() -> [String: Any] {
        [
            "jsonrpc": "2.0", "id": "raymol-broker-init", "method": "initialize",
            "params": [
                "protocolVersion": protocolVersion,
                "capabilities": [String: Any](),
                "clientInfo": ["name": "raymol-broker", "version": "1.0.0"],
            ],
        ]
    }

    /// Whether a request must be preceded by an `initialize` we send ourselves.
    ///
    /// We answer `initialize` locally whenever RayMol is down, so the client's own
    /// handshake never reaches the server. A later tool call would then be the
    /// server's FIRST request — and the server raises the approval prompt only on
    /// `initialize`, so the user would be told to click Allow while no prompt was
    /// ever shown, with every retry repeating the same dead end.
    static func needsSessionHandshake(sessionId: String?, method: String) -> Bool {
        method != "initialize" && (sessionId?.isEmpty ?? true)
    }

    /// Open a server-side session before forwarding, when we don't have one.
    private static func ensureSession(with instance: MCPInstance, method: String) {
        guard needsSessionHandshake(sessionId: getSessionId(), method: method),
              let data = try? JSONSerialization.data(
                  withJSONObject: brokerInitializeRequest())
        else { return }
        // The response carries Mcp-Session-Id, which proxy() records for us.
        _ = proxy(raw: data, to: instance)
    }

    // MARK: proxy

    // Returns the server's JSON response bytes, or nil if the server is unreachable.
    private static func proxy(raw: Data, to instance: MCPInstance) -> Data? {
        guard let url = URL(string: "http://127.0.0.1:\(instance.port)/mcp") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = raw
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(instance.token)", forHTTPHeaderField: "Authorization")
        if let sid = getSessionId() { req.setValue(sid, forHTTPHeaderField: "Mcp-Session-Id") }
        let sem = DispatchSemaphore(value: 0)
        var out: Data? = nil
        let task = URLSession.shared.dataTask(with: req) { body, resp, _ in
            if let http = resp as? HTTPURLResponse {
                if let sid = http.value(forHTTPHeaderField: "Mcp-Session-Id") { setSessionId(sid) }
                out = (http.statusCode == 202) ? Data() : (body ?? Data())
            }
            sem.signal()
        }
        task.resume()
        if sem.wait(timeout: .now() + 120) == .timedOut {
            // Cancel so the abandoned task's completion can't write `out`/sessionId
            // off-thread later; don't read `out` here (it could be racing). On
            // success the completion ran fully before signaling, so `out` is safe.
            task.cancel()
            return nil
        }
        return out
    }

    // MARK: response assembly

    private static func response(for msg: [String: Any], method: String,
                                 id: Any?, raw: Data) -> Data? {
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
        if method == "tools/call", var msgCopy = msg as [String: Any]?,
           var params = msgCopy["params"] as? [String: Any],
           var args = params["arguments"] as? [String: Any],
           let key = args["instance"] as? String {
            requestedKey = key
            args["instance"] = nil
            params["arguments"] = args
            msgCopy["params"] = params
            forward = (try? JSONSerialization.data(withJSONObject: msgCopy)) ?? raw
        }

        // Try the live server first.
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
        case .none where mayColdLaunch(method: method):
            // A RayMol that predates the registry answers here and must not be
            // duplicated by a cold launch.
            if let legacy = legacyHandoff() {
                ensureSession(with: legacy, method: method)
                if let body = proxy(raw: forward, to: legacy) {
                    return body.isEmpty ? nil : body
                }
            }
            let outcome = coldLaunch()
            if case .launched(let launched) = outcome {
                setBound(launched)
                instance = launched
            } else {
                return ok(id: id, result: ["content": [["type": "text",
                    "text": coldLaunchMessage(outcome, path: coldLaunchPath)]],
                    "isError": true])
            }
        default:
            instance = legacyHandoff()
        }
        if let instance {
            ensureSession(with: instance, method: method)
            if let body = proxy(raw: forward, to: instance) {
                return body.isEmpty ? nil : body   // empty = 202 notification ack
            }
            // Unreachable or 401 (a recycled pid, or a rotated token): the binding
            // is stale, so drop it and let the next call re-resolve rather than
            // retrying a port that is not ours.
            setBound(nil)
        }
        // Server unreachable: answer locally.
        switch method {
        case "notifications/initialized": return nil
        case "initialize": return localInitialize(id: id)
        case "tools/list":  return localToolsList(id: id)
        case "ping":        return ok(id: id, result: [:])
        case "tools/call":
            return ok(id: id, result: [
                "content": [["type": "text",
                    "text": "Open RayMol and enable the MCP server (Connect ▸ Enable AI control), then retry."]],
                "isError": true,
            ])
        default:
            if id == nil { return nil }
            return err(id: id, code: -32601, message: "method not found: \(method)")
        }
    }

    private static func localInitialize(id: Any?) -> Data {
        ok(id: id, result: [
            "protocolVersion": protocolVersion,
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "raymol", "version": "1.0.0"],
            "instructions": "RayMol is a molecular viewer (a PyMOL fork). It is not running yet — ask the user to open RayMol and enable its MCP server (Connect ▸ Enable AI control). Then use run_pymol_command / run_python / get_session_state / capture_viewport / search_pdb.",
        ])
    }

    /// Static mirror of raymol_mcp/tools.py TOOLS (used only when the server is
    /// down; the live list is proxied when it's up). Keep names in sync —
    /// MCPBrokerTests.testOfflineToolsListStillNamesEveryTool pins the list.
    static func localToolsSpec() -> [[String: Any]] {
        [
            ["name": "run_pymol_command", "description": "Run one PyMOL command-language statement (e.g. 'fetch 1ubq, async=0').", "inputSchema": ["type": "object", "properties": ["command": ["type": "string"]], "required": ["command"]]],
            ["name": "run_python", "description": "Execute arbitrary Python with 'cmd' (PyMOL API), 'np', 'Bio'. State persists.", "inputSchema": ["type": "object", "properties": ["code": ["type": "string"]], "required": ["code"]]],
            ["name": "get_session_state", "description": "Return objects, selections, camera view, frame info as JSON.", "inputSchema": ["type": "object", "properties": [:]]],
            ["name": "capture_viewport", "description": "Ray-traced PNG of the current view.", "inputSchema": ["type": "object", "properties": ["width": ["type": "integer"], "height": ["type": "integer"]]]],
            ["name": "search_pdb", "description": "Full-text RCSB PDB search; returns PDB IDs.", "inputSchema": ["type": "object", "properties": ["query": ["type": "string"], "limit": ["type": "integer"]], "required": ["query"]]],
        ]
    }

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

    static let listInstancesTool: [String: Any] = [
        "name": "list_raymol_instances",
        "description": "List running RayMol instances and the key that names each one.",
        "inputSchema": ["type": "object", "properties": [String: Any]()],
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

    private static func localToolsList(id: Any?) -> Data {
        ok(id: id, result: ["tools": withInstanceArg(localToolsSpec()) + [listInstancesTool]])
    }

    private static func ok(id: Any?, result: [String: Any]) -> Data {
        encode(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
    }
    private static func err(id: Any?, code: Int, message: String) -> Data {
        encode(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]])
    }
    private static func encode(_ obj: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
    }
}
#endif
