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

enum MCPInstanceRegistry {
    /// Decode one registry file. Returns nil rather than throwing: a corrupt or
    /// half-written entry must not take the readable instances down with it.
    static func decode(_ data: Data) -> MCPInstance? {
        try? JSONDecoder().decode(MCPInstance.self, from: data)
    }

    static func decodeAll(_ blobs: [Data]) -> [MCPInstance] {
        blobs.compactMap(decode)
    }

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
}
#endif



