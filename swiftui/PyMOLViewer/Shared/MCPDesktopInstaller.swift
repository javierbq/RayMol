// MCPDesktopInstaller.swift — install the RayMol bridge into the Claude desktop
// app, either by generating a .mcpb bundle or by merging claude_desktop_config.json.
#if os(macOS) && !RAYMOL_MAS_RESTRICTED
import Foundation

enum MCPDesktopInstaller {
    static func bridgeCommand() -> String {
        Bundle.main.executablePath ?? "/Applications/RayMol.app/Contents/MacOS/RayMol"
    }

    private static func desktopConfigURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    }

    // Pure: merge our entry into an existing config (or a fresh one), preserving
    // any other mcpServers. Returns pretty-printed JSON bytes.
    static func mergedDesktopConfig(existing: Data?, command: String) -> Data {
        var root: [String: Any] = [:]
        if let existing,
           let obj = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] {
            root = obj
        }
        var servers = (root["mcpServers"] as? [String: Any]) ?? [:]
        servers["raymol"] = ["command": command, "args": ["--mcp-bridge"]]
        root["mcpServers"] = servers
        return (try? JSONSerialization.data(withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
    }

    static func installViaConfig() -> (ok: Bool, message: String) {
        let url = desktopConfigURL()
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        let existing = try? Data(contentsOf: url)
        let merged = mergedDesktopConfig(existing: existing, command: bridgeCommand())
        do {
            try merged.write(to: url, options: .atomic)
            return (true, "Added RayMol to the Claude desktop app. Quit and reopen Claude, then ask it to drive RayMol.")
        } catch {
            return (false, "Couldn't write Claude's config. Add this manually to \(url.path):\n\n"
                + (String(data: merged, encoding: .utf8) ?? ""))
        }
    }

    // Pure: the .mcpb manifest. command points at the installed RayMol binary.
    static func mcpbManifest(command: String) -> Data {
        let manifest: [String: Any] = [
            "manifest_version": "0.3",
            "name": "raymol",
            "display_name": "RayMol",
            "version": "1.0.0",
            "description": "Drive the RayMol molecular viewer over its built-in MCP server.",
            "author": ["name": "RayMol"],
            "server": [
                "type": "binary",
                "mcp_config": ["command": command, "args": ["--mcp-bridge"]],
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: manifest,
            options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
    }

    // Writes raymol.mcpb (a zip containing manifest.json) into dir; returns its URL.
    static func writeMcpb(to dir: URL) -> URL? {
        let fm = FileManager.default
        let staging = dir.appendingPathComponent("raymol_mcpb_staging", isDirectory: true)
        try? fm.removeItem(at: staging)
        try? fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let manifest = staging.appendingPathComponent("manifest.json")
        guard (try? mcpbManifest(command: bridgeCommand()).write(to: manifest)) != nil
        else { return nil }
        let out = dir.appendingPathComponent("raymol.mcpb")
        try? fm.removeItem(at: out)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = staging
        zip.arguments = ["-j", out.path, manifest.path]
        do { try zip.run(); zip.waitUntilExit() } catch { return nil }
        guard zip.terminationStatus == 0 else { return nil }
        try? fm.removeItem(at: staging)
        return out
    }
}
#endif
