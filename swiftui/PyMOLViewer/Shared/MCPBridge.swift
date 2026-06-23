// MCPBridge.swift — headless stdio<->localhost-HTTP proxy for the Claude desktop
// app. Claude spawns `RayMol --mcp-bridge`; this forwards newline-delimited
// JSON-RPC to RayMol's loopback MCP server, injecting the bearer token. When the
// server is down it answers initialize/tools/list/ping locally and returns a
// friendly error for tool calls, so Claude always shows the server + tools.
#if os(macOS) && !RAYMOL_MAS_RESTRICTED
import Foundation

enum MCPBridge {
    private static let protocolVersion = "2025-06-18"
    private static var sessionId: String? = nil

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
        if let sid = sessionId, let h = handoff(),
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
        if let sid = sessionId { req.setValue(sid, forHTTPHeaderField: "Mcp-Session-Id") }
        let sem = DispatchSemaphore(value: 0)
        var out: Data? = nil
        let task = URLSession.shared.dataTask(with: req) { body, resp, _ in
            if let http = resp as? HTTPURLResponse {
                if let sid = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionId = sid }
                out = (http.statusCode == 202) ? Data() : (body ?? Data())
            }
            sem.signal()
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 120)
        return out
    }

    // MARK: response assembly

    private static func response(for msg: [String: Any], method: String,
                                 id: Any?, raw: Data) -> Data? {
        // Try the live server first.
        if let body = proxy(raw: raw) {
            return body.isEmpty ? nil : body   // empty = 202 notification ack
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

    private static func localToolsList(id: Any?) -> Data {
        // Static mirror of raymol_mcp/tools.py TOOLS (used only when the server is
        // down; the live list is proxied when it's up). Keep names in sync.
        let tools: [[String: Any]] = [
            ["name": "run_pymol_command", "description": "Run one PyMOL command-language statement (e.g. 'fetch 1ubq, async=0').", "inputSchema": ["type": "object", "properties": ["command": ["type": "string"]], "required": ["command"]]],
            ["name": "run_python", "description": "Execute arbitrary Python with 'cmd' (PyMOL API), 'np', 'Bio'. State persists.", "inputSchema": ["type": "object", "properties": ["code": ["type": "string"]], "required": ["code"]]],
            ["name": "get_session_state", "description": "Return objects, selections, camera view, frame info as JSON.", "inputSchema": ["type": "object", "properties": [:]]],
            ["name": "capture_viewport", "description": "Ray-traced PNG of the current view.", "inputSchema": ["type": "object", "properties": ["width": ["type": "integer"], "height": ["type": "integer"]]]],
            ["name": "search_pdb", "description": "Full-text RCSB PDB search; returns PDB IDs.", "inputSchema": ["type": "object", "properties": ["query": ["type": "string"], "limit": ["type": "integer"]], "required": ["query"]]],
        ]
        return ok(id: id, result: ["tools": tools])
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
