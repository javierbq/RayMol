// MCPBridge.swift — headless stdio<->localhost-HTTP proxy for the Claude desktop
// app. Claude spawns `RayMol --mcp-bridge`; this forwards newline-delimited
// JSON-RPC to RayMol's loopback MCP server, injecting the bearer token. When the
// server is down it answers initialize/tools/list/ping locally and returns a
// friendly error for tool calls, so Claude always shows the server + tools.
#if os(macOS) && !RAYMOL_MAS_RESTRICTED
import Foundation

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

    // Set when tools/list was answered from the offline copy; the first request
    // the live server answers then sends notifications/tools/list_changed, so a
    // client that cached the offline list fetches the live one.
    private static var servedOfflineTools = false

    static func run() {
        while let line = readLine(strippingNewline: true) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            guard let data = line.data(using: .utf8),
                  let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let id = msg["id"]
            let method = msg["method"] as? String ?? ""
            let wasOffline = servedOfflineTools
            let respData = response(for: msg, method: method, id: id, raw: data)
            if wasOffline && !servedOfflineTools {
                FileHandle.standardOutput.write(encode(["jsonrpc": "2.0",
                    "method": "notifications/tools/list_changed"]))
                FileHandle.standardOutput.write(Data([0x0A]))
            }
            if let respData {
                FileHandle.standardOutput.write(respData)
                FileHandle.standardOutput.write(Data([0x0A]))
            }
            // Notifications (no id) and 202s produce no line.
        }
        // Claude closed our stdin (it quit) — tell the server to terminate our
        // session so the connected-client count updates immediately instead of
        // waiting for the idle sweep.
        if let sid = getSessionId(), let h = handoff(),
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

    private static func handoff() -> (port: Int, token: String)? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/RayMol/mcp.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let port = obj["port"] as? Int, let token = obj["token"] as? String
        else { return nil }
        return (port, token)
    }

    // MARK: proxy

    // Returns the server's JSON response bytes, or nil if the server is unreachable.
    private static func proxy(raw: Data) -> Data? {
        guard let h = handoff(),
              let url = URL(string: "http://127.0.0.1:\(h.port)/mcp") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = raw
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(h.token)", forHTTPHeaderField: "Authorization")
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
        // Try the live server first.
        if let body = proxy(raw: raw) {
            servedOfflineTools = false
            return body.isEmpty ? nil : body   // empty = 202 notification ack
        }
        // Server unreachable: answer locally.
        switch method {
        case "notifications/initialized": return nil
        case "initialize": return localInitialize(id: id)
        case "tools/list":
            servedOfflineTools = true
            return localToolsList(id: id)
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

    // What the live server last said on initialize/tools/list, written by
    // raymol_mcp/server.py (write_discovery_cache) each time it starts.
    private static func discoveryCache() -> [String: Any]? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/RayMol/mcp_tools.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    private static let offlineNote = "RayMol is not running yet: ask the user to open RayMol and enable its MCP server (Connect ▸ Enable AI control), then retry. "

    private static func localInitialize(id: Any?) -> Data {
        let cache = discoveryCache()
        let instructions = (cache?["instructions"] as? String) ?? staticInstructions
        return ok(id: id, result: [
            "protocolVersion": protocolVersion,
            // true: the live list may differ, and run() says so once it is up.
            "capabilities": ["tools": ["listChanged": true]],
            "serverInfo": (cache?["serverInfo"] as? [String: Any])
                ?? ["name": "raymol", "title": "RayMol", "version": "1.0.0"],
            "instructions": offlineNote + instructions,
        ])
    }

    private static func localToolsList(id: Any?) -> Data {
        if let tools = discoveryCache()?["tools"] as? [[String: Any]], !tools.isEmpty {
            return ok(id: id, result: ["tools": tools])
        }
        return ok(id: id, result: ["tools": staticTools])
    }

    // Fallback for a machine where RayMol's server has never started. A static
    // mirror of raymol_mcp tools.list_tools() (names checked by
    // testing/tests/test_mcp_tools.py); descriptions are shortened.
    private static let staticInstructions = "RayMol is a native macOS/iOS molecular viewer built on PyMOL, but it is NOT stock PyMOL: it renders with Metal and adds studio lighting (set_lighting, set_atmosphere), materials (set_material), Metal render effects (set_render_effects), Metal image and movie export (export_image, export_movie) and on-device structure prediction (predict_structure, job_status). Call raymol_help for the feature guide. Everything else is PyMOL: run_pymol_command, run_python, get_session_state, capture_viewport, search_pdb."

    private static let staticTools: [[String: Any]] = {
        func tool(_ name: String, _ description: String,
                  _ properties: [String: Any] = [:], _ required: [String] = []) -> [String: Any] {
            var schema: [String: Any] = ["type": "object", "properties": properties]
            if !required.isEmpty { schema["required"] = required }
            return ["name": name, "description": description, "inputSchema": schema]
        }
        let str: [String: Any] = ["type": "string"]
        let int: [String: Any] = ["type": "integer"]
        let num: [String: Any] = ["type": "number"]
        let bool: [String: Any] = ["type": "boolean"]
        return [
            tool("run_pymol_command", "Run one PyMOL command-language statement (e.g. 'fetch 1ubq, async=0').", ["command": str], ["command"]),
            tool("run_python", "Execute Python with 'cmd' (PyMOL API), 'np', 'Bio'. State persists.", ["code": str], ["code"]),
            tool("get_session_state", "Objects, selections, camera, frames, and RayMol state (lights, effects, materials, scenes, jobs) as JSON."),
            tool("capture_viewport", "PNG of the current view, rendered with Metal as the user sees it.", ["width": int, "height": int]),
            tool("search_pdb", "Full-text RCSB PDB search; returns PDB IDs.", ["query": str, "limit": int], ["query"]),
            tool("set_lighting", "Studio lighting: presets (three_point, softbox, rembrandt, neon, ...), add/edit/remove lights, on/off.", ["preset": str, "ambient": num, "classic": num, "lights": ["type": "array", "items": ["type": "object"]], "remove": ["type": "array", "items": str], "mode": str]),
            tool("set_atmosphere", "Haze and dust in the studio light beams.", ["haze": num, "dust": num, "dust_size": num, "dust_speed": num, "scatter": num, "seed": int, "dust_glow": num, "dust_opacity": num, "off": bool]),
            tool("set_material", "Material (glass, metallic, marble, ...) per object and representation.", ["material": str, "object": str, "representations": ["type": "array", "items": str]], ["material"]),
            tool("set_render_effects", "Metal effects: AO, shadows, ray tracing, outline, depth of field, tone mapping.", ["ssao": bool, "shadows": bool, "raytrace": bool, "outline": bool, "dof": bool, "tonemap": bool, "exposure": num, "msaa": bool]),
            tool("export_image", "Save a PNG rendered with Metal (the app's Save Image).", ["path": str, "width": int, "height": int, "raytrace": int], ["path"]),
            tool("export_movie", "Render the movie to mp4/mov/gif/PNG frames with the Metal exporter.", ["path": str, "width": int, "height": int, "quality": str, "fps": int, "codec": str, "raytrace": bool, "first": int, "last": int], ["path"]),
            tool("predict_structure", "Fold a sequence on device (Boltz-2, Protenix); returns job ids.", ["sequence": str, "predictor": str, "name": str, "n_models": int, "seed": int, "msa": str], ["sequence"]),
            tool("job_status", "Status of on-device prediction and design jobs.", ["job_id": str]),
            tool("raymol_help", "RayMol feature guide, or any command's manual.", ["topic": str]),
        ]
    }()

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
