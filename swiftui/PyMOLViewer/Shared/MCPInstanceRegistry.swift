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
